// cet-lua: the mod loader. Scans the CET mods dir, runs each <name>/init.lua in a per-mod environment with a
// sandboxed require rooted at the mod folder (matching CET's <arg> -> <arg>.lua -> <arg>/init.lua resolution
// and its (module, err) return convention). The init.lua return value becomes the mod object.
#pragma once
#include <sol/sol.hpp>
#include <dirent.h>
#include <sys/stat.h>
#include <string>
#include <unordered_map>
#include <vector>
#include "events.hpp"
#include "log.hpp"

namespace cetlua::sandbox
{
inline bool IsDir(const std::string& p) { struct stat st; return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode); }
inline bool IsFile(const std::string& p) { struct stat st; return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode); }

// Candidate CET mod roots, in priority order. mansion ships under cyber_engine_tweaks/mods.
inline std::vector<std::string> ModRoots(const std::string& gameDir)
{
    return {gameDir + "/bin/x64/plugins/cyber_engine_tweaks/mods",
            gameDir + "/red4ext/plugins/cet-lua/mods"};
}

// Install a per-mod `require`/`loadfile` rooted at modDir into env. Caches by absolute path; returns (mod, err).
inline void InstallRequire(sol::state& lua, sol::environment& env, const std::string& modDir)
{
    auto cache = std::make_shared<std::unordered_map<std::string, sol::object>>();
    auto resolve = [modDir](const std::string& name) -> std::string {
        // reject escapes
        if (name.find("..") != std::string::npos || (!name.empty() && name[0] == '/')) return "";
        std::string base = modDir + "/" + name;
        if (IsFile(base)) return base;
        if (IsFile(base + ".lua")) return base + ".lua";
        if (IsFile(base + "/init.lua")) return base + "/init.lua";
        return "";
    };
    // require(name) -> module (errors on failure, like CET mods expect for hard deps)
    env.set_function("require", [&lua, env, cache, resolve, modDir](sol::this_state ts, std::string name) -> sol::object {
        sol::state_view L(ts);
        std::string path = resolve(name);
        if (path.empty()) { LOGF("[cet-lua] require('%s'): not found under %s", name.c_str(), modDir.c_str()); return sol::make_object(L, sol::lua_nil); }
        auto it = cache->find(path);
        if (it != cache->end()) return it->second;
        (*cache)[path] = sol::make_object(L, true); // guard against require cycles
        sol::protected_function_result r = lua.safe_script_file(path, env, sol::script_pass_on_error, sol::load_mode::text);
        if (!r.valid()) { sol::error e = r; LOGF("[cet-lua] require('%s') error: %s", name.c_str(), e.what()); return sol::make_object(L, sol::lua_nil); }
        sol::object mod = r;
        (*cache)[path] = mod;
        return mod;
    });
}

// Load every mod found under the roots. Returns count loaded.
inline int LoadAll(sol::state& lua, const std::string& gameDir)
{
    int loaded = 0;
    events::G().acceptRegistrations = true; // registerForEvent is only valid during init.lua
    for (const auto& root : ModRoots(gameDir))
    {
        if (!IsDir(root)) continue;
        DIR* d = opendir(root.c_str());
        if (!d) continue;
        while (dirent* e = readdir(d))
        {
            std::string name = e->d_name;
            if (name == "." || name == ".." || name == "cet") continue;
            std::string modDir = root + "/" + name;
            std::string init = modDir + "/init.lua";
            if (!IsDir(modDir) || !IsFile(init)) continue;

            sol::environment env(lua, sol::create, lua.globals()); // fallback-index to real globals
            InstallRequire(lua, env, modDir);
            env["__modName"] = name;
            env["__modDir"] = modDir;

            LOGF("[cet-lua] loading mod '%s' (%s)", name.c_str(), init.c_str());
            sol::protected_function_result r = lua.safe_script_file(init, env, sol::script_pass_on_error, sol::load_mode::text);
            if (!r.valid()) { sol::error err = r; LOGF("[cet-lua] mod '%s' init.lua ERROR: %s", name.c_str(), err.what()); continue; }
            // The returned table (if any) is the mod object; CET also calls mod:new() if present.
            if (r.get_type() == sol::type::table)
            {
                sol::table mo = r;
                sol::protected_function newfn = mo["new"];
                if (newfn.valid())
                {
                    sol::protected_function_result nr = newfn(mo);
                    if (!nr.valid()) { sol::error e2 = nr; LOGF("[cet-lua] mod '%s':new() error: %s", name.c_str(), e2.what()); }
                }
            }
            ++loaded;
        }
        closedir(d);
    }
    events::G().acceptRegistrations = false;
    LOGF("[cet-lua] loaded %d mod(s)", loaded);
    return loaded;
}
} // namespace cetlua::sandbox
