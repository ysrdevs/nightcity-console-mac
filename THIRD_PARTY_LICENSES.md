# Third-party components

NightCity Console bundles or builds against the following third-party software.
Each retains its own license. NightCity Console distributes **none** of CD PROJEKT RED's
game files - players use their own legally-owned copy of Cyberpunk 2077.

| Component | Role | License | Source |
|---|---|---|---|
| **Dear ImGui** | In-game console UI (Metal backend) | MIT | https://github.com/ocornut/imgui |
| **Frida (frida-gadget)** | In-process script host injected into the game | wxWindows Library License / LGPL-derived | https://github.com/frida/frida |
| **RED4ext (macOS port)** | REDengine hooking framework | MIT | https://github.com/WopsS/RED4ext; current macOS adaptations maintained separately |
| **RED4ext.SDK** | Native plugin headers and generated layouts | MIT | https://github.com/WopsS/RED4ext.SDK; current macOS adaptations maintained separately |
| **TweakXL** | TweakDB extensions | MIT | https://github.com/psiberx/cp2077-tweak-xl; current macOS adaptations maintained separately |
| **ArchiveXL** | Native archive/resources integration | MIT | https://github.com/psiberx/cp2077-archive-xl; current macOS adaptations maintained separately |
| **Codeware** | Scoped UI and verified wardrobe support on 2.5 | MIT | https://github.com/psiberx/cp2077-codeware; current macOS adaptations maintained separately |
| **Equipment-EX 1.2.9** | Optional expanded wardrobe/outfit mod | MIT | https://github.com/psiberx/cp2077-equipment-ex; pinned core source/assets in `native25/optional-mods/` |
| **Cyberware-EX 1.5.6** | Optional default cyberware expansion mod | MIT | https://github.com/psiberx/cp2077-cyberware-ex; pinned core source in `native25/optional-mods/` |
| **redscript** | Script compiler | MIT | https://github.com/jac3km4/redscript; pinned compiler release in `tools/prepare-release-deps.py` |
| **nctool** | Separate mod installer process | MIT source; links GPLv3 WolvenKit | https://github.com/ysrdevs/cyberpunk-savekit-mac; complete helper source snapshot and patches in `native25/modcompat/` |
| **WolvenKit** | Archive library used by nctool | GPLv3 | https://github.com/WolvenKit/WolvenKit; exact source commit and existing raw-buffer patch in `native25/modcompat/` |
| **WolvenKit/Kraken** | Native compression library used by nctool | GPLv3 or later, as declared in the decompressor source | https://github.com/WolvenKit/kraken; binary hash and source-provenance limitation in `native25/modcompat/sources.lock.json` |

The links above identify the upstream projects. The current macOS native
framework implementation snapshots and build recipe are not included in this
release tree; publication in separate repositories is planned. Their accepted
prebuilt runtime inputs are recorded in `native25/accepted-payload.json`.

Native dependency notices are retained under `native25/licenses/` and beside
the bundled native plugins. Preserve those notices when redistributing them.
The app's `Contents/Resources/native25` includes the loader/SDK notices and
plugin `LICENSE`/`THIRD_PARTY_LICENSES` files. The compiler notice is at
`Contents/Resources/scc/LICENSE`; helper and mod-patch notices are under
`Contents/Resources/nctool/licenses`.

The scoped compatibility deltas for Cyberware-EX and Equipment-EX retain their
upstream MIT notices in `native25/modcompat/`. Their tested core packages are
bundled as optional installs for 2.5, with complete MIT notices under
`Contents/Resources/optional-mods/licenses` and inside each package. Corresponding
source files, package recipes and hashes are preserved in `native25/optional-mods`.
Virtual Atelier, store packs and Cyberware-EX addon presets are not bundled.

The installer helper and its dependencies retain their own licenses. The
`native25/modcompat/` source snapshot, patches, notices and build instructions
remain public alongside the optional mod sources; the native framework source
availability described above does not replace these materials or change their
licenses.

The pre-existing Kraken binary is preserved by SHA-256. Its historical source
commit was not recorded, so the helper documentation does not claim a verified
clean-source, byte-identical rebuild of that input. This limitation is recorded
explicitly alongside the pinned helper/WolvenKit source and build instructions.

Cyberpunk 2077 is a trademark of CD PROJEKT S.A. This project is an unofficial,
non-commercial, single-player modding tool and is not affiliated with or endorsed
by CD PROJEKT RED.
