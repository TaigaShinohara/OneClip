"""Parser/policy regression tests. Fabricated numeric records; no probe/app execution."""
from __future__ import annotations

import importlib.util
import io
from contextlib import redirect_stdout
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("resource_acceptance", Path(__file__).resolve().parents[1] / "scripts" / "run_security_resources.py")
assert spec and spec.loader
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)
MIB = resources.MIB


def fixture(mode="sync", cycles=30, *, growth=0, heartbeat=50_000_000, unavailable=None):
    """A complete fixed synthetic evidence packet, including all required measurement points."""
    no_images = mode in ("control", "product-control")
    owner = mode in resources.OWNER_MODES
    owner_cancelled = mode in resources.OWNER_CANCEL_MODES
    cancelled = mode == "render-before-encode" or mode in resources.CANCELLATION_BASELINE
    product = mode in ("product-states", "product-control")
    full_png = mode in ("sync", "async")
    png_returned = full_png or mode in resources.OWNER_FULL_MODES
    recovery_scope = "coordinator_worker_slot" if owner_cancelled else "m0_wrapper_only" if mode in resources.CANCELLATION_BASELINE else "not_applicable"
    idle = [0] if cycles == 10 else [0, 5, 15, 30]
    lines = [f"M4_OWNER_SCOPE schema=2 synthetic=1 freshProcess=1 mode={mode} workload=standard sourceCount={0 if no_images else 1 if owner and mode.startswith('product-single') else 4} board=not_exercised heartbeatSeries=2 warmupCycles=2 measuredCycles={cycles} idleTargetsSeconds={'_'.join(map(str,idle))} trial=1 recoveryScope={recovery_scope}",
             f"M4_OWNER_LIMITS imageBudgetBytes={384*MIB} processPeakCapBytes={1024*MIB}",
             "M4_OWNER_IDLE_POLICY explicitRunLoopPump=0"]

    def memory(series, iteration, phase, value, elapsed=0):
        fields = {"rss": value, "physicalFootprint": value - MIB, "processHighWater": value + MIB,
                  "internalBytes": value - 2*MIB, "reusableBytes": 0, "compressedBytes": 0,
                  "mallocSizeInUse": MIB, "mallocSizeAllocated": 4*MIB, "mallocBlocksInUse": 2000}
        if unavailable:
            fields[unavailable] = -1
        lines.append(f"M4_OWNER_MEMORY phase={phase} series={series} iteration={iteration} elapsedNanoseconds={elapsed} unit=bytes " + " ".join(f"{k}={v}" for k,v in fields.items()))

    memory("baseline", 0, "baseline", 20*MIB)
    for series, count in (("warmup", 2), ("measured", cycles)):
        for iteration in range(1, count+1):
            value = 30*MIB + (growth*iteration if series == "measured" else 0)
            source_count = 0 if no_images else 7 if mode == "product-states" else 4
            if owner and mode.startswith("product-single"):
                source_count = 1
            recovery = 1000000 if mode in resources.CANCELLATION_BASELINE else -1
            lines.append(f"M4_OWNER_OWNERSHIP series={series} iteration={iteration} compositionSucceeded={int(not cancelled)} expectedCancellation={int(cancelled)} batchOwnerReleased=1 outputReferenceReleased=1 outputWasObserved={int(full_png)} sourceLiveBytes=0 sourceCreated={source_count} sourceReleased={source_count} pngBytes={1000 if png_returned else 0} actualImageBytes={10*MIB if full_png else 0} peakCapExceeded=0 elapsedNanoseconds=100000000 recoveryNanoseconds={recovery} passed=1")
            phases = ["generation_pre", "sources_ready"]
            if mode not in ("source-only", "product-control", "product-states"):
                phases += ["before_allocation"] + ([] if owner and mode.startswith("product-single") else [f"source_{i}" for i in range(4)]) + ["before_encoding"]
                if mode != "render-before-encode" and "cancel-before-encode" not in mode:
                    phases += ["after_encoding"]
                if not cancelled:
                    phases += ["before_result"]
            if product:
                phases += ["view_torn_down"]
                states = ["empty"] if mode == "product-control" else ["ready", "preview", "copied_kept", "hidden_kept", "candidate_keep", "kept_original", "candidate_accept", "accepted", "single_copy_failure", "ended"]
                for phase in states:
                    lines.append(f"M4_OWNER_PRODUCT_STATE series={series} iteration={iteration} phase={phase} actualProductDrawCalls=0 productWindowDisplayed=0 passed=1")
                lines.append(f"M4_OWNER_PRODUCT_RELEASE series={series} iteration={iteration} coordinatorReleased=1 singleReleased=1 nativeReleased=1 viewReleased=1 passed=1")
                workers = 0 if mode == "product-control" else 9
                lines.append(f"M4_OWNER_TRACE series={series} iteration={iteration} entries=120 dropped=0 capacity=8192 enabled=1 workersStarted={workers} workersReturned={workers} slotsAcquired={workers} slotsReleased={workers}")
            if owner:
                phases += ["coordinator_worker_slot_released"]
                method = ("stop" if "-after-" in mode else "invalidate") if owner_cancelled else "none"
                owner_name = "single" if mode.startswith("product-single") else "collection"
                lines.append(f"M4_OWNER_COORDINATOR series={series} iteration={iteration} owner={owner_name} cancellationRequested={int(owner_cancelled)} cancellationMethod={method} busyAtCancellation={int(owner_cancelled)} slotAtCancellation={int(owner_cancelled)} workerIsWorking=0 slotOccupied=0 afterCancellationAdoptions=0 writerCalls={0 if owner_cancelled else 1} recoveryNanoseconds={recovery} workersStarted=5 workersReturned=5 slotsAcquired=5 slotsReleased=5 traceDropped=0 passed=1")
                lines.append(f"M4_OWNER_COORDINATOR_RELEASE series={series} iteration={iteration} singleReleased=1 collectionReleased=1 passed=1")
            for phase in phases:
                memory(series, iteration, phase, value)
            memory(series, iteration, "scope_released", value)
    required = mode in ("async", "product-states", "product-control") or owner or mode in resources.CANCELLATION_BASELINE
    lines.append(f"M4_OWNER_HEARTBEAT required={int(required)} periodNanoseconds=50000000 count={10 if required else 0} maximumGapNanoseconds={heartbeat if required else 0}")
    for series in ("warmup", "measured"):
        lines.append(f"M4_OWNER_HEARTBEAT_SERIES series={series} required={int(required)} count={5 if required else 0} maximumGapNanoseconds={heartbeat if required else 0} wholeCrossingIntervalIncluded=1 acceptanceGate=aggregate")
    for seconds in idle:
        memory("idle", seconds, "idle", 30*MIB + growth*cycles, seconds*1_000_000_000)
    lines.append(f"M4_OWNER_RESULT warmupCycles=2 warmupFailures=0 measuredCycles={cycles} measuredFailures=0 idleObservations={len(idle)-1} idleInterrupted=0")
    return "\n".join(lines) + "\n"


def policy(*, product=False, b=0):
    controls = [resources.summarize(fixture("control", growth=b//30)) for _ in range(3)]
    baselines = [resources.summarize(fixture(mode, 10)) for mode in (resources.FULL_MODES if product else ("sync", "async"))]
    product_controls = [resources.summarize(fixture("product-control")) for _ in range(3)] if product else None
    return resources.build_policy(controls, baselines, ram_bytes=16*1024*MIB,
                                  binary_sha="a"*64, source_id="b"*40, product_controls=product_controls)


class SecurityResourceAcceptanceTests(unittest.TestCase):
    def test_normal_sync_and_async_are_finite_only(self):
        for mode in ("sync", "async"):
            result = resources.evaluate(resources.summarize(fixture(mode)), policy())
            self.assertEqual(result["acceptance"], "passed_finite_current_mac")
            self.assertEqual(result["physicalErasure"], "not_claimed")

    def test_missing_or_negative_metrics_are_not_zero(self):
        for metric in ("rss", "physicalFootprint", "processHighWater"):
            with self.assertRaises(resources.EvidenceError):
                resources.summarize(fixture(unavailable=metric))
            text = fixture().replace(f"{metric}=31457280 ", "", 1)
            if text != fixture():
                with self.assertRaises(resources.EvidenceError):
                    resources.summarize(text)

    def test_truncation_duplicate_and_owner_failure_never_pass(self):
        original = fixture()
        duplicate = next(x for x in original.splitlines() if "phase=scope_released series=measured iteration=1 " in x)
        for text in ("\n".join(original.splitlines()[:-1]), original + duplicate + "\n",
                     original.replace("sourceLiveBytes=0", "sourceLiveBytes=1", 1),
                     original.replace("sourceReleased=4", "sourceReleased=3", 1)):
            with self.assertRaises(resources.EvidenceError):
                resources.summarize(text)

    def test_absent_idle_is_not_an_implicit_zero(self):
        text = "\n".join(x for x in fixture().splitlines() if not "phase=idle series=idle iteration=15 " in x)
        with self.assertRaises(resources.EvidenceError):
            resources.summarize(text)

    def test_missing_source_checkpoint_is_incomplete(self):
        text = "\n".join(x for x in fixture().splitlines() if not "phase=source_2 series=measured iteration=1 " in x)
        with self.assertRaises(resources.EvidenceError):
            resources.summarize(text)

    def test_png_on_cancel_and_missing_png_on_success_are_rejected(self):
        for text in (fixture("async-cancel-after-encode").replace("pngBytes=0", "pngBytes=10", 1),
                     fixture().replace("pngBytes=1000", "pngBytes=0", 1)):
            with self.assertRaises(resources.EvidenceError):
                resources.summarize(text)

    def test_unexplained_first_block_excess_requires_investigation(self):
        result = resources.evaluate(resources.summarize(fixture(growth=MIB)), policy())
        self.assertEqual(result["acceptance"], "needs_investigation")
        self.assertIn("rss_unexplained_growth", result["unexplainedExcess"])

    def test_two_consecutive_block_excesses_fail(self):
        result = resources.evaluate(resources.summarize(fixture(cycles=90, growth=MIB)), policy())
        self.assertEqual(result["acceptance"], "failed")
        self.assertIn("rss_continued_growth_two_blocks", result["violations"])

    def test_rss_and_footprint_thresholds_are_separate(self):
        frozen = policy()
        frozen["thresholds"]["core"]["physicalFootprint"]["E"] = 64*MIB
        result = resources.evaluate(resources.summarize(fixture(growth=MIB)), frozen)
        self.assertEqual(result["unexplainedExcess"], ["rss_unexplained_growth"])

    def test_high_control_variation_cannot_relax_threshold(self):
        controls = [resources.summarize(fixture("control", growth=MIB)) for _ in range(3)]
        with self.assertRaisesRegex(resources.EvidenceError, "control_variation"):
            resources.calibration_guard(controls[0], 1024*MIB)
        with self.assertRaisesRegex(resources.EvidenceError, "control_variation"):
            resources.build_policy(controls, [resources.summarize(fixture("async", 10))],
                                   ram_bytes=16*1024*MIB, binary_sha="a"*64, source_id="b"*40)

    def test_formula_floor_cap_and_current_mac_identity(self):
        frozen = policy()
        self.assertEqual(frozen["thresholds"]["core"]["rss"], {"B": 0, "E": 8*MIB})
        self.assertEqual(frozen["processPeakCapBytes"], 1024*MIB)
        self.assertEqual(frozen["recoveryCapsNanoseconds"]["async"], 2_000_000_000)
        baseline = resources.summarize(fixture("async", 10))
        baseline["durationMaximumNanoseconds"] = 15_000_000_000
        capped = resources.build_policy([resources.summarize(fixture("control")) for _ in range(3)], [baseline],
                                        ram_bytes=4*1024*MIB, binary_sha="a"*64, source_id="b"*40)
        self.assertEqual(capped["processPeakCapBytes"], 512*MIB)
        self.assertEqual(capped["recoveryCapsNanoseconds"]["async"], 30_000_000_000)

    def test_full_baseline_over_fifteen_seconds_stops_before_policy_or_expansion(self):
        controls = [resources.summarize(fixture("control")) for _ in range(3)]
        product_controls = [resources.summarize(fixture("product-control")) for _ in range(3)]
        for mode in resources.FULL_MODES:
            for duration in (15_000_000_001, 25_000_000_000):
                baseline = resources.summarize(fixture(mode, 10))
                baseline["durationMaximumNanoseconds"] = duration
                with self.assertRaisesRegex(resources.EvidenceError, "full_baseline_maximum_over_15_seconds"):
                    resources.calibration_guard(baseline, 1024*MIB)
                with self.assertRaisesRegex(resources.EvidenceError, "full_baseline_maximum_over_15_seconds"):
                    resources.build_policy(controls, [baseline], ram_bytes=16*1024*MIB,
                                           binary_sha="a"*64, source_id="b"*40,
                                           product_controls=product_controls if mode == "product-states" else None)

    def test_full_trial_duration_is_not_a_cancellation_recovery_gate(self):
        frozen = policy()
        for mode in ("sync", "async", "async-cancel-after-encode"):
            summary = resources.summarize(fixture(mode))
            summary["durationMaximumNanoseconds"] = 25_000_000_000
            self.assertEqual(resources.evaluate(summary, frozen)["acceptance"], "passed_finite_current_mac")
        summary["recoveryMaximumNanoseconds"] = 2_000_000_001
        self.assertIn("worker_recovery_cap", resources.evaluate(summary, frozen)["violations"])

    def test_heartbeat_gap_and_missing_callback_fail(self):
        result = resources.evaluate(resources.summarize(fixture("async", heartbeat=251_000_000)), policy())
        self.assertEqual(result["acceptance"], "failed")
        with self.assertRaises(resources.EvidenceError):
            resources.summarize(fixture("async").replace("count=10 maximumGap", "count=0 maximumGap"))

    def test_real_product_ownership_and_state_coverage_are_required(self):
        frozen = policy(product=True)
        self.assertEqual(resources.evaluate(resources.summarize(fixture("product-states")), frozen)["acceptance"], "passed_finite_current_mac")
        for text in (fixture("product-states").replace("viewReleased=1", "viewReleased=0", 1),
                     fixture("product-states").replace("productWindowDisplayed=0", "productWindowDisplayed=1", 1),
                     fixture("product-states").replace("dropped=0", "dropped=1", 1),
                     fixture("product-states").replace("workersReturned=9", "workersReturned=8", 1),
                     "\n".join(x for x in fixture("product-states").splitlines() if not "phase=candidate_accept " in x)):
            with self.assertRaises(resources.EvidenceError):
                resources.summarize(text)

    def test_cancellation_recovery_uses_frozen_workload_cap(self):
        summary = resources.summarize(fixture("async-cancel-after-encode"))
        self.assertEqual(resources.evaluate(summary, policy())["acceptance"], "passed_finite_current_mac")
        summary["recoveryMaximumNanoseconds"] = 2_000_000_001
        self.assertIn("worker_recovery_cap", resources.evaluate(summary, policy())["violations"])

    def test_actual_coordinator_cancel_requires_busy_worker_and_released_slot(self):
        frozen = policy(product=True)
        for mode in resources.OWNER_CANCEL_MODES:
            text = fixture(mode)
            summary = resources.summarize(text)
            self.assertEqual(summary["recoveryScope"], "coordinator_worker_slot")
            self.assertEqual(resources.evaluate(summary, frozen)["acceptance"], "passed_finite_current_mac")
            for before, after in (("busyAtCancellation=1", "busyAtCancellation=0"),
                                  ("slotAtCancellation=1", "slotAtCancellation=0"),
                                  ("workerIsWorking=0", "workerIsWorking=1"),
                                  ("slotOccupied=0", "slotOccupied=1"),
                                  ("afterCancellationAdoptions=0", "afterCancellationAdoptions=1"),
                                  ("writerCalls=0", "writerCalls=1"),
                                  ("workersReturned=5", "workersReturned=4"),
                                  ("singleReleased=1", "singleReleased=0")):
                with self.assertRaises(resources.EvidenceError):
                    resources.summarize(text.replace(before, after, 1))

    def test_single_and_collection_recovery_use_their_own_full_baselines(self):
        frozen = policy(product=True)
        frozen["recoveryCapsNanoseconds"].update({"async": 30_000_000_000, "product-states": 30_000_000_000,
                                                "product-single": 2_000_000_000, "product-collection": 4_000_000_000})
        for owner in ("single", "collection"):
            summary = resources.summarize(fixture(f"product-{owner}-cancel-after-encode"))
            summary["recoveryMaximumNanoseconds"] = 3_000_000_000
            actual = resources.evaluate(summary, frozen)["acceptance"]
            self.assertEqual(actual, "failed" if owner == "single" else "passed_finite_current_mac")
        del frozen["recoveryCapsNanoseconds"]["product-single"]
        with self.assertRaisesRegex(resources.EvidenceError, "owner_specific"):
            resources.evaluate(resources.summarize(fixture("product-single-cancel-before-encode")), frozen)

    def test_wrapper_cancellation_cannot_claim_coordinator_scope(self):
        wrapper = fixture("async-cancel-before-encode")
        self.assertEqual(resources.summarize(wrapper)["recoveryScope"], "m0_wrapper_only")
        with self.assertRaisesRegex(resources.EvidenceError, "recovery_measurement_scope"):
            resources.summarize(wrapper.replace("recoveryScope=m0_wrapper_only", "recoveryScope=coordinator_worker_slot"))

    def mocked_fresh(self, text, *, mode="async", cycles=30, mutate_binary=False, exit_code=0):
        # Popen is replaced: these tests never execute the placeholder file or any app/process.
        with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
            out = Path(directory)
            probe = out / "placeholder"
            probe.write_bytes(b"fixed-test-placeholder")
            expected = resources.digest(probe)
            class FakeProcess:
                def __init__(self, argv, *, stdout, stderr, env):
                    stdout.write(text)
                def wait(self, timeout):
                    if mutate_binary:
                        probe.write_bytes(b"changed-test-placeholder")
                    return exit_code
            with mock.patch.object(resources.subprocess, "Popen", FakeProcess):
                return resources.fresh(probe, out, mode=mode, workload="standard", cycles=cycles, trial=1,
                                       peak_bytes=1024*MIB, timeout=1, expected_binary_sha=expected)

    def test_fresh_child_requested_mode_workload_and_cycles_must_match(self):
        self.assertEqual(self.mocked_fresh(fixture("async"))["mode"], "async")
        for text in (fixture("sync"), fixture("async").replace("workload=standard", "workload=large"), fixture("async", 60)):
            with self.assertRaisesRegex(resources.EvidenceError, "requested_scope_mismatch"):
                self.mocked_fresh(text)

    def test_fresh_binary_identity_is_checked_before_and_after_every_child(self):
        result = self.mocked_fresh(fixture("async"))
        self.assertEqual(result["binarySHA256Before"], result["binarySHA256After"])
        for code in (0, 1):
            with self.assertRaisesRegex(resources.EvidenceError, "binary_changed_during_fresh_child"):
                self.mocked_fresh(fixture("async"), mutate_binary=True, exit_code=code)
        with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
            probe = Path(directory) / "placeholder"
            probe.write_bytes(b"fixed-test-placeholder")
            with mock.patch.object(resources.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(resources.EvidenceError, "binary_changed_before_fresh_child"):
                    resources.fresh(probe, Path(directory), mode="async", workload="standard", cycles=30,
                                    trial=1, peak_bytes=1024*MIB, timeout=1, expected_binary_sha="0"*64)
                launch.assert_not_called()

    def test_series_diagnostics_never_remove_cold_aggregate_from_gate(self):
        text = fixture("product-control", heartbeat=861_439_375)
        text = text.replace("series=measured required=1 count=5 maximumGapNanoseconds=861439375", "series=measured required=1 count=5 maximumGapNanoseconds=50000000")
        summary = resources.summarize(text)
        self.assertEqual(summary["heartbeat"]["seriesDiagnostic"]["measured"]["maximumGapNanoseconds"], 50_000_000)
        with self.assertRaisesRegex(resources.EvidenceError, "heartbeat_exceeds"):
            resources.calibration_guard(summary, 1024*MIB)
        for malformed in (
                "\n".join(x for x in text.splitlines() if not x.startswith("M4_OWNER_HEARTBEAT_SERIES series=warmup ")),
                text.replace("wholeCrossingIntervalIncluded=1", "wholeCrossingIntervalIncluded=0", 1),
                text.replace("acceptanceGate=aggregate", "acceptanceGate=measured_only", 1),
                text.replace("series=measured required=1 count=5", "series=measured required=1 count=11", 1)):
            with self.assertRaises(resources.EvidenceError):
                resources.summarize(malformed)

    def test_first_deadline_diagnostics_never_excuse_an_800ms_cold_gap(self):
        text = fixture("product-control", heartbeat=800_000_000)
        text = text.replace("M4_OWNER_HEARTBEAT required=1 ",
            "M4_OWNER_HEARTBEAT firstTaskEntryElapsedNanoseconds=800000000 "
            "firstCallbackElapsedNanoseconds=800000000 firstDeadlineFromStart=1 required=1 ")
        summary = resources.summarize(text)
        self.assertEqual(summary["heartbeat"]["maximumGapNanoseconds"], 800_000_000)
        with self.assertRaisesRegex(resources.EvidenceError, "heartbeat_exceeds"):
            resources.calibration_guard(summary, 1024*MIB)
        result = resources.evaluate(summary, policy(product=True))
        self.assertEqual(result["acceptance"], "failed")
        self.assertIn("main_actor_heartbeat_cap", result["violations"])

    def test_no_callback_remains_unobserved_with_first_deadline_diagnostics(self):
        text = fixture("product-control", heartbeat=800_000_000)
        text = text.replace("M4_OWNER_HEARTBEAT required=1 periodNanoseconds=50000000 count=10 ",
            "M4_OWNER_HEARTBEAT firstTaskEntryElapsedNanoseconds=-1 "
            "firstCallbackElapsedNanoseconds=-1 firstDeadlineFromStart=1 required=1 "
            "periodNanoseconds=50000000 count=0 ")
        with self.assertRaisesRegex(resources.EvidenceError, "heartbeat_unobserved"):
            resources.summarize(text)

    def interrupted_fresh(self, initial_exception, *, stubborn=False, cleanup_exception=None,
                          mutate_binary=False):
        with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
            out = Path(directory)
            probe = out / "placeholder"
            probe.write_bytes(b"fixed-test-placeholder")
            expected = resources.digest(probe)
            events = []
            class FakeProcess:
                def __init__(self, argv, *, stdout, stderr, env):
                    self.waits = 0
                def poll(self):
                    events.append("poll"); return None
                def wait(self, timeout):
                    self.waits += 1
                    events.append(("wait", timeout))
                    if self.waits == 1:
                        if mutate_binary: probe.write_bytes(b"changed-test-placeholder")
                        raise initial_exception
                    if cleanup_exception is not None:
                        raise cleanup_exception
                    if stubborn and self.waits == 2:
                        raise resources.subprocess.TimeoutExpired("fixed-placeholder", timeout)
                    return -9 if stubborn else -15
                def terminate(self):
                    events.append("terminate")
                def kill(self):
                    events.append("kill")
            try:
                with mock.patch.object(resources.subprocess, "Popen", FakeProcess):
                    resources.fresh(probe, out, mode="async", workload="standard", cycles=30,
                                    trial=1, peak_bytes=1024*MIB, timeout=1, expected_binary_sha=expected)
            except BaseException as error:
                return error, events
            self.fail("interrupted child unexpectedly completed")

    def test_interrupted_wait_reaps_only_owned_handle_with_bounded_escalation(self):
        for interrupted in (KeyboardInterrupt(), RuntimeError("fixed-wait-failure")):
            error, events = self.interrupted_fresh(interrupted, stubborn=True)
            self.assertIs(error, interrupted)
            self.assertEqual(events, [("wait", 1), "poll", "terminate", ("wait", 5), "kill", ("wait", 5)])
        error, events = self.interrupted_fresh(resources.subprocess.TimeoutExpired("fixed-placeholder", 1))
        self.assertIsInstance(error, resources.EvidenceError)
        self.assertEqual(str(error), "fresh_child_timeout")
        self.assertEqual(events, [("wait", 1), "poll", "terminate", ("wait", 5)])

    def test_cleanup_or_identity_failures_do_not_replace_original_interrupt(self):
        interrupted = KeyboardInterrupt()
        error, events = self.interrupted_fresh(interrupted, cleanup_exception=RuntimeError("fixed-cleanup-failure"),
                                               mutate_binary=True)
        self.assertIs(error, interrupted)
        self.assertIn("terminate", events)
        if hasattr(error, "__notes__"):
            self.assertIn("fresh_child_cleanup_incomplete", error.__notes__)
            self.assertIn("binary_changed_during_fresh_child", error.__notes__)

    def cli_failure(self, error):
        # main() is invoked with a fake fresh(): no binary/process is executed.
        with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
            root = Path(directory)
            probe = root / "placeholder"
            probe.write_bytes(b"fixed-test-placeholder"); probe.chmod(0o700)
            argv = ["fixed-runner", "calibrate", "--probe", str(probe), "--out", str(root / "out"),
                    "--workload", "standard", "--ram-bytes", str(16*1024*MIB), "--source-id", "b"*40]
            output = io.StringIO()
            with mock.patch.object(resources.sys, "argv", argv), mock.patch.object(resources, "fresh", side_effect=error) as run, redirect_stdout(output):
                code = resources.main()
            self.assertEqual(run.call_count, 1)  # No later trial can hide the incomplete cleanup.
            return code, json.loads(output.getvalue())

    def test_timeout_cleanup_failure_is_visible_in_cli_and_not_called_stopped(self):
        error, events = self.interrupted_fresh(resources.subprocess.TimeoutExpired("fixed-placeholder", 1),
                                               cleanup_exception=RuntimeError("unprinted-cleanup-detail"))
        self.assertIsInstance(error, resources.EvidenceError)
        self.assertEqual(str(error), "fresh_child_timeout")
        self.assertIs(error.cleanup_confirmed, False)
        self.assertEqual(error.cleanup_classification, "owned_child_state_unknown")
        code, report = self.cli_failure(error)
        self.assertEqual(code, 2)
        self.assertEqual(report, {"acceptance": "incomplete_or_failed", "reason": "fresh_child_timeout",
                                 "launch_attempted": True, "process_handle_acquired": True,
                                 "cleanup_confirmed": False, "cleanup_classification": "owned_child_state_unknown"})
        self.assertNotIn("unprinted-cleanup-detail", json.dumps(report))

    def test_launch_exception_without_handle_reports_unknown_cleanup_and_stops(self):
        for interrupted in (KeyboardInterrupt(), RuntimeError("unprinted-launch-detail")):
            with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
                root = Path(directory)
                probe = root / "placeholder"; probe.write_bytes(b"fixed-test-placeholder")
                with mock.patch.object(resources.subprocess, "Popen", side_effect=interrupted) as launch:
                    try:
                        resources.fresh(probe, root, mode="async", workload="standard", cycles=30,
                                        trial=1, peak_bytes=1024*MIB, timeout=1)
                    except BaseException as actual:
                        self.assertIs(actual, interrupted)
                    else:
                        self.fail("launch interruption unexpectedly completed")
                    self.assertEqual(launch.call_count, 1)
                self.assertIs(interrupted.cleanup_confirmed, False)
                self.assertIs(interrupted.process_handle_acquired, False)
                self.assertEqual(interrupted.cleanup_classification, "child_state_unknown_no_handle")
                code, report = self.cli_failure(interrupted)
                self.assertEqual(code, 130 if isinstance(interrupted, KeyboardInterrupt) else 2)
                self.assertIs(report["cleanup_confirmed"], False)
                self.assertIs(report["process_handle_acquired"], False)
                self.assertEqual(report["cleanup_classification"], "child_state_unknown_no_handle")
                self.assertNotIn("unprinted-launch-detail", json.dumps(report))

    def test_source_render_ablations_repeat_three_fresh_children_but_cancellation_once(self):
        for mode in ("source-only", "render-before-encode", "async-cancel-before-encode"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
                root = Path(directory)
                probe = root / "placeholder"
                probe.write_bytes(b"fixed-test-placeholder"); probe.chmod(0o700)
                frozen = policy(); frozen["binarySHA256"] = resources.digest(probe)
                policy_path = root / "policy.json"; policy_path.write_text(json.dumps(frozen))
                argv = ["fixed-runner", "run", "--probe", str(probe), "--out", str(root / "out"),
                        "--policy", str(policy_path), "--mode", mode]
                summary = resources.summarize(fixture(mode))
                output = io.StringIO()
                with mock.patch.object(resources.sys, "argv", argv), mock.patch.object(resources, "fresh", return_value=summary) as run, redirect_stdout(output):
                    code = resources.main()
                report = json.loads(output.getvalue())
                expected = 3 if mode in resources.REPEATED_ABLATION_MODES else 1
                self.assertEqual(code, 0)
                self.assertEqual(run.call_count, expected)
                self.assertEqual(report["requiredFreshTrials"], expected)
                self.assertEqual(report["completedFreshTrials"], expected)
                self.assertEqual([call.kwargs["trial"] for call in run.call_args_list], list(range(1, expected + 1)))

    def test_repeated_ablation_stops_at_first_failed_acceptance(self):
        with tempfile.TemporaryDirectory(prefix="oneclip-resource-parser-") as directory:
            root = Path(directory)
            probe = root / "placeholder"
            probe.write_bytes(b"fixed-test-placeholder"); probe.chmod(0o700)
            frozen = policy(); frozen["binarySHA256"] = resources.digest(probe)
            policy_path = root / "policy.json"; policy_path.write_text(json.dumps(frozen))
            argv = ["fixed-runner", "run", "--probe", str(probe), "--out", str(root / "out"),
                    "--policy", str(policy_path), "--mode", "render-before-encode"]
            summary = resources.summarize(fixture("render-before-encode"))
            summary["sampledPeaks"]["rss"] = frozen["processPeakCapBytes"] + 1
            output = io.StringIO()
            with mock.patch.object(resources.sys, "argv", argv), mock.patch.object(resources, "fresh", return_value=summary) as run, redirect_stdout(output):
                code = resources.main()
            report = json.loads(output.getvalue())
            self.assertEqual(code, 1)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(report["acceptance"], "failed")
            self.assertEqual(report["requiredFreshTrials"], 3)
            self.assertEqual(report["completedFreshTrials"], 1)

    def test_unknown_record_does_not_echo_content(self):
        with self.assertRaisesRegex(resources.EvidenceError, "unexpected_log_record"):
            resources.summarize(fixture() + "arbitrary framework text\n")


if __name__ == "__main__":
    unittest.main()
