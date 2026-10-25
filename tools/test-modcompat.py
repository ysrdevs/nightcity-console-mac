#!/usr/bin/env python3
"""Exercise the real nctool CLI against disposable game/mod fixtures only."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', type=Path, required=True)
    parser.add_argument('--nctool', type=Path, required=True)
    parser.add_argument('--cyberware-source', type=Path, required=True)
    parser.add_argument('--equipment-zip', type=Path, required=True)
    parser.add_argument('--va-zip', type=Path, required=True)
    args = parser.parse_args()
    command = [str(args.dotnet), str(args.nctool)]
    passed = []
    def run(*argv, success=True):
        p = subprocess.run(command + list(map(str, argv)), capture_output=True, text=True)
        assert (p.returncode == 0) == success, (p.returncode, p.stdout, p.stderr)
        return p
    def hashes(root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file()}
    with tempfile.TemporaryDirectory(prefix='nightcity-modcompat-') as temp:
        root = Path(temp)
        def game(name, version='2.5.0'):
            path = root / name
            info = path / 'Cyberpunk2077.app/Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
            (path / 'r6/scripts').mkdir(parents=True)
            return path
        def cyberware(path, bundled=False):
            target = path / 'r6/scripts/CyberwareEx'
            target.mkdir(parents=True, exist_ok=True)
            if not bundled:
                shutil.copytree(args.cyberware_source / 'scripts', target, dirs_exist_ok=True)
            else:
                groups = {'CyberwareEx.reds': [], 'CyberwareEx.Global.reds': []}
                for p in sorted((args.cyberware_source / 'scripts').rglob('*.reds')):
                    text = p.read_text()
                    if text.startswith('module CyberwareEx'):
                        groups['CyberwareEx.reds'].append(text.split('\n', 1)[1])
                    else:
                        groups['CyberwareEx.Global.reds'].append(text)
                for name, parts in groups.items():
                    prefix = 'module CyberwareEx\n' if name == 'CyberwareEx.reds' else ''
                    (target / name).write_text(prefix + '\n\n'.join(parts))
            return target
        def equipment(path):
            with zipfile.ZipFile(args.equipment_zip) as archive:
                for entry in archive.infolist():
                    if entry.filename.startswith('r6/scripts/') and not entry.is_dir():
                        destination = path / entry.filename
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(archive.read(entry))

        split = game('split'); target = cyberware(split); equipment(split)
        untouched = target / 'Customization.reds'
        untouched.write_text(untouched.read_text() + '\n// user configuration remains untouched\n')
        unrelated = split / 'r6/scripts/OtherMod.reds'
        unrelated.write_text('module OtherMod\n@wrapMethod(EquipmentSystemPlayerData)\npublic final const func GetActiveItem(area: gamedataEquipmentArea) -> ItemID { return wrappedMethod(area); }\n')
        before = hashes(split); run('compat25', split); after = hashes(split)
        changed = [p for p in before if before[p] != after[p]]
        assert sorted(changed) == ['r6/scripts/CyberwareEx/Overrides/EquipmentSystemPlayerData.reds', 'r6/scripts/EquipmentEx/EquipmentEx.Global.reds'], changed
        assert before[str(untouched.relative_to(split))] == after[str(untouched.relative_to(split))]
        run('compat25', split); assert hashes(split) == after
        passed += ['source layout and Equipment core adaptation', 'unrelated user customization preserved', 'already-adapted idempotence']

        bundled = game('synthetic-bundle'); cyberware(bundled, True)
        run('compat25', bundled); after = hashes(bundled); run('compat25', bundled); assert hashes(bundled) == after
        passed.append('synthetic bundled Cyberware layout; not a downloaded Nexus ZIP')

        edited = game('edited'); target = cyberware(edited); equipment(edited)
        target = target / 'Overrides/EquipmentSystemPlayerData.reds'
        target.write_text(target.read_text().replace('if !IsDefined(owner)', 'if true || !IsDefined(owner)', 1))
        before = hashes(edited); run('compat25', edited, success=False); assert hashes(edited) == before
        passed.append('edited target refuses before any compatibility writes')

        incoming = root / 'unsupported-source'
        shutil.copytree(edited / 'r6', incoming / 'r6')
        empty_game = game('unsupported-install'); before = hashes(empty_game)
        run('install', incoming, empty_game, root / 'unsupported-manifest.json', success=False)
        assert hashes(empty_game) == before and not (root / 'unsupported-manifest.json').exists()
        passed.append('unsupported incoming package refused before deployment or manifest')

        unknown = game('unknown'); target = cyberware(unknown)
        facade = target / 'Facade.reds'; facade.write_text(facade.read_text().replace('"1.5.6"', '"1.5.7"'))
        before = hashes(unknown); run('compat25', unknown, success=False); assert hashes(unknown) == before
        passed.append('unknown mod version preserved and rejected')

        old = game('old', '2.3.1'); cyberware(old); equipment(old)
        before = hashes(old); run('compat25', old); assert hashes(old) == before
        passed.append('2.3.1 unchanged')

        rollback = game('rollback'); cyberware(rollback); equipment(rollback)
        locked = rollback / 'r6/scripts/EquipmentEx'; locked.chmod(0o555)
        before = hashes(rollback)
        try:
            run('compat25', rollback, success=False); assert hashes(rollback) == before
        finally:
            locked.chmod(0o755)
        passed.append('write failure rolls back earlier compatibility writes')

        race = game('changed-after-plan'); target = cyberware(race); equipment(race)
        harness = root / 'race-harness'; harness.mkdir()
        repository = Path(__file__).resolve().parent.parent
        shutil.copy2(repository / 'native25/modcompat/NightCityModCompatibility.cs', harness)
        shutil.copy2(repository / 'native25/modcompat/nightcity-mod-compat.json', harness)
        (harness / 'probe.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup><ItemGroup><None Update="nightcity-mod-compat.json" CopyToOutputDirectory="Always" /></ItemGroup></Project>')
        (harness / 'Program.cs').write_text('using System.Text; var plan = NightCityModCompatibility.Plan(args[0]); var target = plan.Keys.First(); File.AppendAllText(target, "\\n// edit after validation\\n"); var edited = File.ReadAllBytes(target); try { NightCityModCompatibility.Apply(plan); return 1; } catch (IOException) { if (!File.ReadAllBytes(target).SequenceEqual(edited)) return 2; Console.WriteLine("EDIT_PRESERVED:" + target); return 0; }')
        before = hashes(race)
        probe = subprocess.run([str(args.dotnet), 'run', '--project', str(harness / 'probe.csproj'), '--', str(race / 'r6/scripts')], capture_output=True, text=True)
        assert probe.returncode == 0, (probe.stdout, probe.stderr)
        after = hashes(race)
        changed = [p for p in before if before[p] != after[p]]
        assert len(changed) == 1 and (race / changed[0]).read_text().endswith('// edit after validation\n'), changed
        passed.append('edits between Plan and Apply refuse before writes and preserve the edit')

        install = game('install'); source = root / 'source'; source.mkdir()
        with zipfile.ZipFile(args.equipment_zip) as archive:
            archive.extractall(source)
        windows = source / 'red4ext/plugins/Codeware/Scripts/Codeware.Global.reds'
        windows.parent.mkdir(parents=True); windows.write_text('// unrelated Windows dependency payload\n')
        native = install / 'red4ext/plugins/Codeware/Scripts/Codeware.Global.reds'
        native.parent.mkdir(parents=True); native.write_text('// existing native profile\n')
        before = hashes(source)
        run('install', source, install, root / 'manifest.json')
        assert hashes(source) == before
        archive_path = install / 'archive/Mac/mod/EquipmentEx.archive'
        assert hashlib.sha256(archive_path.read_bytes()).hexdigest() == '55a438e9315ca227f12f90aacec0711914bd9241e60307242c204410f45ecf8e'
        assert (install / 'archive/Mac/mod/EquipmentEx.archive.xl').is_file()
        assert native.read_text() == '// existing native profile\n'
        assert 'while i < ArraySize(this.m_clothingVisualsInfo)' in (install / 'r6/scripts/EquipmentEx/EquipmentEx.Global.reds').read_text()
        before = hashes(install); run('compat25', install); assert hashes(install) == before
        passed += ['real Equipment ZIP contents install with original archive and nearby XL', 'source input preserved and installed compatibility idempotent']
        passed.append('bundled Windows dependencies cannot overwrite native profile')

        va_game = game('virtual-atelier')
        installed = run('install', args.va_zip, va_game, root / 'va-manifest.json')
        assert 'verified 21 resources against the tested native archive' in installed.stdout
        va_archive = va_game / 'archive/Mac/mod/VirtualAtelier.archive'
        assert va_archive.is_file()
        assert (va_game / 'archive/Mac/mod/VirtualAtelier.archive.xl').is_file()
        assert not (va_game / 'red4ext/plugins/ArchiveXL/Bundle/VirtualAtelier.archive.xl').exists()
        with zipfile.ZipFile(args.va_zip) as archive:
            originals = {entry.filename: archive.read(entry) for entry in archive.infolist()
                         if entry.filename.startswith('r6/scripts/') and entry.filename.endswith('.reds')}
            assert len(originals) == 46
            assert all((va_game / name).read_bytes() == content for name, content in originals.items())
        before = hashes(va_game); run('compat25', va_game); assert hashes(va_game) == before
        passed += ['real VA 1.6.0 ZIP output resources verified against accepted 21-resource manifest',
                   'VA paired XL in native archive folder and 46 scripts retained byte-for-byte',
                   'optional Equipment imports do not require an installed Equipment core']
    print('\n'.join('PASS: ' + item for item in passed))
    print(f'{len(passed)} isolated compatibility checks passed; no installed game was used.')


if __name__ == '__main__':
    main()
