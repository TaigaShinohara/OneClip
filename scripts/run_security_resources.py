#!/usr/bin/env python3
"""Finite synthetic resource acceptance. No builds, screen capture, boards, or uploads.

Analyze existing numeric logs first. `calibrate` launches exactly three fresh no-image
controls and one fresh 2+10-cycle baseline per requested full mode. It exclusively creates
a frozen policy. `run` checks that policy and the exact binary, then launches three fresh
full or source/render ablation trials (one for cancellation or conditional extended idle). 60/90 and extended idle require an earlier
investigation result. All new evidence must be below the OS temporary directory.

These are current-Mac proposed engineering gates, not a physical-erasure or all-OS claim.
Any unexplained growth above E remains unqualified; this tool cannot label it a safe cache.
An ordinary full baseline maximum above 15 seconds stops before expansion; a 30-second
recovery cap cannot be used to admit a slower baseline.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
from typing import Any

MIB = 1_048_576
BASELINE_MAXIMUM_NS = 15_000_000_000
METRICS = ("rss", "physicalFootprint")
OWNER_FULL_MODES = ("product-single", "product-collection")
OWNER_CANCEL_MODES = tuple(f"product-{owner}-cancel-{point}-encode" for owner in ("single", "collection") for point in ("before", "after"))
OWNER_MODES = OWNER_FULL_MODES + OWNER_CANCEL_MODES
FULL_MODES = ("sync", "async", "product-states") + OWNER_FULL_MODES
REPEATED_ABLATION_MODES = ("source-only", "render-before-encode")
DIAGNOSTIC_MODES = ("source-only", "render-before-encode", "async-cancel-before-encode", "async-cancel-after-encode") + OWNER_CANCEL_MODES
CANCELLATION_BASELINE = {"async-cancel-before-encode": "async", "async-cancel-after-encode": "async",
                         **{mode: "product-single" if mode.startswith("product-single-") else "product-collection" for mode in OWNER_CANCEL_MODES}}
MODES = ("control", "product-control") + FULL_MODES + DIAGNOSTIC_MODES
WORKLOADS = ("small", "standard", "large")
KINDS = {"M4_OWNER_" + x for x in ("SCOPE", "LIMITS", "IDLE_POLICY", "MEMORY", "OWNERSHIP", "RANGE", "RESULT", "HEARTBEAT", "HEARTBEAT_SERIES", "PRODUCT_STATE", "PRODUCT_RELEASE", "COORDINATOR", "COORDINATOR_RELEASE", "TRACE", "ABORT")}
TOKEN = re.compile(r"[A-Za-z0-9_.-]+\Z")


class EvidenceError(ValueError):
    """Fixed classifications only; do not echo potentially sensitive unrecognized logs."""


def integer(row: dict[str, str], key: str, *, minimum: int = 0) -> int:
    try:
        value = int(row[key])
    except (KeyError, ValueError):
        raise EvidenceError("missing_or_noninteger_" + key) from None
    if value < minimum:
        raise EvidenceError("unavailable_or_invalid_" + key)
    return value


def parse_log(text: str) -> list[dict[str, str]]:
    rows = []
    for line in text.splitlines():
        bits = line.split()
        if not bits or bits[0] not in KINDS:
            raise EvidenceError("unexpected_log_record")
        row = {"kind": bits[0]}
        for bit in bits[1:]:
            if "=" not in bit:
                raise EvidenceError("malformed_log_field")
            key, value = bit.split("=", 1)
            if not TOKEN.fullmatch(key) or not TOKEN.fullmatch(value) or key in row:
                raise EvidenceError("malformed_or_duplicate_log_field")
            row[key] = value
        rows.append(row)
    return rows


def one(rows: list[dict[str, str]], kind: str) -> dict[str, str]:
    selected = [r for r in rows if r["kind"] == "M4_OWNER_" + kind]
    if len(selected) != 1:
        raise EvidenceError("missing_or_duplicate_" + kind.lower())
    return selected[0]


def exact_iterations(rows: list[dict[str, str]], expected: int, kind: str, series: str,
                     phase: str | None = None) -> list[dict[str, str]]:
    selected = [r for r in rows if r["kind"] == "M4_OWNER_" + kind and r.get("series") == series
                and (phase is None or r.get("phase") == phase)]
    if len(selected) != expected or [integer(r, "iteration", minimum=1) for r in selected] != list(range(1, expected + 1)):
        raise EvidenceError("incomplete_or_duplicate_" + series + "_" + kind.lower())
    return selected


def summarize(text: str, *, legacy: bool = False) -> dict[str, Any]:
    rows = parse_log(text)
    scope, result = one(rows, "SCOPE"), one(rows, "RESULT")
    schema = integer(scope, "schema") if "schema" in scope else 1
    if schema != 2 and not legacy:
        raise EvidenceError("legacy_log_not_acceptance_evidence")
    mode, workload = scope.get("mode", "legacy-sync"), scope.get("workload", "legacy-standard")
    if schema == 2 and (mode not in MODES or workload not in WORKLOADS):
        raise EvidenceError("unknown_mode_or_workload")
    recovery_scope = "coordinator_worker_slot" if mode in OWNER_CANCEL_MODES else "m0_wrapper_only" if mode in CANCELLATION_BASELINE else "not_applicable"
    if schema == 2 and scope.get("recoveryScope") != recovery_scope:
        raise EvidenceError("incorrect_recovery_measurement_scope")
    if scope.get("board") != "not_exercised" or integer(scope, "freshProcess") != 1 or integer(scope, "synthetic") != 1:
        raise EvidenceError("incorrect_probe_scope")
    cycles = integer(scope, "measuredCycles", minimum=1)
    if cycles not in (10, 30, 60, 90) or integer(scope, "warmupCycles") != 2:
        raise EvidenceError("unbounded_or_incorrect_cycle_count")
    if integer(result, "measuredCycles") != cycles or integer(result, "warmupCycles") != 2:
        raise EvidenceError("incomplete_terminal_result")
    if any(integer(result, k) != 0 for k in ("warmupFailures", "measuredFailures", "idleInterrupted")):
        raise EvidenceError("probe_assertion_failure")
    released = exact_iterations(rows, cycles, "MEMORY", "measured", "scope_released")
    warm = exact_iterations(rows, 2, "MEMORY", "warmup", "scope_released")
    ownership = exact_iterations(rows, cycles, "OWNERSHIP", "measured") + exact_iterations(rows, 2, "OWNERSHIP", "warmup")
    for r in ownership:
        if any(integer(r, k) != target for k, target in (("passed", 1), ("batchOwnerReleased", 1), ("outputReferenceReleased", 1), ("sourceLiveBytes", 0))):
            raise EvidenceError("ownership_not_released")
        if integer(r, "sourceCreated") != integer(r, "sourceReleased"):
            raise EvidenceError("source_provider_not_released")
        if schema == 2:
            if integer(r, "peakCapExceeded") != 0 or integer(r, "actualImageBytes") > 384 * MIB:
                raise EvidenceError("image_or_process_budget_exceeded")
            if integer(r, "elapsedNanoseconds", minimum=1) <= 0:
                raise EvidenceError("missing_duration")
            expected_sources = 2 if workload == "small" else 4
            if mode in ("control", "product-control"):
                expected_sources = 0
            elif mode == "product-states":
                expected_sources += 3  # Two reviewed candidates and one independent single.
            elif mode in OWNER_MODES and mode.startswith("product-single"):
                expected_sources = 1
            if integer(r, "sourceCreated") != expected_sources:
                raise EvidenceError("unexpected_source_provider_count")
            cancelled = mode == "render-before-encode" or mode in CANCELLATION_BASELINE
            if integer(r, "expectedCancellation") != int(cancelled) or integer(r, "compositionSucceeded") != int(not cancelled):
                raise EvidenceError("incorrect_completion_classification")
            if mode in FULL_MODES[:2]:
                if integer(r, "pngBytes", minimum=1) <= 0 or integer(r, "outputWasObserved") != 1:
                    raise EvidenceError("completed_png_not_observed")
            elif cancelled or mode in ("control", "product-control", "source-only"):
                if integer(r, "pngBytes") != 0 or integer(r, "outputWasObserved") != 0:
                    raise EvidenceError("unexpected_png_result")
    idle = [r for r in rows if r["kind"] == "M4_OWNER_MEMORY" and r.get("phase") == "idle"]
    if schema == 1:
        targets = [0, 5, 15, 30]
    else:
        try:
            targets = [int(x) for x in scope["idleTargetsSeconds"].split("_")]
        except (KeyError, ValueError):
            raise EvidenceError("missing_idle_targets") from None
        allowed = [[0]] if cycles == 10 else [[0, 5, 15, 30], [0, 5, 15, 30, 60, 120]]
        if targets not in allowed:
            raise EvidenceError("incorrect_idle_targets")
    if [integer(r, "iteration") for r in idle] != targets or integer(result, "idleObservations") != len(targets) - 1:
        raise EvidenceError("missing_or_duplicate_idle_sample")
    for r, seconds in zip(idle, targets):
        if integer(r, "elapsedNanoseconds") < seconds * 1_000_000_000:
            raise EvidenceError("premature_idle_sample")
    memories = [r for r in rows if r["kind"] == "M4_OWNER_MEMORY"]
    # Missing/negative metrics are unavailable, never silently replaced with zero.
    peaks = {metric: max(integer(r, metric) for r in memories) for metric in METRICS + ("processHighWater",)}
    summaries = {}
    for metric in METRICS + ("mallocSizeInUse", "mallocSizeAllocated"):
        values = [integer(r, metric) for r in released]
        tails = [statistics.median(values[i + 25:i + 30]) for i in range(0, cycles - 29, 30)]
        previous = integer(warm[-1], metric)
        increments = []
        for tail in tails:
            increments.append(tail - previous); previous = tail
        summaries[metric] = {
            "n": len(values), "first": values[0], "last": values[-1], "delta": values[-1] - values[0],
            "range": max(values) - min(values), "minimum": min(values), "maximum": max(values),
            "tailFiveMediansPer30": tails, "blockIncrementsFromPostWarmup": increments,
            "idleDeltaFromFinalRelease": integer(idle[-1], metric) - values[-1],
        }
    heartbeat = None
    if schema == 2:
        beat = one(rows, "HEARTBEAT")
        required = mode in ("async", "product-states", "product-control") or mode in CANCELLATION_BASELINE or mode in OWNER_FULL_MODES
        if integer(beat, "required") != int(required) or integer(beat, "periodNanoseconds") != 50_000_000:
            raise EvidenceError("incorrect_heartbeat_scope")
        heartbeat = {"required": required, "count": integer(beat, "count"), "maximumGapNanoseconds": integer(beat, "maximumGapNanoseconds")}
        if required and heartbeat["count"] == 0:
            raise EvidenceError("heartbeat_unobserved")
        series_rows = [r for r in rows if r["kind"] == "M4_OWNER_HEARTBEAT_SERIES"]
        if "heartbeatSeries" in scope:
            if integer(scope, "heartbeatSeries") != 2 or len(series_rows) != 2 or {r.get("series") for r in series_rows} != {"warmup", "measured"}:
                raise EvidenceError("incomplete_heartbeat_series")
            observations = {}
            for r in series_rows:
                count, gap = integer(r, "count"), integer(r, "maximumGapNanoseconds")
                if (integer(r, "required") != int(required) or integer(r, "wholeCrossingIntervalIncluded") != 1
                        or r.get("acceptanceGate") != "aggregate" or count > heartbeat["count"]
                        or gap > heartbeat["maximumGapNanoseconds"] or (not required and (count or gap))):
                    raise EvidenceError("incorrect_heartbeat_series_scope")
                observations[r["series"]] = {"callbackIntervals": count, "maximumGapNanoseconds": gap}
            heartbeat["seriesDiagnostic"] = observations
            heartbeat["seriesCrossingIntervalsIncluded"] = True
            heartbeat["acceptanceGate"] = "aggregate_including_warmup"
        elif series_rows:
            raise EvidenceError("undeclared_heartbeat_series")
        limits = one(rows, "LIMITS")
        if integer(limits, "imageBudgetBytes") != 384 * MIB:
            raise EvidenceError("image_budget_changed")
        for series, n in (("warmup", 2), ("measured", cycles)):
            if mode in OWNER_MODES:
                coordinators = exact_iterations(rows, n, "COORDINATOR", series)
                coordinator_releases = exact_iterations(rows, n, "COORDINATOR_RELEASE", series)
                series_ownership = exact_iterations(rows, n, "OWNERSHIP", series)
                cancelled = mode in OWNER_CANCEL_MODES
                for r, released_owner, owned in zip(coordinators, coordinator_releases, series_ownership):
                    if r.get("owner") != ("single" if mode.startswith("product-single") else "collection"):
                        raise EvidenceError("coordinator_owner_mismatch")
                    if integer(r, "passed") != 1 or integer(r, "workerIsWorking") != 0 or integer(r, "slotOccupied") != 0:
                        raise EvidenceError("coordinator_worker_or_slot_not_released")
                    if integer(r, "workersStarted", minimum=1) != integer(r, "workersReturned") or integer(r, "slotsAcquired", minimum=1) != integer(r, "slotsReleased"):
                        raise EvidenceError("coordinator_worker_trace_unbalanced")
                    if integer(r, "traceDropped") != 0 or any(integer(released_owner, k) != 1 for k in ("singleReleased", "collectionReleased", "passed")):
                        raise EvidenceError("coordinator_release_incomplete")
                    if integer(r, "cancellationRequested") != int(cancelled) or integer(r, "afterCancellationAdoptions") != 0:
                        raise EvidenceError("coordinator_cancellation_or_adoption_incorrect")
                    if cancelled:
                        expected_method = "stop" if "-after-" in mode else "invalidate"
                        if r.get("cancellationMethod") != expected_method or integer(r, "busyAtCancellation") != 1 or integer(r, "slotAtCancellation") != 1 or integer(r, "writerCalls") != 0:
                            raise EvidenceError("coordinator_cancellation_boundary_unobserved")
                        if integer(r, "recoveryNanoseconds") != integer(owned, "recoveryNanoseconds"):
                            raise EvidenceError("coordinator_recovery_duration_mismatch")
                    elif r.get("cancellationMethod") != "none" or integer(r, "writerCalls") != 1 or integer(owned, "pngBytes", minimum=1) <= 0:
                        raise EvidenceError("ordinary_coordinator_baseline_copy_unobserved")
            if mode in ("product-states", "product-control"):
                product = exact_iterations(rows, n, "PRODUCT_RELEASE", series)
                for r in product:
                    if any(integer(r, k) != 1 for k in ("coordinatorReleased", "singleReleased", "nativeReleased", "viewReleased", "passed")):
                        raise EvidenceError("product_owner_not_released")
                trace = exact_iterations(rows, n, "TRACE", series)
                if any(integer(r, "dropped") != 0 or integer(r, "enabled") != 1 for r in trace):
                    raise EvidenceError("incomplete_product_trace")
                for r in trace:
                    started, returned = integer(r, "workersStarted"), integer(r, "workersReturned")
                    if started != returned or integer(r, "slotsAcquired") != integer(r, "slotsReleased"):
                        raise EvidenceError("unbalanced_actual_product_worker_lifetime")
                    if (mode == "product-control" and started != 0) or (mode == "product-states" and started == 0):
                        raise EvidenceError("incorrect_product_worker_scope")
                states = [r for r in rows if r["kind"] == "M4_OWNER_PRODUCT_STATE" and r.get("series") == series]
                expected = {"empty"} if mode == "product-control" else {
                    "ready", "preview", "copied_kept", "hidden_kept", "candidate_keep", "kept_original",
                    "candidate_accept", "accepted", "single_copy_failure", "ended"}
                for iteration in range(1, n + 1):
                    selected = [r for r in states if integer(r, "iteration") == iteration]
                    if len(selected) != len(expected) or {r.get("phase") for r in selected} != expected or any(integer(r, "passed") != 1 for r in selected):
                        raise EvidenceError("incomplete_product_state_coverage")
                    for r in selected:
                        if integer(r, "productWindowDisplayed") != 0:
                            raise EvidenceError("product_offscreen_scope_changed")
                        integer(r, "actualProductDrawCalls") # Zero is a valid observed count, not proof of drawing.
            for iteration in range(1, n + 1):
                phases = {r.get("phase") for r in memories if r.get("series") == series and integer(r, "iteration") == iteration}
                expected_phases = {"generation_pre", "sources_ready"}
                if mode in FULL_MODES[:2] or mode == "control" or mode in OWNER_FULL_MODES:
                    expected_phases |= {"before_allocation", "before_encoding", "after_encoding", "before_result"}
                elif mode in ("render-before-encode", "async-cancel-before-encode"):
                    expected_phases |= {"before_allocation", "before_encoding"}
                elif mode == "async-cancel-after-encode":
                    expected_phases |= {"before_allocation", "before_encoding", "after_encoding"}
                elif mode in OWNER_CANCEL_MODES:
                    expected_phases |= {"before_allocation", "before_encoding"}
                    if "-after-" in mode:
                        expected_phases.add("after_encoding")
                elif mode in ("product-states", "product-control"):
                    expected_phases = {"view_torn_down"}
                if not expected_phases <= phases:
                    raise EvidenceError("missing_phase_observation")
                if mode in OWNER_MODES and "coordinator_worker_slot_released" not in phases:
                    raise EvidenceError("coordinator_worker_slot_release_not_observed")
                if mode in FULL_MODES[:2] + ("control", "render-before-encode", "async-cancel-before-encode", "async-cancel-after-encode"):
                    count = 2 if workload == "small" else 4
                    if not {f"source_{i}" for i in range(count)} <= phases:
                        raise EvidenceError("missing_source_render_boundary")
                if mode in OWNER_MODES and mode.startswith("product-collection"):
                    count = 2 if workload == "small" else 4
                    if not {f"source_{i}" for i in range(count)} <= phases:
                        raise EvidenceError("missing_coordinator_source_render_boundary")
    durations = [integer(r, "elapsedNanoseconds", minimum=1) for r in ownership[:cycles]] if schema == 2 else []
    recoveries = [integer(r, "recoveryNanoseconds") for r in ownership[:cycles]] if mode in CANCELLATION_BASELINE else []
    return {"schema": schema, "mode": mode, "workload": workload, "cycles": cycles,
            "metrics": summaries, "sampledPeaks": peaks, "heartbeat": heartbeat,
            "durationMaximumNanoseconds": max(durations) if durations else None,
            "recoveryMaximumNanoseconds": max(recoveries) if recoveries else None,
            "idleTargets": targets, "recoveryScope": recovery_scope,
            "acceptance": "not_evaluated", "physicalErasure": "not_claimed"}


def validate_baseline_duration(summary: dict[str, Any]) -> int:
    duration = summary.get("durationMaximumNanoseconds")
    if not isinstance(duration, int) or isinstance(duration, bool) or duration <= 0:
        raise EvidenceError("full_baseline_duration_unavailable")
    if duration > BASELINE_MAXIMUM_NS:
        raise EvidenceError("full_baseline_maximum_over_15_seconds")
    return duration


def build_policy(controls: list[dict[str, Any]], baselines: list[dict[str, Any]], *,
                 ram_bytes: int, binary_sha: str, source_id: str,
                 product_controls: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    if ram_bytes <= 0 or not re.fullmatch(r"[0-9a-f]{64}", binary_sha) or not re.fullmatch(r"[0-9a-f]{40}", source_id):
        raise EvidenceError("invalid_manifest_identity")
    if not baselines or any(s["schema"] != 2 or s["cycles"] != 10 or s["mode"] not in FULL_MODES for s in baselines):
        raise EvidenceError("invalid_ten_cycle_baseline")
    workload = baselines[0]["workload"]
    if len({s["mode"] for s in baselines}) != len(baselines) or any(s["workload"] != workload for s in baselines):
        raise EvidenceError("mismatched_baseline_scope")
    for summary in baselines:
        validate_baseline_duration(summary)
    peak = min(1_073_741_824, ram_bytes // 8)
    groups = {"core": controls}
    if product_controls is not None:
        groups["product"] = product_controls
    thresholds = {}
    for flavor, group in groups.items():
        mode = "control" if flavor == "core" else "product-control"
        if len(group) != 3 or any(s["schema"] != 2 or s["mode"] != mode or s["cycles"] != 30 or s["workload"] != workload for s in group):
            raise EvidenceError("three_matching_fresh_controls_required")
        thresholds[flavor] = {}
        for metric in METRICS:
            b = max(s["metrics"][metric]["range"] for s in group)
            if b > 8 * MIB:
                raise EvidenceError("no_image_control_variation_over_8MiB")
            thresholds[flavor][metric] = {"B": b, "E": max(8 * MIB, 2 * b)}
    if any(s["mode"] == "product-states" for s in baselines) and "product" not in thresholds:
        raise EvidenceError("product_control_required")
    for summary in controls + (product_controls or []) + baselines:
        if max(summary["sampledPeaks"].values()) > peak:
            raise EvidenceError("calibration_peak_exceeds_proposed_cap")
        if summary["heartbeat"] and summary["heartbeat"]["required"] and summary["heartbeat"]["maximumGapNanoseconds"] > 250_000_000:
            raise EvidenceError("calibration_heartbeat_exceeds_proposed_cap")
    caps = {s["mode"]: min(30_000_000_000, max(2_000_000_000, 2 * validate_baseline_duration(s))) for s in baselines}
    return {"schema": 1, "scope": "current_mac_synthetic_only", "workload": workload,
            "binarySHA256": binary_sha, "sourceID": source_id, "ramBytes": ram_bytes,
            "imageBudgetBytes": 384 * MIB, "processPeakCapBytes": peak,
            "heartbeatPeriodNanoseconds": 50_000_000, "heartbeatCapNanoseconds": 250_000_000,
            "fullBaselineMaximumAllowedNanoseconds": BASELINE_MAXIMUM_NS,
            "thresholds": thresholds, "recoveryCapsNanoseconds": caps,
            "criteria": "proposed_frozen_before_full_trials", "unexplainedExcess": "unqualified",
            "maximumStandardFreshFullRunsPerModePerLength": 3,
            "maximumConditionalExtendedFreshRunsPerModePerLength": 1, "allowedLengths": [30, 60, 90],
            "physicalErasure": "not_claimed"}


def calibration_guard(summary: dict[str, Any], peak: int) -> None:
    """Stop before starting image baselines if a control already invalidates the session."""
    if summary["mode"] in FULL_MODES and summary["cycles"] == 10:
        validate_baseline_duration(summary)
    if max(summary["sampledPeaks"].values()) > peak:
        raise EvidenceError("calibration_peak_exceeds_proposed_cap")
    beat = summary["heartbeat"]
    if beat["required"] and beat["maximumGapNanoseconds"] > 250_000_000:
        raise EvidenceError("calibration_heartbeat_exceeds_proposed_cap")
    if summary["mode"] in ("control", "product-control"):
        if any(summary["metrics"][metric]["range"] > 8*MIB for metric in METRICS):
            raise EvidenceError("no_image_control_variation_over_8MiB")


def evaluate(summary: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    if summary["schema"] != 2 or summary["workload"] != policy["workload"]:
        raise EvidenceError("policy_scope_mismatch")
    mode = summary["mode"]
    flavor = "product" if mode in ("product-states", "product-control") else "core"
    if flavor not in policy["thresholds"]:
        raise EvidenceError("missing_frozen_control")
    violations, excess = [], []
    if max(summary["sampledPeaks"].values()) > policy["processPeakCapBytes"]:
        violations.append("process_peak_cap")
    beat = summary["heartbeat"]
    if beat["required"] and beat["maximumGapNanoseconds"] > policy["heartbeatCapNanoseconds"]:
        violations.append("main_actor_heartbeat_cap")
    if mode in CANCELLATION_BASELINE:
        baseline_mode = CANCELLATION_BASELINE[mode]
        if baseline_mode not in policy["recoveryCapsNanoseconds"]:
            raise EvidenceError("missing_owner_specific_recovery_baseline")
        if summary["recoveryMaximumNanoseconds"] > policy["recoveryCapsNanoseconds"][baseline_mode]:
            violations.append("worker_recovery_cap")
    for metric in METRICS:
        e = policy["thresholds"][flavor][metric]["E"]
        values = summary["metrics"][metric]
        changes = values["blockIncrementsFromPostWarmup"]
        if any(a > e and b > e for a, b in zip(changes, changes[1:])):
            violations.append(metric + "_continued_growth_two_blocks")
        if any(x > e for x in changes) or values["delta"] > e or values["idleDeltaFromFinalRelease"] > e:
            excess.append(metric + "_unexplained_growth")
    status = "failed" if violations else "needs_investigation" if excess else "passed_finite_current_mac"
    return {**summary, "acceptance": status, "violations": violations, "unexplainedExcess": excess,
            "cause": "not_inferred_from_release_or_malloc_counters"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def temp_output(path: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(Path(tempfile.gettempdir()).resolve()):
        raise EvidenceError("evidence_must_be_in_os_temporary_directory")
    resolved.mkdir(parents=True, exist_ok=True)
    return resolved


def write_new(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=True, indent=2, sort_keys=True)
        handle.write("\n")


def stop_owned_probe(process: subprocess.Popen) -> None:
    """Reap only the Popen handle created by this invocation, even after an interrupted wait."""
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        pass  # The owned process raced with termination; still reap its direct handle.
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


CLEANUP_CLASSIFICATIONS = frozenset({"child_wait_completed", "owned_child_reaped",
                                      "owned_child_state_unknown", "child_state_unknown_no_handle"})


def mark_child_cleanup(error: BaseException, *, handle_acquired: bool,
                       confirmed: bool, classification: str) -> None:
    """Attach fixed, value-free terminal state while preserving the original exception object."""
    error.launch_attempted = True
    error.process_handle_acquired = handle_acquired
    error.cleanup_confirmed = confirmed
    error.cleanup_classification = classification


def failure_report(error: BaseException, *, reason: str) -> dict[str, Any]:
    report: dict[str, Any] = {"acceptance": "incomplete_or_failed", "reason": reason}
    # Only our fixed typed metadata is serialized; arbitrary exception strings/attributes are not.
    classification = getattr(error, "cleanup_classification", None)
    if classification in CLEANUP_CLASSIFICATIONS:
        report.update({"launch_attempted": True,
                       "process_handle_acquired": getattr(error, "process_handle_acquired") is True,
                       "cleanup_confirmed": getattr(error, "cleanup_confirmed") is True,
                       "cleanup_classification": classification})
    return report


def fresh(probe: Path, out: Path, *, mode: str, workload: str, cycles: int,
          trial: int, peak_bytes: int, timeout: float, extended: bool = False,
          expected_binary_sha: str | None = None) -> dict[str, Any]:
    before_sha = digest(probe)
    if expected_binary_sha is not None and before_sha != expected_binary_sha:
        raise EvidenceError("binary_changed_before_fresh_child")
    stem = f"{mode}-{workload}-{cycles}-{trial}" + ("-extended" if extended else "")
    log, stderr = out / (stem + ".log"), out / (stem + ".stderr")
    argv = [str(probe), "--mode", mode, "--workload", workload, "--cycles", str(cycles),
            "--trial", str(trial), "--peak-bytes", str(peak_bytes)]
    if extended:
        argv.append("--extended-idle")
    with log.open("x", encoding="utf-8") as stdout, stderr.open("x", encoding="utf-8") as error:
        # No shell and no inherited authentication/environment payloads. Only this direct child
        # is terminated on timeout; no name-based process matching or global state modification.
        try:
            process = subprocess.Popen(argv, stdout=stdout, stderr=error,
                                       env={"PATH": "/usr/bin:/bin", "TMPDIR": tempfile.gettempdir(), "LANG": "C"})
        except BaseException as launch_error:
            # Popen may have forked before raising or being interrupted. Without its returned
            # handle, this invocation cannot prove cleanup and must stop for manual recovery.
            mark_child_cleanup(launch_error, handle_acquired=False, confirmed=False,
                               classification="child_state_unknown_no_handle")
            raise
        code = None
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise EvidenceError("fresh_child_timeout") from None
        finally:
            # KeyboardInterrupt and any other failed wait also own the same direct child.
            # Cleanup is bounded, never searches by process name, and preserves the original
            # exception if another interruption or a filesystem error happens while cleaning up.
            pending = sys.exc_info()[1]
            cleanup_error = None
            if code is None:
                try:
                    stop_owned_probe(process)
                except BaseException:
                    cleanup_error = EvidenceError("fresh_child_cleanup_incomplete")
            identity_error = None
            try:
                after_sha = digest(probe)
                if after_sha != before_sha:
                    identity_error = EvidenceError("binary_changed_during_fresh_child")
            except BaseException:
                identity_error = EvidenceError("binary_identity_unavailable_after_fresh_child")
            terminal_error = pending or cleanup_error or identity_error
            if terminal_error is not None:
                mark_child_cleanup(terminal_error, handle_acquired=True, confirmed=cleanup_error is None,
                                   classification="owned_child_state_unknown" if cleanup_error is not None
                                   else "owned_child_reaped" if code is None else "child_wait_completed")
            if pending is not None:
                for issue in (cleanup_error, identity_error):
                    if issue is not None and hasattr(pending, "add_note"):
                        pending.add_note(str(issue))
            elif cleanup_error is not None:
                raise cleanup_error
            elif identity_error is not None:
                raise identity_error
    if code != 0:
        raise EvidenceError("fresh_child_failed_or_incomplete")
    summary = summarize(log.read_text(encoding="utf-8"))
    if (summary["mode"], summary["workload"], summary["cycles"]) != (mode, workload, cycles):
        raise EvidenceError("fresh_child_requested_scope_mismatch")
    summary["stderrBytes"] = stderr.stat().st_size
    summary["logSHA256"] = digest(log)
    summary["binarySHA256Before"] = before_sha
    summary["binarySHA256After"] = after_sha
    return summary


def validate_previous(path: Path | None, policy_sha: str, mode: str, cycles: int, *, extended: bool) -> None:
    if cycles == 30 and not extended:
        return
    if path is None:
        raise EvidenceError("conditional_extension_requires_previous_evidence")
    previous = json.loads(path.read_text(encoding="utf-8"))
    expected_cycles = cycles if extended else cycles - 30
    if (previous.get("policySHA256") != policy_sha or previous.get("mode") != mode
            or previous.get("cycles") != expected_cycles or previous.get("acceptance") != "needs_investigation"):
        raise EvidenceError("extension_scope_or_condition_not_met")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    analyze = commands.add_parser("analyze")
    analyze.add_argument("logs", nargs="+", type=Path)
    analyze.add_argument("--legacy", action="store_true")
    calibration = commands.add_parser("calibrate")
    calibration.add_argument("--probe", required=True, type=Path)
    calibration.add_argument("--out", required=True, type=Path)
    calibration.add_argument("--workload", choices=WORKLOADS, required=True)
    calibration.add_argument("--ram-bytes", required=True, type=int)
    calibration.add_argument("--source-id", required=True)
    calibration.add_argument("--product", action="store_true")
    run = commands.add_parser("run")
    run.add_argument("--probe", required=True, type=Path)
    run.add_argument("--out", required=True, type=Path)
    run.add_argument("--policy", required=True, type=Path)
    run.add_argument("--mode", choices=FULL_MODES + DIAGNOSTIC_MODES, required=True)
    run.add_argument("--cycles", choices=(30, 60, 90), type=int, default=30)
    run.add_argument("--extended-idle", action="store_true")
    run.add_argument("--previous", type=Path)
    rebind = commands.add_parser("rebind", help="Bind unchanged frozen criteria to a reviewed local-fix binary")
    rebind.add_argument("--policy", required=True, type=Path)
    rebind.add_argument("--probe", required=True, type=Path)
    rebind.add_argument("--source-id", required=True)
    rebind.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "analyze":
            summaries = [summarize(path.read_text(encoding="utf-8"), legacy=args.legacy) for path in args.logs]
            print(json.dumps({"summaries": summaries}, sort_keys=True))
            return 0
        probe = args.probe.resolve()
        if not probe.is_file() or not os.access(probe, os.X_OK):
            raise EvidenceError("probe_executable_unavailable")
        out = temp_output(args.out)
        binary_sha = digest(probe)
        if args.command == "rebind":
            policy = json.loads(args.policy.read_text(encoding="utf-8"))
            if not re.fullmatch(r"[0-9a-f]{40}", args.source_id) or policy.get("schema") != 1:
                raise EvidenceError("invalid_manifest_identity")
            rebound = {**policy, "binarySHA256": binary_sha, "sourceID": args.source_id,
                       "previousPolicySHA256": digest(args.policy), "criteriaRecalibrated": False}
            write_new(out / "policy.json", rebound)
            print(json.dumps({"status": "same_criteria_rebound", "policySHA256": digest(out / "policy.json")}, sort_keys=True))
            return 0
        if args.command == "calibrate":
            if not re.fullmatch(r"[0-9a-f]{40}", args.source_id) or args.ram_bytes <= 0:
                raise EvidenceError("invalid_manifest_identity")
            if (out / "policy.json").exists():
                raise EvidenceError("frozen_policy_already_exists")
            peak = min(1_073_741_824, args.ram_bytes // 8)
            controls, product_controls = [], [] if args.product else None
            for mode, destination in (("control", controls), ("product-control", product_controls)):
                if destination is None:
                    continue
                for trial in range(1, 4):
                    summary = fresh(probe, out, mode=mode, workload=args.workload, cycles=30,
                                    trial=trial, peak_bytes=peak, timeout=180, expected_binary_sha=binary_sha)
                    write_new(out / f"calibration-{mode}-{trial}.json", summary)
                    calibration_guard(summary, peak)
                    destination.append(summary)
            modes = FULL_MODES if args.product else FULL_MODES[:2]
            baselines = []
            for mode in modes:
                summary = fresh(probe, out, mode=mode, workload=args.workload, cycles=10,
                                trial=1, peak_bytes=peak, timeout=360, expected_binary_sha=binary_sha)
                write_new(out / f"calibration-{mode}-baseline.json", summary)
                calibration_guard(summary, peak)
                baselines.append(summary)
            policy = build_policy(controls, baselines, ram_bytes=args.ram_bytes, binary_sha=binary_sha,
                                  source_id=args.source_id, product_controls=product_controls)
            # Exclusive creation prevents recalibration from silently relaxing an existing gate.
            write_new(out / "calibration.json", {"controls": controls, "productControls": product_controls, "baselines": baselines})
            write_new(out / "policy.json", policy)
            print(json.dumps({"status": "policy_frozen", "policySHA256": digest(out / "policy.json"), "workload": args.workload}, sort_keys=True))
            return 0
        policy = json.loads(args.policy.read_text(encoding="utf-8"))
        if policy.get("binarySHA256") != binary_sha:
            raise EvidenceError("binary_changed_requires_explicit_rebaseline_decision")
        policy_sha = digest(args.policy)
        validate_previous(args.previous, policy_sha, args.mode, args.cycles, extended=args.extended_idle)
        trials = 3 if args.mode in FULL_MODES + REPEATED_ABLATION_MODES and not args.extended_idle else 1
        duration_mode = args.mode if args.mode in FULL_MODES else CANCELLATION_BASELINE.get(args.mode, "sync")
        if duration_mode not in policy["recoveryCapsNanoseconds"]:
            raise EvidenceError("missing_frozen_workload_baseline")
        cap = policy["recoveryCapsNanoseconds"][duration_mode] / 1e9
        results = []
        for trial in range(1, trials + 1):
            summary = fresh(probe, out, mode=args.mode, workload=policy["workload"], cycles=args.cycles, trial=trial,
                            peak_bytes=policy["processPeakCapBytes"], timeout=(args.cycles + 2) * cap + (150 if args.extended_idle else 60),
                            extended=args.extended_idle, expected_binary_sha=binary_sha)
            verdict = evaluate(summary, policy); results.append(verdict)
            if verdict["acceptance"] == "failed":
                break
        status = "failed" if any(r["acceptance"] == "failed" for r in results) else "needs_investigation" if any(r["acceptance"] == "needs_investigation" for r in results) else "passed_finite_current_mac"
        prior_unexplained = args.cycles > 30 or args.extended_idle
        if prior_unexplained and status == "passed_finite_current_mac":
            status = "needs_investigation" # A new stable fresh process cannot explain old excess.
        report = {"schema": 1, "mode": args.mode, "cycles": args.cycles, "policySHA256": policy_sha,
                  "acceptance": status, "completedFreshTrials": len(results), "requiredFreshTrials": trials,
                  "summaries": results, "priorExcessStillRequiresExplanation": prior_unexplained,
                  "noAutomaticCriteriaRelaxation": True}
        name = f"result-{args.mode}-{args.cycles}" + ("-extended" if args.extended_idle else "") + ".json"
        write_new(out / name, report)
        print(json.dumps({k: v for k, v in report.items() if k != "summaries"}, sort_keys=True))
        return 0 if status == "passed_finite_current_mac" else 1
    except EvidenceError as error:
        print(json.dumps(failure_report(error, reason=str(error)), sort_keys=True))
        return 2
    except KeyboardInterrupt as error:
        print(json.dumps(failure_report(error, reason="parent_interrupted"), sort_keys=True))
        return 130
    except Exception as error:
        # Keep errors value-free: stderr/framework strings, arbitrary file data and paths are
        # retained only in the caller-selected temporary evidence directory, never echoed here.
        print(json.dumps(failure_report(error, reason="evidence_or_execution_error"), sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
