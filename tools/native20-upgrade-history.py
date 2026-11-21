#!/usr/bin/env python3
"""Merge exact published payload identities into native upgrade manifests."""
import argparse
import copy
import json
from pathlib import Path
import re
import tempfile
import os

DEFAULT_REGISTRY = Path(__file__).resolve().parents[1] / 'native25/upgrade-history.json'
DIGEST = re.compile(r'^[0-9a-f]{64}$')

def relative(value):
    return isinstance(value, str) and 0 < len(value) <= 1024 and '\\' not in value and '\0' not in value and all(x not in ('', '.', '..') for x in value.split('/'))

def managed_path(path):
    if not relative(path):
        return False
    if path in {'engine/tools/scc', 'engine/tools/libscc_lib.dylib', 'red4ext/RED4ext.dylib', 'red4ext/NightCityFrontend.dylib', 'red4ext/config.ini', 'red4ext/cet_catalog.tsv', 'red4ext/red4ext_hooks.js', 'red4ext/FridaGadget.dylib', 'red4ext/FridaGadget.config', 'red4ext/libcyberconsole_overlay.dylib', 'red4ext/bin/red4ext_plugin_check'}:
        return True
    if path.startswith('red4ext/bin/x64/') or (path.startswith('r6/scripts/NightCityExploration/') and path.endswith('.reds')):
        return True
    parts = path.split('/')
    return len(parts) >= 4 and parts[:2] == ['red4ext', 'plugins'] and parts[2] in {'NightCityRuntime', 'ArchiveXL', 'TweakXL', 'Codeware', 'input_loader', 'ModSettings'} and parts[-1].lower() not in {'settings.json', 'config.json', 'runtime-status.json'} and not parts[-1].lower().endswith('.log') and 'module-data' not in parts

def valid_digest(value):
    return isinstance(value, str) and DIGEST.fullmatch(value) is not None

def published_files(registry):
    if not isinstance(registry, dict) or registry.get('schema') != 1:
        raise ValueError('Invalid upgrade history schema')
    releases = registry.get('releases')
    if not isinstance(releases, list) or not 1 <= len(releases) <= 64:
        raise ValueError('Missing or oversized published release history')
    result = {}
    versions = set()
    for release in releases:
        version = release.get('version')
        if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version) or version in versions:
            raise ValueError('Invalid or duplicate published release version')
        versions.add(version)
        if release.get('artifact') != 'NightCity-Console-for-Mac.zip' or not valid_digest(release.get('sha256')):
            raise ValueError('Invalid published archive provenance')
        files = release.get('files')
        if not isinstance(files, list) or not 1 <= len(files) <= 2048:
            raise ValueError('Invalid published file inventory')
        seen = set()
        for file in files:
            path, digest, entry = file.get('path'), file.get('sha256'), file.get('archiveEntry')
            if not managed_path(path) or path in seen or not valid_digest(digest):
                raise ValueError('Invalid or duplicate published payload identity')
            if not relative(entry) or not entry.startswith('NightCity Console.app/Contents/Resources/') or '/._' in entry:
                raise ValueError('Invalid published archive entry')
            seen.add(path)
            result.setdefault(path, set()).add(digest)
            if len(result[path]) > 32:
                raise ValueError('Published payload identity bound exceeded: ' + path)
    return result

def load_registry(path=None):
    path = Path(path) if path is not None else DEFAULT_REGISTRY
    if path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('Upgrade history exceeds its bound')
    value = json.loads(path.read_text())
    published_files(value)
    return value

def prior_files(manifest):
    if not isinstance(manifest, dict) or manifest.get('schema') != 1:
        raise ValueError('Invalid native manifest')
    current = set()
    files = manifest.get('files')
    if not isinstance(files, list) or not 1 <= len(files) <= 2048:
        raise ValueError('Invalid native payload inventory')
    for file in files:
        path = file.get('path')
        if not managed_path(path) or path in current or not valid_digest(file.get('sha256')):
            raise ValueError('Invalid native payload identity')
        current.add(path)
    known = {}
    raw_counts = {}
    for key in ('previousFiles', 'retiredFiles'):
        values = manifest.get(key)
        if not isinstance(values, dict) or len(values) > 2048:
            raise ValueError('Invalid prior identity inventory')
        for path, hashes in values.items():
            if not managed_path(path) or not isinstance(hashes, list) or not 1 <= len(hashes) <= 32 or not all(valid_digest(h) for h in hashes):
                raise ValueError('Invalid prior payload identity')
            if key == 'retiredFiles' and path in current:
                raise ValueError('Current payload cannot also be retired')
            raw_counts[path] = raw_counts.get(path, 0) + len(hashes)
            if raw_counts[path] > 32:
                raise ValueError('Prior identity bound exceeded: ' + path)
            known.setdefault(path, set()).update(hashes)
    return current, known

def merge_history(manifest, registry=None):
    registry = load_registry() if registry is None else registry
    current, known = prior_files(manifest)
    for path, hashes in published_files(registry).items():
        known.setdefault(path, set()).update(hashes)
        if len(known[path]) > 32:
            raise ValueError('Combined prior identity bound exceeded: ' + path)
    result = copy.deepcopy(manifest)
    result['previousFiles'] = {p: sorted(h) for p, h in sorted(known.items()) if p in current}
    result['retiredFiles'] = {p: sorted(h) for p, h in sorted(known.items()) if p not in current}
    return result

def check_history(manifest, registry=None):
    expected = merge_history(manifest, registry)
    for key in ('previousFiles', 'retiredFiles'):
        actual = manifest[key]
        for path, hashes in expected[key].items():
            if not set(hashes).issubset(actual.get(path, [])):
                raise ValueError('Missing published upgrade identities: ' + path)
    return True

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--apply', type=Path)
    action.add_argument('--check', type=Path)
    parser.add_argument('--registry', type=Path, default=DEFAULT_REGISTRY)
    args = parser.parse_args()
    path = args.apply or args.check
    if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('Manifest must be a bounded regular file')
    manifest = json.loads(path.read_text())
    registry = load_registry(args.registry)
    if args.check:
        check_history(manifest, registry)
    else:
        result = merge_history(manifest, registry)
        data = json.dumps(result, indent=2, sort_keys=True) + '\n'
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.upgrade-history-', delete=False) as temporary:
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        try:
            temporary_path.chmod(path.stat().st_mode & 0o777)
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)
    print('Published native upgrade history verified: ' + str(path))

if __name__ == '__main__':
    main()
