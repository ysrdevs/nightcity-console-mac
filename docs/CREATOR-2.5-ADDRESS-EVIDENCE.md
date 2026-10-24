# Creator localization on macOS game 2.5

Assessed 2026-10-24 from the retained Steam arm64 binaries. No game binaries are distributed here.

| Fixture | SHA-256 |
|---|---|
| 2.3.1 | `864387f4c47444942f5c7d7e9bc2eb9235e82ca2d411a63b0844a281df0a0bf3` |
| 2.5.0 | `1d3c32db2fa9150b9c164eaea1fe678b99d244e705de737999a932487a63bcee` |

Addresses below are RVAs relative to the main executable image. The on-disk virtual address is
`0x100000000 + RVA`; these fixtures map `__TEXT` at file offset zero.

| Function | 2.3.1 RVA | 2.5 RVA |
|---|---|---|
| Localization map lookup | `0x2f6ea14` | `0x1c331f4` |
| Inner numeric localization lookup | `0x2f6e76c` | `0x1c32f4c` |
| PoolString CString reserve | `0x2c904` | `0x2c7e4` |

The localization map function was found using exact masked instruction fragments, then checked
against the complete disassembly. Its first 12 instructions give a unique match after masking
the PC-relative ADRP. Its 32-instruction key-hash and bucket-lookup fragments also match uniquely;
their position moved by `-0x30` because the newer compiler placed the early-return epilogue at the
end. This explains why a single full-function signature failed.

Both versions preserve the same arguments in their prologue:

```text
mov x20, x3       # address of the found boolean
mov x21, x2       # lookup parameter forwarded unchanged
mov x23, x1       # numeric localization key
mov x22, x0       # localization map
mov x19, x8       # indirect CString result
```

Both call their inner numeric-key lookup with the original arguments first, test `*x20`, then
hash all eight bytes of `x23` with FNV-1a and probe the same map layout. A successful fallback
forwards `x2/x3` unchanged and copies a temporary CString into `x19` before destroying the
temporary. The 2.5 function starts at `0x101c331f4` and returns at `0x101c33360`.

The first 44 bytes are identical in both localization functions:

```text
ffc301d1 f85f03a9 f65704a9 f44f05a9 fd7b06a9 fd830191
f40303aa f50302aa f70301aa f60300aa f30308aa
```

PoolString reserve has a unique exact masked match for 16, 32, 48, and 64 instructions. Its first
44 bytes are also identical:

```text
ff0301d1 f65701a9 f44f02a9 fd7b03a9 fdc30091 f40301aa
f30300aa 3f500071 83010054 e00313aa 088c41f8
```

The runtime requires the existing game-build RTTI fingerprint **and** both local 44-byte
fingerprints before installing the localization hook. CString byte lengths are measured in
UTF-8, with strings below 20 bytes stored inline and longer strings grown using the game's own
PoolString allocator.

## Creator integration

On 2.3.1, reload continues through `cybermodman_tweakReload`. On 2.5, it resolves the registered
static native `TweakXL.Reload()` through the existing script executor. The latter returns void
and catches/logs import errors internally, so returning from it is not a success signal.

### Native record lookup registration

The first manual 2.5 Creator test reached the player and transaction system, then failed its
inventory-interface check. The cause was an incorrect assumption that TweakDB record accessors
must occupy `CClass.staticFuncs`. The 2.5 RTTI dump (UUID `7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC`)
places `gamedataTweakDBInterface.GetWeaponItemRecord` and `GetItemRecord` in `CClass.funcs` at
`+0x48`; its `staticFuncs` at `+0x58` is empty. The script alias `TweakDBInterface` is absent from
that native class map. `gameTransactionSystem.GiveItem` and `GetItemQuantity` are also present.

The game's registration initializer at RVA `0x32b05e4` supplies the weapon-record wrapper at
`0x32afc80` to `CClassFunction_ctor` (`0x109b8a4`) with input flags `w6=0`, then registers it through
`0x10c3e9c` in `funcs`. The wrapper ignores incoming `x0`, keeps the script frame from `x1` and result
address from `x2`, reads one eight-byte TweakDBID, calls the global getter at `0x2310df0`, and writes
a sixteen-byte reference handle. It does not require a TweakDBInterface instance. However, the
executor checks the static flag at `0x1099c44`: its nonstatic path retrieves the context at
`0x109d20c`, and the null check at `0x1099c80` sends a null context through a class fallback at
`0x1099d60`. A live menu probe confirmed that null context faults before the accessor is reached.
Creator now passes its resolved player to the executor. The menu probe borrows the immediate
outer executor invocation's context, without caching it for later calls. Both check the actual
one-TweakDBID signature, without treating array placement as a static-call requirement. The
universal resolver's classification is unchanged.

`creatorprobe` is available at the main menu. It prints the real array placement, function flags,
parameter and result type hashes, and relevant capture state. It then reads
`Items.Preset_Lexington_Default` through the same accessor used by Creator. It does not reload
tweaks or give an item. This live probe must succeed before repeating the complete Creator test.
Missing runtime dependencies now identify the particular class/method or captured instance;
opening inventory is suggested only for missing transaction/ItemID capture.

`tests/data/creator-rtti-2.5.json` is a small projection of the pinned SDK's real dump, with its
source SHA-256. `tests/creator-rtti.mjs` runs the actual runtime resolver and Creator preflight
against those array placements. Native calls remain test boundaries, so this catches the false
static-table rejection without pretending to establish live engine execution.

### Inventory query identity

The next manual test created a working weapon, but the UI reported an inventory-confirmation
timeout. Quantity checks were constructing a new `ItemID.FromTDBID` every time. That is an item
instance constructor, not a query for all instances of a record.

In the retained 2.5 binary, the `FromTDBID` wrapper at RVA `0x1712e68` calls constructor
`0x1712090` with seed `-1`. For unique weapons, the path at `0x1712198`–`0x17121cc` generates a
new random seed of at least 3. The `CreateQuery` wrapper at `0x1713184` instead writes the TDBID
followed by the 64-bit value 1: `rngSeed=1`, with counter/structure/flags zero. The inventory
matcher at `0x1712b68` compares only the TDBID's CRC and length when either seed is 1; otherwise
it also compares seed, unique counter and flags. `GetItemQuantity` reaches that matcher through
`0x21aa3f8` → virtual slot `0x2f8` → `0x21aa51c` → `0x2156f38` → `0x2157098` → `0x2157298`.

Creator now resolves native static `gameItemID.CreateQuery(TweakDBID)`, validates its signature,
and caches the resulting query for all before/after quantity checks. `FromTDBID` is called only
for the one item given. The success condition remains an observed quantity increase. Logs and
acknowledgements include the before/after count, query ItemID bytes and given ItemID bytes; count
polls log only when the value changes. Timeouts preserve the latest observed inventory evidence
and never repeat GiveItem.

The RTTI integration regression models the verified unique-seed/query-seed matching rule. It
runs the actual Creator context code and checks quantity 0 → GiveItem once → quantity 1 on
repeated reads, with exactly one query construction and one instance construction. This would
reject the previous fresh-FromTDBID polling behavior. Live acknowledgement and persistence
verification remain separate from that regression.

The overlay sends a dedicated JSON request to `/tmp/cp2077_creator_request.json`. It includes a
unique ID, current game PID, operation (`check` or `apply`), and a 20-second deadline. Apply also
includes the generated record and three localization keys. The runtime processes requests on
its engine executor queue. It verifies the record after reload, sends GiveItem once, and only
acknowledges success after GetItemQuantity increases. A delayed confirmation reads inventory
again and never repeats GiveItem. Replies in `/tmp/cp2077_creator_response.json` carry the same
request ID. Expired requests and requests from an earlier process cannot apply to a new game.

No live success is claimed by the offline tests. The full acceptance sequence is:

1. Boot with the intended loader and TweakXL, then load a save. Confirm ordinary console commands.
2. Verify a minimal cloned weapon YAML loads at boot and gives a real inventory item.
3. Create a distinct YAML after loading the world; call TweakXL.Reload and verify a typed weapon
   record and inventory quantity increase without restarting.
4. Use the Creator UI with a distinct name, white flavor text, gold text, and selected effects.
   Confirm the success message matches inventory, then inspect name, both descriptions, rarity,
   iconic state, equip behavior, and effects. Include a name/description containing non-ASCII text.
5. Restart and verify the saved custom weapon and text persist.
6. Verify missing TweakXL, missing player, invalid YAML, and unavailable localization fail visibly
   without claiming success or giving a duplicate item.

Offline verification:

```bash
node tests/creator-transaction.mjs
node tests/creator-transaction.mjs --fixtures /path/to/retained/game-builds
node tests/creator-names.mjs
node tests/creator-rtti.mjs --rtti /path/to/RED4ext.SDK/data/rtti_layout_macos_25.json
node --check runtime/red4ext_hooks.js
```

The transaction tests cover rejected/failed imports, an existing record, delayed inventory
confirmation, duplicate request IDs, timeout before dispatch, timeout after GiveItem, missing
localization, and a request from an older game process. The optional fixture check reads only
the retained binaries and compares the hook/allocator fingerprints.
The macOS names test compiles the actual Foundation-backed file helpers and verifies existing
keys, quoted flavor text, Unicode text, and preservation of malformed user files.
