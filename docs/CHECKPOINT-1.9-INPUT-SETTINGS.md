# Private 1.9 Input Loader and Mod Settings checkpoint

Accepted on 31 October 2026 for native macOS Cyberpunk 2077 2.5.
This records the tested private development build, not a public release.
The earlier Immersive Rippers restore point remains separate and unchanged.

## Tested flows

- Native Input Loader merges the test input mapping without changing the
  original game input files. The custom action responds in gameplay.
- Mod Settings displays boolean, integer, slider, enum and keybinding controls.
  The user applied changes and exercised rebinding from F6 to F7 and F8.
- A full game quit/relaunch preserved the user's final selection of F7 and
  Number 7. The new process loaded the saved settings and the user confirmed
  the rebound key displayed the correct value.
- Virtual Atelier Instant Buy was enabled through Mod Settings, persisted
  across relaunch and worked for actual purchases.
- The same native build passed the existing Equipment-EX outfit, Cyberware-EX
  second operating system, Creator create/equip/fire, and noclip Stop checks.
- A subsequent packaging-only build installed the Mod Settings archive and
  localization sidecar automatically through ArchiveXL's Bundle directory.
  The old manually installed archive was backed up outside the game and removed
  before this test. A fresh process passed the menu, labels, saved controls,
  F7 notification and Virtual Atelier instant purchase checks.

Five native plugins and all 110 hooks loaded in the accepted sessions, with
no new fault or crash recorded. Installation hashes matched the signed app.
All 233 preserved nonlog baseline files matched in both the accepted Rippers
game and the isolated Input Settings game.

## Preserved state

The native ports and asset-building helper are committed in private local
repositories. Their source bundles and detailed test evidence remain private.
The helper verifies the original inputs, converter components and all four
extracted resource IDs and byte hashes before staging the companion assets.
Archive container timestamps may differ; each actual output hash is recorded.

This checkpoint retains the harmless private test controls and input mapping.
They are separate from the production plugin payload. No files were changed
in the running game after the final acceptance report.

## Remaining scope

This acceptance covers the tested controls and mod flows. Cancel and Restore
Defaults have not received an explicit gameplay check. CName and Uint32 setting
properties are rejected with diagnostics rather than treated as supported.

One earlier flight session recovered to its latest clear position after an
unexpected movement-state exit inside a building. Recovery completed without
an unresolved arrival or collision-restoration flag, but the exact trigger is
unknown. The new dependencies did not change the accepted flight scripts.

The private build is Developer ID signed and has not been newly notarized.
The complete framework bundle still needs its release deployment-target audit,
test-fixture cleanup and release validation before public packaging. This
checkpoint does not establish compatibility with every dependency-based mod.
