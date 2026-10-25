#!/usr/bin/env python3
"""Check optional package boundaries and actual installs in disposable folders."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", type=Path, required=True)
    parser.add_argument("--nctool", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    packaging = runpy.run_path(str(repository / "tools/prepare-optional-mods.py"))
    lock = json.loads((repository / "native25/optional-mods/sources.lock.json").read_text())
    command = [str(args.dotnet), str(args.nctool)]
    checks = []

    def hashes(root):
        return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob("*") if p.is_file()}

    def run(*arguments):
        result = subprocess.run(command + list(map(str, arguments)), capture_output=True, text=True)
        assert result.returncode == 0, (result.stdout, result.stderr)
        return result

    def rejected(path):
        try:
            packaging["verify"](path)
        except ValueError:
            return
        raise AssertionError("changed optional payload was accepted")

    with tempfile.TemporaryDirectory(prefix="nightcity-optional-check-") as temporary:
        root = Path(temporary)
        first, second = root / "first", root / "second"
        packaging["prepare"](first)
        packaging["prepare"](second)
        assert hashes(first) == hashes(second)
        assert (first / "manifest.json").read_bytes() == (repository / "native25/optional-mods/manifest.json").read_bytes()
        checks.append("deterministic ZIPs and manifest match the pinned outputs")
        manifest = json.loads((first / "manifest.json").read_text())
        assert manifest["game_version"] == "2.5.0" and len(manifest["mods"]) == 2
        assert {m["id"] for m in manifest["mods"]} == {"equipment-ex", "cyberware-ex"}
        checks.append("manifest targets only the two optional 2.5 cores; no VA or store package")
        extra = second / "final.redscripts"; extra.write_bytes(b"unexpected cache")
        rejected(second); extra.unlink()
        checks.append("extra cache or player files cannot enter the resource payload")
        package = second / manifest["mods"][0]["package"]
        original = package.read_bytes(); package.write_bytes(original + b"modified")
        rejected(second); package.write_bytes(original)
        checks.append("altered package is rejected")

        game = root / "game"
        info = game / "Cyberpunk2077.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.5.0"}))
        (game / "r6/scripts").mkdir(parents=True)
        protected = game / "red4ext/plugins/Codeware/Codeware.dylib"
        protected.parent.mkdir(parents=True); protected.write_bytes(b"native framework sentinel")
        baseline = hashes(game)
        installed = []
        for mod in manifest["mods"]:
            path = root / (mod["id"] + "-installed.json")
            run("install", first / mod["package"], game, path)
            record = json.loads(path.read_text())
            expected = next(m["installed_files"] for m in lock["mods"] if m["manifest"]["id"] == mod["id"])
            listed = {Path(p).relative_to(game).as_posix() for p in record["files"]}
            assert listed == set(expected), (mod["id"], listed ^ set(expected))
            for relative, sha in expected.items():
                assert hashlib.sha256((game / relative).read_bytes()).hexdigest() == sha, relative
            installed.extend(record["files"])
        assert len(installed) == 47 and len(set(installed)) == 47
        checks.append("both real optional ZIPs install all 47 accepted core files byte-for-byte")
        after = hashes(game); run("compat25", game); assert hashes(game) == after
        checks.append("combined installed packages remain unchanged by repeated compatibility checks")
        assert (game / "archive/Mac/mod/EquipmentEx.archive.xl").is_file()
        assert not (game / "red4ext/plugins/ArchiveXL/Bundle/EquipmentEx.archive.xl").exists()
        assert protected.read_bytes() == b"native framework sentinel"
        checks.append("Equipment XL stays with its archive and native framework files stay intact")
        # Mirror the launcher's path-manifest deletion; no directories or unrelated files are removed.
        for filename in installed:
            Path(filename).unlink()
        assert hashes(game) == baseline
        checks.append("uninstall manifests own exactly their 47 files and preserve unrelated inputs")
    print("\n".join("PASS: " + check for check in checks))
    print(f"{len(checks)} optional-package checks passed; no installed game was used.")


if __name__ == "__main__":
    main()
