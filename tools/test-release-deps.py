#!/usr/bin/env python3
"""Isolated release staging checks; creates fixtures only in a temporary directory."""
import importlib.util
import json
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
import zipfile
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release_deps", Path(__file__).with_name("prepare-release-deps.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseInputsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.args = SimpleNamespace(**{name: self.root / name for name in
            ("baseline", "native25", "nctool", "redscript", "archivexl", "config", "output")})
        self.args.config.write_text("[plugins]\nenabled = true\n")
        def zip_input(path, entries):
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
        prefix = "NightCity Console.app/Contents/"
        entries = {prefix + "Info.plist": plistlib.dumps({"CFBundleShortVersionString": "1.5.0"})}
        entries.update({prefix + "Resources/" + name: b"baseline" for name in ("RED4ext.dylib", "FridaGadget.dylib", "config.ini")})
        entries[prefix + "Resources/cyberpunk2077_addresses.json"] = json.dumps({"game_version": "2.3.1"})
        for plugin in module.PLUGINS:
            entries[prefix + f"Resources/plugins/{plugin}/{plugin}.dylib"] = b"baseline-plugin"
            self.write(self.args.native25 / f"plugins/{plugin}/{plugin}.dylib", b"native-plugin")
            self.write(self.args.native25 / f"plugins/{plugin}/Scripts/main.reds", b"native scripts")
        zip_input(self.args.baseline, entries)
        zip_input(self.args.redscript, {"engine/tools/scc": b"scc", "engine/tools/libscc_lib.dylib": b"scc-lib"})
        zip_input(self.args.archivexl, {"red4ext/plugins/ArchiveXL/" + name: b"bundle" for name in
            ("Bundle/ArchiveXL.archive", "LICENSE", "THIRD_PARTY_LICENSES")})
        for constant, name in (("BASELINE_SHA256", "baseline"), ("REDSCRIPT_SHA256", "redscript"), ("ARCHIVEXL_SHA256", "archivexl")):
            previous = getattr(module, constant)
            self.addCleanup(setattr, module, constant, previous)
            setattr(module, constant, module.digest(getattr(self.args, name)))
        self.write(self.args.native25 / "RED4ext.dylib", b"native loader")
        self.write(self.args.native25 / "bin/red4ext_plugin_check", b"helper", executable=True)
        self.write(self.args.native25 / "bin/x64/cyberpunk2077_addresses.json", b'{"game_version":"2.5.0"}')
        for name in ("nctool", "nctool.dll", "nctool.deps.json", "nctool.runtimeconfig.json", "libkraken.dylib"):
            self.write(self.args.nctool / name, b"nctool", executable=name == "nctool")

    def write(self, path, data, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if executable:
            path.chmod(0o755)

    def test_preserves_public_payload_and_excludes_private_plugins(self):
        self.write(self.args.native25 / "plugins/Codeware/Codeware.dylib", b"private")
        original = module.digest(self.args.baseline)
        module.prepare(self.args)
        self.assertEqual((self.args.output / "RED4ext.dylib").read_bytes(), b"baseline")
        self.assertEqual((self.args.output / "native25/RED4ext.dylib").read_bytes(), b"native loader")
        self.assertFalse((self.args.output / "native25/plugins/Codeware").exists())
        self.assertEqual(module.digest(self.args.baseline), original)
        manifest = json.loads((self.args.output / "release-inputs.json").read_text())
        self.assertEqual(manifest["files"]["nctool/nctool.dll"], module.digest(self.args.nctool / "nctool.dll"))

    def assert_failed_prepare_preserves_output(self):
        self.write(self.args.output / "sentinel", b"previous valid stage")
        with self.assertRaises(ValueError):
            module.prepare(self.args)
        self.assertEqual((self.args.output / "sentinel").read_bytes(), b"previous valid stage")

    def test_checksum_mismatch_preserves_previous_stage(self):
        with self.args.baseline.open("ab") as stream:
            stream.write(b"changed")
        self.assert_failed_prepare_preserves_output()

    def test_missing_native_plugin_preserves_previous_stage(self):
        (self.args.native25 / "plugins/TweakXL/TweakXL.dylib").unlink()
        self.assert_failed_prepare_preserves_output()

    def test_stale_address_database_rejected(self):
        (self.args.native25 / "bin/x64/cyberpunk2077_addresses.json").write_text('{"game_version":"2.3.1"}')
        self.assert_failed_prepare_preserves_output()

    def test_missing_nctool_helper_rejected(self):
        (self.args.nctool / "nctool").unlink()
        self.assert_failed_prepare_preserves_output()

    def test_archive_path_traversal_rejected(self):
        archive_path = self.root / "unsafe.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("Bundle/../../escaped", "bad")
        with zipfile.ZipFile(archive_path) as archive, self.assertRaises(ValueError):
            module.extract_prefix(archive, "Bundle/", self.root / "destination")
        self.assertFalse((self.root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()
