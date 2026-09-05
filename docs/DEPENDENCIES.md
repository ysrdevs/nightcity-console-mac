# Runtime dependencies

The current launcher bundles `RED4ext.dylib`, `FridaGadget.dylib`, TweakXL, ArchiveXL,
`config.ini`, and `cyberpunk2077_addresses.json`. Plugins also need their sibling
libraries. Upstream already tracks its pinned TweakXL and three sibling libraries in
`deps/`; other imported binaries remain ignored by Git. The dependency script fills gaps
without overwriting that pinned build or any existing user-supplied binaries. It does
not download files automatically or verify runtime compatibility merely by finding them.

## First build from a clean checkout

Download **NightCity-Console-for-Mac.zip** from the official
[v1.5.0-beta.2 release](https://github.com/ysrdevs/nightcity-console-mac/releases/tag/v1.5.0-beta.2).
This is the archive used for the tested GOG macOS v2.3.1 console and reset commands.
Then run:

```bash
./tools/fetch-deps.sh --from-zip "$HOME/Downloads/NightCity-Console-for-Mac.zip"
./launcher/build-app.sh
```

The importer verifies the entire ZIP against the release asset SHA-256 before importing
the missing runtime files, configs, and TweakXL/ArchiveXL sibling libraries. It does not
execute the downloaded app or install anything into the game. Existing files in `deps/`
are preserved, including upstream's tracked TweakXL build. The ZIP option is intentionally
pinned to this release and rejects other archives. A fresh checkout plus this ZIP reproduces
the build inputs; it does not imply the older ZIP contains every feature from current main.

The release ZIP does **not** include the newer redscript compiler. For Steam script mods,
provide compatible `scc` and `libscc_lib.dylib` files through `SCC_SRC=/path/to/engine/tools`.
The dependency check reports their absence as a warning, consistent with the launcher's
optional compiler support. Similarly, the newer drag-and-drop mod installer is built from
`NCTOOL_SRC=/path/to/nctool`; when that source is absent, the build reports that the helper
is unavailable. Neither optional tool is required for the GOG console.

Without `--from-zip`, the script fills missing files from `CP2077_DIR` if set; otherwise
it checks the default Steam and GOG installations. This only works if NightCity Console
is already installed there. For example:

```bash
CP2077_DIR="/Applications/Cyberpunk 2077" ./tools/fetch-deps.sh
```

## Verified provenance of the original GOG setup

Archive SHA-256 (matches the official GitHub release asset digest):

```text
19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151
```

Paths below are relative to `NightCity Console.app/Contents/Resources/` inside the ZIP:

| Dependency | Archive path | SHA-256 of extracted file |
|---|---|---|
| RED4ext | `RED4ext.dylib` | `ae94730a81d7b9ece32579dec5922198f6b0b9064396b6aaf52037d2753f09da` |
| Frida Gadget | `FridaGadget.dylib` | `b179993600ef63a41c483ca4067567b40da7785480c55ae66eac095dcdcedf8f` |
| TweakXL | `plugins/TweakXL/TweakXL.dylib` | `8599e7de0cea311ac697e3b866044f10ca411f590b6fa6052a80393f9e41b9ee` |

These are the original three files used on the earlier GOG branch, before rebasing onto
current main. Current upstream tracks a different TweakXL build (commit `b87a823`), which
the importer deliberately preserves. Its SHA-256 is:

```text
6b0d5e5c910c5c5d7aacc349bc464285c0826b1f7d7936d2a5a3f0590f583a1d
```

RED4ext and TweakXL are arm64 binaries; the Frida Gadget is a universal binary that
includes arm64. Replacing these with arbitrary current releases is not covered by the
GOG testing reported here.

## Optional TweakXL limitations

The build bundles TweakXL for Steam mod/Creator features. The GOG launch path uses Frida
Gadget and the overlay directly, without loading RED4ext or its plugins. Both the original
ZIP's TweakXL and upstream's tracked replacement target **macOS 27** and link three siblings:

- `libspdlog.1.17.dylib`
- `libfmt.12.dylib`
- `libyaml-cpp.0.9.dylib`

On the earlier GOG branch, only `TweakXL.dylib` was copied. It failed to load on the tested
macOS 26.6.2 machine while console commands worked. Current upstream packages complete
plugin folders; the updated packaging prefers local sibling libraries, then imported
release siblings, then Homebrew. This resolves the incomplete packaging but not the
macOS 27 runtime requirement. Advanced GOG mod support and macOS 26-compatible plugin
builds still need separate work and are not claimed by this contribution.

## Verification without launching the game

With Node.js installed, run `node tools/test-gog-support.mjs /path/to/NightCity-Console-for-Mac.zip`.
The tests exercise store detection using fixture bundles, both reset handlers using mocked
engine objects, and clean dependency import, checksum rejection, and existing-file preservation.
They use temporary directories and do not install into or launch a game.
