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
                # (original bug) Z13-B18: dEndTime is a time_t, g_Now / 10 seconds since zone start: never true (§3.1)
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

## 3. Portals, effects, endurance, furniture animations and emotions

### 3.1 Portals (house vt 0x104–0x124)

**Data** `smh_PortalList` (`MiniHousePortalList`, +0xc100, 0x138 bytes) *(pdb2016)*: `+0 u8 isActivePortal`, `+2 u16
ActivePortalIndex`, `+4 u32 PortalDeActiveTime` (g_Now ticks), `+8 u16 nPortalCnt`, `+0xa PORTAL_INFO Portal[50]`
(`{u16 nPortalItemID, i32 dEndTime}`, 6 bytes). `dEndTime` is what the Character DB sends: a `time_t` (seconds since 1970)
for a timed gate, 0 for a permanent one (D03, `usp_Minihouse_getGateList`; the DB already leaves out expired rows). A portal
is a portal-scroll item (`MiniHouseFurniture.InvenType = PORTAL`, rows 1000+) moved into the house (§2.6 →
`0x8C5D` PORTAL_ADD); when open it is shown as the pseudo-furniture with handle **60000**.

```pseudo
so_mh_SetPortalList(ack PROTO_NC_MINIHOUSE_DB_PORTAL_LIST_ACK)          vt 0x104  @ FUN_005478c0
    # caller so_ply_MH_SetMHPortalList (player vt 0xfc, Z07 §6.12) has checked Error == 0x1A08 and nPortalCnt < 51
    nPortalCnt = ack.nPortalCnt; Portal[i] = ack.PortalInfo[i] for i < nPortalCnt
    CanEnter += 1                       # the 5th of the five "data loaded" steps (§1.3: enter allowed at >= 5)

so_mh_AddPortal(ack PROTO_NC_MINIHOUSE_DB_PORTAL_ADD_ACK)               vt 0x108  @ FUN_00547960
    if nPortalCnt + 1 <= 50: Portal[nPortalCnt] = { ack.nPortalItemID, ack.dEndDate }; nPortalCnt += 1
    # else silently dropped (the scroll was already deleted by the DB)
    # caller so_ply_MH_AddMHPortal (player vt 0x100, FUN_0056fa10) on ack.Error == 0x1A10:
    #   lock list vt 0x1c (commit lockindex); p must be in its own house (vt 0x130, owner charNo == p.charNo),
    #   else log "] : not found mh" / "] : not owner"; then house vt 0x108 and
    #   p ← 0x8C4C NC_MINIHOUSE_PORTAL_ADD_CMD { PORTAL_INFO { u16 nPortalItemID, i32 dEndDate } } with length 0xE = 12 payload bytes: 6 stale bytes follow (cosmetic, the client reads the first 4)
    #   ack.Error ≠ 0x1A10: lock list vt 0x28 (release lockindex), log

so_mh_PortalOpen(req { u16 nPortalItemID })                              vt 0x10c  @ FUN_00547a30
    if isActivePortal: return 0x19F8                        # another portal is already open
    if so_mh_ActivePortal(nPortalItemID): return 0x1181      # ok → handler broadcasts 0x8C24 for handle 60000 (Z07 §6.8)
    return 0x19F9                                           # not in the list (expired portals are still in it: Z13-B18)

so_mh_ActivePortal(id)                                                   vt 0x118  @ FUN_00547d90
    if id == 0xFFFF: return 0
    i = first index < min(nPortalCnt, 50) with Portal[i].nPortalItemID == id; none: return 0
    ActivePortalIndex = i; isActivePortal = 1; PortalDeActiveTime = g_Now + 600        # open for 60 s
    return 1

so_mh_PortalClose()                                                      vt 0x110  @ FUN_00547b40
    if !isActivePortal: return 0x1A00
    so_mh_DeActivePortal(); return 0x1181                   # handler broadcasts 0x8C27 { 1, 60000 } (Z07 §6.8)
so_mh_DeActivePortal()                                                   vt 0x11c  @ FUN_00542bc0
    isActivePortal = 0; PortalDeActiveTime = 0; return 1
so_mh_isActivePortal()                                                   vt 0x114  @ FUN_00547d30   → isActivePortal
so_mh_GetActivePortalID()                                                vt 0x120  @ FUN_00547c30
    active and ActivePortalIndex < min(50, nPortalCnt) → Portal[ActivePortalIndex].nPortalItemID, else 0xFFFF
so_mh_GetActivePortalEffect()                                            vt 0x124  @ FUN_00542be0
    id = GetActivePortalID(); 0xFFFF → null
    return the first MiniHouseFurnitureObjEffect row whose ItemID (inx name) resolves to item id `id`, else null
```

Timers (in `so_Routine`, §1.2): an open portal closes after 60 s (`0x8C27` delete of handle 60000 to the house, needs the
owner object); every 30 s the list drops entries with `0 < dEndTime < g_Now / 10` that are not the open one and tells the
owner `0x8C4F NC_MINIHOUSE_PORTAL_DEL_CMD { u16 nPortalItemID }`. `g_Now / 10` is seconds since the zone's clock reset
(`clockwatch` is zeroed at the world-time sync, `wms_NC_MISC_TIMEFROMWORLD_CMD` FUN_004511a0) while `dEndTime` is a `time_t` around 1.3 × 10⁹:
the test is never true, so a timed portal that expires while the house is up stays in the list and can still be opened
and used until the house is rebuilt (original bug) Z13-B18. Z13-B3 (index advance after a removal) only matters once
B18 is fixed.

### 3.2 Furniture and portal effects

**Table `MiniHouseFurnitureObjEffect.shn`** (`CDataReader gMiniHouseObjEffect`, read at zone start in `zs_start_star`
with row size 0xD2; read failure → assert "Fail to read 'MiniHouseFurnitureObjEffect.shn'" + `ShineExit`). Columns
(from the SHN header; offsets as the code reads them): `+0 u16 Handle, +2 ItemID[32]` (inx name of the furniture or portal
item), `+0x22 u32 EffectEnum, +0x26 EffectIndex[32], +0x46 u32 ApplyRange[5], +0x5a u32 UseRange[5], +0x6e NeedItem[32],
+0x8e u32 NeedMoney, +0x92 EffectName[32], +0xb2 EffectSound[32]`. `UseRange` (who may *trigger* the effect) is checked by
the requests (Z07 §6.10: [0] anybody, [1] host's party, [2] host's guild, [3] / [4] level range); `ApplyRange` (who
*receives* it), same meaning, by the apply methods below. `EffectEnum`: **0** recall (EffectIndex = recall-scroll item,
its `RecallPoint` row is the target), **1** abnormal state (EffectIndex = abstate inx), **2** none (players are only
listed for the client effect), **3** portal recall (only `so_mh_PortalEffectApply`). The 2016 table: rows 0–3 are type 0
(`IN_ValDn01` …, ApplyRange `{0,1,0,1,120}`, UseRange `{0,0,0,1,120}`), rows 4–12 (Handles 1000–1008) type 3 for the
`IN_PORTAL_*` items (ApplyRange `{0,1,0,1,150}`, UseRange `{0,0,0,1,150}`); no NeedItem, NeedMoney 0, EffectName and
EffectSound all "-". So with the 2016 data only the host can trigger an effect (UseRange all 0 → 0x16CE / 0x19DE for
others), it is free (applied at once, no DB round trip), and it recalls the host plus the host's party members of level
1–120 / 1–150 who are in the house.

```pseudo
so_mh_EffectApply(rowIndex, out cmd PROTO_NC_MINIHOUSE_FURNITURE_EFFECT_CMD)   house vt 0x160  @ FUN_00542520
    # rowIndex = the request's nEffectHandle used as a record index (row Handle == index for the type 0–2 rows)
    row = gMiniHouseObjEffect[rowIndex]; out of range / null: return 1
    switch row.EffectEnum:
      0: rp = RecallPoint row "ItemIdent" == item id of row.EffectIndex; none: return 2
         link = { rp.map (+0x24) as destMap and destMapForClient, x = rp +0x44, y = rp +0x46 }
      1: abstate = dic_abstate[row.EffectIndex]; unknown: return 2
      2: (nothing)
      else: return 2
    owner = GetObject(owner handle); none: return 3
    for i = 5 − GMCount … EnterPlayerCount − 1:                 # GMs, then visitors (slot 5 = owner, skipped)
        m = member i; skip null, the owner, level ∉ [ApplyRange[3], ApplyRange[4]]
        eligible = ApplyRange[0] == 1
                   or (ApplyRange[2] == 1 and m has a guild and m.guild == owner.guild)        (vt 0x828)
                   or (ApplyRange[1] == 1 and m has a party and m.party == owner.party)        (vt 0x550)
                   # the guild / party tests run only if ApplyRange[1] or [2] is non-zero
        if !eligible: continue
        cmd.nApplyPlayerHandle[cmd.nApplyPlayerCnt++] = m.handle
        type 0: if m.so_IsJoinThisGame (vt 0x170) and TaiSai status (vt 0x2a0) ∈ {2 rolling, 3 stand-by}:
                    m.so_SetDiceTaiSaiRoomLeaveInfo(1) (vt 0x190); m.so_SetMiniGameRoomLeaveMapInfo(link map, x, y) (vt 0x194)
                    # moved when the dice round ends (Z06 §3)
                else:
                    before = EnterPlayerCount
                    m.so_LinkTo(link, 6, 9, 10) false: log "…so_mh_EffectApply : player [name] cannot out minihouse";
                                                      m.so_Disconnect (vt 0x5f8)
                    else if EnterPlayerCount changed and i > 4: i −= 1   # the member left the array (same-zone link
                                                                         # unmarks at once): re-test the shifted slot
        type 1: m.so_AbnormalState_Set(m, abstate, strength 1, …) (vt 0x638); so_AbnormalState_BitSet(index);
                if the abstate has sub-state info [1]: m.so_AbnormalState_Inform(index, KeepTime, 1) (vt 0x3f0) and
                so_AbnormalState_BroadcastSet(index, KeepTime, 1)
    owner: same level test, then listed; type 0: TaiSai status ∈ {2, 3} → house.so_mh_SetIsLeaveOwner(1) (vt 0x200) and
           owner vt 0x194(link); else owner.so_LinkTo(link, 6, 9, 10), failure → log, disconnect; type 1 as above
           # the owner needs no ApplyRange membership; outside the level range it is not affected
    return 0

ShinePlayer::so_MH_EffectApply(rowIndex)                     player vt 0x15c  @ FUN_005751f0
    # called by 0x8C40 for a free effect (Z07 §6.10) and by the DB answer 0x347E (Z05 §9.6)
    ack = 0x8C41 NC_MINIHOUSE_FURNITURE_EFFECT_ACK { u16 nEffectHandle = rowIndex, u16 err }
    no field: err 0x16C2; not in a house (vt 0x130): 0x16C4; house gone: 0x16C3 → p ← ack; return
    cmd = static furniture_effect_cmd_buffer: 0x8C42 NC_MINIHOUSE_FURNITURE_EFFECT_CMD { u16 nEffectHandle = rowIndex,
          u16 nApplyPlayerCnt = 0, u16 nApplyPlayerHandle[] }
    r = house.so_mh_EffectApply(rowIndex, cmd) → err 0 → 0x16C0 ok, 1 → 0x16CA, 2 → 0x16C6, other → 0x16C1
    p ← ack { rowIndex, err }
    if err == 0x16C0 and nApplyPlayerCnt > 0: so_AllInMap(p, cmd, 4 + 2n payload bytes)   # whole house map
```

```pseudo
so_mh_PortalEffectApply(row, out cmd PROTO_NC_MINIHOUSE_PORTAL_EFFECT_CMD)   house vt 0x12c  @ FUN_00542c70
    row null: return 1; row.EffectEnum ≠ 3: return 2
    rp = RecallPoint row of the item id of row.EffectIndex; none: return 2
    owner none: return 3
    member loop as in so_mh_EffectApply type 0 (same ApplyRange, level, TaiSai leave-info and LinkTo rules), except:
        after a successful LinkTo: if EnterPlayerCount is unchanged → **break** (stop the loop);
                                   else if i > 4: i −= 1
        # a link to another zone does not unmark the member (Z01 so_LinkTo: only the WM 0x180D reservation), so the count
        # stays and the loop ends after the first such member: the other eligible visitors are not recalled
        # (original bug) Z13-B19
    owner part as in type 0; return 0
    # the portal is not closed by its use; it closes after its 60 s

ShinePlayer::so_MH_PortalEffectApply(row)                    player vt 0x128  @ FUN_00574450
    ack = 0x8C57 NC_MINIHOUSE_PORTAL_EFFECT_ACK { u16 Error }
    no field 0x19D2; not in a house 0x19D4; house gone 0x19D3 → p ← ack; return
    cmd = static portal_effect_cmd_buffer: 0x8C58 { u16 nEffectHandle = row.Handle (first u16 of the row), u16 cnt, handles[] }
    r = house.so_mh_PortalEffectApply(row, cmd) → 0 → 0x19D0, 1 → 0x19DA, 2 → 0x19D6, other → 0x19D1
    p ← ack; if 0x19D0 and cnt > 0: so_AllInMap(p, cmd)
    # caller: 0x8C56 (Z07 §6.10, free effect). The paid path has no DB handler (Z05-B12).
```

### 3.3 Endurance (durability)

**Table `MiniHouseEndure.shn`** (`MiniHouseEndureDataBox minihouseenduredatabox`, `mhe_Load` @ FUN_004a11e0 at zone start
from `../9Data/Shine/MiniHouseEndure.shn` (`BinaryDataBox<MiniHouseEndure>::bdb_ReadData` @ FUN_004a1100); `mhe_default`
= the zeroed default block). Rows `{u16 Handle, u16 Endure[4]}` (hours): 0 `{0,0,0,0}`, 1 `{720,384,48,0}`, 2
`{2160,1200,240,0}`, 3 `{72,48,24,0}`. `MiniHouseFurniture.KeepTime_Endure` selects the row (2016 data: 1 or 0).
`operator[]` @ FUN_00543440: index ≥ row count → the default block.

Grade `MHE_STEP` *(pdb2016)*: 0 NONE (no durability), 1–3 STEP_1–3 (wearing), 4 STEP_4 (worn out). Uses of the grade
(cell +0x25): furniture edits are refused at > 3 (0x11E2, §2.4), character actions at ≥ 3 (0x11E2, Z07 §6.9), furniture
effects at ≥ 3, emotions at > 1 (0x170F, §3.5).

```pseudo
mhe_CalEndureGrade(rowIdx, ShineDateTime end, out grade) → ok         @ FUN_004a12a0
    rowIdx > row count: return 0; row = row rowIdx (or the default block); row.Handle ≠ rowIdx: return 0
    year byte of end == 0:    grade = NONE; return 1                     # no durability clock
    year byte == 0xFF (never) and row.Endure[0] == 0: grade = STEP_1; return 1
    now = chargeditemcheck's current time (struct tm, minute resolution (inferred))
    if mktime(end) <= mktime(now): grade = STEP_4; return 1
    h = min((end − now) / 3600, row.Endure[0])                            # whole hours left
    for k in 0, 1, 2: if row.Endure[k+1] <= h < row.Endure[k]: grade = STEP_1 + k; return 1
    return 0
    # h == Endure[0] (at least Endure[0] hours left) matches no bucket: no grade, the callers keep the old one
    # (original bug) Z13-B20; a fresh or repaired item is capped at now + Endure[0] and is a few seconds below it
    # "never" with Endure[0] ≠ 0: mktime of year 2155 fails (−1) → STEP_4 (only with inconsistent data)
    # row 1: STEP_1 = 384–719 h left, STEP_2 = 48–383 h, STEP_3 = 0–47 h, STEP_4 = expired

so_mh_DoingEndureGradeDown(out changed) → ok                 house vt 0x16c  @ FUN_00548270   (so_Routine every 60 s, §1.2)
    !so_mh_CanEnter (data not loaded) or owner object missing: return 0
    isEndureCheck = 0; nEndureFurnitureCnt = 0
    for each item cell of the four boxes (§2.1), with an attribute and an item id:
        row = MiniHouseFurniture by item id; none: skip
        old = cell +0x25
        if mhe_CalEndureGrade(row.KeepTime_Endure, attr.GetEndureEndTime, &g) and g ≠ old:
            attr.SetEndureGrade(cell, g) (vt 0x98)
            if placed (cell +0x0a bit 0):
                EndureFurniture[nEndureFurnitureCnt++] = { nFurnitureHnd = cell +0x0b, nEndureGrade = g, isRePair = 0 }
                changed = 1
    return 1
    # the grade lives in memory only (it is recomputed from dEndureEndTime at every load, §2.2); unplaced items change
    # silently. List: ENDURE_FURNITURE_INFO[294] with a u8 count (a pass with more than 255 placed changes would wrap,
    # not reachable with the 2016 timers (inferred))
    # caller (so_Routine) broadcasts 0x8C61 { nCount, EndureFurniture[] } and stops the emotions on each listed furniture

so_mh_EndureGradeDownTimeUpdate()                            house vt 0x168  @ FUN_00547f60   — no caller in the 2016 zone
    for each furniture (as above) with grade g ∈ 1…3 and Endure[g−1] ≠ 0:
        t = g_Now + (Endure[g−1] − Endure[g]) × 36000 + 10           # the full length of the current step, from now
        if t < tEndureCheckTime: tEndureCheckTime = t; isEndureCheck = 1
so_mh_isEndureGradeDown()                                    house vt 0x164  @ FUN_00547f00   → isEndureCheck; no caller
    (ShineObject default @ FUN_00547eb0 returns 0). isEndureCheck is written only here and in the two methods above:
    the "next grade change" timer is dead; the fixed 60 s pass does the work.
```

**Repair kit** (request `0x3033` NC_ITEM_MH_FURNITURE_ENDURE_KIT_USE_REQ, handler and state checks Z04 §8.4):

```pseudo
so_ply_MH_FurnitureEndureUse(p, req { u8 nInvenSlot, u16 nFurnitureHnd })   player vt 0x13c  @ FUN_00571550
    house = GetObject(p.GetMyHandle) none: return 0x1A76 "Estate is not activated."
    house owner charNo ≠ p.charNo: return 0x1A7D            # only the owner repairs
    nInvenSlot ≥ inventory size: assert "wrong slot"; return 0x1A73
    inventory cell (9, slot) locked: return 0x1A74 "Working on the other item."
    info = ItemInfo(cell.itemid); none: return 0x1A73
    info.ItemFunc ≠ ITEMFUNC_ENDUREKIT_F: return 0x1A78 "It is wrong repair item."
    p.sp_LastUsedItem = itemid; lot < 1: assert "Try to use lot 0 item"; return 0x1A75
    ce = first chargedbuffdatabox row with ce_ItemID == itemid; none, no data or EffectEnum ≠ EE_ENDURE_KIT: return 0x1A73
    add = ce.EffectValue (hours)
    fcell = house.so_mh_GetItemCellByFurnitureHandle(nFurnitureHnd); none: return 0x1A79 "It is wrong furniture item."
    copy = fcell (0x74 bytes)
    year byte of copy.dEndureEndTime == 0: return 0x1A7B "It is useless for you to use."   # furniture without durability
    row = MiniHouseFurniture by item id; none: return 0x1A79
    e = MiniHouseEndure[row.KeepTime_Endure]; e.Endure[0] == 0: return 0x1A7A "Has no effect."
    attr.SetEndureEndTime(copy, add, e.Endure[0], now) (vt 0x90, §2.1: extend, capped at now + Endure[0])
    actor ui_FurnitureEndureKit (UseEffect::UseItemFurnitureEndureKit): uivpb_SetFurnitureHnd @ FUN_005969a0,
        uivpb_SetFurnitureKey(copy key) @ FUN_005969c0, uivpb_SetFurnitureEndureTime(copy end) @ FUN_005969e0
    UseItemVariationProtocolBase::uib_AfterCast(actor, p, inventory, info, slot) (Z04 §6: consumes one kit) sends
        → DB 0x348B NC_ITEMDB_FURNITURE_ENDURE_REQ (uivpb_ProtocolMake @ FUN_00596960, size 0x23):
          { u16 nFurnitureHnd, u64 nItemKey, ShineDateTime dNewEndureTime, PROTO_NC_ITEMDB_USE_VARIATION_ITEM_REQ CommonData }
    return 0x1A70                                          # handler sends nothing now; every other code → 0x3034 { Error }
    # the kit is used up even when the end time was already at the cap (no "no effect" test)
    # Z04 §8.4 / Z04-B13 say the failures are silent: they are not, the handler FUN_00571340 sends each code as
    # 0x3034 { dEndEndureDate stale, Error }.

UseItemFurnitureEndureKit::uivpb_SendErrorCode(p, code)     actor vt 0x18  @ FUN_0059a990
    # called by uib_AfterCast when the kit cell changed or has lot 0 (code 0x702)
    p ← 0x3034 with Error written at payload +4 but pp_SetPacketLen(6) = 4 payload bytes: the code is not on the wire,
        the client reads `Error` past the packet (original bug) Z13-B17 (also the assert text names smh_SendFurnitureInfo)

so_ply_MH_FurnitureEndureUpdate(p, ack PROTO_NC_ITEMDB_FURNITURE_ENDURE_ACK)   player vt 0x140  @ FUN_00570fe0
    # DB answer 0x348C with Error 0x700 (Z05 §9.7, which sends 0x3034 { Error } for a result ≠ 0x1A70)
    not in a house / house gone: return 0x1A76
    cell = house vt 0x54(ack.nFurnitureHnd); none: return 0x1A75
    attr.vt 0x94 (set dEndureEndTime = ack.dNewEndureTime) fails, no MiniHouseFurniture row, or mhe_CalEndureGrade fails: return 0x1A73
    attr.SetEndureGrade(cell, g)
    p ← 0x3034 NC_ITEM_MH_FURNITURE_ENDURE_KIT_USE_ACK { ShineDateTime dEndEndureDate = ack.dNewEndureTime, u16 Error = 0x1A70 }
    if placed: so_AllInMap(p, 0x8C61 { nCount 1, { nFurnitureHnd, nEndureGrade = g, isRePair = 1 } })   (5-byte payload)
    return 0x1A70
```

### 3.4 Furniture animations (`MiniHouseObjAni.shn`, 0x8C3D / 0x8C3F)

**Table** `MiniHouseObjAniDataBox minihouseobjanidatabox`, `mhoadb_Load` @ FUN_004a1970 at zone start (`zs_start_tough`)
from `../9Data/Shine/MiniHouseObjAni.shn` (`bdb_ReadData` @ FUN_004a1580, row 0x27 bytes, failure → assert + `ShineExit`).
Row `MiniHouseObjAni` *(pdb2016)*: `Handle, ItemID (u16 item id), AniGroupIDMaxNum, AniGroupID, EventCode, NextAniHandle,
ActorMaxNum, Actor01–03, ActeeMaxNum, Actee01–03`. 2016 data: 183 rows, Handles 0–182 contiguous, 67 furniture items;
only row 29 (item 50024) uses a random follow-up and only row 29 has `ActorMaxNum` (2); no row has actees.

```pseudo
mhoadb_MakeServerAniData()                                    @ FUN_004a1660   (end of mhoadb_Load)
    mhoadb_MaxItemHandle = max(row.Handle) + 1; p_mhoadb_ServerAniData = new ServerAniData[MaxItemHandle]
        (default { isRand 0, RandCnt 0, RandStartHandle 0xFFFF, ActorMaxNum 0, ActeeMaxNum 0 })
    for each row r: s = ServerAniData[r.Handle]
        if r.NextAniHandle < 10000: s = { isRand 0, RandCnt 0, RandStartHandle = r.NextAniHandle }   # fixed follow-up
        else:                                                       # NextAniHandle names an animation group
            group = rows with ItemID == r.ItemID and AniGroupID == r.NextAniHandle
            s = { isRand 1, RandCnt = |group|, RandStartHandle = Handle of the first group row }   # assumes contiguous handles
        s.ActorMaxNum = r.ActorMaxNum; s.ActeeMaxNum = r.ActeeMaxNum

mhoadb_GetAniData(handle) → AniData* (one shared static)      @ FUN_004a14c0
    handle >= MaxItemHandle: return null
    s = ServerAniData[handle]
    AniData = { PreHandle = handle,
                NextHandle = s.isRand ? s.RandStartHandle + rnd(s.RandCnt) : s.RandStartHandle,
                ActorIdx = s.ActorMaxNum ? rnd(s.ActorMaxNum) + 1 : 0,
                ActeeIdx = s.ActeeMaxNum ? rnd(s.ActeeMaxNum) + 1 : 0 }        # rnd(n) = RandomBox 0…n−1 (inferred)
    # a handle below MaxItemHandle without a row gets the defaults (NextHandle 0xFFFF)

so_mh_CanObjAni(furnitureHandle)                              house vt 0x158  @ FUN_005424a0   (anti-spam, 2 s per furniture)
    walk smh_FurnitureLastTouchTIme[294] {u16 FurnitureHandle, u32 LastTouch} up to the first free (0xFFFF) entry:
        found: if g_Now <= LastTouch + 20: return 0; LastTouch = g_Now; return 1
    table full (294 used): return 0
    take the free entry: { furnitureHandle, g_Now }; return 1
    # entries are never freed during the house's life; furniture handles are never reused (§2.1), so after 294 distinct
    # furniture handles have been animated every new one is refused (0x14C1) (original bug) Z13-B22
```

**0x8C3F field mapping (Z07 §6.9 open point):** the handler (FUN_00574750) sends the `AniData` returned by
`mhoadb_GetAniData(req.Handle)`, not the raw table row: `{ u16 PreHandle = requested Handle, u16 NextHandle = follow-up
animation, u16 nFurnitureHnd, u16 ActorHnd = p, u8 ActorIdx, u8 ActeeIdx }` (`(u8)` of the two u16 `AniData` words). The
names agree with `PROTO_NC_MINIHOUSE_CHAR_ACTION_CMD`; there is no layout difference. The requested animation's `ItemID` is
never compared with the furniture's item, so any animation Handle can be played on any furniture (original bug) Z13-B23.

### 3.5 Furniture emotions (sitting / lying on furniture)

Player state `sp_FurnitureEmotionInfo` (`FURNITURE_EMOTION_INFO` *(pdb2016)*: `{u16 nPlayerHandle, u16 nFurnitureHnd, u8
nPosition, u8 nEmotionNo}`); `so_ply_MH_InitFurnitureEmotionInfo` @ FUN_0056fe60 (player vt 0x2b0) sets all to 0xFF… =
"not on furniture". Accessors (player vt 0x2b4–0x2d4): `IsFurnitureEmotion(h)` @ FUN_0056fe80 (h ≠ 0xFFFF and on h),
`IsFurnitureEmotionPosition(h, pos)` @ FUN_0056feb0, `IsFurnitureEmotionNo(n)` @ FUN_0056fef0, `GetFurnitureEmotion` (handle,
0xFFFF = none) @ FUN_0056ff10, `GetFurnitureEmotionPosition` @ FUN_0056ff20, `GetFurnitureEmotionNo` @ FUN_0056ff30,
`SetFurnitureEmotion` @ FUN_0056ff40, `SetFurnitureEmotionPosition` @ FUN_0056ff60, `SetFurnitureEmotionNo` @ FUN_0056ff80,
`GetFurnitureEmotionInfo` (pointer) @ FUN_0056fe50 (no caller found). `nPlayerHandle` is never set (the packets use the
player's object handle). The state is reset by the player constructor, `0x8C10` VISIT (a visitor entering, FUN_00571c50), `0x8C65`
cancel and `so_mh_FurnitureEmotionStop`; **not** by `so_mh_Out` or the owner's own entry (`so_mh_Move2MiniHouse`): a player
who leaves while seated keeps the state, and an owner re-entering a rebuilt house (handles renumbered from 1) is reported as
seated on whatever furniture now has that handle, to every later visitor (`0x8C64` at LOGINCOMPLETE) and blocks that seat
(original bug) Z13-B21.

```pseudo
so_mh_CanFurnitureEmotion(p, req { u16 nFurnitureHnd, u8 nPosition, u8 nEmotionNo }) → code   house vt 0x2d8  @ FUN_005485c0
    # ShineObject default @ FUN_00543130 returns 0x1709. Caller 0x8C62 (Z07 §6.11) applies the state on 0x1708.
    p or req null: return 0x1709
    seat taken (so_mh_IsFurnitureEmotion false) and not by p itself (p vt 0x2b8): return 0x170E "Someone else is using that position of the furniture."
    cell = house vt 0x54(nFurnitureHnd); none: return 0x1710
    cell grade (+0x25) > 1: return 0x170F "Cannot use the furniture due to low duration."
    distance(p, furniture LocX/LocY rounded) > 200: return 0x170D "The furniture is too far away."
    row = MiniHouseFurniture by item id; none (or item id 0xFFFF): return 0x1709
    nPosition < row.MaxSlot: return 0x1708 (ok); else return 0x1711
    # nEmotionNo is not validated (MiniHouseFurniture.MHEmotionID is not read) and the furniture's IsPlaced bit is not
    # tested: an item still in the box (default location 276, 388) can be sat on from near that point, and any emotion
    # number is broadcast (original bug) Z13-B24 (CHAR_ACTION and FURNITURE_EFFECT do not test IsPlaced either)
    # 0x170C "You already have this emotion." is never returned

so_mh_IsFurnitureEmotion(h, pos) → "seat free"                house vt 0x2dc  @ FUN_00543140
    for every member (slots 5 − GMCount … EnterPlayerCount − 1): if m.IsFurnitureEmotionPosition(h, pos): return 0
    return 1

so_mh_FurnitureEmotionStop(h, broadcaster)                    house vt 0x2e0  @ FUN_005431b0
    for every member on furniture h (any position): list its handle; m.InitFurnitureEmotionInfo (vt 0x2b0)
    if any: so_AllInMap(broadcaster, 0x8C67 NC_MINIHOUSE_FURNITURE_EMOTION_CANCEL_CMD { u16 nCancelEmotionCnt, u16 handle[] })
    return 1
    # callers: so_Routine after a grade change (§1.2, broadcaster = owner) and the FurnitureReloc releaser for a
    # rearranged / deleted furniture (§2.5)

so_mh_SendInnerPlayerFurnitureEmotion(target)                 house vt 0x2e4  @ FUN_005432d0
    entries = { m.handle, m.GetFurnitureEmotion, Position, No } for every member with GetFurnitureEmotion ≠ 0xFFFF
    if any: target ← 0x8C64 NC_MINIHOUSE_FURNITURE_EMOTION_CMD { u16 nEmotionCnt, FURNITURE_EMOTION_INFO[] }   (4 + 6n bytes
            with the opcode); caller LOGINCOMPLETE (Z07 §6.4)
```

### 3.6 Client side (2016 client, `GameFrameWork` scene)

| Packet | Client handler | What the client does |
|---|---|---|
| 0x8C3F CHAR_ACTION_CMD | `On_NC_MINIHOUSE_CHAR_ACTION_CMD` @ FUN_0049b760 | `MiniHouseIndoor::ObjDoAction(nFurnitureHnd, ActorHnd, PreHandle, NextHandle)`; `ActorIdx` / `ActeeIdx` are not read |
| 0x8C41 FURNITURE_EFFECT_ACK | @ FUN_00499a20 | 0x16C0: nothing; 0x16C7 / 0x16C8 / 0x16CF: `MiniHouseIndoor::ObjEffErrMsg(nEffectHandle, code)` (message built from the effect row); other codes: `ErrMsgTable` text |
| 0x8C42 FURNITURE_EFFECT_CMD | @ FUN_004b5070 | client ObjEffect row `nEffectHandle` (by **index**, as the server); for each listed player: `EffectName` effect and `EffectSound` sound unless "-" (all "-" in 2016) |
| 0x8C4B PORTAL_LIST_CMD / 0x8C4C PORTAL_ADD_CMD / 0x8C4F PORTAL_DEL_CMD | @ FUN_0049b7d0 / FUN_0049b830 / FUN_0049b870 | `mhPortalListWin::Add(entry)` per entry / `Add` / `Delete` (the DEL handler passes no packet field to `Delete` as decompiled; which entry it removes is not resolved) |
| 0x8C51 / 0x8C54 / 0x8C57 / 0x8C58 | – | accepted and ignored: portal open / close results and the portal effect ACK and CMD have no client effect, so the 0x19D* / 0x19F8 / 0x19F9 / 0x1A00 codes are never shown |
| 0x8C61 FURNITURE_ENDURE_CMD | @ FUN_0049b960 | `MiniHouseIndoor::ChangeEndure(nEndureGrade, nFurnitureHnd)` per entry; `isRePair` not read |
| 0x8C63 EMOTION_ACK | @ FUN_004a5080 | ≠ 0x1708: text, leave the emotion mode, stand up at the ground position; 0x1708: nothing (the CMD seats) |
| 0x8C64 EMOTION_CMD | @ FUN_004a5170 | only inside a house: per entry load the character, `ActMHEmotion(entry)`, `AddObjSeatInfo(position, player)` |
| 0x8C66 EMOTION_CANCEL_ACK | @ FUN_0049c3f0 | 0x1718: stand the main character up; any other code: nothing (0x1719 / 0x171A–0x171C not shown) |
| 0x8C67 EMOTION_CANCEL_CMD | @ FUN_004a5230 | only inside a house: per handle stand the character up, `DelObjSeatInfo`; the main character also leaves the emotion UI |
| 0x3034 ENDURE_KIT_USE_ACK | @ FUN_004af590 (Z04 §8.4) | 0x1A70 "Repair has been completed." + new end date; other codes: their texts (0x1A71–0x1A7D, `client-error-codes.json`) |

---

## 4. Wedding: hall, ceremony, married-state timers, partner summon

Z02 §10 has the client requests (propose, reserve, guest enter, divorce), Z07 §5 the DB answers and the partner-info
exchange, D02 §11 the Character-DB procedures, Z11 §6.1 the GM commands `&weddingreset` / `&reserve` / `&enterready` /
`&enter` / `&wedding`. This section is the object side: the hall, its timetable and ceremony, the per-minute status
checker, the ring packets and the partner-summon skill.

### 4.1 Data

```pseudo
class WeddingHall  (global `weddinghall`, DAT_0086ea38 = Z07's g_WeddingHall; size 0x44)           (pdb2016)
    +0x00 u8  Reserved          # one reservation per zone, no queue
    +0x01 u8  Started           # couple recalled, ceremony running
    +0x04 ShineDateTime EnteringStart    # = reservation time + 20 min
    +0x08 ShineDateTime EnteringEnd      # = EnteringStart + 5 min (guest entry window ends)
    +0x0c ShineDateTime WeddingEnd       # = EnteringEnd + 10 min (hall freed)
    +0x10 FieldMap* wh_Field             # map "Wedding" of this zone, set by wh_Start
    +0x14 WeddingPerson Groom  { u32 RegistNumber, Name5 CharacterName }
    +0x2c WeddingPerson Bride  { … }
    static init @ FUN_00699320: names "", Bride.RegistNumber = 0xFFFFFFFF (Groom's stays 0)

ShineDateTimeSpan (u32) = { u16 date, u8 hour, u8 minute }: the spans 0x14000000 / 0x05000000 / 0x0A000000 are 20 / 5 / 10 min.
ShineDateTime (u32 bitfield) = { year:8 (−2000), month:5, date:6, hour:6, minute:7 } (pdb2016). "now" = chargeditemcheck.ct_Current,
    rebuilt from the world clock (timefromworld) when the minute changes, in ZoneServer::zs_mainthreadfunction @ FUN_005aca30.

ShinePlayer.sp_WeddingData (p+0x5cc8) = PROTO_NC_CHAR_WEDDINGDATA_ACK (Z07 §5.1); so_ply_WeddingStatus (vt 0x958) returns it   @ FUN_0059eed0
    ShineObject::so_ply_WeddingStatus (non-players) returns the static so_WeddingData (initialiser FUN_006986c0)              @ FUN_0059eec0
    PROTO_NC_CHAR_WEDDINGDATA_ACK::operator= (field copy of all 0x2b bytes)                                                   @ FUN_0059f250
    PROTO_NC_CHAR_WEDDINGDATA_ACK::Reset (in sp_NC_MAP_LOGINCOMPLETE_CMD, before the 0x1080 request)                          @ FUN_0043bdb0
        header = {0xFFFF, 0xFFFFFFFF}; Status = 0 (Main 0, Sub 0); When ← the old SubWhen (as compiled: `mov ecx,[esi+0xd]; mov [esi+9],ecx`);
        Partner.Name = "", Partner.RegisterNumber = 0xFFFFFFFF, WeddingCount = RefusalCount = 0; Error and SubWhen kept
ShinePlayer.sp_MiscFlag: LockRefundReq, LockRefundCanCelReq, BeSummoned (bytes; pdb2016). Accessors (player vt):
    0x404 sp_IsLockedRefundReq @ FUN_0055a580   0x408 sp_LockRefundReq @ FUN_0055a590   0x40c sp_UnlockRefundReq @ FUN_00549400
    0x410 sp_IsLockedRefundCancelReq @ FUN_0055a5a0   0x414 sp_LockRefundCancelReq @ FUN_0055a5b0   0x418 sp_UnlockRefundCancelReq @ FUN_00549410
    LOGINCOMPLETE calls vt 0x40c and vt 0x418 (both locks cleared at every login / map change).
Special items (ItemDataBox::idb_MakeSpecialID, by item index): sii_ProposeRing "ProposeRing", sii_InvitationCard "InvitationCard",
    sii_WeddingCoupon "WeddingCoupon" (the reservation item Z02 calls "wedding application"), sii_WeddingPresent "MiniWedding01_1".
Special skills: ss_SummonMate "SummonMate01" (active), ss_PowerOfLove "PowerofLove01" (passive), learnt on 0x1092 (Z07 §5.2).
Abstates: STA_WEDDINGBUFF 293 (0x125), STA_WEDDINGSUB01 294, STA_WEDDINGSUB02 295 (pdb2016 enum ABSTATEINDEX).
AnnounceData.shn rows (CAnnounceSystem gAnnounceSystem, DAT_13388678): 12 `"%s"'s proposal has been accepted by  "%s"`,
    13 `Congratulations and well wishes to "%s" and "%s".`
```

`so_ply_WeddingPrepareItem` (vt 0x950) = "holds a WeddingCoupon" (`sp_FindItemFromInventory`) @ FUN_0059f490. The request
checks of Z02 §10 are these helpers (names pdb2016), each returning the code Z02 lists:

| Helper | @ | Checks → code |
|---|---|---|
| `Checker::WhenPropose(p)` | FUN_0059f060 | mode ∉ {1,2,6} → 0x12C1; Main ≠ 0 → 0x12C5 |
| `Checker::WhenBeProposed(t)` | FUN_0059ed90 | mode ∉ {1,2,6} → 0x12C2; Main ≠ 0 → 0x12C6 |
| `Checker::WhenProposeBoth(p, t)` | FUN_0059f180 | `so_DistanceSquar > 10000` → 0x12C3 |
| `Checker::WhenReserve(p)` | FUN_0059ede0 | mode ∉ {1,2} → 0x1301; Main ≠ 1 → 0x1303; no WeddingCoupon → 0x1308 |
| `Checker::WhenReservePartner(t)` | FUN_0059ee50 | same with 0x1302 / 0x1303 / 0x1308 |

### 4.2 Reservation and the timetable

```pseudo
WeddingHall::wh_Reserv(p, t, out i64 time) → bool                    @ FUN_005a0810   (only caller: 0x2053, Z02 §10)
    if Reserved: time = toTime_t(WeddingEnd); return false             # → 0x1306 "All spots for reservations are full." + when the hall frees
    Reserved = 1; Started = 0
    groom, bride = (p, t) if p.so_ply_GetGender() (vt 0x804) == 1 else (t, p)       # 1 = male (inferred); same-sex: t is the groom
    Groom = { groom.charNo, groom.so_CharName() (vt 0x56c) }; Bride = { bride.charNo, bride name }
    EnteringStart = now + 20 min; EnteringEnd = EnteringStart + 5 min; WeddingEnd = EnteringEnd + 10 min
    time = toTime_t(EnteringStart); return true
    # no check that this zone has the map "Wedding" or that p talks to a wedding NPC (original bug) Z13-B27

WeddingHall::wh_GuestCanEnter(ack) → bool                              @ FUN_0059ef40   (0x2056 GUEST_ENTER_READY)
    if Reserved and EnteringStart ≤ now ≤ EnteringEnd:
        ack { err = 0x1340, GroomID = Groom name, BrideID = Bride name, EnterStart = toTime_t(EnteringStart),
              WeddingStart = toTime_t(EnteringEnd), WeddingEnd = toTime_t(WeddingEnd), tm_* = _localtime64 of the three }
        return true
    ack.err = 0x1342 "It's not the right moment for you to enter at this time."; return false
    # 0x1340 = success (no client text; WeddingTask shows the ready window)

WeddingHall::wh_Routine()       once per wall-clock minute, from zs_mainthreadfunction @ FUN_005aca30      @ FUN_005a2a10
    if !Reserved: return
    if !Started and now ≥ EnteringStart:                  # time to start
        Started = 1
        n = wh_RecallCouple(Groom.RegistNumber) + wh_RecallCouple(Bride.RegistNumber)
        if n == 2: wh_Start()
        else: zone ring ← 0x2055 NC_ACT_WEDDING_COUPLE_ENTRANCE_RNG {          # size 0x10 (pdb2016)
                  ZONERINGLINKAGESTART start = { u8 myZoneNo, u16 0xFFFF, u32 0xFFFFFFFF },
                  u32 groom = Groom.RegistNumber, u32 bride = Bride.RegistNumber, u8 RecallCount = n }
    elif now ≥ WeddingEnd:                                 # (Started, or not yet due → this branch only when Started)
        Reserved = 0; Started = 0                          # hall free again; no log, no message

WeddingHall::wh_RecallCouple(charNo) → bool                            @ FUN_005a27f0
    q = som_FindPlayer(charNo); none → false
    if q.so_ply_MH_GetActiveMH() (vt 0x130) != 0: return true             # counted, but not moved (original bug) Z13-B25
    if q.so_Field == 0 or q's map is "EldPri" (Elderine prison, inferred): return false
    sp_DestroyItem(q, WeddingCoupon, 1)                                    # the reservation item is consumed here
    if q.mode == 4: so_ply_ReinforceFoldtent (vt 0x488)                     # leave the tent
    q.so_LinkToReserv({ "Wedding", "Wedding", x 558, y 154 }, 1) (vt 0x3fc)
    return true

0x2055 NC_ACT_WEDDING_COUPLE_ENTRANCE_RNG (zone ring)  ZoneListenSession::zls_… @ FUN_005a2b60
    if start.zoneNo == myZoneNo:                         # back at the hall zone
        if RecallCount == 0: Reserved = 0; Started = 0
                             GameLog ← 0x065F NC_LOG_WEDDING_HALL_CANCEL { u32 groom, u32 bride }
        else: wh_Start()                                 # also with only one of the two found (original bug) Z13-B26
    else:
        RecallCount += wh_RecallCouple(groom) + wh_RecallCouple(bride)
        forward the 16 bytes unchanged otherwise to the next zone (zcs_Send, Z01 §10)
```

`&weddingreset` (Z11) sends the same packet with the GM as groom and bride and count 0: the other zones do not find the GM,
so the lap returns with 0 and the GM's zone cancels its reservation (it is also an ordinary cancel log line).
`0x10B2 NC_CHAR_WEDDING_CANCEL_WEDDING` from the WM (Z07 §5.4, @ FUN_005a07d0) clears `Reserved` / `Started` only while not
started; no log.

### 4.3 Ceremony

```pseudo
WeddingHall::wh_Start()                                                @ FUN_005a25a0
    arg = Groom.CharacterName + " " + Bride.CharacterName              # PineScriptToken, the script's InitFlag
    wh_Field = the FieldMap "Wedding" of this zone (fieldlist search)
    if none: assert "WeddingHall::wh_Start : Map not found"; return      # Reserved stays until WeddingEnd
    wh_Field.CinemaComplex.cc_PlayFilm("Wedding/Wedding", arg)          # scenario ScenarioBookShelf/Wedding/Wedding.ps
    CAnnounceSystem::AnnounceSystem_WeddingStart(Groom name, Bride name)   (below)
    GameLog ← 0x065E NC_LOG_WEDDING_HALL_START { u32 Groom.RegistNumber, u32 Bride.RegistNumber }
```

The scenario `9Data/Shine/ScenarioBookShelf/Wedding/Wedding.ps` (texts in `Script/Wedding.txt`) runs the ceremony
(scenario commands are Z02 §12 / Z09):

| Time from start | Script |
|---|---|
| 0 | `timelimit Min 15` (timeout → `WeddingEnd`); names split from InitFlag; NPCs `PledgeBook` (557, 1137), `WeddingDreian` (501, 1106); door `OX_gate` opened |
| 0–4 min | four `chatwin "Wedding1"` one minute apart (guests enter: `EnteringStart … EnteringEnd`) |
| ~4 min | door closed; `teleportall Split 304 833 808 833`; groom to (536, 580), bride to (582, 580); both walk to y 620, later y 1078 |
| ~4–8 min | 22 lines (`Wedding2…13`, `Book1…9`) 10 s apart |
| ~8 min | `weddingcomplete` (below), `abstateset StaWeddingSub02 1 259200000` (3 days) on both; door opens; couple walks back; `MapLinkGate` NPC at (549, 129) links a clicker to Eld (17214, 13445) |
| 15 min | timeout `WeddingEnd`: `linkto all "Eld" 17214 13445`, NPCs vanish |

The commented-out `WaitBookClick` block (both click the pledge book) and `itemcreate "MiniWedding01_1"` are unused in 2016;
the present comes from 0x1092 (Z07 §5.2).

```pseudo
script statement "weddingcomplete" (2 arguments, ignored)    PineEventScriptNode::ShineWeddingComplete
    ctor / sb_CloneMe: OtherStatement("weddingcomplete", 0, 2, 2)            @ FUN_004e8e40 / FUN_004eaef0
    sa_Step:                                                               @ FUN_004f6b70
        g = som_FindPlayer(weddinghall.Groom.RegistNumber); b = som_FindPlayer(weddinghall.Bride.RegistNumber)
        if both on this zone (and vt 0x4d0 == 2 for both: the folded default returns 2 for every player, always true):
            Character DB ← 0x1091 NC_CHAR_WEDDING_DO_REQ { u16 g.handle, u32 g.charNo, u32 Partner = b.charNo }   (12 bytes)
        pop the script stack (next statement); nothing is sent or shown when one is missing
    # the DB answer 0x1092 (Z07 §5.2) reloads both, gives MiniWedding01_1 and the two skills
```

The only other sender of 0x1091 is `&wedding <name>` (Z11, `ac_Wedding` @ FUN_0041f3a0: `{GM handle, GM charNo, target
charNo}`, no status check; the DB refuses unless the two rows point at each other, D02 §11).

```pseudo
CAnnounceSystem::AnnounceSystem_ProposeAccept(a, b)   (0x2051 accepted: a = proposer, b = acceptor)      @ FUN_005b92a0
CAnnounceSystem::AnnounceSystem_WeddingStart(groom, bride)                                              @ FUN_005b9380
    if AnnounceData has the row (12 resp. 13): text = sprintf(row.Message, a, b)
        Send_PROTO_NC_ANNOUNCE_Z2W_CMD(type = 12 resp. 13, text)                                       @ FUN_005b8d30
            WM ← 0x6401 NC_ANNOUNCE_Z2W_CMD { u8 AnnounceType, u8 SizeOfMessage = strlen + 1, char Message[] }   (W01 relays it world-wide)
```

### 4.4 Married-state checks (`Checker`, per minute and on every 0x1081)

`so_ply_WeddingData` (vt 0x954, Z07 §5.1) and `ShinePlayer::so_Routine` (once per wall-clock minute, after the
charged-item checks, @ FUN_0056c790) both dispatch on `Main`: 1 → `ApplicationLimit`, 2 → `DivorceLimit`, 3 →
`DelayLimit`. On 0x1081 this runs **before** the copy is sent to the client, so the client gets the corrected status.
"Save(Main | Sub′)" below = take a copy of `sp_WeddingData`, set Status, call `so_ply_WeddingInfoUpdate` (vt 0x95c):
`sp_WeddingData = copy` and Character DB ← `0x1082 NC_CHAR_WEDDINGDATA_CMD` (same 0x2b-byte body; D02 §11 writes the row)
@ FUN_0059f390. Messages are `0x205D NC_ACT_WEDDING_DIVORCE_REQ_ACK { u16 err }` (`so_SendErrorCode(8, 0x5d, code)`).

```pseudo
Checker::ApplicationLimit(p)          Main 1 (engaged)                                        @ FUN_0059f1b0
    if now ≥ SubWhen (ApplicationLimit, set to proposal + 3 days by the DB):
        Character DB ← 0x1085 PROPOSE_CANCEL_REQ { u16 handle, u32 charNo, u32 Partner }     # every minute until the reload (no lock)

Checker::DelayLimit(p)                Main 3 (divorced, delay period)                         @ FUN_0059f2d0
    if Sub ≠ 0: so_ply_DivorceProcess() (vt 0x960); return
    if now ≥ SubWhen (DelayLimit, divorce + 7 days):
        Character DB ← 0x1087 ESCAPE_DIVORCE_REQ { u16 handle, u32 charNo, u32 Partner }     # → Main 0 (D02), reload on 0x1088

ShinePlayer::so_ply_DivorceProcess()  the divorce takes effect on this character, once       @ FUN_0059f550
    Character DB ← 0x4825 NC_SKILL_ERASE_REQ { u16 handle, u32 charNo, u16 SummonMate01 }
    Character DB ← 0x4825 { handle, charNo, u16 PowerofLove01 + 30000 }                       # passive ids are stored + 30000
    sp_DestroyItem(MiniWedding01_1, 1) from the inventory (box 9, ci_Inventory), else from box 8 (inferred: equipped)
    so_AbnormalState_Reset 293, 294, 295; so_RecalcAbstateParamReady (vt 0x528)
    if Sub == 2: p ← 0x205D {0x1389} (TextData2: "Your partner used "Annulment" , you are divorced.")
    Save(Main 3 | Sub 0)
    p ← 0x205D {0x1386} "Divorce proceeding complete.  You are now single."
    # the DB writes Main 3 / Sub 1 for a normal divorce and Sub 1 (user) / 2 (partner) for the annulment item (D02 §11)

Checker::DivorceLimit(p)              Main 2 (married), by Sub                                @ FUN_005a1c90
    Sub 0:  sp_UnlockRefundReq(); sp_UnlockRefundCancelReq()
    Sub 1 … 4 (and 9 … 15):  if now < SubWhen: return                 # DivorceLimit = application + 10 min (w00 DB)
        Sub 1 (my agreement application expired unanswered):
            if sp_IsLockedRefundCancelReq(): return
            Character DB ← 0x108F DIVORCE_CANCEL_REQ { u16 handle (stale), u32 charNo = mine, u32 Partner, u8 IncreseCount 0 }
            lock: sp_LockRefundCancelReq() on p and on the partner if on this zone
        Sub 2 (partner's agreement application expired, I did not agree):
            same, but { charNo = Partner, Partner = mine }                 # the applicant's row: 1 → 5 (refund on its next load)
        Sub 3, 4 (forced divorce, refusal window over):
            Character DB ← 0x108D DIVORCE_DO_REQ { u16 handle (stale), u32 charNo = Partner, u32 Partner = mine, u8 Reason 1 }
            # no lock: repeated every minute until the reload; both partners send it (original bug) Z13-B28
        other: nothing
    Sub 5 / 7 (my agreement / forced application was cancelled: partner refused or let it expire; DB marker +4):
        Save(Main 2 | Sub 0)
        if !sp_IsLockedRefundReq(): sp_LockRefundReq(); so_ply_IncDecMoney(+250 000 resp. +750 000, 1)     # fee of 0x205B / 0x205C refunded
        p ← 0x205D {0x1387 = 4999} "Your spouse refused to get a divorce."    # also when the lock skipped the refund
    Sub 6 (partner applied by agreement, first notice):  p ← 0x205D {0x1385} "Your spouse has filed for a collaborative divorce."
        Save(Main 2 | Sub 2)
    Sub 8 (partner applied by force, first notice):      Save(Main 2 | Sub 4)
        # then so_ply_WeddingData sees Sub 4 and sends 0x205D {0x1384} "Your spouse has filed for an uncontested divorce."
```

**Answer to the D02 question (sub-status 5–7).** The zone does not mask bit 2: `Checker::DivorceLimit` handles 5, 6, 7 and 8
as explicit cases. Bit 2 (+4) is a "notify once" marker that the zone consumes and clears through `0x1082`: 5 / 7 = "your
application was cancelled" (refund 250 000 / 750 000 + message 0x1387, back to Sub 0), 6 = "partner applied by
agreement" (message 0x1385, stored as 2), 8 = "partner applied by force" (stored as 4, message 0x1384). The handling runs
on the next `0x1081` (login, map change, the reloads of Z07 §5.2) or minute tick. The w00 DB writes 4 directly for the
forced partner (D02), so case 8 is reached only with a DB that writes 8 *(inferred: older procedure)*. On the client
side only `Main` matters: WeddingTask stores `Status & 0xF` from 0x1081 (FUN_006dd280).

The refund lock (`LockRefundReq`) and the cancel lock (`LockRefundCanCelReq`) live only in the zone process: they stop a
repeated refund / cancel request within one session and are cleared on Sub 0 and at every LOGINCOMPLETE *(inferred
purpose)*.

### 4.5 Ring refresh of a partner's wedding data

```pseudo
ZoneRingPacketRefreshWeddingInfo::zrpb_Request(charNo, buf)        (callers: the DB answers 0x1086 … 0x1090, Z07 §5.2)   @ FUN_005a91c0
    q = som_FindPlayer(charNo)
    none:        zone ring ← 0x10AB NC_CHAR_WEDDING_REFRESH_INFO_RNG { ZONERINGLINKAGESTART { myZoneNo, 0xFFFF, u32 charNo } }   (7 bytes)
    q.so_Field:  zrpb_Success: Character DB ← 0x1080 WEDDINGDATA_REQ { u16 q.handle, u32 q.charNo }       @ FUN_005a8950
    q without a field (logging in / linking): nothing (original bug) Z13-B29

0x10AB on the ring   ZoneListenSession::zls_NC_CHAR_WEDDING_REFRESH_INFO_RNG                              @ FUN_005a0e00
    zls_TravelComplete(start) (back at the origin): drop
    q = som_FindPlayer(start.regnum); q with a field → zrpb_Success (reload); else forward unchanged
```

The class has no state; its three vtable slots are the shared no-op FUN_00509900, so the methods are only called
directly.

### 4.6 Partner summon (`SummonMate01`, Z09 §28.4 hand-over)

```pseudo
skill cast end, ShineMobileObject::so_Routine @ FUN_0056a080 (skill effect branch; Z03 owns the cast):
    if skill == ss_SummonMate and the caster is not in a mini house (vt 0x130) and has a field:
        buf = PROTO_NC_CHAR_WEDDING_PARTNER_SUMMON_RNG (pdb2016, 0x23 bytes) { RegisterNumber = Partner.RegisterNumber,
              Name3 map = caster's map name, SHINE_XY_TYPE coord = caster's position (*(p+0x66)) }
        ZoneRingPacketSummonPartner::zrpb_Request(caster, buf)
    smo_SkillResultPacket(...)                                       # the skill result is sent either way

ZoneRingPacketSummonPartner::zrpb_Request(caster, buf)                                                   @ FUN_005a83b0
    buf.from = 1; buf.to = shineparam levellimit; buf.err = 0xFCF
    for each row of the NPC option table "LinkTable" (OptionReader order): if mapid(row+0x35) == mapid(buf.map):
        if FieldLevelDataBox::fldb_GetFieldLv(row+0x14) exists: from = LvFrom, to = LvTo                 # level band of the map (inferred)
        break
    q = som_FindPlayer(buf.RegisterNumber)
    none: zone ring ← 0x10AA NC_CHAR_WEDDING_PARTNER_SUMMON_RNG { start = { myZoneNo, caster.handle, caster.charNo }, rest of buf }  (0x23 bytes)
    q.level ∉ [from, to] or !q.so_ply_IsLink_OutMap_AndSendErrorMsg() (vt 0xa74):
        caster ← 0x2434 NC_BAT_SKILLBASH_CAST_FAIL_ACK { 0xFCE } "Skill usage is prohibited in this area." (Z03 §5.2 table)
    q in a mini house: nothing
    q.mode == 0: zrpb_Failure(caster, buf) → caster ← 0x2434 { buf.err = 0xFCF } "Your spouse is not online, skill cannot be used."
    else: zrpb_Success(caster, buf)

zrpb_Success(_, buf)                                                                                      @ FUN_005a8680
    q = som_FindPlayer(buf.RegisterNumber); must be a player (vt 0x4d0 == 2, always true)
    q ← server menu (Z02 §6.6) title "Summons", "Yes" → smfm_LinkWithoutNPC { buf.map, buf.coord }, "No" → smfm_Cancel,
        timeout/range arg 1000; q.sp_MiscFlag.BeSummoned = 1
    # smfm_LinkWithoutNPC @ FUN_0050f1d0 links only while BeSummoned (so_LinkTo(arg, 6, 9, 10)) and clears it;
    # 0x3C02 skips the menu range check while BeSummoned (FUN_0050fe60); smfm_Cancel, sp_ServerMenuTitle (any new menu) and LOGINCOMPLETE clear it

zrpb_Failure(caster, buf): caster ← 0x2434 { buf.err }                                                    @ FUN_005a8890

0x10AA on the ring   ZoneListenSession::zls_NC_CHAR_WEDDING_PARTNER_SUMMON_RNG                             @ FUN_005a0c90
    zls_TravelComplete (back at the origin): caster = zls_FindPlayer(start); if online: zrpb_Failure(caster, buf)   # 0xFCF or 0xFCE
    q = som_FindPlayer(RegisterNumber) with a field:
        level in [from, to] and vt 0xa74 true: zrpb_Success(_, buf); stop (the origin is not told)
        else: forward with err = 0xFCE
    else forward unchanged
    # forwarded copies are built with PROTO_NC_CHAR_WEDDING_PARTNER_SUMMON_RNG::operator= @ FUN_0059eee0
    # the remote branch does not test the mini house or mode 0 as the local one does
```

The 2016 client shows 0xFCE / 0xFCF through its cast-fail handler (Z03 §5.2). No cooldown or cost is applied here beyond
the skill's own (Z03).

### 4.7 Client side

- `WeddingTask::OnProcessNetMsg` FUN_006dd280: 0x1081 keeps `Status & 0xF` (Main), When, SubWhen and the partner name
  for `WeddingInfoWin::SetWeddingInfo_006da790`; **0x1094 PARTNER_INFO_ACK is handled** (`SetWeddingInfo_006da330`
  FUN_006da330: for Main 2 it shows "Name: %s", "Level: %d", "Married", the wedding date (`When`), and online state / last
  login; Main 1 "Engaged", Main 3 "Divorced"). This corrects Z07 §5.3 ("no handler for 0x1094").
- `Recv_NC_ACT_WEDDING_DIVORCE_REQ_ACK` FUN_006dd040 (0x205D): 0x1380 "Registration for divorce procedure is complete.",
  0x1384 yes/no dialog "Your spouse has filed for an uncontested divorce." (sets a flag at task+0x70; the answer sends
  0x205C / 0x205E, Z02 §10 *(inferred)*), 0x1385 OK dialog "…collaborative divorce.", 0x1386 "Divorce proceeding complete.
  You are now single.", 0x1387 "Your spouse refused to get a divorce.", 0x1389 OK dialog (TextData2) annulment; other codes
  through `ErrMsgTable::GetErrMsg` (0x1381–0x1383, 0x1388 have texts).

---

## 5. Pets, player side: `PetInfoPlayer` and the summon flow

Z07 §9 has the pet requests and DB answers (0xD404 / 0xD406 / 0xD407 / 0xD409 / 0xD40C / 0xD40E / 0xD412). This section
covers the player methods behind them: the item actor, casting, summon / unsummon, the naming prompt, mind / stress and
the re-summon after a map link. The `ShinePet` object (`spt_*`, its routine, AI, `CPetData` tables, Lua `cPet_*`) is §6
(part 6); only its effect on the player state is given here.

### 5.1 Data

`ShinePlayer::sp_PetInfo` (`PetInfoPlayer`, 0x48 bytes at **p+0x2ab60**) *(pdb2016)*. This replaces the offsets Z07 §9
listed by hand (they agree):

| Off | p+ | Member | Meaning |
|---|---|---|---|
| +0x00 | 0x2ab60 | `nSummonState` | `PetSummonStateType`: 0 `PSST_NONE`, 1 `CASTING`, 2 `CASTED`, 3 `WAIT_CREATING`, 4 `WAIT_1ST_LOADING`, 5 `1ST_SUMMONED`, 6 `RESUMMONED`, 7 `UNSUMMONNING` (never set in 2016), 8 `LINKING_RESUMMON` |
| +0x04 | 0x2ab64 | `nNameDecisionMode` | `PetNameDecisionMode`: 0 `PNDM_NONE`, 1 `CHECK_NAME`, 2 `MODIFY_WAIT` (0xD405 sent), 3 `MODIFIABLE` (client accepted, 0xD407 allowed), 4 `FIXED` |
| +0x08 | 0x2ab68 | `nCallingState` | `PetNameCallingState`: 0 `PNCS_NONE`, 1 `PNCS_CALLING` (master said the pet's name, §5.9; read by Lua `cPet_IsMasterCalling`, §6) |
| +0x0c | 0x2ab6c | `nCastEndTime` | `g_Now` tick when the summon cast ends |
| +0x10 | 0x2ab70 | `nCastingLockIndex` | inventory lock index taken for the cast |
| +0x12 | 0x2ab72 | `nCastSlot` | inventory slot being cast (0xFFFF none) |
| +0x14 | 0x2ab74 | `nSummonSlot` | inventory slot of the summoned pet item (0xFFFF none) |
| +0x16 / +0x18 | 0x2ab76 / 78 | `nWalkSpeed` / `nRunSpeed` | both = `CPetData::GetPetSpeed(PetIDX)` (`sp_PetSystem_FillCommonInfo`) |
| +0x1c | 0x2ab7c | `nId` | pet id (`CPetData::GetPetID`, from the item's `InxName`) |
| +0x20 | 0x2ab80 | `nHandle` | pet object handle |
| +0x24 | 0x2ab84 | `nRegNum` | pet DB key (`0xFFFFFFFF` = not created yet) |
| +0x28 | 0x2ab88 | `sName` | `Name4` (16 bytes) |
| +0x38 / +0x3c | 0x2ab98 / 9c | `nMindMil` / `nStressMil` | mind / stress × 1000 (u32) |
| +0x40 / +0x44 | 0x2aba0 / a4 | `nMindDiffMil` / `nStressDiffMil` | pending change × 1000 (i32), applied by §5.7 |

Next to it: `sp_PetInfoLink` (`PetInfoForLink`, p+0x2aba8: `u8 bDoResummon`, `u64 xResummonCode` +8, `u16 nSummonSlot`
+0x10, `u32 nId` +0x14, `u32 nRegNum` +0x18), `sp_Pet_pObject` (p+0x2abc8, the `ShinePet`; `so_PetSystem_GetPet` player
vt 0xe44 FUN_0055a8a0 returns it), three `Metronome {u32 m_NextTick, u32 m_TickInterval}` (`sp_Pet_HouseTick` p+0x2abcc,
`sp_Pet_BoothTick` p+0x2abd4, `sp_Pet_DanceTick` p+0x2abdc) and `sp_Pet_DanceDataIndex` (p+0x2abe4).
`Metronome::operator unsigned char` FUN_004011c0: `if NextTick < g_Now: NextTick += Interval; return 1` else 0.
`sp_PetSystem_GetPetInfo` FUN_00419430 returns `&sp_PetInfo` (used by `ShinePet`).

```pseudo
sp_PetSystem_InitPetInfo(p):                @ FUN_004d1ff0  (called at LOGINCOMPLETE, after unsummon / cancel)
    nId = nRegNum = 0xFFFFFFFF; sp_Pet_pObject = null; state = NONE; naming = NONE; calling = NONE; nCastEndTime = 0
    nCastingLockIndex = nCastSlot = nSummonSlot = nHandle = 0xFFFF; speeds 0; sName = ""; mind = stress = diffs = 0
sp_PetSystem_InitPetInfoLink(p):            @ FUN_004d2090
    bDoResummon = 0; xResummonCode = 0; nSummonSlot = 0xFFFF; nId = nRegNum = 0xFFFFFFFF
```

**Pet item** = item attribute class 36 (0x24, `ItemAttrCls_Pet`), attribute `ShineItemAttr_Pet` (0x1a bytes at
`SHINE_ITEM_STRUCT.itemattr`, i.e. `ItemTotalInformation` +0xa) *(pdb2016)*: `+0 u32 nPetRegNum`, `+4 u32 nPetID`,
`+8 char sName[17]`, `+0x19 u8 bSummoning`. ITI offsets: RegNum +0xa, name +0x12 (Z07's "cell +0xa / +0x12").

| Method | @ | Behaviour |
|---|---|---|
| `iac_GetAttrSize` / `iac_fill2buffer` / `iac_fill2struct` | 0063ecd0 / 0063ea00 / 0063ebf0 | 0x1a; copy the 26 bytes verbatim (client and DB see `bSummoning`) |
| `iac_itemcreate` | 0063f470 | RegNum = 0xFFFFFFFF, PetID = 0xFFFFFFFF, name and `bSummoning` = 0 |
| `iac_GetPetRegistNumber` / `iac_GetPetName` | 004d06d0 / 004d0650 | RegNum (null ITI → 0xFFFFFFFF); the 16 name bytes as `Name4` (null → "") |
| `iac_SetPetName` | 004d05f0 | copies `min(len, 16)` bytes and terminates (byte 16 = +0x22 when longer) |
| `iac_SetDuringPetSummon` | 00517d00 | `bSummoning = v`; only ever called with 1 (Z13-B37) |

Items made by item mix (`sp_NC_ITEM_MIX_ITEM_REQ` FUN_00521540) and by `sp_CreateItemByAdmin` FUN_00527270 get
`nPetID = CPetData::GetPetID(GetPetIDX(ItemInfo.InxName))`, RegNum 0xFFFFFFFF, empty name, `bSummoning = 0`.

**Constants** (`gPetData`, `CPetData::ReadData` FUN_004cf870 from `SingleData.shn`; the Pup tables are §6): `Pup_MinMind` 1,
`Pup_MaxMind` 100, `Pup_MinStress` 1, `Pup_MaxStress` 10, `PupCastingTime` 1500 ms, `PupCoolTime` 5000 ms (2016 data).
The summon skill (cooldown carrier) is `ui_Pet.uip_PetSummonSkill` = `UsedItemEffect::uie_UseSkillID("UseSumPup")`, set by
`UseItemPet::uip_SetSkill` FUN_00596b10 at start-up (`ZoneServer_zs_start_sun` FUN_005adbd0).

### 5.2 State machine

```
            use item (Cast)            routine: cast end            Summon: spt_SummonPet
  NONE(0) ───────────────▶ CASTING(1) ─────────────────▶ CASTED(2) ─────┬─ RegNum known ──────────────▶ CASTED(2) ── 0xD40C ──▶ RESUMMONED(6)
    ▲  ▲                      │ move / run: CancelCasting              │                                (0xD40B sent)
    │  └──────────────────────┘                                        └─ new pet: spt_CreatePet ──▶ WAIT_CREATING(3)
    │                                                                        0xD40D sent                   │ 0xD40E (RegNum)
    │                                                                                                      ▼
    │                                                                                         WAIT_1ST_LOADING(4) ── 0xD40C ──▶ 1ST_SUMMONED(5)
    │  use the same item again / DB error / Lua / mini-house build: Unsummon (from 5 / 6 only)
    └──────────────────────────────────────────────────────────────────────────────────────────────
  LOGINCOMPLETE after a link: VirtualCast → LINKING_RESUMMON(8) ── routine ──▶ CASTED(2) → LinkResummon → (0xD40C) → RESUMMONED(6)
```

5 and 6 are both "pet out"; every pet behaviour (tendency, naming, chat calling, unsummon) requires one of them.

### 5.3 Using the pet item (`UseEffect::UseItemPet`, Z04 §6.3)

Reached from `NC_ITEM_USE_REQ 0x3015` (Z04 §6.1: mode ∈ {1, 2, 6}, the field allows items, cell checks). Results go out
as `0x3016 NC_ITEM_USE_ACK {u16 error, u16 useditem, u8 invenType}` (`so_ply_ItemUseResultPacket` vt 0x91c FUN_0045e610).

```pseudo
UseItemPet::uib_CanUseItem(p, cell) → code:                      @ FUN_0059b2b0
    fail(c) = p ← 0xD411 NC_PET_USE_ITEM_FAIL_ACK { u16 c } (sp_Send_NC_PET_USE_ITEM_FAIL_ACK FUN_004d15a0); return c
    p null:                                   return 0x3441
    no field (p+0x7a):                        fail(0x3442) "Your pet cannot be summoned. Please try later."
    field has no FieldAttr (+0xc):            fail(0x3443) "You cannot summon your pet in this area."
    FieldAttr.KingdomQuestMap (+0x36) == 2:   return 0x3444 (no 0xD411)
    FieldAttr.byCanItem (+0x9e) == 0:         fail(0x3444) "You cannot summon your pet in this area."
    p.smo_DuringCast() (vt 0xea0) == 1:       fail(0x345b)                           # no client text
    &p.sp_PetInfo == null:                    fail(0x3446)                           # dead check (Z13-B39)
    nCastEndTime > g_Now:                     fail(0x345b)
    switch state:
        NONE, 1ST_SUMMONED, RESUMMONED:
            mode = p.smo_GetMode() (vt 0x484)
            mode ∈ {1, 2} or mode ≥ 8:        return 0x700 (ok)
            else (0 or 3 dead / 4 tent / 5 booth / 6 riding / 7):   fail(0x3445) "Your pet cannot be summoned."
        CASTING:                              return 0x345b (no 0xD411)
        CASTED, WAIT_CREATING, WAIT_1ST_LOADING:   return 0x345c "Pet summoning is in progress." (no 0xD411)
        LINKING_RESUMMON:                     return 0x345d "Pet summoning is in progress." (no 0xD411)
        other (7):                            return 0x3460 "Your pet cannot be summoned. Please try later." (no 0xD411)
    # every non-0x700 code is then also sent as 0x3016, whose client handler shows FUN_00416430(code):
    # the codes sent through fail() appear twice (original bug) Z13-B38

UseItemPet::uib_DirectUse(p, slot, cell) → handled:               @ FUN_0059b660
    if p null: return 0
    if mode ∈ {1, 2}:
        if cell null, item has no InxName, or CPetData::GetPetIDX(InxName) null: return 0   # falls into the Z04 cast path
        if state == NONE or state ∈ {5, 6}: sp_PetSystem_Cast(p, slot)
    return 1                       # the pet item is never consumed; mode ≥ 8 returns 1 without any reply (unreachable: Z04 allows {1,2,6})
```

```pseudo
sp_PetSystem_Cast(p, slot) → ok:                                   @ FUN_004d31c0
    p.so_ply_AllCastCancel() (vt 0x8d0); p.so_ply_SendMoveFail() (vt 0xa4c); p.so_mobile_StopHere() (vt 0xa48); p.smo_BashStop() (vt 0xed8)
    r(c) = so_ply_ItemUseResultPacket(c, 9)     # 0x3016, inventory
    if state ∈ {5, 6}:  if slot ≠ nSummonSlot: r(0x702); return 0        # another pet item while a pet is out
    elif state ≠ NONE:  r(0x701); return 0
    if p has no sub-layer (+0x76) or layer.l_Sub == 3 (GM hidden):  r(0x701); return 0
    cell = inventory[slot]:  null → r(0x703) ("Try to use empty cell"); ITI null → r(0x702)
    attr null or attr class ≠ 36 → assert, r(0x702)
    if state ∈ {5, 6}:                         # same item again = dismiss
        (slot ≠ nSummonSlot → r(0x702) / other state → r(0x701), already excluded above)
        if sp_PetSystem_Unsummon(p): r(0x700); return 1   else r(0x701); return 0
    # state NONE: start the summon cast
    nCastEndTime = g_Now + PupCastingTime × 10 / 1000          (1500 ms → 15 ticks)
    nCastingLockIndex = lock list current index; nCastSlot = slot; state = CASTING
    id = GetPetID(GetPetIDX(ItemInfo[cell.itemid].InxName)); if any step fails: r(0x702); return 0
        # state stays CASTING with the times set (original bug) Z13-B35: 1.5 s later the summon fails with 0xD411 0x345e
    nId = id; nRegNum = attr RegNum; sName = attr name
    lock list vt 0x2c(nCastingLockIndex, 9, slot) (lock the cell); icl_IncIndex
    r(0x700)
    p ← 0x2047 NC_ACT_CREATECASTBAR { u16 millisec = PupCastingTime }   (to the player only)
    return 1
```

Every failing check answers through 0x3016; the cast itself has no 0xD411. While casting, `sp_NC_ACT_MOVEWALK_CMD`
FUN_00457c60 and `sp_NC_ACT_MOVERUN_CMD` FUN_00457fd0 call `sp_PetSystem_CancelCasting` when state == CASTING (before
their own checks):

```pseudo
sp_PetSystem_CancelCasting(p) → ok:                                @ FUN_004d23a0
    cell / ITI / attr at nCastSlot must exist (else assert, return 0; state stays CASTING)
    lock list vt 0x28(nCastingLockIndex) (release); p ← 0x2048 NC_ACT_CANCELCASTBAR {} (so_SendProtocol(8, 0x48))
    sp_PetSystem_InitPetInfo(p); return 1
```

### 5.4 Summon (`sp_PetSystem_PlayerRoutine`, `sp_PetSystem_Summon`)

`ShinePlayer::so_Routine` FUN_0056c790 calls `sp_PetSystem_PlayerRoutine` on every player tick, before the recovery
step (it also drives the tendency ticks, §5.7).

```pseudo
sp_PetSystem_PlayerRoutine(p):                                     @ FUN_004d2d20
    switch state:
    CASTING:  if nCastEndTime <= g_Now:
                  state = CASTED
                  if !sp_PetSystem_Summon(p): p.so_ply_AllCastCancel(); state = NONE
                  # nothing else is reset: the cast lock stays taken (original bug) Z13-B34
    1ST_SUMMONED, RESUMMONED:  naming prompt, §5.5
    LINKING_RESUMMON:  state = CASTED
                  if !sp_PetSystem_LinkResummon(p): p.so_ply_AllCastCancel(); state = NONE        # §5.8, silent for the client

sp_PetSystem_Summon(p) → ok:                                       @ FUN_004d2640
    if p has no sub-layer or l_Sub == 3: return 0                              # silent
    if p.so_PetSystem_GetPet() (vt 0xe44) ≠ null: p ← 0xD411 {0x3458} "Your pet is nearby already."; return 0
    pet = som_AllocObject(type 12 ShinePet) → handle h; null → assert "Too many pet", return 0
    h == 0xFFFF → assert, pet.so_Unmark(0,1,3) (vt 0x33c), som_FreeObject(h, REMOVE_NOW, 0x78); return 0
    nHandle = h
    cell / ITI / attr at nCastSlot (null → assert, return 0; the allocated pet object is not freed, Z13-B36)
    pet.spt_InitShinePet(); pet.spt_pItemTotalInfo = ITI; pet.spt_pItemAttr = attr
    pet.spt_SetMaster(p, p.charNo)                                             (§6)
    a = rnd(64) × 180 / 64  (degrees 0…177);  x = p.x + sin(a) × 50,  y = p.y + cos(a) × 50   (sr_sin1024/cos1024 >> 10)
    dir = 2 × (a < 90 ? a + 90 : a − 90)
    ok = pet.spt_SummonPet(p.map, x, y, dir, nId, p.layer)                     (§6: FillCommonInfo, regenerate; for a
        # pet without RegNum and state CASTED it first calls spt_CreatePet → DB 0xD40D NC_PET_CREATE_DB_REQ
        # {u16 p.handle, u32 p.charNo, Name4 "" , u8 mind, u8 stress (random in the PupServer row's ranges)},
        # state = WAIT_CREATING, naming = CHECK_NAME)
    if !ok: p ← 0xD411 {0x345e}; pet.so_Unmark(0,1,3); som_FreeObject(pet, REMOVE_NOW, 0x78); return 0
    sp_Pet_pObject = pet
    skill = ui_Pet.uip_PetSummonSkill;  null → return 0       # pet stays alive, state reset by the routine (original bug) Z13-B36
    p.smo_ply_SkillCoolTime(skill.id, PupCoolTime, 0, 0, 0) (vt 0xeac); p.so_ply_NewSkillCoolTime(skill.id, PupCoolTime / 1000) (vt 0x374)
    nSummonSlot = nCastSlot; nCastSlot = 0xFFFF; lock list vt 0x28(nCastingLockIndex) (release)
    p ← 0x2048 NC_ACT_CANCELCASTBAR {}
    attr.bSummoning = 1 (iac_SetDuringPetSummon)
    if nRegNum ≠ 0xFFFFFFFF: naming = CHECK_NAME; → CharDB 0xD40B NC_PET_LOAD_INFO_DB_REQ { u16 p.handle, u32 nRegNum }   (FUN_004d11e0)
    return 1
```

The state then advances by the DB answers (Z07 §9): `0xD40E CREATE_DB_ACK` (state 3: RegNum into `nRegNum` and the item,
`sp_PetItemSave`, 0xD40B, state 4) and `0xD40C LOAD_INFO_DB_ACK` (state 4 → 5, states 2 / 8 → 6; mind / stress × 1000).
A DB error unsummons (0xD40C) or leaves the state at 3 (0xD40E, Z07).

```pseudo
sp_PetItemSave(p):                                                 @ FUN_004d35e0   (only from 0xD40E)
    if (u32)nSummonSlot ≠ 0xFFFFFFFF (always true, Z13-B39): sp_PetItemAttrSave(p, inventory[nSummonSlot], 9, nSummonSlot)
sp_PetItemAttrSave(p, cell, type, slot):                           @ FUN_004d2ff0
    if slot < 0: return
    key = slot & 0x3ff | type << 10
    lock list vt 0x40(lockindex, cell, ITI, &key, &key)      (reserve the changed copy = the cell as it is now)
    → GameDB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ { u16 p.handle, u32 p.charNo, u16 lockindex, u64 ITI.registnum,
          u16 itemid, attr (attr class vt 0xc size: 0x1a) }        (length 0x14 + 0x1a)
    lock index += 1
```

### 5.5 Naming prompt (`0xD405`)

```pseudo
sp_PetSystem_PlayerRoutine, state ∈ {5, 6}:                        @ FUN_004d2d20
    if naming == CHECK_NAME and nRegNum ≠ 0:
        cell / ITI / attr at nSummonSlot, attr class 36, dynamic cast to ItemAttrCls_Pet
            # each failure: assert (texts say "sp_PetSystem_Unsummon") and return; repeats every tick while it lasts
        if sName == "" and the item's name == "":
            sp_Send_NC_PET_ASK_NEW_NAME_REQ(p, nHandle, nId, nFirstSummon = (state == 1ST_SUMMONED))
        else: naming = FIXED

sp_Send_NC_PET_ASK_NEW_NAME_REQ(p, handle, id, first):             @ FUN_004d0c90
    if handle == 0xFFFF: return
    p ← 0xD405 NC_PET_ASK_NEW_NAME_REQ { u16 nPetHandle, u32 nPetID, u8 nFirstSummon }
    naming = MODIFY_WAIT           # also when the length check fails
```

Client (`GameFrameWork`, FUN_004bb170, 2017 `On_NC_PET_ASK_NEW_NAME_REQ`): looks `nPetID` up in its pet table; found → opens
the naming dialog for `nPetHandle` with "You're my new master! Hello! What are you going to call me?" (`nFirstSummon` ≠ 0) or
"What name should I answer to?" (0) and answers `0xD406 {u16 0x34C0, u16 nPetHandle}`; not found → `0xD406 {0x34C1, handle}`,
which the server ignores (naming stays `MODIFY_WAIT`, the pet stays unnamed until the next summon). The rest of the naming
exchange (0xD406 → `MODIFIABLE`, 0xD407 / 0xD403 / 0xD404 → `FIXED`, 0xD409 cancel → `FIXED`) is Z07 §9.
`sp_Send_NC_PET_SET_NAME_DB_REQ` FUN_004d1110 (0xD403 `{u16 p.handle, u32 nRegNum, Name4 name}`, only for names of 4+
characters and a known RegNum).

So a pet is asked for a name once per summon while both names are empty; after a rename cancel (`FIXED`) it is asked again
at the next summon. A link resummon (§5.8) sets `FIXED` directly and never asks.

### 5.6 Unsummon

```pseudo
sp_PetSystem_Unsummon(p) → ok:                                     @ FUN_004d2990
    if state ∉ {5, 6}: return 0                                     # silent
    if sp_Pet_pObject == null: p ← 0xD411 {0x3481} "Your pet summons cannot be cancelled. Please try later."; InitPetInfo; return 0
    if pet.so_ObjectType() (vt 0x4d0) ≠ 12:
        p ← 0xD411 {0x3482} "Your pet summons cannot be cancelled."; InitPetInfo (sp_Pet_pObject = null)
        # then falls through and calls sp_Pet_pObject->vt[0x33c]: null dereference, zone crash (original bug) Z13-B31
    sp_PetSystem_ApplyChangedTendency(p); sp_PetSystem_SaveTendency(p)          (§5.7: 0xD401 to the Character DB)
    pet.so_Unmark(0, 1, 3) (vt 0x33c); som_FreeObject(pet handle, REMOVE_NOW, 0x78)
    sp_PetSystem_InitPetInfo(p); return 1
    # the item's bSummoning stays 1 (Z13-B37); the unmark sends 0x1805 { u16 pet handle } to everyone in sight (§6.4)
```

Callers: `sp_PetSystem_Cast` (same item again, §5.3), `gds_NC_PET_LOAD_INFO_DB_ACK` / `gds_NC_PET_SET_NAME_DB_ACK` on a
DB error (Z07 §9), `sp_Schedule_BuildMiniHouse` FUN_00576570 (building a mini house, Z07 §6.3), Lua `cPet_Unsummon`
FUN_005d65a0 (§6). Nothing unsummons on logout, death or a map link: the player only records the link state (§5.8) and the
`ShinePet` notices the missing master itself: its routine frees it as soon as `spt_FindMaster` fails (master gone, in
mode 0 / 7, or on another map; §6.3).

### 5.7 Mind and stress (tendency)

```pseudo
sp_PetSystem_ChangeTendency(p, cond):                              @ FUN_004d2470
    if state ∉ {5, 6}: return
    mt = CPetData::GetPetMindType(nMindMil / 1000)       (PupMind.shn rows: 1–25 PM_SJ, 26–50 PM_NT, 51–75 PM_NF, 76–100 PM_SP, 2016 data §6.1); MAX → return
    d = CPetData::GetPetTendencyModifyData(mt, cond)     @ FUN_004cf440: the last PupFactorCondition row with
        (PupMindType, PupFactorConditionType) = (mt, cond): type = PupFactorType, value = ±Value / 1000 (IsMinus → −); no row → type MAX
    PF_STRESS (0): nStressDiffMil += (long)(value × 1000)      PF_MIND (1): nMindDiffMil += (long)(value × 1000)

sp_PetSystem_ApplyChangedTendency(p):                              @ FUN_004d2520
    if state ∉ {5, 6}: return
    m = (u32)(nMindMil + nMindDiffMil);  if (u8)(m / 1000) < MinMind or > MaxMind: m = bound × 1000
    s = (u32)(nStressMil + nStressDiffMil); same with MinStress / MaxStress
    nMindMil = m; nStressMil = s; diffs = 0
    # unsigned arithmetic and a byte compare: a sum below 0 wraps to ≈ 4.29e9 and its (u8)(/1000) lands anywhere in
    # 0…255, e.g. stress 1.0 − 2.0 → 54 → clamped to MaxStress 10, mind 1.0 − 2.0 → kept as mind 54 (original bug) Z13-B30

sp_PetSystem_SaveTendency(p):                                      @ FUN_004d25d0
    if state ∈ {5, 6}: sp_Send_NC_PET_SET_TENDENCY_DB_REQ(p, nMindMil / 1000, nStressMil / 1000)
sp_Send_NC_PET_SET_TENDENCY_DB_REQ(p, mind, stress):               @ FUN_004d1040
    if p.handle == 0xFFFF or nRegNum == 0xFFFFFFFF: return
    → CharDB 0xD401 NC_PET_SET_TENDENCY_DB_REQ { u16 nMasterHandle, u32 nPetRegNum, u8 nPetMind, u8 nPetStress }   (both clamped to the bounds)
```

Who changes the tendency (cond = `PupFactorConditionTypeEnum`) *(pdb2016)*:

| cond | Raised by | When |
|---|---|---|
| 1 `PFC_S_DANCE` | `ShinePlayer::so_Routine` | every 60 s (`sp_Pet_DanceTick`, 600 ticks, armed by `sp_DoEmotion` FUN_00458860 for an emotion whose `ActionViewInfo` row has byte +0x71 == 1) while the emotion is still shown |
| 2 / 3 / 4 `PFC_S_SUCCESS` / `FAIL` / `CRIFAIL` | `gds_NC_ITEMDB_UPGRADE_ACK` FUN_0053b900, `_NEW_UPGRADE_ACK` FUN_0053bd20, `_BRACELET_UPGRADE_ACK` FUN_0053c0f0 | item upgrade result (success / fail / fail with destruction, Z05) |
| 5 `PFC_S_GATHER` | `sp_GatherComplete` FUN_0046b2f0 | gathering done |
| 6 `PFC_S_PROD` | `smo_ply_ItemProduce` FUN_0046c2d0 | production success |
| 7 `PFC_S_MOVER` | Lua `cPet_Unsummon` (§6) | |
| 8 `PFC_S_REVIVALTOWN` | `so_KilledBy` FUN_00433be0 | on every death (Z13-B40) |
| 9 `PFC_S_REVIVALHERE` | `sp_ReviveNow` FUN_0057d290 | revived in place |
| 10 `PFC_S_RESTHOUSE` | `sp_RecoverPoint_House` FUN_0056b3b0 (tent, mode 4) and `so_Routine` (booth, mode 5) | tent: every 60 s (`sp_Pet_HouseTick`, armed by `sp_NC_ACT_PITCHTENT_REQ` FUN_00457760 only if the pet is out at that moment); booth: every 600 s (`sp_Pet_BoothTick`, armed by `sp_NC_BOOTH_OPEN_REQ` FUN_0058e900) (original bug) Z13-B32 |
| 11 `PFC_S_STORE` | – | never raised |
| 12 / 13 `PFC_M_ATTACK` / `PFC_M_DANCE` | Lua `cPet_ChangeMind` (§6.6) | pet AI; the string compare is inverted: "dance" raises ATTACK, every other string DANCE (Z13-B44) |
| 14–16 `PFC_M_FOLLOW` / `TALK` / `REVOLUTION` | – | never raised (Z13-B44) |

The pending change is applied and saved (0xD401) on unsummon, on every character save (`WholeSaver::ws_save2DB` FUN_00455a10,
Z01 §8.4). Lua `cPet_SaveTendency` (§6.6) only *applies* the pending change (no 0xD401, Z13-B45). GM `&setpetinfo` / `&getpetinfo` are Z11 §7.7. `GetPetMindType` reads
`nMindMil` without the pending diff, so the mind *type* (and with it the factor rows used) only changes once a change is applied.

### 5.8 Re-summon after a map link

```pseudo
so_LinkTo(p, …) (pet part):                                        @ FUN_0049ad30
    if state ∈ {5, 6}:
        bDoResummon = 1; xResummonCode = (u64)p.charNo + 0x1BEC48797BAFC8B0
        link.nSummonSlot = nSummonSlot; link.nId = nId; link.nRegNum = nRegNum
WholeSaver::ws_save2worldmanager → sp_PetLinkResummonInfo_Save2World(p):     @ FUN_004d1760
    if state ∈ {0, 5, 6}:
        → WM 0x4033 NC_CHARSAVE_2WLDMAN_PET_LINK_RESUMMON_CMD { u32 nCharNo, u8 bDoResummon, u64 xResummonCode,
              u16 nSummonSlot, u32 nId, u32 nRegNum }    (0x17 bytes)
    # in states 1–4 and 8 nothing is sent (the WM keeps what it had, W01)
# the WM stores it (W01 §6.3, "pet re-summon" row) and the new zone gets 0xD412 NC_PET_LINK_RESUMMON_CMD → p.sp_PetInfoLink (Z07 §9)

sp_NC_MAP_LOGINCOMPLETE_CMD (pet part):                            @ FUN_00443390
    sp_PetSystem_InitPetInfo(p)
    if bDoResummon == 1 and xResummonCode == p.charNo + 0x1BEC48797BAFC8B0:
        if !sp_PetSystem_VirtualCast(p, link.nSummonSlot): sp_PetSystem_InitPetInfo(p)
    sp_PetSystem_InitPetInfoLink(p)

sp_PetSystem_VirtualCast(p, slot) → ok:                            @ FUN_004d2180
    if state ≠ NONE or no sub-layer or l_Sub == 3: return 0
    cell / ITI / attr at slot (null → assert, return 0); attr class ≠ 36 → assert, return 0
    nCastSlot = slot; state = LINKING_RESUMMON          # no cell lock, no cast bar
    id via ItemInfo.InxName → PetIDX → PetID (any miss → return 0)
    nId = id; nRegNum = attr RegNum; sName = attr name
    return nId == link.nId and nRegNum == link.nRegNum     # the item in that slot must still be the same pet

sp_PetSystem_LinkResummon(p) → ok:                                 @ FUN_004d2a40   (routine, state set to CASTED first)
    as sp_PetSystem_Summon (§5.4) with these differences:
        requires state == CASTED; an existing pet only asserts "ERR_PET_SUMMON_ALREADY" (no 0xD411)
        spt_SummonPet failure → 0xD411 {0x345e} and free, as there
        no cooldown, no lock release (none was taken), no 0x2048
        nSummonSlot = nCastSlot; nCastSlot = 0xFFFF; sp_Pet_pObject = pet; attr.bSummoning = 1
        nRegNum known → naming = FIXED (no name prompt); 0xD40B LOAD_INFO_DB_REQ   (→ 0xD40C: state 2 → 6)
```

The "code" is a fixed offset of the character number, a plausibility check only. A pet that was still being summoned or
named at the link (states 1–4) is not carried over.

### 5.9 Other pet hooks in player code

- **Chat calling** (`sp_NC_ACT_CHAT_REQ` FUN_0045a400): after a normal chat line is broadcast (not an `&` command, map
  allows chat, not spam), if the pet is out (5 / 6), has a RegNum and a name of at least 4 bytes, and the name occurs
  anywhere in the chat text (`strncmp` at every offset), `nCallingState = PNCS_CALLING`. The scan bound is the packet
  length, not the text length *(inferred: a few bytes past the text are compared)*.
- **Item break** (`ItemBreaker::ib_OK` FUN_0048d0d0, NPC item destruction): a class-36 item is refused while the state is
  1…8 (any pet activity, not only this item's): the cell lock is released and `0xD411 {0x345c}` "Pet summoning is in progress." is sent.
- **Relocation** (`ItemRelocationManager::irm_Exchange` FUN_00531e90): swapping two inventory cells (type 9, key `0x2400`) while
  the pet is out moves `nSummonSlot` along. `irm_Move` FUN_00531860 (into an empty cell), moves to other boxes, merges and
  splits do not (original bug) Z13-B33.
- **Mini house**: building one unsummons the pet (§5.6); in a tent the house tick raises `PFC_S_RESTHOUSE` (§5.7).

### 5.10 Client side (2016 client, `GameFrameWork`)

- `0xD411 NC_PET_USE_ITEM_FAIL_ACK` (FUN_0049d350, 2017 `On_NC_PET_USE_ITEM_FAIL_ACK`): shows `FUN_00416430(code)` unless the
  code is 0x3440 or 0x3480 (success codes, never sent). Texts: 0x3441 / 0x3442 / 0x345e / 0x3460 "Your pet cannot be summoned.
  Please try later.", 0x3443 / 0x3444 "You cannot summon your pet in this area.", 0x3445 / 0x3446 "Your pet cannot be
  summoned.", 0x3458 "Your pet is nearby already.", 0x345c / 0x345d "Pet summoning is in progress.", 0x3481 "Your pet summons
  cannot be cancelled. Please try later.", 0x3482 "Your pet summons cannot be cancelled."; **0x345b has no text**.
- `0x3016 NC_ITEM_USE_ACK` (FUN_004abdb0): any code other than 0x700 and the special item codes goes through the same
  `FUN_00416430`, so pet codes from `uib_CanUseItem` show up a second time (Z13-B38).
- `0xD405`: §5.5. `0x2047` / `0x2048` cast bar (FUN_00499c10 / FUN_004d8f90): generic cast bar of mounts and pets.

---

## 6. Pets, object side: `ShinePet`, `CPetData`, pet AI scripts

§5 is the player side (state machine, summon, unsummon, tendency); this section is the pet object (`ShineObjectClass::ShinePet`,
object type 12), the tables in `gPetData` and the Lua interface the pet AI uses.

### 6.1 Tables (`CPetData gPetData`)

`CPetData` (0x50 bytes) *(pdb2016)*: seven row arrays `m_pPup*` + their counts, then the six `SingleData.shn` constants of §5.1
(`m_nMindMinValue` +0x38 … `m_nSummonCoolTimeMil` +0x4c). Ctor FUN_004ceee0 nulls the arrays, dtor FUN_004cef00 frees them.

```pseudo
CPetData::ReadData() → ok                                  @ FUN_004cf870   (from ZoneServer_zs_start_sleep FUN_005b67c0)
    read PupMain (row 0x46), PupServer (0x24), PupMind (6), PupPriority (5), PupCase (9), PupCaseDesc (0x70),
         PupFactorCondition (0x11) from ../9Data/Shine/<name>.shn (CDataReader::Read(path, u32 0x91/0x23/0xc/5/0x19/0x267/0x5e, row size))
    any file missing → assert "Fail to read <name>.shn"; any table empty → "Data is Empty in <name>.shn"; return 0
    allocate the arrays; read the six constants (§5.1)
    validate and copy row by row (failure → assert "<what> in <name>.shn, Index" with the row index, return 0):
      PupMain:      PupID ≠ 0 (the assert prints the not yet written destination row's PupID (original bug) Z13-B46);
                    strlen(PupIDX) ≥ 3; strlen(ItemIDX) ≥ 3
      PupServer:    strlen(PupIDX) ≥ 3; MinMind ≥ Pup_MinMind; MaxMind ≤ Pup_MaxMind; MinStress ≥ Pup_MinStress; MaxStress ≤ Pup_MaxStress
                    (min ≤ max is not checked)
      PupMind:      PupMindType 0…3; MinMind ≥ Pup_MinMind; MaxMind ≤ Pup_MaxMind
      PupPriority:  PupPriorityType 0…4; PriorityNum ≤ row count                         # the table is never read afterwards
      PupCase:      PupMindType 0…3; StressNum in [Pup_MinStress, Pup_MaxStress]; PupCaseType 0…40
      PupCaseDesc:  PupPriorityType 0…4; PupCaseType 0…40; PPT_Idle (4) ⇔ PupCaseType ≠ ALL_PUP_CASE (40);
                    PupIDX, SM_Inx, SoundFile: strlen ≥ 3 or exactly "-"; PupAIType 0…9; PPT_Idle ⇔ PupAIType ≠ PAI_SCRIPT (9)
      PupFactorCondition: PupMindType 0…3; PupFactorConditionType 0…16; PupFactorType 0…1; IsMinus 0/1;
                    Value ≤ (MaxStress − MinStress) × 1000 (PF_STRESS) or ≤ (MaxMind − MinMind) × 1000 (PF_MIND)
    return 1
```

Row structs (`PupMain {u32 PupID; char PupIDX[32]; char ItemIDX[32]; u16 PupSpeed}`, `PupServer {char PupIDX[32]; u8 MinMind,
MaxMind, MinStress, MaxStress}`, `PupMind {PupMindTypeEnum; u8 MinMind, MaxMind}`, `PupCase {PupCaseTypeEnum; PupMindTypeEnum;
u8 StressNum}`, `PupCaseDesc {PupPriorityTypeEnum; PupCaseTypeEnum; char PupIDX[32]; PupAITypeEnum; char SM_Inx[32]; u32
ActionEffectID; char SoundFile[32]}`, `PupFactorCondition {PupMindTypeEnum; PupFactorConditionTypeEnum; PupFactorTypeEnum; u8
IsMinus; u32 Value}`) and enums are *(pdb2016)*. Enums: `PupMindTypeEnum` PM_SJ 0, PM_NT 1, PM_NF 2, PM_SP 3; `PupPriorityTypeEnum`
PPT_MapLink 0, PPT_Die 1, PPT_CallPup 2, PPT_Follow 3, PPT_Idle 4; `PupCaseTypeEnum` SJ01…SJ10 0–9, NT01…NT10 10–19, NF01…NF10 20–29,
SP01…SP10 30–39, ALL_PUP_CASE 40; `PupAITypeEnum` PAI_NONE 0, FOLLOW 1, REVOLUTION 2, DANCE 3, ATTACK 4, ROAMING 5, ROTATION 6,
TALK 7, DIE 8, SCRIPT 9; `PupFactorTypeEnum` PF_STRESS 0, PF_MIND 1 (conditions: §5.7).

2016 data: PupMain 3 pets (1 `P_Slime`, 2 `P_Honeying`, 3 `P_Kebing`; ItemIDX = PupIDX, speed 130); PupServer initial mind
67–100 / 34–66 / 1–33, stress 4–7 for all three; PupMind 1–25 SJ, 26–50 NT, 51–75 NF, 76–100 SP; PupCase = the 40 rows
(mind type, stress 1…10) → case `type × 10 + stress − 1`; PupCaseDesc 153 rows (121 idle rows, the others PAI_SCRIPT rows of the
other priorities, PupIDX "-" = every pet); PupFactorCondition 64 rows (4 mind types × 16 conditions).

| Getter | @ | Returns |
|---|---|---|
| `GetPetID(PupIDX)` | 004cef80 | PupMain.PupID of the row with that PupIDX, else 0xFFFFFFFF |
| `GetPetIDX(u32 PupID)` | 004ceff0 | PupIDX of that PupID, else null |
| `GetPetIDX(char* ItemIDX)` | 004cf030 | PupIDX of the row whose ItemIDX is the item's InxName, else null (null arg → null) |
| `GetPetSpeed(PupIDX)` | 004cf0b0 | PupSpeed, else 0xFFFFFFFF |
| `GetPetInitMindRange` / `GetPetInitStressRange(out BRange, PupIDX)` | 004cf130 / 004cf1c0 | {Min, Max} of the PupServer row; **no row: the output is left untouched** (Z13-B47) |
| `GetPetMindType(u8 mind)` | 004cf250 | the first PupMind row with Min ≤ mind ≤ Max, else `MAX_PUPMINDTYPEENUM` (4) |
| `GetPetTendencyModifyData` | 004cf440 | §5.7 |
| `GetPetActionCaseFlexible(u8 mind, u8 stress)` | 004cf290 | below |
| `GetPetActionBundleFlexible(prio, case, PupIDX)` | 004cf690 | below |

```pseudo
GetPetActionCaseFlexible(mind, stress) → PupCaseTypeEnum             @ FUN_004cf290
    mt = mind type of mind (first PupMind row); none or MAX → MAX_PUPCASETYPEENUM (41)
    s' = clamp(stress + d, Pup_MinStress, Pup_MaxStress) with d = −2 / −1 / 0 / +1 / +2 at 5 / 20 / 50 / 20 / 5 %   (rb_1000 % 100)
    return PupCaseType of the first PupCase row with (PupMindType, StressNum) = (mt, s'), else 41
GetPetActionBundleFlexible(prio, case, idx) → PupCaseDesc*           @ FUN_004cf690
    candidates = PupCaseDesc rows with PupPriorityType == prio and PupCaseType ∈ {case, ALL_PUP_CASE}
                 and PupIDX ∈ {idx, "-"}                    (idx null → only "-")
    none → null; else candidates[rb_1000000 % count]       # random pick (the decompiled vector code is garbled; as read)
```

So idle actions depend on the pet's mind type and (jittered) stress; the other priorities only have `ALL_PUP_CASE` rows, but
`cPet_GetActionRecord` still needs a valid case first (§6.6).

### 6.2 Object (`ShinePet`, 0x25d4 bytes) and its overrides

`ShinePet : ShineMob` *(pdb2016)*: `+0x2568 spt_nPetRegNum`, `+0x256c spt_pMaster` (`ShineMobileObject*`), `+0x2570
spt_nMasterRegNum` (the master's charNo), `+0x2574 spt_pItemTotalInfo`, `+0x2578 spt_pItemAttr` (the pet item's
`ShineItemAttr_Pet`, §5.1), `+0x257c spt_PetBriefInfo` (`BriefInformationPet`, 0x56: a 0x42-byte packet buffer with opcode
0x1C1C and `+0x52 bip_BriefInfo` → its `PROTO_NC_BRIEFINFO_REGENPET_CMD`). Everything else is the `ShineMob` state (Z09 §5),
which the pet reuses for movement, the AI script slot and the death timer.

```pseudo
ShinePet::ShinePet()                       @ FUN_0055b360    ShineMob ctor; BriefInformationPet ctor FUN_00549390
                                                             (buffer, length 0x41, opcode 0x1C1C); spt_pMaster = null
ShinePet::spt_InitShinePet()               @ FUN_004d1fd0    master, ITI, attr = null; spt_nMasterRegNum = 0xFFFFFFFF
ShinePet::spt_SetMaster(player, charNo)    @ FUN_004d2610    sets each argument that is not null / 0xFFFFFFFF
ShinePet::spt_FindMaster() → master|null   @ FUN_00419a80    Z11 §9.2: spt_pMaster unless empty, in mode 0 / 7, or on another map
~ShinePet / vector deleting destructor     @ FUN_005571c0 / FUN_00557a60   (ShineMob dtor; element size 0x25d4)
```

Overridden slots (rest = `ShineMob`) *(vtable diff, rtti.py)*:

| Slot | Method | @ | Behaviour |
|---|---|---|---|
| 0x0 / 0x4 | `GetRTTI` / vector deleting dtor | 005571d0 / 00557a60 | |
| 0x344 | (`so_MiscTable` fold) | 005572e0 | returns +0x2568 (`spt_nPetRegNum`) |
| 0x4a0 | `so_Getabstatebit` | 00557360 | returns the **shared** static `ShineObject::so_emptyabstate` (Z13-B43) |
| 0x4a4 | `so_RemakeHandle(i)` | 00557310 | `i + 0x5c56` for `i ≤ 0x5db` (1500 pet handles 0x5C56…0x6231), else 0xFFFF |
| 0x4ac | `so_Routine` | 0056c1e0 | §6.4 |
| 0x4b8 | (`so_OverlapFactor` fold) | 00557240 | `mode ≠ 3` |
| 0x4c4 | `so_FillBriefInformation(dst)` | 00557490 | copies the 0x3f-byte brief (`PROTO_NC_BRIEFINFO_REGENPET_CMD::operator=` FUN_005571e0) |
| 0x4c8 | `so_SendMyBriefInfo(rcv)` | 00557260 | §6.5 |
| 0x4d0 | `so_ObjectType` | 005572d0 | 12 |
| 0x4f0 / 0x4f4 | `so_MaxHP` / `so_MaxSP` | 005572f0 / 00557300 | 1 (cached in +0xea8 / +0xeac) |
| 0x514 / 0x518 | `so_WalkSpeed` / `so_RunSpeed` | 005574b0 / 00557500 | master's `sp_PetInfo.nWalkSpeed` / `nRunSpeed` (§5.1, = PupSpeed) when `spt_FindMaster` gives a player, else 1000 |
| 0x56c | `so_CharName` | 005573a0 | the **master's** `sp_PetInfo.sName` (16 bytes) copied into a static `Name5` (`charID`, NUL at byte 16); null when `spt_pMaster` is no player |
| 0x5ac, 0x89c | (fold) | 004b8d20 | 0 |
| 0x6cc | `so_BodySize` | 00559910 | 50 |
| 0x700 | (fold `EmptyHandler`) | 00509900 | no-op |
| 0x708 | (fold) | 005550b0 | 0xFFFF |
| 0x714 | (fold) | 00570b00 | 0 |
| 0x72c | `so_mobile_IsEnemy` | 0042f3a0 | false |
| 0x8cc | (fold) | 00647230 | 2 |
| 0x980 / 0xe94 | `so_mobile_ICanDamageTo` / `smo_ICanHealTo` | 004350f0 / 00435770 | false (Z09 §8.4) |
| 0x9b8 | `so_mob_CanBeAttackedByPlayer` | 004a5d80 | false |
| 0xe04 | (fold) | 00549070 | no-op (the mob's KQ team type setter) |
| 0xe08 | (`so_GetKQTeamType` fold) | 005551b0 | 2 (none) |
| 0xe48 | `so_SetAnimationBriefInfo(s)` | 00557370 | `strncpy(brief.sAnimationIndex, s, 32)` (from `ShineMob::so_SetAnimation` / `so_ResetAnimation`, Z09) |
| 0xf68 | (fold) | 005af8d0 | 1 |
| 0xf6c | `sm_BriefLocateSet` | 004b10f0 | copies the brief's x, y, dir to the mob location block (+0x1f84…+0x1f8c) |
| 0xf70 | `sm_InitBriefInfo(h, id)` | 004b1200 | `bip_InitBriefInfo` |

Not overridden and relevant: vt 0x91c is the `ShineMob` no-op (FUN_00509900), so the `(0x702, 9)` item-use error that
`spt_SummonPet` sends to the **pet** when `FillCommonInfo` fails goes nowhere (original bug) Z13-B42 (the player still gets
0xD411 {0x345e} from `sp_PetSystem_Summon`, §5.4). A pet cannot be attacked, healed or targeted as an enemy, and never attacks.

### 6.3 Creation and spawn

```pseudo
ShinePet::spt_SummonPet(map, x, y, dir, id, layer) → ok           @ FUN_0055d440   (from sp_PetSystem_Summon, §5.4)
    if spt_pMaster null or not a player: return 0
    pi = master.sp_PetSystem_GetPetInfo()  (FUN_00419430)
    if pi.state ∈ {NONE, CASTING} or pi.nId == 0xFFFFFFFF: return 0
    if pi.nRegNum == 0xFFFFFFFF:                                   # pet never created in the DB
        if pi.state ≠ CASTED: return 0
        if !spt_CreatePet(master, pi.nId): assert "ShinePet::spt_SummonPet : Create Pet Error" (charNo, nId); return 0
        pi.state = WAIT_CREATING; pi.naming = CHECK_NAME
    if !master.sp_PetSystem_FillCommonInfo(pi.nId) (§5.1 speeds):
        assert "ShinePet::spt_SummonPet : Filling Pet Common Info is Failed"; pet.vt[0x91c](0x702, 9) (no-op, Z13-B42); return 0
    return spt_Regenerate(map, x, y, dir, pi.nHandle, (u16)pi.nId, pi.nRegNum, &pi.sName, 0, layer) == FM_MARKSUCCESS
    # the id argument is not used; a new pet spawns with RegNum 0xFFFFFFFF and an empty name

ShinePet::spt_CreatePet(master, nId) → ok                          @ FUN_0055d290
    idx = GetPetIDX(nId); null → return 0
    mind   = Min + rb_1000 % (Max − Min + 1)  over GetPetInitMindRange(idx)       # no PupServer row: range = uninitialised stack
    stress = Min + rb_1000 % (Max − Min + 1)  over GetPetInitStressRange(idx)     #   bytes / the nId bytes (original bug) Z13-B47
    if master is not a player or master.charNo ≠ spt_nMasterRegNum: return 0
    pi.nMindMil = mind × 1000; pi.nStressMil = stress × 1000
    → CharDB 0xD40D NC_PET_CREATE_DB_REQ { u16 nMasterHandle = master zone handle, u32 nMasterCharNo = spt_nMasterRegNum,
          Name4 sPetName = "", u8 nPetMind = mind, u8 nPetStress = stress }        (length 0x18; Z07 §9, annotation of part 5)
        (the length check's assert names "spt_SummonPet : Packet Too Long"; unreachable)
    pi.state = WAIT_CREATING; return 1

ShinePet::spt_Regenerate(map, x, y, dir, handle, id, regnum, name, markFlag, layer) → FM_MarkingError   @ FUN_004b48c0
    spt_nPetRegNum = sm_MobRegnum (+0x1ec0) = regnum;  login map (+0x1f78) = map;  mode = 0
    bip_InitBriefInfo(handle, id)  FUN_004b0d90: brief = { nHandle, nID, XYDir = 0, sPetName = "", sAnimationIndex = "" }
    brief.sPetName = name (16 bytes);  position = (x, y), dir' = dir / 2 (+180 when negative); brief.XYDir = (x, y, dir')
    sm_BriefLocateSet (vt 0xf6c); roaming / wander state, target, path cleared
    r = ShinePet::so_MapMarking(markFlag)  FUN_00466790: FieldMap with the login map name (vt 0x4bc) in g_FieldList,
        none → FM_MAPNOTEXIST; else fm_Marking(field, pet, 0x19, 0, markFlag)
    if r ≠ FM_MARKSUCCESS: return r
    abstate bits = so_emptyabstate (vt 0x4a0 returns the same static: a self-copy); abstate list emptied
    if dic_abstate[291 StaImmortal]: so_AbnormalState_Set (vt 0x638)(pet, 291, strength 1, row, g_Now, 0, 0xFFFFFFFF, 5000, 8, 0)
        # Z03 §6.2; runs before HP is set below, so it fails when the (pooled) object has HP 0 *(inferred)*
        so_AbnormalState_BitSet(291)  FUN_00401a00: sets the bit in vt 0x4a0's array = the global so_emptyabstate
        # every later "reset to empty" (ShineMob::so_mob_Regenerate FUN_004b41b0, so_KilledBy FUN_00432240, the player's
        # so_FirstActionAfterSocketConnect FUN_00554870, ShineMover::so_smv_SummonMover FUN_0055fdf0,
        # AbstateListInObject::asl_Store FUN_0040afd0) then starts from a template with bit 291 set (original bug) Z13-B43
    regen animation complete = 1; layer = layer; sight state OSS_NONE
    spt_RegenComplete(handle)
    sm_HP = MaxHP() = 1; sm_SP = MaxSP() = 1; target 0xFFFF; HitMe vector cleared; move state reset; return FM_MARKSUCCESS

ShinePet::spt_RegenComplete(handle)                                 @ FUN_00442eb0
    the ShineMob::so_mob_RegenComplete reset (Z09 §5.3) without the MobInfo parts: vt 0xde4 (no-op for pets), overrides
    (MaxHP, EXP, speeds, HP regen) = 0 / −1, drops on, swing index 2, enemy detect 6, so_InitAIScript (vt 0xc14)
    AI script: so_AIScript.script = g_AIScriptPetContainer[PAT_BASE (1)]; if set: funcName = aispc_GetFileName(PAT_BASE) = "PetBase"
    skill-from-script list cleared; layer key cleared
    BriefInfoExchangePet::bixp_Init(&briefpet); g_SightDistSq = MapInfo.Sight² (−1 on wide-sight / special maps, 0 without field)
    so_AllOfRange(pet, sight, so_ExchageBriefInfo)        # every player in sight gets the pet (§6.5); kind 12 → bixp
    deathSent = 0; killer = 0xFFFF; tactic = roaming? (and +0x24d9 = 0) : MobActionWander.maw_MetronomeReset; then NoBrain
    brain context = {self, handle}; mode = 2; stats c_clear + c_MakeTotal; HitMeList cleared; move / cast / battle state cleared
    spawn = return point = position; recalc abstates; rescue reset; +0x24c4 = 60000; weapon title 0xFFFF; damage-absorb flag 0
    mob brief bRegenAni byte = 0; sm_SetRegenAniTime(g_Now)
```

### 6.4 Routine and removal

```pseudo
ShinePet::so_Routine(pet, _, tick)                                    @ FUN_0056c1e0
    if mode ≠ 3 and spt_FindMaster() == null: so_Unmark(0, 1, 3); som_FreeObject(pet, REMOVE_NOW, reason 9); return
    if mode == 0: return
    position outside the field → log "fm_IsInFieldSize : Mob", flags1e78 |= 1
    ShineMobileObject::so_Routine (Z09 §5.5)
    if flags1e78 & 1: so_Unmark(0, 1, 3); som_FreeObject(pet, reason 7); return
    if mode ≠ 3 and triggers_: NPCAction proximity check (as for mobs)          # pets have no triggers_ (cleared at regen)
    sm_DuringRegen; battle state 1 / 2 → sm_DuringBattle / sm_DuringRecover; rescue → so_RescueRoutine
    if mode ≠ 3:
        m = spt_FindMaster(); if m is no player (type 2, dynamic cast) or has no pet info:
            so_Unmark(0, 1, 3); som_FreeObject(pet, reason 9); return
        if m.sp_PetInfo.state ∈ {1ST_SUMMONED, RESUMMONED} and spt_nPetRegNum ≠ 0xFFFFFFFF:
            if so_AIScript.script: lss_Routine(script, "PetBase", LuaArgumentMobAI{pet handle, field})   # return value ignored
            sm_GetRegenAniComplete
            if alive (vt 0x28 == 0) and HP ≠ 0 and (no move manager or move state ≠ 3): brain context = {self, tick}
            # no tactic step: the pet moves only by its Lua script (cRunTo etc.)
        return                                    # other master states (casting, waiting for the DB, linking): the pet idles
    # mode 3 (dead): as ShineMob (Z09 §5.4): 0x244A NC_BAT_REALLYKILL_CMD once to sight, free (reason 8) after
    #   (sm_DeadDelayTime × 5 + 50) × 2 ticks, Lua routine; no path kills a pet (not attackable), so this is unreachable *(inferred)*
```

Removal is always `so_Unmark(0, 1, 3)` + `som_FreeObject(REMOVE_NOW)`: `ShineObject::so_Unmark` FUN_00553970 → vt 0x310
(no-op) → `so_BroadcastLogout` FUN_0054f290 → `so_Logout` → to sight **0x1805** `{ u16 handle }` (Z09 §12.4, Z01 §3.2): this
is how clients drop a pet. Reasons: 9 master lost (`spt_FindMaster` fails: master freed, in mode 0 / 7, or on another map,
which covers logout and map links), 7 off-field, 8 death timer; the unsummon of §5.6 uses 0x78. A pet left behind by a failed summon (Z13-B36) lives until its master leaves the map.

### 6.5 Brief info: `0x1C1C NC_BRIEFINFO_REGENPET_CMD`, `0x1C1D NC_BRIEFINFO_PET_CMD`

`PROTO_NC_BRIEFINFO_REGENPET_CMD` (0x3f) *(pdb2016, same in 2017)*: `+0 u16 nHandle`, `+2 u32 nID` (PupID), `+6 SHINE_COORD_TYPE
XYDir {u32 x, u32 y, u8 dir}`, `+0xf Name4 sPetName`, `+0x1f char sAnimationIndex[32]`. `0x1C1D` = `{ u8 nPetCnt; REGENPET[nPetCnt] }`.

```pseudo
ShinePet::so_SendMyBriefInfo(pet, rcv)                                @ FUN_00557260   (0x1C01 inform, move into sight: Z02 §5.1, Z09 §9.6)
    if rcv.so_ply_SoloingMode() (vt 0x79c, hide-except-me) and spt_nMasterRegNum == 0xFFFFFFFF: return
        # spt_nMasterRegNum is always the master's charNo after spt_SetMaster, so hide-except-me never hides pets (original bug) Z13-B41
    rcv ← 0x1C1C { spt_PetBriefInfo }     (payload 0x3f)
    pet.so_mobile_SendMyMoveInfo(rcv) (vt 0xa10, FUN_005555e0): the last move command, if the pet is moving

BriefInfoExchangePet::bixp_Exchange(batch, rcv, pet)                  @ FUN_004407d0   (so_ExchageBriefInfo kind 12, Z02 §5.2)
    if same layer key (or either −1) and so_SubLayer_CanSee(pet, rcv) and batch ready and rcv is a player:
        if batch.count > 27: bixp_Send(batch, rcv); count = 0
        pet.so_FillBriefInformation(&batch.Pets[count]); count++                # no hide-except-me test here either (Z13-B41)
BriefInfoExchangePet::bixp_Send(batch, rcv)                           @ FUN_0043e200
    if count ≠ 0 and rcv is a player in mode ≠ 0: rcv ← 0x1C1D { nPetCnt = count, Pets[count] }   (length count × 0x3f + 3 incl. opcode)
BriefInfoExchangePet::bixp_Init(batch)                                @ FUN_0043c8a0
    first call: buffer (0x723 bytes, at most 28 entries) with opcode 0x1C1D; afterwards count = 0
```

The pet itself never receives anything (it has no socket); the pet learns nothing about players in sight.

Client (2016 `GameFrameWork`, 2017 names `On_NC_BRIEFINFO_REGENPET_CMD` / `On_NC_BRIEFINFO_PET_CMD`): `0x1C1C` FUN_006491e0 ignores
a packet with `nID == 0xFFFFFFFF`, converts x / y to a ground position, `dir × 2°` to the facing, and creates the pet object with
`CharMgr::AddPet` *(pdb2017 name)* FUN_00649040 (id, handle, position, facing, `sPetName` + NUL). `0x1C1D` FUN_006492f0 does the same per
entry and **stops at the first entry with nID 0xFFFFFFFF or a failed AddPet** (the rest of the batch is dropped). Neither reads
`sAnimationIndex`. Removal: 0x1805 (§6.4).

### 6.6 Lua interface and the pet AI script

**Script objects** (`AIScriptPetContainer g_AIScriptPetContainer`, a `std::map<PET_AI_TYPE, LuaScriptScenario*>` plus
`aispc_m_petNameMap` +0x10): ctor FUN_006270e0 maps `PAT_DUMMY` 0 → "PetDummy", `PAT_BASE` 1 → "PetBase"; `aispc_Load`
FUN_00626630 loads `LuaScript/PetSystem/<name>.lua`; `aispc_GetFileName` FUN_00626440; all three in Z09 §14.2, the GM reload
`&reloadpetlua` in Z11 §8.6; dtor FUN_00627020. Only `PAT_BASE` is ever used (`spt_RegenComplete`).

Every `cPet_*` function takes a handle (Lua number, arg 1; `0xFFFF` → no result) and, except `cPet_Unsummon`, a **pet**
handle: object type 12 → `spt_FindMaster` → a player (type 2) → `sp_PetInfo` → state 5 or 6. Any failed step asserts
"`cPet_<name> : Error get pet` / `Not Pet Handle` / `Pet Type Casting Error` / `Error get pet master` / `Not Player Handle` /
`Player Type Casting Error` / `Get Player Pet Info Error` / `Pet is not summoned`" and returns no value (Lua `nil`).

| Function | @ | Behaviour |
|---|---|---|
| `cPet_Unsummon(masterHandle)` | 005d65a0 | the handle is the **master** (player, state 5/6): `sp_PetSystem_ChangeTendency(PFC_S_MOVER)`, `sp_PetSystem_Unsummon` (§5.6); true, or nil + "Unsummon pet fail" |
| `cPet_IsMasterCalling(pet)` | 005e9320 | `nCallingState == PNCS_CALLING` → true and resets it to NONE; else false |
| `cPet_GetMind` / `cPet_GetStress(pet)` | 005e9520 / 005e9720 | `(u8)(nMindMil / 1000)` / `(u8)(nStressMil / 1000)` (applied value, without the pending diff) |
| `cPet_GetWalkSpeed` / `cPet_GetRunSpeed(pet)` | 005e9920 / 005e9b10 | `nWalkSpeed` / `nRunSpeed` (§5.1) |
| `cPet_GetActionRecord(pet, mode)` | 005e9d00 | below |
| `cPet_ChangeMind(pet, action)` | 005ea1d0 | arg 2 must be a string; raises one tendency condition via `sp_PetSystem_ChangeTendency` and returns true (below) |
| `cPet_SaveTendency(pet)` | 005ea410 | `sp_PetSystem_ApplyChangedTendency` (§5.7) only, returns true; nothing goes to the DB (original bug) Z13-B45. Its "not summoned" assert text says `cPet_ChangeMind` |

```pseudo
cPet_GetActionRecord(pet, mode) → (aiType, SM_Inx, ActionEffectID, SoundFile)      @ FUN_005e9d00
    prio = "idle" → PPT_Idle, "follow" → PPT_Follow, "call" → PPT_CallPup, "die" → PPT_Die, "link" → PPT_MapLink,
           else assert "cPet_GetActionRecord : 2nd param - Pet Master Mode is Invalid", nil
    case = GetPetActionCaseFlexible(nMindMil / 1000, nStressMil / 1000);  41 → "GetPetActionCase fail", nil
    idx  = GetPetIDX(nId);  null → "GetPetIDX fail", nil
    row  = GetPetActionBundleFlexible(prio, case, idx);  null → "GetPetActionBundle fail", nil
    return PupAIType as "none" / "follow" / "revolution" / "dance" / "attack" / "roaming" / "rotation" / "talk" / "die" / "script",
           row.SM_Inx, row.ActionEffectID, row.SoundFile

cPet_ChangeMind(pet, action)                                                         @ FUN_005ea1d0
    # source intent: "dance" → PFC_M_DANCE, "attack" → ATTACK, "follow" → FOLLOW, "talk" → TALK, "revolution" → REVOLUTION;
    # every strcmp branch is inverted in the 2016 code (assembly at 0x5ea30c: test ecx,ecx / je next compare):
    cond = (action ≠ "dance") ? PFC_M_DANCE (13) : PFC_M_ATTACK (12)      # the later compares are unreachable (original bug) Z13-B44
    sp_PetSystem_ChangeTendency(master, cond); return true
```

**The 2016 pet AI** (`9Data/Shine/LuaScript/PetSystem/PetBase.lua` + 7 included files, read in the shipped scripts; summary only,
the script is data): `PetBase(nHandle, sMapIndex)` runs at most every 0.2 s per pet (`cCurrentSecond`), keeps its state in
`gPetAIMemory["PetBase"][handle]` and re-initialises it when `cGetMaster` / `cGetRegistNumber` change. Per call, by the master's
`cGetObjectMode`: "linking" → link mode; "corpse" → a "die" action record (sad animation, stays 180 s); master farther than 300
→ `cRunTo` next to the master (30); farther than 500 for 10 s → `cPet_Unsummon(master)`; `cPet_IsMasterCalling` → "call" record
(runs to the master, distance 50); otherwise an "idle" record every 30–60 s (follow / revolve around / dance with / attack /
talk to another pet within 200, roam within 100, rotate), several of which call `cPet_ChangeMind` with "follow", "revolution",
"dance", "attack" or "talk", and `cPet_SaveTendency` every 60 s while idle. Effects and sounds of a record are played through the
script helpers `PetBaseObjectEffect` / `PetBaseObjectSound` over the generic script functions (Z09).

---

## 7. Mounts, player side: horses (`RideCasting`) and the mover system

A ride item (item class 23 RIDING, Z04 §2) is one of two kinds, decided by `MoverDataBox::mvdb_GetMoverType` FUN_004bf240
(item InxName in `MoverItem.shn` → `MVST_MOVER`, else `MVST_MAX`; callers treat "not MOVER" as a horse):

- **horse** (`MVST_RIDE`): the player is the mount. Row in `Riding.shn`, mode 6, hunger gauge on the item, speeds from the
  row. Packets of dept 8 (`0x203F`–`0x2048`).
- **mover** (`MVST_MOVER`): a separate `ShineMover` object (type 11, §8 next part) with seats; the item owner is its
  master, others ride as passengers. Packets of dept 51 (`0xCC01`–`0xCC0C`, client requests in Z07 §8).

The 2016 zone allocates a `ShineMover` in exactly two places: `sp_MoverSystem_SummonItem` (end of an item cast, §7.4) and
`sp_MoverSystem_MapLogin` (restore after a map link, §7.7). No NPC or script creates one.

### 7.1 Data

**`enum MOVER_SYSTEM_TYPE`** *(pdb2016)*: `MVST_RIDE` 0 (horse), `MVST_RIDE_ADEL` 1 (never used in the 2016 zone),
`MVST_MOVER` 2, `MVST_MAX` 3 (not riding). This is the "ride kind" of Z07 §8 / Z09 §2.3 (Z07's "3 = got off" = `MVST_MAX`).

**Player members** (`ShinePlayer`, *pdb2016*):

| Offset | Member | Meaning |
|---|---|---|
| +0x2962c | `sp_LastEffect` u32 | last tick of the upgrade recovery |
| +0x29630 / +0x29632 | `sp_MoverRecoveryTick` / `sp_MoverRecovery` u16 | interval (ms) / ‰ of max HP and SP per tick (`MoverUpgradeEffect` row) |
| +0x29634 | `sp_MoverUpgradeEffect` fn | `sp_MoverUpgradeEffect_ON` FUN_0056b5f0 while active, else the no-op FUN_00417480 |
| +0x2a760 | `sp_RideCast` (`RideCasting`, 0x20 bytes) | `+0 castslot` i16 (≥ 0 while a ride cast runs), `+2 rideslot` i16 (inventory slot of the ride item, −1 none), `+4 info` → `CIDEB_Element<RIDING>` {u16 itemID, RIDING*} (horses), `+8 castend` (g_Now ticks), `+0xc lockIndex` (cast lock), `+0xe walkspd` / `+0x10 runspd` (‰ of the base speeds), `+0x12 horselockindex` (lock while riding), `+0x14 nexthungrydec`, `+0x18 hungry` (gauge 0), `+0x1c eMoverSystemType` |
| +0x2aad4 | `sp_Mover_LinkData` (`MOVER_LINKDATA`, 0x3d) | mover state carried over a map link (§7.7); `nCharNo == −1` = none |
| +0x2ab11 | `sp_Mover_nSlot` u8 | seat on the mover (10 = none, the `ShineObject` default of vt 0xc7c) |
| +0x2ab14 | `sp_Mover_pObject` | the `ShineMover` ridden |
| brief +0xe6 / +0xe8 | `nMoverHnd` / `nMoverSlot` | mirrored into `PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD` by `so_MoverSystem_SetMover` FUN_00549430 / `SetMoverSlot` FUN_00549470 (0xffff = none) |
| `sp_MiniHouse.mhs_Backup` | `BriefInfoBackup` {notcamp 0x2b, u8 bib_Backuped} | the shape backup of the mini-house (§1.6) is reused for the ride shape |
| `sp_MiscFlag.bMoverUpgradeWait` | bit | upgrade transaction pending (`sp_Get/SetMoverUpgradeWaitState` FUN_00561600 / FUN_00561610; Z04 §11, cleared at map login) |
| `sp_ChargedItem.ci_Effect.cec_MoverNotHungry` | u8 | charged-item effect: horse gauge does not drop (`so_MoverSystem_ChargedMoverNotHungry` FUN_0055a800, vt 0xc94) |

Player vtable (mover slots): 0xc6c `so_MoverSystem_GetOff` FUN_0045f020, 0xc70 `NoDamage` FUN_0055a7d0, 0xc74 `GetMover`
FUN_0055a7a0 (the object only while `eMoverSystemType == MVST_MOVER`), 0xc78 `SetMover`, 0xc7c `GetMoverSlot` FUN_0055a7c0,
0xc80 `SetMoverSlot`, 0xc88 `SetLinkData` FUN_0045ddf0, 0xc8c `ClearLinkData` FUN_0045e040, 0xc90 `Feeding` FUN_0045f1d0,
0xc94 `ChargedMoverNotHungry`, 0x8c8 `so_ply_HorseFeed` FUN_0045eaa0, 0xdd4 `so_ply_LayerMoverRideOn` FUN_0054aef0.
`ShineObject::so_MoverSystem_GetMoverSlot` FUN_00556ff0 returns 10 for every non-player.

`so_MoverSystem_NoDamage` FUN_0055a7d0: on a mover → `!mover.so_MoverSystem_NoDamage()` (mover vt 0xc70, §8); else 0.

**Item attribute `ShineItemAttr_Riding`** (0x13 bytes, *pdb2016*; `ItemAttrCls_Riding`, 51-slot vtable):

| Attr offset | Field | Accessor (attr vt) |
|---|---|---|
| +0 | u16 `hungrypoint` | 0x3c `iac_FoodEat`(cell, add, max) FUN_0063fc60: `clamp(hungry + add, 0, max)`; 0x40 `iac_GetHungry` FUN_0063fc90 |
| +2 | `ShineDateTime deletetime` | 0x34 `iac_GetDeteleDateTime` FUN_0063e460; 0x38 `iac_SetDeteleDateTime`(hours, tm now, hour) FUN_00640140 → `ItemAttributeClass::iac_SetEndTime` FUN_0063e510 (hours < 1 → 0x76bbecff "never", else now + hours; first byte 0 = never set) |
| +6 | u16 `bitflag`, bit 15 = during ride | 0x60 `iac_GetDuringRide` FUN_0063f560, 0x64 `iac_SetDuringRide` FUN_0063f580 |
| +8 | u32 `IsPutOnBelonged` (`SPOBI_NOT_BELONGED` 0 / `SPOBI_BELONGED` 1) | 0xa4 FUN_0063ff70 / 0xa8 FUN_0063ffa0 |
| +0xc | u32 `nHP` (mover HP) | 0xb4 `iac_SetHP` FUN_00640040 / 0xb8 `iac_GetHP` FUN_00640060 |
| +0x10 | u8 `nGrade` (upgrade grade, Z04 §11) | 0xbc FUN_00640090 / 0xc0 FUN_006400b0 |
| +0x11 | u16 `nRareFailCount` | 0xc4 FUN_006400d0 / 0xc8 FUN_006400f0 |

`iac_fill2buffer` FUN_0063e910 / `iac_fill2struct` FUN_0063eb10 copy the 0x13 bytes as they are (`iac_GetAttrSize` FUN_0063ec80
= 0x13). `iac_itemcreate` FUN_0063f230: hunger = `RidingInitHungry(id)` FUN_0044fe00 (mover → `MoverHG.MaxHG`; else the
`Riding.shn` row's `InitHgauge`; none → 0), delete time 0, flags 0, bound 0, HP = `RidingInitHP(id)` FUN_0044f930
(`MoverAbility.HP`, else 0), grade 0, rare fail count 0. Every other attr class has a no-op at vt 0x60 / 0x64.

**Tables** (all loaded once at zone start):

| Table | Loader | Rows (2016) | Use |
|---|---|---|---|
| `Riding.shn` (`RIDING`, 0x15a) | `RidePetDataBox::rpdb_Load` FUN_00450270 (`zs_start_sun`): `ChargedItemEffectDataBox<RIDING>::cideb_Load` (same template as §1.6) registers each row's item with `ui_ride` (`UseEffect::UseItemRide`) and skill "UseRide"; every `FeedType` ≠ "-" must be an item ("RidePetDataBox::rpdb_Load : Invalid food" → `ShineExit`) and is registered with `ui_horsefood` and skill "UseSkill" | 2 (Coll: feed Hay, FeedGauge 100, HGauge 1000, InitHgauge 1000, Tick 20000 ms, UGauge 4, Run 1300, Foot 1100, cast 1000 ms, cool 3000 ms; Claude: no feed, UGauge 0) | horses |
| `MoverMain.shn` (`MoverMain` {MoverID, MoverIDX, CastingTime, CoolTime, RunSpeed, WalkSpeed, DurationHour, MaxCharSlot}) | `MoverDataBox::mvdb_Load` FUN_004bf960 (`zs_start_long`) | 461 (437 with 1 seat, 24 with 2; DurationHour 0 for 185) | `mvdb_Index[MoverID]` (array of `MoverDataBoxIndex` {pBase, pAbility, pHG, pSummonItem, vUseSkill}); BTree MoverIDX → MoverID; duplicate ID → exit |
| `MoverAbility.shn` | same | 0 | mover combat stats (`Parameter::Container::c_StoreMover` FUN_0055e8d0 for the mover object: WC/MA min/max, AC, MR, TH, TB; move/HP/SP recovery 1000) |
| `MoverHG.shn` ({MoverIDX, FeedType, RestoreAmount, MaxHG, CreateHG, Tick, ConsumeHG}) | same; each `FeedType` ≠ "-" registered with `ui_horsefood` / "UseSkill" ("Food skill null" → exit) | 461 (163 with a feed, e.g. LifeDust) | mover hunger (§8) |
| `MoverItem.shn` ({MoverIDX, ItemIDX}) | same; BTree ItemIDX → MoverID; each item registered with `ui_ride` / "UseRide" ("Ride skill null" → exit) | 461 | item → mover |
| `MoverUseSkill.shn` ({MoverIDX, ActiveSkillIDX}) | same, read through `BinaryDataBox<MoverItem>::bdb_ReadData` (identical 0x40-byte rows, folded code), appended to `vUseSkill` | 0 | mover skills (`MoverSkillList` below) |
| `MoverUpgradeEffect.shn` (`MoverUpgradeEffect`, 0x4b) + `RareMoverRate` / `RareMoverEachRate` / `RareMoverSubRate.shn` | `CMoverUpgradeData::DataRead` FUN_004c0660 (`zs_start_sleep`; ctor FUN_004c0540) | 6 grades | per grade (`GetUpgradeEffectInfo(grade)` FUN_004c0460, null above `m_nMaxGrade`): `{RunSpeed, HPSPRecoveryTick, HPSPRecovery ‰, CastingTime ‰, CastingCoolTime ‰, EffectFileName, AbStateIDX, Strength}`; the rare tables are Z04 §11 |

`DataRead` requires as many `RareMoverSubRate` rows as `MoverUpgradeEffect` rows ("Grade is Not Match" → fail),
`m_nMaxGrade = rows − 1`; per grade it resolves `AbStateIDX` ≠ "-" to `{eAbstateIndex, pAbstateDic, nStrength = Strength}`
(unknown → fail; default index 0x318 = none); `RareMoverEachRate` rows become cumulative `{itemID, sum}` pairs. 2016 grades:
RunSpeed 0/200/400/800/800/800, recovery 0/20/40/60/80/100 ‰ every 1000 ms, cast and cooldown −0/20/30/40/50/60 %, grade 4
`StaMoverStatUpSingle` and grade 5 `StaMoverStatUpParty` (strength 1) on dismount.

Row readers: `BinaryDataBox<MoverMain/MoverAbility/MoverHG/MoverItem>::bdb_ReadData` FUN_004bf320 / FUN_004bf3e0 /
FUN_004bf4a0 / FUN_004bf560 (SHN read, one record array each). Lookups: `mvdb_GetData(id)` FUN_004bf290, `mvdb_GetData_ItemIndex(inxName)` FUN_004bf2c0 (null when unknown or above
`mvdb_MaxID`); ctor FUN_004bf8a0.

**`MoverSkillList`** (vector of `{u16 ms_SkillID, u32 ms_EndOfCooltime}`, used by the mover object): `msl_Store` FUN_00449190
(one entry per `MoverUseSkill` row whose skill has an active part), `msl_CoolTimeCheck` FUN_004463d0 (end ≤ now; unknown
skill asserts and returns 0), `msl_SetCoolTime(skill, ms, group, groupMs)` FUN_00449270 (end = now + ms/100 − 3; every
other skill of the same `DlyTimeGroup` gets at least now + groupMs/100 − 3), `msl_UpdateCoolTime` FUN_00446370. Empty in 2016.

**Object lookup:** `ShineObjectManager::som_FindMover(masterCharNo, moverID)` FUN_005506a0 walks `som_Mover` with
`ShineMoverFinder::lid_Call` FUN_00549e30 (mover vt 0xca8 master == and vt 0xce4 mover ID ==); mover handles
`ShineObjectHandleUnion::sohu_SetMoverHandle` FUN_00549010 = 22138 + index (index < 1000).

Cooldowns use the ride skill of `ui_ride` (the "UseRide" skill): the folded getter
`go_Get_NpcObject(&ui_ride)` returns the stored skill, whose first u16 is the skill ID *(inferred from the use)*.

### 7.2 Using a ride item and the cast

```pseudo
UseItemRide::uib_CanUseItem(p, item) → code     @ FUN_005988b0   (item-use pipeline, Z04 §6; "direct use" kind)
    no map / map FieldAttr.byCanRide (+0xa4) == 0:     c = 0x10C8
    p is casting (vt 0xea0 smo_DuringCast):             c = 0x10C4
    mode 1:  ride skill (uir_RideSkill, "UseRide") not learned: 0x10CA; on cooldown: 0x10C2; else 0x700
    mode 2:  swing time (vt 0xc68) > now → 0x10C3; else as mode 1
    mode 0 / 3 / 4 / 5:                                  c = 0x10C3
    any other mode (6 riding, 7, …):                     0x700 (allowed: using the item while riding dismounts)
    every code ≠ 0x700 goes through sp_HorseError(c) FUN_0045d3b0 = SendErrorCode(8, 0x41, c) →
        0x2041 NC_ACT_RIDE_FAIL_CMD { u16 err = c }, and is returned to the pipeline

UseItemRide::uib_DirectUse(p, slot, item) → 1    @ FUN_005995b0
    mode 1 / 2: item null → 0;  mvdb_GetMoverType(item.id) == MVST_MOVER ? sp_MoverSystem_Cast(slot) : sp_HorseCast(slot)
    mode 6:     eMoverSystemType == MVST_MOVER ? sp_MoverSystem_GetOff(0) (§7.4) : sp_HorseOff (§7.3)
    other modes: nothing
```

```pseudo
sp_HorseCast(slot)                                    @ FUN_0045e0e0
    so_ply_AllCastCancel (vt 0x8d0), so_mobile_StopHere (0xa48), so_ply_SendMoveFail (0xa4c), smo_BashStop (0xed8)
    cell = inventory[slot]; null → return (no answer)
    info = first Riding.shn element whose item ID == cell.id (linear scan; an element without data → return)
           # no match: info is left on the last element and the cast goes on with that row (original bug) Z13-B52
    info and cell.attr set:
        t = RIDING.CastingTime − CastingTime‰ of MoverUpgradeEffect[cell.grade] × t / 1000
        castend = g_Now + t/100; castslot = rideslot = slot
        lockIndex = next lock index; lock list OnlyLock(lockIndex, inventory 9, slot) (vt 0x2c); next index++
        so_ply_ItemUseResultPacket(0x700, 9) → 0x3016 NC_ITEM_USE_ACK (Z04 §6)
        p ← 0x2047 NC_ACT_CREATECASTBAR { u16 millisec = t }
    # eMoverSystemType is not set: it keeps the value of the last cast (original bug) Z13-B48

sp_MoverSystem_Cast(slot) → bool                     @ FUN_0045d550
    the same four cancels
    no layer (p+0x76) or layer kind (+4) == 3:   ItemUseResult(0x701) → false
    cell null:                                   ItemUseResult(0x703) → false
    no MoverDataBox entry for the item's InxName, no MoverMain row, or no attr:   ItemUseResult(0x702) → false
    csl_Toggle_AllOffAndReset (every toggle skill off)
    t = MoverMain.CastingTime reduced by CastingTime‰ of the item grade (as above)
    castend, castslot = rideslot = slot, cast lock as above, eMoverSystemType = MVST_MOVER
    ItemUseResult(0x700); p ← 0x2047 { t } → true

cast end (so_Routine, GameModeWork; Z09 §2.3):        @ FUN_0056c790
    if castslot ≥ 0 and castend ≤ g_Now:
        eMoverSystemType == MVST_MOVER: if !sp_MoverSystem_SummonItem(1): so_ply_AllCastCancel; type = MVST_MAX
        else: sp_HorseOn(1)

cancel: so_ply_AllCastCancel FUN_0055a310 → if castslot ≥ 0: sp_HorseFree      @ FUN_0045d3e0
    castslot = −1; lock list Free(lockIndex) (vt 0x28); p ← 0x2048 NC_ACT_CANCELCASTBAR {}
```

### 7.3 Horse on and off

```pseudo
sp_HorseOn(fresh)                                    @ FUN_0045f270   (fresh = 1 at cast end / layer move, 0 at login)
    if !mhs_Backup.bib_Backuped: copy brief shapedata.notcamp (0x2b) into the backup; bib_Backuped = 1
    sp_MakeRideBriefInfo(&brief.shapedata.ride)       @ FUN_0056e800
        ride.equip = current shapedata (0x2b bytes); ride.rideinfo.horse = info ? RIDING.Handle : 0xffff; return 1
        # always 1: the "fail → 0x2041 {0x10C3}, restore the backup" branch is dead (original bug) Z13-B53
    if p has abstate 0x4B (vt 0x3e4):  0x2041 { 0x10C3 }; so_ply_AllCastCancel; return
        # the backup stays marked and the shape keeps the ride copy (same equipment bytes)
    mode = 6
    attr.SetDuringRide(cell, 1)
    broadcast in range 0x2040 NC_ACT_SOMEONERIDE_ON_CMD { u16 handle, u16 ride.horse }
    p ← 0x203F NC_ACT_RIDE_ON_CMD { u16 ride.horse }
    if no info:  walkspd = runspd = 10; nexthungrydec = now; fresh → ride-skill cooldown 10 000 ms (vt 0xeac)
    else:
        walkspd = RIDING.FootSpeed; runspd = RIDING.RunSpeed
        e = MoverUpgradeEffect[item grade]: walkspd += e.RunSpeed; runspd += e.RunSpeed; cool = CoolTime − CastingCoolTime‰
        nexthungrydec = now + RIDING.Tick/100
        smo_ply_SkillCoolTime(ride skill, cool) (vt 0xeac); fresh → so_ply_NewSkillCoolTime(ride skill, cool/1000 s) (vt 0x374, to the client)
    eMoverSystemType = MVST_RIDE
    sp_HorseFree                                     # castslot −1, cast lock freed, 0x2048
    sp_SendHorseHungry(attr.GetHungry(cell))         # §7.5
    horselockindex = next lock index; OnlyLock(horselockindex, 9, rideslot); next index++
    if info:
        d = attr.GetDeteleDateTime(cell); null → assert
        if d unset (first byte 0):
            attr.SetDeteleDateTime(cell, RIDING.UseTime hours, ct_Current)    # starts a rental period (both 2016 rows: 0 = never)
            sp_HorseItemSave (§7.6)
            if e: sp_LastEffect = now; sp_MoverRecoveryTick / sp_MoverRecovery = e.HPSPRecoveryTick / e.HPSPRecovery;
                  sp_MoverUpgradeEffect = sp_MoverUpgradeEffect_ON
            # the recovery is set up only on the first ride of the item (original bug) Z13-B49

sp_HorseOff                                          @ FUN_0045f7c0
    only in mode 6 and eMoverSystemType ≠ MVST_MOVER
    mode = 1
    cell = inventory[rideslot]; null cell / attr → assert, return (mode is already 1)
    attr.SetDuringRide(cell, 0)
    restore the brief shape from the backup if marked; bib_Backuped = 0
    broadcast in range 0x2043 NC_ACT_SOMEONERIDE_OFF_CMD { u16 handle }
    p ← 0x2042 NC_ACT_RIDE_OFF_CMD {}  (so_SendProtocol); ItemUseResult(0x700, 9)
    lock list Free(horselockindex); sp_HorseItemSave
    eMoverSystemType = MVST_MAX
    sp_MoverOffEffect(attr.GetGrade(cell)); sp_MoverUpgradeEffect = no-op
    # rideslot, info and the speeds stay as they were (only read in mode 6)

sp_MoverOffEffect(grade)                              @ FUN_00561630   (also at the end of a mover ride, §7.4)
    e = MoverUpgradeEffect info[grade]; if e and its abstate index < 0x318:
        if so_AbnormalState_Set(p, idx, e.nStrength, dic, now, …) (vt 0x638) == 1:
            so_AbnormalState_BitSet(idx); so_AbnormalState_BroadcastSet(idx, dic.subabstate[g_NewAbstateStrength].KeepTime,
            g_NewAbstateStrength); so_AbnormalState_Inform (vt 0x3f0, same KeepTime, 1); so_RecalcAbstateParamReady (vt 0x528)
    # 2016: grade 4 → StaMoverStatUpSingle, grade 5 → StaMoverStatUpParty (strength 1); grades 0–3 nothing

sp_MoverUpgradeEffect_ON (routine hook +0x29634)     @ FUN_0056b5f0
    mode 6 and now > sp_LastEffect + sp_MoverRecoveryTick/100:
        sp_LastEffect = now; HP += MaxHP (+0xea8) × ‰ / 1000 (vt 0x5b4); SP += MaxSP (+0xeac) × ‰ / 1000 (vt 0x5b8)
        if HP or SP changed: so_AllOfRange(…, so_ply_Send2WhoTargetMe)   # the target bars of whoever targets p
```

While in mode 6 the brief-equipment refresh `sp_BriefEquipmentSetting` FUN_00576010 calls `so_BriefEquipSetRiding`
FUN_0054e280: it rewrites the 20 item IDs and the upgrade nibbles of `shapedata` from the current equipment (the ride
handle at +0x2b stays) and sets the attack speed to 7.

Speeds: `so_WalkSpeed` / `so_RunSpeed` (Z10 §5.4, FUN_00559960 / FUN_005599c0) use `walkspd` / `runspd` in mode 6:
`base × spd / 1000`. Movers set both to 1000 (§7.4); `sp_SetMoverRunSpeed(v)` FUN_00560130 (`runspd = max(v, 1000)`;
only caller the Lua function `cStaticMoverSpeed` FUN_005debb0, Z09) and the GM command `&horsespeed` (`ac_HorseSpeed`
FUN_0041ded0, Z11) change `runspd`.

### 7.4 Mover summon, get on, get off

```pseudo
sp_MoverSystem_SummonItem(fresh) → bool               @ FUN_0045ec10   (cast end, or layer move with fresh = 1)
    no layer or layer kind 3: return false (no answer)
    already on a mover (vt 0xc74): SendErrorCode(51, 3, 0x306A) → 0xCC03 NC_MOVER_RIDE_ON_FAIL_CMD; false
    cell = inventory[rideslot], its attr, MoverDataBox entry by InxName, MoverMain row: any missing → assert, false
    m = som_AllocObject(type 11); none → assert "Too many mover", false
    m.so_smv_ClearMoverInfo (vt 0xc9c); m.so_smv_SetMoverItemInfo(attr, cell) (0xcb4); m.SetMaster_RegNum(p.charNo) (0xca4);
    m.SetMaster_Object(p) (0xcac); m.SetMoverGrade(attr.GetGrade) (0xd00)
    if !m.so_smv_SummonMover(p.field, p.x, p.y, p.dir × 2, MoverMain.MoverID, attr.GetHP(cell), p.layerRegNum) (0xca0):
        0xCC03 { 0x3069 "The mover summoning is failed." }; m.so_Unmark; som_FreeObject(m, REMOVE_NOW, 0x78); false
    cool = MoverMain.CoolTime − CastingCoolTime‰ (grade); ride-skill cooldown (vt 0xeac); fresh → so_ply_NewSkillCoolTime (vt 0x374)
    sp_HorseFree                                     # end the cast: castslot −1, cast lock freed, 0x2048
    if !sp_MoverSystem_GetOn(m, seat 0): m.so_Unmark; som_FreeObject(m, REMOVE_NOW, 0x79); false
        # the cooldown set above stays (original bug) Z13-B54
    attr.SetDuringRide(cell, 1); horselockindex = next; OnlyLock(horselockindex, 9, rideslot); next++
    d = attr.GetDeteleDateTime; null → assert, true
    if d unset: attr.SetDeteleDateTime(MoverMain.DurationHour, ct_Current); sp_HorseItemSave
    true

sp_MoverSystem_GetOn(m, seat) → bool                  @ FUN_0045d7a0   (also 0xCC01, Z07 §8, and §7.7)
    m null: 0xCC03 { 0x306B }; false
    p has abstate 0x4B: 0xCC03 { 0x306A }; so_ply_AllCastCancel; false
    if !m.so_smv_GetOn(p, seat) (vt 0xcb8, §8: seat checks, 0xCC02 / 0xCC04, SetMover / SetMoverSlot on p): false
    shape backup (as sp_HorseOn); mode = 6
    walkspd = runspd = 1000; castend = 0; lockIndex = 0; nexthungrydec = 0; hungry = 0; eMoverSystemType = MVST_MOVER
    e = MoverUpgradeEffect[m.so_smv_GetMoverGrade (0xcfc)]: recovery hook as in sp_HorseOn (every time, owner and passengers)
    if m.master charNo (0xca8) ≠ p.charNo: castslot = rideslot = −1     # passenger: no item
    true

sp_MoverSystem_GetOff(how) → bool                    @ FUN_0045d910   (how: 0 normal, 1 map link, 2 logout / layer move)
    mode ≠ 6: 0xCC07 NC_MOVER_RIDE_OFF_FAIL_CMD { 0x3081 }; false
    no mover: 0xCC07 { 0x3082 }; false
    passenger: return so_MoverSystem_GetOff(how) (vt 0xc6c)
    owner: m.so_smv_GetOffAll(how) (vt 0xcc0: every seated passenger's vt 0xc6c(how), owner included);
           m.so_Unmark(0, 1, 3); som_FreeObject(m, REMOVE_NOW, 0x7B); true
    # 0xCC05 answers a true result with 0xCC07 { 0x3080 } (Z07 §8)

so_MoverSystem_GetOff(how) → bool  (vt 0xc6c)         @ FUN_0045f020
    mode ≠ 6: 0xCC07 { 0x3081 }; false;   no mover: 0xCC07 { 0x3082 }; false
    if !m.so_smv_GetOff(p, p.seat) (vt 0xcbc, §8; 0xCC06 / 0xCC08): false
    restore the brief shape from the backup; mode = 1; eMoverSystemType = MVST_MAX
    if rideslot ≠ −1 (the owner):
        cell / attr null → assert, true
        sp_MoverOffEffect(attr.GetGrade); attr.SetDuringRide(cell, 0)
        how == 0: lock list Free(horselockindex)     # 1 / 2 keep the lock (the player is leaving) — but see Z13-B51
        sp_HorseItemSave
    sp_MoverUpgradeEffect = no-op; ItemUseResult(0x700, 9) → 0x3016; true
```

### 7.5 Hunger and feeding

```pseudo
routine (GameModeWork, Z09 §2.3):                     @ FUN_0056c790
    mode 6, eMoverSystemType == MVST_RIDE, nexthungrydec ≤ now:
        no info / RIDING row, or rideslot < 0: sp_HorseOff
        else if !cec_MoverNotHungry and RIDING.UGauge ≠ 0:
            attr.FoodEat(cell, −UGauge, HGauge); sp_SendHorseHungry(attr.GetHungry); nexthungrydec = now + Tick/100
        # with the charged effect or UGauge 0 the timer is not advanced (the test repeats every tick, no effect)
    # mover hunger runs in the mover object (§8, smv_SendHungryInfo FUN_0055f0a0 → sp_SendHorseHungry)

sp_SendHorseHungry(h)                                 @ FUN_0045e510
    p ← 0x2046 NC_ACT_RIDE_HUNGRY_CMD { u16 hungry = h }; hungry flag = (h == 0)   # blocks running in mode 6 (Z02 §2.2)

UseItemHorseFood::uib_CanUseItem(p, item) → code      @ FUN_00596500   (feed items registered in §7.1; codes go to 0x3016)
    mode ≠ 6 or no item: 0x701
    on a mover: owner → m.so_smv_CanUseFeedItem(item.id) (vt 0xcc4, §8); passenger → 0x701
    horse: item.id ≠ sp_GetHorseFeed() FUN_0045d510 (ItemInfo ID of RIDING.FeedType, 0xffff none) → 0x10C7
           sp_HorseNotHungry() FUN_0045d460 (gauge ≥ RIDING.HGauge; null cell / attr / info → assert, "full") → 0x10C9
           else 0x700
UseItemHorseFood::uib_Effect(p)                       @ FUN_00596600
    on a mover: so_MoverSystem_Feeding (vt 0xc90)     @ FUN_0045f1d0
        mode ≠ 6: SendErrorCode(51, 9, 0x3091) → 0xCC09 NC_MOVER_FEEDING_ERROR_CMD; no mover: 0xCC09 { 0x3092 };
        not the owner: 0xCC09 { 0x3091 }; m.so_smv_Feeding() (vt 0xcc8, §8) true → sp_HorseItemSave
    else so_ply_HorseFeed (vt 0x8c8)                  @ FUN_0045eaa0
        mode 6, rideslot ≥ 0, info, cell.id == info item ID (else assert): attr.FoodEat(FeedGauge, HGauge);
        sp_HorseItemSave; sp_SendHorseHungry(attr.GetHungry)
```

The direct request `0x2044 NC_ACT_RIDE_FEEDING_REQ` is Z02 §9.1 (its `row+0xc4 / +0xc6` = `FeedGauge` / `HGauge`).

### 7.6 Saving the ride item: `sp_HorseItemSave`

```pseudo
sp_HorseItemSave                                      @ FUN_0045e810
    rideslot == −1 → return; cell, attr and InxName must exist
    if the item has a MoverDataBox entry with a MoverAbility row and attr.GetHP(cell) == 0:
        sp_DestroyItem(p.handle, cell, {inventory 9, rideslot})        # a mover with 0 HP is destroyed (2016: no MoverAbility rows)
        return
    if attr.GetIsPutOnBelonged(cell) == SPOBI_BELONGED: return        # (original bug) Z13-B50: nothing saved
    if ItemInfo row exists:
        if the belong type is a put-on-bound type (IA_IsDataPutOnBelonged: BT_PUTON_ACC / BT_PUTON_CHR):
            IsPutOnBelonged = 1
            GameLog ← 0x0554 NC_LOG_GAME_ITEM_PUT_ON_BELONGED { u32 chrregnum, u64 itemkey,
                     u16 iteminvenfrom = iteminvento = 0x2400 | rideslot (inventory 9) }     (D05)
        sp_ItemAttrSave(cell, 9, rideslot)                              # Z05: attribute to the Character DB
```

Callers: feeding (§7.5, Z02 §9.1), first ride (§7.3 / §7.4), `sp_HorseOff`, `so_MoverSystem_GetOff`, and
`ShinePlayer::so_Unmark` FUN_00558900 in mode 6 for `REMOVE_WARP` (Z01).

### 7.7 Login, map link, layer moves

```pseudo
sp_RideInitialize (from sp_LoginInit FUN_00440d80)    @ FUN_0043d140
    only without mover link data (nCharNo == −1) and not on a mover
    rideslot = castslot = −1
    map forbids riding (byCanRide 0): every inventory item: attr.SetDuringRide(0)     # no-op for non-ride attrs
    else: first item with attr.GetDuringRide: rideslot = its slot; info = Riding element by item ID (none → assert, stop);
          sp_HorseOn(0); castslot = −1; mode = 6
    # a horse stays mounted across relog and map links; mover items had DuringRide cleared on the way out

so_LinkTo (Z09) on a mover:                           @ FUN_0049ad30
    seat ≠ 10: sp_Mover_LinkData = { nCharNo = p.charNo, nItemSlot = rideslot (−1 for a passenger), nMoverID (vt 0xce4),
        nMoverHP = m.so_GetHP (vt 0x4e8), nMasterCharNo (0xca8), nGrade (0xcfc), nPassenger[seat] = p.charNo }
        # only the linking player's own fields: on the NPC gate (smfm_Link FUN_0050ed70) and the town portal
        # (sp_NC_MAP_TOWNPORTAL_REQ FUN_0049fe70) the owner's request first copies the mover's whole seating into every
        # rider (mover vt 0xc84 GetLinkData → player vt 0xc88), so all seats are filled; any other link keeps the
        # others at −1 (from ClearLinkData) (§8.5)
    sp_MoverSystem_GetOff(1)                          # owner: everybody gets off, the mover is freed

WholeSaver::ws_save2worldmanager FUN_004536f0 → sp_MoverSystem_ZoneLink_Save2World    @ FUN_0045e710
    nCharNo ≠ −1: WM ← 0xCC0B NC_MOVER_LINKDATA_WORLD_CMD { u32 charNo = p.charNo, i32 nItemSlot, u32 nMoverID,
        u32 nMoverHP, u32 nMasterCharNo, u8 nGrade, u32 nPassenger[10] }      (0x3d bytes = MOVER_LINKDATA)
    # the WM keeps it (W05 §5.5, FUN_00432fa0) and sends it to the next zone (W01 §6.3)

0xCC0C NC_MOVER_LINKDATA_ZONE_CMD { MOVER_LINKDATA }  (WM→Z)   @ FUN_005a5ac0 `wms_NC_MOVER_LINKDATA_ZONE_CMD`
    p = som_FindPlayer(charNo); none → assert; else p.so_MoverSystem_SetLinkData(payload) (vt 0xc88, FUN_0045ddf0: copy)

sp_NC_MAP_LOGINCOMPLETE_CMD (Z01) → sp_MoverSystem_MapLogin, then ClearLinkData (vt 0xc8c)    @ FUN_0045d9e0
    no link data, or the map forbids riding: return
    already on a mover: 0xCC03 { 0x306A }; return
    m = som_FindMover(nMasterCharNo, nMoverID)
    none: m = som_AllocObject(11) (none → assert "Too many mover", return); ClearMoverInfo; SetMoverGrade(nGrade);
          SummonMover(field, x, y, dir × 2, nMoverID, nMoverHP, layerRegNum) fails → Unmark; som_FreeObject(m, 0x7C); return
          m.so_MoverSystem_SetLinkData(link) (vt 0xc88, FUN_0045deb0, §8: seat bookings from nPassenger, master, grade)
    p is the master:
        cell (9, nItemSlot) locked (lock list vt 0xc icl_IsLocked) or cell / attr / MoverDataBox entry missing:
            m.GetOffAll(0); m.Unmark; som_FreeObject(m, 0x80); return
        attr.SetDuringRide(1); m.SetMoverItemInfo(attr, cell); m.SetMaster_RegNum(p.charNo); m.SetMaster_Object(p)
        rideslot = nItemSlot; castslot = −1; horselockindex lock on (9, rideslot)
    seat = m.so_smv_GetMyBookingSlot(p.charNo) (vt 0xce8, §8); sp_Mover_nSlot = seat; sp_MoverSystem_GetOn(m, seat)
    # a passenger who arrives first (or alone) creates a mover with no master object (§8 decides its fate)

`ShineMover::so_MoverSystem_GetLinkData` FUN_0045dd60 (mover vt 0xc84: nCharNo −1, ID, HP, nItemSlot −1, master, every
seat's passenger charNo or −1) is called by `smfm_Link` FUN_0050ed70 and `sp_NC_MAP_TOWNPORTAL_REQ` FUN_0049fe70 when the
mover's owner links (Z02 §6.5, Z01 §7.3): the result goes into the owner's and every other passenger's `sp_Mover_LinkData`
(vt 0xc88), then each passenger is linked (vt 0x600), the owner last. (Part 7 wrote "no caller": corrected in part 8.)

layer moves: so_ply_MoveNewLayer FUN_0054ab90 / so_ply_MoveOtherLayer FUN_0054ac70 (and the _AllInMap variants FUN_0054ad30 /
FUN_0054ae10; Z09):
    trade break, close booth, AllCastCancel
    mode 6: remember (type, rideslot); not on a mover → sp_HorseOff, else sp_MoverSystem_GetOff(2)
    change layer
    remembered type ≠ MVST_MAX: so_ply_LayerMoverRideOn(type, slot) (vt 0xdd4)      @ FUN_0054aef0
        map allows riding and slot ≠ −1: rideslot = slot; MVST_MOVER → sp_MoverSystem_SummonItem(1) (fails →
        AllCastCancel, type = MVST_MAX); else sp_HorseOn(1)
    # a passenger (slot −1) is not seated again; the owner re-summons a fresh, empty mover
```

### 7.8 Forced dismounts

| Caller | Mover | Horse |
|---|---|---|
| `so_KilledBy` FUN_00433be0 (death, mode 6) | `sp_MoverSystem_GetOff(0)` | `sp_HorseOff`; then `sp_MoverUpgradeEffect` = no-op |
| `so_ply_FlagCaptureCast` FUN_00477d90 (mode in the flag-capture mask) | GetOff(0) | HorseOff |
| `sp_StateChangeToNormal` FUN_005606e0 (mode 6) | GetOff(0) | HorseOff |
| `UseItemRide::uib_DirectUse` in mode 6 (§7.2) | GetOff(0) | HorseOff |
| layer moves (§7.7) | GetOff(2) + re-summon | HorseOff + HorseOn |
| `so_LinkTo` FUN_0049ad30 | GetOff(1) after saving the link data | – (DuringRide stays, §7.7) |
| `ShinePlayer::so_Unmark` FUN_00558900: `REMOVE_WARP` | GetOff(2) (and `sp_HorseItemSave` in mode 6) | save only |
| `ShinePlayer::so_Unmark`: `REMOVE_LOGOUT`; `sp_Schedule_Logout` FUN_00558160 | GetOff(2) / GetOff(0) | – |
| GM `&hide` (`ac_Hide` FUN_0041a3a0, Z11) | GetOff(0) | – |
| `so_ply_AllCastCancel` FUN_0055a310 | cancels a running ride cast (`sp_HorseFree`) | same |

### 7.9 Client side (2016 client, `GameFrameWork`)

| Opcode | Client handler | What it does |
|---|---|---|
| 0x203F RIDE_ON_CMD {u16 horse} | `On_NC_ACT_RIDE_ON_CMD` FUN_004aa100 | own char `Char::RidePet(horse)`, mode 6, effect "Pet_St01", run mode, opens the ride window, "Mover has been summoned. You can toggle Run/Walk by Z button." |
| 0x2040 SOMEONERIDE_ON_CMD {u16 handle, u16 horse} | FUN_004a1fc0 | same on another character (no window, no text) |
| 0x2041 RIDE_FAIL_CMD {u16 err} | FUN_00499ee0 | err ≠ 0: system message `ErrMsgTable::GetErrMsg(err)`; only 0x10C3 has a text ("Moving items…"); 0x10C2 / 0x10C4 / 0x10C7–0x10CA fall back to the generic "<text>: <code>" line |
| 0x2042 RIDE_OFF_CMD {} | FUN_004a2060 | `Char::GetoutOfPet`, mode 1, effect "Pet_Fi01", closes the ride window |
| 0x2043 SOMEONERIDE_OFF_CMD {u16 handle} | FUN_004a2100 | same on another character |
| 0x2046 RIDE_HUNGRY_CMD {u16 hungry} | FUN_004aa1c0 (Z02 §9.1) | gauge; text when 0 |
| 0x2047 CREATECASTBAR {u16 millisec} | FUN_00499c10 | stops auto-run, starts the cast bar for `millisec` |
| 0x2048 CANCELCASTBAR {} | FUN_004d8f90 | resets the cast bar |
| 0xCC03 / 0xCC07 / 0xCC09 {u16 err} | FUN_0049d220 / FUN_0049d250 / FUN_0049d280 | system message `GetErrMsg(err)` unless err is the success code of its family (0x3068 / 0x3080 / 0x3090, ignored): so the 0x3080 "success on the FAIL opcode" of 0xCC05 (Z07 §8) is expected by the client; 0x3069–0x3070, 0x3081–0x3086, 0x3091–0x3096 all have texts |

---

## 8. Mounts, object side: `ShineMover` (object type 11)

The player side (items, casts, get on / off from the rider's view, link data, forced dismounts) is §7; this section is
the vehicle object. Code: `clean.py re-data/exports/zone-pdb - <addr>`; names and layouts *(pdb2016)*. In 2016 every
mover is a one- or two-seat vehicle without combat: `MoverAbility.shn` and `MoverUseSkill.shn` are empty (§7.1), so the
HP, resist, level, skill and damage code below never runs with data (noted per block).

### 8.1 Object and vtable

`ShineObjectClass::ShineMover : ShineMobileObject`, 0x202c bytes, handles 22138 + index (`so_RemakeHandle` FUN_0055edf0:
index ≥ 1000 → 0xFFFF), 1000 objects (Z01 §3). Ctor FUN_0055fb90 (`ShineMobileObject` ctor, empty `MoverSkillList`,
`BriefInformationMover` ctor; points the mobile object's coordinate (+0x66) and direction (+0x6a) pointers and `smv_nHP`
into the brief packet), dtor FUN_0055e950, deleting dtor FUN_00549dd0.

| Offset | Member | Meaning |
|---|---|---|
| +0x1ea8 | `smv_Master_RegNum` u32 | owner's charNo (−1 none); vt 0xca4 / 0xca8 FUN_0055ef00 / FUN_0055ef10 |
| +0x1eac | `smv_Master_Object` | owner object, null until the owner is aboard (vt 0xcac / 0xcb0 FUN_0055ef20 / FUN_0055ef30) |
| +0x1eb0 / +0x1eb4 | `smv_nPassengerCnt`, `smv_pPassengerArray[10]` | seated riders; seat 0 = the driver (the owner after a summon) |
| +0x1edc / +0x1ee0 | `smv_nBookingCnt`, `smv_BookingArray[10]` (`MoverBookingInfo` {u32 mbki_CharNo (−1 free), u32 mbki_RegistTime (g_Now)}) | seats reserved across a map link (§8.5) |
| +0x1f30 | `smv_LastMoveLoc` | position at the last passenger update (§8.4) |
| +0x1f38 | `smv_SendMoveSpeed` (`PROTO_NC_MOVER_MOVESPEED_CMD`) | last speeds sent in 0xCC0D (§8.7) |
| +0x1f40 | `smv_HungryTime` | next hunger tick (g_Now), 0 = no hunger (§8.6) |
| +0x1f44 | `smv_MoverData` | `MoverDataBoxIndex` (§7.1); null = invalid mover |
| +0x1f48 / +0x1f4c | `smv_MoverItemTotalInfo` / `smv_MoverItemAttr` | the owner's mover item cell and its `ShineItemAttr_Riding` (vt 0xcb4 `so_smv_SetMoverItemInfo` FUN_0055ef40); null on a mover without its owner |
| +0x1f50 | `smv_MoverResist` | `MobResist` row of `MoverAbility.ResIndex` (none in 2016) |
| +0x1f54 | `smv_MoverSkillList` | `MoverSkillList` (§7.1) |
| +0x1f64 | `smv_nMaxSlotNum` u8 | `MoverMain.MaxCharSlot` (1 or 2 in 2016) |
| +0x1f65 | `smv_MoverBriefInfo` (`BriefInformationMover`, 0xa2) | the live `0x1C1A` packet (§8.10): handle, ID, HP, coordinates, abstate bits, grade, seat handles |
| +0x2008 | `smv_nHP` → brief `nHP` | |
| +0x200c | `smv_LoginLoc` | map name of the summon (`so_LoginLocation` FUN_0055ed60) |
| +0x2021 | `smv_EntrancePoint` | last good position of the block check (Z09 §9.2, `smo_BlockCheck` FUN_004bf020) |

Overridden slots (the rest are the `ShineMobileObject` defaults; mover-system slots are listed with their callers in §7.1):

| Slot | Function | Behaviour |
|---|---|---|
| 0x8 | `so_BriefInfoRange` FUN_00556e40 | `BIR_VARIOUS` |
| 0x28 | `so_AmIAlreadyDead` FUN_0055ee70 | NoDamage → false; else dead flag (+0x1d7c) or HP 0 |
| 0x300 | `so_IsEmpty` FUN_0055eaa0 | true without a master object or in mode 3: a mover whose owner is not aboard counts as "removed" for every scan that tests vt 0x300 (Z09 §16 notes) |
| 0x4a0 | `so_Getabstatebit` FUN_0055ee40 | the brief's `AbstateBit` |
| 0x4ac | `so_Routine` FUN_0056af60 | §8.4 |
| 0x4c4 / 0x4c8 | `so_FillBriefInformation` FUN_0055e9f0 / `so_SendMyBriefInfo` FUN_0055ea10 | §8.10 |
| 0x4d0 | `so_ObjectType` FUN_0055ead0 | 11 |
| 0x4d8 / 0x6cc | `so_GetLevel` FUN_0055eae0 / `so_BodySize` FUN_0055eb00 | `MoverAbility.MoverLv` / `.AbsoluteSize`; without a row 0 / 50 |
| 0x4e8 / 0x4f0 | `so_GetHP` FUN_0055ed70 / `so_MaxHP` FUN_0055ed80 | brief `nHP` / parameter-container MaxHP (stored at +0xea8) when there is a `MoverAbility` row, else 0 |
| 0xaac / 0xf18 | `so_SetHP` FUN_0054a610 / `smo_ZeroHP` FUN_0055ede0 | HP = n; with a `MoverAbility` row and an item also `attr.iac_SetHP` (the HP lives in the item, §7.1) / SetHP(0) |
| 0x514 / 0x518 | `so_WalkSpeed` FUN_0055eb20 / `so_RunSpeed` FUN_0055ec40 | §8.7 |
| 0x550, 0x818, 0x828, 0x85c, 0xa84 | `so_PartyRegistNumber` FUN_0055ee50, `so_ply_GetMyGuildNo` FUN_0055eec0, `so_mobile_GetGuildRegnum` FUN_0056d960, `so_ply_GetMyGuildAcademyNo` FUN_0055eee0, `so_GetRaid` FUN_00560480 | the master object's answer; without a master 0xFFFF / 0 / 0 / 0 / null |
| 0x8cc | `so_mobile_BattleCamp` FUN_0055e9c0 | `BC_CHAR` with a master object, else 0 |
| 0xe60 | `so_IsAlliance` FUN_0054b130 | master's vt 0xe60; no master → false |
| 0x5bc, 0x5c0, 0x634, 0x72c, 0x760, 0x980 | KilledBy, DamagedBy, AbnormalState_Resist, IsEnemy, CanMyTarget, ICanDamageTo | §8.9 |
| 0xd4c / 0xeb8 | `so_SendSpeedInformation` FUN_00456910 / `smo_ply_SendSpeedInformation` FUN_00456850 | §8.7 |
| 0xea8 / 0xeac | `smo_ply_SkillCoolTimeUpdate` FUN_0055e9e0 / `smo_ply_SkillCoolTime` FUN_0054a770 | `msl_UpdateCoolTime` / `msl_SetCoolTime` (§7.1) |
| 0xedc | `smo_SPCheck` FUN_0055eeb0 | always true (a mover pays no SP) |
| 0xcc4 … 0xd00 | the `so_smv_*` methods | §8.2–§8.8 |

Not overridden and relevant: vt 0xa4c `so_ply_SendMoveFail` is the folded no-op FUN_00417480 on a mover (§8.7), vt 0x3f0
`so_AbnormalState_Inform` is a folded no-op, vt 0xa48 `so_mobile_StopHere` and vt 0xa10 `so_mobile_SendMyMoveInfo` are the
`ShineMobileObject` ones (Z02 §1, Z09 §9).

### 8.2 Summon

```pseudo
ShineMover::so_smv_ClearMoverInfo (vt 0xc9c)            @ FUN_0055f360   (same body: smv_Clear FUN_0055f1f0, no caller)
    master object null, master charNo −1, passenger and booking counts 0, every seat empty, every booking {−1, 0},
    seat count 0, HungryTime 0, mover data / item / attr / resist null, HP 0

ShineMover::so_smv_SummonMover(map, x, y, dir2, moverID, hp, layerRegNum) → bool   (vt 0xca0)   @ FUN_0055fdf0
    # callers: sp_MoverSystem_SummonItem (§7.4), sp_MoverSystem_MapLogin (§7.7); dir2 = player dir × 2
    smv_MoverData = mvdb_GetData(moverID) (FUN_004bf290); none or no MoverMain row: return false
    smv_nMaxSlotNum = MoverMain.MaxCharSlot
    MoverAbility row (none in 2016): HP = hp; smv_MoverResist = MobResist[MoverAbility.ResIndex]
    parameter container (obj+0xfc0): c_clear; c_StoreMover(MoverAbility) FUN_0055e8d0; c_MakeTotal
    MoverHG row with Tick ≠ 0: smv_HungryTime = g_Now + Tick / 100           # Tick in ms
    skill list emptied, msl_Store(MoverUseSkill rows) FUN_00449190
    mode = 1; smv_SendMoveSpeed = {_, 0, 0}
    smv_LastMoveLoc = the old position; position = (x, y), dir = dir2 / 2 (+180 if negative); smv_LoginLoc.map = map
    abstate bits = so_emptyabstate; abstate element list erased
    if so_MapMarking(0) ≠ FM_MARKSUCCESS: return false                       # the caller frees the object
    generic mobile-object reset: move manager halted, status flags (+0x1e78) &= 0xFE then &= 0xE5 (Z03 §6.6),
        timers +0xea0 / +0xea4 = g_Now, abstate params recalculated (vt 0x360), vt 0xec8, vt 0xbf0
    so_SetLayerRegNum(layerRegNum); smv_RegenComplete; return true

ShineMover::smv_RegenComplete                           @ FUN_00441fd0
    bimv_InitBriefInfo(handle, MoverMain.MoverID) FUN_0043c280      # nHandle, nID, every nSlotHandle = 0xFFFF
    so_AllOfRange(allofrangearg, position, so_ExchageBriefInfo)     # every player in range gets 0x1C1A (§8.10)
    # (the sight radius it computes first into the global sightsquar is not used by this call)
```

The owner's grade is written by `so_smv_SetMoverGrade` (vt 0xd00, FUN_0055fb70) straight into the brief `nGrade`;
`so_smv_GetMoverGrade` (vt 0xcfc, FUN_0055fb50) reads it (0 without a brief). `so_smv_GetMoverID` (vt 0xce4, FUN_0055efa0) =
`MoverMain.MoverID` (0 without data), `so_smv_GetMaxSlotNum` (vt 0xcd8, FUN_0055ef60), `so_smv_GetPassenger(i)` (vt 0xcdc,
FUN_0055ef70: null for i ≥ seat count), `so_MoverSystem_NoDamage` (vt 0xc70, FUN_0055efc0: data present and no
`MoverAbility` row → true, i.e. **every 2016 mover is undamageable**; without data false).

### 8.3 Seats

```pseudo
ShineMover::so_smv_GetOn(p, seat) → bool  (vt 0xcb8)    @ FUN_0055f380   (from sp_MoverSystem_GetOn, §7.4)
    p null: assert, false
    no mover data: p ← 0xCC03 NC_MOVER_RIDE_ON_FAIL_CMD { 0x306C "The mover cannot be riden." }; false
    seat ≥ smv_nMaxSlotNum: 0xCC03 { 0x306D "This is not the right slot for riding." }; false
    seat occupied: 0xCC03 { 0x306F "This is not the slot for riding." }; false
    booking[seat] held by another charNo: 0xCC03 { 0x306F }; false
    booking[seat] held by p.charNo: booking = {−1, 0}; smv_nBookingCnt −1
    seat[seat] = p; brief nSlotHandle[seat] = p.handle; smv_nPassengerCnt +1
    p.so_mobile_StopHere (vt 0xa48: 0x2013 at p's position); p.so_smo_SetLocation(mover x, y, dir) (vt 0xc98)
    p.SetMover(this) (vt 0xc78); p.SetMoverSlot(seat) (vt 0xc80)          # also the character brief +0xe6 / +0xe8
    p ← 0xCC02 NC_MOVER_RIDE_ON_CMD { u16 nMoverHandle, u8 nSlot = seat, u8 nGrade }
    in range of the mover ← 0xCC04 NC_MOVER_SOMEONE_RIDE_ON_CMD { u16 nHandle = p, u16 nMoverHandle, u8 nSlot, u8 nGrade }
    MoverHG row and the owner's item known: smv_SendHungryInfo(p, attr.iac_GetHungry) → p ← 0xCC0A NC_MOVER_HUNGRY_CMD { u16 nHungry }
        # this is the "mover script hook (+0x1f4c vt 0x40) → FUN_0055f0a0" of Z07 §8: +0x1f4c is smv_MoverItemAttr, vt 0x40 iac_GetHungry
    true
    # no code sends 0x306E "There is no available slot for riding.": a full mover answers 0x306F

ShineMover::so_smv_GetOff(p, seat) → bool  (vt 0xcbc)   @ FUN_0055f620   (from so_MoverSystem_GetOff, §7.4)
    p null: false (no answer)
    no mover data: p ← 0xCC07 NC_MOVER_RIDE_OFF_FAIL_CMD { 0x3083 "It is not the mover you can get off." }; false
    seat ≥ smv_nMaxSlotNum: 0xCC07 { 0x3084 "You cannot get off from this slot." }
    seat empty: 0xCC07 { 0x3086 "You cannot get off from this slot." }
    seat holds another handle: 0xCC07 { 0x3085 "This is not your slot." }
    seat[seat] = null; brief nSlotHandle[seat] = 0xFFFF; smv_nPassengerCnt −1
    p.so_mobile_StopHere (0x2013); p.SetMover(null); p.SetMoverSlot(10)
    p.so_SendSpeedInformation(0) (vt 0xd4c, argument 0 = send even if unchanged) → p ← 0x203E NC_ACT_MOVESPEED_CMD
    p ← 0xCC06 NC_MOVER_RIDE_OFF_CMD {} (so_SendProtocol 51/6)
    in range of p (at the mover's position) ← 0xCC08 NC_MOVER_SOMEONE_RIDE_OFF_CMD { u16 nHandle = p }
    true

ShineMover::so_smv_GetOffAll(how)  (vt 0xcc0)           @ FUN_0055f7c0
    smv_nPassengerCnt < 1: assert "Passenger count error", return
    every seated rider: rider.so_MoverSystem_GetOff(how) (player vt 0xc6c, §7.4)    # the owner's item is saved there

ShineMover::so_smv_GetMyBookingSlot(charNo) → seat  (vt 0xce8)   @ FUN_0055fa10
    smv_nBookingCnt < 1: 10;  the first seat < seat count booked for charNo, else 10
    # 10 makes the following get-on fail with 0x306D (§8.5)

ShineMover::so_smv_PassengerNotice(text)  (vt 0xce0)    @ FUN_0055f9a0
    text null: assert; every seated rider: so_ply_Notice(text) (vt 0x784)     # no caller in the 2016 zone
```

### 8.4 Routine and removal

```pseudo
ShineMover::so_Routine(list, n)                         @ FUN_0056af60   (every object tick)
    no mover data: GetOffAll(0); so_Unmark(0, 1, 3); som_FreeObject(REMOVE_NOW, 0x7E); return
    smv_PassengerCheck                                  @ FUN_0055f2f0
        every seat whose rider is so_IsEmpty (vt 0x300: leaving player): seat = null, brief seat handle 0xFFFF, count −1
        # silent: no 0xCC06 / 0xCC08, the rider's own SetMover / slot are not reset
    if smv_nBookingCnt < 1:
        no rider left, or no master object: GetOffAll(0); Unmark; free (0x7E); return
    else, every seat < seat count with RegistTime ≠ 0 and RegistTime + 600 < g_Now (60 s):
        booking of the master charNo: GetOffAll(0); Unmark; free (0x7E); return    # the owner never arrived
        else booking = {−1, 0}                          # smv_nBookingCnt is not decremented (original bug) Z13-B55
    master object set and (master.so_IsEmpty (vt 0x300) or master.charNo (vt 0x344) ≠ smv_Master_RegNum):
        GetOffAll(0); Unmark; free (0x7E); return       # owner left or the object slot was reused
    ShineMobileObject::so_Routine (movement, abstates; Z09 §2)
    position ≠ smv_LastMoveLoc: smv_PassengerMove FUN_0055efe0 (every rider that is not empty and not already there:
        so_smo_SetLocation(mover x, y, dir), vt 0xc98); smv_LastMoveLoc = position
    smv_HungryTime ≠ 0 and ≤ g_Now: smv_FoodEat (§8.6)
    return 1
```

Removal is always `so_Unmark(0, 1, 3)` (the generic `ShineObject::so_Unmark` FUN_00553970: 0x1805 to the sight, as for
pets §6.4) followed by `som_FreeObject(handle, REMOVE_NOW, reason)`. Reasons: 0x78 / 0x79 summon failures, 0x7B owner gets
off, 0x7C / 0x80 map-login failures (§7), 0x7E routine and death (this section).

Lifecycle summary:

| Event | What happens |
|---|---|
| owner uses the item (§7.2, §7.4) | `som_AllocObject(11)`, ClearMoverInfo, item info, master, grade, SummonMover, owner seated on seat 0 |
| passenger 0xCC01 (Z07 §8) | `so_smv_GetOn` on a free, unbooked seat |
| passenger 0xCC05 | that rider's `so_MoverSystem_GetOff(0)` |
| owner 0xCC05, death, flag capture, state change, GM hide, logout (§7.8) | `sp_MoverSystem_GetOff`: GetOffAll, Unmark, free (0x7B) |
| owner disconnects without a clean get-off | next routine: master `so_IsEmpty` → GetOffAll(0), free (0x7E) |
| a rider disconnects | `smv_PassengerCheck` drops the seat silently |
| map link of the owner | §7.7 / §8.5: the mover is freed in the old map and rebuilt in the new one |

### 8.5 Map links: who rebuilds the mover, and the bookings

The answers to the two open points of part 7, from §7.7 and the methods above:

- **All riders link through the owner's NPC gate or town portal** (`smfm_Link` / `sp_NC_MAP_TOWNPORTAL_REQ`, which copy
  the full seating, §7.7): every rider's link data carries the owner (`nMasterCharNo`), mover ID, HP, grade and every
  seat's charNo. The **first rider to finish its map login** (owner or passenger) creates the mover
  (`sp_MoverSystem_MapLogin`) and `so_MoverSystem_SetLinkData` FUN_0045deb0 books every seat for its charNo with
  `RegistTime = g_Now`. Each later rider finds it with `som_FindMover(master, moverID)` and takes its booked seat
  (`GetMyBookingSlot` → `GetOn` consumes the booking). The owner, when it arrives, also restores the item info and the
  master object. A passenger who boards first sits on a mover with no master object: it is `so_IsEmpty` (§8.1), its
  speeds lack the owner's modifiers and its hunger does not tick (§8.6); it cannot be driven (the driver is seat 0, §8.7).
- **The owner does not arrive within 60 s** (600 ticks): its booking expires and the routine dismounts everyone
  (`GetOffAll(0)`) and frees the mover. A passenger who does not arrive only loses its booking after 60 s; until then
  its seat answers 0x306F to anyone else.
- **A rider arrives with no booking for itself** (the mover was rebuilt from another rider's partial link data, or
  the booking expired): `GetMyBookingSlot` returns 10 and `GetOn` fails with 0xCC03 { 0x306D }; the rider stays on foot.
- **A passenger links alone** (any other link: its link data holds only its own seat and the owner's charNo): no mover
  of that owner exists in the new map, so the passenger's map login creates one booked only for itself and seats the
  passenger (0xCC02 / 0xCC04 / 0x1C1A go out). The booking is consumed, so at the next routine tick `smv_nBookingCnt < 1`
  with no master object: GetOffAll(0) (0xCC06 / 0xCC08) and free. The passenger appears on a phantom copy of the owner's
  mover for one tick (original bug) Z13-B60.
- The owner linking alone keeps only its own seat: it rebuilds the mover and gets on as driver; the passengers were
  dismounted in the old map by the owner's `GetOff(1)` (§7.7).

### 8.6 Hunger and feeding (mover side)

```pseudo
ShineMover::smv_FoodEat                                 @ FUN_0055f110   (routine, when smv_HungryTime ≤ g_Now)
    needs: mover data, a MoverHG row with ConsumeHG ≠ 0, the owner's item and attr, a master object; else return
        # the timer is not advanced, so the test repeats every tick until the owner is aboard (no effect)
    master.so_MoverSystem_ChargedMoverNotHungry (vt 0xc94, charged item effect, §7.1) true: return (timer not advanced)
    attr.iac_FoodEat(cell, −ConsumeHG, MaxHG) (clamped to 0 … MaxHG); smv_HungryTime = g_Now + Tick / 100
    smv_SendHungryInfo(seat 0 rider, attr.iac_GetHungry)  @ FUN_0055f0a0 → 0xCC0A NC_MOVER_HUNGRY_CMD { u16 nHungry }
        # only the driver; passengers got one 0xCC0A when they boarded (§8.3) and no later updates
    # the gauge is not saved here: sp_HorseItemSave runs on feeding and get-off (§7.4–§7.6)

ShineMover::so_smv_CanUseFeedItem(itemID) → code  (vt 0xcc4)   @ FUN_0055f840   (from UseItemHorseFood, §7.5)
    itemID 0xFFFF, no data or no MoverHG row, or itemID ≠ ItemInfo ID of MoverHG.FeedType: 0x10C7
    no item / attr: 0x10C9;  gauge ≥ MaxHG: 0x10C9 (full);  else 0x700

ShineMover::so_smv_Feeding → bool  (vt 0xcc8)          @ FUN_0055f8e0   (from so_MoverSystem_Feeding, §7.5)
    master object (vt 0xcb0) null: assert, false
    no data or no MoverHG row: master ← 0xCC09 NC_MOVER_FEEDING_ERROR_CMD { 0x3093 "This is not the mover you can feed." }; false
    no item / attr: master ← 0xCC09 { 0x3096 "This is not the mover you can feed." }; false
    attr.iac_FoodEat(cell, +RestoreAmount, MaxHG); smv_SendHungryInfo(master, gauge) (0xCC0A); true
```

The server never acts on an empty gauge: `so_smv_MoveRun` (§8.7) does not test it, only the client switches to walking
on `0xCC0A { 0 }` (original bug) Z13-B56. 0x3094 / 0x3095 ("There is no feed you can give.") are never sent.

### 8.7 Movement and speed

The player's move requests hand over to the mover when the player rides one (Z02 §2.2 / §2.3).

```pseudo
ShineMover::so_smv_MoveWalk / so_smv_MoveRun(req {from, to}, p) → bool   (vt 0xccc / 0xcd0)   @ FUN_00459b00 / FUN_00459d80
    req null: assert, false
    mover feared (+0x1e78 bit 2), captivated (vt 0xf20), or move manager blocked (+0x1ac active and state 3): false
    no field: assert "Invalid map", false
    seat 0 ≠ p: assert "Not the driver", false            # passengers cannot steer; the handler then sends 0x201B
    walk: mm_Step, then drop the abstate elements ended by walking (aeo_Walk)
    run:  drop aeo_Run elements, then mm_Step
    speed = so_WalkSpeed / so_RunSpeed; 0: false
    from == to: smo_StopBlockCheck (vt 0xf44); false
    from not near the position, or `to` / the position not walkable (smo_MoveLocationCheck_From / _To), or the path
        blocked (sp_MovePathBlockCheck(position, to, 2)): smo_StopBlockCheck; false
    so_mobile_MoveReserve(to, speed, walk 1 / run 2, 0) (vt 0x660, Z09 §9.1); so_SendSpeedInformation(1)
    around the driver ← 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD / 0x201A NC_ACT_SOMEONEMOVERUN_CMD { u16 handle = mover,
        u32 from = server position, u32 to, u16 speed, u16 moveattr (bit 0 cleared, rest stale as Z02-B2) }; true
    # riders follow in the routine (smv_PassengerMove, §8.4); hunger is not checked (Z13-B56)

ShineMover::so_smv_MoveStop(req {loc}, p)  (vt 0xcd4)   @ FUN_00456e30
    no field: assert; move manager blocked: return
    mm_Step; req null: assert
    dist²(position, loc) < 40001 and loc walkable: so_mobile_StopHere (0x2013 { mover, server position })
    else: smo_StopBlockCheck; vt 0xa4c (no-op on a mover)   # the driver gets no 0x201B correction (original bug) Z13-B57
    # p (the requester) is not checked: any rider's 0x2012 stops the mover

ShineMover::so_WalkSpeed / so_RunSpeed                  @ FUN_0055eb20 / FUN_0055ec40
    no data / MoverMain row: 0
    master object: master static speed set (vt 0xe84 / 0xe88, scripts, Z10): return it (vt 0xe8c / 0xe90)
                   rate = master parameter MoveSpeed ‰ (container +0xc40 = p+0x1c00) − 1000     # the rider's speed buffs
    bonus = MoverUpgradeEffect[attr.grade].RunSpeed (item known; also for the walk speed)
    v = (MoverMain.WalkSpeed|RunSpeed + bonus + rate) × chrwalkspeed|chrrunspeed / 1000 (s16)
    return max(0, v × own MoveSpeed ‰ (obj+0x1c00) / 1000)
    # Z10 §5.4 gives the same formula; the grade's RunSpeed bonus is added to the walk speed as well (as read)

ShineMover::so_SendSpeedInformation(onlyIfChanged)  (vt 0xd4c)   @ FUN_00456910
ShineMover::smo_ply_SendSpeedInformation  (vt 0xeb8)    @ FUN_00456850   (= the same with onlyIfChanged = 1)
    no seat-0 rider: return
    speeds ≠ smv_SendMoveSpeed or !onlyIfChanged: driver ← 0xCC0D NC_MOVER_MOVESPEED_CMD { u16 nMoverHandle, u16 nWalk,
        u16 nRun }; remember them
```

The player version `ShinePlayer::so_SendSpeedInformation` FUN_00459540 uses the same argument sense (1 = only if
changed, 0 = always), so Z02 §2.2's "force=1" is the opposite of the code. Block checks of the mover
(`smo_BlockCheck` FUN_004bf020, `smv_MoveBlockCheck` FUN_004be610, `smv_MoveFindEmpty` FUN_004be6e0) are Z09 §9.2.

### 8.8 Abnormal states shared with the riders

```pseudo
ShinePlayer::so_AbnormalState_Set → after a successful set, if p rides a mover (vt 0xc74):   @ FUN_004162d0
    mover.so_smv_MasterSetAbsCheck(same arguments)  (vt 0xcf4)       @ FUN_0055fc50
        strength ∉ 1…39, abstate or its sub-abstate null: assert, false
        smv_AbstateAffectedByMaster(index) FUN_0055fa70: DispelIndex DA_STUN / DA_FEAR, or SubDispelIndex
            SDA_STUN / SDA_FEAR / SDA_BIND / SDA_KNOCKBACK → true; else false (nothing happens)
        ShineMobileObject::so_AbnormalState_Set on the mover (vt 0x638) succeeds: BitSet(index) in the brief bits;
            vt 0x3f0 (no-op); so_AbnormalState_BroadcastSet(index, KeepTime, strength); true
ShinePlayer::so_AbnormalState_Reset(index) → if on a mover: mover.so_smv_MasterResetAbsCheck(index) (vt 0xcf8)
    @ FUN_00559ef0 → FUN_0055fae0: same class test → asl_AbstateReset on the mover
```

Any rider (not only the owner, despite the "Master" in the names) passes stuns, fears, binds and knock-backs to the
vehicle; a stunned or feared mover refuses `MoveWalk` / `MoveRun` (§8.7). The mover's copy ends with its own timer or
when the rider's state is reset.

### 8.9 Combat overrides (no effect with the 2016 data)

Every 2016 mover is `NoDamage` (§8.2), so player and mob rules never take it as a target (`so_mobile_IsEnemy` and
`ICanDamageTo` of players and mobs return false for a target whose vt 0xc70 is true; the skill target scan
`AxialListScanSkillTarget::alns_ValidObject` FUN_00579320 skips it), and it has no skills. For a rebuild with mover data:

```pseudo
ShineMover::so_DamagedBy(attacker, dmg, …)  (vt 0x5c0) @ FUN_0042d170
    no data: assert; StaImmortal (291) / 499 tests only fetch the name (stripped logging, inferred)
    attacker: its battle stat (vt 0x428) +8 += dmg; drop the mover's aeo_Attacked elements
    so_SetHP(HP − dmg)                                  # no lower clamp here (the caller decides death, Z03)
ShineMover::so_KilledBy  (vt 0x5bc)                     @ FUN_00432df0
    once (status bit 3, Z03 §6.6): base so_KilledBy; SetHP(0); GetOffAll(0); Unmark; free (0x7E)
ShineMover::so_AbnormalState_Resist(abstate)  (vt 0x634) @ FUN_00416790
    null / no info: assert, resisted; no resist row: not resisted
    by SubDispelIndex: stun ResStun, move speed ResMoveSpeed, fear ResFear, blooding ResDot, reverse ResReverse,
        bind ResBinding, mesmerize ResMesmerize, sever bone ResSeverBone, knock-back ResKnockBack, TB minus ResTBMinus;
        other kinds: not resisted;  resisted when random(1000) < value
ShineMover::so_ply_CanMyTarget(mob, i)  (vt 0x760)      @ FUN_004ae450
    mob row's i-th skill entry: target kind (+0x4f) 0 → the mover; 2 → the mover unless it already has all of the skill's
    abstates (first missing one → the mover); 4 → the mover unless `asl_IsHereGood`; else null
ShineMover::so_mobile_IsEnemy(d)  (vt 0x72c)            @ FUN_004309a0
    d = d.owner (vt 0x9b0) or d; d == this or no field: false
    d mob-like (vt 0x89c): as the player rule (Z03 §3.3): not allied (vt 0xe60), not the same guild in a guild
        tournament, mover not captivated, d without 499, d's StaImmortal (291) none or < 3600 left (then reset) → true
    d.NoDamage (vt 0xc70) false: false
    d (a player) captivated, or the mover captivated: true
    field fm_PKField == 1: true
    field has a MapInfo row: false                      # every real map
    (MapInfo null: KingdomMap read through the null pointer, then party battle / guild war / tournament tests)
    # the player version tests PKField ≠ 0, then "MapInfo and KingdomMap == 4"; here the MapInfo test is inverted,
    # so a mover never counts a player as enemy outside PK fields and captivation, and the rest is dead (original bug) Z13-B58
```

`so_mobile_ICanDamageTo` FUN_004368c0 is Z09 §8.4.

**Mover skills (unreachable):** `so_smv_SkillBash_Object(skill, target, p)` (vt 0xcec, FUN_00580800) and
`so_smv_SkillBash_Location(skill, loc, p)` (vt 0xcf0, FUN_00580cf0) are the mover copies of the player's skill-bash
checks (Z03 §5.2) with errors to `p` as `0x2434 NC_BAT_SKILLBASH_CAST_FAIL_ACK` (SendErrorCode 9/0x34): mover mode not 1/2
→ 0xFC0; casting → 0xFC4; target unknown → 0xFC4; field without `FieldAttr` +0x9f (skills allowed) → 0xFC3; feared →
0xFCC; captivated → 0xFD2; StaEthereal (vt 0x9e4) → 0xFC0; silenced → 0xFC7; target not killable by users (`mdb_CanIKill`) →
0xFD6; sub-layer → 0xFC0; mover with StaImmortal (291) or 499 → 0xFC1; target with 291: not mob-like → 0xFC2, a mob with
more than 360 s left → silent return, else its 291 is reset; target with 499 → 0xFD6; `IsNoAttack` → vt 0xed4; attack-blocked line → 0xFD1; unknown skill / no active part → 0xFC6; move-manager
state 3 with a cast time or SHOOTME / HOLDME → 0xFC8; target rules (TARGET_ENEMY / ENEMYUSER via vt 0x980) → 0xFD6, area
→ 0xFD7; `msl_CoolTimeCheck` fails → 0xFC8; out of range ((body size + AttackDist) × 1.25, at most +60) → 0xFCA; else
`smo_SkillBash_Casting`. The location variant checks the target point instead and sends its cooldown failure to the
mover itself (vt 0x308 of `this`) (original bug) Z13-B59. **No code calls vt 0xcec / 0xcf0**: the 2016 zone registers no
handler for `0xCC0E NC_MOVER_SKILLBASH_OBJ_CAST_REQ { u16 nSkillID, u16 nTarget }` / `0xCC0F
NC_MOVER_SKILLBASH_FLD_CAST_REQ { u16 nSkillID, SHINE_XY_TYPE nTargetLoc }` (only 0xCC01 and 0xCC05 are registered).

### 8.10 Brief info: `0x1C1A NC_BRIEFINFO_REGENMOVER_CMD`, `0x1C1B NC_BRIEFINFO_MOVER_CMD`

`BriefInformationMover` (ctor FUN_0055e830): a `ProtocolPacket` over its own 0x8e-byte array, length 0x8d, opcode 0x1C1A;
`bimv_SetSlotHandle(i, h)` FUN_0055e8a0 (i < 10). The packet *is* the mover's state storage, so it is always current:

```
0x1C1A NC_BRIEFINFO_REGENMOVER_CMD (0x8b bytes)
    +0x00 u16 nHandle          mover handle
    +0x02 u32 nID              MoverMain.MoverID
    +0x06 u32 nHP              (0 in 2016)
    +0x0a SHINE_COORD_TYPE nCoord { u32 x, u32 y, u8 dir }   live position
    +0x13 ABNORMAL_STATE_BIT AbstateBit (99 bytes)           §8.8
    +0x76 u8  nGrade           upgrade grade (Z04 §11)
    +0x77 u16 nSlotHandle[10]  rider handle per seat, 0xFFFF empty
```

```pseudo
ShineMover::so_SendMyBriefInfo(r)  (vt 0x4c8)            @ FUN_0055ea10   (sight exchange, regen broadcast)
    r in "soloing" mode (vt 0x79c so_ply_SoloingMode, Z01 §9 flag 8) and this is a mover:
        master charNo −1 or ≠ r.charNo: return          # a soloing player sees only its own mover
    r ← the 0x1C1A packet; so_mobile_SendMyMoveInfo(r) (vt 0xa10: the current move, if any)
ShineMover::so_FillBriefInformation(dst)  (vt 0x4c4)    @ FUN_0055e9f0   copies the 0x8b bytes

BriefInfoExchangeMover (batches for a player entering sight, Z02 §5.2):
    bixmv_Init FUN_0043c810: buffer 0xfbf bytes, opcode 0x1C1B, nMoverNum = 0
    bixmv_Exchange(r, m) FUN_00440690: same layer (or either −1) and m visible from r's sub-layer and r is a player:
        when 28 entries are queued, send and restart; append m.so_FillBriefInformation; nMoverNum +1
    bixmv_Send(r) FUN_0043e0d0: entries > 0, r a player with mode ≠ 0: length 3 + n × 0x8b →
        r ← 0x1C1B NC_BRIEFINFO_MOVER_CMD { u8 nMoverNum, PROTO_NC_BRIEFINFO_REGENMOVER_CMD Movers[n] }
```

### 8.11 Client side (2016 client, `GameFrameWork` / `CharMgr`)

| Opcode | Client handler | What it does |
|---|---|---|
| 0x1C1A | `CharMgr::AddMover` FUN_00646e00 | nID 0xFFFF → ignored; else creates the mover model (`AddMover` FUN_00646c50) with handle, ID, HP, grade at the ground height of (x, y), rotated by dir × 2°. Seat handles and abstate bits are not read: riders are seated from their own character brief (`nMoverHnd` / `nMoverSlot`, §7.1) and 0xCC02 / 0xCC04 |
| 0x1C1B | `CharMgr::AddMover` FUN_00646ef0 | the same per entry; an entry with nID 0xFFFF or a failed `AddMover` ends the loop (later entries dropped) |
| 0xCC02 RIDE_ON_CMD | FUN_004b3aa0 | unknown mover → asks its brief info (0x1C01, Z02 §5.1); else `Mover::RideOn(mover, own char, slot)`, effect "Pet_St01"; seat 0 only: text 0x43482579 "Mover has been summoned. You can toggle Run/Walk by Z button." and `OpenFeedMoverWin(mover, grade)` |
| 0xCC04 SOMEONE_RIDE_ON_CMD | FUN_004a5f70 | mover and character by handle (unknown ones are requested), `RideOn`, effect |
| 0xCC06 RIDE_OFF_CMD | FUN_004b3c00 | own char's mover / slot: effect "Pet_Fi01", `SetMoverEffect(0)`, `RideOff`; a ground click queued while riding is replayed; `CloseFeedMoverWin`; back to run mode |
| 0xCC08 SOMEONE_RIDE_OFF_CMD | FUN_004a6090 | the same for another character (no window) |
| 0xCC0A HUNGRY_CMD | FUN_004b3da0 | feed window gauge (+0x1b4) = nHungry (0 → non-zero switches back to run); 0 → walk mode and "Hunger Gauge is Zero. Your Mover cannot run in this status. Hunger Gauge can be replenished with Mover Feed items." |
| 0xCC0D MOVESPEED_CMD | FUN_0049d2b0 | character by nMoverHandle: walk speed (vt 0x104) = nWalk, run speed (vt 0x108) = nRun |

0xCC03 / 0xCC07 / 0xCC09 are §7.9.

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
| Z13-B17 | `UseItemFurnitureEndureKit::uivpb_SendErrorCode` (0x3034) | the code is written at payload +4 but the length is set to 4 payload bytes | a kit-use failure found by `uib_AfterCast` (0x702) reaches the client without its code; the client reads `Error` past the packet | `pp_SetPacketLen(8)` as the handler does |
| Z13-B18 | `ShineMiniHouse::so_Routine` portal expiry | `dEndTime` (a `time_t` from the DB) is compared with `g_Now / 10` (seconds since the zone clock reset) | timed portals never expire while the house stands; an expired portal can still be opened and used | compare with the current `time_t` |
| Z13-B19 | `so_mh_PortalEffectApply` (0x8C56) | the member loop stops when a successful `so_LinkTo` leaves `EnterPlayerCount` unchanged, which is the case for every link to another zone | with a recall point on another zone only the first eligible visitor (and the owner) is recalled | continue the loop as `so_mh_EffectApply` does |
| Z13-B20 | `mhe_CalEndureGrade` | the hours left are clamped to `Endure[0]`, but the first bucket is `h < Endure[0]` | with at least `Endure[0]` hours left no grade is computed and the old grade stays | `h <= Endure[0]` for the first bucket |
| Z13-B21 | furniture emotions (`so_mh_Out`, `so_mh_Move2MiniHouse`) | the seated state is not reset when a player leaves or when the owner enters | an owner who left seated shows up seated (on whatever furniture now has that handle) in the rebuilt house and blocks that seat | reset the state in `so_mh_Out` |
| Z13-B22 | `so_mh_CanObjAni` | the 294-entry last-touch table is never cleared and handles are never reused | after 294 distinct furniture handles in one house, new furniture can no longer be animated (0x14C1) | free entries of removed furniture or index by cell |
| Z13-B23 | 0x8C3D CHAR_ACTION (FUN_00574750) | the animation `Handle` is not checked against the furniture's item | a client can play any furniture's animation on any furniture; everybody in the house sees it | require `row.ItemID == furniture item` |
| Z13-B24 | `so_mh_CanFurnitureEmotion` (0x8C62); also 0x8C3D / 0x8C40 | `IsPlaced` is not tested and `nEmotionNo` is not validated | sitting on (or animating) an item still in the box near its default spot (276, 388); arbitrary emotion numbers broadcast | test `IsPlaced` and `MHEmotionID` |
| Z13-B25 | `WeddingHall::wh_RecallCouple` | a partner inside a mini house counts as recalled (returns true) but is neither moved nor charged the coupon | the ceremony can start while that partner stays in the house; `weddingcomplete` still marries them if they are on the hall zone (`som_FindPlayer` ignores the map), otherwise no marriage | return false, or link them out of the house |
| Z13-B26 | `wh_Routine` / 0x2055 at the origin | the ceremony starts when `RecallCount ≠ 0`, i.e. with only one of the two found | a one-person ceremony; `weddingcomplete` needs both, so no 0x1091 is sent, the reservation and the coupon of the present partner are used up | start only with 2, cancel otherwise |
| Z13-B27 | `wh_Reserv` (0x2053) | no check that the zone has the map `Wedding` (or that the player talks to a wedding NPC); every zone has its own `weddinghall` | a couple reserving on another zone holds that zone's slot; at start they are linked to `Wedding`, but `wh_Start` asserts "Map not found", no ceremony runs, and guests on the hall zone see no reservation | refuse the reservation outside the hall zone |
| Z13-B28 | `Checker::DivorceLimit` Sub 1–4 | the `0x108F` / `0x108D` requests leave `header.clienthandle` (payload +0) stale; Sub 3 / 4 sets no lock, so both partners send `0x108D` and repeat it each minute until their reload | `gds_NC_CHAR_WEDDING_DIVORCE_DO_ACK` reloads whatever object holds the stale handle; the DB runs `Divorce_Do` twice (two GameLog 0x065B pairs, `dSubWhen` reset) | write the handle; lock as for Sub 1 / 2 and let only one side execute |
| Z13-B29 | `ZoneRingPacketRefreshWeddingInfo::zrpb_Request` | a partner found on this zone without a field (logging in / linking) gets neither a reload nor a ring packet | the partner keeps stale wedding data (e.g. still "married" after the divorce) until their next 0x1081 | reload anyway (the DB answer arrives after the login completes) |
| Z13-B30 | `sp_PetSystem_ApplyChangedTendency` | mind / stress + pending diff summed as `u32`, range tested on `(u8)(sum / 1000)` | a sum below 0 wraps: stress at its minimum jumps to `MaxStress`, mind becomes an arbitrary value (e.g. 54); also any sum ≥ 256 000 wraps | signed sum, clamp before the byte cast |
| Z13-B31 | `sp_PetSystem_Unsummon` | when the pet object's type is not 12 it sends 0x3482, clears the pet info (`sp_Pet_pObject = null`) and then calls `sp_Pet_pObject->so_Unmark` | null dereference, zone crash (only if the handle was reused by another object kind) | return after the 0x3482 |
| Z13-B32 | `ShinePlayer::so_Routine` booth tick | an open booth raises `PFC_S_RESTHOUSE` every 600 s; `PFC_S_STORE` (11) is never raised | booth time counts as tent rest in the tendency table (row 11 differs from row 10 for mind type 1) | raise `PFC_S_STORE` |
| Z13-B33 | `irm_Move` / box moves / merge / split | only `irm_Exchange` updates `nSummonSlot` | after moving the summoned pet item, using it gives 0x702 (cannot dismiss it with the item), naming (0xD407) and `sp_PetItemSave` act on whatever lies in the old slot, the naming check asserts every tick if that slot is empty | track the slot on every move, or lock the summoned item |
| Z13-B34 | `sp_PetSystem_PlayerRoutine` → failed `sp_PetSystem_Summon` | only `AllCastCancel` and state = NONE; the cast lock `nCastingLockIndex` is not released and `nCastSlot` / ids stay | the pet item's cell stays locked (item use 0x70a, moves refused) *(inferred: until the lock list is reset)* | `sp_PetSystem_CancelCasting` (release + init) |
| Z13-B35 | `sp_PetSystem_Cast` | the pet id lookup (item → PetIDX → PetID) is done after state = CASTING and the cast end time are set | 0x3016 0x702 now, then 1.5 s later 0xD411 0x345e for the same use | look the id up before changing state |
| Z13-B36 | `sp_PetSystem_Summon` | returns 0 without freeing the allocated pet when the cast cell / ITI / attr is missing, and after `sp_Pet_pObject = pet` when the `UseSumPup` skill is missing | a pet object without a summoned state: the next summon answers 0x3458 "nearby already" | free the object on every failure |
| Z13-B37 | `iac_SetDuringPetSummon` callers | `bSummoning` is set to 1 at every summon and never cleared (unsummon, link, logout) | the item attribute (client cell info, DB copy at the next item save) keeps saying "summoning" *(effect in the client not traced)* | clear it on unsummon |
| Z13-B38 | `UseItemPet::uib_CanUseItem` | most failures send `0xD411 {code}` and return the same code, which `ItemUse_Inventory` sends again as `0x3016` | the client shows the message twice; codes 0x3444 (KQ map), 0x345b–0x3460 come only once | one channel |
| Z13-B39 | pet code | dead checks: `&p.sp_PetInfo == null` (0x3446 never sent), `(u32)nSummonSlot ≠ 0xFFFFFFFF` in `sp_PetItemSave` (always true), CanUseItem modes ≥ 8 (excluded by the item handler) | none at run time; 0x3446 and 0x3460 are unreachable in practice | – |
| Z13-B40 | `so_KilledBy` | raises `PFC_S_REVIVALTOWN` at every death; `sp_ReviveNow` adds `PFC_S_REVIVALHERE` on top | an in-place revive applies both factors | raise RevivalTown only on the town revive |
| Z13-B41 | `ShinePet::so_SendMyBriefInfo` FUN_00557260, `bixp_Exchange` FUN_004407d0 | hide-except-me skips a pet only when `spt_nMasterRegNum == 0xFFFFFFFF`, which never holds after `spt_SetMaster`; the batch path has no test at all | a player in hide-except-me mode still sees every pet | hide other players' pets (compare the master with the receiver) |
| Z13-B42 | `spt_SummonPet` FUN_0055d440 | on a `FillCommonInfo` failure calls vt 0x91c `(0x702, 9)` on the **pet** (a no-op there) | the intended item-use error never reaches the player (0xD411 {0x345e} still does) | the master's `so_ply_ItemUseResultPacket` |
| Z13-B43 | `ShinePet::so_Getabstatebit` FUN_00557360 + `spt_Regenerate` FUN_004b48c0 | the pet's abstate bit array is the shared static `so_emptyabstate`; `so_AbnormalState_BitSet(StaImmortal)` at every summon sets bit 291 in it | every object later reset from the "empty" template (mob regen, deaths, player connect, mover summon, every `asl_Store`) carries bit 291 in its brief abstate bits; the client-side effect of that bit is not traced *(inferred)* | a per-pet bit array |
| Z13-B44 | Lua `cPet_ChangeMind` FUN_005ea1d0 | every `strcmp` branch is inverted: "dance" → `PFC_M_ATTACK`, any other string → `PFC_M_DANCE` | the pet AI's follow / talk / revolution / attack calls all apply the DANCE factor; FOLLOW, TALK, REVOLUTION rows of PupFactorCondition are never used | map each action string to its own condition |
| Z13-B45 | Lua `cPet_SaveTendency` FUN_005ea410 | only applies the pending change (`ApplyChangedTendency`); no 0xD401 | mind / stress reach the DB only at unsummon and at the character save | apply and send 0xD401 (`sp_PetSystem_SaveTendency`) |
| Z13-B46 | `CPetData::ReadData` FUN_004cf870 | the "Invalid ID in PupMain.shn" assert prints the destination row's PupID, which is not written yet | the log shows uninitialised heap bytes instead of the bad id | print the source row's PupID |
| Z13-B47 | `spt_CreatePet` FUN_0055d290 | `GetPetInitMindRange` / `GetPetInitStressRange` leave the output untouched when no PupServer row matches; the caller does not check | a pet without a PupServer row gets mind / stress from stack garbage and the nId bytes (out of the 1–100 / 1–10 bounds) | refuse the creation or use the global bounds |
| Z13-B48 | `sp_HorseCast` FUN_0045e0e0 | does not set `eMoverSystemType`; a mover cast that was cancelled (`sp_HorseFree` only clears `castslot`) leaves `MVST_MOVER` | the next horse cast ends in `sp_MoverSystem_SummonItem` with the horse item ("Mover data null" assert, cast cancelled, no mount); the second try works | `eMoverSystemType = MVST_RIDE` in `sp_HorseCast` (as `sp_MoverSystem_Cast` does for movers) |
| Z13-B49 | `sp_HorseOn` FUN_0045f270 | the `MoverUpgradeEffect` HP/SP recovery hook is set inside the "delete time not set yet" branch | an upgraded horse recovers HP/SP only on the very first ride of the item; afterwards never (movers set it on every `GetOn`) | set the recovery outside that branch |
| Z13-B50 | `sp_HorseItemSave` FUN_0045e810 | returns without `sp_ItemAttrSave` once the item is bound (`IsPutOnBelonged == 1`); the save sits inside the "bind now" test | hunger, expiry and the during-ride flag of a bound mount are not written at feeding / dismount / first ride; only a later full item save (if any, Z05) persists them | bind-and-log only when unbound, save always |
| Z13-B51 | `so_MoverSystem_GetOff` FUN_0045f020 with how = 2 from a layer move | the owner's `horselockindex` lock is kept (only how = 0 frees it), then `so_ply_LayerMoverRideOn` → `SummonItem` takes a second lock on the same cell | after a layer change on an own mover the mover item's cell stays locked until relog *(inferred effect)* (also `REMOVE_WARP`) | free the lock unless the player really leaves the zone (how = 1 / logout) |
| Z13-B52 | `sp_HorseCast` FUN_0045e0e0 | when no `Riding.shn` element matches the item, `info` keeps the last element scanned and the cast goes on | casts with the last row's cast time and later shows its horse; unreachable with the shipped data (only `Riding.shn` items and mover items use `ui_ride`, movers go to `sp_MoverSystem_Cast`) | reset `info` to null when the scan finds nothing |
| Z13-B53 | `sp_HorseOn` FUN_0045f270 | `sp_MakeRideBriefInfo` always returns 1 | the failure branch (0x2041 {0x10C3} + restore the shape backup) is dead; the abstate-0x4B refusal right after it leaves the backup marked and does not restore | check abstate 0x4B before building the ride shape |
| Z13-B54 | `sp_MoverSystem_SummonItem` FUN_0045ec10 | sets the ride-skill cooldown (and tells the client) before `sp_MoverSystem_GetOn`; a failing get-on (abstate 0x4B: 0x306A) frees the mover but keeps the cooldown | the player waits the full cooldown without having ridden | set the cooldown after a successful get-on |
| Z13-B55 | `ShineMover::so_Routine` FUN_0056af60 | an expired non-master booking is cleared without decrementing `smv_nBookingCnt` | the count stays > 0 for the mover's life, so the "no rider / no master → free" branch never runs for it (other checks still free it when the owner leaves) | decrement the count with the booking |
| Z13-B56 | `ShineMover::so_smv_MoveRun` FUN_00459d80 | runs regardless of the hunger gauge (the horse's run block of Z02 §2.2 is skipped for movers) | only the client enforces "cannot run" on `0xCC0A {0}`; a modified client runs a starving mover | refuse runs at gauge 0 |
| Z13-B57 | `ShineMover::so_smv_MoveStop` FUN_00456e30 | on a failed stop it calls vt 0xa4c, which is the no-op default on a mover, and the 0x2012 handler returns after the mover call | the driver's client is not corrected (no 0x201B) | send the move-fail to the requesting rider |
| Z13-B58 | `ShineMover::so_mobile_IsEnemy` FUN_004309a0 | after the PK test (`fm_PKField == 1`) it returns false whenever the field has a MapInfo row; the KQ / party-battle / guild-war tests run only with a null MapInfo and then read `KingdomMap` through it | a mover never treats players as enemies outside PK fields and captivation; the rest is dead (no effect in 2016: movers cannot attack) | the player rule: PK field ≠ 0, or MapInfo and KingdomMap == 4, then party battle, guild war, tournament |
| Z13-B59 | `ShineMover::so_smv_SkillBash_Location` FUN_00580cf0 | the cooldown failure 0xFC8 goes to the mover's own `so_SendErrorCode` (vt 0x308 of `this`), not to the rider | the rider would get no answer (unreachable in 2016: no handler for 0xCC0F) | send to the rider like every other check |
| Z13-B60 | `sp_MoverSystem_MapLogin` FUN_0045d9e0 with `so_Routine` | a passenger who links without the owner (link data with only its own seat) rebuilds the owner's mover, boards it, and the next routine tick dismounts it and frees the mover | the passenger and its sight see a summon, 0xCC02 / 0xCC04 and a dismount 0xCC06 / 0xCC08 within one tick | do not rebuild a mover whose owner is not coming (no master booking) |

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
- `mhPortalListWin::Delete` (client, 0x8C4F): which entry it removes is not visible in the decompiled call (no field passed).
- `mhe_CalEndureGrade`'s "now" is `chargeditemcheck`'s time struct; that it is refreshed every minute is *(inferred)* from
  its `ct_1MinuteFlow` use in Z09.
- `RandomBox::operator[](n)` returning 0 … n−1 (animation follow-ups, actor index) is *(inferred)*.
- The 0x8C61 list counter is a `u8` over a 294-entry array; a pass with more than 255 changed placed items would wrap
  (not reachable with the 2016 timers, *(inferred)*).
- Wedding (§4): the gender value 1 = male in `wh_Reserv` and "EldPri" = the Elderine prison map in `wh_RecallCouple` are
  *(inferred)*. The `LinkTable` columns used by the partner summon (row +0x14 = FieldLevel key, +0x35 = map) were read as
  offsets only; that the band is the target map's entry level is *(inferred)*. Whether the 2016 Character DB ever writes
  sub-status 8 (DivorceLimit case 8) is unknown (w00 writes 4). The client's answer to the 0x1384 dialog (0x205C accept /
  0x205E refuse) was not traced in the client.
- Pets (§5): the meaning of `FieldAttr.KingdomQuestMap == 2` (refused without a 0xD411) is not identified. Whether the
  WM drops its re-summon record after sending 0xD412, and what happens with a stale record when the next 0x4033 is
  skipped (states 1–4 / 8 at the link), was not traced (W01). The pet is removed by 0x1805 (§6.4); what the client does with `bSummoning` was not
  traced (the 0x1C1C handler does not read the item). Pets (§6): the client effect of the polluted abstate bit 291
  (Z13-B43), whether the StaImmortal set in `spt_Regenerate` ever succeeds (HP test before HP = 1), and what player mode 7
  is in `spt_FindMaster` are *(inferred)* / open; `GetPetActionBundleFlexible`'s random pick is read through garbled decompiler output. That the lock list keeps an unreleased cast lock until relog (Z13-B34) is *(inferred)*.
- Mounts (§7): `go_Get_NpcObject(&ui_ride)` is a folded getter; that it returns `ui_ride`'s skill (whose first u16 is the
  "UseRide" skill ID) is *(inferred)*, as is the skill bound by `uir_SetSkill` (folded body, Z09). `so_AbnormalState_Set`
  writing the strength used into `g_NewAbstateStrength` (read by `sp_MoverOffEffect`) is *(inferred)*. What the item-use
  pipeline does when `UseItemRide::uib_DirectUse` returns 1 without doing anything (modes ≠ 1, 2, 6, which `uib_CanUseItem`
  lets through) was not traced. Whether a later full save writes the attributes skipped by Z13-B50 was not checked (Z05).
  A passenger who links alone re-creates the owner's mover without a master in the new map (§7.7); its fate: §8.5.
- Mover object (§8): the meaning of the parameter-container offset +0xc40 (read as the master's `MoveSpeed` ‰, the same
  as `p+0x1c00`) is *(inferred)* from the offsets; `so_DamagedBy`'s unused name fetches being stripped logging is
  *(inferred)*; whether the damage pipeline (Z03) calls `so_KilledBy` instead of `so_DamagedBy` when HP would go below 0
  was not traced (no mover can be damaged in 2016). The callers of `smo_ply_SendSpeedInformation` (vt 0xeb8, no virtual
  call found) were not traced. The client's `AddMover` FUN_00646c50 internals (model, seat nodes) were not read.

## Coverage boundary

(Filled in by the sweep part.)
