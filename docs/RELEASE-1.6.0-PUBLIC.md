# NightCity Console 1.6.0 for Mac

NightCity Console 1.6.0 brings the Iconic weapon Creator to Cyberpunk 2077 2.5.0
on Apple Silicon Macs running the native Steam edition.

## What's changed

- Create an Iconic weapon from a base weapon, with a custom name, descriptions and
  selected effects. Created weapons and their custom text persist after saving
  and reloading.
- Fixed Creator's 2.5 record lookup and the false inventory-confirmation timeout.
  A successful creation is confirmed against the inventory, with one weapon added
  per request.
- Fixed a native hook allocation failure that could prevent late plugin hooks
  from loading. The macOS TweakXL and ArchiveXL dependencies are included.
- The launcher updates outdated runtime files and stops a 2.5 launch if script
  compilation fails, displaying the error before the game starts.

The console, item browser and quick actions remain available. Release testing on
2.5.0 covered Creator creation and persistence, normal item addition, Quick Money,
a cheat toggled on/off, and SaveSpot/GoToSpot.

## Install or update

1. Copy **NightCity Console.app** to Applications, replacing the older app if present.
2. Open NightCity Console, select your native Steam game installation, click
   **Install**, then **Play**.
3. In game, press **F1** or the backtick key to open the console. Use the **Creator**
   tab to make a weapon. Keep a separate manual save when testing new creations.

The app is Developer ID signed but has **not been notarized by Apple**.

## Compatibility and known issue

This release was tested on native macOS Steam game **2.5.0**. The previous 2.3.1
compatibility payload is retained, without a new live 2.3.1 test. GOG and Intel Mac
builds are not supported. Codeware, Virtual Atelier, CET-Lua/Windows CET mods and
save-editor changes are outside this release.

Pinning an item before first opening Quick can display the pin twice in Quick,
while the saved pin file contains only one entry. This is a known display issue.
