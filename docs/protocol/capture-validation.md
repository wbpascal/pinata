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

Batch 2 (`shop`, `combat`) was recorded on the server host with the LAN and the loopback interface: it adds the
server↔server links (§7). The character is Test2 (`chrregnum` 5, slot 1, level 5, shape 0x19), not Test1235.
Its 257 opcode types not seen in batch 1 (190 on links, 64 zone, 3 WM) are covered in §7–§10 (parts 7–13); the
batch-1 types recur with the same layouts unless a row says otherwise.

The pcapngs hold only the game packets (saved as "displayed packets"): no SYN/ACK frames. Several game packets often share one frame (one TCP segment, §2.1): idle_in_world holds 208 packets in
114 frames, walk-run-portals 1 057 in 566, up to 67 packets in one frame.

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
raid packets (no raid), 0x10B3 / 0x1C06 etc. **The capture confirms Z01 §6's order** for everything it shows.

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
(zone → Character), 0x112C (broadcast, never to the own client).

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
  in the same ms with `0xC811`, then `0x080A`, the order of W01 §8 (**confirmed**). D01 §4.2 calls 0x080A "WM every
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
5.698 … 5.715  CDB → WM, 44 packets in D02 §4 step order:
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
- **W05 §1.4 confirmed on the wire**: the WM handles at most one packet per session per main-loop pass. The 44 blocks
  arrive within 17 ms, yet the WM handles 0x1005 (and sends 0x1036 / 0x1003) only 580 ms (`shop`) / 557 ms (`combat`)
  after it arrived: ≈ 13 ms per pass, which is the `Sleep(5)` that `MainThread` @ FUN_00407340 makes on every pass while
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
  is not a fixed index.
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
+5 … 19 ms   WM → zone, in one ms, on link i+1 (34–36 packets):
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
- **Timing**: 0x1802 leaves 391–455 ms after 0x101D. That is ≈ 12 ms × (34 … 36 packets): the zone handles one packet
  per WM link per main-loop pass (`zs_PacketProcess`, Z09 §1.5), and all blobs arrive on one link. The zone sends
  0x1802 from the 0x101D handler (Z07 §1.4). ≈ 11.5–12.8 ms per pass *(inferred: the sleep manager's `Sleep(1)`, Z09
  §1.4, at Windows timer granularity)*. This queue is most of the map-login latency.
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
CharDB (`ws_save2DB`, part 13); the revive at 102.376 sent `0x180B` and CharDB saves but no `0x40xx` to the WM. Every
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
    GameLog 0xC809 (part 13)
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
    `ID_KILLED_BY_MOB` only when 180 s have passed since the last death and the killer handle differs ([8] stayed 0,
    §14). So 9 is the death
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
  `always99` is the GameLog store type "map link" *(captured; the 0x040F side is part 13)*. Only the first 0x180C of
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

### 7.6 Zone ↔ Character DB and GameLog DB *(parts 11–13, not yet written)*

## 8. Zone in-world, batch 2: items, shops, storage *(part 11, not yet written)*

## 9. Zone in-world, batch 2: combat, death, revive, soulstones *(part 12, not yet written)*

## 10. Zone in-world, batch 2: other new zone opcodes *(part 13, not yet written)*

## 11. Message order against README §2 and the pseudocode

README §2 is a sketch of the login → WM → zone chain. Against the five captures (details in the sections cited):

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

Pseudocode orders the captures confirm in full: Z01 §6 (`sp_NC_MAP_LOGINCOMPLETE_CMD` burst), W01 §7.3 and W04 §17.5
(`fc_NC_MAP_LINKEND_CMD`, incl. the zone round trip `0x1120` that grants abstate 728 one tick after the burst, §5.1),
W05 §2.2 (0x0849 once per character, on the full minute), Z09 §2.4 (per-minute check, item expiry), Z09 §9.6 (sight
enter / leave at `MapInfo.Sight`), Z02 §5 (`ResendLastMove` after 0x1C08).

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

Other items' bugs the captures show on the wire (no new ID; owner's register entry stands):

| ID | Captured evidence | § |
|---|---|---|
| L00-B5 | `0x0C05 bSuccess = 1` on every XTrap key | §3.2 |
| Z07-B7 | 0x1802 `Wizdom` stale | §5.3 |
| Z18-B10 | 0x1C05 `nSlotNum` = 0x74 in all 7 (stale) | §5.2 |
| Z18-B19 | 0x10E4 / 0x10E7 / 0x10EA `chrregnum` stale, different per login | §5.2 |
| Z09-B54 | 0x2011 `unk` never written (values 1 / 2 are buffer leftovers) | §5.2 |
| Z02-B2 | mob `moveattr` = stale `gpp` bytes with bit 0 cleared | §6.3 |
| Z09-B13 | no visible effect while the broadcast buffer is not full (0x1C0E reaches the mover) | §6.3 |

## 13. Discrepancies per work item

Every owner below is `**State:** done`; nobody reopens them. The full rows (old statement, correction, evidence) are in
`docs/knowledge/P02.md` "Corrections"; X01 (contradictions register, plan "Corrections between items") collects them.

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

No discrepancy for Z03, Z05, Z07, Z09, Z11, Z12, Z13, Z16, Z17, Z18, Z22, W03: every statement of theirs that §3–§6 test held. Batch 2 §7.5 also confirms Z01 §5.2–§5.3, Z07 §1.2–§1.4, Z09 §1.2 / §1.5, Z12 / Z13 / Z17 / Z28 blob layouts
(the trailing bytes are the WM's P02-B10 / P02-B11) and W05 §2 (0x441D). Part 10 (§7.5.4) confirms Z01 §7.1 (`so_LinkTo`, 0x180B / 0x180D / 0x180E, the same-zone branch), the
Z03 / Z12 / Z13 / Z15 / Z16 / Z23 / W04 layouts of the saves, Z08 §4 (no 0x580E from a zone without the map, Z08-B8) and
§8.2 (0x7496), W03 §3.5 / §6.4 and W04 §17.5 (0x1120 after the first 0x180C only), and Z18 §6.2's use of title type 9.

## 14. Not reconstructed / uncertain

- **0x0849 / 0x080E clock offset**: the capture PC and server clocks differ by a few tens of ms, sign varying between
  captures (§4.2, §4.3); a capture with the server's own clock (or NTP on both) would pin the send to the second.
- **0x7C07 timing** (§4.1): the short form is sent in the 0x7C06 handler, yet leaves 73–74 ms after 0x7C06 together with
  the CharDB-backed 0x700D. Batch 2 explains it *(inferred)*: the passes do sleep in normal operation (W05-B1 sleeps
  only while the CharDB link is in state 1, which is the normal state; ≈ 13 ms per pass measured in §7.4), the client
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
  was not located (the 2017 `ShortCutMgr` send functions are empty stubs), so it is open whether the tail is
  `+3` or `+3n` *(a capture with n ≥ 2 settles it)*. The WM drops it either way.
- **Title value type 9** (batch 2, §7.4 0x1019): `TitleValues[9]` went 1 → 2 across `combat`, in which Test2 died once,
  but pdb2016 names 8 `ID_KILLED_BY_MOB` and 9 `ID_NOKILLED_BY_MOB`. Either the zone counts deaths under 9 or the
  value changed for another reason. **Settled** in part 10 (§7.5.4): `CT_KilledByMob` @ FUN_005cbdd0 adds 1 to type 9 on
  every death (the death counter). Open: type 8 should also have gone 0 → 1 on the first death of the session (180 s
  since `m_KilledByMobTimeValue`, a new killer handle) but stayed 0. The initial value of `m_KilledByMobTimeValue` /
  `m_KilledByMobHandle` was not traced *(part 12 reads the death path)*.
- **0x10D2 single-option columns** (batch 2, §7.4): `usp_Character_getSingleOption` returns (u8, u8, ts, u32); the
  field names in P02.json are ours. The timestamp equals the 0x101A `dKQDate`: both look like "last save" times
  *(inferred)*.
- **Link-to-process mapping** (batch 2, §7.1): settled in part 9 (§7.5.1): `SocketBundle<…>` `sb_SocketStr[4]`, one
  round-robin pick per send. Which of the 4 WM links carries a zone's broadcasts (the last to register) is *(inferred)*; part 10 (§7.5.4) shows
  it is not a fixed `sb_SocketStr` index.
- *(inferred)* items carried from parts 1–4: the 0x112C range broadcast excludes the sender (§5.1 #12); 0x2011 `unk` values are buffer leftovers (§5.2); the
  client ignores the 0x302D trailing byte (§5.3); AVATAR KQ fields keep the last saved position (§4.3).
- **Not captured at all**: combat beyond targeting, chat (other than `&adminlevel`), item use / trade / shops, party,
  guild, KQ, failure paths (0x0C15, 0x1002, 0x1804, 0x0C66, …; lists in §3.2, §4.2, §5.2). Statuses there stay
  **never seen** until X02's scenarios are recorded.

## 15. Coverage boundary

P02 has no scope table (`coverage.py P02`: "no scope table; coverage does not apply"); its scope is every packet of
the processed captures, and every observed (server, dir, opcode) type has a status in §3.2, §4.2, §5.2 or §6.2.

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

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| 0x7C07 4-byte short form: the decoder warns "sReason needs 16 bytes" | W04 §9.2 (done; documents both forms) | the layout is right; `annotations/W04.json` has one entry for two sizes and sorts after P02.json, so P02 cannot override it; harmless warning |
| README §2 / §1.4 / §1.5 rewrite, Unknowns line "whether the zone also sends the seed unprompted" | **P04** (new, added by P02: `docs/plan/items/P04.md`) | README's owners P01 and L00 are done and X01 may write only `docs/pseudocode/README.md`; P04 corrects the README from §2 / §11 and the knowledge Corrections rows |
| WM → zone blobs never sent for Test2: 0x1026, 0x1028, 0x102A–0x102D, 0x102F, 0x10B8, and the 0x101E fail path (§7.5.3) | X02 (plan: "write targeted capture scenarios"), then P02 again | layouts are Z07 / Z12's; confirming them needs a character with a house, pet, emblem … or a failed map login |
| which of a zone's 4 WM links receives the WM broadcasts (§7.5.1, last to register *(inferred)*; §7.5.4: index [3] twice, [2] once) | X02 (same line) | no layout or order depends on it; a capture of a zone start would show the 0x0802 order |
| corrections to done items' pseudocode (§13) | X01 (same line) | P02 must not edit other items' output; X01 collects knowledge-file corrections |
| opcodes and paths never captured (§14 last bullet) | X02 (plan: "write targeted capture scenarios"), then P02 again | needs new captures; P02 is recurring per batch |
| per-minute phase, clock offset, 0x7C07 timing, LoadMap heartbeat points (§14) | X02 (plan: "adversarially re-check load-bearing claims … write targeted capture scenarios") | none changes a layout or an order; each needs a targeted capture (zone restart, synced clocks, map loads with markers) |
| second per-minute 0x1035, 0x3C01 `npcPosition`, NPC sp 100 | resolved here (review): §6.1 (0x1035), §6.3 | the second 0x1035 = the `so_Routine` dirty-flag pass after the per-minute block sets `p+0xe94` (`smo_Abstate.parameterchange`, Z09 §2.4 / §5.5, §6.1) |
| WM `CWMClientSession::Send_NC_CHAR_SUPPORT_REWARD_CMD` @ FUN_00433ab0 → zone 0x1120 @ FUN_005a5c70 (abstate 728) | W04 §17.5, Z07 §1.2 (both done, both document it) | resolved and confirmed in §5.1; nothing left to document |
