#!/usr/bin/env python3
"""Exercise archive detection without modifying an application or game."""
from pathlib import Path
import runpy
import struct
import tempfile
import unittest
import zipfile

helpers = runpy.run_path(str(Path(__file__).with_name("verify-release-bundle.py")))
verify = helpers["verify_no_nested_zips"]


class NestedArchiveChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, name, empty=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w") as archive:
            if not empty:
                archive.writestr("mod.reds", "module Example\n")
        return path

    def test_optional_zip_rejected(self):
        self.archive("Resources/optional-mods/equipment-ex.zip")
        with self.assertRaisesRegex(ValueError, "nested ZIP"):
            verify(self.root)

    def test_renamed_zip_rejected(self):
        self.archive("Resources/package.bin")
        with self.assertRaisesRegex(ValueError, "nested ZIP"):
            verify(self.root)

    def test_empty_zip_rejected(self):
        self.archive("empty", empty=True)
        with self.assertRaisesRegex(ValueError, "nested ZIP"):
            verify(self.root)

    def test_prefixed_archive_rejected(self):
        path = self.archive("Resources/embedded.bin")
        path.write_bytes(b"MZ" + bytes(128) + path.read_bytes())
        with self.assertRaisesRegex(ValueError, "nested ZIP"):
            verify(self.root)

    def test_damaged_zip_rejected(self):
        (self.root / "broken.ZIP").write_bytes(b"broken")
        with self.assertRaisesRegex(ValueError, "nested ZIP"):
            verify(self.root)

    def test_non_zip_payloads_remain_allowed(self):
        for name, data in {"EquipmentEx.archive": b"RDAR" + bytes(128),
                           "nctool.dll": b"MZ" + bytes(128),
                           "helper.so": b"\x7fELF" + bytes(128),
                           "LICENSE": b"License notice", "mod.reds": b"module Test\n"}.items():
            (self.root / name).write_bytes(data)
        verify(self.root)

    def test_zip_signature_constants_in_a_library_are_not_an_archive(self):
        # A ZIP library can contain the EOCD signature without an actual ZIP
        # directory. is_zipfile alone accepts this invalid metadata.
        data = b"MZ" + bytes(128) + b"PK\x05\x06" + struct.pack("<4H2IH", 0, 0, 0, 0, 0xffffffff, 0xffffffff, 0)
        path = self.root / "zip-library.dll"
        path.write_bytes(data)
        self.assertTrue(zipfile.is_zipfile(path))
        verify(self.root)


class DeploymentTargetChecks(unittest.TestCase):
    def verify(self, commands):
        helpers["validate_macho_target"](commands, "Resources/plugin.dylib")

    def test_current_sdk_with_supported_minos_passes(self):
        self.verify("Load command 7\n cmd LC_BUILD_VERSION\n cmdsize 32\n platform 1\n minos 15.5\n sdk 27.0\n")

    def test_older_legacy_deployment_command_passes(self):
        self.verify("Load command 4\n cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 11.0\n sdk 14.2\n")

    def test_future_minos_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "requires macOS 27.0"):
            self.verify("Load command 7\n cmd LC_BUILD_VERSION\n platform 1\n minos 27.0\n sdk 27.0\n")

    def test_future_legacy_target_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "requires macOS 26.0"):
            self.verify("Load command 7\n cmd LC_VERSION_MIN_MACOSX\n version 26.0\n sdk 27.0\n")

    def test_other_platform_and_missing_target_are_rejected(self):
        for commands in ("Load command 7\n cmd LC_BUILD_VERSION\n platform 2\n minos 15.0\n sdk 27.0\n",
                         "Load command 7\n cmd LC_BUILD_VERSION\n platform 1\n sdk 27.0\n",
                         "Load command 7\n cmd LC_LOAD_DYLIB\n"):
            with self.subTest(commands=commands), self.assertRaises(ValueError):
                self.verify(commands)

    def test_normalized_target_versions_are_equivalent(self):
        self.verify("Load command 7\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 15.5.0\n sdk 27.0\n")


if __name__ == "__main__":
    unittest.main()
