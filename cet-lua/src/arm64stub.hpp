// cet-lua: arm64 trampoline codegen for Observe/Override.
//
// CET (Windows/x86-64) uses an Xbyak `OverrideCodegen` that turns the engine's 4-arg native-handler call
// `(context, frame, out, retType)` into a 5-arg call to HandleOverridenFunction by pushing the original
// CBaseFunction* as the stack-passed 5th arg. On arm64 (AAPCS64) the first eight integer args live in
// x0-x7, so the port is simpler and a *tail* call: x0-x3 already hold (context, frame, out, retType); we
// only load x4 = apFunction and branch to the handler, which returns straight to the engine caller.
//
// Stub (9 instructions / 36 bytes), verified byte-identical to `clang -arch arm64` output:
//     movz x4,  #imm0 ; movk x4,  #imm1,lsl16 ; movk x4,  #imm2,lsl32 ; movk x4,  #imm3,lsl48   ; x4  = apFunction
//     movz x16, #imm0 ; movk x16, #imm1,lsl16 ; movk x16, #imm2,lsl32 ; movk x16, #imm3,lsl48   ; x16 = &handler
//     br x16
//
// Executable memory uses the Apple-sanctioned MAP_JIT + pthread_jit_write_protect_np dance. If the host
// process lacks the com.apple.security.cs.allow-jit entitlement the mmap fails and Alloc returns nullptr;
// callers treat that as "cannot arm" (Observe/Override install is gated on in-game validation regardless).
#pragma once
#include <cstdint>
#include <cstring>
#include <sys/mman.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#include "log.hpp"

namespace cetlua::arm64
{
// ---- instruction encoders (verified against clang -arch arm64) ---------------------------------------
inline uint32_t MOVZ(int rd, uint16_t imm, int hw) { return 0xD2800000u | ((uint32_t)hw << 21) | ((uint32_t)imm << 5) | (rd & 31); }
inline uint32_t MOVK(int rd, uint16_t imm, int hw) { return 0xF2800000u | ((uint32_t)hw << 21) | ((uint32_t)imm << 5) | (rd & 31); }
inline uint32_t BR(int rn)                         { return 0xD61F0000u | ((uint32_t)(rn & 31) << 5); }

// Load a full 64-bit immediate into xRd with movz + 3x movk. Writes 4 words, returns the count.
inline int EmitLoad64(uint32_t* out, int rd, uint64_t v)
{
    out[0] = MOVZ(rd, (uint16_t)(v & 0xFFFF), 0);
    out[1] = MOVK(rd, (uint16_t)((v >> 16) & 0xFFFF), 1);
    out[2] = MOVK(rd, (uint16_t)((v >> 32) & 0xFFFF), 2);
    out[3] = MOVK(rd, (uint16_t)((v >> 48) & 0xFFFF), 3);
    return 4;
}

constexpr int kStubWords = 9;
constexpr size_t kStubBytes = kStubWords * 4;

// Fill `words[0..8]` with the trampoline: set x4=aRealFunc, jump to aHandler. Pure data; no allocation.
inline void BuildStub(uint32_t words[kStubWords], uintptr_t aRealFunc, uintptr_t aHandler)
{
    int n = 0;
    n += EmitLoad64(words + n, 4, aRealFunc);   // x4  = apFunction
    n += EmitLoad64(words + n, 16, aHandler);   // x16 = &HandleOverridenFunction
    words[n++] = BR(16);                        // tail-call
}

// ---- executable-memory pool (MAP_JIT, W^X-correct) ---------------------------------------------------
// One page holds many stubs (36 bytes each). Bump-allocated; never freed (hooks live for the process).
struct StubPool
{
    uint8_t* base = nullptr;
    size_t cap = 0;
    size_t used = 0;

    bool Ensure(size_t need)
    {
        if (base && used + need <= cap) return true;
        size_t sz = 64 * 1024; // one 64K slab per grow
        void* p = mmap(nullptr, sz, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (p == MAP_FAILED)
        {
            LOGF("[cet-lua] arm64 StubPool mmap(MAP_JIT) FAILED (no allow-jit entitlement?) - cannot arm hooks");
            base = nullptr; cap = used = 0;
            return false;
        }
        base = (uint8_t*)p; cap = sz; used = 0;
        return true;
    }

    // Copy `bytes` into the pool as executable code; returns a callable pointer (or nullptr on failure).
    void* Emit(const void* bytes, size_t n)
    {
        if (!Ensure(n)) return nullptr;
        uint8_t* dst = base + used;
        pthread_jit_write_protect_np(0);          // make the JIT region writable on this thread
        std::memcpy(dst, bytes, n);
        pthread_jit_write_protect_np(1);          // back to executable
        sys_icache_invalidate(dst, n);            // flush I-cache for the freshly written code
        used += (n + 15) & ~size_t(15);           // 16-byte align next stub
        return dst;
    }
};

inline StubPool& Pool() { static StubPool p; return p; }

// Generate one trampoline; returns an executable function pointer with the CBaseFunction Handler_t shape,
// or nullptr if executable memory is unavailable.
inline void* MakeTrampoline(uintptr_t aRealFunc, uintptr_t aHandler)
{
    uint32_t words[kStubWords];
    BuildStub(words, aRealFunc, aHandler);
    return Pool().Emit(words, kStubBytes);
}
} // namespace cetlua::arm64
