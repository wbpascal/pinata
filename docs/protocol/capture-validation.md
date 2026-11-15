# Capture validation (P02)

Real client↔server traffic compared with the documented protocol (`README.md`, annotations, generated layouts,
pseudocode). Captures are the strongest evidence level: a statement here marked *(captured)* overrides a reading of
the code; where they disagree, the code was re-read and the finding is listed in §9 for the owning item.

- Decoder: `python3 -I tools/protocol-re/pcap_decode.py re-data/captures/<file>.pcapng --out <dir>` (P01,
  `docs/knowledge/P01.md`). Field names below are the decoder's (annotations first).
- Captured fields confirmed or corrected by P02: `annotations/P02.json` (`packets` = corrected/new layouts,
  `evidence` = confirmed existing layouts).
- Server set: `Files/Server/2016`, client `Files/Client/2016` (version key `20151116141627`), one world
  (`world_no` 0, `INITIO`), zones on ports 9210/9212/9214, all on 172.16.42.214; client on another LAN host.
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

The pcapngs hold only the game packets (saved as "displayed packets"): no SYN/ACK frames, one frame per packet.

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
| Zone | per process: port 9210 → 1 (idle) and 3, 4, 5 (walk); 9212 → 1, 2; 9214 → 1 | **contradicted** README §1.4 and §2: the zone sends `0x0807` **on accept**, unprompted. `ZoneServer::zs_connect` (@ FUN_005aa840) registers the socket with IOCP and calls `ClientSession::Send_NC_MISC_SEED_ACK(session, seed)` (@ FUN_0045b120) with the seed returned by ShinePlayer vtable slot `0x2f4`. The client never sent `0x0806 NC_MISC_SEED_REQ` in any capture; `sp_NC_MISC_SEED_REQ` (@ FUN_00451a30) is only a re-request path. The small values (first connection of a process = 1) fit a per-process counter starting at 0 *(inferred)* |

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
| S→C | 0x0C0A | NC_USER_LOGIN_ACK | 8 | 19 | confirmed | 1 world: `{0, "INITIO", 6}`. The name is ServerInfo.txt `WORLD_NAME 0, "INITIO"`; the tester saw "Enid", so the client shows its own name for world 0 *(inferred, client lookup not traced)* |
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

Streams: 7 WM connections (login-logout 1, login-errors 2, create-char 1, idle_in_world 1, walk-run-portals 1), 155
packets, 42 (dir, opcode) types. Code references are W01-core (`docs/pseudocode/wm/W01-core.md`), W03-guild, W04-social-misc,
W05-process; function names from the WM PDB (`re-data/exports/wm-pdb`).

Decoder fix in this part: annotations whose `dir` names the server (`WM→C`, `C→WM`, `Z→C`, `C→Z`: W03, W04, W05, Z11,
Z12, Z16) were never matched, so 0x7032/0x7C07/0x9414/0x5826/0x5824/0x0849/0x10D9/0x7005/0x700D/0x703B/0x7033/0x7034 decoded with
the PDB or C01 layouts. `pcap_decode.py` now maps any `X→C` / `C→X` label to S→C / C→S (`client_dir`). With that fix and
the P02 entries for 0x1406 / 0x140C / 0x182A, 69 of the 155 WM packets decode from hand annotations, 42 from pdb2016 and
44 from pdb2017 (all empty bodies: 0x0804, 0x0805, 0x080D, 0x7C06).

### 4.1 Message order *(captured)*

World login (all 7 connections):

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
S 0x7005, 0x700D (CharDB round trip, 20–75 ms), 0x7C07 (WM answers itself, 4-byte form)
  zone: C 0x1803 NC_MAP_LOGINCOMPLETE_CMD, and in the same client tick:
C 0x581B NC_KQ_LIST_REFRESH_REQ
S 0x581C, 0x581D ×3                 answer to 0x581B (first refresh of the session only, §4.3)
S 0x1097, 0x1012, 0x9414, 0x5826, 0x10D9, 0x0849, 0x182A   zone 0x180C map login done (fc_NC_MAP_LINKEND_CMD @ FUN_0042d8d0)
```

The order of the 0x180C burst is exactly the call order in `fc_NC_MAP_LINKEND_CMD`: `FriendRefresh` (nothing: no
friends), `GuildRefresh` (0x1097 academy, then 0x1012 guild), `GuildEmblemRefresh`, `ChatRestrictRefresh` (nothing),
`HolyPromiseFirstLogon` (0x9414), `GuildTournamentGoldRefundNotice`, `ChatBlockSpamFilterRefresh` (nothing),
`CKQServer::Send_NC_KQ_JOINING_ALARM_LIST` (0x5826), `NewbieGuideViewListRefresh` (0x10D9), `SendWMTimeToClientFirst`
(0x0849), `LinkEndProcessing`, then 0x182A. The 0x581B answer and the 0x180C burst race: in walk-run-portals the KQ
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
| S→C | 0x0807 | NC_MISC_SEED_ACK | 7 | 2 | confirmed | §2.3 |
| C→S | 0x0C0F | NC_USER_LOGINWORLD_REQ | 7 | 320 | confirmed | `userId` = `"admin"` + 251 NUL; `validate[32]` = the 0x0C0C words unchanged (all 7) |
| S→C | 0x0C14 | NC_USER_LOGINWORLD_ACK | 7 | 133 | confirmed | `worldmanager` handle, 1 AVATAR (0x82); see §4.3 for the handle sequence and the AVATAR fields |
| C→S | 0x080D | NC_MISC_GAMETIME_REQ | 11 | 0 | confirmed | after every 0x0C14 and with every zone `0x1801` (map change) |
| S→C | 0x080E | NC_MISC_GAMETIME_ACK | 11 | 3 | confirmed | `{hour, minute, second}` = server local time (UTC+1); equal to the capture clock to the second in all 11 |
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
  10:19:00) and leave the WM 32–88 ms after the full second by the capture clock. W05 §2.2 *(inferred)* "the send second
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

The 0x1803 burst, captured order (identical in all 7 apart from the counts) against `sp_NC_MAP_LOGINCOMPLETE_CMD`
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
`Session_SendSupportReward` @ FUN_00433ab0 on the first map login only (W04 §17.5), which sends zone `0x1120
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
| S→C | 0x0807 | NC_MISC_SEED_ACK | 7 | 2 | confirmed | per zone process consecutive (§5.1): **confirms** Z01 §5.1 (global counter); first connection after start = 1 |
| C→S | 0x1801 | NC_MAP_LOGIN_REQ | 7 | 1590 | confirmed | `{u16 wm_handle, char charid[20], Name8 checksum[49]}` = pdb2016 `PROTO_NC_MAP_LOGIN_REQ` (0x636); wm_handle 12500 / 17500 = the WM session handle (§4.3); 49 × 32 hex digits, identical in all 7 |
| S→C | 0x1038 | NC_CHAR_CLIENT_BASE_CMD | 7 | 105 | confirmed | Z12 §6.2; chrregnum 2, Level 120, map/coords of the **new** map on every link, adminlevel 100, prisonmin 0 |
| S→C | 0x1039 | NC_CHAR_CLIENT_SHAPE_CMD | 7 | 4 | confirmed | `AE 04 00 00`, same as AVATAR.shape (§4.3) |
| S→C | 0x103A | NC_CHAR_CLIENT_QUEST_DOING_CMD | 7 | 6 | confirmed | `{chrregnum 2, bNeedClear 1, n 0}` (Z12 §6.3) |
| S→C | 0x103B | NC_CHAR_CLIENT_QUEST_DONE_CMD | 7 | 12 | confirmed | 12-byte header, 0 records |
| S→C | 0x10CE | NC_CHAR_CLIENT_QUEST_READ_CMD | 7 | 8 | confirmed | 1 id (3109) |
| S→C | 0x10D7 | NC_CHAR_CLIENT_QUEST_REPEAT_CMD | 7 | 6 | confirmed | 0 records |
| S→C | 0x103D | NC_CHAR_CLIENT_SKILL_CMD | 7 | 298 | confirmed | restempow 60, PartMark 3, nMaxNum = number = 24, 24 × 12-byte records (skills 4000, 4001, 4020 …) |
| S→C | 0x103E | NC_CHAR_CLIENT_PASSIVE_CMD | 7 | 8 | confirmed | 3 passives (200, 201, 218) |
| S→C | 0x1047 | NC_CHAR_CLIENT_ITEM_CMD | 28 | 3–726 | confirmed | 4 per login: box 9 (27 items), 8 (3), 12 (2), 15 (0); flag bit 0 = 1 in all, bits 1–7 stale (0x65, 0x19, 0xFD, 0x25: **confirms** Z12 §6 "flag bits 1–7 left from earlier gpp use"); the empty action box 15 is still sent (single-packet path), the 3 inventory chunks of W01 §6.3 arrive as one packet (box 9). Decoder cannot parse the `PROTO_ITEMPACKET_INFORM[]` tail (P01) |
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
| S→C | 0x1C09 | NC_BRIEFINFO_MOB_CMD | 12 | 299–4173 | confirmed | 1 + 149 × n, n ≤ 28; since the part-5 decoder fix (§11) every record decodes (`mobnum` = record count in all 12; handle, mode 2, mobid, coord); in-world 0x1C09 is §6 |
| S→C | 0x242A | NC_BAT_ABSTATEINFORM_NOEFFECT_CMD | 19 | 8 | confirmed | `asl_SendAfterLogin`, §5.1 #5 |
| S→C | 0x2429 | NC_BAT_ABSTATEINFORM_CMD | 30 | 8 | confirmed | title abstates (§5.1 #13), abstate 728; keepTime −1 = permanent |
| S→C | 0x1C18 | NC_BRIEFINFO_ABSTATE_CHANGE_CMD | 49 | 14 | confirmed | one per 0x2429 / 0x242A, handle = own |
| S→C | 0x105B | NC_CHAR_STAT_REMAINPOINT_CMD | 7 | 1 | confirmed | 73 |
| S→C | 0x203E | NC_ACT_MOVESPEED_CMD | 7 | 4 | confirmed | {33, 127} |
| S→C | 0x9010 | NC_CHARGED_BOOTHSLOTSIZE_CMD | 7 | 1 | confirmed | 5 |
| S→C | 0x182B | NC_MAP_CAN_USE_REVIVEITEM_CMD | 7 | 1 | confirmed | 1 |
| S→C | 0x2011 | NC_ACT_NOTICE_CMD | 14 | 20 | confirmed | 2 per login: "From 172.16.42.231" (`unk` 1) and "Admin level is 100" (`unk` 2): `unk` is never written (Z09-B54); the values are whatever the send buffer held *(inferred)* |
| S→C | 0x10BD | NC_CHAR_CLIENT_AUTO_PICK_ACK | 2 | 3 | confirmed (pdb2016 layout) | login {err 0x1E00, bEnable 1}; at 82.1 s {0x1E00, 0} (in-world, §6); layout added to P02.json |
| S→C | 0x1123 | NC_CHAR_USEITEM_MINIMON_INFO_CLIENT_CMD | 7 | 50 | confirmed | Z13 layout right (0x32); the struct `USEITEM_MINIMON_INFO` (pdb2016, 0x32) is now in `annotations/P02.json` `structs`, so all 7 decode in full (part 5, §11) |
| S→C | 0x10C6 | NC_CHAR_ADMIN_LEVEL_INFORM_CMD | 7 | 1 | confirmed | `nAdminLevel` 100 (pdb2016 name; layout added to P02.json) |
| S→C | 0x482C | NC_SKILL_ITEMACTIONCOOLTIME_CMD | 7 | 2 | confirmed | num 0 (Z17 §3.5: 2 + 8n, sent also when empty); Z11.json overlays the array header and its element fields (`group[i].…`) at offset 2; the decoder now reads that as the element layout (part 5, §11) |
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
  in): 9 inventory, 8 equipment, 12 mini-house, 15 action box. Equipment records: slot 8 (35740), slot 10 (weapon 1250),
  slot 25 (30817), matching the 0x1C02/0x1C05/0x1C03 of the burst.
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
(Z12 §4.2) *(which call produces the second packet was not traced; candidates: the minute block's vt 0x34 and the
charged-buff dirty flag `p+0xe94` on the next tick, Z09 §2.4)*.

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
  stop (6456, 10525) *(probably the server-side player position, as Z02 §6.6 says the actor stores; not traced)*.
- **0x2402 for NPCs**: hp / maxhp 0, sp / maxsp 100, level 0 (the NPC's vt 0x4e8 / 0x4f0 / 0x4ec / 0x4f4 / 0x4d8;
  Gate_Town has MobInfo Level 0, MaxHP 0) *(why SP is 100 not traced)*.
- **0x1C0E delivery**: the player received the deletes caused by its own moves (o = player, second send of
  `ali_Work`), so Z09-B13 (wrong first argument of `pcb_Append`) has no visible effect while the buffer is not full
  *(captured, consistent with Z09's inferred effect)*.

## 7. Message order against README §2 and the pseudocode

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

## 8. Original-server bugs

Found by P02 (tagged `(original bug)` where described):

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| P02-B1 | Character server `GetAvatarInfo` → WM 0x0C14 avatar list (D02 §3.2) | `delinfo` writes only byte +0x27 when the character is not deleted; +0x28..+0x2B keep whatever the buffer held (§4.3) | 4 bytes of Character-server memory (pointer-like) reach every client in the avatar list | zero the whole 5-byte `delinfo` |
| P02-B2 | WM `fc_NC_MAP_LINKEND_CMD` @ FUN_0042d8d0 → client 0x182A | `CSendPacket::ID(&p, 0x182a, 1, NULL)` declares a 1-byte payload and writes none (§4.2) | one stale WM byte per map login (0xDA / 0x00 captured); the client ignores it | payload size 0 (the 2017 PDB struct is empty) |
| P02-B3 | zone `so_ply_FillRewardInven` @ FUN_004fc310 → 0x302D | adds the counter byte to the length `irs_FillBufferItem` @ FUN_00644c80 already counts (§5.3) | every 0x302D carries one uninitialised trailing byte | use the returned length as is |
| P02-B4 | zone `sp_NC_MAP_LOGINCOMPLETE_CMD` @ FUN_00443390 (tail) | a missing title state entry or abstate jumps to the epilogue (§5.3) | latent: with a bad `CurrentTitleElement` the client gets no 0x10C6 / 0x482C / 0x10D4 / 0x1827 / 0x182C, no map Lua `MapLogin`, no GameDB 0x34CF | skip only the title abstates and continue |

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

## 9. Discrepancies per work item

Every owner below is `**State:** done`; nobody reopens them. The full rows (old statement, correction, evidence) are in
`docs/knowledge/P02.md` "Corrections"; X01 (contradictions register, plan "Corrections between items") collects them.

| Owner | Where | Discrepancy | Status |
|---|---|---|---|
| P01 / L00 (README) | `README.md` §1.4, §2 | zone seed is sent on accept; no client `0x0806` | contradicted → X01 |
| P01 / L00 (README) | `README.md` §1.5 | heartbeat runs server → client (`0x0804`), client answers `0x0805` | contradicted → X01 |
| P01 / L00 (README) | `README.md` §2 | missing: 0x0C04/0x0C05, token-login order, 0x0C1B poll, 0x080D game time, WM option pushes, zone blob copies, map change, logout (§7) | corrected → X01 |
| L00 | `login-server.md` §8 | client sends its login request before 0x0C04 | corrected → X01 |
| L00 | `annotations/L00.json` 0x0C37 | token is `char[32]` | corrected (P02.json overrides) |
| D02 | `D02-character.md` §3.2 | `delinfo` +0x28..+0x2B uninitialised (P02-B1) | contradicted → X01 |
| W01 | `W01-core.md` §7.3 | 0x182A byte never written (P02-B2) | corrected → X01 |
| W01 | `W01-core.md` §6.1 | AVATAR `shape` = race / class / gender ids, hair / colour / face table ids | corrected (inferred → captured) |
| W01 | `W01-core.md` §5.1 | 0x0C18 mode 0 also = back to the world list | corrected → X01 |
| W04 | `W04-social-misc.md` §9 | 0x7C07 arrives in the game scene | open item answered |
| W05 | `W05-process.md` §2.2 | 0x0849 has `tm_sec = 0`; no drift | contradicted (inferred claim) → X01 |
| P01 | `pcap_decode.py` | annotation dirs `X→C` / `C→X`; struct-array, `bytes`, nested and inline struct types | fixed by P02 (parts 2 and 5, §11) |
| P01 | `annotations.json` zone 0x1802 | pdb2016 layout replaces the `?` blocks | corrected (P02.json overrides) |
| Z01 | `Z01-core.md` §6 | `sp_ConnectFromWhere` sends a notice, not WM 0x082A | contradicted → X01 |
| Z01 | `Z01-core.md` §6 | tail of 0x1803 is conditional (P02-B4) | corrected → X01 |
| Z01 | `Z01-core.md` §6 | burst senders named in §5.1 | added |
| Z02 | `Z02-actions.md` §2.2 | `so_SendSpeedInformation(1)` sends only on a change | contradicted → X01 |
| Z02 | `Z02-actions.md` §5.2 | 0x1C0E is sent (already corrected by Z09 §9.6) | confirmed correction |
| Z02 | `Z02-actions.md` §6.2 | Gate_Town NPCs (MiniMapIcon 23): no 0x201D, town-portal window | corrected → X01 |
| Z04 | `Z04-items.md` §8.3 | 0x302D trailing byte (P02-B3) | corrected → X01 |
| Z15 | `Z15-quest-engine.md` §5.6 | 0x441E values are `time_t` period starts | corrected → X01 |

No discrepancy for Z03, Z05, Z07, Z09, Z11, Z12, Z13, Z16, Z17, Z18, Z22, W03: every statement of theirs that §3–§6 test held.

## 10. Not reconstructed / uncertain

- **Second per-minute 0x1035** (one tick after the first, flags 0x12–0x1B): the first is `smo_NotifyParameterChange(1)`
  in the per-minute block (Z09 §2.4); the second is probably the charged-buff dirty flag `p+0xe94 = 1` handled on the
  next tick *(inferred, not traced; start from the reader of ShinePlayer +0xe94 in `so_Routine`)*.
- **Per-minute phase** (42 s past the minute on every zone process): likely the common start second of the processes
  *(inferred; a capture after restarting one zone would settle it)*.
- **0x3C01 `npcPosition`** (6457, 10501): neither the gate's NPC.txt position nor the client's last stop; probably the
  server-side player position Z02 §6.6 stores *(not traced)*.
- **0x2402 for NPCs** reports sp / maxsp 100 with hp 0 and level 0 *(source of the 100 not traced: NPC vt 0x4ec / 0x4f4)*.
- **Client `World::LoadMap` heartbeats** (§4.4): which of the 8 call points fire per map load *(not traced)*.
- *(inferred)* items carried from parts 1–4: world name "INITIO" shown as "Enid" (client-side name for world 0, §3.2);
  the 0x112C range broadcast excludes the sender (§5.1 #12); 0x2011 `unk` values are buffer leftovers (§5.2); the
  client ignores the 0x302D trailing byte (§5.3); AVATAR KQ fields keep the last saved position (§4.3).
- **Not captured at all**: combat beyond targeting, chat (other than `&adminlevel`), item use / trade / shops, party,
  guild, KQ, failure paths (0x0C15, 0x1002, 0x1804, 0x0C66, …; lists in §3.2, §4.2, §5.2). Statuses there stay
  **never seen** until X02's scenarios are recorded.

## 11. Coverage boundary

P02 has no scope table (`coverage.py P02`: "no scope table; coverage does not apply"); its scope is every packet of
the processed captures, and every observed (server, dir, opcode) type has a status in §3.2, §4.2, §5.2 or §6.2.

Decoder gaps found in parts 2–4 (knowledge row "pcap_decode.py struct sizes", owner P01 = done) are small and fixed
here in `tools/protocol-re/pcap_decode.py` (part 5): dims `[]` = rest of the payload; `bytes` = rest of the payload;
struct names also match a unique nested `Outer::Inner`; inline element types `{u8,u8}`; `struct[count]` followed by
`name[i].member` fields is read as the element layout; a struct whose first field is `datasize` takes 1 + datasize
bytes per element (`PROTO_ITEMPACKET_INFORM`). `USEITEM_MINIMON_INFO` (pdb2016) is in `annotations/P02.json` `structs`.
After the fix the five captures decode with one warning left (0x7C07 short form, below); `--selftest` passes.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| 0x7C07 4-byte short form: the decoder warns "sReason needs 16 bytes" | W04 §9.2 (done; documents both forms) | the layout is right; `annotations/W04.json` has one entry for two sizes and sorts after P02.json, so P02 cannot override it; harmless warning |
| README §2 / §1.4 / §1.5 rewrite | X01 (plan: "Corrections between items", "contradictions") | README's owner P01 is done; the corrected flows are in §7 and the knowledge Corrections table |
| corrections to done items' pseudocode (§9) | X01 (same line) | P02 must not edit other items' output; X01 collects knowledge-file corrections |
| opcodes and paths never captured (§10 last bullet) | X02 (plan: "write targeted capture scenarios"), then P02 again | needs new captures; P02 is recurring per batch |
| second per-minute 0x1035, 0x3C01 `npcPosition`, NPC sp 100, LoadMap heartbeat points (§10) | X02 (plan: "adversarially re-check load-bearing claims … write targeted capture scenarios") | none changes a layout or an order; each needs either a targeted capture or a code read of a done item's subsystem (Z09 §2.4, Z02 §6.6, client C01) that X02's re-check covers |
| WM `Session_SendSupportReward` @ FUN_00433ab0 → zone 0x1120 @ FUN_005a5c70 (abstate 728) | W04 §17.5, Z07 §1.2 (both done, both document it) | resolved and confirmed in §5.1; nothing left to document |
