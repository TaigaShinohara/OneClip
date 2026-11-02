"""Synthetic files and injected tools only; never signs, launches or installs code."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "oneclip_update_distribution_verification", Path(__file__).resolve().parents[1] / "scripts/verify_update_distribution.py")
verification = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verification
SPEC.loader.exec_module(verification)
TEAM = "ABCDEFGHIJ"
BUNDLE = "test.OneClip"
PRIVATE = "Synthetic Private Contributor /private/synthetic-secret-not-for-report"


def universal(kind=2):
    def thin(cpu, subtype): return struct.pack("<8I", 0xFEEDFACF, cpu, subtype, kind, 0, 0, 0, 0)
    arm, intel = thin(0x0100000C, 0), thin(0x01000007, 3)
    return (struct.pack(">II", 0xCAFEBABE, 2)
            + struct.pack(">IIIII", 0x0100000C, 0, 48, 32, 0)
            + struct.pack(">IIIII", 0x01000007, 3, 80, 32, 0) + arm + intel)


def metadata(identifier):
    return ("Executable=" + PRIVATE + "\nIdentifier=" + identifier + "\n"
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+1 location=embedded\n"
            "Signature size=9000\nAuthority=Developer ID Application: Synthetic Private Contributor (" + TEAM + ")\n"
            "Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n"
            "Timestamp=Nov 2, 2026 at 12:00:00 PM\nTeamIdentifier=" + TEAM + "\n")


def secure_info():
    return {"CFBundlePackageType": "APPL", "CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "OneClip",
            "CFBundleVersion": "2", "CFBundleShortVersionString": "0.2.0", "OneClipUpdateChannel": "stable",
            "SUFeedURL": verification.FEED_URL, "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
            **{key: True for key in ("SUEnableInstallerLauncherService", "SUEnableDownloaderService", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction")},
            **{key: False for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUEnableJavaScript", "SUShowReleaseNotes")},
            "SUSignedFeedFailureExpirationInterval": 0}


class FakeTools:
    def __init__(self, app):
        self.codes = {str((app / owner).resolve()): (label, identifier or BUNDLE)
                      for label, owner, _, identifier, _ in verification.OWNERS}
        self.calls = []
        self.metadata = {}
        self.entitlements = {}
        self.failures = {}
        self.on_call = None
        self.assessment = {"assessment:verdict": True,
            "assessment:authority": {"assessment:authority:source": "Notarized Developer ID"}}
        self.gatekeeper = b"assessments enabled\n"

    def __call__(self, args):
        self.calls.append(args)
        label, arch = "global", None
        if args[0] == "/usr/bin/codesign":
            label, identifier = self.codes[str(Path(args[-1]).resolve())]
            if "--verify" in args:
                operation = "signature"
                result = verification.ToolResult(0)
            else:
                arch = args[args.index("--architecture") + 1]
                if "--entitlements" in args:
                    operation = "entitlements"
                    if label == "main":
                        data = {"com.apple.security.app-sandbox": True,
                                "com.apple.security.temporary-exception.mach-lookup.global-name": [BUNDLE + "-spks", BUNDLE + "-spki"]}
                    elif label == "autoupdate": data = {"com.apple.application-identifier": identifier}
                    elif label == "sparkle": data = None
                    else: data = {}
                    data = self.entitlements.get((label, arch), data)
                    result = verification.ToolResult(0, b"" if data is None else plistlib.dumps(data), ("Executable=" + PRIVATE).encode())
                else:
                    operation = "metadata"
                    result = verification.ToolResult(0, stderr=self.metadata.get((label, arch), metadata(identifier)).encode())
        elif args[:3] == ("/usr/bin/xcrun", "stapler", "validate"):
            operation = "stapler"; result = verification.ToolResult(0)
        elif args == ("/usr/sbin/spctl", "--status"):
            operation = "gatekeeper"; result = verification.ToolResult(0, self.gatekeeper)
        elif args[0] == "/usr/sbin/spctl" and "--assess" in args:
            operation = "assessment"; result = verification.ToolResult(0, plistlib.dumps(self.assessment))
        else: raise AssertionError("Unexpected synthetic command")
        if self.on_call: self.on_call(label, operation, arch)
        failure = self.failures.get((label, operation, arch))
        if isinstance(failure, Exception): raise failure
        return result if failure is None else failure


class UpdateDistributionVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Synthetic.app"
        self.info = self.app / "Contents/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps(secure_info()))
        for _, _, executable, _, kind in verification.OWNERS:
            path = self.app / executable; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(universal(kind)); path.chmod(0o755)
        for relative, identifier, executable, kind in verification.BUNDLE_INFOS:
            path = self.app / relative; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundlePackageType": kind, "CFBundleVersion": "2065", "CFBundleShortVersionString": "2.10.1"}))
        for name in ("Headers", "PrivateHeaders", "Modules"):
            (self.app / verification.VERSION / name).mkdir()
        for relative, target in verification.ALIASES.items():
            path = self.app / relative; path.parent.mkdir(parents=True, exist_ok=True); path.symlink_to(target)
        self.resource = self.app / verification.VERSION / "Resources/synthetic.txt"
        self.resource.write_text("synthetic resource")
        self.tools = FakeTools(self.app)

    def verify(self, stage="signed", **kwargs):
        args = {"stage": stage, "expected_team_id": TEAM, "expected_bundle_id": BUNDLE, "runner": self.tools}
        args.update(kwargs)
        result = verification.verify_app(self.app, **args)
        output = json.dumps(result)
        for secret in (str(self.app), TEAM, BUNDLE, PRIVATE): self.assertNotIn(secret, output)
        return result

    def failed(self, result):
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["signed_preflight_passed"])
        self.assertFalse(result["distribution_preflight_passed"])

    def update_info(self, **changes):
        info = plistlib.loads(self.info.read_bytes()); info.update(changes)
        self.info.write_bytes(plistlib.dumps(info))

    def test_known_runtime_signed_all_components_and_architectures(self):
        result = self.verify()
        self.assertEqual(result["status"], "passed_signed_preflight")
        self.assertFalse(result["distribution_preflight_passed"])
        self.assertFalse(result["update_roundtrip_verified"])
        self.assertRegex(result["artifact_manifest_sha256"], r"^[a-f0-9]{64}$")
        signed = [call for call in self.tools.calls if "--verify" in call]
        self.assertEqual(len(signed), 6)
        displays = [call for call in self.tools.calls if "--verbose=4" in call]
        self.assertEqual(len(displays), 12)
        for call in signed:
            self.assertIn("--all-architectures", call)
            requirement = call[call.index("--test-requirement") + 1]
            self.assertTrue(requirement.startswith("=identifier"))
            self.assertIn("anchor apple generic", requirement)
            self.assertIn("certificate leaf[subject.OU]", requirement)

    def test_distribution_requires_ticket_enabled_gatekeeper_and_boolean_verdict(self):
        result = self.verify("distribution")
        self.assertEqual(result["status"], "passed_distribution_preflight")
        self.assertFalse(result["fresh_install_launch_verified"])
        self.assertFalse(result["offline_launch_verified"])
        self.assertFalse(result["distribution_acceptance_complete"])
        for verdict in (False, 1, "true", None):
            self.tools.assessment["assessment:verdict"] = verdict
            self.failed(self.verify("distribution"))
        self.tools.assessment["assessment:verdict"] = True
        self.tools.assessment["assessment:authority"] = {"source": "Notarized Developer ID"}
        self.failed(self.verify("distribution"))
        self.tools.assessment["assessment:authority"] = {"assessment:authority:source": "Notarized Developer ID"}
        self.tools.gatekeeper = b"assessments disabled\n"
        self.failed(self.verify("distribution"))

    def test_unknown_nested_code_executable_and_macho_are_rejected(self):
        cases = [("Contents/Evil.app", None, False), ("Contents/Resources/secret.sh", b"#!/bin/sh\n", True),
                 ("Contents/Resources/hidden.bin", universal(), False)]
        for relative, content, executable in cases:
            with self.subTest(category=relative):
                path = self.app / relative
                if content is None: path.mkdir(parents=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content)
                    if executable: path.chmod(0o755)
                self.failed(self.verify())
                if path.is_dir(): path.rmdir()
                else: path.unlink()

    def test_only_canonical_framework_aliases_are_accepted(self):
        alias = self.app / verification.FRAMEWORK / "Sparkle"
        alias.unlink(); alias.symlink_to("/private/secret-outside")
        self.failed(self.verify())
        alias.unlink(); alias.symlink_to("Versions/Current/Sparkle")
        other = self.app / "Contents/Resources/extra-link"; other.parent.mkdir(parents=True)
        other.symlink_to(self.resource)
        self.failed(self.verify())
        other.unlink()
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")
        alias.unlink()
        self.failed(self.verify())

    def test_component_version_identity_and_macho_type_are_pinned(self):
        framework_info = self.app / verification.BUNDLE_INFOS[0][0]
        original = framework_info.read_bytes(); info = plistlib.loads(original)
        for key, value in (("CFBundleShortVersionString", "2.11.0"), ("CFBundleVersion", "2066"), ("CFBundleIdentifier", "test.Evil")):
            changed = dict(info); changed[key] = value; framework_info.write_bytes(plistlib.dumps(changed))
            self.failed(self.verify())
        framework_info.write_bytes(original)
        framework = self.app / verification.VERSION / "Sparkle"
        framework.write_bytes(universal(2))
        self.failed(self.verify())

    def test_each_slice_and_helper_requires_approved_signer_runtime_timestamp(self):
        for label, _, _, identifier, _ in verification.OWNERS:
            identifier = identifier or BUNDLE
            for arch in ("arm64", "x86_64"):
                for altered in (metadata(identifier).replace("TeamIdentifier=" + TEAM, "TeamIdentifier=ZZZZZZZZZZ"),
                                metadata(identifier).replace("flags=0x10000(runtime)", "flags=0x10002(adhoc,runtime)"),
                                metadata(identifier).replace("Timestamp=Nov 2, 2026 at 12:00:00 PM", "Timestamp=none")):
                    self.tools.metadata[(label, arch)] = altered
                    self.failed(self.verify())
                self.tools.metadata.pop((label, arch))

    def test_main_capabilities_and_helper_entitlements_fail_closed(self):
        for label, _, _, identifier, _ in verification.OWNERS:
            for key in ("com.apple.security.network.client", "com.apple.security.cs.disable-library-validation", "com.apple.security.get-task-allow", "test.unexpected"):
                data = {"com.apple.security.app-sandbox": True,
                        "com.apple.security.temporary-exception.mach-lookup.global-name": [BUNDLE + "-spks", BUNDLE + "-spki"]} if label == "main" else {}
                if label == "autoupdate": data["com.apple.application-identifier"] = identifier
                data[key] = False
                self.tools.entitlements[(label, "x86_64")] = data
                self.failed(self.verify())
                self.tools.entitlements.clear()
        for data in ({}, {"com.apple.security.app-sandbox": 1},
                     {"com.apple.security.app-sandbox": True, "com.apple.security.temporary-exception.mach-lookup.global-name": [BUNDLE + "-spks", "other-spki"]}):
            self.tools.entitlements[("main", "arm64")] = data
            self.failed(self.verify())
        self.tools.entitlements.clear()
        self.tools.entitlements[("autoupdate", "arm64")] = {}
        self.failed(self.verify())

    def test_updates_are_manual_and_signed_feed_is_required(self):
        original = self.info.read_bytes()
        for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUEnableJavaScript", "SUShowReleaseNotes"):
            self.update_info(**{key: True}); self.failed(self.verify()); self.info.write_bytes(original)
        for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableInstallerLauncherService", "SUEnableDownloaderService"):
            self.update_info(**{key: 1}); self.failed(self.verify()); self.info.write_bytes(original)
        for changes in ({"SUSignedFeedFailureExpirationInterval": 1}, {"SUFeedURL": "https://example.invalid/other"},
                        {"SUPublicEDKey": "invalid"}, {"OneClipUpdateChannel": "nightly"},
                        {"CFBundleVersion": "1"}, {"CFBundleShortVersionString": "0.2.0\n"}):
            self.update_info(**changes); self.failed(self.verify()); self.info.write_bytes(original)
        self.update_info(OneClipUpdateChannel="development", CFBundleShortVersionString="0.2.1-dev.1", CFBundleVersion="3")
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")

    def test_artifact_mutation_during_tools_is_rejected(self):
        changed = []
        def mutate(label, operation, architecture):
            if operation == "metadata" and not changed:
                self.resource.write_text("changed after inventory"); changed.append(True)
        self.tools.on_call = mutate
        result = self.verify()
        self.failed(result)
        self.assertEqual(result["failure"], "artifact_changed")

    def test_tool_failure_oversize_and_unknown_classification_do_not_leak(self):
        key = ("main", "metadata", "arm64")
        failures = [verification.ToolResult(1, stderr=PRIVATE.encode()),
                    verification.ToolResult(0, b"x" * (verification.minimal.MAX_TOOL_OUTPUT + 1)),
                    subprocess.TimeoutExpired("private command", 1),
                    verification.VerificationFailure(PRIVATE)]
        for failure in failures:
            self.tools.failures[key] = failure
            self.failed(self.verify())
        self.tools.failures.clear()
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")

    def test_cli_invalid_arguments_never_echo_paths_or_values(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = verification.main(["--app", PRIVATE, "--stage", "invalid", "--expected-team-id", TEAM,
                                      "--expected-bundle-id", BUNDLE])
        self.assertEqual(code, 1)
        for value in (PRIVATE, TEAM, BUNDLE): self.assertNotIn(value, output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["failure"], "invalid_arguments")

    def test_universal_release_requires_both_architectures_for_every_component(self):
        path = self.app / "Contents/MacOS/OneClip"
        path.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
        self.failed(self.verify())

if __name__ == "__main__": unittest.main()
