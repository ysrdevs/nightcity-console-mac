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

---

## NightCity Console v1.0.0

An in-game cheat/mod console for Cyberpunk 2077 on macOS (Apple Silicon). The kind of thing
Cyber Engine Tweaks does on Windows, on a platform where CET doesn't exist. Press a key in-game,
a console appears, and you type commands. CET item codes from the internet paste in and work as-is.

![NightCity Console launcher](https://raw.githubusercontent.com/ysrdevs/nightcity-console-mac/main/assets/screenshot.png)

### Install (no Terminal needed)
1. Download **NightCity-Console-for-Mac.dmg** (or **NightCity-Console-for-Mac.zip**) below.
2. Open it and run **NightCity Console**.
3. Click **Install**, then **Play**.
4. In-game, press the backtick/tilde key (`` ` ``) or **F1** to open the console. Type `help`.

The app finds your game, installs the files, and launches it. Steam Cloud saves keep working,
and the game exits cleanly.

### Requirements
- macOS on Apple Silicon (arm64).
- Cyberpunk 2077 **v2.3.1**, **Steam**. GOG support is in progress (not supported yet; engine offsets differ).

### What you can do
- Items: `give Items.X <qty>`, `removeitem`, `money`, plus CET-style `Game.AddToInventory("Items.X", n)`.
- Character: `perks`, `attrs`, `relic`, `level`, `heal`.
- World: `teleport` with position bookmarks, `setfact`.
- Power tools: a generic `call <Class> <Method>` bridge to any observed RTTI method.
- Console quality of life: command history (up/down) and clipboard (Cmd+V/C/X/A).

Full command list: [docs/COMMANDS.md](https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/COMMANDS.md).

### Known limits
- godmode registers with the engine but on 2.3.1 still takes hit damage (it prevents death, not damage).
- Teleport is blocked by the game during active combat. Bookmarks reset each launch.
- Quest-gated items (for example `Items.mq007_skippy`) need the relevant quest active to appear.
- Not yet implemented: vehicle summon, equip-to-slot, NPC/vehicle spawning. Contributions welcome.

### Safety
Single-player and personal use only, on your own legally-owned copy. Modding can corrupt saves,
so back them up. Not affiliated with CD PROJEKT RED.

### For developers
Source, build instructions, and a full reverse-engineering write-up are in the repo
([TECHNICAL.md](https://github.com/ysrdevs/nightcity-console-mac/blob/main/TECHNICAL.md)).

### Credits
Built on Dear ImGui, Frida, and the RED4ext macOS port. MIT licensed. If it saved you some hassle,
you can support development on [Ko-fi](https://ko-fi.com/ysrdevs).
