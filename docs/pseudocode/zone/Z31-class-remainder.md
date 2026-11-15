# Zone server: class-named functions no document cites (Z31)

Source: the 2016 zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`), read with the NA2016 `Zone.pdb` names
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Names of classes, members, enums and
struct fields are *(pdb2016)* unless marked otherwise. Evidence markers as in `AGENTS.md`. Layouts:
`docs/protocol/annotations/Z31.json`. Corrections to older documents: `docs/knowledge/Z31.md` §0.

`coverage.py` starts at the packet handlers and follows direct calls, so it misses functions reached only through
virtual slots, member-pointer tables, timers or start-up code. This item documents the class-named functions of
`python3 -I docs/plan/status/X02-cov.py game zone` that no other document cites (the gamble classes are Z32). Every
virtual member names its vtable slot (byte offset into the vftable recovered by `tools/protocol-re/rtti.py`) and the
callers of that slot, found with `rg '\+ 0x<slot>\)\)\(' re-data/exports/zone-pdb/decomp.c`.

## 1. Work list

`X02-cov.py game zone` (2026-11-15): 7 438 class-named functions, 1 157 not cited (25 799 lines). Without the gamble
classes (`CGambleDiceTaiSaiObject`, `CGambleObject`, `DiceTaiSai`, `SlotMachine::*`: 87 functions, 4 065 lines, Z32)
1 070 functions, 21 734 lines remain. They are split by subject into the sections of this document (the part plan
and the bucket rules are in `docs/plan/status/Z31.md` and `docs/plan/status/Z31-parts.py`):

| § | Subject | Functions / lines |
|---|---|---|
| 2 | the 14 player / mobile-object members named by `docs/review/confidence.md` §4.4 | 14 / 1 115 |
| 3 | inventory lock list, cell stacks, inventories and item boxes, item attribute classes | 137 / 2 862 |
| 4 | the other `ShinePlayer` members | 130 / 2 008 |
| 5 | `ShineObject`, `ShineMobileObject` and the other object classes | ≈ 1 750 |
| 6 | abstate containers, character classes, mob AI, rules of engagement, use effects | ≈ 1 800 |
| 7 | table templates (`BinaryDataBox<…>`, `ITableBase<…>`, `IIDTableBase<…>`, `SHND::CommonData<…>`, `Table`) | ≈ 4 100 |
| 8 | the other data loaders and SHN / text parsers | ≈ 2 200 |
| 9 | NPC roles, merchants, booths, guild, events, kingdom quest, Lua glue | 111 / 2 822 |
| 10 | sessions, packet containers, `AxialList*` visitors, map clusters, path finding, library classes | ≈ 3 100 |
| 11 | open points of Z01-Z04 (`confidence.md` §4.6 rows 5-8) | – |

## 2. Player and mobile-object members named by `confidence.md` §4.4

### 2.1 Guild rename / retype: the commit after the item is consumed (vt 0x888 / 0x88c)

The request side is Z08 §8.1 (`0x74AC` / `0x74B4` → WM `0x74AF` / `0x74B7`) and the WM answer Z08 §8.2
(`0x74B0` / `0x74B8` → `so_ply_GuildReName` / `so_ply_GuildReType`). The WM side is W03 §9.3 (rename) and §9.4 (retype).
Both item kinds use the actors `ui_GuildReName` / `ui_GuildReType` (`UseEffect::UseItemGuildReName` /
`…ReType`, Z04 §6.3), so the consumption goes through the normal `uib_AfterCast` → Item DB → `uib_Effect` path
(Z04 §6.3); the new name / type waits in a 128-entry ring until the DB confirms. The pattern is the megaphone's
(Z04 §6.4).

```pseudo
# WM answered 0x74B0 NC_GUILD_WORLD_RENAME_ACK with err 0x1A40 (Z08 §8.2)
ShinePlayer::so_ply_GuildReName(p, u8 nItemSlot, Name4 sGuildName):          @ FUN_00474650
    # the same checks as the request handler 0x74AC, repeated now that the WM has approved
    err → so_SendErrorCode(29, 173, err) = 0x74AD NC_GUILD_RENAME_ACK { u16 err }
    p.mode ∉ cmc_AllowMode 0x56 = {1, 2, 4, 6}:                      0x1A41
    p has no field, or the field's CanItem (FieldList +0x9e) == 0:  0x1A42 "Request cannot be processed at a current location"
    NPC menu or storage open (sp_NPCProcess.duplicatemenustate.dmc_Control & 0x0C): 0x1A41
    nItemSlot ≥ inventory size: assert "…sp_NC_GUILD_RENAME_REQ : wrong slot", 0x1A43 "Incorrect item."
    cell locked (sp_Item.invenlocklist vt 4(9, slot, sp_RideCast.horselockindex)): 0x1A44
    cell item ≠ idb_SpecialItems().sii_GuildReName (Z27 §3.7):      0x1A43
    lot < 1: assert "… Try to use lot 0 item", 0x1A45;  no ItemInfo: assert "… Try to equip empty cell", 0x1A45
    else:
        UseItemNormal::uib_AfterCast(&ui_GuildReName, p, inventory, info, nItemSlot)       # Z04 §6.3: DB USEALL/USELOT
        p.sp_GuildReNameFlag = MemoryQueue<MemoryQueueGuildReName>::mq_Store(&queue_GuildReName,
                                   p.handle, {sGuildName})                                   @ FUN_004745f0
        # no reply now; the reply comes with the DB confirmation below

MemoryQueue<T>::mq_Store(q, handle, content) → index:                         @ FUN_004745f0 (ReName) / FUN_004734f0 (ReType)
    q.mq_Pointer.value = (value + 1) & mask        # mask 0x7F: mq_Buffer has 128 elements { u16 handle; T content }
    q.mq_Buffer[value] = { handle, content };  return value
    # T = MemoryQueueGuildReName { Name4 sGuildName } (element 0x12 B), MemoryQueueGuildReType { u8 nType }

# the Item DB confirmed the consumption → Z05 → UseItemGuildReName::uib_Effect                @ FUN_0059a3d0
#   → p.vt[0x888]() (only caller of the slot; ShineObject default FUN_00417480 is empty)
ShinePlayer::so_ply_GuildReNameItemUseSuccess(p):                             @ FUN_00473ea0 (vt 0x888)
    i = p.sp_GuildReNameFlag
    if i < 0x80 and queue_GuildReName.mq_Buffer[i].handle == p.handle:
        → WM 0x74B1 NC_GUILD_WORLD_RENAME_CMD {                       # 0x18 bytes with the opcode
              u16 zoneHandle = p.handle; u32 charNo = p.so_GetCharRegistNumber() (vt 0x344)   # the 6-byte ref
              Name4 sGuildName = mq_Buffer[i].content.sGuildName }
        send p: so_SendErrorCode(29, 173, 0x1A40) = 0x74AD NC_GUILD_RENAME_ACK { 0x1A40 }    # success
    elif i < 0x80:   # the ring slot was reused by a later rename (128 renames zone-wide in between)
        ChargedItemLog "Guild ReName Null <name>"; nothing is sent        (original bug) Z31-B1
    else:            # i is not a ring index: the player name and i go to ChargedItemLog; nothing is sent
    # the null test `mq_Buffer + i != 0` is always true (dead check)

ShinePlayer::so_ply_GuildReType(p, u8 nItemSlot, u8 nType):                   @ FUN_00473c00
    same checks and order as so_ply_GuildReName with the retype codes, replies so_SendErrorCode(29, 181, err)
    = 0x74B5 NC_GUILD_RETYPE_ACK: mode / NPC menu 0x1A59, place 0x1A5A, slot / wrong item 0x1A5B, locked 0x1A5C,
    lot 0 / empty 0x1A5D; item = sii_GuildReType; actor ui_GuildReType;
    p.sp_GuildReTypeFlag = mq_Store(&queue_GuildReType, p.handle, {nType})    @ FUN_004734f0

# UseItemGuildReType::uib_Effect @ FUN_0059a480 → p.vt[0x88c]()
ShinePlayer::so_ply_GuildReTypeItemUseSuccess(p):                             @ FUN_00474250 (vt 0x88c)
    i = p.sp_GuildReTypeFlag
    if i < 0x80 and queue_GuildReType.mq_Buffer[i].handle == p.handle:
        → WM 0x74B9 NC_GUILD_WORLD_RETYPE_CMD { u16 zoneHandle, u32 charNo, u8 nType }   # 9 bytes with the opcode
        send p: 0x74B5 NC_GUILD_RETYPE_ACK { 0x1A58 }
    else: ChargedItemLog "Guild ReType Null <name>" (or the name only); nothing sent   (original bug) Z31-B1
```

Client (`GuildTask`): `Recv_NC_GUILD_RENAME_ACK` FUN_006b3350 shows nothing for 0x1A40 and the error text
(`ErrMsgTable`) for any other code; the new name reaches the client through the WM's guild broadcast (W03).
`Recv_NC_GUILD_RETYPE_ACK` FUN_006b51f0 shows TextData2 0xC7401B23 "Guild property have been successfully updated."
for 0x1A58, else the error text. Codes with client texts: 0x1A42 / 0x1A5A "Request cannot be processed at a current
location", 0x1A43 "Incorrect item."; 0x1A41, 0x1A44, 0x1A45, 0x1A59, 0x1A5B-0x1A5D have no entry in
`client-error-codes.json`.

A WM failure after `0x74B1` / `0x74B9` is only logged there (W03-B15): the item is gone. The ring is keyed by the
player's zone handle, so a player who logs out before the DB answer and whose handle is reused by another player
in the same ring slot would commit the other player's pending name *(inferred: the handle check is the only
check; the DB answer normally arrives within milliseconds)*.

### 2.2 Item-use checks: `UseItemByTable` and `UseItemSkillDummy2Real`

`uib_CanUseItem` is slot +4 of the `UseEffect` actors (Z04 §6.3), called by `0x3015 NC_ITEM_USE_REQ`
(Z04 §6.1) before the cast; a code ≠ 0x700 is the use result sent to the client.

```pseudo
UseEffect::UseItemByTable::uib_CanUseItem(actor, p, info) → code:             @ FUN_005981e0
    row = useditemeffect.uie_FuncStruct[info.itemid].useeffectstruct    # ItemUseEffect.shn row (Z24 §1.2);
                                                                        # ids ≥ uie_MaxItemID use element 0
    if row == null: return 0x713 "The selected item does not have any effect when used."
    n = sp_CanUseItemCheck_ByTable(p, row.UseEffectA, row.UseValueA, row)
      + sp_CanUseItemCheck_ByTable(p, row.UseEffectB, row.UseValueB, row)
      + sp_CanUseItemCheck_ByTable(p, row.UseEffectC, row.UseValueC, row)
    return n ≠ 0 ? 0x700 : 0x713                      # usable if any one of the three effects would do something

ShinePlayer::sp_CanUseItemCheck_ByTable(p, UseEffectType kind, u16 value, row) → 0/1:   @ FUN_0056eae0
    row == null: 0
    UE_HPUP (0):        so_GetHP (vt 0x4e8) < so_MaxHP (vt 0x4f0)
    UE_SPUP (1):        so_GetSP (vt 0x4ec) < so_MaxSP (vt 0x4f4)
    UE_HPSPALLUP (7):   HP < MaxHP or SP < MaxSP
    UE_POISONREMOVE (2), UE_DISEASEREMOVE (3), UE_CURSEREMOVE (5): 1 (always usable, even without such an abstate)
    UE_ABSTATE (4):     a = dic_abstate[row.UseAbstateName] (B-tree by name; the load-time UseAbstateIndex is not used)
                        a valid and 1 ≤ value ≤ 39: AbstateListInObject::asl_CanEnchant(p+0x1cc, a, strength value)
                        else 0
    UE_NONE (6), UE_DEBUFALLREMOVE (8), UE_ACTIONITEM (9), others: 0
```

In the 2016 `ItemUseEffect.shn` (240 rows) no row relies on kinds 6/8/9 alone except the 75 `ACTIONITEM` rows,
whose items use the direct `UseItemActionItem` actor (Z04 §6.3) and never reach this check *(inferred from the
actor table)*; the single `DEBUFALLREMOVE` row also carries `HPSPALLUP` and `ABSTATE`. So a debuff-removal effect
alone never makes an item usable by this check; poison / disease / curse removal always does.

```pseudo
UseEffect::UseItemSkillDummy2Real::uib_CanUseItem(actor, p, info) = sp_CanItemMakeItem(p)   @ FUN_005965f0

ShinePlayer::sp_CanItemMakeItem(p) → code:                                    @ FUN_0049b6c0
    limit = p.so_ply_ChargedEffectContainer() (vt 0x498) ? inventory.vt 4(container) : inventory.vt 8()
            # the inventory size including the charged bag expansions (as Z15 §5.1 counts free cells)
    first = UnlockedInventoryIterator{ lock list = p.so_ply_GetInventoryLockList() (vt 0x7d4), box type 9,
                                       ItemBoxIterEmpty over sp_Item.itembag.ci_Inventory up to limit }.uii_Home()
    return first found ? 0x700 : 0x71D "There is no empty space in Inventory"
```

The skill-dummy item turns a dummy skill item into the real one, so it needs one free, unlocked inventory cell.

### 2.3 Logout: party slot release (`sp_LogoutDuringParty`)

```pseudo
ShinePlayer::so_FreeFromList(p):                       @ FUN_00554310 (vt 0x2c; called by som_FreeObject, Z01 §4.2)
    sp_LogoutDuringParty(p)
    remove p from the two slanted coordinate lists (cn_RemoveList on +0x16 and +0x22) when linked;
    if only one of them was linked: assert "ShineObjectList::som_FreeObject : one of SlantedList is removed"

ShinePlayer::sp_LogoutDuringParty(p):                                          @ FUN_004cd340
    if p.so_PartyRegistNumber() (vt 0x550) == −1: return
    slot = CParty::operator[](&partycontainer, partyNo)          # the zone's party mirror, Z08 §1
    if slot == null: assert "ShineObjectClass::ShinePlayer::sp_NC_MAP_LOGINCOMPLETE_CMD : Party not found" (sic,
        copied text); return
    for m in slot.Members[0..4] with m.MemberInform.Member.chrregnum == p.charNo:
        m.memberobj = null;  m.MemberInform.ZoneMerchineNo = 0xFF;  m.MemberInform.Member.zonecharhandle = 0xFFFF
        m.MemberInform.Member.charname = p.charid;  .level = p.so_GetLevel() (vt 0x4d8);  .flag = 0
    # the member stays in the slot, marked "not on this zone"; nothing is sent (the other members learn it from the
    # WM's party messages, Z08 §1 / W02 *(inferred)*)
```

Every free of a player object runs it: normal logout (Z01 §8.1, reason 0x12), kick / disconnect (`so_banning`,
Z01 §8.3, reason 0x10) and, *(inferred)*, the free after a zone change. A deferred free (`som_FreeObject` with arg 1) returns before vt 0x2c,
so the slot is cleared only when the object is really freed.

### 2.4 `so_ply_BanByServerDisconnect` (vt 0x4b0): no caller

```pseudo
ShinePlayer::so_ply_BanByServerDisconnect(p, List<ShineObject>* list, u16 index) → true:   @ FUN_00566930 (vt 0x4b0)
    MoreDisconnectLog: the player's name
    p.so_banning(0) (vt 0x5fc, not deferred; Z01 §8.3)
    return true
```

The signature is a list visitor's (`(list, index) → continue?`); the `ShineObject` / `ShineMobileObject` default of
slot 0x4b0 is the folded `return true` body FUN_0064c820 (`ListIteratorDefault<ItemActionObserve>::lid_Call`).
No call through `+ 0x4b0` exists in the zone, and the only pointer to FUN_00566930 in the image is its vftable
entry (VA 0x6eaacc): the "kick every
player when the server connection drops" pass it was written for is dead code in 2016 *(inferred: the WM-link loss
path, Z01 §3.3, does not use it)*.

### 2.5 Chat-spam block state: load, save to the Character DB and the WM

The filter itself (`SpamCheck` / `Penalize`, the tables, 0x0848 to the client) is Z02 §3.4. These members carry the
block across logins and zone changes. `sp_SpamerInfo { BlockTime, DelayTime }` holds absolute `cw_CurrTick` values
(block end, probation end; ticks of 1/10 s as Z02 §3.4); `sp_SpamerInfoSaveChack` = "a non-empty state was saved".

```pseudo
ShinePlayer::sp_SpamInitSpamerInfo(p) → ok:                                   @ FUN_00560730
    n = spdb_SpamePenaltyGetRepeatRule() (Z30 §5)
    if sp_SpamChatTimeInfo.pChatTime == null: pChatTime = malloc(n × 4); null → return false
    pChatTime[0..n−1] = 0; nChatTimePos = 0; BlockTime = DelayTime = 0; sp_SpamerInfoSaveChack = 0
    # ~ShinePlayer frees pChatTime (§2.9)

# WM 0x10CB NC_CHAR_GET_CHAT_BLOCK_SPAMER_CMD { ref, u32 BlockTime, u32 DelayTime } (map login, Z07 §1 table)
#   → wms_NC_CHAR_GET_CHAT_BLOCK_SPAMER_CMD @ FUN_0044c9b0: object by ref.handle, charNo must match, not closing
#     (vt 0x300), else assert "…wms_NC_CHAR_ZONE_BASE_CMD : Invalid player"; then p.vt[0xab4](body)
ShinePlayer::so_SpamRecvDataFromWM(p, body):                                  @ FUN_0044a9b0 (vt 0xab4)
    now = cw_CurrTick; unix = _time32()
    if body.BlockTime ≠ 0:                    # still blocked: both values are durations in seconds
        BlockTime = now + body.BlockTime × 10;  DelayTime = BlockTime + body.DelayTime × 10;  SaveChack = 1
    elif unix < body.DelayTime:               # probation only: DelayTime is a unix time
        BlockTime = now;  DelayTime = now + (body.DelayTime − unix) × 10;  SaveChack = 1
    else: BlockTime = DelayTime = now

# full character save, ws_save2DB with partial == false (Z01 §8.4) → p.vt[0xab8]()
ShinePlayer::so_SpamSendDataToCharDB(p):                                      @ FUN_00562990 (vt 0xab8)
    block = BlockTime > now ? max(1, (BlockTime − now) / 10) : 0                     # seconds left
    if block ≠ 0: delay = (DelayTime − BlockTime) / 10; SaveChack = 1                # probation length, seconds
    else:
        delay = DelayTime > now ? _time32() + (DelayTime − now) / 10 : 0             # probation end, unix time
        if delay ≠ 0: SaveChack = 1
        elif SaveChack == 0: return                                                  # nothing to store
        else: SaveChack = 0                                                          # send the zeros once
    → Character DB 0x4022 NC_CHARSAVE_SET_CHAT_BLOCK_SPAMER_DB_CMD { u32 CharNo, u32 BlockTime = block,
          u32 DelayTime = delay }   (0xE bytes with the opcode, no header; D02: usp_SpamBlock_setTime)
    # ShineObject default of vt 0xab8: the empty FUN_00417480

# ws_save2worldmanager (Z01 §8.4; zone change) calls it directly
ShinePlayer::sp_SpamSendDataToWM(p):                                          @ FUN_00562bc0
    block / delay computed as above (same two encodings), without the SaveChack logic: always sent
    → WM 0x4021 NC_CHARSAVE_SET_CHAT_BLOCK_SPAMER_WM_CMD { u16 WmHandle = so_GetWMSHandle() (vt 0x340),
          u32 CharNo, u32 BlockTime, u32 DelayTime }   (0x10 bytes with the opcode; WM stores them at +0x1ece4 / +0x1ece8, W05)
    # assert text "ShinePlayer::sp_SendSpamerToWM : Packet Too Long"; the DB sender's says sp_SendSpamerDataToCharDB
```

So the two encodings are told apart by `BlockTime`: ≠ 0 → durations, = 0 → `DelayTime` is the unix time the
probation ends. The WM echoes its copy back in 0x10CB at the next map login, so the block survives a zone change;
the DB row survives a logout.

### 2.6 `so_ply_DecreaseDmgPassiveSkill` (vt 0xd34): the BackgroundDefense passive

`roe_CalcDamage` (Z03 §4.5) calls `def.vt[0xd34](att, dmg)` for every hit. The `ShineObject` default is
FUN_004021c0 (`return dmg`, PDB name `so_ply_JobChangeDamageUp`, a fold); `ShinePlayer` overrides it:

```pseudo
ShinePlayer::so_ply_DecreaseDmgPassiveSkill(p, att, dmg) → dmg:              @ FUN_005651e0 (vt 0xd34)
    if att == null or att.vt[0x4d0]() ≠ 5: return dmg          # only plain mobs (type 5, not NPC/bandit/servant/pet)
    rate = p.so_parameter() (vt 0x430).DMGMinusRate (P+0xdac, Z12 §1; PassiveSkill.shn DMG_MinusRate)
    if rate == 0 or a location is missing: return dmg
    area = SingleData["DMG_MinusArea"] (read once into nDMGMinusArea; 2016 SingleData.shn: 300)
    if dist²(p, att) > area²: return dmg
    if p.pos == att.pos: return dmg
    toPlayer = ddt_DirectSR(p.pos − att.pos)          # the direction from the mob to the player, 0..179 (2° units)
    diff = |att.direction − toPlayer| folded to 0..90 (0..180°)
    if diff > 45 (more than 90°): dmg −= dmg × rate / 1000
    return dmg
```

2016 data: `PassiveSkill.shn` rows 840-842 `BackgroundDefenseG01` (200 ‰), `…J01`, `…S01` (300 ‰) are the only
rows with `DMG_MinusRate`. The name says "defence against hits from behind", but the test uses the **attacker's**
facing: the hit is reduced when the mob does not face the player. A mob turns to its target before a melee swing
(Z09 §7.3) *(inferred)*, so ordinary mob attacks are never reduced; only hits from a mob facing elsewhere (area skills, a mob
turned away) are, regardless of where the player looks (original bug) Z31-B2 *(the intent is inferred from the
skill name)*.

### 2.7 Weapon swing interval and reach (vt 0x788 / 0x78c)

Called after the equipment changes: `gds_NC_ITEMDB_EQUIPSUC_ACK` FUN_0052cba0, `…UNEQUIPSUC_ACK` FUN_0053b0a0
(both slots), `…REINFORCEUNEQUIPSUC_ACK` FUN_004a5100 and `…DROPALLSUC_ACK` FUN_0052ab80 (speed only; Z05), and
`sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 (reach only; Z01 §6). The `ShineObject` defaults FUN_0043d380 /
FUN_0043f4e0 are empty.

```pseudo
weapon(p) = ItemInfo of the item in equipment slot ITEMEQUIP_RIGHTHAND (12), or of ITEMEQUIP_LEFTHAND (10) when 12
            is empty (item id 0xFFFF); an id ≥ idb_maxItemhandle or without a row → none
            (a row whose ID differs asserts "ItemDataBox::operator [] :Invalid Item index" → none)

ShinePlayer::so_ply_WeaponSpeedSet(p):                                        @ FUN_0043d3c0 (vt 0x788)
    p.sp_BashControl.bashinterval (+0x29288) = weapon.Class == ITEMCLASS_WEAPON ? weapon.AtkSpeed : 1000

ShinePlayer::so_ply_WeaponRangeSet(p):                                        @ FUN_0043f520 (vt 0x78c)
    p.sp_BashControl.bashrange (+0x29284) = weapon.WeaponType ∈ {WT_BOW, WT_CROSSBOW} ? 600 : 120
```

Readers: `bashinterval` = Z03's `weaponSpeed` (`so_attackspeed1000` FUN_005598d0, `smo_ply_NextBashTime`
FUN_0055ac90, `so_Bash` FUN_0042efb0), `bashrange` = Z03 §3.2's `attackRange` (`sp_Schedule_SwingStart` /
`…SwingDamage` reach test). The reach ignores the item class: every weapon type other than bow and crossbow (and
no weapon) gives 120 units.

### 2.8 `sp_ChatColor_Save2World`

```pseudo
ShinePlayer::sp_ChatColor_Save2World(p):            @ FUN_00563c70 (called by ws_save2worldmanager, Z01 §8.4)
    → WM 0x4032 NC_CHARSAVE_2WLDMAN_CHAT_COLOR_CMD { u32 charNo, u8 sp_nChatFontColor, u8 sp_nChatBalloonColor }  (8 bytes with the opcode)
    # WM: W05 (CHAT_COLOR_CMD → +0x1ed37 / +0x1ed38); the colours come from the charged chat-colour items (Z24 §6.7, table §7.7)
```

### 2.9 `~ShinePlayer`

```pseudo
ShinePlayer::~ShinePlayer(p):                                                 @ FUN_00559300
    # reached only through vt 0x4, `vector_deleting_destructor` FUN_0055b3d0
    free(sp_SpamChatTimeInfo.pChatTime)                                       # §2.5
    ~CSellItemManager(sp_SellItemManager); ~CardCollectionReward ×3 (reward, bookmark, album);
    ~IntelligenceOffice4Mob / ~MobTargetAggresive (m_TargetSelect); observers_: each element's vt[0](0), free;
    free sp_ItemActionObserves.iaom_CoolTimeList / iaom_Observes vectors (Z17 §3.6); ~List<MobHuntElement>;
    CChargedItem::Clear(sp_ChargedInven.inven); ~ChargedEffectList; ~CCharacterTitleZone; ~StreetBoothBuy /
    ~StreetBoothSell; ~TreasureChestLocationManager; ~ItemRewardStorage; ~ItemAccountStorage;
    ~CharacterPassiveList; ~CharaterSkillList; ~ShineQuestDiary; the normal-attack delay deque; sp_Item;
    ~TargetAnalyser; then ~ShineMobileObject
    # the many calls to "ShineObject::so_Gamble_ChangeCoin" are folded empty destructors (timers, menus, ticks)
```

Player objects live in the fixed pool of Z01 §4.2 and are reused, so the destructor runs only when the pool itself
is destroyed at process end *(inferred)*; nothing in it sends a packet or saves.

### 2.10 `ShineMobileObject::so_smo_AbnormalStateAttribute` (vt 0xa64)

The only caller of slot 0xa64 is `MiscDataTable::mdt_ArgumentLoad` FUN_004a6110 (the `ExpandSkill` condition, Z09
§28.3: "the target has an abstate of that attribute"). Non-mobile objects use the `ShineObject`
default FUN_004a62e0 (`false`).

```pseudo
ShineMobileObject::so_smo_AbnormalStateAttribute(o, AbnormalStateAttr attr) → bool:   @ FUN_004a8010 (vt 0xa64)
    # AbnormalStateAttr (MiscDataTable::MiscData_VarifyByAbstate): NONE 0, STUN 1, SLOW 2, ACMRMINUS 3
    for each active abstate a in o.so_mobile_AbstateList() (vt 0x52c, the in-use chain):
        sub = the abstate's sub-state row for a's strength (AbStateStr.subabstate[strength])
        STUN:      sub.assa_info.Type == SUBAB_STUN (21)                                  → true
        SLOW:      sub has the action SAA_SPEEDDOWNRATE (88)                              → true
        ACMRMINUS: sub has SAA_ACMINUS (73), SAA_ACDOWNRATE (74), SAA_MRMINUS (86) or SAA_MRDOWNRATE (87) → true
        (assa_IsHaveEffect: one of the four assa_Effect actions equals the value)
    return false                       # NONE and unknown values walk the whole chain and return false
```

## 3. Inventory lock list, item boxes, item attribute classes

The request / DB-answer model these classes serve is Z05 §1 (reserve → DB → apply) and Z04 §1.4 (request side). This
section adds the members those documents name only by slot: the lock-list constructors and tests, the reservation
sums, the item boxes and their iterators, the item attribute classes' per-class bodies, the item-mall goods table and
two dead pieces (`CellStack`, `ci_FillBufferItem`).

### 3.1 Lock list layout

```pseudo
InventoryLocking::InventoryCellLock            (0x8)      base; vtable of 32 slots, all no-ops (FUN_0064c820 true, FUN_005af8d0 true,
    +4 u16 icl_Index                                       FUN_00500380, FUN_004c2450 / FUN_00402370 / FUN_004879b0 empty, …)
                                                           InventoryCellLock FUN_00487930 / ~InventoryCellLock FUN_00487940 only set the vftable
InventoryLocking::InventoryCellLockList : InventoryCellLock   (0x7830, at ShinePlayer sp_Item.invenlocklist = p+0xfaa8)
    +0x08 ShinePlayer* icll_sp
    +0x0c List<LockedCell> icll_List                       # 192 entries; free-slot finger icll_List.l_Finger.empty (0xFFFF = full)
    +0x28 LockedCell[192] icll_Array
    +0x7828 u8 icll_AllLock                                # Z05's "DB-pending flag" (vt 0x14 sets it)
InventoryLocking::LockedCell (0xa0)
    +0x00 u16 lc_Index                                     # the lock index of the request that made it
    +0x04 InvenCellReleaser* lc_Releaser                   # one static object per kind: icll_Releaser_<Kind>
    +0x08 ITEM_INVEN lc_InvenLocCurrent, +0x0a ITEM_INVEN lc_InvenLocExchange
    +0x10 union lc_Argument (0x90)                         # per kind, (pdb2016):
        cellchange {ItemInventoryCell* cell; ItemTotalInformation iti}      cellchangesmall {ITEM_INVEN cell; iti}
        cellclear {cell*}   cenchange {u64 cen; s16 plusminus}   famechange {u32 fame; s16 plusminus}
        coinchange {u64 coin; s16 plusminus; u8 exchange}   pointstone {int flag; int num}
        equipchange {int equipslot; cell* equipcell; int otherslot; cell* othercell}
        itemuse {iti; UseItemBase* useitemclass}   questreward {int exp; int fame; u8 ct_type; u8 ct_elementno}
        linkinfo {NPCManager::LinkInformTemplete Link (0x61)}   zonerng {SHINE_INVEN_SLOT_INFO zr_from, zr_to; iti zr_changeiteminfo}
        CardOpen {iti Card; cell* Cell; ITEM_INVEN InvenLoc}   CardRegist {cell*; u16 CardID; u32 Serial; int StarNum; int Slot; title}
        ItemSell {SHINE_ITEM_REGISTNUMBER nSellItemKey; iti ItemTotalInfo}   ItemRepurchase {u16 nHandle}
```

Reservations that concern no cell (money, fame, coins, soul stones, sell / repurchase list) store the pseudo cell
`0x4400` (type 17, slot 0) in both locations, so the cell tests below never match them.

Every constructor takes a free entry with `icll_List.vt[8](finger)`. When the list is full (192 open reservations) it
only asserts "`<name> : List Full`" and returns: the caller does not learn it and sends its DB request anyway, so the
DB change is made but nothing is applied in memory on success *(inferred: no caller tests the result; all constructors
return void)*. Reaching 192 needs 192 unanswered DB requests of one player; most request handlers refuse while
`vt 0x10` reports busy, so this is not reachable in normal play (not tagged as a bug).

`~InventoryCellLockList` FUN_00488730 frees the list array; it runs from `~<unnamed-type-sp_Item>` FUN_005498c0
(§3.5). `ListEraser<InventoryLocking::LockedCell>::~ListEraser` FUN_0043f660 only resets its vftable.

### 3.2 Lock-list vtable: every slot and its callers

Callers found by slot offset on the object returned by `p.vt[0x7d4]` (`so_ply_GetInventoryLockList`) or on
`p.sp_Item.invenlocklist` directly. Slots documented elsewhere are only linked.

| Slot | Function | Meaning | Callers |
|---|---|---|---|
| 0x00 | `icl_IsLocked(ITEM_INVEN*, u16 ownIndex)` FUN_00488830 | → vt 0x04 with `inven >> 10`, `inven & 0x3ff` | none found |
| 0x04 | `icl_IsLocked(type, slot, u16 ownIndex)` FUN_0048b0f0 | true when `icll_AllLock`, or a reservation **of another lock index** has the cell as current or exchange location | `sp_NC_ITEM_USE_REQ` FUN_005416b0, `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90, `sp_NC_ACT_ROAR_REQ` FUN_005404d0, guild rename / retype FUN_00473550 / FUN_00473860 / FUN_00474650 / FUN_00473c00 (§2.1), `sp_NC_USER_CONNECTION_CHANGE_CHAR_ID_ITEM_USE_REQ` FUN_0051b090, `so_ply_MH_FurnitureEndureUse` FUN_00571550, `sp_NC_GAMBLE_COIN_VIPCARD_UI_OPEN_REQ` FUN_00616ad0, `StreetBoothSell` trade FUN_00591850 |
| 0x08 | `icl_IsLocked(ITEM_INVEN*)` FUN_00488770 | → vt 0x0c | `sp_NC_ITEM_RELOC_REQ` FUN_00537170, `so_ply_ArrangeInven` FUN_00563500, `sp_MiniHouseActivCheck` FUN_00534fe0, `sp_NC_MINIHOUSE_ACTIV_REQ` FUN_00536310, `sp_SmallItemActivCheck` FUN_005697e0, costume script nodes FUN_00518fb0 / FUN_005191b0, furniture create / delete / re-arrange FUN_00544f00 / FUN_00545a40 / FUN_00546150 |
| 0x0c | `icl_IsLocked(type, slot)` FUN_0048af30 | true when `icll_AllLock`, or **any** reservation has the cell as current or exchange location | ≈ 50 item handlers (Z04 §1.4 "`L.vt[0x0c]`") |
| 0x10 … 0x28 | busy / pending / apply / free | | Z05 §1.2, §1.3 |
| 0x2c | `icl_OnlyLock(lock, type, slot)` FUN_004888f0 | releaser `None` (base `InvenCellReleaser`), current = exchange = `type<<10 \| slot`; its "List Full" text says `icl_ClearItem` | `ItemDropper::id_Drop` FUN_0048dc90, `ItemBreaker::ib_Break` FUN_0048de20 (Z04 §3.1 / §3.2 confirmations) |
| 0x30 | `icl_ClearItem` FUN_00488a10 | | Z04 §1.4 |
| 0x34 | `icl_ClearItemSimple(ItemBoxIterator*)` FUN_00487950 | null iterator: nothing; else `vt 0x30(L.icl_Index, it.ibi_GetCell(), &inv, &inv)` with `inv = bag.vt[0xc]() << 10 \| it.ibi_finger` | `sp_MysteryVaultMakeItem` FUN_005658f0 (Z05 §9.8) |
| 0x38 | FUN_00488b60 | | Z05 §1.4 (`CardRegist`) |
| 0x3c | `icl_CardOpen(lock, cell, ItemTotalInformation* card, slot)` FUN_00488c90 | releaser `CardOpen`; current = exchange = inventory 9 `slot`; argument `{card copy (0x6f bytes), cell, InvenLoc}` | `so_ply_CollectCardOpen` FUN_006281b0 (Z05 §6.6) |
| 0x40 | `icl_StoreItem(lock, cell, iti*, ITEM_INVEN* cur, ITEM_INVEN* exch)` FUN_00488db0 | releaser by `cur` type: 3, 13, 14, 16 (mini-house boxes) `FurnitureReloc`; 4 `GuildStorageChange`; 0 `GuildAcademyRewardStorageChange`; else `CellChange`; argument `{cell, iti}` | 24 request handlers: buy / sell / repurchase lots, booth buy / sell, moves (`irm_*`), equip, upgrades, enchant gems, mix, stat reset, mini-house, WT licence, … |
| 0x44 | `icl_StoreSmallItem(lock, ITEM_INVEN* cell, iti*, cur, exch)` FUN_00488f10 | releaser `CellChangeSmall`; argument `{cell, iti}` | `ItemBreaker::ib_OK` FUN_0048d0d0, `sp_SmallItemReloc<ItemInform_ActionItem>` FUN_00535e10, `sp_Move4Activ` FUN_0059b8e0 |
| 0x48 / 0x4c / 0x50 / 0x54 | money / fame / equip / equip location | | Z04 §1.4 |
| 0x58 | `icl_UseItem(lock, iti*, ITEM_INVEN* cell, UseItemBase* actor)` FUN_004895d0 | releaser `ItemUse`; current = exchange = `cell`; argument `{iti, useitemclass = actor}` | `UseItemNormal::uib_AfterCast` FUN_00540080, `UseItemVariationProtocolBase::uib_AfterCast` FUN_0059a530 (Z04 §6.3) |
| 0x5c | `icl_StorePointStone(lock, int flag, int num)` FUN_004896e0 | releaser `PointStone`; pseudo cell 0x4400; `{flag (0 HP stone, 1 SP stone), num}` | `sp_PointStoneBuy` FUN_00588510 (Z05 §2.4) |
| 0x60 | FUN_00489800 | | Z05 §1.4 (`QuestReward`) |
| 0x64 | `icl_ReservedQuantity(ReservedQuantity* out)` FUN_0048b5d0 | §3.3 | `sp_NC_ITEM_BUY_REQ` FUN_00524a60, `so_ply_ItemBuyGuildToken` FUN_00526ef0, `so_ply_GuildTournamentJoinNew` FUN_00476860, `sp_NC_ITEM_UPGRADE_REQ` / `NEW_UPGRADE` / `BRACELET_UPGRADE` FUN_0053d220 / FUN_0053e360 / FUN_0053ec40, `sp_NC_SOULSTONE_HP_BUY_REQ` / `SP_BUY` FUN_00588d20 / FUN_00588e90 |
| 0x68 | FUN_00489020 | | Z04 §1.4 |
| 0x6c | `icl_LinktoItem(lock, LinkInformTemplete*)` FUN_004899b0 | releaser `LinkInfo`; the 0x61-byte link copied | `sp_DestroyItem` FUN_00527b60 (map-link scroll, Z04 §12.11) |
| 0x70 | `icl_StoreGBCoin(lock, u64 coin, int plusminus, u8 exchange)` FUN_00489d90 | releaser `CoinChange`; pseudo cell 0x4400; its "List Full" text says `icl_StoreMoney` | coin buys (Z04, Z32) |
| 0x74 | `icl_ItemSell(lock, SHINE_ITEM_REGISTNUMBER key, iti*)` FUN_00489ec0 | only when `iti` and `icll_sp` are not null; releaser `ItemSell`; pseudo cell 0x4400; `{key, iti}` | `ItemInventory::ii_SellAll` FUN_00538990, `ii_SellLot` FUN_00538cb0 (Z04 §2.4) |
| 0x78 | `icl_ItemRepurchase(lock, u16 nHandle)` FUN_0048a000 | only when `nHandle ≠ 0xFFFF`; releaser `ItemRepurchase`; pseudo cell 0x4400; `{nHandle}` | `ii_RepurchaseAll` FUN_00537ca0, `ii_RepurchaseLot` FUN_00538010 (Z04 §2.5) |
| 0x7c | `icl_ItemInfoZoneRng(lock, SHINE_INVEN_SLOT_INFO from, … to, ItemTotalInformation iti)` FUN_00489aa0 | only when `from.inven` or `to.inven` is type 0 (academy reward storage); releaser `GuildAcademyRewardStorageInfoZoneRng`; `{zr_from, zr_to, zr_changeiteminfo}`; its "List Full" text says `icl_LinktoItem`. Base `InventoryCellLock::icl_ItemInfoZoneRng` FUN_004879c0 is empty | `ItemRelocationManager::irm_Move` / `irm_Exchange` / `irm_Merge` / `irm_Split_N_Merge` FUN_00531860 / FUN_00531e90 / FUN_005324b0 / FUN_00532a20, `sp_NC_ITEM_SPLIT_REQ` FUN_00539a40 |

The two cell tests differ only in the own-index exclusion: vt 0x04 lets a handler re-check cells its own pending
request has already reserved (item use, roar, guild rename: the item being used is reserved under the same index),
vt 0x0c refuses any reserved cell.

### 3.3 Reserved quantities (`icl_ReservedQuantity`, releaser slot 4)

```pseudo
icl_ReservedQuantity(L, out) → out                                         @ FUN_0048b5d0 (vt 0x64)
    InventoryCellLock::icl_ReservedQuantity(out)                           @ FUN_00489930: out = {cen 0, fame 0, hpstone 0, spstone 0, guild_token 0, gbcoin 0}
    for every reservation e: e.lc_Releaser.icr_Reserv(out, e)              # releaser vt 4
InvenCellReleaser::icr_Reserv                     FUN_00488580   nothing (all cell kinds)
InvenCellReleaser_CenChange::icr_Reserv           FUN_004885d0   out.cen  += plusminus × (u32) cen
InvenCellReleaser_FameChange::icr_Reserv          FUN_00488640   out.fame += plusminus × fame
InvenCellReleaser_PointStone::icr_Reserv          FUN_004886b0   flag 0: out.hpstone += num; flag 1: out.spstone += num
InvenCellReleaser_CoinChange::icr_Reserv          FUN_00489d20   out.cen  += plusminus × (u32) coin      # (original bug) Z31-B3
```

`ReservedQuantity` is six `int`s (0x18). The callers subtract the sums from what the player owns before a price test
(Z04 §2.1 buy, §2.3 guild-token buy, Z05 §2.4 soul stones, the upgrade fees, the guild-tournament fee). Only the low
32 bits of a money or coin reservation are summed. **(original bug) Z31-B3**: the coin releaser adds the coin amount
to `cen`, not to `gbcoin`, and no releaser fills `guild_token` or `gbcoin`; a pending coin reservation lowers the money
the other checks see, and the guild-token buy (`local + 0x10` = `guild_token`, FUN_00526ef0) always sees 0 reserved
tokens. In practice the busy test (vt 0x10) keeps most of these requests from overlapping.

Releaser slot 8 (`busy`, read by `vt 0x10`): `FUN_005af8d0` (returns 1) for the base `InvenCellReleaser` (plain
`icl_OnlyLock` confirmations) and `GuildAcademyRewardStorageInfoZoneRng`; `FUN_004b8d20` (returns 0) for every other
kind. Slot 12 is the undo hook of Z05 §1.3 (`FUN_00549070` empty; `FurnitureReloc` FUN_00487910).

### 3.4 Item boxes, cells and iterators

```pseudo
ItemInventoryCell (0x74) { ItemTotalInformation iic_Item (0x70: u64 key, SHINE_ITEM_STRUCT); ItemAttributeClass* iic_AttrProc }
ItemInventoryCell::iic_ItemIdent(cell) = cell.iic_Item.itemid       @ FUN_0043c120   (0xFFFF = empty; 27 callers, inlined elsewhere)
ItemBag vtable (pure virtual in ItemBag: _purecall FUN_006583ea ×4)
    vt 0x00 cell(slot)   vt 0x04 ib_BagSizeInput(ChargedEffectContainer*) usable size   vt 0x08 ib_BagSizeOutput() full size   vt 0x0c box type
```

| Box | Cells (destructor) | Usable size (`vt 4`) | Full size (`vt 8`) |
|---|---|---|---|
| `ItemEquipment` | 0x1e (`~ItemEquipment` FUN_00643080) | | |
| `ItemInventory` | 0xc0 (`~ItemInventory` FUN_00642f90) | | |
| `ItemAccountStorage` | 0x240 (`~ItemAccountStorage` FUN_00643160, via `~AccountStorage` FUN_005499d0) | `ib_BagSizeInput` FUN_006431d0: `cec_MoreStorage` > 2 → 144, else `(18 + 9·MoreStorage)·4` = 72 / 108 / 144 | `ib_BagSizeOutput` FUN_00643200: 0x240 |
| `ItemGuildStorage` | | FUN_0063ec30 (folded): 36 | `ib_BagSizeOutput` FUN_006432e0: 36 |
| `ItemGuildAcademyRewardStorage` | | `ib_BagSizeInput` FUN_00643350: 72 | `ib_BagSizeOutput` FUN_00643360: 72 |
| `ItemRewardStorage` | 0x18 (`~ItemRewardStorage` FUN_00643470) | | |

The cell destructors are the empty `ShineObject` default (FUN_00417480). `~ItemBag` FUN_00642f50 and
`~ItemSmallBag<ItemInform_ActionItem>` FUN_006439b0 only reset the vftable. `~CharacterInventory` FUN_005494a0 and
`~<unnamed-type-sp_Item>` FUN_005498c0 (the player's `sp_Item`: `CharacterInventory itembag` + lock list) destroy, in
order, the lock list (sp_Item only), action-item box, mini-house box, quest box, inventory and equipment.

```pseudo
ItemBoxIterator { vt; ItemBag* ibi_itembag; int ibi_finger; int ibi_Limit }   vt 0 = ibi_isvalid
ItemBoxIterator::ibi_Next(it) → bool                                   @ FUN_00642f00   (29 callers)
    repeat: if it.ibi_finger ≥ it.ibi_Limit − 1: return false
            it.ibi_finger += 1
    until it.vt[0]() (ibi_isvalid); return true
ItemBoxIterator::ibi_GetCell(it) = it.ibi_itembag ? it.ibi_itembag.vt[0](it.ibi_finger) : null     @ FUN_00642f30
ibi_isvalid variants:  ItemBoxIterItem FUN_0043cba0: cell.itemid ≠ 0xFFFF       ItemBoxIterEmpty FUN_0043cbc0: itemid == 0xFFFF
                       ItemBoxIterIdent FUN_0043cbe0: itemid == it.ibii_ident
                       ItemBoxIterItemRegNo FUN_00643600: cell key == it.ibii_RegNo (both dwords)
                       base ItemBoxIterator FUN_005af8d0: every cell
ItemBag::ib_InitStateCell()                                           @ FUN_006439c0   (from so_Initstaticvar FUN_00549530, start-up)
    ib_staticcell = { key 0xFFFFFFFF:0xFFFFFFFF, item struct zeroed (0x67 bytes), itemid 0xFFFF, iic_AttrProc = itmattcontainer.iacc_default }
    # the shared "empty cell" returned for out-of-range slots (inferred from the name)
```

```pseudo
ItemBag::ib_InitializeAsNumber(bag, u8* count, PROTO_ITEMPACKET_TOTAL* rec, int type)      @ FUN_006434d0
    # caller: so_ply_FillRewardInven FUN_004fc310 (reward inventory page, Z04 §8.3, type 2) after ib_clear
    for i in 0 … *count − 1:
        if rec.location >> 10 == type:
            if i < bag.vt[8]():                    # full size; 24 for ItemRewardStorage
                iti = ItemTotalInformation::iti_fill2struct_whole(default class, 0xFFFF, rec.info)
                cell(i) = iti; cell(i).iic_AttrProc = itmattcontainer[iti.itemid]
            else: assert "ItemRewardStorage::irs_Initializetotal : Invalid slot"   # record dropped
        rec += rec.datasize
    # the cell index is the record's ordinal in the packet, not rec.location & 0x3ff: the page is packed from cell 0
```

**`CharacterInventoryManager`** (`charinvenman`): `cim_Array[17]` maps an inventory type to an accessor
`CharacterInventory → ItemBag*`, built by `so_Initstaticvar`: 7 `cim_quest` FUN_00642e10 (Z15), 8 FUN_00642df0 (folded
`return arg`, PDB name `so_fill_CHAR_PARAMETER_DATA`: `ci_Equipment` is at +0 of `CharacterInventory`), 9 `cim_inven` FUN_00642e00 (`&ci.ci_Inventory`), 12
`cim_minihouse`; every other type → FUN_004a9c90 (folded `return null`). Used by
`ci_FillBufferInventoryItem` (Z12 §6.7 box loading, 0x1047) and by:

```pseudo
CharacterInventory::ci_FillBufferItem(ci, u8* count, PROTO_ITEMPACKET_INFORM* out) → bytes    @ FUN_00643fd0
    *count = 0
    for box in 0 … 16: bag = cim_Array[box](ci); skip null
        for every non-empty cell (ItemBoxIterItem) s of bag:
            ItemInfo row missing: assert "CharacterInventory::ci_fullbuffertotal : Invalid ItemID found"; skip
            out.location = box << 10 | s; end = iti_fill2buffer_union(cell, cell.iic_AttrProc, itemid, &out.info)
            out.datasize = end − &out.info + 2; out = next; *count += 1
    return bytes written
    # only caller: ShinePlayer::so_fullbufferitem FUN_00559a60 = player vt 0x520, which nothing calls: dead in 2016
```

### 3.5 Item attribute classes (`ItemAttributeClass`, 51 slots)

One object per `ItemClassEnum` (Z04 §1.2; container `itmattcontainer`, `ItemAttributeClassContainer::operator[]`).
The Character server links the same library: D07 §1.3 has the container, the wire sizes per class and the
SkillScroll / WeaponTitlaLicence / GBCoin byte. The zone's vtable is longer (51 slots); the slot names (pdb2016):

| Slot | Method | Slot | Method |
|---|---|---|---|
| 0x00 | `scalar_deleting_destructor` (base FUN_006404e0) | 0x58 | `iac_wptitle_Getlicencemob` |
| 0x04 / 0x08 | `iac_fill2buffer` / `iac_fill2struct` | 0x5c / 0x68 / 0x6c | `iac_GetLot` / `iac_GetLot` / `iac_SetLot` (Amount, KQStep variants) |
| 0x0c | `iac_GetAttrSize` | 0x60 / 0x64 | `iac_GetDuringRide` / `iac_SetDuringRide` |
| 0x10 | `iac_itemcreate(id, ShineReward*, iti*)` (§3.5.1) | 0x70 | `iac_GetItemOptionStruct` |
| 0x14 | `iac_itemcreate(id, iti*, char* opt)` (Z11 §4.3 GM `-o` / `-u` options) | 0x74 / 0x78 | `iac_Get` / `SetRandomOptionChangeCount` |
| 0x18 | is-lot (base 1, non-stackable classes 0) | 0x7c / 0x80 / 0x84 | `iac_Get` / `Set` / `ClearItemOptionUpgrade` (§3.5.2) |
| 0x1c / 0x20 | `iac_GetLot` / `iac_SetLot` | 0x88 | `iac_SetFurnitureKey` |
| 0x24 | `iac_equipbriefinfo` (Z18) | 0x8c / 0x90 / 0x94 / 0x98 | `iac_GetEndureEndTime` / `SetEndureEndTime` ×2 / `SetEndureGrade` |
| 0x28 | `iac_ItemClass` | 0x9c / 0xa0 | `iac_Get` / `SetChargedNumber` (Z17) |
| 0x2c | `iac_DropItemMake` (Z18) | 0xa4 / 0xa8 | `iac_Get` / `SetIsPutOnBelonged` |
| 0x30 | `iac_Getupgrade` | 0xac | `iac_Getitemchest` (Capsule) |
| 0x34 / 0x38 | `iac_GetDeteleDateTime` / `iac_SetDeteleDateTime` | 0xb0 | `iac_SetUseableDateTime` (Capsule) |
| 0x3c / 0x40 | `iac_FoodEat` / `iac_GetHungry` (Z13) | 0xb4 … 0xc8 | Riding `iac_Set`/`GetHP`, `Set`/`GetGrade`, `Set`/`GetRareFailCount` |
| 0x44 | `iac_Getitemchest` (ItemChest, Z12) | 0x48 / 0x4c / 0x50 / 0x54 | `iac_wptitle_Setlicense` / `mobkilladd` / `Gettitle` / `Settitle` (§3.5.3) |

Small per-class bodies (each a field read / write at the `ShineItemAttr_*` offset, (pdb2016) layouts):

| Function | Class(es) sharing it | Body |
|---|---|---|
| `iac_fill2buffer` / `iac_fill2struct` FUN_00640510 / FUN_006405a0 | Amulet | copy 0x3e bytes; advance `0x26 + 3·(attr[0x25] >> 1)` (option count of `option`) |
| FUN_00640540 / FUN_006405d0 | Weapon | copy 0x59; advance `0x41 + 3·(attr[0x40] >> 1)` |
| FUN_00640570 / FUN_00640600 | Armor, Shield, Boot, Bracelet | copy 0x25; advance `0xd + 3·(attr[0xc] >> 1)` |
| FUN_0063e8b0 / FUN_0063ea90 | BindItem | copy 0x65; advance `1 + 10·attr[0]` |
| FUN_0063e8e0 / FUN_0063eac0 | ItemChest | copy 0x41; advance `1 + 8·(attr[0] & 0xf)` |
| FUN_0063e890 / FUN_0063ea70 | Decoration | `deletetime`, `IsPutOnBelonged`: 8 |
| FUN_0063e980 / FUN_0063eb70 | Capsule | `content` key (8), `useabletime` (4): 0xc |
| FUN_0063e830 / FUN_0063eb50 | ByteLot and the 8 other byte-lot classes | 1 |
| FUN_0063e850 / FUN_0063ea30 | WordLot, QuestLot, KQStep, ActiveSkill | 2 |
| FUN_0063e950 / FUN_0063eaf0 | DwrdLot, MiniHouseSkin, Amount, CostumWeapon / Shield, ActionItem | 4 |
| FUN_0063e970 (both slots) | SkillScroll, WeaponTitlaLicence, GBCoin | advance 1, nothing written or read: **(original bug) Z31-B4**, the zone copy of D07-B14 (one stale send-buffer byte per such item in 0x1047, 0x3001, DB records) |
| `iac_GetAttrSize` FUN_00640630 / FUN_00640650 / FUN_00640670 | Amulet / Weapon / Armor group | the advance values above |
| FUN_0063ec20, FUN_0063ec40, FUN_0063ec50, FUN_0063ec70, FUN_0063eca0 | DwrdLot group / Decoration / BindItem / ItemChest / Capsule | 4 / 8 / `1 + 10·portalnum` / 0x41 (full, unlike the writer) / 0xc |
| `iac_ItemClass` FUN_0063e490, FUN_0063e4b0, FUN_0063e500, FUN_00640080 | Enchant, Capsule, Bracelet, NoEffect | 0x22, 0x1d, 0x26, 0x21 |
| `iac_Getupgrade` FUN_0063e380 / FUN_0063e3b0 | Amulet (+ Bracelet) / Weapon, Armor group | `upgrade` byte (Amulet +8, Weapon / Armor +0) |
| `iac_GetDeteleDateTime` FUN_0063e4f0 / FUN_0063e390 / FUN_0063e3c0 | Amulet, Bracelet, Decoration, MiniHouseSkin, ActionItem / Weapon / Armor group | `&deletetime` (+0 / +0x3b / +7) |
| `iac_GetItemOptionStruct` FUN_0063e5d0 / FUN_0063e5e0 / FUN_0063e5f0 | Amulet / Weapon / Armor group (base: null) | `&option` (+0x25 / +0x40 / +0xc) |
| `iac_GetRandomOptionChangeCount` base FUN_0063e600 → 0xFF; FUN_0063e610 / FUN_0063e630 / FUN_0063e650; `Set…` FUN_0063e620 / FUN_0063e640 / FUN_0063e660 | Amulet / Weapon / Armor group | `randomOptionChangedCount` (+0x24 / +0x3f / +0xb); callers the random-option handlers FUN_0051dd40 / FUN_00520e40 (Z05 §8.4) |
| `iac_GetIsPutOnBelonged` FUN_0063ff50 / FUN_0063ff60; `iac_SetIsPutOnBelonged` FUN_0063ffc0 / FUN_0063ff80 (returns 1) | Amulet, Decoration, Bracelet / Weapon, Armor group | `IsPutOnBelonged` (+4 / +3); readers: equip (FUN_0052b8d0, also the only writer), `iba_Judge` FUN_00648870, `iba_CanInvenReloc` FUN_00648910, `sp_HorseItemSave` FUN_0045e810 |
| `iac_SetUseableDateTime(item, hours, tm, flag)` FUN_006404b0 | Capsule | `iac_SetEndTime(&useabletime, …)`; callers `sp_MakeCapsuleItem` FUN_0049cce0, `ii_ItemMoneyBuyAll` FUN_005259a0 (Z05 §6.3) |

#### 3.5.1 Items created from a reward row (`iac_itemcreate`, vt 0x10)

Only caller: `TreasureChestMaker::tcm_ItemMake(ShineReward*, clsmask)` FUN_00595d00, used by `sp_KQReward`
FUN_0052da70 (kingdom-quest rewards). `ShineReward` (0x42, pdb2016): `+0x24 Quantity`, `+0x28 u16 Upgrade[10]`
(per-mille weights), `+0x3c u16 OptionDegree`.

```pseudo
ItemAttrCls_ByteLot / WordLot / DwrdLot::iac_itemcreate        @ FUN_0063f5b0 / FUN_0063f5d0 / FUN_0063f5f0
    lot = (u8 / u16 / u32) reward.Quantity
ItemAttrCls_Amulet::iac_itemcreate                             @ FUN_0063f610
    vt 0x14(id, iti, "-o"); OptionCardStack::ocs_make(itemoptiondata.iod_optionlist[reward.OptionDegree], &attr.option)
ItemAttrCls_Bracelet::iac_itemcreate                           @ FUN_0063f7a0
    vt 0x14(id, iti, "-o"); ocs_make(…[OptionDegree], attr + 0xc)          # Bracelet.option
ItemAttrCls_Armor::iac_itemcreate                              @ FUN_0063f700   (Armor, Shield, Boot)
    vt 0x14(id, iti, "-o"); attr byte +2 (upgradefailcount) = 0
    r = random(1000); u = first i < 10 with r < Upgrade[i] (subtracting each weight), none → 0; attr.upgrade = u
    ocs_make(…[OptionDegree], attr + 0xc)                                 # Armor.option
ItemAttrCls_Weapon::iac_itemcreate                             @ FUN_0063f650
    as Armor (upgrade roll, upgradefailcount = 0), options into attr.option (+0x40), then
    s = EnchantSocketRateData::GetSocketRateData(); if s: n = s.vt[0](itemid); attr.maxSocketCount = n < 2 ? n : 2
ItemAttrCls_Decoration::iac_itemcreate                         @ FUN_0063f780
    attr.deletetime = 0; attr.IsPutOnBelonged = SPOBI_NOT_BELONGED        # no "-o" call
other classes: base vt 0x10 = FUN_004c2450 (empty)
```

#### 3.5.2 Amulet upgrade options (vt 0x7c / 0x80)

The amulet attribute keeps a second option list `UpgradeOption` (+0xb, `ItemOptionStorage`: `fixed` byte = bit 0
identified, bits 1-7 count; up to 8 `{u8 type, u16 value}` elements from +0xc), filled by accessory upgrades.

```pseudo
ItemAttrCls_Amulet::iac_GetItemOptionUpgrade(item, u8 type) → u16           @ FUN_0063e670
    type ≥ 15: 0; the value of the first element with that type, else 0
ItemAttrCls_Amulet::iac_SetItemOptionUpgrade(item, u8 type, u16 value)      @ FUN_0063e6f0
    type ≥ 15 or item null: return
    value == 0: remove the element of that type (later elements move down, last cleared), count − 1
    else: an element of that type exists → its value = value; otherwise, count < 8 → append {type, value}, count + 1
          (count == 8: ignored)
```

Callers: `AccUpGradeDataBox::augdb_RandomOptionUpgrade` FUN_005c5c60 (Z11 §4.3 GM item creation and the upgrade
path) for both; the getter also from `FillRandomOption` FUN_004ca9e0 and the moves / split of §3.2 slot 0x7c's
callers. Other classes inherit the base bodies (getter 0, setter / clear no-ops).

#### 3.5.3 Weapon licence slots (vt 0x48 … 0x58)

A weapon has three `mobkills` slots at +7 (`{u16 monster; u32 killcount:28, reserved:4}`, monster 0xFFFF = free),
`CharacterTitleMobID` +0x19 and `usertitle[21]` +0x1b (Z08 §7.1 is the request).

```pseudo
ItemAttrCls_Weapon::iac_wptitle_Setlicense(iti, u16 mob, Name5* owner) → int        @ FUN_0063fb20   (vt 0x48)
    any slot.monster == mob: return 1                    # 0x9BB "Cannot register the same monster."
    first slot with monster 0xFFFF:
        if all three slots were free: usertitle = owner (20 bytes) + NUL      # first licence names the weapon after the owner
        slot.monster = mob; return 0                     # killcount unchanged
    return 2                                             # no free slot → 0x9BC
ItemAttributeClass::iac_wptitle_Setlicense             @ FUN_0063fb10: return 3      # not a weapon → 0x9BD
ItemAttrCls_WeaponTitlaLicence::iac_wptitle_Getlicencemob(mobbox, itembox, iti) → u16  @ FUN_0063fcb0   (vt 0x58)
    ItemInfo row of iti.itemid (index check asserts "ItemDataBox::operator [] :Invalid Item index");
    mob id = MobDataBox B-tree lookup of InxName + 4 (the licence item's InxName minus a 4-char prefix); missing → 0xFFFF
ItemAttributeClass::iac_wptitle_Getlicencemob          @ FUN_0063fca0: 0xFFFF
ItemAttrCls_Weapon::iac_wptitle_mobkilladd(iti, mob, n) → u32   @ FUN_0063fbd0 (vt 0x4c)
    slot with monster == mob: killcount = (killcount + n) & 0x0FFFFFFF (reserved bits kept); return killcount + n (unmasked)
    none: 0xFFFFFFFF
ItemAttrCls_Weapon::iac_wptitle_Gettitle(iti) = &usertitle        @ FUN_0063fc30 (vt 0x50); base FUN_0063fc20 → "" (nullstr)
ItemAttrCls_Weapon::iac_wptitle_Settitle(iti, _, char[21] t)      @ FUN_0063fc40 (vt 0x54): strcpy(usertitle, t) (no length check); true
```

Callers: vt 0x48 and 0x58 from `sp_NC_WT_LICENSE_REQ` FUN_0059e410 (Z08 §7.1); vt 0x58 also from the item-use
`uib_AfterCast` paths FUN_00540080 / FUN_0059a530. No call through vt 0x4c, 0x50 or 0x54 was found: kill counts are
updated inline by `so_weapontitle` FUN_0059e190 (Z18 knowledge, weapon title levels) *(inferred: those three are
unused)*.

### 3.6 Item mall goods (`ItemMall`, `ItemShop.shn`)

```pseudo
ItemMall::im_Load(mall)                                        @ FUN_00493250   (zs_start_moon, Z10 §7.1)
    read "../9Data/Shine/ItemShop.shn" (row ItemShop: u32 goodsNo, char InxName[32], u32 Lot)
    mall.im_Goods = 0
    for each row r: s = the set with isl_Code == r.goodsNo; s ? im_AddSet(s, r) : im_NewSet(r)
ItemMall::im_NewSet(mall, r)                                   @ FUN_00492340
    im_Goods > 0x1fff: assert "ItemMall::im_NewSet : Too many Goods"; ShineExit
    im_Booth[im_Goods] = {isl_Code = r.goodsNo, isl_NumOfSet = 0}; im_AddSet(that, r); im_Goods += 1
ItemMall::im_AddSet(mall, set, r)                              @ FUN_00492060
    isl_NumOfSet > 9: assert "ItemMall::im_NewSet : Too many Set"; ShineExit("ItemMall::im_AddSet")
    item = ItemInfo B-tree[r.InxName] (missing: assert "ItemMall::im_AddSet : Null Item", ShineExit)
    set.isl_SetItem[isl_NumOfSet++] = {item, lot = r.Lot}
ItemMall::im_FindStruct(mall, goodsNo) → set or null           @ FUN_00492020   (linear search)
```

So a goods number is a package of up to 10 `{item, lot}`. The only reader is the premium-item withdrawal
`sp_NC_ITEM_CHARGED_WITHDRAW_REQ` FUN_00492660 (Z04 §8.2, "goods table … by goodsNo"). A bad row stops the zone at
start-up.

### 3.7 Charged inventory, charged buffs, belong attribute: destructors and helpers

- `CChargedItem::Clear` FUN_00632440: `m_NumOfChargedItem = 0`; from `so_ply_FillChargedInven` FUN_00492f30 (before
  a premium page is loaded, Z05 §7.4), `~ChargedInven` FUN_00549a50 and `~ShinePlayer` (§2.9).
- `ChargedItemEffectList::ChargedEffectList::~ChargedEffectList` FUN_00450da0 / its deleting destructor FUN_004514a0
  and `ChargedItem::~ChargedItem` FUN_00549a40: destroy the 50 `cel_Effect` elements (0xc bytes, empty destructor) and
  free the list array (Z24 §6.7 `ChargedItem` 0x2a0).
- `ItemBelongAttribute::IA_GetBelongTypeInfo(type)` FUN_00648810: `type > 10` → null, else `&iba_Array[type]`
  (`BelongTypeInfo` rows, Z04 §1.3); no direct caller (the accessors there index the array inline).
  Deleting destructor FUN_0064b1e0 → `~CItemAuthorityBase`.
- `ItemAttributeClass` deleting destructor FUN_006404e0: vftable reset, free.

### 3.8 `CellStack`: a path-search tracer, dead in 2016

Despite its name (and its place in the work list) `CellStack` is not an inventory class: it is a `Tracer` of a grid
path search, with `LinearStep` (straight-line stepping) and the global `PathFindTable pathfindtable` (cells ±1200
around the origin, `{pfc_flag, pfc_distance, pfc_from}`; `pathfindflag` = the current search stamp).

```pseudo
CellStack::CellStack(cs)                    @ FUN_004cec00   global `cellstack` (initializer FUN_00697120): list of 200 CellStackElement
CellStack::cs_Set(cs, arg, x, y, u16 d)     @ FUN_004ce760   |x|, |y| ≤ 1200 else assert "CellStack::cs_Set : Out of range";
    cs_push the 8 neighbours: orthogonal with d + 1000, diagonal with d + 1414 (0x586)
CellStack::cs_push(cs, arg, fx, fy, x, y, u16 d)   @ FUN_004ce140
    off the table: nothing; the cell already stamped in this search with a distance < d: nothing
    else push {x, y, from fx/fy, d, weight = d/64 + x² + y²}; stamp the cell (flag, d); cs_lastloc = it
    full: assert "CellStack::cs_push : Out of memory"
CellStack::t_trace(cs, arg) → Tracer*       @ FUN_004ce470   pop the minimum-weight element ("no path" when empty);
    if the cell is stamped with a distance ≤ the element's: return cs (pop again); else write {d, from} and continue with
    linestep.ls_Set(x, y) (LinearStep)
CellStack::t_continue(cs, arg, out, r)      @ FUN_004ce310   x² + y² < r (squared radius, not squared like LinearStep's r²): out = last pos, false; else true
CellStack scalar deleting destructor FUN_004cea30; ListEraser<CellStack::CellStackElement> destructor FUN_004ce3f0 (vftable only)
```

`LinearStep::t_trace` FUN_004ce880 hands over to `cs_Set` when the next straight-line cell is stamped. Nothing outside
these classes calls `LinearStep::ls_Set`, reads `pathfindflag` or uses a `Tracer*`: the tracer pair has no driver in
the 2016 zone (the mobs use `Navigator`, Z09 §9.5 / §28.7). The two `t_continue` radius tests differ (`r` vs `r²`) *(dead
code, not tagged)*.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z31-B1 | `so_ply_GuildReNameItemUseSuccess` / `…ReTypeItemUseSuccess` §2.1 | when the 128-entry ring slot was reused before the DB confirmed the item, only "Guild ReName / ReType Null" is logged | the rename / retype item is consumed, the guild is not changed, the client gets no answer | keep the name / type with the item use (as the megaphone, Z04-B7, same pattern) or refund |
| Z31-B2 | `so_ply_DecreaseDmgPassiveSkill` §2.6 | the BackgroundDefense reduction tests the attacking mob's facing against the mob→player direction | ordinary mob attacks (mob facing its target) are never reduced; hits from a mob facing away are, whatever the player's facing | test the player's facing against the player→mob direction (hits from behind the player) |
| Z31-B3 | `InvenCellReleaser_CoinChange::icr_Reserv` §3.3 | adds a pending coin reservation to `ReservedQuantity.cen`; no releaser fills `guild_token` or `gbcoin` | while a coin reservation is open the money checks (buy, upgrades, soul stones) see less money; the guild-token buy never subtracts reserved tokens | add coins to `gbcoin`, and reserve guild tokens under their own field |
| Z31-B4 | `ItemAttrCls_SkillScroll` / `WeaponTitlaLicence` / `GBCoin` `iac_fill2buffer` FUN_0063e970 §3.5 | advances the buffer by the 1-byte attribute without writing it (the reader skips it) | one stale send-buffer byte per such item in every item record (0x1047, 0x3001, DB requests); the client ignores it | write a 0 byte (same as D07-B14 on the Character server) |

## Not reconstructed / uncertain

- §2.1: who sends the item-use DB confirmation that runs `uib_Effect` is Z05's `InvenCellReleaser_ItemUse` path
  (Z04 §6.3); not re-read here.
- §2.4: whether any 2016 path was meant to call vt 0x4b0 (server-link loss) is inferred from the name only.
- §2.6: the intent of BackgroundDefense is taken from the skill name; no client text was checked.
- §3.1: the effect of a full lock list (192 open reservations: DB changed, memory not) is read from the void
  constructors; whether any path can reach 192 was not tested.
- §3.2: callers were found by slot offset on lock-list variables; calls through a copied pointer can be missed (vt 0x00
  `icl_IsLocked(&inv, ownIndex)` has none found).
- §3.5.3: no call through attribute vt 0x4c / 0x50 / 0x54 was found (slot scan only).

## Coverage boundary

Filled in by the sweep part; rows found so far:

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `0x74AC` / `0x74B4` request handlers, `0x74B0` / `0x74B8` WM answers | Z08 §8.1 / §8.2 (done) | documented there; §2.1 adds the commit half |
| `0x74B1` / `0x74B9` / `0x4021` / `0x4032` on the WM | W03, W05 (done) | the WM handlers are cited there (W03 rename / retype, W05 table rows) |
| `0x4022` on the Character server | D02 (done) | `usp_SpamBlock_setTime` documented in D02 |
| `uib_AfterCast` / item DB consumption | Z04 §6.3, Z05 (done) | common path, documented there |
| lock-list slots 0x10-0x30, 0x38, 0x48-0x54, 0x60, 0x68 and the releasers' `icr_Apply` | Z05 §1.2-§1.4, Z04 §1.4 (done) | documented there; §3.2 links them |
| `LinearStep::*`, `Tracer` (dead tracer pair with `CellStack`, §3.8) | this item, part 9 (path finding) | `CellStack` is in the part-2 bucket only by name; part 9 links §3.8 |
| `TreasureChestMaker::tcm_ItemMake` FUN_00595d00 (caller of attribute vt 0x10) | this item, part 8 (`TreasureChest*`) | §3.5.1 documents the callee side |
| item wire sizes per attribute class | D07 §1.3 (done) | same library on the Character server; §3.5 maps the zone addresses |
