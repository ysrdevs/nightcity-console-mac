# Optional mods for the native 2.5 profile

Equipment-EX 1.2.9 and Cyberware-EX 1.5.6 are optional choices. They are not
installed with the native frameworks automatically and are offered only for
game 2.5.0. Virtual Atelier and store packs are not part of these packages.

`manifest.json` is the launcher contract. Its paths are relative to the app's
`Contents/Resources/optional-mods` directory. Schema 2 contains `game_version`
and two `mods` entries with stable IDs, display names, versions, folder paths,
per-file SHA-256 hashes, MIT notice paths, source URLs and installed script
directories. The folders are `equipment-ex-1.2.9` and `cyberware-ex-1.5.6`.
Each `files` entry maps a path relative to its package folder to the bundled
file's hash. The launcher checks the game version and the entire folder before
invoking its existing folder installation and compatibility flow. Each package
uses the existing nctool path manifest for removal, retaining its complete
version in the manifest filename.

## Preserved inputs

`sources.lock.json` records every source file and expected installed file hash,
the upstream revisions and historical archive hashes. Those provenance records
remain unchanged. Only these 47 core files may enter the package folders:

- Equipment-EX: six files from the pinned 1.2.9 release ZIP, including its archive,
  adjacent XL metadata, two script bundles, compiler hints and MIT license.
  The archive paths are adapted to `archive/Mac/mod`. The accepted one-character
  restoration-loop fix is applied during packaging, preserving the source's
  mixed line endings. No other script or asset changes are made.
- Cyberware-EX: 40 pristine scripts from upstream commit
  `855d9a42eecdb635d5c9d15e6949107b9b3b1b00`, plus its MIT license. The existing
  installer applies the two verified 2.5 method adaptations. This is the tested
  default configuration; no separate Extended, Override, Customization or Reset
  addon is included.

Both MIT copyright and permission notices are retained in the source,
standalone app license files and installed script directories. There are no
vanilla game files, compiled caches, native plugins, saves, player data, custom
weapons, VA resources or store definitions here.

## Reproduce and verify

```sh
python3 tools/prepare-optional-mods.py --output build/optional-mods
python3 tools/prepare-optional-mods.py --verify build/optional-mods
python3 tools/test-optional-mods.py \
  --nctool '/path/to/NightCity Console.app/Contents/Resources/nctool/nctool'
# Alternatively, use an existing .NET host and helper DLL:
python3 tools/test-optional-mods.py --dotnet /path/to/dotnet \
  --nctool build/nctool-1.7.0/nctool.dll
```

The builder copies the pinned runtime bytes directly into folders and generates
the sorted per-file manifest. It never creates a ZIP, including in memory or
temporary staging. Repeated builds reproduce identical file contents without
network or installed-game input. Release staging calls the same builder, and
bundle validation checks exactly 50 files: 47 core files, two standalone MIT
notices and the manifest. Missing, extra, changed, linked or oversized contents
are rejected. Link checks cover the payload root and every descendant, while
normal operating-system aliases outside that root remain usable.

The isolated installation checks create disposable game directories. Both
folders install all 47 files matching the accepted snapshots byte for byte,
without archive extraction or changes to the bundled source folders.
Compatibility is idempotent, Equipment's XL stays beside its archive, and the
removal manifests preserve unrelated files. Existing native and .NET helper
files are unchanged. These checks cover packaging and installation. Separate
player tests confirmed Equipment-EX outfit management
and Cyberware-EX's default extra operating-system slot and abilities, including
save/relaunch persistence alongside Virtual Atelier. See the
[mod installation guide](../../docs/MOD-INSTALLATION.md) for the supported
versions and configuration.
