"""Pure, core-only evidence migration. No files, processes, calibration, or trials.

The caller authenticates the old policy bytes and immutable evidence receipts by
their approved hashes. This module validates the generic legacy profile, current
typed proofs and frozen limits; it never promotes an old observation.
"""

import copy
import math
import re


MIB = 1_048_576
OUTPUT_SEMANTICS = "strong_fenced_weak_identity_v2"
MODES = ("control", "sync", "async")
CHILD_DEADLINE_SECONDS = {"control": 45, "sync": 15, "async": 15}
METRICS = ("rss", "physicalFootprint")
ALL_METRICS = METRICS + ("mallocSizeInUse", "mallocSizeAllocated")
REASONS = frozenset("legacy_policy_profile_rejected summary_structure_invalid summary_scope_mismatch summary_proof_not_current summary_prior_failure summary_peak_exceeds_frozen_cap summary_heartbeat_exceeds_frozen_cap summary_growth_exceeds_frozen_E control_variation_exceeds_limit control_derived_E_exceeds_frozen_E baseline_duration_exceeds_frozen_limit baseline_derived_T_exceeds_frozen_T summary_binding_missing summary_binding_mismatch capture_not_established migration_evidence_set_invalid migration_identity_invalid frozen_numeric_changed".split())
CAPTURE_REASONS = frozenset("deadline whole_deadline clock_invalid stdout_cap stderr_cap stderr_present_discarded cleanup_unknown parent_interrupted launch_failed capture_failed child_exit_nonzero input_changed".split())


class MigrationError(ValueError):
    """Only .reason in REASONS is safe to persist; never serialize input/errors."""
    def __init__(self, reason):
        self.reason = reason if reason in REASONS else "summary_structure_invalid"
        super().__init__(self.reason)


def require(value, reason):
    if not value:
        raise MigrationError(reason)


def integer(value, minimum=0, maximum=2**64-1):
    return type(value) is int and minimum <= value <= maximum


def sha(value, length):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{" + str(length) + r"}", value) is not None


def validate_legacy_policy(policy):
    """Accept only the unversioned, standard, core-only legacy policy profile.

    Artifact identities and measured B values are caller data, never hardcoded.
    Existing observation-version fields are rejected so no old numeric path is
    overwritten with schema 2. Current policies use the existing rebind path.
    """
    reason = "legacy_policy_profile_rejected"
    keys = set("allowedLengths binarySHA256 criteria fullBaselineMaximumAllowedNanoseconds heartbeatCapNanoseconds heartbeatPeriodNanoseconds imageBudgetBytes maximumConditionalExtendedFreshRunsPerModePerLength maximumStandardFreshFullRunsPerModePerLength physicalErasure processPeakCapBytes ramBytes recoveryCapsNanoseconds schema scope sourceID thresholds unexplainedExcess workload".split())
    require(type(policy) is dict and set(policy) == keys, reason)
    require(type(policy["schema"]) is int and policy["schema"] == 1 and
            policy["scope"] == "current_mac_synthetic_only" and policy["workload"] == "standard" and
            policy["criteria"] == "proposed_frozen_before_full_trials" and
            policy["unexplainedExcess"] == "unqualified" and policy["physicalErasure"] == "not_claimed", reason)
    require(sha(policy["binarySHA256"], 64) and sha(policy["sourceID"], 40), reason)
    constants = {"fullBaselineMaximumAllowedNanoseconds": 15_000_000_000,
                 "heartbeatCapNanoseconds": 250_000_000, "heartbeatPeriodNanoseconds": 50_000_000,
                 "imageBudgetBytes": 384*MIB, "maximumConditionalExtendedFreshRunsPerModePerLength": 1,
                 "maximumStandardFreshFullRunsPerModePerLength": 3}
    require(all(type(policy[key]) is int and policy[key] == value for key, value in constants.items()), reason)
    require(type(policy["allowedLengths"]) is list and policy["allowedLengths"] == [30, 60, 90]
            and all(type(value) is int for value in policy["allowedLengths"]), reason)
    require(integer(policy["ramBytes"], 8) and integer(policy["processPeakCapBytes"], 1) and
            policy["processPeakCapBytes"] == min(1024*MIB, policy["ramBytes"] // 8), reason)
    thresholds = policy["thresholds"]
    require(type(thresholds) is dict and set(thresholds) == {"core"} and
            type(thresholds["core"]) is dict and set(thresholds["core"]) == set(METRICS), reason)
    for pair in thresholds["core"].values():
        require(type(pair) is dict and set(pair) == {"B", "E"} and integer(pair["B"], 0, 8*MIB)
                and integer(pair["E"], 1) and pair["E"] == max(8*MIB, 2*pair["B"]), reason)
    caps = policy["recoveryCapsNanoseconds"]
    require(type(caps) is dict and set(caps) == {"sync", "async"} and
            all(integer(value, 2_000_000_000, 30_000_000_000) and value % 2 == 0 for value in caps.values()), reason)


def _typed_capture(capture):
    reason = "summary_structure_invalid"
    keys = set("stdoutBytes stderrBytesDiscarded rawSaved rawHashed processHandleAcquired cleanupConfirmed exit elapsedSeconds elapsedWallSeconds childDeadlineSeconds reason launchAttempted".split())
    require(type(capture) is dict and set(capture) == keys, reason)
    require(integer(capture["stdoutBytes"], 0, 512*1024) and integer(capture["stderrBytesDiscarded"], 0, 4097), reason)
    require(all(type(capture[key]) is bool for key in ("rawSaved", "rawHashed", "processHandleAcquired", "cleanupConfirmed", "launchAttempted")), reason)
    require(capture["exit"] is None or integer(capture["exit"], -255, 255), reason)
    for key in ("elapsedSeconds", "elapsedWallSeconds", "childDeadlineSeconds"):
        value = capture[key]
        require(value is None or type(value) in (int, float) and math.isfinite(value) and value >= 0, reason)
    require(capture["reason"] is None or type(capture["reason"]) is str and capture["reason"] in CAPTURE_REASONS, reason)
    return copy.deepcopy(capture)


def sanitize_summary(summary):
    """Project fixed typed scalar fields only. This does not qualify the evidence.

    Capture and parent bindings may be added after saving the immutable receipt;
    the evidence SHA hashes that receipt, so no self-hash is placed inside it.
    """
    reason = "summary_structure_invalid"
    require(type(summary) is dict, reason)
    require(integer(summary.get("schema"), 1, 2) and summary.get("mode") in MODES and
            summary.get("workload") in ("small", "standard", "large") and integer(summary.get("cycles"), 1, 90), reason)
    require(summary.get("acceptance") in ("not_evaluated", "passed_finite_current_mac", "needs_investigation", "failed")
            and summary.get("physicalErasure") == "not_claimed", reason)
    out = {key: summary[key] for key in ("schema", "mode", "workload", "cycles", "acceptance", "physicalErasure")}
    metrics = summary.get("metrics")
    require(type(metrics) is dict and set(metrics) == set(ALL_METRICS), reason)
    out["metrics"] = {}
    scalar_keys = set("n first last delta range minimum maximum idleDeltaFromFinalRelease".split())
    list_keys = {"tailFiveMediansPer30", "blockIncrementsFromPostWarmup"}
    for name in ALL_METRICS:
        record = metrics[name]
        require(type(record) is dict and set(record) == scalar_keys | list_keys, reason)
        require(all(integer(record[key], -(2**64-1)) for key in scalar_keys), reason)
        require(all(type(record[key]) is list and len(record[key]) <= 3 and
                    all(integer(value, -(2**64-1)) for value in record[key]) for key in list_keys), reason)
        out["metrics"][name] = copy.deepcopy(record)
    peaks = summary.get("sampledPeaks")
    require(type(peaks) is dict and set(peaks) == {"rss", "physicalFootprint", "processHighWater"}
            and all(integer(value) for value in peaks.values()), reason)
    out["sampledPeaks"] = dict(peaks)
    beat = summary.get("heartbeat")
    require(type(beat) is dict and {"required", "count", "maximumGapNanoseconds"} <= set(beat) and
            set(beat) <= {"required", "count", "maximumGapNanoseconds", "seriesDiagnostic", "seriesCrossingIntervalsIncluded", "acceptanceGate"}
            and type(beat["required"]) is bool and integer(beat["count"]) and integer(beat["maximumGapNanoseconds"]), reason)
    out["heartbeat"] = {key: beat[key] for key in ("required", "count", "maximumGapNanoseconds")}
    if "seriesDiagnostic" in beat:
        series = beat["seriesDiagnostic"]
        require(type(series) is dict and set(series) == {"warmup", "measured"} and
                type(beat.get("seriesCrossingIntervalsIncluded")) is bool and
                beat.get("acceptanceGate") == "aggregate_including_warmup", reason)
        require(all(type(value) is dict and set(value) == {"callbackIntervals", "maximumGapNanoseconds"}
                    and all(integer(number) for number in value.values()) for value in series.values()), reason)
        out["heartbeat"].update(seriesDiagnostic=copy.deepcopy(series),
            seriesCrossingIntervalsIncluded=beat["seriesCrossingIntervalsIncluded"], acceptanceGate=beat["acceptanceGate"])
    else:
        require(not {"seriesCrossingIntervalsIncluded", "acceptanceGate"} & set(beat), reason)
    evidence = summary.get("outputReleaseEvidence")
    count_keys = set("observations observedReleased unobserved notApplicable legacyAmbiguous legacyUnconfirmedReadback".split())
    expected = count_keys | {"schema", "semantics", "observationScope", "applicable", "coverageEstablished", "backingRelease"}
    require(type(evidence) is dict and set(evidence) == expected, reason)
    require(evidence["schema"] is None or integer(evidence["schema"], 1, 2), reason)
    require(evidence["semantics"] in (OUTPUT_SEMANTICS, "legacy_unconfirmed_readback", "legacy_not_applicable") and
            evidence["observationScope"] in ("returned_result", "not_applicable_no_images", "not_applicable_source_only", "internal_render_unobserved") and
            all(type(evidence[key]) is bool for key in ("applicable", "coverageEstablished")) and
            evidence["backingRelease"] == "not_observed" and all(integer(evidence[key], 0, 92) for key in count_keys), reason)
    out["outputReleaseEvidence"] = copy.deepcopy(evidence)
    for key in ("durationMaximumNanoseconds", "recoveryMaximumNanoseconds"):
        value = summary.get(key)
        require(value is None or integer(value), reason)
        out[key] = value
    idle = summary.get("idleTargets")
    require(type(idle) is list and len(idle) <= 6 and all(integer(value, 0, 120) for value in idle), reason)
    require(summary.get("recoveryScope") in ("not_applicable", "m0_wrapper_only", "coordinator_worker_slot"), reason)
    out["idleTargets"], out["recoveryScope"] = list(idle), summary["recoveryScope"]
    if "migrationWindow" in summary:
        window = summary["migrationWindow"]
        require(type(window) is dict and set(window) == {"count", "postWarmup", "tailFiveMedian", "growth"}
                and integer(window["count"], 1, 90), reason)
        for key in ("postWarmup", "tailFiveMedian", "growth"):
            require(type(window[key]) is dict and set(window[key]) == set(METRICS) and
                    all(integer(value, -(2**64-1) if key == "growth" else 0) for value in window[key].values()), reason)
        out["migrationWindow"] = copy.deepcopy(window)
    allowed_findings = {"process_peak_cap", "main_actor_heartbeat_cap", "worker_recovery_cap",
        "rss_continued_growth_two_blocks", "physicalFootprint_continued_growth_two_blocks",
        "rss_unexplained_growth", "physicalFootprint_unexplained_growth", "output_release_not_established",
        "policy_output_observation_semantics_not_current"}
    for key in ("violations", "unexplainedExcess"):
        if key in summary:
            require(type(summary[key]) is list and all(type(value) is str and value in allowed_findings for value in summary[key]), reason)
            out[key] = list(summary[key])
    binding = {"evidenceSHA256": 64, "binarySHA256Before": 64, "binarySHA256After": 64, "sourceID": 40}
    for key, length in binding.items():
        if key in summary:
            require(sha(summary[key], length), reason)
            out[key] = summary[key]
    if "freshProcessOrdinal" in summary:
        require(integer(summary["freshProcessOrdinal"], 1, 5), reason)
        out["freshProcessOrdinal"] = summary["freshProcessOrdinal"]
    if "capture" in summary:
        out["capture"] = _typed_capture(summary["capture"])
    return out


def guard_summary(summary, policy, expected_mode, expected_cycles):
    validate_legacy_policy(policy)
    value = sanitize_summary(summary)
    require(expected_mode in MODES and expected_cycles == (30 if expected_mode == "control" else 10) and
            type(expected_cycles) is int and value["schema"] == 2 and value["mode"] == expected_mode and
            value["cycles"] == expected_cycles and value["workload"] == policy["workload"] and
            value["idleTargets"] == ([0, 5, 15, 30] if expected_mode == "control" else [0]) and
            value["recoveryScope"] == "not_applicable" and value["recoveryMaximumNanoseconds"] is None,
            "summary_scope_mismatch")
    require(value["acceptance"] in ("not_evaluated", "passed_finite_current_mac") and
            not value.get("violations") and not value.get("unexplainedExcess"), "summary_prior_failure")
    fields = {"evidenceSHA256", "binarySHA256Before", "binarySHA256After", "sourceID", "freshProcessOrdinal", "capture"}
    require(fields <= set(value), "summary_binding_missing")
    require(value["binarySHA256Before"] == value["binarySHA256After"], "summary_binding_mismatch")
    capture = value["capture"]
    require(capture["exit"] == 0 and capture["launchAttempted"] and capture["processHandleAcquired"] and
            capture["cleanupConfirmed"] and capture["reason"] is None and capture["stderrBytesDiscarded"] == 0 and
            not capture["rawSaved"] and not capture["rawHashed"] and capture["stdoutBytes"] > 0 and
            all(type(capture[key]) in (int, float) for key in ("elapsedSeconds", "elapsedWallSeconds", "childDeadlineSeconds"))
            and capture["childDeadlineSeconds"] == CHILD_DEADLINE_SECONDS[expected_mode]
            and capture["elapsedSeconds"] <= capture["childDeadlineSeconds"]
            and capture["elapsedWallSeconds"] <= capture["childDeadlineSeconds"], "capture_not_established")
    evidence = value["outputReleaseEvidence"]
    applicable = expected_mode != "control"
    require(integer(value["durationMaximumNanoseconds"], 1) and
            evidence["schema"] == 2 and evidence["semantics"] == OUTPUT_SEMANTICS and evidence["coverageEstablished"] and
            evidence["applicable"] is applicable and evidence["observations"] == expected_cycles + 2 and
            evidence["observationScope"] == ("returned_result" if applicable else "not_applicable_no_images") and
            evidence["observedReleased"] == (expected_cycles + 2 if applicable else 0) and
            evidence["notApplicable"] == (0 if applicable else expected_cycles + 2) and
            evidence["unobserved"] == evidence["legacyAmbiguous"] == evidence["legacyUnconfirmedReadback"] == 0,
            "summary_proof_not_current")
    require(max(value["sampledPeaks"].values()) <= policy["processPeakCapBytes"], "summary_peak_exceeds_frozen_cap")
    beat = value["heartbeat"]
    required = expected_mode == "async"
    require(beat["required"] is required and "seriesDiagnostic" in beat and beat.get("seriesCrossingIntervalsIncluded") is True and
            all(entry["callbackIntervals"] <= beat["count"] and entry["maximumGapNanoseconds"] <= beat["maximumGapNanoseconds"]
                for entry in beat["seriesDiagnostic"].values()) and
            (beat["count"] > 0 if required else beat["count"] == beat["maximumGapNanoseconds"] == 0), "summary_proof_not_current")
    require(beat["maximumGapNanoseconds"] <= policy["heartbeatCapNanoseconds"], "summary_heartbeat_exceeds_frozen_cap")
    require("migrationWindow" in value and value["migrationWindow"]["count"] == expected_cycles,
            "summary_proof_not_current")
    window = value["migrationWindow"]
    derived = {"migrationWindow": copy.deepcopy(window)}
    for name, metric in value["metrics"].items():
        require(metric["n"] == expected_cycles and 0 <= metric["minimum"] <= metric["maximum"] and
                metric["range"] == metric["maximum"] - metric["minimum"] and metric["delta"] == metric["last"] - metric["first"] and
                all(metric["minimum"] <= metric[key] <= metric["maximum"] for key in ("first", "last")) and
                len(metric["tailFiveMediansPer30"]) == len(metric["blockIncrementsFromPostWarmup"]) == expected_cycles // 30 and
                all(metric["minimum"] <= tail <= metric["maximum"] for tail in metric["tailFiveMediansPer30"]), "summary_structure_invalid")
        if name not in METRICS:
            continue
        require(value["sampledPeaks"][name] >= metric["maximum"], "summary_structure_invalid")
        old_e = policy["thresholds"]["core"][name]["E"]
        require(metric["minimum"] <= window["tailFiveMedian"][name] <= metric["maximum"] and
                window["growth"][name] == window["tailFiveMedian"][name] - window["postWarmup"][name],
                "summary_structure_invalid")
        if expected_mode == "control":
            require(metric["tailFiveMediansPer30"] == [window["tailFiveMedian"][name]] and
                    metric["blockIncrementsFromPostWarmup"] == [window["growth"][name]], "summary_structure_invalid")
        require(all(change <= old_e for change in metric["blockIncrementsFromPostWarmup"]) and
                metric["delta"] <= old_e and metric["idleDeltaFromFinalRelease"] <= old_e and
                window["growth"][name] <= old_e, "summary_growth_exceeds_frozen_E")
        if expected_mode == "control":
            require(metric["range"] <= 8*MIB, "control_variation_exceeds_limit")
            new_e = max(8*MIB, 2*metric["range"])
            require(new_e <= old_e, "control_derived_E_exceeds_frozen_E")
            derived[name] = {"observedB": metric["range"], "derivedE": new_e}
    if expected_mode != "control":
        duration = value["durationMaximumNanoseconds"]
        require(integer(duration, 1) and duration <= policy["fullBaselineMaximumAllowedNanoseconds"], "baseline_duration_exceeds_frozen_limit")
        new_t = min(30_000_000_000, max(2_000_000_000, 2*duration))
        require(new_t <= policy["recoveryCapsNanoseconds"][expected_mode], "baseline_derived_T_exceeds_frozen_T")
        derived["durationMaximumNanoseconds"], derived["derivedT"] = duration, new_t
    return {**value, "derivedWitnesses": derived,
            "qualification": "current_proof_within_frozen_limits", "resourceAcceptance": False}


def _numeric_leaves(value, path=()):
    if type(value) in (int, float):
        return {path: (type(value), value)}
    if type(value) is dict:
        return {key: leaf for name, child in value.items() for key, leaf in _numeric_leaves(child, path + (name,)).items()}
    if type(value) is list:
        return {key: leaf for index, child in enumerate(value) for key, leaf in _numeric_leaves(child, path + (index,)).items()}
    return {}


def migrate_policy(old, controls, baselines_by_mode, *, new_binary_sha, new_source_id, old_policy_sha, evidence_hashes):
    """Return a new policy only after all five proofs pass; never alter old data."""
    validate_legacy_policy(old)
    require(sha(new_binary_sha, 64) and sha(new_source_id, 40) and sha(old_policy_sha, 64), "migration_identity_invalid")
    require(type(controls) is list and len(controls) == 3 and type(baselines_by_mode) is dict and
            set(baselines_by_mode) == {"sync", "async"}, "migration_evidence_set_invalid")
    require(type(evidence_hashes) is dict and set(evidence_hashes) == {"controls", "baselines"} and
            type(evidence_hashes["controls"]) is list and len(evidence_hashes["controls"]) == 3 and
            type(evidence_hashes["baselines"]) is dict and set(evidence_hashes["baselines"]) == {"sync", "async"}, "migration_evidence_set_invalid")
    hashes = evidence_hashes["controls"] + [evidence_hashes["baselines"][mode] for mode in ("sync", "async")]
    require(all(sha(value, 64) for value in hashes) and len(set(hashes)) == 5, "migration_evidence_set_invalid")
    witnesses = [guard_summary(value, old, "control", 30) for value in controls]
    witnesses += [guard_summary(baselines_by_mode[mode], old, mode, 10) for mode in ("sync", "async")]
    for ordinal, (witness, expected_hash) in enumerate(zip(witnesses, hashes), 1):
        require(witness["freshProcessOrdinal"] == ordinal and witness["evidenceSHA256"] == expected_hash and
                witness["binarySHA256Before"] == witness["binarySHA256After"] == new_binary_sha and
                witness["sourceID"] == new_source_id, "summary_binding_mismatch")
    result = copy.deepcopy(old)
    result.update(binarySHA256=new_binary_sha, sourceID=new_source_id, outputReleaseSchema=2,
        outputObservationSemantics=OUTPUT_SEMANTICS, criteriaRecalibrated=False,
        legacyObservationsPromoted=False, resourceAcceptance=False,
        migration={"schema": "oneclip-core-policy-evidence-migration-v1", "oldPolicySHA256": old_policy_sha,
                   "evidenceHashes": copy.deepcopy(evidence_hashes),
                   "witnesses": [{key: copy.deepcopy(witness[key]) for key in
                                  ("mode", "cycles", "freshProcessOrdinal", "evidenceSHA256", "derivedWitnesses", "qualification")}
                                 for witness in witnesses]})
    before, after = _numeric_leaves(old), _numeric_leaves(result)
    require(all(path in after and after[path] == value for path, value in before.items()), "frozen_numeric_changed")
    return result
