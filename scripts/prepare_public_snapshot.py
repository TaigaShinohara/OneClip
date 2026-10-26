#!/usr/bin/env python3
"""Create a local, history-free publication candidate from a clean Git tree."""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


class PreparationError(Exception):
    pass


# Report categories and locations only; never print matched values.
PRIVATE_PATTERNS = (
    ("personal filesystem path", re.compile(r"/(?:Users|home)/[^/\s]+|/(?:Volumes)/[^\s`\"<>]+")),
    ("internal Notion link", re.compile(r"https?://(?:app\.notion\.com|(?:www\.)?notion\.so)(?:/|\b)", re.I)),
    ("private conversation or Space link", re.compile(r"https?://(?:chatgpt\.com/(?:c|space)|chat\.openai\.com/c)/", re.I)),
    ("internal Page or Space ID", re.compile(r"\b(?:page|space)_[0-9a-f]{32}\b", re.I)),
    ("internal conversation ID", re.compile(r"\b01a[0-9a-f]{5}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)),
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}\b")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("API token", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b")),
    ("credential URL", re.compile(r"https?://[^/\s:@]+:[^/\s@]+@", re.I)),
    ("local authentication reference", re.compile(r"codex" r"-auth|op:" r"//", re.I)),
)
# Public documentation describes product behavior and evidence, not private sessions.
# These bounded heuristics supplement a human review; they are not a privacy proof.
DOCUMENT_PATTERNS = (
    ("personal operational narrative", re.compile(
        r"(?:本人|依頼者)(?:が|は|から)[^\n]{0,240}"
        r"(?:と(?:回答|報告)|(?:入力|操作|認証|確認)した|押した|開けた|通らなかった|失敗した)"
        r"|本人の(?:操作|回答)(?:・|と|の|記録|経緯)"
    )),
    ("private chat activity", re.compile(
        r"(?:他の|ほかの|別の|他)(?:ローカル|local)?チャット[^\n]{0,100}"
        r"(?:active|稼働|実行中|件)", re.I
    )),
    ("private session process", re.compile(
        r"(?:host|guest|ホスト|ゲスト|VM)[^\n]{0,80}\bPID\s*\d+\b", re.I
    )),
    ("personal operational narrative", re.compile(
        r"\b(?:the user|I)\s+(?:said|reported|told me)\b", re.I
    )),
)
FORBIDDEN_COMPONENTS = {".git", ".local", "xcuserdata", "DerivedData", "build", ".build", "__pycache__"}
FORBIDDEN_SUFFIXES = {".p12", ".p8", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".bundle"}


def git_environment():
    # Keep credentials and machine-specific Git config out of this local export.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    return environment


def git(repo, *args, input_data=None):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], input=input_data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=git_environment(),
    )
    if result.returncode:
        # Git errors can echo content supplied by hooks/config; keep errors bounded.
        raise PreparationError(f"Git command failed: {args[0]}")
    return result.stdout


def scan_file(path, content):
    problems = []
    parts = PurePosixPath(path).parts
    if (
        not parts or PurePosixPath(path).is_absolute() or ".." in parts
        or any(part in FORBIDDEN_COMPONENTS for part in parts)
        or any(part == ".env" or part.startswith(".env.") and part != ".env.example" for part in parts)
        or path.endswith(".local.json")
        or PurePosixPath(path).suffix.lower() in FORBIDDEN_SUFFIXES
    ):
        problems.append(f"{path}: excluded local or sensitive file")
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return problems + [f"{path}: binary file requires a separate publication review"]
    patterns = PRIVATE_PATTERNS
    if PurePosixPath(path).suffix.lower() == ".md":
        patterns += DOCUMENT_PATTERNS
    for category, pattern in patterns:
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path}:{line}: {category}")
    return problems


def prepare(source, output):
    source = Path(git(source, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    output = Path(output).resolve()
    if output.exists():
        raise PreparationError("Output already exists; choose a new directory. Nothing was overwritten.")
    if output == source:
        raise PreparationError("Output must be separate from the source repository.")
    if output.is_relative_to(source):
        relative = output.relative_to(source).as_posix()
        ignored = subprocess.run(
            ["git", "-C", str(source), "check-ignore", "--quiet", "--", relative],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=git_environment(),
        )
        if ignored.returncode:
            raise PreparationError("An output inside the source repository must be Git-ignored.")
    if git(source, "status", "--porcelain", "--untracked-files=normal"):
        raise PreparationError("Commit or set aside source changes before preparing a public snapshot.")

    revision = git(source, "rev-parse", "HEAD").decode().strip()
    entries = git(source, "ls-tree", "-rz", "--full-tree", revision).split(b"\0")
    files = []
    problems = []
    for entry in entries:
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        mode, object_type, oid = metadata.decode().split()
        path = path_bytes.decode("utf-8")
        if mode not in {"100644", "100755"} or object_type != "blob":
            problems.append(f"{path}: symlink or submodule requires a separate publication review")
            continue
        content = git(source, "cat-file", "blob", oid)
        problems.extend(scan_file(path, content))
        files.append((path, mode, content))
    if problems:
        raise PreparationError("Publication scan failed:\n" + "\n".join(problems))

    author_name = git(source, "log", "-1", "--format=%an", revision).decode().strip()
    author_email = git(source, "log", "-1", "--format=%ae", revision).decode().strip()
    if not author_email.endswith("@users.noreply.github.com"):
        raise PreparationError("The source commit author must use a GitHub noreply email for the public snapshot.")

    output.mkdir(parents=True)
    for path, mode, content in files:
        target = output / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        target.chmod(0o755 if mode == "100755" else 0o644)

    # Init a new repository; never copy source .git, refs, objects, remotes or hooks.
    git(output, "init", "--quiet", "--initial-branch=main", "--template=")
    git(output, "config", "user.name", author_name)
    git(output, "config", "user.email", author_email)
    git(output, "config", "commit.gpgsign", "false")
    git(output, "-c", "core.hooksPath=/dev/null", "add", "--all")
    git(output, "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Prepare OneClip public source snapshot")
    if git(output, "rev-list", "--count", "--all").strip() != b"1":
        raise PreparationError("Unexpected history in the publication candidate; do not publish it.")
    if git(output, "remote"):
        raise PreparationError("Unexpected remote in the publication candidate; do not publish it.")
    if git(output, "rev-parse", "HEAD^{tree}") != git(source, "rev-parse", f"{revision}^{{tree}}"):
        raise PreparationError("The snapshot tree differs from the reviewed source; do not publish it.")
    public_commit = git(output, "rev-parse", "HEAD").decode().strip()
    print(f"Prepared {len(files)} files in a new local repository.")
    print(f"Source commit: {revision}")
    print(f"Public snapshot commit: {public_commit}")
    print("History: one root commit. Remote: none. No network commands were run.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True, help="New, nonexistent output directory")
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except (PreparationError, OSError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
