# Flow: map change

How a character in the world goes to another map instance through a Gate NPC, the town portal or the GM command
`&linkto` (`Zone.Handler`,
`Zone.Link`, `Zone.MapInstance`, `Cluster.WorldManager.zone_of/2`, `Cluster.Sessions.reserve/2`,
`WorldManager.Handler`, `Persistence.save_character/4`). The old Zone connection asks WorldManager for the Zone node
of the target map, saves the player, removes it from its map instance, parks the player struct in the WorldManager
session as the reservation and sends `0x180A`. The client opens a new Zone connection, which redeems the reservation
like a first entry and runs the map entry with the parked struct. A target on the player's own map instance sends
`0x1809` instead, without a reconnect; so does a target on another map instance of the same Zone node whose
`FieldList` machine number is the one of the player's map (the original's "same zone", Z01 §7.1).

```mermaid
sequenceDiagram
    participant C as Client
    participant Z as Old Zone connection
    participant A as Map instance A
    participant W as WorldManager.World
    participant S as Session (WorldManager connection)
    participant P as Persistence
    participant N as New Zone connection
    participant B as Map instance B
    alt gate
        C->>Z: 0x200A {npc handle}
        Z->>A: npc(handle, npc handle)
        A-->>Z: the NPC and the player's position (within 1000 units)
        Z->>C: 0x3C01 "Do you want to move to <name> field?", Yes / No
        C->>Z: 0x3C02 {0} (within 1000 units of where the menu opened)
    else town portal
        C->>Z: 0x181A {index}
        Z->>A: near_npc?(handle, "Gate_Town")
        Note over Z: TownPortal.shn row: 0x19C3 no row, 0x19C4 level too low
    end
    Z->>A: player(handle)
    alt the target is map instance A (0x1809)
        Z->>P: save_character(..., :auto)
        Z->>A: relocate(handle, x, y)
        A->>C: 0x1805 to the players in sight
        Z->>C: (town portal: 0x181B {0x19C1}) 0x1809 {mapIndex, x, y}
        Note over Z: step :loading
        C->>Z: 0x1803
        Z->>C: the 0x1803 burst
        S->>C: 0x5826, 0x182A
    else another map instance
        Z->>W: zone_of(target map)
        alt no Zone node runs it
            W-->>Z: :error
            Z->>C: gate: nothing; town portal: 0x181B {0x19C2} (one info line)
        else map instance B of this node, the same machine number (0x1809)
            W-->>Z: node (this one), host, port
            Z->>P: save_character(..., :auto)
            Z->>B: enter(player at the target position, handle)
            Note over Z,B: handle in use on B: the reconnect below instead
            Z->>A: leave(handle)
            A->>C: 0x1805 to the players in sight
            Z->>C: (town portal: 0x181B {0x19C1}) 0x1809 {mapIndex, x, y}
            Note over Z: step :loading, the map is B now
            C->>Z: 0x1803
            Z->>C: the 0x1803 burst
            S->>C: 0x5826, 0x182A
        else
            W-->>Z: node, host, port
            Z->>P: save_character(..., {:leave, minutes})
            Note over Z: save failed: refused like a missing target (error line)
            Z->>A: leave(handle)
            A->>C: 0x1805 to the players in sight
            A-->>Z: the player (parked struct)
            Z->>S: reserve(character, map, x, y, node, player)
            S-->>Z: the session handle
            Z->>C: (town portal: 0x181B {0x19C1}) 0x180A {mapIndex, x, y, zoneIp, zonePort, wmHandle}
            Note over Z: step :left, stays open until the client closes it
            C->>N: connect, 0x1801 {wmHandle, name, checksums}
            N->>S: redeem(name, node)
            S-->>N: entry kind :map_change (map, x, y, player)
            N->>B: enter(player at the reserved map and position)
            N->>C: the 0x1801 burst (0x1038 ... 0x1802)
            C->>N: 0x1803
            N->>C: the 0x1803 burst
            S->>C: 0x5826, 0x182A
        end
    end
```

## Steps

1. **Gate click** (`0x200A`, step `:in_world`): the map instance steps the player's mover to now and checks that the
   handle is a shown NPC within 1000 units (dist² ≤ 1 000 000, Z02 §6.2); otherwise nothing happens. Only the role
   `Gate` acts: the first `LinkTable` row of its argument with a valid position is the destination. The menu
   `0x3C01` carries the `MapInfo.Name` of the client map, priority 0, the NPC handle, the player's server position,
   `limitRange` 1000 and the entries `{0, "Yes"}`, `{1, "No"}`. The connection keeps the open menu (destination,
   point, NPC name). Asking WorldManager waits for "Yes", as the original does.
2. **Menu answer** (`0x3C02`): `{0}` runs the change when the player stands within 1000 units of the point where the
   menu opened; any other answer closes the menu without a packet.
3. **Town portal** (`0x181A {index}`, step `:in_world`): the player must stand within 1000 units of a shown NPC with
   mob name `Gate_Town` on its map; then the `TownPortal.shn` row of the index (`MapName`, `X`, `Y`, `MinLevel`) is
   the destination, map and client map both `MapName`. In step `:loading` the answer is `0x181B {0x19C2}`.
4. **The change** (`Zone.Link.run/5`), each step only when the one before it succeeded: the `MapInfo` row of the
   client map (its `ID` is `mapIndex`), the current player from the map instance, then (the map instance places
   every arriving player on a free cell, see "Differences"; `0x1809` carries the placed point)
   - the same map instance: an auto-save (`:auto`), `relocate/3` (`0x1805` to the players in sight, the new position,
     mode 0, mover and chat state reset, the handle kept) and `0x1809`; the connection goes back to step `:loading`
     and the client's next `0x1803` runs the burst and the WorldManager burst again. The auto-save timer of the first
     `0x1803` runs on (one timer per connection);
   - another map instance: `Cluster.WorldManager.zone_of/2` (one call, single-node mode too), the save with
     `{:leave, minutes}` (play minutes since the map entry, `logout_at` set as at any leave), `leave/2` on the map
     instance, `Cluster.Sessions.reserve/2` and `0x180A` with the node's `public_host`, its Zone port and the session
     handle. The connection goes to step `:left`: it saves nothing more and stays open until the client closes it.
   - another map instance of this node (the node `zone_of/2` names is this one, `Zone.MapInstance.whereis/2` finds
     the instance) whose first `FieldList` row has the machine number (column `Fiesta`) of the player's map: an
     auto-save (`:auto`, the old map and position), `Zone.MapInstance.enter/3` on the target instance under the
     player's handle (mode 0, the target position, the reset of `Zone.Player.arrive/4`), `leave/2` on the old
     instance (`0x1805` to the players in sight) and `0x1809` on the same connection, which goes back to step
     `:loading` with the target instance as its map. The handle is kept, as the client keeps it. Handles are per map
     instance: when the handle is in use on the target instance (or the target cannot take the player), the change
     falls back to the reconnect above, `0x180A`. Play minutes go on counting on the same connection.
5. **Arrival**: the client connects to the address of `0x180A` (in single-node mode the same address and port) and
   sends `0x1801` with the session handle. The redeem returns an entry of kind `:map_change`; the new connection does
   not load the character from the database but takes the parked struct (`Zone.Player.arrive/4`: the reserved map
   and position, the `FieldList` map type, the new connection, handle, mode 0, direction 90, dimension and sub-layer
   0, no mover, a fresh chat state) and runs the map entry of [`map-entry.md`](map-entry.md). The session does not
   join the character group a second time; it only monitors the new Zone connection.

## The reservation

- It lives in the WorldManager session process (`reservation` of `WorldManager.Handler`, kind `:map_change`, with
  the target map, position, node and the player struct). There is no timer: it ends with the session, with the
  next `0x1001` or with `0x0C18 {1}` (one `info` line; the client went back to the character list between two
  maps, the player is saved already).
- While it is open the session has no Zone connection (the old one is left out at the reserve), so `0x1001` always
  voids the reservation and never answers `0x145`.
- `reserve` is accepted only from the session's current Zone connection. When the session waits in
  `Cluster.Sessions.leave_world/1` for that connection while the connection reserves, the connection answers the
  leave `:ok` (the player is saved and off the map); the session then has no Zone connection and refuses the
  reserve, and the old connection closes with `map change failed: no session`.
- A redeem from another node answers `:wrong_node` (`0x1804 {0x141}`) and keeps it; another character name answers
  `:wrong_character`. Only a success uses it up.
- **The client never arrives**: the player is saved (old map and position) and removed already. When the session
  ends (the client quits or is lost), the reservation goes with the session process; the old Zone connection sees
  the session end and closes. Nothing is on any map.
- `Cluster.Sessions.reserve/2` on a session without a character in the world answers `{:error, :no_session}`.

## Codes

| `0x181B` | Meaning |
|---|---|
| `0x19C1` | accepted; `0x180A` or `0x1809` follows |
| `0x19C2` | cannot be used now: away from a town portal NPC, before `0x1803`, the target map not running, a failed save, no `MapInfo` row, not on the map |
| `0x19C3` | no `TownPortal.shn` row for the index |
| `0x19C4` | the level is below `MinLevel` |

A gate answers nothing on a refusal.

## Server log

| Level | Line | When |
|---|---|---|
| `info` | `Zone: map change: character <id>, map <from> to <to>` | `0x180A` sent, or `0x1809` to another map instance of this node |
| `info` | `Zone: gate <npc> on map <map>: destination <map> is not running` | "Yes" on a gate whose target map no Zone node runs |
| `info` | `Zone: town portal refused: map <map> is not running` | the town portal target no Zone node runs (`0x19C2`) |
| `info` | `Zone: gate <npc> on map <map>: no LinkTable row for <argument>` | a click on a Gate NPC without a usable `LinkTable` row |
| `info` | `Zone: gate <npc> on map <map>: no MapInfo row for <client map>` | a click on a gate whose client map has no `MapInfo` row |
| `info` | `Zone: map change refused: no MapInfo row for <client map>` | a town portal target without a `MapInfo` row |
| `error` | `Zone: map change refused: save failed: character <id>, <reason>` | the save before the change failed; refused (`0x19C2` for a town portal) |
| `warning` | `Zone: map change failed: not on the map` | the player was gone from the map instance |
| `warning` | `Zone: map change refused: no free cell on <map> around (<x>, <y>)` | neither the target point nor the map's regen point has a free cell in reach; refused (`0x19C2` for a town portal) |
| `info` | `Zone: map <map>: no free cell around (<x>, <y>), placed at the regen point` | an arriving player was placed around the map's regen point instead |
| `warning` | `Zone: connection closed: map change failed: no session` | the session ended, or the player went back to the character list, between the save and the reservation; the player is saved and removed |
| `info` | `WorldManager: map-login ticket dropped: back to the character list` | `0x0C18 {1}` while the reservation is open |
| `debug` | `Zone: NPC click dropped: role <role> is not built` | a click on an NPC of another role |
| `debug` | `Zone: server menu answer dropped: too far from where the menu opened` | "Yes" more than 1000 units from the menu's point |

## Differences from the original

- **One call to WorldManager** instead of the original's `0x180B` / `0x180D` / `0x180E` exchange between Zone and
  WorldManager (W01 §7.3).
- **`0x181B` only after WorldManager answered**: the original sends `0x19C1` first and then nothing when the target
  is not running; here a refusal is `0x19C2`.
- **Town portal reach check** (new): `0x181A` is accepted only within 1000 units of a `Gate_Town` NPC; the original
  accepts it anywhere, a free teleport for a modified client (`server/AGENTS.md`, "Untrusted input"). The bug
  register has no id for it.
- **`0x1809` between map instances** needs the same `FieldList` machine number **and** the same Zone node; the
  original needs only the same zone (machine number). A handle in use on the target instance falls back to `0x180A`
  (handles are per map instance here, per zone in the original).
- **The menu texts are constants** (`Script/MenuString.txt` record `LinkTitle`, `Script/ETC.txt` record `Yes`); no
  loader reads `Script/` yet.
- **`&linkto`** is a third origin (`:gm`, flow: [`gm-commands.md`](gm-commands.md)): its target is a point the GM
  names, the `RegenX` / `RegenY` point of `MapInfo`, or a random free cell of the own map (shortcut: rejection
  sampling of at most 100 draws, not the quadtree of `bd_FindEmptyCoord`). A target map that is not running or has
  no `MapInfo` row answers `0x2011` "Invalid map name"; it has no answer packet of its own otherwise.
- **Arrival placement without object spacing**: as the original (`so_MapMarking` → `FieldMap::fm_Marking`), the map
  instance puts an arriving player on the nearest free cell of a spiral of 31 rings at spacing 25 around the wanted
  point (`Zone.Placement`), else around the map's `RegenX` / `RegenY` point. The original also keeps 25 units from
  every other object (`so_collesioncheck`); that test is not built (milestone 4), so there is no x + 25 next to the
  town portal NPC of RouN as in the capture. The regen-point fallback applies here to every arrival; the original
  has it at the map login only. When both searches fail, a change is refused with a `warning` line and the answer
  of its origin (`0x19C2` for a town portal, nothing for a gate or `&linkto`) and the player stays where it is; the
  original disconnects on the same-zone link with `0x685`.
- **Not built**: the NPC menu `0x201C` / `0x201D` (so the real client cannot open the town portal window yet;
  `0x181A` itself is handled), the gate roles `IDGate`, `RandomGate`, `ModeIDGate`, the multi-link `0x181F`, the
  menu close `0x3C0F`.
- **The option pushes** `0x7032` to `0x7034` are not repeated at a map change in the capture `walk-run-portals`:
  after each of the five changes the WorldManager connection sends only `0x5826` and `0x182A`. The rebuild does the
  same: the pushes follow `0x1003` only.

## Not checked

- What the real client shows between `0x181A` and `0x181B`, and for `0x19C2`.
- A reconnect of the real client to the same address and port (single-node mode).
- That the real client closes the old Zone connection itself after `0x180A` (the capture shows it; the replay closes
  it with `close_after:`).
- The real client after a `0x1809` to a different map (captured only inside one map, `&linkto`).
- That `0x1827` need not be sent again after such a `0x1809` (every running map has map type 0).
