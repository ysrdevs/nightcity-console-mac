# Native dependencies for Cyberpunk 2077 2.5

`sources.lock.json` and `patches/` preserve the native source inputs for NightCity Console's 2.5 player build. A clean checkout can rebuild these dependencies without the original developer directories or an installed game. The public 2.3.1 binaries remain a separate, preserved compatibility input.

The upstream macOS ports and their authors retain their history and attribution. The patch series contains only NightCity's local commits by ysrdevs:

| Component | Pinned upstream | Local changes |
| --- | --- | --- |
| [RED4ext](https://github.com/fentz26/RED4ext-macos) | `a70a5e4e70deeb46ab5671abb4b448605677e744` | Host application library paths for background tests; retry hook transactions when threads exit; keep hook island searches inside the ARM64 branch window; diagnose exhausted allocation windows and use a guarded absolute hook fallback |
| [RED4ext.SDK](https://github.com/fentz26/RED4ext.SDK-macos) | `64c1cd0095084ebbed65e725d1f9bc589d7a6e73` | None; generate the 2.5 layouts from its committed RTTI dump |
| [TweakXL](https://github.com/fentz26/cp2077-tweak-xl-macos) | `040d54cabf5a6b5fa46453d59537dc236d8fa0ea` | Preserve the launcher's staged scripts between launches |
| [ArchiveXL](https://github.com/fentz26/cp2077-archive-xl-macos) | `fcfc94a2cf23cdee51e267377977f0ac4693f2a0` | Preserve the launcher's staged scripts between launches |

The manifest records every local patch's original commit and SHA-256, the resulting Git tree, and the macOS build submodule pins. It excludes Windows-only dependencies and the unused vendor SDKs. Both plugins' pinned CMake sources fetch spdlog 1.16.0 and yaml-cpp 0.8.0 with SHA-256 verification; the same pins are listed in the manifest for review.

The RED4ext series includes allocation diagnostics (`5dcda66`) and the absolute-hook fallback (`27566e1`). When the near and ADRP allocation windows are exhausted, the fallback uses a 16-byte entry patch after validating function boundaries, relocation, page boundaries, interior branches and return addresses. Its forced-exhaustion regression tests ship in the patch. Source replay and CTest results do not replace a live check of the final payload under the complete injected stack.

## Build

Use an Apple Silicon Mac with Xcode command line tools, Python 3.10 or later, CMake 3.26 or later, Ninja and Git on `PATH`. The SDK layout generator invokes the local compiler. Internet access is needed for the pinned source commits, submodules, dependency archives and ArchiveXL resource bundle.

From the Console repository:

```sh
python3 tools/build-native25.py --workspace build/native25 --jobs 4
```

Use `--cmake /path/to/cmake` when CMake is not on `PATH`. The workspace must not already exist: the script creates only its own source/build/output directories and never resets an existing checkout. `--prepare-only` fetches, patches and verifies sources without compiling. To perform a full build afterwards, choose a fresh workspace. `--verify-sources /path/to/native-sources` checks an existing set of four repositories without writing to them.

The script:

1. Fetches exact upstream commits, applies the checked local patches with `git am`, and verifies the resulting trees. Patch application preserves authors. The new commit IDs can differ because committer metadata differs; the checked source trees must match exactly.
2. Initializes only the pinned macOS submodules and generates a shared SDK with `data/rtti_layout_macos_25.json`, `RED4EXT_GAME_VERSION_25`, and `--output-include`. It checks all 10,270 generated include files against the recorded aggregate SHA-256. A compiler-dependent layout change stops the build for review.
3. Builds RED4ext with Ninja / RelWithDebInfo, and TweakXL and ArchiveXL with Makefiles / Release, matching the validated build configurations. All use ARM64 and `-DRED4EXT_GAME_VERSION_25`. RED4ext's version tag is pinned to 1.29.1; timestamp/branch version metadata is disabled to avoid incidental differences.
4. Runs the loader's CTest suite, stages scripts and TweakXL data, and downloads the official ArchiveXL 1.27.4 resource bundle with ZIP and archive checksums. `ArchiveXL.archive` is an upstream asset built with WolvenKit, not rebuilt by this macOS script.
5. Checks ARM64 architecture and system-only dynamic dependencies, signs the output ad hoc, and runs the native plugin checker against the exact 2.5 address database.

The generated `build/native25/red4ext` is the `NATIVE25_DIR` input accepted by `tools/fetch-deps.sh` in release mode. It contains the loader, plugin checker, canonical addresses, configuration, TweakXL and ArchiveXL with their scripts/data/resources/licenses, and source/build manifests. TweakXL's optional reload-key input XML is kept separately at `optional-game-files/r6/input/tweakxl.xml`; NightCity's Creator uses its own reload call. Codeware, Virtual Atelier and CET-Lua are not built or staged.

For the complete app, supply the remaining explicit inputs described in [the release build instructions](../docs/RELEASE-BUILD.md). The native build never installs into or launches the game and never uploads anything.

## Verification boundary

The source trees and patch replay were verified locally. The loader and plugins were built separately from those same source trees during 2.5 testing; the full clean-download orchestration script still needs its own end-to-end run. CTest and the plugin checker do not establish Creator success in a running game. That acceptance requires a new weapon record, an inventory quantity increase, the custom name and text, and persistence after restart.

This is a reproducible source recipe, not a promise of byte-identical signed binaries across Xcode/macOS versions. The validated generated headers came from Xcode 27.1 (27A9269). `BUILD_INFO.json` records the actual toolchain, source-manifest hash, generated SDK hash and output hashes for each completed build.

To update a dependency, pin a reviewed upstream SHA, regenerate only the local patch series, update the expected patched tree and checksums, rebuild, then repeat offline and in-game acceptance. Do not replace pins with moving branches or package a dirty checkout.
