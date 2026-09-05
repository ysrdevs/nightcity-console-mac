# GOG Support (experimental)

`runtime/red4ext_hooks_gog.js` is a port of the command engine to the **GOG macOS build** of
Cyberpunk 2077 **v2.3.1** (Apple Silicon). It has been tested in-game on a GOG install:
item/money grants, street cred / level / perk / attribute / relic points, godmode, invisibility,
infinite ammo, heal, teleport, time/slowmo, police toggle, facts, and vehicle summon all work.

## Using it on a GOG install

First populate `deps/` using the [dependency setup instructions](DEPENDENCIES.md).
Build the GUI with `./launcher/build-app.sh`, then open `build/NightCity Console.app`.
The launcher detects `/Applications/Cyberpunk 2077` automatically, or you can select another
location with **Browse**. A previously selected game folder takes priority.

Click **Install**, then **Play**. The launcher recognizes the GOG bundle ID or its GOG framework,
installs both command engines, and writes a store-specific `FridaGadget.config`. It does not
start Steam or pass `SteamAppId` to the GOG game. If macOS blocks installation or re-signing,
use **Open Privacy Settings** to enable **App Management** for NightCity Console; game libraries
on external drives may need **Full Disk Access** instead. After replacing an older launcher,
click **Reinstall NightCity Console** while the game is closed, then launch again.

For the developer workflow, run:

```bash
CP2077_DIR="/Applications/Cyberpunk 2077" ./dev/launch.sh
```

This builds, installs, and launches the console. The script selects the command engine by store
and clears any inherited `SteamAppId` for GOG. The source config keeps the Steam default; neither
launcher requires you to edit it manually. The installed GOG config looks like this:

```json
{
  "interaction": {
    "type": "script",
    "path": "./red4ext_hooks_gog.js",
    "on_load": "resume"
  }
}
```

Everything else (IPC command file, catalog, overlay) works as on Steam.

The integration with current upstream uses Frida Gadget and the overlay directly on GOG.
Steam's RED4ext loader, address library, plugin deployment, redscript compilation, and
hardcoded hook allowlist are excluded from the GOG launch path. Advanced mod installation
is therefore unavailable on GOG; existing Steam support is retained. The console/reset
commands were play-tested on the earlier GOG branch. On 2026-09-05 the rebased build also
passed an initial GOG smoke test on macOS 26.6.2: reinstall, launch, save load, player
capture, `help` listing both reset commands, and `money 1` completing successfully.
Steam regression testing and broader feature coverage remain outstanding.

## What differs from the Steam engine

The GOG binary is not just the Steam binary with shifted offsets — two structural differences
required different mechanisms:

1. **All engine offsets differ.** The GOG equivalents used by the script:
   - `0x27ba1b4` — 5-arg universal caller `Exec(fn, ctx, frame, result, retType)` (Steam `0x2173120`)
   - `0x27b9de8` — scripted-body executor (ctx capture point; real `this` at `frame+0x40`)
   - `0x27b9c88` — per-script-call drain point used as the command trampoline
   - `0x26ae7a4` — RTTI singleton getter
   - `0x31e18` / `0x34fb8` — `Main` / shutdown hook points

2. **The GOG RTTI system is non-virtual.** Steam's virtual `GetClass`/`GetEnum` calls through the
   registry vtable fault on GOG. The GOG engine instead:
   - builds a `CName-hash → CClass` map from runtime capture at the executor/universal-caller
     hooks, plus a `mapscan` that walks the RTTI type arrays directly (crash-safe: candidate
     pointers are gated on the one shared `CClass::GetName` fn pointer already proven by capture);
   - resolves enum members directly off the parameter-type meta instead of virtual `GetEnum`.

3. **Scripted (redscript) classes are invisible to both capture and mapscan.**
   `PlayerDevelopmentSystem` etc. never appear in the walked RTTI arrays (native classes only),
   and all scripted systems share their native base's C++ vtable, so vtable-deduped capture only
   ever sees the first one. The GOG engine resolves scripted systems through the captured
   `gameScriptableSystemsContainer` instance (`Get(CName)`), then registers the returned object's
   class meta via its `GetType` vtable slot (`regFromInstance`) so method resolution works. This
   is what makes street cred / perk / attribute / relic commands work on GOG.

4. **Shutdown teardown crashes with hooks attached** (stale trampoline in static destructors,
   after saves are flushed). The GOG script routes `exit()` → `_exit()` and `_exit(0)`s when
   `Main` returns, so quitting is clean.

## Performance design

The engine keeps **zero Frida hooks on the script-VM hot path in steady state**:

- The two capture hooks auto-detach once essentials are captured (player, TDBID→ItemID
  converter, systems container, transaction/player/status-effect systems). The `recap` command
  re-arms them (use after loading a different save if commands misbehave).
- The command trampoline attaches only while a command is pending and detaches when the queue
  drains.
- Diagnostic logging is off by default; `debug on` / `debug off` toggles it at runtime.

## Not ported

- The cybermodman localized-name fill hook (`FUN_102f6ea14` on Steam) is not wired into the GOG
  engine.
