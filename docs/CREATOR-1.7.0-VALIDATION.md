# Creator expansion validation: 1.7.0

The expanded Creator contains 37 base-game weapon presets in nine categories,
with search by name, category and weapon type. The original seven profiles keep
their preset IDs, blueprints and iconic attachment slots. Existing creations
store record IDs rather than catalogue indices and are not rewritten.

## Local checks

- All 37 presets exist as WeaponItem records in the local native macOS 2.5
  base-game TweakDB. Their relevant record and attachment data also match the
  expansion TweakDB. None of these choices requires Phantom Liberty.
- Attachment profiles were checked against the actual blueprint trees. The
  five supported iconic profiles cover full attachments, no muzzle, no scope,
  no attachments and melee. Guillotine uses the muzzle-only/no-scope profile.
- Preflight checks the selected weapon, blueprint, iconic slot, ability template
  and mod template before generating weapon or localization files. A successful
  response must identify the exact selection; an older or mismatched runtime
  response cannot proceed to generation.
- Native tests cover generation for all 37 presets, category/search filtering,
  empty results, invalid indices, duplicate-name protection, existing files and
  localization keys, preflight ordering and the request/response handshake.
- Runtime tests cover actual 2.5 RTTI metadata, every UI profile, missing and
  invalid prerequisites, failed reloads and exactly-once inventory addition.
- The production ImGui layout was checked at its default 860 × 480 size.
  Controls fit without scrolling; busy and no-result states disable Create.
- The runtime outside the Creator sections is unchanged. Native idle filters
  and compatibility fallback checks still pass.

Reproduce the source-level checks on macOS:

```sh
node tests/creator-catalog.mjs
node tests/creator-names.mjs
node tests/creator-rtti.mjs
node tests/creator-transaction.mjs
node tests/runtime-native-fallback.mjs
```

## Player acceptance

On October 25, 2026, the player reported that the expanded Creator's requested
gameplay checks worked, then separately confirmed save/relaunch persistence,
custom names and Iconic effects, weapon functionality and older creations.

Retained runtime evidence directly confirms one new Dian-based creation with
inventory quantity changing from zero to one. The three older generated weapon
files and their existing localization entries were preserved. Installation also
preserved the 148 checked mod files in the isolated test copy. These observations
do not establish individual gameplay coverage for every one of the 37 bases or
every effect combination.

The accepted test used native macOS Steam game 2.5.0 with the existing combined
VA, Cyberware-EX and Equipment-EX setup. Base-game record presence was checked
offline; a separate gameplay run with Phantom Liberty uninstalled was not done.
The expansion does not change the existing game's save format or migrate saves.
