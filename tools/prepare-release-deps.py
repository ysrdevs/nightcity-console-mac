#!/usr/bin/env python3
"""Stage explicit, hashed release inputs without reading the installed game.

The public v1.5.0 ZIP is the compatibility baseline. Native 2.5 builds and the
self-contained nctool publish directory are separate required inputs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import tempfile
import zipfile

BASELINE_SHA256 = "19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151"
REDSCRIPT_SHA256 = "b9df6cc0144d786dff9590eb6db913d20744055ab694e52fc8c4584eaee39a8a"
ARCHIVEXL_SHA256 = "6c638dc1108a565ff4806835a17f704cbb2ab2afeb8ccf700080797c3f70591c"
PLUGINS = ("TweakXL", "ArchiveXL")


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"required nonempty file missing: {path}")


def copy_tree(source, dest):
    if not source.is_dir():
        raise ValueError(f"required directory missing: {source}")
    for path in sorted(source.rglob("*")):
        if path.name.startswith("._") or path.name == ".DS_Store":
            continue
        if path.is_symlink():
            raise ValueError(f"release inputs must not contain symlinks: {path}")
        if path.is_file():
            target = dest / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def checked_zip(path, expected):
    require(path)
    if digest(path) != expected:
        raise ValueError(f"checksum mismatch: {path}")
    return zipfile.ZipFile(path)


def extract_prefix(archive, prefix, dest):
    count = 0
    for info in archive.infolist():
        if not info.filename.startswith(prefix) or info.is_dir():
            continue
        relative = PurePosixPath(info.filename[len(prefix):])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe archive member: {info.filename}")
        if any(p.startswith("._") or p == ".DS_Store" for p in relative.parts):
            continue
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise ValueError(f"archive symlink not supported: {info.filename}")
        target = dest.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(info) as source, target.open("wb") as out:
            shutil.copyfileobj(source, out)
        target.chmod(0o755 if mode & 0o111 else 0o644)
        count += 1
    if count == 0:
        raise ValueError(f"required archive subtree missing: {prefix}")


def validate_payload(root):
    for name in ("RED4ext.dylib", "FridaGadget.dylib", "config.ini", "cyberpunk2077_addresses.json",
                 "scc/scc", "scc/libscc_lib.dylib", "nctool/nctool", "nctool/nctool.dll",
                 "nctool/nctool.deps.json", "nctool/nctool.runtimeconfig.json", "nctool/libkraken.dylib",
                 "native25/RED4ext.dylib", "native25/bin/red4ext_plugin_check",
                 "native25/bin/x64/cyberpunk2077_addresses.json", "native25/config.ini"):
        require(root / name)
    old = json.loads((root / "cyberpunk2077_addresses.json").read_text())
    new = json.loads((root / "native25/bin/x64/cyberpunk2077_addresses.json").read_text())
    if old.get("game_version") != "2.3.1" or new.get("game_version") != "2.5.0":
        raise ValueError("address databases must identify 2.3.1 and 2.5.0 respectively")
    for plugin in PLUGINS:
        require(root / f"plugins/{plugin}/{plugin}.dylib")
        require(root / f"native25/plugins/{plugin}/{plugin}.dylib")
        if not list((root / f"native25/plugins/{plugin}/Scripts").rglob("*.reds")):
            raise ValueError(f"native25 {plugin} scripts missing")
    require(root / "native25/plugins/ArchiveXL/Bundle/ArchiveXL.archive")
    for name in ("scc/scc", "nctool/nctool", "native25/bin/red4ext_plugin_check"):
        if not os.access(root / name, os.X_OK):
            raise ValueError(f"helper is not executable: {name}")


def prepare(args):
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-deps-", dir=output.parent) as temp:
        stage = Path(temp) / "payload"
        stage.mkdir()
        with checked_zip(args.baseline, BASELINE_SHA256) as archive:
            prefix = "NightCity Console.app/Contents/"
            version = plistlib.loads(archive.read(prefix + "Info.plist"))["CFBundleShortVersionString"]
            if version != "1.5.0":
                raise ValueError("baseline must be the public v1.5.0 app")
            resources = prefix + "Resources/"
            for name in ("RED4ext.dylib", "FridaGadget.dylib", "config.ini", "cyberpunk2077_addresses.json"):
                (stage / name).write_bytes(archive.read(resources + name))
            for plugin in PLUGINS:
                extract_prefix(archive, resources + f"plugins/{plugin}/", stage / "plugins" / plugin)
        for name in ("RED4ext.dylib", "bin/red4ext_plugin_check", "bin/x64/cyberpunk2077_addresses.json"):
            source = args.native25 / name
            require(source)
            target = stage / "native25" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        # Deliberately exclude private development plugins (Codeware, CET-Lua).
        for plugin in PLUGINS:
            copy_tree(args.native25 / "plugins" / plugin, stage / "native25/plugins" / plugin)
        for name in ("BUILD_INFO.json", "sources.lock.json"):
            if (args.native25 / name).is_file():
                shutil.copy2(args.native25 / name, stage / "native25" / name)
        shutil.copy2(args.config, stage / "native25/config.ini")
        with checked_zip(args.redscript, REDSCRIPT_SHA256) as archive:
            extract_prefix(archive, "engine/tools/", stage / "scc")
        with checked_zip(args.archivexl, ARCHIVEXL_SHA256) as archive:
            extract_prefix(archive, "red4ext/plugins/ArchiveXL/Bundle/", stage / "native25/plugins/ArchiveXL/Bundle")
            for name in ("LICENSE", "THIRD_PARTY_LICENSES"):
                (stage / "native25/plugins/ArchiveXL" / name).write_bytes(
                    archive.read("red4ext/plugins/ArchiveXL/" + name))
        copy_tree(args.nctool, stage / "nctool")
        # Windows-created ZIPs need not carry the Unix executable bit.
        (stage / "scc/scc").chmod(0o755)
        validate_payload(stage)
        manifest = {
            "schema": 1,
            "baseline": {"version": version, "sha256": BASELINE_SHA256},
            "redscript": {"version": "0.5.32", "sha256": REDSCRIPT_SHA256},
            "archivexl_bundle": {"version": "1.27.4", "sha256": ARCHIVEXL_SHA256},
            "files": {str(p.relative_to(stage)): digest(p) for p in sorted(stage.rglob("*")) if p.is_file()},
        }
        (stage / "release-inputs.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        # All validation precedes replacement; a failed prepare preserves the previous staging directory.
        if output.exists():
            shutil.rmtree(output)
        shutil.move(stage, output)
    print(f"Prepared explicit release payload: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("baseline", "native25", "nctool", "redscript", "archivexl", "config", "output"):
        parser.add_argument("--" + flag, type=Path, required=True)
    try:
        prepare(parser.parse_args())
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Release dependency preparation failed: {error}\n")


if __name__ == "__main__":
    main()
