#!/usr/bin/env python3
"""Exercise exploration packaging with temporary files, without a game or app build."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


payload = module("exploration_payload", "prepare-exploration.py")
bundle = module("release_bundle", "verify-release-bundle.py")


class ExplorationPayloadTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        self.resources = self.root / "Resources"
        self.output = self.resources / "exploration"
        self.source.mkdir()
        self.resources.mkdir()
        for name in payload.SCRIPT_NAMES:
            (self.source / name).write_text("// fixture " + name + "\n")
        self.release_inputs = self.resources / "release-inputs.json"
        self.dependencies = {"schema": 1, "baseline": {"version": "1.5.0", "sha256": "a" * 64},
                             "files": {"native25/RED4ext.dylib": "b" * 64}}
        self.release_inputs.write_text(json.dumps(self.dependencies))

    def stage(self):
        return payload.prepare(self.output, self.source, self.release_inputs)

    def test_stages_only_named_runtime_scripts_and_preserves_dependency_provenance(self):
        (self.source / "private.cpp").write_text("not a runtime script")
        (self.source / "README.md").write_text("not a runtime script")
        self.stage()
        self.assertEqual({p.name for p in self.output.iterdir()}, payload.PAYLOAD_NAMES)
        manifest = payload.verify(self.output, self.source)
        self.assertEqual(set(manifest), {"schema", "game_version", "files"})
        self.assertEqual(manifest["game_version"], "2.5.0")
        released = json.loads(self.release_inputs.read_text())
        recorded = released.pop("exploration")
        self.assertEqual(released, self.dependencies)
        self.assertEqual(recorded, payload.metadata(self.output))
        bundle.verify_exploration(self.resources, "1.8.0", {"exploration": recorded})

    def test_valid_previous_payload_updates_to_new_source(self):
        self.stage()
        source = self.source / payload.SCRIPT_NAMES[0]
        source.write_text("// updated source\n")
        self.stage()
        self.assertEqual((self.output / source.name).read_bytes(), source.read_bytes())
        payload.verify(self.output, self.source)

    def test_missing_or_symlinked_source_preserves_previous_output(self):
        self.stage()
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        source = self.source / payload.SCRIPT_NAMES[0]
        source.unlink()
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, before)
        foreign = self.root / "foreign.reds"
        foreign.write_text("foreign")
        source.symlink_to(foreign)
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(foreign.read_text(), "foreign")

    def test_missing_or_tampered_bundled_script_fails_verification(self):
        self.stage()
        for name in payload.SCRIPT_NAMES:
            path = self.output / name
            original = path.read_bytes()
            path.unlink()
            with self.assertRaises(ValueError):
                payload.verify(self.output)
            path.write_bytes(original + b"// tampered")
            with self.assertRaises(ValueError):
                payload.verify(self.output)
            path.write_bytes(original)

    def test_extra_file_directory_or_symlink_cannot_be_packaged_or_replaced(self):
        self.stage()
        extra = self.output / "private.cpp"
        extra.write_text("preserve me")
        with self.assertRaises(ValueError):
            payload.verify(self.output)
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(extra.read_text(), "preserve me")
        extra.unlink()
        extra.mkdir()
        with self.assertRaises(ValueError):
            payload.verify(self.output)
        extra.rmdir()
        path = self.output / payload.SCRIPT_NAMES[0]
        path.unlink()
        path.symlink_to(self.source / path.name)
        with self.assertRaises(ValueError):
            payload.verify(self.output)

    def test_wrong_version_extra_fields_and_duplicate_keys_are_rejected(self):
        self.stage()
        path = self.output / "manifest.json"
        original = json.loads(path.read_text())
        for changed in ({**original, "game_version": "2.3.1"}, {**original, "schema": True},
                        {**original, "private_source": "anything"}):
            path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                payload.verify(self.output)
        path.write_text('{"schema":1,"schema":1,"game_version":"2.5.0","files":{}}')
        with self.assertRaises(ValueError):
            payload.verify(self.output)

    def test_output_cannot_replace_or_modify_source(self):
        for path in (self.source, self.source / "nested", self.root):
            with self.subTest(path=path), self.assertRaises(ValueError):
                payload.prepare(path, self.source)
        self.assertTrue(all((self.source / n).is_file() for n in payload.SCRIPT_NAMES))

    def test_18_requires_payload_and_source_manifest_but_17_remains_compatible(self):
        bundle.verify_exploration(self.resources, "1.7.1", self.dependencies)
        with self.assertRaises(ValueError):
            bundle.verify_exploration(self.resources, "1.8.0", self.dependencies)
        self.stage()
        recorded = json.loads(self.release_inputs.read_text())
        with self.assertRaises(ValueError):
            bundle.verify_exploration(self.resources, "1.8.0", self.dependencies)
        bundle.verify_exploration(self.resources, "1.8.0", recorded)
        recorded["exploration"]["manifest_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            bundle.verify_exploration(self.resources, "1.8.0", recorded)

    def test_source_check_rejects_stale_assembly_but_immutable_bundle_still_verifies(self):
        self.stage()
        recorded = json.loads(self.release_inputs.read_text())
        previous = bundle.exploration["SOURCE"]
        self.addCleanup(bundle.exploration.__setitem__, "SOURCE", previous)
        bundle.exploration["SOURCE"] = self.source
        bundle.verify_exploration(self.resources, "1.8.0", recorded, check_inputs=True)
        (self.source / payload.SCRIPT_NAMES[0]).write_text("// next development version\n")
        with self.assertRaises(ValueError):
            bundle.verify_exploration(self.resources, "1.8.0", recorded, check_inputs=True)
        bundle.verify_exploration(self.resources, "1.8.0", recorded)


if __name__ == "__main__":
    unittest.main()
