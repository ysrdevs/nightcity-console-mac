#!/usr/bin/env python3
"""Check a local release bundle before signing or distribution. Never runs its code."""
import argparse
import json
from pathlib import Path
import plistlib
import runpy
import subprocess

helpers = runpy.run_path(str(Path(__file__).with_name("prepare-release-deps.py")))


def verify(app, check_inputs=False):
    resources = app / "Contents/Resources"
    helpers["validate_payload"](resources)
    helpers["require"](app / "Contents/MacOS/NightCityConsole")
    helpers["require"](resources / "libcyberconsole_overlay.dylib")
    for name in ("red4ext_hooks.js", "FridaGadget.config", "cet_catalog.tsv", "cybermodman_names.json"):
        helpers["require"](resources / name)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if version != info["CFBundleVersion"] or tuple(map(int, version.split("."))) <= (1, 5, 0):
        raise ValueError("release bundle versions must match and be newer than the public 1.5.0 baseline")
    manifest = json.loads((resources / "release-inputs.json").read_text())
    if manifest.get("baseline", {}).get("sha256") != helpers["BASELINE_SHA256"]:
        raise ValueError("release-inputs.json does not identify the pinned public baseline")
    if check_inputs:
        for relative, expected in manifest["files"].items():
            if helpers["digest"](resources / relative) != expected:
                raise ValueError(f"staged input changed while assembling bundle: {relative}")
    for parent in (resources / "plugins", resources / "native25/plugins"):
        unexpected = {p.name for p in parent.iterdir() if p.is_dir()} - set(helpers["PLUGINS"])
        if unexpected:
            raise ValueError(f"private/unexpected plugins in release: {sorted(unexpected)}")
    for path in sorted(app.rglob("*")):
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
    parser.add_argument("--check-inputs", action="store_true", help="compare source hashes before codesign changes binaries")
    args = parser.parse_args()
    try:
        verify(args.app, args.check_inputs)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release bundle validation failed: {error}\n")
