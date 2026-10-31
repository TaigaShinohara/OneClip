"""Synthetic filesystem/tool fixtures only; never invokes codesign, spctl or an app."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "oneclip_distribution_verification",
    Path(__file__).resolve().parents[1] / "scripts" / "verify_distribution.py",
)
verification = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verification
SPEC.loader.exec_module(verification)

TEAM = "ABCDEFGHIJ"
BUNDLE_ID = "test.OneClip"
PRIVATE_DIAGNOSTIC = "Synthetic Private Contributor /private/synthetic-not-for-report"
METADATA = (
    "Executable=" + PRIVATE_DIAGNOSTIC + "/OneClip\n"
    "Identifier=" + BUNDLE_ID + "\n"
    "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+1 location=embedded\n"
    "Signature size=9000\n"
    "Authority=Developer ID Application: Synthetic Private Contributor (" + TEAM + ")\n"
    "Authority=Developer ID Certification Authority\n"
    "Authority=Apple Root CA\n"
    "Timestamp=Oct 31, 2026 at 12:00:00 PM\n"
    "TeamIdentifier=" + TEAM + "\n"
)


def thin(cpu=0x0100000C, subtype=0):
    return struct.pack("<8I", 0xFEEDFACF, cpu, subtype, 2, 0, 0, 0, 0)


def universal():
    first, second = thin(), thin(0x01000007, 3)
    return (struct.pack(">II", 0xCAFEBABE, 2)
            + struct.pack(">IIIII", 0x0100000C, 0, 48, len(first), 0)
            + struct.pack(">IIIII", 0x01000007, 3, 80, len(second), 0)
            + first + second)


class FakeTools:
    def __init__(self):
        self.calls = []
        self.metadata = METADATA
        self.metadata_by_arch = {}
        self.entitlements = plistlib.dumps({"com.apple.security.app-sandbox": True})
        self.entitlements_by_arch = {}
        self.failures = {}
        self.on_call = None
        self.enabled = b"assessments enabled\n"
        self.assessment = plistlib.dumps({
            "assessment:verdict": True,
            "assessment:authority": {
                "assessment:authority:flags": 2,
                "assessment:authority:row": 11,
                "assessment:authority:source": "Notarized Developer ID",
            },
            "assessment:remote": True,
        })

    def __call__(self, arguments):
        self.calls.append(arguments)
        if arguments[0] == "/usr/bin/codesign":
            if "--verify" in arguments:
                operation = "signature"
                result = verification.ToolResult(0)
            else:
                arch = arguments[arguments.index("--architecture") + 1]
                if "--entitlements" in arguments:
                    operation = "entitlements"
                    result = verification.ToolResult(
                        0, self.entitlements_by_arch.get(arch, self.entitlements),
                        ("Executable=" + PRIVATE_DIAGNOSTIC).encode(),
                    )
                else:
                    operation = "metadata"
                    result = verification.ToolResult(
                        0, stderr=self.metadata_by_arch.get(arch, self.metadata).encode(),
                    )
        elif arguments[:3] == ("/usr/bin/xcrun", "stapler", "validate"):
            operation = "stapler"
            result = verification.ToolResult(0)
        elif arguments == ("/usr/sbin/spctl", "--status"):
            operation = "gatekeeper_status"
            result = verification.ToolResult(0, self.enabled)
        elif arguments[0] == "/usr/sbin/spctl" and "--assess" in arguments:
            operation = "assessment"
            result = verification.ToolResult(0, self.assessment)
        else:
            raise AssertionError("Unexpected command in a synthetic fixture")
        if self.on_call:
            self.on_call(operation)
        failure = self.failures.get(operation)
        if isinstance(failure, Exception):
            raise failure
        return failure if failure is not None else result


class DistributionVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Synthetic.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        self.info = self.app / "Contents" / "Info.plist"
        self.info.write_bytes(plistlib.dumps({
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "OneClip",
            "CFBundleIdentifier": BUNDLE_ID,
        }))
        self.executable = self.app / "Contents" / "MacOS" / "OneClip"
        self.executable.write_bytes(thin())
        self.executable.chmod(0o755)
        self.tools = FakeTools()

    def verify(self, stage="signed", **kwargs):
        values = dict(stage=stage, policy=verification.POLICY, expected_team_id=TEAM,
                      expected_bundle_id=BUNDLE_ID, runner=self.tools)
        values.update(kwargs)
        result = verification.verify_app(self.app, **values)
        serialized = json.dumps(result)
        for private_value in (str(self.app), PRIVATE_DIAGNOSTIC, TEAM, BUNDLE_ID):
            self.assertNotIn(private_value, serialized)
        return result

    def assert_failed(self, result):
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["signed_preflight_passed"])
        self.assertFalse(result["distribution_preflight_passed"])

    def test_signed_success_is_not_distribution_acceptance(self):
        result = self.verify()
        self.assertEqual(result["status"], "passed_signed_preflight")
        self.assertTrue(result["signed_preflight_passed"])
        self.assertFalse(result["distribution_preflight_passed"])
        self.assertFalse(result["distribution_acceptance_complete"])
        self.assertFalse(result["fresh_install_launch_verified"])
        self.assertFalse(result["offline_launch_verified"])
        self.assertFalse(any(call[0] != "/usr/bin/codesign" for call in self.tools.calls))
        command = self.tools.calls[0]
        for option in ("--verify", "--deep", "--strict=all", "--all-architectures"):
            self.assertIn(option, command)
        requirement = command[command.index("--test-requirement") + 1]
        self.assertTrue(requirement.startswith("="))
        self.assertIn("anchor apple generic", requirement)
        self.assertIn("1.2.840.113635.100.6.1.13", requirement)
        self.assertIn('certificate leaf[subject.OU] = "' + TEAM + '"', requirement)
        self.assertIn('identifier "' + BUNDLE_ID + '"', requirement)
        self.assertEqual(result["artifact_manifest_algorithm"], verification.MANIFEST_ALGORITHM)
        self.assertRegex(result["artifact_manifest_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(result["expected_bundle_id_sha256"], hashlib.sha256(BUNDLE_ID.encode()).hexdigest())
        self.assertEqual(result["expected_team_id_sha256"], hashlib.sha256(TEAM.encode()).hexdigest())

    def test_distribution_requires_staple_and_notarized_policy_verdict(self):
        result = self.verify("distribution")
        self.assertEqual(result["status"], "passed_distribution_preflight")
        self.assertTrue(result["distribution_preflight_passed"])
        self.assertFalse(result["distribution_acceptance_complete"])
        self.assertTrue(any(call[:3] == ("/usr/bin/xcrun", "stapler", "validate") for call in self.tools.calls))
        assessment = next(call for call in self.tools.calls if "--assess" in call)
        self.assertIn("--ignore-cache", assessment)
        self.assertIn("--no-cache", assessment)

    def test_unsigned_or_tool_rejected_signature_fails_without_diagnostics(self):
        self.tools.failures["signature"] = verification.ToolResult(1, stderr=PRIVATE_DIAGNOSTIC.encode())
        result = self.verify()
        self.assert_failed(result)
        self.assertEqual(len(self.tools.calls), 1)

    def test_ad_hoc_development_and_linker_signatures_are_rejected(self):
        fixtures = [
            METADATA.replace("Authority=Developer ID Application:", "Authority=Apple Development:"),
            METADATA.replace("Signature size=9000", "Signature=adhoc"),
            METADATA.replace("flags=0x10000(runtime)", "flags=0x10002(adhoc,runtime)"),
            METADATA.replace("flags=0x10000(runtime)", "flags=0x30000(runtime,linker-signed)"),
        ]
        for metadata in fixtures:
            with self.subTest(metadata_category=fixtures.index(metadata)):
                self.tools.metadata = metadata
                self.assert_failed(self.verify())

    def test_runtime_and_secure_timestamp_must_be_present(self):
        fixtures = [
            METADATA.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
            METADATA.replace("Timestamp=", "Signed Time="),
            METADATA.replace("Timestamp=Oct 31, 2026 at 12:00:00 PM", "Timestamp=none"),
            METADATA.replace("Timestamp=Oct 31, 2026 at 12:00:00 PM", "Timestamp="),
        ]
        for index, metadata in enumerate(fixtures):
            with self.subTest(category=index):
                self.tools.metadata = metadata
                self.assert_failed(self.verify())

    def test_unknown_or_mismatched_identity_and_ambiguous_metadata_fail(self):
        for metadata in (
            METADATA.replace("TeamIdentifier=" + TEAM, "TeamIdentifier=not set"),
            METADATA.replace("TeamIdentifier=" + TEAM, "TeamIdentifier=ZZZZZZZZZZ"),
            METADATA.replace("Identifier=" + BUNDLE_ID, "Identifier=test.Other"),
            METADATA + "TeamIdentifier=" + TEAM + "\n",
        ):
            self.tools.metadata = metadata
            self.assert_failed(self.verify())
        self.assert_failed(self.verify(expected_team_id=""))
        self.assert_failed(self.verify(expected_team_id='" or true'))

    def test_sandbox_requires_actual_boolean_true(self):
        for value in (None, False, "true", 1, [], {}):
            with self.subTest(value_type=type(value).__name__):
                entitlements = {} if value is None else {"com.apple.security.app-sandbox": value}
                self.tools.entitlements = plistlib.dumps(entitlements)
                self.assert_failed(self.verify())

    def test_debuggable_and_other_exceptions_require_absent_or_boolean_false(self):
        for key in sorted(verification.DISABLED_ENTITLEMENTS):
            for value in (True, "true", "false", 1, 0, [], {}):
                with self.subTest(key=key, value_type=type(value).__name__):
                    self.tools.entitlements = plistlib.dumps({
                        "com.apple.security.app-sandbox": True, key: value,
                    })
                    self.assert_failed(self.verify())
        self.tools.entitlements = plistlib.dumps({
            "com.apple.security.app-sandbox": True,
            **{key: False for key in verification.DISABLED_ENTITLEMENTS},
        })
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")

    def test_unknown_privileged_entitlement_is_rejected_even_if_false(self):
        for key in ("com.apple.security.temporary-exception.files.absolute-path.read-write",
                    "com.apple.security.files.user-selected.read-write", "unknown.fixture"):
            for value in (True, False):
                self.tools.entitlements = plistlib.dumps({"com.apple.security.app-sandbox": True, key: value})
                self.assert_failed(self.verify())

    def test_optional_identity_entitlements_must_match_approved_identity(self):
        self.tools.entitlements = plistlib.dumps({
            "com.apple.security.app-sandbox": True,
            "com.apple.application-identifier": TEAM + "." + BUNDLE_ID,
            "com.apple.developer.team-identifier": TEAM,
        })
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")
        self.tools.entitlements = plistlib.dumps({
            "com.apple.security.app-sandbox": True,
            "com.apple.developer.team-identifier": "ZZZZZZZZZZ",
        })
        self.assert_failed(self.verify())

    def test_missing_invalid_duplicate_or_nondictionary_entitlements_fail(self):
        fixtures = [b"", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps([]),
                    b"<?xml version='1.0'?><plist><dict>"
                    b"<key>com.apple.security.app-sandbox</key><true/>"
                    b"<key>com.apple.security.get-task-allow</key><true/>"
                    b"<key>com.apple.security.get-task-allow</key><false/>"
                    b"</dict></plist>"]
        for index, payload in enumerate(fixtures):
            with self.subTest(category=index):
                self.tools.entitlements = payload
                self.assert_failed(self.verify())

    def test_missing_and_invalid_info_plist_stop_before_tools(self):
        self.info.unlink()
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])
        self.info.write_bytes(b"<?xml version='1.0'?><plist><dict>")
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])

    def test_bundle_executable_cannot_escape_its_fixed_location(self):
        self.info.write_bytes(plistlib.dumps({
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "../../outside",
            "CFBundleIdentifier": BUNDLE_ID,
        }))
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])

    def test_approved_bundle_id_is_mandatory_and_rejects_malformed_values(self):
        for identifier in (None, "", "NoDot", "test.bad/path", 'test.bad" or true', "test.bad_id", 1):
            with self.subTest(value_type=type(identifier).__name__):
                self.assert_failed(self.verify(expected_bundle_id=identifier))
        self.assertEqual(self.tools.calls, [])
        with self.assertRaises(TypeError):
            verification.verify_app(self.app, stage="signed", policy=verification.POLICY,
                                    expected_team_id=TEAM, runner=self.tools)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = verification.main(["--app", str(self.app), "--stage", "signed",
                                      "--policy", verification.POLICY, "--expected-team-id", TEAM])
        self.assertEqual(code, 1)
        report = json.loads(output.getvalue())
        self.assertEqual(report["failure"], "invalid_arguments")
        self.assertIsNone(report["artifact_manifest_sha256"])
        self.assertNotIn(str(self.app), output.getvalue())
        self.assertNotIn(TEAM, output.getvalue())

    def test_other_app_from_same_team_cannot_use_a_matching_self_declared_identity(self):
        other_id = "test.OtherApp"
        info = plistlib.loads(self.info.read_bytes())
        info["CFBundleIdentifier"] = other_id
        self.info.write_bytes(plistlib.dumps(info))
        self.tools.metadata = METADATA.replace(BUNDLE_ID, other_id)
        result = self.verify()
        self.assert_failed(result)
        self.assertEqual(result["failure"], "approved_bundle_id_mismatch")
        self.assertEqual(self.tools.calls, [])

    def test_success_report_is_bound_to_candidate_bytes_but_not_local_path(self):
        resource = self.app / "Contents" / "resource.txt"
        resource.write_bytes(b"synthetic before")
        before = self.verify()
        self.assertEqual(before["status"], "passed_signed_preflight")
        copied_app = Path(self.temporary.name) / "DifferentLocalName.app"
        shutil.copytree(self.app, copied_app)
        copied = verification.verify_app(
            copied_app, stage="signed", policy=verification.POLICY,
            expected_team_id=TEAM, expected_bundle_id=BUNDLE_ID, runner=FakeTools(),
        )
        self.assertEqual(copied["status"], "passed_signed_preflight")
        self.assertEqual(copied["artifact_manifest_sha256"], before["artifact_manifest_sha256"])
        resource.write_bytes(b"synthetic after")
        after = self.verify()
        self.assertEqual(after["status"], "passed_signed_preflight")
        self.assertNotEqual(after["artifact_manifest_sha256"], before["artifact_manifest_sha256"])
        self.assertNotEqual(after, before)

    def test_timeout_tool_unavailability_and_unexpected_errors_fail_closed(self):
        for failure in (subprocess.TimeoutExpired(PRIVATE_DIAGNOSTIC, 30),
                        FileNotFoundError(PRIVATE_DIAGNOSTIC), RuntimeError(PRIVATE_DIAGNOSTIC)):
            self.tools.failures["signature"] = failure
            self.assert_failed(self.verify())

    def test_default_runner_uses_no_shell_stdin_or_credential_environment(self):
        completed = subprocess.CompletedProcess(["fixture"], 0, b"", b"")
        with mock.patch.object(verification.subprocess, "run", return_value=completed) as run:
            verification.run_tool(("/usr/bin/codesign", "--verify", "fixture.app"))
        kwargs = run.call_args.kwargs
        self.assertFalse(kwargs["shell"])
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertGreater(kwargs["timeout"], 0)
        self.assertEqual(set(kwargs["env"]), {"PATH", "LANG", "LC_ALL"})

    def test_notarization_failure_is_not_a_distribution_pass(self):
        self.tools.failures["stapler"] = verification.ToolResult(65, stderr=PRIVATE_DIAGNOSTIC.encode())
        self.assert_failed(self.verify("distribution"))
        self.assertFalse(any("--assess" in call for call in self.tools.calls))

    def test_disabled_or_unknown_gatekeeper_cannot_pass(self):
        for status in (b"assessments disabled\n", b"", b"unknown\n"):
            self.tools.enabled = status
            self.assert_failed(self.verify("distribution"))

    def test_policy_assessment_requires_real_notarized_boolean_verdict(self):
        fixtures = [
            {"assessment:verdict": False, "assessment:authority": {"assessment:authority:source": "Notarized Developer ID"}},
            {"assessment:verdict": "true", "assessment:authority": {"assessment:authority:source": "Notarized Developer ID"}},
            {"assessment:verdict": True, "assessment:authority": {"assessment:authority:source": "Developer ID"}},
            {"assessment:verdict": True, "assessment:authority": {"assessment:authority:source": "User Defined"}},
            {},
        ]
        for payload in fixtures:
            self.tools.assessment = plistlib.dumps(payload)
            self.assert_failed(self.verify("distribution"))
        self.tools.assessment = b"<?xml version='1.0'?><plist><dict>"
        self.assert_failed(self.verify("distribution"))

    def test_gatekeeper_raw_public_schema_accepts_namespaced_source(self):
        # Shape from Apple's SecAssessment keys and actual spctl --raw output.
        # Public classifications only: no originator, path, or signer identity.
        self.tools.assessment = plistlib.dumps({
            "assessment:authority": {
                "assessment:authority:flags": 2,
                "assessment:authority:row": 11,
                "assessment:authority:source": "Notarized Developer ID",
            },
            "assessment:remote": True,
            "assessment:verdict": True,
        })
        self.assertEqual(self.verify("distribution")["status"], "passed_distribution_preflight")

    def test_gatekeeper_bare_source_alias_and_misspelled_keys_fail_closed(self):
        for key in ("source", "assessment:source", "assessment:authority:soruce"):
            with self.subTest(key=key):
                self.tools.assessment = plistlib.dumps({
                    "assessment:authority": {key: "Notarized Developer ID"},
                    "assessment:remote": True,
                    "assessment:verdict": True,
                })
                result = self.verify("distribution")
                self.assert_failed(result)
                self.assertEqual(result["failure"], "notarized_policy_verdict_required")

    def test_gatekeeper_canonical_source_type_value_and_verdict_are_strict(self):
        for source in ("Developer ID", "User Defined", "notarized developer id",
                       "Notarized Developer ID ", True, ["Notarized Developer ID"]):
            with self.subTest(source_type=type(source).__name__):
                self.tools.assessment = plistlib.dumps({
                    "assessment:authority": {"assessment:authority:source": source},
                    "assessment:verdict": True,
                })
                self.assert_failed(self.verify("distribution"))
        for verdict in (False, "true", 1, 0):
            with self.subTest(verdict_type=type(verdict).__name__):
                self.tools.assessment = plistlib.dumps({
                    "assessment:authority": {"assessment:authority:source": "Notarized Developer ID"},
                    "assessment:verdict": verdict,
                })
                self.assert_failed(self.verify("distribution"))

    def test_each_universal_slice_has_its_own_metadata_and_entitlement_checks(self):
        self.executable.write_bytes(universal())
        self.assertEqual(self.verify()["status"], "passed_signed_preflight")
        self.tools.entitlements_by_arch["x86_64"] = plistlib.dumps({
            "com.apple.security.app-sandbox": True, "com.apple.security.get-task-allow": True,
        })
        self.assert_failed(self.verify())
        del self.tools.entitlements_by_arch["x86_64"]
        self.tools.metadata_by_arch["x86_64"] = METADATA.replace("flags=0x10000(runtime)", "flags=0x0(none)")
        self.assert_failed(self.verify())

    def test_malformed_fat_ranges_and_unknown_architecture_fail_before_tools(self):
        self.executable.write_bytes(struct.pack(">II", 0xCAFEBABE, 2)
                                    + struct.pack(">IIIII", 0x0100000C, 0, 48, 32, 0)
                                    + struct.pack(">IIIII", 0x01000007, 3, 48, 32, 0) + thin())
        self.assert_failed(self.verify())
        self.executable.write_bytes(thin(cpu=12))
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])

    def test_nested_macho_and_hidden_executable_script_require_policy_extension(self):
        nested = self.app / "Contents" / "extra"
        nested.write_bytes(thin())
        self.assert_failed(self.verify())
        nested.write_text("#!/bin/sh\nexit 0\n")
        nested.chmod(0o755)
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])

    def test_nested_bundle_and_symlink_are_not_silently_assessed_as_root_code(self):
        nested = self.app / "Contents" / "Helper.xpc"
        nested.mkdir()
        self.assert_failed(self.verify())
        nested.rmdir()
        (self.app / "Contents" / "link").symlink_to(self.info)
        self.assert_failed(self.verify())
        self.assertEqual(self.tools.calls, [])

    def test_artifact_change_during_checks_invalidates_preflight(self):
        resource = self.app / "Contents" / "resource.txt"
        resource.write_text("before")
        self.tools.on_call = lambda operation: resource.write_text("after") if operation == "entitlements" else None
        result = self.verify()
        self.assert_failed(result)
        self.assertEqual(result["failure"], "artifact_changed")

    def test_stage_policy_and_approved_signer_are_explicit(self):
        self.assert_failed(self.verify(stage="invalid"))
        self.assert_failed(self.verify(policy="unknown-policy"))
        self.assertEqual(self.tools.calls, [])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = verification.main(["--app", PRIVATE_DIAGNOSTIC])
        self.assertEqual(code, 1)
        self.assertNotIn(PRIVATE_DIAGNOSTIC, output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["failure"], "invalid_arguments")


if __name__ == "__main__":
    unittest.main()
