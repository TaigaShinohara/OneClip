#!/usr/bin/env python3
"""One source-bound synthetic caller-owned-buffer diagnostic; never resource acceptance.

The withdrawn weak-provider observer and closed resource migration are not called.
Only fixed, typed scalar JSONL is retained; unknown output/errors are not saved or hashed.
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
import subprocess

import migrate_resource_policy as safe


REPO = Path(__file__).absolute().parents[1]
SCHEMA = "oneclip-owned-backing-lifetime-v1"
TOOLS_SCHEMA = "oneclip-owned-backing-tools-v1"
BINARY = "owned-backing-probe"
CLAIM = "owned-backing-lifetime-v1.reserved.json"
ARMS = ("provider_hold", "image_hold", "png_encode")
INPUTS = frozenset(("Tests/OwnedBackingLifetimeProbe.swift", "scripts/run_owned_backing_trial.py",
    "scripts/build_owned_backing_tools.sh", "scripts/migrate_resource_policy.py",
    "scripts/prepare_resource_observation.py", "scripts/resource_policy_migration.py",
    "scripts/run_security_resources.py", "scripts/run_security_trial.py"))
BASE_FLAGS = ["-swift-version", "6", "-strict-concurrency=complete", "-O",
              "-whole-module-optimization", "-parse-as-library"]
STDOUT_CAP, LINE_CAP, RECORD_CAP, STDERR_CAP = 16_384, 2_048, 3, 1_024
CHILD_SECONDS, WHOLE_SECONDS, CLEANUP_SECONDS = 10, 14, 4
NATIVE_REASONS = frozenset(("none", "allocation_failed", "context_failed", "context_retained",
    "provider_failed", "image_failed", "encoding_failed", "held_control_failed", "buffer_retained",
    "callback_invalid", "deadline", "internal_failure"))
REASONS = frozenset(("none", "invalid_arguments", "input_rejected", "manifest_hash_mismatch",
    "manifest_invalid", "source_mismatch", "binary_mismatch", "input_changed", "series_already_reserved",
    "output_invalid", "deadline", "whole_deadline", "clock_invalid", "stdout_cap", "stderr_cap",
    "stderr_present_discarded", "cleanup_unknown", "parent_interrupted", "launch_failed", "capture_failed",
    "output_size_invalid", "output_framing_invalid", "record_invalid", "record_fields_invalid",
    "record_value_invalid", "arm_order_invalid", "arm_observation_invalid", "incomplete_protocol",
    "stop_violation", "child_exit_mismatch", "native_not_established", "capture_not_established",
    "receipt_changed", "receipt_not_saved", "runner_failure"))
FIELDS = frozenset(("schema", "ordinal", "arm", "status", "reason", "bufferBytes", "createdBuffers",
    "releasedBuffers", "providerCallbacks", "contextCallbacks", "heldProviderCallbacks", "heldLiveBuffers",
    "heldLiveBytes", "finalLiveBuffers", "finalLiveBytes", "pngBytes", "elapsedNanoseconds"))
HEX64 = re.compile(r"[0-9a-f]{64}")


class Rejected(ValueError):
    def __init__(self, reason):
        self.reason = reason if reason in REASONS else "runner_failure"
        super().__init__(self.reason)


def require(value, reason):
    if not value:
        raise Rejected(reason)


def fixed_reason(error, fallback="runner_failure"):
    if isinstance(error, Rejected):
        return error.reason
    if isinstance(error, safe.RunnerError) and error.reason in REASONS:
        return error.reason
    return fallback


def strict_json(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, "record_invalid")
            result[key] = value
        return result
    def constant(_):
        raise Rejected("record_invalid")
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)
    except Rejected:
        raise
    except (ValueError, UnicodeError, TypeError):
        raise Rejected("record_invalid") from None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def is_integer(value, low, high):
    return type(value) is int and low <= value <= high


def checked_record(row, ordinal):
    require(type(row) is dict and set(row) == FIELDS, "record_fields_invalid")
    require(row["schema"] == SCHEMA and row["status"] in ("OBSERVED", "NOT_ESTABLISHED")
            and type(row["reason"]) is str and row["reason"] in NATIVE_REASONS,
            "record_value_invalid")
    require(type(row["ordinal"]) is int and row["ordinal"] == ordinal and row["arm"] == ARMS[ordinal-1],
            "arm_order_invalid")
    require(row["bufferBytes"] == 16_384 and type(row["bufferBytes"]) is int, "record_value_invalid")
    for key in ("createdBuffers", "releasedBuffers", "providerCallbacks", "contextCallbacks", "finalLiveBuffers"):
        require(is_integer(row[key], 0, 1), "record_value_invalid")
    for key in ("heldProviderCallbacks", "heldLiveBuffers"):
        require(is_integer(row[key], -1, 1), "record_value_invalid")
    require(type(row["heldLiveBytes"]) is int and row["heldLiveBytes"] in (-1, 0, 16_384)
            and type(row["finalLiveBytes"]) is int and row["finalLiveBytes"] in (0, 16_384)
            and is_integer(row["pngBytes"], 0, 65_536)
            and is_integer(row["elapsedNanoseconds"], 0, 9_007_199_254_740_991), "record_value_invalid")
    require((row["status"] == "OBSERVED") == (row["reason"] == "none"), "record_value_invalid")
    if row["status"] == "OBSERVED":
        require(all(row[key] == 1 for key in ("createdBuffers", "releasedBuffers", "providerCallbacks"))
                and row["heldProviderCallbacks"] == 0 and row["heldLiveBuffers"] == 1
                and row["heldLiveBytes"] == 16_384 and row["finalLiveBuffers"] == row["finalLiveBytes"] == 0
                and row["elapsedNanoseconds"] <= 2_000_000_000, "arm_observation_invalid")
        require(row["contextCallbacks"] == (0 if ordinal == 1 else 1)
                and (row["pngBytes"] > 0 if ordinal == 3 else row["pngBytes"] == 0),
                "arm_observation_invalid")
    # Reconstruct only the exact scalar fields validated above.
    return {key: row[key] for key in sorted(FIELDS)}


def receive(raw):
    require(type(raw) is bytes and 0 < len(raw) <= STDOUT_CAP, "output_size_invalid")
    try:
        text = raw.decode("ascii")
    except UnicodeError:
        raise Rejected("output_framing_invalid") from None
    require(text.endswith("\n") and "\r" not in text and "\0" not in text, "output_framing_invalid")
    lines = text[:-1].split("\n")
    require(1 <= len(lines) <= RECORD_CAP and all(0 < len(line) <= LINE_CAP for line in lines),
            "output_framing_invalid")
    rows = []
    for ordinal, line in enumerate(lines, 1):
        require(not rows or rows[-1]["status"] == "OBSERVED", "stop_violation")
        rows.append(checked_record(strict_json(line), ordinal))
    require(rows[-1]["status"] == "NOT_ESTABLISHED" or len(rows) == 3, "incomplete_protocol")
    return rows


def verify_inputs(repo, manifest_path, manifest_sha):
    require(type(manifest_sha) is str and HEX64.fullmatch(manifest_sha), "manifest_hash_mismatch")
    raw = safe.owned_bytes(manifest_path, 65_536)
    require(sha(raw) == manifest_sha, "manifest_hash_mismatch")
    manifest = strict_json(raw)
    require(type(manifest) is dict and set(manifest) == {"schema", "inputs", "binarySHA256", "toolchain", "flags"}
            and manifest["schema"] == TOOLS_SCHEMA, "manifest_invalid")
    require(type(manifest["inputs"]) is dict and set(manifest["inputs"]) == INPUTS
            and all(type(value) is str and HEX64.fullmatch(value) for value in manifest["inputs"].values()),
            "manifest_invalid")
    toolchain = manifest["toolchain"]
    require(type(toolchain) is dict and set(toolchain) == {"swift", "sdk"}
            and all(type(value) is str and 0 < len(value) <= 256
                    and all(32 <= ord(char) < 127 for char in value) for value in toolchain.values()),
            "manifest_invalid")
    tools, descriptor = safe.private_temp_directory(Path(manifest_path).absolute().parent)
    os.close(descriptor)
    flags = [*BASE_FLAGS, "-module-cache-path", str(tools / "module-cache"), "-sdk", toolchain["sdk"]]
    require(manifest["flags"] == flags, "manifest_invalid")
    current = {name: sha(safe.owned_bytes(Path(repo) / name, 2_097_152)) for name in sorted(INPUTS)}
    require(current == manifest["inputs"], "source_mismatch")
    binary_hash = sha(safe.owned_bytes(tools / BINARY, 32 * 1_048_576, executable=True))
    require(type(manifest["binarySHA256"]) is str and HEX64.fullmatch(manifest["binarySHA256"])
            and manifest["binarySHA256"] == binary_hash, "binary_mismatch")
    return tools, {"manifestSHA256": manifest_sha, "binarySHA256": binary_hash, "inputs": current}


def capture_once(binary, directory, whole):
    process, selector, budget, reason = None, None, None, None
    raw, stderr_bytes, attempted, effective = bytearray(), 0, False, None
    try:
        effective = min(CHILD_SECONDS, whole.remaining() - CLEANUP_SECONDS)
        require(effective > 0, "whole_deadline")
        budget = safe.Budget(effective)
        selector = selectors.DefaultSelector()
        attempted = True
        process = subprocess.Popen([str(binary), "--owned-backing-lifetime-v1"], cwd=str(directory),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
            env={"PATH": "/usr/bin:/bin", "TMPDIR": str(directory), "LANG": "C"})
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            require(whole.remaining() > CLEANUP_SECONDS, "whole_deadline")
            left = min(budget.remaining(), whole.remaining() - CLEANUP_SECONDS)
            require(left > 0, "deadline")
            for key, _ in selector.select(min(0.05, left)):
                cap = STDERR_CAP - stderr_bytes + 1 if key.data == "stderr" else STDOUT_CAP - len(raw) + 1
                chunk = os.read(key.fileobj.fileno(), min(4096, cap))
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.data == "stderr":
                    stderr_bytes += len(chunk)
                    require(stderr_bytes <= STDERR_CAP, "stderr_cap")
                else:
                    require(len(raw) + len(chunk) <= STDOUT_CAP, "stdout_cap")
                    raw.extend(chunk)
        left = min(budget.remaining(), whole.remaining() - CLEANUP_SECONDS)
        require(left > 0, "deadline")
        process.wait(timeout=left)
        require(budget.remaining() >= 0 and whole.remaining() >= CLEANUP_SECONDS, "deadline")
    except subprocess.TimeoutExpired:
        reason = "deadline"
    except KeyboardInterrupt:
        reason = "parent_interrupted"
    except (Rejected, safe.RunnerError) as error:
        reason = fixed_reason(error, "capture_failed")
    except BaseException:
        reason = "launch_failed" if attempted and process is None else "capture_failed"
    finally:
        cleanup = safe.stop_owned(process)
        if selector is not None:
            try:
                selector.close()
            except BaseException:
                reason = "capture_failed"
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except BaseException:
                        pass
    if process is not None and not cleanup:
        reason = "cleanup_unknown"
    elif reason is None and stderr_bytes:
        reason = "stderr_present_discarded"
    elapsed = (None, None)
    if budget is not None:
        try:
            budget.remaining()
            whole.remaining()
            elapsed = budget.elapsed
        except safe.RunnerError:
            reason = "clock_invalid"
    return bytes(raw), {"stdoutBytes": len(raw), "stderrBytesDiscarded": stderr_bytes,
        "rawSaved": False, "rawHashed": False, "launchAttempted": attempted,
        "processHandleAcquired": process is not None, "cleanupConfirmed": cleanup,
        "exit": process.returncode if process is not None else None,
        "elapsedSeconds": elapsed[0], "elapsedWallSeconds": elapsed[1],
        "childDeadlineSeconds": effective, "reason": reason}


def run_trial(manifest_path, manifest_sha, output, reservation, *, repo=REPO):
    whole = safe.Budget(WHOLE_SECONDS)
    tools, binding = verify_inputs(repo, manifest_path, manifest_sha)
    reservation, reservation_fd = safe.private_temp_directory(reservation)
    out_fd = None
    result = {"schema": SCHEMA, "state": "NOT_ESTABLISHED", "reason": "runner_failure",
        "childLaunches": 0, "maximumChildren": 1, "automaticRetry": False,
        "resourceAcceptance": False, "productBackingRelease": "not_observed",
        "physicalErasure": "not_claimed", "oldPolicyChanged": False, "rawSaved": False, "rawHashed": False}
    try:
        out_fd = safe.filesystem._new_output_directory(output, Path(repo).absolute())
        output, identity = safe.private_temp_directory(output)
        os.close(identity)
        try:
            safe.save_new(reservation_fd, CLAIM, {"schema": SCHEMA, "launchReserved": True,
                "maximumChildren": 1, "automaticRetry": False, "binding": binding})
        except FileExistsError:
            raise Rejected("series_already_reserved") from None
        safe.save_new(out_fd, "plan.json", {"schema": SCHEMA, "binding": binding,
            "arms": list(ARMS), "maximumChildren": 1, "childCapSeconds": CHILD_SECONDS,
            "wholeDeadlineSeconds": WHOLE_SECONDS, "cleanupSeconds": [2, 2],
            "stdoutCapBytes": STDOUT_CAP, "lineCapBytes": LINE_CAP, "maximumRecords": RECORD_CAP,
            "stderrDiscardCapBytes": STDERR_CAP, "automaticRetry": False,
            "resourceAcceptance": False, "productBackingRelease": "not_observed"})
        _, before = verify_inputs(repo, manifest_path, manifest_sha)
        require(before == binding, "input_changed")
        raw, capture = capture_once(tools / BINARY, output, whole)
        result["childLaunches"] = int(capture["launchAttempted"])
        rows, protocol_reason = None, "none"
        try:
            rows = receive(raw)
        except Rejected as error:
            protocol_reason = error.reason
        del raw
        after_matches = False
        try:
            _, after = verify_inputs(repo, manifest_path, manifest_sha)
            after_matches = after == binding
        except (ValueError, OSError):
            pass
        if not after_matches:
            capture["reason"] = "input_changed"
        receipt = {"schema": "oneclip-owned-backing-receipt-v1", "binding": binding,
            "bindingAfterMatches": after_matches, "capture": capture, "records": rows,
            "protocolReason": protocol_reason, "resourceAcceptance": False,
            "productBackingRelease": "not_observed", "physicalErasure": "not_claimed",
            "rawSaved": False, "rawHashed": False}
        receipt_sha = safe.save_new(out_fd, "receipt.json", receipt)
        result["receiptSHA256"] = receipt_sha
        # Qualification only happens after the fixed receipt has been saved.
        require(capture["reason"] is None, capture["reason"] or "capture_not_established")
        require(capture["launchAttempted"] and capture["processHandleAcquired"] and capture["cleanupConfirmed"]
                and capture["stderrBytesDiscarded"] == 0
                and type(capture["childDeadlineSeconds"]) in (int, float)
                and 0 < capture["childDeadlineSeconds"] <= CHILD_SECONDS
                and all(type(capture[key]) in (int, float) and math.isfinite(capture[key])
                        and 0 <= capture[key] <= capture["childDeadlineSeconds"]
                        for key in ("elapsedSeconds", "elapsedWallSeconds")), "capture_not_established")
        require(protocol_reason == "none" and rows is not None, protocol_reason)
        observed = len(rows) == 3 and all(row["status"] == "OBSERVED" for row in rows)
        require(capture["exit"] == (0 if observed else 2), "child_exit_mismatch")
        require(observed, "native_not_established")
        require(sha(safe.owned_bytes(output / "receipt.json", 65_536)) == receipt_sha, "receipt_changed")
        require(whole.remaining() >= 0, "whole_deadline")
        result.update(state="ESTABLISHED_DIAGNOSTIC_ONLY", reason="none")
    except KeyboardInterrupt:
        result["reason"] = "parent_interrupted"
    except Exception as error:
        result["reason"] = fixed_reason(error, "input_rejected")
    finally:
        os.close(reservation_fd)
        if out_fd is not None:
            try:
                safe.save_new(out_fd, "result.json", result)
            except OSError:
                result.update(state="NOT_ESTABLISHED", reason="receipt_not_saved")
            finally:
                os.close(out_fd)
    return (0 if result["state"] == "ESTABLISHED_DIAGNOSTIC_ONLY" else 2), result


class FixedParser(argparse.ArgumentParser):
    def error(self, _message):
        raise Rejected("invalid_arguments")


def main(arguments=None):
    try:
        parser = FixedParser(description=__doc__, allow_abbrev=False)
        parser.add_argument("--manifest", type=Path, required=True)
        parser.add_argument("--manifest-sha256", required=True)
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--reservation", type=Path, required=True)
        args = parser.parse_args(arguments)
        code, result = run_trial(args.manifest, args.manifest_sha256, args.output, args.reservation)
    except KeyboardInterrupt:
        code, result = 2, {"schema": SCHEMA, "state": "NOT_ESTABLISHED", "reason": "parent_interrupted",
            "childLaunches": 0, "resourceAcceptance": False}
    except Exception as error:
        code, result = 2, {"schema": SCHEMA, "state": "NOT_ESTABLISHED", "reason": fixed_reason(error, "input_rejected"),
            "childLaunches": 0, "resourceAcceptance": False}
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
