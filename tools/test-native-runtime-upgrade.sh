#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
UPGRADE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nightcity-upgrade-test.XXXXXX")"
trap 'rm -rf "$UPGRADE_TEST_DIR"' EXIT

# Inventory pins identify files inside actual published ZIPs. Do not substitute
# a rebuilt 1.9 app: final signing changes its compiler/framework identities.
python3 - "$UPGRADE_TEST_DIR" "$@" <<'PY'
import argparse, hashlib, json, pathlib, stat, sys, zipfile
temp = pathlib.Path(sys.argv[1])
p = argparse.ArgumentParser(description='Test actual published legacy runtime migration without launching a game.')
p.add_argument('--inventory', type=pathlib.Path, required=True)
p.add_argument('--legacy-version', default='1.9.0')
p.add_argument('--legacy-archive', type=pathlib.Path)
p.add_argument('--candidate-resources', type=pathlib.Path, required=True)
p.add_argument('--result', type=pathlib.Path, required=True)
a = p.parse_args(sys.argv[2:])
releases = [r for r in json.loads(a.inventory.read_text())['releases'] if r['version'] == a.legacy_version]
if len(releases) != 1:
    raise SystemExit('Inventory must identify exactly one requested legacy release')
release = releases[0]
archive = (a.legacy_archive or pathlib.Path(release['archive'])).resolve(strict=True)
h = hashlib.sha256()
with archive.open('rb') as f:
    for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
if h.hexdigest() != release['archiveSHA256']:
    raise SystemExit('Published ZIP hash does not match inventory')
legacy = temp / 'published-legacy'
legacy.mkdir()
seen = set()
with zipfile.ZipFile(archive) as z:
    for record in release['files']:
        rel = pathlib.PurePosixPath(record['path'])
        if rel.is_absolute() or str(rel) != record['path'] or any(x in ('', '.', '..') for x in rel.parts) or record['path'] in seen:
            raise SystemExit('Unsafe or repeated legacy inventory path')
        seen.add(record['path'])
        matches = [i for i in z.infolist() if i.filename == record['archiveEntry']]
        if len(matches) != 1 or stat.S_ISLNK(matches[0].external_attr >> 16):
            raise SystemExit('Legacy archive entry is absent, ambiguous or linked')
        data = z.read(matches[0])
        if len(data) != record['size'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise SystemExit('Legacy file hash does not match published inventory: ' + record['path'])
        dest = legacy.joinpath(*rel.parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        dest.chmod(0o755 if record['path'].endswith('.dylib') or record['path'] == 'engine/tools/scc' else 0o644)
selected = {k: release[k] for k in ('version', 'archiveSHA256', 'files')}
selected['archive'] = str(archive)
(temp / 'inventory.json').write_text(json.dumps(selected))
(temp / 'candidate-path').write_text(str(a.candidate_resources.resolve(strict=True)))
(temp / 'result-path').write_text(str(a.result.resolve()))
PY

swiftc launcher/Sources/NativeRuntimeManifest.swift \
  launcher/Sources/NativeRuntimeInstallation.swift \
  tests/NativeRuntimeUpgradeTests.swift -o "$UPGRADE_TEST_DIR/upgrade-tests"
"$UPGRADE_TEST_DIR/upgrade-tests" "$UPGRADE_TEST_DIR/published-legacy" \
  "$UPGRADE_TEST_DIR/inventory.json" "$(cat "$UPGRADE_TEST_DIR/candidate-path")" \
  "$(cat "$UPGRADE_TEST_DIR/result-path")"
