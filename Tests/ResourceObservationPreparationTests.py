"""Source-only observer preparation regressions; no Swift build or image work."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "prepare_resource_observation", ROOT / "scripts" / "prepare_resource_observation.py")
preparation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preparation)


class ResourceObservationPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oneclip-render-preparation-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.repo = self.base / "repo"
        (self.repo / "OneClip").mkdir(parents=True)
        self.original = (ROOT / preparation.SOURCE).read_bytes()
        self.source = self.repo / preparation.SOURCE
        self.source.write_bytes(self.original)
        self.output = self.base / "derived"

    def test_exact_one_line_delta_and_hash_binding(self):
        transformed, binding = preparation.transform_source(self.original)
        before, after = self.original.split(b"            try checked(.beforeEncoding)\n")
        expected = (before + b"            M4RenderObjectObservation.record(image)\n"
                    + b"            try checked(.beforeEncoding)\n" + after)
        self.assertEqual(transformed, expected)
        self.assertEqual(binding["originalSHA256"], hashlib.sha256(self.original).hexdigest())
        self.assertEqual(binding["transformedSHA256"], hashlib.sha256(expected).hexdigest())
        delta = binding["delta"]
        self.assertEqual(delta["byteOffset"], len(before))
        self.assertEqual(delta["insertionCount"], 1)
        self.assertEqual(delta["insertedUTF8"].encode(), expected[len(before):len(before) + len(preparation.INSERTION)])
        self.assertEqual(delta["transformedBytes"] - delta["originalBytes"], len(preparation.INSERTION))
        self.assertFalse(binding["productSourceChanged"])
        self.assertFalse(binding["resourceAcceptance"])

    def test_missing_or_duplicated_encoding_anchor_is_rejected(self):
        for content in (self.original.replace(preparation.ANCHOR, b"", 1),
                        self.original.replace(preparation.ANCHOR, preparation.ANCHOR * 2, 1)):
            with self.subTest(contentLength=len(content)), self.assertRaises(preparation.PreparationError):
                preparation.transform_source(content)

    def test_anchor_elsewhere_cannot_replace_missing_render_boundary(self):
        content = self.original.replace(preparation.ANCHOR, b"", 1) + preparation.ANCHOR
        with self.assertRaisesRegex(preparation.PreparationError, "source_render_boundary_mismatch"):
            preparation.transform_source(content)

    def test_changed_near_anchor_cannot_be_guessed(self):
        content = self.original.replace(preparation.RENDER_PREFIX,
                                        preparation.RENDER_PREFIX + b"            // changed boundary\n", 1)
        with self.assertRaisesRegex(preparation.PreparationError, "source_render_boundary_mismatch"):
            preparation.transform_source(content)

    def test_reinstrumentation_and_duplicate_compose_boundary_are_rejected(self):
        observed, _ = preparation.transform_source(self.original)
        for content in (observed, self.original + preparation.COMPOSE_START,
                        self.original + preparation.RENDER_PREFIX):
            with self.subTest(contentLength=len(content)), self.assertRaises(preparation.PreparationError):
                preparation.transform_source(content)

    def test_invalid_size_encoding_and_nul_are_rejected(self):
        for content in (b"", b"x" * (preparation.MAX_SOURCE_BYTES + 1),
                        self.original + b"\xff", self.original + b"\0"):
            with self.subTest(contentLength=len(content)), self.assertRaises(preparation.PreparationError):
                preparation.transform_source(content)

    def test_new_private_copy_and_manifest_leave_original_untouched(self):
        binding = preparation.prepare(self.repo, self.output)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         sorted([preparation.COPY, preparation.MANIFEST]))
        self.assertEqual(json.loads((self.output / preparation.MANIFEST).read_text()), binding)
        self.assertEqual(hashlib.sha256((self.output / preparation.COPY).read_bytes()).hexdigest(),
                         binding["transformedSHA256"])
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        for name in (preparation.COPY, preparation.MANIFEST):
            self.assertEqual(stat.S_IMODE((self.output / name).stat().st_mode), 0o600)
        self.assertNotIn(str(self.repo), json.dumps(binding))
        self.assertNotIn(str(self.output), json.dumps(binding))

    def test_existing_output_directory_is_not_overwritten(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_bytes(b"synthetic-existing-file")
        with self.assertRaisesRegex(preparation.PreparationError, "output_already_exists"):
            preparation.prepare(self.repo, self.output)
        self.assertEqual(marker.read_bytes(), b"synthetic-existing-file")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_existing_file_or_leaf_symlink_is_not_overwritten(self):
        target = self.base / "target"
        target.write_bytes(b"synthetic-existing-file")
        with self.subTest(kind="file"):
            with self.assertRaisesRegex(preparation.PreparationError, "output_already_exists"):
                preparation.prepare(self.repo, target)
        for name, destination in (("live-link", target), ("dangling-link", self.base / "absent")):
            link = self.base / name
            link.symlink_to(destination)
            with self.subTest(kind=name), self.assertRaises(preparation.PreparationError):
                preparation.prepare(self.repo, link)
            self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_bytes(), b"synthetic-existing-file")

    def test_output_parent_symlink_is_rejected_without_following(self):
        parent = self.base / "real-parent"
        parent.mkdir(mode=0o700)
        link = self.base / "parent-link"
        link.symlink_to(parent, target_is_directory=True)
        with self.assertRaises((preparation.PreparationError, OSError)):
            preparation.prepare(self.repo, link / "derived")
        self.assertEqual(list(parent.iterdir()), [])

    def test_outside_os_temp_and_inside_repository_are_rejected(self):
        outside = Path(tempfile.gettempdir()).resolve().parent / "oneclip-not-a-temporary-child"
        for output, reason in ((outside, "output_outside_os_temporary_directory"),
                               (self.repo / "derived", "output_inside_repository")):
            with self.subTest(reason=reason), self.assertRaisesRegex(preparation.PreparationError, reason):
                preparation.prepare(self.repo, output)
        self.assertFalse((self.repo / "derived").exists())

    def test_source_file_symlink_is_rejected_and_no_output_created(self):
        self.source.rename(self.source.with_suffix(".saved"))
        self.source.symlink_to(self.source.with_suffix(".saved"))
        with self.assertRaises((preparation.PreparationError, OSError)):
            preparation.prepare(self.repo, self.output)
        self.assertFalse(self.output.exists())

    def test_source_directory_or_repository_symlink_is_rejected(self):
        real = self.repo / "real-sources"
        (self.repo / "OneClip").rename(real)
        (self.repo / "OneClip").symlink_to(real, target_is_directory=True)
        with self.assertRaises((preparation.PreparationError, OSError)):
            preparation.prepare(self.repo, self.output)
        alias = self.base / "repo-alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        with self.assertRaises(preparation.PreparationError):
            preparation.prepare(alias, self.output)
        self.assertFalse(self.output.exists())

    def test_repository_ancestor_symlink_is_rejected(self):
        alias = self.base / "ancestor-alias"
        alias.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises((preparation.PreparationError, OSError)):
            preparation.prepare(alias / "repo", self.output)
        self.assertFalse(self.output.exists())

    def test_fifo_without_writer_and_directory_source_are_refused_in_bounded_children(self):
        for kind in ("fifo", "directory"):
            with self.subTest(kind=kind):
                self.source.unlink()
                if kind == "fifo":
                    os.mkfifo(self.source, 0o600)
                else:
                    self.source.mkdir(mode=0o700)
                result = subprocess.run(
                    [sys.executable, "-I", "-B", str(ROOT / "scripts" / "prepare_resource_observation.py"),
                     "--repo", str(self.repo), "--output-dir", str(self.output)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    env={"PATH": os.defpath, "LANG": "C", "TMPDIR": tempfile.gettempdir()},
                    timeout=3, check=False)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"source_file_invalid\n")
                self.assertFalse(self.output.exists())
                if kind == "fifo":
                    self.source.unlink()
                else:
                    self.source.rmdir()
                self.source.write_bytes(self.original)

    def test_source_descriptor_is_closed_if_fdopen_raises(self):
        opened = []
        live_fdopen = os.fdopen

        def failing_fdopen(descriptor, *args, **kwargs):
            opened.append(descriptor)
            raise OSError("synthetic_fdopen_failure")

        with mock.patch.object(preparation.os, "fdopen", side_effect=failing_fdopen):
            with self.assertRaises(OSError):
                preparation.prepare(self.repo, self.output)
        self.assertEqual(len(opened), 1)
        with self.assertRaises(OSError):
            os.fstat(opened[0])
        self.assertFalse(self.output.exists())
        self.assertIs(os.fdopen, live_fdopen)

    def test_writable_output_parent_and_dot_dot_are_rejected(self):
        parent = self.base / "writable-parent"
        parent.mkdir(mode=0o700)
        parent.chmod(0o777)
        with self.assertRaisesRegex(preparation.PreparationError, "output_parent_not_private_directory"):
            preparation.prepare(self.repo, parent / "derived")
        with self.assertRaisesRegex(preparation.PreparationError, "output_path_invalid"):
            preparation.prepare(self.repo, self.base / "unused" / ".." / "derived")


if __name__ == "__main__":
    unittest.main()
