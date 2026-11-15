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

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z31-B1 | `so_ply_GuildReNameItemUseSuccess` / `…ReTypeItemUseSuccess` §2.1 | when the 128-entry ring slot was reused before the DB confirmed the item, only "Guild ReName / ReType Null" is logged | the rename / retype item is consumed, the guild is not changed, the client gets no answer | keep the name / type with the item use (as the megaphone, Z04-B7, same pattern) or refund |
| Z31-B2 | `so_ply_DecreaseDmgPassiveSkill` §2.6 | the BackgroundDefense reduction tests the attacking mob's facing against the mob→player direction | ordinary mob attacks (mob facing its target) are never reduced; hits from a mob facing away are, whatever the player's facing | test the player's facing against the player→mob direction (hits from behind the player) |

## Not reconstructed / uncertain

- §2.1: who sends the item-use DB confirmation that runs `uib_Effect` is Z05's `InvenCellReleaser_ItemUse` path
  (Z04 §6.3); not re-read here.
- §2.4: whether any 2016 path was meant to call vt 0x4b0 (server-link loss) is inferred from the name only.
- §2.6: the intent of BackgroundDefense is taken from the skill name; no client text was checked.

## Coverage boundary

Filled in by the sweep part; rows found so far:

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `0x74AC` / `0x74B4` request handlers, `0x74B0` / `0x74B8` WM answers | Z08 §8.1 / §8.2 (done) | documented there; §2.1 adds the commit half |
| `0x74B1` / `0x74B9` / `0x4021` / `0x4032` on the WM | W03, W05 (done) | the WM handlers are cited there (W03 rename / retype, W05 table rows) |
| `0x4022` on the Character server | D02 (done) | `usp_SpamBlock_setTime` documented in D02 |
| `uib_AfterCast` / item DB consumption | Z04 §6.3, Z05 (done) | common path, documented there |
