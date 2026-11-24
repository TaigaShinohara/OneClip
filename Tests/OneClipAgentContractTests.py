"""Black-box contract tests for the oneclip-agent CLI.

Builds nothing by itself: set ONECLIP_AGENT_BIN to the built binary
(scripts/test_agent_cli.sh does). When the binary is unavailable the whole
suite skips with a reason instead of failing, matching how the other
platform-bound suites behave on machines without the toolchain.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = os.environ.get("ONECLIP_AGENT_BIN", "")

FIXTURE_ID = "11111111-1111-4111-8111-111111111111"
EDITED_ID = "44444444-4444-4444-8444-444444444444"


def run_cli(root: Path, *args: str) -> tuple[int, dict]:
    proc = subprocess.run(
        [BIN, *args, "--root", str(root)],
        capture_output=True, text=True, timeout=30,
    )
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise AssertionError(f"stdout is not one JSON envelope: {proc.stdout!r} stderr={proc.stderr!r}")
    return proc.returncode, payload


@unittest.skipUnless(BIN and Path(BIN).exists(), "ONECLIP_AGENT_BIN not set or missing; run scripts/test_agent_cli.sh")
class OneClipAgentContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "root"
        code, payload = run_cli(self.root, "seed")
        self.assertEqual(code, 0, payload)
        self.assertTrue(payload["ok"])

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_envelope_and_status(self) -> None:
        code, payload = run_cli(self.root, "status")
        self.assertEqual(code, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["meta"]["schema_version"], 1)
        self.assertIn("request_id", payload["meta"])
        data = payload["data"]
        self.assertEqual(data["app"], "OneClip")
        self.assertEqual(data["captures"]["count"], 4)
        self.assertEqual(data["captures"]["edited_count"], 1)

    def test_list_and_get(self) -> None:
        code, payload = run_cli(self.root, "list")
        self.assertEqual(code, 0)
        ids = {item["id"] for item in payload["data"]["items"]}
        self.assertIn(FIXTURE_ID, ids)
        self.assertIn(EDITED_ID, ids)

        code, payload = run_cli(self.root, "get", FIXTURE_ID)
        self.assertEqual(code, 0)
        self.assertTrue(payload["data"]["png_signature_valid"])
        # Metadata only: no image payload keys anywhere in the response.
        self.assertNotIn("base64", json.dumps(payload).lower())

        code, payload = run_cli(self.root, "get", "99999999-9999-4999-8999-999999999999")
        self.assertEqual(code, 4)
        self.assertEqual(payload["error"]["code"], "not_found")

        code, payload = run_cli(self.root, "get", "not-a-uuid")
        self.assertEqual(code, 1)
        self.assertEqual(payload["error"]["code"], "invalid_input")

    def test_export_dry_run_then_real_then_conflict(self) -> None:
        out = Path(self._tmp.name) / "out"
        code, payload = run_cli(self.root, "export", FIXTURE_ID, "--to", str(out), "--dry-run")
        self.assertEqual(code, 0)
        self.assertTrue(payload["data"]["dry_run"])
        self.assertFalse(out.exists())

        code, payload = run_cli(self.root, "export", FIXTURE_ID, "--to", str(out),
                                "--idempotency-key", "contract-export-1")
        self.assertEqual(code, 0)
        self.assertTrue(Path(payload["data"]["destination"]).exists())

        # Same idempotency key replays the first result instead of conflicting.
        code, payload = run_cli(self.root, "export", FIXTURE_ID, "--to", str(out),
                                "--idempotency-key", "contract-export-1")
        self.assertEqual(code, 0)
        self.assertTrue(payload["meta"].get("idempotent_replay"))

        # A different key hits the real conflict.
        code, payload = run_cli(self.root, "export", FIXTURE_ID, "--to", str(out))
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "conflict")

    def test_delete_requires_yes_and_is_recoverable(self) -> None:
        code, payload = run_cli(self.root, "delete", FIXTURE_ID)
        self.assertEqual(code, 1)
        self.assertEqual(payload["error"]["code"], "confirmation_required")

        code, payload = run_cli(self.root, "delete", FIXTURE_ID, "--yes")
        self.assertEqual(code, 0)
        trash_path = payload["data"]["trash_path"]
        self.assertTrue((self.root / "Application Support" / "OneClip" / "Captures" / trash_path).exists())

        code, payload = run_cli(self.root, "list")
        self.assertEqual(payload["data"]["count"], 3)

    def test_history_records_writes_only(self) -> None:
        run_cli(self.root, "list")
        run_cli(self.root, "status")
        code, payload = run_cli(self.root, "history")
        self.assertEqual(code, 0)
        commands = [entry["command"] for entry in payload["data"]["entries"]]
        self.assertEqual(commands, ["seed"])

    def test_verify_passes_on_fixtures(self) -> None:
        code, payload = run_cli(self.root, "verify")
        self.assertEqual(code, 0)
        self.assertEqual(payload["data"]["result"], "pass")
        self.assertEqual(payload["data"]["checked"], 4)

    def test_seed_production_guard_on_real_root(self) -> None:
        # Pointing --root at the machine's real default root must be refused
        # before anything is written (exit 3, production_guard).
        real_root = Path(os.path.expanduser("~/Library"))
        proc = subprocess.run(
            [BIN, "seed", "--root", str(real_root)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "production_guard")

    def test_reset_clears_fixtures(self) -> None:
        code, payload = run_cli(self.root, "reset", "--test-data")
        self.assertEqual(code, 0)
        code, payload = run_cli(self.root, "list")
        self.assertEqual(payload["data"]["count"], 0)

    def test_unknown_command_and_flag(self) -> None:
        code, payload = run_cli(self.root, "frobnicate")
        self.assertEqual(code, 1)
        self.assertEqual(payload["error"]["code"], "invalid_input")
        code, payload = run_cli(self.root, "list", "--bogus")
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
