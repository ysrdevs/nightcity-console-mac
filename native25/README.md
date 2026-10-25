# Native dependencies for Cyberpunk 2077 2.5

This directory records the accepted prebuilt native dependencies used by
NightCity Console 1.7.0. The Console launcher, overlay and command runtime are
built from this repository. The current macOS native framework adaptations are
maintained separately; their implementation sources and build recipe are not
included in this release tree. Publication in separate repositories is planned.

## Accepted profile

The 2.5 payload includes RED4ext, TweakXL, ArchiveXL and **Codeware's scoped UI
profile with the verified wardrobe method**. It supports the player-tested VA 1.6.0,
Cyberware-EX 1.5.6 default preset and Equipment-EX 1.2.9 flows. This is not full
Codeware world/entity/weather/quest/service-persistence support. Clipboard
functionality retains the existing limitation. Equipment-EX and Cyberware-EX are
available as separate optional packages; installing the native frameworks does
not enable them automatically. Virtual Atelier and store packs are downloaded
separately.

`accepted-payload.json` records the 52 runtime files from the accepted combined
checkpoint. Release staging checks those input bytes before copying anything.
It preserves the tested plugin scripts and resources, adds license notices and
records input hashes. Private development metadata is excluded.
Signing later changes Mach-O signatures; the input manifest records the accepted
dependency bytes before release signing. A different native payload needs its own
testing and acceptance manifest before replacing these release inputs.

## Assemble the Console with prebuilt dependencies

Provide `NATIVE25_DIR` as a complete prebuilt runtime tree containing:

- `RED4ext.dylib`, `config.ini` and `bin/red4ext_plugin_check`;
- `bin/x64/cyberpunk2077_addresses.json` for game 2.5.0;
- `plugins/TweakXL`, `plugins/ArchiveXL` and `plugins/Codeware`, including each
  plugin's library, scripts, resources and license notices.

The required files and exact input hashes are in
[`accepted-payload.json`](accepted-payload.json). Release assembly validates them
before replacing its staging directory. A signed release app may have different
library hashes because signing changes those files; extracting arbitrary signed
libraries is not a substitute for the accepted input checkpoint.

See [release assembly instructions](../docs/RELEASE-BUILD.md) for the baseline
ZIP, native dependency tree and installer-helper inputs. The public 2.3.1
dependencies are extracted separately from the pinned 1.5.0 ZIP and remain
unchanged. This repository does not currently provide a complete source rebuild
of the macOS native frameworks.

The plugin `.reds` files, address database and ArchiveXL resources are required
runtime content and remain in the distributed app. All bundled components retain
their own licenses; see [third-party notices](../THIRD_PARTY_LICENSES.md).

## Mod installation compatibility

`modcompat/` contains only the small compatibility changes, exact guards, source
snapshot and notices for the installer helper. The helper applies the tested
Cyberware 1.5.6 method changes and Equipment 1.2.9 restoration-loop fix when a
supported package is installed, and checks already installed mods before 2.5
compilation. It refuses unknown versions, duplicates or edited target methods
instead of replacing them. The original 2.3.1 path is unchanged.

See [the helper source and test recipe](modcompat/README.md) and the
[mod installation guide](../docs/MOD-INSTALLATION.md). The release assembly
workflow builds the app without installing into or launching a game.

The [optional package recipe](optional-mods/README.md) preserves the two MIT core
packages, notices and exact installation hashes. These are offered only for 2.5;
the existing public 2.3.1 framework payload remains unchanged.
