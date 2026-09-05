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
- Cyberpunk 2077 **v2.3.1**, **Steam**. Experimental GOG support: use `runtime/red4ext_hooks_gog.js` (see `docs/GOG.md`).

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
