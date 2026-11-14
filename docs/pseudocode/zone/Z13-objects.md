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

## 2. Furniture (house boxes, placement, furniture lists)

### 2.1 Data

**Boxes.** `smh_Furniture` (`MiniHouseInven`, +0x5c4) = `u16 FurnitureHandle` + four `ItemFurnicherBox` (each 98 cells
of 0x74 bytes, `ib_BagSizeInput` @ FUN_006433d0 / `ib_BagSizeOutput` @ FUN_006433e0 = 0x62; the cell getter
`ItemInventory::ib_GetInventoryCell` @ FUN_00643000 returns a shared static cell for an index past the end, never null):

| Index | Box | Inventory type (`ITEM_INVEN.Inven >> 10`) | `MiniHouseFurniture.InvenType` |
|---|---|---|---|
| 0 | `FurnitureInven` | 3 | `FURNITURE` |
| 1 | `AccessoryInven` | 13 | `ACCESSORY` |
| 2 | `TileAllInven` | 14 | `TILEALL` |
| 3 | `MiniGameInven` | 16 | `MINIGAME` |

Every furniture loop below walks these four boxes in this order with an `ItemBoxIterItem` (cells that hold an item;
limit = the owner's charged-effect container `vt 0x498`, else the box size). 4 × 98 = 392 cells is the limit behind
the `count < 0x189` checks. The player's own mini-house item box (inventory type 12, `0x3000 | slot`, §1.6) is an
`ItemMiniHouseBox` of 35 cells (ctor @ FUN_00644980, dtor @ FUN_00643210, sizes @ FUN_00643270 / FUN_0063e4e0 = 0x23).

**Furniture item attribute** `ShineItemAttr_Furniture` *(pdb2016)*, 0x24 bytes at cell +10 (cell = `ItemInventoryCell`:
+0 `SHINE_ITEM_REGISTNUMBER` key (8), +8 `u16 itemid`, +10 attribute, +0x70 `iic_AttrProc` attribute class):

| Cell off | Attr off | Field | Meaning |
|---|---|---|---|
| +0x0a | +0x00 | `flag.IsPlaced` (bit 0) | 1 = placed in the room |
| +0x0b | +0x01 | `u16 furnicherID` | the **furniture handle** (per house instance, not saved meaningfully: re-assigned at every load) |
| +0x0d | +0x03 | `ShineDateTime deletetime` | expiry of a time-limited furniture (0 = not started, `0x76bbecff` = never) |
| +0x11 | +0x07 | `float LocX, LocY, LocZ, Direct` | position and direction |
| +0x21 | +0x17 | `ShineDateTime dEndureEndTime` | end of the durability period (§3) |
| +0x25 | +0x1b | `u8 nEndureGrade` | durability grade; > 3 blocks every edit (0x11E2) |
| +0x26 | +0x1c | `u64 nRewardMoney` | not used by the furniture code read here |

`ShineDateTime` packing (as written here): bits 0–7 year − 100 (`tm_year + 0x9c`), 8–12 month (1–12), 13–18 day,
19–24 hour, 25–30 minute; `0x76bbecff` is the "never" value.

`ItemAttrCls_Furniture` (attribute class, vtable of 51 slots): vt 0x04 `iac_fill2buffer` @ FUN_0063e870 / vt 0x08
`iac_fill2struct` @ FUN_0063ea50 (copy the 0x24 bytes), vt 0x0c attribute size = 0x24 (folded body FUN_0063ec30),
vt 0x14 `iac_itemcreate` @ FUN_0063f0b0 (a new furniture: not placed, handle 0, **default location (276.0, 388.0, 6.0),
direction 0**, all times, grade and reward 0), vt 0x34 `iac_GetDeteleDateTime` @ FUN_0063e3e0 (→ attr+3), vt 0x8c
`iac_GetEndureEndTime` @ FUN_0063e400 (→ attr+0x17), vt 0x88 `iac_SetFurnitureKey` @ FUN_0063fd30 (handle), vt 0x94
`iac_SetEndureEndTime(item, ShineDateTime)` @ FUN_0063fd50 (copy), vt 0x98 `iac_SetEndureGrade` @ FUN_0063ff40, and

```pseudo
iac_SetEndureEndTime(item, addHours, maxHours, now):   @ FUN_0063fda0 (vt 0x90)
    t = &item.attr.dEndureEndTime ; null item → 0
    if maxHours == 0: *t = never (0x76bbecff)
    elif year byte of *t ≠ 0xFF:                       # "never" stays never
        cap = now + maxHours h
        if *t is set (year byte ≠ 0): end = min(max(*t, now) + addHours h, cap)   # extend, but never past now+max
        else: end = cap
        *t = pack(end)
    return 1
```

**`MiniHouseFurniture.shn`** (89 rows; `ChargedItemEffectDataBox<MiniHouseFurniture>` `minihousefurnituredatabox`, loaded by
`cideb_Load` @ FUN_005af6d0 from `../9Data/Shine/MiniHouseFurniture.shn` at zone start (`zs_start_tough`): every row's
`ItemID` (inx name) must resolve in `itemdatabox`, else `ShineExit`; the duplicate-Handle test is Z13-B1; for each item
whose class is not ActionItem / GBCoin / Capsule the box registers its use effect with `uie_SetChargedBuffer`).
Columns *(pdb2016)*: `Handle, ItemID[32], FurnitureType[32], InvenType[32], GameType (0 GT_NOGAME, 1 GT_DICE), CanSet,
Backimage[32], WALL, BOTTOM, CEILING, IsAnimation, Weight, KeepTime_Hour, KeepTime_Endure, Grip, MaxSlot, MHEmotionID`.
The 2016 table: 64 FURNITURE, 4 ACCESSORY, 6 TILEALL, 6 MINIGAME (row 900 `IN_MoneyCard00` with `CanSet = 0`, rows
901–905 dice tables GT_DICE, KeepTime_Hour 168 / 720), 9 PORTAL (rows 1000+, 168 h); 69 rows use `KeepTime_Endure = 1`
(`MiniHouseEndure` row 1: `Endure = {720, 384, 48, 0}` hours), the others 0 (row 0: all 0). Lookups: by item id with a
linear scan (`cideb_GetItemID` @ FUN_00543400, or an inline scan with a `ChargedItemEffectFinger`, `cideb_Next`
@ FUN_00514ae0, `cideb_GetIndex` @ FUN_00514b10 → element or null).

**Furniture handles:** `so_mh_GetNextFurnitureHandle` @ FUN_0056ffa0 (house vt 0xc4) returns `FurnitureHandle++`; the
player's `so_MH_GetNextFurnitureHandle` @ FUN_0056ffd0 (player vt 0xc8) forwards to the house it is in (not in a house /
house gone: log, 0xFFFF). SaveMHInven numbers every loaded item (attr vt 0x88), new arrivals get one in §2.6. The portal
pseudo-furniture uses the fixed handle 60000 (Z07 §6.8).

### 2.2 Loading the boxes and sending the furniture lists

```pseudo
DB answer 0x1077 NC_CHAR_GET_ITEMLIST_BY_TYPE_ACK, type ∈ {3, 13, 14, 16} (Z07 §10.1):
    p.so_MH_SaveMHInven(list, type)                    @ FUN_00570260 (player vt 0xcc)
        p not in a house: log, 0;  house gone: log "] does not get the minihouse", 0
        house.so_mh_SaveMHInven(list, type)            (house vt 0xd0) → 1

so_mh_SaveMHInven(list PROTO_NC_CHAR_ITEM_CMD, type):  @ FUN_005435d0
    box = the box of `type`
    if list.nPartMark & 1 (first part): clear box
    ib_Initializetotal(box, list)                      # store the items
    if list.nPartMark & 2 (last part):
        owner must exist (else return 0)
        for each item with an attribute class:
            attr.vt[0x88](cell, FurnitureHandle++)                       # new handle per load
            row = MiniHouseFurniture by item id
            grade = mhe_CalEndureGrade(row.KeepTime_Endure, attr.vt[0x8c] end time)   (§3)
            if grade ≠ 0: attr.vt[0x98](grade)
            if type == 16 and row.GameType == GT_DICE and cell.IsPlaced and no dice active:
                house.so_mh_InitActiveDiceInfo(cell) (vt 0x1c0, Z06 §3)
            failure in this loop → return 0
        CanEnter += 1                                  # 4 boxes + the portal list → ≥ 5 = ready (§1.3)
        house.smh_SendFurnitureInfo(owner)             (vt 0xd8)
```

`smh_SendFurnitureInfo(viewer)` @ FUN_00546930 (house vt 0xd8). Callers: SaveMHInven above (every box load; only the
load that brings `CanEnter` to 5 gets past the first check), the portal-list answer (Z07 §6.12, `so_ply_MH_SetMHPortalList`
@ FUN_0056f660) and `NC_MINIHOUSE_LOGINCOMPLETE_REQ` (Z07 §6.4, every member entering).

```pseudo
smh_SendFurnitureInfo(viewer):
    if !so_mh_CanEnter() (CanEnter < 5): return 0
    owner = GetObject(house owner handle vt 0x84); none → return 0
    if viewer.charNo == house owner charNo (vt 0x80):           # the owner gets his four boxes
        for box in (3, 13, 14, 16):
            viewer ← 0x8C08 NC_MINIHOUSE_FUNICHERINVEN_CMD {
                u8  numofitem                         # filled by ci_FillBufferInventoryItem
                u8  box = inventory type
                u8  flag                              # never written: (original bug) Z13-B11
                PROTO_ITEMPACKET_INFORM × n { u8 datasize, u16 location = box<<10 | slot, SHINE_ITEM_STRUCT } }
              (so_fullbufferitem_box @ FUN_00559a70 → CharacterInventory::ci_FillBufferInventoryItem @ FUN_00643d40,
               max 8000 bytes; sent on the viewer's data socket, vt 0x2f8)
        for each cell of the four boxes (owner's iterator limit):
            row = MiniHouseFurniture by item id; no row: skip
            want = InvenType → 3 / 13 / 14 / 16 (FURNITURE / ACCESSORY / TILEALL / MINIGAME);
                   any other InvenType leaves `want` uninitialised / at the previous cell's value: (original bug) Z13-B9
            if want ≠ this box: so_mh_Move2MiniHouseFurniture(viewer, cell, slot, this box) (vt 0x44, §2.6); next cell
            if !InFurnitureArea(cell.LocX, cell.LocY, cell.LocZ) (§2.3):       # checked for every cell, placed or not
                copy = cell; copy.IsPlaced = 0; copy.Loc = (276.0, 388.0, 6.0); copy.Direct = 0
                owner lock list (vt 0x7d4).icl_StoreFurniture(lock, cell, copy, box<<10|slot)   (vt 0x68, releaser §2.5)
                → GameDB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ (§2.4 layout, static 0x81-byte buffer); lock index += 1
              # unplaced furniture lies at the default location (z = 6.0 < 700), so every unplaced item is "reset" and
              # written again on every owner load: (original bug) Z13-B8
        return 1
    else:                                                       # visitors and GMs: only what is placed
        viewer ← 0x8C09 NC_MINIHOUSE_FUNICHER_CMD {
            u8 furniturecount = n (& 0xFF)                     # up to 392 placed items: (original bug) Z13-B10
            u8 next = 0xFF                                     # always a single, final packet
            { u16 furniturehandle, u16 furnitureid (item id), f32 x, y, z, angle, u8 nEndureGrade } × n }   (21 bytes each)
        return 1
```

Client *(2016 client, FUN_0049b510 / FUN_004af160)*: 0x8C08 decodes each item into the house inventory box and creates
the room model of every item with `IsPlaced` (handle, item id, position, direction, grade); after the packet it sends
`0x8C1D NC_MINIHOUSE_FUNITUREINFOCOMPLETE_REQ {1}` (so the owner sends it four times; Z07 §6.7). 0x8C09 creates a model
per entry (failure → text "Estate furniture file error") and sends `0x8C1D {1}` when `next == 0xFF`.

### 2.3 Placement area

```pseudo
InFurnitureArea(x, y, z):   (inline in so_mh_CreateFurniture, so_mh_ReArrangeFurniture, smh_SendFurnitureInfo)
    for i in 1 … 9:
        a = interior map's AreaInfoData area "FURNITURE_ARE<i>"   # sprintf("FURNITURE_ARE%d%c", i, 0)
        if a and a.contains(round(x), round(y)) (area vt 0, coordinates taken as unsigned): break
    if no area matched (i == 10) or z < 700.0 or z > 900.0: return false      → 0x11CD in the requests
    return true
```

### 2.4 Create, rearrange, delete (house vt 0xbc / 0xb8 / 0xc0)

Called by the owner requests of Z07 §6.8 (`InHouseOwner` prefix, cmd 0x23 / 0x20 / 0x26) with `payload + 0`. None of the
three handlers (@ FUN_00572bf0, FUN_00572d50, FUN_00572eb0) compares `furniturecount` with the packet length: up to 392
entries (7 KB) are read past a short packet (original bug) Z13-B7. A result other than 0x11C1 goes back as the ACK
(0x8C23 / 0x8C20 / 0x8C26 `{u16 err}`); 0x11C1 sends nothing at once: one ACK + CMD per item follows from the releaser
when the DB confirms (§2.5).

Request entries: CREATE and REARRANGE `{u8 furniturecount, {u16 furniturehandle, f32 x, y, z, angle} × n}` (18 bytes each),
DELETE `{u8 furniturecount, u16 furniturehandle × n}`.

```pseudo
so_mh_CreateFurniture(p, req):   @ FUN_00544f00
    if !house.vt[0xb0]() → 0x11C6          # vt 0xb0 is the default "return 1": dead (§1.8)
    if req.furniturecount ≥ 393 → 0x11E0   # no client text
    pass 1, per entry e:
        if !InFurnitureArea(e.x, e.y, e.z) → 0x11CD "You may not place an item at an invalid location."
        find the first cell (boxes in order) whose furniture handle == e.furniturehandle; none: entry not counted
        cell.IsPlaced → 0x11E1 "Please cancel all current operation and try again."
        cell.nEndureGrade > 3 → 0x11E2 "…the furniture's durability is lack."
        if box index 3 (MiniGame):
            row = MiniHouseFurniture by item id; no row → 0x11CA "Invalid item"
            if row.GameType == GT_DICE and (a dice table is active (ActiveDice key ≠ −1 and cell set) or Reserve.bIsCreateDice):
                → 0x1DC0 "You are not able to setup more than 1 Dice Game."
            if !row.CanSet → 0x1DC1 (no client text)
        if p's lock list (vt 0x7d4).vt[8](box<<10|slot) (cell locked) → 0x11C7 "Item is currently being moved"
        found += 1
    if found ≠ furniturecount → 0x11CB "Item does not exist."
    pass 2, per entry (re-finds the slot of the same handle in its box, slots 0 … 97; not found: entry skipped):
        copy = cell; copy.IsPlaced = 1; copy.handle = e.handle; copy.Loc/Direct = e.x, y, z, angle
        row = MiniHouseFurniture by item id; no row → return 0x11CA   # earlier entries are already locked and sent: (original bug) Z13-B12
        if copy.dEndureEndTime not set (year byte 0):                  # first placement starts the durability clock
            e0 = MiniHouseEndure[row.KeepTime_Endure].Endure[0]
            if attr.vt[0x90](copy, e0, e0, now): grade = mhe_CalEndureGrade(row.KeepTime_Endure, end, &step) (§3);
                grade ≠ 0 → attr.vt[0x98](copy, grade)
        if box type 16 and row.GameType == GT_DICE: house.so_mh_SetIsCreateDice(1, cell key) (vt 0x1e8, Z06 §3)
        p lock list.icl_StoreFurniture(lockindex, cell, copy, key, key)   (vt 0x68 @ FUN_00489020: entry with the
            FurnitureReloc releaser, the new item copy and both locations; "List Full" → assert only)
        → GameDB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ { NETPACKETZONEHEADER {u16 p.handle, u32 p.charNo}, u16 lockindex,
              SHINE_ITEM_REGISTNUMBER key, SHINE_ITEM_STRUCT {u16 itemid, attr[0x24]} }   (pp length 0x14 + 0x24)
        lock index += 1
    return 0x11C1

so_mh_ReArrangeFurniture(p, req):   @ FUN_00546150
    same checks as create pass 1 except: cell must already be placed (not placed → 0x11E1), no MiniGame / dice / CanSet checks
    pass 2: copy with the new position (IsPlaced stays 1), icl_StoreFurniture + 0x3449 as above; no endurance or dice step
    return 0x11C1 (0x11C6 / 0x11E0 / 0x11CD / 0x11E1 / 0x11E2 / 0x11C7 / 0x11CB as in create)

so_mh_DeleteFurniture(p, req):   @ FUN_00545a40   (no area check)
    0x11C6 (dead) / count ≥ 393 → 0x11E0
    pass 1, per handle: find the cell as above (none: not counted)
        !cell.IsPlaced → 0x11E1
        box index 3 and the cell is the active dice table (key == ActiveDice key, or cell == ActiveDice cell):
            if TaiSai nGameStatus ∈ {DTGS_ROLLING, DTGS_STAND_BY}: house.so_mh_SetIsBlowGame(1) (vt 0x1f8)
                → 0x1DC2 "Reserved to remove Dice Game."
            else house.so_mh_SetIsDeleteDice(1, key) (vt 0x1f0)    # set before the remaining entries are checked: (original bug) Z13-B12
        cell locked → 0x11C7;  found += 1
    found ≠ count → 0x11CB
    pass 2: copy = cell with IsPlaced = 0 (position kept); icl_StoreFurniture + 0x3449; lock index += 1
    return 0x11C1
```

Duplicate handles inside one request are not rejected: each copy is locked and written separately *(inferred effect: two
pending entries on one cell; the lock list was not checked for this)*.

### 2.5 Releasers: what the DB confirmation shows

The `0x344A NC_ITEMDB_ITEMCHANGE_ACK` handler (Z05 §5.4) applies (`err == 0x901`) or frees the lock.

```pseudo
InvenCellReleaser_FurnitureReloc::icr_Apply(p, lockedCell):   @ FUN_0048a560
    was = cell.IsPlaced (before);  now = new item.IsPlaced
    InvenCellReleaser_CellChange::icr_Apply (Z05 §1.4: the copy is written into the cell, client 0x3001/0x3002)
    was 1, now 1 (rearrange):
        p ← 0x8C20 NC_MINIHOUSE_REARRANGE_ACK {u16 0x11C1}          (so_SendErrorCode 35/0x20)
        house map (so_AllInMap(p, …, 1): every member incl. p) ← 0x8C21 NC_MINIHOUSE_REARRANGE_CMD
            { u8 1, u16 furniturehandle, f32 x, y, z, angle }        (19 bytes)
        house.so_mh_FurnitureEmotionStop(handle, p) (vt 0x2e0, §3)   # sitters stand up
    was 1, now 0 (delete, or an owner-load reset of a placed item):
        p ← 0x8C26 NC_MINIHOUSE_DELETE_FURNITURE_ACK {0x11C1};  house map ← 0x8C27 NC_MINIHOUSE_DELETE_FURNITURE_CMD
            { u8 1, u16 furniturehandle }
        if p is in a house and house.so_mh_IsDeleteDice(key) (vt 0x1f4):
            so_mh_DiceTaiSai_BroadGameFold (vt 0x29c), so_mh_InitDiceInfo (vt 0x1bc), so_mh_SetIsDeleteDice(0, −1) (Z06 §3)
        house.so_mh_FurnitureEmotionStop(handle, p)
    was 0, now 1 (create):
        p ← 0x8C23 NC_MINIHOUSE_CREATE_FURNITURE_ACK {0x11C1};  house map ← 0x8C24 NC_MINIHOUSE_CREATE_FURNITURE_CMD
            { u8 1, u16 furniturehandle, u16 furnitureid, f32 x, y, z, angle, u8 nEndureGrade }   (22 bytes)
        if p is in a house and house.so_mh_IsCreateDice(key) (vt 0x1ec):
            so_mh_InitActiveDiceInfo(cell) (vt 0x1c0), so_mh_SetIsCreateDice(0, −1) (vt 0x1e8)
        if the furniture has a KeepTime and its deletetime is not started: compute deletetime = now + KeepTime_Hour (or
            never) — into a stack copy of the cell, so it is lost: (original bug) Z13-B13; the clock starts at the next
            smh_FurnitureActiveCheck (§2.7, ≤ 30 s)
    was 0, now 0: nothing (the owner-load reset of an unplaced item)

InvenCellReleaser_FurnitureReloc::lc_Free(p):   @ FUN_00487910   (DB refused / lock freed)
    p ← 0x8C20 NC_MINIHOUSE_REARRANGE_ACK {0x11CE "You may not place an item at an invalid location."}
    # also for a failed create or delete: (original bug) Z13-B14

InvenCellReleaser_FurnitureCellClear::icr_Apply(p, lockedCell):   @ FUN_0048aa60
    # chosen by icl_ClearItem @ FUN_00488a10 (lock list vt 0x30) for cells of inventory types 3 / 13 / 14 / 16
    if the exchange location == the current location (the item is removed, not moved):
        p ← 0x8C26 {0x11C1};  house map ← 0x8C27 { u8 1, u16 furniturehandle }
    InvenCellReleaser_CellClear::icr_Apply (Z05 §1.4)
```

Client *(2016 client)*: the three ACKs (FUN_0049b3d0 / FUN_004a3a80 / FUN_0049b4b0) show the code's text unless it is
0x11C1 (CREATE's handler also re-arms a flag, DAT_00a8e44e = 1, *(inferred: the placement UI)*). 0x8C21 (FUN_0049b400)
moves **only the first entry** (the count byte is ignored), 0x8C24 (FUN_0049b440) creates every entry, 0x8C27
(FUN_004a3ac0) removes the first handle and closes the selection if it was that furniture. The zone always sends count 1.

### 2.6 Moving an item into the house boxes

```pseudo
UseItemMiniHouseFurniture::uib_CanUseItem(p, item):   @ FUN_00596490
    p in a house and p is its owner → 0x700;  in a house, not the owner → 0x71C "Only available to room host.";
    else 0x71A "Only available within Estate."
UseItemMiniHouseFurniture::uib_DirectUse(p, slot, item) @ FUN_00599500 → p.so_mh_Move2MiniHouseFurniture(slot, item) (vt 0x48)

ShinePlayer::so_mh_Move2MiniHouseFurniture(slot, item):   @ FUN_00543470
    not in a house → SendErrorCode(35, 35, 0x1184); house gone → 0x1187 (both as 0x8C23 CREATE_FURNITURE_ACK)
    cell = inventory (type 9) cell `slot`; none → result 0x703
    if cell key == item key: cell.furniture handle = p.so_MH_GetNextFurnitureHandle() (vt 0xc8, memory only)
                             house.so_mh_Move2MiniHouseFurniture(p, cell, slot, 9) (house vt 0x44)
    p.so_ply_ItemUseResultPacket(0x700 or 0x703, 9) (vt 0x91c, Z04 §6)   # 0x700 even when nothing moved: (original bug) Z13-B15

ShineMiniHouse::so_mh_Move2MiniHouseFurniture(p, cell, slot, fromType):   @ FUN_005354a0
    p null → log, return
    row = MiniHouseFurniture by cell.itemid; none → log "Invalid Furniture Type"
    InvenType FURNITURE / ACCESSORY / TILEALL / MINIGAME → target box 3 / 13 / 14 / 16:
        free = first empty cell of the target box that p's lock list does not lock (ItemBoxIterEmpty + UnlockedInventoryIterator)
        none → nothing (no message)
        ItemRelocationManager::irm_Move(p.handle, p, from {fromType<<10 | slot, cell, p.charNo, p.charNo},
                                                     to {target<<10 | free, free cell, p.charNo, p.charNo})   (Z04 relocation)
    InvenType PORTAL:
        if nPortalCnt + 1 < 51 and the item id is not in Portal[]:
            p lock list.icl_ClearItem(lockindex, cell, fromType<<10|slot, same)   (vt 0x30: consume the scroll on success)
            → GameDB 0x8C5D NC_MINIHOUSE_DB_PORTAL_ADD_REQ { NETPACKETZONEHEADER {p.handle, p.charNo}, u16 nPortalItemID = item id,
                  u8 bType = (row.KeepTime_Hour ≠ 0), i32 dEndDate = mktime(now + KeepTime_Hour h), u16 lockindex,
                  PROTO_ITEM_RELOC { key (8 bytes), ITEM_INVEN newlocation } }   (pp length 0x1b; newlocation is never
                  written: (original bug) Z13-B16);  lock index += 1;  the answer 0x8C5E is Z07 §6.12 (portals §3)
        else nothing
    other InvenType → log "Invalid Furniture Type : <type>"
```

`smh_SendFurnitureInfo` also calls the house method directly for an item sitting in the wrong box (from = that box).

### 2.7 Furniture expiry: `smh_FurnitureActiveCheck`

```pseudo
smh_FurnitureActiveCheck(box, type):   @ FUN_005472e0   (from so_Routine every 30 s, §1.2, for all four boxes)
    owner = GetObject(owner handle); none → return
    for each cell of box not locked by the owner (UnlockedInventoryIterator, box size limit):
        copy = cell
        if copy has an attribute class and copy.IsPlaced and copy.deletetime (attr vt 0x34) is not started (year byte 0)
           and row = MiniHouseFurniture by item id:
            copy.deletetime = never (0x76bbecff) if row.KeepTime_Hour == 0 else pack(now + KeepTime_Hour h)
            owner lock list.vt[0x40](lockindex, cell, copy, key, key)   (move/replace reservation, Z04 §2)
            → GameDB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ (layout §2.4); lock index += 1
            if type 16 and row.GameType == GT_DICE: owner.so_SetCTDiceTaiSaiSet() (player vt 0x1b8, Z06 §3)
```

So a time-limited furniture's clock starts at its first placement (within 30 s), not when it is bought; removing it from
the room does not stop the clock. The removal of expired items is `sp_ChargedItemLimitCheck` (player vt 0x38) and
`so_DiceTaiSaiChargedItemLimitCheck`, called right after (§1.2; the same `sp_ChargedItemLimitCheck` runs on the player's
own bags every minute, Z09 §2.4).

### 2.8 Other furniture helpers

- `so_mh_GetItemCellByFurnitureHandle(handle)` @ FUN_00547700 (house vt 0x54): owner must exist; first cell of the four
  boxes whose furniture handle matches, else null. `ShineObject` default @ FUN_005476b0 = null. Used by the endurance,
  emotion, char-action and furniture-effect code (§3, Z07 §6.9–§6.11).
- `so_MH_GetFurnitureInven(type, &box)` @ FUN_00570a40 (player vt 0x50, used by item moves, Z04 §1): box = null; not in a
  house 0x1184, no field 0x1193, house gone 0x1187, not the owner 0x1188; box = house vt 0x4c(type) → 0x1181, none → 0x11A1.
  So only the owner can move items into or out of the house boxes; the `ShineObject` default FUN_00449600 returns 0.
- `so_MH_SendFunitureInfoStart(target)` @ FUN_00544de0 (player vt 0xd4): if player vt 0xb0 (default, returns 0) is
  false, puts `StaQuestEntangle` (abstate 0x122) on `target` for 420 000 000 ms with bit set and broadcast. **No caller** in
  the 2016 zone (the vt 0xd4 calls in the TaiSai code are on `CGambleDiceTaiSaiObject`).

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
| Z13-B7 | 0x8C1F / 0x8C22 / 0x8C25 (FUN_00572d50, FUN_00572bf0, FUN_00572eb0) | `furniturecount` (≤ 392) is never compared with the packet length | the house methods read up to 7 KB past a short packet (stale buffer bytes taken as handles / positions) | reject `len < 1 + n × entry size` |
| Z13-B8 | `smh_SendFurnitureInfo` (owner) | the area / height check and its "reset" run for every box cell, placed or not; unplaced items lie at the default (276, 388, 6) and always fail it | every owner house load sends one lock + `0x3449` ITEMCHANGE_REQ per unplaced furniture (silent on success) | check only `IsPlaced` cells |
| Z13-B9 | `smh_SendFurnitureInfo` (owner) | the target box of a row whose `InvenType` is none of the four (e.g. `PORTAL`) is an uninitialised / previous-cell local | random choice between "move to another box" (`so_mh_Move2MiniHouseFurniture`) and the area check for such items | handle `PORTAL` (or unknown types) explicitly |
| Z13-B10 | `smh_SendFurnitureInfo` → 0x8C09 | placed count written as `u8`, entries written without a cap | with more than 255 placed items the client reads `n mod 256` entries; the packet length uses the wrapped count too | cap at 255 or split with `next` |
| Z13-B11 | `smh_SendFurnitureInfo` → 0x8C08 | the `flag` byte (payload +2) is never written | stale byte of the shared send buffer on the wire (the 2016 client does not read it) | write 0 |
| Z13-B12 | `so_mh_CreateFurniture` / `so_mh_DeleteFurniture` | create: a missing `MiniHouseFurniture` row is detected in pass 2, after earlier entries were locked and sent; delete: the dice table is flagged for deletion in pass 1 before later entries are validated | partial edits with an error reply; a dice table marked "delete" although the request failed | validate everything before the first side effect |
| Z13-B13 | `InvenCellReleaser_FurnitureReloc::icr_Apply` (create) | the furniture expiry is computed into a stack copy of the cell | no effect (dead code); the clock starts ≤ 30 s later in `smh_FurnitureActiveCheck` | write the cell (or drop the code) |
| Z13-B14 | `InvenCellReleaser_FurnitureReloc::lc_Free` | every refused furniture change answers `0x8C20` REARRANGE_ACK {0x11CE} | a failed create / delete shows "You may not place an item at an invalid location." through the rearrange ACK | ACK of the request kind with a DB-error code |
| Z13-B15 | `ShinePlayer::so_mh_Move2MiniHouseFurniture` | item-use result 0x700 is sent although the house method may do nothing (target box full, portal already listed / list full) | the client sees a successful use; the item stays in the inventory without a message | report a failure code |
| Z13-B16 | `so_mh_Move2MiniHouseFurniture` (portal) → 0x8C5D | `PROTO_ITEM_RELOC.newlocation` (2 bytes) is never written | stale bytes reach the DB request (the DB side was not checked for its use) | write the source location |

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
- `"FURNITURE_ARE%d%c"`: the arguments are `(i, 0)` (assembly at 0x545051: `esi` = i, `edi` = 0), so the areas are named
  `FURNITURE_ARE1` … `FURNITURE_ARE9` (also for `CompulsionMoveTo`). The valid height band z ∈ [700, 900] is as read; that
  the client's furniture z values lie there (while the item default is z = 6.0) was not checked in a capture.
- Duplicate furniture handles in one CREATE / REARRANGE / DELETE request: both entries are locked and written; what the
  lock list and the two DB answers then do with one cell was not traced.
- The 0x3449 requests of `smh_SendFurnitureInfo` use the static `delete_item_packet` buffer (0x81 bytes) instead of the
  shared `gpp`; why (re-entrancy with the 0x8C08 sends) is *(inferred)*.

## Coverage boundary

(Filled in by the sweep part.)
