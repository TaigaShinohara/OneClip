#!/usr/bin/env python3
"""Explicit, finite evidence migration; never relabel old output observations.

Only five fresh, source-bound synthetic children are permitted: three no-image controls
and two ten-cycle baselines. Raw stdout/stderr never reaches a file. Building, capture,
boards, GUI operation, and full thirty-cycle image acceptance are outside this command.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import stat
import statistics
import subprocess
import sys
import tempfile
import time

import prepare_resource_observation as filesystem  # FD-only helpers; no observer preparation.
import resource_policy_migration as migration
import run_security_resources as resources
import run_security_trial as tools_loader


REPO = Path(__file__).absolute().parents[1]
SCHEMA = "oneclip-resource-policy-migration-run-v1"
SERIES = "core-standard-current2-controls30x3-sync10-async10-v1"
PLAN = (("control", 30, 1, 45), ("control", 30, 2, 45), ("control", 30, 3, 45),
        ("sync", 10, 1, 15), ("async", 10, 1, 15))
STDOUT_CAP, LINE_CAP, RECORD_CAP, STDERR_CAP = 524_288, 4_096, 8_192, 4_096
WHOLE_SECONDS = 180
CAPTURE_REASONS = frozenset({"deadline", "whole_deadline", "clock_invalid", "stdout_cap",
    "stderr_cap", "stderr_present_discarded", "cleanup_unknown", "parent_interrupted",
    "launch_failed", "capture_failed", "child_exit_nonzero", "input_changed"})
RUNNER_REASONS = CAPTURE_REASONS | frozenset({"input_path_invalid", "input_file_unsafe",
    "executable_required", "input_changed_during_read", "temporary_path_invalid",
    "temporary_directory_required", "temporary_parent_unsafe", "private_directory_required",
    "old_policy_hash_required", "old_policy_hash_mismatch", "manifest_hash_mismatch", "manifest_fields_invalid",
    "current_source_set_mismatch", "current_source_hash_mismatch", "probe_hash_mismatch",
    "series_already_reserved", "capture_not_established", "summary_not_established",
    "receipt_changed", "result_receipt_not_saved", "runner_failure"})


class RunnerError(ValueError):
    """Fixed classifications only; no exception text is serialized."""
    def __init__(self, reason):
        self.reason = reason if reason in RUNNER_REASONS else "runner_failure"
        super().__init__(self.reason)


def fixed_reason(error, fallback):
    if isinstance(error, RunnerError):
        return error.reason
    if isinstance(error, migration.MigrationError) and error.reason in migration.REASONS:
        return error.reason
    return fallback


def require(value, reason):
    if not value:
        raise RunnerError(reason)


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("ascii")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def owned_bytes(path, maximum, *, executable=False):
    """Bounded owned regular-file read through no-follow directory descriptors."""
    path = Path(path).absolute()
    require(".." not in path.parts, "input_path_invalid")
    parent = filesystem._open_directory_path(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(descriptor)
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                    and before.st_nlink == 1 and not before.st_mode & 0o022
                    and 0 < before.st_size <= maximum, "input_file_unsafe")
            require(not executable or before.st_mode & stat.S_IXUSR, "executable_required")
            data = bytearray()
            while len(data) <= maximum:
                chunk = os.read(descriptor, min(65_536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            after = os.fstat(descriptor)
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            identity = lambda v: (v.st_dev, v.st_ino, v.st_mode, v.st_size, v.st_mtime_ns, v.st_ctime_ns)
            require(identity(before) == identity(after) == identity(current)
                    and len(data) == before.st_size <= maximum, "input_changed_during_read")
            return bytes(data)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def private_temp_directory(path):
    """Require owned, non-writable descendants of the OS temp root and final mode 0700."""
    path = Path(path).absolute()
    require(".." not in path.parts, "temporary_path_invalid")
    lexical = Path(tempfile.gettempdir()).absolute()
    root = lexical.resolve(strict=True)
    relative = next((path.relative_to(p) for p in (root, lexical)
                     if path != p and path.is_relative_to(p)), None)
    require(relative is not None, "temporary_directory_required")
    path = root / relative
    descriptor = filesystem._open_directory_path(root)
    try:
        for part in relative.parts:
            child = os.open(part, filesystem._directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            value = os.fstat(descriptor)
            require(value.st_uid == os.getuid() and not value.st_mode & 0o022, "temporary_parent_unsafe")
        require(stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o700, "private_directory_required")
        result, descriptor = descriptor, None
        return path, result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def save_new(directory, name, value):
    data = encoded(value)
    filesystem._write_new(directory, name, data)
    return sha(data)


def verify_inputs(repo, old_path, old_sha, manifest_path, manifest_sha, source_id):
    require(type(old_sha) is str and tools_loader.HEX64.fullmatch(old_sha), "old_policy_hash_required")
    old_raw = owned_bytes(old_path, 65_536)
    require(sha(old_raw) == old_sha, "old_policy_hash_mismatch")
    old = tools_loader.strict_json(old_raw)
    migration.validate_legacy_policy(old)
    manifest_raw = owned_bytes(manifest_path, 1_048_576)
    require(type(manifest_sha) is str and tools_loader.HEX64.fullmatch(manifest_sha)
            and sha(manifest_raw) == manifest_sha, "manifest_hash_mismatch")
    manifest = tools_loader.strict_json(manifest_raw)
    require(type(manifest) is dict and set(manifest) == {"schema", "sourceIDKind", "sourceID",
            "inputs", "optimization", "toolchain", "binaries"}, "manifest_fields_invalid")
    tools, directory = private_temp_directory(Path(manifest_path).parent)
    os.close(directory)
    # Use the existing manifest verifier; do not derive a replacement source identity.
    tools_loader.load_tools(Path(manifest_path).absolute(), manifest_sha, source_id)
    expected = {str(p.relative_to(repo)) for p in (repo / "OneClip").glob("*.swift")}
    expected |= {"Tests/M4ResourceOwnershipProbe.swift", "Tests/OutputReferenceObservation.swift",
                 "Tests/SecurityRuntimeTrial.swift", "Tests/M4Fixture.swift"}
    require(type(manifest["inputs"]) is dict
            and set(manifest["inputs"]) == expected, "current_source_set_mismatch")
    current = {name: sha(owned_bytes(repo / name, 2_097_152)) for name in sorted(expected)}
    require(current == manifest["inputs"], "current_source_hash_mismatch")
    probe_sha = sha(owned_bytes(tools / "ownership-probe", 134_217_728, executable=True))
    require(probe_sha == manifest["binaries"]["ownership-probe"], "probe_hash_mismatch")
    implementation = {name: sha(owned_bytes(repo / "scripts" / name, 2_097_152)) for name in
        ("migrate_resource_policy.py", "resource_policy_migration.py", "run_security_resources.py",
         "run_security_trial.py", "prepare_resource_observation.py")}
    return old, {"oldPolicySHA256": old_sha, "manifestSHA256": sha(manifest_raw),
                 "sourceID": source_id, "binarySHA256": probe_sha,
                 "sourceHashes": current, "implementationHashes": implementation}, tools


class Budget:
    def __init__(self, seconds):
        self.seconds = seconds
        self.start = self.previous = (time.monotonic(), time.time())
        self.elapsed = (None, None)
        self.remaining()

    def remaining(self):
        now = (time.monotonic(), time.time())
        require(all(type(v) in (int, float) and math.isfinite(v) for v in (*self.start, *now)), "clock_invalid")
        require(all(n >= p >= s for n, p, s in zip(now, self.previous, self.start)), "clock_invalid")
        self.previous = now
        self.elapsed = tuple(n - s for n, s in zip(now, self.start))
        return self.seconds - max(self.elapsed)


def stop_owned(process):
    if process is None:
        return False
    try:
        if process.poll() is not None:
            process.wait(timeout=0)
            return True
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        process.wait(timeout=2)
        return process.poll() is not None
    except BaseException:
        try:
            process.kill()
        except BaseException:
            pass
        try:
            process.wait(timeout=2)
            return process.poll() is not None
        except BaseException:
            return False


def capture_once(argv, directory, seconds, whole):
    """One direct child only; both raw streams are bounded, ephemeral and never hashed."""
    process, selector, reason, error_bytes, attempted = None, None, None, 0, False
    raw, budget = bytearray(), None
    try:
        budget = Budget(seconds)
        require(whole.remaining() >= seconds + 4, "whole_deadline")
        selector = selectors.DefaultSelector()
        attempted = True
        process = subprocess.Popen(argv, cwd=str(directory), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
            env={"PATH": "/usr/bin:/bin", "TMPDIR": str(directory), "LANG": "C"})
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            require(whole.remaining() > 0, "whole_deadline")
            left = budget.remaining()
            require(left > 0, "deadline")
            for key, _ in selector.select(min(0.05, left)):
                cap = STDERR_CAP - error_bytes + 1 if key.data == "stderr" else STDOUT_CAP - len(raw) + 1
                chunk = os.read(key.fileobj.fileno(), min(4096, cap))
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.data == "stderr":
                    error_bytes += len(chunk)
                    require(error_bytes <= STDERR_CAP, "stderr_cap")
                else:
                    require(len(raw) + len(chunk) <= STDOUT_CAP, "stdout_cap")
                    raw.extend(chunk)
        left = min(budget.remaining(), whole.remaining())
        require(left > 0, "deadline")
        process.wait(timeout=left)
        require(budget.remaining() >= 0 and whole.remaining() >= 0, "deadline")
    except subprocess.TimeoutExpired:
        reason = "deadline"
    except KeyboardInterrupt:
        reason = "parent_interrupted"
    except RunnerError as error:
        reason = error.args[0] if error.args and error.args[0] in CAPTURE_REASONS else "capture_failed"
    except BaseException:
        reason = "launch_failed" if process is None else "capture_failed"
    finally:
        cleanup = stop_owned(process)
        if selector is not None:
            selector.close()
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
    if attempted and not cleanup:
        reason = "cleanup_unknown"
    elif reason is None and error_bytes:
        reason = "stderr_present_discarded"
    elif reason is None and process.returncode != 0:
        reason = "child_exit_nonzero"
    elapsed = (None, None)
    if budget is not None:
        try:
            budget.remaining()
            elapsed = budget.elapsed
        except RunnerError:
            reason = "clock_invalid"
    return bytes(raw), {"stdoutBytes": len(raw), "stderrBytesDiscarded": error_bytes,
        "rawSaved": False, "rawHashed": False, "launchAttempted": attempted,
        "processHandleAcquired": process is not None,
        "cleanupConfirmed": cleanup, "exit": process.returncode if process is not None else None,
        "elapsedSeconds": elapsed[0], "elapsedWallSeconds": elapsed[1],
        "childDeadlineSeconds": seconds, "reason": reason}


RECORD_KEYS = {kind: set(keys.split()) | {"kind"} for kind, keys in {
    "SCOPE": "schema synthetic freshProcess mode workload sourceCount board heartbeatSeries outputReleaseSchema warmupCycles measuredCycles idleTargetsSeconds trial recoveryScope",
    "LIMITS": "sourceProviderRelease batchRelease outputReferenceRelease PNGBackingRelease ImageIOCaches physicalErasure imageBudgetBytes processPeakCapBytes memoryAPIs allocatorStatistics ownProcessOnly",
    "IDLE_POLICY": "explicitRunLoopPump externalInspection pressureRelief forcedCollection backgroundLoad observationAndReportingMayAffectProcessMemory",
    "MEMORY": "phase series iteration elapsedNanoseconds unit rss processHighWater physicalFootprint internalBytes reusableBytes compressedBytes mallocBlocksInUse mallocSizeInUse mallocSizeAllocated",
    "OWNERSHIP": "series iteration compositionSucceeded expectedCancellation batchOwnerReleased outputReferenceReleased outputWasObserved outputObservationScope outputReferenceState sourceLiveBytes sourceCreated sourceReleased pngBytes actualImageBytes peakCapExceeded elapsedNanoseconds recoveryNanoseconds passed",
    "HEARTBEAT": "required periodNanoseconds count maximumGapNanoseconds firstTaskEntryElapsedNanoseconds firstCallbackElapsedNanoseconds firstDeadlineFromStart mainActorOnly interactiveUIClaim",
    "HEARTBEAT_SERIES": "series required count maximumGapNanoseconds wholeCrossingIntervalIncluded acceptanceGate",
    "RESULT": "warmupCycles warmupFailures measuredCycles measuredFailures idleObservations idleInterrupted finiteObservationOnly cacheOrLeakConclusion memoryStabilityPass",
}.items()}
FIXED_FIELDS = {
    "SCOPE": {"schema": "2", "synthetic": "1", "freshProcess": "1", "workload": "standard", "board": "not_exercised", "heartbeatSeries": "2", "recoveryScope": "not_applicable"},
    "LIMITS": {"sourceProviderRelease": "tracked", "batchRelease": "weak_observation", "outputReferenceRelease": "weak_observation", "PNGBackingRelease": "unobserved", "ImageIOCaches": "unobserved", "physicalErasure": "not_claimed", "memoryAPIs": "sequential_snapshots", "allocatorStatistics": "all_zones", "ownProcessOnly": "1"},
    "IDLE_POLICY": {"explicitRunLoopPump": "0", "externalInspection": "0", "pressureRelief": "0", "forcedCollection": "0", "backgroundLoad": "uncontrolled", "observationAndReportingMayAffectProcessMemory": "1"},
    "MEMORY": {"unit": "bytes"},
    "HEARTBEAT": {"firstDeadlineFromStart": "1", "mainActorOnly": "1", "interactiveUIClaim": "0"},
    "HEARTBEAT_SERIES": {"wholeCrossingIntervalIncluded": "1", "acceptanceGate": "aggregate"},
    "RESULT": {"finiteObservationOnly": "1", "cacheOrLeakConclusion": "not_automatic", "memoryStabilityPass": "not_automatic"},
}
ENUM_FIELDS = {
    "SCOPE": {"mode": {"control", "sync", "async"}, "idleTargetsSeconds": {"0", "0_5_15_30"}},
    "MEMORY": {"series": {"baseline", "warmup", "measured", "idle"}, "phase": {"baseline", "idle", "generation_pre", "sources_ready", "before_allocation", "source_0", "source_1", "source_2", "source_3", "before_encoding", "after_encoding", "before_result", "scope_released"}},
    "OWNERSHIP": {"series": {"warmup", "measured"}, "outputObservationScope": {"not_applicable_no_images", "returned_result"}, "outputReferenceState": {"not_applicable", "observed_released", "observed_retained", "unobserved"}},
    "HEARTBEAT_SERIES": {"series": {"warmup", "measured"}},
}


def receive(raw, mode, cycles, trial, policy):
    require(0 < len(raw) <= STDOUT_CAP, "summary_not_established")
    require(raw.endswith(b"\n") and b"\r" not in raw and b"\0" not in raw, "summary_not_established")
    lines = raw.split(b"\n")[:-1]
    require(len(lines) <= RECORD_CAP and all(0 < len(line) <= LINE_CAP for line in lines), "summary_not_established")
    try:
        text = raw.decode("ascii", errors="strict")
        rows = resources.parse_log(text)
        require([row["kind"] for row in rows[:3]] == ["M4_OWNER_SCOPE", "M4_OWNER_LIMITS", "M4_OWNER_IDLE_POLICY"]
                and rows[-1]["kind"] == "M4_OWNER_RESULT", "summary_not_established")
        for row in rows:
            kind = row["kind"].removeprefix("M4_OWNER_")
            require(kind in RECORD_KEYS and set(row) == RECORD_KEYS[kind], "summary_not_established")
            for key, value in row.items():
                if key == "kind":
                    continue
                if key in FIXED_FIELDS.get(kind, {}):
                    require(value == FIXED_FIELDS[kind][key], "summary_not_established")
                elif key in ENUM_FIELDS.get(kind, {}):
                    require(value in ENUM_FIELDS[kind][key], "summary_not_established")
                else:
                    require(re.fullmatch(r"-?[0-9]{1,20}", value) is not None
                            and -(1 << 63) <= int(value) < (1 << 64), "summary_not_established")
        scope, limits = resources.one(rows, "SCOPE"), resources.one(rows, "LIMITS")
        require((scope.get("mode"), scope.get("workload"), resources.integer(scope, "measuredCycles"),
                 resources.integer(scope, "trial")) == (mode, "standard", cycles, trial),
                "summary_not_established")
        require(resources.integer(scope, "sourceCount") == (0 if mode == "control" else 4),
                "summary_not_established")
        require(resources.integer(limits, "imageBudgetBytes") == policy["imageBudgetBytes"]
                and resources.integer(limits, "processPeakCapBytes") == policy["processPeakCapBytes"],
                "summary_not_established")
        summary = resources.summarize(text)
        released = resources.exact_iterations(rows, cycles, "MEMORY", "measured", "scope_released")
        warmup = resources.exact_iterations(rows, 2, "MEMORY", "warmup", "scope_released")
        post = {metric: resources.integer(warmup[-1], metric) for metric in resources.METRICS}
        tail = {metric: statistics.median(resources.integer(row, metric) for row in released[-5:])
                for metric in resources.METRICS}
        summary["migrationWindow"] = {"count": cycles, "postWarmup": post, "tailFiveMedian": tail,
            "growth": {metric: tail[metric] - post[metric] for metric in resources.METRICS}}
        return migration.sanitize_summary(summary)
    except (UnicodeError, ValueError, KeyError, TypeError):
        raise RunnerError("summary_not_established") from None


def run_migration(old_policy, old_sha, manifest_path, manifest_sha, source_id, output, *, repo=REPO):
    repo = Path(repo).absolute()
    whole = Budget(WHOLE_SECONDS)
    old, binding, tools = verify_inputs(repo, old_policy, old_sha, manifest_path, manifest_sha, source_id)
    out_fd = filesystem._new_output_directory(output, repo)
    try:
        output, output_identity = private_temp_directory(output)
        os.close(output_identity)
        tools, tools_fd = private_temp_directory(tools)
    except BaseException:
        os.close(out_fd)
        raise
    summaries, receipts, launches = [], [], 0
    result = {"schema": SCHEMA, "series": SERIES, "state": "NOT_ESTABLISHED", "reason": None,
              "childLaunches": 0, "maximumChildren": 5, "policyCreated": False,
              "criteriaRecalibrated": False, "resourceAcceptance": False, "rawSaved": False}
    try:
        claim_key = sha(encoded({"schema": SCHEMA, "series": SERIES,
            "oldPolicySHA256": old_sha, "binarySHA256": binding["binarySHA256"]}))
        try:
            save_new(tools_fd, "resource-policy-migration-" + claim_key + ".json", {
                "schema": SCHEMA, "series": SERIES, "binding": binding,
                "launchReserved": True, "maximumChildren": 5, "automaticRetry": False})
        except FileExistsError:
            raise RunnerError("series_already_reserved") from None
        save_new(out_fd, "plan.json", {"schema": SCHEMA, "series": SERIES, "binding": binding,
            "plan": [{"mode": m, "cycles": c, "trial": t, "deadlineSeconds": d} for m, c, t, d in PLAN],
            "wholeDeadlineSeconds": WHOLE_SECONDS, "cleanupSecondsAfterDeadline": [2, 2],
            "stdoutCapBytes": STDOUT_CAP, "lineCapBytes": LINE_CAP, "maximumRecords": RECORD_CAP,
            "stderrDiscardCapBytes": STDERR_CAP, "automaticRetry": False})
        for ordinal, (mode, cycles, trial, seconds) in enumerate(PLAN, 1):
            _, current, _ = verify_inputs(repo, old_policy, old_sha, manifest_path, manifest_sha, source_id)
            require(current == binding, "input_changed")
            require(whole.remaining() >= seconds + 4, "whole_deadline")
            argv = [str(tools / "ownership-probe"), "--mode", mode, "--workload", "standard",
                    "--cycles", str(cycles), "--trial", str(trial),
                    "--peak-bytes", str(old["processPeakCapBytes"])]
            raw, capture = capture_once(argv, output, seconds, whole)
            launches += int(capture["launchAttempted"])
            summary, parse_reason = None, None
            try:
                summary = receive(raw, mode, cycles, trial, old)
            except RunnerError:
                parse_reason = "summary_not_established"
            del raw  # Never persist unrecognized content, its hash, or exception text.
            try:
                _, current, _ = verify_inputs(repo, old_policy, old_sha, manifest_path, manifest_sha, source_id)
                require(current == binding, "input_changed")
            except (ValueError, OSError, tools_loader.Rejected, filesystem.PreparationError):
                capture["reason"] = "input_changed"
            receipt = {"schema": SCHEMA, "ordinal": ordinal, "mode": mode, "cycles": cycles,
                       "trial": trial, "capture": capture, "summary": summary, "parseReason": parse_reason}
            receipt_sha = save_new(out_fd, f"receipt-{ordinal}.json", receipt)
            receipts.append(receipt_sha)
            require(capture["reason"] is None and capture["cleanupConfirmed"]
                    and capture["exit"] == 0, capture["reason"] or "capture_not_established")
            require(parse_reason is None, "summary_not_established")
            summary.update({"evidenceSHA256": receipt_sha, "binarySHA256Before": binding["binarySHA256"],
                "binarySHA256After": current["binarySHA256"], "sourceID": source_id,
                "freshProcessOrdinal": ordinal, "capture": capture})
            migration.guard_summary(summary, old, expected_mode=mode, expected_cycles=cycles)
            summaries.append(summary)
        require(whole.remaining() >= 0, "whole_deadline")
        for ordinal, digest in enumerate(receipts, 1):
            require(sha(owned_bytes(output / f"receipt-{ordinal}.json", 131_072)) == digest,
                    "receipt_changed")
        _, current, _ = verify_inputs(repo, old_policy, old_sha, manifest_path, manifest_sha, source_id)
        require(current == binding, "input_changed")
        evidence_hashes = {"controls": receipts[:3], "baselines": {"sync": receipts[3], "async": receipts[4]}}
        policy = migration.migrate_policy(old, summaries[:3], {"sync": summaries[3], "async": summaries[4]},
            new_binary_sha=binding["binarySHA256"], new_source_id=source_id,
            old_policy_sha=old_sha, evidence_hashes=evidence_hashes)
        require(whole.remaining() > 0, "whole_deadline")
        save_new(out_fd, "policy.json", policy)
        result.update(state="MIGRATED_FROZEN_CRITERIA", policyCreated=True,
                      policySHA256=sha(encoded(policy)))
    except (ValueError, OSError, tools_loader.Rejected, filesystem.PreparationError) as error:
        # Classification only. Arbitrary parser/OS/validator exception values are discarded.
        result["reason"] = fixed_reason(error, "migration_stopped_unqualified")
    except KeyboardInterrupt:
        result["reason"] = "parent_interrupted"
    finally:
        result["childLaunches"] = launches
        os.close(tools_fd)
        try:
            save_new(out_fd, "migration-result.json", result)
        except OSError:
            result.update(state="NOT_ESTABLISHED", reason="result_receipt_not_saved")
        finally:
            os.close(out_fd)
    return (0 if result["state"] == "MIGRATED_FROZEN_CRITERIA" else 2), result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-policy", required=True, type=Path)
    parser.add_argument("--old-policy-sha256", required=True)
    parser.add_argument("--tools-manifest", required=True, type=Path)
    parser.add_argument("--tools-manifest-sha256", required=True)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(arguments)
    try:
        code, result = run_migration(args.old_policy, args.old_policy_sha256, args.tools_manifest,
            args.tools_manifest_sha256, args.source_id, args.output)
    except (ValueError, OSError, tools_loader.Rejected, filesystem.PreparationError) as error:
        code, result = 2, {"schema": SCHEMA, "state": "NOT_ESTABLISHED", "reason": fixed_reason(error, "inputs_rejected"),
                          "childLaunches": 0, "policyCreated": False, "resourceAcceptance": False}
    except KeyboardInterrupt:
        code, result = 2, {"schema": SCHEMA, "state": "NOT_ESTABLISHED", "reason": "parent_interrupted",
                          "childLaunches": 0, "policyCreated": False, "resourceAcceptance": False}
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
