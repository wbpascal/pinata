# Capture validation (P02)

Real client↔server traffic compared with the documented protocol (`README.md`, annotations, generated layouts,
pseudocode). Captures are the strongest evidence level: a statement here marked *(captured)* overrides a reading of
the code; where they disagree, the code was re-read and the finding is listed in §13 for the owning item.

- Decoder: `python3 -I tools/protocol-re/pcap_decode.py re-data/captures/<file>.pcapng --out <dir>` (P01,
  `docs/knowledge/P01.md`). Field names below are the decoder's (annotations first).
- Captured fields confirmed or corrected by P02: `annotations/P02.json` (`packets` = corrected/new layouts,
  `evidence` = confirmed existing layouts).
- Server set: `Files/Server/2016`, client `Files/Client/2016` (version key `20151116141627`), one world
  (`world_no` 0, `INITIO`), zones on ports 9210/9212/9214 (Zone03 on 9216 was never used), all on 172.16.42.214; client on another LAN host.
  The server links (batch 2, §7) run over loopback on the same host.
- Status words per opcode: **confirmed** (size and every field value consistent with the documented layout and
  behaviour), **corrected** (layout or behaviour differs; correction recorded), **contradicted** (a documented
  statement is wrong, owner must fix), **partial** (size confirmed, some fields not exercised or not documented),
  **never seen** (documented, not in any capture yet).

## 1. Captures processed

| Capture (`re-data/captures/26_11_15_…`) | Scenario (notes file + pcapng comments) | Streams | Packets |
|---|---|---|---|
| `login-logout` | login `admin`, world select, character list (Test1235, lvl 120 archer in Roumen), back to world select, quit | login×2, wm×1 | 26 |
| `login-errors` | wrong password; client 1 logs in; client 2 logs in with the same account, client 1 is kicked ("multiple logins detected") | login×3, wm×2 | 44 |
| `create-char` | create Cleric/female/face 3/"Feather" hair/"Deep Blue" `CharCreateTest`, then delete it | login, wm | 30 |
| `idle_in_world` | log Test1235 into Roumen, idle among mobs, log out to character select, back to world select | login×2, wm, zone | 208 |
| `walk-run-portals` | run, walk, town portal Roumen↔Forest of Mist several times, link portal Roumen→Forest of Tides | login, wm, zone×6 | 1057 |
| `buy item, equip item, use storage, unequip, sell item, travel portal, attack, use soulstones` (**shop**, batch 2) | name only, no notes file, no pcapng comments: Test2 (lvl 5) buys, equips, opens storage, unequips, sells, uses a portal, attacks, uses HP / SP stones | login, wm, zone×2 + 56 server links | 1570 |
| `travel portal, attack mob, pick-up item, die, revive, linkto` (**combat**, batch 2) | name only: Test2 travels, fights mobs, picks up drops, dies, revives, takes a link portal | login, wm, zone×3 + 56 server links | 1870 |
| `14_second-client-in-sight` (**s14**, batch 3) | notes file (times not filled in): Test1235 (GM) at the RouN slimes, a second account creates the Mage `X14B`, walks into sight, emotes, jumps, shouts, whispers, attacks; A `&hide` / `&show` / `&dimension` / `&linkto` | login×2, wm×2, zone×2 (both 9210) + 56 links | 13 468 |
| `21_items-drop-split-storage-use-shop` (**s21**, batch 3) | notes file + SQL snapshots before / after: Test2 splits, merges, drops, picks up, destroys, uses, equips rings, uses storage, sells and buys back, buys soul stones, KQ pick-up limit, full inventory | login×3, wm×2, zone×2 (9210) + 56 links | 11 569 |
| `21b_purchase-attr-write-fail` (**s21b**) | name only: S16 (a purchase whose attribute write fails); Test1235 buys Leather Boots twice (§21.1) | login, wm, zone (9210) + 56 links | 397 |
| `21c_expired-item` (**s21c**) | name only + one pcapng comment ("Boots deleted here", 66.1 s): S13 (an item past its end time); Test1235 logs in and waits (§21.2) | login, wm, zone (9210) + 56 links | 606 |
| `21d_stack-over-maxlot` (**s21d**) | name only: X3 (a stack limit lower than an existing stack; zone restarted with the changed table); Test1235 makes, drops and picks up 10 potions (§21.3) | login, wm, zone (9210) + 67 links (zone restart) | 853 |
| `37_login-heartbeat-refusals-delete` (**s37**, batch 3) | notes file: idle on the world list, create / delete / re-create `X37Del`, 4 min on the character list, WM stopped (world closed), WM restarted with capacity 1 (world full), blocked account, not-login-able account | login×6, wm + 124 links (WM restarts) | 3 583 |

Batch 2 (`shop`, `combat`) was recorded on the server host with the LAN and the loopback interface: it adds the
server↔server links (§7). The character is Test2 (`chrregnum` 5, slot 1, level 5, shape 0x19), not Test1235.
Its 257 opcode types not seen in batch 1 (190 on links, 64 zone, 3 WM) are covered in §7–§10 (parts 7–13); the
batch-1 types recur with the same layouts unless a row says otherwise.

The pcapngs hold only the game packets (saved as "displayed packets"): no SYN/ACK frames. Several game packets often share one frame (one TCP segment, §2.1): idle_in_world holds 208 packets in
114 frames, walk-run-portals 1 057 in 566, up to 67 packets in one frame.

Batch 3 (commit 26bb95f, the X02 scenarios 14, 21, 37 and the setups S13, S16, X3) was recorded the same way as batch 2.
`26_11_15_24_skills-abstates-stat-points.md` has no pcapng (blank notes only): scenario 24 is not captured. The 146
opcode types not seen in batches 1–2 (98 on links, 9 WM, 39 zone) are covered in §16–§21; those sections stand
before §11 so that the sweep sections §11–§15, which other documents cite by number, keep their numbers.

## 2. Transport

### 2.1 Framing *(captured)*

README §1.1 **confirmed**: 1 365 packets parsed with no resync, gap or truncation. The long form `00 len:u16`
appears exactly for bodies ≥ 256 bytes (`0x0C5A` 318, `0x0C0F` 322, zone `0x1801` 1 592, `0x1C09` up to 4 175,
WM `0x581D` up to 7 477). Several packets share one TCP segment on the server side.

### 2.2 Client→server cipher *(captured)*

README §1.3 **confirmed** on all three servers: every C→S body decrypts with XOR-499 starting at `seed % 499` of the
stream's `0x0807` and running across packets (all 346 C→S packets decode to opcodes the server's client parser registers; the brute-force
check of P01 picks the same start index). S→C traffic is plaintext.

### 2.3 Seed `0x0807` *(captured)*

| Server | Captured | Code |
|---|---|---|
| Login | 9 connections, seeds 355–368: consecutive inside each capture (359, 360, 361 in login-errors; 365, 366 in idle_in_world), the gaps are connections between captures | **confirmed** and extended: `CLoginClientSessionManager` starts the counter at `rand()` after `srand(time)` (ctor @ FUN_00409680); `ActiveSession` (@ FUN_00409700) sets `m_ClientSeed = (m_ClientSeed + 1) % 499` for every accepted client; `Send_NC_MISC_SEED_ACK` (@ FUN_00409610) sends it |
| WM | 264, 266–269, 271: +1 per connection | same scheme (`m_ClientSeed + 1` in the WM client session manager, wm-pdb decomp) |
| Zone | per process: port 9210 → 1 (idle) and 3, 4, 5 (walk); 9212 → 1, 2; 9214 → 1 | **contradicted** README §1.4 and §2: the zone sends `0x0807` **on accept**, unprompted. `ZoneServer::zs_connect` (@ FUN_005aa840) registers the socket with IOCP and calls `ClientSession::Send_NC_MISC_SEED_ACK(session, seed)` (@ FUN_0045b120) with the seed returned by ShinePlayer vtable slot `0x2f4` = `ShinePlayer::so_EncSeedSet` @ FUN_0054f660: `seed = seed + 1; if seed >= pe_encryptlen (499): seed = 0` on the global `seed` (DAT_13282f60, used only there), which also sets the session's cipher position. Hence first connection of a process = 1, then consecutive: **confirms** Z18 §1.3 (accept path). The client never sent `0x0806 NC_MISC_SEED_REQ` in any capture; `sp_NC_MISC_SEED_REQ` (@ FUN_00451a30) with its own `newseed` counter (Z01 §5.1) is the path Z18 §1.3 / Z18-B2 mark dead |

### 2.4 Heartbeat *(captured)*

README §1.5 **contradicted** for WM and zone: the **server** sends `0x0804 NC_MISC_HEARTBEAT_REQ` (empty) and the
client answers `0x0805 NC_MISC_HEARTBEAT_ACK` (empty) within ~5 ms. WM sent it after ~30 s without client traffic
(create-char: t = 31.5, 61.5, 91.6, 141.1, 171.1 s), which matches the Login `HeartbeatTick` rule (`login-server.md`
§2: request after 30 s of silence). The client also sends unsolicited `0x0805` to WM while in a zone
(walk-run-portals: t = 86.3, 106.5, 136.2, 181.8 s): it comes from the client's map loader (§4.4). Login sent no heartbeat in the captures: on the
world-select screen the client polls `0x0C1B` every 10 s, so the 30 s silence never occurs.

## 3. Login server

### 3.1 Message order *(captured)*

Password login (all five captures), times from the seed:

```
S 0x0807 seed            +0 ms
C 0x0C65 version         +5..10
S 0x0C67 version ok      +10..20
C 0x0C5A login           +20     (same client tick as the next one)
C 0x0C04 XTrap key       +20
S 0x0C05 XTrap ack       +30     (Login answers 0x0C04 at once)
S 0x0C0A world list      +70..170 (after the AccountDB 0x0C5B/0x0C5C and AccountLog 0x0C5D/0x0C5E round trips)
C 0x0C1B world status    +10 ms after 0x0C0A, then every 10.0 s while the world list is shown
S 0x0C1C world status
C 0x0C0B world select    (user)
S 0x0C0C WM address + validate[32]   +20..30 ms (WM 0x0C0D/0x0C0E round trip)
```

Token login after leaving the WM (`0x0C33`/`0x0C34`, login-logout and idle_in_world `login#2`): `0x0807`,
`0x0C65`, `0x0C67`, `C 0x0C37 token`, `C 0x0C04`, **`S 0x0C0A` before `S 0x0C05`** (the token table is in Login
memory, no DB round trip), then `0x0C1B`/`0x0C1C`.

Wrong password (login-errors `login#1`): `0x0C5A`, `0x0C04`, `0x0C05`, then `S 0x0C09 {error 0x45}` 50 ms later
("Please check ID or Password."); the next attempt is a new TCP connection (new seed).

Differences from the documented order:

- README §2 omits `0x0C04`/`0x0C05` and the `0x0C1B` poll. The client sends `0x0C04` **after** its login request,
  not instead of it: `AccountFrameWork::On_NC_USER_CLIENT_RIGHTVERSION_CHECK_ACK` (client @ FUN_0046f470) first
  calls `NcUserLoginReq` (`0x0C5A` or `0x0C37`), then sends `0x0C04`. `login-server.md` §8 lists only the `0x0C04`
  send (owner L00, done: correction recorded here and in `docs/knowledge/P02.md`).
- The client connects to Login only when the user confirms the login form: `0x0C5A` follows `0x0C67` by ~10 ms
  *(captured; inferred: the credentials are entered before the TCP connect)*.

### 3.2 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| S→C | 0x0807 | NC_MISC_SEED_ACK | 9 | 2 | confirmed | §2.3 |
| C→S | 0x0C65 | NC_USER_CLIENT_VERSION_CHECK_REQ | 9 | 64 | confirmed | `20151116141627` |
| S→C | 0x0C67 | NC_USER_CLIENT_RIGHTVERSION_CHECK_ACK | 9 | 2 | confirmed | `01 00`: length 1, empty key (`login-server.md` §4) |
| C→S | 0x0C5A | NC_USER_US_LOGIN_REQ | 7 | 316 | confirmed | exact length 0x13E; `spawnapps` = `"Original"` |
| C→S | 0x0C37 | NC_USER_LOGIN_WITH_OTP_REQ | 2 | 32 | corrected | the token is ASCII: the 32 hex characters of WM `0x0C34`'s token (`4c076e5e…` → `34 63 30 37 …`), no NUL; retyped `char[32]` in `annotations/P02.json` |
| C→S | 0x0C04 | NC_USER_XTRAP_REQ | 9 | 30 | confirmed | order: after the login request (§3.1) |
| S→C | 0x0C05 | NC_USER_XTRAP_ACK | 9 | 1 | confirmed | `bSuccess = 1` always (the key is not checked, L00-B5) |
| S→C | 0x0C09 | NC_USER_LOGINFAIL_ACK | 1 | 2 | confirmed | `0x45` for a wrong password (`login-server.md` §5.1) |
| S→C | 0x0C0A | NC_USER_LOGIN_ACK | 8 | 19 | confirmed | 1 world: `{0, "INITIO", 6}`. The name is ServerInfo.txt `WORLD_NAME 0, "INITIO"`. The scenario notes say the tester saw "Enid", but neither `Fiesta.bin` (2016) nor its `TextData*.shn` contains that string, so the 2016 client cannot have shown it: unexplained (probably another client install or a slip in the notes); §14 |
| C→S | 0x0C1B | NC_USER_WORLD_STATUS_REQ | 10 | 0 | confirmed | every 10 s on the world list |
| S→C | 0x0C1C | NC_USER_WORLD_STATUS_ACK | 10 | 19 | confirmed | same body as 0x0C0A |
| C→S | 0x0C0B | NC_USER_WORLDSELECT_REQ | 6 | 1 | confirmed | `world_no = 0` |
| S→C | 0x0C0C | NC_USER_WORLDSELECT_ACK | 6 | 83 | confirmed | status 6 → client connects to WM; `validate[32]` see §3.3 |
| C→S | 0x0C18 | NC_USER_NORMALLOGOUT_CMD | 1 | 1 | confirmed (layout pdb2016) | `LogoutType = 0` when quitting from the world list; Login ignores it (`login-server.md` §4), the client closes the socket |
| C→S | 0x0804 | NC_MISC_HEARTBEAT_REQ | 0 | – | never seen (Login) | handler `FUN_004060b0` |
| S→C | 0x0C66 | NC_USER_CLIENT_WRONGVERSION_CHECK_ACK | 0 | – | never seen | |
| S→C | 0x0C17 | NC_USER_CONNECTCUT_CMD | 0 on Login | – | see §4 | captured on WM |

### 3.3 Field findings

- **Validate key** (`0x0C0C.validate`, forwarded to WM as `0x0C0D.validate`): the XOR of all 32 words is the
  per-world validation counter: 1, 3, 4, 5, 6, 8 in time order over the six world selections *(captured)*. Code:
  `CLoginWorldManagerSessionManager::GetClientValidation` (@ FUN_0040a200) increments
  `m_pWMClientValidationTable[world]` and masks it with `0x7FF`; `fc_NC_USER_WORLDSELECT_REQ` (@ FUN_00406970)
  fills words 0..30 with `rand() % 0xFFFF` and word 31 with `counter XOR word0 … XOR word30`. Every random word is
  < 0x8000 in the captures (MSVC `rand()` returns 15 bits, so `% 0xFFFF` never reduces anything). The gaps (2, 7)
  are world selections outside the captures.
- **World status 6**: the only value seen. `login-server.md` §8 (client: 6..10 connect) **confirmed** for 6.

## 4. World manager

Streams: 6 WM connections (login-logout 1, login-errors 2, create-char 1, idle_in_world 1, walk-run-portals 1), 155
packets, 42 (dir, opcode) types. Code references are W01-core (`docs/pseudocode/wm/W01-core.md`), W03-guild, W04-social-misc,
W05-process; function names from the WM PDB (`re-data/exports/wm-pdb`).

Decoder fix in this part: annotations whose `dir` names the server (`WM→C`, `C→WM`, `Z→C`, `C→Z`: W03, W04, W05, Z11,
Z12, Z16) were never matched, so 0x7032/0x7C07/0x9414/0x5826/0x5824/0x0849/0x10D9/0x7005/0x700D/0x703B/0x7033/0x7034 decoded with
the PDB or C01 layouts. `pcap_decode.py` now maps any `X→C` / `C→X` label to S→C / C→S (`client_dir`). With that fix and
the P02 entries for 0x1406 / 0x140C / 0x182A, 69 of the 155 WM packets decode from hand annotations, 42 from pdb2016 and
44 from pdb2017 (all empty bodies: 0x0804, 0x0805, 0x080D, 0x7C06).

### 4.1 Message order *(captured)*

World login (all 6 connections):

```
S 0x0807 seed                       +0      (on accept, W01 §3.2)
C 0x0C0F userId + validate[32]      +2..9 ms
S 0x0C14 avatar list                +50..76 ms   (AccountDB 0x0C60/0x0C61 [+ AccountLogDB 0x0C62/0x0C63] + CharDB 0x0C12/0x0C13)
C 0x080D game time                  +4..8 ms after 0x0C14
S 0x080E {hour, minute, second}     +6..14 ms
```

Character login (idle_in_world, walk-run-portals) and the WM side of the zone login:

```
C 0x1001 {slot 0}                   (user)
S 0x1003 {zoneIp, zonePort 9210}    +614 / +616 ms  (CharDB 0x1004 → blob packets → 0x1005)
  zone: S 0x0807, C 0x1801 …        +50 ms
S 0x7032, 0x7033, 0x7034            +53 ms after 0x1003, before the zone has answered 0x1801
                                    (SendToClient_CharOptionData @ FUN_00431680, called by CharDB 0x1005 after 0x1003)
  zone: … S 0x1802 NC_MAP_LOGIN_ACK
C 0x7004, 0x700C, 0x7C06            same client tick, 7 ms after 0x1802 (the client asks on NC_MAP_LOGIN_ACK, C01)
S 0x7005, 0x700D (CharDB round trip, 20–75 ms), 0x7C07 (4-byte form; the WM sends it in the 0x7C06 handler
                                    without a DB round trip, W04, yet it left 73–74 ms after 0x7C06, in the same TCP
                                    segment as 0x700D, before it in idle and after it in walk; cause open, §14)
  zone: C 0x1803 NC_MAP_LOGINCOMPLETE_CMD, and in the same client tick:
C 0x581B NC_KQ_LIST_REFRESH_REQ
S 0x581C, 0x581D ×3                 answer to 0x581B (first refresh of the session only, §4.3)
S 0x1097, 0x1012, 0x9414, 0x5826, 0x10D9, 0x0849, 0x182A   zone 0x180C map login done (fc_NC_MAP_LINKEND_CMD @ FUN_0042d8d0)
```

The packets of the 0x180C burst come in the call order of `fc_NC_MAP_LINKEND_CMD` (wm-pdb). Its first calls sent
nothing here (no party, no raid): `RaidRefresh` / `IsInRaid`, `PartyRefresh` with `SendPartyMemberList`,
`SendPartyItemLooting`, `SendPartyLogin` / `SendPartyLoginInfo`. Then `FriendRefresh` (nothing: no
friends), `GuildRefresh` (0x1097 academy, then 0x1012 guild), `GuildEmblemRefresh`, `ChatRestrictRefresh` (nothing),
`HolyPromiseFirstLogon` (0x9414), `GuildTournamentGoldRefundNotice`, `ChatBlockSpamFilterRefresh` (nothing),
`CKQServer::Send_NC_KQ_JOINING_ALARM_LIST` (0x5826), `NewbieGuideViewListRefresh` (0x10D9), `SendWMTimeToClientFirst`
(0x0849), on the first join only (`GetFirstJoinSendData`, then `SetFirstJoinSendData`)
`CWMClientSession::Send_NC_CHAR_SUPPORT_REWARD_CMD` @ FUN_00433ab0 (zone `0x1120`, server-internal: abstate 728, §5.1)
and `cEvent_Attendance::Send_NC_CHAR_EVENT_ATTENDANCE_LIST_DB_REQ` (to the CharDB), then `LinkEndProcessing`, 0x182A,
`0x5425 {u16 points}` only when `GetDiffFriendPoint() != 0` (never in the captures; reset by `SetDiffFriendPoint(0)`)
and the GameLog `0x040F` (0x2C bytes, server-internal). The 0x581B answer and the 0x180C burst race: in walk-run-portals the KQ
list came first (9.784 s, burst 9.812–9.858 s), in idle_in_world after the burst (41.793–41.798 s, list 41.798 s).

Map change (walk-run-portals, 5 changes): zone A `0x180A NC_MAP_LINKOTHER_CMD` → new zone stream (`0x0807`, `0x1801`)
and **in the same client tick `C 0x080D` to the WM** (→ `0x080E`) → zone `0x1802` → (4 of 5 times) `C 0x0805` to the
WM, see §4.4 → zone `0x1803` + `C 0x581B` → WM `0x5826`, `0x182A` only. The once-per-character pushes (0x1097, 0x1012,
0x9414, 0x10D9, first 0x0849) and the KQ list are not repeated: **confirmed** for 0x10D9 (W05 §4.7: blob freed after
the first send) and 0x0849 (W05 §2.2: `m_bFirstJoinSend_WMTime_ToClient`); for 0x1097/0x1012/0x9414 the pending flags
of W03 §4.2 / W04 §12.2 are consumed by the first call *(captured)*.

Logout from the game to the world list (idle_in_world, comment "Character logout" at 96.53 s):

```
zone C 0x2012 NC_ACT_STOP_REQ, C 0x1071 NC_CHAR_LOGOUTREADY_CMD     96.530
WM   C 0x7011 SET_SHORTCUTSIZE (24), 0x7015 SET_WINDOWPOS (392), 0x7016 SET_KEYMAPPING (308),
       0x703B IMPROVE_SET_GAMEOPTION (86)                           96.530, same tick (no answers, W04 §8.2)
     … 10 s logout countdown (WM KQ traffic continues) …
WM   C 0x0C33 → S 0x0C34 {0x1E58, token} (+20 ms, Login round trip)  106.541
WM   C 0x0C18 {LogoutType 0}; zone C 0x0C18 {0}                       106.566, same tick
login#2: seed, 0x0C65, 0x0C37 token …                                107.949 (§3.1)
```

The client saves only the old blobs (0x7011, 0x7015, 0x7016) and the improved game options (0x703B); it sends no
0x7037 / 0x7039 although it loaded the improved shortcut and key-map data (0x7032 / 0x7033) at login. 0x7011's data is
byte-identical to the 0x7005 it received (24 bytes), 0x7015's to 0x700D's (392 bytes), 0x703B's 28 options to 0x7034's.

From the character list to the world list (login-logout, no character in game): `C 0x0C33`, `S 0x0C34` (+44 ms), then
the client closes the WM connection **without** `0x0C18` (W01 §5.1's handler would ignore it anyway: no CHARDATA).

Duplicate login (login-errors): client 1 sits in the character list (wm#1); client 2 logs in with the same account.
Login answers client 2's `0x0C5A` after the DB round trip, the WM sends `S 0x0C17 {0x683}` to client 1 at 80.2470 s and
Login sends `0x0C0A` to client 2 at 80.2478 s; client 1's WM stream ends there and the client showed "multiple logins
detected, you have been logged out" (capture comment). This is the Login-initiated path: Login broadcasts 0x0C16
`NC_USER_KICKOFFFROMWORLD_CMD` to the WMs and then sends 0x0C0A (`login-server.md` §5.1), the WM's handler
(W01 §5.2 @ FUN_00424880) calls `Kickoff(userNo)` @ FUN_00437d50, which sends 0x0C17 {0x683} (W05 §3 kick table). The
WM-side kick of W01 §3.2 (`Clients_KickDoubleLogin` on a second 0x0C0F) is not exercised: client 2's 0x0C0F (83.2 s)
found no old session.

### 4.2 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| S→C | 0x0807 | NC_MISC_SEED_ACK | 6 | 2 | confirmed | §2.3 |
| C→S | 0x0C0F | NC_USER_LOGINWORLD_REQ | 6 | 320 | confirmed | `userId` = `"admin"` + 251 NUL; `validate[32]` = the 0x0C0C words unchanged (all 6) |
| S→C | 0x0C14 | NC_USER_LOGINWORLD_ACK | 6 | 133 | confirmed | `worldmanager` handle, 1 AVATAR (0x82); see §4.3 for the handle sequence and the AVATAR fields |
| C→S | 0x080D | NC_MISC_GAMETIME_REQ | 11 | 0 | confirmed | after every 0x0C14 and with every zone `0x1801` (map change) |
| S→C | 0x080E | NC_MISC_GAMETIME_ACK | 11 | 3 | confirmed | `{hour, minute, second}` = server local time (UTC+1); equal to the capture clock to the second in 9 of 11. In login-logout (09:50:33 against 09:50:34.019) and login-errors (09:56:57 against 09:56:58.019) it is one second behind, ~20 ms after a capture-clock second boundary: the capture PC and the server have separate clocks that differ by a few tens of ms (see also 0x0849, §4.3) |
| S→C | 0x0804 | NC_MISC_HEARTBEAT_REQ | 13 | 0 | confirmed (W05 §1.5) | 30.0 s after the last client packet (create-char 1.516 → 31.521, idle 41.784 → 71.789) |
| C→S | 0x0805 | NC_MISC_HEARTBEAT_ACK | 18 | 0 | confirmed + extended | 13 answers (+1..12 ms), 5 unsolicited during map loading (§4.4) |
| C→S | 0x1401 | NC_AVATAR_CREATE_REQ | 1 | 25 | confirmed + extended | `{slot 1, name "CharCreateTest", shape 0x19, hair 1, colour 1, face 5}`; field meanings §4.3 |
| S→C | 0x1406 | NC_AVATAR_CREATESUCC_ACK (pdb2016; the decoder shows C01's "character created (ours)": C01.json has the only annotation) | 1 | 131 | confirmed | `{u8 1, AVATAR}` (W01 §4.1 CharDB 0x1405); 99 ms after 0x1401 |
| C→S | 0x1407 | NC_AVATAR_ERASE_REQ | 1 | 1 | confirmed | `slot 1` |
| S→C | 0x140C | NC_AVATAR_ERASESUCC_ACK (pdb2016; decoder: C01 "character deleted (ours)") | 1 | 1 | confirmed | `{u8 slot 1}`, 44 ms after 0x1407 (CharDB 0x1408 / 0x140B) |
| C→S | 0x1001 | NC_CHAR_LOGIN_REQ | 2 | 1 | confirmed | `slot 0` |
| S→C | 0x1003 | NC_CHAR_LOGIN_ACK | 2 | 18 | confirmed | `{"172.16.42.214", 9210}`: Zone00 (ServerInfo), the zone of `RouN` |
| S→C | 0x7032 | NC_CHAR_OPTION_IMPROVE_GET_SHORTCUTDATA_CMD | 2 | 37 | confirmed | `count 5`, 5 × 7-byte `SHORT_CUT_DATA {u8 nSlotNo, u16 nCodeNo, i32 nValue}`: slots 0, 1, 4, 10, 11 |
| S→C | 0x7033 | NC_CHAR_OPTION_IMPROVE_GET_KEYMAP_CMD | 2 | 382 | confirmed | 95 entries (W04 §8.1 "key map ≤ 95") |
| S→C | 0x7034 | NC_CHAR_OPTION_IMPROVE_GET_GAMEOPTION_CMD | 2 | 86 | confirmed | 28 entries |
| C→S | 0x7004 | NC_CHAR_OPTION_GET_SHORTCUTSIZE_REQ | 2 | 0 | confirmed | |
| C→S | 0x700C | NC_CHAR_OPTION_GET_WINDOWPOS_REQ | 2 | 0 | confirmed | |
| S→C | 0x7005 | NC_CHAR_OPTION_GET_SHORTCUTSIZE_ACK | 2 | 25 | confirmed | `bSuccess 1` + 24 bytes |
| S→C | 0x700D | NC_CHAR_OPTION_GET_WINDOWPOS_ACK | 2 | 393 | confirmed | `bSuccess 1` + 392 bytes |
| C→S | 0x7C06 | NC_PRISON_GET_REQ | 2 | 0 | confirmed | |
| S→C | 0x7C07 | NC_PRISON_GET_ACK | 2 | 4 | confirmed | short form `{err 0x0DB1, nMinute 0}` (W04 §9.2: not in prison). The decoder warns because W04.json lists `sReason`/`sRemark` for the long form; the 4-byte form is documented in its note |
| S→C | 0x0849 | NC_MISC_SERVER_TIME_NOTIFY_CMD | 8 | 37 | confirmed + extended | `tm` local time, `nTimeZone 1`, `tm_isdst 0`; timing §4.3 |
| C→S | 0x581B | NC_KQ_LIST_REFRESH_REQ | 7 | 0 | confirmed | with every `0x1803` |
| S→C | 0x581C | NC_KQ_LIST_TIME_ACK | 2 | 40 | confirmed | `ServerTime` = capture time (s), `tm` local; first refresh of the session only (`listTimeSent`) |
| S→C | 0x581D | NC_KQ_LIST_ADD_ACK | 6 | 7475 / 4232 / 4514 | confirmed | 136 / 138 KQs split 53 + 53 + 30 / 32 (141-byte `PROTO_KQ_INFO_CLIENT`; §4.3) |
| S→C | 0x581F | NC_KQ_LIST_UPDATE_ACK | 2 | 9 | confirmed | `{1, {Handle 14, Status 1→2, 0}}` from the per-second refresh (§4.3) |
| S→C | 0x5824 | NC_KQ_JOINING_ALARM_CMD | 1 | 84 | confirmed | `{14, ID 16, 46, 60}`, `MsgLength 75`, "Recruitment for Kingdom Quest - 'Lost Mini Dragon (Hardcore)[B]' has begun." = MsgWorldManager row 0 (W04 §6.2) |
| S→C | 0x5826 | NC_KQ_JOINING_ALARM_LIST | 7 | 178 / 194 | confirmed | 22 / 24 Status-2 KQs × 8 bytes; on every map login |
| S→C | 0x1097 | NC_CHAR_GUILD_ACADEMY_CMD | 2 | 5 | confirmed | 5-byte form `{0, 0}` (no guild, W03 §4.2) |
| S→C | 0x1012 | NC_CHAR_GUILD_CMD | 2 | 4 | confirmed | 4-byte form `{0}`; sent for a guildless character too (the `else` branch of `Client_SendGuildInfo`, W03 §4.2) |
| S→C | 0x9414 | NC_HOLY_PROMISE_LIST_CMD | 2 | 29 | confirmed | empty master, `nPart 3` (first + last), `MemberCount 0` (0x1D bytes, W04 §12.2) |
| S→C | 0x10D9 | NC_CHAR_CLIENT_NEWBIE_GUIDE_VIEW_LIST_CMD | 2 | 35 | confirmed | 34 guide ids, all < 0xC5 |
| S→C | 0x182A | NC_MAP_LINKEND_CLIENT_CMD | 7 | 1 | corrected | the byte is uninitialised: `0xDA` (idle) and `0x00` (6× walk); `CSendPacket::ID(&p, 0x182a, 1, NULL)` writes no payload (original bug) P02-B2. pdb2017 struct is empty (0 bytes); annotated in `annotations/P02.json`. The client ignores the byte: `GameFrameWork::On_NC_MAP_LINKEND_CLIENT_CMD` (FUN_004bb330) only, when the own level ≤ the client value `PopUpDialogNPC_Raemi_LimitLv`, finds the NPC `PopUpDialogNPC_Raemi` on the map and clicks it (`NcActNPCClickCmd`), so the stale byte only leaks WM memory |
| C→S | 0x7011 | NC_CHAR_OPTION_SET_SHORTCUTSIZE_CMD | 1 | 24 | confirmed | 0x18 bytes (W04 §8.2) |
| C→S | 0x7015 | NC_CHAR_OPTION_SET_WINDOWPOS_CMD | 1 | 392 | confirmed | 0x188 bytes |
| C→S | 0x7016 | NC_CHAR_OPTION_SET_KEYMAPPING_CMD | 1 | 308 | confirmed | 0x134 bytes |
| C→S | 0x703B | NC_CHAR_OPTION_IMPROVE_SET_GAMEOPTION_REQ | 1 | 86 | confirmed | `n 28` |
| C→S | 0x0C33 | NC_USER_WILL_WORLD_SELECT_REQ | 2 | 0 | confirmed | |
| S→C | 0x0C34 | NC_USER_WILL_WORLD_SELECT_ACK | 2 | 34 | confirmed | `result 0x1E58`, 32 ASCII hex chars (= the later Login 0x0C37, §3.2) |
| C→S | 0x0C18 | NC_USER_NORMALLOGOUT_CMD | 1 | 1 | confirmed + extended | `LogoutType 0` when going from the game to the world list (W01 §5.1 calls mode 0 "quit"; it covers leaving the WM either way). Mode 1 not captured |
| S→C | 0x0C17 | NC_USER_CONNECTCUT_CMD | 1 | 2 | confirmed | `0x683` (Login-initiated kick, §4.1) |
| C→S | 0x10DA | NC_CHAR_NEWBIE_GUIDE_VIEW_SET_CMD | 2 (batch 2) | 1 | confirmed | `nGuideView` 131, 142 (`shop`). The WM forwards CharDB `0x10DB {nCharNo 5, nGuideView}` 5–11 ms later (W01 §5 @ FUN_004182f0; D02 0x10DB) |
| C→S | 0x7037 | NC_CHAR_OPTION_IMPROVE_SET_SHORTCUTDATA_REQ | 2 (batch 2) | 11 | partial | `n 1`, `SHORT_CUT_DATA {nSlotNo 9, nCodeNo 0, nValue 0}`, then `{9, 1, 38043}` (`combat`). The client sends **3 zero bytes more** than `1 + 7n`. The WM forwards CharDB `0x704B` with `5 + 7n` = 12 bytes (tail dropped); CharDB `0x704C {nError 0x2100 ok, nCharNo 5}` comes back 1–2 ms later (W04 §8.2 / §8.3 **confirmed**). Client sender not located: the 2017 `ShortCutMgr::SaveToNet` / `SendOptToChange` are empty stubs (§14) |
| S→C | 0x7038 | NC_CHAR_OPTION_IMPROVE_SET_SHORTCUTDATA_ACK | 2 (batch 2) | 2 | confirmed | `nError 0x2100` 23–29 ms after the request; the 2016 client has no handler (W04 §8.3) |

Never seen on the WM (documented client-facing paths not exercised): `0x0C15` (bad validate / DB error), `0x1002`
(char login errors), `0x1404` / `0x140A` (create / delete errors), `0x1110` / `0x111D` (tutorial), `0x140F` / `0x1410`
(rename), `0x5425` (friend points), all friend / party / guild / chat traffic. They stay at their W01–W05 reading.

### 4.3 Field findings

- **Client session handle** (`0x0C14.worldmanager`, later `0x1801.wm_handle` and zone `0x180A.wmHandle`): 0, 5000,
  7500, 10000, 12500, 17500 for the WM connections with seeds 264, 266, 267, 268, 269, 271 *(captured)*: one slot
  reused, the handle grows by 2500 per connection (the missing 2500 / 15000 are seeds 265 / 270, outside the captures).
  **Confirms** W05 §4.2 (release: `h' = h + m_MaxSessions`) with `m_MaxSessions` = 2500 = the client listener's
  `nMaxAccept` in ServerInfo.txt (`PG_W00_WM … 20, "0.0.0.0", 9110, 100, 2500`).
- **AVATAR** (W01 §6.1, 0x82 bytes), character Test1235 (6 lists) and the new CharCreateTest (0x1406):
  - `shape` byte 0 (`race:2, chrclass:5, gender:1`): Test1235 `0xAE` = race 2, class 11, gender 1; CharCreateTest
    `0x19` = race 1, class 6, gender 0. Race ids are `RaceNameInfo.shn` (1 Human, 2 Elf, 3 DarkElf), classes
    `ClassName.shn` (6 Cleric, 11 Archer); the tester created a **female** cleric, so gender 0 = female, 1 = male
    *(captured; W01's "race (inferred)" confirmed)*.
  - `hairtype 1` = `HairInfo.shn` id 1 "Feather", `haircolor 1` = `HairColorInfo.shn` id 1 "Deep Blue", `faceshape 5` =
    `FaceInfo.shn` id 5 "Face 3" (the UI's third face; ids 1–3 are unused Korean placeholder rows): the bytes are the
    client table ids *(captured)*.
  - `delinfo` (+0x27, 5 bytes) of the listed Test1235: byte +0x27 = 0, bytes +0x28..+0x2B differ per list: `98 d9 72 10`,
    `c0 d5 d0 0f`, `58 d7 53 11` (twice), `50 d8 8b 12`, `00 00 00 00`: pointer-like values = uninitialised memory of the
    Character server. D02 §3.2 reads `GetAvatarInfo` as writing only +0x27 when `bDeleted == 0` and infers the field
    is "always 0 on the wire": **contradicted** for +0x28..+0x2B (original bug) P02-B1. The new avatar of 0x1406 (create
    path) has all 5 bytes 0.
  - `nKQHandle` = −1 in all records, yet `sKQMapName`, `nKQCoord` and `dKQDate` carry values: Test1235 `"RouN"`,
    (6477, 9844) and later (5926, 8346); `dKQDate` decodes (4/4/5/5/6/6 bits, year mod 16) to 13 Nov 12:57:15 and, in
    walk-run-portals, 15 Nov 10:14:46 (shortly before that capture's login at 10:15:03, after a session outside the
    captures). The new character: map empty, (0, 0), date 15 Nov 10:06:40 (creation, ≈ 2 s before the 0x1406). So the
    KQ columns hold the last saved position and time even outside a kingdom quest *(captured; meaning inferred)*.
    W01 §4.2 uses them only when the instance redirect applies (`nKQHandle` known), so no behaviour changes.
  - `CharIDChangeData` = `{0, 0x64, 0}` for Test1235 (D02 knowledge: the default when the account has no rename
    right) **confirmed**; the 0x1406 record has `{0, 0, 0}`.
  - `TutorialInfo`: Test1235 `{2, 0}`, CharCreateTest `{0, 0}` (tutorial not done). The new record's `loginmap` is
    `"RouN"`; W01 §3.3 rewrites it to `"RouT"` only in the 0x0C13 list, and 0x1406 is not patched *(captured,
    consistent)*.
  - Equipment: `equip[4]` = 1250 in all lists; `equip[9]` = 35740 and `equip[18]` = 30817 in five lists, `0xFFFF` in
    walk-run-portals (unequipped between captures); `upgrade` bytes `00 00 f0`.
- **0x0849 timing**: the periodic sends carry `tm_sec = 0` every time (idle 10:10:00, 10:11:00; walk 10:16:00 …
  10:19:00) and are captured between 4 ms before (idle 10:10:00 at 10:09:59.996) and 88 ms after the full second
  (idle 10:11:00 +32 ms; walk +34, +64, +88, +68 ms). The capture PC's clock is not the server's (0x080E, §4.2: a few
  tens of ms apart, either sign), so the captures only bound the send to the full second ± that offset plus the loop latency.
  Of the 8 × 0x0849, 6 are periodic and 2 first-join copies. W05 §2.2 *(inferred)* "the send second
  drifts by the loop latency" is **corrected**: `m_NextSendWMTime` is computed from `_time32()` (whole seconds), so the
  sub-second latency of a pass is dropped at every send and the grid stays on the full minute; a drift needs a pass
  late by ≥ 1 s. The first-join copy carries the current second (`tm_sec 1`, `11`). The periodic copy also reaches a
  client that is still loading the map (idle: 40.126 s, between 0x1802 at 7.255 s and 0x1803 at 41.784 s), as W05
  §2.2 says (`m_bCharDataValid`).
- **KQ list split**: 53 entries per 0x581D = 2 + 53 · 141 = 7 475 bytes, i.e. the packet is sent when it **passes**
  0x1D25 (7 461) after adding an entry (52 entries would be 7 334): W04 §6.4 **confirmed**. Statuses in the list: 114 ×
  0, 22 × 2 (idle); `PROTO_KQ_INFO_CLIENT` fields decode with sane values (titles from the KQ table, `StartTime` local
  minute grid, `DemandClass 0x0FFFFFFE`, `DemandGender 3`).
- **KQ state change** (idle, KQ handle 14, ID 16, `StartTime` 10:11:00): `0x581F {Status 1}` at 10:10:59.977 (capture
  clock; `KQ_TickMake`, Status 0 → 1 and zone 0x580D), then `0x5824` alarm at 10:11:00.163 (zone `0x580E` answer →
  `KQ_OnMakeOk`, Status 2, `KQ_SendJoiningAlarm` with WM text #0), then `0x581F {Status 2}` at 10:11:01.093 from
  `KQ_RefreshOneClient` (one client per second, `wantsListRefresh` set by 0x581B). W04 §6.2 / §6.3 **confirmed**.
  The 0x5824 reached a player whose level (120) is outside 46–60; the client decides (W04: `ConfirmKQAlarmInfo`).
- **Shortcut data** (0x7032): slot 0 `{code 4, value 0}`, slot 1 `{4, 1}`, slot 4 `{3, 4021}`, slot 10 `{1, 3500}`,
  slot 11 `{1, 3505}` (meaning of the codes not checked against the client).

### 4.4 Heartbeat on the WM *(captured)*

- WM → client: W05 §1.5 `CheckHeartBeat` **confirmed**: `0x0804` exactly 30.0 s after the last packet from the client
  (every instance), repeated 30 s after the client's answer; the client answers within 1–12 ms (2016 client handler
  `Net::ProcessNetMsg` @ FUN_006d2fa0, if heartbeats are enabled, net +0x10048). W01 §2's sentence "every link answers
  0x0804 with 0x0805" is true for the WM as a receiver but the WM is also the sender; see the README correction (§2.4).
- Client → WM unsolicited `0x0805`: 5 times, each while the client loads a map (idle 31.6 s during the 34 s load
  between 0x1802 and 0x1803; walk 86.30, 106.49, 136.22, 181.77 s, 30 ms after the new zone's 0x1802). Source: the
  2016 client's `World::LoadMap` (FUN_006768c0, C02 name) calls FUN_006d2ef0 at 8 points of the load; FUN_006d2ef0
  sends `0x0805` on the **WM** connection (net object `+0x20`, if connected and heartbeats enabled) and resets the
  heartbeat timer. Its shape matches the 2017 client's `NetMgr::SendHeartBeat2WorldMgrServer` *(pdb2017 name)*. It keeps
  the WM from timing out the session during long loads. Which of the 8 points fire depends on the map's load path:
  the first loads of Roumen (6.3 s) and Forest of Mist (74.9 s) sent none *(not traced)*.

## 5. Zone login

Streams: 7 zone connections (idle_in_world 1, walk-run-portals 6: Roumen `RouN` on port 9210 ×3, Forest of Mist
`RouVal01` on 9212 ×2, Forest of Tides `RouCos02` on 9214 ×1), each one map login of the same character (Test1235,
admin level 100). Code references: Z01 §5–§8 (`docs/pseudocode/zone/Z01-core.md`), Z07 §1, Z12 §6 (blobs), Z18
§4/§6.5, function names from the zone PDB (`re-data/exports/zone-pdb`). This section covers the login streams up to the
end of the 0x1803 burst and the client's follow-up requests, plus logout; movement, portals and NPCs are §6.

### 5.1 Message order *(captured)*

Map login (every one of the 7 streams; times from the zone stream start):

```
S 0x0807 seed                    +0          on accept (§2.3); seeds per zone process 1, 3, 4, 5 (9210), 1, 2 (9212), 1 (9214)
C 0x1801 NC_MAP_LOGIN_REQ        +1..11 ms   (with C 0x080D to the WM in the same tick, §4.1)
  zone → WM 0x104B → 0x104C → 0x101C → blobs 0x101F … → 0x101D (not on the wire here; W01 §7.2)
S 0x1038 BASE, 0x1039 SHAPE, 0x103A QUEST_DOING, 0x103B QUEST_DONE, 0x10CE QUEST_READ, 0x10D7 QUEST_REPEAT,
  0x103D SKILL, 0x103E PASSIVE, 0x1047 ITEM ×4 (box 9, 8, 12, 15), 0x1049 CHARTITLE, 0x104A CHARGEDBUFF, 0x1048 GAME,
  0x10DE COININFO, 0x441E QUEST_RESET_TIME          +37..475 ms, the client copies of the blobs in W01 §6.3 table order
S 0x1802 NC_MAP_LOGIN_ACK        +442..560 ms  (0x101D handler, after the last blob)
  … client loads the map: 0.43 s … 3.9 s; 35 s for the first load of idle_in_world …
C 0x1803 NC_MAP_LOGINCOMPLETE_CMD, and in the same client tick:
C 0x2001 NC_ACT_CHAT_REQ "&adminlevel", C 0x200B NC_ACT_ENDOFTRADE_CMD ×3
  [first map login of the session only: C 0x302C REWARDINVENOPEN_REQ {page 0}, C 0x3020 CHARGEDINVENOPEN_REQ {page 0}]
S the 0x1803 burst (+6..18 ms, one server tick), then the next tick (+11..16 ms later) the parameter refresh
```

The 0x1803 burst, captured order (identical in all 7 apart from the counts; two streams carry other packets inside it:
walk-run-portals zone#1 has the 0x302D answer to the first-login 0x302C after the 0x2011 notice, zone#6 has 6 × 0x2018
mob moves between 0x1C09 and 0x242A, both from work of the same server tick) against `sp_NC_MAP_LOGINCOMPLETE_CMD`
@ FUN_00443390 (Z01 §6), with the call that sends each packet:

| # | Packet(s) | Sent by (FUN_00443390 call order) | Captured |
|---|---|---|---|
| 1 | 0x10E4, 0x10E7, 0x10EA card album / bookmarks / rewards | `sp_CardCollectionSend` @ FUN_0044cc30 (first call after `so_allparametercalculate`) | always, number 0 |
| 2 | 0x1C04 ×29 (slots 1–29), then 0x1C02 (slot 8), 0x1C05 (weapon), 0x1C03 (slot 25) to the player himself | vt 0xd6c `so_ply_ViewSlot_UnEquipAll(0)` @ FUN_0052b510: unequip brief for every slot 1..29, then the equip brief (`iac_equipbriefinfo`, Z18 §4.3) of every equipped slot | 29 + one per worn item (3 in idle_in_world, 1 in walk-run-portals) |
| 3 | 0x583A NC_KQ_TEAM_TYPE_CMD {2} | `sp_SendKQTeamType` @ FUN_00561560 (Z16 §2.4) | 2 = not in a KQ team |
| 4 | 0x1C09 NC_BRIEFINFO_MOB_CMD ×1–2 | `so_AllInMap(so_ExchageBriefInfo @ FUN_00441460)` + `bixall_Send` @ FUN_0043fc80 | 28 mobs per packet (4173 = 1 + 28 × 149), then the rest: confirms the batch size 28 of Z18 §2.1 |
| 5 | 0x242A + 0x1C18 per abstate already on the character | `asl_SendAfterLogin` @ FUN_0040aed0 | 345 StaRestExp (7 166 000 ms, Z12 §5.4), from the second map login on also 728, then 291 = 0x123 StaImmortal (5 000 ms, set just before by vt 0x638) |
| 6 | 0x105B NC_CHAR_STAT_REMAINPOINT_CMD | `sp_StatRemainSend` @ FUN_0058bd10 | 73 |
| 7 | 0x203E NC_ACT_MOVESPEED_CMD | inline | walk 33, run 127 |
| 8 | 0x9010 NC_CHARGED_BOOTHSLOTSIZE_CMD | `sp_LoginInit` @ FUN_00440d80 → vt 0x3e0 `so_ply_SendBoothSize` @ FUN_00535390 | 5 |
| 9 | 0x182B NC_MAP_CAN_USE_REVIVEITEM_CMD | vt 0xe14 `so_ply_SendCanUseReviveItem` @ FUN_005616f0 (Z09) | 1 on all 3 maps |
| 10 | 0x2011 NC_ACT_NOTICE_CMD "From 172.16.42.231" | `sp_ConnectFromWhere` @ FUN_0043f1f0: admins only, `sprintf("From %d.%d.%d.%d")` → vt 0x784 notice (FUN_005977e0) | **corrects Z01 §6** (see §5.3) |
| 11 | 0x10BD NC_CHAR_CLIENT_AUTO_PICK_ACK {0x1E00, 1} | `sp_SetAutoPick(sp_GetAutoPick())` @ FUN_005654d0, only when a pick-up mini-mon is worn (`sp_IsAutoPickEnableState`) | idle_in_world only |
| 12 | 0x1123 NC_CHAR_USEITEM_MINIMON_INFO_CLIENT_CMD (50 bytes) | `sp_SendUseItemMinimonInfo_Client` @ FUN_00561990 (Z13); its 0x112C range broadcast never reached the own client *(captured; the broadcast excludes the sender, inferred)* | flags 0, 24 × 0xFFFF |
| 13 | (0x1C18 + 0x2429) ×4 | worn title's abstates: `GetStateData(CurrentTitle 9, element 3)` → vt 0x638 + `so_AbnormalState_BroadcastSet` | 422, 424, 425, 427, keepTime −1 (permanent) |
| 14 | 0x10C6 NC_CHAR_ADMIN_LEVEL_INFORM_CMD {100} | inline, `adminlevel ≠ 0` | 0x64 |
| 15 | 0x482C NC_SKILL_ITEMACTIONCOOLTIME_CMD {num 0} | `sp_ItemActionSetup` @ FUN_00566420 → `SendCoolTimes2Client` @ FUN_005d0d30 (Z17 §3.5) | sent with an empty list, 2 bytes |
| 16 | 0x10D4 NC_CHAR_MYSTERYVAULT_UI_STATE_CMD {0} | inline | 0 |
| 17 | 0x1827 NC_MAP_FIELD_ATTRIBUTE_CMD {0} | vt 0xd3c `so_ply_SendFieldAttribute` @ FUN_0054aa20: `u32 = FieldOption +0x36` (`FIELD_MAP_TYPE`, pdb2016) | 0 = `FMT_NORMAL` on all 3 maps |
| – | 0x2011 "Admin level is 100" {unk 2} | the client's `&adminlevel` chat (Z11), handled after 0x1803 | every map login |
| – | next tick: 0x1035 (26 entries, 131 bytes), 0x240E HP, 0x240F SP, 0x245F LP | `so_mobile_NotifyParameterChange` (Z12 §4): `sp_LastStat` was reset to −1 by the 0x1803 handler, so everything is sent once | always |

Not sent in any capture (conditions false): 0x0810 (no map-cluster time limit), 0x7C05 (no prison minutes), 0x182C
(sent only when the field's ID-level type `FieldMap+0x214` < 3; Roumen, Forest of Mist, Forest of Tides are ≥ 3),
raid packets (no raid), 0x1C06 etc. (0x10B3 is a CharDB link packet, sent at every 0x1803: batch 1 had no link
streams, §10.2) **The capture confirms Z01 §6's order** for everything it shows.

Newbie abstate: in walk-run-portals and idle_in_world the client gets `0x2429 + 0x1C18` for abstate 728 (600 000 ms)
one tick after the burst, before the refresh, on the first map login of the session only; on every later map login 728 is
already on the character and comes with the `asl_SendAfterLogin` batch (0x242A). Source (resolved in part 5): 728 =
AbState.shn `StaE_UserNewbie01` (0x2D8). The WM's 0x180C handler (`fc_NC_MAP_LINKEND_CMD` @ FUN_0042d8d0) calls
`CWMClientSession::Send_NC_CHAR_SUPPORT_REWARD_CMD` @ FUN_00433ab0 (W04's `Session_SendSupportReward`) on the first map
login only (W04 §17.5), which sends zone `0x1120
NC_CHAR_SUPPORT_REWARD_CMD {nCharNo, eUserType 2}`; the zone handler @ FUN_005a5c70 (Z07 §1.2) sets abstate 0x2D8.
userType 2 = "newbie": account signed up less than `UserNewbie_DaysAfterSignUp` (21) days ago (W01 §3.3), which fits
the test account. The 10 min matches SubStaE_UserNewbie01 (exp +3 %, 10 min; Z22 §7.3). **Confirms**
W04 §17.5 and Z07 §1.2 *(captured)*: the zone round trip explains the one-tick delay after the 0x1803 burst.

Client follow-ups (first map login only): `0x302C {page 0}` → `0x302D` (21–29 ms, Character DB round trip
0x1099), `0x3020 {page 0}` → `0x3021 {0x1041, partmark 3, count 0}` (21–73 ms, GameDB 0x3463). Login protection:
StaImmortal (291) is reset by `0x2428 {8000, 291}` exactly 5.0 s after the burst (idle_in_world 46.787 s), followed by
a 10-entry 0x1035 *(captured)*; 4.93–5.02 s in all 7 streams.

### 5.2 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| S→C | 0x0807 | NC_MISC_SEED_ACK | 7 | 2 | confirmed | per zone process consecutive (§5.1): **confirms** Z18 §1.3 (`so_EncSeedSet` @ FUN_0054f660, global `seed` + 1 mod 499, §2.3; not Z01 §5.1's `newseed`, which is the dead 0x0806 path); first connection after start = 1 |
| C→S | 0x1801 | NC_MAP_LOGIN_REQ | 7 | 1590 | confirmed | `{u16 wm_handle, char charid[20], Name8 checksum[49]}` = pdb2016 `PROTO_NC_MAP_LOGIN_REQ` (0x636); wm_handle 12500 / 17500 = the WM session handle (§4.3); 49 × 32 hex digits, identical in all 7 |
| S→C | 0x1038 | NC_CHAR_CLIENT_BASE_CMD | 7 | 105 | confirmed | Z12 §6.2; chrregnum 2, Level 120, map/coords of the **new** map on every link, adminlevel 100, prisonmin 0 |
| S→C | 0x1039 | NC_CHAR_CLIENT_SHAPE_CMD | 7 | 4 | confirmed | `AE 04 00 00`, same as AVATAR.shape (§4.3) |
| S→C | 0x103A | NC_CHAR_CLIENT_QUEST_DOING_CMD | 7 | 6 | confirmed | `{chrregnum 2, bNeedClear 1, n 0}` (Z12 §6.3) |
| S→C | 0x103B | NC_CHAR_CLIENT_QUEST_DONE_CMD | 7 | 12 | confirmed | 12-byte header, 0 records |
| S→C | 0x10CE | NC_CHAR_CLIENT_QUEST_READ_CMD | 7 | 8 | confirmed | 1 id (3109) |
| S→C | 0x10D7 | NC_CHAR_CLIENT_QUEST_REPEAT_CMD | 7 | 6 | confirmed | 0 records |
| S→C | 0x103D | NC_CHAR_CLIENT_SKILL_CMD | 7 | 298 | confirmed | restempow 60, PartMark 3, nMaxNum = number = 24, 24 × 12-byte records (skills 4000, 4001, 4020 …) |
| S→C | 0x103E | NC_CHAR_CLIENT_PASSIVE_CMD | 7 | 8 | confirmed | 3 passives (200, 201, 218) |
| S→C | 0x1047 | NC_CHAR_CLIENT_ITEM_CMD | 28 | 3–726 | confirmed | 4 per login: box 9 (27 items), 8 (3 in idle_in_world, 1 = the weapon in walk-run-portals: 73 bytes), 12 (2), 15 (0); flag bit 0 = 1 in all, bits 1–7 stale (0x65, 0x19, 0xFD, 0x25: **confirms** Z12 §6 "flag bits 1–7 left from earlier gpp use"); the empty action box 15 is still sent (single-packet path), the 3 inventory chunks of W01 §6.3 arrive as one packet (box 9). Decoder cannot parse the `PROTO_ITEMPACKET_INFORM[]` tail (P01) |
| S→C | 0x1049 | NC_CHAR_CLIENT_CHARTITLE_CMD | 7 | 22 | confirmed | Current 9/3, MobID 0, 8 titles × {u8, u8} (Z07 §1.3) |
| S→C | 0x104A | NC_CHAR_CLIENT_CHARGEDBUFF_CMD | 7 | 16 | confirmed | 1 buff (id 12) |
| S→C | 0x1048 | NC_CHAR_CLIENT_GAME_CMD | 7 | 4 | confirmed | partyno 0xFFFF, nRaidNo 0xFFFF |
| S→C | 0x10DE | NC_CHAR_CLIENT_COININFO_CMD | 7 | 16 | confirmed | coin 0, exchangeable 1 000 000 |
| S→C | 0x441E | NC_QUEST_RESET_TIME_CLIENT_CMD | 7 | 16 | confirmed, fields named | §5.3 |
| S→C | 0x1802 | NC_MAP_LOGIN_ACK | 7 | 242 | corrected (layout) | annotations.json had `?` blocks; now pdb2016 `PROTO_NC_CHAR_MAPLOGIN_ACK` in P02.json; §5.3 |
| C→S | 0x1803 | NC_MAP_LOGINCOMPLETE_CMD | 7 | 0 | confirmed | burst §5.1 |
| C→S | 0x2001 | NC_ACT_CHAT_REQ | 7 | 13 | confirmed | `"&adminlevel"` after every 0x1803 (client-generated, §5.3); in-world chat is §6 |
| C→S | 0x200B | NC_ACT_ENDOFTRADE_CMD | 25 | 0 | confirmed | 3 after every 0x1803 (+ 4 in-world, §6); empty layout added (P02.json) |
| S→C | 0x10E4 | NC_CHAR_CLIENT_CARDCOLLECT_CMD | 7 | 6 | confirmed | `chrregnum` stale (different per login, same in the 3 packets of one login): **confirms** Z18-B19 |
| S→C | 0x10E7 | NC_CHAR_CLIENT_CARDCOLLECT_BOOKMARK_CMD | 7 | 6 | confirmed | as 0x10E4 |
| S→C | 0x10EA | NC_CHAR_CLIENT_CARDCOLLECT_REWARD_CMD | 7 | 6 | confirmed | as 0x10E4 |
| S→C | 0x1C04 | NC_BRIEFINFO_UNEQUIP_CMD | 203 | 3 | confirmed | 29 per login (own handle, slots 1..29), §5.1 #2 |
| S→C | 0x1C02 | NC_BRIEFINFO_CHANGEDECORATE_CMD | 1 | 5 | confirmed | item 35740 slot 8 (idle_in_world; in walk-run-portals the item was not worn) |
| S→C | 0x1C03 | NC_BRIEFINFO_CHANGEUPGRADE_CMD | 1 | 6 | confirmed | item 30817, upgrade 0, slot 25 |
| S→C | 0x1C05 | NC_BRIEFINFO_CHANGEWEAPON_CMD | 7 | 9 | confirmed | item 1250 (equipment slot 10 in 0x1047), `nSlotNum` = 0x74 in all 7 (stale): **confirms** Z18-B10; currentmobid 0xFFFF, killlevel 0xFF |
| S→C | 0x583A | NC_KQ_TEAM_TYPE_CMD | 7 | 1 | confirmed | 2 |
| S→C | 0x1C09 | NC_BRIEFINFO_MOB_CMD | 12 | 299–4173 | confirmed | 1 + 149 × n, n ≤ 28; since the part-5 decoder fix (§15) every record decodes (`mobnum` = record count in all 12; handle, mode 2, mobid, coord); in-world 0x1C09 is §6 |
| S→C | 0x242A | NC_BAT_ABSTATEINFORM_NOEFFECT_CMD | 19 | 8 | confirmed | `asl_SendAfterLogin`, §5.1 #5 |
| S→C | 0x2429 | NC_BAT_ABSTATEINFORM_CMD | 30 | 8 | confirmed | title abstates (§5.1 #13), abstate 728; keepTime −1 = permanent |
| S→C | 0x1C18 | NC_BRIEFINFO_ABSTATE_CHANGE_CMD | 49 | 14 | confirmed | one per 0x2429 / 0x242A, handle = own |
| S→C | 0x105B | NC_CHAR_STAT_REMAINPOINT_CMD | 7 | 1 | confirmed | 73 |
| S→C | 0x203E | NC_ACT_MOVESPEED_CMD | 7 | 4 | confirmed | {33, 127} |
| S→C | 0x9010 | NC_CHARGED_BOOTHSLOTSIZE_CMD | 7 | 1 | confirmed | 5 |
| S→C | 0x182B | NC_MAP_CAN_USE_REVIVEITEM_CMD | 7 | 1 | confirmed | 1 |
| S→C | 0x2011 | NC_ACT_NOTICE_CMD | 14 | 20 | confirmed | 2 per login: "From 172.16.42.231" (`unk` 1) and "Admin level is 100" (`unk` 2): `unk` is never written (Z09-B54); the values are whatever the send buffer held *(inferred)* |
| S→C | 0x10BD | NC_CHAR_CLIENT_AUTO_PICK_ACK | 2 | 3 | confirmed (pdb2016 layout) | login {err 0x1E00, bEnable 1}; at 82.1 s {0x1E00, 0} (in-world, §6); layout added to P02.json |
| S→C | 0x1123 | NC_CHAR_USEITEM_MINIMON_INFO_CLIENT_CMD | 7 | 50 | confirmed | Z13 layout right (0x32); the struct `USEITEM_MINIMON_INFO` (pdb2016, 0x32) is now in `annotations/P02.json` `structs`, so all 7 decode in full (part 5, §15) |
| S→C | 0x10C6 | NC_CHAR_ADMIN_LEVEL_INFORM_CMD | 7 | 1 | confirmed | `nAdminLevel` 100 (pdb2016 name; layout added to P02.json) |
| S→C | 0x482C | NC_SKILL_ITEMACTIONCOOLTIME_CMD | 7 | 2 | confirmed | num 0 (Z17 §3.5: 2 + 8n, sent also when empty); Z11.json overlays the array header and its element fields (`group[i].…`) at offset 2; the decoder now reads that as the element layout (part 5, §15) |
| S→C | 0x10D4 | NC_CHAR_MYSTERYVAULT_UI_STATE_CMD | 7 | 1 | confirmed | 0 |
| S→C | 0x1827 | NC_MAP_FIELD_ATTRIBUTE_CMD | 7 | 4 | confirmed (pdb2016 layout) | `eFieldMapType` 0 = FMT_NORMAL; layout added to P02.json |
| S→C | 0x1035 | NC_CHAR_CHANGEPARAMCHANGE_CMD | 25 | 51–131 | confirmed | 1 + 5n; full refresh (26) after login, 10 after the immortal reset (in-world refresh is §6) |
| S→C | 0x240E | NC_BAT_HPCHANGE_CMD | 8 | 6 | confirmed | {3043, hpchangeorder 1} after login |
| S→C | 0x240F | NC_BAT_SPCHANGE_CMD | 8 | 4 | confirmed | 2851 |
| S→C | 0x245F | NC_BAT_LPCHANGE_CMD | 7 | 4 | confirmed | 0 (not a Sentinel) |
| S→C | 0x2428 | NC_BAT_ABSTATERESET_CMD | 7 | 6 | confirmed | {own handle, 291} 5 s after login |
| C→S | 0x302C | NC_ITEM_REWARDINVENOPEN_REQ | 2 | 2 | confirmed | {page 0}, first map login only |
| S→C | 0x302D | NC_ITEM_REWARDINVENOPEN_ACK | 2 | 2 | corrected | 0 items + **1 stray trailing byte** (0x12, 0x10): §5.3, P02-B3 |
| C→S | 0x3020 | NC_ITEM_CHARGEDINVENOPEN_REQ | 2 | 2 | confirmed | {page 0} |
| S→C | 0x3021 | NC_ITEM_CHARGEDINVENOPEN_ACK | 2 | 5 | confirmed | {0x1041 ok, partmark 3, count 0}; the trailing `bytes` field is empty (decoder fixed in part 5: `bytes` = rest of the payload) |
| C→S | 0x1071 | NC_CHAR_LOGOUTREADY_CMD | 1 | 0 | confirmed | §5.4; empty layout added |
| C→S | 0x0C18 | NC_USER_NORMALLOGOUT_CMD | 1 | 1 | confirmed | `LogoutType` 0; §5.4 |
| S→C | 0x0804 | NC_MISC_HEARTBEAT_REQ | 3 | 0 | confirmed | §5.5 |
| C→S | 0x0805 | NC_MISC_HEARTBEAT_ACK | 3 | 0 | confirmed | §5.5 |

Documented zone-login opcodes never seen: 0x1804 NC_MAP_LOGINFAIL_ACK (no failure), 0x0810, 0x7C05, 0x182C, 0x10B3
(zone → Character: a link packet, not in batch 1's client-only streams; seen at every 0x1803 in batch 2, §10.2), 0x112C (broadcast, never to the own client).

### 5.3 Field findings

- **0x1802 = `PROTO_NC_CHAR_MAPLOGIN_ACK`** *(pdb2016)* `{u16 charhandle, CHAR_PARAMETER_DATA param (0xE8), SHINE_XY_TYPE
  logincoord}`; all 7 decode field by field as Z07 §1.5 says: PrevExp / NextExp = 72 987 672 292 / 83 037 947 834
  (level-120 / 121 rows), 15 stat pairs `{base, change}` (`base` 0 for every stat above Intelligence/MentalPower: the
  pure layer has no WC/AC/…), MaxHp 3043 / 3033 = CurHP of 0x1038, MaxSp 2851 / 2841, MaxLp 0, MaxAp 0, MaxHPStone 441,
  MaxSPStone 416, PwrStone … ShockRes 0. **`Wizdom` (+0x30) carries stale bytes**: `", though"`, `"ful."`, `00×6 FF FF`
  *(captured)*: **confirms Z07-B7**. Handles: 8000 (first player on each zone process), then 8002, 8003, 8004 on 9210 and
  8001 on 9212: the player pool (Z01 §4.2, 8000..9499) hands out the next index, freed ones are not reused at once.
- **0x1802.logincoord can differ from 0x1038.currentcoord**: walk-run-portals zone#3 and #5 (Roumen, arriving from Forest
  of Mist) have base 5874/6530, ACK 5899/6530 (x + 25). `so_MapMarking` (Z01 §5.3) moved the player off the saved cell
  (the cell is occupied by the Roumen Teleport Gate NPC, §6.3); the other 5 agree. The client gets the saved position first and the
  real one in 0x1802.
- **0x441E** `{tResetYearQuest, tResetMonthQuest, tResetWeekQuest, tResetDayQuest}` (decoder names) are `time_t` of the
  **start of the current period** in server local time (UTC+1): 1767222000 = 2026-01-01 00:00, 1793487600 =
  2026-11-01 00:00, 1794178800 = Mon 2026-11-09 00:00, 1794697200 = 2026-11-15 00:00 (capture day). Z15 §5.6 calls them
  `{Year, Month, Week, Day}` of `m_QuestRestTime`: values are the last reset instants, not counters.
- **`&adminlevel`**: the client sends `NC_ACT_CHAT_REQ {itemLinkDataCount 0, len 11, "&adminlevel"}` in the same tick as
  every 0x1803 (7/7), unprompted (a character with admin level 0 was not captured). The
  zone answers with the GM command's notice "Admin level is 100" (Z11 `&adminlevel`). Client side not traced.
- **`sp_ConnectFromWhere`** @ FUN_0043f1f0 (2016) sends no WM message: if `basedata.adminlevel ≠ 0` it formats
  `"From %d.%d.%d.%d"` (the client IP) and sends it as a 0x2011 notice through vt 0x784, then clears `sp_ConnectFrom`.
  **Contradicts Z01 §6** ("WM 0x082A … → answer 0x082B"): 0x082B is a separate path (Z01 §9). Captured: the notice is
  in the burst between 0x182B and 0x1123, exactly where the call stands.
- **0x1803 tail is conditional** (code, found while checking the order): after `sp_SendUseItemMinimonInfo_Client`
  the handler takes the title block (vt 0x420) and `GetStateData(CurrentTitle, CurrentTitleElement)` @ FUN_005ca9b0;
  if either is null (title type ≥ 128 or element ≥ 4) **or** one of the title's state entries has no abstate, it jumps to
  the epilogue (disassembly 0x4442f4 / 0x444316 / 0x44433d → 0x443539 → 0x4448ff). Everything after it is then skipped:
  0x0810, 0x7C05 prison, 0x10C6, charged effects, `sp_ItemActionSetup` (0x482C), `sp_RemoveField`, 0x10D4, pets,
  raid data, GM events, 0x1827, 0x182C, map buffs, GameDB 0x34CF and the map's Lua `MapLogin`. Z01 §6 lists these
  as unconditional. (original bug) P02-B4: latent with valid data (title ids come from the DB / 0x1031 and
  `CCharacterTitleDataStateServer::Read` refuses unknown abstates, Z18 §6), but a bad `CurrentTitleElement` silently
  disables half of the login.
- **0x302D** `so_ply_FillRewardInven` @ FUN_004fc310: `len = irs_FillBufferItem(&counter, records) + 3` and
  `irs_FillBufferItem` @ FUN_00644c80 returns `end − &counter`, which already includes the counter byte, so every
  0x302D carries **one uninitialised byte after the records** (captured 0x12 / 0x10 with 0 items). (original bug)
  P02-B3. Z04 §8.3's layout `{u8 itemcounter, PROTO_ITEMPACKET_INFORM[]}` is right otherwise; the client reads
  `itemcounter` records and ignores the byte *(inferred)*.
- **0x1047 box order** is the zone's (`so_StoreInventoryFromServer`, one 0x1047 per box once the last inventory chunk is
  in): 9 inventory, 8 equipment, 12 mini-house, 15 action box. Equipment records (idle_in_world): slot 8 (35740), slot 10
  (weapon 1250), slot 25 (30817), matching the 0x1C02/0x1C05/0x1C03 of the burst; walk-run-portals: slot 10 (1250) only,
  matching its lone 0x1C05.
- **Blob spacing**: the client copies arrive in groups 40–50 ms apart (37, 82, 128, 178, 220, 266, 313, 360, 425 ms), not
  back-to-back as the WM sends them. *(inferred: TCP/Nagle on the zone→client link with the client's delayed ACK; the
  zone forwards each blob the moment its handler runs)*.

### 5.4 Logout *(captured)*

idle_in_world, comment "Character logout" at 96.530 s: zone `C 0x2012 STOP_REQ`, `C 0x1071 LOGOUTREADY` (same tick, with
the WM option saves of §4.1) → nothing from the zone (Z07 §3.3: arms `sp_Schedule_Logout` at +13 s and
`sp_NormalLogoutTick` = +8 s) → `C 0x0C18 {LogoutType 0}` at 106.566 s = **10.04 s** after 0x1071, together with the
WM 0x0C18 and after the WM's 0x0C34. 10.04 s > 8 s, so `0x0C18` (Z01 §8.1, FUN_00558690) runs `sp_Schedule_Logout` at
once; the zone sends the client nothing and the stream ends (the WM is told by 0x0C31). **Confirms** Z07 §3.3 and Z01
§8.1; the client's own countdown is 10 s. The zone handler of 0x1071 carries the profiler string of LOGOUTCANCEL (Z07
§3.3); handlers.json names op 0x1071 `NC_CHAR_LOGOUTCANCEL_CMD` from that string, the pdb2016 enum gives
`NC_CHAR_LOGOUTREADY_CMD = 113` (0x71).

### 5.5 Heartbeat on the zone *(captured)*

`S 0x0804` 30.0 s after the last client packet (idle_in_world 0.011 → 30.006 s, 35.07 → 65.083 s; walk-run-portals
zone#6 2.36 → 32.36 s): **confirms** `ClientSession::CheckHeartBeat` @ FUN_0045b110 → `ZoneBaseSession::CheckHeartBeat` @ FUN_005a67c0 (S02 §4.4, Z18 §1.4: 30 s
silence → 0x0804, close after 180 s more; the 300 passed by the client override is ignored). The
client answers within 4–14 ms, except during the first map load of idle_in_world (answered after 4.88 s, at 34.887 s,
just before 0x1803): the client's loader does not service the zone socket. The 0x0805 arrives in session mode 1
(before 0x1803) and is accepted (Z18 §1.3 session filter: 0x0805 allowed before LOGINCOMPLETE).

## 6. Zone in-world

Same 7 zone streams as §5, from one tick after the 0x1803 burst to the end of each stream: idle among mobs
(idle_in_world, 96 s in Roumen), run/walk in Roumen (walk-run-portals zone#1), four town-portal hops Roumen ↔ Forest of
Mist (zone#1→#2→#3→#4→#5) and one gate link Roumen → Forest of Tides (zone#5→#6). Only one player was on the server, so
every 0x2018 / 0x201A / 0x1C08 / 0x1C0E is about a mob or NPC. Code: Z02 §2/§5/§6, Z09 §2.4/§5.3/§9.6, Z01 §7.1/§7.3,
Z03 §2.2–2.3/§3.4. Opcodes of §5 that also occur in-world (0x1035, 0x240E, 0x240F, 0x10BD, 0x200B, 0x0804/0x0805) keep
their §5.2 status; their in-world instances are described here.

### 6.1 Message order *(captured)*

**Town portal** (4 hops; times relative to the click):

```
C 0x2401 NC_BAT_TARGETTING_REQ {target = Teleport Gate NPC}   (client clicks the NPC: target first)
S 0x2402 NC_BAT_TARGETINFO_CMD {order 0, …}                    +4..17 ms   to_SendInform @ FUN_0042b3f0 (Z03 §2.3)
C 0x200A NC_ACT_NPCCLICK_CMD {npchandle}                       +11..24 ms  (zone#1 also C 0x2012 STOP_REQ in the same tick)
S 0x243D NC_BAT_CEASE_FIRE_CMD {own handle}                    same or next tick (0..51 ms): smo_BashStop of 0x2401 sets
                                                               sp_CeaseFireSender, so_Routine sends it (Z03 §3.4)
S 0x201C NC_ACT_NPCMENUOPEN_REQ {mobid 191}                    InteractWithNPC @ FUN_004c4660: NPC.txt row NPCMenu = 1 (Z02 §6.2)
  … client town-portal window, 1.4–10 s …                      (no 0x201D: see §6.3)
C 0x181A NC_MAP_TOWNPORTAL_REQ {index} + C 0x200B ENDOFTRADE   same client tick
S 0x181B NC_MAP_TOWNPORTAL_ACK {0x19C1}                        +4..18 ms   FUN_0049fe70 (Z01 §7.3): success, so_ply_BriefLink
  zone → WM 0x180B, 0x180D LINKRESERVE; WM → zone 0x180E      (not on the wire; Z01 §7.1)
S 0x180A NC_MAP_LINKOTHER_CMD {mapIndex, x, y, zoneIp, zonePort, wmHandle}   +87..91 ms after 0x181B; last packet of the stream
C (new connection) 0x1801 to zonePort                          +0.41..0.58 s → §5.1
```

**Gate link** (zone#5, Roumen gate NPC `MapLinkGate` 17311, NPC.txt `Gate GateRou1`, role `NPCRole_Portal`):

```
C 0x2401 {17311}; C 0x200A {17311} (+11 ms)
S 0x2402 + S 0x3C01 NC_MENU_SERVERMENU_REQ (same tick, +19 ms)  NPCRole_Portal::nrb_Role @ FUN_004c2ef0: one link → "LinkTitle" menu
S 0x243D {own handle} (next tick, +65 ms)
C 0x3C02 NC_MENU_SERVERMENU_ACK {reply 0} (4.5 s later)         FUN_0050fe60 → sma_Reply → slot 0 = smfm_Link → so_LinkTo
S 0x180A {mapIndex 2, 17418, 13832, port 9214} +94 ms; stream ends   (no 0x181B, no 0x200B on this path)
```

**Movement.** The client reports its own moves: during a continuous run `C 0x2019 NC_ACT_MOVERUN_CMD` every 0.1–0.4 s
(walk `0x2017` the same), each `to` about 100 units ahead of `from`, and `C 0x2012 STOP_REQ {loc}` when it stops (also
before an NPC click and before `0x1071` at logout). The server answers none of them on success (no 0x203E, no 0x2013 to
the mover; see §6.3). One `S 0x201B NC_ACT_MOVEFAIL_CMD {back = 5862, 6677}` came 7 ms after a `0x2019` whose `from` and
`to` were both (5862, 6677): **confirms** Z02 §2.2 (`from == to` → `SendMoveFail` with the server position).

**Sight.** Objects enter with `S 0x1C08 NC_BRIEFINFO_REGENMOB_CMD` (44, all `mode 2`, `bRegenAni 0`), followed in the
same tick by the object's remembered move (0x2018 / 0x201A with `from == to` when it had already arrived: 6 of 6 such
moves directly follow the 0x1C08 of the same handle: **confirms** `ResendLastMove` FUN_005555e0, Z02 §5), and leave
with `S 0x1C0E NC_BRIEFINFO_BRIEFINFODELETE_CMD {hnd}` (22). With the client-reported position, objects appear at
1589–1637 units and are deleted at 1567–1608 units: the `MapInfo.Sight` 1600 of Roumen / Forest of Mist / Forest of
Tides (± the client/server position lag). **Confirms** Z09 §9.6 (the plain `MapInfo.Sight²` in
`AxialListBriefExchangerAtMove` / `AxialListBriefDeleteAtMove`, FUN_004bdde0 / FUN_004bdfe0). In-world there is no
0x1C09 batch (all 12 are in the login bursts, §5.1).

**Per-minute player check.** Once a minute every zone player gets two 10-entry `0x1035` one tick apart (40–56 ms):
idle 41.97 / 42.01 s past the minute, walk zone#1/#3/#5/#6 the same second (42.02–42.14 s past the minute, on both
9210 and 9214), so all zone processes share the phase *(the phase is probably the processes' common start second,
inferred)*. The ten entries are flags 0x12–0x1B (free-stat WC … MaxSP), the ones `smo_NotifyParameterChange` always sends
(Z12 §4.2). The two packets come from two code points: the per-minute block (Z09 §2.4) sets `p+0xe94 = 1`
(`smo_Abstate.parameterchange`, pdb2016) and calls `smo_NotifyParameterChange(1)` (vt 0x34) itself (first packet); on
the next tick `ShineMobileObject::so_Routine` @ FUN_0056a080 (Z09 §5.5) sees the dirty flag, recalculates and calls
`smo_NotifyParameterChange(1)` again (second packet), then clears the flag.

**Expiry of time-limited items** (idle_in_world 82.1 s, inside the per-minute check):

```
S 0x1035 (10)                                  82.103   per-minute (above)
S 0x1035 (10)                                  82.144   next tick
S 0x3002 NC_ITEM_EQUIPCHANGE_CMD {exchange 0x2008, location 8,  item 0xFFFF}   "[Critical] Red Elderine Uniform (1 Day)" 35740 gone
S 0x3002 NC_ITEM_EQUIPCHANGE_CMD {exchange 0x2019, location 25, item 0xFFFF}   "[Pickup] Mini Phino (1 Day)" 30817 gone
S 0x10BD NC_CHAR_CLIENT_AUTO_PICK_ACK {err 0x1E00, bEnable 0}                  the pick-up mini-mon is no longer worn
S 0x1035 (25)  MaxHP 3043 → 3033, MaxSP 2851 → 2841, every stat −2
S 0x240E {hp 3033, hpchangeorder 2}, S 0x240F {sp 2841}
```

Code path: `sp_ChargedItemLimitCheck` @ FUN_00451530 (Z09 §2.4) → `sp_ItemDelete` @ FUN_00451090 → `sp_DestroyItem` →
GameDB `0x3459 DESTROY_REQ` → `gds_NC_ITEMDB_DESTROY_ACK` @ FUN_005287b0 (Z05 §6.4): the cell is emptied (0x3002, Z05
§1.5) and `sp_SetAutoPick(0)` @ FUN_005654d0 sends 0x10BD. This answers the part-3 question why the auto-pick flag
flips at 82.1 s. In walk-run-portals (later that day) neither item was worn any more (§5.2 0x1C02 / 0x1C03 rows).

### 6.2 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x2019 | NC_ACT_MOVERUN_CMD | 154 | 16 | confirmed | `{from, to}` (Z02 §2.2); no server answer on success |
| C→S | 0x2017 | NC_ACT_MOVEWALK_CMD | 7 | 16 | confirmed | as 0x2019 |
| C→S | 0x2012 | NC_ACT_STOP_REQ | 12 | 8 | confirmed | `{loc}`; the 0x2013 broadcast of `so_mobile_StopHere` never reaches the mover (sight broadcast without the sender) |
| S→C | 0x201B | NC_ACT_MOVEFAIL_CMD | 1 | 8 | confirmed | `{back}` = the position the client sent with `from == to` (§6.1) |
| S→C | 0x2018 | NC_ACT_SOMEONEMOVEWALK_CMD | 119 | 22 | confirmed | mobs only; `speed` = MobInfo.WalkSpeed of the mob (30 / 40), `from` = previous `to` of the same handle; `moveattr` stale (§6.3) |
| S→C | 0x201A | NC_ACT_SOMEONEMOVERUN_CMD | 35 | 22 | confirmed | `speed` = MobInfo.RunSpeed (105 / 110); 154 of 154 mob moves match MobInfo.shn |
| S→C | 0x1C08 | NC_BRIEFINFO_REGENMOB_CMD | 44 | 149 | confirmed (pdb2016 layout) | objects entering sight: `mobid` = MobInfo ids (Slime 0, Mushroom 1, Hero Slime 2000, Snowbank 10004, Teleport Gate 191, Gate 32, Christmas tree 178, signs/merchants …), `coord` = NPC.txt position for NPCs, `nKQTeamType` 2, `bRegenAni` 0 (no respawn captured); Z09 §5.3 offsets +0x72…+0x94 confirmed |
| S→C | 0x1C0E | NC_BRIEFINFO_BRIEFINFODELETE_CMD | 22 | 2 | confirmed | `{hnd}`; **confirms Z09 §9.6** (sender `AxialListBriefDeleteAtMove::ali_Work` @ FUN_004bdfe0) and **contradicts Z02 §5.2** "no zone code sends 0x1C0E"; no NPC (kind 4) handle is ever deleted; mob-kind Christmas trees are |
| C→S | 0x2401 | NC_BAT_TARGETTING_REQ | 5 | 2 | confirmed | `{target}`: the client targets an NPC before clicking it |
| S→C | 0x2402 | NC_BAT_TARGETINFO_CMD | 5 | 30 | confirmed | order 0 only; NPC values hp 0 / maxhp 0 / sp 100 / maxsp 100 / lp 0 / level 0; `hpchangeorder` 1 on the first, 2 on the second targeting of the same NPC after a re-login to that zone process: **confirms** Z03 §2.3 (the target's own counter, incremented by the read) |
| S→C | 0x243D | NC_BAT_CEASE_FIRE_CMD | 5 | 2 | confirmed | `{own handle}` 0–65 ms after 0x2401: Z03 §3.4 (deferred `sp_CeaseFireSender`, to sight including the player) |
| C→S | 0x200A | NC_ACT_NPCCLICK_CMD | 5 | 2 | confirmed | `{npchandle}` (Z02 §6.2) |
| S→C | 0x201C | NC_ACT_NPCMENUOPEN_REQ | 4 | 2 | confirmed | `{mobid 191}` for the Teleport Gate (NPC.txt `Gate_Town … 1 QuestNpc`: NPCMenu 1) |
| C→S | 0x181A | NC_MAP_TOWNPORTAL_REQ | 4 | 1 | confirmed | `{index}` = TownPortal.shn row: 1 → RouVal01 (13658, 7812), 0 → RouN (5874, 6530) |
| S→C | 0x181B | NC_MAP_TOWNPORTAL_ACK | 4 | 2 | confirmed | `{0x19C1}` success (Z01 §7.3); the code has no row in `client-error-codes.json` |
| S→C | 0x180A | NC_MAP_LINKOTHER_CMD | 5 | 30 | confirmed | Z01 §7.1 layout; `{150 RouN, 5874, 6530}`, `{5 RouVal01, 13658, 7812}` (= TownPortal rows), `{2 RouCos02, 17418, 13832}` (= NPC.txt `LinkTable GateRou1`); zoneIp "172.16.42.214" + NUL padding, ports 9210 / 9212 / 9214, `wmHandle` 17500 = the WM handle (§4.3); `zoneIp` NUL-padded, no stale bytes |
| S→C | 0x3C01 | NC_MENU_SERVERMENU_REQ | 1 | 208 | confirmed | title "Do you want to move to Forest of Tides field?" (script string `LinkTitle` + MapInfo.Name), priority 0, npcHandle 17311, npcPosition (6457, 10501), limitRange 1000, menunum 2: `{0 "Yes"}`, `{1 "No"}` (`SERVERMENU {u8 reply, char string[32]}`); 128 + 1 + 2 + 8 + 2 + 1 + 2 × 33 = 208 |
| C→S | 0x3C02 | NC_MENU_SERVERMENU_ACK | 1 | 1 | confirmed | `{reply 0}` = "Yes" → `smfm_Link` |
| S→C | 0x3002 | NC_ITEM_EQUIPCHANGE_CMD | 2 | 5 | confirmed | `{u16 exchange = box 8 << 10 \| slot, u8 location = slot, SHINE_ITEM_VAR item = 0xFFFF (empty)}` (Z05 §1.5); `attributes` is empty for an empty item (decoder fixed in part 5: `bytes` = rest of the payload) |

In-world instances of §5 opcodes: 0x1035 (per-minute pairs, expiry, §6.1), 0x240E / 0x240F (after the expiry), 0x10BD
(expiry), 0x200B (with every 0x181A), 0x0804 / 0x0805 (§5.5). No 0x2011 notice, 0x2001 chat or 0x1C09 in-world.

### 6.3 Field findings

- **0x203E is not sent after moves.** Z02 §2.2 (and Z09 `so_MoveByServer`) read `p.vt[0xd4c](1)` as "send 0x203E,
  forced". `ShinePlayer::so_SendSpeedInformation` @ FUN_00459540 sends when the run or walk speed differs from
  `sp_SpeedNotice` **or the argument is 0**; with 1 it sends only when a speed changed. 161 client moves, no 0x203E
  after the login burst *(captured)*: the argument means "only if changed". (Its assert text says
  `sp_NC_ACT_MOVERUN_CMD : Packet Too Long`, copied from the run handler.)
- **`moveattr` of mob moves**: the low byte is even in all 154 mob 0x2018 / 0x201A and both bytes are ASCII text
  (`ll`, `, `, `t `, `ne`, `er`, `th` …): stale `gpp` content with bit 0 cleared. **Confirms** Z02-B2 (and Z09 §9 /
  Z13 for the mob and mover paths).
- **Town portal arrival is occupied**: TownPortal.shn row 0 (RouN 5874, 6530) is exactly the NPC.txt position of the
  Roumen `Gate_Town` NPC (handle 17252, 0x1C08 coord 5874/6530). That is why `so_MapMarking` moved the arriving player to
  x + 25 in zone#3 and #5 (§5.3, reason now captured, not inferred). Forest of Mist's gate NPC stands at 13660, 7862, 50
  units from its TownPortal row (13658, 7812): no shift there.
- **Client side of 0x201C**: `GameFrameWork` handler FUN_004b5560 looks the mob id up in MobViewInfo; for
  `MiniMapIcon` (+0xAA) = 23 (Gate_Town) it opens its town-portal window (FUN_0048c460, window at GameFrameWork +0x4dc)
  instead of `NpcDialogWin::OpenNpcNormalDialog`, and never sends 0x201D; the window sends 0x181A and then 0x200B.
  (Z02 §6.2 says "the client shows the NPC's dialog and answers 0x201D", which holds for other NPCMenu NPCs.)
- **0x3C01 `npcPosition`** (6457, 10501) is neither the gate's NPC.txt position (6477, 10579) nor the client's last
  stop (6456, 10525): it is the player's server-side position. `NPCRole_Portal::nrb_Role` @ FUN_004c2ef0 calls
  `ShinePlayer::sp_ServerMenuOpen` @ FUN_0054eaa0 with a NULL `SHINE_XY_TYPE*`, and `sp_ServerMenuOpen` then writes
  `*(p+0x66)` (`so_LocateInfo.location`, pdb2016) into `npcPosition` (packet +0x85 / +0x89) and stores the same point as the
  menu actor's origin for the `limitRange` 1000 check (Z02 §6.6). The server position lags the client's last stop.
- **0x2402 for NPCs**: hp / maxhp 0, sp / maxsp 100, level 0 (the NPC's vt 0x4e8 / 0x4f0 / 0x4ec / 0x4f4 / 0x4d8;
  Gate_Town has MobInfo Level 0, MaxHP 0). The SP slots resolve to `ShineMob::so_GetSP` @ FUN_00556940 (`sm_SP`) and
  `ShineMob::so_MaxSP` @ FUN_00556920 (`sm_MobDataBox->serv->MaxSP`), and MobInfoServer.shn has `MaxSP` 100 for
  Gate_Town (191) and MapLinkGate (32): the 100 is table data.
- **0x1C0E delivery**: the player received the deletes caused by its own moves (o = player, second send of
  `ali_Work`), so Z09-B13 (wrong first argument of `pcb_Append`) has no visible effect while the buffer is not full
  *(captured, consistent with Z09's inferred effect)*.

## 7. Server links (batch 2)

The batch-2 captures (`shop`, `combat`, §1) also hold the loopback traffic between the server processes on
172.16.42.214. The decoder names a link stream after its listener (ServerInfo.txt): `AccDB` 9000 (Account), `ALDB` 9311
(AccountLog), `W00_CDB` 9411 (Character), `W00_GLDB` 9511 (GameLog), `Login` 9011 (Login's WM listener), `W00_WM` 9111
(the WM's zone listener). On a link, "C→S" means connecting server → listener. Every link was up before recording
started, so no `0x0801`–`0x0803` handshake was captured.

### 7.1 Transport on the links *(captured)*

- **Framing and cipher**: README §1.1 framing; no `0x0807` seed and no XOR on any link (plaintext both ways, as
  `pcap_decode.py` assumes). The short and long length forms are the same as on client streams. All 3 440 batch-2
  packets parse without a resync.
- **Connections per capture** (the same in both): AccDB 2, ALDB 2, Login 1, W00_WM 16, W00_CDB 17, W00_GLDB 18.
  All servers share one IP, so the connecting process is identified by content:
  - AccDB: one link from Login (`0x0C5B`, `0x0C10`) and one from the WM (`0x0C60`).
  - ALDB: one link from Login (`0x0C5D`, `0x0721`, `0xC801`) and one from the WM (`0x0809` / `0x080A` / `0xC811`).
  - Login: the WM's link to Login.
  - W00_WM: 4 of the 16 links get every WM→zone broadcast (`0x0C16`, `0x0821`, `0x580D`, `0x987A` / `0x987B`), so
    they are one per zone process (Zone00–03). The other 12 carry per-character traffic (`0x101C`, `0x104B`, `0x40xx`).
  - W00_CDB: one WM link (`0x0C12`, `0x1004` …) and 16 zone links.
  - 16 = 4 zones × 4 links per DB / WM listener: `SocketBundle<…>` `sb_SocketStr[4]`, round robin per send (§7.5.1).
- **Heartbeat**: either end sends `0x0804` (empty) when it has received nothing on that link for 30 s, and the other
  end answers `0x0805` (empty) within 1 ms. Every idle link shows requests exactly 30.0 s apart. Most come from the
  connecting side, but on the W00_WM main links and some CharDB links the listener sends them. Longer gaps (42–81 s)
  occur only on links that carried other traffic in between. This is the Login rule (`login-server.md` §2; L01 §1.6
  `ProcHeartBeat` on every link) running on both ends of every link.
- **Timestamps**: the pcapng holds a LAN and a loopback interface, and the file does not keep their frames in time
  order (e.g. the first AccDB frame, 2.877 s, comes before LAN frames stamped 2.845 s). Sorted by timestamp, every
  request/answer chain is causal with 1–15 ms steps, so both interfaces share one clock. All orders below are by
  timestamp.

### 7.2 Login, Account and AccountLog links: message order *(captured)*

`shop` capture, times in s (`combat` gives the same order, each step within ±20 ms):

```
2.866  client → Login     0x0C5A US_LOGIN_REQ + 0x0C04 XTRAP_REQ (same tick)
2.877  Login → AccountDB  0x0C5B PASSWORD_CHECK_REQ               (Login → client 0x0C05 in the same ms)
2.880  AccountDB → Login  0x0C5C nError 0x41 (ok)
2.892  Login → AcctLogDB  0x0C5D IS_IP_BLOCK_REQ
2.908  AcctLogDB → Login  0x0C5E bUserIPBlock 0
2.910  Login → WM         0x0C16 KICKOFFFROMWORLD {userNo 103}  + Login → AcctLogDB 0xC801 (same ms)
2.918  Login → client     0x0C0A world list
2.923  WM → zone ×4       0x0C16 {FF×6, 103}                       (first kick, W01 §5.2)
3.954  client → Login     0x0C0B world 0
3.960  Login → AccountDB 0x0C10, → AcctLogDB 0x0721, → WM 0x0C0D   (same ms, this order)
3.977  WM → Login         0x0C0E ok 1
3.993  Login → client     0x0C0C (WM address, validate[32])
4.042  WM → client 0x0807 seed;  4.050 client → WM 0x0C0F
4.059  WM → zone ×4       0x0C16 {FF×6, 103}                       (second kick, W01 §3.2)
4.059  WM → AccountDB     0x0C60 RETURN_CHECK_REQ;  4.060 AccountDB → WM 0x0C61
4.075  WM → CharDB        0x0C12 AVATARINFO_REQ;  4.076 0x0C5F, 4.078 0x0C13   (§7.4)
4.104  WM → client        0x0C14 avatar list
```

**Confirms** the `login-server.md` §4 / §5.1 / §5.2 handler order and its §6 summary (`0x0C5A → 0x0C5B → 0x0C5C →
0x0C5D → 0x0C5E → 0x0C16 + 0x0C0A + 0xC801`; `0x0C0B → 0x0C10, 0x0721, 0x0C0D → 0x0C0E → 0x0C0C`). It also confirms W01
§3.2 / §3.3: on world login the WM kicks on every zone, then runs `0x0C60` → `0x0C61` → the avatar request → `0x0C14`.
Each login therefore sends 2 × 4 zone kicks (one from Login's `0x0C16`, one from the WM's own `0x0C0F`).

Periodic traffic:
- WM → Login `0x0808` every 30.0 s (25.7, 55.8, 85.7, 115.8, 145.7 s): W01 §2 `Login_WorldStatus` **confirmed**.
- AccountLog → WM `0x0809` at the start of each minute: 58.802 s, while the WM's `0x0849` for 12:03:00 goes out at
  58.804 s; then 119.293 s; in `combat` 43.397 and 102.901 s. The sender is `CStatistics::Process` @ AL:FUN_004064b0:
  when the local `tm_min` changes, it sends a raw 4-byte `{03, 0x0809, b}` to every type-5 (WM) session. The WM answers
  with `0xC811`, then `0x080A`, the order of W01 §8 (**confirmed**): in the same ms at `shop` 119.293 and `combat`
  102.901, 15 ms later at `shop` 58.802 → 58.817 and 3 ms later at `combat` 43.397 → 43.400 (the next WM pass). Only
  the first 0x0809 is in step with the WM's `0x0849` (2 ms); in `combat` it leaves 0.6 s / 0.12 s after the 0x0849
  (42.801 / 102.777), so the two minute clocks are not aligned. D01 §4.2 calls 0x080A "WM every
  interval": **corrected**, the WM sends it only as the answer to 0x0809, once per AccountLog minute.

### 7.3 Opcodes (Login, Account, AccountLog links)

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| Login→AccountDB | 0x0C5B | NC_USER_US_PASSWORD_CHECK_REQ | 2 | 338 | confirmed | `clienthandle` = Login client handle (5600 / 5200), `sUserName "admin"`, `sPassword` = 32 lowercase hex chars = MD5("admin") `21232f29…` (the client hashes; Login forwards it unchanged), `sUserIP "172.016.042.231"` (`%03d` format, `login-server.md` §4), `spawnapps "Original"` |
| AccountDB→Login | 0x0C5C | NC_USER_US_PASSWORD_CHECK_ACK | 2 | 353 | confirmed | `nError 0x41` (ok), `nUserNo 103`, request strings echoed, `nAuthID 9`, `nBlock 0`, `bLoginAble 1` (D01 §3.2) |
| Login→AccountLogDB | 0x0C5D | NC_USER_US_IS_IP_BLOCK_REQ | 2 | 379 | confirmed | `LoginData` = the 0x0C5C body (0x161), `nUserNo 103`, `nClientHandle`, `sUserIP` |
| AccountLogDB→Login | 0x0C5E | NC_USER_US_IS_IP_BLOCK_ACK | 2 | 356 | confirmed | `LoginData` copy, `nClientHandle` at +0x161, `bUserIPBlock 0` at +0x163: the offsets of `login-server.md` §5.2 |
| Login→AccountLogDB | 0xC801 | NC_SYSLOG_ACCOUNT_LOGIN_SUCCESS | 2 | 40 | **contradicted** (L00-B6) | `UserNo 103`, `UserIP "172.16.42.231"` (`%d` format, NUL-padded), `spawnapps "Original"` at +0x14 (2016 40-byte layout, D01 §4.5). `fc_NC_USER_US_IS_IP_BLOCK_ACK` @ FUN_004058c0 zeroes `Data[4..0x13]`, then copies `sprintf("%d.%d.%d.%d", ip)` into it with `strncpy(Data + 4, …, 0x10)`: the IP is filled, so L00-B6 ("UserIP zeroed") is not a bug |
| Login→WM | 0x0C16 | NC_USER_KICKOFFFROMWORLD_CMD | 2 | 10 | **corrected** | 10 bytes, not `{u32 userNo}` (`login-server.md` §4, §5.1, §5.2; the pdb2017 struct is 4 bytes). The handler builds the raw header `{0x0C, 0x0C16}` on the stack, writes `usrregnum` at +6 and `BroadCast`s 0xD bytes, so the 6 bytes before `usrregnum` (the `NETPACKETZONEHEADER` slot) are never written: `76 27 d3 ef 76 00` in both captures. (original bug) P02-B5. The WM reads `userNo` at +6 (W01 §5.2 **confirmed**) |
| WM→Zone | 0x0C16 | NC_USER_KICKOFFFROMWORLD_CMD | 16 | 10 | confirmed | header all `0xFF`, `usrregnum 103` (W01 §3.2 / §5.2); 4 per event (one per zone process), 2 events per login (§7.2) |
| Login→AccountDB | 0x0C10 | NC_USER_LOGIN_DB | 2 | 9 | confirmed | `usrregnum 103`, `worldnum 0`, `ip` bytes `ac 10 2a e7` = 172.16.42.231 in network order |
| Login→AccountLogDB | 0x0721 | NC_LOG_USER_LOGIN | 2 | 9 | confirmed | same body as 0x0C10 |
| Login→WM | 0x0C0D | NC_USER_WILLLOGIN_REQ | 2 | 347 | confirmed | 0x15B bytes: `clienthandle` = Login client handle, world 0, `usrregnum 103`, `userid "admin"`, `validate_new[32]` = the words the client then sends in WM 0x0C0F (§4.2), `spawnapps "Original"` at +0x147 (W05 §5.3 names) |
| WM→Login | 0x0C0E | NC_USER_WILLLOGIN_ACK | 2 | 348 | confirmed | the 0x15B request verbatim + `ok 1` (W01 §3.1) |
| WM→Login | 0x0808 | NC_MISC_USER_COUNT_CMD | 9 | 4 | confirmed | `{NumOfUser 1, MaxOfUser 2500}` every 30 s; 2500 = the `nMaxAccept` of the WM client listener (ServerInfo.txt `PG_W00_WM` type 20), no OPTool limit set (W01 §2) |
| WM→AccountDB | 0x0C60 | NC_USER_RETURN_CHECK_REQ | 2 | 6 | confirmed | `nHandle` = WM client handle (35000 / 32500, the `worldmanager` of the following 0x0C14), `nUserNo 103` |
| AccountDB→WM | 0x0C61 | NC_USER_RETURN_CHECK_ACK | 2 | 11 | confirmed | `bReturnUser 0`, `tLastSec` 174 618 (`combat`) and 174 902 s (`shop`, 284 s later): with no comeback row, D01 §3.3 falls back to `usp_User_GetDatediffCreated`, i.e. seconds since the account was created (≈ 2.02 days). The WM takes the `hasHistory = 0` branch (W01 §3.3) |
| AccountLogDB→WM | 0x0809 | NC_MISC_CONNECTER_REQ | 4 | 1 | **corrected** (size) | 1 payload byte. `CStatistics::Process` @ AL:FUN_004064b0 reuses its `CSession_Manager *` parameter as the 4-byte packet buffer (`CONCAT13(ptr >> 24, 0x080903)`), so the byte is the high byte of that pointer (0x00 here). The 2016 / 2017 PDB struct is empty. (original bug) P02-B6. Layout in `annotations/P02.json` |
| WM→AccountLogDB | 0xC811 | NC_SYSLOG_SERVER_CCU | 4 | 5 | confirmed | `UserCount 1, WorldNo 0` |
| WM→AccountLogDB | 0x080A | NC_MISC_CONNECTER_ACK | 4 | 131 | confirmed | `worldno 0`, `connectercount 1`, `nEachClass[6] = 1`: the character in game is Test2 (0x0C14 shape byte 0x19 → class `(0x19 >> 2) & 0x1F` = 6), counted from the SHAPE byte as W01 §8 says |
| both | 0x0804 / 0x0805 | NC_MISC_HEARTBEAT_REQ / _ACK | 457 / 458 | 0 | confirmed | §7.1 |

### 7.4 WM ↔ Character DB *(captured)*

The WM's link to the Character server is `W00_CDB#1` (`shop`) / `W00_CDB#4` (`combat`), client port 49823 in both. It
carries one avatar list, one character load and the option and guide forwards of one session per capture. Every packet
on it decodes without an issue: P02 added CharDB→WM layouts (WM `clienthandle` + the pdb2016 struct) to
`annotations/P02.json` `packets.wm` (0x1008, 0x100A–0x100E, 0x1012, 0x1017, 0x1019, 0x101A, 0x101B, 0x1097, 0x10CC,
0x10CF, 0x10D2, 0x10D5, 0x10D8, 0x10DC, 0x10E2, 0x10E5, 0x10E8), a `tm` struct, and a decoder rule (link opcodes try
every annotation of the opcode, §15). Before that, 26 of the 51 packet types had field issues: the pdb2016 structs leave
out the handle that D02 §4 says every block starts with.

**Message order** (`shop`, s; `combat` matches step for step, each block within 1 ms of the `shop` offset):

```
4.075  WM → CDB  0x0C12 AVATARINFO_REQ {35000, userNo 103}
4.076  CDB → WM  0x0C5F TUTORIAL_CAN_SKIP {isSkip 0};  4.078 0x0C13 avatar list (2 avatars)    (D02 §3.1 order)
5.693  client → WM 0x1001 LOGIN_REQ slot 1;  5.696 WM → CDB 0x1004 CHARDATA_REQ               (W01 §4.2, same pass)
5.698 … 5.715  CDB → WM, 37 packets (36 blocks + 0x1005) in D02 §4 step order:
       0x1007 base, 0x541C friend points, 0x101A KQ map, 0x1008 shape, 0x100A / 0x100B / 0x10CC / 0x10D5 quests,
       0x100D skills, 0x100E passives, 0x100C abstates, 0x9427 / 0x9429 / 0x9444 holy promise, 0x1012 guild,
       0x1097 academy, 0x1017 ×4 items, 0x1019 titles, 0x101B charged buffs, 0x10D2 single option,
       0x702C–0x702F improved options, 0x10CF item cool-times, 0x10D8 guide list, 0x10DC coins,
       0x10E2 / 0x10E5 / 0x10E8 card collection, 0x1114 tutorial, 0x111E chat colour, 0x1121 minimon, 0x1005 done
6.295  WM → CDB 0x1036 LOGIN_DB;  WM → GameLog 0xC806 (+ CDB's own 0x040A to GameLog 1 ms later, D02 §5);
       WM → client 0x1003 LOGIN_ACK (same ms)
6.342  WM → client 0x7032 / 0x7033 / 0x7034 (option push, §4.1)
6.798  client → WM 0x7004, 0x700C, 0x7C06 (one tick);  6.801 WM → CDB 0x7019;  6.804 CDB → WM 0x701A → client 0x7005
6.817  WM → CDB 0x7021;  6.822 CDB → WM 0x7022 → client 0x700D (6.885)
10.766 WM → CDB 0x10EB attendance list (first map login);  10.768 CDB → WM 0x10EC
19.304, 30.568  WM → CDB 0x10DB guide view set (after client 0x10DA, §4.2)
```

- **D02 §4 confirmed** step by step, with these steps absent: 12 (0x1010, Test2 has no friends), 18 (0xA801, no chat
  ban), the old-option packets of step 20 (`DataType 2` = improved), and 21 / 22 (0x0844, 0x10CA). D02 §4 says those two
  send zeros on error; the code of `FUN_00438dc0` sends them **only when `usp_SpamFilter_get` / `usp_SpamBlock_getTime`
  return a row**: a failed call is logged and a call with no row sends nothing. **Corrected** (D02). The WM still sends
  the zone 0x10CB (14 bytes, 6.389 s) without a 0x10CA: its chat-block copy (W01 §6.3, +0x1ECE4) is 8 bytes inside the
  session, not a blob pointer, so it goes out whatever it holds (values checked in part 9, §7.5).
- **W05 §1.4 confirmed on the wire**: the WM handles at most one packet per session per main-loop pass. The 37 packets
  (36 blocks + 0x1005) arrive within 17 ms, yet the WM handles 0x1005 (and sends 0x1036 / 0x1003) only 580 ms (`shop`) / 557 ms (`combat`)
  after it arrived: 580 / 37 ≈ 15.7 ms and 557 / 37 ≈ 15.1 ms per pass, one 15.6-ms Windows timer tick, which is the `Sleep(5)` that `MainThread` @ FUN_00407340 makes on every pass while
  the CharDB link is in state 1 (W05 §1.2, W05-B1: state 1 is normal operation) at Windows timer granularity *(inferred
  for the rounding)*. The three client requests of 6.798 s show the same thing: 0x7019 leaves after 3 ms, 0x7021 one
  pass (16 ms) later.
- W01 §4.2 0x1005 handler order **confirmed**: 0x1036 to CharDB, 0xC806 to GameLog, 0x1003 to the client in one ms. The
  option push `SendToClient_CharOptionData` @ FUN_00431680 is called right after the 0x1003 send (`fc_NC_CHAR_CHARDATA_ACK`
  @ FUN_00410040), yet its three packets leave 47 ms (both captures) after 0x1003. The sockets keep Nagle on (S02 §1.4:
  no `TCP_NODELAY`), so the next small segment waits until the client ACKs 0x1003 (client delayed ACK); pure ACK
  frames are not in the captures *(inferred)*.
- The client's 0x7004 / 0x700C come 2–3 ms after the zone's 0x1802 `NC_MAP_LOGIN_ACK` (6.796 / 6.870 s): W04 §8.2
  **confirmed**. The 0x10EB request follows the client's zone 0x1803 by 4 ms (10.762 → 10.766 s), i.e. the WM's
  first-map-login handler (W04 §17.5, the zone → WM side is §7.5).

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| WM→CDB | 0x0C12 | NC_USER_AVATARINFO_REQ | 2 | 6 | confirmed | `{clienthandle 35000 / 32500, usrregnum 103}` (W01 / D02 §3.1) |
| CDB→WM | 0x0C5F | NC_USER_TUTORIAL_CAN_SKIP_CMD | 2 | 3 | confirmed | `isSkip 0`, 1–3 ms before 0x0C13 (D02 §3.1, W01 §3.3) |
| CDB→WM | 0x0C13 | NC_USER_AVATARINFO_ACK | 2 | 263 | confirmed | handle + `numofavatar 2` + 2 × 130-byte AVATAR, forwarded as client 0x0C14 (§4.2). `delinfo` bytes again pointer-like (P02-B1). `dKQDate` bits 30–31 differ between the lists (Test2 `0x8B058FBA` / `0x40D96FBA`) while bits 0–29 equal the 0x101A date: `GetAvatarInfo` @ FUN_0046bff0 ORs the packed date into `*(u32*)(a+0x73) & 0xC0000000`, keeping two buffer bits. (original bug) P02-B7 |
| WM→CDB | 0x1004 | NC_CHAR_CHARDATA_REQ | 2 | 14 | confirmed | `{handle, chrregnum 5, nUserNo 103, tExchangedCoinSumDate 1794718800}` = 15 Nov 06:00 local: `CGambleSystemServer::GetSendExchangeCoinInitTime` (next `GBHouse.shn` `GB_ResetTime` 06:00:00) − 1 day, as W01 §4.2 reads it (its "day start" is the gamble reset time) |
| CDB→WM | 0x1007 | NC_CHAR_BASE_CMD | 2 | 107 | confirmed | D02 §4.1 layout: Test2 lvl 5, exp 22 (`combat`) → 30 (`shop`, after the kills), HP / SP stones 13 / 10, Cen 99 440, RouN (5904, 6793) / (5724, 8768), dir 90, adminlevel 100, fame 14 |
| CDB→WM | 0x541C | NC_FRIEND_DB_POINT_CMD | 2 | 10 | confirmed | `{1, {5, 0, 0}}`: the character's own entry (D02 §4 step 2); no second 0x541C after 0x1036 (no friends) |
| CDB→WM | 0x101A | NC_CHAR_KQMAP_CMD | 2 | 30 | confirmed | handle + 28-byte pdb2016 struct: `nKQHandle −1`, `"RouN"` + the 0x1007 position, `dKQDate` 15 Nov 12:01:11 (`shop`) / 11:54:00 (`combat`): between the captures, so the KQ columns hold the last saved position and time (as §4.3 inferred for the AVATAR copy) |
| CDB→WM | 0x1008 | NC_CHAR_SHAPE_CMD | 2 | 6 | confirmed | handle + `PROTO_AVATAR_SHAPE_INFO` `{0x19, 2, 1, 4}` = the AVATAR shape. No struct in either PDB: layout in P02.json |
| CDB→WM | 0x100A | NC_CHAR_QUEST_DOING_CMD | 2 | 8 | confirmed | `{handle, chrregnum 5, bNeedClear 1, n 0}`: `FUN_0046cb00` always writes `bNeedClear = 1` |
| CDB→WM | 0x100B | NC_CHAR_QUEST_DONE_CMD | 2 | 18 | **corrected** (size) | header `{5, nTotalDoneQuest 0, nTotalDoneQuestSize 12 (= 10n + 12), nDoneQuestCount 0, nIndex 0}` = 14 bytes, then 4 more zero bytes: `SendQuestDone` @ FUN_004288d0 sizes each part `0x12 + 10n`, 4 more than the header + records. (original bug) P02-B8 |
| CDB→WM | 0x10CC / 0x10D5 | NC_CHAR_QUEST_READ_CMD / _REPEAT_CMD | 2 + 2 | 8 | confirmed | `{handle, 5, n 0}` |
| CDB→WM | 0x100D | NC_CHAR_SKILL_CMD | 2 | 427 | confirmed | `PartMark 3` (start + end), `nMaxNum 26`, `number 26`, 16-byte records: skill 1500 (`savetime` set) + 25 ids 29001–29746 (the class's default list, D02 §4 step 9) |
| CDB→WM | 0x100E | NC_CHAR_SKILL_PASSIVE_CMD | 2 | 4 | confirmed | `{handle, number 0}` |
| CDB→WM | 0x100C | NC_CHAR_ABSTATE_CMD | 2 | 8 | confirmed | `{handle, 5, n 0}` |
| CDB→WM | 0x9427 | NC_HOLY_PROMISE_DB_GET_UP_ACK | 2 | 48 | confirmed | no handle; `DBError 0x1740` (ok), `PromiseCharNo −1` (no master), dates from the current time (D04 §8 0x9426, D02 §4 step 11) |
| CDB→WM | 0x9429 | NC_HOLY_PROMISE_DB_GET_MEMBER_ACK | 2 | 8 | confirmed | `{5, 0x1740, nPart 3, nMemberCount 0}` |
| CDB→WM | 0x9444 | NC_HOLY_PROMISE_DB_GET_REMAIN_MONEY_CMD | 2 | 12 | confirmed | `{5, nMoney 0}` |
| CDB→WM | 0x1012 | NC_CHAR_GUILD_CMD | 2 | 6 | confirmed | `{handle, nGuildNo 0}`; the client-side `GUILD_CLIENT` tail of the PDB struct is not on this link |
| CDB→WM | 0x1097 | NC_CHAR_GUILD_ACADEMY_CMD | 2 | 7 | confirmed | `{handle, nGuildAcademyNo 0, isGuildAcademyMember 0}`; the byte D02-B7 says is never written was 0 both times |
| CDB→WM | 0x1017 | NC_CHAR_ITEM_CMD | 8 | 114 / 86, 83, 22, 5 | confirmed | one part per storage, each `PacketOrder 0x80` (last): part mark 5 inventory (`combat` 4 items: 3000 Spirit Dust, 3001 Meat, 38043 Wooden Horse, 46003 Damaged Mystery Vault; `shop` + 3004 Bone, 3005 Leather, picked up in `combat`), 8 equipped (750 Short Mace at slot 12), 0x10 storage 12 (31000 Mushroom House), 0x22 storage 15 (empty). Locations `storage << 10 \| slot` (D02 §4 step 15; record content D03) |
| CDB→WM | 0x1019 | NC_CHAR_CHARTITLE_CMD | 2 | 1033 | confirmed | handle + `CHARACTER_TITLE_READBLOCK` (0x407, pdb2016), `NumOfTitle 0`, 0x409 + 2n as D02 §4 step 16. `FUN_0046d2c0` fills `TitleValues[type]` from rows with element 0xFF: type 4 (ID_PLAY_TIME) 73 → 80, type 9 1 → 2, type 11 (ID_TOTAL_KILL_MOB) 7 → 11 between `combat` and `shop`. The character died once in `combat`, yet type 9 is `ID_NOKILLED_BY_MOB` and 8 is `ID_KILLED_BY_MOB` (pdb2016) *(open, §14)* |
| CDB→WM | 0x101B | NC_CHAR_CHARGEDBUFF_CMD | 2 | 4 | confirmed | `{handle, 0}` |
| CDB→WM | 0x10D2 | NC_CHAR_FREESTAT_SET_DB_ACK | 2 | 17 | confirmed | the single-option block of D02 §4 step 19 (`FUN_0046dc00`, SetOpcode size 0x11), **not** the 15-byte CharDB→Zone free-stat ack D02.json annotates under the same opcode: `{handle, nCharNo 5, i32 time, u8 col2 0, u8 col1 1, u32 col4 0, u8 1}`. The time equals the 0x101A `dKQDate` (the last save). Layout (our field names) in P02.json; the decoder picks it by size |
| CDB→WM | 0x702C | NC_CHAR_OPTION_IMPROVE_DB_GET_DATA_TYPE_CMD | 2 | 8 | confirmed | `DataType 2` (improved), W04 §8.1 |
| CDB→WM | 0x702D / 0x702E / 0x702F | …_IMPROVE_DB_GET_SHORTCUTDATA / _KEYMAP / _GAMEOPTION_CMD | 2 each | 48 / 386 / 90 | confirmed | 6 short-cuts (skill 1500; items 38043, 3500 / 3505 HP / SP Potion Tier 1), 95 key-map entries (the W04 §8.2 limit is < 0x60), 28 game options. The WM forwards `payload+4` as client 0x7032 (44) / 0x7033 (382) / 0x7034 (86) (W04 §8.1) |
| CDB→WM | 0x10CF | NC_CHAR_ITEMACTIONCOOLTIME_CMD | 2 | 4 | confirmed | `{handle, num 0}`, records `ActionCooltime {u16 actionID, i64 expiredTime}` (pdb2016; `FUN_0046dd40`) |
| CDB→WM | 0x10D8 | NC_CHAR_NEWBIE_GUIDE_VIEW_LIST_CMD | 2 | 30 / 29 | confirmed | `{handle, n, u8 list[n]}`: 26 guide ids in `combat`, 27 in `shop` (169 added between the captures, in the middle of the list: the procedure's row order is not insertion order). 131 / 142, set in `shop` by 0x10DB, are not yet in it |
| CDB→WM | 0x10DC | NC_CHAR_COININFO_CMD | 2 | 18 | confirmed | `{handle, nCoin 0, nExchangedCoin 0}` |
| CDB→WM | 0x10E2 / 0x10E5 / 0x10E8 | NC_CHAR_CARDCOLLECT_(…)_CMD | 2 each | 8 | confirmed | `{handle, 5, n 0}` |
| CDB→WM | 0x1114 | NC_CHAR_TUTORIAL_INFO_WORLD_CMD | 2 | 9 | confirmed | no handle, `{5, nTutorialState 2, nTutorialStep 0}` = the AVATAR `TutorialInfo` |
| CDB→WM | 0x111E | NC_CHAR_CHAT_COLOR_CMD | 2 | 6 | confirmed | no handle, `{5, 0, 0}` |
| CDB→WM | 0x1121 | NC_CHAR_USEITEM_MINIMON_INFO_CMD | 2 | 56 | confirmed | its own `nWorldHandle` = the WM handle, `{5, 0, 0, 0xFFFF ×12, 0xFFFF ×12}` |
| CDB→WM | 0x1005 | NC_CHAR_CHARDATA_ACK | 2 | 2 | confirmed | raw `{4, 0x1005, handle}`, the 44th packet, 17–19 ms after 0x1004 |
| WM→CDB | 0x1036 | NC_CHAR_LOGIN_DB | 2 | 56 | confirmed | `{5, "RouN", x, y, Cen 99 440, usrregnum 103, spawnapps "Original"}` = the 0x1007 values; W01's `u32 extra[5]` is D02's `char spawnapps[20]` |
| WM→CDB | 0x7019 / 0x7021 | NC_CHAR_OPTION_DB_GET_SHORTCUTSIZE_REQ / _WINDOWPOS_REQ | 2 each | 6 | confirmed | `{WorldManagerHandle, nCharNo 5}`, forwarded from client 0x7004 / 0x700C (W04 §8.2) |
| CDB→WM | 0x701A / 0x7022 | NC_CHAR_OPTION_DB_GET_SHORTCUTSIZE_ACK / _WINDOWPOS_ACK | 2 each | 27 / 395 | confirmed | `bSuccess 1` + 24 / 392 data bytes, forwarded as client 0x7005 / 0x700D (W04 §8.3; D04 §5.1 sizes) |
| WM→CDB | 0x10EB | NC_CHAR_EVENT_ATTENDANCE_LIST_DB_REQ | 2 | 80 | confirmed | event 2015-11-09 → 2015-12-07 (28 days, long over), `tConnect` = the request time (first map login, W04 §17.5) |
| CDB→WM | 0x10EC | NC_CHAR_EVENT_ATTENDANCE_LIST_DB_ACK | 2 | 1020 | confirmed (layout); **bug** | `nError 0x2C00`, `tConnect` echoed, `AttendanceNum 0`, `RewardNum 0` (0x3FC + 0). `AttendanceArray[28]` (1008 bytes) holds stack data: `FUN_00427d90` zeroes only the first 7 ints of element 0 and writes one element per row. (original bug) P02-B9. The WM sends the client no 0x10ED (event over, nothing to claim; W04 §17.5) |
| WM→CDB | 0x10DB | NC_CHAR_DB_NEWBIE_GUIDE_VIEW_SET_CMD | 2 | 5 | confirmed | see §4.2 (0x10DA) |
| WM→CDB / CDB→WM | 0x704B / 0x704C | NC_CHAR_OPTION_IMPROVE_DB_SET_SHORTCUTDATA_REQ / _ACK | 2 + 2 | 12 / 6 | confirmed | see §4.2 (0x7037) |
| both | 0x0804 / 0x0805 | heartbeat | 7 / 7 | 0 | confirmed | §7.1; in `combat` the Character server also sends 0x0804 once |

### 7.5 Zone ↔ WM *(captured)*

Part 9 covers the links themselves and the map-login hand-over (0x104B … 0x101D, §7.5.1–§7.5.3). Part 10 adds the
zone → WM saves, level / exp updates, map links and the per-minute link traffic (§7.5.4).

#### 7.5.1 Four links per zone process

- **Code**: every zone keeps `SocketBundle<WorldManagerSession>` (pdb2016: `sb_SocketStr[4]` + `BitANDInt sb_Pointer`).
  The same template holds the GameDB and GameLog links (`sb_Packet` / `sb_Routine`, Z09 §1.1). For every send,
  `sb_GetSocket` @ FUN_004199b0 (Z01 §1 "SessionPool_Pick") moves the cursor to the next connected and verified entry.
  So the 16 WM links are 4 zone processes × 4, and the same holds for the zone links to CharDB and GameLog. §7.1's
  inference is **confirmed** (read in the code).
- **Captured rotation**: each zone sends on its 4 links in a fixed order. `shop` zone A (9210): links #11 → #3 → #7
  → #8 → #11 … (118.993 s: 0x180B #11, 0x400E #3, 0x400F #7, 0x4010 #8, 0x4029 #11, 0x402B #3, …). `combat` zone A:
  #1, #8, #9, #10; zone B (9214): #7, #3, #13, #16. The once-a-minute 0x7495 of the four zones goes out on four
  different links.
- **Replies**: the WM answers on the link the request came in on (`CParserZone` handlers send to their session
  argument): 0x104C on the 0x104B link, all blobs and 0x101D on the 0x101C link.
- **Broadcasts** (0x0821, 0x0C16, 0x580D, 0x987A / 0x987B) reach one link per zone: `g_Zones[zone]`. The 0x0802
  handler (W01 §7.1) overwrites it for each of the 4 links, so the last link to register gets them *(inferred:
  which link registers last)*. Part 10 (§7.5.4): that link is `sb_SocketStr[3]` for two zones and `[2]` for one, so it
  is not a fixed index. Batch 3 **confirms** the rule on two zone starts (§17.4: 186 of 188 broadcasts on the
  last-registered link; the WM refuses 2 of every zone's 4 first connects, P02-B25).
- **Ordering** *(inferred)*: one zone's save burst is spread over 4 links, and the WM handles one packet per session
  per pass (§7.4). The WM therefore applies the parts interleaved by link, not in send order. In `combat` 43.715–43.720
  s, 0x180D (sent last) is the 6th packet on link #1 while the 0x4013 saves sit on the other links. Only time
  (≈ 600 ms here, until the client's next 0x1801) orders the old zone's saves before the new zone's 0x101C. Part 10 (§7.5.4) adds that the round robin itself already
  does: 0x180D, sent last, sits on the link with the longest queue, so the WM has applied every save by the pass that
  answers it *(inferred)*. Two updates of one field within one pass can still be applied in reverse (P02-B12).

#### 7.5.2 Map-login hand-over: order and timing

Five hand-overs: `shop` 6.34 s (first login), 119.53 s (portal to RouCos02); `combat` 6.44 s (first login),
44.34 s (portal to RouCos02), 118.72 s (linkto back to RouN). Steps in all five:

```
t0           client → zone 0x1801 MAP_LOGIN_REQ { wmHandle 35000 / 32500, "Test2" }
+2 … 20 ms   zone → WM 0x104B REGISTNUMBER_REQ { ref { zone handle, −1 }, loginreq }               link i
+2 … 16 ms   WM → zone 0x104C REGISTNUMBER_ACK { ref, usrregnum 103, chrregnum 5, loginreq }       link i
+5 … 15 ms   zone → WM 0x101C ZONE_CHARDATA_REQ { ref { handle, 5 }, wldmanhandle, "Test2" }       link i+1
+5 … 19 ms   WM → zone, in one ms, on link i+1 (31 packets with 0x101D, + 0–2 of the bracketed ones: 31–33):
             0x101F 0x1020 0x1021 0x1022 0x10CD 0x10D6 0x1023 0x1024 0x1025 0x1029 0x1098 0x102E ×4
             0x1031 0x1032 0x1030 0x10D3 0x10D0 0x10CB [0xBC01] 0x10DD 0x10E3 0x10E6 0x10E9 [0x1130]
             [0xCC0C] 0x441D 0x1115 0x111F 0xD412 0x1122 0x101D
+391 … 455 ms zone → client 0x1802 MAP_LOGIN_ACK
```

- **Order** = the code order of `CParserZone::fc_NC_CHAR_ZONE_CHARDATA_REQ` @ FUN_00428ba0. `SendCharData` @
  FUN_00428ac0 skips null blobs: 0x1026 house, 0x1028, 0x102A–0x102D, 0x10B8 link-from and 2 of the 6 0x102E parts
  were never sent. W01 §7.2 / §6.3 differ in three places:
  - 0x1029 / 0x1098 come between 0x1028 and 0x102A; W01 puts them after the loop.
  - 0xCC0C (`MoverSystem_SendToZoneLinkData` @ FUN_004330a0) comes after 0x1130 and before 0x441D; W01 lists it last.
  - `m_ZoneHandle = ref.clienthandle` and 0x441D (`Send_NC_QUEST_RESET_TIME_ZONE_CMD` @ FUN_00439e30) come before
    0x1115 / 0x111F / 0xD412 / 0x1122 (@ FUN_00433660, FUN_00433820, FUN_00433980, FUN_00433bd0); W01 puts 0x441D after
    them.
  **Corrected** (W01, §13).
- **Optional packets**:
  - 0xBC01: after the map changes only (3 of 5). It carries the previous map name from the old zone's 0xBC1D, which
    the WM then clears.
  - 0x1130: only in `shop`'s portal hand-over (2 items sold before it); the WM frees it after the send.
  - 0xCC0C: only in `combat`'s portal hand-over, where the old zone sent 0xCC0B (Test2 on a mount: `nMoverID 160`,
    `nItemSlot 3`). It is a byte-identical copy.
- **Timing**: 0x1802 leaves 391–455 ms after 0x101D. That is ≈ 13 ms × (31 … 33 packets): the zone handles one packet
  per WM link per main-loop pass (`zs_PacketProcess`, Z09 §1.5), and all blobs arrive on one link. The zone sends
  0x1802 from the 0x101D handler (Z07 §1.4). ≈ 12.6–13.8 ms per pass *(inferred: the sleep manager's `Sleep(1)`, Z09
  §1.4, plus the pass's own work; the split between the two is open)*. This queue is most of the map-login latency.
- **Handles**: `ref.clienthandle` = the zone's player handle = the 0x1802 `charhandle` (8015, 8004, 8013, 8003,
  8014). `ref.charregistnumber` is −1 in 0x104B (Z01 §5.2) and 5 from 0x101C on. Z01 §5.2 / §5.3 **confirmed**.
- **Map change**: after a portal or linkto, the 0x101F position is the 0x180D destination: RouCos02 (17418, 13832)
  twice, RouN (6445, 8630). This is W01 §7.2's `pendingLink` (`LinkMapInfo` in pdb2016) **confirmed**.
- No 0x101E (CHARDATAFAIL) was captured. Every blob reaches the receiver Z07 §1.2 names.

#### 7.5.3 Blob copies: what the zone receives

Each packet was compared byte by byte with its CharDB block (§7.4) and with the zone save that replaced it (part 10):

- **CharDB copies are 2 bytes too long.** A zone packet = `ref` (6) + the cached blob. While the blob still holds the
  CharDB copy, it is the CharDB payload after the handle **plus 2 bytes**: the first two bytes of the next CharDB
  packet in the WM's receive buffer (its length byte and opcode low byte, or `00 lenLo` in the long form). All 17
  such opcodes match in both captures, e.g. 0x1021 tail `14 0b` = the header of the next 0x100B (20 bytes),
  0x10D6 tail `00 ad` = the long-form length 0x1AD of the next 0x100D, 0x1031 tail `06 1b` = the next 0x101B.
  - Code: every CharDB handler stores `CWMClientSession::CharDataStore(payload + 2, len − 2)` (FUN_00430780 and the
    skill / item overloads FUN_004307d0 / FUN_00430870), where `len` includes the 2-byte opcode. That covers all 30
    handlers FUN_0040a1d0 … FUN_0040df70: base, shape, quest doing / read / repeat, abstate, skill, passive, house,
    maspup, emblem, pet, arena, sea war, item, chest, title, KQ map, charged buff, single option, item cool-time,
    guide list, coin and the three card blocks (FUN_0040a1d0, FUN_0040a230, FUN_0040a290, FUN_0040a340, FUN_0040a3a0,
    FUN_0040a400, FUN_0040a460, FUN_0040a4b0, FUN_0040a510, FUN_0040a6a0, FUN_0040a780, FUN_0040a7e0, FUN_0040a840,
    FUN_0040a8a0, FUN_0040a900, FUN_0040a950, FUN_0040a9b0, FUN_0040aa10, FUN_0040aa70, FUN_0040aad0, FUN_0040ab50,
    FUN_0040abb0, FUN_0040de50, FUN_0040deb0, FUN_0040df10, FUN_0040df70). (original bug) P02-B10.
  - 0x101F keeps the tail for the whole session, because 0x400E writes into the blob in place. The others lose it
    when a zone save replaces the blob.
- **Zone saves replace the blob at the exact length**: 0x400F → 0x1021, 0x4029 / 0x402B → 0x10CD / 0x10D6, 0x4011 →
  0x1023 (rebuilt as `{charNo, n, 0x24 n}`, @ FUN_0042a000), 0x4012 → 0x1024, 0x4016 → 0x1031, 0x402A → 0x10D3,
  0x402C → 0x10DD, 0x4037 → 0x1130 (`payload + 6, len − 8`, @ FUN_0042d080).
- **0x4013 is the exception: 4 bytes too long.** `fc_NC_CHARSAVE_2WLDMAN_ITEM_CMD` @ FUN_0042a160 stores
  `payload + 6, len − 4`, i.e. 4 bytes past the packet. Every later 0x102E ends with the first 4 bytes of the next
  zone packet on that WM link (`0d 15 40 f4` = 0x4015's length, opcode and the WM-handle low byte); 12 of 12 match.
  (original bug) P02-B11.
- **No visible effect**: the zone receivers have no length checks (Z07 §1.2; `layouts.json` lists none) and read by
  count. Only the decoder misread them: 0x10CD showed a phantom quest id 54538, which is the tail `0a d5`. P02.json
  `packets.wm` now annotates the WM's sends with a trailing `overread` field.
- **Values** (both captures):
  - Base and items: Test2 lvl 5 (8 at `shop`'s portal, after the level-ups at 30.5 s); Cen, stones, HP and SP as in
    0x1007 / 0x400E.
  - Quests: 0x1022 is rebuilt by `QuestDoneLIstSendToZone` @ FUN_004332f0 (12 bytes; the P02-B8 tail is not
    forwarded). 0x1023 holds one abstate (id 9266) after the first zone.
  - Guild: 0x1029 guild 0, 0x1098 academy 0 (0x1097's member byte is dropped). 0x1030 `{bIsGM 0, party 0xFFFF,
    raid 0xFFFF}`: party and raid are re-read from the WM registries.
  - 0x10D3 `bFirstJoin`: 1 from CharDB, 0 after the zone's 0x402A. The WM also forces it to 1 on store
    (`fc_NC_CHAR_SINGLE_OPTION_CMD` @ FUN_0040aad0) and to 0 after the send.
  - 0x10CB `{BlockTime 0, DelayTime 0}` every time: inline 8 bytes, sent without any 0x10CA (settles the §7.4 lead).
  - 0x441D: period starts 2026-01-01, 2026-11-01, Mon 2026-11-09, 2026-11-15 00:00 local (W05 §2).
  - 0x1115 `{state 2, step 0}`; 0x111F `{0, 0}`; 0xD412 `{5, 0, 0, 0xFFFF, −1, −1}` = 0x4033; 0x1122 = 0x1121 with
    the zone ref.

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| Z→WM | 0x104B | NC_CHAR_REGISTNUMBER_REQ | 5 | 28 | confirmed | `ref.charregistnumber −1`, `loginreq {WM handle, Test2}` (W01 §7.2, Z01 §5.2) |
| WM→Z | 0x104C | NC_CHAR_REGISTNUMBER_ACK | 5 | 36 | confirmed | `usrregnum 103, chrregnum 5`, ticket accepted each time (Z01 §5.3) |
| Z→WM | 0x101C | NC_CHAR_ZONE_CHARDATA_REQ | 5 | 28 | confirmed | on the next link of the round robin (§7.5.1) |
| WM→Z | 0x101D | NC_CHAR_ZONE_CHARDATA_ACK | 5 | 8 | confirmed | last packet of the burst; 0x1802 391–455 ms later |
| WM→Z | 0x101F | NC_CHAR_ZONE_BASE_CMD | 5 | 113 | confirmed; **bug** | 6 + 105 (Z12) + 2 (P02-B10, `0c 1c` for the whole session) |
| WM→Z | 0x1020 | NC_CHAR_ZONE_SHAPE_CMD | 5 | 12 | confirmed; **bug** | `{0x19, 2, 1, 4}` + 2 (P02-B10) |
| WM→Z | 0x1021 / 0x10CD / 0x10D6 | NC_CHAR_ZONE_QUEST_DOING / _READ / _REPEAT_CMD | 5 each | 14 / 12 | confirmed; **bug** | `n 0`; 14 = CharDB copy + 2 (P02-B10), 12 after the zone saves |
| WM→Z | 0x1022 | NC_CHAR_ZONE_QUEST_DONE_CMD | 5 | 18 | confirmed | rebuilt (FUN_004332f0), no tail |
| WM→Z | 0x1023 | NC_CHAR_ZONE_ABSTATE_CMD | 5 | 14 / 48 | confirmed; **bug** | 0 + 2 (P02-B10) at first login; 1 abstate after a zone save (0x4011) |
| WM→Z | 0x1024 | NC_CHAR_ZONE_SKILL_CMD | 5 | 433 / 431 | confirmed; **bug** | one part (`PartMark 3`), 26 skills; + 2 while it is the CharDB copy |
| WM→Z | 0x1025 / 0x1032 / 0x10D0 | NC_CHAR_ZONE_PASSIVE / _CHARGEDBUFF / NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD | 5 each | 10 | confirmed; **bug** | `n 0`; always the CharDB copy (no zone save captured) + 2 |
| WM→Z | 0x1029 / 0x1098 | NC_CHAR_ZONE_GUILD_CMD / NC_CHAR_GUILD_ACADEMY_ZONE_CMD | 5 each | 10 | confirmed | `u32 0`; sent between 0x1028 and 0x102A (**corrected** order, W01 §7.2) |
| WM→Z | 0x102E | NC_CHAR_ZONE_ITEM_CMD | 20 | 11–122 | confirmed; **bug** | 4 parts per hand-over in the 0x1017 order (part marks 5, 8, 0x10, 0x22 / 0x12); + 2 (P02-B10) or + 4 after a 0x4013 save (P02-B11) |
| WM→Z | 0x1031 | NC_CHAR_ZONE_CHARTITLE_CMD | 5 | 1039 / 1037 | confirmed; **bug** | ref + `CHARACTER_TITLE_READBLOCK` (Z07 §1.3), + 2 while it is the CharDB copy; no layout before: P02.json |
| WM→Z | 0x1030 | NC_CHAR_ZONE_GAME_CMD | 5 | 11 | confirmed | `{0, 0xFFFF, 0xFFFF}` |
| WM→Z | 0x10D3 | NC_CHAR_ZONE_SINGLE_OPTION_CMD | 5 | 23 / 21 | confirmed; **bug** | Z12 layout; + 2 while it is the CharDB copy; `bFirstJoin` 1 → 0 |
| WM→Z | 0x10CB | NC_CHAR_GET_CHAT_BLOCK_SPAMER_CMD | 5 | 14 | **corrected** (layout) | ref + the pdb2016 8-byte struct (the decoder read the struct at +0); `{0, 0}`; P02.json |
| WM→Z | 0xBC01 | NC_GAMBLE_ZONE_PREVMAPNAME_CMD | 3 | 18 | **corrected** (layout) | ref + `Name3 sPrevMapName` (RouN, RouN, RouCos02); only after a map change; P02.json |
| WM→Z | 0x10DD | NC_CHAR_ZONE_COININFO_CMD | 5 | 24 / 22 | **corrected** (layout); **bug** | ref + `{u64 nCoin 0, u64 nExchangedCoin 0}` (+ 2 while it is the CharDB copy); P02.json |
| WM→Z | 0x10E3 / 0x10E6 / 0x10E9 | NC_CHAR_ZONE_CARDCOLLECT_(…)_CMD | 5 each | 14 | confirmed; **bug** | `{5, n 0}` + 2 (P02-B10) |
| WM→Z | 0x1130 | NC_CHAR_SELL_ITEM_INFO_ZONE_CMD | 1 | 51 | **corrected** (layout) | ref + `{NumOfSellItem 2, 2 × PROTO_SELL_ITEM_INFO_SERVER}` (1 + `nDataSize` bytes each: items 3000, 3001); = the 0x4037 body; P02.json (also fixes 0x4037) |
| WM→Z | 0xCC0C | NC_MOVER_LINKDATA_ZONE_CMD | 1 | 61 | confirmed | = the old zone's 0xCC0B (Z13 layout) |
| WM→Z | 0x441D | NC_QUEST_RESET_TIME_ZONE_CMD | 5 | 20 | confirmed | no ref, `nCharNo` + 4 period starts (W05 §2) |
| WM→Z | 0x1115 / 0x111F / 0xD412 / 0x1122 | tutorial / chat colour / pet re-summon / minimon | 5 each | 11 / 8 / 23 / 56 | confirmed | pdb2016 / Z13 layouts; 0xD412 has no ref |
| WM→Z | 0x0821 | NC_MISC_TIMEFROMWORLD_CMD | 16 | 36 | confirmed | every 60 s (± 40 ms) to the 4 main links at once, `tm_sec` 42 both times in both captures. The zones' per-minute block runs on it (Z09 §1.2): 0x7495 to the WM 3–20 ms later; settles §14 "per-minute phase" |
| WM→Z | 0x101E, 0x1026, 0x1028, 0x102A–0x102D, 0x102F, 0x10B8 | fail ack, house, maspup, emblem, pet, arena, sea war, chest, link-from | 0 | | never seen | null blobs for Test2 / no failure |

#### 7.5.4 Zone → WM saves and map links

Code: zone exports `zone-pdb` (official names, pdb2016). Captured events: two portal links to another zone (`shop`
118.993, `combat` 43.715), one `&linkto RouN` (GM command, `combat` 118.017 → 118.034), one revive on the same zone
(`combat` 102.372 `0x104E` → 102.376), `&levelup 3` (`shop` 30.491), 6 exp gains, 2 minutes of per-minute traffic per
capture, one KQ creation (`shop` 58.755).

**The WM cache save** = `WholeSaver::ws_save2worldmanager` @ FUN_004536f0. Its only caller is `so_LinkTo` @
FUN_0049ad30 on the "other zone" branch (Z01 §7.1). Logout, the 6-s timer and same-zone links save only to the
CharDB (`ws_save2DB`, §10.1); the revive at 102.376 sent `0x180B` and CharDB saves but no `0x40xx` to the WM. Every
packet goes through `sb_GetSocket` (one link further per send, §7.5.1). Code order, with the send conditions (lengths
include the 2-byte opcode):

```pseudo
so_LinkTo, destination on another zone:                              @ FUN_0049ad30 (Z01 §7.1)
    WM 0x180B NC_MAP_LINKSTART_CMD { wmHandle, charNo }               # also on a same-zone link (revive, 102.376)
    ws_save2DB(p, 0, reason 2)                                         # CharDB + GameLog (parts 11–13)
    ws_save2worldmanager(p):                                           @ FUN_004536f0
        only if smo_GetMode (vt 0x484) != 0
        0x400E ALL          ws_savelevel2worldmamager @ FUN_00453580; only if p has a field (p+0x7a); 0x6D bytes
                            { wldmanhandle, handle { bufferlocation = ws_savestorepoint, chrregnum }, level, location, stat }
        0x400F QUEST_DOING  so_SaveQuestDoing @ FUN_004534b0 ≥ 0; 10 + 32 n
        0x4010 QUEST_DONE   CQuestZone::Send_NC_CHARSAVE_2WLDMAN_QUEST_DONE_CMD @ FUN_005bc6f0 (vt 0xd20), always:
                            done quests (state byte 2) as { u16 id, u64 time } (10 bytes); a new packet whenever 8000
                            bytes are reached, nIndex = records sent before; nTotalDoneQuestSize = 12 + 10 n
        0x4029 QUEST_READ   vt 0x39c ≥ 0; 10 + 2 n
        0x402B QUEST_REPEAT vt 0x3a0 ≥ 0; 10 + 32 n
        0x4011 ABSTATE      always; 12 + 0x24 n
        0x4012 SKILL        so_Send_NC_CHARSAVE_2WLDMAN_SKILL_CMD @ FUN_00455780 (vt 0xaec), only if the skill count
                            ≠ 0; `PartMark` bit 0 first, bit 1 last; 15 + 16 n per part
        0x4013 ITEM ×4      so_SaveItem_Part @ FUN_00456030 (vt 0x3b8): nPartMark 5 inventory, 8 equipment,
                            0x12 mini-house skins, 0x22 action box; PacketOrder bit 7 = last of this box
                            (original bug) P02-B14: boxes 0x12 / 0x22 count PacketOrder from 1, the others from 0 (Z13 §2.8)
                            any box fails → so_Disconnect 0x68C, and nothing below is sent
        0x4015 GAME         so_SaveGameData @ FUN_00454a90 (returns 5, so always); 13 bytes
        0x4014 CHESTINFO, 0x4016 TITLE (vt 0x3c0), 0x4017 MISC { cen, fame } (vt 0x3c4)
        0x4021              sp_SpamSendDataToWM @ FUN_00562bc0 { WmHandle, CharNo, BlockTime, DelayTime }
                            (remaining block / delay time; the zone's 0x10CB reader only logs it, Z07 §1.2)
        0x402A              sp_SingleOptionSave2World @ FUN_00563050: resttime = 0 and bFirstJoin = 0 always (Z12 §7.2)
        0xBC1D              sp_Gamble_PrevMapNameSave2World @ FUN_00617010: sPrevMapName = the map being left
        0x402C              sp_Gamble_CoinDataSave2World @ FUN_00617130 { nCoin, nExchangedCoin, nCharNo }
        0xCC0B              sp_MoverSystem_ZoneLink_Save2World @ FUN_0045e710, only if sp_Mover_LinkData.nCharNo ≠ −1
                            (its assert text says "sp_Gamble_PrevMapNameSave2World": copy-paste, log only)
        0x4032              sp_ChatColor_Save2World @ FUN_00563c70 (no wmHandle: { nCharNo, font, balloon })
        0x4033              sp_PetLinkResummonInfo_Save2World @ FUN_004d1760, only if the pet state is
                            PSST_1ST_SUMMONED, PSST_RESUMMONED or PSST_NONE (no wmHandle)
        0x4034              ItemActionObserveManager::SendCoolTimes2World @ FUN_005d0fa0, only if a cool time runs
        0x4036              sp_SaveUseItemMinimonInfo_World @ FUN_00563e70; 0x3A bytes
        0x4037              sp_SendSellItemInfo_World @ FUN_00537c30, only if items were sold (§7.5.3)
    WM 0x180D NC_MAP_LINKRESERVE_REQ (Z01 §7.1; W01 §7.3 stores the destination and sets the ticket)
    GameLog 0xC809 (§10.2)
WM → zone 0x180E NC_MAP_LINKRESERVE_ACK on the 0x180D link → client 0x180A 10–16 ms later (Z01 §7.1)
```

- **Captured order = code order.** The three bursts, read in round-robin link order (§7.5.1), give exactly the
  sequence above: `shop` 118.993 (links #11 → #3 → #7 → #8): 0x180B, 0x400E, 0x400F, 0x4010, 0x4029, 0x402B, 0x4011,
  0x4012, 0x4013 ×4, 0x4015, 0x4014, 0x4016, 0x4017, 0x4021, 0x402A, 0xBC1D, 0x402C, 0x4032, 0x4033, 0x4036, 0x4037,
  0x180D. `combat` 43.715 is the same without 0x4037 and with 0xCC0B between 0x402C and 0x4032 (Test2 on a mount);
  `combat` 118.034 without both. 0x4034 was never sent (no cool time). Z01 §8.4 lists only part of this (§13).
- **Send timing**: one burst leaves within 1–2 ms. On one link per burst the later packets leave 5 ms (`combat` 43.720,
  link #1) or 16 ms (`combat` 118.051, 0x4021 / 0x4032 on #7) late, so sorting by time misplaces them (0x4029 seems to
  follow 0x4036). Nagle on a link that has an unacknowledged small segment *(inferred, as §7.4)*.
- **WM side**: the 0x180E leaves 90–110 ms after the 0x180D, about 7 WM passes, which is the number of packets queued on
  the 0x180D link (7, 7, 6). Because 0x180D is the last send of the round robin, its link has as many queued packets
  as any other, so the WM has applied every save no later than the pass that answers 0x180D *(inferred from the
  one-packet-per-session-per-pass rule, §7.4)*. That refines §7.5.1 "Ordering": the old zone's saves are in the cache
  before the new zone's 0x101C can come.
- **Field values** (all with the annotated layouts; 0 decode issues):
  - 0x400E carries the position of the map being left (`RouN 6471, 10573` / `RouN 6487, 10543` / `RouCos02 …`),
    `kqhandle −1` and `map_kq` = the map. The destination comes only with 0x180D, and the WM applies it at the next
    0x101C (§7.5.2). `bufferlocation 0` (`ws_savestorepoint`), CurHPStone 13 / SPStone 10, HP 140 / SP 165.
  - 0x4012 `{PartMark 3, nMaxNum 26}`: one part, 26 skills, `savetime` = the current `time_t`. 0x4011 holds abstate
    9266 (1 left, `resttime` 492 000 / 568 000 / 495 000 ms). 0x4013 holds parts 5 (2–6 items), 8 (equipment: item
    750 / 751), 0x12 (1: item 31000), 0x22 (0); `PacketOrder` 0x80 / 0x80 / 0x81 / 0x81 (P02-B14).
  - 0x4016 `TitleValues` move with the scenario. [9] `ID_NOKILLED_BY_MOB` 1 → 2 in `combat` (one death):
    `CCharacterTitleZone::CT_KilledByMob` @ FUN_005cbdd0 adds 1 to type 9 on every death and to type 8
    `ID_KILLED_BY_MOB` only when 180 s have passed since the last death and the killer handle differs ([8] stayed 0:
    the death came 48 s after the zone login, §9.5). So 9 is the death
    counter that Z18 §6.2's "reach level V without dying" checks, and the §14 lead is settled. Others: [11] kills 7 → 11
    (combat), 11 → 12 (shop); [23] NPC sales 0 → 2, [24] NPC buys 2 → 3, [46] 2 → 8 after `&levelup 3` (shop).
  - 0x402A `{resttime 0, autopick 0, mystery_vault 1, nChatBan 0, bFirstJoin 0}`: the zero `resttime` is the code
    (Z12 knowledge: rest exp is computed only at character login). 0x4021 / 0x402C / 0x4032 / 0x4015 all zero or
    "none" (`partyno` / `nRaidNo` 0xFFFF). 0x4033 `{bDoResummon 0, nSummonSlot 0xFFFF, nId −1, nRegNum −1}` (no pet).
  - 0xBC1D `sPrevMapName` = RouN, RouN, RouCos02 = the next zone's 0xBC01 (§7.5.2).
- **Same-zone link** (revive at `combat` 102.376, `so_LinkTo` with `(4, 0x4F, 0x50)` → client 0x104F): 0x180B, then
  the client's 0x1803 at 102.530 → 0x180C. No 0x180D, no 0x40xx. W01's `s.linking` is set and cleared without a map
  login ticket. **Confirmed** Z01 §7.1.
- **0x180C** after every 0x1803 (6): `{wmHandle, objHandle = zone handle, charNo, map, zoneNo (0 = 9210, 2 = 9214),
  x, y, always99 99, exp, money, inGuildTournament 0}`. The WM copies `charNo, map, x, y, 99, exp, money` into GameLog
  0x040F, which names the 99 `StoreType` (102.538: `RouCos02 9647 9002 StoreType 99 30 99440`): the field Z01 calls
  `always99` is the GameLog store type "map link" *(captured; the 0x040F side: §10.2)*. Only the first 0x180C of
  a session triggers WM → zone 0x1120 (W04 §17.5), sent on the zone's main link, not on the 0x180C link (`shop` #11 →
  #3, `combat` #10 → #1).

**Level and exp** (`ShinePlayer::sp_GainExp` @ FUN_0042d830; GM `&levelup` = `so_AmpersandCommand_LevelUp` @
FUN_0042fa00):

```pseudo
sp_GainExp(p, exp, mobHandle, …):                                     @ FUN_0042d830
    mode 3 (dead) or 0: return; ExpHold charged effect: exp = 0; level ≥ levellimit: return
    p.exp += exp; client 0x240B; WM 0x1073 NC_CHAR_EXP_CHANGED_CMD { wmHandle, charNo, u64 exp (new total) }
    exp < nextexp[level]: maybe move sp_NextSaveExp; return
    level up: level += 1, HP / SP full, CT_LevelUp, level-max announce, quest hook
        client 0x240C NC_BAT_LEVELUP_CMD { level, mobHandle, 232-byte parameters }; area 0x240D { handle, mobHandle }
        ws_savelevel2worldmamager → WM 0x400E; WM 0x1074 NC_CHAR_LEVEL_CHANGED_CMD { wmHandle, charNo, level }
        GameLog 0x041E { charNo, map, x, y, level, exp }; ws_save2DB(p, 1, reason 8)
        if vt 0x858 / 0x85c (academy membership, inferred): GameDB 0x986B; free empower points: client 0x4810;
        client 0x105B; GM events
so_AmpersandCommand_LevelUp: the same level-up block without the exp add, the 0x1073 and the 0x240B; mobHandle 0  @ FUN_0042fa00
```

- `shop` 30.491 `&levelup 3`: three level-up blocks in one tick, each 0x400E → 0x1074 → GameLog 0x041E → CharDB saves
  (0x4018, 0x4001, 0x4007, 0x400B, 0x0410 `StoreType 8`, 0x401A, 0x4035, 0x1070), then the client sees 0x240C, 0x4810,
  0x105B, 0x2446, 0x106F, 0xBC05 three times. `exp` stays 30 (the GM path adds none), so at level 8 the cache holds
  `exp 30 < PrevExp 840`.
- Exp gains (`combat` 22 → 24 → 26 → 28 → 30, `shop` 30 → 31 → 35): one 0x1073 each with the new total. **Confirmed**
  Z03 layouts.
- **Out-of-order application on the WM** (original bug) P02-B12: the level-up's 0x400E and 0x1074 go out on
  different links, and the WM serves its sessions once per pass in list order. The WM's GameLog `0xC808` (sent from the
  0x1074 handler, W01 §7.5) arrived as level **7, 6** (30.507, same ms) and 8 (30.524). Link #7 carried the 0x1074 for
  levels 6 and 8, #11 the one for 7, and #11 was served before #7 in that pass. Any two updates of one field within
  one WM pass (two 0x1073, two 0x1074) can be applied in reverse, so the WM cache (party, guild and academy member
  level, exp) can stay one step old until the next update.

**Per-minute and broadcast traffic on the zone links**:

- 0x7495 NC_GUILD_GUILDWARSTATUS_REQ (empty) from each zone 3–20 ms after the WM's 0x0821 (§7.5.3). It is sent by
  `WorldManagerSession::wms_GuildWarStatusRequest` @ FUN_005a45f0 from `zs_mainthreadfunction` (Z09 §1.1) on
  `sb_SocketStr[0]` directly, not via `sb_GetSocket`: each zone used the same link both minutes (`shop` #7, #10, #9,
  #12; `combat` #8, #16, #14, #15). The WM answers 0x7496 `{warnumber 0}` on that link 1–15 ms later (W03 §3.5,
  `CGuildManager::Recv_NC_GUILD_GUILDWARSTATUS_REQ` @ FUN_0043f060). The zone clears all war states and adds none
  (Z08 §8.2). **Confirmed**.
- 0x987A / 0x987B from `CGuildManager::ProcessGuildAcademy` @ FUN_00441200 to the 4 main links, every 60 s at :00
  local (18 s after each 0x0821 at :42; the first run rounds `NextWorkTime` to the full minute, later runs add 60 s).
  0x987A `{BuffName "StaAcaGenalBuf", NumOfGuild 0}` (36 bytes), 0x987B `{NumOfMaster 0}`. **Confirmed** W03 §6.4.
  (original bug) P02-B13: `BuffName[32]` is filled with a `strcpy` into the uncleared `CSendPacket` buffer, so the 17
  bytes after the NUL are stale. In `shop` 58.755 they are `g[A]\0B]\0)[B]\0`, the tail of the KQ title
  "Mean Giant Honeying[A]" from the 0x580D built in the same ms; later minutes carry other stale bytes.
- 0x580D NC_KQ_W2Z_MAKE_REQ (`shop` 58.755, KQ 14 "Mean Giant Honeying[A]", map `KDHoneying`, Handle 21) to the 4 main
  links; one 0x580E `{hquest 21, err 0x0981}` came back 16 ms later on link #9 (the zone process hosting the map).
  0x0981 = `ERR_KINGDOMQUEST_MAKE_NOERR` (success). The three other zones sent nothing: Z08 §4's "no 0x580E when a map
  is not local" (Z08-B8) is **captured**, and the WM's 1-minute fallback (W04) is not needed on success.

**Broadcast link (§7.5.1)**: 0x7495 marks `sb_SocketStr[0]`, and the round robin gives the index order of the others.
The main link (the one with the broadcasts) is `sb_SocketStr[3]` for `shop` zone A ([0] #7, [1] #8, [2] #11, [3] #3)
and `combat` zone A ([0] #8 … [3] #1), but `sb_SocketStr[2]` for `combat` zone B ([0] #16, [1] #7, [2] #3, [3] #13).
So it is not a fixed index. "The last link to register" still fits if the 4 handshakes can finish out of index order
*(inferred)*.

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| Z→WM | 0x180B | NC_MAP_LINKSTART_CMD | 4 | 6 | confirmed | first packet of every `so_LinkTo`, also same-zone (revive); Z01 layout |
| Z→WM | 0x180C | NC_MAP_LINKEND_CMD | 6 | 47 | confirmed; **extended** | after each 0x1803; `always99` = GameLog `StoreType` 99 (copied to 0x040F) |
| Z→WM | 0x180D | NC_MAP_LINKRESERVE_REQ | 3 | 59 | confirmed | last of the burst; dest = next 0x101F position (§7.5.2); `mapIndex` 2 (RouCos02), 150 (RouN) |
| WM→Z | 0x180E | NC_MAP_LINKRESERVE_ACK | 3 | 36 | confirmed | on the 0x180D link, 90–110 ms later (one WM pass per queued packet); client 0x180A 10–16 ms later |
| Z→WM | 0x400E | NC_CHARSAVE_2WLDMAN_ALL_CMD | 6 | 107 | confirmed | pdb2016 layout; per level-up and per zone change; map / position = map being left |
| Z→WM | 0x400F / 0x4029 / 0x402B | QUEST_DOING / _READ / _REPEAT | 3 each | 8 | confirmed | `n 0`; `bNeedClear 1` in 0x400F |
| Z→WM | 0x4010 | NC_CHARSAVE_2WLDMAN_QUEST_DONE_CMD | 3 | 14 | confirmed | `{0, 12, 0, 0}` (Z15 layout); sent even when empty |
| Z→WM | 0x4011 | NC_CHARSAVE_2WLDMAN_ABSTATE_CMD | 3 | 46 | confirmed | 1 abstate (9266) |
| Z→WM | 0x4012 | NC_CHARSAVE_2WLDMAN_SKILL_CMD | 3 | 429 | confirmed | Z23 layout; one part `PartMark 3`, 26 skills |
| Z→WM | 0x4013 | NC_CHARSAVE_2WLDMAN_ITEM_CMD | 12 | 9–118 | confirmed; **bug** | 4 parts per burst (5, 8, 0x12, 0x22); PacketOrder base 1 for 0x12 / 0x22 (P02-B14); WM store P02-B11 |
| Z→WM | 0x4014 / 0x4015 / 0x4017 | CHESTINFO / GAME / MISC | 3 each | 10 / 11 / 18 | confirmed | chest 0; `{bIsGM 0, 0xFFFF, 0xFFFF}`; `{cen, fame, nCharNo}` |
| Z→WM | 0x4016 | NC_CHARSAVE_2WLDMAN_TITLE_CMD | 3 | 1037 | confirmed | `TitleValues` follow the scenario; [9] = death counter (settles §14) |
| Z→WM | 0x4021 | NC_CHARSAVE_SET_CHAT_BLOCK_SPAMER_WM_CMD | 3 | 14 | confirmed | `{0, 0}` |
| Z→WM | 0x402A | NC_CHARSAVE_2WLDMAN_SINGLE_OPTION_CMD | 3 | 17 | confirmed | Z12 layout; `resttime` / `bFirstJoin` written as 0 by the code |
| Z→WM | 0x402C | NC_CHARSAVE_2WLDMAN_COININFO_CMD | 3 | 22 | confirmed | `{0, 0, 5}` |
| Z→WM | 0x4032 / 0x4033 / 0x4036 | CHAT_COLOR / PET_LINK_RESUMMON / USEITEM_MINIMON_INFO_WORLD | 3 each | 6 / 23 / 56 | confirmed | Z13 / pdb2016 layouts; 0x4032 / 0x4033 have no wmHandle (WM looks up by charNo) |
| Z→WM | 0x4037 | NC_CHARSAVE_SELL_ITEM_INFO_CMD | 1 | 51 | confirmed | `shop` only (2 items sold); layout §7.5.3 |
| Z→WM | 0xBC1D | NC_GAMBLE_WORLD_PREVMAPNAME_CMD | 3 | 18 | confirmed | W04 layout; = the map being left |
| Z→WM | 0xCC0B | NC_MOVER_LINKDATA_WORLD_CMD | 1 | 61 | confirmed | only while riding (`combat` 43.720); between 0x402C and 0x4032 |
| Z→WM | 0x1073 | NC_CHAR_EXP_CHANGED_CMD | 6 | 14 | confirmed | new total exp per gain (Z03 layout) |
| Z→WM | 0x1074 | NC_CHAR_LEVEL_CHANGED_CMD | 3 | 7 | confirmed; **bug** | one per level; applied out of order on the WM (P02-B12) |
| Z→WM | 0x7495 | NC_GUILD_GUILDWARSTATUS_REQ | 16 | 0 | confirmed | per minute, on `sb_SocketStr[0]` |
| WM→Z | 0x7496 | NC_GUILD_GUILDWARSTATUS_ACK | 16 | 2 | confirmed | `warnumber 0` |
| WM→Z | 0x987A | NC_GUILD_ACADEMY_ZONE_GUILD_BUFF_CMD | 16 | 36 | confirmed; **bug** | `StaAcaGenalBuf`, 0 guilds; stale bytes after the NUL (P02-B13) |
| WM→Z | 0x987B | NC_GUILD_ACADEMY_ZONE_GUILD_ACADEMY_MASTER_BUFF_CMD | 16 | 4 | confirmed | 0 masters |
| WM→Z | 0x580D | NC_KQ_W2Z_MAKE_REQ | 4 | 377 | confirmed | Z16 layout; to the 4 main links |
| Z→WM | 0x580E | NC_KQ_Z2W_MAKE_ACK | 1 | 6 | confirmed | `err 0x0981` success, only from the hosting zone (Z08-B8 captured) |
| WM→Z | 0x1120 | NC_CHAR_SUPPORT_REWARD_CMD | 2 | 8 | confirmed | `{5, eUserType 2}` after the first 0x180C only, on the main link |
| Z→WM | 0x4034 | NC_CHARSAVE_2WLDMAN_ITEMACTIONCOOLTIME_CMD | 0 | | never seen | no cool time running at a zone change |

### 7.6 Zone ↔ Character DB and GameLog DB *(captured)*

The zone's 4 CharDB links and 4 GameLog links follow the round robin of §7.5.1: consecutive requests of one player
leave on different `W00_CDB#n` links (the 4 `0x3444` of one storage open go out on 4 links in the same ms). Every
CharDB answer comes back on the link of its request. The Character server's item logs (`0x0446`, `0x0448`, `0x0449`,
`0x044C`, `0xC80D`, `0xC80E`) all use one link (`W00_GLDB#2` in both captures, which otherwise carries only `0x040A`, §10.2), so that link is
the Character server's GameLog link *(inferred from the content: only D03 sends these logs)*. Each log leaves 0–1 ms after the
CharDB answer it belongs to, so the Character server sends the log after the reply (D03 §2.1 / §2.2 / §3.2 order).

#### 7.6.1 Item transactions (part 11)

Request → answer → client, by timestamp (`shop` unless noted; `Δ` from the client request):

| Client request | Zone → CharDB | CharDB → zone | CharDB → GameLog | Zone → client (same ms) |
|---|---|---|---|---|
| 0x3003 buy 751 (19.253) | 0x340A BUYALL +1 ms, lock 0 | 0x340B +12 ms | 0x0448, 0xC80D +13 ms | +35 ms: CharDB 0x1070 FAMESAVE, 0x1033 cen, 0x106F fame, 0xBC04 coin, 0x3001, 0x3004 `0x201` |
| 0x300F equip (34.931, 61.540) | 0x3410 EQUIP +4 / +17 ms, lock 1 / 6 | 0x3411 +13 / +19 ms | – | 0x3002 (equip slot), 0x3001 (inventory cell), 0x3011 `0x281` |
| 0x300B move ×3 (51.508 …) | 0x3428 RELOC +4…12 ms, locks 2–4 | 0x3429 +8…23 ms | 0x044C (inventory → storage) | 0x3001 source emptied, 0x3001 target, 0x300C `0x241` |
| 0x3012 unequip (59.029) | 0x3413 UNEQUIP +8 ms, lock 5 | 0x3414 +12 ms | – | 0x3002 slot 12 emptied (5 bytes), 0x3001, **0x3011** `0x281` (Z05-B2 captured) |
| 0x3006 sell ×2 (94.949, 95.646) | 0x3422 SELLALL +0…5 ms, locks 7, 8 | 0x3423 +4…10 ms | 0x0449, 0xC80E | 0x1033, 0x3001 emptied, 0x305C repurchase slot 0 / 1, 0x3005 `0x381` |
| 0x3009 pick (144.964; `combat` 69.422, 75.179) | 0x341C PICKALL **and** 0x3001 in the same ms (+3…6 ms) | 0x341D +7…10 ms | 0x0446 | 0x300A `0x341` 34–52 ms after 0x341D |
| storage NPC (0x201D at 49.946) | 4 × 0x3444 pages 0–3, 15 ms after 0x201D | 4 × 0x3446, 16 ms later | – | 4 × 0x3C08 16 ms later, in the order 2, 3, 0, 1 |
| 0x3015 ride item (`combat` 16.096) | none (direct use) | – | – | 0x3016 `0x700` + 0x2047 cast bar 3000 ms (+1 ms) |
| ride item while riding (`combat` 56.122), map link while riding (43.715) | 0x3449 ITEMCHANGE (`sp_HorseItemSave`) | 0x344A `err 0x901` +7 ms | – | 0x203E, 0xCC06, 0x3016 `0x700`, 0x1805; 0x3001 with the new attribute 48 ms after 0x344A |
| zone login (every 0x1803) | 0x34CF; with the client's 0x3020 / 0x302C: 0x3463, 0x1099 | 0x3464 `0x1041`, 0x109A (+1–2 ms) | – | (§5.1) |

- **Lock indices** run 0, 1, 2 … per player across all transaction types (buy 0, equip 1, moves 2–4, unequip 5, equip
  6, sells 7, 8), as Z05 §1.2 describes; every answer echoes its request's index.
- **Commit styles (Z05 §1.1) captured**: style 1 (buy, equip, move, unequip, sell): the client sees nothing until the
  CharDB answer, then all cell changes and the ACK in one ms. Style 2 (pick-up): the `0x3001` leaves with the request,
  and only the `0x300A` waits for `0x341D`.
- **Money releasers**: a purchase that costs only cen still runs all three releasers (`CenChange`, `FameChange`,
  `CoinChange`, Z05 §1.4): `0x1033`, `0x106F` `fame 14` (unchanged), `0xBC04` `nCoin 0` and a `0x1070 FAMESAVE` to
  the CharDB, before the `0x3001` of the new item. A sale sends only `0x1033`.
- **The 34–52 ms gaps** (`0x341D` → `0x300A`, `0x344A` → `0x3001`) are the Nagle delay of §7.5.4: a small client
  send right after another one in the same ms waits for the client's ACK *(inferred)*.
- **Mover (Wooden Horse 38043, `MoverItem.shn` → mover 160)**: Z13 §7.2 / §7.4 confirmed. The use answers at once
  (`uib_DirectUse` → `sp_MoverSystem_Cast`, no DB request). On the portal link at 43.715 `so_LinkTo` dismounts with
  `GetOff(1)` right after `0x180B` and before the `ws_save2DB` packets (§7.5.4): `0x3449` with `hungrypoint 760`,
  `bitflag 0` (DuringRide cleared before the save), then client `0x203E`, `0xCC06`, `0x3016 {0x700, 0xFFFF, 9}` (the
  useditem was reset by the first 0x3016) and `0x1805` for the mover object; WM `0xCC0B` carries the link data
  (§7.5.4). In zone B the mover is back (re-summoned from the link data, Z13 §7.7), and using the item at 56.122
  dismounts with `GetOff(0)`: `hungrypoint 750`, the same client packets with `useditem 38043`.

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| Z→CDB | 0x340A | NC_ITEMDB_BUYALL_REQ | 1 | 133 | **corrected** | D03 layout right; `attr` (u16 @42) = byte offset of the attribute (68), not a length (Z04 §2.1 "attrLen"); attribute = variable tail (65 B weapon); P02.json override |
| CDB→Z | 0x340B | NC_ITEMDB_BUYALLSUC_ACK | 1 | 8 | confirmed | `{ref, lockindex}` |
| Z→CDB | 0x3410 | NC_ITEMDB_EQUIP_REQ | 2 | 35 | confirmed | D03 layout; `relocA_IsPutOnBelonged` is 4 bytes (Z04 §5.1 says u8, its offsets are right); `relocB.key −1` for an empty slot |
| CDB→Z | 0x3411 / 0x3414 / 0x3423 / 0x3429 | EQUIPSUC / UNEQUIPSUC / SELLALLSUC / RELOCSUC_ACK | 2 / 1 / 2 / 3 | 8 | **corrected** | `{ref, lockindex}`; pdb2016 struct lacks the 6-byte ref (P02.json) |
| Z→CDB | 0x3413 | NC_ITEMDB_UNEQUIP_REQ | 1 | 20 | confirmed | Z04 layout |
| Z→CDB | 0x341C | NC_ITEMDB_PICKALL_REQ | 3 | 45 | confirmed; **new layout** | no annotation before; `{ref, PROTO_ITEM_CREATE, attribute}`; map / x / y = the picker's position; `attr` = offset 44 (P02.json) |
| CDB→Z | 0x341D | NC_ITEMDB_PICKALLSUC_ACK | 3 | 6 | confirmed; **new layout** | `{ref}` only (D03 §3.4) |
| Z→CDB | 0x3422 | NC_ITEMDB_SELLALL_REQ | 2 | 39 | confirmed | D03 layout; `price` = unit price × lot |
| Z→CDB | 0x3428 | NC_ITEMDB_RELOC_REQ | 3 | 34 | **corrected** | pdb2016 struct + ref prefix; `ownerA 5` (charNo), `ownerB 103` (userNo: account storage) |
| Z→CDB | 0x3444 | NC_ITEMDB_OPENSTORAGE_REQ | 4 | 12 | confirmed | Z04 §7.2; pages 0–3 from the NPC role (Z02 §6.5), `fromAccountStorageCmd 0` |
| CDB→Z | 0x3446 | NC_ITEMDB_OPENSTORAGE_ACK | 4 | 20 | confirmed; **bug** | 17 bytes + 3 stale bytes (D03-B8 captured, zeros here) |
| Z→CDB | 0x3449 | NC_ITEMDB_ITEMCHANGE_REQ | 2 | 37 | confirmed | Z26 layout; riding attribute 0x13 bytes (Z13 §7.1) |
| CDB→Z | 0x344A | NC_ITEMDB_ITEMCHANGE_ACK | 2 | 10 | confirmed | pdb2016 layout; `err 0x901` |
| Z→CDB | 0x3463 / CDB→Z 0x3464 | NC_ITEMDB_CHARGED_LIST_REQ / _ACK | 2 / 2 | 14 / 11 | confirmed | Z04 §8.1 page 0 (0..23); `ErrorCode 0x1041`, 0 items |
| Z→CDB | 0x34CF | NC_ITEMDB_RESET_SCROLL_LINK_MAP_INFO_CMD | 6 | 4 | confirmed | once per zone login completion, also after the same-zone revive (D06 §5.2) |
| Z→CDB | 0x1099 / CDB→Z 0x109A | NC_CHAR_GET_ITEMLIST_BY_TYPE_NUM_REQ / _ACK | 2 / 2 | 16 / 16 | confirmed; **bug** | Z04 §8.3 box 2 page 0; `Error 0x1200` in both = never written (D02-B13 captured) |
| CDB→GL | 0x0446 | NC_LOG_GAME_ITEM_TAKE | 3 | 38 | confirmed; **bug** | map "Need" (D03-B11); x / y and `iteminven` never written (P02-B15); `itemlot 0` |
| CDB→GL | 0x0448 / 0x0449 | NC_LOG_GAME_ITEM_BUY / _SELL | 1 / 2 | 23 | confirmed | D03 §2.1 / §2.2; `itemlot 0`, seller / buyer 0 |
| CDB→GL | 0x044C | NC_LOG_GAME_ITEM_INVEN_MOVE | 3 | 20 | confirmed | only for a move that leaves the inventory (D03 §3.2) |
| CDB→GL | 0xC80D / 0xC80E | NC_SYSLOG_CHAR_ITEM_BUY / _SELL | 1 / 2 | 20 | confirmed | `Vendor 28` = the NPC's mob id |

The combat / death rows (0x1070, 0x041E, 0x042B, 0x042D, 0xC808, 0xC80A, 0xC80B) are in §9.7, the saves and the other
zone ↔ CharDB and GameLog rows (0x4001 … 0x4035, 0x10B3, 0x1080, 0x040A, 0x040F, 0x0410, 0xC806, 0xC809) in §10.8.

## 8. Zone in-world, batch 2: items, shops, storage *(captured)*

Scenario (`shop`, zone A = RouN, character Test2, 99 371 cen): weapon NPC (0x3C09 at 13.076), buy Long Mace 751
(19.253), equip it in place of Short Mace 750 (34.931), storage NPC (49.946), move 750, Bone 3004 and Leather 3005
into account storage (51.5–53.0), close (57.055), unequip 751 (59.029) and equip it again (61.540), item NPC (0x3C0B
at 86.732), weapon NPC (92.892), sell Spirit Dust 3000 and Meat 3001 (94.949, 95.646), then in zone B (RouCos02) pick
up a Meat drop (144.964). `combat`: ride item Wooden Horse 38043 used twice (16.096 zone A, 56.122 zone B), three
pick-ups of mob drops (69.422, 75.179). The CharDB / GameLog side of every transaction and its timing: §7.6.1.

### 8.1 Field findings

- **0x3001 NC_ITEM_CELLCHANGE_CMD** (Z05 §1.5 layout): sizes 6 (empty cell, `itemid 0xFFFF`, nothing follows),
  7 (stackable: 1-byte lot), 25 (riding item: 0x13-byte `ShineItemAttr_Riding`), 71 (weapon: 65 attribute bytes).
  `exchange` = the other cell of the change: the target cell when the source is emptied, the source when the target
  is filled (a move sends the emptied source first), the equipment cell (`0x200C`) for the inventory side of an
  (un)equip, and `location` itself for buy, sell, pick-up and attribute changes.
- **0x3002 NC_ITEM_EQUIPCHANGE_CMD** (batch 1 §6.2): `exchange` = the inventory cell, `location` u8 = equipment slot
  12 (right hand); 70 bytes with a weapon, 5 when the slot is emptied. On an equip the 0x3002 precedes the 0x3001 of
  the inventory cell, then the ACK.
- **0x3C09 / 0x3C0B NC_MENU_SHOPOPENTABLE_WEAPON / _ITEM_CMD** (no layout before; P02.json from Z02 §6.5
  `nrm_ShopMenuOpen` and the pdb2017 struct): `{u16 itemnum, u16 npc, MENUITEM {u8 slot, u16 item}[itemnum]}`,
  190 = 4 + 62 × 3 and 67 = 4 + 21 × 3. The weapon list holds three runs of rising slots (0…26 weapons 250…57365,
  0…69 armour from LeatherBoots 0 to 57396, 0…8 rings 2000…2302) and the item list two (weapon licences 10000…10005,
enchant stones 61000…). The client
  (`Market::SetWeapon` FUN_006137c0) starts a run whenever `slot` is 0, takes the tab from the first item's
  `ItemInfo.Class` (5 weapon, 6–8 armour, else the third tab), fills skipped slots with empty cells, and stops at 200
  per tab. Both NPC visits to the weapon NPC sent byte-identical lists (`npc 17084`).
- **0x305C NC_ITEM_SELL_ITEM_INSERT_CMD** (pdb2016 `{u16 nHandle, SHINE_ITEM_STRUCT ItemInfo}`, 105 bytes):
  `nHandle` 0 / 1 = repurchase slot, `itemid` 3000 / 3001, then the 1-byte lot. The other 100 bytes are stale:
  readable text of earlier text packets ("…nly death can cleanse the light.…", "…oes anyone want to play? My game is
  deadly, though.") followed by the `MENUITEM` bytes of the 0x3C09 sent at 92.892. `so_ply_SellItemList_Insert` @ FUN_00537a20 writes
  the opcode, `nHandle` and the item through `iti_fill2buffer_union` @ FUN_006406c0 (only as many attribute bytes as the
  class has), then sends a fixed `pp_SetPacketLen(&gpp, 0x6b)` from the shared send buffer `gpp`
  (original bug) P02-B16. Client: `On_NC_ITEM_SELL_ITEM_INSERT_CMD` @ FUN_0049dbe0 passes the payload to
  `ItemShopWin::AddRepurchaseInv` / `NPCItemWin::AddRepurchaseInv` (whichever shop window is open);
  `Market::AddRepurchase` @ FUN_006135d0 keeps the u16 at +0 and builds the item with `Item::Create` @ FUN_006684f0
  from +2. No client code looks at the packet length, so the tail is never read *(the item parser itself not
  re-read)*. The bug puts earlier packets of the zone (other players' texts included) on the wire.
- **0x3C08 NC_MENU_OPENSTORAGE_CMD** (Z05 §7.1): one per DB page, 13 bytes with an empty page, the PDB struct is 12 +
  items. `so_accountstoragefill` @ FUN_0044c530 sends `0xe + n` bytes (opcode included), with n =
  `ias_FillBufferItem` @ FUN_00643b10, which returns `end − counter pointer` (`param_1` = the `itemcounter` byte at
  +0xd) and so counts the counter byte a second time: every 0x3C08 ends with one stale byte (0x00 here)
  (original bug) P02-B17, the same slip as `irs_FillBufferItem` for 0x302D (P02-B3). Client: `On_NC_MENU_OPENSTORAGE_CMD`
  @ FUN_0049a9a0 keeps byte +10 (frame+0x900) and opens the storage menu with byte +9 after `Bank::SetContents`
  @ FUN_00610700, which reads `itemcounter` (+0xb) items one by one by their own length: the stray byte is never read,
  so the bug has no visible effect. `pages` = 0x10 constant; the zone
  sends the pages in the order their 0x3446 arrive on its 4 links (2, 3, 0, 1).
- **0x300A NC_ITEM_PICK_ACK**: `{itemid, lot 1, 0x341, 0xFFFF}` ×3, matches Z05 §3.2; the client prints
  "[%s] has been obtained." (Z04 §3.3).
- **0x3011 for the unequip**: the 0x3414 answer sends `0x3011 NC_ITEM_EQUIP_ACK 0x281`, never `0x3013`: Z05-B2 captured.
- **0x3016 NC_ITEM_USE_ACK** (Z04 §6.1): the ride item answers `0x700` with `useditem 38043` at once (direct use, no
  CharDB request) and the client starts a 3000-ms cast bar (0x2047, §9.6). The two forced dismounts send a second
  `0x3016 0x700` (Z13 §7.4 `so_MoverSystem_GetOff` → `ItemUseResult`), `useditem 0xFFFF` when the first 0x3016 had
  already reset it (map link) and 38043 when the dismount is the use itself (§7.6.1).
- **0x1C0A NC_BRIEFINFO_DROPEDITEM_CMD** (Z09 §11.3): `attr 8` (looting bit 3) for the killer, `dropmobhandle` = the
  mob that dropped it; sent 1.5–6.6 s before the pick-up, 15 bytes.
- **0x304D NC_ITEM_ACCOUNT_STORAGE_CLOSE_CMD**: the client sends it when the NPC storage window closes, although the
  storage was opened through the NPC (`fromAccountStorageCmd 0`, `nOpenType 0`); no reply (Z04 §7.3). The `0x200B`
  sent in the same tick clears the open flag (§14, sweep).
- **0x3003 / 0x3006 payloads** match Z04 §2.1 / §2.4 (`{itemid 751, lot 1}`, `{slot, lot 1}`); `0x300B` = `{0x2406 →
  0x1800}` etc. (the decoder read every `ITEM_INVEN` as 1 byte until P02.json defined the struct, part 11).

### 8.2 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x3003 | NC_ITEM_BUY_REQ | 1 | 6 | confirmed | Z04 §2.1 |
| S→C | 0x3004 | NC_ITEM_BUY_ACK | 1 | 2 | confirmed | `0x201` after 0x340B (Z05 §2.1) |
| C→S | 0x3006 | NC_ITEM_SELL_REQ | 2 | 5 | confirmed | Z04 §2.4 |
| S→C | 0x3005 | NC_ITEM_SELL_ACK | 2 | 2 | confirmed | `0x381` after 0x3423 |
| C→S | 0x3009 | NC_ITEM_PICK_REQ | 3 | 2 | confirmed | Z04 §3.3 |
| S→C | 0x300A | NC_ITEM_PICK_ACK | 3 | 10 | confirmed | `0x341`, `itemhandle 0xFFFF` |
| C→S | 0x300B | NC_ITEM_RELOC_REQ | 3 | 4 | confirmed | inventory → account storage; decoder fixed (`ITEM_INVEN`) |
| S→C | 0x300C | NC_ITEM_RELOC_ACK | 3 | 2 | confirmed | `0x241` |
| C→S | 0x300F | NC_ITEM_EQUIP_REQ | 2 | 1 | confirmed | Z04 §5.1 |
| S→C | 0x3011 | NC_ITEM_EQUIP_ACK | 3 | 2 | confirmed; **bug** | `0x281` also for the unequip (Z05-B2) |
| C→S | 0x3012 | NC_ITEM_UNEQUIP_REQ | 1 | 2 | confirmed | `{12, 4}` |
| S→C | 0x3013 | NC_ITEM_UNEQUIP_ACK | 0 | | never seen | on success the zone sends 0x3011 (Z05-B2) |
| C→S | 0x3015 | NC_ITEM_USE_REQ | 2 | 2 | confirmed | ride item |
| S→C | 0x3016 | NC_ITEM_USE_ACK | 3 | 5 | confirmed | `0x700`; 2 from forced dismounts |
| C→S | 0x304D | NC_ITEM_ACCOUNT_STORAGE_CLOSE_CMD | 1 | 0 | confirmed | also after an NPC open |
| S→C | 0x305C | NC_ITEM_SELL_ITEM_INSERT_CMD | 2 | 105 | confirmed; **bug** | 100 stale `gpp` bytes (P02-B16) |
| S→C | 0x3001 | NC_ITEM_CELLCHANGE_CMD | 17 | 6 / 7 / 25 / 71 | confirmed | `exchange` rule above |
| S→C | 0x3002 | NC_ITEM_EQUIPCHANGE_CMD | 3 | 5 / 70 | confirmed | before the 0x3001 of the inventory cell |
| S→C | 0x3C08 | NC_MENU_OPENSTORAGE_CMD | 4 | 13 | confirmed; **bug** | one stray trailing byte (P02-B17) |
| S→C | 0x3C09 / 0x3C0B | NC_MENU_SHOPOPENTABLE_WEAPON_CMD / _ITEM_CMD | 2 / 1 | 190 / 67 | confirmed; **new layout** | P02.json; tabs by slot runs |
| S→C | 0x1C0A | NC_BRIEFINFO_DROPEDITEM_CMD | 3 | 15 | confirmed | `attr 8` for the killer |

## 9. Zone in-world, batch 2: combat, death, revive, soulstones *(captured)*

Scenario: `shop` kills a Slime (MobInfo 0, level 1) in RouN at 110.852 with one swing, then in RouCos02 fights a
Hero Slime (2000, level 2, 119 HP) with swings and one Bash [01] (ActiveSkill 1500) until it dies at 138.352, and
uses an HP and an SP soulstone (139.805, 141.521); `&levelup 3` at 30.491 takes Test2 from level 5 to 8. `combat`
(level 5) kills four Slimes in RouCos02 (59.025, 61.619, 67.486 by skill, 73.719), is killed by a Hero Slime at
94.130 after a 14-s duel (13 player and 6 mob swings), revives from the death menu at 102.372, and summons the Wooden Horse mover (16.096 → 19.029).
Code references are Z03 §3 (swing), §5 (skills), §7 (death), §8 (mob death, exp, level-up); Z07 §3.1 (revive); Z04
§13.2 (soulstones); Z09 §5.4 / §7.4 (mob death, mob weapons); Z12 §7 (level-up tail); Z13 §7 (mover cast).

### 9.1 The swing cycle

- **Start.** `0x242B NC_BAT_BASHSTART_CMD` (empty) is answered by `0x2447 NC_BAT_SWING_START_CMD` 15–31 ms later (the
  swing timer `ts_Set(…, delay 0)` fires on the next player tick, Z03 §3.1). Before a bash the client always sends
  `0x2401` + an `0x2012 STOP_REQ`; every `0x2401` gets `0x2402` and, one tick later, `0x243D NC_BAT_CEASE_FIRE_CMD`
  (`p.smo_BashStop` from the target change).
- **Hit times** (`attackspeed 1100`, `p.vt[0x50c]`): the first hit lands 303–413 ms after its 0x2447, every later one
  475–534 ms after; the next swing starts 889 ms after the first and 1078–1128 ms after every later one. This is Z03
  §3.2 with the 0.1-s `g_Now` step: hit at `(AttackSpeed / 2 + HitNotRevision) × 10 / 1000` tenths = 4 (first swing,
  −150 ms) or 5 (550 ms rounded down), next swing after `AttackSpeed + HitNotRevision` = 950 / 1100 ms.
- **Hero Slime swings** (`attackspeed 1000`): one every 2.46–2.53 s, hit 570–635 ms after the start. MobWeapon row
  2000 has `AtkSpd 1000, AtkDly 1500, SwingTime 1000, HitTime 633`: Z09 §7.4 gives `next = D + A` = 15 + 10 tenths =
  2.5 s and the hit at `B` = 6 tenths = 600 ms. Its first swing at a player follows `0x2013 NC_ACT_SOMEONESTOP_CMD
  {handle, server position}` in the same ms (the mob stops its chase, `so_mobile_StopHere`, Z09 §7).
- **Counters.** `damageindex` (= `++swingCount`) restarts at 1 with every 0x242B for the player; `attacksequence` (+0x1e80)
  keeps counting across bashes, skills and kills (1 → 19 in `combat`). For the mob, `attacksequence` is always 0 and
  `damageindex` counts its swings over its life (3…8 for mob 4, 8…10 for mob 3). `actioncode` cycles through the
  animations 0…5 and keeps its position across bashes. `hpchangeorder` is per defender and grows by more than one per hit:
  mob 4 2, 4, 6 … with no other packet about it in between, the player 3, 6, 9, … with `0x240E` taking the values in
  between (5 after the hit with 3) and 20 / 21 at death and revive. Every read of the counter advances it (`vt 0x7e8`,
  Z03 §2.3); which other reads take the missing values was not traced.
- **Stop.** `0x2432 NC_BAT_BASHSTOP_CMD` → 0x243D 20–44 ms later (`bashStopNotify` on the next tick, Z03 §3.4). A
  `0x2019 MOVERUN` from the chasing client stops the bash too (`combat` 77.943 → 0x243D at 78.119): the queued hit
  (due at +400 ms) is dropped, no 0x2448 follows. After a kill the next swing tick finds the target dead and stops:
  0x243D 434–598 ms after the killing blow (the next swing time). `0x2408 NC_BAT_UNTARGET_REQ` (`shop` 72.878, no bash running) has no
  reply, as in Z03 §2.5 (nobody targeted the player).

### 9.2 Damage packets

- **`0x2448 NC_BAT_SWING_DAMAGE_CMD`** (16 bytes, 28 packets, all to the fighters only): `flag` is 0 in every
  packet, the five killing blows on mobs (`resthp 0`) and the blow that killed the player included. `smo_SwingDamage` @
  FUN_00432f30 writes the flag byte (payload + 4) bit by bit from the battle context `ctx` (`ctx` = the local block
  `{+0 att, +4 def, … +0x10 critical, +0x11 miss, +0x12 ?, +0x13 shield block, +0x14, +0x15, +0x16}`): bit 0 ← +0x10,
  bit 1 ← +0x14, bit 2 ← +0x11 (miss), bit 3 ← +0x13, bit 4 ← costume-weapon charge, bit 6 ← +0x15, bit 7 ← +0x16, and
  of byte payload + 5 only bit 0 (costume shield). The pdb2016 bitfield `PROTO_NC_BAT_SWING_DAMAGE_CMD::flag` names these
  `iscritical, isresist, ismissed, isshieldblock, isCostumCharged, isDead (bit 5), isDamege2Heal, isImmune,
  isCostumShieldCharged`. **Bit 5 `isDead` and bits 1–7 of the second byte are never written**: they keep whatever
  the shared send buffer `gpp` held (0 in all 28) (original bug) P02-B18. Z03's annotation (and §7.1 "the death
  reaches clients as the dead flag of the damage packet, SWING_DAMAGE flag bit1") does not hold: bit 1 is `ctx+0x14`
  (`isresist`), and nothing sets a dead bit. The client (`FUN_004a2620`) reads bits 0–4, 6, 7 and the second byte's
  bit 0, and takes death from `resthp == 0` (`*(u32 *)(payload + 8) != 0` → alive), so the missing bit has no effect.
- **`0x2452 NC_BAT_SKILLBASH_HIT_DAMAGE_CMD`** (19 = 5 + 14 bytes, the pdb2016 layout; the decoder now falls back to
  it, §15): `SkillDamage.flag` is `0x2801` (hit, mob alive) and `0x2901` (kill: byte 2 bit 0 `isDead`). Byte 2 bits 3
  and 5 (`0x28`) are set in both. `sds_TemplateStore` @ FUN_005803c0 builds the entry in a stack local and writes
  that byte as `(old & 0xfa) | isImmune << 1 | IsCostumShield << 2 | (resthp == 0)`: bits 3–7 keep uninitialised stack
  bits (original bug) P02-B19. `isDead` is set first from `resthp == 0` and cleared again when the damage is less
  than the target's HP. `hpchange` 70 / 27, `resthp` 16 / 0 match the swing sequence (119 − 33 − 70 = 16).
- **Bystanders**: no `0x2449` was captured (no third player in sight).

### 9.3 Kills, experience, hunt log

- **Order at a swing kill** (all in the ms of the killing hit): link `0x1073 NC_CHAR_EXP_CHANGED_CMD` to the WM and
  `0xC80B NC_SYSLOG_CHAR_VICTORY` to GameLog; client `0x2402` (`targethp 0`), `0x240B NC_BAT_EXPGAIN_CMD`, `0x2448`.
  The exp packet precedes the damage packet because `vt 0xef0` (apply damage → `ShineMob::so_KilledBy` → exp) runs
  before the 0x2448 send (Z03 §3.2, §8.1). `0x244A NC_BAT_REALLYKILL_CMD {dead, attacker}` (4 bytes) follows 41–55 ms
  later from the mob's own tick (`deathSent`, Z09 §5.4); after the skill kill it leaves in the same ms as 0x2452,
  because the blast runs in the player tick before the mob's. `0x1C0A` drops leave with the 0x240B (§8.1).
- **`0x240B expgain`** 1 (Slime at level 8), 2 (Slime at level 5) and 4 (Hero Slime at level 8): `MonEXP` 3 / 8 ×
  the level handicap (Z03 §8.2), `mobhandle` = the dead mob. `0x1073 exp` goes 30 → 31 and 22 → 30 in steps of 2.
- **`0xC80B`** (22 bytes, D05 layout): `ZoneNo` = the zone process number (0 = RouN on 9210, 2 = RouCos02 on 9214;
  `zs_worlddata().nZoneNo`), `TargetType 1` (mob), `TargetID` = MobInfo id (0 Slime, 2000 Hero Slime: `vt 0x708`, the
  mob id masked to 16 bits), `KillCoord` = the killer's position (`param_1->so_LocateInfo`, ShineMob::so_KilledBy @
  FUN_00432760).
- **Hunt log.** `0x042D NC_LOG_GAME_MK_GETEXPINFIELD {chrregnum 5, mobid 0, number 4, exp 8}` leaves once, at the
  revive (102.376): the four Slime kills of `combat` with their 4 × 2 exp, Z09 §28.12 `mhe_Send2Log`. Its only flush
  is `mhl_SendAll2Log` in `ShinePlayer::so_Unmark` @ FUN_00558900, guarded by `smo_GetMode() != 0` (vt 0x484). The
  revive's same-zone link calls `so_Unmark` while the player is in mode 1 (Z07 §3.1 sets it before `so_LinkTo`), so
  the log goes out. A link to another zone sets `mode = 0` in `so_LinkTo` (Z01 §7.1) and unmarks only later in
  `so_banning` (0x180E), so the guard fails and the entries are dropped with the object: the Slime kill of `shop`
  (110.852, zone A) never reaches GameLog although Test2 left for zone B at 118.993 (original bug) P02-B20. Normal
  logout (0x0C18, mode 1–6) flushes it (Z01 §8.1).

### 9.4 Level-up (`&levelup 3`, `shop` 30.491)

All three levels go out in one ms (30.500–30.501), each in Z03 §8.3 / Z12 §7 code order: links `0x400E`, `0x1074`,
GameLog `0x041E`, the CharDB save burst of `ws_save2DB(p, 1, 8)` (`0x4018 … 0x4035`, `StoreType 8`, §10.1), CharDB
`0x1070 NC_CHAR_FAMESAVE_CMD`; client `0x240C NC_BAT_LEVELUP_CMD`, `0x4810 NC_SKILL_EMPOWPOINT_CMD`, `0x105B`,
`0x2446 NC_BAT_FAMEGAIN_CMD`, `0x106F NC_CHAR_FAMECHANGE_CMD`, `0xBC05` (§10.6). No `0x240D` (nobody in sight).

- **`0x240C`** (235 = 3 + `CHAR_PARAMETER_DATA` 0xe8; Z03's annotation type `struct` cannot be decoded, the decoder
  uses the pdb2016 layout): `level` 6 / 7 / 8, `mobhandle 0` (GM command), `PrevExp` / `NextExp` 350 / 560, 560 / 840,
  840 / 1200, the base and change stats equal (no gear bonus). `Wizdom` holds stale bytes (`" tho"` = text of an
  earlier packet, then `FF FF FF 01`): Z07-B7, now also in 0x240C. `exp` stays 30 (`0x041E currentexp 30`, `0x0410
  CharExp 30`), below `PrevExp`: `&levelup` raises the level without exp (Z11 §7.3).
- **`0x4810 restempow`** 2, 3, 3 and **`0x105B remain`** 6, 7, 8: free empower and stat points after each level.
- **Fame**: `famegain` = the new level (6, 7, 8); `0x106F` / CharDB `0x1070` carry the total 20, 27, 35 (start 14).
  The buy at 19.288 sends `0x106F` and `0x1070` with the unchanged 14 (§7.6.1, the money releasers).
- The HP / SP refill (`0x1035`, `0x240E hp 140`, `0x240F sp 165`) leaves 15 ms later, on the next player tick.
- **WM `0xC808 NC_SYSLOG_CHAR_LEVEL_UP`** (9 bytes `{UserNo 103, CharNo 5, CharLev}`): one per `0x1074`, in the order
  7, 6 (30.507), 8 (30.524). The three `0x1074` came on links #7, #11, #7: the WM handles one packet per session per
  pass (§7.4), session #11 before #7, and the second packet of #7 one pass (17 ms) later.

### 9.5 Player death and revive (`combat`)

- **Death (94.130).** The Hero Slime's hit is applied in its own tick: GameLog `0x042B NC_LOG_GAME_MKED {chrregnum,
  mappos RouCos02 16351 / 12980, mobid 2000, exp 0}` and `0xC80A NC_SYSLOG_CHAR_DEATH {UserNo, CharNo, ZoneNo 2,
  AttackerType 1, AttackerID 2000, DeathCoord}` (22 bytes, the 2016 form without the 2017 `CharID / CharLevel /
  LostEXP`) leave at once; the client gets `0x104D`, the killing `0x2448 {damage 3, resthp 0, hpchangeorder 18}`, `0x2402` (order 1, handle
  0xFFFF: the mob's target cleared) and `0x240E {hp 0, hpchangeorder 20}`, in this order, 19 ms later in one frame
  (frame 2086). `exp 0`: level 5 is below `g_ExpLossMinLevel` (Z03 §7.2, "Starting from level 20 …"), so no `0x2411` and no
  `0x1073`. No `0x2428` removals reach the client for the states `so_KilledBy` erases (abstate 728).
- **`0x104D NC_CHAR_DEADMENU_CMD`** (9 bytes): `{reviveWaitSec 180, 50, 0}` as Z03 §7.2 (`field+0x210`, constant 50,
  `p+0x2aac4 && field flag 2`). The 2017 PDB names the fields `Second`, `u8 priority`, `DeadMenuType eMenuType`
  (`DMT_BASE 0`, `DMT_REBIRTH 1`) *(pdb2017)*: the last one is 1 only with a pending rebirth offer (Z07 §3.2
  `p+0x2aac4`), so Z03's `canReviveHere` is the "rebirth" menu variant *(inferred from the names)*.
  Client `On_NC_CHAR_DEADMENU_CMD` @ FUN_004a9940 confirms the 2016 layout `{u32 +0, u8 +4, u32 +5}`: it gives the
  low byte of +0 to `ReviveMenuWin::SetAutoRevieTimeSec` and +0 / 60 to `RebirthMenuWin::SetAutoRevieTime` (so a wait
  over 255 s would show wrong in the revive window; 180 fits), +4 to `ReviveMenuWin::SetPriority`, locks inventory and
  equipment, and opens the rebirth window when +5 == 1, else the revive window; below level 6 it adds the system
  message 0xd5562a42 ("Starting from level 20, character will lose part of the exp when dying.").
- **Revive (102.372, `0x104E`, empty).** Same ms: WM `0x180B`, GameLog `0x042D` (§9.3), then the CharDB save burst
  with `0x0410 StoreType 2` (`so_Unmark` @ FUN_00558900 calls `mhl_SendAll2Log` before its `REMOVE_REVIVE` case runs
  `ws_save2DB`; captured 0x180B, 0x042D, 0x4018 … 0x4035), client `0x1C18` / `0x242A` for abstate 728 (`keepTime 510100`, restored from `g_ShelterDie`),
  then `0x104F NC_CHAR_REVIVESAME_CMD {mapid 2, location 9647 / 9002}` (10 bytes, pdb2017 `{u16 mapid, SHINE_XY_TYPE}`,
  no hand annotation; client FUN_0049feb0 copies the 10 bytes whole to frame+0x969, sets +0x968 = 1, closes the
  map-bound windows (minimap marks, dice game, guild-tournament windows) and calls FUN_008c57c0, the start of the map
  reload that ends in the `0x1803` *(inferred)*): the RouCos02 regen point, a same-zone link (Z07 §3.1 "Revive City", Z01 §7.1 `so_LinkTo(…, 4,
  0x4F, 0x50)`). 158 ms later the client sends `0x1803` and the zone repeats the full map-login burst (§5.1), with
  `0x240E hp 28` = MaxHP 94 × 0x133 / 1024 (Z07 §3.1, 30 %), `0x180C` to the WM and GameLog `0x040F`. The 8.2-s wait
  is the player's; the auto-revive would have fired after 180 + 2 + 6 s (Z03 §7.2).
- **Title counter** (§14, open since part 10): `CT_KilledByMob` @ FUN_005cbdd0 adds to type 8 `ID_KILLED_BY_MOB` only
  when `m_KilledByMobTimeValue + 180 < now`; `CCharacterTitleZone::InitNewPlayer` @ FUN_005ca620 sets that time to
  `mysecond()` and the handle to 0xFFFF when the WM's title block arrives (`wms_NC_CHAR_ZONE_CHARTITLE_CMD` @
  FUN_005a39f0, every zone login). Test2 entered RouCos02 at 45.855 and died at 94.130, 48 s later, so [8] stayed 0
  and only [9] counted: settled.

### 9.6 Skills, soulstones, mover cast bar

- **Bash [01] (1500) on an object**: `0x2440 {skill, target}` → `0x244E NC_BAT_SKILLBASH_HIT_OBJ_START_CMD {skill,
  targetobj, index}` + `0x2435 NC_BAT_SKILLBASH_CAST_SUC_ACK` (empty) 1–8 ms later; `0x2457 NC_BAT_SKILLBASH_HIT_BLAST_CMD
  {index, caster, nSkillID}` and `0x2452` 44–55 ms after that (the links in `combat` 27 ms after), then `0x240F sp`
  (165 → 156 = SP 9). The row has `CastTime 0` and `IsMovingSkill 1`, so `smo_SkillBash_Blast_Obj` (Z03 §5.4) blasts
  on the first tick without the 0.3-s arming pass. `index` 3 and 4 (per-zone blast counter). No `0x4821` cooldown packet
  for this skill (DlyTime 6000 is kept server side).
- **Soulstones**: `0x5007` → `0x5008` (11 ms), `0x5009` → `0x500A` (1 ms), all empty (Z04 §13.2). The heal itself
  goes out on the next tick as `0x240E hp 140` / `0x240F sp 165` (+51 / +45 ms) after an order-1 `0x2402` about the
  player. The player's own client gets no `0x500B` / `0x500C`: `sp_HPStoneUse` @ FUN_00589180 broadcasts it with
  `so_AllOfRange` before sending 0x5008, and it does not reach the user *(captured)*: its `so_AllOfRange` u8 argument is 0, which
  excludes the source (§10.4).
- **Mover (Wooden Horse 38043)**: `0x3015` → `0x201B MOVEFAIL`, `0x3016 0x700`, `0x2047 NC_ACT_CREATECASTBAR
  {millisec 3000}` in one ms, `0x243D` one tick later (the four cancels of `sp_MoverSystem_Cast`, Z13 §7.2). After
  2.93 s (MoverMain row 160 `WoodenHorse01`: `CastingTime 3000`, 0.1-s `g_Now` step): `0x1C1A` (the mover object),
  `0x4821 NC_SKILL_COOLTIME_CMD {skill 29206 UseRide, sec 5}` (`CoolTime 5000`), `0x2048 NC_ACT_CANCELCASTBAR`,
  `0xCC02`, `0xCC04`, `0xCC0A`: `sp_MoverSystem_SummonItem` order (Z13 §7.4); the CC0x / 0x1C1A statuses are in §10.7 / §10.8.

### 9.7 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x242B | NC_BAT_BASHSTART_CMD | 9 | 0 | confirmed | 0x2447 next tick |
| C→S | 0x2432 | NC_BAT_BASHSTOP_CMD | 3 | 0 | confirmed | 0x243D one or two ticks later |
| C→S | 0x2408 | NC_BAT_UNTARGET_REQ | 1 | 0 | confirmed | no reply |
| S→C | 0x2447 | NC_BAT_SWING_START_CMD | 31 | 9 | confirmed | timing = Z03 §3.2 / Z09 §7.4 |
| S→C | 0x2448 | NC_BAT_SWING_DAMAGE_CMD | 28 | 16 | confirmed; **corrected**; **bug** | flag bit map ≠ Z03; no dead bit (P02-B18) |
| S→C | 0x244A | NC_BAT_REALLYKILL_CMD | 6 | 4 | confirmed | 41–55 ms after a swing kill |
| S→C | 0x240B | NC_BAT_EXPGAIN_CMD | 6 | 6 | confirmed | before the killing 0x2448 |
| S→C | 0x240C | NC_BAT_LEVELUP_CMD | 3 | 235 | confirmed; **bug** | pdb2016 layout; `Wizdom` stale (Z07-B7) |
| S→C | 0x2446 | NC_BAT_FAMEGAIN_CMD | 3 | 4 | confirmed | = new level |
| S→C | 0x4810 | NC_SKILL_EMPOWPOINT_CMD | 3 | 1 | confirmed | |
| C→S | 0x2440 | NC_BAT_SKILLBASH_OBJ_CAST_REQ | 2 | 4 | confirmed | skill 1500 |
| S→C | 0x244E | NC_BAT_SKILLBASH_HIT_OBJ_START_CMD | 2 | 6 | confirmed | |
| S→C | 0x2435 | NC_BAT_SKILLBASH_CAST_SUC_ACK | 2 | 0 | confirmed | |
| S→C | 0x2457 | NC_BAT_SKILLBASH_HIT_BLAST_CMD | 2 | 6 | confirmed | first tick (IsMovingSkill) |
| S→C | 0x2452 | NC_BAT_SKILLBASH_HIT_DAMAGE_CMD | 2 | 19 | confirmed; **bug** | 5-byte header (pdb2016); flag bits 11/13 stack garbage (P02-B19) |
| S→C | 0x4821 | NC_SKILL_COOLTIME_CMD | 1 | 6 | confirmed | ride skill 29206, 5 s |
| S→C | 0x2047 | NC_ACT_CREATECASTBAR | 1 | 2 | confirmed | 3000 ms = MoverMain.CastingTime |
| S→C | 0x2048 | NC_ACT_CANCELCASTBAR | 1 | 0 | confirmed | at the cast end (summon) |
| S→C | 0x2013 | NC_ACT_SOMEONESTOP_CMD | 2 | 10 | confirmed | mob stops before its first swing |
| S→C | 0x1C19 | NC_BRIEFINFO_ABSTATE_CHANGE_LIST_CMD | 4 | 15 | confirmed | regen mob: `{291 StaImmortal, 5000, 1}` with its 0x1C08, reset by 0x2428 5.0 s later |
| S→C | 0x104D | NC_CHAR_DEADMENU_CMD | 1 | 9 | confirmed | `{180, 50, 0}`; client FUN_004a9940: §9.5 |
| C→S | 0x104E | NC_CHAR_REVIVE_REQ | 1 | 0 | confirmed | |
| S→C | 0x104F | NC_CHAR_REVIVESAME_CMD | 1 | 10 | confirmed | pdb2017 layout; client FUN_0049feb0 copies it whole (§9.5); then a full map login |
| S→C | 0x1033 | NC_CHAR_CENCHANGE_CMD | 3 | 8 | confirmed | 99 440 − 69 (BuyPrice), + 3, + 4 (SellPrice) |
| S→C | 0x106F | NC_CHAR_FAMECHANGE_CMD | 4 | 4 | confirmed | total fame |
| C→S | 0x5007 / 0x5009 | NC_SOULSTONE_HP / SP_USE_REQ | 1 / 1 | 0 | confirmed | |
| S→C | 0x5008 / 0x500A | NC_SOULSTONE_HP / SP_USESUC_ACK | 1 / 1 | 0 | confirmed | heal on the next tick; no 0x500B to self |
| Z→CDB | 0x1070 | NC_CHAR_FAMESAVE_CMD | 4 | 8 | confirmed | `{charregnum, fame}`; buy + each level |
| Z→GL | 0x041E | NC_LOG_GAME_LEVEL_UP | 3 | 33 | confirmed | `currentexp` = unchanged exp |
| Z→GL | 0x042B | NC_LOG_GAME_MKED | 1 | 34 | confirmed | `exp` = lost exp (0) |
| Z→GL | 0x042D | NC_LOG_GAME_MK_GETEXPINFIELD | 1 | 12 | confirmed; **bug** | only when unmarked in mode ≠ 0 (P02-B20) |
| Z→GL | 0xC80A | NC_SYSLOG_CHAR_DEATH | 1 | 22 | confirmed | 2016 short form |
| Z→GL | 0xC80B | NC_SYSLOG_CHAR_VICTORY | 6 | 22 | confirmed | `TargetID` = mob id, killer's position |
| WM→GL | 0xC808 | NC_SYSLOG_CHAR_LEVEL_UP | 3 | 9 | confirmed | one per 0x1074, WM session order |

## 10. Zone in-world, batch 2: saves, map-login requests, NPC menus, mover, chat *(captured)*

The remaining new types: the CharDB saves of `ws_save2DB` (part of every burst in §7.5.4, §9.4 and §9.5), the CharDB
and GameLog requests of each map login, NPC menus and the quest dialog, the client-side extras of a level-up, the mover
packets and object removal, chat and the combat stance. The content also gives the recording order: `combat` came
first (it starts and ends with 99 440 cen; `shop` starts with 99 440 and then spends it; the title counter
`ID_PLAY_TIME` is 75–77 in `combat` and 81–83 in `shop`, §10.3) *(inferred from the content)*.

### 10.1 CharDB saves: `WholeSaver::ws_save2DB` @ FUN_00455a10

Seven bursts: `shop` 30.500 (three level-ups in one ms, reason 8), 118.993 (portal, 2); `combat` 43.715 (portal while
riding, 2), 102.376 (revive, 2), 118.034 (`&linkto`, 2). Each one leaves in one ms, round robin over the zone's 4 CharDB
links (§7.6), in code order:

```pseudo
ws_save2DB(p, partial, reason)                                   # ref = {u16 zone handle, u32 charNo}
                                                                 # handle = {u16 bufferlocation, u32 chrregnum}
    CharDB 0x4018 NC_CHARSAVE_PKCOUNT_CMD { ref, u32 chrregnum, u32 pkcount = 0 }     14 B, no answer
    CharDB 0x4001 NC_CHARSAVE_ALL_REQ { ref, handle, level, location, stat }          111 B → 0x4002 { ref, handle } 3–21 ms later
    (0x4005 QUEST_DOING_REQ: only if !partial and a quest is in progress; never sent)
    CharDB 0x4007 NC_CHARSAVE_ABSTATE_REQ { ref, handle, u16 abstatenum = 0 }         14 B → 0x4008 { ref, handle } 2–18 ms later
    (0x4009 SKILL_REQ: only when the skill list changed; never sent)
    CharDB 0x400B NC_CHARSAVE_TITLE_REQ { ref, handle, u16 n, n × { u8 Type, u64 TitleValue } }   32 / 50 / 59 B (§10.3), no answer
    GameLog 0x0410 NC_LOG_GMAE_LOGOUT_ZONEINFO { chrregnum, mappos, u8 StoreType = reason, exp, money }   41 B
    CharDB 0x401A NC_CHARSAVE_REST_EXP_LAST_EXEC_TIME_SAVE_REQ { handle }  (no ref)   6 B, no answer
    (0x4023 cool-times via ItemActionObserveManager::SendCoolTimes2DB, pet tendency: nothing to save, not sent)
    CharDB 0x4035 NC_CHARSAVE_USEITEM_MINIMON_INFO_DB_CMD { nCharNo, … }  (sp_SaveUseItemMinimonInfo_DB)   78 B, no answer
```

- **Headers.** D02 §6 is right: the `_REQ`s carry ref + handle (12 bytes), `0x4018` only the ref, `0x401A` only the
  handle, `0x4035` neither, and both ACKs echo the 12 bytes. The pdb2016 structs lack the ref, so the decoder misread
  0x4001 / 0x4002 / 0x4007 / 0x400B / 0x4018 (size issues since part 7); `annotations/P02.json` `packets.character` now
  has the ref-prefixed layouts (and 0x4008, which had none).
- **`bufferlocation` is always 0.** It is `WholeSaver::ws_savestorepoint.value` (a `BitANDInt`, mask 0x7FF). Only the
  WholeSaver constructor @ FUN_004565f0 writes it, so it never moves. The 2048-slot ring `ws_savestore`
  (`EventSaveCheck[0x800]`, 0x148A8 bytes each, 172 MB per zone process) is touched only by the constructor and the
  destructor. `ws_save2DB` copies its packets into `ws_saveblock` instead, and `ws_saveassure` @ FUN_00453d40 is
  empty. Pending saves are therefore never tracked, and the ACKs' `bufferlocation` identifies nothing (original bug)
  P02-B21.
- **`0x4001` content** (decoded with the new layout): `level` = current level / exp / fame (6, 7, 8 / 30 / 14, 20, 27
  in the level-up bursts; 8 / 31 / 35 at 118.993). `location` comes from `so_SaveLocation` @ FUN_004542f0: it is the
  position **before** the link (RouN 6471 / 10573 for the portal at 118.993; the destination travels in WM 0x180D,
  §7.5.4). After the revive (`sp_MiscFlag.JustRevive`) it is the map's regen point (RouCos02 9647 / 9002), while
  `map_kq` / `coord_kq` (always the current map and position) keep the death spot 16351 / 12980. `kqhandle` is
  0xFFFFFFFF. `stat`: HPStone 13 and SPStone 10, then the current HP / SP (107 / 127, 126 / 143, 140 / 165 at levels
  6–8; 28 / 78 after the revive, the 30 % of §9.5).
- **Answers**: only 0x4001 and 0x4007 get one; 0x4008 (one procedure set) comes before 0x4002 (three procedures, D02 §6)
  in every burst. In `combat` 118.034, `0x401A` left 16 ms after the rest. It went on the link that had taken `0x4018`
  in the same ms (Nagle, as in §7.5.4) *(inferred)*.
- `0x0410 StoreType` = the `reason` argument: 8 for `&levelup`, 2 for both zone links **and** the revive (a same-zone
  link, §9.5). Its `mappos` is the position before the link, as in 0x4001.

### 10.2 Map-login requests and the GameLog login / link logs

At every `0x1803` (`shop` 10.766, 120.991; `combat` 10.919, 45.854, 102.537, 119.643) the zone sends CharDB `0x10B3
NC_CHAR_REGNUM_VARIFICATION_REQ {zonehandle, "Test2", 5}`. It is the first link packet of the burst
(`sp_RegistNumberVarification` @ FUN_00551950 at the start of the 0x1803 handler, Z01 §6 / Z18 §1.1). Next in the same
ms comes CharDB `0x1080 NC_CHAR_WEDDINGDATA_REQ {ref}` (after `sp_ConnectFromWhere`), and 0–6 ms later the WM's GameLog
`0x040F NC_LOG_GAME_LINK` (`StoreType 99`, the WM's copy of 0x180C, W01 §7.3) arrives on `W00_GLDB#1`. The answers:

- `0x10B4 {zonehandle, 5, iscorrect 1}` 0–11 ms later (D02 §7.1 `usp_Char_chkCharNo`; Z07 §10.2).
- `0x1081 NC_CHAR_WEDDINGDATA_ACK` 1–12 ms later, with `Error 0x12E2` (4834). D02 §11 predicts that code for a single,
  because the partner-name lookup of partner 0 finds no row. `Status 0`; `When` = `SubWhen` = 1582426906 (the packed
  ShineDateTime of the empty row). The zone ignores an answer with `Error ≠ 0` (Z07 `so_ply_WeddingData`), so no
  client `0x1081` is sent *(captured)*.

§5.1's batch-1 line "0x10B3 not sent (conditions false)" was wrong. 0x10B3 is a CharDB link packet and batch 1 had no
link streams; the call has no condition besides `mode == 0`. §5.1 is corrected.

Login (W01 §4.2, §7.4): WM `0xC806 NC_SYSLOG_CHAR_ENTER_GAME {103, 5}` on `W00_GLDB#1` in the 0x1005 handler, then the
CharDB's own `0x040A NC_LOG_GAME_LOGIN` (56 bytes: login map / position, `Cen 99440`, `usrregnum 103`, `spawnapps
"Original"`) on `#2` 1 ms later (D02 §5, D05 §2). Zone change: `0xC809 NC_SYSLOG_CHAR_ZONE_TRANSITION {103, 5,
DestZoneNo, SrcZoneNo, CharLev}` (2 / 0 for RouN → RouCos02, 0 / 2 for `&linkto RouN`) is sent 1–2 ms after the save
burst, at the end of `so_LinkTo`'s other-zone branch (Z01 §7.1). It is not sent for the same-zone revive.

### 10.3 Character titles in `0x400B`

| Burst | n | Type = value (pdb2016 `CHARACTER_TITLE_TYPE`) |
|---|---|---|
| `combat` 43.715 | 2 | 4 `ID_PLAY_TIME` 75, 41 `ID_NOCHATTING_COUNT` 75 |
| `combat` 102.376 | 4 | 4 = 76, 9 `ID_NOKILLED_BY_MOB` 2, 11 `ID_TOTAL_KILL_MOB` 11, 41 = 76 |
| `combat` 118.034 | 2 | 4 = 77, 41 = **0** |
| `shop` 30.500, level 6 | 5 | 4 = 81, 9 = 2, 24 `ID_BUY_NPC_COUNT` 3, 41 = 4, 46 `ID_JOB_CLERIC` 6 |
| `shop` 30.500 / 30.501, levels 7 / 8 | 2 | 9 = 2, 46 = 7 / 8 |
| `shop` 118.993 | 4 | 4 = 83, 11 = 12, 23 `ID_SELL_NPC_COUNT` 2, 41 = 6 |

- Only titles marked for saving are sent (`bTitleSave`, Z12 §7.4), so `n` varies. 0x400B is sent only when the count
  is > 0. The value is a u64 (pdb2016 `CHARACTER_TITLE_DB_SAVE::TitleValues`); D02 §6 reads the same 8 bytes as two u32.
- `ID_PLAY_TIME` and `ID_NOCHATTING_COUNT` count minutes (one step per minute boundary passed). The chat at `combat`
  106.620 reset 41 to 0. That identifies Z02 §3.1's `FUN_005cc2a0(p+0x29638)` "event 0x29 (inferred: achievement/stat
  hook)" as the reset of title 41 = 0x29. By the same enum, the shout's `FUN_005cc2d0` event 0x2a is `ID_BROADCAST_COUNT`
  (42) *(inferred)*.
- `ID_JOB_CLERIC` carries the level (Test2 is a Cleric). One kill adds 1 to 11 (`combat`'s four kills end at 11, the
  `shop` slime makes 12), the two sales make 23 = 2. Type 9 goes out unchanged (2) with every level-up save and was
  not sent at the zone links before the death. It is 2 after the death in `combat` and stays 2 in `shop` (§9.5, part-12
  title note). Why the level-up re-marks it: settled in the sweep (§14). `CCharacterTitleZone::CT_LevelUp` @
  FUN_005cc2f0 stores the new level in the class-group title (45 + group for classes 1–5 / 6–10 / 11–15 / 16–20,
  60 for 21–25, 113 for 26–27: 46 `ID_JOB_CLERIC` for Test2) only when it changed. It then sets
  `m_TitleValues[9].bTitleSave = 1` and runs `CheckNewTitle(9)` on every level-up, whatever the class. That gives the
  captured {9, 46} of levels 7 / 8.

### 10.4 Chat and the combat stance: broadcasts with and without the sender

- `0x2001 {"test"}` → `0x2002 NC_ACT_SOMEONECHAT_CMD {itemLinkDataCount 0, handle 8003 = the sender, len 4, flag 2
  (chatwin 1, no GM colour), colours 0, "test"}` to the sender itself 3 ms later (Z02 §3.1).
- `0x2008 NC_ACT_CHANGEMODE_REQ {mode 2}` (three times, each before attacking): no reply, and no `0x2009` reaches the
  sender (Z02 §2.5).
- The reason is the u8 argument of `so_AllOfRange` @ FUN_0054bc80 (`so_AllOfRange_Class1`, passed on to the field's
  `fm_fp_AllOfRange2`). `so_Chat` @ FUN_00458c90 passes 1; `sp_NC_ACT_CHANGEMODE_REQ` @ FUN_00457560 and
  `sp_HPStoneUse` @ FUN_00589180 (0x500B, §9.6) pass 0. So 1 = the source receives its own broadcast, 0 = it does not
  *(captured for both values)*. Code (sweep): every `FieldMap` constructor @ FUN_00466170 sets
  `fm_BroadFunc.fm_fp_AllOfRange2` to `ShineObject::so_AllOfRangeNomal` @ FUN_0054c900 (`…_Class2`). That function
  runs the iterator on every object in range whose handle is not the u16 `param_7`, and after the scan it calls
  `iterator(source, source, 0)` only when the u8 is ≠ 0. This settles §9.6's 0x500B question.
  `0xCC04 SOMEONE_RIDE_ON` also reaches the rider (`nHandle` = itself, §10.7).

### 10.5 NPC menus and the quest dialog (`shop`)

- Storage keeper (mobid 108, 48.777) and item merchant (mobid 88, 85.816): `0x200A` → `0x201C NC_ACT_NPCMENUOPEN_REQ
  {mobid}` 17–18 ms later. After the player's choice the client sends `0x201D {ack 1}` and the role runs: 4 × `0x3C08`
  47 ms later (§7.6.1) or `0x3C0B` 4 ms later (Z02 §6.2 / §6.3).
- Blacksmith James (mobid 28, handle 17084; 12.046 and 92.144): no 0x201C. `NPCClickCheck` returns 1 →
  `QuestPlayer.NPCClick` → `0x4401 NC_QUEST_SCRIPT_CMD_REQ {nQuestID 10 / 947, Cmd 2 SAY, IsPigeonStartType 0, Data
  {nID 230 / 18702, TalkerType 0 NPC, NPCNo 28}}` 1–10 ms later. NPCNo is `m_nClickNPCNo`, which SAY substitutes for
  0xFFFF (Z15 §3.3). The rest of `Data` is 0, except 7 at +0xC and 1 at +0x10 in both packets: SAY does not use those
  bytes (Z15-B11's leftovers; their source was not identified). The client's quest dialog also offers the NPC's menu:
  choosing the shop answers `0x201D {1}` (13.068, 92.877), which the zone accepts because case 1 also armed the range
  check (Z02 §6.2). The shop list `0x3C09` follows 8–15 ms later. No `0x4402` is sent, so SAY's wait stays open
  (`m_bWaitResult`, Z15 §3.4). The next click got the SAY of another quest (947) *(the zone state is not on the
  wire)*.
- Every map login brings three client `0x200B NC_ACT_ENDOFTRADE_CMD` in one ms. Closing a shop or storage window sends
  one more.

### 10.6 Level-up extras (`shop` 30.501, §9.4)

- Per `0x240C`: `0x105B NC_CHAR_STAT_REMAINPOINT_CMD {remain 6 / 7 / 8}` (one point per level; 5 at level 5) and
  `0xBC05 NC_GAMBLE_EXCHANGECOIN_CHANGE_CMD {10000}`. 10000 is the `GBExchangeMaxCoin.shn` cap of levels 6–8 minus the
  0 coins exchanged (Z12 §5.2 `so_Gamble_ChangeExchangedCoin` @ FUN_00617360).
- The client sends `0x4025 NC_CHARSAVE_UI_STATE_SAVE_REQ {btMysteryType 1}` three times, 15 / 19 / 65 ms after the
  burst. The 2016 client's `GameFrameWork::On_NC_BAT_LEVELUP_CMD` @ FUN_004aa3d0 sends it once `Inventory::FindMysteryVault`
  finds a Mystery Vault item with window data, and also calls `MysteryVaultWin::OnReachTheLevel` and `OpenMysteryVaultWin`.
  The only other sender is FUN_004a59d0 (`{u8 arg}`; caller not traced). This answers Z12's open question "who sends
  0x4025". The zone (`sp_NC_MISC_DB_UI_STATE_SAVE_REQ` @ FUN_00562f40, Z12 §7.1) sends CharDB `0x4027 {ref, 1}` 2–9 ms
  later; two of one tick leave on two links in the same ms. CharDB answers `0x4028 {ref, err 0x2158}` 1–8 ms later, and
  @ FUN_00551360 forwards client `0x4026 {8536}` 7–10 ms after that. The 2016 client has no handler for it (Z01-B5).
- `0xBC04 NC_GAMBLE_COIN_CHANGE_CMD {nCoin 0}` is the purchase's coin releaser (§7.6.1).

### 10.7 Mover packets and object removal (`combat`)

- **Summon** (19.029): `0x1C1A NC_BRIEFINFO_REGENMOVER_CMD {22139, nID 160, nHP 0, nCoord {6171, 6883, dir 38},
  AbstateBit 0, nGrade 0, nSlotHandle 10 × 0xFFFF}` → `0xCC02 NC_MOVER_RIDE_ON_CMD {22139, slot 0, grade 0}` →
  `0xCC04 NC_MOVER_SOMEONE_RIDE_ON_CMD {8013, 22139, 0, 0}` → `0xCC0A NC_MOVER_HUNGRY_CMD {780}`, all in one ms (Z13
  §8.2 / §8.3 / §8.10). The seat list is still empty because 0x1C1A is sent before the rider boards.
  `0xCC0D NC_MOVER_MOVESPEED_CMD {22139, 36, 165}` follows 0.39 s later (0.47 s in zone B). Z13 §8.7's formula gives
  exactly these values: (MoverMain 160 WalkSpeed 1100 / RunSpeed 1300 + grade bonus 0 + rate 0) × the rider's 33 / 127 / 1000.
- **Hunger**: 0xCC0A 770 at 29.032, 760 at 39.026: `ConsumeHG 10` every `Tick 10000` ms (`MoverHG.shn` WoodenHorse01)
  through `smv_FoodEat` @ FUN_0055f110 (Z13 §8.6), 10.00 s apart and counted from the summon. In zone B the mover is
  re-summoned in the map-login ms (45.855, Z13 §7.7) at 760, the value of the 0x3449 save, and drops to 750 10.001 s later.
- **Dismount** (43.716 by the link, 56.126 by the item): `0x203E {33, 127}` (the rider's own speeds again),
  `0xCC06 NC_MOVER_RIDE_OFF_CMD {}`, `0x3016`, `0x1805 {mover handle}` (§7.6.1).
- **`0x1805 NC_MAP_LOGOUT_CMD`** also removes the dead mobs, 10.0 s (9.98–10.03 s) after their `0x240B`. That matches
  Z09 §5.4's `(corpseExtra·5 + 50)·2` = 100 `g_Now` units with `corpseExtra` 0. It removes picked-up items too, in the
  frame of their `0x300A` (§7.6.1). The `shop` slimes get none: Test2 left RouN 8.1 s after the kill, and the capture
  ends less than 10 s after the RouCos02 kill.

### 10.8 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| S→C | 0x2002 | NC_ACT_SOMEONECHAT_CMD | 1 | 11 | confirmed | reaches the sender (`so_AllOfRange` u8 1) |
| C→S | 0x2008 | NC_ACT_CHANGEMODE_REQ | 3 | 1 | confirmed | mode 2; no 0x2009 to the sender |
| C→S | 0x201D | NC_ACT_NPCMENUOPEN_ACK | 4 | 1 | confirmed | also after a quest SAY (no 0x201C) |
| S→C | 0x1805 | NC_MAP_LOGOUT_CMD | 9 | 2 | confirmed | mover, corpses (10.0 s), picked items |
| S→C | 0x1C1A | NC_BRIEFINFO_REGENMOVER_CMD | 2 | 139 | confirmed | decoder needed `SHINE_COORD_TYPE` / `ABNORMAL_STATE_BIT` (P02.json `structs`) |
| C→S | 0x4025 | NC_CHARSAVE_UI_STATE_SAVE_REQ | 3 | 1 | confirmed | client sender = `On_NC_BAT_LEVELUP_CMD` (Mystery Vault) |
| S→C | 0x4026 | NC_CHARSAVE_UI_STATE_SAVE_ACK | 3 | 2 | confirmed; **bug** | 8536; no 2016 client handler (Z01-B5) |
| S→C | 0x4401 | NC_QUEST_SCRIPT_CMD_REQ | 2 | 103 | confirmed | SAY, NPCNo = clicked NPC; decoder needed `STRUCT_QSC` |
| S→C | 0xBC04 | NC_GAMBLE_COIN_CHANGE_CMD | 1 | 8 | confirmed | 0 (§7.6.1) |
| S→C | 0xBC05 | NC_GAMBLE_EXCHANGECOIN_CHANGE_CMD | 3 | 8 | confirmed | 10000 = GBExchangeMaxCoin |
| S→C | 0xCC02 | NC_MOVER_RIDE_ON_CMD | 2 | 4 | confirmed | |
| S→C | 0xCC04 | NC_MOVER_SOMEONE_RIDE_ON_CMD | 2 | 6 | confirmed | also to the rider |
| S→C | 0xCC06 | NC_MOVER_RIDE_OFF_CMD | 2 | 0 | confirmed | after 0x203E |
| S→C | 0xCC0A | NC_MOVER_HUNGRY_CMD | 5 | 2 | confirmed | −10 per 10 s |
| S→C | 0xCC0D | NC_MOVER_MOVESPEED_CMD | 2 | 6 | confirmed | Z13 §8.7 formula exact |
| S→C | 0x105B / 0x203E | (batch-1 types) | 9 / 8 | 1 / 4 | confirmed | + level-up values, dismount |
| Z→CDB | 0x4001 | NC_CHARSAVE_ALL_REQ | 7 | 111 | confirmed; **corrected** | ref + pdb2016 struct (P02.json) |
| CDB→Z | 0x4002 | NC_CHARSAVE_ALL_ACK | 7 | 12 | confirmed; **corrected** | ref + handle |
| Z→CDB | 0x4007 | NC_CHARSAVE_ABSTATE_REQ | 7 | 14 | confirmed; **corrected** | abstatenum 0 |
| CDB→Z | 0x4008 | NC_CHARSAVE_ABSTATE_ACK | 7 | 12 | confirmed | first layout (P02.json) |
| Z→CDB | 0x400B | NC_CHARSAVE_TITLE_REQ | 7 | 32–59 | confirmed; **corrected** | 9-byte `{Type, u64}` entries |
| Z→CDB | 0x4018 | NC_CHARSAVE_PKCOUNT_CMD | 7 | 14 | confirmed; **corrected** | ref + pdb2016 struct |
| Z→CDB | 0x401A | NC_CHARSAVE_REST_EXP_LAST_EXEC_TIME_SAVE_REQ | 7 | 6 | confirmed; **bug** | no ref; `bufferlocation` always 0 (P02-B21) |
| Z→CDB | 0x4035 | NC_CHARSAVE_USEITEM_MINIMON_INFO_DB_CMD | 7 | 78 | confirmed | last of the burst |
| Z→CDB | 0x4027 | NC_CHARSAVE_DB_UI_STATE_SAVE_REQ | 3 | 7 | confirmed | |
| CDB→Z | 0x4028 | NC_CHARSAVE_DB_UI_STATE_SAVE_ACK | 3 | 8 | confirmed | err 0x2158 |
| Z→CDB | 0x10B3 | NC_CHAR_REGNUM_VARIFICATION_REQ | 6 | 26 | confirmed; **corrected** | every 0x1803 (§5.1's "not sent" was wrong) |
| CDB→Z | 0x10B4 | NC_CHAR_REGNUM_VARIFICATION_ACK | 6 | 7 | confirmed | iscorrect 1 |
| Z→CDB | 0x1080 | NC_CHAR_WEDDINGDATA_REQ | 6 | 6 | confirmed | |
| CDB→Z | 0x1081 | NC_CHAR_WEDDINGDATA_ACK | 6 | 43 | confirmed | Error 0x12E2 (single); not forwarded |
| CDB→GL | 0x040A | NC_LOG_GAME_LOGIN | 2 | 56 | confirmed | 1 ms after WM 0xC806 |
| WM→GL | 0x040F | NC_LOG_GAME_LINK | 6 | 41 | confirmed | StoreType 99 |
| Z→GL | 0x0410 | NC_LOG_GMAE_LOGOUT_ZONEINFO | 7 | 41 | confirmed | StoreType 2 / 8 |
| WM→GL | 0xC806 | NC_SYSLOG_CHAR_ENTER_GAME | 2 | 8 | confirmed | |
| Z→GL | 0xC809 | NC_SYSLOG_CHAR_ZONE_TRANSITION | 3 | 11 | confirmed | other-zone links only |

## 16. Login side, batch 3: refusals, character create / delete, idle (`s37`) *(captured)*

Scenario 37 (`docs/plan/capture-scenarios.md` §3.37, setups S10, S11, X6). Account `admin` (`nUserNo` 103, `nAuthID` 9)
and `testaccountB` (104, `nAuthID` 1). Login connections: `login#1` (129.8 s, world select, character list until
631.4 s), `#2` (631.6 s, the OTP return), `#3` (677.6 s, world closed), `#4` (803.5 s, world full), `#5` (846.0 s,
blocked), `#6` (879.0 s, not login-able). Link streams: Login's AccountDB / AccountLogDB links are `AccDB#1` /
`ALDB#1`; the WM's are `AccDB#2` / `ALDB#2` (until the WM stops), its CharDB link `W00_CDB#2`, its GameLog link
`W00_GLDB#1`; the Character server's GameLog link is `W00_GLDB#18`. The WM stop and the two WM starts (729.4 s,
783.8 s) with the link handshakes and the start-up queries are §17.

### 16.1 Message order

```text
create (250.412, again at 347.053 with class 21):
  C→WM 0x1401 {slot 2, "X37Del", shape 0x85}  → 14 ms → WM→CDB 0x1402 → 100 ms (85 ms the second time) → CDB→WM 0x1405
  → 8 ms, one WM pass → WM→AccDB 0x140D, WM→GL 0x0411, WM→GL 0xC804, WM→C 0x1406   (same ms)
delete (319.801; the client's name check refuses a wrong confirmation without a packet):
  C→WM 0x1407 {slot 2} → 14 ms → WM→CDB 0x1413 → 3 ms → CDB→WM 0x1414 {nGuildNo 0}
  → 12 ms → WM→CDB 0x1408 → 22 ms → CDB→WM 0x140B + CDB→GL 0x0412 (same ms)
  → 10 ms → WM→AccDB 0x140E, WM→GL 0x0412, WM→GL 0xC805, WM→C 0x140C, WM→CDB 0x9424, WM→zones 0x10B2 ×4   (same ms)
  → 3 ms → CDB→WM 0x9425 {DBError 0x1740}
back to the world list (631.405):
  C→WM 0x0C33 → 11 ms → WM→Login 0x0C35 → 1 ms → Login→WM 0x0C36 {0x1E58} → 16 ms → WM→C 0x0C34
  → client closes the WM connection → 15 ms → WM→AccDB 0x0C11, WM→ALDB 0x0722, WM→ALDB 0xC803, WM→zones 0x0C19 ×4
  → 143 ms → new Login connection: seed, 0x0C65, 0x0C37 token → Login→WM 0x0C16, C 0x0C0A → WM→zones 0x0C16 ×4
  → 632.981 C 0x0C18 {0}: the user leaves the world list for the login screen
world closed (WM stopped after 655.5 s): 0x0C0A / 0x0C1C {worldstatus 0}; world select 696.113 → 17 ms → 0x0C0C {0}
world full (WM up since 783.8 s): 0x0C0A {5}; world select 805.915 → 13 ms → Login→AccDB 0x0C10, Login→ALDB 0x0721,
  Login→WM 0x0C0D → 18 ms → WM→Login 0x0C0E {ok 1} → 14 ms → C 0x0C0C {5, WM address, validate}; no WM connection
blocked (846.0): 0x0C5A … AccDB 0x0C5C {nBlock 1, bLoginAble 1} → 10 ms → C 0x0C09 {0x47}, ALDB 0x0720, ALDB 0xC802
not login-able (879.0): AccDB 0x0C5C {nBlock 0, bLoginAble 0} → 5 ms → ALDB 0x0720, 0xC802 → 15 ms → C 0x0C09 {0x48}
```

- **Create** (W01 §4.1, D02 §3) **confirmed**: the WM sends its four packets in code order (`fc_NC_AVATAR_CREATEDATASUC_ACK`
  @ FUN_004113c0); `0x1402 adminlevel` is 0 for the GM account (the WM writes a constant 0). Shape 0x85 = Fighter
  (class `(0x85 >> 2) & 0x1F` = 1), 0xD5 = Trickster (21); `0x140D.nClass` and `0xC804.CharClass` carry the same
  value. The CharDB answer takes 85–100 ms (`p_Char_Create`). Slot 2 is the notes' "slot 3" (the client counts from 1).
- **Delete** **confirmed** against W03 §4.5 (guild check 0x1413 → 0x1414 → 0x1408, `nNo` = the guild number 0) and
  W04 §4.3 (`CWMClientSessionManager::AvatarErase` @ FUN_004382d0: 0x9424 to CharDB, 0x10B2 to every zone process; no
  friend or guild member, so no 0x540C / 0x7438). W01 §4.1's "0x1407 sends 0x1408" is the statement W03 §4.5 already
  corrects; the capture sides with W03 (`CParserClient::fc_NC_AVATAR_ERASE_REQ` @ FUN_00412fa0 sends `09 13 14`).
  GameLog 0x0412 arrives twice, 10 ms apart: first from the Character server (D02 §3.4, its own GameLog link), then from
  the WM (D05 §2.3, "two senders"). 0x9425 is also asked by every character delete, not only by the OPTool 0x281F path
  that W04 §12.4's 0x9425 block names.
- **Return to the world list** (W01 §5.1, `login-server.md` §5.3) **confirmed**: `0x0C36 {nError 0x1E58, hWM 37500,
  sOTP}` in W01's field order; the session closes when the client drops the WM connection (`Client_OnClosed` @
  FUN_00437030: `playmin 7` = 421.7 s since 209.7 s, `closeReason 0x780`, `LoginKeepTime 7`). No handler on this path
  sets `closeReason`; 0x780 (normal logout) is the session's value from before *(inferred)*. The token login is the
  batch-1 flow (§3.1); the Login → WM 0x0C16 of the OTP handler carries other stale header bytes (`07 f3 23 fc 00
  50`) than the password path (`76 27 d3 ef 76 00`, again at 129.9 s and 803.5 s): P02-B5, one stack slot per caller.
- **World closed**: the world stays in the list with status 0 (L01 status table, "WM link released") and the client
  shows "Server is closed. Please try login later." (notes). The refusal is **not** "status and zeros"
  (`login-server.md` §4): see §16.3 and P02-B23.
- **World full**: the X6 prediction **confirmed** to the byte: Login sends AccountDB 0x0C10, AccountLog 0x0721 and WM
  0x0C0D before it answers `0x0C0C {5}` with the WM address and a valid `validate` set (L00-B3); the WM accepts the
  pending login (`0x0C0E ok 1`); the client shows "Server is full. Please try again later." and does not connect. The
  status 5 at 803–806 s does not yet come from the capacity 1: the only `0x0808` the WM had sent since its start was
  `{0, 0}` (P02-B22). From 816.2 s the WM reports `{0, 1}`, which also gives 5 (`95 × 1 / 100 = 0`); before the change
  it reported `{0 or 1, 2500}`. So `MaxOfUser` is the last number of the WM's client row in `ServerInfo.txt` (X6's
  inference **confirmed**).
- **Blocked / not login-able**: `AccountCheckResult` (`login-server.md` §5.1) **confirmed** for 0x47 (`nBlock 1`) and
  0x48 (`bLoginAble 0`); the client texts are the notes' "The ID has been blocked." and "The World Servers are down for
  maintenance". Neither path asks AccountLog 0x0C5D. The S11 variant used clears the whole group: `nAuthID` stays 1 and
  `bLoginAble` is 0 *(captured)*.

### 16.2 Heartbeats and idle

- **Login ↔ client**: the 2016 client opens the Login connection only when the user submits the login form: in all
  six connections the seed comes 2–9 ms before `0x0C65`, and nothing reached port 9010 during the 70 s on the login
  screen before 129.8 s. On the world list the client polls `0x0C1B` every 10.0 s (also after a refused world
  select), and it closes the connection after 0x0C09. A 2016 client is therefore never 30 s silent on a Login
  connection: Login sent no `0x0804` in any capture, and L01-B11 (heartbeat before the login request) is not reachable
  with this client *(captured)*. Scenario 37 step 1 tests nothing as written (no connection exists).
- **WM ↔ client** (7 min on the character list, 209.8–631.4 s): `0x0804` exactly 30.0 s after the last client packet,
  12 times, answered in 1–10 ms; no close (W05 §1.5 / §4.5, §4.4 **confirmed**; scenario 37 prediction 6).

### 16.3 Field findings

- **0x0C0C refusal** (`CParserClient::fc_NC_USER_WORLDSELECT_REQ` @ FUN_00406970): on a refusal Login sends its stack
  `PROTO_NC_USER_WORLDSELECT_ACK` (0x55 bytes) as filled by `GetWorldManagerConnectInfo` @ FUN_0040a020 (L01): status,
  and `wm_ip` / `wm_port` from the `ServerInfo.txt` row (`"172.16.42.214"`, 9110) even though the WM is down. The 64
  bytes of `validate_new[32]` are never written: captured `01 76 00 00 00 32 36 32 30 30 7c f2 ff 00 e0 d1 42 02 b5 e8
  db 84 d8 f9 d3 07 …` (pointer-like words, the text `"26200"`, near the end `"172.01"` of an earlier `%03d` IP string).
  (original bug) P02-B23. The client reads only the status for values below 6 (`login-server.md` §8).
- **0x0720 `userpassword`** (the 16 bytes Login copies from `0x0C5C` +0x10C): the first 16 of the 32 lowercase hex
  characters of `sPassword`, i.e. half of the MD5 the client sent, not the typed password (D01 §4.1 says "the typed
  password"). Logged for both refusals with `userip ac 10 2a e7` and the refusal code.
- **0x140D** (WM → AccountDB, `PROTO_NC_USP_USER_CHARACTER_INSERT`, 0x32 bytes, `sCharName` `char[40]` *(pdb2016)*):
  the WM writes 20 name bytes and one zero byte; bytes +0x1E..+0x30 are stack residue (`9c 64 00 7f 61 52 00 e0 9e 64 00
  5c e1 62 00 8e 00 00 00`, the same in both creates). (original bug) P02-B24. The Account server drops 0x140D unread
  (D01 §3.1), so nothing is stored.
- **0x0808 after a WM start**: `{NumOfUser 0, MaxOfUser 0}` in the same ms as the Login-link handshake (729.448,
  783.818), then `{0, 1}` 30 s later. `CWMLoginSession::SendUserCount` @ FUN_00438d10 (W01 `Login_WorldStatus`) is
  forced on the handshake (W01 §2.1) and sends the client capacity `DAT_00556bb8`, which is still 0 then: the client
  listener opens only after the four DB links are validated (W01 §2 `BootstrapTick`) *(inferred cause)*. Login turns
  `MaxOfUser 0` into status 5 (L01 §3: every threshold 0) and, since it is the first 0x0808 after a connect, pushes
  the list to every client. (original bug) P02-B22: for up to 30 s after every WM start the world reports "full".
- **0x0C35** `ip` 3 878 293 676 = `ac 10 2a e7` (172.16.42.231, network order); **0x0C11 / 0x0722** `{usrregnum 103,
  worldnum 0, playmin 7, error 0x780}`; **0xC803** `{103, LoginKeepTime 7}` (minutes, not seconds).
- **0x1405** = `{clienthandle, numofavatar 1, AVATAR}` (W01's "u8 ?" is `numofavatar`): level 1, `loginmap "RouN"`,
  `delinfo` all zero (5 bytes; P02-B1 concerns only `GetAvatarInfo`), every equipment slot 0xFFFF.

### 16.4 Opcodes

Batch-1 client opcodes of these flows recur unchanged (0x0807, 0x0C65, 0x0C67, 0x0C5A, 0x0C04, 0x0C05, 0x0C0A, 0x0C1B,
0x0C1C, 0x0C0B, 0x0C37, 0x0C18; WM 0x0C0F, 0x0C14, 0x080D, 0x080E, 0x1401, 0x1406, 0x1407, 0x140C, 0x0C33, 0x0C34,
0x0804, 0x0805: §3.2, §4.2). New values and the 22 new link types:

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| S→C | 0x0C09 | NC_USER_LOGINFAIL_ACK | 2 | 2 | confirmed | 0x47 blocked, 0x48 not login-able (§16.1) |
| S→C | 0x0C0C | NC_USER_WORLDSELECT_ACK | 3 | 83 | **corrected** (refusal) | status 0 carries the WM address + 64 stale bytes (P02-B23); status 5 = full answer with `validate` (L00-B3) |
| S→C | 0x0C0A / 0x0C1C | NC_USER_LOGIN_ACK / NC_USER_WORLD_STATUS_ACK | 4 / 17 | 19 | confirmed | `worldstatus` 6, 0 (WM down), 5 (after the WM start) |
| WM→CharDB | 0x1402 | NC_AVATAR_CREATEDATA_REQ | 2 | 33 | confirmed | `adminlevel 0`, `createworld 0`, shape + hair from 0x1401 |
| CharDB→WM | 0x1405 | NC_AVATAR_CREATEDATASUC_ACK | 2 | 133 | confirmed | §16.3 |
| WM→AccountDB | 0x140D | NC_USP_USER_CHARACTER_INSERT | 2 | 50 | **corrected** (stale bytes) | P02-B24; `nClass` 1 / 21 |
| WM→GameLog | 0x0411 | NC_LOG_GAME_CREATE_AVATAR | 2 | 4 | confirmed | `chrregnum` 6 / 7 |
| WM→GameLog | 0xC804 | NC_SYSLOG_CHAR_CREATED | 2 | 9 | confirmed | `UserNo, CharNo, CharClass` |
| WM→CharDB | 0x1413 | NC_AVATAR_GUILD_DATA_REQ | 1 | 7 | confirmed | W03 §4.5 (not W01 §4.1) |
| CharDB→WM | 0x1414 | NC_AVATAR_GUILD_DATA_ACK | 1 | 11 | confirmed | `nGuildNo 0` → straight to 0x1408 |
| WM→CharDB | 0x1408 | NC_AVATAR_ERASEDATA_REQ | 1 | 15 | confirmed | `{handle, usrregnum, avatar, slot, nNo = guild 0}` (W03 §4.5) |
| CharDB→WM | 0x140B | NC_AVATAR_ERASEDATASUC_ACK | 1 | 15 | confirmed | the 0x1408 body echoed |
| CharDB→GameLog, WM→GameLog | 0x0412 | NC_LOG_GAME_DELETE_AVATAR | 2 | 4 | confirmed | two senders (D05), Character server first |
| WM→AccountDB | 0x140E | NC_USP_USER_CHARACTER_DELETE | 1 | 9 | confirmed | dropped by the Account server (D01 §3.1) |
| WM→GameLog | 0xC805 | NC_SYSLOG_CHAR_DELETED | 1 | 9 | confirmed | class 1 |
| WM→CharDB | 0x9424 | NC_HOLY_PROMISE_DB_DEL_CHAR_REQ | 1 | 4 | confirmed | from `AvatarErase` (W04 §4.3) |
| CharDB→WM | 0x9425 | NC_HOLY_PROMISE_DB_DEL_CHAR_ACK | 1 | 6 | confirmed | `DBError 0x1740` ok (D04) |
| WM→Zone | 0x10B2 | NC_CHAR_WEDDING_CANCEL_WEDDING | 4 | 4 | confirmed | one per zone process, `RegisterNumber` = charNo |
| WM→Login | 0x0C35 | NC_USER_CREATE_OTP_REQ | 1 | 266 | confirmed | `{handle, userNo, userId[256], ip}` (W01 §5.1) |
| Login→WM | 0x0C36 | NC_USER_CREATE_OTP_ACK | 1 | 36 | confirmed | `{nError 0x1E58, hWM, sOTP[32]}` (W01's order) |
| WM→AccountDB | 0x0C11 | NC_USER_LOGOUT_DB | 1 | 9 | confirmed | dropped by the Account server |
| WM→AccountLogDB | 0x0722 | NC_LOG_USER_LOGOUT | 1 | 9 | confirmed | same body as 0x0C11 |
| WM→AccountLogDB | 0xC803 | NC_SYSLOG_ACCOUNT_LOGOUT | 1 | 8 | confirmed | `LoginKeepTime` in minutes |
| WM→Zone | 0x0C19 | NC_USER_CONNECTCUT2ZONE_CMD | 4 | 10 | confirmed | header all 0xFF, `usrregnum 103` |
| Login→AccountLogDB | 0x0720 | NC_LOG_USER_LOGINFAIL | 2 | 278 | **corrected** (D01 note) | `userpassword` = half the MD5 (§16.3) |
| Login→AccountLogDB | 0xC802 | NC_SYSLOG_ACCOUNT_LOGIN_FAILURE | 2 | 296 | confirmed | `UserName`, `UserIP "172.16.42.231"`, `spawnapps` |
| Login→WM | 0x0C16 | NC_USER_KICKOFFFROMWORLD_CMD | 3 | 10 | confirmed (P02-B5) | stale header differs per caller (§16.1) |
| WM→Login | 0x0808 | NC_MISC_USER_COUNT_CMD | 27 | 4 | **corrected** (first after a start) | `{0, 0}` on the handshake (P02-B22), then `{0, 1}` |

## 17. Server stop and start on the links, batch 3 (`s37`, `s21d`) *(captured)*

`s37` holds a full stop and two starts: the four zone processes and the WM stop (653–659 s), a first WM start that
ends after 1.25 s (729.4 s), a second WM start (783.8 s) and a zone start (794.6 s). `s21d` starts with the four zone
processes starting against a running WM (0.0 s; X3 setup). The pcapngs of batch 3 keep the TCP SYN / FIN frames,
so link opens and closes are timed with `tcpdump -r … 'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'`; the decoder
streams are mapped by their ports. 106 S2S handshakes (58 + 48), all three packets each.

### 17.1 What happened (TCP opens / closes)

```text
s37
653.266 … 657.329  the 4 zone processes stop one by one (653.27, 654.62, 655.72, 657.33): each closes its 12 links
                   (4 WM, 4 CharDB, 4 GameLog) within 2 ms, FIN from the zone; no packet before (operator stop)
655.466            WM → Login 0x0808 {0, 2500} (the 30-s count, last one)
658.674 … 658.676  WM stops: FIN from the WM on Login, AccountDB, AccountLogDB, CharDB, GameLog, in that order
                   = WorldManagerServer::ProcessStop @ FUN_004067f0 (W05 §1.2)
729.400 … 729.403  first WM start: connects AccountLog, Account, CharDB, GameLog, Login (W05 §1.3 order)
729.415 … 729.561  handshakes, 0x0808 {0, 0} (P02-B22), the CharDB start-up load (§17.3)
730.649 … 730.653  FIN from the WM on the same 5 links, same order: ProcessStop again, 1.09 s after 0x9804 (§17.6)
783.801 … 783.945  second WM start: same connects, handshakes, 0x0808 {0, 0}, the same load, then 0xA41A later
794.639 … 797.121  zone start, order 0, 1, 3, 2 (0.6–1 s apart): per zone 4 CharDB, 4 GameLog, 4 WM connects in 8 ms;
                   the WM closes the 2nd and 4th WM link of every zone 5–22 ms after the SYN, without a packet (§17.4)
822.998 … 845.887  each zone reconnects the closed links (two at a time); again one of a pair is closed when both
                   land in one WM pass; after 843.8 / 845.9 every zone holds 4 WM links
s21d
0.000 … 2.267      zone start against the running WM, order 0, 1, 3, 2: the same 12 connects per zone, the same
                   refusals of WM links 2 and 4 (0.012 / 0.028, 0.991 / 0.997, 1.590 / 1.606, 2.272 / 2.288)
27.201 … 29.872    first retry per zone (25–28 s after the refusal); 47.175 / 47.429 / 48.171 second retry, 20.0 s
                   (±0.03) after the first for the three zones whose first retry was refused again
```

The Character and GameLog servers accept all 4 links of a zone within 1 ms: the refusal is the WM's (§17.4). Zone
and WM never close a link because of the other side going down: the zones were stopped before the WM, and the
Character server's GameLog link (`W00_GLDB#18`) runs on with heartbeats through both WM starts.

### 17.2 The S2S handshake (0x0801 / 0x0802 / 0x0803)

```text
listener → connector  0x0801 NC_MISC_S2SCONNECTION_RDY {}                      on accept (W05 §1.4, Z01 §3.3)
connector → listener  0x0802 NC_MISC_S2SCONNECTION_REQ { echo_data, server_to_id, server_from_id,
                                                          server_from_world_num, server_from_zone_num, key }
                      0–56 ms after the 0x0801 (zones: up to 56 ms, WM: same ms)
listener → connector  0x0803 NC_MISC_S2SCONNECTION_ACK { echo_data = the request's, error = 0 }
```

- **Server ids confirmed** on all 106: 0 Account, 1 AccountLog, 2 Character, 3 GameLog, 4 Login, 5 WM, 6 zone;
  `key = server_to_id + server_from_id` (5 … 11) every time; world 0; zone 0–3 (W01 §7.1, W05 §5.2, Z01 §3.3,
  D01 / D02).
- **echo_data**: the WM writes 0 on its 5 links; the zones' byte is never written (Z01-B2 **confirmed**): 126, 155,
  222, 17, 63, 3, 125, 112, 67, 4, 12, 45, 255, 38, 104, 33, 2. The two links a zone opens in the same ms usually
  carry the same value (same stack). Every peer copies it back in 0x0803 (106 / 106), `error` 0 every time.
- **After 0x0803** the zone, per WM link, sends `0x180F` and `0xA419` on that link (`wms_NC_MISC_S2SCONNECTION_ACK`
  @ FUN_005a3320, Z01 §3.3: confirmed, on every link that registers, 2–4 times per zone start), and **once per process**
  `0x7446` on the round-robin link (`gz_IsSendReq`, set by the first call, reset only in the constructor). The first
  GameDB link's 0x0803 sends `0xBCD5` once (`smjpr_RankingReq` @ FUN_00626220, guard `smjpr_IsReq`). §17.4 has the
  order.

### 17.3 WM start-up: links and the CharDB load (W05 §1.3, W03 §9.1)

```text
729.400 SYN ALDB, AccDB, CDB, GLDB, Login (1 ms apart; ProcessLink order: AccountLog, Account, Char, GameLog, Login)
729.415 0x0801 from AccountDB / CharDB / GameLog → WM 0x0802 at once; AccountLog's 0x0801 at 729.415, Login's 729.432
        Login 0x0803 → WM 0x0808 {0, 0} in the same ms (P02-B22)
CharDB load, one request per WM pass after each answer (state machine of ProcessPacket @ FUN_00405aa0):
  0x7456 {1 byte}             → 0x7457 {Error 0x0C41, PartMask 3, NumOfGuild 0}                   18 ms
  0x7503 {1 byte}             → 0x7504 {PartMask 2, nNumOfEmblem 0}                               17 ms
  0x74BC {1 byte}             → 0x74BD {Error 0x0C41, PartMask 3, 0}                              40 ms
  (states 0xB / 0xC: 0x7454 per guild; no guild, so nothing on the wire)
  0x7485 {nGTNo 0}            → 0x7486 {Error 0x0D40, nGTNo 1794258000, nMatchType 6, MatchTime[9], 31 brackets, …} (204 B)
  0x74F6 {nGTNo 1794258000}   → 0x74F7 {Error 0x0D50, PartMask 3, 0}
  0x9801 {1 byte}             → 0x9802 {Error 0x1780, PartMask 3, 0}
  (states 0x13 / 0x14: 0x980F per guild; nothing)
  0x9803 {nRoundTime 1}       → 0x9804 {Error 0x18B8, PartMask 3, dAggregationDate 0, 0 rows}       144 ms in all
  no 0x9805: CharDB link state 1 directly (below)
second start (783.801): the same requests and answers byte for byte; then 794.763 WM → CharDB 0xA41A (§17.4)
```

- **Order and codes confirmed** against W03 §9.1, §6.1, §8.4 (all ok codes as documented: 0x0C41, 0x0D40, 0x0D50,
  0x1780, 0x18B8; 0x7504 has no `Error`). 0x7486 = 43 + 31 × 5 + 6 = 204 bytes as W03 §8.4 lays it out.
- **No 0x9805** (state 0x17) in either start: `CGuildManager::Recv_NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_ACK`
  @ FUN_00441aa0 sets `m_bAcademyRankInit = 1` when `RankData.dAggregationDate` is 0 (never aggregated; the next
  balance time is this week's from `GuildAcademy` data row 0, + 7 days if already past); state 0x17 (→ 0x9805 → 0x9806)
  is taken only when a stored date is more than 600 s older than the balance time that has passed. The 0x9804 handler
  `fc_…_GET_RANKING_LIST_ACK` @ FUN_0040ccc0 then sets the CharDB link to state 1. W05 §1.3 names 0x9806 as "the last
  answer" that sets state 1: that holds only on the balance path (§13).
- **The 1-byte requests** (0x7456, 0x7503, 0x74BC, 0x9801; 0x9805 too) are raw 4-byte packets built in the stack word
  `local_10c` (`{3, op lo, op hi, byte 3}`); byte 3 is never written for the packet (W03 §11 "observation" for
  0x7456). It is **0** in both starts because the AccountDB / AccountLogDB pump of the same `ProcessPacket` call stores
  `local_10c = 1` first whenever that link is in state 1 or 2, i.e. always after the handshakes; only a pass with
  both links down would send a stack byte. Annotated in P02.json `packets.character` (`(unset)`) so the decoder no
  longer reports "size 1 vs 0".

### 17.4 Zone start: registration, the WM's accept refusals, reconnects

```text
zone 0, s37 (the other zones and s21d alike, offsets ±10 ms):
794.639–.644 SYN 4 × CharDB, 4 × GameLog            all accepted, 0x0801 → 0x0802 → 0x0803
794.645–.647 SYN 4 × WM (#17 #18 #19 #20)            #18 closed by the WM at .654, #20 at .669: no 0x0801, FIN at once
794.702      0x0802 on #17 and #19 (echo 126)
794.717      0x0803 + 0x0821 on #19, then on #17   (each registration: 0x0803, SendWMTimeToZone(force) → 0x0821 to every
             registered zone's broadcast link, enss_NPCStandState (nothing: no standing event NPC), GMEM_SendAllEventInfo
             (nothing))
794.731      #17: 0x180F {107 maps}, 0xA419 {17}, 0x7446 {0x11};  #19: 0x180F, 0xA419;  CharDB#20: 0xBCD5
794.737      CharDB → 0xBCD6 × 3 {Machine 0/1/2, 0x2940, JackPot 0, 0 ranks}
794.740      #17 0x7495 (the per-minute guild-war query, first run) → .794 0x7496 {0}
794.763      WM → CharDB 0xA41A {the first 0xA419's 17 entries}: once per WM start, no answer (W04-B43)
794.779      WM → zone 0x7447 {PartMask 3, 0 guilds}
795.408      zone 1 only: 0x207D NC_ACT_SCRIPT_MSG_WORLD_CMD {0xFFFF, "E_Olympic_A04" + 18 heap bytes, nlen 0×5}
823.834      zone 0 retries #18 / #20 as #37 (accepted) and #38 (closed at once); 843.842 #41 accepted
```

- **Accept refusal** (S02 §1.4 per-IP admission rule, **confirmed**): `CSocket_Acceptor::SetAccepted` @ FUN_00463c40
  refuses a socket while another one from the same IPv4 address waits in the accepted ring, and the accept thread
  (`AcceptThreadRing` @ FUN_00463ee0) then calls `shutdown` + `closesocket` (the FIN 5–22 ms after the SYN, no packet).
  `WorldManagerServer::ProcessConnect` @ FUN_00405860 drains the ring once per main pass (≈ 15.6 ms), so of 4 links
  opened within 2 ms the 1st and 3rd survive. Every zone therefore runs its first 25–30 s on 2 of its 4 WM links
  (round robin over the verified entries only, §7.5.1, so traffic is not lost) and gets the full 4 after 45–50 s when
  a retry pair is split again (`s21d` zones 0, 1, 3; `s37` zones 0, 2). Two connects 2 ms apart can both pass when
  a pass falls between them (`s37` 822.998 / 823.000, `s21d` 29.870 / 29.872). (original bug) P02-B25: S02 calls the
  rule a flood guard *(inferred)*, but it also refuses the zones' own server links on every start, and any two
  clients behind one NAT address that connect in the same pass (§12).
- **Retry timing**: `SocketBundle::sb_DisconnectCheck` @ FUN_005ab2c0 / `sb_Packet` @ FUN_005ab030 close a dead entry
  and set `reconnectAt = cw_CurrTick + sb_ReconnectInterval × 10`; `sock2wldman.sb_ReconnectInterval = 0x14` (20 s in
  0.1-s ticks), `sock2gameDB` 20 s, `sock2gamelog` 600 (= 600 s) (set by the static initialisers, `dynamic_initializer_for_'sock2gameDB'` @ FUN_0069afc0 and its two
  neighbours). The second retry comes 20.0 s after the first: **confirmed**. The first retry
  comes 26–29 s after the refusal: the zone notices the closed socket only when its main loop runs, 6–9 s after its
  links connected *(inferred: map / data loading between the link handshakes and the first main-loop pass)*.
  `sb_Routine` @ FUN_005aa340 returns at the first entry not yet due, so a later entry waits for an earlier one (the
  first retries of a zone come as a pair).
- **Broadcast link = the zone's last-registered link** (§7.5.1 inference, now **confirmed**): `SetZoneSession` @
  FUN_00439190 overwrites `m_ppZoneMappingTable[zone]` on every 0x0802. Over all WM → zone broadcasts after a
  registration in both captures (0x0821, 0x0C16, 0x987A / 0x987B, 0x580D), 186 of 188 go to the link whose 0x0803 came
  last; the 2 others are 0x0821 sent in the same ms as a registration of that zone. So the broadcast link changes
  with every retry (`s37` 0x987A at 844.9 s on #34 / #35 / #39 / #41, the retried links, and at 899.9 s on #42 instead of #39: zone 2's #42 registered at 845.887).
- **0x180F**: `{numofmap, maparray[n] {canparty, mapname[12], IsPartyReleaseMap}}` (pdb2016): 107 / 88 / 255 / 196
  maps for zones 0 / 1 / 3 / 2, the same in both captures; `IsPartyReleaseMap = (canparty == 0)` (`fm_Regist2WMS` @
  FUN_00461cf0; `fc_MapRegist` @ FUN_00463a70 has no cap, the count is the zone's `FieldMap` list). canparty 0 / 1 / 2
  all occur (zone 0: 40 / 41 / 26; GuildT* maps 2 = guild-only, W02 §1.6). Every registering link sends the full list:
  `CWMZoneSessionManager::SetServiceMapZoneNo` @ FUN_004391d0 (W01's `Zones_AddMap`) updates an existing entry with all
  three values, but a **new** entry gets only `Vaild`, the name, `ZoneNo` and `CanParty`: `IsReleaseMap` stays 0 until
  the same map is registered a second time (original bug) P02-B26. The zone's second link repairs it in the same ms,
  so it shows only for a zone that registers through a single link (3 refused connects).
- **0xA419** on every registering link (17 entries, the instance-dungeon table, the same from every zone); the WM keeps
  the first only and forwards it once as 0xA41A (W04 §13.3 "Zone 0xA419" block, **confirmed**; no 0xA41F back, W04-B43).
- **0x7446** once per zone process, on the round-robin link: its one payload byte is 0x11 in all 8, the low byte of the
  preceding 0xA419's `nMapCount` (17) left at `gpp + 2` (Z30-B8 **confirmed**, its value explained). A WM restart while a
  zone runs gets no new 0x7446 from that zone (the guard is never reset) *(inferred from the code: not captured, the
  zones restarted with the WM in `s37`)*.
- **0xBCD5 / 0xBCD6** (Z06 §5 `smjpr_RankingReq`; D03 §11 0xBCD5 block): `{3, {0, 10}, {1, 100}, {2, 500}}` = `BetUnits` from
  `smsm_BettingAtOnce`; three answers `{Machine, 0x2940, 0, 0}` (8 bytes each, **confirmed**; with no ranks D03-B22's
  trailing bytes cannot show). The decoder now reads PDB element types named `Outer::<unnamed-type-…>` (0x180F, 0xBCD5).
- **0x207D** from zone 1 at both starts (`cScriptMsg_World` @ FUN_005eb970 from a map / NPC script at load; the
  string `E_Olympic_A04` is in `9Data/Shine/LuaScript/AIScript/E_Ski_CongressNPC.lua`): `sScriptMsgIndex` is a 32-byte
  copy from the Lua string, so 18 heap bytes follow the terminator, different per start (`ee 1b c7 e7 7a 04 …` /
  `e0 03 77 c3 00 a1 …`): Z09-B72 **confirmed**.
- **0x0821** carries the WM's local time (`tm` 2026-11-15 17:16:16, wday 0, yday 318); the zone's handler sets the
  machine clock from it (Z01 §9). One zone start sends 20 (8 registrations × the zones registered so far: 1, 1, 2, 2,
  3, 3, 4, 4); zone 0's broadcast link gets 7 of them, in both captures.

### 17.5 Message order against the documents

| Flow | Documents | Captured | Status |
|---|---|---|---|
| WM link connect order | W05 §1.3 (`ProcessLink`) | AccountLog, Account, Char, GameLog, Login within 3 ms | confirmed |
| WM stop | W05 §1.2 `ProcessStop` | Login, AccountDB, AccountLogDB, CharDB, GameLog FINs in 2 ms; zones had stopped first | confirmed |
| CharDB start-up load | W03 §9.1, §6.1, §8.4 | states 5 → 0x15 in order, one request per answer | confirmed |
| end of the load | W05 §1.3 ("the last answer 0x9806 sets state 1") | 0x9804 with `dAggregationDate 0` ends it | **corrected** (§13) |
| zone link set | Z01 §3.3, Z09 §1.5, §7.5.1 | 4 CharDB, 4 GameLog, 4 WM per zone; 2 WM links refused per start (P02-B25) | confirmed + **extended** |
| per-link registration | Z01 §3.3 (0x0803 → 0x180F, 0xA419, 0x7446) | 0x180F + 0xA419 on every link; 0x7446 once per process | **extended** (the call is per 0x0803, the guard `gz_IsSendReq` is Z30's) |
| WM on 0x0802 | W05 §5.2 | 0x0803, then 0x0821 to every registered zone; no 0x086A (no standing NPC) | confirmed |
| 0xA419 → 0xA41A | W04 (0xA419 block) | once per WM start, after the first zone's 0xA419, 32 ms later | confirmed |
| broadcast link | §7.5.1 *(inferred)* | the last-registered link, 186 / 188 | confirmed (settles the §15 row) |
| reconnect delay | Z09 §1.5 (`pool.reconnectSeconds`) | 20.0 s on the WM pool | confirmed (value added) |

### 17.6 Why the first WM start ended

Both WM ends are `ProcessStop` (§17.1: the FIN order is its close order). The first start ran its whole CharDB load
and stopped 1.09 s after 0x9804, before any zone or client connected; the second start sent the same bytes up to
0x9804 and ran on. In the code two things end the WM right after the load: a failed `Listen_Zone` / `Listen_Client`
(`ProcessLink` @ FUN_00404bf0 sets `m_bStopMainThread`, W05 §1.3; `CSocket_Acceptor::Listen_Add` @ FUN_00463a50
fails when the accept thread cannot `bind` / `listen`) and a stop of the service or console by the operator (the notes
step "ServerInfo capacity set to 1, WM started" suggests a restart). `InitSessions` cannot fail (FUN_00437fd0 returns
1). The wire does not tell which; the WM log of 729–731 s ("*FAILED LISTEN ADD, IP=%s:%d, From=%s*" or the
`ViewStopInfo` stop time) would (§14).

### 17.7 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| listener → connector | 0x0801 | NC_MISC_S2SCONNECTION_RDY | 106 | 0 | confirmed | on accept; never on a refused WM link |
| connector → listener | 0x0802 | NC_MISC_S2SCONNECTION_REQ | 106 | 7 | confirmed (Z01-B2) | ids and key §17.2; zone `echo_data` unwritten |
| listener → connector | 0x0803 | NC_MISC_S2SCONNECTION_ACK | 106 | 3 | confirmed | echo copied, `error` 0 |
| WM→CharDB | 0x7456 | NC_GUILD_DB_ALL_REQ | 2 | 1 | **corrected** (size) | 1 unwritten byte, 0 in practice (§17.3); P02.json |
| CharDB→WM | 0x7457 | NC_GUILD_DB_ALL_ACK | 2 | 5 | confirmed | `0x0C41`, PartMask 3, 0 guilds |
| WM→CharDB | 0x7503 | NC_GUILD_EMBLEM_INFO_DB_REQ | 2 | 1 | **corrected** (size) | as 0x7456 |
| CharDB→WM | 0x7504 | NC_GUILD_EMBLEM_INFO_DB_ACK | 2 | 3 | confirmed | PartMask 2, no Error field |
| WM→CharDB | 0x74BC | NC_GUILD_DB_TOKEN_ALL_REQ | 2 | 1 | **corrected** (size) | as 0x7456 |
| CharDB→WM | 0x74BD | NC_GUILD_DB_TOKEN_ALL_ACK | 2 | 5 | confirmed | `0x0C41`, 3, 0 |
| WM→CharDB | 0x7485 | NC_GUILD_TOURNAMENT_DB_GET_REQ | 2 | 4 | confirmed | `nGTNo 0` |
| CharDB→WM | 0x7486 | NC_GUILD_TOURNAMENT_DB_GET_ACK | 2 | 204 | confirmed | `0x0D40`, nGTNo = a `time_t`, nMatchType 6 |
| WM→CharDB | 0x74F6 | NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_REQ | 2 | 4 | confirmed | nGTNo of 0x7486 |
| CharDB→WM | 0x74F7 | NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_ACK | 2 | 5 | confirmed | `0x0D50`, 3, 0 |
| WM→CharDB | 0x9801 | NC_GUILD_ACADEMY_START_DB_ALL_REQ | 2 | 1 | **corrected** (size) | as 0x7456 |
| CharDB→WM | 0x9802 | NC_GUILD_ACADEMY_START_DB_ALL_ACK | 2 | 5 | confirmed | `0x1780`, 3, 0 |
| WM→CharDB | 0x9803 | NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_REQ | 2 | 4 | confirmed | `nRoundTime 1` |
| CharDB→WM | 0x9804 | NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_ACK | 2 | 11 | confirmed | `0x18B8`; date 0 ends the load (no 0x9805) |
| WM→CharDB | 0xA41A | NC_INSTANCE_DUNGEON_RANK_REQ | 1 | 223 | confirmed (W04-B43) | once per WM start, never answered |
| Zone→WM | 0x180F | NC_MAP_REGIST_CMD | 32 | 1234–3572 | confirmed | every registering link; decoder fixed (§17.4) |
| Zone→WM | 0xA419 | NC_INSTANCE_DUNGEON_MAP_REGIST_CMD | 32 | 223 | confirmed | every registering link; WM keeps the first |
| Zone→WM | 0x7446 | NC_GUILD_ZONE_LIST_REQ | 8 | 1 | confirmed (Z30-B8) | once per process; byte 0x11 = stale 0xA419 count |
| WM→Zone | 0x7447 | NC_GUILD_ZONE_LIST_ACK | 8 | 3 | confirmed | PartMask 3, 0 guilds |
| Zone→WM / WM→Zone | 0x7495 / 0x7496 | NC_GUILD_GUILDWARSTATUS_REQ / _ACK | 8 / 8 at start | 0 / 2 | confirmed | first run of the per-minute query (§7.5.4) |
| Zone→WM | 0x207D | NC_ACT_SCRIPT_MSG_WORLD_CMD | 2 | 39 | confirmed (Z09-B72) | zone 1 at load; 18 heap bytes in the index |
| Zone→CharDB | 0xBCD5 | NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_REQ | 8 | 10 | confirmed | once per process; decoder fixed |
| CharDB→Zone | 0xBCD6 | NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_ACK | 24 | 8 | confirmed | `0x2940`, no jackpot, no ranks |
| WM→Zone | 0x0821 | NC_MISC_TIMEFROMWORLD_CMD | 40 at starts | 36 | confirmed | 20 per zone start: to every registered zone at each registration |
| WM→Zone | 0x0C16 | NC_USER_KICKOFFFROMWORLD_CMD | 12 after a start | 10 | confirmed | header all 0xFF; only on each zone's broadcast link |

The 0x0804 / 0x0805 heartbeats of the new links run as in §7.1. After this part `s37` decodes with **0 issue
packets** (was 28) and `s21d` with 2 (0x3401 / 0x3402, part 19); `pcap_decode.py --selftest` has a case for the nested
element type.

## 18. Second client in sight, batch 3 (`s14`) *(captured)*

Scenario 14 (`capture-scenarios.md` §3.14). Client A = `admin` / Test1235 (level 120 archer, admin level 100, zone
handle 8000, WM session 0), client B = `testaccountB`, which creates the mage `X14B` (`chrregnum` 8, handle 8001, WM
session 1). Both clients run on 172.16.42.231 and use zone 9210. The notes give no times, so the times below are
capture seconds. Code: Z02 §2–§5, Z09 §9.6 / §11.4, Z11 §3.1, Z01 §3.2 / §8.4, W01 §4.2, W04 §2.1, Z13 §1.6, D03 §7.1.
`s14` decodes with **0 issue packets** after this part (the 0x1110 byte was the only one, §18.7).

### 18.1 What happened

| t (s) | Event | On the wire |
|---|---|---|
| 8.9–52.4 | A logs in, map login at RouN 6443, 9850 | batch-1 burst (§5.1) |
| 82.0–92.2 | B logs in, creates X14B | 0x1401 → CharDB 0x1402 / 0x1405, AccDB 0x140D, GameLog 0x0411 / 0xC804, client 0x1406 (as in §16, `s37`) |
| 105.1–107.1 | B selects the character, tutorial popup, skip | §18.7 |
| 107.1–113.4 | B's map login at RouN 6888, 7045 | §5.1 burst, plus the mushroom house (§18.7) |
| 151.4–154.5 | B jumps 6 × out of A's sight | 6 × C 0x2024, no 0x2025 to anyone |
| 156.75 | B runs north into A's sight | 0x1C06 both ways (§18.2) |
| 183.1–209.0 | B emotes 7 ×, jumps once | §18.3 |
| 237.9–325.2 | shouts and whispers | §18.4 |
| 305.3–381.6 | A targets B; B fights Slime 5375, 3 × Magic Missile, the slime dies | §18.5 |
| 392.5–506.3 | A: `&hide`, `&show`, `&dimensio 1` (typo), `&dimension 1`, `&dimension -1` × 2, `&dimension 70000`, `&dimension 0`, `&linkto` | §18.6 |
| 549.1 | capture ends (no logout in the file) | – |

### 18.2 Entering sight, 0x1C06 and 0x1C01

- **B walks in.** At 156.753 the zone sends B `0x1C06 NC_BRIEFINFO_LOGINCHARACTER_CMD` for A, then `0x1C19` with A's
  6 abstates. A gets B's `0x1C06`, B's last move `0x201A` and B's `0x1C19` 33 ms later (156.786), from the same exchanger call (B's last `0x2019` put
  B ≈ 1 534 units from A; `MapInfo.Sight` of RouN is 1600). After that, B's moves reach A as `0x201A` (95 ×) and
  `0x2013` (16 ×). **Confirms** Z09 §9.6 (`AxialListBriefExchangerAtMove::ali_Work` @ FUN_004bdde0: appear packet
  plus abstate list, both directions) and the 1600 radius of §6.1.
- **0x1C07 not in `s14`.** No map login of this capture (B at 113.4, A at 506.4) had another player in sight, so
  `bixc_Send` (Z02 §5.2) had nothing to batch. It is in `s21` (review, part 23): at B's map login there (89.893) B gets
  `0x1C07 NC_BRIEFINFO_CHARACTER_CMD` (236 bytes, `charnum 1`, `chars[0]` = A: handle 8003, `Test2`, 6484 / 8683) and
  A's `0x1C19`, and A gets B's `0x1C06` + `0x1C19` 14 ms later (89.907, §20.4). **Confirms** Z02 §5.2 (`bixc_Send`
  batches the players already in sight of the one logging in; the others get the single `0x1C06`).
- **0x1C06 layout** (pdb2016, 0xEB = 235 bytes in all 544): `charid`, `coord` (server position), `mode` (1 / 2),
  `chrclass` 11 / 16 (= bits 2–6 of the shape byte), `Level` 120 / 1, `chartitle` {9, 3, 0} = A's `0x1049`,
  `nKQTeamType` 2 = `0x583A`, `abstatebit` with the bits of A's abstates. **Confirmed** field by field (Z02 §1).
- **0x1C01 NC_BRIEFINFO_INFORM_CMD** (18 ×, `{nMyHnd, ReceiveNetCommand, hnd}`): the client sends it when a
  `0x201A` / `0x2018` names a handle it does not know (`ReceiveNetCommand` = 0x201A or 0x2018). Every request got the
  object's appear packet (0x1C06 for players, 0x1C08 for mobs) followed by its last move, within 3–20 ms.
  **Confirms** Z02 §5.1 and C01's `GetCharByHandle` path. In both player cases (416.915 B asks for A; 493.847 A asks
  for B), the requester's `0x1C19` goes to the **other** player (A gets B's list at 416.929; B gets A's 6 abstates at
  493.861), and the requester gets no abstate list. **Confirms Z02-B3 on the wire.**

### 18.3 Moves, emotes, jumps, stance

- B only **ran** (`0x2019` 216 ×, no `0x2017`). A got B's runs as `0x201A {handle, from, to, speed 127,
  moveattr}` and B's stops as `0x2013`, so walking (`0x2018` from a player) is not in this capture. The notes'
  "sat" has no packet: B sent `0x2020 {7}` (ActionViewInfo `stand`), and no `0x2020 {6}` (sit) appears.
- **Emotes** `0x2020 {emoticonid}` 7, 9, 10, 25, 26, 23, 24 (stand, laugh, cry, Dance 2–5): every one comes back to B
  itself 6–20 ms before it reaches A, because `sp_DoEmotion` @ FUN_00458860 broadcasts with `includeSelf` 1. B never
  sent `0x2022`, so `0x2022` / `0x2023` (stop emote) are **never seen**.
- **Jump** `0x2024` (no payload): only the jump in sight (193.435) produced `0x2025 {handle 8001}`, to A only
  (`includeSelf` 0, FUN_0045a250). **Stance** `0x2008 {2}` → A `0x2009 {8001, 2}` (351.361), not echoed to B
  (FUN_00457560). **Confirms** Z02 §2.4, §2.5, §4.

### 18.4 Chat: shout and whisper

- **Shout.** B (level 1) sent `0x201E "test"` (237.918), and nobody got a `0x201F`. A (level 120) shouted twice, 36 s
  apart, and both lines went to A **and** B as `0x201F {speaker "Test1235", flag, len, content}`. **Confirms** Z02 §3.2:
  the level check fails silently (so `g_ShoutLevel` is between 1 and 119 *(inferred)*; 0x0830 is not in the capture),
  and `so_AllInMap(…, includeSelf 1)` echoes the line to the shouter. B was in A's sight both times, so the "whole map,
  also out of sight" part is not tested. The `flag` byte was 0x78, then 0x74: `smo_Shout` @ FUN_00459080 clears bit 1
  and writes bit 0 (`vt 0xef4` GM colour, 0 for A), and leaves bits 2–7 as the shared buffer `gpp` held them
  (original bug) P02-B29. The client (`On_NC_ACT_SOMEONESHOUT_CMD` @ FUN_004a0ec0) tests only bits 0 and 1.
- **Whisper.** B → WM `0x200C {receiver "Test1235", "x14 whisper B"}` (298.517). 11 ms later the WM sent A
  `0x200D {talker "X14B", flag 0x54, …}`, B `0x200F` (echo), and the sender's zone `0x6006 NC_CT_CHARTTING_CMD
  {zoneHandle 8001, charNo 8}`, all in the same ms; `0x6006` went on the zone's broadcast link W00_WM#2. A → `0x200C {receiver
  "X14B", content "X14Nobody"}` (325.162) is an ordinary whisper to B: `0x200D {talker "Test1235", flag 0x04}`,
  `0x200F`, `0x6006 {8000, 2}`. The notes' "A whispered X14Nobody" put the name in the text. So `0x200E
  NC_ACT_WHISPERFAIL_ACK` (unknown name) is **never seen**. **Confirms** W04 §2.1 (order, fields, `0x6006`). The flag's bit 0
  (`bIsGM`) is 0 for both, even for A with admin level 100: the WM's GM bit is not the zone admin level. Bits 1–7
  (0x54, 0x04) are stale stack bits as W04 §2.1 says, with no bug ID there; they are added to P02-B29.

### 18.5 Combat seen by a third player

B hit Slime 5375 next to A (351.3–358.8), then cast skill 6000 three times (366.6, 368.8, 371.1); the slime died at
381.576.

- A (bystander) got `0x2447 SWING_START` for both directions, **`0x2449 NC_BAT_SOMEONESWING_DAMAGE_CMD`** (13 bytes:
  `{attacker, defender, flag, resthp, hpchangeorder, damageindex, attacksequence}`, 14 ×, the same `damageindex` as
  the `0x2447`), **`0x244F NC_BAT_SOMEONESKILLBASH_HIT_OBJ_START_CMD {caster 8001, skill 6000, targetobj 5375, index
  1..3}`** 14–35 ms after B's own `0x244E` / `0x2435`, and the same `0x2457` blast / `0x2452` damage as B. B got none
  of the `SOMEONE` forms. **Confirms** Z03 §3 / §5 ("to sight, not o"). `0x242E` and `0x2438` (named in the scenario's
  prediction) did not occur: no other skill path was used.
- A had B targeted (305.262), so A got `0x2402` twice per change: `order 0` for B and `order 1` for B's target (A
  itself at first, then 5375, then `65535` at 348.546 when B dropped its target). This is the batch-2 pattern (§9.7)
  seen from a third player.
- The slime's drop `0x1C0A {handle 10500, itemid 3001 LowMeat}` reached B with `attr 8` and A with `attr 0` (371.582).
  At 391.549 (+20.0 s) both got it again with `attr 8`, and at 431.656 (+60.07 s) B got `0x1805 {10500}`. A, in another
  layer by then (§18.6), got no `0x1805`. **Confirms** Z09 §11.4 (owner-only time, then a re-broadcast with fresh
  pickable bits, `so_Routine` vanish, the first handle of the 10500 pool), with the times 20 s / 60 s.
- Mob chat `0x2002` from handle 5375 reached both players (sight broadcast, Z09 §8.6).

### 18.6 GM visibility: `&hide`, `&show`, `&dimension`, `&linkto`

| t (s) | A's command | A got | B got | Matches |
|---|---|---|---|---|
| 392.450 | `&hide` | `0x242A {288 STA_GMHIDEMODE, keepTime 4 200 000 000}` | `0x1805 {8000}` (16 ms) | Z11 §3.1: `so_Logout` + abstate inform (the NOEFFECT form `0x242A`) |
| 405.082 | `&show` | `0x2428 {8000, 288}` | `0x2428 {8000, 288}`, nothing else | V24: no appear broadcast. B gets the reset for a handle its client no longer knows |
| 409.232 | (B steps) | B's `0x201A` | nothing | the exchanger skips A: A is within sight of B's old position |
| 416.894 | (A steps) | – | A's `0x201A` → B `0x1C01 {8000, 0x201A}` → `0x1C06` + `0x201A` | B sees A again only after **A** moves. The notes say "after B stepped": B's own step did nothing |
| 428.574 | `&dimensio 1` | `0x2011 "Invalid command : &dimensio"` (10 ms) | nothing | Z02 §3.3 (no element took the word, admin level ≠ 0) |
| 431.166 | `&dimension 1` | – | `0x1805 {8000}` | `so_Logout` while A's `l_Main` was still 0 |
| 431.2–451.4 | (both move) | **appear + delete storm** (below) | **storm** | (original bug) P02-B27 |
| 451.474 | `&dimension -1` | nothing | **no** `0x1805` | logout broadcast filtered: A's `l_Main` 1 ≠ B's 0 |
| 456.960 | `&dimension -1` | – | `0x1805 {8000}` | `l_Main` −1 passes the "either is −1" rule of `AxialListPacketBroadcast` (Z01 §3.2) |
| 457–473 | (both move) | storm, **plus** B's ordinary `0x201A` / `0x2013` broadcasts (16 + 2) | storm | −1 = receives every layer's broadcasts |
| 473.194 | `&dimension 70000` | – | `0x1805 {8000}` | sent while A was at −1; no range check (V24) |
| 492.149 | `&dimension 0` | nothing | **no** `0x1805`, no `0x1C06` | logout filtered (70000 ≠ 0); the command does not re-enter the map (V24) |
| 493.821 | (B steps) | B's `0x201A` → A `0x1C01` → `0x1C06` + `0x201A` | only A's `0x1C19` (Z02-B3) | A sees B again; B gets **no** appear packet for A (the notes say B saw A after stepping; the wire disagrees) |
| 506.256 | `&linkto` (no argument) | `0x1809 NC_MAP_LINKSAME_CMD {mapIndex 150, x 4975, y 5825}`, then the A-side burst of §10.2 | `0x1805 {8000}` | Z11 §3.1 (`bd_FindEmptyCoord`), Z01 §7.1. 150 = MapInfo `RouN` |

**The storm (P02-B27).** `ac_Dimension` @ FUN_0041a5a0 runs `so_Logout(gm)`, then
`**(int **)(gm+0x76) = ac_Scanf(arg)`: it writes `so_layer.layer→l_Main` (`SubLayer::Layer`, pdb2016) and nothing else.
The two sight workers compare that layer in different ways:

- `so_AllOfRangeNomal` @ FUN_0054c900 picks the objects by `so_slantedlist.LayerRegistInfo.LayerRegNumberUnion`
  (the tutorial / char-number layer, which `&dimension` leaves unchanged) or `nViewType`. So the GM stays in every
  range query of its map.
- `so_DistanceSquar(obj)` @ FUN_004028f0 returns 999 999 999 when the two `l_Main` differ.

So for every server step of any mobile object within the sight range of the GM (`mm_Step` → `smo_NewObjBriefInfoChange` /
`smo_OldObjectDelete`), both workers see "out of sight": `AxialListBriefExchangerAtMove::ali_Work` @ FUN_004bdde0
sends the appear packet (`0x1C06` / `0x1C08` + the last move + `0x1C19`) both ways, and `AxialListBriefDeleteAtMove::ali_Work`
@ FUN_004bdfe0 sends `0x1C0E` both ways right after it. Captured: 136 such pairs to each player in 431–451 s, 93 in
457–473 s, 40 in 473–492 s, each pair 3 per server step. For the mobs around A: 1 995 `0x1C08`, 1 292 `0x1C0E` and
940 `0x2018` in 20 s, **374 KB to A in 20 s** against about 7 KB in the 236 s before. When A asks with `0x1C01` for such a
mob, the mob's appear packet is followed by the next delete in the same tick. The visible result is right (B never
keeps A; A never keeps B), but every object that moves near the GM costs both clients an appear + delete per step.
Plain broadcasts (`0x201A`, `0x2013`, logout `0x1805`) use `AxialListPacketBroadcast`'s `l_Main` test and are
filtered correctly: in the dimension-1 and 70000 windows no ordinary `0x201A` crossed between A and B, only the resent
last move inside each appear. With `&dimension 0` the storm stops (`l_Main` equal again).

**Corrections / extensions.** Z11 §3.1 "objects of another main layer do not see each other" *(inferred)* holds for
broadcasts only. Brief info is exchanged and deleted again on every step (P02-B27). `-1` is a wildcard for
broadcasts (the GM hears all layers) but not for `so_DistanceSquar`. The V24 predictions hold: no appear broadcast on `&show`, no range test (−1,
70000 accepted), no re-entry on `&dimension 0`.

### 18.7 New character: tutorial popup and the mushroom house

- **Tutorial popup.** `0x1001 {slot 0}` (105.099) → WM `0x1110 NC_CHAR_TUTORIAL_POPUP_REQ` 6 ms later, with **one
  byte** (0xD5): `CParserClient::fc_NC_CHAR_LOGIN_REQ` @ FUN_00422be0 calls `CSendPacket::ID(&p, 0x1110, 1, NULL)`
  (the same pattern as P02-B2) (original bug) P02-B28. W01 §4.2 says "(empty)". The client reads no payload (C01). B
  answered `0x1111 {bIsSkip 1}` after 1.34 s. The WM sent CharDB `0x1112 {nSessionHandle 1, nCreateWorldNo 0, nCharNo 8,
  nUserNo 104, bIsSkip 1}` (4 ms), and CharDB answered `0x1113 {1, 8, rErrorType 0x31E8, bIsSkip 1}` (25 ms). 6 ms
  later the WM sent `0x1004`, so `TutorialLoginProcess` follows the normal 0x1001 path (W01 §6.2). No `0x111D` was sent (skip = 1). The
  character blob then carried `0x1114 {nTutorialState 2, nTutorialStep 0}`, and the zone got `0x1115` with the same
  values. **Confirms** W01 §4.2 / §6.2 and D02 §8 (0x1112 / 0x1113 layout). `0x1003` reached the client at 107.092,
  1.99 s after `0x1001` (most of it the popup wait).
- **Mushroom house.** On B's first `0x1803` (113.352), the zone sent CharDB `0x3467 NC_ITEMDB_CREATEMUSHROOM_REQ` on
  W00_CDB#5 in the same ms as the §10.2 requests. Layout (first annotation, `annotations/P02.json`): `{ref, lockindex 0,
  owner 8, MAPPOS {RouN, 6888, 7045}, location 0x3000, key, itemid 31000 House_MushRoom, attr 0x002E, attributes[4] = 0}`.
  The u16 before the attributes is the constant 46, the payload offset of the attribute block
  (`sp_MakeMiniHouse` @ FUN_0043eab0 writes `end − start − 2`), not a length (Z13 §1.6 calls it `attrLen`). Then
  `0x3468 {ref, lockindex}` came back (34 ms), the Character server logged GameLog `0x044F {8, 8, key, 31000, 0x3000}`
  on W00_GLDB#1, and the client got `0x3001 NC_ITEM_CELLCHANGE_CMD {0x3000, 0x3000, 31000, attributes 0}` (13 ms).
  At the next per-minute block (WM `0x0821`, 121.398), the zone wrote the house's attribute with ItemDB `0x3449
  {lockindex 1, key, 31000, attribute ffecbb76}` → `0x344A {err 0x0901}`. At the same time the client got
  `0x9010 NC_CHARGED_BOOTHSLOTSIZE_CMD {size 5}` (it was 0 at the map login) and a second `0x3001` with the new
  attribute. **Confirms** Z13 §1.6, Z05 §9.5, D03 §7.1. A, who already owns 31000, got `0x9010 {5}` in its login burst.
- **0x750C NC_GUILD_EMBLEM_LEVELUP_CMD {nCharNo 2}**, zone → WM W00_WM#10, 5 ms after CharDB's `0x4002` of A's
  `&linkto` save (506.357 → 506.362). **Confirms** Z01 §8.4 (level ≥ 60 → `0x750C`) and W03 §3.11 (the WM handler).

### 18.8 Opcodes

Batch 1–2 opcodes recur unchanged (create: §16.4; map login and in-world: §5.2, §6.2, §8.2, §9.7, §10.8). New types:

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x1C01 | NC_BRIEFINFO_INFORM_CMD | 18 | 6 | confirmed | §18.2; Z02-B3 captured |
| S→C | 0x1C06 | NC_BRIEFINFO_LOGINCHARACTER_CMD | 544 | 235 | confirmed | 2 by sight, 2 on request, 540 in the P02-B27 storm |
| S→C | 0x1C07 | NC_BRIEFINFO_CHARACTER_CMD | 0 (`s21` 1) | 236 | confirmed (`s21`) | none in `s14` (no player in sight at a map login); `s21` 89.893 at B's map login, `charnum 1` = A (§18.2, §20.4) |
| C→S / S→C | 0x2024 / 0x2025 | NC_ACT_JUMP_CMD / NC_ACT_SOMEEONEJUMP_CMD | 7 / 1 | 0 / 2 | confirmed | not to the jumper |
| C→S / S→C | 0x2020 / 0x2021 | NC_ACT_EMOTICON_CMD / NC_ACT_SOMEONEEMOTICON_CMD | 7 / 14 | 1 / 3 | confirmed | also to the sender |
| C→S / S→C | 0x2022 / 0x2023 | NC_ACT_EMOTICONSTOP_CMD / …SOMEONEEMOTICONSTOP_CMD | 0 | – | never seen | no emote stop |
| S→C | 0x2009 | NC_ACT_SOMEONECHANGEMODE_CMD | 1 | 3 | confirmed | `{8001, 2}`, not to the sender |
| C→S | 0x201E | NC_ACT_SHOUT_CMD | 3 | 6–13 | confirmed | level-1 shout dropped silently |
| S→C | 0x201F | NC_ACT_SOMEONESHOUT_CMD | 4 | 28 / 34 | **corrected** (flag) | bits 2–7 stale (P02-B29); also to the shouter |
| C→WM | 0x200C | NC_ACT_WHISPER_REQ | 2 | 31 / 35 | confirmed | §18.4 |
| WM→C | 0x200D | NC_ACT_SOMEONEWHISPER_CMD | 2 | 32 / 36 | confirmed | flag bit 0 = 0 for the admin too |
| WM→C | 0x200F | NC_ACT_WHISPERSUCCESS_ACK | 2 | 31 / 35 | confirmed | same ms as 0x200D |
| WM→C | 0x200E | NC_ACT_WHISPERFAIL_ACK | 0 | – | never seen | the "unknown name" step named an online player |
| WM→Zone | 0x6006 | NC_CT_CHARTTING_CMD | 2 | 6 | confirmed | sender's zone handle / charNo, broadcast link |
| S→C | 0x2449 | NC_BAT_SOMEONESWING_DAMAGE_CMD | 14 | 13 | confirmed | bystander form, both directions |
| S→C | 0x244F | NC_BAT_SOMEONESKILLBASH_HIT_OBJ_START_CMD | 3 | 8 | confirmed | bystander form of 0x244E |
| S→C | 0x1809 | NC_MAP_LINKSAME_CMD | 1 | 10 | confirmed | `{150, 4975, 5825}` |
| WM→C | 0x1110 | NC_CHAR_TUTORIAL_POPUP_REQ | 1 | 1 | **corrected** (size) | 1 unwritten byte (P02-B28); was the capture's only decoder issue |
| C→WM | 0x1111 | NC_CHAR_TUTORIAL_POPUP_ACK | 1 | 1 | confirmed | `bIsSkip 1` |
| WM→CharDB | 0x1112 | NC_CHAR_TUTORIAL_MAKE_ITEM_REQ | 1 | 12 | confirmed | D02 §8 |
| CharDB→WM | 0x1113 | NC_CHAR_TUTORIAL_MAKE_ITEM_ACK | 1 | 9 | confirmed | `0x31E8` ok |
| Zone→CharDB | 0x3467 | NC_ITEMDB_CREATEMUSHROOM_REQ | 1 | 50 | confirmed, **first layout** | `attr` = constant offset 46 (§18.7) |
| CharDB→Zone | 0x3468 | NC_ITEMDB_CREATEMUSHROOMSUC_ACK | 1 | 8 | confirmed, **first layout** | `{ref, lockindex}` |
| Character→GameLog | 0x044F | NC_LOG_GAME_ITEM_CREATE | 1 | 20 | confirmed | D03 §7.1 |
| Zone→WM | 0x750C | NC_GUILD_EMBLEM_LEVELUP_CMD | 1 | 4 | confirmed | after 0x4002, level 120 |
| WM→CharDB, CharDB→WM, WM→AccountDB, WM→GameLog | 0x1402, 0x1405, 0x140D, 0x0411, 0xC804 | (character create) | 1 each | 33, 133, 50, 4, 9 | confirmed | as in §16.4 (`s37`); 0x140D +0x1E..+0x30 again stale (P02-B24), partly other values (`… 00 70 9e … 00 72 00 …`) |

The 0x1C08 / 0x1C0E / 0x2018 counts of this capture (3 255 / 2 736 / 2 072) are mostly the P02-B27 storm (§18.6).

## 19. Items I, batch 3: GM items, split, drop, pick-up, destroy, use, full inventory (`s21`) *(captured)*

`s21` steps 1–7 and 11 (the storage, shop and soul-stone steps 8–10 are §20). Streams: client A = zone#1 / wm#1
(`admin`, **Test2**, `chrregnum` 5, zone handle 8003), client B = zone#2 / wm#2 (`testaccountB`, X14B, `chrregnum` 8,
handle 8004), both on RouN (zone 0, 9210). The zone's CharDB links are W00_CDB#1 / #2 / #3 / #17 (requests go round
robin), its GameLog link W00_GLDB#1. Times are capture seconds (the notes have no times). Decoder: 56 `0x3401`, 1
`0x341F`, 2 `0x343E`, 1 `0x346A`, 1 `0x3439` issue packets before this part; the P02.json layouts of §19.8 fit all
of them (`s21` now has 18 issue packets, all §20 types).

### 19.1 What happened

| Time | Step | Client request | Wire result |
|---|---|---|---|
| 130.6–190.5 | setup (`21-setup.txt`) | `&cleariv`, `&levelup 25`, `&getmoney 200000`, `&fullpoint`, 9 × `&makeitem` | §19.2 |
| 289.6, 291.5, 454.6, 620.3 | (not in the notes) | 0x3015 HP potion at full HP | 0x3016 `0x713` at once (§19.6) |
| 299.4 / 301.0 | 1 split / merge | 0x300D 4 → cell 9; 0x300B cell 9 → cell 0 | 0x3434 → 0x3435, 0x300E `0x441`; 0x342E → 0x342F, 0x300C `0x241` (§19.3) |
| 382.4, 389.5, 451.2 | 1 split onto the x3 stack ("did not work") | 0x300D 4 / 4 / 9 → cell 1 (occupied) | 0x300E `0x446`, no DB request |
| 447.1 | (not in the notes) | 0x3007 lot 9 of the 10-stack | 0x3008 `0x303` (Z04-B4) |
| 456.5 / 458.0 | 1 "split the whole lot" | 0x300D 9 → cell 9; 0x300B back | as at 299.4 (client range 1…9: "split 0" never reaches the server) |
| 477.1 / 479.3 | 2 drop / pick up the x3 stack | 0x3007 lot 3; 0x3C02 OK; 0x3009 | §19.4: DROPALL, then PICKMERGE onto cell 0 (lot 13) |
| 512.9 / 541.0 | 3 A drops Leather Boots, B picks | 0x3007 cell 5; B's 0x3009 at 541.0 only | §19.4: B's first try (notes) sent nothing |
| 601.3 / 604.8 | 4 destroy Binding Reset Resin | 0x3007 cell 6, two 0x3C02 OK | §19.5: 0x346A ITEMBREAK |
| 746.6 / 790.8 | 5 use potions | 0x3015 cell 0 (lot 13), cell 2 (lot 1) | §19.6: USELOT / USEALL |
| 805.7 / 810.8 | 6 rings | 0x300F cell 3, cell 4 | 0x3410 → equipment slots 15, 16 (§19.7) |
| 1324.2 / 1339.6 | 11 KQ pick-up limit | drop one Freezing Ice, pick it up | §19.4: free at once; 0x300A `0x34A` |
| 1356.4–1410.7 | 7 full inventory | 49 × `&makeitem LeatherBoots` | 46 × 0x3401 (cells 1–7, 9–47), 3 without a packet (§19.2) |
| 1470.5 | 7 unequip a ring, inventory full | 0x3012 `{15, 48}` | 0x3013 `0x2C2` (§19.7) |
| 1481.6 / 1485.2 / 1486.4 | 7 drop one, `&makeitem` refills the cell, pick | 0x3007, chat, 0x3009 | 0x300A `0x346` "Inventory is full." |
| 1498.2–1507.4 | 7 clean-up | `&cleariv` (48 keys), 2 × 0x3012, `&cleariv` (2), 2 × 0x3009, `&cleariv` (2) | §19.2, §19.4 |

### 19.2 The GM setup on the links (`&makeitem`, `&getmoney`, `&cleariv`)

- **`&makeitem`** (Z11 §4.3): `0x3401 NC_ITEMDB_ADMINCREATE_REQ` 2–24 ms after the chat line, `0x3402` 8–32 ms later,
  GameLog `0x044F {itemmaker = owner = 5, key, itemid, cell}` in the same ms as the `0x3402`, then the client's
  `0x3001` for the cell (style 1: the item appears only after the DB answer, Z05 §9.1). The cell is the first free
  one in slot order (0x2400…0x2408 in the setup; after the drops of step 7 the refilled cell 23). Layout:
  `{ref, u16 lockindex, PROTO_ITEM_CREATE create, attribute}` (the pdb2016 struct + the 6-byte ref; `create.attr` =
  46, the payload offset of the attribute, as for 0x3467 in §18.7). Attributes: 1 byte (lot 10 / 3 / 1 for HP Potion
  3500 `-l10` / `-l3` / `-l1`, KQ_Ice01 57001, PutOn_ClearKit01 2530 `-l1`), 13 bytes for LeatherBoots (item id 0,
  `ShineItemAttr_Boot`), 41 bytes for SkullRing 2203 (the two rings differ in the last two bytes: `00 01` / `01 02`,
  the random option roll of Z11 §4.3 *(inferred)*).
- `&makeitem` with a full inventory sends nothing and the GM gets no message: 3 of the 49 step-7 commands (1409.695,
  1410.214, 1410.719) have no `0x3401`. **Z11-B12 captured.** The notes' "cells filled 46, no failure message" agree.
- **Lock indices** (Z05 §1.2) count every transaction of the character, the GM commands included: `&cleariv` 0,
  `&makeitem` 1–9, split 10, merge 11, split 12, merge 13, break 17, uses 18 / 19, equips 20 / 21, … `&makeitem`
  43–88, 90, `&cleariv` 91, unequips 92 / 93, `&cleariv` 94 / 95. Between 13 and 17 lie a drop, a pick-merge, a drop
  and the destroy menu, which carry no index on the wire; which of them took the three indices was not traced.
- **`&getmoney 200000`** (Z11 §7.4): `0x3438 {owner 5, itemonfield −1, cen 200000}` and `0x1033 {cen 299378}` in the
  same ms, `0x3439` 23 ms later, GameLog `0x0446 {"Need Cen", 0, 0, key 0, itemlot 3392 = (u16) 200000, …}`, then
  the client's `0x300A {itemid 0, lot 0, 0x341, 0xFFFF}`: **Z11-B32 captured**, and its open point settled: with
  nothing picked since the map login the item id and lot are 0, so the client prints the obtained message for item 0
  (LeatherBoots) *(the text not seen; the notes do not mention it)*. `0x3439` is 7 bytes: the ref and one byte the
  Character server never writes (`0x10`): **D03-B6 captured**.
- **`&cleariv`** (Z11 §4.3, Z18 §4.4): `0x3459 NC_ITEMDB_DESTROY_REQ` with `flags` = key count (3, 48, 2, 2; bit 7
  clear), the keys at payload 0x17, `0x345A {lockindex, err 0xB81}` 2–60 ms later, then one `0x3001` (6 bytes,
  `itemid 0xFFFF`) per cell in slot order in the same ms (Z05 §6.4). No GameLog row. Payload bytes 9…22 (`itemID`,
  `key`, `attrOffset`, `inven`, valid only with bit 7) are not written: they hold earlier `gpp` contents, readable
  text included (`…n u s`, `…r e s`, `…n   b`) (original bug) P02-B30. Z11 §4.3 says "stale, unread"; the Character
  server indeed reads them only with bit 7 (Z18 §4.4).

### 19.3 Split and merge

- **Split** (Z04 §4.2): `0x3434` 10–17 ms after the request (68 bytes: D03 layout), `0x3435 {ref, lockindex, lotmain,
  RemainLot 6 / 1}` 33–53 ms later, GameLog `0x0457 {charNo, RouN 6481 8752, itemid, key, new key, 4 / 9, 6 / 1}` in the same
  ms (the split log carries the real map, unlike the drop and merge logs), then `0x3001` source (new lot, `exchange`
  = itself), `0x3001` target (`exchange` = the source cell) and `0x300E {0x441}`: style 1, confirms Z05 §4. Z04
  §4.2's "+0x42 u32 lot, +0x44 u16 oldLot, 0x46 bytes" is off by two: `splitlot` u16 at payload 64, `MainLot` (the lot before the split, 10) at 66,
  68 bytes. `lotcreate.attr` (payload 62) is not written (`0x6874` / `0x6620`, text bytes; no attribute follows)
  (original bug) P02-B30.
- **Split onto an occupied cell** answers `0x300E {0x446}` without a DB request (3 ×). The code (zone 0x53a03f…0x53a052):
  `to` cell item ≠ 0xFFFF → `so_SendErrorCode(12, 14, 0x446)`; an out-of-range `from` or `to` cell both answer
  `0x445` (shared label at 0x539f25). Z04 §4.2 gives these as "to cell not empty: 0x44c" and "Invalid 'to' cell:
  0x446": **corrected**. The client shows nothing for 0x446 (only `0x447` has a text, Z04 §4.2); the notes'
  "did not work" is the cell not changing.
- **Merge = 0x300B onto a stack of the same item** (Z04 §4.1): `0x342E NC_ITEMDB_MERGE_REQ {ownerA, ownerB, lockindex,
  itemid, lotmain = target key, lotsub = source key, nMainLot 6 / 1, nSubLot 4 / 9}`, `0x342F {ref, lockindex,
  lotmain, MergeResultLot 10}`, GameLog `0x0456 {"Need", 0, 0, itemid, main key, sub key, itemlot 4 / 9 = sub lot,
  itemlotadd 10 = result, itemlotsub 0}` (D03 §3.3, D03-B11), then `0x3001` source emptied, `0x3001` target 10,
  `0x300C {0x241}` (a RELOC_ACK, as Z05 §4 says).

### 19.4 Drop, pick-up and the looting time

- **Drop of a whole stack / item** (Z04 §3.1, Z05 §3.1): `0x3C01` "Do you want to discard the item?" (menu
  `ItemDropWarn`, 208 bytes, `npcHandle 0xFFFF`, position = A's) and `0x3008 {0x301}` in the same ms; after the OK
  (`0x3C02 reply 0`, 1.0–5.0 s later) `0x3416 DROPALL_REQ` and `0x3001` (cell emptied) in the same ms (style 2),
  `0x3417` 11–16 ms later, GameLog `0x0447 {"Need", 0, 0, key, itemlot 0, cell, itemid}` (D03-B11), `0x1C0A` to the
  others in sight first (`attr 0` for B), then to A (`attr 8`) with the second `0x3008 {0x301}`. Two `0x301` per
  drop: the menu ACK and the DB answer (Z05 §3.1) both send it. `0x3416` / `0x3417` carry the 101-byte attribute
  union of the cell: a ByteLot item writes its lot byte, the other 100 bytes are heap contents (pointer-like
  values, `ffff`, …), echoed unchanged in `0x3417` (original bug) P02-B30.
- **Part stack**: `0x3007 lot 9` on the 10-stack → `0x3008 {0x303}` at once, no menu: **Z04-B4 captured** (only whole
  stacks drop; `DropLot` / `0x3419` unreachable). The client shows no text for 0x303.
- **Pick-up onto a stack** (Z04 §3.3 IsLot): `0x341F NC_ITEMDB_PICKMERGE_REQ` (33 bytes: ref + pdb2016 struct +
  attribute; `itemonfield` = the drop's key, `nCellItemLot 10`, `itempick` = cell 0's key, `attr` = offset 32,
  attribute = lot 13), `0x3001 {cell 0, lot 13}` and `0x3014` to B in the same ms, `0x3420 {ref}` 6 ms later, no
  GameLog row, `0x300A {3500, lot 3, 0x341}` 43 ms after it. No new key: the drop's key disappears (the DB deletes it,
  D03 §3.4).
- **`0x3014 NC_ITEM_SOMEONEPICK_CMD`** (26 bytes `{char pickerID[20], u16 itemID, u32 nItemLot}`, first capture): sent to
  the other players in sight (B for A's three picks, A for B's) together with the picker's `0x3001`, not to the
  picker. The client (`FUN_004abc20`) prints "%s of the expedition group has received an item." only when the picker
  is in its expedition (raid) list *(inferred from the lookup FUN_006f7e30)*: here nothing.
- **Ownership** (Z09 §11.4, §18.5): LeatherBoots (`ItemInfoServer.looting` 20000, `Vanish` 60000) dropped at 514.0,
  re-broadcast with `attr 8` to both at 533.954 (+19.95 s). B's first try (notes: "You do not have the right to pick up
  the item.") produced **no 0x3009**: the client refuses by itself while the drop's pick bit is 0 *(inferred: the
  client's drop object FUN_00610fc0 was not read)*. B's 0x3009 at 541.0 → `0x341C PICKALL` (map / x / y = B's
  position, `location` = B's first free cell 0x2401), B's `0x3001` + A's `0x3014` in the same ms, `0x341D`, GameLog
  `0x0446` (`iteminven 0` here, `0x750F` for A's later picks: P02-B15), `0x300A {0, 1, 0x341}`. The notes' "~30 s" is
  the tester's wait; the server allowed it after 20 s. The step-7 Boots (dropped 1484.2) turned free at 1504.149 (+19.9 s).
- **Looting time 0**: KQ_Ice01 57001 has `looting 0`, `Vanish 300000`: its drop (1329.244) went to B as `attr 0` and
  at once again as `attr 8`, and to A twice with `attr 8`, all in the same ms: the owner time is already over at the
  first `so_Routine` pass, which re-broadcasts (Z09 §11.4) *(the routine call itself not timed)*.
- **KQ pick-up limit** (X02 §4, Z04 §3.3 `ItemLotInspector`): picking up the second Freezing Ice while holding one →
  `0x300A {0xFFFF, 0, 0x34A, 0xFFFF}` 11 ms after the request, no DB request, the drop stays; client "Failed to
  obtain the item." (notes). **Confirms** the X02 reading of 0x34A (KQItem.shn `PickupLimit`).
- **Full inventory**: `0x3009` → `0x300A {0xFFFF, 0, 0x346, 0xFFFF}` 15 ms later, client "Inventory is full.":
  **settles** Z04 §3.3's *(inferred)* code: it is 0x346. After `&cleariv` the two picks went to cells 0 / 1 as
  `0x341C` PICKALL (`0x3014` to B each time).

### 19.5 Destroying an undroppable item (Binding Reset Resin)

`0x3007` on PutOn_ClearKit01 2530 (bound: `BelongType_CanDrop` false, Z04 §3.1) opens `0x3C01` "If you discard this
item, it will automatically be destroyed." (`ItemBreakWarn0`) with `0x3008 {0x301}`; the OK (1.4 s) opens the
second `0x3C01` "Do you want to destory the selected item?" (`ItemBreakWarn1`, the client text's spelling) 26 ms
later; the second OK (2.1 s) sends `0x346A NC_ITEMDB_ITEMBREAK_REQ {packheader, lockindex 17, key, Owner 5, nID 2530,
nLot 1, nDeleteChestItem 0}` (25 bytes, pdb2016 layout; the decoder read one element of the `[0]` array until
P02.json restated it), `0x346B {ref, 17}` 13 ms later, GameLog `0x0445 {5, key, 2530, 1}` and, 1 ms after the `0x346B`, the client's
`0x3001` (cell 6 emptied) and **`0x3024 NC_ITEM_BREAKSUCCESS_CMD`** (empty, *(pdb2017)* name) together. **Confirms**
Z04 §3.2 (two confirmations, style 1) and Z05 §6.4; the client has no 0x3024 handler and shows nothing.

### 19.6 Using potions

- **Full HP**: four 0x3015 on HP Potion 3500 (`ItemUseSkill` UsePotion, `UseItemByTable` actor) answer `0x3016
  {0x713, 3500, 9}` 2–9 ms later, no DB request, client "The selected item does not have any effect when used.".
  Code: `UseEffect::UseItemByTable::uib_CanUseItem` @ FUN_005981e0 returns 0x700 only when one of the row's three
  effects (`sp_CanUseItemCheck_ByTable` for UseEffectA / B / C) would change something, else 0x713. The notes' step
  10 "HP stone at full HP → no message" is the soul-stone path (§20).
- **Stack (lot 13)** at HP 632 (`&staticdamage 1`): `0x343E NC_ITEMDB_USELOT_REQ` and **`0x301A
  NC_ITEM_USECOMPLETE_CMD`** (empty) in the same ms, 34 ms after the request (the UsePotion cast; Z13 §8
  `smo_ply_ItemUse` sends 0x301A before `uib_AfterCast`), GameLog `0x0459 {5, key, 3500, itemlot 12 = new lot}` and
  `0x3440 {ref, 18, 0x700}` 19 ms later, then `0x3016 {0x700, 3500, 9}`, `0x3001 {cell 0, lot 12}` and `0x240E {hp
  633}` together (the heal runs in the releaser after the DB answer, Z05 §6.1). Layout: ref + pdb2016 `{PROTO_CHANGEATTR
  {key, itemid, attr}, lockindex}` + the attribute (lot 12); `attr` = 20 = the payload offset of the attribute: Z04
  §6.3's "+0x12 attrLen" is an offset (as for 0x340A in §7.6.1): **corrected**.
- **Single potion (lot 1)**: `0x343F NC_ITEMDB_USEALL_REQ {ref, key, lock 19, itemid}` with `0x301A`, GameLog `0x045A
  {5, key, 3500}`, `0x3440 {19, 0x700}`, then `0x3016`, `0x3001` (cell 2 emptied), `0x240E`. **Confirms** Z04 §6.3
  (lot 1 → USEALL) and D03 §4.

### 19.7 Rings, unequip with a full inventory

- `0x300F` on SkullRing 2203 (`ItemInfo.Equip` 15) in cell 3 → `0x3410 {relocA = ring → 0x200F, relocB.key −1}`
  (empty slot), `0x3411`, then `0x3002 {exchange 0x2403, location 15, ring}` (46 bytes), `0x3001 {exchange 0x200F,
  cell 3 emptied}`, `0x3011 {0x281}`. The second ring went to slot 16 (`0x2010`) although the 1-byte 0x300F names only the
  inventory cell: the zone chose the free ring slot (`EquipEnumChanger_eec_EquipLocation` with the current equipment, Z04 §5.1). The notes call the
  first one "right". B (in sight) got **nothing** for the two equips but `0x1C04 NC_BRIEFINFO_UNEQUIP_CMD {8003, 16}` /
  `{8003, 15}` for the two unequips at 1499.6 / 1500.1: SkullRing is class 4 (amulet), whose `iac_equipbriefinfo`
  returns 0, while an unequip builds the brief info of the empty item (base class → 0x1C04). **Confirms** Z18 §4.3.
- **Unequip with a full inventory**: the client sends `0x3012 {slotequip 15, slotinven 48}` (48 = one past the 48-cell
  inventory, its "no free cell" value *(inferred)*); the zone answers `0x3013 NC_ITEM_UNEQUIP_ACK {0x2C2}` at once
  (`slotinven ≥ usable size`, Z04 §5.4), client "Failed to unequip the item.". **First 0x3013 on the wire** (§8.2 had it
  "never seen": a success answers 0x3011, Z05-B2; both unequips at 1499.6 / 1500.1 again got `0x3011 {0x281}`).
  The two later unequips name the free cells 0 / 1 and go through `0x3413` / `0x3414` (style 1, `0x3002` 5 bytes
  first).

### 19.8 SQL snapshots

`26_11_15_21_items-snapshot-before.txt` / `-after.txt` (and `-prep.txt`) list **Test1235** (`nCharNo` 2, `nUserNo`
103), not Test2 (`nCharNo` 5) whom the scenario played; both snapshots are identical except `taken_at` (18:02:25 /
18:43:42). They cannot check D03 against `s21`. The committed `tools/capture/21/21-snapshot.sql` already selects
`N'Test2'`, so the run used an older copy of the script *(inferred)*. The account storage rows (`nStorageType` 6,
owner 103) did not change either: the storage step (§20) moved only potions and cen of Test2 (net zero).

### 19.9 Opcodes

Types new in batch 3 (batch 1–2 types recur unchanged: §8.2, §7.6.1; `0x3001` sizes 6 / 7 / 19 boots / 47 ring):

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x3007 | NC_ITEM_DROP_REQ | 6 | 14 | confirmed | Z04 §3.1 |
| S→C | 0x3008 | NC_ITEM_DROP_ACK | 10 | 2 | confirmed | `0x301` ×2 per drop, ×1 per destroy; `0x303` part stack (Z04-B4) |
| C→S | 0x300D | NC_ITEM_SPLIT_REQ | 7 | 8 | confirmed | Z04 §4.2 |
| S→C | 0x300E | NC_ITEM_SPLIT_ACK | 7 | 2 | **corrected** | `0x441`; `0x446` = target occupied (Z04 says 0x44c) |
| S→C | 0x3013 | NC_ITEM_UNEQUIP_ACK | 1 | 2 | confirmed | first capture: `0x2C2` full inventory (§19.7) |
| S→C | 0x3014 | NC_ITEM_SOMEONEPICK_CMD | 4 | 26 | confirmed | pdb2016 layout; to the others in sight |
| S→C | 0x301A | NC_ITEM_USECOMPLETE_CMD | 3 | 0 | confirmed | with the use request to the CharDB (Z13 §8) |
| S→C | 0x3024 | NC_ITEM_BREAKSUCCESS_CMD | 1 | 0 | confirmed; **new layout** | *(pdb2017)* name; P02.json (empty) |
| Z→CDB | 0x3401 | NC_ITEMDB_ADMINCREATE_REQ | 56 | 47 / 59 / 87 | **corrected** | pdb2016 struct + ref + attribute tail (P02.json) |
| CDB→Z | 0x3402 | NC_ITEMDB_ADMINCREATESUC_ACK | 56 | 8 | **corrected** | `{ref, lockindex}` (P02.json) |
| Z→CDB | 0x3416 | NC_ITEMDB_DROPALL_REQ | 4 | 129 | confirmed; **bug** | D03 layout; 100 heap bytes in the attribute (P02-B30) |
| CDB→Z | 0x3417 | NC_ITEMDB_DROPALLSUC_ACK | 4 | 117 | confirmed | Z05 §3.1; echo of the item |
| Z→CDB | 0x341F | NC_ITEMDB_PICKMERGE_REQ | 1 | 33 | **corrected** | ref + pdb2016 + attribute (P02.json) |
| CDB→Z | 0x3420 | NC_ITEMDB_PICKMERGESUC_ACK | 1 | 6 | confirmed; **new layout** | `{ref}` (P02.json) |
| Z→CDB | 0x342E | NC_ITEMDB_MERGE_REQ | 2 | 42 | confirmed | D03 §3.3 |
| CDB→Z | 0x342F | NC_ITEMDB_MERGESUC_ACK | 2 | 18 | confirmed | Z05 §4 |
| Z→CDB | 0x3434 | NC_ITEMDB_SPLIT_REQ | 4 | 68 | confirmed; **bug** | D03 layout; `lotcreate.attr` unwritten (P02-B30); Z04 offsets off by 2 |
| CDB→Z | 0x3435 | NC_ITEMDB_SPLITSUC_ACK | 4 | 18 | confirmed | Z05 §4 |
| Z→CDB | 0x3438 | NC_ITEMDB_PICKMONEY_REQ | 1 | 22 | confirmed | Z11 §7.4 |
| CDB→Z | 0x3439 | NC_ITEMDB_PICKMONEYSUC_ACK | 1 | 7 | **corrected**; **bug** | ref + 1 unwritten byte (D03-B6); pdb2017 empty |
| Z→CDB | 0x343E | NC_ITEMDB_USELOT_REQ | 2 | 21 | **corrected** | ref + pdb2016 + attribute; `attr` = offset (P02.json) |
| Z→CDB | 0x343F | NC_ITEMDB_USEALL_REQ | 1 | 18 | confirmed | Z04 §6.3 |
| CDB→Z | 0x3440 | NC_ITEMDB_USE_ACK | 3 | 10 | confirmed | `0x700` |
| Z→CDB | 0x3459 | NC_ITEMDB_DESTROY_REQ | 4 | 47 / 407 / 39 / 39 | confirmed; **bug** | Z18 §4.4 layout; 14 unwritten bytes (P02-B30) |
| CDB→Z | 0x345A | NC_ITEMDB_DESTROY_ACK | 4 | 10 | confirmed | `err 0xB81` |
| Z→CDB | 0x346A | NC_ITEMDB_ITEMBREAK_REQ | 1 | 25 | confirmed | pdb2016; restated for the decoder (P02.json) |
| CDB→Z | 0x346B | NC_ITEMDB_ITEMBREAKSUC_ACK | 1 | 8 | confirmed | Z05 §6.4 |
| CDB→GL | 0x0445 | NC_LOG_GAME_ITEM_BREAK | 1 | 16 | confirmed | D05 / D03 §7.5 |
| CDB→GL | 0x0447 | NC_LOG_GAME_ITEM_DROP | 4 | 38 | confirmed; **bug** | "Need" (D03-B11), `itemlot 0` |
| CDB→GL | 0x0456 | NC_LOG_GAME_ITEM_MERGE | 2 | 48 | confirmed; **bug** | "Need" (D03-B11) |
| CDB→GL | 0x0457 | NC_LOG_GAME_ITEM_SPLIT | 4 | 46 | confirmed | real map and position |
| CDB→GL | 0x0459 | NC_LOG_GAME_ITEM_USELOT | 2 | 16 | confirmed | `itemlot` = lot after |
| CDB→GL | 0x045A | NC_LOG_GAME_ITEM_USEALL | 1 | 14 | confirmed | D03 §4 |

`0x0446` (`&getmoney` row) and `0x044F` (56) match their batch-2 rows (§7.6.1, §18.8). `0x0459` has 2 rows: the
second (lock 31, lot 8) belongs to the step-9 potion use (§20).

## 20. Items II, batch 3: storage money, selling and buying back, soul stones; world traffic (`s21`) *(captured)*

`s21` steps 8–10 (storage, sell / buy back, soul stones) and the world traffic of the capture that the scenario did not
ask for (level-up announcement and titles, KQ minute ticks, a script message, B's map login seen by A). Streams as in
§19 (A = Test2, zone#1 / wm#1, handle 8003; B = X14B, zone#2 / wm#2, handle 8004; CharDB W00_CDB#1 / #2 / #3 / #17,
GameLog W00_GLDB#1). Times are capture seconds. Decoder: the 18 issue packets left by part 19 (0x34BB ×5, 0x3425 /
0x3426 ×4, 0x3441 / 0x3442 ×2, 0x6401) fit the P02.json layouts of this section; all six batch-3 captures now decode
with 0 issue packets.

### 20.1 Storage (step 8, Storage Keeper Raina)

- **Open** (as §8.1): `0x200A {17092}` (mob 108 RouStoreRaina) 843.695 → `0x201C {108}` → the client's `0x201D {1}`
  844.693 → 3 ms later 4 × `0x3444` pages 0–3, all at 844.696 on 4 links → `0x3446` pages 2 / 3 / 1 (20 bytes, empty) at 844.707 and page 0
  (126 bytes, 3 items) at 844.717 → `0x3C08` pages 1, 2, 3 at 844.713 and page 0 at 844.757: each page goes to the client
  when its DB answer arrives (batch 2: 2, 3, 0, 1).
- **Item in / out**: the HP-potion stack (cell 0, lot 12) to account-storage cell 3 (`0x300B 0x2400 → 0x1803`): `0x3428`
  `ownerA 5, ownerB 103`, lock 22, GameLog `0x044C`, `0x3429`, two `0x3001`, `0x300C {0x241}`; back at 854.766 with
  `ownerA 103, ownerB 5`, lock 23. The notes' "changed to page 2, back to page 1" sent **nothing**: the four pages are
  loaded at open, and the 2016 client never sent `0x3028 NC_ITEM_OPENSTORAGEPAGE_REQ` (Z04 §7.2) in either batch.
- **Money** (Z04 §7.1, D03 §5.1): deposit `0x301C {cen 1333}` 865.110 → `0x345F {ref, lock 24, userNo 103, cen 1333}`
  +7 ms → GameLog `0x045E {chrregnum 5, deposit_money 1333, userregnum 103, user_result_money 1333}` and `0x3460 {ref,
  lock 24, storagemoney 1333, error 0xF80}` in the same ms (+25 ms) → `0x1033 {298045}` and `0x301D {cen 1333, err
  0xF80}` +26 ms. Withdraw `0x301E {1333}` 877.854 → `0x3461` lock 25 → `0x045F {5, 1333, 103, 0}` + `0x3462 {…, cen 0,
  err 0xF80}` +87 ms → `0x1033 {299378}`, `0x301F {0, 0xF80}`. The ACK's `cen` is the **storage balance after**, the
  10-byte success ACK is the PDB `{u64 cen, u16 err}` (the Z04-B8 error path was not reached); money before / after
  299378 as in the notes. The GameLog field order is D05's `{chrregnum u32, money u32, userregnum u32, result u64}`; D03
  §5.1 lists it as `{nUserNo, charNo, money, storageMoney}` (§13).
- **Close**: `0x200B` and `0x304D` in the same ms (893.855), as §8.1.

### 20.2 Selling and buying back (step 9, Blacksmith James)

James (17084, mob 28 RouSmithJames, `Merchant Weapon`) answers the click with the quest dialog `0x4401` (quest 2524,
§10.5); the client's `0x201D {1}` opens `0x3C09` (62 items). HP Potion 3500: `SellPrice` 6, `MaxLot` 50.

| Time | Request | Cells 0 / 1 (lots) | DB | Client |
|---|---|---|---|---|
| 966.6 | `0x300D` 4 → cell 1 | 12 → 8 / 4 | (§19.3) | `0x300E {0x441}` |
| 987.3 | `0x3006 {slot 1, lot 1}` | 8 / 3 | `0x3425` SELLLOT, lock 27 | `0x305C {h 0}` |
| 991.6 | `0x3059 {0}` | **9** / 3 | `0x34BB` onto cell 0, lock 28 | `0x305D {0}`, `0x305A {0x3668}` |
| 997.1 | `0x3006 {slot 0, lot 1}` | 8 / 3 | SELLLOT, lock 29 | `0x305C {h 1}` |
| 999.5 | `0x3059 {1}` | 9 / 3 | `0x34BB`, lock 30 | `0x305D {1}`, `0x305A {0x3668}` |
| 1001.3 | `0x3015` cell 0 | 8 / 3 | `0x343E` (§19.6) | `0x3016 {0x700}` |
| 1015.6, 1025.1 | `0x3006 {slot 1, lot 1}` ×2 | 8 / 2, 8 / 1 | SELLLOT, locks 32 / 33 | `0x305C {h 2}`, `{h 3}` |
| 1025.4 | `0x3006 {slot 1, lot 1}` | 8 / – | `0x3422` SELLALL, lock 34 | `0x305C {h 4}` |
| 1068.3–1069.3 | `0x3059 {4}`, `{3}`, `{2}` | 9, 10, 11 / – | `0x34BB` ×3, locks 35–37 | `0x305D` + `0x305A {0x3668}` each |
| 1075.7 | `0x300D` 3 → cell 1 | 8 / 3 | `0x3434` lock 38 | `0x300E {0x441}` |
| 1092.3 | `0x3006 {slot 1, lot 3}` | 8 / – | SELLALL `price 18`, lock 39 | `0x305C {h 5}` |
| 1095.0 | `0x200A {17164}` (the Anvil) | | | nothing |
| 1117.7–1130.2 | `0x3059 {5}` ×19 | | none | `0x305A {0x3671}` each, no text |

- **Sell** (Z04 §2.4, Z05 §2.2, D03 §2.2): `0x3006` → `0x3425` / `0x3422` 1–20 ms later → `0x3426` / `0x3423` 6–26 ms
  later with GameLog `0x0449` + `0xC80E` in the same ms → `0x1033` (+cen), `0x3001` (lot left, or the cell emptied),
  `0x305C`, `0x3005 {0x381}`. `req.lot < cell.lot` → SELLLOT, else SELLALL (the last single of cell 1 at 1025.4 went
  as SELLALL). **0x3425** = D03's layout (ref + pdb2016 struct + attribute, P02.json): `iteminfo.attr` = 32 = payload
  offset of the attribute (as 0x343E, §19.6), the attribute = the lot **left**, `price` = sold lot × 6, `Vendor` 28 =
  James's mob id; `0x3426` = `{ref, lock}`. `0x0449 itemlot` = lot left (3 / 8 / 2 / 1, 0 after SELLALL).
- **0x305C**: `nHandle` 0…5 in sale order; freed handles 0 and 1 were not reused by the next sale *(the allocator
  `CSellItemManager` vt 0x18 / +8 was not read)*. `itemattr` = the sold lot (1, then 3) + 100 stale `gpp` bytes
  (P02-B16, batch 2): bytes 1–2 are the `0x3001` sent just before (high byte of item id 3500, its lot), bytes 18–27 the
  `0x3425` built in the same buffer (`price 6`, `UserNo 103`, `Vendor 28`), then text of earlier packets
  ("…ess to Isya…"): client and link packets share `gpp`.
- **Buy back** (Z04 §2.5, Z05 §2.2, D03 §2.2): `0x3059` → `0x34BB` 2–20 ms → GameLog `0x07FD` + `0x34BC {0x3668}` +
  `0xC815` in the same ms → `0x1033` (−6), `0x3001` (cell 0 lot + 1), `0x305D {h}`, `0x305A {0x3668}`. Every buy-back
  went onto **cell 0**, the potion sold from cell 1 too: `ii_RepurchaseLot` stacks onto the first unlocked cell of the
  item with room and the sold key only reaches the logs (D03 §2.2 confirmed). `0x34BB` = pdb2016 struct + 1 attribute
  byte (the target's lot after), `nItemAttrChange.attr` 40 = offset, `nItemAttrChange.attritemregnum` = cell 0's key,
  `nSellItemKey` = the sold item's key. `0x07FD {nType 0x7F8, charNo 5, 0, 3500, target key, nInt1 lot after, nInt2
  cell, nInt3 price 6, nBigint1 nSellItemKey}`; `0xC815 {103, 5, 3500, u64 6, Vendor 28}`. Buy-back price = `SellPrice`
  × lot.
- **The stack of 3 that could not be bought back** (notes "bug?"): settled. After the sale at 1092.3 the tester
  clicked the Anvil next to James (17164, mob 9361; `World/NPC.txt` RouN 5645 / 8924, `NPCMenu 0`, role `NPCMenu
  RandomOption` = `NPCRole_MenuOpen`) while James's shop window was open. `InteractWithNPC` @ FUN_004c4660 (Z02 §6.2)
  stores the Anvil's role entry in `sp_NPCProcess.npc` and calls `NPCRole_MenuOpen::nrb_Role` @ FUN_004c4140 at once,
  which returns without a packet because `dmc_CanMenuOpen(0)` fails (James's shop still holds menu bit 0): no reply on
  the wire. `sp_NC_ITEM_REPURCHASE_REQ` @ FUN_00538580 then asks `so_ply_CanItemRepurchase` @ FUN_005379f0 (vt 0xe6c)
  *(pdb2016)*: true only when the current role's slot 14 says so, i.e. `NPCRole_Merchant::nrb_CanItemRepurchase` @
  FUN_004c7690 with `RoleArg0` "Item" or "Weapon"; every other role class has the shared "return 0" FUN_004b8d20 there.
  So all 19 tries got `0x305A {0x3671}` without a DB request, and the client handler FUN_004b46a0 shows text only for
  `0x366B` / `0x366C` / `0x366D`: silent, with James's window still open (original bug) P02-B31. The stack stays in the
  list as handle 5. The two ends of the session (1165.8 `0x200B`, 1167.1 James again, no `0x201D`) retried nothing.
- `so_ply_SellItemList_Insert` @ FUN_00537a20 inserts the sold item first and sends `0x305C` only when
  `so_ply_CanItemRepurchase` holds: a sale at a SoulStone / Skill / WeaponTitle / Guild merchant (whose
  `nrb_ItemSellPrice` is the same Merchant function) enters the server's list without telling the client *(read, not
  captured)*. The same test also drops the `0x305D` for the entry `simg_Insert` pushed out of a full list, so the
  client keeps a handle the server no longer holds (original bug) P02-B32.

### 20.3 Soul stones (step 10, Healer Julia)

- `0x200A {17085}` (mob 29 RouSoulMctJulia, `Merchant SoulStone`) 1206.546 → `0x201C {29}` (no quest dialog) →
  `0x201D {1}` 1212.279 → `0x3C05 NC_MENU_SHOPOPENSOULSTONE_CMD {hp.recover 443, hp.maxnum 100, hp.price 55, sp.recover
  590, sp.maxnum 114, sp.price 37}` 4 ms later (Z02 §6.5 `nrm_PortionStone`; first capture).
- **Buy** (Z04 §13.1, Z05 §2.4, D03 §2.4): `0x5001 {3}` 1219.196 → `0x3441 {ref, chrregnum 5, flag 0, number 3, price
  165, lock 40}` +7 ms (D03's layout = ref + pdb2016 struct, P02.json) → `0x3442 {ref, lock}` +11 ms → `0x1033 {299231}`,
  `0x5003 {15}`, `0x3004 {0x201}` in the same ms. SP: `0x5002 {42}` → `flag 1`, `price 1554`, lock 41 → `0x5004 {51}`,
  money 297677 (notes). Totals = held (12 / 9) + bought, under `maxnum`: `0x742` not reached. **No GameLog row**: no
  `0x0458` from any server, as D05 says ("no 2016 sender"); D03 §2.4's "the zone logs 0x0458" is wrong (§13).
- **HP stone at full HP**: no `0x5007` on the wire; the client refuses by itself, without a message.
- **Use at 1 HP / 1 SP** (`&sethp 1` → `0x240E {1}`, `&setsp 1` → `0x240F {1}`): `0x5007` → `0x5008` +11 ms and B's
  `0x500B {8003}` in the same ms → `0x240E {444}` +48 ms (1 + `hp.recover` 443); `0x5009` → `0x500A` +14 ms, B's
  `0x500C {8003}` → `0x240F {591}` +45 ms. Confirms §9.6 / §10.4 from the bystander side: the other player gets
  0x500B / 0x500C, the user does not.

### 20.4 World traffic in the capture

- **`&levelup 25`** (135.630, level 8 → 33): A gets 25 × `0x240C` in one ms, B 25 × `0x240D {8003, 0}` 14 ms later
  (one per level; first bystander `0x240D`). Titles (`CT_LevelUp`, Z11 §7.3, Z18 §6.2): Test2 is class 6 → type 0x2E =
  46 (`CharacterTitleData` "Apprentice Cleric" `Value0 10`, "High Cleric" `Value1 20`): CharDB `0x6005 {ref, 46,
  0x80}` at 135.637 and `{46, 0x81}` at 135.642 (no answer, D04 §4.2), client `0x6004 {0x2E80}` /
  `{0x2E81}` (`ElementNo` 0 / 1, `ElementValue` 2), each **before** the `0x240C` of level 10 / 20 in the stream.
- **Level announcement**: level 20 passed → zone `0x6401 {AnnounceType 4, SizeOfMessage 51, "\"Test2\" has just become
  level 20. Congratulations!"}` on W00_WM#13 at 135.642 → WM `0x6402` with the same 53 bytes to both clients 88 ms
  later (W01 §7.6). **Z11-B30 captured**: a GM's `&levelup` announces world-wide. `0x6401` layout in P02.json (Z04.json
  types it as one 2-byte `ANNOUNCE_MESSAGE`).
- **Script message**: zone `0x207D` on W00_WM#11 at 146.087 → WM `0x2079` to both clients 6 ms later, the 39 bytes
  unchanged: `"E_Olympic_A04"` + 18 stale bytes (Z09-B72, §17.4); confirms W04 §2.4's relay. A map script, not a step.
- **B's map login seen by A** (89.9): B gets `0x1C07 {charnum 1, A}` + A's `0x1C19` at 89.893 (§18.2); A gets B's
  `0x1C06` + `0x1C19` at 89.907, then `0x2427 {8004, 291 StaImmortal}`, `0x112C {8004, bUse 0}`, `0x2427 {8004, 728
  StaE_UserNewbie01}`. `0x112C` reached A only: confirms §5.1 #12's *(inferred)* "the minimon broadcast excludes the
  sender"; `0x2427` goes to the others in sight (Z03 §6.3).
- **KQ minute ticks** (W04 §6.2 `SetDoneSkip` @ FUN_004548c0): from 756.8 on, every 60 s at hh:mm:00 (no skip at
  1356) the WM skips the KQs whose start wait passed without joiners: per KQ `0x5811 {hquest}` to the four zones'
  broadcast links (W00_WM#1 / #7 / #4 / #3, §17.4) and `0x5825 {nHandle, nID}` to both clients, then `0x581E
  NC_KQ_LIST_DELETE_ACK` through `KQ_RefreshOneClient` (one client per second: wm#2 in the same second, wm#1 ≈ 0.9 s
  later). 120 / 60 / 24 packets, 11 KQs at the first tick, 1–3 later; no `0x580B` (no joiners). Confirms W04 §6.2 /
  §6.4.

### 20.5 Opcodes

Types new in batch 3 (`0x3001`, `0x3006`, `0x3005`, `0x3422` / `0x3423`, `0x0449`, `0xC80E`, `0x3444` / `0x3446`,
`0x3C08`, `0x3428` / `0x3429`, `0x044C`, `0x5007`–`0x500A` recur as in §8.2 / §9.7):

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| C→S | 0x301C | NC_ITEM_DEPOSIT_REQ | 1 | 8 | confirmed | Z04 §7.1 |
| S→C | 0x301D | NC_ITEM_DEPOSIT_ACK | 1 | 10 | confirmed | `{storage balance, 0xF80}`, after `0x1033` |
| C→S | 0x301E | NC_ITEM_WITHDRAW_REQ | 1 | 8 | confirmed | Z04 §7.1 |
| S→C | 0x301F | NC_ITEM_WITHDRAW_ACK | 1 | 10 | confirmed | `{0, 0xF80}` |
| Z→CDB | 0x345F | NC_ITEMDB_DEPOSIT_REQ | 1 | 20 | confirmed | D03 §5.1 |
| CDB→Z | 0x3460 | NC_ITEMDB_DEPOSIT_ACK | 1 | 18 | confirmed | balance after |
| Z→CDB | 0x3461 | NC_ITEMDB_WITHDRAW_REQ | 1 | 20 | confirmed | D03 §5.1 |
| CDB→Z | 0x3462 | NC_ITEMDB_WITHDRAW_ACK | 1 | 18 | confirmed | balance after |
| CDB→GL | 0x045E | NC_LOG_GAME_MONEY_DEPOSIT | 1 | 20 | confirmed | D05 order; D03 §5.1's order **corrected** |
| CDB→GL | 0x045F | NC_LOG_GAME_MONEY_WITHDRAW | 1 | 20 | confirmed | as 0x045E |
| Z→CDB | 0x3425 | NC_ITEMDB_SELLLOT_REQ | 4 | 33 | **corrected** | ref + pdb2016 + attribute; `attr` = offset (P02.json) |
| CDB→Z | 0x3426 | NC_ITEMDB_SELLLOTSUC_ACK | 4 | 8 | **corrected** | `{ref, lock}` (P02.json) |
| C→S | 0x3059 | NC_ITEM_REPURCHASE_REQ | 24 | 2 | confirmed | 5 accepted, 19 refused |
| S→C | 0x305A | NC_ITEM_REPURCHASE_ACK | 24 | 2 | confirmed; **bug** | `0x3668` ×5; `0x3671` ×19 silent (P02-B31) |
| S→C | 0x305D | NC_ITEM_SELL_ITEM_DELETE_CMD | 5 | 2 | confirmed | before 0x305A |
| Z→CDB | 0x34BB | NC_ITEMDB_REPURCHASE_LOT_REQ | 5 | 41 | **corrected** | pdb2016 + 1 attribute byte (P02.json) |
| CDB→Z | 0x34BC | NC_ITEMDB_REPURCHASE_LOT_ACK | 5 | 10 | confirmed | `0x3668` |
| CDB→GL | 0x07FD | NC_LOG_GAME_DATA_TYPE_L | 5 | 44 | confirmed | `nType 0x7F8`; `nInt3` = price |
| CDB→GL | 0xC815 | NC_SYSLOG_CHAR_ITEM_REBUY | 5 | 20 | confirmed | D03 §2.2 |
| S→C | 0x3C05 | NC_MENU_SHOPOPENSOULSTONE_CMD | 1 | 24 | confirmed | Z02 §6.5 |
| C→S | 0x5001 / 0x5002 | NC_SOULSTONE_HP / SP_BUY_REQ | 1 / 1 | 2 | confirmed | Z04 §13.1 |
| Z→CDB | 0x3441 | NC_ITEMDB_SOULSTONEBUY_REQ | 2 | 23 | **corrected** | ref + pdb2016 (P02.json); `flag` 0 HP / 1 SP |
| CDB→Z | 0x3442 | NC_ITEMDB_SOULSTONEBUYSUC_ACK | 2 | 8 | **corrected** | `{ref, lock}` (P02.json) |
| S→C | 0x5003 / 0x5004 | NC_SOULSTONE_HP / SP_BUY_ACK | 1 / 1 | 2 | confirmed | new total; with `0x3004 {0x201}` |
| S→C | 0x500B / 0x500C | NC_SOULSTONE_HP / SP_SOMEONEUSE_CMD | 1 / 1 | 2 | confirmed | first capture: to the other player only |
| S→C | 0x240D | NC_BAT_SUMEONELEVELUP_CMD | 25 | 4 | confirmed | first capture: one per level, to the others |
| S→C | 0x2427 | NC_BAT_ABSTATESET_CMD | 4 | 6 | confirmed | first capture: the other player's abstates |
| S→C | 0x112C | NC_CHAR_USEITEM_MINIMON_USE_BROAD_CMD | 1 | 3 | confirmed | first capture: to the others, not the sender |
| Z→CDB | 0x6005 | NC_CT_DB_SET_CMD | 2 | 8 | confirmed | D04; no answer |
| S→C | 0x6004 | NC_CT_SET_CMD | 2 | 2 | confirmed | Z18 §6.2 |
| Z→WM | 0x6401 | NC_ANNOUNCE_Z2W_CMD | 1 | 53 | **corrected** | `{type, len, text[len]}` (P02.json) |
| WM→C | 0x6402 | NC_ANNOUNCE_W2C_CMD | 2 | 53 | confirmed; **bug** | type 4 level announcement for a GM (Z11-B30) |
| WM→C | 0x2079 | NC_ACT_SCRIPT_MSG_CMD | 2 | 39 | confirmed; **bug** | relay of 0x207D (Z09-B72) |
| WM→Zone | 0x5811 | NC_KQ_W2Z_DESTROY_CMD | 120 | 4 | confirmed | per skipped KQ, 4 zones |
| WM→C | 0x5825 | NC_KQ_JOINING_ALARM_END_CMD | 60 | 6 | confirmed | per skipped KQ, every client |
| WM→C | 0x581E | NC_KQ_LIST_DELETE_ACK | 24 | 2 + 4n | confirmed | one client per second |

`0x6006` (part-20 scope in the status file) does not occur in `s21`; its row is §18.8. Never sent by the 2016 client in
batches 2–3: `0x3028` (storage page). Not reached: `0x3427` / `0x34BA` / `0x34B9` (buy-back onto an empty cell),
`0x5005` / `0x3443` (soul-stone refusals).

## 21. Items III, batch 3: the setup runs S16, S13 and X3 (`s21b`, `s21c`, `s21d`) *(captured)*

Scenario 21 step 12 (capture-scenarios §8.17, §8.14, §9.4): three short runs, one login each. The character is
**Test1235** (`chrregnum` 2, user 103), not Test2 as in `s21`: zone handles 8009 / 8011 / 8000, WM sessions 12500 /
17500 / 20000. The committed `tools/capture/21/21-s16-on.sql` and `21-s13.sql` select `N'Test2'`; the outputs
(`26_11_15_21_items-s16-before.txt` `nCharNo 2`, `-s13.txt` key 120327209734897664, which is in Test1235's
inventory in `s21c`) show that they ran for Test1235, like the snapshots of §19.8 *(inferred: older copies of the
scripts)*. No notes files, one pcapng comment (`s21c`). Decoder: 0 issue packets in all three. Only one type is new
against every other capture, `0x340C`; the others recur with the layouts of §7.6.1, §8 and §19.

### 21.1 S16: a purchase whose attribute write fails (`s21b`, D03 check 13)

| Time | Stream | Packet |
|---|---|---|
| 14.585 | zone#1 | `0x200A {17084}` (James, mob 28) → `0x201C {28}`; the client's `0x201D {1}` 15.676 → `0x3C09` weapon list (62 items) 15.688 |
| 17.169 | zone#1 | `0x3003 {itemid 0 (LeatherBoots), lot 1}` |
| 17.178 | W00_CDB#1 | `0x340A BUYALL {ref 8009 / 2, owner 2, RouN 5701 / 8805, cell 0x241B, key …092480, itemid 0, attr 68, lock 0, price_cen 13, fame 0, coin 0, UserNo 103, Vendor 28, 13-byte boot attribute}` |
| 17.213 | W00_CDB#1 | `0x340C BUYALLFAIL {ref, error 0x206, lock 0}` (+35 ms) |
| 17.213 | zone#1 | `0x3004 {0x206}` (same ms) |
| 22.319 – 22.337 | zone#1, W00_CDB#2 | the same again: new key …898944, lock 1, `0x340C {0x206, 1}` +11 ms, `0x3004 {0x206}` |

Nothing else follows: no `0x3001`, no `0x1033`, no GameLog `0x0448` / `0xC80D`, no holy-promise reward. The capture ends
at 27 s.

- **Which call failed.** The trigger fires on an insert into `tItemOptions`. `p_Item_BuyAll` writes only `tItem`
  (`p_Item_Create` inserts one row) and commits; the first `tItemOptions` insert is `ItemAttr_Save`'s
  `p_Item_SetOption`, whose `UPDATE` finds no row for a new key and then inserts *(db-backup)*. So the run took D03
  §1.2's attribute branch of `ItemBuy_Create` @ FUN_0046bbf0: `p_Item_Delete`, `p_Char_MoneyAdd(owner, 13)`, an error
  other than 1, hence `0x206` (D03 §2.1). Confirmed: D03 §1.2 / §2.1 and Z05 §2.1 (`0x340C` → `0x3004 {error}` in the
  same ms, the reservation is dropped: no cell and no cen change on the client).
- **The refund.** The CharDB's `0x1007 Cen` is 99 999 634 524 at the logins of `s21b`, `s21c` and `s21d`, the
  `-s16-before.txt` value. The zone's saves carry no cen (§10.1), so the DB balance after the two failed purchases
  shows that both 13-cen debits of `p_Item_BuyAll` were refunded *(inferred from the balance; the debit is not on the
  wire)*. The item rows are gone too: `s21c`'s inventory holds no boots key from `s21b`. **D03-B1 is not tested.**
  Leather Boots cost cen only (`price_fame 0`, `coin 0`), so the lost fame / coins of D03-B1 cannot show. That needs
  a fame or token purchase under S16 (§15).
- **Client.** `GameFrameWork::On_NC_ITEM_BUY_ACK` @ FUN_004ab770 has no case for 0x206: its switch's default label is
  the 0x206 case (`switchD_004ab79e_caseD_206`), which returns without a text. The player sees nothing at all for a
  failed purchase. Z04-B6 lists 0x203 / 0x204 / 0x20E / 0x210 as silent; 0x206 (BUYALL DB error, captured) and 0x208
  (BUYLOT DB error, D03 §2.1, same default) are silent too (§12 row, §13).
- **The prediction** (capture-scenarios §8.17: "the item is deleted again, cen is refunded, fame or coins are not")
  holds for the item and the cen; the fame / coin half is untested.

### 21.2 S13: an item past its end time (`s21c`)

- **Setup.** `21-s13.sql` sets option row 820 (boot `deletetime`) of the newest Leather Boots in the inventory to
  8468 = 2020-01-01 00:00. Its output lists key 120327209734897664, inventory cell 27, with the 7 option rows 800–803 and
  820–822 (820 = 0 and 803 = 1 before the update): the boot rows of D03 §1.3 *(db query output)*.
- **Login.** The CharDB's `0x1017` (6.372), the WM's `0x102E` (7.017) and the client's `0x1047` (7.165) carry the
  boots at `0x241B` with the 13-byte `ShineItemAttr_Boot`. Bytes 7–10 are `14 21 00 00` = `deletetime` 8468 (offset
  +7 *(pdb2016)*), byte 12 = 1. The expired item is **not** removed in the login burst (`0x1801` 6.980, `0x1803`
  11.171).
- **Expiry**, in one 65 ms run:

| Time | Stream | Packet |
|---|---|---|
| 66.104 | W00_WM#1–#4 | `0x0821` (`tm_min` 54 → 55, `tm_sec` 35): the WM's minute (first one at 6.103, before the map login) |
| 66.124 | W00_CDB#6 | `0x3459 DESTROY_REQ {handle 8011, charNo 2, lock 0, flags 1, keys [120327209734897664]}` (+20 ms) |
| 66.149 | W00_CDB#6 | `0x345A {ref, lock 0, err 0xB81}`; the pcapng comment "Boots deleted here" is on this frame (976) |
| 66.169 | zone#1 | `0x3001 {0x241B, 0x241B, itemid 0xFFFF}`: cell 27 emptied |

  No client text, no GameLog row, no `0x1C04` (the boots were not worn). This confirms Z09 §1.2 / §2.4: the
  per-minute block runs when the WM's `0x0821` changes the minute, and `sp_ChargedItemLimitCheck` @ FUN_00451530 checks
  the inventory. It confirms Z24 §6.7 and Z13 §2.7 too: `end.year ≠ 0` and `end < now` lead to `sp_ItemDelete`
  @ FUN_00451090 → `sp_DestroyItem` @ FUN_00527870 → `0x3459`, and Z05 §6.4 clears the cell on the ACK. The prediction
  of capture-scenarios §8.14 holds: the item went at the first per-minute check after the login, 59.1 s after the map
  login (the WM's minute falls at :35 in this WM process, so the wait is at most 60 s), not in the login burst. Until
  that check the expired item is in the inventory and usable *(inferred, not tried)*.
- **`0x3459` from `sp_DestroyItem`.** The code writes `+8 flags` = key count 1 (bit 7 clear) and the key at payload +0x17
  (buffer +0x19). It does not write payload bytes 9–22 (`00 00 14 00 00 00 00 15 00 00 00 00 16 00`, earlier `gpp`
  contents), so P02-B30 is on the expiry path as well. Its overflow assert text reads
  "sp_MakeItem : Packet Too Long" (copied from the creation function).

### 21.3 X3: a stack over `MaxLot` (`s21d`)

- **Setup.** `ItemInfo.shn` with `BestLowHpPotion` (3500) `MaxLot` 49 on the server and the client (`21-x3.ps1`). The
  zones were restarted inside the capture (0–23 s, §17.4). Login: WM 23.6 s, `0x1801` 26.171. No refusal anywhere:
  no SHN-checksum kick (both copies changed) and no item check at login.
- **The stack.** Cell 27 (`0x241B`) = 3500, lot 50 (`0x102E` 26.240; `0x1047` 26.392 `1b24 ac0d 32`). It is loaded
  over the limit as it is, and no `0x3001` touches cell 27 in the whole capture.

| Time | Packet |
|---|---|
| 49.472 | `&makeitem BestLowHpPotion -l10` → `0x3401 ADMINCREATE` into cell 28 (`0x241C`, lot 10) → `0x3402` → GameLog `0x044F` → `0x3001 {0x241C, 3500, lot 10}` (a GM create takes an empty cell, §19.2) |
| 53.395 | `0x3007 {0x241C, lot 10}` → `0x3C01` drop warning + `0x3008 {0x301}`; OK 54.598 → `0x3416 DROPALL` + `0x3001` emptied → `0x3417` → `0x0447` → `0x1C0A {10500, attr 8}` + second `0x3008 {0x301}` (§19.4) |
| 55.966 | `0x3009 {10500}` → +9 ms `0x341C PICKALL {cell 0x241C, key …133824}` and `0x3001 {0x241C, 3500, lot 10}` → `0x341D` → `0x0446` → `0x300A {3500, 10, 0x341, 0xFFFF}` + `0x1805 {10500}` |

- **Reading.** `so_ply_PickupItem` @ FUN_0052faf0 walks the unlocked inventory cells that hold the item
  (`UnlockedInventoryIterator` over an `ItemBoxIterIdent`). It merges (`ii_PickMerge` → `0x341F`) only when
  `cell.lot + picked ≤ ItemInfo.MaxLot` (an unsigned sum; the code has no "free = `MaxLot` − lot" term that could go
  negative); otherwise it falls back to `ii_PickAll` into an empty cell. 50 + 10 = 60 > 49, so no merge and a new cell.
  The X3 question (capture-scenarios §9.4, "open, no prediction") has this answer: an over-full stack is never a
  pick-up target and stays at 50, and nothing at login or at the pick-up checks it. Z04 §3.3's "first stack with room"
  means room for the **whole** picked lot (no partial merge) (§13).
- **Not tried** (read only, Z04): the other `MaxLot` comparisons would treat the 50-stack differently: sell
  (§2.4, `cell.lot > MaxLot` → `0x3005 {0x385}`), use (§6.1, `lot > MaxLot` → `0x702`), and a move onto it (§4.1,
  `a + b > MaxLot` → `irm_Split_N_Merge(…, MaxLot − b)` with `MaxLot − b` = −1). §15 lists them for a later run.

### 21.4 Opcodes

| Dir | Opcode | Name | Seen | Size | Status | Notes |
|---|---|---|---|---|---|---|
| Z→CDB | 0x340A | NC_ITEMDB_BUYALL_REQ | 2 | 81 | confirmed | §7.6.1 layout; 13-byte boot attribute at `attr` 68 |
| CDB→Z | 0x340C | NC_ITEMDB_BUYALLFAIL_ACK | 2 | 10 | confirmed | **first capture**: `{ref, error 0x206, lock}` (Z05 §2.1, D03 §2.1) |
| S→C | 0x3004 | NC_ITEM_BUY_ACK | 2 | 2 | confirmed; **bug** | `0x206`, silent in the client (Z04-B6) |
| Z→CDB | 0x3459 | NC_ITEMDB_DESTROY_REQ | 1 | 31 | confirmed; **bug** | the expiry path: 1 key, bytes 9–22 stale (P02-B30) |
| CDB→Z | 0x345A | NC_ITEMDB_DESTROY_ACK | 1 | 10 | confirmed | `err 0xB81` |
| S→C | 0x3001 | NC_ITEM_CELLCHANGE_CMD | 1 / 3 | 6 / 6, 7 | confirmed | `s21c` / `s21d`; expiry: `itemid 0xFFFF` after `0x345A` |
| WM→Z | 0x0821 | NC_MISC_TIMEFROMWORLD_CMD | 8 (`s21c`) | 36 | confirmed | the minute change that triggers the expiry |
| Z→CDB | 0x341C | NC_ITEMDB_PICKALL_REQ | 1 | 45 | confirmed | pick into a new cell beside the over-full stack |
| S→C | 0x300A | NC_ITEM_PICK_ACK | 1 | 10 | confirmed | `{3500, 10, 0x341, 0xFFFF}` |

The other types of the three runs (the login bursts, the zone start of `s21d`, drop and `&makeitem` in `s21d`) recur
as in §5, §7, §17.4 and §19 with the same layouts.

## 11. Message order against README §2 and the pseudocode

README §2 is a sketch of the login → WM → zone chain. Against the thirteen captures (details in the sections cited;
the rows from "Login links" on come from batch 2, the first capture of the server links; each row's order holds in
every instance of both batch-2 captures; the rows from "Character create" on come from batch 3, §16–§21, and hold in
every instance of the six batch-3 captures):

| Phase | README §2 / pseudocode | Captured | Status | Detail |
|---|---|---|---|---|
| Login: version, password | `0x0807`, `0x0C65` → `0x0C67`, `0x0C5A` → DB round trips → `0x0C0A` | same, plus `C 0x0C04` right after `0x0C5A` (same tick) and `S 0x0C05` at once; `0x0C0A` 70–170 ms later | **corrected** (README omits 0x0C04/0x0C05; `login-server.md` §8 has 0x0C04 without the login request before it) | §3.1 |
| Login: token login | not in README | `0x0C37 token`, `0x0C04`, then `S 0x0C0A` **before** `S 0x0C05` (no DB round trip) | new | §3.1 |
| Login: world list | `0x0C0B` → `0x0C0C` | same (20–30 ms, WM 0x0C0D/0x0C0E); plus the client's `0x0C1B` / `0x0C1C` status poll every 10.0 s while the list is shown | **corrected** (poll missing) | §3.1 |
| WM: world login | `0x0807`, `0x0C0F` → `0x0C14` | same (+50..76 ms); then `C 0x080D` → `S 0x080E` game time | **confirmed**, 0x080D/0x080E missing from README | §4.1 |
| WM: character login | `0x1001` → `0x1003` | same (+614 ms); WM sends `0x7032`–`0x7034` 53 ms later, before the zone answers 0x1801; client asks `0x7004` / `0x700C` / `0x7C06` on 0x1802 | **confirmed**, option pushes missing from README | §4.1 |
| Zone: seed | `C 0x0806` → `S 0x0807` | `S 0x0807` on accept; the client never sends `0x0806` | **contradicted** (README §1.4, §2) | §2.3 |
| Zone: map login | `0x1801` → WM 0x104B / 0x101D → `0x1802` | `0x1801` (with `C 0x080D` to the WM in the same tick) → 15 client blob copies `0x1038` … `0x441E` → `0x1802` (+442..560 ms) | **confirmed**; README omits the blob copies before 0x1802 | §5.1 |
| Zone: login complete | `0x1803` → "initial world state" | `0x1803` + `0x2001 "&adminlevel"` + `0x200B` ×3 (+ `0x302C` / `0x3020` on the first login) in one client tick; the burst in Z01 §6 call order (17 steps, one server tick); parameter refresh one tick later; WM `0x180C` burst (W01 `fc_NC_MAP_LINKEND_CMD` call order) | **confirmed** (Z01 §6 order, W01 §7.3 order); one Z01 correction (0x2011 "From …" notice, §5.3) | §5.1, §4.1 |
| Map change | not in README | town portal `0x2401` → `0x2402` → `0x200A` → `0x243D` → `0x201C` → `0x181A` + `0x200B` → `0x181B` → `0x180A` (+90 ms); gate `0x3C01` / `0x3C02` → `0x180A`; new zone stream as above; WM repeats only `0x5826`, `0x182A` | new; **confirms** Z01 §7, Z02 §6, Z03 §2.3 / §3.4 | §6.1, §4.1 |
| Logout to the world list | not in README | zone `0x2012`, `0x1071`; WM option saves `0x7011` / `0x7015` / `0x7016` / `0x703B`; 10 s; `0x0C33` → `0x0C34`; `0x0C18 {0}` to WM and zone in one tick | new; **corrects** W01 §5.1 (mode 0 is also "back to the world list") | §4.1, §5.4 |
| Heartbeat | `C 0x0804` → `S 0x0805` | `S 0x0804` after 30 s of client silence → `C 0x0805`; unsolicited `C 0x0805` to the WM during map loads | **contradicted** (README §1.5) | §2.4, §4.4, §5.5 |
| Duplicate login | `login-server.md` §5.1 (Login broadcasts 0x0C16, then 0x0C0A) | WM `0x0C17 {0x683}` to the old client 0.8 ms before Login's `0x0C0A` to the new one | **confirmed** | §4.1 |
| Login links | `login-server.md` §4 / §5.1 / §5.2 / §6; W01 §3.2 / §3.3 | `0x0C5A` → AccountDB `0x0C5B` → `0x0C5C` → AccountLogDB `0x0C5D` → `0x0C5E` → WM `0x0C16` + AccountLogDB `0xC801` (same ms) → client `0x0C0A`; world select `0x0C0B` → AccountDB `0x0C10`, AccountLogDB `0x0721`, WM `0x0C0D` (same ms, this order) → `0x0C0E` → `0x0C0C`; WM world login: `0x0C16` to every zone, `0x0C60` → `0x0C61`, CharDB `0x0C12` → `0x0C5F` + `0x0C13` → client `0x0C14` | **confirmed**; two zone kicks per login (Login's and the WM's own); P02-B5 in the Login `0x0C16` | §7.2 |
| Character load (WM ↔ CharDB) | D02 §4 step order; W01 §4.2 (0x1005 handler) | `0x1001` → CharDB `0x1004` (same pass) → 36 blocks within 17 ms in D02 §4 step order → `0x1005`; the WM handles it 557–580 ms later (one packet per session per ≈ 15.6-ms pass) and sends CharDB `0x1036`, GameLog `0xC806`, client `0x1003` in one ms (CharDB's own GameLog `0x040A` 1 ms later); option push `0x7032`–`0x7034` 47 ms after | **confirmed**; D02 §4 steps 21 / 22 **corrected** (sent only with a row) | §7.4 |
| Map-login hand-over (zone ↔ WM) | Z01 §5.2 / §5.3; W01 §7.2 (0x101C send order) | `0x1801` → WM `0x104B` (link i) → `0x104C` → `0x101C` (link i + 1) → 30–32 blob packets and `0x101D` (31–33 packets) in one ms on that link → client `0x1802` 391–455 ms after `0x101D` (the zone reads one packet per link per ≈ 13-ms pass) | **confirmed** (Z01); W01 §7.2 **corrected** in three places (0x1029 / 0x1098, 0xCC0C, 0x441D) | §7.5.2 |
| Map-login requests at `0x1803` | Z01 §6 (0x10B3 first, 0x1080); D02 §7.1 / §11 | CharDB `0x10B3` (first link packet of the burst) → CharDB `0x1080` (same ms) → the WM's GameLog `0x040F` 0–6 ms later; answers `0x10B4 iscorrect 1`, `0x1081 Error 0x12E2` (not forwarded to the client) | **confirmed**; corrects this file's batch-1 §5.1 line ("0x10B3 not sent") | §10.2 |
| Map change on the links | Z01 §7.1 (`so_LinkTo`); Z01 §8.4 (`ws_save2worldmanager`) | WM `0x180B` → `ws_save2DB(p, 0, 2)` (CharDB + GameLog `0x0410 StoreType 2`) → `ws_save2worldmanager` `0x400E` … `0x4037` (round robin over the 4 WM links, one burst in 1–2 ms; on one link the tail leaves 5–16 ms late, Nagle, §7.5.4) → WM `0x180D` → GameLog `0xC809` → WM `0x180E` on the `0x180D` link → client `0x180A` 10–16 ms later → new zone: hand-over as above | **confirmed** (Z01 §7.1); Z01 §8.4 **extended** (list and conditions); P02-B12, P02-B14 | §7.5.4, §10.1, §10.2 |
| CharDB save burst | D02 §6; Z01 §8.4 | `ws_save2DB`: `0x4018`, `0x4001`, `0x4007`, `0x400B` (if titles are marked), GameLog `0x0410`, `0x401A`, `0x4035` in one ms (`0x401A` 16 ms late in `combat` 118.034, §10.1); ACK `0x4008` before `0x4002` in every burst | **confirmed**; Z01 §8.4 header **corrected** (`bufferlocation` always 0, P02-B21) | §10.1 |
| Kill | Z03 §3.2 / §8.1; Z09 §5.4 | in the ms of the killing hit: WM `0x1073`, GameLog `0xC80B`, client `0x2402`, `0x240B` (+ `0x1C0A` drops), `0x2448`; `0x244A` 41–55 ms later from the mob tick (same ms after a skill kill); hunt log GameLog `0x042D` only at the next same-zone link or logout | **confirmed**; Z09 §28.12 **corrected** (P02-B20: a link to another zone drops the hunt log) | §9.3 |
| Level-up | Z03 §8.3; Z12 §7 | per level, in one ms: WM `0x400E`, `0x1074`, GameLog `0x041E`, `ws_save2DB(p, 1, 8)`, CharDB `0x1070`; client `0x240C`, `0x4810`, `0x105B`, `0x2446`, `0x106F`, `0xBC05`; HP / SP refill one tick later; client `0x4025` → CharDB `0x4027` → `0x4028` → client `0x4026`; WM GameLog `0xC808` in link-service order (7, 6, 8) | **confirmed**; P02-B12 (WM order) | §9.4, §10.6 |
| Death and revive | Z03 §7.2; Z07 §3.1; Z01 §7.1 (same-zone branch) | death in the mob tick: GameLog `0x042B` + `0xC80A`, then (19 ms later, one frame) client `0x104D`, `0x2448 resthp 0`, `0x2402`, `0x240E hp 0`; revive `0x104E` → WM `0x180B`, GameLog `0x042D` (hunt-log flush in `so_Unmark` before its `REMOVE_REVIVE` case), `ws_save2DB(p, 0, 2)`, client `0x1C18` / `0x242A`, `0x104F` → client `0x1803` 158 ms later → full map-login burst (§5.1) and WM `0x180C`; no WM saves, no `0xC809` | **confirmed** | §9.5 |
| Item transaction | Z05 §1.1 / §1.2; D03 §2–§5 | client request → CharDB request (lock index 0, 1, 2 … per player) → answer → GameLog log and, in one ms, the client cell changes + ACK (commit style 1); pick-up: `0x3001` with the request, `0x300A` after `0x341D` (style 2) | **confirmed** | §7.6.1 |
| Periodic link traffic | W01 §2 / §8; D01 §4.2; Z09 §1.2 | WM → Login `0x0808` every 30.0 s; AccountLog `0x0809` on each minute change → WM `0xC811` + `0x080A` (same ms or one WM pass later, 0–15 ms); WM `0x0821` every 60 s (at :42) → each zone's per-minute block; zone `0x7495` per minute, `0x987A` / `0x987B` at :00 | **confirmed**; D01 §4.2 **corrected** (0x080A only as the answer to 0x0809) | §7.2, §7.5.3, §7.5.4 |
| Character create | W01 §4.1; D02 §3 | `0x1401` → CharDB `0x1402` (14 ms) → `0x1405` (85–100 ms, `p_Char_Create`) → one WM pass → AccountDB `0x140D`, GameLog `0x0411` + `0xC804`, client `0x1406` in one ms (`fc_NC_AVATAR_CREATEDATASUC_ACK` @ FUN_004113c0 code order) | **confirmed**; P02-B24 (`sCharName` tail) | §16.1, §16.3, §18.1 |
| Character delete | W01 §4.1; W03 §4.5; W04 §4.3 / §12.4; D02 §3.4; D05 §2.3 | `0x1407` → CharDB `0x1413` → `0x1414 {nGuildNo 0}` → `0x1408` → `0x140B` + the Character server's GameLog `0x0412` (same ms) → AccountDB `0x140E`, GameLog `0x0412` + `0xC805`, client `0x140C`, CharDB `0x9424`, every zone `0x10B2` (same ms) → `0x9425` 3 ms later | **confirmed** (W03 §4.5, W04 §4.3: `AvatarErase` @ FUN_004382d0); W01 §4.1 (0x1407 → 0x1408) **corrected**, W04 §12.4 **extended** (0x9425 on every delete) | §16.1 |
| Back to the world list on the links | W01 §5.1; `login-server.md` §5.3 | `0x0C33` → Login `0x0C35` → `0x0C36 {0x1E58, hWM, sOTP}` → client `0x0C34` → client closes the WM connection → AccountDB `0x0C11`, AccountLog `0x0722` + `0xC803`, every zone `0x0C19` (same ms) → token login (batch-1 row above) with Login → WM `0x0C16` → every zone `0x0C16` | **confirmed**; P02-B5 also on the OTP path (other stale bytes) | §16.1 |
| Login refusals | `login-server.md` §4 / §5.1; L00-B3; L01 world-status table | world closed: `0x0C0A` / `0x0C1C {0}`, select → `0x0C0C {0}` 17 ms; world full: select → AccountDB `0x0C10`, AccountLog `0x0721`, WM `0x0C0D` → `0x0C0E {ok 1}` → `0x0C0C {5, WM address, validate}`, no WM connection; blocked / not login-able: AccountDB `0x0C5C {nBlock 1}` / `{bLoginAble 0}` → client `0x0C09 {0x47}` / `{0x48}`, AccountLog `0x0720` + `0xC802`, no `0x0C5D` | **confirmed**; `login-server.md` §4 refusal body **contradicted** (P02-B23); L00-B3 captured; P02-B22 (first `0x0808 {0, 0}`) | §16.1, §16.3 |
| WM start | W05 §1.2 / §1.3; W03 §9.1; W01 §2.1 | links to AccountLog, Account, Char, GameLog, Login within 3 ms, each `0x0801` → `0x0802` → `0x0803`; Login `0x0808 {0, 0}` in the handshake ms (P02-B22); CharDB start-up load in W03 §9.1 order, one request per answer, ended by the `0x9804` answer when `dAggregationDate` is 0 (no `0x9805` / `0x9806`); stop: the five FINs within 2 ms | **confirmed**; W05 §1.3 (end of the load) **corrected** | §17.2, §17.3, §17.5 |
| Zone start | Z01 §3.3; Z09 §1.5; W05 §5.2; S02 §1.4 | per process 4 CharDB, 4 GameLog, 4 WM links; the WM refuses the 2nd and 4th WM link (P02-B25), the zone retries after 20.0 s; per accepted WM link `0x0801` → `0x0802` → `0x0803` → zone `0x180F` + `0xA419` (`0x7446`, `0xBCD5` once per process) → WM `0x0821`; WM → CharDB `0xA41A` once per WM start (32 ms after the first `0xA419`); later broadcasts on the last-registered link (186 / 188) | **confirmed** + Z01 §3.3 **extended**; W01 §7.1 / W02 §1.6 **corrected** (P02-B26); §7.5.1's broadcast-link inference settled | §17.4, §17.5 |
| Entering sight | Z09 §9.6; Z02 §5.1 / §5.2 | inside `MapInfo.Sight` (1600 on RouN) the mover gets `0x1C06` + `0x1C19` for the other player, the other `0x1C06` + the mover's last `0x201A` + `0x1C19` 33 ms later from the same exchanger call; at a map login next to a player the one logging in gets `0x1C07` + `0x1C19`, the other `0x1C06` + `0x1C19` 14 ms later (`s21`); then the mover's `0x201A` / `0x2013` reach the other; a move naming an unknown handle → client `0x1C01` → appear packet + last move 3–20 ms later, the requester's `0x1C19` to the **other** player (Z02-B3) | **confirmed** | §18.2, §20.4 |
| Chat: shout, whisper | Z02 §3.2; W04 §2.1 | shout `0x201E` → `0x201F` to the map including the shouter (a level-1 shout dropped silently); whisper `0x200C` → 11 ms → WM: receiver `0x200D`, sender `0x200F`, sender's zone `0x6006` on its broadcast link, one ms | **confirmed**; P02-B29 (stale flag bits) | §18.4 |
| GM visibility | Z11 §3.1; Z01 §3.2 (`AxialListPacketBroadcast`) | `&hide`: GM `0x242A {288}`, the others `0x1805` (16 ms); `&show`: `0x2428` to both, the appear only after the **GM's** next move (`0x201A` → `0x1C01` → `0x1C06`); `&dimension n`: `0x1805` only where `l_Main` matches or is −1; an appear + delete pair per server step of every object near the GM (P02-B27) | **extended** (Z11 §3.1 holds for broadcasts only) | §18.6 |
| Split, merge | Z04 §4.1 / §4.2; Z05 §4; D03 §3.3 | split `0x300D` → `0x3434` (10–17 ms) → `0x3435` + GameLog `0x0457` (same ms) → `0x3001` ×2 + `0x300E {0x441}` (style 1); merge `0x300B` → `0x342E` → `0x342F` + `0x0456` → `0x3001` ×2 + `0x300C {0x241}`; occupied target → `0x300E {0x446}` without a DB request | **confirmed**; Z04 §4.2 codes and 0x3434 offsets **corrected** | §19.3 |
| Drop, pick-up | Z04 §3.1 / §3.3; Z05 §3.1; Z09 §11.4 | drop `0x3007` → menu `0x3C01` + `0x3008 {0x301}` → `0x3C02` → `0x3416` + `0x3001` (same ms, style 2) → `0x3417` → GameLog `0x0447`, `0x1C0A` to the others, then to the dropper with the second `0x3008 {0x301}`; part stack → `0x3008 {0x303}` (Z04-B4); pick onto a stack `0x341F` + `0x3001` + `0x3014` to the others (same ms) → `0x3420` → `0x300A`; pick into a new cell `0x341C` (as §7.6.1); owner-only time 19.9–19.95 s, then `0x1C0A attr 8` again | **confirmed**; Z05 §3.1 time unit **corrected** (0.1 s) | §19.4 |
| Item use | Z04 §6.3; Z13 §8; Z05 §6.1; D03 §4 | `0x3015` → after the cast (34 ms) `0x343E` USELOT / `0x343F` USEALL + `0x301A` (same ms) → `0x3440` + GameLog `0x0459` / `0x045A` → `0x3016 {0x700}`, `0x3001`, `0x240E` together; full HP → `0x3016 {0x713}` without a DB request | **confirmed** | §19.6 |
| Storage | Z04 §7.1 / §7.2; Z05 §7; D03 §5.1 | open → 4 × `0x3444` (one per CharDB link, all in one ms, 3 ms after `0x201D`) → each `0x3446` → its `0x3C08` as it arrives (no `0x3028`); deposit `0x301C` → `0x345F` → GameLog `0x045E` + `0x3460` (same ms) → `0x1033`, `0x301D {balance after}`; withdraw `0x301E` → `0x3461` → `0x045F` + `0x3462` → `0x1033`, `0x301F` | **confirmed**; D03 §5.1 (0x045E field order) **corrected** | §20.1 |
| Sell, buy back | Z04 §2.4 / §2.5; Z05 §2.2; D03 §2.2 | `0x3006` → `0x3425` SELLLOT / `0x3422` SELLALL → `0x3426` / `0x3423` + GameLog `0x0449` + `0xC80E` (same ms) → `0x1033`, `0x3001`, `0x305C`, `0x3005 {0x381}`; buy back `0x3059` → `0x34BB` → GameLog `0x07FD` + `0x34BC` + `0xC815` (same ms) → `0x1033`, `0x3001` (first cell of the item with room), `0x305D`, `0x305A {0x3668}`; with another NPC's role current → `0x305A {0x3671}` without a DB request (P02-B31) | **confirmed**; Z04 §2.5 vt 0xe6c **settled** | §20.2 |
| Soul stones | Z04 §13.1 / §13.2; Z05 §2.4; D03 §2.4 | `0x5001` / `0x5002` → `0x3441` → `0x3442` → `0x1033`, `0x5003` / `0x5004`, `0x3004 {0x201}` (same ms), no GameLog row; use `0x5007` → `0x5008` + `0x500B` to the others (same ms) → `0x240E` 48 ms later (SP: `0x5009` → `0x500A` + `0x500C` → `0x240F`) | **confirmed**; D03 §2.4 ("the zone logs 0x0458") **contradicted** | §20.3 |
| World announcements | W01 §7.6; W04 §2.4 / §6.2; Z11 §7.3 | `&levelup` past level 20: zone `0x6401` → WM `0x6402` to every client 88 ms later (Z11-B30); zone `0x207D` → WM `0x2079` unchanged 6 ms later (Z09-B72); title marks CharDB `0x6005` + client `0x6004` before the level's `0x240C`; KQ skip at hh:mm:00: `0x5811` per zone, `0x5825` per client, then `0x581E` one client per second | **confirmed** | §20.4 |
| Failed purchase (S16) | Z05 §2.1; D03 §1.2 / §2.1 | `0x3003` → `0x340A` → 11–35 ms → `0x340C {0x206}` → client `0x3004 {0x206}` in the same ms; no `0x3001`, `0x1033` or GameLog row; the cen comes back (next login's balance) | **confirmed**; Z04-B6 **extended** (0x206 / 0x208 silent) | §21.1 |
| Item expiry (S13) | Z09 §1.2 / §2.4; Z24 §6.7; Z13 §2.7; Z05 §6.4 | not in the login burst; WM `0x0821` (the WM's minute falls at :35 in `s21b` / `s21c`, at :42 in batch 2) → 20 ms → CharDB `0x3459 {flags 1, key}` → `0x345A {0xB81}` → client `0x3001` (cell emptied), no text, no GameLog row | **confirmed**; P02-B30 on this path | §21.2 |

Pseudocode orders the captures confirm in full: Z01 §6 (`sp_NC_MAP_LOGINCOMPLETE_CMD` burst), W01 §7.3 and W04 §17.5
(`fc_NC_MAP_LINKEND_CMD`, incl. the zone round trip `0x1120` that grants abstate 728 one tick after the burst, §5.1),
W05 §2.2 (0x0849 once per character, on the full minute), Z09 §2.4 (per-minute check, item expiry), Z09 §9.6 (sight
enter / leave at `MapInfo.Sight`), Z02 §5 (`ResendLastMove` after 0x1C08). Batch 2 adds `login-server.md` §4 / §5
(link round trips), D02 §4 (character load), Z01 §5.2 / §5.3 / §7.1 (hand-over, both `so_LinkTo` branches), D02 §6
(save headers and ACKs), Z03 §3 / §7.2 / §8 (swing, death, kill, level-up), Z05 §1 (both commit styles), Z07 §3.1
(revive) and Z12 §7 (level-up tail). Batch 3 adds W01 §4.1 / W03 §4.5 / W04 §4.3 (character create and delete), W05
§1.2 / §1.3 and W03 §9.1 (WM start, stop, CharDB load), Z01 §3.3 and Z09 §1.5 (zone link set, registration,
reconnect), Z09 §9.6 and Z02 §5.1 (sight entry, `0x1C01`), Z02 §3.2 and W04 §2.1 (shout, whisper), Z05 §3 / §4 / §6
(drop, pick-up, split, merge, use), Z04 §7 / §13 (storage, soul stones), D03 §2.2 (sell, buy back) and Z09 §2.4 /
Z24 §6.7 (expiry at the first minute). The corrected orders are W01 §7.2 (hand-over), Z01 §8.4 (WM save list), W01
§4.1 (0x1407 asks the guild first) and W05 §1.3 (end of the CharDB load), all in §13.

## 12. Original-server bugs

Found by P02 (tagged `(original bug)` where described):

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| P02-B1 | Character server `GetAvatarInfo` → WM 0x0C14 avatar list (D02 §3.2) | `delinfo` writes only byte +0x27 when the character is not deleted; +0x28..+0x2B keep whatever the buffer held (§4.3) | 4 bytes of Character-server memory (pointer-like) reach every client in the avatar list | zero the whole 5-byte `delinfo` |
| P02-B2 | WM `fc_NC_MAP_LINKEND_CMD` @ FUN_0042d8d0 → client 0x182A | `CSendPacket::ID(&p, 0x182a, 1, NULL)` declares a 1-byte payload and writes none (§4.2) | one stale WM byte per map login (0xDA / 0x00 captured); the client ignores it | payload size 0 (the 2017 PDB struct is empty) |
| P02-B3 | zone `so_ply_FillRewardInven` @ FUN_004fc310 → 0x302D | adds the counter byte to the length `irs_FillBufferItem` @ FUN_00644c80 already counts (§5.3) | every 0x302D carries one uninitialised trailing byte | use the returned length as is |
| P02-B4 | zone `sp_NC_MAP_LOGINCOMPLETE_CMD` @ FUN_00443390 (tail) | a missing title state entry or abstate jumps to the epilogue (§5.3) | latent: with a bad `CurrentTitleElement` the client gets no 0x10C6 / 0x482C / 0x10D4 / 0x1827 / 0x182C, no map Lua `MapLogin`, no GameDB 0x34CF | skip only the title abstates and continue |
| P02-B5 | Login `fc_NC_USER_US_IS_IP_BLOCK_ACK` @ FUN_004058c0 (and the other 0x0C16 broadcasts of `login-server.md` §4 / §5.1) → WM 0x0C16 | builds the raw packet on the stack, writes only the header and `usrregnum` at +6, and sends 0xD bytes (§7.3) | 6 bytes of Login stack (`76 27 d3 ef 76 00`) reach the WM in the `NETPACKETZONEHEADER` slot on every login; the WM ignores them | zero the header (the WM fills it with 0xFF when it forwards) |
| P02-B6 | AccountLog `CStatistics::Process` @ AL:FUN_004064b0 → WM 0x0809 | the payload byte is the high byte of the `CSession_Manager *` parameter, which is reused as the packet buffer (§7.3) | one meaningless byte per minute to each WM; the WM ignores it | empty payload (the struct is empty) |
| P02-B7 | Character server `GetAvatarInfo` @ FUN_0046bff0 → 0x0C13 → client 0x0C14 (D02 §3.2) | packs `dKQDate` into bits 0–29 and ORs in `*(u32 *)(avatar + 0x73) & 0xC0000000`, so bits 30–31 keep the buffer's old bits (§7.4) | 2 random bits per avatar on the wire (`0x8B…` / `0x40…` captured for the same date); the 30 date bits are right | clear the whole u32 before packing |
| P02-B8 | Character server `SendQuestDone` @ FUN_004288d0 → WM 0x100B (D02 §4 step 6) | sizes every part `0x12 + 10n`: 4 bytes past the 14-byte header + records (§7.4) | 4 unwritten bytes per part go to the WM, which stores them in the quest-done blob (zero in both captures) | `0xE + 10n` |
| P02-B9 | Character server 0x10EB handler @ FUN_00427d90 → WM 0x10EC (D02 §12) | zeroes only the first 7 ints of `AttendanceArray[0]` and fills one `tm` per DB row; the packet always carries all 28 (§7.4) | ≈ 1 KB of Character-server stack per attendance request reaches the WM; the WM reads only `AttendanceNum` entries | zero the array (`memset`) |
| P02-B10 | WM `CParserCharDB` character-block handlers FUN_0040a1d0 … FUN_0040df70 (30, list in §7.5.3) → `CWMClientSession::CharDataStore` @ FUN_00430780 / FUN_004307d0 / FUN_00430870 | store `payload + 2` with `len − 2` bytes, where `len` includes the 2-byte opcode: 2 bytes past the packet (§7.5.3) | every zone hand-over packet built from a CharDB copy carries 2 extra bytes (the next packet's header bytes from the WM receive buffer, or stale bytes for the last packet); the zone ignores them, the WM reads 2 bytes beyond the packet | `len − 4` (the payload after the handle) |
| P02-B11 | WM `CParserZone::fc_NC_CHARSAVE_2WLDMAN_ITEM_CMD` @ FUN_0042a160 (zone 0x4013) | stores `payload + 6` with `len − 4` bytes: 4 bytes past the packet (§7.5.3) | every later 0x102E carries 4 extra bytes (the start of the next zone packet on that link); harmless for the zone, a 4-byte over-read on the WM | `len − 8` |
| P02-B12 | zone `SocketBundle<WorldManagerSession>::sb_GetSocket` @ FUN_004199b0 used for every per-character update (`sp_GainExp` @ FUN_0042d830, `ws_save2worldmanager` @ FUN_004536f0, …), with the WM serving each link once per pass in session-list order | consecutive updates of one character go out on 4 different links, and the WM applies them in link-service order, not in send order (§7.5.4) | `&levelup 3`: the WM logged GameLog 0xC808 for levels 7, 6, 8; two updates of one field in one WM pass (two 0x1073 / 0x1074 / 0x400E) can leave the WM cache (party, guild, academy level, exp) one step old until the next update | keep one character's updates on one link (pick the link by character) |
| P02-B13 | WM `CGuildManager::ProcessGuildAcademy` @ FUN_00441200 → all zones 0x987A | copies the 15-byte buff name with a `strcpy` loop into the uncleared `CSendPacket` buffer and sends all 32 bytes of `BuffName` (§7.5.4) | 17 stale WM stack bytes per zone per minute (in `shop` 58.755 the tail of the KQ title of the 0x580D built in the same ms); the zone reads up to the NUL | zero the buffer or use a bounded copy that pads |
| P02-B14 | zone `ShinePlayer::so_SaveItem_Part` @ FUN_00456030 → WM 0x4013 | the mini-house (`nPartMark 0x12`) and action-box (0x22) loops increment `nPacketOrderNum` before the send, the inventory (5) and equipment (8) loops after it; an action-box failure logs the mini-house message (§7.5.4) | first packet of boxes 0x12 / 0x22 carries order 1 (`0x81` captured), of boxes 5 / 8 order 0 (`0x80`); harmless, the WM uses the order only for the inventory (`CharDataStore` @ FUN_00430870, `nPartMark & 4`); Z13 §2.8 describes the order without a tag | count from 0 in all four loops; own log text for the action box |
| P02-B15 | Character server `fc_NC_ITEMDB_PICKALL_REQ` @ FUN_0040b760 → GameLog 0x0446 | fills `chrregnum`, the map name (`strncpy` "Need", 12 bytes, D03-B11), the key, `itemlot 0` and `itemid`; `mappos.x` / `mappos.y` and `iteminven` (10 bytes) keep the stack (§7.6.1) | every pick-up log has garbage cell values (0x7512, 0x4372, 0x7511 captured) and x = y = 0 | write the request's map position and `location` |
| P02-B16 | zone `ShinePlayer::so_ply_SellItemList_Insert` @ FUN_00537a20 → client 0x305C | writes `nHandle` and the item with its class-sized attribute, then sends a fixed 105-byte payload from the shared `gpp` buffer (§8.1) | up to 100 stale bytes per sale: text and lists of earlier packets (other players' messages included) | length = 4 + written item bytes, or clear the buffer |
| P02-B17 | zone `ShinePlayer::so_accountstoragefill` @ FUN_0044c530 → client 0x3C08 | adds the length of `ias_FillBufferItem` @ FUN_00643b10, which already counts the `itemcounter` byte, to the offset after it (§8.1) | every storage page carries one stale trailing byte | use `0xd + n` (same slip as P02-B3) |
| P02-B18 | zone `ShineMobileObject::smo_SwingDamage` @ FUN_00432f30 → 0x2448 | sets the `flag` bits one by one in the shared buffer `gpp` and never writes bit 5 (`isDead`, pdb2016) or bits 1–7 of the second flag byte (§9.2) | 8 bits of whatever `gpp` last held per damage packet (0 in all 28 captured); the client reads none of them and takes death from `resthp 0` | clear the flag word first; set `isDead` when the hit kills |
| P02-B19 | zone `SkillDamageSender::sds_TemplateStore` @ FUN_005803c0 → 0x2452 | builds each `SkillDamage` in a stack local and writes the second flag byte from `old & 0xfa` plus the three known bits, keeping bits 3–7 of the stack (§9.2) | uninitialised stack bits on every skill damage entry (`0x28` in both captured) | start from a zeroed entry |
| P02-B20 | zone `ShinePlayer::so_Unmark` @ FUN_00558900 (hunt log, Z09 §28.12) | flushes `mhl_SendAll2Log` only when `smo_GetMode() != 0`; a link to another zone sets mode 0 in `so_LinkTo` before the unmark in `so_banning` (§9.3) | every zone change drops the hunt-log entries of that zone (`shop`: the RouN Slime kill never reached GameLog 0x042D); only same-zone links and logout log them | flush in the other-zone branch of `so_LinkTo`, or before setting mode 0 |
| P02-B21 | zone `WholeSaver::ws_save2DB` @ FUN_00455a10, `ws_save2worldmanager` @ FUN_004536f0, `ws_savelevel2worldmamager` @ FUN_00453580 (§10.1) | every save's `handle.bufferlocation` is `ws_savestorepoint.value`, which only the constructor @ FUN_004565f0 sets (0); the 2048-slot `ws_savestore` ring (0x148A8 bytes per slot) is never used and `ws_saveassure` @ FUN_00453d40 is empty | `bufferlocation` is 0 in every 0x4001 / 0x4007 / 0x401A and every ACK, so an ACK cannot be matched to a pending save and a lost save is never re-sent; 172 MB of unused memory per zone process | advance the index per save, keep the save in `ws_savestore[index]` until its ACK, re-send unanswered ones in `ws_saveassure` |
| P02-B22 | WM `CWMLoginSession::SendUserCount` @ FUN_00438d10, forced by the Login-link handshake (W01 §2.1) | the first `0x0808` after a WM start carries `MaxOfUser` = the client capacity `DAT_00556bb8`, still 0 because the client listener opens only after the four DB links (cause *inferred*; `{0, 0}` captured at both starts, §16.3) | Login sets the world to `WMSUS_FULL` and pushes the list: for up to 30 s after every WM start world selects get "Server is full" (after L00-B3's AccountDB / AccountLog / WM side effects) | send the first count once the client listener is open, or skip a count with `MaxOfUser 0` |
| P02-B23 | Login `fc_NC_USER_WORLDSELECT_REQ` @ FUN_00406970 (refusal branch) | sends the 0x55-byte stack `PROTO_NC_USER_WORLDSELECT_ACK` with only status, `wm_ip` and `wm_port` written; `validate_new[32]` is never initialised (§16.3) | 64 bytes of Login stack (pointers, string pieces) reach the client with every refused world select; the client ignores them | zero the struct before `GetWorldManagerConnectInfo` |
| P02-B24 | WM `fc_NC_AVATAR_CREATEDATASUC_ACK` @ FUN_004113c0 → AccountDB 0x140D | `sCharName` is `char[40]` *(pdb2016)*; the WM writes 20 name bytes and one zero byte, bytes +0x1E..+0x30 are stack residue (§16.3) | 19 stale WM bytes per character creation on the AccountDB link; the Account server drops 0x140D unread, so no effect | copy the name into a zeroed 40-byte field |
| P02-B25 | shared `CSocket_Acceptor::SetAccepted` @ FUN_00463c40 (S02 §1.4), WM zone listener; the same class serves the WM client listener and Login / Zone (S02 §1.9) | refuses and closes a socket while another one from the same IPv4 address waits in the accepted ring; the ring is drained once per main pass (§17.4) | every zone start loses its 2nd and 4th WM link (8 of 16 in both captures) and reconnects them 26–29 s later, half again refused, 20 s more; a zone runs ≈ 30 s on 2 links and ≈ 50 s until it has 4; two clients behind one NAT address that connect within one pass lose the second connection | exempt server listeners, or compare address and port, or drain the ring in the accept thread |
| P02-B26 | WM `CWMZoneSessionManager::SetServiceMapZoneNo` @ FUN_004391d0 (zone 0x180F, W01 §7.1 `Zones_AddMap`) | a new map entry stores `Vaild`, name, `ZoneNo` and `CanParty` but not `IsReleaseMap`; only the update path (a second registration of the same map) stores all three (§17.4) | masked: every zone registers its maps on each link that registers (2–4 times), so the flag is set one 0x180F later; a zone left with a single WM link would keep `IsPartyReleaseMap` 0 for all its maps (no leave-party on entering `Job*_Dn*`, `Wedding`, `Rou00`… after a fresh WM start) | store `IsReleaseMap` in the new-entry path too |
| P02-B27 | zone `AmpersandCommand::ac_Dimension` @ FUN_0041a5a0 (Z11 §3.1) with the sight workers `AxialListBriefExchangerAtMove::ali_Work` @ FUN_004bdde0 / `AxialListBriefDeleteAtMove::ali_Work` @ FUN_004bdfe0 (Z09 §9.6) | `&dimension n` writes only `so_layer.layer→l_Main`; `so_AllOfRangeNomal` @ FUN_0054c900 still selects the GM by the unchanged `LayerRegistInfo`, while `so_DistanceSquar` @ FUN_004028f0 returns 999 999 999 across `l_Main` values, so both workers fire on every step (§18.6) | while a GM is in another dimension, every server step of a player or mob within sight sends an appear packet (+ last move + abstates) and a 0x1C0E both ways: 374 KB to the GM in 20 s near a mob group, 136 appear / delete pairs to the other player | set the slanted-list layer as well (or test `l_Main` in the range query), and re-enter the map (`so_ExchageBriefInfo`) after the change |
| P02-B28 | WM `CParserClient::fc_NC_CHAR_LOGIN_REQ` @ FUN_00422be0 → client 0x1110 (W01 §4.2) | `CSendPacket::ID(&p, 0x1110, 1, NULL)` declares a 1-byte payload and writes none (§18.7) | one stale WM byte (0xD5) in every tutorial popup; the client reads no payload | payload size 0 (PROTO struct empty), as P02-B2 |
| P02-B29 | zone `ShineMobileObject::so_Shout` @ FUN_00459080 → 0x201F (Z02 §3.2); WM whisper 0x200D (W04 §2.1) | `smo_Shout` writes only bits 0 / 1 of `flag`; bits 2–7 keep the shared buffer `gpp` byte (0x78, 0x74 captured). The WM's 0x200D flag has bits 1–7 from the stack (0x54, 0x04; W04 states it without an ID) (§18.4) | stale bits on the wire; both clients test only bits 0 / 1, so no visible effect | write the whole byte (`flag = GMColor + (isMob << 1)`) |
| P02-B30 | zone ITEMDB requests: `ac_ClearInventory` @ FUN_0041bbd0 and the `sp_DestroyItem` family (Z18 §4.4; `sp_DestroyItem` @ FUN_00527870 itself on the per-minute expiry, §21.2) → 0x3459; `sp_NC_ITEM_SPLIT_REQ` @ FUN_00539a40 → 0x3434; `ItemInventory_ii_DropAll` @ FUN_00529a70 → 0x3416 | 0x3459 without bit 7 leaves payload +9…+22 (`itemID`, `key`, `attrOffset`, `inven`) unwritten; 0x3434 leaves `lotcreate.attr` (+62) unwritten; 0x3416 copies the cell's whole 101-byte attribute union, of which a lot item uses 1 byte (§19.2–§19.4, §21.2) | earlier `gpp` contents (text of other packets) and zone heap bytes reach the Character DB on every `&cleariv` / destroy / expiry / split / drop and come back in 0x3417; the Character server reads only the valid parts *(inferred from D03 §3.3 / §3.4 and Z18 §4.4)* | zero the fields (or the send buffer) before filling; copy only the class's attribute length |
| P02-B31 | zone `ShinePlayer::InteractWithNPC` @ FUN_004c4660 (Z02 §6.2) with `sp_NC_ITEM_REPURCHASE_REQ` @ FUN_00538580 / `so_ply_CanItemRepurchase` @ FUN_005379f0 | clicking another NPC while a shop is open replaces `sp_NPCProcess.npc` without `sp_EndOfTrade`; when the new role cannot open (`NPCRole_MenuOpen` with menu bit 0 still set by the shop) nothing is sent, so the client keeps the shop window; every buy-back then fails `so_ply_CanItemRepurchase` and gets `0x305A {0x3671}`, a code the client shows no text for (§20.2) | the player cannot buy back (19 silent refusals in `s21` after an Anvil click next to the Blacksmith) | end the old trade (or refuse the click) before replacing the NPC, and answer a refused buy-back with a code the client shows |
| P02-B32 | zone `ShinePlayer::so_ply_SellItemList_Insert` @ FUN_00537a20 with `CSellItemManager::simg_Insert` @ FUN_0050e360 (found in the batch-3 review) | the sold item enters the buy-back list first; `0x305D` (the entry `simg_Insert` evicted from a full list, handle in its out-parameter) and `0x305C` (the new entry) both go only when `so_ply_CanItemRepurchase` (vt 0xe6c) holds, so a sale at a merchant without buy-back (SoulStone / Skill / WeaponTitle / Guild) changes the server's list silently (§20.2; read, not captured) | the client keeps a buy-back entry whose handle the server has reused or dropped; a later buy-back of it at a Weapon / Item merchant names the wrong item or none *(inferred)* | send `0x305D` whenever an entry is evicted, or insert into the list only where buy-back is allowed |

Other items' bugs the captures show on the wire (no new ID; owner's register entry stands):

| ID | Captured evidence | § |
|---|---|---|
| L00-B5 | `0x0C05 bSuccess = 1` on every XTrap key | §3.2 |
| Z07-B7 | 0x1802 `Wizdom` stale; also in each 0x240C `newparam` (batch 2) | §5.3, §9.4 |
| Z18-B10 | 0x1C05 `nSlotNum` = 0x74 in all 7 (stale) | §5.2 |
| Z18-B19 | 0x10E4 / 0x10E7 / 0x10EA `chrregnum` stale, different per login | §5.2 |
| Z09-B54 | 0x2011 `unk` never written (values 1 / 2 are buffer leftovers) | §5.2 |
| Z02-B2 | mob `moveattr` = stale `gpp` bytes with bit 0 cleared | §6.3 |
| Z09-B13 | no visible effect while the broadcast buffer is not full (0x1C0E reaches the mover) | §6.3 |
| Z05-B2 | unequip answered with `0x3011 0x281`, no `0x3013` | §8.1 |
| D03-B8 | 0x3446 = 17 bytes + 3 stale (zero) bytes | §7.6.1 |
| D03-B11 | 0x0446 map name "Need" | §7.6.1 |
| D02-B13 | 0x109A `Error 0x1200` in both captures (never written) | §7.6.1 |
| L00-B3 | `s37` 805.9 s: 0x0C10, 0x0721, 0x0C0D and the WM's `0x0C0E ok 1` before `0x0C0C {5}`; the client does not connect | §16.1 |
| P02-B5 | `s37`: the OTP path (0x0C37) leaves other stale header bytes than the password path | §16.1 |
| Z01-B2 | 0x0802 `echo_data` of the zones: 17 different values over 48 links, the WM's own 0x0802 carry 0 | §17.2 |
| Z30-B8 | 0x7446 payload byte 0x11 in all 8 = the preceding 0xA419 `nMapCount` (17) left in `gpp` | §17.4 |
| Z09-B72 | 0x207D `sScriptMsgIndex` "E_Olympic_A04" + 18 heap bytes, different per start | §17.4 |
| W04-B43 | WM → CharDB 0xA41A once per WM start, no answer | §17.4 |
| Z02-B3 | `s14` 416.929 / 493.861: after a player's 0x1C01 for the other player, the requester's 0x1C19 goes to the other player; the requester gets none | §18.2 |
| W04 (0x200D flag, no ID) | bits 1–7 stale (0x54 / 0x04), joined into P02-B29 | §18.4 |
| D03-B11 | `s21`: 0x0447 and 0x0456 map "Need", x / y 0 (the split log 0x0457 carries the real map) | §19.3, §19.4 |
| D03-B6 | `s21`: 0x3439 = ref + one unwritten byte (`0x10`) | §19.2 |
| Z04-B4 | `s21` 447.1: a part-stack drop answers `0x3008 {0x303}` without a menu | §19.4 |
| Z11-B12 | `s21`: 3 `&makeitem` with a full inventory send nothing and show nothing | §19.2 |
| Z11-B32 | `s21` 142.9: `&getmoney` → `0x300A {itemid 0, lot 0, 0x341}` (nothing picked since login) | §19.2 |
| Z11-B30 | `s21` 135.642: `&levelup 25` of a GM passes level 20 and sends the world announcement 0x6401 → 0x6402 to every client | §20.4 |
| Z09-B72 | `s21` 146.087: the WM relays 0x207D unchanged as 0x2079 to both clients, the 18 stale bytes included | §20.4 |
| P02-B16 | `s21`: every 0x305C carries the bytes of the 0x3001 and the 0x3425 built just before in `gpp`, then older text | §20.2 |
| Z04-B6 | `s21b` 17.213 / 22.337: `0x3004 {0x206}` (BUYALL DB error) shows no text: 0x206 is the switch's default case in `On_NC_ITEM_BUY_ACK`; 0x208 (BUYLOT DB error) is silent the same way (not in Z04-B6's list) | §21.1 |

## 13. Discrepancies per work item

Every owner below is `**State:** done`; nobody reopens them. The full rows (old statement, correction, evidence) are in
`docs/knowledge/P02.md` "Corrections"; X01 (contradictions register, plan "Corrections between items") collected
them, but X01 (done) integrated only batch 1 into `docs/pseudocode/README.md` §5 / §6. **X04** (added by P02, batch-3
sweep, `docs/plan/items/X04.md`) carries every row marked "→ X01" that README §5 does not hold yet and every row marked
"→ X04" into the README. Rows owned by X02 (done) go to **X05** (added by P02, X02's recurring re-run:
`docs/plan/items/X05.md`).

| Owner | Where | Discrepancy | Status |
|---|---|---|---|
| P01 / L00 (README) | `README.md` §1.4, §2 | zone seed is sent on accept; no client `0x0806` | contradicted → X01 |
| P01 / L00 (README) | `README.md` §1.5 | heartbeat runs server → client (`0x0804`), client answers `0x0805` | contradicted → X01 |
| L00 | `login-server.md` §4 (0x0C37), §5.1, §5.2 (0x0C16 broadcasts) | Login → WM 0x0C16 is 10 bytes (6 unwritten bytes + `usrregnum`), not `{u32 userNo}` (P02-B5, batch 2) | corrected → X01 |
| L00 | `login-server.md` §5.2 (0xC801) and its bugs table L00-B6 | 0xC801 `UserIP` is filled (`"172.16.42.231"`); L00-B6 is not a bug | contradicted → X01 (drop L00-B6 from the register) |
| D01 | `D01-account.md` §4.2 (0x080A "WM every interval") | the WM sends `0xC811` + `0x080A` only as the answer to AccountLog's `0x0809`, which `CStatistics::Process` @ AL:FUN_004064b0 sends on each minute change (P02-B6 for its byte) | corrected → X01 |
| W04 | `W04-social-misc.md` §8.2 (0x7037) | the client sends 3 bytes more than `1 + 7n`; the WM forwards only `5 + 7n` | extended → X01 |
| D02 | `D02-character.md` §4 steps 21 / 22 (0x0844, 0x10CA) | "zeros on error": both are sent only when the procedure returns a row; on error or no row nothing is sent (batch 2, §7.4) | corrected → X01 |
| D02 | `D02-character.md` §3.2, §4 step 6, §12 | `dKQDate` bits 30–31 (P02-B7), 0x100B 4 extra bytes (P02-B8), 0x10EC `AttendanceArray` uninitialised (P02-B9) | corrected → X01 |
| D02 | `annotations/D02.json` 0x10D2 | annotates only the CharDB→Zone free-stat ack (15 bytes); the character load sends a 17-byte single-option block under the same opcode (§7.4) | extended (P02.json `packets.wm` 0x10D2) |
| W01 | `W01-core.md` §4.2 (0x1004, 0x1036); `annotations/W01.json` | 0x1004 `time` = gamble reset time (`GB_ResetTime`) − 1 day, not a day start; 0x1036 `u32 extra[5]` = `char spawnapps[20]` | corrected → X01 |
| W01 | `W01-core.md` §6.3 ("copy `payload+2 .. end`"), §7.4 (0x4013) | the CharDB blobs are `len − 2` bytes from payload + 2 (2 past the end, P02-B10); 0x4013 stores 4 past the end (P02-B11) (batch 2, §7.5.3) | corrected → X01 |
| W01 | `W01-core.md` §7.2 (0x101C send order) | 0x1029 / 0x1098 go between 0x1028 and 0x102A; 0xCC0C comes before 0x441D; `zoneHandle` + 0x441D come before 0x1115 / 0x111F / 0xD412 / 0x1122 (§7.5.2) | corrected → X01 |
| Z01 | `Z01-core.md` §8.4 (`ws_save2worldmanager` list; "who calls the save … link, logout") | the list misses 0x4010, 0x4012, 0x4021, 0x402A, 0xBC1D, 0x402C, 0xCC0B, 0x4032, 0x4033, 0x4034, 0x4036, 0x4037 and every send condition; its only caller is `so_LinkTo` to another zone (logout and the 6-s save go to the CharDB only); level-ups send 0x400E alone via `ws_savelevel2worldmamager` (batch 2, §7.5.4) | extended → X01 |
| Z01 | `annotations/Z01.json` 0x180C `always99` | the byte is the GameLog store type: the WM copies it into 0x040F `StoreType` (99 = map link; 2 = zone link and 8 = level-up in 0x0410) (§7.5.4) | extended → X01 |
| Z01 / W01 | zone link round robin (Z01 §1 `SessionPool_Pick`), WM `CParserZone` (W01 §7.4 / §7.5) | per-character updates reach the WM out of order (P02-B12) | corrected → X01 |
| W03 | `W03-guild.md` §6.4 (0x987A) | `BuffName` carries 17 stale bytes after the NUL (P02-B13) | corrected → X01 |
| Z13 | `Z13-objects.md` §2.8 (`so_SaveItem_Part`, "boxes 12 and 15 increment before the send") | described there without a bug tag; captured (`PacketOrder` 0x80, 0x80, 0x81, 0x81); registered as P02-B14 | confirmed; bug → X01 |
| P01 / L00 (README) | `README.md` §2 | missing: 0x0C04/0x0C05, token-login order, 0x0C1B poll, 0x080D game time, WM option pushes, zone blob copies, map change, logout (§11) | corrected → X01 |
| L00 | `login-server.md` §8 | client sends its login request before 0x0C04 | corrected → X01 |
| L00 | `annotations/L00.json` 0x0C37 | token is `char[32]` | corrected (P02.json overrides) |
| D02 | `D02-character.md` §3.2 | `delinfo` +0x28..+0x2B uninitialised (P02-B1) | contradicted → X01 |
| W01 | `W01-core.md` §7.3 | 0x182A byte never written (P02-B2) | corrected → X01 |
| W01 | `W01-core.md` §6.1 | AVATAR `shape` = race / class / gender ids, hair / colour / face table ids | corrected (inferred → captured) |
| W01 | `W01-core.md` §5.1 | 0x0C18 mode 0 also = back to the world list | corrected → X01 |
| W04 | `W04-social-misc.md` §9 | 0x7C07 arrives in the game scene | open item answered |
| W05 | `W05-process.md` §2.2 | 0x0849 has `tm_sec = 0`; no drift | contradicted (inferred claim) → X01 |
| P01 | `pcap_decode.py` | annotation dirs `X→C` / `C→X`; struct-array, `bytes`, nested and inline struct types | fixed by P02 (parts 2 and 5, §15) |
| P01 | `annotations.json` zone 0x1802 | pdb2016 layout replaces the `?` blocks | corrected (P02.json overrides) |
| Z01 | `Z01-core.md` §6 | `sp_ConnectFromWhere` sends a notice, not WM 0x082A | contradicted → X01 |
| Z01 | `Z01-core.md` §6 | tail of 0x1803 is conditional (P02-B4) | corrected → X01 |
| Z01 | `Z01-core.md` §6 | burst senders named in §5.1 | added |
| Z02 | `Z02-actions.md` §2.2 | `so_SendSpeedInformation(1)` sends only on a change | contradicted → X01 |
| Z02 | `Z02-actions.md` §5.2 | 0x1C0E is sent (already corrected by Z09 §9.6) | confirmed correction |
| Z02 | `Z02-actions.md` §6.2 | Gate_Town NPCs (MiniMapIcon 23): no 0x201D, town-portal window | corrected → X01 |
| Z04 | `Z04-items.md` §8.3 | 0x302D trailing byte (P02-B3) | corrected → X01 |
| Z15 | `Z15-quest-engine.md` §5.6 | 0x441E values are `time_t` period starts | corrected → X01 |
| Z04 | `Z04-items.md` §2.1 (0x340A `+0x2c attrLen`), §5.1 (0x3410 `+0x14 u8 bind`) | the u16 is the byte offset of the attribute in the payload (68; 44 in 0x341C), not a length; `bind` is 4 bytes (offsets right) | corrected → X01 |
| Z05 | `Z05-itemdb.md` §1.4 (ItemSell → 0x305C), §7.1 (0x3C08) | fixed-length 0x305C with 100 stale bytes (P02-B16); 0x3C08 one stray byte (P02-B17) | corrected → X01 |
| D03 | `D03-character-items.md` §3.4 (PICKALL → 0x0446 `{ owner, "Need", key, 0, itemid }`) | x, y and `iteminven` are never written (P02-B15); annotation 0x340A `attr` SHINE_ITEM_ATTRIBUTE (101 fixed) is a variable tail | corrected (P02.json override) → X01 |
| S01 | `pdb2016-layouts.json` 0x3411 / 0x3414 / 0x3423 / 0x3429 / 0x3428 | the CharDB ↔ zone packets carry the 6-byte `NETPACKETZONEHEADER` before the PDB struct (8 / 34 bytes) | corrected (P02.json `packets.zone`) |
| P01 | `pcap_decode.py` with the annotations | `ITEM_INVEN` and `MAPPOS` had no struct entry, so every field of these types decoded as 1 byte | fixed by P02 (part 11, P02.json `structs`) |
| Z03 | `Z03-combat.md` §3.2 (0x2448 flag), §7.1 ("death reaches clients as SWING_DAMAGE flag bit1"); `annotations/Z03.json` 0x2448 | flag bits are 0 ← ctx+0x10, 1 ← ctx+0x14 (`isresist`), 2 ← +0x11 miss, 3 ← +0x13, 4 costume, 6 ← +0x15, 7 ← +0x16, second byte bit 0; no dead bit is written (`isDead` = bit 5, P02-B18); the client takes death from `resthp 0` (batch 2, §9.2) | corrected → X01 |
| Z03 | `annotations/Z03.json` 0x240C (`struct`), 0x2452 (`struct[targetnum]`) | types the decoder cannot read; the pdb2016 layouts fit (235 bytes, 5 + 14 n) | extended (decoder falls back to pdb2016, §15) |
| Z03 | `Z03-combat.md` §5.6 (`sds_Finish` SkillDamage flag) | the second flag byte keeps uninitialised stack bits 3–7 (P02-B19, `sds_TemplateStore` @ FUN_005803c0) | corrected → X01 |
| Z09 | `Z09-world.md` §28.12 (hunt log "flush … on logout") | the flush in `so_Unmark` needs mode ≠ 0, so a link to another zone drops the log (P02-B20); same-zone links (revive) flush it | corrected → X01 |
| Z04 | `Z04-items.md` §13.2 ("broadcast 0x500B") | the user's own client gets no 0x500B / 0x500C; the heal reaches it as 0x240E / 0x240F on the next tick | extended → X01 |
| Z01 | `Z01-core.md` §8.4 (0x4001 "u32 saverSeq or charNo…", 0x401A `{ u16, u32 }`) | the u16 after the ref is `handle.bufferlocation` = `ws_savestorepoint`, always 0 (P02-B21); 0x401A = `{ bufferlocation 0, chrregnum }` (§10.1) | corrected → X01 |
| S01 | `pdb2016-layouts.json` 0x4001 / 0x4002 / 0x4007 / 0x400B / 0x4018 | the zone ↔ CharDB saves carry the 6-byte ref before the PDB struct (111 / 12 / 14 / 14 + 9 n / 14 bytes) | corrected (P02.json `packets.character`) |
| D02 | `D02-character.md` §6 (0x400B `{ u8 type, u32, u32 }`) | pdb2016: `{ u8 Type, u64 TitleValue }`, same 9 bytes (§10.3) | extended → X01 |
| Z02 | `Z02-actions.md` §3.1 (`FUN_005cc2a0` "event 0x29, inferred: achievement/stat hook") | resets title 41 `ID_NOCHATTING_COUNT` (captured: 76 → 0 after a chat, §10.3); 0x2a of the shout = 42 `ID_BROADCAST_COUNT` *(inferred)* | corrected (inferred → captured) → X01 |
| Z12 | `Z12-stats.md` N ("who sends 0x4025 in the client was not traced") | the 2016 client's `On_NC_BAT_LEVELUP_CMD` @ FUN_004aa3d0 sends `{1}` when the inventory holds a Mystery Vault (§10.6) | open item answered → X01 |
| P01 | `pcap_decode.py` with the annotations | `SHINE_COORD_TYPE`, `ABNORMAL_STATE_BIT`, `STRUCT_QSC` had no struct entry (Z09 / Z13 / Z08 annotations decoded them as 1 byte or fell back to pdb2016) | fixed by P02 (part 13, P02.json `structs`) |
| L00 | `login-server.md` §4 (0x0C0B: "Send 0x0C0C { status, zeros… }, only status filled") | the refusal also carries `wm_ip` / `wm_port` from `ServerInfo.txt` and 64 uninitialised bytes (P02-B23, batch 3, §16.3); L01's `GetWorldManagerConnectInfo` block is right | contradicted → X04 |
| L01 | `L01-process.md` world-status table (6 = "WM connected") | the WM's first 0x0808 in the handshake ms is `{0, 0}`: the world turns 5 (full) at once and stays so until the next 0x0808 30 s later (P02-B22, §16.3) | extended → X04 |
| L01 | `L01-B11` (Login heartbeat before the login request) | not reachable with the 2016 client: it opens the Login connection only on submit and polls 0x0C1B every 10 s (§16.2) | reach limited (captured) → X04 |
| D01 | `D01-account.md` §4.1 (0x0720: "failed logins store the typed password") | the stored 16 characters are the first half of the client's MD5 hex string (`0x0C5C sPassword`), not the typed password (§16.3) | corrected → X04 |
| W01 | `W01-core.md` §4.1 (0x1407 → 0x1408; 0x1405's "u8 ?") | 0x1407 sends 0x1413 (W03 §4.5 already says so; captured); the byte is `numofavatar` (1) | confirmed W03 → X04 |
| W04 | `W04-social-misc.md` §12.4 (0x9425 "asked by OPTool 0x281F") | every character delete asks it too (`AvatarErase` from CharDB 0x140B, §16.1) | extended → X04 |
| X02 | `capture-scenarios.md` §3.37 step 1 / prediction (1) | the login screen holds no connection, so a 70 s idle there tests nothing (§16.2) | reach limited → X05 |
| W05 | `W05-process.md` §1.3 ("the last answer 0x9806 sets state 1") | 0x9805 / 0x9806 run only on the rank-balance path; with `dAggregationDate` 0 (or a balance not due) the 0x9804 handler sets the CharDB link to state 1 (FUN_0040ccc0 / FUN_00441aa0, §17.3) | extended → X04 |
| W01 / W02 | `W01-core.md` §7.1 (0x180F `g_Zones.AddMap(map, zone, a, b)`), `W02-party-raid.md` §1.6 | a new map entry does not get `IsPartyReleaseMap`; only a re-registration stores it (P02-B26, §17.4) | corrected → X04 |
| Z01 | `Z01-core.md` §3.3 (0x0803 → 0x180F, 0xA419, 0x7446) | 0x180F / 0xA419 go out on every registering link; 0x7446 once per process (guard `gz_IsSendReq`, Z30's annotation) (§17.4) | extended → X04 |
| Z09 | `Z09-world.md` §1.5 (`reconnectAt = g_Now + pool.reconnectSeconds · 10`) | the values: WM 20 s, GameDB 20 s, GameLog 600 s (`dynamic_initializer_for_'sock2gameDB'` @ FUN_0069afc0 and neighbours); captured 20.0 s; `sb_Routine` returns at the first entry not yet due (§17.4) | extended → X04 |
| S02 | `S02-library.md` §1.4 per-IP admission rule ("several zones started together … lose all but the first", *inferred*) | confirmed per zone: of 4 links opened within 2 ms the 1st and 3rd survive; tagged P02-B25 (§17.4) | confirmed + bug ID → X04 |
| Z11 / Z09 | `Z11-gm-commands.md` §3.1 `&dimension` ("objects of another main layer do not see each other" *(inferred)*), `Z09-world.md` §9.6 (the at-move workers' `dist²` test) | true for broadcasts (`AxialListPacketBroadcast`'s `l_Main` test; −1 = hears every layer); the at-move workers use `so_DistanceSquar`, which is 999 999 999 across `l_Main`, while the range query ignores `l_Main`: appear + delete on every step (P02-B27, §18.6) | extended → X04 |
| Z11 | `Z11-gm-commands.md` §3.1 `&show` ("the others see the GM again on their next sight exchange" *(inferred)*) | they see the GM after the **GM's** next move: its `0x201A` makes their client ask with `0x1C01`; their own steps do nothing (the exchanger skips objects already within range); `&hide`'s inform is the `0x242A` NOEFFECT form (§18.6) | extended → X04 |
| W01 | `W01-core.md` §4.2 (0x1001: "send 0x1110 (empty)") | 0x1110 carries one unwritten byte (P02-B28, §18.7) | corrected → X04 |
| Z13 | `Z13-objects.md` §1.6 (0x3467 `u16 attrLen`) | the u16 at +0x2C is the constant 0x2E (payload offset of the attribute block), not a length; D03 §7.1 `attr16` is right (§18.7) | corrected → X04 |
| Z02 | `Z02-actions.md` §3.2 (0x201F `flag = GMColor (bit 0), isMob (bit 1) = 0`) | bits 2–7 are not written (stale `gpp` byte, P02-B29) (§18.4) | extended → X04 |
| X02 | `capture-scenarios.md` §3.14 steps (2), (4), (6) and the `s14` notes | no walk and no sit on the wire (only runs and `stand`); the "name not online" whisper went to X14B with the text `X14Nobody` (0x200E not reached); the shout was never out of sight; notes "B saw A after B stepped" for `&show` and `&dimension 0` disagree with the wire (A's step for `&show`; no appear for `&dimension 0`) (§18.3, §18.4, §18.6) | reach limited → X05 |
| Z04 | `Z04-items.md` §4.2 (0x300D: "to cell not empty: 0x44c", "Invalid 'to' cell: 0x446"; 0x3434 "+0x42 u32 lot, +0x44 oldLot, 0x46 bytes") | occupied target → `0x446` (zone 0x53a047), invalid from / to → `0x445`; `splitlot` u16 @64, `MainLot` @66, 68 bytes (§19.3) | corrected → X04 |
| Z04 | `Z04-items.md` §6.3 (0x343E `+0x12 attrLen`) | payload offset of the attribute (20) (§19.6) | corrected → X04 |
| Z04 | `Z04-items.md` §3.3 (client 0x300A, inventory full `0x34a`/`0x346` *(inferred)*) | `0x346` "Inventory is full."; `0x34A` = KQ pick-up limit (§19.4) | extended → X04 |
| Z05 | `Z05-itemdb.md` §3.1 (owner-only time "looting / 100 s", "g_Now is in seconds") | 20000 → 19.95 s: `g_Now` counts 0.1 s, as Z09 §11.4 says (§19.4) | corrected → X04 |
| Z11 | `Z11-gm-commands.md` §7.4 (`&getmoney`: item id 0 *(inferred)*) | captured `0x300A {0, 0, 0x341}` (§19.2) | confirmed |
| X02 | `tools/capture/21` outputs of `s21` (snapshot / prep) | they list Test1235 (`nCharNo` 2), not the scenario's Test2: no D03 check (§19.8) | contradicted → X05 |
| Z04 | `Z04-items.md` §2.5 (0x3059: "`p.vt[0xe6c]()` (repurchase allowed, inferred) → 0x3671"; client 0x305A "otherwise Inventory is full.") | vt 0xe6c = `so_ply_CanItemRepurchase` @ FUN_005379f0: the current NPC is a Merchant with `RoleArg0` "Item" or "Weapon" (`nrb_CanItemRepurchase` @ FUN_004c7690); the client shows only `0x366B` / `0x366C` / `0x366D` ("Inventory is full."), every other code is silent (Z05 §2.2's table is right) (§20.2) | corrected → X04 |
| D03 | `D03-character-items.md` §2.4 ("No GameLog entry is written (the zone logs `0x0458 SOULSTONEBUY`)") | nobody logs a soul-stone purchase: no 0x0458 on the wire, and D05 finds no 2016 sender (§20.3) | contradicted → X04 |
| D03 | `D03-character-items.md` §5.1 (Log 0x045E / 0x045F `{ nUserNo, charNo, money, storageMoney }`) | `{chrregnum u32, money u32, userregnum u32, storage balance u64}` = D05's row (§20.1) | corrected → X04 |
| X02 | `s21` notes, step 9 ("sold all 4 potions individually", "bought back 1 potion and used it", "could not buy back stack of 3 (bug?)") | 5 sales (one from cell 0) and 2 single buy-backs before the use; the stack failed because of an Anvil click with the shop open (P02-B31), not because it was a stack (§20.2) | contradicted → X05 |
| Z04 | `Z04-items.md` §2.1 (client `0x3004`: "other codes (0x203, 0x204, 0x20e, 0x210) are silent", Z04-B6) | 0x206 and 0x208, the Character server's DB-error codes of BUYALL / BUYLOT (D03 §2.1), are silent too (the switch's default); captured for 0x206 (§21.1) | extended → X04 |
| Z04 | `Z04-items.md` §3.3 (`so_ply_PickupItem`: "IsLot → first stack with room") | room = `cell.lot + picked ≤ MaxLot` for the whole picked lot (no partial merge); a stack over `MaxLot` is never a target, and nothing checks it at login (§21.3) | extended → X04 |
| X02 | `capture-scenarios.md` §8.14 / §8.17 / §9.4 and the `tools/capture/21` S13 / S16 scripts | the runs used Test1235 (`nCharNo` 2) although the scripts name Test2; §8.14 confirmed (expiry at the first minute after login); §8.17 confirmed for item and cen, fame / coins untested (a cen-only item); §9.4's open X3 question answered: no check, no merge, a new cell (§21) | confirmed / extended → X05 |

In batch 1 (§3–§6) no discrepancy for Z03, Z07, Z09, Z11, Z12, Z13, Z16, Z17, Z18, Z22, W03: every statement of theirs that §3–§6 test held (batch 2's rows for Z03, Z09, Z12, Z13 and W03 are above). Part 12 (§9) confirms Z03 §3.1–§3.4 (swing
timing with the 0.1-s `g_Now` step, stop paths), §5.4 (cast, `IsMovingSkill` blast), §7.2 (death order, 0x104D, no exp
loss below level 20), §8.1–§8.3 (kill order, exp, level-up), Z07 §3.1 (revive city, 30 % HP), Z09 §5.4 / §7.4 (0x244A
from the mob tick, MobWeapon timing), Z12 §7 (level-up tail, fame), Z13 §7.2 / §7.4 (mover cast and summon order),
Z11 §7.3 (`&levelup` without exp), D05 (GameLog layouts) and W01's 0xC808. Batch 2 §7.5 also confirms Z01 §5.2–§5.3, Z07 §1.2–§1.4, Z09 §1.2 / §1.5, Z12 / Z13 / Z17 / Z28 blob layouts
(the trailing bytes are the WM's P02-B10 / P02-B11) and W05 §2 (0x441D). Part 10 (§7.5.4) confirms Z01 §7.1 (`so_LinkTo`, 0x180B / 0x180D / 0x180E, the same-zone branch), the
Z03 / Z12 / Z13 / Z15 / Z16 / Z23 / W04 layouts of the saves, Z08 §4 (no 0x580E from a zone without the map, Z08-B8) and
§8.2 (0x7496), W03 §3.5 / §6.4 and W04 §17.5 (0x1120 after the first 0x180C only), and Z18 §6.2's use of title type 9. Part 11 (§7.6.1, §8) confirms Z02 §6.5 (shop lists), Z04 §2–§7, Z05 §1–§7 (lock
indices, both commit styles, the money releasers), Z09 §11.3 (0x1C0A looting bit), Z13 §7.2 / §7.4 (mover use and both
forced dismounts, `so_LinkTo` dismounting before `ws_save2DB`), D03 §2–§5 (answers before logs) and D06 §5.2 (0x34CF). Part 13 (§10) confirms Z01 §6 (0x10B3 first, 0x1080) and §8.4 (`ws_save2DB` order and
conditions), D02 §6 (12-byte save headers, ACKs only for 0x4001 / 0x4007, 0x401A / 0x4035 without a ref, 0x4027 /
0x4028), D02 §7.1 / §11 (0x10B4; 0x1081 `0x12E2` for a single), Z07 §1 (an erroneous 0x1081 is not forwarded), Z02 §2.5 /
§3.1 / §6.2 / §6.3, Z15 §3.3 / §3.4 (SAY with the clicked NPC), Z12 §5.2 (0xBC05 cap), Z13 §8.2 / §8.3 / §8.6 / §8.7 /
§8.10 (summon order, hunger, speed formula, 0x1C1A), Z09 §5.4 (10-s corpse) and D05's GameLog layouts (0x040A, 0x040F,
0x0410, 0xC806, 0xC809). The sweep (part 14) confirms Z02 §6.4 (the client's `0x200B` in the tick of `0x304D` runs `sp_EndOfTrade`,
which clears `AccountStorage_opened`) and Z18 §6.2 (title type 9 rule; `CT_LevelUp` re-marks type 9 on every level). Part 20 (§20) confirms Z04 §2.4 / §7.1 / §13.1, Z05 §2.2 / §2.4 (answer orders, `0x305D` before `0x305A`), D03 §2.2 / §2.4 / §5.1 layouts (with the ref), Z02 §6.5 (`0x3C05`), Z11 §7.3 (`CT_LevelUp`, the level-20 announcement), Z18 §6.2 (titles 46 / 0 and 1), W01 §7.6 (0x6401 relay), W04 §2.4 (0x2079 relay) and §6.2 / §6.4 (KQ skip: 0x5811, 0x5825, one 0x581E per client per second). Part 21 (§21) confirms D03 §1.2 / §2.1 (`ItemBuy_Create`'s attribute branch: item deleted, cen refunded, `0x340C {0x206}`), Z05 §2.1 (`0x340C` → `0x3004 {error}`) and §6.4 (`0x345A` → `0x3001` emptied), Z09 §1.2 / §2.4 (the per-minute block on the WM's `0x0821`), Z24 §6.7 / Z13 §2.7 (`sp_ChargedItemLimitCheck` → `sp_ItemDelete` → `sp_DestroyItem`, not at login), D03 §1.3 (boot option rows 800–803 / 820–822, `deletetime` at attribute +7) and the capture-scenarios predictions §8.14 (S13) and §8.17 (S16, its cen half).

## 14. Not reconstructed / uncertain

- **0x0849 / 0x080E clock offset**: the capture PC and server clocks differ by a few tens of ms, sign varying between
  captures (§4.2, §4.3); a capture with the server's own clock (or NTP on both) would pin the send to the second.
- **0x7C07 timing** (§4.1): the short form is sent in the 0x7C06 handler, yet leaves 73–74 ms after 0x7C06 together with
  the CharDB-backed 0x700D. Batch 2 explains it *(inferred)*: the passes do sleep in normal operation (W05-B1 sleeps
  only while the CharDB link is in state 1, which is the normal state; ≈ 15.6 ms per pass measured in §7.4), the client
  session gets one packet per pass (0x7004, 0x700C, then 0x7C06 in the third pass), and Nagle (S02 §1.4, no
  `TCP_NODELAY`) holds the 0x7C07 segment until the client ACKs 0x7005 (6.833 s), so 0x7C07 and 0x700D leave together
  at 6.885 s. The same 47–52 ms hold appears after 0x1003 (§7.4). The batch-1 reading "the passes do not sleep" was wrong.
- **Per-minute phase** (42 s past the minute on every zone process): **settled** in batch 2 (§7.5.3, 0x0821). The
  zones' per-minute block runs when the WM's 0x0821 arrives (Z09 §1.2), and the WM sends it on its own 60-s timer
  (W01 §2), at :42 in both batch-2 captures. Only the phase of that timer (WM start or the last forced send on a zone
  connect) is left *(inferred)*.
- **Client `World::LoadMap` heartbeats** (§4.4): which of the 8 call points fire per map load *(not traced)*.
- **World name "Enid"** in the scenario notes (§3.2): not in the 2016 client or its texts; unexplained.
- **0x7037 trailing 3 bytes** (batch 2, §4.2): the client sends `1 + 7n + 3` bytes for `n = 1`. The 2016 client sender
  was not located (the 2017 `ShortCutMgr` send functions are empty stubs; the sweep found no `0x7037` immediate in the
  2016 client, as `push`, `mov word` or decompiled constant, nor any of the other captured option-save opcodes 0x7011 /
  0x7015 / 0x703B: the option sends build their opcode another way), so it is open whether the tail is `+3` or `+3n`
  *(a capture with n ≥ 2 settles it)*. The WM drops it either way. The decoder now reads the captured form through a
  variant layout (§15).
- **Title value type 9** (batch 2, §7.4 0x1019): `TitleValues[9]` went 1 → 2 across `combat`, in which Test2 died once,
  but pdb2016 names 8 `ID_KILLED_BY_MOB` and 9 `ID_NOKILLED_BY_MOB`. Either the zone counts deaths under 9 or the
  value changed for another reason. **Settled** in part 10 (§7.5.4): `CT_KilledByMob` @ FUN_005cbdd0 adds 1 to type 9 on
  every death (the death counter). Type 8: **settled** in part 12 (§9.5): `InitNewPlayer` @ FUN_005ca620 sets
  `m_KilledByMobTimeValue` to the zone-login time, and the death came 48 s after the RouCos02 login (< 180 s).
- **0x10D2 single-option columns** (batch 2, §7.4): `usp_Character_getSingleOption` returns (u8, u8, ts, u32); the
  field names in P02.json are ours. The timestamp equals the 0x101A `dKQDate`: both look like "last save" times
  *(inferred)*.
- **Link-to-process mapping** (batch 2, §7.1): settled in part 9 (§7.5.1): `SocketBundle<…>` `sb_SocketStr[4]`, one
  round-robin pick per send. Which of the 4 WM links carries a zone's broadcasts (the last to register) is *(inferred)*; part 10 (§7.5.4) shows
  it is not a fixed `sb_SocketStr` index.
- **Account-storage flags after 0x304D** (§8.1): **settled** in the sweep. The NPC open sets `p+0x5cb8` bit 4
  (`sp_MiscFlag.AccountStorage_opened`, `nOpenType 0`, Z05 §7.1) and the close command clears only bit 5 (Z04 §7.3), but
  the client sends `0x200B NC_ACT_ENDOFTRADE_CMD` in the same tick as `0x304D` (`shop` 57.055, 0x200B first).
  `sp_NC_ACT_ENDOFTRADE_CMD` @ FUN_004c4a60 (`cmc_AllowMode 0x46` = modes 1, 2, 6) calls `sp_EndOfTrade(p, 1)` @
  FUN_004c25b0, which, with an NPC set, runs the role's `nrb_EndOfTrade`, resets the server menu, clears
  `AccountStorage_opened` and the NPC handle and closes the guild storage (Z02 §6.4, confirmed). So bit 4 does not stay set after a
  normal close. A client that sent only `0x304D` would keep it; the client never does that in the captures.
- **Character server's GameLog link** (§7.6): identified by content (D03 logs only), and the 34–52 ms client delays
  after a CharDB answer by the Nagle reading of §7.5.4 *(both inferred)*.
- *(inferred)* items carried from parts 1–4: the 0x112C range broadcast excludes the sender (§5.1 #12); 0x2011 `unk` values are buffer leftovers (§5.2); the
  client ignores the 0x302D trailing byte (§5.3); AVATAR KQ fields keep the last saved position (§4.3).
- **Client sends after a mob-tick event** (batch 2, §9.5, §9.6): at the player's death and the skill kill the GameLog
  / WM link packets leave 18 / 27 ms before the client packets of the same event (one frame), while swing kills in the
  player tick send both in one ms. Reading: client packets are queued in the player's game socket stream and flushed
  at a later point of the pass than the link sends *(inferred; the flush point was not traced)*.
- **0x500B / 0x500C** (§9.6): settled in §10.4. The u8 argument of `so_AllOfRange` decides whether the source gets its
  own broadcast (1 chat, 0 soulstone / change mode). The sweep read the implementation, `so_AllOfRangeNomal` @
  FUN_0054c900: a final `iterator(source, source, 0)` when the u8 is ≠ 0 (§10.4).
- **Title type 9 `ID_NOKILLED_BY_MOB`** (§10.3): it goes out unchanged (2) with every level-up save. **Settled** in the
  sweep: `CT_LevelUp` @ FUN_005cc2f0 marks type 9 for saving and re-checks it on every level-up (§10.3). Its name says
  "not killed by a mob". `CheckNewTitle` @ FUN_005cb5f0 (Z18 §6.2) gives the rule: type 9 unlocks "reach level V
  without dying" only while its value (the death count) is 0. Test2's value 2 blocks it, and the zone still saves
  the unchanged 2 on every level-up.
- **Client 0x4025 second sender** FUN_004a59d0 (§10.6): **settled** in the sweep. Its two callers send `{btMysteryType 0}`: the item-use path FUN_006a2b30, only once the level requirement is met
  (`Inventory::FindMysteryVault` finds the used slot and its item's level field `+0x7f` ≤ `User::Lv`), and
  FUN_00553a10, a window button handler, whenever `param_1 == 1` and the frame exists: its level check
  (`this+0x174` ≤ `User::Lv`) gates only `OpenInventoryWin`, not the `CloseRaidMemberAddWin` + `FUN_004a59d0(frame, 0)`
  that follow (review fix). FUN_00553a10 is probably the 2016
  `MysteryVaultWin::OnMysteryVaultBtnClick` (2017 @ 0x559560, next to `MysteryVaultWin::Create`) *(inferred)*. So
  `1` = "vault level reached" (level-up) and `0` = "vault opened". Both callers first call the frame method that
  `names/client` labels `CloseRaidMemberAddWin`. That label is doubtful here: the 2017 `CloseMysteryVaultWin` would fit
  *(inferred)*. Not captured (no vault use in batch 2).
- **Quest SAY bytes** `Data+0xC = 7`, `+0x10 = 1` (§10.5): not identified (Z15-B11 says they are leftovers of earlier
  commands of the script).
- **`hpchangeorder` steps** (§9.1): the counter advances by 2–3 per hit; the extra reads were not traced.
- **Not captured at all** (after batch 3): party / PvP / guild-war deaths (0x0429, 0x244A WM, 0x2411 exp loss), skill
  failure and cast abort, trade, booths, party, guild, KQ joins (batch 3 has only the WM's minute skips 0x5811 / 0x5825 /
  0x581E, §20.4), most item failure paths (batch 3 has 0x300E {0x446}, 0x3008 {0x303}, 0x3016 {0x713}, 0x3013 {0x2C2},
  0x305A {0x3671}, 0x340C, §19–§21; the others are in the §15 X05 rows), other failure paths (0x0C15, 0x1002, 0x1804,
  0x0C66, …; lists in §3.2, §4.2, §5.2). Batch 3 captured the bystander packets (0x2449, 0x244F, 0x240D, 0x500B /
  0x500C: §18.5, §20.3, §20.4) and chat (shout, whisper: §18.4). The statuses of the rest stay **never seen** until
  X05's scenarios are recorded.
- Batch 3, login side (§16): the cause of P02-B22 (client capacity 0 until the client listener opens) is inferred
  from `BootstrapTick`'s order, not from a writer of `DAT_00556bb8`; `closeReason 0x780` on the 0x0C33 path (no
  handler on it sets the field) is taken to be the value left from before *(inferred)*.
- Batch 3, server start (§17): why the first WM start of `s37` stopped 1.09 s after its CharDB load (listener failure
  or an operator stop, §17.6) needs the WM's `Msg` log of 729–731 s; the 6–9 s between a zone's link handshakes and its
  first main-loop pass (from the first-retry delay) is *inferred* (data loading), not read; that a WM restart under
  running zones brings no new 0x7446 is read from the guard, not captured; zone 3's 255 maps were not checked against
  `World/Field.txt` (the count is the zone's `FieldMap` list, `fc_MapRegist` has no cap).
- Batch 3, second client (§18): the notes say B saw A again after B stepped (after `&dimension 0`), but B received
  no appear packet for A until A's `&linkto`. Either the client builds an object from the stray `0x1C19` (Z02-B3) or
  the tester saw something else; the client's 0x1C19 handler FUN_004a5560 was not read for unknown handles. Why
  each step yields exactly three appear / delete pairs (`mm_Step` sub-steps per tick) is *inferred*. Which field
  makes `vt 0xef4` (zone GM colour) and the WM's `bIsGM` 0 for an admin-level-100 character (an account flag, not
  `nAdminLevel`, *inferred*) was not traced. The mushroom house's attribute `ffecbb76` (0x3449 at the first
  per-minute block) was not decoded. `g_ShoutLevel` is bounded only (1 ≤ value < 120).
- Batch 3, items I (§19): B's refused pick-up attempt sent no 0x3009, so the client checks the pick right itself;
  its drop object (`FUN_00610fc0`, built by the 0x1C0A handler FUN_00499900) was not read. The 0x3014 text condition
  (picker in the client's expedition list, FUN_006f7e30) is read from the call only. Which of drop, pick-merge, drop
  and destroy menu took the lock indices 14–16 was not traced (one of the four took none). The SQL snapshots of `s21`
  are of another character (§19.8): the D03 side of scenario 21 is checked only on the wire.
- Batch 3, items II (§20): that freed repurchase handles are not reused at once is read from the wire only (the
  `CSellItemManager` allocator, vt +8 / +0x18 of its pool, was not read; `simg_Initialize` @ FUN_0050e1b0 caps a stored
  list at 42). That a sale at a non-Item / Weapon merchant enters the list without 0x305C is read, not captured. The
  client's refusal of an HP stone at full HP (no 0x5007) was not read in the client. `hp.maxnum 100` / `sp.maxnum 114`
  were not checked against the class table row of level 33 (Z02 §6.5 formula with the factor 1000 assumed). Why the
  KQs skipped at each minute were scheduled then (KQ data) was not checked; `nrb_ItemSellPrice` of a non-Merchant role
  (what a sale from the open shop window does after the Anvil click) was not read.
- Batch 3, items III (§21): the cen refund of S16 is deduced from the next logins' DB balance; the debit and the
  `p_Char_MoneyAdd` are not on the wire, and neither are the Character server's log lines ("ERROR - …SetItemOptions").
  The error value `ItemAttr_Save` returned is unknown beyond "not 1" (0x206 maps every other value). Where the
  stale bytes 9–22 of the expiry `0x3459` come from was not traced. Not tried: using an expired item before the
  first minute check, an expired item that is worn (equipment, kind 8) or a ridden mount (skipped, Z24 §6.7), and the
  over-full stack's sell / use / move paths (§21.3). That the S13 / S16 scripts ran for Test1235 is read from their
  outputs, not from the scripts that ran.

## 15. Coverage boundary

P02 has no scope table (`coverage.py P02`: "no scope table; coverage does not apply"); its scope is every packet of
the processed captures, and every observed (server, dir, opcode) type has a status in §3.2, §4.2, §5.2 or §6.2
(batch 1) or §4.2, §7.3–§7.6, §8.2, §9.7, §10.8 (batch 2): 388 types over the seven captures, checked in the sweep
against the decoder output. Batch 3 adds 146 types (466 over its six captures, 534 over all thirteen), each with a
row in §16.4, §17.7, §18.8, §19.9, §20.5 or §21.4 (checked in the batch-3 sweep, part 22, by matching every new
(server, dir, opcode) of the decoder output against those tables).

Decoder gaps found in parts 2–4 (knowledge row "pcap_decode.py struct sizes", owner P01 = done) are small and fixed
here in `tools/protocol-re/pcap_decode.py` (part 5): dims `[]` = rest of the payload; `bytes` = rest of the payload;
struct names also match a unique nested `Outer::Inner`; inline element types `{u8,u8}`; `struct[count]` followed by
`name[i].member` fields is read as the element layout; a struct whose first field is `datasize` takes 1 + datasize
bytes per element (`PROTO_ITEMPACKET_INFORM`). `USEITEM_MINIMON_INFO` (pdb2016) is in `annotations/P02.json` `structs`.
After the fix the five captures decode with one warning left (0x7C07 short form, below); `--selftest` passes.
Review (part 6): `--out` creates its directory; `--selftest` now also covers every form above, `client_dir` and a
seed before the first client packet of a stream without SYN. `tools/protocol-re/packets.py` renders the `evidence`
block of `annotations/P02.json` as a **Captured** line under each packet of `packets-<server>.md` (all 92 entries), and
lists the four without a generated section (WM 0x1012, 0x1097; zone 0x0C18, 0x1C08) at the end of the page.

Batch 2 (part 8): link opcodes may have several annotations (0x10D2 CharDB→Zone and CharDB→WM); `load_docs` keeps all
of them in `link_alts` and `decode_packet` uses the first one that decodes the payload exactly. A parenthesised comment
in an annotation type (`tm (9×i32)[28]`, W04) is ignored; the `tm` struct is in `annotations/P02.json` `structs`.

Batch 2 (part 9): no decoder change. `annotations/P02.json` `packets.wm` annotates the WM → zone hand-over sends (dir
`WM→Zone`): ref + the zone reader's layout (Z12 / Z17 / Z28) with counted arrays and a trailing `overread` `bytes` field
(0, 2 or 4 bytes, P02-B10 / P02-B11), and the first layouts of 0x1031, 0x10CB, 0x10DD, 0xBC01, 0x1130. The struct
`PROTO_SELL_ITEM_INFO_SERVER` (pdb2016) is redefined there with `datasize` first (variable elements), which also
decodes 0x4037. After that every packet on the 32 WM links decodes without an issue.

Batch 2 (part 11): no decoder change. `annotations/P02.json` `structs` adds `ITEM_INVEN` (u16) and `MAPPOS` (20 bytes),
which no file defined (the decoder read both as 1 byte), and `MENUITEM`; `packets.zone` adds the ref-prefixed CharDB ↔
zone layouts 0x3411 / 0x3414 / 0x3423 / 0x3429 / 0x3428 / 0x341C / 0x341D and the shop lists 0x3C09 / 0x3C0B;
`packets.character` 0x340A replaces D03's fixed 101-byte attribute with a variable tail. After that every part-11
opcode decodes without an issue (issue types left: shop 9, combat 8, all of parts 12–13 or the known 0x7C07 / 0x7037).

Batch 2 (part 12): `decode_packet` falls back to the PDB layout (pdb2016 first) when a client-facing hand annotation
does not decode the payload exactly and the PDB layout does (`source` = `pdb2016 (annotation did not fit)`; selftest
case 0x240C). That fixes Z03's 0x240C (`struct`) and 0x2452 (`struct[targetnum]`); every part-12 opcode decodes
without an issue (zone issue types left: 0x4401, fixed in part 13).

Batch 2 (part 13): no decoder change. `annotations/P02.json` `structs` adds `SHINE_COORD_TYPE` (9), `ABNORMAL_STATE_BIT`
(99), `STRUCT_QSC` (0x65) and `CHARACTER_TITLE_DB_SAVE_VALUE` (ours: the PDB type is unnamed); `packets.character` adds
the ref-prefixed save layouts 0x4001 / 0x4002 / 0x4007 / 0x4008 / 0x400B / 0x4018. After that the only issue packets
left in batch 2 are the known WM 0x7C07 short form (both captures) and 0x7037 (`combat`, §4.2): shop 1, combat 3.

Batch 2 (part 14, sweep): an `evidence` entry in an annotation file may carry a `layout` (same field-list schema as
`packets`). `load_docs` collects these as captured variants per (server, opcode, direction). When a client-facing
hand annotation does not decode the payload exactly, `decode_packet` tries them first (source `annotation (captured
variant)`) and then the PDB fallback of part 12 (selftest case added). `annotations/P02.json` uses this for the two
W04 packets P02 cannot override (W04.json sorts after P02.json): WM `0x7C07` 4-byte short form `{err, nMinute}` and
`0x7037` `{n, SHORT_CUT_DATA[n], u8[3] tail}`. After that **all seven captures decode without an issue** (4 805 packets;
3 packets have no layout at all: zone `0x500A`, `0x2048`, `0x104E`, all empty and without an annotation or PDB entry; statuses in §9.7).
`packets.py` shows the variants through the evidence `fields` note (`layout`).

Batch 3 (parts 16–22): before part 17 the batch-3 decodes had issue packets in `s21` (135: the ITEMDB link packets
with the 6-byte ref or the item-transaction header the pdb2016 structs lack, `0x6401`, `0x3439`), `s21d` (22) and
`s37` (28: the arrays of `0x180F` / `0xBCD5`, size-1 empty requests) and `s14` (1: `0x1110`). One decoder change
(part 17): a PDB element type named `Outer::<unnamed-type-…>` is resolved (0x180F, 0xBCD5; selftest case). The rest
are `annotations/P02.json` entries: `packets.character` (the 1-byte WM → CharDB start-up requests 0x7456 / 7503 /
74BC / 9801 / 9805, and 0x3401 / 3402 / 341F / 3420 / 3425 / 3426 / 3439 / 343E / 3441 / 3442 / 3467 / 3468 / 346A /
34BB), `packets.wm` 0x6401,
`packets.zone` 0x3024 and the captured 1-byte variant of 0x1110. Batch-3 sweep (part 22): all thirteen captures
decode with **0 issue packets** (35 281 packets, 30 476 of them in batch 3); 11 have no layout, all empty: zone
`0x2024` ×7 (`s14`, §18.8), `0x500A` ×2 (§9.7, §20.3), `0x2048`, `0x104E` (§9.7); `--selftest` passes.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| 0x7C07 4-byte short form: the decoder warned "sReason needs 16 bytes" | resolved here (sweep) | W04 §9.2 (done) documents both forms; the decoder now reads the short form as a captured variant (`annotations/P02.json` `evidence.wm` 0x7c07 `layout`, paragraph above) |
| README §2 / §1.4 / §1.5 rewrite, Unknowns line "whether the zone also sends the seed unprompted" | **P04** (new, added by P02: `docs/plan/items/P04.md`) | README's owners P01 and L00 are done and X01 may write only `docs/pseudocode/README.md`; P04 corrects the README from §2 / §11 and the knowledge Corrections rows |
| WM → zone blobs never sent for Test2: 0x1026, 0x1028, 0x102A–0x102D, 0x102F, 0x10B8, and the 0x101E fail path (§7.5.3) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done), then P02 again | layouts are Z07 / Z12's; confirming them needs a character with a house, pet, emblem … or a failed map login |
| which of a zone's 4 WM links receives the WM broadcasts (§7.5.1, last to register *(inferred)*; §7.5.4: index [3] twice, [2] once) | resolved here (batch 3, §17.4) | the zone starts of `s37` / `s21d`: 186 of 188 broadcasts on the last-registered link (`SetZoneSession` @ FUN_00439190 overwrites the mapping) |
| corrections to done items' pseudocode (§13) | X04 (added by P02, `docs/plan/items/X04.md`: "for every §13 row whose status names X01 or X04 … add the missing ones"); X01 (done) took batch 1 only | P02 must not edit other items' output; X01 collects knowledge-file corrections |
| opcodes and paths never captured (§14 last bullet) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done), then P02 again | needs new captures; P02 is recurring per batch |
| per-minute phase, clock offset, 0x7C07 timing, LoadMap heartbeat points (§14) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done) | none changes a layout or an order; each needs a targeted capture (zone restart, synced clocks, map loads with markers) |
| second per-minute 0x1035, 0x3C01 `npcPosition`, NPC sp 100 | resolved here (review): §6.1 (0x1035), §6.3 | the second 0x1035 = the `so_Routine` dirty-flag pass after the per-minute block sets `p+0xe94` (`smo_Abstate.parameterchange`, Z09 §2.4 / §5.5, §6.1) |
| WM `CWMClientSession::Send_NC_CHAR_SUPPORT_REWARD_CMD` @ FUN_00433ab0 → zone 0x1120 @ FUN_005a5c70 (abstate 728) | W04 §17.5, Z07 §1.2 (both done, both document it) | resolved and confirmed in §5.1; nothing left to document |
| item transaction failures (0x340C/0x340F, 0x3412, 0x3415, 0x341E, 0x3424, 0x342A, 0x3445 …) and their client codes | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done), then P02 again | batch 2 holds only successes (§8.2); the failure layouts are Z05 §2–§7 / D03's |
| PvP / party / guild-war deaths, exp loss (0x0429, WM 0x244A, 0x244B, 0x2411, 0x7445), skill fail / abort (0x2434, 0x2438, 0x2445), revive to another map (0x1050), rebirth (0x1102 / 0x1103) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done), then P02 again | batch 2 has one PvE death, a solo player and successful casts only (§9); the layouts are Z03 / Z07's. The bystander packets (0x2449, 0x240D, 0x244F, 0x500B) are captured in batch 3 (§18.5, §20.3, §20.4) |
| the extra `hpchangeorder` reads (§9.1) and the client-send flush point (§14) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done) | no layout depends on them; the order within one socket is right |
| 0x7037 trailing bytes `+3` or `+3n`, and how the 2016 client builds its option-save opcodes (no 0x7037 / 0x7011 / 0x7015 / 0x703B immediate, §14) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Batch-2 leftovers"; X02 is done), then P02 again | a capture with two or more shortcut changes in one request settles the tail; the WM drops it either way (W04 §8.2), so no server layout depends on it |
| quest SAY bytes `Data+0xC = 7`, `+0x10 = 1` (§10.5, §14) | Z15 (done): `Z15-quest-engine.md` Z15-B11 documents the leftover heap pointers / bytes of earlier script commands in the SAY buffer | the bytes are stale data, not fields; nothing to add |
| title type 9 marking and its unlock rule (§10.3, §14) | resolved here (sweep): `CT_LevelUp` @ FUN_005cc2f0; rule = Z18 §6.2 (done) `CheckNewTitle` @ FUN_005cb5f0 | – |
| `fm_fp_AllOfRange2` (§10.4) and the account-storage open flag after 0x304D (§8.1, §14) | resolved here (sweep): `so_AllOfRangeNomal` @ FUN_0054c900; `sp_NC_ACT_ENDOFTRADE_CMD` @ FUN_004c4a60 → `sp_EndOfTrade` @ FUN_004c25b0 (Z02 §6.4, done) | – |
| client 0x4025 second sender FUN_004a59d0 and its callers FUN_00553a10 / FUN_006a2b30 (§14) | resolved here (sweep) | official name of FUN_00553a10 *(inferred)* only; Z12's open item is answered (§13) |
| 0x10D2 single-option column names (ours), Character server's GameLog link, link carrying the WM broadcasts (§14 *(inferred)*) | link carrying the broadcasts: resolved here (batch 3, §17.4); Character server's GameLog link: resolved here (batch 3: `s37` `W00_GLDB#18` keeps its heartbeats through the WM stop and both WM starts, §17.1, so it is not the WM's link); the 0x10D2 names: X05 (added by P02, step "Batch-2 leftovers"; X02 is done) | the layouts and orders hold whatever the names; the zone starts of `s37` / `s21d` showed the 0x0802 registration order |
| Character / GameLog servers' acceptors (they take 4 links of one address within 1 ms, no per-IP refusal, §17.1) | D08 (plan: "the Character and GameLog process layers are matched and their differences stated") | the difference is in the DB servers' own process layer, not documented by S02 (Login / WM / Zone only) |
| cause of the first WM stop in `s37` (§17.6) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Open after batch 3": the WM's `Msg` log next to a WM restart), then P02 again | not on the wire; the code paths are named in §17.6 |
| `s14` steps not on the wire: unknown-name whisper 0x200E, emote stop 0x2022 / 0x2023, a player walk (0x2017 / 0x2018), sit, a shout out of sight (§18.8; 0x1C07 is in `s21`, §18.2) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Open after batch 3": scenario 14 steps (2)–(4)), then P02 again | the layouts are W04 §2.1 / Z02 §2–§5's; only the capture is missing |
| P02-B27's storm also hits the client side (rendering of 136 appear / delete pairs) | – (client behaviour, out of the server spec) | the server bug and its fix are in §12; what the 2016 client does with each pair is not needed for a rebuild |
| the 2016 client's own pick-right check on a drop object (`FUN_00610fc0`, §19.4) | – (client behaviour, out of the server spec) | the server's rule (Z09 §11.4 owner time, `so_drpitm_CanLooting`) and its timing are captured; a rebuilt server must answer 0x345 for a client that does ask |
| buy-back onto an empty cell (`0x34B9` / `0x34BA`), sell / buy-back / soul-stone refusals (`0x3427`, `0x366B`–`0x366F`, `0x5005`, `0x3443`), the storage page request `0x3028` (§20.5) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Open after batch 3"; X02 is done), then P02 again | the layouts are Z04 §2.5 / §7.2 / §13.1, Z05 §2.2 / §2.4 and D03 §2.2 / §2.4's; `s21` holds only successes and the P02-B31 refusal |
| the 2016 client's own soul-stone check at full HP (no 0x5007, §20.3) | – (client behaviour, out of the server spec) | the server's 0x5007 handler (Z04 §13.2) answers whatever the client sends; a rebuilt server needs nothing from the client check |
| S16 with a fame or gamble-coin purchase (D03-B1: lost fame / coins), X3's untried `MaxLot` paths (sell `0x385`, use `0x702`, move-merge `irm_Split_N_Merge(MaxLot − b)` with b > `MaxLot`), an expired item worn or used before the minute check (§21) | X05 (added by P02: X02's re-run, `docs/plan/items/X05.md` step "Open after batch 3"; X02 is done), then P02 again | the code paths are read (D03 §1.2, Z04 §2.4 / §4.1 / §6.1, Z24 §6.7); only a capture with these setups can confirm them |
| P02-B5 … B32 (§12, first table), the *(captured)* evidence for other items' bugs (§12, second table) and the batch-2 / batch-3 rows of §13, none of them in `docs/pseudocode/README.md` §5 / §6 yet (X01 integrated batch 1 only; its README links still cite §8 for the bugs, renumbered §12 in batch 2) | **X04** (new, added by P02 in the batch-3 sweep: `docs/plan/items/X04.md`) | X01 is done and has no recurring step; X03 covers only X02 and its follow-ups; P02 may not write the README |
| scenario texts that did not match the recordings (§13 rows owned by X02: §3.37 step 1, §3.14 steps, the `tools/capture/21` scripts' character), result lines for the recorded scenarios 14 / 21 / 37 / S13 / S16 / X3, scenario 24 (notes without a capture, §1), and the confidence ratings after batches 2–3 | **X05** (new, added by P02 in the batch-3 sweep: `docs/plan/items/X05.md`, X02's recurring re-run) | X02 is done; its plan's last step ("after the user records them, P02 validates them …; then re-run X02 to update the ratings") has no open item to run it |
