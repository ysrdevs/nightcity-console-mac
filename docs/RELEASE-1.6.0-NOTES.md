# NightCity Console 1.6.0 — local candidate notes

This is a local release preparation document, not an announcement or approval to
publish. The user will push source and upload releases to GitHub and Nexus after
testing. No publication is part of this work.

## Candidate status — October 24, 2026

The user reported that the second candidate created a weapon and that the weapon
works in game 2.5.0. This establishes that manual creation/use succeeded in that
session; it does not establish every effect combination or restart persistence.
The user is testing persistence in a new manual save slot.

The same creation attempt produced a false failure indication: the inventory
acknowledgement timed out after GiveItem. The discrepancy between the Creator
message and the actual inventory is under investigation. Do not label this
candidate release-ready or suggest repeating Create solely because of that message.

The public scope is the existing console/item-browser/cheat workflow plus the
Iconic weapon Creator on native macOS Steam game 2.5.0. TweakXL and ArchiveXL are
the bundled native dependencies. Codeware, Virtual Atelier, the CET-Lua host,
general Windows CET-mod compatibility and save-editor changes are outside this
release. The retained 2.3.1 payload is a compatibility baseline, not evidence of a
new live 2.3.1 regression pass.

See [RELEASE-1.6.0-TESTING.md](RELEASE-1.6.0-TESTING.md) for detailed evidence and
acceptance steps, [RELEASE-BUILD.md](RELEASE-BUILD.md) for assembly/signing, and
[native25/README.md](../native25/README.md) for the native source recipe.

## Remaining publication checks

- Resolve and retest the acknowledgement discrepancy: one request gives one
  weapon, and the status agrees with the resulting inventory.
- Finish the user's new-slot/restart test, including custom name, descriptions,
  Iconic identity, equipped behavior and chosen effects.
- Close the native custom-stat hook reliability gate under the complete injected
  stack; one successful creation is not a substitute for that check.
- Complete the public-feature smoke tests and the 2.3.1 regression check before
  claiming full parity or newly verified support for both game versions.
- Freeze the accepted source revision and candidate file hashes. Recheck the
  final signed payload after any JS, native, overlay or launcher change.
- Prepare final ZIP/DMG files from the accepted candidate. Local Developer ID
  signing does not mean notarization has occurred; any Apple submission remains
  a separate authorized step. The user handles GitHub and Nexus publication.

## Publication draft — use only after acceptance

**NightCity Console 1.6.0 for Mac**

This update brings the Iconic weapon Creator to Cyberpunk 2077 2.5 on Apple Silicon
Macs running the native Steam edition. Create a custom weapon from a base weapon,
give it a name and descriptions, and choose its effects from the Creator tab.

The console, item browser and quick actions remain available. The launcher updates
outdated runtime files and stops a 2.5 launch when script compilation fails, so a
failed compile is shown before starting the game.

This release includes the macOS TweakXL and ArchiveXL dependencies. Codeware,
Virtual Atelier and CET-Lua mods are not supported by this release. GOG and Intel
Mac builds are not supported.

To update, replace the app, click **Install**, then **Play**. In game, press **F1**
or the backtick key to open NightCity Console. Test new creations in a separate
manual save slot.

Before publishing this draft, resolve the candidate issues above and set the
supported-game-version wording to match the completed tests. Do not copy the
candidate status or unfinished checklist into the public announcement.
