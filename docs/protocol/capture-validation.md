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
(walk-run-portals: t = 86.3, 106.5, 136.2, 181.8 s; see §4). Login sent no heartbeat in the captures: on the
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
