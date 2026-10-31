#!/usr/bin/env python3
"""Inspect selected public OneClip history and an optional fixed ZIP without extraction.

Only the approved public repository origin is accepted. Tips must come from a
separate current public-ref inventory; local private branches, reflogs and the
old development repository are not traversed. No network, fetch, hooks, app or
build is invoked. Findings contain classifications/locations, never matched values.
This heuristic audit does not prove binary privacy or inventory remote surfaces.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "oneclip_publication_rules", Path(__file__).with_name("prepare_public_snapshot.py"))
publication = importlib.util.module_from_spec(SPEC)
previous_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    SPEC.loader.exec_module(publication)
finally:
    sys.dont_write_bytecode = previous_bytecode

PUBLIC_ORIGINS = {
    "https://github.com/TaigaShinohara/OneClip", "https://github.com/TaigaShinohara/OneClip.git",
    "git@github.com:TaigaShinohara/OneClip.git", "ssh://git@github.com/TaigaShinohara/OneClip.git",
}
APPROVED_NAMES = {"TaigaShinohara", "GitHub", "github-actions[bot]"}
MANIFEST_ALGORITHM = "oneclip-bundle-manifest-sha256-v1"
MAX_BLOB = 16 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
MAX_OBJECTS = 20_000
MAX_ARCHIVE_FILE = 64 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")


class AuditFailure(Exception):
    """Fixed classifications only."""


def git(repo, *arguments, missing_ok=False):
    try:
        result = subprocess.run(
            ["/usr/bin/git", "--no-replace-objects", "-C", str(repo), *arguments],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, check=False, shell=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                 "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                 "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1"},
        )
    except subprocess.TimeoutExpired:
        raise AuditFailure("git_timeout") from None
    except (OSError, subprocess.SubprocessError):
        raise AuditFailure("git_unavailable") from None
    if result.returncode == 1 and missing_ok:
        return b""
    if result.returncode != 0:
        raise AuditFailure("git_rejected_or_public_object_missing")
    if len(result.stdout) > MAX_TOTAL:
        raise AuditFailure("git_output_limit")
    return result.stdout


def content_categories(content, document=False):
    # Binary input is also scanned for recognizable ASCII/UTF-8 patterns, but a
    # zero result is not a semantic review of Mach-O/plist/other binary formats.
    text = content.decode("utf-8", errors="replace")
    patterns = publication.PRIVATE_PATTERNS + (publication.DOCUMENT_PATTERNS if document else ())
    return {(category, text.count("\n", 0, match.start()) + 1)
            for category, pattern in patterns for match in pattern.finditer(text)}


def safe_location(path):
    # Filenames themselves can contain a value. Never repeat such a filename.
    if content_categories(str(path).encode("utf-8", errors="replace")):
        return "redacted-path"
    return str(path)


def path_categories(path):
    pure = PurePosixPath(path)
    parts = pure.parts
    categories = set()
    if (not parts or pure.is_absolute() or ".." in parts or "\\" in path or "//" in path
            or "." in path.split("/") or re.match(r"^[A-Za-z]:", path)
            or "\0" in path or any(ord(character) < 32 for character in path)):
        categories.add("unsafe_path")
    if (any(part in publication.FORBIDDEN_COMPONENTS | {".codex", ".agents"} for part in parts)
            or any(part == ".env" or part.startswith(".env.") and part != ".env.example" for part in parts)
            or pure.suffix.lower() in publication.FORBIDDEN_SUFFIXES or path.endswith(".local.json")):
        categories.add("local_or_sensitive_file")
    if content_categories(path.encode("utf-8", errors="replace")):
        categories.add("sensitive_path_name")
    return categories


def audit_repository(repo, tips, approved_names=None):
    repo = Path(repo).resolve(strict=True)
    origin = git(repo, "config", "--get", "remote.origin.url").decode("utf-8").strip()
    if origin not in PUBLIC_ORIGINS:
        raise AuditFailure("approved_public_origin_required")
    if not tips or len(tips) > 100 or any(not SHA.fullmatch(tip) for tip in tips):
        raise AuditFailure("explicit_public_commit_tips_required")
    if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise AuditFailure("shallow_history_incomplete")
    if (git(repo, "config", "--local", "--get", "extensions.partialclone", missing_ok=True)
            or git(repo, "config", "--local", "--get", "remote.origin.promisor", missing_ok=True)):
        raise AuditFailure("partial_history_or_lazy_fetch_unsupported")
    for name, failure in (("info/grafts", "grafted_history_unsupported"),
                          ("objects/info/alternates", "alternate_object_store_unsupported")):
        location = Path(git(repo, "rev-parse", "--git-path", name).decode("utf-8").strip())
        if not location.is_absolute():
            location = repo / location
        if location.exists():
            raise AuditFailure(failure)
    commits = git(repo, "rev-list", "--topo-order", "--reverse", *sorted(set(tips))).decode().splitlines()
    if len(commits) > MAX_OBJECTS or any(not SHA.fullmatch(commit) for commit in commits):
        raise AuditFailure("history_limit_or_invalid_object")
    findings, seen, blobs, build_surfaces = [], set(), set(), []
    total_bytes, entries, binary_blobs = 0, 0, 0
    names = set(approved_names) if approved_names is not None else APPROVED_NAMES

    def finding(category, commit, location, line=None):
        key = (category, commit, location, line)
        if key not in seen:
            seen.add(key)
            item = {"category": category, "commit": commit, "location": safe_location(location)}
            if line is not None:
                item["line"] = line
            findings.append(item)

    for commit in commits:
        metadata = git(repo, "cat-file", "commit", commit)
        header, _, message = metadata.partition(b"\n\n")
        for role in ("author", "committer"):
            records = [line for line in header.splitlines() if line.startswith((role + " ").encode())]
            match = re.fullmatch(rb"\w+ (.+) <([^<>]+)> \d+ [+-]\d{4}", records[0]) if len(records) == 1 else None
            if not match:
                finding("author_metadata_invalid", commit, role)
                continue
            name, email = (part.decode("utf-8", errors="replace") for part in match.groups())
            if name not in names:
                finding("unapproved_public_author_name", commit, role)
            if not re.fullmatch(r"[A-Za-z0-9+_.-]+@users\.noreply\.github\.com|noreply@github\.com", email):
                finding("non_noreply_author_email", commit, role)
            for category, line in content_categories(records[0]):
                finding(category, commit, role, line)
        for category, line in content_categories(message, document=True):
            finding(category, commit, "commit_message", line)
        tree = git(repo, "ls-tree", "-rz", "--full-tree", commit)
        for entry in tree.split(b"\0"):
            if not entry:
                continue
            entries += 1
            metadata, raw_path = entry.split(b"\t", 1)
            mode, object_type, oid = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8", errors="replace")
            if commit in tips and (path.startswith(".github/workflows/")
                    or PurePosixPath(path).name in {"Package.swift", "Package.resolved", ".gitmodules", "Podfile", "Cartfile"}
                    or path.endswith((".lock", ".entitlements", ".pbxproj"))):
                build_surfaces.append({"commit": commit, "location": safe_location(path)})
            for category in path_categories(path):
                finding(category, commit, path)
            if mode not in {"100644", "100755"} or object_type != "blob":
                finding("symlink_or_submodule_requires_review", commit, path)
                continue
            key = (oid, PurePosixPath(path).suffix.lower() == ".md")
            if key in blobs:
                continue
            blobs.add(key)
            if len(blobs) > MAX_OBJECTS:
                raise AuditFailure("object_limit")
            size = int(git(repo, "cat-file", "-s", oid))
            total_bytes += size
            if size > MAX_BLOB or total_bytes > MAX_TOTAL:
                raise AuditFailure("history_content_limit")
            content = git(repo, "cat-file", "blob", oid)
            if path.endswith(".pbxproj") and b"PBXShellScriptBuildPhase" in content:
                finding("build_script_phase_requires_review", commit, path)
            if path.endswith(".pbxproj") and (b"XCRemoteSwiftPackageReference" in content
                                              or b"XCSwiftPackageProductDependency" in content):
                finding("external_package_reference_requires_review", commit, path)
            try:
                content.decode("utf-8")
            except UnicodeError:
                binary_blobs += 1
            for category, line in content_categories(content, document=key[1]):
                finding(category, commit, path, line)
    return {"public_origin_verified": True, "public_tips": sorted(set(tips)),
            "commits_reviewed": len(commits), "tree_entries_reviewed": entries,
            "unique_blob_contexts_reviewed": len(blobs), "binary_blob_contexts": binary_blobs,
            "selected_tip_build_surfaces": build_surfaces,
            "findings": findings}


def audit_zip(path, expected_sha256, expected_manifest):
    if not SHA256.fullmatch(expected_sha256 or "") or not SHA256.fullmatch(expected_manifest or ""):
        raise AuditFailure("explicit_archive_and_app_hashes_required")
    archive_hash = hashlib.sha256()
    with Path(path).open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            archive_hash.update(chunk)
    if archive_hash.hexdigest() != expected_sha256:
        raise AuditFailure("archive_hash_mismatch")
    findings, entries, roots = [], {}, set()
    total = 0
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if not members or len(members) > MAX_OBJECTS:
            raise AuditFailure("archive_member_limit")
        for member in members:
            name = member.filename[:-1] if member.filename.endswith("/") else member.filename
            categories = path_categories(name)
            if member.orig_filename != member.filename:
                categories.add("unsafe_path")
            if categories:
                for category in sorted(categories):
                    findings.append({"category": category, "location": safe_location(name)})
            if "unsafe_path" in categories:
                raise AuditFailure("unsafe_archive_path")
            if name in entries:
                raise AuditFailure("duplicate_archive_path")
            if member.flag_bits & 1 or member.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                raise AuditFailure("archive_encoding_unsupported")
            mode = member.external_attr >> 16
            if stat.S_IFMT(mode) not in {stat.S_IFREG, stat.S_IFDIR}:
                raise AuditFailure("archive_type_or_permissions_unsupported")
            if member.is_dir() != stat.S_ISDIR(mode):
                raise AuditFailure("archive_type_mismatch")
            total += member.file_size
            if member.file_size > MAX_ARCHIVE_FILE or total > MAX_TOTAL:
                raise AuditFailure("archive_content_limit")
            if member.file_size > 1024 * 1024 and member.file_size > max(1, member.compress_size) * 200:
                raise AuditFailure("archive_expansion_limit")
            with archive.open(member) as handle:
                content = handle.read(MAX_ARCHIVE_FILE + 1)
            if len(content) != member.file_size or len(content) > MAX_ARCHIVE_FILE:
                raise AuditFailure("archive_size_mismatch")
            for category, line in content_categories(content, document=name.endswith(".md")):
                findings.append({"category": category, "location": safe_location(name), "line": line})
            parts = PurePosixPath(name).parts
            if parts[0] != "__MACOSX":
                roots.add(parts[0])
            entries[name] = (mode, hashlib.sha256(content).digest())
    if len(roots) != 1 or not next(iter(roots)).endswith(".app"):
        raise AuditFailure("single_app_archive_required")
    root = next(iter(roots))
    digest = hashlib.sha256(MANIFEST_ALGORITHM.encode("ascii") + b"\0")
    app_entries = []
    for name, (mode, content_hash) in entries.items():
        if name in {root, "__MACOSX"} or name.startswith("__MACOSX/"):
            continue
        if not name.startswith(root + "/"):
            raise AuditFailure("archive_extra_payload")
        relative = PurePosixPath(name).relative_to(root)
        for ancestor in relative.parents:
            if str(ancestor) == ".":
                continue
            full = root + "/" + str(ancestor)
            if full not in entries or not stat.S_ISDIR(entries[full][0]):
                raise AuditFailure("archive_directory_metadata_missing")
        app_entries.append((relative, mode, content_hash))
    for relative, mode, content_hash in sorted(app_entries):
        encoded = str(relative).encode("utf-8")
        digest.update(struct.pack(">I", len(encoded)) + encoded + struct.pack(">I", stat.S_IMODE(mode)))
        digest.update(b"directory" if stat.S_ISDIR(mode) else b"file")
        if stat.S_ISREG(mode):
            digest.update(content_hash)
    if digest.hexdigest() != expected_manifest:
        raise AuditFailure("archived_app_manifest_mismatch")
    return {"archive_sha256": expected_sha256, "app_manifest_sha256": expected_manifest,
            "app_manifest_algorithm": MANIFEST_ALGORITHM, "members_reviewed": len(entries),
            "archive_and_app_binding_verified": True, "findings": findings}


def audit(repo, tips, *, candidate_zip=None, expected_zip_sha256=None, expected_app_manifest=None,
          approved_names=None):
    report = {"schema": "oneclip-public-security-surface-v1", "status": "failed",
              "remote_surfaces_inventory_complete": False,
              "limitations": ["heuristic_content_scan", "binary_semantics_not_proven",
                              "remote_inventory_separate", "xattrs_excluded_from_app_manifest"]}
    try:
        report["repository"] = audit_repository(repo, tips, approved_names)
        if candidate_zip is not None:
            report["archive"] = audit_zip(candidate_zip, expected_zip_sha256, expected_app_manifest)
        report["status"] = ("findings_require_review" if report["repository"]["findings"]
                            or report.get("archive", {}).get("findings") else "passed_selected_scope")
    except AuditFailure as error:
        report["failure"] = str(error)
    except Exception:
        report["failure"] = "inspection_unavailable_or_invalid"
    return report


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        raise AuditFailure("invalid_arguments")


def main(arguments=None):
    parser = SafeParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--tip", required=True, action="append")
    parser.add_argument("--zip", type=Path)
    parser.add_argument("--expected-zip-sha256")
    parser.add_argument("--expected-app-manifest-sha256")
    parser.add_argument("--approved-author-name", action="append")
    try:
        options = parser.parse_args(arguments)
        result = audit(options.repo, options.tip, candidate_zip=options.zip,
                       expected_zip_sha256=options.expected_zip_sha256,
                       expected_app_manifest=options.expected_app_manifest_sha256,
                       approved_names=options.approved_author_name)
    except AuditFailure:
        result = {"schema": "oneclip-public-security-surface-v1", "status": "failed",
                  "failure": "invalid_arguments"}
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "passed_selected_scope" else 1


if __name__ == "__main__":
    sys.exit(main())
