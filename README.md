# NightCity Console for Mac

![macOS arm64](https://img.shields.io/badge/macOS-arm64-black)
![Cyberpunk 2077](https://img.shields.io/badge/Cyberpunk%202077-2.3.1%20%7C%202.5-yellow)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Steam%20supported-green)

A native Apple Silicon in-game console, cheat menu, and item browser for Cyberpunk 2077 on macOS. Think Cyber Engine Tweaks, rebuilt from scratch for the native macOS/Apple Silicon build of the game: inject into the running process, resolve REDengine's runtime type system, call game functions with real typed arguments, and draw a console on the live frame with a Metal overlay you control with your mouse or keyboard.

> Renamed from "CET Mac" to "NightCity Console for Mac" to avoid confusion with Cyber Engine Tweaks. This is an independent, macOS-native project and is not affiliated with CET, WolvenKit, REDmod, CD PROJEKT RED, or Cyberpunk 2077. Single-player, personal use, on your own legally-owned copy. Back up your saves before using it.

![NightCity Console launcher](assets/screenshot.png)

## Demo

[Watch the demo](https://raw.githubusercontent.com/ysrdevs/nightcity-console-mac/main/assets/demo.mp4) (adding relic and perk points, weapons, and money, live in-game on macOS).

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="assets/search-item.jpg" width="100%" alt="Search any item and add it"><br><b>Search any item and spawn it</b></td>
    <td width="50%"><img src="assets/item-stats.jpg" width="100%" alt="Find any item and its stats"><br><b>Find any item and its stats</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="assets/add-points.jpg" width="100%" alt="Add perks, attributes, and relic points"><br><b>Add perks, attributes, and relic points</b></td>
    <td width="50%"><img src="assets/teleport-quick-actions.jpg" width="100%" alt="Teleport utility and quick actions"><br><b>Teleport utility and quick actions</b></td>
  </tr>
</table>

## Status

**Version 2.0.2 supports Cyberpunk 2077 2.5.0, native macOS Steam.**
2.0.2 corrects a native preparation timeout and an order-dependent script compiler
failure, and expands support diagnostics. It retains the earlier upgrade fixes.
See the [2.0.2 hotfix notes](docs/RELEASE-2.0.2-PUBLIC.md).
The 2.5 Console now uses a native runtime without Frida Gadget. Items, money,
Creator, gameplay controls, saved locations and noclip have passed private
player tests, including save/relaunch. The signed player installer has also
passed the final ITP camera/binding, flight and Mansion activity checks,
including relaunch. See the
[2.0 release notes](docs/RELEASE-2.0.0-PUBLIC.md).

2.0 adds support for specific original Lua mods: Vehicle Call Cost,
V's Edgerunners Mansion and Immersive Third Person. ITP's original Lua and
REDscripts are unchanged. Its smooth camera, weapon draw/holster transitions,
distance/height controls and settings-page navigation have passed player tests.
The final installer also passed a player-selected F10 camera binding, the
Console toggle and binding persistence after relaunch.
Mansion ownership, elevator travel, sleeping and drinks have passed relaunch
checks. These results do not establish universal CET compatibility.

The bundled foundation includes macOS RED4ext, ArchiveXL, TweakXL, scoped
Codeware, Input Loader, Mod Settings and the redscript compiler. VA,
Equipment-EX, Cyberware-EX, Immersive Rippers and Limited HUD remain part of the
compatibility baseline. Exact versions and tested features are listed in
[Mod compatibility](docs/MOD-COMPATIBILITY.md).

Equipment-EX and Cyberware-EX remain optional installs, unchecked by default.
VA, store packs and the new Lua gameplay mods are separate downloads.
Use **Add Mod** to review a supported original package and its dependencies
before installation. Unsupported or changed Lua packages are refused rather
than treated as verified. See the [mod guide](docs/MOD-INSTALLATION.md).

The existing 2.3.1 backend remains a separate compatibility path. GOG, Intel,
AudioXL and arbitrary Windows native DLLs are outside the 2.0 support claim.

## What it does

- In-game Metal/ImGui console with mouse-operated tabs, typed commands, command history and clipboard support. Press F1 or backtick to open it.
- Searchable item browser with 7,543 supported item records from a 7,667-row source catalog. Filter by category or name, select an item and quantity, then click Add.
- Pinned favorites that persist across restarts, surfaced in a Quick tab so your go-to gear is one keypress away.
- One-click cheats: money, full heal, perks, attributes, relic points, set character level.
- Godmode and infinite ammo with explicit On, Off, Check and Reset controls.
- Invisibility (line-of-sight and detection break), infinite ammo, and world toggles (time of day, slow motion, disable police response).
- Teleport with saved position bookmarks (save a spot, return to it later).
- Noclip flight on game 2.5: an Exploration tab with speed presets, pause/resume, stopping at your destination and optional Return to start. See the [flight guide](docs/EXPLORATION.md).
- Mod import preview with detected dependency checks, conflict detection and a list of destination files before installation.
- Named profiles for managed native Lua packages, dependency-aware removal and Restore previous. Switch with the game closed; settings stay shared between profiles.
- Native Input Loader and Mod Settings on game 2.5, including supported mods' custom keys, settings controls and rebinding.
- Supported console commands and quest-fact editing. The native backend exposes reviewed operations; arbitrary game-method calls and unrestricted Lua evaluation are not supported.
- Action results distinguish pending requests, verified changes, refusals and uncertain outcomes. Do not repeat a grant while its result is pending or unknown.
- Iconic Weapon Creator with 37 base-game weapons, nine categories and search by name or weapon type. Custom names, descriptions and effects persist after saving and reloading. Creation checks the selected base and required Iconic records before writing files; Phantom Liberty is not required for these weapon choices.
- Add Mod installs supported ZIPs or folders, including multiple selections, and prepares script mods for the selected game version.
- Optional Mods offers Equipment-EX and Cyberware-EX, plus an official Virtual Atelier download link and import button. The built-in Mod Guide explains installation and file locations.
- Export Diagnostics saves a local support ZIP with an on-demand game thread sample, bounded logs, runtime and script integrity checks, version information, installed mod inventory and optional performance telemetry.

See [docs/COMMANDS.md](docs/COMMANDS.md) for the full command list and known limits.

## Requirements

- Apple Silicon Mac (arm64). Intel is not supported.
- Cyberpunk 2077 v2.5.0, native macOS Steam, for the current mod-support features.
- The 2.5 runtime targets macOS 15.5 or newer, matching the game's minimum.
  Current release testing is on macOS 27; an older-OS gameplay run is not claimed.
- The older 2.3.1 runtime is retained unchanged. Its legacy libraries retain
  their original macOS 26/27 deployment targets, and the 15.5 target does not
  apply to those legacy files.
- A legally-owned copy of the game. No CD PROJEKT RED files are distributed by this project.

## Install and usage (players)

Prefer a walkthrough? Watch the install and usage video:

[![Watch the install and usage video](https://img.youtube.com/vi/VOUMaNLSAV0/hqdefault.jpg)](https://youtu.be/VOUMaNLSAV0)

1. Download `NightCity-Console-for-Mac.dmg` from [Releases](../../releases).
2. Open it and drag NightCity Console into your Applications folder.
3. Open NightCity Console, click Install, then Play.
4. In-game, press the backtick/tilde key (`` ` ``) or F1 to open the console.

No Terminal, no file editing. The app finds your game, installs the runtime files (re-signing the game binary so the console can load), and launches it. Steam Cloud saves keep working.

Updating from an older version: quit the game and the older launcher, replace the app, then click Install once (it reads "Reinstall NightCity Console") and Play. This installs the updated runtime and the flight scripts on supported 2.5 games, while retaining the 1.7.1 loading fix. No need to uninstall first.

The release app and DMG are Developer ID signed, notarized by Apple and stapled.
The ZIP contains the same stapled app, without nested ZIP files.

### Virtual Atelier, Cyberware-EX and Equipment-EX on 2.5

The tested combination is:

| Mod | Tested version | Verified features |
| --- | --- | --- |
| [Virtual Atelier](https://www.nexusmods.com/cyberpunk2077/mods/2987) | 1.6.0 package | Store cards, names/icons, search, cart purchases and purchased-item persistence; tested with PUBLICNET 1.2.1 |
| [Cyberware-EX](https://github.com/psiberx/cp2077-cyberware-ex) | 1.5.6, default configuration | Second operating-system slot, abilities including Sandevistan, normal weapons/arms and save/relaunch persistence |
| [Equipment-EX](https://github.com/psiberx/cp2077-equipment-ex) | 1.2.9 | Added clothing slots, wardrobe search, named outfits, appearance changes, outfit switching and save/relaunch persistence |

A Middle Torso over Inner Torso clothing combination showed clipping in local testing; Outer Torso over Inner Torso worked for the tested combination. A matched comparison with 1.7.0 is not available, so this has not been established as a new regression.

1. Update NightCity Console and click **Install** / **Reinstall NightCity Console**.
2. Open **Optional Mods…**, select **Equipment-EX 1.2.9** and/or **Cyberware-EX 1.5.6**, then click **Install Selected**. Both start unchecked. Existing installations are detected and kept; the Cyberware pack uses the tested default configuration without extra presets or add-ons.
3. For VA, use **Download Virtual Atelier** in that sheet to open its official Nexus page, then **Import VA…** to select the downloaded ZIP or extracted folder. The tested package is **1.6.0**. Also import an Atelier store mod through **Add Mod**; VA alone does not provide stores. [PUBLICNET 1.2.1](https://www.nexusmods.com/cyberpunk2077/mods/10909) is the tested store pack (the page is now titled A.G.I.S.). VA and store packs are not bundled.
4. Click **Play**. The launcher applies the supported 2.5 script adaptations and compiles the scripts before starting the game.
5. Open VA on an in-game computer, visit a ripperdoc for Cyberware-EX, or open Inventory → Wardrobe for Equipment-EX. Cyberware-EX's extra slots retain the mod's normal unlock requirements.

Quit the game before installing or removing mods. The launcher blocks these changes while Cyberpunk 2077 is running. For other mods, use **Add Mod** with a ZIP or extracted folder; see **Guide** in the app or the [full guide](docs/MOD-INSTALLATION.md) for folder locations, updates and removal.

Use the bundled macOS framework dependencies. Windows `.dll` plugins cannot replace them. Unknown versions or edited compatibility targets may need separate adaptation; the launcher reports an error rather than guessing. Optional presets, add-ons and arbitrary combinations of other mods have not all been tested. Keep a separate manual save when adding gameplay mods.

### Reporting a problem or performance drop

Click **Export Diagnostics** in the launcher and choose where to save the ZIP. It collects recent launcher/runtime/plugin and compiler diagnostics, relevant crash excerpts, app/game/macOS versions, hardware and graphics settings, installed-versus-bundled runtime hashes, managed script integrity, bounded flight-state summaries and a bounded installed-mod inventory. Collection runs only when requested; nothing is uploaded automatically.

**For a freeze or loading hang, leave the game open and export before force-quitting it.** The launcher attempts a 3-second thread sample of the game running from the selected folder. This includes thread stacks and loaded binary identities to help locate a blocked operation. The ZIP records the selected process, capture times, any failure or truncation, and dates for older logs and crashes. A closed game cannot be sampled. If macOS prevents sampling, the other diagnostics still export and the launcher tells you; Activity Monitor → select Cyberpunk 2077 → Sample Process is a manual fallback.

For a performance report, enable **Record performance on next launch**, relaunch the game, reproduce the slowdown and then export. Turn recording off when finished. On the native 2.0 backend, measurements are sampled runtime callback times, not game FPS or GPU benchmarks. The legacy backend retains its drawable-interval measurements.

Save files, screenshots, mod source contents, memory dumps, unrelated process samples and console command history are excluded. Common personal paths and identifiers are redacted, but review the ZIP before sharing it. Include what happened, the steps to reproduce it, whether the in-game console was open or closed, and FPS before/after at the same location and graphics settings. This helps distinguish a console bottleneck from the cost of a particular mod or graphics setting. File, size and time limits keep collection bounded; some issues may still need a focused follow-up capture.

### Using the console in-game

Press F1 or backtick to open the Console. Use the mouse to select Console,
Items, Quick, Creator, Exploration, Locations or Lua mods. Close it before
moving or flying. Console supports typed commands, history and paste.

Items has category and text filters, a selected quantity and Add buttons.
Quick contains money, character/gameplay controls and favorites. Locations
stores named destinations. Lua mods shows the native Lua host's module states;
it is not a list of every archive or redscript mod.

Common native commands (see [the command reference](docs/COMMANDS.md)):

```text
add Items.Preset_Ajax_Default 1
money 50000
perks 10
level 50
heal
pos
bookmark save home
bookmark go home
Game.AddToInventory("Items.MaxDOSE", 5)
```

Enter one command per line and wait for its result. Close F1 after a travel
request says PREPARING, and release movement keys while it completes.

## Build (from source)

This repository contains the launcher, legacy Metal overlay and legacy command
runtime source. The 2.0 native runtime/frontend and macOS framework adaptations
are maintained separately for now; their implementation sources and build
recipes are not included here. Publication in separate repositories is planned. The distributed app
includes the prebuilt frameworks and their required runtime scripts/resources.

To build the retained legacy Console overlay on Apple Silicon with Xcode command line tools:

```bash
git clone https://github.com/ysrdevs/nightcity-console-mac.git
cd nightcity-console-mac
./overlay/build.sh
```

This builds `build/libcyberconsole_overlay.dylib` and does not install into or
launch the game. It fetches pinned Dear ImGui and Lua inputs when needed.

For a complete launcher build, follow [release assembly instructions](docs/RELEASE-BUILD.md).
They require the pinned compatibility dependencies plus an explicit verified
`NIGHTCITY_NATIVE20_PAYLOAD` for 2.0, including its native binaries and original-mod
preparation helper. Signing and notarization use `tools/sign-notarize.sh` with an Apple
Developer ID. These steps assemble the Console around its native dependencies;
they do not rebuild those frameworks from this checkout.

Key source files:

- `runtime/red4ext_hooks.js`: the retained legacy command engine.
- `overlay/overlay.mm`: the retained legacy Metal/ImGui overlay and input handling.
- `launcher/`: the SwiftUI macOS app that installs and launches the game.

## How it works (short version)

On supported Steam 2.5, the launcher selects the native backend before starting
the process. It loads the native RED4ext loader and Metal frontend, with the
Console runtime supplied as a native plugin. Exact executable checks precede
engine hooks. Copied requests/results cross the UI boundary; game and Lua work
runs on its assigned execution thread. Frida Gadget and the old Console Lua
host are not loaded on this path.

The retained 2.3.1 path uses the older Frida-backed command bridge and overlay.
[TECHNICAL.md](TECHNICAL.md) and the
[earlier platform write-up](docs/MACOS-MODDING-PLATFORM.md) describe that design,
not the complete 2.0 runtime.

Install applies the game-signature entitlements required by the supported
loader. Steam's Verify Integrity of Game Files restores the original game
signature. No SIP change is required.

## Compatibility and caveats

- Steam version only right now. The offsets come from the Steam macOS build; the GOG build differs, so it is not supported yet. GOG support is in progress.
- Built against v2.3.1 and ported to v2.5 (the game version is detected at startup). Game updates can move offsets and break it. Releases are tagged per supported game version.
- Single-player only. Modding can corrupt saves, so keep backups.
- Install re-signs the game binary (ad-hoc) so the console can load. This is reversible at any time via Steam's "Verify Integrity of Game Files".
- macOS arm64 only.

## Support

NightCity Console is free. This repository publishes its launcher and legacy overlay/command runtime; the new native runtime and framework ports are currently maintained separately. If it saved you some hassle and you want to support development, you can buy me a coffee. Completely optional, and very appreciated.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ysrdevs)

## Credits and acknowledgements

macOS port and reverse engineering by ysrdevs (Yuvraj Singh).

This project rebuilds capability pioneered by the Windows Cyberpunk 2077 modding ecosystem. NightCity Console supports selected CET-style console commands and item codes. This does not provide general compatibility with CET's Lua API or Windows CET mods.

Upstream originals, used under their respective MIT licenses (see each project's LICENSE for the exact name and year):

- RED4ext and RED4ext.SDK by WopsS (Octavian Dima). The macOS hooking framework is a port of this work.
- TweakXL, ArchiveXL, and Codeware by psiberx. The macOS modding integrations are ports of these projects.
- Input Loader and Mod Settings by Jack Humbert. The 2.5 payload includes native macOS integrations.
- Cyber Engine Tweaks (CET) by the CET team. Selected console commands use familiar CET-style syntax.

Tools and libraries:

- Frida (retained legacy runtime instrumentation and in-process script host).
- Dear ImGui by Omar Cornut (overlay UI).
- Ghidra (reverse engineering and decompilation).
- redscript by jac3km4.
- Vendored libraries: nameof and semver by Neargye, PEGTL by taocpp, WIL by Microsoft, spdlog by gabime, fmt by fmtlib, simdjson, toml11, and fishhook.

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for component roles and license details.

Cyberpunk 2077 is a trademark of CD PROJEKT S.A. This is an unofficial, non-commercial, single-player tool and is not affiliated with or endorsed by CD PROJEKT RED.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 ysrdevs.
