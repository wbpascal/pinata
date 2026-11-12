# Character server: social, guild, quests, skills (D04)

Source: `Files/Server/2016/w00_Character/Character Release.exe` (export `re-data/exports/character`). Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/character tools/protocol-re/names/character <addr>`. Names:
`tools/protocol-re/names/character/D04.json` (handlers `fc_NC_*` = the opcode name; where the handler's own log string
carries another `fc_NC_*` name it is said; helpers are ours). Framework (CheckAlive, DB getters, sends, `SQL_<procedure>`
wrappers): D02 §1 (`docs/pseudocode/db/D02-character.md`). Conventions (`hdr`, `lock`, `cell`, `key`, `attr`, "Send", "Log")
exactly as D03's header (`docs/pseudocode/db/D03-character-items.md` lines 14–26). Zone side of the quest / guild / academy /
tournament / holy-promise packets: Z08 (`docs/pseudocode/zone/Z08-content.md`); WM side of the guild / academy / friend packets:
W03 / W04. Layouts: `docs/protocol/annotations/D04.json` (key `character`).

Evidence markers as in `CLAUDE.md`: plain = read in the 2016 binary; *(db-backup)* = only from the procedure source in
`Files/Server/2016/_Database` (version used: `w00_Character.bak` unless stated; where `Character.bak` differs it is said);
*(pdb2017)* = 2017 PDB only; *(inferred)*.

**Conventions in this file (in addition to D03's).**
- Offsets are payload offsets (after the 2-byte opcode). `hdr` = `NETPACKETZONEHEADER {u16 clienthandle, u32 charNo}`;
  `whdr` = the WM's 6-byte header of the same shape (W01 calls it the `ref` prefix, `docs/knowledge/Z01.md`).
- Every handler starts with `if !CheckAlive(pkt): return` (D02 §1.1). No handler checks the packet length; counts inside a
  request are trusted (see the bugs section).
- "wrapper returns ok" = the `SQL_<procedure>` wrapper's bool, which is `nRet == 0` unless stated. Ghidra shows several
  per-handler DB helpers as `void`; they return a bool in `EAX` (checked in the disassembly, e.g. FUN_00406b80 ends with
  `xor eax,eax` / `mov eax,1`).
- Answers go back on the requesting link (zone or WM). Which server sends a request: Z08 / W03 / W04 for the senders.

## 1. Quests (dept 17, CParserCharacter)

`tQuest {nCharNo, nQuestNo, nStatus, sData varbinary(100)}` *(db-backup)*. The zone keeps the quest diary; the Character
server only stores single records. `PLAYER_QUEST_INFO` = `{u16 ID, u8 Status, PLAYER_QUEST_DATA Data (0x1D)}` (0x20 bytes;
Data = `{i64 StartTime, i64 EndTime, u32 RepeatCount, u8 ProgressStep, u8 End_NPCMobCount[5], u8 flags, u16
End_RunningTimeSec}` *(pdb2017)*). Status values = `PLAYER_QUEST_STATUS` (0 NONE, 1 ABORT, 2 DONE, 3 SOON, 4 REPEAT, 5 ABLE,
6 ING, 7 FAILED, 8 REWARD, 9 LOWABLE, 20 READ_ABLE) *(pdb2017; Z08 uses the same numbers)*.

Result codes (u16 `ErrorType`, quest-local numbers, no client text; the zone maps every failure to its own QUEST_ERROR,
Z08 §3.3): **0xB41 ok**, 0xB42 clear failed, 0xB43 set failed, 0xB46 give-up failed, 0xBC2 reward item insert failed, 0xBC3
reward money failed, 0xBC5 reward title failed. 0xBC4 is a rollback case nothing sets.

### 1.1 Store one record

```pseudo
Quest_Store(rec{+2 charNo, +7 u16 questNo, +9 u8 status, +10 data[29]}) -> bool              @ FUN_00406b80
    p_Quest_Set(nCharNo, nQuestNo, nStatus, sData = 100 bytes from rec+9 … , OUT nRet)            @ wrapper FUN_004530e0
        # binds sData with length 100 although only the 29 Data bytes are filled; the other 71 bytes are uninitialised
        # stack and are stored in tQuest.sData (original bug) D04-B1
    # (db-backup, 2004 CJC) UPDATE tQuest SET nStatus, sData WHERE (charNo, questNo); no row → INSERT. nRet = @@ERROR.
    failure: log "ERROR - CharSetQuest, nCharNo=%d, nQuestNo=%d, nStatus=%d"; return false

Quest_Delete(charNo, questNo) -> bool                                                         @ FUN_00406c50
    p_Quest_Del(nCharNo, nQuestNo, OUT nRet)                                                       @ wrapper FUN_004531b0
    # (db-backup) DELETE; nRet = 0 only if exactly one row was deleted, else 1 (so clearing a quest with no record fails)
    failure: log "ERROR - CharDelQuest, nCharNo=%d, nQuestNo=%d, Error=%d"
```

### 1.2 Handlers

```pseudo
0x4403 NC_QUEST_DB_SET_INFO_REQ { hdr, u8 nQSC @6, PLAYER_QUEST_INFO QuestInfo @7 }      (0x27)   @ FUN_00406d00
    err = Quest_Store(payload) ? 0xB41 : 0xB43
    ok: Log 0x043E NC_LOG_GAME_QUEST_SET_INFO { charNo, mappos "Need" (D03-B11), questid, queststatus = QuestInfo.Status }
    Send 0x4404 NC_QUEST_DB_SET_INFO_ACK { hdr, nQSC, QuestInfo (copied from the request), u16 ErrorType = err }   (0x29)

0x4405 NC_QUEST_DB_CLEAR_REQ { hdr, u16 nQuestID @6 }                                    (8)      @ FUN_00406eb0
    err = Quest_Delete(charNo, nQuestID) ? 0xB41 : 0xB42
    ok: Log 0x0440 NC_LOG_GAME_QUEST_DELETE { charNo, "Need", questid }
    Send 0x4406 NC_QUEST_DB_CLEAR_ACK { hdr, u16 nQuestID, u16 ErrorType = err }                                   (0xA)

0x4409 NC_QUEST_DB_GIVE_UP_REQ { hdr, u16 nQuestID @6 }                                  (8)      @ FUN_00407050
    # give-up does not delete: the record becomes READ_ABLE with zeroed data
    err = Quest_Store({charNo, nQuestID, status 20 PQS_READ_ABLE, data = 0}) ? 0xB41 : 0xB46
    ok: Log 0x0440 NC_LOG_GAME_QUEST_DELETE { charNo, "Need", questid }
    Send 0x440A NC_QUEST_DB_GIVE_UP_ACK { hdr, u16 nQuestID, u16 ErrorType = err }                                 (0xA)

0x4418 NC_QUEST_DB_READ_REQ { hdr, u16 nQuestID @6 }                                     (8)      @ FUN_00407230
    err = Quest_Store({charNo, nQuestID, status 20 PQS_READ_ABLE, data = 0}) ? 0xB41 : 0xB43
    ok: Log 0x043E NC_LOG_GAME_QUEST_SET_INFO { charNo, "Need", questid, queststatus 20 }
    Send 0x4419 NC_QUEST_DB_READ_ACK { hdr, u16 err @6, u16 nQuestID @8 }                                          (0xA)
```

Zone handling of the answers: Z08 §3.3 (any `ErrorType ≠ 0xB41` → QUEST_ERROR 0xC0E / 0xC00; the give-up code goes to the
client in 0x4408). The Character server never reads the existing record: a SET_INFO for a quest the character never had
creates it, and READ / GIVE_UP overwrite whatever status was stored.

```pseudo
0x441A NC_QUEST_DB_DONE_REQ { hdr, u32 UserNo @6, u16 NPCID @0xA, u8 nQSC @0xC, PLAYER_QUEST_INFO QuestInfo @0xD,
        u32 nMoney @0x2D, u32 nExp @0x31, u32 nFame @0x35, u64 nCur_Money @0x39, u64 nCur_Exp @0x41, u32 nCur_Fame @0x49,
        u8 CT_Type @0x4D, u8 CT_ElementNo @0x4E, u8 nCur_CT_ElementValue @0x4F, u16 nLockIndex @0x50,
        u8 nItemCreateCount @0x52, PROTO_ITEM_CREATE ItemCreate[n] @0x53 (0x26 each), attr data }        @ FUN_00431550
    # PDB layout (0x53 + n·0x26) matches every offset the 2016 code reads.
    err = 0xB41; inserted = 0
    for i < nItemCreateCount:                                       # ItemCreate = {owner, MAPPOS map, cell, key, itemid, u16 attr}
        r = Item_Insert(key, owner, cell >> 10, cell & 0x3FF, itemid, attr bytes at payload + ItemCreate.attr, useEmpty = 0)
                                                                    # FUN_0046be10 (D03 §1.2)
        r ≠ 0: log; Item_Delete(key) for each of the `inserted` items (FUN_00468130, failures logged); err = 0xBC2; break
        inserted++
    if nMoney ≠ 0 and err == 0xB41: p_Char_MoneyAdd(charNo, nMoney) fails → err = 0xBC3                 @ FUN_00459440
    if nExp ≠ 0 and err == 0xB41: p_Char_AddExp(charNo, nExp)        # failure is only logged "CharAddExp ERROR:…"
    # nFame is never written to the DB here (only logged below); fame is saved by the zone's CHARSAVE messages (D02) (inferred)
    if CT_Type ≠ 0 and err == 0xB41:
        title = {u8 CT_Type, u8 (CT_ElementNo & 0x3F) | 0x80}       # CT_INFO {Type, ElementNo:6, ElementValue:2} → value 2
        SetCharTitles(charNo, 1, &title) fails → err = 0xBC5       (§6.1)
    if err == 0xB41:
        if !Quest_Store({charNo, QuestInfo}) (§1.1): err = 0xB43
        else:
            Log 0x051A NC_LOG_GAME_QUEST_REWARD_ITEM { owner, questid, key, itemid }          per created item     (0x10)
            nMoney ≠ 0: Log 0x0519 NC_LOG_GAME_QUEST_REWARD_MONEY { charNo, questid, old = nCur_Money, new = nCur_Money + nMoney }
            nExp ≠ 0:   Log 0x0518 NC_LOG_GAME_QUEST_REWARD_EXP { charNo, questid, old = nCur_Exp, new = nCur_Exp + nExp }
            nFame ≠ 0:  Log 0x051C NC_LOG_GAME_QUEST_REWARD_FAME { charNo, questid, old = nCur_Fame, new = nCur_Fame + nFame }
            CT_Type ≠ 0: Log 0x051F NC_LOG_GAME_QUEST_REWARD_TITLE { charNo, questid, ct_type, ct_elementno }
            Log 0x043E NC_LOG_GAME_QUEST_SET_INFO { charNo, "Need", questid, QuestInfo.Status }
            Log 0xC810 NC_SYSLOG_CHAR_QUEST_FINISHED { UserNo, charNo, QuestID, u64 RewardMoney = nMoney,
                RewardItemNo = ItemCreate[0].itemid or 0xFFFF, u64 ClearTime = (EndTime − StartTime) / 60, QuestEndNPC = NPCID }
    rollback by err (switch with fall-through):
        0xB43: if CT_Type ≠ 0 and err == 0xB41: restore the old title value   # never true inside case 0xB43: dead code,
               # the new title stays after a failed quest store (original bug) D04-B2
        0xB43, 0xBC5: p_Char_SubExp(charNo, nExp)   (also when nExp == 0 or the add had failed)               @ FUN_00459ce0
        0xB43, 0xBC5, 0xBC4: p_Char_MoneySub(charNo, nMoney)   (also when nMoney == 0)                          @ FUN_004594e0
        0xB43, 0xBC5, 0xBC4, 0xBC3: Item_Delete(key) for each inserted item
    Send 0x441B NC_QUEST_DB_DONE_ACK { hdr, nQSC, QuestInfo, u16 nLockIndex, u16 ErrorType = err }                (0x2B)
```

The zone gives the reward items from its lock list only on 0xB41 (Z08 §3.3); the DB rows already exist at that point. The
procedures (*(db-backup)*): `p_Char_MoneyAdd` / `p_Char_MoneySub` / `p_Char_AddExp` / `p_Char_SubExp` are D02's
(`tCharacter.nMoney` / `nExp`). The rollback `p_Char_SubExp` after a failed `p_Char_AddExp` subtracts experience that was
never added (original bug) D04-B3.

## 2. Skills (dept 18, CParserCharacter)

`tSkill {nCharNo, nSkillNo smallint, nSkillLevel, nSkillExp, nSkillWriteTime bigint, nSkillCoolTime, nSkillPowerDemage,
nSkillPowerSP, nSkillPowerKeepTime, nSkillPowerCoolTime}` *(db-backup)*. Passive skills are stored as `nSkillNo = id + 30000`.
Zone side and client texts of every answer: Z03 §9 (`docs/pseudocode/zone/Z03-combat.md`).

```pseudo
0x4801 NC_SKILL_SKILLTEACH_REQ { hdr, u32 chrregnum @6, u16 skillid @0xA, u8 ispassive @0xC, u16 removeid @0xD }  (0xF)
                                                                    @ FUN_00411f10
    if ispassive == 1:
        ok = p_Skill_SetPassive(chrregnum, nSkillNewNo = skillid + 30000, bSkillOld = (removeid ≠ 0xFFFF),
                                nSkillOldNo = removeid + 30000)                                  @ wrapper FUN_00452dd0
        # (db-backup, 2005 CJC) bSkillOld = 1: UPDATE the old row's nSkillNo to the new number (a passive upgrade replaces
        # the lower one); no old row → nRet 1. bSkillOld = 0: INSERT a new row (duplicate → SQL error → nRet ≠ 0).
    else:
        n = p_Skill_Get(chrregnum, skillid, OUT level, exp, writeTime, coolTime, 4 powers)       @ wrapper FUN_00452b20
        # (db-backup) nRet = @@ROWCOUNT: 0 = not learned, 1 = learned; the wrapper returns nRet (−1 if the call failed)
        ok = n == 0 and p_Skill_Set(chrregnum, skillid, level 1, exp 0, writeTime = time(NULL) (i64), coolTime 0,
                                    powers 0, 0, 0, 0)                                           @ wrapper FUN_00452c70
        # (db-backup) UPDATE … else INSERT; nRet = @@ERROR
    ok: Send 0x4802 NC_SKILL_SKILLTEACHSUC_ACK { hdr, u16 skillid, u8 ispassive }                                  (9)
        Log 0x0432 NC_LOG_GAME_SKILL_LEARN { chrregnum, "Need", u16 skill = ispassive ? skillid + 30000 : skillid, u8 1 }
    else (already learned, DB error, missing old passive):
        Send 0x4803 NC_SKILL_SKILLTEACHFAIL_ACK { hdr, u8 }   (7 bytes; the last byte is never written: CSendPacket_Init
        # FUN_0044f880 only sets the buffer header, so one uninitialised stack byte goes on the wire) (original bug) D04-B4

0x4825 NC_SKILL_ERASE_REQ { hdr, u16 skill @6 }                                          (8)      @ FUN_004121b0
    ok = p_Skill_Del(charNo, skill)                                                              @ wrapper FUN_00452e90
    # (db-backup) DELETE; nRet = @@ERROR, so deleting a skill the character does not have also succeeds
    ok:   err = 0x1501; Log 0x0433 NC_LOG_GAME_SKILL_DELETE { charNo, "Need", skill, u8 1 }
    fail: err = 0x1504; log "FAILED - fc_NC_SKILL_ERASE_REQ, nCharNo=%d, nSkill=%d"
    Send raw 0x4826 NC_SKILL_ERASE_ACK { hdr, u16 skill, u16 err }                                                 (0xA)

0x480B NC_SKILL_EMPOW_RESET_DB_REQ { hdr }                                               (6)      @ FUN_00412370
    ok = p_Skill_ResetPower(charNo)        # wrapper FUN_00453070 returns nRet == 1 (this procedure reports success as 1)
    # (db-backup) in one transaction: clear bit 31 of tCharacter.nFlags ("skillempower_can_reset") and set the four
    # nSkillPower* columns of every tSkill row of the character to 0; nRet 1 = ok, 0 = no character / SQL error
    Send raw ok ? 0x480D NC_SKILL_EMPOW_RESET_DB_SUC_ACK { hdr } : 0x480C NC_SKILL_EMPOW_RESET_DB_FAIL_ACK { hdr }  (6)

0x4812 NC_SKILL_EMPOWALLOC_DB_REQ { hdr, u16 lockindex @6, u16 skill @8, u8 bUseItem @0xA,
        PROTO_NC_SKILL_EMPOWALLOC_REQ empower @0xB { u16 skill, SKILL_EMPOWER plus @0xD, SKILL_EMPOWER minus @0xF },
        PROTO_ITEMDELETEREQUEST redistitem @0x11 { hdr, u16 lock, u8 count @0x19, changeinfo {u16 itemId @0x1A,
        u64 key @0x1C, u16 attrOffset @0x24}, u64 vanishkeys[] @0x28 } }                                @ FUN_004124c0
    # the redistribution item is consumed first (same helper as 0x3459 NC_ITEMDB_DESTROY_REQ, D03 §7.5):
    r = DestroyItems(redistitem)                                                                 @ FUN_00412420
        # count bit 7: ItemAttr_Save(key, itemId, payload + attrOffset) fails → 1; bits 0–6: Item_Delete(vanishkeys[i]),
        # first failure → 2
    r == 1: err = 0x887 (log key, itemId, error)
    r == 2: err = 0x888
    r == 0: SKILL_EMPOWER plus = {damage:4, sp:4, keeptime:4, cooltime:4}
            ok = p_Skill_SetPowerAll(charNo, empower.skill, plus.damage, plus.sp, plus.keeptime, plus.cooltime)
                                                                    # wrapper FUN_00452f80 returns nRet == 1
            # (db-backup) w00: any value > 5 → nRet 0; UPDATE the four columns of (charNo, skill); no row → nRet 0.
            # Character.bak's older version has no > 5 check.
            err = ok ? 0x881 : 0x885
    # `minus` is never read: the zone sends the resulting totals in `plus` (inferred from the overwrite)
    # a failed SetPowerAll does not give back the consumed items (original bug) D04-B5
    Send raw 0x4813 NC_SKILL_EMPOWALLOC_DB_ACK { hdr, u16 lockindex, u16 skill (the outer one @8), u16 err, u8 bUseItem } (0xD)
```

The zone kicks the player (0x68A) on any 0x4813 error other than 0x881 to resync (Z03 §9.1).

## 3. Friends (dept 21) and the kingdom-quest reward (dept 22)

`tFriend {nCharNo, nFriendCharNo, nFlags}` *(db-backup)*: one row per direction, foreign keys to `tCharacter`. The WM sends
these requests (W04) and turns the answers into the client's `0x5402` / `0x5406` (client texts below are those handlers'
switch on the same code, `GameFrameWork::On_NC_FRIEND_SET_ACK` FUN_004ad950 / `On_NC_FRIEND_DEL_ACK` FUN_004adc30; that the
WM passes the code through unchanged is W04's to confirm). The friend list at login (`0x1010`, `p_Friend_GetAll`) and friend
points (`usp_Character_*Friendpoint`) are D02 §4–5 / D03 §6.5 (0x34BF).

```pseudo
0x5410 NC_FRIEND_DB_SET_REQ { u16 handle_charno, u16 handle_friendno, u32 charno @4, u32 friendno @8, u8 flag @0xC } (0xD)
                                                                    @ FUN_004126a0
    r = p_Friend_Set(nMAXFRIEND = 100, charno, friendno, flag)                                 @ wrapper FUN_004532c0
    # (db-backup, 2004 CJC) 1 same character; 2 my count (p_Friend_GetNumOfFriend) ≥ max; 3 friend's count ≥ max;
    # else INSERT both directions in one transaction, nRet = @@ERROR (547 = no such character (FK), 2627 = already friends)
    err = r 0 → 0x941, 1 → 0x942, 2 → 0x943, 3 → 0x947, else (DB errors, 547, 2627, wrapper −1) → 0x949
    Send raw 0x5411 NC_FRIEND_DB_SET_ACK { handle_charno, handle_friendno, charno, friendno, u16 err }            (0xE)
    # client: 0x941 success (no text here; the list update comes separately), 0x942 "You cannot add yourself to your Buddy
    # List.", 0x943 "Cannot register anymore friend.", 0x947 "%s cannot register anymore friend.", 0x949 "Already have a
    # friend request." — so "already friends" and every DB error show the friend-request text (original bug) D04-B6;
    # the client's own "%s is already registered in the friends list." (0x945 / 0x948) is never produced here

0x5412 NC_FRIEND_DB_DEL_REQ { u16 handle_charno, u32 charno @2, Name5 charid @6, Name5 friendid @0x1A }      (0x2E)
                                                                    @ FUN_00436690
    friendNo = p_Char_GetCharNo(sID = friendid)        # wrapper FUN_00458790; output charNo (0 = no such name)
    friendNo == 0: err = 0x953
    else: err = p_Friend_Del(charno, friendNo) ? 0x951 : 0x952                                 @ wrapper FUN_00453380
          # (db-backup) deletes both directions; nRet = sum of the two @@ERRORs, so deleting a non-friend succeeds
    Send raw 0x5413 NC_FRIEND_DB_DEL_ACK { handle_charno, charno, charid, friendid, u16 err }                      (0x30)
    # client: 0x951 "%s has been deleted from the friends list.", 0x952 / 0x953 "Cannot find %s."

0x5414 NC_FRIEND_DB_GET_REQ { u16 handle_char, u32 charno @2, u32 friendno @6 }           (0xA)    @ FUN_00437cd0
    row = p_Friend_Get(charno, friendno)                                                       @ wrapper FUN_00453480
    # (db-backup) SELECT nFriendCharNo, F.nFlags, C.sID, S.nClass, C.nLevel, C.sLoginZone, C.dLastLoginDate
    #   FROM tFriend F JOIN tCharacterShape S JOIN tCharacter C (bDeleted = 0); read as U32, U8, Str, U8, U16, Str, Time
    no row: err = 0x952 (friendinfo left uninitialised)
    row:    err = 0x951; friendinfo = PROTO_FRIEND_INFO {
                logininfo = PROTO_FRIEND_DATE { login 0, year:11, month:4, day:5, hour:5 from dLastLoginDate } (bits 26–31
                    keep stack garbage), charid = sID (20 chars), classid = nClass, level = (u8) nLevel, isparty 0,
                flag = nFlags, map = sLoginZone (12 chars), statustitle = "NONE" (8 bytes; the other 24 bytes uninitialised) }
    Send raw 0x5415 NC_FRIEND_DB_GET_ACK { handle_char, charno, friendno, u16 err, PROTO_FRIEND_INFO friendinfo }   (0x54)
```

```pseudo
0x5815 NC_KQ_REWARD_REQ { u32 fame @0, u64 cen @4, PROTO_NC_ITEMDB_CREATEITEMLIST_REQ itmlst @0xC { hdr @0xC,
        u32 owner @0x12, u16 lockindex @0x16, u16 map @0x18, u64 price @0x1A, PROTO_ITEM_CMD itemlist @0x22 } }
                                                                    @ FUN_004321d0
    # no zone header first: the reply header is itmlst.hdr
    ok = CreateChestItemList(itmlst)   # FUN_0040f370, D03 §7.2: the first item keeps its cell, the others go into the
                                        # first item's contents storage (type 10); itmlst.price is charged inside
    !ok: err = 0x1101 → fail
    cen ≠ 0: p_Char_MoneyAdd(owner, cen) fails → err = 0x1102 → delete the created items → fail
        # the delete walk advances by datasize × 0x72 like D03-B19, so only the first item is removed reliably
    fame ≠ 0: AddCharFame(owner, fame)                                                          @ FUN_00410f20
        # p_Char_FameAdd; a failure is only logged "AddCharFame ERROR:CharNo=%d, Fame=%d": the helper always returns 1,
        # so the handler's error 0x1103 (with p_Char_MoneySub(owner, cen) refund FUN_00402c60 and item deletion) is dead
        # code (original bug) D04-B7
    cen ≠ 0:  Log 0x0519 NC_LOG_GAME_QUEST_REWARD_MONEY { owner, questid 0, old 0, new = cen }
    fame ≠ 0: Log 0x051C NC_LOG_GAME_QUEST_REWARD_FAME { owner, questid 0, old 0, new = fame }
    Send raw 0x5816 NC_KQ_REWARDSUC_ACK { itmlst.hdr, u16 lockindex }                                              (8)
  fail:
    Send raw 0x5817 NC_KQ_REWARDFAIL_ACK { itmlst.hdr, u16 lockindex, u16 error }                                  (0xA)
```

Zone side: Z08 §4 (the zone gives the locked reward items on 0x5816, cancels them on 0x5817). Error codes 0x1101–0x1103
are only logged by the zone.

## 4. Weapon licences (dept 23 WEAPONTITLE) and character titles (dept 24 CHARACTERTITLE)

Tables *(db-backup)*: `tItemMobList {nItemKey, nMobID, nGrade, nKillCount}` (licences on a weapon), `tItemTitle {nItemKey,
nTitleType, nTitleCharNo, sTitle nvarchar(24)}` (the weapon's first licensee), `tCharacterTitle {nCharNo, nType, nElementNo,
nElementValue bigint}`. Zone side: Z08 §7.1 (`0x5C01` licence flow, the zone ignores the answers to 0x5C09 / 0x5C0B) and
Z08 §7.2 (0x6008 sender).

### 4.1 Weapon licences

```pseudo
0x5C05 NC_WT_LICENSE_SET_REQ { hdr, u16 lockindex @6, u32 chrregnum @8, Name5 chrname @0xC, u64 WeaponItemKey @0x20,
        u64 LicenItemKey @0x28, u16 LicenseMobID @0x30, echo_data {ITEM_INVEN licenseitem, weaponitem} @0x32 }   (0x36)
                                                                    @ FUN_00412790
    r = p_Item_SetWeaponTitle(WeaponItemKey, LicenItemKey, LicenseMobID, chrregnum, sTitle = chrname (24-char bind))
                                                                    # wrapper FUN_00461c70 returns nRet (−1 if the call failed)
    # (db-backup, 2005 CJC) one transaction: p_Item_SetMobList(weapon, mob, 0, 0) (upsert tItemMobList) else nRet 1;
    # if the weapon now has exactly one licence: p_Item_SetTitle(weapon, 0, charNo, name) (first licensee) else nRet 2;
    # p_Item_Delete(licence item) else nRet 3; 0 = ok
    err = r == 0 ? 0x9B9 : 0x9BA                     # the procedure's 1/2/3 are not told apart
    Send raw 0x5C06 NC_WT_LICENSE_SET_ACK { hdr, u16 Error = err, u16 lockindex, echo_data }                       (0xE)
    Log 0x0454 NC_LOG_GAME_ITEM_TITLE { chrregnum, WeaponItemKey, LicenseItemKey, u16 LicenseMobID,
        u16 @0x16 = request u16 @0x36, u16 @0x18 = request u16 @0x38 }                                            (0x1A)
    # sent whether or not the licence was stored (original bug) D04-B8; the 2016 log is 4 bytes longer than the 2017 struct
    # (0x16) and fills them from 4 bytes past the end of the 0x36-byte request (stale receive-buffer bytes) (original bug) D04-B9

0x5C07 NC_WT_LICENSE_CLR_REQ { hdr, u16 lockindex @6, echo_data @8, u64 WeaponItemKey @0xC, u16 MobID @0x14,
        u64 LicenseClearItemKey @0x16, u16 LicenseClearItemID @0x1E, u8 LicenseClearItemDelete @0x20,
        u16 LicenseClearAttr @0x21, clear item attribute bytes @0x23 }                              @ FUN_00412960
    err = 0x9E1
    if LicenseClearItemDelete == 0:
        ItemLotAfterUse(LicenseClearItemID, attr @0x23, out lot, out optType) fails → err = 0x9E2, no DB call     (D02 §1)
    if err == 0x9E1:
        r = p_Item_ClrWeaponTitle(WeaponItemKey, MobID, LicenseClearItemKey, LicenseClearItemDelete, optType, (i64) lot)
                                                                    # wrapper FUN_00461d40 returns nRet
        # (db-backup, 2006 CJC) no tItemMobList row → 1; one transaction: DELETE the licence (error → 2); delete flag 1 →
        # p_Item_Delete(clear item) (error → 3) else p_Item_SetOption(clear item, optType, lot) (error → 4); 0 = ok
        r 0: Log LicenseClearItemDelete == 0 ? 0x0459 NC_LOG_GAME_ITEM_USE_LOT { charNo, clear key, itemId, lot }
                                             : 0x045A NC_LOG_GAME_ITEM_USEALL { charNo, clear key, itemId }
        r 1 → 0x9E3, 2 → 0x9E4, 3 → 0x9E5, 4 → 0x9E6
        # any other value (wrapper −1 = call failed, SQL error) keeps 0x9E1 "ok" (original bug) D04-B10
    Send raw 0x5C08 NC_WT_LICENSE_CLR_ACK { hdr, u16 lockindex, echo_data, u64 WeaponItemKey, u16 MobID, u16 ErrorCode = err } (0x18)

0x5C09 NC_WT_MOB_KILLCOUNT_SET_REQ { hdr, u64 ItemKey @6, u16 MobID @0xE, u32 MobKillCount @0x10 }   (0x14)  @ FUN_00412bd0
    r = p_Item_SetMobList(ItemKey, MobID, nGrade = 0, MobKillCount)     # wrapper FUN_004619c0 returns nRet
    # (db-backup) upsert tItemMobList; nRet = @@ERROR. nGrade is always written as 0 (the grade is not stored by this path)
    Send raw 0x5C0A NC_WT_MOB_KILLCOUNT_SET_ACK { hdr, ItemKey, MobID, MobKillCount, u16 Error = r == 0 ? 0x9F0 : 0x9F1 } (0x16)

0x5C0B NC_WT_TITLE_SET_REQ { hdr, u64 ItemKey @6, u32 nTitleCharNo @0xE, char Title[21] @0x12 }      (0x27)  @ FUN_00412c90
    r = p_Item_SetTitle(ItemKey, nTitleType 0, nTitleCharNo, sTitle = Title (copied up to its NUL))     @ wrapper FUN_00461af0
    # (db-backup) upsert tItemTitle; nRet = @@ERROR. The copy has no length limit (relies on the zone's terminator).
    Send raw 0x5C0C NC_WT_TITLE_SET_ACK { hdr, u16 Error = r == 0 ? 0x9F2 : 0x9F3 }                                  (8)
```

Client: only 0x5C06 / 0x5C08 reach it, through the zone's 0x5C02 (Z08 §7.1: 0x9B9 / 0x9E1 success, the zone passes the other
codes through; the client shows text only for its own codes 0x9BB–0x9C0, so 0x9BA and 0x9E2–0x9E6 are silent failures)
*(inferred from Z08's list)*.

### 4.2 Character titles

```pseudo
p_Char_SetTitle(nCharNo, u8 nType, u8 nElementNo, i64 nElementValue, OUT u8 nRet)               @ wrapper FUN_00459880
    # (db-backup, header copied from "Character Set shape" 2004.6 CJC) UPDATE tCharacterTitle (charNo, type, element) or
    # INSERT; nRet 1 = ok, 0 = error. The wrapper logs nRet ≠ 1 and returns nRet == 1.

SetCharTitles(charNo, n, CT_INFO list[n]) -> bool                                                @ FUN_0046d3e0
    for each CT_INFO {Type, ElementNo:6, ElementValue:2}: p_Char_SetTitle(charNo, Type, ElementNo, ElementValue)
        failure: log "ERROR - SetCharTitles's CPFsCharacter::fc_NC_CT_DB_SET_CMD …"; remember it, continue
    return no failure        # Ghidra shows void; the disassembly returns `failed == 0` (callers: §1.2 0x441A, D03 0x345B)

0x6005 NC_CT_DB_SET_CMD { hdr, CT_INFO Info @6 }                                         (8)      @ FUN_00412f50
    p_Char_SetTitle(charNo, Info.Type, Info.ElementNo, Info.ElementValue); failure logged
    "ERROR - CPFsCharacter::fc_NC_CT_DB_SET_CMD, nCharNo=%d, (%d,%d,%I64d), nRet=%d"; no answer

0x6008 NC_CT_SET_CURRENT_DB_CMD { hdr, u8 CurrentTitle @6, u8 CurrentTitleElement @7, u16 CurrentTitleMobID @8,
        CT_INFO UseTitle @0xA, CT_INFO UseAbleTitle @0xC }                                (0xE)    @ FUN_00413050
    SetCharTitleCurrent(charNo, CurrentTitle, CurrentTitleElement, CurrentTitleMobID)          @ FUN_0046d5c0
        # the current title is kept in three type-0 rows: p_Char_SetTitle(charNo, 0, 0, CurrentTitle),
        # (charNo, 0, 1, CurrentTitleElement), (charNo, 0, 2, CurrentTitleMobID)
        # returns 1 only if all three calls succeeded (results OR-ed; disassembly `neg / sbb / lea eax,[ecx+1]`);
        # failure → log "ERROR - fc_NC_CT_SET_CURRENT_DB_CMD: m_DBFChar.SetCharTitleCurrent"; never reported to the zone
    for t in (UseTitle, UseAbleTitle): if 0 < t.Type < 0x80:
        SetCharTitle(charNo, t) = p_Char_SetTitle(charNo, t.Type, t.ElementNo, t.ElementValue)    @ FUN_0046d500
        failure logged "ERROR - fc_NC_CT_SET_CURRENT_DB_CMD: m_DBFChar.SetCharTitles, nCharNo=%d"; no answer
```

Loading titles (`p_Char_GetTitleAll`, 0x1004) and the zone's bulk save `0x400B NC_CHARSAVE_TITLE_REQ` (`CharSaveTitle`
FUN_00406370 → FUN_0046d560, element value written with `nElementNo 0xFF`) are D02 §4 / §6.

## 5. Character options (dept 28 CHAR_OPTION), requests from the WM

Two generations exist side by side. The **old** options are one binary blob per kind in `tCharacterOptions` (row made at
character creation, D02); the **improved** ones (2010, "Ko Dong Gyun") are rows in `tCharacterShortCut {nCharNo, nSlotNo,
nCodeType, nCodeNo, nValue}`, `tCharacterKeyMap {nCharNo, nFunctionNo, nExtendedKey, nASCIICode}` (defaults `tKeyMapInit`) and
`tCharacterGameOption {nCharNo, nOptionNo, nValue}` (defaults and active flag `tGameOptionInit`) *(db-backup; the usp_ procedures
exist only in w00_Character)*. Which generation the character uses is chosen at load time (D02 §4 step 20,
`usp_Character_chkKeyMap`). WM side (client relay, the `CParserCharDB` answers): W04.

### 5.1 Old options (`p_Char_GetOpt*` / `p_Char_SetOpt*`)

| Kind | GET REQ → ACK | SET CMD | Column (varbinary) | Data size | Handlers (GET / SET) | DB helpers (GET / SET) |
|---|---|---|---|---|---|---|
| short-cut data | 0x7017 → 0x7018 | 0x7025 | sShortCutData (1024) | 0x400 | FUN_00413b90 / FUN_00413f70 | FUN_0046d100 / FUN_0046d1e0 |
| short-cut size | 0x7019 → 0x701A | 0x7026 | sShortCutSize (24) | 0x18 | FUN_00413c30 / FUN_00413fb0 | FUN_0046d120 / FUN_0046d200 |
| video | 0x701B → 0x701C | 0x7027 | sVideo (60) | 0x3C | FUN_00413cb0 / FUN_00413ff0 | FUN_0046d140 / FUN_0046d220 |
| sound | 0x701D → 0x701E | 0x7028 | sSound (1) | 1 | FUN_00413d30 / FUN_00414030 | FUN_0046d160 / FUN_0046d240 |
| game | 0x701F → 0x7020 | 0x7029 | sGame (64) | 0x40 | FUN_00413db0 / FUN_00414070 | FUN_0046d180 / FUN_0046d260 |
| window positions | 0x7021 → 0x7022 | 0x702A | sWindowsPos (392) | 0x188 | FUN_00413e30 / FUN_004140b0 | FUN_0046d1a0 / FUN_0046d280 |
| key mapping | 0x7023 → 0x7024 | 0x702B | sKeyMapping (308) | 0x134 | FUN_00413ed0 / FUN_004140f0 | FUN_0046d1c0 / FUN_0046d2a0 |

```pseudo
0x70xx NC_CHAR_OPTION_DB_GET_<kind>_REQ { u16 WorldManagerHandle, u32 nCharNo @2 }        (6)
    bSuccess = p_Char_GetOpt<kind>(nCharNo, OUT u8 nRet, OUT varbinary sData)
    # (db-backup) SELECT sData, nRet = 1 FROM tCharacterOptions WHERE nCharNo AND column IS NOT NULL; else nRet 0.
    # the wrapper returns 1 only if the call succeeded and nRet == 1
    Send raw long frame { 0x00, u16 len = 3 + size + 2, u16 opcode = REQ + 1,
        PROTO_NC_CHAR_OPTION_DB_GET_<kind>_ACK { u16 WorldManagerHandle, u8 bSuccess, u8 Data[size] } }
    # bSuccess 0: Data is the uninitialised stack buffer (original bug) D04-B12. Every answer uses the 3-byte long length
    # form, even the 4-byte sound answer.

0x70xx NC_CHAR_OPTION_DB_SET_<kind>_CMD { u32 nCharNo @0, u8 Data[size] @4 }
    p_Char_SetOpt<kind>(nCharNo, Data)        # (db-backup) UPDATE tCharacterOptions SET column; no row → INSERT
    # result ignored (the handler returns 1 for the parser either way), no answer
```

The GET handlers are the same code the character load uses for the old format (D02 §4 step 20, FUN_00422020).

### 5.2 Improved options

```pseudo
0x704B NC_CHAR_OPTION_IMPROVE_DB_SET_SHORTCUTDATA_REQ { u32 nCharNo @0, u8 count @4, SHORT_CUT_DATA[count] @5
        { u8 nSlotNo, u16 nCodeNo, i32 nValue } (7 each) }                                          @ FUN_004224d0
    nError = 0x2100
    for each: usp_Character_setShortCut(nCharNo, nSlotNo, nCodeNo, nValue) fails → log, nError = 0x2101, continue
                                                                    # wrapper FUN_0045d920: ok = call ok and nRet == 0
        # (db-backup) no row → INSERT (nCodeType 1) else -2791; same code and value as stored → nRet -2722 (so an unchanged
        # slot counts as a failure here); else UPDATE
    Send 0x704C NC_CHAR_OPTION_IMPROVE_DB_SET_SHORTCUTDATA_ACK { u16 nError, u32 nCharNo }                           (6)

0x704D NC_CHAR_OPTION_IMPROVE_DB_SET_KEYMAP_REQ { u32 nCharNo @0, u16 count @4, KEY_MAP_DATA[count] @6
        { u16 nFunctionNo, u8 nExtendKey, u8 nASCIICode } }                                         @ FUN_00422b80
    nError = 0x2108; each usp_Character_setKeyMap(nCharNo, nFunctionNo, nExtendKey, nASCIICode) failure → 0x2109
        # (db-backup) UPDATE (error → -2793) else INSERT (error → -2792), in a transaction
    Send 0x704E NC_CHAR_OPTION_IMPROVE_DB_SET_KEYMAP_ACK { u16 nError, u32 nCharNo }                                 (6)
    # nCharNo is never written (stack garbage; checked in the disassembly: no store to the packet's +2). The WM
    # (FUN_0040af00) looks the client up by that number, so the client normally gets no 0x703A answer (original bug) D04-B13

0x704F NC_CHAR_OPTION_IMPROVE_DB_SET_GAMEOPTION_REQ { u32 nCharNo @0, u16 count @4, GAME_OPTION_DATA[count] @6
        { u16 nOptionNo, u8 nValue } (3 each) }                                                     @ FUN_004231a0
    nError = 0x2118; each usp_Character_setGameOption(nCharNo, nOptionNo, nValue) failure → 0x2119
        # (db-backup) UPDATE else INSERT; error → -2792
    Send 0x7050 NC_CHAR_OPTION_IMPROVE_DB_SET_GAMEOPTION_ACK { u16 nError, u32 nCharNo }   # nCharNo unwritten too (D04-B13)

0x7057 NC_CHAR_OPTION_IMPROVE_DB_INIT_KEYMAP_REQ { u32 nCharNo }                         (4)      @ FUN_00422890
    usp_Character_initKeyMap(nCharNo) fails:                         # (db-backup) replace all rows by tKeyMapInit; -2723/-2724
        log; Send 0x7058 { u16 nError 0x2111, u32 nCharNo, u16 0 }                                                    (8)
    else:
        usp_Character_getKeyMap(nCharNo) fails: log unless nRet == −2721 (0xF55F); **no answer** (original bug) D04-B14
            # w00's procedure reports "no rows" as −2725, not −2721 (db-backup)
        rows (u16 nFunctionNo, u8 nExtendedKey, u8 nASCIICode) → KEY_MAP_DATA[n], at most 95 (more: logged "too many key map
            data 1", the rest dropped)
        Send 0x7058 NC_CHAR_OPTION_IMPROVE_DB_INIT_KEYMAP_ACK { u16 nError 0x2110, u32 nCharNo, u16 n, KEY_MAP_DATA[n] } (8 + 4n)

0x7059 NC_CHAR_OPTION_IMPROVE_DB_INIT_GAMEOPTION_REQ { u32 nCharNo }                     (4)      @ FUN_00422f10
    usp_Character_setGameOptionInit(nCharNo) fails (# (db-backup) DELETE the character's rows) →
        log; Send 0x705A { u16 0x2121, u32 nCharNo, u16 0 }                                                           (8)
    else usp_Character_getGameOption(nCharNo) fails: log unless nRet == −2721; no answer (D04-B14)
        # (db-backup) every active tGameOptionInit option with the character's value or the default
    rows (u16 nOptionNo, u8 nValue) → GAME_OPTION_DATA[n] (stops when 8 + 3n > 8000, logged "too many short cut data")
    Send 0x705A NC_CHAR_OPTION_IMPROVE_DB_INIT_GAMEOPTION_ACK { u16 nError 0x2120, u32 nCharNo, u16 n, GAME_OPTION_DATA[n] }
```

## 6. Guilds (dept 29 GUILD), requests from the WM

Tables *(db-backup)*: `tGuild {nNo identity, sName nvarchar(18), sPassword nvarchar(9), nMaxMembers, nMoney, nType, nGrade,
nFame, nStoneLevel, nExp, dCreateDate, dWarRequestDate, dWarStartDate, dWarEndDate, nWarEnemy, nWarWinCount, nWarLoseCount,
nWarDrawCount, nDismissStatus, dDismissDate, dNotifyDate, sNotifyCharID, sNotify nvarchar(512), sIntro nvarchar(128), nToken…}`,
`tGuildMember {nNo, nCharNo, nGrade, nFlags, nExpRatio, sIntro nvarchar(64), dJoinDate}` (grade 0 = master; a replaced master
gets grade 6), `tLog_GuildMasterChange {nGuildNo, nOldGuildMaster, nNewGuildMaster, dDate}`, `tGuildHistory {nGuildID,
nCharNo, sID, dDate, nAction}` (private-server reconstruction, see §6.5). The WM (W03) keeps the guilds in memory and sends
these requests; all answers go back to it, and the WM turns them into client packets (W03 cross-checks the client texts: the
guild result codes 0x0C41… have no entry in the client error-code table).

Common codes: **0xC41 ok** in every guild answer. A handler whose `*this` (DB connection object) is NULL logs
"…, Error=12736" (0x31C0) and sends **no** answer (0x7458, 0x745A, 0x7469, 0x746B, 0x746F, 0x7471; inferred: never true
once the server runs).

### 6.1 Loading guilds

```pseudo
0x7452 NC_GUILD_DB_REQ { u16 hWMChar, u32 nNo @2 }                                       (6)      @ FUN_00437e50
    ack = PROTO_NC_GUILD_DB_ACK (0x443): only the name fields are zeroed first (GuildDbAck_Init FUN_004367c0: sName,
          sWarEnemyName, sNotifyCharID, GuildServer.sPassword)
    row = p_Guild_Get(nNo)                    # wrapper FUN_00453640; (db-backup) SELECT the tGuild columns listed above
    no row: Error = 0xC42, log "ERROR - CPFsCharacter::fc_NC_GUILD_DB_REQ, GuildNo=%d"
    row:    Error = 0xC41; GuildClient = { sName (16), nMoney, nType, nGrade, nFame, nStoneLevel, nExp,
                dCreateDate / dWarRequestDate / dWarStartDate / dWarEndDate / dDismissDate = mktime(local time of the DB value),
                nMaxMembers, nWarWinCount, nWarLoseCount, nWarDrawCount, nDismissStatus, sIntro, sNotify (strcpy) }
            GuildServer = { nNo = request nNo, sPassword (12), dCreateDate }
    # never written: GuildClient.nNo, every tm_* copy, nNumMembers, nWarStatus, nWarEnemy, nWarEnemyGrade, MyScore,
    # EnemyScore, dNotifyDate (uninitialised stack); sWarEnemyName / sNotifyCharID stay zero although p_Guild_Get read
    # nWarEnemy, dNotifyDate and sNotifyCharID (original bug) D04-B15 — the WM gets them from 0x7456 at start-up (inferred)
    Send raw long frame 0x7453 NC_GUILD_DB_ACK { u16 hWMChar, u16 Error, GUILD_CLIENT GuildClient, GUILD_SERVER GuildServer } (0x443)

0x7456 NC_GUILD_DB_ALL_REQ {}                                                                     @ FUN_004332e0
    rows = p_Guild_GetAll()                   # wrapper FUN_004537e0 (db-backup: every tGuild row, same columns + nNo)
    call failed: log (the message buffer is never filled); Send 0x7457 { u16 Error 0xC43 } (5 bytes; PartMask and
        NumOfGuild uninitialised)
    per row: GUILD_DB (0x2F7) { nNo, sName (16), sPassword (12), nMaxMembers, nMoney, nType, nGrade, nFame, nStoneLevel, nExp,
        dCreateDate, dWarRequestDate, dWarStartDate, dWarEndDate (mktime), nWarEnemy, nWarWinCount, nWarLoseCount,
        nWarDrawCount, nDismissStatus, dDismissDate, sIntro, dNotifyDate, sNotifyCharID (20), sNotify } (GuildDb_Copy FUN_004143b0)
        when 5 + n·0x2F7 > 0x7FD and n > 1 (i.e. every 3 guilds): Send 0x7457 NC_GUILD_DB_ALL_ACK { u16 Error 0xC41,
            u8 PartMask, u16 NumOfGuild, GUILD_DB[n] }; PartMask bit 0 = first part, bit 1 = last part; a failed send stops
    Send the rest with PartMask |= 2 (an empty last part when the count is a multiple of 3)

0x7454 NC_GUILD_DB_MEMBER_REQ { u32 nNo }                                                (4)      @ FUN_00432d90
    rows = p_Guild_Member_GetAll(nNo)         # (db-backup) G.nCharNo, dJoinDate, nGrade, nFlags, nExpRatio, sIntro, C.sID,
                                              # S.nClass, C.nLevel, C.sLoginZone, C.dLastLoginDate (deleted characters skipped)
    call failed: Send 0x7455 { nNo, u16 Error 0xC44 } (9 bytes; PartMask / NumOfMember uninitialised)
    per row: GUILD_MEMEBER_INFO (0xEA) = GUILD_MEMBER_CLIENT { sName = sID (20), nGrade, nFlags, nExpRatio, sIntro (strcpy),
             dLogonInfo = PROTO_FRIEND_DATE-style bits of dLastLoginDate (as 0x5415), nClassID, nLevel, bIsParty 0, sMap (12) }
           + GUILD_MEMBER_SERVER { nMemberCharNo, dJoinDate = mktime, dCanLeaveTime 0, dCanBanishTime 0,
             tm_dJoinDate = localtime(dJoinDate); tm_dCanLeaveTime / tm_dCanBanishTime not written }   (Copy FUN_00405610)
        every 9 members (9 + n·0xEA > 0x7FD): Send 0x7455 NC_GUILD_DB_MEMBER_ACK { nNo, u16 Error 0xC41, u8 PartMask,
            u16 NumOfMember, members[n] }; the last part gets PartMask |= 2
```

### 6.2 Creating, deleting, dismissing

```pseudo
0x7458 NC_GUILD_DB_MAKE_REQ { u16 hWMChar, u32 nCharNo @2, Name5 sCharID @6, PROTO_NC_GUILD_MAKE_REQ Make @0x1A
        { Name4 Name, Name3 Password @0x2A, u8 Type @0x36 } }                              (0x37)   @ FUN_00438440
    r = p_Guild_Make2(sName = Name (18-char bind), sPassword = first 11 bytes of Password (9-char bind), nMaxMembers 100,
                      nType = Type, nMakerCharNo = nCharNo, nMakerPay 1 000 000, nMakerNeedItemID 0xFFFF,
                      OUT nNo, OUT nRemainCharMoney)                 # wrapper FUN_00453860: ok = call ok and nNo > 0
    # (db-backup, 2006.12 CJC) −1 name exists, −2 need item missing (only when ≠ 65535), −3 maker already in a guild,
    # in one transaction: p_Char_MoneySub(maker, pay) else −4, p_Char_MoneyGet → nRemainCharMoney, INSERT tGuild
    # (−5 check is dead: it tests @@ERROR of the SET that follows the INSERT), p_Guild_Member_Join(nNo, maker, grade 0)
    # else −6, usp_GuildAcademy_setAcademy(nNo, maker, 50) else nNo = its error; nNo = new guild number
    fail: Error = −1 → 0xC99, −2 → 0xC9A, −3 → 0xC9B, −4 → 0xC9C, −5 → 0xC9D, −6 → 0xC9E, else (0, academy errors,
          call failure) 0xC98; log "ERROR - …fc_NC_GUILD_DB_MAKE_REQ, Error=%d nRet=%d"
    ok:   p_Guild_Get(nNo) → dCreateDate (mktime; failure logged, the date stays 0)
          Log 0x048C NC_LOG_GAME_GUILD_CREATE { nCharNo, nNo, u64 pay 1 000 000, u64 nRemainCharMoney, Name4 Name }   (0x28)
          usp_Guild_setHistory(nNo, nCharNo, sCharID, nAction 0)                                    (§6.5)
          usp_GuildAcademy_setHistory(nNo, nCharNo, sCharID, nAction 100)                          (§9)
    Send raw 0x7459 NC_GUILD_DB_MAKE_ACK { hWMChar, nCharNo, Make (29 bytes, FUN_00414700), i32 dCreateDate, u32 nNo,
        u16 Error }                                                                                                  (0x2D)
    # on failure dCreateDate and nNo are uninitialised

0x745A NC_GUILD_DB_DELETE_REQ { u32 nNo, Name4 sGuildName @4 }                           (0x14)   @ FUN_00414740
    ok = p_Guild_Delete(nNo)       # (db-backup) DELETE tGuild row only (members / academy rows are not touched here);
                                   # nRet = @@ROWCOUNT; wrapper FUN_004539a0 ok = nRet == 1
    ok: Log 0x048D NC_LOG_GAME_GUILD_DELETE { nNo, sGuildName }; Error 0xC41   else Error 0xC82 (logged)
    Send raw 0x745B NC_GUILD_DB_DELETE_ACK { u32 nNo, u16 Error }                                                    (6)

0x745C NC_GUILD_DB_DISMISS_REQ { u16 hWMChar, u32 nNo @2, u8 nDismissStatus @6, i32 dDismissDate @7 }  (0xB)  @ FUN_00414900
    p_Guild_SetDismiss(nNo, nDismissStatus, TIMESTAMP(dDismissDate) (TimeT_ToTimestamp FUN_00414340))   @ wrapper FUN_00453c00
    # (db-backup) UPDATE nDismissStatus, dDismissDate; nRet 1 = ok
    Send raw 0x745D NC_GUILD_DB_DISMISS_ACK { hWMChar, nNo, nDismissStatus, dDismissDate, u16 Error 0xC41 / 0xD07 } (0xD)

0x74EE NC_GUILD_DB_DELETE_CANCEL_REQ { u32 nNo, u16 hTool @4 }                            (6)      @ FUN_00415150
    # from the operator tool (W01 OPTool relay)
    p_Guild_SetDismiss(nNo, 0, now)
    Send raw 0x74EF NC_GUILD_DB_DELETE_CANCEL_ACK { u16 nError = ok ? 0x1E48 : 0x1E4C, u32 nNo, u16 hTool }          (8)
```

### 6.3 Money, notice, introduction, war, members

```pseudo
0x745E NC_GUILD_DB_MONEY_ADD_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, u64 nMoneyAdd }    (0x12)   @ FUN_00414a20
    ok = p_Guild_MoneyAdd(nNo, nCharNo, nMoneyAdd, OUT nMemberMoney, OUT nTotalMoney)       # wrapper FUN_00453a20: nRet == 1
    # (db-backup, 2006 CJC) member money < add → 0; in one transaction p_Char_MoneySub(member), p_Char_MoneyGet, guild
    # nMoney += add, read the total; any failure → rollback, 0
    Send raw 0x745F NC_GUILD_DB_MONEY_ADD_ACK { hWMChar, nNo, nCharNo, nMoneyAdd, u64 nMemberMoney, u64 nTotalMoney,
        u16 Error = ok ? 0xC41 : 0xC83 }                                                                             (0x24)
    # on failure the two money fields carry whatever the procedure left in its OUT parameters

0x7460 NC_GUILD_DB_MONEY_SUB_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, u64 nMoneySub }    (0x12)   @ FUN_00414b80
    ok = p_Guild_MoneySub(…)        # wrapper FUN_00453b10: nRet == 0 (this procedure is the 2007 "Lunar" rewrite: 0 = ok,
    # 1 guild read, 2 not enough guild money, 3 guild update, 4 member p_Char_MoneyAdd, 5/6 re-reads; one transaction)
    Send raw 0x7461 NC_GUILD_DB_MONEY_SUB_ACK { …same…, u16 Error = ok ? 0xC41 : 0xC84 }                            (0x24)

0x7462 NC_GUILD_DB_NOTIFY_REQ { u16 hWMChar, u32 nNo, Name5 sNotifyCharID @6, u16 nNotifyLength @0x1A, sNotify @0x1C }
                                                                    @ FUN_00414ce0
    # the answer is built first: { u16 Error, hWMChar, nNo, i32 dNotifyDate = time(NULL), sNotifyCharID, nNotifyLength,
    #   sNotify = nNotifyLength bytes (_mbsnbcpy) }
    ok = p_Guild_SetNotify(nNo, sNotifyCharID (20-byte bind), sNotify (strcpy of the copy, 512-byte bind))   @ wrapper FUN_004545e0
    # (db-backup) UPDATE dNotifyDate = getdate(), sNotifyCharID, sNotify; nRet 1 = ok
    # nNotifyLength is not checked: > ~8150 overflows the 8 KB send buffer and > 512 the procedure buffer (stack)
    # (original bug) D04-B16
    Send 0x7463 NC_GUILD_DB_NOTIFY_ACK { u16 Error = ok ? 0xC41 : 0xC87, … }                                    (0x22 + len)

0x7464 NC_GUILD_DB_INTRO_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, u16 nIntroLength @0xA, sIntro @0xC } @ FUN_00414ee0
    ok = p_Guild_SetIntro(nNo, sIntro)   # strcpy up to the NUL, nIntroLength ignored (128-char bind; overflow as D04-B16)
    Send raw 0x7465 NC_GUILD_DB_INTRO_ACK { hWMChar, nNo, nCharNo, u16 Error = ok ? 0xC41 : 0xC87 }                 (0xC)

0x7466 NC_GUILD_DB_WAR_REQ { u16 hWMChar, u32 nNo, u32 nWarEnemy, i32 dWarRequestDate, i32 dWarStartDate, i32 dWarEndDate }
                                                                    (0x16)   @ FUN_00414ff0
    ok = p_Guild_SetWar(nNo, 3 × TIMESTAMP(date), nWarEnemy)    # (db-backup) UPDATE the four war columns; nRet 1 = ok
    Send raw 0x7467 NC_GUILD_DB_WAR_ACK { u16 Error = ok ? 0xC41 : 0xD27, PROTO_NC_GUILD_DB_WAR_REQ (echo) }         (0x18)

0x7468 NC_GUILD_DB_RESULT_WRITE_CMD { GUILD_DB_RESULT_WRITE Guild1, Guild2 } each { u32 nNo, u32 nFame, u32 nWin, u32 nLose,
        u32 nDraw }                                                (0x28)   @ FUN_00415780
    for g in (Guild1, Guild2):
        p_Guild_SetFame(g.nNo, g.nFame)                        # (db-backup) absolute value, not an increment
        p_Guild_SetWarResult(g.nNo, g.nWin, g.nLose, g.nDraw)  # absolute counters
        each failure logged "FAILED, fc_NC_GUILD_DB_RESULT_WRITE_CMD-…"; no answer

0x7469 NC_GUILD_DB_MEMBER_JOIN_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, Name5 sCharID @0xA, u8 nGrade @0x1E } (0x1F) @ FUN_00415270
    ok = p_Guild_Member_Join(nNo, nCharNo, nGrade)          # (db-backup) INSERT tGuildMember; nRet 1 = ok
    ok: usp_Guild_setHistory(nNo, nCharNo, sCharID, nAction 1)
    Send raw 0x746A NC_GUILD_DB_MEMBER_JOIN_ACK { hWMChar, nNo, nCharNo, nGrade, u16 Error = ok ? 0xC41 : 0xC85 }   (0xD)

0x746B NC_GUILD_DB_MEMBER_LEAVE_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, Name5 sCharID @0xA }  (0x1E)  @ FUN_00415480
    ok = p_Guild_Member_Leave(nNo, nCharNo)                 # (db-backup) DELETE; nRet = @@ROWCOUNT
    ok: usp_Guild_setHistory(nNo, nCharNo, sCharID, nAction 2)
    Send raw 0x746C NC_GUILD_DB_MEMBER_LEAVE_ACK { hWMChar, nNo, nCharNo, u16 Error = ok ? 0xC41 : 0xC86 }          (0xC)

0x7471 NC_GUILD_DB_MEMBER_VANISH_REQ { u16 hWMChar, Name5 sCharID @2, u32 nNo @0x16, u32 nCharNo @0x1A }  (0x1E)  @ FUN_00436820
    ok = p_Guild_Member_Leave(nNo, nCharNo)
    ok: usp_Guild_setHistory(nNo, nCharNo, sCharID, nAction 3)
    Send raw 0x7472 NC_GUILD_DB_MEMBER_VANISH_ACK { hWMChar, sCharID, nNo, nCharNo, u16 Error = ok ? 0xC41 : 0xCF6 } (0x20)

0x746D NC_GUILD_DB_MEMBER_INTRO_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, u16 nMemberIntroLength @0xA, sMemberIntro @0xC }
                                                                    @ FUN_00415670
    ok = p_Guild_Member_SetIntro(nNo, nCharNo, sMemberIntro (strcpy, length field ignored; 64-char procedure parameter))
    Send raw 0x746E NC_GUILD_DB_MEMBER_INTRO_ACK { hWMChar, nNo, nCharNo, u16 Error = ok ? 0xC41 : 0xC88 }          (0xC)

0x746F NC_GUILD_DB_MEMBER_GRADE_REQ { u16 hWMChar, Name5 sCharID @2, u32 nNo @0x16, u32 nCharNo @0x1A, u8 MemberGrade @0x1E,
        u32 nSetCharNo @0x1F, u8 MemberGrade_Old @0x23 }                                    (0x24)   @ FUN_00436a40
    p_Guild_Member_SetGrade(nNo, nCharNo, MemberGrade, OUT nRet)    # wrapper ok = nRet == 0
    # (db-backup, 2006 CJC + kodong 2010–2011) −1311 no guild, −1313 no character; −1323 making a character master who used
    # the "reset relations" rename item (tCharacterChangeID bInit 1, bFlag 0); for grade 0: −1324 last master change
    # < 7 days ago (tLog_GuildMasterChange), the old master becomes grade 6; −1325 update error; the change is logged in
    # tLog_GuildMasterChange
    fail: Error = nRet == −1324 ? 0xC8A : 0xC89 (logged)
    ok:   Log 0x04A3 NC_LOG_GAME_GUILD_M_GRADE { nSetCharNo, nNo, nCharNo, MemberGrade_Old, MemberGrade }          (0xE)
          nAction by the new grade: 0 → 10, 1 → 11, 3 → 12, 4 → 13; other grades: no history, the answer is sent at once
          usp_Guild_setHistory(nNo, nCharNo, sCharID, nAction)
    Send 0x7470 NC_GUILD_DB_MEMBER_GRADE_ACK { hWMChar, sCharID, nNo, nCharNo, MemberGrade, u16 Error, u32 nSetCharNo } (0x25)
```

### 6.4 Guild tournament

Two generations. The **old** format stores every tournament value as a row `tGuildTournament {nGTNo, nType, nData,
nGuildNo}` *(db-backup)*: `nType` 0 = match type, 1000 + i = tree slot i's guild, 2000 + i = match-tree guild (second round
layout), 3000 + i = slot i's result, 4000 + i = `MatchTime[i]`. The **new** (2009, kodong) registration rows are
`tGuildTournamentRegist {nGTNo, nNo (guild), nCharNo, nMoney, nLimitLevel…, bChoice, bRefundNotice, nSeed}`. The WM (W03)
and, for the join, the zone (Z08 §8.2) send these requests; codes 0x0D40 ok / 0x0D41–0x0D45 failures (old), 0x1C40–0x1C51
(new). Z16 owns the tournament system itself.

```pseudo
GuildTournament_Set(nGTNo, list of {u16 nType, i32 nData})      # wrapper SQL_p_GuildTournament_Set FUN_00454cc0
    one p_GuildTournament_Set(nGTNo, nType, nData) per pair (upsert, nRet = @@ERROR); stops at the first failure → false

0x7485 NC_GUILD_TOURNAMENT_DB_GET_REQ { u32 nGTNo }                                      (4)      @ FUN_004159d0
    ack = PROTO_NC_GUILD_TOURNAMENT_DB_GET_ACK, zeroed (0xCC), Error 0xD40
    rows = p_GuildTournament_GetLastMatch()   # (db-backup) nGTNo, nType, nData of the highest nGTNo, ORDER BY nType
    failed: Error 0xD41, log "ERROR - fc_NC_GUILD_TOURNAMENT_DB_GET_REQ, nGTNo=%d, nRet=%d"
    else: ack.nGTNo = the stored tournament's number (not the request's)
          per row (type, data), rows ordered by nType so the type-0 row comes first:
                                0 → nMatchType = data
                                nMatchType < 2: 1000…1999 → TournamentTree[type−1000].nGuildNo; 2000…3999 dropped
                                    (so the nResult values 0x7487 stores as 3000+i are never read back in this mode)
                                nMatchType ≥ 2: 1…1999 dropped; 2000…2999 → TournamentTree[type−2000].nGuildNo, 3000…3999 →
                                                TournamentTree[type−3000].nResult
                                ≥ 4000 → MatchTime[type−4000]
          # 2000+i rows are written only by 0x7497 SET_MATCH (first 16 slots); who decides the second-round layout is Z16 / W03's
          # no index bound: a stored type ≥ 1031 / 4009 … writes past the tree / MatchTime arrays (trusts the table)
          n = count of usp_GuildTournament_getRegistList(request nGTNo) rows (each row read as U32, I64, U8, U8 and dropped)
          ack.nGuildTournamentJoinCnt = n; nLastWinnerGuildNo stays 0
    Send 0x7486 NC_GUILD_TOURNAMENT_DB_GET_ACK { u16 Error, u32 nGTNo, u8 nMatchType, i32 MatchTime[9],
        GUILD_TOURNAMENT_LIST_DB TournamentTree[31] {u8 nResult, u32 nGuildNo}, u32 nLastWinnerGuildNo, u16 nGuildTournamentJoinCnt } (0xCC)

0x7487 NC_GUILD_TOURNAMENT_DB_SET_REQ { u16, u32 nGTNo @2, u8 nMatchType @6, TournamentTree[31] @7 }   (0xA2)   @ FUN_00415fe0
    GuildTournament_Set(nGTNo, (0, nMatchType), (1000+i, tree[i].nGuildNo), (3000+i, tree[i].nResult) for i < 31)  # 63 rows
    Send 0x7488 NC_GUILD_TOURNAMENT_DB_SET_ACK { u16 Error 0xD40 / 0xD42, u32 nGTNo }                                 (6)

0x7489 NC_GUILD_TOURNAMENT_DB_JOIN_REQ { u16 hWMChar, u32 nGTNo, u16 nTeamPosition, u32 nGuildNo }   (0xC)  @ FUN_004163b0
    GuildTournament_Set(nGTNo, (1000 + nTeamPosition, nGuildNo))
    Send raw 0x748A NC_GUILD_TOURNAMENT_DB_JOIN_ACK { echo, u16 Error 0xD40 / 0xD45 }                                 (0xE)

0x748B NC_GUILD_TOURNAMENT_DB_SET_TYPE_REQ { u32 nGTNo, u8 nMatchType @4, … }                     @ FUN_004164f0
    GuildTournament_Set(nGTNo, (0, nMatchType))
    Send 0x748C NC_GUILD_TOURNAMENT_DB_SET_TYPE_ACK { u16 Error 0xD40 / 0xD42, u32 nGTNo, u8 nMatchType, u8 }       (8)
    # the 8th byte (2017: nFinalSelectionGuildNum) is never written (original bug) D04-B19

0x748E NC_GUILD_TOURNAMENT_DB_SET_RESULT_REQ { u32 nGTNo, u16 nTeamPosition @4, u8 nResult @6, u32 nGuildNo @7 } (0xB) @ FUN_004161c0
    ok = usp_GuildTournament_setResult(nGTNo, 3000 + nTeamPosition, nResult, nGuildNo)
         # (db-backup) upsert (nData, nGuildNo); −1492 insert / −1493 update error
    ok: Log 0x04AE NC_LOG_GAME_GUILD_4_TOURNAMENT_RESULT { nGTNo, u32 nTeamPosition, nGuildNo, u32 nResult }        (0x10)
    Send 0x748F NC_GUILD_TOURNAMENT_DB_SET_RESULT_ACK { nGTNo, nTeamPosition, nResult, u16 Error 0xD40 / 0xD42 }     (9)

0x7497 NC_GUILD_TOURNAMENT_DB_SET_MATCH_REQ { u16, u32 nGTNo @2, TournamentTree[31] @6 }      (0xA1)   @ FUN_00415cf0
    GuildTournament_Set(nGTNo, (2000 + i, tree[i].nGuildNo) for i < 16 with nGuildNo ≠ 0)   # entries 16–30 ignored
    Send 0x7498 NC_GUILD_TOURNAMENT_DB_SET_MATCH_ACK { u16 Error 0xD40 / 0xD42, u32 nGTNo }                           (6)

0x7499 NC_GUILD_TOURNAMENT_DB_SET_MATCH_TIME_REQ { u16, u32 nGTNo @2, i32 MatchTime[9] @6 }   (0x2A)   @ FUN_00415e70
    # the handler's log string says fc_NC_GUILD_TOURNAMENT_DB_SET_MATCH_REQ (copy-paste)
    GuildTournament_Set(nGTNo, (4000 + i, MatchTime[i]) for i < 9)
    Send 0x749A NC_GUILD_TOURNAMENT_DB_SET_MATCH_TIME_ACK { u16 Error 0xD40 / 0xD42, u32 nGTNo }                      (6)

0x74E5 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_REQ { hdr, u16 lockindex @6, u16 hWMChar @8, u32 nCharNo @0xA, u32 nGTNo @0xE,
        u32 nGuildNo @0x12, u8 nMinLevel @0x16, u16 nMinMember @0x17, u64 nProposalMoney @0x19 }      (0x21)  @ FUN_00408180
    # from the zone (Z08 §8.2); the zone has locked the proposal money and applies it on 0x1C40
    r = usp_GuildTournament_setRegist(nGTNo, nGuildNo, nCharNo, nProposalMoney, nMinLevel, nMinMember, OUT nRet)
        # wrapper FUN_00454e40 binds in this order; ok = call ok and nRet == 0. (db-backup, header only: the w00 body is
        # truncated) −1411 / −1412 / −1413 invalid tournament / guild / character, −1421 guild already registered,
        # −1422 level / member requirement, −1423 not enough money, −1492 insert error
    Error = ok ? 0x1C40 : by nRet: −1421 → 0x1C46, −1422 → 0x1C45, −1423 → 0x1C44, −1424 → 0x1C47, else 0x1C41 (logged)
    Send 0x74E6 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_ACK { hdr, lockindex, u16 Error, hWMChar, nCharNo, nGTNo, nGuildNo,
        nMinLevel, nMinMember, nProposalMoney }                                                                       (0x23)

0x74EB NC_GUILD_TOURNAMENT_DB_JOIN_LIST_REQ { u16 hWMChar, u32 nGTNo }                    (6)      @ FUN_004083d0
    rows = usp_GuildTournament_getRegistList(nGTNo)      # failure: Error 0x1C49 (logged), the fetch loop still runs
    per row: only SHINE_GUILD_LIST_NEW.nGuildNo is written (row read as U32, I64, U8, U8); name, master, type, grade,
             member counts are left uninitialised for the WM to fill (inferred)
    every 169 entries (0xB + n·0x2E > 0x1E6A): Send 0x74EC NC_GUILD_TOURNAMENT_DB_JOIN_LIST_ACK { u16 Error 0x1C48, u8 PartMask,
        u16 hWMChar, u32 nGTNo, u16 nJoinGuildNum, SHINE_GUILD_LIST_NEW[n] }; the last part PartMask |= 2

0x74E7 NC_GUILD_TOURNAMENT_DB_FINAL_SELECTION_REQ { u32 nGTNo, u8 nMinLevel @4, u16 nMinMember @5 }  (7)  @ FUN_00408630
    usp_GuildTournament_setChoice(nGTNo, nMinLevel, nMinMember)    # failure → Error 0x1C51, continue
        # (db-backup) bChoice = 1 for the TOP 16 registered guilds (ORDER BY nSeed DESC) having ≥ nMinMember members of
        # level ≥ nMinLevel; −1493 on error
    usp_GuildTournament_getChoiceList(nGTNo)                       # (db-backup) nNo of the bChoice rows; failure → 0x1C51
    read up to 17 guild numbers (more: logged, stop)
    Send 0x74E8 NC_GUILD_TOURNAMENT_DB_FINAL_SELECTION_ACK { u16 Error 0x1C50 / 0x1C51, u32 nGTNo, u8 nFSGuildNum,
        u32 nFSGuildNo[n] }                                                                                           (7 + 4n)

0x74F6 NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_REQ { u32 nGTNo }                           (4)      @ FUN_00408890
    rows = usp_GuildTournament_getRegistList(nGTNo)  # read as U32 nGuildNo, U64 nRefundMoney, I32 bIsChoice, I32 bIsRefundNotice
    # failure is logged but answered with the success code 0xD50 as well (original bug) D04-B20
    every 389 entries (5 + n·0x14 > 0x1E6A): Send 0x74F7 NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_ACK { u16 Error 0xD50,
        u8 PartMask, u16 nEnterGuildNum, GT_EnterList[n] {nGuildNo, bIsChoice, bIsRefundNotice, nRefundMoney} }; last |= 2

0x74F9 NC_GUILD_TOURNAMENT_REFUND_NOTICE_DB_SET_REQ { u32 nGTNo, u32 nNo }               (8)      @ FUN_00408ae0
    usp_GuildTournament_setRefundNotice(nGTNo, nNo, OUT nRet)   # missing from every backup (inferred: sets bRefundNotice)
    failure logged; no answer
```

The four registration readers (0x7485, 0x74EB, 0x74F6 and the w00 procedure) disagree on `getRegistList`'s columns: the
2016 code expects four columns (guild, money, choice flag, refund flag; 0x74EB reads the flags as U8, 0x74F6 as I32), the
w00 procedure returns only `nNo` *(db-backup)*: the 2016 procedure was a different version.

```pseudo
0x74AA NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_REQ { u32 nGTNo, u32 OwnerGuildNum @4, i32 nItem @8,
        ITEM_OPT[nItem] @0xC (0x21 bytes each: u8 nType (GT_REWARD_TYPE), u32 nValue @1, u32 nMin @5, u32 nMax @9, … ) }
                                                                    @ FUN_004076a0
    ack = { u32 nGuildNo = OwnerGuildNum, u32 nAddMoney 0, nAddFame 0, nAddExp 0, nAddToken 0, u64 nAddMoneyDivision 0 }
    used = ItemStorage_GetUsedSlots(OwnerGuildNum, storage 4 (guild storage), max 36)            @ FUN_0046a500
           (p_Item_GetStorageListType; storage type > 16 → none)
    free = the first nItem slot numbers 0…35 not in `used`
    for each option:
        0 ID_ITEM: if a free slot is left: key = MakeItemKeyEx(itemId = (u16) nValue, 0xB, 0, g)   @ FUN_0044d240
                       # time-packed u64: seconds, counter DAT_006ef2dc, 0xB, year−2000/month/day/hour/minute
                   attr = GTReward_MakeItemAttr(option) (by ItemInfo class: lot / count from the option, class 4 adds
                          random-option entries from the option's tail)                                  @ FUN_00467c60
                   Item_Insert({key, owner = guild, storage 4, slot}, attr, 0) → Log 0x044F NC_LOG_GAME_ITEM_CREATE
                       { guild, …, cell = 4 << 10 | slot }; failure logged; no free slot: log "… item Create Fail, Inven full …"
        1 ID_GUILD_FAME: p_Guild_Get → p_Guild_SetFame(guild, fame + nValue); ack.nAddFame = nValue;
                   Log 0x04AC NC_LOG_GAME_GUILD_4_REWARD_FAME { guild, old, new }
        2 ID_GUILD_MONEY: p_Guild_Get → p_Guild_SetMoney(guild, money + nValue); ack.nAddMoney = nValue;
                   Log 0x04AB { guild, u64 old, u64 new }
                   # p_Guild_SetMoney (missing from the backups) gets the new total bound as SQL_C_ULONG: only the low
                   # 32 bits reach the DB (original bug) D04-B21
        3 ID_GUILD_EXP: p_Guild_Get → p_Guild_SetExp(guild, exp + nValue); ack.nAddExp = nValue;
                   Log 0x04AD { guild, u64 old exp, u64 new = the guild number (sign-extended) } (original bug) D04-B22
        4 ID_GUILD_TOKEN: usp_Guild_GetToken(guild) → usp_Guild_SetToken(guild, token + nValue); ack.nAddToken = nValue;
                   Log 0x04AF { guild, u64 old, u64 new }      # (db-backup, 2008 Lunar) tGuildToken upsert
        5 ID_GUILD_MONEY_DIVISION: total = usp_GuildTournament_getMoney(nGTNo) (db-backup: SUM(nMoney) of the
                   registrations); if total > 0 and nValue ≠ 0: share = (i64)(total × (min(nValue, 1000) / 1000.0))
                   (per mille, float); clamp to nMin / nMax when those are ≠ 0; p_Guild_Get → p_Guild_SetMoney(guild,
                   money + share) (same 32-bit bind); ack.nAddMoneyDivision = share; Log 0x04B0 { guild, old, new }
        other types: skipped. Each DB failure is logged ("… ID_GUILD_FAME 1/2 …") and only skips that option.
    Send 0x74AB NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_ACK { ack }                                                      (0x1C)
```

### 6.5 Rename, type, tokens, history

```pseudo
0x74B2 NC_GUILD_DB_RENAME_REQ { u16 hWMChar, u32 nGuildNo, Name4 sGuildName }          (0x16)   @ FUN_0041f7e0
    p_Guild_setName(nGuildNo, sGuildName, OUT nRet)    # ok = nRet == 0. (db-backup, 2008.9 kodong, for the guild-rename
    # item) −1311 no number, −1312 empty name, −1321 no guild, −1322 name taken, −1393 update error
    Send 0x74B3 NC_GUILD_DB_RENAME_ACK { hWMChar, nGuildNo, sGuildName, u16 err = ok ? 0x1A40 : 0x1A4F }            (0x18)
    # the client's rename texts are 0x1A42–0x1A4E (zone / WM checks); 0x1A4F has no client text

0x74BA NC_GUILD_DB_RETYPE_REQ { u16 hWMChar, u32 nGuildNo, u8 nType }                    (7)      @ FUN_0041f980
    p_Guild_SetType(nGuildNo, nType)                   # (db-backup) UPDATE nType; nRet 1 = ok
    Send 0x74BB NC_GUILD_DB_RETYPE_ACK { hWMChar, nGuildNo, nType, u16 err = ok ? 0x1A58 : 0x1A65 }                  (9)

0x74BC NC_GUILD_DB_TOKEN_ALL_REQ {}                                                               @ FUN_004144e0
    rows = usp_Guild_GetTokenAll()                     # (db-backup) nNo, nToken FROM tGuildToken
    failed: Send 0x74BD { u16 Error 0xC43 } (5; PartMask / count uninitialised)
    every 171 guilds (5 + n·12 > 0x7FD): Send 0x74BD NC_GUILD_DB_TOKEN_ALL_ACK { u16 Error 0xC41, u8 PartMask,
        u16 NumOfGuild, GUILD_TOKEN_DB[n] {u32 nNo, u64 nToken} }; last part |= 2

usp_Guild_setHistory(nGuildID, nCharNo, sID (40-byte bind of a 20-byte name), u8 nAction, OUT nRet)   @ wrapper FUN_004570f0
    # nAction = GUILD_HISTORY_MSG_TYPE (pdb2017): 0 created, 1 join, 2 leave, 3 banished ("vanish"), 10–13 new grade
    # master / sub-master / elder / guard; 100–103 the academy equivalents (§9). Procedure only in Fixes/ (2018
    # private-server reconstruction: INSERT tGuildHistory, −2 on error). Failures are only logged.

0x74FF NC_GUILD_HISTORY_DB_LIST_REQ { u16 hWMChar, u32 nGuildNo }                         (6)      @ FUN_00435630
    no WM link (*(this+4) == 0): log Error 12737 (0x31C1); no DB object: log 0x31C0; no answer in both cases
    usp_Guild_getHistoryList(nGuildNo, nAmount 30, OUT nRet)   # (Fixes/ only) TOP (30) sID, nAction, dDate
    failed: Send 0x7500 { u16 Error 0x3181, hWMChar, 0, 0, 0 }                                                         (0xA)
    rows i = 0…: GUILD_HISTORY { u32 nHistoryNumber = 30 − i, GUILD_HISTORY_DATE {u16 year, u8 month, u8 day} of dDate,
        Name5 sCharName = sID, u32 nMessageType = nAction }
    Send 0x7500 NC_GUILD_HISTORY_DB_LIST_ACK { u16 Error 0x3180, hWMChar, u16 TotalHistoryCount = n, u16 HistoryCount = n,
        u16 HistoryIndex 0, GUILD_HISTORY[n] }                                                                     (0xA + 0x20n)
```

### 6.6 Guild emblems (private-server procedures)

`usp_GuildEmblem_GetInfo`, `_GetInfoAll`, `_SetInfo` exist only as private-server reconstructions (w00 and `Fixes/Guild
Emblem`, `_SetInfo` has a parameter named `@nUnk`); the columns below are what the 2016 code reads, not the procedures.

```pseudo
0x7503 NC_GUILD_EMBLEM_INFO_DB_REQ {}                                                             @ FUN_0042f3a0
    usp_GuildEmblem_GetInfoAll() == 1: per row (U32 nGuildNo, U8 nPTFileNo, U8 nPTIconNo, Time create, Time delete,
        U8 EmblemSqlState) → GUILD_EMBLEM_INFO_DB (0xF) { nGuildNo, EmblemInfo, EmblemCreateDate, EmblemDeleteDate =
        mktime or 0 when mktime fails, EmblemSqlState }
        every 136 entries (3 + n·0xF > 0x7FD): Send 0x7504 NC_GUILD_EMBLEM_INFO_DB_ACK { u8 PartMask, u16 nNumOfEmblem, … }
    Send the last part with PartMask = 2 (assigned, not or-ed: a single-part answer has no "first" bit; also sent when
    the call failed, with 0 entries)

0x7507 NC_GUILD_EMBLEM_SAVE_DB_REQ { u32 nCharNo, u32 nGuildNo @4, GUILD_EMBLEM_INFO {u8 nPTFileNo @8, u8 nPTIconNo @9},
        i32 EmblemCreateDate @0xA }                                                        (0xE)    @ FUN_0042f730
    usp_GuildEmblem_SetInfo(nGuildNo, nPTFileNo, nPTIconNo, create = TIMESTAMP(localtime(EmblemCreateDate)),
        delete = 1900-01-01, state 0 …)
    ok: Send 0x7508 NC_GUILD_EMBLEM_SAVE_DB_ACK { nCharNo, EmblemInfo, EmblemCreateDate }                             (0xA)
    failure: logged, **no answer** (inferred: the WM's save stays pending)

0x750D NC_GUILD_EMBLEM_STATE_DB_REQ { u32 nGuildNo, i32 EmblemDeleteDate @4, u8 EmblemState @8 }   (9)   @ FUN_0042f970
    usp_GuildEmblem_GetInfo(nGuildNo) → file, icon (0xFF if no row), create, delete, state
    usp_GuildEmblem_SetInfo(nGuildNo, file, icon, create, delete = EmblemDeleteDate ? TIMESTAMP(localtime(it)) : 1900-01-01,
        state = EmblemState 0 or 3 → 0, 0xFF or 4 → 0xFF, 1 → 1, 2 → 2, other → an uninitialised stack byte
        (original bug) D04-B11)
    # no GetInfo row: SetInfo still runs with file / icon 0xFF and an all-zero create TIMESTAMP (year 0)
    failure: logged, **no answer** (as 0x7507)
    ok: Send 0x750E NC_GUILD_EMBLEM_STATE_DB_ACK { nGuildNo, EmblemDeleteDate, EmblemState } (echo)                  (9)
```

## 7. Prison (dept 31, `NC_DATA_PRISON_*`), requests from the WM

Tables *(db-backup, "lenasoft 2006")*: `tCharacter.nPrisonMin` plus the login position, `tPrison {nCharID, nMinute, sReason,
sGmID, sRemark, dPrisonDate}` (one row per imprisonment or change). Imprisoning moves the login position to `EldPri`
(896, 1122); release (0 minutes) moves it to `Rou` (5963, 9793) — the procedures hard-code the map, the comment says they
must be changed together with MapInfo. WM side: W04 (`NC_PRISON_*` client packets); the zone counts the minutes down (Z09).

```pseudo
0x7C0B NC_DATA_PRISON_ADD_GM_REQ { u16 nGmHandler, Name256Byte sGmUserID @2, u32 nImprisonRegNum @0x102,
        Name5 sImprison @0x106, u16 nMinute @0x11A, char sReason[16] @0x11C, char sRemark[64] @0x12C }   (0x16C)  @ FUN_00436df0
    rec = { sGmUserID (Name256 copy FUN_00402a10), sImprison, nMinute, sReason, sRemark, nImprisonRegNum, OUT err }
    nImprisonRegNum == 0 (by name, offline target):
        ok = p_Prison_Add2(sGmUserID, sImprison, nMinute, sReason, sRemark, OUT err)
        # (db-backup) err 1 no character of that name, 2 already in prison; else one transaction: nPrisonMin, login
        # position EldPri, INSERT tPrison
    else: ok = p_Prison_Add(…, nImprisonRegNum, OUT err)   # (db-backup) no checks; same update + insert by number
    err code = !ok → 0xD87, err 1 → 0xD81, err 2 → 0xD82, else 0xD80
    Send raw 0x7C0C NC_DATA_PRISON_ADD_GM_ACK { u16 err, nGmHandler, nImprisonRegNum, sImprison, nMinute, sReason, sRemark } (0x6E)
    # client (On NC_PRISON_ADD_GM_ACK FUN_004aeba0, via the WM): 0xD80 ok, 0xD81 "Character ID does not exist.",
    # 0xD82 "The character is already in prison.", 0xD87 "Imprisonment request has failed." (0xD83–0xD86, 0xD88 are WM checks)

0x7C10 NC_DATA_PRISON_ALTER_GM_REQ { same layout as 0x7C0B }                            (0x16C)  @ FUN_00437010
    nImprisonRegNum == 0: p_Prison_Alter2(by name)   # (db-backup) err 1 no character, 2 not in prison
    else:                 p_Prison_Alter(by number) # no checks
        # both: nMinute 0 → release (nPrisonMin 0, login Rou 5963/9793) else EldPri; INSERT tPrison (history row)
    err code = !ok → 0xDA7, 1 → 0xDA1, 2 → 0xDA2, else 0xDA0
    Send raw 0x7C11 NC_DATA_PRISON_ALTER_GM_ACK { u16 err, nGmHandler, nImprisonRegNum, sImprison, nMinute, sReason, sRemark } (0x6E)
    # client (FUN_004aee00): 0xDA1 "Character ID does not exist.", 0xDA2 "Not in prison.", other failures "Imprisonment
    # request has failed."

0x7C0D NC_DATA_PRISON_UPDATE_MIN_CMD { u32 nImprisonRegNum, u16 nMinute }                (6)      @ FUN_00416650
    p_Prison_UpdateCharPrisonMin(nImprisonRegNum, nMinute)
    # (db-backup) nMinute 0 → nPrisonMin 0 and login Rou (5963, 9793); else nPrisonMin = nMinute, sLoginZone 'EldPri'
    OutputDebugString("p_Prison_UpdateCharPrisonMin OK/FAIL"); no answer

0x7C0E NC_DATA_PRISON_GET_REQ { u16 nCharHandle, u32 nCharRegNum }                      (6)      @ FUN_004166d0
    r = p_Prison_Get(nCharRegNum)   # (db-backup) TOP 1 sReason, sRemark ORDER BY dPrisonDate DESC; wrapper: 1 row,
                                    # −1 no row, 0 call failed
    r 1:  err 0xDB0, the stored reason / remark
    r −1: err 0xDB0, sReason "Be Nonexistent Reason", sRemark "Be Nonexistent Remark"
    r 0:  err 0xDB2, reason / remark uninitialised
    Send raw 0x7C0F NC_DATA_PRISON_GET_ACK { u16 nCharHandle, u16 err, char sReason[16], char sRemark[64] }           (0x54)
```

## 8. Holy promise (master / apprentice, "Monarch"; dept 37)

Tables *(db-backup, 2008 CJC / 2009 "Luunar")*: `tHolyPromise {nCharNo (apprentice), nUpCharNo (master, 0 = none), nFlags,
dRegDate, dRejoinableDate, dMemberAcceptableDate}`, `tHolyPromiseReward {nCharNo, nSeqNo, nType (1 credit, 2 withdrawal),
nMoney, nRemainMoney, nReceiptCharNo}` (credited by every cen purchase of an apprentice, D03 §1.5). Requests come from the WM
(W04) except the two cen-reward requests, which the zone sends (Z08 §9). Codes 0x1740 ok … 0x176E;
client texts from the error table (the WM / zone pass the code on; W04 / Z08 confirm which reach the client).

`PROTO_HOLY_PROMISE_INFO_DB` (0x2A) = `{Name5 PromiseCharID, PROTO_HOLY_PROMISE_DATE LogonInfo, u8 Level, u8 Flags,
u32 PromiseCharNo, DATE RegDate, DATE RejoinableDate, DATE MemberAcceptableDate}`; a DATE is the 32-bit
`{login:1, year:11, month:4, day:5, hour:5}` (the year field holds the full year mod 2048; built from local time).

```pseudo
0x941E NC_HOLY_PROMISE_DB_SET_UP_REQ { INFO_DB ReqInfo @0, INFO_DB UpInfo @0x2A }        (0x54)   @ FUN_0043adc0
    r = p_HolyPromise_Set(nMAXPROMISEMEMBER 20, ReqInfo.PromiseCharNo, UpInfo.PromiseCharNo, UpInfo.Flags)
                                                                    # wrapper FUN_004576e0 returns nRet
    # (db-backup) p_HolyPromise_CheckRing → 1 (ring or same character); master's member count ≥ 20 → 2; the apprentice
    # row exists with a master → 4; exists without → UPDATE (re-join) → 3; else INSERT → 0; other = SQL error
    r 0 → 0x1740, r 3 → 0x1751: UpInfo.RegDate = now (DATE, login bit kept)
    r 1 → 0x1741 (client table: "User is already logged on." — a text that does not fit, inferred mismatch)
    r 2 → 0x1742 "You've exceed the maximum capacity of members."   r 4 → 0x1749 "You've already registered a master."
    else → 0x1743 "An error has occurred while registering a Monarch relation." (logged)
    Send raw 0x941F NC_HOLY_PROMISE_DB_SET_UP_ACK { ReqInfo, UpInfo, u16 DBError }                                    (0x56)

0x9420 NC_HOLY_PROMISE_DB_DEL_UP_REQ { u32 nCharNo, u32 nUpCharNo, u8 nDelCmdType }       (9)      @ FUN_0041a440
    ok = p_HolyPromise_Del(nCharNo)   # (db-backup) row exists → nUpCharNo 0, nFlags 0, dRegDate now; no row → ok
    Send raw 0x9421 NC_HOLY_PROMISE_DB_DEL_UP_ACK { echo, u16 DBError = ok ? 0x1740 : 0x1744 }                        (0xB)

0x9422 NC_HOLY_PROMISE_DB_DEL_DOWN_REQ { u32 nCharNo, u32 nDownCharNo, Name5 DownCharID }  (0x1C)  @ FUN_00437240
    ok = p_HolyPromise_Del(nDownCharNo)        # the master releases an apprentice
    Send raw 0x9423 NC_HOLY_PROMISE_DB_DEL_DOWN_ACK { echo, u16 DBError = ok ? 0x1740 : 0x1744 }                      (0x1E)

0x9424 NC_HOLY_PROMISE_DB_DEL_CHAR_REQ { u32 nCharNo }                                   (4)      @ FUN_0041a4f0
    ok = p_HolyPromise_DelChar(nCharNo)        # (db-backup) DELETE every row whose master is nCharNo
    Send raw 0x9425 NC_HOLY_PROMISE_DB_DEL_CHAR_ACK { nCharNo, u16 DBError = ok ? 0x1740 : 0x1745 }                   (6)

0x9426 NC_HOLY_PROMISE_DB_GET_UP_REQ { u32 nCharNo }      → GetHolyPromiseUp(nCharNo)      @ FUN_00438b90 → FUN_004389b0
    rec = p_HolyPromise_Get(nCharNo)           # wrapper FUN_00457880
    # (db-backup) the master's nUpCharNo, nFlags, the three dates, sID, nLevel, dLastLoginDate (deleted master → '', 1, now);
    # no row: the wrapper fills nUpCharNo −1, flags 0 and dates from the current time
    call failed: DBError 0x1746 "Unable to retrieve the master list."
    else DBError 0x1740, UpMemberInfo = { PromiseCharNo = nUpCharNo, RegDate / RejoinableDate / MemberAcceptableDate,
         and if nUpCharNo ≠ −1: PromiseCharID = sID, LogonInfo (dLastLoginDate), Level, Flags }
    Send raw 0x9427 NC_HOLY_PROMISE_DB_GET_UP_ACK { u32 nCharNo, u16 DBError, INFO_DB UpMemberInfo }                  (0x30)
    # the same function sends this block during the character load (D02 §4 step 11)

0x9428 NC_HOLY_PROMISE_DB_GET_MEMBER_REQ { u32 nCharNo }  → GetHolyPromiseMember(nCharNo)  @ FUN_0041a8d0 → FUN_0041a570
    p_HolyPromise_GetMember(nCharNo, OUT n)    # wrapper FUN_00457a90; (db-backup) the apprentices (not deleted): nCharNo, nFlags, 3 dates, sID,
                                               # nLevel, dLastLoginDate
    call failed: DBError 0x1747 "Unable to retrieve the apprentice list."
    rows → INFO_DB[n]; every 192 entries (8 + n·0x2A > 0x1F96): Send 0x9429 NC_HOLY_PROMISE_DB_GET_MEMBER_ACK
        { u32 nCharNo, u16 DBError 0x1740, u8 nPart (bit 0 first, bit 1 last), u8 nMemberCount, INFO_DB[n] }

0x942C NC_HOLY_PROMISE_DB_SET_DATE_REQ { u32 nCharNo, DATE RejoinableDate, DATE MemberAcceptableDate }  (0xC)  @ FUN_0041ae00
    p_HolyPromise_SetDate(nCharNo, TIMESTAMP(Rejoinable: year, month, day, hour), TIMESTAMP(MemberAcceptable))
    # (db-backup) UPDATE the two dates, or INSERT a row without master
    Send raw 0x942D NC_HOLY_PROMISE_DB_SET_DATE_ACK { echo, u16 DBError = ok ? 0x1740 : 0x1752 }                      (0xE)

0x942A NC_HOLY_PROMISE_DB_REWARD_REQ { u32 nCharNo, u8 nClass @4, u8 nLevel @5 }          (6)      @ FUN_0041a900
    # the master's reward when an apprentice reaches a level; table HolyPromiseReward.shn (g_Server+0x209E58, record 0x46:
    # Level, Class (promotion class), ItemIndex[33], Lot @0x23, Upgrade @0x25, IO_Str/Con/Dex/Int/Men @0x26… (u32 each),
    # Res1–3), loaded by GameData_Load FUN_00401550 (an unknown ItemIndex only logs "ERROR - HOLY_PROMISE_REWARD Unknowned …")
    DBError = 0x1768; list = []
    if nClass < 28 and pc = g_PromotionClass[nClass] ≠ 0:
        for every row with Level == nLevel and Class == pc:
            itemId = ItemIndex → id (FUN_0044cda0); unknown → DBError 0x176B, stop
            key = MakeItemKeyEx(itemId, 0xB, 0, g)                                          @ FUN_0044d240
            attr = ItemAttr_Init(itemId) else DBError 0x176C, stop; ItemLot_Set(attr, Lot); upgrade = Upgrade (FUN_00467b00);
            random options from the non-zero IO_* columns (type 1 Str, 5 Con, 3 Dex, 2 Int, 4 Men) (FUN_00467bc0)
            Item_Insert({key, owner nCharNo, storage 2 (reward box), slot 0}, attr, useEmptySlot 1) fails →
                DBError 0x176D ("Failed to create a Monarch reward item."), stop
            list += {u16 itemId, u16 Lot}; Log 0x044F NC_LOG_GAME_ITEM_CREATE { nCharNo, key, …, cell = 2 << 10 | slot }
    # items created before a failure stay (no rollback); class / level without rows → 0x1768 with no items
    Send 0x942B NC_HOLY_PROMISE_DB_REWARD_ACK { nCharNo, nClass, nLevel, u16 DBError, u8 nNumOfItems, {u16 id, u16 lot}[n] } (9 + 4n)
    # client: 0x1768 "You've received a reward from your Monarch.", 0x176B "Unknown Monarch reward item.", 0x176C "Failed to
    # edit a Monarch reward item.", 0x176D "Failed to create a Monarch reward item."

0x943E NC_HOLY_PROMISE_DB_GET_CEN_REWARD_REQ { hdr }                                     (6)      @ FUN_0041aff0
    usp_HolyPromise_getRemainMoney(charNo, OUT nRet)    # wrapper ok = nRet == 0
    # (db-backup, 2009.4 Luunar) −2211 bad charNo; latest tHolyPromiseReward.nRemainMoney > 0 → SELECT it, 0;
    # = 0: SELECT 0 if the character is somebody's master, else −2224
    nError = ok ? 0x1C60 : nRet == −2224 ? 0x1C62 : 0x1C61 (logged); nMoney = the selected value (0 when no row)
    Send 0x943F NC_HOLY_PROMISE_DB_GET_CEN_REWARD_ACK { hdr, u16 nError, u64 nMoney }                                 (0x10)

0x9442 NC_HOLY_PROMISE_DB_WITHDRAW_CEN_REWARD_REQ { hdr }                                (6)      @ FUN_0041b190
    usp_HolyPromise_withDrawRemainMoney(charNo, OUT nRet)
    # (db-backup) one transaction: remain ≤ 0 → −2226; p_Char_MoneyAdd(char, remain) else −2227; INSERT a withdrawal row
    # (nType 2, nRemainMoney 0); then the withdrawn amount is selected
    nError = ok ? 0x1C68 : nRet == −2226 (0xF74E) ? 0x1C6A : nRet == −2225 ? 0x1C6B : 0x1C69 (logged); nMoney = selected value
    Send 0x9443 NC_HOLY_PROMISE_DB_WITHDRAW_CEN_REWARD_ACK { hdr, u16 nError, u64 nMoney }                            (0x10)
    # the zone adds nMoney to the player's cen only on 0x1C68 (Z08); the DB already credited tCharacter.nMoney

GetHolyPromiseRemainMoney(charNo)                                                                @ FUN_0041b340
    # character load only (D02 §4 step 11): same procedure, log unless nRet ∈ {0, −2224}
    Send raw 0x9444 NC_HOLY_PROMISE_DB_GET_REMAIN_MONEY_CMD { u32 nCharNo, u64 nMoney }                               (0xC)
```

## 9. Guild academy (dept 38 GUILD_ACADEMY), requests from the WM (0x986B from the zone)

Tables *(db-backup, kodong 2008–2010)*: `tGuildAcademy {nNo (= guild number), nMasterCharNo, nMaxMembers, nMoney, nPoint,
nRanking, dBuffEndTime, dNotifyDate, sNotify, sIntro, …}`, `tGuildAcademyMember {nNo, nCharNo, nJoinLevel, dJoinDate, nGrade,
sIntro, nChatBanTime}`, `tGuildAcademyRanking {dDate, nRanking, nGuildNo, sGuildName, nMasterNo, sMasterID, nPoint, nCount}`,
`tGuildAcademyReward {nNo, nLevel, nType (1 = cen; else the item option type), nData, nItemID}`, graduates. An academy is
created together with its guild (`usp_GuildAcademy_setAcademy` inside `p_Guild_Make2`, §6.2). Every `usp_GuildAcademy_*`
wrapper returns ok = call ok and `nRet == 0`; failures are logged with the handler's name. Handlers whose `*this` is NULL log
0x31C0 and do not answer (0x9814, 0x9819, 0x981D, 0x9827, 0x982F). WM side: W03.

### 9.1 Loading and ranking

```pseudo
0x9801 NC_GUILD_ACADEMY_START_DB_ALL_REQ {}                                                       @ FUN_00434030
    rows = usp_GuildAcademy_getGuildAcademyList()   # failure: Send 0x9802 { u16 Error 0x1791 } (5 bytes)
    per row → GUILD_ACADEMY_DB (0x2D0) { nNo, nAcademyMasterCharNo, sAcademyMasterCharID (20), nMaxMembers, u64 nMoney,
        nAcademyPoint, nAcademyRanking, dBuffEndTime / dNotifyDate (mktime), sNotify (strcpy), sIntro (strcpy),
        nGuildMasterCharNo, sGuildMasterCharID (20), u16 nGraduateCount }                      (copy FUN_0041b4c0)
    every 3 academies (5 + n·0x2D0 > 0x7FD): Send 0x9802 NC_GUILD_ACADEMY_START_DB_ALL_ACK { u16 Error 0x1780, u8 PartMask,
        u16 NumOfGuildAcademy, GUILD_ACADEMY_DB[n] }; last part |= 2

0x980F NC_GUILD_ACADEMY_DB_MEMBER_REQ { u32 nNo }                                        (4)      @ FUN_00437300
    rows = usp_GuildAcademy_getMemberList(nNo)   # (db-backup) G.nCharNo, nJoinLevel, dJoinDate, nGrade, sIntro, nChatBanTime,
                                                 # C.sID, C.nLevel, sLoginZone, dLastLoginDate, S.nClass
    failure: Send 0x9810 { nNo, u16 Error 0x1792 } (9 bytes)
    per row → GUILD_ACADEMY_MEMEBER_INFO (0x9D) = CLIENT { sName, nGrade, sIntro (strcpy), dLogonInfo (date bits of
        dLastLoginDate), nClassID, nLevel, bIsParty 0, sMap (12), dJoinInfo (dJoinDate bits), nJoinLevel } (FUN_0041bb40)
        + SERVER { nAcademyMemberCharNo, dCanLeaveTime 0, tm_dCanLeaveTime not written, tChatBan_RestTime = nChatBanTime }
    every 13 members (9 + n·0x9D > 0x7FD): Send 0x9810 NC_GUILD_ACADEMY_DB_MEMBER_ACK { nNo, u16 Error 0x1780, u8 PartMask,
        u16 NumOfAcademyMember, entries }; last part |= 2

0x9803 NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_REQ { u32 nRoundTime }                  (4)      @ FUN_0041b5b0
0x984F NC_GUILD_ACADEMY_DB_GET_RANKING_LIST_REQ { u16 hWMChar, u32 nRoundTime }           (6)      @ FUN_00434bd0
    rows = usp_GuildAcademy_getRanking(nRoundTime)   # rows (Time dDate, u32 nPoint, i32 nGuildNo, sGuildName, i32 nMasterNo,
                                                     # sMasterID, u32 nRanking)
    0x9803: entries {u32 nGuildNo, u32 nPoint} (8); Send 0x9804 { u16 Error 0x18B8 / 0x18B9, u8 PartMask,
            GUILD_ACADEMY_START_RANKING_DATA { i32 round time = mktime(dDate of the last row), u32 count, entries } } (0xB + 8n)
    0x984F: entries of 11 dwords (all row columns, names 20 bytes); Send 0x9850 { u16 Error 0x19B0 / 0x19B3, u16 hWMChar,
            u8 PartMask, GUILD_ACADEMY_RANKING_DATA … } (0x35 + 44n)
    both split into parts at 0x7FD bytes (PartMask bit 0 first, bit 1 last)

0x9805 NC_GUILD_ACADEMY_START_DB_RANK_BALANCE_REQ {}                                              @ FUN_0041b9e0
0x9857 NC_GUILD_ACADEMY_DB_RANK_BALANCE_REQ {}                                                    @ FUN_0041db80
    usp_GuildAcademy_setRanking()   # (db-backup) one transaction: append the current ranking (all academies by point) to
                                    # tGuildAcademyRanking with nCount = max + 1
    Send 0x9806 { u16 Error 0x18C8 / 0x18C9 }  resp. 0x9858 NC_GUILD_ACADEMY_DB_RANK_BALANCE_ACK { u16 Error 0x18B0 / 0x18B2 }  (2)

0x9854 NC_GUILD_ACADEMY_DB_LEVEL_UP_REQ { u16 hWMChar, u32 nGuildNo, u32 nAddAcademyPoint, i32 dAddBuffEndTime }  (0xE)  @ FUN_0041dcb0
    usp_GuildAcademy_setMemberLevelup(nGuildNo, nAddAcademyPoint, dAddBuffEndTime)
    Send 0x9855 NC_GUILD_ACADEMY_DB_LEVEL_UP_ACK { u16 Error 0x1890 / 0x1891, hWMChar, nGuildNo, nAddAcademyPoint, dAddBuffEndTime } (0x10)
```

### 9.2 Members

```pseudo
0x9814 NC_GUILD_ACADEMY_DB_MEMBER_JOIN_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, Name5 sCharID @0xA, u8 nJoinLevel @0x1E,
        u8 nGrade @0x1F }                                                                   (0x20)   @ FUN_0041bbd0
    ok = usp_GuildAcademy_setMember(nNo, nCharNo, dJoinDate = now, nGrade)    # wrapper FUN_00455ae0; nJoinLevel not passed
         # (db-backup) −1511 / −1512 invalid, −1522…−1524 membership checks, −1591 insert error
    ok: usp_GuildAcademy_setHistory(nNo, nCharNo, sCharID, 101 ACADEMY_MEMBER_JOIN)
    Send raw 0x9815 NC_GUILD_ACADEMY_DB_MEMBER_JOIN_ACK { hWMChar, nNo, nCharNo, nGrade, dJoinInfo (now, FUN_0041b460),
        nJoinLevel, u16 Error = ok ? 0x1780 : 0x178F }                                                               (0x12)

0x981D NC_GUILD_ACADEMY_DB_MEMBER_LEAVE_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, Name5 sCharID }  (0x1E)  @ FUN_0041be10
    ok = usp_GuildAcademy_delMember(nNo, nCharNo); ok: history 102 ACADEMY_MEMBER_LEAVE
    Send raw 0x981E NC_GUILD_ACADEMY_DB_MEMBER_LEAVE_ACK { hWMChar, nNo, nCharNo, u16 Error = ok ? 0x1780 : 0x1794 }  (0xC)

0x9819 NC_GUILD_ACADEMY_DB_MEMBER_VANISH_REQ { u16 hWMChar, Name5 sCharID @2, u32 nNo @0x16, u32 nCharNo @0x1A }  (0x1E)  @ FUN_00437ab0
    ok = usp_GuildAcademy_delMember(nNo, nCharNo); ok: history 103 ACADEMY_MEMBER_VANISH
    Send raw 0x981A NC_GUILD_ACADEMY_DB_MEMBER_VANISH_ACK { hWMChar, sCharID, nNo, nCharNo, u16 Error = ok ? 0x1780 : 0x179E } (0x20)

0x982F NC_GUILD_ACADEMY_DB_MEMBER_GUILD_JOIN_REQ { u16 hWMChar, u32 nNo, Name5 sInviteCharID @6, u32 nTargetCharNo @0x1A,
        Name5 sTargetCharID @0x1E, u8 nGrade @0x32 }                                        (0x33)   @ FUN_004377c0
    # an academy member is promoted into the guild
    ok = usp_GuildAcademy_raiseMember(nNo, nTargetCharNo, nGrade, 0)
    ok: usp_Guild_setHistory(nNo, nTargetCharNo, sTargetCharID, 1 GUILD_MEMBER_JOIN);
        usp_GuildAcademy_setHistory(nNo, nTargetCharNo, sTargetCharID, 102 ACADEMY_MEMBER_LEAVE)
    Send raw 0x9830 NC_GUILD_ACADEMY_DB_MEMBER_GUILD_JOIN_ACK { hWMChar, nNo, sInviteCharID, nTargetCharNo, nGrade,
        u16 Error = ok ? 0x1780 : 0x178F }                                                                           (0x21)

0x985C NC_GUILD_ACADEMY_DB_SET_MASTER_REQ { u16 hWMChar, u32 nCharNo, Name5 sName, u32 nGuildNo @0x1A, u32 nSetCharNo @0x1E } (0x22)  @ FUN_0041c1e0
    ok = usp_GuildAcademy_setMaster(nGuildNo, nCharNo)
    ok: Log 0x0755 NC_LOG_GUILD_ACADEMY_SET_MASTER { nGuildNo, nSetCharNo, nCharNo }                                (0xC)
    Send 0x985D NC_GUILD_ACADEMY_DB_SET_MASTER_ACK { u16 Error = ok ? 0x17F0 : 0x17F1, echo }                        (0x24)

0x987F NC_GUILD_ACADEMY_DB_SET_MASTER_BY_LEAVE_REQ { u32 nGuildNo, u32 nOldAcademyMasterCharNo, Name5 sOldAcademyMasterName,
        u32 nNewAcademyMasterCharNo, Name5 sNewAcademyMasterName }                          (0x34)   @ FUN_0041c3d0
    ok = usp_GuildAcademy_setMaster(nGuildNo, nNewAcademyMasterCharNo)
    Send 0x9880 NC_GUILD_ACADEMY_DB_SET_MASTER_BY_LEAVE_ACK { u16 Error = ok ? 0x1780 : 0x0C87 (the guild notice code,
        copy-paste; also 0x9827) (original bug) D04-B18, echo }                                                                                         (0x36)

0x9827 NC_GUILD_ACADEMY_DB_NOTIFY_REQ { u16 hWMChar, u32 nNo, u16 nNotifyLength @6, sNotify @8 }            @ FUN_0041c000
    as 0x7462 (§6.3): the answer { u16 Error, hWMChar, nNo, i32 dNotifyDate = time(NULL), nNotifyLength, sNotify } is built
    first; usp_GuildAcademy_setNotify(nNo, sNotify); Error = ok ? 0x1780 : 0x0C87; nNotifyLength unchecked (D04-B16)
    Send 0x9828 NC_GUILD_ACADEMY_DB_NOTIFY_ACK                                                              (0xE + len)

0x9887 NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_REQ { u32 nGuildNo, u32 nCharNo, u32 nBanCharNo, u32 nRestTime }  (0x10)  @ FUN_0041ecf0
    usp_GuildAcademy_setChatBanTime(nGuildNo, nBanCharNo, nRestTime)
    Error = ok ? 0x17B0 : nRet == −1511 ? 0x17B3 : 0x17B4
    Send 0x9888 NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_ACK { echo, u16 Error }                                          (0x12)

0x988D NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_CANCEL_REQ { u32 nGuildNo, u32 nCharNo, u32 nBanCancelCharNo }  (0xC)  @ FUN_00428bf0
    usp_GuildAcademy_setChatBanTime(nGuildNo, nBanCancelCharNo, 0)
    Error = ok ? 0x31A8 : nRet == −1511 ? 0x31AB : 0x31AC
    Send 0x988E NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_CANCEL_ACK { echo, u16 Error }                                   (0xE)

0x9889 NC_GUILD_ACADEMY_MEMBER_DB_SAVE_CHAT_BAN_TIME_CMD { u32 nGuildNo, u32 nCharNo, u32 nRestTime }  (0xC)  @ FUN_0041ee80
    usp_GuildAcademy_setChatBanTime(nGuildNo, nCharNo, nRestTime); failure logged; no answer

0x9891 NC_GUILD_ACADEMY_HISTORY_DB_LIST_REQ { u16 hWMChar, u32 nGuildNo }                 (6)      @ FUN_00428dd0
    as 0x74FF (§6.5) with usp_GuildAcademy_getHistoryList (w00 and Fixes/), Error 0x3188 ok / 0x3189 fail;
    Send 0x9892 NC_GUILD_ACADEMY_HISTORY_DB_LIST_ACK
```

### 9.3 Graduates and rewards

```pseudo
0x9851 NC_GUILD_ACADEMY_DB_GRADUATE_JOIN_REQ { u16 hWMChar, u32 nCharNo, u32 nGuildNo, Name5 sName, u8 nClass @0x1E,
        u8 nGraduateLevel @0x1F }                                                           (0x20)   @ FUN_0041d9f0
    # the handler's log string is fc_NC_GUILD_ACADEMY_DB_CLEAR_REWARD_ITEM_REQ and its codes are 0x9847's (copy-paste)
    # (original bug) D04-B17
    usp_GuildAcademy_setGraduate(nCharNo, nGuildNo, sName, nClass, nGraduateLevel)
    Send 0x9852 NC_GUILD_ACADEMY_DB_GRADUATE_JOIN_ACK { hWMChar, nGuildNo, u16 Error = ok ? 0x1998 : 0x199D }         (8)

0x984B NC_GUILD_ACADEMY_DB_GET_GRADUATE_REQ { u16 hWMChar, u32 nGuildNo }                  (6)      @ FUN_004345f0
    total = usp_GuildAcademy_getGraduateCount(nGuildNo) (first column) ; failure → Error 0x19AB
    rows = usp_GuildAcademy_getGraduateList(nGuildNo): (sName, u8 class, u16 level, Time join, u16, Time graduate)
        → entries of 0x67 bytes (name, class, level, join time_t + localtime tm, graduate time_t + tm)
    every 144 entries or 0x7FD bytes: Send 0x984C NC_GUILD_ACADEMY_DB_GET_GRADUATE_ACK { u16 Error 0x19A8, hWMChar,
        u8 PartMask, GRADUATE_DATA { total, count, entries } }; last part |= 2

0x9833 NC_GUILD_ACADEMY_DB_GET_REWARD_MONEY_REQ { u16 hWMChar, u32 nGuildNo }             (6)      @ FUN_0041ccc0
    rows = usp_GuildAcademy_getRewardAll(nGuildNo, type 1)   # (u8 nLevel, u16, u64 nCen, i32)
    ≤ 51 entries GUILD_ACADEMY_REWARD_MONEY {u8 nLevel, u64 nCen}
    Send 0x9834 NC_GUILD_ACADEMY_DB_GET_REWARD_MONEY_ACK { u16 Error 0x1880 / 0x1885, hWMChar, u8 n, entries }      (5 + 9n)

0x9837 NC_GUILD_ACADEMY_DB_GET_REWARD_ITEM_REQ { u16 hWMChar, u32 nGuildNo }              (6)      @ FUN_0041cef0
    # log string of 0x9833 (copy-paste)
    rows = usp_GuildAcademy_getRewardAll(nGuildNo, type 2)   # (u8 nLevel, u8 option type, u64 option data, u16 nItemID)
    rows with the same (level, item) merge into one GUILD_ACADEMY_REWARD_ITEM {u8 nLevel, u16 nItemID, u8 NumOfItemOption,
        {u32 type, u64 data}}: option type 2 → NumOfItemOption 0, else 1; a second option for one item → Error 0x188D, stop
    Send 0x9838 NC_GUILD_ACADEMY_DB_GET_REWARD_ITEM_ACK { u16 Error 0x1888 / 0x188D, hWMChar, u8 n, entries (0x10) }

0x983B NC_GUILD_ACADEMY_DB_SET_REWARD_MONEY_REQ { u16 hWMChar, u32 nGuildNo, u8 n @6, {u8 nLevel, u64 nCen}[n] @7 }  @ FUN_0041d290
    usp_GuildAcademy_delRewardAll(nGuildNo, 1) fails → 0x18C5
    for each: usp_GuildAcademy_setReward(nGuildNo, nLevel, type 1, nCen, nItemID 0xFFFF) fails → 0x18C5, stop
    # the old rewards are already deleted when a later insert fails (no transaction)
    Send 0x983C NC_GUILD_ACADEMY_DB_SET_REWARD_MONEY_ACK { hWMChar, u16 Error 0x18C0 / 0x18C5 }                      (4)

0x983F NC_GUILD_ACADEMY_DB_SET_REWARD_ITEM_REQ { u16 hWMChar, u32 nGuildNo, u8 n @6, GUILD_ACADEMY_REWARD_ITEM[n] @7 }  @ FUN_0041d4c0
    usp_GuildAcademy_delRewardAll(nGuildNo, 2) fails → 0x199D
    for each item: only its first option is stored: setReward(nGuildNo, nLevel, type = option type, data = option data,
        nItemID); an item with NumOfItemOption 0 is not stored at all (original bug) D04-B23; failure → 0x190D, stop
    Send 0x9840 NC_GUILD_ACADEMY_DB_SET_REWARD_ITEM_ACK { hWMChar, u16 Error 0x1908 / 0x190D / 0x199D }              (4)

0x9843 NC_GUILD_ACADEMY_DB_CLEAR_REWARD_MONEY_REQ { u16 hWMChar, u32 nGuildNo }           (6)      @ FUN_0041d770
    usp_GuildAcademy_delRewardAll(nGuildNo, 1); Send 0x9844 { hWMChar, u16 Error 0x1950 / 0x1955 }                   (4)
0x9847 NC_GUILD_ACADEMY_DB_CLEAR_REWARD_ITEM_REQ { u16 hWMChar, u32 nGuildNo }            (6)      @ FUN_0041d8b0
    usp_GuildAcademy_delRewardAll(nGuildNo, 2); Send 0x9848 { hWMChar, u16 Error 0x1998 / 0x199D }                   (4)

0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ { hdr, u32 nCharNo @6, u32 nGuildNo @0xA, u8 nLevel @0xE }  (0xF)  @ FUN_0041de10
    # from the zone when an academy member reaches a level; pays the academy's configured reward for that level
    answer = PROTO_NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_ACK { hdr, u16 Error @6, nCharNo, nGuildNo, u64 nWantMoney,
             u32 nWantItemCnt, GUILD_ACADEMY_REWARD_ITEM WantItem, u64 nSubAcademyMoney, u64 nStorageMoney,
             u8 nModifyItemCnt, EACH_MODIFY_ITEM[n] (9 each) };  Error = 0x18A0 (success)
    usp_GuildAcademy_getReward(nGuildNo, nLevel) failed → Error 0x188D, send (logged)
    rows (u8 type, u64 data, u16 itemId): type 1 → reward cen = data; type 3 → reward item lot (low 16 + 16 bits of data);
        other types → the item's option; a non-cen row with item 0xFFFF or two rows with different item ids →
        Error 0x18A1, send (log "DB reward item setting abnormal")
    nothing configured (no cen, item 0xFFFF) → send (0x18A0, nothing paid)
    usp_GuildAcademy_getMoney(nGuildNo) → the academy's money (row u64); failure → 0x18A1, send
    item reward: AcademyStorage_List(nGuildNo) (D03 §5.3) fails → 0x18A1, send (log "academy inventory fetch failed");
        checking a storage item fails → 0x18A1, send; then find stacks of that item in the academy reward storage and
        move / grow / create the member's item: ItemAttr_Save with the new lot (CGameDB_Item_GetItemOptions),
        p_Item_SetStorageAndOwner(…, 1) / Item_DropAll / Item_Insert(MakeItemKeyEx(itemId, 0xB, 0, g),
        ItemAttr_MakeWithLot FUN_00468000, 1); the attribute-class helpers FUN_0044ff60 / FUN_0044d340 build the option
        block; failures → Error 1099 (0x44B); each changed item is listed in ModifyItem; what is missing → nWantItemCnt
    cen reward: amount = min(reward, academy money); usp_GuildAcademy_withdrawMoney(nGuildNo, nCharNo, amount)
        # (db-backup) moves cen from tGuildAcademy.nMoney to the character
        failure: nRet 1 → 0xF99, 2 → 0xF9A, 3 → 0xF9B, 4 → 0xF9C, 5 → 0xF9D, 6 → 0xF9E, other → 0xF98; send at once
        # the w00 procedure returns only negative codes (−1511/−1512/−1514/−1524/−1525/−1527/−1593), so with it every
        # failure is 0xF98: the 2016 procedure returned 1–6 (db-backup mismatch)
        nSubAcademyMoney = amount, nStorageMoney = money left, nWantMoney = reward − amount
    Send 0x986C NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_ACK (0x3D + 9n)
    if that send returned 1 and (nWantMoney ≠ 0 or the wanted lot ≠ 0): Send to the WM (SendToWorldManager)
        0x9882 NC_GUILD_ACADEMY_DB_REWARD_WANT_CMD { nCharNo, nGuildNo, u64 nWant_Cen, u16 nWant_ItemID (only copied when
        the lot ≠ 0), u32 nWant_ItemLot }                                                                          (0x16)
    # the exact rule for choosing / merging stacks in the storage is not traced instruction by instruction (§12)
```

## 10. Chat block list (dept 42 CHAT_RESTRICT), requests from the WM

`tChatBlock {nUserNo, nCharNo}` *(db-backup, w00)*: an account-wide list of blocked characters (loaded at character load as
0xA801, D02 §4 step 18). WM side: W04.

```pseudo
0xA804 NC_CHAT_RESTRICT_DB_ADD_REQ { u16 nSessionHandle, u32 nUserNo, Name5 sChatRestrictCharID }  (0x1A)  @ FUN_00438bc0
    ok = usp_ChatBlock_setBlock(nUserNo, sChatRestrictCharID, OUT nRet)
    # (db-backup) −2311 bad user, −2312 bad name, −2323 no such (undeleted) character, −2321 already blocked,
    # −2322 count > max (the check is `>`, so one more than the maximum fits, db-backup), −2392 insert error;
    # ok → SELECT nCharNo, sID, nAdminLevel, bDeleted of the new entry
    ok: row → nChatRestrictCharNo, sCharID (bIsDeleted 1: cut at the first '~' of the deleted-name suffix, FUN_00442ab0),
        bIsGM = (nAdminLevel ≠ 0), bIsDeleted
    nError: ok → 0x1C00; −2311 → 0x1C05, −2312 → 0x1C06, −2321 → 0x1C07 "You already blocked this user.",
            −2322 → 0x1C08 "You can only block a maximum of 100 players. …", −2323 → 0x1C09, −2392 / other / call failed → 0x1C0A
    Send raw 0xA805 NC_CHAT_RESTRICT_DB_ADD_ACK { u16 nError, nSessionHandle, PROTO_CHAT_RESTRICT_INFO {Name5 sCharID,
        u8 bIsGM, u8 bIsDeleted}, u32 nChatRestrictCharNo }                                                          (0x1E)
    # on failure the info part is uninitialised

0xA808 NC_CHAT_RESTRICT_DB_DEL_REQ { u16 nSessionHandle, u32 nUserNo, u32 nChatRestrictCharNo }  (0xA)  @ FUN_00420990
    usp_ChatBlock_delBlock(nUserNo, nChatRestrictCharNo)
    nError: ok → 0x1C10; −2311 → 0x1C14, −2312 → 0x1C15, −2323 → 0x1C16, −2394 / other → 0x1C13
    Send raw 0xA809 NC_CHAT_RESTRICT_DB_DEL_ACK { u16 nError, nSessionHandle, u32 nChatRestrictCharNo }              (8)

0xA80C NC_CHAT_RESTRICT_DB_DEL_ALL_REQ { u16 nSessionHandle, u32 nUserNo }               (6)      @ FUN_00420aa0
    usp_ChatBlock_delBlockALL(nUserNo)
    nError: ok → 0x1C20; −2321 → 0x1C20 (treated as success, inferred: nothing to delete); −2311 → 0x1C22;
            −2394 / other → 0x1C21
    Send raw 0xA80D NC_CHAT_RESTRICT_DB_DEL_ALL_ACK { u16 nError, nSessionHandle }                                   (4)
```

## 11. Procedures and helpers reached by these handlers

The procedures cited in the sections above with their wrapper address are not repeated. The table lists the remaining
`SQL_<procedure>` wrappers (D02 named them; parameter count = the `{CALL …}` string). Every wrapper binds its parameters with
`SQLBindParameter` (`Ordinal_72`) and executes with `SQLExecDirect` (`Ordinal_11`); "ok" conventions are given where the
procedure is described. Procedures missing from every backup: `p_Guild_SetMoney`, `usp_GuildTournament_setRefundNotice`.
Private-server reconstructions (not original): `usp_GuildEmblem_*`, `usp_GuildAcademy_setHistory`, and the Fixes/-only
`usp_Guild_getHistoryList` / `usp_Guild_setHistory`. `usp_GuildTournament_setRegist`'s w00 body is truncated after the
header; `usp_GuildTournament_getRegistList` returns fewer columns than the 2016 code reads (§6.4).

| Procedure | Params | Wrapper | Caller | Backups (`=` same parameter count) |
|---|---|---|---|---|
| `p_Char_FameAdd` | 3 | FUN_004596d0 | FUN_00410f20 | Character:= w00:= |
| `p_Char_GetOptGame` | 3 | FUN_00458c60 | FUN_0046d180 | Character:= w00:= |
| `p_Char_GetOptKeyMapping` | 3 | FUN_00458dc0 | FUN_0046d1c0 | Character:= w00:= |
| `p_Char_GetOptShortCutData` | 3 | FUN_004589a0 | FUN_0046d100 | Character:= w00:= |
| `p_Char_GetOptShortCutSize` | 3 | FUN_00458a50 | FUN_0046d120 | Character:= w00:= |
| `p_Char_GetOptSound` | 3 | FUN_00458bb0 | FUN_0046d160 | Character:= w00:= |
| `p_Char_GetOptVideo` | 3 | FUN_00458b00 | FUN_0046d140 | Character:= w00:= |
| `p_Char_GetOptWindowsPos` | 3 | FUN_00458d10 | FUN_0046d1a0 | Character:= w00:= |
| `p_Char_SetOptGame` | 3 | FUN_004590f0 | FUN_0046d260 | Character:= w00:= |
| `p_Char_SetOptKeyMapping` | 3 | FUN_00459230 | FUN_0046d2a0 | Character:= w00:= |
| `p_Char_SetOptShortCutData` | 3 | FUN_00458e70 | FUN_0046d1e0 | Character:= w00:= |
| `p_Char_SetOptShortCutSize` | 3 | FUN_00458f10 | FUN_0046d200 | Character:= w00:= |
| `p_Char_SetOptSound` | 3 | FUN_00459050 | FUN_0046d240 | Character:= w00:= |
| `p_Char_SetOptVideo` | 3 | FUN_00458fb0 | FUN_0046d220 | Character:= w00:= |
| `p_Char_SetOptWindowsPos` | 3 | FUN_00459190 | FUN_0046d280 | Character:= w00:= |
| `p_GuildTournament_GetLastMatch` | 0 | FUN_00454d90 | FUN_004159d0 | Character:= w00:= |
| `p_Guild_Member_Join` | 4 | FUN_00454950 | FUN_00415270 | Character:= w00:= |
| `p_Guild_Member_SetGrade` | 4 | FUN_00454ab0 | FUN_00436a40 | Character:= Character:= w00:= |
| `p_Guild_Member_SetIntro` | 4 | FUN_00454c00 | FUN_00415670 | Character:= w00:= |
| `p_Guild_SetExp` | 3 | FUN_00453ea0 | FUN_004076a0 | Character:= w00:= |
| `p_Guild_SetFame` | 3 | FUN_00453d60 | FUN_00415780 | Character:= w00:= |
| `p_Guild_SetIntro` | 3 | FUN_004546a0 | FUN_00414ee0 | Character:= w00:= |
| `p_Guild_SetMoney` | 3 | FUN_00453e00 | FUN_004076a0 | MISSING |
| `p_Guild_SetType` | 3 | FUN_00453cc0 | FUN_0041f980 | Character:= w00:= |
| `p_Guild_SetWarResult` | 5 | FUN_00454510 | FUN_00415780 | Character:= w00:= |
| `p_Guild_SetWar` | 6 | FUN_00454420 | FUN_00414ff0 | Character:= w00:= |
| `p_Guild_setName` | 3 | FUN_004547e0 | FUN_0041f7e0 | Character:= w00:= |
| `p_HolyPromise_DelChar` | 2 | FUN_00457810 | FUN_0041a4f0 | Character:= w00:= |
| `p_HolyPromise_Del` | 2 | FUN_004577a0 | FUN_0041a440 | Character:= w00:= |
| `p_HolyPromise_SetDate` | 4 | FUN_00457b10 | FUN_0041ae00 | Character:= w00:= |
| `p_Item_GetStorageListType` | 2 | FUN_00461660 | FUN_0046a500 | Character:= w00:= |
| `p_Prison_Add2` | 6 | FUN_00465af0 | FUN_00436df0 | Character:= w00:= |
| `p_Prison_Add` | 7 | FUN_004659e0 | FUN_00436df0 | Character:= w00:= |
| `p_Prison_Alter2` | 6 | FUN_00465e10 | FUN_00437010 | Character:= w00:= |
| `p_Prison_Alter` | 7 | FUN_00465d00 | FUN_00437010 | Character:= w00:= |
| `p_Prison_Get` | 1 | FUN_00465c60 | FUN_004166d0 | Character:= w00:= |
| `p_Prison_UpdateCharPrisonMin` | 2 | FUN_00465be0 | FUN_00416650 | Character:= w00:= |
| `usp_Character_getGameOption` | 2 | FUN_0045dec0 | FUN_00422f10 | w00:= |
| `usp_Character_getKeyMap` | 2 | FUN_0045db70 | FUN_00422890 | w00:= |
| `usp_Character_initKeyMap` | 2 | FUN_0045da70 | FUN_00422890 | w00:= |
| `usp_Character_setGameOptionInit` | 2 | FUN_0045ddc0 | FUN_00422f10 | w00:= |
| `usp_Character_setGameOption` | 4 | FUN_0045dfc0 | FUN_004231a0 | w00:= |
| `usp_Character_setKeyMap` | 5 | FUN_0045dc70 | FUN_00422b80 | w00:= |
| `usp_ChatBlock_delBlockALL` | 2 | FUN_0045bf10 | FUN_00420aa0 | Character:= w00:= |
| `usp_ChatBlock_delBlock` | 3 | FUN_0045bd20 | FUN_00420990 | Character:= w00:= |
| `usp_ChatBlock_setBlock` | 3 | FUN_0045bb30 | FUN_00438bc0 | Character:= w00:= |
| `usp_GuildAcademy_delMember` | 3 | FUN_00455c20 | FUN_00437ab0 | Character:= w00:= |
| `usp_GuildAcademy_delRewardAll` | 3 | FUN_00456400 | FUN_0041d770 | Character:= w00:= |
| `usp_GuildAcademy_getGraduateCount` | 2 | FUN_004568d0 | FUN_004345f0 | Character:= w00:= |
| `usp_GuildAcademy_getGraduateList` | 2 | FUN_004569c0 | FUN_004345f0 | Character:= w00:= |
| `usp_GuildAcademy_getGuildAcademyList` | 1 | FUN_00455800 | FUN_00434030 | Character:= w00:= |
| `usp_GuildAcademy_getHistoryList` | 3 | FUN_00457250 | FUN_00428dd0 | w00:= Fixes/usp_GuildAcademy_getHistoryList.sql:= |
| `usp_GuildAcademy_getMemberList` | 2 | FUN_004558e0 | FUN_00437300 | Character:= w00:= |
| `usp_GuildAcademy_getRanking` | 2 | FUN_00456ab0 | FUN_00434bd0 | Character:= w00:= |
| `usp_GuildAcademy_getRewardAll` | 3 | FUN_00456080 | FUN_0041cef0 | Character:= w00:= |
| `usp_GuildAcademy_getReward` | 3 | FUN_00456190 | FUN_0041de10 | Character:= w00:= |
| `usp_GuildAcademy_raiseMember` | 4 | FUN_00455d30 | FUN_004377c0 | Character:= w00:= |
| `usp_GuildAcademy_setChatBanTime` | 4 | FUN_00456ea0 | FUN_0041ecf0 | w00:= |
| `usp_GuildAcademy_setGraduate` | 6 | FUN_00456770 | FUN_0041d9f0 | Character:= w00:= |
| `usp_GuildAcademy_setHistory` | 5 | FUN_00457370 | FUN_00437ab0 | w00:= Fixes/usp_GuildAcademy_setHistory.sql:= |
| `usp_GuildAcademy_setMaster` | 3 | FUN_00455f70 | FUN_0041c3d0 | Character:= w00:= |
| `usp_GuildAcademy_setMemberLevelup` | 4 | FUN_00456c80 | FUN_0041dcb0 | Character:= w00:= |
| `usp_GuildAcademy_setNotify` | 3 | FUN_00455e60 | FUN_0041c000 | Character:= w00:= |
| `usp_GuildAcademy_setRanking` | 1 | FUN_00456ba0 | FUN_0041db80 | Character:= w00:= |
| `usp_GuildAcademy_setReward` | 6 | FUN_004562a0 | FUN_0041d290 | Character:= w00:= |
| `usp_GuildEmblem_GetInfoAll` | 0 | FUN_004574d0 | FUN_0042f3a0 | w00:= Fixes/usp_GuildEmblem_GetInfoAll.sql:= |
| `usp_GuildEmblem_GetInfo` | 1 | FUN_00457530 | FUN_0042f970 | w00:= Fixes/usp_GuildEmblem_GetInfo.sql:= |
| `usp_GuildEmblem_SetInfo` | 7 | FUN_004575c0 | FUN_0042f730 | w00:= Fixes/usp_GuildEmblem_SetInfo.sql:= |
| `usp_GuildTournament_SetResult` | 5 | FUN_004556b0 | FUN_004161c0 | w00:= |
| `usp_GuildTournament_getChoiceList` | 2 | FUN_004553c0 | FUN_00408630 | Character:= w00:= |
| `usp_GuildTournament_getMoney` | 2 | FUN_00454250 | FUN_004076a0 | Character:= w00:= |
| `usp_GuildTournament_getRegistList` | 2 | FUN_004550b0 | FUN_004159d0 | Character:= w00:= |
| `usp_GuildTournament_setChoice` | 4 | FUN_004551b0 | FUN_00408630 | Character:= w00:= |
| `usp_GuildTournament_setRefundNotice` | 3 | FUN_00455590 | FUN_00408ae0 | MISSING |
| `usp_Guild_GetTokenAll` | 0 | FUN_00453820 | FUN_004144e0 | Character:= w00:= |
| `usp_Guild_getHistoryList` | 3 | FUN_00456fd0 | FUN_00435630 | Fixes/usp_Guild_getHistoryList.sql:= |
| `usp_HolyPromise_getRemainMoney` | 2 | FUN_00457df0 | FUN_0041aff0 | Character:= w00:= |
| `usp_HolyPromise_withDrawRemainMoney` | 2 | FUN_00457fd0 | FUN_0041b190 | Character:= w00:= |

Non-procedure helpers: `GameData_Load` FUN_00401550 (loads HolyPromiseReward.shn, §8); SHN row getter FUN_0043fdc0;
`MakeItemKeyEx` FUN_0044d240 (§6.4); `ItemStorage_GetUsedSlots` FUN_0046a500; `GTReward_MakeItemAttr` FUN_00467c60 and
`ItemAttr_MakeWithLot` FUN_00468000 (attribute block by ItemInfo class +0x66 with a lot / count; used by 0x986B); item-attribute
class helpers FUN_0044d340 / FUN_0044ff60 (`g_ItemAttrClassContainer`, 0x986B); the log writers `LogMsg` FUN_00447920 →
FUN_00447710 → FUN_00447570 (append to the daily log file); CRT `_localtime32_s` FUN_0048e5c3 and `__ftol2` FUN_0048edb6.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D04-B1 | 0x4403/0x4409/0x4418/0x441A (`Quest_Store`) | `sData` bound as 100 bytes, only 29 filled | 71 bytes of stack garbage stored in every `tQuest.sData` | bind 29 bytes |
| D04-B2 | 0x441A | title rollback in `case 0xB43` tests `err == 0xB41` | a failed quest store keeps the new character title | restore the old title |
| D04-B3 | 0x441A | rollback subtracts nExp / nMoney even when they were not added (exp failure only logged) | exp can be lost on a later failure | track what was applied |
| D04-B4 | 0x4801 | 0x4803 is 7 bytes, the last never written | one stack byte on the wire | send 6 bytes or zero it |
| D04-B5 | 0x4812 | redistribution items are destroyed before `p_Skill_SetPowerAll`; no restore on failure | items lost when the DB refuses | one transaction |
| D04-B6 | 0x5410 | every DB error incl. "already friends" (2627) → 0x949 | client shows "Already have a friend request." | map 2627 to the "already registered" code |
| D04-B7 | 0x5815 | `AddCharFame` always returns 1 | 0x1103 path dead; fame failures not reported or refunded | return the procedure result |
| D04-B8 | 0x5C05 | GameLog 0x0454 sent on failure too | log shows licences that were never stored | log only on 0x9B9 |
| D04-B9 | 0x5C05 | log fields @0x16/@0x18 read 4 bytes past the 0x36-byte request | stale bytes in the GameLog | real fields / drop them |
| D04-B10 | 0x5C07 | unhandled `p_Item_ClrWeaponTitle` results (−1 call failure, SQL errors) keep 0x9E1 | zone applies a clear that did not happen | default to an error code |
| D04-B11 | 0x750D | `EmblemState` values other than 0/1/2/3/4/0xFF store an uninitialised stack byte | random emblem state in the DB | reject unknown states |
| D04-B12 | 0x7017… GET old options | `bSuccess 0` answers carry the uninitialised data buffer | stack bytes to the WM / client | zero the buffer |
| D04-B13 | 0x704D / 0x704F | ack `nCharNo` never written | the WM finds no (or the wrong) client; no 0x703A | copy nCharNo |
| D04-B14 | 0x7057 / 0x7059 | get-procedure failure after a successful init sends no answer | WM / client wait forever | answer with the error code |
| D04-B15 | 0x7452 | `nWarEnemy`, `dNotifyDate`, `sNotifyCharID`, `GuildClient.nNo`, tm copies, counters not filled | stale / zero guild data in the WM after a single-guild load | copy all columns |
| D04-B16 | 0x7462 / 0x7464 / 0x746D / 0x9827 | text lengths unchecked; `strcpy` / `_mbsnbcpy` into fixed buffers | stack overflow on a long notice / intro from the WM | clamp to 512 / 128 / 64 |
| D04-B17 | 0x9851 | answers with 0x9847's codes (0x1998 / 0x199D) and log text | graduate-join errors look like reward-clear errors | own codes |
| D04-B18 | 0x987F / 0x9827 | failure code 0x0C87 (guild notice) | wrong error shown / handled | academy code |
| D04-B19 | 0x748B | the ack's 8th byte (`nFinalSelectionGuildNum`) never written | WM may read a garbage count | write 0 |
| D04-B20 | 0x74F6 | a failed `getRegistList` still answers 0x0D50 (success) | WM treats an error as an empty list | error code |
| D04-B21 | 0x74AA money / division | new guild money bound as `SQL_C_ULONG` | guild money above 4 294 967 295 wraps when rewarded | bind as SBIGINT |
| D04-B22 | 0x74AA exp | log 0x04AD "new exp" = the guild number | wrong GameLog value | log the new exp |
| D04-B23 | 0x983F | reward items without an option are not stored; only the first option is | rewards silently lost | store the item row regardless |

## 12. Not reconstructed / uncertain

- **0x986B academy reward**: flow and error codes are reconstructed; the rule that picks and merges stacks in the academy
  reward storage (FUN_0041de10 decompiled lines ~107–170 and ~300–397) is summarised, not traced line by line. The 2016
  `usp_GuildAcademy_withdrawMoney` returned 1–6 (mapped to 0xF99–0xF9E); their meanings are unknown.
- `GTReward_MakeItemAttr` FUN_00467c60: the tail of ITEM_OPT (bytes 0x0D–0x20) feeding random options for class-4 items is
  not mapped field by field.
- `usp_GuildTournament_setRegist` (−1424 → 0x1C47 has no backup meaning; the w00 body is truncated), `setRefundNotice`
  and `p_Guild_SetMoney` (missing) — D06.
- Client texts: the guild (0x0C41…), academy (0x1780…), tournament (0x0D40…, 0x1C40…), quest, skill, holy-promise success
  and chat-block delete codes have no entry in the client error table; which reach the client and with what text is W03 /
  W04 / Z08's to check. The holy-promise 0x1741 text ("User is already logged on.") does not fit its DB meaning (ring).
- The `getRegistList` column disagreement (§6.4) means the 2016 procedure differed from w00; its real columns are inferred
  from the reads.

## 13. Coverage boundary

The two remaining open points of §12 (0x986B storage merge, `GTReward_MakeItemAttr`) are D04 scope; they are proposed
as follow-up item D07 in `docs/plan/status/D04.md` ("Proposed follow-up items").

| Found | Covered by | Argument |
|---|---|---|
| Friend list / friend points at load (`p_Friend_GetAll`, `usp_Character_*Friendpoint`, 0x1010, 0x541C) | D02 §4–5, D03 §6.5 | reached from 0x1004 / 0x1036 / 0x34BF, not from dept 21 |
| Title load / bulk save (`p_Char_GetTitleAll`, 0x400B `CharSaveTitle` FUN_00406370, FUN_0046d560) | D02 §4 / §6 | CHARSAVE and CHARDATA handlers |
| Holy-promise blocks of the character load (GetHolyPromiseUp/Member/RemainMoney called from 0x1004) | D02 §4 step 11 (documented here in §8) | same functions, D02 owns the load sequence |
| Holy-promise cen credit `usp_HolyPromise_setMoney` | D03 §1.5 | called by item purchases |
| `SetCharTitles` caller 0x345B quest reward | D03 §7.5 | ITEMDB handler |
| `CreateChestItemList` / `CreateItemList` (0x5815) | D03 §7.2 | item-list helpers |
| `DestroyItems` FUN_00412420, `Item_Insert`, `Item_Delete`, `ItemAttr_Save`, `AcademyStorage_List`, `ItemLotAfterUse` | D03 §1.2–1.3, §5.3, §7.5 | shared item helpers |
| WM handling of every guild / academy answer (CParserCharDB dept 29 / 38) and client texts | W03 (scope "CParserCharDB · 29 GUILD, 38 GUILD_ACADEMY") | WM side |
| WM handling of friend / option / prison / holy / chat-restrict answers | W04 (scope "CParserCharDB · 21 FRIEND, 28 CHAR_OPTION?, 31 ZONE?, 37 HOLY, 42 ?") | WM side |
| Zone side of quest / KQ / WT / CT / tournament join / holy cen reward / academy reward | Z08 (§3, §4, §7, §8, §9) | zone side |
| Skill DB answers in the zone | Z03 §9 | zone side |
| Guild tournament system, KQ map scripts | Z16 / Z09 | game logic, not persistence |
| Missing / truncated / mismatched procedures (`p_Guild_SetMoney`, `usp_GuildTournament_setRefundNotice` named in D06's scope; `setRegist` body, `getRegistList` columns, `withdrawMoney` 1–6 results, private `usp_GuildEmblem_*` / `usp_GuildAcademy_setHistory`) | D06 (scope names the first two; its clause on every inferred / db-backup statement takes the rest, listed in `docs/knowledge/D04.md` "For D06") | DB reconstruction, not binary behaviour |
| Who writes the tournament's second-round keys 2000+i besides 0x7497 | Z16 / W03 (proposal in the status file) | game logic of the tournament |
| GameLog packets 0x043E… / 0x04A3… / 0x0755 / 0xC810 | D05 | GameLog server side |
