"""Finite migration regressions: fake Popen, fabricated scalar packets and temp metadata only."""
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
with mock.patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
    SPEC = importlib.util.spec_from_file_location("policy_migration_runner", ROOT / "scripts/migrate_resource_policy.py")
    runner = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(runner)
SPEC = importlib.util.spec_from_file_location("migration_scalar_fixture", ROOT / "Tests/SecurityResourceAcceptanceTests.py")
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


def packet(mode="control", cycles=30, trial=1, **options):
    """Complete fixed-key protocol, fabricated independently of any native execution."""
    lines = fixture.fixture(mode, cycles, **options).splitlines()
    result = []
    for line in lines:
        kind = line.split()[0].removeprefix("M4_OWNER_")
        present = {bit.split("=", 1)[0] for bit in line.split()[1:]}
        additions = {key: value for key, value in runner.FIXED_FIELDS.get(kind, {}).items() if key not in present}
        if kind == "SCOPE":
            line = line.replace(" trial=1 ", f" trial={trial} ")
        if kind == "HEARTBEAT":
            additions.update(firstTaskEntryElapsedNanoseconds=1 if mode == "async" else -1,
                             firstCallbackElapsedNanoseconds=50_000_000 if mode == "async" else -1)
        result.append(line + "".join(f" {key}={value}" for key, value in additions.items()))
    return ("\n".join(result) + "\n").encode("ascii")


class FakeClock:
    def __init__(self):
        self.mono, self.wall = 100.0, 1_000.0

    def advance(self, seconds):
        self.mono += seconds
        self.wall += seconds


class FakeStream:
    def __init__(self, descriptor):
        self.descriptor, self.closed = descriptor, False

    def fileno(self):
        return self.descriptor

    def close(self):
        self.closed = True


class FakeProcess:
    def __init__(self, clock, data=b"", error=b"", seconds=0.5, wait_effects=()):
        self.stdout, self.stderr = FakeStream(101), FakeStream(102)
        self.buffers = {101: bytearray(data), 102: bytearray(error)}
        self.clock, self.seconds, self.returncode = clock, seconds, None
        self.wait_effects, self.waits = list(wait_effects), []
        self.terminations, self.kills = 0, 0

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.waits.append(timeout)
        if self.wait_effects:
            effect = self.wait_effects.pop(0)
            if isinstance(effect, BaseException):
                raise effect
        if self.returncode is None:
            self.clock.advance(self.seconds)
            self.returncode = 0
        return self.returncode

    def terminate(self):
        self.terminations += 1
        self.returncode = -15

    def kill(self):
        self.kills += 1
        self.returncode = -9


class FakeSelector:
    def __init__(self):
        self.keys = {}

    def register(self, stream, _, name):
        self.keys[stream] = SimpleNamespace(fileobj=stream, data=name)

    def unregister(self, stream):
        del self.keys[stream]

    def get_map(self):
        return self.keys

    def select(self, _):
        return [(key, 1) for key in list(self.keys.values())]

    def close(self):
        self.keys.clear()


class ResourcePolicyMigrationRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="oneclip-policy-migration-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.repo, self.tools, self.output = self.base / "repo", self.base / "tools", self.base / "result"
        self.repo.mkdir(mode=0o700)
        self.tools.mkdir(mode=0o700)
        sources = [*ROOT.glob("OneClip/*.swift"), *(ROOT / name for name in (
            "Tests/M4ResourceOwnershipProbe.swift", "Tests/OutputReferenceObservation.swift",
            "Tests/SecurityRuntimeTrial.swift", "Tests/M4Fixture.swift"))]
        implementations = [ROOT / "scripts" / name for name in ("migrate_resource_policy.py",
            "resource_policy_migration.py", "run_security_resources.py", "run_security_trial.py",
            "prepare_resource_observation.py")]
        for source in sources + implementations:
            target = self.repo / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        inputs = {str(path.relative_to(ROOT)): runner.sha(path.read_bytes()) for path in sources}
        self.source_id = hashlib.sha1(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        binaries = {}
        for name in ("ownership-probe", "SecurityRuntimeTrial", "M4Fixture"):
            binary = self.tools / name
            binary.write_bytes(("fake metadata never executed " + name).encode("ascii"))
            binary.chmod(0o700)
            binaries[name] = runner.sha(binary.read_bytes())
        self.manifest = self.tools / "manifest.json"
        self.manifest.write_bytes(runner.encoded({"schema": "oneclip-security-tools-v1",
            "sourceIDKind": "build-inputs-sha1", "sourceID": self.source_id,
            "inputs": inputs, "optimization": "-O", "toolchain": {"swift": "synthetic", "sdk": "synthetic"},
            "binaries": binaries}))
        self.manifest_sha = runner.sha(self.manifest.read_bytes())
        self.old = fixture.policy()
        self.old.pop("outputReleaseSchema")
        self.old.pop("outputObservationSemantics")
        self.old_path = self.base / "old-policy.json"
        self.old_path.write_bytes(runner.encoded(self.old))
        self.old_sha = runner.sha(self.old_path.read_bytes())
        self.clock, self.processes = FakeClock(), []

    def fake_children(self, stack, packets=None, *, errors=None, process_factory=None):
        packets = list(packets) if packets is not None else [packet(m, c, t) for m, c, t, _ in runner.PLAN]
        errors = list(errors or [b""] * len(packets))
        live_read = os.read

        def launch(argv, **kwargs):
            index = len(self.processes)
            if process_factory:
                process = process_factory(index)
            else:
                process = FakeProcess(self.clock, packets[index], errors[index],
                                      31.0 if argv[2] == "control" else 0.5)
            self.processes.append(process)
            return process

        def read(descriptor, maximum):
            if descriptor not in (101, 102):
                return live_read(descriptor, maximum)
            content = self.processes[-1].buffers[descriptor]
            chunk = bytes(content[:maximum])
            del content[:maximum]
            return chunk

        popen = stack.enter_context(mock.patch.object(runner.subprocess, "Popen", side_effect=launch))
        stack.enter_context(mock.patch.object(runner.selectors, "DefaultSelector", side_effect=FakeSelector))
        stack.enter_context(mock.patch.object(runner.os, "set_blocking"))
        stack.enter_context(mock.patch.object(runner.os, "read", side_effect=read))
        stack.enter_context(mock.patch.object(runner.time, "monotonic", side_effect=lambda: self.clock.mono))
        stack.enter_context(mock.patch.object(runner.time, "time", side_effect=lambda: self.clock.wall))
        return popen

    def run_series(self, output=None):
        return runner.run_migration(self.old_path, self.old_sha, self.manifest, self.manifest_sha,
                                    self.source_id, output or self.output, repo=self.repo)

    def test_all_five_required_preserve_old_numbers_and_fixed_minimal_arguments(self):
        with ExitStack() as stack:
            launch = self.fake_children(stack)
            code, result = self.run_series()
        self.assertEqual((code, result["childLaunches"], result["policyCreated"]), (0, 5, True))
        self.assertFalse(result["resourceAcceptance"])
        migrated = json.loads((self.output / "policy.json").read_bytes())
        for key, value in self.old.items():
            if key not in ("binarySHA256", "sourceID"):
                self.assertEqual(migrated[key], value)
        self.assertEqual(migrated["outputReleaseSchema"], 2)
        for call, (mode, cycles, trial, seconds) in zip(launch.call_args_list, runner.PLAN):
            self.assertEqual(call.args[0], [str(self.tools / "ownership-probe"), "--mode", mode,
                "--workload", "standard", "--cycles", str(cycles), "--trial", str(trial),
                "--peak-bytes", str(self.old["processPeakCapBytes"])])
            self.assertEqual(call.kwargs["env"], {"PATH": "/usr/bin:/bin", "TMPDIR": str(self.output), "LANG": "C"})
            self.assertIs(call.kwargs["stdin"], subprocess.DEVNULL)
            self.assertTrue(call.kwargs["close_fds"])
        self.assertEqual(len(list(self.output.glob("receipt-*.json"))), 5)
        self.assertTrue(all(p.stdout.closed and p.stderr.closed for p in self.processes))
        self.assertEqual(self.old_sha, runner.sha(self.old_path.read_bytes()))

    def test_hash_source_manifest_and_profile_mismatches_launch_nothing(self):
        original_source = self.repo / "OneClip/M0ImageCore.swift"
        cases = ("old_hash", "manifest_hash", "source_hash", "legacy_profile", "source_id")
        for case in cases:
            with self.subTest(case=case), mock.patch.object(runner.subprocess, "Popen") as launch:
                source_bytes, old_bytes = original_source.read_bytes(), self.old_path.read_bytes()
                arguments = [self.old_path, self.old_sha, self.manifest, self.manifest_sha, self.source_id,
                             self.base / ("invalid-" + case)]
                if case == "old_hash": arguments[1] = "0" * 64
                if case == "manifest_hash": arguments[3] = "0" * 64
                if case == "source_id": arguments[4] = "0" * 40
                if case == "source_hash": original_source.write_bytes(source_bytes + b"\n")
                if case == "legacy_profile":
                    altered = dict(self.old, workload="small")
                    self.old_path.write_bytes(runner.encoded(altered))
                    arguments[1] = runner.sha(self.old_path.read_bytes())
                try:
                    with self.assertRaises((ValueError, runner.tools_loader.Rejected)):
                        runner.run_migration(*arguments, repo=self.repo)
                    launch.assert_not_called()
                    self.assertFalse(arguments[-1].exists())
                finally:
                    original_source.write_bytes(source_bytes)
                    self.old_path.write_bytes(old_bytes)

    def test_first_numeric_violation_saves_receipt_before_guard_and_stops(self):
        with ExitStack() as stack:
            launch = self.fake_children(stack, [packet(growth=runner.resources.MIB)])
            guard = runner.migration.guard_summary

            def inspect(summary, policy, **scope):
                self.assertTrue((self.output / "receipt-1.json").is_file())
                return guard(summary, policy, **scope)

            stack.enter_context(mock.patch.object(runner.migration, "guard_summary", side_effect=inspect))
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count, result["childLaunches"]), (2, 1, 1))
        self.assertEqual(result["reason"], "summary_growth_exceeds_frozen_E")
        self.assertIsNotNone(json.loads((self.output / "receipt-1.json").read_bytes())["summary"])
        self.assertFalse((self.output / "policy.json").exists())

    def test_own_manifest_read_is_hash_pinned_before_loader_handoff(self):
        with mock.patch.object(runner.tools_loader, "load_tools", return_value={}) as loader, \
                mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(runner.RunnerError, "^manifest_hash_mismatch$"):
                runner.run_migration(self.old_path, self.old_sha, self.manifest, "0" * 64,
                                     self.source_id, self.output, repo=self.repo)
        loader.assert_not_called()
        launch.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_first_applicable_unknown_stops_before_async_and_never_writes_policy(self):
        packets = [packet("control", 30, trial) for trial in (1, 2, 3)]
        unknown = packet("sync", 10).replace(b"outputReferenceReleased=1 outputWasObserved=1", b"outputReferenceReleased=-1 outputWasObserved=0")
        unknown = unknown.replace(b"outputReferenceState=observed_released", b"outputReferenceState=unobserved")
        with ExitStack() as stack:
            launch = self.fake_children(stack, packets + [unknown])
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count), (2, 4))
        self.assertEqual(result["reason"], "summary_proof_not_current")
        receipt = json.loads((self.output / "receipt-4.json").read_bytes())
        self.assertFalse(receipt["summary"]["outputReleaseEvidence"]["coverageEstablished"])
        self.assertFalse((self.output / "receipt-5.json").exists())
        self.assertFalse((self.output / "policy.json").exists())

    def test_ten_cycle_warmup_jump_with_zero_first_last_delta_stops(self):
        lines = packet("sync", 10).decode("ascii").splitlines()
        for index, line in enumerate(lines):
            if line.startswith("M4_OWNER_MEMORY ") and " series=measured " in line:
                tokens = line.split()
                for j, token in enumerate(tokens):
                    key, _, value = token.partition("=")
                    if key in ("rss", "physicalFootprint"):
                        tokens[j] = f"{key}={int(value) + 9*runner.resources.MIB}"
                lines[index] = " ".join(tokens)
        jump = ("\n".join(lines) + "\n").encode("ascii")
        packets = [packet("control", 30, trial) for trial in (1, 2, 3)] + [jump]
        with ExitStack() as stack:
            launch = self.fake_children(stack, packets)
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count, result["reason"]), (2, 4, "summary_growth_exceeds_frozen_E"))
        summary = json.loads((self.output / "receipt-4.json").read_bytes())["summary"]
        self.assertEqual(summary["metrics"]["rss"]["delta"], 0)
        self.assertEqual(summary["migrationWindow"]["growth"]["rss"], 9*runner.resources.MIB)
        self.assertFalse((self.output / "policy.json").exists())

    def test_cross_output_replay_refuses_without_a_second_launch(self):
        with ExitStack() as stack:
            launch = self.fake_children(stack, [b"unknown\n"])
            self.assertEqual(self.run_series()[0], 2)
            claim = next(self.tools.glob("resource-policy-migration-*.json"))
            original = claim.read_bytes()
            code, result = self.run_series(self.base / "second-output")
        self.assertEqual((code, launch.call_count, result["childLaunches"]), (2, 1, 0))
        self.assertEqual(result["reason"], "series_already_reserved")
        self.assertEqual(claim.read_bytes(), original)

    def test_existing_output_and_exclusive_receipt_never_overwrite(self):
        self.output.mkdir(mode=0o700)
        marker = self.output / "receipt-1.json"
        marker.write_bytes(b"existing metadata")
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaises(runner.filesystem.PreparationError):
                self.run_series()
        launch.assert_not_called()
        directory = runner.filesystem._open_directory_path(self.output)
        try:
            with self.assertRaises(FileExistsError):
                runner.save_new(directory, "receipt-1.json", {"new": True})
        finally:
            os.close(directory)
        self.assertEqual(marker.read_bytes(), b"existing metadata")

    def test_unknown_stdout_and_stderr_are_not_saved_or_hashed(self):
        secret = b"fictional-private-payload-never-save"
        with ExitStack() as stack:
            launch = self.fake_children(stack, [secret + b"\n"], errors=[secret])
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count), (2, 1))
        self.assertEqual(result["reason"], "stderr_present_discarded")
        receipt = json.loads((self.output / "receipt-1.json").read_bytes())
        self.assertIsNone(receipt["summary"])
        for path in [*self.output.iterdir(), *self.tools.glob("resource-policy-migration-*.json")]:
            data = path.read_bytes()
            self.assertNotIn(secret, data)
            self.assertNotIn(hashlib.sha256(secret).hexdigest().encode(), data)
        self.assertFalse(receipt["capture"]["rawSaved"])
        self.assertFalse(receipt["capture"]["rawHashed"])

    def test_framing_scope_and_unknown_fields_reject_before_summary(self):
        good = packet()
        bad = [good[:-1], good.replace(b"\n", b"\r\n", 1), good + b"\0\n",
            good + b"\xff\n", good.replace(b" trial=1 ", b" trial=2 "),
            good.replace(b" sourceCount=0 ", b" sourceCount=4 "),
            good.replace(b" heartbeatSeries=2 ", b" heartbeatSeries=2 extra=fictional "),
            good.replace(b" mode=control ", b" mode=product-states "),
            good.replace(b" synthetic=1 ", b" synthetic=1 synthetic=1 "),
            b"X" * (runner.LINE_CAP + 1) + b"\n", b"x\n" * (runner.RECORD_CAP + 1)]
        with mock.patch.object(runner.migration, "sanitize_summary", wraps=runner.migration.sanitize_summary) as sanitize:
            for data in bad:
                with self.subTest(length=len(data)), self.assertRaisesRegex(runner.RunnerError, "^summary_not_established$"):
                    runner.receive(data, "control", 30, 1, self.old)
            sanitize.assert_not_called()

    def test_fifo_symlink_and_unsafe_temp_ancestor_refuse_before_launch(self):
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            fifo = self.base / "fifo-policy"
            os.mkfifo(fifo)
            with self.assertRaises(runner.RunnerError): runner.owned_bytes(fifo, 65_536)
            link = self.base / "linked-policy"
            link.symlink_to(self.old_path)
            with self.assertRaises(OSError): runner.owned_bytes(link, 65_536)
            unsafe = self.base / "unsafe"
            unsafe.mkdir(mode=0o777)
            unsafe.chmod(0o777)
            (unsafe / "child").mkdir(mode=0o700)
            with self.assertRaises(runner.RunnerError): runner.private_temp_directory(unsafe / "child")
        launch.assert_not_called()

    def test_post_capture_binding_change_keeps_receipt_but_cannot_qualify(self):
        original = runner.capture_once

        def changed(*arguments):
            result = original(*arguments)
            path = self.repo / "OneClip/M0ImageCore.swift"
            path.write_bytes(path.read_bytes() + b"\n")
            return result

        with ExitStack() as stack:
            launch = self.fake_children(stack, [packet()])
            stack.enter_context(mock.patch.object(runner, "capture_once", side_effect=changed))
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count, result["reason"]), (2, 1, "input_changed"))
        receipt = json.loads((self.output / "receipt-1.json").read_bytes())
        self.assertIsNotNone(receipt["summary"])
        self.assertEqual(receipt["capture"]["reason"], "input_changed")
        self.assertFalse((self.output / "policy.json").exists())

    def test_capture_caps_are_bounded_cleanup_is_owned_and_no_next_child(self):
        for stream, data, reason in (("stdout", b"x" * (runner.STDOUT_CAP + 1), "stdout_cap"),
                                     ("stderr", b"x" * (runner.STDERR_CAP + 1), "stderr_cap")):
            with self.subTest(stream=stream), ExitStack() as stack:
                self.processes.clear()
                launch = self.fake_children(stack, process_factory=lambda _: FakeProcess(
                    self.clock, data if stream == "stdout" else b"",
                    data if stream == "stderr" else b""))
                raw, capture = runner.capture_once([str(self.tools / "ownership-probe")], self.base, 15, runner.Budget(180))
            self.assertEqual((launch.call_count, capture["reason"]), (1, reason))
            self.assertLessEqual(len(raw), runner.STDOUT_CAP)
            self.assertLessEqual(capture["stderrBytesDiscarded"], runner.STDERR_CAP + 1)
            self.assertTrue(capture["cleanupConfirmed"])
            self.assertEqual(self.processes[0].terminations, 1)
            self.assertEqual(self.processes[0].waits, [2])

    def test_wait_timeout_and_cleanup_unknown_preserve_one_handle(self):
        for unknown in (False, True):
            with self.subTest(unknown=unknown), ExitStack() as stack:
                self.processes.clear()
                effects = [subprocess.TimeoutExpired("fixed", 15)]
                if unknown: effects += [RuntimeError("do not serialize"), RuntimeError("do not serialize")]
                launch = self.fake_children(stack, process_factory=lambda _: FakeProcess(self.clock, wait_effects=effects))
                _, capture = runner.capture_once([str(self.tools / "ownership-probe")], self.base, 15, runner.Budget(180))
            self.assertEqual(launch.call_count, 1)
            self.assertEqual(capture["reason"], "cleanup_unknown" if unknown else "deadline")
            self.assertEqual(capture["cleanupConfirmed"], not unknown)
            self.assertEqual(self.processes[0].waits, [15, 2, 2] if unknown else [15, 2])

    def test_clock_failure_and_insufficient_cleanup_slack_launch_nothing(self):
        with ExitStack() as stack:
            launch = self.fake_children(stack, [])
            whole = runner.Budget(18)
            _, capture = runner.capture_once([str(self.tools / "ownership-probe")], self.base, 15, whole)
            self.assertEqual(capture["reason"], "whole_deadline")
            self.assertFalse(capture["launchAttempted"])
            self.clock.mono = float("nan")
            _, invalid = runner.capture_once([str(self.tools / "ownership-probe")], self.base, 15, whole)
            self.assertEqual(invalid["reason"], "clock_invalid")
            self.assertIsNone(invalid["elapsedSeconds"])
            self.assertFalse(invalid["launchAttempted"])
            launch.assert_not_called()

    def test_wall_clock_regression_after_launch_cannot_qualify(self):
        with ExitStack() as stack:
            launch = self.fake_children(stack, process_factory=lambda _: FakeProcess(self.clock))
            original = runner.stop_owned

            def rollback(process):
                result = original(process)
                self.clock.wall -= 1_000
                return result

            stack.enter_context(mock.patch.object(runner, "stop_owned", side_effect=rollback))
            _, capture = runner.capture_once([str(self.tools / "ownership-probe")], self.base, 15, runner.Budget(180))
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(capture["reason"], "clock_invalid")
        self.assertTrue(capture["processHandleAcquired"])
        self.assertTrue(capture["cleanupConfirmed"])
        self.assertIsNone(capture["elapsedWallSeconds"])

    def test_pre_policy_deadline_prevents_policy_after_five_fake_proofs(self):
        original = runner.migration.migrate_policy

        def expired(*arguments, **keywords):
            result = original(*arguments, **keywords)
            self.clock.advance(181)
            return result

        with ExitStack() as stack:
            launch = self.fake_children(stack)
            stack.enter_context(mock.patch.object(runner.migration, "migrate_policy", side_effect=expired))
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count, result["reason"]), (2, 5, "whole_deadline"))
        self.assertFalse((self.output / "policy.json").exists())

    def test_failed_final_receipt_write_keeps_actual_launch_count_and_fixed_reason(self):
        original = runner.save_new

        def cannot_save(directory, name, value):
            if name == "migration-result.json":
                raise OSError("fictional private OS message must not escape")
            return original(directory, name, value)

        with ExitStack() as stack:
            launch = self.fake_children(stack, [b"unknown\n"])
            stack.enter_context(mock.patch.object(runner, "save_new", side_effect=cannot_save))
            code, result = self.run_series()
        self.assertEqual((code, launch.call_count, result["childLaunches"]), (2, 1, 1))
        self.assertEqual(result["reason"], "result_receipt_not_saved")
        self.assertNotIn("fictional private", json.dumps(result))
        self.assertTrue((self.output / "receipt-1.json").is_file())
        self.assertFalse((self.output / "migration-result.json").exists())


if __name__ == "__main__":
    unittest.main()
