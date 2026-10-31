"""Disposable Git/ZIP fixtures only; no network, signing, build or app execution."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


surface = load("oneclip_security_surface", "audit_public_security_surface.py")
distribution = load("oneclip_distribution_for_surface", "verify_distribution.py")


class SecuritySurfaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "public"
        self.repo.mkdir()
        self.command("init", "--quiet", "--initial-branch=main", "--template=")
        self.command("config", "user.name", "TaigaShinohara")
        self.command("config", "user.email", "12345+synthetic@users.noreply.github.com")
        self.command("config", "commit.gpgsign", "false")
        self.command("remote", "add", "origin", "https://github.com/TaigaShinohara/OneClip.git")

    def command(self, *arguments):
        return surface.git(self.repo, *arguments)

    def commit(self, text):
        (self.repo / "README.md").write_text(text)
        self.command("-c", "core.hooksPath=/dev/null", "add", "--all")
        self.command("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Synthetic public fixture")
        return self.command("rev-parse", "HEAD").decode().strip()

    def audit(self, tip):
        return surface.audit(self.repo, [tip])

    def candidate(self, extra=None):
        app = self.root / "OneClip.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "OneClip", "CFBundleIdentifier": "test.OneClip", "CFBundlePackageType": "APPL",
        }))
        main = app / "Contents" / "MacOS" / "OneClip"
        main.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
        main.chmod(0o755)
        if extra is not None:
            (app / "Contents" / "resource.txt").write_bytes(extra)
        digest = distribution.inspect_artifact(app).digest.hex()
        archive_path = self.root / "candidate.zip"
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(app, app.name + "/")
            for item in sorted(app.rglob("*")):
                archive.write(item, app.name + "/" + item.relative_to(app).as_posix())
        return archive_path, hashlib.sha256(archive_path.read_bytes()).hexdigest(), digest

    def test_clean_public_history_reports_bounded_selected_coverage(self):
        self.commit("# First synthetic public version\n")
        tip = self.commit("# Second synthetic public version\n")
        report = self.audit(tip)
        self.assertEqual(report["status"], "passed_selected_scope")
        self.assertEqual(report["repository"]["commits_reviewed"], 2)
        self.assertFalse(report["remote_surfaces_inventory_complete"])
        self.assertEqual(report["repository"]["findings"], [])

    def test_secret_removed_from_head_remains_detected_in_reachable_history_without_echo(self):
        value = "gh" + "p_" + "A" * 35
        earlier = self.commit(value)
        tip = self.commit("# Clean current version\n")
        report = self.audit(tip)
        self.assertEqual(report["status"], "findings_require_review")
        self.assertTrue(any(item["commit"] == earlier and item["category"] == "GitHub token"
                            for item in report["repository"]["findings"]))
        self.assertNotIn(value, json.dumps(report))

    def test_unselected_private_branch_and_reflog_are_not_traversed(self):
        public_tip = self.commit("# Public\n")
        self.command("checkout", "--quiet", "--orphan", "private-fixture")
        self.commit("/" + "Users/" + "synthetic/private-fixture")
        self.command("checkout", "--quiet", "main")
        report = self.audit(public_tip)
        self.assertEqual(report["status"], "passed_selected_scope")
        self.assertEqual(report["repository"]["commits_reviewed"], 1)

    def test_private_origin_and_unresolved_public_tip_fail_closed(self):
        tip = self.commit("# Public\n")
        self.command("remote", "set-url", "origin", "https://example.invalid/private")
        self.assertEqual(self.audit(tip)["failure"], "approved_public_origin_required")
        self.command("remote", "set-url", "origin", "https://github.com/TaigaShinohara/OneClip.git")
        self.assertEqual(self.audit("a" * 40)["status"], "failed")
        self.assertEqual(self.audit("main;injected")["failure"], "explicit_public_commit_tips_required")

    def test_author_metadata_is_classified_without_echoing_email(self):
        email = "synthetic" + "@example.test"
        self.command("config", "user.email", email)
        tip = self.commit("# Public\n")
        report = self.audit(tip)
        self.assertTrue(any(item["category"] == "non_noreply_author_email"
                            for item in report["repository"]["findings"]))
        self.assertNotIn(email, json.dumps(report))

    def test_promisor_store_cannot_trigger_lazy_network_object_fetch(self):
        tip = self.commit("# Public\n")
        self.command("config", "remote.origin.promisor", "true")
        self.assertEqual(self.audit(tip)["failure"], "partial_history_or_lazy_fetch_unsupported")

    def test_legacy_graft_cannot_hide_reachable_history(self):
        tip = self.commit("# Public\n")
        grafts = self.repo / ".git" / "info" / "grafts"
        grafts.parent.mkdir(exist_ok=True)
        grafts.touch()
        self.assertEqual(self.audit(tip)["failure"], "grafted_history_unsupported")

    def test_alternate_object_store_is_not_implicitly_read(self):
        tip = self.commit("# Public\n")
        (self.repo / ".git" / "objects" / "info" / "alternates").touch()
        self.assertEqual(self.audit(tip)["failure"], "alternate_object_store_unsupported")

    def test_symlink_is_not_read_as_an_approved_regular_blob(self):
        (self.repo / "link").symlink_to("/" + "Users/" + "synthetic/private-target")
        tip = self.commit("# Public\n")
        report = self.audit(tip)
        self.assertTrue(any(item["category"] == "symlink_or_submodule_requires_review"
                            for item in report["repository"]["findings"]))
        self.assertNotIn("private-target", json.dumps(report))

    def test_build_dependency_and_workflow_surfaces_are_inventoried(self):
        (self.repo / "Package.swift").write_text("// Synthetic package\n")
        workflow = self.repo / ".github" / "workflows"
        workflow.mkdir(parents=True)
        (workflow / "synthetic.yml").write_text("name: synthetic\n")
        project = self.repo / "Synthetic.pbxproj"
        project.write_text("PBXShellScriptBuildPhase\n")
        tip = self.commit("# Public\n")
        report = self.audit(tip)
        locations = {item["location"] for item in report["repository"]["selected_tip_build_surfaces"]}
        self.assertIn("Package.swift", locations)
        self.assertIn(".github/workflows/synthetic.yml", locations)
        self.assertTrue(any(item["category"] == "build_script_phase_requires_review"
                            for item in report["repository"]["findings"]))

    def test_sensitive_filename_is_redacted(self):
        value = "gh" + "p_" + "B" * 35
        (self.repo / value).write_text("fixture")
        tip = self.commit("# Public\n")
        report = self.audit(tip)
        self.assertEqual(report["status"], "findings_require_review")
        self.assertNotIn(value, json.dumps(report))

    def test_fixed_archive_and_independent_app_manifest_match_without_extraction(self):
        archive, zip_hash, app_hash = self.candidate()
        result = surface.audit_zip(archive, zip_hash, app_hash)
        self.assertTrue(result["archive_and_app_binding_verified"])
        self.assertEqual(result["findings"], [])
        self.assertFalse((self.root / "extracted").exists())

    def test_different_zip_or_app_bytes_cannot_reuse_binding(self):
        archive, zip_hash, app_hash = self.candidate()
        with self.assertRaisesRegex(surface.AuditFailure, "archive_hash_mismatch"):
            surface.audit_zip(archive, "0" * 64, app_hash)
        with self.assertRaisesRegex(surface.AuditFailure, "archived_app_manifest_mismatch"):
            surface.audit_zip(archive, zip_hash, "0" * 64)
        with self.assertRaisesRegex(surface.AuditFailure, "explicit_archive_and_app_hashes_required"):
            surface.audit_zip(archive, None, app_hash)

    def test_archive_private_content_is_classified_without_echo(self):
        value = "/" + "Users/" + "synthetic/private-fixture"
        archive, zip_hash, app_hash = self.candidate(value.encode())
        result = surface.audit_zip(archive, zip_hash, app_hash)
        self.assertTrue(any(item["category"] == "personal filesystem path" for item in result["findings"]))
        self.assertNotIn(value, json.dumps(result))

    def unsafe_archive(self, names):
        path = self.root / "unsafe.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for name, mode in names:
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = mode << 16
                    archive.writestr(entry, b"synthetic")
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_archive_traversal_duplicates_and_symlinks_are_rejected(self):
        fixtures = [
            ([('../outside', stat.S_IFREG | 0o644)], "unsafe_archive_path"),
            ([('OneClip.app//file', stat.S_IFREG | 0o644)], "unsafe_archive_path"),
            ([('OneClip.app/file', stat.S_IFREG | 0o644)] * 2, "duplicate_archive_path"),
            ([('OneClip.app/link', stat.S_IFLNK | 0o777)], "archive_type_or_permissions_unsupported"),
        ]
        for entries, error in fixtures:
            with self.subTest(category=error):
                archive, digest = self.unsafe_archive(entries)
                with self.assertRaisesRegex(surface.AuditFailure, error):
                    surface.audit_zip(archive, digest, "0" * 64)

    def test_appledouble_metadata_is_separate_from_app_manifest(self):
        archive, _, app_hash = self.candidate()
        with zipfile.ZipFile(archive, "a") as output:
            entry = zipfile.ZipInfo("__MACOSX/")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFDIR | 0o755) << 16
            output.writestr(entry, b"")
        result = surface.audit_zip(archive, hashlib.sha256(archive.read_bytes()).hexdigest(), app_hash)
        self.assertTrue(result["archive_and_app_binding_verified"])

    def test_cli_argument_error_does_not_repeat_input_values(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = surface.main(["--repo", "synthetic-private-input"])
        self.assertEqual(code, 1)
        self.assertNotIn("synthetic-private-input", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["failure"], "invalid_arguments")


if __name__ == "__main__":
    unittest.main()
