# Installing mods with NightCity Console

This guide covers the native Apple Silicon Steam build of Cyberpunk 2077.
Equipment-EX, Cyberware-EX and Virtual Atelier support below targets game **2.5.0**.
Keep a separate manual save before adding gameplay mods.

## Start here

1. Quit Cyberpunk 2077. Open **NightCity Console** and check the game folder at
   the top of the window. **Browse** selects the folder containing
   `Cyberpunk2077.app`, not the app itself.
2. Click **Install** (or **Reinstall NightCity Console** after updating the app).
   This installs the bundled macOS runtime, RED4ext, TweakXL, ArchiveXL, scoped
   Codeware support and redscript compiler. You do not need the Windows versions
   of those dependencies.
3. Add the mods you want using the choices below. Wait for installation and
   script compilation to finish, then click **Play** in NightCity Console.

The launcher prevents installation and removal while the game is running.
Changes take effect on the next launch through NightCity Console.

## Equipment-EX and Cyberware-EX

Open **Optional Mods…** in the launcher:

- **Equipment-EX 1.2.9** adds clothing slots and wardrobe outfit management.
- **Cyberware-EX 1.5.6** adds cyberware slots, including a second operating-system
  slot. The bundled pack uses the tested default configuration and retains the
  mod's normal unlock requirements. Extra presets and add-ons are not included.

Both choices start unchecked. Select either or both and click **Install Selected**.
These packages are included in the app; no separate download is needed.
They are not required to use the console or Creator.

An existing installation is shown as already present and is kept. Do not stack a
bundled install on top of another version or custom configuration. If you want
to replace it, follow the original mod's removal instructions first. Mods installed
through the launcher appear in its Mods list with a removal button.

## Virtual Atelier and stores

1. Open **Optional Mods… → Download Virtual Atelier**. This opens the
   [official Nexus page](https://www.nexusmods.com/cyberpunk2077/mods/2987).
   Download the mod there; a Nexus account may be required. **1.6.0 is the tested
   package**. Newer versions are not covered by that test.
2. Return to NightCity Console and click **Import VA…**. Select the downloaded
   ZIP, or the extracted folder containing its `archive` and `r6` directories.
   Leave the original package structure intact. If VA is already present, Import VA
   keeps it and asks you to remove the existing installation before replacing it;
   this avoids compiling two copies from differently named folders.
3. Download an Atelier store pack separately and install it with **Add Mod**.
   **VA alone does not include stores.** The tested pack is **PUBLICNET 1.2.1**;
   its [Nexus page](https://www.nexusmods.com/cyberpunk2077/mods/10909) is now
   titled **A.G.I.S. — All Game Items Store**. Check the file version you download.
   Other store packs may need additional item, clothing or framework mods.
4. Click **Play**, load your save and use an in-game computer. Open **Atelier**
   to browse the stores.

VA and store packs are not bundled with NightCity Console. Import prepares the
supported archive and script files for macOS 2.5. An empty store page can mean
that no store pack is installed; check the launcher's status for compilation
errors as well.

## Adding other mods

Use **Add Mod** to select one or more ZIPs or extracted folders, or drop them on
the Mods area. The launcher installs them in sequence, prepares supported files
and compiles scripts before launch. Do not point it at your entire Downloads
folder. For `.7z` or `.rar` downloads, extract them first and import the mod folder.

Check each mod's requirements and instructions. Native macOS support is not
implied by a Windows mod working on the same game version. In particular:

- Windows native plugins (`.dll`) cannot run on macOS. Use the bundled macOS
  frameworks; do not replace them with Windows downloads.
- Windows CET/Lua mods are not supported by NightCity Console.
- Codeware support covers the tested UI and wardrobe features. Mods that require
  other Codeware features need separate validation.
- The known compatibility adaptations target the versions listed above.
  Unknown or edited targets can stop preparation with an actionable error.

## Where the files go

These paths are relative to the **game folder shown in the launcher**. In Steam,
you can also use the game's **Manage → Browse local files** command to find it.
They are not paths inside `Cyberpunk2077.app`, and they are not save folders.

| File type | macOS game-folder location |
| --- | --- |
| Compatible `.archive` mods | `archive/Mac/mod/` |
| Verified VA / Equipment `.archive.xl` metadata | Beside its matching archive in `archive/Mac/mod/` |
| Redscript `.reds` files | `r6/scripts/<ModName>/` |
| TweakXL `.yaml` / `.yml` / supported tweak files | `r6/tweaks/` |
| Bundled native frameworks | `red4ext/plugins/` — managed by NightCity Console |

Prefer **Add Mod**: Windows downloads often use `archive/pc/mod`, and some
archives need conversion. Merely moving a Windows archive into the Mac folder
does not perform that conversion. The table is for understanding or maintaining
an already compatible install, not a substitute for the import step.

The importer can place other XL configurations in `red4ext/plugins/ArchiveXL/Bundle/`.
Keep the layout selected by the importer or specified for that Mac-compatible mod.

Keep each script mod's folder structure. Do not copy duplicate versions into
separate folders: both sets of declarations would be compiled. NightCity Console
manages the modded script cache; do not copy a Windows `final.redscripts` cache
into your game.

## Updating and removing mods

Quit the game first. Follow the mod author's update/removal instructions,
especially if the mod changes equipped items, slots or outfits. Keep a save from
before the change. For a replacement version with different files, remove the old
package first so obsolete scripts do not remain alongside the new ones.

Use the removal button in the launcher's Mods list for packages installed there.
It removes their recorded files and recompiles scripts. Manually installed mods
may not appear in that list; remove only the files belonging to that mod, using
its original package as a reference. Removing NightCity Console itself does not
uninstall every gameplay mod you have added.

For Equipment-EX or Cyberware-EX, restore a normal outfit or equipment setup
before removing the mod, and follow its author's instructions. Do not assume a
save that uses extra slots will behave the same without the mod.

## If something fails

Read the launcher's status message first. A script error prevents a 2.5 launch;
resolve the incompatible mod instead of replacing the cache by hand. If a mod
needs a newer dependency or game version, its newest download may not match this
release's tested versions.

Click **Export Diagnostics**, save the ZIP and include it with a report. Add the
mod names/versions, the first failure and the steps to reproduce it. For a
slowdown, enable **Record performance on next launch**, relaunch, reproduce it,
then export. Turn recording off afterward. Exports stay on your Mac until you
choose to share them; review the ZIP first.
