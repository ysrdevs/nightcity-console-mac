#include "../overlay/exploration_input.h"
#include <cassert>
#include <thread>
#include <vector>
#include <cstdio>

using Input = nightcity::ExplorationInput;
static uint32_t epoch(const Input& input) {
    return (input.snapshot() & Input::epochMask) >> Input::epochShift;
}
static void checkInvariant(uint32_t snapshot) {
    assert(snapshot & Input::ready);
    assert((snapshot & Input::blocked) == 0 || (snapshot & 255) == 0);
    assert((snapshot & (Input::appInactive | Input::exhausted)) == 0 || (snapshot & Input::blocked));
    assert((snapshot & ((1u << 13) | (1u << 14))) == 0);
}

int main() {
    Input input;
    // All zero/default settings preserve the original low-bit packet contract.
    assert(input.snapshot() == (Input::ready | Input::blocked));
    input.key(Input::forward, true);
    assert(input.snapshot() == (Input::ready | Input::blocked));
    input.setBlocked(false);
    input.key(Input::forward | Input::up, true);
    assert(input.snapshot() == (Input::ready | Input::forward | Input::up));
    input.key(Input::forward, false);
    assert(input.snapshot() == (Input::ready | Input::up));
    input.setBlocked(true);
    input.key(Input::up, false);
    input.setBlocked(false);
    assert(input.snapshot() == Input::ready);

    input.key(Input::forward | Input::boost, true);
    const auto held = input.snapshot();
    for (uint32_t preset = 0; preset < 4; ++preset) {
        assert(input.setPreset(preset));
        assert(input.preset() == preset);
        assert((input.snapshot() & ~Input::presetMask) == held);
    }
    const auto beforeInvalid = input.snapshot();
    assert(!input.setPreset(4) && !input.setPreset(UINT32_MAX));
    assert(input.snapshot() == beforeInvalid);
    input.setBlocked(true); // F1 opening clears keys, never advances cancellation.
    assert(input.preset() == 3 && epoch(input) == 0);
    input.setBlocked(false);
    assert(input.snapshot() == (Input::ready | (3u << Input::presetShift)));

    input.key(Input::forward | Input::up, true);
    input.blockAndCancel();
    assert(input.snapshot() == (Input::ready | Input::blocked | Input::appInactive |
                               (3u << Input::presetShift) | (1u << Input::epochShift)));
    input.setBlocked(false); // F1/unrelated unblock cannot bypass app inactivity.
    input.key(Input::forward, true);
    assert(input.snapshot() & Input::blocked);
    assert((input.snapshot() & 255) == 0);
    input.focusGained(false);
    assert(input.snapshot() == (Input::ready | (3u << Input::presetShift) | (1u << Input::epochShift)));
    const auto lossThenRegain = input.snapshot();
    for (int read = 0; read < 100; ++read) assert(input.snapshot() == lossThenRegain);
    input.blockAndCancel();
    input.focusGained(true); // Returning while F1 is open remains blocked.
    assert(epoch(input) == 2 && input.preset() == 3);
    assert((input.snapshot() & Input::appInactive) == 0 && (input.snapshot() & Input::blocked));
    input.setBlocked(false);
    input.key(UINT32_MAX, true); // Public key API can modify held-key bits only.
    assert(epoch(input) == 2 && input.preset() == 3 && (input.snapshot() & 255) == 255);
    input.key(UINT32_MAX, false);

    // Simultaneous settings, key and focus writers must preserve a coherent
    // blocked packet and every focus-loss epoch. Reads do not consume intent.
    std::vector<std::thread> threads;
    for (int i=0; i<4; ++i) threads.emplace_back([&] {
        for (int n=0; n<10000; ++n) {
            input.key(Input::forward, true);
            const auto snapshot = input.snapshot();
            checkInvariant(snapshot);
            input.key(Input::forward, false);
        }
    });
    threads.emplace_back([&] {
        for (uint32_t n = 0; n < 10000; ++n) {
            assert(input.setPreset(n % 4));
            checkInvariant(input.snapshot());
        }
    });
    for (int n=0; n<10000; ++n) {
        input.blockAndCancel();
        checkInvariant(input.snapshot());
        input.focusGained(false);
        input.setBlocked(true);
        input.setBlocked(false);
    }
    for (auto& thread : threads) thread.join();
    input.setBlocked(true);
    assert(epoch(input) == 10002 && input.preset() == 3);
    assert(input.snapshot() == (Input::ready | Input::blocked | (3u << Input::presetShift) |
                               (10002u << Input::epochShift)));

    // Exercise the real counter boundary. Never wrap to an old epoch: once
    // exhausted, regain/F1/settings/keys cannot make the packet usable again.
    Input saturated;
    for (uint32_t loss = 1; loss <= 0xffffu; ++loss) {
        saturated.blockAndCancel(); saturated.focusGained(false);
        assert(epoch(saturated) == loss);
        assert(!(saturated.snapshot() & Input::exhausted));
    }
    saturated.key(Input::forward, true);
    saturated.blockAndCancel();
    assert(epoch(saturated) == 0xffffu && (saturated.snapshot() & Input::exhausted));
    saturated.focusGained(false); saturated.setBlocked(false);
    assert(saturated.setPreset(2)); saturated.key(UINT32_MAX, true);
    saturated.blockAndCancel(); saturated.focusGained(false);
    assert(saturated.snapshot() == (Input::ready | Input::blocked | Input::exhausted |
                                   Input::epochMask | (2u << Input::presetShift)));
    std::puts("Exploration input: compatible defaults, masked speed settings, focus-loss retention, F1 clearing, saturation and concurrent snapshots passed");
}
