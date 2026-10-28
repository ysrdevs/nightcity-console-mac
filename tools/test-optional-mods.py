#!/usr/bin/env python3
"""Check optional package boundaries and actual installs in disposable folders."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", type=Path, help="Host for an nctool DLL; omit when --nctool is the native executable")
    parser.add_argument("--nctool", type=Path, required=True, help="Native nctool executable, or DLL when --dotnet is supplied")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("optional_packaging", repository / "tools/prepare-optional-mods.py")
    packaging = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packaging)
    lock = json.loads((repository / "native25/optional-mods/sources.lock.json").read_text())
    if not args.nctool.is_file() or (args.dotnet is None and not os.access(args.nctool, os.X_OK)):
        parser.error("--nctool must identify an existing helper (executable unless using --dotnet)")
    command = ([str(args.dotnet)] if args.dotnet else []) + [str(args.nctool)]
    helper_before = hashlib.sha256(args.nctool.read_bytes()).hexdigest()
    lock_before = (repository / "native25/optional-mods/sources.lock.json").read_bytes()
    checks = []

    def hashes(root):
        return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob("*") if p.is_file()}

    def run(*arguments):
        result = subprocess.run(command + list(map(str, arguments)), capture_output=True, text=True, cwd=root, timeout=30)
        assert result.returncode == 0, (result.stdout, result.stderr)
        return result

    def rejected(path):
        try:
            packaging.verify(path)
        except (ValueError, OSError):
            return
        raise AssertionError("changed optional payload was accepted")

    with tempfile.TemporaryDirectory(prefix="nightcity-optional-check-") as temporary:
        root = Path(temporary)
        first, second = root / "first", root / "second"
        packaging.prepare(first)
        packaging.prepare(second)
        assert hashes(first) == hashes(second)
        assert (first / "manifest.json").read_bytes() == (repository / "native25/optional-mods/manifest.json").read_bytes()
        assert len(hashes(first)) == 50 and not list(first.rglob("*.zip"))
        checks.append("deterministic unpacked folders and schema2 manifest match the pinned 50-file output")
        manifest = json.loads((first / "manifest.json").read_text())
        assert manifest["schema"] == 2 and manifest["game_version"] == "2.5.0" and len(manifest["mods"]) == 2
        assert {m["id"] for m in manifest["mods"]} == {"equipment-ex", "cyberware-ex"}
        for mod in manifest["mods"]:
            source = next(m for m in lock["mods"] if m["manifest"]["id"] == mod["id"])
            assert mod["package"] == f"{mod['id']}-{mod['version']}" and "sha256" not in mod
            assert hashes(first / mod["package"]) == mod["files"]
            expected = source["files"] if mod["id"] == "cyberware-ex" else source["installed_files"]
            assert mod["files"] == expected
        checks.append("manifest targets only the two optional 2.5 cores; no VA or store package")
        checks.append("Cyberware source stays pristine; Equipment retains only its accepted byte-preserving transform")
        extra = second / "final.redscripts"; extra.write_bytes(b"unexpected cache")
        rejected(second); extra.unlink()
        extra.mkdir(); rejected(second); extra.rmdir()
        checks.append("extra cache or player files cannot enter the resource payload")
        mod = manifest["mods"][0]
        package_file = second / mod["package"] / next(iter(mod["files"]))
        original = package_file.read_bytes(); package_file.write_bytes(original + b"modified")
        rejected(second); package_file.unlink(); rejected(second); package_file.write_bytes(original)
        checks.append("altered and missing package files are rejected")
        outside = root / "outside.txt"; outside.write_bytes(original)
        package_file.unlink(); package_file.symlink_to(outside); rejected(second); package_file.unlink(); package_file.write_bytes(original)
        ancestor = root / "alias"; ancestor.symlink_to(root, target_is_directory=True)
        packaging.verify(ancestor / "second")
        packaging.prepare(ancestor / "allowed-output")
        packaging.verify(ancestor / "allowed-output")
        ancestor.unlink()
        root_link = root / "payload-link"; root_link.symlink_to(second, target_is_directory=True)
        rejected(root_link); root_link.unlink()
        intermediate = second / mod["package"] / "r6"
        moved = root / "moved-r6"; intermediate.rename(moved)
        intermediate.symlink_to(moved, target_is_directory=True)
        rejected(second); intermediate.unlink(); moved.rename(intermediate)
        assert outside.read_bytes() == original
        checks.append("payload-root, intermediate and file links are rejected while ordinary outer aliases are accepted")

        previous_hashes = hashes(second)
        shadow = root / "source-fixture"
        shutil.copytree(packaging.ROOT, shadow)
        original_root, original_lock = packaging.ROOT, packaging.LOCK
        packaging.ROOT, packaging.LOCK = shadow, shadow / "sources.lock.json"
        try:
            source_file = shadow / "source" / mod["id"] / next(iter(mod["files"]))
            source_original = source_file.read_bytes()
            source_file.write_bytes(source_original + b"tampered")
            try:
                packaging.prepare(second)
            except ValueError:
                pass
            else:
                raise AssertionError("modified pinned source was accepted")
            assert hashes(second) == previous_hashes
            source_file.unlink()
            try:
                packaging.expected_payload()
            except (ValueError, OSError):
                pass
            else:
                raise AssertionError("missing pinned source was accepted")
            source_file.write_bytes(source_original)
            source_extra = source_file.parent / "extra.reds"
            source_extra.write_text("unlisted")
            try:
                packaging.expected_payload()
            except ValueError:
                pass
            else:
                raise AssertionError("unlisted source was accepted")
            source_extra.unlink()
            source_file.unlink(); source_file.symlink_to(outside)
            try:
                packaging.expected_payload()
            except ValueError:
                pass
            else:
                raise AssertionError("linked source was accepted")
            source_file.unlink(); source_file.write_bytes(source_original)
            link = root / "source-alias"; link.symlink_to(shadow, target_is_directory=True)
            packaging.ROOT, packaging.LOCK = link, link / "sources.lock.json"
            try:
                packaging.expected_payload()
            except ValueError:
                pass
            else:
                raise AssertionError("linked source ancestor was accepted")
            link.unlink()
        finally:
            packaging.ROOT, packaging.LOCK = original_root, original_lock
        checks.append("missing, changed, extra and linked sources fail before replacing a valid output")
        for unsafe in ["", "/absolute", "../escape", "a/../b", "a//b", "a/./b", "a\\b", "a\x00b", "a/", "x" * 513]:
            try:
                packaging.safe_path(unsafe)
            except ValueError:
                pass
            else:
                raise AssertionError(f"unsafe relative path accepted: {unsafe!r}")
        for name in ["MAX_FILES", "MAX_ENTRIES", "MAX_FILE_BYTES", "MAX_TOTAL_BYTES"]:
            old = getattr(packaging, name)
            setattr(packaging, name, 1)
            try:
                rejected(second)
            finally:
                setattr(packaging, name, old)
        extra = second / "preserve.txt"; extra.write_text("unrelated")
        try:
            packaging.prepare(second)
        except ValueError:
            pass
        else:
            raise AssertionError("unowned output was replaced")
        assert extra.read_text() == "unrelated"; extra.unlink()
        checks.append("unsafe relative paths and bounded tree sizes fail closed; unknown output content is kept")

        game = root / "game"
        info = game / "Cyberpunk2077.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.5.0"}))
        (game / "r6/scripts").mkdir(parents=True)
        protected = game / "red4ext/plugins/Codeware/Codeware.dylib"
        protected.parent.mkdir(parents=True); protected.write_bytes(b"native framework sentinel")
        unrelated = game / "r6/scripts/unrelated.reds"; unrelated.write_bytes(b"// unrelated mod sentinel\n")
        baseline = hashes(game)
        bundle_before = hashes(first)
        installed, receipts = [], []
        for mod in manifest["mods"]:
            path = game / "red4ext/nightcity/mods" / (mod["package"] + ".json")
            result = run("install", first / mod["package"], game, path)
            assert "[install] unzipped" not in (result.stdout + result.stderr).lower()
            record = json.loads(path.read_text())
            assert path.stem == f"{mod['id']}-{mod['version']}"
            expected = next(m["installed_files"] for m in lock["mods"] if m["manifest"]["id"] == mod["id"])
            listed = {Path(p).relative_to(game).as_posix() for p in record["files"]}
            assert listed == set(expected), (mod["id"], listed ^ set(expected))
            for relative, sha in expected.items():
                assert hashlib.sha256((game / relative).read_bytes()).hexdigest() == sha, relative
            installed.extend(record["files"])
            receipts.append(path)
        assert len(installed) == 47 and len(set(installed)) == 47
        assert hashes(first) == bundle_before
        assert not list(root.rglob("*unzipped*"))
        checks.append("both actual folder installs deploy all 47 accepted core files without extraction or bundle mutation")
        checks.append("explicit managed receipt filenames retain complete 1.2.9 and 1.5.6 versions")
        after = hashes(game); run("compat25", game); assert hashes(game) == after
        checks.append("combined installed packages remain unchanged by repeated compatibility checks")
        assert (game / "archive/Mac/mod/EquipmentEx.archive.xl").is_file()
        assert not (game / "red4ext/plugins/ArchiveXL/Bundle/EquipmentEx.archive.xl").exists()
        assert protected.read_bytes() == b"native framework sentinel"
        checks.append("Equipment XL stays with its archive and native framework files stay intact")
        # Mirror the launcher's path-manifest deletion; no directories or unrelated files are removed.
        for filename in installed:
            Path(filename).unlink()
        for path in receipts:
            path.unlink()
        assert hashes(game) == baseline
        checks.append("uninstall manifests own exactly their 47 files and preserve unrelated inputs")
    assert hashlib.sha256(args.nctool.read_bytes()).hexdigest() == helper_before
    assert (repository / "native25/optional-mods/sources.lock.json").read_bytes() == lock_before
    checks.append("existing native/.NET helper bytes and historical source/archive lock remain unchanged")
    print("\n".join("PASS: " + check for check in checks))
    print(f"{len(checks)} optional-package checks passed; no installed game was used.")


if __name__ == "__main__":
    main()
