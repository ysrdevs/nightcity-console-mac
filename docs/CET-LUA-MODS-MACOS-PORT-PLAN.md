# CET Lua mods on macOS - how CET does it on Windows and the port plan

Plan of record. Target: run a full Cyber Engine Tweaks (CET) Lua mod - concretely `mansionDLC` - on the native macOS (Apple Silicon) Steam build of Cyberpunk 2077 v2.3.1. Synthesized from five research passes (CET core runtime + events, Observe/Override, reflection + types, the current macOS runtime + gap, and the mansion mod's required API surface). All Windows source references are to `maximegmd/CyberEngineTweaks@master`; all macOS addresses are for Steam 2.3.1 arm64 and must be re-verified in Ghidra (`/Users/ysr/cp2077/_ghidra`) because the RED4ext `addresses.json` is unreliable on this build.

---

## 1. Executive summary

**Running full CET Lua mods on macOS is feasible, and `mansionDLC` in particular is a realistic near-term target.** The hard, platform-specific reverse engineering that CET depends on is already done and proven in-game on this exact build:

- the engine's universal function executor (`imageBase+0x2173120` = `CBaseFunction::InternalExecute`), driven with a hand-built `CStackFrame` - the same call ABI CET uses;
- full RTTI access (`CRTTISystem::Get` at `0x2188e8c`, class/enum/function/property/static walking with confirmed struct offsets);
- argument marshalling for the common set (primitives, enums, `CName`, `TweakDBID`, `ItemID`, handles, struct blobs) and return reads;
- manual inline function hooks (the frida-gum keystone that fixed macOS-27's HookAfter breakage);
- native registration at the correct RTTI-ready-but-pre-bind window (`CBaseEngine::InitScripts` entry `0x3d8c188`, gated on ready-flag byte `0x7d6a268`);
- a safe main-thread re-entrancy window for game calls (drain a queue in the executor's `onLeave` at call-depth 0);
- the object-lifecycle relocation cluster (real `Handle` ctor / refcount inc / `DecWeakRef`) needed to create and hold engine objects.

**What is missing is not engine capability - it is the entire CET *framework* layer.** The current macOS runtime (`/Users/ysr/cet-mac/runtime/red4ext_hooks.js`, "MINI-CET v3") is a Frida/QuickJS agent exposing a *fixed command set* (give/tweakload/call/observe/...). It is not a Lua VM, has no mod loader, no `require`, no event bus, no per-frame `onUpdate`, no `ObserveAfter`, no `Override`-with-call-original, and no `Game.*` reflection surface exposed to script. `mansionDLC` is 20 ordinary Lua modules driven by `registerForEvent`, `Observe`/`ObserveAfter`/`Override`, and `Game.*` reflection - none of which the JS command runtime can execute.

### Recommendation (decisive)

**Build a RED4ext C++ plugin that embeds LuaJIT (OpenResty, GC64) + sol2, and re-binds CET's `src/scripting` and `src/reverse` layer onto the proven macOS address table and the frida-gum inline-hook keystone.** Ship it as a dylib that loads exactly like ArchiveXL / Codeware / TweakXL already do. Auto-run `mods/<name>/init.lua` headless.

This beats the two alternatives:

- **Frida-JS embeds Lua (drive `lua_*` C API through `NativeFunction`).** Mechanically possible but you would reimplement all of CET's `src/scripting` across a JS - Lua boundary, and fire Lua callbacks from `Observe` (which runs on the game thread inside the executor hook) back into the QuickJS heap off-thread. Fragile, slow to build, no upside. Rejected.
- **Transpile / interpret the mod without Lua.** `mansionDLC` has 51 `Observe`, 9 `Override`, 3 `ObserveAfter`, closures, a `Cron` scheduler, a `GameUI` state machine, ink widgets and a 20-module `require` graph. Interpreting that in JS means writing a Lua interpreter - strictly worse than embedding one. Rejected.

The C++ plugin path is the only one that runs a real CET mod **unchanged**, and it reuses every primitive already proven on this build. sol2 + LuaJIT is a known-good pairing (it is exactly CET's own `SOL_LUAJIT=1` configuration), so CET's binding code ports with minimal structural divergence.

### Two calls that shape the whole build

1. **Use LuaJIT, not PUC Lua 5.4 - but start with the JIT compiler disabled (`jit.off()`, interpreter mode).** CET mods are written for LuaJIT and `mansionDLC` proves it: it builds `entEntityID` from full 64-bit `ULL` cdata literals such as `13312760010544421172ULL`. That value (1.33e19) exceeds signed int64 max (9.22e18); in PUC Lua 5.4 it silently becomes a float and loses precision, and the `ULL` suffix is not even valid 5.4 lexer syntax. Only LuaJIT's FFI cdata carries it losslessly and parses the literal. The prior "LuaJIT is a non-starter on macOS" concern applies only to the JIT *trace compiler* (which allocates `MAP_JIT` W^X pages); the LuaJIT *interpreter* is a static hand-written asm loop in signed `__TEXT` plus data-only cdata allocation - W^X-safe and fully cdata/FFI/`ULL`-capable. Run interpreter-only first (matching CET's user-toggleable `EnableJIT`), and enable the JIT later if wanted: the game is already re-signed with `allow-jit` and `allow-unsigned-executable-memory` (see `cet-mac/TECHNICAL.md` section 8), so the JIT path is available but is not on the critical path.

2. **The overlay is off the critical path.** `mansionDLC` registers exactly two events - `onInit` and `onUpdate` - and `onUpdate` is just `Cron.Update(dt)`. No mod file registers `onDraw`, `onOverlayOpen`, or `onOverlayClose`, and there is no `ImGui.*` use anywhere. That removes the single most macOS-divergent CET subsystem (the D3D12/ImGui overlay, which on macOS would mean a Metal ImGui backend hooked into the game's `CAMetalLayer` present) from the requirements for this mod. `TriggerOnDraw`/`TriggerOnOverlay*` can be permanent no-ops. This is what makes the whole effort tractable now rather than a from-scratch overlay project. (A native Metal overlay already exists in `cet-mac/overlay` for the console, but the mod does not need it.)

Bottom line: this is a **porting** job on top of a **proven** engine-interface layer, with the hardest CET subsystem excluded by the target mod's actual surface. Recommended and scheduled below.

---

## 2. How Windows CET works, subsystem by subsystem

### 2.1 Runtime, mod loader and events

**VM and binding.** OpenResty LuaJIT (GC64) bound with sol2 (`SOL_LUAJIT=1`, `SOL_ALL_SAFETIES_ON`). One shared `sol::state` for the whole process (`Scripting::m_lua`), wrapped `Lockable<sol::state, std::recursive_mutex>`; every trigger takes `GetLockedState()` first. Libraries opened: `base, string, io, math, package, os, table, bit32` (+`jit`), then `sqlite3`, `json`, `IconGlyphs`.

**Sandbox.** Per-mod `sol::environment` layered over a shared, deep-copied *whitelist* of `_G` (`LuaSandbox::Initialize`, `s_cVMGlobalObjectsWhitelist`): `assert, pairs, pcall, setmetatable, string, table, math, bit32, json, ...`; no `loadstring`/`dofile`/`os.execute`/raw `require` from `_G`; `os` reduced to `clock/date/difftime/time`. Mod code runs *in* its env via `state.script_file(path, env, load_mode::text)` - source only, precompiled bytecode refused. Globals are progressively frozen as the engine crosses milestones (`PostInitializeScripting` protects `CName/TweakDBID/ItemID/Observe/Override/...`; `PostInitializeTweakDB` protects `TweakDB`; `PostInitializeMods` protects `Game/GetSingleton/NewObject/...`), so a mod's `onInit` sees a fuller API than its top-level chunk did.

**Loader.** `ScriptStore::LoadAll` iterates `mods/` subdirs, skips those without `init.lua` and the reserved name `cet`, builds a `ScriptContext` per mod, and executes `init.lua` in the sandbox. **The return value of `init.lua` becomes the mod object** (`GetMod(name)`).

**`require`** is a sandboxed replacement, not stock: rooted at the mod dir it tries `<arg>` -> `<arg>.lua` -> `<arg>/init.lua`; rejects absolute paths and `..`; caches by absolute path; returns a `(module, err)` tuple.

**Events.** `registerForEvent(name, fn)` is injected into the env only *during* `init.lua` and nil'd immediately after, so events register at load time only. Accepted set and drivers:

| event | driver (Windows) |
|---|---|
| `onHook` | after RTTI/scripting init, before mods run |
| `onTweak` | after TweakDB loads |
| `onInit` | after player spawn / all systems ready |
| `onShutdown` | game shutdown task |
| `onUpdate(dt)` | **every running-frame tick** |
| `onDraw` | **every present, inside ImGui frame** |
| `onOverlayOpen`/`onOverlayClose` | overlay toggled |

Dispatch fans out `Scripting::TriggerOnX -> ScriptStore -> each ScriptContext`, locking the state and calling the stored `sol::function`.

**`onUpdate` is not driven by present.** In `LuaVM::Hook`, CET does `GameMainThread::Get().AddRunningTask(...)` with a task that computes a wall-clock `dt` and calls `s_vm->Update(dt) -> TriggerOnUpdate(dt)`, returning `false` so it is never dequeued and runs every frame. `GameMainThread` MinHook-detours the four game-state `OnTick` functions and drains a task queue on each tick; the running-state one (`CRunningState_OnTick`, hash `3592689218` = `red::GameAppRunningState::OnTick`) is the heartbeat.

**`onDraw`** is driven by the D3D12 present hook (`CRenderNode_Present_DoInternal`, hash `2468877568` = `GpuApi::Present`) -> `ImGui::NewFrame` -> `GetVM().Draw() -> TriggerOnDraw`, bracketed with `SetImGuiAvailable(true)`. Windows-only; not needed for mansion.

**Bootstrap gates** (each a one-time DLL-load hook that fires a "Post-Initialize" stage as the engine crosses a milestone):

1. `CScriptDataBinder::LoadOpcodes` (hash `3442875632`) - RTTI/script binder is up. Runs `Scripting::Initialize` (opens libs, builds sandbox, **`LoadAll` executes every `init.lua` here**) then `PostInitializeScripting` (registers `Game`, the reference usertypes, `CName/TweakDBID/ItemID/...`, `Observe/ObserveBefore/ObserveAfter/Override`, `NewObject/GetSingleton/GetMod`, then `TriggerOnHook`).
2. `game::data::TweakDB::LoadOptimized` (hash `3602585178`) -> `PostInitializeTweakDB` -> bind `TweakDB` global, `TriggerOnTweak`.
3. `cp::PlayerSystem::OnPlayerMainObjectSpawned` (hash `2050111212`) - first spawn only -> `PostInitializeMods` -> `RegisterOverrides`, **`TriggerOnInit`**, then set `LuaVM::m_initialized = true` (the gate `Update`/`Draw` check before firing `onUpdate`/`onDraw`).

Observable order a mod sees: top-level chunk (RTTI up) -> `onHook` -> `onTweak` -> `onInit` (player in world) -> `onUpdate` every frame.

### 2.2 Observe / ObserveAfter / Override (the RTTI method-hook core)

The one big idea: **CET does not detour each hooked method.** It installs exactly **two** global engine detours once, then hooks each individual method by **swapping RTTI function-descriptor objects** - pure data manipulation. 51 hooks = 51 struct swaps + 51 tiny code stubs behind 2 inline hooks, not 51 inline patches.

The two global detours (`FunctionOverride::Hook`):

- `CScript_RunPureScript` (hash `3791200470`, = `rtti::Function::InternalCall`) -> `HookRunPureScriptFunction`. Catches the *scripted* invocation route.
- `CScript_AllocateFunction` (hash `160045886`) -> `HookCreateFunction`. Forces every RTTI function allocation to max size so a later object swap cannot overflow a neighbouring allocation.

A third routine is *called*, not hooked: `CBaseFunction_InternalExecute` (the universal executor) via `UniversalRelocFunc<TCallScriptFunction> CallScriptFunction` - **this is the macOS `imageBase+0x2173120` primitive.**

**Resolution** (`FunctionOverride::Override`): `CRTTISystem::Get()->GetClass(name)`, falling back through `scriptToNative` for redscript-only class names; then `CClass::GetFunction(fullName)`, falling back to `RTTIHelper::FindFunction` which walks `funcs`/`staticFuncs` by `FNV1a64(fullName)` up the `parent` chain and also consults `@addMethod` extended globals. Native vs scripted is transparent here - both are `CBaseFunction*` in the same arrays; the only distinguisher is the `flags.isNative` bit. Overloads are disambiguated by a `;`-encoded signature in the name (e.g. `"CanPlayerTimeSkip;PlayerPuppet"`).

**Hook install** (per method, first time):

- **Step A - trampoline descriptor.** Build a small codegen stub (`OverrideCodegen`) that appends a 5th argument (the original descriptor pointer) and tail-calls the single handler `HandleOverridenFunction`. Create a `CClassFunction` whose native handler is that stub; `CopyFunctionDescription(..., forceNative=true)` copies `fullName/shortName/returnType/params/localVars/flags` and `memcpy`s the `bytecode`/`CCompiledCode` region, then forces `isNative=1` (the marker both detours use to recognise a hooked function).
- **Step B - three-way byte swap.** `memcpy` the raw descriptor bytes: `tmp <- realFunc`, `realFunc <- stubFunc`, `stubFunc <- tmp`. Now the object *at the original address* is the hook (handler = stub, `isNative=1`), so every vtable slot, RTTI table entry and script bytecode reference that points at that address is redirected with zero per-site patching; the other allocation (`chain.Trampoline`) holds the pristine original and is how CET calls through. Layout-exact and self-described as "UB" - works only because `CBaseFunction` (0xB0) / `CClassFunction` (0xC0) / `CGlobalFunction` (0xB8) layout is fixed.

**Native path** (`HandleOverridenFunction`): pops args off the `CStackFrame` by constructing each declared param type and running `OpcodeHandlers::Run(*frame->code++, ...)`, converts each to Lua via `Scripting::ToLua`, runs the CallChain, and calls the original via `CallScriptFunction(chain.Trampoline, ...)`.

**Scripted path** (`HookRunPureScriptFunction`, the `InternalCall` detour): guarded by `apFunction->flags.isNative == 1`; reads args directly out of `CScriptStack` (detecting one of two stack layouts with `isArrayArgs = stack->value != ret.value`), runs the chain, or forwards to `RealRunPureScriptFunction(chain.Trampoline, ...)`.

**CallChain semantics** (`ExecuteChain`): `Before` callbacks (return ignored) -> `Override` (absolute; user callback receives `self, args..., next`, where `next` continues the chain and ultimately calls the real function; **its return value is written back** into `apResult` and out-params via `ToRED`) -> real function if no override -> `After` callbacks (return ignored). `this` is `WeakHandle<IScriptable>` from `stack->GetContext()` / `frame->context`, pushed as `args[0]` for non-static functions.

**Threading/locking.** Callbacks run on the calling (game main) thread. The `sol::state` recursive mutex allows a hooked method to run Lua that calls another hooked method. `m_functions` is a `shared_mutex`; the detours take it shared and **unlock it before calling the original** so nested hooked calls do not deadlock. `Override` recursion is bounded structurally by `WrapNextOverride` walking a fixed chain index.

### 2.3 `Game.*` reflection and marshalling

`globals["Game"] = this` - `Game` **is** the `Scripting` singleton exposed as a `no_constructor` usertype, so `Game.Foo` hits `Scripting::Index("Foo")`: check the memoized `m_properties` cache, else `RTTIHelper::ResolveFunction(name)` for a global RTTI func, cache and return a sol callable. `RTTIMapper::RegisterDirectGlobals` front-loads the global func table (skipping exec funcs and `::` class members), so `GetWorkspotSystem`, `GetTeleportationFacility`, `FindEntityByID`, `NameToString`, `GetPlayer` etc. are all **global RTTI functions**, not methods.

**GameInstance auto-injection.** These globals are engine `static func X(self: ScriptGameInstance) -> ...`, but Lua calls them with no argument. In `RTTIHelper::ExecuteFunction` the per-param loop fills any param of type `m_pGameInstanceType` with the static `s_gameInstance`; `isOut` params get an owned placeholder; `isOptional` are filled from Lua or left null; everything else is `Scripting::ToRED(luaArg, paramType, &scratch)`.

**`GetSingleton(name)`** returns a `SingletonReference{lua, GetClass(FNV1a64(name))}` - a `ClassType` with no handle whose method calls pass the class's static instance as context.

**The invoke keystone.** CET does not use `CStack`/`CBaseFunction::Execute`; it hand-builds a synthetic `CStackFrame` bytecode stream and calls the engine's script-function entry directly:

```
NopOp=0  ParamOp=27  ParamEndOp=38   MaxCodeSize=264
char code[264]; CStackFrame frame(nullptr, code);
per param: if optional && no value -> *code++ = NopOp
           else -> *code++ = ParamOp; write CBaseRTTIType* type (8); write void* value (8)
*code = ParamEndOp; frame.code = code; frame.func = s_dummyFunction;
CallScriptFunction(func, ctx ? ctx : s_dummyContext, &frame, result.value, result.type);
```

`CStackFrame { char* code@0; CBaseFunction* func@8; localVars@0x10; params@0x18; ...; context@0x40 }`; `CStackType { CBaseRTTIType* type@0; ScriptInstance value@8 }` (0x10). `CallScriptFunction = UniversalRelocFunc(AddressHashes::CBaseFunction_InternalExecute)`.

**Returned object -> callable Lua object.** `Converter::ToLua` on a `Handle` return builds a `StrongReference` (or `WeakReference` for `WeakHandle`, `ClassReference` for a raw instance, `SingletonReference` for a system); all inherit `ClassType`, and `m_pType = handle->GetType()`. `ClassType::Index` is the metatable `__index`: resolve the member func (or property) on the live class, memoize, and on call route back through `RTTIHelper::ExecuteFunction` with the wrapped handle as `apContext`. Property writes go through `NewIndex -> SetProperty` using `CProperty` `type`/`valueOffset`. This is what makes `Game.GetWorkspotSystem():PlayInDevice(...)` chain.

### 2.4 Types

- **PODs** (`CName`, `TweakDBID`, `ItemID`, ...) via `LuaRED<T, REDName>`: `Is` compares `apRtti == GetType(FNV1a64(Name))`; `ToLua` copies into a Lua usertype (64-bit integrals emitted as strings to dodge double precision); `ToRED` allocates in the scratch allocator. Registered as usertypes with ctors + `ToString`.
- **`CName`**: holds the 64-bit `FNV1a64` hash; **`CName.add(str)` -> `CNamePool::Add(str)`**, which *registers* the string so the engine can later resolve hash -> string (exactly why mansion calls `CName.add("mansion_owned")`).
- **`TweakDBID`**: 32-bit name hash + 8-bit length; `operator+` composes child ids. **`ItemID`**: `{TweakDBID id; u32 seed; ...}`.
- **`Converter`** dispatches via a compile-time visitor over `{CNameConverter, TweakDBIDConverter, EnumConverter, BitFieldConverter, ClassConverter, RawConverter}` plus the reference usertypes; first `Is` match wins.
- **Arrays/CString/Variant**: `DynArray<T>` <-> 1-indexed Lua table (recursive), `CString` <-> Lua string, `Variant` re-dispatched on its inner `{type, value}`.
- **Handle lifetime**: `StrongReference` wraps `Handle<IScriptable>`; copy/destroy inc/dec the shared refcount block. CET's destructor deliberately nulls `instance`/`refCount` on shutdown so the Lua GC never frees live game memory.

---

## 3. macOS mapping, subsystem by subsystem

Legend: **HAVE** = proven in-game on this build; **BUILD** = new C++/Lua we must write; **HARD** = the specific risk.

### 3.1 Runtime, loader, events

- **HAVE**: nothing engine-specific is needed for the VM itself. The sandbox model, whitelist env, per-mod `sol::environment`, and sandboxed `require` are pure C++/Lua and port from CET as-is. The re-entrancy trick (drain a command queue in the executor `onLeave` at `depth==0`, `red4ext_hooks.js`) proves the safe main-thread window.
- **BUILD**: embed LuaJIT (GC64) + sol2 in the plugin; port `LuaSandbox`/`Sandbox`/`ScriptStore`/`ScriptContext`; wire the event bus; forward `dt` into `TriggerOnUpdate`.
- **BUILD (gates)**: hook three engine functions with the gum keystone and fire the stages: `CScriptDataBinder::LoadOpcodes` (VM init + `LoadAll` + register reflection), `TweakDB::LoadOptimized` (`onTweak`), `PlayerSystem::OnPlayerMainObjectSpawned` (`onInit`, once). We already register at the equivalent `InitScripts` entry window (`0x3d8c188`, gated on `0x7d6a268`); these are three more targets in the same table. CET's exact three-stage split is not required - the minimum for mansion is: VM up at RTTI-ready, `onInit` once at player spawn, `onUpdate` per frame.
- **HARD - driving `onUpdate` per frame.** Two options. (a) Hook `red::GameAppRunningState::OnTick` (CET hash `3592689218`) and call `TriggerOnUpdate(dt)` in the after-callback - clean, exactly the shape of our existing `observe` primitive, but the address must be found in Ghidra. (b) Reuse the existing executor `onLeave` drain, which already runs on the game script thread at a safe point, and tick from there - available today but only fires when a script function executes (not a true fixed cadence). Recommendation: ship (b) as a stopgap to unblock `Cron`, resolve `OnTick` and switch to (a) for correctness. `dt` is CET's own wall-clock delta, not the engine sim delta.
- **HARD - LuaJIT under the hardened runtime.** Run interpreter-only (`jit.off()`) initially so no `MAP_JIT` executable pages are generated; the static asm interpreter and cdata are W^X-safe. cdata/FFI/`ULL` still work (required for mansion's 64-bit `entEntityID` hashes). JIT can be enabled later - the game is re-signed with `allow-jit`.

### 3.2 Observe / ObserveAfter / Override

- **HAVE**: RTTI resolution (`CRTTISystem::Get` `0x2188e8c`, `GetClass`/`GetEnum`, `funcs@0x48`/`staticFuncs@0x58` walk by `FNV1a64(shortName@+0x10)`, `retType@+0x18`) - proven. The three-way descriptor `memcpy` swap is **byte-identical** on macOS (same RED4ext SDK layout; assert `RED4EXT_ASSERT_SIZE/_OFFSET` against the live binary before enabling). Calling the original = the universal executor (`0x2173120`) with the `ParamOp=27 / ParamEndOp=38` frame we already emit. A partial before-only `Observe` already exists (`cmObserve` + dispatch folded into the executor `onEnter`).
- **BUILD**: exactly **two** gum inline hooks (replacing MinHook): (1) `rtti::Function::InternalCall` (scripted route), (2) the RTTI function-pool allocator (over-allocate to `max(sizeof CClassFunction, CScriptedFunction)`), the latter installed **before** RTTI/scripts build - fits the `InitScripts` entry window we use. Per hooked method, an **arm64 (AAPCS64) stub** - simpler than Windows: the 5th arg goes in `x4`, not a stack slot:

  ```
  movz x4,#imm0 ; movk x4,#imm1,lsl 16 ; movk x4,#imm2,lsl 32 ; movk x4,#imm3,lsl 48   ; x4 = pRealFunction
  ldr x16,=HandleOverridenFunction ; br x16
  ```

  emitted into an `mmap(PROT_EXEC|PROT_WRITE)` W^X pool + `sys_icache_invalidate`. Port `CallChain`/`ExecuteChain`/`WrapNextOverride` and the `ToLua`/`ToRED` marshalling. Add the locking CET relies on: a recursive mutex around each callback dispatch and a `shared_mutex` over the hook registry, **released before calling the original**.
- **HARD - native vs scripted.** Native-method observes (game C++ methods) are the easier first milestone and need `OpcodeHandlers::Run` (opcode interpreter) for the native-path arg pop plus the `CStackFrame` layout. **Scripted-function hooking is the fragile half** and is mandatory for mansion (it observes redscript methods such as `QuestTrackerGameController::OnInitialize`): it depends on `rtti::Function::InternalCall`, the forced `isNative=1` marker being honoured by macOS dispatch, and the correct `CScriptStack` variant (verify which of the two shapes this build uses). The allocator over-alloc hook must be live before RTTI builds or swapping a 0xB8 scripted descriptor with a 0xC0 class-function trampoline overflows the neighbour.
- **HARD - function ctors.** Building trampolines needs `CClassFunction::Create`/`CClassStaticFunction::Create`. `CGlobalFunction_ctor` is already wired (we build a `$Lua` global in the reflection primitive; candidate `0x21739e8`); `CClassFunction_ctor` candidate `0x2173760` (7-arg macOS variant) - confirm both in Ghidra.

### 3.3 `Game.*` reflection and marshalling

- **HAVE**: the entire engine-facing half is proven. System acquisition three ways (`getViaGetter` static-func path = CET's auto-injected `s_gameInstance`; low-level `getSystem` container path; `getScriptableSystem` container `.Get(CName)`). Instance method dispatch on returned objects (runtime `CClass` via vtable `GetType@+8`, call with instance as context). Property offset/type resolution (`props@0x28`, `offset@+0x20`, `type@+0x00`). Arg marshalling for `i32/u32/i64/u64/f32/bool/CName/TweakDBID/ItemID/enum/handle/struct-blob` and return reads. The universal executor is the same function CET calls - both the canonical opcode-27 inline path (Codeware `Invocation.hpp`, compiled arm64, in-game) and our opcode-0x18 descriptor path work.
- **BUILD**: the Lua binding that exposes all of the above - `Scripting::Index` (the `Game` facade + lazy global-func resolve/cache), the `ClassType`/`Type` metatables (`__index`/`__newindex` -> RTTI dispatch), the primitive usertypes, `RTTIMapper` (enum tables, class type objects, direct-global registration), `GetSingleton`, and `GameInstance` auto-injection (synthesize `ScriptGameInstance`, auto-fill the `m_pGameInstanceType` param so mods call `Game.GetWorkspotSystem()` argument-free). Overload resolution by arg count/types (the `"OperatorEqual;IScriptableIScriptable;Bool"` and `"CanPlayerTimeSkip;PlayerPuppet"` signature-string forms). Out-param handling (allocate placeholder, marshal back into multi-return).
- **HARD - complete the Converter.** `DynArray<T>` <-> table (recursive), `CString` <-> string, `Variant`, `ScriptRef`, nested `Handle`/`WeakHandle` returns, and struct-by-value marshalling by field (not opaque blobs). None of these exist in the JS runtime; several are required by mansion.
- **HARD - Handle refcounting.** Replace the static `0x100000` fake refcount block with the **proven** object-lifecycle ops (`Handle_ctor` / refcount inc / `DecWeakRef` from the macOS object-lifecycle cluster), plus CET's GC-safety null-on-teardown, or the Lua GC will either free live game memory or leak.
- **HARD - CName reverse-lookup (known-finicky on macOS).** Forward hashing works (`fnv1a64`), but the JS never calls `CNamePool::Add` (candidate `0x3452ddc`), so `CName.add` does not intern new names and `NameToString` cannot resolve a modded name back to a string. `CName::ToString` is unreliable on this build (documented in memory: the dynamic-render diagnosis found `CName::ToString()==""`). For mansion, `CName.add("mansion_owned")` must actually intern via `CNamePool::Add`; verify the address and the by-value CName ABI (this build passes `CName` by value). Where reverse resolution of engine-internal names is needed, the existing `[CMN]` LocKey side-table hook is a display-only workaround, not a general solution.

### 3.4 Consolidated address table

**Known / proven (Steam 2.3.1 macOS arm64, `imageBase`-relative):**

| symbol | offset | use |
|---|---|---|
| `CBaseFunction::InternalExecute` (universal executor) | `0x2173120` | call any RTTI function |
| `CRTTISystem::Get` | `0x2188e8c` | RTTI root; `GetClass@vt+0x10`, `GetEnum@vt+0x18` |
| `CNamePool::Add` | `0x3452ddc` | `CName.add` (verify + by-value ABI) |
| `CNamePool::Get` | `0x3452bdc` | hash -> string (verify) |
| `CGlobalFunction` ctor | `0x21739e8` | global trampoline / `$Lua` dummy |
| `CClassFunction` ctor | `0x2173760` | instance-method trampoline (confirm) |
| `CBaseEngine::InitScripts` entry | `0x3d8c188` | native-reg / allocator-hook window |
| RTTI-ready flag byte | `0x7d6a268` | gate for the above |
| object-lifecycle cluster | see memory | real Handle ctor / refcnt / `DecWeakRef` |

**Unknowns to resolve in Ghidra (the port gates on these):**

| CET symbol (hash) | why needed |
|---|---|
| `rtti::Function::InternalCall` (`3791200470`) | scripted-exec detour for `Observe`/`Override` |
| RTTI function-pool allocator (`160045886`) | over-alloc detour so descriptor swap cannot overflow |
| `OpcodeHandlers::Run` | native-path arg pop |
| `red::GameAppRunningState::OnTick` (`3592689218`) | per-frame `onUpdate(dt)` driver |
| `CScriptDataBinder::LoadOpcodes` (`3442875632`) | VM init + `LoadAll` gate |
| `game::data::TweakDB::LoadOptimized` (`3602585178`) | `onTweak` gate |
| `cp::PlayerSystem::OnPlayerMainObjectSpawned` (`2050111212`) | `onInit` gate |

---

## 4. Phased plan

Each phase is independently testable and ordered to run `mansionDLC` as early as possible. Mansion features are named per the surface analysis (Tier 0 = loads without error, Tier 1 = detects session start, Tier 2 = places interactions/workspots).

### Phase 1 - the spine: VM + loader + events + read-only reflection + basic types

**Build.** RED4ext C++ plugin (loads like ArchiveXL/Codeware/TweakXL). Embed LuaJIT GC64 + sol2 (`jit.off()`). Port `LuaSandbox`/`Sandbox`/`ScriptStore`/`ScriptContext` (whitelist env, per-mod `require`, `init.lua` discovery, mod-object return). Event bus with `registerForEvent` accepting the full name set but only wiring `onInit` and `onUpdate` (others stored, never fired for now). Hook `PlayerSystem::OnPlayerMainObjectSpawned` -> `TriggerOnInit` once; drive `onUpdate(dt)` from the executor-`onLeave` stopgap (§3.1). Bind `Game` as the reflection facade over the proven `resolveFunc`/`callFunc` path (read-only calls: system getters, `GetPlayer`, `NameToString`, `FindEntityByID`), `GetSingleton`, and the load-time type ctors: `Vector4`, `EulerAngles`, `HDRColor`, `WorldTransform`, `TweakDBID`, `entEntityID` (with 64-bit `ULL` via cdata), `Enum.new`, `CName.add` (wired to `CNamePool::Add`), plus stubs for `GetLocalizedText`, `ModArchiveExists`, and a truthy `ArchiveXL` global. `Observe`/`ObserveAfter`/`Override` exist as **no-throw registrations** (store the target, do nothing yet) so `onInit` completes.

**Unlocks.** Tier 0: `mansionDLC` loads, `require`s its 20 modules, runs `onInit` to completion, constructs its 25+ workspot objects and value types, registers all 25 hooks without error, and ticks `Cron` via `onUpdate`.

**Biggest risk.** LuaJIT-interpreter integration under the hardened runtime (mitigated by `jit.off()`), and the load-time type ctors needing real engine object allocation for the RTTI-object `.new()` calls (`MappinData`, `worldEffectBlackboard`, the interaction-hub value-objects) - use the proven object-lifecycle cluster, not tables.

### Phase 2 - Observe / ObserveAfter (native first, then scripted)

**Build.** The two gum global detours (`rtti::Function::InternalCall` + the function-pool allocator) and the per-method arm64 stub + three-way descriptor swap. `CallChain` with `Before`/`After` only (no `Override` yet). RED -> Lua arg marshalling for observers (read-only; return ignored - the easy direction). Native-method path first (needs `OpcodeHandlers::Run`), then the scripted path (`isNative=1` marker + correct `CScriptStack` variant). Registry `shared_mutex`, released before the original; recursive dispatch mutex.

**Unlocks.** Tier 1: the GameUI Session hooks (`QuestTrackerGameController::OnInitialize`/`OnUninitialize`) fire, so session-start is detected and `world/logic/terminal.onSessionStart` run; the mod's many `Observe`/`ObserveAfter` targets (elevator style, fast-travel terminal, world-interaction mappins) begin reacting. Requires the Tier-1 read calls inside `refreshCurrentState` to return sane values (Blackboard/Time/Quests/Player systems, `GetSingleton('inkMenuScenario')`).

**Biggest risk.** Scripted-function hooking - the whole path hinges on the macOS dispatch honouring the forced `isNative=1` flag and on identifying the right `CScriptStack` layout; get either wrong and the RTTI table corrupts silently. Validate SDK size/offset asserts against the live binary before enabling any swap.

### Phase 3 - Override (call-original) + full converter + name/refcount correctness

**Build.** `Override` with the `wrapped`/`next` continuation and **write-back** of the return value and out-params (`ToRED` into `apResult`/`apOutArgs`) - the JS -> RED hard direction. `WrapNextOverride` chain. Complete the `Converter`: `DynArray<T>` <-> table, `CString`, `Variant`, `ScriptRef`, nested handle returns, struct-by-value by field. Replace the fake refcount with real Handle lifetime ops + GC-safety teardown. Confirm `CName.add`/`NameToString` round-trip through `CNamePool`.

**Unlocks.** Tier 2 interaction UI: the 9 `Override`s that arbitrate the choice hub against the game (`InteractionUIBase::OnDialogsData/OnDialogsSelectIndex`, `dialogWidgetGameController::OnDialogsActivateHub`, `GameTimeUtils::CanPlayerTimeSkip;PlayerPuppet`, elevator UI, loot-lock, item-drop teleport) - without working `Override` continuations the interaction UI cannot render or select. Plus per-frame blackboard writes and array-typed reads.

**Biggest risk.** `Override` write-back correctness and refcount lifetime - a wrong `ToRED` into a return slot or a mismanaged Handle count crashes on the game thread.

### Phase 4 - workspot / teleport / spawn specifics (the point of the mod)

**Build.** Exercise and harden the exotic engine calls behind the interactions: `WorkspotSystem::PlayInDevice/SendForwardSignal/SendJumpCommandEnt`, `TeleportationFacility::Teleport`, `GetFPPCameraComponent():SetLocalOrientation/SetLocalPosition/ResetPitch`, script-side game-object instantiation + dispatch (`EquipRequest`/`UnequipRequest` via `EquipmentSystem:QueueRequest`, `SoundPlayEvent`/`SoundStopEvent` via `QueueEvent`), `MappinSystem:RegisterMappin`, `QuestsSystem:GetFactStr/SetFactStr`, and the menu-scenario overrides (wardrobe/appearance via `UISystem:QueueEvent(inkMenuInstance_SpawnEvent)`). Ensure the redscript-provided `exEntitySpawner.Spawn/Despawn` global is compiled and registered (this is **not** a CET built-in - it is a redscript dependency; every furniture workspot spawns a device `.ent` through it), and that `sampleStyleManagerGameController.new()` + `RegisterToCallback` (instantiating a real inkGameController from script to receive widget callbacks) works.

**Unlocks.** Tier 2 fully: sit/couch/bench/rail/coffee/drink/shower/sleep workspots, elevator, fast-travel terminal, appearance device - i.e. the mod actually doing its job.

**Biggest risk.** `WorkspotSystem::PlayInDevice` (drives an animation graph + camera hand-off + player state) and the `exEntitySpawner` redscript dependency; either can no-op or crash on the port. These sit on top of everything above and are where engine work beyond the existing primitives is most likely still required.

---

## 5. Concrete first step this week - prove the spine end to end

**Goal:** smallest possible end-to-end that proves VM + loader + event + reflection + logging, with no hooks and no per-frame tick. Success = a trivial mod's `onInit` fires in-world, calls one `Game.*` function, and logs the result.

**Deliverable:** a minimal RED4ext C++ plugin `cet-mac.dylib` that:

1. **Loads like the existing plugins** (same injection path; `RED4EXT_CALL Main`/`Load`), linked against LuaJIT (GC64, built for arm64) + sol2 (header-only). Open `base, string, table, math, bit` and call `jit.off()`.
2. **On the `PlayerSystem::OnPlayerMainObjectSpawned` gum hook** (resolve the address in Ghidra from CET hash `2050111212`; until then, reuse the existing `InitScripts`/spawn detection already in `red4ext_hooks.js` as the trigger), once only: create a `sol::state`, define a minimal `registerForEvent(name, fn)` that stores `onInit`, then `state.script_file("mods/spine/init.lua", env)`, then call the stored `onInit`.
3. **`mods/spine/init.lua`:**

   ```lua
   registerForEvent("onInit", function()
       local ps = Game.GetPlayerSystem()          -- one read-only Game.* call
       local player = ps:GetLocalPlayerControlledGameObject()
       spdlog_info("spine onInit: player = " .. tostring(player))
   end)
   ```

4. **Bind just enough reflection** for that one call: `Game` as a usertype whose `__index` resolves a global RTTI func by short name via the **already-proven** `resolveFunc` + universal-executor (`0x2173120`) path, `GetPlayerSystem` returning a `StrongReference`-like wrapper whose `__index` resolves `GetLocalPlayerControlledGameObject` on the runtime class and calls it with the instance as context (the returned-object dispatch loop is already demonstrated in the JS). Bind one log function (`spdlog_info`) to the plugin's logger.

**Why this is the right first cut.** It touches every spine component - embed the VM, load and run a mod file, fire one event at the correct lifecycle moment, resolve and call one real engine function through the proven executor, marshal one Handle return, and log - while deliberately excluding the two hardest pieces (`Observe`/`Override` hooks and the per-frame `onUpdate` tick). If this runs, Phase 1 is de-risked: everything else in Phase 1 is more of the same reflection/type binding. The only genuinely new artifact is the LuaJIT+sol2 build inside a RED4ext plugin; prove that here, on a five-line mod, before pointing it at mansion's 20 modules.

**Parallel task (unblocks Phases 1-2):** resolve the seven Ghidra unknowns in §3.4, starting with `PlayerSystem::OnPlayerMainObjectSpawned` (needed for this step's clean trigger) and `red::GameAppRunningState::OnTick` (needed for a real `onUpdate`).

---

### Key files

- Mod: `/Users/ysr/Downloads/mods/mansion/bin/x64/plugins/cyber_engine_tweaks/mods/mansionDLC/`
- Current macOS runtime (primitives, offsets, executor): `/Users/ysr/cet-mac/runtime/red4ext_hooks.js`
- Canonical arm64 executor reference (proven, in-game): `/Users/ysr/cybermodman/vendor/cp2077-codeware-macos/lib/Red/TypeInfo/Invocation.hpp`
- RED4ext SDK struct layouts: `/Users/ysr/cybermodman/vendor/cp2077-tweak-xl-macos/vendor/RED4ext.SDK/include/RED4ext/` (`Scripting/Functions.hpp`, `Scripting/Stack.hpp`, `RTTITypes.hpp`, `DynArray.hpp`, `Handle.hpp`, `Memory/SharedPtr.hpp`, `CString.hpp`, `CName.hpp`)
- CET Windows source (framework to port): `src/scripting/{Scripting,FunctionOverride,LuaSandbox,ScriptStore,ScriptContext}.*`, `src/reverse/{RTTIHelper,Type,Converter,LuaRED,BasicTypes,RTTIMapper,StrongReference,SingletonReference,Addresses}.*`, `src/d3d12/*` and `src/overlay/*` (skip for mansion)
- Ghidra project (address resolution): `/Users/ysr/cp2077/_ghidra`
- Overlay/injection facts (entitlements, W^X, re-signing): `/Users/ysr/cet-mac/TECHNICAL.md`
