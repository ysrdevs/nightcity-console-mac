#!/usr/bin/env python3
"""Synthetic plist/command tests. Never invokes hdiutil or accesses a device."""
from pathlib import Path
import os
import plistlib
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

helpers = runpy.run_path(str(Path(__file__).with_name("create-release-dmg.py")))
parse = helpers["parse_attachments"]
plan = helpers["cleanup_device"]
create = helpers["create_dmg"]


def image(path, root="/dev/disk9", mounted=False):
    entities = [{"dev-entry": root}, {"dev-entry": root + "s1"}]
    if mounted:
        entities[-1]["mount-point"] = "/Volumes/Other image"
    return {"image-path": str(path), "system-entities": entities}


def snapshot(*images):
    return plistlib.dumps({"images": list(images)})


class CreationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.output = self.root / "release.dmg"
        self.source = self.root / "stage"
        self.source.mkdir()

    def runner(self, states, failure=None):
        queue, calls = list(states), []

        def run(arguments, timeout):
            calls.append((arguments, timeout))
            if arguments[0] == failure:
                raise RuntimeError("synthetic command failure")
            if arguments == ["info", "-plist"]:
                return queue.pop(0)
            return b""
        return run, calls

    def commands(self, calls):
        return [arguments[0] for arguments, _ in calls]

    def test_no_attachment_needs_no_detach(self):
        run, calls = self.runner([snapshot(), snapshot()])
        create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info", "verify"])
        self.assertEqual(calls[-1][0], ["verify", str(self.output)])
        self.assertTrue(all(0 < timeout <= 600 for _, timeout in calls))

    def test_only_new_exact_unmounted_root_is_detached(self):
        unrelated = image(self.root / "unrelated.dmg", "/dev/disk3", mounted=True)
        run, calls = self.runner([snapshot(unrelated), snapshot(unrelated, image(self.output)),
                                  snapshot(unrelated)])
        create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info", "detach", "info", "verify"])
        self.assertEqual(calls[3], (["detach", "/dev/disk9"], 30))
        self.assertFalse(any("-force" in arguments for arguments, _ in calls))

    def test_unrelated_new_attachment_is_untouched(self):
        run, calls = self.runner([snapshot(), snapshot(image(self.root / "other.dmg", mounted=True))])
        create(self.source, self.output, "Release", run=run)
        self.assertNotIn("detach", self.commands(calls))

    def test_preexisting_output_refuses_before_create_or_overwrite(self):
        for mounted in (False, True):
            with self.subTest(mounted=mounted):
                run, calls = self.runner([snapshot(image(self.output, mounted=mounted))])
                with self.assertRaisesRegex(ValueError, "already attached"):
                    create(self.source, self.output, "Release", run=run)
                self.assertEqual(self.commands(calls), ["info"])

    def test_canonical_alias_is_detected_before_create(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        run, calls = self.runner([snapshot(image(alias / self.output.name))])
        with self.assertRaisesRegex(ValueError, "already attached"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info"])

    def test_mounted_output_is_not_detached(self):
        run, calls = self.runner([snapshot(), snapshot(image(self.output, mounted=True))])
        with self.assertRaisesRegex(ValueError, "mount point"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info"])

    def test_existing_same_file_alias_blocks_overwrite(self):
        self.output.write_bytes(b"synthetic fixture, not a disk image")
        alias = self.root / "another-name.dmg"
        os.link(self.output, alias)
        run, calls = self.runner([snapshot(image(alias))])
        with self.assertRaisesRegex(ValueError, "already attached"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info"])

    def test_same_file_alias_does_not_authorize_detach(self):
        self.output.write_bytes(b"synthetic fixture, not a disk image")
        alias = self.root / "another-name.dmg"
        os.link(self.output, alias)
        run, calls = self.runner([snapshot(), snapshot(image(alias))])
        with self.assertRaisesRegex(ValueError, "unexpected path alias"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info"])

    def test_empty_mount_point_is_not_assumed_unmounted(self):
        entry = image(self.output)
        entry["system-entities"][1]["mount-point"] = ""
        with self.assertRaisesRegex(ValueError, "mount point"):
            plan(parse(snapshot()), parse(snapshot(entry)), self.output)

    def test_duplicate_matching_images_are_ambiguous(self):
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            plan(parse(snapshot()), parse(snapshot(image(self.output), image(self.output, "/dev/disk10"))), self.output)

    def test_missing_multiple_or_duplicate_roots_are_rejected(self):
        for entities in ([{"dev-entry": "/dev/disk9s1"}],
                         [{"dev-entry": "/dev/disk9"}, {"dev-entry": "/dev/disk10"}],
                         [{"dev-entry": "/dev/disk9"}, {"dev-entry": "/dev/disk9"}]):
            with self.subTest(entities=entities), self.assertRaisesRegex(ValueError, "unambiguous root"):
                plan(parse(snapshot()), parse(snapshot({"image-path": str(self.output),
                                                        "system-entities": entities})), self.output)

    def test_other_partition_family_is_rejected(self):
        entry = image(self.output)
        entry["system-entities"].append({"dev-entry": "/dev/disk10s1"})
        with self.assertRaisesRegex(ValueError, "multiple device families"):
            plan(parse(snapshot()), parse(snapshot(entry)), self.output)

    def test_preexisting_device_family_cannot_be_detached(self):
        old = image(self.root / "previous.dmg")
        old["system-entities"] = [{"dev-entry": "/dev/disk9s1"}]
        with self.assertRaisesRegex(ValueError, "existed before"):
            plan(parse(snapshot(old)), parse(snapshot(image(self.output))), self.output)

    def test_device_shared_with_another_image_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "another image"):
            plan(parse(snapshot()), parse(snapshot(image(self.output), image(self.root / "other.dmg"))), self.output)

    def test_create_failure_never_detaches(self):
        run, calls = self.runner([snapshot()], failure="create")
        with self.assertRaisesRegex(RuntimeError, "synthetic"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create"])

    def test_detach_failure_never_forces_or_verifies(self):
        run, calls = self.runner([snapshot(), snapshot(image(self.output))], failure="detach")
        with self.assertRaisesRegex(RuntimeError, "synthetic"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info", "detach"])

    def test_still_attached_after_detach_stops_before_verify(self):
        run, calls = self.runner([snapshot(), snapshot(image(self.output)), snapshot(image(self.output))])
        with self.assertRaisesRegex(ValueError, "remains attached"):
            create(self.source, self.output, "Release", run=run)
        self.assertEqual(self.commands(calls), ["info", "create", "info", "detach", "info"])

    def test_malformed_plist_or_device_stops_without_create(self):
        bad = image(self.output)
        bad["system-entities"][0]["dev-entry"] = "/dev/disk9 -force"
        for state in (b"not a plist", plistlib.dumps({}), snapshot(bad)):
            with self.subTest(state=state):
                run, calls = self.runner([state])
                with self.assertRaises((ValueError, plistlib.InvalidFileException)):
                    create(self.source, self.output, "Release", run=run)
                self.assertEqual(self.commands(calls), ["info"])

    def test_verify_failure_is_fatal(self):
        run, calls = self.runner([snapshot(), snapshot()], failure="verify")
        with self.assertRaisesRegex(RuntimeError, "synthetic"):
            create(self.source, self.output, "Release", run=run)

    def test_subprocess_timeout_is_fatal_and_has_no_retry(self):
        with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("hdiutil", 30)) as mocked:
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                helpers["run_hdiutil"](["detach", "/dev/disk9"], 30)
        mocked.assert_called_once_with(["/usr/bin/hdiutil", "detach", "/dev/disk9"],
                                       check=True, capture_output=True, timeout=30)

    def test_signing_script_calls_guard_before_signing_and_has_no_early_unlink(self):
        script = Path(__file__).with_name("sign-notarize.sh").read_text()
        guard = script.index("python3 tools/create-release-dmg.py")
        signing = script.index('codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"')
        submission = script.index('notarize "$DMG" dmg')
        self.assertLess(guard, signing)
        self.assertLess(signing, submission)
        self.assertNotIn('rm -f "$DMG"', script)


if __name__ == "__main__":
    unittest.main()
