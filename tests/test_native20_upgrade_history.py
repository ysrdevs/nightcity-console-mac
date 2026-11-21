import copy
import importlib.util
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/native20-upgrade-history.py'
spec = importlib.util.spec_from_file_location('upgrade_history', TOOL)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)

class UpgradeHistoryTests(unittest.TestCase):
    def setUp(self):
        self.registry = history.load_registry()
        self.manifest = {'schema': 1, 'files': [
            {'path': 'engine/tools/scc', 'sha256': 'a'*64, 'mode': 493},
            {'path': 'engine/tools/libscc_lib.dylib', 'sha256': 'b'*64, 'mode': 493}],
            'previousFiles': {'engine/tools/scc': ['c'*64]},
            'retiredFiles': {'red4ext/red4ext_hooks.js': ['d'*64]},
            'unrelated': {'preserved': True}}

    def test_all_published_versions_and_both_compilers(self):
        self.assertEqual({r['version'] for r in self.registry['releases']}, {'1.6.0','1.6.1','1.7.0','1.7.1','1.8.0','1.8.1','1.9.0'})
        result = history.merge_history(self.manifest, self.registry)
        for release in self.registry['releases']:
            paths = {r['path'] for r in release['files']}
            self.assertTrue({'engine/tools/scc','engine/tools/libscc_lib.dylib'} <= paths)
            for row in release['files']:
                key = 'previousFiles' if row['path'].startswith('engine/tools/') else 'retiredFiles'
                self.assertIn(row['sha256'], result[key][row['path']])
        self.assertTrue(history.check_history(result, self.registry))
        self.assertEqual(result['unrelated'], self.manifest['unrelated'])
        self.assertIn('c'*64, result['previousFiles']['engine/tools/scc'])
        self.assertIn('d'*64, result['retiredFiles']['red4ext/red4ext_hooks.js'])

    def test_deterministic_idempotent_and_nonmutating(self):
        before = copy.deepcopy(self.manifest)
        once = history.merge_history(self.manifest, self.registry)
        self.assertEqual(self.manifest, before)
        self.assertEqual(history.merge_history(once, self.registry), once)
        reversed_registry = copy.deepcopy(self.registry)
        reversed_registry['releases'].reverse()
        for release in reversed_registry['releases']: release['files'].reverse()
        self.assertEqual(history.merge_history(before, reversed_registry), once)

    def test_missing_compiler_identity_refuses_check(self):
        with self.assertRaisesRegex(ValueError, 'Missing published'):
            history.check_history(self.manifest, self.registry)
        merged = history.merge_history(self.manifest, self.registry)
        merged['previousFiles']['engine/tools/libscc_lib.dylib'].pop()
        with self.assertRaisesRegex(ValueError, 'Missing published'):
            history.check_history(merged, self.registry)

    def test_reject_paths_and_bad_provenance(self):
        for path in ['/tmp/file','red4ext/../save','r6/scripts/OtherMod/settings.reds','red4ext/plugins/Codeware/config.json','red4ext/plugins/Codeware/module-data/a','red4ext/plugins/Codeware/test.log']:
            registry = copy.deepcopy(self.registry)
            registry['releases'][0]['files'][0]['path'] = path
            with self.assertRaises(ValueError): history.merge_history(self.manifest, registry)
        registry = copy.deepcopy(self.registry)
        registry['releases'][0]['sha256'] = 'bad'
        with self.assertRaises(ValueError): history.published_files(registry)
        registry = copy.deepcopy(self.registry)
        registry['releases'][0]['files'].append(registry['releases'][0]['files'][0])
        with self.assertRaises(ValueError): history.published_files(registry)

    def test_combined_bound_and_retirement(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['previousFiles']['engine/tools/scc'] = [f'{i:064x}' for i in range(32)]
        with self.assertRaisesRegex(ValueError, 'bound'):
            history.merge_history(manifest, self.registry)
        manifest = copy.deepcopy(self.manifest)
        manifest['retiredFiles']['engine/tools/scc'] = ['e'*64]
        with self.assertRaisesRegex(ValueError, 'retired'):
            history.merge_history(manifest, self.registry)

    def test_cli_atomic_apply_then_check_and_repeat(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'manifest.json'
            path.write_text(json.dumps(self.manifest))
            subprocess.run([sys.executable, str(TOOL), '--apply', str(path)], check=True, capture_output=True)
            first = path.read_bytes()
            subprocess.run([sys.executable, str(TOOL), '--check', str(path)], check=True, capture_output=True)
            subprocess.run([sys.executable, str(TOOL), '--apply', str(path)], check=True, capture_output=True)
            self.assertEqual(path.read_bytes(), first)
            bad = Path(folder)/'bad.json';bad.write_text('{}')
            result = subprocess.run([sys.executable, str(TOOL), '--apply', str(path), '--registry', str(bad)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), first)

if __name__ == '__main__': unittest.main()
