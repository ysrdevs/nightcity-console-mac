#!/usr/bin/env python3
"""Exercise resource preservation using real archives and disposable output folders."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive_hashes(path):
    # Read the uncompressed index independently of nctool/WolvenKit.
    with path.open('rb') as stream:
        header = stream.read(16)
        assert header[:4] == b'RDAR', header[:4]
        offset = struct.unpack_from('<Q', header, 8)[0]
        stream.seek(offset + 16)
        count, _, _ = struct.unpack('<III', stream.read(12))
        hashes = [struct.unpack_from('<Q', stream.read(56))[0] for _ in range(count)]
    assert len(set(hashes)) == count
    return set(hashes)


def resources(root):
    return {str(path.relative_to(root)): digest(path)
            for path in root.rglob('*') if path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', type=Path, required=True)
    parser.add_argument('--nctool', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True, help='previous signed nctool executable')
    parser.add_argument('--rippers', type=Path, required=True)
    parser.add_argument('--render-archive', type=Path, required=True)
    parser.add_argument('--va-zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    command = [str(args.dotnet), str(args.nctool)]
    inputs = {str(path): digest(path) for path in (args.rippers, args.render_archive, args.va_zip)}
    passed = []
    runs = []

    def run(*argv, success=True, baseline=False):
        process = subprocess.run(([str(args.baseline)] if baseline else command) + list(map(str, argv)),
                                 capture_output=True, text=True)
        number = len(runs)
        (root / f'{number:02d}-{argv[0]}.log').write_text(process.stdout + process.stderr)
        runs.append({'args': list(map(str, argv)), 'returncode': process.returncode, 'baseline': baseline})
        assert (process.returncode == 0) == success, (argv, process.returncode, process.stdout, process.stderr)
        return process.stdout

    run('unpack', args.rippers, root / 'rippers-original')
    run('rawrepack', args.rippers, root / 'rippers-work', root / 'rippers.archive')
    run('unpack', root / 'rippers.archive', root / 'rippers-repacked')
    assert len(archive_hashes(args.rippers)) == 22
    assert archive_hashes(args.rippers) == archive_hashes(root / 'rippers.archive')
    assert resources(root / 'rippers-original') == resources(root / 'rippers-repacked')
    passed.append('Rippers: all 22 original resource hashes and extracted bytes preserved')

    with zipfile.ZipFile(args.va_zip) as package:
        entry = next(name for name in package.namelist() if name.endswith('/VirtualAtelier.archive'))
        (root / 'va-input.archive').write_bytes(package.read(entry))
    run('rawrepack', root / 'va-input.archive', root / 'va-work', root / 'va.archive')
    run('unpack', root / 'va.archive', root / 'va-repacked')
    repo = Path(__file__).resolve().parent.parent
    catalog = json.loads((repo / 'native25/modcompat/nightcity-mod-compat.json').read_text())
    accepted = next(item for item in catalog['verified_repacks'] if item['input_sha256'] == digest(root / 'va-input.archive'))
    assert resources(root / 'va-repacked') == accepted['resources']
    passed.append('VA: all 21 resources still match the accepted native conversion')

    run('rawrepack', args.render_archive, root / 'render-old-work', root / 'render-old.archive', baseline=True)
    output = run('rawrepack', args.render_archive, root / 'render-new-work', root / 'render-new.archive')
    run('unpack', root / 'render-old.archive', root / 'render-old')
    run('unpack', root / 'render-new.archive', root / 'render-new')
    assert archive_hashes(args.render_archive) == archive_hashes(root / 'render-new.archive')
    assert resources(root / 'render-old') == resources(root / 'render-new')
    assert 'still KARK after re-serialize: 0' in output
    passed.append('Render archive: complete hash set and converted bytes match the previous helper')

    run('unpack', args.render_archive, root / 'render-original')
    mesh = next(path for path in sorted((root / 'render-original').rglob('*.mesh')) if b'KARK' in path.read_bytes())
    unknown_hash = 18446744073709500001
    hashed = root / 'hash-mesh'
    hashed.mkdir()
    shutil.copy2(mesh, hashed / f'{unknown_hash}.mesh')
    run('pack', hashed, root / 'hash-input.archive')
    output = run('rawrepack', root / 'hash-input.archive', root / 'hash-work', root / 'hash-output.archive')
    run('unpack', root / 'hash-output.archive', root / 'hash-result')
    assert archive_hashes(root / 'hash-output.archive') == {unknown_hash}
    assert '[RAWREPACK] re-serialized 1 render file(s)' in output
    assert digest(root / 'hash-result' / f'{unknown_hash}.bin') == digest(root / 'render-new' / mesh.relative_to(root / 'render-original'))
    passed.append('Unknown depot mesh: original numeric hash retained and KARK conversion still runs')

    destination = root / 'existing.archive'
    destination.write_bytes(b'previous installed archive')
    existing = digest(destination)
    unsupported = root / 'unsupported'
    unsupported.mkdir()
    (unsupported / 'resource.unknown-extension').write_bytes(b'payload that must not disappear')
    run('pack', unsupported, destination, success=False)
    assert digest(destination) == existing
    passed.append('Skipped file causes failure and preserves existing output')

    duplicate = root / 'duplicate'
    duplicate.mkdir()
    (duplicate / '123.bin').write_bytes(b'first')
    (duplicate / '123.mesh').write_bytes(b'second')
    run('pack', duplicate, destination, success=False)
    assert digest(destination) == existing
    passed.append('Duplicate hashes refuse and preserve existing output')

    broken = root / 'broken-mesh'
    broken.mkdir()
    (broken / 'invalid.mesh').write_bytes(b'This is not a CR2W mesh')
    run('pack', broken, root / 'broken-input.archive')
    run('rawrepack', root / 'broken-input.archive', root / 'broken-work', destination, success=False)
    assert digest(destination) == existing
    passed.append('Unreadable render resource refuses before replacing output')

    run('rawrepack', args.rippers, root / 'rippers-work', destination, success=False)
    assert digest(destination) == existing
    passed.append('Nonempty work directory refuses before mixing stale resources')
    assert not list(root.glob('*.tmp'))
    assert all(digest(Path(path)) == value for path, value in inputs.items())
    passed.append('Original mod inputs unchanged; no failed temporary archives remain')
    (root / 'report.json').write_text(json.dumps({'passed': passed, 'inputs': inputs, 'runs': runs}, indent=2) + '\n')
    for item in passed:
        print('PASS:', item)


if __name__ == '__main__':
    main()
