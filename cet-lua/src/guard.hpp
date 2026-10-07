// cet-lua: fault guard. A native call that faults (SIGSEGV/SIGBUS) inside a Protected() region is unwound with
// siglongjmp and reported to the caller, which raises a Lua error naming the call - instead of the process
// dying. This turns "one crash per launch" into "every failing call listed in one launch". Faults OUTSIDE a
// protected region are forwarded to whatever handler was installed before us (RED4ext/gum) or the default, so
// unrelated crashes still produce a normal report. Diagnostic-grade: unwinding out of engine frames skips their
// cleanup, so state after a caught fault is best-effort.
#pragma once
#include <csetjmp>
#include <csignal>
#include <cstring>
#include "log.hpp"

namespace cetlua::guard
{
inline thread_local sigjmp_buf* t_jb = nullptr;
inline thread_local int t_sig = 0;
inline struct sigaction g_prevSegv{}, g_prevBus{};
inline bool g_installed = false;

inline void Forward(struct sigaction* prev, int sig, siginfo_t* si, void* uc)
{
    if (prev->sa_flags & SA_SIGINFO)
    {
        if (prev->sa_sigaction && reinterpret_cast<void*>(prev->sa_sigaction) != reinterpret_cast<void*>(SIG_DFL) &&
            reinterpret_cast<void*>(prev->sa_sigaction) != reinterpret_cast<void*>(SIG_IGN))
        { prev->sa_sigaction(sig, si, uc); return; }
    }
    else if (prev->sa_handler && prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN)
    { prev->sa_handler(sig); return; }
    signal(sig, SIG_DFL);
    raise(sig);
}

inline void OnFault(int sig, siginfo_t* si, void* uc)
{
    if (t_jb) { t_sig = sig; siglongjmp(*t_jb, 1); }
    Forward(sig == SIGBUS ? &g_prevBus : &g_prevSegv, sig, si, uc);
}

inline void Install()
{
    if (g_installed) return;
    g_installed = true;
    struct sigaction sa{};
    sa.sa_sigaction = OnFault;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_prevSegv);
    sigaction(SIGBUS, &sa, &g_prevBus);
    LOGF("[cet-lua] fault guard installed: faults inside native calls become Lua errors");
}

// Runs f(); returns false if it faulted (LastSignal() tells which signal).
template <typename F> inline bool Protected(F&& f)
{
    sigjmp_buf jb;
    struct Restore { sigjmp_buf* prev; ~Restore() { t_jb = prev; } } restore{t_jb}; // also on C++ throw
    t_jb = &jb;
    t_sig = 0;
    if (sigsetjmp(jb, 1) == 0) { f(); return true; }
    return false;
}
inline int LastSignal() { return t_sig; }
} // namespace cetlua::guard
