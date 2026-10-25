#!/usr/bin/env python3
"""Stage explicit, hashed release inputs without reading the installed game.

The public v1.5.0 ZIP is the compatibility baseline. A verified prebuilt native
2.5 runtime and the self-contained nctool publish directory are separate inputs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import runpy
import shutil
import stat
import tempfile
import zipfile

BASELINE_SHA256 = "19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151"
REDSCRIPT_SHA256 = "b9df6cc0144d786dff9590eb6db913d20744055ab694e52fc8c4584eaee39a8a"
ARCHIVEXL_SHA256 = "6c638dc1108a565ff4806835a17f704cbb2ab2afeb8ccf700080797c3f70591c"
PLUGINS = ("TweakXL", "ArchiveXL")  # Preserved public 2.3.1 payload.
NATIVE25_PLUGINS = (*PLUGINS, "Codeware")
REPO = Path(__file__).resolve().parent.parent
ACCEPTED_PAYLOAD = REPO / "native25/accepted-payload.json"
OPTIONAL = runpy.run_path(str(REPO / "tools/prepare-optional-mods.py"))
NATIVE_LICENSES = (
    ("TweakXL-MIT.txt", "plugins/TweakXL/LICENSE"),
    ("TweakXL-THIRD-PARTY.txt", "plugins/TweakXL/THIRD_PARTY_LICENSES"),
    ("RED4ext-MIT.md", "LICENSE.md"),
    ("RED4ext-THIRD-PARTY.md", "THIRD_PARTY_LICENSES.md"),
    ("RED4ext.SDK-MIT.md", "RED4ext.SDK-LICENSE.md"),
)
NATIVE_METADATA = {"accepted-payload.json", "BUILD_INFO.json"}
SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx",
                   ".m", ".mm", ".inl", ".inc", ".patch", ".diff", ".cmake",
                   ".cs", ".swift", ".py"}


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"required nonempty file missing: {path}")


def runtime_path(relative):
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or ".." in path.parts or "\\" in relative:
        raise ValueError(f"invalid runtime input path: {relative}")
    if (path.suffix.lower() in SOURCE_SUFFIXES
            or path.name.lower() in {"sources.lock.json", "cmakelists.txt", "makefile"}
            or any(part.lower() in {".git", "patches", "development", "source", "sources", "include", "headers"}
                   for part in path.parts)):
        raise ValueError(f"native source or private build recipe must not ship: {relative}")
    return relative


def public_native_manifest(accepted):
    """Keep runtime identity and input hashes, without source history or recipes."""
    result = {"schema": 1, "game_version": accepted["game_version"], "profile": accepted["profile"],
              "files": {runtime_path(name): value for name, value in accepted["files"].items()}}
    if "game_uuid" in accepted:
        result["game_uuid"] = accepted["game_uuid"]
    return result


def native_allowed_files(accepted):
    return (set(public_native_manifest(accepted)["files"]) | NATIVE_METADATA | {"config.ini"}
            | {destination for _, destination in NATIVE_LICENSES})


def validate_native_runtime(root, accepted):
    allowed = native_allowed_files(accepted)
    for path in root.rglob("*"):
        relative = runtime_path(path.relative_to(root).as_posix())
        if path.is_symlink():
            raise ValueError(f"runtime payload symlink is not supported: {relative}")
        if path.is_file() and relative not in allowed:
            raise ValueError(f"unrecorded native runtime file: {relative}")


def write_native_metadata(root, accepted):
    """Generate public metadata for existing runtime bytes; never rebuild or sign."""
    validate_native_runtime(root, accepted)
    manifest = public_native_manifest(accepted)
    manifest_path = root / "accepted-payload.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    build_info = {
        "schema": 3, "assembly_mode": "verified-runtime-inputs",
        "game_version": manifest["game_version"], "profile": manifest["profile"],
        "runtime_input_manifest_sha256": digest(manifest_path),
        "file_hash_stage": "before-final-release-signing",
        "files": {p.relative_to(root).as_posix(): digest(p)
                  for p in sorted(root.rglob("*")) if p.is_file() and p.name != "BUILD_INFO.json"},
    }
    (root / "BUILD_INFO.json").write_text(json.dumps(build_info, indent=2, sort_keys=True) + "\n")


def validate_native_metadata(root, accepted):
    expected = public_native_manifest(accepted)
    manifest_path = root / "accepted-payload.json"
    if json.loads(manifest_path.read_text()) != expected:
        raise ValueError("native runtime manifest must contain only the accepted runtime identity and input hashes")
    build = json.loads((root / "BUILD_INFO.json").read_text())
    fields = {"schema", "assembly_mode", "game_version", "profile", "runtime_input_manifest_sha256", "file_hash_stage", "files"}
    if (set(build) != fields or build["schema"] != 3 or build["assembly_mode"] != "verified-runtime-inputs"
            or build["game_version"] != expected["game_version"] or build["profile"] != expected["profile"]
            or build["runtime_input_manifest_sha256"] != digest(manifest_path)
            or build["file_hash_stage"] != "before-final-release-signing"):
        raise ValueError("native build metadata must describe verified runtime inputs only")
    files = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and p.name != "BUILD_INFO.json"}
    if set(build["files"]) != files:
        raise ValueError("native build metadata file inventory differs from the runtime payload")


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
    for path in root.rglob("*"):
        runtime_path(path.relative_to(root).as_posix())
    accepted = json.loads(ACCEPTED_PAYLOAD.read_text())
    validate_native_runtime(root / "native25", accepted)
    validate_native_metadata(root / "native25", accepted)
    OPTIONAL["verify"](root / "optional-mods")
    for name in ("RED4ext.dylib", "FridaGadget.dylib", "config.ini", "cyberpunk2077_addresses.json",
                 "scc/scc", "scc/libscc_lib.dylib", "nctool/nctool", "nctool/nctool.dll",
                 "nctool/nctool.deps.json", "nctool/nctool.runtimeconfig.json", "nctool/libkraken.dylib",
                 "nctool/nightcity-mod-compat.json",
                 "native25/RED4ext.dylib", "native25/bin/red4ext_plugin_check",
                 "native25/bin/x64/cyberpunk2077_addresses.json", "native25/config.ini"):
        require(root / name)
    old = json.loads((root / "cyberpunk2077_addresses.json").read_text())
    new = json.loads((root / "native25/bin/x64/cyberpunk2077_addresses.json").read_text())
    if old.get("game_version") != "2.3.1" or new.get("game_version") != "2.5.0":
        raise ValueError("address databases must identify 2.3.1 and 2.5.0 respectively")
    for plugin in PLUGINS:
        require(root / f"plugins/{plugin}/{plugin}.dylib")
    for plugin in NATIVE25_PLUGINS:
        require(root / f"native25/plugins/{plugin}/{plugin}.dylib")
        if not list((root / f"native25/plugins/{plugin}/Scripts").rglob("*.reds")):
            raise ValueError(f"native25 {plugin} scripts missing")
    require(root / "native25/plugins/ArchiveXL/Bundle/ArchiveXL.archive")
    global_script = (root / "native25/plugins/Codeware/Scripts/Codeware.Global.reds").read_text()
    if global_script.count("public native func ForgetItemID(itemID: ItemID) -> Bool") != 1:
        raise ValueError("Codeware must include exactly one verified wardrobe native declaration")
    for name in ("scc/scc", "nctool/nctool", "native25/bin/red4ext_plugin_check"):
        if not os.access(root / name, os.X_OK):
            raise ValueError(f"helper is not executable: {name}")
    if digest(root / "nctool/nightcity-mod-compat.json") != digest(REPO / "native25/modcompat/nightcity-mod-compat.json"):
        raise ValueError("nctool compatibility catalog differs from the checked release source")


def prepare(args):
    accepted = public_native_manifest(json.loads(ACCEPTED_PAYLOAD.read_text()))
    # Release staging promotes verified prebuilt runtime inputs. Native port
    # sources and build recipes are not required or included in this process.
    for relative, expected in accepted["files"].items():
        path = args.native25 / relative
        if not path.is_file():
            raise ValueError(f"accepted native25 file missing: {relative}")
        if digest(path) != expected:
            raise ValueError(f"native25 input differs from accepted checkpoint: {relative}")
    for plugin in NATIVE25_PLUGINS:
        for path in (args.native25 / "plugins" / plugin).rglob("*"):
            if path.is_file() and str(path.relative_to(args.native25)) not in accepted["files"]:
                raise ValueError(f"unrecorded native25 plugin file: {path.relative_to(args.native25)}")
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
        for plugin in NATIVE25_PLUGINS:
            copy_tree(args.native25 / "plugins" / plugin, stage / "native25/plugins" / plugin)
        shutil.copy2(args.config, stage / "native25/config.ini")
        with checked_zip(args.redscript, REDSCRIPT_SHA256) as archive:
            extract_prefix(archive, "engine/tools/", stage / "scc")
        with checked_zip(args.archivexl, ARCHIVEXL_SHA256) as archive:
            if hashlib.sha256(archive.read("red4ext/plugins/ArchiveXL/Bundle/ArchiveXL.archive")).hexdigest() != digest(stage / "native25/plugins/ArchiveXL/Bundle/ArchiveXL.archive"):
                raise ValueError("accepted ArchiveXL archive differs from the official release")
        for source, destination in NATIVE_LICENSES:
            shutil.copy2(REPO / "native25/licenses" / source, stage / "native25" / destination)
        write_native_metadata(stage / "native25", accepted)
        copy_tree(args.nctool, stage / "nctool")
        shutil.copy2(REPO / "native25/licenses/redscript-MIT.txt", stage / "scc/LICENSE")
        for name in ("CyberwareEx-MIT.txt", "EquipmentEx-MIT.txt", "WolvenKit-GPL3.txt", "nctool-MIT.txt", "Kraken-NOTICE.txt"):
            (stage / "nctool/licenses").mkdir(exist_ok=True)
            shutil.copy2(REPO / "native25/modcompat" / name, stage / "nctool/licenses" / name)
        OPTIONAL["prepare"](stage / "optional-mods")
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
