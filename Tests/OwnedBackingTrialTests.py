"""Synthetic JSONL, fake children and virtual clocks only; never runs native code."""
from contextlib import ExitStack
import copy
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
    SPEC = importlib.util.spec_from_file_location("owned_backing_runner", ROOT / "scripts/run_owned_backing_trial.py")
    runner = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(runner)


def record(ordinal=1, **changes):
    row = dict(schema=runner.SCHEMA, ordinal=ordinal, arm=runner.ARMS[ordinal-1], status="OBSERVED", reason="none",
        bufferBytes=16_384, createdBuffers=1, releasedBuffers=1, providerCallbacks=1,
        contextCallbacks=0 if ordinal == 1 else 1, heldProviderCallbacks=0, heldLiveBuffers=1,
        heldLiveBytes=16_384, finalLiveBuffers=0, finalLiveBytes=0,
        pngBytes=128 if ordinal == 3 else 0, elapsedNanoseconds=20_000)
    row.update(changes)
    return row


def packet(rows=None):
    return ("\n".join(json.dumps(row, sort_keys=True) for row in
                     (rows if rows is not None else [record(i) for i in range(1, 4)])) + "\n").encode("ascii")


class Clock:
    def __init__(self):
        self.mono, self.wall = 100.0, 1_000.0

    def advance(self, seconds):
        self.mono += seconds
        self.wall += seconds


class Stream:
    def __init__(self, fd):
        self.fd, self.closed = fd, False

    def fileno(self):
        return self.fd

    def close(self):
        self.closed = True


class Process:
    def __init__(self, clock, raw=None, error=b"", exit_code=0, seconds=0.25, wait_errors=()):
        self.stdout, self.stderr = Stream(100_001), Stream(100_002)
        self.buffers = {100_001: bytearray(packet() if raw is None else raw), 100_002: bytearray(error)}
        self.clock, self.seconds, self.exit_code = clock, seconds, exit_code
        self.returncode, self.terminated, self.killed = None, 0, 0
        self.wait_errors = list(wait_errors)

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        if self.wait_errors:
            error = self.wait_errors.pop(0)
            if error:
                raise error
        if self.returncode is None:
            self.clock.advance(self.seconds)
            self.returncode = self.exit_code
        return self.returncode

    def terminate(self):
        self.terminated += 1
        self.returncode = -15

    def kill(self):
        self.killed += 1
        self.returncode = -9


class Selector:
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


class OwnedBackingTrialTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="oneclip-owned-backing-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.base.chmod(0o700)
        self.repo, self.tools = self.base / "repo", self.base / "tools"
        self.repo.mkdir(mode=0o700)
        self.tools.mkdir(mode=0o700)
        for name in runner.INPUTS:
            source = self.repo / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("synthetic metadata only: " + name)
        self.binary = self.tools / runner.BINARY
        self.binary.write_bytes(b"fake binary metadata, never executable by tests")
        self.binary.chmod(0o700)
        self.manifest = self.tools / "manifest.json"
        self.data = {"schema": runner.TOOLS_SCHEMA,
            "inputs": {name: runner.sha((self.repo / name).read_bytes()) for name in runner.INPUTS},
            "binarySHA256": runner.sha(self.binary.read_bytes()),
            "toolchain": {"swift": "synthetic compiler", "sdk": "/synthetic/sdk"},
            "flags": [*runner.BASE_FLAGS, "-module-cache-path", str(self.tools / "module-cache"),
                      "-sdk", "/synthetic/sdk"]}
        self.save_manifest()
        self.output = self.base / "result"
        self.clock = Clock()

    def save_manifest(self):
        self.manifest.write_text(json.dumps(self.data, sort_keys=True))
        self.manifest_sha = runner.sha(self.manifest.read_bytes())

    def fake(self, process=None, popen_effect=None):
        stack = ExitStack()
        self.addCleanup(stack.close)
        process = process if process is not None else Process(self.clock)
        original_read = os.read

        def read(fd, count):
            if fd not in process.buffers:
                return original_read(fd, count)
            data = bytes(process.buffers[fd][:count])
            del process.buffers[fd][:count]
            return data

        stack.enter_context(mock.patch.object(runner.safe.time, "monotonic", lambda: self.clock.mono))
        stack.enter_context(mock.patch.object(runner.safe.time, "time", lambda: self.clock.wall))
        stack.enter_context(mock.patch.object(runner.selectors, "DefaultSelector", Selector))
        stack.enter_context(mock.patch.object(runner.os, "set_blocking"))
        stack.enter_context(mock.patch.object(runner.os, "read", side_effect=read))
        popen = stack.enter_context(mock.patch.object(runner.subprocess, "Popen", return_value=process,
                                                       side_effect=popen_effect))
        return process, popen

    def run_fake(self):
        return runner.run_trial(self.manifest, self.manifest_sha, self.output, self.base, repo=self.repo)

    def rejected(self, raw, reason=None):
        with self.assertRaises(runner.Rejected) as value:
            runner.receive(raw)
        if reason is not None:
            self.assertEqual(value.exception.reason, reason)

    def test_observed_and_terminal_not_established_packets(self):
        self.assertEqual(len(runner.receive(packet())), 3)
        for ordinal in (1, 2, 3):
            rows = [record(i) for i in range(1, ordinal)]
            rows.append(record(ordinal, status="NOT_ESTABLISHED", reason="buffer_retained",
                               elapsedNanoseconds=8_500_000_000))
            self.assertEqual(runner.receive(packet(rows))[-1]["reason"], "buffer_retained")

    def test_json_framing_size_duplicate_and_unknown_fields(self):
        good = packet()
        bad = [b"", good[:-1], good.replace(b"\n", b"\r\n"), b"\xff\n", b"\0\n",
               b"{}\n", b"{}\n" * 4, b" " * 2_049 + b"\n", b"x" * 16_385,
               packet([record(1, extra="private marker must not survive")]),
               packet([record(1)]).replace(b'"ordinal": 1', b'"ordinal": 1, "ordinal": 1'),
               packet([record(1)]).replace(b'"ordinal": 1', b'"ordinal": NaN')]
        for raw in bad:
            with self.subTest(raw_size=len(raw)):
                self.rejected(raw)

    def test_arm_order_stop_and_incomplete_protocol(self):
        self.rejected(packet([record(2)]), "arm_order_invalid")
        self.rejected(packet([record(1)]), "incomplete_protocol")
        failure = record(1, status="NOT_ESTABLISHED", reason="allocation_failed")
        self.rejected(packet([failure, record(2)]), "stop_violation")

    def test_type_ranges_and_observation_invariants(self):
        changes = [{"createdBuffers": True}, {"bufferBytes": 16_384.0}, {"providerCallbacks": 2},
                   {"heldProviderCallbacks": 1}, {"heldLiveBytes": 0}, {"finalLiveBuffers": 1},
                   {"releasedBuffers": 0}, {"elapsedNanoseconds": 2_000_000_001},
                   {"elapsedNanoseconds": 9_007_199_254_740_992}, {"pngBytes": -1},
                   {"reason": "unknown private error"}, {"status": "NOT_ESTABLISHED"},
                   {"contextCallbacks": 1}, {"pngBytes": 1}]
        for change in changes:
            with self.subTest(change=change):
                self.rejected(packet([record(1, **change)]))
        self.rejected(packet([record(1), record(2, contextCallbacks=0), record(3)]))
        self.rejected(packet([record(1), record(2), record(3, pngBytes=0)]))

    def test_manifest_exact_binding_and_flags(self):
        tools, binding = runner.verify_inputs(self.repo, self.manifest, self.manifest_sha)
        self.assertEqual(tools, self.tools)
        self.assertEqual(binding["inputs"], self.data["inputs"])
        for mutation in (lambda d: d["inputs"].pop(next(iter(d["inputs"]))),
                         lambda d: d["flags"].append("-Onone"),
                         lambda d: d.update(extra="ignored is forbidden"),
                         lambda d: d["toolchain"].update(sdk="bad\nsdk")):
            modified = copy.deepcopy(self.data)
            mutation(modified)
            self.manifest.write_text(json.dumps(modified))
            with self.assertRaises(runner.Rejected):
                runner.verify_inputs(self.repo, self.manifest, runner.sha(self.manifest.read_bytes()))

    def test_source_binary_and_manifest_hash_mismatch(self):
        with self.assertRaises(runner.Rejected) as error:
            runner.verify_inputs(self.repo, self.manifest, "0" * 64)
        self.assertEqual(error.exception.reason, "manifest_hash_mismatch")
        source = self.repo / next(iter(runner.INPUTS))
        source.write_bytes(b"changed source")
        with self.assertRaises(runner.Rejected) as error:
            runner.verify_inputs(self.repo, self.manifest, self.manifest_sha)
        self.assertEqual(error.exception.reason, "source_mismatch")
        self.data["inputs"][str(source.relative_to(self.repo))] = runner.sha(source.read_bytes())
        self.save_manifest()
        self.binary.write_bytes(b"changed binary")
        with self.assertRaises(runner.Rejected) as error:
            runner.verify_inputs(self.repo, self.manifest, self.manifest_sha)
        self.assertEqual(error.exception.reason, "binary_mismatch")

    def test_unsafe_source_and_nonprivate_reservation_are_rejected_without_launch(self):
        process, popen = self.fake()
        source = self.repo / next(iter(runner.INPUTS))
        source.chmod(0o666)
        with self.assertRaises(ValueError):
            self.run_fake()
        popen.assert_not_called()
        source.chmod(0o600)
        self.base.chmod(0o755)
        with self.assertRaises(ValueError):
            self.run_fake()
        popen.assert_not_called()

    def test_symlink_fifo_and_hardlink_sources_fail_without_launch(self):
        process, popen = self.fake()
        source = self.repo / "Tests/OwnedBackingLifetimeProbe.swift"
        original = source.read_bytes()
        backup = self.base / "synthetic-backup"
        backup.write_bytes(original)
        for kind in ("symlink", "fifo", "hardlink"):
            source.unlink()
            if kind == "symlink":
                source.symlink_to(backup)
            elif kind == "fifo":
                os.mkfifo(source, 0o600)
            else:
                os.link(backup, source)
            with self.subTest(kind=kind):
                with self.assertRaises((ValueError, OSError)):
                    self.run_fake()
                popen.assert_not_called()
            source.unlink()
            source.write_bytes(original)

    def test_single_launch_saved_receipt_and_no_resource_acceptance(self):
        process, popen = self.fake()
        code, result = self.run_fake()
        self.assertEqual(code, 0)
        self.assertEqual(result["state"], "ESTABLISHED_DIAGNOSTIC_ONLY")
        self.assertFalse(result["resourceAcceptance"])
        self.assertEqual(result["childLaunches"], 1)
        popen.assert_called_once()
        args, keywords = popen.call_args
        self.assertEqual(args[0], [str(self.binary), "--owned-backing-lifetime-v1"])
        self.assertEqual(keywords["stdin"], subprocess.DEVNULL)
        self.assertTrue(keywords["close_fds"])
        self.assertEqual(set(keywords["env"]), {"PATH", "TMPDIR", "LANG"})
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertTrue(receipt["bindingAfterMatches"])
        self.assertTrue(receipt["capture"]["cleanupConfirmed"])
        self.assertTrue(process.stdout.closed and process.stderr.closed)
        self.assertEqual(runner.sha((self.output / "receipt.json").read_bytes()), result["receiptSHA256"])
        self.assertEqual({path.name for path in self.output.iterdir()}, {"plan.json", "receipt.json", "result.json"})

    def test_fixed_claim_rejects_output_or_binary_rebuild_retry(self):
        process, popen = self.fake()
        self.assertEqual(self.run_fake()[0], 0)
        self.output = self.base / "second-output"
        self.binary.write_bytes(b"different fake binary after rebuild")
        self.data["binarySHA256"] = runner.sha(self.binary.read_bytes())
        self.save_manifest()
        code, result = self.run_fake()
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "series_already_reserved")
        self.assertEqual(result["childLaunches"], 0)
        popen.assert_called_once()

    def test_native_not_established_is_saved_before_qualification(self):
        row = record(1, status="NOT_ESTABLISHED", reason="buffer_retained",
                     releasedBuffers=0, providerCallbacks=0, finalLiveBuffers=1, finalLiveBytes=16_384)
        process, popen = self.fake(Process(self.clock, packet([row]), exit_code=2))
        code, result = self.run_fake()
        self.assertEqual((code, result["reason"]), (2, "native_not_established"))
        self.assertEqual(json.loads((self.output / "receipt.json").read_text())["records"], [row])
        self.assertEqual(result["childLaunches"], 1)
        popen.assert_called_once()

    def test_unknown_output_and_stderr_are_not_saved_or_hashed(self):
        marker = b"private-unrecognized-string"
        process, popen = self.fake(Process(self.clock, raw=marker + b"\n", error=marker))
        code, result = self.run_fake()
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "stderr_present_discarded")
        for path in self.output.iterdir():
            content = path.read_bytes()
            self.assertNotIn(marker, content)
            self.assertNotIn(runner.sha(marker).encode(), content)
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertIsNone(receipt["records"])
        self.assertFalse(receipt["rawHashed"])

    def test_capture_caps_discard_and_reap_owned_handle(self):
        for raw, error, reason in ((b"x" * (runner.STDOUT_CAP + 1), b"", "stdout_cap"),
                                   (b"", b"e" * (runner.STDERR_CAP + 1), "stderr_cap")):
            with self.subTest(reason=reason):
                process, popen = self.fake(Process(self.clock, raw=raw, error=error))
                data, metadata = runner.capture_once(self.binary, self.base, runner.safe.Budget(14))
                self.assertEqual(metadata["reason"], reason)
                self.assertLessEqual(len(data), runner.STDOUT_CAP)
                self.assertLessEqual(metadata["stderrBytesDiscarded"], runner.STDERR_CAP + 1)
                self.assertTrue(metadata["processHandleAcquired"] and metadata["cleanupConfirmed"])
                self.assertEqual(process.terminated, 1)

    def test_effective_child_deadline_reserves_cleanup(self):
        process, popen = self.fake()
        whole = runner.safe.Budget(14)
        self.clock.advance(1)
        _, metadata = runner.capture_once(self.binary, self.base, whole)
        self.assertEqual(metadata["childDeadlineSeconds"], 9)
        self.assertIsNone(metadata["reason"])
        self.assertTrue(metadata["launchAttempted"])

    def test_no_launch_when_cleanup_is_all_remaining_budget(self):
        process, popen = self.fake()
        whole = runner.safe.Budget(14)
        self.clock.advance(10)
        _, metadata = runner.capture_once(self.binary, self.base, whole)
        self.assertEqual(metadata["reason"], "whole_deadline")
        self.assertFalse(metadata["launchAttempted"])
        self.assertFalse(metadata["processHandleAcquired"])
        popen.assert_not_called()

    def test_wall_clock_reversal_after_launch_is_not_accepted(self):
        process, popen = self.fake()
        original_wait = process.wait
        def reversed_wait(timeout):
            result = original_wait(timeout)
            self.clock.wall -= 1
            return result
        process.wait = reversed_wait
        _, metadata = runner.capture_once(self.binary, self.base, runner.safe.Budget(14))
        self.assertEqual(metadata["reason"], "clock_invalid")
        self.assertTrue(metadata["processHandleAcquired"] and metadata["cleanupConfirmed"])

    def test_launch_failure_is_counted_without_raw_error(self):
        process, popen = self.fake(popen_effect=OSError("private exception text"))
        code, result = self.run_fake()
        self.assertEqual(code, 2)
        self.assertEqual(result["childLaunches"], 1)
        self.assertEqual(result["reason"], "launch_failed")
        self.assertNotIn("private exception", (self.output / "receipt.json").read_text())

    def test_source_change_after_launch_fails_with_typed_receipt(self):
        process, popen = self.fake()
        original_wait = process.wait
        def changed_wait(timeout):
            value = original_wait(timeout)
            (self.repo / "Tests/OwnedBackingLifetimeProbe.swift").write_bytes(b"changed")
            return value
        process.wait = changed_wait
        code, result = self.run_fake()
        self.assertEqual((code, result["reason"]), (2, "input_changed"))
        self.assertFalse(json.loads((self.output / "receipt.json").read_text())["bindingAfterMatches"])

    def test_receipt_is_saved_before_native_qualification(self):
        process, popen = self.fake()
        original = runner.safe.save_new
        def tamper(descriptor, name, value):
            digest = original(descriptor, name, value)
            if name == "receipt.json":
                (self.output / name).write_bytes(b"{}\n")
            return digest
        with mock.patch.object(runner.safe, "save_new", side_effect=tamper):
            code, result = self.run_fake()
        self.assertEqual((code, result["reason"]), (2, "receipt_changed"))

    def test_cleanup_failure_and_deadline_remain_unestablished(self):
        process, popen = self.fake(Process(self.clock, seconds=11))
        _, metadata = runner.capture_once(self.binary, self.base, runner.safe.Budget(14))
        self.assertEqual(metadata["reason"], "deadline")
        self.assertTrue(metadata["cleanupConfirmed"])
        process, popen = self.fake(Process(self.clock))
        with mock.patch.object(runner.safe, "stop_owned", return_value=False):
            _, failure = runner.capture_once(self.binary, self.base, runner.safe.Budget(14))
        self.assertTrue(failure["launchAttempted"])
        self.assertTrue(failure["processHandleAcquired"])
        self.assertFalse(failure["cleanupConfirmed"])
        self.assertEqual(failure["reason"], "cleanup_unknown")


if __name__ == "__main__":
    unittest.main()
