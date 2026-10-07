// cet-lua - a CET-compatible Lua modding host for the macOS ARM64 build of Cyberpunk 2077.
// Loads like any RED4ext plugin. Embeds LuaJIT (interpreter mode) + sol2 and re-implements the CET Lua
// framework (registerForEvent / Observe / Override / Game.* reflection) on the proven macOS engine
// primitives (universal executor 0x2173120, RTTI, CNamePool). Drivers use the RED4ext game-state + hooking
// SDK interfaces (no Ghidra addresses needed for onInit/onUpdate). See docs/CET-LUA-MODS-MACOS-PORT-PLAN.md.
// This TU is the ONLY one that pulls in the RED4ext SDK impl.
#include <RED4ext/RED4ext.hpp>
#include <sol/sol.hpp>
extern "C" {
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}
#include <chrono>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <string>
#include <vector>

#include "addrs.hpp"
#include "log.hpp"
#include "reflect.hpp"
#include "luatypes.hpp"
#include "game.hpp"
#include "guard.hpp"
#include "events.hpp"
#include "sandbox.hpp"
#include "observe.hpp"

namespace cetlua
{
sol::state g_lua;
bool g_vmUp = false;
bool g_apiUp = false;
bool g_modsLoaded = false;
RED4ext::PluginHandle g_handle = nullptr;
const RED4ext::Sdk* g_sdk = nullptr;
uint32_t g_tickCount = 0;         // Running-tick counter (driver)
uint32_t g_fwPublishedAtTick = 0; // tick at which the CGameFramework was published (post-ctor)

// ---- game dir discovery (<game>/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077 -> up 4) ---------------
std::string GameDir()
{
    char buf[4096];
    uint32_t sz = sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0)
        return "";
    std::string p(buf);
    for (int i = 0; i < 4; ++i)
    {
        auto slash = p.find_last_of('/');
        if (slash == std::string::npos) break;
        p = p.substr(0, slash);
    }
    return p;
}

// ---- Lua stdout + spdlog -> our log ------------------------------------------------------------------
int LuaPrint(lua_State* L)
{
    int n = lua_gettop(L);
    std::string out;
    for (int i = 1; i <= n; ++i)
    {
        size_t len = 0;
        const char* s = luaL_tolstring(L, i, &len);
        if (i > 1) out += '\t';
        out.append(s ? s : "", len);
        lua_pop(L, 1);
    }
    LOGF("[mod] %s", out.c_str());
    return 0;
}

void SetupSpdlog(sol::state& lua)
{
    sol::table sp = lua.create_named_table("spdlog");
    auto lg = [](const char* lvl) {
        return [lvl](std::string m) { LOGF("[mod:%s] %s", lvl, m.c_str()); };
    };
    sp["info"] = lg("info");
    sp["warning"] = lg("warn");
    sp["error"] = lg("error");
    sp["debug"] = lg("debug");
    sp["trace"] = lg("trace");
}

// ---- VM + CET API ------------------------------------------------------------------------------------
void BootVM()
{
    if (g_vmUp) return;
    lua_State* L = g_lua.lua_state();
    luaL_openlibs(L);
    g_lua.safe_script("if jit and jit.off then jit.off() end", sol::script_pass_on_error);
    sol::protected_function_result r =
        g_lua.safe_script("return tostring(13312760010544421172ULL)", sol::script_pass_on_error);
    LOGF("[cet-lua] VM up (LuaJIT interpreter); ULL64=%s", r.valid() ? r.get<std::string>().c_str() : "FAIL");
    g_vmUp = true;
}

void SetupAPI()
{
    if (g_apiUp) return;
    g_lua.set_function("print", &LuaPrint);
    SetupSpdlog(g_lua);
    types::RegisterValueTypes(g_lua);
    game::RegisterGame(g_lua);
    events::Register(g_lua);
    observe::Register(g_lua);

    // ArchiveXL integration globals mansion checks.
    g_lua["ModArchiveExists"] = [](std::string /*name*/) { return true; }; // TODO: real check via ArchiveXL
    g_lua["ArchiveXL"] = true;
    g_lua["GetLocalizedText"] = [](std::string k) { return k; }; // TODO: LocKey resolve
    g_lua["GetVersion"] = []() { return std::string("cet-lua 0.1"); };
    g_apiUp = true;
}

// ---- drivers: mods load + onInit at Running-enter; onUpdate per frame ---------------------------------
std::chrono::steady_clock::time_point g_last;

// Load mods + fire onInit exactly once, from whichever driver fires first. RED4ext may register our Running
// state AFTER the engine already entered Running (so OnEnter is missed and never re-fires) - but OnUpdate ticks
// every frame during Running, so the first OnUpdate tick is a reliable fallback trigger.
void EnsureLoaded(RED4ext::CGameApplication* aApp, const char* via)
{
    if (g_modsLoaded) return;
    g_modsLoaded = true;
    game::SetGIFromApp(aApp);
    std::string gd = GameDir();
    LOGF("[cet-lua] first-load via %s; gameDir=%s -> loading mods + onInit", via, gd.c_str());
    sandbox::LoadAll(g_lua, gd);
    observe::InstallPending(g_sdk, g_handle); // Phase 2+: install recorded Observe/Override hooks
    g_last = std::chrono::steady_clock::now();
    events::Fire("onInit");
}

bool RunningOnEnter(RED4ext::CGameApplication* aApp)
{
    LOGF("[cet-lua] Running OnEnter fired");
    game::SetGIFromApp(aApp);
    EnsureLoaded(aApp, "OnEnter");
    return true;
}

bool RunningOnUpdate(RED4ext::CGameApplication* aApp)
{
    static bool firstTick = true;
    if (firstTick) { firstTick = false; LOGF("[cet-lua] Running OnUpdate first tick"); }
    game::SetGIFromApp(aApp);
    EnsureLoaded(aApp, "OnUpdate tick"); // fallback if OnEnter was missed
    if (!g_modsLoaded) return false;
    auto now = std::chrono::steady_clock::now();
    double dt = std::chrono::duration<double>(now - g_last).count();
    g_last = now;
    events::FireUpdate(dt);
    return false; // keep ticking
}

bool RunningOnExit(RED4ext::CGameApplication*)
{
    events::Fire("onShutdown");
    return true;
}

// ---- Fallback driver (macOS): RED4ext's game-state dispatch is DEAD on this build. The engine
// CGameApplication AddState hook can't resolve its address (0/8 core state hooks attach per red4ext.log), so
// gameStates->Add(Running)=ok is a FALSE POSITIVE - nothing ever calls our OnEnter/OnUpdate. Instead we drive
// onInit/onUpdate ourselves by hooking the engine's Running-state per-frame tick (RVA 0x3d8d7f8) through the
// PROVEN manual-inline hook (aSdk->hooking->Attach, the same path that installs ArchiveXL/Codeware hooks). The
// tick is argless, operates on the running-state singleton, returns a uint. First fire loads mods + onInit;
// every fire pumps onUpdate. GameInstance may still be null here (engine not fully up / global not yet wired);
// Game.* calls guard on that and no-op until it's available.
constexpr std::uintptr_t kRunningTickRVA = 0x3d99348; // per-frame Running worker (SIMPLE prologue,
                                                       // manual-inline hookable). Tail-called by the
                                                       // outer tick 0x3d8d7f8 (whose prologue has a
                                                       // bl at +8 -> non-simple -> gum no-op).
using TickFn = uint64_t (*)(void*, void*, uint64_t);
TickFn g_origTick = nullptr;
bool g_inTick = false;

// The worker runs every frame on the MAIN THREAD (the outer tick gates on SIsMainThread). x0 is the engine/
// running-state singleton; x1/x2 are its own args - captured here and forwarded verbatim to the original.
uint64_t RunningTickDetour(void* a0, void* a1, uint64_t a2)
{
    if (!g_inTick) // guard against any reentrancy from within our pump
    {
        g_inTick = true;
        try
        {
            if (!g_modsLoaded)
            {
                // CET fires onInit once the game instance is ready. On macOS the CGameFramework (and its
                // GameInstance) is constructed late (session start), AFTER the Running tick begins - so wait
                // for GI() to be live before loading mods, or every Game.* call in init.lua sees nil.
                // CET's onInit effectively fires once the main menu is up, where a (detached) player puppet
                // already exists - GameUI-style libraries rely on Game.GetPlayer() being non-nil there. So wait
                // for BOTH a live GameInstance and a local player object, using the proven reflection path.
                bool ready = false;
                ++g_tickCount;
                // settle window: don't touch the fresh GameInstance for ~1s of ticks after publication
                const bool settled = game::Framework() && (g_tickCount - g_fwPublishedAtTick) > 60;
                if (settled && game::GI())
                {
                    // Precompiled once (compiling a chunk every frame is wasteful); returns true when a local
                    // player object exists.
                    static sol::protected_function playerCheck = [] {
                        sol::load_result lr = g_lua.load(
                            "local ps = Game.GetPlayerSystem(); if not ps then return false end; "
                            "return ps:GetLocalPlayerControlledGameObject() ~= nil");
                        return lr.valid() ? sol::protected_function(lr) : sol::protected_function();
                    }();
                    if (playerCheck.valid())
                    {
                        sol::protected_function_result r = playerCheck();
                        ready = r.valid() && r.get_type() == sol::type::boolean && r.get<bool>();
                    }
                }
                if (!ready)
                {
                    static bool waited = false;
                    static uint32_t waitTicks = 0;
                    if (!waited) { waited = true; LOGF("[cet-lua] tick: waiting for GameInstance + player before onInit (CET timing)"); }
                    // Self-diagnosing wait: every ~5s log what the gate sees, so a "stuck at splash" report tells
                    // us whether GI is null (plumbing) or the player just isn't there yet (intro awaiting a key).
                    if (++waitTicks % 300 == 0)
                        LOGF("[cet-lua] tick: still waiting (tick %u): GI=%p framework=%p player=%s", waitTicks,
                             (void*)game::GI(), game::Framework(), game::GI() ? "absent" : "n/a");
                }
                else
                {
                    LOGF("[cet-lua] GameInstance (%p) + player live -> loading mods + onInit", (void*)game::GI());
                    EnsureLoaded(nullptr, "RunningTick");
                }
            }
            else
            {
                auto now = std::chrono::steady_clock::now();
                double dt = std::chrono::duration<double>(now - g_last).count();
                g_last = now;
                events::FireUpdate(dt);
            }
        }
        catch (const std::exception& e) { LOGF("[cet-lua] RunningTickDetour EXCEPTION: %s", e.what()); }
        catch (...) { LOGF("[cet-lua] RunningTickDetour UNKNOWN EXCEPTION"); }
        g_inTick = false;
    }
    return g_origTick ? g_origTick(a0, a1, a2) : 0;
}

// ---- CGameFramework capture (macOS): every static route to the GameInstance failed live (the app object,
// the "engine" global 0x8d5d830 = a service container, SDK offsets all disproved), so we capture the framework
// at CONSTRUCTION instead. Hook the CGameFramework ctor (RVA 0x3f0d2ac; simple prologue; single call site from
// the factory that Allocate(0x28)s it). x0 = this = the framework; forward all 5 ctor args verbatim.
constexpr std::uintptr_t kFrameworkCtorRVA = 0x3f0d2ac;
using FwCtorFn = void* (*)(void*, void*, void*, void*, void*);
FwCtorFn g_origFwCtor = nullptr;

// The framework is constructed on a JOB thread. Publish it only AFTER the original ctor returns, so the
// main-thread tick can never observe a half-built framework/GameInstance (that race hung GetPlayerSystem at
// the splash, 2026-09-22). fwReadyTick then gives the engine a short settle window before we use it.
void* FwCtorDetour(void* a0, void* a1, void* a2, void* a3, void* a4)
{
    void* r = g_origFwCtor ? g_origFwCtor(a0, a1, a2, a3, a4) : a0;
    game::Framework() = a0;               // aligned 8-byte store: atomic on arm64
    g_fwPublishedAtTick = g_tickCount;
    LOGF("[cet-lua] CGameFramework ctor completed: framework=%p (published at tick %u)", a0, g_fwPublishedAtTick);
    return r;
}

RED4ext::GameState g_runningState{&RunningOnEnter, &RunningOnUpdate, &RunningOnExit};
} // namespace cetlua

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::PluginHandle aHandle, RED4ext::EMainReason aReason,
                                        const RED4ext::Sdk* aSdk)
{
    using namespace cetlua;
    try
    {
        switch (aReason)
        {
        case RED4ext::EMainReason::Load:
        {
            LogInit();
            guard::Install();
            g_handle = aHandle;
            g_sdk = aSdk;
            LOGF("[cet-lua] Load: imageBase=%p executor=%p", (void*)addrs::ImageBase(),
                 (void*)(addrs::ImageBase() + addrs::CBaseFunction_InternalExecute));
            BootVM();
            SetupAPI();
            // Drive onInit/onUpdate from the Running game state (RTTI ready + player in world).
            if (aSdk && aSdk->gameStates)
            {
                bool ok = aSdk->gameStates->Add(aHandle, RED4ext::EGameStateType::Running, &g_runningState);
                LOGF("[cet-lua] gameStates->Add(Running) = %s", ok ? "ok" : "FAILED");
            }
            else
            {
                LOGF("[cet-lua] WARNING: no gameStates SDK interface");
            }
            // macOS: the gameStates dispatch never fires (see RunningTickDetour). Install our own driver by
            // hooking the engine Running-state tick via the manual-inline hook keystone.
            struct stat _nt;
            const bool tickDisabled = (::stat("/tmp/cetlua_no_tick", &_nt) == 0);
            if (tickDisabled)
            {
                LOGF("[cet-lua] RunningTick driver DISABLED (/tmp/cetlua_no_tick present) - onInit/onUpdate off");
            }
            else if (aSdk && aSdk->hooking)
            {
                void* target = reinterpret_cast<void*>(addrs::ImageBase() + kRunningTickRVA);
                bool ok = aSdk->hooking->Attach(aHandle, target, reinterpret_cast<void*>(&RunningTickDetour),
                                                reinterpret_cast<void**>(&g_origTick));
                LOGF("[cet-lua] hooking->Attach(RunningTick %p) = %s", target, ok ? "ok" : "FAILED");
                // Capture the CGameFramework at construction -> GameInstance (see FwCtorDetour).
                void* fwTarget = reinterpret_cast<void*>(addrs::ImageBase() + kFrameworkCtorRVA);
                bool fwOk = aSdk->hooking->Attach(aHandle, fwTarget, reinterpret_cast<void*>(&FwCtorDetour),
                                                  reinterpret_cast<void**>(&g_origFwCtor));
                LOGF("[cet-lua] hooking->Attach(CGameFramework ctor %p) = %s", fwTarget, fwOk ? "ok" : "FAILED");
            }
            else
            {
                LOGF("[cet-lua] ERROR: no hooking SDK interface - cannot install fallback driver");
            }
            break;
        }
        case RED4ext::EMainReason::Unload:
            LOGF("[cet-lua] Unload");
            break;
        }
        return true;
    }
    catch (const std::exception& e) { LOGF("[cet-lua] Main EXCEPTION: %s", e.what()); return false; }
    catch (...) { LOGF("[cet-lua] Main UNKNOWN EXCEPTION"); return false; }
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::PluginInfo* aInfo)
{
    aInfo->name = L"cet-lua";
    aInfo->author = L"ysrdevs";
    aInfo->version = RED4EXT_SEMVER(0, 1, 0);
    aInfo->runtime = RED4EXT_RUNTIME_INDEPENDENT;
    aInfo->sdk = RED4EXT_SDK_LATEST;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_LATEST;
}
