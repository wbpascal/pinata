# Sight

Who sees whom on a map instance, and the packets that follow from it (decided in issue 90). The code is
`Zone.Grid` (the range queries), `Zone.Sight` (the rules, pure functions) and `Zone.MapInstance` (state and
delivery). Flows: [`flows/sight.md`](flows/sight.md), [`flows/map-entry.md`](flows/map-entry.md).

## The rule

An object is in sight of another when all three hold:

- **Distance:** `dist² < Sight²`, with `Sight` the column of the map's `MapInfo` row (128 maps 1600, the others 2000
  to 6000). A map without a row (`RouCos04` in the 2016 data) gets 0, as in the original (`so_FieldSightSquar` @
  FUN_0043c330): nobody is in sight there, except at map entry: a player standing on exactly the same point as the entrant is still sent, because the entry test is `dist² <= r²` (step 2 of the entry exchange below).
- **Dimension:** both in the same dimension, or one of them in -1. Default 0 (`Zone.Player.dimension`,
  `Zone.Npc.dimension`).
- **Sub-layer**, one way (`Zone.Sight.sees?/2`): table `SendMyBrief` of
  `Files/Server/2016/9Data/Shine/World/SubLayerInteract.txt` (`sublayerview.sli_Interactive`, `DAT_0d67a118`).
  Row = the sub-layer of the object shown, column = the sub-layer of the receiver; 1 = shown. 0 Base,
  1 RangerStealth, 2 Observer, 3 AdminHide, 4 GMDoor, 5 GMPlayer:

  | shown \ receiver | 0 | 1 | 2 | 3 | 4 | 5 |
  |---|---|---|---|---|---|---|
  | 0 | 1 | 1 | 1 | 1 | 0 | 1 |
  | 1 | 0 | 0 | 0 | 1 | 0 | 1 |
  | 2 | 0 | 0 | 0 | 1 | 1 | 1 |
  | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
  | 4 | 0 | 0 | 0 | 0 | 0 | 0 |
  | 5 | 1 | 0 | 0 | 0 | 1 | 1 |

  The table is in the code; the file is not read at start-up.

Dimension and sub-layer are set by the GM commands `&hide`, `&show` and `&dimension` (`Zone.MapInstance.action/3`,
with their packets; `&dimension` runs the exchange of "Dimension change" below; flow: [`flows/gm-commands.md`](flows/gm-commands.md)) and by `Zone.MapInstance.set_layer/4`
(sends nothing). A map change resets both to 0 (`relocate/3` for a `0x1809`, a fresh entry otherwise) without a
packet. The registered layer and "hide except me" are not represented. A player in mode 0
(between `0x1801` and `0x1803`) is in the grid and counts for the crowd figure, but receives nothing and is shown to
nobody. An NPC without `MobInfo` row is not shown.

## `Zone.Grid`

A uniform grid inside the map process: object handles by square cell, the cell size is the map's sight radius (1600
for a map with radius 0), so a query at the sight radius reads 3 × 3 cells. `Zone.Grid.query/4` is the only function
that reads the cells; it returns the handles with `dist² < r²` other than the centre object.

The result is in the original's order (`Zone.Grid.walk_order/3`): the original walks its y-sorted object list from the
centre object first towards smaller y, then towards larger y (`so_AllOfRangeNomal` @ FUN_0054c900, `so_AllInMapNomal`
@ FUN_0054be00). The capture `idle_in_world` confirms it: the player at y 9844 gets NPCs with y 9821, 8999, … 4370,
then 9934, 10005, … 10579. Objects with equal y lie in descending handle order: three captures (`walk-run-portals`
294 and 520, `stale-tutorial-rename-kickout-shn`) show the NPCs at y 7862 of RouVal01 seen from below as 17289, 17226,
17225, the order of a list that keeps a later insert before equal keys. Beyond that the original's order of equal keys
depends on the history of its list (players inserted later) and is not reproduced.

**Cost.** `test/zone/grid_test.exs` puts 1500 players on a fixed lattice over a 20 000 × 20 000 map (x = i · 7919 mod 20 000, y = i · 104729 mod 20 000; deterministic, not random) with cell 1600 and compares
every query at radius 1600 with a brute-force filter. Measured on 2026-11-22 (Apple M1 Pro, Erlang/OTP 29, Elixir
1.20.5, `PINATA_BENCH=1 mix test test/zone/grid_test.exs`): **4.9 µs** mean per query. The test fails above 1000 µs.
Many players on one spot cost more: every query then reads one full cell and every step reaches all of them (issue 90
accepts this). The benchmark does not measure that case; it belongs with the movement issues (110, 113 to 115).

## Map entry (`0x1803`)

`Zone.Sight.entry/2` (`so_ExchageBriefInfo` @ FUN_00441460), run by `Zone.MapInstance.login_complete/2` once the
player is in mode 1:

1. **Crowd shrink** (`cbd_DistanceSquar` @ FUN_0043e740): `n` = number of objects of any kind with `dist² < 500²`
   around the entrant, the entrant not counted. Below 29 the radius `r` is the map's; from 29 on
   `r = min(1600, trunc(√(75,000,000 / min(n, 528))))` (29 gives 1600, 30 gives 1581, 528 and more give 376).
2. **Candidates:** every shown NPC of the map, without a distance limit, and every player in mode 1 with
   `dist² <= r²`. The NPCs are not limited by distance because the capture says so, against the issue text
   ("crowd-shrunk radius" for all): `so_BriefInfoRange` returns 1 (no limit) for `ShineNPC` and 3 (the crowd-shrunk
   radius) for players and mobs, and `idle_in_world` shows all 29 NPCs of `RouN`, up to 5474 units away, with
   `Sight` 1600.
3. **Walk** the candidates in walk order. An NPC the entrant sees goes into the NPC batch; a player that sees the
   entrant gets one `0x1C06` of the entrant, and a player the entrant sees goes into the player batch.
4. **Batches** (`bixc_Exchange` @ FUN_0043fd00, `bixm_Exchange` @ FUN_0043fe40, `bixall_Send` @ FUN_0043fc80): a
   batch that already holds 28 elements is sent before the 29th is added; after the walk the rest of the player batch
   (`0x1C07`) goes out, then the rest of the NPC batch (`0x1C09`). With 29 NPCs and one player the entrant gets
   `0x1C09` (28), `0x1C07` (1), `0x1C09` (1), as captured in `26_11_21_45` and `26_11_21_52`.

The entrant's packets go into the second map-entry burst directly after `0x583A` (`Zone.MapEntry.login_complete/2`).

## Appear packets

- **Player** `0x1C06` (`Zone.Sight.brief/1`, 235 bytes): handle, name, position, direction, mode (the stance, 1 or
  2), class, look,
  the item id of each worn item in the 20 slots of `WorldManager.Avatar` (0xFFFF for an empty one) with the upgrades
  of right hand, left hand, leg, body and shoes, polymorph 0xFFFF, the player's emote state as emoticon (`{0xFF, 0}` in
  the entrant's own appear of the entry exchange, `{0xFF, 0xFFFF}` once cleared, `{id, frame}` during an emote;
  [`flows/actions.md`](flows/actions.md)), type 2, no mover
  (0xFFFF, slot 0x0A), Kingdom Quest team type 2, level; title, guild and the 99 abstate bytes are 0 until their
  milestones. Checked against the captured `0x1C06` of capture 14 (`test/zone/sight_test.exs`).
- **NPC** `0x1C08` (`Zone.Npc`, 149 bytes, built once at instance start): mode 2, the mob id of the `MobInfo` row of
  the NPC's mob name, position, `Direct / 2` truncated towards zero plus 180 when negative, Kingdom Quest team type 2.
  A gate (`Gate`, `IDGate`, `ModeIDGate`, `RandomGate` with a `LinkTable` row) has flag state 1 and the client map of
  the first `LinkTable` row of its argument in the flag, with byte 36 of the flag set to 0x08
  (`NPCRole_Portal::nrb_BriefInformSet` @ FUN_004c2360, `so_SetGateBriefInform` @ FUN_00557bc0). The replay of
  `idle_in_world` compares all 29 elements byte for byte.

The appear of a player that has a remembered move (`Zone.Player.move`, set by an accepted walk or run, forgotten by a
stop) is its `0x1C06` followed by that move packet (`0x2018` / `0x201A`) with `from` = its current position
(`ResendLastMove` @ FUN_005555e0), so a client that sees it appear also sees where it goes
([`movement.md`](movement.md)). The move stays remembered after the mover reached its goal.

## Step

`Zone.MapInstance.step/3`, the one way a position changes (each slice of the mover, a pull-back), computes, from the
old and the new position and without any per-player "seen" list (`Zone.Sight.step/3`):

- **appears**: for each shown object within the radius of the new position that was not within the radius of the
  old one: a player gets the mover's appear when it sees the mover, the mover gets the object's appear when it sees
  the object (an NPC only this way);
- **disappears**: for each player in mode 1 within the radius of the old position that is not within the radius of
  the new one: `0x1C0E` both ways, each when that side saw the other. NPCs are never removed by a move.

Appears go out before disappears on one step. The mover's own appear carries its position **before** the step: the
original sends it before it sets the position (capture 45: B is shown at a point 1602 units from A, radius 1600).

## Leave

A player that leaves the map instance (`leave/2`, or the end of its connection) is announced with `0x1805 {handle}`
to the players in mode 1 that see it within the full radius. This goes through the private
`Zone.MapInstance.broadcast/3`, the one "to players in sight" function, which the chat, emote and move relays of later
issues use too.

## Dimension change

`Zone.Sight.dimension/3` returns the deliveries of `&dimension <n>` of a player in mode 1, computed once from its
sight under the old number and under `n`, in this order:

1. `0x1805 {handle}` to every player that saw it under the old number (also when `n` is the same);
2. one delivery to the player itself: the `0x1C0E` of every object it saw and no longer sees, then the appear packets
   of every object it sees only now (players in grid order, then NPCs by handle); left out when both are empty;
3. its own appear (with the new number) to every player that sees it under `n`.

Players count in mode 1 within the full radius; NPCs count without a distance limit, as in the entry exchange, which
shows every NPC of the map. No "seen" list is needed: both sights follow from the rule. An object whose sight does
not change gets nothing more, so the same number again sends `0x1805` and then the appear to the players that see
the player, and nothing to the player. A hidden GM (sub-layer 3) is shown to nobody, so only it gets packets.
`Zone.MapInstance.set_layer/4` still sends nothing. The original instead called `so_Logout` and left the rest to its
per-step storm (`ac_Dimension` @ FUN_0041a5a0, P02-B27).

## `0x1C01`

The client asks for the appear packet of a handle it does not know. In the world, `Zone.Handler` asks the map instance
(`Zone.MapInstance.inform/3`); the client's own handle field is ignored (the connection's player is the requester). The
answer is the object's appear packet when the requester is in mode 1, the object is a shown player or NPC other than
the requester, `dist² < Sight²` and the requester sees it; for a player with a remembered move the answer is both
packets of its appear. Anything else (unknown handle, the requester itself, a
player in mode 0, an object out of sight or hidden) gets no answer, no log line, and the connection stays open: the
unmodified client can send all of these. There is no rate limit; the original has none and each request is one cheap
call.

## Original-server bugs

- **P02-B27 fixed:** objects in different dimensions are not in sight; the original sent an appear and a delete
  packet on every step; a dimension change sends one exchange instead.
- **`0x1C01` in-sight check added:** the original answered for any object of the map (decided in issue 90). Z02-B3 is
  not reachable without abstates.
- **Z09-B13** cannot occur: nothing here keeps a per-player list of seen objects.
