# NightCity Console 1.9.0: Mod Support and Import Preview

Release candidate: final gameplay and notarization checks are pending.

This update expands mod support for **Cyberpunk 2077 2.5.0 on native macOS
Steam**, adds native Input Loader and Mod Settings, and lets you review a mod
before installing it.

## What's new

- **Native Input Loader:** compatible mods can add custom input mappings without
  replacing the game's original input files.
- **Native Mod Settings:** supported mods can expose settings and key rebinding
  in the game. Includes the companion interface assets and localization.
- **Import preview:** Add Mod, drag-and-drop and the optional import flows show
  detected requirements, issues and the exact files to add. Cancel leaves your
  game unchanged.
- **Dependency and conflict checks:** missing detected requirements, duplicate
  core mods, unsupported Windows components and conflicting files block import.
  Existing files and NightCity's managed frameworks are not overwritten.
- **Checked batch installation:** the reviewed files are verified again before
  copying. Failed copies roll back new files, and removal validates the recorded
  paths before deleting a managed package.
- **Broader tested mod support:** the private development checkpoints include
  Immersive Rippers' Cassius Ryder interaction, Input Loader hotkeys, Mod Settings
  controls and Virtual Atelier Instant Buy. Limited HUD's current main package
  is undergoing final gameplay testing.
- **Noclip and streaming fixes:** vehicle impacts no longer interrupt the tested
  flight path. The ArchiveXL hidden-object correction fixes the reproduced
  crashes when exploring below the map or inside empty building space.
- **Updated mod guide:** explains included frameworks, separate gameplay-mod
  downloads, input bindings, import review, updates and removal.
- **Explicit macOS targets:** the shared tools and game 2.5 framework builds
  target macOS 15.5. The separate 2.3.1 libraries retain their original signed
  bytes and higher deployment targets. Current gameplay testing is on macOS 27.

The existing performance improvements, save-loading fix, diagnostics export,
37-weapon Iconic Weapon Creator, Virtual Atelier, Equipment-EX and Cyberware-EX
support remain included. These checks do not guarantee every mod or combination
works; see the [compatibility list](MOD-COMPATIBILITY.md).

**Equipment-EX and Cyberware-EX can be installed from Optional Mods**, unchecked
by default. Virtual Atelier, store packs, Immersive Rippers and Limited HUD are
separate downloads installed through the launcher. Gameplay mods are not enabled
merely by installing the bundled frameworks.

## Install or update

1. Quit Cyberpunk 2077 and the older NightCity Console launcher.
2. Replace **NightCity Console.app** in Applications with the new app.
3. Open it and click **Install / Reinstall NightCity Console**, then **Play**.
   No uninstall is needed. Your existing mods and custom weapon definitions
   remain in place.
4. Use **Add Mod** for downloaded ZIPs or extracted mod folders. Review the
   preview and resolve blocking issues before installing.

The new mod-support features target game 2.5.0. GOG, Intel and Windows CET/Lua
mods are not supported. Keep a separate manual save when changing gameplay mods.
For a crash, freeze or performance issue, leave the game open if possible and
use **Export Diagnostics** before relaunching. Nothing is uploaded automatically.
