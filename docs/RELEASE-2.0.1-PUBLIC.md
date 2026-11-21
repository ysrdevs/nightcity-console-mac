# NightCity Console for Mac 2.0.1

Hotfix for upgrading an existing NightCity Console installation to the native 2.0 runtime on Cyberpunk 2077 2.5.0 for macOS Steam.

- Fixes Install stopping with “Kept an unrecognized or edited file” for the script compiler and other files from published Console releases 1.6.0 through 1.9.0.
- Recognizes the exact files from those signed releases and backs them up automatically during replacement. Mods, settings and Creator definitions are preserved.
- Fixes the first native launch when the script compiler restores its supported original game-script cache from an earlier installation.
- Removes valid macOS AppleDouble metadata sidecars from mod/script paths before launch so the compiler does not try to parse them as script files.

Quit Cyberpunk and the old launcher, replace NightCity Console in Applications, then click **Install** followed by **Play**. You do not need to uninstall mods or manually delete `scc` or `libscc_lib.dylib`. If those two files were already removed, Install supplies them again.

All 2.0 features remain included. This update changes installation and launch preparation; the native gameplay runtime is unchanged.
