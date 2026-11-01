"""Runner/manifest regressions with fake processes only; no Swift or image execution."""

from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
with mock.patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
    SPEC = importlib.util.spec_from_file_location("render_ownership_runner", ROOT / "scripts/run_render_ownership_pilot.py")
    runner = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(runner)
# Reuse the separately reviewed fixed-protocol fixture, not a Swift child.
FIXTURE_SPEC = importlib.util.spec_from_file_location("render_protocol_fixture", ROOT / "Tests/RenderOwnershipReceiverTests.py")
fixture = importlib.util.module_from_spec(FIXTURE_SPEC)
FIXTURE_SPEC.loader.exec_module(fixture)


class FakeStream:
    def __init__(self, descriptor):
        self.descriptor, self.closed = descriptor, False

    def fileno(self):
        return self.descriptor

    def close(self):
        self.closed = True


class FakeProcess:
    def __init__(self, wait_effects=()):
        self.stdout, self.stderr = FakeStream(101), FakeStream(102)
        self.returncode = None
        self.wait_effects = list(wait_effects)
        self.waits, self.terminations, self.kills = [], 0, 0

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.waits.append(timeout)
        if self.wait_effects:
            effect = self.wait_effects.pop(0)
            if isinstance(effect, BaseException):
                raise effect
        if self.returncode is None:
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


def fake_capture(stack, data, *, stderr=b"", process=None):
    process = process or FakeProcess()
    buffers = {101: bytearray(data), 102: bytearray(stderr)}
    live_read = os.read

    def read(descriptor, maximum):
        if descriptor not in buffers:
            return live_read(descriptor, maximum)
        content = bytes(buffers[descriptor][:maximum])
        del buffers[descriptor][:maximum]
        return content

    launch = stack.enter_context(mock.patch.object(runner.subprocess, "Popen", return_value=process))
    stack.enter_context(mock.patch.object(runner.selectors, "DefaultSelector", return_value=FakeSelector()))
    stack.enter_context(mock.patch.object(runner.os, "set_blocking"))
    stack.enter_context(mock.patch.object(runner.os, "read", side_effect=read))
    return launch, process


class RenderOwnershipRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="oneclip-render-runner-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.repo, self.tools, self.output = self.base / "repo", self.base / "tools", self.base / "result"
        for name in runner.INPUTS:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        self.compiler = self.base / "synthetic-compiler"
        self.compiler.write_bytes(b"synthetic compiler metadata; never executed")
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            runner.prepare_build(self.repo, self.tools, self.compiler)
            (self.tools / runner.BINARY).write_bytes(b"synthetic executable metadata; never executed")
            (self.tools / runner.BINARY).chmod(0o700)
            self.manifest = runner.finish_build(self.repo, self.tools, self.compiler)
            launch.assert_not_called()

    def test_build_binding_has_exact_derived_sources_and_never_runs(self):
        _, manifest, manifest_hash = runner.verify_build(self.repo, self.tools)
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(manifest_hash, hashlib.sha256((self.tools / "manifest.json").read_bytes()).hexdigest())
        original = (self.repo / "OneClip/M0ImageCore.swift").read_bytes()
        observed = (self.tools / "M0ImageCore.observed.swift").read_bytes()
        self.assertEqual(observed.count(runner.preparation.INSERTION), 1)
        self.assertEqual(observed.replace(runner.preparation.INSERTION, b"", 1), original)
        self.assertFalse(manifest["pilotExecuted"])
        self.assertFalse(manifest["resourceAcceptance"])

    def test_withdrawn_public_function_rejects_before_inputs_outputs_or_launch(self):
        with mock.patch.object(runner, "verify_build") as verify, \
                mock.patch.object(runner.preparation, "_new_output_directory") as create, \
                mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(runner.RunnerError, "^observer_withdrawn$"):
                runner.run_pilot(self.repo, self.tools, self.output)
        verify.assert_not_called(); create.assert_not_called(); launch.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.tools / "launch-claim.json").exists())

    def test_withdrawn_cli_records_zero_launches_without_validating_paths(self):
        arguments = ["run_render_ownership_pilot.py", "--tools-dir", "/unread-closed-observer",
                     "--output-dir", "/uncreated-closed-observer"]
        output = io.StringIO()
        with mock.patch.object(sys, "argv", arguments), \
                mock.patch.object(sys, "stdout", output), \
                mock.patch.object(runner, "verify_build") as verify, \
                mock.patch.object(runner.subprocess, "Popen") as launch:
            self.assertEqual(runner.main(), 2)
        verify.assert_not_called(); launch.assert_not_called()
        self.assertEqual(json.loads(output.getvalue()), {
            "state": "NOT_ESTABLISHED", "reason": "observer_withdrawn",
            "childLaunches": 0, "resourceAcceptance": False})

    def test_withdrawn_builder_uses_no_toolchain_and_creates_no_output(self):
        target = self.base / "not-created-by-withdrawn-builder"
        for arguments in (["--output-dir", str(target)], ["--help"], []):
            with self.subTest(arguments=arguments):
                result = subprocess.run(["/bin/bash", str(ROOT / "scripts/build_render_ownership_tools.sh"),
                                         *arguments], env={"PATH": "/no-observer-toolchain"},
                                        capture_output=True, timeout=3, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(json.loads(result.stdout), {
                    "state": "NOT_ESTABLISHED", "reason": "observer_withdrawn",
                    "childLaunches": 0, "resourceAcceptance": False})
                self.assertFalse(target.exists())

    def test_one_launch_no_args_minimal_environment_and_object_receipt(self):
        with ExitStack() as stack:
            launch, process = fake_capture(stack, fixture.packet())
            code, report = runner._run_bound_trial(self.repo, self.tools, self.output)
        self.assertEqual(code, 0)
        self.assertEqual(report["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")
        self.assertEqual(report["resourceSummary"]["status"], "NOT_EXERCISED")
        launch.assert_called_once()
        self.assertEqual(launch.call_args.args[0], [str(self.tools / runner.BINARY)])
        self.assertEqual(launch.call_args.kwargs["env"],
                         {"PATH": "/usr/bin:/bin", "TMPDIR": str(self.output), "LANG": "C"})
        self.assertTrue(process.stdout.closed and process.stderr.closed)
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         ["object-receipt.json", "run-binding.json"])
        receipt = json.loads((self.output / "object-receipt.json").read_text())
        self.assertFalse(receipt["rawSaved"])
        self.assertFalse(receipt["resourceAcceptance"])

    def test_build_launch_reservation_prevents_replay_with_a_new_output(self):
        with ExitStack() as stack:
            launch, _ = fake_capture(stack, fixture.packet())
            runner._run_bound_trial(self.repo, self.tools, self.output)
            old_claim = (self.tools / "launch-claim.json").read_bytes()
            with self.assertRaisesRegex(runner.RunnerError, "launch_already_claimed"):
                runner._run_bound_trial(self.repo, self.tools, self.base / "second-result")
            launch.assert_called_once()
        self.assertEqual((self.tools / "launch-claim.json").read_bytes(), old_claim)

    def test_source_binary_and_derived_mismatch_each_stop_before_launch(self):
        for path in (self.repo / "Tests/M4RenderOwnershipPilot.swift", self.tools / runner.BINARY,
                     self.tools / "M0ImageCore.observed.swift"):
            original = path.read_bytes()
            path.write_bytes(original + b"\nsynthetic mismatch\n")
            with self.subTest(name=path.name), mock.patch.object(runner.subprocess, "Popen") as launch:
                with self.assertRaises(runner.RunnerError):
                    runner._run_bound_trial(self.repo, self.tools, self.output)
                launch.assert_not_called()
                self.assertFalse(self.output.exists())
            path.write_bytes(original)

    def test_source_changed_after_capture_preserves_receipt_but_cannot_pass(self):
        live_capture = runner.capture_once

        def capture_then_change_source(*args):
            captured = live_capture(*args)
            source = self.repo / "OneClip/CaptureSecurityTrace.swift"
            source.write_bytes(source.read_bytes() + b"\n// synthetic post-capture change\n")
            return captured

        with ExitStack() as stack:
            launch, _ = fake_capture(stack, fixture.packet())
            stack.enter_context(mock.patch.object(runner, "capture_once", side_effect=capture_then_change_source))
            code, report = runner._run_bound_trial(self.repo, self.tools, self.output)
        launch.assert_called_once()
        self.assertEqual(code, 2)
        self.assertEqual(report["protocolStatus"], "VALID_FIXED_PROTOCOL")
        self.assertEqual(report["objectObservation"], "NOT_ESTABLISHED")
        self.assertEqual(report["capture"]["reason"], "input_changed")
        saved = json.loads((self.output / "object-receipt.json").read_text())
        self.assertEqual(saved["capture"]["reason"], "input_changed")
        self.assertEqual(saved["objectObservation"], "NOT_ESTABLISHED")
        self.assertIsNotNone(saved["rows"])

    def test_existing_output_does_not_reserve_or_launch(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_bytes(b"synthetic existing file")
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaises(runner.preparation.PreparationError):
                runner._run_bound_trial(self.repo, self.tools, self.output)
            launch.assert_not_called()
        self.assertFalse((self.tools / "launch-claim.json").exists())
        self.assertEqual(marker.read_bytes(), b"synthetic existing file")

    def test_symlink_binary_and_unsafe_temp_ancestor_stop_before_launch(self):
        binary = self.tools / runner.BINARY
        backup = self.tools / "saved-binary"
        binary.rename(backup)
        binary.symlink_to(backup)
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaises(OSError):
                runner._run_bound_trial(self.repo, self.tools, self.output)
            launch.assert_not_called()
        binary.unlink(); backup.rename(binary)
        parent = self.base / "unsafe"
        parent.mkdir(mode=0o700)
        moved = parent / "tools"
        self.tools.rename(moved)
        parent.chmod(0o777)
        with mock.patch.object(runner.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(runner.RunnerError, "temporary_parent_unsafe"):
                runner._run_bound_trial(self.repo, moved, self.output)
            launch.assert_not_called()

    def test_fifo_and_directory_types_are_rejected_before_any_read(self):
        for mode in (stat.S_IFIFO | 0o600, stat.S_IFDIR | 0o700):
            with self.subTest(mode=mode), ExitStack() as stack:
                stack.enter_context(mock.patch.object(runner.preparation, "_open_directory_path", return_value=100))
                opened = stack.enter_context(mock.patch.object(runner.os, "open", return_value=101))
                stack.enter_context(mock.patch.object(runner.os, "fstat", return_value=SimpleNamespace(st_mode=mode)))
                closed = stack.enter_context(mock.patch.object(runner.os, "close"))
                read = stack.enter_context(mock.patch.object(runner.os, "read"))
                with self.assertRaisesRegex(runner.RunnerError, "input_file_invalid"):
                    runner._regular(self.tools / "synthetic-input", 65_536)
                self.assertTrue(opened.call_args.args[1] & os.O_NONBLOCK)
                self.assertTrue(opened.call_args.args[1] & os.O_NOFOLLOW)
                read.assert_not_called()
                self.assertEqual(closed.call_args_list, [mock.call(101), mock.call(100)])

    def test_deadline_checks_wall_clock_as_well_as_monotonic(self):
        with ExitStack() as stack:
            launch, process = fake_capture(stack, fixture.packet())
            stack.enter_context(mock.patch.object(runner.time, "monotonic", return_value=100.0))
            stack.enter_context(mock.patch.object(runner.time, "time", side_effect=[100.0, 116.0, 116.0]))
            _, metadata = runner.capture_once(self.tools / runner.BINARY, self.output)
        launch.assert_called_once()
        self.assertEqual(metadata["reason"], "deadline")
        self.assertTrue(metadata["cleanupConfirmed"])
        self.assertEqual(process.terminations, 1)

    def test_invalid_clock_remains_unobserved_instead_of_zero(self):
        with ExitStack() as stack:
            _, process = fake_capture(stack, fixture.packet())
            stack.enter_context(mock.patch.object(runner.time, "monotonic", return_value=100.0))
            stack.enter_context(mock.patch.object(runner.time, "time", side_effect=[100.0, 99.0, 99.0]))
            _, metadata = runner.capture_once(self.tools / runner.BINARY, self.output)
        self.assertEqual(metadata["reason"], "clock_invalid")
        self.assertIsNone(metadata["elapsedSeconds"])
        self.assertIsNone(metadata["elapsedWallSeconds"])
        self.assertTrue(metadata["cleanupConfirmed"])
        self.assertEqual(process.terminations, 1)

    def test_stdout_and_stderr_caps_stop_and_reap_the_same_child(self):
        for stdout, stderr, reason in ((b"x" * (runner.STDOUT_CAP + 1), b"", "stdout_cap"),
                                       (b"", b"x" * (runner.STDERR_CAP + 1), "stderr_cap")):
            with self.subTest(reason=reason), ExitStack() as stack:
                launch, process = fake_capture(stack, stdout, stderr=stderr)
                data, metadata = runner.capture_once(self.tools / runner.BINARY, self.output)
                launch.assert_called_once()
                self.assertLessEqual(len(data), runner.STDOUT_CAP)
                self.assertEqual(metadata["reason"], reason)
                self.assertTrue(metadata["cleanupConfirmed"])
                self.assertEqual(process.terminations, 1)

    def test_interrupted_wait_still_reaps_owned_handle_without_retry(self):
        process = FakeProcess(wait_effects=[KeyboardInterrupt()])
        with ExitStack() as stack:
            launch, _ = fake_capture(stack, fixture.packet(), process=process)
            _, metadata = runner.capture_once(self.tools / runner.BINARY, self.output)
        launch.assert_called_once()
        self.assertEqual(metadata["reason"], "parent_interrupted")
        self.assertTrue(metadata["cleanupConfirmed"])
        self.assertEqual(process.terminations, 1)

    def test_cleanup_escalates_and_uncertain_cleanup_never_claims_stopped(self):
        process = FakeProcess(wait_effects=[runner.subprocess.TimeoutExpired("synthetic", 2), OSError("synthetic")])
        self.assertFalse(runner._stop_owned(process))
        self.assertEqual(process.waits, [2, 2])
        self.assertEqual((process.terminations, process.kills), (1, 1))

    def test_launch_failure_with_no_handle_is_unknown_and_not_retried(self):
        with mock.patch.object(runner.subprocess, "Popen", side_effect=KeyboardInterrupt()) as launch:
            data, metadata = runner.capture_once(self.tools / runner.BINARY, self.output)
        launch.assert_called_once()
        self.assertEqual(data, b"")
        self.assertEqual(metadata["reason"], "cleanup_unknown")
        self.assertFalse(metadata["cleanupConfirmed"])
        self.assertIsNone(metadata["exit"])

    def test_unknown_output_and_stderr_are_not_saved_and_do_not_pass(self):
        private = b"synthetic-unapproved-text"
        with ExitStack() as stack:
            launch, _ = fake_capture(stack, private, stderr=private)
            code, report = runner._run_bound_trial(self.repo, self.tools, self.output)
        launch.assert_called_once()
        self.assertEqual(code, 2)
        self.assertEqual(report["objectObservation"], "NOT_ESTABLISHED")
        for path in self.output.iterdir():
            self.assertNotIn(private, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
