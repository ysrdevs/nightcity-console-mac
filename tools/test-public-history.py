#!/usr/bin/env python3
"""Synthetic local Git repositories; never reads remotes or changes the real repo."""
import importlib.util
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("public_history", Path(__file__).with_name("check-public-history.py"))
guard = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = guard
spec.loader.exec_module(guard)
ZERO = "0" * 40


class PublicHistoryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nightcity-public-history-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "ysrdevs")
        self.git("config", "user.email", "singh.yuvraj31@icloud.com")
        self.git("config", "commit.gpgsign", "false")
        self.write("README.md", "public baseline\n")
        self.write("native25/patches/ArchiveXL/old.patch", "already public\n")
        self.baseline = self.commit()
        self.git("branch", "-M", "public")

    def git(self, *args, input=None):
        result = subprocess.run(["git", "-C", str(self.repo), *args], input=input,
                                capture_output=True, text=True, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", "Changes")
        return self.git("rev-parse", "HEAD")

    def updates(self, oid=None, remote_ref="refs/heads/main", remote_oid=ZERO):
        oid = oid or self.git("rev-parse", "HEAD")
        return guard.parse_updates(f"refs/heads/public {oid} {remote_ref} {remote_oid}\n")

    def check(self, updates=None, remote=guard.PUBLIC_URL, baseline=None):
        return guard.check_updates(self.repo, remote, updates if updates is not None else self.updates(), baseline or self.baseline)

    def test_public_ancestry_and_unchanged_old_patch_are_grandfathered(self):
        self.assertEqual(self.check(), 0)
        self.write("README.md", "safe release\n"); self.commit()
        self.assertEqual(self.check(), 1)

    def test_clean_snapshot_deletes_published_source_and_keeps_optional_mit(self):
        (self.repo / "native25/patches/ArchiveXL/old.patch").unlink()
        self.write("native25/optional-mods/source/equipment-ex/core.reds", "optional MIT source\n")
        self.commit()
        self.assertEqual(self.check(), 1)

    def test_each_forbidden_path_is_blocked(self):
        paths = ["development/codeware25/private.cpp", "native25/patches/Codeware/new.patch",
                 "native25/scripts/Codeware/Codeware.reds", *sorted(guard.FORBIDDEN_FILES)]
        for path in paths:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.baseline)
                self.write(path, "unpublished source\n"); self.commit()
                with self.assertRaises(guard.Rejected): self.check()

    def test_deletion_in_later_commit_does_not_hide_private_history(self):
        self.write("development/private.cpp", "private\n"); self.commit()
        (self.repo / "development/private.cpp").unlink(); self.commit()
        with self.assertRaisesRegex(guard.Rejected, "later deletion"): self.check()

    def test_modified_public_patch_then_reverted_still_blocks(self):
        self.write("native25/patches/ArchiveXL/old.patch", "private change\n"); self.commit()
        self.write("native25/patches/ArchiveXL/old.patch", "already public\n"); self.commit()
        with self.assertRaises(guard.Rejected): self.check()

    def test_merged_private_ancestor_blocks_even_when_merge_tree_is_clean(self):
        self.git("checkout", "-q", "-b", "private")
        self.write("development/private.cpp", "private\n"); self.commit()
        (self.repo / "development/private.cpp").unlink(); self.commit()
        self.git("checkout", "-q", "public")
        self.write("safe.txt", "public\n"); self.commit()
        self.git("merge", "--no-ff", "private", "-m", "Changes")
        self.assertFalse((self.repo / "development/private.cpp").exists())
        with self.assertRaises(guard.Rejected): self.check()

    def test_annotated_private_tag_in_batch_blocks_safe_branch(self):
        self.write("development/private.cpp", "private\n"); private = self.commit()
        self.git("tag", "-a", "checkpoint/private", "-m", "Changes", private)
        tag = self.git("rev-parse", "refs/tags/checkpoint/private")
        updates = self.updates(self.baseline) + self.updates(tag, "refs/tags/checkpoint/private")
        with self.assertRaises(guard.Rejected): self.check(updates)

    def test_annotated_and_lightweight_public_tags_are_allowed(self):
        self.write("safe.txt", "public\n"); commit = self.commit()
        self.git("tag", "-a", "v1.7.0", "-m", "Changes", commit)
        self.assertEqual(self.check(self.updates(self.git("rev-parse", "v1.7.0"), "refs/tags/v1.7.0")), 1)
        self.assertEqual(self.check(self.updates(commit, "refs/tags/lightweight")), 1)

    def test_all_branch_batch_is_checked_and_remote_tip_is_not_trusted(self):
        self.write("development/private.cpp", "private\n"); private = self.commit()
        updates = self.updates(self.baseline) + self.updates(private, "refs/heads/private", private)
        with self.assertRaises(guard.Rejected): self.check(updates)

    def test_delete_is_allowed_without_baseline_objects(self):
        updates = guard.parse_updates(f"(delete) {ZERO} refs/tags/private {'a' * 40}\n")
        self.assertEqual(self.check(updates, baseline="b" * 40), 0)

    def test_first_parent_must_continue_public_baseline(self):
        tree = self.git("rev-parse", self.baseline + "^{tree}")
        unrelated = self.git("commit-tree", tree, input="Changes\n\nSynthetic unrelated root.\n")
        disguised = self.git("commit-tree", tree, "-p", unrelated, "-p", self.baseline, input="Changes\n")
        with self.assertRaisesRegex(guard.Rejected, "first-parent"): self.check(self.updates(disguised))

    def test_noncommit_object_and_unknown_destination_ref_block(self):
        blob = self.git("hash-object", "-w", "--stdin", input="private blob")
        with self.assertRaises(guard.Rejected): self.check(self.updates(blob, "refs/tags/blob"))
        with self.assertRaises(guard.Rejected): self.check(self.updates(self.baseline, "refs/notes/private"))

    def test_remote_urls_are_exact_and_unknown_credentials_are_not_echoed(self):
        for url in (guard.PUBLIC_URL, "git@github.com:ysrdevs/nightcity-console-mac.git",
                    "ssh://git@github.com/ysrdevs/nightcity-console-mac", "https://github.com/ysrdevs/nightcity-console-mac/"):
            self.assertEqual(self.check(remote=url), 0)
        for url in ("https://secret-token@github.com/other/public.git", "/tmp/new-remote.git",
                    "https://github.com.attacker.test/ysrdevs/nightcity-console-mac.git"):
            with self.assertRaises(guard.Rejected) as error: self.check(remote=url)
            self.assertNotIn("secret-token", str(error.exception))

    def test_missing_baseline_and_replacements_block(self):
        with self.assertRaises(guard.Rejected): self.check(baseline="b" * 40)
        self.write("safe.txt", "public\n"); tip = self.commit()
        self.git("replace", self.baseline, tip)
        with self.assertRaisesRegex(guard.Rejected, "Replacement"): self.check()

    def test_shallow_and_grafted_history_block(self):
        shallow = self.repo / ".git/shallow"
        shallow.write_text(self.baseline + "\n")
        with self.assertRaisesRegex(guard.Rejected, "Shallow"): self.check()
        shallow.unlink()
        grafts = self.repo / ".git/info/grafts"
        grafts.write_text(self.baseline + "\n")
        with self.assertRaisesRegex(guard.Rejected, "grafts"): self.check()

    def test_persistent_hook_reads_sibling_checker_without_checkout_source(self):
        hooks = Path(self.temp.name) / "persistent-hooks"
        hooks.mkdir()
        entry = hooks / "pre-push"
        shutil.copy2(Path(__file__).resolve().parent.parent / ".githooks/pre-push", entry)
        entry.chmod(0o755)
        checker = hooks / "check-public-history.py"
        # Only this synthetic copy gets a fixture baseline. The production CLI has no override.
        checker.write_text(Path(spec.origin).read_text().replace(
            f'BASELINE = "{guard.BASELINE}"', f'BASELINE = "{self.baseline}"', 1))
        self.write("development/private.cpp", "private\n"); private = self.commit()
        self.git("checkout", "--detach", self.baseline)
        def invoke(oid):
            line = f"refs/heads/public {oid} refs/heads/main {ZERO}\n"
            return subprocess.run([str(entry), "origin", guard.PUBLIC_URL], cwd=self.repo,
                                  input=line, capture_output=True, text=True)
        self.assertEqual(invoke(self.baseline).returncode, 0)
        self.assertEqual(invoke(private).returncode, 1)
        checker.unlink()
        failed = invoke(self.baseline)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("checker is missing", failed.stderr)

    def test_pre_push_parser_rejects_invalid_and_duplicate_records(self):
        for text in ("bad\n", f"main invalid refs/heads/main {ZERO}\n", "\n",
                     f"main {ZERO} main {ZERO}\n", f"main {ZERO} refs/heads/main {ZERO}\n" * 2):
            with self.assertRaises(guard.Rejected): guard.parse_updates(text)
        self.assertEqual(guard.parse_updates(""), [])

    def test_checker_uses_outgoing_oid_not_checked_out_branch(self):
        self.write("development/private.cpp", "private\n"); private = self.commit()
        self.git("checkout", "--detach", self.baseline)
        with self.assertRaises(guard.Rejected): self.check(self.updates(private, "refs/heads/private"))
        self.assertEqual(self.check(), 0)


if __name__ == "__main__":
    unittest.main()
