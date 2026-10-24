# NightCity Console 1.6.1 — Cyberpunk 2077 Patch 2.5 Support

NightCity Console now supports **Cyberpunk 2077 patch 2.5** on Apple Silicon Macs
running the native Steam edition. This is the first public 2.5 compatibility
update since the previous release for 2.3.1, bringing the console, mod support
and Iconic Weapon Creator forward to the new game patch.

## What's changed

- **Console and quick actions updated for 2.5:** the in-game overlay, searchable
  item browser, money and cheat commands, and teleport bookmarks. The item catalog
  includes items added in 2.5.
- **Mod support updated for 2.5:** includes the native macOS RED4ext loader and
  matching TweakXL and ArchiveXL dependencies, alongside loose `.archive` mod
  support. Fixed a native loading failure that could crash the game during startup.
- **Iconic Weapon Creator working on 2.5:** create custom weapons with names,
  descriptions and selected effects. Weapons and custom text persist after
  saving and reloading. Fixed the false inventory timeout so successful creation
  reports correctly and adds exactly one weapon.
- **More reliable installation and updates:** the launcher replaces outdated
  runtime files and preserves existing custom weapon files. Script compilation
  errors are shown before launching the game.

## Install or update from the 2.3.1 release

1. Replace the older app in Applications with **NightCity Console.app** from this
   release. There is no need to uninstall first.
2. Open NightCity Console, select your native Steam game installation, click
   **Install** / **Reinstall NightCity Console**, then **Play**.
3. In game, press **F1** or the backtick key to open the console.

Keep a separate manual save when trying new mods or custom weapons.

## Compatibility

Tested on **Cyberpunk 2077 2.5.0, native macOS Steam, Apple Silicon**.
GOG and Intel Mac builds are not supported. Codeware, Virtual Atelier and
CET-Lua/Windows CET mods are not supported by this release.

The app is **Developer ID signed and notarized by Apple**. Notarization tickets
are stapled to both the app and the DMG; the ZIP includes the stapled app.

## Known issue

Pinning an item before first opening Quick can display the pin twice in Quick,
while the saved pin file contains only one entry.
