# NightCity Console 1.8.1: Optional Mod Packaging

Installer verification and Apple notarization are in progress.

This update packages Equipment-EX and Cyberware-EX as regular folders inside the app so download-site scanners can inspect their contents directly. The app no longer contains the two nested optional-mod ZIPs.

## Changes

- **Same Optional Mods workflow:** Equipment-EX 1.2.9 and Cyberware-EX 1.5.6 remain included, optional and unchecked by default.
- **Verified folder installation:** Every bundled mod file is checked before installation. Missing, changed or extra files are rejected.
- **Existing installs preserved:** The launcher recognizes the same installation records used by 1.8.0, so existing optional mods do not need reinstalling.
- **Packaging checks:** Release validation rejects embedded ZIPs even if their extensions have been changed.

The 47 optional-mod files, gameplay runtime, noclip scripts, native frameworks and helper libraries retain the tested 1.8.0 contents. This is a packaging update. Noclip, the Iconic Weapon Creator, VA support, Equipment-EX, Cyberware-EX, performance improvements and the save-loading fix remain included. Virtual Atelier and store packs are still downloaded separately. Add Mod continues to accept external ZIPs and folders.

## Install or update

1. Quit Cyberpunk 2077 and the older NightCity Console launcher.
2. Replace NightCity Console.app in Applications with the new app from the DMG or ZIP.
3. Open it and click **Install / Reinstall NightCity Console**, then **Play**. No uninstall is needed.

Cyberpunk 2077 2.5.0 on native macOS Steam is the target for noclip and the tested mod combination. Existing 2.3.1 console compatibility is retained. See the [1.8.0 feature notes](RELEASE-1.8.0-PUBLIC.md), [flight guide](EXPLORATION.md) and [mod installation guide](MOD-INSTALLATION.md).

Download sites run their own reviews. Removing nested ZIPs does not guarantee automatic approval; export diagnostics from the launcher for installation or gameplay problems.
