# Account and AccountLog servers: reconstructed pseudocode (D01)

Sources: `Files/Server/2016/Account/Account Release.exe` (export `account`) and
`Files/Server/2016/AccountLog/AccountLog Release.exe` (export `accountlog`). Each block cites the function it was read
from (`@ FUN_xxxxxxxx`, Account addresses unless marked `AL:`). Names are ours unless they come from a string in the binary
(`CPFsAccount::fc_NC_…`, `CSQLPAccount::…`), the 2017 PDB *(pdb2017)* or a DB backup *(db-backup)*. Procedure sources were
printed with `tools/protocol-re/bak.py` from `Account.bak`, `AccountLog.bak` and `StatisticsData.bak` (one stored version
each unless noted); every `{CALL}` string has the same parameter count as the backup copy unless noted. Payload offsets are
after the 2-byte opcode. Packet layouts: [`../../protocol/annotations/D01.json`](../../protocol/annotations/D01.json).

---

## 1. Process structure (both servers)

Both are instances of the same "DataServer" framework; only the parser classes and the SQL wrappers differ.

```
DataServer
├── config         : DataServerInfo_Account.txt / DataServerInfo_AccountLog.txt (MY_SERVER "PG_AccDB" type 0 /
│                    "PG_ALDB" type 1) + #INCLUDE ../9Data/ServerInfo/ServerInfo.txt          @ FUN_00401360 / AL:FUN_00401380
├── ODBC_INFO rows : Account → "Account" (id 0); AccountLog → "AccountLog" (id 1, BASE) + "Statistics" (id 2,
│                    "DB_ID_STATICSTICS", database StatisticsData)                             @ FUN_00405f20 / AL:FUN_00405870
├── also loads     : ../9Data/Shine/MapInfo.shn, ItemInfo.shn (framework; not used by any handler)
├── listener       : accepts Login / WM / OPTool links (CPFs parser = server-link handlers)
├── sessions       : per link: +0xdc state (0 = not authenticated, 1 = connected, 2 = …), +0xe0 peer type,
│                    +0xe4 world, +0xe8 zone, +0xec connect SYSTEMTIME; send lock at +0x114
└── session workers: N threads ("<NUMBER OF %d SESSION WORKER STARTED>")                         @ FUN_00406010
```

```pseudo
SessionWorker.Run(w):                                    @ FUN_00406010
    w.running = 1
    if !DBInit(w): w.state = 4; log "<SESSION WORKER #%d INIT DB FAILED - STOP ******>"; return
    w.state = 2
    while w.state == 2:
        job = queue.Pop(w)                       @ FUN_00406780   (one received packet + its session)
        if none: Sleep(2); continue
        ok = parser.Dispatch(job)                # vtable slot 0; handler = table[dept][cmd]
        if !ok and session.state != 0:
            log "*Work failed (…) (DEP=%d,CMD=%d,LEN=%d,WORK=%d, WorkerID=%d)"
    close the worker's ODBC connection; log "<SESSION WORKER #%d FREE>"

DBInit(w):                                               @ FUN_00405f20 (AL:FUN_00405870)
    open ODBC "BASE" row of my server  → w.db  (handler code: *this + 0x124c)
    AccountLog only: open "Statistics" row → w.statDb (*this + 0x126c)
    missing row: "DB_Init FAILED, Scriptor BASE ODBC info. not found." / "… DB_ID_STATICSTICS ODBC info. not found."
```

Every handler runs on a worker with **its own** DB connection, so handlers block on SQL but do not share a statement.

### 1.1 Helpers used by every handler

```pseudo
CheckAlive(session, pkt):                                @ FUN_004046c0 (AL:FUN_00403f80)   (asm: returns 0 / 1)
    if session.state(+0xdc) == 0:
        log "ERROR - 접속 미인증 상태에서 패킷 도착, 바로 접속을 끊음, dep=%d, cmd=%d"   # "packet before authentication"
        return 0                                  # the packet is ignored (the message says "disconnect", the code does not)
    return 1

SQL wrapper pattern (every CSQLPAccount / CSQLPAccountLog function):
    stmt = db.stmt;  SQLCloseCursor(stmt)                 # ODBC32 ordinal 26
    SQLBindParameter(stmt, i, INPUT|OUTPUT, cType, sqlType, …)   # ordinal 72, one per '?'
    rc = SQLExecDirect(stmt, "{CALL proc(?,…)}", SQL_NTS)        # ordinal 11
    ok = rc in {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO} [and the @nRet output has the expected value]
    on error some wrappers log SQLError state/number/text   @ FUN_00417420 (AL:FUN_00412f80)
Result rows: DB_Fetch @ FUN_004124a0 (AL:FUN_0040e530) (SQLFetch), DB_GetLong @ FUN_004124e0 (AL:FUN_0040e570)
             (SQLGetData col++, SQL_C_SLONG), DB_GetULong @ FUN_00412510 (SQL_C_ULONG), DB_CloseCursor @ FUN_004124d0.
             AccountLog's `DBRecord::operator>>` (AL:FUN_0040e5a0, AL:FUN_0040e5d0) are the same column reads (pdb2016 names).

Sends:  SendPacket(session, CSendPacket)  @ FUN_004055a0 (AL:FUN_00404e80)
          CSendPacket: Init @ FUN_004121d0 (AL:FUN_0040e250), SetOpcode(op, size) @ FUN_00412310 (AL:FUN_0040e3a0),
          payload at +5; GetSendSize @ FUN_004122d0 (AL:FUN_0040e360), GetSendPtr @ FUN_004122f0 (AL:FUN_0040e380)
          SetSize @ FUN_004121f0 (AL:FUN_0040e280) writes {u8 size+2} when size+2 < 0x100, else {0, u16 size+2}  (correct framing)
        SendRaw(session, frame, n)  @ FUN_004055d0 (AL:FUN_00404eb0): the handler builds {u8 len, u16 op, payload}
          itself; the length byte is a plain u8 (see D01-B1 / D01-B2)
```

### 1.2 Copies of shared and library code (address aliases)

Both binaries link their own copy of the shared server library (S02) and of the compiler runtime. The behaviour is
documented where the cited section says; only the addresses here are new. Names are *(pdb2016)*. The Account /
AccountLog bodies were not compared byte-wise with the S02 reference copies (same library source, inferred).

| Function | Account | AccountLog | Documented at |
|---|---|---|---|
| `CSocket_IOCP::Send` | FUN_00413770 | – | S02 §1.5 |
| `CSocket_IOCP::Shutdown` | FUN_004131f0 | FUN_0040ed50 | S02 §1.5 |
| `CSocket_IOCP::Close` | FUN_00413340 | FUN_0040eea0 | S02 §1.5 |
| `CSocket_IOCP::FreeBuffer` | FUN_004132d0 | FUN_0040ee30 | S02 §1.5 |
| `CSocket_Session::Send` (two overloads) | FUN_00412c80, FUN_00412cd0 | FUN_0040e7e0, FUN_0040e830 | S02 §1.6 |
| `CSocket_Session::Close` | FUN_00412c60 | FUN_0040e7c0 | S02 §1.6 |
| `CSocket_Session_Manager::CSM_Enter_CS` / `CSM_Leave_CS` | FUN_00410300 / FUN_00410320 | FUN_0040c390 / FUN_0040c3b0 | session-list lock, S02 §1.6 |
| `GetShineServerIDName` | FUN_00406eb0 | FUN_00406a80 | S02 §2.5 |
| `Name256Byte::Name256Byte`, `Name256Byte::operator=` | FUN_00402050, FUN_00402180, FUN_004022c0 | FUN_004020f0, FUN_00402220 | 256-byte name copy (compiler-generated) |
| `PROTO_NC_USER_GER_PASSWORD_CHECK_ACK::operator=`, `PROTO_NC_USER_US_PASSWORD_CHECK_ACK::operator=` | – | FUN_00402d70, FUN_00403000 | struct copy of `LoginData` into the IP-block ack, §4.3 |
| `std::basic_string` `assign` / `append` / `_Copy` / dtor, `std::_Xlength_error` | FUN_00406db0, FUN_0040f460, FUN_0040b7b0, FUN_00406b50, FUN_00403de0, FUN_00419c42 | – | MSVC STL, not reconstructed |
| `_ftol2_sse`, `operator delete[]` | FUN_0041b830, FUN_0041b75a | – | MSVC CRT, not reconstructed |

The JP web check's helpers (§3.2, 0x0C4B) are third-party code used as-is, not reconstructed beyond their call site:
MD5 `CMD5Checksum::Update` / `Transform` / `Final` FUN_0040b700 / FUN_0040b020 / FUN_0040b8e0 (under `MD5_Hex`
FUN_0040baf0); HTTP client `CWebHttpConnect::InitConnection` / `SetServer` / `SetFuntion` / `SetParameter` /
`MakeAddress` / `QueryToServer` / `GetHTMLDocument` / dtor FUN_004129b0 / FUN_00412710 / FUN_00412750 / FUN_004127a0 /
FUN_00412800 / FUN_00412a70 / FUN_00412950 / FUN_00412980; TinyXML `TiXmlDocument` ctor / `Parse` / `SetError`
FUN_00408140 / FUN_0040a210 / FUN_004096d0, `TiXmlNode` ctor / dtor / `Identify` / `FirstChild` / `NextSibling` /
`FirstChildElement` FUN_00407de0 / FUN_00407e20 / FUN_00409b80 / FUN_004078b0 / FUN_00407900 / FUN_00407950,
`TiXmlElement` ctor / `GetText` FUN_00408c40 / FUN_00407a30, `TiXmlText` / `TiXmlDeclaration` ctors FUN_004089f0 /
FUN_00408ac0, `TiXmlBase::SkipWhiteSpace` / `StringEqual` / `IsAlpha` FUN_004094e0 / FUN_00409620 / FUN_004092d0,
`TiXmlString::assign` FUN_00407710.

---

## 2. Server-link handlers (CPFs, identical code in both binaries)

Registered by the CParser base constructor `@ FUN_00405290` (AL: same code). The default slot is `fc_dummyfunction`
`@ FUN_00404750`: logs `"fc_dummyfunction, Protocol = 0x%04x, dep=%d, cmd=%d, length=%d From (…)"` and ignores the
packet. The normalized decompilation of all CPFs handlers is byte-for-byte the same in Account and AccountLog.

```pseudo
0x0801 NC_MISC_S2SCONNECTION_RDY, 0x0805 NC_MISC_HEARTBEAT_ACK:  return 1 (no-op)     @ FUN_00404820 (AL:FUN_004040e0)
0x0804 NC_MISC_HEARTBEAT_REQ:                              @ LAB_00404db0 (not decompiled; reply 0x0805 as in Login, inferred)
0x0823 NC_MISC_START_THE_BOOM_CMD:  return CheckAlive()    @ FUN_00402510 (AL:FUN_00404b50)  — no action

0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo @0, u8 server_id_to @1, u8 server_id_from @2, u8 world @3, u8 zone @4,
                                   u16 key @5 }:           @ FUN_00404830 (AL:FUN_004040f0)
    ok = 1
    if session.state not in {0, 2} and session.type != 3:
        ok = 0; log "접속되어 있는 세션인데, 또 접속요청이 온 경우 - IP=…"   # "already connected session asks again"
    if server_id_to != my_type (Account 0, AccountLog 1) and ok:
        ok = 0; log "접속요청한 서버의 타입과 나의 타입이 맞지 않음 …"        # "requested type is not my type"
              log "NC_MISC_S2SCONNECTION_REQ <server_from id=%d w=%d z=%d, server_id_to=%d, key=%d, my_type=%d>"
    if ok and key != server_id_to + server_id_from:
        log "접속요청한 곳에서 잘못된 키값이 왔음 …"                          # "wrong key"
        log "NC_MISC_S2SCONNECTION_REQ <server_id_from=%d, server_id_to=%d, key=%d, my_type=%d>"
        close(session); return
    if !ok: close(session); return
    session.type/world/zone = from/world/zone
    SendPacket 0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo, u16 0 }
    if send failed: log "CProtocol_Functions::fc_NC_MISC_S2SCONNECTION_REQ - 응답패킷 보내기 에러 …"; close
    else: session.state = 1; session.connectTime = GetLocalTime(); log "Connected from %p (…)"

0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo, u16 err @1 }:  if err == 0: session.state = 1; log "Connected to …"   @ FUN_00404ce0 (AL:FUN_004045a0)

0x2801 NC_OPTOOL_S2SCONNECT_LIST_REQ { u8 echo }:          @ FUN_00404dd0 (AL:FUN_00404690)
    reply 0x2802 { u8 echo, u8 my_type, u16 n, n × { u8 type, u8 world, u8 zone,
                   u32 connectTime = (year & 0xf) | month<<4 | day<<8 | hour<<13 | minute<<18 | second<<24 } }
                   # bit fields 4/4/5/5/6/6 of the session's connect SYSTEMTIME
                   # one entry per session with state 1, under the session-list lock
0x2803 NC_OPTOOL_CLOSE_SERVER_REQ:  reply 0x2804 { u16 0x0600 }; g_Shutdown (DAT_00654bbc) = 1   @ FUN_00404fc0 (AL:FUN_00404880)  (no CheckAlive)
0x2805 NC_OPTOOL_MAP_USER_LIST_REQ { u8 echo }:  reply 0x2806 { u8 echo, u8 my_type, u16 0 }   @ FUN_00405070 (AL:FUN_00404930)
0x2807 NC_OPTOOL_CONNECT_BRIF_REQ { u8 echo }:             @ FUN_00405140 (AL:FUN_00404a00)
    reply 0x2808 (0xaa bytes, zeroed) { u8 echo, u8 my_type, u16 count[type][world][zone] }
        for each session with state 1: t = type (> 20 → 10), w = world (> 1 → 0), z = zone (> 1 → 0); count[t][w][z]++
```

---

## 3. Account server (CParserAccount, registered @ FUN_00404520)

Peers: Login (password checks, world-select notices), WM (return-user, web key, PC-bang check, event), and whoever sends
the teen-protection packets. Every handler first calls `CheckAlive`; on 0 it returns without a reply.

### 3.1 Handlers that do nothing

```pseudo
0x0C10 NC_USER_LOGIN_DB, 0x0C11 NC_USER_LOGOUT_DB, 0x140D NC_USP_USER_CHARACTER_INSERT,
0x140E NC_USP_USER_CHARACTER_DELETE:   return CheckAlive()          @ FUN_00402510
```

Login sends 0x0C10 `{ u32 usrregnum, u8 worldnum, u8 ip[4] }` on every world select (login-server.md §4); the Account
server registers it and drops it. No `usp_*` for login/logout or character counts is called in this build.

### 3.2 Login checks (the result codes behind Login's 0x45 / 0x47 / 0x48 / 0x4B)

```pseudo
0x0C5B NC_USER_US_PASSWORD_CHECK_REQ { u16 clienthandle @0, char sUserName[260] @2, char sPassword[36] @0x106,
                                       char sUserIP[20] @0x12a, Name5 spawnapps @0x13e }   (0x152, Login FUN_00406450)
                                                            @ FUN_00402fe0  "CSQLPAccount::usp_UserUSLoginGame"
    ack = 0x0C5C NC_USER_US_PASSWORD_CHECK_ACK (CSendPacket, 0x161 bytes):
        clienthandle = req.clienthandle;  nError = 0x41;  nUserNo = -1
        sUserName = req.sUserName (first 256 bytes); sPassword = req.sPassword (first 32); sUserIP = req.sUserIP (20)
        spawnapps = req.spawnapps;  nAuthID = nBlock = bLoginAble = 0
    p = { userID = sUserName[256], userPW = sPassword[32] }
    if !usp_User_USLoginGame(p):                           @ FUN_004197c0
        ack.nError = 0x43                                  # DB error
    else:
        ack.nUserNo = p.userNo; ack.nAuthID = p.authID; ack.nBlock = p.block; ack.bLoginAble = p.isLoginable
    SendPacket(ack)

usp_User_USLoginGame(p):                                   @ FUN_004197c0
    {CALL usp_User_USLoginGame(?,?,?,?,?,?)}
      1 in  WVARCHAR userID (256)   2 in  WVARCHAR userPW (32)
      3 out INTEGER @userNo         4 out TINYINT @authID       5 out INTEGER(ulong) @block   6 out INTEGER @isLoginable
    p.nRet (+0x138) = 0 and is never bound; "ok" = rc ∈ {0,1} and p.nRet == 0   # the nRet test is dead (original bug) D01-B3
    on failure: log "ERROR - CSQLPAccount::usp_UserUSLoginGame, ret(%d), nRet(%d)" + SQLError detail
```

Procedure `usp_User_USloginGame` (Account.bak, Korean header "Ko Dong Gyun, 2007-05-07; 2013-01-28 US service move:
retry with the e-mail when the ID fails") *(db-backup)*:

```sql
SET @userNo = 0
SELECT @userNo = nUserNo, @authID = U.nAuthID, @block = bIsBlock, @isLoginable = bIsLoginAble
  FROM tUser U JOIN tUserAuth UA ON U.nAuthID = UA.nAuthID
 WHERE sUserID = @userID AND sUserPW = @userPW AND bIsDelete = 0
IF @userNo = 0  -- retry: tUserOption.sEmail = @userID
    … same SELECT joined with tUserOption …
    IF @userNo = 0  → @userNo = -1, @authID = 0, @block = 0, RETURN
IF @block = 1 → EXEC usp_User_chkBlock @userNo, @RET OUTPUT; IF @RET = 1 re-read @block = tUser.bIsBlock
-- "added by Stu": @userPW = '8a6f2805b4515ac12058e79e66539be9' (EGPal accounts) → @userNo = 0, all flags 0, RETURN
-- "added by John": user in tUserMergeYet → HTTP GET http://10.55.12.231:880/<userNo>; result ≠ userNo → @userNo = -1
```

`usp_User_chkBlock(@userNo, @RET OUTPUT)` (Account.bak, Ko Dong Gyun 2007, source cut at 8 KB but complete in practice)
*(db-backup)*: takes the oldest active `tUserBlock` row (`bStatus = 1`); if it is a timed block (`nType = 1`) whose
`dEndDate` has passed, sets that row `bStatus = 0`; if no other active block remains, sets `tUser.bIsBlock = 0` and
`@RET = 1` (so the caller re-reads `bIsBlock` = 0). Otherwise `@RET` stays unset/0 and the account stays blocked.

**Login open question resolved** (Login `AccountCheckResult`, login-server.md §5.1):

| Login result | Account field | Set when *(db-backup unless noted)* |
|---|---|---|
| 0x45 "Please check ID or Password." | `nUserNo == -1` | no `tUser` row with this ID **or** e-mail, this `sUserPW`, `bIsDelete = 0`; or a `tUserMergeYet` account whose HTTP check fails. Also the Account server's own default when the DB call fails (`nUserNo = -1`, `nError = 0x43`; read in the code) |
| 0x4B "Please accept the agreement" | `nUserNo == -2` | **never**: no procedure in any backup returns -2, and the Account binary never writes -2. Dead branch against these DBs |
| 0x47 "The ID has been blocked." | `nBlock != 0` | `tUser.bIsBlock = 1` and no expired timed block could clear it (`usp_User_chkBlock`) |
| 0x48 "The World Servers are down for maintenance." | `bLoginAble != 1` | `tUserAuth.bIsLoginAble` of the account's `nAuthID` group is not 1 (group login policy; nAuthID 1 member, 2 closed beta, 3 test, 9 admin per the header). Also the EGPal password case (`nUserNo = 0`, `bLoginAble = 0`): a private/publisher edit |
| (DB failure) | `nError = 0x43` | the 0x43 code itself is not used by Login: with `nUserNo = -1` the client sees 0x45 (Login checks `nUserNo` first, login-server.md §5.1) |

The region flag 0x51 comes from AccountLog (§4.3).

```pseudo
0x0C07 NC_USER_PASSWORD_CHECK_REQ, 0x0C39 NC_USER_GER_PASSWORD_CHECK_REQ, 0x0C53 NC_USER_CH_PASSWORD_CHECK_REQ
   { u16 clienthandle @0, Name256Byte user @2, Name4 password @0x102 }   (0x112)
                                                   @ FUN_004039c0 / FUN_00403b20 / FUN_00403c80 (identical bodies)
    ack (raw frame, PROTO_NC_USER_*PASSWORD_CHECK_ACK 0x11f bytes, opcode 0x0C08 / 0x0C3A / 0x0C54):
        clienthandle; id[256] = req.user; password[16] = 0
    userNo = usp_User_loginGame(user[256], password[16] + NUL, &authid, &block, &loginable)   @ FUN_00418dd0
    if userNo == -1: ack.password = req.password            # the typed password is echoed only on failure
    ack.usrregnum = userNo; ack.authid; ack.block; ack.loginable
    SendRaw(frame = { 0x21, op, ack }, 0x122)               # length byte 0x21 = (u8)0x121 (original bug) D01-B1

usp_User_loginGame:                                        @ FUN_00418dd0   "CSQLPAccount::p_UserLoginGame"
    {CALL usp_User_loginGame(?,?,?,?,?,?)}  1 in WVARCHAR id(256)  2 in WVARCHAR pw(16)  3 out INTEGER userNo (init -1)
                                            4 out TINYINT authID  5 out ulong block  6 out INTEGER isLoginable
    rc ∉ {0,1}: log "ERROR - CSQLPAccount::p_UserLoginGame5, ret(%d), UserNo(%d)" + SQLError; userNo stays -1
    return userNo
```

`usp_User_loginGame` (Account.bak, Ko Dong Gyun 2007) *(db-backup)*: the same as `usp_User_USloginGame` without the e-mail
retry, the EGPal and merge additions: no row → `-1`, blocked → `usp_User_chkBlock`. The Login parser for 0x0C08 / 0x0C3A /
0x0C54 exists (login-server.md §5.1) but the 2016 client cannot start these flows (it only sends 0x0C5A / 0x0C37).

```pseudo
0x0C1E NC_USER_LOGIN_NETMARBLE_DB_REQ { u16 clienthandle @0, uchar UniID[20] @2, uchar UserID[256] @0x16 } (pdb2017 names)
                                                            @ FUN_00403720
    ack as 0x0C08 above: id = req.UniID (copied first), then overwritten with req.UserID
    userNo = usp_User_LoginNetmarble(UniID, &authid, &block, &loginable)          @ FUN_00419010
        {CALL usp_User_LoginNetmarble(?,?,?,?,?)}  1 in WVARCHAR UniID (buffer length 0x100 for a 20-byte field)
                                                   2 out ulong userNo (init -1)  3 out TINYINT  4 out ulong  5 out ulong
        (procedure missing from every backup)
    if userNo == -1: ack.password = ""
    SendRaw({0x21, 0x0C08, ack}, 0x122)                     # same truncated length byte (original bug) D01-B1
    # replies with 0x0C08, not a Netmarble-specific ACK; Login has no 0x0C1E path from the 2016 client

0x0C3E NC_USER_TW_PASSWORD_CHECK_REQ { u16 clienthandle @0, char sUserName[36] @2, char sSerial[36] @0x26,
                                       char sUID[20] @0x4a, char sSID[8] @0x5e }   (0x66, pdb2017 names)   @ FUN_00402d40
    a = { sUserName (32), sSerial (32), sUID (16), sSID (6) }
    if !usp_User_LoginGame5(a):                            @ FUN_00419440
        nError = 0x44; nUserNo = -1
    else:
        nUserNo = atol(sUID); nError = 0x41
        b = { userNo = nUserNo, userName = sUserName (0x32), nRet }
        if !usp_TWUser_insert(b):                          @ FUN_00419580
            log "Error - CPFsAccount::fc_NC_USER_TW_PASSWORD_CHECK_REQ : UserNo %d"; nError = 0x46
            dbUserNo stays -1
        else: dbUserNo = ULONG column 1 of the last row (while DB_Fetch: DB_GetULong); close cursor
        if dbUserNo != nUserNo: log "… UserNo %d, %d"; nError = 0x46
    SendRaw({10, 0x0C3F, { clienthandle, u16 nError, u32 nUserNo }}, 0xb)

usp_User_LoginGame5 (this is the 5-parameter call of the plan):   @ FUN_00419440
    {CALL usp_User_LoginGame(?,?,?,?,?)}  1 in WVARCHAR name(32)  2 in WVARCHAR serial(32)  3 in WVARCHAR uid(16)
                                          4 in WVARCHAR sid(6)    5 out INTEGER nRet;  ok = rc ∈ {0,1} and nRet == 0
    log "ERROR - CSQLPAccount::usp_UserTWLoginGame, ret(%d), nRet(%d)"
    # only the Taiwan path uses it. Against Account.bak it calls the 6-parameter usp_User_loginGame (names are not
    # case-sensitive) with the wrong arguments and fails → every TW login gets 0x44 *(db-backup)*
usp_TWUser_insert:  {CALL usp_TWUser_insert(?,?,?)}  1 in SLONG userNo  2 in WVARCHAR name(0x32)  3 out SLONG nRet   @ FUN_00419580
                    returns a result set with the user number (procedure missing from every backup)

0x0C4B NC_USER_JP_PASSWORD_CHECK_REQ { u16 clienthandle @0, char sUserName[24] @2, char sPassword[36] @0x1a,
                                       char sChannel[254] @0x3e, char sUserIP[20] @0x13c }   (0x150, pdb2017)   @ FUN_00403e10
    ack = 0x0C4C NC_USER_JP_PASSWORD_CHECK_ACK (CSendPacket 0x132) { clienthandle, u16 nError = 0x41, u32 nUserNo = -1,
          sUserName[24], sChannel[254], sUserIP[20] }   (copies of the request)
    hash = MD5hex("SO002|" sChannel "|" sUserIP "|" sUserName "|" sPassword "|785B3E33F1C84C2")[0:32]   @ FUN_0040baf0
          (MD5 identified by its init constant 0x67452301, inferred)
    http = HttpClient()                                    @ FUN_00412960
    if !http.Init():                                        nError = 0x5e
    else:
        http.port = 80; host "auth.gamescampus.co.jp"; path "UserAuthentication.asp"
        params: gameid=SO002, userid=sUserName, userpassword=sPassword, useripaddress=sUserIP,
                requestid=sChannel, hashvalue=hash
        if !http.Request():                                  nError = 0x5f
        else: parse the XML answer (TinyXML):  <…>/AuthenticationInfo/result
            result starts with "SUCCESS"                     → nError = 0x41
            else resultcode -1…-9 → 0x53…0x5b, -99 → 0x5c, other / missing node → 0x5d
    if nError == 0x41:
        if !usp_JPUser_insert({ sUserName(24), sUserIP(30), sChannel(254) }):  nError = 0x5d     @ FUN_00419690
        else: nUserNo = ULONG column 1 of the last row      # uninitialised if no row (original bug) D01-B6
    SendPacket(ack)
usp_JPUser_insert: {CALL usp_JPUser_insert(?,?,?,?)}  1 WVARCHAR(0x14)  2 WVARCHAR(0x1e)  3 WVARCHAR(0xfa)  4 out SLONG nRet;
                   ok = rc ∈ {0,1} and nRet == 0;  log "ERROR - CSQLPAccount::usp_UserJPLoginGame, ret(%d), nRet(%d)"
```

Codes 0x53–0x5f have no entry in the 2016 client's error table (Japanese service only).

### 3.3 Return-user ("comeback") checks, for the WM

```pseudo
0x0C60 NC_USER_RETURN_CHECK_REQ { u16 nHandle @0, u32 nUserNo @2 }:     @ FUN_00403220
    ack 0x0C61 NC_USER_RETURN_CHECK_ACK { u16 nHandle, u32 nUserNo, u8 bReturnUser = 0, i32 tLastSec = 0 }  (0xb)
    if usp_ReturnUser_GetDatediffLastlog(nUserNo):          @ FUN_00419a70
        if a row: tLastSec = SLONG col 1; bReturnUser = 1
    else: log "Error - CPFsAccount::fc_NC_USER_RETURN_CHECK_REQ usp_ReturnUser_GetDatediffLastlog: UserNo %d"
    if bReturnUser == 0:
        if usp_User_GetDatediffCreated(nUserNo) and a row:  tLastSec = SLONG col 1   @ FUN_00419950
        elif failed: log "… usp_User_GetDatediffCreated: UserNo %d"
    if tLastSec == 0: log "Error - CPFsAccount::fc_NC_USER_RETURN_CHECK_REQ : UserNo %d"
    SendPacket(ack)
    # WM reads bReturnUser = "has comeback history" and tLastSec (W01-core.md §3.3)

0x0C64 NC_USER_SET_RETURN_CMD { u32 nUserNo }:              @ FUN_00403480
    if !usp_ReturnUser_SetUserItem(nUserNo): log "… usp_ReturnUser_SetUserItem: UserNo %d"   @ FUN_004199e0
    (no reply)
```

All three wrappers: `{CALL proc(?,?)}` 1 in SLONG nUserNo, 2 out SLONG @nRet (init 0); ok = rc ∈ {0,1} and nRet == 0.
Procedures (Account.bak, JK CHO 2014-02-10) *(db-backup)*:
- `usp_ReturnUser_GetDatediffLastlog`: `SELECT TOP 1 DATEDIFF(s, dDate, getdate()) FROM tReturnUser WHERE nUserNo = @nUserNo
  ORDER BY dDate DESC` (seconds since the last comeback reward).
- `usp_User_GetDatediffCreated` (2 identical versions): `SELECT DATEDIFF(s, dDate, getdate()) FROM tUser WHERE nUserNo = …`
  (seconds since account creation).
- `usp_ReturnUser_SetUserItem`: `EXEC usp_Charge_ItemInsert @nUserNo, 0, 30001, 1, @RET OUTPUT`; on `@RET = 1` inserts
  `tReturnUser (dDate, nUserNo, nItemNo = 30001)`, else rollback and `@nRet = -1`. So the comeback gift is charge item 30001.

### 3.4 Web key, PC-bang, events, teen protection

```pseudo
0x081D NC_MISC_WEB_DB_KEY_REQ { u16 nWorldSessionHandle @0, u32 nUserNo @2 }:     @ FUN_00403830
    g_WebKeyCounter (DAT_00655bdc) = (g_WebKeyCounter + 1) & 0x7ffffff        # before CheckAlive; no lock (D01-B9)
    ack 0x081E NC_MISC_WEB_DB_KEY_ACK (0x28) { u16 Error = 0x1110, u16 nWorldSessionHandle, u32 nUserNo, uchar WebKey[32] }
    if usp_Item_setSerialKey(userNo = nUserNo, serialKey = g_WebKeyCounter):      @ FUN_004190d0
        t = timeGetTime() & 0x7ffffff
        WebKey = sprintf("%09u%09u%09u", t, (t + nUserNo) ^ 0x5aaa7a, (t + counter) ^ 0x7aaa5a)   # 27 chars + NUL
    else:
        Error = 0x1111; log "Error - fc_NC_MISC_WEB_DB_KEY_REQ, UserNo=%d, DBError=%d"
    SendPacket(ack)
usp_Item_setSerialKey: {CALL usp_Item_setSerialKey(?,?,?)} 1 in ulong userNo, 2 in ulong serialKey, 3 out SLONG @RET (init 0); ok = @RET == 1
    procedure (Account.bak, Ko Dong Gyun 2006-06-17, "serial key for item-mall authentication") *(db-backup)*:
    userNo or key 0 → RETURN -1 (@RET 0); user exists and not deleted → replace tSerialKey(userNo, serialKey), @RET = 1
    # the web side can recover the counter from WebKey: ((third ^ 0x7aaa5a) - first) (inferred)

0x082F NC_MISC_CONNECTFROMWHERE_DB_REQ (the plan's name NC_MISC_SERVERPARAMETER_REQ is the PDB alias of this value;
       the 2016 payload is CONNECTFROMWHERE_DB_REQ, docs/knowledge/C02.md §2)
   { u16 hZone @0, NETPACKETZONEHEADER { u16 clienthandle @2, u32 charregistnumber @4 }, uchar connectip[4] @8 }   @ FUN_00402ba0
    ip = sprintf("%d.%d.%d.%d", connectip)
    connectfrom = 0
    if !usp_Pcbang_chkIP(ip, &connectfrom): log "ERROR - usp_Pcbang_chkIP, IP=%s, nCharNo=%d"; connectfrom = 0   @ FUN_00419b00
    SendRaw({0x0b, 0x0830, { u16 hZone, u16 clienthandle, u32 charregistnumber, u8 connectfrom }}, 0xc)
        # 0x0830 NC_MISC_CONNECTFROMWHERE_DB_ACK (9 B), WM turns it into 0x082B for the zone (W01-core.md)
usp_Pcbang_chkIP: if strlen(ip) < 3: return ok with 0 (never: "%d.%d.%d.%d" is ≥ 7 chars)
                  {CALL usp_Pcbang_chkIP(?,?)} 1 in WVARCHAR ip(0x1e), 2 out SLONG @RET → connectfrom = (u8)@RET
                  (procedure missing from every backup; meaning "PC-bang IP → nonzero", inferred from the name)

0x0820 NC_MISC_EVENT_HIT3_ADD_CASH { uchar UserID[20] @0, u64 AddCash @0x14 }:     @ FUN_00402530
    ok = usp_Event_addCash(UserID, AddCash)                @ FUN_00419160
        {CALL usp_Event_addCash(?,?,?)} 1 in WVARCHAR(0x14), 2 in SQL_C_UBIGINT/BIGINT, 3 out SLONG @RET; ok = @RET == 1
    if !ok: log "Error - fc_NC_MISC_EVENT_HIT3_ADD_CASH, UserID=%s, AddCash=%I64d"
    log "OK - fc_NC_MISC_EVENT_HIT3_ADD_CASH, …"           # logged also after an error (original bug) D01-B5
    (no reply; procedure missing from every backup)

0x0838 NC_MISC_EVENT_DONE_MUNSANG_WM2ACC { u32 nUserNo, u32 nCharNo, u8 nWorldNo, u16 hZone, u16 nQuestID }:   @ FUN_00402cb0
    SendRaw({0x11, 0x0839, { nUserNo, nCharNo, nWorldNo, u16 nError = 0x1545, hZone, nQuestID }}, 0x12)
        # 0x0839 NC_MISC_EVENT_DONE_MUNSANG_ACC2WM (pdb2017 layout matches). No DB access: the event is answered with the
        # fixed code 0x1545 (meaning unknown; probably "event not running", inferred)

0x0C26 NC_USER_TEENAGER_REQ { Name256Byte sUserID @0, u16 nHandle @0x100 }:          @ FUN_00402610
    ack 0x0C27 NC_USER_TEENAGER_ACK (0x139) { sUserID, nHandle, Data { uchar sUserKey[50] = 0, u8 nType, u32 nMinute } }
    k = { sUserID (20) }
    if !p_UserKey_Get_FromAccount(k):                       @ FUN_00419200
        log ", p_UserKey_Get_FromAccount, sUserID=%s, DB ERROR, Check GAMECOMMONDB Linked Server."; nType = 3
    else:
        sUserKey = k.userKey
        born = mktime(k.birth.year, month, day)
        if born < mktime(today − 18 years + 1 day):   nType = 2              # adult
        else:                                                                 # under 18
            r = { userKey }
            if !p_UserPlayRemainTime_Get_FromAccount(r):    @ FUN_004192c0
                if r.nRet == 1: nType = 0; nMinute = 180                     # no record yet: full 3 hours
                else: log ", p_UserPlayRemainTime_Get_FromAccount, … DB ERROR …"; nType = 3
            else:
                elapsed = difftime(now, mktime(r.lastTime))   # lastTime = y/m/d h:m
                if elapsed >= 17940.0 (DAT_00432960, 4 h 59 min):  nType = 0; nMinute = 180     # window over: reset
                elif r.remain < 1:  nType = 1; nMinute = ftol(…) / 60       # time used up; value = minutes left in
                                                                             # the window (inferred, FPU operand not traced)
                else:               nType = 0; nMinute = r.remain
    SendPacket(ack)
    # Login (login-server.md §5.1, 0x0C27): nType 1 → refuse with 0x4E; 3 → warning, treated as 2; else log in.
    # The 2016 Login never sends 0x0C26 from the client path (no client packet starts it).

0x0C28 NC_USER_TEENAGER_SET_CMD { uchar sUserKey[50] @0, u32 nUserPlayRemainTime @0x32 }:   @ FUN_00402a40
    r.userKey = strcpy(sUserKey)                          # unbounded copy (original bug) D01-B7
    r.lastTime = now (year, month, day, hour, minute; seconds 0)
    r.remain = nUserPlayRemainTime
    if !p_UserPlayRemainTime_Set_FromAccount(r):          @ FUN_00419380
        log "_SET, p_UserPlayRemainTime_Set_FromAccount, sUserKey=%s, nUserPlayRemainTime=%d, DB ERROR, …"
```

Teen-protection procedures (all missing from every backup; "GAMECOMMONDB Linked Server" in the log text):

| Wrapper | `{CALL}` | Parameters (binary) | ok when |
|---|---|---|---|
| `@ FUN_00419200` | `p_UserKey_Get_FromAccount(?,?,?,?)` | in WVARCHAR userID(0x14), **out** WVARCHAR userKey(0x19), out TIMESTAMP birth, out ulong nRet (init 1) | nRet == 0 |
| `@ FUN_004192c0` | `p_UserPlayRemainTime_Get_FromAccount(?,?,?,?)` | in WVARCHAR userKey(0x19), out TIMESTAMP lastTime, out ulong remain, out ulong nRet (init 2) | nRet == 0 (1 = no row) |
| `@ FUN_00419380` | `p_UserPlayRemainTime_Set_FromAccount(?,?,?,?)` | in WVARCHAR userKey(0x19), in TIMESTAMP lastTime, in ulong remain, out ulong nRet (init 2) | nRet == 0 |

---

## 4. AccountLog server (CParserAccountLog)

Peers: Login (login logs, IP block checks, syslog lines), WM (statistics, events, reports, logout day). All handlers run
`CheckAlive` first (`AL:FUN_00403f80`).

### 4.1 Account log (`p_AccountLog_Add` → `tAccountLog`)

```pseudo
AccountLogAdd(l):                                        @ AL:FUN_00414a30
    {CALL p_AccountLog_Add(?,?,?,?,?,?,?,?,?)}
      1 TINYINT nType  2 SLONG nUserNo  3 TINYINT nWorldNo  4 SSHORT nPlayMin  5 USHORT nErrorCode
      6 VARCHAR sIP(16)  7 WVARCHAR sUserID(16)  8 WVARCHAR sUserPassword(16)  9 out UBIGINT nLogNo
    on error (rc ∉ {0, 1}): p_AccountLog_TextLogWrite(" nType, nUserNo, nWorldNo, nPlayMin, nErrorCode, sIP, sUserID,
        sUserPassword, nLogNo")   @ AL:FUN_00414930
        # appends "YYYY-MM-DD hh:mm:ss> <line>" to AccountLog_<YYYY-MM-DD>.txt (fopen "a+", working directory)
    no reply in any case

0x0720 NC_LOG_USER_LOGINFAIL { Name256Byte userid @0, Name4 userpassword @0x100, uchar userip[4] @0x110,
                               u16 error @0x114 }   (0x116, pdb2017 names):     @ AL:FUN_00402470
    AccountLogAdd(nType 0, userNo 0, world 0, playMin 0, error, ip = "%d.%d.%d.%d", userid, userpassword)
    # the 16 bytes Login copies "from reply +0x10C" (login-server.md §5.1) are the password field: sPassword of
    # 0x0C5C, i.e. failed logins store the typed password in tAccountLog.sUserPassword (db-backup column)

0x0721 NC_LOG_USER_LOGIN { u32 usrregnum, u8 worldnum, uchar ip[4] }:      @ AL:FUN_00402580
    AccountLogAdd(nType 1, usrregnum, worldnum, 0, 0, ip, "", "")           # Login sends it on world select

0x0722 NC_LOG_USER_LOGOUT { u32 usrregnum, u8 worldnum, u16 playmin @5, u16 error @7 }:   @ AL:FUN_00402640
    AccountLogAdd(nType 2, usrregnum, worldnum, playmin, error, "", "", "")
```

`p_AccountLog_Add` (AccountLog.bak) *(db-backup)*: `INSERT tAccountLog (nType, nUserNo, nWorldNo, nPlayMin, nErrorCode, sIP,
sUserID, sUserPassword)`, `@nLogNo = @@IDENTITY`. `sUserID nvarchar(16)` cuts longer IDs.

### 4.2 Statistics, events

```pseudo
0x080A NC_MISC_CONNECTER_ACK { u8 worldno @0, u16 connectercount @1, u16 nEachClass[64] @3 }  (0x83, WM every interval):
                                                         @ AL:FUN_004026f0
    idx = p_SameTimeChar_Add(world, count)  on the Statistics DB          @ AL:FUN_00415540
          {CALL p_SameTimeChar_Add(?,?,?)} 1 TINYINT nWorld  2 ulong nCount  3 out ulong nIndex
    for c in 0..63 where nEachClass[c] != 0:
        p_SameTimeCharClass_Add(idx, (u8)c, nEachClass[c])                 @ AL:FUN_004155c0
          {CALL p_SameTimeCharClass_Add(?,?,?,?)} 1 ulong index  2 TINYINT class  3 ulong count  4 out ulong nRet; ok nRet == 0
          (procedure missing from every backup; log "CSQLPStatistics::p_SameTimeCharClass_Add")
    # idx is used even when the first call failed (idx = 0) (original bug) D01-B8
p_SameTimeChar_Add (StatisticsData.bak, 2005) *(db-backup)*: INSERT tSameTimeChar (nWorld, nCount); @nIndex = @@IDENTITY

0x081F NC_MISC_CHAR_LOGOFF_STATISTICS { u8 WorldNo, u32 UserNo @1, u32 CharNo @5, u8 CharClass @9, u8 CharLevel @0xa,
                                        u64 CharGetExp @0xb, u16 CharPlayMin @0x13 }  (0x15):   @ AL:FUN_00402990
    if !usp_Log_setLogout(...): log "ERROR - fc_NC_MISC_CHAR_LOGOFF_STATISTICS, WorldNo=%d, UserNo=%d, …"   @ AL:FUN_00414be0
    {CALL usp_Log_setLogout(?,?,?,?,?,?,?,?)} TINYINT world, SLONG user, SLONG char, TINYINT class, USHORT level,
                                              SBIGINT exp, SSHORT playMin, out SLONG @RET; ok @RET == 1
    procedure (AccountLog.bak) *(db-backup)*: INSERT tLogout (worldNo, userNo, charNo, class, level, experience, playTime)

0x0843 NC_MISC_EVENT_LONG_TIME_PLAY_CMD { u32 nUserNo, u16 nPlayTime }:    @ AL:FUN_004030d0
    usp_EventiPad_setTicket(nUserNo, nPlayTime)            @ AL:FUN_00414e30  "CSQLPAccountLog::p_Set_Event_Long_Time_Play"
        {CALL usp_EventiPad_setTicket(?,?,?)} 1 SLONG  2 SLONG  3 out SLONG nRet; logs on rc error or nRet != 0; no reply
    procedure (AccountLog.bak, Ko Dong Gyun 2010-04-26) *(db-backup)*: playTime < 60 → nRet -1; tickets = playTime / 60,
    added to tEventiPad.nTicket (insert or update; -7 / -8 on error). WM sends it when a session played ≥ 60 min (W01)

0x082C NC_MISC_EVENT_L20_DB_REQ { u16 nWMHandle @0, Name256Byte sUserID @2, u32 nUserNo @0x102, u8 nEventNo @0x106,
                                  u8 nWorldNo @0x107, u32 nCharNo @0x108, u32 nEventPoint @0x10c }  (0x110):   @ AL:FUN_00402aa0
    ack 0x082D NC_MISC_EVENT_L20_DB_ACK { u16 nWMHandle, u32 nUserNo, u8 nEventNo, u32 nCharNo, u16 nError = 0x1288 }
    q = { nUserNo, nEventNo }                              # q.nRet is NOT initialised (original bug) D01-B10
    if p_Event_L20_Get(q):  nError = 0x1289                # nRet > 0: already has the reward (inferred)
    elif q.nRet == -1:      log "ERROR - fc_NC_MISC_EVENT_L20_DB_REQ, GetEventL20,…"; nError = 0x128a
    else:
        q.nWorldNo, q.nCharNo, q.nEventPoint = req…
        if p_Event_L20_Set(q):  nError = 0x1288            # granted
        else:                   nError = 0x128b; log "…SetEventL20,…, nRet=%d" when nRet ∉ {1, 3}
    SendRaw({0x0f, 0x082D, ack}, 0x10)
p_Event_L20_Get: {CALL p_Event_L20_Get(?,?,?,?,?,?)} 1 in ulong userNo  2 in UTINYINT eventNo  3 out UTINYINT  4 out ulong
                 5 out TIMESTAMP  6 out ulong nRet; ok = rc ∈ {0,1} and nRet > 0          @ AL:FUN_00415360
p_Event_L20_Set: same shape, all in (userNo, eventNo, worldNo, charNo, eventPoint) + out nRet; ok nRet == 0   @ AL:FUN_00415450
                 (both procedures missing from every backup; code meanings inferred from the branch structure)

0x0835 NC_MISC_HACK_SCAN_STORE_DB_CMD (pdb2017: { u32 nUserNo, u8 nWorldNo, u32 nCharNo, char sIP[20], Name5 sCharID,
       { u16 nDescSize, sDesc[] } }):   CheckAlive only, nothing stored                    @ AL:FUN_00402d40
```

### 4.3 IP block checks (the source of Login's 0x51)

```pseudo
IsBlock(userNo, ip):                                     @ AL:FUN_00414d00 (US variant AL:FUN_00414d90 also logs the SQLError)
    {CALL p_IPBlock_IsBlock(?,?,?)} 1 in SLONG nUserNo  2 in VARCHAR sIP(0x14)  3 out TINYINT bIsBlock
    ok = rc ∈ {0,1}

0x0C5D NC_USER_US_IS_IP_BLOCK_REQ { US_PASSWORD_CHECK_ACK LoginData @0 (0x161), u32 nUserNo @0x161,
                                    u16 nClientHandle @0x165, char sUserIP[20] @0x167 }  (0x17b):   @ AL:FUN_004038d0
    ack 0x0C5E NC_USER_US_IS_IP_BLOCK_ACK (CSendPacket 0x164) { LoginData (copied), u16 nClientHandle, u8 bUserIPBlock = 0 }
    if IsBlock(nUserNo, sUserIP, &b): ack.bUserIPBlock = b
    SendPacket(ack)                                       # DB error → 0 = not blocked (fail-open)

0x0C2A NC_USER_IS_IP_BLOCK_REQ { LOGIN_REQ LoginData (0x110), u32 nUserNo @0x110, u16 nClientHandle @0x114,
                                 char sUserIP[20] @0x116 }:   → SendRaw({0x15, 0x0C2B, { LoginData, nClientHandle,
                                 bUserIPBlock }}, 0x116)          # 0x15 = (u8)0x115 (original bug) D01-B2   @ AL:FUN_00403bb0
0x0C3B NC_USER_GER_IS_IP_BLOCK_REQ { GER_PASSWORD_CHECK_ACK LoginData (0x11f), nUserNo @0x11f, nClientHandle @0x123,
                                     sUserIP @0x125 }:   → SendRaw({0x24, 0x0C3C, …}, 0x125)   # (u8)0x124 D01-B2   @ AL:FUN_00403cc0
0x0C40 NC_USER_TW_IS_IP_BLOCK_REQ { TW_PASSWORD_CHECK_ACK LoginData (8), nUserNo @8, nClientHandle @0xc, sUserIP @0xe }:
                                     → SendRaw({0x0d, 0x0C41, { LoginData, nClientHandle, bUserIPBlock }}, 0xe)   @ AL:FUN_00402e00
0x0C4D NC_USER_JP_IS_IP_BLOCK_REQ { JP_PASSWORD_CHECK_ACK LoginData (0x132), nUserNo @0x132, nClientHandle @0x136,
                                    sUserIP @0x138 }:   → SendPacket 0x0C4E (0x135) { LoginData, nClientHandle, bUserIPBlock }   @ AL:FUN_00402ec0
```

All five variants have the same logic; the ACK is the request's LoginData followed by the handle and the flag (pdb2017
layouts agree with every offset read in the code).

`p_IPBlock_IsBlock` (AccountLog.bak copy, no header author) *(db-backup)*:

```sql
SET @bIsBlock = 0
IF EXISTS(SELECT sIPStart FROM tIPBlock WHERE @sIP >= sIPStart AND @sIP <= sIPEnd)
    IF NOT EXISTS(SELECT TOP 1 nLogNo FROM tAccountLog WHERE nUserNo = @nUserNo AND nType = 1)
        SET @bIsBlock = 1
```

So **Login error 0x51 "You are not in our service area."** = the client IP lies in a `tIPBlock` range (string comparison;
Login formats the IP as `"%03d.%03d.%03d.%03d"`, which keeps the string order equal to the numeric order) **and** the account
has never selected a world (`tAccountLog` has no `nType = 1` row, written by 0x0721). Accounts that have played before
are exempt. `Fixes/IP Block/p_IPBlock_IsBlock.sql` ("Fixed by Gherblino", 2018) is a private-server edit: it strips the
zero padding with `PARSENAME` and then sets `@bIsBlock = 1` for every IP in a range, without the exemption.

### 4.4 Logout day, user reports

```pseudo
0x0C62 NC_USER_LOGOUT_LAST_DAY_REQ { u16 nHandle, u32 nUserNo }:        @ AL:FUN_004035e0
    ack 0x0C63 NC_USER_LOGOUT_LAST_DAY_ACK (CSendPacket 10) { u16 nHandle, u32 nUserNo, i32 tLastSec = 0 }
    if usp_AccountLog_GetDateDiffLastlogout(nUserNo):       @ AL:FUN_00415020  ({CALL …(?,?)} in SLONG, out SLONG nRet; ok nRet == 0)
        if a row: tLastSec = SLONG col 1
    else: log "ERROR - CPFsAccountLog::fc_NC_USER_LOGOUT_LAST_DAY_REQ usp_AccountLog_GetDateDiffLastlogout nUserNo = %d"
    if tLastSec == 0: log "Error - CPFsAccountLog::fc_NC_USER_LOGOUT_LAST_DAY_REQ : UserNo %d"
    SendPacket(ack)
    # procedure missing from every backup; by analogy with §3.3 it returns seconds since the last tAccountLog logout (inferred)

0x8007 NC_DATA_REPORT_ADD_REQ { u32 dwReporter @0, u16 hReporter @4, u8 nWorldNo @6, Name5 sReporterCharID @7,
                                Name5 sHarmer @0x1b, uchar byReportType[16] @0x2f, uchar byReason[256] @0x3f,
                                u16 nChatLogSize @0x13f, uchar byChatLog[2048] @0x141 }  (pdb2017 names):   @ AL:FUN_00403a00
    r = { reporter, reporterCharID (20), harmer (20), worldNo, reportType (16), reason (256),
          chatLog = byChatLog[min(nChatLogSize, 0x800)] }
    if !p_Report_Add(r):            err = 0xf58            # DB error           @ AL:FUN_004150c0
    elif r.nReportRegNo == -2:      err = 0xf41            # client: "Reporting same character is resticted to once a day."
    elif r.nReportRegNo == -1:      err = 0xf42            # client: "Reporting is restricted to once an hour."
    elif r.nReportRegNo != 0:       err = 0xf40            # OK
    else:                           err = 0xf58            # client: "Failed to report. (DB Error)"
    SendRaw({0x1e, 0x8008, { u16 err, u16 hReporter, Name5 sHarmer, i32 nRegNumber }}, 0x1f)   # NC_DATA_REPORT_ADD_ACK
p_Report_Add: {CALL p_Report_Add(?,?,?,?,?,?,?,?)} ulong reporter, WVARCHAR(0x14) ×2, UTINYINT world, WVARCHAR(0x10) type,
              WVARCHAR(0x100) reason, WLONGVARCHAR chatLog (length = chat size, read as a NUL-terminated string),
              out ulong nReportRegNo
    procedure (AccountLog.bak, lenasoft 2006-03-06) *(db-backup)*: reporter already reported in this world within 1 hour → -1;
    same harmer within 1 day → -2; else INSERT tReport (sReportType, nReporter, sReporterCharID, sHarmer, nWorldNo, sReason,
    sChatLog), @@IDENTITY (0 on error)

0x8009 NC_DATA_REPORT_CANCEL_REQ { i32 nRegNumber, u16 hReporter }:     @ AL:FUN_004027b0
    p_Report_Del(nRegNumber, &nRet)                          @ AL:FUN_004151f0   (in ulong, out USHORT)
    err = DB fail → 0xf58; nRet 0 → 0xf40 (deleted), 1 → 0xf50, 2 → 0xf51, 3 → 0xf52, other → 0xf58
    SendRaw({10, 0x800A, { i32 nRegNumber, u16 hReporter, u16 err }}, 0xb)       # NC_DATA_REPORT_CANCEL_ACK
    procedure (lenasoft 2006-03-07) *(db-backup)*: 1 = unknown number, 2 = older than 1 hour, 3 = already processed
    (nResult ≠ 0); else DELETE

0x800B NC_DATA_REPORT_GET_REQ { u16 hReporter, u32 dwReporter, u8 nWorldNo }:   @ AL:FUN_004028a0
    ack { u16 hReporter, u16 err, i32 nRegNumber, u8 byReportResult, uchar byRemark[128] }   (0x89)
    rc = p_Report_Get(dwReporter, nWorldNo, &ack)           @ AL:FUN_00415270
          (in ulong, in UTINYINT; first row: nRegNumber SLONG, nResult, sRemark; returns 1 row / -1 no row / 0 DB error)
    err = rc 1 → 0xf40, 0 → 0xf58, -1 → 0xf60
    SendRaw({0x8b, 0x800C, ack}, 0x8c)                       # NC_DATA_REPORT_GET_ACK
    procedure (lenasoft) *(db-backup)*: SELECT nRegNumber, nResult, sRemark FROM tReport WHERE reporter/world, last hour
```

The WM forwards 0x8008 / 0x800A / 0x800C to the client as 0x8002 / 0x8004 / 0x8006 (W01-core.md, AccountLogDB report results). Client
`GameFrameWork::On_NC_REPORT_ADD_ACK` (`FUN_004ae700`) handles 0xf40 (success) and shows texts for 0xf41 (once a day), 0xf42
(once an hour), 0xf43 "Cannot report oneself.", 0xf44 "Please enter the reason for reporting.", 0xf45 "There is no
chatting log.", 0xf46 (text id 0xb6bfe821), 0xf58 "Failed to report. (DB Error)". The AccountLog only produces 0xf40/41/42/58.

### 4.5 Syslog lines (NC_SYSLOG_*)

```pseudo
SysLog(msg):                                             @ AL:FUN_00403150
    line = sprintf("%s %s %s %s %s - %s", "Mon d hh:mm:ss" (local), gethostname(), "YYYY-MM-DDThh:mm:ss.mmmZ" (UTC),
                   "ACCOUNTLOG", "ACCOUNTLOG", msg)
    queue line in the writer at DAT_0064fa90             @ AL:FUN_0040aa20   (consumer not traced)
        # = cLogSystem::ls_LogReservation on gServer.m_UK_SysLog (pdb2016); it pushes a std::string into a
        # cLS_Queue (lsq_Push @ AL:FUN_0040a870: chunked ring of blocks; when full it overwrites the last slot)

0xC801 NC_SYSLOG_ACCOUNT_LOGIN_SUCCESS { u32 UserNo @0, char UserIP[16] @4, Name5 spawnapps @0x14 }  (2016: 40 bytes):   @ AL:FUN_00403310
    SysLog("ACCOUNT_LOGIN_SUCCESS [fiesta@onson account-id=\"%d\" ipv4=\"%s\" client-version=\"%s\"]", UserNo, UserIP, spawnapps)
    # the 2017 struct (70 B) adds char UserID[30] at 0x14 (pdb2017); the 2016 AccountLog reads spawnapps at 0x14
0xC802 NC_SYSLOG_ACCOUNT_LOGIN_FAILURE { char UserName[260] @0, char UserIP[16] @0x104, Name5 spawnapps @0x114 }:   @ AL:FUN_004033d0
    SysLog("ACCOUNT_LOGIN_FAILURE [fiesta@onson login-name=\"%s\" ipv4=\"%s\" client-version=\"%s\"]", UserName[256], …)
0xC803 NC_SYSLOG_ACCOUNT_LOGOUT { u32 UserNo, u32 LoginKeepTime }:   SysLog("ACCOUNT_LOGOUT [… account-id=… in-game-minutes=…]")   @ AL:FUN_004034e0
0xC811 NC_SYSLOG_SERVER_CCU { u32 UserCount, u8 WorldNo }:   SysLog("SERVER_CCU [fiesta@onson number=\"%d\" world-name=\"%d\"]")   @ AL:FUN_00403560
```

"client-version" prints `spawnapps` as a string: the Name5 field carries the client version/launcher tag (inferred).

---

## 5. Procedures called, by server

| Server | Procedure | Params | Source used | Notes |
|---|---|---|---|---|
| account | usp_User_loginGame | 6 | Account.bak (KR) | legacy login variants |
| account | usp_User_USLoginGame | 6 | Account.bak (KR + Stu/John edits) | live login path 0x0C5B |
| account | usp_User_LoginGame | 5 | – | TW path; resolves to the 6-param procedure and fails against Account.bak |
| account | usp_User_LoginNetmarble | 5 | missing | |
| account | usp_TWUser_insert, usp_JPUser_insert | 3, 4 | missing | |
| account | usp_Item_setSerialKey | 3 | Account.bak (KR) | web key |
| account | usp_Event_addCash | 3 | missing | |
| account | usp_Pcbang_chkIP | 2 | missing | |
| account | usp_ReturnUser_GetDatediffLastlog, usp_ReturnUser_SetUserItem, usp_User_GetDatediffCreated | 2 | Account.bak (KR, JK CHO 2014) | |
| account | p_UserKey_Get_FromAccount, p_UserPlayRemainTime_Get/Set_FromAccount | 4 | missing (GAMECOMMONDB linked server) | teen protection |
| accountlog | p_AccountLog_Add | 9 | AccountLog.bak (KR) | |
| accountlog | p_IPBlock_IsBlock | 3 | AccountLog.bak (the Fixes/ copy is a 2018 private edit) | region block |
| accountlog | usp_Log_setLogout, usp_EventiPad_setTicket | 8, 3 | AccountLog.bak (KR) | |
| accountlog | p_Report_Add / Del / Get | 8, 2, 2 | AccountLog.bak (lenasoft 2006) | |
| accountlog | p_SameTimeChar_Add | 3 | StatisticsData.bak (KR) | Statistics DB |
| accountlog | p_SameTimeCharClass_Add, p_Event_L20_Get/Set, usp_AccountLog_GetDateDiffLastlogout | 4, 6, 6, 2 | missing | |

---

## 6. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D01-B1 | Account 0x0C07, 0x0C39, 0x0C53, 0x0C1E | the 0x0C08 / 0x0C3A / 0x0C54 reply is sent raw with length byte 0x21 = (u8)0x121 and 0x122 bytes | the peer reads a 33-byte packet and parses the remaining 256 bytes as further packets. The PDB `_SEND` struct has `uchar size`, so the original design could not hold the length | send through CSendPacket (`{0, u16 len}` framing) |
| D01-B2 | AccountLog 0x0C2A, 0x0C3B | raw replies 0x0C2B / 0x0C3C with length byte (u8)0x115 = 0x15 / (u8)0x124 = 0x24 | same mis-framing | CSendPacket framing |
| D01-B3 | Account 0x0C5B (`usp_User_USLoginGame` wrapper) | the `nRet` field (+0x138) is zeroed and tested but never bound to a parameter | dead check (the test never fails) | drop it, or bind a return value |
| D01-B4 | Account 0x0C3E | calls `usp_User_LoginGame` with 5 parameters; the DB (Account.bak) has only the 6-parameter `usp_User_loginGame` (same name for SQL Server) | every Taiwan login fails with 0x44 against this DB *(db-backup)* | a separate TW procedure name |
| D01-B5 | Account 0x0820 | logs "OK - fc_NC_MISC_EVENT_HIT3_ADD_CASH" after the error line too | misleading log | `else` branch |
| D01-B6 | Account 0x0C4B | `nUserNo` is taken from a stack variable filled only by SQLGetData; no row → uninitialised value with nError 0x41 | Login gets a garbage user number for a successful JP auth | initialise to -1 and fail without a row |
| D01-B7 | Account 0x0C28 | `sUserKey[50]` is copied with an unbounded byte loop (strcpy) | a key without NUL overruns the local struct | bounded copy |
| D01-B8 | AccountLog 0x080A | the `nIndex` of `p_SameTimeChar_Add` is used without checking the call | class rows are stored with index 0 when the first insert fails | skip the class rows on failure |
| D01-B9 | Account 0x081D | `g_WebKeyCounter` is incremented without a lock from several worker threads, and before CheckAlive | two requests can get the same serial key | atomic increment |
| D01-B10 | AccountLog 0x082C | `nRet` of `p_Event_L20_Get` is not initialised; after an SQL error the branch (0x128a vs. Set) depends on stack contents; the Set log condition `nRet != 1 && (nRet == 2 \|\| nRet != 3)` reduces to `nRet ∉ {1,3}` | undefined result code after DB errors | initialise nRet, test the rc |

## 7. Not reconstructed / uncertain

- Missing procedures (no source in any backup): `usp_User_LoginNetmarble`, `usp_JPUser_insert`, `usp_TWUser_insert`,
  `usp_Pcbang_chkIP`, `usp_Event_addCash`, `p_UserKey_Get_FromAccount`, `p_UserPlayRemainTime_Get/Set_FromAccount`,
  `p_Event_L20_Get/Set`, `p_SameTimeCharClass_Add`, `usp_AccountLog_GetDateDiffLastlogout`. Their parameters are from the
  binary only; their semantics (PC-bang flag, L20 codes 0x1288–0x128b, logout-day seconds) are inferred.
- `nUserNo == -2` (Login 0x4B) is not produced by any backup procedure; the original DB may have had an agreement check.
- The `usp_User_USloginGame` additions by "Stu" (EGPal password → userNo 0, which Login shows as 0x48) and "John"
  (`tUserMergeYet` HTTP check) are publisher/private edits of unknown date; the 2016 server may have run without them.
- TEENAGER nType 1: the value divided by 60 comes from an FPU expression not traced; "minutes until the 17940 s window
  ends" is a guess. Meaning of 17940 s (4 h 59 min) as the reset window is inferred.
- 0x0838 → 0x0839 nError 0x1545 and 0x081E Error 0x1110 / 0x1111, report codes 0xf50–0xf52 / 0xf60: no client text found
  (the client never sees most of them directly).
- 0x0804 handler `LAB_00404db0` was not decompiled (assumed to answer 0x0805 like the other servers).
- The syslog writer object at `DAT_0064fa90` (where the lines go: file, UDP, …) was not traced.
- Session-list and accept plumbing, service install, crash dumps, MapInfo/ItemInfo loading: framework, not detailed.
- Security notes (deliberate, not tagged as bugs): failed logins store the typed password in `tAccountLog.sUserPassword`;
  IP-block DB errors fail open (`bUserIPBlock = 0`).
