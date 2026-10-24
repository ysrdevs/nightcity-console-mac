# NightCity Console 1.6.0 — release record

All requested local release checks are complete. This document records the evidence
and its limits; player-facing notes are in [RELEASE-1.6.0-PUBLIC.md](RELEASE-1.6.0-PUBLIC.md).
The user handles source pushes and GitHub/Nexus publication. No push or upload is
part of this work.

## Accepted release — October 24, 2026

The user reported that the second candidate created a weapon and that the weapon
works in game 2.5.0. This establishes that manual creation/use succeeded in that
session; it does not establish every effect combination. The user subsequently
confirmed that the weapon's custom name, Iconic identity/effects and equip/fire
behavior persisted after a new manual save and relaunch.

The same creation attempt produced a false failure indication: the inventory
acknowledgement timed out after GiveItem. The quantity check generated fresh unique
ItemIDs instead of a record query. Commit `9437697` changes it to native
`ItemID.CreateQuery`. The user tested the separately signed third candidate and
confirmed a correct success message, exactly one added weapon, and persistence of
the prior weapon. The runtime independently recorded quantity increasing from 0
to 1. Creator acceptance is complete.

The native allocation gate has also passed. Native commit `27566e1` adds an
absolute hook fallback when the nearby branch windows are full, with its source
recipe preserved in `d8a798c`. Two fresh full-stack TweakXL sessions passed all six
functional checks and exited normally. Their overall harness verdicts remained
FAIL because the initial snapshot had stale zero core-hook counters before the
short scripted quit. A separate 120-second boot received an overall PASS and
installed all 94 hooks, including three absolute hooks: `GetStatRange` recorded 3,067
hits, another recorded 145, and the third was installed but not hit. That boot was
ended by the harness; it does not establish normal quit or every ArchiveXL path.

The fourth candidate preserves the accepted third candidate's Creator
runtime, overlay, launcher code and other dependencies, replacing only the 2.5
loader and provenance before selective signing. Manual overlay checks passed for
F1 open/close, help, keyboard tab switching, Lexington item search (49 results),
and a pin appearing in Quick. The user then confirmed all requested fourth-candidate
gameplay checks: existing created weapons worked, Items added a normal item, Quick
Money changed the balance, a usual cheat toggled on/off, and SaveSpot followed by
moving away and GoToSpot returned to the saved location. This is acceptance of those
specific checks, not every cheat, effect combination or third-party mod workflow.
Unpinning remains unverified.
An existing nonblocking first-pin display issue can show two Quick rows after lazy
loading while the saved file contains one pin; no fix is included in this candidate.

The public scope is the existing console/item-browser/cheat workflow plus the
Iconic weapon Creator on native macOS Steam game 2.5.0. TweakXL and ArchiveXL are
the bundled native dependencies. Codeware, Virtual Atelier, the CET-Lua host,
general Windows CET-mod compatibility and save-editor changes are outside this
release. The retained 2.3.1 payload is a compatibility baseline, not evidence of a
new live 2.3.1 regression pass.

See [RELEASE-1.6.0-TESTING.md](RELEASE-1.6.0-TESTING.md) for detailed evidence and
acceptance steps, [RELEASE-BUILD.md](RELEASE-BUILD.md) for assembly/signing, and
[native25/README.md](../native25/README.md) for the native source recipe.

## Accepted artifacts and publication

ZIP extraction and read-only DMG mounting matched all 303 frozen app file hashes
and permissions. Both packaged apps passed strict deep signature verification;
DMG integrity and the Applications shortcut also passed. The accepted test4 app
and packages are promoted unchanged to the final local `releases/1.6.0` directory,
without rebuilding or re-signing. Hashes and detailed evidence are recorded in
[RELEASE-1.6.0-TESTING.md](RELEASE-1.6.0-TESTING.md).

No requested local release check remains open. The app is Developer ID signed but
not notarized; no Apple submission, source push or release upload has occurred.
The user can use [RELEASE-1.6.0-PUBLIC.md](RELEASE-1.6.0-PUBLIC.md) for publication.
Any later runtime, native, overlay or launcher change requires validation of the
changed artifact. The retained 2.3.1 compatibility payload has not received a new
live regression pass, and many ArchiveXL paths remain unexercised.
