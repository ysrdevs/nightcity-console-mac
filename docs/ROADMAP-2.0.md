# NightCity Console 2.0 roadmap

Approved direction: 1 November 2026. Status: isolated native prototype in progress.
This is a development plan, not a claim that these features are available.

## Release objective

Run a tested selection of real CET-dependent gameplay mods on native Apple
Silicon Cyberpunk 2077, backed by a native Console runtime and dependable mod
profiles. The first complete gameplay showcase is V's Edgerunners Mansion:
purchase, elevator travel, apartment interactions, wardrobe and save/relaunch.

Target the exact supported macOS Steam 2.5 executable. Keep the accepted 1.9
features working throughout. Compatibility will be stated for named mod
versions and exercised features, not as universal CET compatibility.

## Accepted baseline

- Console 1.9.0 release source: `f256a327d533f5058465c7f64e6f4773d0330535`.
- Signed runtime source: `ab7b6bc1e948ec96e372f0d479943d6cc7d98a56`.
  Subsequent release changes were documentation and packaging tools.
- Existing native foundations: RED4ext, ArchiveXL, TweakXL, scoped Codeware,
  Input Loader, Mod Settings, redscript compilation and the Metal/ImGui overlay.
- Accepted gameplay: Creator, noclip, VA/PUBLICNET, Equipment-EX, Cyberware-EX,
  Cassius Ryder's Immersive Rippers interaction and Limited HUD, including the
  documented save/relaunch checks. See [the compatibility list](MOD-COMPATIBILITY.md).
- Preserve the legacy 2.3.1 payload and its existing deployment targets. New
  2.0 capabilities target the supported 2.5 path.

Native migration reuses these foundations. It does not re-port every framework.
Remaining Frida-dependent Console behavior includes game-call dispatch, player
discovery, Creator localization, parts of flight integration and shutdown.

## Required for 2.0

1. The supported 2.5 production launch and normal Console/mod runtime work
   without Frida Gadget loaded. Keep Frida available for development and the
   separate legacy path until that path has its own migration decision.
2. Existing Console features meet the 1.9 acceptance baseline on the native
   backend, including old Creator definitions and save/relaunch behavior.
3. Three to five named third-party CET mods pass documented end-to-end tests,
   including the original Mansion as the first flagship target. Test fixtures
   do not count toward this total. Audit and pin each exact package first.
4. Players can manage mod profiles, switch them with the game closed, recover
   from interrupted activation and restore the previous managed files/settings.
5. The launcher identifies supported versions, detected missing capabilities
   and actionable mod errors. Unknown packages must not be labeled verified.
6. A clean installer passes the combined gameplay regression and full relaunch
   check. The final app and DMG are signed, notarized and stapled. The app-only
   ZIP contains that signed, stapled app and passes verification after extraction.

No release date is committed before the first native runtime milestone passes.
Changes to these release requirements require an explicit scope decision.

## Milestones and acceptance gates

### M0. Preserve the baseline and pin the first target

Deliverables:

- Record the immutable 1.9 artifacts, input manifests and private source
  checkpoints. Keep release binaries and accepted test installations unchanged.
- Prepare a separate 2.0 development game and test launcher with a distinct
  identity and preferences. Snapshot mutable test files only while the game
  and launcher are closed. Runtime installation also requires closure.
- Select the Console backend before process launch. Frida and native backends
  must not both own the same Console hooks in one process. No automatic live
  handoff or silent fallback between them.
- Give the native profile one authoritative Lua module loader. Disable or
  redirect the old overlay VM, autoload path and legacy Game bridge; merely
  avoiding duplicate native hooks does not remove those entry points.
- Audit the original Mansion package, its author requirements, version and
  hash. Inventory lifecycle events, Observe/ObserveAfter, Override, helper
  libraries, TweakDB operations, game methods and ArchiveXL resources.
- Classify each required capability as verified, missing or version-sensitive.
  A dependency's name/version alone does not establish API compatibility.

Exit: reproducible baseline, separate test configuration and a concrete Mansion
capability checklist. No claim of Mansion compatibility yet.

### M1. Native runtime and a minimal Lua module

Build a shared native backend for the Console and the Lua mod host. Start with
a small, versioned interface for capabilities, typed commands and results.
Keep the existing Console interaction model where possible.

The first slice includes:

- Exact executable identity checks and verified addresses before hooks load.
- An appropriate game-thread execution point, a bounded command queue and
  explicit failure when the runtime/session is unavailable.
- Correct typed values and engine handle lifetimes. Preserve full 64-bit
  identifiers; invalidate session-bound references on unload/reload.
- Native player/position queries and one explicit inventory command.
- A real Lua module with initialization, update, one hotkey, module-local
  logging and clean shutdown. Callbacks must work with the Console closed.
- A visible, attributable Lua error that leaves another healthy module usable.
  This is script error isolation, not a claim to contain native process crashes.

Do not carry successful no-op APIs from prototypes into the compatibility layer.
Unsupported required APIs must fail visibly. Arbitrary ImGui/game-call mixing
and render-thread callbacks are outside this first slice.

Automated gate: refusal on wrong executable/addresses; argument and return
conversion; stale-handle rejection; queue limits; duplicate-hook ownership;
callback ordering; module failure and unload behavior; native plugin startup.

Player gate: one hotkey-triggered item action executes once, remains responsive
with F1 closed, and continues correctly after a load/session transition. A new
process proves the native 2.5 path has no Frida Gadget loaded and no old overlay
Lua host or legacy bridge entry points active.

Exit: the first native runtime checkpoint. This is not yet full Console parity
or third-party CET mod support.

### M2. Existing Console parity on the native backend

Move behavior in small groups, using the accepted 1.9 build as the reference:

1. Item/Quick commands, supported calls, cheats and teleport bookmarks.
2. Creator record validation, creation, custom text/localization, old definitions
   and inventory persistence. Existing definitions must not be discarded when
   an older save lacks the corresponding inventory item.
3. Flight input, collision/filter handling, movement, pause/resume, Stop here,
   Return to start, workspot interruption, restart and session teardown.
4. Remaining Console lifecycle, shutdown, diagnostics and startup wiring.

Hook installation remains exclusive by process/backend. Add a new native hook
only after its exact signature, ownership and removal behavior are understood.

Exit: all existing features pass on the native backend, including the combined
mod regression and full relaunch. Audit loaded images and startup configuration
to prove the supported 2.5 path is independent of Gadget. Do not use a bundle-wide
"no Frida files" test because the retained 2.3.1 path may still contain them.

### M3. CET compatibility and the Mansion

Implement the audited target's real API semantics: module loading and helper
libraries; lifecycle and input; native and scripted game calls; properties and
collections; supported TweakDB operations; observers and overrides.

Define thread contracts before each hook. Delayed observation is acceptable
only where it preserves semantics. A synchronous override must retain its
wrapped-original continuation, return values and cleanup behavior; it cannot
be replaced with a queued notification.
An override invoked off the Lua owner thread is unsupported until a separately
validated execution model exists. Never block another engine thread waiting
for the Lua owner thread to execute that override.

Add safe ownership and conversion for every required value type, including
arrays, structs, enums, variants and 64-bit identifiers. Introduce UI callbacks
only after their threading and game-call behavior are explicit and tested.

Mansion player acceptance:

- Purchase and verify the expected charge and unlock state.
- Ride the elevator both ways; leave the area and return.
- Enter and exit sitting, sleeping and shower interactions normally.
- Use the wardrobe and verify ordinary movement afterward.
- Save to a separate manual slot, quit fully, relaunch and verify the purchase
  and interactions again.
- Run the relevant existing-mod regression and final combined pass.

The original [Mansion, mod 5437](https://www.nexusmods.com/cyberpunk2077/mods/5437)
and [Mansion Reloaded, mod 26023](https://www.nexusmods.com/cyberpunk2077/mods/26023)
are different targets. Reloaded adds Native Interactions Framework and its own
dependency chain. Do not silently substitute one for the other. If the selected
package has upstream 2.5 problems, record them and resolve the target/version
before calling the milestone complete.

Exit: one complete third-party CET gameplay experience, with exact package and
API coverage recorded. Preserve original mod files where compatible; never
silently remove required behavior to make the package appear to load.

### M4. Broaden the tested mod set

Choose two to four additional maintained packages after inspecting their actual
APIs and dependencies. Favor useful, distinct coverage:

- A small hotkey or quality-of-life mod.
- A settings/UI mod, including persistence and rebinding where supported.
- A gameplay mod exercising observers, overrides or session-bound state.
- Another world/interaction mod when its dependencies are individually proven.

Native Settings is a separate CET-side compatibility target from the native
Mod Settings integration already shipped in 1.9. Do not conflate them.

Expand Codeware only for demonstrated requirements. Entity/component callbacks,
dynamic entities, world/quest extensions and service-state serialization need
individual layout, ownership, teardown and persistence tests. Existing resource
PostLoad support is already part of the accepted profile; Resource Load, generic
cloning and service persistence are separate capabilities.

Exit: three to five named third-party CET mods total, with pinned versions,
supported features, dependencies, limitations and save/relaunch results.

### M5. Profiles, recovery and the tested-mod catalog

Profiles contain exact managed package files/hashes, owned settings/bindings,
game identity and a required foundation version. The first implementation uses
a fixed foundation version across profiles; framework upgrades/downgrades are
a separate transaction and are not ordinary mod toggles.

- Show dependent mods before disabling a requirement.
- Switch only with the game closed and one installation lock held.
- Stage the full change, validate ownership/dependencies, compile the proposed
  scripts, then activate with a recovery journal.
- Retain the previous working profile and recover interrupted activation on
  the next launcher start. Report incomplete recovery explicitly.
- Preserve unknown/manual files and existing Creator definitions. Refuse
  ambiguous ownership, collisions and foreign receipts.
- A recovery launch can omit a selected Lua mod, with its settings retained.
  Missing dependencies must be resolved before launch.
- Record the active profile in diagnostics. Associate saves with profiles only
  through user-facing guidance or explicit metadata; never replace saves silently.

File/settings rollback does not undo changes already written into a save. Use a
separate manual slot when testing a substantially different gameplay profile.

The catalog lists tested versions, required capabilities, author download links
and guided import. Gameplay mods remain separate downloads unless redistribution
is explicitly supported. Unknown packages can be inspected without being labeled
compatible. Detection is not a complete static analysis of arbitrary Lua.

Automated gate: interrupted activation, out-of-space/copy failures, failed
compilation, file changes after preview, shared/unknown ownership, foreign
receipts and recovery failures.

Player gate: create two profiles, switch with the game closed, verify their
settings/mod differences, then restore the first profile and confirm existing
Creator weapons and VA remain intact.

Exit: recoverable profiles and an honest compatibility catalog. UI/schema work
can proceed alongside M2-M4 after the capability interface is settled.

### M6. Release acceptance

- Clean install and update from 1.9, including optional EX packages and import.
- Exact native dependency/address/signature checks and clean script compilation.
  Review any warnings against the accepted baseline rather than ignoring changes.
- Combined VA purchase, Equipment-EX outfit, second OS, Creator, noclip,
  Rippers, Limited HUD, supported CET mods and profile checks.
- Full save/quit/relaunch/load test on the final signed payload.
- Packaging contains no private sources, fixtures, debug flags or nested ZIPs.
- Notarize that same signed app, staple, verify extracted ZIP and mounted DMG,
  then record hashes and local source checkpoints.
- Document exact supported versions and remaining limits. The owner pushes
  GitHub changes and uploads releases.

## Performance gates

Record the same save, location, settings, mod set, resolution and Console state
for comparisons. Separate cold startup, save loading, closed-overlay gameplay,
open-overlay behavior and command latency. Preserve run duration and sample
counts; compare repeated runs using median and high-percentile frame intervals.
These intervals are not a GPU benchmark or proof of causation.

Set acceptance thresholds from repeatable baseline variance before comparing
candidate results. Investigate material regressions before promotion. Native
code alone is not evidence of an FPS improvement. Diagnostic recording remains
optional and is disabled again after the capture.

## Manual test budget and release discipline

Run meaningful static/native/script checks before asking the player to test.
Use one new behavior and one relevant baseline pair per short request:

| Changed area | Focused regression |
| --- | --- |
| Module loading or session lifecycle | VA purchase and second OS |
| Typed calls/return conversion | Creator weapon and Equipment-EX outfit |
| Observers, overrides or input | Noclip Stop here/normal movement and Limited HUD key |
| Profiles or recovery | VA reopening and an existing Creator weapon after restoration |

These pairs apply to capabilities already enabled in the candidate. M1 precedes
native noclip and Creator parity, so use an available baseline check such as
Limited HUD input or VA and record the absent native features as pending M2.
Their absence is not a passing regression result.

Reserve the complete suite and full relaunch for coherent milestones and the
final candidate. Stop at the first failure, capture current-session evidence
and correct it before continuing. Keep automated validation, player confirmation
and untested behavior distinct. Never replace runtime files while the game or
its launcher is running.

Use regular local checkpoints with commit subject `Changes` under the owner's
existing Git identity. Keep native framework implementations and private
development evidence out of the public Console tree. No push or publishing is
part of an implementation milestone.

## Separate stretch track: AudioXL and Titanfall

Audit source availability and distribution terms early, independently of the
native Console milestone. [AudioXL's author page](https://www.nexusmods.com/cyberpunk2077/mods/33442)
states that 0.9.0 and later restrict publishing modified copies; earlier versions
remain MIT. Establish matching source, required API coverage and a distribution
route before promising a bundled port. An older source release is not assumed
to satisfy a newer mod's requirements. No author contact is sent without the
owner's instruction.

If viable, first prove one native audio event: play/stop, pause/focus behavior,
spatial emitter lifetime, volume and teardown. Broaden only after that gate.

[Titanfall BT-7274](https://www.nexusmods.com/cyberpunk2077/mods/35041) 1.2.0 has a
2.5 release but requires CET, AudioXL and VehicleTurretCore beyond the existing
foundation. Prove those dependencies and needed Codeware capabilities separately
before its complete quest, companion and piloting tests. A working Mansion does
not establish Titanfall compatibility. These goals do not block the core 2.0
release unless explicitly promoted into its scope.

## Initial exclusions

Universal CET support, arbitrary Windows DLL loading, a wholesale rewrite of
working frameworks, GOG/Intel expansion, a vehicle garage and Creator-library
sharing are outside the agreed core plan. Broad native-feature enablement must
not bypass address or lifecycle validation.

## Progress ledger

- First implementation checkpoint, 1 November: the isolated native scheduler
  probe reaches a responsive main menu, confirmed by the player. Loaded-image
  inspection shows the five accepted framework plugins and the new probe, with
  neither Gadget nor the old overlay loaded. Its first 600 update callbacks use
  one consistent thread. Script compilation has zero errors and the same 408
  warning messages as the accepted baseline. These are startup results, not
  Console parity, Lua-mod compatibility or gameplay acceptance. The 1.9 release
  artifacts and accepted test installation passed hash-preservation checks.
- The same native-only process subsequently passed player checks for loading
  an existing save, normal walking, opening a VA store, Equipment-EX outfit
  switching, second-OS activation and Limited HUD keys. Normal quit recorded
  197,810 callbacks without a thread mismatch, followed by Running exit,
  Shutdown entry and plugin unload. No new-save persistence, Creator, noclip,
  Lua gameplay API or purchase acceptance is claimed for this prototype.
- Second private probe, 1 November: native Lua initialization and 600 owner
  updates are recorded in the live game. An intentionally failing module is
  isolated while the healthy update fixture continues. Read-only RTTI inspection
  reports four unambiguous method signatures; none of those gameplay methods
  is invoked. All 110 existing framework hooks install without failure, script
  compilation has zero errors, and Gadget/the legacy overlay remain absent.
  The player confirms a responsive main menu, two existing-save loads with a
  return to the main menu between them, normal walking, VA store opening and
  Limited HUD keys. No unexpected runtime/framework error is recorded. Normal
  quit records 119,086 scheduler updates without a thread mismatch, all three
  Lua fixtures cleaning up once, owner-thread Lua shutdown and inert plugin
  unload. No gameplay API is enabled.
  Its isolated installation preserved 1.9 and the frozen first-probe artifacts.
- Third private probe, 1 November: a ScriptableService now forwards primitive
  session events to a bounded native recorder, without player access or new
  hooks. Actual script-to-native delivery is observed. Initial world attach
  callbacks arrive on worker threads rather than the Running owner, so native
  player acquisition is still disabled. An immediate registry lookup reports a
  false failure because the SDK lookup slot expects a signature hash instead of
  the plain function name used by this probe; actual handler delivery is intact.
  The player subsequently confirmed two existing-save loads, normal walking,
  return to the menu and normal quit. Four complete world cycles recorded
  worker-thread attach events and owner-thread teardown events without dropped
  or out-of-order events. All three Lua fixtures cleaned up once, and 100,663
  scheduler updates had no thread mismatch. These observations support a
  bounded diagnostic reader on the owner thread, with startup queued and
  teardown invalidating access synchronously. They do not establish safety
  against arbitrary concurrent teardown or enable a public gameplay API.
  Installation and post-quit checks preserved 1.9 and both frozen prior probes.
- Fourth private probe, 1 November: the corrected native registry lookup works
  at startup, with no registration failure. The probe captures bounded copies
  of player-system identities and observes the game's Ready event. Actual
  player/position calls remain disabled because the lifetime of an intermediate
  borrowed entry during acquisition is not yet established. The scoped-handle
  pipeline passes offline cleanup tests but is not connected to gameplay.
  Startup records 600 Lua updates and 110 installed framework hooks without
  failures; Gadget and the legacy overlay remain absent. Installation preserved
  1.9 and all three frozen prior probes. The player confirms loading, walking
  and VA store opening without issues. Two loaded-session Ready events are now
  recorded on the scheduler owner, with no Ready in the intervening menu worlds
  and no event errors. Normal shutdown is now captured with 10,708,534 scheduler
  updates and no thread mismatch. Native player calls stay disabled in this
  frozen probe. The longer run also exposed a separate Lua collector issue:
  a non-allocating callback could exhaust its memory budget after several
  minutes. The corrected host passes one million offline updates and cleanup;
  its live long-run check is pending. Successful gameplay alone did not prove
  that the Lua module remained healthy throughout the earlier run.

- [x] 2.0 direction approved and roadmap written.
- [x] Accepted 1.9 release and source checkpoints identified.
- [ ] M0: isolated test configuration and exact Mansion capability inventory.
- [ ] M1: minimal native runtime and Lua module.
- [ ] M2: existing Console parity.
- [ ] M3: Mansion gameplay and persistence.
- [ ] M4: expanded tested CET mod set.
- [ ] M5: profiles, recovery and catalog.
- [ ] M6: final release acceptance and notarized artifacts.
- [ ] Stretch: AudioXL source/distribution feasibility.
- [ ] Stretch: audio prototype, VehicleTurretCore and Titanfall acceptance.
