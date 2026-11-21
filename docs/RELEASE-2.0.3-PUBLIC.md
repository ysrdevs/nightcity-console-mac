# NightCity Console for Mac 2.0.3

Corrects a reproduced game startup crash after successful script compilation in 2.0.2, on Cyberpunk 2077 2.5.0 for native macOS Steam.

The earlier compiler correction resolved a forward-declaration compilation error but could still write native fields before the classes that own them. This depended on script discovery order. The game could then terminate with signal 11 while loading the compiled scripts, before reaching the main menu.

- Allocate added fields after their new parent classes are defined.
- Check the final compiled layout and refuse invalid native-field ordering before writing it.
- Recognize the exact 2.0.2 compiler files when upgrading, with backups and interrupted-update recovery.
- Retain the earlier preparation-timeout, compiler-repair and diagnostics fixes.

No mod scripts are rewritten or rearranged. The native gameplay runtime, frontend and framework payloads are unchanged from 2.0.2.

## Updating

Quit Cyberpunk and the old launcher. Replace **NightCity Console** in Applications with the app from the new DMG or ZIP. Open it, confirm the selected game folder, click **Install / Reinstall NightCity Console**, then **Play**. Reinstall updates the compiler, and Play recompiles scripts with the correction.

There is no need to delete mods, the compiler or saves manually. If the compiler pair was already deleted, Install restores it.

## Verification and limits

The player's signal-11 crash was reproduced locally with the same game executable identity and stock cache, using only bundled scripts in the reported framework-file order. With the corrected compiler, that same input order reaches startup and exits normally. The full 234-script configuration also reaches the main menu and F1 console.

Compiler tests cover final serialized field ordering, inherited-field conflicts, defaults and bytecode references. The signed update passed targeted installation, rollback and full script-preparation checks on disposable fixtures while preserving stock cache and player-file sentinels.

These results verify the reproduced startup defect locally. They do not establish recovery on every player's installation or replace an affected player's load/gameplay confirmation.
