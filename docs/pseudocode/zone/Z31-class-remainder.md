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
| 4 | the other `ShinePlayer` members | 127 / 1 954 |
| 5 | `ShineObject`, `ShineMobileObject` and the other object classes | 138 / 1 731 |
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

## 4. The other `ShinePlayer` members

The 127 `ShineObjectClass::ShinePlayer` members (with nested types) of the part-3 bucket. Most are one-line accessors
that other documents call by slot only (`p.vt[0x550]()` and so on); §4.10 lists them with their member and slot, so a
reader of an older document can resolve the slot. Members with logic get their own blocks. Slots are byte offsets into
the 986-entry `ShinePlayer` vftable. Callers come from a scan of `re-data/exports/zone-pdb/decomp.c` for
`+ 0x<slot>))(` and for `code **)(… + 0x<slot>)` (the pointer is loaded first and called later). Low slots (< 0x100)
are shared with every `ShineObject` class, so their caller counts include calls on other objects.

### 4.1 Unregistered commands: `sp_DummyFunction`

```pseudo
ShinePlayer::sp_DummyFunction(p, NETCOMMAND* cmd, int len, u16 index)     @ FUN_0054ebf0
    assert "Invalid protocol" with "%d/%d" (dept / cmd); InvalidProtocolLog: the same numbers and the player
    p.so_Disconnect(0x0686, deferred 0, silent 0)            (vt 0x5f8, Z01 §8.3)
```

The only pointer to it in the image is `shineprotofunc.pft_deffunc` (VA 0x851f2c). `` `dynamic_initializer_for_'shineprotofunc'` ``
FUN_006971d0 copies it into every slot of `pft_defaultdepartment`. Every department of the client parser that
registers no table (and every command with no `pft_Store`) therefore points to this function. A client that sends an
opcode the zone does not handle is disconnected. The reason code 0x0686 is the same one that Z01 §8.3 lists for "seed
request without packet encryption", so the WM cannot tell the two cases apart.

### 4.2 Packets to the client and the WM

```pseudo
ShinePlayer::so_ply_ChangeBriefInfo(p, ItemInventoryCell* cell, int slot)     @ FUN_0043e330   (vt 0x608)
    len = cell.iic_AttrProc.iac_equipbriefinfo (attr vt 0x24)(p.handle, gpp, &cell.item, slot, &titleMob, &titleLevel)
    len ≤ 0: return
    if p.so_GetCharacterTitle (vt 0x420).m_CurrentTitle == 10 (weapon title):
        CCharacterTitle::SetCurrentTitle(t, 10, titleLevel, titleMob, null)        @ FUN_0062e2e0
        # titleMob / titleLevel are written only by the weapon class (original bug) Z31-B5, the same as Z18-B9
    so_AllOfRange broadcast of gpp (len) around p (AxialListPacketBroadcast, all of range, flag 0)
```
This function is a twin of `so_ply_EquipmentChange` (Z18 §4.3) that always broadcasts. It sends one of the
brief packets of the Z18 §4.3 table (`0x1C02` / `0x1C03` / `0x1C04` / …). Its callers are both calls in
`InvenCellReleaser_EquipLocation::icr_Apply` FUN_0048ca20 (the equip / unequip DB answer, Z05 §1.3, Z17 / Z21
cite it as vt 0x608).

```pseudo
ShinePlayer::so_ply_BroadcastGuildInfo(p)              @ FUN_0056e5f0   (vt 0x824)
    brief.myguild = p.so_mobile_GetGuildRegnum (vt 0x818); brief.isGuildAcademyMember = p.so_ply_isAcademyGuildMember (vt 0x858)
    broadcast around p (flag 1): 0x106E NC_CHAR_SOMEONEGUILDCHANGE_CMD { u16 handle = p.handle, u32 guild = vt 0x818 }   (6)
ShinePlayer::so_ply_BroadcastGuildAcademyInfo(p)       @ FUN_0056e9b0   (vt 0x854)
    brief.myguild = p.so_ply_GetMyGuildAcademyNo (vt 0x85c); brief.isGuildAcademyMember = vt 0x858
    broadcast: 0x1096 NC_CHAR_SOMEONEGUILDACADEMYCHANGE_CMD { u16 handle, u32 guild = vt 0x85c }   (6)
```
Callers of vt 0x824 are the WM guild membership commands `wms_NC_GUILD_ZONE_MEMBER_JOIN_CMD` FUN_005a4230 and
`…_LEAVE_CMD` FUN_005a4340, `wms_NC_GUILD_ACADEMY_ZONE_MEMBER_GUILD_JOIN_CMD` FUN_0046ee20, and
`CGuildZone::Recv_NC_GUILD_ZONE_MAKE_CMD` FUN_005cca80 and `…DELETE_CMD` FUN_005cd1e0. Callers of vt 0x854 are
`wms_NC_GUILD_ACADEMY_ZONE_MEMBER_JOIN_CMD` FUN_0046eaa0 and `…_LEAVE_CMD` FUN_0046ebb0 (W03 / Z08 guild flows). On
the client, 0x106E (FUN_0049fe10) looks up the object by handle and stores `guild` at +0x2a8 with the academy flag
+0x2ac = 0. 0x1096 (FUN_0049fe50) stores the same with flag 1, and first sends `0x980B NC_GUILD_ACADEMY_LIST_REQ` when
a client window check (vt 0x104) is true *(window not identified)*.

```pseudo
ShinePlayer::so_ply_ChangeCen(p)                       @ FUN_00517f70   (vt 0x448)
    to p: 0x1033 NC_CHAR_CENCHANGE_CMD { u64 cen = p.sp_CharData…Cen }   (8; "Packet Too Long" assert otherwise)
```
Callers are every money change: `InvenCellReleaser_CenChange::icr_Apply` FUN_00487d50 (Z05 §1.4), `so_ply_PickupMoney`
FUN_0052fe80, `so_SendReceiptIncomeMoney` FUN_00511230, `so_ply_HolyPromiseWithdrawCenReward` FUN_00484100, and the
academy reward storage pair FUN_0046e430 / FUN_0046e750. On the client, FUN_004997d0 stores the u64. The value is
*(captured)* in P02 (packets-zone 0x1033).

```pseudo
ShinePlayer::so_ply_SendFieldAttribute(p)              @ FUN_0054aa20   (vt 0xd3c)
    if p.field (+0x7a) and field.option (+0xc):
        to p: 0x1827 NC_MAP_FIELD_ATTRIBUTE_CMD { u32 eFieldMapType = option byte +0x36 }   (annotated; 0 NORMAL … 4 TUTORIAL)
```
Its caller is `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 (Z01).

```pseudo
ShinePlayer::so_ply_SendSellItemInfo_Client(p)         @ FUN_00537970   (vt 0xe68)
    n = 0; len = CSellItemManager::simg_FillBuffer_Client(&p.sp_SellItemManager, &n, gpp+3)     @ FUN_0050e6b0
    len > 0: to p: 0x305B NC_ITEM_SELL_ITEM_LIST_CMD { u8 NumOfSellItem = n, PROTO_SELL_ITEM_INFO[n] }  (3 + len)
    # empty list: nothing is sent
simg_FillBuffer_Client(mgr, u8* n, PROTO_SELL_ITEM_INFO* out)                                     @ FUN_0050e6b0
    skip the first *n entries of the sell list (callers pass 0); per entry e:
        e.handle == 0xFFFF: assert "… : Invalid handle", next
        cls = itmattcontainer[e.itemid] (none: next)
        out = { u8 nDataSize = 2 + item bytes, u16 nHandle = e.handle, item = iti_fill2buffer_union(e.info, cls) }
        n += 1; stop when 8000 bytes are written
    return bytes written
ShinePlayer::so_ply_CanItemRepurchase(p) → bool        @ FUN_005379f0   (vt 0xe6c)
    the open NPC's role (sp_NPCProcess.npc.func) vt 0x38 (repurchase allowed); no NPC: false
```
`0x305B` is the repurchase list ("items sold to this merchant") *(inferred from vt 0xe6c and 0x3059 REPURCHASE)*. Its caller is `NPCRole_Merchant::nrm_ShopMenuOpen`
FUN_004c26b0 (Z02), when a merchant menu opens. The insert / delete updates `0x305C` / `0x305D` come from
`so_ply_SellItemList_Insert` FUN_00537a20 / `…_Delete` FUN_00537ba0 (Z04 §2.5, Z05), which test vt 0xe6c first. `sp_NC_ITEM_REPURCHASE_REQ`
FUN_00538580 also tests it. `nDataSize` counts the handle plus the item bytes. The next element starts at
`&nHandle + nDataSize`, which matches the 2016 PDB layout `{u8 nDataSize, u16 nHandle, SHINE_ITEM_STRUCT}`.

```pseudo
ShinePlayer::sp_SendSellItemInfo_World(p)              @ FUN_00537c30   (direct, from ws_save2worldmanager FUN_004536f0)
    gpp: opcode 0x4037 NC_CHARSAVE_SELL_ITEM_INFO_CMD; NumOfSellItem (payload +6) = 0
    len = CSellItemManager::simg_FillBuffer_Server(&p.sp_SellItemManager, &NumOfSellItem, payload+7)   @ FUN_0050e4d0 (Z18)
    len > 0: send 7 + len bytes to the WM (sock2wldman)
    # nWorldHandle (+0) and nCharNo (+2) are not written here: they are what the previous packet in gpp,
    # 0x4036 from sp_SaveUseItemMinimonInfo_World FUN_00563e70 (called just before, unconditionally), left at the same
    # offsets (original bug) Z31-B6
```
On the WM, 0x4037 is stored as the sell-item blob and echoed back as `0x1130` at the next zone login (W01 table "sell-item
info").

```pseudo
ShinePlayer::so_ply_PartyZoneLeaveCmd(p)               @ FUN_004cd9a0   (vt 0xd5c)
    to WM: 0x3861 NC_PARTY_ZONE_LEAVE_CMD { u32 nCharNo = vt 0x344 }   (assert text "cPartyJoin : Packet Too Long")
```
No call through vt 0xd5c exists, and the only pointer to the function is its vftable entry, so this copy is dead. The
live 0x3861 is built inline by the logout path (Z09 §17.7 "live player in a party").

### 4.3 Character save fillers (WholeSaver)

They fill one part of the save packets of `ws_save2DB` FUN_00455a10, `ws_save2worldmanager` FUN_004536f0 and
`ws_savelevel2worldmamager` FUN_00453580 (Z01 §8.4). Each returns the number of bytes written.

| Function | Slot | Writes | Size | Callers |
|---|---|---|---|---|
| `so_SaveStat(PROTO_NC_CHARSAVE_CHARSTAT_CMD*)` FUN_00454990 | 0x3ac | `chrregnum` (vt 0x344), `CurPwrStone`, `CurGrdStone`, `CurHPStone`, `CurSPStone` (each widened to u32), `CurHP`, `CurSP`, `statdistribute {Strength, Constitute, Dexterity, Intelligence, MentalPower, RedistributePoint}` | 0x22 | ws_savelevel2worldmamager, ws_save2DB |
| `so_SaveLevel(PROTO_NC_CHARSAVE_LEVEL_CMD*)` FUN_004548b0 | 0x390 | `chrregnum`, `level` (u8), `exp` (u64), `fame` | 0x11 | the same two |
| `so_ply_SavePKCount(PROTO_NC_CHARSAVE_PKCOUNT_CMD*)` FUN_00454230 | 0x388 | `chrregnum`, `pkcount` | 8 | ws_save2DB |
| `so_SaveGameData(PROTO_GAMEDATA_CMD*)` FUN_00454a90 | 0x3b0 | the 5-byte `sp_GameData` (`zone` byte, `client {partyno, nRaidNo}`) | 5 | ws_save2worldmanager |
| `so_SaveItem(PROTO_ITEM_CMD*)` FUN_00454ea0 | 0x3b4 | `numofitem = 0`, then `CharacterInventory::ci_FillBufferTotal` FUN_006444b0 of the whole bag | var. | none: no call through 0x3b4, so the function is dead (Z05's item saves use other builders) |
| `so_ply_SaveWeaponTitle()` FUN_0055a020 | 0x780 | `ItemInventoryCell::iic_WeaponTitleSave` FUN_0059e8a0 (Z05) on equipment slots 10 (left hand) and 12 (right hand) | – | ws_save2DB |
| `so_SetAutoSaveTime(now, s)` FUN_005608c0 | 0xac0 | `tAutoSaveTime` (+0x2aa40) = now + s × 10 (ticks of 100 ms *(inferred)*) | – | LOGINCOMPLETE, ws_save2DB (Z01 §8.4 "now + 6000" = 10 min) |

### 4.4 Combat factors

```pseudo
ShinePlayer::smo_ply_NormalAttackFactor(p) → per-mille          @ FUN_0042f910   (vt 0xf3c)
    p.smo_CharClass (+0xfbc).cc_ClassType (class vt 0x48) == 21 (Joker line):
        sp_MultiHitNotIndex == 3 ? 400 : 300
    else 1000
```
`smo_SwingDamage` FUN_00432f30 multiplies the swing damage by this rate (Z03 §3.2 "attacker's total damage rate").
Trickster-line normal hits are multi-hits, and each part carries 30 % (the last one 40 %) *(inferred from the counter
name)*. CharClass vt 0x48 returns the **first class of the line**: 1 Fighter … Knight, 6 Cleric … Guardian, 11 Archer
… Ranger, 16 Mage … Wizard, 21 Joker … Assassin, 26 Sentinel / Savior (see `docs/knowledge/Z31.md` §0 for Z12's name of
it).

```pseudo
ShinePlayer::so_ply_JobChangeDamageUp(p, ShineObject* target, int dmg) → dmg   @ FUN_00560e80   (vt 0xd2c)
    target null or target.so_ObjectType (vt 0x4d0) ≠ 5 (mob): return dmg
    row = class.cc_array[level < 151 ? level : 0] (PrimaryParameter, class +0x10858; level = vt 0x4d8 & 0xff)
    row null: return dmg
    return dmg × (row.JobChangeDmgUp (+0x80, u16) + rndbox[2] (0 or 1)) / 1000     (64-bit product)
```
Its callers are `RulesOfEngagement::roe_CalcDamage` FUN_00505c00 and `RuleOfEngagementHealAttack::roe_CalcDamage`
FUN_005002a0, as `att.vt[0xd2c](def, dmg)` (Z03 §4.5). `JobChangeDmgUp` is 1000 in the Fighter file
(Z12 §2.1), which gives a factor of 1.000 or 1.001 there.

```pseudo
ShinePlayer::so_ply_ReinforceRemoveWeapon(p)           @ FUN_004a4bf0   (vt 0x9a0)
    if class line == 11 (Archer): so_ply_ReinforceRemoveEquip (vt 0x9a8)(12); then (10)    # bow: both hands
    else: vt 0x9a8(12)
    smo_CastAbort (vt 0xed4); smo_BashStop (vt 0xed8)
ShinePlayer::so_ply_ReinforceRemoveShield(p)           @ FUN_004a4cd0   (vt 0x9a4)
    class line 6 (Cleric) or 1 (Fighter): vt 0x9a8(10)          # other lines: nothing (no shield)
```
They are the slot-12 / slot-10 cases of the "neutralization" roll in `MiscDataTable::mdt_PostSkillBlast` FUN_004a3a90
(Z09 §28.3). `so_ply_ReinforceRemoveEquip` FUN_004a4da0 (Z05, Z21) unequips the slot.

```pseudo
ShinePlayer::so_AttackRange(p, ShineObject*) → range   @ FUN_00559930   (vt 0x510)
    class line == 11 (Archer) ? 450 : 100                       # the argument is ignored
ShinePlayer::smo_ply_NextBashTime_AfterSkill(p, int swingTime)   @ FUN_0055ad60   (vt 0xec4)
    sp_SkillControl.duringnormalhit = 1
    if the timer's current work ∉ {TSCW_NORMALATTACK_SWING, TSCW_NORMALATTACK_DAMAGE} and sp_SkillControl.normalattackcontinue:
        sp_NextSwingTick = sp_LastSwingTick = 0
        if p+0x1ac == 0: ts_Set(&sp_TimerStr, FUN_00430bc0 (normal-attack swing), TSRT_DEFAULT, TSCW_NORMALATTACK_SWING, swingTime)
ShinePlayer::smo_CastAbort(p)                          @ FUN_00579e70   (vt 0xed4)  → ShineMobileObject::smo_CastAbort FUN_00579d50 (Z03, Z09)
ShinePlayer::smo_ply_SkillCastFail(p, u16 err)         @ FUN_00579480   (vt 0xee4)  sp_SkillFinish.scf_ErrorType = err
ShinePlayer::smo_CeaseFireSend(p)                      @ FUN_005794c0   (vt 0xf48)  CeaseFireSender::cfs_Routine FUN_00566820 (Z03)
ShinePlayer::so_IsAlliance(p, ShineObject* o) → bool   @ FUN_0054b010   (vt 0xe60)
    o null: false; else o.vt[0x8cc]() == p.vt[0x8cc]()           # side id; players return 2 (folded FUN_00647230)
```
vt 0x510 is read by the mob AI on its target (`so_mob_SelectWeapon` FUN_004ab720, `MobActionAttack::mab_Think`
FUN_004bba00, `mab_CaptivatePlayerAttack` FUN_004ba0d0, BackStep / AvoidOverlap / Chase `mab_Think`, Z09). vt 0xec4
is called after a skill (Z23 §3.1, with `sdi_ServInf.SwingTime`; the slot call sits in `ShineMobileObject::so_Routine` FUN_0056a080).
vt 0xed4 has 20 callers (targeting, equip, abstate set, captivate; Z03 / Z09). vt 0xee4 is called from
`SkillBlastEffectContainer::sbec_Routine` FUN_00437fc0 and `smo_SkillBash_Casting` FUN_0057bef0. vt 0xf48 is called
from `so_ply_Volley` FUN_004a44a0, `smo_SkillBash_Casting` and `smo_SkillBash_Blast` FUN_0057cd40. vt 0xe60 is the
"same side" test of Z03 §3.3 / Z09 §6.2 (`== 1` = friendly; 18 callers: enemy / aggro / heal scans).

Small combat accessors:

| Function | Slot | Body | Callers |
|---|---|---|---|
| `sp_IsEthereal` FUN_0042b040 | 0x9e4 | `so_AbnormalState_IsSet(STA_ETHEREAL 326)` (vt 0x3e4) | 17: damage-over-time, `so_mobile_IsImmortal`, item-use handlers |
| `sp_IsPreventAttack` FUN_004a9ca0 | 0x9e0 | `sp_PreventAttack` (+0x2a7f6) | `MobTargetAggresive2::ali_Work` FUN_004aa020 |
| `so_IsInWeapon` FUN_004c8eb0 | 0x938 | `sp_WeaponCell` (+0x2a7cc) set and its item ≠ 0xFFFF | `roe_MinWC` FUN_004fdbe0, `roe_MaxWC` FUN_004fea10 |
| `so_GetTargetInfo(o)` FUN_00568f90 | 0x42c | if p's target (`sp_Target.to_Object`, else `to_MainBody`) is `o`: `TargetObject::to_SendInform` FUN_0042b3f0 | `so_ply_Send2WhoTargetMe` FUN_00568ee0 |
| `so_CurrentTargetObject` FUN_0055adf0 | 0x75c | `to_Object`, else `to_MainBody` | 16 (GM `&` commands, …) |
| `so_GetTargetObject` FUN_0042b3e0 / `so_IsTarget` FUN_0042aca0 | 0xa04 / 0xa0c | `to_Object` / `to_Object ≠ null` | `AxialListTargetInform::ali_Work` FUN_0042b0b0, `to_SendInform`, mob tactics |
| `smo_ZeroHP` FUN_00559c00 | 0xf18 | `CurHP = 0` | `ShineMobileObject::so_KilledBy` FUN_00432240 |
| `so_ply_IncNGet_PKCount` FUN_0055a4e0 | 0x384 | `++pkcount`, returns it | `ShinePlayer::so_KilledBy` FUN_00433be0 |
| `so_ply_SetDamageAbsorb(n)` FUN_0055a730 / `…SetRemainingDamageAbsorb(n)` FUN_0055a750 / `…GetRemainingDamageAbsorb` FUN_0055a740 | 0xbdc / 0xbe4 / 0xbe0 | `sp_nDamageAbsorb` (+0x2aa8c) / `sp_nRemainingDamageAbsorb` (+0x2aa90) | `so_ply_CheckDamageAbsorption` FUN_00579860, `NPCAction::DamageAbsorbAction::exe` FUN_005c11a0, LOGINCOMPLETE (Z18, Z25) |
| `so_ply_IsRebirth` FUN_0055a760 / `so_ply_HealRate` FUN_0055a770 | 0xc44 / 0xc4c | `sp_RebirthState.bIsRebirth` / `.nHealRate` (+0x2aac4 / +0x2aac8) | `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90, `sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ` FUN_0057fa50 / none (0xc4c dead) |
| `so_ply_getSwingTime` FUN_00560af0 | 0xc68 | `sp_SwingTime` (+0x2aad0) | `UseItemRide::uib_CanUseItem` FUN_005988b0 |

### 4.5 Connection, socket and location

```pseudo
ShinePlayer::so_PacketBufferFlush(p) → bool            @ FUN_0055aa70   (vt 0x2e8)
    a = so_GetDataSocketStream (vt 0x2f8).vt[8](sp_SocketSession); b = so_GetGameSocketStream (vt 0x2fc).vt[8](sp_SocketSession)
    return a and b                                        # both streams are flushed, even when the first fails
ShinePlayer::so_SetSocketSession(p, ClientSession* s)  @ FUN_00559d90   (vt 0x2f0)
    sp_SocketSession = s; sp_SocketContainer.stream.vt[0](s)          # rebinds the packet container
ShinePlayer::so_ply_RemoveWhen(p) → RemoveWhen         @ FUN_0055a4a0   (vt 0x8ec)
    mode (vt 0x484) == 0, mode == 3 (dead) or sp_MiscFlag.JustRevive: REMOVE_NOW (0)
    else: sp_MiscFlag.JustLink ? REMOVE_NOW : REMOVE_LOGOUT (1)
```
vt 0x2e8 is called from `so_Routine` FUN_0056c790 (Z09 §2: "Char as write fail") and `ZoneServer::zs_disconnect`
FUN_005abb60. vt 0x2f0 is called from `zs_connect` FUN_005aa840 (attach) and `som_FreeObject` FUN_00557d70 (detach *(inferred)*).
`zs_disconnect` (Z09 §1) is the only caller of vt 0x8ec: on a socket cut it calls `so_Unmark(RemoveWhen, 1, 7)`
(vt 0x33c) and `som_FreeObject(handle, RemoveWhen, 0)`. A player in game who was not linking out gets REMOVE_LOGOUT,
which keeps the character in the world until the 10 s kick-out schedule (Z16 §4.4 `RemoveWhen`, `sp_Schedule_Kickout`).
A dead or just-revived player, or one in a link, is removed at once.

```pseudo
ShinePlayer::so_datasync(p)                            @ FUN_00559790   (vt 0x4c0)
    sp_CharData.logininfo.currentcoord = { x, y = live position (+0x66), dir = live direction (+0x6a) }
ShinePlayer::so_ply_reinforce_reloc(p, FieldMap* f, char map[12], x, y)   @ FUN_00559f30   (vt 0x6a8)
    p.field (+0x7a) = f; logininfo.currentmap = map (strncpy 12, after zeroing); position = (x, y); so_datasync
ShinePlayer::sp_LinkReplyCheck(p, LinkInformTemplete*) → bool   @ FUN_0050ec40   (direct)
    the open NPC's role vt 0x34 (link reply allowed); no NPC: false
```
vt 0x4c0 is called before a save or link: `so_LinkTo` FUN_0049ad30, `so_ply_LoginTutorialMap` FUN_00561450,
`wms_NC_CHAR_ZONE_CHARDATA_ACK` FUN_005a3590 and `so_ply_reinforce_reloc`. vt 0x6a8 has no caller and its only image
pointer is the vftable entry, so it is dead. `sp_LinkReplyCheck` is called from
`ZoneRingPacketFindInstanceDungeon::zrpb_Request` FUN_005a92e0 (Z14 instance-dungeon link through an NPC).

| Function | Slot | Body | Callers |
|---|---|---|---|
| `so_ply_GetClientSession` FUN_004c8df0 | 0xa70 | `sp_SocketSession` (+0x5e10) | `wms_NC_MAP_LINKRESERVE_ACK` FUN_0049b510, `PacketContainer::pcb_Append` FUN_004c8b20 |
| `so_PacketEncryptClass` FUN_00559700 | 0x4a8 | `&sp_Encryption` (+0x7e30) | `pcb_Append`, `ClientSession::zbs_Parsing` FUN_004fb9f0 |
| `so_SetPossibleNewConnect(b)` FUN_00549420 / `so_GetPossibleNewConnect` FUN_0055a5c0 | 0x330 / 0x334 | `sp_isPossibleNewConnect` (+0x2a800) | setters: 0x0806 seed, 0x1801 map login, class change / beauty-shop DB answers; reader `so_RefreshWMSSocket` FUN_00552190 (Z01 §8.2) |
| `so_ply_FromWhere(b)` FUN_0043c9c0 | 0x940 | `sp_ConnectFrom` (+0x2a7d4) = b | `wms_NC_MISC_CONNECTFROMWHERE_ACK` FUN_0043f2f0 (Z01) |
| `so_SetWaitTradeResFromDB(b)` FUN_005596a0 / `so_GetWaitTradeResFromDB` FUN_00559690 | 0x328 / 0x324 | `sp_tradestr.waitingTradeResFromDB` | `sp_NC_TRADE_DECIDE_REQ` FUN_00594870, `so_TradeBoardreset` FUN_00559eb0 / `so_LinkTo` (Z06 trade) |
| `so_LoginLocation` FUN_00559a50 | 0x4bc | `&sp_CharData.logininfo` | map marking (`so_MapMarking` FUN_00466470 …) |

### 4.6 Mini-game (dice Tai Sai) state on the player

`sp_MiniGame` (+0x5d00, `SHINE_MINI_GAME`) holds the mini-house game state: `nGameType` (`SMT_DICE_TAISAI` for the dice
table), `GameInfo.DiceTaiSai` (`BetInfo.nBetSumMoney`, 0x34 `nBetMoney` words, two more dwords at +0xd8 / +0xdc, the
leave flags `bGameLeaveReserve` / `bRoomLeaveReserve`) and `RoomLeavePos` (map name 12 + `LocateXY`). The callers are
the mini-house game (`ShineMiniHouse::so_mh_*`, Z06 §3) and its gamble twin (`CGambleDiceTaiSaiObject`,
Z32). Setters accept only 0 / 1 and only while `nGameType == SMT_DICE_TAISAI`, and return false otherwise.

| Function | Slot | Body |
|---|---|---|
| `so_GetDiceTaiSaiInfo` FUN_005110c0 | 0x19c | `&GameInfo` when Tai Sai, else null (11 `so_mh_*` callers) |
| `so_ClearDiceTaiSaiInfo` FUN_005110e0 | 0x1a0 | Tai Sai only: zero `nBetSumMoney`, the 0x34 bet words and +0xd8 / +0xdc; true (`so_mh_ClearGamerBettingInfo` FUN_00511990, `so_mh_DiceTaiSai_Enter` FUN_00511f30) |
| `so_GetDiceTaiSaiGameLeaveInfo(u8*)` FUN_00510f60 / `so_SetDiceTaiSaiGameLeaveInfo(b)` FUN_00510f90 | 0x184 / 0x188 | `bGameLeaveReserve` (`so_mh_ExcuteLeaveGame` FUN_00514860, `sp_NC_DICE_TAISAI_GAME_LEAVE_REQ` FUN_005151b0, mini-house login complete FUN_00571f20) |
| `so_GetDiceTaiSaiRoomLeaveInfo(u8*)` FUN_00510fc0 / `so_SetDiceTaiSaiRoomLeaveInfo(b)` FUN_00510ff0 | 0x18c / 0x190 | `bRoomLeaveReserve` (`so_mh_ExcuteLeaveRoom` FUN_00514660, `so_mh_EffectApply` FUN_00542520, `so_mh_PortalEffectApply` FUN_00542c70) |
| `so_GetMiniGameRoomLeaveMapInfo(map, xy)` FUN_00511070 / `so_SetMiniGameRoomLeaveMapInfo(map, xy)` FUN_00511020 | 0x198 / 0x194 | copy `RoomLeavePos` out / in; null arguments: false (setters: effect / portal apply, `sp_NC_MINIHOUSE_KICKOUT_REQ` FUN_00575500) |
| `so_SetCTDiceTaiSaiWin(n)` FUN_005113c0 / `so_SetCTDiceTaiSaiSet` FUN_005113f0 | 0x1b4 / 0x1b8 | `CCharacterTitleZone::CT_WinDiceTaiSaiWin` FUN_005cc490 (n ≠ 0) / `CT_WinDiceTaiSaiSet` FUN_005cc4c0 (title counters, Z06 §3) |
| `so_Gamble_IsJoinThisGamble(t)` FUN_00615e80 / `so_Gamble_SetGambleType(t)` FUN_00615ec0 | 0xb20 / 0xb28 | `sp_Gamble_JoinType` (+0x2aa78) `== t` / `= t` (`GAMBLE_TYPE` 0 BASE, 1 DICETAISAI, 2 SLOTMACHINE; gamble-house callers, Z32) |

### 4.7 Party, raid and guild state

| Function | Slot | Body | Callers |
|---|---|---|---|
| `so_PartyRegistNumber` FUN_00559dd0 | 0x550 | `sp_GameData.client.partyno` (0xFFFF = none) | 106 (party scans, abstates, …) |
| `so_SetParty(n)` FUN_00559760 | 0x574 | `partyno = n` | `PartyManufacture::pm_Break` FUN_004cc520 / `pm_MemberLeave` FUN_004cc7e0 / `pm_Sendmemberinfo` FUN_004cc9f0, `so_SetRaid` FUN_005604a0, `ac_outraid`, `sp_SendPartyMemberInform` (Z08) |
| `so_PartyRegistNumber_InAttack` FUN_004811b0 | 0x560 | = vt 0x550 | `HitMeList::EnemyList::el_Store` FUN_00482070, magic-field heal, NPC actions |
| `so_GetRaidNumber` FUN_00559de0 / `so_SetRaidNumber(n)` FUN_00559df0 | 0x554 / 0x558 | `sp_GameData.client.nRaidNo` | LOGINCOMPLETE, exp distribution, … / `so_SetRaid` |
| `so_GetRaid` FUN_00560470 | 0xa84 | `sp_RaidSlot` (+0x2926c) | 63 |
| `so_GetPartyGroup` FUN_00559e10 | 0x55c | raid ≠ 0xFFFF → `PartyGroup_Raid` (2), party ≠ 0xFFFF → `PartyGroup_Party` (1), else `Alone` (0) | none: no call through 0x55c, so the function is dead |
| `so_ply_Setpartyslot(PARTY_SLOT*)` FUN_005493f0 | 0x774 | `sp_LastPartyParam.pmi_PartySlot` | LOGINCOMPLETE, `pm_HandleSet` FUN_004cc610, `pm_Sendmemberinfo`, `wms_PartyMemberRefresh` FUN_004cd1a0, `so_FirstActionAfterSocketConnect` FUN_00554870 |
| `so_ply_partymemberlogin(charNo)` FUN_0056e550 | 0x778 | `sp_PartyInformInit` FUN_004cd6d0 (Z08) | LOGINCOMPLETE |
| `so_ply_PartyInformInit` FUN_004cd720 | 0x8dc | `PartyMemberInform::pmi_Clear(&sp_LastPartyParam)` FUN_0056d980 | `sp_PartyInformInit` |
| `so_ply_SetMyGuild(GUILD_ZONE*)` FUN_0055a200 / `so_ply_SetMyGuildAcademy(GUILD_ZONE*)` FUN_0055a510 | 0x820 / 0x864 | `m_pMyGuild` (+0x2a320) / `m_pMyGuildAcademy` (+0x2a32c) | the guild / academy membership commands of §4.2, `so_FirstActionAfterSocketConnect` |
| `so_ply_isIAmGuildAcademyMaster` FUN_0055a550 | 0x868 | not an academy member (vt 0x858) and in a guild (vt 0x818 ≠ 0) | none: dead |
| `so_ply_GetMyGuildStorageHandle` FUN_0055a210 / `so_ply_SetMyGuildStorageHandle(h)` FUN_0055a220 | 0x830 / 0x834 | `&sp_GuildStorageManager.storagehandle` / `= h` | guild storage (24 / `so_ply_GuildStorageDeactivate` FUN_00477420, Z08) |
| `so_ply_SetMyGuildAcademyRewardStorageHandle(h)` FUN_0055a250 | 0x840 | `sp_GuildAcademyRewardStorageManager.storagehandle = h` | LOGINCOMPLETE, `so_ply_GuildAcademyRewardStorageDeactivate` FUN_0046f7f0 |
| `so_ply_GuildStoreGradeFill(g)` FUN_00475b00 / `so_ply_isGuildStoreGrade` FUN_00475b10 | 0x5ec / 0x5f0 | `GuildStoreageGrade` (+0x5e0d) `= g` / `== 0` | `wms_NC_GUILD_STORAGE_WITHDRAW_GRADE_ACK` FUN_005a48f0 / guild-token buy, `sp_ItemReloc`, storage withdraw, split (Z08 §8.2) |

### 4.8 NPC menus, trade, booth, tent

```pseudo
ShinePlayer::so_TentDistance(p, SHINE_XY_TYPE* xy) → bool   @ FUN_0058cc50   (vt 0x768)
    mode (vt 0x484) ∉ {4, 5}: true                    # not resting / not in a booth: does not block *(inferred from Z02 §7)*
    else: dist²(p, xy) > 2025 (45 units)
ShinePlayer::so_ply_BoothTrade(p, ShinePlayer* buyer, PROTO_NC_BOOTH_ITEMTRADE_REQ* req)   @ FUN_0058cd70   (vt 0x7cc)
    mode == 5 (booth): sp_Booth.boardpnt vt 0x1c(p, buyer, req)        # Z06 booth trade
```
vt 0x768 is asked by `ShineObject::so_TentPoint` FUN_0058d260 for each object in the rest / booth / tent scan (Z02 §7;
the NPC version is Z09's `ShineNPC::so_TentDistance` FUN_0058cbf0). vt 0x7cc is called from `sp_NC_BOOTH_ITEMTRADE_REQ`
FUN_0058da30 (Z06).

| Function | Slot | Body | Callers |
|---|---|---|---|
| `so_ply_dupmenu_Set(m)` FUN_00559fb0 / `so_ply_dupmenu_close(m)` FUN_00559f80 | 0x6b0 / 0x6b4 | set / clear bit m of `sp_NPCProcess.duplicatemenustate.dmc_Control` | `NPCRole_Merchant` / `StoreManager` / `MenuOpen` `nrb_Role` (set) and `nrb_EndOfTrade` (clear); the upgrade REQs and DB ACKs (Z04, Z05) |
| `so_ply_dupmenu_canmenuopen(m)` FUN_00559fa0 | 0x6ac | `DuplicatedMenuControl::dmc_CanMenuOpen` FUN_00460d70: false if any open menu bit b has `dmc_Table[b][m] ≠ 0` (7 × 7 table), else true | the same `nrb_Role`s and upgrade REQs |
| `so_ply_ServerMenuactor_sma_IsReady` FUN_005924b0 | 0x978 | `ServerMenuActor::sma_IsReady` FUN_0050ec90 | `sp_NC_TRADE_PROPOSE_REQ` FUN_005925a0, `sp_NC_TRADE_PROPOSEYES_ACK` FUN_00592cd0 |
| `so_ply_ReactionNpcHandle` FUN_0055a710 | 0xb40 | `nReactionNpcHandle` (+0x2aa80) = `sp_NPCProcess.npchandle` | buy (`ii_BuyAll` FUN_00523ce0, `ii_BuyLot` FUN_005241f0, guild-storage buys), capsule / magic container make |
| `so_TradeStructure` FUN_00559670 / `so_TradeBoard` FUN_00559680 | 0x31c / 0x320 | `&sp_tradestr` (+0x17d4c) / `&sp_tradeboard` | trade handlers (Z06) |
| `so_ply_TreasureChestLocationManager` FUN_0055a280 | 0x30 | `&sp_ChestItemBox` (+0x29326) | slot 0x30 is shared by every object type (77 call sites: chest, GM item commands, …) |

### 4.9 Inventory arrange and storage

```pseudo
ShinePlayer::sp_ArrangeInven_nClassifyGrade(p, AI_ArrangeInven* e) → rank   @ FUN_00560df0   (direct, from so_ply_ArrangeInven FUN_00563500)
    e, e.pInvenCell, e.pIAC, e.pITI all set, by e.pItemData.data.ItemGradeType:
        GT_CHARGE 0, GT_MYTHIC 1, GT_LEGENDARY 2, GT_UNIQUE 3, GT_SET 4, GT_RARE 5, GT_NAMED 6, GT_NORMAL 7
    anything else / missing pointer: 0xFF
ShinePlayer::so_ply_ArrangeInvenInit(p)                @ FUN_00560d70   (vt 0xd0c, from LOGINCOMPLETE FUN_00443390)
    so_ply_SetArrangeInven (vt 0xd18)(0); sp_ArrangeInvenDelayCheckTime (+0x2ab1c) = now
ShinePlayer::so_ply_StorageSize(p) → cells             @ FUN_0055a2b0   (vt 0x490, from sp_ItemReloc FUN_00536780)
    m = sp_ChargedItem.ci_Effect.cec_MoreStorage: m > 2 ? 144 : (18 + 9m) × 4   (72 / 108 / 144, §3.4)
```
The grade rank is one key of the auto-arrange sort (`AI_ArrangeInven` 0x18 bytes: cell, attribute class, total
information, item data, `Classify`; Z04 §12.5). The rest of that sort and its scheduling are §11 (part 10).
`so_ply_ArrangeInvenInit` arms the 5 s delay check of 0x304A (Z04 §12.5) at login.

### 4.10 Plain accessors

| Function | Slot | Returns | Callers (count / examples) |
|---|---|---|---|
| `GetRTTI` FUN_00559650 | 0x0 | `&ShinePlayer::m_RTTI` | `ShineDynamicCast<…>` (e.g. FUN_00409840) as `vt[0]`, walking `m_pkBaseRTTI` (§5) |
| `so_ItemInventory` FUN_00559660 | 0x47c | `&sp_Item.itembag` (`CharacterInventory`) | 23 (item breaker, relocation, item search) |
| `so_ply_GetItemLotInspector` FUN_00490bd0 | 0x96c | `&sp_ItemLotInspector` (+0x1ea8) | `ItemRelocationManager::irm_Move` FUN_00531860 / `irm_Exchange` / `irm_Merge` / `irm_Split_N_Merge` |
| `so_ply_CurrentMoney` FUN_00559710 | 0x434 | `Cen` (u64) | 45 |
| `so_ply_CurrentExp` FUN_00559720 | 0x438 | `Experience` (u64) | LOGINCOMPLETE, ws_save2DB, `CQuestZone::Send_NC_QUEST_DB_DONE_REQ` FUN_005bbe60 |
| `so_ply_CurrentFame` FUN_00559730 / `so_ply_StoreFame(f)` FUN_0055a080 | 0x43c / 0x444 | `fame` / `fame = f` | buy, quest done / `InvenCellReleaser_FameChange::icr_Apply` FUN_00487e60 |
| `so_GetSP` FUN_00559b80 | 0x4ec | `CurSP` | 32 |
| `so_GetClass` FUN_005598c0 | 0x4dc | `shape.chrclass` | 11 (class change, GM event class check, booth search) |
| `so_ply_GetGender` FUN_0055a1e0 | 0x804 | `shape.gender` | KQ score, `WeddingHall::wh_Reserv` FUN_005a0810, quest gender |
| `so_GetStatDistStr` FUN_0055a1c0 | 0x424 | `&statdistribute` | the five `so_ply_FreeStat*` (Z12) |
| `so_GetWMSHandle` FUN_00559a20 | 0x340 | `sp_extra.pecd_worldmanagerhandle` | 41 |
| `so_GetUserRegistNumber` FUN_00559a40 | 0x348 | `sp_CharData.usrregnum` | 35 |
| `so_extradata` FUN_00559750 | 0x570 | `&sp_extra` | none: dead |
| `so_Getabstatebit` FUN_00559dc0 | 0x4a0 | `&brief.abstatebit` | 11 (abstate bit set / reset) |
| `so_FillBriefInformation(dst)` FUN_0055abf0 | 0x4c4 | copies the brief (`PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD::operator=`) | the `BriefInfoExchanger` visitors (§6) |
| `so_ply_HideMyIdentity` FUN_0055a4f0 | 0x18 | `BriefInformationCharacter::bic_HideMyIdentity` FUN_0043c180: brief `charid` = "???" (code zeroed), title {0, 0, 0xFFFF}, `myguild = 0` | slot 0x18 is called on every object type (99 call sites); the sites that reach a player were not separated |
| `so_ply_SoloingMode` FUN_005597b0 | 0x79c | `sp_MiscFlag.SoloingMode` (p+0x5cb8 bit 3; Z02 "hide-except-me") | packet broadcast visitor, brief senders, KQ top |
| `so_ply_GetChatFontColorID` FUN_0055a840 / `so_ply_SetChatFontColorID(c)` FUN_0055a860 | 0xe2c / 0xe30 | `sp_nChatFontColor` (+0x2ab5d), read only while `cec_ChatFontColor` or `cec_ChatColor` == 1 (else 0) | `so_Chat` FUN_00458c90 / `wms_NC_CHAR_ZONE_CHAT_COLOR_CMD` FUN_0044d4a0, `so_ply_ChatColorInfoApply` FUN_00563ac0 (§2.8) |
| `so_ply_GetChatBalloonColorID` FUN_0055a870 / `so_ply_SetChatBalloonColorID(c)` FUN_0055a890 | 0xe34 / 0xe38 | `sp_nChatBalloonColor` (+0x2ab5e), read under `cec_ChatBalloonColor` or `cec_ChatColor` | the same |
| `sp_CharFreeStat_UnLock` FUN_0055a670 | 0xad0 | `sp_bCharFreeStatLock` (+0x5e0c) = 0 | LOGINCOMPLETE, `gds_NC_CHAR_TUTORIAL_FREESTAT_INIT_ACK` FUN_00468b70, `gds_NC_CHAR_FREESTAT_SET_DB_ACK` FUN_0058be50 (Z12) |
| `so_ply_GetTutorialInfo` FUN_00561520 | 0xdfc | `&sp_TutorialInfo` (+0x2ab44) | `wms_NC_CHAR_ZONE_CHARDATA_ACK`, tutorial save / get (Z07) |

### 4.11 Nested-type destructors

`NPCProcess::~NPCProcess` FUN_00549960 (its `duplicatemenustate`, `servermenuactor` and `currentmenu` members),
`BoothSell::~BoothSell` FUN_005499e0 (`StreetBoothBuy` / `StreetBoothSell` destructors), `SocketStream::~SocketStream`
FUN_00549810 (vftable reset to `PacketContainerBase`) and `LPInfo::~LPInfo` FUN_00549a60 (the `RecoverTick` member).
They run only from the unwind funclets of the `ShinePlayer` constructor and `~ShinePlayer` (§2.9). Their member
destructors are the empty fold FUN_00417480.

## 5. `ShineObject`, `ShineMobileObject` and the other object classes

The class tree and the type numbers are `docs/knowledge/Z01.md` §2. `ShineObject` has 933 vtable slots (up to vt 0xe90),
`ShineMobileObject` and its subclasses 986 (up to vt 0xf64), `ShineMob` and its subclasses 992. This section covers the base-class bodies:
the defaults that every class without its own override inherits. The per-class override tables are elsewhere: the mini-house in Z13 §1.8,
the pet in Z13 §6.2, the mover in Z13 §8.1, the door, effect object and servant in Z09 §13.1-§13.3, the mob, NPC and bandit in Z09 §5. For each slot
the row gives the default, the classes that keep it (abbreviations: O `ShineObject`, Di drop item, Ef effect object,
Mf magic field, Mh mini-house, Af axial flag, MO `ShineMobileObject`, P player, Do door, Mv mover, M mob, N NPC,
B bandit, S servant, Pe pet), the override and the callers of the slot. Callers were found by the slot scan of §1. Where the only
reference to a body in the image is its vtable entry and no `+ 0x<slot>` call exists, the row says "no caller".

### 5.1 Construction, copy and destruction

```pseudo
# The object pools are arrays allocated with new[] in ShineObjectManager::som_Initialize FUN_0055c260 (Z01 §4); an
# object is never deleted individually. The deleting destructors (vt 0x4) are therefore reached only by a pool's delete[],
# and no such call exists in the zone *(inferred: no `+ 4))(` call on an object, no direct call)*.
ShineObject::~ShineObject: abstract in the base vftable (vt 0x4 = _purecall FUN_006583ea)
ShineMobileObject::scalar_deleting_destructor(flags)       @ FUN_00556310 (vt 0x4 of MO)
    ~ShineMobileObject(this); if flags & 1: delete this
ShineMobileObject::~ShineMobileObject                       @ FUN_005554c0
    vftable = ShineMobileObject; ~Parameter::Container(smo_Param); empty fold FUN_00417480 on smo_Spy
    ~AbstateListInObject(smo_Abstate.abstatelist); empty fold on smo_MoveManager; ~ShineObject
    # called by ~ShineDoor FUN_00555ad0, ~ShineMob, ~ShinePlayer (§2.9), ~ShineMover FUN_0055e950 and the unwind funclets
ShineMobileObject::AS::~AS (smo_Abstate)                    @ FUN_005497d0
    free abstatelist.asl_List.l_Array; destroy the 0x74 AbstateElementInObject slots (0x1c bytes each); only in the
    constructor's unwind path
ShineMob::~ShineMob                                         @ FUN_00556340
    vftable = ShineMob; free sm_WeaponUseRate's buffer and zero its three words; ~EnemyList(sm_HitMeList);
    ~Actor(sm_ArtificalIntelligence.maa_MobActionStruct); ~Selector(….maa_TargetSelect);
    free sm_ReadyWeapon.nextblast's buffer and zero it; empty fold on sm_CurrRoamInterval; ~TargetAnalyser(sm_TargetAnalyser);
    empty fold on sm_WanderChat; ~ShineMobileObject
    # called by ~ShineBandit FUN_00556e20, ~ShineServant FUN_00556f50, ~ShinePet FUN_005571c0, ~ShineNPC FUN_00557b70,
    # the deleting destructors below and the som_Initialize unwind
ShineEffectObject::~ShineEffectObject                       @ FUN_00555370
    vftable = ShineEffectObject; empty fold on seo_DetachCheck; ~ShineObject
vector_deleting_destructor(flags) (vt 0x4) of ShineEffectObject FUN_00555f70 (array element 0x1d3 bytes),
    ShineDoor FUN_00556030 (0x1f14), ShineMob FUN_005579a0, ShineBandit FUN_00557940, ShineServant FUN_00557a00,
    ShineNPC FUN_00557d10:
    flags & 2: run the class destructor over the count stored before the array (_eh_vector_destructor_iterator_),
               flags & 1: delete[] the block; return the block
    else:      run the class destructor once; flags & 1: delete this
```

`ShineObject` copy (`operator=` FUN_00558890) copies `so_handle`, the slanted-list block (below), `so_LocateInfo`
(location pointer and direction), `so_layer` (`templyr` main / sub, `layer`), `so_Field`, `so_AIScript` (`LuaAi::operator=`
FUN_00557ac0: the `AIScript` flag and the 8 script entry names `Entrance`, `NPCClick`, `NPCMenu`, `MobDamaged`, `ObjectDied`,
`NPCAction`, `MobAttack`, `RankingValue` as `std::string` copies), `so_bIsMapMarking` and `so_eSightState`. Its only
callers are `List<ShineObject>::l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` (FUN_00558d20 … FUN_00558df0), a by-value
list template instance (part 9).

The slanted-list block `so_slantedlist` (+0x06, 0x60 bytes) holds the object's nodes in the map's two
coordinate-sorted lists (`SlantedCoordList`, layout in Z09 §9): `Xnode` / `Ynode`, the list links `Xlist` / `Ylist` (`cn_node`,
`cn_prev`, `cn_next`), `eventnumber[4]`, `listcheck.lcs_ListCheck[4]` and `LayerRegistInfo` (layer number, view type,
layer type / value). The copy is `operator=` FUN_00554660; the destructor FUN_00549660 (empty folds on the two lists, then
`~ObjectXCoordNode` on both nodes) runs only in the `ShineObject` constructor's unwind.

### 5.2 Run-time type: `GetRTTI` and `ShineDynamicCast<T>`

Every object class has its own `m_RTTI` (`ShineRTTI`: name, `m_pkBaseRTTI` = parent class) returned by vt 0x0
`GetRTTI`: `ShineObject` FUN_00554ed0 (used by O, Di, Ef, Af, which have no own RTTI object), `ShineMobileObject`
FUN_00555550, `ShineDoor` FUN_00555ae0, `ShineMagicField` FUN_00555c80, `ShineBandit` FUN_00556e30, `ShineServant`
FUN_00556f60, `ShineNPC` FUN_00557b80 (player: FUN_00559650, §4.10).

```pseudo
ShineDynamicCast<T>(ShineObject* o) → T*:                   @ FUN_00479410 (T = ShineNPC; one instance per T)
    if o == null: return null
    for r = o.vt[0x0]() (GetRTTI); r ≠ null; r = r.m_pkBaseRTTI:
        if r == &T::m_RTTI: return (T*)o           # single inheritance, no pointer adjustment
    return null
```

So a drop item or axial flag answers to `ShineDynamicCast<ShineObject>` only. The `ShineNPC` instance is called by
`GuildTournamentSystem::CaptureFlag` FUN_0047eae0 (part 8). The other instances are cited where they are used
(e.g. `<ShinePlayer>` in Z21, `<ShineMobileObject>` in Z25).

### 5.3 Map removal, handles, start-up

```pseudo
ShineObject::so_RetrateFromMap()  (vt 0x3f4; O, Mf, Mh, Af)                                @ FUN_00495ae0
    assert "ShineObjectClass::ShineObject::so_RetrateFromMap"            # nothing else; such objects are never retreated
    # overrides: MO / P / M / … FUN_00495d20 (sets smo_Flag.Retrate, Z09 §28, Z11), drop item FUN_00495c40 (Z09 §11),
    # effect FUN_00495cc0 (Z09 §13.2), door FUN_00495e50 (Z09 §13.1). 10 callers: map clear, mob vanish, &releasenpc, …

ShineObject::so_RetreatFromMapByImmeditely()  (vt 0x3f8; O, Di, Ef, Mf, Mh, Af)             @ FUN_00495b90
    this.vt[0x3f4]()                                                    # so_RetrateFromMap: removal at the next tick
ShineMobileObject::so_RetreatFromMapByImmeditely()  (vt 0x3f8; P, MO, Do, M, B, S, N, Pe, Mv) @ FUN_00495d80
    # its profiler string is the copied "…ShineMobileObject::so_RetrateFromMap"
    this.vt[0x3f4]()                                                    # sets smo_Flag.Retrate
    this.vt[0x33c](0, 1, 3)                                             # so_Unmark FUN_00553970: leave the sight (0x1805, Z13 §6.4)
    ShineObjectManager::som_FreeObject(handle, REMOVE_NOW, 100)         # Z01 §4.2
    # vt 0x3f8 has no caller in 2016 (both bodies referenced only by their vftables): dead

ShineObject::so_FreeFromList()  (vt 0x2c; O, Di, Ef, MO, Do, Mf, Mh, Af, Mv)                @ FUN_00554220
    unlink so_slantedlist.Xlist if linked (cn_prev ≠ cn_next: cn_RemoveList), the same for Ylist
    if exactly one was linked: assert "ShineObjectList::som_FreeObject : one of SlantedList is removed"
    # the mob variant FUN_00554280 also leaves the family ring (Z09 §10.5, §28); the player variant FUN_00554310 releases the
    # party slot first (§2.3). Caller: som_FreeObject FUN_00557d70

ShineObject::so_RemakeHandle(i) → 0xFFFF  (vt 0x4a4; O, MO)                                 @ FUN_00554ff0
    assert "ShineObjectClass::ShineObject::so_RemakeHandle" (i)         # abstract classes have no handle range
    # every concrete class overrides it with its pool's handle range (Z01 §3, Z09 §11-§13, Z13 §1.1 / §6.2 / §8.1)

ShineObject::so_LoginLocation() → null  (vt 0x4bc; O, MO, Mf, Af)                          @ FUN_00554fd0
    assert "ShineObjectClass::ShineObject::so_LoginLocation"
    # callers: so_MapMarking, so_MapMarkingAtDefaultCoord (Z09), effect blast, SysFuncShineIsGateUse; they run only on
    # classes with their own LoginLocation (player, mob family, drop item, effect, door, mini-house, mover)

ShineObject::so_Init()  (vt 0xe78; every class)                                           @ FUN_005551c0
    this.vt[0xe7c](0, 0); this.vt[0xe80](0, 0)                          # clear the fixed walk / run speed
    # MO and subclasses: so_smo_SetStaticWalkSpeed FUN_005558f0 / so_smo_SetStaticRunSpeed FUN_00555910 set
    # (smo_bStaticWalkSpeed, smo_nStaticWalkSpeed) / (smo_bStaticRunSpeed, smo_nStaticRunSpeed); the other classes have
    # the empty two-argument fold FUN_00509900 there. Caller: som_AllocObject (Z01 §4.1), on every object taken from a pool
```

### 5.4 `ShineMobileObject` members

```pseudo
ShineMobileObject::so_mobile_IsEnemy(o) → bool  (vt 0x72c; MO, Do)                         @ FUN_0042f220
    if o.vt[0x9b0]() ≠ null: o = o.vt[0x9b0]()               # so_serv_FindMaster: a servant counts as its master
    if o.so_AbnormalState_IsSet(STA_IMMORTAL 291) (vt 0x3e4) or o.…IsSet(STA_ADLFLOUSSIERIMT 499): return false
    if this.so_IsAlliance(o) (vt 0xe60) == 1: return false
    if o.so_mobile_BattleCamp() (vt 0x8cc) == BC_NPC 3: return false
    return o.so_ObjectType() (vt 0x4d0) ∈ {2 player, 8 bandit, 5 mob, 11 mover}
    # in 2016 only doors keep this body, and for a door so_IsAlliance is the `false` fold (§5.7) and its camp is 0. The mob
    # override ShineMob::so_mobile_IsEnemy FUN_004304c0 (M, N, B; Z03, Z25) calls it directly. Other overrides: player
    # FUN_00430570 (Z03 §3.3), pet FUN_0042f3a0 (false, Z13 §6.2), servant FUN_004308b0 (Z09 §13.3), mover FUN_004309a0
    # (Z13 §8.9). 14 slot callers (target scans, aggro, swing damage)

ShineMobileObject::so_mobile_TargetModeCheck(TargetState s) → bool  (vt 0x7e4; MO family)  @ FUN_00555840
    TS_LIVE 0:   return not this.so_AmIAlreadyDead() (vt 0x28, FUN_005557a0: smo_BattleObject.alreadydead or HP 0)
    TS_CORPSE 1: return this.so_AmIAlreadyDead()
    else:        assert "…so_mobile_TargetModeCheck : Invalid target mode" (s); return false
    # caller: the cast tick in ShineMobileObject::so_Routine FUN_0056a080: while a skill is cast on a target,
    # target.vt[0x7e4](ActiveSkill.SkillTargetState) false → caster.smo_CastAbort (vt 0xed4)

ShineMobileObject::so_mobile_MoveHalt()  (vt 0x7c4; MO family; others: empty fold)          @ FUN_005559d0
    if smo_MoveManager.mm_state ≠ MM_REINFORCEMOVE 3:
        mm_state = MM_HALT; mm_startTime_ms = mm_fullTime_ms = mm_currTime_ms = mm_lastTime_ms = mm_leftTime_ms = 0
        mm_charSpeed = 0; mm_goalPos = current location
    # callers: AbstateListInObject::asl_AbstateSet when a SUBAB_FEAR sub-state is set (Z03 abstates);
    # MobTacticElement::MobActionTurning::mab_Think after its move reserve (vt 0x660) (Z09 §7)

ShineMobileObject::smo_MoveLocationCheck_From(SHINE_XY_TYPE* from) → bool                @ FUN_004569e0
    from == null: assert "…smo_MoveLocationCheck_From : pFromLoc null"; return false
    return dx² + dy² < 40001 between the current location and from      # the claimed start is within 200 units
ShineMobileObject::smo_MoveLocationCheck_To(SHINE_XY_TYPE* to) → bool                    @ FUN_00456a30
    to == null: assert "…sp_MoveLocationCheck_To : pToLoc null" (sic); return false
    return MapBlockInformation::mbi_OccupCellCheck(field's block map, to.x, to.y, 1) ≠ 0   # walkable cell
    # both are non-virtual; callers ShineMover::so_smv_MoveWalk / MoveRun / MoveStop (Z13 §8.7)

ShineMobileObject::so_mobile_NotifyParameterChange(u8)  (vt 0x34; all MO except P)         @ FUN_00503b60
    Parameter::Container::c_MakeTotal(smo_Param)                        # recompute the totals (Z12)
    # player override FUN_00503c10 (Z12). 38 callers (abstate actors, & commands, KilledBy, item effects)

ShineMobileObject::so_batobj_DamageApply(dmg)  (vt 0x658)                                   @ FUN_005556c0
    smo_BattleObject.damagereserve -= dmg; < 0: assert "…so_batobj_DamageApply"
    # no caller (referenced only by the 9 vftables): dead; its reader so_batobj_GetDamage FUN_005556f0
```

Small members (slot; classes that use the body; callers):

| Function | Slot | Body | Callers |
|---|---|---|---|
| `so_smo_CanEnchant(idx, strength)` FUN_0040dba0 | 0xa6c (MO family; O… `ShineObject::so_smo_CanEnchant` FUN_00408d30 = false) | `AbstateListInObject::asl_CanEnchant` (§6) | `ShinePlayer::sp_AbstateCheck` |
| `so_smo_RangeEvation` FUN_004a6380 | 0xa68 (O… FUN_004a6330 = 0) | `smo_Param.RangeEvasion` | `RulesOfEngagement::roe_FreeStatHitRate` (Z12) |
| `smo_HowMachSoul(skill, out, target)` FUN_004a5ff0 | 0xf38 (all MO but P) | `out = {null, 0, 0}`: only players collect souls | `SkillBlastEffectContainer::sbec_Store` (player body FUN_004a6060, Z25) |
| `smo_SoulManage(target, skill)` FUN_004a5dd0 | 0xf34 (all MO but P) | empty | `MiscDataTable::mdt_PostSkillBlast` (player FUN_004a5e20, Z25) |
| `so_BashStop` FUN_00401b80 | 0xadc (MO family; others empty fold) | `this.vt[0xed8]()` | `AbstateElementInObject::aeo_Set` |
| `smo_BashStop` FUN_0042e800 | 0xed8 (MO, Do, Mv) | empty (mob FUN_0042adf0, player FUN_0042e840, Z03) | 29 (swing / targeting / abstate) |
| `smo_ply_NormalAttackFactor` FUN_0042f8c0 | 0xf3c (all MO but P) | 1000 | `smo_SwingDamage` (player version §4.4) |
| `so_mobile_SetNaturalEnemy(a)` FUN_0042b020 / `so_mobile_GetNaturalEnemy` FUN_0042b030 | 0x9d8 / 0x9dc (MO family) | `smo_NaturalEnemy = a` / return it | `asl_AbstateSet` / `asl_AbstateReset`, `smo_SwingDamage` |
| `so_AbnormalState_Reset(idx)` FUN_00555700 | 0x650 (all MO but P) | `asl_AbstateReset(smo_Abstate.abstatelist, this, idx)` | 37 (player FUN_00559ef0) |
| `so_RecalcSpeed(v)` FUN_005557e0 | 0x7b8 (MO family) | `MoveManager::mm_RecalcSpeed` | no caller: dead |
| `so_mobile_GetHPChangeOrder` FUN_00555890 | 0x7e8 (MO family; O… FUN_00555130 = 0xFF) | `++smo_HPChangeOrder` (u16 `hpchangeorder`, the sequence number in every HP-changing packet, Z03) | 15 (DoT, HP heal, target inform) |
| `so_mobile_DeadCheck(cause)` FUN_005558b0 | 0x8d4 (MO family) | `smo_DeadCheck.dc_Cause = cause` (`DC_LIVE` 0, `DC_DOT` 1, `DC_ATTACK` 2, `DC_ATTACK2` 3, `DC_SELFKILL` 4, `DC_SKILL` 5) | DoT, `so_Bash` (dead), mob suicide |
| `so_SetMovePacket(h, pkt)` FUN_0055d5d0 | 0xbb8 (MO family) | `smo_SetMovePacket` FUN_00434ae0 | no caller: dead (the walk / run handlers call `smo_SetMovePacket` directly) |
| `so_smo_SPExhByAbState` FUN_00402070 | 0xa60 (MO family; O… `so_getDetectRange` FUN_005551a0 = 1000) | `smo_Param.SPRate` | `CharaterSkillList::csl_SPCheck` |
| `so_Getabstatebit` FUN_005556a0 | 0x4a0 (MO, Do) | the static `AS::tempbit`, one array shared by every door (original bug) Z31-B7 | 10 (abstate bit set / reset) |
| `smo_DuringCast` FUN_00555730 | 0xea0 | `smo_SkillCast.scs_BlastTime ≠ 0` | 13 (item use, flag capture, mob attack) |
| `so_mobile_MoveSpeed` FUN_005557c0 / `so_mobile_MoveState` FUN_005557d0 | 0x7b0 / 0x7b4 | `mm_charSpeed` / `mm_state` | `so_mobile_SpeedChange`, `MobActionInChase`, `so_ExchageBriefInfo` |
| `so_mobile_DuringFlying` FUN_00555880 | 0x7c0 | `smo_Flag.DuringFlying` | `CharClass::cc_CanNormalAttack` |
| `so_mobile_IsInFear` FUN_00566e70 | 0x9e8 | `smo_Flag.InFear` | mob target selectors, `MoveManager::mm_Step`, active-skill item use |
| `so_smo_GetStaticRunSpeed` FUN_00555960 | 0xe90 | `smo_nStaticRunSpeed` | the three `so_RunSpeed` (mob, player, mover) |

The non-mobile classes have the shared folds of §5.6 in all these slots.

### 5.5 `ShineObject` defaults of player slots

These slots are overridden only by `ShinePlayer` (or by one other class, named in the row). The default either asserts
(the caller only reaches players) or returns a neutral value. The player bodies are cited in the column "Override".

| Default | Slot | Body | Override | Callers |
|---|---|---|---|---|
| `so_SaveMisc2WMS` FUN_00453380, `so_SaveCharTitle` FUN_004533a0, `so_SaveToDB_CharTitle` FUN_004533c0, `so_ply_SavePKCount` FUN_004533e0, `so_SaveLocation` FUN_00453400, `so_SaveChestInfo` FUN_00453420, `so_SaveLevel` FUN_00453440, `so_SaveStat` FUN_00453460, `so_SaveGameData` FUN_00453480, `so_SaveAbstate` FUN_00453500, `so_SaveItem` FUN_00453540, `so_SaveSkill` FUN_00453560 | 0x3c4, 0x3c0, 0x3c8, 0x388, 0x38c, 0x3bc, 0x390, 0x3ac, 0x3b0, 0x3a4, 0x3b4, 0x3a8 | assert with its own name, return 0 (no bytes written) | FUN_00453e70 … FUN_00456520 (Z07, §4.3) | `WholeSaver::ws_save2worldmanager` / `ws_savelevel2worldmamager` / `ws_save2DB` (Z07); 0x3b4 none |
| `so_SetRegistNumber(ack)` FUN_0044a950 | 0x2ec | assert | FUN_0044e900 (Z07) | `wms_NC_CHAR_REGISTNUMBER_ACK` |
| `so_ply_RegistNumberVarifyCheck(ack)` FUN_00551b60 | 0x9f0 | false (profiler string "…so_RegistNumberVarifyCheck") | FUN_00551bb0 (Z10) | `gds_NC_CHAR_REGNUM_VARIFICATION_ACK` |
| `so_PacketBufferFlush` FUN_005551f0 | 0x2e8 | true | FUN_0055aa70 (§4.5) | `ShinePlayer::so_Routine`, `zs_disconnect` |
| `so_ply_Getchestinform(cmd)` FUN_0044c850 | 0x6c4 | empty | FUN_0044c8a0 | `wms_NC_CHAR_ZONE_CHESTINFO_CMD` |
| `so_ply_GuildReName` FUN_00473b60 / `so_ply_GuildReType` FUN_00473bb0 | 0x880 / 0x884 | empty | FUN_00474650 / FUN_00473c00 (§2.1) | the WM rename / retype acks (Z08 §8.2) |
| `so_ply_GetClientSession` FUN_004c8da0 | 0xa70 | null | FUN_004c8df0 | `wms_NC_MAP_LINKRESERVE_ACK`, `PacketContainer::pcb_Append` |
| `so_ply_InvenWrite(text)` FUN_0051ad40 | 0xa58 | empty | FUN_0051ad90 (Z11) | `AmpersandCommand::ac_InventoryView` |
| `so_ply_ChangeCharIDUseAck(ack)` FUN_0051b7c0 | 0x9fc | empty | FUN_0051b810 (Z07) | the CHANGE_CHAR_ID item-use DB ack |
| `so_Disconnect(reason, when, arg)` FUN_00549db0 | 0x5f8 | assert "…so_Disconnect" with the object type | FUN_0054f340 (Z01 §8.3) | 50 |
| `so_ply_ItemLotChange(slot, lot)` FUN_00578220 | 0x7f8 | empty | FUN_00578270 (Z05) | `icl_Apply_N_Free`, `icl_Apply_N_Free_ItemUseAck` (§3.2) |
| `so_Prison_Go(min)` FUN_005b9460 / `so_Prison_End(name, xy)` FUN_005b96e0 | 0x8a4 / 0x8a8 | 1 / empty | FUN_005b94b0 / FUN_005b9730 (Z08) | `wms_NC_ZONE_PRISON_GO_REQ` / `…_END_CMD` |
| `so_GetCharRegistNumber_ItemLooter` FUN_004811f0 | 0x564 | `this.vt[0x344]()` (own char number; also used by players) | servant FUN_00481200 (Z09 §13.3: the master's) | `HitMeList::EnemyList::el_Store` (§6) |
| `so_NC_ITEMDB_fail(dept, cmd, err)` FUN_00517d20, `so_NC_ITEMDB_ADMINCREATEFAIL_ACK` FUN_00527250, `so_NC_ITEMDB_USE_ACK(slot)` FUN_0053f820 | 0x350 / 0x34c / 0x354 | assert | FUN_00517eb0 / FUN_005275b0 / FUN_0053fb50 (Z05) | the Item-DB fail acks (12), mushroom / admin create fail, `gds_NC_ITEMDB_USE_ACK` |
| `so_drpitm_CanLooting(o)` FUN_00529a50, `so_drpitm_itemview` FUN_00555070 (string "…so_itemview"), `so_itempicked` FUN_00555090 | 0x53c / 0x548 / 0x54c | assert; false / null / – | drop item FUN_0052a4e0 / FUN_00555310 / FUN_00555340 (Z09 §11) | pick-up, party / raid distribution, `ii_PickAll` / `ii_PickMerge` |
| `so_ply_KeepFromChat(gm)` FUN_00549f40 | 0x8f0 | `gm.vt[0x784]("Error in KeepFromChat")` (`so_ply_Notice` to the GM) | FUN_00549f60 (Z11) | `AmpersandCommand::ac_KeepFromChat` (target not a player) |
| `so_ply_GodOfSlotMachine` FUN_0061dde0 | 0xb58 | a static empty buffer `tmp` | FUN_0061ddf0 (Z11) | `ac_GodOfSlotMachine`, `SlotMachineScreen::SMS_StopButton` (Z32) |
| `so_AbnormalState_Set_CharAllMode(…)` FUN_004165b0 | 0x63c | false | FUN_004165c0 (Z03) | `ShineMobileObject::so_KilledBy` |
| `so_ply_isGuildStoreGrade` FUN_0046deb0 | 0x5f0 and 0x874 | 99 (nonzero) | FUN_00475b10 / `so_ply_isGuildAcademyRewardStoreGrade` FUN_0046dec0 (§4.7) | guild-token buy, item relocation / split, storage withdraws |
| `so_ply_GetItemLotInspector` FUN_00490bc0 | 0x96c | `&so_ItemLotInspector` (static) | FUN_00490bd0 (§4.10) | `ItemRelocationManager::irm_*` |
| `so_GetLastUpgradeInfo` FUN_0053b280 | 0x314 | `&so_deflastupgradeinfo` | FUN_0053b290 (Z04) | the three upgrade DB acks |
| `so_ply_MakeLayerRegNum(type, no)` FUN_0054ab30 | 0xdb8 | 0 | FUN_0054ab40 (Z14) | `so_ply_MoveNewLayer`, `…_AllInMap`, `cMobRegen_XY_Layer` |
| `so_TradeStructure` FUN_00554f00 / `so_TradeBoard` FUN_00554f10 | 0x31c / 0x320 | `&so_deftradestr` / `&so_deftradebrd` | FUN_00559670 / FUN_00559680 | `so_CloseTradeMenu`, trade propose / decide (Z06) / 0x320: no caller |
| `so_PacketEncryptClass` FUN_00554f60 | 0x4a8 | `&so_PacketEncrypt` | FUN_00559700 | `pcb_Append`, `ClientSession::zbs_Parsing` (Z01) |
| `so_ply_CurrentMoney` FUN_00554f70 | 0x434, 0x438, 0xb04, 0xb10 | 0 (u64; one body for four slots) | `so_ply_CurrentMoney` FUN_00559710, `so_ply_CurrentExp` FUN_00559720, `so_Gamble_CurrentCoin` FUN_0055a6b0, `so_Gamble_CurrentExchangedCoin` FUN_0055a6e0 | 35 / 3 / 7 / 1 |
| `so_extradata` FUN_00554f80 | 0x570 | `&so_defextdata` | FUN_00559750 | none |
| `so_CharName` FUN_00554f90 | 0x56c (O, Di, Ef, MO, Do, Mf, Mh, Af, Mv) | `&so_defname` | player FUN_00559780, mob family FUN_00556530, pet FUN_005573a0 | 114 (logs, & commands) |
| `sp_lastpickuptime` FUN_005550d0 | 0x41c | `clockwatch.cw_CurrTick` | FUN_0055a090 | party / raid item distribution |
| `so_GetStatDistStr` FUN_005550f0 | 0x424 | `&so_StatDistStr` | FUN_0055a1c0 (§4.10) | the five `so_ply_FreeStat*`, `cFreeStatInit` |
| `so_ply_GetInventoryLockList` FUN_00555100 | 0x7d4 | `&so_definvlocklist` (a static, empty lock list) | FUN_0055a1d0 (§3) | 258 |
| `so_ply_FreeStatInt` FUN_00555150 / `…Dex` FUN_00555160 / `…Con` FUN_00555170 | 0x46c / 0x470 / 0x474 | the first row of the `FreeStat*` tables (`shineparam.scp_param`, Z12) | FUN_0055a390 / FUN_0055a3d0 / FUN_0055a410 | rule-of-engagement hit / damage / block, NotifyParameterChange, `sp_MaxHP` |
| `so_MiscTable` FUN_00555190 | 0x984 | `&so_MiscTableDef` | servant FUN_005572e0 | `ShineMobileObject::so_Dispel` |
| `so_fullbufferitem_box(buf, inform, n, bag)` FUN_0063fd90 | 0x524 | 0 bytes written | FUN_00559a70 | guild / academy storage `…StoreItem`, `smh_SendFurnitureInfo` (Z13 §2.2) |

### 5.6 `ShineObject` defaults of mobile, mob, NPC and effect slots

| Default | Slot | Body | Override | Callers |
|---|---|---|---|---|
| `so_Chat(…)` FUN_00458c40 | 0x530 (O, Di, Ef, Mf, Mh, Af) | empty | `ShineMobileObject::so_Chat` FUN_00458c90 | chat request, `MobChat::*` |
| `so_Bash(…)` FUN_0042ae90 | 0x598 (non-mobiles) | `*dmg = 0`, return 0 | MO FUN_0042e950, P FUN_0042efb0 | none: the whole slot is dead (Z09 §7.8) |
| `so_SkillEnchant(…)` FUN_0042adb0 | 0x5a0 (non-mobiles) | false | MO FUN_00431ca0 (Z03) | `smo_SkillBlast`, `smo_old_skill_blast` |
| `so_smo_RangeEvation` FUN_004a6330 | 0xa68 (non-mobiles) | 0 | §5.4 | §5.4 |
| `so_CharacterClass` FUN_00554f20 | 0x49c (non-mobiles) | `&charclassmanager.ccm_classdefault` | MO FUN_00555590 | 32 |
| `so_mobile_AbstateList` FUN_00554f40 | 0x52c (non-mobiles) | `&so_defabstatelist` | MO FUN_005555b0 | 72 |
| `so_Getabstatebit` FUN_00555060 | 0x4a0 (non-mobiles) | `&so_defabstatebit` | §5.4, player, mob, bandit, pet, mover | 10 |
| `so_parameter` FUN_005550c0 | 0x430 (non-mobiles) | `&so_defaultparam` | MO FUN_00555720 | 66 |
| `so_mobile_GetHPChangeOrder` FUN_00555130 | 0x7e8 (non-mobiles) | 0xFF | §5.4 | §5.4 |
| `so_ObjectType` FUN_00554fb0 | 0x4d0 (O, MO) | 0xFF | every concrete class (Z01 §2): bandit FUN_00556eb0 = 8, NPC FUN_00557c00 = 4 | 202 |
| `so_DefaultCoord` FUN_0054a0f0 | 0xc (all but Af) | `&so_TempLocation` | axial flag FUN_0054a100 (Z09 §12) | many (slot 0xc is shared with other class families; not separated) |
| `so_mob_GetMonEXP` FUN_004aa2a0 | 0xb9c (non-mob) | 0 | mob family FUN_004aa2f0 (Z09 §5) | `ExperienceDistribute::lid_Call` |
| `so_mob_SetMobResist` FUN_004aa350 | 0xba0 | empty | FUN_004a9d00 | `cSetNPCResist` (Lua, part 8) |
| `so_mob_SetIsPlayerSide(v)` FUN_004aa750 | 0xbac | empty | FUN_004aa7a0 | none: dead |
| `so_mob_CanGathered(p, &picker)` FUN_0046a490 | 0x720 (non-mob) | 0x0B02 (not a gathering object) | FUN_0046af50 (Z02 §8) | `sp_NC_ACT_GATHERSTART_REQ` → 0x202E err 0x0B02 |
| `so_mob_SelectWeapon(t, n)` FUN_004a9d40 | 0x73c | −1 | FUN_004ab720 (Z09) | `MobActionTargetting` / `MobActionAttack::mab_Think` |
| `so_mob_SightCenter(i, xy)` FUN_004abcc0 | 0x8f4 | own location | FUN_004abcd0 (Z09) | `MobTargetSelector` / `MobTargetAggresive::mts_SelectTarget` |
| `so_mob_FindLooter(&out)` FUN_0055e7f0 | 0xe4c | an empty `ShineMultiTypeHandle` | FUN_0055e810 (Z09) | `cDropItem` (Lua) |
| `so_mob_Regenerate(…)` FUN_004b0e30 | 0x6e0 | `FM_MAPNOTEXIST` 1 | mob / bandit / pet FUN_004b41b0, servant FUN_004b4780, NPC FUN_004b4bc0 (Z09) | 16 (breeders, NPC manager, summons, scripts) |
| `so_effect_EffectBlast(…)` FUN_004b0e10 (handle form) | 0x6e4 | `FM_MAPNOTEXIST` | effect FUN_004b1540 (Z09 §13.2) | `cEffectRegen_Object` |
| `so_effect_EffectBlast(…)` FUN_004b0e20 (coordinate form) | 0x6e8 and 0x6dc | `FM_MAPNOTEXIST` | effect FUN_004b1770 / door `so_door_Build` FUN_0043f7b0 at 0x6dc | `cEffectRegen_XY`, `ShineEffectLocate::sa_Step` / door build (`&doorbuild`, scripts) |
| `so_npc_FromTable` FUN_004b1970 | 0xa80 | empty | `ShineNPC::so_npc_FromTable` FUN_004b19b0: `sn_FromTable` (+0x2568) = 1 | `NPCManager::nm_SetNPC`, `nm_MarkingNPC`, `nm_DynamicRegenerateNPC` (part 8) |
| `smo_LightningWaveSkill(…)` FUN_00579690 | 0xbf4 (non-mobiles) and 0xb4c (all but N) | empty | MO FUN_005796a0 (Z25) at 0xbf4; `ShineNPC::so_npc_SetLocation` FUN_00557cc0 at 0xb4c | 0xbf4: `so_Routine`, skill-target scans; 0xb4c: `nm_MarkingNPC` |

`ShineNPC::so_mobile_BattleCamp` FUN_00557b90 (vt 0x8cc): `sm_MobDataBox.data.IsPlayerSide` (MobInfo +0x67) ≠ 0 →
`BC_CHAR` 2, else `BC_NPC` 3 (`BattleCamp`: `BC_NONE` 0, `BC_MOB` 1, `BC_CHAR` 2, `BC_NPC` 3). The generic enemy test (§5.4)
therefore never takes an NPC: camp 3 answers false, and type 4 is not in its type set either. Mobs and bandits use FUN_00556460, the servant
FUN_00556f70 (Z09 §13.3), the mover FUN_0055e9c0 (Z13 §8.1), doors and the non-mobiles the `0` fold FUN_00570b00 (`BC_NONE`), the player and pet the `return 2` fold FUN_00647230.

### 5.7 Folded bodies in the object vtables

These shared bodies carry a PDB name from an unrelated class (identical-code folding, `docs/knowledge/X02.md`). They fill the
slots that a class does not implement. Read them by body, not by name:

| Body | PDB name | Behaviour | Used in the object vtables at (examples) |
|---|---|---|---|
| FUN_00417480 | `ShineObject::so_Gamble_ChangeCoin` | empty | non-mobile 0x7c4, 0xadc, 0x588; also the empty member destructors |
| FUN_00549070 | `ShineObject::so_ply_CollectCardOpen` | empty, one argument | non-player 0x784; non-mobile 0x34, 0x650, 0x658, 0x7b8, 0x8d4, 0x9d8 |
| FUN_00615e70 | `CGambleObject::go_Init_MaxPlayer` | false, one argument | non-mobile 0x72c, 0x7e4, 0x3e4; 0xe60 of the non-mobiles, `ShineMobileObject` and the door |
| FUN_00570b00 | `CGambleObject::GDTSO_GetGameStatus` | 0 | non-mobile 0x7b0, 0x7b4, 0xe90, 0x9dc; 0x8cc of the non-mobiles, `ShineMobileObject` and the door; 0x9b0 everywhere but the servant |
| FUN_00509900 | `CGambleObject::go_SMC_WinRank` | empty, two arguments | non-mobile 0xe7c, 0xe80, 0xbb8 |
| FUN_004b8d20 | `SlotMachineScreen::go_IsFullCheck` | false | non-mobile 0x28, 0x7c0, 0x9e8; axial flag 0x4d0 (type 0) |
| FUN_00647230 | `SlotMachineCluster::go_Get_GambleType` | 2 | player and pet 0x8cc (camp `BC_CHAR`) |
| FUN_00401a80 | `ShineObject::so_smo_GetRandomTarget_Object` | null | non-mobile 0x584 |
| FUN_005551a0 | `ShineObject::so_getDetectRange` | 1000 | non-mobile 0xa60 |
| FUN_00408d30 | `ShineObject::so_smo_CanEnchant` | false | non-mobile 0xa6c |
| FUN_005af8d0 / FUN_00556ff0 | `so_Gamble_IsGambleHouse` / `so_MoverSystem_GetMoverSlot` | 1 / 10 | drop item 0x4d0 (type 1) / servant 0x4d0 (type 10) |

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z31-B1 | `so_ply_GuildReNameItemUseSuccess` / `…ReTypeItemUseSuccess` §2.1 | when the 128-entry ring slot was reused before the DB confirmed the item, only "Guild ReName / ReType Null" is logged | the rename / retype item is consumed, the guild is not changed, the client gets no answer | keep the name / type with the item use (as the megaphone, Z04-B7, same pattern) or refund |
| Z31-B2 | `so_ply_DecreaseDmgPassiveSkill` §2.6 | the BackgroundDefense reduction tests the attacking mob's facing against the mob→player direction | ordinary mob attacks (mob facing its target) are never reduced; hits from a mob facing away are, whatever the player's facing | test the player's facing against the player→mob direction (hits from behind the player) |
| Z31-B3 | `InvenCellReleaser_CoinChange::icr_Reserv` §3.3 | adds a pending coin reservation to `ReservedQuantity.cen`; no releaser fills `guild_token` or `gbcoin` | while a coin reservation is open the money checks (buy, upgrades, soul stones) see less money; the guild-token buy never subtracts reserved tokens | add coins to `gbcoin`, and reserve guild tokens under their own field |
| Z31-B4 | `ItemAttrCls_SkillScroll` / `WeaponTitlaLicence` / `GBCoin` `iac_fill2buffer` FUN_0063e970 §3.5 | advances the buffer by the 1-byte attribute without writing it (the reader skips it) | one stale send-buffer byte per such item in every item record (0x1047, 0x3001, DB requests); the client ignores it | write a 0 byte (same as D07-B14 on the Character server) |
| Z31-B5 | `so_ply_ChangeBriefInfo` (vt 0x608) §4.2 | passes the addresses of two uninitialised locals as the weapon-title out values; only the weapon class writes them, but `SetCurrentTitle(10, …)` runs for every item whenever the weapon title is current | after an equip / unequip of a non-weapon item the current weapon title gets stack garbage as level / mob (same as Z18-B9 in the twin `so_ply_EquipmentChange`) | update the title only when the item is a weapon, or initialise the locals |
| Z31-B6 | `sp_SendSellItemInfo_World` §4.2 | builds 0x4037 without writing `nWorldHandle` / `nCharNo`; the bytes come from the 0x4036 packet that `sp_SaveUseItemMinimonInfo_World` left in the shared send buffer | none in 2016 (the 0x4036 builder always runs just before and writes the same two fields); breaks if the save order changes | write the 6-byte header in the 0x4037 builder |
| Z31-B7 | `ShineMobileObject::so_Getabstatebit` FUN_005556a0 (vt 0x4a0, kept by `ShineDoor`) §5.4 | returns one static bit array (`AS::tempbit`) for every door | an abstate bit set on one door (`so_AbnormalState_BitSet`, `asl_Store`) would show in every door's bits; no 2016 path that puts an abstate on a door was found *(inferred)* | a per-object bit array, as the other classes have (the pet's twin is Z13-B43) |

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
- §4.1: the zone parser table covers every department, so `sp_DummyFunction` is reached by any command without a
  `pft_Store`; whether the client ever sends one (dead client code) was not checked.
- §4.2: the client window tested before the 0x980B request (0x1096 handler FUN_0049fe50, vt 0x104) was not identified.
- §4.4: the 300 / 400 per-mille split of `smo_ply_NormalAttackFactor` is read from the code; that it splits a
  Trickster multi-hit is inferred from `sp_MultiHitNotIndex`.
- §4.5: which `RemoveWhen` path `som_FreeObject` takes for REMOVE_LOGOUT on a socket cut is Z16 §4.4 / Z01 §8.3; not re-read.
- §5.1: that the object pools are never deleted (so the deleting destructors never run) is inferred from the missing
  `+ 4))(` calls on objects; a shutdown path freeing them was not searched.
- §5.4 / §5.7: Z31-B7 (shared door bit array) is reachable only if a door can receive an abstate; the door's
  `so_AbnormalState_Set` path was not traced.
- §5.5 / §5.6: slots below 0x100 (0xc `so_DefaultCoord`, 0x2c, 0x34) share their offsets with other class families, so
  their caller counts include non-object calls.
- §4.10: callers of the low slots 0x18 (`so_ply_HideMyIdentity`) and 0x30 (`so_ply_TreasureChestLocationManager`)
  were not separated from the other object types' calls of the same slots.

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
| `CSellItemManager` (the sell list itself, `simg_FillBuffer_Server` FUN_0050e4d0 and the insert / delete) | Z18, this item part 8 (`CSellItemManager`) | §4.2 documents the two player-side senders and `simg_FillBuffer_Client` |
| `DuplicatedMenuControl::dmc_Table` contents (7 × 7 menu exclusion table) | this item, part 8 (`DuplicatedMenuControl`) | §4.8 documents the test; the table's initializer is in the part-8 bucket |
| `ShineMiniHouse::so_mh_*` dice game, `CGambleDiceTaiSaiObject` | Z06 §3 (done), Z32 | §4.6 documents only the player-side state accessors they call |
| `GuildTournamentSystem::CaptureFlag` FUN_0047eae0 (caller of `ShineDynamicCast<ShineNPC>`) | this item, part 8 (`Guild*`) | §5.2 documents the cast |
| `List<ShineObject>::l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` (callers of `ShineObject::operator=`) | this item, part 9 (library templates) | §5.1 documents the copy |
| per-class overrides of the object slots (mob, NPC, bandit, servant, door, effect, drop item, flag, pet, mover, mini-house) | Z09 §5 / §11-§13, Z13 §1.8 / §6.2 / §8.1 (done) | §5 documents only the base-class bodies and links the overrides |
| auto-arrange sort and step scheduling (`so_ply_ArrangeInven` FUN_00563500) | this item, part 10 (§11, Z04 open point) | §4.9 documents the grade rank and the login init |
