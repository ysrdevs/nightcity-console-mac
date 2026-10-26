# Exploration prototype for 1.8

This is an experimental, local test checkpoint based on released 1.7.1. It is not a completed noclip feature or a release build. The launcher does not install this script automatically; it is staged explicitly into `r6/scripts/NightCityExploration/` in an isolated game copy. The existing native framework payload is unchanged.

The **Exploration** tab sends `flight validate`, `flight camera`, `flight toggle`, `flight return` and `flight status`. Requests require game 2.5, an authoritative player lookup, matching script signatures and an available native input snapshot. Activation separately requires the script to receive the native READY bit on its next engine movement update, before it changes collision or position. The default script input result refuses activation when the bridge is unavailable.

The command runs inside the executor hook's return callback. Frida suppresses recursive invocation of that same listener, so calling the input script method there returns its blocked default rather than proving the bridge. The native fixture reproduces this case. Commands now read only the overlay's atomic snapshot; the engine update performs the actual script input check. Status reports the last script input packet and check count for that live validation.

The second prototype crashed in the native collision setter while copying a null Variant payload. Two empty type names could pass its earlier equality check. The native 2.5 `GetStateVectorParameter` implementation does not support reading `SimulationFilter`; its case returns an empty Variant. All owned physics writes now require a defined Variant with the exact expected native type. Filter and velocity values are materialized in typed locals before conversion. Do not reuse the unsupported getter as a restoration source.

The restoration source is a copy of a filter the engine successfully applies. The installed compiler does not support wrapping this native setter in redscript, so a native listener captures it only within a bounded scope around the original scripted collision-setting method. A shared native thread-local stack associates each scope with its interface and executor depth, copies the verified 16-byte filter payload, and consumes it into an initially empty owned Variant. Failed captures invalidate the script's older same-interface capture. Native suppression brackets the exact flight-owned filter writer, including nested calls, so its writes cannot overwrite an outer capture scope. No preset is substituted for an unknown current filter.

Setup checks the capture and owned-writer script signatures, the exact native filter and Variant sizes and alignments, the reflected enum value, and the 2.5 setter's instruction fingerprint. Native fixtures cover inline and heap inputs, source lifetime, output boundaries, rejected/failed calls, nested scopes, stale scopes, overflow, and concurrent threads. The actual Frida integration fixture verifies shared native state, argument/return preservation, and exclusion of owned writes while an outer scope remains active. Its negative control reproduces baseline corruption when the owned-writer binding is incorrect.

`flight validate` first configures native capture, then queues a read-only check on the locomotion update. After that first call, crouch and stand normally to give the original state logic a chance to apply its filter, then validate and check status again. The report includes input readiness, capture validity, current-interface matching and Variant types, without probe physics writes or teleports. The capture-only build passed this live check: two normal filter captures, a valid current interface and input READY, with no probe physics writes. The user subsequently confirmed flight including upward movement, passing through a solid barrier, and automatic return to the activation point. A same-session status reported the filter restored with flight inactive and no pending transition. Ordinary collision at the barrier after return and manual return still need explicit confirmation.

While active, the script uses the locomotion update context, camera-relative movement, the current state's collision filter and zero velocity. Held keys come from one atomic native snapshot. Movement does not cross into JavaScript, read command files or write logs every frame. Opening F1 or losing application focus clears held input. Unsupported player states stop the probe. Normal stops restore the captured filter and return to the activation point; a 10-second simulation-time limit does the same. Unexpected interface changes or failed fresh captures stop the probe without writing the old baseline through a new context. Flight state is transient and is discarded on player detach.

Controls: WASD to move, Space to rise, Control to descend, Shift to boost and Alt (Option on an Apple keyboard) for precision. Start on clear ground, close F1 to move, and do not save while the probe is active.

The movement test exposed a horizontal camera lock while vertical look remained available. With F1 closed the overlay forwards both mouse axes unchanged. Using current camera world yaw for the active teleport and transition resume did not resolve it in the next live test. The subsequent recordings confirmed horizontal input in both normal movement and flight, but almost no camera yaw response during flight. Rotation did not change inside either sampled callback interval, so these recordings locate the lost response outside that interval without proving which engine operation causes it. Activation snapshots also showed matching physics and entity positions to the printed millimetre precision.

The temporary **Record camera input** diagnostic compares a short normal-look baseline with the next flight. It samples input and rotation around the original locomotion update and flight update, so the report can also compare a later frame with the previous frame's result. Collection is bounded and emits no per-frame text or file output; **Check flight status** retrieves the report manually. It also records a guarded physics-position versus player-position comparison.

The current private build replaces only the active per-frame teleport with a guarded native position-only write. It leaves facing direction to the engine. The original 2.5 state setter rejects Position; the supplemental bridge can run only within the exact `StateGameScriptInterface.NCCFlightWritePosition` method, after the original setter returns false. Setup verifies the method signature, Vector3 layout, enum value and six native helper instruction fingerprints. The raw position getter uses a verified hidden x8 output adapter, not a float-vector return convention. No framework plugin is modified.

Each native write copies a finite Vector3, validates the current physics handle and permits at most one attempt within that invocation. Its target must be within one metre of the current physics position. Nested writer scopes, stale candidates, changed handles and incompatible setup fail closed. The script separately bounds frame time, movement steps, activation-origin agreement, origin divergence and distance from the starting point. A refused write uses the existing restoration and return path, without falling back to per-frame teleport. Status distinguishes issued writes from subsequent readbacks; a readback within one metre is a proximity check, not proof of movement or exact arrival. One-shot return and locomotion-transition resume still use the existing teleports.

The user confirmed horizontal and vertical camera look with this position-only build. Its latest live status recorded 444 issued position writes and 444 subsequent proximity readbacks, zero refusals, and completion of the 10-second return with the filter restored. Flight was inactive with no pending transition. The final readback distance was 0.0206m and final physics/entity origin divergence was zero; these are final samples, not maxima. All 106 framework hooks were installed and the fault log contained only initialization. Barrier passage, ordinary collision after return, explicit no-drift behavior and early manual return still need acceptance for this movement implementation.

## Validation at this checkpoint

- Native executor fixtures cover exact function matching, four-byte result writes, nested and concurrent calls, observer coexistence and a missing overlay export.
- Command fixtures cover version and signature checks, current-player context, native snapshot failure cleanup and the command return buffer. They forbid trying the scripted input round trip inside a command callback.
- Input fixtures cover coherent snapshots, blocked input and clearing held keys.
- Position fixtures cover exact method and context scope, the raw x8 getter convention and output boundaries, original arguments and results, single-use native writes, finite and distance bounds, helper failures, nested calls and concurrent threads. An intentionally incorrect writer binding refuses all supplemental writes.
- The combined script set compiles with VA, Equipment-EX, Cyberware-EX and the existing plugin scripts.
- The overlay output reader now runs on a worker with a bounded 128 KiB tail and 400 lines. The render path only consumes completed snapshots; clear operations invalidate older pending output. Sanitizer fixtures cover partial lines, replacement, truncation, special files and concurrent reads.

Static and native fixture checks do not establish gameplay behavior or an FPS improvement. The user has confirmed the narrow movement/barrier/automatic-return flows above; camera behavior during locomotion transitions, normal collision afterward, and early manual return still need acceptance. Then repeat the established Creator, VA purchase, outfit switching, dual OS and save/relaunch checks.

Before production use, complete player lifecycle and menu/transition testing, explicit safe exit behavior, configurable controls and speed, persistent places and performance comparisons. Manual diagnostic commands currently return script Strings using the existing runtime convention; add explicit native String ownership handling or replace these with primitive results before frequent polling. Do not turn this status command into a frame loop.

## Focused checks

```sh
node --check runtime/red4ext_hooks.js
node tests/runtime-flight-commands.mjs
node tests/runtime-flight-capture-setup.mjs
node tests/runtime-flight-position-setup.mjs
node tests/runtime-native-fallback.mjs
node tests/runtime-diagnostics.mjs
node tests/creator-transaction.mjs
node tests/creator-catalog.mjs
bash tools/test-output-snapshot.sh
bash tools/test-flight-capture.sh
bash tools/test-flight-position.sh
clang++ -std=c++17 -O2 -pthread tests/exploration-input.cpp -o /tmp/nightcity-exploration-input-test
/tmp/nightcity-exploration-input-test
```

The native executor fixture in `tests/runtime-native-gates.py` and position integration fixture in `tests/runtime-flight-position.py` additionally require their documented local Frida host setup. Compile all installed redscripts into the separate modded cache before launching. Keep the original game copy, vanilla script cache, existing mod hashes and Creator name map intact.
