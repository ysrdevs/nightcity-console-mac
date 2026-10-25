#pragma once
#include <atomic>
#include <cstdint>

namespace nightcity {
// One coherent snapshot, written by AppKit and read by the game simulation.
// Blocking clears held keys; returning to the app requires fresh key presses.
class ExplorationInput {
public:
    static constexpr uint32_t forward = 1, back = 2, left = 4, right = 8;
    static constexpr uint32_t up = 16, down = 32, boost = 64, precision = 128;
    static constexpr uint32_t blocked = 256, ready = 512;
    void setBlocked(bool value) noexcept {
        state_.store(value ? blocked : 0, std::memory_order_release);
    }
    void key(uint32_t mask, bool pressed) noexcept {
        mask &= 255;
        auto current = state_.load(std::memory_order_acquire);
        do {
            if (current & blocked) return;
        } while (!state_.compare_exchange_weak(current, pressed ? current | mask : current & ~mask,
                                               std::memory_order_acq_rel, std::memory_order_acquire));
    }
    uint32_t snapshot() const noexcept { return state_.load(std::memory_order_acquire) | ready; }
private:
    std::atomic<uint32_t> state_{blocked};
};
}
