# GOG Support (experimental)

`runtime/red4ext_hooks_gog.js` is a port of the command engine to the **GOG macOS build** of
Cyberpunk 2077 **v2.3.1** (Apple Silicon). It has been tested in-game on a GOG install:
item/money grants, street cred / level / perk / attribute / relic points, godmode, invisibility,
infinite ammo, heal, teleport, time/slowmo, police toggle, facts, and vehicle summon all work.

## Using it on a GOG install

Point the Frida gadget at the GOG script in `FridaGadget.config`:

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
