#!/usr/bin/env python3
"""Exercise release inventory, source exclusion and signing refresh in temp files."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('payload', Path(__file__).resolve().parents[1] / 'tools/native20-payload.py')
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.resources = Path(self.temporary.name) / 'Resources'
        self.root = self.resources / 'native20'
        self.root.mkdir(parents=True)
        names = ['red4ext/RED4ext.dylib', 'red4ext/NightCityFrontend.dylib',
                 'red4ext/plugins/NightCityRuntime/NightCityRuntime.dylib',
                 'engine/tools/scc', 'engine/tools/libscc_lib.dylib']
        entries = []
        for name in names:
            path = self.root / 'payload' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\xcf\xfa\xed\xfeoriginal-code')
            entries.append({'path': name, 'sha256': P.digest(path), 'mode': 0o755})
        helper = self.root / 'helpers/NightCityModPrepare'
        helper.parent.mkdir()
        helper.write_bytes(b'\xcf\xfa\xed\xfehelper-code')
        tool = self.resources / 'nctool/nctool'
        tool.parent.mkdir()
        tool.write_bytes(b'\xcf\xfa\xed\xfetool-code')
        data = tool.parent / 'nctool.deps.json'
        data.write_text('{}')
        config = {'schema': 1, 'helperRelative': 'native20/helpers/NightCityModPrepare',
                  'helperSHA256': P.digest(helper), 'nctool': {'path': 'nctool/nctool',
                  'sha256': P.digest(tool), 'files': {'nctool': P.digest(tool), 'nctool.deps.json': P.digest(data)}}}
        (self.root / 'mod-import.json').write_text(json.dumps(config))
        self.manifest = {'schema': 1, 'backend': 'native2.5', 'gameVersion': '2.5.0',
                         'environment': {'NCC_RUNTIME_PROFILE': 'native20-release',
                         'NIGHTCITY_RUNTIME_PROBE': 'release20', 'NCC_DISABLE_LEGACY_LUA': '1'},
                         'files': entries, 'bundleFiles': {'helpers/NightCityModPrepare': P.digest(helper),
                         'mod-import.json': P.digest(self.root / 'mod-import.json')}}
        self.write_manifest()

    def write_manifest(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_complete_payload_and_fresh_stage(self):
        P.verify(self.root)
        P.verify_tools(self.root)
        target = self.resources / 'staged'
        P.stage(self.root, target)
        P.verify(target)
        with self.assertRaises(ValueError): P.stage(self.root, target)

    def test_unrecorded_source_and_corruption_refused(self):
        extra = self.root / 'private.cpp'
        extra.write_text('private source')
        with self.assertRaises(ValueError): P.verify(self.root)
        extra.unlink()
        path = self.root / 'payload' / self.manifest['files'][0]['path']
        path.write_bytes(b'changed')
        with self.assertRaises(ValueError): P.verify(self.root)
        with self.assertRaises(ValueError): P.verify(self.root, signing=True)

    def test_links_and_noncanonical_paths_refused(self):
        extra = self.root / 'link'
        extra.symlink_to(self.root / 'manifest.json')
        with self.assertRaises(ValueError): P.verify(self.root)
        for value in ('../x', '/x', 'payload//x', 'x/../y', 'sources/foo', 'foo.zip', 'compiled.redscripts'):
            with self.subTest(value=value), self.assertRaises(ValueError): P.relative(value)

    def test_signing_refreshes_only_code_and_bound_tool_config(self):
        old = copy.deepcopy(self.manifest)
        for path in (self.root / 'helpers/NightCityModPrepare', self.resources / 'nctool/nctool',
                     self.root / 'payload' / self.manifest['files'][0]['path']):
            with path.open('ab') as stream: stream.write(b'signature')
        with self.assertRaises(ValueError): P.verify(self.root)
        P.verify(self.root, signing=True)
        P.verify(self.root)
        P.verify_tools(self.root)
        updated = json.loads((self.root / 'manifest.json').read_text())
        self.assertNotEqual(updated['bundleFiles']['mod-import.json'], old['bundleFiles']['mod-import.json'])
        self.assertEqual(updated['files'][1], old['files'][1])

    def test_noncode_dependency_changes_cannot_be_refreshed(self):
        (self.resources / 'nctool/nctool.deps.json').write_text('{"changed":true}')
        with self.assertRaises(ValueError): P.verify_tools(self.root)
        with self.assertRaises(ValueError): P.verify(self.root, signing=True)

    def test_development_identity_refused(self):
        self.manifest['environment']['NIGHTCITY_RUNTIME_PROBE'] = 'probe76'
        self.write_manifest()
        with self.assertRaises(ValueError): P.verify(self.root)


if __name__ == '__main__': unittest.main()
