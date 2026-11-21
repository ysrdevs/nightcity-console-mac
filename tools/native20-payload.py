#!/usr/bin/env python3
"""Verify/copy a prepared native payload or refresh Mach-O hashes after signing.

This accepts explicit release artifacts. It never reads an installed game,
fetches a framework repository, or copies private source/build directories.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import runpy
import shutil
import stat
import tempfile

UPGRADES = runpy.run_path(str(Path(__file__).with_name('native20-upgrade-history.py')))


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def changed_code(path, expected, signing):
    actual = digest(path)
    if actual != expected:
        with path.open('rb') as stream:
            magic = stream.read(4)
        if not signing or magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            raise ValueError('Changed release dependency: ' + str(path.name))
    return actual


def relative(value):
    if not isinstance(value, str) or not value or len(value) > 1024 or '\\' in value or '\0' in value:
        raise ValueError('Invalid native payload path')
    p = PurePosixPath(value)
    if p.is_absolute() or p.as_posix() != value or any(x in ('', '.', '..') for x in value.split('/')):
        raise ValueError('Noncanonical native payload path: ' + value)
    if p.suffix.lower() in {'.cpp', '.hpp', '.h', '.c', '.cc', '.cs', '.swift', '.py', '.patch', '.zip'}:
        raise ValueError('Source or nested archive in native payload: ' + value)
    if any(x.lower() in {'.git', 'fixtures', 'source', 'sources', 'module-data'} for x in p.parts):
        raise ValueError('Development or mutable data in native payload: ' + value)
    if p.name == 'compiled.redscripts':
        raise ValueError('Full game-derived reference cache must not be distributed')
    return p


def inventory(root):
    result = set()
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Native payload must be a real directory')
    for path in root.rglob('*'):
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('Native payload contains a link or nonregular file')
        result.add(path.relative_to(root).as_posix())
    return result


def verify(root, signing=False):
    files = inventory(root)
    manifest_path = root / 'manifest.json'
    if manifest_path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('Native manifest exceeds its bound')
    manifest = json.loads(manifest_path.read_text())
    # Signing changes whole-file identities. Every release must retain the exact
    # published upgrade history, including the compiler outside red4ext/.
    UPGRADES['check_history'](manifest, UPGRADES['load_registry']())
    if manifest.get('schema') != 1 or manifest.get('backend') != 'native2.5' or manifest.get('gameVersion') != '2.5.0':
        raise ValueError('Unsupported native release payload')
    if manifest.get('environment') != {'NCC_RUNTIME_PROFILE': 'native20-release',
            'NIGHTCITY_RUNTIME_PROBE': 'release20', 'NCC_DISABLE_LEGACY_LUA': '1'}:
        raise ValueError('Development runtime identity cannot ship as 2.0')
    entries = manifest.get('files', [])
    bundled = manifest.get('bundleFiles', {})
    if not isinstance(bundled, dict) or len(bundled) > 2048:
        raise ValueError('Invalid native helper inventory')
    if not entries or len(entries) > 2048:
        raise ValueError('Native payload inventory is missing or too large')
    expected = {'manifest.json'}
    for entry in entries:
        rel = relative(entry['path'])
        name = 'payload/' + str(rel)
        if name in expected or entry.get('mode') not in (0o644, 0o755):
            raise ValueError('Duplicate path or invalid mode')
        expected.add(name)
        path = root / name
        wanted = entry.get('sha256')
        if not isinstance(wanted, str) or len(wanted) != 64 or any(c not in '0123456789abcdef' for c in wanted):
            raise ValueError('Invalid native payload digest')
        actual = digest(path)
        if actual != wanted:
            with path.open('rb') as stream:
                magic = stream.read(4)
            # This mode is called only after pre-sign verification by the
            # signing script. Non-code bytes must remain identical throughout.
            if not signing or magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                raise ValueError('Changed native payload: ' + str(rel))
            entry['sha256'] = actual
    for name, wanted in bundled.items():
        relative(name)
        if name == 'manifest.json' or name.startswith('payload/') or name in expected:
            raise ValueError('Invalid native helper path')
        expected.add(name)
        if not isinstance(wanted, str) or len(wanted) != 64 or any(c not in '0123456789abcdef' for c in wanted):
            raise ValueError('Invalid native helper digest')
        path = root / name
        actual = digest(path)
        if actual != wanted:
            with path.open('rb') as stream:
                magic = stream.read(4)
            if not signing or magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                raise ValueError('Changed native helper: ' + name)
            bundled[name] = actual
    if files != expected:
        raise ValueError('Unrecorded/missing native files: ' + str(sorted(files ^ expected)))
    required = {'red4ext/RED4ext.dylib', 'red4ext/NightCityFrontend.dylib',
                'red4ext/plugins/NightCityRuntime/NightCityRuntime.dylib',
                'engine/tools/scc', 'engine/tools/libscc_lib.dylib'}
    if not required.issubset({x['path'] for x in entries}):
        raise ValueError('Native runtime core is incomplete')
    if signing:
        if 'mod-import.json' in bundled:
            config_path = root / 'mod-import.json'
            config = json.loads(config_path.read_text())
            helper = relative(config['helperRelative'])
            if not str(helper).startswith('native20/helpers/'):
                raise ValueError('Native preparation helper must be bundled under native20/helpers')
            config['helperSHA256'] = digest(root.parent / str(helper))
            nctool = config['nctool']
            if nctool['path'] != 'nctool/nctool':
                raise ValueError('Unexpected archive helper path')
            nctool['sha256'] = changed_code(root.parent / nctool['path'], nctool['sha256'], True)
            tool_root = root.parent / 'nctool'
            if inventory(tool_root) != set(nctool['files']):
                raise ValueError('Archive helper inventory changed while signing')
            nctool['files'] = {name: changed_code(tool_root / str(relative(name)), old, True) for name, old in nctool['files'].items()}
            config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + '\n')
            bundled['mod-import.json'] = digest(config_path)
        pending = manifest_path.with_suffix('.pending')
        pending.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        pending.replace(manifest_path)
    return manifest


def verify_tools(root):
    config_path = root / 'mod-import.json'
    if not config_path.exists():
        raise ValueError('Native mod preparation is missing from the release')
    config = json.loads(config_path.read_text())
    helper = relative(config['helperRelative'])
    if config.get('schema') != 1 or not str(helper).startswith('native20/helpers/'):
        raise ValueError('Invalid native preparation helper contract')
    changed_code(root.parent / str(helper), config['helperSHA256'], False)
    nctool = config['nctool']
    if nctool['path'] != 'nctool/nctool':
        raise ValueError('Invalid archive helper contract')
    tool_root = root.parent / 'nctool'
    if inventory(tool_root) != set(nctool['files']):
        raise ValueError('Archive helper inventory differs')
    changed_code(root.parent / nctool['path'], nctool['sha256'], False)
    for name, old in nctool['files'].items():
        changed_code(tool_root / str(relative(name)), old, False)


def stage(source, destination):
    verify(source)
    if destination.exists():
        raise ValueError('Refusing to replace an existing native payload')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.native20-stage-', dir=destination.parent) as temporary:
        copied = Path(temporary) / 'native20'
        shutil.copytree(source, copied)
        verify(copied)
        copied.rename(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--stage', type=Path)
    parser.add_argument('--after-signing', action='store_true')
    args = parser.parse_args()
    if args.stage and args.after_signing:
        parser.error('staging and signing are separate operations')
    if args.stage:
        stage(args.root, args.stage)
    else:
        verify(args.root, signing=args.after_signing)
    print('Native 2.0 payload verified')
