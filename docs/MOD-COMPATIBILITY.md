# Mod compatibility for NightCity Console 1.9

These checks target Cyberpunk 2077 **2.5.0**, native Apple Silicon Steam.
They describe tested flows and exact versions, not every feature or combination.
The final 1.9 release candidate is still being validated.

| Mod | Version | Verified development-build checks | Installation |
| --- | --- | --- | --- |
| Virtual Atelier | 1.6.0 | Store rendering, search, purchase/equip and save/relaunch | Download separately, then Import VA |
| PUBLICNET, now A.G.I.S. | 1.2.1 | Store listing and purchases with the tested VA version | Download separately, then Add Mod |
| Equipment-EX | 1.2.9 | Extra clothing slots, named outfits, switching and save/relaunch | Optional Mods in the launcher |
| Cyberware-EX | 1.5.6, default preset | Second operating system, abilities and save/relaunch | Optional Mods in the launcher |
| Immersive Rippers | 2.6.2 | Cassius Ryder chair, cyberware menu, exit/repeat and save/relaunch | Download separately, then Add Mod |
| Limited HUD | 2.23.1 author source snapshot | Import and combined compilation pass; gameplay acceptance pending | Download separately, then Add Mod |

Virtual Atelier, store packs, Immersive Rippers and Limited HUD are not bundled.
Use their official pages:

- [Virtual Atelier](https://www.nexusmods.com/cyberpunk2077/mods/2987)
- [PUBLICNET / A.G.I.S.](https://www.nexusmods.com/cyberpunk2077/mods/10909)
- [Immersive Rippers](https://www.nexusmods.com/cyberpunk2077/mods/7064)
- [Limited HUD](https://www.nexusmods.com/cyberpunk2077/mods/2592)

The Limited HUD candidate uses the author's exact files from commit
`7bc5ac17ebdae21d2c9067604cc6581ccca34012`, corresponding to the 2.23.1 changes.
This does not claim the generated test ZIP is byte-identical to the Nexus ZIP.
Only its main package is in scope; optional HUD replacements need separate tests.

The bundled foundation on 2.5 includes native RED4ext, ArchiveXL, TweakXL,
scoped Codeware support, Input Loader, Mod Settings and the redscript compiler.
Input Loader and Mod Settings passed custom input, settings controls, rebinding,
VA Instant Buy and relaunch checks. They do not make Windows native plugins or
CET/Lua mods compatible with macOS.

Codeware support remains scoped. Full world, entity, quest, weather and service
persistence features are not covered by the listed tests. Rippers acceptance
is specific to Cassius Ryder; it does not establish every clinic or scene.
Unknown versions, optional presets and extra mods can require new compatibility
work. The importer flags detectable missing requirements and conflicts, but
cannot determine every dependency or minimum version from arbitrary packages.

Follow the [installation guide](MOD-INSTALLATION.md), keep a separate manual save
and report the exact mod version and first failure when exporting diagnostics.
