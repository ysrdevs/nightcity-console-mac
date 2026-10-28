# NightCity Console - command reference

Toggle the in-game console with **`` ` ``** (backtick/tilde) or **F1**. Type a command and press **Enter**.
Use **↑/↓** for history and **Cmd+V/C/X/A** for clipboard. Type `help` in-game for a quick list.

> Single-player only. Back up your saves before experimenting.

## Items & money
| Command | Effect |
|---|---|
| `give <Items.Name> <qty>` | Add an item. qty ≤ 20 -> distinct instances (weapons); > 20 -> one bulk stack. |
| `removeitem <Items.Name> <qty>` | Remove an item. |
| `money <amount>` | Add eddies. |
| `Game.AddToInventory("Items.Name", n)` | **CET copy-paste** - works verbatim from any CET guide. |

Item IDs are the same `Items.*` TweakDB names CET uses, so codes you find online work here.
Items whose name string is not known (some records added in game patches) use CET's hashed form, e.g.
`give <TDBID:7495DECE:17> 1`; the Items tab lists them that way.

## Character
| Command | Effect |
|---|---|
| `perks <N>` | Add N perk points. |
| `attrs <N>` | Add N attribute points. |
| `relic <N>` | Add N relic points. |
| `level <N>` | Set character level. |
| `streetcred <N>` | Set street cred level (alias `sc`; 1-50). |
| `heal` | Refill health to full. |
| `godmode [off]` | Toggle invulnerability - no damage at all, including fall damage. |
| `invis [off]` | Toggle invisibility - cameras and enemies can't see you. |
| `infammo [off]` | Toggle infinite ammo. |
| `time <h> [m]` | Set the in-game time of day (24h). |
| `slowmo [factor\|off]` | Slow motion (default 0.3x; e.g. `slowmo 0.1`). |
| `nopolice [off]` | Disable / re-enable the police response. |

## World
| Command | Effect |
|---|---|
| `teleport` | Print your current coords + saved bookmarks. |
| `teleport save <name>` | Bookmark your current position (resets each launch). |
| `teleport <name>` | Teleport to a saved bookmark. |
| `teleport <x> <y> <z>` | Teleport to absolute coords. |
| `setfact <name> <value>` | Set a quest fact flag. |

## Noclip flight (1.8, game 2.5 only)

The **Exploration** tab provides these controls. See the [flight guide](EXPLORATION.md) for movement, landing and pause behavior.

| Command | Effect |
| --- | --- |
| `flight start` | Prepare automatically from clear, grounded standing/crouching, then start after F1 closes. |
| `flight stop` | Stop at the current destination when the standing player has enough space. Normal gravity resumes. |
| `flight resume` | Resume a paused flight after closing menus/F1 and releasing movement keys. |
| `flight return` | Return to this flight's starting point if clear, restore normal collision and stop. |
| `flight status` | Report current flight and restoration status in Console. |
| `flight validate` | Request an optional readiness diagnostic; this is not required before Start. |
| `flight camera` | Record an optional short camera-input diagnostic for troubleshooting. |

WASD moves, Space ascends, Control descends, Shift boosts and Alt/Option slows for precision. Open **Exploration → Flight speed** to change the base speed. Inventory and app switching pause in place. Stop just above clear ground before saving; stopping in the air resumes falling.

## Power tools
| Command | Effect |
|---|---|
| `call <Class> <method> [args]` | Invoke any **observed** RTTI method (args auto-marshalled). |
| `sig <Class> <method>` | Print a method's signature. |
| `convdump` / `devdump` | Diagnostics - dump method signatures. |
| `itemdump [idfile]` | Resolve TweakDB item IDs (`crc32hex<TAB>length` per line, default `/tmp/cp2077_itemids.txt`) to display name, item type and quality in `/tmp/cp2077_itemdump.tsv`. Used to extend the item catalog after a game patch; works from the main menu. |
| `clear` / `help` | Clear scrollback / list commands. |

## Notes & known limits
- **godmode / invis**: applied as player status effects (`BaseStatusEffect.Invulnerable` / `Cloaked`) and
  reapplied on a tick so they survive scene/vehicle transitions. Godmode blocks all damage including falls.
  Invisibility breaks line-of-sight and camera detection; physically bumping into an enemy still alerts them.
- **teleport** is blocked by the game during active combat; bookmarks are session-only.
- **Quest-gated items** (e.g. `Items.mq007_skippy`) won't commit without the relevant quest active.
- **Deferred / contributions welcome**: real vehicle summon, equip-to-slot, NPC/vehicle spawn.
