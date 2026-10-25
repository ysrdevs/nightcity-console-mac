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
        for plugin in module.NATIVE25_PLUGINS:
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
        self.write(self.args.native25 / "plugins/Codeware/Scripts/Codeware.Global.reds",
                   b"@addMethod(WardrobeSystem)\npublic native func ForgetItemID(itemID: ItemID) -> Bool\n")
        self.write(self.args.native25 / "plugins/ArchiveXL/Bundle/ArchiveXL.archive", b"bundle")
        self.write(self.args.native25 / "plugins/ArchiveXL/Bundle/Preserved.xl", b"accepted\n")
        for name in ("nctool", "nctool.dll", "nctool.deps.json", "nctool.runtimeconfig.json", "libkraken.dylib"):
            self.write(self.args.nctool / name, b"nctool", executable=name == "nctool")
        self.write(self.args.nctool / "nightcity-mod-compat.json", (module.REPO / "native25/modcompat/nightcity-mod-compat.json").read_bytes())
        accepted = self.root / "accepted-payload.json"
        accepted.write_text(json.dumps({"accepted_checkpoint": "test", "profile": "ui-with-verified-wardrobe",
            "game_version": "2.5.0", "files": {str(p.relative_to(self.args.native25)): module.digest(p)
            for p in self.args.native25.rglob("*") if p.is_file()}}))
        self.addCleanup(setattr, module, "ACCEPTED_PAYLOAD", module.ACCEPTED_PAYLOAD)
        module.ACCEPTED_PAYLOAD = accepted

    def write(self, path, data, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if executable:
            path.chmod(0o755)

    def test_preserves_231_and_promotes_only_supported_native_plugins(self):
        self.write(self.args.native25 / "plugins/CET-Lua/CET-Lua.dylib", b"private")
        self.write(self.args.native25 / "CODEWARE_TEST_BUILD.json", b"private metadata")
        self.write(self.args.native25 / "sources.lock.json", b'{"private_source_commit":"private"}')
        self.write(self.args.native25 / "patches/Codeware/private.patch", b"private native implementation")
        original = module.digest(self.args.baseline)
        module.prepare(self.args)
        self.assertEqual((self.args.output / "RED4ext.dylib").read_bytes(), b"baseline")
        self.assertEqual((self.args.output / "native25/RED4ext.dylib").read_bytes(), b"native loader")
        self.assertTrue((self.args.output / "native25/plugins/Codeware/Codeware.dylib").is_file())
        self.assertFalse((self.args.output / "plugins/Codeware").exists())
        self.assertFalse((self.args.output / "native25/plugins/CET-Lua").exists())
        self.assertFalse((self.args.output / "native25/CODEWARE_TEST_BUILD.json").exists())
        self.assertFalse((self.args.output / "native25/sources.lock.json").exists())
        self.assertFalse((self.args.output / "native25/patches").exists())
        self.assertEqual((self.args.output / "native25/plugins/ArchiveXL/Bundle/Preserved.xl").read_bytes(), b"accepted\n")
        self.assertEqual(module.digest(self.args.baseline), original)
        manifest = json.loads((self.args.output / "release-inputs.json").read_text())
        self.assertEqual(manifest["files"]["nctool/nctool.dll"], module.digest(self.args.nctool / "nctool.dll"))
        self.assertEqual(len([p for p in manifest["files"] if p.startswith("optional-mods/")]), 5)
        module.OPTIONAL["verify"](self.args.output / "optional-mods")

    def test_public_metadata_contains_only_runtime_identity_and_hashes(self):
        module.prepare(self.args)
        native = self.args.output / "native25"
        accepted = json.loads((native / "accepted-payload.json").read_text())
        build = json.loads((native / "BUILD_INFO.json").read_text())
        self.assertEqual(set(accepted), {"schema", "profile", "game_version", "files"})
        self.assertEqual(build["schema"], 3)
        self.assertEqual(build["assembly_mode"], "verified-runtime-inputs")
        self.assertEqual(build["runtime_input_manifest_sha256"], module.digest(native / "accepted-payload.json"))
        for key in ("source_manifest_sha256", "accepted_checkpoint", "repositories", "patches"):
            self.assertNotIn(key, accepted)
            self.assertNotIn(key, build)
        self.assertNotIn("sources.lock.json", build["files"])
        for relative, digest in build["files"].items():
            self.assertEqual(module.digest(native / relative), digest)

    def test_metadata_refresh_preserves_every_runtime_byte(self):
        module.prepare(self.args)
        native = self.args.output / "native25"
        before = {p.relative_to(native).as_posix(): module.digest(p) for p in native.rglob("*")
                  if p.is_file() and p.name not in module.NATIVE_METADATA}
        # The metadata helper can describe already signed bytes without touching
        # them. Input provenance remains the separately accepted input manifest.
        (native / "BUILD_INFO.json").write_text('{"source_manifest_sha256":"old-private-ref"}')
        module.write_native_metadata(native, json.loads(module.ACCEPTED_PAYLOAD.read_text()))
        after = {p.relative_to(native).as_posix(): module.digest(p) for p in native.rglob("*")
                 if p.is_file() and p.name not in module.NATIVE_METADATA}
        self.assertEqual(before, after)
        module.validate_payload(self.args.output)

    def test_private_native_files_and_unlisted_runtime_files_rejected(self):
        module.prepare(self.args)
        for relative in ("native25/sources.lock.json", "native25/plugins/Codeware/implementation.hpp",
                         "native25/patches/SDK/fix.patch", "native25/notes.txt", "nctool/private.cpp"):
            with self.subTest(relative=relative):
                path = self.args.output / relative
                self.write(path, b"private source")
                with self.assertRaises(ValueError):
                    module.validate_payload(self.args.output)
                path.unlink()
                # Empty private recipe directories must not survive validation either.
                while path.parent != self.args.output and not any(path.parent.iterdir()):
                    path = path.parent
                    path.rmdir()

    def test_private_metadata_fields_rejected(self):
        module.prepare(self.args)
        path = self.args.output / "native25/BUILD_INFO.json"
        build = json.loads(path.read_text())
        build["source_manifest_sha256"] = "private-ref"
        path.write_text(json.dumps(build))
        with self.assertRaises(ValueError):
            module.validate_payload(self.args.output)

    def test_native_source_cannot_be_added_to_the_input_allowlist(self):
        path = self.args.native25 / "plugins/Codeware/private.cpp"
        self.write(path, b"private native implementation")
        accepted = json.loads(module.ACCEPTED_PAYLOAD.read_text())
        accepted["files"][str(path.relative_to(self.args.native25))] = module.digest(path)
        module.ACCEPTED_PAYLOAD.write_text(json.dumps(accepted))
        self.assert_failed_prepare_preserves_output()

    def test_source_in_helper_publish_refuses_before_replacing_stage(self):
        self.write(self.args.nctool / "private.cpp", b"private native implementation")
        self.assert_failed_prepare_preserves_output()

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

    def test_modified_codeware_cannot_replace_accepted_candidate(self):
        (self.args.native25 / "plugins/Codeware/Codeware.dylib").write_bytes(b"unaccepted")
        self.assert_failed_prepare_preserves_output()

    def test_missing_wardrobe_declaration_rejected_even_if_input_hash_updated(self):
        p = self.args.native25 / "plugins/Codeware/Scripts/Codeware.Global.reds"
        p.write_text("// missing native binding\n")
        accepted = json.loads(module.ACCEPTED_PAYLOAD.read_text())
        accepted["files"][str(p.relative_to(self.args.native25))] = module.digest(p)
        module.ACCEPTED_PAYLOAD.write_text(json.dumps(accepted))
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
