#!/usr/bin/env python3
"""Check a public source set or create an isolated repository with fresh history.

Only standard-library modules are used. Findings contain paths/rules, never the
matched credential or personal value. This is a guardrail, not a complete audit.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 2_000_000
EXPORT_DATE = "2000-01-01T00:00:00Z"  # Synthetic date; never reuse private commit dates.
EMAIL = re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
NOREPLY = re.compile(r"(?:[0-9]+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com")
PATTERNS = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----",
    "service token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|hf_[A-Za-z0-9]{25,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})\b",
    "cloud access key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "credential URL": rb"https?://[^\s/@:]+:[^\s/@]+@",
    "credential assignment": rb"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[=:]\s*[\"'][^\"'\n]{8,}[\"']",
    "personal home path": rb"/(?:Users|home)/[A-Za-z0-9_.-]+",
    "local hostname": rb"(?i)(?<![A-Za-z0-9_.-])[a-z0-9][a-z0-9-]{1,62}\.(?:local|lan)\b",
    "device identifier": rb"(?i)(?:serial[_ ]number|hardware[_ ]uuid|IOPlatformUUID|SSID|UDID)\s*[\"']?\s*[:=]",
}
DOC_PATTERNS = {
    "machine-specific hardware": rb"\b(?:M[1-9](?: Pro| Max| Ultra)? Mac|Mac (?:mini|Studio|Pro)|MacBook(?: Air| Pro)?)\b",
    "local validation metadata": rb'"(?:hardware|macos|browser_version|code_directory_hash|executable_sha256|microphone_authorized)"\s*:',
}


def git(root, *args, env=None):
    return subprocess.check_output(["git", "-C", str(root), *args], env=env)


def policy(root):
    return json.loads((root / ".public-source.json").read_text())


def allowed(path, manifest):
    p = PurePosixPath(path)
    if p.is_absolute() or ".." in p.parts or any(part.startswith(".") for part in p.parts):
        return path in manifest["files"]
    return path in manifest["files"] or any(
        path.startswith(tree + "/") and p.suffix in suffixes
        for tree, suffixes in manifest["trees"].items()
    )


def inspect_bytes(path, data):
    issues = []
    if len(data) > MAX_BYTES or b"\0" in data:
        return [f"{path}: binary or oversized file is not public source"]
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return [f"{path}: source must be UTF-8 text"]
    third_party_notice = path.startswith("docs/licenses/")
    patterns = dict(PATTERNS)
    if path.endswith(".md") and not third_party_notice:
        patterns.update(DOC_PATTERNS)
    for number, line in enumerate(data.splitlines(), 1):
        for rule, pattern in patterns.items():
            if re.search(pattern, line):
                issues.append(f"{path}:{number}: {rule}")
        # Preserve copyright holders' attribution details unchanged.
        if not third_party_notice:
            for email in EMAIL.findall(line):
                if not NOREPLY.fullmatch(email.decode()) and email != b"noreply@github.com":
                    issues.append(f"{path}:{number}: personal email address")
    return issues


def inspect_identity(line, require_utc=True):
    match = re.fullmatch(r"(?:author |committer )?(.+) <([^>]+)> [0-9]+ ([+-][0-9]{4})", line)
    if not match:
        return ["unrecognized Git identity metadata"]
    name, email, zone = match.groups()
    account = NOREPLY.fullmatch(email)
    issues = []
    if not ((account and name == account.group(1)) or (name == "GitHub" and email == "noreply@github.com")):
        issues.append("use a public GitHub handle and its noreply email for author and committer")
    if require_utc and zone != "+0000":
        issues.append("local timezone in commit metadata; run commits with TZ=UTC")
    return issues


def candidates(root):
    names = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    # Deleted tracked reports are absent from the proposed working-tree export.
    return sorted({os.fsdecode(p) for p in names.split(b"\0") if p and os.path.lexists(root / os.fsdecode(p))})


def inspect_worktree(root):
    manifest = policy(root)
    names = candidates(root)
    issues = [f"{p}: required public file is missing" for p in manifest["required"] if p not in names]
    for name in names:
        path = root / name
        if not allowed(name, manifest):
            issues.append(f"{name}: outside the public source allowlist")
        elif any(part.is_symlink() for part in (path, *path.parents) if part != root and root in part.parents):
            issues.append(f"{name}: symlinks are not allowed in public source")
        elif not path.is_file():
            issues.append(f"{name}: not a regular source file")
        elif path.stat().st_size > MAX_BYTES:
            issues.append(f"{name}: source exceeds the size limit")
        else:
            issues.extend(inspect_bytes(name, path.read_bytes()))
    return names, issues


def tree_entries(root, revision=None):
    args = ("ls-tree", "-r", "-z", "--full-tree", revision) if revision else ("ls-files", "--stage", "-z")
    for record in git(root, *args).split(b"\0"):
        if not record:
            continue
        header, path = record.split(b"\t", 1)
        fields = header.decode().split()
        mode, oid = (fields[0], fields[2]) if revision else (fields[0], fields[1])
        yield os.fsdecode(path), mode, oid


def inspect_tree(root, entries, manifest, seen):
    issues = []
    for path, mode, oid in entries:
        if not allowed(path, manifest):
            issues.append(f"{path}: outside the public source allowlist")
        elif mode not in {"100644", "100755"}:
            issues.append(f"{path}: symlinks and submodules are not allowed")
        elif (path, oid) not in seen:
            seen.add((path, oid))
            if int(git(root, "cat-file", "-s", oid)) > MAX_BYTES:
                issues.append(f"{path}: source exceeds the size limit")
            else:
                issues.extend(inspect_bytes(path, git(root, "cat-file", "blob", oid)))
    return issues


def inspect_staged(root):
    # Use the committed candidate policy, not an unstaged local relaxation.
    manifest = json.loads(git(root, "show", ":.public-source.json"))
    entries = list(tree_entries(root))
    names = {path for path, _, _ in entries}
    issues = [f"{p}: required staged file is missing" for p in manifest["required"] if p not in names]
    issues.extend(inspect_tree(root, entries, manifest, set()))
    # The post-commit hook rewrites local offsets to +0000; history checks enforce it.
    for identity in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
        issues.extend(inspect_identity(git(root, "var", identity).decode().strip(), require_utc=False))
    return issues


def inspect_history(root):
    manifest, seen, issues = policy(root), set(), []
    for revision in git(root, "rev-list", "--all").decode().splitlines():
        headers, _, message = git(root, "cat-file", "commit", revision).partition(b"\n\n")
        for line in headers.decode().splitlines():
            if line.startswith(("author ", "committer ")):
                issues.extend(f"commit {revision[:12]}: {issue}" for issue in inspect_identity(line))
        issues.extend(inspect_bytes(f"commit-{revision[:12]}.md", message))
        issues.extend(f"{revision[:12]}:{issue}" for issue in inspect_tree(root, tree_entries(root, revision), manifest, seen))
    # Annotated tags can carry private identities/messages even with clean trees.
    for line in git(root, "for-each-ref", "--format=%(objecttype) %(objectname)").decode().splitlines():
        kind, oid = line.split()
        if kind == "tag":
            data = git(root, "cat-file", "tag", oid)
            headers, _, message = data.partition(b"\n\n")
            for header in headers.decode().splitlines():
                if header.startswith("tagger "):
                    issues.extend(f"tag {oid[:12]}: {issue}" for issue in inspect_identity(header[7:]))
            issues.extend(inspect_bytes(f"tag-{oid[:12]}.md", message))
    return issues


def export_source(root, output, author, email):
    match = NOREPLY.fullmatch(email)
    if not match or author != match.group(1):
        raise ValueError("Provide your public GitHub handle and its GitHub noreply email.")
    names, issues = inspect_worktree(root)
    if issues:
        raise ValueError("Source export rejected:\n" + "\n".join(issues))
    output = output.absolute()
    if os.path.lexists(output):
        raise ValueError("Export destination already exists; choose a new empty destination.")
    if root == output or root in output.parents:
        if not git(root, "check-ignore", "--no-index", str(output)).strip():
            raise ValueError("An export inside the source checkout must be Git-ignored.")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".dctt-public-", dir=output.parent))
    try:
        for name in names:
            source, destination = root / name, staging / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
            destination.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
        # Discard inherited Git configuration, identities, dates, hooks and remotes.
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME=author, GIT_AUTHOR_EMAIL=email,
                   GIT_COMMITTER_NAME=author, GIT_COMMITTER_EMAIL=email,
                   GIT_AUTHOR_DATE=EXPORT_DATE, GIT_COMMITTER_DATE=EXPORT_DATE, TZ="UTC")
        git(staging, "init", "--quiet", "--initial-branch=main", "--template=", env=env)
        git(staging, "config", "user.name", author, env=env)
        git(staging, "config", "user.email", email, env=env)
        git(staging, "config", "commit.gpgsign", "false", env=env)
        git(staging, "config", "core.hooksPath", ".githooks", env=env)
        git(staging, "add", "--all", env=env)
        git(staging, "commit", "--quiet", "-m", "Initial public source", env=env)
        issues = inspect_history(staging)
        if issues:
            raise ValueError("Export history rejected:\n" + "\n".join(issues))
        if git(staging, "rev-list", "--count", "--all").strip() != b"1" or git(staging, "remote").strip():
            raise ValueError("Export must have one commit and no remotes.")
        staging.rename(output)
    except BaseException:
        shutil.rmtree(staging)
        raise
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="check proposed files, staged files, or all reachable history")
    mode = check.add_mutually_exclusive_group()
    mode.add_argument("--history", action="store_true")
    mode.add_argument("--staged", action="store_true")
    export = commands.add_parser("export", help="create a separate local repository; never push")
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--author", required=True, help="public GitHub handle")
    export.add_argument("--email", required=True, help="GitHub noreply email")
    args = parser.parse_args()
    try:
        if args.command == "export":
            count = export_source(ROOT, args.output, args.author, args.email)
            print(f"Exported {count} source files with one fresh commit and no remote.")
        else:
            issues = inspect_staged(ROOT) if args.staged else inspect_worktree(ROOT)[1]
            if args.history:
                issues.extend(inspect_history(ROOT))
            if issues:
                print("Public source check failed (matched values withheld):")
                print("\n".join(sorted(set(issues))))
                return 1
            print("Public source checks passed. Manual review is still required.")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Avoid dumping tool output or environment variables with private values.
        print(str(error) if isinstance(error, ValueError) else "Check could not complete; verify Git and file access.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
