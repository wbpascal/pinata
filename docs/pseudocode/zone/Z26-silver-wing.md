# Zone: silver-wing teleport item (Z26)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`. Read the code with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …` (official names and types, *(pdb2016)*), byte
offsets with `re-data/exports/zone`. Client: `Files/Client/2016/Fiesta.bin` (`re-data/exports/client`). Evidence markers as in
`AGENTS.md`: *(pdb2016)* NA2016 server PDB (same build), *(pdb2017)* 2017 client PDB, *(inferred)* deduced. Layouts:
`docs/protocol/annotations/Z26.json`.

The Silver Wing is a reusable premium teleport item: using it opens a server menu with "Save location" and, once a
location is saved in the item, "Fly to the saved location". Saving writes the current map and position into the item's
attribute (DB 0x3449); flying starts an item cast of the pseudo-skill `UseSilverWings` whose end links the player to the
saved place. The item is never consumed; a 60-minute cooldown limits it (a premium effect `EE_SILVERWINGCOOLTIME` could
shorten it, but no 2016 `ChargedEffect` row carries it, §1.1). A second, unintended entry (0x304E, §5.5) skips menu and cast.

Neighbouring items (not redone here): the item-use framework and 0x3015 (Z04 §6), the cast routine and `smo_ply_ItemUse`
(summarised in Z13 §9.4, the Minimon auto-use section), cooldowns and Z23-B5 (Z23 §3.2 / §3.6), server menus and 0x3C02 (Z02 §6.6), the link
`so_LinkTo` (Z01 §7.1), the DB attribute change answer 0x344A (Z05 §5.4) and its Character-server side (D03 §4: 0x3449
`FUN_0040e630` → `ItemAttr_Save`, BindItem storage table in D03 §1.3), the loaders of the tables in §1.1 (Z24 §2, Z27).

## 1. Data

### 1.1 The item, its actor and its pseudo-skill

| What | Value | Where |
|---|---|---|
| Item | `ItemInfo` row ID **2504** `SilverWings` "Silver Wing": Type 1 (consumable / EXH), Class **13** (`ITEMCLASS_BINDITEM`, the same attribute class as the Wing of Z01 §7.2), MaxLot 1, UseSkill `UseSilverWings` | `ItemInfo.shn` |
| `itemdatabox.idb_specialid.sii_silverwing` (DAT_14d5048c) | the ID of the `InxName` "SilverWings" row (2504) | set by `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| Actor | `UseEffect::UseItemSilverWing` (size 4, base `UseItemBase`), the static `ui_silverwing` (constructed by `dynamic_initializer_for_'ui_silverwing'` FUN_006990e0, reset to the base vftable by the atexit destructor FUN_0069f4f0) | registered for `ItemUseFunction` "UseSilverWings" by `ItemUseFunction::iuf_Load` FUN_0049b770 (Z24 §2) |
| Actor slots | +4 `uib_CanUseItem` FUN_00598000, +8 `uib_DirectUse` FUN_0059c260, +0xc `uib_AfterCast` FUN_0053ff70, +0x10 `uib_Effect` = base no-op (never reached: nothing is consumed) | §3, §5.3 |
| Pseudo-skill | `ActiveSkill` 29200 = **0x7210** `UseSilverWings` "Use Silver Wing": **CastTime 0**, DlyTime 3 600 000 ms (only stored, §5.1), DlyTimeGroup 0 | `ActiveSkill.shn` (server and client rows agree) |
| Skill special | the row's SpecialIndexA = **19 `SS_SILVERWING`**, SpecialValueA 0 (the only `ActiveSkill` row using index 19): `SkillDataIndex::sdi_SetArgument` FUN_00584800 sets `sdi_SILVERWING = { exist 1, value 0 }` (cleared by `sdi_Clear` FUN_00584500, Z20 §4). **No 2016 zone code reads `sdi_SILVERWING`**: the silver-wing special cases test the item ID (`sii_silverwing`, §5.1) or the skill ID 0x7210 (§5.2) | `ActiveSkill.shn`, Z20 §4 |
| Cooldown | `so_ply_SilverWingCoolTime()` (vt 0x3d8, FUN_005596b0) = `sp_ChargedItem.ci_Effect.cec_SilverWingCoolTime_Minute · 60 000` ms; template value 60 (`so_Initstaticvar` FUN_00549530), lowered to min(cur, EffectValue) by a charged effect `EE_SILVERWINGCOOLTIME` (0) in `ciee_Activ` FUN_00450550. **No 2016 `ChargedEffect` row carries EE 0**, so with the 2016 data the cooldown is always 60 min | Z23 §3.6, Z24 §6.7 |

### 1.2 Saved location: the item attribute

The attribute is `ShineItemAttr_BindItem { u8 portalnum; Bind portal[10] }` with `Bind { u16 mapid; u32 x; u32 y }`
*(pdb2016)*. In the Character DB (D03 §1.3, class 13 row) it is stored as option rows: 1100 = portalnum, then per portal n
(0…9) 1110+10n = u16 map, +1 = u32 x, +2 = u32 y; `ItemAttr_Save` writes them on 0x3449 (D03 §4, FUN_0040e630). The silver
wing uses only the first entry and `portalnum` as the "location saved" flag. Offsets in the item
cell / `ItemTotalInformation` (key +0, `itemid` +8, attribute from +0xa):

| Cell offset | Field | Meaning |
|---|---|---|
| +0x0a | `portalnum` | 0 = nothing saved (new item); `sp_silverwing_Setloc` writes **1**; `sp_SilverWingMenu` shows the portal entry when ≠ 0 |
| +0x0b | `portal[0].mapid` | `MapInfo` index of the map where the location was saved (`mapdatabox.mdb_btree[fieldName]`), **0xFFFF** if the field's name is not in `MapInfo` |
| +0x0d | `portal[0].x` | u32 position x at the save |
| +0x11 | `portal[0].y` | u32 position y |
| +0x15 … | `portal[1..9]` | untouched |

The PDB view of the code names these bytes through other union members (`amulet.deletetime.year`, `furniture.furnicherID`,
`weapon.IsPutOnBelonged`, `armor.deletetime`); the byte offsets above are what the code reads and writes.

### 1.3 Menu argument

`ServerMenuArgument::SilverWingSet { ITEM_INVEN inven }` *(pdb2016)*, the first u16 of the 0x68-byte argument; all three
menu entries carry `inven = 0x2400 | (slot & 0x3ff)` (type 9 = main inventory; the other 0x66 bytes are uninitialised stack
and never read). The callbacks read only `inven & 0x3ff`.

### 1.4 Cast fields used (`smo_SkillCast`, p+0x1d84, `SkillCastStruct` *(pdb2016)*, Z03 §5.1)

| Offset | Member | Silver-wing value |
|---|---|---|
| +0x1d84 | `scs_BlastTime` | `CastTime·10/1000 + clockwatch.cw_CurrTick` (CastTime 0 → the current tick: the cast ends at the next `so_Routine`) |
| +0x1d88 | `scs_Skill` | `ActiveSkill.ID` of the item's use skill (0x7210) |
| +0x1d98 | `scs_ProduceSkill.sklidx` | the use skill's `SkillDataIndex` (non-null = "a cast is running" for `so_Routine`) |
| +0x1da0 | `scs_UseItem.cooltime_millisec` | `ActiveSkill.DlyTime` (ignored for the silver wing, §5.1) |
| +0x1da4 | `scs_UseItem.itemdata` | `ItemDataBox[itemid]` of the cell |
| +0x1da8 | `scs_UseItem.invenslot` | low byte of the menu's `inven` (= slot) |
| +0x1da9 | `scs_UseItem.bAutoUse` | 0 (player use: `smo_ply_ItemUse` sends 0x301A) |

## 2. Flow

```pseudo
client 0x3015 NC_ITEM_USE_REQ { invenslot, invenType 9 }        (Z04 §6.1: mode, field CanItem, level, class, lot … checks)
  sp_NC_ITEM_USE_REQ FUN_005416b0: sp_LastUsedItem = 2504
  └ sp_ItemUseReq_Inven FUN_0053f5e0 (Z04's "ItemUse_Inventory")
      ├ uib_CanUseItem (§3.1)       ≠ 0x700 → 0x3016 {0x70F} (+ 0x181D, 0x2011 notice)
      └ uib_DirectUse (§3.2) → sp_SilverWingMenu → 0x3C01 menu; returns "handled": no 0x3016 now, no cooldown check
client 0x3C02 NC_MENU_SERVERMENU_ACK { reply }                    (Z02 §6.6: mode ∈ {1,2,3,6}, ≤ 1000 units from the opening point)
  ├ "Save location"   → sp_silverwing_Setloc (§4.1) → DB 0x3449 ITEMCHANGE_REQ, 0x3016 {0x700}
  ├ "Fly …"           → sp_SilverWing_PortalCast (§4.2) → item cast (no packet) or 0x3016 {0x70D}
  └ "Cancel"          → sp_silverwing_Cancel + smfm_Cancel (§4.3) → 0x3016 {0x700}
next so_Routine tick (§5.1): cooldown 0x7210 started, 0x4821 (ms, Z23-B5)
  └ smo_ply_ItemUse (§5.2): uib_CanUseItem again; 0x301A; no 0x3029 broadcast (BroadCast 0); 0x4821 (s)
      └ uib_AfterCast (§5.3) → sp_SilverWing_PortalBlast (§5.4): 0x301A, 0x3016 {0x700}, so_LinkTo(saved map, x, y) → 0x1809 or WM 0x180D
crafted 0x304E NC_ITEM_USE_ACTIVESKILL_REQ on the slot (§5.5): uib_AfterCast at once → blast and link, then a skill cast
```

## 3. Using the item (0x3015 → actor)

### 3.1 uib_CanUseItem

```pseudo
UseItemSilverWing::uib_CanUseItem(actor, p, cell) → code                       @ FUN_00598000
    if !p.so_ply_IsLink_OutMap_AndSendErrorMsg()        (vt 0xa74, FUN_005603d0; Z16 §2.3)
        # no field: false silently; FieldAttr.LinkOut (+0x6c) == 0: p ← 0x181D NC_MAP_LINK_FAIL_CMD { u16 0x1E42 };
        # FieldAttr.SystemMap (+0x6d) == 1: p ← 0x181D { 0x1E41 }
        p.so_ply_Notice(ScrString ETC "RecallDisableField")   (vt 0x784, FUN_005977e0)
            → 0x2011 NC_ACT_NOTICE_CMD "This location is not accessible via Warping."
        return 0x70F
    return 0x700
```

Called twice per flight: by `ItemUse_Inventory` before the menu (Z04 §6.1) and by `smo_ply_ItemUse` at the end of the
cast (§5.2); a non-0x700 code is answered there as `0x3016 { code }`. It does **not** look at the item, the saved map or
the cooldown. Client: 0x181D shows TextData2 0x35ac8487 (a blank line) for 0x1E41 / 0x1E42 (`On_NC_MAP_LINK_FAIL_CMD`
FUN_004b0e70); 0x2011 is shown as "[Notice] …" (`On_NC_ACT_NOTICE_CMD` FUN_004b5420, Z09 annotation); 0x3016 0x70F is
**ignored** by `On_NC_ITEM_USE_ACK` FUN_004abdb0 (silent codes 0x70A, 0x70E, 0x70F, 0x10C4), so the notice is the only text.

### 3.2 uib_DirectUse → sp_SilverWingMenu

```pseudo
UseItemSilverWing::uib_DirectUse(actor, p, slot, cell) → 1                      @ FUN_0059c260
    sp_SilverWingMenu(p, slot, cell); return 1            # always "handled": ItemUse_Inventory returns without a reply

ShinePlayer::sp_SilverWingMenu(p, slot, cell)                                  @ FUN_0059c090
    if !servermenuactor.sma_IsReady() (FUN_0050ec90: a menu with entries is open) or p.sp_tradeboard.tb_opposit (+0x17d5f) ≠ null:
        return                                            # nothing sent: (original bug) Z26-B1
    sp_NPCProcess.npchandle (+0x17d7c) = 0xFFFF; sp_NPCProcess.npc (+0x17d80) = null      # not an NPC menu
    servermenuactor.x, y (+0x17d90 / +0x17d94) = p.position
    arg = SilverWingSet { inven = 0x2400 | slot }         (§1.3; one copy per entry)
    sp_ServerMenuTitle(ScrString MenuString "SilverWingTitle" = "Use silver wings")       @ FUN_0054e8a0
        # starts 0x3C01 in the send buffer, sma_Clear (FUN_0050f660: 10 slots and the reset callback = no-op,
        # sma_bRangeCheck = 1, count 0), sp_MiscFlag.BeSummoned = 0
    if cell.portalnum (+0x0a) ≠ 0:
        sp_ServerMenuItem(smfm_Silverwing_Portal, "SilverWingPortal" = "Fly to the saved location", arg)   @ FUN_0054e990
    sp_ServerMenuItem(smfm_Silverwing_LocSet, "SilverWingLocSet" = "Save location", arg)
    sp_ServerMenuItem(smfm_Silverwing_Cancel, ScrString ETC "Cancel" = "Cancel", arg)
        # each item: SERVERMENU { u8 reply = index, char string[32] }, sma_Regist (FUN_0050f710) copies (callback, arg)
    sp_ServerMenuOpen(priority 0, npcHandle 0xFFFF, pos null → p.position, limitRange 1000)               @ FUN_0054eaa0
        → p ← 0x3C01 NC_MENU_SERVERMENU_REQ (§6); actor x, y = p.position again
```

Reply indices: with a saved location 0 = fly, 1 = save, 2 = cancel; without, 0 = save, 1 = cancel. Nothing is locked: the
item can be moved, swapped or used otherwise while the menu is open (see Z26-B5). The cooldown is not checked here, so the
menu (and "Save location") works during the cooldown. When the menu ends without one of its three callbacks running
(§4.4: the 0x3C02 range or mode check fails, a reply index without an entry, another menu replaces it, a map change), the
item use is never answered: (original bug) Z26-B1.

## 4. Menu replies (0x3C02 → `ServerMenuActor::sma_Reply`, Z02 §6.6)

### 4.1 Save location

```pseudo
ServerMenuFuncter::smfm_Silverwing_LocSet(f, p, arg)                           @ FUN_0059bff0
    sp_silverwing_Setloc(p, &arg.inven)

ShinePlayer::sp_silverwing_Setloc(p, inven)                                   @ FUN_0059bc80
    cell = p.inventory (p+0x8e2c) .vt[0](inven & 0x3ff)
    if cell.itemid ≠ sii_silverwing:
        assert "ShinePlayer::sp_silverwing_Setloc : wrong item"; p.so_ply_ItemUseResultPacket(0x703, 9); return
    field = p.so_Field (+0x7a)
    if field == null:                         code = 0x70F
    elif field.fm_FieldOption.LinkIn (+0xc → +0x6b) == 0:     # the map cannot be a link destination
        p.so_ply_ItemUseResultPacket(0x70F, 9); return
    else:
        copy = cell (0x6f bytes, ItemTotalInformation)
        copy.portalnum = 1
        copy.portal[0].mapid = mapdatabox.mdb_btree[NameString(field.fm_MapID)] (−1 → 0xFFFF)
        copy.portal[0].x, y = p.so_LocateInfo.location (+0x66) x, y
        sp_AttrChange2DB(p, cell, cell.attrClass (+0x70), &copy, inven)        # below
        code = 0x700
    p.so_ply_ItemUseResultPacket(code, 9)    → 0x3016 { code, useditem = sp_LastUsedItem, 9 }
    # 0x70F has no client text and no notice: (original bug) Z26-B2

ShinePlayer::sp_AttrChange2DB(p, cell, attrClass, &copy, inven)               @ FUN_005979b0
    GameDB (sock2gameDB.sb_GetSocket) ← 0x3449 NC_ITEMDB_ITEMCHANGE_REQ {
        +0  u16 objHandle (p+4)  +2 u32 charNo (vt 0x344)    # NETPACKETZONEHEADER (ref)
        +6  u16 lockindex = InventoryLocking index (p.sp_Item.invenlocklist)
        +8  u64 itemkey = copy.iti_registnum
        +0x10 SHINE_ITEM_STRUCT { u16 itemid, attribute[attrClass.vt[0xc](attr) bytes] } }  # class 13: 0x65 bytes
    # wire size 0x12 + attribute size (the code passes attrSize + 0x14 incl. the opcode); too long → assert "Packet Too Long", not sent
    invenlocklist.vt[0x40](lock, cell, &copy, inven, inven)   # reserve the changed copy (Z04 §1.4)
    lock += 1
    # the attribute takes effect only when GameDB answers 0x344A ITEMCHANGE_ACK err 0x901 → Apply (Z05 §5.4)
```

`sp_LastUsedItem` (p+0x2a7c6) still holds 2504 from the 0x3015 (no 0x3016 was sent in between), so the reply names the
silver wing; `so_ply_ItemUseResultPacket` FUN_0045e610 resets it to 0xFFFF.

### 4.2 Fly: the portal cast

```pseudo
ServerMenuFuncter::smfm_Silverwing_Portal(f, p, arg)                           @ FUN_0059bbe0
    sp_SilverWing_PortalCast(p, &arg.inven)

ShinePlayer::sp_SilverWing_PortalCast(p, inven)                               @ FUN_00597b30
    cell = p.inventory.vt[0](inven & 0x3ff)                 # not checked against sii_silverwing: (original bug) Z26-B5
    e = useditemeffect.uie_FuncStruct[cell.itemid] (entry 0 if itemid ≥ uie_MaxItemID)
    skill = e.useskill
    if e == null or skill == null or skill.sdi_ServInf == null:  p.so_ply_ItemUseResultPacket(0x70D, 9); return
    if !CharaterSkillList::csl_CoolTimeCheck(p.sp_SkillList, p, skill.sdi_ServInf.ID)  (FUN_0046a420, Z23 §3.6):
        p.so_ply_ItemUseResultPacket(0x70D, 9); return         # "Cannot use the item yet." (cooling down or not learned)
    info = ItemDataBox[cell.itemid]
    SkillCastStruct::scs_Clear(&p.smo_SkillCast)              (FUN_005691f0)
    smo_SkillCast = { scs_BlastTime = skill.sdi_Activ.CastTime·10/1000 + g_Now, scs_Skill = sdi_Activ.ID,
                      sklidx = skill, itemdata = info, invenslot = (u8)inven, bAutoUse = 0,
                      cooltime_millisec = sdi_Activ.DlyTime }   (§1.4)
    # no packet: the client learns of the use only at the end (0x301A, 0x3016)
```

No mode, fear, captivation, "already casting" (vt 0xea0) or field check here (0x3C02 only requires mode ∈ {1,2,3,6}): a
running skill cast is replaced by the item cast (original bug) Z26-B5. Client: 0x70D shows "Cannot use the item yet."
(TextData 0x85f7d6d1). The 0x3019 USEABORT (Z04 §6.2) and the cast abort of `so_Routine` (§5.1) apply to this cast as to
any item cast.

### 4.3 Cancel

```pseudo
ServerMenuFuncter::smfm_Silverwing_Cancel(f, p, arg)                           @ FUN_0059bb30
    sp_silverwing_Cancel(p, &arg.inven)     @ FUN_00597900: p.so_ply_ItemUseResultPacket(0x700, 9)   # closes the client's item use
    smfm_Cancel(f, p, arg)                  @ FUN_0050ecc0: sp_EndOfTrade(p, 1); sp_MiscFlag.BeSummoned = 0
```

### 4.4 Menu end without a silver-wing callback

The generic machinery (Z02 §6.6, which names `sma_Clear` "sma_Reset" and `sma_Reset` "sma_Reset_new") matters here because
the item use stays unanswered whenever none of §4.1–§4.3 runs:

```pseudo
ShinePlayer::sp_NC_MENU_SERVERMENU_ACK(p, { u8 reply })                        @ FUN_0050fe60   (Z02 §6.6)
    if mode ∉ cmc_AllowMode 0x4e = {1,2,3,6}: BeSummoned = 0; sma_Reset(actor); return
    tooFar = actor.sma_bRangeCheck == 1 and dist²(p.position, actor.x/y) > 1 000 000      # silver wing: check on (sma_Clear default)
    if BeSummoned == 0 and tooFar: BeSummoned = 0; sma_Reset(actor); return
    sma_Reply(actor, p, reply)

ServerMenuActor::sma_Reply(actor, p, i)                                         @ FUN_0050fd40
    if i ≥ 10: assert "ServerMenuActor::sma_Reply : Too many regist"; BeSummoned = 0; sma_Reset(actor); return
    (cb, arg) = sma_Selected[i]; sma_Clear(actor); cb(p, arg)
        # i ≥ menunum (e.g. 2 when no location is saved) → the default no-op cb (CGambleObject::go_SMC_WinRank,
        # FUN_00509900, an empty `return;`; the PDB name is one of several sharing it (identical-code folding, *(inferred)*)): nothing answered (Z26-B1); a 0x3C02 with no menu open does the same

ServerMenuActor::sma_Reset(actor)                                               @ FUN_0050fc00
    if actor.sma_pPlayer ≠ null and actor.sma_Subst ≠ 0 (entries registered):
        sma_ResetFuction.smfunction(player, copy of sma_ResetFuction.smargument (0x68 bytes))
        player ← 0x3C0F NC_MENU_SERVERMENU_CLOSE_CMD (2-byte packet; too long → assert "ServerMenuActor::sma_Reset : Packet Too Long")
    sma_Clear(actor)                                                            @ FUN_0050f660
        # 10 slots and sma_ResetFuction ← the no-op, sma_bRangeCheck = 1, sma_Subst = 0

ShinePlayer::sp_ServerMenu_SetReserFunction(p, cb, arg)                        @ FUN_00549b30   (sic, official name)
    ServerMenuActor::sma_SetResetFuction(actor, cb, arg)                        @ FUN_0050f800
        if cb ≠ null and arg ≠ null: sma_ResetFuction = { smargument = *arg (0x68 bytes), smfunction = cb }
```

Ways the silver-wing menu ends without a callback of its own:

| Trigger | Path | Client sees |
|---|---|---|
| reply while mode ∉ {1,2,3,6} or > 1000 units from where the menu opened | `sma_Reset` from FUN_0050fe60 → no-op reset callback | 0x3C0F (menu closed) |
| reply index ≥ 10 | `sma_Reset` from `sma_Reply` | 0x3C0F |
| reply index from `menunum` (2 or 3) to 9 | default slot no-op | nothing |
| map change | `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 calls `sma_Reset` (Z01) | 0x3C0F |
| another server menu opens (its `sp_ServerMenuTitle` → `sma_Clear`) | slots overwritten silently | the new 0x3C01 |

`sp_EndOfTrade` (FUN_004c25b0, Z02 §6.4; also called by `smfm_Cancel`, §4.3) resets the menu only when `sp_NPCProcess.npc`
≠ null; the silver-wing menu sets it to null (§3.2), so 0x200B and the Cancel path never call `sma_Reset` for it. The only
caller of `sp_ServerMenu_SetReserFunction` is the item drop/destroy menu `ItemMenu_Open` FUN_0048ced0 (Z04 §1.5, which also
turns the range check off with `sma_SetRangeCheck(0)`); the silver wing never registers a reset callback.

## 5. Cast end and blast

### 5.1 ShineMobileObject::so_Routine, item branch @ FUN_0056a080

```pseudo
    # each tick while scs_BlastTime ≠ 0 and sklidx ≠ null (Z13 §9.4):
    before scs_BlastTime: if IsNoAttack (Parameter container) or smo_SkillBlastOption == SB_SILENCE: vt 0xed4 smo_CastAbort
    at/after scs_BlastTime: vt 0xef8 smo_ply_SetItemEffect(sdi_Activ.ID)       (FUN_00510d20)
        scs_UseItem.itemdata ≠ null:
            if itemdata.ID == sii_silverwing:
                ms = p.so_ply_SilverWingCoolTime()                                  (vt 0x3d8)
                p.smo_ply_SkillCoolTime(scs_Skill, ms, 0, 0, 0)                     (vt 0xeac, Z23 §3.2)
                p.so_ply_NewSkillCoolTime(scs_Skill, ms)  (vt 0x374) → 0x4821 { 0x7210, sec = ms }   # Z23-B5
            else: smo_ply_SkillCoolTime(scs_Skill, cooltime_millisec, 0, 0, 0)
            p.smo_ply_ItemUse(itemdata, invenslot, bAutoUse)                        (vt 0xed0, §5.2)
            scs_BlastTime = 0; vt 0xf00 smo_SetEffectForJustSkillClear              (FUN_005102a0)
```

The cooldown is started **before** the item is re-checked and before the blast, so every later failure (§5.2–§5.4) still
costs the full cooldown: (original bug) Z26-B3.

### 5.2 smo_ply_ItemUse (shared, Z13 §9.4) @ FUN_0053fd10

```pseudo
    cell = inventory[invenslot]; item data of cell.itemid missing → return; data.ID ≠ cell.itemid → assert
    lot < 1 → assert, 0x3016 { 0x703 }
    actor = useditemeffect[cell.itemid].useitemclass        # the actor of the item in the slot NOW
    code = actor.uib_CanUseItem(p, cell); ≠ 0x700 → 0x3016 { code }; return     # silver wing: §3.1 again
    if bAutoUse == 0: p ← 0x301A NC_ITEM_USECOMPLETE_CMD (so_SendProtocol 12/0x1a, no payload)
    sp_ItemUseBroadcast(p, entry, itemid)  (FUN_0053f840, Z24 §1.4): returns at once when entry.broadcast == 0, and the
        `World/ItemUseFunction.txt` row `SilverWings` has BroadCast 0 → no 0x3029 NC_ITEM_SOMEONEUSE_CMD for the silver wing
    if scs_Skill == 0x7210: p.so_ply_NewSkillCoolTime(0x7210, so_ply_SilverWingCoolTime() / 1000) → 0x4821 { 0x7210, sec }
    actor.uib_AfterCast(p, inventory, itemdata, invenslot)          (§5.3)
    field Lua script: event 0x20 ItemUse (field, p, itemid)          # runs after the link of §5.4 (see §8)
```

### 5.3 uib_AfterCast

```pseudo
UseItemSilverWing::uib_AfterCast(actor, p, box, itemdata, slot)                 @ FUN_0053ff70
    cell = box.vt[0](slot)
    if cell.itemid ≠ itemdata.ID:
        assert "UseEffect::UseItemSilverWing::uib_AfterCast : Item Changed"; p.so_ply_ItemUseResultPacket(0x702, 9); return
    sp_SilverWing_PortalBlast(p, &(0x2400 | slot))
    # nothing is consumed: no 0x343E / 0x343F, uib_Effect never runs
```

0x702 shows "You cannot use this" (TextData2 0xd6370f38). The cooldown of §5.1 is already running.

### 5.4 sp_SilverWing_PortalBlast: the link

```pseudo
ShinePlayer::sp_SilverWing_PortalBlast(p, inven)                              @ FUN_00597cf0
    cell = p.inventory.vt[0](inven & 0x3ff)
    if cell.itemid ≠ sii_silverwing:
        assert "ShinePlayer::sp_silverwing_Setloc : wrong item" (the Setloc string, sic); return      # no reply: Z26-B4
    m = cell.portal[0].mapid
    if m ≥ mapdatabox.mdb_maxmapid or mapdatabox.mdb_index[m] == null: return      # nothing sent: (original bug) Z26-B4
    info = mdb_index[m]
    link = NPCManager::LinkInformTemplete (0x61 bytes, stack) {
        +0x00 index[20]       uninitialised (so_LinkTo never reads it)
        +0x14 linktoserver    = info.MapName (Name3, 12 chars, via the NameString ring buffer)
        +0x35 linktoclient    = info.MapName
        +0x56 coordx          = cell.portal[0].x
        +0x5a coordy          = cell.portal[0].y
        +0x5e direct, +0x60 Party   uninitialised (not read by so_LinkTo) }
    p.so_SendProtocol(12, 0x1a)          (vt 0x304, FUN_0054ef70) → 0x301A again   (original bug) Z26-B6
    p.so_ply_ItemUseResultPacket(0x700, 9)  → 0x3016 { 0x700, sp_LastUsedItem, 9 }
    p.so_LinkTo(&link, 6, 9, 10)         (vt 0x600, FUN_0049ad30, Z01 §7.1)
        # same zone → 0x1809 NC_MAP_LINKSAME_CMD { u16 mapIndex, u32 x, u32 y }; other zone → WM 0x180D, later 0x180A
        # its refusals (mode ∉ {1,2,6}, trade partner, locked inventory, unknown zone) are silent: (original bug) Z26-B3
```

The destination is not checked: neither `LinkIn` of the saved map now (only at the save), nor `portalnum` (a fresh item
links to `MapInfo` index 0 when reached through §5.5), nor the field level window of `FieldLvCondition.shn` (`LvFrom`–`LvTo`,
Z14), nor kingdom-quest or instance state. The save-time `LinkIn` test keeps most instance / KQ maps out; a map with
`LinkIn` ≠ 0 and an `LvTo` upper bound would let a player who saved there below `LvTo` return after out-levelling it:
(original bug) Z26-B9 *(inferred: no 2016 map was checked for that combination)*. `sp_LastUsedItem` at the blast is 2504 only if no other 0x3016 was sent since the 0x3015 (a Cancel/LocSet
reply or another item use in between leaves 0xFFFF or another item's ID; the client's `On_NC_ITEM_USE_ACK` 0x700 branch only
uses `useditem` for mount, feed and item-0x7578 extras, so the silver wing is unaffected).

### 5.5 Unintended entry: 0x304E NC_ITEM_USE_ACTIVESKILL_REQ @ FUN_00540b90

`sp_NC_ITEM_USE_ACTIVESKILL_REQ` (Z04 §12.7, which describes it as a generic skill-item cast) is the second caller of the
actor slot +0xc (`uib_AfterCast`); the first is `smo_ply_ItemUse` (§5.2). It never calls `uib_CanUseItem` or
`uib_DirectUse` and does not check the item class (Z04's "class 35" is what the client sends, not a server test):

```pseudo
    checks of Z04 §12.7: mode, field CanItem (+0x9e), exclusive states, inventory locks, SB_SILENCE, slot, DemandLv,
        1 ≤ lot ≤ MaxLot, KQ map + PK_KQ_USE, useditemeffect[itemid].useskill present (0x7210 for the silver wing),
        move state 3 with CastTime ≠ 0 (not the case here), csl_CoolTimeCheck(0x7210) → 0x304F { 0x3129 } while cooling down
    sp_LastUsedItem = itemid
    target 0xFFFF (ground): TargetLoc reachable (so_FindBlockLocate) and within AttackDist + body size; the player's own
        position passes both
    actor.uib_AfterCast(p, inventory, itemdata, slot)      # silver wing: §5.3 → sp_SilverWing_PortalBlast → so_LinkTo NOW
    vt 0xef8 smo_ply_SetItemEffect(0x7210); vt 0x8d0
    smo_SkillBash_Casting(p, skill 0x7210, null, &TargetLoc, −1)   # Z03 §5.4: 0x2450 to p, 0x2451 to sight, CastTime 0
    p ← 0x304F NC_ITEM_USE_ACTIVESKILL_ACK { 0x3128 }
```

So a crafted 0x304E on the silver-wing slot teleports at once: no menu, no item cast, **no `so_ply_IsLink_OutMap…` test**
(only `uib_CanUseItem` does it, §3.1), so `LinkOut` / SystemMap maps can be left; with nothing saved (`portalnum` 0) the
blast uses map 0 (`Rou`) at the stored x/y (0/0 for a fresh attribute *(inferred)*). The 0x301A / 0x3016 0x700 of the
blast are sent, then a skill cast of 0x7210 starts on the already-linked player; its cooldown is set by the generic skill
path (DlyTime 3 600 000 ms) rather than `so_ply_SilverWingCoolTime` *(inferred, cast end not traced for this case)*:
(original bug) Z26-B7. The official client only sends 0x304E for its skill-cast items, so this needs a modified client.

## 6. Packets and client handlers

| Opcode | Dir | Layout | Client |
|---|---|---|---|
| 0x3015 NC_ITEM_USE_REQ | C→Z | `{ u8 invenslot, u8 invenType }` (Z04 §6.1) | `ItemUseTask` start FUN_006a2b30: the use skill `UseSilverWings` (and `UseRide`) skip the client's own cooldown test `Skill::IsSkillUsePossible`; CastTime 0 → task state 3 (no cast bar) |
| 0x3016 NC_ITEM_USE_ACK | Z→C | `{ u16 error, u16 useditem, u8 invenType }` (Z04 annotation) | `On_NC_ITEM_USE_ACK` FUN_004abdb0 + `ItemUseTask::OnProcessNetMsg` FUN_006a2750 (task ends, state 2). Codes here: 0x700 ok, 0x702 "You cannot use this", 0x703 no client text, 0x70D "Cannot use the item yet.", 0x70F silent |
| 0x301A NC_ITEM_USECOMPLETE_CMD | Z→C | no payload (2-byte packet) | `ItemUseTask::OnProcessNetMsg`: first one in state 3/4 → `Skill::RecordSkillUse(useskill)` (cooldown icon; 4 also `CastingSuccess`), then a flag (+0x48) ignores the second |
| 0x3C01 NC_MENU_SERVERMENU_REQ | Z→C | `{ char title[128], u8 priority = 0, u16 npcHandle = 0xFFFF, u32 x, u32 y (player), u16 limitRange = 1000, u8 menunum (2 or 3), SERVERMENU { u8 reply, char string[32] }[menunum] }` (0x8e + 0x21·n) *(pdb2017 struct, confirmed by the offsets in FUN_0054e8a0 / 0054e990 / 0054eaa0)* | `GameFrameWork` FUN_0049a950 (Z02) |
| 0x3C02 NC_MENU_SERVERMENU_ACK | C→Z | `{ u8 reply }` (Z02 §6.6) | – |
| 0x3C0F NC_MENU_SERVERMENU_CLOSE_CMD | Z→C | empty, when the menu is reset without a reply (Z02) | FUN_008b80a0 |
| 0x181D NC_MAP_LINK_FAIL_CMD | Z→C | `{ u16 err }` 0x1E41 / 0x1E42 | FUN_004b0e70: TextData2 0x35ac8487 (blank) |
| 0x2011 NC_ACT_NOTICE_CMD | Z→C | `{ u8 unk (not written, Z09-B54), u8 len, char text[len] }` | FUN_004b5420 "[Notice] %s" |
| 0x4821 NC_SKILL_COOLTIME_CMD | Z→C | `{ u16 skill, u32 sec }` (Z03; ms first, Z23-B5) | FUN_0049a9e0 |
| 0x3449 NC_ITEMDB_ITEMCHANGE_REQ | Z→GameDB | §4.1 (`PROTO_NC_ITEMDB_ITEMCHANGE_REQ` *(pdb2016)*) | – (Character server FUN_0040e630 → `ItemAttr_Save`, answer 0x344A err 0x901 ok / 0x902 failed, D03 §4; zone side Z05 §5.4) |
| 0x304E / 0x304F NC_ITEM_USE_ACTIVESKILL_REQ / ACK | C→Z / Z→C | Z04 §12.7 | only reached by a crafted request (§5.5); 0x304F codes in Z04 §12.7 |
| 0x3029 NC_ITEM_SOMEONEUSE_CMD | Z→sight | Z24 §1.4 | **never sent** for the silver wing (BroadCast 0, §5.2) |
| 0x1809 / 0x180D | Z→C / Z→WM | Z01 §7.1 | Z01 |

## 7. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z26-B1 | `sp_SilverWingMenu` FUN_0059c090 / menu end (§4.4) | refused silently while another menu is open or a trade partner is set, yet `uib_DirectUse` returns "handled"; a menu that ends without one of its callbacks (0x3C02 range/mode check, reply index without an entry, map change, replaced by another menu) runs only the no-op default | the 0x3015 never gets its 0x3016: the client's `ItemUseTask` stays open *(inferred effect)* | answer 0x3016 (e.g. 0x701) when refusing; register `smfm_Silverwing_Cancel` with `sp_ServerMenu_SetReserFunction` FUN_00549b30 after `sp_ServerMenuOpen`, as the item drop/destroy menu does (Z04 §1.5) |
| Z26-B2 | `sp_silverwing_Setloc` FUN_0059bc80 | "map cannot be saved" (no field / `LinkIn` == 0) answers only 0x3016 0x70F, which the client ignores | the player gets no message; the save just does not happen | send the "RecallDisableField" notice as `uib_CanUseItem` does, or a code with a text |
| Z26-B3 | `so_Routine` FUN_0056a080 → `smo_ply_ItemUse` → `sp_SilverWing_PortalBlast` | the 60-min cooldown starts before the re-check, the item check and the link; 0x3016 0x700 is sent before `so_LinkTo`, whose refusals are silent | a failed flight (item moved, map now forbids leaving, invalid saved map, trade/locked inventory/dead) still costs the full cooldown, sometimes after a "success" | start the cooldown and send 0x700 only after the link was accepted |
| Z26-B4 | `sp_SilverWing_PortalBlast` FUN_00597cf0 | an invalid saved map (`mapid` 0xFFFF from a field missing in `MapInfo`, or ≥ `mdb_maxmapid`) or a wrong item returns without any packet; the wrong-item assert text names `sp_silverwing_Setloc` | no 0x3016 for the use, cooldown spent (B3); misleading log | answer 0x3016 with an error; refuse saving when the map id is unknown |
| Z26-B5 | `sp_SilverWing_PortalCast` FUN_00597b30 | uses whatever item is in the slot at the reply: its use skill, cooldown and actor; no Type/level/class/field `CanItem`/fear/"already casting" checks | an item swapped into the slot while the menu is open is cast and used through `smo_ply_ItemUse` without the 0x3015 checks *(inferred: needs a 0x300B move while the menu is open)*; a running skill cast is overwritten | check `itemid == sii_silverwing` and the 0x3015 state checks before casting |
| Z26-B6 | `sp_SilverWing_PortalBlast` FUN_00597cf0 | sends 0x301A although `smo_ply_ItemUse` just sent it | harmless: the client's `ItemUseTask` ignores the second | drop one |
| Z26-B7 | `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90 → `uib_AfterCast` FUN_0053ff70 | 0x304E calls the item actor's `uib_AfterCast` directly, without `uib_CanUseItem` / `uib_DirectUse` and without an item-class check; for the silver wing it runs `sp_SilverWing_PortalBlast` at once, then starts a skill cast of 0x7210 on the linked player | a crafted 0x304E teleports without menu or cast, out of `LinkOut` / SystemMap maps, and with nothing saved to map 0 (Rou); cooldown from the generic skill path | refuse 0x304E for items whose actor is not the skill-item actor (check the item class / `ItemUseFunction` entry), or call `uib_CanUseItem` first |
| Z26-B8 | `sp_silverwing_Setloc` FUN_0059bc80 | answers 0x3016 0x700 right after sending 0x3449, before the Character server confirms; a 0x344A 0x902 (`ItemAttr_Save` failed, D03 §4) makes the zone Free the reserved copy (Z05 §5.4) | the player is told the save succeeded while the old location (or none) stays in the item | answer after the 0x344A, or send an error on 0x902 |
| Z26-B9 | `sp_SilverWing_PortalBlast` FUN_00597cf0 | no field level check (`FieldLvCondition` LvFrom–LvTo) at save or blast | *(inferred)* a player can return to a level-windowed map with `LinkIn` ≠ 0 after passing its `LvTo` | check the destination's level window at the blast |

Also in this flow: Z23-B5 (the first 0x4821 carries milliseconds).

## 8. Not reconstructed / uncertain

- Client side of the menu and the cooldown display: `ItemUseTask` state 3 is entered at the 0x3015; whether the client
  blocks other item uses until the 0x3016 arrives (the effect claimed in Z26-B1) was not traced in the task scheduler.
- `smo_ply_ItemUse` runs the field Lua event `ItemUse` after `uib_AfterCast`; after a same-zone link `p.so_Field` may
  already be the destination field, so the event would fire on the destination map *(inferred, not traced in so_LinkTo's
  field switch)*.
- Whether a dead player (mode 3, accepted by 0x3C02) can save a location: `sp_silverwing_Setloc` has no mode check, so it
  would *(inferred; mode 3 = dead from so_LinkTo's "Link Fail Player Die" test in Z01 §7.1)*.
- Whether any client build shows the "Fly" entry differently: the menu is plain server text (`MenuString` / `ETC` script
  strings), the client has no silver-wing code besides the `UseSilverWings` cooldown exception in FUN_006a2b30.
- 0x304E path (§5.5, Z26-B7): the end of the skill cast of 0x7210 started after the link (which cooldown store, whether
  the cast survives a cross-zone link) was not traced; the attribute bytes of a newly created silver wing (assumed 0) neither.
- Z26-B9: no 2016 map was checked for `LinkIn` ≠ 0 together with a `FieldLvCondition` row.
- How the client refreshes the item's attribute after 0x344A Apply (cell change packet) is Z05 §5.4 / Z04 §1.4, not traced here.

## 9. Coverage boundary

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| 0x3015 checks, `sp_NC_ITEM_USE_REQ` FUN_005416b0, `sp_ItemUseReq_Inven` FUN_0053f5e0 (Z04: "ItemUse_Inventory"), `UseItemNormal` path | Z04 §6.1, §6.3 (done) | generic item use before the actor is called |
| 0x304E `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90 (all non-silver-wing behaviour) | Z04 §12.7 (done) | generic skill-item use; its silver-wing consequence is §5.5 / Z26-B7 here, because Z04 does not describe the direct `uib_AfterCast` call |
| `smo_SkillBash_Casting` FUN_0057bef0 and the skill cast end | Z03 §5.4 (done) | generic cast after §5.5 |
| Minimon auto-use `sp_UseItemMonimon_UseItem` FUN_00561b80 (another caller of `uib_CanUseItem` / `uib_DirectUse`) | Z13 §9.4 (done) | cannot reach the silver wing: auto-use items are validated against `MinimonAutoUseItem.shn`, which has no `SilverWings` row (checked) |
| Character-server 0x3449 FUN_0040e630 / `ItemAttr_Save`, BindItem option rows 1100 / 1110+10n | D03 §1.3, §4 (done) | DB side of the location save, cited in §1.2 |
| `FieldLvCondition.shn` loader `fldb_Load` FUN_0046a350 | Z14 (table loader, done) | cited only for Z26-B9 |
| `ShineMobileObject::so_Routine` FUN_0056a080 (all non-item branches), `smo_ply_ItemUse` FUN_0053fd10 | Z13 §9.4 (Minimon auto-use section, which also summarises `smo_ply_ItemUse`; done) | §5.1 / §5.2 summarise only the silver-wing path |
| `csl_CoolTimeCheck`, `smo_ply_SkillCoolTime`, `so_ply_NewSkillCoolTime`, `so_ply_SilverWingCoolTime` FUN_005596b0 / FUN_00554f50 | Z23 §3.2, §3.6 (done) | cooldown store; bug Z23-B5 recorded there |
| `sp_ServerMenuTitle` / `Item` / `Open`, `sma_Regist`, `sma_IsReady`, 0x3C02 handler FUN_0050fe60, `sma_Reply` FUN_0050fd40 | Z02 §6.6 (done) | generic server-menu machinery; the parts that decide whether the item use is answered (`sma_Reset` FUN_0050fc00, `sma_Clear` FUN_0050f660, the reset-callback hook FUN_00549b30 / FUN_0050f800) are in §4.4 because Z02 does not cite them |
| `ItemMenu_Open` FUN_0048ced0 (the other user of the reset callback) | Z04 §1.5 (done) | cited only to argue Z26-B1's intent |
| `sp_EndOfTrade` FUN_004c25b0, `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 | Z02 §6.4, Z01 (done) | only their `sma_Reset` call matters here (§4.4) |
| `SkillDataIndex::sdi_SetArgument` FUN_00584800 / `sdi_Clear` FUN_00584500 (`sdi_SILVERWING`) | Z20 §4 (done) | loader of the skill special; no 2016 reader exists (§1.1) |
| `ChargedItemEffectElement::ciee_Activ` FUN_00450550, `so_Initstaticvar` FUN_00549530, template copies in FUN_00443390 / 00554870 / 005645e0 / 005970c0 / 0056c790, `UseItemChargedBuff::uib_CanUseItem` FUN_00598310 (`EE_SILVERWINGCOOLTIME` case) | Z24 §6.7 (done) | the `cec_SilverWingCoolTime_Minute` value; 2016 data never lowers it |
| profiler / assert / message-table / map-btree helpers (FUN_004682d0, 00468360, 0063c710, 0063c760, 0048ce60, 0063cc30, 004c89c0) | boilerplate (Z01) | no silver-wing logic |
| `so_LinkTo` FUN_0049ad30, 0x1809, WM 0x180D / 0x180E | Z01 §7.1 | generic link path |
| `so_ply_IsLink_OutMap_AndSendErrorMsg` FUN_005603d0 | Z16 §2.3 (done) | documented there with 0x181D codes |
| `so_ply_Notice` FUN_005977e0, 0x2011 | Z09 / Z11 §1.5 | notice packet |
| 0x344A ITEMCHANGE_ACK Apply / Free | Z05 §5.4 | DB answer path |
| `sp_ItemUseBroadcast` FUN_0053f840, `ItemUseFunction::iuf_Load` FUN_0049b770 | Z24 §1.4, §2 (done) | item-use table loader and broadcast |
| `ItemDataBox::idb_Load` FUN_00649780 (`sii_silverwing`) | Z27 (open; plan: "special item IDs") | table loader |
| `cec_SilverWingCoolTime_Minute` premium effect | Z24 §6.7 (done) | data source of the cooldown |
