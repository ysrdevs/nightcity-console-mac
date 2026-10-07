# cet-lua — implementation status (2026-09-01)

A CET-compatible Lua modding host for the macOS ARM64 build of Cyberpunk 2077 (Steam 2.3.1). Loads as a
RED4ext plugin, embeds LuaJIT (interpreter mode) + sol2, and re-implements the CET Lua framework
(`registerForEvent` / `Observe` / `Override` / `Game.*` reflection) on the proven macOS engine primitives.

Goal: run real CET Lua mods (the mansion DLC mod is the target) without Windows / Cyber Engine Tweaks.

Plan of record: [CET-LUA-MODS-MACOS-PORT-PLAN.md](../../docs/CET-LUA-MODS-MACOS-PORT-PLAN.md).

---

## TL;DR

- **Phases 1–4 are written, compile with zero errors, and are deployed.** `cet-lua.dylib` (arm64, self-contained,
  LuaJIT static-linked) sits in `red4ext/plugins/cet-lua/` alongside ArchiveXL/Codeware/TweakXL.
- **Phase 1 (VM + loader + events + reflection)** is ready to validate in-world. Needs a launch.
- **Phase 2–3 (Observe / ObserveAfter / Override)** is fully implemented — descriptor swap + verified arm64
  trampoline + arg-marshalling dispatch. All engine addresses resolved (Ghidra hunt 2026-09-01). **Arming is
  OFF by default** and gated behind a runtime flag, because a wrong swap corrupts RTTI silently and the game has
  not been launched to validate. Flip it on for one validation session (below) — no rebuild needed.
- The only remaining work is **in-game validation** (which I can't do — the user launches) and whatever that
  surfaces.

---

## What's built (by file)

| File | Role | State |
|------|------|-------|
| `src/main.cpp` | Plugin entry; VM boot; API setup; drives onInit/onUpdate via the RED4ext `gameStates` SDK (Running state) | ✅ compiles/deploys |
| `src/addrs.hpp` | Proven macOS RVAs (executor `0x2173120`, RTTI, CNamePool), MH_EXECUTE base | ✅ |
| `src/addrs_gates.hpp` | The Observe/Override "gate" RVAs from the Ghidra hunt + the runtime arming flag | ✅ addresses filled |
| `src/reflect.hpp` | RTTI lookup + `CallWithArgs` (synthetic CStackFrame → universal executor) | ✅ |
| `src/luatypes.hpp` | CName/TweakDBID/EntityID/ItemID/Vector4/… value types; ULL cdata reader | ✅ |
| `src/game.hpp` | `Game.*` reflection facade; ToRED/ToLua marshalling; ClassRef dispatch; GameInstance | ✅ |
| `src/events.hpp` | `registerForEvent` bus (onInit/onUpdate/onShutdown) | ✅ |
| `src/sandbox.hpp` | Per-mod environment + sandboxed `require`; scans CET mods dirs | ✅ |
| `src/arm64stub.hpp` | **arm64 trampoline codegen** (MOVZ/MOVK/BR), MAP_JIT exec memory — encoder verified byte-identical to `clang -arch arm64` | ✅ verified |
| `src/observe.hpp` | Observe/Override: record → resolve → descriptor swap → dispatch (arg-pop via SDK `OpcodeHandlers::Run`, marshal, run before/override/after, forward via executor) | ✅ compiles; arming gated |
| `build.sh` | Reproducible build (fetches LuaJIT/sol2/CET ref, links macOS RED4ext.SDK) | ✅ |

---

## The Ghidra hunt (2026-09-01) — resolved gate addresses

RVA = Ghidra address − `0x100000000`.

| Target | RVA | Conf | Needed for |
|--------|-----|------|-----------|
| `CBaseFunction::InternalExecute` (universal executor) | `0x2173120` | **confirmed** | forwarding + all reflection (already pinned) |
| `OpcodeHandlers` dispatch table | `0x908b798` | HIGH | arg-pop (via SDK header-only `OpcodeHandlers::Run`; already in the macOS reloc map) |
| `CClassFunction_ctor` | `0x2173760` | HIGH | trampoline creation (`CClassFunction::Create`, already SDK-ported, calloc's 0xC0) |
| `rtti::Function::InternalCall` | `0x2172f90` | HIGH-MED | Override of *scripted* (non-native) funcs only |
| `CClass::CreateFunction` / alloc | `0x2198410` | MED | not needed for native Observe (calloc path is size-safe) |
| `GameAppRunningState::OnTick` | `0x3d8d7f8` | HIGH | optional (we use the gameStates SDK) |
| `TweakDB::LoadOptimized` | `0x2b75744` | MED | optional (onTweak) — note: NOT `0x2b7be94` (that's a name resolver) |
| `CScriptDataBinder::LoadOpcodes` | `0x3d9a028` | LOW | optional; verify at runtime |
| `PlayerSystem::OnPlayerMainObjectSpawned` | unresolved | — | optional (pure C++, no CName literal) |

For **native-method Observe** (what mansion uses) every required address is present: executor + OpcodeHandlers
table + `CClassFunction::Create`. The descriptor swap is `CClassFunction(0xC0) ↔ CClassFunction(0xC0)`, so it's
size-safe without CET's over-alloc `CreateFunction` detour (which has no single hook site on macOS anyway — the
pool alloc is inlined at ~2800 call sites).

---

## Phase 2–3 mechanism (macOS port of CET `FunctionOverride`)

1. **Record** (`init.lua` time): `Observe/ObserveBefore/ObserveAfter/Override` push `{class, func, kind, cb}`.
2. **Install** (Running-state enter): resolve each target `CClassFunction` in RTTI, group by target. If arming is
   requested:
   - `CClassFunction::Create(...)` a trampoline whose native handler is a **36-byte arm64 stub** that sets
     `x4 = the real function` and tail-calls `HandleOverridenFunction`. (CET uses an x86-64 Xbyak stub that pushes
     the 5th arg on the stack; on arm64 the 5th integer arg is just `x4`, so it's a simpler tail call. The stub
     encoder is verified byte-identical to the assembler.)
   - `CopyFunctionDescription(trampoline ← real)` so it forwards with the real signature.
   - **Three-way swap** of the full `0xC0`: now calling `real` runs our stub → dispatch; the trampoline holds the
     pristine original for forwarding.
3. **Dispatch** (`HandleOverridenFunction`): pop args off the `CStackFrame` via the SDK's header-only
   `OpcodeHandlers::Run` (indexes table `0x908b798`), marshal to Lua (`game::ToLua`), run
   `Before → Override(or forward original) → After`, forward through the pinned executor `0x2173120`. Defensive:
   any failure forwards the original so a bad Lua hook can't brick the method.

---

## How to validate in-world (the launch step — user)

Launch from `NightCity Console.app` as usual. Then check `/tmp/cet-lua.log`.

### Phase 1 — expect (no arming needed)
```
[cet-lua] Load: imageBase=... executor=...
[cet-lua] VM up (LuaJIT interpreter); ULL64=13312760010544421172
[cet-lua] gameStates->Add(Running) = ok
[cet-lua] Running state entered; ... loading mods + onInit
[cet-lua] loaded N mod(s)
[mod] spine: onInit fired            <- the spine test mod proves VM+loader+event
[mod] spine: Game.GetPlayer -> ...   <- proves Game.* reflection end-to-end
```
If Phase 1 logs look right, the host is live. mansion's `init.lua` should load (it only *records* its Observes,
which always succeeds); its actual behavior needs Phase 2 armed.

### Phase 2–3 — arm for ONE validation session
Only after Phase 1 is confirmed. Arming performs the RTTI descriptor swap (MED-confidence; a wrong address
corrupts RTTI silently), so it is opt-in:

```bash
touch /tmp/cetlua_arm_hooks     # or launch with CETLUA_ARM_HOOKS=1
```
Relaunch, then in `/tmp/cet-lua.log` expect:
```
[cet-lua] Observe/Override: K recorded, K resolved in RTTI, M distinct methods
[cet-lua] Observe/Override ARMED M method(s) via descriptor swap (CETLUA_ARM_HOOKS)
```
Then exercise the mansion mod. If the game crashes or RTTI misbehaves, remove the flag
(`rm /tmp/cetlua_arm_hooks`) and relaunch to fall back to record-only (safe) mode, and report the log.

---

## Deployed layout

```
<GAME>/red4ext/plugins/cet-lua/cet-lua.dylib          (ad-hoc signed, arm64)
<GAME>/red4ext/plugins/cet-lua/mods/spine/init.lua    (Phase-1 smoke test)
<GAME>/bin/x64/plugins/cyber_engine_tweaks/mods/mansionDLC/   (22 lua files)
<GAME>/archive/{pc,Mac}/mod/mansionDLC.archive + .xl
```

## Known gaps / next
- `NewObject` (MakeHandle<T>) is a stub — needs the Codeware object-creation path if a mod constructs engine
  objects from Lua.
- `ModArchiveExists` / `GetLocalizedText` are permissive stubs.
- Override of *scripted* (non-native) functions would additionally route through `rtti::Function::InternalCall`
  (`0x2172f90`) — implemented addresses are captured but the native path is what's wired; validate native first.
- Everything past "compiles + deploys" is pending a launch. **I cannot launch; the user does.**
