#!/usr/bin/env python3
"""Prevent unpublished native port source history from entering the public repository.

No network access or Git mutations. The production baseline is deliberately pinned
in this file, rather than trusting the remote's reported old tip or checkout files.
Install a copy beside the persistent common-directory pre-push hook; do not point
core.hooksPath at a working tree that an older branch can replace.
"""
import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

BASELINE = "9a37b5f0034b1aa41ee238e7dc4d2cc045b1f2e6"
PUBLIC_URL = "https://github.com/ysrdevs/nightcity-console-mac.git"
FORBIDDEN_DIRS = ("development/", "native25/patches/", "native25/scripts/")
FORBIDDEN_FILES = {
    "native25/sources.lock.json", "tools/build-native25.py",
    "docs/codeware-2.5-development.md", "docs/cyberware-equipment-2.5-development.md",
    "docs/release-1.7.0-handoff.md", "docs/release-1.7.0-testing.md",
}


class Rejected(Exception):
    pass


@dataclass(frozen=True)
class Update:
    local_ref: str
    local_oid: str
    remote_ref: str
    remote_oid: str

    @property
    def deletion(self):
        return set(self.local_oid) == {"0"}


def parse_updates(text):
    updates, seen = [], set()
    for number, line in enumerate(text.splitlines(), 1):
        fields = line.split()
        if len(fields) != 4:
            raise Rejected(f"Malformed pre-push input on line {number}; nothing was approved.")
        local_ref, local_oid, remote_ref, remote_oid = fields
        if any(re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid) is None for oid in (local_oid, remote_oid)):
            raise Rejected(f"Invalid object ID on pre-push line {number}.")
        if remote_ref in seen or not remote_ref.startswith("refs/"):
            raise Rejected(f"Invalid or duplicate destination ref on line {number}.")
        seen.add(remote_ref)
        updates.append(Update(local_ref, local_oid, remote_ref, remote_oid))
    return updates


def recognized_remote(location):
    # Never echo unknown URLs: they can contain embedded credentials.
    try:
        if "://" in location:
            url = urlsplit(location)
            if url.scheme not in ("https", "ssh") or url.hostname != "github.com" or url.query or url.fragment:
                return False
            if url.port not in (None, 443 if url.scheme == "https" else 22):
                return False
            path = url.path
        else:
            match = re.fullmatch(r"(?:[^@/:\s]+@)?github\.com:([^?#\s]+)", location, re.IGNORECASE)
            if not match:
                return False
            path = match.group(1)
        path = path.strip("/").lower()
        if path.endswith(".git"):
            path = path[:-4]
        return path == "ysrdevs/nightcity-console-mac"
    except ValueError:
        return False


def forbidden(path):
    path = path.replace("\\", "/").lower()
    return path in FORBIDDEN_FILES or any(path.startswith(prefix) or path == prefix[:-1] for prefix in FORBIDDEN_DIRS)


class Git:
    def __init__(self, repository):
        self.repository = str(repository)

    def run(self, *args):
        env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1"}
        result = subprocess.run(["git", "--no-replace-objects", "-C", self.repository, *args],
                                capture_output=True, env=env)
        if result.returncode:
            raise Rejected("Cannot inspect local Git history completely; no push approved. " +
                           result.stderr.decode(errors="replace").strip()[:500])
        return result.stdout

    def tree(self, commit):
        files = {}
        for record in self.run("ls-tree", "-r", "-z", commit).split(b"\0"):
            if record:
                metadata, path = record.split(b"\t", 1)
                name = path.decode("utf-8", "surrogateescape")
                if forbidden(name):
                    files[name] = metadata.split()[2].decode("ascii")
        return files


def check_updates(repository, location, updates, baseline=BASELINE):
    if not updates:
        return 0
    if not recognized_remote(location):
        raise Rejected("This destination has no approved publication policy. Only ysrdevs/nightcity-console-mac is configured; review a different destination before pushing.")
    git = Git(repository)
    for update in updates:
        git.run("check-ref-format", update.remote_ref)
        if not update.deletion and not update.remote_ref.startswith(("refs/heads/", "refs/tags/")):
            raise Rejected("Only branch/tag publication and ref deletions are covered by this policy.")
    outgoing = [u for u in updates if not u.deletion]
    if not outgoing:
        return 0
    if git.run("rev-parse", "--is-shallow-repository").strip() != b"false":
        raise Rejected("Shallow history cannot establish the publication boundary; use the complete local repository.")
    if git.run("for-each-ref", "--format=%(refname)", "refs/replace").strip():
        raise Rejected("Replacement refs obscure history; no push approved while they exist.")
    grafts = Path(git.run("rev-parse", "--git-path", "info/grafts").decode().strip())
    if not grafts.is_absolute():
        grafts = Path(repository) / grafts
    if grafts.exists() and grafts.stat().st_size:
        raise Rejected("Git grafts obscure history; no push approved while they exist.")
    if git.run("cat-file", "-t", baseline).strip() != b"commit":
        raise Rejected("The pinned public baseline is not available as a commit.")
    public_commits = set(git.run("rev-list", baseline).decode().splitlines())
    grandfathered = git.tree(baseline)
    inspected = set()
    for update in outgoing:
        # Peel annotated tags; a tag to a blob/tree must fail rather than bypass a commit scan.
        tip = git.run("rev-parse", "--verify", update.local_oid + "^{commit}").decode().strip()
        if tip in public_commits:
            continue
        first_parents = set(git.run("rev-list", "--first-parent", tip).decode().splitlines())
        if baseline not in first_parents:
            raise Rejected(f"{update.remote_ref} does not continue the approved public baseline on its first-parent history. Keep private branches/checkpoints local.")
        # Do not exclude remote_oid: an arbitrary remote tip must not grandfather private history.
        # Traverse ALL parents, so merging then deleting private sources is still rejected.
        commits = git.run("rev-list", "--reverse", "--topo-order", tip, "^" + baseline).decode().splitlines()
        for commit in commits:
            if commit in inspected:
                continue
            for path, oid in git.tree(commit).items():
                if grandfathered.get(path) != oid:
                    raise Rejected(f"{update.remote_ref} would publish private source history: {commit[:12]} contains {path}. A later deletion does not remove its history; publish only the clean release branch.")
            inspected.add(commit)
    return len(inspected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--pre-push", action="store_true", help="read Git's four-column ref updates from stdin")
    parser.add_argument("--ref", action="append", default=[], help="audit a local ref without contacting a remote (repeatable; defaults to HEAD)")
    parser.add_argument("remote_name", nargs="?", default="origin")
    parser.add_argument("remote_url", nargs="?", default=PUBLIC_URL)
    args = parser.parse_args()
    try:
        if args.pre_push:
            if args.ref:
                raise Rejected("Do not combine --pre-push with --ref.")
            updates = parse_updates(sys.stdin.read())
        else:
            updates = []
            git = Git(args.repo)
            for index, ref in enumerate(args.ref or ["HEAD"]):
                oid = git.run("rev-parse", "--verify", "--end-of-options", ref + "^{object}").decode().strip()
                destination = ref if ref.startswith(("refs/heads/", "refs/tags/")) else f"refs/heads/manual-audit-{index + 1}"
                updates.append(Update(ref, oid, destination, "0" * len(oid)))
        count = check_updates(args.repo, args.remote_url, updates)
        print(f"Public-history check passed ({count} newly reachable commits inspected).", file=sys.stderr)
        return 0
    except (Rejected, OSError) as error:
        print("Public-history guard blocked the push: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
