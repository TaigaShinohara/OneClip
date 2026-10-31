#!/usr/bin/env python3
"""Opt-in parent for one manual, fixture-only OS trial. Default/help performs no I/O.

The ledger pins a reviewed tools manifest, counts reservations across sessions, and never
launches an existing process by name. Only fresh children are terminated. No shell, credential,
OS-transition or general-clipboard operation is provided. Output contains fixed codes/hashes.
Invalidation alone remains NOT_ESTABLISHED. A second explicit HUD action must prove fresh
SCK/PNG/named-board success and actual worker return before a counted limited full-cell PASS.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import stat
import subprocess
import sys
import time
import uuid


# v2 additionally pins the parent verifier bytes; v1 ledgers are rejected, not migrated.
SCHEMA = "oneclip-security-trial-ledger-v2"
MODES = {"single", "collection"}
TRACE_MODES = MODES | {"none", "annotation"}
STAGES = {"selecting", "sck", "encoding", "retained"}
TRANSITIONS = {"menu-lock", "key-lock", "system-sleep", "display-sleep"}
PASS = "PASS_LIMITED_OBSERVATION"
STATUSES = {PASS, "NOT_ESTABLISHED", "FAIL", "CANCELLED", "BLOCKED", "RESERVED"}
MAX_ATTEMPTS = 5
TARGET_PASSES = 3
SESSION_SECONDS = 900
SESSION_OPERATIONS = 3
WAIT_POLL_SECONDS = 0.25
MAX_SESSIONS = 256
MAX_TRIALS = len(MODES) * len(STAGES) * len(TRANSITIONS) * MAX_ATTEMPTS
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
SAFE_ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
REASONS = {
    "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE", "TRACE_OVERFLOW",
    "MANUAL_TRANSITION_NOT_CONFIRMED", "TRANSITION_OR_INVALIDATION_UNOBSERVED",
    "REQUESTED_STAGE_OVERLAP_NOT_ESTABLISHED", "RETURN_OR_IMAGE_RELEASE_NOT_ESTABLISHED",
    "OBSERVED_ROUTE_INVALIDATED_WITHOUT_NEW_CONSUMER", "EXPLICIT_RECOVERY_NOT_ESTABLISHED", "OBSERVED_INVALIDATION_AND_EXPLICIT_RECOVERY", "START_PREREQUISITE_UNAVAILABLE",
    "SELECTION_NOT_AVAILABLE", "FIXTURE_ACQUISITION_NOT_ESTABLISHED", "RETAINED_STAGE_NOT_ESTABLISHED",
    "PERSON_CANCELLED", "SESSION_15_MINUTE_LIMIT",
}
CODES = set("""systemSleep displaySleep sessionResigned displayChanged protectedDataUnavailable
consoleSessionChanged consoleSessionUnavailable consoleUserChanged consoleUserUnavailable
cgDispatch cgCheck cgRegister cgRegisterDispatch cgRegisterCheck cgCancel scDelivery scCheck scRegister scCancel
environmentValidated operationStarted operationInvalidated captureRequested captureCallback captureReturned
compositionStarted compositionCheckpoint compositionFinished allocationCheckpoint sourceCheckpoint beforeEncoding
afterEncoding beforeResult cancellationRequested workerStarted workerReturned slotAcquired slotReleased resultAdopted
viewShown viewHidden viewDraw clipboardPrepared clipboardWrite clipboardOutcome permissionChecked permissionRequested
resultReceived resultInvalidated resultInvalidationDelivered archiveQueued archiveStarted archiveReturned archiveOutcome
resultPreviewShown resultPreviewHidden resultPreviewDraw editCopyStarted editCopyReturned
annotationOpened annotationLoaded annotationExportStarted annotationExportReturned annotationInvalidated
annotationResultAdopted annotationViewShown annotationViewHidden annotationViewDraw annotationInvalidationDelivered
trialReady manualTransitionConfirmed trialRecoveryStarted trialRecoveryFinished trialFinished""".split())
PHASES = set("none idle onboarding permission selecting capturing encoding writing failure cancelling ready reviewingReplacement".split())
OUTCOMES = set("none accepted rejected changed unchanged unavailable cancelled success failure stale restarted".split())


class Rejected(Exception):
    """Only fixed reason codes may cross the CLI boundary."""


class Clock:
    def wall_ns(self):
        return time.time_ns()

    def monotonic_ns(self):
        return time.monotonic_ns()


def require(condition, code):
    if not condition:
        raise Rejected(code)


def integer(value, low=0, high=(1 << 64) - 1):
    return type(value) is int and low <= value <= high


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "DUPLICATE_JSON_KEY")
            result[key] = value
        return result

    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Rejected("NONFINITE_JSON")))
    except Rejected:
        raise
    except (ValueError, UnicodeError, TypeError):
        raise Rejected("INVALID_JSON") from None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def no_symlink_chain(path):
    path = Path(path)
    require(path.is_absolute(), "ABSOLUTE_PATH_REQUIRED")
    require(".." not in path.parts, "PARENT_PATH_REJECTED")
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            require(part == path, "PATH_PARENT_MISSING")
            continue
        require(not stat.S_ISLNK(info.st_mode), "SYMLINK_REJECTED")
    return path


def owned_directory(path, private=True):
    path = no_symlink_chain(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "OWNED_DIRECTORY_REQUIRED")
    if private:
        require(stat.S_IMODE(info.st_mode) == 0o700, "PRIVATE_DIRECTORY_REQUIRED")
    return path


def regular_bytes(path, limit, *, exact_mode=None):
    path = no_symlink_chain(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
                "OWNED_REGULAR_FILE_REQUIRED")
        require(not (stat.S_IMODE(info.st_mode) & 0o022), "WRITABLE_BY_OTHERS_REJECTED")
        if exact_mode is not None:
            require(stat.S_IMODE(info.st_mode) == exact_mode, "PRIVATE_FILE_REQUIRED")
        require(0 <= info.st_size <= limit, "FILE_SIZE_LIMIT")
        data = bytearray()
        while True:
            chunk = os.read(descriptor, min(65_536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= limit, "FILE_SIZE_LIMIT")
        after = os.fstat(descriptor)
        require((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), "FILE_CHANGED_DURING_READ")
        return bytes(data)
    finally:
        os.close(descriptor)


def current_runner_sha256():
    return digest(regular_bytes(Path(__file__).resolve(), 1_048_576))


def require_runner(candidate):
    require(candidate.get("parent_runner_sha256") == current_runner_sha256(), "PARENT_RUNNER_HASH_MISMATCH")


def load_tools(manifest_path, expected_manifest, expected_source):
    require(type(expected_manifest) is str and HEX64.fullmatch(expected_manifest), "APPROVED_MANIFEST_HASH_REQUIRED")
    require(type(expected_source) is str and HEX40.fullmatch(expected_source), "APPROVED_SOURCE_ID_REQUIRED")
    manifest_path = no_symlink_chain(manifest_path)
    tools = owned_directory(manifest_path.parent)
    raw = regular_bytes(manifest_path, 1_048_576)
    require(digest(raw) == expected_manifest, "MANIFEST_HASH_MISMATCH")
    value = strict_json(raw)
    require(type(value) is dict and value.get("schema") == "oneclip-security-tools-v1"
            and value.get("sourceIDKind") == "build-inputs-sha1", "TOOLS_SCHEMA_REJECTED")
    inputs = value.get("inputs")
    require(type(inputs) is dict and 4 <= len(inputs) <= 256, "TOOLS_INPUTS_REJECTED")
    require({"OneClip/CaptureSecurityTrace.swift", "OneClip/M0ImageCore.swift", "OneClip/M3PracticeFixture.swift",
             "Tests/M4ResourceOwnershipProbe.swift", "Tests/SecurityRuntimeTrial.swift", "Tests/M4Fixture.swift"} <= set(inputs), "TOOLS_INPUTS_REJECTED")
    for name, sha in inputs.items():
        require(type(name) is str and type(sha) is str and HEX64.fullmatch(sha), "TOOLS_INPUTS_REJECTED")
        require(not PurePosixPath(name).is_absolute() and ".." not in PurePosixPath(name).parts,
                "TOOLS_INPUTS_REJECTED")
        require(re.fullmatch(r"OneClip/[A-Za-z0-9]+\.swift|Tests/(?:M4ResourceOwnershipProbe|SecurityRuntimeTrial|M4Fixture)\.swift", name),
                "TOOLS_INPUTS_REJECTED")
    calculated = hashlib.sha1(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    require(value.get("sourceID") == expected_source == calculated, "SOURCE_ID_MISMATCH")
    binaries = value.get("binaries")
    require(type(binaries) is dict and set(binaries) == {"ownership-probe", "SecurityRuntimeTrial", "M4Fixture"}, "TOOLS_BINARIES_REJECTED")
    for name, sha in binaries.items():
        require(type(sha) is str and HEX64.fullmatch(sha), "TOOLS_BINARIES_REJECTED")
        binary = tools / name
        require(digest(regular_bytes(binary, 134_217_728)) == sha, "BINARY_HASH_MISMATCH")
        require(binary.stat().st_mode & stat.S_IXUSR, "EXECUTABLE_REQUIRED")
    require(value.get("optimization") == "-O", "TOOLS_OPTIMIZATION_REJECTED")
    toolchain = value.get("toolchain")
    return {
        "manifest_path": str(manifest_path), "manifest_sha256": expected_manifest,
        "source_id_kind": "build-inputs-sha1", "source_id": expected_source,
        "runtime_sha256": binaries["SecurityRuntimeTrial"], "fixture_sha256": binaries["M4Fixture"],
        "toolchain_recorded": toolchain is not None,
        "toolchain_sha256": digest(json.dumps(toolchain, sort_keys=True).encode()),
        "optimization": "-O", "tools_dir": str(tools), "parent_runner_sha256": current_runner_sha256(),
    }


def cell_key(mode, stage, transition):
    require(mode in MODES and stage in STAGES and transition in TRANSITIONS, "CELL_REJECTED")
    return f"{mode}/{stage}/{transition}"


def validate_state(state):
    require(type(state) is dict and set(state) == {"schema", "candidate", "sessions", "current_session", "trials", "active_trial", "halt"}
            and state["schema"] == SCHEMA, "LEDGER_SCHEMA_REJECTED")
    require(type(state["candidate"]) is dict and type(state["sessions"]) is list and type(state["trials"]) is list,
            "LEDGER_SCHEMA_REJECTED")
    candidate = state["candidate"]
    require(set(candidate) == {"manifest_path", "manifest_sha256", "source_id_kind", "source_id", "runtime_sha256", "fixture_sha256",
                              "toolchain_recorded", "toolchain_sha256", "optimization", "tools_dir", "parent_runner_sha256"}, "CANDIDATE_SCHEMA_REJECTED")
    require(all(type(candidate[k]) is str and HEX64.fullmatch(candidate[k]) for k in ("manifest_sha256", "runtime_sha256", "fixture_sha256", "toolchain_sha256", "parent_runner_sha256"))
            and type(candidate["source_id"]) is str and HEX40.fullmatch(candidate["source_id"])
            and candidate["source_id_kind"] == "build-inputs-sha1" and candidate["optimization"] == "-O"
            and type(candidate["toolchain_recorded"]) is bool
            and all(type(candidate[k]) is str and Path(candidate[k]).is_absolute() for k in ("manifest_path", "tools_dir")), "CANDIDATE_SCHEMA_REJECTED")
    require(len(state["sessions"]) <= MAX_SESSIONS and len(state["trials"]) <= MAX_TRIALS, "LEDGER_BOUNDS_REJECTED")
    for index, session in enumerate(state["sessions"], 1):
        require(type(session) is dict and set(session) == {"ordinal", "wall_ns", "monotonic_ns"}
                and integer(session["ordinal"], index, index) and integer(session["wall_ns"]) and integer(session["monotonic_ns"]), "SESSION_SCHEMA_REJECTED")
    require(state["current_session"] is None or integer(state["current_session"], 1, len(state["sessions"])), "SESSION_REFERENCE_REJECTED")
    require((state["halt"] is None or type(state["halt"]) is str)
            and state["halt"] in {None, "SECURITY_FAILURE", "CLEANUP_UNCONFIRMED"}, "HALT_REJECTED")
    reserved = []
    counts = {}
    passes = {}
    session_counts = {}
    for index, trial in enumerate(state["trials"], 1):
        require(type(trial) is dict and set(trial) == {"ordinal", "session", "cell", "status", "result"}
                and integer(trial["ordinal"], index, index) and integer(trial["session"], 1, len(state["sessions"])), "TRIAL_SCHEMA_REJECTED")
        require(type(trial["cell"]) is str and len(trial["cell"].split("/")) == 3, "CELL_REJECTED")
        require(cell_key(*trial["cell"].split("/")) == trial["cell"] and type(trial["status"]) is str and trial["status"] in STATUSES,
                "TRIAL_SCHEMA_REJECTED")
        require(type(trial["result"]) is dict, "RESULT_SCHEMA_REJECTED")
        if trial["status"] == "RESERVED":
            require(trial["result"] == {}, "RESERVATION_REJECTED")
            reserved.append(index)
        else:
            require(type(trial["result"].get("reason")) is str and re.fullmatch(r"[A-Z0-9_]{1,100}", trial["result"]["reason"]), "RESULT_SCHEMA_REJECTED")
            require(set(trial["result"]) <= {"reason", "metadata_sha256", "trace_sha256", "manual_transition_confirmed",
                    "product_image_view_exercised", "invalidation_observation_established", "explicit_recovery_exercised",
                    "full_cell_accepted", "recovery_evidence_validated", "cleanup_confirmed", "parent_timeout", "process_termination_used"}, "RESULT_SCHEMA_REJECTED")
            for key in ("metadata_sha256", "trace_sha256"):
                require(key not in trial["result"] or (type(trial["result"][key]) is str and HEX64.fullmatch(trial["result"][key])), "RESULT_SCHEMA_REJECTED")
            for key in ("manual_transition_confirmed", "product_image_view_exercised", "invalidation_observation_established", "explicit_recovery_exercised",
                        "full_cell_accepted", "recovery_evidence_validated", "cleanup_confirmed", "parent_timeout", "process_termination_used"):
                require(key not in trial["result"] or type(trial["result"][key]) is bool, "RESULT_SCHEMA_REJECTED")
        if trial["status"] == PASS:
            require(proven_pass(trial["result"]), "FULL_CELL_EVIDENCE_REQUIRED")
        else:
            require(trial["result"].get("full_cell_accepted", False) is False, "FULL_CELL_EVIDENCE_REQUIRED")
        counts[trial["cell"]] = counts.get(trial["cell"], 0) + 1
        passes[trial["cell"]] = passes.get(trial["cell"], 0) + (trial["status"] == PASS)
        session_counts[trial["session"]] = session_counts.get(trial["session"], 0) + 1
    require(all(n <= MAX_ATTEMPTS for n in counts.values()) and all(n <= TARGET_PASSES for n in passes.values()), "CELL_CAP_REJECTED")
    require(all(n <= SESSION_OPERATIONS for n in session_counts.values()), "SESSION_CAP_REJECTED")
    require(state["active_trial"] is None or integer(state["active_trial"], 1, len(state["trials"])), "ACTIVE_RESERVATION_REJECTED")
    require(reserved == ([] if state["active_trial"] is None else [state["active_trial"]]), "ACTIVE_RESERVATION_REJECTED")
    require(not any(t["status"] == "FAIL" for t in state["trials"]) or state["halt"] == "SECURITY_FAILURE", "FAILURE_LATCH_REJECTED")


class Ledger:
    def __init__(self, directory):
        self.path = owned_directory(directory)
        self.directory = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.lock = os.open("lock", os.O_RDWR | os.O_NOFOLLOW, dir_fd=self.directory)
        info = os.fstat(self.lock)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o600, "LOCK_FILE_REJECTED")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock); os.close(self.directory)
            raise Rejected("LEDGER_BUSY") from None
        try:
            self.state = strict_json(regular_bytes(self.path / "state.json", 1_048_576, exact_mode=0o600))
            validate_state(self.state)
            require_runner(self.state["candidate"])
            for trial in self.state["trials"]:
                if trial["status"] == PASS: self.verify_pass_evidence(trial, trial["result"])
        except BaseException:
            os.close(self.lock); os.close(self.directory)
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.lock); os.close(self.directory)

    def save(self):
        validate_state(self.state)
        require_runner(self.state["candidate"])
        payload = (json.dumps(self.state, sort_keys=True, indent=2) + "\n").encode()
        require(len(payload) <= 1_048_576, "LEDGER_SIZE_LIMIT")
        name = ".state-" + uuid.uuid4().hex
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload); stream.flush(); os.fsync(stream.fileno())
            os.replace(name, "state.json", src_dir_fd=self.directory, dst_dir_fd=self.directory)
            os.fsync(self.directory)
        finally:
            try:
                os.unlink(name, dir_fd=self.directory)
            except FileNotFoundError:
                pass

    def tools(self):
        candidate = self.state["candidate"]
        require_runner(candidate)
        try:
            current = load_tools(candidate["manifest_path"], candidate["manifest_sha256"], candidate["source_id"])
        except (KeyError, TypeError):
            raise Rejected("CANDIDATE_SCHEMA_REJECTED") from None
        require(current == candidate, "CANDIDATE_BINDING_CHANGED")
        return current

    def new_session(self, clock):
        require(self.state["halt"] is None, "LEDGER_HALTED")
        require(self.state["active_trial"] is None, "RESERVATION_RECOVERY_REQUIRED")
        self.tools()
        require(len(self.state["sessions"]) < MAX_SESSIONS, "SESSION_HISTORY_LIMIT")
        session = {"ordinal": len(self.state["sessions"]) + 1, "wall_ns": clock.wall_ns(), "monotonic_ns": clock.monotonic_ns()}
        self.state["sessions"].append(session); self.state["current_session"] = session["ordinal"]
        self.save()

    def remaining(self, clock):
        identifier = self.state["current_session"]
        require(identifier is not None, "EXPLICIT_SESSION_REQUIRED")
        session = self.state["sessions"][identifier - 1]
        wall = clock.wall_ns() - session["wall_ns"]
        monotonic = clock.monotonic_ns() - session["monotonic_ns"]
        require(wall >= 0 and monotonic >= 0, "SESSION_CLOCK_DISCONTINUITY")
        return SESSION_SECONDS - max(wall, monotonic) / 1_000_000_000

    def reserve(self, mode, stage, transition, clock):
        require(self.state["halt"] is None, "LEDGER_HALTED")
        require(self.state["active_trial"] is None, "RESERVATION_RECOVERY_REQUIRED")
        candidate = self.tools()
        require(self.remaining(clock) > 0, "SESSION_EXPIRED")
        key = cell_key(mode, stage, transition)
        previous = [t for t in self.state["trials"] if t["cell"] == key]
        require(len(previous) < MAX_ATTEMPTS, "CELL_ATTEMPT_LIMIT")
        require(sum(t["status"] == PASS for t in previous) < TARGET_PASSES, "CELL_TARGET_ALREADY_MET")
        session = self.state["current_session"]
        require(sum(t["session"] == session for t in self.state["trials"]) < SESSION_OPERATIONS, "SESSION_OPERATION_LIMIT")
        trial = {"ordinal": len(self.state["trials"]) + 1, "session": session, "cell": key, "status": "RESERVED", "result": {}}
        self.state["trials"].append(trial); self.state["active_trial"] = trial["ordinal"]
        self.save()  # Durable before any process is launched; a crash consumes this attempt.
        return trial, candidate

    def verify_pass_evidence(self, trial, result):
        proof = read_evidence(self.path / "runs" / f"{trial['ordinal']:06d}" / "runtime",
            self.state["candidate"], *trial["cell"].split("/"), 0)
        require(proof["status"] == PASS and all(proof[k] == result.get(k) for k in (
            "metadata_sha256", "trace_sha256", "invalidation_observation_established",
            "explicit_recovery_exercised", "full_cell_accepted", "recovery_evidence_validated")), "FULL_CELL_EVIDENCE_CHANGED")

    def complete(self, trial, result):
        require(self.state["active_trial"] == trial["ordinal"] and trial["status"] == "RESERVED", "RESERVATION_MISMATCH")
        require(result["status"] in STATUSES - {"RESERVED"}, "RESULT_STATUS_REJECTED")
        require(proven_pass(result) if result["status"] == PASS else result.get("full_cell_accepted", False) is False,
                "FULL_CELL_EVIDENCE_REQUIRED")
        if result["status"] == PASS: self.verify_pass_evidence(trial, result)
        trial["status"] = result["status"]; trial["result"] = {k: v for k, v in result.items() if k != "status"}
        self.state["active_trial"] = None
        if result["status"] == "FAIL": self.state["halt"] = "SECURITY_FAILURE"
        elif result.get("cleanup_confirmed") is False: self.state["halt"] = "CLEANUP_UNCONFIRMED"
        self.save()

    def recover(self):
        require(self.state["halt"] != "SECURITY_FAILURE", "LEDGER_HALTED")
        identifier = self.state["active_trial"]
        if identifier is not None:
            self.complete(self.state["trials"][identifier - 1], {"status": "NOT_ESTABLISHED", "reason": "INTERRUPTED_PARENT_MANUAL_CLEANUP_CONFIRMED", "cleanup_confirmed": True})
        if self.state["halt"] == "CLEANUP_UNCONFIRMED":
            self.state["halt"] = None; self.save()


def initialize(directory, manifest, expected_manifest, expected_source):
    candidate = load_tools(manifest, expected_manifest, expected_source)
    require_runner(candidate)
    path = no_symlink_chain(directory)
    require(not path.exists(), "NEW_LEDGER_DIRECTORY_REQUIRED")
    path.mkdir(mode=0o700)
    for name in ("lock", "state.json"):
        descriptor = os.open(path / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            if name == "state.json":
                stream.write(json.dumps({"schema": SCHEMA, "candidate": candidate, "sessions": [], "current_session": None,
                    "trials": [], "active_trial": None, "halt": None}, sort_keys=True).encode())
            stream.flush(); os.fsync(stream.fileno())
    (path / "runs").mkdir(mode=0o700)


class Driver:
    def fixture(self, binary):
        return subprocess.Popen([str(binary)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=SAFE_ENV, shell=False, close_fds=True, start_new_session=True)

    def ready(self, process, timeout):
        require(process.stdout is not None, "FIXTURE_READINESS_UNAVAILABLE")
        deadline = time.monotonic() + timeout
        pending = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline and process.poll() is None:
                for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fd, 4_096)
                    if not chunk: return False
                    pending.extend(chunk)
                    if len(pending) > 65_536: return False
                    if b"READY ONECLIP_M4_FIXTURE\n" in pending.splitlines(keepends=True): return True
        return False

    def runtime(self, arguments):
        return subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=SAFE_ENV, shell=False, close_fds=True, start_new_session=True)

    def cleanup(self, process):
        if process is None: return True
        try:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=2)
            return process.poll() is not None
        except (OSError, subprocess.TimeoutExpired):
            return False
        finally:
            if getattr(process, "stdout", None) is not None: process.stdout.close()


def proven_pass(result):
    return (result.get("reason") == "OBSERVED_INVALIDATION_AND_EXPLICIT_RECOVERY"
        and all(result.get(k) is True for k in ("manual_transition_confirmed", "invalidation_observation_established",
            "explicit_recovery_exercised", "full_cell_accepted", "recovery_evidence_validated", "cleanup_confirmed"))
        and result.get("parent_timeout") is False and result.get("process_termination_used") is False
        and all(type(result.get(k)) is str and HEX64.fullmatch(result[k]) for k in ("metadata_sha256", "trace_sha256")))


def slot_integrity(entries, mode, *, balanced=False):
    acquired = working = False
    for entry in entries:
        if entry["mode"] != mode: continue
        code = entry["code"]
        if code == "slotAcquired":
            if acquired: return False
            acquired = True
        elif code == "workerStarted":
            if not acquired or working: return False
            working = True
        elif code == "workerReturned":
            if not working: return False
            working = False
        elif code == "slotReleased":
            if not acquired or working: return False
            acquired = False
    return not balanced or (not acquired and not working)


ENVIRONMENT_CODES = set("""systemSleep displaySleep sessionResigned displayChanged protectedDataUnavailable
consoleSessionChanged consoleSessionUnavailable consoleUserChanged consoleUserUnavailable""".split())
RECOVERY_CODES = set("""operationStarted slotAcquired workerStarted captureRequested captureCallback captureReturned
resultAdopted compositionStarted compositionFinished clipboardPrepared clipboardWrite clipboardOutcome workerReturned slotReleased""".split())


def recovery_projection(mode):
    capture = "operationStarted slotAcquired workerStarted captureRequested captureCallback captureReturned resultAdopted".split()
    composition = "compositionStarted compositionFinished resultAdopted clipboardPrepared clipboardWrite clipboardOutcome workerReturned slotReleased".split()
    return capture + ([] if mode == "single" else "workerReturned slotReleased slotAcquired workerStarted".split()) + composition


def recovery_established(entries, mode, start, end):
    if not (start > 0 and end > start): return False
    starts = [e for e in entries if e["code"] == "trialRecoveryStarted"]
    finishes = [e for e in entries if e["code"] == "trialRecoveryFinished"]
    if not (len(starts) == len(finishes) == 1 and starts[0]["sequence"] == start and starts[0]["mode"] == mode
            and finishes[0]["sequence"] == end and finishes[0]["mode"] == mode and finishes[0]["outcome"] == "accepted"): return False
    segment = [e for e in entries if start < e["sequence"] < end]
    if any(e["code"] in ENVIRONMENT_CODES | {"operationInvalidated", "permissionRequested"} for e in segment): return False
    if any(e["code"] in RECOVERY_CODES and e["mode"] != mode for e in segment): return False
    return ([e["code"] for e in segment if e["code"] in RECOVERY_CODES] == recovery_projection(mode)
        and slot_integrity(segment, mode, balanced=True)
        and all(any(e["code"] == code and e["outcome"] == "success" for e in segment)
                for code in ("captureCallback", "captureReturned"))
        and all(any(e["code"] == "resultAdopted" and e["phase"] == phase for e in segment) for phase in ("capturing", "encoding"))
        and any(e["code"] == "clipboardWrite" and e["outcome"] == "none" for e in segment)
        and any(e["code"] == "clipboardOutcome" and e["outcome"] == "accepted" for e in segment))


def observation_established(meta, entries, mode, stage, transition):
    ready, end = meta["ready_sequence"], meta["invalidation_evidence_end_sequence"]
    if not (0 < ready <= end <= meta["evidence_end_sequence"] <= len(entries)
            and meta["manual_transition_confirmed"] is True and meta["manual_operations_requested"] == 1
            and meta["dropped_count"] == meta["evidence_dropped_count"] == 0
            and all(meta[k] is True for k in ("worker_ended", "images_cleared", "slot_free"))
            and entries[ready - 1]["code"] == "trialReady" and entries[ready - 1]["mode"] == mode): return False
    old = entries[:end]
    if not slot_integrity(old, mode, balanced=True): return False
    if not any(e["sequence"] > ready and e["mode"] == mode and e["code"] == "manualTransitionConfirmed" for e in old): return False
    signals = {"system-sleep": {"systemSleep"}, "display-sleep": {"displaySleep"}}.get(transition,
        {"displaySleep", "sessionResigned", "protectedDataUnavailable", "consoleSessionChanged", "consoleUserChanged"})
    events = [e for e in old if e["sequence"] > ready and e["code"] in signals]
    if not events: return False
    event = events[0]["sequence"]
    invalidations = [e for e in old if e["sequence"] > event and e["mode"] == mode and e["code"] == "operationInvalidated"]
    if not invalidations: return False
    if stage == "selecting" and invalidations[0]["phase"] != "selecting": return False
    if stage in {"sck", "encoding"}:
        begin, finish = ("captureRequested", "captureCallback") if stage == "sck" else ("compositionStarted", "compositionFinished")
        if not any(ready < e["sequence"] < event and e["mode"] == mode and e["code"] == begin
                and any(x["sequence"] > event and x["mode"] == mode and x["code"] == finish for x in old) for e in old): return False
    return True


def leaked(entries, mode, ready, authorized_recovery_start=0):
    if any(e["mode"] == "annotation" for e in entries): return True
    if not slot_integrity(entries, mode): return True
    if any(e["code"] in RECOVERY_CODES and e["mode"] != mode for e in entries): return True
    if any(e["code"] in {"archiveQueued", "archiveStarted", "editCopyStarted", "resultPreviewShown", "resultPreviewDraw", "permissionRequested"} for e in entries): return True
    finished = [e for e in entries if e["code"] == "trialRecoveryFinished"]
    if finished and any(e["sequence"] > finished[0]["sequence"] and e["code"] in RECOVERY_CODES | {"viewDraw"} for e in entries): return True
    for invalidation in (e for e in entries if e["sequence"] > ready and e["mode"] == mode and e["code"] == "operationInvalidated"):
        stop = authorized_recovery_start if authorized_recovery_start > invalidation["sequence"] else len(entries) + 1
        if any(invalidation["sequence"] < e["sequence"] < stop and (e["code"] in {"operationStarted", "captureRequested", "permissionRequested"}
                or (e["mode"] == mode and (e["code"] in {"resultAdopted", "viewDraw", "clipboardPrepared", "clipboardWrite"}
                    or (e["code"] == "clipboardOutcome" and e["outcome"] == "accepted")))) for e in entries): return True
    return False


def read_evidence(output, candidate, mode, stage, transition, returncode):
    owned_directory(output)
    require({p.name for p in output.iterdir()} == {"metadata.json", "trace.json"}, "EVIDENCE_FILES_REJECTED")
    meta_raw = regular_bytes(output / "metadata.json", 32_768)
    trace_raw = regular_bytes(output / "trace.json", 4_194_304)
    meta, entries = strict_json(meta_raw), strict_json(trace_raw)
    require(type(meta) is dict and meta.get("schema") == "oneclip-runtime-trial-v1", "METADATA_SCHEMA_REJECTED")
    require(set(meta) == {"schema", "source_baseline", "status", "reason", "mode", "stage", "transition", "ready_sequence",
        "evidence_end_sequence", "manual_transition_confirmed", "worker_ended", "images_cleared", "slot_free",
        "invalidation_observation_established", "explicit_recovery_exercised", "full_cell_accepted",
        "invalidation_evidence_end_sequence", "recovery_start_sequence", "recovery_end_sequence",
        "recovery_manual_start_confirmed", "recovery_worker_ended", "recovery_slot_free", "archive_exercised", "annotation_exercised",
        "fixture_executable_sha256", "fixture_binding", "single_retained_forced_writer_rejection", "selection_ui",
        "product_image_view_exercised", "board", "general_board_access", "permission_requested", "automatic_os_operations",
        "manual_operations_requested", "session_limit_seconds", "parent_ledger_required", "dropped_count", "evidence_dropped_count",
        "full_os_matrix_complete", "m4_acceptance_complete", "voiceover_verified", "os_atomicity_guaranteed"}, "METADATA_FIELDS_REJECTED")
    require(meta["source_baseline"] == "062f1bd1129d0286f4696fec612db5f6d6593050", "METADATA_BASELINE_REJECTED")
    require(type(meta.get("status")) is str and meta["status"] in STATUSES - {"RESERVED"}
            and type(meta.get("reason")) is str and meta["reason"] in REASONS, "METADATA_STATUS_REJECTED")
    require((meta.get("mode"), meta.get("stage"), meta.get("transition")) == (mode, stage, transition), "METADATA_CELL_MISMATCH")
    require(meta.get("fixture_executable_sha256") == candidate["fixture_sha256"]
            and meta.get("fixture_binding") == "parent_fresh_pid_path_sha256", "METADATA_FIXTURE_MISMATCH")
    require(meta.get("selection_ui") == "harness_fixed_fixture_crop" and meta.get("product_image_view_exercised") is False
            and meta.get("board") == "private_named" and meta.get("parent_ledger_required") is True, "METADATA_BOUNDARY_REJECTED")
    for key in ("general_board_access", "permission_requested", "full_os_matrix_complete", "m4_acceptance_complete", "voiceover_verified", "os_atomicity_guaranteed", "archive_exercised", "annotation_exercised"):
        require(meta.get(key) is False, "METADATA_GUARANTEE_REJECTED")
    require(type(meta.get("manual_transition_confirmed")) is bool
            and type(meta.get("single_retained_forced_writer_rejection")) is bool
            and meta["single_retained_forced_writer_rejection"] == (mode == "single" and stage == "retained"), "METADATA_MIXED_SCOPE_REJECTED")
    require(type(meta.get("automatic_os_operations")) is int and meta["automatic_os_operations"] == 0
            and integer(meta.get("manual_operations_requested"), 0, 1)
            and type(meta.get("session_limit_seconds")) is int and meta["session_limit_seconds"] == 900, "METADATA_LIMIT_REJECTED")
    for key in ("ready_sequence", "evidence_end_sequence", "dropped_count", "evidence_dropped_count",
                "invalidation_evidence_end_sequence", "recovery_start_sequence", "recovery_end_sequence"):
        require(integer(meta.get(key)), "METADATA_SEQUENCE_REJECTED")
    require(meta["evidence_dropped_count"] <= meta["dropped_count"], "METADATA_SEQUENCE_REJECTED")
    for key in ("worker_ended", "images_cleared", "slot_free", "invalidation_observation_established",
                "explicit_recovery_exercised", "full_cell_accepted", "recovery_manual_start_confirmed",
                "recovery_worker_ended", "recovery_slot_free"):
        require(type(meta.get(key)) is bool, "METADATA_RETURN_FLAGS_REJECTED")
    require(type(entries) is list and len(entries) <= 8_192, "TRACE_BOUNDS_REJECTED")
    previous_time = 0
    for index, entry in enumerate(entries, 1):
        require(type(entry) is dict and set(entry) == {"trial", "sequence", "relativeNanos", "code", "mode", "phase", "outcome"}, "TRACE_SCHEMA_REJECTED")
        require(type(entry["trial"]) is int and entry["trial"] == 1 and type(entry["sequence"]) is int and entry["sequence"] == index
                and integer(entry["relativeNanos"], previous_time) and type(entry["code"]) is str and entry["code"] in CODES
                and type(entry["mode"]) is str and entry["mode"] in TRACE_MODES
                and type(entry["phase"]) is str and entry["phase"] in PHASES
                and type(entry["outcome"]) is str and entry["outcome"] in OUTCOMES, "TRACE_VALUE_REJECTED")
        previous_time = entry["relativeNanos"]
    require(meta["ready_sequence"] <= meta["evidence_end_sequence"] <= len(entries), "EVIDENCE_PREFIX_REJECTED")
    require(meta["invalidation_evidence_end_sequence"] <= meta["evidence_end_sequence"], "OBSERVATION_PREFIX_REJECTED")
    ready = meta["ready_sequence"]
    observation = observation_established(meta, entries, mode, stage, transition)
    start, end = meta["recovery_start_sequence"], meta["recovery_end_sequence"]
    authorized = (observation and meta["recovery_manual_start_confirmed"] is True
        and start > meta["invalidation_evidence_end_sequence"] and start <= meta["evidence_end_sequence"]
        and entries[start - 1]["code"] == "trialRecoveryStarted" and entries[start - 1]["mode"] == mode
        and slot_integrity(entries[:start - 1], mode, balanced=True))
    status, reason = meta["status"], meta["reason"]
    violation = leaked(entries, mode, ready, start if authorized else 0)
    if violation: status, reason = "FAIL", "POST_INVALIDATION_CONSUMER_OR_EARLY_SLOT_RELEASE"
    recovered = (authorized and end <= meta["evidence_end_sequence"] and meta["recovery_worker_ended"] is True
        and meta["recovery_slot_free"] is True and recovery_established(entries, mode, start, end))
    if status != "FAIL":
        require(not meta["invalidation_observation_established"] or observation, "INVALIDATION_OBSERVATION_REQUIRED")
        if status == PASS:
            require(returncode == 0 and observation and recovered
                and all(meta[k] is True for k in ("invalidation_observation_established", "explicit_recovery_exercised", "full_cell_accepted"))
                and reason == "OBSERVED_INVALIDATION_AND_EXPLICIT_RECOVERY", "FULL_CELL_EVIDENCE_REQUIRED")
        else:
            require(meta["full_cell_accepted"] is False and meta["explicit_recovery_exercised"] is False,
                    "UNACCEPTED_FULL_CELL_FLAGS")
            if reason == "EXPLICIT_RECOVERY_NOT_ESTABLISHED":
                require(returncode == 2 and meta["invalidation_observation_established"] is True and observation,
                        "INVALIDATION_OBSERVATION_REQUIRED")
    accepted = status == PASS and not violation
    return {"status": status, "reason": reason, "metadata_sha256": digest(meta_raw), "trace_sha256": digest(trace_raw),
        "manual_transition_confirmed": meta["manual_transition_confirmed"], "product_image_view_exercised": False,
        "invalidation_observation_established": meta["invalidation_observation_established"] if status != "FAIL" else False,
        "explicit_recovery_exercised": accepted, "full_cell_accepted": accepted,
        "recovery_evidence_validated": accepted}


def run_trial(ledger, mode, stage, transition, *, driver=None, clock=None):
    driver, clock = driver or Driver(), clock or Clock()
    trial, candidate = ledger.reserve(mode, stage, transition, clock)
    fixture = runtime = None
    fixture_launch_attempted = runtime_launch_attempted = False
    result = {"status": "NOT_ESTABLISHED", "reason": "RUNTIME_EVIDENCE_MISSING"}
    timed_out = terminated = False
    trial_root = ledger.path / "runs" / f"{trial['ordinal']:06d}"
    try:
        owned_directory(ledger.path / "runs")
        trial_root.mkdir(mode=0o700)
        remaining = ledger.remaining(clock)
        require(remaining > 0, "SESSION_EXPIRED")
        fixture_launch_attempted = True
        fixture = driver.fixture(Path(candidate["tools_dir"]) / "M4Fixture")
        require(integer(fixture.pid, 1, (1 << 31) - 1), "FRESH_FIXTURE_PID_REJECTED")
        require(driver.ready(fixture, min(10, remaining)), "FIXTURE_NOT_READY")
        require(fixture.poll() is None, "FIXTURE_EXITED")
        remaining = ledger.remaining(clock)
        require(remaining > 0, "SESSION_EXPIRED")
        output = trial_root / "runtime"
        arguments = [str(Path(candidate["tools_dir"]) / "SecurityRuntimeTrial"), "--run", "--mode", mode, "--stage", stage,
            "--transition", transition, "--output-dir", str(output), "--fixture-pid", str(fixture.pid),
            "--fixture-executable", str(Path(candidate["tools_dir"]) / "M4Fixture"), "--fixture-sha256", candidate["fixture_sha256"],
            "--parent-fresh-fixture", "yes"]
        runtime_launch_attempted = True
        runtime = driver.runtime(arguments)
        try:
            # On macOS a monotonic timeout can pause across system sleep. Re-read both clocks
            # after every short wait, so a wall-clock expiry is acted on at the next slice.
            while True:
                remaining = ledger.remaining(clock)
                if remaining <= 0:
                    raise subprocess.TimeoutExpired("SecurityRuntimeTrial", 0)
                try:
                    returncode = runtime.wait(timeout=min(WAIT_POLL_SECONDS, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
        except subprocess.TimeoutExpired:
            timed_out = terminated = True
            driver.cleanup(runtime)
            returncode = runtime.poll()
        try:
            result = read_evidence(output, candidate, mode, stage, transition, returncode)
        except (Rejected, OSError):
            result = {"status": "NOT_ESTABLISHED", "reason": "RUNTIME_EVIDENCE_INVALID_OR_MISSING"}
        if result["status"] != "FAIL" and (timed_out or ledger.remaining(clock) <= 0):
            result.update(status="NOT_ESTABLISHED", reason="PARENT_SESSION_DEADLINE", full_cell_accepted=False, recovery_evidence_validated=False)
    except (Rejected, OSError, subprocess.SubprocessError):
        result = {"status": "NOT_ESTABLISHED", "reason": "LAUNCH_OR_READINESS_NOT_ESTABLISHED"}
    finally:
        terminated = terminated or (runtime is not None and runtime.poll() is None)
        # An exception/interrupt inside Popen can occur after fork but before its handle returns.
        # No handle is not evidence of no child: do not claim cleanup or allow automatic retry.
        runtime_cleanup = driver.cleanup(runtime) and not (runtime_launch_attempted and runtime is None)
        fixture_cleanup = driver.cleanup(fixture) and not (fixture_launch_attempted and fixture is None)
        result["cleanup_confirmed"] = runtime_cleanup and fixture_cleanup
        result["parent_timeout"] = timed_out
        result["process_termination_used"] = terminated
        if not result["cleanup_confirmed"] and result["status"] != "FAIL":
            result.update(status="NOT_ESTABLISHED", reason="CHILD_CLEANUP_UNCONFIRMED", full_cell_accepted=False, recovery_evidence_validated=False)
        ledger.complete(trial, result)
    return result


def summary(ledger):
    return {"status": "LEDGER_STATUS", "source_id": ledger.state["candidate"]["source_id"],
        "runtime_sha256": ledger.state["candidate"]["runtime_sha256"],
        "parent_runner_sha256": ledger.state["candidate"]["parent_runner_sha256"], "sessions": len(ledger.state["sessions"]),
        "reserved_attempts": len(ledger.state["trials"]), "established_passes": sum(t["status"] == PASS for t in ledger.state["trials"]),
        "invalidation_observations": sum(t["result"].get("invalidation_observation_established") is True for t in ledger.state["trials"]),
        "explicit_recovery_exercised": any(t["result"].get("explicit_recovery_exercised") is True for t in ledger.state["trials"]),
        "full_cell_accepted": False,
        "halted": ledger.state["halt"] is not None, "active_reservation": ledger.state["active_trial"] is not None,
        "full_os_matrix_complete": False}


def parser():
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command")
    init = commands.add_parser("init")
    init.add_argument("--ledger-dir", required=True)
    init.add_argument("--tools-manifest", required=True)
    init.add_argument("--expected-manifest-sha256", required=True)
    init.add_argument("--expected-source-id", required=True)
    for command in ("session", "run", "status", "recover"):
        item = commands.add_parser(command); item.add_argument("--ledger-dir", required=True)
        if command == "session": item.add_argument("--person-began-session", action="store_true", required=True)
        if command == "recover": item.add_argument("--person-confirmed-owned-children-stopped", action="store_true", required=True)
        if command == "run":
            item.add_argument("--mode", choices=sorted(MODES), required=True)
            item.add_argument("--stage", choices=sorted(STAGES), required=True)
            item.add_argument("--transition", choices=sorted(TRANSITIONS), required=True)
    check = commands.add_parser("check-tool")
    check.add_argument("--tools-manifest", required=True); check.add_argument("--expected-manifest-sha256", required=True)
    check.add_argument("--expected-source-id", required=True); check.add_argument("--operation", choices=["help", "self-test"], required=True)
    return value


def main(arguments=None):
    cli = parser(); args = cli.parse_args(arguments)
    if args.command is None: cli.print_help(); return 0
    try:
        if args.command == "init":
            initialize(args.ledger_dir, args.tools_manifest, args.expected_manifest_sha256, args.expected_source_id)
            print(json.dumps({"status": "INITIALIZED_NOT_RUN"})); return 0
        if args.command == "check-tool":
            candidate = load_tools(args.tools_manifest, args.expected_manifest_sha256, args.expected_source_id)
            result = subprocess.run([str(Path(candidate["tools_dir"]) / "SecurityRuntimeTrial"), "--" + args.operation],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=SAFE_ENV,
                shell=False, timeout=30, close_fds=True)
            require(result.returncode == 0, "TOOL_CHECK_FAILED")
            print(json.dumps({"status": "TOOL_CHECK_COMPLETE", "operation": args.operation})); return 0
        with Ledger(args.ledger_dir) as ledger:
            if args.command == "session": ledger.new_session(Clock())
            elif args.command == "recover": ledger.recover()
            elif args.command == "run":
                result = run_trial(ledger, args.mode, args.stage, args.transition)
                print(json.dumps(result, sort_keys=True)); return 0 if result["status"] == PASS else (1 if result["status"] == "FAIL" else 2)
            print(json.dumps(summary(ledger), sort_keys=True)); return 0
    except (Rejected, OSError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, Rejected) else "LOCAL_IO_OR_PROCESS_REJECTED"
        print(json.dumps({"status": "BLOCKED", "reason": reason})); return 2
    except KeyboardInterrupt:
        print(json.dumps({"status": "NOT_ESTABLISHED", "reason": "PERSON_INTERRUPTED_PARENT"})); return 2


if __name__ == "__main__":
    sys.exit(main())
