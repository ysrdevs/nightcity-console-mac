#!/usr/bin/env python3
"""Exercise archive detection without modifying an application or game."""
from pathlib import Path
import runpy
import struct
import tempfile
import unittest
import zipfile

verify = runpy.run_path(str(Path(__file__).with_name("verify-release-bundle.py")))["verify_no_nested_zips"]


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


if __name__ == "__main__":
    unittest.main()
