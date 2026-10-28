#!/usr/bin/env python3
"""Build or verify the two pinned optional MIT mod packages; never reads a game."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile

ROOT = Path(__file__).resolve().parent.parent / "native25/optional-mods"
LOCK = ROOT / "sources.lock.json"
MAX_FILES = 128
MAX_ENTRIES = 512
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024
PINNED = {"equipment-ex": ("1.2.9", "EquipmentEx"), "cyberware-ex": ("1.5.6", "CyberwareEx")}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 512
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"unsafe optional package path: {value}")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        raise ValueError(f"unsafe optional package path: {value}")
    return path


def no_symlinks(path, boundary=None):
    """Reject links within the supplied root, without rejecting OS /var aliases."""
    boundary = boundary or path
    if path != boundary and boundary not in path.parents:
        raise ValueError("optional file is outside its declared root")
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise ValueError(f"optional payload path contains a symlink: {path}")
        if candidate == boundary:
            break


def read_file(path, boundary=None):
    no_symlinks(path, boundary)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE_BYTES:
        raise ValueError(f"nonregular or oversized optional file: {path}")
    data = path.read_bytes()
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f"optional file exceeded its size limit: {path}")
    return data


def read_json(path, boundary=None):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate optional manifest key: {key}")
            result[key] = value
        return result
    return json.loads(read_file(path, boundary), object_pairs_hook=unique)


def tree(directory):
    no_symlinks(directory)
    if not directory.is_dir():
        raise ValueError(f"optional payload directory is missing: {directory}")
    files, directories, pending = {}, set(), [directory]
    entries = total = 0
    while pending:
        for path in pending.pop().iterdir():
            entries += 1
            if entries > MAX_ENTRIES:
                raise ValueError("optional payload exceeds its entry limit")
            relative = str(safe_path(path.relative_to(directory).as_posix()))
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"optional payload contains a symlink: {relative}")
            if stat.S_ISDIR(mode):
                directories.add(relative)
                pending.append(path)
            elif stat.S_ISREG(mode):
                if len(files) >= MAX_FILES:
                    raise ValueError("optional payload exceeds its file limit")
                data = read_file(path, directory)
                total += len(data)
                if total > MAX_TOTAL_BYTES:
                    raise ValueError("optional payload exceeds its total byte limit")
                files[relative] = data
            else:
                raise ValueError(f"nonregular optional payload entry: {relative}")
    return files, directories


def parent_directories(paths):
    return {str(parent) for name in paths for parent in PurePosixPath(name).parents if str(parent) != "."}


def verify_tree(directory, expected):
    actual, directories = tree(directory)
    if set(actual) != set(expected) or directories != parent_directories(expected):
        raise ValueError("optional payload contains missing or extra files/directories")
    if any(actual[name] != data for name, data in expected.items()):
        raise ValueError("optional payload file bytes do not match the pinned inputs")


def expected_payload():
    lock = read_json(LOCK, ROOT)
    if lock["schema"] != 1 or lock["game_version"] != "2.5.0":
        raise ValueError("optional packages must target the accepted 2.5.0 profile")
    if {m["manifest"]["id"] for m in lock["mods"]} != {"equipment-ex", "cyberware-ex"} or len(lock["mods"]) != 2:
        raise ValueError("only the two accepted optional MIT mod cores may be packaged")
    output = {}
    manifest = {"schema": 2, "game_version": "2.5.0", "mods": []}
    for mod in lock["mods"]:
        metadata = mod["manifest"]
        version, script_name = PINNED[metadata["id"]]
        if (set(metadata) != {"id", "name", "version", "package", "license", "license_path", "source_url", "script_directory"}
                or metadata["version"] != version or metadata["package"] != f"{metadata['id']}-{version}.zip"
                or metadata["script_directory"] != f"r6/scripts/{script_name}"
                or metadata["license_path"] != f"licenses/{script_name}-MIT.txt"
                or metadata["source_url"] != f"https://github.com/psiberx/cp2077-{metadata['id']}"):
            raise ValueError("optional package metadata differs from the pinned cores")
        package = metadata["package"][:-4]
        source = ROOT / "source" / metadata["id"]
        no_symlinks(source, ROOT)
        actual, directories = tree(source)
        if set(actual) != set(mod["files"]) or directories != parent_directories(mod["files"]):
            raise ValueError(f"unexpected or missing source file in {metadata['id']}")
        files = {}
        for name, expected in mod["files"].items():
            safe_path(name)
            allowed = name.startswith(metadata["script_directory"] + "/") and (name.endswith(".reds") or name.endswith("/LICENSE"))
            if metadata["id"] == "equipment-ex":
                allowed = allowed or name in {"archive/Mac/mod/EquipmentEx.archive", "archive/Mac/mod/EquipmentEx.archive.xl", "r6/config/redsUserHints/EquipmentEx.toml"}
            if not allowed:
                raise ValueError(f"non-core file cannot be packaged: {name}")
            data = actual[name]
            if digest(data) != expected:
                raise ValueError(f"optional source checksum mismatch: {name}")
            files[name] = data
        if metadata["id"] == "cyberware-ex" and mod["transforms"]:
            raise ValueError("Cyberware-EX must remain pristine until installation")
        for change in mod["transforms"]:
            name, before, after = change["path"], change["before"].encode(), change["after"].encode()
            if not before or len(before) > 1024 or len(after) > 1024 or files[name].count(before) != 1:
                raise ValueError(f"optional compatibility transform is ambiguous: {name}")
            files[name] = files[name].replace(before, after)
            if digest(files[name]) != mod["installed_files"][name]:
                raise ValueError(f"optional compatibility output differs from accepted source: {name}")
        license_data = read_file(ROOT / safe_path(metadata["license_path"]), ROOT)
        if metadata["license"] != "MIT" or license_data != files[metadata["script_directory"] + "/LICENSE"]:
            raise ValueError(f"missing or changed MIT notice: {metadata['id']}")
        # Copy the already pinned runtime bytes directly. Historical archive
        # hashes stay in sources.lock.json; no ZIP is generated or unpacked here.
        for name, data in sorted(files.items()):
            output[f"{package}/{name}"] = data
        output[str(safe_path(metadata["license_path"]))] = license_data
        manifest["mods"].append({**metadata, "package": package,
                                 "files": {name: digest(data) for name, data in sorted(files.items())}})
    output["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return output


def verify(directory):
    expected = expected_payload()
    verify_tree(directory, expected)
    return expected


def verify_previous(directory, expected):
    """Permit replacement of this exact payload or the previously pinned ZIP layout."""
    actual, directories = tree(directory)
    if actual == expected and directories == parent_directories(expected):
        return
    # Read-only migration recognition. These are historical hashes; this path
    # never constructs or extracts an archive.
    lock = read_json(LOCK, ROOT)
    legacy = {"schema": 1, "game_version": "2.5.0", "mods": []}
    hashes = {}
    for mod in lock["mods"]:
        metadata = mod["manifest"]
        hashes[metadata["package"]] = mod["package_sha256"]
        hashes[metadata["license_path"]] = digest(expected[metadata["license_path"]])
        legacy["mods"].append({**metadata, "sha256": mod["package_sha256"]})
    hashes["manifest.json"] = digest((json.dumps(legacy, indent=2) + "\n").encode())
    if (set(actual) != set(hashes) or directories != parent_directories(hashes)
            or any(digest(data) != hashes[name] for name, data in actual.items())):
        raise ValueError("kept output directory because it is not an unchanged managed optional payload")


def prepare(output):
    expected = expected_payload()
    output = output.absolute()
    no_symlinks(output)
    canonical = output.parent.resolve() / output.name
    source = ROOT.resolve()
    if canonical == source or source in canonical.parents or canonical in source.parents:
        raise ValueError("output must be separate from the preserved optional source directory")
    if output.exists():
        verify_previous(output, expected)
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
    print(f"Prepared two unpacked optional 2.5 mod packages: {output}")


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
