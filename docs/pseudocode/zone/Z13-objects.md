# Zone server: mini-house object, wedding hall, pets and mounts internals (Z13)

Source: the 2016 zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`). Code read in the PDB export
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`); official class / member / method names come
from the NA2016 zone PDB (same build) and count as read in the code *(pdb2016)*. Other markers as in `AGENTS.md`:
*(pdb2017)*, *(inferred)*, *(db-backup)*. Packet layouts: `docs/protocol/packets-zone.md`, annotations
`docs/protocol/annotations/Z13.json`. Names: `tools/protocol-re/names/zone/Z13.json`.

This item continues Z07 (`docs/pseudocode/zone/Z07-character.md`), which documented the client requests and DB answers
of the mini-house (§6), wedding (§5), mounts (§8) and pets (§9); here are the object methods, timers and tables behind them.
The house TaiSai dice game is Z06 §3 (house vt 0x1bc–0x2a8, offsets +0xc6e0…); it is only linked here.

Time: `g_Now` = `clockwatch.cw_CurrTick` (DAT_14d41a70) counts **tenths of a second** (`docs/knowledge/Z02.md`).

Sections: §1 mini-house object (part 1). Later parts add §2 furniture, §3 portals / endurance / effects / emotions,
§4 wedding hall, §5–§6 pets, §7–§8 mounts, §9 minimon and other open points (see `docs/plan/status/Z13.md`).

---

## 1. Mini-house object `ShineObjectClass::ShineMiniHouse` (object type 3)

### 1.1 Data

`ShineMiniHouse : ShineObject`, size 0xD100 *(pdb2016)*. Ctor @ FUN_0055b050 (four `ItemFurnicherBox`, the brief-info
packet; the object's coordinate pointer is aimed at the brief's `coord`), dtor @ FUN_00555cf0, `MiniHouseInven` dtor
@ FUN_00549b40, deleting dtor @ FUN_00556150, `GetRTTI` @ FUN_00555d90.

| Offset | Member *(pdb2016)* | Meaning |
|---|---|---|
| +0x168 | `smh_Info` (0x458 bytes, below) | settings, member lists, positions |
| +0x5c0 | `smh_ValidCheckTime` | next 30-s check (`so_Routine`) |
| +0x5c4 | `smh_Furniture` (`MiniHouseInven`, 0xB1B4) | `u16 FurnitureHandle` (next furniture handle, starts at 1) + four boxes `FurnitureInven` (inventory type 3), `AccessoryInven` (13), `TileAllInven` (14), `MiniGameInven` (16) (§2) |
| +0xb778 | `smh_FurnitureLastTouchTIme[294]` | `{u16 FurnitureHandle, u32 LastTouch}` per furniture (object animations, §3) |
| +0xc0a8 | `smh_BriefInfo` (`BriefInformationMiniHouse`) | the prepared `0x1C13` packet (§1.7) |
| +0xc100 | `smh_PortalList` (0x138) | `u8 isActivePortal, u16 ActivePortalIndex, u32 PortalDeActiveTime, u16 nPortalCnt, PORTAL_INFO Portal[50] {u16 nPortalItemID, i32 dEndTime}` (§3) |
| +0xc238 | `smh_EndureCheckTime` (0x4a4) | `u8 isEndureCheck, u32 tEndureCheckTime, u8 nEndureFurnitureCnt, ENDURE_FURNITURE_INFO EndureFurniture[294] {u16 nFurnitureHnd, u8 nEndureGrade, u8 isRePair}` (§3) |
| +0xc6e0 | `smh_DiceTaiSai` | TaiSai table state: Z06 §3 |

`smh_Info` *(pdb2016)* (offsets inside, absolute = +0x168):

| +off | Field | Meaning |
|---|---|---|
| +0x00 | `char Title[21]` | room title |
| +0x15 | `char Password[9]` | empty = public |
| +0x1e | `u8 MaxPlayer` | capacity **+ 5** (the five reserved GM slots) |
| +0x1f | `u8 isArrageMode` | decoration mode (§1.5, unreachable) |
| +0x20 | `u8 CanEnter` | load counter: guests may enter when ≥ 5 |
| +0x21 | `u8 isPublic` | `Password == ""` |
| +0x24 | `FieldMap* Map` | the interior map instance |
| +0x28 | `u8 EnterPlayerCount` | index one past the last occupied member slot; **starts at 5** |
| +0x29 | `u8 EnterGMCount` | hidden GMs inside (0..5) |
| +0x2a | `u8 KickOutPlayerCount` | 0..20 |
| +0x2c | `ShineObject* pEnterPlayerIndex[104]` | member objects |
| +0x1cc | `u32 EnterPlayerIndex[104]` | member charNo (0xFFFF / −1 = empty) |
| +0x36c | `u32 KickOutPlayerIndex[20]` | charNo banned from this house instance |
| +0x3bc | `LoginLocation loginloc` | outside map + coordinate of the house |
| +0x3d1 | `RollBack RollBackPos {Name3 exitmapname, SHINE_XY_TYPE locate}` | where leavers go (= the outside spot) |
| +0x3e5 | `Enter EnterPos {Name3 entermapname}` | the interior map name |
| +0x3f1 | `u8 isItemInfoClose` | hide item info from guests |
| +0x3f2 | `char Notify[101]` | room notice |

**Member array layout** (read from `so_mh_Enter` / `so_mh_Out` / `so_Routine`): slot **5 = owner** (written by
`so_mh_BuildingMiniHouse`), slots 6…`EnterPlayerCount−1` = visitors in entry order, slots 4, 3, 2, 1, 0 = hidden GMs
(GM n goes to slot `4 − EnterGMCount`, so the occupied GM slots are `5 − EnterGMCount … 4`). Every "all members" loop
runs `i = 5 − EnterGMCount … EnterPlayerCount − 1`. Visitor counts shown to clients are `EnterPlayerCount − 5`
(owner included, GMs not), the shown capacity is `MaxPlayer − 5`.

Handle range: `so_RemakeHandle` @ FUN_00555e60 / `sohu_SetMiniHouseHandle` @ FUN_00548e60: handle = index + 0x251C
(9500…10499); index > 999 → 0xFFFF. `so_ObjectType` @ FUN_00555e40 = 3. `so_LoginLocation` @ FUN_00555e50 =
`&smh_Info.loginloc`. `so_FillBriefInformation` @ FUN_00555eb0 copies the 0x40-byte brief; `so_SendMyBriefInfo`
@ FUN_00555e10 sends the prepared 0x1C13 packet to one viewer (`viewer.so_GetGameSocketStream`). `so_TentDistance`
@ FUN_0058ccb0: true when dist² from the house > 0x7E9 (45 units); used by the build check of 0x8C03 (Z07 §6.3,
"tent point within …").

Interior map: `FieldMap::fm_MiniHouseInteriorMap` (static Name3) = the field whose `FieldAttr.KingdomQuestMap == 2`
(`FieldMap::fm_Init` FUN_00464bc0, Z09 §28.1); its map broadcast is `so_AllInMapMiniHouse` (only the members of the
sender's house, Z09 §28.1). Debug log file: `InnerMiniHouseLog` (initialiser FUN_0069aae0).

### 1.2 Building, routine and removal

```pseudo
so_mh_BuildingMiniHouse(owner, interiorMap, title, password, maxvisiter, bItemInfoClose, sNotify)   vt 0x78  @ FUN_00548810
    # called by sp_Schedule_BuildMiniHouse (Z07 §6.3) on a freshly allocated object, interiorMap = fm_MiniHouseInteriorMap
    smh_ValidCheckTime = 0; FurnitureHandle = 1
    EnterPlayerCount = 5; EnterGMCount = 0; KickOutPlayerCount = 0; CanEnter = 0
    Password = strncpy(password, 8); isPublic = (Password == ""); isArrageMode = 0
    LastTouch[294] = {0xFFFF, 0}; isActivePortal = 0; nPortalCnt = 0
    Title = strncpy(title, 20)
    maxvisiter = clamp(maxvisiter, 1, 99); MaxPlayer = maxvisiter + 5
    isItemInfoClose = bItemInfoClose; Notify = strncpy(sNotify, 100)
    isEndureCheck = 0; tEndureCheckTime = (g_Now / 100) * 100 + 610        # first endurance pass after ~61 s, aligned to 10 s
    member slots[104] = {null, 0xFFFF}
    slot 5 = owner, charNo; EnterPlayerCount = 6
    vt 0x1bc so_mh_InitDiceInfo()                                          # Z06 §3
    if owner has no field: return 0
    loginloc = owner's map + coordinate (the house stands where the owner stands)
    so_MapMarking(house) ≠ FM_MARKSUCCESS: return 0
    Map = FieldMap named interiorMap (search of fieldlist); none: return 0
    RollBackPos = { loginloc.currentmap, loginloc.currentcoord }
    FieldAttr of the outside map and of interiorMap must exist, and the interior's client map id must be in MapInfo: else return 0
    EnterPos.entermapname = interiorMap
    brief 0x1C13 body (PROTO_NC_BRIEFINFO_MINIHOUSEBUILD_CMD, 0x40 bytes, pdb2016):
        { u16 handle = house, CHARBRIEFINFO_CAMP camp = sp_MakeTentBriefInfo(owner), Name5 charid = owner name,
          SHINE_COORD_TYPE coord = owner xy + dir, char title[21] }
    return 1                                    # caller frees the object on 0 and answers (35, 4, 0x1196)
```

```pseudo
ShineMiniHouse::so_Routine(list, n)        vt 0x4ac   @ FUN_00567400   (every zone tick, Z09 §1.3 object routines)
    assert the coordinate lies inside the field ("fm_IsInFieldSize : MiniHouse")

    # 1. portal open timeout (§3)
    if so_mh_isActivePortal (vt 0x114) and PortalDeActiveTime <= g_Now:
        owner = GetObject(vt 0x84 owner handle)
        if owner: owner.so_AllInMap(0x8C27 NC_MINIHOUSE_DELETE_FURNITURE_CMD { u8 count = 1, u16 handle = 60000 }, 1)   # the portal pseudo-furniture
                  so_mh_DeActivePortal (vt 0x11c)
        # (no owner: the portal stays active and is re-tested every tick)

    # 2. endurance pass, every 600 ticks (60 s)
    if tEndureCheckTime <= g_Now:
        tEndureCheckTime = g_Now + 600
        if so_mh_DoingEndureGradeDown(&changed) (vt 0x16c, §3) and changed:
            owner = GetObject(owner handle)
            owner? owner.so_AllInMap(0x8C61 NC_MINIHOUSE_FURNITURE_ENDURE_CMD { u8 nCount = nEndureFurnitureCnt,
                         ENDURE_FURNITURE_INFO × nCount {u16 nFurnitureHnd, u8 nEndureGrade, u8 isRePair} }, 1)  (size 3 + 4n)
            for each entry: so_mh_FurnitureEmotionStop(nFurnitureHnd, owner) (vt 0x2e0)   # players using it stand up (§3)

    # 3. validity pass, every 300 ticks (30 s)
    if smh_ValidCheckTime <= g_Now:
        smh_ValidCheckTime = g_Now + 300
        owner = GetObject(owner handle)
        if owner and so_mh_CanEnter (data loaded):
            smh_FurnitureActiveCheck(FurnitureInven, 3) (§2); owner.sp_ChargedItemLimitCheck(FurnitureInven, 3) (player vt 0x38)
            same for AccessoryInven 13 and TileAllInven 14
            smh_FurnitureActiveCheck(MiniGameInven, 16); owner.so_DiceTaiSaiChargedItemLimitCheck(MiniGameInven, 16, 0, TaiSai status) (vt 0x180, Z06 §3.6)
        nowSec = g_Now / 10
        for i in 0 … min(nPortalCnt, 50) − 1:                       # expired portal scrolls (§3)
            if 0 < Portal[i].dEndTime < nowSec and Portal[i].nPortalItemID ≠ so_mh_GetActivePortalID (vt 0x120):
                owner? owner ← 0x8C4F NC_MINIHOUSE_PORTAL_DEL_CMD { u16 nPortalItemID }          # owner only, 4 bytes
                remove Portal[i] (shift down), nPortalCnt −= 1
                # (original bug) Z13-B3: i still advances, so the entry shifted into i is tested only 30 s later
        for each member m (slots 5 − GMCount … EnterPlayerCount − 1):
            if !m.so_ply_MH_GetActiveMH (player vt 0x130: the player's house handle is 0xFFFF):
                log "minihouse error(invalid MH handle) : mhnd(%d) - (%s : %d, %d)"
                m.so_ply_MH_SetMyHandle(house) (vt 0x134); m.so_LinkTo(so_mh_GetRollBackLinkPos, 6, 9, 10)   # send it out
            if m.so_IsEmpty (vt 0x300: the object slot was freed):
                m.so_LinkTo(rollback, 6, 9, 10); failure → log "minihouse error(Logout Fail) …"
            # neither path removes m from the member array (so_mh_Out does that when m unmarks)

    # 4. TaiSai timer (bIsActiveTimerCheckTime): auto roll / next game; Z06 §3.4
    return 1
```

```pseudo
so_mh_RemoveMH()                           vt 0x5c   @ FUN_00543960
    so_Unmark(house, 0, 1, 3) (FUN_00553970: vt 0x310, vt 0x51c, leave the coordinate lists, so_bIsMapMarking = 0)
    som_FreeObject(house, REMOVE_NOW, reason 0x13); failure → assert "…so_mh_RemoveMH : Fail to object free"
    # callers: so_MH_LogOut (owner leaves), sp_Schedule_BuildMiniHouse failure path (Z07 §6.3)
```

### 1.3 Membership: enter, leave, visit checks, kick

```pseudo
so_mh_isAlreadyEnterPlayer(p)     vt 0x90   @ FUN_00541ae0     # name is inverted: true = p may be added
    p null → 0
    for each member m: m == p → log, 0; m.charNo == p.charNo → log, 0
    return 1

so_mh_CanEnter()                  vt 0x94   @ FUN_00541e50:  CanEnter >= 5
    # CanEnter += 1 for each house box that finished loading from the DB (so_mh_SaveMHInven, four boxes, §2)
    # and once for the DB portal list (so_mh_SetPortalList, §3): 4 + 1 = 5 = everything loaded
so_mh_PasswordComp(pw)            vt 0x98   @ FUN_00541e70:  isPublic → 1; pw null → 0; strncmp(Password, pw, 8) == 0
so_mh_isPublic()                  vt 0xb4   @ FUN_00541e60
so_mh_GetVisitReadyInfo(ack)      vt 0x9c   @ FUN_00542270:  ack 0x8C0F { isPublic, visitercnt = EnterPlayerCount − 5, maxvisiter = MaxPlayer − 5 }

so_mh_Enter(p)                    vt 0x7c   @ FUN_00543cb0     → result code (dept 35)
    p null                                → 0x11A1 (no client text)
    !so_mh_CanEnter                       → 0x119F "Estate isn't available, please try again later."
    !so_mh_isAlreadyEnterPlayer(p)        → 0x11A4 (no client text: p or its character is already inside)
    p has StaGMHideMode (0x120):
        EnterGMCount >= 5                 → 0x119D "Destination full, unable to join."
        slot[4 − EnterGMCount] = p, charNo; EnterGMCount += 1  → 0x1181
    else:
        charNo in KickOutPlayerIndex      → 0x119C "Kicked user may not re-join a Estate they have been kicked …"
        EnterPlayerCount >= MaxPlayer     → 0x119D
        slot[EnterPlayerCount] = p, charNo; EnterPlayerCount += 1  → 0x1181
    # caller 0x8C10 VISIT_REQ (Z07 §6.5) sends the code as (35, 0x11, code) = 0x8C11 and links p in on 0x1181

so_mh_Out(p)                      vt 0x88   @ FUN_00543f40     → 1 removed / 0 not found
    if p.so_IsJoinThisGame(1) (vt 0x170, p plays the TaiSai table):
        remove p from GamerInfo (shift), nGamerCnt −= 1; p.so_SetMiniGameInfo(0) (vt 0x178);
        so_mh_RankSort (vt 0x1e4); so_mh_DiceTaiSai_Out(p, 0) (vt 0x22c)                 # Z06 §3
    if p has StaQuestEntangle (0x122, set while loading / decorating): reset it, recalc parameters (vt 0x650, asl_AbstateReset, vt 0x528)
    if p lacks StaGMHideMode: search slots 5 … EnterPlayerCount − 1; found → shift the rest down, clear the last, EnterPlayerCount −= 1, return 1
    else: search GM slots 4 … 0; found → shift, clear slot 5 − EnterGMCount, EnterGMCount −= 1, return 1
    return 0
    # (original bug) Z13-B4: the list is chosen by p's GM-hide state at exit time; a GM who toggles hide mode inside
    # is not found, stays in the array (stale pointer) and keeps a visitor / GM slot
    # the owner (slot 5) can be removed too, which shifts the first visitor into the owner slot; the only caller that
    # removes the owner is VISIT_REQ's failure path, which never runs for the owner (inferred)

so_mh_KickOut(charNo)             vt 0xdc   @ FUN_00544240
    KickOutPlayerCount > 19                  → 0x118F "Unable to kick anymore users"
    charNo not among slots 5 … count − 1     → 0x1192 "Unable to find a selected user"   (GMs cannot be kicked)
    charNo already in the kick list          → 0x1190 "User is already have been kicked"
    append to KickOutPlayerIndex             → 0x1181
    # the kicked player is not removed here: 0x8C12 (Z07 §6.6) links it out and so_mh_Out runs on its unmark.
    # The ban lasts as long as this house object (a new build starts with an empty list).
```

```pseudo
ShinePlayer::so_MH_LogOut()       player vt 0x8c   @ FUN_00570500
    # called from ShinePlayer::so_Unmark (FUN_00558900) when the player leaves the map (warp, link, logout) while
    # so_ply_MH_GetActiveMH (vt 0x130) is true
    h = GetObject(p.MHRegNum (vt 0x138)); none: return 0
    if h.owner charNo (vt 0x80) == p.charNo:                   # the owner leaves: the house closes
        exit = h.so_mh_GetRollBackLinkPos (vt 0x150)
        for i = EnterPlayerCount − 1 down to 6:                # visitors
            m ← SendErrorCode(35, 0x19, 0x1181) = 0x8C19 NC_MINIHOUSE_EXIT_ACK { 0x1181 }
            m.so_LinkTo(exit, 6, 9, 10); failure → log, m.so_Disconnect(0x685)
        for i = 5 − EnterGMCount … 4: same for the GMs
        p.so_ply_MH_SetMyHandle(0xFFFF); h.so_mh_RemoveMH(); return 1
    else:
        h.so_mh_Out(p)
        so_AllInMap(p, 0x8C0D NC_MINIHOUSE_LOGOUTCOMPLETE_CMD { u16 handle = p }, 0)        # the house members see p leave
        p.so_ply_MH_SetMyHandle(0xFFFF); return 0
```

Player house-link accessors *(pdb2016)*: `sp_MH_InnerInfo` at `p+0x5cf4` = `MiniHouseEntrance { u16 MHFlag (index in
queue_MH_InnerInfo), u16 MHRegNum (house handle, 0xFFFF outside), u8 isCastMiniHouse }`. `so_ply_MH_GetActiveMH`
@ FUN_005709f0 (vt 0x130, `MHRegNum ≠ 0xFFFF`), `so_ply_MH_SetMyHandle` @ FUN_00570a10 (vt 0x134),
`so_ply_MH_GetMyHandle` @ FUN_00570a30 (vt 0x138), `so_mh_GetMinihouse` @ FUN_00570b10 (= `GetObject(MHRegNum)`).
Z07 §6.1's `p+0x5cf4` "build record index", `+0x5cf6` "house handle" and `+0x5cf8` "build-cast flag" are these three fields.

```pseudo
so_mh_GetAllPlayerInfo(ack, viewerCharNo)   vt 0xa0   @ FUN_005422a0      # fills 0x8C0B LOGINCOMPLETE_ACK (Z07 §6.4)
    for i = 5 … EnterPlayerCount − 1 (owner and visitors, GMs never listed), non-null:
        ack.player[k] = { u8 level = m.so_GetLevel (vt 0x4d8), u16 handle = m }   (3 bytes each, after the 0x8C-byte head)
    ack.playernum = k
    owner = GetObject(owner handle); none → return 0 (the handler then still sends the ack)
    K = g_Now & 0x7FFFFFF
    ack.TargetKey = sprintf("%010u%010u%010u", K, K ^ viewerCharNo ^ 0x5C599A, K ^ ownerCharNo ^ 0x82783A)   (30 chars + NUL in char[32])
    ack.bItemInfoClose = isItemInfoClose; ack.sNotify = strncpy(Notify, 100); ack.maxvisiter = MaxPlayer − 5
    return 1
```

`TargetKey` is an obfuscated (viewer, owner) key; nothing in the zone reads it back. The 2017 enum lists OWNERBLOG
opcodes (0x8C35…0x8C3C) that the 2016 zone does not register; the key is probably for the owner's web page / blog link
*(inferred)*.

Other getters (one line each, all *(pdb2016)* names): `so_mh_GetOwner` @ FUN_005423c0 (vt 0x3c, owner name or null),
`so_mh_GetTitle` @ FUN_00542420 (vt 0x40), `so_mh_GetFurnitureInven(type)` @ FUN_00542430 (vt 0x4c; 3/13/14/16 → box, else
null), `so_mh_GetMaxInnerPlayer` @ FUN_00542230 (vt 0x58, `MaxPlayer` raw, +5 included), `so_mh_GetMemberPlayerRegistNumber`
@ FUN_005421d0 (vt 0x60), `so_mh_GetMemberPlayerHandleNumber` @ FUN_005421a0 (vt 0x64; the `ShineObject` default
@ FUN_00542190 returns 0xFFFF), `so_mh_GetMemberPlayer` @ FUN_005421f0 (vt 0x68), `so_mh_GetInnerPlayerCount` @ FUN_00542210
(vt 0x6c, raw `EnterPlayerCount`), `so_mh_GetInnerGMCount` @ FUN_00542220 (vt 0x70), `so_mh_GetBriefInfo` @ FUN_00542240
(vt 0x74), `so_mh_GetOwnerRegistNumber` @ FUN_00542180 (vt 0x80 = `EnterPlayerIndex[5]`), `so_mh_GetOwnerHandleNumber`
@ FUN_00542160 (vt 0x84, 0xFFFF without owner object).

```pseudo
so_mh_GetRollBackLinkPos()   vt 0x150   @ FUN_00541f20  → static LinkInformTemplete smh_StaticRollBackPos
    linktoserver = the outside map; FieldAttr found → linktoclient = its client map id, coord = loginloc.currentcoord
    (no FieldAttr: the static keeps the previous call's values and is still returned)
so_mh_GetEnterLinkPos()      vt 0x154   @ FUN_00542000  → static smh_StaticEnterPos
    linktoserver = EnterPos.entermapname; no FieldAttr → null
    client map id in MapInfo → linktoclient = it, coord = MapInfo.RegenX / RegenY (the interior's spawn point)
```

Links always use `so_LinkTo(link, 6, 9, 10)` (FUN_0049ad30, Z01). Every house shares the interior map name; the
instance a player sees is chosen by its `MHRegNum` (map broadcasts filter by house, Z09 §28.1).

### 1.4 Settings setters (owner requests of Z07 §6.8)

```pseudo
so_mh_reSetMaxPlayer(n)      vt 0xe4  @ FUN_00544500
    n == 0 or n >= 100            → 0x118B "Please reconfigure player number."
    n + 5 < EnterPlayerCount      → 0x118C "Not enough players... Unable to set player numbers"  (more people inside than n)
    MaxPlayer = n + 5             → 0x1181
so_mh_reSetPassword(pw)      vt 0xe8  @ FUN_00544610
    len = strnlen(pw, 9)
    strncmp(Password, pw, 8) == 0 → 0x11D5 "Your new password is same as before."
    len == 0                      → isPublic = 1, Password = "" → 0x11D6 "Room has changed to public room."
    len < 8                       → wasPublic = isPublic; isPublic = 0; Password = pw
                                    → wasPublic ? 0x11D7 "Room has changed to private room." : 0x11D5 (the same text as "unchanged")
    else (8 characters)           → 0x118A "Please re-enter password."
    # (original bug) Z13-B2: building accepts 8 characters (strncpy 8) but changing refuses them; a changed password
    # answers 0x11D5 "same as before"; the client's own 0x11D8 / 0x11D9 (too long / too short) are never sent
so_mh_reSetTitle(t)          vt 0xec  @ FUN_005448e0
    len(t) == 0 → Title = "" → 0x1181;   len > 20 → 0x1189 "Invalid title contents…";   else strcpy → 0x1181
so_mh_SendOutSideTitleCmd()  vt 0xf0  @ FUN_005447b0
    brief.title = Title (20 + NUL)                                     # later 0x1C13 / 0x1C14 carry the new title
    so_AllOfRange(house position) ← 0x8C31 NC_MINIHOUSE_MODIFY_OUTSIDE_TITLE_CMD { u16 house, char title[20], u8 0 }  (0x19 bytes)
so_mh_reSetItemInfoOpen(r)   vt 0xf4  @ FUN_00544a10:  isItemInfoClose = r.bItemInfoClose → 0x1181 (no check)
so_mh_reSetNotify(r)         vt 0xf8  @ FUN_00544a80
    r.nNotifyLen > 100 → 0x19C8 (no client text)
    strncpy(Notify, r.text, nNotifyLen) → 0x1181
    # (original bug) Z13-B5: no terminator is written; when the request text has no NUL within nNotifyLen, the tail of
    # the previous, longer notice stays in Notify (Notify[100] is always 0, so the string stays bounded)
```

This answers Z07-B13 in part: the house method refuses `nNotifyLen > 100`, so the 0x8C4A broadcast copies at most 100
bytes; the handler still does not compare `nNotifyLen` with the received packet length (Z07 §6.8).

### 1.5 House methods with no caller in the 2016 zone

The 2016 zone registers no handler for `NC_MINIHOUSE_KICKOUTCANCEL_REQ` 0x8C15, `ARRANGEMODE_REQ` 0x8C1A,
`COMPULSIONMOVETO_REQ` 0x8C28 or the OWNERBLOG opcodes 0x8C35/0x8C37 (`handlers.json`, dept 35), and the 2016 client
sends none of them (`opcodes.json`). No other code calls the slots below (scan of every virtual call `+ 0xa4/0xa8/0xe0/0x144`
in functions touching the house). They are documented for completeness:

```pseudo
so_mh_KickOutCancel(charNo)   vt 0xe0  @ FUN_005443e0:  remove from the kick list → 0x1181; not found → 0x118E "Selected player does not exist"
so_mh_SetArrangeMode(on)      vt 0xa8  @ FUN_00544b60
    unchanged → 0x11C5 "Invalid command.  Unable to execute."
    isArrageMode = on; for every visitor (slots 6 …, not the owner, not GMs): so_mh_SendArrangeMode(m)
    → on ? 0x11C2 "Changed to decoration mode." : 0x11C3 "Decoration mode has turned off."
so_mh_SendArrangeMode(m)      vt 0xac  @ FUN_00544c90
    on:  m gets StaQuestEntangle (0x122) for 4 200 000 000 ticks (frozen while the owner decorates), bit set, broadcast
    off: reset 0x122, recalc parameters
so_mh_CompulsionMoveTo(req { u16 hnd, SHINE_XY_TYPE location })   vt 0xa4  @ FUN_00543a40
    no owner → 0x11D3 "Invalid player info"; hnd == owner → 0x11D4 "You cannot move yourself"
    hnd not among slots 6 … → 0x11D2 "Selected player cannot be located"
    location inside one of the interior's areas "FURNITURE_ARE1…9" (AreaInfoData of smh_Info.Map) → 0x11D0 (no text) else 0x11D1
    "Invalid location have been selected.  Unable to move"        # nothing is moved; the result is only computed
so_mh_BroadcastNotify(text)   vt 0x144 @ FUN_00541eb0:  every member m: m.so_ply_Notice(text) (vt 0x784)
```

### 1.6 Player side: the mini-house item, `MiniHouseStr`, build queue

The player owns its house as an item in the mini-house box `sp_Item.itembag.ci_MiniHouse` (inventory type 12, slot 0
= the active house, slots 11+ = stored house items; slots 1–10 are skipped by both functions below).

```pseudo
sp_MakeMiniHouse()            @ FUN_0043eab0     # from sp_NC_MAP_LOGINCOMPLETE_CMD (FUN_00443390) on every map login
    id = itemdatabox.idb_specialid.sii_MiniHouse_MushRoom              # the default "mushroom" house
    if the mini-house box already holds an item with that id: return
    first unlocked empty cell of the box whose slot is 0 or > 10; none: return
    key = iti_mkregnum(id, 5, zoneNo, worldNo); attributes = item class default ("-o")
    → ItemDB 0x3467 NC_ITEMDB_CREATEMUSHROOM_REQ { ref, u16 lockindex, u32 owner, Name3 map, u32 x, u32 y,
         u16 cell = 0x3000 | slot, u64 key, u16 itemid, u16 attrLen, attributes }       (Z05 §1.7, D03)
    lock the cell (InvenCellReleaser via lock list vt 0x40), ++lock index
    # answers: 0x3468 → so_ply_MakeMiniHouse, 0x3469 fail (Z05 §9.5)

so_ply_MakeMiniHouse(ack)     player vt 0x3dc  @ FUN_0043f010    (Z05 §9.5)
    release the lock ack.lockindex; failure: log, return
    if box cell 0 holds an item: MiniHouseStr.mhs_Init(p, cell 0)

sp_NC_MAP_LOGINCOMPLETE_CMD (FUN_00443390, Z01) for the house: mhs_Backup.bib_Backuped = 0, mhs_Activ = 1, mhs_SkinHandle = null,
    sp_MakeMiniHouse(), then mhs_Init(cell 0) if cell 0 holds an item

MiniHouseStr::mhs_Init(p, cell) → code        @ FUN_00534a30   (also 0x8C01 ACTIV_REQ, Z07 §6.2)
    cell null → 0x1006
    row = the MiniHouse.shn row whose ItemID is cell's item id (ChargedItemEffectDataBox<MiniHouse>); none → mhs_SkinHandle = null, 0x1006
    mhs_SkinHandle = row
    row data: mhs_HPTick = HPTick × 10 / 1000, mhs_SPTick = SPTick × 10 / 1000 (ms → ticks of 1/10 s ÷ 10, i.e. ms / 100),
              mhs_HPInc = HPRecovery, mhs_SPInc = SPRecovery, mhs_BoothSlot = Slot
    (row without data: ticks 60000, increments 0, booth slots 0)
    mhs_DummyObject[10] = null
    → 0x1001
```

`MiniHouseStr` at `p+0x292ac` *(pdb2016)*: `BriefInfoBackup mhs_Backup` (+0, 0x2c: the saved character shape while the
house is up; Z07's "+0x292d7 saved flag" is `bib_Backuped`), `mhs_SkinHandle` (+0x2c), `mhs_DummyObject[10]` (+0x30),
`u16 mhs_HPTick, mhs_SPTick` (+0x58), `i32 mhs_HPInc, mhs_SPInc` (+0x5c), `i32 mhs_BoothSlot` (+0x64, the booth size bonus,
Z06), `u8 mhs_Activ` (+0x68; written by map login, 0x8C01 and `sp_MiniHouseActivCheck`, read by nothing in the 2016 zone).
Readers of the other fields: `sp_MakeTentBriefInfo` @ FUN_0056e720 (Z02 §7: camp brief = `{u16 minihouse = row.Handle,
10 × 0xFF}`, fails without a skin), `so_ply_StreetBoothSlot` @ FUN_0055a2d0 (player vt 0x494, Z06 §2: booth slots =
min(20, charged-item bonus + mhs_BoothSlot)) and the rest-mode recovery below.

```pseudo
sp_RecoverPoint_House()       @ FUN_0056b3b0    # p.recoverFunc (+0x29628) while resting in the tent / house (Z02 §7, Z09 §2.4)
    if smo_GetMode (vt 0x484) ≠ 4 (rest): return
    hpStep = mhs_HPInc × smo_Recover.maxhp (+0xea8) / 1000;  spStep = mhs_SPInc × smo_Recover.maxsp (+0xeac) / 1000
    if smo_Recover.lasthp (+0xea0) + mhs_HPTick < g_Now:
        HP += stat(p+0x19a0) × hpStep / 1000 (vt 0x5b4); lasthp = g_Now
    if smo_Recover.lastsp (+0xea4) + mhs_SPTick < g_Now:
        SP += stat(p+0x1740) × mhs_SPTick / 1000 + spStep (vt 0x5b8); lastsp = g_Now
        # (original bug) Z13-B6 (checked in the assembly at 0x56b4f8): the SP gain multiplies by the tick interval
        # instead of applying the rate to spStep as the HP line does
    if HP or SP changed: so_AllOfRange(… so_ply_Send2WhoTargetMe)                 # HP/SP to p and whoever targets p
    if the pet is out (sp_PetInfo.nSummonState 1st-summoned / resummoned) and sp_Pet_HouseTick is due:
        advance the tick; sp_PetSystem_ChangeTendency(PFC_S_RESTHOUSE)             # pet mood, §5
```

`MiniHouse.shn` row *(pdb2016)*, 0x6F bytes: `u16 Handle, char ItemID[32], char DummyType[32], char Backimage[32],
u16 KeepTime_Hour, u16 HPTick, u16 SPTick, u16 HPRecovery, u16 SPRecovery, u16 Casting, u8 Slot`.
Loader `ChargedItemEffectDataBox<MiniHouse>::cideb_Load` @ FUN_005af4d0 (`BinaryDataBox<MiniHouse>::bdb_ReadData`
@ FUN_005ae840; deleting dtors FUN_0044fbf0 / FUN_0044fc20): one `{u16 ce_ItemID, MiniHouse* ce_Data}` per row, item id
from `ItemID` (unknown item → assert + `ShineExit`), duplicate `Handle` → `ShineExit`
((original bug) Z13-B1: the duplicate test only compares row k with rows 0 … k−2, so two adjacent rows with the same
Handle pass); items whose class is not ACTIONITEM / GBCOIN / CAPSULE get a charged-buffer use effect
(`uie_SetChargedBuffer`). `cideb_GetItemID(id)` @ FUN_00531820: linear search by item id. The same template loads
`MiniHouseFurniture.shn` (FUN_005af6d0, §2).

```pseudo
sp_MiniHouseActivCheck()      @ FUN_00534fe0     # player so_Routine (Z09 §2.4), only while mhs_SkinHandle is set
    ok = 1
    for slot 0 … 0x22 of the mini-house box (cells 0x3000 | slot):
        if the cell is locked: ok = 0; continue
        if slot == 0 or mhs_DummyObject[slot − 1] (always null in 2016, so only slot 0 counts):
            t = the item's time attribute (attr vt 0x34)
            if t exists and its first byte == 0 (time not started yet):
                row = MiniHouse row of the item; none: continue
                t = (KeepTime_Hour == 0) ? 0x76BBECFF (marker: permanent) : packed date of now + KeepTime_Hour h
                lock the cell; → ItemDB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ { ref, u16 lockindex, item key + id, new attributes }   (Z05)
                ++lock index
    mhs_Activ = !ok …   # as read: mhs_Activ = (ok == 0), i.e. 1 when some cell was locked (inferred: "a DB change is pending")
```

Moving a house item from the inventory into the box: `UseEffect::UseItemMiniHouse::uib_DirectUse` @ FUN_00599450 (the
item's use effect) → `sp_Move2MiniHouse(slot, item)` @ FUN_00596fe0: the inventory cell must still hold that item key,
then `sp_Move2MiniHouse(cell, slot)` @ FUN_00534880 (first empty box slot > 10 → `irm_Move` inventory (0x2400 | slot) →
box (0x3000 | slot)); always `so_ply_ItemUseResultPacket(0x700, 9)` (vt 0x91c, the item-use result; codes Z04 §6).
The furniture counterpart `UseItemMiniHouseFurniture::uib_DirectUse` @ FUN_00599500 calls player vt 0x48
`so_mh_Move2MiniHouseFurniture` (§2).

Build queue: `queue_MH_InnerInfo` (`MemoryQueue<MemoryMiniHouseEntrance>`, 0x80 elements; Z07 called it
`g_MiniHouseBuild`): each element = `{u16 handle, MemoryMiniHouseEntrance { char Title[21], char Password[9],
u8 MaxPlayer, u8 bItemInfoClose, char sNotify[101] }}`. 0x8C03 stores the request there and sets `MHFlag` to its index and
`isCastMiniHouse = 1` (Z07 §6.3). `sp_MiniHouseGetMHInfo` @ FUN_00575d10: `MHFlag < 0x80` and the element's handle == p
→ element; else log and null (the build then fails). `sp_MiniHouseFree` @ FUN_0045d420 (from `so_ply_AllCastCancel`
FUN_0055a310, i.e. the build cast is interrupted): clear the time scheduler `sp_TimerStr` (the 5-s build timer of
Z07 §6.3; `ts_Limit = 0`, no-op functions, `TSCW_NONE`), `isCastMiniHouse = 0`, p ← `0x2048 NC_ACT_CANCELCASTBAR`
(`so_SendProtocol(8, 0x48)`).

### 1.7 Brief info: `0x1C13` / `0x1C14`

`BriefInformationMiniHouse` ctor @ FUN_00549190: a 0x43-byte packet buffer, length 0x42, opcode `0x1C13
NC_BRIEFINFO_MINIHOUSEBUILD_CMD`, body = the 0x40-byte `PROTO_NC_BRIEFINFO_MINIHOUSEBUILD_CMD` of §1.2 (client handler
GameFrameWork FUN_006c09e0). It is sent single when a house appears to one viewer (`so_SendMyBriefInfo`).

Sight exchange (Z02 §5.2, `BriefInfoExchanger`; kind 3 = mini-house):

```pseudo
bixmh_Exchange(a, b)   @ FUN_004403e0
    a and b on the same main layer (or either −1):
        if so_SubLayer_CanSee(a, b): a.so_SendMyBriefInfo(b) (vt 0x4c8)
        if so_SubLayer_CanSee(b, a) and a is a player (vt 0x4d0 == 2):
            if the batch already holds 28 entries: bixmh_Send(a), count = 0
            append b.so_FillBriefInformation (0x40 bytes) to a's batch
bixmh_Send(a)          @ FUN_0043dc90
    count > 0, a is a player and a.smo_GetMode (vt 0x484) ≠ 0:
        a ← 0x1C14 NC_BRIEFINFO_MINIHOUSE_CMD { u8 count, PROTO_NC_BRIEFINFO_MINIHOUSEBUILD_CMD × count }   (3 + 0x40 × count bytes)
```

Client: 0x1C14 → GameFrameWork FUN_004999c0 (C01).

### 1.8 ShineMiniHouse vtable: status of every slot Z07 lists

From the RTTI vftable of `ShineObjectClass::ShineMiniHouse` (933 slots, `rtti.py`) and the PDB function names.
Slots that are not overridden hold folded one-line `ShineObject` defaults (the PDB name of a folded body is arbitrary);
their real behaviour is the body:

| Slot | Function | Status |
|---|---|---|
| 0x3c, 0x40, 0x4c, 0x58–0x74, 0x80, 0x84 | getters (§1.3) | documented |
| 0x44 | `so_mh_Move2MiniHouseFurniture` FUN_005354a0 | §2 |
| 0x54 | `so_mh_GetItemCellByFurnitureHandle` FUN_00547700 | §2 |
| 0x5c | `so_mh_RemoveMH` | §1.2 |
| 0x78 | `so_mh_BuildingMiniHouse` | §1.2 |
| 0x7c / 0x88 | `so_mh_Enter` / `so_mh_Out` | §1.3 |
| 0x8c | default: returns 0 (FUN_004b8d20) | not overridden |
| 0x90 / 0x94 / 0x98 / 0x9c / 0xa0 | isAlreadyEnterPlayer / CanEnter / PasswordComp / GetVisitReadyInfo / GetAllPlayerInfo | §1.3 |
| 0xa4 / 0xa8 / 0xac | CompulsionMoveTo / SetArrangeMode / SendArrangeMode | §1.5 (no caller) |
| 0xb0 | default: **returns 1** (FUN_005af8d0) | not overridden. Z07 §6.7's `if !h.vt[0xb0]()` (reset StaQuestEntangle after the furniture list) is therefore never taken: the abstate is removed only by `so_mh_Out` |
| 0xb4 | `so_mh_isPublic` | §1.3 |
| 0xb8 / 0xbc / 0xc0 / 0xc4 | ReArrange / Create / Delete furniture, GetNextFurnitureHandle | §2 |
| 0xc8 | default: returns 0xFFFF (FUN_005550b0) | not overridden |
| 0xcc, 0xd4 | defaults (return 0 / no-op) | not overridden |
| 0xd0 | `so_mh_SaveMHInven` FUN_005435d0 | §2 |
| 0xd8 | `smh_SendFurnitureInfo` FUN_00546930 | §2 |
| 0xdc / 0xe0 | KickOut / KickOutCancel | §1.3 / §1.5 |
| 0xe4–0xf8 | setters | §1.4 |
| 0xfc, 0x100 | defaults (no-op) | not overridden (the player's vt 0xfc / 0x100 are the DB portal answers, Z07 §6.12) |
| 0x104–0x124, 0x12c | portals | §3 |
| 0x128 | default: no-op (FUN_00549070) | not overridden; Z07's "player vt 0x128 so_MH_PortalEffectApply" is a player slot (§3) |
| 0x144 | `so_mh_BroadcastNotify` | §1.5 (no caller) |
| 0x14c / 0x4bc | `so_LoginLocation` | §1.1 |
| 0x150 / 0x154 | rollback / enter link | §1.3 |
| 0x158 | `so_mh_CanObjAni` FUN_005424a0 | §3 |
| 0x15c | default: no-op (FUN_00549070) | not overridden; the furniture effect is slot **0x160** `so_mh_EffectApply` FUN_00542520 (§3) |
| 0x164 / 0x168 / 0x16c | endurance | §3 |
| 0x1bc–0x2a8 | TaiSai | Z06 §3 (0x2a0 = `so_mh_DiceTaiSai_GetGameStatus` FUN_00514a20: 0 no bets, 1 betting, 2 rolling, 3 stand-by) |
| 0x2d8–0x2e4 | furniture emotions | §3 |
| 0x4a4 / 0x4ac / 0x4c4 / 0x4c8 / 0x4d0 / 0x768 | RemakeHandle / so_Routine / FillBriefInformation / SendMyBriefInfo / ObjectType / TentDistance | §1.1, §1.2 |

Z07 §6.1 corrections: vt 0x90 is "p (or its character) is not inside yet" (false → 0x1185 in VISITREADY / VISIT, not
"full"); "furniture usable" vt 0x158 is `so_mh_CanObjAni`.

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z13-B1 | `ChargedItemEffectDataBox<T>::cideb_Load` (MiniHouse, MiniHouseFurniture, …) | duplicate-Handle test compares row k only with rows 0 … k−2 | two adjacent rows with the same Handle load without the intended `ShineExit` | compare with rows 0 … k−1 |
| Z13-B2 | `so_mh_reSetPassword` (0x8C2B) | 8-character passwords refused (0x118A) although building accepts 8; a changed private password answers 0x11D5 "same as before" | owner cannot re-set an 8-character password; misleading text | accept len ≤ 8; distinct success code / the client's 0x11D8 / 0x11D9 |
| Z13-B3 | `ShineMiniHouse::so_Routine` portal expiry | index advances after removing an entry | the next expired portal is removed 30 s later | do not advance after a removal |
| Z13-B4 | `so_mh_Out` | member list chosen by the GM-hide abstate at exit time | a GM who toggles hide mode inside stays in the array (stale pointer, slot kept) | remember which list the player joined |
| Z13-B5 | `so_mh_reSetNotify` (0x8C48) | `strncpy` without terminator over the old notice | the old notice's tail can survive a shorter new one | clear `Notify` first |
| Z13-B6 | `sp_RecoverPoint_House` | SP gain = stat × SPTick / 1000 + SPInc × maxSP / 1000 (HP: stat × (HPInc × maxHP / 1000) / 1000) | house SP regeneration does not follow the MiniHouse.shn SPRecovery rate the way HP does | same formula as HP |

## Not reconstructed / uncertain

- `so_mh_Out` on the owner: whether any path removes slot 5 while visitors remain (it would promote the first visitor to
  "owner" for every owner check) was not found; only VISIT_REQ's failure path calls `so_mh_Out` outside `so_MH_LogOut`.
- When the owner leaves, `so_MH_LogOut` frees the house at once (`REMOVE_NOW`) while the visitors' links are still pending;
  their `MHRegNum` is not reset here. What their own `so_MH_LogOut` then finds (no object, or a new house reusing the
  handle) was not traced.
- `so_Routine`'s "invalid MH handle" branch sets the member's handle back to this house before linking it out; the intent
  (so that the member's unmark runs `so_MH_LogOut` → `so_mh_Out` for this house) is *(inferred)*.
- `sp_MiniHouseActivCheck`: the meaning of `mhs_Activ` (set when a cell was locked) is *(inferred)*; its readers are
  outside this part.
- `CompulsionMoveTo`: the `%c` argument of `"FURNITURE_ARE%d%c"` was not recovered (dead code).

## Coverage boundary

(Filled in by the sweep part.)
