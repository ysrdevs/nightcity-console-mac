# NightCity Console 1.8.0: Noclip Flight

Release candidate: final installer testing and Apple notarization are pending.

Explore Night City with built-in noclip on **Cyberpunk 2077 2.5.0, native macOS Steam**. Fly through geometry, reach a rooftop and stop at your destination. Return to start is optional, with no automatic time limit or return radius.

## What's new

- **Exploration tab:** Start, Stop here, Resume and Return to start, with automatic preparation from clear ground.
- **Flight controls:** WASD movement, normal mouse look, Space up, Control down, Shift boost and Alt/Option precision. Choose Slow, Normal, Fast or Faster speed.
- **Destination stopping:** Stop here restores collision and gravity where you are when there is enough space. If the destination is blocked, flight stays paused so you can move clear or return.
- **Pause and interaction handling:** Inventory and app switching pause in place. Using a computer stops flight as the game takes control; start again after finishing the interaction.
- **Rendering work reduced:** Console output is read on a worker using bounded snapshots, keeping file reads out of the render path. The performance improvements from 1.7 remain included.
- **Automatic script installation:** Install/Reinstall includes the flight scripts on supported 2.5 games. Managed-file checks detect missing or changed payloads while preserving unrelated mod files.
- **Flight support data:** Export Diagnostics includes managed flight-script integrity and bounded flight-state summaries without exporting console command history or mod source contents.

## How to fly

1. Open **F1 → Exploration** while standing on clear ground.
2. Click **Start**, close F1 and move with the flight controls.
3. To land, move over a clear surface and descend until your feet are just above it. Click **Stop here**. Stopping higher up resumes falling.
4. Use **Return to start** if you want to go back, or **Resume** after a menu/app-switch pause.

Stop flight and check normal walking before saving. No manual Validate/crouch setup is needed. See the [flight guide](EXPLORATION.md) for details and troubleshooting.

## Existing features remain included

The 1.7.1 save-loading fix, support diagnostics, console commands and **37-weapon Iconic Weapon Creator** remain included. The Creator's base-game choices do not require Phantom Liberty, and existing custom weapons are preserved.

**Equipment-EX 1.2.9 and Cyberware-EX 1.5.6 can be installed from Optional Mods**, unchecked by default. **Virtual Atelier** has an official download link and import option; VA and store packs are downloaded separately. The native macOS Codeware, ArchiveXL and TweakXL payloads support the tested mod combination. Other Codeware-dependent mods may need separate adaptation.

See the [mod installation guide](MOD-INSTALLATION.md) for downloads, folders and setup.

## Install or update

1. Quit Cyberpunk 2077 and the older NightCity Console launcher.
2. Replace **NightCity Console.app** in Applications with the new app from the DMG or ZIP.
3. Open it, select your game and click **Install / Reinstall NightCity Console**, then **Play**. No uninstall is needed.
4. Open the console with **F1** or the backtick key.

Flight targets **2.5.0 on Apple Silicon, native macOS Steam**. Existing 2.3.1 console compatibility is retained, but flight is not installed on 2.3.1. GOG, Intel and Windows CET/Lua mods are not supported.

If something fails, click **Check flight status**, leave the game open and export diagnostics before reloading. Include the last action and whether you were near geometry, using a computer or switching menus. Nothing is uploaded automatically.
