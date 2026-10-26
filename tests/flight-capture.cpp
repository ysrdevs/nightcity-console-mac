#include "../overlay/flight_capture.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace capture = nightcity::flight_capture;
constexpr uintptr_t filterType = 0x1000;
constexpr uintptr_t ownerA = 0x2000, ownerB = 0x3000;
constexpr uint32_t filterEnum = 32;
using Payload = std::array<uint64_t, 2>;

struct VariantBytes {
    uintptr_t type = 0;
    Payload data{};
};
static_assert(sizeof(VariantBytes) == capture::variantBytes);

// A deliberately small fixture for the verified POD Variant contract. Heap
// sources own a separate payload; copies are independent inline values; destroy
// frees only heap-backed payloads. It does not pretend to execute game RTTI.
struct OwnedVariant {
    VariantBytes value;
    static inline std::atomic<unsigned> allocations{0}, frees{0};
    OwnedVariant() = default;
    explicit OwnedVariant(Payload data, bool heap = false) {
        value.type = filterType | (heap ? 0 : 1);
        if (heap) {
            auto* payload = static_cast<Payload*>(std::malloc(sizeof(Payload)));
            assert(payload);
            *payload = data;
            std::memcpy(value.data.data(), &payload, sizeof(payload));
            ++allocations;
        } else value.data = data;
    }
    OwnedVariant(const OwnedVariant& other) {
        if (!other.value.type) return;
        value = {filterType | 1, other.payload()};
    }
    OwnedVariant& operator=(const OwnedVariant&) = delete;
    ~OwnedVariant() {
        if (value.type && !(value.type & 1)) {
            void* payload = nullptr;
            std::memcpy(&payload, value.data.data(), sizeof(payload));
            std::free(payload);
            ++frees;
        }
    }
    Payload payload() const {
        assert((value.type & ~uintptr_t{1}) == filterType);
        if (value.type & 1) return value.data;
        const Payload* pointer = nullptr;
        std::memcpy(&pointer, value.data.data(), sizeof(pointer));
        assert(pointer);
        return *pointer;
    }
};

static capture::Candidate prepare(uintptr_t owner, const VariantBytes& source) {
    capture::Candidate candidate;
    assert(capture::prepare(owner, filterEnum, &source, &candidate));
    return candidate;
}
static void accepted(uintptr_t owner, Payload payload) {
    const OwnedVariant source(payload);
    auto candidate = prepare(owner, source.value);
    assert(capture::finish(&candidate, true));
    assert(!capture::finish(&candidate, true));
}
static void expect(uintptr_t owner, uint32_t depth, Payload payload) {
    struct Guarded { uint64_t before = 0x12345678abcdef01; OwnedVariant output;
                     uint64_t after = 0xfedcba0123456789; } guarded;
    assert(capture::consume(owner, depth, &guarded.output.value));
    assert(guarded.before == 0x12345678abcdef01 && guarded.after == 0xfedcba0123456789);
    assert(guarded.output.value.type == (filterType | 1));
    assert(guarded.output.payload() == payload);
    OwnedVariant copied(guarded.output);
    assert(copied.payload() == payload);
    VariantBytes second;
    assert(!capture::consume(owner, depth, &second));
    assert(second.type == 0);
}

int main() {
    assert(!capture::begin(ownerA, 1));
    assert(!capture::configure(0, 16, 8, 32));
    assert(!capture::configure(filterType | 1, 16, 8, 32));
    assert(!capture::configure(filterType, 24, 8, 32));
    assert(!capture::configure(filterType, 16, 0, 32));
    assert(!capture::configure(filterType, 16, 3, 32));
    assert(!capture::configure(filterType, 16, 16, 32));
    assert(!capture::configure(filterType, 16, 8, 11));
    assert(capture::configure(filterType, 16, 8, 32));
    assert(capture::configure(filterType, 16, 8, 32));
    assert(!capture::configure(filterType + 8, 16, 8, 32));
    assert(!capture::configure(filterType, 16, 4, 32));

    // Ordinary, all-zero and heap-backed source values, with source lifetime
    // ending before consume. Guard bytes prove the output write is exactly 24.
    for (const bool heap : {false, true}) {
        assert(capture::begin(ownerA, 4));
        {
            OwnedVariant source({0x123456789abcdef0, 0xfedcba9876543210}, heap);
            auto candidate = prepare(ownerA, source.value);
            assert(capture::finish(&candidate, true));
        }
        expect(ownerA, 4, {0x123456789abcdef0, 0xfedcba9876543210});
    }
    assert(capture::begin(ownerA, 4)); accepted(ownerA, {0, 0}); expect(ownerA, 4, {0, 0});

    // No active scope means a later flight ZERO setter cannot become baseline.
    const OwnedVariant zero({0, 0});
    capture::Candidate candidate;
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(!capture::finish(&candidate, true));
    assert(!capture::consume(ownerA, 4, reinterpret_cast<void*>(1)));

    // Unrelated setters must be rejected before touching their argument memory.
    assert(capture::begin(ownerA, 4));
    assert(!capture::prepare(ownerB, 32, reinterpret_cast<void*>(1), &candidate));
    assert(!capture::prepare(ownerA, 4, reinterpret_cast<void*>(1), &candidate));
    assert(!capture::prepare(ownerA, 32, &zero.value, nullptr));
    struct ScratchGuard {
        uint64_t before = 0x123456789abcdef0;
        capture::Candidate value;
        uint64_t after = 0xfedcba9876543210;
    } scratch;
    assert(capture::prepare(ownerA, 32, &zero.value, &scratch.value));
    assert(capture::finish(&scratch.value, true));
    assert(scratch.before == 0x123456789abcdef0 && scratch.after == 0xfedcba9876543210);
    expect(ownerA, 4, {0, 0});

    // Refused, mismatched and empty arguments do not become accepted captures.
    for (int invalid = 0; invalid < 6; ++invalid) {
        assert(capture::begin(ownerA, 4));
        VariantBytes source{filterType | 1, {1, 2}};
        const void* pointer = &source;
        uintptr_t owner = ownerA;
        uint32_t state = 32;
        if (invalid == 0) source.type = 0;
        if (invalid == 1) source = {filterType + 8, {1, 0}}; // Never dereference poison pointer 1.
        if (invalid == 2) source = {filterType, {0, 0}};    // Correct heap tag, null payload.
        if (invalid == 3) pointer = nullptr;
        if (invalid == 4) owner = ownerB;
        if (invalid == 5) state = 4;
        assert(!capture::prepare(owner, state, pointer, &candidate));
        assert(!capture::finish(&candidate, true));
        VariantBytes output;
        assert(!capture::consume(ownerA, 4, &output));
        assert(output.type == 0 && output.data == Payload{});
    }
    assert(capture::begin(ownerA, 4));
    accepted(ownerA, {10, 20});
    candidate = prepare(ownerA, zero.value);
    assert(!capture::finish(&candidate, false));
    expect(ownerA, 4, {10, 20}); // Last successful original setter still wins.

    // Never overwrite an owning result, even with a valid accepted capture.
    assert(capture::begin(ownerA, 4)); accepted(ownerA, {1, 2});
    {
        OwnedVariant output({8, 9}, true);
        const auto before = output.value;
        assert(!capture::consume(ownerA, 4, &output.value));
        assert(std::memcmp(&before, &output.value, sizeof(before)) == 0);
        assert(output.payload() == (Payload{8, 9}));
    }
    VariantBytes empty;
    assert(!capture::consume(ownerA, 4, &empty));
    assert(capture::begin(ownerA, 4)); accepted(ownerA, {1, 2});
    assert(!capture::consume(ownerA, 4, nullptr));
    assert(!capture::consume(ownerA, 4, &empty));

    // Nested contexts, including the same interface, retain separate baselines.
    for (const uintptr_t inner : {ownerA, ownerB}) {
        assert(capture::begin(ownerA, 2)); accepted(ownerA, {2, 20});
        assert(capture::begin(inner, 3)); accepted(inner, {3, 30});
        expect(inner, 3, {3, 30}); expect(ownerA, 2, {2, 20});
    }

    // Regression: consuming an inner scope leaves the same-interface outer
    // scope active. The inner wrapper's subsequent own ZERO write must not
    // overwrite the outer original filter while that native scope is open.
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {2, 20});
    assert(capture::begin(ownerA, 3)); accepted(ownerA, {3, 30});
    expect(ownerA, 3, {3, 30});
    assert(capture::ownedBegin() == 1);
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(!capture::finish(&candidate, true));
    assert(capture::ownedEnd() == 1);
    expect(ownerA, 2, {2, 20});

    // A second legitimate setter after the guarded write is still captured.
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {2, 20});
    assert(capture::begin(ownerA, 3)); accepted(ownerA, {3, 30});
    expect(ownerA, 3, {3, 30});
    assert(capture::ownedBegin() == 1);
    assert(capture::ownedBegin() == 1);
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(capture::ownedEnd() == 1);
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(capture::ownedEnd() == 1);
    accepted(ownerA, {4, 40}); expect(ownerA, 2, {4, 40});

    // An outer original call may remain in flight during a nested own call.
    assert(capture::begin(ownerA, 2));
    const OwnedVariant original({9, 90});
    auto originalCandidate = prepare(ownerA, original.value);
    assert(capture::ownedBegin() == 1);
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(capture::ownedEnd() == 1);
    assert(capture::finish(&originalCandidate, true));
    expect(ownerA, 2, {9, 90});

    // No publication while suppressed, even for an earlier prepared candidate.
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {7, 70});
    originalCandidate = prepare(ownerA, original.value);
    assert(capture::ownedBegin() == 1);
    assert(!capture::finish(&originalCandidate, true));
    assert(capture::ownedEnd() == 1);
    assert(!capture::finish(&originalCandidate, true));
    expect(ownerA, 2, {7, 70});

    // Unbalanced guard exit cannot leave a previously captured scope available.
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {2, 20});
    assert(capture::ownedEnd() == 0);
    assert(!capture::consume(ownerA, 2, &empty));
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {5, 50});
    expect(ownerA, 2, {5, 50});
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {2, 20});
    assert(capture::begin(ownerB, 4));
    auto stale = prepare(ownerB, zero.value);
    assert(capture::begin(ownerB, 3)); // Unwind abandoned depth4, retain depth2.
    assert(!capture::finish(&stale, true));
    accepted(ownerB, {3, 30}); expect(ownerB, 3, {3, 30}); expect(ownerA, 2, {2, 20});

    const auto first = capture::begin(ownerA, 3);
    stale = prepare(ownerA, zero.value);
    const auto second = capture::begin(ownerA, 3);
    assert(first && second && first != second);
    assert(!capture::finish(&stale, true));
    assert(!capture::consume(ownerA, 3, &empty));
    assert(capture::begin(ownerA, 3)); accepted(ownerA, {1, 2});
    assert(!capture::consume(ownerB, 3, &empty)); // Mismatch closes that depth.
    assert(!capture::consume(ownerA, 3, &empty));
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {1, 2});
    assert(capture::begin(ownerB, 3)); accepted(ownerB, {3, 4});
    assert(!capture::consume(ownerA, 2, &empty)); // Out-of-order consume clears both.
    assert(!capture::consume(ownerB, 3, &empty));

    for (uint32_t depth = 1; depth <= capture::maxScopes; ++depth)
        assert(capture::begin(ownerA, depth));
    assert(!capture::begin(ownerA, 9));
    assert(!capture::prepare(ownerA, 32, &zero.value, &candidate));
    assert(!capture::consume(ownerA, 8, &empty));
    assert(capture::begin(ownerA, 1)); accepted(ownerA, {1, 2});
    assert(!capture::begin(0, 2));
    assert(!capture::consume(ownerA, 1, &empty));

    // Same interface addresses in different threads must not share state.
    std::vector<std::thread> workers;
    for (uint64_t worker = 1; worker <= 8; ++worker) workers.emplace_back([worker] {
        assert(capture::configure(filterType, 16, 8, 32));
        for (uint64_t sequence = 0; sequence < 500; ++sequence) {
            assert(capture::begin(ownerA, 2)); accepted(ownerA, {worker, sequence});
            assert(capture::begin(ownerA, 3)); accepted(ownerA, {sequence, worker});
            expect(ownerA, 3, {sequence, worker});
            assert(capture::ownedBegin() == 1);
            const OwnedVariant own({0, 0});
            capture::Candidate suppressed;
            assert(!capture::prepare(ownerA, 32, &own.value, &suppressed));
            assert(capture::ownedEnd() == 1);
            expect(ownerA, 2, {worker, sequence});
        }
    });
    for (auto& worker : workers) worker.join();
    capture::Candidate foreign;
    std::thread producer([&] {
        assert(capture::begin(ownerA, 2));
        foreign = prepare(ownerA, zero.value);
    });
    producer.join();
    assert(capture::begin(ownerA, 2)); accepted(ownerA, {77, 88});
    assert(!capture::finish(&foreign, true));
    expect(ownerA, 2, {77, 88});

    assert(OwnedVariant::allocations == OwnedVariant::frees);
    std::puts("Flight capture: immutable configuration, inline/heap payload ownership, 24-byte output guards, rejection, scopes, stale cleanup, overflow, nested own-write suppression, underflow cleanup and eight-thread isolation passed");
}
