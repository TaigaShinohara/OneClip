"""Pure fabricated dictionaries only. No calibration, process, or policy file."""

import copy
import importlib.util
import json
from pathlib import Path
from unittest import mock
import unittest


SPEC = importlib.util.spec_from_file_location("resource_policy_migration", Path(__file__).resolve().parents[1] / "scripts/resource_policy_migration.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)
MIB = 1_048_576


def legacy_policy():
    # Fabricated generic profile; no private artifact identity or measured value.
    return dict(schema=1, scope="current_mac_synthetic_only", workload="standard",
        binarySHA256="1"*64, sourceID="2"*40, ramBytes=32*1024*MIB,
        imageBudgetBytes=384*MIB, processPeakCapBytes=1024*MIB,
        heartbeatPeriodNanoseconds=50_000_000, heartbeatCapNanoseconds=250_000_000,
        fullBaselineMaximumAllowedNanoseconds=15_000_000_000,
        thresholds={"core": {"rss": {"B": MIB, "E": 8*MIB}, "physicalFootprint": {"B": 2*MIB, "E": 8*MIB}}},
        recoveryCapsNanoseconds={"sync": 2_000_000_000, "async": 4_000_000_000},
        criteria="proposed_frozen_before_full_trials", unexplainedExcess="unqualified",
        maximumStandardFreshFullRunsPerModePerLength=3,
        maximumConditionalExtendedFreshRunsPerModePerLength=1, allowedLengths=[30, 60, 90],
        physicalErasure="not_claimed")


def summary(mode="control", ordinal=1):
    cycles = 30 if mode == "control" else 10
    required = mode == "async"
    metric = dict(n=cycles, first=30*MIB, last=30*MIB, delta=0, range=0,
                  minimum=30*MIB, maximum=30*MIB, idleDeltaFromFinalRelease=0,
                  tailFiveMediansPer30=[30*MIB] if cycles == 30 else [],
                  blockIncrementsFromPostWarmup=[0] if cycles == 30 else [])
    heartbeat = dict(required=required, count=6 if required else 0, maximumGapNanoseconds=50_000_000 if required else 0,
        seriesDiagnostic={series: {"callbackIntervals": 3 if required else 0,
                                  "maximumGapNanoseconds": 50_000_000 if required else 0} for series in ("warmup", "measured")},
        seriesCrossingIntervalsIncluded=True, acceptanceGate="aggregate_including_warmup")
    return dict(schema=2, mode=mode, workload="standard", cycles=cycles,
        metrics={name: copy.deepcopy(metric) for name in ("rss", "physicalFootprint", "mallocSizeInUse", "mallocSizeAllocated")},
        sampledPeaks={"rss": 40*MIB, "physicalFootprint": 40*MIB, "processHighWater": 40*MIB}, heartbeat=heartbeat,
        outputReleaseEvidence=dict(schema=2, semantics="strong_fenced_weak_identity_v2",
            observationScope="not_applicable_no_images" if mode=="control" else "returned_result",
            applicable=mode!="control", coverageEstablished=True, observations=cycles+2,
            observedReleased=0 if mode=="control" else cycles+2, unobserved=0,
            notApplicable=cycles+2 if mode=="control" else 0, legacyAmbiguous=0, legacyUnconfirmedReadback=0,
            backingRelease="not_observed"), durationMaximumNanoseconds=100_000_000,
        recoveryMaximumNanoseconds=None, idleTargets=[0, 5, 15, 30] if cycles==30 else [0],
        migrationWindow={"count":cycles, "postWarmup":{"rss":30*MIB,"physicalFootprint":30*MIB},
            "tailFiveMedian":{"rss":30*MIB,"physicalFootprint":30*MIB},"growth":{"rss":0,"physicalFootprint":0}},
        recoveryScope="not_applicable", acceptance="not_evaluated", physicalErasure="not_claimed",
        evidenceSHA256=f"{ordinal:064x}", binarySHA256Before="b"*64, binarySHA256After="b"*64,
        sourceID="c"*40, freshProcessOrdinal=ordinal,
        capture=dict(stdoutBytes=4096, stderrBytesDiscarded=0, rawSaved=False, rawHashed=False,
            processHandleAcquired=True, cleanupConfirmed=True, exit=0, elapsedSeconds=30.1 if cycles==30 else 1.0,
            elapsedWallSeconds=30.1 if cycles==30 else 1.0, childDeadlineSeconds=45 if cycles==30 else 15,
            reason=None, launchAttempted=True))


def evidence():
    controls = [summary("control", i) for i in (1, 2, 3)]
    baselines = {"sync": summary("sync", 4), "async": summary("async", 5)}
    hashes = {"controls": [value["evidenceSHA256"] for value in controls],
              "baselines": {mode: value["evidenceSHA256"] for mode, value in baselines.items()}}
    return controls, baselines, hashes


def migrated(old=None, controls=None, baselines=None, hashes=None):
    normal_controls, normal_baselines, normal_hashes = evidence()
    return migration.migrate_policy(legacy_policy() if old is None else old,
        normal_controls if controls is None else controls, normal_baselines if baselines is None else baselines,
        new_binary_sha="b"*64, new_source_id="c"*40, old_policy_sha="a"*64,
        evidence_hashes=normal_hashes if hashes is None else hashes)


def numbers(value, path=()):
    if type(value) in (int, float):
        return {path: (type(value), value)}
    if type(value) is dict:
        return {p: number for key, child in value.items() for p, number in numbers(child, path+(key,)).items()}
    if type(value) is list:
        return {p: number for key, child in enumerate(value) for p, number in numbers(child, path+(key,)).items()}
    return {}


class ResourcePolicyMigrationTests(unittest.TestCase):
    def reject(self, function, reason):
        with self.assertRaises(migration.MigrationError) as raised:
            function()
        self.assertEqual(raised.exception.reason, reason)
        self.assertIn(raised.exception.reason, migration.REASONS)

    def test_all_old_numeric_paths_and_unrelated_properties_are_preserved(self):
        old = legacy_policy(); original = copy.deepcopy(old)
        with mock.patch("builtins.open", side_effect=AssertionError("no I/O")), mock.patch("subprocess.Popen", side_effect=AssertionError("no native launch")):
            result = migrated(old)
        self.assertEqual(old, original)
        for path, value in numbers(old).items():
            self.assertEqual(numbers(result)[path], value)
        for key, value in old.items():
            if key not in ("binarySHA256", "sourceID"):
                self.assertEqual(result[key], value)
        self.assertEqual(result["outputReleaseSchema"], 2)
        self.assertEqual(result["outputObservationSemantics"], "strong_fenced_weak_identity_v2")
        self.assertFalse(result["resourceAcceptance"])
        self.assertFalse(result["criteriaRecalibrated"])
        self.assertFalse(result["legacyObservationsPromoted"])
        self.assertEqual([row["freshProcessOrdinal"] for row in result["migration"]["witnesses"]], [1,2,3,4,5])

    def test_generic_frozen_numbers_are_not_recalculated_from_smaller_witnesses(self):
        old = legacy_policy()
        old["thresholds"]["core"]["rss"] = {"B": 6*MIB, "E": 12*MIB}
        result = migrated(old)
        self.assertEqual(result["thresholds"], old["thresholds"])
        self.assertEqual(result["migration"]["witnesses"][0]["derivedWitnesses"]["rss"], {"observedB":0,"derivedE":8*MIB})

    def test_legacy_versions_unknown_shapes_bools_and_bad_formulas_are_rejected(self):
        mutations = [lambda p:p.update(outputReleaseSchema=1), lambda p:p.update(outputObservationSemantics="legacy"),
            lambda p:p.update(schema=True), lambda p:p.update(workload="small"), lambda p:p.update(ramBytes=True),
            lambda p:p.update(processPeakCapBytes=512*MIB), lambda p:p["allowedLengths"].append(120),
            lambda p:p["thresholds"]["core"]["rss"].update(B=True),
            lambda p:p["thresholds"]["core"]["rss"].update(E=9*MIB),
            lambda p:p["recoveryCapsNanoseconds"].update(sync=2_000_000_001),
            lambda p:p["recoveryCapsNanoseconds"].update(product=2_000_000_000),
            lambda p:p.update(unknown="unapproved")]
        for mutate in mutations:
            old = legacy_policy(); mutate(old)
            self.reject(lambda:migration.validate_legacy_policy(old), "legacy_policy_profile_rejected")

    def test_sanitizer_keeps_unknown_proof_but_drops_unapproved_top_content(self):
        value = summary("sync",4)
        value["outputReleaseEvidence"].update(coverageEstablished=False, observedReleased=0, unobserved=12)
        value["unapproved"] = "synthetic-private-text"
        typed = migration.sanitize_summary(value)
        self.assertNotIn("synthetic-private-text", json.dumps(typed))
        self.assertEqual(typed["outputReleaseEvidence"]["unobserved"], 12)
        self.reject(lambda:migration.guard_summary(typed,legacy_policy(),"sync",10),"summary_proof_not_current")

    def test_missing_metrics_nonfinite_bools_unknown_nested_fields_are_not_zeroed(self):
        mutations = [lambda s:s["sampledPeaks"].update(rss=None), lambda s:s["sampledPeaks"].update(rss=True),
            lambda s:s["metrics"]["rss"].update(first=float("nan")),
            lambda s:s["metrics"]["rss"].update(unknown=1),
            lambda s:s["capture"].update(elapsedSeconds=float("inf")),
            lambda s:s["capture"].update(reason="synthetic-unapproved-detail")]
        for mutate in mutations:
            value=summary(); mutate(value)
            self.reject(lambda:migration.sanitize_summary(value),"summary_structure_invalid")

    def test_schema1_or_fake_coverage_and_prior_failure_never_qualify(self):
        for change in ({"schema":1}, {"semantics":"legacy_unconfirmed_readback"},
                       {"unobserved":1}, {"observedReleased":11}, {"legacyUnconfirmedReadback":12}):
            value=summary("sync",4); value["outputReleaseEvidence"].update(change)
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_proof_not_current")
        for status in ("failed","needs_investigation"):
            value=summary("sync",4); value["acceptance"]=status
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_prior_failure")
        value=summary("sync",4); value["violations"]=["process_peak_cap"]
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_prior_failure")

    def test_scope_length_idle_recovery_and_cold_aggregate_proof_are_required(self):
        mutations=[lambda s:s.update(workload="small"),lambda s:s.update(cycles=30),
            lambda s:s.update(idleTargets=[0,5]),lambda s:s.update(recoveryScope="m0_wrapper_only"),
            lambda s:s.update(recoveryMaximumNanoseconds=0)]
        for mutate in mutations:
            value=summary("sync",4); mutate(value)
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_scope_mismatch")
        value=summary("async",5); value["heartbeat"]["seriesCrossingIntervalsIncluded"]=False
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"async",10),"summary_proof_not_current")

    def test_peak_and_heartbeat_cannot_exceed_old_limits(self):
        value=summary("sync",4); value["sampledPeaks"]["processHighWater"]=1024*MIB+1
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_peak_exceeds_frozen_cap")
        value=summary("async",5); value["heartbeat"]["maximumGapNanoseconds"]=250_000_001
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"async",10),"summary_heartbeat_exceeds_frozen_cap")

    def test_baseline_ten_cycle_delta_and_idle_growth_must_fit_old_E(self):
        for key in ("delta","idleDeltaFromFinalRelease"):
            value=summary("sync",4); metric=value["metrics"]["rss"]
            metric[key]=8*MIB+1
            if key=="delta":
                metric.update(last=metric["first"]+metric[key],maximum=metric["first"]+metric[key],range=metric[key])
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_growth_exceeds_frozen_E")
        value=summary(); value["metrics"]["physicalFootprint"]["blockIncrementsFromPostWarmup"]=[8*MIB+1]
        value["migrationWindow"]["postWarmup"]["physicalFootprint"]-=8*MIB+1
        value["migrationWindow"]["growth"]["physicalFootprint"]=8*MIB+1
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"control",30),"summary_growth_exceeds_frozen_E")

    def test_baseline_warmup_jump_is_rejected_even_when_first_last_delta_is_zero(self):
        value=summary("sync",4)
        value["migrationWindow"]["postWarmup"]["rss"]-=8*MIB+1
        value["migrationWindow"]["growth"]["rss"]=8*MIB+1
        self.assertEqual(value["metrics"]["rss"]["delta"],0)
        self.assertEqual(value["metrics"]["rss"]["blockIncrementsFromPostWarmup"],[])
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_growth_exceeds_frozen_E")

    def test_window_missing_count_arithmetic_tail_and_control_binding_are_checked(self):
        value=summary("sync",4); del value["migrationWindow"]
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_proof_not_current")
        value=summary("sync",4); value["migrationWindow"]["count"]=9
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_proof_not_current")
        for key in ("growth","tailFiveMedian"):
            value=summary("sync",4); value["migrationWindow"][key]["rss"]+=1
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_structure_invalid")
        value=summary(); value["metrics"]["rss"]["blockIncrementsFromPostWarmup"]=[1]
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"control",30),"summary_structure_invalid")

    def test_control_variation_cannot_request_a_looser_E(self):
        value=summary(); metric=value["metrics"]["rss"]
        metric.update(maximum=metric["minimum"]+5*MIB,range=5*MIB)
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"control",30),"control_derived_E_exceeds_frozen_E")

    def test_baseline_duration_and_derived_T_must_fit_each_old_mode_cap(self):
        value=summary("sync",4); value["durationMaximumNanoseconds"]=1_000_000_001
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"baseline_derived_T_exceeds_frozen_T")
        value=summary("async",5); value["durationMaximumNanoseconds"]=1_500_000_000
        self.assertEqual(migration.guard_summary(value,legacy_policy(),"async",10)["derivedWitnesses"]["derivedT"],3_000_000_000)
        value["durationMaximumNanoseconds"]=15_000_000_001
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"async",10),"baseline_duration_exceeds_frozen_limit")

    def test_capture_missing_clocks_failure_handles_and_deadline_are_not_qualified(self):
        mutations={"cleanupConfirmed":False,"exit":-6,"rawSaved":True,"rawHashed":True,
            "launchAttempted":False,"processHandleAcquired":False,"stderrBytesDiscarded":1,
            "elapsedSeconds":None,"elapsedWallSeconds":None,"reason":"deadline","childDeadlineSeconds":45}
        for key, change in mutations.items():
            value=summary("sync",4); value["capture"][key]=change
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"capture_not_established")
        value=summary("sync",4); del value["capture"]
        self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_binding_missing")

    def test_capture_both_clocks_must_fit_the_exact_declared_child_deadline(self):
        for mode,ordinal,cycles,deadline in (("control",1,30,45),("sync",4,10,15),("async",5,10,15)):
            value=summary(mode,ordinal)
            value["capture"].update(elapsedSeconds=deadline,elapsedWallSeconds=deadline)
            self.assertEqual(migration.guard_summary(value,legacy_policy(),mode,cycles)["qualification"],
                             "current_proof_within_frozen_limits")
            for key in ("elapsedSeconds","elapsedWallSeconds"):
                over=copy.deepcopy(value); over["capture"][key]=deadline+0.000001
                self.reject(lambda:migration.guard_summary(over,legacy_policy(),mode,cycles),"capture_not_established")

    def test_sampled_RSS_and_footprint_peaks_cannot_understate_their_own_samples(self):
        for name in ("rss","physicalFootprint"):
            value=summary("sync",4); value["sampledPeaks"][name]=value["metrics"][name]["maximum"]-1
            self.reject(lambda:migration.guard_summary(value,legacy_policy(),"sync",10),"summary_structure_invalid")

    def test_wrong_or_duplicate_bindings_and_evidence_sets_are_rejected(self):
        controls,baselines,hashes=evidence()
        controls[1]["freshProcessOrdinal"]=1
        self.reject(lambda:migrated(controls=controls),"summary_binding_mismatch")
        controls,baselines,hashes=evidence(); hashes["controls"][1]=hashes["controls"][0]
        self.reject(lambda:migrated(hashes=hashes),"migration_evidence_set_invalid")
        controls,baselines,hashes=evidence(); baselines["async"]["binarySHA256After"]="d"*64
        self.reject(lambda:migrated(baselines=baselines),"summary_binding_mismatch")
        controls,baselines,hashes=evidence(); baselines["async"]["sourceID"]="d"*40
        self.reject(lambda:migrated(baselines=baselines),"summary_binding_mismatch")
        controls,baselines,hashes=evidence(); del baselines["async"]
        self.reject(lambda:migrated(baselines=baselines),"migration_evidence_set_invalid")
        self.reject(lambda:migrated(controls=controls[:2]),"migration_evidence_set_invalid")

    def test_bad_hash_types_are_rejected_and_old_inputs_are_deep_copied(self):
        controls,baselines,hashes=evidence(); before=copy.deepcopy((controls,baselines,hashes))
        result=migrated(controls=controls,baselines=baselines,hashes=hashes)
        self.assertEqual((controls,baselines,hashes),before)
        hashes["controls"][0]="f"*64
        self.assertNotEqual(result["migration"]["evidenceHashes"],hashes)
        controls,baselines,hashes=evidence()
        for identity in (True,"x"*64):
            self.reject(lambda:migration.migrate_policy(legacy_policy(),controls,baselines,
                new_binary_sha=identity,new_source_id="c"*40,old_policy_sha="a"*64,evidence_hashes=hashes),"migration_identity_invalid")


if __name__ == "__main__":
    unittest.main()
