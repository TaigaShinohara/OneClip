#!/usr/bin/env python3
"""Withdrawn render-object diagnostic. Public entry points never launch a child.

The bounded capture/binding helpers remain for fixed-protocol regressions and
historical evidence analysis. They are not an approved live observer.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import tempfile
import time

import prepare_resource_observation as preparation
import render_ownership_receiver as receiver


class RunnerError(ValueError):
    """Fixed failure classifications only; never include OS exception text."""


INPUTS = ("OneClip/M0ImageCore.swift", "OneClip/CaptureSecurityTrace.swift",
          "Tests/M4RenderOwnershipPilot.swift", "scripts/prepare_resource_observation.py",
          "scripts/render_ownership_receiver.py", "scripts/run_render_ownership_pilot.py",
          "scripts/build_render_ownership_tools.sh")
COPIES = {"M0ImageCore.observed.swift": None,
          "CaptureSecurityTrace.swift": "OneClip/CaptureSecurityTrace.swift",
          "M4RenderOwnershipPilot.swift": "Tests/M4RenderOwnershipPilot.swift"}
BINARY = "render-ownership-pilot"
FLAGS = ["-swift-version", "6", "-strict-concurrency=complete", "-O",
         "-whole-module-optimization", "-parse-as-library"]
STDOUT_CAP, STDERR_CAP, DEADLINE = 32_768, 4_096, 15.0


def require(condition, reason):
    if not condition:
        raise RunnerError(reason)


def _regular(path, maximum, *, content=False, executable=False):
    """No symlink or FIFO access; all descriptors close even on interrupted reads."""
    path = Path(path).absolute()
    require(".." not in path.parts, "input_path_invalid")
    parent = preparation._open_directory_path(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(descriptor)
            require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, "input_file_invalid")
            if executable:
                require(before.st_uid == os.getuid() and before.st_mode & 0o111 and
                        not before.st_mode & 0o022 and before.st_nlink == 1, "binary_file_unsafe")
            digest, chunks, total = hashlib.sha256(), [], 0
            while True:
                chunk = os.read(descriptor, min(65_536, maximum + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                require(total <= maximum, "input_file_too_large")
                digest.update(chunk)
                if content:
                    chunks.append(chunk)
            after = os.fstat(descriptor)
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            identity = lambda v: (v.st_dev, v.st_ino, v.st_mode, v.st_size, v.st_mtime_ns, v.st_ctime_ns)
            require(identity(before) == identity(after) == identity(current) and total == before.st_size,
                    "input_changed_during_read")
            return b"".join(chunks) if content else digest.hexdigest()
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def _temp_path(path):
    path = Path(path).absolute()
    require(".." not in path.parts, "temporary_path_invalid")
    lexical = Path(tempfile.gettempdir()).absolute()
    canonical = lexical.resolve(strict=True)
    for root in (canonical, lexical):
        if path != root and path.is_relative_to(root):
            return canonical / path.relative_to(root)
    raise RunnerError("path_outside_os_temp")


def _private_directory(path):
    path = _temp_path(path)
    root = Path(tempfile.gettempdir()).resolve(strict=True)
    descriptor = preparation._open_directory_path(root)
    try:
        for part in path.relative_to(root).parts:
            child = os.open(part, preparation._directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            value = os.fstat(descriptor)
            require(value.st_uid == os.getuid() and not value.st_mode & 0o022,
                    "temporary_parent_unsafe")
        value = os.fstat(descriptor)
        require(value.st_uid == os.getuid() and stat.S_IMODE(value.st_mode) == 0o700,
                "temporary_directory_unsafe")
        result, descriptor = descriptor, None
        return path, result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _save(directory, name, value):
    preparation._write_new(directory, name,
                           (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("ascii"))


def _input_hashes(repo):
    return {name: _regular(repo / name, 2 * 1024 * 1024) for name in INPUTS}


def prepare_build(repo, output, compiler):
    """Builder's source-copy phase only; no compiler or pilot launch here."""
    repo = Path(repo).absolute()
    hashes = _input_hashes(repo)
    compiler_hash = _regular(Path(compiler).resolve(strict=True), 512 * 1024 * 1024)
    binding = preparation.prepare(repo, output)
    require(binding["originalSHA256"] == hashes[preparation.SOURCE], "source_changed_before_copy")
    path, directory = _private_directory(output)
    try:
        for name, original in COPIES.items():
            if original is not None:
                preparation._write_new(directory, name, _regular(repo / original, 2 * 1024 * 1024, content=True))
        os.mkdir("module-cache", 0o700, dir_fd=directory)
        _save(directory, "build-inputs.json", {"inputs": hashes, "compilerSHA256": compiler_hash})
    finally:
        os.close(directory)
    return path


def finish_build(repo, output, compiler):
    """Bind the one completed compilation; never run its executable."""
    repo, output = Path(repo).absolute(), _temp_path(output)
    original = _regular(repo / preparation.SOURCE, preparation.MAX_SOURCE_BYTES, content=True)
    derived, binding = preparation.transform_source(original)
    pending = json.loads(_regular(output / "build-inputs.json", 65_536, content=True))
    hashes = _input_hashes(repo)
    compiler_hash = _regular(Path(compiler).resolve(strict=True), 512 * 1024 * 1024)
    require(pending == {"inputs": hashes, "compilerSHA256": compiler_hash}, "build_inputs_changed")
    copies = {name: _regular(output / name, 2 * 1024 * 1024) for name in COPIES}
    require(copies[preparation.COPY] == hashlib.sha256(derived).hexdigest() and
            all(copies[name] == hashes[source] for name, source in COPIES.items() if source), "build_copy_mismatch")
    require(json.loads(_regular(output / preparation.MANIFEST, 65_536, content=True)) == binding,
            "preparation_binding_mismatch")
    manifest = {"schema": "oneclip-render-ownership-tools-v1", "algorithm": preparation.ALGORITHM,
                "inputs": hashes, "copies": copies, "flags": FLAGS,
                "compilerSHA256": compiler_hash, "binarySHA256": _regular(output / BINARY, 32 * 1024 * 1024, executable=True),
                "preparationSHA256": _regular(output / preparation.MANIFEST, 65_536),
                "buildExecuted": True, "pilotExecuted": False, "resourceAcceptance": False}
    _, directory = _private_directory(output)
    try:
        _save(directory, "manifest.json", manifest)
    finally:
        os.close(directory)
    return manifest


def verify_build(repo, tools):
    repo = Path(repo).absolute()
    tools, descriptor = _private_directory(tools)
    os.close(descriptor)
    manifest_bytes = _regular(tools / "manifest.json", 65_536, content=True)
    manifest = json.loads(manifest_bytes)
    keys = {"schema", "algorithm", "inputs", "copies", "flags", "compilerSHA256", "binarySHA256",
            "preparationSHA256", "buildExecuted", "pilotExecuted", "resourceAcceptance"}
    require(type(manifest) is dict and set(manifest) == keys and
            manifest["schema"] == "oneclip-render-ownership-tools-v1" and
            manifest["algorithm"] == preparation.ALGORITHM and manifest["flags"] == FLAGS and
            manifest["buildExecuted"] is True and manifest["pilotExecuted"] is False and
            manifest["resourceAcceptance"] is False, "build_manifest_invalid")
    hashes = _input_hashes(repo)
    require(manifest["inputs"] == hashes, "source_mismatch")
    derived, binding = preparation.transform_source(_regular(repo / preparation.SOURCE,
                                                             preparation.MAX_SOURCE_BYTES, content=True))
    copies = {name: _regular(tools / name, 2 * 1024 * 1024) for name in COPIES}
    require(manifest["copies"] == copies and copies[preparation.COPY] == hashlib.sha256(derived).hexdigest()
            and all(copies[name] == hashes[source] for name, source in COPIES.items() if source), "derived_source_mismatch")
    require(json.loads(_regular(tools / preparation.MANIFEST, 65_536, content=True)) == binding and
            manifest["preparationSHA256"] == _regular(tools / preparation.MANIFEST, 65_536),
            "preparation_binding_mismatch")
    require(type(manifest["compilerSHA256"]) is str and len(manifest["compilerSHA256"]) == 64 and
            all(c in "0123456789abcdef" for c in manifest["compilerSHA256"]), "compiler_binding_invalid")
    require(manifest["binarySHA256"] == _regular(tools / BINARY, 32 * 1024 * 1024, executable=True),
            "binary_mismatch")
    return tools, manifest, hashlib.sha256(manifest_bytes).hexdigest()


def _stop_owned(process):
    """Bounded direct-handle cleanup, including interrupted/failed wait calls."""
    try:
        if process.poll() is not None:
            process.wait(timeout=0)
            return True
    except BaseException:
        pass
    try:
        process.terminate()
    except BaseException:
        pass
    try:
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


def capture_once(binary, working_directory):
    """Exactly one Popen attempt. Raw bytes remain bounded and in memory only."""
    started, wall = time.monotonic(), time.time()
    process, reason, stderr_bytes = None, None, 0
    data, selector = bytearray(), selectors.DefaultSelector()

    def remaining():
        elapsed, elapsed_wall = time.monotonic() - started, time.time() - wall
        if not all(math.isfinite(v) and v >= 0 for v in (elapsed, elapsed_wall)):
            raise RunnerError("clock_invalid")
        return min(DEADLINE - elapsed, DEADLINE - elapsed_wall)

    try:
        process = subprocess.Popen([str(binary)], cwd=str(working_directory), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
                                   env={"PATH": "/usr/bin:/bin", "TMPDIR": str(working_directory), "LANG": "C"})
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            left = remaining()
            if left <= 0:
                reason = "deadline"; break
            for key, _ in selector.select(min(0.05, left)):
                read_limit = min(4096, STDERR_CAP - stderr_bytes + 1) if key.data == "stderr" else 4096
                chunk = os.read(key.fileobj.fileno(), read_limit)
                if not chunk:
                    selector.unregister(key.fileobj); continue
                if key.data == "stdout":
                    if len(data) + len(chunk) > STDOUT_CAP:
                        reason = "stdout_cap"; break
                    data.extend(chunk)
                else:
                    stderr_bytes += len(chunk)
                    if stderr_bytes > STDERR_CAP:
                        reason = "stderr_cap"; break
            if reason:
                break
        if reason is None:
            left = remaining()
            if left <= 0:
                reason = "deadline"
            else:
                process.wait(timeout=left)
                if remaining() < 0:
                    reason = "deadline"
    except subprocess.TimeoutExpired:
        reason = "deadline"
    except KeyboardInterrupt:
        reason = "parent_interrupted"
    except RunnerError:
        reason = "clock_invalid"
    except BaseException:
        reason = "launch_failed" if process is None else "capture_failed"
    finally:
        cleanup = _stop_owned(process) if process is not None else False
        selector.close()
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
    if not cleanup:
        reason = "cleanup_unknown"
    elif reason is None and stderr_bytes:
        reason = "stderr_present_discarded"
    elapsed, elapsed_wall = time.monotonic() - started, time.time() - wall
    if not all(math.isfinite(v) and v >= 0 for v in (elapsed, elapsed_wall)):
        reason, elapsed, elapsed_wall = "clock_invalid", None, None
    metadata = {"stdoutBytes": len(data), "stderrBytesDiscarded": stderr_bytes,
                "cleanupConfirmed": cleanup, "exit": process.returncode if process is not None else None,
                "elapsedSeconds": elapsed, "elapsedWallSeconds": elapsed_wall, "reason": reason}
    return bytes(data), metadata


def run_pilot(repo, tools, output):
    """Reject before input access, output creation, or process reservation."""
    raise RunnerError("observer_withdrawn")


def _run_bound_trial(repo, tools, output):
    """Regression seam for fake children; never reached by a public entry point."""
    tools, manifest, manifest_hash = verify_build(repo, tools)
    directory = preparation._new_output_directory(output, Path(repo).absolute())
    os.close(directory)
    output = _temp_path(output)
    _, directory = _private_directory(tools)
    try:
        try:
            _save(directory, "launch-claim.json", {"schema": "oneclip-render-launch-claim-v1",
                                                   "binarySHA256": manifest["binarySHA256"],
                                                   "manifestSHA256": manifest_hash, "launchReserved": True})
        except FileExistsError:
            raise RunnerError("launch_already_claimed") from None
    finally:
        os.close(directory)
    data, metadata = capture_once(tools / BINARY, output)
    try:
        _, after, after_hash = verify_build(repo, tools)
        require(after == manifest and after_hash == manifest_hash, "source_mismatch_after_run")
    except (RunnerError, preparation.PreparationError, OSError, ValueError):
        metadata["reason"] = "input_changed"
    report = receiver.receive_to_file(data, metadata, output / "object-receipt.json")
    _, directory = _private_directory(output)
    try:
        _save(directory, "run-binding.json", {"schema": "oneclip-render-run-binding-v1",
              "manifestSHA256": manifest_hash, "binarySHA256": manifest["binarySHA256"],
              "maximumProcesses": 1, "automaticRetry": False, "rawSaved": False,
              "resourceAcceptance": False})
    finally:
        os.close(directory)
    return (0 if report["objectObservation"] == "ESTABLISHED_OBJECT_LIFETIME_ONLY" else 2), report


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        code, report = run_pilot(args.repo, args.tools_dir, args.output_dir)
        print(json.dumps({"objectObservation": report["objectObservation"],
                          "objectReason": report["objectReason"], "resourceAcceptance": False,
                          "rawSaved": False}, sort_keys=True))
        return code
    except (RunnerError, preparation.PreparationError) as error:
        # Both exception classes are constructed only from fixed classifications.
        print(json.dumps({"state": "NOT_ESTABLISHED", "reason": str(error),
                          "childLaunches": 0, "resourceAcceptance": False}))
    except BaseException:
        print('{"state":"NOT_ESTABLISHED","reason":"runner_failed","resourceAcceptance":false}')
    return 2


if __name__ == "__main__":
    sys.exit(main())
