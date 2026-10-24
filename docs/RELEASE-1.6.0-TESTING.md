# 1.6.0 release validation

Status: All requested local release checks passed on macOS game 2.5.0, including
Creator acceptance, the native allocation gate, the user's fourth-candidate gameplay
checks, and ZIP/DMG validation. The accepted packages are promoted unchanged; no
rebuild or re-signing is needed. This validates the tested features below, not every
cheat or third-party mod workflow. The app is Developer ID signed but not notarized.

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
lookup by itself, not inventory creation or hot reload.

The subsequent user test confirmed "Weapon created and works." The generated
Crit Machine YAML and runtime localization hits corroborate the new weapon and its
custom text. However, the runtime response reported inventory-confirmation timeout
after GiveItem. This was a false-negative status problem: the user's
visible result is successful creation, while the automatic quantity check did not
confirm it. No second item should be given to work around this timeout. A new-slot
save/relaunch persistence check subsequently passed: the user reported "Everything
persists and works" for custom name, Iconic identity/effects and equip/fire behavior.

Commit `9437697` fixes the quantity check to use the game's `ItemID.CreateQuery`
wildcard identity, while retaining one unique ItemID for GiveItem. Constructor and
inventory-matching semantics were verified in the 2.5 binary; focused tests cover
the previously failing unique-weapon case. The separately signed third candidate
changes only runtime JavaScript resources, preserving all other test2 resources
byte-for-byte. The user installed it and confirmed the success message without a
timeout, exactly one added weapon, and the previous weapon still present. The
runtime response corroborates `ok: true`, `before: 0`, `after: 1`, with the query
using wildcard seed 1 and GiveItem using a distinct unique instance seed.

The broader custom-stat scenario also reproduced a separate native allocation
failure with the full injected stack. The near and ADRP branch windows could both
be occupied by the time a late hook was installed. Native commit `27566e1` adds a
guarded 16-byte absolute branch fallback; source-recipe commit `d8a798c` preserves
the exact patches and source tree. The checks below close this observed allocation
gate without claiming that every plugin path has been exercised.

The candidate preserves the public 1.5.0 ZIP's game-2.3.1 native dependencies and
adds a separate 2.5 loader, address database, TweakXL and ArchiveXL. Codeware,
CET-Lua, Virtual Atelier development and save-editor changes are outside this release.
See RELEASE-BUILD.md and ../native25/README.md for inputs and source provenance.

## Fourth candidate and native allocation validation

The signed fourth candidate copies the accepted third candidate. Only the
2.5 loader and its source/input provenance change, followed by signing the replacement
dylib and resealing the outer app. The runtime JavaScript, overlay, launcher code,
other native dependencies and retained 2.3.1 payload are preserved. Signature bytes
changed when the outer app was resealed. All 303 final files are recorded in the
candidate's `signed-app-sha256.json`; `changes-from-test3.json` records exactly six
changed/added paths: the loader, source lock, new build metadata, input provenance,
and the two outer signature-bearing files. No other payload bytes changed.

The installed core files match the signed candidate. Both previously created
weapon YAML files and the custom-name map were verified unchanged after Install.
The signed loader SHA-256 is
`4e08ad904005008e9843070c218cc9ec46e60cbc7701e761955657cc6103784f`.
The app passed strict deep signature verification and native dependency inspection.
Its build metadata explicitly records manual assembly from separately built native
components, rather than claiming a fresh end-to-end recipe build.

Local evidence is recorded in `release-evidence/native-allocation/live-validation.json`:

- Fresh full-stack TweakXL runs `20261024-053107-tweakxl` and
  `20261024-053149-tweakxl` each passed all six functional checks: player attached,
  new flat, new record, record override, custom stat and scriptable tweak. Both
  exited naturally with code 0. Their harness verdicts remain **FAIL** because
  the initial core-hook snapshot still showed zero hits for `Main` and
  `CGameApplication_AddState` before the approximately four-second scripted quit.
  These are functional passes and normal exits, not overall harness passes.
- The 120-second full-stack boot `20261024-053215-boot` received an overall
  harness **PASS**, with all 94 hooks installed successfully. Three TweakXL hooks
  used the new absolute fallback. `GetStatRange` at RVA `0x23b3cb0` recorded 3,067
  hits; the absolute hook at `0x23b3438` recorded 145; the one at `0x23b34b4` was
  installed but recorded zero. This proves execution of the fallback on the
  original failing target. The harness ended the timed boot (exit 143), so this
  is not a normal-quit or gameplay pass. Many ArchiveXL paths remain unexercised.
- Manual overlay checks observed F1 open/close, `help`, keyboard tab switching,
  item search for `Lexington` returning 49 results, and a pinned item appearing in
  Quick. These menu checks do not establish gameplay or unpinning behavior; the
  subsequent user gameplay checks are recorded separately below.

An existing nonblocking display issue was observed when pinning before Quick was
first opened: lazy loading can show the pin twice even though the saved pin file
contains one entry. This observation does not establish that unpinning works.

## Fourth-candidate user acceptance — October 24, 2026

The user confirmed that all five requested gameplay checks worked:

- Previously created weapons still worked.
- Items added a normal item.
- Quick Money changed the balance.
- One usual, user-selected cheat could be turned on and off.
- SaveSpot, moving away, then GoToSpot returned to the saved location.

Together with the earlier Creator checks, this completes the requested local
acceptance. It does not establish every cheat, every Creator effect combination,
unpinning, all third-party mod installation workflows or a new live 2.3.1 pass.

## Completed checks

- Creator bridge transaction tests cover preflight, reload/record errors, inventory
  acknowledgements, timeout, duplicate requests and stale process IDs.
- Custom-name JSON preservation and UTF-8 handling checks passed. Version-specific
  localization fingerprints match the retained 2.3.1 and installed 2.5 binaries.
- Loader CTest passed 5/5. Hook thread-exit and near-allocation regressions were
  reproduced before their fixes and passed repeated checks after them.
- Final native-loader CTest passed 5/5, including forced absolute relocation,
  conditional branches, SIMD/struct returns, full restore and unsafe-entry refusal.
- Full-stack TweakXL functional checks and the timed 2.5 boot with Frida, overlay,
  TweakXL, ArchiveXL and the launcher's flat-namespace environment passed within
  the evidence boundaries detailed above. Creator gameplay evidence comes from
  the separate user acceptance sessions.
- Launcher script-staging and compilation-gate checks passed; source typechecked.
  A 2.5 compiler error stops launch. Play detects stale core payload bytes.
- Explicit-input release assembly, native dependency inspection and local Developer
  ID signing passed. Installed test files matched the signed candidate byte-for-byte.
- The user accepted the fourth candidate's requested gameplay checks listed above.
- ZIP extraction and read-only DMG mounting reproduced all 303 signed file hashes
  and permissions. Strict deep signature verification passed for both packaged apps;
  DMG integrity and its Applications shortcut passed. Packaging left the app unchanged.
- All changes are local commits under ysrdevs. No push, release upload or notarization
  submission has been performed.

## Completed acceptance procedure

1. Use the prepared test launcher and click Play. It targets an isolated game copy;
   the game profile and saves were backed up before testing.
2. Load a save, open and close Inventory once, then open the console with F1 or `.
3. In Creator, choose a base weapon, a unique new name and effects, then Create & Apply.
4. Record the Creator status. Check the weapon appears exactly once, shows its custom
   name and Iconic identity, and can be equipped and fired with the selected effects.
5. If this works, save to a new manual slot, quit and relaunch through this candidate.
   Verify the weapon/name/effects persist after loading that slot.
6. Check the existing weapons, normal item addition, Quick Money, one usual cheat
   on/off, and SaveSpot/GoToSpot. The user confirmed all five checks worked.

The isolated game path may display the launcher's Steam-only warning because it does
not contain “steamapps”; it is a copy of the Steam game. Do not change the folder to
the live development installation during this first test.

## Release acceptance and evidence boundaries

Creator creation, acknowledgement, uniqueness and persistence have passed. The
observed custom-stat allocation failure is fixed and its absolute fallback was
exercised in the real full stack. The fourth-candidate gameplay checks and package
verification complete the requested local release checks. Final release artifacts
are the already verified packages, promoted without rebuilding or re-signing.
Only the specific user-selected cheat and workflows listed above were accepted;
do not claim every cheat or third-party mod installation workflow was tested.

Preserved 2.3.1 binaries and static checks are not evidence of a new live 2.3.1 pass.
An unavailable old-game replay does not block a release explicitly validated for 2.5;
do not advertise a new 2.3.1 validation. The native source recipe's patch replay and
generated SDK hashes were verified; a fresh end-to-end orchestration build has not
yet been run. The current app is signed locally but not notarized.

## Accepted local packages

The accepted ZIP and DMG originate from test4's `packages/`, with `SHA256SUMS`,
`packaging-validation.json` and a validation log. They are promoted byte-for-byte
to the final local `releases/1.6.0` directory. The app is Developer ID signed;
neither artifact has been submitted for notarization or uploaded for publication.
The user handles source pushes and GitHub/Nexus publication.

```text
08d0d75241c15a7e029eb0bc62395441a126646dbb9bbd1bd0bac91bb7ae71d4  NightCity-Console-for-Mac.zip
0dcd12db702ccc69523ac3c73058caa7a4aa7a5f5f7be21196071c59d8d778af  NightCity-Console-for-Mac.dmg
```
