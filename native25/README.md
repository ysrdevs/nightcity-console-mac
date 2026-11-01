# Native dependencies for Cyberpunk 2077 2.5

This directory records the accepted prebuilt native dependencies used by
NightCity Console 1.9.0. The Console launcher, overlay and command runtime are
built from this repository. The current macOS native framework adaptations are
maintained separately; their implementation sources and build recipe are not
included in this release tree. Publication in separate repositories is planned.

## Accepted profile

The 2.5 payload includes RED4ext, TweakXL, ArchiveXL, Input Loader, Mod Settings
and **Codeware's scoped UI, wardrobe and resource-event profile**. The private
development checkpoints cover VA 1.6.0, Cyberware-EX 1.5.6 default preset,
Equipment-EX 1.2.9 and Immersive Rippers 2.6.2 at Cassius Ryder. This is not full
Codeware world/entity/weather/quest/service-persistence support. Clipboard
functionality retains the existing limitation. Equipment-EX and Cyberware-EX are
available as separate optional packages; installing the native frameworks does
not enable them automatically. Virtual Atelier and store packs are downloaded
separately.

ArchiveXL retains the player-confirmed 1.7.1 save-loading fix. It
preserves the game's native sleeve suffix instead of querying attachment slots
again during suffix resolution, avoiding the reported loading lock. The other
1.9 changes add scoped resource/streaming support and correct the hidden-object
replacement involved in the reproduced below-map crash. This does not establish
compatibility for every clothing combination or world/quest mod.

`accepted-payload.json` records the 77 runtime input files for the 1.9 candidate,
including the verified macOS 15.5 source rebuilds. Release staging checks those
input bytes before copying anything. Final candidate gameplay testing remains
separate from the earlier development-build acceptance.
Staging preserves the tested plugin scripts and resources, adds license notices and
records input hashes. Private development metadata is excluded.
Signing later changes Mach-O signatures; the input manifest records the accepted
dependency bytes before release signing. A different native payload needs its own
testing and acceptance manifest before replacing these release inputs.

## Assemble the Console with prebuilt dependencies

Provide `NATIVE25_DIR` as a complete prebuilt runtime tree containing:

- `RED4ext.dylib`, `config.ini` and `bin/red4ext_plugin_check`;
- `bin/x64/cyberpunk2077_addresses.json` for game 2.5.0;
- `plugins/TweakXL`, `plugins/ArchiveXL` and `plugins/Codeware`, including each
  plugin's library, scripts, resources and license notices;
- `plugins/input_loader` with its native library and license notices (this plugin
  has no script payload), and `plugins/ModSettings` with its library, scripts and
  license;
- the Mod Settings companion archive and localization sidecar under
  `plugins/ArchiveXL/Bundle`.

The required files and exact input hashes are in
[`accepted-payload.json`](accepted-payload.json). Release assembly validates them
before replacing its staging directory. A signed release app may have different
library hashes because signing changes those files; extracting arbitrary signed
libraries is not a substitute for the accepted input checkpoint.

See [release assembly instructions](../docs/RELEASE-BUILD.md) for the baseline
ZIP, native dependency tree and installer-helper inputs. The public 2.3.1
dependencies are extracted separately from the pinned 1.5.0 ZIP and remain
byte-identical, including their existing signatures and macOS 26/27 deployment
targets. They are not installed by the 2.5 path. The shared tools and 2.5 native
runtime target macOS 15.5; the development host is macOS 27, so an older-OS live
test is not claimed. This repository does not currently provide a complete source rebuild
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
