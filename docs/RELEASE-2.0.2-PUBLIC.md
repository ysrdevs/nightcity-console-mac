# NightCity Console for Mac 2.0.2

Hotfix for script preparation and compilation failures on Cyberpunk 2077 2.5.0 for native macOS Steam.

- Fixes the package-preparation hang that could stop Install, Add Mod or Play with “nctool exceeded its preparation time limit”. The launcher now starts helper processes with the correct signal mask.
- Fixes an order-dependent script compiler constant-pool failure when a mod adds a field before the target class or its parent is defined. Inherited duplicate-field checks remain enforced.
- Improves preparation error reporting and keeps bounded preparation logs for support.
- Expands Export Diagnostics with native game logs, compiler and cache identities, preparation logs and the actual installed launcher version.
- Removes valid macOS AppleDouble sidecars from compiler hint files, preventing a secondary hint-reading error from obscuring compilation failures.

## Updating

Quit Cyberpunk and the old launcher. Open the DMG, replace **NightCity Console** in Applications, then open it and click **Install / Reinstall NightCity Console**, followed by **Play**.

Do not manually delete the compiler or your mods. If `scc` or `libscc_lib.dylib` were already deleted, Install restores them. The update retains the 2.0.1 upgrade handling and preserves existing mod files, settings and Creator definitions.

The native gameplay runtime, frontend and framework code are unchanged in this hotfix. The app and DMG are Developer ID signed, notarized by Apple and stapled.

## Validation

The reported preparation hang was reproduced with the published helper. The exact `definition not found: 212489` compiler failure was also reproduced using the affected player's hash-matched framework files in their logged order; the corrected compiler accepts the identical inputs. The corrected signed package passed installation, rollback and preparation checks on disposable fixtures. Its compiled scripts reached the game's title screen with Native Settings initialized. The compiler correction passed unit and actual compiler checks, including forward declarations and inherited-field conflicts.

These local results do not establish that every affected player's installation has recovered. If launch still fails, export diagnostics from this version so its new preparation and native game logs are included.
