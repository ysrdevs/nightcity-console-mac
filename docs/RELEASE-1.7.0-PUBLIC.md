# NightCity Console 1.7.0: Performance, Codeware and Expanded Mod Support

This release brings **lower console overhead, broader Codeware-based mod support,
Virtual Atelier, Cyberware-EX and Equipment-EX** to Cyberpunk 2077 **2.5.0, native
macOS Steam**. It also expands the Iconic Weapon Creator to **37 base-game
weapons** and adds optional mod installs, a mod guide and diagnostics export.
The existing console commands, quick actions and item browser remain available.

## What's new

- **Performance improvements:** reduced console overhead during gameplay by
  avoiding unnecessary runtime callbacks while idle and during ordinary text
  lookups. Long console histories render only visible rows, and continuous frame
  logging is off by default. Local player testing reported noticeably smoother
  gameplay; results depend on hardware, settings and installed mods.
- **Broader Codeware-based mod support:** expanded native macOS UI, widget and
  wardrobe support enables the tested Virtual Atelier, Equipment-EX and
  Cyberware-EX setup. The required Codeware runtime is included alongside
  RED4ext, TweakXL and ArchiveXL. The launcher prepares supported script
  adaptations automatically and stops before launching if compilation fails.
- **Expanded Iconic Weapon Creator:** choose from 37 base-game weapons across
  nine categories, with search by name or weapon type. No Phantom Liberty is
  required for these choices. The selected weapon, blueprint and shared Iconic
  records are checked before any weapon files are written. Existing creations
  are preserved. Creation and save/relaunch persistence have passed local player
  testing; see the [validation notes](https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/CREATOR-1.7.0-VALIDATION.md)
  for coverage.
- **Optional mod installs:** Equipment-EX 1.2.9 and Cyberware-EX 1.5.6 are included
  in the app. Choose either or both in **Optional Mods…**; neither installs
  automatically. Existing manual installations are kept.
- **VA download/import and Mod Guide:** open the official Virtual Atelier page,
  import its ZIP or folder, and follow the built-in guide for store packs and
  other mods. Add Mod now handles multiple selected packages in sequence.
  Installs and removals are blocked while the game is running.
- **Virtual Atelier:** browse stores, search items and make purchases. The tested
  setup includes Virtual Atelier 1.6.0 with PUBLICNET 1.2.1. Purchased items remain
  available after saving and relaunching.
- **Cyberware-EX 1.5.6:** the default configuration supports the second operating
  system slot and its abilities, including Sandevistan. Equipped operating systems
  persist after saving and relaunching; the mod's normal unlock requirements apply.
- **Equipment-EX 1.2.9:** additional clothing slots, wardrobe search, named outfits,
  appearance changes and outfit switching. Outfits persist after saving and
  relaunching.
- **Export Diagnostics:** save a local ZIP with recent logs and crash excerpts,
  versions, hardware, graphics settings, native file hashes and mod inventory.
  Save files, screenshots, mod source files and console command history are
  excluded. Common personal paths and identifiers are redacted. Review the ZIP
  before sharing; nothing is uploaded automatically.
- **Optional performance recording:** enable “Record performance on next launch”,
  relaunch the game, reproduce a slowdown and export diagnostics. Recording is
  off by default.

## Install or update

1. Replace the older app in Applications with **NightCity Console.app**, then
   click **Install** / **Reinstall NightCity Console**. No uninstall is needed.
2. With the game closed, open **Optional Mods…** and select Equipment-EX and/or
   Cyberware-EX if wanted, then click **Install Selected**.
3. For VA, use **Download Virtual Atelier**, then **Import VA…**. Import a
   separate Atelier store pack through **Add Mod** too. VA and store packs are
   not bundled; the tested setup is VA 1.6.0 with PUBLICNET 1.2.1.
4. Click **Play**. Open the console with **F1** or the backtick key.

See the [README](https://github.com/ysrdevs/nightcity-console-mac#virtual-atelier-cyberware-ex-and-equipment-ex-on-25)
for tested versions, or the [mod installation guide](https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/MOD-INSTALLATION.md)
for download links, folder locations and troubleshooting. Keep a separate
manual save when adding gameplay mods.

## Compatibility

The new mod support targets **2.5.0 on Apple Silicon, native macOS Steam**.
Existing 2.3.1 compatibility is retained. GOG, Intel and Windows CET/Lua mods
are not supported. This is a scoped Codeware implementation; other Codeware
features, optional mod presets/add-ons and newer mod versions require their own
testing.

The app is **Developer ID signed and notarized by Apple**. Notarization tickets
are stapled to both the app and DMG; the ZIP contains the stapled app.

## Known issue

Pinning an item before first opening Quick can display the pin twice in Quick,
while the saved pin file contains only one entry.
