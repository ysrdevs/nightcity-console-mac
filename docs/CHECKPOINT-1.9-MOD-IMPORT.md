# Private 1.9 mod import checkpoint

Accepted on 1 November 2026 for native macOS Cyberpunk 2077 2.5.
This records private test build 1.9.0.10 from console commit `d0be45e`,
not a public release. The earlier Input Loader and Mod Settings checkpoint
remains separate and unchanged.

## Import validation

- Add Mod prepares a ZIP or folder outside the game and displays detected
  requirements, blocking issues and the exact files to add before installation.
- The launcher preview showed the two files in the private notification test
  package and detected Input Loader, RED4ext and redscript as present.
- Cancel left every game file, directory and symlink unchanged in the recorded
  before/after comparison.
- An unsupported Windows component was blocked with Install disabled.
- Existing Virtual Atelier and an already-installed test package were refused;
  existing files and receipts were not overwritten.
- Installing the reviewed test package produced the expected two files and
  receipt. Script compilation completed with zero errors.
- Automated checks covered dependency detection, optional integrations, batch
  conflicts, protected files, prepared-file verification, rollback and safe
  removal. Existing archive conversion and compatibility regressions passed.

## User-confirmed gameplay

The user loaded a save through the private launcher and confirmed all requested
checks passed:

- F6 displayed the imported test mod's notification.
- A Virtual Atelier purchase worked.
- Equipment-EX outfit switching worked.
- The Cyberware-EX second operating system worked.
- A short noclip flight and Stop here restored normal walking.

The corresponding running session loaded all five native plugins and all 110
hooks with zero hook failures. Input Loader merged the imported mapping, and
no new fault or crash report was recorded. Existing platform-specific warnings
remain. The gameplay outcomes above are the user's observations; the logs are
supporting startup evidence rather than a substitute for those checks.

This confirms the tested import and compatibility flows. It does not establish
compatibility with arbitrary mods or infer dependencies that a package does not
reliably declare. This pass did not request a new save/relaunch persistence test.

## Preserved state and release scope

The installed native libraries, flight scripts, existing mod scripts and
archives matched the accepted baseline after import. Changes were limited to
the test package and receipt, compiler caches and compiler logs. The original
game script cache remained unchanged. Detailed evidence and source bundles
remain private.

The private build is Developer ID signed and has not been newly notarized.
It retains the harmless notification test package and earlier private settings
controls. Test-fixture cleanup, the framework deployment-target audit and final
release validation remain separate work before public packaging. No running
game files were changed when recording this acceptance.
