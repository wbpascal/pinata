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
- Client side: 0x082E NC_MISC_EVENT_L20_CMD `{ u8 nEventNo, u16 nError }` (pdb2017) is forwarded by the WM for every code
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
        UPDATE tGuildTournamentRegist SET bRefundNotice = 1 WHERE nGTNo = @nGTNo AND nNo = @nNo
        IF @@ERROR <> 0: SET @nRet = -1493
```

- `bRefundNotice` is a 2016 column the backups' `tGuildTournamentRegist (nGTNo, nNo, nMoney, nSeed, bChoice, dDate)` does
  not have (constraint names `DF__tGuildTou__nSeed`, `__bChoi`, `__dDate`; `bak.py names` / UTF-16 scan of Character.bak).
  The 2016 `getRegistList` returns it as the 4th column (§5.7) and the WM keeps it as `GT_EnterList.bIsRefundNotice`
  *(pdb2017 field name; W03 §8.1)*. Column name ours.
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
SELECT nNo, nMoney, CAST(bChoice AS tinyint), CAST(bRefundNotice AS tinyint)
  FROM tGuildTournamentRegist WITH (NOLOCK) WHERE nGTNo = @nGTNo
```

(`tinyint` converts to both U8 and I32; the column order is the fetch order, the money column carries the refund amount
= the paid fee *(inferred)*.)

**`usp_Character_getKeyMap` −2721 / −2725 (D04 §5.2, 0x7057).** The w00 procedure (Ko Dong Gyun 2010.09.13) returns no
result set and `@nRet = −2725` when the character has no `tCharacterKeyMap` rows; −2721 is the family's "not found
nCharNo" (`usp_Character_getShortCutList`, same author and date). The 2016 handler only skips its log line for −2721;
both values give the same behaviour (no answer, D04-B14). For a rebuild the difference is cosmetic; −2721 keeps the
2016 log quiet. After `usp_Character_initKeyMap` the rows always exist unless `tKeyMapInit` is empty.

**`usp_GuildAcademy_withdrawMoney` 1–6 (D04 §9.3, 0x986B).** Both backups (2008.5.14, w00 adds `UPDLOCK, HOLDLOCK`
2011.7.11) return 0 or −1511 / −1512 / −1514 / −1524 / −1525 / −1527 / −1593. The 2016 wrapper (@ FUN_00456510) passes
`nRet` through unchanged, and the handler switches on 1…6 (→ 0xF99…0xF9E), other → 0xF98. So the 2016 procedure had
positive codes; their order most likely follows the six checks in the procedure *(inferred, weak)*: 1 invalid guild
number, 2 invalid character number, 3 invalid amount, 4 character not found / deleted, 5 academy not found, 6 not enough
academy money; a DB error falls to 0xF98. In 2016 the handler only calls it with `0 < amount ≤` the money it has just
read (D04 §9.3), so only 6 (concurrent withdrawal) and DB errors are reachable. A rebuild can keep the w00 body and map
its negative codes to 1–6 in that order; nothing outside the Character server sees the codes except 0x986C's `Error`.
