# Private 1.9 mod-support checkpoint

Accepted on 30 October 2026 for native macOS Cyberpunk 2077 2.5. This records
the tested development build before Input Loader and Mod Settings work.

## Tested flows

- Immersive Rippers 2.6.2: Cassius Ryder chair interaction, cyberware menu,
  exit, normal walking and repeat interaction.
- Existing-mod regression: Virtual Atelier purchases, Equipment-EX outfit
  switching, both Cyberware-EX operating systems, Creator and noclip.
- Noclip vehicle traversal: four car-impact events suppressed in a recorded
  session; Stop restored normal collision without unresolved recovery.
- The user revisited the previously crashing below-map/building area without
  another crash after the ArchiveXL replacement-node correction.
- Full game quit/relaunch was confirmed by a new process and user gameplay.
- After diagnostic cleanup, a further fresh process passed the Cassius menu,
  Virtual Atelier opening and flight Stop checks. All 107 native hooks loaded,
  with no new crash or fault recorded.

## Preserved state

The original Rippers script was restored byte-for-byte. Four temporary logging
lines and the private resource-trace flag were removed. The separate modded
script cache compiled successfully with zero errors and 408 existing warnings.
Hash checks preserved the framework binaries, flight scripts, other mods and
vanilla script cache. The cleanup received a separate gameplay check.

The native ports, their detailed evidence and signed test build remain in the
private development workspace. This checkpoint does not publish those sources
or constitute a public release.

## Remaining scope

Acceptance covers the tested clinic and flows, not every clinic or the full
Codeware world API. Additional resource-handler readbacks and sector coverage
remain unverified. Restarting flight directly after swimming without a save
reload is also untested.

Input Loader and Mod Settings are the next separate development slice and are
not part of this accepted checkpoint.
