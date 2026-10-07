// cet-lua: RTTI reflection + invocation on macOS, built on the proven universal executor (0x2173120) and
// the CStackFrame ParamOp protocol (identical to Codeware's proven Invocation.hpp and to what CET emits).
// We call the executor by pinned RVA (addrs.hpp) rather than the SDK's address table, which is unreliable
// for the executor on this fork.
#pragma once
#include <RED4ext/RED4ext.hpp>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "addrs.hpp"

namespace cetlua::reflect
{
using RED4ext::CBaseFunction;
using RED4ext::CBaseRTTIType;
using RED4ext::CClass;
using RED4ext::CName;
using RED4ext::CRTTISystem;
using RED4ext::CStackFrame;
using RED4ext::IScriptable;
using RED4ext::ScriptInstance;

// ---- RTTI root -------------------------------------------------------------------------------------
inline CRTTISystem* RTTI()
{
    using Fn = CRTTISystem* (*)();
    static Fn fn = addrs::At<Fn>(addrs::CRTTISystem_Get);
    return fn();
}

inline CClass* GetClass(CName aName) { auto* r = RTTI(); return r ? r->GetClass(aName) : nullptr; }
inline CBaseRTTIType* GetType(CName aName) { auto* r = RTTI(); return r ? r->GetType(aName) : nullptr; }
inline RED4ext::CGlobalFunction* GetGlobalFunction(CName aName) { auto* r = RTTI(); return r ? r->GetFunction(aName) : nullptr; }

// Walk a class' funcs / staticFuncs (up the parent chain) for a member/static function by short or full name.
inline CBaseFunction* GetClassFunction(CClass* aType, CName aName, bool aMember = true, bool aStatic = true)
{
    while (aType)
    {
        if (aMember)
            for (auto* f : aType->funcs)
                if (f->shortName == aName || f->fullName == aName) return f;
        if (aStatic)
            for (auto* f : aType->staticFuncs)
                if (f->shortName == aName || f->fullName == aName) return f;
        aType = aType->parent;
    }
    return nullptr;
}

// ---- CName interning -------------------------------------------------------------------------------
inline uint64_t Fnv1a64(const char* s)
{
    uint64_t h = 0xCBF29CE484222325ULL;
    while (*s) { h ^= (uint8_t)*s++; h *= 0x100000001B3ULL; }
    return h;
}

// Intern a string so the engine can later resolve hash->string. Engine CNamePool::Add takes the C-string
// pointer; returns the CName (hash). We also return the fnv hash for the Lua-side CName value.
inline CName NameAdd(const char* aStr)
{
    using Fn = uint64_t (*)(const char*); // returns the interned hash in x0
    static Fn fn = addrs::At<Fn>(addrs::CNamePool_Add);
    uint64_t h = fn ? fn(aStr) : 0;
    if (!h) h = Fnv1a64(aStr);
    return CName{h};
}

// hash -> string (engine reverse lookup; CName passed BY VALUE in x0 on arm64).
inline const char* NameToString(CName aName)
{
    using Fn = const char* (*)(CName); // by value
    static Fn fn = addrs::At<Fn>(addrs::CNamePool_Get);
    const char* s = fn ? fn(aName) : nullptr;
    return s ? s : "";
}

// ---- Invocation: build the synthetic ParamOp frame + call the executor -----------------------------
// aArgs: one CStackType per param (type + value ptr). aResult: type+value for the return (or nulls).
using CallFn_t = bool (*)(CBaseFunction*, IScriptable* aCtx, CStackFrame* aFrame, void* aRet, void* aRetType);

inline bool CallWithArgs(CBaseFunction* aFunc, IScriptable* aCtx, RED4ext::CStackType* aArgs, uint32_t aArgc,
                         RED4ext::CStackType* aResult)
{
    if (!aFunc)
        return false;
    static CallFn_t exec = addrs::At<CallFn_t>(addrs::CBaseFunction_InternalExecute);
    if (!exec)
        return false;

    if (!aFunc->flags.isNative) return false;   // scripted functions need a real script stack
    if (aFunc->params.size > 28) return false;  // 1 + 17*28 + 1 fits MaxCode
    constexpr int NopOp = 0, ParamOp = 27, ParamEndOp = 38, MaxCode = 512;
    char code[MaxCode];
    CStackFrame frame(nullptr, code);

    for (uint32_t i = 0; i < aFunc->params.size; ++i)
    {
        auto* param = aFunc->params[i];
        bool have = (i < aArgc) && aArgs[i].value;
        if (!have)
        {
            if (!param->flags.isOptional) return false; // never emit ParamOp with a null value
            *frame.code = (char)NopOp; ++frame.code;
        }
        else
        {
            *frame.code = (char)ParamOp; ++frame.code;
            *reinterpret_cast<void**>(frame.code) = aArgs[i].type; frame.code += sizeof(void*);
            *reinterpret_cast<void**>(frame.code) = aArgs[i].value; frame.code += sizeof(void*);
        }
    }
    *frame.code = (char)ParamEndOp;
    frame.code = code; // rewind
    frame.func = aFunc;

    return exec(aFunc, aCtx, &frame,
                aResult ? aResult->value : nullptr,
                aResult ? aResult->type : nullptr);
}
} // namespace cetlua::reflect
