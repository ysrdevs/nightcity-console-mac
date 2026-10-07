// cet-lua: proven macOS ARM64 engine addresses (Steam 2.3.1).
// We pin RVAs directly + resolve against the MH_EXECUTE base, instead of trusting any vendored SDK's
// macOSAddressTable (the TweakXL fork maps the executor to 0x94FE44, which is NOT the proven universal
// executor - the proven one, used by Codeware's in-game reflection, is 0x2173120). Every value here is
// from the port plan's "known / proven" table (docs/CET-LUA-MODS-MACOS-PORT-PLAN.md sec 3.4); the 7
// "unknown" gates land in addrs_gates.hpp once the Ghidra hunt resolves them.
#pragma once
#include <cstdint>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>

namespace cetlua::addrs
{
// The game's MH_EXECUTE image base (NOT an injected dylib). Mirrors ArchiveXL/Codeware Core::Platform.
inline std::uintptr_t ImageBase()
{
    static const std::uintptr_t base = []() -> std::uintptr_t {
        const uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; ++i)
        {
            const auto* h = _dyld_get_image_header(i);
            if (h && h->filetype == MH_EXECUTE)
                return reinterpret_cast<std::uintptr_t>(h);
        }
        // Fallback: image 0 (should not happen for an injected plugin, but never return 0).
        return reinterpret_cast<std::uintptr_t>(_dyld_get_image_header(0));
    }();
    return base;
}

template <typename Fn>
inline Fn At(std::uintptr_t rva)
{
    return reinterpret_cast<Fn>(ImageBase() + rva);
}

// ---- proven RVAs ------------------------------------------------------------------------------------
constexpr std::uintptr_t CBaseFunction_InternalExecute = 0x2173120; // universal executor (the call keystone)
constexpr std::uintptr_t CRTTISystem_Get               = 0x2188e8c; // RTTI root singleton getter
constexpr std::uintptr_t CNamePool_Add                 = 0x3452ddc; // intern a string -> CName (by VALUE arg)
constexpr std::uintptr_t CNamePool_Get                 = 0x3452bdc; // CName hash -> const char* (by VALUE arg)
constexpr std::uintptr_t TweakDBID_Derive              = 0x3453b14; // compose child TweakDBID

// InitScripts window (RTTI ready, pre-bind) - where native registration / allocator hooks must arm.
constexpr std::uintptr_t CBaseEngine_InitScripts       = 0x3d8c188;
constexpr std::uintptr_t RTTIReadyFlagByte             = 0x7d6a268;
} // namespace cetlua::addrs
