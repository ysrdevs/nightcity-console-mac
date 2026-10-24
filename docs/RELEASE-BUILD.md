# Local release builds

The public 1.5.0 ZIP is the 2.3.1 compatibility baseline. Its payload differs from
the source tag and from the current installed game. Release builds preserve its
loader, Frida Gadget, plugin libraries, address database and configuration.
They never import dependencies from the live game or overwrite developer `deps/`.

The archived baseline ZIP has SHA-256:

```
19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151
```

Build with three explicit inputs:

```sh
NIGHTCITY_BUILD_MODE=release \
NIGHTCITY_BASELINE_ZIP=/path/to/NightCity-Console-for-Mac.zip \
NATIVE25_DIR=/path/to/built-2.5/red4ext \
NCTOOL_PUBLISH_DIR=/path/to/nctool-publish \
./launcher/build-app.sh
```

`NATIVE25_DIR` must contain `RED4ext.dylib`, `bin/red4ext_plugin_check`,
`bin/x64/cyberpunk2077_addresses.json` identifying 2.5.0, and complete
`plugins/TweakXL` and `plugins/ArchiveXL` directories including their scripts and
native dependencies. Only those two plugin trees enter the public bundle.
Codeware and CET-Lua development plugins are excluded.

The nctool input is an explicit self-contained `osx-arm64` publish directory with
its .NET runtime and universal/arm64 `libkraken.dylib`. Use the version with the
`stageplugins` command. The older nctool in the public ZIP predates that command.
Building nctool from source still requires the pinned WolvenKit checkout and the
raw-buffer patch documented in the save-tool repository; release assembly does
not silently rebuild that dependency.

Redscript 0.5.32 and the matching ArchiveXL 1.27.4 resource bundle are downloaded
with pinned SHA-256 checksums and cached under `build/release-downloads`.
Inputs are validated in a staging directory before replacing `build/release-deps`.
The bundle includes `release-inputs.json` recording every original input hash;
codesigning subsequently changes Mach-O bytes, so these are provenance hashes,
not hashes of the final signed executable files.

Keep `Const.appVersion`, both version fields in `launcher/Info.plist`, and release
notes aligned. The stable version must be greater than 1.5.0. The updater checks
GitHub's latest stable release and offers its DMG as a manual download; no update
feed or automatic installation service is involved.

Validate without running the app:

```sh
python3 tools/test-release-deps.py
python3 tools/verify-release-bundle.py 'build/NightCity Console.app'
```

To sign an already tested local bundle without rebuilding or uploading:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
./tools/sign-notarize.sh --existing-app 'build/NightCity Console.app' --sign-only
```

When notarization is separately authorized, omit `--sign-only` and supply
`NOTARY_PROFILE` with an existing keychain profile. This uploads the app and DMG
to Apple, staples the results, and creates local ZIP/DMG files. It never publishes
to GitHub or Nexus. `--existing-app` is important: signing the tested bundle does
not rerun dependency preparation or compilation.
