// cet-lua: Observe / ObserveBefore / ObserveAfter / Override.
//
// Mechanism (ported from CET FunctionOverride.cpp; macOS ARM64 specifics noted):
//   * Register (init.lua time): record each hook (class, func, kind, callback).
//   * Install (Running-state enter): resolve each target CClassFunction in RTTI, group hooks into a per-target
//     Chain, and - if arming is requested - install by a three-way descriptor byte-swap:
//       1. Create a trampoline CClassFunction (SDK Create() calloc's 0xC0 + engine ctor 0x2173760) whose native
//          handler is a 36-byte arm64 stub (arm64stub.hpp) that sets x4 = the real function and tail-calls
//          HandleOverridenFunction. CET uses an x86-64 Xbyak stub here; arm64 passes arg 5 in x4, so it's a
//          simpler tail call.
//       2. CopyFunctionDescription(trampoline <- real) so the trampoline forwards with the real signature.
//       3. Swap the full 0xC0 of real <-> trampoline. Now calling `real` runs the stub -> our dispatch, and the
//          trampoline holds the pristine original for forwarding. For native instance methods both sides are
//          CClassFunction (0xC0), so the swap is size-safe WITHOUT CET's over-alloc CreateFunction detour.
//   * Dispatch (HandleOverridenFunction): pop args off the CStackFrame via the SDK's header-only
//     OpcodeHandlers::Run (table already in the macOS reloc map), marshal to Lua (game::ToLua), run
//     Before -> Override(or forward original) -> After, forward via the pinned universal executor 0x2173120.
//
// SAFETY: arming is gated on gates::ArmHooksRequested() (env CETLUA_ARM_HOOKS / file /tmp/cetlua_arm_hooks),
// default OFF. The swap targets are MED-confidence and a wrong swap corrupts RTTI silently; we cannot launch
// the game to validate, so by default we RECORD hooks and do not swap. See docs/CET-LUA-STATUS.md.
#pragma once
#include <sol/sol.hpp>
#include <RED4ext/RED4ext.hpp>
#include <RED4ext/Scripting/OpcodeHandlers.hpp>
#include <RED4ext/Scripting/Stack.hpp>
#include <cstring>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>
#include "addrs.hpp"
#include "reflect.hpp"
#include "game.hpp"
#include "arm64stub.hpp"
#include "addrs_gates.hpp"
#include "log.hpp"

// main.cpp owns the VM; the dispatch borrows it.
namespace cetlua { extern sol::state g_lua; }

namespace cetlua::observe
{
enum class Kind { Before, After, Override };

// ---- recorded hook (Phase 1: recorded so init.lua completes) ----------------------------------------
struct Record
{
    std::string className;
    std::string funcName; // shortName, or "Name;ParamTypes" overload signature
    Kind kind;
    sol::protected_function cb;
};
inline std::vector<Record>& Records() { static std::vector<Record> v; return v; }

// ---- per-target call chain (Phase 2+: what dispatch runs) -------------------------------------------
struct Chain
{
    RED4ext::CClassFunction* trampoline = nullptr; // holds pristine original after swap; forward through this
    std::vector<sol::protected_function> before, after, overrides;
    bool empty() const { return before.empty() && after.empty() && overrides.empty(); }
};
// keyed by the REAL function address (stable across the swap)
inline std::unordered_map<RED4ext::CBaseFunction*, Chain>& Chains()
{
    static std::unordered_map<RED4ext::CBaseFunction*, Chain> m;
    return m;
}

// ---- Lua API (records only; never blocks init.lua) --------------------------------------------------
inline void Register(sol::state& lua)
{
    lua["Observe"] = [](std::string cls, std::string fn, sol::protected_function cb)
    { Records().push_back({std::move(cls), std::move(fn), Kind::Before, std::move(cb)}); };
    lua["ObserveBefore"] = lua["Observe"];
    lua["ObserveAfter"] = [](std::string cls, std::string fn, sol::protected_function cb)
    { Records().push_back({std::move(cls), std::move(fn), Kind::After, std::move(cb)}); };
    lua["Override"] = [](std::string cls, std::string fn, sol::protected_function cb)
    { Records().push_back({std::move(cls), std::move(fn), Kind::Override, std::move(cb)}); };
    lua["NewObject"] = [](sol::this_state ts, std::string /*cls*/)
    { return sol::object(sol::state_view(ts), sol::lua_nil); }; // TODO: MakeHandle<T> via Codeware path
}

// ---- descriptor helpers (portable; match CET) -------------------------------------------------------
inline size_t GetFunctionSize(RED4ext::CBaseFunction* f)
{
    if (f->flags.isStatic)
        return f->flags.isNative ? sizeof(RED4ext::CClassStaticFunction) : sizeof(RED4ext::CGlobalFunction);
    return sizeof(RED4ext::CClassFunction);
}

// Copy the descriptor fields (NOT the handler/vtable) real -> dst, forcing native so the engine uses dst's
// handler directly. Mirrors CET FunctionOverride::CopyFunctionDescription against the macOS SDK field set.
inline void CopyFunctionDescription(RED4ext::CBaseFunction* dst, RED4ext::CBaseFunction* real, bool forceNative)
{
    dst->fullName = real->fullName;
    dst->shortName = real->shortName;
    dst->returnType = real->returnType;

    dst->params.Clear();
    for (auto* p : real->params) dst->params.PushBack(p);
    dst->localVars.Clear();
    for (auto* p : real->localVars) dst->localVars.PushBack(p);

    dst->unk20 = real->unk20;
    dst->unk48 = real->unk48;
    dst->unkAC = real->unkAC;

    dst->flags = real->flags;
    dst->flags.isNative = forceNative;

    std::memcpy(&dst->bytecode, &real->bytecode, sizeof(real->bytecode));
}

// Three-way swap of the full descriptor (data, not code). Size-safe when both are the same subtype.
inline void SwapDescriptors(RED4ext::CBaseFunction* real, RED4ext::CBaseFunction* tramp)
{
    const size_t n = GetFunctionSize(real);
    std::vector<char> tmp(n);
    std::memcpy(tmp.data(), real, n);
    std::memcpy(real, tramp, n);
    std::memcpy(tramp, tmp.data(), n);
}

// ---- dispatch: the single handler every swapped native tail-calls (x4 = real function) --------------
// Faithful to CET FunctionOverride::HandleOverridenFunction, simplified for the native-method case mansion
// uses. Defensive: any failure forwards the original so a bad Lua hook can't brick the method.
inline void HandleOverridenFunction(RED4ext::IScriptable* aContext, RED4ext::CStackFrame* aFrame, void* aOut,
                                    void* aRetType, RED4ext::CBaseFunction* aRealFunc)
{
    auto& chains = Chains();
    auto it = chains.find(aRealFunc);

    // forward helper: restore frame cursor and run the pristine original through the pinned executor.
    auto forward = [&](char* code, uint8_t param) {
        aFrame->code = code;
        aFrame->currentParam = param;
        static reflect::CallFn_t exec = addrs::At<reflect::CallFn_t>(addrs::CBaseFunction_InternalExecute);
        RED4ext::CClassFunction* tramp = (it != chains.end()) ? it->second.trampoline : nullptr;
        exec(tramp ? (RED4ext::CBaseFunction*)tramp : aRealFunc, aContext, aFrame, aOut, aRetType);
    };

    char* savedCode = aFrame->code;
    const uint8_t savedParam = aFrame->currentParam;

    if (it == chains.end() || it->second.empty())
    {
        // No callbacks: just forward. (Shouldn't happen once installed, but stay safe.)
        forward(savedCode, savedParam);
        return;
    }

    // The single LuaJIT VM is main-thread-only; native methods can fire on worker threads. We have no locked
    // state (CET does), so off the main thread we forward the original WITHOUT running Lua callbacks rather than
    // risk a cross-thread VM crash. Most gameplay/UI Observe targets run on the main thread.
    if (!pthread_main_np())
    {
        forward(savedCode, savedParam);
        return;
    }

    Chain& chain = it->second;
    sol::state_view lua(cetlua::g_lua.lua_state());

    // Marshal args: pop each param off the frame via the opcode VM, convert to Lua.
    std::vector<sol::object> args;
    auto* fn = aRealFunc;
    if (!fn->flags.isStatic)
    {
        RED4ext::IScriptable* self = aContext ? aContext : aFrame->context;
        args.push_back(self ? game::WrapInstance(lua, self, self->GetType())
                            : sol::make_object(lua, sol::lua_nil));
    }
    // temp storage for popped arg instances
    struct Held { RED4ext::CBaseRTTIType* t; void* v; };
    std::vector<Held> held;
    for (auto* p : fn->params)
    {
        auto* pt = p->type;
        size_t sz = pt->GetSize() ? pt->GetSize() : 8;
        size_t al = pt->GetAlignment() ? pt->GetAlignment() : 8;
        void* inst = nullptr;
        if (posix_memalign(&inst, al < sizeof(void*) ? sizeof(void*) : al, (sz + al - 1) & ~(al - 1)) != 0)
            inst = std::calloc(1, sz);
        std::memset(inst, 0, sz);
        pt->Construct(inst);

        aFrame->currentParam++;
        aFrame->data = nullptr;
        aFrame->dataType = nullptr;
        const uint8_t opcode = *aFrame->code++;
        RED4ext::OpcodeHandlers::Run(opcode, aFrame->context, aFrame, inst, nullptr);

        args.push_back(game::ToLua(lua, pt, inst));
        held.push_back({pt, inst});
    }
    aFrame->code++; // skip ParamEnd

    // Run Before callbacks.
    for (auto& cb : chain.before)
    {
        sol::protected_function_result r = cb(sol::as_args(args));
        if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] Observe callback error: %s", e.what()); }
    }

    bool handled = false;
    if (!chain.overrides.empty())
    {
        // Absolute override: last override wins; its return (if any) becomes the engine result.
        for (auto& cb : chain.overrides)
        {
            sol::protected_function_result r = cb(sol::as_args(args));
            if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] Override callback error: %s", e.what()); continue; }
            handled = true;
            if (aOut && fn->returnType && fn->returnType->type && r.return_count() > 0)
            {
                game::Scratch s;
                void* red = game::ToRED(lua, r[0].get<sol::object>(), fn->returnType->type, s);
                if (red) std::memcpy(aOut, red, fn->returnType->type->GetSize());
            }
        }
    }

    if (!handled)
        forward(savedCode, savedParam); // run the pristine original

    // Run After callbacks.
    for (auto& cb : chain.after)
    {
        sol::protected_function_result r = cb(sol::as_args(args));
        if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] ObserveAfter callback error: %s", e.what()); }
    }

    // Release popped arg instances.
    for (auto& h : held) { h.t->Destruct(h.v); std::free(h.v); }
}

// ---- resolve a recorded hook's target CClassFunction ------------------------------------------------
inline RED4ext::CClassFunction* Resolve(const Record& r)
{
    auto* cls = reflect::GetClass(RED4ext::CName(r.className.c_str()));
    if (!cls) return nullptr;
    // shortName lookup first; then FNV of the (possibly overloaded) full name.
    auto* f = cls->GetFunction(RED4ext::CName(r.funcName.c_str()));
    if (f) return f;
    // walk funcs by full name (handles "Name;Params" overloads)
    RED4ext::CName want(r.funcName.c_str());
    for (auto* cf : cls->funcs)
        if (cf && (cf->fullName == want || cf->shortName == want)) return cf;
    return nullptr;
}

// ---- build + install a trampoline for one target (arming) -------------------------------------------
inline RED4ext::CClassFunction* MakeTrampoline(RED4ext::CClassFunction* real)
{
    // arm64 stub: x4 = real, tail-call HandleOverridenFunction.
    void* stub = arm64::MakeTrampoline(reinterpret_cast<uintptr_t>(real),
                                       reinterpret_cast<uintptr_t>(&HandleOverridenFunction));
    if (!stub) { LOGF("[cet-lua] MakeTrampoline: no executable memory (arm64 stub) - cannot arm"); return nullptr; }

    using NativeFn = void (*)(RED4ext::IScriptable*, RED4ext::CStackFrame*, void*, int64_t);
    auto payload = reinterpret_cast<NativeFn>(stub);

    // Name is throwaway: CopyFunctionDescription overwrites fullName/shortName from `real`, and the trampoline
    // is never added to the class. Use a literal to avoid depending on CName::ToString.
    RED4ext::CClassFunction* tramp =
        RED4ext::CClassFunction::Create(real->parent, "cetlua_tramp", "cetlua_tramp", payload, real->flags);
    if (!tramp) { LOGF("[cet-lua] MakeTrampoline: CClassFunction::Create returned null"); return nullptr; }
    tramp->parent = real->parent;
    CopyFunctionDescription(tramp, real, /*forceNative*/ true);
    return tramp;
}

// ---- install recorded hooks (called once at Running-state enter) ------------------------------------
inline void InstallPending(const RED4ext::Sdk* /*aSdk*/, RED4ext::PluginHandle /*aHandle*/)
{
    // Group records into chains by resolved target, so multiple hooks on one method share a trampoline.
    int resolved = 0;
    std::unordered_map<RED4ext::CBaseFunction*, std::vector<const Record*>> byTarget;
    for (const auto& r : Records())
    {
        auto* t = Resolve(r);
        if (!t) { LOGF("[cet-lua] Observe unresolved: %s::%s", r.className.c_str(), r.funcName.c_str()); continue; }
        byTarget[t].push_back(&r);
        ++resolved;
    }
    LOGF("[cet-lua] Observe/Override: %zu recorded, %d resolved in RTTI, %zu distinct methods",
         Records().size(), resolved, byTarget.size());

    const bool arm = gates::ArmHooksRequested();
    if (!arm)
    {
        LOGF("[cet-lua] Observe/Override NOT armed (default-safe). To arm for a validation session: "
             "set CETLUA_ARM_HOOKS=1 or `touch /tmp/cetlua_arm_hooks`, then relaunch. "
             "Addresses are present (executor 0x2173120, OpcodeHandlers 0x908b798, ctor 0x2173760) but the "
             "swap is MED-confidence and unvalidated in-world.");
        return;
    }

    int armed = 0;
    for (auto& [target, recs] : byTarget)
    {
        auto* real = static_cast<RED4ext::CClassFunction*>(target);
        Chain chain;
        chain.trampoline = MakeTrampoline(real);
        if (!chain.trampoline) continue;
        for (const Record* r : recs)
        {
            if (r->kind == Kind::Before) chain.before.push_back(r->cb);
            else if (r->kind == Kind::After) chain.after.push_back(r->cb);
            else chain.overrides.push_back(r->cb);
        }
        Chains()[real] = std::move(chain);
        SwapDescriptors(real, Chains()[real].trampoline); // arm: real now dispatches to our stub
        ++armed;
    }
    LOGF("[cet-lua] Observe/Override ARMED %d method(s) via descriptor swap (CETLUA_ARM_HOOKS)", armed);
}
} // namespace cetlua::observe
