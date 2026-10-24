# 1.6.0 local test candidate

Status: ready for manual Creator testing on macOS game 2.5.0. Not a validated public release yet.

## Second local candidate

The first manual test failed before writing weapon files: Creator incorrectly required
the native record getter to be registered in the static-function array. The real 2.5
RTTI table registers it as an instance function. The corrected code validates its
signature and passes the resolved player as the script executor's calling context.
The native wrapper itself ignores that object, but the executor requires it.

A read-only probe using the corrected call found `Items.Preset_Lexington_Default`
in the actual 2.5 menu session. Early startup probes were inconclusive because the
database was not loaded; the probe now waits for a menu/player context. The final
menu scenario exited normally with its checks passing, although the harness still
reported zero core-hook counters before the early exit. This proves the record
lookup, not inventory creation or hot reload. Manual Create & Apply remains pending.

The broader custom-stat scenario also reproduced a separate native near-allocation
failure with the full injected stack. That remains a release gate; a previous passing
run did not establish reliable custom-stat hook installation. The second Creator
candidate retains the existing native payload while this is investigated separately.

The candidate preserves the public 1.5.0 ZIP's game-2.3.1 native dependencies and
adds a separate 2.5 loader, address database, TweakXL and ArchiveXL. Codeware,
CET-Lua and Virtual Atelier development are outside this candidate's release scope.
See RELEASE-BUILD.md and ../native25/README.md for inputs and source provenance.

## Completed checks

- Creator bridge transaction tests cover preflight, reload/record errors, inventory
  acknowledgements, timeout, duplicate requests and stale process IDs.
- Custom-name JSON preservation and UTF-8 handling checks passed. Version-specific
  localization fingerprints match the retained 2.3.1 and installed 2.5 binaries.
- Loader CTest passed 5/5. Hook thread-exit and near-allocation regressions were
  reproduced before their fixes and passed repeated checks after them.
- Native TweakXL in-game scenario passed: new flat/record, record override,
  custom stat and scriptable tweak. This does not prove Creator gameplay.
- Full 2.5 boot with Frida, the new overlay, TweakXL, ArchiveXL and the launcher's
  flat-namespace environment reached Running/menu without a crash. The custom-name
  hook attached. This was a timed boot check terminated by the harness, not a
  gameplay or normal-quit test; many ArchiveXL hooks were not exercised.
- Launcher script-staging and compilation-gate checks passed; source typechecked.
  A 2.5 compiler error stops launch. Play detects stale core payload bytes.
- Explicit-input release assembly, native dependency inspection and local Developer
  ID signing passed. Installed test files matched the signed candidate byte-for-byte.
- All changes are local commits under ysrdevs. No push, release upload or notarization
  submission has been performed.

## Manual test now required

1. Use the prepared test launcher and click Play. It targets an isolated game copy;
   the game profile and saves were backed up before testing.
2. Load a save, open and close Inventory once, then open the console with F1 or `.
3. In Creator, choose a base weapon, a unique new name and effects, then Create & Apply.
4. Record the Creator status. Check the weapon appears exactly once, shows its custom
   name and Iconic identity, and can be equipped and fired with the selected effects.
5. If this works, save to a new manual slot, quit and relaunch through this candidate.
   Verify the weapon/name/effects persist after loading that slot.
6. Exercise the existing console, item browser, cheats and public mod-install workflow
   before claiming parity with the previous public build.

The isolated game path may display the launcher's Steam-only warning because it does
not contain “steamapps”; it is a copy of the Steam game. Do not change the folder to
the live development installation during this first test.

## Remaining release gates

Manual Creator and persistence results, public-feature smoke tests, and actual
2.3.1 runtime regression checks remain outstanding. Preserved 2.3.1 binaries and
static checks are not evidence of a new live 2.3.1 pass. The native source recipe's
patch replay and generated SDK hashes were verified; a fresh end-to-end orchestration
build has not yet been run. A final distribution package should be made only after
acceptance; the current app is signed locally but not notarized.
