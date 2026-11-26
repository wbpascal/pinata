# Movement

Walking (`0x2017`), running (`0x2019`) and stopping (`0x2012`) of a player on a map instance: `Zone.Handler` passes
the request to `Zone.MapInstance.move/5` or `stop/3`, the map instance checks it against its own position of the
player and the block data (`GameData.BlockData`), moves the player with a server-side mover (`Zone.Mover`) and sends
the packets. Sources: `docs/pseudocode/zone/Z02-actions.md` §2, `Z09-world.md` §9.1, §9.2, §9.6; capture 45 and
`walk-run-portals`. Flow: [`flows/movement.md`](flows/movement.md).

## Walk and run request

The request carries `from` (where the client shows the player) and `to`. Only in the world (step `:in_world`, mode 1);
before that the packet gets no answer. The map instance first steps the running mover to the clock's millisecond (see
"Exact step"), then checks with the server position `pos`, in this order:

1. `from == to`: refused;
2. `dist²(pos, from) >= 40 001` (200 units or more), or no free cell in the 3 × 3 cells around `to`
   (`BlockData.free_cell?/3`; outside the map is blocked), or none around `pos`: refused;
3. the straight line from `pos` to `to` has two blocked steps in a row (`BlockData.line_blocked?/4`): refused;
4. accepted. When `to != pos` the direction becomes `Zone.Mover.direction/2` of `to - pos` and a new mover starts from
   `pos` at walk speed (33, `ChrCommon.WalkSpeed`) or run speed (127, `ChrCommon.RunSpeed`). When `to == pos` the
   direction and a running mover stay. The move packet `0x2018` (walk) / `0x201A` (run) `{handle, from = pos, to,
   speed, moveattr = 0}` is remembered on the player and sent to the players in sight (`Zone.Sight.receivers/2`).

The order keeps the line walk bounded: it runs only when both ends lie inside the map, so any `u32` a client writes is
safe. No speed check of our own, no rate limit beyond the connection's packet rate.

A **refusal** runs the stop block check (below), then sends `0x201B {pos}` to the player. It does not stop a running
mover. No log line: the unmodified client produces refused moves (it sends `from == to`, see `walk-run-portals` file
line 701), and the answer is the original's.

An accepted move clears the emote state of the player (`{0xFF, 0xFFFF}`) after its relay; a stop, a refusal and a
pull-back do not ([`flows/actions.md`](flows/actions.md)).

## Stop request

`0x2012 {loc}`: the mover is stepped to the clock's millisecond; when `dist²(pos, loc) < 40 001` and `loc` has a free
cell, the player stops ("StopHere"): the mover ends, the remembered move is forgotten and `0x2013 {handle, pos}` goes
to the players in sight. Else a refusal as above. `loc` is never stored: the server position stays.

## The mover

`Zone.Mover` uses the integer arithmetic of the original:

- **distance** (`ddt_Distance` FUN_004012d0): magnitudes `dx`, `dy`; while one is above 1024 both are halved (integer
  division) and a multiplier doubled; `round(√(dx² + dy²)) × multiplier`;
- **duration** = `max(1, distance × 1000 div speed)` ms;
- **point after `applied` ms**: per axis `start ± |d| × applied div duration`; when the elapsed time has reached the
  duration, every slice of that step is the goal;
- **step to `now`** (`mm_Step` FUN_004be7e0): `elapsed = min(now − started_at, duration)`; slices of at most 100 ms
  from `applied` on, the last at `elapsed`; each slice runs the block check and then sets the position through
  `Zone.MapInstance.step/3`, so the sight rule runs on every slice ([`sight.md`](sight.md)); the mover ends when the
  duration is applied (the remembered move stays);
- **direction** (`ddt_DirectSR`): `atan2(dx, dy)` in degrees, plus 360 when negative, halved and rounded, modulo
  180 *(inferred; three captured points of capture 45 agree)*.

Every tick (100 ms) steps the mover of every moving player, in ascending handle order. The original's throttle of
Z09-B15 is not built: every call steps.

**Exact step.** A walk, run or stop request steps the mover to the clock's millisecond before its checks, not to the
last tick. The decision of the issue names this only for the stop; capture 45 shows it for a move too: the relayed
`from` of a move that follows another after 75 ms advanced by exactly `14 × 75 div 110 = 9` units, so the original's
position is current to the millisecond when a request arrives.

## Block check and pull-back

Each slice point is checked (`ShinePlayer::smo_BlockCheck` FUN_004bec00, with `sp_MoveFindEmpty` FUN_004be4c0). The
player has a **last good position** (`Zone.Player.last_good`, the entry position at first):

- point not blocked: the last good position becomes the position before the step; the step is applied;
- point blocked and `dist²(pos, last good) > 899`: the four probes `(x+10, y)`, `(x−10, y)`, `(x, y+10)`,
  `(x, y−10)` around the point in this order; the first free one becomes the last good position and the step is
  applied; when all four are blocked, the **pull-back**: the player is set to the last good position (through
  `step/3`, so the sight rule runs; the original sets it without one, but with a stateless sight rule a silent jump
  could leave a client with a stale object), StopHere, and `0x204A {pos}` to the player; the stepping ends;
- point blocked otherwise: the step is applied (a few units into a blocked cell are accepted).

The **stop block check** before every `0x201B` (`smo_StopBlockCheck` FUN_004bee40): when the player stands on a
blocked cell that is not its last good position, the same pull-back.

## Who gets what

| Packet | To |
|---|---|
| `0x2018` / `0x201A` relay | the players in sight, not the mover (capture 45) |
| `0x2013` stop | the players in sight, not the player itself (capture 45, file lines 1751 to 1753) |
| `0x201B` refusal, `0x204A` pull-back | the player itself |
| `0x1C06` + the remembered move, `0x1C0E` | as the sight rule of each step ([`sight.md`](sight.md)) |

`0x203E` (the speeds) is **not** sent on a move: both captures show it only in the login burst, against the reading
"SendSpeedIfChanged(force = 1)" of Z02 §2.2; the capture wins.

Every packet for the requesting player goes to its connection as `{:cluster, {:packets, packets}}`, like the packets
of a tick. The map instance sends them before it replies to the call; the connection takes them from its mailbox
right after the call (same sender, so they are there) and sends them before it reads the next frame, so a heartbeat
that arrived in the same TCP read is answered after them.

**Appear of a moving player.** Its `0x1C06` is followed by its remembered move packet with `from` = its current
position (`ResendLastMove` FUN_005555e0). In a step the mover's own appear carries its position **before** the step:
the original sends it before it sets the position (capture 45, transcript file lines 890 and 891: B is shown at
(6422, 8254), 1602 units from A at radius 1600). This differs from issue 109's `Zone.Sight.step/3`, which sent the new
position; the capture wins.

## Original-server bugs

- **Z02-B2:** the original leaves the `moveattr` bytes of `0x2018` / `0x201A` as its buffer held them except bit 0;
  the rebuild sends 0. The replay masks the field.
- **Z02-B1 not rebuilt:** the legacy move packets `0x2003` / `0x2005` moved the character without any check; they are
  dropped by `Net.Connection` as known opcodes without a packet module.
- **Z09-B15 not rebuilt:** the throttle of `mm_Step`; every call steps.

## Not built

The mover-rider, fear, pet-cast, attack-cancel, skill-cancel, gamble and abstate branches of the original handlers
(later milestones), speed changes, doors (`.sbi`) and areas.
