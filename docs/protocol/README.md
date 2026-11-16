# Client ⇄ Server Protocol Specification (recovered from binaries)

Recovered by static analysis of the shipped server binaries in `Files/Server/2016/`, then checked against packet
captures of a 2016 client on these servers ([capture-validation.md](capture-validation.md), work item P02). In this
file **observed** means read in the decompiled code, **inferred** means deduced from it, and *(captured)* means seen
on a real connection (the strongest evidence; where a capture and the code disagreed, the text below follows the
capture and cites the code that explains it). Open questions are listed in [Unknowns](#unknowns). Statements changed
after the captures are listed with their old wording in [`docs/knowledge/P04.md`](../knowledge/P04.md).

| Binary | SHA-256 (prefix) | Role | Client port |
|---|---|---|---|
| `Files/Server/2016/Login/3LoginServer2.exe` | `3513309c4422237f` | Login server | 9010 |
| `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe` | `903d73807b77a30f` | World manager (WM) | 9110 |
| `Files/Server/2016/w00_Zone0{0..3}/5ZoneServer2.exe` (all four identical) | `a18129fd83d214df` | Zone (map) server | 9210 / 9212 / 9214 / 9216 |
| `Account`, `AccountLog`, `w00_Character`, `w00_GameLog` | – | DB servers (internal only) | – |

Ports come from `9Data/ServerInfo/ServerInfo.txt`. `SERVER_INFO` rows with type `20` are the client
listeners. The Login accept loop handles type `0x14` (20) sockets as clients and sends them the seed
packet (`3LoginServer2.exe` `FUN_004022a0`). Type `8` rows are bound to 127.0.0.1 and carry server links.

Generated per-server opcode tables (every handler, with the packets it sends):

- [opcodes-login.md](opcodes-login.md): 12 client handlers
- [opcodes-wm.md](opcodes-wm.md): 167 client handlers
- [opcodes-zone.md](opcodes-zone.md): 245 client handlers
- [opcodes.json](opcodes.json): all 2,056 opcodes seen in the 7 binaries (names, receivers)

Per-packet field layouts (what each packet contains, with values or where each value comes from):

- [packets-login.md](packets-login.md), [packets-wm.md](packets-wm.md), [packets-zone.md](packets-zone.md):
  generated layouts for every client handler (fields read, value checks) and every client-bound send site
  (fields written, constants, source expressions, `in(0xOP)+N` data flow). Hand-verified layouts with
  field names appear first in each section, marked **Verified layout**.
- [client-error-codes.json](client-error-codes.json): all 479 error codes the client knows, with the
  message it shows. Extracted from the 2016 client `Fiesta.bin` (`FUN_00416430`) and its
  `TextData*.shn` tables (`tools/protocol-re/errcodes.py`, `shn.py`).
- [annotations.json](annotations.json): the hand-verified layouts (36 packets plus the `WORLD` and
  130-byte `AVATAR` structs). Edit this file to add names as you confirm fields, then regenerate.

---

## 1. Transport

All three client-facing servers share one network library (`CSocket_IOCP`, `CSendPacket`), with the same
framing and the same cipher table.

### 1.1 Framing (observed, *captured*)

```
short packet  (body < 256 bytes):  [len:u8]               [body: len bytes]
long packet   (body ≥ 256 bytes):  [0x00] [len:u16 LE]    [body: len bytes]

body = [opcode:u16 LE] [payload]
len  = 2 + payload length       (the length prefix is not counted)
```

- `CSendPacket::SetSize` (Login `FUN_004122a0`) picks the short form when `payload+2 < 0x100`, otherwise the
  long form. Payloads of 0x1FFC bytes or more are rejected. Zone `ProtocolPacket::pp_SendPacket`
  (`FUN_004c89c0`) applies the same rule, with a limit of `< 0x1FFD`.
- Writes are queued in 0x2000-byte IO buffers. Several packets can share one TCP write.
- Hand-built packets in the code show the same layout, for example `{04, 07 08, seed_lo, seed_hi}` is
  `len=4, opcode=0x0807, u16 seed`.
- *(captured)* Every captured packet parses with this rule; the long form appears exactly for bodies ≥ 256 bytes
  (`0x0C5A`, `0x0C0F`, zone `0x1801`, large `0x1C09` / `0x581D`), and the servers put several packets in one TCP
  segment (capture-validation §2.1).

### 1.2 Opcode (observed)

```
opcode = (department << 10) | command          department: 6 bits, command: 10 bits
```

The dispatcher reads `dept = op >> 10` and `cmd = op & 0x3FF` (Login `FUN_00406680`). Handlers live in
`PROTOCOLFUNCTIONTEMPLETE<T>`, a `[cmd][dept]` table filled by `pft_Store(dept, cmd, handler)`. One table
exists per peer type (client, WM, account DB, and so on). An opcode with no handler, or one sent in the
wrong session state, is logged as `Invalid Client Session ...` and the session is closed (`*session = 3`).

Department prefixes from the handler names: 2 `NC_MISC`, 3 `NC_USER`, 4 `NC_CHAR`, 5 `NC_AVATAR`,
6 `NC_MAP`, 7 `NC_BRIEFINFO`, 8 `NC_ACT`, 9 `NC_BAT`, 10 `NC_OPTOOL`, 12 `NC_ITEM`, 13 `NC_ITEMDB`,
14 `NC_PARTY`, 15 `NC_MENU`, 17 `NC_QUEST`, 18 `NC_SKILL`, 19 `NC_TRADE`, 20 `NC_SOULSTONE`, 21 `NC_FRIEND`,
22 `NC_KQ`, 23 `NC_WT`, 24 `NC_CT`, 26 `NC_BOOTH`, 27 `NC_SCENARIO`, 29 `NC_GUILD`, 35 `NC_MINIHOUSE`,
37 `NC_HOLY`, 38 `NC_GUILD`(academy), 41 `NC_INSTANCE`, 43 `NC_DICE`, 44 `NC_RAID`, 47 `NC_GAMBLE`,
49 `NC_COLLECT`, 51 `NC_MOVER`, 53 `NC_PET`. See `opcodes.json` for the rest.

### 1.3 Encryption (observed, *captured*)

- **Client → server only.** Each received body (opcode + payload, not the length prefix) is XORed in
  place before dispatch (Login `FUN_0040b170`, WM `FUN_0045d4b0`, Zone `FUN_00631120`). Server → client traffic is plaintext: the send path (`CSocket_IOCP::Send`) has no cipher.
- Keystream: a fixed **499-byte table**, byte-identical in Login (`0x430430`), WM (`0x497840`) and Zone
  (`0x871608`). The table is reproduced in [Appendix A](#appendix-a-xor-table).
- The per-session index starts at `seed % 499`, advances by one per byte across packets, and wraps to 0
  after index 498.

```python
def decrypt(body: bytearray, state):         # state.idx starts at seed % 499
    for i in range(len(body)):
        body[i] ^= XOR499[state.idx]
        state.idx = 0 if state.idx >= 498 else state.idx + 1
```

*(captured)* On all three servers every client body decrypts with this rule from the stream's `0x0807` seed, across
packets; server → client traffic is plaintext (capture-validation §2.2). Server ↔ server links carry no seed and no
cipher (capture-validation §7.1).

### 1.4 Seed: `0x0807` NC_MISC_SEED_ACK (observed, *captured*)

Every client-facing server sends the seed **unasked, right after accept**, as the raw 5 bytes `{04, 07 08, u16 seed}`;
the server's decrypt index for that session starts at `seed % 499` (§1.3). The client never asks for it.

| Server | Sent by (on accept) | Seed value |
|---|---|---|
| Login | `LoginServer::ProcessConnect` (FUN_004022a0) → `CLoginClientSession::Send_NC_MISC_SEED_ACK` (FUN_00409610) | per-process counter `m_ClientSeed`: `rand()` after `srand(time)` at start (ctor FUN_00409680), then `(m_ClientSeed + 1) % 499` in `CLoginClientSessionManager::ActiveSession` (FUN_00409700) per accepted client (L01 §2) |
| WM | `WorldManagerServer::ProcessConnect` (FUN_00405860) → `Send_NC_MISC_SEED_ACK` (FUN_00430550) | same scheme in `CWMClientSessionManager::ActiveSession` (FUN_00438a60; W05 §1.4, §4.3) |
| Zone | `ZoneServer::zs_connect` (FUN_005aa840) → `ClientSession::Send_NC_MISC_SEED_ACK` (FUN_0045b120) | `ShinePlayer::so_EncSeedSet` (FUN_0054f660, vtable slot `0x2f4`): global `seed = seed + 1`, `0` once it reaches 499; also sets the player's decrypt index. So the first client of a zone process gets 1, then consecutive values (Z18 §1.3) |

*(captured)* Login seeds 355–368 and WM seeds 264–271 rise by one per connection; zone seeds per process are 1, 2, 3 …
(capture-validation §2.3).

The zone also registers client `0x0806 NC_MISC_SEED_REQ` (`sp_NC_MISC_SEED_REQ`, FUN_00451a30), which answers
`0x0807` from a second counter `newseed` without moving the decrypt index (Z01 §5.1). The 2016 client never sends
`0x0806` *(captured)*, and the zone's session filter lets it through only in a state normal play never reaches, so the
path is dead (Z18 §1.3, original bug Z18-B2).

### 1.5 Heartbeat (observed, *captured*)

`0x0804 NC_MISC_HEARTBEAT_REQ` and `0x0805 NC_MISC_HEARTBEAT_ACK` are both empty. **The server starts them**: every
server session (client and server links alike) runs a check per main-loop pass: no packet received for 30 s → send one
`0x0804` (raw `02 04 08`); nothing at all received in the next 180 s → close the session. Any received packet resets
the timer. A failed `0x0804` send closes the session at once.

| Server | Check | Client-session notes |
|---|---|---|
| Login | `CheckHeartBeat` (FUN_00408f30; L01 §2) | a client before its login request (session mode 0 / 1) is closed for any `0x0804` / `0x0805` it sends, so a pre-login heartbeat cannot be answered (original bug L01-B11). Not reachable with the 2016 client: it opens the Login connection only when the login form is submitted and then polls `0x0C1B` every 10 s, so Login never sends it a heartbeat *(captured, capture-validation §16.2)* |
| WM | `CWMBaseSession::CheckHeartBeat` (FUN_0042fda0), via `ProcHeartBeat` (FUN_00430160; W05 §1.5) | `0x0804` exactly 30.0 s after the last client packet, repeated 30 s after each answer; the client answers within ~1–12 ms; 7 min on the character list without a close *(captured, capture-validation §4.4, §16.2)* |
| Zone | `ClientSession::CheckHeartBeat` (FUN_0045b110) → `ZoneBaseSession::CheckHeartBeat` (FUN_005a67c0; S02 §4.4, Z18 §1.4) | same 30 s / 180 s rule (the 300 the client override passes is ignored). The answer is accepted before `0x1803` too; during the first map load the client answers late (4.9 s), because its loader does not service the zone socket *(captured, capture-validation §5.5)* |

A received `0x0804` is answered with a bare `0x0805` (Login: raw bytes `02 05 08`); a received `0x0805` is accepted and
ignored. The 2016 client answers the server's `0x0804` with `0x0805` (`Net::ProcessNetMsg` FUN_006d2fa0, when its
heartbeat flag is on) and was never seen sending `0x0804` itself *(captured)*. It also sends **unsolicited `0x0805` to
the WM while it loads a map** (`World::LoadMap` FUN_006768c0 → FUN_006d2ef0, name *(pdb2017)*
`NetMgr::SendHeartBeat2WorldMgrServer`), which keeps the WM session alive during long loads (capture-validation §4.4).
Server ↔ server links use the same rule in both directions (capture-validation §7.1; `docs/pseudocode/README.md` §2.3).

---

## 2. Connection flow: which messages are sent when

```
Client                Login                AccountDB  AccountLog   WM                CharDB   Zone
  |-- TCP connect ----->|
  |<-- 0x0807 seed -----|
  |-- 0x0C65 version -->|                                                   (state 0 → 1)
  |<-- 0x0C67 ok / 0x0C66 fail
  |-- 0x0C5A login ---->|-- 0x0C5B -->|                                     (state 1 → 2)
  |                     |<-- 0x0C5C --|
  |<-- 0x0C09 error ----|  (fail)
  |                     |-- 0x0C5D ------------->|
  |                     |<-- 0x0C5E -------------|
  |<-- 0x0C0A worlds ---|  (or 0x0C09 0x51)
  |-- 0x0C0B world ---->|-- 0x0C0D ----------------------------->|
  |                     |<-- 0x0C0E -----------------------------|
  |<-- 0x0C0C WM addr + 32×u16 validate key
  |
  |== TCP connect to WM ====================================================>|
  |<-- 0x0807 seed ---------------------------------------------------------|
  |-- 0x0C0F world login (user, validate key) -------------------------------->|-- 0x0C60 → AccountDB
  |                                                             ...0x0C61 →  |-- 0x0C12 -->|
  |<-- 0x0C14 avatar list (or 0x0C15 error) --------------------------------|<-- 0x0C13 --|
  |-- 0x1001 NC_CHAR_LOGIN_REQ (slot) --------------------------------------->|-- 0x1004 -->|
  |                                                                          |<-- 0x1005 --|
  |<-- 0x1003 zone ip/port (or 0x1002 error) ------------------------------|-- 0x1036 → zone
  |
  |== TCP connect to Zone =================================================================================>|
  |-- 0x0806 seed req ---------------------------------------------------------------------------------------->|
  |<-- 0x0807 seed -------------------------------------------------------------------------------------------|
  |-- 0x1801 NC_MAP_LOGIN_REQ (char id, 49 SHN checksums) ---------------------------------------------------->|
  |<-- 0x1804 fail (bad checksum)                                         WM <-- 0x104B ------------------------|
  |                                                                        WM --> 0x101D ZONE_CHARDATA_ACK --->|
  |<-- 0x1802 NC_MAP_LOGIN_ACK (or 0x1804) -------------------------------------------------------------------|
  |-- 0x1803 NC_MAP_LOGINCOMPLETE_CMD ------------------------------------------------------------------------>|
  |<-- initial world state (see opcodes-zone.md, row 0x1803) -------------------------------------------------|
```

### 2.1 Login server session states (observed, `FUN_00406680`)

| State | Accepted client opcodes | Transition |
|---|---|---|
| 0 (new) | only `0x0C65` | → 1 |
| 1 | only dept 3 with cmd `0x37` (`0x0C37`) or `0x5A` (`0x0C5A`) | → 2 |
| 2 | every opcode registered for `CParserClient` | – |

Anything else closes the session.

---

## 3. Packet layouts

Offsets are payload offsets (just after the opcode). Little-endian. Strings are fixed-size and
NUL-padded unless stated otherwise.

### 3.1 Login server

| Opcode | Dir | Layout | Notes |
|---|---|---|---|
| `0x0807` | S→C | `u16 seed` | sent on accept |
| `0x0C65` | C→S | `char version_key[64]` | `strncmp(..., 64)` against each line of `Login/ClientVersionKeyInfo.txt` |
| `0x0C67` | S→C | `u8 n; char s[n]` | version OK. In this build always `n=1, s=""` (the source field is cleared before the copy) |
| `0x0C66` | S→C | `u8` (value not set by the code) | version rejected |
| `0x0C5A` | C→S | `char user[256]` @0, 4 unread bytes @256, `char password[36]` @260, `u32 extra[5]` @296 | total packet length must equal `0x13E`. `extra` is forwarded to AccountDB without being interpreted |
| `0x0C37` | C→S | `u8 token[32]` | total packet length must equal `0x22`. Token login: looked up in a table filled by WM message `0x0C35`. Unknown token → `0x0C09 {0x52}`; login disabled flag (`DAT_004425f8 == 0`) → `{0x45}`; else world list |
| `0x0C09` | S→C | `u16 error` | login failure, then disconnect. Codes seen: `0x45` (server closed or account error -1), `0x47`, `0x48`, `0x4A` (after `0x0C1D`), `0x4B` (account error -2), `0x4C` (after `0x0C20`), `0x51` (AccountLog block), `0x52` (bad token) |
| `0x0C0A` | S→C | `u8 count; WORLD[count]` | `WORLD` (18 bytes) = `u8 world_no; char name[16]; u8 status`. Status is set to 2 at load. Worlds with status `< 5` cannot be selected |
| `0x0C1B` | C→S | – | world list refresh → `0x0C1C` (same layout as `0x0C0A`) |
| `0x0C0B` | C→S | `u8 world_no` | world select |
| `0x0C0C` | S→C | `u8 status; char wm_ip[16]; u16 ?; u16 validate[32]` (83 bytes) | On an unknown or closed world, sent with only `status` filled. On success, `validate` is the 64-byte key that came back from WM `0x0C0E`. Offset 17–18 is not written on this code path (probably the port; unknown) |
| `0x0C04` | C→S | – | answered with `0x0C05 {u8 1}` |
| `0x0C1D` / `0x0C20` | C→S | – | answered with `0x0C09 {0x4A}` / `{0x4C}`, then disconnect |
| `0x0C06`, `0x0C18` | C→S | – | no-op handlers |

Login → WM `0x0C0D` (internal): carries the login handle, world number, user name and user number, plus
31 random `u16` values and a 32nd `u16` that is the XOR of a world key with all 31. WM keeps this record
until the client presents the same 32 values in `0x0C0F`.

### 3.2 World manager

| Opcode | Dir | Layout | Notes |
|---|---|---|---|
| `0x0807` | S→C | `u16 seed` | sent on accept |
| `0x0C0F` | C→S | `char user[256]` @0, `u16 validate[32]` @256 | must match a pending `0x0C0D` record. No match → `0x0C15 {u16 0x44}` |
| `0x0C15` | S→C | `u16 error` | world login failed (`0x44` bad key, `0x46` avatar DB error) |
| `0x0C14` | S→C | `u16 handle; u8 count; AVATAR[count]` | `AVATAR` is 130 bytes (`0x82`), copied from CharDB `0x0C13`. Slot index is at byte `+0x1A` inside each record (inferred). Layout of the 130 bytes: not yet decoded |
| `0x1001` | C→S | `u8 slot` (0–5) | `NC_CHAR_LOGIN_REQ`: select a character |
| `0x1002` | S→C | `u16 error` | `NC_CHAR_LOGIN_ACK` (failure). Codes: `0x0144` (empty slot), `0x0145` (map or zone lookup failed, inferred), `0x31EB` (meaning unknown) |
| `0x1003` | S→C | `char zone_ip[16]; u16 zone_port` | zone handoff, sent after CharDB `0x1005 NC_CHAR_CHARDATA_ACK`. WM sends `0x1036` to the target zone at the same moment |
| `0x1401` | C→S | `u8 slot; char name[20]; u8 …` | avatar create (inferred from reads), forwarded to CharDB as `0x1402` |
| `0x1407` | C→S | `u8 slot` | avatar delete (inferred), see table |

The other 160 WM handlers (party, friends, guild, raid, chat channels, …) are listed in
[opcodes-wm.md](opcodes-wm.md) with their replies and payload-read hints.

### 3.3 Zone

| Opcode | Dir | Layout | Notes |
|---|---|---|---|
| `0x0807` | S→C | `u16 seed` | sent on accept (§1.4) *(captured)* |
| `0x0806` | C→S | – | `NC_MISC_SEED_REQ`: registered, never sent by the 2016 client; dead path (§1.4) |
| `0x1801` | C→S | `u16 wm_handle` @0, `char char_id[20]` @2, `u8 shn_md5[49][32]` @22 | `NC_MAP_LOGIN_REQ`. Each 32-byte entry is compared with the server's checksum of one SHN data file |
| `0x1804` | S→C | `u16 error; u8 index` | map login failed. `0x0147` = SHN checksum mismatch, `index` names the file. Also sent on `0x101E NC_CHAR_ZONE_CHARDATAFAIL_ACK` |
| `0x1802` | S→C | 242 bytes | `NC_MAP_LOGIN_ACK`, sent in `wms_NC_CHAR_ZONE_CHARDATA_ACK` once WM delivers the character. Layout not yet decoded |
| `0x1803` | C→S | – | `NC_MAP_LOGINCOMPLETE_CMD`. Zone then pushes initial state: party, abstates, items, … (see the table row) |

Zone → WM `0x104B NC_CHAR_REGISTNUMBER_REQ` (internal): `u16 zone_handle, u32 0xFFFFFFFF, u16 wm_handle,
char char_id[20]`.

All 245 zone client handlers carry their original names (from `ShinePlayer::sp_NC_*` profiler strings)
in [opcodes-zone.md](opcodes-zone.md).

---

## 4. How the tables were produced

1. Ghidra headless (tables were generated with 12.2) with `Decompiler Parameter ID` enabled (`tools/protocol-re/EnableParamId.java`).
   `tools/protocol-re/ExportAll.java` dumps every function's C and every string with its references.
   REA (Hopper backend) was used for spot checks. REA's Ghidra provider requires Ghidra 12.1.x
   (now installed as `ghidra@12.1.4`).
2. `extract.py` finds the `pft_Store` function from its "Duplicate protocol set" string. It then reads
   every `pft_Store(dept, cmd, handler)` registration and assigns it to the
   `PROTOCOLFUNCTIONTEMPLETE<Class::*>` table being built. For each handler it collects:
   - **name**: the handler's own `sp_/fc_/gds_/wms_/zls_NC_*` profiler or log string (zone, WM, Character)
   - **sends**: opcodes written by `CSendPacket::ID`, by hand-built raw headers, or into the zone send buffer, in the handler and its direct callees
   - **hints**: packet-length checks and byte offsets read from the packet
3. `catalog.py` merges the 7 binaries. A sent opcode counts as **client-bound** when no server-to-server
   parser in any of the 7 binaries registers a handler for it.

Regenerate:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
G=/opt/homebrew/opt/ghidra@12.1.4/libexec/support/analyzeHeadless; T=tools/protocol-re; OUT=/tmp/re/out
$G /tmp/re/proj login -import Files/Server/2016/Login/3LoginServer2.exe -scriptPath $T \
   -preScript EnableParamId.java -postScript ExportAll.java $OUT/login      # repeat per binary
tools/protocol-re/regen.sh                   # rebuilds every generated doc from re-data/exports (preferred)
python3 $T/extract.py $OUT/login            # per server → handlers.json
python3 $T/layouts.py $OUT/zone x Files/Server/2016/w00_Zone00/5ZoneServer2.exe   # per server → layouts.json (exe enables vtable resolution)
python3 $T/catalog.py $OUT docs/protocol    # reads $OUT/<server> (or ${OUT}2/<server> if present)
python3 $T/packets.py $OUT docs/protocol    # → packets-<server>.md (merges annotations.json)
OUT=$OUT $T/fn.sh login 406680              # print one decompiled function
```

## 5. Confidence

| Item | Basis |
|---|---|
| Framing, opcode split, XOR table and index rule, seed packets, heartbeats | observed, cross-checked in 3 binaries, *captured* on all three servers (capture-validation §2) |
| Handler ↔ opcode tables | observed (registration calls). 597/597 zone and 220/223 `sp_` handler names matched |
| Names marked "handler" | the opcode's own handler string in some binary |
| Names marked † | inferred: REQ+1 = ACK, or a log string. Can be wrong (e.g. `0x0C65` is the version check, not `RETURN_CHECK_ACK`) |
| "Sends" columns | regex over decompiled C. Misses sends through virtual calls and helpers deeper than one call. Callee hits (¹) can include unrelated paths |
| Payload layouts in §3 | read manually from the handlers cited |

## 6. Decoding captures

`tools/protocol-re/pcap_decode.py` (stdlib only) decodes `.pcap`/`.pcapng` captures of client traffic with the
rules of §1: TCP reassembly, framing, XOR-499 decryption from the `0x0807` seed (brute-forced when the seed is
missing), field decode from `annotations*.json` then `layouts.json`, and a validation report.

```bash
python3 -I tools/protocol-re/pcap_decode.py re-data/captures/x.pcapng [--port 9010=login] [--show-secrets]
python3 -I tools/protocol-re/pcap_decode.py --selftest
```

Outputs `x.pcapng.decoded.txt`, `.report.md`, `.json`. The `0x0C5A` password is masked by default. The decoder
reads the cipher table from Appendix A below, so keep that heading and hex block intact. Details and limits:
[`docs/knowledge/P01.md`](../knowledge/P01.md).

## Unknowns

- The 130-byte avatar record (`0x0C14`) is decoded in `annotations.json`. Some fields have no name;
  several names are inferred from SQL column types.
- `0x1802` (map-login ACK, 242 B): handle, stat pairs and position are known. Bytes 2–17 and 146–169 are
  unnamed. The initial-state burst after `0x1803` has generated layouts but no names.
- `0x0C0C` offset 17–18 (probably the WM port) is not written in the observed path.
- ~~Whether the zone also sends the seed unprompted on accept~~: it does (§1.4, *captured*).
- Session-state gating in WM and Zone is documented in the pseudocode (WM: W01 §2 / §3.2 and W05 §4.3 `m_SessionMode`;
  zone: Z18 §1.3 session filter), not summarised here.
- Which of the client's 8 `0x0805` points in `World::LoadMap` fire for which map (two first loads sent none;
  capture-validation §4.4).
- Names for most WM- and Login-only opcodes. These binaries carry no name strings for them; the names
  would have to come from the client.
- Server → client messages sent from timers or other non-handler code (combat ticks, mob AI, broadcasts)
  are not listed per trigger. They do appear in `opcodes.json` when a handler sends them.

## Appendix A: XOR table

499 bytes, identical in all three servers (Login VA `0x430430`):

```
0759694a941194858c8805cba09ecd583a365b1a6a16febddf9402f82196c8e99ef7bfbdcfcdb27a009f4022fc11f90c2e12fba7740a7d78401e2ca02d06cba8b97eefde49ea4e13161680f43dc29ad486d7942417f4d665bd3fdbe4e10f50f6ec7a9a0c273d2466d322689c9a520be0f9a50b25da80490dfd3e77d156a8b7f40f9be80f5247f56f832022db0f0bb14385c1cba40b0219dff08becdb6c6d66ad45be89147e2f8910b89360d860def6fe6e9bca06c1759533cfc0b2e0cca5ce12f6e5b5b426c5b2184f2a5d261b654df545c98414dc7c124b189cc724e73c64ffd63a2cee8c8149396cb7dcbd94e232f7dd0afc020164ec4c940ab156f5c9a934de0f3827bc81300f7b3825fee83e29ba5543bf6b9f1f8a4952187f8af888245c4fe1a830878e501f2fd10cb4fd0abcdc1285e252ee4a5838abffc63db960640ab450d54089179ad585cfec0d7e817fe3c3040122ec27ccfa3e21a654c8de00b6df279ff625340785bfa7a5a5e0830c3d5d2040af60a36456f305c41c7d3798c3e85a6e5885a49a6b6af4a37b619b09401e604b32d951a4fef95d4e4afb4ad47c330233d59dce5baa5a7cd8f805fa1f2b8c725750ae6c1989ca01fcfc299b61126863654626c45b50aa2bbeef9a790223752c2013fdd95a7623f10bb5b859f99f7ae606e9a53ab450bf165898b39a6e36ee8deb
```
