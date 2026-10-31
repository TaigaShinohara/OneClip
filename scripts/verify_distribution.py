#!/usr/bin/env python3
"""Read-only, fail-closed distribution preflight for OneClip's single-executable app.

This is separate from ordinary local builds. It never signs, staples, uploads,
launches, changes quarantine, or reads signing credentials. The distribution
stage may consult macOS security services; it is not an offline/fresh-launch test.
System-tool output can contain personal information and never reaches the report.

Policy oneclip-minimal-v1 requires an explicitly approved Developer ID team and bundle ID,
App Sandbox, Hardened Runtime and a secure timestamp in every executable slice.
Only the app's main executable is supported. Additional code, executable files,
nested bundles and symlinks fail closed until the policy is deliberately extended.
Deep signature verification also checks the bundle's sealed nested content; it
does not substitute for a future per-helper entitlement/runtime policy.

References: local codesign(1), spctl(8), and `xcrun stapler help`;
https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
https://developer.apple.com/documentation/security/resolving-common-notarization-issues
https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
from xml.parsers.expat import ExpatError


POLICY = "oneclip-minimal-v1"
MANIFEST_ALGORITHM = "oneclip-bundle-manifest-sha256-v1"
BUNDLE_ID_PATTERN = r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"
TOOL_TIMEOUT = 30
MAX_TOOL_OUTPUT = 1024 * 1024
MAX_PLIST_BYTES = 1024 * 1024
MAX_ENTRIES = 20_000
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
NESTED_SUFFIXES = {".app", ".framework", ".xpc", ".appex", ".bundle"}
DISABLED_ENTITLEMENTS = {
    "com.apple.security.get-task-allow",
    "com.apple.security.network.client", "com.apple.security.network.server",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.debugger",
    "com.apple.security.automation.apple-events",
}


class VerificationFailure(Exception):
    """The code is a fixed classification, never a tool diagnostic or input value."""


class UniqueKeys(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise ValueError("duplicate plist key")
        super().__setitem__(key, value)


@dataclass(frozen=True)
class ToolResult:
    returncode: int
    stdout: bytes = b""
    stderr: bytes = b""


@dataclass(frozen=True)
class Artifact:
    path: Path
    bundle_id: str
    architectures: tuple
    digest: bytes


def run_tool(arguments):
    """Fixed executable/argv, bounded time, no shell, stdin or credential environment."""
    try:
        completed = subprocess.run(
            list(arguments), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=TOOL_TIMEOUT, check=False, shell=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        raise VerificationFailure("tool_timeout") from None
    except (OSError, subprocess.SubprocessError):
        raise VerificationFailure("tool_unavailable") from None
    if len(completed.stdout) + len(completed.stderr) > MAX_TOOL_OUTPUT:
        raise VerificationFailure("tool_output_limit")
    return ToolResult(completed.returncode, completed.stdout, completed.stderr)


def checked_tool(runner, arguments):
    try:
        result = runner(tuple(arguments))
    except VerificationFailure:
        raise
    except subprocess.TimeoutExpired:
        raise VerificationFailure("tool_timeout") from None
    except (OSError, subprocess.SubprocessError):
        raise VerificationFailure("tool_unavailable") from None
    if not isinstance(result, ToolResult):
        raise VerificationFailure("tool_result_invalid")
    if (type(result.returncode) is not int or type(result.stdout) is not bytes
            or type(result.stderr) is not bytes):
        raise VerificationFailure("tool_result_invalid")
    if len(result.stdout) + len(result.stderr) > MAX_TOOL_OUTPUT:
        raise VerificationFailure("tool_output_limit")
    if result.returncode != 0:
        raise VerificationFailure("tool_rejected")
    return result


def dictionary_plist(data):
    if not data or len(data) > MAX_PLIST_BYTES:
        raise VerificationFailure("plist_missing_or_oversized")
    try:
        value = plistlib.loads(data, dict_type=UniqueKeys)
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, ExpatError):
        raise VerificationFailure("plist_invalid") from None
    if not isinstance(value, dict):
        raise VerificationFailure("plist_not_dictionary")
    return value


def architecture_name(cpu, subtype):
    supported = {(0x0100000C, 0): "arm64", (0x01000007, 3): "x86_64"}
    name = supported.get((cpu, subtype & 0x00FFFFFF))
    if name is None:
        raise VerificationFailure("architecture_unsupported")
    return name


def thin_architecture(handle, offset, size):
    handle.seek(offset)
    header = handle.read(32)
    if len(header) != 32 or size < 32:
        raise VerificationFailure("executable_invalid")
    endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(header[:4])
    if endian is None:
        raise VerificationFailure("architecture_unsupported")
    _, cpu, subtype, file_type, _, _, _, _ = struct.unpack(endian + "8I", header)
    if file_type != 2:  # MH_EXECUTE; libraries/helpers need an explicit future policy.
        raise VerificationFailure("executable_invalid")
    return architecture_name(cpu, subtype), cpu, subtype


def executable_architectures(path):
    size = path.stat().st_size
    with path.open("rb") as handle:
        magic = handle.read(4)
        if magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}:
            return (thin_architecture(handle, 0, size)[0],)
        formats = {
            b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
            b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
        }
        if magic not in formats:
            raise VerificationFailure("executable_invalid")
        endian, fat64 = formats[magic]
        count_data = handle.read(4)
        if len(count_data) != 4:
            raise VerificationFailure("executable_invalid")
        count = struct.unpack(endian + "I", count_data)[0]
        if count not in {1, 2}:
            raise VerificationFailure("architecture_unsupported")
        entry_size = 32 if fat64 else 20
        entries = handle.read(count * entry_size)
        if len(entries) != count * entry_size:
            raise VerificationFailure("executable_invalid")
        names, ranges = [], []
        for index in range(count):
            entry = entries[index * entry_size:(index + 1) * entry_size]
            fields = struct.unpack(endian + ("IIQQII" if fat64 else "IIIII"), entry)
            cpu, subtype, offset, slice_size, alignment = fields[:5]
            if (offset < 8 + count * entry_size or slice_size < 32
                    or offset + slice_size > size or alignment > 31
                    or offset % (1 << alignment) != 0
                    or any(offset < end and offset + slice_size > start for start, end in ranges)):
                raise VerificationFailure("executable_invalid")
            name, actual_cpu, actual_subtype = thin_architecture(handle, offset, slice_size)
            if actual_cpu != cpu or actual_subtype != subtype or name in names:
                raise VerificationFailure("executable_invalid")
            names.append(name)
            ranges.append((offset, offset + slice_size))
        return tuple(names)


def inspect_artifact(app):
    """Inventory sealed files without following links or executing any candidate code."""
    path = Path(app).absolute()
    if path.is_symlink() or path.suffix != ".app" or not path.is_dir():
        raise VerificationFailure("app_invalid")
    path = path.resolve(strict=True)
    entries = []

    def unreadable_directory(error):
        raise VerificationFailure("bundle_unreadable")

    for directory, dirs, files in os.walk(path, followlinks=False, onerror=unreadable_directory):
        for name in sorted(dirs + files):
            item = Path(directory) / name
            relative = item.relative_to(path)
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise VerificationFailure("symlink_unsupported")
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise VerificationFailure("bundle_entry_unsupported")
            if stat.S_ISDIR(mode) and item.suffix.lower() in NESTED_SUFFIXES:
                raise VerificationFailure("nested_code_unsupported")
            entries.append((relative, mode))
            if len(entries) > MAX_ENTRIES:
                raise VerificationFailure("bundle_entry_limit")
    info_path = path / "Contents" / "Info.plist"
    if info_path.stat().st_size > MAX_PLIST_BYTES:
        raise VerificationFailure("plist_missing_or_oversized")
    info = dictionary_plist(info_path.read_bytes())
    executable = info.get("CFBundleExecutable")
    bundle_id = info.get("CFBundleIdentifier")
    if (type(executable) is not str or not re.fullmatch(r"[A-Za-z0-9_.-]+", executable)
            or executable in {".", ".."} or info.get("CFBundlePackageType") != "APPL"
            or type(bundle_id) is not str
            or not re.fullmatch(BUNDLE_ID_PATTERN, bundle_id)):
        raise VerificationFailure("bundle_metadata_invalid")
    main = Path("Contents") / "MacOS" / executable
    main_path = path / main
    if not main_path.is_file() or main_path.stat().st_mode & 0o111 == 0:
        raise VerificationFailure("main_executable_missing")
    digest = hashlib.sha256()
    # Portable v1 framing: algorithm tag, then sorted relative path bytes (u32
    # length + bytes), u32 POSIX permissions, entry type, and the 32-byte SHA-256
    # of each regular file. Absolute paths, timestamps and inode IDs are absent.
    # Quarantine and other xattrs are separate evidence, not covered by this hash.
    digest.update(MANIFEST_ALGORITHM.encode("ascii") + b"\0")
    for relative, mode in sorted(entries):
        item = path / relative
        relative_bytes = os.fsencode(relative)
        digest.update(struct.pack(">I", len(relative_bytes)) + relative_bytes)
        digest.update(struct.pack(">I", stat.S_IMODE(mode)))
        digest.update(b"directory" if stat.S_ISDIR(mode) else b"file")
        if stat.S_ISDIR(mode):
            continue
        file_digest = hashlib.sha256()
        with item.open("rb") as handle:
            magic = handle.read(4)
            if relative != main and (magic in MACHO_MAGICS or mode & 0o111):
                raise VerificationFailure("nested_code_unsupported")
            handle.seek(0)
            while chunk := handle.read(1024 * 1024):
                file_digest.update(chunk)
        digest.update(file_digest.digest())
    return Artifact(path, bundle_id, executable_architectures(main_path), digest.digest())


def validate_metadata(result, team_id, bundle_id):
    try:
        lines = (result.stdout + b"\n" + result.stderr).decode("utf-8").splitlines()
    except UnicodeError:
        raise VerificationFailure("metadata_invalid") from None

    def one(prefix):
        values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
        if len(values) != 1 or not values[0].strip():
            raise VerificationFailure("metadata_missing_or_ambiguous")
        return values[0].strip()

    if one("Identifier=") != bundle_id or one("TeamIdentifier=") != team_id:
        raise VerificationFailure("signer_or_identifier_mismatch")
    authorities = [line[len("Authority="):] for line in lines if line.startswith("Authority=")]
    if not authorities or not authorities[0].startswith("Developer ID Application: "):
        raise VerificationFailure("developer_id_required")
    if any(line.lower() == "signature=adhoc" for line in lines):
        raise VerificationFailure("developer_id_required")
    signatures = [line for line in lines if re.fullmatch(r"Signature size=[1-9][0-9]*", line)]
    if len(signatures) != 1:
        raise VerificationFailure("developer_id_required")
    directories = [line for line in lines if line.startswith("CodeDirectory ")]
    if len(directories) != 1:
        raise VerificationFailure("metadata_missing_or_ambiguous")
    flags = re.search(r"\bflags=(0x[0-9a-fA-F]+)(?:\(|\s|$)", directories[0])
    if not flags:
        raise VerificationFailure("metadata_missing_or_ambiguous")
    value = int(flags.group(1), 16)
    if not value & 0x10000 or value & (0x2 | 0x20000):
        raise VerificationFailure("hardened_runtime_required")
    if one("Timestamp=").lower() in {"none", "(none)", "not set", "unknown"}:
        raise VerificationFailure("secure_timestamp_required")


def validate_entitlements(data, team_id, bundle_id):
    entitlements = dictionary_plist(data)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise VerificationFailure("sandbox_required")
    allowed = {"com.apple.security.app-sandbox"} | DISABLED_ENTITLEMENTS | {
        "com.apple.application-identifier", "com.apple.developer.team-identifier",
    }
    if any(key not in allowed for key in entitlements):
        raise VerificationFailure("unexpected_entitlement")
    for key in DISABLED_ENTITLEMENTS:
        if key in entitlements and entitlements[key] is not False:
            raise VerificationFailure("unsafe_entitlement_value")
    expected = {"com.apple.application-identifier": team_id + "." + bundle_id,
                "com.apple.developer.team-identifier": team_id}
    for key, value in expected.items():
        if key in entitlements and entitlements[key] != value:
            raise VerificationFailure("entitlement_identity_mismatch")


def output_plist(result):
    # codesign/spctl output channel differs by tool/version; accept one whole plist,
    # never strip arbitrary diagnostics from a mixed stream or print either stream.
    candidates = [stream for stream in (result.stdout, result.stderr)
                  if stream.lstrip().startswith((b"<?xml", b"<plist", b"bplist00"))]
    if len(candidates) != 1:
        raise VerificationFailure("plist_missing_or_ambiguous")
    return candidates[0]


def verify_app(app, *, stage, policy, expected_team_id, expected_bundle_id, runner=run_tool):
    report = {
        "schema": "oneclip-distribution-preflight-v1", "stage": stage if stage in {"signed", "distribution"} else "invalid",
        "policy": POLICY, "status": "failed", "checks": [],
        "signed_preflight_passed": False, "distribution_preflight_passed": False,
        "distribution_acceptance_complete": False, "fresh_install_launch_verified": False,
        "offline_launch_verified": False, "atomic_inspection": False,
        "artifact_manifest_algorithm": MANIFEST_ALGORITHM,
        "artifact_manifest_sha256": None,
        "expected_team_id_sha256": None, "expected_bundle_id_sha256": None,
    }

    def check(name, action):
        try:
            value = action()
        except VerificationFailure as error:
            report["checks"].append({"check": name, "passed": False, "reason": str(error)})
            raise
        report["checks"].append({"check": name, "passed": True, "reason": "verified"})
        return value

    try:
        if stage not in {"signed", "distribution"} or policy != POLICY:
            raise VerificationFailure("explicit_stage_and_policy_required")
        if type(expected_team_id) is not str or not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
            raise VerificationFailure("approved_team_required")
        if type(expected_bundle_id) is not str or not re.fullmatch(BUNDLE_ID_PATTERN, expected_bundle_id):
            raise VerificationFailure("approved_bundle_id_required")
        report["expected_team_id_sha256"] = hashlib.sha256(expected_team_id.encode("ascii")).hexdigest()
        report["expected_bundle_id_sha256"] = hashlib.sha256(expected_bundle_id.encode("ascii")).hexdigest()
        artifact = check("single_executable_bundle", lambda: inspect_artifact(app))
        report["artifact_manifest_sha256"] = artifact.digest.hex()

        def approved_bundle():
            if artifact.bundle_id != expected_bundle_id:
                raise VerificationFailure("approved_bundle_id_mismatch")
        check("approved_bundle_identity", approved_bundle)
        # codesign treats a plain requirement argument as a file path. The '='
        # prefix selects literal requirement source, as documented by csreq(1).
        requirement = ('=identifier "' + expected_bundle_id + '" and anchor apple generic '
                       'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                       'and certificate leaf[subject.OU] = "' + expected_team_id + '"')
        check("strict_signature_all_architectures", lambda: checked_tool(runner, (
            "/usr/bin/codesign", "--verify", "--deep", "--strict=all", "--all-architectures",
            "--test-requirement", requirement, str(artifact.path))))
        for architecture in artifact.architectures:
            def metadata():
                result = checked_tool(runner, ("/usr/bin/codesign", "--display", "--verbose=4",
                                      "--architecture", architecture, str(artifact.path)))
                validate_metadata(result, expected_team_id, expected_bundle_id)
            check("signed_metadata_" + architecture, metadata)

            def entitlements():
                result = checked_tool(runner, ("/usr/bin/codesign", "--display", "--entitlements", "-", "--xml",
                                      "--architecture", architecture, str(artifact.path)))
                validate_entitlements(output_plist(result), expected_team_id, expected_bundle_id)
            check("minimal_entitlements_" + architecture, entitlements)
        if stage == "distribution":
            check("stapled_notarization_ticket", lambda: checked_tool(
                runner, ("/usr/bin/xcrun", "stapler", "validate", "-q", str(artifact.path))))

            def gatekeeper_enabled():
                result = checked_tool(runner, ("/usr/sbin/spctl", "--status"))
                if result.stdout.strip() != b"assessments enabled":
                    raise VerificationFailure("gatekeeper_disabled_or_unknown")
            check("gatekeeper_enabled", gatekeeper_enabled)

            def assessment():
                result = checked_tool(runner, ("/usr/sbin/spctl", "--assess", "--type", "execute",
                                      "--ignore-cache", "--no-cache", "--raw", str(artifact.path)))
                value = dictionary_plist(output_plist(result))
                authority = value.get("assessment:authority")
                if (value.get("assessment:verdict") is not True or not isinstance(authority, dict)
                        or authority.get("source") != "Notarized Developer ID"):
                    raise VerificationFailure("notarized_policy_verdict_required")
            check("notarized_gatekeeper_assessment", assessment)

        def unchanged():
            if inspect_artifact(artifact.path) != artifact:
                raise VerificationFailure("artifact_changed")
        check("artifact_unchanged_during_checks", unchanged)
        report["signed_preflight_passed"] = True
        report["distribution_preflight_passed"] = stage == "distribution"
        report["status"] = "passed_distribution_preflight" if stage == "distribution" else "passed_signed_preflight"
    except VerificationFailure as error:
        report["failure"] = str(error)
    except (OSError, ValueError, TypeError, struct.error):
        report["failure"] = "artifact_or_result_unreadable"
    except Exception:
        # Unknown execution/parser failures also fail closed, without an error
        # string or traceback that could contain an input path or tool output.
        report["failure"] = "verification_unexpected_error"
    return report


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally repeats supplied values, which can contain private paths.
        raise VerificationFailure("invalid_arguments")


def main(arguments=None):
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--stage", required=True, choices=("signed", "distribution"))
    parser.add_argument("--policy", required=True, choices=(POLICY,))
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    try:
        options = parser.parse_args(arguments)
        report = verify_app(options.app, stage=options.stage, policy=options.policy,
                            expected_team_id=options.expected_team_id,
                            expected_bundle_id=options.expected_bundle_id)
    except VerificationFailure:
        report = {"schema": "oneclip-distribution-preflight-v1", "status": "failed",
                  "failure": "invalid_arguments", "distribution_preflight_passed": False,
                  "artifact_manifest_algorithm": MANIFEST_ALGORITHM,
                  "artifact_manifest_sha256": None,
                  "expected_team_id_sha256": None, "expected_bundle_id_sha256": None}
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"].startswith("passed_") else 1


if __name__ == "__main__":
    sys.exit(main())
