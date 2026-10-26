#pragma once
#include <atomic>
#include <cstdint>

namespace nightcity {
// One coherent snapshot, shared by AppKit, the settings UI and game simulation.
// Reads never consume focus-loss intent. Blocking clears held keys only; focus
// loss also advances a persistent epoch, even if focus returns before a read.
class ExplorationInput {
public:
    static constexpr uint32_t forward = 1, back = 2, left = 4, right = 8;
    static constexpr uint32_t up = 16, down = 32, boost = 64, precision = 128;
    static constexpr uint32_t blocked = 256, ready = 512;
    static constexpr uint32_t presetShift = 10, presetMask = 3u << presetShift;
    static constexpr uint32_t appInactive = 1u << 12, exhausted = 1u << 15;
    static constexpr uint32_t epochShift = 16, epochMask = 0xffff0000u;

    void setBlocked(bool value) noexcept {
        auto current = state_.load(std::memory_order_acquire);
        uint32_t next;
        do {
            next = current & ~(uint32_t{255} | blocked);
            if (value || (current & (appInactive | exhausted))) next |= blocked;
        } while (!state_.compare_exchange_weak(current, next, std::memory_order_acq_rel,
                                               std::memory_order_acquire));
    }

    // Preset0 keeps the accepted 4m/s default. The other presets are 2/6/8m/s;
    // Shift12 and Option0.75 remain script constants. Invalid settings do nothing.
    bool setPreset(uint32_t preset) noexcept {
        if (preset > 3) return false;
        auto current = state_.load(std::memory_order_acquire);
        uint32_t next;
        do {
            next = (current & ~presetMask) | (preset << presetShift);
        } while (!state_.compare_exchange_weak(current, next, std::memory_order_acq_rel,
                                               std::memory_order_acquire));
        return true;
    }
    uint32_t preset() const noexcept {
        return (state_.load(std::memory_order_acquire) & presetMask) >> presetShift;
    }

    void blockAndCancel() noexcept {
        auto current = state_.load(std::memory_order_acquire);
        uint32_t next;
        do {
            const uint32_t epoch = (current & epochMask) >> epochShift;
            next = (current & ~(uint32_t{255} | epochMask)) | blocked | appInactive;
            if (epoch == 0xffffu) next |= epochMask | exhausted;
            else next |= (epoch + 1u) << epochShift;
        } while (!state_.compare_exchange_weak(current, next, std::memory_order_acq_rel,
                                               std::memory_order_acquire));
    }

    void focusGained(bool overlayShown) noexcept {
        auto current = state_.load(std::memory_order_acquire);
        uint32_t next;
        do {
            next = current & ~(uint32_t{255} | blocked | appInactive);
            if (overlayShown || (current & exhausted)) next |= blocked;
        } while (!state_.compare_exchange_weak(current, next, std::memory_order_acq_rel,
                                               std::memory_order_acquire));
    }
    void key(uint32_t mask, bool pressed) noexcept {
        mask &= 255;
        auto current = state_.load(std::memory_order_acquire);
        do {
            if (current & (blocked | appInactive | exhausted)) return;
        } while (!state_.compare_exchange_weak(current, pressed ? current | mask : current & ~mask,
                                               std::memory_order_acq_rel, std::memory_order_acquire));
    }
    uint32_t snapshot() const noexcept { return state_.load(std::memory_order_acquire) | ready; }
private:
    std::atomic<uint32_t> state_{blocked};
};
}
