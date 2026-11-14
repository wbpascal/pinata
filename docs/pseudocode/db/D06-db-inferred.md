# Database behaviour the backups do not give us (D06)

The 2016 DB servers (Account, AccountLog, Character, GameLog) call stored procedures. D01–D05 document the servers and
take the procedure bodies from the private-server backups (`docs/plan/db-backups.md`). This document is the spec of what
a rebuild has to write itself: procedures without source anywhere, procedures whose parameter count differs from every
backup, run-time call strings, the open *(inferred)* / *(db-backup)* statements of D01–D05, and the table schema.

Code: `python3 -I tools/protocol-re/clean.py re-data/exports/<bin>-pdb - <addr>` (account / accountlog have a 2016 PDB;
character / gamelog: `re-data/exports/<bin>` with `tools/protocol-re/names/<bin>`). Procedure source:
`python3 -I tools/protocol-re/bak.py <backup> proc <name>`. Evidence markers as in `AGENTS.md`; names marked *(ours)* are
not from any binary, PDB or backup.

## 1. Conventions

### 1.1 How a procedure block reads

```
procedure_name(@p1 TYPE in, @p2 TYPE out, …)          ← signature a rebuild declares
    called by  : wrapper @ FUN_… (official wrapper name), handler @ FUN_… (D0x §)
    binds      : the SQLBindParameter list of the wrapper (direction, C type, SQL type, buffer length)
    result     : how the wrapper decides ok / failure; result rows the caller fetches (column order, C type)
    reads/writes: tables and columns (from the family procedures in the backups, else *(inferred)*)
    body       : pseudo-SQL of what the procedure must do so the 2016 caller behaves as designed
    evidence   : per statement
```

The signature types are the SQL types of the binds. Parameter names come from the 2016 PDB struct member the wrapper
binds (*(pdb2016)*), else from the family procedure in the backups, else *(ours)*.

### 1.2 ODBC codes in the binds

`SQLBindParameter(stmt, n, dir, cType, sqlType, columnSize, scale, buffer, bufferLength, indicator)` (ODBC32 ordinal 72).
Every wrapper passes `columnSize = 0`, `scale = 0` and a NULL indicator: input strings are NUL-terminated, output strings
are written into `bufferLength` bytes (including the NUL).

| Code | Direction | C type | SQL type |
|---|---|---|---|
| 1 | in | `SQL_C_CHAR` (narrow string) | – |
| 2 | in/out | – | – |
| 4 | out | – | – |
| −6 | – | `SQL_C_TINYINT` | `SQL_TINYINT` |
| −16 | – | `SQL_C_SLONG` | – |
| −18 | – | `SQL_C_ULONG` | – |
| −25 / −27 | – | `SQL_C_SBIGINT` / `SQL_C_UBIGINT` | – |
| −28 / −17 | – | `SQL_C_UTINYINT` / `SQL_C_USHORT` | – |
| −2 | – | `SQL_C_BINARY` | `SQL_BINARY` |
| 11 | – | `SQL_C_TIMESTAMP` (`TIMESTAMP_STRUCT`) | `SQL_TIMESTAMP` |
| 4 | – | – | `SQL_INTEGER` |
| −5 | – | – | `SQL_BIGINT` |
| −9 | – | – | `SQL_WVARCHAR` (the narrow C string is converted to nvarchar) |

`SQLExecDirect` (ordinal 11) returns `SQL_SUCCESS` 0 / `SQL_SUCCESS_WITH_INFO` 1; every wrapper treats exactly these two as
"executed". A procedure `RETURN` value is never bound (no `{? = CALL …}` anywhere in the four binaries): only output
parameters and result sets reach the server.

## 2. Account DB (`Account`, Account server)

Eight procedures the Account server calls have no source anywhere, and one call has a parameter count no backup matches.
All run on the one ODBC connection of the worker (`*this + 0x124c`); the teen-protection log lines say the procedures go
on to a linked server "GAMECOMMONDB", so they are relay procedures in `Account` *(inferred from the log text)*.

**Reachability in 2016.** The 2016 client only starts the 0x0C5A login (login-server.md §5.1), and no 2016 Login, WM or
Zone binary contains the opcodes 0x0C1E, 0x0C26, 0x0C28, 0x0C3E, 0x0C4B or 0x0820 as a send (searched in the exports'
`layouts.json` and as literals in `decomp.c`). So of the procedures below only `usp_Pcbang_chkIP` (WM 0x082F at every zone
login) is on a live path; the others serve region logins (Netmarble KR, Taiwan, Japan), the Korean teen-protection rule
and an event that no 2016 binary triggers. A rebuild for the 2016 service needs `usp_Pcbang_chkIP`; the rest only if it
keeps those region paths.

### 2.1 `usp_Pcbang_chkIP` — PC-bang (internet café) IP check

```pseudo
usp_Pcbang_chkIP(@sIP nvarchar(15) in, @nRet int out)          (names ours)
    called by : CSQLPIPChecker::usp_Pcbang_chkIP @ FUN_00419b00 (pdb2016) ← 0x082F NC_MISC_CONNECTFROMWHERE_DB_REQ
                @ FUN_00402ba0 (D01 §3.4), sent by the WM for every zone login (W01-core.md, WM FUN_0042b740)
    binds     : 1 in SQL_C_CHAR → WVARCHAR, buffer 0x1e; 2 out SQL_C_SLONG → INTEGER (local initialised 0)
    result    : connectfrom = (u8) @nRet, also on failure; rc ∉ {0,1} → the handler logs
                "ERROR - usp_Pcbang_chkIP, IP=%s, nCharNo=%d" and answers 0x0830 with connectfrom 0
                (strings shorter than 3 characters skip the call: never, the IP is "%d.%d.%d.%d")
    body (inferred):
        SET @nRet = 0
        IF the dotted IP lies in a registered PC-bang range: SET @nRet = 1
    consumers : WM 0x0830 → zone 0x082B → ShinePlayer.connectFrom (+0x2a7d4, Z01 §9). The only reader found is the mob drop
                roll: connectFrom == 1 adds 200 to the map drop rate (Z09-world.md, `so_ply_GetFromWhere` FUN_0043c9d0).
                Other values have no effect in the 2016 zone.
```

- Tables: none of the backups has a PC-bang table or IP range table in `Account` (`bak.py names`; the only IP table is
  AccountLog's `tIPBlock`, D01 §4.3). A rebuild needs its own table *(ours: `tPcbangIP(sStartIP, sEndIP)`)*, or a
  procedure that always answers 0 (no PC-bang bonus), which is what an empty table gives.
- The value 1 = "connected from a PC-bang" is inferred from the procedure name and the single zone test `== 1`.

### 2.2 `usp_Event_addCash` — event cash for an account ID

```pseudo
usp_Event_addCash(@userID nvarchar(20) in, @cash bigint in, @RET int out)     (@userID, @RET ours; @cash from the log)
    called by : CSQLPAccount::usp_Event_addCash @ FUN_00419160 ← 0x0820 NC_MISC_EVENT_HIT3_ADD_CASH @ FUN_00402530 (D01 §3.4)
    binds     : 1 in SQL_C_CHAR → WVARCHAR, buffer 0x14; 2 in SQL_C_UBIGINT → BIGINT (the PDB type is __int64);
                3 out SQL_C_SLONG → INTEGER (initialised 0)
    result    : ok = rc ∈ {0,1} and @RET == 1; no reply packet, only the log line
    body (inferred from usp_Cash_setCash, Account.bak, Ko Dong Gyun 2007):
        SET @RET = 0
        SELECT @userNo = nUserNo FROM tUser WHERE sUserID = @userID AND bIsDelete = 0;  not found → RETURN
        BEGIN TRAN
        UPDATE tCash SET cash = cash + @cash WHERE userNo = @userNo AND cashType = 2      -- 2 = event cash
            (no row → INSERT tCash (userNo, cashType, cash) VALUES (@userNo, 2, @cash))
        INSERT tCashLog (userNo, logType, cashType, cash, reference) VALUES (@userNo, 1, 2, @cash, <event id>)
        error → ROLLBACK, RETURN;  COMMIT; SET @RET = 1
```

- Family: `usp_Cash_setCash(@userNo, @cashType 1 cash / 2 event cash, @cash int, @reference nvarchar(20))` and the event
  copy `usp_Cash_setCash_EVENT_L20` (once per account, reference `'200708_EVENT_L20'`), both Account.bak with original
  headers *(db-backup)*. They key on the user number; this procedure gets an account **ID**, so it must look the user up.
- "HIT3" is the event name in the handler's log text; the cash type (event cash 2) and the reference string are
  *(inferred)*. `tCash.cash` is `int` in the family procedures while the bind is `bigint`.
- Dead in 2016: no binary sends 0x0820.

### 2.3 Teen protection: `p_UserKey_Get_FromAccount`, `p_UserPlayRemainTime_Get_FromAccount`, `…_Set_FromAccount`

The Korean rule *(inferred: the 2016 Login never sends 0x0C26; Korea had a play-time limit for minors)*: an account
under 18 may play 180 minutes in a window of 17 940 s (4 h 59 min) after its last logout. The three procedures relay to
the portal database (linked server "GAMECOMMONDB") that holds the birth date and the per-person play time. The person is
identified by a portal **user key**, not by the Fiesta user number.

```pseudo
p_UserKey_Get_FromAccount(@sUserID nvarchar(20) in, @sUserKey nvarchar(24) out, @dUserBirthDay datetime out,
                          @nRet int out)                       (names: CSQLPAccount::SQL_USERKEY_DATA, pdb2016)
    called by : @ FUN_00419200 ← 0x0C26 NC_USER_TEENAGER_REQ @ FUN_00402610 (D01 §3.4)
    binds     : 1 in CHAR→WVARCHAR buffer 0x14 (struct field sUserID[22]); 2 out CHAR→WVARCHAR buffer 0x19 (struct field
                sUserKey[50]: the key is at most 24 characters); 3 out TIMESTAMP; 4 out SQL_C_ULONG → INTEGER, initialised 1
    result    : ok = rc ∈ {0,1} and @nRet == 0. Not ok → 0x0C27 nType 3 (DB error; Login lets the account in, treated as
                adult) and the log ", p_UserKey_Get_FromAccount, sUserID=%s, DB ERROR, Check GAMECOMMONDB Linked Server."
    body      : SELECT @sUserKey, @dUserBirthDay FROM GAMECOMMONDB.<portal user table> WHERE <portal id> = @sUserID;
                found → @nRet = 0, else @nRet = 1 (inferred; the caller does not tell 1 from other non-zero values)
    use       : only year / month / day of @dUserBirthDay are read; born before (today − 18 years + 1 day) 00:00 → adult
                (nType 2, no further call)

p_UserPlayRemainTime_Get_FromAccount(@sUserKey nvarchar(24) in, @dUserLogoff datetime out,
                                     @nUserPlayRemainTime int out, @nRet int out)   (SQL_USER_PLAY_REMAIN_TIME_DATA, pdb2016)
    called by : @ FUN_004192c0 ← 0x0C26 (minors only)
    binds     : 1 in CHAR→WVARCHAR buffer 0x19; 2 out TIMESTAMP; 3 out SQL_C_ULONG → INTEGER; 4 out ULONG → INTEGER, init 2
    result    : @nRet 0 = row found; 1 = no row yet (caller: nType 0, 180 minutes); anything else = DB error (nType 3).
                The caller reads year…minute of @dUserLogoff (seconds ignored) and @nUserPlayRemainTime (minutes):
                    elapsed = now − dUserLogoff
                    elapsed ≥ 17940 s                → nType 0, nMinute 180         (window over: full time again)
                    else nUserPlayRemainTime ≥ 1    → nType 0, nMinute = nUserPlayRemainTime
                    else                             → nType 1, nMinute = (int)(17940 − elapsed) / 60
                                                       (minutes until the window ends; asm @ 0x4029c6 `fsubrp` 17940 − elapsed)
    body      : SELECT @dUserLogoff, @nUserPlayRemainTime FROM <play time table> WHERE sUserKey = @sUserKey;
                @nRet = 0 found / 1 not found

p_UserPlayRemainTime_Set_FromAccount(@sUserKey nvarchar(24) in, @dUserLogoff datetime in,
                                     @nUserPlayRemainTime int in, @nRet int out)
    called by : @ FUN_00419380 ← 0x0C28 NC_USER_TEENAGER_SET_CMD @ FUN_00402a40 (D01 §3.4; no reply)
    binds     : 1 in CHAR→WVARCHAR buffer 0x19; 2 in TIMESTAMP (now, seconds 0); 3 in ULONG→INTEGER; 4 out ULONG, init 2
    result    : ok = @nRet == 0, else only a log line
    body      : upsert (sUserKey, dUserLogoff, nUserPlayRemainTime); @nRet = 0
```

- No Fiesta table holds these values; the portal table and column names are unknown *(ours: `tUserPlayTime(sUserKey,
  dUserLogoff, nUserPlayRemainTime)`)*. `nUserPlayRemainTime` is in minutes: the get result goes unchanged into
  `nMinute`, and 180 is the full allowance.
- Who sends 0x0C28 with the remaining time is not in any 2016 binary (dead path).

### 2.4 Region logins: `usp_User_LoginNetmarble`, `usp_User_LoginGame` (5), `usp_TWUser_insert`, `usp_JPUser_insert`

```pseudo
usp_User_LoginNetmarble(@UniID nvarchar in, @userNo int out, @authID tinyint out, @block int out,
                        @isLoginable int out)                  (out names from usp_User_loginGame, Account.bak)
    called by : CSQLPAccount::usp_User_LoginNetmarble @ FUN_00419010 ← 0x0C1E NC_USER_LOGIN_NETMARBLE_DB_REQ @ FUN_00403720
    binds     : 1 in CHAR→WVARCHAR buffer 0x100 (the request field UniID is 20 bytes); 2 out ULONG→INTEGER (init −1);
                3 out TINYINT; 4 out ULONG→INTEGER; 5 out ULONG→INTEGER
    result    : the rc is not checked; the wrapper returns @userNo. −1 = not found (the reply's password is cleared);
                block / isLoginable go into 0x0C08 like usp_User_loginGame's
    body (inferred: the 6-parameter usp_User_loginGame without the password, keyed on the portal's unique ID):
        SET @userNo = -1, @authID = 0, @block = 0, @isLoginable = 0
        SELECT @userNo = nUserNo, @authID = U.nAuthID, @block = bIsBlock, @isLoginable = bIsLoginAble
          FROM tUser U JOIN tUserAuth UA ON U.nAuthID = UA.nAuthID WHERE <Netmarble UniID column> = @UniID AND bIsDelete = 0
        IF @block = 1: EXEC usp_User_chkBlock @userNo, @RET OUTPUT; @RET = 1 → re-read bIsBlock
```

- Where the Netmarble ID is stored is unknown: `tUser` / `tUserOption` in Account.bak have no such column; accounts
  created through a channel get `tUserOption.sChannel` (`usp_User_insert` → `usp_User_insertOption`, values `ONSON` /
  `PANDORA` in `usp_User_setChannelLog`'s header) *(db-backup)*. The simplest rebuild stores the UniID as `tUser.sUserID`.

```pseudo
usp_User_LoginGame(@sUserName nvarchar(32) in, @sSerial nvarchar(32) in, @sUID nvarchar(16) in, @sSID nvarchar(6) in,
                   @nRet int out)                    (names: CSQLPAccount::SQL_USER_GET_TW_LOGIN_GAME, pdb2016)
    called by : CSQLPAccount::usp_UserTWLoginGame @ FUN_00419440 (pdb2016) ← 0x0C3E NC_USER_TW_PASSWORD_CHECK_REQ
                @ FUN_00402d40 (D01 §3.2)
    binds     : 1–4 in CHAR→WVARCHAR, buffers 0x20 / 0x20 / 0x10 / 6 (struct fields 36 / 36 / 20 / 8); 5 out SLONG, init 0
    result    : ok = rc ∈ {0,1} and @nRet == 0, else 0x0C3F nError 0x44 and nUserNo −1
    body (inferred): validate the portal session (@sSerial, @sSID) issued to account @sUserName / portal number @sUID;
                @nRet = 0 valid, non-zero refused. The caller then takes the user number from atol(@sUID): the TW
                Fiesta user number **is** the portal number.
```

- **Version question (plan: "usp_User_LoginGame 5 vs 6").** SQL Server procedure names are not case-sensitive, so one
  database cannot hold both this 5-parameter `usp_User_LoginGame` and the 6-parameter `usp_User_loginGame` the
  0x0C07 / 0x0C39 / 0x0C53 path calls (`CSQLPAccount::p_UserLoginGame` @ FUN_00418dd0, source in Account.bak). The official
  wrapper name `usp_UserTWLoginGame` and the Taiwan-only caller show that the 5-parameter procedure belonged to the
  Taiwan service's Account database, which did not carry the Korean/US `usp_User_loginGame` *(inferred)*. Against the NA
  database (Account.bak) the call resolves to the 6-parameter procedure and fails (D01-B4). A rebuild that offers both
  login families in one database has to rename one of them (and patch the call string), or keep one database per region.

```pseudo
usp_TWUser_insert(@nUserNo int in, @sUserName nvarchar(50) in, @nRet int out)   (SQL_USER_INSERT_TW, pdb2016)
    called by : CSQLPAccount::usp_UserTWInsert @ FUN_00419580 ← 0x0C3E after a valid usp_User_LoginGame
    binds     : 1 in SQL_C_SLONG → INTEGER (= atol(sUID)); 2 in CHAR→WVARCHAR buffer 0x32 (sUserName, first 32 bytes);
                3 out SLONG, init 0
    result    : ok = rc ∈ {0,1} and @nRet == 0, else nError 0x46. Then the caller fetches every row of a result set and
                keeps the **last** row's column 1 (SQL_C_ULONG); it must equal @nUserNo, else nError 0x46. No row: the
                compare value stays −1 (≠ any real number) → 0x46.
    body (inferred):
        IF NOT EXISTS (SELECT 1 FROM tUser WHERE nUserNo = @nUserNo):
            SET IDENTITY_INSERT tUser ON; INSERT tUser (nUserNo, sUserID, sUserPW, sUserName, …) VALUES (@nUserNo, @sUserName, …)
        SET @nRet = 0
        SELECT nUserNo FROM tUser WHERE nUserNo = @nUserNo        -- the result row the caller checks
```

- The explicit user number means `tUser.nUserNo` (an IDENTITY in the NA DB, `usp_User_insert` reads `@@IDENTITY`
  *(db-backup)*) was either inserted with IDENTITY_INSERT or the TW database had no identity; a separate mapping table is
  equally possible. Only "the last row's first column is the user number" is fixed by the caller.

```pseudo
usp_JPUser_insert(@sUserName nvarchar(20) in, @sIP nvarchar(30) in, @sChannel nvarchar(250) in, @nRet int out)
                                                       (SQL_USER_GET_JP_LOGIN_GAME, pdb2016)
    called by : CSQLPAccount::usp_UserJPLoginGame @ FUN_00419690 (pdb2016 name) ← 0x0C4B NC_USER_JP_PASSWORD_CHECK_REQ
                @ FUN_00403e10, after the HTTP authentication at auth.gamescampus.co.jp succeeded (D01 §3.2)
    binds     : 1–3 in CHAR→WVARCHAR, buffers 0x14 / 0x1e / 0xfa (struct fields 24 / 30 / 254); 4 out SLONG, init 0
    result    : ok = rc ∈ {0,1} and @nRet == 0 (failure → nError 0x5d). Then the last row's column 1 (SQL_C_ULONG) is
                0x0C4C nUserNo; without a row it is an uninitialised stack value (D01-B6)
    body (inferred): find or create the account for the portal ID @sUserName (sUserIP = @sIP; the channel / request id
                @sChannel kept as the sign-up channel), @nRet = 0, then SELECT nUserNo.
```

- Japan has no password in Fiesta's DB: the portal authenticates, the procedure only maps the portal ID to a user number
  and creates it on first login *(inferred from the call order: insert only after "SUCCESS")*.

### 2.5 Other Account login statements of D01

- **`nUserNo == −2` → Login 0x4B "Please accept the agreement".** No Account procedure in any backup produces −2 and the
  Account server never writes it (D01 §3.2). Account.bak's only agreement tables are the payment agreement
  (`tPayAgreement`, `usp_Pay_getAgreement` / `usp_Pay_setAgreement`, used by the web shop, not by any binary). Left open:
  the Login branch is dead against every known database. A rebuild that wants an agreement step returns −2 from
  `usp_User_USloginGame` for accounts without one; nothing in the 2016 data says which column held it.
- **`usp_User_USloginGame` version.** Account.bak has two bodies: `usp_User_USloginGame` (ID, then e-mail retry; plus the
  "added by Stu" EGPal password refusal and the "added by John" `tUserMergeYet` HTTP check) and `usp_User_USloginGame_O`
  (ID only, header of `usp_User_loginGame`, 2007). Both match the 6-parameter call. A rebuild should follow
  `usp_User_USloginGame` **without** the Stu / John blocks: the e-mail retry is in Ko Dong Gyun's own dated change note
  (2013-01-28, "US service move"), the two additions name a private host address (`10.55.12.231`) and a single
  hard-coded password hash, which are deployment hacks of unknown date *(db-backup)*.
