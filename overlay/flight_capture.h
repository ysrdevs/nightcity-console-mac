#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace nightcity::flight_capture {

// Only the verified 2.5 physicsSimulationFilter POD contract is supported.
// Callers validate RTTI metadata before configuring and supply readable Variant
// arguments and a writable, initialized-empty 24-byte Variant result buffer.
constexpr std::size_t filterBytes = 16;
constexpr std::size_t variantBytes = 24;
constexpr std::size_t maxScopes = 8;

struct Candidate {
    uint64_t threadId = 0;
    uintptr_t context = 0;
    uint32_t depth = 0;
    uint32_t serial = 0;
    uint32_t slot = 0;
    uint32_t valid = 0;
    std::array<uint64_t, 2> payload{};
};
static_assert(sizeof(uintptr_t) == 8, "Flight capture requires the verified 64-bit ABI");
static_assert(sizeof(Candidate) == 48 && alignof(Candidate) == 8);
static_assert(std::is_trivially_copyable_v<Candidate>);

namespace detail {
struct Configuration {
    uintptr_t type = 0;
    uint32_t size = 0;
    uint32_t alignment = 0;
    uint32_t enumValue = 0;
};
inline Configuration configuration;
// 0 unconfigured, 1 one publisher owns initialization, 2 immutable and ready.
inline std::atomic<uint32_t> configurationState{0};
inline std::atomic<uint64_t> nextThreadId{1};

struct Scope {
    uintptr_t context = 0;
    uint32_t depth = 0;
    uint32_t serial = 0;
    bool captured = false;
    std::array<uint64_t, 2> payload{};
};
struct ThreadState {
    const uint64_t id = nextThreadId.fetch_add(1, std::memory_order_relaxed);
    uint32_t nextSerial = 1;
    std::size_t count = 0;
    std::array<Scope, maxScopes> scopes{};
};

// One shared TLS object must back both executor and native setter hooks. Native
// callers should go through exports in the same overlay image, not instantiate
// separate copies of this header in separate dynamically loaded libraries.
inline ThreadState& threadState() noexcept {
    thread_local ThreadState state;
    return state;
}

inline const Configuration* config() noexcept {
    return configurationState.load(std::memory_order_acquire) == 2 ? &configuration : nullptr;
}

inline void discardAtOrBelow(ThreadState& state, uint32_t depth) noexcept {
    while (state.count && state.scopes[state.count - 1].depth >= depth) {
        state.scopes[--state.count] = {};
    }
}

struct InlineVariant {
    uintptr_t type;
    std::array<uint64_t, 2> payload;
};
static_assert(sizeof(InlineVariant) == variantBytes);
} // namespace detail

inline bool configure(uintptr_t type, uint32_t size, uint32_t alignment,
                      uint32_t enumValue) noexcept {
    if (!type || (type & 1) || size != filterBytes || !alignment ||
        alignment > 8 || (alignment & (alignment - 1)) || enumValue != 32)
        return false;
    uint32_t expected = 0;
    if (detail::configurationState.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {
        detail::configuration = {type, size, alignment, enumValue};
        detail::configurationState.store(2, std::memory_order_release);
        return true;
    }
    const auto* config = detail::config();
    return config && config->type == type && config->size == size &&
           config->alignment == alignment && config->enumValue == enumValue;
}

inline uint32_t begin(uintptr_t context, uint32_t executorDepth) noexcept {
    auto& state = detail::threadState();
    if (!detail::config() || !context || !executorDepth || !state.id || !state.nextSerial) {
        state.count = 0;
        return 0;
    }
    // A new call at the same or a shallower depth invalidates abandoned scopes.
    // Properly nested deeper calls retain their caller's scope.
    detail::discardAtOrBelow(state, executorDepth);
    if (state.count == maxScopes) {
        // Leaving the outer scope active here would let an overflowed inner
        // call record its setter into that outer scope. Fail closed instead.
        state.count = 0;
        return 0;
    }
    const uint32_t serial = state.nextSerial++;
    state.scopes[state.count++] = {context, executorDepth, serial, false, {}};
    return serial;
}

inline bool prepare(uintptr_t context, uint32_t enumValue, const void* variant,
                    Candidate* candidate) noexcept {
    if (!candidate) return false;
    *candidate = {};
    const auto* config = detail::config();
    auto& state = detail::threadState();
    if (!config || !state.count || !context || !variant || enumValue != config->enumValue)
        return false;
    const auto& scope = state.scopes[state.count - 1];
    if (scope.context != context) return false;

    uintptr_t taggedType = 0;
    std::memcpy(&taggedType, variant, sizeof(taggedType));
    if ((taggedType & ~uintptr_t{1}) != config->type) return false;
    const void* payload = static_cast<const unsigned char*>(variant) + sizeof(uintptr_t);
    if (!(taggedType & 1)) {
        std::memcpy(&payload, payload, sizeof(payload));
        if (!payload) return false;
    }
    Candidate prepared;
    prepared.threadId = state.id;
    prepared.context = context;
    prepared.depth = scope.depth;
    prepared.serial = scope.serial;
    prepared.slot = static_cast<uint32_t>(state.count - 1);
    std::memcpy(prepared.payload.data(), payload, filterBytes);
    prepared.valid = 1;
    *candidate = prepared;
    return true;
}

inline bool finish(Candidate* candidate, bool accepted) noexcept {
    if (!candidate) return false;
    const Candidate prepared = *candidate;
    candidate->valid = 0;
    auto& state = detail::threadState();
    if (!accepted || !prepared.valid || !detail::config() || prepared.threadId != state.id ||
        !state.count || prepared.slot != state.count - 1)
        return false;
    auto& scope = state.scopes[prepared.slot];
    if (scope.context != prepared.context || scope.depth != prepared.depth ||
        scope.serial != prepared.serial)
        return false;
    scope.payload = prepared.payload;
    scope.captured = true;
    return true;
}

inline bool consume(uintptr_t context, uint32_t executorDepth, void* emptyVariant24) noexcept {
    auto& state = detail::threadState();
    const auto* config = detail::config();
    detail::Scope scope;
    bool matched = false;
    if (state.count) {
        scope = state.scopes[state.count - 1];
        matched = context && executorDepth && scope.context == context && scope.depth == executorDepth;
    }
    // Consume is also scope cleanup on every failure. An invalid depth cancels
    // all scopes; a valid outer depth removes abandoned deeper scopes as well.
    detail::discardAtOrBelow(state, executorDepth);
    if (!matched || !scope.captured || !config || !emptyVariant24) return false;
    uintptr_t previousType = 0;
    std::memcpy(&previousType, emptyVariant24, sizeof(previousType));
    if (previousType) return false;

    // The configured type is exactly a 16-byte, <=8-aligned POD filter. The
    // empty destination owns no old value; an inline copy owns these bytes and
    // retains no pointer into the original Variant. Never use this for arbitrary
    // Variant types, handles, strings, arrays or other owning structures.
    const detail::InlineVariant output{config->type | uintptr_t{1}, scope.payload};
    std::memcpy(emptyVariant24, &output, sizeof(output));
    return true;
}

} // namespace nightcity::flight_capture
