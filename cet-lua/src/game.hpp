// cet-lua: the `Game` reflection facade, Lua<->RED marshalling, returned-object (ClassRef) method dispatch,
// GetSingleton, and GameInstance resolution. Mirrors CET's src/reverse (RTTIHelper/Converter/Type) but lean,
// on our proven primitives. Read-heavy Phase-1 surface; the converter is structured to extend for Phase 3.
#pragma once
#include <sol/sol.hpp>
#include <RED4ext/RED4ext.hpp>
#include <RED4ext/GameEngine.hpp>
#include <RED4ext/Scripting/Natives/ScriptGameInstance.hpp>
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <mach/mach_vm.h>
#include <memory>
#include <vector>
#include <string>
#include "reflect.hpp"
#include "luatypes.hpp"
#include "log.hpp"
#include "guard.hpp"
#include <stdexcept>

namespace cetlua::game
{
using namespace cetlua::types;
using RED4ext::CBaseRTTIType;
using RED4ext::CClass;
using RED4ext::CName;
using RED4ext::ERTTIType;
using RED4ext::IScriptable;

// ---- GameInstance --------------------------------------------------------------------------------------
// Live GameInstance, computed each call from the engine global (Ghidra-verified, macOS Steam 2.3.1).
// RED4ext's CGameEngine::Get() is null on macOS (unmapped hash) and the app-callback path never fires (the
// gameStates dispatch is dead), so we read the engine global directly:
//   GameInstance = *(*(*(imageBase + 0x90dc3a0) + 0x338) + 0x10)
// NOTE the macOS shift: CGameEngine is 0x380 here (+0x30 vs the SDK's 0x350), so framework is at 0x338, NOT
// the SDK's 0x308. gameInstance stays at framework+0x10. Recomputed each call so it's null before the engine
// is up and after teardown, and valid in between - callers guard on null.
// GameInstance via a two-level VTABLE-FINGERPRINT scan (offset-independent, self-validating, cached).
// Why: the live layout disproved every static offset (framework@0x308/0x338 both null on the app object), and
// every `GetGameInstance` native derives the instance from its *input* (this / a context arg) - none reads a
// global - so reflection can't hand it to us. What we DO have, Ghidra-confirmed, are two definitive fingerprints:
//   GameInstance   vtable RVA 0x6fb1fa0 (set by its ctor 0x1f2d640; the 0x140-byte object)
//   CGameFramework vtable RVA 0x728cd18 (set by its ctor 0x3f0d2ac; stores gameInstance at +0x10)
// The framework lives on the ENGINE, a sibling of the app/running-state object at the 0x90dc3a0 global. So:
//   level 1: scan the app object's fields directly for either fingerprint;
//   level 2: for each field that is a real polymorphic child (module vtable), scan ITS fields (app->engine->fw).
// Only real objects are dereferenced (vtable must be a module address), which keeps level 2 safe.
// Fault-proof pointer read: mach_vm_read_overwrite returns an error for unmapped/protected memory instead of
// raising SIGBUS/SIGSEGV. Every dereference in the scan goes through this, so a "plausible-looking" but unmapped
// value (the exact crash we hit: KERN_PROTECTION_FAILURE at 0x1e00000002) is simply skipped.
inline bool SafeReadPtr(const void* aAddr, const void** aOut)
{
    if (!aAddr) return false;
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), reinterpret_cast<mach_vm_address_t>(aAddr),
                                              sizeof(void*), reinterpret_cast<mach_vm_address_t>(aOut), &got);
    return kr == KERN_SUCCESS && got == sizeof(void*);
}

// True only if p points at a readable object whose first qword is a vtable inside the game module. Used to
// refuse virtual calls (GetType etc.) on values that merely LOOK like handles - a garbage instance pointer
// jumps to a garbage address (the ToLua crash 2026-09-22).
inline bool IsLiveObject(const void* p)
{
    auto v = reinterpret_cast<uintptr_t>(p);
    if (v <= 0x10000 || v >= 0x0000800000000000ULL) return false;
    const void* vt = nullptr;
    if (!SafeReadPtr(p, &vt)) return false;
    auto t = reinterpret_cast<uintptr_t>(vt); const auto base = addrs::ImageBase();
    return t > base && t < base + 0x10000000ULL;
}

// Is p inside the game's __TEXT (code) segment? Used to tell a real object (whose first qword is a vptr into a
// DATA segment) from a vtable masquerading as an "instance" (whose first qword is a function address in __TEXT).
inline bool IsInText(const void* p)
{
    static const std::pair<uintptr_t, uintptr_t> range = []() -> std::pair<uintptr_t, uintptr_t> {
        const auto* seg = getsegbyname("__TEXT"); // main executable (the game), unslid vmaddr
        if (!seg) return {0, 0};
        const uintptr_t slide = addrs::ImageBase() - 0x100000000ULL;
        return {seg->vmaddr + slide, seg->vmaddr + slide + seg->vmsize};
    }();
    auto v = reinterpret_cast<uintptr_t>(p);
    return range.first && v >= range.first && v < range.second;
}

inline RED4ext::GameInstance* ScanForGI()
{
    static RED4ext::GameInstance* cached = nullptr;
    static bool logged = false;
    // Roots to scan, in order. 0x8d5d830 = the CGameEngine global (Ghidra: getter FUN_10488b8dc returns it and
    // its caller reads framework at +0x310, the slot the live init job FUN_103f282c4 stores into). 0x90dc3a0 =
    // the app/running-state object (kept as a fallback root). Every hop is vtable-validated + fault-proof.
    constexpr std::uintptr_t kRoots[] = {0x8d5d830, 0x90dc3a0};
    constexpr std::uintptr_t kFwVt = 0x728cd18, kGiVt = 0x6fb1fa0;
    const std::uintptr_t base = addrs::ImageBase();
    const void* FW = reinterpret_cast<const void*>(base + kFwVt);
    const void* GIV = reinterpret_cast<const void*>(base + kGiVt);
    auto plausible = [](const void* p) { auto v = reinterpret_cast<uintptr_t>(p); return v > 0x10000 && v < 0x0000800000000000ULL; };
    auto rd = [&](const void* at) -> const void* { const void* v = nullptr; return SafeReadPtr(at, &v) ? v : nullptr; };
    auto vt = [&](const void* o) -> const void* { return plausible(o) ? rd(o) : nullptr; };
    auto isObj = [&](const void* o) { auto v = reinterpret_cast<uintptr_t>(vt(o)); return v > base && v < base + 0x10000000ULL; };
    auto giFromFw = [&](const void* fw) -> RED4ext::GameInstance* {
        const void* gi = rd(static_cast<const char*>(fw) + 0x10);
        return (plausible(gi) && vt(gi) == GIV) ? (RED4ext::GameInstance*)gi : nullptr;
    };
    if (cached && vt(cached) == GIV) return cached;
    cached = nullptr;

    for (std::uintptr_t rootRVA : kRoots)
    {
        const void* root = rd(reinterpret_cast<const void*>(base + rootRVA));
        if (!isObj(root)) continue;
        // level 1: direct fields
        for (std::uintptr_t off = 0; off < 0x380; off += 8)
        {
            const void* F = rd(static_cast<const char*>(root) + off);
            if (!plausible(F)) continue;
            const void* fv = vt(F);
            if (fv == GIV) { cached = (RED4ext::GameInstance*)F; if (!logged) { logged = true; LOGF("[cet-lua] GI found: root 0x%lx +0x%lx is the GameInstance", (unsigned long)rootRVA, (unsigned long)off); } return cached; }
            if (fv == FW) if (auto* gi = giFromFw(F)) { cached = gi; if (!logged) { logged = true; LOGF("[cet-lua] GI found: root 0x%lx +0x%lx = framework -> +0x10 = %p", (unsigned long)rootRVA, (unsigned long)off, (void*)gi); } return cached; }
        }
        // level 2: one hop through real child objects
        for (std::uintptr_t off = 0; off < 0x380; off += 8)
        {
            const void* F = rd(static_cast<const char*>(root) + off);
            if (!isObj(F) || F == root) continue;
            for (std::uintptr_t off2 = 0; off2 < 0x400; off2 += 8)
            {
                const void* G = rd(static_cast<const char*>(F) + off2);
                if (!plausible(G)) continue;
                const void* gv = vt(G);
                if (gv == GIV) { cached = (RED4ext::GameInstance*)G; if (!logged) { logged = true; LOGF("[cet-lua] GI found: root 0x%lx +0x%lx -> +0x%lx is the GameInstance", (unsigned long)rootRVA, (unsigned long)off, (unsigned long)off2); } return cached; }
                if (gv == FW) if (auto* gi = giFromFw(G)) { cached = gi; if (!logged) { logged = true; LOGF("[cet-lua] GI found: root 0x%lx +0x%lx -> +0x%lx = framework -> +0x10", (unsigned long)rootRVA, (unsigned long)off, (unsigned long)off2); } return cached; }
            }
        }
    }
    if (!logged) { logged = true; LOGF("[cet-lua] GI: fingerprint scan found neither framework nor GameInstance from roots 0x8d5d830/0x90dc3a0"); }
    return nullptr;
}

// Ground-truth diagnostic: log the LIVE chain from the CGameEngine global with real vtables (fault-proof), at
// the first tick and again at tick 300 (timing). Fingerprinting by base-ctor vtables missed - derived classes
// overwrite the vptr - so read what is actually there. Remove once GI is pinned.
inline void DumpEngineChain()
{
    static int calls = 0;
    ++calls;
    if (calls != 1 && calls != 300) return;
    const std::uintptr_t base = addrs::ImageBase();
    auto rd = [&](const void* at) -> const void* { const void* v = nullptr; return SafeReadPtr(at, &v) ? v : nullptr; };
    auto rva = [&](const void* p) -> unsigned long { auto v = reinterpret_cast<uintptr_t>(p); return (v > base && v < base + 0x10000000ULL) ? (unsigned long)(v - base) : 0UL; };
    auto vtr = [&](const void* o) -> unsigned long { return o ? rva(rd(o)) : 0UL; }; // vtable RVA or 0 if not module
    auto chain = [&](const char* tag, const void* obj) {
        if (!obj) { LOGF("[cet-lua] EC#%d %s: <null>", calls, tag); return; }
        LOGF("[cet-lua] EC#%d %s: obj=%p vt(rva)=0x%lx", calls, tag, obj, vtr(obj));
        for (std::uintptr_t off : {(std::uintptr_t)0x308, (std::uintptr_t)0x310, (std::uintptr_t)0x338, (std::uintptr_t)0x340})
        {
            const void* F = rd(static_cast<const char*>(obj) + off);
            const void* G = F ? rd(static_cast<const char*>(F) + 0x10) : nullptr;
            const void* G8 = F ? rd(static_cast<const char*>(F) + 0x8) : nullptr;
            LOGF("[cet-lua]   %s+0x%lx: F=%p vt=0x%lx | F+0x8=%p vt=0x%lx | F+0x10=%p vt=0x%lx",
                 tag, (unsigned long)off, F, vtr(F), G8, vtr(G8), G, vtr(G));
        }
    };
    const void* E = rd(reinterpret_cast<const void*>(base + 0x8d5d830));
    chain("ENGINE(0x8d5d830)", E);
    const void* A = rd(reinterpret_cast<const void*>(base + 0x90dc3a0));
    // app -> +0x370 -> +0x10 was the vt-0x7369570 object whose dtor clears the engine global: log its chain too
    const void* X = A ? rd(static_cast<const char*>(A) + 0x370) : nullptr;
    const void* X10 = X ? rd(static_cast<const char*>(X) + 0x10) : nullptr;
    chain("APP+0x370->+0x10", X10);
}

// The CGameFramework captured at construction by the ctor hook in main.cpp (RVA 0x3f0d2ac). Definitive: the
// factory Allocate(0x28)s it and constructs through exactly one ctor call site, and that ctor is the one that
// builds the GameInstance (FUN_101f2d640, vtable 0x6fb1fa0) and stores it at framework+0x10.
inline void*& Framework() { static void* f = nullptr; return f; }

inline RED4ext::GameInstance* GI()
{
    if (void* fw = Framework())
    {
        const void* gi = nullptr;
        if (SafeReadPtr(static_cast<const char*>(fw) + 0x10, &gi) && gi)
        {
            const void* vt = nullptr;
            if (SafeReadPtr(gi, &vt) && reinterpret_cast<uintptr_t>(vt) == addrs::ImageBase() + 0x6fb1fa0)
                return const_cast<RED4ext::GameInstance*>(static_cast<const RED4ext::GameInstance*>(gi));
        }
    }
    return nullptr; // no scan fallback: the ctor hook is the definitive source, and scanning per frame stalls the splash
}
// Kept as a no-op for call-site compatibility (drivers used to push the app here; GI() now self-sources).
inline void SetGIFromApp(void* /*aApp*/) {}

// One-shot diagnostic: log the engine-global walk at a few ticks so we can see which framework offset yields a
// live gameInstance (0x338 is the Ghidra-verified value, but confirm in-world). Self-throttled; safe pointer
// checks. Remove once GI is confirmed.
inline void DumpEngineWalk()
{
    static int calls = 0;
    ++calls;
    if (calls != 1 && calls != 300) return;
    auto plausible = [](void* p) { auto v = reinterpret_cast<uintptr_t>(p); return v > 0x10000 && v < 0x0000800000000000ULL; };
    auto vt = [&](void* o) -> void* { return plausible(o) ? *reinterpret_cast<void**>(o) : nullptr; };
    uintptr_t base = addrs::ImageBase();
    char* eg = *reinterpret_cast<char**>(base + 0x90dc3a0);
    LOGF("[cet-lua] EW#%d: base=%p eg=%p eg.vt(rva)=0x%lx", calls, (void*)base, (void*)eg,
         eg ? (unsigned long)(reinterpret_cast<uintptr_t>(vt(eg)) - base) : 0UL);
    if (!plausible(eg)) return;
    for (uintptr_t off = 0x300; off <= 0x378; off += 8)
    {
        char* fw = *reinterpret_cast<char**>(eg + off);
        if (!plausible(fw)) continue;
        void* fwvt = vt(fw);
        char* gi = *reinterpret_cast<char**>(fw + 0x10);
        void* givt = plausible(gi) ? vt(gi) : nullptr;
        unsigned long fwrva = plausible(fwvt) ? (unsigned long)(reinterpret_cast<uintptr_t>(fwvt) - base) : 0;
        unsigned long girva = givt ? (unsigned long)(reinterpret_cast<uintptr_t>(givt) - base) : 0;
        LOGF("[cet-lua]   +0x%lx fw=%p fw.vt(rva)=0x%lx | +0x10 gi=%p gi.vt(rva)=0x%lx",
             (unsigned long)off, (void*)fw, fwrva, (void*)gi, girva);
    }
}

// A ScriptGameInstance is { GameInstance* instance; int8 unk8=1; int64 unk10=0 } (0x18). Built as a plain POD:
// the SDK's ScriptGameInstance(GameInstance*) ctor runs a call_once size-check through CRTTISystem::Get(), which
// is unmapped on macOS (null) -> null deref. This layout is exactly what the engine's own builder
// (FUN_101f44968) writes, so the native reads it identically.
struct SGI { RED4ext::GameInstance* instance; int8_t unk8; int64_t unk10; };
static_assert(sizeof(SGI) == 0x18, "ScriptGameInstance must be 0x18");
inline SGI MakeSGI() { return SGI{GI(), 1, 0}; }

// ---- ClassRef (returned engine object) forward decl ----------------------------------------------------
sol::object WrapInstance(sol::state_view lua, IScriptable* inst, CClass* type, void* refCount = nullptr);

// ---- Marshalling: scratch storage keeps arg buffers alive across the call ------------------------------
struct Scratch
{
    std::vector<std::shared_ptr<void>> keep;
    template <typename T> T* alloc(const T& v)
    {
        auto p = std::make_shared<T>(v);
        keep.push_back(p);
        return p.get();
    }
    // zeroed raw bytes (a param blob must never be uninitialized heap)
    void* raw(size_t n)
    {
        auto p = std::shared_ptr<void>(operator new(n), [](void* q) { operator delete(q); });
        std::memset(p.get(), 0, n);
        keep.push_back(p);
        return p.get();
    }
    // a zeroed, Construct'ed instance of an RTTI type (Construct is a virtual on the engine-owned type object)
    void* typed(CBaseRTTIType* t)
    {
        size_t n = (t && t->GetSize()) ? t->GetSize() : 8;
        void* p = raw(n);
        if (t) t->Construct(p);
        return p;
    }
    // RED4ext::CString as a POD (0x20): text/ptr@0, cap@0x10, length|flags@0x14, allocator@0x18. Short strings
    // are inline; long ones point at our own buffer with the 0x40000000 "not owned" flag so the engine reads
    // it but never frees it. Never constructs the SDK CString (its ctor/copy/dtor are unmapped on macOS).
    void* cstring(const std::string& str)
    {
        auto* p = static_cast<unsigned char*>(raw(0x20));
        if (str.size() < 0x14)
        {
            std::memcpy(p, str.data(), str.size());
            *reinterpret_cast<uint32_t*>(p + 0x14) = (uint32_t)str.size();
        }
        else
        {
            char* buf = static_cast<char*>(raw(str.size() + 1));
            std::memcpy(buf, str.data(), str.size());
            *reinterpret_cast<char**>(p) = buf;
            *reinterpret_cast<uint32_t*>(p + 0x10) = (uint32_t)str.size() + 1;
            *reinterpret_cast<uint32_t*>(p + 0x14) = (uint32_t)str.size() | 0x40000000u;
        }
        return p;
    }
};

inline bool NameIs(CBaseRTTIType* t, const char* n) { return t && t->GetName() == CName(n); }

// Lua value -> a pointer to a RED value of type `t`, allocated in `s`. Returns nullptr on unsupported.
inline void* ToRED(sol::state_view lua, sol::object o, CBaseRTTIType* t, Scratch& s)
{
    if (!t) return nullptr;
    const ERTTIType kind = t->GetType();
    if (NameIs(t, "ScriptGameInstance") || NameIs(t, "GameInstance")) return s.alloc(MakeSGI());
    switch (kind)
    {
    case ERTTIType::Name:
        if (o.is<LCName>()) return s.alloc(CName{o.as<LCName>().hash});
        if (o.get_type() == sol::type::string) return s.alloc(reflect::NameAdd(o.as<std::string>().c_str()));
        return s.alloc(CName{});
    case ERTTIType::Fundamental:
    {
        auto nm = t->GetName();
        if (nm == CName("Bool")) { bool b = o.is<bool>() ? o.as<bool>() : (ReadU64(o) != 0); return s.alloc(b); }
        if (nm == CName("Float")) { float f = o.is<double>() ? (float)o.as<double>() : 0.f; return s.alloc(f); }
        if (nm == CName("Double")) { double d = o.is<double>() ? o.as<double>() : 0.0; return s.alloc(d); }
        if (nm == CName("Uint64") || nm == CName("Int64")) return s.alloc(ReadU64(o));
        if (nm == CName("Uint32")) return s.alloc((uint32_t)ReadU64(o));
        if (nm == CName("Int32")) return s.alloc((int32_t)ReadU64(o));
        if (nm == CName("Uint16")) return s.alloc((uint16_t)ReadU64(o));
        if (nm == CName("Int16")) return s.alloc((int16_t)ReadU64(o));
        if (nm == CName("Uint8")) return s.alloc((uint8_t)ReadU64(o));
        if (nm == CName("Int8")) return s.alloc((int8_t)ReadU64(o));
        return s.alloc((int32_t)ReadU64(o));
    }
    case ERTTIType::Handle:
    case ERTTIType::WeakHandle:
    {
        struct HandlePOD { void* inst; void* ref; };
        if (o.is<LClassRef>())
        {
            auto& cr = o.as<LClassRef>();
            if (!cr.inst) return s.alloc(HandlePOD{nullptr, nullptr});
            if (cr.owner) throw std::runtime_error("cet-lua: a by-value struct cannot be passed as a handle");
            CClass* inner = (kind == ERTTIType::Handle)
                                ? static_cast<CClass*>(static_cast<RED4ext::CRTTIHandleType*>(t)->innerType)
                                : static_cast<CClass*>(static_cast<RED4ext::CRTTIWeakHandleType*>(t)->innerType);
            if (inner && cr.type)
            {
                bool isa = false;
                for (CClass* c = cr.type; c; c = c->parent) if (c == inner) { isa = true; break; }
                if (!isa)
                    throw std::runtime_error(std::string("cet-lua: handle type mismatch: expected ") +
                                             reflect::NameToString(inner->name) + " got " + reflect::NameToString(cr.type->name));
            }
            // faithful copy of the source handle {instance, refCount}; no ref inc/dec, no SDK ctor
            return s.alloc(HandlePOD{cr.inst, cr.refCount});
        }
        return s.alloc(HandlePOD{nullptr, nullptr});
    }
    case ERTTIType::Enum:
    {
        int64_t v = o.is<LEnum>() ? o.as<LEnum>().value : (o.get_type() == sol::type::number ? (int64_t)ReadU64(o) : 0);
        size_t n = t->GetSize() ? t->GetSize() : 4;
        void* p = s.raw(n);
        std::memcpy(p, &v, n > 8 ? 8 : n);
        return p;
    }
    case ERTTIType::Class:
    {
        if (NameIs(t, "entEntityID")) { uint64_t h = o.is<LEntityID>() ? o.as<LEntityID>().hash : ReadU64(o); return s.alloc(h); }
        if (NameIs(t, "gamedataTweakDBID") || NameIs(t, "TweakDBID"))
        { uint64_t v = o.is<LTweakID>() ? o.as<LTweakID>().value : ReadU64(o); return s.alloc(v); }
        if (NameIs(t, "Vector4") && o.is<LVector4>()) return s.alloc(o.as<LVector4>());
        if (NameIs(t, "Vector3") && o.is<LVector4>()) { auto v = o.as<LVector4>(); struct V3 { float x, y, z; } v3{v.x, v.y, v.z}; return s.alloc(v3); }
        if (NameIs(t, "EulerAngles") && o.is<LEuler>()) return s.alloc(o.as<LEuler>());
        if (NameIs(t, "Quaternion") && o.is<LQuat>()) return s.alloc(o.as<LQuat>());
        if (NameIs(t, "gameItemID") && o.is<LItemID>()) return s.alloc(o.as<LItemID>().id);
        // an object/struct value of this class: copy its bytes
        if (o.is<LClassRef>())
        {
            auto& cr = o.as<LClassRef>();
            if (cr.inst && t->GetSize()) { void* p = s.raw(t->GetSize()); std::memcpy(p, cr.inst, t->GetSize()); return p; }
        }
        return s.typed(t);
    }
    default:
        if (NameIs(t, "String"))
            return s.cstring(o.get_type() == sol::type::string ? o.as<std::string>() : std::string());
        return s.typed(t); // Simple/Array/Variant/...: a constructed empty value, never garbage
    }
}

// RED value -> Lua. copyStructs=true (return values): by-value structs are copied into Lua-owned storage so
// they outlive the call's return buffer; false (property reads): wrap the live engine memory.
inline sol::object ToLua(sol::state_view lua, CBaseRTTIType* t, void* v, bool copyStructs = true)
{
    if (!t || !v) return sol::make_object(lua, sol::lua_nil);
    const ERTTIType kind = t->GetType();
    switch (kind)
    {
    case ERTTIType::Name: return sol::make_object(lua, LCName{reinterpret_cast<CName*>(v)->hash});
    case ERTTIType::Fundamental:
    {
        auto nm = t->GetName();
        if (nm == CName("Bool")) return sol::make_object(lua, *reinterpret_cast<bool*>(v));
        if (nm == CName("Float")) return sol::make_object(lua, (double)*reinterpret_cast<float*>(v));
        if (nm == CName("Double")) return sol::make_object(lua, *reinterpret_cast<double*>(v));
        if (nm == CName("Uint64") || nm == CName("Int64")) return sol::make_object(lua, (double)*reinterpret_cast<uint64_t*>(v));
        if (nm == CName("Uint32")) return sol::make_object(lua, (double)*reinterpret_cast<uint32_t*>(v));
        if (nm == CName("Int32")) return sol::make_object(lua, (double)*reinterpret_cast<int32_t*>(v));
        if (nm == CName("Uint16")) return sol::make_object(lua, (double)*reinterpret_cast<uint16_t*>(v));
        if (nm == CName("Int16")) return sol::make_object(lua, (double)*reinterpret_cast<int16_t*>(v));
        if (nm == CName("Uint8")) return sol::make_object(lua, (double)*reinterpret_cast<uint8_t*>(v));
        if (nm == CName("Int8")) return sol::make_object(lua, (double)*reinterpret_cast<int8_t*>(v));
        return sol::make_object(lua, (double)*reinterpret_cast<int32_t*>(v));
    }
    case ERTTIType::Enum:
    {
        int64_t val = 0; size_t n = t->GetSize() ? t->GetSize() : 4; std::memcpy(&val, v, n > 8 ? 8 : n);
        return sol::make_object(lua, LEnum{std::string(reflect::NameToString(t->GetName())), val});
    }
    case ERTTIType::Handle:
    case ERTTIType::WeakHandle:
    {
        CClass* inner = (kind == ERTTIType::Handle)
                            ? static_cast<CClass*>(static_cast<RED4ext::CRTTIHandleType*>(t)->innerType)
                            : static_cast<CClass*>(static_cast<RED4ext::CRTTIWeakHandleType*>(t)->innerType);
        if (!inner) return sol::make_object(lua, sol::lua_nil);
        // Handle{instance, refCount}: wrap `instance` by the DECLARED class; never inspect the object (static
        // definitions have a function pointer, not a vptr, at +0). Keep refCount for faithful pass-back.
        const void* instance = nullptr; const void* refc = nullptr;
        if (!SafeReadPtr(v, &instance) || !instance) return sol::make_object(lua, sol::lua_nil);
        SafeReadPtr(static_cast<const char*>(v) + 8, &refc);
        return WrapInstance(lua, const_cast<IScriptable*>(static_cast<const IScriptable*>(instance)), inner, const_cast<void*>(refc));
    }
    case ERTTIType::Class:
    {
        auto* cls = static_cast<CClass*>(t);
        if (NameIs(t, "entEntityID")) return sol::make_object(lua, LEntityID{*reinterpret_cast<uint64_t*>(v)});
        if (NameIs(t, "gamedataTweakDBID") || NameIs(t, "TweakDBID")) return sol::make_object(lua, LTweakID{*reinterpret_cast<uint64_t*>(v)});
        if (NameIs(t, "Vector4")) { LVector4 r; std::memcpy(&r, v, 16); return sol::make_object(lua, r); }
        if (NameIs(t, "Vector3")) { LVector4 r; std::memcpy(&r, v, 12); r.w = 0; return sol::make_object(lua, r); }
        if (NameIs(t, "Quaternion")) { LQuat r; std::memcpy(&r, v, 16); return sol::make_object(lua, r); }
        if (NameIs(t, "EulerAngles")) { LEuler r; std::memcpy(&r, v, 12); return sol::make_object(lua, r); } // Roll,Pitch,Yaw
        if (NameIs(t, "gameItemID") || NameIs(t, "ItemID")) { LItemID r; std::memcpy(&r.id, v, sizeof(r.id)); return sol::make_object(lua, r); }
        if (!copyStructs) return sol::make_object(lua, LClassRef{reinterpret_cast<IScriptable*>(v), cls}); // live member
        size_t n = t->GetSize();
        if (!n) return sol::make_object(lua, sol::lua_nil);
        auto owner = std::shared_ptr<void>(operator new(n), [](void* q) { operator delete(q); });
        std::memcpy(owner.get(), v, n);
        LClassRef cr{reinterpret_cast<IScriptable*>(owner.get()), cls};
        cr.owner = owner;
        return sol::make_object(lua, cr);
    }
    default:
        if (NameIs(t, "String")) return sol::make_object(lua, std::string(reinterpret_cast<RED4ext::CString*>(v)->c_str()));
        return sol::make_object(lua, sol::lua_nil);
    }
}

// ---- Invoke an RTTI function with Lua args, return the Lua result --------------------------------------
inline sol::object InvokeFunc(sol::state_view lua, RED4ext::CBaseFunction* fn, IScriptable* ctx,
                              sol::variadic_args va, size_t skip = 0)
{
    if (!fn) return sol::make_object(lua, sol::lua_nil);
    const char* fname = reflect::NameToString(fn->fullName);
    if (!fname || !*fname) fname = "?";
    static int traced = 0;
    if (traced < 160)
    {
        ++traced;
        LOGF("[cet-lua] call %s native=%u params=%u ctx=%p", fname, (unsigned)fn->flags.isNative, fn->params.size, (void*)ctx);
    }
    // A SCRIPTED function needs a real script stack (locals/params/CScriptStack); the synthetic frame we build
    // only works for natives and null-derefs inside the executor otherwise. Refuse it as a Lua error.
    if (!fn->flags.isNative)
        throw std::runtime_error(std::string("cet-lua: scripted function not supported yet: ") + fname);
    if (!fn->flags.isStatic && !ctx)
        throw std::runtime_error(std::string("cet-lua: member function called without an instance: ") + fname);
    // If this call needs a GameInstance we don't have yet, skip rather than pass null.
    if (!GI())
        for (uint32_t gi = 0; gi < fn->params.size; ++gi)
        {
            auto* gpt = fn->params[gi]->type;
            if (NameIs(gpt, "ScriptGameInstance") || NameIs(gpt, "GameInstance"))
                return sol::make_object(lua, sol::lua_nil);
        }

    Scratch s;
    std::vector<RED4ext::CStackType> args(fn->params.size);
    RED4ext::CStackType result{};
    std::shared_ptr<void> retBuf;
    sol::object out = sol::make_object(lua, sol::lua_nil);
    bool ok = false;

    const bool safe = guard::Protected([&] {
        // arity: Lua args (after the implicit self) must not exceed the explicit params
        uint32_t explicitParams = 0;
        for (uint32_t i = 0; i < fn->params.size; ++i)
            if (!(NameIs(fn->params[i]->type, "ScriptGameInstance") || NameIs(fn->params[i]->type, "GameInstance"))) ++explicitParams;
        const size_t given = va.size() > skip ? va.size() - skip : 0;
        if (given > explicitParams)
            throw std::runtime_error(std::string("cet-lua: ") + fname + ": too many arguments (" + std::to_string(given) +
                                     " given, " + std::to_string(explicitParams) + " expected)");
        size_t luaIdx = skip;
        for (uint32_t i = 0; i < fn->params.size; ++i)
        {
            auto* p = fn->params[i];
            auto* pt = p->type;
            if (NameIs(pt, "ScriptGameInstance") || NameIs(pt, "GameInstance"))
            {
                args[i].type = pt;
                args[i].value = ToRED(lua, sol::lua_nil, pt, s);
                continue;
            }
            const bool have = luaIdx < va.size();
            if (!have && !p->flags.isOptional)
                throw std::runtime_error(std::string("cet-lua: ") + fname + ": missing argument " + std::to_string(i + 1) +
                                         " (" + reflect::NameToString(pt ? pt->GetName() : CName{}) + ")");
            sol::object a = have ? va[luaIdx++] : sol::object(sol::lua_nil);
            args[i].type = pt;
            args[i].value = have ? ToRED(lua, a, pt, s) : nullptr; // nullptr + optional -> NopOp in the frame
        }
        if (fn->returnType && fn->returnType->type)
        {
            result.type = fn->returnType->type;
            size_t rn = result.type->GetSize();
            retBuf = std::shared_ptr<void>(operator new(rn ? rn : 16), [](void* q) { operator delete(q); });
            std::memset(retBuf.get(), 0, rn ? rn : 16);
            result.value = retBuf.get();
        }
        ok = reflect::CallWithArgs(fn, ctx, args.data(), (uint32_t)args.size(), result.type ? &result : nullptr);
        if (ok) out = result.type ? ToLua(lua, result.type, result.value) : sol::make_object(lua, true);
    });
    if (!safe)
    {
        LOGF("[cet-lua] FAULT sig=%d in native call %s (ctx=%p) -> Lua error", guard::LastSignal(), fname, (void*)ctx);
        throw std::runtime_error(std::string("cet-lua: native call faulted: ") + fname);
    }
    if (!ok) return sol::make_object(lua, sol::lua_nil);
    return out;
}

// ---- ClassRef: returned engine object with dynamic method dispatch -------------------------------------
inline sol::object WrapInstance(sol::state_view lua, IScriptable* inst, CClass* type, void* refCount)
{
    if (!inst) return sol::make_object(lua, sol::lua_nil);
    return sol::make_object(lua, LClassRef{inst, type, refCount});
}

inline void RegisterClassRef(sol::state& lua)
{
    lua.new_usertype<LClassRef>(
        "__cetlua_ClassRef", sol::no_constructor,
        sol::meta_function::index,
        [](sol::this_state ts, LClassRef& self, std::string name) -> sol::object {
            sol::state_view lua(ts);
            const CName key(name.c_str());
            // 1) method: obj:Method(...) -> closure capturing (fn, ctx)
            if (auto* fn = reflect::GetClassFunction(self.type, key, true, true))
            {
                IScriptable* ctx = self.inst;
                CClass* selfType = self.type;
                return sol::make_object(lua, [fn, ctx, selfType](sol::this_state ts2, sol::variadic_args va) {
                    // obj:Method(a) arrives as {obj, a}: drop the implicit self so params[0] is `a`, not obj.
                    size_t skip = 0;
                    if (va.size() > 0)
                    {
                        sol::object a0 = va[0];
                        if (a0.is<LClassRef>())
                        {
                            auto& r = a0.as<LClassRef>();
                            if (r.inst == ctx && r.type == selfType) skip = 1;
                        }
                    }
                    return InvokeFunc(sol::state_view(ts2), fn, ctx, va, skip);
                });
            }
            // 2) property: obj.Field -> read the CProperty off the instance (walk parents). Done by scanning
            //    each class' own props array, NOT CClass::GetProperty (a reloc'd engine call that may resolve
            //    to 0 on macOS). Value marshalled through ToLua (handles -> ClassRef, scalars, names, strings).
            if (self.inst)
            {
                for (CClass* c = self.type; c; c = c->parent)
                {
                    for (uint32_t i = 0; i < c->props.size; ++i)
                    {
                        auto* prop = c->props[i];
                        if (!prop || !prop->type || prop->name != key) continue;
                        const char* base = reinterpret_cast<const char*>(self.inst);
                        if (prop->flags.inValueHolder) // scripted props live in IScriptable::valueHolder (+0x38)
                        {
                            const void* vh = nullptr;
                            if (!SafeReadPtr(base + 0x38, &vh) || !vh) return sol::make_object(lua, sol::lua_nil);
                            base = static_cast<const char*>(vh);
                        }
                        void* vp = const_cast<char*>(base) + prop->valueOffset;
                        static bool dumped = false;
                        if (!dumped)
                        {
                            dumped = true;
                            for (uint32_t k = 0; k < c->props.size && k < 12; ++k)
                            {
                                auto* q = c->props[k];
                                if (q && q->type)
                                    LOGF("[cet-lua]   %s.props[%u] %s kind=%d off=0x%x", reflect::NameToString(c->name), k,
                                         reflect::NameToString(q->name), (int)q->type->GetType(), q->valueOffset);
                            }
                        }
                        static int diag = 0;
                        if (diag < 24)
                        {
                            ++diag; const void* raw = nullptr; SafeReadPtr(vp, &raw);
                            LOGF("[cet-lua] prop %s.%s kind=%d type=%s off=0x%x raw=%p",
                                 reflect::NameToString(c->name), name.c_str(), (int)prop->type->GetType(),
                                 reflect::NameToString(prop->type->GetName()), prop->valueOffset, raw);
                        }
                        sol::object pv = sol::make_object(lua, sol::lua_nil);
                        const bool safe = guard::Protected([&] { pv = ToLua(lua, prop->type, vp, /*copyStructs*/ false); });
                        if (!safe)
                        {
                            LOGF("[cet-lua] FAULT sig=%d reading property %s.%s -> Lua error", guard::LastSignal(),
                                 reflect::NameToString(c->name), name.c_str());
                            throw std::runtime_error("cet-lua: property read faulted: " + name);
                        }
                        return pv;
                    }
                }
            }
            return sol::make_object(lua, sol::lua_nil);
        },
        "IsValid", &LClassRef::Valid);
}

// ---- The `Game` global + GetSingleton ------------------------------------------------------------------
inline void RegisterGame(sol::state& lua)
{
    RegisterClassRef(lua);

    // Game facade: Game.<Name> resolves a global RTTI function and returns a marshalling callable.
    sol::table game = lua.create_named_table("Game");
    sol::table gameMeta = lua.create_table();
    gameMeta[sol::meta_function::index] = [](sol::this_state ts, sol::table /*self*/, std::string name) -> sol::object {
        sol::state_view lua(ts);
        RED4ext::CBaseFunction* fn = reflect::GetGlobalFunction(CName(name.c_str()));
        if (!fn)
        {
            // Some are static members on gameInstance-ish classes; try a couple of common owners.
            for (const char* owner : {"ScriptGameInstance", "GameInstance", "gameScriptGameInstance"})
            {
                auto* c = reflect::GetClass(CName(owner));
                if (c) { fn = reflect::GetClassFunction(c, CName(name.c_str()), false, true); if (fn) break; }
            }
        }
        if (!fn) return sol::make_object(lua, sol::lua_nil);
        return sol::make_object(lua, [fn](sol::this_state ts2, sol::variadic_args va) {
            return InvokeFunc(sol::state_view(ts2), fn, nullptr, va);
        });
    };
    game[sol::metatable_key] = gameMeta;

    lua["GetSingleton"] = [](sol::this_state ts, std::string cls) -> sol::object {
        sol::state_view lua(ts);
        auto* c = reflect::GetClass(CName(cls.c_str()));
        if (!c) return sol::make_object(lua, sol::lua_nil);
        // A singleton reference is a ClassRef whose method calls pass the class' static instance (null ctx
        // works for static funcs; instance funcs on true singletons resolve their own context in-engine).
        return sol::make_object(lua, LClassRef{nullptr, c});
    };

    lua["GetMod"] = [](sol::this_state ts, std::string /*name*/) { return sol::object(sol::state_view(ts), sol::lua_nil); };
}
} // namespace cetlua::game
