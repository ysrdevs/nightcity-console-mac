# NightCity Console for Mac 2.0.0

The app and DMG are Developer ID signed, notarized by Apple and stapled.
The signed player installer passed its final camera, keybinding, flight and
Mansion activity checks, including relaunch. The ZIP contains the same
stapled app without nested ZIP files.

## A native runtime for Cyberpunk 2077 2.5

The supported macOS Steam 2.5 backend now runs the Console and reviewed Lua
mods through a native runtime, without loading Frida Gadget. The separate
legacy 2.3.1 backend is retained.

Items, money, the Iconic Weapon Creator, favorites, gameplay controls, saved
locations, vehicle summoning and noclip have moved to the native backend.
Existing Creator definitions and saves are preserved. Noclip still supports
travel, Stop here, pause/resume and optional Return to start.

## Original gameplay mods on Mac

- **Immersive Third Person: Best Of Both Worlds V2 2.0.1:** the original Lua
  and REDscripts run unchanged. Smooth mouse look, adjustable distance/height,
  movement and switching between first and third person have passed testing.
  Weapon drawing uses first person for aiming, with third person restored on
  holstering when appropriate. Bind the camera key under MODS → Immersive Third
  Person → Keys; F10 and its save/relaunch persistence passed the final installer
  check. F1 includes a camera toggle, and Console accepts `thirdperson`.
- **V's Edgerunners Mansion 2.0 with Native Interactions Framework 1.1.5:**
  purchase/ownership, elevator travel and apartment interactions, including
  sleeping and drinks. Ownership and tested activities survive save/relaunch.
- **Native Settings 1.97 and Vehicle Call Cost:** mod controls, configurable
  charging, disabled behavior and setting persistence.

These gameplay mods and their required original packages are separate
downloads. Add Mod checks the exact supported versions and dependencies,
prepares the reviewed outputs and shows a preview before applying them.
Changed or unsupported Lua versions require a compatibility update.

## Existing mod support stays

Virtual Atelier, Equipment-EX, Cyberware-EX, Immersive Rippers and Limited HUD
remain part of the tested baseline. Equipment-EX and Cyberware-EX are available
from **Optional Mods**. VA and store packs remain separate downloads.

The app includes macOS RED4ext, ArchiveXL, TweakXL, scoped Codeware, Input Loader,
Mod Settings and redscript compilation. This is support for named versions and
tested features, not universal CET, Codeware or Windows DLL compatibility.
GOG and AudioXL are not included in this release's support claim.

## Recovery and diagnostics

Managed imports use verified files, recoverable transactions and a previous
selection that can be restored with the game closed. Unknown edited files are
kept and reported instead of silently overwritten. Settings, saves and Creator
definitions are separate from managed immutable packages.

Use **Profiles…** to save and switch named managed Lua mod selections. Dependency
checks protect required providers when removing a mod. Settings are shared
between profiles; unrelated mods and saves are not switched.

The Console's **Lua mods** tab shows module state and failures. Diagnostics
include native-runtime identity, module recovery state, selected package
versions and optional sampled callback timings. Timings measure runtime work,
not game FPS. Raw settings, source paths, saves and command history are excluded.

## Updating

Quit Cyberpunk and the old launcher, replace the app, then click **Install**
and **Play**. The supported 2.5 installation uses the native backend and removes
known previous Console injection files through the managed upgrade transaction.
Keep a separate manual save when adding gameplay mods.

See the [mod guide](https://github.com/ysrdevs/nightcity-console-mac/blob/v2.0.0/docs/MOD-INSTALLATION.md),
[compatibility list](https://github.com/ysrdevs/nightcity-console-mac/blob/v2.0.0/docs/MOD-COMPATIBILITY.md) and [noclip guide](https://github.com/ysrdevs/nightcity-console-mac/blob/v2.0.0/docs/EXPLORATION.md).
