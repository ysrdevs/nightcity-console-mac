#include "../overlay/exploration_input.h"
#include <cassert>
#include <thread>
#include <vector>
#include <cstdio>
int main() {
    using Input = nightcity::ExplorationInput;
    Input input;
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
    std::vector<std::thread> threads;
    for (int i=0; i<4; ++i) threads.emplace_back([&] {
        for (int n=0; n<10000; ++n) {
            input.key(Input::forward, true);
            const auto snapshot = input.snapshot();
            assert((snapshot & Input::ready) != 0);
            assert((snapshot & Input::blocked) == 0 || (snapshot & 255) == 0);
            input.key(Input::forward, false);
        }
    });
    for (int n=0; n<10000; ++n) { input.setBlocked(true); input.setBlocked(false); }
    for (auto& thread : threads) thread.join();
    input.setBlocked(true);
    assert(input.snapshot() == (Input::ready | Input::blocked));
    std::puts("Exploration input: focus/overlay clearing and concurrent snapshots passed");
}
