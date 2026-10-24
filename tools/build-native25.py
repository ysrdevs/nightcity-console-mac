#!/usr/bin/env python3
"""Rebuild the pinned macOS 2.5 native payload without reading an installed game."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "native25/sources.lock.json"
IDENTITY = ["-c", "user.name=ysrdevs", "-c", "user.email=singh.yuvraj31@icloud.com"]


def run(*args, cwd=None, capture=False):
    command = [str(arg) for arg in args]
    print("+ " + " ".join(command), flush=True)
    return subprocess.run(command, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def git(path, *args, capture=False):
    return run("git", "-C", path, *args, capture=capture)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def include_digest(root):
    files = {p.relative_to(root).as_posix(): digest(p) for p in root.rglob("*")
             if p.is_file() and not p.name.startswith("._")}
    value = "".join(f"{name}\0{sha}\n" for name, sha in sorted(files.items()))
    return len(files), hashlib.sha256(value.encode()).hexdigest()


def read_manifest():
    lock = json.loads(LOCK.read_text())
    if lock["schema"] != 1:
        raise ValueError("unsupported source manifest")
    for repo in lock["repositories"]:
        for patch in repo["patches"]:
            relative = PurePosixPath(patch["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("patch path must stay inside native25")
            if digest(LOCK.parent / relative) != patch["sha256"]:
                raise ValueError(f"patch checksum mismatch: {relative}")
    return lock


def verify_source(path, repo):
    if git(path, "rev-parse", "HEAD^{tree}", capture=True).strip() != repo["patched_tree"]:
        raise ValueError(f"source tree mismatch: {repo['name']}")
    # Ignore generated, untracked build directories, but refuse tracked edits.
    git(path, "diff", "--exit-code", "HEAD", "--")
    for sub in repo["submodules"]:
        pinned = git(path, "rev-parse", f"HEAD:{sub['path']}", capture=True).strip()
        if pinned != sub["commit"]:
            raise ValueError(f"submodule pin mismatch: {sub['path']}")


def prepare_source(path, repo):
    path.mkdir()
    git(path, "init", "--quiet")
    git(path, "remote", "add", "origin", repo["url"])
    git(path, "fetch", "--no-tags", "--depth=1", "origin", repo["upstream_commit"])
    git(path, "checkout", "--quiet", "-b", "nightcity-2.5", "FETCH_HEAD")
    if repo.get("version_tag"):
        # Upstream CMake uses the greatest local tag, even when unrelated to HEAD.
        # Fetch only this pinned version tag; newer remote tags cannot change it.
        tag = repo["version_tag"]
        git(path, "fetch", "--no-tags", "--depth=1", "origin", tag["commit"])
        git(path, "tag", tag["name"], tag["commit"])
    for patch in repo["patches"]:
        git(path, *IDENTITY, "-c", "commit.gpgsign=false", "am", "--committer-date-is-author-date",
            LOCK.parent / patch["path"])
    verify_source(path, repo)
    if repo["submodules"]:
        git(path, "submodule", "update", "--init", "--recursive", "--",
            *(sub["path"] for sub in repo["submodules"]))
        for sub in repo["submodules"]:
            actual = git(path / sub["path"], "rev-parse", "HEAD", capture=True).strip()
            if actual != sub["commit"]:
                raise ValueError(f"submodule checkout mismatch: {sub['path']}")


def download(artifact, destination):
    if destination.exists() and digest(destination) == artifact["sha256"]:
        return
    pending = destination.with_suffix(destination.suffix + ".partial")
    with urllib.request.urlopen(artifact["url"]) as source, pending.open("wb") as target:
        shutil.copyfileobj(source, target)
    if digest(pending) != artifact["sha256"]:
        raise ValueError(f"download checksum mismatch: {artifact['url']}")
    pending.replace(destination)


def extract_bundle(archive, output):
    prefix = "red4ext/plugins/ArchiveXL/"
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            if not member.filename.startswith(prefix) or member.is_dir():
                continue
            relative = PurePosixPath(member.filename[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(f"unsafe archive path: {member.filename}")
            if relative.parts[0] != "Bundle" and str(relative) not in ("LICENSE", "THIRD_PARTY_LICENSES"):
                continue
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError(f"archive symlink: {member.filename}")
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.open(member) as source, target.open("wb") as dest:
                shutil.copyfileobj(source, dest)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def validate_binary(path):
    arches = run("lipo", "-archs", path, capture=True).strip().split()
    if arches != ["arm64"]:
        raise ValueError(f"expected arm64 binary: {path}")
    own_ids = run("otool", "-D", path, capture=True).splitlines()[1:]
    dependencies = run("otool", "-L", path, capture=True).splitlines()[1:]
    for entry in dependencies:
        dependency = entry.strip().split(" (", 1)[0]
        if dependency not in own_ids and not dependency.startswith(("/usr/lib/", "/System/")):
            raise ValueError(f"non-system dependency in {path.name}: {dependency}")
    run("codesign", "--force", "--sign", "-", path)
    run("codesign", "--verify", "--strict", path)


def build(args, lock):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("native builds require an Apple Silicon Mac")
    if sys.version_info < (3, 10):
        raise ValueError("SDK generation requires Python 3.10 or later")
    for tool in ("git", args.cmake, "ninja", "clang++", "xcrun", "xcodebuild", "codesign", "lipo", "otool"):
        if not shutil.which(tool):
            raise ValueError(f"required build tool not found: {tool}")
    xcode_version = run("xcodebuild", "-version", capture=True).strip()
    workspace = args.workspace.resolve()
    if workspace.exists():
        raise ValueError(f"workspace already exists; choose a new empty build location: {workspace}")
    workspace.mkdir(parents=True)
    sources = workspace / "sources"
    sources.mkdir()
    for repo in lock["repositories"]:
        prepare_source(sources / repo["name"], repo)
    (workspace / "sources.lock.json").write_bytes(LOCK.read_bytes())
    if args.prepare_only:
        print(f"Pinned sources and patches verified: {sources}")
        return

    sdk = sources / "RED4ext.SDK"
    generated = workspace / "sdk-2.5"
    run(sys.executable, sdk / "scripts/gen_macos_layouts.py", "--dump", sdk / lock["sdk_generation"]["dump"],
        "--define", lock["sdk_generation"]["define"], "--output-include", generated / "include",
        "--report", workspace / "sdk-layout-report.json")
    count, sha = include_digest(generated / "include")
    if count != lock["sdk_generation"]["include_files"] or sha != lock["sdk_generation"]["include_sha256"]:
        raise ValueError("generated SDK differs from the validated 2.5 headers; inspect sdk-layout-report.json")

    for repo in lock["repositories"]:
        if "build" not in repo:
            continue
        source = sources / repo["name"]
        destination = workspace / "build" / repo["name"]
        run(args.cmake, "-S", source, "-B", destination, "-G", repo["build"]["generator"],
            f"-DCMAKE_BUILD_TYPE={repo['build']['configuration']}",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_CXX_FLAGS=-DRED4EXT_GAME_VERSION_25",
            f"-DRED4EXT_SDK_DIR={generated}", "-DRED4EXT_GIT_METADATA=OFF")
        run(args.cmake, "--build", destination, "--parallel", args.jobs)
    ctest = str(Path(shutil.which(args.cmake)).with_name("ctest"))
    run(ctest, "--test-dir", workspace / "build/RED4ext", "--output-on-failure")

    output = workspace / "red4ext"
    copy(workspace / "build/RED4ext/libs/RED4ext.dylib", output / "RED4ext.dylib")
    copy(workspace / "build/RED4ext/bin/red4ext_plugin_check", output / "bin/red4ext_plugin_check")
    copy(sdk / "data/addresses/2.5.json", output / "bin/x64/cyberpunk2077_addresses.json")
    copy(ROOT / "runtime/native25/config.ini", output / "config.ini")
    for name in ("LICENSE.md", "THIRD_PARTY_LICENSES.md"):
        copy(sources / "RED4ext" / name, output / name)
    for name in ("TweakXL", "ArchiveXL"):
        plugin = output / "plugins" / name
        copy(workspace / "build" / name / f"{name}.dylib", plugin / f"{name}.dylib")
        shutil.copytree(sources / name / "scripts", plugin / "Scripts",
                        ignore=shutil.ignore_patterns("._*", ".DS_Store", "r6"))
        for license in ("LICENSE", "THIRD_PARTY_LICENSES"):
            copy(sources / name / license, plugin / license)
    shutil.copytree(sources / "TweakXL/data", output / "plugins/TweakXL/Data")
    # Keep optional input bindings beside the payload. The app's Creator does not use this hotkey.
    shutil.copytree(sources / "TweakXL/scripts/r6", workspace / "optional-game-files/r6")
    downloads = workspace / "downloads"
    downloads.mkdir()
    archive = downloads / "ArchiveXL-1.27.4.zip"
    download(lock["archive_bundle"], archive)
    extract_bundle(archive, output / "plugins/ArchiveXL")
    if digest(output / "plugins/ArchiveXL/Bundle/ArchiveXL.archive") != lock["archive_bundle"]["archive_sha256"]:
        raise ValueError("ArchiveXL resource archive checksum mismatch")
    binaries = [output / "RED4ext.dylib", output / "bin/red4ext_plugin_check",
                output / "plugins/TweakXL/TweakXL.dylib", output / "plugins/ArchiveXL/ArchiveXL.dylib"]
    for binary in binaries:
        validate_binary(binary)
    run(output / "bin/red4ext_plugin_check", output / "bin/x64/cyberpunk2077_addresses.json", *binaries[2:])
    build_info = {"source_manifest_sha256": digest(LOCK), "generated_sdk_sha256": sha,
                  "toolchain": {"python": platform.python_version(),
                                "xcode": xcode_version,
                                "cmake": run(args.cmake, "--version", capture=True).splitlines()[0]},
                  "files": {p.relative_to(output).as_posix(): digest(p)
                            for p in sorted(output.rglob("*")) if p.is_file()}}
    (output / "BUILD_INFO.json").write_text(json.dumps(build_info, indent=2) + "\n")
    (output / "sources.lock.json").write_bytes(LOCK.read_bytes())
    print(f"Native 2.5 payload ready. Set NATIVE25_DIR={output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=ROOT / "build/native25",
                        help="new build directory; existing directories are never overwritten")
    parser.add_argument("--cmake", default="cmake", help="CMake 3.26+ executable")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--prepare-only", action="store_true", help="fetch and verify sources, without compiling")
    parser.add_argument("--verify-sources", type=Path,
                        help="read-only check of existing RED4ext, RED4ext.SDK, TweakXL and ArchiveXL repositories")
    args = parser.parse_args()
    try:
        if args.jobs < 1:
            raise ValueError("--jobs must be positive")
        lock = read_manifest()
        if args.verify_sources:
            for repo in lock["repositories"]:
                verify_source(args.verify_sources / repo["name"], repo)
            print("Pinned source trees and patch checksums verified.")
        else:
            build(args, lock)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Native 2.5 build failed: {error}\n")


if __name__ == "__main__":
    main()
