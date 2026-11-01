#!/usr/bin/env python3
"""Prepare a test-only render-observer copy in a new OS-temporary directory.

This does not build, run, or change the product. The derived Swift source requires
the separately reviewed M4RenderObjectObservation test helper when compiled.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


class PreparationError(Exception):
    """A fixed, content-free preparation failure."""


ALGORITHM = "oneclip-render-object-observation-v1"
SOURCE = "OneClip/M0ImageCore.swift"
COPY = "M0ImageCore.observed.swift"
MANIFEST = "observation-preparation.json"
MAX_SOURCE_BYTES = 1024 * 1024
ANCHOR = b"            try checked(.beforeEncoding)\n"
INSERTION = b"            M4RenderObjectObservation.record(image)\n"
COMPOSE_START = b"    static func compose(assets: [M0ImageAsset], limits: M0ImageLimits = .init(),\n"
COMPOSE_END = b"\n    static func validateEncodedBytes("
RENDER_PREFIX = (
    b"            let image: CGImage\n"
    b"            if assets.count == 1 {\n"
    b"                image = assets[0].image\n"
    b"            } else {\n"
    b"                image = try render(assets: assets, plan: plan, checkCancellation: checked)\n"
    b"            }\n"
)


def transform_source(original):
    """Accept one exact source boundary; never guess or apply a fallback edit."""
    if not isinstance(original, bytes) or not 0 < len(original) <= MAX_SOURCE_BYTES:
        raise PreparationError("source_size_invalid")
    try:
        original.decode("utf-8")
    except UnicodeError:
        raise PreparationError("source_encoding_invalid") from None
    if b"\0" in original or INSERTION.strip() in original:
        raise PreparationError("source_already_instrumented_or_invalid")
    for token in (COMPOSE_START, COMPOSE_END, RENDER_PREFIX, ANCHOR):
        if original.count(token) != 1:
            raise PreparationError("source_boundary_not_unique")
    begin = original.index(COMPOSE_START)
    end = original.index(COMPOSE_END)
    offset = original.index(ANCHOR)
    render = original.index(RENDER_PREFIX)
    if not begin < render < offset < end or render + len(RENDER_PREFIX) != offset:
        raise PreparationError("source_render_boundary_mismatch")
    transformed = original[:offset] + INSERTION + original[offset:]
    binding = {
        "schema": "oneclip-resource-observation-preparation-v1",
        "algorithm": ALGORITHM,
        "source": SOURCE,
        "copy": COPY,
        "originalSHA256": hashlib.sha256(original).hexdigest(),
        "transformedSHA256": hashlib.sha256(transformed).hexdigest(),
        "delta": {
            "operation": "insert_utf8",
            "byteOffset": offset,
            "insertedUTF8": INSERTION.decode("utf-8"),
            "insertionCount": 1,
            "originalBytes": len(original),
            "transformedBytes": len(transformed),
        },
        "productSourceChanged": False,
        "buildExecuted": False,
        "observationScope": "test_only_render_object_lifetime",
        "resourceAcceptance": False,
    }
    return transformed, binding


def _directory_flags():
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise PreparationError("safe_filesystem_operations_unavailable")
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_directory_path(path):
    """Open every absolute path component without accepting a symlink."""
    descriptor = os.open(path.anchor, _directory_flags())
    try:
        for component in path.parts[1:]:
            child = os.open(component, _directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        result, descriptor = descriptor, None
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _read_source(repo):
    repo = Path(repo).absolute()
    if ".." in repo.parts or repo.is_symlink():
        raise PreparationError("repository_path_invalid")
    # The repository path itself is caller-selected. Its source components are
    # opened relative to directory handles, so a source symlink is never read.
    repo_fd = _open_directory_path(repo)
    try:
        source_dir = os.open("OneClip", _directory_flags(), dir_fd=repo_fd)
        try:
            source_fd = os.open("M0ImageCore.swift", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                dir_fd=source_dir)
            try:
                # O_NONBLOCK prevents a FIFO from hanging before this type check.
                # Keep FD ownership here even if fdopen itself raises.
                before = os.fstat(source_fd)
                if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_SOURCE_BYTES:
                    raise PreparationError("source_file_invalid")
                with os.fdopen(source_fd, "rb", closefd=False) as source_file:
                    original = source_file.read(MAX_SOURCE_BYTES + 1)
                after = os.fstat(source_fd)
            finally:
                os.close(source_fd)
            current = os.stat("M0ImageCore.swift", dir_fd=source_dir, follow_symlinks=False)
            identity = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                                      value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if identity(before) != identity(after) or identity(after) != identity(current):
                raise PreparationError("source_changed_during_read")
            if len(original) != before.st_size:
                raise PreparationError("source_changed_during_read")
            return repo.resolve(strict=True), original
        finally:
            os.close(source_dir)
    finally:
        os.close(repo_fd)


def _new_output_directory(output, repo):
    requested = Path(output).absolute()
    if ".." in requested.parts:
        raise PreparationError("output_path_invalid")
    lexical_temp = Path(tempfile.gettempdir()).absolute()
    temp_root = lexical_temp.resolve(strict=True)
    # Accommodate the OS's /var -> /private/var spelling only at the temp root;
    # never resolve descendant symlinks supplied in an output path.
    relative = None
    for root in (temp_root, lexical_temp):
        if requested != root and requested.is_relative_to(root):
            relative = requested.relative_to(root)
            break
    if relative is None:
        raise PreparationError("output_outside_os_temporary_directory")
    canonical_output = temp_root / relative
    if canonical_output.is_relative_to(repo):
        raise PreparationError("output_inside_repository")
    parent = os.open(temp_root, _directory_flags())
    try:
        for component in relative.parts[:-1]:
            child = os.open(component, _directory_flags(), dir_fd=parent)
            os.close(parent)
            parent = child
            value = os.fstat(parent)
            if value.st_uid != os.getuid() or value.st_mode & 0o022:
                raise PreparationError("output_parent_not_private_directory")
        try:
            os.mkdir(relative.name, 0o700, dir_fd=parent)
        except FileExistsError:
            raise PreparationError("output_already_exists") from None
        output_fd = os.open(relative.name, _directory_flags(), dir_fd=parent)
        value = os.fstat(output_fd)
        entry = os.stat(relative.name, dir_fd=parent, follow_symlinks=False)
        if (value.st_uid != os.getuid() or stat.S_IMODE(value.st_mode) != 0o700
                or (value.st_dev, value.st_ino) != (entry.st_dev, entry.st_ino)):
            os.close(output_fd)
            raise PreparationError("output_directory_identity_invalid")
        return output_fd
    finally:
        os.close(parent)


def _write_new(directory, name, content):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
    with os.fdopen(descriptor, "wb") as output:
        output.write(content)


def prepare(repo, output):
    repo, original = _read_source(repo)
    transformed, binding = transform_source(original)
    directory = _new_output_directory(output, repo)
    try:
        _write_new(directory, COPY, transformed)
        _write_new(directory, MANIFEST,
                   (json.dumps(binding, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    finally:
        os.close(directory)
    return binding


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="New, nonexistent directory under the OS temporary root")
    args = parser.parse_args()
    try:
        binding = prepare(args.repo, args.output_dir)
    except PreparationError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        # OS error text may contain user-selected paths; never echo it.
        print("preparation_io_failed", file=sys.stderr)
        return 1
    print(json.dumps({"status": "PREPARED", "algorithm": binding["algorithm"],
                      "originalSHA256": binding["originalSHA256"],
                      "transformedSHA256": binding["transformedSHA256"],
                      "productSourceChanged": False, "buildExecuted": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
