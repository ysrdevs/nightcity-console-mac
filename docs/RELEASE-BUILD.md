# Local Console release assembly

This workflow builds NightCity Console's launcher and overlay from the public
source and combines them with explicit prebuilt dependencies. Use Apple Silicon,
Xcode command line tools and Python 3.10 or later. Network access is used for the
pinned overlay dependencies and release archives.

The current macOS RED4ext/SDK, TweakXL, ArchiveXL and Codeware adaptations are
maintained separately and are not included as implementation source here.
Separate repositories are planned. Assemble with the accepted native runtime
input below; this is not a public source-build recipe for those frameworks.

The public 1.5.0 ZIP is the 2.3.1 compatibility baseline. Its payload differs from
the source tag and from the current installed game. Release builds preserve its
loader, Frida Gadget, plugin libraries, address database and configuration.
They never import dependencies from the live game or overwrite developer `deps/`.

The archived baseline ZIP has SHA-256:

```
19f83a8546819cf09091bb836e585940eaed23a87447009184249d5d2f031151
```

Build with three explicit dependency inputs:

```sh
NIGHTCITY_BUILD_MODE=release \
NIGHTCITY_BASELINE_ZIP=/path/to/NightCity-Console-for-Mac.zip \
NATIVE25_DIR=/path/to/accepted-prebuilt-2.5/red4ext \
NCTOOL_PUBLISH_DIR=/path/to/nctool-publish \
./launcher/build-app.sh
```

`NATIVE25_DIR` must contain `RED4ext.dylib`, `config.ini`, `bin/red4ext_plugin_check`,
`bin/x64/cyberpunk2077_addresses.json` identifying 2.5.0, and complete
`plugins/TweakXL`, `plugins/ArchiveXL` and `plugins/Codeware` directories including
their scripts, resources and license notices. Every accepted runtime input must
match `native25/accepted-payload.json`; unknown plugin files are rejected. This
manifest identifies the prebuilt Codeware UI/wardrobe profile and the other
tested native dependencies. A signed app's libraries may differ from these input
hashes, so a release extraction is not automatically a valid build input.
Private test metadata and CET-Lua development plugins are excluded. The native
framework payload remains separate from the optional gameplay packages.

Release staging also deterministically builds Equipment-EX 1.2.9 and
Cyberware-EX 1.5.6 from the pinned MIT inputs under `native25/optional-mods`.
The two ZIPs, catalogue and license files are copied to
`Contents/Resources/optional-mods`. Both are optional, unchecked by default,
and offered only on game 2.5.0. See that directory’s README and source lock
for provenance, the exact compatibility adaptation and reproduction commands.
The bundle verifier checks every optional package and rejects extra files.
VA and store packages are not distributed; the launcher links to VA and imports
user-provided ZIPs or folders.

The nctool input is an explicit self-contained `osx-arm64` publish directory with
its .NET runtime and universal/arm64 `libkraken.dylib`. Use the version with the
`stageplugins` and `compat25` commands and the checked
`nightcity-mod-compat.json` adapter manifest. The older public helper predates
these commands.
The helper source snapshot, compatibility code, pinned WolvenKit input and
raw-buffer patch are documented in
[`native25/modcompat/README.md`](../native25/modcompat/README.md). That recipe
also records the required Kraken binary input and its source-provenance limit.
Release assembly consumes the explicit helper publish directory; it does not
silently rebuild those dependencies.

Redscript 0.5.32 and the official ArchiveXL 1.27.4 input are downloaded with pinned
SHA-256 checksums and cached under `build/release-downloads`. The accepted native
ArchiveXL Bundle is preserved byte-for-byte during staging, including its `.xl`
files; the downloaded ZIP records upstream provenance.
Inputs are validated in a staging directory before replacing `build/release-deps`.
The bundle includes `release-inputs.json` recording every staged input hash;
codesigning subsequently changes Mach-O bytes, so these are provenance hashes,
not hashes of the final signed executable files.

Keep `Const.appVersion`, both version fields in `launcher/Info.plist`, and release
notes aligned. A new stable version must exceed the preceding public release. The updater checks
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

After testing the signed candidate, preserve its exact signatures when notarizing:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE=cyberconsole-notary \
./tools/sign-notarize.sh --existing-app 'build/NightCity Console.app' \
  --skip-signing --output-dir /path/to/release
```

This uploads only to Apple, checks that each submission is accepted, staples both
app and DMG, and verifies signatures and Gatekeeper assessment. It saves the
submission receipts, Apple logs and final package SHA-256 checksums alongside
the ZIP and DMG. It never publishes to GitHub or Nexus. `--existing-app` avoids
rerunning dependency preparation or compilation; `--skip-signing` also avoids
changing the tested executable signatures. Independently inspect the packaged
app from both containers before handing off a release.
