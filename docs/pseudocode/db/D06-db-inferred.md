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
| −15 | – | `SQL_C_SSHORT` | – |
| 5 | – | – | `SQL_SMALLINT` |
| 12 | – | – | `SQL_VARCHAR` (narrow; the AccountLog IP strings) |
| −10 | – | – | `SQL_WLONGVARCHAR` (`text` / `ntext` parameter; report chat log) |

Two driver rules a rebuild's procedures must respect *(inferred from Microsoft's ODBC documentation of the SQL Server
drivers, not from the binaries)*:

- **Output parameters arrive after the last result set.** The SQL Server drivers return output parameter values only once
  every result set of the call has been read (`SQLMoreResults` → `SQL_NO_DATA`). A wrapper that tests an output parameter
  right after `SQLExecDirect` of a procedure that also `SELECT`s a row therefore tests the value the caller put into the
  buffer before the call, not the procedure's (see `usp_AccountLog_GetDateDiffLastlogout`, §3.4). For procedures without
  a result set (`SET NOCOUNT ON`, only `SET @out = …`) the values are there when `SQLExecDirect` returns.
- **Never return NULL in an output parameter.** Every bind passes a NULL indicator pointer; a NULL output value then
  makes the call fail with SQLSTATE 22002 ("indicator variable required but not supplied"). Every procedure in this
  document sets each output parameter to a non-NULL value on every path (dates included, e.g. `'1900-01-01'`).

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

## 3. AccountLog DB (`AccountLog`) and Statistics DB (`StatisticsData`), AccountLog server

The AccountLog server holds two ODBC connections (`ServerInfo.txt` `ODBC_INFO`): "AccountLog" (`Database=AccountLog`,
`*this + 0x124c`) and "Statistics" (`Database=StatisticsData`, `*this + 0x126c`). Four procedures it calls have no source
in any backup; the 2015 AccountLog binary calls the same four with the same strings (no older version to compare).
Code: `clean.py re-data/exports/accountlog-pdb - <addr>` (official wrapper and struct names, *(pdb2016)*).

**Reachability in 2016.** 0x080A (WM, every statistics interval) and 0x0C62 (WM, world login of an account whose comeback window is over or
that is older than `UserComeback_DaysAfterSignUp`, W01-core.md §3.3) are live; 0x082C has no sender in any 2016 binary (no literal in the
login / WM / zone exports, no `EVENT_L20` string outside the WM's 0x082D handler) and the 2016 client ignores the
resulting 0x082E (C01: "WM `0x082e` … ignored by this client build"). So a 2016 rebuild needs §3.1 and §3.4; §3.2–§3.3
only if it revives the level-20 event.

### 3.1 `p_SameTimeCharClass_Add` — concurrent players per class (Statistics DB)

```pseudo
p_SameTimeCharClass_Add(@nIndex int in, @nClass tinyint in, @nCount int in, @nRet int out)
                                      (names: CSQLPStatistics::SQL_SAME_TIME_CHAR_CLASS_DATA, pdb2016)
    called by : CSQLPStatistics::p_SameTimeCharClass_Add @ FUN_004155c0 ← 0x080A NC_MISC_CONNECTER_ACK
                CPFsAccountLog::fc_NC_MISC_CONNECTER_ACK @ FUN_004026f0 (D01 §4.2), after p_SameTimeChar_Add @ FUN_00415540
    binds     : 1 in SQL_C_ULONG → INTEGER  (nIndex = the @nIndex output of p_SameTimeChar_Add for this report)
                2 in SQL_C_TINYINT → TINYINT (nClass = 0…63, the index into the WM's nEachClass[64])
                3 in SQL_C_ULONG → INTEGER  (nCount = nEachClass[nClass], 1…65535; classes with 0 are not called)
                4 out SQL_C_ULONG → INTEGER (nRet, set to 0 by the handler before each call)
    result    : ok = rc ∈ {0,1} and nRet == 0; on an rc error `ViewDBError("CSQLPStatistics::p_SameTimeCharClass_Add")`.
                The handler ignores the result (no retry, no reply).
    table     : tSameTimeCharClass (nIndex int, nClass tinyint, nCount int)   *(ours: name and columns from the PDB struct)*
    body      : SET NOCOUNT ON
                INSERT tSameTimeCharClass (nIndex, nClass, nCount) VALUES (@nIndex, @nClass, @nCount)
                SET @nRet = CASE WHEN @@ERROR = 0 THEN 0 ELSE -1 END
```

Evidence: the parent row `p_SameTimeChar_Add` (StatisticsData.bak, 2005) inserts `tSameTimeChar (nWorld, nCount)` and
returns `@nIndex = @@IDENTITY`; its PDB struct `SQL_SAMETIMECHAR_DATA { int nIndex; TIMESTAMP dDate; uchar nWorld; int
nCount }` is exactly that table's row (`p_SameTimeChar_Query` selects `nIndex, dDate, nWorld, nCount`). The class struct
`SQL_SAME_TIME_CHAR_CLASS_DATA { int nIndex; uchar nClass; int nCount; int nRet }` has the same shape minus the date, so
the class rows are children of one `tSameTimeChar` row keyed by `nIndex` *(inferred)*. StatisticsData.bak has no class
table at all (`bak.py names`: only `tSameTimeChar`, `tDayClassLevel*`, `tDayUser*`, …), so the private-server install
dropped it.

- `nIndex` is 0 when `p_SameTimeChar_Add` failed (D01-B8): a rebuild that wants the 2016 behaviour must not declare a
  foreign key from `tSameTimeCharClass.nIndex` to `tSameTimeChar`, or the class rows of a failed report are lost
  instead of stored under 0.
- Per world and report at most 64 rows; nothing in any binary reads the table back (reporting is external).

### 3.2 `p_Event_L20_Get` — has the account already had the level-20 reward?

```pseudo
p_Event_L20_Get(@nUserNo int in, @nEventType tinyint in, @nWorldNo tinyint out, @nCharNo int out,
                @dDateDone datetime out, @nRet int out)        (names: CSQLPEventL20::SQL_EVENT_L20, pdb2016)
    called by : CSQLPEventL20::p_Event_L20_Get @ FUN_00415360 ← 0x082C NC_MISC_EVENT_L20_DB_REQ
                CPFsAccountLog::fc_NC_MISC_EVENT_L20_DB_REQ @ FUN_00402aa0 (D01 §4.2)
    binds     : 1 in ULONG → INTEGER (nUserNo = req.nUserNo); 2 in UTINYINT → TINYINT (nEventType = req.nEventNo);
                3 out UTINYINT → TINYINT; 4 out ULONG → INTEGER; 5 out TIMESTAMP; 6 out ULONG → INTEGER
                (nRet; the wrapper sets it to −1 before binding: asm `mov dword [edi+0x20], 0xffffffff` @ 0x41538e)
    result    : wrapper true = rc ∈ {0,1} and nRet > 0. The handler:
                    true             → ack nError 0x1289            (already rewarded: stop)
                    nRet == −1       → ack nError 0x128a + log "…GetEventL20…"   (rc error leaves the −1 in place)
                    other (0, < −1)  → p_Event_L20_Set (§3.3)
                The outputs 3–5 (world, character and date of the earlier reward) are fetched into the struct but no
                code reads them.
    table     : tEventL20 (nUserNo int, nEventType tinyint, nWorldNo tinyint, nCharNo int, nEventPoint int,
                dDateDone datetime DEFAULT getdate())   *(ours: name; columns = SQL_EVENT_L20 minus nRet)*
    body      : SET NOCOUNT ON
                SELECT @nWorldNo = nWorldNo, @nCharNo = nCharNo, @dDateDone = dDateDone
                  FROM tEventL20 WHERE nUserNo = @nUserNo AND nEventType = @nEventType
                IF @@ROWCOUNT > 0  SET @nRet = 1
                ELSE  SELECT @nWorldNo = 0, @nCharNo = 0, @dDateDone = '1900-01-01', @nRet = 0
                (a DB error inside the procedure: @nRet = −1)
```

### 3.3 `p_Event_L20_Set` — record the reward

```pseudo
p_Event_L20_Set(@nUserNo int in, @nEventType tinyint in, @nWorldNo tinyint in, @nCharNo int in,
                @nEventPoint int in, @nRet int out)              (same struct SQL_EVENT_L20)
    called by : CSQLPEventL20::p_Event_L20_Set @ FUN_00415450 ← fc_NC_MISC_EVENT_L20_DB_REQ @ FUN_00402aa0,
                only after p_Event_L20_Get answered "not yet"
    binds     : 1 in ULONG; 2 in UTINYINT (nEventType); 3 in UTINYINT (nWorldNo = req.nWorldNo); 4 in ULONG
                (nCharNo = req.nCharNo); 5 in ULONG (nEventPoint = req.nEventPoint); 6 out ULONG nRet (wrapper sets −1)
    result    : ok = rc ∈ {0,1} and nRet == 0 → ack nError 0x1288 (granted). Else nError 0x128b, and the line
                "ERROR - …SetEventL20,…, nRet=%d" is logged only when nRet ∉ {1, 3} (D01-B10's condition): 1 and 3 are
                expected refusals, 2 / −1 / anything else is a DB error.
    body      : SET NOCOUNT ON
                IF <event period over>                 SET @nRet = 3      (inferred, see below)
                ELSE IF EXISTS(SELECT * FROM tEventL20 WHERE nUserNo = @nUserNo AND nEventType = @nEventType)
                                                       SET @nRet = 1      (race with a parallel request)
                ELSE  INSERT tEventL20 (nUserNo, nEventType, nWorldNo, nCharNo, nEventPoint)
                           VALUES (@nUserNo, @nEventType, @nWorldNo, @nCharNo, @nEventPoint)
                      SET @nRet = CASE WHEN @@ERROR = 0 THEN 0 ELSE 2 END
```

Evidence for §3.2–§3.3 (all *(inferred)* except the binds and the branch structure):

- **The event.** Account.bak `usp_Cash_setCash_EVENT_L20` (Ko Dong Gyun, 2007-06-14): "event cash for the 2007-08-07
  PandoraTV / own event; to pay the cash only once per account even if several characters reach Lv 20; delete on
  2007-10-07" (`reference = '200708_EVENT_L20'`, `RETURN(-1)` when the account already has it). So L20 = "a character
  of the account reached level 20", once per (account, event number); `nEventPoint` is the amount the WM asked for. That
  procedure runs in the Account DB and is not called by any 2016 binary, so the cash payment itself happened outside
  these servers (web shop or a cross-database call inside `p_Event_L20_Set`; `p_AccountLog_GetLog` shows that
  AccountLog procedures do reach `AccountDB.Account.dbo.tUser` through a linked server). A rebuild that revives the event
  can call `usp_Cash_setCash_EVENT_L20` from `p_Event_L20_Set`.
- **The codes 1 / 2 / 3.** The AccountLog family procedure `p_Event_WorldCup_Enter` (AccountLog.bak, lenasoft
  2006-05-26) answers `@err` 3 = `GETDATE()` past the event end, 1 = already entered, 2 = insert error, 0 = done. That is
  exactly the split the handler makes: 1 and 3 are not logged, every other code is. The once-per-account rule of
  `usp_Cash_setCash_EVENT_L20` and the "delete on 2007-10-07" note give the period check.
- **Get's `nRet > 0`.** The wrapper's −1 default and the handler's `== −1` test make −1 the error value; the Set call on
  every other non-positive value makes 0 "no row". "> 0" = found.
- Client side: 0x082E NC_MISC_EVENT_L20_CMD `{ u8 nEventNo, u16 nError }` (pdb2016, WorldManager.pdb) is forwarded by the WM for every code
  except 0x1289 (W01-core.md §8); the 2016 client ignores it, and `client-error-codes.json` has no text for
  0x1288–0x128b.

### 3.4 `usp_AccountLog_GetDateDiffLastlogout` — seconds since the account's last logout

```pseudo
usp_AccountLog_GetDateDiffLastlogout(@nUserNo int in, @nRet int out)
                                                   (names: CSQLPAccountLog::SQL_GET_DATE_LAST_LOGOUT, pdb2016)
    called by : CSQLPAccountLog::usp_AccountLog_GetDateDiffLastlogout @ FUN_00415020 ← 0x0C62 NC_USER_LOGOUT_LAST_DAY_REQ
                CPFsAccountLog::fc_NC_USER_LOGOUT_LAST_DAY_REQ @ FUN_004035e0 (D01 §4.4)
    binds     : 1 in SQL_C_SLONG → INTEGER (nUserNo); 2 out SQL_C_SLONG → INTEGER (nRet, set to 0 by the handler)
    result    : wrapper true = rc ∈ {0,1} and nRet == 0 (with a result set this tests the handler's 0, §1.2:
                (original bug) D06-B1). Then DBRecord::fetch: a row → column 1 read as SLONG into
                ack.tLastSec; endFetch. No row or a failed call → tLastSec 0 and the log "Error - … : UserNo %d".
    result row: one row, one int column = seconds between the last logout and now
    body      : SET NOCOUNT ON
                SET @nRet = 0
                SELECT TOP 1 DATEDIFF(s, dDate, getdate()) AS diffDate
                  FROM tAccountLog WHERE nUserNo = @nUserNo AND nType = 2
                 ORDER BY dDate DESC                                    (inferred)
```

Evidence: the WM sends 0x0C62 during world login (after 0x0C61) when the account's last comeback is older than
`UserComeback_DaysAfterComeback` days, or it has none and is older than `UserComeback_DaysAfterSignUp` days, and treats `tLastSec ≥ UserComeback_DaysAfterLogOff · 86400` as a comeback (W01-core.md
§3.3), so the value is seconds since the last logout. The Account twin `usp_ReturnUser_GetDatediffLastlog` (Account.bak,
JK CHO 2014-02-10, same `(@nUserNo, @nRet output)` signature, called the same way by the Account server, D01 §3.3) is
`SET @nRet = 0; SELECT TOP 1 DATEDIFF(s, dDate, getdate()) … ORDER BY dDate DESC`; the body above is that procedure on
the AccountLog table. `tAccountLog` has `dDate` (`p_AccountLog_Get` selects `nLogNo, dDate, nType, nUserNo, …`), and
`nType 2` is the account logout row (0x0722 NC_LOG_USER_LOGOUT, sent by the WM at session close, D01 §4.1). The
alternative source, `tLogout` (`usp_Log_setLogout`, one row per character logoff), is not written when an account leaves
without entering the game and its date column is not visible in the backup, so `tAccountLog nType 2` is the better fit;
the procedure prefix `usp_AccountLog_` points the same way *(inferred)*. When the procedure is called, the current
session is still open, so the newest `nType 2` row is the previous session's logout.

- An account without a logout row returns no row: tLastSec 0, logged as an error, and the WM classes it as a normal
  user (0 < the comeback limit). Same outcome for a DB error.

### 3.5 Version check of the AccountLog / Statistics procedures that have source

Binds of the 2016 wrappers against the parameter lists of the backup copies (each procedure has one version; `cover`
shows the same parameter count for all):

| Procedure (backup) | Wrapper | Binds vs backup | Verdict |
|---|---|---|---|
| `p_AccountLog_Add` (AccountLog.bak) | `@ FUN_00414a30` | TINYINT, SLONG, TINYINT, SSHORT→SMALLINT, USHORT→SMALLINT, CHAR→VARCHAR(16), CHAR→WVARCHAR buf 16 ×2, out UBIGINT→BIGINT vs `tinyint, int, tinyint, smallint, smallint, varchar(16), nvarchar(16) ×2, bigint OUTPUT` | match; `nErrorCode` ≥ 0x8000 would overflow `smallint` (SQLSTATE 22003, row lost); all close reasons and login codes are small |
| `p_IPBlock_IsBlock` (AccountLog.bak) | `@ FUN_00414d00` | SLONG, CHAR→VARCHAR buf 20, out TINYINT vs `int, nvarchar(20), tinyint OUTPUT` | match (the `Fixes/` copy is the 2018 edit, D01 §4.3) |
| `usp_Log_setLogout` (AccountLog.bak) | `@ FUN_00414be0` | TINYINT, SLONG ×2, TINYINT, USHORT→SMALLINT, SBIGINT→BIGINT, SSHORT→SMALLINT, out SLONG vs `TINYINT, INT ×2, TINYINT, SMALLINT, BIGINT, SMALLINT, INT OUTPUT` (`@RET` 1 = ok) | match |
| `usp_EventiPad_setTicket` (AccountLog.bak) | `@ FUN_00414e30` | SLONG ×2, out SLONG vs `int, int, int output` | match |
| `p_Report_Add` (AccountLog.bak) | `@ FUN_004150c0` | ULONG, WVARCHAR buf 20 ×2, UTINYINT, WVARCHAR buf 16, WVARCHAR buf 256, WLONGVARCHAR, out ULONG vs `int, nvarchar(16) ×2, tinyint, nvarchar(16), nvarchar(512), text, int OUTPUT` | match; a 17–19 character name would be cut to 16 by the parameter (character names are shorter) |
| `p_Report_Del` / `p_Report_Get` (AccountLog.bak) | `@ FUN_004151f0` / `@ FUN_00415270` | ULONG, out USHORT→SMALLINT / ULONG, UTINYINT vs `int, smallint OUTPUT` / `int, tinyint` | match |
| `p_SameTimeChar_Add` (StatisticsData.bak) | `@ FUN_00415540` | TINYINT, ULONG, out ULONG vs `tinyint, int, int OUTPUT` | match |

All AccountLog-side procedures with source are consistent with the 2016 calls; a rebuild can take them as they are
(`p_IPBlock_IsBlock` from AccountLog.bak, not from `Fixes/`).

## 4. GameLog DB (`w00_GameLog`), GameLog server

### 4.1 `usp_Login_setChannel` — the client channel tag of each character login

```pseudo
usp_Login_setChannel(@nCharNo int in, @nUserNo int in, @sChannel nvarchar(20) in, @nRet int out)
                                                          (parameter names ours; the struct has no PDB)
    called by : SQL_usp_Login_setChannel @ FUN_0041b680 ← 0x040A NC_LOG_GAME_LOGIN fc_NC_LOG_GAME_LOGIN @ FUN_004032b0
                (D05 §2.2), before the p_GameLog_Add_Type6 nType 10 row of the same login
    binds     : 1 in SQL_C_ULONG → INTEGER (req.chrregnum); 2 in SQL_C_ULONG → INTEGER (req.usrregnum);
                3 in SQL_C_CHAR → WVARCHAR, buffer 0x14 (req.spawnapps, copied with _mbsnbcpy max 20 bytes; the zeroed
                output field behind it terminates a 20-byte value); 4 out SQL_C_SLONG → INTEGER (set to 0 first)
    result    : none: the SQLExecDirect return value and @nRet are not read, and unlike the p_GameLog_Add* wrappers no
                failure line is written to GameLog_<date>.txt (D05 §1.2). A failing procedure loses the row silently.
    table     : tLoginChannel (nLogNo int IDENTITY, dDate datetime DEFAULT getdate(), nCharNo int, nUserNo int,
                sChannel nvarchar(20))                     *(ours)*
    body      : SET NOCOUNT ON
                INSERT tLoginChannel (nCharNo, nUserNo, sChannel) VALUES (@nCharNo, @nUserNo, @sChannel)
                SET @nRet = CASE WHEN @@ERROR = 0 THEN 0 ELSE -1 END
```

Evidence:

- **What `spawnapps` is.** The 2016 client fills the 20-byte `spawnapps` of 0x0C5A NC_USER_US_LOGIN_REQ
  (`AccountFrameWork::NcUserLoginReq` @ FUN_0046f0a0, `_strncpy(…, DAT_00a64358, 0x14)`) from a string that
  client start-up (@ FUN_0045b1b0) sets to `"Original"` and then overwrites with the first entry read from `Fiesta.ini`;
  for "Original" it prints "SpawnApps Off.". Login keeps it in the session (login-server.md §5.1), the WM passes it to the
  Character server in 0x1036, and the Character server forwards the 56-byte request as 0x040A (D02 §5). So the value is
  the name of the launcher / partner portal that started the client, `"Original"` for the publisher's own launcher. The
  AccountLog server prints the same field as `client-version` (D01 §4.5); the client code shows it is a tag, not a version.
- **"Channel".** The Account DB has the same concept for account creation: `usp_User_setChannelLog` (Account.bak, Ko Dong
  Gyun 2007-08-03, "log of users who joined through a channeling partner", `@channel nvarchar(20)` = "ONSON/PANDORA")
  inserts `tChannelLog (userNo, channel, issueDate)` with a `dDate` default (`bak.py names`: `DF__tChannelL__dDate`).
  `@channel nvarchar(20)` has the same size as the 20-byte bind. `usp_Login_setChannel` is the per-login counterpart in
  the game log *(inferred)*; whether it inserts one row per login (as above) or keeps one row per character with the last
  channel cannot be told from the binary, since nothing reads it back.
- 2015 GameLog calls the same string; neither GameLog backup has the procedure or a channel table.

### 4.2 `p_GameLog_Add_Type6` version (D05 §1.2 open point)

The two GameLog backups differ only in Type6: `GameLog.bak` (2008 R2 backup, 31 procedures, has table `tLevelUpInfo`)
adds the event-ranking update for nType 30; `w00_GameLog.bak` (2017 backup, 26 procedures, no `tLevelUpInfo`) has the
plain insert. The 2016 binary calls `p_GameLog_Add_TypeL`, which only `w00_GameLog.bak` has, and `ServerInfo.txt` points
the GameLog server at `Database=w00_GameLog`. So the only backup that serves every 2016 call has the plain Type6, and a
rebuild should follow it. The `tLevelUpInfo` block ("이벤트 랭킹용으로 별도 테이블기록 by amadeus", for an event ranking) is an
event-time addition of the older database; that the live 2016 database still had it is possible but not shown by
anything *(db-backup)*. The binary cannot decide it (same call either way); D05's statement stays open for the live
database, settled for the rebuild.

## 5. Character DB (`w00_Character`), Character server: pets, link scroll, mini house, guild

Code: `re-data/exports/character` (no 2016 PDB for this exe; wrapper names `SQL_<procedure>` from D02/D03/D04's names
files). Parameter names come from the `CSQLP*::SQL_*` structs of the Account PDB, the same shared library
(`docs/knowledge/S01.md` §4.2) *(pdb2016; offsets checked against the Character wrappers below)*. Return values of the
wrappers whose decompilation shows `void` are read from the assembly (`objdump` of `w00_Character/Character Release.exe`).

### 5.1 Pets: `usp_Pet_setCreate`, `usp_Pet_getInfo`, `usp_Pet_setName`, `usp_Pet_setTendency`, `usp_Pet_setDelete`

No 2016 backup has a pet procedure. `Character.bak` / `w00_Character.bak` hold an older, unrelated pet table `tPet`
(default constraints on `nPetNumber, sInfo, nFlags, nAssignName, nLevel, nExp, nSatiety, nSpeed, nAbilityType,
nAbilityValue, nSkinColor, dDate`) and `tPetSkill` (FK `nPetK…` → `tPet`) *(db-backup)*: no master, mind or stress
column, so the 2016 procedures used another table. The NA2016 `World00_Character.bak` adds third-party versions of three
of them (author "Sam \"Saze\" V.", 2019, over `tPetNew`); they are not 2016 and differ in the result convention (below).

Shared contract (all five wrappers, `CSQLPPet`):

- **`@nRet` = 0 means success.** Each wrapper sets `nRet = 0` before the call and logs `"ERROR - CSQLPPet::usp_Pet_<x>,
  ret(%d), nRet(%d)"` when `rc ∉ {0,1}` or `nRet ≠ 0`. For the three without a result set (setName, setTendency,
  setDelete) the wrapper returns 1 only when `rc ∈ {0,1}` and `nRet == 0` (asm: `mov al,1` / `xor al,al` before `ret 8`
  @ 0x467430 / 0x467540 / 0x467810). The NA2016 procedures set `@nRet = @@ROWCOUNT` (= 1 on success): with them every
  rename fails (0x3419). A rebuild must answer 0.
- **For setCreate / getInfo the row decides.** These two return a row; the wrapper's flag starts at 1 (`mov byte
  [ebp-0x105], 1`) and is cleared on `rc ∉ {0,1}` or `nRet ≠ 0` (@ 0x467393 / 0x467754), then the row is fetched anyway;
  no row → log `"…, fetch error"`, return 0. With the SQL Server drivers `@nRet` is not yet returned while the row is
  pending (§1.2), so in practice: row returned and call ok → success; no row → failure. (Same dead-check pattern as
  D06-B1.)
- All numbers are bound `SQL_C_ULONG → INTEGER`, mind / stress `SQL_C_UTINYINT → TINYINT`, the name `SQL_C_CHAR →
  WVARCHAR` from a 16-byte `Name4` the handler copies into the 17-byte struct field and NUL-terminates (`SQL_PET_*`
  `sPetName[17]`). Names are 4–16 characters (zone check, Z07 §9); a new pet is created with the name `""`.
- `nMasterRegNum` is the zone's `ShinePet::spt_nMasterRegNum` (`spt_CreatePet` @ zone FUN_0055d290 fills 0xD40D with it)
  = the owner's character number *(inferred from the name)*.

Table *(ours, after the PDB field names)*:

```
tPetInfo ( nPetRegNum   int IDENTITY(1,1) PRIMARY KEY,     -- the pet item's option 2700 (D03 §1.3)
           nMasterRegNum int NOT NULL,                     -- tCharacter.nCharNo
           sPetName     nvarchar(16) NOT NULL DEFAULT '',
           nPetMind     tinyint NOT NULL, nPetStress tinyint NOT NULL,
           bDeleted     bit NOT NULL DEFAULT 0, dCreateDate datetime NOT NULL DEFAULT getdate() )
```

```pseudo
usp_Pet_setCreate(@nMasterRegNum int in, @sPetName nvarchar(16) in, @nPetMind tinyint in, @nPetStress tinyint in,
                  @nRet int out)                                    (names pdb2016 SQL_PET_CREATE)
    called by : SQL_usp_Pet_setCreate @ FUN_00467260 ← 0xD40D NC_PET_CREATE_DB_REQ @ FUN_0042b6b0 (D03 §13)
    binds     : 1 in ULONG→INTEGER +0; 2 in CHAR→WVARCHAR buf 0x10 +4; 3 in UTINYINT→TINYINT +0x15; 4 same +0x16;
                5 out SLONG→INTEGER +0x1c
    result    : one row, column 1 → DB_GetU32 → nPetRegNum (+0x18)
                handler: wrapper 0 → 0xD40E nError 0x3409, RegNum −1; RegNum == 0xFFFFFFFF → 0x3400; else 0x3408
    body      : SET NOCOUNT ON; SET @nRet = 0
                INSERT tPetInfo (nMasterRegNum, sPetName, nPetMind, nPetStress) VALUES (…)
                IF @@ERROR <> 0: SET @nRet = -1; SELECT CAST(-1 AS int); RETURN       -- → 0x3400 (handled refusal)
                SELECT CAST(SCOPE_IDENTITY() AS int) AS nPetRegNum
    evidence  : binds, fetch and codes read in the code; body inferred. Returning a −1 row for a refusal is what the
                handler's 0x3400 branch expects (inferred; no limit on pets per master is visible anywhere).

usp_Pet_getInfo(@nPetRegNum int in, @nRet int out)                  (SQL_PET_GET_INFO)
    called by : SQL_usp_Pet_getInfo @ FUN_00467670 ← 0xD40B NC_PET_LOAD_INFO_DB_REQ @ FUN_0042bcc0 (D03 §13), and
                CGameDB_Item_GetItemOptions @ FUN_004681a0 for every pet item (class 36, option 2700 ≠ −1) it loads:
                on success it copies the 16-char name into the attribute (+8) (D03 §1.3); failure keeps the item's name
    binds     : 1 in ULONG→INTEGER +0; 2 out SLONG→INTEGER +0x1c
    result    : one row: DB_GetU32 nMasterRegNum (+4), DB_GetStr sPetName (+8, field zeroed first), DB_GetU8 nPetMind
                (+0x19), DB_GetU8 nPetStress (+0x1a). Handler: 0x3420 with name / mind / stress, else 0x3421 (name "",
                0, 0). The master number is read but not sent or checked.
    body      : SET NOCOUNT ON; SET @nRet = 0
                SELECT nMasterRegNum, sPetName, nPetMind, nPetStress FROM tPetInfo
                 WHERE nPetRegNum = @nPetRegNum AND bDeleted = 0
                IF @@ROWCOUNT = 0: SET @nRet = -1                          -- no row → wrapper 0
    evidence  : column order = fetch order (code); NA2016's third-party version has the same column order.

usp_Pet_setName(@nPetRegNum int in, @sPetName nvarchar(16) in, @nRet int out)   (SQL_PET_SET_NAME)
    called by : SQL_usp_Pet_setName @ FUN_00467430 ← 0xD403 NC_PET_SET_NAME_DB_REQ @ FUN_0042ba70 (0xD404 0x3418 ok /
                0x3419), and ItemAttr_Save @ FUN_0046a730 case 0x24 (pet item, RegNum ≠ −1, after the option row is
                saved; result ignored)
    binds     : 1 in ULONG→INTEGER +0; 2 in CHAR→WVARCHAR buf 0x10 +4; 3 out SLONG→INTEGER +0x18
    body      : SET NOCOUNT ON; UPDATE tPetInfo SET sPetName = @sPetName WHERE nPetRegNum = @nPetRegNum AND bDeleted = 0
                SET @nRet = CASE WHEN @@ERROR = 0 AND @@ROWCOUNT = 1 THEN 0 ELSE -1 END

usp_Pet_setTendency(@nPetRegNum int in, @nPetMind tinyint in, @nPetStress tinyint in, @nRet int out)  (SQL_PET_SET_TENDENCY)
    called by : SQL_usp_Pet_setTendency @ FUN_00467540 ← 0xD401 NC_PET_SET_TENDENCY_DB_REQ @ FUN_0042b920 (no answer;
                failure logged "ERROR - fc_NC_PET_SET_TENDENCY_DB_REQ, (nPetRegNum=%d)")
    binds     : 1 in ULONG→INTEGER +0; 2 in UTINYINT→TINYINT +4; 3 same +5; 4 out SLONG→INTEGER +8
    body      : UPDATE tPetInfo SET nPetMind = @nPetMind, nPetStress = @nPetStress WHERE nPetRegNum = @nPetRegNum;
                @nRet as setName

usp_Pet_setDelete(@nPetRegNum int in, @nMasterRegNum int in, @nRet int out)     (SQL_PET_DELETE)
    called by : SQL_usp_Pet_setDelete @ FUN_00467810 ← 0xD40F NC_PET_REMOVE_DB_REQ @ FUN_0042bf30 (0xD410 0x3428 /
                0x3429). Dead in 2016: no zone code sends 0xD40F (`rg -w 0xd40f` in both zone exports: none).
    binds     : 1 in ULONG→INTEGER +0; 2 in ULONG→INTEGER +4; 3 out SLONG→INTEGER +8
    body      : UPDATE tPetInfo SET bDeleted = 1 WHERE nPetRegNum = @nPetRegNum AND nMasterRegNum = @nMasterRegNum;
                @nRet as setName (soft delete *(inferred)*: the master check suggests a guarded delete, the
                "setDelete" name a flag)
```

### 5.2 `usp_LinkScroll_SetDestMap` — remember where a map-link scroll sends the character

```pseudo
usp_LinkScroll_SetDestMap(@nCharNo int in, @sDestMapName nvarchar(12) in, @nRet int out)
                                                    (names pdb2016 CSQLPCharacter::SQL_MAPLINK_SCROLL_DEST: nRet +0,
                                                     nCharNo +4, destMapName[13] +8)
    called by : SQL_usp_LinkScroll_SetDestMap @ FUN_00460950 ←
                0x34C9 NC_ITEMDB_MAPLINK_ITEM_CONSUME_REQ @ FUN_0042fd10 after the scroll was consumed (dest = mapName)
                0x34CF NC_ITEMDB_RESET_SCROLL_LINK_MAP_INFO_CMD @ FUN_00430290 (dest = "", all 13 bytes zero)
                (both D03 §6.5), failure logged "… sp call fail SET MapLinkScrollDest charRegNum %u", no other effect
    binds     : 1 in ULONG→INTEGER +4; 2 in CHAR→WVARCHAR buf 0xd +8; 3 out SLONG→INTEGER +0 (not preset: the handlers
                zero it)
    result    : wrapper returns 1 when rc ∈ {0,1} (asm @ 0x460a6a), whatever @nRet is; @nRet ≠ 0 is only logged
                ("ERROR - CSQLPCharacter::usp_LinkScroll_SetDestMap nRet(%d), nCharNo(%d)")
    body      : SET NOCOUNT ON
                UPDATE tCharacter SET sLinkScrollDestMap = @sDestMapName WHERE nCharNo = @nCharNo   (column ours)
                SET @nRet = CASE WHEN @@ERROR = 0 AND @@ROWCOUNT = 1 THEN 0 ELSE -1 END
```

What the value is for *(inferred, strong)*: the zone sends 0x34CF at every `sp_NC_MAP_LOGINCOMPLETE_CMD` (zone
FUN_00443390, Z01 §6), i.e. the destination is cleared as soon as the character has arrived on any map. The only reader
that fits is the 37th column of `p_Char_GetAllData` that the 2016 Character server reads at login (D02 §4.1, D02-B19):
a 12-character map name that, when non-empty and in MapInfo, replaces the login map and puts the character on that map's
regen point. Together: a character that used a map-link scroll and dropped before arriving logs in on the destination
map. So the rebuild's column lives in `tCharacter` and `p_Char_GetAllData` returns it as its last column (part 4 of this
item, §6, settles the GetAllData side). The 2016 binary itself never compares anything despite the code name
`…COMPARE_MAP_REQ`; the 2017 name `RESET_SCROLL_LINK_MAP_INFO_CMD` describes what it does.

### 5.3 `p_Item_MiniHouse_Effect_Resource_Del` — pay a mini-house furniture effect

```pseudo
p_Item_MiniHouse_Effect_Resource_Del(@nOwner int in, @nNeedMoney bigint in, @nNeedItemKey bigint in,
        @nNeedItemOptionType smallint in, @nNeedItemLot int in, @nRet int out)
                                        (names pdb2016 CSQLPItem::SQL_ITEM_MINIHOUSE_EFFECT_RESOURCE_DEL)
    called by : SQL_p_Item_MiniHouse_Effect_Resource_Del @ FUN_00462e70 ← 0x347D NC_ITEMDB_MINIHOUSE_EFFECT_DEMANDGOOD_REQ
                @ FUN_0041a230 (D03 §7.6) ← zone sp_NC_MINIHOUSE_FURNITURE_EFFECT_REQ @ FUN_00574a30 (Z07 §6.10)
    binds     : 1 in ULONG→INTEGER +0 (charNo); 2 in UBIGINT→BIGINT +8 (nDemandMoney); 3 in UBIGINT→BIGINT +0x10 (item
                key); 4 in SSHORT→SMALLINT +0x18 = ItemLotOption(nDemandItemID) or 0xFFFE (sent as −2) when the item id is
                0xFFFF or the item has no lot option; 5 in ULONG→INTEGER +0x1c (nNeedItemLot); 6 out ULONG→INTEGER +0x20,
                preset −1
    result    : the wrapper returns @nRet without looking at rc (a failed call leaves −1). Handler: 0 → 0x1700 (zone plays
                the effect), 1 → 0x1702, 2 → 0x1703, 3 → 0x1704, 4 → 0x1705, 5 → 0x1706, other → 0x1701; the zone turns
                them into 0x8C41 codes 0x16D1…0x16D5 / 0x16D0 (Z05 §9.6; no client text in the error table)
    body (inferred from p_Item_Furniture_Endure_Update, Character.bak, "2008.10 By Lunar", the mini-house furniture
          procedure whose codes 1–5 match the five handled ones):
        SET NOCOUNT ON; SET @nRet = 0
        item = (@nNeedItemOptionType <> -2) OR the key is an item of @nOwner     -- see the money-only case below
        IF item:
            EXEC p_Item_IsValidOwner @nNeedItemKey, @nOwner, @t OUTPUT;  @t <> 0 → SET @nRet = @t (1 not found, 2 owner); RETURN
        BEGIN TRAN
        IF @nNeedMoney > 0: EXEC p_Char_MoneySub @nOwner, @nNeedMoney, @r OUTPUT; @r <> 1 → ROLLBACK, @nRet = 3, RETURN
        IF item:
            IF @nNeedItemOptionType = -2 OR @nNeedItemLot <= 1:
                 EXEC p_Item_Delete @nNeedItemKey, @r OUTPUT;  @r <> 0 → ROLLBACK, @nRet = 5, RETURN
            ELSE EXEC p_Item_SetOption @nNeedItemKey, @nNeedItemOptionType, @nNeedItemLot - 1, @r OUTPUT
                                                                          @r <> 0 → ROLLBACK, @nRet = 4, RETURN
        COMMIT
```

- The lot the zone sends is the stack's **current** lot (`local_8c` = the attribute's lot getter, before the zone's own
  `lot − 1` for its cell), so the procedure stores `lot − 1` or deletes the item at 1; the furniture family procedure
  instead receives the lot after use. Code meanings 1 / 2 / 3 / 5 follow that family procedure and `p_Item_IsValidOwner`;
  4 (lot write failed) is the remaining step *(inferred)*.
- **Money-only effects (original bug) D06-B2.** For an effect with a money cost and no item, the zone writes item id
  0xFFFF but leaves the key (+0xA…+0x11) and lot (+0x14) of its global send buffer unwritten (zone FUN_00574a30), so the
  Character server passes a stale key from the previous packet. The option type is −2 then, as for a real non-stackable
  item. A procedure that always checks the key fails the effect with 1 (or deletes an unrelated item of the same owner
  when the stale key happens to be one). The body above therefore treats "type −2 and the key not owned" as "no item";
  a rebuild of the zone should zero the key and lot.
- No source and no table needed beyond `tItem` / `tItemOptions` / `tCharacter.nMoney` (D03's tables).

### 5.4 `p_MiniHouseURL_Get`, `p_MiniHouseURL_Set` — the house owner's blog address

```pseudo
p_MiniHouseURL_Get(@nUserNo int in, @sURL nvarchar(254) out)        (names ours)
    called by : SQL_p_MiniHouseURL_Get @ FUN_0045aaa0 ← 0x8C39 NC_MINIHOUSE_DB_OWNERBLOG_GET_REQ @ FUN_00417ac0 (D03 §8)
    binds     : 1 in ULONG→INTEGER (by value on the stack); 2 **out** SQL_C_CHAR → WVARCHAR, bufferLength 0xff into the
                handler's zeroed 0x200 buffer, with a real indicator (preset SQL_NTS −3): the only output in this part
                that may be NULL — NULL leaves the buffer empty and still succeeds
    result    : ok = rc ∈ {0,1} (truncation is SUCCESS_WITH_INFO, so a longer URL arrives cut to 254 bytes). Handler: 0x8C3A
                Error 0x11DA with bloglen = min(strlen, 255) and the string; fail → 0x11DB ("Unable to navigate to room
                host's blog.")
    body      : SELECT @sURL = sURL FROM tMiniHouseURL WHERE nUserNo = @nUserNo        (no row → NULL → empty, ok)

p_MiniHouseURL_Set(@nUserNo int in, @sURL nvarchar(255) in)
    called by : SQL_p_MiniHouseURL_Set @ FUN_0045ab20 ← 0x8C3B NC_MINIHOUSE_DB_OWNERBLOG_SET_REQ @ FUN_00417c80
    binds     : 1 in ULONG→INTEGER; 2 in CHAR→WVARCHAR buffer 0xff (the request's `blogaddr` up to its NUL; `bloglen` is
                not used); no output parameter
    result    : ok = rc ∈ {0,1}; 0x8C3C 0x11DA, else 0x11DC ("Unable to save blog address.")
    body      : MERGE tMiniHouseURL (upsert sURL for nUserNo)
table *(ours)*: tMiniHouseURL (nUserNo int PRIMARY KEY, sURL nvarchar(255) NOT NULL)
```

- Keyed by the **user** (account) number, not the character: the request carries `nUserNo` (PDB 2017
  `PROTO_NC_MINIHOUSE_DB_OWNERBLOG_*_REQ`), and the call runs on the Character DB connection.
- Dead in 2016: no zone code sends 0x8C39 / 0x8C3B (`rg -w` in both zone exports, decimal too) and the zone has no handler
  for their answers; the client still has handlers for 0x8C36 / 0x8C38 (opcodes.json). Neither backup has a URL or blog
  column (only an old `tMiniHouse` with `sData`, unrelated to `tMinihouse`).

### 5.5 `p_Guild_SetMoney` — set a guild's money

```pseudo
p_Guild_SetMoney(@nNo int in, @nMoney bigint in, @nRet tinyint out)   (names pdb2016 CSQLPGuild::SQL_GUILD_SET_MONEY:
                                                                       nNo +0, __int64 nMoney +8, uchar nRet +0x10)
    called by : SQL_p_Guild_SetMoney @ FUN_00453e00 ← 0x74AA NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_REQ @ FUN_004076a0,
                reward types 2 ID_GUILD_MONEY and 5 ID_GUILD_MONEY_DIVISION (D04 §6.4), after p_Guild_Get
    binds     : 1 in ULONG→INTEGER +0; 2 in **SQL_C_ULONG** → BIGINT +8 (the low 32 bits of the new total:
                D04-B21); 3 out UTINYINT→TINYINT +0x10, preset 0
    result    : ok = rc ∈ {0,1} and @nRet == 1
    body (from p_Guild_SetExp / p_Guild_SetFame, Character.bak, "2006.2 By CJC", same signature shape):
        SET NOCOUNT ON; SET @nRet = 0
        UPDATE tGuild SET nMoney = @nMoney WHERE nNo = @nNo
        SET @nRet = @@ROWCOUNT;  IF @@ERROR <> 0 OR @nRet <> 1: SET @nRet = 0
```

The family's convention (`tinyint` 1 = ok, 0 = guild not found) is exactly what the wrapper tests; `tGuild.nMoney` is a
column `p_Guild_Get` returns. A rebuild that fixes D04-B21 binds `SQL_C_UBIGINT`; the procedure is the same.

### 5.6 `usp_GuildTournament_setRefundNotice` — mark a refund as announced

```pseudo
usp_GuildTournament_setRefundNotice(@nGTNo int in, @nNo int in, @nRet int out)
                                        (names pdb2016 CSQLPGuild::SQL_GUILD_TOURNAMENT_REFUND_NOTICE_SET)
    called by : SQL_usp_GuildTournament_setRefundNotice @ FUN_00455590 ← 0x74F9 NC_GUILD_TOURNAMENT_REFUND_NOTICE_DB_SET_REQ
                @ FUN_00408ae0 (D04 §6.4; no answer, failure logged) ← WM Client_SendRefundNotice FUN_00430e30 (W03 §8.4),
                right after it sent 0x74F8 NC_GUILD_TOURNAMENT_REFUND_NOTICE_CMD { u64 nRefundMoney } to a member of a
                guild whose entry was not chosen
    binds     : 1 in ULONG→INTEGER +0; 2 in ULONG→INTEGER +4; 3 out ULONG→INTEGER +8, preset 0
    result    : ok = rc ∈ {0,1} and @nRet == 0 (asm @ 0x45568b); log string "CSQLPGuild::usp_GuildTournament_Refund_Notice_Set"
    body (family: Ko Dong Gyun's usp_GuildTournament_* 2009, codes −1411 / −1412 / −1493):
        SET NOCOUNT ON; SET @nRet = 0
        IF ISNULL(@nGTNo,0) <= 0: SET @nRet = -1411; RETURN;   IF ISNULL(@nNo,0) <= 0: SET @nRet = -1412; RETURN
        UPDATE tGuildTournamentRegist SET bIsRefundNotice = 1 WHERE nGTNo = @nGTNo AND nNo = @nNo
        IF @@ERROR <> 0: SET @nRet = -1493
```

- `bIsRefundNotice` is a 2016 column the backups' `tGuildTournamentRegist (nGTNo, nNo, nMoney, nSeed, bChoice, dDate)` does
  not have (constraint names `DF__tGuildTou__nSeed`, `__bChoi`, `__dDate`; `bak.py names` / UTF-16 scan of Character.bak).
  The 2016 `getRegistList` returns it as the 4th column (§5.7) and the WM keeps it as `GT_EnterList.bIsRefundNotice`
  *(pdb2016: WorldManager.pdb and Zone.pdb `GT_EnterList { nGuildNo, bIsChoice, bIsRefundNotice, nRefundMoney }`; W03 §8.1)*. Column name ours, taken from that member.
- **Who pays the refund (original bug, inferred) D06-B3.** The WM broadcasts the unchosen entries to all zones as
  0x74F4 NC_GUILD_TOURNAMENT_GOLD_REFUND_ZONE_CMD, but the 2016 zone handler is empty (Z08 §8.2, LAB_00476c00), and none of
  the Character-server procedures on the refund path receives money or a character (`setRefundNotice` has only tournament
  and guild). Unless the lost 2016 `usp_GuildTournament_setChoice` paid the fee back itself (the backups' version only sets
  `bChoice`, §5.7), no 2016 component returns the money that 0x74F8 announces. `tGuildTournamentRegist` keeps no
  character number, so a DB-side refund could only go to the guild (`tGuild.nMoney`) *(inferred)*. A rebuild should pay
  it in `setChoice` (to the guild) or implement the zone's 0x74F4.

### 5.7 D04 version mismatches

**`usp_GuildTournament_setRegist` (D04 §6.4, 0x74E5): −1424 and the money.** `bak.py` shows the w00 body as truncated, but
the full text is in `w00_Character.bak` (UTF-16 at file offset 0x43ca68, again at 0x43d1ee). It adds, after the
level / member check (comment "2011.8.22 by kodong"):

```sql
SELECT TOP 1 @prevGTNo = nGTNo FROM tGuildTournament WHERE nGTNo < @nGTNo ORDER BY nGTNo DESC
IF @prevGTNo IS NOT NULL BEGIN
    SELECT @prevWinnerNo = nGuildNo FROM tGuildTournament
     WHERE nGTNo = @prevGTNo AND nType >= 3028 AND nType <= 3029 AND nData = 1
    IF @prevWinnerNo = @nNo BEGIN SET @nRet = -1424 RETURN END
END
```

So **−1424 (→ 0x1C47) = the guild won the previous tournament** and may not register for the next one: rows 3028 / 3029
are `3000 + slot` result rows of the final pair (slots 28 / 29, W03 §8.4: the last round is pair 28) and `nData = 1` is a
win (`usp_GuildTournament_setResult`, D04 §6.4). The 2016 handler maps exactly −1421…−1424, so the 2016 procedure is the
w00 version (Character.bak's 2009 version lacks −1424). Both versions take the fee in the same transaction (`EXEC
p_Char_MoneySub @nCharNo, @nMoney` → −1423 on failure) before inserting `(nGTNo, nNo, nMoney, nSeed = RAND()·100000)`:
the DB does charge the character, and the zone's `lock.apply` on 0x1C40 (Z08 §8.2) mirrors it in memory (the usual
DB-first money pattern).

**`usp_GuildTournament_getRegistList`.** Character.bak and w00 have the same 2009 body: `SELECT nNo … WHERE nGTNo =
@nGTNo` (−1411 for an invalid number). The 2016 readers fetch four columns: U32 guild, 64-bit money (I64 in 0x7485 / 0x74EB,
U64 in 0x74F6), and two flags (U8 in 0x74EB, I32 in 0x74F6) = `GT_EnterList {nGuildNo, bIsChoice, bIsRefundNotice,
nRefundMoney}`. A rebuild returns

```sql
SELECT nNo, nMoney, CAST(bChoice AS tinyint), CAST(bIsRefundNotice AS tinyint)
  FROM tGuildTournamentRegist WITH (NOLOCK) WHERE nGTNo = @nGTNo
```

(`tinyint` converts to both U8 and I32; the column order is the fetch order, the money column carries the refund amount
= the paid fee *(inferred)*.)

**`usp_Character_getKeyMap` −2721 / −2725 (D04 §5.2, 0x7057).** The w00 procedure (Ko Dong Gyun 2010.09.13) returns no
result set and `@nRet = −2725` when the character has no `tCharacterKeyMap` rows; −2721 is the family's "not found
nCharNo" (`usp_Character_getShortCutList`, same author and date). The 2016 handler only skips its log line for −2721;
both values give the same behaviour (no answer, D04-B14). The second caller is the login-time loader
`GetCharOptionImprove_KeyMapData` @ FUN_00422660 (called by `SendCharOption_Improve_Data` @ FUN_004354b0, D02 §4 step 20):
on a failed call it logs unless `nRet == −2721` and returns 0 (asm `xor eax,eax`), so no 0x702E key-map packet is sent and
the following game-option step is skipped ("FAILED - GetCharOptionImprove_KeyMapData"); on success it sends 0x702E
`{u32 nCharNo, u16 n, KEY_MAP_DATA[n] {u16, u8, u8}}` (at most 0x5F rows; returns the send result). Again −2721 and −2725
differ only in the log line. For a rebuild the difference is cosmetic; −2721 keeps the 2016 log quiet. After `usp_Character_initKeyMap` the rows always exist unless `tKeyMapInit` is empty.

**`usp_GuildAcademy_withdrawMoney` 1–6 (D04 §9.3, 0x986B).** Both backups (2008.5.14, w00 adds `UPDLOCK, HOLDLOCK`
2011.7.11) return 0 or −1511 / −1512 / −1514 / −1524 / −1525 / −1527 / −1593. The 2016 wrapper (@ FUN_00456510) passes
`nRet` through unchanged, and the handler switches on 1…6 (→ 0xF99…0xF9E), other → 0xF98. So the 2016 procedure had
positive codes; their order most likely follows the six checks in the procedure *(inferred, weak)*: 1 invalid guild
number, 2 invalid character number, 3 invalid amount, 4 character not found / deleted, 5 academy not found, 6 not enough
academy money; a DB error falls to 0xF98. In 2016 the handler only calls it with `0 < amount ≤` the money it has just
read (D04 §9.3), so only 6 (concurrent withdrawal) and DB errors are reachable. A rebuild can keep the w00 body and map
its negative codes to 1–6 in that order; nothing outside the Character server sees the codes except 0x986C's `Error`.

## 6. Character DB (`w00_Character`), Character server: loading reports, login data, friend points, promotion, free stats

Same conventions as §5 (Character exe has no PDB: parameter names come from the packet structs of the WM / Zone 2016
PDBs *(pdb2016)* or, where those lack them, the 2017 client PDB *(pdb2017)*, the backups' older procedure, the binary's log strings, or are *(ours)*). Wrapper return values were read
from the asm epilogues (Ghidra shows most of them as `void`).

### 6.1 Loading-failure reports: `usp_CharacterLoading` (11 vs 6), `usp_CharacterLoadingDetailInfo`

The client reports a failed map load (0x0840, W04 §17.3); the WM adds `nCharNo` and `nWorldTime = time(NULL)` and forwards
it as `0x0841 NC_MISC_DB_CLIENT_LOADING_BUG_DETECT_CMD` (D02 §5); the Character server stores it and answers nothing.

```pseudo
usp_CharacterLoading(@nCharNo int in, @dWorldTime datetime in, @sLoadingMapName varchar(16) in, @nFailType smallint in,
                     @nLoadingFailCnt smallint in, @sFromMapName varchar(16) in, @sFromZoneIP varchar(16) in,
                     @sToZoneIP varchar(16) in, @nToZonePort smallint in, @nSeqNo int out, @nRet int out)
                     (names: inputs 3–9 = PROTO_NC_MISC_DB_CLIENT_LOADING_BUG_DETECT_CMD members (pdb2016, WorldManager.pdb); 1–5 and
                      @nRet = the backups' 6-parameter procedure; @nSeqNo = its local variable / key column)
    called by : SQL_usp_CharacterLoading @ FUN_0045c360 (log name `CSQLPCharacter::p_Set_Client_Loading_Bug_Detect`)
                ← 0x0841 @ FUN_00420b80 (D02 §5)
    binds     : 1 in ULONG→INTEGER +0 (nCharNo); 2 in TIMESTAMP→TIMESTAMP (11/11) +4 = localtime(nWorldTime), fraction 0;
                3 in CHAR→VARCHAR buf 0x10 +0x14; 4 in USHORT→SMALLINT +0x24; 5 in USHORT→SMALLINT +0x26;
                6 in CHAR→VARCHAR buf 0x10 +0x28; 7 +0x38 and 8 +0x48 the same (16-byte IP strings);
                9 in USHORT→SMALLINT +0x58; 10 out SLONG→INTEGER +0x5C (handler presets 0); 11 out SLONG→INTEGER +0x60
                (wrapper presets 0)
    result    : wrapper returns 1 iff rc ∈ {0,1} and @nRet == 0 (asm: `mov eax,1` @ 0x45c608, else `xor eax,eax`
                @ 0x45c5ce); otherwise logs "ERROR - …p_Set_Client_Loading_Bug_Detect, ret(%d), nRet(%d)" plus the SQL
                diagnostics. On 1 the handler passes @nSeqNo to one DetailInfo call per error entry; on 0 none.
    reads/writes: tCharacterLoading (2016 columns below)
    body      : SET NOCOUNT ON; SET @nSeqNo = 0; SET @nRet = 0
                BEGIN TRAN
                SELECT TOP 1 @nSeqNo = nSeqNo FROM tCharacterLoading WITH (UPDLOCK, HOLDLOCK)
                 WHERE nCharNo = @nCharNo ORDER BY nSeqNo DESC
                SET @nSeqNo = @nSeqNo + 1
                INSERT tCharacterLoading (nCharNo, nSeqNo, dWorldTime, sLoadingMapName, nFailType, nLoadingFailCnt,
                                          sFromMapName, sFromZoneIP, sToZoneIP, nToZonePort)
                VALUES (@nCharNo, @nSeqNo, @dWorldTime, @sLoadingMapName, @nFailType, @nLoadingFailCnt,
                        @sFromMapName, @sFromZoneIP, @sToZoneIP, @nToZonePort)
                IF @@ERROR <> 0: SET @nRet = -1001; ROLLBACK; RETURN
                COMMIT
    evidence  : the numbering, the insert and −1001 are the backups' body ("char loading save, 2009.6 By Luunar",
                identical in Character.bak and w00_Character); the four extra inputs are what the 2016 handler binds; the
                output @nSeqNo is required because the handler reuses parameter 10 as the detail rows' key (inferred);
                the lock hint is ours (several Character-server workers may store reports of one character at once).

usp_CharacterLoadingDetailInfo(@nCharNo int in, @nSeqNo int in, @nErrorNo smallint in, @nErrorData int in, @nRet int out)
                     (names: CLBD_ErrorData { u16 nErrorNo, u32 nErrorData } (pdb2016, WorldManager.pdb), the parent's key)
    called by : SQL_usp_CharacterLoadingDetailInfo @ FUN_0045c620 (log name `…p_Set_Client_Loading_Bug_Detec_Error_Data`)
                ← 0x0841 @ FUN_00420b80, once per ErrorData entry (6-byte entries from packet +0x4A, count at +0x48)
    binds     : 1 in ULONG→INTEGER +0 (nCharNo); 2 in SLONG→INTEGER +4 (@nSeqNo of the parent call); 3 in USHORT→SMALLINT
                +8; 4 in ULONG→INTEGER +0xC; 5 out SLONG→INTEGER +0x10, preset 0
    result    : same rule as the parent (1 iff rc ∈ {0,1} and @nRet == 0, asm @ 0x45c82c); the handler ignores it and
                tries every entry
    body      : SET NOCOUNT ON; SET @nRet = 0
                INSERT tCharacterLoadingDetailInfo (nCharNo, nSeqNo, nErrorNo, nErrorData)
                VALUES (@nCharNo, @nSeqNo, @nErrorNo, @nErrorData)
                IF @@ERROR <> 0: SET @nRet = -1002          (code ours, in the family's −100x range)
    evidence  : no source anywhere; the table and the code are ours, the columns are the bound values.
```

2016 tables (the backups' `tCharacterLoading` has only the first six columns):

| Table | Columns | Source |
|---|---|---|
| `tCharacterLoading` | nCharNo int, nSeqNo int (per character, 1, 2, …), dWorldTime datetime, dDBTime datetime = getdate() (not bound), sLoadingMapName varchar(16), nFailType smallint, nLoadingFailCnt smallint, PK `PK_tCharLoading` (nCharNo, nSeqNo) (restore, §9.3), **sFromMapName varchar(16), sFromZoneIP varchar(16), sToZoneIP varchar(16), nToZonePort smallint**; key (nCharNo, nSeqNo) | first six *(db-backup)*; bold ones from the 2016 binds, names *(pdb2016)*, types ours; no key constraint name in the backups |
| `tCharacterLoadingDetailInfo` *(ours)* | nCharNo int, nSeqNo int, nDetailNo int identity, nErrorNo smallint, nErrorData int; key (nCharNo, nSeqNo, nDetailNo) | the bound values; one row per CLBD_ErrorData entry, several per report, hence the identity |

Values that make the insert fail, all from the client without a check *(inferred from the ODBC conversion rules)*:
`nFailType`, `nLoadingFailCnt`, `nToZonePort` ≥ 0x8000 or `nErrorData` ≥ 2³¹ overflow `SMALLINT` / `INTEGER` (SQLSTATE
22003, call fails, the report or detail row is lost and logged). The map names are copied 12 bytes + 4 zero bytes and so
always terminated, but the two IP strings are copied as 16 raw bytes and bound as NUL-terminated: a client that fills all
16 bytes makes the driver read `sFromZoneIP` on into `sToZoneIP`, and `sToZoneIP` on into the port and the zeroed
`@nSeqNo` (at most 20 characters), so garbage is stored or the call fails on truncation (original bug) D06-B4. A normal
client sends dotted IPv4 text (≤ 15 characters). What the client's `nFailType` / `nErrorNo` values mean was not traced
(diagnostics only; no server logic depends on them).

### 6.2 `p_Char_GetAllData` column 37 (D02-B19): the map-link scroll destination

D02 §4.1 reads 37 columns; both backups' procedure ("2004.6 By CJC") returns 36. Column 37 is read with `DB_GetStr` into a
21-byte zeroed buffer; when it is not `""` (compare @ FUN_0046bf70 with the empty string at 0x4b6667) and the name is
in the map table (`ItemIndex_ToId(&DAT_006ecf7c, name)`, a generic name index; row +0x32 / +0x36 = regen X / Y), it
replaces `currentmap` and the coordinates (@ FUN_0046e2e0).

**Settled *(inferred, strong)*: column 37 = `tCharacter.sLinkScrollDestMap` *(ours)*, the value `usp_LinkScroll_SetDestMap`
writes (§5.2).**

- It is no column of the backups' `tCharacter`: the other map columns are `sLoginZone` (column 17) and `sKQMap`, which the
  2016 binary reads separately (`{CALL p_Char_GetKQMap(?)}` @ FUN_0045a130; `nKQHandle, sKQMap, nKQX, nKQY, nKQD,
  dKQDate`, present in both backups). No backup has a column or text containing `LinkScroll`, `DestMap`, `MapLink` or
  `ReturnMap` (UTF-16 scan of both Character backups).
- `usp_LinkScroll_SetDestMap` is the only 2016 write of a map name that nothing reads back, and column 37 the only
  read of a map name that nothing writes; both are 12-byte map names (`Name3`), and both call strings are already in the
  2015 Character binary (same feature generation).
- The life cycle fits the override: written when a map-link scroll is consumed (0x34C9), cleared at every arrival on a
  map (0x34CF from the zone's `sp_NC_MAP_LOGINCOMPLETE_CMD`). Only a character that disconnects between using the scroll
  and arriving has a value at its next login, and it then starts at the destination map's regen point.

So D02-B19 is a backup mismatch, not a 2016 bug. A rebuild:

```pseudo
ALTER TABLE tCharacter ADD sLinkScrollDestMap varchar(16) NOT NULL DEFAULT ''     (ours; '' = none)
p_Char_GetAllData(@nCharNo int): the backups' SELECT plus, as the 37th item after dDeletedDate,
    ISNULL(sLinkScrollDestMap, '') AS sLinkScrollDestMap
```

Type: `DB_GetStr` passes the column's `SQL_DESC_LENGTH` as the buffer length, so the declared length must stay ≤ 20 to
fit the 21-byte buffer; `varchar(16)` matches the `sLoginZone` and `sKQMap` columns (restore, §9.3; the backups' position-save
procedure declares its parameters `@sLoginZone nvarchar(16)`, `@sKQMap nvarchar(16)`, which convert). A NULL value would make `SQLGetData` fail (no indicator, 22002) and leave the buffer empty,
also "no override", but NOT NULL keeps it clean.

### 6.3 `usp_Character_setFriendpoint` (2 markers, 3 binds) and `usp_Character_getFriendpoint`

```pseudo
usp_Character_setFriendpoint(@nCharNo int in, @nFriendPoint int in, @nRet int = 0 out)     (w00, "JK CHO 2014.8.19")
    called by : SQL_usp_Character_setFriendpoint @ FUN_00460710 ← 0x1036 login @ FUN_00405810 (+1 for every friend, D02 §5) and
                0x34BF NC_ITEMDB_UES_FRIEND_POINT_REQ @ FUN_0042ef20 (points − item cost, D03)
    binds     : 1 in ULONG→INTEGER +0; 2 in SLONG→INTEGER +4; 3 out SLONG→INTEGER +8, preset 0 — but the call string is
                `{CALL usp_Character_setFriendpoint(?,?)}` (two markers, also in the 2015 binary)
    result    : 1 iff rc ∈ {0,1} and the buffer +8 == 0 (asm 0x460801–0x460808)
usp_Character_getFriendpoint(@nCharNo int in, @nRet int = 0 out) → row { nFriendPoint int }  (w00, same author/date)
    called by : SQL_usp_Character_getFriendpoint @ FUN_00460600 (same two callers); binds 1 in ULONG→INTEGER, 2 out SLONG
                preset 0; result 1 iff rc ∈ {0,1} and the buffer == 0 (asm 0x4606d7–0x4606de); then DB_Fetch + DB_GetI32
```

- **D02-B8 confirmed for the w00 body, and harmless there.** Only the two marked parameters reach the server *(inferred:
  ODBC sends parameters by marker number; parameter 3 has none)*; w00 declares `@nRet int = 0 output`, so the
  two-argument call is legal and the procedure's `@nRet` stays local. The wrapper therefore tests its own preset 0 and
  succeeds whenever the call executes. What is lost: `@nRet = −1111` (no such character) and `1` (`@@ROWCOUNT ≠ 1` after
  the `EXISTS` check, only possible when the character is deleted in between). A real SQL error (deadlock, the
  connection's 5000 ms `LOCK_TIMEOUT`, §7.3, error 1222) still reaches the wrapper as `SQL_ERROR` *(inferred)*. So the friend
  point updates behave as designed.
- The default is **required**: without `= 0` the call fails with error 201 ("expects parameter '@nRet'") on every
  update, and neither the daily +1 nor the item exchange ever writes. A rebuild keeps the w00 signature exactly.
- `getFriendpoint` tests `@nRet` right after `SQLExecDirect`, before fetching its row. That test is **not** dead: the
  w00 body returns a result set only when the character exists; for a missing character it only sets `@nRet = −1111`
  (no SELECT, `NOCOUNT ON`), so the call has no result set and the output arrives with `SQLExecDirect` (§1.2 driver
  rule). The wrapper then logs "ERROR - CSQLPCharacter::usp_Character_getFriendpoint, nRet(…)" and returns 0: 0x34BF
  @ FUN_0042ef20 logs "…usp_Character_getFriendpoint : CharNo" and answers 0x34C0 with 0x36C2, and the 0x1036 login
  caller FUN_00405810 takes its failure branch. On the success path `@nRet` is 0 anyway, so the early test changes
  nothing. `usp_Character_GetDiffFriendpoint` (0x1004, D02 §4) has the same shape and the same correct behaviour.

### 6.4 Promotion: `p_IsPromotionUser`, `p_Promotion_Get`, `p_Promotion_Set` (dead in 2016)

No 2016 component sends `0xA001 NC_PROMOTION_USER_REQ` or `0xA004 NC_PROMOTION_DB_REWARD_REQ`: no opcode literal, no
`.sends` entry and no `NC_PROMOTION_*` string in the login, WM or zone exports; the WM only handles the answers (0xA002
no action, 0xA005 → client 0xA006, W01 §6.2). Even an arriving 0xA004 never reaches Get / Set (the reward table is never
loaded, D02-B18). The three procedures are specified only so that the handlers have a contract.

```pseudo
p_IsPromotionUser(@nUserNo int in, @bIsPromotion tinyint out, @nRet int out)
                     (bIsPromotion = PROTO_NC_PROMOTION_USER_ACK member (pdb2017); others ours / family style)
    called by : SQL_p_IsPromotionUser @ FUN_0045b710 ← 0xA001 @ FUN_0041ef50 (D02 §13)
    binds     : 1 in ULONG→INTEGER (copy of nUserNo); 2 out SQL_C_TINYINT→TINYINT into the handler's byte (preset 0);
                3 out SLONG→INTEGER preset 1
    result    : ok iff rc ∈ {0,1} and @nRet == 0 → 0xA002 DBError 0x1848, else 0x1849; bIsPromotion is sent either way
    body      : SET NOCOUNT ON
                SET @bIsPromotion = CASE WHEN EXISTS (SELECT 1 FROM tPromotionUser WHERE nUserNo = @nUserNo) THEN 1 ELSE 0 END
                SET @nRet = 0                                  (tPromotionUser ours: nUserNo int PRIMARY KEY, dDate datetime)
    evidence  : binds and codes only. What made an account a "promotion user" (an event registration) is in no backup;
                the Character DB is per world, so the flag is per world account (inferred).

p_Promotion_Get(@nUserNo int in, @nRewardLV tinyint in, @nWorldNo tinyint in, @nCharNo int out, @dRewardDate datetime out)
    called by : SQL_p_Promotion_Get @ FUN_0045b7b0 ← 0xA004 @ FUN_0041eff0 (D02 §13)
    binds     : 1 in ULONG→INTEGER +0 nUserNo; 2 in SQL_C_TINYINT→TINYINT +4 = request nLevel; 3 the same +5 = request
                nWorldNo; 4 out ULONG→INTEGER +8, preset −1; 5 out TIMESTAMP +0xC (16 bytes, never read)
    result    : ok iff rc ∈ {0,1} and @nCharNo ≠ −1. ok and @nCharNo == 0 → not rewarded yet, items are created;
                ok and any other value → 0x1856 (already rewarded by that character); not ok → 0x1856 as well
    body      : SET NOCOUNT ON; SET @nCharNo = 0; SET @dRewardDate = '1900-01-01'
                SELECT @nCharNo = nCharNo, @dRewardDate = dDate FROM tPromotionReward
                 WHERE nUserNo = @nUserNo AND nRewardLV = @nRewardLV AND nWorldNo = @nWorldNo
                (tPromotionReward ours: nUserNo int, nRewardLV tinyint, nWorldNo tinyint, nCharNo int, dDate datetime,
                 PRIMARY KEY (nUserNo, nRewardLV, nWorldNo))
    evidence  : "none" must be 0, not NULL (−1 = failure, NULL breaks the call: §1.2); the parameter order level-before-
                world is the struct the handler fills (+4 = byte 0xC of the request = nLevel, +5 = byte 6 = nWorldNo)
                and the order of the Set failure log "nUser=%d, nRewardLV=%d, nWorld=%d, nCharNo=$d", which also gives
                the name nRewardLV.

p_Promotion_Set(@nUserNo int in, @nRewardLV tinyint in, @nWorldNo tinyint in, @nCharNo int in, @nRet int out)
    called by : SQL_p_Promotion_Set @ FUN_0045b890 ← 0xA004 after every reward item was created
    binds     : 1–3 as Get; 4 in ULONG→INTEGER +8 = request nCharNo; 5 out SLONG→INTEGER preset −1
    result    : ok iff rc ∈ {0,1} and @nRet == 0; failure is only logged ("…But reward is successed…"), the 0xA005
                answer still lists the items
    body      : SET NOCOUNT ON
                INSERT tPromotionReward (nUserNo, nRewardLV, nWorldNo, nCharNo, dDate) VALUES (…, GETDATE())
                SET @nRet = CASE WHEN @@ERROR = 0 THEN 0 ELSE -1 END     (a key violation = already rewarded)
```

Get and Set are separate calls around the item creation, not one transaction: two 0xA004 of one account handled by two
workers at once would both read 0 and both grant the items; the second Set then fails on the key and is only logged
(original bug) D06-B5, in a path that is dead in 2016.

### 6.5 `usp_Character_setStatPoint` −1091 / −1092 / −1094

The binary's switch on `@nRet` (@ FUN_004135e0, jump table @ 0x4137c4) has one group for −1091…−1094 (cases −0x443…
−0x446): log `자유스탯 설정 에러 : DB_ERROR CharNo %d ErrorNo %d` ("free-stat set error: DB_ERROR", string @ 0x4b0614)
and return without `0x10D2` (D02-B10). The other codes have their own log texts, which confirm D02's reading of the
backup body: −1024 "no init item" (→ 0xAC6), −1023 "can not delete item" (0x1094), −1022 "item lot" (0x1096), −1021
"delete item lot" (0x1097), −1014 "not find char" (asm 0x413948–0x41399a).

- Both backups' body (identical, "Ko Dong Gyun 2010.10.21") produces −1093 for the failed `UPDATE tCharacter`. −1091,
  −1092 and −1094 occur in no procedure of either Character backup (UTF-16 scan for `1091`, `1092`, `1094`).
- So −1091…−1094 is the DB-error class of the procedure; the 2016 body most likely had three more DB-error exits
  numbered there (e.g. around the item writes, which the backup body reports as −1022 / −1023) *(inferred)*.
- All four behave identically in the binary, so a rebuild can take the backup body unchanged: no visible behaviour
  depends on which DB-error number is returned. Left open: which statements produced −1091 / −1092 / −1094.

## 7. SQL built at run time (all four DB servers)

`bak.py cover` lists the procedures whose `{CALL …}` text is a literal string. This section lists every SQL statement
the four binaries build at run time, so that together with `cover` the inventory is complete.

### 7.1 Inventory: how the four servers reach SQL Server

- **One entry point.** All four executables import from `ODBC32.dll` only by ordinal, and the only execute function among
  them is `SQLExecDirect` (ordinal 11). There is no `SQLPrepare` (19) and no `SQLExecute` (12) in any import table
  (`objdump -p`, Character: 9 10 11 13 16 24 26 27 29 31 39 41 43 72 75; Account: the same without 27). The `Ordinal_11` /
  `Ordinal_19` calls with one or four arguments in the decompiled code are `WS2_32.dll` ordinals 11 / 19 (`inet_addr`,
  `send`; the three `Ordinal_19` calls of Character are the gSOAP sender @ FUN_0048bf40), not SQL.
- **Every `SQLExecDirect` call site whose statement is not one string literal** (scan of the `Ordinal_11(stmt, str, -3)`
  calls, `SQL_NTS` = −3):

| Binary | Site | Statement | Covered |
|---|---|---|---|
| Character | `SQL_p_Char_SetStateWithSetItemAndRestTime` @ FUN_00460ee0 | built by `SQL_BuildCallString` @ FUN_00460bf0 | §7.2 |
| Character | `DBRecord::query` @ FUN_0044fb00 | `vsprintf` of the caller's format | §7.3 |
| Account | `DBRecord::query` @ FUN_00412410 *(pdb2016)* | same | §7.3 |
| AccountLog | `DBRecord::query` @ FUN_0040e4a0 *(pdb2016)* | same | §7.3 |
| GameLog | `DBRecord::query` @ FUN_00413f70 | same | §7.3 |
| Character | @ FUN_00458480 | `p_Char_GetListOfUserChar( ? )` / `p_Char_GetListOfUserCharAll( ? )` by flag | literals: `cover` lists both, source in both backups, same count (D02 §3.1) |
| Character | @ FUN_0045b470 | `p_Char_Wedding_Divorce_Do(?,?,?)` / `…_by_Item(?,?,?)` | same (D02 §11) |
| Character | @ FUN_00461270 | `p_Item_Create(…7)` / `p_Item_Create_UseEmptyStorage(…7)` | same (D03 §1.2) |
| Character | @ FUN_00461fc0 | `p_Item_SetStorageAndOwner(…5)` / `…_UseEmptyStorage(…5)` | same (D03 §1.2) |

- **Strings.** Apart from the literal `{CALL name(…)}` texts, the only SQL-looking strings in the four `strings.tsv` are
  `"{CALL "` @ 0x4c5a3c and `"p_Char_SetStateWithSetItemAndRestTime"` @ 0x4c5b24 (both §7.2). `"DELETE"` / `"DELETE "`
  in Character (@ FUN_004825e0, FUN_00484d00) are gSOAP HTTP method names; no `SELECT` / `INSERT` / `UPDATE` / `EXEC`
  text exists. So no ad-hoc SQL statement exists in any 2016 DB server.
- Same in 2015: the 2015 Character executable has the same `"{CALL "` + name strings and the same 312 `{CALL ` literals
  (diff only).

### 7.2 `p_Char_SetStateWithSetItemAndRestTime` — save one abnormal state (buff) of a character

The only procedure whose call string is assembled at run time. `SQL_BuildCallString(out std::string, name, n)` @
FUN_00460bf0 writes `"{CALL " + name + "(" + "?" + ",?" × (n−1) + ")}"` into a `std::stringstream` (no `?` for n = 0)
and returns its `str()` (@ FUN_00460bc0). Its one caller passes n = 0x15, so the statement is
`{CALL p_Char_SetStateWithSetItemAndRestTime(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)}`: 21 markers, 21 binds.

```
p_Char_SetStateWithSetItemAndRestTime(
    @nCharNo int in, @nStateNo smallint in, @nStateLevel smallint in, @nStateTime int in, @nRestTime int in,
    @nStateCount smallint in, @nStatePowerDemage tinyint in, @nStatePowerSP tinyint in,
    @nStatePowerKeepTime tinyint in, @nStatePowerCoolTime tinyint in,
    @nSetItemIndexA smallint in, @nSetItemValueA smallint in, … @nSetItemIndexd smallint in, @nSetItemValueD smallint in,
    @nCasterLevel smallint in, @nCasterAttackPower int in, @nRet int out)
    called by  : SQL_p_Char_SetStateWithSetItemAndRestTime @ FUN_00460ee0 ← CharSaveState @ FUN_00406070
                 ← fc_NC_CHARSAVE_ABSTATE_REQ 0x4007 @ FUN_00406850 (D02 §6, once per ABSTATEREADBLOCK row,
                 after p_Char_DelStateAll)
    binds      : 1 in C −16 → INTEGER   nCharNo                      (struct +0x00)
                 2 in C −17 → SMALLINT  nStateNo   = abstateid        (+0x04)
                 3 in C −17 → SMALLINT  nStateLevel = strength (u8 widened)   (+0x06)
                 4 in C −16 → INTEGER   nStateTime = pasttime          (+0x08)
                 5 in C −16 → INTEGER   nRestTime  = resttime          (+0x0C)
                 6 in C −17 → SMALLINT  nStateCount = restcount        (+0x10)
                 7–10 in C −28 → TINYINT the four 4-bit nibbles of SKILL_EMPOWER (bits 0–3, 4–7, 8–11, 12–15)
                                          = nStatePowerDemage / SP / KeepTime / CoolTime   (+0x12…+0x15)
                 11–18 in C −17 → SMALLINT setitem[0..3].Index / .Value   (+0x16…+0x24)
                 19 in C −17 → SMALLINT nCasterLevel = CasterInfo.nLevel (u8 widened)   (+0x26)
                 20 in C −17 → INTEGER  nCasterAttackPower = low 16 bits of CasterInfo.nAttackPower   (+0x28)
                 21 out C −16 → INTEGER nRet, preset −1
    result     : SQLExecDirect not 0/1 → ViewDBError("CSQLPCharacter::p_Char_SetState", stmt) @ FUN_00451ec0 (log only).
                 Then: nRet ∉ {0, 2627} → log "ERROR, CSQLPCharacter::p_Char_SetStateWithSetItem, nCharNo=%d, …, nRet=%d …"
                 Returns AL = (nRet == 0 || nRet == 2627)   (asm 0x46119c–0x46124e: 2627 forced to 0, then sete)
                 → on false CharSaveState logs "ERROR - CharSaveState SetState, nCharNo=%d, nStateNo=%d, …" and clears its
                   "all saved" flag (0x4008 not sent, D02)
    reads/writes: tCharacterState (nCharNo, nStateNo) primary key (PK__tCharacterState__…), all columns below
    body (w00_Character.bak, "2008.06 By Lunar", caster columns added "2011.10.19 by kodong"):
        IF EXISTS (row nCharNo, nStateNo): UPDATE every column = the parameter
        ELSE INSERT the row
        SET @nRet = @@ERROR
    evidence   : binds and return read in the wrapper and its asm; field mapping from the copy loop in CharSaveState
                 (asm 0x40615a–0x406240) and ABSTATEREADBLOCK (2016 zone PDB, 0x24 bytes: abstateid u16, strength u8,
                 pasttime / resttime u32, restcount u16, empower u16 @ +0x0D, CasterInfo {u8 nLevel, int nAttackPower}
                 @ +0x0F, setitem[4] {u16 Index, u16 Value} @ +0x14) (pdb2016)
```

- **Version: follow w00.** w00_Character.bak has exactly the 21 parameters in the bind order and types above. Character.bak
  has an older 19-parameter text (no `@nCasterLevel` / `@nCasterAttackPower`, found as ASCII text by a raw scan; `bak.py
  proc` does not find it): the 2016 call would fail with "too many arguments" on every row, so no buff would ever be
  saved. w00 also has the uncalled siblings `p_Char_SetState`, `p_Char_SetStateWithRestTime`, `p_Char_SetStateWithSetItem`
  (no 2016 caller; the log label `p_Char_SetState` / `p_Char_SetStateWithSetItem` in the wrapper is a leftover name).
- **2627 = SQL Server error 2627, PRIMARY KEY violation.** The wrapper accepts it as success: the `EXISTS` check and the
  `INSERT` are not atomic, so a second save of the same state racing in between (two workers saving the same character)
  hits the key; the row then exists, which is the wanted result *(inferred)*. Within one packet this cannot happen:
  `p_Char_DelStateAll` runs first and a repeated `abstateid` takes the `UPDATE` branch. Whether the driver delivers
  `@nRet` after a statement error inside the procedure is not certain (the statement returns an error record first); the
  wrapper does not depend on it: on `SQL_ERROR` it only logs and then tests `@nRet` as delivered (still −1 = failure if
  not) *(inferred)*.
- `nCasterAttackPower` is truncated *(original bug)* D06-B6: CharSaveState copies only the low 16 bits of the 32-bit
  `CasterInfo.nAttackPower` (`movzx edx, word ptr [eax+0x18]`, asm 0x4061e9) and the wrapper binds it as `SQL_C_USHORT`,
  although the column and the parameter are `int`. The loader truncates too: FUN_0046c6e0 (the
  `p_Char_GetStateAllWithSetItemAndRestTime` reader, §8.5) fetches column 19 `nCasterAttackPower` with `DB_GetU16` and
  stores it zero-extended into the 32-bit field (+0xe of the state entry), and column 18 `nCasterLevel` with `DB_GetU16`
  stored as a byte (+0xd). So the round trip is 16-bit both ways: a caster attack power ≥ 65536 or negative comes back
  modulo 65536, and a damage-over-time state restored at the next login deals damage from the wrong attack power
  *(inferred)*. Likely intent: bind and fetch the full `int` (fixing only the save would still reload a cut value). A
  rebuild's procedure is unaffected (the value arrives already cut).
- A rebuild implements the w00 body unchanged; it can build the statement with any method (the name and marker count
  are fixed), but must keep `@nRet` = `@@ERROR` (0 on success) as the only output.

### 7.3 Connection startup command (`ODBC_INFO` column 5, `DBRecord::query`)

```
SessionWorker_DBInit(w)        @ Account FUN_00405f20 CSessionWorker::DB_Init (pdb2016), AccountLog FUN_00405870,
                                 Character FUN_0043e040, GameLog FUN_0040a290
    info = GetODBCInfo(row id, my world)            # ServerInfo.txt ODBC_INFO rows: Account 0, AccountLog 1,
                                                    # Statistics 2, w00_Character 10, w00_GameLog 11
    CGameDB_Connect::DBConnect(w.db, info.pConnectInfo, info.pStartupCmd)   (pdb2016 names)
                               @ Account FUN_00419bb0, AccountLog FUN_00415680, Character FUN_0046ecd0, GameLog FUN_0041b720
        connect (vtable slot 1) with the connection string; failure → return 1
        if pStartupCmd is not empty:
            DBRecord::query(w.db, pStartupCmd)      @ FUN_00412410 / FUN_0040e4a0 / FUN_0044fb00 / FUN_00413f70
                vsprintf(buf[0x2000], pStartupCmd, <no arguments>)
                SQLCloseCursor; SQLFreeStmt(SQL_CLOSE); SQLExecDirect(buf, SQL_NTS)
            failure → return 2
        return 0
    AccountLog: same for the Statistics row into w.statDb; if that fails the AccountLog connection is closed again
    (CGameDB_Connect::DBClose)
    any failure → log, the worker does not start (D01 §1, D05 §1.1)
```

- Every `ODBC_INFO` row of the 2016 `ServerInfo.txt` has the startup command `"SET LOCK_TIMEOUT 5000;"`. It is the only
  free SQL text the servers execute, and it comes from the configuration, not the binary. Effect on every procedure:
  a statement that waits more than 5 s for a lock fails with SQL Server error 1222 ("Lock request time out period
  exceeded"); the batch is not aborted, but `SQLExecDirect` returns `SQL_ERROR` and the wrapper takes its failure path
  (usually: log, no reply or the handler's DB-error reply). A rebuild that keeps the procedures but not this setting waits
  indefinitely instead (SQL Server's default `LOCK_TIMEOUT` is −1). So a rebuild should run `SET LOCK_TIMEOUT 5000` on
  every connection (or keep the configuration column).
- The command is passed to `vsprintf` as the **format** with no arguments *(original bug)* D06-B7: a `%` in the
  configured text (e.g. a `LIKE '%…'` in a custom startup batch) reads stack garbage or crashes the worker at start; text
  longer than 0x2000 bytes overflows the stack buffer. Harmless with the shipped value. Likely intent: execute the text
  as is.
- `DBRecord::query` has no other caller in any of the four binaries.

## 8. Version choices for Character procedures that have source (D02 / D03 *(db-backup)* points)

### 8.1 `p_Item_BuyAll` (10) / `p_Item_BuyLot` (8): follow w00

| | Binary binds | Character.bak | w00_Character |
|---|---|---|---|
| `p_Item_BuyAll` @ FUN_00462380 | 1 SBIGINT→BIGINT key, 2 ULONG→INTEGER owner, 3 UTINYINT→TINYINT storage type, 4 USHORT→SMALLINT slot, 5 ULONG→INTEGER item ID, 6 ULONG→INTEGER flags, 7 SBIGINT→BIGINT price, 8 ULONG→INTEGER fame, 9 ULONG→INTEGER coin, 10 out ULONG→INTEGER nRet | 9 parameters, no `@nCoin` | `(@nItemKey bigint, @nOwner int, @nStorageType tinyint, @nStorage smallint, @nItemID int, @nFlags int, @nPrice bigint, @nFame int, @nCoin bigint, @nRet int OUTPUT)` = binary |
| `p_Item_BuyLot` @ FUN_00462600 | 1 key BIGINT, 2 owner INTEGER, 3 USHORT→SMALLINT option type, 4 SBIGINT→BIGINT new lot, 5 SBIGINT→BIGINT price, 6 ULONG→INTEGER fame, 7 ULONG→INTEGER coin, 8 out nRet (preset −1) | 7 parameters, no `@nCoin` | `(…, @nPrice bigint, @nFame int, @nCoin bigint, @nRet int OUTPUT)` = binary |

With the Character.bak copies every purchase fails (error 8144 "too many arguments", `SQL_ERROR`). w00's `@nCoin bigint`
receives the binary's 32-bit value (implicit widening). `SQL_p_Item_BuyLot` returns `@nRet` without testing the
`SQLExecDirect` result, so a failed call reads as its preset −1 (D03 §2 maps the codes).

### 8.2 `usp_Character_setChatBan`: follow w00

Binary @ FUN_0045e920: `{CALL usp_Character_setChatBan(?, ?, ?)}`, 1 in CHAR→WVARCHAR buf 0x28 (`sID`), 2 in
ULONG→INTEGER (`nChatBan`), 3 out SLONG→INTEGER preset 0; returns 1 iff rc ∈ {0,1} and `@nRet ∈ {0, −3121}` (asm
0x45ea29–0x45ea4d). w00 ("Ko Dong Gyun 2010.12.13", `@sID nvarchar(40), @nChatBan int, @nRet int = 0 output`) matches:
−3121 no such (undeleted) character → 0x216A / 0x2172 "Can't find the character"; −3192 insert of the
`tCharacterSingleOption` row failed and −3193 its update failed → wrapper 0 → 0x0864 `0x2169`, 0x0869 not sent at all
(D02-B12). Character.bak has two truncated 2009.2.12 copies with other signatures (`@nRet int` alone; `@nCharNo int,
@nExp bigint`, `bak.py` marks both `TRUNCATED?`); neither can run the 2016 call.

### 8.3 `usp_Gamble_addCoin` and D03-B21

Wrapper @ FUN_00466320: 1 in ULONG→INTEGER charNo +0, 2 in SBIGINT→BIGINT item key +8, 3 in SBIGINT→BIGINT coins
+0x10, 4 out SLONG→INTEGER `@nRet` +0x18 preset 0; returns 1 iff rc ∈ {0,1}, **`@nRet` is never tested**. w00 body
("Ko Dong Gyun 2011.5.16", the only source): the key must be an item of the character, which it deletes before adding
the coins; else −3331; −3311 / −3313 bad character / coin count; −3332 / −3329 / −3323 / −3326 write errors.

- `0xBC19 NC_GAMBLE_COIN_DB_USE_COINITEM_REQ` (@ FUN_00424fc0, the coin item) passes the real key and maps `@nRet`
  itself (D03 §11): the w00 body fits it.
- `0xBC06 NC_GAMBLE_COIN_DB_ADD_REQ` (@ FUN_004248b0) leaves the key at +8 unwritten (D03-B21) **and answers `0x2828`
  (ok) whenever the call executes**: `0x2829` only on a call failure. With the w00 body the garbage key matches nothing →
  −3331 → the zone would be told "added" while no coin was added. Correction to D03 §11 (which lists 0x2829 as the
  failure answer without saying that `@nRet` is ignored).
- **0xBC06 is unreachable in 2016:** the zone never sends it and registers no `0xBC07` handler (its GameDB gamble
  handlers are 0xBC0B, 0xBC12, 0xBC16, 0xBC1A; zone `handlers.json`), and the WM neither. D03-B21 has no effect in 2016,
  and D03's verification step 8 ("buy/receive gamble coins (0xBC06)") cannot exercise it: coin purchases use 0xBC11, coin
  items 0xBC19.
- Were it reachable, the stack slot could hold a real item key of the same character left by an earlier request on the
  same worker thread, and the procedure would delete that item *(inferred)*.

A rebuild takes the w00 body for 0xBC19 and needs nothing for 0xBC06.

### 8.4 Enchant procedures (`usp_Item_*Enchant*`): follow w00

Only w00 has them (header "Author: <KHRISMIZER>, 2010.08.13", the SSMS template filled in; `bak.py` marks `3RD?`). Every
parameter matches the 2016 binds in order, direction and type:

| Procedure (wrapper) | Binary binds | w00 signature |
|---|---|---|
| `usp_Item_Add_EnchantGem` (FUN_00465540) | INTEGER, BIGINT, BIGINT, TINYINT +0x1C, INTEGER +0x18, TINYINT +0x1D, out INTEGER | `@nCharNo INT, @nEquipmentItemKey BIGINT, @nGemItemKey BIGINT, @nGemSocketIndex TINYINT, @nGemID INT, @nRestGemCount TINYINT, @nRet INT = 0 OUTPUT` |
| `usp_Item_Del_EnchantGem` (FUN_00465640) | INTEGER, BIGINT, BIGINT, TINYINT, TINYINT, SMALLINT, out BIGINT, out INTEGER | `… @nResetSocketIndex TINYINT, @bNeedItem TINYINT, @nRemoverLotType SMALLINT, @nRemoverLotValue BIGINT OUTPUT, @nRet INT OUTPUT` |
| `usp_Item_Add_EnchantSocket` (FUN_00465760) | INTEGER, BIGINT, BIGINT, out TINYINT, SMALLINT, out BIGINT, out INTEGER | `… @nDrillItemKey BIGINT, @nAllSocketCount TINYINT OUTPUT, @nDrillLotType SMALLINT, @nDrillLotValue BIGINT OUTPUT, @nRet INT OUTPUT` |
| `usp_Item_Set_EnchantGemLot` (FUN_00465860) | INTEGER, BIGINT, TINYINT, TINYINT, out INTEGER | `@nCharNo INT, @nEquipmentItemKey BIGINT, @nSlot TINYINT, @nRestGemCount TINYINT, @nRet INT OUTPUT` |
| `usp_Item_Get_EnchantAll` (FUN_00465930) | BIGINT, out INTEGER (+ result rows) | `@nEquipmentItemKey BIGINT, @nRet INT = 0 OUTPUT` |

With the result codes D03 §6.2 found in the bodies (−101, −201, −202, −301, −302, all tested by the binary), this is the
strongest compatibility the backups can give. Whether the bodies are the official 2016 ones or a private server's
rewrite cannot be decided; a rebuild follows them. (`usp_Item_Get_EnchantAll` returns rows and `@nRet`: the wrapper does
not test `@nRet`, so the D06-B1 timing does not matter there.)

### 8.5 Version sweep: every called procedure that exists in two backups

Method (sweep part, from the restore of §9.1): every procedure name in a `{CALL …}` string of the Character (307 names) and
GameLog (23) binaries that exists in both `Character` and `w00_Character` (219) or `GameLog` and `w00_GameLog` (21) was
compared after removing comments, whitespace, case and `[dbo].` brackets. 193 + 20 are identical; the 26 + 1 that
differ are below, with the version a rebuild follows and the 2016 evidence that decides it. (The three `usp_Tutorial_*`
of `Account.bak` were compared with w00 too: only `setCharInfo` differs, D02 §3 already decided it.) Account, AccountLog
and StatisticsData exist in one backup each (§3.5 compared AccountLog / Statistics with the binary).

| Procedure (wrapper) | `Character.bak` (2011–2015 dates) | `w00_Character` | Follow | Evidence |
|---|---|---|---|---|
| `p_Char_Create` (FUN_00458070) | "2004.6 CJC" body | header adds "2010.10.7 By kodong: changed for the new short-cut key system": calls `usp_Character_initKeyMap`, `−4` on its failure | **w00** (corrects D02 §3 / §15 "Character.bak used") | the 2016 server has the 2010 key-map system (0x702E / 0x7057, `tCharacterKeyMap`), which `Character.bak` lacks entirely (§9.7); `−4` reaches the 0x1403 `else` branch (0x181 "The name is already in use."), like `0` |
| `p_Char_GetLoginData` (FUN_004584f0) | runs `p_Prison_UpdateCharPrisonMin @nCharNo, 0` before the SELECT | SELECT only | **w00** | same SELECT; the extra call belongs to the third-party prison rework below (dated 2015-10-01); with w00's prison procedure it would release every prisoner at login |
| `p_Prison_Add` / `p_Prison_Add2` (FUN_004659e0 / FUN_00465af0) | forces `@nMinute = 10080` and updates the existing `tPrison` row | the GM's `nMinute`; inserts a history row | **w00** (as D04 §7) | the binary passes the GM's `nMinute` (0x7C0B) and echoes it to the client; a fixed 7-day sentence is a private change |
| `p_Prison_UpdateCharPrisonMin` (FUN_00465be0) | parameter `@nMinuteOld`; recomputes the rest from `tPrison.dPrisonDate`, ends the sentence only in `EldPri` | `@nMinute`: 0 → release to Rou (5963, 9793), else store it | **w00** (as D04 §7) | the zone counts the minutes down and sends them (0x7C0D, Z09); the binary binds the zone's value |
| `p_Char_GetStateAllWithSetItemAndRestTime` (FUN_00459340) | 17 columns | 19: + `nCasterLevel`, `nCasterAttackPower` | **w00** | the loader FUN_0046c6e0 fetches 19 columns (9 × U16/U32/U8 state fields, 8 set-item U16, then `nCasterLevel` U16 and `nCasterAttackPower` U16, the latter truncated: D06-B6), matching the 21-parameter save of §7.2 |
| `usp_Character_getSingleOption` (FUN_0045c0e0) | `bMysteryBolt, bAutoPick, dRestExpLastExecuteTime` | + `nChatBan` | **w00** | FUN_0046dc00 fetches U8, U8, TIME, U32 (4 columns) |
| `usp_GuildAcademy_getMemberList` (FUN_004558e0) | no `nChatBanTime` | + `g.nChatBanTime` | **w00** (as D04 §9) | D04 §9 reads `nChatBanTime` in the fetch list |
| `p_Quest_GetAllDoing` (FUN_00453240) | `WHERE nStatus <> @nStatus` | `WHERE nStatus = @nStatus` | **w00** | the binary passes `PLAYER_QUEST_STATUS` *(pdb2016: Zone.pdb, same in the 2017 client PDB)* values read from the asm: the "doing" list FUN_0046cb00 calls it three times (6 `PQS_ING`, 7 `PQS_FAILED`, 8 `PQS_REWARD`) into one packet, the done list FUN_0046ce30 / `SendQuestDone` FUN_004288d0 with 2 (`PQS_DONE`), the read list FUN_0046ce50 with 20 (`PQS_READ_ABLE`), the repeat list FUN_0046ced0 with 4 (`PQS_REPEAT`). With `<>` every quest would appear three times in 0x100A (corrects D02 §4 "filter values 2, 7, 8 and one from a register, `<>`") |
| `p_Quest_Set` (FUN_004530e0) | counts completions of quest 20016 ("wedding planner 2", 2008-06-03) in `tQuestTimes` | the same block commented out | either; **w00** | no 2016 procedure or binary reads `tQuestTimes` (only `p_Quest_Set` names it in both backups) |
| `p_Char_Login` (FUN_00458560) / `p_Char_Logout` (FUN_004585f0) | third-party `LoggedInChars` table; Login returns no row | "JK CHO 2014.8.22": Login returns `nLoginDateDiff`; Logout snapshots `nFriendPoint` into `nLastFriendPoint` | **w00** (as D02 §5) | the friend-point columns exist only in w00 (§9.7); `LoggedInChars` is no official table (D02 knowledge) |
| `p_Char_Rename` (FUN_00458400) | plain UPDATE | requires an unused `tCharacterChangeID` row (= `Fixes/Free Name Change`, 2018) | **Character.bak** (as D02 §3) | the w00 copy is the 2018 fix applied to the dump; the 2016 rename item flow (0xB40A) is separate |
| `usp_Character_setChangeID` (FUN_00465f30) | "Ko Dong Gyun 2010.7.7" | + `−3024` "no unused `tCharacterChangeID` row" (Free Name Change fix) | **Character.bak** (as D02 §14) | the binary has no own code for −3024 (→ 0x20C5) |
| `p_Guild_Member_SetGrade` (FUN_00454ab0) | third-party (2014-11-02): `@nRet tinyint`, 1 = ok / 0 = fail, 24-hour rule on `tGuild.dMasterChange` | 2006 CJC + kodong: `@nRet int`, 0 = ok, −1311 / −1313 / −1323 / −1324 / −1325, 7-day rule on `tLog_GuildMasterChange` | **w00** (as D04 §6) | the wrapper treats `nRet == 0` as success and the handler maps −1324 to 0xC8A: with the `Character.bak` copy every successful change would be reported as failure |
| `p_Char_Wedding_Do`, `…_Divorce_Do` (FUN_0045b610, FUN_0045b470) | `dSubWhen = now + 3 minutes` | `+ 7 days` | **w00** | client text 0x1382 "Your marriage has not yet elapsed 7 days. You cannot apply for a divorce yet."; `Character.bak` has test-server timers |
| `p_Char_Wedding_Divorce_by_Agree` (FUN_0045b330) | `+ 5 minutes` | `+ 10 minutes` | **w00** | same family; sub-status values identical in both |
| `p_Char_Wedding_Divorce_by_Force` (FUN_0045b3d0) | `+ 5 minutes` | `+ 3 days` | **w00** | as above |
| `usp_Dice_setDicePay` (FUN_0045d0e0) | deletes the money card by key only | requires `nOwner = @nCharNo`, else `−2423` | **w00** | −2423 falls to the handler's generic 0x1D0D (D03 §10); the owner check only adds safety |
| `usp_Dice_setDiceResult` (FUN_0045ca50) | `−2421` and rollback when a loss exceeds the customer's money | clamps the customer's money at 0, `UPDLOCK, HOLDLOCK` | **w00** | the 2016 handler does not see this `nRet` (it tests the wrong variable, D03-B23), so only the money outcome differs; w00 is the version the other dice procedures come from |
| `p_Item_BuyAll`, `p_Item_BuyLot`, `usp_Character_setChatBan`, `usp_GuildAcademy_withdrawMoney`, `usp_GuildTournament_setRegist` | | | §8.1, §8.2, §5.7 | already decided |
| `p_GameLog_Add_Type6` (GameLog) | `GameLog.bak` keeps a `tLevelUpInfo` ranking for nType 30 | w00 without it | **w00** | §4.2 |

Not in the table: procedures that exist only in w00 (dice / gamble / collection, key map, tutorial, enchant, …): the
only version; their result codes match what the binary tests (D03 §16, §8.4), so a rebuild follows them.

### 8.6 Other open DB statements of D01–D05 settled in the sweep

- **Account storage = storage type 6 owned by the user number** (D03 §5.1 / §16, *inferred*): confirmed by the DB. The
  w00 procedure `p_Event_Friend_Reward` (lenasoft 2006-05-22; not called by the 2016 binary) sets `@nStorageType = 6
  --개정창고` ("account storage"), reads `@nFriendUserNo = tCharacter.nUserNo` and inserts `tItem(nStorageType 6,
  nOwner = nFriendUserNo, nStorage ≤ 143)`: owner = user number, 4 pages × 36 slots, as D03 read from the listing.
- **Storage type 10 = the hidden content box of chests and capsules** (D03 §16): left *(inferred)*. No procedure of
  either backup names type 10, and `w00_Character` has no CHECK constraint on `tItem` (none at all: `sys.check_constraints`
  is empty), so the DB treats storage types as plain numbers; only the binary's use defines them (D03 §7.2).
- **Wedding sub-status 6 / "+4" marker** (D02 §11 / §16, open): both backups write the same values (only the timers
  differ, §8.5). Who writes which value (w00 bodies): `p_Char_Wedding_Divorce_by_Agree` applicant 1, partner **6** (2 + 4);
  `…_by_Force` applicant 3, partner 4; `p_Char_Wedding_Divorce_Cancel` applicant 1 → **5**, 3 → **7**, partner 0. No
  procedure writes 8. The zone handles them in `Checker::DivorceLimit` @ FUN_005a1c90 *(pdb2016 name; Z07 §5.1 calls it
  by role and lists Sub 1–4 only)*, called for a married character (Main 2) when its wedding record arrives (Z07 §5.1). It switches on
  `Sub = Status >> 4` (vt 0x958 `so_ply_WeddingStatus`):

  ```pseudo
  Checker::DivorceLimit(player)                                   @ FUN_005a1c90 (zone)
      Sub 0: sp_UnlockRefundReq (vt 0x40c); sp_UnlockRefundCancelReq (vt 0x418)      # clear both refund locks
      Sub 5 (own request cancelled: by-agreement request lapsed, Sub 1/2 below):
          so_ply_WeddingInfoUpdate (vt 0x95c) with Sub 0     # local copy + DB 0x1082 save (FUN_0059f390)
          if not sp_IsLockedRefundReq (vt 0x404): sp_LockRefundReq (vt 0x408); so_ply_IncDecMoney (vt 0x794)(250 000, 1)
          so_SendErrorCode (vt 0x308)(8, 0x5D, 4999 = 0x1387)  # also when locked: only the refund is skipped
      Sub 6 (partner applied by agreement, not yet shown): so_SendErrorCode(8, 0x5D, 0x1385); store Sub 2
      Sub 7 (own forced divorce refused: zone 0x205E, Z02 §10): as Sub 5 with 750 000
      Sub 8: store Sub 4 (no message; no procedure writes 8)
      Sub 1–4, only once the limit `WeddingData+0xd` has passed:
          Sub 1 / 2: if sp_IsLockedRefundCancelReq (vt 0x410): return
                     DB 0x108F NC_CHAR_WEDDING_DIVORCE_CANCEL_REQ { applicant, partner, u8 IncreseCount 0 }
                       (Sub 1: applicant = self; Sub 2: applicant = the partner WeddingData+0x25)
                     sp_LockRefundCancelReq (vt 0x414) on self, and on the partner if som_FindPlayer finds them
          Sub 3 / 4: DB 0x108D NC_CHAR_WEDDING_DIVORCE_DO_REQ { partner, self, u8 1 }  # forced divorce executes
  ```

  Slot names *(pdb2016)*, resolved through the RTTI vftable of `ShinePlayer`; the locks are the `sp_MiscFlag` bytes
  `LockRefundReq` / `LockRefundCanCelReq` (FUN_00549400, FUN_0055a580, FUN_0055a5b0). So "+4" = "change not yet shown
  to this character": the zone shows it once, strips it and saves the stripped value (0x1082), and 5 / 7 also refund
  the by-agreement / forced divorce fee the zone took (Z02 §10 0x1089 / 0x205C). The refund lock stops a second
  refund before the 0x1082 save lands; the cancel lock stops a second 0x108F before the DB answers; Sub 0 clears both.
- **Client cross-check (0x205D NC_ACT_WEDDING_DIVORCE_REQ_ACK).** The client handles these codes itself, not through
  the error table, in `WeddingTask::Recv_NC_ACT_WEDDING_DIVORCE_REQ_ACK` @ FUN_006dd040 (client): 0x1385 → text
  0x0A6E6E51 "Your spouse has filed for a collaborative divorce." (message box); 4999 = 0x1387 → 0x1030E51D "Your spouse
  refused to get a divorce." (chat line, shown for a lapsed request too); 0x1386 → 0x7CBCC7B9 "Divorce proceeding
  complete. You are now single."; 0x1384 (Sub 4 notice, Z07 §5.1) → 0xCAEDDB1D, a message box (type 5) that sets
  `WeddingTask+0x70` (the id is not in the 2016 `TextData*.shn`: empty text); 0x1389 → `TextData2` 0x89C0CDB9; every
  other code → `ErrMsgTable`. Texts from `shn.py` over `Files/Client/2016/ressystem/TextData*.shn`.
- **0x1090 sub-status bytes** (D02 §11 / §16: "arguments lost by the decompiler"): settled from the asm of
  `fc_NC_CHAR_WEDDING_DIVORCE_CANCEL_REQ` @ FUN_00419730 (0x419793–0x4197c3): it calls FUN_0046d9a0 →
  `SQL_p_Char_Wedding_Divorce_Cancel` @ FUN_0045b520 with (charregistnumber, Partner, IncreseCount, &MySubStatus
  (0x1090 +10), &PartnerSubStatus (+15)); binds 4 and 5 are out UTINYINT→TINYINT, 6 out `@nRet`, result 1 iff rc ∈
  {0,1} and `@nRet` == 0. The w00 body reads `@SubStatusA` / `@SubStatusB` **before** its UPDATEs, so the reply carries
  the old sub-status of applicant and partner (e.g. 1 and 2), not the new 5 / 0. `@nRet`: 0 ok, 1 = either row missing
  or an UPDATE error (rolled back). On failure the outputs are not set (NULL, never delivered, §1.2), so the two bytes
  keep stale stack contents *(inferred)*; the zone reads only Success (Z07 §5.2 0x1090). A rebuild keeps the w00 body.
- **`tGameLog` column types, defaults, date column** (D05 §9): read from the restore, §9.3 (`w00_GameLog`).
- **0x0798 `ItemDropLog`** (D05 §9): an SHN table read by the zone, not a database table; nothing for D06.
- **D01 knowledge *(db-backup)* statements** (`nBlock` = `tUser.bIsBlock` after `usp_User_chkBlock`, admin levels,
  `p_IPBlock_IsBlock` AccountLog copy): `Account.bak` / `AccountLog.bak` are the only versions and their parameter
  counts match (§3.5, `bak.py cover account`); they stand as *(db-backup)*.

## 9. Table schema of the 2016 servers

### 9.1 Source and method

- **Restore done** (part 6): all eight backups restored into SQL Server 2022 (Linux, amd64 image under OrbStack/Docker on
  the arm64 host). Database versions: `Account`, `w00_Character`, `w00_GameLog` were written by SQL Server 2017 (version
  869, files under `MSSQL14`, backup of 2019-06-03), `AccountLog`, `StatisticsData`, `Character`, `GameLog`,
  `OperatorTool` by SQL Server 2008 R2 (661). So the column types, nullability, defaults, identity seeds, keys, indexes and
  foreign keys below are read from the restored catalogs (`sys.columns`, `sys.indexes`, `sys.foreign_keys`,
  `sys.default_constraints`), not from `bak.py`; they are *(db-backup)* facts about the private-server databases.
- **Which database each server opens:** `9Data/ServerInfo/ServerInfo.txt` `ODBC_INFO`: Account (index 0) → `Account`,
  AccountLog (1) → `AccountLog`, Statistics (2) → `StatisticsData`, Character (10) → `w00_Character`, GameLog (11) →
  `w00_GameLog`; all with `Driver={SQL Server}` and the startup command `SET LOCK_TIMEOUT 5000;` (§7.3). `Character.bak` and
  `GameLog.bak` are older copies of the last two (§9.7 lists the column differences); `OperatorTool` is used by no 2016
  server binary.
- **Which tables:** for every procedure a binary calls (`bak.py cover <bin>`), in its server's database, the transitive
  closure of `sys.sql_expression_dependencies` (procedures calling procedures included). Dynamic SQL is invisible to
  that view: of the called procedures only `p_Item_GetStorageEmptyList` uses `sp_executesql` (adds `tItemStorageFindEmpty`;
  every other `EXEC(`/`sp_executesql` hit is an operator-tool or maintenance procedure no binary calls). Result:
  8 Account tables, 5 AccountLog, 1 Statistics, 70 Character (+ `Account.dbo.tChargeItem`, reached cross-database:
  `usp_ChargeItem_Draw` / `usp_ChargeItem_GetList` `EXEC Account.dbo.usp_Charge_ItemDraw` / `usp_Charge_ItemSelectList`
  (Account.bak, Ko Dong Gyun 2006-06-17; D03 §6), so a rebuild needs these two Account procedures too and `Account` and
  `w00_Character` must live on one instance), 1 GameLog.
  Plus the tables of the procedures that have no source (§9.6, *ours*).
- **Not used by any 2016 call** (a rebuild can leave them out): `Account` 26 of 34 tables (tCash, tCashLog, tOrder, tPay*,
  tChannelLog, tItem, tTutorial, event and one-off copy tables…), `AccountLog` 5 of 10 (tUser, tUserLog, tEventWorldCup,
  tEvent_Friend*), `StatisticsData` 12 of 13 (the day/age/gender/location statistics the operator tool fills and reads),
  `w00_Character` 43 of 112 (old `tPet` / `tPetSkill`, `tParty*`, `tArena*`, `tMasterPupils`, `tKingdomQuest`, `tRestExp`,
  `tAutoPick`, `tGMItemReward*`, `tMinihouseGuest`, statistics, backups and temp tables), `w00_GameLog` `TEMP_QuestComplete`,
  all of `OperatorTool` (tOperator, tMenuAuth, tOpLog).
- **Collation:** every database `SQL_Latin1_General_CP1_CI_AS` (old `GameLog` `Latin1_General_CI_AS`): comparisons are
  case-insensitive, so character names (`tCharacter.sID`, uniqueness checked by `p_Char_Create`, no unique index) and
  account IDs are unique regardless of case. A rebuild on another engine must keep that.
- **Constraint names:** names of the form `PK__<table>__<hex>`, `FK__<tab>__<col>__<hex>`, `DF__…` were generated by SQL
  Server (they differ between the two Character backups); no procedure refers to a constraint by name, so a rebuild may
  name them freely. Explicit names are given below; generated default names are omitted.

### 9.2 Types: what the 2016 binds put into these columns

Every `SQLBindParameter` of the four binaries (360 wrapper functions with a literal call string, 1,546 binds; the one
run-time call string is §7.2) was compared with `sys.parameters` of the called procedure (w00 version first):

- **Unsigned C types into signed SQL types, everywhere.** The servers bind their unsigned fields as `SQL_C_ULONG` →
  `int` (533 binds), `SQL_C_UBIGINT` → `bigint` (207), `SQL_C_USHORT` → `smallint` (105), `SQL_C_TINYINT` (signed) →
  `tinyint` (23), `SQL_C_UTINYINT`/`SQL_C_ULONG` → `bit` (10). A value outside the SQL type's range (an u32 ≥ 2³¹, an u16 ≥
  32768, a negative i8) makes the driver fail the call with SQLSTATE 22003 (numeric value out of range) *(inferred from
  the ODBC conversion rules)*: the wrapper logs its `SQL_ERROR` line and the handler takes its failure path. In practice
  the values (character numbers, item IDs, levels, slots) stay far below the limits; a rebuild keeps the signed types of
  the columns below and treats out-of-range values as errors, as 2016 did. `bit` parameters receive any non-zero byte as 1.
- **Narrow strings into nvarchar.** Strings are bound `SQL_C_CHAR` with SQL type `SQL_WVARCHAR` (−9) and land in
  `nvarchar` parameters; several target columns are `varchar` (e.g. `tCharacter.sLoginZone`, `sKQMap` `varchar(16)`,
  `tAccountLog.sIP varchar(16)`), which is lossless for the ASCII map names and IPs the servers send. Column sizes are the
  limits the procedures truncate to; the binds pass `columnSize = 0` (§1.2).
- **Real mismatches** (direction or count; everything else lines up with the w00 / backup signatures):

| Wrapper | 2016 bind | Backup procedure | Effect | § |
|---|---|---|---|---|
| Account `usp_User_LoginGame` (FUN_00419440) | 5 params | 6 (`@userNo`, `@authID` output at 3–4) | the TW database's own 5-param procedure | §2.4 |
| Character `usp_CharacterLoading` (FUN_0045c360) | 11 params | 6 | 2016 table had more columns | §6.1 |
| Character `usp_Character_setFriendpoint` (FUN_00460710) | 2 markers, 3 binds | 3 params | harmless with w00's `@nRet = 0` default | §6.3 |
| Character `p_Item_GetStorageEmptyList` (FUN_00464b40) | `@nRet` (4) bound **input** (`SQL_PARAM_INPUT`, buffer pre-set 0) | `@nRet int OUTPUT` | the wrapper's `nRet != 0` test never sees the procedure's value: dead check (original bug) D06-B8; rows are read regardless | D03 §7.2 |
| Account `usp_Item_setSerialKey` (FUN_004190d0) | binds 1–2 (`@serialKey` …) `SQL_C_ULONG`/`SQL_INTEGER` | `@serialKey bigint` | by the systemic rule above a key ≥ 2³¹ already fails with 22003; the 32-bit buffer cannot carry the bigint range at all | D01 |
| Character `p_Guild_SetWar` (FUN_00454420) | `@nWarEnemy` `SQL_C_UBIGINT`/`SQL_BIGINT` | `int` | guild numbers fit; a value ≥ 2³¹ fails (22003) | D04 |
| Character `usp_GuildAcademy_getReward` (FUN_00456190) | `@nLevel` `SQL_C_USHORT`/`SQL_SMALLINT` | `tinyint` | levels > 255 fail; the procedure answers −1513 for 0 | D04 |

  The ternary pairs of §7.1 (`p_Item_Create` / `…_UseEmptyStorage`, `p_Item_SetStorageAndOwner` / `…_UseEmptyStorage`)
  bind `@nStorage` as output only in the `_UseEmptyStorage` branch, whose procedure declares it `OUTPUT`: consistent.

### 9.3 Tables (from the restore)

Per table: number of called procedures that reach it, rows present in the backup (only where non-zero; seed rows in
§9.5), columns in `column_id` order as `name type [IDENTITY(seed)] [NULL] [=default] [explicit default name]`
(`NOT NULL` unless `NULL` is given), then keys. No called procedure returns `SELECT *` (only inside `EXISTS` / a derived
table, e.g. `usp_Character_getGameOption`); they name their result columns, so the column order is the backup's, not a
requirement; the order of the *result* columns is what the binaries depend on, and
that is given by the procedure bodies (D02–D05) and §5–§8.

#### `Account`

- **`tChargeItem`** (Account `usp_ReturnUser_SetUserItem`; Character `usp_ChargeItem_Draw` / `usp_ChargeItem_GetList` reach it through `EXEC Account.dbo.usp_Charge_ItemDraw` / `usp_Charge_ItemSelectList`; 1 row in the backup): `rowNo int IDENTITY(1)` · `userNo int` · `orderNo int` · `goodsNo int` · `amount int =1` · `registerDate datetime =getdate()` · `isDraw tinyint =0` · `drawDate datetime NULL =getdate()`. PK `PK_tChargeItem_NC` (rowNo) nonclustered.
- **`tReturnUser`** (2 procs): `nRowNo int IDENTITY(1)` · `dDate datetime` · `nUserNo int` · `nItemNo int`. PK `PK_tReturnUser_nRowNo_NC` (nRowNo) nonclustered.
- **`tSerialKey`** (1 proc): `userNo int` · `serialKey bigint` · `registerDate datetime =getdate()`. PK `PK_tSerialKey_CL` (userNo); FK `FK__tSerialKe__userN__5629CD9C` userNo → tUser.nUserNo.
- **`tUser`** (5 procs; 1 row in the backup): `nUserNo int IDENTITY(100)` · `sUserID nvarchar(60)` · `sUserPW nvarchar(32)` · `sUserName nvarchar(10) NULL` · `bIsBlock bit =0` · `bIsDelete bit =0` · `nAuthID tinyint =1` · `sUserIP nvarchar(30)` · `dDate datetime =getdate()` · `sUserNo int NULL` · `blsBlock tinyint NULL` · `blsDelete tinyint NULL`. PK `PK_tUser_CL` (nUserNo); FK `FK__tUser__nAuthID__7E6CC920` nAuthID → tUserAuth.nAuthID.
- **`tUserAuth`** (3 procs; 5 rows in the backup): `nAuthID tinyint` · `sAuthName nvarchar(11)` · `bIsLoginAble tinyint =0`. PK `PK_tUserAuth_CL` (nAuthID).
- **`tUserBlock`** (3 procs): `nBlockNo int IDENTITY(1)` · `nUserNo int` · `nType tinyint =1` · `dBlockDate datetime =getdate()` · `nTimeValue int =1` · `dEndDate datetime =getdate()` · `bStatus bit =1` · `sComment nvarchar(200) NULL`. PK `PK_tUserBlock_NC` (nBlockNo) nonclustered; FK `FK__tUserBloc__nUser__0BC6C43E` nUserNo → tUser.nUserNo.
- **`tUserMergeYet`** (1 proc): `nuserno int IDENTITY(100)`. PK `PK__tUserMer__E789114E0A05505D` (nuserno).
- **`tUserOption`** (1 proc): `nUserNo int` · `sEmail nvarchar(200) NULL` · `sJuminNo nvarchar(50) NULL` · `sPhoneNo nvarchar(20) NULL` · `nZipNo int NULL` · `sAddress nvarchar(90) NULL` · `bIsMail bit` · `sChannel nvarchar(20)` · `nAffiliateID varchar(50) NULL` · `szAffiliateSubID varchar(50) NULL` · `szCountryCode varchar(50) NULL`. FK `FK_tUserOption_nUserNo` nUserNo → tUser.nUserNo cascade.

#### `AccountLog`

- **`tAccountLog`** (2 procs): `nLogNo bigint IDENTITY(1)` · `sUserID nvarchar(16) NULL` · `nType tinyint` · `nUserNo int NULL` · `nPlayMin smallint NULL` · `sUserPassword nvarchar(16) NULL` · `nWorldNo tinyint NULL` · `nErrorCode smallint NULL` · `sIP varchar(16) NULL` · `dDate datetime =getdate()`. PK `PK__tAccountLog__1ED998B2` (nLogNo); IX `XIE1tAccountLog_Date` (dDate); IX `XIE2tAccountLog_UserNo` (sUserID); IX `XIE3tAccountLog_Type` (nType).
- **`tEventiPad`** (1 proc): `nUserNo int` · `nTicket int` · `sys_create_date datetime =getdate()` · `sys_update_date datetime =getdate()`. PK `PK_tEventiPad_CL` (nUserNo).
- **`tIPBlock`** (1 proc): `sIPStart nvarchar(20)` · `sIPEnd nvarchar(20)` · `sDesc nvarchar(30) NULL` · `dDate datetime =getdate() [DF_tIPBlock_dDate]`. PK `PK_tIPBlock` (sIPStart,sIPEnd).
- **`tLogout`** (1 proc): `rowNo int IDENTITY(1)` · `logDate datetime =getdate()` · `worldNo tinyint NULL` · `userNo int` · `charNo int` · `class tinyint` · `level tinyint` · `experience bigint` · `playTime smallint =0`. IX `IX_tLogout` (userNo).
- **`tReport`** (3 procs): `nRegNumber int IDENTITY(1)` · `nReporter int` · `sReporterCharID nvarchar(16)` · `nWorldNo tinyint` · `dReportDate datetime NULL =getdate() [DF_tReport_dReportDate]` · `sHarmer nvarchar(16) NULL` · `sReportType nvarchar(16) NULL` · `sReason nvarchar(512) NULL` · `sChatLog ntext NULL` · `nResult tinyint NULL =0 [DF_tReport_nResult]` · `sRemark nvarchar(128) NULL`. PK `PK_tReport` (nRegNumber); IX `IX_ReportNo_WorldNo_dDate` (nReporter,nWorldNo,dReportDate).

#### `StatisticsData`

- **`tSameTimeChar`** (1 proc; 2 rows in the backup): `nIndex int IDENTITY(1)` · `dDate datetime =getdate()` · `nWorld tinyint` · `nCount int`. PK `PK__tSameTimeChar__00551192` (nIndex).

#### `w00_Character`

- **`tAttendance`** (3 procs): `nCharNo int` · `dAttendanceDate datetime`. PK `PK_tAttendance_CL` (nCharNo,dAttendanceDate). *(w00 only.)*
- **`tAttendanceReward`** (2 procs): `nCharNo int` · `dEventDate datetime` · `dRewardDate datetime` · `nRewardID int`. no key, no index. *(w00 only.)*
- **`tAutoMon`** (2 procs; 24 rows in the backup): `nCharNo int` · `nType tinyint` · `nSlot tinyint` · `nItemID int NULL`. PK `PK_tAutoMon_CL` (nCharNo,nType,nSlot). *(w00 only.)*
- **`tCharacter`** (90 procs; 1 row in the backup): `nCharNo int IDENTITY(1)` · `sID nvarchar(40)` · `nUserNo int` · `nAdminLevel tinyint =0` · `nPS int =0` · `nGS int =0` · `dCreateDate datetime =getdate()` · `bDeleted tinyint =0` · `nLoginZoneX int =5963` · `nLoginZoneY int =9793` · `nLoginZoneD tinyint =90` · `nPKYellowTime tinyint =0` · `dDeletedDate datetime =getdate() [DF_tCharacter_dDeletedDate]` · `nAP smallint =0` · `sLoginZone varchar(16) ='Rou'` · `nPKCount int =0` · `nLevel smallint =1` · `nExp bigint =0` · `nSlotNo tinyint =0` · `nHP smallint =100` · `nSP smallint =100` · `nHPS smallint =100 [DF_tCharacter_nHP2]` · `nSPS smallint =100 [DF_tCharacter_nSP2]` · `dLastLoginDate datetime =getdate()` · `nLoginCount int =0` · `nCreateWorld tinyint =0` · `nFame int =0` · `nPrisonMin smallint =0` · `nPlayMin int =0` · `nFlags int =0` · `nMoney bigint =0 [DF_tCharacter_nMoney]` · `nStrength tinyint =0 [DF_tCharacter_nStrength]` · `nConstitute tinyint =0 [DF_tCharacter_nConstitute]` · `nDexterity tinyint =0 [DF_tCharacter_nDexterity]` · `nIntelligence tinyint =0 [DF_tCharacter_nIntelligence]` · `nMentalPower tinyint =0 [DF_tCharacter_nMentalPower]` · `nRedistributePoint tinyint =0 [DF_tCharacter_nRedistributePoint]` · `nKQHandle int =-1 [DF_tCharacter_nKQHandle]` · `sKQMap varchar(16) ='' [DF_tCharacter_sLoginZone1]` · `nKQX int =0 [DF_tCharacter_nLoginZoneX1]` · `nKQY int =0 [DF_tCharacter_nLoginZoneY1]` · `nKQD tinyint =90 [DF_tCharacter_nLoginZoneD1]` · `dKQDate datetime =getdate() [DF_tCharacter_dKQDate]` · `nFriendPoint int NULL` · `nLastFriendPoint int NULL`. PK `PK__tCharacter__2610A626` (nCharNo). *w00 only: nFriendPoint, nLastFriendPoint.*
- **`tCharacterChangeID`** (5 procs): `nRowNo int IDENTITY(1)` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nUserNo int` · `nCharNo int` · `bFlag bit =0` · `bInit bit =0` · `sOldID nvarchar(50) NULL` · `sNewID nvarchar(50) NULL`. PK `PK_tCharacterChangeID_NC` (nRowNo) nonclustered; FK `FK_tCharacter_tCharacterChangeID_nCharNo` nCharNo → tCharacter.nCharNo.
- **`tCharacterChargedBuffer`** (3 procs): `nNo int IDENTITY(1)` · `nCharNo int` · `nKey int` · `nID smallint =0 [DF_tCharacterChargedBuffer_nID]` · `dUseDate datetime` · `dEndDate datetime`. PK `PK_tCharacterChargedBuffer` (nNo) nonclustered; FK `FK_tCharacterChargedBuffer_tCharacter` nCharNo → tCharacter.nCharNo.
- **`tCharacterGameOption`** (3 procs; 28 rows in the backup): `nCharNo int` · `sys_create_date datetime =getdate()` · `nOptionNo smallint` · `nValue tinyint`. PK `PK_tCharacterGameOption_CL` (nCharNo,nOptionNo,nValue); FK `FK_tCharacterGameOption_tCharacter_nCharNo` nCharNo → tCharacter.nCharNo cascade; FK `FK_tCharacterGameOption_tGameOptionInit_nOptionNo` nOptionNo → tGameOptionInit.nOptionNo. *(w00 only.)*
- **`tCharacterKeyMap`** (5 procs; 95 rows in the backup): `nCharNo int` · `nFunctionNo smallint` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nExtendedKey tinyint NULL` · `nASCIICode tinyint NULL`. PK `PK_tCharacterKeyMap_CL` (nCharNo,nFunctionNo); FK `FK_tCharacter_tCharacterKeyMap_nCharNo` nCharNo → tCharacter.nCharNo cascade; FK `FK_tKeyMapInit_tCharacterKeyMap_nFunctionNo` nFunctionNo → tKeyMapInit.nFunctionNo. *(w00 only.)*
- **`tCharacterLoading`** (1 proc): `nCharNo int` · `nSeqNo int` · `dWorldTime datetime` · `dDBTime datetime =getdate() [DF_tCharLoading_dDBTime]` · `sLoadingMapName varchar(16)` · `nFailType smallint` · `nLoadingFailCnt smallint`. PK `PK_tCharLoading` (nCharNo,nSeqNo).
- **`tCharacterOptions`** (15 procs; 1 row in the backup): `nCharNo int` · `sShortCutData varbinary(1024) NULL` · `sShortCutSize varbinary(24) NULL` · `sVideo varbinary(60) NULL` · `sSound varbinary(1) NULL` · `sGame varbinary(64) NULL` · `sWindowsPos varbinary(392) NULL` · `sKeyMapping varbinary(308) NULL`. PK `PK_tCharacterOptions` (nCharNo).
- **`tCharacterShape`** (8 procs; 1 row in the backup): `nCharNo int` · `nClass tinyint =0` · `nRace tinyint =0` · `nGender tinyint =0` · `nHairType tinyint =0` · `nHairColor tinyint =0` · `nFaceShape tinyint =0`. PK `PK__tCharacterShape__336AA144` (nCharNo).
- **`tCharacterShortCut`** (2 procs; 4 rows in the backup): `nCharNo int` · `nSlotNo tinyint` · `sys_create_date datetime =getdate()` · `sys_update_date datetime =getdate()` · `nCodeType smallint` · `nCodeNo smallint` · `nValue int`. PK `PK_tCharacterShortCut_CL` (nCharNo,nSlotNo); FK `FK_tCharacter_tCharacterShortCut_nCharNo` nCharNo → tCharacter.nCharNo cascade. *(w00 only.)*
- **`tCharacterSingleOption`** (8 procs; 1 row in the backup): `nCharNo int` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `bMysteryBolt bit =1` · `bAutoPick bit =0` · `dRestExpLastExecuteTime datetime =getdate()` · `nChatBan int =0` · `nAutoBuff tinyint =0` · `nAutoChargedBuff tinyint =0`. PK `PK_tCharacterSingleOption_CL` (nCharNo); FK `FK_tCharacter_tCharacterSingleOption_nCharNo` nCharNo → tCharacter.nCharNo. *w00 only: nChatBan, nAutoBuff, nAutoChargedBuff.*
- **`tCharacterState`** (2 procs): `nCharNo int` · `nStateNo smallint` · `nStateLevel smallint` · `nStateTime int` · `nStateCount smallint =0 [DF_tCharacterState_nStateCount]` · `nStatePowerDemage tinyint =0 [DF_tCharacterState_nStatePowerDemage]` · `nStatePowerSP tinyint =0 [DF_tCharacterState_nStatePowerDemage1]` · `nStatePowerKeepTime tinyint =0 [DF_tCharacterState_nStatePowerDemage2]` · `nStatePowerCoolTime tinyint =0 [DF_tCharacterState_nStatePowerDemage3]` · `nSetItemIndexA smallint =0` · `nSetItemValueA smallint =0` · `nSetItemIndexB smallint =0` · `nSetItemValueB smallint =0` · `nSetItemIndexC smallint =0` · `nSetItemValueC smallint =0` · `nSetItemIndexD smallint =0` · `nSetItemValueD smallint =0` · `nRestTime int =0` · `nCasterLevel smallint =0` · `nCasterAttackPower int =0`. PK `PK__tCharacterState__3552E9B6` (nCharNo,nStateNo). *w00 only: nCasterLevel, nCasterAttackPower.*
- **`tCharacterTitle`** (2 procs; 8 rows in the backup): `nNo bigint IDENTITY(1)` · `dDate datetime =getdate() [DF_tCharacterTitle_dDate]` · `nCharNo int` · `nType tinyint` · `nElementNo tinyint` · `nElementValue bigint =0 [DF_tCharacterTitle_nElementValue]`. UQ `IX_tCharacterTitle` (nCharNo,nType,nElementNo) clustered; PK `PK_tCharacterTitle` (nNo) nonclustered; FK `FK_tCharacterTitle_tCharacter` nCharNo → tCharacter.nCharNo cascade.
- **`tChatBlock`** (5 procs): `nUserNo int` · `nCharNo int` · `dDate datetime =getdate()`. PK `PK_tChatBlock_CL` (nUserNo,nCharNo).
- **`tChatColor`** (3 procs): `nCharNo int` · `nFontColorID tinyint` · `nBalloonColorID tinyint` · `dDate datetime =getdate()`. PK `PK_tChatColor_nCharNo_CL` (nCharNo). *(w00 only.)*
- **`tCollectionCard`** (3 procs): `nCharNo int` · `nCardID int` · `nSerialNo bigint` · `nStarNumber tinyint` · `dDate datetime =getdate()`. PK `PK_tCollectionCard_nCharNo_nCardID_CL` (nCharNo,nCardID); FK `FK_tCollectionCard_tCharacter_nCharNo` nCharNo → tCharacter.nCharNo. *(w00 only.)*
- **`tCollectionFavorites`** (2 procs): `nCharNo int` · `nSlotNo tinyint` · `nCardID int` · `dDate datetime =getdate()`. PK `PK_tCollectionFavorites_nCharNo_nSlotNo_nCardID_CL` (nCharNo,nSlotNo,nCardID); FK `FK_tCollectionFavorites_tCollectionCard_nCharNo_nCardID` nCharNo → tCollectionCard.nCharNo, nCardID → tCollectionCard.nCardID. *(w00 only.)*
- **`tCollectionReward`** (2 procs): `nCharNo int` · `nReward int` · `dDate datetime =getdate()`. PK `PK_tCollectionReward_nCharNo_nReward_CL` (nCharNo,nReward). *(w00 only.)*
- **`tCollectionSerialCount`** (2 procs): `nCardID int` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nCount bigint`. PK `PK_tCollectionSerialCount_nCardID_CL` (nCardID). *(w00 only.)*
- **`tDice`** (3 procs): `nGameNo int IDENTITY(1)` · `nCharNo int` · `nItemKey bigint` · `sDice nvarchar(3)` · `dDate datetime =getdate()`. PK `PK_tDice_NC` (nGameNo) nonclustered.
- **`tDiceLog`** (2 procs): `nGameNo int` · `nCustomCharNo int` · `nSlotNo tinyint` · `nBattingMoney bigint` · `nBattingRate int` · `bStatus bit` · `nTaxRate int` · `nDividend bigint`. PK `PK_tDiceLog_CL` (nGameNo,nCustomCharNo,nSlotNo); FK `FK__tDiceLog__5B988E2F` nGameNo → tDiceResult.nGameNo, nCustomCharNo → tDiceResult.nCustomCharNo.
- **`tDicePayLog`** (1 proc): `nCharNo int` · `nItemKey bigint` · `nTotalDividend bigint` · `dDate datetime =getdate()`. PK `PK_tDicePayLog_CL` (nCharNo,nItemKey).
- **`tDiceResult`** (2 procs): `nGameNo int` · `nCustomCharNo int` · `nBeforeMoney bigint` · `nTotalDividend bigint` · `nAfterMoney bigint`. PK `PK_tDiceResult_CL` (nGameNo,nCustomCharNo); FK `FK__tDiceResu__nGame__5D80D6A1` nGameNo → tDice.nGameNo.
- **`tFriend`** (8 procs): `nCharNo int` · `nFriendCharNo int` · `nFlags tinyint =0` · `dDate datetime =getdate() [DF_tFriend_dDate]`. PK `PK_tFriend_CL` (nCharNo,nFriendCharNo).
- **`tGambleCoin`** (8 procs): `nCharNo int` · `sys_update_date datetime NULL` · `nCoin bigint =0` · `dDate datetime =getdate()`. PK `PK_tGambleCoin_CL` (nCharNo); FK `FK_tGambleCoin_tCharacter_nCharNo` nCharNo → tCharacter.nCharNo. *(w00 only.)*
- **`tGambleCoinExchangeLog`** (6 procs): `nLogNo bigint IDENTITY(1)` · `nCharNo int` · `dDate datetime =getdate()` · `nExchangedCoin bigint` · `nStatus tinyint` · `nBeforeCoin bigint =0` · `nAfterCoin bigint =0` · `nBeforeMoney bigint =0` · `nAfterMoney bigint =0`. PK `PK_tGambleCoinExchangeLog_NC` (nLogNo) nonclustered. *(w00 only.)*
- **`tGambleDice`** (2 procs): `nGameNo int IDENTITY(1)` · `sDice nvarchar(3)` · `dDate datetime =getdate()`. PK `PK_tGambleDice_NC` (nGameNo) nonclustered. *(w00 only.)*
- **`tGambleDiceLog`** (2 procs): `nGameNo int` · `nCharNo int` · `nSlotNo tinyint` · `nBattingMoney bigint` · `nBattingRate int` · `bStatus bit` · `nTaxRate int` · `nDividend bigint` · `dDate datetime =getdate()`. PK `PK_tGambleDiceLog_CL` (nGameNo,nCharNo,nSlotNo); FK `FK_tGambleDiceLog_tGambleDiceResult_nGameNo` nGameNo → tGambleDiceResult.nGameNo, nCharNo → tGambleDiceResult.nCharNo. *(w00 only.)*
- **`tGambleDiceResult`** (1 proc): `nGameNo int` · `nCharNo int` · `nBeforeMoney bigint` · `nTotalDividend bigint` · `nAfterMoney bigint` · `dDate datetime =getdate()`. PK `PK_tGambleDiceResult_CL` (nGameNo,nCharNo); FK `FK_tGambleDiceResult_tGambleDice_nGameNo` nGameNo → tGambleDice.nGameNo. *(w00 only.)*
- **`tGambleJackpot`** (2 procs): `sGameName nvarchar(20)` · `nBattingUnit bigint` · `sys_create_date datetime =getdate()` · `sys_update_date datetime =getdate()` · `nJackpotCoin bigint =0`. no key, no index. *(w00 only.)*
- **`tGambleJackpotLog`** (2 procs): `nLogNo bigint IDENTITY(1)` · `sGameName nvarchar(20)` · `nBattingUnit bigint` · `sID nvarchar(80)` · `nJackpotCoin bigint =0` · `nGameNo bigint`. PK `PK_tGambleJackpotLog_NC` (nLogNo) nonclustered; FK `FK_tGambleJackpotLog_tGambleSlotMachineLog_nCharNo` nGameNo → tGambleSlotMachineLog.nGameNo. *(w00 only.)*
- **`tGambleSlotMachineLog`** (1 proc): `nGameNo bigint IDENTITY(1)` · `nCharNo int` · `dDate datetime =getdate()` · `nBattingUnit bigint` · `nBatting tinyint` · `sGameResult nvarchar(10)` · `bIsWin bit` · `nPrizeCoin bigint =0`. PK `PK_tGambleSlotMachineLog_NC` (nGameNo) nonclustered; FK `FK_tGambleSlotMachineLog_tCharacter_nCharNo` nCharNo → tCharacter.nCharNo. *(w00 only.)*
- **`tGameOptionInit`** (1 proc; 28 rows in the backup): `nOptionNo smallint` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nDefaultValue tinyint NULL` · `bIsActive bit` · `sDescription nvarchar(100) NULL` · `sDescriptionLocal nvarchar(100) NULL`. PK `PK_tGameOptionInit_CL` (nOptionNo). *(w00 only.)*
- **`tGuild`** (18 procs; 1 row in the backup): `nNo int IDENTITY(1)` · `sName nvarchar(18)` · `sPassword nvarchar(10)` · `nMaxMembers smallint =15` · `nMoney bigint =0` · `nType tinyint =0 [DF_tGuild_nType]` · `nGrade tinyint =1` · `nFame int =0 [DF_tGuild_nFame]` · `nStoneLevel smallint =1` · `nExp bigint =0` · `dCreateDate datetime =getdate()` · `dWarRequestDate datetime =getdate() [DF_tGuild_dWarRequestDate]` · `dWarStartDate datetime =getdate() [DF_tGuild_dWarStartDate]` · `dWarEndDate datetime =getdate() [DF_tGuild_dWarEndDate]` · `nWarEnemy int =0 [DF_tGuild_nWarEnemy]` · `nWarWinCount int =0 [DF_tGuild_nWarWinCount]` · `nWarLoseCount int =0 [DF_tGuild_nWarLoseCount]` · `nWarDrawCount int =0 [DF_tGuild_nWarDrawCount]` · `nDismissStatus tinyint =0 [DF_tGuild_nDeleteStatus]` · `dDismissDate datetime =getdate() [DF_tGuild_dDeleteDate]` · `sIntro nvarchar(128) ='' [DF_tGuild_sIntro]` · `dNotifyDate datetime =getdate() [DF_tGuild_dNotifyDate]` · `sNotifyCharID nvarchar(17) ='' [DF_tGuild_sNotifyCharID]` · `sNotify nvarchar(512) ='' [DF_tGuild_sNotify]`. PK `PK__tGuild__41B8C09B` (nNo). *Character.bak only: dMasterChange datetime ='2000-01-01 00:00:00.000' [DF_tGuild_dMasterChange].*
- **`tGuildAcademy`** (10 procs; 1 row in the backup): `nNo int` · `nMasterCharNo int` · `nMaxMember smallint` · `nMoney bigint =0` · `nPoint int =0` · `dBuffEndTime datetime NULL` · `dNotifyDate datetime NULL` · `sNotify varchar(512) NULL` · `sIntro nvarchar(128) NULL`. PK `PK_tGuildAcademy_CL` (nNo); FK `FK__tGuildAca__nMast__6521F869` nMasterCharNo → tCharacter.nCharNo; FK `FK__tGuildAcade__nNo__66161CA2` nNo → tGuild.nNo cascade. *Character.bak differs: sNotify nvarchar(512) NULL.*
- **`tGuildAcademyGraduate`** (4 procs): `nNo int` · `nCharNo int` · `sID nvarchar(40)` · `nClass tinyint` · `nJoinLevel smallint` · `dJoinDate datetime =getdate()` · `nGraduateLevel smallint` · `dGraduateDate datetime =getdate()`. PK `PK_tGuildAcademyGraduate_CL` (nNo,nCharNo).
- **`tGuildAcademyHistory`** (2 procs; 1 row in the backup): `nAcademyID int` · `nCharNo int` · `sID nvarchar(50)` · `dDate datetime` · `nAction int`. no key, no index. *(w00 only.)*
- **`tGuildAcademyMember`** (8 procs): `nNo int` · `nCharNo int` · `nJoinLevel smallint` · `dJoinDate datetime =getdate()` · `nGrade tinyint NULL =255` · `sIntro nvarchar(128) NULL` · `nChatBanTime int =0`. PK `PK_tGuildAcademyMember_CL` (nNo,nCharNo); FK `FK__tGuildAca__nChar__670A40DB` nCharNo → tCharacter.nCharNo; FK `FK__tGuildAcade__nNo__67FE6514` nNo → tGuildAcademy.nNo cascade. *w00 only: nChatBanTime.*
- **`tGuildAcademyRanking`** (2 procs): `nRowNo int IDENTITY(1)` · `dDate datetime =getdate()` · `nRanking int` · `nGuildNo int` · `sGuildName nvarchar(18)` · `nMasterNo int` · `sMasterID nvarchar(40)` · `nPoint int` · `nCount int`. PK `PK_tGuildAcademyRanking_NC` (nRowNo) nonclustered.
- **`tGuildAcademyReward`** (4 procs): `nNo int` · `nLevel smallint` · `nTypeID tinyint` · `nValue bigint NULL` · `nItemID int NULL`. PK `PK_tGuildAcademyReward_CL` (nNo,nLevel,nTypeID); FK `FK__tGuildAca__nType__68F2894D` nTypeID → tGuildAcademyRewardType.nTypeID; FK `FK__tGuildAcade__nNo__69E6AD86` nNo → tGuildAcademy.nNo cascade.
- **`tGuildEmblem`** (3 procs; 1 row in the backup): `nGuildNo int` · `nColor int` · `nIcon int` · `dCreated datetime` · `dUpdated datetime` · `nUnk int`. no key, no index. *(w00 only.)*
- **`tGuildMember`** (15 procs; 1 row in the backup): `nNo int` · `nCharNo int` · `dJoinDate datetime =getdate()` · `nGrade tinyint =0` · `nFlags int =0` · `nExpRatio smallint =0 [DF_tGuildMember_nExpRatio]` · `sIntro nvarchar(64) ='' [DF_tGuildMember_sIntro]`. PK `PK__tGuildMember__1FCDBCEB` (nNo,nCharNo); UQ `IX_tGuildMember` (nCharNo); FK `FK_tGuildMember_tGuild` nNo → tGuild.nNo cascade.
- **`tGuildToken`** (5 procs): `nNo int` · `nToken bigint`. no key, no index.
- **`tGuildTournament`** (4 procs; 10 rows in the backup): `nGTNo int` · `nType smallint` · `nData int` · `nGuildNo int NULL`. PK `PK_tGuildTournament` (nGTNo,nType). *w00 only: nGuildNo.*
- **`tGuildTournamentRegist`** (5 procs): `nGTNo int` · `nNo int` · `nMoney bigint` · `dDate datetime =getdate()` · `nSeed int =0` · `bChoice bit =0`. PK `PK_tGuildTournamentRegist_CL` (nGTNo,nNo).
- **`tHolyPromise`** (9 procs): `nCharNo int` · `nUpCharNo int` · `nFlags tinyint` · `dRegDate datetime =getdate() [DF_tHolyPromise_dRegDate]` · `dRejoinableDate datetime =getdate() [DF_tHolyPromise_dLeaveDate]` · `dMemberAcceptableDate datetime =getdate() [DF_tHolyPromise_dKickDate]`. PK `PK_tHolyPromise` (nCharNo,nUpCharNo); FK `FK_tHolyPromise_tCharacter` nCharNo → tCharacter.nCharNo cascade.
- **`tHolyPromiseReward`** (3 procs): `nCharNo int` · `nSeqNo int` · `nType tinyint` · `nMoney bigint` · `nRemainMoney bigint` · `nReceiptCharNo int` · `dDate datetime =getdate() [DF_tHolyPromiseReward_dDate]`. PK `PK_tHolyPromiseReward` (nCharNo,nSeqNo).
- **`tInGameGuide`** (2 procs; 15 rows in the backup): `nCharNo int` · `nGuideNo int NULL`. no key, no index. *(w00 only.)*
- **`tItem`** (44 procs; 3 rows in the backup): `nItemKey bigint` · `nStorageType tinyint` · `nOwner bigint` · `nStorage smallint` · `nItemID int` · `nFlags int =0` · `dDate datetime =getdate()`. PK `PK_tItem_nItemKey_NC` (nItemKey) nonclustered.
- **`tItemActionCoolTime`** (2 procs): `nCharNo int` · `nActionGroup smallint` · `sys_create_date datetime =getdate()` · `dEndTime datetime`. PK `PK_tItemActionCoolTime_CL` (nCharNo,nActionGroup); FK `FK_tCharacter_tItemActionCoolTime_nCharNo` nCharNo → tCharacter.nCharNo. *(w00 only.)*
- **`tItemEnchant`** (4 procs): `nItemKey bigint` · `nSlot tinyint` · `nGemItemID int` · `nRestCount tinyint`. PK `PK_tItemEnchant_CL` (nItemKey,nSlot); FK `FK_tItemEnchant_tItem_nItemKey` nItemKey → tItem.nItemKey cascade. *(w00 only.)*
- **`tItemMobList`** (4 procs): `nItemKey bigint` · `nMobID smallint` · `nGrade tinyint =1 [DF_tItemMobList_nGrade]` · `nKillCount int =0`. PK `PK__tItemMobList__2724C5F0` (nItemKey,nMobID); FK `FK_tItem_tItemMobList_nItemKey` nItemKey → tItem.nItemKey cascade.
- **`tItemOptions`** (26 procs; 13 rows in the backup): `nItemKey bigint` · `nOptionType smallint` · `nOptionData bigint`. PK `PK__tItemOptions__290D0E62` (nItemKey,nOptionType); FK `FK_tItem_tItemOptions_nItemKey` nItemKey → tItem.nItemKey cascade.
- **`tItemStorageFindEmpty`** (1 proc; 65536 rows in the backup): `nStorage int`. PK `PK_tItemStorageFindEmpty_CL` (nStorage). *(w00 only.)*
- **`tItemTitle`** (3 procs): `nItemKey bigint` · `nTitleType smallint =0` · `sTitle nvarchar(24)` · `nTitleCharNo int =0`. PK `PK__tItemTit__3556903A78E68B7D` (nItemKey); FK `FK_tItem_tItemTitle_nItemKey` nItemKey → tItem.nItemKey cascade.
- **`tKeyMapInit`** (2 procs; 95 rows in the backup): `nFunctionNo smallint` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nExtendedKey tinyint NULL` · `nASCIICode tinyint` · `sDescription nvarchar(1000) NULL`. PK `PK_tKeyMapInit_CL` (nFunctionNo). *(w00 only.)*
- **`tLog_GuildMasterChange`** (1 proc): `nRowNo bigint IDENTITY(1)` · `nGuildNo int` · `dDate datetime =getdate()` · `nOldGuildMaster int` · `nNewGuildMaster int`. PK `PK_tLog_GuildMasterChange_NC` (nRowNo) nonclustered. *(w00 only.)*
- **`tMarriage`** (12 procs; 1 row in the backup): `nCharNo int` · `nPartnerCharNo int` · `nStatus tinyint =0 [DF_tMarriage_nStatus]` · `nSubStatus tinyint =0 [DF_tMarriage_nSubStatus]` · `dWhen datetime` · `dSubWhen datetime` · `nMarriageCount tinyint =0 [DF_tMarriage_nMarriageCount]` · `nDivorceCancel tinyint =0 [DF_tMarriage_nDivorceCancel]`. PK `PK_tMarriage` (nCharNo,nPartnerCharNo).
- **`tMinihouse`** (2 procs): `nCharNo int` · `nVisitor int =0` · `dDate datetime =getdate()`. PK `PK_tMinihouse_CL` (nCharNo); FK `FK__tMinihous__nChar__7187CF4E` nCharNo → tCharacter.nCharNo.
- **`tMinihouseGate`** (3 procs): `nCharNo int` · `nItemID int` · `bType tinyint =1` · `dDate datetime =getdate()` · `dEndDate datetime NULL`. PK `PK_tMinihouseGate_CL` (nCharNo,nItemID); FK `FK__tMinihous__nChar__727BF387` nCharNo → tMinihouse.nCharNo.
- **`tPrison`** (5 procs): `nPrisonNum bigint IDENTITY(1)` · `nCharID int` · `dPrisonDate datetime =getdate() [DF_tPrison_dPrisonDate]` · `nMinute smallint` · `sReason nvarchar(16) NULL` · `nRegNumber bigint NULL =0 [DF_tPrison_nRegNumber]` · `sGmID nvarchar(16) NULL` · `sRemark nvarchar(64) NULL`. PK `PK_tPrison` (nPrisonNum) nonclustered.
- **`tQuest`** (3 procs): `nCharNo int` · `nQuestNo int` · `nStatus tinyint` · `sData varbinary(100)`. PK `PK__tQuest__3E52440B` (nCharNo,nQuestNo).
- **`tSkill`** (9 procs; 25 rows in the backup): `nCharNo int` · `nSkillNo smallint` · `nSkillLevel tinyint =1` · `nSkillExp int =0` · `nSkillWriteTime bigint =0 [DF_tSkill_dSkillWriteTime]` · `nSkillCoolTime int =0 [DF_tSkill_nSkillCoolTime_1]` · `nSkillPowerDemage tinyint =0 [DF_tSkill_nSkillPowerDemage]` · `nSkillPowerSP tinyint =0 [DF_tSkill_nSkillPowerSP]` · `nSkillPowerKeepTime tinyint =0 [DF_tSkill_nSkillPowerKeepTime]` · `nSkillPowerCoolTime tinyint =0 [DF_tSkill_nSkillPowerCoolTime]`. PK `PK__tSkillCharList__7814D14C` (nCharNo,nSkillNo).
- **`tSpamBlockTime`** (2 procs): `nCharNo int` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `nBlockTime int =0` · `nStandbyTime int =0`. PK `PK_tSpamBlockTime_CL` (nCharNo).
- **`tSpamFilter`** (2 procs): `nUserNo int` · `sys_create_date datetime =getdate()` · `sys_update_date datetime NULL` · `bIsSpamSpread bit =0` · `bIsSpamBlock bit =0` · `nSpamFilterRate tinyint =100`. PK `PK_tSpamFilter_CL` (nUserNo).
- **`tTutorial`** (3 procs; 1 row in the backup): `nUserNo int` · `nCharNo int` · `nState tinyint` · `nStep tinyint` · `dDate datetime =getdate()`. PK `PK_tTutorial_nUserNo_nCharNo_CL` (nUserNo,nCharNo). *(w00 only.)*
- **`tUserMoney`** (3 procs): `nUserNo int` · `nUserMoney bigint =0 [DF_tUserMoney_nStorageMoney]`. PK `PK_tUserMoney` (nUserNo).

#### `w00_GameLog`

- **`tGameLog`** (22 procs; 69 rows in the backup): `nLogNo bigint IDENTITY(1)` · `dDate datetime =getdate()` · `nType int` · `nCharNo int NULL` · `sMap varchar(16) NULL` · `nMapX int NULL` · `nMapY int NULL` · `nMapZ int NULL` · `nTargetCharNo int NULL` · `nTargetID int NULL` · `nItemKey bigint NULL` · `nInt1 int NULL` · `nInt2 int NULL` · `nInt3 int NULL` · `nBigint1 bigint NULL`. PK `PK__tGameLog__182C9B23` (nLogNo).

### 9.4 Private-server additions in the restored tables

Not 2016; a rebuild leaves them out:

- `Account.tUser.sUserNo`, `blsBlock`, `blsDelete` (nullable, NULL in the backup's only row, read by no procedure; the
  `bls…` spelling copies `bIs…` with an `l`).
- `Account.tUserMergeYet` (identity seed 100) and the `HttpGetMethod` call in `usp_User_USloginGame` that reads it ("added
  by John", D01): `dbo.HttpGetMethod` is not in the backup (an assembly or linked procedure), so the restored
  `usp_User_USloginGame` fails for any account listed in `tUserMergeYet` (empty in the backup).
- `w00_Character.tGuildEmblem`, `tGuildAcademyHistory` (created by `Fixes/Guild Emblem`, `Fixes/Guild Academy History`;
  their procedures are private-server reconstructions, D04 knowledge) and `tGuildHistory` (only in
  `Fixes/Guild History/tGuildHistory.sql`: `nGuildID int, nCharNo int, sID nvarchar(50), dDate datetime, nAction int`, all
  NOT NULL, no key; used by the Fixes-only `usp_Guild_setHistory` / `usp_Guild_getHistoryList`, which the 2016 binary
  calls with 5 and 3 parameters). The 2016 tables behind these calls are unknown; the Fixes shapes are the only evidence.
- `Account.tUserAuth` rows (0 Player, 1 Tester, 2 Staff, 3 Developer, 4 Owner, all loginable) are the private server's
  naming; the binaries only test `nAuthID` (D01).

### 9.5 Seed rows a rebuild must load

Tables whose rows are configuration, not player data (the other non-empty tables hold the backup's single test
account / character):

- **`tKeyMapInit`** (w00 only, 95 rows, `nFunctionNo:nExtendedKey/nASCIICode`; `p_Char_Create` and
  `usp_Character_initKeyMap` copy them into `tCharacterKeyMap`; `sDescription` Korean,
  not needed): 0:0/121 1:0/27 2:0/67 3:0/73 4:0/75 5:0/76 6:0/70 7:0/72 8:0/86 9:0/13 10:17/78 11:17/71 12:17/80 13:17/87
  14:0/222 15:0/88 16:0/71 17–20:0/0 21:0/82 22:17/65 23:0/87 24:0/83 25:0/0 26:0/65 27:0/68 28:0/90 29:0/32 30:0/38
  31:0/40 32:0/37 33:0/39 34:0/36 35:0/84 36:0/81 37:0/69 38:0/245 39:0/66 40:0/80 41:0/77 42:0/85 43:16/90 44–45:0/0
  46:0/35 47–55:0/49…57 (keys `1`–`9`) 56:0/48 57:0/189 58:0/187 59–67:16/49…57 68:16/48 69:16/189 70:16/187
  71–79:18/49…57 80:18/48 81:18/189 82:18/187 83–94:0/0. (`nExtendedKey` 16 / 17 / 18 = Shift / Ctrl / Alt, the Windows
  virtual-key codes `VK_SHIFT` / `VK_CONTROL` / `VK_MENU`; `nASCIICode` = the virtual-key code *(inferred)*.)
- **`tGameOptionInit`** (w00 only, 28 rows, `nOptionNo:nDefaultValue`, all `bIsActive = 1`; read by
  `usp_Character_getGameOption` as the default for options a character has not stored): 0:1 1:1 2:1 3:1 4:0 5:1 6:0 7:1 8:1 9:1 10:1 11:1 12:0
  13:0 14:0 15:0 16:1 17:0 18:0 19:0 20:1 21:0 22:0 23:0 24:1 25:1 26:1 27:1.
- **`tItemStorageFindEmpty`** (w00 only): the numbers 0–65535 (65,536 rows, one `nStorage int` each), the slot list
  `p_Item_GetStorageEmptyList` left-joins against `tItem` to find the first free slots of a storage (D03 §7.2).
- **`tUserAuth`** (Account): one row per `nAuthID` the servers use (0 = player; `bIsLoginAble` 1); names see §9.4.
- `tGuildTournament` (10 rows) is the schedule of the backup's last tournament (`nGTNo` = a Unix time, `nType` 0 / 4000+
  with times in `nData`), written by the procedures, not seed data.

### 9.6 Tables and columns the 2016 servers need that no backup has (*ours*)

| Table / column | Database | Defined in | Live in 2016 |
|---|---|---|---|
| `tUserPlayTime` | portal DB, not Fiesta's | §2.3 | no (KR teen protection) |
| `tSameTimeCharClass (nIndex, nClass, nCount)` | StatisticsData | §3.1 | yes (WM 0x080A) |
| `tEventL20` | AccountLog | §3.2 | no |
| `tLoginChannel` | w00_GameLog | §4.1 | yes (every character login) |
| `tPetInfo` | w00_Character | §5.1 | yes |
| `tCharacter.sLinkScrollDestMap` | w00_Character | §5.2, §6.2 | yes (`p_Char_GetAllData` column 37); `varchar(16)` like `sLoginZone` (§9.3) |
| `tMiniHouseURL` | w00_Character | §5.4 | no |
| `tGuildTournamentRegist.bIsRefundNotice` | w00_Character | §5.6 | yes |
| `tCharacterLoading` + `sFromMapName, sFromZoneIP, sToZoneIP, nToZonePort` | w00_Character | §6.1 | yes |
| `tCharacterLoadingDetailInfo` | w00_Character | §6.1 | yes |
| `tPromotionUser`, `tPromotionReward` | w00_Character | §6.4 | no |

The private-server shapes `tGuildEmblem`, `tGuildAcademyHistory`, `tGuildHistory` (§9.4) stand in for unknown 2016 tables.

### 9.7 `Character.bak` / `GameLog.bak` against the w00 copies

For the tables in §9.3, the older `Character.bak` differs only in: `tCharacter` lacks `nFriendPoint`, `nLastFriendPoint`;
`tCharacterSingleOption` lacks `nChatBan`, `nAutoBuff`, `nAutoChargedBuff`; `tCharacterState` lacks `nCasterLevel`,
`nCasterAttackPower` (its 19-param save procedure, §7.2); `tGuildAcademyMember` lacks `nChatBanTime`; `tGuildTournament`
lacks `nGuildNo`; `tGuild` has an extra `dMasterChange datetime = '2000-01-01'` (w00 logs master changes in
`tLog_GuildMasterChange` instead); `tGuildAcademy.sNotify` is NULL-able. 29 of the §9.3 Character tables exist only in
w00 (attendance, auto-minimon, game option / key map / short-cut, chat colour, card collection, gamble coin / dice /
jackpot / slot machine, emblem, academy history, in-game guide, item-action cool time, enchant, storage-find helper,
master-change log, tutorial). Every one is reached by a procedure the 2016 binary calls with w00's parameter count, which
is the reason to follow w00 (D02 knowledge). `tGameLog` is identical in `GameLog.bak` and `w00_GameLog.bak`.

## 10. Original-server bugs

Tagged in place with `(original bug) D06-B<n>`. They are bugs of the 2016 server binaries as they meet the database
(the procedure bodies a rebuild writes are not bugs of 2016).

| ID | Handler / procedure | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D06-B1 | AccountLog `usp_AccountLog_GetDateDiffLastlogout` (FUN_00415020, §3.4); Character `usp_Pet_setCreate` / `usp_Pet_getInfo` (§5.1); the same code shape in Account `usp_ReturnUser_GetDatediffLastlog`, `usp_User_GetDatediffCreated` (harmless there: their bodies never set `@nRet` ≠ 0) | the wrapper tests the output `@nRet` right after `SQLExecDirect` of a procedure that returns a result set on its error path too | SQL Server returns output parameters only after the last result set is consumed (§1.2 driver rule), so the test always sees the pre-set 0: dead error check *(inferred from the ODBC rules)*. Not `usp_Character_getFriendpoint` / `GetDiffFriendpoint`: their error path has no result set, so the test works (§6.3) | test `@nRet` after `SQLMoreResults`, or return the code as a column |
| D06-B2 | zone 0x347D mini-house effect payment (FUN_00574a30) → `p_Item_MiniHouse_Effect_Resource_Del` (§5.3) | a money-only effect leaves item key / lot of the request stale | the procedure receives an old item key and lot; with a body that checks them, a money-only payment can fail or consume the wrong item | zero the item fields when the effect costs money only |
| D06-B3 | WM 0x74F8 tournament refund notice → `usp_GuildTournament_setRefundNotice` (§5.6) | the refunds the notice announces are paid by no 2016 component (the zone's 0x74F4 handler is empty) *(inferred)* | guilds that were not chosen never get their fee back, though the DB marks the refund as announced | pay the fee back (`p_Guild_SetMoney`) before marking it |
| D06-B4 | Character 0x0841 loading report → `usp_CharacterLoading` / `…DetailInfo` (FUN_00420b80, §6.1) | the IP strings are copied as 16 raw bytes but bound as NUL-terminated strings; u16 / u32 client values are bound into SMALLINT / INTEGER | an IP of 16 characters reads past the field; large values overflow and the report row is lost | bound the copies with a terminator; bind the matching unsigned ranges |
| D06-B5 | `p_Promotion_Get` / `p_Promotion_Set` (FUN_0041eff0, §6.4) | "already rewarded?" and "mark rewarded" are two calls, not one transaction | two simultaneous requests can both get the reward (path dead in 2016: no sender of 0xA001 / 0xA004) | one procedure that checks and marks under a lock |
| D06-B6 | Character `CharSaveState` (FUN_00406070) → `p_Char_SetStateWithSetItemAndRestTime` (FUN_00460ee0, §7.2), and the loader FUN_0046c6e0 of `p_Char_GetStateAllWithSetItemAndRestTime` | `CasterInfo.nAttackPower` (32-bit) is copied as its low 16 bits (bound `SQL_C_USHORT`) on save and fetched with `DB_GetU16` on load | a caster attack power above 65 535 is saved and reloaded wrapped; the buff reloads weaker | bind and fetch the full 32-bit value |
| D06-B7 | all four DB servers `DBRecord::query` with the `ODBC_INFO` startup command (§7.3) | the configured text is used as the `vsprintf` format with no arguments, into a 0x2000-byte buffer | a `%` in the command is undefined behaviour; a longer command overflows the stack buffer | pass the text as data (`"%s"`), bound the length |
| D06-B8 | Character `p_Item_GetStorageEmptyList` (FUN_00464b40, §9.2) | `@nRet` is bound as input (`SQL_PARAM_INPUT`, pre-set 0) | the wrapper's `nRet != 0` test is dead; a DB-side refusal is never seen and the (possibly empty) rows are used | bind it `SQL_PARAM_OUTPUT` |

## 11. Not reconstructed / uncertain

- **Procedures without source** (§2–§6): every block is the narrowest contract the binary's binds, fetches and code
  mapping force; bodies, table names and some column names are *(ours)*. Tables invented: `tUserPlayTime` (§2.3),
  `tSameTimeCharClass` (§3.1), `tEventL20` (§3.2), `tLoginChannel` (§4.1), `tPetInfo` (§5.1), `tMiniHouseURL` (§5.4),
  `tCharacterLoadingDetailInfo`, `tPromotionUser`, `tPromotionReward` (§6), columns `tCharacter.sLinkScrollDestMap`
  (§5.2), `tGuildTournamentRegist.bIsRefundNotice` (§5.6); §9.6 lists them with types.
- **Account:** the portal tables behind the teen-protection trio and the Netmarble / TW / JP logins (§2.3, §2.4) are
  unknown (only one is live: `usp_Pcbang_chkIP`). The `nUserNo == −2` agreement answer of 0x4B (§2.5) is produced by no
  backup procedure: left open (a payment-agreement table exists for the web shop only).
- **AccountLog:** the L20 event result codes (§3.2) come from `p_Event_WorldCup_Enter` of the same family, not from a
  2016 body; the path is dead in 2016.
- **Character:** `usp_GuildAcademy_withdrawMoney`'s 1–6 order (§5.7) is *(inferred, weak)*; which statements gave
  `usp_Character_setStatPoint` −1091 / −1092 / −1094 (§6.5) is left open (the backup body is enough for a rebuild);
  `usp_CharacterLoading`'s `nFailType` / `nErrorNo` values (§6.1) are client-side and not traced; whether the
  enchant procedures (§8.4) are the official bodies cannot be decided.
- **D06-B1 / D06-B3** rest on the ODBC driver rule and on the absence of a payer in all 2016 binaries; a capture with a
  tournament refund or a pet creation would settle them.
- **Storage type 10** (§8.6) stays *(inferred)*. Wedding: the client text of 0x1384 (id 0xCAEDDB1D) is missing from the
  2016 `TextData*.shn`; the 0x1090 sub-status bytes on a failed cancel are stale stack bytes *(inferred)* (§8.6).
- **Schema** (§9): types, defaults and keys are those of the 2019 restore. Where a 2016 column differs, only the binds
  show it (§9.2: systemic unsigned → signed, 7 real mismatches). The private-server tables of §9.4 stand in for 2016
  tables that are not in any backup.
- **Version choices** (§8): the w00 dump is from 2019 and carries 2018 private fixes; §8.5 follows w00 where a 2016 bind,
  fetch or code mapping proves it and keeps the older copy where w00 holds a dated private fix (`p_Char_Rename`,
  `usp_Character_setChangeID`, `usp_Tutorial_setCharInfo`). `p_Quest_Set`'s quest-20016 counter and the
  `usp_Dice_setDiceResult` loss rule cannot be decided from the binary (both versions work with it).

## 12. Coverage boundary

D06 has no scope table (`coverage.py D06`: "no scope table; coverage does not apply"). Every procedure in the plan's scope
list has a block (§2–§6, re-checked with `bak.py cover` for account / accountlog / character / gamelog in the sweep: the
missing and mismatching names are unchanged); every caller of every documented wrapper is cited here or in its D0x
section (sweep: one caller added, `GetCharOptionImprove_KeyMapData` FUN_00422660, §5.7).

| Found (function / table / behaviour) | Covered by | Argument |
|---|---|---|
| Server handlers around each procedure (packets, error-code mapping, client texts) | D01 §2–§5, D02 §2–§15, D03 §2–§15, D04 §1–§11, D05 §1–§6 (all done) | D06 documents the procedure side only and links each handler there |
| Backup tables and procedures no 2016 binary reaches (§9.1 list: one-off copies, web-shop agreement procs, `p_Event_Friend_Reward`, old `tPet` / `tMiniHouse`, `LoggedInChars`) | none needed | §9.1 builds the table set from the dependency closure of the called procedures; unreached objects carry no 2016 behaviour (used here only as family evidence) |
| `OperatorTool` DB (tOperator, tMenuAuth, tOpLog) | none needed | used by no 2016 server binary (ODBC_INFO lists no DSN for it, §9.1); it belongs to an external GM tool that is not part of the reconstruction |
| Zone `Checker::DivorceLimit` FUN_005a1c90: Sub 0 lock reset, Sub 1 / 2 refund-cancel lock, Sub 5–8 branches | this document §8.6 | Z07 (done) §5.1 lists Sub 1–4 only and leaves Sub 0 "(not traced)"; the missing parts were a small gap, documented here because they decide the meaning of the DB's "+4" values |
| Zone 0x347D sender FUN_00574a30 (D06-B2) and zone 0x74F4 (D06-B3) | Z07 §6.10 (0x347D), Z08 §8.2 0x74F4 "empty body" (both done) | D06 records only what reaches the DB; the zone handlers themselves are documented there and only the DB consequence is new |
| `ItemDropLog` (D05 §9) | Z01 §2.3 (done) | SHN table read by the zone, not a database table |
| Client meaning of `usp_CharacterLoading`'s `nFailType` / `nErrorNo` (§6.1) | W04 §17.3 (done: the 0x0840 packet and its forwarding) | client diagnostics stored verbatim; no server or DB logic reads them, so a rebuild needs only the column types (§6.1); left in §11 |
| Client handling of the wedding codes 0x1384–0x1389 in 0x205D (`WeddingTask::Recv_NC_ACT_WEDDING_DIVORCE_REQ_ACK` FUN_006dd040) | this document §8.6 | the client handles them in its own handler, not through the error table; texts resolved from `TextData*.shn` (small gap, documented here) |
| 0x1090 sub-status bytes (D02 §16 open point) | this document §8.6 | settled from the asm of FUN_00419730 and the w00 body (small gap) |

No follow-up item was created: every remaining thing is either documented here, in a finished item's section cited
above, or outside the 2016 server binaries.
