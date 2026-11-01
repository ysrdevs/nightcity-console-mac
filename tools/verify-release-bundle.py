#!/usr/bin/env python3
"""Check a local release bundle before signing or distribution. Never runs its code."""
import argparse
import errno
import json
from pathlib import Path
import plistlib
import re
import runpy
import subprocess
import zipfile

helpers = runpy.run_path(str(Path(__file__).with_name("prepare-release-deps.py")))
exploration = runpy.run_path(str(Path(__file__).with_name("prepare-exploration.py")))
MINIMUM_SUPPORTED_MACOS = "15.5"


def version_tuple(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError(f"invalid macOS deployment target: {value}")
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))


def validate_macho_target(load_commands, relative, maximum=MINIMUM_SUPPORTED_MACOS):
    """Validate arm64 load-command output, not the SDK used to build the binary."""
    targets = []
    for block in load_commands.split("Load command "):
        if re.search(r"^\s*cmd LC_BUILD_VERSION\s*$", block, re.M):
            platform = re.search(r"^\s*platform (\S+)\s*$", block, re.M)
            target = re.search(r"^\s*minos (\S+)\s*$", block, re.M)
            if not platform or platform[1].lower() not in {"1", "macos"} or not target:
                raise ValueError(f"missing or non-macOS deployment target in {relative}")
            targets.append(target[1])
        elif re.search(r"^\s*cmd LC_VERSION_MIN_MACOSX\s*$", block, re.M):
            target = re.search(r"^\s*version (\S+)\s*$", block, re.M)
            if not target:
                raise ValueError(f"missing macOS deployment target in {relative}")
            targets.append(target[1])
    if not targets:
        raise ValueError(f"missing macOS deployment target in {relative}")
    for target in targets:
        if version_tuple(target) > version_tuple(maximum):
            raise ValueError(f"{relative} requires macOS {target}, above the supported {maximum} floor")


def verify_no_nested_zips(app):
    """Distribution containers may be ZIPs, but their app payload must not be."""
    for path in app.rglob("*"):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(4)
        # is_zipfile only recognizes an end marker. ZIP-processing libraries
        # contain those constants too, so require a readable central directory.
        has_zip_directory = False
        if zipfile.is_zipfile(path):
            try:
                with zipfile.ZipFile(path) as archive:
                    archive.infolist()
                    has_zip_directory = True
            except (zipfile.BadZipFile, ValueError):
                pass
            except OSError as error:
                if error.errno != errno.EINVAL:
                    raise
        if (path.suffix.lower() in {".zip", ".zipx"}
                or header in {b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"}
                or has_zip_directory):
            raise ValueError(f"nested ZIP in app payload: {path.relative_to(app)}")


def verify_exploration(resources, version, manifest, check_inputs=False):
    if tuple(map(int, version.split("."))) < (1, 8, 0):
        return
    expected = exploration["metadata"](resources / "exploration",
                                        exploration["SOURCE"] if check_inputs else None)
    if manifest.get("exploration") != expected:
        raise ValueError("release-inputs.json does not match the bundled exploration source hashes")


def verify(app, check_inputs=False):
    resources = app / "Contents/Resources"
    helpers["validate_payload"](resources)
    legacy_files = helpers["legacy_baseline"]()["files"]
    helpers["require"](app / "Contents/MacOS/NightCityConsole")
    helpers["require"](resources / "libcyberconsole_overlay.dylib")
    for name in ("red4ext_hooks.js", "FridaGadget.config", "cet_catalog.tsv", "cybermodman_names.json"):
        helpers["require"](resources / name)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if version != info["CFBundleVersion"] or tuple(map(int, version.split("."))) <= (1, 5, 0):
        raise ValueError("release bundle versions must match and be newer than the public 1.5.0 baseline")
    check_os_floor = tuple(map(int, version.split("."))) >= (1, 9, 0)
    if check_os_floor and version_tuple(info.get("LSMinimumSystemVersion", "")) != version_tuple(MINIMUM_SUPPORTED_MACOS):
        raise ValueError(f"release 1.9+ must declare the game-supported macOS {MINIMUM_SUPPORTED_MACOS} floor")
    if tuple(map(int, version.split("."))) >= (1, 8, 1):
        verify_no_nested_zips(app)
    manifest = json.loads((resources / "release-inputs.json").read_text())
    if manifest.get("baseline", {}).get("sha256") != helpers["BASELINE_SHA256"]:
        raise ValueError("release-inputs.json does not identify the pinned public baseline")
    verify_exploration(resources, version, manifest, check_inputs)
    if check_inputs:
        for relative, expected in manifest["files"].items():
            helpers["runtime_path"](relative)
            if helpers["digest"](resources / relative) != expected:
                raise ValueError(f"staged input changed while assembling bundle: {relative}")
    for parent, allowed in ((resources / "plugins", helpers["PLUGINS"]),
                            (resources / "native25/plugins", helpers["NATIVE25_PLUGINS"])):
        unexpected = {p.name for p in parent.iterdir() if p.is_dir()} - set(allowed)
        if unexpected:
            raise ValueError(f"private/unexpected plugins in release: {sorted(unexpected)}")
    if (resources / "native25/CODEWARE_TEST_BUILD.json").exists():
        raise ValueError("private Codeware handoff metadata must not ship in a release")
    for path in sorted(app.rglob("*")):
        helpers["runtime_path"](path.relative_to(app).as_posix())
        if path.name.startswith("._"):
            raise ValueError(f"AppleDouble sidecar in release: {path}")
        if path.is_symlink():
            raise ValueError(f"unexpected bundle symlink: {path}")
        if not path.is_file():
            continue
        kind = subprocess.check_output(["file", "-b", str(path)], text=True)
        if "Mach-O" not in kind:
            continue
        if "arm64" not in kind:
            raise ValueError(f"native binary has no arm64 slice: {path}")
        if check_os_floor:
            commands = subprocess.check_output(["otool", "-arch", "arm64", "-l", str(path)], text=True)
            relative = path.relative_to(resources).as_posix() if path.is_relative_to(resources) else None
            # validate_payload already checked the original signed byte hashes
            # for these nine legacy files. No wildcard path exception.
            maximum = legacy_files[relative]["minimum_macos"] if relative in legacy_files else MINIMUM_SUPPORTED_MACOS
            validate_macho_target(commands, path.relative_to(app).as_posix(), maximum)
        identities = {
            line.strip() for line in subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()
            if line.strip() and not line.rstrip().endswith(":")
        }
        links = subprocess.check_output(["otool", "-L", str(path)], text=True)
        for line in links.splitlines():
            if not line.startswith("\t"):
                continue
            link = line.strip().split(" (", 1)[0]
            # otool -L includes the dylib's LC_ID_DYLIB, which may retain an upstream build path.
            # Its identity is not a load dependency; inspect LC_LOAD_DYLIB references instead.
            if link in identities:
                continue
            if link.startswith("/") and not link.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError(f"nonportable dependency in {path.name}: {link}")
            if link.startswith("@loader_path/") and not (path.parent / link[len("@loader_path/"):]).is_file():
                raise ValueError(f"missing bundled dependency in {path.name}: {link}")
            # Each distributed native component is self-contained beside its dependencies.
            # The dylib's own LC_ID_DYLIB also appears in `otool -L`; it is not a dependency.
            if link.startswith("@rpath/") and Path(link).name != path.name:
                sibling = path.parent / link[len("@rpath/"):]
                if not sibling.is_file():
                    raise ValueError(f"unresolved bundled dependency in {path.name}: {link}")
    print(f"Release bundle structure and native dependencies verified: {app} (v{version})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--check-inputs", action="store_true", help="compare runtime input hashes before codesign changes binaries")
    args = parser.parse_args()
    try:
        verify(args.app, args.check_inputs)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release bundle validation failed: {error}\n")
