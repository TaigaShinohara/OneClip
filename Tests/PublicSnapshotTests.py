"""Check that publication preparation cannot carry over private Git history."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "public_snapshot", Path(__file__).resolve().parents[1] / "scripts" / "prepare_public_snapshot.py",
)
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)


class PublicSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "public"
        self.git("init", "--quiet", "--initial-branch=main", "--template=")
        self.git("config", "user.name", "Synthetic Contributor")
        self.git("config", "user.email", "12345+synthetic@users.noreply.github.com")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return snapshot.git(self.source, *args)

    def commit(self, text):
        (self.source / "README.md").write_text(text, encoding="utf-8")
        self.git("-c", "core.hooksPath=/dev/null", "add", "--all")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Synthetic fixture")

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()):
            snapshot.prepare(self.source, self.output)

    def test_new_root_contains_current_tree_but_no_private_history(self):
        private_fixture = "/" + "Users/" + "synthetic/private-workspace"
        self.commit(private_fixture)
        old_blob = self.git("rev-parse", "HEAD:README.md").decode().strip()
        self.commit("# OneClip fixture\n")
        source_head = self.git("rev-parse", "HEAD")
        self.prepare()

        self.assertEqual(snapshot.git(self.output, "rev-list", "--count", "--all").strip(), b"1")
        self.assertEqual(snapshot.git(self.output, "rev-parse", "HEAD^{tree}"), self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(snapshot.git(self.output, "symbolic-ref", "--short", "HEAD").strip(), b"main")
        self.assertEqual(snapshot.git(self.output, "remote"), b"")
        self.assertFalse((self.output / ".git/objects/info/alternates").exists())
        self.assertEqual(self.git("rev-parse", "HEAD"), source_head)
        self.assertEqual(self.git("rev-list", "--count", "--all").strip(), b"2")
        result = subprocess.run(
            ["git", "-C", str(self.output), "cat-file", "-e", old_blob],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=snapshot.git_environment(),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_private_metadata_is_rejected_without_echoing_values(self):
        fixtures = (
            "/" + "Users/" + "synthetic/private-workspace",
            "https://app." + "notion.com/p/synthetic-private-page",
            "01a12345" + "-1234-1234-1234-123456789abc",
            "page_" + "a" * 32,
        )
        for private_fixture in fixtures:
            with self.subTest(category=fixtures.index(private_fixture)):
                self.commit(private_fixture)
                with self.assertRaises(snapshot.PreparationError) as caught:
                    self.prepare()
                self.assertNotIn(private_fixture, str(caught.exception))
                self.assertIn("README.md:1:", str(caught.exception))
                self.assertFalse(self.output.exists())

    def test_personal_document_narratives_are_rejected_without_echoing_values(self):
        fixtures = (
            "本人は「架空操作を試した」と回答した。",
            "本人が管理者認証を試し、入力が通らなかったと報告した。",
            "ほかのローカルチャットが3件activeだった。",
            "guest PID 99999 で起動を確認した。",
            "The user reported a synthetic authentication failure.",
        )
        for index, private_fixture in enumerate(fixtures):
            with self.subTest(category=index):
                self.commit("# Fixture\n" + private_fixture + "\n")
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaises(snapshot.PreparationError) as caught:
                        snapshot.prepare(self.source, self.output)
                self.assertNotIn(private_fixture, str(caught.exception))
                self.assertNotIn(private_fixture, output.getvalue())
                self.assertIn("README.md:2:", str(caught.exception))
                self.assertFalse(self.output.exists())

    def test_generic_documentation_and_swift_callback_tokens_are_allowed(self):
        callback = "let token = UUID()\nlet observerToken = center.addObserver(callback)\n"
        (self.source / "Callback.swift").write_text(callback, encoding="utf-8")
        self.commit(
            "# Fixture\n"
            "画面収録の許可が必要です。認証情報をログに保存しません。\n"
            "利用者は画面を選択し、アプリはPNGを生成します。\n"
            "本人の明示的な許可がある場合だけ設定を変更します。\n"
            "The user can cancel capture without copying.\n"
        )
        self.prepare()
        self.assertEqual((self.output / "Callback.swift").read_text(encoding="utf-8"), callback)

    def test_dirty_source_is_rejected(self):
        self.commit("# Fixture\n")
        (self.source / "uncommitted.txt").write_text("not reviewed", encoding="utf-8")
        with self.assertRaises(snapshot.PreparationError):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.commit("# Fixture\n")
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("preserve this", encoding="utf-8")
        with self.assertRaises(snapshot.PreparationError):
            self.prepare()
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve this")

    def test_tracked_local_files_are_rejected(self):
        self.commit("# Fixture\n")
        local = self.source / ".local"
        local.mkdir()
        (local / "private.txt").write_text("fixture", encoding="utf-8")
        self.git("-c", "core.hooksPath=/dev/null", "add", "--all")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Synthetic local file")
        with self.assertRaises(snapshot.PreparationError) as caught:
            self.prepare()
        self.assertIn("excluded local or sensitive file", str(caught.exception))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
