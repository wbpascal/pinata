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
