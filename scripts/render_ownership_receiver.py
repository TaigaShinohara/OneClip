"""TEMPORARY fixed-scalar receiver. No child launch, build, or resource acceptance.

Call receive_to_file while the bounded capture's raw bytes are still in scope.
It saves the approved object protocol and an independent fixed summary error code;
it never saves raw output, exception text, payload, names, paths, or OS strings.
"""

import errno
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile


MAX_BYTES = 65_536
MAX_LINE_BYTES = 4_096
DEADLINE_NS = 2_000_000_000
IMAGE_BUDGET = 384 * 1_048_576
MODES = ("positive_control", "success", "cancel_before", "cancel_after")
FAILURES = frozenset("invalid_arguments stale_generation duplicate_hook missing_hook provider_unavailable identity_mismatch shape_mismatch positive_control_failed object_retained wrapper_incomplete trace_incomplete gate_deadline worker_deadline unexpected_outcome operation_failed".split())
STATES = frozenset(("ESTABLISHED", "NOT_ESTABLISHED"))
SCOPE = dict(schema="1", classification="temporary_default_render_object_pilot",
             maximumProcesses="1", maximumArms="4", sourceCount="2", sourceWidth="64",
             sourceHeight="64", expectedWidth="96", expectedHeight="224",
             operationDeadlineNanoseconds="2000000000", workerReturnEvidence="original_wrapper_awaited",
             sourcePayload="fictional", board="not_exercised", capture="0", gui="0",
             backingRelease="not_observed", resourceAcceptance="0")
HELD = frozenset("heldImageAlive heldProviderAlive heldImageIdentity heldProviderIdentity providerOnlyImageAlive providerOnlyProviderAlive".split())
TRISTATE = HELD | frozenset("hookImageAlive hookProviderAlive providerGetterStable finalImageAlive finalProviderAlive gateImageAlive gateProviderAlive resultReturned".split())
BITS = frozenset("imageObserved providerObserved gateReached cancellationRequested".split())
COUNTERS = frozenset("schema arm generation hookCalls wrapperStarted valueAwaited wrapperReturned compositionEntered compositionFinished traceDropped elapsedNanoseconds".split())
ARM_KEYS = TRISTATE | BITS | COUNTERS | {"pngBytes", "mode", "state", "reason", "cancellationOutcome"}
RESULT_KEYS = frozenset("schema state reason completedArms maximumArms backingRelease resourceAcceptance".split())
ONES = frozenset("hookCalls imageObserved providerObserved hookImageAlive hookProviderAlive providerGetterStable wrapperStarted valueAwaited wrapperReturned compositionEntered compositionFinished".split())
# Deliberately exact. Unknown/new codes fail closed without echoing their value.
RESOURCE_ERROR_CODES = frozenset("unexpected_log_record malformed_log_field malformed_or_duplicate_log_field legacy_log_not_acceptance_evidence unknown_mode_or_workload incorrect_probe_scope incomplete_terminal_result probe_assertion_failure ownership_not_released source_provider_not_released image_or_process_budget_exceeded missing_duration unexpected_source_provider_count incorrect_completion_classification completed_png_not_observed unexpected_png_result missing_idle_targets incorrect_idle_targets missing_or_duplicate_idle_sample premature_idle_sample incorrect_heartbeat_scope heartbeat_unobserved incomplete_heartbeat_series incorrect_heartbeat_series_scope undeclared_heartbeat_series image_budget_changed output_reference_retained invalid_output_release_state incomplete_output_release_fields incorrect_output_observation_scope output_reference_state_mismatch undeclared_output_release_fields unsupported_output_release_schema unbounded_or_incorrect_cycle_count unavailable_or_invalid_rss unavailable_or_invalid_physicalFootprint unavailable_or_invalid_processHighWater unavailable_or_invalid_mallocSizeInUse unavailable_or_invalid_mallocSizeAllocated".split())
CAPTURE_REASONS = frozenset(("deadline", "stdout_cap", "stderr_cap", "stderr_present_discarded", "cleanup_unknown",
                             "parent_interrupted", "clock_invalid", "launch_failed", "capture_failed", "input_changed"))


class ReceiverError(ValueError):
    """Fixed internal reason codes only."""


def require(condition, code):
    if not condition:
        raise ReceiverError(code)


def number(value, *, minimum=0):
    require(isinstance(value, str) and len(value) <= 20 and
            re.fullmatch(r"(?:0|[1-9][0-9]*|-1)", value) is not None, "noncanonical_number")
    result = int(value)
    require(minimum <= result < 2**64, "numeric_bounds")
    return result


def fields(line):
    words = line.split(" ")
    require(bool(words) and all(words), "malformed_record")
    result = {}
    for word in words[1:]:
        key, separator, value = word.partition("=")
        require(bool(separator) and bool(key) and bool(value) and key not in result, "malformed_or_duplicate_field")
        result[key] = value
    return words[0], result


def checked_arm(row, ordinal):
    require(set(row) == ARM_KEYS, "incorrect_arm_keys")
    require(row["mode"] == MODES[ordinal - 1] and row["state"] in STATES and
            row["reason"] in FAILURES | {"none"} and
            row["cancellationOutcome"] in {"not_requested", "cancelled"}, "incorrect_arm_enum")
    out = {key: row[key] for key in ("mode", "state", "reason", "cancellationOutcome")}
    for key in COUNTERS | BITS:
        out[key] = number(row[key])
    for key in TRISTATE | {"pngBytes"}:
        out[key] = number(row[key], minimum=-1)
    require(out["schema"] == 1 and out["arm"] == ordinal and out["generation"] == ordinal, "arm_generation_mismatch")
    require(all(out[key] in (0, 1) for key in BITS) and
            all(out[key] in (-1, 0, 1) for key in TRISTATE), "invalid_observation_state")
    require((out["state"] == "ESTABLISHED") == (out["reason"] == "none"), "arm_reason_state_mismatch")
    if out["state"] == "NOT_ESTABLISHED":
        return out
    require(all(out[key] == 1 for key in ONES) and
            out["finalImageAlive"] == out["finalProviderAlive"] == out["traceDropped"] == 0 and
            0 < out["elapsedNanoseconds"] <= DEADLINE_NS, "established_arm_invariants_missing")
    if ordinal == 1:
        require(all(out[key] == 1 for key in HELD - {"providerOnlyImageAlive"}) and
                out["providerOnlyImageAlive"] in (0, 1), "positive_control_not_established")
    else:
        require(all(out[key] == -1 for key in HELD), "unexpected_explicit_hold")
    if ordinal <= 2:
        require(out["gateReached"] == out["cancellationRequested"] == 0 and
                out["gateImageAlive"] == out["gateProviderAlive"] == -1 and
                out["cancellationOutcome"] == "not_requested" and out["resultReturned"] == 1 and
                0 < out["pngBytes"] <= IMAGE_BUDGET, "success_result_not_established")
    else:
        require(out["gateReached"] == out["cancellationRequested"] ==
                out["gateImageAlive"] == out["gateProviderAlive"] == 1 and
                out["cancellationOutcome"] == "cancelled" and
                out["resultReturned"] == out["pngBytes"] == 0, "cancel_result_not_established")
    return out


def parse_protocol(data):
    """Validate the entire dedicated protocol; never call the resource summarizer."""
    require(isinstance(data, bytes) and 0 < len(data) <= MAX_BYTES, "output_size_invalid")
    try:
        text = data.decode("ascii")
    except UnicodeError:
        raise ReceiverError("output_encoding_invalid") from None
    require(text.endswith("\n") and "\r" not in text and "\0" not in text, "output_framing_invalid")
    lines = text[:-1].split("\n")
    require(2 <= len(lines) <= 6 and all(0 < len(line) <= MAX_LINE_BYTES for line in lines), "output_record_count_invalid")
    kind, scope = fields(lines[0])
    require(kind == "OC_RENDER_LIFETIME_SCOPE" and scope == SCOPE, "incorrect_scope")
    arms = []
    for line in lines[1:-1]:
        kind, row = fields(line)
        require(kind == "OC_RENDER_LIFETIME_ARM" and len(arms) < 4 and
                all(arm["state"] == "ESTABLISHED" for arm in arms), "arm_order_or_stop_violation")
        arms.append(checked_arm(row, len(arms) + 1))
    kind, terminal = fields(lines[-1])
    require(kind == "OC_RENDER_LIFETIME_RESULT" and set(terminal) == RESULT_KEYS, "incorrect_terminal_keys")
    require(terminal["schema"] == "1" and terminal["maximumArms"] == "4" and
            terminal["backingRelease"] == "not_observed" and terminal["resourceAcceptance"] == "0" and
            terminal["state"] in STATES and terminal["reason"] in FAILURES | {"none"}, "incorrect_terminal_enum")
    completed = number(terminal["completedArms"])
    established = sum(arm["state"] == "ESTABLISHED" for arm in arms)
    require(completed == established and completed <= 4, "terminal_count_mismatch")
    if terminal["state"] == "ESTABLISHED":
        require(terminal["reason"] == "none" and len(arms) == completed == 4, "terminal_success_incomplete")
    else:
        require((not arms and terminal["reason"] == "invalid_arguments" and completed == 0) or
                (bool(arms) and arms[-1]["state"] == "NOT_ESTABLISHED" and
                 arms[-1]["reason"] == terminal["reason"]), "terminal_failure_mismatch")
    return {"scope": dict(SCOPE), "arms": arms,
            "terminal": {**terminal, "completedArms": completed},
            "allObjectsObservedReleased": terminal["state"] == "ESTABLISHED"}


def capture_metadata(metadata, byte_count):
    """Reconstruct only known scalar fields; never transfer arbitrary reason text."""
    require(isinstance(metadata, dict), "capture_metadata_invalid")
    result = {}
    for key in ("stdoutBytes", "stderrBytesDiscarded"):
        value = metadata.get(key)
        require(type(value) is int and 0 <= value <= MAX_BYTES, "capture_metadata_invalid")
        result[key] = value
    require(result["stdoutBytes"] == byte_count, "capture_stdout_size_mismatch")
    require(type(metadata.get("cleanupConfirmed")) is bool, "capture_metadata_invalid")
    result["cleanupConfirmed"] = metadata["cleanupConfirmed"]
    exit_code = metadata.get("exit")
    require(exit_code is None or type(exit_code) is int and -255 <= exit_code <= 255, "capture_metadata_invalid")
    result["exit"] = exit_code
    for key in ("elapsedSeconds", "elapsedWallSeconds"):
        value = metadata.get(key)
        require(value is None or type(value) in (int, float) and math.isfinite(value) and value >= 0,
                "capture_metadata_invalid")
        result[key] = value
    reason = metadata.get("reason")
    result["reason"] = reason if reason in CAPTURE_REASONS else None if reason is None else "unrecognized_capture_failure"
    result["rawSaved"] = False
    return result


def summary_observation(data, summarize=None, evidence_error_type=None):
    if summarize is None:
        return {"status": "NOT_EXERCISED", "reason": "not_exercised_emission_only_scope",
                "resourceAcceptance": False}
    try:
        summarize(data.decode("ascii"))
    except BaseException as error:
        known_type = isinstance(evidence_error_type, type) and isinstance(error, evidence_error_type)
        value = error.args[0] if known_type and len(error.args) == 1 and type(error.args[0]) is str else None
        known_code = value in RESOURCE_ERROR_CODES
        return {"status": "NOT_ESTABLISHED", "reason": value if known_code else
                "unrecognized_evidence_error" if known_type else
                "summary_interrupted" if isinstance(error, KeyboardInterrupt) else "unexpected_summary_failure",
                "recognizedEvidenceError": bool(known_type and known_code), "resourceAcceptance": False}
    return {"status": "SCALAR_PARSE_ONLY", "reason": "summary_parse_does_not_qualify_emission_pilot",
            "resourceAcceptance": False}


def build_report(data, metadata, *, summarize=None, evidence_error_type=None):
    report = {"schema": "oneclip-render-object-receipt-v1", "protocolStatus": "NOT_ESTABLISHED",
              "protocolReason": "receiver_incomplete", "objectObservation": "NOT_ESTABLISHED",
              "objectReason": "receiver_incomplete", "backingRelease": "not_observed",
              "resourceAcceptance": False, "rawSaved": False, "rows": None, "capture": None}
    try:
        report["capture"] = capture_metadata(metadata, len(data) if isinstance(data, bytes) else -1)
        protocol = parse_protocol(data)
        report["rows"] = protocol
        report["protocolStatus"] = "VALID_FIXED_PROTOCOL"
        report["protocolReason"] = "none"
        capture = report["capture"]
        require(capture["cleanupConfirmed"] and capture["reason"] is None and
                capture["stderrBytesDiscarded"] == 0 and
                all(type(capture[key]) in (int, float) for key in ("elapsedSeconds", "elapsedWallSeconds")) and
                capture["elapsedSeconds"] <= 15 and capture["elapsedWallSeconds"] <= 15,
                "capture_not_established")
        expected_exit = 0 if protocol["allObjectsObservedReleased"] else 2
        require(capture["exit"] == expected_exit, "child_exit_mismatch")
        if protocol["allObjectsObservedReleased"]:
            report["objectObservation"] = "ESTABLISHED_OBJECT_LIFETIME_ONLY"
            report["objectReason"] = "none"
        else:
            report["objectReason"] = protocol["terminal"]["reason"]
    except ReceiverError as error:
        # Every ReceiverError is created with one of this file's fixed constants.
        if report["protocolStatus"] != "VALID_FIXED_PROTOCOL":
            report["protocolReason"] = error.args[0]
        report["objectReason"] = error.args[0]
    except Exception:
        report["protocolReason"] = report["objectReason"] = "unexpected_receiver_failure"
    # Separate call, after the approved object protocol was reconstructed. Never copy
    # the summary object or a free-form exception into the persistent receipt.
    report["resourceSummary"] = summary_observation(data, summarize, evidence_error_type)
    return report


def _output_parent(output):
    path = Path(output).absolute()
    require(".." not in path.parts, "output_path_invalid")
    lexical = Path(tempfile.gettempdir()).absolute()
    canonical = lexical.resolve(strict=True)
    relative = None
    for root in (canonical, lexical):
        if path != root and path.is_relative_to(root):
            relative = path.relative_to(root)
            break
    require(relative is not None, "output_outside_os_temp")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(canonical, flags)
    try:
        for part in relative.parts[:-1]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            value = os.fstat(descriptor)
            require(value.st_uid == os.getuid() and not value.st_mode & 0o022, "output_parent_unsafe")
        result, descriptor = descriptor, None
        return result, relative.name
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _save_new(output, report):
    content = (json.dumps(report, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("ascii")
    parent, name = _output_parent(output)
    try:
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            os.fchmod(descriptor, 0o600)
            value = os.fstat(descriptor)
            require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid() and
                    value.st_nlink == 1 and stat.S_IMODE(value.st_mode) == 0o600, "output_file_unsafe")
            remaining = memoryview(content)
            while remaining:
                try:
                    written = os.write(descriptor, remaining)
                except OSError as error:
                    if error.errno == errno.EINTR:
                        continue
                    raise
                require(written > 0, "output_write_failed")
                remaining = remaining[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def receive_to_file(data, metadata, output, *, summarize=None, evidence_error_type=None):
    """Save a new fixed receipt before the caller drops raw bytes. Never overwrite.

    If persistence fails, this raises and the parent must report receipt persistence
    NOT_ESTABLISHED. No raw-output fallback file or retry is permitted.
    """
    # The immutable main receipt is written FIRST, before any resource parser runs.
    # An optional independent resource result uses another new immutable scalar file.
    report = build_report(data, metadata)
    _save_new(output, report)
    if summarize is not None:
        summary = summary_observation(data, summarize, evidence_error_type)
        sidecar = {"schema": "oneclip-render-object-summary-receipt-v1",
                   "resourceSummary": summary, "resourceAcceptance": False, "rawSaved": False}
        _save_new(Path(output).with_name(Path(output).name + ".summary.json"), sidecar)
        report = {**report, "resourceSummary": summary}
    return report
