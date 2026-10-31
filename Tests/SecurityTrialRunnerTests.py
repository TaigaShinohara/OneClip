#!/usr/bin/env python3
"""Private temporary files, fake clocks and fake child processes only. Never launches an app."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


MODULE = Path(__file__).resolve().parents[1] / "scripts" / "run_security_trial.py"
spec = importlib.util.spec_from_file_location("security_trial_runner", MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FakeClock:
    def __init__(self): self.wall = self.monotonic = 10_000_000_000
    def wall_ns(self): return self.wall
    def monotonic_ns(self): return self.monotonic
    def advance(self, seconds, *, wall_only=False):
        self.wall += int(seconds * 1_000_000_000)
        if not wall_only: self.monotonic += int(seconds * 1_000_000_000)


class FakeProcess:
    def __init__(self, pid, *, timeout=False, clock=None, wall_jump_on_wait=False):
        self.pid, self.timeout = pid, timeout
        self.clock, self.wall_jump_on_wait = clock, wall_jump_on_wait
        self.wait_slices = []
        self.returncode = None
        self.stdout = None
        self.terminated = self.killed = 0
    def poll(self): return self.returncode
    def wait(self, timeout=None):
        self.wait_slices.append(timeout)
        if self.timeout and self.returncode is None:
            if self.clock is not None:
                if self.wall_jump_on_wait and len(self.wait_slices) == 1: self.clock.advance(901, wall_only=True)
                else: self.clock.advance(timeout)
            raise subprocess.TimeoutExpired("synthetic", timeout)
        if self.returncode is None: self.returncode = 0
        return self.returncode
    def terminate(self): self.terminated += 1; self.returncode = -15
    def kill(self): self.killed += 1; self.returncode = -9


def evidence(mode="collection", stage="retained", transition="menu-lock", *, status="NOT_ESTABLISHED", recovery=False):
    rows = []
    def entry(code, *, selected_mode=mode, phase="none", outcome="none"):
        n = len(rows) + 1
        rows.append({"trial": 1, "sequence": n, "relativeNanos": n, "code": code,
                     "mode": selected_mode, "phase": phase, "outcome": outcome})
    entry("trialReady")
    if stage in {"sck", "encoding"}: entry("captureRequested" if stage == "sck" else "compositionStarted")
    entry({"system-sleep": "systemSleep", "display-sleep": "displaySleep"}.get(transition, "protectedDataUnavailable"), selected_mode="none")
    entry("operationInvalidated", phase="selecting" if stage == "selecting" else "none")
    if stage in {"sck", "encoding"}: entry("captureCallback" if stage == "sck" else "compositionFinished")
    entry("manualTransitionConfirmed")
    old_end = len(rows)
    recovery_start = recovery_end = 0
    if recovery:
        entry("trialRecoveryStarted"); recovery_start = len(rows)
        adoption = 0
        for code in runner.recovery_projection(mode):
            if code == "resultAdopted": adoption += 1
            entry(code, phase=("capturing" if adoption == 1 else "encoding") if code == "resultAdopted" else "none",
                outcome="success" if code in {"captureCallback", "captureReturned"}
                    else ("accepted" if code == "clipboardOutcome" else "none"))
        entry("trialRecoveryFinished", outcome="accepted"); recovery_end = len(rows)
    end = len(rows)
    entry("trialFinished")
    metadata = {
        "schema": "oneclip-runtime-trial-v1", "source_baseline": "062f1bd1129d0286f4696fec612db5f6d6593050",
        "status": status, "reason": "OBSERVED_INVALIDATION_AND_EXPLICIT_RECOVERY" if recovery else "EXPLICIT_RECOVERY_NOT_ESTABLISHED",
        "mode": mode, "stage": stage, "transition": transition, "ready_sequence": 1,
        "evidence_end_sequence": end, "manual_transition_confirmed": True,
        "worker_ended": True, "images_cleared": True, "slot_free": True,
        "invalidation_observation_established": True, "explicit_recovery_exercised": recovery,
        "full_cell_accepted": recovery,
        "invalidation_evidence_end_sequence": old_end,
        "recovery_start_sequence": recovery_start, "recovery_end_sequence": recovery_end,
        "recovery_manual_start_confirmed": recovery, "recovery_worker_ended": True, "recovery_slot_free": True,
        "archive_exercised": False, "annotation_exercised": False,
        "fixture_executable_sha256": "", "fixture_binding": "parent_fresh_pid_path_sha256",
        "single_retained_forced_writer_rejection": mode == "single" and stage == "retained",
        "selection_ui": "harness_fixed_fixture_crop", "product_image_view_exercised": False,
        "board": "private_named", "general_board_access": False, "permission_requested": False,
        "automatic_os_operations": 0, "manual_operations_requested": 1, "session_limit_seconds": 900,
        "parent_ledger_required": True, "dropped_count": 0, "evidence_dropped_count": 0,
        "full_os_matrix_complete": False, "m4_acceptance_complete": False, "voiceover_verified": False,
        "os_atomicity_guaranteed": False,
    }
    return metadata, rows


class FakeDriver:
    def __init__(self, clock, candidate, *, status="NOT_ESTABLISHED", timeout=False, ready=True, malformed=False, leak=False, cleanup=True, advance=0, wall_jump_on_wait=False, recovery=False):
        self.recovery = recovery
        self.clock, self.candidate = clock, candidate
        self.status, self.timeout, self.is_ready = status, timeout, ready
        self.malformed, self.leak, self.cleanup_ok, self.advance = malformed, leak, cleanup, advance
        self.wall_jump_on_wait = wall_jump_on_wait
        self.fixture_process = self.runtime_process = None
        self.arguments = None
        self.cleanups = []
    def fixture(self, binary):
        self.fixture_path = binary
        self.fixture_process = FakeProcess(1234)
        return self.fixture_process
    def ready(self, process, timeout): return self.is_ready
    def runtime(self, arguments):
        self.arguments = arguments
        output = Path(arguments[arguments.index("--output-dir") + 1]); output.mkdir(mode=0o700)
        mode = arguments[arguments.index("--mode") + 1]
        stage = arguments[arguments.index("--stage") + 1]
        transition = arguments[arguments.index("--transition") + 1]
        meta, rows = evidence(mode, stage, transition, status=self.status, recovery=self.recovery)
        meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        if self.leak:
            rows.insert(-1, {"trial": 1, "sequence": len(rows), "relativeNanos": len(rows),
                "code": "resultAdopted", "mode": mode, "phase": "capturing", "outcome": "accepted"})
            rows[-1]["sequence"] += 1; rows[-1]["relativeNanos"] += 1
            meta["evidence_end_sequence"] += 1
        (output / "metadata.json").write_text("{" if self.malformed else json.dumps(meta))
        (output / "trace.json").write_text(json.dumps(rows))
        self.runtime_process = FakeProcess(1235, timeout=self.timeout, clock=self.clock, wall_jump_on_wait=self.wall_jump_on_wait)
        if not self.timeout: self.runtime_process.returncode = 0 if self.status == runner.PASS else 2
        if self.advance: self.clock.advance(self.advance)
        return self.runtime_process
    def cleanup(self, process):
        if process is not None:
            self.cleanups.append(process.pid)
            if process.poll() is None: process.terminate()
        return self.cleanup_ok


class SecurityTrialRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.tools = self.root / "tools"; self.tools.mkdir(mode=0o700)
        binaries = {}
        for name in ("ownership-probe", "SecurityRuntimeTrial", "M4Fixture"):
            path = self.tools / name; path.write_bytes(("SYNTHETIC " + name).encode()); path.chmod(0o700)
            binaries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        inputs = {name: "a" * 64 for name in (
            "OneClip/CaptureSecurityTrace.swift", "OneClip/M0ImageCore.swift", "OneClip/M3PracticeFixture.swift",
            "Tests/M4ResourceOwnershipProbe.swift", "Tests/SecurityRuntimeTrial.swift", "Tests/M4Fixture.swift")}
        self.source = hashlib.sha1(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        self.manifest = self.tools / "manifest.json"
        self.manifest.write_text(json.dumps({"schema": "oneclip-security-tools-v1", "sourceIDKind": "build-inputs-sha1",
            "sourceID": self.source, "inputs": inputs, "optimization": "-O", "toolchain": {"swift": "synthetic"}, "binaries": binaries}))
        self.manifest_hash = runner.digest(self.manifest.read_bytes())
        self.directory = self.root / "ledger"
        runner.initialize(self.directory, self.manifest, self.manifest_hash, self.source)
        self.clock = FakeClock()
        with runner.Ledger(self.directory) as ledger:
            ledger.new_session(self.clock)
            self.candidate = copy.deepcopy(ledger.state["candidate"])
    def tearDown(self): self.temporary.cleanup()
    def reject(self, function, code):
        with self.assertRaisesRegex(runner.Rejected, "^" + code + "$"): function()
    def run_fake(self, **options):
        with runner.Ledger(self.directory) as ledger:
            driver = FakeDriver(self.clock, self.candidate, **options)
            result = runner.run_trial(ledger, "collection", "retained", "menu-lock", driver=driver, clock=self.clock)
        return result, driver

    def test_default_and_help_do_not_touch_files_or_processes(self):
        with mock.patch.object(runner, "load_tools", side_effect=AssertionError("no I/O")), mock.patch.object(runner.subprocess, "Popen", side_effect=AssertionError("no launch")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main([]), 0)
            with self.assertRaises(SystemExit) as status: runner.main(["--help"])
            self.assertEqual(status.exception.code, 0)

    def test_parent_verifier_bytes_are_pinned_at_initialization(self):
        self.assertEqual(self.candidate["parent_runner_sha256"], hashlib.sha256(MODULE.read_bytes()).hexdigest())
        self.assertEqual(runner.SCHEMA, "oneclip-security-trial-ledger-v2")
        other = self.root / "changed-at-init"
        with mock.patch.object(runner, "current_runner_sha256", side_effect=["a" * 64, "b" * 64]):
            self.reject(lambda: runner.initialize(other, self.manifest, self.manifest_hash, self.source), "PARENT_RUNNER_HASH_MISMATCH")
        self.assertFalse(other.exists())

    def test_wrong_parent_hash_and_changed_parent_file_reject_reopening(self):
        path = self.directory / "state.json"
        state = json.loads(path.read_text()); state["candidate"]["parent_runner_sha256"] = "0" * 64
        path.write_text(json.dumps(state))
        self.reject(lambda: runner.Ledger(self.directory), "PARENT_RUNNER_HASH_MISMATCH")
        state["candidate"]["parent_runner_sha256"] = self.candidate["parent_runner_sha256"]
        path.write_text(json.dumps(state))
        changed = self.root / "changed-parent.py"; changed.write_bytes(MODULE.read_bytes() + b"\n# synthetic changed verifier\n")
        with mock.patch.object(runner, "__file__", str(changed)):
            self.reject(lambda: runner.Ledger(self.directory), "PARENT_RUNNER_HASH_MISMATCH")

    def test_changed_parent_is_rejected_before_tools_or_state_mutation(self):
        changed = self.root / "changed-parent.py"; changed.write_bytes(MODULE.read_bytes() + b"\n# synthetic changed verifier\n")
        with runner.Ledger(self.directory) as ledger:
            before = (self.directory / "state.json").read_bytes()
            with mock.patch.object(runner, "__file__", str(changed)), mock.patch.object(runner, "load_tools", side_effect=AssertionError("must reject before tool I/O")):
                self.reject(ledger.tools, "PARENT_RUNNER_HASH_MISMATCH")
                self.reject(ledger.save, "PARENT_RUNNER_HASH_MISMATCH")
            self.assertEqual((self.directory / "state.json").read_bytes(), before)

    def test_legacy_parent_unpinned_schema_is_rejected_without_migration(self):
        path = self.directory / "state.json"
        state = json.loads(path.read_text()); state["schema"] = "oneclip-security-trial-ledger-v1"
        state["candidate"].pop("parent_runner_sha256")
        path.write_text(json.dumps(state))
        self.reject(lambda: runner.Ledger(self.directory), "LEDGER_SCHEMA_REJECTED")

    def test_private_ledger_and_atomic_save(self):
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.directory / "state.json").stat().st_mode & 0o777, 0o600)
        with runner.Ledger(self.directory) as ledger: ledger.save()
        self.assertFalse(any(p.name.startswith(".state-") for p in self.directory.iterdir()))

    def test_ledger_lock_rejects_concurrent_access(self):
        with runner.Ledger(self.directory): self.reject(lambda: runner.Ledger(self.directory), "LEDGER_BUSY")

    def test_reservation_precedes_launch_and_survives_reopen(self):
        with runner.Ledger(self.directory) as ledger:
            trial, _ = ledger.reserve("single", "sck", "key-lock", self.clock)
            self.assertEqual(trial["status"], "RESERVED")
        with runner.Ledger(self.directory) as ledger:
            self.assertEqual(len(ledger.state["trials"]), 1)
            self.reject(lambda: ledger.reserve("single", "sck", "key-lock", self.clock), "RESERVATION_RECOVERY_REQUIRED")
            ledger.recover()
            self.assertEqual(ledger.state["trials"][0]["status"], "NOT_ESTABLISHED")

    def test_explicit_session_is_required(self):
        with runner.Ledger(self.directory) as ledger:
            ledger.state["current_session"] = None; ledger.save()
            self.reject(lambda: ledger.reserve("single", "retained", "menu-lock", self.clock), "EXPLICIT_SESSION_REQUIRED")

    def test_three_operations_per_session_and_five_attempts_across_sessions(self):
        for index in range(5):
            with runner.Ledger(self.directory) as ledger:
                if index == 3:
                    self.reject(lambda: ledger.reserve("collection", "retained", "menu-lock", self.clock), "SESSION_OPERATION_LIMIT")
                    ledger.new_session(self.clock)
                trial, _ = ledger.reserve("collection", "retained", "menu-lock", self.clock)
                ledger.complete(trial, {"status": "NOT_ESTABLISHED", "reason": "SYNTHETIC_NOT_ESTABLISHED", "cleanup_confirmed": True})
        with runner.Ledger(self.directory) as ledger:
            ledger.new_session(self.clock)
            self.reject(lambda: ledger.reserve("collection", "retained", "menu-lock", self.clock), "CELL_ATTEMPT_LIMIT")

    def test_three_invalidation_observations_never_satisfy_full_cell_target(self):
        for _ in range(3):
            result, _ = self.run_fake()
            self.assertEqual(result["status"], "NOT_ESTABLISHED")
            self.assertEqual(result["reason"], "EXPLICIT_RECOVERY_NOT_ESTABLISHED")
            self.assertTrue(result["invalidation_observation_established"])
            self.assertFalse(result["explicit_recovery_exercised"] or result["full_cell_accepted"])
        with runner.Ledger(self.directory) as ledger:
            status = runner.summary(ledger)
            self.assertEqual(status["established_passes"], 0)
            self.assertEqual(status["invalidation_observations"], 3)
            ledger.new_session(self.clock)
            trial, _ = ledger.reserve("collection", "retained", "menu-lock", self.clock)
            self.assertEqual(trial["ordinal"], 4)
            ledger.complete(trial, {"status": "NOT_ESTABLISHED", "reason": "SYNTHETIC_NOT_ESTABLISHED"})

    def test_parent_and_ledger_reject_forged_full_cell_pass(self):
        result, _ = self.run_fake(status=runner.PASS)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertEqual(result["reason"], "RUNTIME_EVIDENCE_INVALID_OR_MISSING")
        with runner.Ledger(self.directory) as ledger:
            trial, _ = ledger.reserve("single", "retained", "menu-lock", self.clock)
            self.reject(lambda: ledger.complete(trial, {"status": runner.PASS, "reason": "SYNTHETIC"}), "FULL_CELL_EVIDENCE_REQUIRED")
            ledger.recover()
            ledger.state["trials"][0]["status"] = runner.PASS
            self.reject(lambda: runner.validate_state(ledger.state), "FULL_CELL_EVIDENCE_REQUIRED")

    def test_three_trace_proven_recoveries_satisfy_the_cell_target(self):
        for _ in range(3):
            result, _ = self.run_fake(status=runner.PASS, recovery=True)
            self.assertEqual(result["status"], runner.PASS)
            self.assertTrue(runner.proven_pass(result))
        with runner.Ledger(self.directory) as ledger:
            self.assertEqual(runner.summary(ledger)["established_passes"], 3)
            ledger.new_session(self.clock)
            self.reject(lambda: ledger.reserve("collection", "retained", "menu-lock", self.clock), "CELL_TARGET_ALREADY_MET")

    def test_reopening_ledger_revalidates_accepted_trace_bytes(self):
        self.assertEqual(self.run_fake(status=runner.PASS, recovery=True)[0]["status"], runner.PASS)
        trace_path = self.directory / "runs" / "000001" / "runtime" / "trace.json"
        rows = json.loads(trace_path.read_text()); rows[-1]["relativeNanos"] += 1
        trace_path.write_text(json.dumps(rows))
        self.reject(lambda: runner.Ledger(self.directory), "FULL_CELL_EVIDENCE_CHANGED")

    def test_trace_proves_all_32_mode_stage_transition_recoveries(self):
        output = self.root / "matrix-evidence"; output.mkdir(mode=0o700)
        for mode in sorted(runner.MODES):
            for stage in sorted(runner.STAGES):
                for transition in sorted(runner.TRANSITIONS):
                    meta, rows = evidence(mode, stage, transition, status=runner.PASS, recovery=True)
                    meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
                    (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
                    result = runner.read_evidence(output, self.candidate, mode, stage, transition, 0)
                    self.assertEqual(result["status"], runner.PASS, (mode, stage, transition))
                    self.assertTrue(result["recovery_evidence_validated"])
                    self.assertFalse(result["product_image_view_exercised"])

    def test_late_old_worker_return_releases_only_after_actual_return(self):
        output = self.root / "old-return-evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(stage="sck")
        meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        rows[1:1] = [dict(rows[0], code="slotAcquired"), dict(rows[0], code="workerStarted")]
        position = next(i for i, row in enumerate(rows) if row["code"] == "manualTransitionConfirmed")
        rows[position:position] = [dict(rows[0], code=code) for code in ("captureReturned", "workerReturned", "slotReleased")]
        for n, row in enumerate(rows, 1): row.update(sequence=n, relativeNanos=n)
        meta["invalidation_evidence_end_sequence"] = meta["evidence_end_sequence"] = len(rows) - 1
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        result = runner.read_evidence(output, self.candidate, "collection", "sck", "menu-lock", 2)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertTrue(result["invalidation_observation_established"])
        returned = next(row for row in rows if row["code"] == "workerReturned")
        release = next(row for row in rows if row["code"] == "slotReleased")
        returned["code"], release["code"] = "slotReleased", "workerReturned"
        (output / "trace.json").write_text(json.dumps(rows))
        result = runner.read_evidence(output, self.candidate, "collection", "sck", "menu-lock", 2)
        self.assertEqual(result["status"], "FAIL")

    def test_recovery_flags_cannot_replace_real_capture_encode_write_or_return_evidence(self):
        output = self.root / "forged-recovery"; output.mkdir(mode=0o700)
        for missing in ("operationStarted", "captureRequested", "captureCallback", "captureReturned", "compositionStarted",
                        "compositionFinished", "resultAdopted", "clipboardPrepared", "clipboardWrite", "clipboardOutcome",
                        "workerReturned", "slotReleased", "trialRecoveryStarted", "trialRecoveryFinished"):
            meta, rows = evidence(status=runner.PASS, recovery=True)
            meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
            # Preserve sequence shape and all claimed flags while replacing proof with a neutral code.
            for row in rows:
                if row["sequence"] > meta["invalidation_evidence_end_sequence"] and row["code"] == missing:
                    row["code"] = "environmentValidated"
            (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
            try: result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)
            except runner.Rejected: continue
            self.assertNotEqual(result["status"], runner.PASS, missing)

    def test_write_call_none_and_later_accepted_outcome_are_distinct_evidence(self):
        output = self.root / "clipboard-shape"; output.mkdir(mode=0o700)
        meta, rows = evidence(status=runner.PASS, recovery=True)
        meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        write = next(e for e in rows if e["code"] == "clipboardWrite")
        outcome = next(e for e in rows if e["code"] == "clipboardOutcome")
        self.assertEqual(write["outcome"], "none"); self.assertEqual(outcome["outcome"], "accepted")
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        self.assertEqual(runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)["status"], runner.PASS)
        write["outcome"] = "accepted"
        (output / "trace.json").write_text(json.dumps(rows))
        with self.assertRaises(runner.Rejected): runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)
        write["outcome"] = "none"; outcome["outcome"] = "rejected"
        (output / "trace.json").write_text(json.dumps(rows))
        with self.assertRaises(runner.Rejected): runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)

    def test_recovery_rejects_failed_or_unknown_sck_outcomes(self):
        output = self.root / "contradictory-capture"; output.mkdir(mode=0o700)
        for mode in ("single", "collection"):
            for code in ("captureCallback", "captureReturned"):
                for outcome in ("failure", "none"):
                    with self.subTest(mode=mode, code=code, outcome=outcome):
                        meta, rows = evidence(mode=mode, status=runner.PASS, recovery=True)
                        meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
                        row = next(e for e in rows if e["sequence"] > meta["recovery_start_sequence"] and e["code"] == code)
                        self.assertEqual(row["outcome"], "success")
                        row["outcome"] = outcome
                        (output / "metadata.json").write_text(json.dumps(meta))
                        (output / "trace.json").write_text(json.dumps(rows))
                        with self.assertRaises(runner.Rejected):
                            runner.read_evidence(output, self.candidate, mode, "retained", "menu-lock", 0)

    def test_recovery_requires_manual_boundary_old_release_and_new_return(self):
        output = self.root / "boundary-evidence"; output.mkdir(mode=0o700)
        for field, value in (("recovery_manual_start_confirmed", False), ("worker_ended", False), ("images_cleared", False),
                             ("slot_free", False), ("recovery_worker_ended", False), ("recovery_slot_free", False),
                             ("recovery_start_sequence", 1), ("invalidation_evidence_end_sequence", 0),
                             ("manual_transition_confirmed", False), ("dropped_count", 1)):
            meta, rows = evidence(status=runner.PASS, recovery=True)
            meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]; meta[field] = value
            (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
            try: result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)
            except runner.Rejected: continue
            self.assertNotEqual(result["status"], runner.PASS, field)

    def test_old_leak_before_recovery_or_new_invalidation_survives_claimed_recovery_pass(self):
        output = self.root / "leak-boundary"; output.mkdir(mode=0o700)
        for before_start in (True, False):
            meta, rows = evidence(status=runner.PASS, recovery=True)
            meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
            if before_start:
                row = rows[meta["recovery_start_sequence"] - 1]
                row["code"] = "resultAdopted"; row["phase"] = "encoding"
                # The missing manual boundary can never authorize this old result.
            else:
                row = next(r for r in rows if r["sequence"] > meta["recovery_start_sequence"] and r["code"] == "compositionStarted")
                row["code"] = "operationInvalidated"
            (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
            result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)
            self.assertEqual(result["status"], "FAIL")

    def test_recovery_permission_attempt_and_unexercised_archive_are_failures(self):
        output = self.root / "scope-evidence"; output.mkdir(mode=0o700)
        for code in ("permissionRequested", "archiveStarted", "editCopyStarted", "resultPreviewDraw"):
            meta, rows = evidence(status=runner.PASS, recovery=True)
            meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
            rows[-1]["code"] = code; rows[-1]["mode"] = "collection"
            (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
            result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)
            self.assertNotEqual(result["status"], runner.PASS)

    def test_capture_by_an_unrequested_mode_is_failure_even_before_trial_ready(self):
        output = self.root / "wrong-mode-evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        rows.insert(0, dict(rows[0], code="captureRequested", mode="single"))
        for n, row in enumerate(rows, 1): row.update(sequence=n, relativeNanos=n)
        meta["ready_sequence"] += 1
        meta["invalidation_evidence_end_sequence"] += 1; meta["evidence_end_sequence"] += 1
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        self.assertEqual(runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 2)["status"], "FAIL")

    def test_annotation_trace_is_recognized_but_rejected_as_an_unexercised_path(self):
        output = self.root / "annotation-evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(status=runner.PASS, recovery=True)
        meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        rows[-1]["code"] = "annotationOpened"; rows[-1]["mode"] = "annotation"
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        self.assertEqual(runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 0)["status"], "FAIL")
        self.assertNotIn("annotation", runner.MODES)

    def test_parent_expiry_or_unknown_cleanup_removes_a_proven_recovery_pass(self):
        result, _ = self.run_fake(status=runner.PASS, recovery=True, advance=901)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertFalse(result["full_cell_accepted"] or result["recovery_evidence_validated"])

    def test_first_failure_latches_across_sessions_and_recovery(self):
        result, _ = self.run_fake(leak=True)
        self.assertEqual(result["status"], "FAIL")
        with runner.Ledger(self.directory) as ledger:
            self.reject(lambda: ledger.new_session(self.clock), "LEDGER_HALTED")
            self.reject(lambda: ledger.reserve("single", "selecting", "system-sleep", self.clock), "LEDGER_HALTED")
            self.reject(ledger.recover, "LEDGER_HALTED")
            self.assertEqual(ledger.state["trials"][0]["status"], "FAIL")

    def test_bad_metadata_consumes_an_attempt_but_never_passes(self):
        result, driver = self.run_fake(malformed=True)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertCountEqual(driver.cleanups, [1234, 1235])
        with runner.Ledger(self.directory) as ledger: self.assertEqual(len(ledger.state["trials"]), 1)

    def test_expired_session_does_not_launch_or_reserve(self):
        self.clock.advance(901)
        with runner.Ledger(self.directory) as ledger:
            self.reject(lambda: ledger.reserve("single", "sck", "menu-lock", self.clock), "SESSION_EXPIRED")
            self.assertEqual(ledger.state["trials"], [])

    def test_wall_sleep_expiration_cannot_hide_behind_monotonic_clock(self):
        self.clock.advance(901, wall_only=True)
        with runner.Ledger(self.directory) as ledger:
            self.reject(lambda: ledger.reserve("single", "sck", "menu-lock", self.clock), "SESSION_EXPIRED")

    def test_timeout_and_late_completion_are_not_successful_recovery(self):
        result, driver = self.run_fake(timeout=True)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertTrue(result["parent_timeout"] and result["process_termination_used"])
        self.assertTrue(all(0 < value <= runner.WAIT_POLL_SECONDS for value in driver.runtime_process.wait_slices))

    def test_sleep_wall_expiry_stops_an_unfinished_child_at_the_next_slice(self):
        before_monotonic = self.clock.monotonic_ns()
        result, driver = self.run_fake(timeout=True, wall_jump_on_wait=True)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertEqual(result["reason"], "PARENT_SESSION_DEADLINE")
        self.assertEqual(self.clock.monotonic_ns(), before_monotonic)
        self.assertEqual(driver.runtime_process.wait_slices, [runner.WAIT_POLL_SECONDS])
        self.assertEqual(driver.runtime_process.terminated, 1)
        self.assertTrue(result["parent_timeout"] and result["process_termination_used"])

    def test_deadline_after_runtime_invalidation_observation_is_not_established(self):
        self.assertEqual(self.run_fake(advance=901)[0]["status"], "NOT_ESTABLISHED")

    def test_security_failure_survives_deadline(self):
        self.assertEqual(self.run_fake(advance=901, leak=True)[0]["status"], "FAIL")

    def test_unknown_cleanup_blocks_future_trials(self):
        result, _ = self.run_fake(cleanup=False)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        with runner.Ledger(self.directory) as ledger:
            self.reject(lambda: ledger.reserve("single", "retained", "menu-lock", self.clock), "LEDGER_HALTED")

    def test_fresh_fixture_identity_is_forwarded_without_process_search(self):
        result, driver = self.run_fake()
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertTrue(result["invalidation_observation_established"])
        args = driver.arguments
        self.assertEqual(args[args.index("--fixture-pid") + 1], "1234")
        self.assertEqual(args[args.index("--fixture-executable") + 1], str(self.tools / "M4Fixture"))
        self.assertEqual(args[args.index("--fixture-sha256") + 1], self.candidate["fixture_sha256"])
        self.assertEqual(args[args.index("--parent-fresh-fixture") + 1], "yes")

    def test_fixture_readiness_failure_still_cleans_up_and_counts_attempt(self):
        result, driver = self.run_fake(ready=False)
        self.assertEqual(result["status"], "NOT_ESTABLISHED")
        self.assertIsNone(driver.runtime_process)
        self.assertEqual(driver.cleanups, [1234])

    def test_interrupted_fixture_launch_without_handle_halts_for_manual_cleanup(self):
        driver = FakeDriver(self.clock, self.candidate)
        def interrupted(_): raise KeyboardInterrupt
        driver.fixture = interrupted
        with runner.Ledger(self.directory) as ledger:
            with self.assertRaises(KeyboardInterrupt):
                runner.run_trial(ledger, "collection", "retained", "menu-lock", driver=driver, clock=self.clock)
            self.assertEqual(ledger.state["halt"], "CLEANUP_UNCONFIRMED")
            self.assertFalse(ledger.state["trials"][0]["result"]["cleanup_confirmed"])

    def test_interrupted_runtime_launch_keeps_unknown_handle_halted(self):
        driver = FakeDriver(self.clock, self.candidate)
        def interrupted(_): raise KeyboardInterrupt
        driver.runtime = interrupted
        with runner.Ledger(self.directory) as ledger:
            with self.assertRaises(KeyboardInterrupt):
                runner.run_trial(ledger, "collection", "retained", "menu-lock", driver=driver, clock=self.clock)
            self.assertEqual(ledger.state["halt"], "CLEANUP_UNCONFIRMED")
            self.assertEqual(driver.cleanups, [1234])

    def test_binary_or_manifest_change_is_rejected(self):
        (self.tools / "SecurityRuntimeTrial").write_bytes(b"different")
        with runner.Ledger(self.directory) as ledger:
            self.reject(ledger.tools, "BINARY_HASH_MISMATCH")
        self.manifest.write_text("{}")
        with runner.Ledger(self.directory) as ledger:
            self.reject(ledger.tools, "MANIFEST_HASH_MISMATCH")

    def test_wrong_source_id_is_rejected(self):
        self.reject(lambda: runner.load_tools(self.manifest, self.manifest_hash, "0" * 40), "SOURCE_ID_MISMATCH")

    def test_symlink_and_corrupt_state_are_rejected(self):
        original = (self.directory / "state.json").read_bytes()
        (self.directory / "state.json").write_text("{")
        self.reject(lambda: runner.Ledger(self.directory), "INVALID_JSON")
        (self.directory / "state.json").write_bytes(original)
        target = self.directory / "state-target.json"; target.write_bytes(original)
        (self.directory / "state.json").unlink(); (self.directory / "state.json").symlink_to(target)
        self.reject(lambda: runner.Ledger(self.directory), "SYMLINK_REJECTED")

    def test_false_return_flags_numeric_bools_and_scope_widening_rejected(self):
        output = self.root / "evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        (output / "trace.json").write_text(json.dumps(rows))
        for key, value in (("worker_ended", False), ("slot_free", 1), ("general_board_access", True), ("os_atomicity_guaranteed", True),
                           ("manual_transition_confirmed", 1), ("invalidation_observation_established", 1),
                           ("invalidation_observation_established", False), ("explicit_recovery_exercised", True), ("full_cell_accepted", True)):
            changed = dict(meta); changed[key] = value
            (output / "metadata.json").write_text(json.dumps(changed))
            with self.assertRaises(runner.Rejected): runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 2)

    def test_duplicate_json_and_unknown_trace_code_are_rejected(self):
        self.reject(lambda: runner.strict_json('{"x":1,"x":2}'), "DUPLICATE_JSON_KEY")
        output = self.root / "evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        rows[0]["code"] = "arbitrary text"
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        self.reject(lambda: runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 2), "TRACE_VALUE_REJECTED")


    def test_new_start_capture_or_permission_request_after_invalidation_is_failure(self):
        output = self.root / "restart-evidence"; output.mkdir(mode=0o700)
        for code in ("operationStarted", "captureRequested", "permissionRequested"):
            for mode in ("single", "collection"):
                meta, rows = evidence(); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
                rows.insert(-1, {"trial": 1, "sequence": len(rows), "relativeNanos": len(rows),
                    "code": code, "mode": mode, "phase": "none", "outcome": "none"})
                rows[-1]["sequence"] += 1; rows[-1]["relativeNanos"] += 1
                meta["evidence_end_sequence"] += 1
                (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
                result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 2)
                self.assertEqual(result["status"], "FAIL", (code, mode))
                self.assertFalse(result["invalidation_observation_established"])

    def test_late_callbacks_and_worker_returns_do_not_imply_automatic_restart(self):
        output = self.root / "return-evidence"; output.mkdir(mode=0o700)
        for code in ("captureCallback", "captureReturned"):
            meta, rows = evidence(); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
            rows.insert(-1, {"trial": 1, "sequence": len(rows), "relativeNanos": len(rows),
                "code": code, "mode": "collection", "phase": "none", "outcome": "none"})
            rows[-1]["sequence"] += 1; rows[-1]["relativeNanos"] += 1
            meta["evidence_end_sequence"] += 1
            (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
            result = runner.read_evidence(output, self.candidate, "collection", "retained", "menu-lock", 2)
            self.assertEqual(result["status"], "NOT_ESTABLISHED")
            self.assertTrue(result["invalidation_observation_established"])
            self.assertFalse(result["full_cell_accepted"])

    def test_post_callback_event_is_not_real_sck_overlap(self):
        output = self.root / "evidence"; output.mkdir(mode=0o700)
        meta, rows = evidence(stage="sck"); meta["fixture_executable_sha256"] = self.candidate["fixture_sha256"]
        rows[2]["code"], rows[4]["code"] = "captureCallback", "protectedDataUnavailable"
        rows[2]["mode"], rows[4]["mode"] = "collection", "none"
        (output / "metadata.json").write_text(json.dumps(meta)); (output / "trace.json").write_text(json.dumps(rows))
        with self.assertRaises(runner.Rejected): runner.read_evidence(output, self.candidate, "collection", "sck", "menu-lock", 2)


if __name__ == "__main__":
    unittest.main()
