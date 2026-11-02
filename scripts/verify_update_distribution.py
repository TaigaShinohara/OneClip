#!/usr/bin/env python3
"""Read-only preflight for OneClip with the pinned Sparkle 2.10.1 runtime.

Never signs, launches, installs, publishes, changes quarantine, or reads credentials.
Tool diagnostics, paths and signer identities never enter the JSON report. The
old single-executable policy remains separate and unchanged. This policy permits
only Sparkle's five known nested code owners and fixed framework aliases.
"""
import argparse
import base64
from dataclasses import dataclass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys

_SPEC = importlib.util.spec_from_file_location(
    "oneclip_minimal_distribution_policy", Path(__file__).with_name("verify_distribution.py"))
minimal = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = minimal
_SPEC.loader.exec_module(minimal)
VerificationFailure = minimal.VerificationFailure
ToolResult = minimal.ToolResult
run_tool = minimal.run_tool
checked_tool = minimal.checked_tool
POLICY = "oneclip-sparkle-2.10.1-v1"
MANIFEST_ALGORITHM = "oneclip-update-bundle-manifest-sha256-v1"
FEED_URL = "https://raw.githubusercontent.com/TaigaShinohara/OneClip/main/updates/appcast.xml"
FRAMEWORK = "Contents/Frameworks/Sparkle.framework"
VERSION = FRAMEWORK + "/Versions/B"
ALIASES = {FRAMEWORK + "/Versions/Current": "B"}
for _name in ("Autoupdate", "Headers", "Modules", "PrivateHeaders", "Resources", "Sparkle", "Updater.app", "XPCServices"):
    ALIASES[FRAMEWORK + "/" + _name] = "Versions/Current/" + _name
REQUIRED_ALIASES = set(ALIASES) - {FRAMEWORK + "/" + name for name in ("Headers", "Modules", "PrivateHeaders")}
# label, owner path, executable path, identifier, Mach-O type
OWNERS = (
    ("main", ".", "Contents/MacOS/OneClip", None, 2),
    ("sparkle", FRAMEWORK, VERSION + "/Sparkle", "org.sparkle-project.Sparkle", 6),
    ("autoupdate", VERSION + "/Autoupdate", VERSION + "/Autoupdate", "org.sparkle-project.Sparkle.Autoupdate", 2),
    ("updater", VERSION + "/Updater.app", VERSION + "/Updater.app/Contents/MacOS/Updater", "org.sparkle-project.Sparkle.Updater", 2),
    ("installer", VERSION + "/XPCServices/Installer.xpc", VERSION + "/XPCServices/Installer.xpc/Contents/MacOS/Installer", "org.sparkle-project.InstallerLauncher", 2),
    ("downloader", VERSION + "/XPCServices/Downloader.xpc", VERSION + "/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "org.sparkle-project.DownloaderService", 2),
)
BUNDLE_INFOS = (
    (VERSION + "/Resources/Info.plist", "org.sparkle-project.Sparkle", "Sparkle", "FMWK"),
    (VERSION + "/Updater.app/Contents/Info.plist", "org.sparkle-project.Sparkle.Updater", "Updater", "APPL"),
    (VERSION + "/XPCServices/Installer.xpc/Contents/Info.plist", "org.sparkle-project.InstallerLauncher", "Installer", "XPC!"),
    (VERSION + "/XPCServices/Downloader.xpc/Contents/Info.plist", "org.sparkle-project.DownloaderService", "Downloader", "XPC!"),
)

SAFE_FAILURES = frozenset("""
app_invalid approved_bundle_id_required approved_team_required architecture_unsupported
artifact_changed artifact_or_result_unreadable autoupdate_application_identifier_required
bundle_entry_limit bundle_entry_unsupported bundle_metadata_invalid bundle_unreadable
developer_id_required entitlements_missing_or_ambiguous entitlement_identity_mismatch
executable_invalid executable_not_allowed executable_type_invalid explicit_stage_and_policy_required
framework_alias_missing gatekeeper_disabled_or_unknown hardened_runtime_required
known_executable_missing manual_only_update_settings_required metadata_invalid
metadata_missing_or_ambiguous nested_code_not_allowed notarized_policy_verdict_required
plist_invalid plist_missing_or_ambiguous plist_missing_or_oversized plist_not_dictionary
sandbox_required secure_timestamp_required secure_update_setting_required signed_feed_expiry_forbidden
signer_or_identifier_mismatch sparkle_bundle_version_or_identity_mismatch sparkle_mach_names_mismatch
symlink_not_allowed tool_output_limit tool_rejected tool_result_invalid tool_timeout tool_unavailable
unexpected_entitlement universal_release_required update_channel_invalid update_feed_mismatch
update_public_key_invalid update_version_invalid verification_unexpected_error
""".split())


def failure_code(error):
    value = str(error)
    return value if value in SAFE_FAILURES else "verification_unexpected_error"

@dataclass(frozen=True)
class Code:
    label: str
    owner: Path
    executable: Path
    identifier: str
    architectures: tuple

@dataclass(frozen=True)
class Artifact:
    path: Path
    bundle_id: str
    codes: tuple
    digest: bytes


def _read_info(path):
    if path.stat().st_size > minimal.MAX_PLIST_BYTES:
        raise VerificationFailure("plist_missing_or_oversized")
    return minimal.dictionary_plist(path.read_bytes())


def validate_settings(info, bundle_id):
    if (info.get("CFBundleIdentifier") != bundle_id or info.get("CFBundleExecutable") != "OneClip"
            or info.get("CFBundlePackageType") != "APPL"):
        raise VerificationFailure("bundle_metadata_invalid")
    build = info.get("CFBundleVersion")
    display = info.get("CFBundleShortVersionString")
    if (type(build) is not str or not re.fullmatch(r"[1-9][0-9]{0,17}", build) or int(build) < 2
            or type(display) is not str or len(display) > 64
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", display)):
        raise VerificationFailure("update_version_invalid")
    if info.get("OneClipUpdateChannel") not in {"stable", "development"}:
        raise VerificationFailure("update_channel_invalid")
    if info.get("SUFeedURL") != FEED_URL:
        raise VerificationFailure("update_feed_mismatch")
    key = info.get("SUPublicEDKey")
    try:
        if type(key) is not str or len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError()
    except (ValueError, TypeError):
        raise VerificationFailure("update_public_key_invalid") from None
    required_true = ("SUEnableInstallerLauncherService", "SUEnableDownloaderService",
                     "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction")
    required_false = ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates",
                      "SUEnableSystemProfiling", "SUEnableJavaScript", "SUShowReleaseNotes")
    if any(info.get(k) is not True for k in required_true):
        raise VerificationFailure("secure_update_setting_required")
    if any(info.get(k) is not False for k in required_false):
        raise VerificationFailure("manual_only_update_settings_required")
    if type(info.get("SUSignedFeedFailureExpirationInterval")) is not int or info["SUSignedFeedFailureExpirationInterval"] != 0:
        raise VerificationFailure("signed_feed_expiry_forbidden")


def _thin(handle, offset, size, expected_type):
    handle.seek(offset)
    header = handle.read(32)
    endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(header[:4])
    if endian is None or len(header) != 32 or size < 32:
        raise VerificationFailure("executable_invalid")
    _, cpu, subtype, kind, _, _, _, _ = struct.unpack(endian + "8I", header)
    if kind != expected_type:
        raise VerificationFailure("executable_type_invalid")
    return minimal.architecture_name(cpu, subtype), cpu, subtype


def code_architectures(path, expected_type):
    size = path.stat().st_size
    with path.open("rb") as handle:
        magic = handle.read(4)
        if magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}:
            return (_thin(handle, 0, size, expected_type)[0],)
        formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
        if magic not in formats:
            raise VerificationFailure("executable_invalid")
        endian, fat64 = formats[magic]
        raw = handle.read(4)
        if len(raw) != 4 or struct.unpack(endian + "I", raw)[0] != 2:
            raise VerificationFailure("universal_release_required")
        entry_size = 32 if fat64 else 20
        entries = handle.read(2 * entry_size)
        if len(entries) != 2 * entry_size:
            raise VerificationFailure("executable_invalid")
        names, ranges = [], []
        for index in range(2):
            fields = struct.unpack(endian + ("IIQQII" if fat64 else "IIIII"), entries[index * entry_size:(index + 1) * entry_size])
            cpu, subtype, offset, length, alignment = fields[:5]
            if (offset < 8 + 2 * entry_size or length < 32 or offset + length > size or alignment > 31
                    or offset % (1 << alignment) or any(offset < end and offset + length > start for start, end in ranges)):
                raise VerificationFailure("executable_invalid")
            name, actual_cpu, actual_subtype = _thin(handle, offset, length, expected_type)
            if (actual_cpu, actual_subtype) != (cpu, subtype) or name in names:
                raise VerificationFailure("executable_invalid")
            names.append(name); ranges.append((offset, offset + length))
        return tuple(names)


def inspect_artifact(app, bundle_id):
    root = Path(app).absolute()
    if root.is_symlink() or root.suffix != ".app" or not root.is_dir():
        raise VerificationFailure("app_invalid")
    root = root.resolve(strict=True)
    entries, links = [], set()
    allowed_bundles = {owner for _, owner, _, _, _ in OWNERS if owner != "." and Path(owner).suffix in minimal.NESTED_SUFFIXES}
    allowed_executables = {executable for _, _, executable, _, _ in OWNERS}
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=lambda _: (_ for _ in ()).throw(VerificationFailure("bundle_unreadable"))):
        for name in sorted(dirs + files):
            item = Path(directory) / name
            relative = item.relative_to(root).as_posix()
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode):
                if relative not in ALIASES or os.readlink(item) != ALIASES[relative]:
                    raise VerificationFailure("symlink_not_allowed")
                try:
                    target = item.resolve(strict=True)
                    target.relative_to(root)
                except (ValueError, OSError, RuntimeError):
                    raise VerificationFailure("symlink_not_allowed") from None
                links.add(relative)
            elif not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise VerificationFailure("bundle_entry_unsupported")
            elif stat.S_ISDIR(mode) and item.suffix.lower() in minimal.NESTED_SUFFIXES and relative not in allowed_bundles:
                raise VerificationFailure("nested_code_not_allowed")
            entries.append((relative, mode))
            if len(entries) > minimal.MAX_ENTRIES:
                raise VerificationFailure("bundle_entry_limit")
    if not REQUIRED_ALIASES.issubset(links):
        raise VerificationFailure("framework_alias_missing")
    validate_settings(_read_info(root / "Contents/Info.plist"), bundle_id)
    for relative, identifier, executable, kind in BUNDLE_INFOS:
        info = _read_info(root / relative)
        if (info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable
                or info.get("CFBundlePackageType") != kind or info.get("CFBundleShortVersionString") != "2.10.1"
                or info.get("CFBundleVersion") != "2065"):
            raise VerificationFailure("sparkle_bundle_version_or_identity_mismatch")
    digest = hashlib.sha256(MANIFEST_ALGORITHM.encode("ascii") + b"\0")
    for relative, mode in sorted(entries):
        item = root / relative
        raw = os.fsencode(relative)
        digest.update(struct.pack(">I", len(raw)) + raw + struct.pack(">I", stat.S_IMODE(mode)))
        if stat.S_ISDIR(mode):
            digest.update(b"directory"); continue
        if stat.S_ISLNK(mode):
            target = os.fsencode(os.readlink(item))
            digest.update(b"symlink" + struct.pack(">I", len(target)) + target); continue
        content = hashlib.sha256()
        with item.open("rb") as handle:
            magic = handle.read(4)
            if relative not in allowed_executables and (magic in minimal.MACHO_MAGICS or mode & 0o111):
                raise VerificationFailure("executable_not_allowed")
            handle.seek(0)
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                content.update(chunk)
        digest.update(b"file" + content.digest())
    codes = []
    for label, owner, executable, identifier, kind in OWNERS:
        path = root / executable
        if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o111 == 0:
            raise VerificationFailure("known_executable_missing")
        architectures = code_architectures(path, kind)
        if set(architectures) != {"arm64", "x86_64"}:
            raise VerificationFailure("universal_release_required")
        codes.append(Code(label, root / owner, path, identifier or bundle_id, architectures))
    return Artifact(root, bundle_id, tuple(codes), digest.digest())


def entitlement_dictionary(result):
    if any(stream.lstrip().startswith((b"<?xml", b"<plist", b"bplist00")) for stream in (result.stdout, result.stderr)):
        return minimal.dictionary_plist(minimal.output_plist(result))
    # codesign emits no plist for a signature with no entitlements. The only
    # accepted diagnostic is its ordinary Executable line; never print the value.
    if result.stdout.strip() or any(not line.startswith(b"Executable=") for line in result.stderr.splitlines() if line.strip()):
        raise VerificationFailure("entitlements_missing_or_ambiguous")
    return {}


def validate_entitlements(result, code, team, bundle_id):
    values = entitlement_dictionary(result)
    identity = {"com.apple.application-identifier", "com.apple.developer.team-identifier"}
    if code.label == "main":
        allowed = identity | {"com.apple.security.app-sandbox", "com.apple.security.temporary-exception.mach-lookup.global-name"}
        if values.get("com.apple.security.app-sandbox") is not True:
            raise VerificationFailure("sandbox_required")
        names = values.get("com.apple.security.temporary-exception.mach-lookup.global-name")
        if (type(names) is not list or len(names) != 2 or any(type(name) is not str for name in names)
                or set(names) != {bundle_id + "-spks", bundle_id + "-spki"}):
            raise VerificationFailure("sparkle_mach_names_mismatch")
        app_ids = {team + "." + bundle_id}
    else:
        allowed = identity
        app_ids = {code.identifier, team + "." + code.identifier}
        if code.label == "autoupdate" and values.get("com.apple.application-identifier") not in app_ids:
            raise VerificationFailure("autoupdate_application_identifier_required")
    if any(key not in allowed for key in values):
        raise VerificationFailure("unexpected_entitlement")
    if "com.apple.application-identifier" in values and values["com.apple.application-identifier"] not in app_ids:
        raise VerificationFailure("entitlement_identity_mismatch")
    if "com.apple.developer.team-identifier" in values and values["com.apple.developer.team-identifier"] != team:
        raise VerificationFailure("entitlement_identity_mismatch")


def verify_app(app, *, stage, expected_team_id, expected_bundle_id, runner=run_tool, policy=POLICY):
    report = {"schema": "oneclip-update-distribution-preflight-v1", "policy": POLICY,
              "stage": stage if stage in {"signed", "distribution"} else "invalid", "status": "failed", "checks": [],
              "signed_preflight_passed": False, "distribution_preflight_passed": False,
              "distribution_acceptance_complete": False, "fresh_install_launch_verified": False,
              "offline_launch_verified": False, "update_roundtrip_verified": False, "atomic_inspection": False,
              "artifact_manifest_algorithm": MANIFEST_ALGORITHM, "artifact_manifest_sha256": None,
              "expected_team_id_sha256": None, "expected_bundle_id_sha256": None}
    def check(name, action):
        try: value = action()
        except VerificationFailure as error:
            report["checks"].append({"check": name, "passed": False, "reason": failure_code(error)}); raise
        report["checks"].append({"check": name, "passed": True, "reason": "verified"})
        return value
    try:
        if stage not in {"signed", "distribution"} or policy != POLICY:
            raise VerificationFailure("explicit_stage_and_policy_required")
        if type(expected_team_id) is not str or not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
            raise VerificationFailure("approved_team_required")
        if type(expected_bundle_id) is not str or not re.fullmatch(minimal.BUNDLE_ID_PATTERN, expected_bundle_id):
            raise VerificationFailure("approved_bundle_id_required")
        report["expected_team_id_sha256"] = hashlib.sha256(expected_team_id.encode()).hexdigest()
        report["expected_bundle_id_sha256"] = hashlib.sha256(expected_bundle_id.encode()).hexdigest()
        artifact = check("closed_sparkle_bundle_inventory", lambda: inspect_artifact(app, expected_bundle_id))
        report["artifact_manifest_sha256"] = artifact.digest.hex()
        for code in artifact.codes:
            requirement = ('=identifier "' + code.identifier + '" and anchor apple generic '
                           'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                           'and certificate leaf[subject.OU] = "' + expected_team_id + '"')
            check("strict_signature_" + code.label, lambda code=code, requirement=requirement: checked_tool(runner, (
                "/usr/bin/codesign", "--verify", "--strict=all", "--all-architectures", "--deep",
                "--test-requirement", requirement, str(code.owner))))
            for architecture in code.architectures:
                def metadata(code=code, architecture=architecture):
                    result = checked_tool(runner, ("/usr/bin/codesign", "--display", "--verbose=4", "--architecture", architecture, str(code.owner)))
                    minimal.validate_metadata(result, expected_team_id, code.identifier)
                check("signed_metadata_" + code.label + "_" + architecture, metadata)
                def entitlements(code=code, architecture=architecture):
                    result = checked_tool(runner, ("/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", "--architecture", architecture, str(code.owner)))
                    validate_entitlements(result, code, expected_team_id, expected_bundle_id)
                check("minimal_entitlements_" + code.label + "_" + architecture, entitlements)
        if stage == "distribution":
            check("stapled_notarization_ticket", lambda: checked_tool(runner, ("/usr/bin/xcrun", "stapler", "validate", "-q", str(artifact.path))))
            def enabled():
                result = checked_tool(runner, ("/usr/sbin/spctl", "--status"))
                if result.stdout.strip() != b"assessments enabled": raise VerificationFailure("gatekeeper_disabled_or_unknown")
            check("gatekeeper_enabled", enabled)
            def assessment():
                result = checked_tool(runner, ("/usr/sbin/spctl", "--assess", "--type", "execute", "--ignore-cache", "--no-cache", "--raw", str(artifact.path)))
                value = minimal.dictionary_plist(minimal.output_plist(result))
                authority = value.get("assessment:authority")
                if (value.get("assessment:verdict") is not True or not isinstance(authority, dict)
                        or authority.get("assessment:authority:source") != "Notarized Developer ID"):
                    raise VerificationFailure("notarized_policy_verdict_required")
            check("notarized_gatekeeper_assessment", assessment)
        def unchanged():
            if inspect_artifact(artifact.path, expected_bundle_id) != artifact:
                raise VerificationFailure("artifact_changed")
        check("artifact_unchanged_during_checks", unchanged)
        report["signed_preflight_passed"] = True
        report["distribution_preflight_passed"] = stage == "distribution"
        report["status"] = "passed_distribution_preflight" if stage == "distribution" else "passed_signed_preflight"
    except VerificationFailure as error: report["failure"] = failure_code(error)
    except (OSError, ValueError, TypeError, struct.error): report["failure"] = "artifact_or_result_unreadable"
    except Exception: report["failure"] = "verification_unexpected_error"
    return report


def main(arguments=None):
    parser = minimal.SafeArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--stage", required=True, choices=("signed", "distribution"))
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    parser.add_argument("--policy", choices=(POLICY,), default=POLICY)
    try:
        options = parser.parse_args(arguments)
        result = verify_app(options.app, stage=options.stage, expected_team_id=options.expected_team_id,
                            expected_bundle_id=options.expected_bundle_id, policy=options.policy)
    except VerificationFailure:
        result = {"schema": "oneclip-update-distribution-preflight-v1", "policy": POLICY,
                  "status": "failed", "failure": "invalid_arguments", "signed_preflight_passed": False,
                  "distribution_preflight_passed": False, "distribution_acceptance_complete": False}
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"].startswith("passed_") else 1

if __name__ == "__main__": sys.exit(main())
