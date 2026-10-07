// cet-lua: registerForEvent + the event bus. CET injects registerForEvent only during init.lua; we keep a
// global name->callbacks registry (sufficient for Phase 1; per-mod scoping is a Phase-1.5 refinement).
#pragma once
#include <sol/sol.hpp>
#include <string>
#include <unordered_map>
#include <vector>
#include "log.hpp"

namespace cetlua::events
{
struct Bus
{
    std::unordered_map<std::string, std::vector<sol::protected_function>> cbs;
    bool acceptRegistrations = false; // true only while an init.lua chunk runs
};
inline Bus& G() { static Bus b; return b; }

inline const std::vector<std::string>& Names()
{
    static const std::vector<std::string> n = {"onInit",       "onUpdate",       "onShutdown", "onDraw",
                                               "onOverlayOpen", "onOverlayClose", "onHook",     "onTweak"};
    return n;
}

inline void Register(sol::state& lua)
{
    lua["registerForEvent"] = [](sol::this_state ts, std::string name, sol::protected_function fn) {
        auto& b = G();
        if (!b.acceptRegistrations)
        {
            LOGF("[cet-lua] registerForEvent('%s') ignored (only valid during init.lua load)", name.c_str());
            return;
        }
        bool known = false;
        for (auto& e : Names()) if (e == name) { known = true; break; }
        if (!known) { LOGF("[cet-lua] registerForEvent: unknown event '%s'", name.c_str()); return; }
        b.cbs[name].push_back(std::move(fn));
        (void)ts;
    };
}

inline void Fire(const char* name)
{
    auto it = G().cbs.find(name);
    if (it == G().cbs.end()) return;
    for (auto& f : it->second)
    {
        sol::protected_function_result r = f();
        if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] %s callback error: %s", name, e.what()); }
    }
}

inline void FireUpdate(double dt)
{
    auto it = G().cbs.find("onUpdate");
    if (it == G().cbs.end()) return;
    for (auto& f : it->second)
    {
        sol::protected_function_result r = f(dt);
        if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] onUpdate callback error: %s", e.what()); }
    }
}
} // namespace cetlua::events
