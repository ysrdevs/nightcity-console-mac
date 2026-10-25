#include "../overlay/frame_cadence.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <future>
#include <iostream>
#include <thread>
#include <vector>

using nightcity::CadenceResult;
using nightcity::CadenceWindow;
using nightcity::FrameCadence;

static void uniform(const CadenceWindow& window, double milliseconds) {
    for (double value : window.intervals) assert(std::abs(value - milliseconds) < 1e-8);
}

static CadenceWindow complete(FrameCadence& recorder, uintptr_t layer, double& time) {
    CadenceWindow window, last;
    bool ready = false;
    for (int i = 0; i < 121; ++i) {
        time += 0.01;
        if (recorder.tick(layer, false, [&] { return time; }, window) == CadenceResult::ready) {
            last = window;
            ready = true;
        }
    }
    assert(ready);
    return last;
}

int main() {
    // Rendering migrates across eight real threads. Every accepted acquisition must
    // contribute to one layer's stream, not eight sparse worker-specific intervals.
    {
        FrameCadence recorder;
        std::vector<std::thread> workers;
        std::vector<CadenceWindow> completed;
        std::mutex completedMutex;
        uint64_t tick = 0; // safe only if the supplied clock runs under recorder's lock
        for (int worker = 0; worker < 8; ++worker) workers.emplace_back([&] {
            for (int accepted = 0; accepted < 61;) {
                CadenceWindow window;
                auto result = recorder.tick(1, false, [&] { return (++tick) / 60.0; }, window);
                if (result == CadenceResult::dropped) { std::this_thread::yield(); continue; }
                ++accepted;
                if (result == CadenceResult::ready) {
                    std::lock_guard<std::mutex> guard(completedMutex);
                    completed.push_back(window);
                }
            }
        });
        for (auto& worker : workers) worker.join();
        assert(tick == 488 && completed.size() == 4);
        std::sort(completed.begin(), completed.end(), [](const auto& a, const auto& b) { return a.frames < b.frames; });
        for (size_t i = 0; i < completed.size(); ++i) {
            assert(completed[i].frames == 121 + i * 120 && completed[i].layerID == 1);
            assert(completed[i].trackedLayers == 1);
            uniform(completed[i], 1000.0 / 60.0);
        }
    }
    // Interleave independent 60Hz and 30Hz layers without combining their timestamps.
    {
        FrameCadence recorder;
        std::vector<CadenceWindow> completed;
        for (int frame = 0; frame <= 240; ++frame) {
            const double time = frame / 60.0;
            CadenceWindow window;
            if (recorder.tick(10, false, [&] { return time; }, window) == CadenceResult::ready) completed.push_back(window);
            if (frame % 2 == 0 && recorder.tick(20, false, [&] { return time; }, window) == CadenceResult::ready) completed.push_back(window);
        }
        assert(completed.size() == 3);
        for (const auto& window : completed) uniform(window, window.layerID == 1 ? 1000.0 / 60.0 : 1000.0 / 30.0);
        const auto saved = completed.front();
        double later = 5.0;
        complete(recorder, 10, later);
        uniform(saved, 1000.0 / 60.0); // later 100Hz samples cannot change the emitted snapshot
    }
    // A long pause resets a partial window; a real stutter of exactly 5s remains visible.
    {
        FrameCadence recorder;
        CadenceWindow window;
        for (int i = 0; i <= 60; ++i) recorder.tick(1, false, [&] { return i / 60.0; }, window);
        recorder.tick(1, false, [] { return 7.0; }, window);
        for (int i = 1; i <= 120; ++i) recorder.tick(1, false, [&] { return 7.0 + i / 60.0; }, window);
        assert(window.idleResets == 1);
        uniform(window, 1000.0 / 60.0);
        FrameCadence stutter;
        stutter.tick(1, false, [] { return 0.0; }, window);
        stutter.tick(1, false, [] { return 5.0; }, window);
        for (int i = 1; i <= 119; ++i) stutter.tick(1, false, [&] { return 5.0 + i / 60.0; }, window);
        assert(window.idleResets == 0 && *std::max_element(window.intervals.begin(), window.intervals.end()) == 5000.0);
    }
    // Visibility changes must not mix console-open and console-closed measurements.
    {
        FrameCadence recorder;
        CadenceWindow window;
        for (int i = 0; i <= 60; ++i) recorder.tick(1, false, [&] { return i / 60.0; }, window);
        recorder.tick(1, true, [] { return 1.1; }, window);
        for (int i = 1; i <= 120; ++i) recorder.tick(1, true, [&] { return 1.1 + i / 60.0; }, window);
        assert(window.consoleOpen && window.visibilityResets == 1);
        uniform(window, 1000.0 / 60.0);
    }
    // A fifth layer evicts the least recently used stream; opaque IDs are not reused.
    {
        FrameCadence recorder;
        CadenceWindow window;
        for (uintptr_t layer = 1; layer <= 4; ++layer) recorder.tick(layer, false, [&] { return double(layer - 1); }, window);
        recorder.tick(1, false, [] { return 4.0; }, window);
        double time = 4.0;
        auto fifth = complete(recorder, 5, time);
        auto first = complete(recorder, 1, time);
        auto second = complete(recorder, 2, time);
        assert(fifth.layerID == 5 && first.layerID == 1 && second.layerID == 6);
        assert(fifth.trackedLayers == 4 && first.trackedLayers == 4 && second.trackedLayers == 4);
    }
    // Forced contention returns before the owner releases its lock and never reads
    // the clock out of order. The dropped observation is reported in the next window.
    {
        FrameCadence recorder;
        std::promise<void> entered, release;
        auto enteredFuture = entered.get_future();
        auto released = release.get_future().share();
        std::thread owner([&] {
            CadenceWindow window;
            recorder.tick(1, false, [&] { entered.set_value(); released.wait(); return 0.0; }, window);
        });
        enteredFuture.wait();
        bool clockCalled = false;
        CadenceWindow window;
        auto result = recorder.tick(2, false, [&] { clockCalled = true; return 1.0; }, window);
        assert(result == CadenceResult::dropped && !clockCalled);
        release.set_value();
        owner.join();
        for (int i = 1; i <= 120; ++i) recorder.tick(1, false, [&] { return i / 60.0; }, window);
        assert(window.droppedSamples == 1 && window.trackedLayers == 1);
    }
    std::cout << "PASS shared-worker cadence, separate layers, pauses, visibility, LRU, contention and snapshot ownership\n";
}
