# NightCity Console 1.7.1: Save Loading Fix and Better Diagnostics

This update fixes a reported save-loading hang on **Cyberpunk 2077 2.5.0,
native macOS Steam**, and makes it easier to capture useful diagnostics when a
game freezes or slows down. The player who reported the loading hang confirmed
that the fix works.

## What's changed

- **Save-loading fix:** corrected an ArchiveXL garment-processing lock that
  could leave the game stuck on the loading screen after selecting Continue or
  loading a save. Local testing also passed repeat loading, wardrobe changes,
  Virtual Atelier purchases and dual operating-system abilities.
- **Game thread samples:** Export Diagnostics attempts a short, 3-second sample
  of the running game selected in the launcher. Thread stacks and loaded binary
  identities help locate a blocked operation. The export records capture status,
  timing, failures and any truncation.
- **More complete support data:** the ZIP includes installed-versus-bundled
  runtime hashes, managed script integrity, script-cache metadata, relevant
  configuration and available runtime filter status, alongside bounded startup
  and recent logs, dated crash excerpts, versions and mod inventory.
- **Collection stays on demand:** sampling runs only when you export. Nothing is
  uploaded automatically. Save files, screenshots, mod source contents, memory
  dumps and console command history are excluded. Common personal paths and
  identifiers are redacted; review the ZIP before sharing it.

## Included from 1.7.0

The performance improvements, scoped native Codeware support and Iconic Weapon
Creator with **37 base-game weapons across nine categories** remain included.
Existing created weapons are preserved. These Creator choices do not require
Phantom Liberty.

**Equipment-EX 1.2.9 and Cyberware-EX 1.5.6 can be installed from Optional Mods**;
both remain unchecked by default. **Virtual Atelier** uses the launcher's
official download link and import option. VA and store packs are downloaded
separately. The tested combination remains VA 1.6.0 with PUBLICNET 1.2.1.

See the [1.7.0 release notes](https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/RELEASE-1.7.0-PUBLIC.md)
for the original feature details, or the [mod installation guide](https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/MOD-INSTALLATION.md)
for downloads, folder locations and setup.

## Install or update

1. Quit Cyberpunk 2077 and the older NightCity Console launcher.
2. Download **NightCity-Console-for-Mac.dmg** or the ZIP, then replace the older
   **NightCity Console.app** in Applications.
3. Open the new app, select your game if needed, and click **Install** /
   **Reinstall NightCity Console** to apply the updated runtime. No uninstall is
   needed.
4. Click **Play**. Open the in-game console with **F1** or the backtick key.

The app and DMG are **Developer ID signed and notarized by Apple**, with stapled
tickets. The ZIP contains the stapled app.

## If the game hangs

**Leave the game running and export diagnostics before force-quitting it.** In
the launcher, click **Export Diagnostics** and save the ZIP. Include whether the
problem occurred before the main menu or after Continue/Load Game, and what you
were doing just before it stopped responding.

A closed game cannot be sampled. If macOS prevents sampling, the other
diagnostics still export and the launcher reports that the sample could not be
captured. Activity Monitor's **Sample Process** is a manual fallback. Some issues
may need a focused follow-up capture.

For a slowdown, enable **Record performance on next launch**, relaunch, reproduce
the issue and export. Turn recording off afterward. These measurements describe
drawable intervals, not GPU benchmark results.

## Compatibility and known limits

- The loading fix targets **2.5.0 on Apple Silicon, native macOS Steam**. Existing
  2.3.1 compatibility is retained. GOG, Intel and Windows CET/Lua mods are not
  supported.
- Codeware support remains scoped to the tested features. Other Codeware APIs,
  optional mod presets and arbitrary mod combinations need separate testing.
- A Middle Torso over Inner Torso clothing combination showed clipping in local
  testing. Outer Torso over Inner Torso worked for the tested combination. A
  matched 1.7.0 comparison is unavailable, so a new regression is not established.
- The existing Quick-tab issue remains: pinning an item before first opening
  Quick can display the pin twice, while the saved pin file has one entry.
