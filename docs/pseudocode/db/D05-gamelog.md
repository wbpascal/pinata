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

Parts: §1–§2 = part 1 (framework, procedures, dept-1 commands 1–84), §3 = part 2 (dept-1 commands 85–857), §4–§6 = part 3
(rest of dept 1, MISC/OPTOOL server link, NC_SYSLOG dept 50), §7 = part 4 (process framework: start, service, sockets, framing,
heartbeat, diagnostics), §8–§10 bugs, open points, coverage boundary.

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
├── also     : ../9Data/Shine/ItemInfo.shn only (MapInfo.shn is read only by server type 2; no handler uses either, §7.1)
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
    if !Parser_CheckAlive(parser, pkt): return 0        @ FUN_00408a60
        # session +0xdc == 0 (link not authenticated): log "…dep=%d, cmd=%d" and drop the packet (D01 §1.1)
        # CheckAlive returns 0 (xor eax,eax @ 0x408abe), the handler passes it on: CParser_Dispatch (§7.2) sets work = 3 and
        # drops the remaining frames of the job; SessionWorker_Run logs nothing because the session state is 0
    st = {}                                             # stack struct of the procedure (§1.2); a few handlers memset it first
    st.nType = opcode & 0x3FF                           # the command number; item handlers use a constant instead (§2.3)
    st.<column> = p.<field> …                           # straight copies, u8/u16 zero-extended; no other logic
    st.sMap = _mbsnbcpy(p.MapName, 12)                  # MAPPOS map name → 16-byte buffer
    SQL_<proc>(parser.worker.db(+0x124c), &st)          # §1.2; result ignored
    return 1                                            # every log and SYSLOG handler (mov eax,1 e.g. @ 0x403540)
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
| `0x0454` | NC_LOG_GAME_ITEM_TITLE | `FUN_00404ce0` | p_GameLog_Add_TypeG | 84 | nCharNo ← chrregnum u32 @0x0; nItemKey ← WeaponItemKey u64 @0x4; nBigint1 ← LicenseItemKey u64 @0xc; nInt1 ← LicenseMobID u16 @0x14; nTargetID ← (2016 only) u16 @0x16; nInt2 ← (2016 only) u16 @0x18; sMap = ""; nMapX = 0; nMapY = 0; nMapZ = 0 | character FUN_00412790 (D04 §4.1; 0x1A bytes, D04-B9) | struct zeroed first |

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
every zone function that references the GameLog session pool `0x14d43958`, including the one that builds its opcode at run
time, `AxialListMobKillLog_ali_Work` FUN_00429590 (§4.2, 0x078E/0x078F only)). Their handlers are live but unreachable from
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
  `ShinePlayer_sp_HorseItemSave` (`zone FUN_0045e810`, called e.g. after mount feeding, Z02 §9.1; owned by Z13, whose plan lists `sp_HorseItemSave`): when the mount item in the
  ride slot has a belong type listed in `g_BelongType`, the zone marks the item bound (`item +0x12 = 1`) and logs
  `{ charNo, itemkey, iteminvenfrom = iteminvento = ride slot | 0x2400 }` (inventory type 9) before saving the item attributes.
- **0x05EA REGENLOCATESAVE_CMD**: the zone (`ShinePlayer_so_ply_ToNormalLoc`, Z01 §7.4) logs a forced relocation:
  `SaveMap/SaveLocate` → `sMap/nMapX/nMapY`, `KQHandle → nInt2`, `InvalidLocate.x → nMapZ`, `InvalidLocate.y → nInt1`,
  `Flag → nInt3`. The map name is copied as three dwords with a zero 13th byte (struct zeroed first).
- **0x0612 ITEM_CW_BREAKATZERO**: zone `ShinePlayer_smo_ply_CostumWeaponChargeDecrease` (`FUN_00520840`) and its shield twin
  `FUN_00520aa0` (charges are Z17's: Z17 plan "Costume weapon/shield charges"; Z06 handed them over): when the costume item's charge counter reaches 0 the zone deletes the item from equip
  slot 13 (or 11), then logs `{ charNo, itemkey, mappos = current map + x/y }`. nType 530 = cmd.
- **Wedding hall** (zone; the hall and its timetable are Z07's open wedding question, Z07 plan line 13; the 0x2055 handler is in
  Z01's scope table): 0x065D from the reservation handler (Z02 §10), 0x065E from
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

## 4. NC_LOG handlers, commands 858–1021 (CParserGameLog, part 3)

Same skeleton as §1.3 (CheckAlive, copy, one procedure; no length check, D05-B1). 33 registrations, 26 handler functions.
Columns, `std` (MAPPOS → `sMap`, `nMapX`, `nMapY`, `nMapZ = 0`) and the sender column as in §2.3. Every
handler here except 0x075A, DATA_TYPE_5 `FUN_00402420` and DATA_TYPE_D `FUN_004029f0` zeroes its struct first, so columns not
named stay 0 / `""` (the last two write every field, so nothing stale reaches the row).

### 4.1 Guild academy rewards, MK2, mover, item money, random options

| Opcode | Name | Handler | Procedure | nType | Columns ← fields | Sender (2016) | Note |
|---|---|---|---|---|---|---|---|
| `0x075A` | NC_LOG_GUILD_ACADEMY_SET_REWARD_MONEY | `FUN_00406800` | p_GameLog_Add_TypeD | 858 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nCharNo u32 @0x4; nInt2 ← nLevel u8 @0x8; nItemKey ← nMoney u64 @0x9 | none found | struct not zeroed, but every TypeD column is written |
| `0x075B` | NC_LOG_GUILD_ACADEMY_SET_REWARD_ITEM | `FUN_004068b0` | p_GameLog_Add_TypeA | 859 | nInt1 ← nGuildNo u32 @0x0; nCharNo ← nCharNo u32 @0x4; nInt2 ← nLevel u8 @0x8; nInt3 ← nItemID u16 @0x9; nTargetID ← nItemLot u16 @0xb | none found | the lot goes to `nTargetID`, where other rows keep the item id (§9) |
| `0x075C` | NC_LOG_GUILD_ACADEMY_CLEAR_REWARD_MONEY | `FUN_00406950` | p_GameLog_Add_TypeA | **0** | nothing: zeroed struct, no field read | none found | (original bug) D05-B8: an all-zero row |
| `0x078E` | NC_LOG_GAME_MK2_START | `FUN_00406aa0` | p_GameLog_Add_Type7 | 910 | nCharNo ← chrregnum u32 @0x0; nInt1 ← nLevel u8 @0x4; nInt2 ← nClass u8 @0x5; nTargetCharNo ← mobid u16 @0x6; sMap/nMapX/nMapY ← mappos @0x8 | zone `AxialListMobKillLog_ali_Work` FUN_00429590 from FUN_00556d70 (mob enters combat, vt 0x588; §4.2) | one handler for 910–912 |
| `0x078F` | NC_LOG_GAME_MK2_SUCCESS | `FUN_00406aa0` | p_GameLog_Add_Type7 | 911 | as 0x078E | zone `AxialListMobKillLog_ali_Work` FUN_00429590 from `ShineMob_so_KilledBy` FUN_00432760 (§4.2) | one row per player in the map |
| `0x0790` | NC_LOG_GAME_MK2_FAIL | `FUN_00406aa0` | p_GameLog_Add_Type7 | 912 | as 0x078E | none found (`FUN_00428340` has only the two callers above) |  |
| `0x0791` | NC_LOG_GAME_MK2_DEAD | `FUN_00406b50` | p_GameLog_Add_TypeH | 913 | nTargetCharNo ← mobid u16 @0x0; sMap/nMapX/nMapY ← mappos @0x2; nCharNo ← nCharNo u32 @0x16 (killer) | zone `ShineMob_so_KilledBy` FUN_00432760 (Z03 §8.1) | killer 0 when not a player |
| `0x0798` | NC_LOG_GAME_MK_DROP_ITEM | `FUN_00406c00` | p_GameLog_Add_TypeB | 920 | nTargetID ← nItemID u16 @0x0; nInt1 ← nLot u16 @0x2; nItemKey ← nItemKey u64 @0x4; nTargetCharNo ← mobid u16 @0xc; sMap/nMapX/nMapY ← mappos @0xe; nCharNo = 0 | zone `ShineDropItem_so_ItemDrop` FUN_0052a7a0 (Z05 §3.1) | §4.2 |
| `0x079A` | NC_LOG_MOVER_UPGRADE | `FUN_004076d0` | p_GameLog_Add | 922 | nCharNo ← nCharNo u32 @0x0; nMapX ← nMain_FailCount u16 @0x4; nMapY ← nConsum_FailCount u16 @0x6; nTargetCharNo ← nMain_ID u16 @0x8; nTargetID ← nMain_Grade u8 @0xa; nItemKey ← nMain_Key u64 @0xb; nInt2 ← nConsum_ID u16 @0x13; nInt3 ← nConsum_Grade u8 @0x15; nBigint1 ← nConsum_Key u64 @0x16 | character `fc_NC_ITEMDB_MOVER_UPGRADE_REQ` FUN_00429e70 (D03 §6.3) | sMap `""`, nInt1 0; fail counters in the coordinate columns |
| `0x079B` | NC_LOG_MOVER_RAREMOVER | `FUN_004077a0` | p_GameLog_Add | 923 | nCharNo ← nCharNo u32 @0x0; nTargetCharNo ← nRare_ID u16 @0x8; nTargetID ← nRare_Grade u8 @0xa; nItemKey ← nRare_Key u64 @0xb; nInt1 ← nConsum_Num u8 @0x13; nInt2 ← nConsum_ID u16 @0x14; nInt3 ← nConsum_Grade u8 @0x16; nBigint1 ← nConsum_Key u64 @0x17 | character `fc_NC_ITEMDB_MOVER_RAREMOVER_REQ` FUN_0042a230 (D03 §6.3) | `nRare_FailCount` @0x4 and `nConsum_FailCount` @0x6 are not stored |
| `0x079C` | NC_LOG_ITEMMONEY_BUY | `FUN_00407860` | p_GameLog_Add_TypeA | 924 | nCharNo ← nCharNo u32 @0x0; nTargetCharNo ← nNPCNo u16 @0x4; nTargetID ← nItemID u16 @0x6; nItemKey ← nItemkey u64 @0x8; nInt1 ← nItemLot u32 @0x10; nInt2 ← nMoneyID u16 @0x14; nInt3 ← nMoneyLot u32 @0x16 | character FUN_0042a6d0, FUN_0042aeb0 (D03 §2.6) |  |
| `0x079D` | NC_LOG_RANDOMOPTION_CHANGE | `FUN_00407910` | p_GameLog_Add_TypeF | **packet** | nType ← nType u32 @0x0; nCharNo ← nCharNo u32 @0x4; nTargetID ← nTargetID u32 @0x8; nItemKey ← nItemKey u64 @0xc; nInt2 ← nInt2 u32 @0x14; nInt3 ← nInt3 u32 @0x18; nBigint1 ← nBigint1 u64 @0x1c | none found | sMap `""`, coordinates and nInt1 0 |
| `0x079E` | NC_LOG_RANDOMOPTION_CHANGE_BEFORE | `FUN_004079c0` | p_GameLog_Add | **packet** | the whole `p_GameLog_Add` row, 0x44 bytes, as 0x0401 (§2.1) | character `fc_NC_ITEMDB_RANDOMOPTION_CHANGE_REQ` FUN_004359c0 (D03 §6.4) | §4.2 |
| `0x079F` | NC_LOG_RANDOMOPTION_CHANGE_AFTER | `FUN_004079c0` | p_GameLog_Add | **packet** | as 0x079E | as 0x079E | no 2017 PDB struct; the handler is 0x079E's |

**Not stored** (registered to `fc_CheckAliveOnly` `FUN_004069c0`, ours: `return CheckAlive(parser, pkt)`, nothing else):
0x075D CLEAR_REWARD_ITEM, 0x075E REWARD_MONEY, 0x075F REWARD_ITEM, 0x0760 REWARD_ITEM_PAY, 0x0761 LEVEL_UP (guild academy),
and MISC 0x0823 (§5). The 2017 PDB has structs for all five *(pdb2017)*; no 2016 server sends them.

### 4.2 Notes on the part-3 rows

- **0x0791 MK2_DEAD** (zone, Z03 §8.1): sent from `ShineMob_so_KilledBy` when the mob's data has a kill-log record
  (`MobData +0x20`, first u32 = the mob id; Z03 calls it the `MobKillLog` row) after the drop and the quest checks:
  `{ u16 mobId, MAPPOS (map name copied as three dwords, mob position), u32 killerCharNo }` (0x1A); the killer is the
  `nCharNo` of the killer when it is a player (`vt 0x4d0` = 2), else 0. It is followed by one 0x078F MK2_SUCCESS GameLog
  packet per player in the map (below); Z03 §8.1 reads that call as a "map-wide notice 0x38f", which it is not.
- **0x078E MK2_START / 0x078F MK2_SUCCESS** (zone): built by a map visitor whose opcode is set at run time, so a search for
  literal opcode stores misses it.
  ```pseudo
  AxialListMobKillLog(this, dept, cmd, mobId): this+4 = dept, +8 = cmd, +0xc = mobId     @ zone FUN_00428340 (vftable AxialListMobKillLog)
  AxialListMobKillLog::ali_Work(this, obj):        # called by ShineObject_so_AllInMap1 for every object of the map instance  @ zone FUN_00429590
      if obj.vt 0x4d0 != 2: return 1                                   # players only
      g_buf.opcode = dept << 10 | cmd
      { chrregnum = obj.vt 0x344 (charNo), nLevel = u8 obj.vt 0x4d8, nClass = u8 obj.vt 0x4dc, mobid = this.mobId,
        mappos = { MapName ← *(obj+0x7a) (12 bytes), x/y ← *(obj+0x66) } }          # the player's map and position
      SetPacketLen(0x1e) (0x1C payload = PDB size); too long → "AxialListMobKillLog::ali_Work : Packet Too Long"
      send to SessionPool_Pick(GameLog pool 0x14d43958); return 1
  # FUN_00428480 resets the vftable to AxialListIterator (destructor)
  ```
  - **MK2_START (910)**: zone `FUN_00556d70`, vtable slot 0x588 of ShineMob, ShineNPC, ShinePet, ShineBandit, ShineServant (no
    direct caller). It runs on both attacker and target of every hit (`ShineMobileObject_so_smash` / `so_skillsmash` /
    `smo_SwingDamage`, `ShinePlayer_so_smo_CrossCounterDamage`) and sets the last-fight time `+0xfb8 = g_Now`. The first time
    (flag `+0x24b0` = 0) and only when the mob data (`+0x1f90`) has a kill-log row (`MobData +0x20`, first u32 = mob id, the
    same test as 0x0791), it sends AxialListMobKillLog(1, 0x38e, mobId) to every player in the map. The flag is then set to 1,
    so each mob logs MK2_START once.
  - **MK2_SUCCESS (911)**: `ShineMob_so_KilledBy` FUN_00432760, right after the 0x0791 send: AxialListMobKillLog(1, 0x38f,
    mobId) to every player in the map.
  - MK2_FAIL (912) has no sender: `FUN_00428340` has only these two callers.
- **0x0798 MK_DROP_ITEM** (zone): `ShineDropItem_so_ItemDrop` sends it when the dropped item's `ItemInfo` entry has a
  record at `+0x18` whose first u32 is the item id (*inferred*: the `ItemDropLog.shn` row, Z01 §2.3):
  `{ u16 itemId, u16 lot (ItemAttr class vt 0x1c), u64 itemKey, u16 dropper vt 0x344 (PDB: mobid), MAPPOS (drop position) }`
  (0x22). `nCharNo` is written 0 by the handler: the packet has no character.
- **0x079E / 0x079F** (Character, D03 §6.4): after a random-option change the Character server sends the old options as two
  0x079E rows and the new ones as two 0x079F rows (option kinds 0–8 with `sMap = "1"`, kinds 9–14 with `sMap = "2"`), in the
  `p_GameLog_Add` layout with `nType = 926 / 927` (the commands). The GameLog handler is the generic one (the same function as
  0x07E8 DATA_TYPE_0): every column from the packet, `sMap` = 12 bytes + 4 zero bytes.
- **0x079A MOVER_UPGRADE** puts the two fail counters into `nMapX/nMapY` (the packet has no position) and leaves `nInt1` 0;
  0x079B RAREMOVER drops both counters and stores `nConsum_Num` in `nInt1`. Payload sizes match the Character senders
  (0x1E, 0x1F, 0x1A for 0x079C).

### 4.3 NC_LOG_GAME_DATA_TYPE_0…L: one command per procedure

Commands 1000–1021 are a raw interface to the procedures: `PROTO_NC_LOG_GAME_DATA_TYPE_<x>` *(pdb2017)* is exactly the
parameter list of `p_GameLog_Add_Type<x>` (§1.2) in procedure order, without the output `nLogNo`, and the handler copies every
field 1:1 into the column of the same name. **`nType` is taken from the packet** (offset 0), so the sender chooses the
`tGameLog.nType` value; names are `u32`, `sMap` is a 12-byte `Name3`, `nItemKey`/`nBigint1` are u64. Each handler zeroes its
struct and writes `sMap[12..15] = 0`, so the map name is always terminated.

```pseudo
fc_NC_LOG_GAME_DATA_TYPE_<x>(parser, pkt):       @ FUN_00402140 (1) … FUN_00402fe0 (L), FUN_004079c0 (0)
    if !Parser_CheckAlive(parser, pkt): return
    st = {}                                      # memset; Type5/TypeD handlers write every field instead
    st.<column> = p.<column> for every field     # sMap: 3 dwords, 13th byte 0
    SQL_p_GameLog_Add_Type<x>(db, &st)           # Type0 = p_GameLog_Add
```

| Opcode | Cmd | Handler | Procedure | Payload (= PDB size) | 2016 senders and the nType values they write |
|---|---|---|---|---|---|
| `0x07E8` | TYPE_0 | `FUN_004079c0` | p_GameLog_Add | 0x44 | Character `fc_NC_ITEMDB_TERMEXTEND_REQ` FUN_0042d500: nType 2030 (0x7EE); `fc_NC_ITEMDB_CLASS_CHANGE_REQ` FUN_0042e6b0: nType 930 (0x3A2 = `NC_LOG_CLASS_CHANGE_REQ` *(pdb2017)*) (D03 §6.5) |
| `0x07E9` | TYPE_1 | `FUN_00402140` | …_Type1 | 0x20 | none found |
| `0x07EA` | TYPE_2 | `FUN_004021f0` | …_Type2 | 0x28 | none found |
| `0x07EB` | TYPE_3 | `FUN_004022a0` | …_Type3 | 0x2C | none found |
| `0x07EC` | TYPE_4 | `FUN_00402360` | …_Type4 | 0x2C | zone `Send_NC_LOG_GAME_DATA_TYPE_4` FUN_006144a0, called only by the script function `cSendGameLogDataType_4` (FUN_005f1a10): nType chosen by the script (§4.4) |
| `0x07ED` | TYPE_5 | `FUN_00402420` | …_Type5 | 0x10 | zone `Send_NC_LOG_GAME_DATA_TYPE_5` FUN_006145c0: script `cSendGameLogDataType_5` (FUN_005f1d40), and `cSaveTutorialInfo` (FUN_005e70b0): nType 2025 (0x7E9) (§4.4) |
| `0x07EE` | TYPE_6 | `FUN_004024b0` | …_Type6 | 0x2C | none found |
| `0x07EF` | TYPE_7 | `FUN_00402570` | …_Type7 | 0x2C | none found |
| `0x07F0` | TYPE_8 | `FUN_00402630` | …_Type8 | 0x24 | none found |
| `0x07F1` | TYPE_9 | `FUN_004026e0` | …_Type9 | 0x30 | none found |
| `0x07F2` | TYPE_A | `FUN_004027a0` | …_TypeA | 0x24 | Character `fc_NC_ITEMDB_UES_FRIEND_POINT_REQ` FUN_0042ef20: nType 929 (0x3A1 = `NC_LOG_UES_FRIEND_POINT` *(pdb2017)*) (D03 §6.5) |
| `0x07F3` | TYPE_B | `FUN_00402850` | …_TypeB | 0x3C | none found |
| `0x07F4` | TYPE_C | `FUN_00402920` | …_TypeC | 0x38 | none found |
| `0x07F5` | TYPE_D | `FUN_004029f0` | …_TypeD | 0x18 | none found |
| `0x07F6` | TYPE_E | `FUN_00402a90` | …_TypeE | 0x30 | none found |
| `0x07F7` | TYPE_F | `FUN_00402b50` | …_TypeF | 0x40 | zone `Send_NC_LOG_GAME_DATA_TYPE_F` FUN_006146a0 from the enchant ACKs (Z05 §8.2): ADD_GEM FUN_00522fc0 nType 2020 (0x7E4), REMOVE_GEM FUN_005233d0 2021 (0x7E5, one row per removed socket), ADD_NEW_SOCKET FUN_00523820 2022 (0x7E6) |
| `0x07F8` | TYPE_G | `FUN_00402c30` | …_TypeG | 0x3C | zone `Send_NC_LOG_GAME_DATA_TYPE_G` FUN_006147f0 from `EQUIP_BELONGED_CANCEL_USE_ACK` FUN_0051bfa0 (Z05 §5.3): nType 2000; Character FUN_0042c120: nType 928 (0x3A0 = `NC_LOG_RANDOMOPTION_USE_CONSUME_ITEM_TO_TARGET_ITEM`, sMap "UseBijouH"), FUN_0042c750: nType 933 (0x3A5 = `NC_LOG_RANDOMOPTION_RECOVER_COUNT_LIMIT`, sMap "RORecover") (D03 §6.4) |
| `0x07F9` | TYPE_H | `FUN_00402d00` | …_TypeH | 0x24 | none found |
| `0x07FA` | TYPE_I | `FUN_00402db0` | …_TypeI | 0x28 | none found |
| `0x07FB` | TYPE_J | `FUN_00402e60` | …_TypeJ | 0x34 | none found |
| `0x07FC` | TYPE_K | `FUN_00402f20` | …_TypeK | 0x30 | none found (the zone `0x7fc` hits are vtable offsets) |
| `0x07FD` | TYPE_L | `FUN_00402fe0` | …_TypeL | 0x2C | Character `fc_NC_ITEMDB_REPURCHASE_ALL_REQ` FUN_0042e060, `…_LOT_REQ` FUN_0042e380: nType 2040 (0x7F8) (D03 §2.2) |

Every sender's payload size equals the PDB size. The `nType` values 2000–2040 are not `PROTOCOL_COMMAND_LOG` members in the 2017
PDB; 926–933 are *(pdb2017)*. Together with §2.3/§3.1 the `tGameLog.nType` value space is: the NC_LOG command number,
510–521 (item `…_INVEN_EXT`), these DATA_TYPE values, and the script values of §4.4 (2026, 2027, 2045–2050).

### 4.4 Zone script and tutorial senders

```pseudo
cSendGameLogDataType_4(L):         # script function; args read as numbers unless noted        @ FUN_005f1a10
    Send_NC_LOG_GAME_DATA_TYPE_4(nType = arg1, nCharNo = arg2, sMap = strncpy(arg3 string, 12) or "",
                                 nMapX = arg4, nMapY = arg5, nMapZ = arg6, nInt1 = arg7, nInt2 = arg8, nInt3 = arg9)
    # an argument of the wrong type becomes 0; floats are rounded                          @ FUN_006144a0
cSendGameLogDataType_5(L):  Send_NC_LOG_GAME_DATA_TYPE_5(arg1 nType, arg2 nCharNo, arg3 nInt1, arg4 nInt2)   @ FUN_005f1d40 → FUN_006145c0
cSaveTutorialInfo(L): handle = arg1, state = arg2, step = arg3                             @ FUN_005e70b0
    p = object(handle); store {state, step} in the player's tutorial record (vt 0xdfc)
    send 0x1118 and 0x111C (tutorial save) to two other server pools (owned by the zone/character items)
    if state == 1: Send_NC_LOG_GAME_DATA_TYPE_5(2025, p.charNo, nInt1 = 1, nInt2 = step)
Send_NC_LOG_GAME_DATA_TYPE_x: static packet buffer, opcode + fields, SetPacketLen, send to SessionPool_Pick(GameLog pool
    0x14d43958); too long → log "Send_NC_LOG_GAME_DATA_TYPE_x : Packet Too Long"
```

The script functions are registered by the zone's `c*` script-function table `FUN_005f5350` (strings at `005f70af`,
`005f70cd`, `005f6767`). The 2016 script files in `Files/Server/2016/9Data/Shine/LuaScript/` call them like this (names are
the scripts' own):

| Script | Function | nType | Other fields |
|---|---|---|---|
| `AIScript/E_XTreeBig.lua` (Christmas tree event; constants at lines 152–157) | `cSendGameLogDataType_5` | 2045 `NC_LOG_GAME_CHRISTMAS_DECO_TRY_BIG_TREE` (line 1219), 2046 `…_DECO_TRY_SMALL_TREE` (1639), 2047 `…_DECO_COMPLETE_BIG_TREE` (678), 2048 `…_DECO_COMPLETE_SMALL_TREE` (1655), 2049 `NC_LOG_GAME_CHRISTMAS_START_DEFENCE` (713), 2050 `…_SUCC_DEFENCE` (765) | nCharNo 0; nInt1 = `cGetMobID(NPCHandle)` for 2046/2048, else 0; nInt2 0 |
| `AIScript/E_Ski_CongressNPC.lua` (ski event; constants at lines 22–30) | `cSendGameLogDataType_4` | 2026 `GameResultLogType` (lines 1025, 1135, 1173, 1259), 2027 `SeasonbRewardLogType` (1046) | nCharNo = player; sMap ""; nMapX/nMapY 0; for 2026 nMapZ = result `GRT_SeasonEnd` 1 / `GRT_StanbyTimeout` 2 / `GRT_RunTimeout` 3 / `GRT_Goal` 4, nInt1–3 = the result values passed after it (ranking/record); for 2027 nMapZ 0, nInt1 = ranking, nInt2 = title type, nInt3 = title element |
| `Tutorial/Tutorial.lua` | `cSaveTutorialInfo` | 2025 only from line 151 (state 1); lines 75 and 165 pass state 0 and log nothing | nInt1 1, nInt2 = step |

The script files are the private-server set shipped with the 2016 binaries; scripts not in this folder may use other values
*(inferred)*.

## 5. Server-link handlers (CPFs, registered @ FUN_00409640 CPFs_ctor)

The D01 §2 handlers with the same code; `my_type` = `g_MyServerType` (`DAT_0044d688`) = 3 from the config (§1.1).
Unregistered commands of every parser go to `fc_dummyfunction` (`FUN_00408af0`: log "fc_dummyfunction, Protocol = 0x%04x,
dep=%d, cmd=%d, length=%d From (…)", ignore).

```pseudo
0x0801 NC_MISC_S2SCONNECTION_RDY, 0x0805 NC_MISC_HEARTBEAT_ACK: fc_ReturnTrue (no-op)          @ FUN_004063d0
0x0804 NC_MISC_HEARTBEAT_REQ (no CheckAlive):                                                  @ LAB_00409150
    Session_SendRaw(session, {02 05 08}, 3)            # static frame DAT_0044a0b0: length 2, opcode 0x0805 HEARTBEAT_ACK
                                                       @ FUN_00409970 (under the send lock)
0x0823 NC_MISC_START_THE_BOOM_CMD: return CheckAlive()  (fc_CheckAliveOnly)                    @ FUN_004069c0

0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo_data, u8 server_to_id, u8 server_from_id, u8 world, u8 zone, u16 key }   @ FUN_00408bd0
    ok = 1
    if session.state(+0xdc) not in {0, 2} and session.type(+0xe0) != 3: ok = 0; log (already connected) "IP=%s:%d, SOCKET=%d"
    if server_to_id != g_MyServerType and ok: ok = 0; log (wrong type) + "NC_MISC_S2SCONNECTION_REQ <server_from id=%d w=%d z=%d,
        server_id_to=%d, key=%d, my_type=%d>"
    if ok and key != (u16)(server_to_id + server_from_id): log (wrong key) + "<server_id_from=…>"; Session_Close; return
    if !ok: Session_Close(session); return                                                    @ FUN_00412c70
        # Session_Close = CSocket_IOCP_Shutdown(SD_SEND) @ FUN_00413240 (WSAENOTCONN ignored, other errors logged
        #   "ERROR - CSocket_IOCP::Shutdown : …") + CSocket_IOCP_Close @ FUN_00413360 (closesocket, socket = −1, failure logged
        #   "ERROR - CSocket_IOCP::Close : …"; then frees the queued send buffers FUN_00413320 under the send lock)
    session.type/world/zone (+0xe0/+0xe4/+0xe8) = server_from_id / world / zone
    Send 0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo_data, u16 error = 0 }   # CSendPacket on the stack; CSendPacket_dtor FUN_004183c0 is empty
    send failed: log; Session_Close
    else: session.state = 1 (authenticated: CheckAlive passes from now on); fields set again; connectTime(+0xec) = GetLocalTime();
          log "Connected from …" with ServerTypeName(type) (FUN_0040b240: SERVER_ID_* string table, index > 20 or < 0 → 10)

0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo_data, u16 error }:  if error == 0: session.state = 1; log "Connected to …"   @ FUN_00409080
    # the GameLog server never connects out; registered by the shared base

0x2801 NC_OPTOOL_S2SCONNECT_LIST_REQ { u8 echo_data }   (CheckAlive)                                @ FUN_00409170
    under the session-list lock (0x44d6d4, FUN_00411350/FUN_00411370), for each session with state 1:
        SERVER_CONN_INFO { u8 connect_server_world, u8 connect_server_zone, u8 connect_server_id, u32 connect_time }
        connect_time = SHINE_DATETIME bits: year&0xF | month<<4 | day<<8 | hour<<13 | minute<<18 | second<<24
    Send 0x2802 { u8 echo_data, u8 my_server_id = 3, u16 num_of_connections, entries } (4 + 7n)
    # the entry order is world, zone, id (as SERVER_CONN_INFO (pdb2017)); D01 §2 lists the type first
0x2803 NC_OPTOOL_CLOSE_SERVER_REQ  (no CheckAlive)                                                   @ FUN_00409360
    Send 0x2804 NC_OPTOOL_CLOSE_SERVER_ACK { u16 error = 0x0600 }
    g_CloseServerRequested (DAT_00656a3c) = 1          # no code reads it: the server keeps running (original bug) D05-B7
0x2805 NC_OPTOOL_MAP_USER_LIST_REQ { u8 echo_data } (CheckAlive):  Send 0x2806 { echo_data, my_server_id = 3, u16 0 }   @ FUN_00409410
0x2807 NC_OPTOOL_CONNECT_BRIF_REQ { u8 echo_data } (CheckAlive):                                     @ FUN_004094e0
    Send 0x2808 (0xAA, zeroed) { echo_data, my_server_id = 3, u16 count[21][2][2] }:
        for each session with state 1: t = type (> 20 → 10), w = world (> 1 → 0), z = zone (> 1 → 0); count[t][w][z]++
```

## 6. NC_SYSLOG handlers: text log for the data warehouse (dept 50, CParserGameLog)

The fourteen dept-50 handlers do not touch the database. Each formats one line and hands it to a rotating text log.

### 6.1 The log file

Helper names in this section (`RotatingLog_*`, `LineQueue_Push`, `CreateDirectoryPath`, `Syslog_WriteLine`) are ours; the
binary has no strings for them.

```pseudo
at startup (main, FUN_00401f90; part 4):
    RotatingLog_Open(g_SyslogFile (main +0x2098c4 = DAT_00656a4c), dir = "C:/data/gamigo-dwh/current/", mode 4 (hourly),
                     name = sprintf("_fiesta_Gamelog_World%d.log", my world (main +0x504)))          @ FUN_0040f6b0
        CreateDirectoryPath(dir): CreateDirectoryA for every prefix ending in '/' or '\' (not after ':'), then the whole  @ FUN_0040ed70
            # result ignored: a missing directory does not stop the start
        line queue: chunked deque of strings (+0x33c), CreateThread(RotatingLog_WriterThread)
        thread creation fails → the server does not start (main returns)

Syslog_WriteLine(msg):                                                                            @ FUN_00406cc0
    local = GetLocalTime(); host = gethostname(255 bytes); utc = GetSystemTime()
    line = sprintf("%s %s %s %s %s - %s",
                   "<Mon> <d> <hh:mm:ss>" (English month abbreviation, day not padded, local time),
                   host, "<yyyy>-<mm>-<dd>T<hh>:<mm>:<ss>.<mmm>Z" (UTC), "GAMELOG", "GAMELOG", msg)     # 512-byte buffer
    RotatingLog_Write(g_SyslogFile, line)                                                          @ FUN_0040f1f0
        dropped unless the writer thread runs (+0x38c = 1) and no stop was requested (+0x38d)
        under the queue lock (+0x36c): append a std::string copy (FUN_0040f120) with LineQueue_Push FUN_0040f040; lineCount(+0x368)++

RotatingLog_WriterThread(log):                                                                    @ FUN_0040f250
    log.running = 1
    loop until a stop is requested and the queue is empty: Sleep(1); then for every queued line:
        now = GetLocalTime()
        no file open, or now ≥ rollover (RotatingLog_IsBeforeRollover FUN_0040edf0 compares yyyyMMddhhmmss numbers):
            close the old file; stamp = "%04d%02d%02d%02d" (mode 4; modes 1–6 = year … second, other = "")
            rollover = start of the next hour; path = dir + stamp + name; fopen(path, "a+")
            fopen fails → the thread ends (running = 0): later lines are dropped, nothing is logged
                # never retried, the server keeps running: (original bug) D05-B11
        pop the line (copied into a 512-byte buffer with "%s"), fprintf("%s\n"), fflush
    close the file; running = 0
```

So one file per hour, e.g. `C:/data/gamigo-dwh/current/2016031514_fiesta_Gamelog_World0.log` *(inferred example)*. The
directory name and the line format (an RFC 5424-like header plus an SD element `[fiesta@onson key="value" …]`) point to
gamigo's data-warehouse import *(inferred)*.

### 6.2 The fourteen messages

Every handler: `if !CheckAlive: return`; `msg = sprintf(format, fields)` into a 256-byte buffer; `Syslog_WriteLine(msg)`. All
numbers print with `%d` (u32 values above 2³¹ print negative) except `%I64d` amounts. The 2016 packets are the PDB structs
without the trailing `CharID`/`UserID` strings and levels *(pdb2017 has them)*; sizes below are the 2016 senders'.

| Opcode | Name | Handler | Payload read (2016 size) | Message (`fiesta@onson` attributes) | Sender (2016) |
|---|---|---|---|---|---|
| `0xC804` | NC_SYSLOG_CHAR_CREATED | `FUN_00406e60` | UserNo u32 @0, CharNo u32 @4, CharClass u8 @8 (9) | `CHAR_CREATED [… account-id char-id char-type]` | WM `CharDB_AvatarCreated_1405` FUN_004113c0 (W01) |
| `0xC805` | NC_SYSLOG_CHAR_DELETED | `FUN_00406ee0` | UserNo, CharNo, CharClass u8 @8 (9) | `CHAR_DELETED [… account-id char-id char-type]` | WM `CharDB_AvatarErased_140B` FUN_0040a010 (W01) |
| `0xC806` | NC_SYSLOG_CHAR_ENTER_GAME | `FUN_00406f60` | UserNo, CharNo (8) | `CHAR_ENTER_GAME [… account-id char-id]` | WM `CharDB_CharDataAck_1005` FUN_00410040 (W01) |
| `0xC807` | NC_SYSLOG_CHAR_LEAVE_GAME | `FUN_00406fe0` | UserNo, CharNo, PlayTime u32 @8 (12) | `CHAR_LEAVE_GAME [… account-id char-id in-game-minutes]` | WM `Client_CharacterLogout` FUN_00436d50 (W01) |
| `0xC808` | NC_SYSLOG_CHAR_LEVEL_UP | `FUN_00407060` | UserNo, CharNo, CharLev u8 @8 (9) | `CHAR_LEVEL_UP [… account-id char-id level]` | WM `Zone_LevelChanged_1074` FUN_0042e160 (W01) |
| `0xC809` | NC_SYSLOG_CHAR_ZONE_TRANSITION | `FUN_004070e0` | UserNo, CharNo, DestZoneNo u8 @8, SrcZoneNo u8 @9, CharLev u8 @0xa (11) | `CHAR_ZONE_TRANSITION [… account-id char-id dest-zone-id src-zone-id level]` | zone `ShinePlayer_so_LinkTo` FUN_0049ad30 (Z01) |
| `0xC80A` | NC_SYSLOG_CHAR_DEATH | `FUN_00407170` | UserNo, CharNo, ZoneNo u8 @8, AttackerType u8 @9, AttackerID u32 @0xa, DeathCoord x u32 @0xe, y u32 @0x12 (0x16) | AttackerType 0: `CHAR_DEATH [… account-id char-id opponent-id longitude latitude zone-id]`; 1: same with `from-id`; other: without an attacker | zone `ShinePlayer_so_KilledBy` FUN_00433be0 (Z03) |
| `0xC80B` | NC_SYSLOG_CHAR_VICTORY | `FUN_00407260` | UserNo, CharNo, ZoneNo u8 @8, TargetType u8 @9, TargetID u32 @0xa, KillCoord x/y @0xe/@0x12 (0x16) | TargetType 0: `CHAR_VICTORY [… account-id char-id zone-id opponent-id longitude latitude]`; other: `victim-id` instead of `opponent-id` | zone `ShineMob_so_KilledBy` FUN_00432760 (mob kill: TargetType 1, TargetID = mob id, the killer's zone number from `ServerInfo_GetMine`), `ShinePlayer_so_KilledBy` FUN_00433be0 (Z03) |
| `0xC80D` | NC_SYSLOG_CHAR_ITEM_BUY | `FUN_00407320` | UserNo, CharNo, ItemNo u16 @8, BuyMoney u64 @0xa, Vendor u16 @0x12 (0x14) | `CHAR_ITEM_BUY [… account-id char-id item-id amount vendor-id]` | Character FUN_00409300, FUN_004096d0 (D03 §2.1) |
| `0xC80E` | NC_SYSLOG_CHAR_ITEM_SELL | `FUN_004073b0` | as ITEM_BUY (SellMoney) (0x14) | `CHAR_ITEM_SELL [… account-id char-id item-id amount vendor-id]` | Character FUN_00409a20, FUN_00409ec0 (D03 §2.2) |
| `0xC80F` | NC_SYSLOG_CHAR_QUEST_STARTED | `FUN_00407440` | UserNo, CharNo, QuestID u16 @8, ZoneNo u8 @0xa, QuestStartNPC u16 @0xb (0xd) | `CHAR_QUEST_STARTED [… account-id char-id quest-id zone-id npc-id]` | zone `CQuestZone_Recv_NC_QUEST_DB_SET_INFO_ACK` FUN_005bf280 (Z08) |
| `0xC810` | NC_SYSLOG_CHAR_QUEST_FINISHED | `FUN_004074d0` | UserNo, CharNo, QuestID u16 @8, RewardMoney u64 @0xa, RewardItemNo u16 @0x12, ClearTime u64 @0x14 (low dword printed), QuestEndNPC u16 @0x1c (0x1e) | RewardItemNo = 0xFFFF: `CHAR_QUEST_FINISHED [… account-id char-id npc-id quest-id amount time-needed]`; else with `item-id` before `time-needed` | Character FUN_00431550 (D04 §1.2) |
| `0xC814` | NC_SYSLOG_CHAR_ITEMMONEY_BUY | `FUN_004075b0` | UserNo, CharNo, ItemNo u16 @8, ItemLot u32 @0xa, ItemMoneyNo u16 @0xe, ItemMoneyLot u32 @0x10, Vendor u16 @0x14 (0x16) | `CHAR_ITEMMONEY_BUY [… account-id char-id item-id item-amount money-id money-amount vendor-id]` | Character FUN_0042a6d0, FUN_0042aeb0 (D03 §2.6) |
| `0xC815` | NC_SYSLOG_CHAR_ITEM_REBUY | `FUN_00407640` | as ITEM_BUY (0x14) | `CHAR_ITEM_REBUY [… account-id char-id item-id amount vendor-id]` | Character FUN_0042e060, FUN_0042e380 (D03 §2.2: amount = nPrice, high dword 0) |

`…` stands for `fiesta@onson`; attribute values are quoted: `account-id="%d"`. Example *(inferred, built from the formats)*:
`Mar 15 14:02:07 GLHOST 2016-03-15T13:02:07.512Z GAMELOG GAMELOG - CHAR_LEVEL_UP [fiesta@onson account-id="1001" char-id="2002" level="31"]`.

Not registered in 2016 (go to `fc_dummyfunction`, §5): 50/1–3 `ACCOUNT_LOGIN_SUCCESS/FAILURE/LOGOUT`, 50/12 `CHAR_LOOT`,
50/17 `SERVER_CCU`, 50/23 `NC_GAMIGO_NEW_TUTORIAL_STORE_STEP` *(pdb2017 names)*.

## 7. Process framework (part 4 sweep)

The same "DataServer" code as the Account / AccountLog servers (D01 §1, which documents only the worker and the helpers). All
helper names in this section are ours unless a string is quoted; class names (`CSession`, `CSession_Manager`, `CPacket`,
`CIOBuffer`, `WinService`, `Database`, `AssertClass`, `ShineLog`, `IOBufferContainer`) come from RTTI or log strings. The
process object is the global `g_DataServer` = `DAT_0044d188` (ctor `DataServer_ctor` FUN_00401900).

| `g_DataServer` + | Meaning |
|---|---|
| 0x4f8 / 0x4fc | service name / display name (the two `MY_SERVER` strings: "PG_W00_GLDB", "_2015_GameLog") *(inferred: read by `DataServer_ReadDefineScriptor`)* |
| 0x500 / 0x504 / 0x508 | my server type (3) / world / zone (`MY_SERVER` integers) |
| 0x51c | IOCP object (handle + worker-thread table) |
| 0x54c | `CSession_Manager` (session pool; ctor FUN_0040a250); 0x558 = its listener (`mgr + 0xc`) |
| 0x9838 | session-worker pool (§1.1) |
| 0x209890 | "started as a service" flag, set to 1 once the syslog file object is open |
| 0x209894 / 0x2098a4 | local start / stop time (SYSTEMTIME, logged with the UTC time by FUN_004010f0 / FUN_00401230) |
| 0x2098b4 / 0x2098b8 / 0x2098bc | stop requested / main thread running / main thread handle |
| 0x2098c4 | NC_SYSLOG file object (§6.1) |

### 7.1 Start, Windows service, shutdown

```pseudo
DataServer_WinMain(…, cmdline):                                           @ FUN_004020b0 (called by the CRT entry)
    Exception_Install(): SetUnhandledExceptionFilter(Exception_Filter)    @ FUN_00412880 (§7.4)
    rc = DataServer_Main(g_DataServer, cmdline); log "< END OF MAIN = %d >"

DataServer_Main(cmdline):                                                 @ FUN_00401de0
    chdir(directory of the exe)
    log "-------…", "Launching the server....."
    DebugMessage_WriteExecUpdateInfo(DAT_00434898)  →  .\DebugMessage\ExecUpdateInfo.txt =
        "US - 2015년 11월 05일 - 11시 42분 26초"   (build stamp: US build of 2015-11-05 11:42:26)   @ FUN_0040fc10
    DataServer_LogStartTime()                                             @ FUN_004010f0
    if !DataServer_ReadDefineScriptor(): return −1                        @ FUN_00401370 (§1.1)
    if !DataServer_ReadGameData():       return −4                        @ FUN_00401510
    if !DataServer_ServiceCommand(cmdline): return −2                     @ FUN_004019e0
    WinService_Run(name = +0x4f8, start = FUN_00402120 → DataServer_ServiceStart,
                   stop = FUN_00402130 → DataServer_ServiceStop)          @ FUN_004120d0
        StartServiceCtrlDispatcherA({name, WinService_ServiceMain}); fails (not started by the SCM) → returns
    return 0
    # the server only runs as a Windows service; started from a console, the dispatcher fails and main ends with 0 (inferred
    # from the API: StartServiceCtrlDispatcher fails with 1063 outside the SCM)

DataServer_ReadGameData():                                                @ FUN_00401510
    ItemDataBox_LoadIfExists(DAT_006574a0, "../../9Data/Shine/ItemInfo.shn"), else "../9Data/Shine/ItemInfo.shn"
        (fopen test, then ItemDataBox_Load: SHN rows → id index + name hash)   @ FUN_00410d00 / FUN_00410a40
        both missing → log "*FAILED GLOBAL GAME DATA READ - ItemInfo.shn"; return 0
    if my type (+0x500) == 2: MapDataBox_Load(DAT_00656f80, "../../9Data/Shine/MapInfo.shn" / "../9Data/…")  @ FUN_004105c0
        # never for the GameLog server (type 3)
    return 1
    # no GameLog code reads DAT_006574a0 after the load: the item table only costs start-up time and memory

DataServer_ServiceCommand(cmdline):                                       @ FUN_004019e0
    args = up to 5 tokens of cmdline split at " \t,\""
    no args: if WinService_QueryStatus(name) succeeds (service installed)  @ FUN_00411db0
                 → log "Service start(no parameter)"; return 1      (continue: run as the service)
             else args[0] = "UPLOAD"                                  (not installed yet: install it)
    "UPLOAD": WinService_Install(name, display name, exe path)          @ FUN_00411b70
                 CreateServiceA(SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_IGNORE)
                 → "Service upload only ok." / "Service upload failed."
    "REMOVE": WinService_Remove(name) (OpenService + DeleteService)       @ FUN_00411c70
                 → "Service remove ok." / "Service remove failed."
    other  : "Service unknown command."
    every non-start case: log + MessageBoxA(text, caption = display name); return 0 (main returns −2)

WinService_ServiceMain():                                                 @ FUN_00411fa0
    WinService_ReportStart():                                             @ FUN_00411ee0
        event = CreateEvent(auto-reset); RegisterServiceCtrlHandlerA(name, WinService_CtrlHandler FUN_00411eb0)
        SetServiceStatus(START_PENDING, controls = STOP | SHUTDOWN, wait hint 1000)
        if !DataServer_ServiceStart(): return     # status stays START_PENDING (original bug) D05-B10
        SetServiceStatus(RUNNING)
    loop: wait for the event; control = code stored by the handler (+0x24); STOP (1) or SHUTDOWN (5) → leave; other codes ignored
    WinService_ReportStop(): SetServiceStatus(STOP_PENDING, wait hint 5000); DataServer_ServiceStop(); SetServiceStatus(STOPPED)  @ FUN_00411d20

DataServer_ServiceStart():                                                @ FUN_00401f90
    RotatingLog_Open(syslog file, "C:/data/gamigo-dwh/current/", hourly, "_fiesta_Gamelog_World%d.log")   (§6.1)
        fails → return 0
    +0x209890 = 1
    IOCP_StartThreads(5 × CPU count, wait until all run)                    @ FUN_0040ec80
        CreateIoCompletionPort; one IOCP_WorkerThread each (FUN_0040eb90); log "<NUMBER OF %d IOCP WORKTHREAD STARTED, %d CPU DETECTED>"
        fewer threads than asked → return 0
    SessionWorkerPool_Start(count −1 → min(10 × CPU + 1, 81), wait)        @ FUN_0040abe0
        per worker: CSessionWorker (0x1268 bytes, ctor FUN_0040a6d0), SessionWorker_Start FUN_0040a580 (thread SessionWorker_Run,
        wait while state 1; ok when state 2 = DB connected); any failure → stop all, return 0
        log "<NUMBER OF %d SESSION WORKER STARTED>"
    DataServer_StartAcceptor():                                           @ FUN_004015b0
        row = SERVER_INFO with (type, world, zone) = (+0x500, +0x504, +0x508)   ServerInfo_LookupServer @ FUN_004100e0
            (ServerInfo_FindServer FUN_0040ff60 / ServerInfo_GetServer FUN_0040feb0: scriptor record kind 3 = SERVER_INFO
             {name, type, world, zone, int, ip, port, backlog, max sessions})
            none → log "FATAL ERROR - Can't found ServerInfo on funcition 'DataServer::Start_Acceptor()', …"; return 0
            (2016 ServerInfo.txt: SERVER_INFO "PG_W00_GLDB", 3, 0, 0, 0, "0.0.0.0", 9511, 100, 100)
        SessionManager_Init(IOCP, max sessions)                           @ FUN_004119b0
            pre-creates max-sessions CSession objects (CSession_Manager_NewSession FUN_00409f40: 0x154 bytes, CSession_ctor FUN_00409c00)
            fails → "*FAILED SESSION MANAGER INIT*"; else "<SUCCESSED SESSION MANAGER INIT>"
        ip == "" → Listener_StartOnLocalAddress (first address of the host; "ERROR - FAILED TO GET LISTEN SOCKET IP ADDRESS")  @ FUN_004112f0
        else Listener_Start(ip, port, backlog)                            @ FUN_00411250
            Listener_Bind: socket, SO_REUSEADDR, non-blocking (FIONBIO), bind, listen     @ FUN_00411020
            Listener_StartThread (Listener_AcceptThread)                  @ FUN_004111a0
            log "<SUCCSSED LISTEN AT IP=%s, Port=%d, BacklogCount=%d >"
        failure → "*FAILED START LISTEN SOCKET*"; return 0
    DataServer_StartMainThread(): CreateThread(DataServer_MainThread), wait until it runs   @ FUN_00401d60
        fails → "*FAILED CREATE MAIN THREAD*"
    log "SERVER WORK START ----…"; return 1

DataServer_MainThread():                                                  @ FUN_004016d0
    log "<MAIN THREAD START>"; +0x2098b8 = 1
    every 1000 ms until +0x2098b4 (stop requested): CSession_Manager_HeartbeatTick()   (§7.2)
    Listener_Stop (shutdown + closesocket, wait for the accept thread)    @ FUN_00410fb0   "<SUCCESSED STOP LISTEN SOCKET>" / "*FAILED …*"
    SessionWorkerPool_Stop(−1): workers in state 2 → 3, wait until all are 0   @ FUN_0040a800   "<SESSION WORKER ALL STOPPED>"
    SessionManager_CloseAll: Session_Close on every used session           @ FUN_00411510   "<SESSION DISCONNECTED>"
    IOCP_Close (stop the IOCP threads, CloseHandle)                        @ FUN_0040ec60   "<IOCP CLOSED>"
    SessionManager_Destroy                                                @ FUN_00411a90   "<SESSION CLOSED>"
    DataServer_LogStopTime(); "<MAIN THREAD STOP>"; +0x2098b8 = 0
    +0x209890 != 0 → "<SERVER MANUAL STOPPED>", return    else "<SERVER SELF STOPPED>", _exit(0)
    # +0x209890 is set before this thread starts and never cleared, so the _exit branch is dead code

DataServer_ServiceStop():  +0x2098b4 = 1; wait (5 ms steps) until the main thread clears +0x2098b8      @ FUN_004010c0
```

The `NC_OPTOOL_CLOSE_SERVER_REQ` flag (`DAT_00656a3c`, §5, D05-B7) is not part of this loop: only the SCM can stop the server.

### 7.2 Sessions: accept, receive, framing, heartbeat, close

`CSession` (0x154 bytes, one per accepted link, pooled):

| + | Meaning |
|---|---|
| 0x08 | `CSocket_IOCP` (socket handle at +8; peer address at +0xc: port +0xe, IPv4 +0x10) |
| 0xbc | `CPacket` receive buffer: base +0xc0, capacity +0xc4 (0x2000), read cursor +0xc8, used bytes +0xd0 |
| 0xdc | state: 0 = connected, not authenticated; 1 = authenticated by 0x0802 (§5); 2 = (D01) |
| 0xe0 / 0xe4 / 0xe8 / 0xec | peer server type / world / zone / connect SYSTEMTIME (§5) |
| 0xfc / 0x100 | `timeGetTime` of the last receive / last write completion |
| 0x104 / 0x108 / 0x10c | opcode, payload length and work state (1 running, 2 done, 3 failed) of the packet being handled (log only) |
| 0x110 | time the heartbeat request was sent (0 = none pending) |
| 0x114 | send lock (CRITICAL_SECTION) |
| 0x134 / 0x148 | OVERLAPPED used to post a close; its kind = 2 |

```pseudo
Listener_AcceptThread(listener):                                          @ FUN_00410df0
    until stop: select(listen socket, timeout) → accept → AcceptorApp_OnAccept → CSession_Manager_OnAccept(sock, addr)
        returns null → log "*Accept_Process Error!*", closesocket
        select error → log "*Listen Socket Error!*"; Sleep 10 ms (1 ms after an accept)

CSession_Manager_OnAccept(sock, addr):                                    @ FUN_00409ff0 (CSession_Manager slot 2)
    under the session-list lock:
    s = SessionManager_TakeFree()                                         @ FUN_004118d0 / FUN_00411970
        none (max sessions in use) → log "* ACCEPT NO SESSION BUFFER - ERROR *" (once until a session is free again); return null
    s.socket = sock; s.addr = addr; s.state = 0; s.lastRecv = now; s.heartbeatSent = 0
    Socket_RegisterToIOCP(s) (associate + first ReadFile)                 @ FUN_00412d20
        fails → "ERROR - Socket_Register_To_IOCP Step #1|#2, Socket=%d, %s", log "* ACCEPT SOCKET IOCP REGISTER - ERROR *",
                release s, return null
    CSession_SendConnectionRdy(s): raw frame {02 01 08} = 0x0801 NC_MISC_S2SCONNECTION_RDY      @ FUN_00409e40
        fails → "* NC_MISC_S2SCONNECTION_RDY - SEND ERROR *", release s, return null
    # the peer answers with 0x0802 S2SCONNECTION_REQ (§5)

IOCP_WorkerThread(t):                                                     @ FUN_0040eb90
    log "<IOCP WORKTHREAD #%d RUNNING>"
    loop: GetQueuedCompletionStatus(1000 ms)
        failed with an OVERLAPPED (not timeout 0x102 / aborted 0x3e3) → IOCPManagerApp_OnError → CSession_Manager_OnClose  @ FUN_0040a230
        ok → IOCPManagerApp_OnCompletion(ov, bytes)                       @ FUN_0040a1d0
               CSession_OnIOCompletion(s, ov, bytes) == 0 → CSession_Manager_OnClose(s)
    "<IOCP WORKTHREAD #%d FREE>"

CSession_OnIOCompletion(s, ov, bytes):                                    @ FUN_00409b30
    kind 0 (read):
        s.lastRecv = now
        bytes == 0 (peer closed) → Session_Close; return 0
        used += bytes
        if !CSession_QueueReceivedPackets(s): Session_Close; return 0
        free = CPacket_FreeSpace(rx)                                      @ FUN_00413e00
        free ≤ 0 → log "ERROR - Socket buffer full, some protocol too large then socket buffer"; Session_Close; return 0
        CSocket_IOCP_Read(rx.base + used, free)                           @ FUN_00413120
            (0 bytes asked → "ERROR - CSocket_IOCP::Receive, …"; error other than 997 → "CSocket_IOCP::Read, ERROR=%d, …", no close)
    kind 1 (write done): s.lastSend = now; CSocket_IOCP_WriteCallback (free the sent buffer, start the next queued one;
        "MISSMATCH - WriteCallback, …", "m_pFirstBuf = NULL - WriteCallback, …" on inconsistencies)   @ FUN_00413420
    kind 2 (posted close): Session_Close; return 0

CSession_QueueReceivedPackets(s):                                         @ FUN_004099d0
    while CPacket_HasPacket(rx) == 1:                                     @ FUN_00413b80
        JobQueue_Push(g_JobQueue DAT_004569c0, s, frame, frame length)    @ FUN_0040a9d0
            # one 2 MB buffer of {session, frame} records under a lock; full → returns 0; the IOCP thread Sleep(2)s and retries
        CPacket_Advance(rx)                                               @ FUN_00413cc0
    HasPacket == 2 (bad frame) → log "패킷 오류 확인 From (%25s world=%3d zone=%3d, %5d=%15s:%5d) (DEP=%d,CMD=%d,LEN=%d,WORK=%d) at"
                                 ("packet error check"); return 0 (the session is closed)
    CPacket_Compact(rx) (move the unread tail to the start)              @ FUN_00413cf0; return 1

CPacket_HasPacket(rx):  frame = the bytes at the read cursor                @ FUN_00413b80
    header (CPacket_HeaderKind FUN_00413b40): first byte != 0 and > 2 bytes buffered → short frame, length = b0 + 1
                                              first byte == 0 and > 4 bytes buffered → long frame, length = u16 @1 + 3
                                              otherwise → 0 (wait for more)
    length (CPacket_FrameLength FUN_00413be0) ≤ 2 or > capacity (0x2000) → 2 (bad frame)
    return length ≤ buffered bytes ? 1 : 0
    # opcode = u16 after the length (CPacket_Opcode FUN_00413d70), payload length = b0 or the u16 (CPacket_PayloadLength
    # FUN_00413c20). Same framing as the client protocol (docs/protocol/README.md), no cipher on server links.

CParser_Dispatch(parser, job):                                            @ FUN_00409770 (CParser / CParserGameLog slot 0)
    s = parser.session (+8)
    for each frame in the job:
        s.curOpcode = opcode; s.curLen = payload length; s.work = 1
        handler = parser.table[opcode & 0x3ff][opcode >> 10]               # pft table: 1024 cmd rows × 64 depts, default fc_dummyfunction
        if !handler(frame + 2 (the opcode), payload length): s.work = 3; return       # SessionWorker_Run logs "*Work failed …" (§1.1)
        s.work = 2
    bad frame → log "패킷 오류 확인 …" (no close)

pft_Store(table, dept, cmd, fn):                                          @ FUN_00407ad0
    row = table[cmd] (allocated on first use, 64 slots of the default handler)
    row[dept] already set → AssertClass_ac_AssertFail("…pft_Store : Duplicate protocol set") and AssertClass_ExitLog:
        the process ends (_exit(0)) while the parser is constructed (§7.4)
    row[dept] = fn

CSession_Manager_HeartbeatTick():  (main thread, every second)            @ FUN_00409ee0
    under the session-list lock, for every used session with state == 1:
        if !CSession_CheckHeartbeat(s): CSession_PostClose(s)              @ FUN_004099b0 (PostQueuedCompletionStatus, kind 2)
    # state-0 sessions (connected, never authenticated) are never checked: (original bug) D05-B9

CSession_CheckHeartbeat(s):                                               @ FUN_00409d10
    now − s.lastRecv < 30 000 ms → s.heartbeatSent = 0; return 1
    s.heartbeatSent == 0 → s.heartbeatSent = now; Send 0x0804 NC_MISC_HEARTBEAT_REQ {} (CSendPacket, under the send lock);
                           return the send result
    now − s.heartbeatSent ≥ 180 000 ms → log "ERROR - HEARTBEAT OVERTIME, NOW DISSCONNECT WITH %s" (peer type name); return 0
    return 1
    # any received frame resets the timer (lastRecv is set on every read completion); the peer's 0x0805 ACK is a no-op (§5)

CSession_Manager_OnClose(s):                                              @ FUN_0040a0d0 (CSession_Manager slot 3)
    under the session-list lock:
    if s.state != 0: log "Closed    from %p (%-25s world=%3d zone=%3d, %- 5d=%15s:%- 5d) (% 3d/% 3d개) (DEP=%d,CMD=%d,LEN=%d,WORK=%d)"
                     (peer, address, sessions in use / max, last packet)
    SessionManager_Release(s): back to the free list                      @ FUN_00411710 / FUN_004115d0
```

Send buffers: `CSocket_IOCP_Send` (§1.1) copies each chunk into a pooled `CIOBuffer` (0x2010 bytes, 0x2000 data):
`IOBuffer_Alloc` FUN_00417690 takes one from 16 spin-locked free lists (round robin), else from 16 × 512 buffers pre-allocated by
`IOBufferContainer_ctor` FUN_00417600 (allocation failure there → `AssertClass_ExitLog("IOBufferContainer::IOBufferContainer")`),
else from the heap; `IOBuffer_Free` FUN_00417780 pushes it back on a free list (buffers are never returned to the heap). Write
errors are logged with `ShineLog_Write` (§7.4).

### 7.3 ODBC connection

`Database_Connect(connection string)` FUN_00417c70 (class `Database`, ctor FUN_00417ab0, dtor FUN_00417c00): one process-wide ODBC
environment (`DAT_006621ac`, reference count `DAT_006621b0`, freed with the last connection), one connection handle per
`Database` (disconnected and freed first if already open), `SQLDriverConnect` with the `ODBC_INFO` connection string, no prompt.
Each session worker opens its own (`SessionWorker_DBInit`, §1.1), so the number of SQL connections = number of workers
(≤ 81). `ServerInfo_FindODBC` FUN_00410030 finds the `ODBC_INFO` row (scriptor record kind 4) by id (11) and the second integer
column (`DAT_0044d68c`, next to `g_MyServerType`; 0 in the 2016 config).

### 7.4 Diagnostics: debug log, crash dump, asserts, scriptor report

```pseudo
Log(level, category, fmt, …) = DebugMessage_Write                         @ FUN_0040fcd0 → FUN_0040fa80
    (also LogMsg FUN_0040fc90, LogMsgLevel FUN_0040fcb0 with category "Msg")
    level 0 → nothing
    line = sprintf("%06d %s%s\n", counter++, TimeString() ("yyyy-mm-dd hh:mm:ss ", FUN_0040f8e0), message (≤ 1024))
    append to ".\DebugMessage\<category>_<yyyy-mm-dd>.txt" (MakeSureDirectoryPathExists; file opened and closed per line)
    # the counter DAT_00657df8 is incremented without a lock from all threads (inferred harmless: numbering only)

ShineLog_Write(log, fmt, …):                                              @ FUN_00417850 (name: ShineLog_SetName FUN_004177e0, default "ShineLog")
    used only for "CSocket_IOCP::Write %#x(%#x) err=%d" (log object DAT_0044ae90)
    file ".\Log\<name>_<yyyy-mm-dd> <hh>.txt" (hourly) or ".\Log\<name>_<yyyy-mm-dd>.txt" (daily); reopened when the name changes;
    line "%06d <yyyy-mm-dd> <hh:mm:ss:mmm>\t<message>"

Exception_Filter(exception):  (unhandled exception)                       @ FUN_00412590
    load DBGHELP.DLL from the exe directory, else the system one
    Exception_WriteCallStack → "CallStack.txt" (exception name table FUN_00416a20, stack walk FUN_00416cd0 / FUN_004170d0)  @ FUN_00412370
    optional hook DAT_006586e0 (never set in this binary (inferred))
    MiniDumpWriteDump(…, type 0x40) into "<exe path> <TimeStringForFile()>.mdmp" (FUN_0040f9a0: "yyyy-mm-dd tt hhmmss")
    log "EXCEPTION - Saved dump file to '%s'" / "… Failed to create|save dump file …" / "DBGHELP.DLL NOT FOUND|TOO OLD"
    # what happens after the dump depends on the filter's return value (not decompiled; inferred: the process ends)

AssertClass (DAT_0044a6a8):
    ac_AssertFail(msg, value) → append "%s : AssertClass::ac_AssertFail : %s[%d]" to "Assert<yyyymmdd><hh>.txt"   @ FUN_00412970 / FUN_00412920 / FUN_004128a0
    AssertClass_ExitLog(where) → append "%s : AssertClass::ac_AssertFail : %s" to "ExitLog<yyyymmdd><hh>.txt"; _exit(0)   @ FUN_004129c0
    callers: duplicate pft_Store (§7.2), IOBufferContainer allocation, SHN read failures
             ("BinaryDataBox<T>::bdb_ReadData : readfail", "Code:%X:%d\tSHN:%X:%d" when the file header does not match the expected one, FUN_00410120)
```

The config reader ("scriptor", `Scriptor_ReadFile` FUN_0040e7c0) reads `DataServerInfo_GameLog.txt` and its `#INCLUDE`s: `#DEFINE`
blocks declare record formats (`<STRING>`, `<INTEGER>` …), data lines are matched against them, directives are handled by
`Scriptor_Directive` FUN_0040cd60 (a 7-entry keyword table: block-comment on/off and settings that redefine
separator characters *(inferred: the keyword strings are not in the export)*). Every step is reported with
`Scriptor_Report` FUN_0040cb40 into an in-memory list ("FILE PROCESSING - %s", "Include - %s", "%s - UNKNOWNED.",
"FILE OPEN ERROR(Code = %d) - %s", totals "TOTAL Format|Data %d Defined, %d Errors" by `Scriptor_Summary` FUN_0040d5f0). Records
are read by kind (3 = SERVER_INFO and 4 = ODBC_INFO are checked by the code; that the kind is the `#DEFINE` order, 0 = MY_SERVER,
1 = NATION_NAME, 2 = WORLD_NAME, is *(inferred)*) and column (accessors FUN_0040cc10 / FUN_0040cc20 / FUN_0040cc70). This is the generic Shine config reader; its
error handling is what `DataServer_ReadDefineScriptor` (§1.1) checks.

### 7.5 Linked-in code that no GameLog path uses

The binary links the shared game-data library: `BinaryDataBox<ItemInfo | ItemInfoServer | ItemOptions | GradeItemOption |
ItemDropLog | ItemSort | ItemInvenDel | ItemMoney | ShineReward | FriendPointReward | MapInfo>`, `ItemDataBox` (operator[] with
"Invalid Item index"), `ItemOptionsData::OptionCardStack` (random-option cards, `CardDeck` lists), `ItemAttributeClass` and its
`ItemAttrCls_*` subclasses, `MapDataBox`, `DBRecord`/`BinaryData` (name hash, FUN_004141e0 is the only part used, by
`ItemDataBox_Load`). Apart from the ItemInfo load (§7.1) none of it has a caller outside the library: the call graph of the export
shows calls into 0x414190–0x416870 and 0x417da0–0x418ed0 only from the ItemInfo/MapInfo loaders, the static constructors of the
`BinaryDataBox` globals and the shared empty destructor `CSendPacket_dtor` FUN_004183c0 (identical-code folding). It is therefore
dead weight in the GameLog server; the zone owns the behaviour of these tables (§10).

## 8. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D05-B1 | every CParserGameLog handler (§1.3) | no packet-length check; fixed offsets are read whatever the length | a short or truncated log packet writes stale receive-buffer bytes into `tGameLog` | check the length per command |
| D05-B2 | 0x0452 ITEM_UPGRADE `FUN_00404bf0` | reads a 0x2D-byte layout with an extra u16 at 0x20; the 2016 zone sends the 0x2B-byte PDB layout | upgrade rows have old/new level packed into `nMapZ`, item ids shifted by one field, `nBigint1` high dword from 2 bytes past the packet | read the zone's layout (old level, new level, left/right/middle id, element) |
| D05-B3 | 0x0415 MOVE `FUN_004036a0` | `sMap` = constant `"NEED"`; the packet's map name is dropped | move rows have no map | copy `startpos.MapName` |
| D05-B4 | 0x044F ITEM_CREATE `FUN_004049c0` | `sMap` = constant `"RouN"`, coordinates 0 | every created item looks created in RouN | leave the map empty (the packet has none) |
| D05-B5 | `SQL_p_GameLog_Add_TypeL` `FUN_0041b4c0` | the failure line starts `"TA,"` and omits `nBigint1` | lost TypeL rows look like TypeA rows in `GameLog_<date>.txt`, without their 64-bit value | `"TL, …, %I64d"` |
| D05-B6 | 0x0462 MONEY_CHANGE `FUN_00405660` | zeroes the struct, copies only the three money values; `nType` and `nCharNo` stay 0 (`chrregnum` @0 is never read) | every money-change row (sent on each money change by the Character server) has nType 0 and no character | `nType = 98`, `nCharNo = chrregnum` like every other handler |
| D05-B7 | 0x2803 OPTOOL_CLOSE_SERVER_REQ `FUN_00409360` | no CheckAlive; replies 0x2804 `{0x0600}` and sets `DAT_00656a3c`, which no code reads (the Account server's copy, D01 §2, is the same) | an operator tool is told the server closes, but it keeps running; any peer, even unauthenticated, gets the same answer | stop the main loop / service on the flag, and require an authenticated link |
| D05-B8 | 0x075C GUILD_ACADEMY_CLEAR_REWARD_MONEY `FUN_00406950` | zeroes the TypeA struct and calls the procedure without copying anything (no nType, no field) | each packet writes an all-zero `tGameLog` row (nType 0); no 2016 server sends it, so latent | `nType = 860`, `nInt1 = nGuildNo`, `nCharNo = nCharNo` like 0x075A |
| D05-B9 | heartbeat `CSession_Manager_HeartbeatTick` FUN_00409ee0 (§7.2) | only sessions in state 1 (authenticated by 0x0802) are checked; a peer that connects and never sends a valid 0x0802 keeps its session forever | each such connection holds one of the `SERVER_INFO` max sessions (100); enough of them make every later accept fail with "ACCEPT NO SESSION BUFFER" and log packets are lost | time out state-0 sessions too (e.g. no 0x0802 within some seconds) |
| D05-B10 | `WinService_ReportStart` FUN_00411ee0 / `DataServer_ServiceStart` FUN_00401f90 (§7.1) | when the start fails (syslog writer allocation or thread, IOCP threads, workers, ServerInfo row, listen socket, main thread) ServiceMain returns with the status still `SERVICE_START_PENDING`; threads already started keep running | the SCM shows the service as "starting" until its timeout, the half-started process stays alive without a listener; the cause is only in the DebugMessage log | report `SERVICE_STOPPED` with an exit code and stop the started threads |
| D05-B11 | `RotatingLog_WriterThread` FUN_0040f250 (§6.1) | `RotatingLog_Open` FUN_0040f6b0 ignores the `CreateDirectoryPath` result; when an `fopen(path, "a+")` fails (missing or unwritable directory at start, full disk or locked file at an hourly rollover) the writer thread ends and sets running = 0; `RotatingLog_Write` then drops every line, nothing is logged and nothing retries | all NC_SYSLOG lines are lost silently for the rest of the process life, while the server keeps running normally | log the failure and retry the open at the next line or rollover |

Next free ID: D05-B12.

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
  text; the wedding hall is Z07's open question (Z07 plan line 13).
- 0x075B SET_REWARD_ITEM stores the u16 at 0x0B (`nItemLot` in the 2017 PDB) in `nTargetID` and the u16 at 0x09 (`nItemID`)
  in `nInt3`, the reverse of the usual "item id → nTargetID". No 2016 sender exists to tell whether the 2016 layout had the lot
  first or the handler swaps them.
- 0x0798 MK_DROP_ITEM: the drop is logged only for items with an `ItemInfo +0x18` record; that this is the `ItemDropLog` table,
  and that the zone's u16 at 0x0C (dropper `vt 0x344`) is the mob id as the PDB names it, are inferred.
- 0x079F RANDOMOPTION_CHANGE_AFTER has no 2017 PDB struct; its layout is the 0x079E/0x0401 one (same handler, same sender).
- The nType values of §4.4 come from the 2016 script folder; scripts loaded from elsewhere could log other values. The
  per-argument meaning of 2026's nInt1–3 is read from the argument names only.
- NC_SYSLOG: the meaning of AttackerType/TargetType values beyond 0/1 and the unit of `PlayTime` ("in-game-minutes") come from
  the format strings only; the senders (W01, Z03) own the values.
- Framework (§7): the scriptor's directive keywords (table at `+0x3fc`, read by FUN_0040b650) and the exact behaviour after the
  crash dump were not decompiled in detail; both are generic Shine library code with no GameLog-specific behaviour. The
  `MY_SERVER` string at `+0x4f8` being the service name is inferred from the service calls (the reader FUN_00401370 fills it).
- `IOCP_StopThreads` FUN_0040ea60 and the session-pool free/destroy helpers (FUN_004115d0, FUN_00411570, FUN_00411820) were read
  only as far as their names say; they hold no protocol behaviour.
- Whether the 2016 deployment ran the GameLog server as an installed service (the only mode the code supports, §7.1) and with
  which account: not in the binary.

## 10. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| Sender functions of every log packet (zone, WM, Character) | Z01/Z03/Z05/Z08, W01, D02/D03/D04 (cited per row in §2.3) | they build the packet as part of their own feature; D05 only records what the GameLog server stores |
| `usp_Login_setChannel` body, `tGameLog` schema | D06 (scope: "missing procedures, schema") | not in any backup |
| Zone senders `FUN_0045e810` (horse item belong), `FUN_00520840`/`FUN_00520aa0` (costume charges), `FUN_005a25a0`/`FUN_005a2b60` (wedding hall) | Z13 (plan line 16: `sp_HorseItemSave`) / Z17 (plan line 13: costume weapon/shield charges) / Z01 (scope row 0x2055 `FUN_005a2b60`, Z01 plan line 94) and Z07 (wedding hall `wh_Start`, Z07 plan line 13) | only the log packet they build is D05's (§3.2); the game logic around it belongs to the zone items |
| The 23 no-op registrations (§3.3) | D05 (done) | `fc_ReturnTrue`: nothing to reconstruct beyond "ignored" |
| DataServer framework beyond the worker (main, service, listener, IOCP, framing, heartbeat, diagnostics) | D05 (done, §7) | documented in part 4; D01 §1 has the same code for Account/AccountLog but only the worker part |
| Zone script functions `cSendGameLogDataType_4/5` (FUN_005f1a10, FUN_005f1d40) and `cSaveTutorialInfo` (FUN_005e70b0), their `Send_NC_LOG_GAME_DATA_TYPE_4/5/F/G` builders (FUN_006144a0, FUN_006145c0, FUN_006146a0, FUN_006147f0) | Z10 (plan line 14: "any other `lua_setglobal` registrations", i.e. the `c*` table `FUN_005f5350`) and Z09 (Lua scripts, 9Data/Shine/LuaScript) / Z05 §5.3, §8.2 | only the log packet is D05's (§4.3, §4.4); the scripts and the tutorial state belong to the zone items |
| Zone MK2 kill-log visitor `AxialListMobKillLog` (ctor FUN_00428340, `ali_Work` FUN_00429590, dtor FUN_00428480) and its MK2_START trigger FUN_00556d70 (vt 0x588) | Z03 (kill and combat flow, `so_KilledBy`) / Z09 (mob objects and their vtables) | D05 documents the packet and the trigger condition (§4.2); the combat bookkeeping at vt 0x588 belongs to the zone items |
| Zone senders `ShineMob_so_KilledBy` FUN_00432760, `ShinePlayer_so_KilledBy` FUN_00433be0, `ShineDropItem_so_ItemDrop` FUN_0052a7a0, `ShinePlayer_so_LinkTo` FUN_0049ad30, `CQuestZone_Recv_NC_QUEST_DB_SET_INFO_ACK` FUN_005bf280 | Z03 §8.1 / Z05 §3.1 / Z01 / Z08 | they build 0x0791/0x0798/0xC809–0xC80F as a side effect of their own feature |
| WM syslog senders FUN_004113c0, FUN_0040a010, FUN_00410040, FUN_00436d50, FUN_0042e160 | W01 | 0xC804–0xC808 are built by the WM's character life-cycle handlers |
| CPFs server-link handlers (§5): handshake rules, session list | D05 (done, §5) | in D05's scope table (part 3); D01 §2 documents the same code for Account/AccountLog |
| Rotating text log internals: deque growth (FUN_0040ef00 allocates 0x1c-byte `std::string` blocks), string helpers (FUN_0040b130 assign, FUN_0040b040 substring assign, FUN_0040f160 queue front copy) | D05 (done, §6.1) | MSVC `std::deque<std::string>` / `std::string` code; the behaviour is in §6.1, the helpers hold no protocol logic |
| Shared game-data library linked into the binary (0x414190–0x416870, 0x417da0–0x418ed0: `ItemDataBox`, `ItemOptionsData::OptionCardStack`, `CardDeck` lists, `ItemAttributeClass`/`ItemAttrCls_*`, `BinaryDataBox<…>` for ten item tables, `MapDataBox`) | Z01 (Goal: "SHN data loading (list every table and its loader)") / Z04 (Goal: "Use ItemInfo/ItemInfoServer/ItemUpgrade/RandomOption SHN tables") | dead code in the GameLog server (§7.5): no caller outside the library except the start-up ItemInfo load; the zone uses the same tables for real and owns their meaning |
| `ItemInfo.shn` loaded at start (`ItemDataBox_Load` FUN_00410a40, SHN reader FUN_0042faa0) | Z01 / Z04 (as above); SHN format: `tools/protocol-re/shn.py` | loaded but never read by GameLog code (§7.1); nothing to reconstruct beyond "must exist or the server does not start" |
| MSVC CRT / STL / EH runtime (0x41b780–0x432f50 except the SHN reader 0x42f700–0x431270; `std::string`, `std::bad_alloc`, `_sprintf`, `__mbstok` …) | none needed | compiler runtime, no server behaviour |
| Exception call-stack writer internals (FUN_00416a20, FUN_00416cd0, FUN_004170d0, FUN_00417520) | D05 (done, §7.4, summary) | generic crash-report code; only its output files matter for an operator |
| Scriptor internals (FUN_0040b3f0 tokenizer, FUN_0040b650 keyword match, FUN_0040e2c0 #WRITE/#READ of formats, FUN_0040d260/FUN_0040cf70 data/format definitions, FUN_0040ca40/FUN_0040cac0 index arrays) | D05 (done, §7.4, summary) | generic Shine config reader, the same in every server; the GameLog-specific part is the config content (§1.1, §7.1) |
