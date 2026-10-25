# Exploration prototype for 1.8

This is an experimental, local test checkpoint based on released 1.7.1. It is not a completed noclip feature or a release build. The launcher does not install this script automatically; it is staged explicitly into `r6/scripts/NightCityExploration/` in an isolated game copy. The existing native framework payload is unchanged.

The **Exploration** tab sends `flight toggle`, `flight return` and `flight status`. Activation requires game 2.5, an authoritative player lookup, matching script signatures and a successful native input round trip. The default script input result refuses activation when the bridge is unavailable.

While active, the script uses the locomotion update context, camera-relative movement, the current state's collision filter and zero velocity. Held keys come from one atomic native snapshot. Movement does not cross into JavaScript, read command files or write logs every frame. Opening F1 or losing application focus clears held input. Unsupported player states stop the probe. Normal stops restore the captured filter and return to the activation point; a 30-second simulation-time limit does the same. Flight state is transient and is discarded on player detach.

Controls: WASD to move, Space to rise, Control to descend, Shift to boost and Option for precision. Start on clear ground, close F1 to move, and do not save while the probe is active.

## Validation at this checkpoint

- Native executor fixtures cover exact function matching, four-byte result writes, nested and concurrent calls, observer coexistence and a missing overlay export.
- Command fixtures cover version and signature checks, current-player context, failed round-trip cleanup and the command return buffer.
- Input fixtures cover coherent snapshots, blocked input and clearing held keys.
- The combined script set compiles with VA, Equipment-EX, Cyberware-EX and the existing plugin scripts.
- The overlay output reader now runs on a worker with a bounded 128 KiB tail and 400 lines. The render path only consumes completed snapshots; clear operations invalidate older pending output. Sanitizer fixtures cover partial lines, replacement, truncation, special files and concurrent reads.

These checks do not prove collision passage, stable hovering, safe restoration in the real engine or an FPS improvement. The first gameplay gate must check movement through geometry, camera behavior during locomotion transitions, return to start and normal movement afterward. Then repeat the established Creator, VA purchase, outfit switching, dual OS and save/relaunch checks.

Before production use, complete player lifecycle and menu/transition testing, explicit safe exit behavior, configurable controls and speed, persistent places and performance comparisons. Manual diagnostic commands currently return script Strings using the existing runtime convention; add explicit native String ownership handling or replace these with primitive results before frequent polling. Do not turn this status command into a frame loop.

## Focused checks

```sh
node --check runtime/red4ext_hooks.js
node tests/runtime-flight-commands.mjs
node tests/runtime-native-fallback.mjs
node tests/runtime-diagnostics.mjs
node tests/creator-transaction.mjs
node tests/creator-catalog.mjs
bash tools/test-output-snapshot.sh
clang++ -std=c++17 -O2 -pthread tests/exploration-input.cpp -o /tmp/nightcity-exploration-input-test
/tmp/nightcity-exploration-input-test
```

The native executor fixture in `tests/runtime-native-gates.py` additionally requires its documented local Frida host setup. Compile all installed redscripts into the separate modded cache before launching. Keep the original game copy, vanilla script cache, existing mod hashes and Creator name map intact.
