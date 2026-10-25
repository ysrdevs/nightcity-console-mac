# Runtime performance work for 1.7.0

The reported slowdown also occurred with the console closed. A narrow live process sample showed engine worker threads waiting in Frida's shared JavaScript callback machinery beneath script execution. The overlay already skipped its Metal render pass while hidden; no per-frame Metal queue wait was found. The two main runtime hot paths were the universal executor interceptor and localization lookup interceptor, which entered JavaScript for every call.

## Changes

- On native Mac 2.5, filter idle executor calls in native CModule callbacks. Keep nesting per engine thread, capture unfamiliar function/context identities, and preserve player changes, observers and queued commands. The existing 500ms poll invalidates identity caches so recycled objects are rediscovered; commands and observers bypass the cache immediately. All game-memory inspection remains in guarded JavaScript.
- Match custom localization keys natively before calling JavaScript. Publish immutable sorted key tables with acquire/release atomics, retaining old tables for concurrent readers. Matching keys still use the existing game CString allocator and found flag.
- Compile four small atomic helpers into the existing overlay dylib. Missing helpers or unsupported CModule setup fall back to JavaScript callbacks. Game 2.3.1 deliberately retains its existing callback path.
- Disable continuous frame-cadence logging by default. Optional NCC_PERF=1 instrumentation writes a bounded JSON snapshot on a utility queue, without accumulating work or writing files from the render callback.
- Bound visible-console output reads to the latest 128 KiB and clip offscreen console rows.

## Verification

`tests/runtime-native-gates.py` builds an isolated ARM64 executable and loads a copy of the shipped Gadget. It does not attach to the game. It exercises actual native callbacks, function discovery, cache refresh, nested calls, player switching, observer delivery, busy reentry, localization keys across the UInt32 range, the ARM64 x8 output register, found flags and key-table replacement. It then compares four worker threads calling a small function with no hook, minimal legacy JavaScript entry/leave callbacks, and the native gate.

With Frida 17.5.2, one recorded three-run fixture comparison gave medians of 121.668 ms for legacy callbacks and 2.198 ms for the native filter across 40,000 calls. These numbers measure synthetic callback overhead, not game FPS or an expected FPS multiplier. Existing Creator RTTI, transaction/duplicate/timeout and name-preservation tests also pass. `tests/runtime-native-fallback.mjs` checks the real compatibility-listener wiring with nested calls on separate threads.

Separate APFS-cloned menu runs use the same settings, mod stack and overlay binary for both old and gated JavaScript. They must reach MAIN_MENU, complete the held-menu callback and exit normally. Menu tests do not load saves or generate keyboard input. Player gameplay and persistence acceptance remain necessary after packaging; a background menu comparison cannot establish gameplay FPS.

## Optional timing summary

`NCC_PERF=1` writes `/tmp/cp2077_perf.json` with schema version, process ID, timestamp, mode, console visibility, frame/sample counts, elapsed time, and average/p95/maximum drawable acquisition intervals. It contains no commands, names, paths or save data. A fresh summary replaces the previous one atomically using a uniquely created temporary file.

The measurement is CAMetalLayer.nextDrawable cadence, not GPU duration. Four LRU layer slots collect acquisitions across engine worker threads without combining unrelated surfaces. A nonblocking lock orders the monotonic clock reads; contention increments dropped_samples, so an interval can span skipped acquisitions. Gaps over five seconds and console visibility changes reset partial windows; shorter stutters remain included. Opaque layer_id, tracked_layers, idle_resets and visibility_resets describe each snapshot. A stopped renderer can leave stale data, so exports retain the timestamp/session association. With instrumentation disabled, no nextDrawable hook or periodic cadence work is installed.

A live player-session sample confirmed that nextDrawable migrates among many redDispatcher workers. The earlier single-thread recorder therefore missed acquisitions and could remain stale. `tests/overlay-cadence.cpp` covers eight real worker threads sharing a layer, independent interleaved layers, idle and visibility resets, preserved five-second stutters, bounded LRU replacement, forced contention and immutable snapshots. This correction changes optional telemetry only; the accepted runtime filters are unchanged.
