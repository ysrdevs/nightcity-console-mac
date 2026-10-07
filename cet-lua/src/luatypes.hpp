// cet-lua: the CET Lua value types (CName, TweakDBID, ItemID, entEntityID, Vector4, EulerAngles, Quaternion)
// as sol2 usertypes, plus the handle wrapper for returned engine objects. Kept deliberately small - each
// holds the raw RED representation so marshalling is a memcpy.
#pragma once
#include <sol/sol.hpp>
#include <RED4ext/RED4ext.hpp>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <memory>
#include "reflect.hpp"

namespace cetlua::types
{
// Read a Lua value as a lossless uint64. Handles LuaJIT `ULL` cdata (via tostring -> strtoull, exactly how
// CET moves 64-bit integrals) and plain numbers/strings. This is what lets `13312760010544421172ULL` survive.
inline uint64_t ReadU64(sol::object o)
{
    if (!o.valid())
        return 0;
    if (o.get_type() == sol::type::number)
        return (uint64_t)o.as<double>();
    if (o.get_type() == sol::type::string)
        return std::strtoull(o.as<std::string>().c_str(), nullptr, 0);
    // cdata / userdata: stringify through Lua's tostring, then parse the leading digits (drops the ULL suffix).
    sol::state_view lua(o.lua_state());
    sol::protected_function ts = lua["tostring"];
    if (ts.valid())
    {
        sol::protected_function_result r = ts(o);
        if (r.valid())
        {
            std::string s = r.get<std::string>();
            // tostring on a cdata may be like "25176159ULL" or "cdata<...>: 0x..."; take the first number.
            const char* p = s.c_str();
            while (*p && (*p < '0' || *p > '9') && *p != 'x') ++p;
            return std::strtoull(p, nullptr, 0);
        }
    }
    return 0;
}

struct LCName    { uint64_t hash = 0; };
struct LTweakID  { uint64_t value = 0; };            // 32-bit hash | 8-bit length packed low
struct LEntityID { uint64_t hash = 0; };
struct LItemID   { RED4ext::ItemID id{}; };
struct LVector4  { float x = 0, y = 0, z = 0, w = 0; LVector4() = default; LVector4(float x_, float y_, float z_, float w_) : x(x_), y(y_), z(z_), w(w_) {} };
struct LEuler    { float roll = 0, pitch = 0, yaw = 0; LEuler() = default; LEuler(float r, float p, float y) : roll(r), pitch(p), yaw(y) {} }; // engine order Roll,Pitch,Yaw
struct LQuat     { float i = 0, j = 0, k = 0, r = 1; LQuat() = default; LQuat(float i_, float j_, float k_, float r_) : i(i_), j(j_), k(k_), r(r_) {} };
struct LEnum     { std::string type; int64_t value = 0; }; // CET Enum value {typeName, ordinal}

// A returned engine object. Phase 1 holds a raw instance + its runtime class (WeakHandle-like); Phase 3
// replaces this with a real refcounted Handle + GC-safety (see plan sec 3.2 "Handle refcounting").
struct LClassRef
{
    RED4ext::IScriptable* inst = nullptr;
    RED4ext::CClass* type = nullptr;
    void* refCount = nullptr; // the source Handle's RefCnt*, so we can pass the object back as a faithful copy
    std::shared_ptr<void> owner;  // set when inst points into a Lua-owned copy of a by-value struct (return values)
    bool Valid() const { return inst && type; }
};

// Register the value usertypes + their constructors. The Game facade + ClassRef are registered in game.hpp.
// Standard CRC-32 (poly 0xEDB88320), the engine's TweakDBID name hash.
inline uint32_t Crc32(const char* d, size_t n)
{
    static uint32_t T[256]; static bool init = false;
    if (!init) { init = true; for (uint32_t i = 0; i < 256; ++i) { uint32_t c = i; for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1); T[i] = c; } }
    uint32_t c = 0xFFFFFFFFu; for (size_t i = 0; i < n; ++i) c = T[(c ^ (uint8_t)d[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}

inline void RegisterValueTypes(sol::state& lua)
{
    lua.new_usertype<LCName>(
        "CName", sol::no_constructor,
        "hash", &LCName::hash,
        "ToString", [](LCName& n) { return std::string(reflect::NameToString(RED4ext::CName{n.hash})); });
    // CName.new(str) / CName.add(str) : add interns into CNamePool so hash->string round-trips.
    sol::table cname = lua["CName"];
    cname["new"] = [](const char* s) { return LCName{reflect::Fnv1a64(s)}; };
    cname["add"] = [](const char* s) { return LCName{reflect::NameAdd(s).hash}; };

    lua.new_usertype<LEntityID>("entEntityID", sol::no_constructor, "hash", &LEntityID::hash);
    sol::table eid = lua["entEntityID"];
    eid["new"] = [](sol::table t) { return LEntityID{ReadU64(t["hash"])}; };

    lua.new_usertype<LTweakID>(
        "TweakDBID", sol::no_constructor, "value", &LTweakID::value);
    sol::table tdb = lua["TweakDBID"];
    tdb["new"] = [](sol::object a) -> LTweakID {
        if (a.get_type() == sol::type::string)
        {
            // Engine TweakDBID = CRC32(name) | (length << 32) (SDK NativeTypes.hpp: {uint32 hash /*CRC32*/, uint8 length}).
            std::string s = a.as<std::string>();
            return LTweakID{(uint64_t)Crc32(s.data(), s.size()) | ((uint64_t)(s.size() & 0xFF) << 32)};
        }
        return LTweakID{ReadU64(a)};
    };

    lua.new_usertype<LVector4>("Vector4", sol::constructors<LVector4(), LVector4(float, float, float, float)>(),
                               "x", &LVector4::x, "y", &LVector4::y, "z", &LVector4::z, "w", &LVector4::w);
    lua.new_usertype<LEuler>("EulerAngles", sol::constructors<LEuler(), LEuler(float, float, float)>(),
                             "roll", &LEuler::roll, "pitch", &LEuler::pitch, "yaw", &LEuler::yaw);
    lua.new_usertype<LQuat>("Quaternion", sol::constructors<LQuat(), LQuat(float, float, float, float)>(),
                            "i", &LQuat::i, "j", &LQuat::j, "k", &LQuat::k, "r", &LQuat::r);
    lua.new_usertype<LItemID>("ItemID", sol::constructors<LItemID()>());

    // CET Enum: Enum.new(typeName, ordinal). Comparable by (type, value); marshalled to its ordinal for
    // enum-typed native params (see game.hpp ToRED). String member-name resolution via RTTI is a TODO.
    lua.new_usertype<LEnum>(
        "Enum", sol::no_constructor,
        "value", &LEnum::value,
        "type", &LEnum::type,
        sol::meta_function::to_string,
        [](const LEnum& e) { return e.type + "(" + std::to_string((long long)e.value) + ")"; },
        sol::meta_function::equal_to,
        [](const LEnum& a, const LEnum& b) { return a.type == b.type && a.value == b.value; });
    sol::table en = lua["Enum"];
    en["new"] = [](std::string type, sol::object val) -> LEnum {
        int64_t v = (val.get_type() == sol::type::number) ? (int64_t)ReadU64(val) : 0;
        return LEnum{std::move(type), v};
    };

    // CET table->value converters used by mansion (ToVector4{x,y,z,w}, ToEulerAngles{pitch,yaw,roll}).
    lua["ToVector4"] = [](sol::table t) {
        return LVector4{t.get_or("x", 0.0f), t.get_or("y", 0.0f), t.get_or("z", 0.0f), t.get_or("w", 0.0f)};
    };
    lua["ToEulerAngles"] = [](sol::table t) {
        return LEuler{t.get_or("roll", 0.0f), t.get_or("pitch", 0.0f), t.get_or("yaw", 0.0f)};
    };
    lua["ToQuaternion"] = [](sol::table t) {
        return LQuat{t.get_or("i", 0.0f), t.get_or("j", 0.0f), t.get_or("k", 0.0f), t.get_or("r", 1.0f)};
    };
}
} // namespace cetlua::types
