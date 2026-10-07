// cet-lua: the Observe/Override "gate" RVAs, resolved by the Ghidra hunt (2026-09-01, agent af41d79770659bfcb),
// cross-referenced against CET's Windows Addresses.h. onInit/onUpdate do NOT depend on any of these (they run on
// the RED4ext game-state SDK). Only Phase 2-4 method hooking (Observe/ObserveAfter/Override) does.
//
// CONFIDENCE (from the hunt): a wrong address here corrupts RTTI *silently*. Arming therefore stays behind a
// runtime flag (ArmHooksRequested) that defaults OFF; the user enables it for one validation launch only after
// the Phase-1 spine mod is confirmed working in-world. See docs/CET-LUA-STATUS.md.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <sys/stat.h>

namespace cetlua::gates
{
// ---- resolved RVAs (Ghidra address - 0x100000000) ---------------------------------------------------
// [HIGH-MED] rtti::Function::InternalCall (CScript RunPureScript): 3-arg bool(CBaseFunction*,CScriptStack*,
// CStackFrame*); indexes the 0x908b798 handler table and dispatches handler(ctx,frame,ret,type). Needed only
// for Override of *scripted* (non-native) functions. Native-method Observe does not use it.
constexpr std::uintptr_t rtti_Function_InternalCall = 0x2172f90;

// [MED] CClass::CreateFunction: allocates PoolStorageProxy<PoolRTTIFunction>(0xC0) + CBaseFunction ctor
// (0x2173760) + appends to the class func DynArray. On macOS the pool Alloc is INLINED (no standalone
// void*(pool,size) allocator, so CET's over-alloc CreateFunction detour has no single hook site). For
// native-method Observe we do NOT need it: CClassFunction::Create() calloc's the full 0xC0 and the descriptor
// swap is CClassFunction(0xC0) <-> CClassFunction(0xC0), i.e. already size-safe.
constexpr std::uintptr_t rtti_AllocateFunction      = 0x2198410;

// [HIGH] OpcodeHandlers dispatch TABLE (not a function; dispatch is inlined at ~2800 sites). CET's SDK
// OpcodeHandlers::Run/Get are header-only and index this table, and it is ALREADY in the macOS reloc table
// (SDK hash 0x39532858 -> 0x908b798). So the arg-pop path works via the SDK with no extra wiring here.
constexpr std::uintptr_t OpcodeHandlers_Table       = 0x908b798;

// ---- optional / not required for Observe (kept for completeness) -------------------------------------
constexpr std::uintptr_t GameAppRunningState_OnTick = 0x3d8d7f8; // [HIGH] we use the gameStates SDK instead
constexpr std::uintptr_t CScriptDataBinder_LoadOpcodes = 0x3d9a028; // [LOW] verify at runtime before use
constexpr std::uintptr_t TweakDB_LoadOptimized      = 0x2b75744; // [MED] real LoadOptimized (NOT 0x2b7be94)
constexpr std::uintptr_t PlayerSystem_OnPlayerMainObjectSpawned = 0; // UNRESOLVED (pure C++, no CName literal)

// ---- readiness ---------------------------------------------------------------------------------------
// Addresses for native-method Observe are all present. OpcodeHandlers is via the SDK; the executor is pinned in
// addrs.hpp (0x2173120, Ghidra-confirmed); CClassFunction::Create is SDK-ported. So the *address* prerequisites
// for native Observe/ObserveAfter are met. Scripted Override additionally uses rtti_Function_InternalCall.
inline bool ObserveAddressesReady() { return true; }
inline bool OverrideScriptedReady() { return rtti_Function_InternalCall != 0; }

// The irreversible arming gate. Addresses being present is necessary but NOT sufficient: a MED-confidence swap
// can corrupt RTTI silently, and we cannot launch the game to validate. So arming is opt-in per launch:
//   * env  CETLUA_ARM_HOOKS=1          (preferred; set for one validation session)
//   * file /tmp/cetlua_arm_hooks       (fallback for launch wrappers that can't set env)
// Default (neither present) = record hooks, do not swap. This keeps the platform safe by default.
inline bool ArmHooksRequested()
{
    if (const char* e = std::getenv("CETLUA_ARM_HOOKS"))
        if (e[0] && e[0] != '0') return true;
    struct stat st;
    return ::stat("/tmp/cetlua_arm_hooks", &st) == 0;
}
} // namespace cetlua::gates
