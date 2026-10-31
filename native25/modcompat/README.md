# Scoped mod compatibility helper

This code is compiled into the existing `nctool` process. It is not a mod bundle.
The complete helper entrypoint/project snapshot is in `nctool/`; the compatibility
class and catalog are beside it. `sources.lock.json` pins the original repository,
our patch, the existing WolvenKit input/patch and the native Kraken binary input.
The complete patch applies at the recorded `cyberpunk-savekit-mac` base commit.

## Runtime behavior

`nctool compat25 <gameDir>` reads the real app's Info.plist. It returns 0 without
changes outside game 2.5.0. On 2.5 it checks all targets before writing, accepts
already adapted code, and applies changes through atomic file replacements with
rollback if a write fails. Validated input bytes are retained, so edits made
between planning and applying also refuse before any write. Unsupported versions, duplicate cores and edited
target code return 2 with an actionable `[COMPAT]` message.

- Cyberware-EX 1.5.6: exact normalized-token hashes include the annotations,
  signatures and complete bodies of `GetActiveItem` and `UpdateArmSlot`. A single
  1.5.6 version facade is required. The method patches support the original source
  layout and concatenated release layout; unrelated custom code is preserved.
- Equipment-EX 1.2.9: exact normalized whole-file before/after hashes cover the
  original release `EquipmentEx.Global.reds` and the corresponding source file.
  Only the restoration loop's inclusive bound changes.
- Install preflight leaves the source ZIP/folder untouched. Recognized tested
  Equipment archives and the previously accepted native VA archive keep their
  original bytes on 2.5. The original VA 1.6.0 archive is raw-repacked and all 21
  output resources are verified against the accepted resource hashes before
  deployment. Container timestamps vary, as recorded in
  `va-package-verification.json`. Their paired XL file stays beside the archive
  under `archive/Mac/mod`. Other archive behavior is unchanged. Bundled native dependency directories from Windows mod ZIPs do not
  overwrite NightCity's tested 2.5 Codeware/TweakXL/ArchiveXL files.

The launcher calls compatibility before compilation on Play and after mod
installation. Existing nctool uninstall manifests list paths, not hashes; the
adaptations do not add extra installed script files.

## Source/build inputs

To reproduce the helper changes, check out the pinned `cyberpunk-savekit-mac`
base, apply `nctool-compat.patch`, `archive-repack.patch`, and then `import-preview.patch`, populate `_refs/WolvenKit` at its recorded
commit and apply `wolvenkit-raw-buffers.patch`. The latter patch predates this
release. Use the preserved native universal `libkraken.dylib` input with the
recorded SHA-256 and .NET 8:

```sh
dotnet publish _tools/nctool/nctool.csproj -c Release -r osx-arm64 \
  --self-contained true -p:PublishSingleFile=false -o /path/to/nctool-publish
```

The historical Kraken source commit was not recorded in the original workspace.
Its public source is WolvenKit/Kraken, but an exact historical source-to-binary
rebuild is **not verified**. This recipe uses that explicit hashed binary input.
WolvenKit's GPLv3 notice, the helper's MIT notice and the mod notices are retained;
the source snapshot and patch are included for review and redistribution.

## Isolated checks

Generic archive repacking preserves the original resource hashes, including
resources whose depot paths are unknown. Every output resource is extracted
again and compared with the staged bytes before the output archive is replaced.
Incomplete extraction or mesh conversion fails without replacing an existing
output. `rawrepack` requires an empty working directory.

The archive regression runner accepts explicit local input paths and keeps all
downloads untouched. It covers ordinary and hash-named resources, mesh conversion,
the accepted VA conversion, and failed-output preservation:

```sh
python3 tools/test-archive-repack.py --help
```

```sh
python3 tools/test-modcompat.py --dotnet /path/to/dotnet \
  --nctool /path/to/nctool/bin/Release/net8.0/nctool.dll \
  --cyberware-source /path/to/pinned/CyberwareEx \
  --equipment-zip /path/to/Equipment-EX-1.2.9.zip \
  --va-zip /path/to/Virtual_Atelier_1.6.0.zip
```

These create disposable fake game folders and test source/bundled layouts,
repeat application, retained unrelated edits, refusal of modified targets and
unknown versions, 2.3.1 no-op behavior, rollback, actual Equipment ZIP contents
installation, and actual VA 1.6.0 ZIP installation/resource validation. VA has
optional Equipment imports that must not require an installed Equipment core. The Cyberware bundle fixture is synthesized from the pristine
pinned source; it is not claimed to be a downloaded Nexus ZIP test. The installed
game is never opened or changed by this test.

## Prepared mod imports

`nctool prepare-import <zip-or-folder> <gameDir> <new-workspace>` snapshots the
source into `workspace/source`, filters unsupported components, and runs the
existing installer against `workspace/game`. Only the selected game's
Info.plist is copied; installed scripts are validated read-only. The schema 1
`report.json` lists exact converted files, SHA-256 hashes, source inventory,
skipped files, and blocking issues. Preparation writes nothing into the game.
Case and Unicode aliases cannot place the workspace inside the source/game.

The report uses `files[].source` relative to the workspace and
`files[].destination` relative to the game. `sourceFiles[].path` is relative to
`workspace/source`. `sourceFingerprint` hashes the sorted source records, not
the external ZIP's filename. Later external source edits do not replace the
reviewed snapshot. ZIP and source snapshots reject traversal, symlinks, special
files, duplicate/case-colliding paths, more than 20,000 files, files over 8 GiB,
or totals over 16 GiB. These bounds do not claim to limit all intermediate
resource expansion inside the existing archive converter.

`nctool commit-import <request.json>` accepts:

```json
{
  "gameRoot": "/path/to/Cyberpunk 2077",
  "packages": [{
    "workspace": "/path/to/preview",
    "reportSHA256": "hash-of-the-reviewed-report-json",
    "receiptName": "my-mod.json"
  }]
}
```

Commit revalidates the entire batch, prepared source/payload inventories, game
version/Info.plist, destination containment, and all receipt paths before game
writes. It refuses while the game is running. Every existing destination or
receipt blocks this initial import workflow; remove the old mod first. Native
and CET components block a package; recognized bundled foundation components
are skipped with an explanation. Foundation scripts/plugins and their exact companion archive names are protected,
while ordinary XL companions can use ArchiveXL's Bundle directory. Input Loader
XML files under `r6/input` are supported.

Only reviewed files are copied with create-new semantics, followed by receipts
under `red4ext/nightcity/mods`. Failures roll back files and empty directories
created by that transaction. Exit 2 means refusal or completed rollback; exit 3
means rollback needs attention. A transaction that reached game writes records
its outcome in each workspace's `commit-result.json`. Keep that workspace for
recovery instead of retrying a failed approval. Dependency policy and player
approval remain in the launcher; this helper does not infer gameplay support.

```sh
python3 tools/test-mod-import.py --dotnet /path/to/dotnet \
  --nctool /path/to/nctool.dll \
  --va-zip /path/to/Virtual_Atelier_1.6.0.zip \
  --equipment-zip /path/to/Equipment-EX-1.2.9.zip \
  --rippers-folder /path/to/Immersive-Rippers/extracted
```

The offline tests use disposable game folders, including mid-transaction
failure/rollback, stale approvals, malformed packages, native blockers,
foundation preservation, `r6/input`, and exact reviewed payload deployment.
The running-game refusal check compiles a tiny sleeping process with the game's
process name; it never launches Cyberpunk. For an isolated incremental build,
compile the current Program.cs, ModImport.cs and NightCityModCompatibility.cs
against the accepted helper's WolvenKit.RED4/Common/Core assemblies. Copy the
complete accepted helper directory and replace only `nctool.dll`; preserve its
apphost, deps/runtimeconfig files, native Kraken library and other dependencies.
