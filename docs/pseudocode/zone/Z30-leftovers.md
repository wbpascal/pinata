# Zone: handler-reachable leftovers (Z30)

Source: the 2016 zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`), read with the NA2016 PDB
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Function, class, member and packet names
are from the 2016 zone PDB *(pdb2016)* unless marked; vtable slots were resolved with `tools/protocol-re/rtti.py` over the
`ShineObjectClass::ShinePlayer` vftable. Evidence markers as in `AGENTS.md`. `g_Now` = `clockwatch.cw_CurrTick` (tenths
of a second, Z02 §1). `p` = the player, `gpp` = the global packet buffer.

This item closes the zone functions that `coverage.py --overview` still listed as uncited after the done zone items
(48 functions, 2 handlers). Where another doc already describes the caller, the section below only adds what that doc
left out and links it.

## 1. Character rename by item: the zone side (dept 45 USER2)

The rename-by-item flow: client `0xB410` → zone (Z01 §9, FUN_0051b090) → Character DB `0xB411` (D02 §14, FUN_00423f30)
→ zone `0xB412` (§1.1) → client `0xB413`. The actual rename happens later at character select (WM W01 §6.2, CharDB
`0xB40A/0xB40B`); the WM then tells every zone with `0xB40F` (§1.2).

### 1.1 GameDB 0xB412 NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ITEM_USE_ACK (GameDBSession)

```pseudo
0xB412 NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ITEM_USE_ACK { NETPACKETZONEHEADER Header { u16 clienthandle, u32 charregistnumber },
        u16 nError, u16 lockindex, u16 nUsedItemID }   (0xc bytes; no length check)          @ FUN_0051b6d0
    o = som_GetObject(Header.clienthandle); if !o: return
    if o.GetCharNo() (vt 0x344) ≠ Header.charregistnumber: return          # silently
    if o.so_IsEmpty() (vt 0x300): return                                    # closing
    o.so_ply_ChangeCharIDUseAck(&payload) (vt 0x9fc)

ShinePlayer::so_ply_ChangeCharIDUseAck(ack)                                                  @ FUN_0051b810
    L = p.so_ply_GetInventoryLockList() (vt 0x7d4)
    if ack.nError == 0x20B0:  L.icl_Apply_N_Free(p, ack.lockindex, 0) (vt 0x1c)    # consume the rename item
                              failure → LockIndexLog "…so_ply_ChangeCharIDUseAck : <lockindex>" only
    else:                     L.vt 0x28(ack.lockindex)                              # release the reservation
    p ← 0xB413 NC_USER_CONNECTION_CHANGE_CHAR_ID_ITEM_USE_ACK { u16 nError, u16 nUsedItemID }   (4 bytes)
```

Codes come from the Character server (D02 §14): `0x20B0` ok, `0x20B9` already used (`nRet −3022`), `0x20BA` guild
master (`−3025`), `0x20B8` any other DB failure. The zone's own pre-check codes (`0x20B1…0x20B6`, `0x1A78`) go out
directly from `0xB410` (Z01 §9).

Client (`GameFrameWork::On_NC_USER_CONNECTION_CHANGE_CHAR_ID_ITEM_USE_ACK`, client FUN_004b2bc0):
- `0x20B0`: modal "Name Change activated. You will be given the option to change upon relogging."; looks up
  `nUsedItemID` in the client item table; item class 4 → selected avatar `+0x77 = 1`; class 5 → `+0x77 = +0x78 = 1`
  (the char-select list then offers the rename; class 5 is the premium variant, the same split as Z01 §9 `premium`).
- `0x20B9` "Already used the Name change- premium item.", `0x20BA` "Guild Master not allowed to use human relationship
  reset item. first transfer to another guild master position." (system messages).
- every other code, `0x20B8` included: "Cannot use the item due to an Abnormal State." (Z01-B7 covers the zone codes).

### 1.2 WM 0xB40F NC_USER_CONNECTION_ZONE_CHANGE_CHAR_ID_CMD (WorldManagerSession)

Sent by the WM to **all** zones (`CWMZoneSessionManager::BroadCast`) from `CWMClientSession::CharIDChange` (wm
FUN_00431dd0, W01 §6.2) after CharDB confirmed a rename (`0xB40B` with `0x20C0`). The character is at character select,
not on a map; only its party / raid record on the zone is touched.

```pseudo
0xB40F NC_USER_CONNECTION_ZONE_CHANGE_CHAR_ID_CMD { u32 nCharNo, u8 bInit, Name5 sOldID, Name5 sNewID }   (0x2d bytes)
                                                                                                       @ FUN_0044caa0
    # bInit = the avatar's CHAR_ID_CHANGE_DATA.bInit: the rename item also reset the character's relations (D02 §14)
    raidNo = RaidTask::GetRaidSystem().GetInRaidNumber(nCharNo)                                @ FUN_0063d8b0
    if raidNo == 0xFFFF:                                       # not in a raid: plain party
        partyNo = CParty::PartyGetNo(&partycontainer, nCharNo)
        if partyNo == 0xFFFF or partyNo ≥ 4000: return
        slot = CParty::MemberGetNo(&partycontainer, partyNo, nCharNo)                          @ FUN_00645280
        if slot < 0: return
        if bInit == 1: CParty::MemberLeave(&partycontainer, partyNo, nCharNo)   # Z08 §1 Party_RemoveMember FUN_00645710
        else:          partycontainer.m_Array[partyNo].Members[slot].charname = sNewID
    else:
        r = GetRaid(raidNo); if !r: return
        it = r.Find(nCharNo); if it == r.End(): return
        if bInit == 1: r.DeleteMember(nCharNo, &out)                             # Z14 §5.1 FUN_0063de00
        else:          it.UpdateMemberName(&sNewID)                                            @ FUN_0063d620
    # nothing is sent: no client, WM or other-zone packet. sOldID is not read.
```

The zone only mirrors the WM's party records (Z08 §1, Z14 §5); the WM sends its own party / raid updates. With
`bInit` the zone removes the member from its copy without `pm_MemberLeave` (no link-member cleanup) *(inferred: the
character is offline at that moment, so no member object is linked)*.

Helpers:

```pseudo
RaidSystem::GetInRaidNumber(charNo) → raidNo or 0xFFFF                                       @ FUN_0063d8b0
    charNo == 0xFFFFFFFF → 0xFFFF
    for raid in m_RaidSlot[0..499] with m_NumOfMember ≠ 0:
        for partyIndex 0..3, slot 0..4:
            party = sm_pPartyData[m_PartyNos[partyIndex]] (skip 0xFFFF / null)
            member charNo = slot < party.NumOfMember ? Members[slot].chrregnum : 0xFFFFFFFF
            == charNo → return the raid's slot index (0..499)
    → 0xFFFF                                       # linear scan of 500 × 20 slots

Raid::iterator::UpdateMemberName(it, name) → bool                                            @ FUN_0063d620
    party = sm_pPartyData[it.m_pRaid.m_PartyNos[it.m_nPartyIndex]] (index 0..3, else 0xFFFF → null)
    party and 0 ≤ it.m_nSlot < min(NumOfMember, 5): Members[slot].charname = name (20 bytes); true;  else false

CParty::MemberGetNo(partyNo, charNo) → slot                                                  @ FUN_00645280
    partyNo ≥ 4000 → −1;  first i < NumOfMember with Members[i].chrregnum == charNo → i;  none → −2
```

### 1.3 Client 0x4025 NC_CHARSAVE_UI_STATE_SAVE_REQ

`sp_NC_CHARSAVE_UI_STATE_SAVE_REQ` @ FUN_00562f40 (log name `sp_NC_MISC_DB_UI_STATE_SAVE_REQ`) is fully described in
Z12 §7 ("The mystery-vault flag is also changed by the client"): no mode / value / length check, GameDB ←
`0x4027 { u16 handle, u32 charNo, u8 btMysteryType }`, `p.sp_MysteryVaultUI = btMysteryType`; the DB answer `0x4028` →
`0x4026` has no 2016 client handler. Checked against the code: complete, nothing to add.

## 2. Item dismantling internals (answers Z04 §12.1)

`ItemDismantleProducer` (0x2194 bytes, on the stack of `sp_NC_ITEM_DISMANTLE_REQ` FUN_005293c0):

```
+0x0000 InventoryCellLock* idp_ItemLock   (= p.vt 0x7d4)        +0x000c u32 idp_nProductCnt   (Karis count n)
+0x0004 ItemBag*  idp_Inventory           (p.sp_Item inventory)  +0x0010 int idp_nProductCellCnt
+0x0008 u16       idp_ProductID           (= itemdatabox.idb_specialid.sii_Karis, Z04 g_KarisItemID)
+0x0014 idp_Product[64] (0x84 each): u16 productuselot_log, ItemInventoryCell* cell, ItemAttributeClass* iac,
        ItemTotalInformation iti (copy of the target cell's item, 0x6f bytes), int slot, u8 iscreated
+0x2114 idp_Raw: ItemInventoryCell* cell, ItemAttributeClass* iac (always null), ItemTotalInformation iti, int slot
+0x2190 ChargedEffectContainer* idp_ChargedEffectContainer (= p.vt 0x498; premium inventory size)
```

```pseudo
ItemDismantleProducer(p, productID, n, inventory, slot)                                      @ FUN_00528a90
    store the fields above; idp_Raw = { cell = inventory[slot], iac = null, iti = copy of that cell's item, slot }
~ItemDismantleProducer()                                                                     @ FUN_00528ba0
    profiler only (no members to free)

idp_DismantleProduceCheck() → code                                                           @ FUN_005290f0
    return idp_WhereDismantleProductStore()        # 0x1680 = ok; any other code is sent as 0x302B by the handler

idp_WhereDismantleProductStore() → code   (log name "…idp_WhereProductStore")                @ FUN_00528be0
    info = ItemDataBox[idp_ProductID]; none (or the index row's ID differs) → assert "…Invalid Item", return 0x168B
    maxLot = info.MaxLot; left = idp_nProductCnt; used[] = {}  (cells already chosen, up to 64)
    limit = inventory size: chargedEffect ? bag.vt 4(chargedEffect) : bag.vt 8()        # premium-expanded size
    k = 0
    while left > 0 and k < 64:
        lot = left ≥ maxLot ? maxLot : left
        # 1) stack onto an unlocked inventory cell (type 9) that already holds the product
        for c over UnlockedInventoryIterator(lock list, ItemBoxIterIdent(productID), type 9):
            if c.lot + lot > maxLot or c ∈ used: continue
            P[k] = { cell c, iac = c.iic_AttrProc, iti = copy of c's item with lot = c.lot + lot (iac vt 0x20),
                     slot = c.slot, iscreated = 0, productuselot_log = lot };  used += c;  found
        # 2) else a free unlocked cell
        if not found:
            for c over UnlockedInventoryIterator(lock list, ItemBoxIterEmpty, type 9), c ∉ used:
                P[k] = { cell c, iti.registnum = iti_mkregnum(productID, 8, zoneNo, worldNo), itemid = productID,
                         iac = itmattcontainer[productID], lot via iac vt 0x20, slot, iscreated = 1 };  used += c
            none → return 0x168C ("inventory full")
        left −= lot; k += 1
    # (original bug) Z30-B5: more than 64 stacks needed → the loop stops; the rest is dropped and the result is still ok
    idp_nProductCellCnt = k;  return k > 0 ? 0x1680 : 0x168B
```

Codes (client error table, Z04 §12.1): `0x1680` "Item has been dismantled. Karis has been created.", `0x168B` (Karis
missing from ItemInfo), `0x168C` inventory full.

```pseudo
idp_DismantleProductExecute(p, buf, req) → payload length   (log "ItemDismantleProducer::id_ProductExecute")   @ FUN_00529110
    # req = gpp+2; the caller already wrote 0x3476, header.clienthandle = p.handle, header.charregistnumber = charNo
    tail = req + 0x1a + k × 0x2b          # attribute data area after the produce[] array
    for i in 0..k−1:  e = produce[i] (0x2b bytes at req+0x1a):
        e.create = P[i].iscreated;  e.product = P[i].iti.itemid;  e.productuselot_log = P[i].productuselot_log
        if create == 0:  e.iteminfo.itemchange = { attritemregnum = P[i].iti.registnum,
                                                   attr = tail − (gpp+2)   (offset of this item's attribute data),
                                                   location = ITEM_INVEN 0x2400 | P[i].slot }
        else:            e.iteminfo.itemcreate = { owner = p.charNo, map = { p's map name (12 bytes, p+0x7a),
                                                   p's x, y (p+0x66) }, location = 0x2400 | slot,
                                                   createitemregnum = P[i].iti.registnum, createitemid = itemid,
                                                   attr = tail − (gpp+2) }
        tail = P[i].iac.vt 4(&P[i].iti.itemstruct, tail)                  # append the item's attribute bytes
        L.vt 0x40(L.icl_Index, P[i].cell, &P[i].iti, &location, &location) # reserve the cell with the new contents
    # idp_Raw.iac is always null here, so the raw block is always written:
    req.raw = { vanish = 1, rawid = dismantled itemid, rawuselot_log = 1,
                iteminfo.itemchange = { attritemregnum = its registnum, attr = 0x2400 | slot (low 10 bits = slot) } }
    L.vt 0x30(L.icl_Index, idp_Raw.cell, &attr, &attr)                    # clear-cell reservation for the dismantled item
    req.producenumber = k;  req.lockindex = L.icl_Index;  L.icl_Index += 1
    return tail − (gpp+2)     # the caller sends pp_SetPacketLen(len + 2) to GameDB
```

`0x3476 NC_ITEMDB_DISMANTLE_REQ` layout *(pdb2016, matches the writes)*: `{ NETPACKETZONEHEADER header @0, u16 lockindex
@6, raw { u8 vanish, u16 rawid, u16 rawuselot_log, union { PROTO_ITEM_VANISH, PROTO_ITEM_ATTRCHANGE } (0xc) } @8, u8
producenumber @0x19, produce[producenumber] { u8 create, u16 product, u16 productuselot_log, union { PROTO_ITEM_CREATE
(0x26), PROTO_ITEM_ATTRCHANGE (0xc) } } (0x2b each) @0x1a, attribute data… }`. In `raw.itemchange` the `attr` member
holds the location word, unlike the produce entries where `attr` is the attribute-data offset and `location` the cell
*(as written; the DB side is D03's `0x3476`)*. The answer `0x3477` is Z05 §8.6.

## 3. Soul stones: SP use and the queued use (answers Z04 §13.2)

`sp_HPStoneManager` / `sp_SPStoneManager` (`PointStoneCheck` = the queued action as a member-function pointer,
`StoneTick` = next use allowed, `StoneReservationTick` = from when a request is queued). The "cleared" state is the
pointer `ShineObject::so_Gamble_ChangeCoin`, an empty function shared by identical-code folding (Z04 calls it no-op).

```pseudo
sp_SPStoneUse(p)                                                                             @ FUN_00588a40
    so_AllOfRange(p, all, AxialListPacketBroadcast) ← 0x500C NC_SOULSTONE_SP_SOMEONEUSE_CMD { u16 p.handle }   (players in sight, p included)
    p ← 0x500A NC_SOULSTONE_SP_USESUC_ACK (empty, so_SendProtocol(20, 10))
    PointStoneCheck = no-op;  StoneTick = g_Now + 70 (7 s);  StoneReservationTick = g_Now + 50 (5 s)
    CurSPStone −= 1
    row = class data (vt 0x49c) +0x10858 + level × 4  (level = so_GetLevel & 0xff; ≥ 151 → entry 0)
    CurSP += cec_MaxSPRate (sp_ChargedItem.ci_Effect, ‰) × row+0x28 / 1000;  CurSP = min(CurSP, MaxSP (p+0xeac))
    so_AllOfRange(p, all, so_ply_Send2WhoTargetMe)           # SP bar to everyone who has p targeted

sp_SPStoneReserv(p)   (the queued action, called from the player tick)                       @ FUN_00588c50
    if StoneTick > g_Now: return
    CurSPStone == 0 → PointStoneCheck = no-op;  else sp_SPStoneUse(p)
    # (original bug) Z30-B2: no dead / HP / "SP already full" re-check, unlike the request (Z04 §13.2)

sp_HPStoneReserv(p)                                                                          @ FUN_00589410
    if StoneTick > g_Now: return
    CurHPStone == 0, or so_GetHP() (vt 0x4e8) == 0, or so_AmIAlreadyDead() (vt 0x28) → PointStoneCheck = no-op
    else sp_HPStoneUse(p) (Z04 §13.2, FUN_00589180)           # no "HP already full" re-check (Z30-B2)
```

Client 0x500C: FUN_004ad900 (reads the handle, plays the `SPSoulStone` effect).

## 4. Character title helpers (answers Z08 §7.2)

```pseudo
ShinePlayer::sp_CharTitleChangeAvailable(p) → bool = p.sp_NextCharTitleChangeTime (p+0x2aa48) < g_Now   @ FUN_005608e0
    # 0x6001's 10-second rule; the setter is Z18 §6.1 FUN_00560900

CCharacterTitleZone::Send_NC_CT_SET_CURRENT_ACK(t, Type, ElementNo, MobID, Error)            @ FUN_005ca9e0
    p ← 0x6002 NC_CT_SET_CURRENT_ACK { u8 Type, u8 ElementNo, u16 MobID, u16 Error }   (game socket, vt 0x2fc)
    if Error == 0xA01 and not (p.so_Field and fm_FieldOption and fm_FieldOption.NameHide):
        so_AllOfRange(p, all, AxialListPacketBroadcast) ← 0x6003 NC_CT_SET_SOMEONECHANGE_CMD
            { u16 hnd = p.handle, u8 Type, u8 ElementNo, u16 MobID }     # NameHide maps hide titles like names
        # client 0x6003: FUN_00499700 (updates that player's title)

CCharacterTitleZone::Send_NC_CT_SET_CURRENT_DB_CMD(t, req, UseTitle, UseAbleTitle)            @ FUN_005cadd0
    any argument null → assert "ShinePlayer:::so_SaveToDB_CharTitle : buf is NULL"; return
    charNo = p.vt 0x344;  charNo == −1 or 0 → assert ("Send_NC_CT_DB_SET_CMD : …charregistnumber"); nothing sent
    GameDB ← 0x6008 NC_CT_SET_CURRENT_DB_CMD { header { u16 p.handle, u32 charNo }, u8 CurrentTitle = req.Type,
        u8 CurrentTitleElement = req.ElementNo, u16 CurrentTitleMobID = req.MobID, CT_INFO UseTitle, CT_INFO UseAbleTitle }
        # 0x10 bytes; CT_INFO = { u8 Type, u8 ElementNo:6 | ElementValue:2 }; Character side D04 §4.2 0x6008

CCharacterTitleZone::CT_SellNPC(t, itemKey, itemId)                                         @ FUN_005cbff0
    m_TitleValues[0x17].TitleValue += 1 (u64);  bTitleSave = 1;  CheckNewTitle(t, 0x17) (Z18 §6.2)
    # type 23 = "Apprentice / Advanced / Pro / Master Merchant" (CharacterTitleData.shn: 500 / 1000 / 3000 / 5000);
    # called once per sale by ItemInventory::ii_SellAll / ii_SellLot (0x3006, Z04 §2.4): one sale = +1, whatever the lot

CCharacterTitle::Clear(t)                                                                    @ FUN_0062e370
    m_Titles[0x80 bytes] = 0;  m_CurrentTitle = 0;  m_CurrentTitleElement = 0;  m_CurrentTitleMobID = 0xFFFF
    m_pTitle = &szCTNone;  m_NumOfView = 0
    # caller: CCharacterTitleZone::InitNewPlayer FUN_005ca620 (Z07 §1.3 "t.Reset") at WM 0x1031 NC_CHAR_ZONE_CHARTITLE_CMD
```

## 5. Spam-filter table getters (answers Z02 §3.4)

`SpamerPenaltyDataBox` (0x90 bytes): `BinaryDataBox<SpamerPenaltyRule> spdb_BinSpamerPenaltyRuleData` @0
(`SpamerPenaltyRule.shn` row `{ u16 SecondRule, u8 RepeatRule }`), `BinaryDataBox<SpamerPenalty>
spdb_BinSpamerPenaltyData` @0x44 (`SpamerPenalty.shn` rows `{ u8 PenaltyLv, u16 ChatBlockTime, u16 ProbateTime }`),
`u8 spdb_SpamerPenaltyMaxNum` @0x8c; loaded by `spdb_Load` FUN_005897f0 (Z01 §2.3, `zs_start_long`). An empty table falls back
to the box's `bdb_defaultblock`.

```pseudo
spdb_SpamePenaltyGetSecondRule() → u16 = (rule row 0 or default).SecondRule / 100              @ FUN_00589820
    # SecondRule is in milliseconds (3000); /100 gives g_Now tenths (30 = 3.0 s)
spdb_SpamePenaltyGetRepeatRule() → u8 = (rule row 0 or default).RepeatRule                    @ FUN_00589850
spdb_SpamePenaltyGetChatBlockTime(level, &out) → bool                                       @ FUN_00589870
spdb_SpamePenaltyGetProbateTime(level, &out) → bool                                         @ FUN_00589900
    for i in 0..spdb_SpamerPenaltyMaxNum−1: row = i < rows ? row i : default
        row.PenaltyLv == level → out = row.ChatBlockTime (resp. ProbateTime), in seconds; true
    → false (out untouched)
```

Their only callers are `sp_SpamCheck` FUN_005649d0 and `sp_SpamSetBlock` FUN_00562ab0 (Z02 §3.4 "Penalize"), which
multiply the seconds by 10.

## 6. Zone ring: holy-promise money transfer and the academy-master teleport

### 6.1 0x9436 NC_HOLY_PROMISE_CENTRANSFER_RNG (dead path in 2016)

```pseudo
zls_NC_HOLY_PROMISE_CENTRANSFER_RNG(pkt)                                                       @ FUN_004839b0
    { ZONERINGLINKAGESTART start { u8 machine, u16 handle, u32 regnum }, u32 upper, u32 cen, Name5 lower }   (0x23 bytes)
    if zls_TravelComplete(start) (FUN_0045b1f0): return   # back at the origin zone: dropped (Z01 §10, Z13 §4.6)
    hpctm_Process(&hpctmanager, pkt)

HolyPromiseCenTransferManager::hpctm_Process(m, pkt)                                         @ FUN_00483860
    (copies `lower` into the namestring ring; unused)
    q = som_FindPlayer(upper)                      # the receiving master, by charNo
    q missing → forward unchanged: ZoneConnect ← 0x9436 { start, upper, cen, lower } (0x25 bytes with the opcode)
    else      → q.so_ply_HolyPromiseCenFrom(pkt) (vt 0x9cc)

ShinePlayer::so_ply_HolyPromiseCenFrom(q, pkt)                                               @ FUN_00484240
    if q's lock list has an open lock (invenlocklist vt 0x10): return   # (original bug) Z30-B1: the money is dropped
    sp_HolyPromiseCenFrom(q, pkt.cen, &pkt.lower)

ShinePlayer::sp_HolyPromiseCenFrom(q, cen, lowerName)                                        @ FUN_00483aa0
    q.so_ply_IncDecMoney(cen, 1) (vt 0x794)                             # credit the money (Z04 money path)
    q ← 0x941B NC_HOLY_PROMISE_REWARD_MONEY_CMD { Name5 MemberCharID = lowerName, u64 nMoney = cen (high half 0) }   (0x1c bytes)
    # client FUN_004b0040: system message with the trainee name and the amount (Gem / Gold / Silver / Copper)
```

Nothing in the 2016 zone starts this transfer: `0x9436` is only sent by `hpctm_Process` itself (forwarding), and the
spending hook that would create it, `so_ply_HolyPromiseCenUseTry` (vt 0x9c4, FUN_004837d0) and
`so_ply_HolyPromiseCenUseSuccess` (FUN_00483820), are empty functions (Z04 §2.1 calls the hook). The path is kept here
because a rebuild that revives the trainee-spending reward needs it. The holy-promise reward withdrawal that does work
is Z08 §9.

### 6.2 Finding an academy member across zones: `ZoneRingPacketFindPlayerByNormalUser`

Started by WM `0x9878 NC_GUILD_ACADEMY_ZONE_MASTER_TELEPORT_CMD` (Z08 §10, FUN_0046ecb0) when the target member is not on
the master's zone. vt 4 = `zrpb_Success`, vt 8 = `zrpb_Failure` (same scheme as the GM search, Z11 §5.1).

```pseudo
zrpb_Request(master, pkt { start, Name5 charid })                                            @ FUN_005a7430
    if !master: return
    t = som_FindPlayer(charid)
    t missing: ZoneConnect ← 0x10AD NC_CHAR_PLAYERSEARCH_BY_NORMAL_USER_RNG
                   { start = { machine = own zoneNo, handle = master.handle, regnum = master.charNo }, charid }  (0x1d)
    t without a map: zrpb_Failure(master, pkt)
    else: found = { map = t's map, coord = t's x, y, charid = t.vt 0x56c name,
                    modeIDLv = map.fm_eLevelType (ILT_MAX → 1), canRecall = t.so_ply_IsLink_In_MapAndSendErrorMsg() (vt 0xa78) == 1 }
          if t is in a mini house (so_ply_MH_GetActiveMH, vt 0x130): house = som_GetObject(so_ply_MH_GetMyHandle (vt 0x138));
                map / coord = house.vt 0x14c (5 dwords: the house's map and outside position)
                house missing → return            # (original bug) Z30-B4: the master gets no answer
          zrpb_Success(master, found)

0x10AD NC_CHAR_PLAYERSEARCH_BY_NORMAL_USER_RNG { start, Name5 charid }  (0x1b)                @ FUN_0045c0b0
    if start.machine > 9 or start.machine == own zoneNo:           # travelled the whole ring
        o = som_GetObject(start.handle); o and o.charNo == start.regnum → zrpb_Failure(o, pkt)
        return
    t = som_FindPlayer(charid)
    t missing or without a map → forward the packet unchanged (0x1d)
    else: 0x10AE NC_CHAR_PLAYERFOUND_BY_NORMAL_USER_RNG { start, Name3 map, SHINE_XY_TYPE coord, Name5 charid,
                                                           u8 canRecall, u8 modeIDLv }   (0x31 bytes, 0x33 with the opcode)
          m = zls_FindPlayer(start) (only found if the master is on this zone too)
          if m: e = fc_CanEnterField(m, t)                    # player / player overload
                e == ENTER_MAP_ERR_DATA_NULL → return (nothing sent)
                e == ENTER_MAP_ERR_LEVEL_LIMIT → m.so_SendErrorCode(38, 32, 0x3E00) (0x9820 "Unable to Travel to Academy
                     Member due Level Restriction on Map"); return
          canRecall = t.vt 0xa78 == 1;  ZoneConnect ← 0x10AE

0x10AE NC_CHAR_PLAYERFOUND_BY_NORMAL_USER_RNG                                                @ FUN_0045c340
    start.machine < 10 and ≠ own zoneNo → forward (PROTO operator=, 0x33)
    else o = som_GetObject(start.handle); o.charNo == start.regnum → zrpb_Success(o, pkt)

ZoneRingPacketFindPlayerByNormalUser::zrpb_Success(master, pkt)                              @ FUN_005a7cf0
    if !master: return
    mp = master.vt 0xbbc (ShinePlayer cast; identity for players)
    if mp:
        e = fc_CanEnterField(mp, pkt.map, pkt.modeIDLv)          # map-name overload
        e == ENTER_MAP_ERR_DATA_NULL → return
        e == ENTER_MAP_ERR_LEVEL_LIMIT → mp.so_SendErrorCode(38, 32, 0x3E00); return
    if master.so_ply_IsLink_In_MapAndSendErrorMsg() (vt 0xa78) == 1 and pkt.canRecall:
        master.so_ply_BriefLink(pkt.map, pkt.coord) (vt 0x890)    # the master travels to the member

ZoneRingPacketFindPlayerByNormalUser::zrpb_Failure(master, pkt)                              @ FUN_005a8170
    if master: master.so_ply_Notice(sprintf("%s is not in game", pkt.charid)) (vt 0x784)   # charid at payload +7
```

`ENTER_MAP_ERR` *(pdb2016)*: 0 NONE, 1 DATA_NULL, 2 LEVEL_LIMIT, 3 PARTY_LIMIT, 4 NEED_PARTY_OR_QUEST, 5 NEED_RAID,
6 NEED_ITEM. The two overloads used here return only 0, 1 or 2 (the other values come from the instance-dungeon
checks, Z08 §5):

```pseudo
FieldContainer::fc_CanEnterField(p, char* map, u8 levelType) → ENTER_MAP_ERR                 @ FUN_00462380
    p or map null → DATA_NULL
    m = p.so_MoverSystem_GetMover() (vt 0xc74)
    no mover: row = FieldLevelDataBox::fldb_GetFieldLv(map, levelType) (FUN_0046a370);
              row and (p.level < row.LvFrom or p.level > row.LvTo) → LEVEL_LIMIT
    on a mover: m's owner charNo (vt 0xca8) ≠ p.charNo → DATA_NULL (only the driver may take the mover along);
              for every seat i < m.vt 0xcd8() with a passenger (vt 0xcdc(i)): same level test on the passenger → LEVEL_LIMIT
    → NONE
FieldContainer::fc_CanEnterField(p, ShinePlayer* t) → ENTER_MAP_ERR                          @ FUN_004621f0
    the same tests with map = t's map (t+0x7a field: name +0xc, level type +0x214, value 3 → 1); no level row → NONE
    t without a field → DATA_NULL (both branches); p on a mover it does not drive → DATA_NULL
    # also the "local summon" call of Z08 §10 0x9878 (Z08 reads FUN_004621f0 as the summon itself; it is this check)
```

`canRecall` is the target's own "can a link start here" test (vt 0xa78 also sends the target an error text
when it fails *(inferred from the PDB name)*).

## 7. Sight and NPC callbacks

```pseudo
ShineObject::so_HideExceptMeOff_BriefInfo(obj, rcv, distSq) → 1 (continue)                   @ FUN_00441700
    # map iterator callback of ShinePlayer HideExceptMeOff_Exchange FUN_00441940 (Z02 §5.2 end): rcv just turned
    # "hide except me" (sp_MiscFlag bit 3 SoloingMode) off and gets the brief info of the objects it was hiding
    by obj.so_BriefInfoRange() (vt 8): 0 skip; 1 always; 2 skip if obj.so_FieldSightSquar() < distSq;
                                        3 skip if global sightsquar < distSq; other → assert "…so_ExchageBriefInfo : INVALID TYPE"
    if obj.smo_GetMode() (vt 0x484) == 0: skip
    if obj has a game status / move state (vt 0xa18 / vt 0x7b4 ≠ 0): mobinroam.push_back(obj)
    by obj kind (vt 0x4d0):
        2 player, 8 (bandit):  BriefInfoExchangeCharacter.bixc_Exchange(rcv, obj) + abstates (briefabstate_char)
        4, 5, 10 (NPC, mob, servant): bixm_Exchange + abstates (briefabstate_mob)
        11 mover: only if obj's owner charNo (vt 0xca8) ≠ rcv.charNo: bixmv_Exchange + abstates (own mover skipped)
        12 pet: bixp_Exchange
        0, 1, 3, 6, 7, 9: nothing        # items, mini houses, magic fields were never hidden (Z02 §5.2 table)
        other: assert
```

Compared with `so_ExchageBriefInfo` FUN_00441460 (Z02 §5.2) it skips the object kinds the soloing mode never hides and
the receiver's own mover.

```pseudo
ShineObject::so_BroadcastEndOfTrade(obj, npc, _) → 1                                         @ FUN_00552e10
    obj.so_ply_EndofTrade(npc.handle, 1) (vt 0xb3c)     # close obj's dialog with that NPC
    # map iterator callback of NPCManager::nm_UnmarkNPC FUN_004c6ad0 (Z01 §9 NpcSchedule "end"; so_ply_EndofTrade
    # FUN_004c4b50 = sp_EndOfTrade of Z02 §6.2): before a scheduled
    # event NPC is removed (vt 0x33c(0, 1, 3)), every object on its map is told; non-players have an empty slot
```

## 8. Party, raid and guild helpers

```pseudo
CParty::GetEmptyParty() → partyNo or 0xFFFF                                                  @ FUN_00645070
    i = m_EmptyPartySearchPoint wrapped into 0..3999
    up to 4000 steps: first i (cyclic) with !isRaidTypeParty and NumOfMember == 0
    found → m_EmptyPartySearchPoint = (i + 1) % 4000; return i      # round-robin, so freed numbers are not reused at once
    callers: CParty::CreateRaidParty FUN_006451d0 (raid parties: marks isRaidTypeParty, 5 slots −1, m_NumOfParty += 1;
             NO_EMPTY_PARTY_BF when full) and CParty::MemberJoin FUN_00645600 (Z08 §1 Party_Create, when partyNo ≥ 4000)

CParty::SwapPartyMember(partyA, slotA, partyB, slotB) → bool                                 @ FUN_006459e0
    parties < 4000 and slots < 5, else false;  swap the two PARTY_MEMBER_SLOTs (operator= below); true
    # NumOfMember is not adjusted: the caller Raid::SwapMember FUN_0063ded0 (Z14 §5.1) handles counts
PARTY_SLOT::PARTY_MEMBER_SLOT::operator=(dst, src)                                           @ FUN_006455a0
    copies MemberInform { Member { chrregnum, zonecharhandle, wmcharhandle, charname, level, flag, charclass },
                          ZoneMerchineNo } and memberobj (the local object link)

Raid::iterator::operator==(a, b) = a.m_pRaid ≠ null and a.m_pRaid == b.m_pRaid and same m_nPartyIndex and m_nSlot
                                                                                             @ FUN_0063d0a0
    # used by the rt_SendPlayer* loops (Z14 §5.3) to stop at End(); an iterator with a null raid never equals End

CGuildZone::Add(gz, guild) → 1 ok / 0 full                                                   @ FUN_005cc900
    e = gz_GuildList.vt 8(empty finger) (new list element); finger == 0xFFFF (list full) → e = null
    e null → assert "CGuildZone::ClearWar : Guild Buffer Full." (wrong function name in the text, Z30-B6); return 0
    e.GuildZone = guild (GUILD_ZONE::operator=);  e+0x38 u16 list index = finger;  e+0x34 u32 = 0
    # caller: Recv_NC_GUILD_ZONE_MAKE_CMD FUN_005cca80 (Z08 §8 0x7448); on 0 the new guild is not set on the master
GUILD_ZONE::operator=(dst, src)                                                              @ FUN_005cc790
    member-wise copy: nNo, sName (16), nMoney (u64), nType, nGrade, nFame, nStoneLevel, nExp (u64), nWarStatus, nWarEnemy

CGuildZone::Send_NC_GUILD_ZONE_LIST_REQ(gz) → 1                                              @ FUN_005cc980
    if !gz_IsSendReq: WM ← 0x7446 NC_GUILD_ZONE_LIST_REQ (pp_SetPacketLen(3): opcode + 1 byte never written; gz_IsSendReq = 1
    # (original bug) Z30-B8: one uninitialised byte on the wire (the WM reads no body, W03 §3.5)
    # once per process: the caller is wms_NC_MISC_S2SCONNECTION_ACK FUN_005a3320 (Z01 §8.2); a WM reconnect does not
    # ask again (the flag is never cleared); the answer 0x7447 is Z08 §8

GuildWarManager::gwm_IsEnemyGuild(m, a, b) → GuildWarElement* or null                        @ FUN_00481070
    a ≠ b, both ≠ 0: scan gwm_Array[0..4095] (gwm_Pointer is the loop index) for {attacker, defender} == {a, b} either way
GuildWarManager::gwm_EnemyCheck(m, expected, a, b)                                           @ FUN_00481190
    gwm_IsEnemyGuild(a, b); result discarded       # expected (0/1) unused: a release build's empty consistency check
    # caller: CGuildZone::IsGuildEnemy FUN_005ccdf0 (Z03 / Z16 / Z17) after deciding from GUILD_ZONE.nWarStatus == 2 and
    # nWarEnemy; every call pays a 4096-entry scan for nothing (Z30-B7)

GuildAcademyRewardStorageElement::garse_GuildCheck(e, guildNo) = e.garse_Guild == guildNo    @ FUN_00470800
    # callers: sp_ItemReloc FUN_00536780, 0x300D split FUN_00539a40, so_ply_ItemLotCheck FUN_0053a5c0 (Z04 §4, §7.5):
    # the guild-academy reward box may only be used for the player's own guild

ItemGuildStorage::~ItemGuildStorage(s)                                                       @ FUN_00643280
    vfptr = ItemGuildStorage; destroy igs_Array (0x24 cells × 0x74 bytes; the cell destructor is the empty folded function);
    vfptr = ItemBag
    # callers: GuildStorageManager functions (gsm_FindStorage FUN_004751f0, FUN_00474e80, FUN_00475610, Z14 §3):
    # the destructor of temporary / removed storage elements (inferred from the call sites)
```

## 9. Remaining helpers

```pseudo
WELLRNG512a() → double in [0, 1)                                                             @ FUN_0063c8c0
    # the reference WELL512a generator (Panneton / L'Ecuyer / Matsumoto): u32 STATE[16], state_i
    V0 = STATE[i]; VM1 = STATE[(i+13) & 15]; VM2 = STATE[(i+9) & 15]; z0 = STATE[(i+15) & 15]
    z1 = V0 ^ V0 << 16 ^ VM1 ^ VM1 << 15;  z2 = VM2 ^ VM2 >> 11
    STATE[i] = z1 ^ z2
    STATE[(i+15) & 15] = z0 ^ z0 << 2 ^ z1 ^ z1 << 18 ^ z2 << 28 ^ (z1 ^ z2) ^ ((z1 ^ z2) << 5 & 0xDA442D24)
    i = (i + 15) & 15;  return STATE[i] (as unsigned) × 2^-32
InitWELLRNG512a(seed[16]) : STATE = seed; state_i = 0                                         @ FUN_0063c890
    # seeded once in zs_mainthreadfunction (Z09 §1.1: srand(time()), 16 × rand()); only the main thread uses it
```

The decompiled form writes the last term as `((… << 13 ^ (z1 ^ z2) & 0xFED22169) * 8 ^ z0) * 4` (the compiler factored
the `<< 5`; `0xFED22169 << 5` = `0xDA442D20`). A Python port of the decompiled expression and of the reference gave the
same output for 200 random seeds × 50 draws, so it is the unmodified reference algorithm. Callers: only the mover upgrade's rare roll:

```pseudo
CMoverUpgradeData::GetIsRareMover(d, value, sub) → 0/1                                      @ FUN_004c03b0
    rate = RareMoverRate row[value] (u16; missing → last row; no rows → 0)
    r = (u32)round(WELLRNG512a() × 1e11)               # low 32 bits of a value up to 10^11
    return r % 1000 + 1 ≤ rate + (RareMoverSubRate row[sub] (u16) or 0)        # rate in ‰
CMoverUpgradeData::GetRareMoverItemID(d) → itemID or 0xFFFF                                 @ FUN_004c0490
    r = (u32)round(WELLRNG512a() × 1e11)
    first m_RareMoverInfo entry { u16 itemID, u32 cumulative rate @+4 } (8 bytes) with r % m_nTotalEachRateValue + 1 ≤ cumulative
```

(This answers Z04 §14 "the mover-upgrade rare roll formula is not reconstructed"; the tables are Z13 §7.1.)

```pseudo
ShineDateTime::operator+=(t, seconds) (long64)                                               @ FUN_00517a80
    # ShineDateTime = u32 bit field { year:8 (since 2000) @0, month:5 @8, date:6 @13, hour:6 @19, minute:7 @25 }
    tm = { year + 100, month − 1, date, hour, minute, sec 0, isdst −1 };  s = _mktime64(tm) + seconds
    t = _localtime64(s) packed back (minute resolution, local time)
    # only caller: 0x3057 NC_ITEM_TERMEXTEND_REQ FUN_0051eb40 (Z04 §12.9):
    #   cap    = now (chargeditemcheck.ct_Current) + 2160 h (90 days), via _mktime32 on tm_hour + 0x870
    #   newEnd = term item's end date (attribute, must have year ≠ 0) + extend item's ChargedItemEffect.KeepTime_Hour × 3600
    #   end = newEnd > cap ? cap : newEnd           # written into the item attribute in memory at once
    #   DB 0x34B7 carries the old end @+0x87 and (new − old) seconds @+0x8b
    # (WeddingHall::wh_Reserv uses the other overload operator+=(ShineDateTimeSpan) FUN_0059ead0, Z07)

TownPortalData::operator[](index) → TownPortal* or null                                      @ FUN_0049fd60
    linear search of TownPortal.shn rows { u8 Index, u8 MinLevel, u8 TP_GroupNo, char MapName[32], u32 X, u32 Y } for Index
    # caller: 0x181A NC_MAP_TOWNPORTAL_REQ FUN_0049fe70 (Z01 §7.3); table load tpd_Load FUN_0049fbc0 (Z01 §2.3)

BoothStoreManager::RemoveItem(ownerHandle, itemKey) → value or 0xFFFFFFFF                    @ FUN_0043a420
    ownerHandle == 0xFFFF → assert "…The booth owner handle value is Invalid."; −1
    find the booth (bsm_StoreList node with that owner handle) else assert "…Cannot find the booth…"; −1
    find the item node with that 8-byte key else assert "…Cannot find the item…"; −1
    unlink and delete the node;  return node[4]      # (original bug) Z30-B3: read after operator delete
    # caller: BoothManager_RemoveItem FUN_0043ad30 ← 0x3456 booth trade ACK (Z05 §9.11, Z06 §2.1)

CItemAuthorityBase::IA_IsWorkChrBelonged(belongType, putOn) → 0/1                            @ FUN_00632180
CItemAuthorityBase::IA_IsWorkAccBelonged(belongType, putOn) → 0/1                            @ FUN_006321e0
    row = vt 4(belongType) (BelongTypeInfo.shn row { BT_Inx, PutOnBelonged, NoDrop, NoSell, NoStorage, NoTrade, NoDelete })
    if row.PutOnBelonged and putOn == SPOBI_NOT_BELONGED: row = vt 4(0)   # "binds on equip" items not yet equipped act as type 0
    Chr: NoDrop and NoStorage and NoTrade → 1         Acc: NoDrop and NoTrade → 1        (else 0; no row → 0)
    # callers: IA_CanInvenReloc FUN_00632280 (Z04 §1.3 BelongType_CanMove): character-bound items may not go to the
    # account storage, account-bound ones may

CShnDataFileCheckSum::GetDataFileCheckSum(i) → &CheckSumData[i].CheckSum (Name8) or null if i ≥ SHN_MaxCnt (49)   @ FUN_006313d0
CShnDataFileCheckSum::GetDataFileName(i)     → CheckSumData[i].DataFileName or null                               @ FUN_00631430
    # used only to build the log line of a checksum mismatch in 0x1801 NC_MAP_LOGIN_REQ (Z01 §5.2, code 0x068E)

NameString::operator[](Name8*) → next namestring ring buffer with the 32-byte name + NUL                      @ FUN_004519d0
    # the Name8 twin of Z18 §1.7's Name4 version FUN_0045b060; log formatting only

ItemMixData::GetMixItemIndex(inxName) → result InxName (char*) or null                       @ FUN_00635820
    m_ItemMixDataMap (std::map<string, string>, from ItemMix.shn): lower_bound(inxName); exact match → mapped value
    # caller: 0x3069 NC_ITEM_MIX_ITEM_REQ FUN_00521540 (Z04 §12.12: "result = ItemMix.shn row by the item's InxName")

AxialListCount::AxialListCount() : vfptr; alc_Cnt = 0                                        @ FUN_00428200
    # counting iterator for so_AllOfRange; caller CalculateBroadcastDistance::cbd_DistanceSquar FUN_0043e740 (Z02 §5.2)
ShinePlayer::sp_SetNormalLogoutTick(t) : sp_NormalLogoutTick = t                            @ FUN_005620f0
    # caller: 0x34BE NC_ITEMDB_CLASS_CHANGE_ACK FUN_00469590 (Z05 §8.5): success → vt 0x330(1), tick = g_Now,
    # sp_SetScheduleLogout (the class change forces a logout; Z12 §6.9 sets the tick to 0xFFFFFFFF at login)
FieldContainer::fc_GetFieldOption() → &fc_FieldOption                                        @ FUN_00419390
    # caller: 0x34CA MAPLINK_ITEM_CONSUME_ACK FUN_004698a0 (Z05 §8.5): fo_GetFieldAttr(mapName).mapidclient for the reply
ShineCommonParameter::operator->() → &scp_param                                             @ FUN_004192f0
    # callers: 0xA40D FUN_00485810 (Z08 §5.3: LevelTo = shineparam.levellimit, the server level cap),
    # RestExpCalculate ctor FUN_0059d4b0
ShinePlayer::sp_GetServerMenuactor() → &sp_NPCProcess.servermenuactor                       @ FUN_0048cec0
ShinePlayer::sp_IsInTrade() → sp_tradeboard.tb_opposit ≠ null                               @ FUN_004c2420
    # both from 0xA40D NC_INSTANCE_DUNGEON_LEVEL_SELECT_MENU_ACK FUN_00485810 (Z08): not in wait state, not trading,
    # and the server menu actor ready (sma_IsReady)
```

## 10. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z30-B1 | 0x9436 `so_ply_HolyPromiseCenFrom` FUN_00484240 | the receiver has any open inventory lock → return; the packet is not forwarded or retried; at the origin (`zls_TravelComplete`) an unfound receiver is dropped too | transferred holy-promise money vanishes (path dead in 2016: no sender) | queue / retry or return the money |
| Z30-B2 | queued soul stones `sp_SPStoneReserv` FUN_00588c50, `sp_HPStoneReserv` FUN_00589410 | the queued use re-checks only the stock (SP) or stock + HP ≠ 0 + not dead (HP); SP does not re-check death; neither re-checks "already full" | an SP stone is used on a dead player; stones are spent when HP / SP filled up meanwhile | repeat the request's checks |
| Z30-B3 | 0x3456 booth trade → `BoothStoreManager::RemoveItem` FUN_0043a420 | returns `node[4]` after `operator delete(node)` | use after free (heap reuse can return garbage) | read the value before deleting |
| Z30-B4 | 0x9878 → `zrpb_Request` FUN_005a7430 | target inside a mini house whose house object is not found → return | the academy master gets no answer at all | send the failure notice |
| Z30-B5 | 0x302A dismantle `idp_WhereDismantleProductStore` FUN_00528be0 | stops after 64 product stacks with the rest unplaced but still returns 0x1680 | products beyond 64 stacks are lost (unreachable with the 2016 tables: Karis MaxLot ≫ counts) | refuse with 0x168C |
| Z30-B6 | 0x7448 `CGuildZone::Add` FUN_005cc900 | full guild list asserts "CGuildZone::ClearWar : Guild Buffer Full." and the MAKE_CMD is dropped | wrong function name in the log; the master's guild is not set on this zone | correct text; log the guild |
| Z30-B7 | `CGuildZone::IsGuildEnemy` → `gwm_EnemyCheck` FUN_00481190 | scans the 4096-entry guild-war array on every call and discards the result | wasted work on every PvP target check (dead debug check) | remove, or compare and log |
| Z30-B8 | `CGuildZone::Send_NC_GUILD_ZONE_LIST_REQ` FUN_005cc980 | packet length 3 = opcode + one byte nobody writes | one stale byte of `gpp` goes to the WM | length 2 (empty body) |

## 11. Not reconstructed / uncertain

- §9 WELL512a: the tempering expression was copied as decompiled; whether it is the reference algorithm with a changed
  constant or a decompiler artefact was not checked against the assembly (`objdump` FUN_0063c8c0 is 33 lines).
- §9 TERMEXTEND: the zone writes the extended end date into the item attribute before the DB answer (an exception to
  Z04 knowledge §2 "nothing changes before the DB answer"). Whether `0x34B8`'s Free path (Z05 §8.5) restores the old date
  was not traced.
- §6.2 `canRecall` = the target's `so_ply_IsLink_In_MapAndSendErrorMsg` (vt 0xa78): whether it sends the error text to
  the target (not the master) was taken from the PDB name, not read.
- §8 `CGuildZone::Add`: the element offsets +0x34 / +0x38 are past the 0x31-byte `GUILD_ZONE`; named by Z08 as "enemy of"
  and list index *(inferred)*.
- §1.2: whether the WM sends its own party / raid packets to the zones and clients for a `bInit` rename (so that the zone
  copy and the WM agree) is W01's / W02's side; not followed.
- §8 `~ItemGuildStorage`: which object `gsm_FindStorage` destroys (temporary search key vs. removed element) is inferred
  from the call shape.

## 12. Coverage boundary

`coverage.py --overview` before this item: zone 983/1031 functions (48 gaps), 571/573 handlers. Every one of the 48 is
cited above with its `FUN_` address; the two handlers (FUN_0044caa0, FUN_0051b6d0) are §1.1 / §1.2.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `CWMClientSession::CharIDChange` wm FUN_00431dd0 (sender of 0xB40F, also 0xB40D) | W01 §6.2 (done; cites FUN_00431dd0) | WM side of the rename |
| Character DB 0xB411 / 0xB40A procedures | D02 §14 (done) | DB side |
| `sp_NC_USER_CONNECTION_CHANGE_CHAR_ID_ITEM_USE_REQ` 0xB410 FUN_0051b090 | Z01 §9 (done) | request side, already documented |
| `sp_NC_ITEM_DISMANTLE_REQ` FUN_005293c0, DB 0x3477 FUN_005298f0 | Z04 §12.1, Z05 §8.6 (done) | the handlers around §2 |
| `sp_HPStoneUse` FUN_00589180, SOULSTONE USE / BUY handlers | Z04 §13 (done) | §3 adds only the SP use and the queue |
| `sp_NC_CT_SET_CURRENT_REQ` FUN_005cb100, `CheckNewTitle` FUN_005cb5f0, `InitNewPlayer` FUN_005ca620 | Z08 §7.2, Z18 §6.2, Z07 §4 (done) | title logic around §4 |
| `sp_SpamCheck` FUN_005649d0, `sp_SpamSetBlock` FUN_00562ab0, `spdb_Load` FUN_005897f0 | Z02 §3.4, Z01 §3 (done) | spam filter use and load |
| `zls_TravelComplete` FUN_0045b1f0, `ZoneConnectSession::zcs_Send` (ring transport) | Z01 §10, Z13 §4.6 (done) | shared ring plumbing |
| the other `fc_CanEnterField` overloads FUN_00461ee0 / FUN_00462040, `fldb_GetFieldLv` FUN_0046a370 | Z02 §6.5 (FUN_00461ee0 / FUN_00462040 cited), Z14 (fldb_GetFieldLv) (done) | instance / NPC-gate entry checks, not reached from §6.2 |
| `BriefInfoExchanger::*_Exchange` | Z18 §2.1 (done) | brief-info batch |
| `so_ply_EndofTrade` FUN_004c4b50 body, `NPCManager::nm_UnmarkNPC` FUN_004c6ad0 | Z02 §6.2 (`sp_EndOfTrade`) / Z01 §9 (done) | NPC dialog close and schedule |
| `Raid::*`, `RaidSystem::*`, `RaidTask::rt_*` | Z14 §5 (done) | raid library |
| `CParty::MemberJoin` / `CreateRaidParty` / `MemberLeave` | Z08 §1, Z14 §5 (done) | party library |
| `GuildStorageManager::gsm_FindStorage` and friends | Z14 §3 (done) | guild storage |
| TERMEXTEND `0x34B7` / `0x34B8` | Z04 §12.9, Z05 §8.5 (done) | handler and DB answer |
| `CMoverUpgradeData` tables (RareMoverRate / SubRate / Info) | Z13 §7.1 (done) | table loading |
| `WeddingHall::wh_Reserv`, `ShineDateTime::operator+=(ShineDateTimeSpan)` FUN_0059ead0 | Z07 §12 open point (done item; "wh_Reserv internals: not reconstructed") | not reached from Z30's functions; a wedding-hall question, not a leftover of the coverage list. Small; noted here: `wh_Reserv` sets EnteringStart = now + span 0x14000000, EnteringEnd = +0x5000000, WeddingEnd = +0xa000000 (ShineDateTimeSpan {u16 date, u8 hour, u8 minute}: +20 min, +5 min, +10 min) |
