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
node --check runtime/red4ext_hooks.js
```

The transaction tests cover rejected/failed imports, an existing record, delayed inventory
confirmation, duplicate request IDs, timeout before dispatch, timeout after GiveItem, missing
localization, and a request from an older game process. The optional fixture check reads only
the retained binaries and compares the hook/allocator fingerprints.
The macOS names test compiles the actual Foundation-backed file helpers and verifies existing
keys, quoted flavor text, Unicode text, and preservation of malformed user files.
