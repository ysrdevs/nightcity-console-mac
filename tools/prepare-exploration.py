#!/usr/bin/env python3
"""Stage and verify only NightCity's two game 2.5 exploration scripts."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

SOURCE = Path(__file__).resolve().parent.parent / "runtime/exploration"
SCRIPT_NAMES = ("NCCCollisionFlightProbe.reds", "NCCFlightClearance.reds")
PAYLOAD_NAMES = {*SCRIPT_NAMES, "manifest.json"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate manifest key: {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def read_scripts(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("exploration source must be a regular directory")
    result = {}
    for name in SCRIPT_NAMES:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or nonregular exploration source: {name}")
        data = path.read_bytes()
        if not data:
            raise ValueError(f"empty exploration source: {name}")
        result[name] = data
    return result


def expected_manifest(scripts):
    return {"schema": 1, "game_version": "2.5.0",
            "files": {name: digest(data) for name, data in sorted(scripts.items())}}


def verify(directory, source=None):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("exploration payload is missing or is not a regular directory")
    if {path.name for path in directory.iterdir()} != PAYLOAD_NAMES:
        raise ValueError("exploration payload must contain exactly its two scripts and manifest")
    for name in PAYLOAD_NAMES:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"nonregular exploration payload: {name}")
    scripts = read_scripts(directory)
    manifest = load_json(directory / "manifest.json")
    if (not isinstance(manifest, dict) or type(manifest.get("schema")) is not int
            or manifest != expected_manifest(scripts)):
        raise ValueError("exploration manifest or script hashes do not match the game 2.5 payload")
    if source is not None and scripts != read_scripts(source):
        raise ValueError("exploration payload differs from the current source scripts")
    return manifest


def metadata(directory, source=None):
    manifest = verify(directory, source)
    return {**manifest, "manifest_sha256": digest((directory / "manifest.json").read_bytes())}


def record_release_inputs(directory, path):
    manifest = load_json(path)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), dict):
        raise ValueError("release inputs must contain the existing dependency file hashes")
    # Dependency provenance stays byte-for-byte equivalent as data. These source
    # inputs are tracked separately because they are assembled after dependencies.
    manifest["exploration"] = metadata(directory)
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def prepare(output, source=SOURCE, release_inputs=None):
    output = output.absolute()
    source = source.absolute()
    if (output.is_symlink() or output.resolve() == source.resolve()
            or output.resolve() in source.resolve().parents or source.resolve() in output.resolve().parents):
        raise ValueError("exploration output must be separate from its source directory")
    scripts = read_scripts(source)
    manifest = expected_manifest(scripts)
    # Refuse to remove an unrelated directory or a tampered previous payload.
    if output.exists():
        verify(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".exploration-", dir=output.parent) as temporary:
        staged = Path(temporary) / "payload"
        staged.mkdir()
        for name, data in scripts.items():
            (staged / name).write_bytes(data)
        (staged / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        verify(staged, source)
        if output.exists():
            shutil.rmtree(output)
        shutil.move(staged, output)
    if release_inputs is not None:
        record_release_inputs(output, release_inputs)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--verify", type=Path)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--release-inputs", type=Path)
    args = parser.parse_args()
    try:
        if args.verify:
            if args.release_inputs is not None:
                raise ValueError("--release-inputs is only valid when staging a payload")
            verify(args.verify, args.source)
            print(f"Verified game 2.5 exploration scripts: {args.verify}")
        else:
            prepare(args.output, args.source, args.release_inputs)
            print(f"Prepared game 2.5 exploration scripts: {args.output}")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Exploration payload validation failed: {error}\n")
