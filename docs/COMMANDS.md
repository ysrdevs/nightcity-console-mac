# NightCity Console command reference

Open the Console with **F1** or **`** (backtick). Enter one command at a time
and press **Enter**. Command names are case-sensitive. Use Up/Down for history
and Cmd+V to paste. Type `help` for the commands in your running backend.

The first section documents the **2.0 native backend for Cyberpunk 2077 2.5.0**.
The separate **legacy 2.3.1 backend** is described at the end. See the
[2.0 release notes](RELEASE-2.0.0-PUBLIC.md) for the supported features and mods.

Single-player only. Keep a separate manual save before changing your character,
quest facts or installed gameplay mods.

## Native 2.0: commands and results

Use the mouse to select Console, Items, Quick, Creator, Exploration or Locations.
Keep F1 open until the request's response appears. `PENDING`, `PREPARING` and
`SUBMITTED` mean work was requested, not that its effect has been confirmed.
When instructed, close F1, resume gameplay and use the relevant `check` or
`status` command. If a result says `UNKNOWN`, inspect the game state and export
diagnostics before retrying a command that adds or removes something.

### Items and money

| Command | Effect |
| --- | --- |
| `add Items.Record [quantity]` | Request an item grant. Quantity defaults to 1; range 1 to 1,000. |
| `give Items.Record [quantity]` | Alias for `add`. |
| `money <amount>` | Add 1 to 1,000,000 eurodollars per request. |
| `Game.AddToInventory("Items.Record", quantity)` | Supported CET-style item grant syntax, with the same checks and limits. |
| `remove Items.Record [quantity]` | Request removal of 1 to 1,000 items; default 1. `removeitem` is an alias. |
| `remove status` | Check the last item-removal request. `removeitem status` also works. |

The loaded game must contain the requested item record. Item IDs must be named
`Items.*` records containing letters, digits, dots, underscores or hyphens.
Hashed `<TDBID:...>` syntax is not accepted by the native backend. Giving
`Items.money` uses the money limit. Larger supported requests can finish across
multiple frames; there is no legacy 20-item cutoff in this interface.

Example commands, each entered separately:

```text
add Items.Preset_Ajax_Default 2
money 1000
Game.AddToInventory("Items.Preset_Nue_Default", 1)
remove Items.Preset_Nue_Default 1
remove status
```

Creator designs belong to the game installation; inventory copies belong to a
save. Loading an older save does not delete a design or free its name. Add an
existing design using `give <record ID shown when it was created> 1`. Creating
another design with the same name is refused to preserve its definition.

### Character, time and gameplay controls

| Command | Effect |
| --- | --- |
| `heal` | Request a full heal. |
| `perks [N]` | Add perk points; default 1, range 1 to 1,000. |
| `attrs [N]` | Add attribute points; default 1, range 1 to 1,000. |
| `relic [N]` | Add relic points; default 1, range 1 to 1,000. Requires Phantom Liberty and an available relic system. |
| `level <N>` | Request a character level. The game's proficiency limits are checked before changes. |
| `streetcred <N>` | Request a Street Cred level. `sc` is an alias; game limits still apply. |
| `time <hour> [minute]` | Set time of day; hour 0 to 23, minute 0 to 59, default minute 0. |
| `godmode [on\|off\|check]` | Enable, release or inspect Console invulnerability. No argument means `on`. |
| `infammo [on\|off\|check]` | Enable, release or inspect infinite ammo. `ammo` is an alias. No argument means `on`. |
| `invis on\|off\|check` | Change or inspect detection visibility. `invisible` and `invisibility` are aliases. An argument is required. |
| `nopolice [on\|off\|check]` | `on` disables police response and clears pursuit; `off` releases the Console's disable. No argument means `on`. |
| `police [on\|off\|check]` | Legacy spelling of `nopolice`, with the **same polarity**: `police on` disables police response. |
| `slowmo [factor\|off]` | Set world speed from 0.001 to 5, with at most three decimal places. Default 0.3; `off` restores normal speed. |
| `gameplay status` | Report the Console gameplay-control state. |
| `gameplay reset` | Release the Console's gameplay changes, including invisibility and police disable. |

Level and Street Cred inputs are bounded to 1 to 1,000 by the parser; this is
not a promise that the game supports those levels. Read the operation's result.
Invisibility changes detection behavior; it does not apply optical camouflage.
Police commands do not add wanted stars, spawn police or restore an earlier
pursuit. Use `check` after returning to gameplay to confirm deferred changes.
Reset releases Console-owned changes rather than other mods' effects.

### Positions and saved locations

| Command | Effect |
| --- | --- |
| `pos` / `position` | Report current coordinates when a loaded player is available. |
| `bookmark save <name>` | Save the current position. Names can contain spaces. |
| `bookmark go <name or key>` | Request travel to a saved location. |
| `bookmark list` | List saved locations. |
| `teleport save <name>` | Save a location using a one-word name. |
| `teleport <name>` | Travel to a saved location using a one-word name. |
| `tp <x> <y> <z>` / `teleport <x> <y> <z>` | Request travel to decimal coordinates. Each coordinate must be within +/-1,000,000. |
| `tp check` / `teleport check` | Check travel status. `status` is also accepted. |

Native Locations bookmarks persist across game restarts. Use `bookmark go` for
multiword names, numeric names or reserved words such as `check`. Bare
`teleport` is not a native position/list command; use `pos` or `bookmark list`.

Travel requires an eligible player state and is refused while flight is active.
After `PREPARING`, close F1 and release movement keys as instructed. Confirm
normal walking after arrival. The Locations tab also provides saved-location
controls without typing commands.

### Noclip and third-person camera

| Command | Effect |
| --- | --- |
| `flight start` | Prepare and start flight when the player state permits it. `flight on` is an alias. |
| `flight stop` | Stop at the current destination if there is room. Gravity resumes. `flight off` is an alias. |
| `flight resume` | Resume paused flight when its conditions permit. |
| `flight return` | Return to this flight's starting position and stop. |
| `flight status` | Report flight and restoration status. `flight check` is an alias. |
| `flight speed slow\|normal\|fast\|faster` | Set the base flight speed. |
| `thirdperson` | Request the installed, supported Immersive Third Person mod's camera toggle once. |

`fly` and `noclip` are aliases for the `flight` command prefix and require the
same action arguments. There is no bare flight toggle. `flight validate` and
`flight camera` are legacy diagnostic commands and are not accepted here.

WASD moves, Space rises, Control descends, Shift boosts and Alt/Option slows for
precision. Inventory and app switching pause flight. To land, move above clear
solid ground, descend until your feet are just above it and use Stop here.
Stopping high in the air restores gravity. Stop flight and check normal walking
before saving. See the [flight guide](EXPLORATION.md).

The camera command requires ITP; it does not install or replace the mod. Keep
F1 open for the response, then close it to view the camera. ITP's supported
weapon transition uses first person for aiming. The **Lua mods** tab shows
reported module state and failures. If ITP is disabled after an error, camera
recovery is unverified: quit and restart the game before using third person
again. Reloading a save does not restart a disabled Lua module.

### Quest facts, vehicles and Console output

| Command | Effect |
| --- | --- |
| `getfact <name>` | Read a quest fact. |
| `setfact <name> [value]` | Assign a signed 32-bit integer value; default 1. |
| `addfact <name> [value]` | Alias for `setfact`. It **assigns**, rather than increments, the value. |
| `summon` / `car` | Request your currently selected owned vehicle. Select the vehicle using the game's normal controls. |
| `summonmode` | Toggle the game's summon mode only; it does not request a vehicle. |
| `clear` | Clear Console output. Pending requests are still tracked. |
| `help` | Show the available command list. |

A submitted vehicle request does not confirm arrival. Summoning can be refused
in an unsuitable player state, including while seated in a vehicle. These
commands accept no model ID and do not unlock arbitrary vehicles.

### Native limits

Only the commands above and the reviewed Lua packages in the
[compatibility list](MOD-COMPATIBILITY.md) are supported. Accepting
`Game.AddToInventory` does not imply support for arbitrary `Game.*` calls.
The native Console does not evaluate arbitrary Lua, expose `call`/`sig`, accept
legacy hashed item IDs, or provide `convdump`, `devdump`, `itemdump`, zero-speed
world pause, equip-to-slot or arbitrary NPC/vehicle spawning. Item/quest
availability and game-state checks can refuse an otherwise valid command.

## Legacy backend: Cyberpunk 2077 2.3.1

The retained 2.3.1 backend uses the older command engine. Its behavior is
separate from the native 2.0 interface above. Use its in-game `help` output;
new native commands and checks are not automatically available there.

| Legacy command | Behavior |
| --- | --- |
| `give <Items.Name> <quantity>` | Add items through the legacy grant path. Up to 20 uses individual grants; larger quantities use its bulk path. |
| `give <TDBID:CRC32HEX:LENGTH> <quantity>` | Legacy hashed-record form for known IDs without a named catalog entry. |
| `removeitem <Items.Name> <quantity>` / `remove` | Request item removal. |
| `money <amount>` | Add eurodollars. |
| `Game.AddToInventory("Items.Name", N)` | Selected CET-style item grant syntax. |
| `perks N`, `attrs N`, `relic N` | Add the selected development points, subject to the available game systems. |
| `level N`, `streetcred N` / `sc N`, `heal` | Legacy character controls. |
| `godmode [off]`, `invis [off]`, `infammo [off]` | Enable the respective effect, or disable it with `off`. |
| `time <hour> [minute]`, `slowmo [factor\|off]` | Legacy time controls. |
| `nopolice [off]` / `police [off]` | Disable police response, or restore it with `off`; does not summon police. |
| `teleport` | Print coordinates and legacy bookmarks. |
| `teleport save <name>` / `teleport <name>` | Save/use a legacy bookmark; these bookmarks reset each launch. |
| `teleport <x> <y> <z>` | Request coordinate travel. |
| `setfact <name> <value>` | Assign a quest fact. |
| `call <Class> <method> [args]` | Attempt a resolved, observed RTTI method through the legacy bridge. This does not guarantee arbitrary methods are callable. |
| `sig <Class> <method>` | Print a resolved method signature. |
| `convdump` / `devdump` | Legacy method-signature diagnostics. |
| `itemdump [idfile]` | Legacy catalog diagnostic, using `crc32hex<TAB>length` input rows. Default input `/tmp/cp2077_itemids.txt`; output `/tmp/cp2077_itemdump.tsv`. |
| `clear` / `help` | Clear output / show legacy help. |

The old effects and teleport paths have their own restrictions and do not
provide the native `check`/`reset` result contracts. Noclip and the native Lua
mod support described above are not supplied for game 2.3.1.
