#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace nightcity {

enum class CadenceResult { dropped, recorded, ready };

struct CadenceWindow {
    std::array<double, 120> intervals{};
    uint64_t layerID = 0;
    uint64_t frames = 0;
    uint64_t droppedSamples = 0;
    uint64_t idleResets = 0;
    uint64_t visibilityResets = 0;
    size_t trackedLayers = 0;
    double elapsed = 0.0;
    bool consoleOpen = false;
};

// One acquisition stream per Metal layer, even when work migrates between engine workers.
// The caller supplies a monotonic clock; it is read only after the nonblocking lock succeeds.
// This class owns no Metal objects. Four LRU slots bound memory and discard inactive streams.
class FrameCadence {
public:
    static constexpr size_t layerCapacity = 4;
    static constexpr double idleSeconds = 5.0;

    template<class Clock>
    CadenceResult tick(uintptr_t identity, bool consoleOpen, Clock clock, CadenceWindow& output) {
        std::unique_lock<std::mutex> guard(mutex_, std::try_to_lock);
        if (!guard.owns_lock()) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return CadenceResult::dropped;
        }
        const double now = clock();
        Layer* layer = nullptr;
        Layer* available = nullptr;
        Layer* oldest = &layers_[0];
        size_t active = 0;
        for (auto& candidate : layers_) {
            if (candidate.id) {
                ++active;
                if (candidate.identity == identity) layer = &candidate;
                if (candidate.last < oldest->last) oldest = &candidate;
            } else if (!available) {
                available = &candidate;
            }
        }
        if (!layer) {
            layer = available ? available : oldest;
            *layer = Layer{};
            layer->identity = identity;
            layer->id = nextID_++;
            layer->started = now;
            if (available) ++active;
        }

        if (layer->frames > 0) {
            const double interval = now - layer->last;
            const bool idle = interval > idleSeconds;
            const bool visibilityChanged = consoleOpen != layer->consoleOpen;
            if (idle || visibilityChanged) {
                layer->count = 0;
                if (idle) ++layer->idleResets;
                if (visibilityChanged) ++layer->visibilityResets;
            } else {
                layer->intervals[layer->count++] = interval * 1000.0;
            }
        }
        layer->last = now;
        layer->consoleOpen = consoleOpen;
        ++layer->frames;
        if (layer->count < layer->intervals.size()) return CadenceResult::recorded;

        output.intervals = layer->intervals;
        output.layerID = layer->id;
        output.frames = layer->frames;
        output.droppedSamples = dropped_.load(std::memory_order_relaxed);
        output.idleResets = layer->idleResets;
        output.visibilityResets = layer->visibilityResets;
        output.trackedLayers = active;
        output.elapsed = now - layer->started;
        output.consoleOpen = consoleOpen;
        layer->count = 0;
        return CadenceResult::ready;
    }

private:
    struct Layer {
        std::array<double, 120> intervals{};
        uintptr_t identity = 0;
        uint64_t id = 0;
        uint64_t frames = 0;
        uint64_t idleResets = 0;
        uint64_t visibilityResets = 0;
        double started = 0.0;
        double last = 0.0;
        size_t count = 0;
        bool consoleOpen = false;
    };
    std::array<Layer, layerCapacity> layers_{};
    std::mutex mutex_;
    std::atomic<uint64_t> dropped_{0};
    uint64_t nextID_ = 1;
};

} // namespace nightcity
