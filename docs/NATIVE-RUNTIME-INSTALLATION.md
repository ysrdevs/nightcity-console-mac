# Native 2.5 production launcher integration

This source is a release integration checkpoint, not a released or gameplay-tested
2.0 package. The accepted 1.9 checkout and installations are unchanged.

The normal launcher selects native2.5 before installing or launching game 2.5.0.
A missing manifest, unsupported image, invalid native payload or missing package
preparation stops Play. It does not fall back to the old Frida backend. The existing
2.3.1 path remains separate. Switching a folder containing a native2.5 receipt to
2.3.1 requires first using Uninstall, which removes only unchanged owned files.

## Bundle contract

`Resources/native20/manifest.json` is application-owned JSON, schema 1:

- `backend`: `native2.5`; `gameVersion`: `2.5.0`.
- `executable`: `relativePath`, `uuid`, `textSHA256`. The fixed executable path is
  `Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077`. UUID and SHA-256 of its arm64
  Mach-O `__TEXT,__text` section must match, independent of a changed signature.
- `files`: bounded entries `{path, sha256, mode}`. Paths are game-relative and
  refer to bundled bytes at `native20/payload/<path>`. Mode is 420 or 493 decimal.
- `injectedDylibs`: exactly `red4ext/RED4ext.dylib` and
  `red4ext/NightCityFrontend.dylib`, in that order.
- `scriptRoots`: the installed `red4ext/plugins/NightCityRuntime/scripts` root.
- `environment`: explicit reviewed native profile/identity values, limited to
  `NCC_RUNTIME_PROFILE`, `NIGHTCITY_RUNTIME_PROBE`, `NCC_DISABLE_LEGACY_LUA` and
  optional `NCC_NATIVE_PROBE_HOTKEY`. The legacy Lua disable flag must be `1`.
- `previousFiles`: path to allowed prior SHA-256 values for explicit upgrade
  ownership. An unrecognized existing file is preserved and stops installation.
- `retiredFiles`: exact known prior files to remove, with their accepted hashes.
  Old Exploration wrappers must be retired before compiling the native ones.
- `requiresPreparedPackages`: whether launch requires the reviewed mod-package
  selection integration. A missing integration blocks launch, not just imports.

The core payload includes its compiler, native foundations, runtime, frontend and
scripts. Original third-party mod assets, settings, Creator definitions and saves
are not core-owned destinations. Packaging must not put private fixtures or
unlicensed mod payloads in a public release merely because a path is allowed.

## Install and recovery

`red4ext/nightcity/native-runtime-installed.json` records managed file hashes.
`native-runtime-pending.json` and `native-runtime-backups/<transaction>/` in the
same directory retain interrupted transaction evidence and original bytes.
Install/remove serialize through `native-runtime.lock`. All paths are checked for
links; regular inputs must not be hard links. Incoming files and every existing
conflict are checked before changing the runtime. Failed changes restore only
paths matching the recorded old/new hashes. Unknown edits block restoration and
retain the journal/backups. Play refuses a pending transaction. Install retries
recovery with the game closed. Backups are retained after success.

A complete 1.9 migration needs the exact previous payload hash allowlist. This
source does not infer ownership merely from a familiar filename. Unknown/manual
mods and player data remain outside the transaction.

## Launch preparation

The native launch builds a clean child environment and refuses inherited runtime
or injection controls. It verifies the exact image and installed inventory,
checks/stages native plugin declarations, compiles the user's scripts with the
runtime script root into `r6/cache/native20/final.redscripts`, and requires the
original game script cache to remain unchanged.

`NativeRuntimePackagePreparation.withLaunch` is the integration boundary for the
reviewed package manager. It must publish the immutable selected-package startup
snapshot and hold its selection lock while invoking the supplied launch closure.
It must not retry the closure after an uncertain spawn. Until that implementation
is bundled, `requiresPreparedPackages=true` refuses clearly before Play proceeds.

The native process receives the selected backend and the legacy Lua disable flag.
Its launcher log/exit record is under `red4ext/nightcity-native20/logs`; module data
and the prepared-launch snapshot use `red4ext/nightcity-native20`. Runtime-native
logs/status retain the installed plugin directory. No data is uploaded.

## Validation and remaining gates

`tools/test-native-runtime.sh` uses temporary synthetic images and payloads only:
installation, ownership conflicts, edited-file preservation, failed-write rollback,
persisted-interruption recovery, tampered recovery refusal, previous-version
migration, uninstall preservation, image mismatch, symlink/hardlink refusal,
clean environment and native-only injection. It never launches an app or game.

The full launcher Swift sources also pass type checking. Release-native runtime
and frontend identity/path configuration, current package preparation wiring,
actual clean/upgrade gameplay acceptance, signing and notarization remain separate
gates. A passing fixture cannot establish those outcomes.
