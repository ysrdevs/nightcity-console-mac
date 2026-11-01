#!/usr/bin/env python3
"""Build pinned Kraken sources for the native Apple Silicon helper."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess

COMMIT = "f75df7ab817d9ffb43ea8ad84a698ad3df9ba4c1"
SIMDE_COMMIT = "e9cc73da14ab6bc2bf7c2bb4f1c2645415515d8b"
SOURCES = ["compress.cpp", "compr_multiarray.cpp", "compr_match_finder.cpp",
           "compr_leviathan.cpp", "compr_kraken.cpp", "compr_tans.cpp",
           "compr_entropy.cpp", "kraken.cpp"]


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="new build directory; existing directories are refused")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("run this recipe on an Apple Silicon Mac with Xcode installed")
    source = args.source.resolve(strict=True)
    for repo, commit in [(source, COMMIT), (source / "simde", SIMDE_COMMIT)]:
        if output("git", "-C", str(repo), "rev-parse", "HEAD") != commit:
            parser.error(f"unexpected source revision: {repo}")
        if output("git", "-C", str(repo), "status", "--porcelain"):
            parser.error(f"source checkout must be clean: {repo}")
    destination = args.output.absolute()
    destination.mkdir(parents=True, exist_ok=False)
    library = destination / "libkraken.dylib"
    compiler = output("xcrun", "--find", "clang++")
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    # Upstream CMake forces a universal build. Compile its exact shared-library
    # source list directly to retain the arm64 deployment target without edits.
    command = [compiler, "-target", "arm64-apple-macos15.5", "-isysroot", sdk,
               "-std=c++14", "-O3", "-fopenmp-simd", "-fPIC",
               "-DSIMDE_ENABLE_NATIVE_ALIASES", "-DSIMDE_ENABLE_OPENMP",
               "-I", str(source), "-I", str(source / "simde"), "-dynamiclib",
               "-Wl,-install_name,@rpath/libkraken.dylib",
               *[str(source / name) for name in SOURCES], "-o", str(library)]
    process = subprocess.run(command, capture_output=True, text=True)
    (destination / "stdout.txt").write_text(process.stdout)
    (destination / "stderr.txt").write_text(process.stderr)
    process.check_returncode()
    build_version = output("xcrun", "vtool", "-show-build", str(library))
    architecture = output("lipo", "-archs", str(library))
    exports = output("nm", "-gU", str(library))
    if architecture != "arm64" or "minos 15.5" not in build_version:
        raise RuntimeError("the compiled deployment target did not match the recipe")
    if not all(name in exports for name in ["_Kraken_Decompress", "_Kraken_Compress"]):
        raise RuntimeError("missing required C ABI exports")
    record = {"repository": "https://github.com/WolvenKit/kraken.git",
              "commit": COMMIT, "simde_commit": SIMDE_COMMIT,
              "command": command, "compiler_version": output(compiler, "--version"),
              "architecture": architecture, "build_version": build_version,
              "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
              "dependencies": output("otool", "-L", str(library))}
    (destination / "BUILD.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"library": str(library), "sha256": record["sha256"]}))


if __name__ == "__main__":
    main()
