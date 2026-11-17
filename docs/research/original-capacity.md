# Capacity and timing figures of the original 2016 server

Research for issue #7. Local sources only: the reconstruction docs, the shipped config under
`Files/Server/2016`, and three functions read in `re-data/exports/zone-pdb` where the docs lacked the figure.
Evidence marks follow `CLAUDE.md`: plain = read in the code or config, *(inferred)* = deduced.
"Shipped" means the value in the config files of this install; an operator could change it without a rebuild.

## 1. Summary: the numbers the rebuild must at least match

| Figure | Original | Kind |
|---|---|---|
| Client connections, Login | 200 | config (shipped) |
| Client connections, WorldManager = players per world | 2500 | config (shipped) |
| Client connections, per zone process | 1700 sockets, but only 1500 player objects | config / compiled |
| Players per zone process | 1500 | compiled pool |
| Players per world, hard ceiling | min(2500, 4 × 1500) = 2500 | *(inferred)* from the two rows above |
| Players per map | no per-map limit; bounded by the zone's 1500 | see §4 |
| Zone tick | no fixed period; free-running loop with 1 ms sleeps | compiled |
| Zone timer resolution | 100 ms (`g_Now` counts tenths of a second) | compiled |
| Login / WM loop | 5 ms sleep per pass (≤ ~200 passes/s) | compiled |
| Area of interest | radius 1600 units on 128 of 138 maps; shrinks above 29 players within 500 units | data + compiled |

## 2. Connection limits

The session pools are sized from the last column (`nMaxAccept`) of the `SERVER_INFO` rows in
`Files/Server/2016/9Data/ServerInfo/ServerInfo.txt`. Columns: `pName, nServerID, nWorldNo, nZoneNo, nServerIDFrom,
pIP, nPort, nBackLog, nMaxAccept` (W05 §5.2 `CServerInfo::GetServerInfo` FUN_00465d60; S01 knowledge §2.4).
`nServerIDFrom` is the peer type: 20 client, 6 zone, 5 WM, 8 OPTool.

| Listener (row) | Port | Backlog | nMaxAccept | Pool built by |
|---|---|---|---|---|
| Login ← clients (`PG_Login`, from 20) | 9010 | 100 | **200** | `CLoginClientSessionManager::InitSessions` FUN_00409a00 (L01 §2.3) |
| Login ← WorldManagers (from 5) | 9011 | 100 | 50 | L01 §2.5; also the size of the world-number table |
| Login ← OPTool (from 8) | 9015 | 1 | 30 | L01 §2.4 |
| WM ← clients (`PG_W00_WM`, from 20) | 9110 | 100 | **2500** | `CWMClientSessionManager::InitSessions` FUN_00437fd0 (W05 §4.1) |
| WM ← zones (from 6) | 9111 | 100 | 100 | `CWMZoneSessionManager::InitSessions` FUN_004397d0 |
| WM ← OPTool (from 8) | 9115 | 100 | 30 | FUN_00438f70 |
| Zone ← clients (`PG_W00_Z0n`, from 20), each of 4 | 9210/12/14/16 | 100 | **1700** | `ClientSessionManager::InitSessions` FUN_0045c4c0 (Z10, `zs_Start_Acceptor` FUN_005a9c60) |
| Zone ← previous zone of the ring (from 6) | 9218–9221 | 1 | 30 | Z01 §10 |
| Zone ← OPTool (from 8) | 9211/13/15/17 | 100 | 30 | Z01 §3.3 |
| DB servers (AccDB, ALDB, CDB, GLDB) | 9000, 9311, 9411, 9511 | 100 | 100 | not client-facing |

Behaviour at the limit (all three parts): a pool is a fixed array with an empty list and an active list. When
`m_NumSessions == m_MaxSessions` the accept fails, the server logs `* ACCEPT NO SESSION BUFFER - ERROR *` and
closes the socket (L01 §2.1 FUN_00409410; W05 §4.1 FUN_004302f0; zone `zs_connect` FUN_005aa840, Z09 §1.5: "full →
socket closed"). The client gets no error packet.

Session sizes, for a memory comparison: Login client session 0x2d0 bytes, WM client session 0x1f7b8 bytes
(129 KB, so 2500 sessions ≈ 322 MB preallocated), zone `ClientSession` 0x110 bytes (L01 §2.1, W05 §4.1, Z10).

Outgoing zone links: pools of up to 4 sessions each to WM, Character DB and GameLog, picked round-robin
(Z01 §1, `SessionPool_Pick` FUN_004199b0).

## 3. Players per world

- The WM reports `0x0808 { u16 currentUsers, u16 max }` to Login every 30 s. `max` = client pool capacity (2500
  shipped), or the OPTool limit when `0 < limit ≤ capacity` (W01 §2 `Login_WorldStatus` FUN_00438d10; OPTool
  `0x280E` FUN_00426390, W04; the limit starts at −1 = none, W05 §1).
- Login turns the ratio into the world status with `m_LoginUserRatable`, default thresholds 3 / 5 / 8 / 10 / 30 /
  95 % of `max` (L01 §3, FUN_0040a0c0). At ≥ 95 % the world shows as full (status 5). With the shipped 2500 that is
  2375 users. Login still passes a world select on a full world (L00-B3, cited in L01 §3), so the real stop is the
  WM pool: the 2501st connection is closed at accept.
- A WM client session exists from world login through character select and play, so 2500 counts everyone
  connected to the world, not only players on maps *(inferred from W05 §4.3–4.5 session lifecycle)*.

## 4. Players per zone process and per map; object and handle tables

One fixed pool per object type, built at start-up by `som_Initialize` FUN_0055c260. The 16-bit object handle sent to
the client is `range start + pool index`, so the ranges are client-visible (Z01 §4.2, `ObjectHandle_Decode`
FUN_00633650; also `docs/knowledge/Z01.md`).

| Handle range | Type | Pool size | Object size |
|---|---|---|---|
| 0 – 7999 | 5 mob | 8000 | 0x2568 |
| 8000 – 9499 | 2 player | **1500** | 0x2c058 (180 KB) |
| 9500 – 10499 | 3 mini-house | 1000 | 0xd100 |
| 10500 – 13499 | 1 drop item | 3000 | 0x28b |
| 13500 – 17083 | 0 axial flag | 3584 | 0x188 |
| 17084 – 17339 | 4 NPC | 256 | 0x256c |
| 17340 – 19387 | 8 bandit | 2048 | 0x266c |
| 19388 – 20387 | 9 effect | 1000 | 0x1d3 |
| 20388 – 20637 | 6 magic field | 250 | 0x1c8 |
| 20638 – 21637 | 7 door | 1000 | 0x1f14 |
| 21638 – 22137 | 10 servant | 500 | 0x2598 |
| 22138 – 23137 | 11 mover | 1000 | 0x202c |
| 23638 – 25137 | 12 pet | 1500 | 0x25d4 |

- **Players per zone process: 1500.** The player handle is `8000 + poolIndex`, −1 above index 1499 (Z09 §2.1,
  FUN_00559d40). The zone's client socket pool is larger (1700 shipped), so up to 200 sockets can be connected
  without a player object, e.g. during map login *(inferred; what the zone answers when the player pool is
  exhausted but a socket is free was not read)*.
- **Players per map: no limit found.** No per-map player cap appears in `Field.txt`, `MapInfo.shn` or the docs for
  normal maps; all maps of a zone share its 1500 player slots. Exceptions are content rules, not capacity: the
  tutorial map picks an instance with `fm_GetPlayerCountInField < MaxChr` (Z14, `mc_FindNotFullMap` FUN_0049f010),
  and Kingdom Quests and instance dungeons have their own entry limits (Z14, Z16).
- Because the pools are per process, mobs (8000), drops (3000) etc. are also per zone, shared by all its maps.
- WM-side handles: slot = `handle % m_MaxSessions`, each reuse of a slot adds `m_MaxSessions` to its handle
  (W05 §4.2; same scheme in Login, L01 §2.3). Server-internal, not client-visible.

## 5. How the four zone processes divide the maps

Static assignment by a data column, no load balancing (K01 knowledge §5 and §8; code read for this ticket in
`FieldContainer::fc_Load` FUN_004655f0):

- `9Data/ServerInfo/_ServerGroup.txt` holds one word, shipped `Fiesta`. It names the column of table `FieldList`
  in `9Data/Shine/World/Field.txt` that holds each map's zone ("machine") number
  (`FieldOption::fo_GetMechineNumber` FUN_0063e200). A per-world override `World/<WORLD_NAME>/Field.txt` is tried
  first (shipped world name `INITIO`; no such file shipped).
- A zone creates a map (`fc_MakeField` FUN_004650a0 → `fm_Init`) only when the machine number equals its own
  `nZoneNo`. Value 99 means "one copy per zone": the sub-map whose name ends in the zone's digit is loaded
  (only `MHBasic`, sub-maps 0–3, the mini-house interior).
- After the WM handshake each zone registers its maps with `0x180F` (and instance maps with `0xA419`); the WM
  routes a player to the zone that registered the target map (Z01 §3.3; K01 §5).
- A row with `SubFrom`/`SubTo` is expanded into several map instances (e.g. `KDArena` 100–109, `Rou` 00–19).

Shipped split (153 `FieldList` rows, counted from `Field.txt` for this ticket):

| Zone | Rows | Character |
|---|---|---|
| 0 | 36 | Roumen (`Rou`), `RouN`, `Bera`, several fields and dungeons, GuildT03/04, Job2 dungeons, `WarH` |
| 1 | 33 | Elderine (`Eld`), fields and dungeons, GuildT01, Wedding, Job1 dungeon, `Rou` sub-maps 00–19 and 50–51, Tower03 |
| 2 | 45 | Uruga (`Urg`), `Adl`, fields and dungeons, GuildT02, the tutorial `RouT`, `KDArena`, several KQ maps |
| 3 | 38 | almost only Kingdom Quest and instance maps (`KD*`, Tower01/02, Leviathan, `AdlF`, WarN/WarBL), plus `UrgFire01`, `GBHouse`, `Gate` |
| 99 | 1 | `MHBasic`, one sub-map per zone |

So the towns sit on three different processes and zone 3 carries the instanced content *(the "character" column
is my reading of the map names)*. Each zone has its own client port, so a map change between zones moves the
client to another connection *(inferred from the port rows; flow in Z01 §7, not re-read)*.

Zones talk to each other only through the zone ring (each zone connects to the next; requests that must find a
player "in any zone" travel around it, Z01 §10) and through the WM.

## 6. Loops and timers

### 6.1 Zone main loop

- One thread runs everything: server links, all client packet handling, every object's routine, global
  containers. IOCP workers (2 × CPUs + 1) only move bytes (Z01 §1; Z09 §1.1 `zs_mainthreadfunction` FUN_005aca30).
- **No fixed tick.** The loop runs as fast as it can. `SleepManager::sm_Routine` FUN_005aa610 sleeps 1 ms when
  `work · 2500 / peak < step²` (work = packets handled since the last check): an idle zone sleeps 1 ms every other
  pass, a busy one after about √(2500 · work / peak) passes (Z09 §1.4).
- Clock: `g_Now` = milliseconds since the first WM time message × 10 / 1000, i.e. **tenths of a second**. Every
  zone timer below compares against it, so timer resolution is 100 ms; only movement and the swing queue use
  milliseconds (Z09 §1.1, Z02 §1).
- Per pass, each object's `so_Routine` runs once (13 pool lists, Z09 §1.3). A player's packets are handled
  inside that player's routine: **up to 1000 packets per player per pass**, then its send buffer is flushed
  (Z09 §2.5). Latency of a request is therefore one loop pass plus the flush, with no artificial delay.
- The rebuild target that follows *(inferred)*: request-to-reply latency in the low milliseconds under light
  load; there is no tick to align to, and nothing the client could measure as a tick period.

### 6.2 Zone periodic work

| What | Period | Source |
|---|---|---|
| Character save to the Character DB (`ws_save2DB`, partial) | 600 s per player (`nextSave = now + 6000` tenths) | Z01 §8.4 FUN_00455a10; Z09 §2.3 |
| Per-minute block (world time, charged-item expiry, play time, wedding checks) | 60 s, on the minute of the WM time | Z09 §1.1, §1.2, §2.4 |
| GM event state refresh | 1 s | Z09 §1.1, §3 |
| Object-list consistency report | 60 s | Z09 §1.3 FUN_0054f710 |
| Boss servant-buff pulse | 5 s | Z09 §1.4 |
| HP / SP / LP change packets to the owner | every pass, sent only when the value changed | Z09 §2.4 FUN_0056d9a0 … |
| Minimon auto-potion | 1 s | Z09 §2.3 |
| Client session without map login | closed after 2 h (72000 tenths) | Z09 §1.5 `zs_disconnect` FUN_005abb60 |
| Zone → DB / WM link reconnect | `reconnectSeconds` of the pool | Z09 §1.5 |
| Two recurring start-up events | 300 s and 10 s | Z01 §2.2 (`zs_start_open`); purpose not read |

### 6.3 Movement

- Position is advanced by `MoveManager::mm_Step` FUN_004be7e0 from the object's routine on **every loop pass**
  while moving. Duration of a move = distance × 1000 / speed ms; the step walks the elapsed time in slices of at
  most **100 ms**, each slice checking blocks and updating sight (Z09 §9.1).
- The intended throttle "skip when less than 100 ms since the last step" never fires (Z09-B15), so the original
  really updates on every pass.
- Each position change re-sorts the map's coordinate lists and runs the appear / disappear passes of §7.

### 6.4 Combat

- Basic attack: the swing timer re-arms every `AttackSpeed()` ms (first swing 150 ms early); damage lands at
  `AttackSpeed / 2` after the swing start, or at the weapon's `hitTime[i]` fractions for multi-hit weapons; ranged
  classes add flight time = distance × 1000 / 200 ms. The damage queue is checked every pass and stored in tenths
  of a second (Z03 §3.2, FUN_00430bc0, FUN_005772a0, FUN_00577520).
- A new swing request is accepted after 80 % of the swing time (Z03 §3.2 `sp_Schedule_SwingDamage`).
- Skill cast completion, abnormal-state ticks and cooldowns are per-object timers checked every pass
  (`ShineMobileObject::so_Routine` FUN_0056a080, Z03 §5–6); periods come from the skill and abstate tables.

### 6.5 Regeneration

- **Players have no passive regeneration outside rest mode**: the recovery hook is a no-op unless the player
  rests in a mini-house tent (Z02 §7; Z09 §2.3).
- Rest mode: `sp_RecoverPoint_House` FUN_0056b3b0 adds HP every `mhs_HPTick` and SP every `mhs_SPTick`, both
  per-item values from the mini-house table (`HPTick`, `SPTick`, `HPRecovery`, `SPRecovery`; Z18 §2.6, Z24). The
  tick values were not tabulated for this ticket.
- Mobs: 10 % HP and SP every 3 s after a fight, none during it (Z09 §6.5).
- Mob respawn is handled by `so_mob_Regenerate` (Z09 §5.3); its periods were not read for this ticket.

### 6.6 Login and WorldManager

| What | Value | Source |
|---|---|---|
| Login main loop | `Sleep(5)` every pass; one pass handles all buffered frames of every session | L01 §1.2 FUN_004030e0 |
| WM main loop | `Sleep(5)` per pass in normal operation; one frame per session per pass | W05 §1.2 FUN_00407340; L01 §1.2 note |
| WM busy loop without sleep while the CharDB link is not validated | (original bug) W05-B1 | W05 §1.2 |
| Heartbeat (Login and WM, all sessions) | `0x0804` after 30 s of silence, close 180 s later | W05 §1.5 FUN_0042fda0; L01 §1.6 |
| WM → Login user count `0x0808` | 30 s | W05 §2.1 |
| WM → zones time `0x0821`; WM → clients time `0x0849` | 60 s each | W05 §2.1, §2.2 |
| WM Kingdom Quest tick / guild war / attendance | 1 s | W05 §2.1 |
| WM prison timer | 2 s | W05 §2.1 |
| WM party finder expiry | 11 s | W05 §2.1 |
| WM client login timeout | 2 h | W05 §1.5 (W01 §2) |

The WM's "one frame per session per pass, 5 ms sleep" bounds a single WM client to about 200 requests per second
*(inferred from the two facts)*.

## 7. Broadcast range (area of interest)

**Data structure.** No grid. Each map keeps two sorted doubly linked lists of its objects, one by x and one by
y ("slanted coordinate lists"), with two sentinels and five anchors on the diagonal. A range query walks the X
list both ways while |Δx| < range and stamps the objects, then walks the Y list while |Δy| < range and tests
`dist² < range²` on the stamped ones; a query aborts after 10000 steps on one list (Z09 §9.6,
`so_AllOfRangeNomal` FUN_0054c900). Moving an object re-sorts its two nodes (`cn_Rearrange` FUN_005883a0).

**Radius.** Per map, column `Sight` of `9Data/Shine/MapInfo.shn` (counted for this ticket, 138 rows):

| Sight | Maps |
|---|---|
| 1600 | 128 |
| 2000 | 4 (`Eld`, `KDArena`, `KDSoccer_W`, `KDCake`) |
| 2400 | 1 (`GuildT04`) |
| 3000 | 2 (`KDMine`, `KDEgg`) |
| 6000 | 3 (`WarL`, `WarH`, `RouT`) |

Unlimited (99,999,999 / −1) for an object in wide-sight state or while a script camera move runs (Z09 §9.6).
For scale: a map's `xsize`/`ysize` in `Field.txt` is 256 or 512 for the early maps; the relation between those
units and the 1600 sight units was not read.

**Who receives a broadcast** (`AxialListPacketBroadcast::ali_Work` FUN_00428b20, Z01 §3.2): players in a game mode,
within the range, on the same layer (or either on layer −1), passing the 6 × 6 sub-layer visibility table, not
closing; a receiver with "hide except me" only gets its own packets and its mover's.

**Crowd reduction** (`CalculateBroadcastDistance::cbd_DistanceSquar` FUN_0043e740, read for this ticket; table
built by FUN_0043c910, Z31 §10.6): n = players within 500 units of the object.

- n < 29: radius² = `Sight²` of the map.
- n ≥ 29: radius² = `trunc(√(75,000,000 / n))²`, i.e. the sight **area** shrinks as 75,000,000 / n, capped at
  n − 29 = 499. Examples: n = 30 → 1581 units, n = 100 → 866, n = 528 or more → 376.
- This reduced radius is used only by the full "exchange brief info" passes (login complete, respawn, teleport,
  layer change; Z02 §5.2). The per-step appear / disappear tests during movement use the plain map `Sight`
  (Z09 §9.6), and ordinary packet broadcasts use the map's sight iteration (Z01 §3.2).

**Appear / disappear.** On every movement step: objects within sight of the new position that were not within
sight of the old one exchange brief info; objects that left sight get `0x1C0E` (NPCs are never removed this way)
(Z09 §9.6, FUN_004bdef0 / FUN_004be0d0). Full exchanges batch up to 28 characters per `0x1C07` (Z02 §5.2).

## 8. Not verified

- What a zone answers when all 1500 player slots are taken but a client socket is free.
- Whether a per-map player limit exists outside the tutorial / KQ / instance rules: none was found in the docs or
  in the two data tables, but the map-login handler was not re-read for one.
- The `Sight` unit against map size, and the actual `HPTick` / `SPTick` values.
- Real load figures: nothing local says how many players the original hardware carried at what CPU cost. The
  only measured diagnostics in the binary are the `PerformanceChecker` ring of tick start times and the function
  profiler (Z09 §1.1), which keep no persistent output we have.
- The 2500 / 1700 / 200 limits are this install's config (a private-server set); the 1500-player pool and all
  timers are compiled in.
- The instance counts behind `SubFrom`/`SubTo` were not expanded into a per-zone total.
