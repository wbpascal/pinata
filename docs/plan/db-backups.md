# Database backups (`Files/Server/2016/_Database/`)

SQL Server backups of the game databases, plus `Fixes/`: `.sql` scripts a private-server team wrote in 2018–2019.
**None of it is guaranteed original.** All backups come from private-server installations, which edited some procedures
and wrote others from scratch. Most of the procedure source still matches the binaries' `{CALL …}` strings, so it is a strong
hint for what a procedure does: tables and columns, result order, the meaning of return codes. The 2016 binary decides. A fact
taken only from a backup is marked *(db-backup)* until a 2016 binary agrees (parameter count, `SQLGetData` column order and C
types, result codes the code checks).

## What is there

| File | SQL Server | Server that uses it (ODBC_INFO in `9Data/ServerInfo/ServerInfo.txt`) | Content |
|---|---|---|---|
| `Account.bak` | 2017 | Account (`Account`) | 77 procedures: login (`usp_User_loginGame`, `usp_User_USloginGame`, `usp_User_chkBlock`), user, cash/shop, payment, OPTool. Most have original Korean headers |
| `AccountLog.bak` | 2008 R2 | AccountLog (`AccountLog`) | 27 procedures (`p_AccountLog_*`, `p_IPBlock_*`, `p_Report_*`, `p_Event_Friend_*`, `usp_EventiPad_*`, `usp_Log_setLogout`) |
| `StatisticsData.bak` | 2008 R2 | AccountLog (`Statistics`) | 18 procedures (`p_Day*`, `p_SameTime*`, `p_User*`) |
| `OperatorTool.bak` | 2008 R2 | none of our binaries (no ODBC entry, no string refers to it) | 18 procedures (`p_OPLog_*`, `p_Operator_*`, `p_OPTMenu_*`) of the separate operator tool. Out of scope |
| `Character.bak` | 2008 R2 | Character (`w00_Character`) | **older** Character DB: 324 procedures, about 60 tables. Contains player data, latest date seen 2015 |
| `w00_Character.bak` | 2017 | Character (`w00_Character`) | **newer** Character DB: 405 procedures. The `Fixes/` scripts are already applied in it |
| `GameLog.bak` | 2008 R2 | GameLog (`w00_GameLog`) | older GameLog DB: 31 procedures (`p_GameLog_Add_Type1…K`, some `usp_Character_*`) |
| `w00_GameLog.bak` | 2017 | GameLog (`w00_GameLog`) | newer GameLog DB: 26 procedures, adds `p_GameLog_Add_TypeL` |
| `Fixes/<topic>/*.sql` | – | – | 14 procedures and 3 tables (`tGuildEmblem`, `tGuildHistory`, `tGuildAcademyHistory`) written or changed by the private-server team (SSMS script dates 2018–2019) |

All backups are uncompressed (MTF/`TAPE` format), so the tool below reads them without SQL Server.

## Tool

```bash
T=tools/protocol-re; B=Files/Server/2016/_Database
python3 -I $T/bak.py cover character 'Guild'                  # every {CALL} of the binary vs every backup and Fixes script
python3 -I $T/bak.py $B/w00_Character.bak proc p_Char_Create  # procedure source, every distinct stored version
python3 -I $T/bak.py $B/Character.bak proc p_Char_Create      # ... the same procedure in the older backup, to compare
python3 -I $T/bak.py $B/w00_Character.bak procs '^usp_Guild'  # procedure names with source, with origin hints
python3 -I $T/bak.py $B/Character.bak names '^t'              # object names (tables, constraints…), heuristic
```

- `cover` prints one line per procedure the binary calls: every source that has it, `=` when its parameter count equals the
  binary's, otherwise the source's count, plus origin hints. `MISSING` = no source anywhere.
- Origin hints: `KR` = Korean header comment, as the original developers wrote them (authors such as CJC, Ko Dong Gyun,
  JK CHO, Lunar; 2004–2014). `3RD?` = a private-server mark (author `<KHRISMIZER>`, SSMS script date 2018/2019). They are
  hints only. Example: `usp_GuildEmblem_SetInfo` carries a copied original header ("Set Guild Token, 2008.12 By Lunar") but
  has a parameter named `@nUnk`, so it is a private-server reconstruction. An original header does not prove the body was
  not edited either (the `Fixes/Duplicate Names/p_Char_Create.sql` fix keeps the 2004 header), and a missing `KR` does not
  prove a procedure is third-party (see the end of this page).
- Source longer than one 8 KB page is rejoined from its LOB fragments (added by D02; it fixed `usp_Character_setStatPoint`
  and others). `TRUNCATED?` means only that the text does not end in `END`/`RETURN`/`GO`; most flagged definitions are
  complete (they end in `SET @nRet = 1` or a bare `SELECT`). Really cut off: `usp_Character_setChatBan` (Character.bak;
  a NUL character inside the text; w00 has it whole) and `IndexOptimize` (w00, third-party maintenance script, stops
  after two fragments; not investigated). Comments in Latin-1 / Latin Extended characters (Korean saved through the
  wrong code page, umlauts) are read as text since D02.
- `N versions` = several stored copies (old pages, `ALTER`s). Compare them.
- Table **columns** are not extracted. Read them from the procedure source (`INSERT`/`SELECT` lists) or from the `Fixes/`
  table scripts. For the full schema and data, restore a backup into SQL Server 2017 or newer (not done yet; it needs Docker
  or a Windows SQL Server).

## Which version to trust

1. The parameter count must match the binary's `{CALL}` string. If only one version matches, that is the one the 2016 server
   was written against.
2. Between versions that match, prefer the one with an original Korean header and no private-server marks. Where
   `Character.bak` and `w00_Character.bak` both have it with the same text, that is the most reliable case (99 of the
   Character server's procedures).
3. Where they differ (123 Character procedures), either the original developers changed it between the two snapshots or the
   private-server team did. Say which version you used and why.
4. A procedure that only exists as private-server work (list at the end of this page, or only in `Fixes/`) is a third party's guess
   at what the server needs. Use it only to cross-check the binary, and say so.

## How well they match the 2016 binaries

Output of `bak.py cover <bin>` (procedure exists, same parameter count):

| Binary | Procedures called | Source somewhere | Same parameter count | Missing |
|---|---|---|---|---|
| account | 15 | 7 (Account.bak) | 6 | 8 |
| accountlog | 12 | 8 (7 AccountLog.bak, 1 StatisticsData.bak) | 8 | 4 |
| character | 311 | 296 | 294 | 15 |
| gamelog | 23 | 22 | 22 | 1 |

**Parameter count differs in every source:**
- `usp_User_LoginGame` (binary 5, Account.bak 6). SQL Server names are not case-sensitive, so this is the same procedure as
  `usp_User_loginGame` (binary 6, matches). The 5-parameter call would fail against this DB; find out which code path uses it.
- `usp_CharacterLoading` (binary 11, both Character backups 6).
- `usp_Character_setFriendpoint` (binary 2, w00_Character 3).

`p_Item_BuyAll` and `p_Item_BuyLot` match only in `w00_Character` (the older `Character.bak` has one parameter fewer).

**Missing** (no source anywhere; reconstruct from the binary alone):
- account: `usp_User_LoginNetmarble`, `usp_JPUser_insert`, `usp_TWUser_insert`, `usp_Pcbang_chkIP`, `usp_Event_addCash`,
  `p_UserKey_Get_FromAccount`, `p_UserPlayRemainTime_Get_FromAccount`, `p_UserPlayRemainTime_Set_FromAccount`
- accountlog: `p_Event_L20_Get`, `p_Event_L20_Set`, `p_SameTimeCharClass_Add`, `usp_AccountLog_GetDateDiffLastlogout`
- character: pets (`usp_Pet_getInfo`, `usp_Pet_setCreate`, `usp_Pet_setDelete`, `usp_Pet_setName`, `usp_Pet_setTendency`),
  `usp_CharacterLoadingDetailInfo`, `p_Promotion_Get`, `p_Promotion_Set`, `p_IsPromotionUser`, `p_Guild_SetMoney`,
  `usp_GuildTournament_setRefundNotice`, `usp_LinkScroll_SetDestMap`, `p_Item_MiniHouse_Effect_Resource_Del`,
  `p_MiniHouseURL_Get`, `p_MiniHouseURL_Set`
- gamelog: `usp_Login_setChannel`

**Likely private-server work** (treat as third-party unless the binary agrees):
- `usp_GuildEmblem_GetInfo`, `usp_GuildEmblem_GetInfoAll`, `usp_GuildEmblem_SetInfo`, `usp_GuildAcademy_setHistory`: header
  copied from `usp_Guild_SetToken`; `usp_GuildEmblem_SetInfo` has a parameter named `@nUnk`; also in `Fixes/`.
- `usp_Guild_getHistoryList`, `usp_Guild_setHistory`: only in `Fixes/`.
- gem enchant `usp_Item_Add_EnchantGem`, `usp_Item_Add_EnchantSocket`, `usp_Item_Del_EnchantGem`, `usp_Item_Get_EnchantAll`,
  `usp_Item_Set_EnchantGemLot`: SSMS template header by `<KHRISMIZER>` (dated 2010, origin unclear).
- the `Fixes/` edits of existing procedures: `usp_ChargeItem_Draw`, `usp_ChargeItem_GetList`, `p_Char_Create`, `p_Char_Rename`,
  `usp_Character_setChangeID`, `usp_Tutorial_setCharInfo`, `p_IPBlock_IsBlock`. Compare with the backup versions; the older
  `Character.bak` / `AccountLog.bak` copy is the pre-fix one where it exists.

Several procedures only in `w00_Character` show no `KR` hint although they are original: their header was split off by a page
boundary, or the 2017 DB turned the Korean text into `?` (e.g. `usp_Gamble_getJackpotCoin`, "Ko Dong Gyun, 2011.7.13").
Look for the Ko Dong Gyun header layout (`' 이  름 :` … `' Parameter :` … `@nRet int = 0 output`) before calling one third-party.

Run `bak.py cover <bin>` again whenever a backup is added or replaced, and update this page.
