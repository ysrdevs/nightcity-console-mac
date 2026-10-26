#pragma once

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>

namespace nightcity::flight_position {

using Valid = uint32_t (*)(uint32_t);
using Init = void* (*)(void*, uint32_t);
using WritePosition = void* (*)(void*, const float*, uint32_t);
using Commit = void (*)(void*);
using Destroy = void (*)(void*);
// The game getter uses an ARM64 hidden output pointer in X8. This is the ABI
// of a verified native adapter that moves its X2 argument into X8, not the raw
// getter and not a C float3 return (which would use the HFA return registers).
using GetPosition = void (*)(uint32_t, uint32_t, float*);

struct Helpers {
    Valid valid = nullptr;
    Init init = nullptr;
    WritePosition writePosition = nullptr;
    Commit commit = nullptr;
    Destroy destroy = nullptr;
    GetPosition getPosition = nullptr;
};

struct Candidate {
    uint64_t threadId = 0;
    uintptr_t context = 0;
    uint32_t depth = 0;
    uint32_t token = 0;
    uint32_t handle = 0;
    uint32_t valid = 0;
    std::array<float, 3> target{};
};
static_assert(sizeof(uintptr_t) == 8);
static_assert(sizeof(Candidate) == 48 && alignof(Candidate) == 8);
static_assert(std::is_trivially_copyable_v<Candidate>);

namespace detail {
struct Configuration { uintptr_t type = 0; Helpers helpers; };
inline Configuration configuration;
inline std::atomic<uint32_t> configurationState{0};
inline std::atomic<uint64_t> nextThreadId{1};
inline uint64_t allocateThreadId() noexcept {
    uint64_t next = nextThreadId.load(std::memory_order_relaxed);
    while (next && next != std::numeric_limits<uint64_t>::max()) {
        if (nextThreadId.compare_exchange_weak(next, next + 1, std::memory_order_relaxed)) return next;
    }
    return 0; // Saturate instead of recycling identities after overflow.
}

enum class Phase : uint8_t { idle, available, preparing, prepared, finished };
struct Scope {
    uintptr_t context = 0;
    uint32_t depth = 0;
    uint32_t token = 0;
    Phase phase = Phase::idle;
    bool poisoned = false;
};
struct ThreadState {
    const uint64_t id = allocateThreadId();
    uint32_t nextToken = 1;
    Scope scope;
};
inline ThreadState& threadState() noexcept {
    thread_local ThreadState state;
    return state;
}
inline const Configuration* config() noexcept {
    return configurationState.load(std::memory_order_acquire) == 2 ? &configuration : nullptr;
}
inline bool helpersEqual(const Helpers& a, const Helpers& b) noexcept {
    return a.valid == b.valid && a.init == b.init && a.writePosition == b.writePosition &&
           a.commit == b.commit && a.destroy == b.destroy && a.getPosition == b.getPosition;
}
inline bool vectorValid(const std::array<float, 3>& vector) noexcept {
    for (const float value : vector)
        if (!std::isfinite(value) || std::fabs(value) > 1000000.0f) return false;
    return true;
}
inline bool matches(const Scope& scope, const Candidate& candidate, Phase phase) noexcept {
    return scope.phase == phase && !scope.poisoned && scope.context == candidate.context &&
           scope.depth == candidate.depth && scope.token == candidate.token;
}
inline uint32_t readHandle(uintptr_t context) noexcept {
    uint32_t handle;
    // The exact owned executor scope establishes the interface's lifetime.
    // No unscoped call may read game memory, including this verified offset.
    std::memcpy(&handle, reinterpret_cast<const void*>(context + 0xa8), sizeof(handle));
    return handle;
}
struct alignas(8) Builder { std::array<unsigned char, 24> bytes{}; };
static_assert(sizeof(Builder) == 24 && alignof(Builder) == 8);
} // namespace detail

inline bool configure(uintptr_t type, uint32_t size, uint32_t alignment, Helpers helpers) noexcept {
    if (!type || (type & 7) || size != 12 || alignment != 4 || !helpers.valid ||
        !helpers.init || !helpers.writePosition || !helpers.commit || !helpers.destroy || !helpers.getPosition)
        return false;
    uint32_t expected = 0;
    if (detail::configurationState.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {
        detail::configuration = {type, helpers};
        detail::configurationState.store(2, std::memory_order_release);
        return true;
    }
    const auto* config = detail::config();
    return config && config->type == type && detail::helpersEqual(config->helpers, helpers);
}

inline uint32_t begin(uintptr_t context, uint32_t executorDepth) noexcept {
    auto& state = detail::threadState();
    if (state.scope.phase != detail::Phase::idle) {
        // No nested position writer is permitted, even for a different owner.
        // Its zero token must not let its End clear/re-enable the outer scope.
        state.scope.poisoned = true;
        return 0;
    }
    if (!detail::config() || !context || (context & 7) || !executorDepth ||
        !state.id || !state.nextToken) return 0;
    const uint32_t token = state.nextToken++;
    state.scope = {context, executorDepth, token, detail::Phase::available, false};
    return token;
}

inline bool end(uintptr_t context, uint32_t executorDepth, uint32_t token) noexcept {
    auto& scope = detail::threadState().scope;
    if (!token || scope.phase == detail::Phase::idle || scope.context != context ||
        scope.depth != executorDepth || scope.token != token) return false;
    scope = {};
    return true;
}

inline bool prepare(uintptr_t context, uint32_t enumValue, const void* variant24,
                    Candidate* candidate) noexcept {
    if (!candidate) return false;
    *candidate = {};
    const auto* config = detail::config();
    auto& state = detail::threadState();
    auto& scope = state.scope;
    if (!config || !context || (context & 7) || context != scope.context ||
        enumValue != 1 || scope.phase != detail::Phase::available || scope.poisoned)
        return false;
    // One eligible attempt per exact writer scope, including rejected payloads.
    scope.phase = detail::Phase::preparing;
    if (!variant24) return false;
    uintptr_t taggedType = 0;
    std::memcpy(&taggedType, variant24, sizeof(taggedType));
    if ((taggedType & ~uintptr_t{1}) != config->type) return false;
    const void* payload = static_cast<const unsigned char*>(variant24) + sizeof(uintptr_t);
    if (!(taggedType & 1)) {
        std::memcpy(&payload, payload, sizeof(payload));
        if (!payload) return false;
    }
    Candidate prepared;
    prepared.threadId = state.id;
    prepared.context = context;
    prepared.depth = scope.depth;
    prepared.token = scope.token;
    std::memcpy(prepared.target.data(), payload, 12);
    if (!detail::vectorValid(prepared.target)) return false;
    prepared.handle = detail::readHandle(context);
    if (!config->helpers.valid(prepared.handle) ||
        !detail::matches(scope, prepared, detail::Phase::preparing)) return false;
    scope.phase = detail::Phase::prepared;
    prepared.valid = 1;
    *candidate = prepared;
    return true;
}

inline bool finish(Candidate* candidate, bool originalAccepted) noexcept {
    if (!candidate) return false;
    const Candidate prepared = *candidate;
    candidate->valid = 0;
    const auto* config = detail::config();
    auto& state = detail::threadState();
    auto& scope = state.scope;
    if (!config || !prepared.valid || prepared.threadId != state.id ||
        !detail::matches(scope, prepared, detail::Phase::prepared)) return false;
    // Consume before any helper calls. Copies/replays and reentrant writers
    // cannot issue a second sequence or revive the candidate after rejection.
    scope.phase = detail::Phase::finished;
    if (originalAccepted || !detail::vectorValid(prepared.target)) return false;
    const auto& helpers = config->helpers;
    if (detail::readHandle(prepared.context) != prepared.handle || !helpers.valid(prepared.handle)) return false;
    std::array<float, 3> current;
    current.fill(std::numeric_limits<float>::quiet_NaN());
    helpers.getPosition(prepared.handle, 0, current.data());
    if (!detail::vectorValid(current)) return false;
    double distanceSquared = 0;
    for (std::size_t axis = 0; axis < 3; ++axis) {
        const double delta = double(prepared.target[axis]) - double(current[axis]);
        distanceSquared += delta * delta;
    }
    if (distanceSquared > 1.0 || !detail::matches(scope, prepared, detail::Phase::finished)) return false;
    // Re-read identity and validity after the getter, immediately before apply.
    if (detail::readHandle(prepared.context) != prepared.handle || !helpers.valid(prepared.handle) ||
        !detail::matches(scope, prepared, detail::Phase::finished)) return false;
    detail::Builder builder;
    if (helpers.init(&builder, prepared.handle) != &builder ||
        !detail::matches(scope, prepared, detail::Phase::finished)) {
        helpers.destroy(&builder);
        return false;
    }
    if (helpers.writePosition(&builder, prepared.target.data(), 0) != &builder ||
        !detail::matches(scope, prepared, detail::Phase::finished)) {
        helpers.destroy(&builder);
        return false;
    }
    helpers.commit(&builder);
    helpers.destroy(&builder);
    // This confirms only a native sequence was issued, never gameplay motion.
    return true;
}

} // namespace nightcity::flight_position
