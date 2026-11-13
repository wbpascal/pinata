# GameLog server: what is logged (D05)

Source binary: `Files/Server/2016/w00_GameLog/GameLog Release.exe` (export `re-data/exports/gamelog`). View code with
`python3 -I tools/protocol-re/clean.py re-data/exports/gamelog tools/protocol-re/names/gamelog <addr>…`.
Evidence markers as in `AGENTS.md`: *(db-backup)* = only the procedure source in `GameLog.bak` / `w00_GameLog.bak` shows it,
*(pdb2017)* = only the 2017 client PDB, *(inferred)* = deduced. Field names are the 2017 PDB's (`PROTO_NC_LOG_GAME_*`) where the
2016 GameLog code reads the same offsets. Verified layouts: `docs/protocol/annotations/D05.json` (4th field = the `tGameLog`
column it fills).

The GameLog server is a write-only sink. Zone, WM and Character servers send one packet per event; each handler copies the
fields into a parameter struct and calls one `p_GameLog_Add*` procedure, which inserts one `tGameLog` row. Nothing is read back,
nothing is answered (one exception: 0x0402 → 0x0403), no state is kept between packets.

Parts: §1–§2 = part 1 (framework, procedures, dept-1 commands 1–84), §3 = part 2 (dept-1 commands 85–857). Later parts add the
rest of dept 1, MISC/OPTOOL and the NC_SYSLOG dept 50 (see `docs/plan/status/D05.md`).

## 1. Process and storage

### 1.1 Process (the DataServer framework of D01 §1)

The binary is the same "DataServer" as the Account and AccountLog servers (D01 §1): config script, ODBC row, listener, N
session workers with one ODBC connection each, the `CPFs` server-link handlers, a parser class with a `pft_Store` table.
GameLog-specific values:

```
DataServer (GameLog)
├── config   : DataServerInfo_GameLog.txt: MY_SERVER "PG_W00_GLDB", "_2015_GameLog", type 3, world 0, zone 0
│              + #INCLUDE ../9Data/ServerInfo/ServerInfo.txt                          @ FUN_00401370 DataServer_ReadDefineScriptor
├── ODBC     : row id 11 ("w00_GameLog", database w00_GameLog) is the only one opened    @ FUN_0040a290 SessionWorker_DBInit
│              (missing row: "DB_Init FAILED, Scriptor BASE ODBC info. not found.")
├── also     : ../9Data/Shine/MapInfo.shn, ItemInfo.shn (framework; no part-1 handler uses them)
├── parsers  : CPFs (server link, ctor FUN_00409640), CParserGameLog (ctor FUN_00407c30, 191 registrations)
└── workers  : "<NUMBER OF %d SESSION WORKER STARTED>"; each runs SessionWorker_Run       @ FUN_0040a380
```

```pseudo
SessionWorker_Run(w):                                   @ FUN_0040a380   (same code as D01 SessionWorker.Run)
    w.running(+300) = 1
    if !SessionWorker_DBInit(w): w.state(+0x114) = 4; log "<SESSION WORKER #%d INIT DB FAILED - STOP ******>"; return
    w.state = 2
    while w.state == 2:
        job = queue.Pop(w)                       @ FUN_0040aab0
        if none: Sleep(2); continue
        ok = parser.Dispatch(job)                # vtable slot 0 of the parser at w+0x138
        if !ok and job.session.state(+0xdc) != 0:
            log "*Work failed (%-25s world=%3d zone=%3d, …) (DEP=%d,CMD=%d,LEN=%d,WORK=%d, WorkerID=%d)"
    close ODBC (+0x124c); log "<SESSION WORKER #%d FREE>"; w.state = 4; w.running = 0
```

Sending (only 0x0402's answer and the server-link replies use it):

```pseudo
CSendPacket: Init @ FUN_00412a90; SetOpcode(op, size, data) @ FUN_00412bd0 (opcode at +3, payload at +5, copies data);
    SetSize @ FUN_00412ab0: size+2 < 0x100 → u8 length at +2 (frame starts at +2); size < 0x1FFC → {0, u16 size+2} at +0;
    larger → "ERROR - CSendPacket::SetSize=%d, …", the packet is emptied (opcode 0, length 2)       (correct framing)
    WireSize @ FUN_00412b90 = size + 3 or size + 5; WireStart @ FUN_00412bb0 = +2 or +0
Session_SendPacket(session, pkt) @ FUN_00409940: under the session send lock (+0x114) → FUN_00412ca0 →
    CSocket_IOCP_Send(socket = session+8, WireStart, WireSize) @ FUN_00413790:
        > 0x2000 bytes: log "WARNING - CSocket_IOCP::Send, OVERMAX SIZE,TYPE_0|1 …" and send anyway in 0x2000-byte chunks
        per chunk: copy into a pooled I/O buffer; invalid socket or chunk > 0x2000 → log, drop
        nothing in flight → WriteFile (overlapped); a hard error (not 997 pending, not the usual reset/abort codes) is
        logged "CSocket_IOCP::Write %#x(%#x) err=%d" and the socket is closed (FUN_00413320)
        else append to the queued tail buffer when it fits, or chain a new buffer
```

Every log handler therefore runs on some worker with its own connection; packets from one sender can be inserted out of
order when several workers run *(inferred: the queue hands jobs to any free worker)*.

### 1.2 `tGameLog` and the procedures

All 22 `p_GameLog_Add*` procedures insert exactly one row into `tGameLog` and return `@nLogNo = @@IDENTITY` (0 on error)
*(db-backup)*. They differ only in which columns they take; a column a procedure does not take is left to its table default
(not visible in the backups; D06). Columns *(db-backup)*: `nType int, nCharNo int, sMap varchar(16), nMapX int, nMapY int,
nMapZ int, nTargetCharNo int, nTargetID int, nItemKey bigint, nInt1 int, nInt2 int, nInt3 int, nBigint1 bigint` plus the
identity `nLogNo` (no date column is written; a default such as `getdate()` is likely, *inferred*).

Versions: both backups have all of them with the binary's parameter count, except `p_GameLog_Add_TypeL` (only
`w00_GameLog.bak`) and `usp_Login_setChannel` (in neither). The text is identical in both apart from the script-date header,
except **Type6**: the `GameLog.bak` copy (scripted 2007-03-13, later than w00's 2005-05-30 copies) also keeps an event-ranking
table: `IF @nType = 30: UPDATE tLevelUpInfo SET nLevel = @nInt1, dLastUpdated = getdate() WHERE nCharNo = @nCharNo, or INSERT
(nCharNo, nInt1, getdate())` ("이벤트 랭킹용으로 별도 테이블기록 by amadeus"). nType 30 is 0x041E LEVEL_UP (§2.3). Which copy the
2016 database ran is not decidable from the binary (same call).

Each wrapper is `SQL_<proc>(db, struct *)`: `stmt = DB_GetStmt(db)` (`@ FUN_00414000`, `db+0xc`), `SQLCloseCursor`, struct
`+0` (u64 `nLogNo`) = 0, one `SQLBindParameter` per `?` (parameter 1 `SQL_PARAM_OUTPUT` `SQL_C_UBIGINT`; strings `SQL_C_CHAR` →
`SQL_WVARCHAR` size 16, null-terminated), `SQLExecDirect("{CALL …}")`. Return value: the u64 `nLogNo` (only 0x0402 uses it).
If `SQLExecDirect` returns neither `SQL_SUCCESS` nor `SQL_SUCCESS_WITH_INFO`, the wrapper writes the parameters as one text line
through `GameLog_WriteFailedCall` (`@ FUN_00418f50`): file `GameLog_<yyyy-mm-dd>.txt` in the working directory, opened `"a+"`,
line `"<yyyy-mm-dd> <hh:mm:ss>> T<x>, <params…>"` (`<x>` = 0 for `p_GameLog_Add`, else the type letter). The row is lost; there is no
retry.

Parameter → struct offset (the handler fills the struct; `[o]` = byte offset; `C` = `SQL_C_` type of the binding):

| Procedure (`{CALL}` params) | Wrapper | Struct layout: column[offset] (C type when not u32/s32) |
|---|---|---|
| `p_GameLog_Add` (14) | `FUN_00419080` | nType[0x18] nCharNo[0x1c] sMap[0x20,16] nMapX[0x30] nMapY[0x34] nMapZ[0x38] nTargetCharNo[0x3c] nTargetID[0x40] nItemKey[0x48,u64] nInt1[0x50] nInt2[0x54] nInt3[0x58] nBigint1[0x60,u64] |
| `…_Type1` (7) | `FUN_004192c0` | H = nType[8] nCharNo[0xc] sMap[0x10,16] nMapX[0x20] nMapY[0x24] nMapZ[0x28] |
| `…_Type2` (9) | `FUN_00419420` | H, nInt1[0x2c] nInt2[0x30] |
| `…_Type3` (10) | `FUN_004195c0` | H, nTargetCharNo[0x2c] nTargetID[0x30] nInt1[0x34] |
| `…_Type4` (10) | `FUN_00419780` | H, nInt1[0x2c] nInt2[0x30] nInt3[0x34] |
| `…_Type5` (5) | `FUN_00419940` | nType[8] nCharNo[0xc] nInt1[0x10] nInt2[0x14] |
| `…_Type6` (9) | `FUN_00419a70` | H, nInt1[0x2c] nBigint1[0x30,s64] |
| `…_Type7` (10) | `FUN_00419c10` | H, nTargetCharNo[0x2c] nInt1[0x30] nInt2[0x34] |
| `…_Type8` (8) | `FUN_00419dd0` | H, nInt1[0x2c] |
| `…_Type9` (10) | `FUN_00419f50` | H, nItemKey[0x30,u64] nInt1[0x38] nInt2[0x3c] |
| `…_TypeA` (9) | `FUN_0041a110` | nType[8] nCharNo[0xc] nTargetCharNo[0x10] nTargetID[0x14] nItemKey[0x18,u64] nInt1[0x20] nInt2[0x24] nInt3[0x28] |
| `…_TypeB` (13) | `FUN_0041a2b0` | H, nTargetCharNo[0x2c] nTargetID[0x30] nItemKey[0x38,u64] nInt1[0x40] nInt2[0x44] nInt3[0x48] |
| `…_TypeC` (12) | `FUN_0041a4d0` | H, nTargetID[0x2c] nItemKey[0x30,u64] nInt1[0x38] nInt2[0x3c] nInt3[0x40] |
| `…_TypeD` (6) | `FUN_0041a6d0` | nType[8] nCharNo[0xc] nItemKey[0x10,u64] nInt1[0x18] nInt2[0x1c] |
| `…_TypeE` (10) | `FUN_0041a820` | nType[8] sMap[0xc,16] nMapX[0x1c] nMapY[0x20] nMapZ[0x24] nTargetID[0x28] nItemKey[0x30,u64] nInt1[0x38] nInt2[0x3c] (no nCharNo) |
| `…_TypeF` (13) | `FUN_0041a9e0` | as `p_GameLog_Add` without nTargetCharNo: nType[0x18] nCharNo[0x1c] sMap[0x20] X[0x30] Y[0x34] Z[0x38] nTargetID[0x3c] nItemKey[0x40,u64] nInt1[0x48] nInt2[0x4c] nInt3[0x50] nBigint1[0x58,u64] |
| `…_TypeG` (12) | `FUN_0041ac00` | as TypeF without nInt3: … nItemKey[0x40,u64] nInt1[0x48] nInt2[0x4c] nBigint1[0x50,u64] |
| `…_TypeH` (8) | `FUN_0041ae00` | H, nTargetCharNo[0x2c] |
| `…_TypeI` (9) | `FUN_0041af80` | H, nTargetCharNo[0x2c] nTargetID[0x30] |
| `…_TypeJ` (11) | `FUN_0041b120` | H, nTargetID[0x2c] nItemKey[0x30,u64] nInt1[0x38] nInt2[0x3c] |
| `…_TypeK` (10) | `FUN_0041b300` | H, nInt1[0x2c] nInt2[0x30] nBigint1[0x38,s64] |
| `…_TypeL` (10) | `FUN_0041b4c0` | as TypeA + nBigint1[0x30,s64] |
| `usp_Login_setChannel` (4) | `FUN_0041b680` | p1 u32[0] p2 u32[4] p3 char[8,20] p4 out s32[0x1c] (set to 0 first); no failure line, result ignored |

C types: nType/nCharNo `SQL_C_ULONG` (TypeE: nType only), nTargetCharNo/nTargetID `SQL_C_ULONG`, coordinates and nInt1–3
`SQL_C_SLONG`, nItemKey `SQL_C_UBIGINT`, nBigint1 `SQL_C_UBIGINT` in Add/F/G, `SQL_C_SBIGINT` in Type6/K/L. Type3 and Type4 bind nType
as `SQL_C_SLONG` (no effect). The failure-line formats match the parameters, except TypeL's (original bug) D05-B5: it prints
`"TA, …"` and leaves out nBigint1.

### 1.3 The handler skeleton

Every CParserGameLog handler of this part has the same shape:

```pseudo
fc_NC_LOG_GAME_<X>(parser, pkt):                        # pkt = u16 opcode + payload; p = pkt + 2
    if !Parser_CheckAlive(parser, pkt): return          @ FUN_00408a60
        # session +0xdc == 0 (link not authenticated): log "…dep=%d, cmd=%d" and drop the packet (D01 §1.1)
    st = {}                                             # stack struct of the procedure (§1.2); a few handlers memset it first
    st.nType = opcode & 0x3FF                           # the command number; item handlers use a constant instead (§2.3)
    st.<column> = p.<field> …                           # straight copies, u8/u16 zero-extended; no other logic
    st.sMap = _mbsnbcpy(p.MapName, 12)                  # MAPPOS map name → 16-byte buffer
    SQL_<proc>(parser.worker.db(+0x124c), &st)          # §1.2; result ignored
```

- **No length check.** The handler never looks at the packet length; a shorter packet fills columns with whatever the receive
  buffer still holds (original bug) D05-B1.
- `tGameLog.nType` is the NC_LOG command number (30 = level up, 63 = quest item…) except for the item logs that write the
  `…_INVEN_EXT` numbers 510–520 (§2.3). Those numbers are not registered opcodes in 2016; the 2017 PDB names them
  `NC_LOG_GAME_ITEM_TAKE_INVEN_EXT = 510` … `NC_LOG_GAME_ITEM_STORE_OUT_INVEN_EXT = 520` *(pdb2017)*.
- MAPPOS packets (`chrregnum`, `mappos {MapName[12], x, y}`) all write `nCharNo`, `sMap`, `nMapX`, `nMapY` and `nMapZ = 0`
  ("std" in the table of §2.3). The map buffer's bytes 12–15 are not cleared in the handlers without memset; `_mbsnbcpy`
  copies a terminating NUL only when the name is shorter than 12, which every 2016 `MapInfo.shn` name is (longest 11), so the
  string is always terminated in practice.

## 2. NC_LOG_GAME handlers, commands 1–84 (CParserGameLog, part 1)

### 2.1 Generic add with and without answer

```pseudo
0x0401 NC_LOG_GAME_ADD { PROTO_NC_LOG_GAME_ADD (0x44): u32 nType, u32 nCharNo, Name3 sMap, u32 nMapX, nMapY, nMapZ,
                         u32 nTargetCharNo, u32 nTargetID, u64 nItemKey, u32 nInt1, nInt2, nInt3, u64 nBigint1 }   @ FUN_00403090
    CheckAlive
    st = every field 1:1 (sMap: 12 bytes + 4 zero bytes); nType is the sender's, not the command
    SQL_p_GameLog_Add(db, st)                                                   @ FUN_00419080

0x0402 NC_LOG_GAME_ADD_REQ { u32 log_req_num, PROTO_NC_LOG_GAME_ADD logdata }  (0x48)                         @ FUN_00403160
    CheckAlive
    logNo = SQL_p_GameLog_Add(db, logdata as in 0x0401)                        # u64 @@IDENTITY, 0 on error
    Send to the requesting session 0x0403 NC_LOG_GAME_ADD_ACK {                # CSendPacket, 12 bytes
        u32 log_req_num  = request.log_req_num
        u64 writted_logno = logNo }                                             (CSendPacket_Init @ FUN_00412a90,
                                                                                 SetOpcode @ FUN_00412bd0, Session_SendPacket @ FUN_00409940)

0x0403 NC_LOG_GAME_ADD_ACK:  return 1 (no-op)                                   @ FUN_004063d0 (also CPFs 0x0801 / 0x0805)
```

No 2016 server sends 0x0401 or 0x0402 (§2.4), so the generic path and its answer are unused in this build.

### 2.2 Login: two procedures

```pseudo
0x040A NC_LOG_GAME_LOGIN { u32 chrregnum, MAPPOS mappos, u64 Cen @0x18, u32 usrregnum @0x20, Name5 spawnapps @0x24 } (0x38)  @ FUN_004032b0
    CheckAlive
    SQL_usp_Login_setChannel(db, { p1 = chrregnum, p2 = usrregnum,
                                   p3 = spawnapps (20 bytes, terminated by the zeroed output field), p4 out })   @ FUN_0041b680
        # procedure missing from both backups (D06). Name and arguments suggest it records the account's login
        # channel / client build (spawnapps; D01 prints the same field as "client-version") (inferred)
    SQL_p_GameLog_Add_Type6(db, { nType = 10, nCharNo = chrregnum, sMap = MapName, nMapX = x, nMapY = y,
                                  nMapZ = 0, nInt1 = 0, nBigint1 = Cen })                                         @ FUN_00419a70
```

Sent by the Character server after the character-login load (D02 §5), with the 56-byte request it received.

### 2.3 All handlers of this part

`std` = `nCharNo ← chrregnum @0, sMap ← mappos.MapName @4, nMapX ← x @0x10, nMapY ← y @0x14, nMapZ = 0`. A column that the
procedure takes but the handler does not fill is 0 when the handler zeroes the struct first ("struct zeroed first"), and listed
as `= 0` when the handler writes 0 itself. Senders: the 2016 function that builds the packet (from `layouts.json` send sites
and the zone functions that use the GameLog session pool `0x14d43958`), with the item that documents it.

| Opcode | Name | Handler | Procedure | nType | Columns ← fields | Sender (2016) | Note |
|---|---|---|---|---|---|---|---|
| `0x0401` | NC_LOG_GAME_ADD | `FUN_00403090` | p_GameLog_Add | payload nType | nType ← nType u32 @0x0; nCharNo ← nCharNo u32 @0x4; sMap ← sMap Name3 @0x8; nMapX ← nMapX u32 @0x14; nMapY ← nMapY u32 @0x18; nMapZ ← nMapZ u32 @0x1c; nTargetCharNo ← nTargetCharNo u32 @0x20; nTargetID ← nTargetID u32 @0x24; nItemKey ← nItemKey u64 @0x28; nInt1 ← nInt1 u32 @0x30; nInt2 ← nInt2 u32 @0x34; nInt3 ← nInt3 u32 @0x38; nBigint1 ← nBigint1 u64 @0x3c | none found | generic: every column from the packet (0x44 bytes) |
| `0x0402` | NC_LOG_GAME_ADD_REQ | `FUN_00403160` | p_GameLog_Add | payload logdata.nType | nType ← logdata.nType u32 @0x4; nCharNo ← logdata.nCharNo u32 @0x8; sMap ← logdata.sMap Name3 @0xc; nMapX ← logdata.nMapX u32 @0x18; nMapY ← logdata.nMapY u32 @0x1c; nMapZ ← logdata.nMapZ u32 @0x20; nTargetCharNo ← logdata.nTargetCharNo u32 @0x24; nTargetID ← logdata.nTargetID u32 @0x28; nItemKey ← logdata.nItemKey u64 @0x2c; nInt1 ← logdata.nInt1 u32 @0x34; nInt2 ← logdata.nInt2 u32 @0x38; nInt3 ← logdata.nInt3 u32 @0x3c; nBigint1 ← logdata.nBigint1 u64 @0x40 | none found | as 0x0401, then replies 0x0403 (§2.1) |
| `0x040A` | NC_LOG_GAME_LOGIN | `FUN_004032b0` | p_GameLog_Add_Type6 (+ usp_Login_setChannel) | 10 | std; nBigint1 ← Cen u64 @0x18; usrregnum @0x20 → usp_Login_setChannel p2; spawnapps @0x24 → usp_Login_setChannel p3; nInt1 = 0 | character FUN_00405810 (D02 §5) | two procedures (§2.2) |
| `0x040B` | NC_LOG_GAME_LOGOUT | `FUN_004033d0` | p_GameLog_Add_TypeK | 11 | std; nInt1 ← playmin u16 @0x18; nInt2 ← state u8 @0x1a; nBigint1 ← Cen u64 @0x1b | character FUN_00405b30 (D02 §5) |  |
| `0x040F` | NC_LOG_GAME_LINK | `FUN_00403490` | p_GameLog_Add_TypeG | 15 | std; nInt1 ← StoreType u8 @0x18; nItemKey ← CharExp u64 @0x19; nBigint1 ← CharMoney u64 @0x21; nTargetID = 0; nInt2 = 0 | wm FUN_0042d8d0 (W01 §7.3) | struct zeroed first |
| `0x0410` | NC_LOG_GMAE_LOGOUT_ZONEINFO | `FUN_00403490` | p_GameLog_Add_TypeG | 16 | std; nInt1 ← StoreType u8 @0x18; nItemKey ← CharExp u64 @0x19; nBigint1 ← CharMoney u64 @0x21; nTargetID = 0; nInt2 = 0 | zone FUN_00455a10 ws_save2DB, every character save (Z01 §8.4; StoreType = save reason) | same handler as 0x040F |
| `0x0411` | NC_LOG_GAME_CREATE_AVATAR | `FUN_00403560` | p_GameLog_Add_Type5 | 17 | nCharNo ← chrregnum u32 @0x0; nInt1 = 0; nInt2 = 0 | wm FUN_004113c0 (W01 §4.1) |  |
| `0x0412` | NC_LOG_GAME_DELETE_AVATAR | `FUN_00403560` | p_GameLog_Add_Type5 | 18 | nCharNo ← chrregnum u32 @0x0; nInt1 = 0; nInt2 = 0 | wm FUN_0040a010 (W01 §4.1) and character FUN_00404cd0 (D02 §3.4) | same handler as 0x0411; both senders fire on one deletion (inferred), two rows |
| `0x0414` | NC_LOG_GAME_HIT | `FUN_004035e0` | p_GameLog_Add_Type3 | 20 | std; nTargetCharNo ← targetnum u32 @0x18; nTargetID ← targettype u8 @0x1c; nInt1 ← demage u16 @0x1d | none found |  |
| `0x0415` | NC_LOG_GAME_MOVE | `FUN_004036a0` | p_GameLog_Add_Type4 | 21 | nCharNo ← chrregnum u32 @0x0; startpos.MapName @0x4 ignored; nMapX ← startpos.x u32 @0x10; nMapY ← startpos.y u32 @0x14; nInt1 ← endpos.x u32 @0x18; nInt2 ← endpos.y u32 @0x1c; sMap = "NEED"; nMapZ = 0; nInt3 = 0 | none found | map name replaced by "NEED" (D05-B3) |
| `0x0419` | NC_LOG_GAME_PRISON | `FUN_00403740` | p_GameLog_Add_Type5 | 25 | nCharNo ← chrregnum u32 @0x0; nInt1 ← prisonmin u16 @0x4; nInt2 ← prisontype u8 @0x6 | none found |  |
| `0x041A` | NC_LOG_GAME_PRISON_RELEASE | `FUN_004037c0` | p_GameLog_Add_Type1 | 26 | std | none found |  |
| `0x041E` | NC_LOG_GAME_LEVEL_UP | `FUN_00403870` | p_GameLog_Add_Type6 | 30 | std; nInt1 ← level u8 @0x18; nBigint1 ← currentexp u64 @0x19 | zone FUN_0042d830 ShinePlayer_sp_GainExp, FUN_0042fa00 (Z03 §8.3) | GameLog.bak Type6 also upserts tLevelUpInfo for nType 30 (§1.2) |
| `0x041F` | NC_LOG_GAME_LEVEL_DOWN | `FUN_00403870` | p_GameLog_Add_Type6 | 31 | std; nInt1 ← level u8 @0x18; nBigint1 ← currentexp u64 @0x19 | none found | same handler as 0x041E |
| `0x0420` | NC_LOG_GAME_CHANGE_CLASS | `FUN_00403930` | p_GameLog_Add_Type2 | 32 | std; nInt1 ← level u8 @0x18; nInt2 ← classno u8 @0x19 | character FUN_00412d60 (D02 §7.1; map "UNUSE", D02-B9) |  |
| `0x0428` | NC_LOG_GAME_PK | `FUN_004039e0` | p_GameLog_Add_Type7 | 40 | std; nTargetCharNo ← diechrrgnum u32 @0x18; nInt1 ← pkcount u32 @0x1c; nInt2 ← pkyellowtime u8 @0x20 | none found |  |
| `0x0429` | NC_LOG_GAME_PKED | `FUN_004039e0` | p_GameLog_Add_Type7 | 41 | std; nTargetCharNo ← killerdiechrrgnum u32 @0x18; nInt1 ← pkcount u32 @0x1c; nInt2 ← pkyellowtime u8 @0x20 | zone FUN_00433be0 ShinePlayer_so_KilledBy (Z03 §7.2) | same handler as 0x0428 |
| `0x042A` | NC_LOG_GAME_MK | `FUN_00404040` | p_GameLog_Add_Type8 | 42 | std; nInt1 ← mobid u16 @0x18 | none found |  |
| `0x042B` | NC_LOG_GAME_MKED | `FUN_00403aa0` | p_GameLog_Add_Type6 | 43 | std; nInt1 ← mobid u16 @0x18; nBigint1 ← exp u64 @0x1a | zone FUN_00433be0 (Z03 §7.2; mobid 0xFFFF = killer unknown; exp = lost exp, sign-extended) |  |
| `0x042C` | NC_LOG_GAME_MK_GETEXP | `FUN_00403b60` | p_GameLog_Add_Type6 | 44 | std; nInt1 ← mobid u16 @0x18; nBigint1 (high dword 0) ← exp u32 @0x1a | none found |  |
| `0x042D` | NC_LOG_GAME_MK_GETEXPINFIELD | `FUN_00403c20` | p_GameLog_Add_Type4 | 45 | nCharNo ← chrregnum u32 @0x0; nInt1 ← mobid u16 @0x4; nInt2 ← number u16 @0x6; nInt3 ← exp u32 @0x8; sMap = ""; nMapX = 0; nMapY = 0; nMapZ = 0 | zone FUN_004b6ae0 HuntingLog_MobHuntElement_mhe_Send2Log |  |
| `0x0432` | NC_LOG_GAME_SKILL_LEARN | `FUN_00403cc0` | p_GameLog_Add_Type2 | 50 | std; nInt1 ← skillid u16 @0x18; nInt2 ← skilllevel u8 @0x1a | character FUN_00411f10 (D04 §2; passive skills logged as id + 30000, map "Need") |  |
| `0x0433` | NC_LOG_GAME_SKILL_DELETE | `FUN_00403cc0` | p_GameLog_Add_Type2 | 51 | std; nInt1 ← skillid u16 @0x18; nInt2 ← skilllevel u8 @0x1a | character FUN_004121b0 (D04 §2) | same handler as 0x0432 |
| `0x0434` | NC_LOG_GAME_SKILL_USE | `FUN_00403d70` | p_GameLog_Add_Type4 | 52 | std; nInt3 ← skillexp u32 @0x18; nInt1 ← skillid u16 @0x1c; nInt2 ← skilllevel u8 @0x1e | none found |  |
| `0x0437` | NC_LOG_GAME_STATE_SET | `FUN_00403e30` | p_GameLog_Add_Type3 | 55 | std; nTargetCharNo ← actorchrregnum u32 @0x18; nTargetID ← stateid u16 @0x1c; nInt1 ← statetime u16 @0x1e | none found |  |
| `0x0438` | NC_LOG_GAME_STATE_CLEAR | `FUN_00404040` | p_GameLog_Add_Type8 | 56 | std; nInt1 ← stateid u16 @0x18 | none found | same handler as 0x042A |
| `0x0439` | NC_LOG_GAME_CHARGED_BUFF_SET | `FUN_00403ef0` | p_GameLog_Add_TypeA | 57 | nCharNo ← chrregnum u32 @0x0; nTargetID ← buff_id u16 @0x4; nInt1 ← buff_key u32 @0x6; nInt2 ← userno u32 @0xa; nInt3 ← buff_endtime ShineDateTime @0xe; nItemKey ← itemkey u64 @0x12; nTargetCharNo = 0 | character FUN_00416ae0 (D03 §9) | struct zeroed first |
| `0x043A` | NC_LOG_GAME_CHARGED_BUFF_CLR | `FUN_00403fa0` | p_GameLog_Add_TypeA | 58 | nCharNo ← chrregnum u32 @0x0; nTargetID ← buff_id u16 @0x4; nInt1 ← buff_key u32 @0x6; nInt2 ← userno u32 @0xa; nTargetCharNo = 0; nItemKey = 0; nInt3 = 0 | character FUN_00416d30 (D03 §9) | struct zeroed first |
| `0x043C` | NC_LOG_GAME_QUEST_GET | `FUN_00404040` | p_GameLog_Add_Type8 | 60 | std; nInt1 ← questid u16 @0x18 | none found | same handler as 0x042A |
| `0x043D` | NC_LOG_GAME_QUEST_COMPLETE | `FUN_00404040` | p_GameLog_Add_Type8 | 61 | std; nInt1 ← questid u16 @0x18 | none found | same handler as 0x042A |
| `0x043E` | NC_LOG_GAME_QUEST_SET_INFO | `FUN_00403cc0` | p_GameLog_Add_Type2 | 62 | std; nInt1 ← questid u16 @0x18; nInt2 ← queststatus u8 @0x1a | character FUN_00406d00, FUN_00407230, FUN_00431550 (D04 §1.2; map "Need") | same handler as 0x0432 |
| `0x043F` | NC_LOG_GAME_QUEST_ITEM_GET | `FUN_004040f0` | p_GameLog_Add_TypeC | 63 | std; nInt1 ← questid u16 @0x18; nTargetID ← itemid u16 @0x1a; nItemKey ← itemkey u64 @0x1c; nInt2 ← itemlot u16 @0x24; nInt3 = 0 | character FUN_00408e20, FUN_00409080 (D03 §7.1; map "Need", D03-B11) |  |
| `0x0440` | NC_LOG_GAME_QUEST_DELETE | `FUN_00404040` | p_GameLog_Add_Type8 | 64 | std; nInt1 ← questid u16 @0x18 | character FUN_00406eb0, FUN_00407050 (D04 §1.2) | same handler as 0x042A |
| `0x0441` | NC_LOG_GAME_KQ_ENTER | `FUN_004041c0` | p_GameLog_Add_Type2 | 65 | std; nInt1 ← KQ_ID u16 @0x18; nInt2 ← KQ_Handle u32 @0x1a | zone FUN_00496280 KingdomQuestGate_KingdomQuestGateKeeper_erb_happen (Z08 §4) | struct zeroed first |
| `0x0442` | NC_LOG_GAME_KQ_LEAVE | `FUN_00404270` | p_GameLog_Add_Type4 | 66 | std; nInt1 ← KQ_ID u16 @0x18; nInt2 ← KQ_Handle u32 @0x1a; nInt3 ← Leave_Status u8 @0x1e | zone FUN_00429e00 (Z08 §4) | struct zeroed first |
| `0x0445` | NC_LOG_GAME_ITEM_BREAK | `FUN_004043f0` | p_GameLog_Add_TypeJ | 69 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nTargetID ← itemid u16 @0xc; nInt1 ← itemlot u16 @0xe; sMap = ""; nMapX = 0; nMapY = 0; nMapZ = 0; nInt2 = 0 | character FUN_0040eb50, FUN_00410a80, FUN_00411c90, FUN_00426050 (D03 §7.3) | struct zeroed first |
| `0x0446` | NC_LOG_GAME_ITEM_TAKE | `FUN_00404330` | p_GameLog_Add_TypeJ | 510 (0x1FE) | std; nItemKey ← itemkey u64 @0x18; nInt1 ← itemlot u16 @0x20; nInt2 ← iteminven ITEM_INVEN @0x22; nTargetID ← itemid u16 @0x24 | character FUN_0040b760, FUN_0040c500 (D03 §3.4; map "Need"/"Need Cen") | nType = NC_LOG_GAME_ITEM_TAKE_INVEN_EXT (pdb2017) |
| `0x0447` | NC_LOG_GAME_ITEM_DROP | `FUN_00404490` | p_GameLog_Add_TypeJ | 511 (0x1FF) | std; nItemKey ← itemkey u64 @0x18; nInt1 ← itemlot u16 @0x20; nInt2 ← iteminven ITEM_INVEN @0x22; nTargetID ← itemid u16 @0x24 | character FUN_0040b140, FUN_0040b4d0 (D03 §3.4) | nType = …_ITEM_DROP_INVEN_EXT (pdb2017) |
| `0x0448` | NC_LOG_GAME_ITEM_BUY | `FUN_00404550` | p_GameLog_Add_TypeA | 512 (0x200) | nCharNo ← chrregnum u32 @0x0; nTargetCharNo ← itemseller u8 @0x4; nTargetID ← itemid u16 @0x5; nItemKey ← itemkey u64 @0x7; nInt1 ← itemlot u16 @0xf; nInt2 ← iteminven ITEM_INVEN @0x11; nInt3 ← itemmoney u32 @0x13 | character FUN_00409300, FUN_004096d0, FUN_00420250, FUN_00420710, FUN_00425900 (D03 §2.1) | nType = …_ITEM_BUY_INVEN_EXT (pdb2017) |
| `0x0449` | NC_LOG_GAME_ITEM_SELL | `FUN_004045f0` | p_GameLog_Add_TypeA | 513 (0x201) | nCharNo ← chrregnum u32 @0x0; nTargetCharNo ← itembuyer u8 @0x4; nTargetID ← itemid u16 @0x5; nItemKey ← itemkey u64 @0x7; nInt1 ← itemlot u16 @0xf; nInt2 ← iteminven ITEM_INVEN @0x11; nInt3 ← itemmoney u32 @0x13 | character FUN_00409a20, FUN_00409ec0 (D03 §2.2) | nType = …_ITEM_SELL_INVEN_EXT (pdb2017) |
| `0x044A` | NC_LOG_GAME_ITEM_TRADE | `FUN_00404690` | p_GameLog_Add_TypeA | 74 | nCharNo ← chrregnum u32 @0x0; nTargetCharNo ← chrregnumtaker u32 @0x4; nTargetID ← itemid u16 @0x8; nItemKey ← itemkey u64 @0xa; nInt1 ← itemlot u16 @0x12; nInt2 = 0; nInt3 = 0 | character FUN_0040ca80 (D03 §14) |  |
| `0x044B` | NC_LOG_GAME_ITEM_USE | `FUN_00404730` | p_GameLog_Add_TypeC | 514 (0x202) | std; nTargetID ← itemid u16 @0x18; nItemKey ← itemkey u64 @0x1a; nInt1 ← itemnumofuse u16 @0x22; nInt2 ← iteminven ITEM_INVEN @0x24; nInt3 ← itemnumofremain u16 @0x26 | none found | nType = …_ITEM_USE_INVEN_EXT (pdb2017) |
| `0x044C` | NC_LOG_GAME_ITEM_INVEN_MOVE | `FUN_00404800` | p_GameLog_Add_TypeA | 515 (0x203) | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← iteminvenfrom ITEM_INVEN @0xc; nInt2 ← iteminvento ITEM_INVEN @0xe; nTargetID ← guildregnum u32 @0x10; nTargetCharNo = 0; nInt3 = 0 | character FUN_0040a1e0, FUN_0040a4b0, FUN_0040eb50, FUN_00426050 (D03 §3.2) | nType = …_INVEN_MOVE_INVEN_EXT (pdb2017) |
| `0x044D` | NC_LOG_GAME_ITEM_EQUIP | `FUN_004048a0` | p_GameLog_Add_TypeD | 516 (0x204) | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← iteminvenfrom ITEM_INVEN @0xc; nInt2 ← iteminvento ITEM_INVEN @0xe | none found | nType = …_ITEM_EQUIP_INVEN_EXT (pdb2017) |
| `0x044E` | NC_LOG_GAME_ITEM_UNEQUIP | `FUN_00404930` | p_GameLog_Add_TypeD | 517 (0x205) | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← iteminvenfrom ITEM_INVEN @0xc; nInt2 ← iteminvento ITEM_INVEN @0xe | none found | nType = …_ITEM_UNEQUIP_INVEN_EXT (pdb2017) |
| `0x044F` | NC_LOG_GAME_ITEM_CREATE | `FUN_004049c0` | p_GameLog_Add_TypeB | 518 (0x206) | nCharNo ← chrregnum u32 @0x0; nTargetCharNo ← itemmaker u32 @0x4; nItemKey ← itemkey u64 @0x8; nTargetID ← itemid u16 @0x10; nInt1 ← iteminvento ITEM_INVEN @0x12; sMap = "RouN"; nMapX = 0; nMapY = 0; nMapZ = 0; nInt2 = 0; nInt3 = 0 | character (13 functions; D02 §12, D03 §7.1, D04 §6.4) | nType = …_ITEM_CREATE_INVEN_EXT (pdb2017); map "RouN" (D05-B4) |
| `0x0450` | NC_LOG_GAME_ITEM_STORE_IN | `FUN_00404a70` | p_GameLog_Add_Type9 | 519 (0x207) | std; nItemKey ← itemkey u64 @0x18; nInt1 ← iteminvenfrom ITEM_INVEN @0x20; nInt2 ← iteminvento ITEM_INVEN @0x22 | none found | nType = …_STORE_IN_INVEN_EXT (pdb2017) |
| `0x0451` | NC_LOG_GAME_ITEM_STORE_OUT | `FUN_00404b30` | p_GameLog_Add_Type9 | 520 (0x208) | std; nItemKey ← itemkey u64 @0x18; nInt1 ← iteminvenfrom ITEM_INVEN @0x20; nInt2 ← iteminvento ITEM_INVEN @0x22 | none found | nType = …_STORE_OUT_INVEN_EXT (pdb2017) |
| `0x0452` | NC_LOG_GAME_ITEM_UPGRADE | `FUN_00404bf0` | p_GameLog_Add | 82 | nCharNo, sMap, nMapX, nMapY as std; nItemKey ← itemkey u64 @0x18; then the GameLog view (D05-B2, see below): nMapZ ← u16 @0x20; nInt1 ← u8 @0x22; nInt2 ← u8 @0x23; nInt3 ← u16 @0x24; nTargetID ← u16 @0x26; nTargetCharNo ← u16 @0x28; nBigint1 ← u8 @0x2a (low dword) + u16 @0x2b (high dword) | zone FUN_0053b900, FUN_0053bd20, FUN_0053c0f0 (Z05 §8.1) | reads a 0x2D-byte layout; zone sends 0x2B (D05-B2) |
| `0x0453` | NC_LOG_GAME_ITEM_PRODUCT | `FUN_004052c0` | p_GameLog_Add | 83 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nTargetID ← itemid u16 @0xc; nInt1 ← itemlot_inc u16 @0xe; nInt2 ← itemlot_before u16 @0x10; nInt3 ← itemlot_last u16 @0x12; sMap = ""; nMapX = 0; nMapY = 0; nMapZ = 0; nTargetCharNo = 0; nBigint1 = 0 | character FUN_00419c00 (D03 §6.6) | struct zeroed first |
| `0x0454` | NC_LOG_GAME_ITEM_TITLE | `FUN_00404ce0` | p_GameLog_Add_TypeG | 84 | nCharNo ← chrregnum u32 @0x0; nItemKey ← WeaponItemKey u64 @0x4; nBigint1 ← LicenseItemKey u64 @0xc; nInt1 ← LicenseMobID u16 @0x14; nTargetID ← (2016 only) u16 @0x16 u16 @0x16; nInt2 ← (2016 only) u16 @0x18 u16 @0x18; sMap = ""; nMapX = 0; nMapY = 0; nMapZ = 0 | character FUN_00412790 (D04 §4.1; 0x1A bytes, D04-B9) | struct zeroed first |

Notes on single rows:

- **0x0452 ITEM_UPGRADE** (original bug) D05-B2. The zone (`FUN_0053b900` and two siblings, Z05 §8.1) sends 0x2B payload bytes in
  the 2017 PDB layout: `u64 itemkey @0x18, u8 itemoldlevel @0x20, u8 itemnewlevel @0x21, u16 left_item_id @0x22,
  u16 right_item_id @0x24, u16 middle_item_id @0x26, Element randomoption_elemental @0x28 (u16 + u8)`. The GameLog handler
  reads a layout two bytes longer, as if a u16 sat at 0x20: `nMapZ ← u16 @0x20` (= old level | new level << 8),
  `nInt1/nInt2 ← the two bytes of left_item_id`, `nInt3 ← right_item_id`, `nTargetID ← middle_item_id`,
  `nTargetCharNo ← u16 of the element`, `nBigint1 = u8 @0x2a | u16 @0x2b << 32`. Bytes 0x2B–0x2C lie past the zone packet,
  so the high dword of `nBigint1` is stale receive-buffer data.
- **0x0415 MOVE**: the start map name in the packet is ignored; `sMap` is the constant `"NEED"` (`DAT_00434958`)
  (original bug) D05-B3.
- **0x044F ITEM_CREATE**: the packet has no position; the handler writes `sMap = "RouN"`, x = y = z = 0 (original bug)
  D05-B4. Together with the Character server's constant map names (`"Need"`, `"Need Cen"`, D03-B11; `"UNUSE"`, D02-B9),
  `sMap` of the item logs carries no information in 2016.
- **0x0412 DELETE_AVATAR** has two senders: the WM's delete path (W01 §4.1, `wm FUN_0040a010`) and the Character server's
  delete handler (D02 §3.4, `character FUN_00404cd0`). If both run for one deletion, `tGameLog` gets two nType-18 rows
  *(inferred; the sender items own the flow)*.
- **0x042B MKED** from the zone's death handler: `mobid = 0xFFFF` when the killer is unknown; `exp` is the lost experience
  as a sign-extended s64 (Z03 §7.2).

### 2.4 Commands no 2016 server sends

No 2016 Zone, WM, Character or Login function builds these packets (searched: `layouts.json` send sites of all four binaries,
and every zone function that references the GameLog session pool `0x14d43958`). Their handlers are live but unreachable from
the 2016 servers *(inferred: a send built through an unrecognised path would be missed)*:

0x0401, 0x0402 (so 0x0403 is never sent), 0x0414 HIT, 0x0415 MOVE, 0x0419 PRISON, 0x041A PRISON_RELEASE, 0x041F LEVEL_DOWN,
0x0428 PK, 0x042A MK, 0x042C MK_GETEXP, 0x0434 SKILL_USE, 0x0437 STATE_SET, 0x0438 STATE_CLEAR, 0x043C QUEST_GET,
0x043D QUEST_COMPLETE, 0x044B ITEM_USE, 0x044D ITEM_EQUIP, 0x044E ITEM_UNEQUIP, 0x0450 ITEM_STORE_IN, 0x0451 ITEM_STORE_OUT.

## 3. NC_LOG_GAME handlers, commands 85–857 (CParserGameLog, part 2)

Every handler of this part has the skeleton of §1.3 (no length check, D05-B1). Columns, `std` and the sender column as in §2.3.
61 of the 84 registrations log a row; the other 23 go to `fc_ReturnTrue` (§3.3). Senders: `layouts.json` send sites of
Zone/WM/Character/Login and the zone functions that use the GameLog session pool `0x14d43958`; every sender's payload size
equals the size the handler reads (and the 2017 PDB struct size), so no part-2 row has the D05-B2 kind of shift.

### 3.1 All logging handlers of this part

| Opcode | Name | Handler | Procedure | nType | Columns ← fields | Sender (2016) | Note |
|---|---|---|---|---|---|---|---|
| `0x0455` | NC_LOG_GAME_ITEM_MOB_DROP | `FUN_00404d90` | p_GameLog_Add_TypeJ | 85 | std; nItemKey ← itemkey u64 @0x18; nTargetID ← itemid u16 @0x20; nInt1 ← itemlot u16 @0x22; nInt2 ← dropmobid u16 @0x24 | none found |  |
| `0x0456` | NC_LOG_GAME_ITEM_MERGE | `FUN_00404e60` | p_GameLog_Add_TypeF | 86 | std; nTargetID ← itemid u16 @0x18; nItemKey ← itemkeyadd u64 @0x1a; nBigint1 ← itemkeysub u64 @0x22; nInt1 ← itemlot u16 @0x2a; nInt2 ← itemlotadd u16 @0x2c; nInt3 ← itemlotsub u16 @0x2e | character FUN_0040bbb0, FUN_0040c000 (D03 §3.3) |  |
| `0x0457` | NC_LOG_GAME_ITEM_SPLIT | `FUN_00404f40` | p_GameLog_Add_TypeG | 87 | std; nTargetID ← itemid u16 @0x18; nItemKey ← itemkey u64 @0x1a; nBigint1 ← itemkeynew u64 @0x22; nInt1 ← itemlotsplit u16 @0x2a; nInt2 ← itemlotremain u16 @0x2c | character FUN_004104b0 (D03 §3.3) |  |
| `0x0458` | NC_LOG_GAME_ITEM_SOULSTONEBUY | `FUN_00405010` | p_GameLog_Add_TypeK | 88 | std; nInt1 ← flag u8 @0x18; nInt2 ← number u16 @0x19; nBigint1 ← price u64 @0x1b | none found |  |
| `0x0459` | NC_LOG_GAME_ITEM_USELOT | `FUN_004050d0` | p_GameLog_Add_TypeD | 89 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← itemid u16 @0xc; nInt2 ← itemlot u16 @0xe | character FUN_0040d5e0 and 16 more (D02 §7.1, D03 §4, D04 §4.1) |  |
| `0x045A` | NC_LOG_GAME_ITEM_USEALL | `FUN_00405160` | p_GameLog_Add_TypeD | 90 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← itemid u16 @0xc; nInt2 = 0 | character FUN_0040d800 and 11 more (D02 §7.1, D03 §4) |  |
| `0x045B` | NC_LOG_GAME_ITEM_BOOTH_BUY | `FUN_004051f0` | p_GameLog_Add | 91 | nCharNo ← chrregnum_buyer u32 @0x0; nTargetCharNo ← chrregnum_seller u32 @0x4; nItemKey ← itemkey u64 @0x8; nTargetID ← itemid u16 @0x10; nInt1 ← tradelot u16 @0x12; nInt2 ← money u64 @0x14 (low dword only); nInt3 ← newlot u16 @0x1c; nBigint1 ← newmoney u64 @0x1e; sMap = "UNUSE" | character FUN_0040f510, FUN_0040f950, FUN_0040feb0 (D03 §14) | struct zeroed first; nInt2 = low dword of money (§3.2) |
| `0x045C` | NC_LOG_GAME_ITEM_BOOTH_SELL | `FUN_004051f0` | p_GameLog_Add | 92 | nCharNo ← chrregnum_seller u32 @0x0; nTargetCharNo ← chrregnum_buyer u32 @0x4; nItemKey ← itemkey u64 @0x8; nTargetID ← itemid u16 @0x10; nInt1 ← tradelot u16 @0x12; nInt2 ← money u64 @0x14 (low dword only); nInt3 ← newlot u16 @0x1c; nBigint1 ← newmoney u64 @0x1e; sMap = "UNUSE" | character FUN_0040f510, FUN_0040f950, FUN_0040feb0 (D03 §14) | struct zeroed first; same handler as 0x045B; buyer/seller swap columns |
| `0x045D` | NC_LOG_GAME_ITEM_PRODUCT_STUFF | `FUN_00405370` | p_GameLog_Add | 93 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nTargetID ← itemid u16 @0xc; nBigint1 ← itemkey_stuff u64 @0xe; nTargetCharNo ← itemid_stuff u16 @0x16; nInt1 ← itemlot_stuff_use u16 @0x18; nInt2 ← itemlot_stuff_before u16 @0x1a; nInt3 ← itemlot_stuff_last u16 @0x1c | character FUN_00419c00 (D03 §6.6) | struct zeroed first |
| `0x045E` | NC_LOG_GAME_MONEY_DEPOSIT | `FUN_004054f0` | p_GameLog_Add_TypeK | 94 | nCharNo ← chrregnum u32 @0x0; nInt1 ← deposit_money u32 @0x4; nInt2 ← userregnum u32 @0x8; nBigint1 ← user_result_money u64 @0xc; sMap = "UNUSE" | character FUN_00410fa0 (D03 §5.1) | struct zeroed first |
| `0x045F` | NC_LOG_GAME_MONEY_WITHDRAW | `FUN_004054f0` | p_GameLog_Add_TypeK | 95 | nCharNo ← chrregnum u32 @0x0; nInt1 ← withdraw_money u32 @0x4; nInt2 ← userregnum u32 @0x8; nBigint1 ← user_result_money u64 @0xc; sMap = "UNUSE" | character FUN_00411200 (D03 §5.1) | struct zeroed first; same handler as 0x045E |
| `0x0460` | NC_LOG_GAME_MONEY_TRADE_INCOME | `FUN_004055a0` | p_GameLog_Add_TypeG | 96 | nCharNo ← chrregnum u32 @0x0; nInt1 ← chrregnum_from u32 @0x4; nBigint1 ← cen u64 @0x8; nItemKey ← result_money u64 @0x10; sMap = "UNUSE" | character FUN_0040ca80 (D03 §14) | struct zeroed first |
| `0x0461` | NC_LOG_GAME_MONEY_TRADE_OUTGO | `FUN_004055a0` | p_GameLog_Add_TypeG | 97 | nCharNo ← chrregnum u32 @0x0; nInt1 ← chrregnum_to u32 @0x4; nBigint1 ← cen u64 @0x8; nItemKey ← result_money u64 @0x10; sMap = "UNUSE" | character FUN_0040ca80 (D03 §14) | struct zeroed first; same handler as 0x0460 |
| `0x0462` | NC_LOG_GAME_MONEY_CHANGE | `FUN_00405660` | p_GameLog_Add_TypeG | 0 (not set) | nItemKey ← prev_cen u64 @0x4; nBigint1 ← last_cen u64 @0xc; nInt1 ← adv_cen u64 @0x14 (low dword only) | character FUN_0040c700 (D03 §3.5), FUN_0040e710 (D03 §7.2) | struct zeroed first; nType 0, no nCharNo (D05-B6) |
| `0x0464` | NC_LOG_GAME_ENCHANNT | `FUN_004056f0` | p_GameLog_Add_Type4 | 100 | std; nInt1 ← enchanteid u8 @0x18; nInt2 ← enchantecount u16 @0x19; nInt3 ← enchantetotalcount u16 @0x1b | none found |  |
| `0x0465` | NC_LOG_GAME_DISENCHANT | `FUN_004056f0` | p_GameLog_Add_Type4 | 101 | std; nInt1 ← disenchanteid u8 @0x18; nInt2 ← disenchantecount u16 @0x19; nInt3 ← disenchantetotalcount u16 @0x1b | none found | same handler as 0x0464 |
| `0x0478` | NC_LOG_GAME_FRIEND_ADD | `FUN_004057b0` | p_GameLog_Add_TypeH | 120 | std; nTargetCharNo ← addchrregnum u32 @0x18 | none found |  |
| `0x0479` | NC_LOG_GAME_FRIEND_DELETE | `FUN_004057b0` | p_GameLog_Add_TypeH | 121 | std; nTargetCharNo ← delchrregnum u32 @0x18 | none found | same handler as 0x0478 |
| `0x0482` | NC_LOG_GAME_MAS_PUP_ADD | `FUN_00405860` | p_GameLog_Add_TypeI | 130 | std; nTargetCharNo ← addchrregnum u32 @0x18; nTargetID ← type u8 @0x1c | none found |  |
| `0x0483` | NC_LOG_GAME_MAS_PUP_DELETE | `FUN_00405860` | p_GameLog_Add_TypeI | 131 | std; nTargetCharNo ← delchrregnum u32 @0x18; nTargetID ← type u8 @0x1c | none found | same handler as 0x0482 |
| `0x048C` | NC_LOG_GAME_GUILD_CREATE | `FUN_00405910` | p_GameLog_Add_TypeG | 140 | nCharNo ← chrregnum u32 @0x0; nTargetID ← guildregnum u32 @0x4; nInt1 ← money_use u64 @0x8 (low dword only); nBigint1 ← money_last u64 @0x10; sMap ← sGuildName Name4 @0x18; nMapX = 0 | character FUN_00438440 (D04 §6.2) | struct zeroed first; guild name in sMap; nInt1 = low dword of money_use |
| `0x048D` | NC_LOG_GAME_GUILD_DELETE | `FUN_004059d0` | p_GameLog_Add_TypeI | 141 | nTargetID ← guildregnum u32 @0x0; sMap ← sGuildName Name4 @0x4; nMapX = 0 | character FUN_00414740 (D04 §6.2) | struct zeroed first; guild name in sMap; no character |
| `0x04A3` | NC_LOG_GAME_GUILD_M_GRADE | `FUN_00405a70` | p_GameLog_Add_TypeA | 163 | nCharNo ← chrregnum u32 @0x0; nInt1 ← guildregnum u32 @0x4; nTargetCharNo ← chrregnum_grade u32 @0x8; nInt2 ← guildmembergrade_old u8 @0xc; nInt3 ← guildmembergrade_new u8 @0xd | character FUN_00436a40 (D04 §6.3) | struct zeroed first; nType written as the constant 163 |
| `0x04AA` | NC_LOG_GAME_GUILD_K_MONEY_WITHDRAW | `FUN_00405b10` | p_GameLog_Add_TypeG | 170 | nCharNo ← chrregnum u32 @0x0; nInt1 ← withdraw_money u32 @0x4; nTargetID ← guildregnum u32 @0x8; nBigint1 ← guild_result_money u64 @0xc; sMap = "UNUSE" | character FUN_00411460 (D03 §5.2), FUN_0041c880, FUN_0041caa0 (D03 §5.3) | struct zeroed first |
| `0x04AB` | NC_LOG_GAME_GUILD_G_REWARD_MONEY | `FUN_00405bc0` | p_GameLog_Add_TypeG | 171 | nTargetID ← guildregnum u32 @0x0; nItemKey ← old_money u64 @0x4; nBigint1 ← new_money u64 @0xc; nCharNo = 0; nInt1 = 0 | character FUN_004076a0 (D04 §6.4) | struct zeroed first; no character; guild in nTargetID |
| `0x04AC` | NC_LOG_GAME_GUILD_4_REWARD_FAME | `FUN_00405c70` | p_GameLog_Add_TypeA | 172 | nTargetID ← guildregnum u32 @0x0; nInt2 ← old_fame u32 @0x4; nInt3 ← new_fame u32 @0x8; nCharNo = 0; nInt1 = 0 | character FUN_004076a0 (D04 §6.4) | struct zeroed first; no character |
| `0x04AD` | NC_LOG_GAME_GUILD_G_REWARD_EXP | `FUN_00405bc0` | p_GameLog_Add_TypeG | 173 | nTargetID ← guildregnum u32 @0x0; nItemKey ← old_exp u64 @0x4; nBigint1 ← new_exp u64 @0xc; nCharNo = 0; nInt1 = 0 | character FUN_004076a0 (D04 §6.4) | struct zeroed first; same handler as 0x04AB |
| `0x04AE` | NC_LOG_GAME_GUILD_4_TOURNAMENT_RESULT | `FUN_00405d10` | p_GameLog_Add_TypeA | 174 | nInt1 ← guildtournament_no u32 @0x0; nInt2 ← position u32 @0x4; nTargetID ← guildregnum u32 @0x8; nInt3 ← result u32 @0xc; nCharNo = 0 | character FUN_004161c0 (D04 §6.4) | struct zeroed first; no character |
| `0x04AF` | NC_LOG_GAME_GUILD_G_REWARD_TOKEN | `FUN_00405bc0` | p_GameLog_Add_TypeG | 175 | nTargetID ← guildregnum u32 @0x0; nItemKey ← old_token u64 @0x4; nBigint1 ← new_token u64 @0xc; nCharNo = 0; nInt1 = 0 | character FUN_004076a0 (D04 §6.4) | struct zeroed first; same handler as 0x04AB |
| `0x04B0` | NC_LOG_GAME_GUILD_G_REWARD_MONEY_DIVISION | `FUN_00405bc0` | p_GameLog_Add_TypeG | 176 | nTargetID ← @0x0 u32 @0x0; nItemKey ← @0x4 u64 @0x4; nBigint1 ← @0xc u64 @0xc; nCharNo = 0; nInt1 = 0 | character FUN_004076a0 (D04 §6.4; tournament money division) | struct zeroed first; same handler as 0x04AB; no PDB struct, names ours |
| `0x04BE` | NC_LOG_GAME_CHARGE_WITHDRAW | `FUN_00405db0` | p_GameLog_Add_Type4 | 190 | nCharNo ← chrregnum u32 @0x0; nInt1 ← ChargedItemOrderNo u32 @0x4; nInt2 ← ChargedItemCode u32 @0x8; nInt3 ← ChargedItemAmount u32 @0xc; nMapX = 0; nMapY = 0; nMapZ = 0; sMap = "UNUSE" | character FUN_004118a0 (D03 §5.4) |  |
| `0x04C9` | NC_LOG_GAME_MINIHOUSE_BUILDING | `FUN_00406280` | p_GameLog_Add_Type1 | 201 | std | zone FUN_00571f20 ShinePlayer_sp_NC_MINIHOUSE_LOGINCOMPLETE_REQ (Z07 §6.4; owner enters) | struct zeroed first |
| `0x04CA` | NC_LOG_GAME_MINIHOUSE_VISIT | `FUN_00406320` | p_GameLog_Add_TypeH | 202 | nTargetCharNo ← owner_chrregnum u32 @0x0; nCharNo ← visitor_chrregnum u32 @0x4; sMap ← mappos.MapName Name3 @0x8; nMapX ← mappos.x u32 @0x14; nMapY ← mappos.y u32 @0x18 | zone FUN_00571f20 (Z07 §6.4; a visitor enters) | struct zeroed first |
| `0x0518` | NC_LOG_GAME_QUEST_REWARD_EXP | `FUN_00405e50` | p_GameLog_Add_TypeG | 280 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nItemKey ← old_exp u64 @0x6; nBigint1 ← new_exp u64 @0xe | character FUN_00431550 (D04 §1.2), FUN_00432770 (D03 §7.5) | struct zeroed first |
| `0x0519` | NC_LOG_GAME_QUEST_REWARD_MONEY | `FUN_00405e50` | p_GameLog_Add_TypeG | 281 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nItemKey ← old_money u64 @0x6; nBigint1 ← new_money u64 @0xe | character FUN_00431550 (D04 §1.2), FUN_004321d0 (D04 §3), FUN_00432770 (D03 §7.5) | struct zeroed first; same handler as 0x0518 |
| `0x051A` | NC_LOG_GAME_QUEST_REWARD_ITEM | `FUN_00405ef0` | p_GameLog_Add_TypeJ | 282 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nItemKey ← itemkey u64 @0x6; nTargetID ← itemid u16 @0xe | character FUN_00431550, FUN_00432770 | struct zeroed first |
| `0x051B` | NC_LOG_GAME_QUEST_REWARD_ABSTATE | `FUN_004060d0` | p_GameLog_Add_Type3 | 283 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nTargetID ← abstateid u16 @0x6 | none found | struct zeroed first |
| `0x051C` | NC_LOG_GAME_QUEST_REWARD_FAME | `FUN_00405f90` | p_GameLog_Add_Type4 | 284 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nInt2 ← old_fame u32 @0x6; nInt3 ← new_fame u32 @0xa | character FUN_00431550, FUN_004321d0, FUN_00432770 | struct zeroed first |
| `0x051D` | NC_LOG_GAME_QUEST_REWARD_PET | `FUN_00406160` | p_GameLog_Add_Type3 | 285 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nTargetID ← petid u32 @0x6 | none found | struct zeroed first |
| `0x051E` | NC_LOG_GAME_QUEST_REWARD_MINIHOUSE | `FUN_004061f0` | p_GameLog_Add_Type3 | 286 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nTargetID ← minihouseid u8 @0x6 | none found | struct zeroed first |
| `0x051F` | NC_LOG_GAME_QUEST_REWARD_TITLE | `FUN_00406030` | p_GameLog_Add_Type4 | 287 | nCharNo ← chrregnum u32 @0x0; nInt1 ← questid u16 @0x4; nInt2 ← ct_type u8 @0x6; nInt3 ← ct_elementno u8 @0x7 | character FUN_00431550, FUN_00432770 | struct zeroed first |
| `0x0554` | NC_LOG_GAME_ITEM_PUT_ON_BELONGED | `FUN_004063e0` | p_GameLog_Add_TypeD | 521 (0x209) | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; nInt1 ← iteminvenfrom ITEM_INVEN @0xc; nInt2 ← iteminvento ITEM_INVEN @0xe | character FUN_0040a8f0 (D03 §3.1); zone FUN_0045e810 ShinePlayer_sp_HorseItemSave (§3.2) | nType = …_PUT_ON_BELONGED_EXT (pdb2017) |
| `0x05EA` | NC_LOG_REGENLOCATESAVE_CMD | `FUN_004069e0` | p_GameLog_Add_Type4 | 490 | nCharNo ← ChrRegNum u32 @0x0; sMap ← SaveMap Name3 @0x4; nMapX ← SaveLocate.x u32 @0x10; nMapY ← SaveLocate.y u32 @0x14; nInt2 ← KQHandle u32 @0x18; nMapZ ← InvalidLocate.x u32 @0x1c; nInt1 ← InvalidLocate.y u32 @0x20; nInt3 ← Flag u16 @0x24 | zone FUN_00552350 ShinePlayer_so_ply_ToNormalLoc (Z01 §7.4) | struct zeroed first; saved map in sMap, rejected position in nMapZ/nInt1 |
| `0x0612` | NC_LOG_GAME_ITEM_CW_BREAKATZERO | `FUN_00405430` | p_GameLog_Add_Type9 | 530 | nCharNo ← chrregnum u32 @0x0; nItemKey ← itemkey u64 @0x4; sMap ← mappos.MapName Name3 @0xc; nMapX ← mappos.x u32 @0x18; nMapY ← mappos.y u32 @0x1c; nInt1 = 0; nInt2 = 0 | zone FUN_00520840 ShinePlayer_smo_ply_CostumWeaponChargeDecrease, FUN_00520aa0 …CostumShieldChargeDecrease (§3.2) | struct zeroed first |
| `0x0658` | NC_LOG_WEDDING_PROPOSE_EXE | `FUN_00406500` | p_GameLog_Add_TypeH | 600 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | character FUN_00418e40 (D02 §11) | struct zeroed first |
| `0x0659` | NC_LOG_WEDDING_PROPOSE_CANCEL | `FUN_00406500` | p_GameLog_Add_TypeH | 601 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | character FUN_00418fc0 (D02 §11) | struct zeroed first; same handler as 0x0658 |
| `0x065A` | NC_LOG_WEDDING_DIVORCE_REQ | `FUN_00406470` | p_GameLog_Add_Type3 | 602 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4; nInt1 ← DivorceType u8 @0x8 | character FUN_00419250, FUN_004193d0 (D02 §11) | struct zeroed first |
| `0x065B` | NC_LOG_WEDDING_DIVORCE_EXE | `FUN_00406500` | p_GameLog_Add_TypeH | 603 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | character FUN_00419550 (D02 §11) | struct zeroed first; same handler as 0x0658 |
| `0x065C` | NC_LOG_WEDDING_DIVORCE_CANCEL | `FUN_00406500` | p_GameLog_Add_TypeH | 604 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | character FUN_00419730 (D02 §11) | struct zeroed first; same handler as 0x0658 |
| `0x065D` | NC_LOG_WEDDING_HALL_RESERVE | `FUN_00406500` | p_GameLog_Add_TypeH | 605 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | zone FUN_005a2330 ShinePlayer_sp_NC_ACT_WEDDING_HALL_RESERV_REQ (Z02 §10) | struct zeroed first; same handler as 0x0658 |
| `0x065E` | NC_LOG_WEDDING_HALL_START | `FUN_00406500` | p_GameLog_Add_TypeH | 606 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | zone FUN_005a25a0 WeddingHall_wh_Start (§3.2) | struct zeroed first; same handler as 0x0658 |
| `0x065F` | NC_LOG_WEDDING_HALL_CANCEL | `FUN_00406500` | p_GameLog_Add_TypeH | 607 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | zone FUN_005a2b60 (wh_Cancel inlined into the couple-entrance answer, §3.2) | struct zeroed first; same handler as 0x0658 |
| `0x0660` | NC_LOG_WEDDING_WEDDING_EXE | `FUN_00406500` | p_GameLog_Add_TypeH | 608 | nCharNo ← CharRegisterNumber u32 @0x0; nTargetCharNo ← PartnerRegisterNumber u32 @0x4 | character FUN_00419920 (D02 §11) | struct zeroed first; same handler as 0x0658 |
| `0x0752` | NC_LOG_GUILD_ACADEMY_JOIN | `FUN_00406590` | p_GameLog_Add_Type5 | 850 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nCharNo u32 @0x4; nInt2 = 0 | none found |  |
| `0x0753` | NC_LOG_GUILD_ACADEMY_LEAVE | `FUN_00406590` | p_GameLog_Add_Type5 | 851 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nCharNo u32 @0x4; nInt2 = 0 | none found | same handler as 0x0752 |
| `0x0754` | NC_LOG_GUILD_ACADEMY_VANISH | `FUN_004066c0` | p_GameLog_Add_Type5 | 852 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nVanishCharNo u32 @0x4; nInt2 ← nTargetCharNo u32 @0x8 | none found |  |
| `0x0755` | NC_LOG_GUILD_ACADEMY_SET_MASTER | `FUN_004066c0` | p_GameLog_Add_Type5 | 853 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nSetCharNo u32 @0x4; nInt2 ← nNewMasterCharNo u32 @0x8 | character FUN_0041c1e0 (D04 §9.2) | same handler as 0x0754 |
| `0x0756` | NC_LOG_GUILD_ACADEMY_GRADUATE | `FUN_00406620` | p_GameLog_Add_TypeA | 854 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nCharNo u32 @0x4; nInt2 ← nLevel u8 @0x8; nInt3 ← nClass u8 @0x9 | none found | struct zeroed first |
| `0x0757` | NC_LOG_GUILD_ACADEMY_GUILD_INVITE | `FUN_004066c0` | p_GameLog_Add_Type5 | 855 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nInveteCharNo u32 @0x4; nInt2 ← nTargetCharNo u32 @0x8 | none found | same handler as 0x0754 |
| `0x0758` | NC_LOG_GUILD_ACADEMY_CHAT_BAN | `FUN_004066c0` | p_GameLog_Add_Type5 | 856 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nChatBanCharNo u32 @0x4; nInt2 ← nTargetCharNo u32 @0x8 | none found | same handler as 0x0754 |
| `0x0759` | NC_LOG_GUILD_ACADEMY_MASTER_TELEPORT | `FUN_00406750` | p_GameLog_Add_Type2 | 857 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nTeleportCharNo u32 @0x4; nInt2 ← nTargetCharNo u32 @0x8; sMap ← ToMapPosition.MapName Name3 @0xc; nMapX ← ToMapPosition.x u32 @0x18; nMapY ← ToMapPosition.y u32 @0x1c; nMapZ = 0 | none found | struct zeroed first |

### 3.2 Notes on single rows and the zone senders

- **0x0462 MONEY_CHANGE** `FUN_00405660` (original bug) D05-B6: the handler zeroes the TypeG struct and copies only
  `prev_cen → nItemKey`, `last_cen → nBigint1` and the low dword of `adv_cen → nInt1`. It never writes `nType` or `nCharNo`, so
  every money-change row has `nType = 0` and `nCharNo = 0` and cannot be attributed to a character or told apart from other
  nType-0 rows. The Character server sends it on every money change of a character (D03 §3.5, §7.2; its "before" value is
  itself wrong for gains, D03-B7).
- **64-bit values cut to 32 bits** (the procedure has no second 64-bit column, so this looks deliberate): BOOTH_BUY/SELL
  `money` (u64) → `nInt2`, GUILD_CREATE `money_use` → `nInt1`, MONEY_CHANGE `adv_cen` → `nInt1`. Amounts ≥ 2³² would be
  logged wrapped; 2016 money is below 2³² per transaction in practice *(inferred)*.
- **Constant map names**: the money/booth/charge handlers (0x045B/0x045C, 0x045E/0x045F, 0x0460/0x0461, 0x04AA, 0x04BE) write
  `sMap = "UNUSE"` (`s_UNUSE_00434968`, 6 bytes with the NUL); the packets have no position. GUILD_CREATE/GUILD_DELETE put
  the 16-byte guild name (`Name4`, copied as four dwords) into `sMap`; the name is terminated by the zero `nMapX` that follows
  in the struct even when it fills all 16 bytes, and the wrapper binds 16 characters.
- **Guild rows** 0x04AB–0x04B0: `nCharNo = 0`, the guild number goes to `nTargetID`, old → `nItemKey`, new → `nBigint1`
  (64-bit money/exp/token; fame and tournament values are u32 in `nInt2/nInt3`). 0x04B0 G_REWARD_MONEY_DIVISION has no 2017
  PDB struct; its layout is the 0x04AB one (same handler; D04 §6.4 sends `{ guild, old, new }`).
- **0x04A3 GUILD_M_GRADE** writes `nType = 0xA3` as a constant instead of `opcode & 0x3FF` (same value).
- **0x0554 ITEM_PUT_ON_BELONGED** writes `nType = 521` (`0x209`), the 2017 `NC_LOG_GAME_ITEM_PUT_ON_BELONGED_EXT` *(pdb2017)*,
  continuing the 510–520 item numbers of §2.3. Two senders: the Character server's item-belong path (D03 §3.1) and the zone's
  `ShinePlayer_sp_HorseItemSave` (`zone FUN_0045e810`, called e.g. after mount feeding, Z02 §9.1): when the mount item in the
  ride slot has a belong type listed in `g_BelongType`, the zone marks the item bound (`item +0x12 = 1`) and logs
  `{ charNo, itemkey, iteminvenfrom = iteminvento = ride slot | 0x2400 }` (inventory type 9) before saving the item attributes.
- **0x05EA REGENLOCATESAVE_CMD**: the zone (`ShinePlayer_so_ply_ToNormalLoc`, Z01 §7.4) logs a forced relocation:
  `SaveMap/SaveLocate` → `sMap/nMapX/nMapY`, `KQHandle → nInt2`, `InvalidLocate.x → nMapZ`, `InvalidLocate.y → nInt1`,
  `Flag → nInt3`. The map name is copied as three dwords with a zero 13th byte (struct zeroed first).
- **0x0612 ITEM_CW_BREAKATZERO**: zone `ShinePlayer_smo_ply_CostumWeaponChargeDecrease` (`FUN_00520840`) and its shield twin
  `FUN_00520aa0` (charges are Z06's): when the costume item's charge counter reaches 0 the zone deletes the item from equip
  slot 13 (or 11), then logs `{ charNo, itemkey, mappos = current map + x/y }`. nType 530 = cmd.
- **Wedding hall** (zone, Z08 owns the wedding flow): 0x065D from the reservation handler (Z02 §10), 0x065E from
  `WeddingHall_wh_Start` (`zone FUN_005a25a0`, our name from its log text "WeddingHall::wh_Start"; logged after the film
  starts, with the two partner numbers), 0x065F from `wh_Cancel`, which the compiler inlined into
  `ZoneListenSession_zls_NC_ACT_WEDDING_COUPLE_ENTRANCE_RNG` (`zone FUN_005a2b60`): sent when the couple-entrance answer
  has its flag byte (+0x11) = 0, i.e. the couple did not enter *(inferred)*. All wedding handlers store the pair as `nCharNo/nTargetCharNo`; DIVORCE_REQ adds
  `DivorceType → nInt1`.
- **Guild academy** 0x0752–0x0759: the guild number goes to `nInt1`, the acting character to `nCharNo`, the other character
  to `nInt2` (Type5, no map); GRADUATE adds level/class (`nInt2/nInt3`), MASTER_TELEPORT the target map position. Only
  0x0755 SET_MASTER has a 2016 sender (Character, D04 §9.2).

### 3.3 Commands no 2016 server sends; no-op registrations

**Registered to `fc_ReturnTrue` (`FUN_004063d0`): nothing is stored.** 0x046E–0x0473 PARTY_CREATE/JOIN/LEAVE/CHG_MAS/DELETE/
BANISH, 0x048E GUILD_TYPE, 0x048F GUILD_GRADE, 0x0490–0x0492 GUILD_WAR_DECLARE/ACCEPT/RESULT, 0x04A0–0x04A2 GUILD_M_JOIN/LEAVE/
BANISH, 0x04C8 MINIHOUSE, 0x04FA PET, 0x050E EMBLEM, 0x052C/0x0536/0x0540/0x054A ARENA_PVP/FBZ/CNG/GUILD, 0x0590 SEAWAR,
0x05F4 MINIGAME (23 registrations). The 2017 PDB has a struct for each of them *(pdb2017)*; no 2016 server sends any (no
send site in `layouts.json`, no opcode store in the four other binaries).

**Logging handlers without a 2016 sender** (same search as §2.4): 0x0455 ITEM_MOB_DROP, 0x0458 ITEM_SOULSTONEBUY,
0x0464/0x0465 ENCHANNT/DISENCHANT, 0x0478/0x0479 FRIEND_ADD/DELETE, 0x0482/0x0483 MAS_PUP_ADD/DELETE, 0x051B
QUEST_REWARD_ABSTATE, 0x051D QUEST_REWARD_PET, 0x051E QUEST_REWARD_MINIHOUSE, 0x0752–0x0754 and 0x0756–0x0759 (guild academy,
all but SET_MASTER).

## 8. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D05-B1 | every CParserGameLog handler (§1.3) | no packet-length check; fixed offsets are read whatever the length | a short or truncated log packet writes stale receive-buffer bytes into `tGameLog` | check the length per command |
| D05-B2 | 0x0452 ITEM_UPGRADE `FUN_00404bf0` | reads a 0x2D-byte layout with an extra u16 at 0x20; the 2016 zone sends the 0x2B-byte PDB layout | upgrade rows have old/new level packed into `nMapZ`, item ids shifted by one field, `nBigint1` high dword from 2 bytes past the packet | read the zone's layout (old level, new level, left/right/middle id, element) |
| D05-B3 | 0x0415 MOVE `FUN_004036a0` | `sMap` = constant `"NEED"`; the packet's map name is dropped | move rows have no map | copy `startpos.MapName` |
| D05-B4 | 0x044F ITEM_CREATE `FUN_004049c0` | `sMap` = constant `"RouN"`, coordinates 0 | every created item looks created in RouN | leave the map empty (the packet has none) |
| D05-B5 | `SQL_p_GameLog_Add_TypeL` `FUN_0041b4c0` | the failure line starts `"TA,"` and omits `nBigint1` | lost TypeL rows look like TypeA rows in `GameLog_<date>.txt`, without their 64-bit value | `"TL, …, %I64d"` |
| D05-B6 | 0x0462 MONEY_CHANGE `FUN_00405660` | zeroes the struct, copies only the three money values; `nType` and `nCharNo` stay 0 (`chrregnum` @0 is never read) | every money-change row (sent on each money change by the Character server) has nType 0 and no character | `nType = 98`, `nCharNo = chrregnum` like every other handler |

Next free ID: D05-B7.

## 9. Not reconstructed / uncertain

- `usp_Login_setChannel` has no source in any backup; its meaning (record the account's channel / client build) is inferred
  from its name and arguments. Its output parameter is ignored. D06 owns missing procedures.
- The `tGameLog` column types, defaults and any date column: only the procedure parameter lists are known (D06 can restore the
  backup for the schema).
- Which Type6 version (with or without the `tLevelUpInfo` ranking) the 2016 database had (§1.2).
- The meaning of the two extra u16 of the 2016 0x0454 ITEM_TITLE (`nTargetID`, `nInt2`); D04 §4.1 shows the Character server
  fills them from 4 bytes past its request (D04-B9), so they are stale data in practice.
- Senders of the §2.4 and §3.3 commands: none found; a capture of a 2016 session with GameLog traffic would settle it (P02).
- 0x04B0 G_REWARD_MONEY_DIVISION has no 2017 PDB struct; its field names (guild, old, new) are ours, taken from the shared
  handler and the sender (D04 §6.4).
- 0x065F HALL_CANCEL: that a zero flag in the couple-entrance answer means "not entered" is inferred from the `wh_Cancel` log
  text; Z08 owns the wedding flow.

## 10. Coverage boundary (parts 1–2; the sweep part completes it)

| Found | Covered by | Argument |
|---|---|---|
| Sender functions of every log packet (zone, WM, Character) | Z01/Z03/Z05/Z08, W01, D02/D03/D04 (cited per row in §2.3) | they build the packet as part of their own feature; D05 only records what the GameLog server stores |
| `usp_Login_setChannel` body, `tGameLog` schema | D06 (scope: "missing procedures, schema") | not in any backup |
| Zone senders `FUN_0045e810` (horse item belong), `FUN_00520840`/`FUN_00520aa0` (costume charges), `FUN_005a25a0`/`FUN_005a2b60` (wedding hall) | Z02 §9.1 / Z06 (costume charges) / Z08 (wedding) | only the log packet they build is D05's (§3.2); the game logic around it belongs to the zone items |
| The 23 no-op registrations (§3.3) | D05 (done) | `fc_ReturnTrue`: nothing to reconstruct beyond "ignored" |
| DataServer framework beyond the worker (listener, IOCP, service, main loop, scriptor parser) | D05 sweep part (part 4) | reached from no part-1 handler; same code as D01 §1 |
