# Character server: characters, avatars, save/load (D02)

Source binary: `Files/Server/2016/w00_Character/Character Release.exe`, export `re-data/exports/character`
(`python3 -I tools/protocol-re/clean.py re-data/exports/character tools/protocol-re/names/character <addr>`).
Names found here: `tools/protocol-re/names/character/D02.json`. Layouts: `docs/protocol/annotations/D02.json`.
Procedure source: `Files/Server/2016/_Database/Character.bak` (older, 2008 R2) and `w00_Character.bak` (2017), read with
`tools/protocol-re/bak.py`; see `docs/plan/db-backups.md`. A fact only a backup shows is marked *(db-backup)*; a name or
layout only the 2017 PDB shows is *(pdb2017)*; deductions *(inferred)*. Tables and columns: `docs/knowledge/D02.md`.

Peers: the WM (most requests, all avatar/char-select traffic, `0x1004` character load) and the zones (dept 16 saves,
wedding, stats, styles, attendance, promotion). Every reply goes back on the link the request came from. Most requests
carry the WM client handle (`NETPACKETHEADER {u16 clienthandle}`) at payload +0; zone requests carry the 6-byte
`NETPACKETZONEHEADER {u16 clienthandle, u32 charregistnumber}` (`docs/knowledge/C02.md` §3). Opcode names are the 2016
binaries' (handler log strings and `handlers.json`); field names follow the 2017 PDB where it agrees with the 2016 code.

## 1. Process structure

The Character server is the same "DataServer" framework as Account and AccountLog (`docs/pseudocode/db/D01-account.md` §1):
config `DataServerInfo_Character.txt` (`MY_SERVER "PG_W00_CDB", "_2015_Character", 2, 0, 0` → server type 2 = CharDB),
`#INCLUDE ../9Data/ServerInfo/ServerInfo.txt`, one ODBC row "BASE" = `w00_Character` per session worker
(`DB_Init` @ FUN_0043e040, worker loop @ FUN_0043e130, `"<NUMBER OF %d SESSION WORKER STARTED>"` @ FUN_0043e9e0).
Handlers run on a worker with its own connection; the handler's DB object is `*this + 0x124c`.

```
Character DataServer (global object g_Server = DAT_004e2a68, loaded by GameData_Load @ FUN_00401550)
├── ItemInfo.shn              → DAT_006ed408 (item id → row; +0x66 Class, +0x6e Equip used by create)
├── DefaultCharacterData.txt  → +0x209890 = DAT_006ec2f8: per class CHARACTER {class, map, x, y, HP, SP, HP stones,
│                               SP stones, money, InitLV, InitEXP}, ITEM {class, id, lot}, SKILL, QUEST, MAXSHAPE, SHORTCUT
├── FaceInfo.shn / HairColorInfo.shn / HairInfo.shn → DAT_006ec7f0 / DAT_006ec830 / DAT_006ec870 (create: Grade must be 0)
├── ItemInfo "HairShop01".."HairShop05", "UniChange01" (beauty-shop item ids, §8)
├── HolyPromiseReward.shn (+0x209e58), AttendReward.shn (+0x209ed8, §9), TutorialCharacterData.txt (+0x209f4c, §10)
├── MapInfo.shn               → DAT_006ecee8
└── a second batch of SHN tables (ChargedDeletableBuff, MinimonAutoUseItem, MinimonInfo, TermExtendMatch, ChatColor,
    PupMain, ItemMoney, MarketSearchInfo, SingleData, ItemViewEquipTypeInfo, GTIView, CollectCardView) @ FUN_00442cd0
```

Outgoing link: the GameLog server. `g_GameLogLink` (DAT_006ecee0) is the session of peer type 3; it is cleared when that
session closes (@ FUN_0043de40). Many handlers send a log packet to it after a DB write ("if g_GameLogLink: send").

### 1.1 Helpers used by every handler

```pseudo
CheckAlive(pkt):  @ FUN_0043c640 — same as D01 §1.1: session.state(+0xdc) == 0 → log "packet before authentication", ignore.

SQL wrapper (one CSQLPCharacter function per procedure, list in §15):
    stmt = db.stmt (FUN_0044fdd0); SQLCloseCursor; SQLBindParameter per '?'; SQLExecDirect("{CALL …}")
    success = rc in {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO} and, for most, the OUTPUT @nRet has the expected value
    some log "ERROR - CSQLPCharacter::<proc>, ret(%d), nRet(%d)" or SQLError text (FUN_00451ec0)

Result rows (column index auto-increments, reset by DB_Fetch):
    DB_Fetch @ FUN_0044fb90 (SQLFetch)          DB_CloseCursor @ FUN_0044fbc0 (SQLCloseCursor)
    DB_GetI32 @ FUN_0044fbd0 (C type -16)       DB_GetU8  @ FUN_0044fc00 (-28)     DB_GetU16 @ FUN_0044fc30 (-17)
    DB_GetU32 @ FUN_0044fc60 (-18)              DB_GetI64 @ FUN_0044fc90 (-25)     DB_GetU64 @ FUN_0044fcc0 (-27)
    DB_GetStr @ FUN_0044fcf0 (1, SQL_C_CHAR)    DB_GetBin @ FUN_0044fd40 (-2)      DB_GetTime @ FUN_0044fda0 (11, TIMESTAMP_STRUCT)

Sends: CSendPacket Init @ FUN_0044f880, SetOpcode(op, payloadSize) @ FUN_0044fa10 (payload at +5, correct framing),
       Session_SendPacket @ FUN_0043d5f0, Session_SendRaw(frame, n) @ FUN_0043d620 (hand-built {u8 len, u16 op, …}),
       Session_SendPacketTo(session, pkt) @ FUN_0044ce10 (used for g_GameLogLink).
MakeItemKey() @ FUN_004041d0: u64 item registration number = packed local time (GetLocalTime) | 16-bit counter DAT_006edd54++.
```

## 2. Server-link handlers (CPFs, registered @ FUN_0043d2f0)

The CPFs handlers are the D01 ones (§2 of `D01-account.md`), same code after renaming, with one addition:

```pseudo
0x0801 NC_MISC_S2SCONNECTION_RDY, 0x0805 NC_MISC_HEARTBEAT_ACK: return 1 (no-op)     @ FUN_0043c7a0, FUN_004503c0
    # 0x0801 is registered with a sender of 0x0802 (handlers.json); the outgoing handshake to the GameLog server
0x0804 NC_MISC_HEARTBEAT_REQ:              @ LAB_0043cdf0 (not decompiled; reply 0x0805 as in Login, inferred)
0x0823 NC_MISC_START_THE_BOOM_CMD:         @ FUN_0043d2d0  CheckAlive only, no action

0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo, u8 server_id_to, u8 server_id_from, u8 world, u8 zone, u16 key }:   @ FUN_0043c880
    checks as D01 (state, server_id_to == 2, key == to + from)
    if g_GameLogLink == null or a check failed: close(session)            # NEW: links are refused until GameLog is connected
    else reply 0x0803 { u8 echo, u16 0 }; session.state = 1; session.type/world/zone = from/world/zone
0x0803 NC_MISC_S2SCONNECTION_ACK:          @ FUN_0043cd20  (as D01)
0x2801 / 0x2803 / 0x2805 / 0x2807 OPTool:  @ FUN_0043ce10 / FUN_0043d000 / FUN_0043d0b0 / FUN_0043d180  (as D01, my_type = 2)
```

## 3. Avatars (char select): list, create, delete, rename, guild

### 3.1 Avatar list

```pseudo
0x0C12 NC_USER_AVATARINFO_REQ { u16 clienthandle, u32 usrregnum }  (from the WM)   @ FUN_004050b0
    if !CheckAlive: return
    if !p_Char_GetListOfUserChar(userNo): goto fail                               @ FUN_00458480 (param 3 = 0)
        # SELECT nCharNo FROM tCharacter WHERE nUserNo = @nUserNo AND bDeleted = 0   (row order not defined) (db-backup)
    chars[] = every row's nCharNo (DB_GetI32)                                     # no limit on the count (inferred: ≤ 6 by slots)
    if !usp_Tutorial_getIsSkip(userNo, out nRet):                                  @ FUN_0045f9d0
        log "CPFsCharacter::fc_NC_USER_AVATARINFO_REQ - usp_Tutorial_getIsSkip, nUserNo=%d"
        Send 0x0C13 { u16 handle, u8 numofavatar = 0xFF }; return                 # 0xFF = error marker
    isSkip = last row's u8 (0 if no row)   # SELECT nState FROM tTutorial WHERE nUserNo=@nUserNo AND nState=1 (db-backup)
    Send 0x0C5F { u16 handle, u8 isSkip }                                         # tutorial "skip" right of the account (inferred)
    for each charNo: if !GetAvatarInfo(charNo, &avatar[i]): goto fail           @ FUN_0046bff0 (§3.2)
    for each avatar: avatar.CharIDChangeData = { bNeedChangeID 0, bInit 0x64, nRowNo 0 }   # 0x64 default (inferred: "none")
    if usp_Character_getChangeIDList(userNo, out nRet == 0):                       @ FUN_0045e5f0
        for each row (i32 nRowNo, u32 nUserNo, u32 nCharNo, u8 bInit):          # tCharacterChangeID WHERE bFlag = 0 (db-backup)
            avatar with chrregnum == nCharNo: bNeedChangeID = 1, bInit = bInit, nRowNo = nRowNo
        # a failed call is only logged; the list goes out without rename rights
    Send 0x0C13 NC_USER_AVATARINFO_ACK { u16 handle, u8 numofavatar = n, PROTO_AVATARINFORMATION avatar[n] }   # 3 + n·0x82
    return
fail:
    log "…%d…" (DAT_004ae450, userNo); Send 0x0C13 { u16 handle, u8 0xFF }      # the WM shows no list (W01 §3.3)
```

### 3.2 GetAvatarInfo (the 130-byte AVATAR record)

`CGameDB_Character::GetAvatarInfo` (name from its log string) @ FUN_0046bff0 fills `PROTO_AVATARINFORMATION` (layout:
`annotations.json` struct `AVATAR`, W01-core §6.1). Column order of its procedures (verified against the SQLGetData calls):

```pseudo
GetAvatarInfo(charNo, out a):                                                       @ FUN_0046bff0
    p_Char_GetLoginData(charNo) and DB_Fetch                                       @ FUN_004584f0
        # result row (C types): sID str → a.name[20]; nLevel u16 → a.level; nSlotNo u8 → a.slot; sLoginZone str → a.loginmap[12];
        # bDeleted u8 + dDeletedDate ts → a.delinfo (see below);
        # nRace u8 → shape.race (2 bits), nClass u8 → shape.chrclass (5 bits), nGender u8 → shape.gender (1 bit),
        # nHairType, nHairColor, nFaceShape u8; nKQHandle i32 → nKQHandle; sKQMap str → sKQMapName[12];
        # nKQX u32, nKQY u32 → nKQCoord; nKQD u32 (read, not stored); dKQDate ts → dKQDate (packed 4/4/5/5/6/6 bits)
        # SELECT list: tCharacter C ⋈ tCharacterShape S (db-backup; matches the 18 SQLGetData calls in order and type)
    equipment = ItemList(charNo, type 8, max 30)                                   @ FUN_0046a2c0 → FUN_00469f70 (§3.6)
    a.equip.* = 0xFFFF (memset 0x2b bytes); a.equip.upgrade = 0; CharIDChangeData = 0
    for each equipped item: switch item.slot (u16):                                # slot → AVATAR field (W01 §6.1)
        1 Head, 7 righthand(+0x36, + upgrade nibble from item options FUN_004681a0), 8, 9, 10 body(+0x38 + upgrade),
        11, 12 leg(+0x34 + upgrade), 13, 17, 0x16…0x1d other visible slots; unknown slots ignored
    usp_Tutorial_getCharInfo(charNo, out nRet) else log "CGameDB_Character::GetAvatarInfo - usp_Tutorial_getCharInfo, nCharNo=%d"; return 0
        row (u8 nState, u8 nStep) → TutorialInfo { nTutorialState = nState, nTutorialStep = nStep }
        no row → nTutorialState = 3, nTutorialStep = 0                              # 3 = no tutorial record (pre-tutorial character)
    return 1
```

`delinfo` (+0x27, 5 bytes): if `bDeleted == 0` only +0x27 = 0; else +0x27 = `(u8)(dDeletedDate.year + 0x30)` = year − 2000 (mod 256), +0x28..+0x2b =
month, day, hour, minute (low bytes). Characters with `bDeleted = 1` never reach this function from 0x0C12 (the list excludes
them), so the field is always 0 on the wire *(inferred)*.

### 3.3 Create

```pseudo
0x1402 NC_AVATAR_CREATEDATA_REQ { u16 clienthandle, u32 usrregnum, u8 createworld, u8 adminlevel, u8 slotnum,
                                  char name[20], u8 shape(race:2,chrclass:5,gender:1), u8 hairtype, u8 haircolor,
                                  u8 faceshape }   (33 bytes, from the WM 0x1401)                      @ FUN_00404b30
    if !CheckAlive: return
    r = CreateCharacter(payload)                                                    @ FUN_00404280
    if r >= 1:
        if GetAvatarInfo(r, &avatar):
            Send 0x1405 NC_AVATAR_CREATEDATASUC_ACK { u16 handle, u8 numofavatar = 1, AVATAR avatar }   # 0x85 bytes
            return
        p_Char_Wipe(r); r = 0                                                       # wrapper return value ignored
    Send 0x1403 NC_AVATAR_CREATEDATAFAIL_ACK { u16 handle, char charid[20] = request name, u16 err }   # 0x18 bytes
        err = 0x184 if r == -3, 0x183 if r == -2, 0x182 if r == -1, else 0x181
        # client (CharCreateFrameWork::On_NC_AVATAR_CREATEFAIL_ACK, FUN_0040b480; the WM forwards err in 0x1404):
        #   0x181 "The name is already in use."; 0x182/0x183/0x184 → no message box at all (original bug) D02-B1

CreateCharacter(req):                                                               @ FUN_00404280
    class = shape.chrclass; gender = shape.gender
    race = g_ClassRace[class]   (DAT_004df5e0: class 0→0, 1–10→1, 11–15→2, 16–20→3, 21–25→1, 26–27→2)   # request race bits ignored
    hair = HairInfo[hairtype], color = HairColorInfo[haircolor], face = FaceInfo[faceshape]
    if any is missing or hair.Grade != 0 or color.Grade != 0 or face.Grade != 0: return -2   # only free (grade-0) styles
    if !DefaultCharacterData.CHARACTER[class]: return 0                              # FUN_0043eb50 (→ 0x181)
    charNo = p_Char_Create(userNo, createworld, adminlevel, slot, name, race, class, gender, hair, color, face, out nCharNo)
                                                                                     @ FUN_00458070
        # (db-backup, Character.bak, "2004.6 By CJC"): nCharNo = 0 error / name exists, -1 slot in use (bDeleted = 0),
        # -2 tCharacterShape insert failed, -3 tCharacterOptions insert failed; else the new tCharacter identity.
        # INSERT tCharacter (nUserNo, nSlotNo, sID, nCreateWorld, nAdminLevel), tCharacterShape, tCharacterOptions.
        # The name check returns inside BEGIN TRAN without ROLLBACK (db-backup) — see D02-B2.
    if charNo < 1: return charNo
    on any failure below: p_Char_Wipe(charNo); return 0                              @ FUN_00458390 (→ 0x181 "name in use")
    p_Char_CreateSetDefaultData(charNo, map, x, y, HP, SP, HPStones, SPStones, money, out nRet == 1)   @ FUN_004581e0
        # UPDATE tCharacter SET sLoginZone, nLoginZoneX/Y, nHP, nSP, nHPS, nSPS, nMoney (db-backup)
    p_Char_SetLevelExp(charNo, InitLV, InitEXP (u64 parsed from the string), out u8)   @ FUN_00402c80 → FUN_00459770
    slot = 0; equipped = 0
    for each ITEM row of this class:
        key = MakeItemKey(); attr = ItemAttr_Init(itemId) (FUN_00467940; fail → log, abort)
        place = { storage type 9 (inventory), slot }
        if !equipped and ItemInfo[itemId].Class == 5:
            if ItemInfo.Equip not in {10, 12}: abort                               # weapon slot must be one of the two hands
            place = { type 8 (equipped), slot = Equip }; equipped = 1
        if Item_Insert(charNo, key, place, attr) != 0: log; abort                   @ FUN_0046be10 (p_Item_Create + attribute rows, D03)
        if the item went to the inventory: slot++
    for each SKILL row: p_Skill_Set(charNo, skillId, …zeros, out) else abort       @ FUN_00452c70
    for each QUEST row: p_Quest_Set(charNo, questId, status 6, data[100] = 0, out) else abort   @ FUN_004530e0
    for each SHORTCUT row: usp_Character_setShortCut(charNo, nSlotNo, nCodeNo, nValue, out) else abort   @ FUN_0045d920
    usp_Tutorial_setCharInfo(userNo, charNo, nState = (class == 26 ? 2 : 0), nStep = 0, out nRet == 0) else abort   @ FUN_0045fb30
        # Sentinel (class 26) starts with the tutorial marked done; all others start "not done" (W01 §4.2 asks the client)
        # Fixes/Tutorial Skip (2018) inserts nState 2 for every new row: private-server change, not 2016 behaviour
    return charNo
```

`DefaultCharacterData.txt` (2016): classes 1/6/11/16/21 start in `RouN` (6888, 7045), level 1, money 0, item 46003
(mystery bolt); class 26 (Sentinel) starts in `Eld` (12259, 13434), level 60 with 24 346 145 exp, item 46012.

### 3.4 Delete

```pseudo
0x1408 NC_AVATAR_ERASEDATA_REQ { u16 clienthandle, u32 usrregnum, u32 avatar (charNo), u8 slot, u32 nNo (guild) }   @ FUN_00404cd0
    if !CheckAlive: return
    if !p_Char_GetListOfUserChar(userNo) or charNo not among the rows: err = 5 → fail
    if !p_Friend_Del_All(charNo, out nRet == 0): log "ERROR - CPFsCharacter::fc_NC_AVATAR_ERASEDATA_REQ, nCharNo = %d"; err = 200 → fail
    if nNo != 0 and !p_Guild_Member_Leave(nNo, charNo, out u8 nRet == 1):            @ FUN_00454a10
        log "…, nCharNo = %d, nGuildNo = %d"; err = 0xC9 → fail
        # DELETE FROM tGuildMember WHERE nNo AND nCharNo; nRet = @@ROWCOUNT (db-backup). No guild-master check anywhere
        # in this server: a master is removed from tGuildMember like any member (inferred; tGuild keeps the master number)
    usp_GuildAcademy_getGuildNo(charNo, out nRet):                                  @ FUN_004559d0
        fails with nRet != -1521 (0xFFFFFA0F, "not an academy member"): log "…GuildAcademyNo Get Fail…"; err = 0xC9 → fail
        ok: academyGuild = last row's i32; if academyGuild != 0:
            usp_GuildAcademy_delMember(academyGuild, charNo, out) else log "…GuildAcademyNo Del Fail…"; err = 0xC9 → fail
    err = p_Char_Delete(charNo, out nRet)                                           @ FUN_00458320 (nRet preset 4)
        # (db-backup) 0 ok; 1 already deleted; 2 not found; 3 cannot rename. Soft delete: sID becomes
        # "<name>~<year><month><day>#<try>" and bDeleted is set, so the name is free again.
    if err != 0: fail
    Send 0x140B NC_AVATAR_ERASEDATASUC_ACK = the 15-byte request echoed                # {handle, userNo, charNo, slot, nNo}
    if g_GameLogLink: send 0x0412 { u32 charNo }                                    # character-deleted log
    return
fail:
    Send 0x1409 NC_AVATAR_ERASEDATAFAIL_ACK { u16 handle, u16 err + 0xC0 }
        # 0xC5 not this account's character, 0x188 friend delete failed, 0x189 guild/academy step failed,
        # 0xC1/0xC2/0xC3/0xC4 from p_Char_Delete (4 = call failed)
        # client (FUN_00476860): 0xC7 → "You may not delete guild leader.", every other code → "Unable to delete a Guild
        # Master character." — this server never sends 0xC7 (original bug) D02-B3
```

Friends are deleted before the guild and delete steps, so a later failure leaves the character without friends
(original bug) D02-B4 (same row: no rollback across procedures).

### 3.5 Rename (char select) and guild data

```pseudo
0x1411 NC_AVATAR_RENAME_DB_REQ { u16 clienthandle, u32 nCharNo, u8 SlotNo, char NewName[20] }   @ FUN_00436030
    if !CheckAlive: return
    nRet = p_Char_Rename(nCharNo, NewName (NUL-terminated copy), out nRet, preset -1)   @ FUN_00458400
        # Character.bak: UPDATE tCharacter SET sID = @sID WHERE nCharNo; nRet = @@ERROR (a duplicate fails on the
        # unique name, inferred). Fixes/Free Name Change (2018) adds "only if a tCharacterChangeID row with bFlag = 0
        # exists": private-server change.
    SendRaw { u8 0x1F, u16 0x1412, u16 handle, u32 nCharNo, u8 SlotNo, char NewName[20], u16 Error }   # NC_AVATAR_RENAME_DB_ACK
        Error = 0xD0 when nRet == 0, else 0xD1                                      # client 0x1410: 0xD0 ok, 0xD1 "The name cannot be used."

0x1413 NC_AVATAR_GUILD_DATA_REQ { u16 clienthandle, u32 chrregnum, u8 slot }       @ FUN_004054f0
    nGuildNo = p_Guild_GetMyNo(chrregnum, out) ? out value : 0                      @ FUN_00454750
    Send 0x1414 NC_AVATAR_GUILD_DATA_ACK { u16 handle, u32 nGuildNo, u32 chrregnum, u8 slot }   # 11 bytes

0x1415 NC_AVATAR_GUILD_MEMBER_DATA_REQ { u16 clienthandle, u32 chrregnum, u32 nNo (guild), u8 slot }   @ FUN_00436150
    if !p_Guild_Member_GetAll(nNo):                                                 @ FUN_004548f0
        log "ERROR - CPFsCharacter::fc_NC_AVATAR_GUILD_MEMBER_DATA_REQ, GuildNo=%d"
        Send 0x1416 { header, Error = 0xC44, PartMask 0, NumOfMember 0 }; return
    header = { u16 handle, u32 chrregnum, u8 slot, u32 nNo, u16 Error = 0xC41, u8 PartMask = 1 (first), u16 NumOfMember }
    per row: i32 nCharNo, ts dJoinDate, u8 nGrade, i32 nFlags, u16 nExpRatio, str sIntro, str sName, u8 nClassID,
             u16 nLevel, str sMap, ts dLogonInfo → GUILD_MEMEBER_INFO (234 bytes: MemberClient 110 @ FUN_00405610 +
             MemberServer { nMemberCharNo, dJoinDate (mktime), … } 124)                         (pdb2017 field names)
        when 14 + n·234 > 0x7FD and n > 1: send this part, n = 0, PartMask = 0
    PartMask |= 2 (last); send the rest
    # Size passed to SetOpcode is 14 + n·234 while the payload has a 16-byte header (handle + PDB header 14), so the last
    # 2 bytes of every part are not sent (original bug) D02-B5
```

### 3.6 Item list helper (shared with D03)

```pseudo
ItemList(charNo, type, max, out n, out rows[40 bytes each]):                        @ FUN_00469f70
    if type > 16: return 0
    p_Item_GetListType(charNo, type)                                                @ FUN_004615e0
    per row while n < max: u64 nItemKey @+0, u16 nStorage slot @+8, u32 nItemID @+0xc, u32 lot/attr @+0x10,
                            ts @+0x14; row byte +0xa = type
```

## 4. Character load: 0x1004 NC_CHAR_CHARDATA_REQ (CParserCharacter, registered @ FUN_0043b040)

The WM asks for the whole character when the player selects it (W01 §4.2) or after the tutorial answer (W01 §6.2).
The Character server answers with one packet per data block, then `0x1005`. The WM stores every block in its client
session and later replays them to each zone (W01 §6.3). Every block packet starts with the WM `clienthandle` (u16) unless
noted; the PDB structs (named below) omit it.

```pseudo
0x1004 NC_CHAR_CHARDATA_REQ { u16 clienthandle, u32 chrregnum, u32 nUserNo, i32 tExchangedCoinSumDate }   @ FUN_00438dc0
    if !CheckAlive: return
    step by step (stop at the first failure, see "failures" below):
    1  0x1007 NC_CHAR_BASE_CMD (0x6B) ← GetCharBaseData(charNo)                  @ FUN_0046e2e0  p_Char_GetAllData   fail 0x582
    2  0x541C NC_FRIEND_DB_POINT_CMD { u16 numoffriend = 1, { u32 charregnum, u16 friendpoint, u16 diffpoint } }  (no handle)
          friendpoint = usp_Character_getFriendpoint(charNo) row u16 (0 on error, logged)  @ FUN_00460600
          diffpoint   = usp_Character_GetDiffFriendpoint(charNo) row u16 (0 on error, logged)  @ FUN_00460840
    3  0x101A NC_CHAR_KQMAP_CMD (0x1E) ← p_Char_GetKQMap(charNo): i32 nKQHandle, str sKQMapName, u32 x, u32 y,
          ts dKQDate (packed year:4, month:4, day:5, hour:5, min:6, sec:6)       @ FUN_0045a130                   fail 0x594
    4  0x1008 NC_CHAR_SHAPE (6: handle + 4 shape bytes) ← p_Char_GetShape(charNo)  @ FUN_0046c5d0              fail 0x583
    5  0x100A NC_CHAR_QUEST_DOING_CMD (8 + n·32) ← p_Quest_GetAllDoing (doing list) @ FUN_0046cb00            fail 0x587
    6  0x100B NC_CHAR_QUEST_DONE_CMD, parts ≤ 8000 bytes, 10-byte records          @ FUN_004288d0 (own 0x1006 0x587)
    7  0x10CC NC_CHAR_QUEST_READ_CMD (8 + n·2)                                     @ FUN_0046ce50              fail 0x587
    8  0x10D5 NC_CHAR_QUEST_REPEAT_CMD (8 + n·32)                                  @ FUN_0046ced0              fail 0x587
          # quest rows: p_Quest_GetAllDoing(charNo, nStatusDone) → (nQuestNo, nStatus, sData); filter values 2, 7, 8 and
          # one from a register (db-backup: WHERE nStatus <> @nStatusDone). Quest semantics: D04.
    9  skills ← p_Skill_GetAll(charNo)                                             @ FUN_0046c900              fail 0x586
          then every DefaultCharacterData SKILL row whose class == shape.chrclass (exact class) that the character
          lacks is inserted now with p_Skill_Set(charNo, id, 1, …0) (fail 0x586):  id < 30000 → active list (max 3000),
          id ≥ 30000 → passive list as id − 30000 (max 1000); over the limit → 0x586
          0x100D NC_CHAR_SKILL_CMD { u16 handle, u32 chrregnum, u8 PartMark (bit0 start, bit1 end, bits 2-7 order),
                 u16 nMaxNum (total), u16 number, PROTO_SKILLREADBLOCK[number] (16 bytes) }   one part per 500 skills
          0x100E NC_CHAR_SKILL_PASSIVE_CMD { u16 handle, u16 number, u16 passive[number] }
    10 0x100C NC_CHAR_ABSTATE_CMD (8 + n·36) ← p_Char_GetStateAllWithSetItemAndRestTime   @ FUN_0046c6e0   fail 0x585
    11 holy promise (master/apprentice) blocks, failures only logged ("FAILED - GetHolyPromiseUp/Member/RemainMoney"):
          raw 0x9427 NC_HOLY_PROMISE_DB_GET_UP_ACK (0x33)       ← p_HolyPromise_Get           @ FUN_004389b0
          0x9429 NC_HOLY_PROMISE_DB_GET_MEMBER_ACK (8 + n·42)  ← p_HolyPromise_GetMember     @ FUN_0041a570
          raw 0x9444 NC_HOLY_PROMISE_DB_GET_REMAIN_MONEY_CMD (0xF) ← usp_HolyPromise_getRemainMoney   @ FUN_0041b340
    12 0x1010 NC_CHAR_FRIEND_CMD (4 + n·25) ← p_Friend_GetNumOfFriend / p_Friend_GetAll   @ FUN_0046d010  (only if n > 0)
    13 0x1012 NC_CHAR_GUILD_CMD { u16 handle, u32 nGuildNo } ← p_Guild_GetMyNo (0 when the call fails)
    14 0x1097 NC_CHAR_GUILD_ACADEMY_CMD { u16 handle, u32 nGuildAcademyNo, u8 isGuildAcademyMember }
          nGuildAcademyNo = last row of usp_GuildAcademy_getGuildNo (0 on failure, logged
          "ERROR - CPFsCharacter::fc_NC_CHAR_CHARDATA_REQ, CharNo=%d"); the u8 is never written (original bug) D02-B7
    15 items: four ItemList reads, then 0x1017 NC_CHAR_ITEM_CMD packets   (Send_NC_CHAR_ITEM_CMD @ FUN_004056a0)
          storage 9 inventory (max 144, part mark 5), 8 equipped (max 30, 8), 12 (max 35, 0x10), 15 (max 42, 0x22)
          @ FUN_00402f80 / FUN_00403000 / FUN_00403480 / FUN_00403700 → ItemList (§3.6) + per item p_Item_GetOptionAll,
          p_Item_GetMobListAll, p_Item_GetTitle, usp_Item_Get_EnchantAll, usp_Pet_getInfo (item content: D03)
          the inventory list is split into parts < 0x1C13 bytes; byte 0 = PacketOrder (bit 7 = last part)
          a send that fails: raw 0x1006 { u16 handle, u16 0x591 } ("There is an error in the Item Information.")
    16 0x1019 NC_CHAR_CHARTITLE (0x409 + n·2) ← p_Char_GetTitleAll                @ FUN_0046d2c0               fail 0x593
    17 0x101B NC_CHAR_CHARGEDBUFF_CMD (4 + n·14) ← p_Char_GetChargedBufferAll      @ FUN_0046d680               fail 0x595
    18 0xA801 NC_CHAT_RESTRICT_DB_LIST_CMD (4 + n·26) ← usp_ChatBlock_getBlockList(nUserNo)  @ FUN_0046daf0  (only if n > 0)
    19 0x10D2 NC_CHAR_FREESTAT_SET_DB_ACK used as "single option" block (0x11) ← usp_Character_getSingleOption  @ FUN_0046dc00  fail 0x597
    20 options: usp_Character_chkKeyMap(charNo) (FUN_00422240) chooses the format     fail 0x59B
          1 → "improved" options: usp_Character_getShortCutList, usp_Character_getKeyMap, usp_Character_getGameOption
              → 0x702C NC_CHAR_OPTION_IMPROVE_DB_GET_DATA_TYPE_CMD packets   @ FUN_004354b0
          else → old options: p_Char_GetOptShortCutData / GetOptShortCutSize / GetOptGame / GetOptWindowsPos /
              GetOptKeyMapping → raw long-frame packets 0x7018, 0x701A, 0x7020, 0x7022, 0x7024
              (NC_CHAR_OPTION_DB_GET_*_ACK, pdb2017)                          @ FUN_00422020
    21 0x0844 NC_MISC_GET_CHAT_BLOCK_SPAM_FILTER_DB_CMD { u16 handle, u32 nUserNo, u32 nCharNo, u8 bIsSpamSpread,
          u8 bIsSpamBlock, u8 nSpamFilterRate } ← usp_SpamFilter_get(nUserNo) row (u32 ?, u8, u8, u8); zeros on error
    22 0x10CA NC_CHAR_GET_CHAT_BLOCK_SPAMER_DB_CMD { u16 handle, u32 CharNo, u32 BlockTime, u32 DelayTime }
          ← usp_SpamBlock_getTime(charNo) row (u32, u32, u32); zeros on error
    23 0x10CF item action cool times (4 + n·10) ← usp_Character_getItemActionCoolTime  @ FUN_0046dd40         fail 0x59A
    24 0x10D8 NC_CHAR_NEWBIE_GUIDE_VIEW_LIST_CMD { u16 handle, u8 n, u8 list[n] } ← usp_InGameGuide_getViewList   fail 0x59C
    25 0x10DC NC_CHAR_COININFO_CMD { u16 handle, u64 nCoin, u64 nExchangedCoin }                                 fail 0x59D
          nCoin ← usp_Gamble_getCoin(charNo); nExchangedCoin ← usp_Gamble_getExchangedCoin(charNo,
          TIMESTAMP(tExchangedCoinSumDate) via FUN_00414340)          # the WM passes "day start − 1 day" (W01 §4.2)
    26 0x10E2 NC_CHAR_CARDCOLLECT_CMD { u16 handle, u32 chrregnum, u16 n, n × { u32 serial, u16 card, u8 star,
          u32 time (mktime of the row's ts) } (11 bytes) } ← usp_Collection_getCardList     fail 0x59E
    27 0x10E5 NC_CHAR_CARDCOLLECT_BOOKMARK_CMD (8 + n·4: u16, u16) ← usp_Collection_getFavoritesList      fail 0x59F
    28 0x10E8 NC_CHAR_CARDCOLLECT_REWARD_CMD (8 + n·2: u16 RewardID) ← usp_Collection_getRewardList       fail 0x5A0
    29 0x1114 NC_CHAR_TUTORIAL_INFO_WORLD_CMD (9, no handle) { u32 nCharNo, i32 nTutorialState, u8 nTutorialStep }
          ← usp_Tutorial_getCharInfo                                   @ FUN_00429910                       fail 0x31EA
    30 0x111E NC_CHAR_CHAT_COLOR_CMD (6, no handle) { u32 nCharNo, u8 nChatFontColorID, u8 nChatBalloonColorID } ← usp_ChatColor_get  @ FUN_0042ce20   fail 0x5A2
    31 0x1121 NC_CHAR_USEITEM_MINIMON_INFO_CMD (0x38: u16 nWorldHandle, u32 nCharNo, u8 bNormalItem, u8 bChargedItem, u16[12] ×2) ← usp_Character_getAutoScroll, usp_Item_getAutoMonList  @ FUN_0042da90   fail 0x5A3
    32 SendRaw { u8 4, u16 0x1005, u16 handle }   NC_CHAR_CHARDATA_ACK: done (the WM now sends the zone address, W01 §4.2)

failures:
    Send 0x1006 NC_CHAR_CHARDATAFAIL_ACK, 6-byte payload. Codes 0x591 (raw), 0x5A2, 0x5A3, 0x31EA are written at +2;
    every other code (0x582…0x5A0) is written at +4 while +2 keeps whatever the previous step left in the buffer.
    The WM forwards the u16 at +2 to the client as 0x1002 NC_CHAR_LOGINFAIL_ACK (W01 FUN_00409e70), so those codes never
    reach the client (original bug) D02-B6.
    Client texts (CharSelectFrameWork FUN_004769d0): 0x582 Character, 0x583 Appearance, 0x584 Option, 0x585 Status,
    0x586 Skill, 0x587 Quest, …, 0x591 Item, 0x593 Title, 0x594 Kingdom Quest, 0x595 Premium Item ("There is an error in
    the <…> Information."); 0x597 and above (incl. 0x5A2, 0x5A3, 0x31EA) → "The Map is under maintenance."
    Blocks already sent stay in the WM cache. When a send fails, or the quest-done step fails after sending its own
    0x1006, the handler stops without 0x1005.
```

Blocks the WM cache table lists but the 2016 Character server **never sends**: 0x100F (house), 0x1011, 0x1013, 0x1014,
0x1015, 0x1016, 0x1018 (no `SetOpcode` with these values in the binary).

### 4.1 GetCharBaseData: `p_Char_GetAllData` → `PROTO_NC_CHAR_BASE_CMD` (0x1007 payload + 2)

```pseudo
GetCharBaseData(charNo, out base, out userNo?)                                     @ FUN_0046e2e0
    p_Char_GetAllData(charNo) and DB_Fetch                                        @ FUN_00458680
    base.chrregnum = charNo
    columns in order (SQLGetData type → field):
       1 nUserNo i32 → out param (optional)          2 nSlotNo u8 → slotno (+0x18)     3 sID str → charid[20] (+0x04)
       4 nLevel u8 → Level (+0x19)                   5 nExp i64 → Experience (+0x1A)
       6 nHP u16 → CurHP (+0x2A, u32)                 7 nSP u16 → CurSP (+0x2E, u32)    CurLP (+0x32) = 0
       8 nAP u32 → read, dropped                     9 nHPS u16 → CurHPStone (+0x26)   10 nSPS u16 → CurSPStone (+0x28)
      11 nPS u16 → CurPwrStone (+0x22)              12 nGS u16 → CurGrdStone (+0x24)  13 nMoney i64 → Cen (+0x3A)
      14 nFame u32 → fame (+0x36)                   15 nFlags u32 → flags (+0x65)     16 nAdminLevel u8 → adminlevel (+0x64)
      17 sLoginZone str → currentmap[12] (+0x42)    18 nLoginZoneX u32 (+0x4E)        19 nLoginZoneY u32 (+0x52)
      20 nLoginZoneD u8 → dir (+0x56)               21 nPrisonMin u16 → prisonmin (+0x62)   22 nPKCount u32 (+0x5E)
      23 nPKYellowTime u8 (+0x5D)                   24–29 nStrength, nConstitute, nDexterity, nIntelligence, nMentalPower,
                                                    nRedistributePoint u8 → statdistribute (+0x57…+0x5C)
      30 nPlayMin i32, 31 nLoginCount i32, 32 dLastLoginDate ts, 33 dCreateDate ts, 34 nCreateWorld u8, 35 bDeleted u8,
      36 dDeletedDate ts → read, dropped
      37 str (12) → if non-empty and the map exists in MapInfo: currentmap = it, x/y = MapInfo.RegenX/RegenY
    # Both backups' p_Char_GetAllData return 36 columns (db-backup); the 37th is absent there, its SQLGetData fails
    # silently and the override never happens (D02-B19, a backup mismatch). The 2016 procedure had one more string
    # column (inferred: a "return to" map, e.g. after an instance).
```

## 5. Login, logout, loading report

```pseudo
0x1036 NC_CHAR_LOGIN_DB { u32 chrregnum, char MapName[12], u32 x, u32 y, u64 Cen, u32 usrregnum, char spawnapps[20] }   (56 bytes, from the WM)   @ FUN_00405810
    if !CheckAlive: return
    p_Char_Login(charNo, out nRet == 0) else log "Error - fc_NC_CHAR_LOGIN_DB, CharNo=%d"        @ FUN_00458560
        # w00_Character (JK CHO 2014.8.22): nLoginCount += 1, dLastLoginDate = GETDATE(); result row
        # nLoginDateDiff = DATEDIFF(day, previous dLastLoginDate, now); nRet 1 update failed, -1111 no character.
        # Character.bak's older copy returns no row and also fills a private-server table LoggedInChars (third party).
    if g_GameLogLink: send 0x040A NC_LOG_GAME_LOGIN = the 56-byte request                     # login log
    if a row comes back and nLoginDateDiff > 0:                                               # first login on a new day
        friends = p_Friend_GetNumOfFriend / p_Friend_GetAll(charNo)                           @ FUN_0046d010
        for each friend f:
            pt = usp_Character_getFriendpoint(f) row (i32)                                     @ FUN_00460600
            usp_Character_setFriendpoint(f, pt + 1) else log "…usp_Character_setFriendpoint: CharNo %d"   @ FUN_00460710
                # {CALL …(?,?)} with three bound parameters; w00 has (@nCharNo, @nFriendPoint, @nRet = 0 output), so the
                # bound output is ignored and the wrapper's nRet stays 0 (inferred) (original bug) D02-B8
            entry { u32 f, u16 pt + 1, u16 0 }
        if any: Send 0x541C NC_FRIEND_DB_POINT_CMD { u16 n, entries[n] }  to the WM   # every friend +1 friend point per day
    # the map, coordinates and money in the request are not stored here (only logged)

0x1037 NC_CHAR_LOGOUT_DB { u32 chrregnum, char MapName[12], u32 x, u32 y, u16 playmin, u8 state, u64 Cen }  (35 bytes)   @ FUN_00405b30
    p_Char_Logout(charNo, playmin, out nRet == 1) else log "Error - fc_NC_CHAR_LOGOUT_DB, CharNo=%d, PlayMin=%d"   @ FUN_004585f0
        # UPDATE tCharacter SET nPlayMin = nPlayMin + @nPlayMin; nRet = @@ROWCOUNT (db-backup)
    if g_GameLogLink: send 0x040B NC_LOG_GAME_LOGOUT = the 35-byte request
    # position and money are saved by the zone's dept-16 messages (§6), not here

0x0841 NC_MISC_DB_CLIENT_LOADING_BUG_DETECT_CMD { u32 nCharNo, i32 nWorldTime, char sLoadingMapName[12], u16 nFailType,
        u16 nLoadingFailCnt, char sFromMapName[12], char sFromZoneIP[16], char sToZoneIP[16], u16 nToZonePort,
        u16 nErrorDataCnt, nErrorDataCnt × { u16, u32 } }                                            @ FUN_00420b80
    nSeqNo = usp_CharacterLoading(nCharNo, TIMESTAMP(localtime(nWorldTime)), sLoadingMapName, nFailType, nLoadingFailCnt,
                                  sFromMapName, sFromZoneIP, sToZoneIP, nToZonePort, out nRet, out nSeqNo)   @ FUN_0045c360
    if ok: for each error entry: usp_CharacterLoadingDetailInfo(nCharNo, nSeqNo, u16, u32, out)    @ FUN_0045c620
    # no reply. The binary calls usp_CharacterLoading with 11 parameters; both backups have the 2009 6-parameter version
    # ("char loading save, 2009.6 By Luunar": INSERT tCharacterLoading (nCharNo, nSeqNo, dWorldTime, sLoadingMapName,
    # nFailType, nLoadingFailCnt)), and usp_CharacterLoadingDetailInfo exists in neither (db-backup): the 2016 DB had a
    # newer pair that also stored the from-map / zone addresses and per-error details.
```

## 6. Character saves from the zone (dept 16 CHARSAVE)

The zone's `WholeSaver` (`docs/knowledge/Z01.md`) sends these. Requests carry the 6-byte `NETPACKETZONEHEADER`, and the
`_REQ`s additionally the PDB `handle { u16 bufferlocation, u32 chrregnum }` (12-byte header in all); each `_ACK` echoes those
12 bytes. Command packets (`_CMD`) have the 6-byte header only, except where noted. No packet here checks that `chrregnum`
belongs to the sending zone.

```pseudo
0x4001 NC_CHARSAVE_ALL_REQ { hdr12, level {u32 chrregnum, u8 level, u64 exp, u32 fame}, location {u32 chrregnum,
        char map[12], u32 x, u32 y, u32 kqhandle, char map_kq[12], u32 kq_x, u32 kq_y}, stat {u32 chrregnum, u32 PwrStone,
        u32 GrdStone, u32 HPStone, u32 SPStone, u32 HP, u32 SP, u8 statdistribute[6]} }                        @ FUN_004064c0
    ok = SaveLevelExp(level) & SaveLocation(location) & SaveStat(stat)       (all three run; failures logged)
    if ok: Send 0x4002 NC_CHARSAVE_ALL_ACK { hdr12 }
    else:  log "CPFsCharacter::fc_NC_CHARSAVE_ALL_REQ - FAILED CharNo=%d"      # no answer
SaveLevelExp(b):  p_Char_SaveLevelExpFrame(chrregnum, level, exp, fame)      @ FUN_00405d40 → FUN_00459de0
                  # UPDATE tCharacter SET nLevel, nExp, nFame (lenasoft 2006-04-07, db-backup); log "CharSaveLevelExp ERROR:…"
SaveLocation(b):  p_Char_SaveLocation(chrregnum, map, x, y, kqhandle, map_kq, kq_x, kq_y)   @ FUN_00405c40 → FUN_00459e90
                  # sLoginZone, nLoginZoneX/Y, nKQHandle, sKQMap, nKQX, nKQY, dKQDate = GetDate() (db-backup)
SaveStat(b):      p_Char_SaveStat(chrregnum, PwrStone, GrdStone, HPStone(u16), SPStone(u16), HP(u16), SP(u16))   @ FUN_00406290 → FUN_00459fb0
                  # nPS, nGS, nHPS, nSPS, nHP, nSP. statdistribute is NOT saved here (it is saved by 0x10D1, §7.2)

0x4003 NC_CHARSAVE_LOCATION_CMD { hdr6, location }:  SaveLocation          @ FUN_00406610   (no reply)
0x4004 NC_CHARSAVE_LEVEL_CMD    { hdr6, level }:     SaveLevelExp          @ FUN_00406640   (no reply)
0x400D NC_CHARSAVE_CHARSTAT_CMD { hdr6, stat }:      SaveStat              @ FUN_00406940   (no reply)

0x4005 NC_CHARSAVE_QUEST_DOING_REQ { hdr12, u8 bNeedClear, u8 n, PLAYER_QUEST_INFO[n] (32 bytes) }      @ FUN_00406670
    for each: p_Quest_Set(chrregnum, ID, Status, Data[29 bytes] as binary, out) else log "ERROR - CharSaveQuest, …"   @ FUN_00405de0
    Send 0x4006 { hdr12 } only when every row was saved (helper returns failures == 0); else no reply. bNeedClear is ignored
0x4007 NC_CHARSAVE_ABSTATE_REQ { hdr12, u16 n, ABSTATEREADBLOCK[n] (36 bytes) }                         @ FUN_00406850
    p_Char_DelStateAll(chrregnum) else log "ERROR - CharSaveState DEL STATE ALL, nCharNo=%d"; stop
    for each: p_Char_SetStateWithSetItemAndRestTime(chrregnum, abstateid, strength, pasttime, resttime, restcount,
              empower 4 × 4 bits, setitem[4] {index, value}, CasterInfo.nLevel, CasterInfo.nAttackPower, out)   @ FUN_00460ee0
              # call string built at run time ("{CALL " + name + "(?,…)}" @ FUN_00460bf0); failures logged
    Send 0x4008 { hdr12 } when the helper reports success (DelStateAll failure or any row failure → no reply, inferred
    from the helper's result flag)
0x4009 NC_CHARSAVE_SKILL_REQ { hdr12, u16 n, PROTO_SKILLREADBLOCK[n] (16 bytes) }                       @ FUN_00406760
    for each: p_Skill_Set(chrregnum, skillid, 0, mastery, savetime (i64), cooltime, empow ×4, out) else log   @ FUN_00405f00
    Send 0x400A { hdr12 } when the helper reports success (inferred, same pattern)
0x400B NC_CHARSAVE_TITLE_REQ { hdr12, u16 NumOfValues, NumOfValues × { u8 type, u32, u32 } (9 bytes) }  @ FUN_00406970 → FUN_00406370
    if NumOfValues > 128: log "ERROR - CharSaveTitle: NumOfValues"; return
    for each with 0 < type < 0x80: p_Char_SetTitle(chrregnum, type, …) via FUN_0046d560 else log      # no reply
0x4018 NC_CHARSAVE_PKCOUNT_CMD { hdr6, u32 chrregnum, u32 pkcount }: p_Char_SavePKCount     @ FUN_004069a0
0x401A NC_CHARSAVE_REST_EXP_LAST_EXEC_TIME_SAVE_REQ { u16 bufferlocation, u32 chrregnum } (no zone header):
        usp_Character_setRestExpExecTime(chrregnum, out)        @ FUN_00406a40   # no reply (no 0x401B)
0x401C NC_CHARSAVE_AUTO_PICK_SAVE_REQ { u16 bEnable, u32 chrregnum } (zone sp_SetAutoPick, 6 bytes, no header):
        usp_Character_setAutoPick(chrregnum, (i8)bEnable, out)  @ FUN_00406ae0   # no reply
0x4022 NC_CHARSAVE_SET_CHAT_BLOCK_SPAMER_DB_CMD { u32 CharNo, u32 BlockTime, u32 DelayTime } (no header):   @ FUN_00423420
        usp_SpamBlock_setTime(CharNo, BlockTime, DelayTime, out nRet); nRet -2893 "DB_ERROR[UPDATE]", -2892 "DB_ERROR[INSERT]" (logged)
0x4023 NC_CHARSAVE_ITEMACTIONCOOLTIME_REQ { hdr6, u16 num, num × { u16 group, u32 endTime (time_t), 4 bytes } (10 bytes) }   @ FUN_00424140
        for each: usp_Character_setItemActionCoolTime(chrregnum, group, TIMESTAMP(localtime(endTime)), out) else log   # no reply
0x4027 NC_CHARSAVE_DB_UI_STATE_SAVE_REQ { hdr6, u8 btMysteryType }:                                       @ FUN_00424300
        usp_Character_setMysteryBolt(chrregnum, btMysteryType, out) (FUN_0046dd20)
        Send 0x4028 NC_CHARSAVE_DB_UI_STATE_SAVE_ACK { hdr6, u16 err = 0x2158 ok / 0x2159 failed }
0x4031 NC_CHARSAVE_CHAT_COLOR_CMD { u32 nCharNo, u8 font, u8 balloon }:  CheckAlive only — nothing saved   @ FUN_0042cf90
        # the colour is stored by the item-use path 0x34B5 (usp_ChatColor_setFont / setBalloon, D03)
0x4035 NC_CHARSAVE_USEITEM_MINIMON_INFO_DB_CMD { u32 nCharNo, u8 bNormalItem, u8 bChargedItem, u16 NormalItemList[12],
        u16 ChargedItemList[12], u8 DelSlotList_Normal[12], u8 DelSlotList_Charged[12] } (0x4E, no header)   @ FUN_0042de30
        usp_Character_setBuffScroll(nCharNo, bNormalItem, out) else log "…set buffscroll fail…"; stop
        usp_Character_setChargedbuffScroll(nCharNo, bChargedItem, out) else log; stop
        for slot 0..11 where NormalItemList[slot] != 0xFFFF or DelSlotList_Normal[slot]:
            usp_Item_setAutoMon(nCharNo, 2, slot, NormalItemList[slot], out) else log "…set buffitem fail…"; stop
        same for the charged list with type 1                                   # no reply
```

## 7. Class, stats, fame, name check

### 7.1 Class change, legacy stat points, fame, registration check

```pseudo
0x1056 NC_CHAR_CLASSCHANGE_REQ { hdr6, u8 newclass, u8 level }                                    @ FUN_00412d60
    ok = p_Char_ChangeClass(chrregnum, newclass)                                                 @ FUN_00459d60
    SendRaw { u8 9, u16 0x1057 NC_CHAR_CLASSCHANGE_ACK, hdr6, u8 newclass (0 when the update failed) }
    if ok and g_GameLogLink: send 0x0420 NC_LOG_GAME_CHANGE_CLASS { u32 chrregnum, MapName[12] = "UNUSE",
        u32 x, u32 y (not written: stale buffer bytes), u8 level, u8 classno }      (original bug) D02-B9
    on failure: log "fc_NC_CHAR_CLASSCHANGE_REQ ERROR:CharNo=%d, Class=%d"

0x105D NC_CHAR_STAT_INCPOINT_DB_REQ { hdr6, u8 stat }                                           @ FUN_004131a0
    if p_Char_StatPoint_Inc(chrregnum, stat, out): SendRaw { u8 9, 0x105E NC_CHAR_STAT_INCPOINTSUC_DB_ACK, hdr6, u8 stat }
    else: SendRaw { u8 10, 0x1060 NC_CHAR_STAT_INCPOINTFAIL_DB_ACK, hdr6, u16 0xAC4 }; log
0x1063 NC_CHAR_STAT_DECPOINT_DB_REQ { hdr6, u8 stat, u16 lockindex, u64 restatitemkey, u16 restatitemid, u8 isdelete, attr }   @ FUN_004132d0
    if isdelete == 0:
        if !ItemLotAfterUse(restatitemid, attr, &newLot, &newKey) (FUN_004038c0): err = 0x1099
        else ok = usp_ChargeItem_UseStatPointDecLotChange(chrregnum, stat, key, newLot, newKey, out r)   @ FUN_00463e10
             err = r 1 → 0x1096, 2 → 0x1097, 3 → 0x1098, else 0x109A
    else: ok = usp_ChargeItem_UseStatPointDecDel(chrregnum, stat, key, out r): r 1 → 0x1093, 2 → 0x1094, 3 → 0x1095, else 0x109A
    ok:   Send 0x1064 NC_CHAR_STAT_DECPOINTSUC_DB_ACK { hdr6, u8 stat, u16 lockindex }
          GameLog 0x0459 NC_LOG_GAME_ITEM_USELOT { chrregnum, itemkey, itemid, newLot } (isdelete 0) or
                  0x045A NC_LOG_GAME_ITEM_USEALL { chrregnum, itemkey, itemid }
    fail: Send 0x1066 NC_CHAR_STAT_DECPOINTFAIL_DB_ACK { hdr6, u16 lockindex, u16 err }
    # 0x105D and 0x1063 are legacy: the 2016 zone sends only 0x10D1 (Z07 §2.2/§2.5)

0x1070 NC_CHAR_FAMESAVE_CMD { u32 charregnum, u32 fame } (no header): p_Char_FameSet(charNo, fame, out u8)   @ FUN_00414130  (no reply, result ignored)

0x10B3 NC_CHAR_REGNUM_VARIFICATION_REQ { u16 zonehandle, char zone_charid[20], u32 charregnum }        @ FUN_00414170
    usp_Char_chkCharNo(charregnum, zone_charid, out nRet) (FUN_0045a5d0); failure logged
    Send 0x10B4 NC_CHAR_REGNUM_VARIFICATION_ACK { u16 zonehandle, u32 charregnum, u8 iscorrect = (nRet == 0) }
```

### 7.2 Free-stat save: 0x10D1 NC_CHAR_FREESTAT_SET_DB_REQ (answers Z07 §2)

The zone sends the whole target stat array for both raising and lowering (Z07 §2.2–§2.4) and locks its free-stat state
until `0x10D2` arrives.

```pseudo
0x10D1 { u16 clienthandle, u32 chrregnum, u8 nMaxStat, u8 nFreeStat[5], u16 nLockIndex, u8 nItemNum,
         nItemNum × DecItemInfo { u8 isDelete, u64 itemKey, u16 itemId, u8 count } (12 bytes) }          @ FUN_004135e0
    itemId = DecItemInfo[0].itemId (read even when nItemNum = 0: a stale receive-buffer word, harmless then)
    for each DecItemInfo: if .itemId != itemId: log "…ItemID Not Matching…"; return                    # no reply
    deleteCount = Σ count;  err = 0xAC1
    if nItemNum: optionType = ItemLotOption(itemId) (FUN_00403aa0); missing → err = 0xAC6 (logged, continues)
    ok = usp_Character_setStatPoint(chrregnum, nMaxStat, nFreeStat[0..4], itemId, optionType, deleteCount, out nRet)   @ FUN_00459af0
    if !ok or nRet != 0: err = 0xAC4; log "…DB_ERROR nCharacterNo %d"
    switch nRet:
        -1024 → err 0xAC6;  -1023 → 0x1094;  -1022 → 0x1096;  -1021 → 0x1097;  -1013 → 0xAC2
        -1011, -1012, -1014, -1091…-1094 → log and return WITHOUT a reply                                (original bug) D02-B10
        anything else → err as set above
    Send 0x10D2 NC_CHAR_FREESTAT_SET_DB_ACK { u16 clienthandle, u32 chrregnum, u8 nFreeStat[5], u16 nLockIndex, u16 nErrorType = err }
    if the send failed: log "…ZoneServer Send Fail…"; return
    for each DecItemInfo:                                                      # logged whatever err is (original bug) D02-B11
        isDelete == 0 → GameLog 0x0459 NC_LOG_GAME_ITEM_USELOT { chrregnum, itemKey, itemId, u16 count }
        else          → GameLog 0x045A NC_LOG_GAME_ITEM_USEALL { chrregnum, itemKey, itemId }
        (no GameLog link → log "…GameLog Send Fail…")
```

`usp_Character_setStatPoint` (w00_Character, "Ko Dong Gyun 2010.10.21", source cut at 8 KB) *(db-backup)*:
- `nRet` -1011 charNo ≤ 0, -1012 a negative stat, -1013 Σ stats > `@nMaxStatPoint`, -1021 `@nDeleteCount` ≠ the sum of
  the decreases against the stored `tCharacter.nStrength…nMentalPower`, -1093 the stat UPDATE failed, -1022 lowering an
  item's lot failed (`p_Item_SetOption`), further codes in the cut part.
- The restat items are consumed **inside the procedure**, not by the keys the zone sent: for one item it takes the first
  `tItem` of `@nItemID` in inventory (`nStorageType = 9`) by `nStorage` order and either lowers its `tItemOptions.nOptionData`
  of `@nOptionType` by one or deletes it (`p_Item_Delete`); for several it walks the same order with a cursor. The
  `itemKey`s in `DecItemInfo` only reach the GameLog. When the zone locked a different cell than the one the DB consumes
  (two stacks of the restat item), the zone's view and the DB disagree until the next load *(inferred)*.
- So `nErrorType` 0xAC1 = saved; 0xAC2 = more points than `nMaxStat`; 0x1097 = decrease count ≠ items; 0x1094 / 0x1096 /
  0xAC6 = item step failed; 0xAC4 = other DB error. The zone shows none of them as text (Z07 §2.4).

```pseudo
0x111A NC_CHAR_TUTORIAL_FREESTAT_INIT_REQ { u32 nCharNo, u8 nMaxStat, u8 nFreeStat[5] }               @ FUN_00429c90
    for stat i in 0..4: repeat nFreeStat[i] times: p_Char_StatPoint_Dec(nCharNo, i, out)               @ FUN_00459a60
        failure: log "…FreeStat init fail…"; err = 0x31ED; stop (decrements already done stay)
    Send 0x111B NC_CHAR_TUTORIAL_FREESTAT_INIT_ACK { u32 nCharNo, u16 nError = 0x31EC ok / 0x31ED }
```

## 8. Tutorial

```pseudo
0x1112 NC_CHAR_TUTORIAL_MAKE_ITEM_REQ { u16 nSessionHandle, u8 nCreateWorldNo, u32 nCharNo, u32 nUserNo, u8 bIsSkip }  (from the WM)   @ FUN_00429160
    reply = 0x1113 NC_CHAR_TUTORIAL_MAKE_ITEM_ACK { u16 nSessionHandle, u32 nCharNo, u16 rErrorType, u8 bIsSkip }
    class = p_Char_GetShape(nCharNo).chrclass else rErrorType = 0x31E9 ("CharacterShape Get Fail")
    if bIsSkip == 0:                                   # the player takes the tutorial
        row = TutorialCharacterData.TUTORIAL_CHARACTER[class] else 0x31E9
        p_Char_CreateSetDefaultData(nCharNo, map, x, y, HP, SP, HPStones, SPStones, money) else 0x31E9
        rErrorType = 0x31E8                            # 2016 data: RouN (7178, 7011), money 300 = where the tutorial ends
    else:                                              # skip: give the tutorial's weapon now
        slot = 0; equipped = 0
        for each DEFAULT_ITEM row of the class (2016: one weapon per class: 250, 750, 1250, 1750, 57363):
            build the item as in create (§3.3; class-5 item → equip slot 10/12 else "Incorrect EquipInfo" 0x31E9)
            if the equipped list already has an item in that cell: log "Duplicate Inven Cell … (Skipped)"; continue
            Item_Insert … else 0x31E9
        usp_Tutorial_setCharInfo(nUserNo, nCharNo, nState 2, nStep 0) else 0x31E9 ("TutorialState Set Fail")
        rErrorType = 0x31E8
    Send reply                                         # the WM then logs in (W01 §6.2)

0x1118 NC_CHAR_TUTORIAL_STEP_SAVE_REQ { u32 nCharNo, u32 nUserNo, i32 nTutorialState, u8 nTutorialStep }   @ FUN_00429ab0
    if usp_Tutorial_setCharInfo(nUserNo, nCharNo, (u8)nTutorialState, nTutorialStep, out nRet == 0):
        Send 0x1119 NC_CHAR_TUTORIAL_STEP_SAVE_ACK { u32 nCharNo, i32 nTutorialState, u8 nTutorialStep }
    else: log "ERROR - TutorialInfo Set Fail - …"                       # no reply
```

## 9. Misc (chat bans, spam filter, guide, item shop URL, ping test)

```pseudo
0x0847 NC_MISC_SET_CHAT_BLOCK_SPAM_FILTER_DB_CMD { u32 nUserNo, u32 nCharNo, u8 bIsSpamSpread, u8 bIsSpamBlock, u8 nSpamFilterRate }   @ FUN_00423320
    usp_SpamFilter_set(nUserNo, spread, block, rate, out nRet); -2893 / -2892 logged as UPDATE / INSERT errors   # no reply

0x0863 NC_MISC_SPAMMER_SET_DB_CHAT_BAN_REQ { u32 nGMCharNo, char sSpammerName[20], u32 nChatBan }       @ FUN_00424450
    ok = usp_Character_setChatBan(sSpammerName, nChatBan, out nRet)                                     @ FUN_0045e920
    nError = ok ? 0x2168 : 0x2169;  if nRet == -3121: nError = 0x216A   # client: 0x216A "Can't find the character"
    Send 0x0864 NC_MISC_SPAMMER_SET_DB_CHAT_BAN_ACK { request 28 bytes, u16 nError }
0x0868 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_DB_REQ (same layout)                                          @ FUN_004245f0
    ok = usp_Character_setChatBan(sSpammerName, nChatBan, out nRet)
    if !ok: log; return                                                   # no reply at all (original bug) D02-B12
    nError = 0x2170, or 0x2172 when nRet == -3121 ("Can't find the character")
    Send 0x0869 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_DB_ACK { request 28 bytes, u16 nError }

0x10DB NC_CHAR_DB_NEWBIE_GUIDE_VIEW_SET_CMD { u32 nCharNo, u8 nGuideView }                              @ FUN_004247a0
    usp_InGameGuide_setGuideNo(nCharNo, nGuideView, out nRet); failure or nRet ∉ {0, -1111} logged    # no reply

0x0870 NC_MISC_ITEMSHOP_URL_DB_REQ { u32 nCharNo, u32 nUserNo }                    @ FUN_00428bb0 → cUKItemShop::Recv… FUN_0043f7f0
    if the SOAP client pool is not initialised: log "…Not Init Soap"; return             # no reply
    if no pooled client is free (semaphore, no wait): Send 0x0871 { u32 nCharNo, u16 0x3042, u16 0 }
    else: getItemShopUrl(userNo as decimal string) on the gamigo "gameserverconnector" SOAP service
          (URL string at 0x004bb5a0, set up by FUN_0043f690)
          ok:   Send 0x0871 NC_MISC_ITEMSHOP_URL_DB_ACK { u32 nCharNo, u16 nError 0x3040, u16 nLen, char sURL[nLen] }
          fail: Send 0x0871 { nCharNo, 0x3043, 0 }; log "…soap fail ErrCode : %d\n%s"

0x0812 / 0x0813 / 0x0814 / 0x0815 NC_MISC_PINGTEST_* (round-trip timing)               @ FUN_004167e0 / FUN_004168a0 / FUN_00416960 / FUN_00416a20
    write timeGetTime() twice, into the u32s at payload +0x26/+0x2A, +0x4E/+0x52, +0x1E/+0x22, +0x32/+0x36 respectively,
    and echo the packet with the same opcode (0x5A / 0x82 / 0x26 / 0x3A bytes). The 2017 PDB structs are larger
    (0x7C / 0xA4 / 0x26 / 0x3A) and put DBRecvFrom…/DBSendTo… 8 bytes earlier for 0x0812/0x0813, so the 2016 field
    names are not confirmed; no ODBC round trip is made (inferred: the pair is DBSendToODBC / DBRecvFromODBC)
```

## 10. Item lists by storage type, beauty shop

```pseudo
0x1076 NC_CHAR_GET_ITEMLIST_BY_TYPE_REQ { hdr6, u8 nInvenType, u32 nOwner }                            @ FUN_00417460
    loader by nInvenType: 0 FUN_00403400, 1 FUN_00403380, 2 FUN_00403300, 3 FUN_00403500, 4 FUN_00403280,
        5 FUN_00403200, 6 FUN_00403100, 7 FUN_00403080, 8 equipped (FUN_00403000), 9 inventory (FUN_00402f80),
        11 and 15 FUN_00403700, 12 FUN_00403480, 13 FUN_00403580, 14 FUN_00403600, 16 FUN_00403680; 10 and > 16 → error
        (each = ItemList(nOwner, storage type, max) + item details, D03)
    reply 0x1077 NC_CHAR_GET_ITEMLIST_BY_TYPE_ACK { hdr6, u8 nInvenType, u32 nOwner, u16 Error, u8 PacketOrder,
          u8 nPartMark, u8 numofitem, items… }
        only nPartMark (+0xE) and numofitem (+0xF) are written: Error and PacketOrder (+0xB…+0xD) keep stale bytes
        (original bug) D02-B13. nPartMark bit 0 = first part, bit 1 = last part; a part is sent when the next item would
        pass 0x1FFC bytes. Error / unknown type / loader failure → one part with nPartMark 3 and no items, the same
        bytes as an empty list.
0x1099 NC_CHAR_GET_ITEMLIST_BY_TYPE_NUM_REQ { hdr6, u8 nInvenType, u32 nOwner, u8 slotORnumber, u16 from, u16 to }   @ FUN_00417860
    only nInvenType 2 is served (FUN_00403780: slots from..to); anything else → empty part, nPartMark 3
    reply 0x109A (same layout as 0x1077, same stale fields)
```

Beauty shop (WM `CHairShopFrameWork`, W01 §4.3). Coupons are ItemInfo `HairShop01`…`HairShop05` (grades 1–5) and
`UniChange01` (gender change), resolved at start-up (`g_HairShopItem[6]` = DAT_006ec8b0…, the sixth slot is
`HairShop05` again; `g_GenderChangeItem` = DAT_006ec8bc).

```pseudo
CouponTable(charNo, out t[6]):                                                          @ FUN_004180b0
    t[i] = { u16 id = HairShop01 + i (t[5].id = UniChange01), u64 key = -1, u16 maxLot = 0, u16 totalLot = 0 }
    for each inventory item (storage 9, ItemList): lot = item lot (FUN_004681a0)
        HairShop01 ≤ id ≤ HairShop05: e = t[id − HairShop01]   # assumes consecutive item ids (inferred)
        id == UniChange01: e = t[5]
        e.totalLot += lot; if lot > e.maxLot: e.maxLot = lot, e.key = item key

0x107E NC_CHAR_SET_STYLE_GET_INFO_DB_REQ { u16 WMHandle, u32 nCharNo }                                @ FUN_00418840
    Send 0x107F NC_CHAR_SET_STYLE_GET_INFO_DB_ACK { u16 WMHandle, u32 nCharNo, u16 Error (0x1280 ok / 0x1282),
          STYLE_ITEM_COUNTS Items[6] { u16 itemId, u16 totalLot } }

0x107A NC_CHAR_SET_STYLE_DB_REQ { u16 WMHandle, u32 nCharNo, u8 shape (race:2, chrclass:5, gender:1), u8 hairtype,
        u8 haircolor, u8 faceshape }                                                               @ FUN_004182b0
    cur = p_Char_GetShape(nCharNo) else Error 0x1282
    grade = max(Grade of each part that differs from cur: HairColorInfo / HairInfo / FaceInfo)
    genderChange = (shape.gender != cur.gender)
    if nothing differs and !genderChange: Error 0x1280 (no DB write, no coupon)
    coupon = grade ? HairShop0<grade> : HairShop01                    # a free (grade 0) style still costs a HairShop01
    if genderChange: if grade != 0: Error 0x1286 (gender and paid style together); coupon = UniChange01
    t = CouponTable(nCharNo) else Error 0x1285
    use the first coupon type from `coupon` up to HairShop05 that the character has (a higher grade pays for a lower one);
        gender change: t[5]; none → Error 0x1283 ("You need a Beauty Shop … item")
    p_Char_SetShape(nCharNo, shape, hair, colour, face) else Error 0x1281                       @ FUN_0046c680
    coupon stack maxLot == 1: p_Item_Delete(key) (FUN_00468130), GameLog 0x045A NC_LOG_GAME_ITEM_USEALL
    else: p_Item_SetOption(key, lot option, maxLot − 1) (FUN_0046a730), GameLog 0x0459 NC_LOG_GAME_ITEM_USELOT
        failure of either: restore the old shape (p_Char_SetShape(cur)); Error 0x1281
    Send 0x107B NC_CHAR_SET_STYLE_DB_ACK { u16 Error, u16 WMHandle, u32 nCharNo, u8 shape[4] (as requested) }
    # client (W01 → 0x1079): 0x1280 "Decoration you chose has properly been applied.", 0x1281/0x1282 DB error,
    # 0x1283 "You need a Beauty Shop … item", 0x1286 gender-change notice; 0x1285 has no text of its own
    # The race / class bits of `shape` are written as sent: the WM forwards a u32 from the client (W01 §4.3), so a
    # client can change its class or race through the beauty shop (original bug) D02-B14 (inferred: the WM does not
    # mask the value; not checked in the client)
```

## 11. Wedding (tMarriage) — answers the Z07 §5 questions

Table `tMarriage` (db-backup): `nCharNo, nPartnerCharNo, nStatus, nSubStatus, dWhen, dSubWhen, nMarriageCount,
nDivorceCancel`. Both partners have a row; every couple procedure updates both rows and fails (`@nRet = 1`, rollback) if
either row does not point at the other. The wrappers report success as `rc ok and nRet == 0`.

```pseudo
0x1080 NC_CHAR_WEDDINGDATA_REQ { hdr6 }                                                             @ FUN_00418a40
    if !p_Char_WeddingStatus_Get(chrregnum) (FUN_0046d7d0): Error 0x12E0
        # rows: u32 nPartnerCharNo, u8 nStatus, u8 nSubStatus, ts dWhen, ts dSubWhen, u8 nMarriageCount, u8 nDivorceCancel
        # Character.bak v1 inserts a row (partner 0) when none exists; v2 and w00 only SELECT (db-backup)
    else:
        Error 0; Status = nStatus | nSubStatus << 4; When = dWhen, SubWhen = dSubWhen (ShineDateTime, year − 2000)
        Partner.RegisterNumber = nPartnerCharNo; Partner.Name = p_Char_GetCharID(nPartnerCharNo, out sID, out nRet)
        WeddingCount = nMarriageCount; RefusalCount = nDivorceCancel
        if the name lookup did not find exactly one row (nRet != 1): Error 0x12E2      # always for a single (partner 0)
    Send 0x1081 NC_CHAR_WEDDINGDATA_ACK { hdr6, u16 Error, u8 Status, u32 When, u32 SubWhen, Partner { char Name[20],
          u32 RegisterNumber }, u8 WeddingCount, u8 RefusalCount }   (43 bytes; on 0x12E0 the body is stale)

0x1082 NC_CHAR_WEDDINGDATA_CMD (same 43-byte layout, from the zone)                               @ FUN_00418c80
    p_Char_WeddingStatus_Set(chrregnum, Partner.RegisterNumber, Status & 0xF, Status >> 4, When, SubWhen,
                             WeddingCount, RefusalCount)  (dates unpacked, year + 2000); failure logged; no reply
    # upsert of the whole row: the zone's periodic status maintenance (Z07 §5.1) writes through here
```

**How the partner gets chosen (Z07 open question).** The Character server never chooses one. `0x1083` carries the
partner's character number, taken by the zone from the proposal (Z02 §10: `{ p.handle, p.charNo, q.charNo }`), and
`p_Char_Wedding_Propose` writes it into both rows. Before that, `nPartnerCharNo` is 0 for a character that never had a
partner, or the **previous partner**: cancelling a proposal, escaping a divorce and divorcing set only the status fields
and never clear `nPartnerCharNo` (db-backup). `Partner.RegisterNumber` in `0x1081` therefore stays the old partner until
the next proposal or a `0x1082` that writes another value.

```pseudo
0x1083 NC_CHAR_WEDDING_PROPOSE_REQ { hdr6, u32 Partner }                                           @ FUN_00418e40
    ok = p_Char_Wedding_Propose(chrregnum, Partner, out nRet)     # both rows: partner = other, nStatus 1, nSubStatus 0,
                                                                  # dWhen = now, dSubWhen = now + 3 days (upsert)
    if ok: GameLog 0x0658 { u32 chrregnum, u32 Partner }
    Send 0x1084 NC_CHAR_WEDDING_PROPOSE_ACK { hdr6, i32 Success = ok, u32 Partner }
0x1085 NC_CHAR_WEDDING_PROPOSE_CANCEL_REQ { hdr6, u32 Partner }                                    @ FUN_00418fc0
    p_Char_Wedding_Cancel_Propose: both rows nStatus 0, nSubStatus 0 (partner kept); GameLog 0x0659; reply 0x1086 (same layout)
0x1087 NC_CHAR_WEDDING_ESCAPE_DIVORCE_REQ { hdr6, … }                                              @ FUN_00419140
    p_Char_Wedding_Escape_Divorce_State(chrregnum): own row only: nStatus 0, nSubStatus 0, nDivorceCancel 0;
        nRet 1 only when the row is missing
    reply 0x1088 { hdr6, i32 Success, u32 Partner (not written: stale) }   (original bug) D02-B17
0x1089 NC_CHAR_WEDDING_DIVORCE_BY_AGREE_REQ { hdr6, u32 Partner }                                  @ FUN_00419250
    p_Char_Wedding_Divorce_by_Agree: applicant nSubStatus 1, partner nSubStatus 6 (= 2 + 4), both dSubWhen = now + 10 min
        (w00; Character.bak versions use 3, 5, 10 or 20 minutes)
    if ok: GameLog 0x065A { u32 chrregnum, u32 Partner, u8 1 }
    reply 0x108A { hdr6, i32 Success, u32 Partner }
0x108B NC_CHAR_WEDDING_DIVORCE_BY_FORCE_REQ: same with p_Char_Wedding_Divorce_by_Force (applicant 3, partner 4),
    GameLog 0x065A type 2, reply 0x108C                                                             @ FUN_004193d0
0x108D NC_CHAR_WEDDING_DIVORCE_DO_REQ { hdr6, u32 Partner, u8 Reason }                             @ FUN_00419550
    Reason == 2 ? p_Char_Wedding_Divorce_Do_by_Item : p_Char_Wedding_Divorce_Do                    @ FUN_0046d970
        # Do: both rows nStatus 3, nSubStatus 1, dSubWhen = now + 7 days; by_Item: nStatus 3, sub 1 / 2, + 5 seconds
    if ok: GameLog 0x065B { chrregnum, Partner } and 0x065B { Partner, chrregnum }
    reply 0x108E { hdr6, i32 Success, u32 Partner }
0x108F NC_CHAR_WEDDING_DIVORCE_CANCEL_REQ { hdr6, u32 Partner, u8 IncreseCount }                   @ FUN_00419730
    p_Char_Wedding_Divorce_Cancel(chrregnum, Partner, IncreseCount, out SubStatusA, out SubStatusB, out nRet):
        own row: nSubStatus 1 → 5, 3 → 7 (+4 marker), nDivorceCancel += IncreseCount, dSubWhen = dWhen;
        partner row: nSubStatus 0
    if ok: GameLog 0x065C both directions
    reply 0x1090 NC_CHAR_WEDDING_DIVORCE_CANCEL_ACK { hdr6, i32 Success, u8 MySubStatus, u32 Partner, u8 PartnerSubStatus }
        (the two sub-status bytes come from the wrapper's output parameters (not traced))
0x1091 NC_CHAR_WEDDING_DO_REQ { hdr6, u32 Partner }                                                @ FUN_00419920
    p_Char_Wedding_Do: both rows nStatus 2, nSubStatus 0, dSubWhen = now + 7 days (newly-wed period, inferred)
    if ok: GameLog 0x0660 both directions;  reply 0x1092 { hdr6, i32 Success, u32 Partner }
0x1093 NC_CHAR_WEDDING_PARTNER_INFO_REQ { hdr6, u32 Partner }                                      @ FUN_00419af0
    p_Char_Wedding_Get_Partner_Info(Partner): SELECT nLevel, dLastLoginDate FROM tCharacter (db-backup)
    reply 0x1094 NC_CHAR_WEDDING_PARTNER_INFO_ACK { hdr6, u8 Level, u8 Connected, u32 LastConnect, u16 CurrentMap }
        only Level and LastConnect are written; Connected and CurrentMap keep stale bytes (original bug) D02-B15
```

**When do the divorce requests answer Success 0 (Z07-B11)?** `0x1089`, `0x108B` and `0x108D` fail only when the
procedure finds no `tMarriage` row of the requester pointing at `Partner`, or no row of the partner pointing back, or an
UPDATE fails (deadlock, lock timeout). None of them checks `nStatus` (married) or the sub-status, and the zone sends the
partner number it got from `0x1081`, so in normal play they succeed. Success 0 happens when the partner's row points
at someone else (the partner escaped a divorce and proposed to another character: `Escape_Divorce` resets only the
escaper's row) or on a DB error. In those cases the zone has already taken the 250 000 / 750 000 fee (Z07-B11).

Sub-status values the DB writes: 1 applicant (by agreement), 6 = 2 + 4 partner (by agreement), 3 / 4 forced applicant /
partner, +4 added by `Divorce_Cancel` to 1 and 3. Bit 2 (value 4) is a marker the zone's Sub checks (Z07 §5.1:
1/2/3/4) do not mask *(inferred: partner-by-agreement arrives as 6, not 2)*; see §16.

## 12. Attendance event

`AttendReward.shn` (`AR_ID, AR_Type, AR_Count, AR_ItemInx`) at `g_Server+0x209ed8` (DAT_006ec940). 2016 rows: weekly
rewards (type 0) `Attend_Week_1…4`, day-count rewards (type 1) such as `Attend_Day_20`.

```pseudo
0x10EB NC_CHAR_EVENT_ATTENDANCE_LIST_DB_REQ { u32 nCharNo, tm tmEventStartDate, tm tmEventEndDate, i32 tConnect }   @ FUN_00427d90
    usp_Attendance_getCallDateList(nCharNo, TIMESTAMP(start), TIMESTAMP(end), out) → rows (ts): AttendanceArray[i] = tm
        (sec, min, hour, mday, mon − 1, year − 1900; other tm fields 0); the row count is not limited to 28
        (original bug) D02-B16
    usp_Attendance_getRewardList(nCharNo, TIMESTAMP(start), out) → rows (ts, i32 reward): RewardList[] = (u8) reward, max 28
    Send 0x10EC NC_CHAR_EVENT_ATTENDANCE_LIST_DB_ACK { u32 nCharNo, u16 nError (0x2C00 ok / 0x2C01 DB error),
          i32 tConnect (echo), u8 AttendanceNum, tm AttendanceArray[28], u8 RewardNum, u8 RewardList[RewardNum] }   (0x3FC + n)
0x10EE NC_CHAR_EVENT_ATTENDANCE_CHECK_DB_REQ { u32 nCharNo, tm tCheckTime }                           @ FUN_00428130
    usp_Attendance_setCall(nCharNo, TIMESTAMP(tCheckTime), out nRet)
    Send 0x10EF { u32 nCharNo, u16 nError = 0x2C08 ok, 0x2C0A when nRet == -1111 (inferred: already checked), else 0x2C09 }
0x10F3 NC_CHAR_EVENT_ATTENDANCE_REWARD_DB_REQ { u32 nCharNo, u8 nIndex, tm tmEventDay, u8 nRewardID,
        tm tmCheckStartDay, tm tmCheckEndDay }                                                       @ FUN_00428290
    reply = 0x10F4 { u32 nCharNo, u8 nIndex, u8 nRewardID, u16 nError = 0x2C10 }
    count = usp_Attendance_getCount(nCharNo, start, end) first row i32 else 0x2C11
    row = AttendReward row with AR_ID == nRewardID:
        AR_Type 0 (week): count must be exactly 7, else 0x2C16;  AR_Type 1: count ≥ AR_Count, else 0x2C16;
        other type 0x2C12; AR_ItemInx not in ItemInfo 0x2C12; no row: item 0xFFFF → attribute step fails → 0x2C15
    item = new key (MakeItemKey), storage type 2, created with p_Item_Create_UseEmptyStorage (Item_Insert flag 1) else 0x2C15
    usp_Attendance_setReward(nCharNo, TIMESTAMP(tmEventDay), nRewardID, out nRet) else:
        nError = 0x2C14 when nRet == -1111 (inferred: already rewarded) else 0x2C11; p_Item_Delete(new item) (failure logged)
    on success: GameLog 0x044F NC_LOG_GAME_ITEM_CREATE { u32 nCharNo, u32 itemmaker = nCharNo, u64 key, u16 itemid,
                u16 location = 2 << 10 | slot }
    Send reply
```

## 13. Promotion (event) user and reward

```pseudo
0xA001 NC_PROMOTION_USER_REQ { u16 nWMHandle, u32 nUserNo }                                         @ FUN_0041ef50
    ok = p_IsPromotionUser(nUserNo, out i8 bIsPromotion, out nRet)                                   (no source in any backup)
    SendRaw { u8 0x0B, u16 0xA002, u16 nWMHandle, u32 nUserNo, u8 bIsPromotion, u16 DBError = ok ? 0x1848 : 0x1849 }
0xA004 NC_PROMOTION_DB_REWARD_REQ { u32 nUserNo, u8 nWorldNo, u32 nCharNo, u8 nClass, u8 nLevel }  @ FUN_0041eff0
    DBError = 0x1850; n = 0
    if nClass < 28 and g_PromotionClass[nClass] (DAT_004df010) != 0:
        rows = promotion reward table (g_Server+0x209e98, DAT_006ec900) rows with level == nLevel and class == that value
        if any row's item index is not in ItemInfo: 0x1853
        if rows: p_Promotion_Get(nUserNo, nWorldNo, nLevel, out u32 nCharNo, out ts) else 0x1856
                 a non-zero stored charNo (already rewarded) → 0x1856
                 else for each row: create the item (storage 2, lot, up to five options from the row) else 0x1854 / 0x1855;
                      RewardList += { u16 itemId, u16 lot }; GameLog 0x044F
                 p_Promotion_Set(nUserNo, nWorldNo, nLevel, nCharNo, out) else log "ERROR - SetPromotion REWARD INFO, But reward is successed…"
    Send 0xA005 NC_PROMOTION_DB_REWARD_ACK { u32 nUserNo, u8 nWorldNo, u32 nCharNo, u8 nClass, u8 nLevel, u16 DBError,
          u8 nNumOfItems, nNumOfItems × { u16 itemId, u16 lot } }
```

The table object at `g_Server+0x209e98` is constructed and destroyed (@ 0x00401059 / 0x00401fc9) but no code loads a file
into it (no SHN name refers to it, no other reference), so `DAT_006ec934` stays 0: in 2016 every `0xA004` answers 0x1850
with no items and never calls `p_Promotion_Get` / `p_Promotion_Set` *(inferred from the absence of a loader)*
(original bug) D02-B18. The WM
sends the client `0xA006` only when items are listed (W01 §6.2), so nothing happens.

## 14. Character rename with a rename item (dept 45)

```pseudo
0xB40A (NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_REQ by the PDB struct) { u16 hWMChar, u32 nRowNo, u32 nUserNo, u32 nCharNo,
        char sNewID[20], u8 bInit }   (from the WM 0xB409, W01 §4.1)                               @ FUN_00423cb0
    ok = usp_Character_setChangeID(nRowNo, nCharNo, sNewID, bInit, nUserNo, out nRet)              @ FUN_00465f30
        # (db-backup, "Ko Dong Gyun 2010.7.7"): renames tCharacter.sID; with bInit = 1 also clears friends, marriage,
        # holy promise (both directions), chat blocks, guild and academy membership; marks tCharacterChangeID row used.
    error = nRet == 0 ? (ok ? 0x20C0 : 0x20C5) :
            -3023 → 0x20C6 (character deleted / missing), -3025 → 0x20C7 (guild master cannot reset relations),
            -3027 … -3035 → 0x20C8 … 0x20D0 (friend, marriage, holy promise ×2, chat block, academy master, guild,
            academy, service-flag update failed), -3039 → 0x20D1 (name in use, or equal to the old name), other → 0x20C5
            (-3024 user mismatch and -3026 rename failed have no own code)
    Send 0xB40B NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ACK { u16 hWMChar, u16 error, u32 nUserNo, u32 nCharNo, char sNewID[20] }
        # client 0xB40C: 0x20C0 "Character name successfully changed.", 0x20C7 "Guild Master not allowed…", 0x20D1 "The
        # name is already taken by another user.", other codes: generic error text with the number
0xB411 (NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ITEM_USE_REQ by the PDB struct; handlers.json: …ITEM_USE_ACK)
        { u64 nCharIDChangeItemKey, u16 nCharIDChangeItemSlot, u8 bInit, u16 nUsedItemID, u32 nUserNo,
          CommonData { hdr6, PROTO_CHANGEATTR attr { u64 key, u16 itemid, u16 attrOffset }, u16 lockindex, u8 isClear },
          attr data… }   (from the zone, Z-side item use)                                          @ FUN_00423f30
    if isClear == 0: (newLot, …) = ItemLotAfterUse(itemid, attr data) (FUN_004038c0)
    ok = usp_Character_setChangeIDItemUsed(CommonData.charNo, bInit, nUserNo, key, lot words, out nRet)   @ FUN_004660a0
        # (db-backup) consumes the rename item and inserts the tCharacterChangeID row the char-select list reads (§3.1)
    nError = ok ? 0x20B0 : (nRet == -3025 ? 0x20BA : nRet == -3022 ? 0x20B9 : 0x20B8)
    if ok: GameLog 0x0459 NC_LOG_GAME_ITEM_USELOT { charNo, key, itemid, newLot }
    Send 0xB412 NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ITEM_USE_ACK { CommonData.hdr6, u16 nError, u16 lockindex, u16 nUsedItemID }
```

## 15. Procedures called by these handlers

Wrapper addresses: `tools/protocol-re/names/character/D02.json` (`SQL_<procedure>`). "both" = `Character.bak` and
`w00_Character.bak` have it with the binary's parameter count; "w00" = only the 2017 backup; "–" = no source anywhere.
Where the two differ, the version used is named.

| Handler(s) | Procedures (source) |
|---|---|
| 0x0C12 | `p_Char_GetListOfUserChar` (both), `usp_Tutorial_getIsSkip` (w00, also Account.bak), `p_Char_GetLoginData` (both; 3 versions in Character.bak, same SELECT), `p_Item_GetListType` (both), `usp_Tutorial_getCharInfo` (w00), `usp_Character_getChangeIDList` (both) |
| 0x1402 | `p_Char_Create` (both + Fixes; Character.bak used), `p_Char_CreateSetDefaultData`, `p_Char_SetLevelExp`, `p_Item_Create` / `_UseEmptyStorage` + option procedures (D03), `p_Skill_Set`, `p_Quest_Set`, `usp_Character_setShortCut` (w00), `usp_Tutorial_setCharInfo` (w00 = Fixes copy; Account.bak copy = original), `p_Char_Wipe` |
| 0x1408 | `p_Friend_Del_All` (both, no header), `p_Guild_Member_Leave`, `usp_GuildAcademy_getGuildNo`, `usp_GuildAcademy_delMember`, `p_Char_Delete` (all both) |
| 0x1411 / 0x1413 / 0x1415 | `p_Char_Rename` (both; Character.bak = pre-Fixes), `p_Guild_GetMyNo`, `p_Guild_Member_GetAll` (both) |
| 0x1004 | `p_Char_GetAllData` (both, 36 columns vs 37 read), `usp_Character_getFriendpoint` / `GetDiffFriendpoint` (w00), `p_Char_GetKQMap`, `p_Char_GetShape`, `p_Quest_GetAllDoing`, `p_Skill_GetAll`, `p_Skill_Set`, `p_Char_GetStateAllWithSetItemAndRestTime`, `p_HolyPromise_Get` / `GetMember`, `usp_HolyPromise_getRemainMoney`, `p_Friend_GetNumOfFriend` / `GetAll`, `p_Guild_GetMyNo`, `usp_GuildAcademy_getGuildNo`, item list + `p_Item_GetOptionAll` / `GetMobListAll` / `GetTitle`, `usp_Item_Get_EnchantAll` (third party?, db-backups.md), `usp_Pet_getInfo` (–), `p_Char_GetTitleAll`, `p_Char_GetChargedBufferAll`, `usp_ChatBlock_getBlockList`, `usp_Character_getSingleOption`, `usp_Character_chkKeyMap` / `getShortCutList` / `getKeyMap` / `getGameOption` (w00), `p_Char_GetOpt*` (both), `usp_SpamFilter_get`, `usp_SpamBlock_getTime`, `usp_Character_getItemActionCoolTime` (w00), `usp_InGameGuide_getViewList` (w00, no header), `usp_Gamble_getCoin` / `getExchangedCoin` (w00), `usp_Collection_get*List` (w00), `usp_Tutorial_getCharInfo` (w00), `usp_ChatColor_get` (w00), `usp_Character_getAutoScroll`, `usp_Item_getAutoMonList` (w00) |
| 0x1036 / 0x1037 | `p_Char_Login` (w00 "JK CHO 2014.8.22" used; Character.bak copy has no result set and a third-party LoggedInChars table), `p_Friend_*`, `usp_Character_getFriendpoint` / `setFriendpoint` (w00 has 3 parameters, the call string 2), `p_Char_Logout` |
| 0x0841 | `usp_CharacterLoading` (binary 11, both backups 6), `usp_CharacterLoadingDetailInfo` (–) |
| dept 16 | `p_Char_SaveLevelExpFrame`, `p_Char_SaveLocation`, `p_Char_SaveStat`, `p_Quest_Set`, `p_Char_DelStateAll`, `p_Char_SetStateWithSetItemAndRestTime` (run-time string; w00 and Character.bak, no header), `p_Skill_Set`, `p_Char_SetTitle`, `p_Char_SavePKCount`, `usp_Character_setRestExpExecTime`, `usp_Character_setAutoPick`, `usp_SpamBlock_setTime`, `usp_Character_setItemActionCoolTime` (w00), `usp_Character_setMysteryBolt`, `usp_Character_setBuffScroll` / `setChargedbuffScroll` / `usp_Item_setAutoMon` (w00) |
| 0x1056 / 0x105D / 0x1063 / 0x1070 / 0x10B3 | `p_Char_ChangeClass`, `p_Char_StatPoint_Inc`, `usp_ChargeItem_UseStatPointDecLotChange` / `DecDel`, `p_Char_FameSet`, `usp_Char_chkCharNo` (w00) |
| 0x10D1 / 0x111A | `usp_Character_setStatPoint` (both, source cut at 8 KB), `p_Char_StatPoint_Dec` |
| 0x1112 / 0x1118 | `p_Char_GetShape`, `p_Char_CreateSetDefaultData`, item create, `usp_Tutorial_setCharInfo` |
| 0x0847 / 0x0863 / 0x0868 / 0x10DB | `usp_SpamFilter_set`, `usp_Character_setChatBan` (w00 matches; Character.bak copies have 1 and 2 parameters), `usp_InGameGuide_setGuideNo` (w00) |
| 0x1076 / 0x1099 / 0x107A / 0x107E | item lists (D03), `p_Char_GetShape`, `p_Char_SetShape`, `p_Item_Delete`, `p_Item_SetOption` |
| 0x1080–0x1093 | `p_Char_WeddingStatus_Get` / `_Set`, `p_Char_GetCharID`, `p_Char_Wedding_*` (both, no Korean header; Character.bak keeps several test versions with minute timers; w00 used) |
| 0x10EB / 0x10EE / 0x10F3 | `usp_Attendance_*` (w00 only), item create, `p_Item_Delete` |
| 0xA001 / 0xA004 | `p_IsPromotionUser`, `p_Promotion_Get`, `p_Promotion_Set` (– all three) |
| 0xB40A / 0xB411 | `usp_Character_setChangeID` (both + Fixes; Character.bak used), `usp_Character_setChangeIDItemUsed` (both) |

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D02-B1 | 0x1402 create | DB results −1/−2/−3 become 0x182/0x183/0x184; the client's create scene has no case for them | no message, the create screen waits; −1 is "slot in use" | map to 0x85 / 0x82 |
| D02-B2 | `p_Char_Create` *(db-backup)* | name-exists check `RETURN`s inside `BEGIN TRAN` without `ROLLBACK` | an open transaction on that connection after a duplicate name | rollback first (the 2018 Fixes copy moved the check) |
| D02-B3 | 0x1408 delete | errors are `err + 0xC0`: 0xC5, 0x188, 0x189, 0xC1–0xC4; 0xC7 (guild leader) is never produced | the client shows "Unable to delete a Guild Master character." for every failure | distinct codes; refuse guild masters |
| D02-B4 | 0x1408 delete | friends are deleted (and the guild membership left) before `p_Char_Delete`, no rollback across procedures | a failed delete still loses friends / guild | one transaction |
| D02-B5 | 0x1415 | `SetOpcode` size 14 + n·234 for a 16 + n·234 payload | last 2 bytes of each part not sent | size + 2 |
| D02-B6 | 0x1004 | `0x1006` codes 0x582…0x5A0 written at +4; the WM reads +2 | the client gets a garbage code (usually "The Map is under maintenance") instead of the "error in … Information" text | write at +2 (as the 0x591/0x5A2/0x5A3/0x31EA paths do) |
| D02-B7 | 0x1004 step 14 | `0x1097.isGuildAcademyMember` never written | stale byte to the WM | write the member flag |
| D02-B8 | 0x1036 | `usp_Character_setFriendpoint` is called with `(?,?)` but three parameters bound | the procedure's `@nRet` never comes back; failures are not detected (inferred) | `(?,?,?)` |
| D02-B9 | 0x1056 | GameLog 0x0420 map = "UNUSE", x/y not written | stale coordinates in the class-change log | real position or 0 |
| D02-B10 | 0x10D1 | nRet −1011/−1012/−1014/−1091…−1094 and "ItemID Not Matching" return without `0x10D2` | the zone's free-stat lock (p+0x5e0c) stays set: every later stat change answers 0xAC7 until relog | always answer with an error |
| D02-B11 | 0x10D1 | item-use GameLog lines are written whatever `nErrorType` is | logs claim restat items were used when the DB refused | log only on 0xAC1 |
| D02-B12 | 0x0868 | a failed `usp_Character_setChatBan` sends no `0x0869` (0x0863 sends 0x2169) | the GM gets no answer | send an error code |
| D02-B13 | 0x1076 / 0x1099 | `Error` and `PacketOrder` of the reply never written; errors look like an empty list | stale bytes; failures invisible | set Error |
| D02-B14 | 0x107A | race and class are written from the request (`p_Char_SetShape` updates nRace, nClass) without comparing them with the stored shape | a client that sends other class bits through the WM beauty shop changes its class/race (inferred, the WM forwards the client u32, W01 §4.3) | keep stored race/class |
| D02-B15 | 0x1093 | `Connected` and `CurrentMap` of 0x1094 not written | stale bytes to the zone | fill or zero |
| D02-B16 | 0x10EB | call-date rows are copied into `tm AttendanceArray[28]` with no limit | more than 28 rows overflow the stack buffer | stop at 28 |
| D02-B17 | 0x1087 | 0x1088 `Partner` not written | stale u32 to the zone | echo Partner |
| D02-B18 | 0xA004 | the promotion reward table is never loaded | the promotion reward never grants anything; `p_Promotion_Get/Set` are dead code | load the table |
| D02-B19 | 0x1004 §4.1 | `p_Char_GetAllData` read with 37 columns; both backups return 36 | with those procedures the "return map" override is silently skipped (db-backup mismatch; the 2016 DB may have had the column) | – |

## 16. Not reconstructed / uncertain

- **Wedding sub-status 6 / +4 marker.** The DB writes 6 for "partner applied for divorce by agreement" and adds 4 on
  `Divorce_Cancel`; Z07 §5.1 reads Sub values 1–4. Whether the zone masks bit 2 or treats 5–7 as "none" was not checked
  (zone `FUN_0059f2d0` area). The 0x1090 sub-status bytes come from `p_Char_Wedding_Divorce_Cancel`'s outputs through
  `FUN_0046d9a0` (arguments lost by the decompiler).
- `0x1004` step 5–8: which `nStatusDone` filter belongs to doing / done / read / repeat (one comes from a register);
  record layouts of the quest blobs are D04's.
- `0x1004` holy promise blocks (0x9427 / 0x9429 / 0x9444) and the improved / old option packets (0x702C, 0x7018…0x7024):
  only their sources and opcodes are recorded; their layouts belong to D04 (holy promise) and Z-side option items.
- `0x1017` item packets: header bytes (part mark 5 / 8 / 0x10 / 0x22 per storage) are read from the code; the meaning of
  storage types 12 and 15 and the item record (`Send_NC_CHAR_ITEM_CMD` @ FUN_004056a0) are D03's.
- `p_Char_GetAllData` 37th column: name and meaning unknown (the 2016 procedure is lost).
- `usp_CharacterLoading` (11 parameters) and `usp_CharacterLoadingDetailInfo`, `p_IsPromotionUser`, `p_Promotion_Get`,
  `p_Promotion_Set`, `usp_Pet_getInfo`: no source; semantics from the binary only.
- `usp_Character_setStatPoint` source is cut at 8 KB (`bak.py` does not reassemble pages): the multi-item path and the
  −1023 / −1024 meanings are inferred from the binary's code mapping.
- `0x0804` heartbeat (`LAB_0043cdf0`) not decompiled; assumed to answer 0x0805 like the other servers.
- `0x0812`–`0x0815` field names: the 2017 PDB structs are larger than the 2016 packets.
- The SOAP item-shop client (`cUKItemShop`, gSOAP) setup and pool size (FUN_0043f690) were not followed; the URL length
  from the response is copied without a bound check (inferred risk, not verified against the buffer size).
- `0x0841` sender (zone or WM) not identified here.
