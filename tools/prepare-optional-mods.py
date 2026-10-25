#!/usr/bin/env python3
"""Build or verify the two pinned optional MIT mod packages; never reads a game."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent / "native25/optional-mods"
LOCK = ROOT / "sources.lock.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        raise ValueError(f"unsafe optional package path: {value}")
    return path


def expected_payload():
    lock = json.loads(LOCK.read_text())
    if lock["schema"] != 1 or lock["game_version"] != "2.5.0":
        raise ValueError("optional packages must target the accepted 2.5.0 profile")
    if {m["manifest"]["id"] for m in lock["mods"]} != {"equipment-ex", "cyberware-ex"} or len(lock["mods"]) != 2:
        raise ValueError("only the two accepted optional MIT mod cores may be packaged")
    output = {}
    manifest = {"schema": 1, "game_version": "2.5.0", "mods": []}
    for mod in lock["mods"]:
        metadata = mod["manifest"]
        source = ROOT / "source" / metadata["id"]
        actual = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
        if actual != set(mod["files"]):
            raise ValueError(f"unexpected or missing source file in {metadata['id']}")
        files = {}
        for name, expected in mod["files"].items():
            path = source / safe_path(name)
            if any(parent.is_symlink() for parent in (path, *path.parents)):
                raise ValueError(f"optional source is a symlink: {name}")
            allowed = name.startswith(metadata["script_directory"] + "/") and (name.endswith(".reds") or name.endswith("/LICENSE"))
            if metadata["id"] == "equipment-ex":
                allowed = allowed or name in {"archive/Mac/mod/EquipmentEx.archive", "archive/Mac/mod/EquipmentEx.archive.xl", "r6/config/redsUserHints/EquipmentEx.toml"}
            if not allowed:
                raise ValueError(f"non-core file cannot be packaged: {name}")
            data = path.read_bytes()
            if digest(data) != expected:
                raise ValueError(f"optional source checksum mismatch: {name}")
            files[name] = data
        for change in mod["transforms"]:
            name, before, after = change["path"], change["before"].encode(), change["after"].encode()
            if files[name].count(before) != 1:
                raise ValueError(f"optional compatibility transform is ambiguous: {name}")
            files[name] = files[name].replace(before, after)
            if digest(files[name]) != mod["installed_files"][name]:
                raise ValueError(f"optional compatibility output differs from accepted source: {name}")
        license_data = (ROOT / safe_path(metadata["license_path"])).read_bytes()
        if metadata["license"] != "MIT" or license_data != files[metadata["script_directory"] + "/LICENSE"]:
            raise ValueError(f"missing or changed MIT notice: {metadata['id']}")
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in sorted(files.items()):
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                entry.compress_type = zipfile.ZIP_STORED
                archive.writestr(entry, data)
        data = buffer.getvalue()
        package_sha = digest(data)
        if mod.get("package_sha256") and package_sha != mod["package_sha256"]:
            raise ValueError(f"optional ZIP differs from the pinned deterministic output: {metadata['id']}")
        output[str(safe_path(metadata["package"]))] = data
        output[str(safe_path(metadata["license_path"]))] = license_data
        manifest["mods"].append({**metadata, "sha256": package_sha})
    output["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return output


def verify(directory):
    expected = expected_payload()
    actual = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}
    if actual != set(expected):
        raise ValueError("optional payload must contain only its manifest, two ZIPs and two licenses")
    for relative, data in expected.items():
        path = directory / relative
        if path.is_symlink() or path.read_bytes() != data:
            raise ValueError(f"optional payload mismatch: {relative}")
    return expected


def prepare(output):
    expected = expected_payload()
    output = output.resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError("output must be separate from the preserved optional source directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".optional-mods-", dir=output.parent) as temporary:
        staged = Path(temporary) / "payload"
        staged.mkdir()
        for relative, data in expected.items():
            path = staged / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        verify(staged)
        if output.exists():
            shutil.rmtree(output)
        shutil.move(staged, output)
    print(f"Prepared two optional 2.5 mod packages: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path)
    group.add_argument("--verify", type=Path)
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.verify)
            print(f"Verified optional 2.5 packages: {args.verify}")
        else:
            prepare(args.output)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Optional package validation failed: {error}\n")
