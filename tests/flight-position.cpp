#include "../overlay/flight_position.h"

#include <cassert>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace position = nightcity::flight_position;
using Vector = std::array<float, 3>;
constexpr uintptr_t vectorType = 0x1000;
constexpr uint32_t physicsHandle = 0x12345678;

struct alignas(8) Context {
    unsigned char prefix[0xa8]{};
    uint32_t handle = physicsHandle;
};
static_assert(offsetof(Context, handle) == 0xa8);
struct Variant {
    uintptr_t type = vectorType | 1;
    unsigned char payload[16]{};
    explicit Variant(Vector value) { std::memcpy(payload, value.data(), 12); }
};
static_assert(sizeof(Variant) == 24);
struct Spy {
    Context* owner = nullptr;
    Vector current{100, 200, 300}, written{};
    std::string events;
    unsigned validCalls = 0, invalidOn = 0;
    bool changeHandle = false, noGetterWrite = false, partialGetterWrite = false;
    bool failInit = false, failWrite = false;
    char poisonAt = 0;
};
static thread_local Spy spy;
static uintptr_t address(Context& context) { return reinterpret_cast<uintptr_t>(&context); }
static void record(char event) {
    spy.events += event;
    if (spy.poisonAt == event) {
        assert(spy.owner);
        assert(!position::begin(address(*spy.owner), 2));
        assert(!position::end(address(*spy.owner), 2, 0));
    }
}
static uint32_t valid(uint32_t handle) {
    record('V');
    ++spy.validCalls;
    return handle == physicsHandle && spy.validCalls != spy.invalidOn;
}
static void* init(void* builder, uint32_t handle) {
    record('I');
    assert(handle == physicsHandle && !(reinterpret_cast<uintptr_t>(builder) & 7));
    const std::array<unsigned char, 24> empty{};
    assert(std::memcmp(builder, empty.data(), 24) == 0);
    static_cast<unsigned char*>(builder)[0] = 0xa5;
    return spy.failInit ? nullptr : builder;
}
static void* writePosition(void* builder, const float* vector, uint32_t selector) {
    record('W');
    assert(selector == 0 && static_cast<unsigned char*>(builder)[0] == 0xa5);
    std::memcpy(spy.written.data(), vector, 12);
    return spy.failWrite ? nullptr : builder;
}
static void commit(void* builder) {
    record('C');
    assert(static_cast<unsigned char*>(builder)[0] == 0xa5);
}
static void destroy(void* builder) {
    record('D');
    assert(static_cast<unsigned char*>(builder)[0] == 0xa5);
    std::memset(builder, 0, 24);
}
static void getPosition(uint32_t handle, uint32_t selector, float* output) {
    record('G');
    assert(handle == physicsHandle && selector == 0);
    if (!spy.noGetterWrite) std::memcpy(output, spy.current.data(), spy.partialGetterWrite ? 8 : 12);
    if (spy.changeHandle) spy.owner->handle = physicsHandle + 1;
}
static position::Helpers helpers() { return {valid, init, writePosition, commit, destroy, getPosition}; }
static void reset(Context& context) { context.handle = physicsHandle; spy = {}; spy.owner = &context; }
static position::Candidate prepare(Context& context, Vector target = {100.25f, 200.5f, 300}) {
    const Variant variant(target);
    position::Candidate candidate;
    assert(position::prepare(address(context), 1, &variant, &candidate));
    return candidate;
}

int main() {
    Context context;
    reset(context);
    assert(!position::begin(address(context), 1));
    assert(!position::configure(0, 12, 4, helpers()));
    assert(!position::configure(vectorType | 1, 12, 4, helpers()));
    assert(!position::configure(vectorType + 4, 12, 4, helpers()));
    assert(!position::configure(vectorType, 16, 4, helpers()));
    assert(!position::configure(vectorType, 12, 8, helpers()));
    for (int missing = 0; missing < 6; ++missing) {
        auto invalid = helpers();
        if (missing == 0) invalid.valid = nullptr;
        if (missing == 1) invalid.init = nullptr;
        if (missing == 2) invalid.writePosition = nullptr;
        if (missing == 3) invalid.commit = nullptr;
        if (missing == 4) invalid.destroy = nullptr;
        if (missing == 5) invalid.getPosition = nullptr;
        assert(!position::configure(vectorType, 12, 4, invalid));
    }
    assert(position::configure(vectorType, 12, 4, helpers()));
    assert(position::configure(vectorType, 12, 4, helpers()));
    assert(!position::configure(vectorType + 8, 12, 4, helpers()));
    auto changed = helpers(); changed.valid = [](uint32_t) -> uint32_t { return 1; };
    assert(!position::configure(vectorType, 12, 4, changed));

    // No scope or a mismatched scope must not dereference the poison arguments.
    position::Candidate candidate;
    assert(!position::prepare(8, 1, reinterpret_cast<void*>(1), &candidate));
    assert(!position::begin(1, 1));
    assert(!position::begin(address(context), 0));
    assert(!position::begin(0, 1));
    assert(spy.events.empty());

    // Inline and heap values have no retained Variant/payload lifetime. A guard
    // around the invocation candidate also verifies its fixed scratch extent.
    for (const bool heap : {false, true}) {
        reset(context);
        const auto token = position::begin(address(context), 1); assert(token);
        struct Guarded { uint64_t before = 0x12345678abcdef01; position::Candidate value;
                         uint64_t after = 0xfedcba0123456789; } guarded;
        const Vector target{100.25f, 200.5f, 300};
        {
            Variant source(target);
            auto storage = std::make_unique<Vector>(target);
            if (heap) {
                source.type = vectorType;
                const void* pointer = storage->data();
                std::memcpy(source.payload, &pointer, sizeof(pointer));
            }
            assert(position::prepare(address(context), 1, &source, &guarded.value));
            source = Variant({0, 0, 0});
        }
        assert(spy.events == "V"); // No sequence before original returned false.
        auto replay = guarded.value;
        assert(position::finish(&guarded.value, false));
        assert(spy.events == "VVGVIWCD" && spy.written == target);
        assert(!position::finish(&guarded.value, false));
        assert(!position::finish(&replay, false));
        assert(!position::prepare(address(context), 1, reinterpret_cast<void*>(1), &candidate));
        assert(guarded.before == 0x12345678abcdef01 && guarded.after == 0xfedcba0123456789);
        assert(position::end(address(context), 1, token));
        assert(!position::end(address(context), 1, token));
    }

    reset(context);
    auto token = position::begin(address(context), 1);
    candidate = prepare(context);
    assert(!position::finish(&candidate, true)); // Never duplicate original success.
    assert(spy.events == "V");
    assert(position::end(address(context), 1, token));

    // Invalid payloads consume the one eligible attempt and issue no native call.
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    for (const Vector target : {Vector{nan, 0, 0}, Vector{0, inf, 0}, Vector{0, 0, -inf},
                               Vector{1000001, 0, 0}, Vector{0, -1000001, 0}}) {
        reset(context); token = position::begin(address(context), 1);
        const Variant invalid(target);
        assert(!position::prepare(address(context), 1, &invalid, &candidate));
        const Variant good({100, 200, 300});
        assert(!position::prepare(address(context), 1, &good, &candidate));
        assert(spy.events.empty());
        assert(position::end(address(context), 1, token));
    }
    for (int invalid = 0; invalid < 4; ++invalid) {
        reset(context); token = position::begin(address(context), 1);
        Variant source({100, 200, 300});
        if (invalid == 0) source.type = (vectorType + 8) | 1;
        if (invalid == 1) source.type = 0;
        if (invalid == 2) { source.type = vectorType; std::memset(source.payload, 0, 16); }
        assert(!position::prepare(address(context), 1, invalid == 3 ? nullptr : &source, &candidate));
        assert(!position::finish(&candidate, false));
        assert(spy.events.empty());
        assert(position::end(address(context), 1, token));
    }
    reset(context); token = position::begin(address(context), 1);
    assert(!position::prepare(address(context) + 8, 1, reinterpret_cast<void*>(1), &candidate));
    assert(!position::prepare(address(context), 32, reinterpret_cast<void*>(1), &candidate));
    candidate = prepare(context); assert(position::finish(&candidate, false));
    assert(position::end(address(context), 1, token));

    // Fresh physics position, all three axes and Euclidean distance are checked
    // independently of script input. One meter is accepted, a diagonal >1 is not.
    for (const Vector delta : {Vector{1, 0, 0}, Vector{0, -1, 0}, Vector{0, 0, 1},
                              Vector{0.8f, 0.8f, 0}, Vector{0, 0, 1.01f}}) {
        reset(context); token = position::begin(address(context), 1);
        Vector target = spy.current;
        for (unsigned axis = 0; axis < 3; ++axis) target[axis] += delta[axis];
        candidate = prepare(context, target);
        const bool allowed = delta == Vector{1, 0, 0} || delta == Vector{0, -1, 0} || delta == Vector{0, 0, 1};
        assert(position::finish(&candidate, false) == allowed);
        assert((spy.events.find('I') != std::string::npos) == allowed);
        assert(position::end(address(context), 1, token));
    }
    reset(context); token = position::begin(address(context), 1);
    spy.current = {1000000, -1000000, 0};
    candidate = prepare(context, spy.current); assert(position::finish(&candidate, false));
    assert(position::end(address(context), 1, token));
    for (int failure = 0; failure < 9; ++failure) {
        reset(context); token = position::begin(address(context), 1);
        if (failure == 0) spy.invalidOn = 1;
        if (failure == 0) {
            const Variant source({100, 200, 300});
            assert(!position::prepare(address(context), 1, &source, &candidate));
        } else {
            candidate = prepare(context);
            if (failure == 1) context.handle++;
            if (failure == 2) spy.invalidOn = 2;
            if (failure == 3) spy.invalidOn = 3;
            if (failure == 4) spy.changeHandle = true;
            if (failure == 5) spy.current[0] = nan;
            if (failure == 6) spy.current[2] = 1000001;
            if (failure == 7) spy.noGetterWrite = true;
            if (failure == 8) spy.partialGetterWrite = true;
        }
        assert(!position::finish(&candidate, false));
        assert(spy.events.find('I') == std::string::npos);
        assert(position::end(address(context), 1, token));
    }

    // Nested writers poison the outer candidate. Their token0 End cannot revive
    // it; mismatched/stale End also cannot clear a newer exact writer scope.
    reset(context); token = position::begin(address(context), 1);
    candidate = prepare(context);
    Context other;
    assert(!position::begin(address(other), 2));
    assert(!position::end(address(other), 2, 0));
    assert(!position::finish(&candidate, false)); assert(spy.events == "V");
    assert(position::end(address(context), 1, token));
    reset(context); token = position::begin(address(context), 1);
    auto stale = prepare(context);
    assert(position::end(address(context), 1, token));
    const auto fresh = position::begin(address(context), 1); assert(fresh != token);
    candidate = prepare(context);
    assert(!position::end(address(context), 1, token));
    assert(!position::finish(&stale, false));
    assert(position::finish(&candidate, false));
    assert(position::end(address(context), 1, fresh));
    for (const char event : {'V', 'G', 'I', 'W'}) {
        reset(context); token = position::begin(address(context), 1);
        spy.poisonAt = event;
        const Variant source({100, 200, 300});
        const bool prepared = position::prepare(address(context), 1, &source, &candidate);
        assert(prepared == (event != 'V'));
        assert(!position::finish(&candidate, false));
        assert(spy.events.find('C') == std::string::npos);
        assert((spy.events.find('D') != std::string::npos) == (event == 'I' || event == 'W'));
        assert(position::end(address(context), 1, token));
    }
    for (bool failInit : {true, false}) {
        reset(context); token = position::begin(address(context), 1);
        spy.failInit = failInit; spy.failWrite = !failInit;
        candidate = prepare(context); assert(!position::finish(&candidate, false));
        assert(spy.events == (failInit ? "VVGVID" : "VVGVIWD"));
        assert(position::end(address(context), 1, token));
    }

    position::Candidate foreign;
    std::thread producer([&] {
        Context owner; reset(owner);
        const auto scope = position::begin(address(owner), 1);
        foreign = prepare(owner);
        assert(position::end(address(owner), 1, scope));
    }); producer.join();
    reset(context); token = position::begin(address(context), 1);
    candidate = prepare(context);
    assert(!position::finish(&foreign, false));
    assert(position::finish(&candidate, false));
    assert(position::end(address(context), 1, token));
    std::vector<std::thread> threads;
    for (unsigned index = 0; index < 8; ++index) threads.emplace_back([index] {
        Context owner;
        for (unsigned i = 0; i < 200; ++i) {
            reset(owner); spy.current[0] += float(index);
            const auto scope = position::begin(address(owner), 1); assert(scope);
            auto target = spy.current; target[2] += .25f;
            auto invocation = prepare(owner, target);
            assert(position::finish(&invocation, false));
            assert(spy.events == "VVGVIWCD" && spy.written == target);
            assert(position::end(address(owner), 1, scope));
        }
    });
    for (auto& thread : threads) thread.join();

    // Explicit boundary injection tests counter overflow without billions of
    // calls. No production reset/testing hook is added to the public API.
    std::thread overflow([] {
        Context owner; reset(owner);
        position::detail::threadState().nextToken = std::numeric_limits<uint32_t>::max();
        const auto scope = position::begin(address(owner), 1); assert(scope == UINT32_MAX);
        assert(position::end(address(owner), 1, scope));
        assert(!position::begin(address(owner), 1));
    }); overflow.join();
    position::detail::nextThreadId.store(std::numeric_limits<uint64_t>::max());
    std::thread identityOverflow([] {
        Context owner; reset(owner);
        assert(!position::begin(address(owner), 1));
    }); identityOverflow.join();
    assert(position::detail::nextThreadId.load() == std::numeric_limits<uint64_t>::max());
    std::puts("Flight position: immutable ABI, finite bounded targets, scoped handle validation, fresh physics distance, single sequence, cleanup, nested poisoning, stale/replay/overflow rejection and eight-thread isolation passed");
}
