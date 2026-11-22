# Flow: enter the world

From `0x1001` at WorldManager to an accepted `0x1801` at the Zone (`WorldManager.Handler`, `WorldManager.World.zone_of/2`, `Persistence.skip_tutorial/3`, `Cluster.Sessions.redeem/2`, `Zone.Handler`, `GameData.ClientData`). `0x1001` and `0x1111` are accepted only after the login of the WorldManager connection (`0x0C0F`). Login takes no part.

```mermaid
sequenceDiagram
    participant C as Client
    participant M as WorldManager connection (session)
    participant P as Persistence
    participant W as World process
    participant Z as Zone connection
    participant I as Map instance
    C->>M: 0x1001 {slot}
    alt a Zone connection of the session lives
        M->>C: 0x1002 {0x145}
    else slot above 5
        M->>C: 0x1002 {0x143}
    else
        M->>P: list_characters(world, user_no)
        alt empty slot
            M->>C: 0x1002 {0x31EB}
        else database fails
            M->>C: 0x1002 {0x145}
        else tutorial state 0
            M->>C: 0x1110 {0}
            alt 0x1111 {0} ("yes")
                C->>M: 0x1111 {0}
                M->>C: 0x1002 {0x145}
            else 0x1111 {1} (skip)
                C->>M: 0x1111 {1}
                M->>P: skip_tutorial(world, user_no, slot): state 2
                Note over M: continues with the map-table lookup (stored map)
            end
        end
        M->>W: zone_of(world, stored map)
        alt map not running
            M->>C: 0x1002 {0x145}
        else
            Note over M: reservation (map-login ticket) for this character and Zone node
            M->>C: 0x1003 {zone_ip, zone_port}
        end
    end
    C->>Z: connect to the Zone node
    C->>Z: 0x1801 {wm_handle, char name, 49 checksums}
    alt Client data check: a checksum differs
        Z->>C: 0x1804 {0x147, index}, close
    else
        Z->>M: redeem(wm_handle, name) (call to every session with the handle)
        alt no session / no ticket / another Zone node
            M-->>Z: refusal
            Z->>C: 0x1804 {0x141, 0xFF}, close
        else not the reserved character
            M-->>Z: refusal
            Z->>C: 0x1804 {0x590, 0xFF}, close
        else
            M-->>Z: entry (first entry); the ticket is used up
            Note over M,Z: monitor each other: the end of the Zone connection frees the session for a new 0x1001, the end of the session closes the Zone connection
            Note over Z,I: hand-over to the map instance and the map-entry burst: issue 108
        end
    end
```

## Codes

| Code | Packet | When | Client text |
|---|---|---|---|
| `0x143` | `0x1002` | slot above 5 | not checked |
| `0x31EB` | `0x1002` | empty slot (W01-B6 kept) | not checked |
| `0x145` | `0x1002` | map not running, a Zone connection of the session lives, "yes" to the tutorial, database failure | "The Map is under maintenance" (captured, `docs/protocol/README.md`); the client stays on character select |
| `0x147` | `0x1804` | Client data check failed; the second byte is the index of the table | "The client has been illegally manipulated…" |
| `0x141` | `0x1804` | no session for the handle, no open ticket, ticket for another Zone node | not checked |
| `0x590` | `0x1804` | the name is not the reserved character | not checked |

## Reservation and ticket

- `0x1003` leaves a reservation in the session: character, stored map and the Zone node that runs it. The open reservation is the unused map-login ticket; the client presents it with `wm_handle` and the character name. It has no timer.
- The session joins the `:pg` group `{:wm_handle, handle}` at world login. The Zone asks every member (`Cluster.Sessions.redeem/2`); the name and the node decide, so a handle that repeats after 65536 logins is harmless.
- Only a successful redeem uses the ticket up. A wrong name or a wrong node leaves it, so a stranger cannot void it.
- A new `0x1001` voids an open reservation and an open tutorial question. A `0x1111` without an open question is ignored.

## Client data check

The client sends the MD5 (lower-case hex text) of 49 of its tables, each over the whole file with its body (from offset 0x24) decrypted with the SHN cipher. The Zone node hashes its own copies the same way at start (`GameData.load_client_checksums/1`, only with the Zone part) and compares the 49 pieces in order; the first difference is refused. The files, index 0 to 48, relative to the data directory (`GameData.ClientData.files/0`):

`shn/AbState.shn`, `shn/ActiveSkill.shn`, `shn/CharacterTitleData.shn`, `shn/ChargedEffect.shn`, `shn/ClassName.shn`, `shn/Gather.shn`, `shn/GradeItemOption.shn`, `shn/ItemDismantle.shn`, `shn/ItemInfo.shn`, `shn/MapInfo.shn`, `shn/MiniHouse.shn`, `shn/MiniHouseFurniture.shn`, `shn/MiniHouseObjAni.shn`, `shn/MobInfo.shn`, `shn/PassiveSkill.shn`, `shn/Riding.shn`, `shn/SubAbState.shn`, `shn/UpgradeInfo.shn`, `shn/WeaponAttrib.shn`, `shn/WeaponTitleData.shn`, `shn/MiniHouseFurnitureObjEffect.shn`, `shn/MiniHouseEndure.shn`, `shn/DiceDividind.shn`, `shn/ActionViewInfo.shn`, `shn/MapLinkPoint.shn`, `shn/MapWayPoint.shn`, `shn/View/AbStateView.shn`, `shn/View/ActiveSkillView.shn`, `shn/View/CharacterTitleStateView.shn`, `shn/View/EffectViewInfo.shn`, `shn/View/ItemShopView.shn`, `shn/View/ItemViewInfo.shn`, `shn/View/MapViewInfo.shn`, `shn/View/MobViewInfo.shn`, `shn/View/NPCViewInfo.shn`, `shn/View/PassiveSkillView.shn`, `shn/View/ProduceView.shn`, `shn/View/CollectCardView.shn`, `shn/View/GTIView.shn`, `shn/View/ItemViewEquipTypeInfo.shn`, `shn/SingleData.shn`, `shn/MarketSearchInfo.shn`, `shn/ItemMoney.shn`, `shn/PupMain.shn`, `shn/ChatColor.shn`, `shn/TermExtendMatch.shn`, `shn/MinimonInfo.shn`, `shn/MinimonAutoUseItem.shn`, `shn/ChargedDeletableBuff.shn`.

## Log lines

| Level | Part | Line |
|---|---|---|
| `info` | WorldManager | `character login refused: map <map> is not running` |
| `warning` | WorldManager | `character login failed, database failure`, `tutorial skip failed, database failure` |
| `warning` | Zone | `connection closed: Client data check failed: character "<name>", table <table>, server <hash>, client "<hash>"` |
| `info` | Zone | `connection closed: map login refused: <reason>`, `map login accepted: character <id>, map <map>`, `connection closed: session ended` |

Slot above 5, empty slot, "yes", a skip whose character changed in the meantime and "already in the world" write no line: they are refusals with an answer, like the rename refusals.

The three WorldManager lines are written before their `0x1002` is sent. Telemetry: the handling of each packet of this flow is a `[:pinata, :packet]` span (`part`, `opcode`; see [`telemetry.md`](../telemetry.md)); a close has no event of its own, here as in the rest of the server. Issue 96 rules one out for the Client data check.

## Original-server bugs

- P02-B33 fixed narrowly: the character list still says "RouT" for tutorial state 0 and `0x1110` is still asked; a skip saves state 2 and enters the world on the stored map.
- P02-B28: the byte of `0x1110` the original leaves unwritten is sent as 0 (masked in replays).
- Z01-B1 fixed: a refused map login carries the real refusal code (`0x141`, `0x590`).
- W01-B6 kept: `0x1001` for an empty slot answers `0x31EB`.
- P02-B43 does not exist here: a missing or truncated file of the Client data check stops the start of the node with a message.

## Differences from the original

No `0x104B` / `0x101C` round trip to the Character server and no `0x0C1A`. No `0x111D` (tutorial map). The WorldManager option pushes `0x7032` to `0x7034` after `0x1003` are not sent yet. An accepted `0x1801` sends nothing yet (issue 108).

## Not checked

What the client shows for `0x141` and `0x590`, and the text of `0x147` during a map change.
