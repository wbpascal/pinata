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
| 6 | abstate containers, character classes, mob AI, rules of engagement, use effects | 109 / 1 774 |
| 7 | table templates (`BinaryDataBox<…>`, `ITableBase<…>`, `IIDTableBase<…>`, `SHND::CommonData<…>`, `Table`) | 201 / 4 103 |
| 8 | the other data loaders and SHN / text parsers | 67 / 1 927 |
| 9 | NPC roles, merchant cities, item authority, booths, repurchase list, guild containers, party table, finders, events | 106 / 2 621 (+ `mcd_Load`, `nm_MarkingNPC`, `dmc_Table`) |
| 10 | sessions, packet containers, `AxialList*` visitors, map clusters, path finding, library classes | 154 / 3 096 (+ `sb_HeartBeatCheck`, `sb_DisconnectCheck`, `sp_Send_NC_ITEM_SOMEONEPICK_CMD`) |
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
    p.smo_CharClass (+0xfbc).cc_BaseClass (class vt 0x48) == 21 (Joker line):
        sp_MultiHitNotIndex == 3 ? 400 : 300
    else 1000
```
`smo_SwingDamage` FUN_00432f30 multiplies the swing damage by this rate (Z03 §3.2 "attacker's total damage rate").
Trickster-line normal hits are multi-hits, and each part carries 30 % (the last one 40 %) *(inferred from the counter
name)*. CharClass vt 0x48 `cc_BaseClass` returns the **first class of the line**: 1 Fighter … Knight, 6 Cleric … Guardian, 11 Archer
… Ranger, 16 Mage … Wizard, 21 Joker … Assassin, 26 Sentinel / Savior (all class slots: §6.2).

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
| `so_ply_dupmenu_canmenuopen(m)` FUN_00559fa0 | 0x6ac | `DuplicatedMenuControl::dmc_CanMenuOpen` FUN_00460d70: false if any open menu bit b has `dmc_Table[b][m] == 0` (7 × 7 table of "may be open together" bytes, contents in §9.4), else true | the same `nrb_Role`s and upgrade REQs |
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

## 6. Abstate containers, character classes, attack rhythm, rules of engagement, mob AI objects, use effects

The 109 functions of this part. Most are small virtual members, folded stubs and destructors; this section gives
each one its slot, its callers and its body. The subsystems they belong to are documented elsewhere: abnormal states
in Z03 §6 and Z22, character classes and stats in Z12, rules of engagement in Z03 §4, mob AI in Z09 §5-§8, use
effects in Z04 §6.3.

### 6.1 Abnormal-state containers

```pseudo
AbnormalStateContainer::AbstateListInObject::asl_CanEnchant(list, ABSTATEINDEX idx, int strength) → bool   @ FUN_0040bf50
    e = asl_Abstate_IsSet(list, idx)
    if e ≠ null: return strength >= e.aeo_Strength          # the same state is on: only an equal or stronger grade may replace it
    as = dic_abstate.as_StateIndexList[idx]                 # idx ≥ 792 (0x318): assert "AbState::as_FromIndex : Invalid skill idx", as = null (then crashes)
    sub = as.subabstate[strength].assa_info                 # the SubAbState.shn row of (idx, strength)
    if sub.Type == SUBAB_DEFAULT: return true
    x = first element of the list whose ident (abstateidentarray[x.aeo_Index], 12 bytes: +8 u16 Type, +10 u16 SubType)
        has the same Type and SubType;  none: return true
    r = SubAbstatePriority::PriorityBase::bp_AbStateChange(&subabpriority.pc_Base,
            x's row (abstateidentarray[x.aeo_Index].strength[x.aeo_Strength]), &as.subabstate[strength])
    return r ∈ { SAP_NORELATION 0, SAP_SUBSCRIPT 1 }          # SAP_VANISH 2 (the new state would be wiped by the old one): refuse
```

Callers: `ShineMobileObject::so_smo_CanEnchant` FUN_0040dba0 (vt 0xa6c, §5.4), which `ShinePlayer::sp_AbstateCheck`
FUN_00408be0 calls before a buff skill; a `false` there is error 0xFD4 "upper level effect are used already"
(Z03 §5.2, 0x2440). This is the dry-run twin of the priority test inside `asl_AbstateSet` (Z03 §6).

| Function | Body | Callers |
|---|---|---|
| `AbnormalStateDictionary::SubAbState::SubAbState` FUN_00416b50 | `BinaryDataBox<SubAbStateInfo>`; default row `sas_DefAbstate` = the box's `bdb_defaultblock` zeroed (0x4f bytes), `ID` 0xFFFF, `Type` SUBAB_DEFAULT, every action SAA_NONE 0 and argument 0 (`ActionIndexA` is set twice and `B` stays from the memset, also 0) | the `dic_abstate` start-up constructor |
| `AbnormalStateDictionary::AbState::~AbState` FUN_00416de0 | `delete as_AbstateArray` | `dic_abstate` atexit |
| `AbstateElementInObject::ase_Terminate` FUN_00401200 | `aeo_Tick.terminate = clockwatch.cw_CurrTick`: the element expires at the next tick of `asl_Routine` | `DispelAttrTypeEffect::_execute` FUN_005d05f0 (Z17 §2.6, dispel by `DispelIndex`) |
| `AbnormalStateElement::~AbnormalStateElement` FUN_00401490, `AbnormalStateTickRoutine::~…` FUN_004014b0, `ASE_Tick::~ASE_Tick` FUN_00401b10, `ListIteratorAbstateEquip::~…` FUN_004027f0 | reset the vftable (the tick routine also runs the empty `astr_Tick` destructor, the folded FUN_00417480) | compiler-generated: the element / actor destructors and the unwind funclets (1 863 and 377 references are the folded bodies being shared) |
| `sasa_IndexString` of `SubAbnormalStateMaxHP` FUN_004015f0, `…Fear` FUN_00401600 (shared by two actor classes), `…Captivate` FUN_00401610, `…ActerTimeAttack` FUN_004016f0, `…DamageMinus` FUN_004017b0, `…RangeDamageMinusAtk` FUN_00401810 | return "MaxHP", "Fear", "Captivate", "TimeAttack", "DamageMinusRate", "DamageMinusAtk" | actor vt 0x00 (Z22 §1.2 table: the other classes' strings), for the abstate log only |

### 6.2 Character classes (`CharClass`, 29 classes)

Each player and mob holds a pointer to one static class object (`smo_CharClass` +0xfbc, `so_CharacterClass` vt
0x49c). `CharClassManager` owns the 29 objects (`ccm_classdefault`, `ccm_classfighter` … `ccm_classsavior`,
`ccm_classmob`); its destructor FUN_0044a130 runs `CharClass::~CharClass` FUN_004497b0 (vftable reset +
`OptionReader::~OptionReader`, the `ChrCommon` parser base) on each, in reverse order. Slots 0x20-0x34 are Z12 §3.1.
The PDB's folded stubs carry several names each; the slot meaning below follows the classes that override a slot
with a unique body (e.g. `CharClassHighCleric` +0x38 = `HighCleric::cc_ClassType`, +0x44 = `HighCleric::cc_PromoteClass`).

| Slot | Member | Body |
|---|---|---|
| 0x38 | `cc_ClassType` | own class id (table below); base `CharClass` 0 |
| 0x3c | `cc_AttackRhythm` | `&attrhythm_melee` (FUN_004496b0); archer line `&attrhythm_range` (FUN_00449840); mob `&attrhythm_mob` (FUN_004496e0); §6.3 |
| 0x40 | `cc_JustAfterSkill(mo)` | no-op FUN_00549070; mage line FUN_00449900: `mo.smo_BashStop()` (vt 0xed8): a mage's auto-attack stops after a skill |
| 0x44 | `cc_PromoteClass` | the next class of the line; the two last classes and Warrior / Paladin / Scout / Enchanter / Cruel return their own id (they branch) |
| 0x48 | `cc_BaseClass` | first class of the line: 1, 6, 11, 16, 21, 26; base and mob 0 |
| 0x4c | `cc_NormalHitDelay_AfterSkill` | 3 (FUN_00556e40); archer line 0 (FUN_00570b00) |
| 0x50 | `cc_CanNormalAttack(o)` | FUN_004496c0: `not o.so_mobile_DuringFlying()` (vt 0x7c0); archer line FUN_00500380 `true` |
| 0x54 | `cc_IsDescendantsOf(id)` | true when `id` is a strict ancestor (table); base `false` (FUN_00615e70) |

| id | Class | Promote | Base | `cc_IsDescendantsOf` true for | Function |
|---|---|---|---|---|---|
| 0 | `CharClass` (default) | 0 | 0 | – | |
| 1 / 2 / 3 | Fighter / CleverFighter / Warrior | 2 / 3 / 3 | 1 | – / 1 / 1, 2 | FUN_00449710, FUN_00449720 |
| 4 / 5 | Gladiator / Knight | own | 1 | 1, 2, 3 | FUN_00449750 (shared) |
| 6 / 7 / 8 | Cleric / HighCleric / Paladin | 7 / 8 / 8 | 6 | – / 6 / 6, 7 | FUN_004497a0, FUN_004497c0 |
| 9 / 10 | HolyKnight / Guardian | own | 6 | 6, 7, 8 | FUN_004497f0 |
| 11 / 12 / 13 | Archer / HawkArcher / Scout | 12 / 13 / 13 | 11 | – / 11 / 11, 12 | FUN_00449850, FUN_00449870 |
| 14 / 15 | SharpShooter / Ranger | own | 11 | 11, 12, 13 | FUN_004498b0 |
| 16 / 17 / 18 | Mage / WizMage / Enchanter | 17 / 18 / 18 | 16 | – / 16 / 16, 17 | FUN_00449920, FUN_00449930 |
| 19 / 20 | Warrock / Wizard | own | 16 | 16, 17, 18 | FUN_00449960 |
| 21 / 22 / 23 | Joker / Chaser / Cruel | 22 / 23 / 23 | 21 | – / 21 / 21, 22 | FUN_004499b0, FUN_004499d0 |
| 24 / 25 | Closer / Assassin | own | 21 | 21, 22, 23 | FUN_00449a00 |
| 26 / 27 | Sentinel / Savior | 27 / 27 | 26 | – / 26 | FUN_00449a40 |
| 28 | `CharClassMob` | 0 | 0 | – | |

The `mov eax, n; ret` stubs of slots 0x38 / 0x44 / 0x48 (FUN_00557bb0 1, FUN_00647230 2, FUN_00556e40 3, FUN_00449740 4,
FUN_0063e3a0 5, FUN_00449780 6, FUN_00449790 7, FUN_0063e3d0 8, FUN_0063e3f0 9, FUN_004497e0 10, FUN_00449820 11,
FUN_00449830 12, FUN_00449860 13, FUN_00449890 14, FUN_004498a0 15, FUN_004498e0 16, FUN_004498f0 17, FUN_0063e420 18,
FUN_00449950 19, FUN_00449990 20, FUN_0063e440 21, FUN_004499a0 22, FUN_004499c0 23, FUN_004499f0 24, FUN_0063e430 25,
FUN_0063e470 26, FUN_00449a30 27, FUN_0063e4a0 28; FUN_00570b00 0) are shared with unrelated slots of the same value
(e.g. the attribute classes' `iac_ItemClass` vt 0x28, §3.5): `n` is all they do.

Slot callers (scan of every function that reads `+0xfbc` / vt 0x49c): vt 0x40 `ShinePlayer::so_Routine` FUN_0056c790
and `smo_SkillResultPacket` FUN_0057a630; vt 0x44 `so_ply_FirstJobChange` FUN_0049fa70 (Z15); vt 0x48 twelve
(`smo_SwingStart`, `smo_ply_NormalAttackFactor` §4.4, `sp_Schedule_SwingStart`, `so_AttackRange` §4.4, the reinforce
removes, `so_ply_CheckCharType`, `sp_GetItemWhoEquip_ClassGroup`, `sp_ThirdPromote`, `CharClassValidator::check`, the
Lua `cGetBaseClass`, `AxialListFindNearPlayer::ali_Work`); vt 0x50 `sp_Schedule_SwingStart` FUN_00430bc0 (Z03 §3.2);
vt 0x54 `NPCAction::ClassCondition::check` FUN_005c26e0 (Z09 §16.4). vt 0x4c: no call through it was found.

### 6.3 Attack rhythm: the swing animation number (`AttackRhythm`)

`smo_AttackRhythm` (`ShineMobileObject` +0x1d70) is an `AttackRhythm::CharArgument` `{ AttackRhythmBase*
ca_attrhythm, u8 ca_group (+4), u8 ca_point (+5) }`. `so_mob_RegenComplete` FUN_004424f0, `sp_NC_MAP_LOGINCOMPLETE_CMD`
FUN_00443390 and `so_smv_SummonMover` FUN_0055fdf0 set `ca_attrhythm = class.cc_AttackRhythm()` (vt 0x3c) and
group = point = 0. Three static rhythm objects with three slots each:

```pseudo
slot 0 arb_Next(arg, int baseClass)     # smo_SwingStart FUN_0042f3f0 after each 0x2447, with class.cc_BaseClass() (0 without class)
slot 4 arb_ActionNumber(arg) → int      # smo_SwingStart: byte actioncode of 0x2447 NC_BAT_SWING_START_CMD (Z03 §3.2)
slot 8 arb_NextBash(arg, int interval)  # ShinePlayer::smo_ply_NextBashTime FUN_0055ac90 with sp_BashControl.bashinterval (§2.7)

AttackRhythm_Melee (attrhythm_melee, 0x74d680: vftable + arm_table[12][3] preset in .data)
    arb_Next  @ FUN_00427c70:  ++ca_point; if ca_point > 2:
                                   ca_point = 0
                                   ca_group = baseClass == 21 (Joker line) ? rand 0..5 : rand 0..11     # rndbox.rb_box[6] / [12]
    arb_ActionNumber @ FUN_00427cd0:  arm_table[ca_group > 11 ? 0 : ca_group][ca_point]
    arb_NextBash     @ FUN_00427d00:  ca_group ≥ 6 and ca_point ≠ 0 ? interval × 1180 >> 17 (≈ interval × 0.9 / 100)
                                                                    : interval × 10 / 1000
    arm_table rows: 0 {0,1,2}  1 {0,2,1}  2 {1,0,2}  3 {1,2,0}  4 {2,1,0}  5 {2,0,1}  6-11 {3,4,5}
AttackRhythm_Range (attrhythm_range; archer line)
    arb_Next  @ FUN_00427d50:  ca_point = (ca_point + 1) & 2            # from 0 this stays 0 (original bug) Z31-B8
    arb_ActionNumber @ FUN_00427d70:  ca_point
    arb_NextBash = AttackRhythmBase::arb_NextBash @ FUN_00427c10:  interval × 10 / 1000
AttackRhythm_Mob (attrhythm_mob; CharClassMob)
    arb_Next = empty fold FUN_00509900; arb_ActionNumber = `return 0` fold FUN_004a9c90; arb_NextBash = FUN_00427c10
```

So melee classes swing in cycles of three animations: a random permutation of 0, 1, 2, or (in half of the cycles,
never for the Joker line) the combo 3, 4, 5, whose second and third swings come 10 % sooner. Ranged swings always
send animation 0, and mobs always 0. `AttackRhythmBase` itself has no instance (its slots 0 / 4 are the pure-call
stub FUN_006583ea).

### 6.4 Rules of engagement: base slots, damage immunity, `EngNormAtt` / `EngSklAtt`

The rule-set objects (`roe_normalPY`, `roe_normalMA`, `roe_physical`, `roe_magical`, `roe_cure`, `roe_always`,
`roe_alwaysCritical`, `roe_alwaysHealAttack`) and their slots are Z03 §4.2. The base `RulesOfEngagement` has no
instance; its bodies are reached only through the classes that keep them:

```pseudo
RulesOfEngagement::roe_HitRate(ctx) → ‰   (vt 0x18; only RuleOfEngagementHealAttack keeps it)        @ FUN_004ffb50
    if this.vt[0x14](ctx) (shield block rate; 0 for HealAttack) > rand(1000): ctx.isshieldblock = 1; return 0
    f = def.so_parameter().MissPercentFix (+0xcd0)
    f == 0: return 1000           (log " Shield Fail")
    f ≤ 1000: return 1000 − f;    else return 0
    # roe_alwaysHealAttack is used only for vt 0x20 / 0x1c inside smo_SkillBlast (Z25 §2.5), so this body is never run

RulesOfEngagementNormalPY::roe_IsDamageImmune(ctx) → bool  (vt 0x38; NormalPY, PhisycalSkill, AlwaysCritical)  @ FUN_005043e0
    ctx.def == null: return true
    return rand(1000) < def.so_parameter().PhysicalImmuneRate (+0xda4)       # SAA_ACSHIELDRATE (Z12 §2.5)
RulesOfEngagementNormalMA::roe_IsDamageImmune(ctx)  (vt 0x38; NormalMA, MagicalSkill)                 @ FUN_005044e0
    same with MagicalImmuneRate (+0xda6)                                    # SAA_MRSHIELDRATE
RulesOfEngagement::roe_IsDamageImmune(ctx) = false  (vt 0x38; base, CureSkill, AlwaysHit, HealAttack) @ FUN_00504390
    # caller: roe_CalcDamage (Z03 §4.5: immune → ctx.isImmune = 1, damage 0)
```

Other base bodies: `roe_ShieldBlock` FUN_004ffd90 `return 0.0` (fills 38 slots of the base, NormalMA, MagicalSkill,
CureSkill, AlwaysHit, HealAttack vftables: every "rate" those classes do not define is 0), `roe_CriticalStunRate`
FUN_00500170 = 200 (vt 0x00 of all but AlwaysCritical), `roe_IsDamageSkill` FUN_004ff840 = `ctx.sklinfo ?
sdi_ServInf.UsualAttack : 0` (vt 0x20), `roe_Damage(ctx, a, b)` FUN_00500510 (vt 0x10 of the base family: `max(1, nBMPDamageRate × a / 1000) ×
(att.so_GetLevel() + 1) / b`, with BalanceLog output; *(inferred: a = attack, b = defence)*), and FUN_004ffda0 `return 1000.0` (AlwaysHit /
CureSkill hit rate and evasion slots, AlwaysCritical critical slots; Z11 §6.4 `&allcritical`).

`EngNormAtt` (`engnormatt`) and `EngSklAtt` (`engsklatt`) are an older damage model with fixed results:

```pseudo
EngNormAtt::ena_physichitrate(a, d, flag) = 500 + ena_LH(|Δ|) × (a.so_GetLevel() − d.so_GetLevel())   @ FUN_004fc440   (slots 0 / 4)
EngNormAtt::ena_LH(n) = 30                                                                                @ FUN_004fc430   (slot 0x10)
EngNormAtt::ena_physicdamage = 1                                                                           @ FUN_004fc490   (slots 8 / 0xc)
EngNormAtt::ena_attack(a, d, flag, u8* crit)   (slot 0x14)                                                 @ FUN_004fc4a0
    if slot0(a, d, flag) < rand(1000): return 0
    dmg = slot8(a, d, flag)                                   # 1
    rand 0..9 == 0: *crit = 1; return 2 × dmg;  else *crit = 0; return dmg
EngSklAtt::ena_attack(a, d, flag, crit)   (slot 0x14)                                                      @ FUN_00500450
    flag.efm_sklinfo == null: assert "EngSklAtt::ena_attack : Null skill info"; return 0
    if not sdi_ServInf.UsualAttack: return 0
    dmg = (esa_physicaldamage + esa_masicaldamage) × DmgIncRate / 1000 + DmgIncValue;  1 in 10: ×2, *crit = 1
EngSklAtt::esa_physicaldamage(a, d, flag)                                                                   @ FUN_004fc530
    PsySucRate ≠ 0: hit = rand(1000) ≤ PsySucRate
    else SkilPyHitRate == 0: return 0;  else hit = slot0(a, d, flag) ≥ rand(1000) and rand(1000) ≤ SkilPyHitRate
    hit: return MinWC + (MaxWC − MinWC < 100 ? rand 0..(MaxWC − MinWC) : 0) + slot8(…)
EngSklAtt::esa_masicaldamage(a, d, flag)                                                                    @ FUN_004fc630
    same rolls with MagSucRate / SkilMaHitRate, then advances the random box of MaxMA − MinMA and returns only slot 0xc (1):
    MinMA and the spread are dropped (original bug) Z31-B9
```

`EngNormAtt::ena_attack` is called only by the dead `ShineMobileObject::so_attack` FUN_0042cab0 (Z09 §7.8).
`engsklatt` is referenced only by its initializer and atexit destructor: `EngSklAtt` is dead.

### 6.5 Mob AI objects

**The kill-credit list 0x244C** (`MobTargetBout::mts_SlayerList` FUN_004bd630, selector vt 0x30; the builder Z03 §11
left open). `ShineMob::so_KilledBy` FUN_00432760, when the mob's `MobInfoServer.BroadAtDead` is set:

```pseudo
    Send to WM 0x244C NC_BAT_MOBSLAYER_CMD (pdb2017) {               # length 5 + 4·number (2-byte opcode included)
        u16 killedmob = MobInfoServer.ID
        u8  number
        u32 slayers[number]
    } = sm_ArtificalIntelligence.maa_TargetSelect.selector.vt[0x30](&payload, ID)
MobTargetBout::mts_SlayerList(pkt, killedmob):        number = 0; killedmob = killedmob
    l_4AllInList(mtb_targetlist (the mob's MobAggroManager, Z09 §6.1), SlayerCollect { sc_Packet = pkt })
SlayerCollect::lid_Call(MobTargetStruct s, h) → continue                                         @ FUN_004bd440
    o = s.mts_Object
    if o ≠ null and o.so_ObjectType() == 2 (player) and not o.IsClosing() (vt 0x300)
       and o.so_GetCharRegistNumber() (vt 0x344) == s.mts_CharRegnum:        # the handle was not reused by another character
        pkt.slayers[pkt.number++] = s.mts_CharRegnum
```

Every player still on the aggro list (at most its 10 entries) counts, whatever their damage. All seven `MobTarget*`
selector classes share this slot; the base `MobTargetSelector` has the empty fold FUN_00509900, which would leave
`number` unwritten in the shared send buffer *(no mob without a Bout-derived selector was checked)*. In 2016 six
`MobInfoServer` rows set `BroadAtDead`: Helga, B_CrackerHumar, BH_Helga, BH_Humar, Chimera, Anvil. The WM registers
no handler for 0x244C (`re-data/exports/wm/handlers.json`), so the list goes nowhere.

| Function | Body | Callers |
|---|---|---|
| `ListMaximumSearch<HitMeList::Enemy>::lid_Call` FUN_00481660 | `v = lms_compfunc(lms_lst, h)`; first entry or `v > lms_maxval` → remember `{lms_hnd = h, lms_maxval = v, lms_max = entry}` | `HitMeList::EnemyList::el_Store` FUN_00482070 (Z09 §6.9: the entry with the least damage is replaced) |
| `HitMeList::EnemyList::~EnemyList` FUN_00482b50 / scalar deleting FUN_00482e10 | free `el_vecEnemyPlayer`, then the `List<Enemy>` array | `~ShineMob` FUN_00556340 |
| `MobAggroManager` scalar deleting FUN_004bd6a0 | destroy the 10 inline `MobTargetStruct` (0x20 each), free the list array | vt 0 (mob destruction) |
| `MobTargetSelector` FUN_004a9df0, `MobTargetBout` FUN_004bd570 (also `MobTargetNoBrain`), `MobTargetAggresive` FUN_004bd5a0 (also `…Aggresive2`), `MobTargetAggresiveALL` FUN_00548dd0 / `~` FUN_00548dc0, `MobTargetAggresiveNoLevel` FUN_00549d60, `MobTargetPlayerCaptivate` FUN_0054df00 / `~` FUN_0054dea0 (scalar deleting = selector vt 4) | each destroys its `IntelligenceOffice4Mob` analysers (`mta_InstanceTarget`, `PlayerTarget`) and its base, then the `AxialListIterator` base | mob destruction |
| `MobCondition` scalar deleting FUN_004b00e0 (also `MobHPcondition`) | vftable reset, delete | `sm_pMobConditionList` cleanup |
| `MobRegenClass::MobBreederGroup` scalar deleting FUN_004b2fd0 | destroy the 100 inline `MobBreeder` (0x40 each, empty destructor), free the list array | vt 0 (`MobHatchery` teardown, Z09 §10.2) |
| `ListEraser<MobAttackSequence::SkillChange>` FUN_004a8690, `ListEraser<MobRegenClass::MobBreeder>` FUN_004b1530, `ListEraser<…MobBreederGroup>` FUN_004b2ce0 | vftable reset to `ListIteratorDefault<T>` | the stack iterators of their `l_4AllInList` callers |
| `MobTacticElement::MobActionArgument::~MobActionArgument` FUN_00554190 | `Actor::~Actor(maa_MobActionStruct)`, `Selector::~Selector(maa_TargetSelect)` | `~ShineMob` |
| `MobDeadCount::~MobDeadCount` FUN_004b07a0 | `delete[] mdc_Counter` | field teardown (the counters: Z09 §5.1) |
| `MobDataBox::<mdb_BinData>::~…` FUN_00641d00 | `BinaryData::~BinaryData` on the 11 boxes `groupAbstate`, `mobRegenAni`, `mobKillablePermission`, `moblifetime`, `mobkilllog`, `mobkillannounce`, `questspec`, `mobspec`, `mobweapon`, `mobinfserv`, `mobinf` (reverse of Z09 §5.1's load order) | `mobdatabox` atexit |

### 6.6 Use effects

```pseudo
UseEffect::UseItemCapsule::uib_CanUseItem(actor, p, info) → code   (vt 4)                       @ FUN_005969f0
    p null: 0x701;  info null: 0x702
    t = itmattcontainer[info.itemid].vt[0xac](&info.iti_itemstruct)    # FUN_0063e410: itemattr + 8 = ShineItemAttr_Capsule.useabletime
    if t ≠ null and t.year ≠ 0 and now (chargeditemcheck.ct_Current) ≤ t (year, month, date, hour, minute compared in turn):
        return 0x700                                                  # inside the capsule's period
    return 0x726                                                      # no date or the period is over (no text in client-error-codes.json)
```

`useabletime` = creation time + `ChargedItemEffect.KeepTime_Hour` (`sp_MakeCapsuleItem` FUN_0049cce0 through attribute
vt 0xb0, §3.5). The check runs in `ItemUse_Inventory` (Z04 §6.1) before `UseItemCapsule::uib_DirectUse` FUN_0059bf00
(`sp_CapsuleItemOpen`, Z05 §6.3), so a capsule can be opened only until its period ends.

```pseudo
UseEffect::UseItemSkillDummy2Real::uib_Effect(actor, p, info, f)  (vt 0x10)                      @ FUN_00596640
    p.so_ply_ItemMakeItem(info)   (player vt 0x32c, its only caller)
ShinePlayer::so_ply_ItemMakeItem(p, info)                                                          @ FUN_0049c680
    info null: return
    to = bsearch(itemconvmap, info.itemid).icm_To, 0xFFFF if absent     # the dummy card → container map, Z09 §10.10
    item = new ItemTotalInformation; iti_mkregnum(&item, to, 6, zone no, world no)
    if itemdatabox[to] has a row:
        itmattcontainer[to].vt[0x14](to, &item, "-o")                   # iac_itemcreate with the empty GM option string (§3.5)
        sp_MakeItem(p, p.handle, &item)                                 # into the inventory (Z04)
```

The check before it is `UseItemSkillDummy2Real::uib_CanUseItem` (§2.2: one free cell). The effect runs when the
Character DB has confirmed the dummy's consumption (Z04 §6.3).

Constructors and destructors: `UseItemNormal::UseItemNormal` FUN_00596420 / `~UseItemNormal` FUN_00596430 (vftable
only), `UseItemJustReviveAtDead::UseItemJustReviveAtDead` FUN_00417490 and its scalar deleting destructor FUN_00417820
(the revive effect is Z21), `UseItemMysteryBolt` scalar deleting FUN_0059aa80 is the folded vt 0 of 35 `UseItem*`
classes (reset to `UseItemBase::vftable`, delete). The actors are static (`ui_Capsule` etc.), built at start-up.

### 6.7 Target analyser, looting, brief-info buffers, skill list

- `TargetAnalyser` (`ta_body` +4): ctor FUN_00591d50, dtor FUN_00591d70, `ta_me(o)` FUN_00591d80 = `o.handle == ta_body.handle`
  (slot 0); `TargetAnalyser_Player::ta_enemy(o)` FUN_00591da0 = `o.vt[0x89c]()` (slot 4), `ta_friend(o)` FUN_00591dc0 =
  `o.so_ObjectType() == 2` (slot 8); base slots 4 / 8 = `return false` fold FUN_00615e70. The mob (`sm_TargetAnalyser`
  +0x1eb0) and the player (`sp_TargetAnalyser` +0x5e14) construct one, set its body, and store it in
  `smo_TargetAnalyser.analyser` (+0x188; `ShineMobileObject` default: the static `TA::tmp`). Nothing reads +0x188 or
  calls the slots: dead in 2016.
- `CLooting::CLooting` FUN_00645370: the four `m_ItemLootingType` = LOOTING_TYPE_FREE, `m_Looter` = 0xFFFFFFFF; called by
  `Raid::Raid` FUN_0063d180 (the zone's raid copy; the WM twin is W05 / W02 §1.4).
- `BriefInfoExchangeAbstate::BriefInfoExchangeAbstate` FUN_0043ddc0: 28 `bixaPacketbuffer` (0x164 bytes) each prepared
  as `0x1C19 NC_BRIEFINFO_ABSTATE_CHANGE_LIST_CMD { handle 0xFFFF, count 0 }` with buffer size 341; `bixa_count` = 0,
  `bixa_Pointer` = the first payload. The batching is Z18 §2.2 (`bixa_Init` FUN_0043c6b0).
- `CharaterSkillList::~CharaterSkillList` FUN_00447f40: frees the `csl_ToggleSkill` and `csl_Skill` vectors; called by
  `~ShinePlayer` (§2.9). The list itself is Z23.

## 7. Table templates: `BinaryDataBox<T>`, `SHND::CommonData<T, Cmp>`, `ITableBase<Row, Table>`, `Table::Load<T>`

The zone reads its SHN files through three template families. Their bodies were documented by earlier items:
`BinaryDataBox<T>::bdb_ReadData` (the checked `CDataReader::Read(path, key, rowSize)`) in Z20 §2.1,
`SHND::CommonData<T, Cmp>` (layout, construction, `cd_Load`, `cd_Find`) in Z28 §2, and `Table::Load<T>` →
`ITableBase<Row, Table>::Load` → `DataProcess` in Z21 §4.1. The stage that loads each file is Z01 §2.3. This section
adds the instances no document cited: about 200 functions, most of them 10-40 line copies of one template body.
Each subsection gives the template once and then lists the instances.

### 7.1 `CDataReader`, `BinaryData`, `BinaryDataBox<T>`: layout and destructors

```
CDataReader   (size 0x40)                                   *(pdb2016)*
    +0x00  vftable (1 slot: scalar deleting dtor FUN_0062a260)
    +0x04  m_nFileSize   +0x08 m_nBFSize   +0x0c m_nDataArraySize   +0x10 m_nFileCheckSum
    +0x14  Name8 m_sFileMD5
    +0x34  HEAD* m_pHead      HEAD (0x34): +0 nVersionKey, +4 sVersion[20], +0x18 nReserved, +0x1c nDataMode,
                              +0x20 nFileSize, +0x24 nDataSize, +0x28 nNumOfRecord, +0x2c nFieldSize, +0x30 nNumOfField, +0x34 FIELD[]
    +0x38  uchar* m_pData     +0x3c uchar** m_pDataArray   (row pointers: GetRecord(i) = m_pDataArray[i])
BinaryData : CDataReader                (0x40, no members; own vftable, 1 slot FUN_0063cf60)
BinaryDataBox<T> : BinaryData           (0x40 + sizeof T)
    +0x40  T bdb_defaultblock            the row returned for an index past the end (Z28 §2.3: that branch is dead in every user)
```

The "rowcount at reader data +0x28" of Z28 §2.3 is `m_pHead->nNumOfRecord`.

```pseudo
BinaryDataBox<T>::~BinaryDataBox(this)                         @ the "~BinaryDataBox<T>" column below
    this.vftable = BinaryDataBox<T>::vftable
    BinaryData::~BinaryData(this)                              # → CDataReader::~CDataReader: frees the file buffer and the row array

BinaryDataBox<T>::`scalar deleting destructor'(this, flags)    @ the "scalar deleting dtor" column below
    same as ~BinaryDataBox; if flags & 1: operator delete(this)

BinaryData::`scalar deleting destructor'(this, flags)          @ FUN_0063cf60
    this.vftable = BinaryData::vftable; CDataReader::~CDataReader(this); if flags & 1: operator delete(this)
```

Callers. The normal path never calls the named `~BinaryDataBox<T>` bodies. The owners inline
`BinaryData::~BinaryData` (for example every `cd_Load` destroys its stack reader that way, Z28 §2.3). The only direct
callers are the compiler's exception-unwind funclets of the owner's constructor, destructor or loader (for example
`__unwindfunclet$?mht_Load@MultiHitTable…`, `…??0<unnamed-type-mdb_BinData>@MobDataBox…`). Each scalar deleting
destructor is slot 0 of its `BinaryDataBox<T>` vftable, and in 74 of the 77 instances the vftable is its only
reference in the image. No `delete` through a `BinaryData` pointer was found, so these destructors never run
*(inferred: the boxes are globals, members or stack objects)*. The other three bodies are each referenced by a second
vftable: `BinaryDataBox<MerchantLocation>` FUN_004c7d10 by `MerchantCityData`, `BinaryDataBox<ShineReward>` FUN_0064ca80
by `RewardData`, and `BinaryDataBox<FriendPointReward>` FUN_0064cb40 by `FPRewardData`. These derived boxes add no
code to the destructor, so identical-code folding gives them the same body.

All instances follow. Every function in the table is the template above with the row type's key, size and vftable;
the readers check `HEAD.nVersionKey == key` and `nFieldSize − 2 == row size` (Z20 §2.1). Every key and size equals
the `DataVersionKey` / `row_bytes` of `docs/knowledge/S01-shn-structs.tsv`. Where a row type has no reader under its
own name, another instance with the same key and row size reads it (identical-code folding: the PDB keeps one name).
"Owner" is the loader that holds the box and the item that documents it.

| Row type `T` | `bdb_ReadData` (key / row size) | `~BinaryDataBox<T>` | scalar deleting dtor (vftable slot 0) | Owner and loader |
|---|---|---|---|---|
| `SubAbStateInfo` | FUN_00416940 (0x42c / 0x4f) | – | FUN_00416ac0 | `SubAbState::sas_Load` FUN_00416bd0 (Z25) |
| `AbnormalStateInfo` | FUN_00416a00 (0xfca / 0x121) | FUN_004169f0 | FUN_00416af0 | `AbState::as_Load` FUN_00416e80 (Z25) |
| `AbStateSaveTypeInfo` | FUN_006416e0 (0x16 / 7) | FUN_00416ab0 | FUN_00416b20 | `AbState::as_Load` FUN_00416e80 (Z25) |
| `BRAccUpgrade` | FUN_0043b8c0 (0x51 / 0xe) | FUN_0043b8b0 | FUN_0043b960 | `BRAccUpgradeDataBox::LoadBRAccUpgradeData` FUN_0043bb00 (Z18) |
| `BRAccUpgradeInfo` | no reader under its own name (a key / size twin or inline in the owner) | – | FUN_0043b990 | `BRAccUpgradeDataBox::LoadBRAccUpgradeData` FUN_0043bb00 (Z18) |
| `ChargedItemEffect` | FUN_005ae790 (0x8d / 0x2b) | – | FUN_0044fb80 | `ChargedItemEffectDataBox<ChargedItemEffect>::cideb_Load` FUN_005af300 (Z24) |
| `MiniHouseFurniture` | FUN_005ae8f0 (0x3f9 / 0x94) | – | FUN_0044fc70 | `ChargedItemEffectDataBox<MiniHouseFurniture>::cideb_Load` FUN_005af6d0 (Z13) |
| `StateField` | FUN_004628e0 (0x39 / 0x30) | FUN_004639f0 | FUN_00463a10 | `FieldContainer::fc_AbstateInFieldLoad` FUN_00464950 (Z22 §7.5) |
| `MapBuff` | FUN_00462980 (0x67 / 0x30) | FUN_00463a00 | FUN_00463a40 | `MapBuffDataBox::mbdb_Load` FUN_004670b0 (Z01 §2.3) |
| `FieldLvCondition` | FUN_0046a280 (0x20 / 0x26) | – | FUN_0046a320 | `FieldLevelDataBox::fldb_Load` FUN_0046a350 (Z14) |
| `PartyBonusByLvDiff` | folded: CollectCardDropRate FUN_00481440 (7 / 4, Z28 knowledge) | FUN_00481430 | FUN_00481600 | `LevelHandicap4ExperienceDouble::lh4ed_Load` FUN_00481a80 (Z28 §3.8) |
| `ItemShop` | FUN_00492180 (0x3d / 0x28) | FUN_00492170 | FUN_004922e0 | `ItemMall::im_Load` FUN_00493250 (§3.6) |
| `ItemServerEquipTypeInfo` | FUN_00492230 (0x3e9 / 0x1d) | FUN_00492220 | FUN_00492310 | `ItemEquipTable::iet_Load` FUN_00493140 (Z18) |
| `RandomOptionCount` | FUN_00493380 (0x12 / 0x25) | FUN_00493370 | FUN_00493430 | `RandomOptionTable::rot_Load` FUN_00494570 (Z01 §2.3; §8) |
| `RandomOption` | no reader under its own name (a key / size twin or inline in the owner) | FUN_00493420 | FUN_00493460 | `RandomOptionTable::rot_Load` FUN_00494570 (Z01 §2.3; §8) |
| `KINGDOM_QUEST_REW` | FUN_0049a860 (0x32a9 / 0x80) | – | FUN_0049a910 | `KQRewardDataBox::kqrdb_Load` FUN_0049a940 (Z01 §2.3) |
| `LCGroupRate` | FUN_0049beb0 (0x16 / 9) | FUN_0049bea0 | FUN_0049bff0 | `CLCReward::clcr_Load` FUN_0049d420 (Z01 §2.3) |
| `LCReward` | FUN_0049bf50 (0x33 / 0x22) | – | FUN_0049c020 | `CLCReward::clcr_Load` FUN_0049d420 (Z01 §2.3) |
| `TownPortal` | FUN_0049f0e0 (0xd5 / 0x2b) | – | FUN_0049f240 | `TownPortalData::tpd_Load` FUN_0049fbc0 (Z30) |
| `MiniHouseEndure` | FUN_004a1100 (0xfb / 10) | – | FUN_004a11b0 | `MiniHouseEndureDataBox::mhe_Load` FUN_004a11e0 (Z13) |
| `MiniHouseObjAni` | FUN_004a1580 (0x271 / 0x27) | – | FUN_004a1630 | `MiniHouseObjAniDataBox::mhoadb_Load` FUN_004a1970 (Z13) |
| `MinimonInfo` | FUN_004a1ae0 (0x33 / 0x28) | FUN_004a1ad0 | FUN_004a1c30 | `CMinimonDataBox::mmdb_Load` FUN_004a27f0 (Z13) |
| `MinimonAutoUseItem` | no reader under its own name (a key / size twin or inline in the owner) | FUN_004a1b80 | FUN_004a1c60 | `CMinimonAutoUseItemDataBox::mauidb_Load` FUN_004a2b80 (Z13) |
| `MoverMain` | FUN_004bf320 (0xba / 0x33) | FUN_004bf310 | FUN_004bf600 | `MoverDataBox::mvdb_Load` FUN_004bf960 (Z13) |
| `MoverAbility` | FUN_004bf3e0 (0x388 / 0x61) | FUN_004bf3d0 | FUN_004bf630 | `MoverDataBox::mvdb_Load` FUN_004bf960 (Z13) |
| `MoverHG` | FUN_004bf4a0 (0x95 / 0x4a) | FUN_004bf490 | FUN_004bf660 | `MoverDataBox::mvdb_Load` FUN_004bf960 (Z13) |
| `MoverItem` | FUN_004bf560 (0x2c / 0x40) | FUN_004bf550 | FUN_004bf690 | `MoverDataBox::mvdb_Load` FUN_004bf960 (Z13) |
| `MoverUseSkill` | folded: MoverItem FUN_004bf560 (0x2c / 0x40) | – | FUN_004bf6c0 | `MoverDataBox::mvdb_Load` FUN_004bf960 (Z13) |
| `MultiHitType` | FUN_004c09b0 (0xac / 0x2a) | FUN_004c09a0 | FUN_004c0a60 | `MultiHitTable::mht_Load` FUN_004c0ff0 (Z25) |
| `MerchantLocation` | FUN_004c5820 (5 / 5) | – | FUN_004c7d10 | `MerchantCityData::mcd_Load` FUN_004c77b0 (§9) |
| `SpamerPenaltyRule` | FUN_005896f0 (5 / 3) | FUN_005896e0 | FUN_00589790 | `SpamerPenaltyDataBox::spdb_Load` FUN_005897f0 (Z02) |
| `SpamerPenalty` | folded: GBSMGroup FUN_0061df60 (0x12 / 5) | – | FUN_005897c0 | `SpamerPenaltyDataBox::spdb_Load` FUN_005897f0 (Z02) |
| `StateItem` | FUN_0058bfe0 (0x4d / 0x46) | FUN_0058bfd0 | FUN_0058c080 | `cStateItemDataBox::sidb_Load` FUN_0058c920 (Z24) |
| `UpGradeInfo` | FUN_00596160 (0xa2b / 0x3e) | – | FUN_00596210 | `UpgradeDataBox::udb_Load` FUN_00596240 (Z12) |
| `ItemUseEffect` | FUN_00596b20 (0x23b / 0x56) | – | FUN_00596bd0 | `UsedItemEffect::uie_Load` FUN_0059cc30 (Z24) |
| `GBBanGame` | FUN_005aec00 (0x23 / 0xc) | FUN_005aebf0 | FUN_005aef30 | `CommonData<GBBanGame, CmpGameType>::cd_Load` FUN_005b85c0 (§7.3) |
| `GBTaxRate` | FUN_005aecb0 (0x38 / 0xc) | FUN_005aeca0 | FUN_005aef60 | `CommonData<GBTaxRate, CmpGameType>::cd_Load` FUN_005b8720 (§7.3) |
| `GBReward` | FUN_005aed60 (0x67 / 0x28) | FUN_005aed50 | FUN_005aef90 | `CommonData<GBReward, CmpGambleItemReward>::cd_Load` FUN_005b8880 (§7.3) |
| `GBEventCode` | folded: GBBanGame FUN_005aec00 (same key 0x23 / 0xc) | FUN_005aee00 | FUN_005aefc0 | `CommonData<GBEventCode, CmpEventCode>::cd_Load` FUN_005b8aa0 (§7.3) |
| `AccUpGradeInfo` | FUN_005c5160 (3999 / 0x70) | FUN_005c5150 | FUN_005c5210 | `AccUpGradeDataBox::augdb_Load` FUN_005c69b0 (§8) |
| `StateMob` | FUN_005d21b0 (0x9a / 100) | FUN_005d21a0 | FUN_005d23d0 | `ServentBuffBossTable::sbbt_Load` FUN_005d4580 (Z09) |
| `MobAbStateDropSetting` | FUN_005d2270 (0x58 / 0x47) | FUN_005d2260 | FUN_005d2400 | `ListOfMobStateCheckAtDead::lomscad_Load` FUN_005d5970 (Z09 §8.9) |
| `MobAutoAction` | FUN_005d2320 (0x160 / 0x51) | FUN_005d2310 | FUN_005d2430 | `MobAutomaticActionList::maal_Load` FUN_005d49f0 (Z09) |
| `GBSMCardRate` | FUN_0061dea0 (7 / 6) | FUN_0061de90 | FUN_0061e110 | `SlotMachineScreenManager::smsm_Load` FUN_00624820 (Z06) |
| `GBSMNPC` | no reader under its own name (a key / size twin or inline in the owner) | FUN_0061df40 | FUN_0061e140 | `SlotMachineScreenManager::smsm_Load` FUN_00624820 (Z06) |
| `GBSMGroup` | FUN_0061df60 (0x12 / 5) | FUN_0061df50 | FUN_0061e170 | `SlotMachineAnalyse::sma_Load` FUN_006239b0 (Z06) |
| `GBSMLine` | no reader under its own name (a key / size twin or inline in the owner) | FUN_0061e000 | FUN_0061e1a0 | `SlotMachineAnalyse::sma_Load` FUN_006239b0 (Z06) |
| `GBSMAll` | no reader under its own name (a key / size twin or inline in the owner) | FUN_0061e010 | FUN_0061e1d0 | `SlotMachineAnalyse::sma_Load` FUN_006239b0 (Z06) |
| `GBSMCenter` | no reader under its own name (a key / size twin or inline in the owner) | FUN_0061e020 | FUN_0061e200 | `SlotMachineAnalyse::sma_Load` FUN_006239b0 (Z06) |
| `GBSMJackpotRate` | FUN_0061e040 (0x1b / 0xc) | FUN_0061e030 | FUN_0061e230 | `SlotMachineJackPotRanking::smjpr_Load` FUN_00624270 (Z06) |
| `GBSMBetCoin` | folded: GBSMCardRate FUN_0061dea0 (7 / 6) *(inferred)* | – | FUN_0061e0e0 | `SlotMachineScreenManager::smsm_Load` FUN_00624820 (Z06) |
| `MobInfo` | FUN_00641110 (0x4a9 / 0x6c) | FUN_00641100 | FUN_006418d0 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobInfoServer` | FUN_006411d0 (0x1cf1 / 0xa7) | FUN_006411c0 | FUN_00641900 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobWeapon` | FUN_00641290 (0x9fc / 0x98) | FUN_00641280 | FUN_00641930 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobSpecies` | FUN_00641350 (0x24f / 0x86) | FUN_00641340 | FUN_00641960 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobKillAnnounce` | FUN_006414d0 (0x25 / 8) | FUN_006414c0 | FUN_006419c0 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobKillLog` | folded: ItemDropLog FUN_00641580 (0xb / 4) | FUN_00641570 | FUN_006419f0 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `ItemDropLog` | FUN_00641580 (0xb / 4) | FUN_00648c80 | FUN_006490a0 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `MobLifeTime` | FUN_00641630 (7 / 0x22) | FUN_00641620 | FUN_00641a20 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobKillAble` | folded: AbStateSaveTypeInfo FUN_006416e0 (0x16 / 7) | FUN_006416d0 | FUN_00641a50 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobRegenAni` | FUN_00641790 (0x66 / 0x43) | FUN_00641780 | FUN_00641a80 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `GroupAbState` | FUN_00641830 (0x33 / 0x41) | – | FUN_00641ab0 | `MobDataBox::mdb_Load` FUN_00641e60 (Z09 §5.1) |
| `MobResist` | FUN_00644da0 (0x11e / 0x34) | – | FUN_00644e50 | `MobResistTable::mrt_Load` FUN_00644e80 (Z09) |
| `ItemInfo` | FUN_00648a50 (0x4b67 / 0x17a) | FUN_00648a40 | FUN_00649010 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `ItemInfoServer` | FUN_00648b10 (0x12a2 / 0xde) | FUN_00648b00 | FUN_00649040 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `GradeItemOption` | FUN_00648bd0 (0x268 / 0x3e) | FUN_00648bc0 | FUN_00649070 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `ItemSort` | FUN_00648ca0 (1 / 0x20) | FUN_00648c90 | FUN_006490d0 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `ItemInvenDel` | no reader under its own name (a key / size twin or inline in the owner) | FUN_00648d40 | FUN_00649100 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `ItemMoney` | FUN_00648df0 (0x37 / 0x42) | – | FUN_00649130 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `WeaponAttrib` | no reader under its own name (a key / size twin or inline in the owner) | FUN_00648e90 | FUN_00649160 | `ItemDataBox::idb_Load` FUN_00649780 (Z27) |
| `BelongTypeInfo` | FUN_00648eb0 (0x46 / 10) | FUN_00648ea0 | FUN_00649190 | `ItemBelongAttribute::iba_Load` FUN_0064b210 (Z27) |
| `TermExtendMatch` | folded: MoverItem FUN_004bf560 (0x2c / 0x40) | FUN_00648f50 | FUN_006491c0 | `CTermExtendMatchDataBox::teib_Load` FUN_0064c090 (Z24 §7.6) |
| `KQItem` | FUN_00648f70 (0x22 / 0x26) | FUN_00648f60 | FUN_006491f0 | `KQItemDataBox::kqidb_Load` FUN_0064bd80 (Z16) |
| `ShineReward` | FUN_0064c5e0 (0x96f / 0x42) | – | FUN_0064ca80 | `RewardData::rd_Load` FUN_0064c830 (Z01 §2.3) |
| `ItemOptions` | FUN_0064c6a0 (0x62e / 0x19) | FUN_0064c690 | FUN_0064c7f0 | `ItemOptionsData::iod_Load` FUN_0064cbc0 (Z01 §2.3; §8) |
| `FriendPointReward` | FUN_0064c750 (0x1b / 0x28) | – | FUN_0064cb40 | `FPRewardData::fprd_Load` FUN_0064ca60 (Z08) |
| `MapInfo` | FUN_0064eb40 (0x1f8 / 0x4c) | FUN_0064ee90 | FUN_0064eea0 | `MapDataBox::mdb_Load` FUN_0064ebf0 (Z09) |

Folded readers, in short: `BinaryDataBox<GBBanGame>` FUN_005aec00 also reads GBEventCode.shn; `<GBSMGroup>`
FUN_0061df60 also reads SpamerPenalty.shn (called by `spdb_Load`); `<MoverItem>` FUN_004bf560 also reads MoverUseSkill.shn
and TermExtendMatch.shn (called by `teib_Load`); `<AbStateSaveTypeInfo>` FUN_006416e0 also reads MobKillAble.shn and
`<ItemDropLog>` FUN_00641580 also reads MobKillLog.shn (both called by `mdb_Load`). A wrong row size on any of them
stops the zone (`ShineExit`), so the folding is safe only while the twin files keep equal keys and sizes. In 2016 they do.

### 7.2 `SHND::CommonData<…>` of the gamble tables

Four more instances of the Z28 §2 template hold the gamble configuration. Their users are the gamble classes
(Z06 §4-§5, Z32); here only the tables are described.

| Global *(pdb2016)* | Address | File (`../9Data/Shine/`) | Construction | key / row | rows 2016 | `cd_Load` | Default row |
|---|---|---|---|---|---|---|---|
| `SHND::g_BanTime` | 0x870f5c | GBBanTime.shn | constant-initialised in `.data` (vftable 0x704884, `cd_ShnName` 0x7048b0, `cd_Data` = own vector) | 0x23 / 0xc `GBBanGame {GameType, GB_Ban, GB_BanTime}` | 1 | FUN_005b85c0 | {MT_HUMAN, GB_BAN_NO_PLAY, 0} |
| `SHND::g_TaxRate` | 0x870f78 | GBTaxRate.shn | constant-initialised (vftable 0x704890, name 0x7048c0) | 0x38 / 0xc `GBTaxRate {GameType, u16 GB_TaxRate, GB_JPSave, u16 GB_JPSaveRate}` | 2 | FUN_005b8720 | {MT_HUMAN, 0, 0, 0} |
| `SHND::g_EventCode` | 0x870f94 | GBEventCode.shn | constant-initialised (vftable 0x7048a8, name 0x7048e0) | 0x23 / 0xc `GBEventCode {GameType, GB_ANI, GB_ECode}` (read by the GBBanGame reader) | 14 | FUN_005b8aa0 | the GBBanGame default (same 12 bytes) |
| `SHND::g_GBReward` | – | GBReward.shn | `dynamic_initializer_for 'g_GBReward'` FUN_0069b800: ctor FUN_006153a0(this, "GBReward.shn") (vftable, `cd_Data` = &`cd_MyData`, empty vector, name), atexit FUN_006a0f00 | 0x67 / 0x28 `GBReward {GameType, RewardType, char Item_INX[32]}` | 1 | FUN_005b8880 | {MT_HUMAN, GBSM_JACKPOT, ""} |

```pseudo
zs_start_long():                                               @ FUN_005b8c00 (Z28 §2.4), after the card tables
    g_BanTime.cd_Load(); g_TaxRate.cd_Load(); g_EventCode.cd_Load(); g_GBReward.cd_Load()   # direct calls, not through the vftable

CommonData<GB…>::cd_Load(this)                                 @ FUN_005b85c0, FUN_005b8720, FUN_005b8aa0, FUN_005b8880
    = the Z28 §2.3 body: name null → assert "CommonData<T, C>::cd_Load : Name NULL" + ShineExit;
      path = "../9Data/Shine/" + name; cd_Data.clear(); stack BinaryDataBox<T> with the default row;
      bdb_ReadData (exits on a bad file); push_back a copy of every row; destroy the reader
    # FUN_005b8880 inlines push_back (the "is the source inside the vector" test of std::vector before _Reserve)

CommonData<GBBanGame, CmpGameType<GBBanGame>>::cd_Find(this, CmpGameType key) → row | null       @ FUN_00614e20
    for each row in *cd_Data (file order): if row.GameType == key.cgt_GameType: return row
    return null
    # also used on g_TaxRate (same 12-byte rows, GameType at +0: identical-code folding). Callers:
    #   CGambleDiceTaiSaiObject::go_Init FUN_00614f10 (g_TaxRate, game 0x17), SlotMachineScreen::go_Enter_Player
    #   FUN_00620d00, SlotMachineJackPotRanking::smjpr_Load FUN_00624270
CommonData<GBEventCode, CmpEventCode>::cd_Find(this, {cec_GameType, cec_AnyType})                 @ FUN_00614e90
    first row with row.GameType == cec_GameType and row.GB_ANI == cec_AnyType, else null
    # callers: go_Init FUN_00614f10 (game 0x17 with GB_ANI 0, 1, 2, …), CGambleObject::go_PlayerAction FUN_00615180
CommonData<GBReward, CmpGambleItemReward>::cd_Find(this, {cgir_GameType, cgir_Status})            @ FUN_00620970
    first row with row.GameType == cgir_GameType and row.RewardType == cgir_Status, else null
    # caller: SlotMachine::SlotMachineScreen::SMS_StopButton FUN_00625340
```

The second vftable slot of every instance is the shared external-vector `cd_Load` FUN_00629840 (Z28 §2.3). It is
not called for these four.

### 7.3 `ITableBase<Row, Table>` singletons and `Table::Load<T>`

```
ITableBase<Row, Table>   (size 0xc4)                         *(pdb2016)*
    +0x00  vftable   slot 0 (0x0): empty FUN_00417480 (shared fold); slot 1 (0x4): DataProcess, default FUN_005af8d0 `return 1`;
                     slot 2 (0x8): scalar deleting destructor
    +0x04  CDataReader m_kDataReader
    +0x44  char m_acFilename[128]
    static Table* ms_pkTable                                   (one global per instance)
IIDTableBase<Row, Table, K> : ITableBase                      (size 0xcc)
    +0xc4  Row** m_pkRecordIDMap      id → row, sized m_tMostLargeID + 1
    +0xc8  K m_tMostLargeID
    vftable slots 3 (0xc) GetID(row) → K (pure in the base: `_purecall` 0x6583ea), 4 (0x10) IsValidID(K)
```

The template (Z21 §4.1 shows the SetEffect instance):

```pseudo
Table::Load<T>(char* name)                                     @ FUN_005b5080 (PVE), FUN_005b51c0 (EVP), FUN_005b5300 (PVP), FUN_005b5440 (BelongDice)
    path = Table::GetTableDir() + name                         # FUN_005c6ed0 returns &strDirPath, set once by Table::SetTableDir
                                                               #   FUN_005c74d0 from zs_start_earth FUN_005ad970 ("../9Data/Shine/", Z01 §2.3)
    msg  = "Fail to read  : " + name
    if not ITableBase<Row, T>::Load(path, true):
        AssertFail(msg); ShineExit(msg)                        # the zone does not start
    # GetTableDir has 24 callers, one per Table::Load<…> instance (FUN_005b42b0 … FUN_005b6140)

ITableBase<Row, T>::Load(char* path, bool _unused) → bool      @ FUN_005b2f90 (PVE), FUN_005b3070 (EVP), FUN_005b4090 (PVP),
                                                                 FUN_005b3150 (BelongDice), FUN_005b3850 (EnchantSocketRate)
    if ms_pkTable == null: ms_pkTable = new T                  # 0xc4 bytes (PVP: 0xcc); allocation failure leaves it null
    ms_pkTable.m_kDataReader.ClearBF()
    if not m_kDataReader.Read(path) or m_pHead == null or m_pHead.nVersionKey != KEY: return false
        # only the version key is checked, not the row size (S01 knowledge: all 24 ITableBase loaders)
    strcpy(m_acFilename, path)                                 # no length check; the paths are fixed and short
    return ms_pkTable.vt[1]()                                  # DataProcess

T::T()  (LevelGap_Player_to_Monster FUN_005b1520, LevelGap_Monster_to_Player FUN_005b1560, LevelGap_Player_to_Player FUN_005b3930,
         BelongDiceTable FUN_005b1620, EnchantSocketRateTable FUN_005b2000)
    vftable = ITableBase<Row, T>::vftable; CDataReader::CDataReader(&m_kDataReader)
    once (function-local static guard): atexit(ITableBase<Row, T>'s "dynamic atexit destructor for __instance__")
    m_acFilename[0] = 0
    PVP only: m_pkRecordIDMap = null, m_tMostLargeID = 0
    vftable = T::vftable

atexit destructor  @ FUN_006a0410 (PVE), FUN_006a03e0 (EVP), FUN_006a0680 (PVP), FUN_006a03b0 (BelongDice), FUN_006a0230 (EnchantSocketRate)
    if ms_pkTable: ms_pkTable.vt[0](); if ms_pkTable: ms_pkTable.vt[2](1)    # empty slot 0, then the scalar deleting destructor
    ms_pkTable = null

ITableBase<Row, T>::`scalar deleting destructor'(this, flags)   (vt slot 2; list in §7.4)
    vftable = ITableBase vftable; m_kDataReader.ClearBF(); ~CDataReader(&m_kDataReader); if flags & 1: delete this
IIDTableBase<DamageLvGapPVP, LevelGap_Player_to_Player, u8>::`scalar deleting destructor'   @ FUN_005aff00
    vftable = IIDTableBase vftable; delete[] m_pkRecordIDMap; then the ITableBase body above

ITableBase<Row, T>::GetTotal() = m_pHead ? m_pHead.nNumOfRecord : 0        (static, on ms_pkTable; list in §7.4)
```

| Table class *(pdb2016)* | `ms_pkTable` | File | key (2016 file) | Row *(pdb2016)* | rows 2016 | DataProcess (vt 0x4) | Loaded in |
|---|---|---|---|---|---|---|---|
| `LevelGap_Player_to_Monster` | DAT_133888cc | DamageLvGapPVE.shn | 7 | `DamageLvGapPVE {u16 LvGap, u16 DamageRate}` (4) | 24 | `return 1` FUN_005af8d0 | `zs_start_full` LAB_005b6580 (Z01 §2.3), strings at 0x5b65d0 … 0x5b65ee |
| `LevelGap_Monster_to_Player` | DAT_133888d0 | DamageLvGapEVP.shn | 7 | `DamageLvGapEVP` (same 4 bytes) | 24 | `return 1` | same |
| `LevelGap_Player_to_Player` (an `IIDTableBase<…, u8>`) | DAT_133888f4 | DamageLvGapPVP.shn | 0xddc8 (56776) | `DamageLvGapPVP {u8 MyLv; u16 TargetLv1 … TargetLv150}` (0x12d) | 151 | `IIDTableBase::DataProcess` FUN_005af8f0 | same |
| `BelongDiceTable` | DAT_132723c4 | BelongDice.shn | 1 | `BelongDice {u8 DiceTimeLimit}` | 1 (15) | `return 1` | same; use: Z09 §11.1 |
| `EnchantSocketRateTable` | DAT_133888f0 | EnchantSocketRate.shn | 0x22 (34) | `EnchantSocketRate {GradeType ItemGradeType; u16 Socket0, Socket1, Socket2}` (0xa) | 5 | `EnchantSocketRateTable::DataProcess` FUN_005c8070 (§8) | `zs_start_open` via `Table::Load<EnchantSocketRateTable>` FUN_005b56c0 (Z10) |

The four `Table::Load` instances of the plan run in `zs_start_full` in the order PVE, EVP, PVP, BelongDice, between
AccUpGrade and MysteryVaultServer (Z01 §2.3). No function calls them: `zs_start_full` is a label inside the staged
start-up (LAB_005b6580), which is why X02 counted 0 callers.

```pseudo
IIDTableBase<DamageLvGapPVP, LevelGap_Player_to_Player, u8>::DataProcess(this) → bool   @ FUN_005af8f0 (vt 0x4)
    maxId = −1
    for i in 0 .. nNumOfRecord − 1: maxId = max(maxId, vt[3](GetRecord(i)) & 0xff)        # GetID = row.MyLv
    if maxId < 0: return false                                 # empty file → Load fails → "Fail to read  : DamageLvGapPVP.shn", ShineExit
    delete[] m_pkRecordIDMap; m_pkRecordIDMap = new Row*[maxId + 1], all null
    for i in 0 .. nNumOfRecord − 1:
        id = GetID(GetRecord(i)) & 0xff
        if m_pkRecordIDMap[id] != null: delete[] m_pkRecordIDMap; m_pkRecordIDMap = null; return false   # duplicate MyLv: the zone exits
        m_pkRecordIDMap[id] = GetRecord(i)
    m_tMostLargeID = maxId; return true
LevelGap_Player_to_Player::GetID(row) = row.MyLv                                @ FUN_005c8170 (vt 0xc; only caller: DataProcess)
IIDTableBase<…>::IsValidID(u8 id) = id != 0xFF                                  @ FUN_005af8e0 (vt 0x10; caller: GetLevelCapRate)
```

The level-gap lookups. `RulesOfEngagement::roe_LevelGapDamageRevision` FUN_00500180 (Z03 §4.5) and the abstate
strength rule of Z22 call them as `GetLevelCapRate(attackerLevel, defenderLevel)` and scale by the per-mille result:

```pseudo
LevelGap_Player_to_Monster::GetLevelCapRate(att, def) → per mille            @ FUN_005c8220 (PVE)
LevelGap_Monster_to_Player::GetLevelCapRate(att, def) → per mille            @ FUN_005c8280 (EVP, same body)
    for i in 0 .. GetTotal() − 1:                              # GetTotal FUN_005c8180 / FUN_005c81a0
        row = GetRecord(i)
        if def − att <= (s16)row.LvGap: return row.DamageRate  # first match in file order; LvGap is read signed
    return 1000
    # the rows must be sorted by LvGap ascending. 2016 PVE: −150 → 1500, −10 … −5 → 1500, −4 → 1400, −3 → 1300,
    #   −2 → 1200, −1 → 1100, 0 … 11 and 150 → 1000: a player hitting a mob 1-4+ levels below deals 110-150 %.
    #   2016 EVP: every row 1000 (no level effect on mob damage). A gap above 150 finds no row → 1000.

LevelGap_Player_to_Player::GetLevelCapRate(att, def) → per mille             @ FUN_005c81c0 (PVP)
    t = ms_pkTable
    if t.vt[0x10](att & 0xff)                                  # IsValidID: att & 0xff != 0xFF
       and (att & 0xff) <= t.m_tMostLargeID and (row = t.m_pkRecordIDMap[att & 0xff]) != null
       and def < 150:
        return *(u16*)((byte*)row + DefLv[def])               # DefLv @ 0x870148: u32[150], DefLv[i] = 1 + 2·i = offset of TargetLv(i+1)
        # (original bug) Z31-B10: a defender of level L reads column TargetLv(L+1). Row 0 of the file is a header
        # row (MyLv 0, TargetLvN = N) that labels column N as level N. A level-150 defender fails `def < 150` and
        # always gets 1000.
    return 1000
    # 2016 DamageLvGapPVP.shn: rows MyLv 0 … 150, every cell of rows 1-150 is 1000, so neither the shift nor the cap
    #   changes any damage in 2016
```

### 7.4 The other `ITableBase` instances: destructors and `GetTotal`

Every `ITableBase<Row, Table>` vftable has the three slots of §7.3. Its scalar deleting destructor (slot 2) is called
only by that table's atexit destructor at process exit. These are the instances not cited before (the `Load` /
`DataProcess` bodies are in the item named):

| Table class | Scalar deleting dtor | `Table::Load<…>` | Documented in |
|---|---|---|---|
| `GuildTournamentScoreTable` / `…LvGapTable` / `…OccupyTable` / `…SkillTable` / `…MasterBuffTable` | FUN_005b1120 / FUN_005afa00 / FUN_005afa80 / FUN_005b1260 / FUN_005afb00 | FUN_005b42b0 / FUN_005b43f0 / FUN_005b4530 / FUN_005b4670 / FUN_005b47b0 | Z16 (guild tournament) |
| `GTIGetRateTable` / `GTIGetRateGapTable` / `GTIServerTable` / `GTIBreedSubjectTable` / `GTWinScoreTable` | FUN_005afb80 / FUN_005afc00 / FUN_005afc80 / FUN_005afd00 / FUN_005b1460 | FUN_005b48f0 / FUN_005b4a30 / FUN_005b4b70 / FUN_005b4cb0 / FUN_005b4df0 | Z16, Z11 |
| `MysteryVaultTable` | FUN_005afd80 | FUN_005b5580 | Z24, Z05 |
| `AccUpGradeTable` | FUN_005b1060 | FUN_005b4f40 | Z01 §2.3 (stage full); §8 |
| `LevelGap_Player_to_Monster` / `LevelGap_Monster_to_Player` | FUN_005afe00 / FUN_005b15a0 | FUN_005b5080 / FUN_005b51c0 | §7.3 |
| `LevelGap_Player_to_Player` | `IIDTableBase` body FUN_005aff00 (slot 2 of its vftable) | FUN_005b5300 | §7.3 |
| `BelongDiceTable` | FUN_005aff90 | FUN_005b5440 | §7.3 |
| `EnchantSocketRateTable` | FUN_005b2040 | FUN_005b56c0 | §7.3, §8 |
| `ActionRangeFactors` / `ItemActionConditions` / `ItemActionEffects` / `ItemActions` | FUN_005b0010 / FUN_005b0090 / FUN_005b0110 / FUN_005b0190 | FUN_005b59c0 / FUN_005b5b00 / FUN_005b5c40 / FUN_005b5d80 | Z17 |
| `ActionEffectItemTable` / `ActionEffectAbStateTable` | FUN_005b0210 / FUN_005b0290 | FUN_005b6000 / FUN_005b6140 | Z17, Z21 |

`ITableBase<DamageLvGapPVP, LevelGap_Player_to_Player>::`scalar deleting destructor'` FUN_005afe80 is dead. Its only
image reference is the `ITableBase<DamageLvGapPVP, …>` vftable. The `LevelGap_Player_to_Player` constructor replaces
that vftable twice before the object is used (by the `IIDTableBase` one and then its own), so the destructor that
runs is FUN_005aff00.

`ITableBase<…>::GetTotal()` (body in §7.3) instances not cited before, with their only caller:

| Instance | Address | Caller |
|---|---|---|
| `ITableBase<ItemAction, ItemActions>` | FUN_005b1800 | `ItemActions::DataProcess` FUN_005b78e0 (Z17) |
| `ITableBase<ActionEffectItem, ActionEffectItemTable>` | FUN_005c7e50 | `ActionEffectItemTable::DataProcess` FUN_005c80d0 (Z17) |
| `ITableBase<EnchantSocketRate, EnchantSocketRateTable>` | FUN_005c7e90 | `EnchantSocketRateDataChild::iod_GetSocketCount` FUN_005c7fd0 (§8) |
| `ITableBase<DamageLvGapPVE, LevelGap_Player_to_Monster>` | FUN_005c8180 | `LevelGap_Player_to_Monster::GetLevelCapRate` FUN_005c8220 (§7.3) |
| `ITableBase<DamageLvGapEVP, LevelGap_Monster_to_Player>` | FUN_005c81a0 | `LevelGap_Monster_to_Player::GetLevelCapRate` FUN_005c8280 (§7.3) |
| `ITableBase<ActionRangeFactor, ActionRangeFactors>` | FUN_005cf030 | `ActionRangeFactors::DataProcess` FUN_005cf5a0 (Z17) |
| `ITableBase<ItemActionCondition, ItemActionConditions>` | FUN_005cf050 | `ItemActionConditions::DataProcess` FUN_005cf820 (Z17) |
| `ITableBase<ItemActionEffect, ItemActionEffects>` | FUN_005d01c0 | `ItemActionEffects::DataProcess` FUN_005d0790 (Z17) |

## 8. Other loaders and parsers: item options, random options, sockets, accessory upgrades, key tables, area bitmaps, lot analyser, `OptionReader` remainder

These are the start-up loaders that hold their own data structure next to (or instead of) a `BinaryDataBox<T>`, and the
parts of the `OptionReader` text parser that Z09 §28.6 left uncited. The stage that runs each loader is Z01 §2.3.
The §7.1 rows that point to "§8" (`ItemOptions`, `RandomOption`, `RandomOptionCount`, `AccUpGradeInfo`) are
documented here.

### 8.1 Item option cards (`ItemOptionsData`, `ItemOptions.shn`)

`itemoptiondata` (global, 0x46ac bytes) is a `BinaryDataBox<ItemOptions>` plus `OptionCardStack iod_optionlist[500]`
(+0x5c, 0x24 each: `CardDeck::CardStack ocs_cardstack` +0, `ItemOptions* ocs_Number` +0x20) *(pdb2016)*.
`ItemOptions` (0x19) = `{u16 OptionDegree, ITEM_OPTION_TYPE Type +2, u8 Interval +6, u16 Rate[9] +7}`. `ITEM_OPTION_TYPE`
*(pdb2016)*: 0 `IOT_NUMBER` (the option-count row), 1 STR, 2 INT, 3 DEX, 4 MEN, 5 CON, 6 TH, 7 TB, 8 AC, 9 WC, 10 MA,
11 MR. The card decks are the `CardDeck` lists of Z09 §28.10.

```pseudo
ItemOptionsData::iod_Load(iod)                                         @ FUN_0064cbc0  (Z01 §2.3)
    bdb_ReadData("../9Data/Shine/ItemOptions.shn")                     # key 0x62e, row 0x19 (§7.1)
    every iod_optionlist[d].ocs_Number = null
    for each row r (file order, row index i):
        s = iod_optionlist[r.OptionDegree]                             # no bound check against 500 (original bug) Z31-B12
        if r.Type == 0 (IOT_NUMBER):                                   # "ocs_Init"
            s.ocs_Number already set: fatal "ItemOptionsData::OptionCardStack::ocs_Init : already initialized"
            s.ocs_Number = &r; empty s's deck (ListEraser over the cards)
        else:                                                          # "ocs_cardinsert"
            s.ocs_Number null: fatal "…::ocs_cardinsert : not initializes"   # the count row must come first
            CardStack::cs_InsertTop(s.ocs_cardstack, card = i)         # the card is the row index
    for every stack with ocs_Number set: CardStack::cs_Suffle(50)      # once, at start-up (CRT rand(), Z09 §28.10)
    bdb_defaultblock.OptionDegree = 0xFFFF                             # +0x40, the "not found" marker

OptionCardStack::ocs_selectnumber(s, row) -> int                       @ FUN_0064c4f0
    r = well512_GetRandom(1000)                                        # 0…999
    i = 0; while i < 9: if r <= row.Rate[i]: break; r -= row.Rate[i]; i += 1
        # `<=`: index 0 gets Rate[0] + 1 chances in 1000 and the last non-zero rate one less (original bug) Z31-B13
    i == 9: assert "…ocs_selectnumber : Error in random select" (OptionDegree), i = 0
    row.Interval == 1: return i + 1
    off = 1 <= Interval <= 100 ? next value of the shuffled ring rndbox.rb_box[Interval] (0…Interval−1, Z28 §4.1) : 0
    v = Interval × i + off; v > 255: assert "…Too large value", v = 255
    return v

OptionCardStack::ocs_make(s, ItemOptionStorage* o) -> bool              @ FUN_0064c8a0
    o.fixed.optionnumber &= 1                                          # keep the "identified" bit, count 0
    s.ocs_Number null: return false                                    # a degree without an IOT_NUMBER row
    n = ocs_selectnumber(s, s.ocs_Number)                              # how many options
    while count(o) < n:
        card = top card of the deck; none: assert "…ocs_make : Error in selecting" (degree), return false
        take it off and put it back at the bottom (cs_InsertBottom; fails: assert "…Error in card recycle")
        row = ItemOptions[card] (default block past the end)
        row.OptionDegree == 0xFFFF: assert "…Option not found", return false
            # dead: the u16 is zero-extended and compared with −1, so the test never fires (original bug) Z31-B12
        row.Type == 0 or > 11: assert "…ocs_make : Invalid Option", return false
        o.optionlist[count].itemoption_type  = row.Type
        o.optionlist[count].itemoption_value = ocs_selectnumber(s, s.ocs_Number)
            # the value is drawn from the IOT_NUMBER row, not from the option's own row: Rate / Interval of the
            # rows of type 1-11 are never read (original bug) Z31-B11
        count += 1                                                     # count > 8 (optionlist has 8) unchecked (Z31-B12)
    return true
```

Callers of `ocs_make`: the reward item creators `ItemAttrCls_Amulet` / `_Weapon` / `_Armor` / `_Bracelet::iac_itemcreate`
(§3.5.1) with `iod_optionlist[reward.OptionDegree]`. Because the deck is shuffled once and every item takes the next
cards and puts them back at the bottom, the option types rotate zone-wide in one fixed order per degree; two items made
one after the other never repeat a type until the deck has gone round *(inferred from the card handling)*. The 2016
table has degree 1 (count row 995 / 5 ‰ for 1 / 2 options; types 1-5) and degree 2 (count row 900 / 90 / 9 / 1 ‰ for
1-4 options; types 1-11, types 6-11 with `Interval` 10). With Z31-B11 every value is 1-2 (degree 1) or 1-4 (degree 2).

Plumbing: `OptionCardStack::OptionCardStack` FUN_0064c4d0 (the `CardStack` ctor; called by the array constructor of
`itemoptiondata`'s dynamic initializer); `ItemOptionsData::`scalar deleting destructor'` FUN_0064cab0 (destroys the 500
stacks and the box; vftable slot 0, only image reference, never called).

### 8.2 Random options of dropped items (`ItemRandomOption::RandomOptionTable`)

`RandomOptionTable {vector<RandomOptionList> rot_OptionList}`; `RandomOptionList` (0x40) = `{Name8 rol_Index,
vector<OptionCountTable {int oct_Number, int oct_Rate}> rol_Count +0x20, vector<OptionTable> rol_Option +0x30}`;
`OptionTable` (0x14) = `{RandomOptionType ot_Type, vector<ValueList {int vl_Min, vl_Max, vl_Rate}> ot_ValueList}`
*(pdb2016)*. The user is `rot_FillOption` (Z18 §4.5, FUN_00493590) and the GM command of Z11 (`std::_Find` FUN_00493490).

```pseudo
ItemRandomOption::RandomOptionTable::rot_Load(t, Name4*)               @ FUN_00494570  (stage "home", Z01 §2.3)
    # 1. option counts: stack BinaryDataBox<RandomOptionCount> (key 0x12, row 0x25)
    bdb_ReadData("../9Data/Shine/RandomOptionCount.shn")
    for each row {char InxName[33], u16 LimitCount +0x21, u16 LimitDropRate +0x23}:
        name = first 32 bytes of InxName
        L = list with rol_Index == name; none: push_back {name, empty, empty} and find it again
        none even then: fatal "ItemRandomOption::RandomOptionTable::rot_Load : Not appended in list"
        L.rol_Count.push_back({oct_Number = LimitCount, oct_Rate = LimitDropRate})
    # 2. option values: stack reader, CDataReader::Read("../9Data/Shine/RandomOption.shn", key 0x5d, row 0x31)
    #    fails: assert "BinaryDataBox<T>::bdb_ReadData : readfail" + ShineExit (the box template inlined)
    for each row {char DropItemIndex[33], RandomOptionType +0x21, u32 Min +0x25, u32 Max +0x29, u32 TypeDropRate +0x2d}:
        L = list named DropItemIndex (32 bytes); none: fatal "…rot_Load : RandomOptionIndex out of CountList"
        T = RandomOptionList::rol_FindOption(L, type); null: fatal "…rot_Load : Null RandomOption"
        T.ot_ValueList.push_back({Min, Max, TypeDropRate})
    # 3. checks, per list (all fatal, with the list name)
    sum of L.rol_Count[].oct_Rate != 1000: "…rot_Load : Count not 1000"
    for each T of L: sum of T.ot_ValueList[].vl_Rate != 1000: "…rot_Load : Option not 1000"

RandomOptionList::rol_FindOption(L, type) -> OptionTable*               @ FUN_00493f20
    linear search of L.rol_Option for ot_Type == type: found → return it
    else push_back {type, empty} and search again (found → it, else null)
```

A list therefore exists only for names that appear in `RandomOptionCount.shn` (2016: 5 928 count rows, 11 456 option
rows). `RandomOptionList::~RandomOptionList` FUN_00493e00 frees `rol_Option` (the element destructor is a folded
`_Destroy_range`) and `rol_Count`; its caller is the unwind path of `rot_Load`.

### 8.3 Gem socket count (`EnchantSocketRateTable`, `EnchantSocketRate.shn`)

`Table::Load<EnchantSocketRateTable>` (§7.3) ends in this table's `DataProcess`:

```pseudo
EnchantSocketRateTable::DataProcess(t) -> true                          @ FUN_005c8070
    once: RateDataProcess = EnchantSocketRateDataChild (a static object; its vftable is the whole object)
    EnchantSocketRateData::SetSocketRateData(&RateDataProcess)          @ FUN_0064c5d0: sm_pSocketRateData = it
    # EnchantSocketRateData::GetSocketRateData FUN_0064c5c0 returns it (Z18 §4.5, iac_DropItemMake)

EnchantSocketRateDataChild::iod_GetSocketCount(this, itemID) -> u8      @ FUN_005c7fd0  (vt slot 0)
    d = itemdatabox[itemID]; none: return 0
    for each EnchantSocketRate row r (GetTotal() rows, file order):
        r == null: return 0
        if r.ItemGradeType == d.ItemGradeType:
            x = rb_largerandom(Socket0 + Socket1 + Socket2) − Socket0     # uniform 0…n−1
            return x < 0 ? 0 : (x < Socket1 ? 1 : 2)
    assert "EnchantSocketRateDataChild::iod_GetSocketCount UnKnow Grade Type" (grade); return 0
```

So `Socket0` / `Socket1` / `Socket2` are the weights of 0 / 1 / 2 sockets. The result is the weapon's `maxSocketCount`
in `ItemAttrCls_Weapon::iac_DropItemMake` (Z18 §4.5). 2016 rows (`GradeType` *(pdb2016)*): 0 NORMAL 0 / 100 / 100,
1 NAMED 0 / 100 / 80, 2 RARE 0 / 100 / 40, 5 SET 0 / 100 / 20, 3 UNIQUE 0 / 100 / 10: every dropped weapon gets 1 or 2
sockets; grades 4 CHARGE, 6 LEGENDARY and 7 MYTHIC have no row (assert, 0 sockets).

### 8.4 Accessory upgrades (`AccUpGradeDataBox`, `AccUpGradeTable`)

`gAccUpGradeDataBox` (0xc0) = `{BinaryDataBox<AccUpGradeInfo> augdb_bdbAccUpGrade, map<u16, map<RandomOptionType,
ACC_UPGRADE_FACTOR {AccUpGradeInfo* pSuccess, *pFail}>> augdb_AccUpGradeData +0xb0}` *(pdb2016)*. The readers of the map
are Z11 §9.3 (`augdb_GetAccUpGradeFactor…`, `augdb_RandomOptionUpgrade`).

```pseudo
AccUpGradeDataBox::augdb_Load(b) -> true                                @ FUN_005c69b0  (Z01 §2.3)
    bdb_ReadData("../9Data/Shine/AccUpGradeInfo.shn")                   # key 3999, row 0x70 (§7.1)
    for each row r {u16 ID, char InxName[32] +2, RandomOptionType UpFactor +0x22, u16 Success +0x26, 12 × {Min, Max, Limit}}:
        r is the default block: fatal "AccUpGradeDataBox::augdb_Load - def data block"
        inner = augdb_AccUpGradeData[r.ID] (created empty if missing)
        f = inner[r.UpFactor] (created {null, null} if missing)
        r.Success == 1 ? f.pSuccess = &r : f.pFail = &r                # a later row with the same key replaces the earlier
```

Constructor `AccUpGradeDataBox::AccUpGradeDataBox` FUN_005c6e00 (box with a zeroed default block, empty map; caller:
the dynamic initializer of `gAccUpGradeDataBox`) and destructor FUN_005c6d70 (frees the map; its atexit destructor).

`AccUpGradeTable` is a different table: `ITableBase<AccUpgrade, AccUpGradeTable>` over `AccUpgrade.shn` (row `{u32 ID,
u16 CriFail, DownFail, NormalFail, nCon, LuckySuc}`, the `ItemUpgrade.shn` layout). `zs_start_full` calls
`Table::Load<AccUpGradeTable>("AccUpGrade.shn")` FUN_005b4f40 → `ITableBase<AccUpgrade, AccUpGradeTable>::Load`
FUN_005b2500 (the §7.3 template: `new AccUpGradeTable` FUN_005b1020, the §7.3 constructor, default `DataProcess`).
`ITableBase<AccUpgrade, AccUpGradeTable>::GetByIndex(i)` FUN_0053c740 = `GetRecord(i)` of the singleton's reader; its
caller is `Item_Upgrade_Table_mode` FUN_0053ca10 for amulets (Z04 §9.4: the override of the `ItemUpgrade` row; a
missing row asserts "Item_Upgrade Not Found AccUpgrade Index :").

### 8.5 Small key tables: `ItemMixData`, `CSingleDataMap`, `CBadNameFilterData`

```pseudo
ItemMixData::Read(m, path, key, rowSize) -> int                         @ FUN_00635450
    # zs_start_star: Read(&gItemMixData, "../9Data/Shine/ItemMix.shn", 0x2c, 0x40); 0 → fatal "Fail to read 'ItemMix.shn'"
    clear m.m_ItemMixDataMap (std::map<string, string>)
    CDataReader::Read(&m.m_ItemMixDataReader, path, key, rowSize) fails: return 0
    for each row {char Raw_ItemIDX[32], char Mix_ItemIDX[32] +0x20}:
        Raw_ItemIDX already a key: return 0                             # one duplicate stops the zone
        insert Raw_ItemIDX → Mix_ItemIDX
    return 1                                                            # the reader keeps the file in memory
```

The reader of the map is `ItemMixData::GetMixItemIndex` FUN_00635820 (Z30 §9). 2016: 98 rows, no duplicate. Plumbing:
ctor FUN_006353a0 (reader + empty map; `gItemMixData`'s dynamic initializer), dtor FUN_00635100 (map, then reader).

```pseudo
CSingleDataMap::InitSingleDataArray(m, path, key, rowSize) -> int        @ FUN_0062ee90
    # zs_start_sleep: (&gSingleData, "../9Data/Shine/SingleData.shn", 7, 0x22); 0 → ShineExit("ZoneServer::zs_start_old")
    stack CDataReader; Read fails: return 0
    for each row {char SingleDataIDX[32], u16 SingleDataValue +0x20}: null row → return 0
        m.m_SingleData[SingleDataIDX] = SingleDataValue                 # std::map<string, u16>; a duplicate overwrites
    return 1                                                            # the reader is freed
```

Same code and file as the WM's (W05 §3.2 row 24, §3.3 `GetValue`; 41 keys such as `KQVote_VoteLimitTime`,
`SenMaxLP`, `LimitRandomOption`, `MixMinUpgrade`). Zone readers: `CSingleDataMap::GetValue` (26 call sites; Z12 §3.1 for
the Sentinel values). Plumbing: ctor FUN_0062f080 (empty map; `gSingleData`'s dynamic initializer), dtor FUN_0062f020.

```pseudo
CBadNameFilterData::ReadBadNameFilterData(f, path) -> int               @ FUN_0042a9a0
    # zs_start_sleep: (&gBadNameFilterData, "../9Data/Shine/BadNameFilter.shn"); 0 → ShineExit("ZoneServer::zs_start_old")
    CDataReader::Read(&f.m_BadNameFilterData, path, 0x12, 0x24) fails, or 0 rows: return 0
    for each row {char BadName[32], u32 Type +0x20}: _mbsupr(BadName)    # upper-cased in place
    return 1
```

Same as the WM's `CDataFileServer::ReadBadNameFilterData` (W05 §3.2 row 19). The zone's only test is
`CBadNameFilterData::GetIsBadName` FUN_0042aa10 in the pet rename `sp_NC_PET_SET_NAME_R` (Z07). (The row count comes
through `cChatColorDataBox::ccdb_GetMaxNum`, a folded "record count" accessor.)

### 8.6 Area bitmaps (`BmpDataBox`, `BMP.shn`, `AreaBMP/*.bmp`)

`bmpdatabox` = `{vector<BmpDataInfo*> bdb_vBmpDataList, BTree bdb_BmpTree +0x10, u32 bdb_nMaxBmpSize +0x414}`;
`BmpDataInfo` = `BMPInfo {int AreaCenter_X, AreaCenter_Y, AreaSize, AreaSize_X, AreaSize_Y; u8** AreaBMP}` *(pdb2016)*.
The area skills copy the `BMPInfo` per step (Z20 §3.1, `sdb_Load` step 10, `bdb_GetBmpDataInfo` FUN_00439520).

```pseudo
BmpDataBox::bdb_ReadData(b) -> true                                      @ FUN_00439550  (Z01 §2.3)
    stack CDataReader: Read("../9Data/Shine/BMP.shn", 0x2c, 0x40) fails: fatal "Fail to read BMPIndex.shn"
    for each row i {char BMPIndex[32], char FileName[32] +0x20}:
        info = new BmpDataInfo (all zero)
        bdi_LoadBmpFile(info, FileName) false: fatal "BmpDataBox::bdb_ReadData : BMP file Load Fail"
        BTree::bt_Insert(&b.bdb_BmpTree, BMPIndex, i); b.bdb_vBmpDataList.push_back(info)

BmpDataInfo::bdi_LoadBmpFile(info, name) -> bool                        @ FUN_004390f0
    f = fopen(sprintf("../9Data/%sAreaBMP/%s.bmp", "Shine/", name), "rb"); none: fatal "SBmpDataInfo::bdi_LoadBmpFile : BMP file name error"
    every check below is fatal ("BmpDataInfo::bdi_LoadBmpFile : BMP file …"):
        14-byte file header read ("header info error"); bfType == "BM"; bfSize == file length ("File Size Error");
        both reserved words 0 ("Reserved Error"); 40-byte info header read ("info error"); biCompression == 0;
        biBitCount 1 or 8 ("bit error - biBitCount "); biWidth and biHeight <= 8000 ("size error ", 8000)
    AreaSize_X = biHeight, AreaSize_Y = biWidth, AreaCenter_X = biHeight / 2, AreaCenter_Y = biWidth / 2
    AreaBMP = malloc(biHeight pointers), each row malloc(biWidth); a failed malloc → return false
    if biBitCount == 8:
        read the 256-entry palette ("RGBQuad Error"); seek to bfOffBits
        for x in 0…AreaSize_X−1 (file rows, bottom-up): read one row padded to 4 bytes (short read → return false)
            for y in 0…AreaSize_Y−1: red = palette[pixel].rgbRed
                AreaBMP[x][AreaSize_Y − 1 − y] = red < 201 ? red / 2 : 100           # 0…100
    # biBitCount == 1 passes the checks but no pixel is read: AreaBMP stays uninitialised heap (original bug) Z31-B14
    AreaSize = max over the cells with value 1 of (int) sqrt((x − AreaCenter_X)² + (y − AreaCenter_Y)²)
    return true
```

2016: `BMP.shn` has 52 rows; all 52 files exist (some named `.BMP`, matched case-blind by Windows), all 8-bit, at most
2800 × 2800. The one 1-bit file in the folder (`SW_FFocalor_Skill05_N.bmp`) is not in `BMP.shn`, so Z31-B14 is latent.

### 8.7 Inventory item-count changes (`ItemLotAnalyser::LotAnalyser`)

`itemlotanalyser` (global, 0x618) = `List<LotChanger>` of 192 entries over `LotChanger la_Array[192]` (+0x18),
`LotChanger` (8) = `{u16 item, int delta +4}` *(pdb2016)*. `icl_Apply_N_Free` (Z05 §1.3) empties it, lets the releasers
fill it, then calls `p.so_ply_ItemLotChange(entry.item, entry.delta)` (vt 0x7f8, Z15 §4.5: the quest item counters) for
each entry.

```pseudo
ItemLotAnalyser::LotAnalyser::la_Store(a, ITEM_INVEN* where, ItemInventoryCell* cell, int sign)   @ FUN_0048a170
    # callers: InvenCellReleaser_CellClear::icr_Apply (−1, before the cell is cleared),
    #          InvenCellReleaser_CellChange::icr_Apply (−1 for the old item, +1 after the new one is stored)
    if (where.Inven & 0xFC00) != 0x2400: return                        # inventory type 9 (the bag) only
    lot = cell.attr.vt[0x1c](&cell.item)                               # iac_GetLot (§3.5)
    id = cell.item.itemid; id == 0xFFFF: return
    e = first entry with e.item == id (ListSearchSame, compare FUN_004b6aa0)
    found: e.delta += lot × sign
    else: e = next free entry (none: assert "ItemLotAnalyser::ItemLotAnalyser::ila_Store : List leck")
          e.delta = lot × sign
          # e.item is never written (original bug) Z31-B15: entries keep item 0 from the zero-initialised array
```

So in 2016 the search never matches a real item (every entry says item 0), each stored cell takes a new entry, and
`icl_Apply_N_Free` reports `so_ply_ItemLotChange(0, delta)`: the quest hooks are asked about item 0 instead of the
changed item (see knowledge §0 for the correction to Z05 §1.3 / Z15 §4.5). Plumbing: `LotAnalyser::LotAnalyser`
FUN_0048c5f0 (`l_MakeList(192)`, content pointers into `la_Array`; `itemlotanalyser`'s dynamic initializer),
`ListSearchSame<LotChanger>::~ListSearchSame` FUN_0048a160 (resets the iterator vftable; inlined in `la_Store`).

### 8.8 `OptionReader` remainder (Z09 §28.6)

ORField vftables *(read from RTTI)*: `{0 orf_CompareContent(char* value, ORToken* key), 4 orf_Alloc(buffer), 8 orf_Read
(reader), 0xc data pointer FUN_005d6dc0 (`return +8`), 0x10 type}`; type = 1 index (FUN_00557bb0), 2 string
(FUN_00647230), 3 byte (FUN_00556e40), 4 word (FUN_00449740), 5 dwrd (FUN_0063e3a0) (all folded constants). Field layout
`{vftable, ORColumnHeader* +4, data* +8}`. Column headers: `{0 ortr_SetLength(reader, args), 4 type}` with the same type
constants.

| Function | Address | Behaviour | Caller |
|---|---|---|---|
| `ORFieldIndex::orf_Alloc` (shared by all five field classes) | FUN_00653be0 | `data = buffer`; returns the header's length (`+4`, folded accessor FUN_0045ff90), so the record buffer advances column by column | `ORRecord::orr_AllocObject` (Z20 §7) |
| `ORFieldIndex::orf_CompareContent` | FUN_00653ad0 | true when the 20-byte key equals the field's index token | vt 0 |
| `ORFieldString::orf_CompareContent` | FUN_00653b10 | `strcmp(field, value) == 0` (case-sensitive) | vt 0 |
| `ORFieldByte` / `ORFieldWord` / `ORFieldDwrd::orf_CompareContent` | FUN_00653bb0 / FUN_00653c50 / FUN_00653cd0 | `sscanf(value, "%d")` equals the stored number | vt 0 |
| `ORFieldWord::orf_Read` | FUN_00653c00 | `ortr_ReadNumber`; a read error or a value ≥ 0x10000 → "Cannot read word data", false; else stores the low 16 bits (negative values pass, `-1` = 0xFFFF) | vt 8 (`ort_ReadData`) |
| `ORColumnHeader::ortr_SetLength` | FUN_00647150 | base: returns `orch_Length` (+4); the string header's override is FUN_00647160 (Z09 §28.6) | `ort_ReadColumnHeader` |
| `ColumnCheckArgument::lid_Call` | FUN_00647000 | per field: empty column name → found, stop; same column name (20 bytes) → found = field.vt[0](value, key), stop; else go on | `RecordDataCompareArgument::lid_Call` FUN_006475a0 (`or_SelectFrom`) |
| `ColumnNameArgument::lid_Call` | FUN_006474b0 | reads the next name (`ortr_ReadString`, no braces); none → "Column type-name mismatch", stop; else column name = first 20 bytes | `ORTable::ort_ReadColumnName` FUN_006477a0 |
| `MakePrimaryKeyColumn::lid_Call` | FUN_00646f70 | on the key column: if its type is 1 (index), `okl_AddKey(keylist, field data, record)`; other types add nothing; stop | `MakePrimaryKey::lid_Call` FUN_00647410 |
| `OrderArgument::lid_Call` | FUN_00646fe0 | counts down `oa_target`; at 0 keeps the record and stops | `or_SelectFromOrder` FUN_00647a60 |
| `OptionReader::or_ClearError` | FUN_00645ef0 | error = {line 0, "Noerr", flag 0} | `SoulDamageContainer::sdc_Load`, `MobHatchery::mh_Load`, `MobRoamingSet::mrs_Load` |
| `OptionReader::~OptionReader` | FUN_006467d0 | frees the file name string, destroys the 32 tables and the table list, then the `TokenArgument` | 42 loaders with a stack or member reader (Z09 §28.6 list) |
| `TokenArgument::~TokenArgument` | FUN_00645e60 | five empty member destructors (folded `so_Gamble_ChangeCoin`) | unwind funclets of the `OptionReader` ctor / dtor |
| `ORTable::operator=` | FUN_00646230 | member copy: name, record length, the 512 header pointers, the record list and key pointer (shallow) | `List<ORTable>::l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` |
| `ListArray<ORRecord>::~ListArray` | FUN_00646180 | destroys the record array (0x808 each) | unwind funclets of the `ORTable` ctor / dtor |
| `SafePointer<OptionReader>::~SafePointer` | FUN_004b14d0 | `~OptionReader` + `delete` of the held reader | unwind funclet of `MobHatchery::mh_Load` |
| `ListEraser<ORTable>` / `ListEraser<ORRecord>::~ListEraser`, `ColumnNameArgument::~…`, `MakePrimaryKeyColumn::~…` | FUN_006462e0 / FUN_00647590 / FUN_006474a0 / FUN_00647580 | reset the iterator vftable | `l_MakeList` and unwind funclets |

`FieldOption` (the map option file reader of `FieldContainer`, Z09) is an `OptionReader` with no members of its own:
ctor FUN_0064cd20 = `OptionReader::OptionReader`, dtor FUN_0063e150 = the inlined `~OptionReader`; callers
`FieldContainer`'s ctor / dtor and `kqscriptmanager`'s dynamic initializer / atexit destructor.

### 8.9 Constructors and destructors of the other loader-owned objects

| Object | Function | Behaviour | Caller |
|---|---|---|---|
| `FieldContainer` (`fieldlist`, 0x54090: `List<FieldMap>` of 512, `FieldOption fc_FieldOption` +0x18, `FieldMap fc_Array[512]` +0x11070, `fc_GuildTournamentMap` +0x54070, `fc_InstanceDungeon` +0x54078, `fc_TutorialMap` +0x54084) | ctor FUN_00466900 | `l_MakeList(512)`, `FieldOption` ctor, 512 `FieldMap` ctors, content pointers into `fc_Array` | `fieldlist`'s dynamic initializer |
| | dtor FUN_00465550, scalar deleting dtor FUN_00466a30 | frees `fc_GuildTournamentMap.attr` and `fc_InstanceDungeon.Attribute`, the 512 maps, the reader and the list | atexit; the scalar dtor (vt 0) has no caller |
| `FieldMap::fm_GetCenterObject` | FUN_00463510 | returns `fm_SlantedListPoint.flag[2]`, the map's centre object (axial flag, Z09 §12.7) | 64 callers (every "objects of a map" walk: `ac_SetPVP`, `mc_Routine`, `sp_EscapeFromEmptyID`, …) |
| `MapDataBox` (`mapdatabox`, 0x51c) | ctor FUN_0064eed0, dtor FUN_0064ef60 | box with a zeroed `MapInfo` default block, `BTree mdb_btree`, `mdb_index` null, `mdb_maxmapid` 0 / frees `mdb_index`, the tree and the box | dynamic initializer / atexit (loader `mdb_Load`, Z09) |
| `MapBlockInformationBox` array element (`blockinfobox.mbib_array[256]`) | FUN_0049dfe0 | `mapid` cleared, `AreaInfoData` ctor, 32 `MapDoorBlockElement`s, the four block buffers null | `blockinfobox`'s dynamic initializer (loader `mbib_Load` FUN_0049e940, Z09 §9.2) |
| `KQItemDataBox` (`gKQItemDataBox`, `map<u16, KQItem>`) | dtor FUN_0064bf90 | frees the map | atexit (loader Z16) |
| `BRAccUpgradeDataBox` (`gBRAccUpgradeDataBox`) | dtor FUN_0043ba60 | frees `m_upgradeInfoList`, `m_upgradeList`, both boxes | atexit (loader `LoadBRAccUpgradeData` FUN_0043bb00, Z18) |
| `cStateItemDataBox` (`gStateItemDataBox`, `vector<SIDB_Element>`) | dtor FUN_0058c810 | frees the vector | atexit and the unwind of `g_KQContributeList`'s initializer (loader Z24 / Z20) |
| `ItemActionItemBox` (42 small cells of 0x14) | dtor FUN_00644bc0 | empty cell destructors, base vftable | `CharacterInventory::~CharacterInventory`, `sp_Item`'s dtor (§3.4) |
| `ItemActionObserveBuffer` (Z17 §2.1, the 5000-observer pool) | scalar deleting dtor FUN_005d1560 | destroys the 5000 observers and the list | vftable slot 0 only (the pool is a function-local static, never deleted) |
| `ItemActionObserve` | scalar deleting dtor FUN_005d0a00 | resets the vftable | vftable slot 0 only |
| `ListEraser<ItemActionObserve>` | `lid_Call` FUN_005538d0, dtor FUN_005d0c10 | `list.vt[0xc](index)` (free the node), continue / reset the vftable | `List<ItemActionObserve>::l_MakeList` (the RTTI also lists it under the lot-changer and script-interrupt erasers: identical code) |
| `CDataReader` | dtor FUN_0062a140 | frees the file buffer (`m_pHead`) when `m_nBFSize` != 0 and the row array when `m_nDataArraySize` != 0; zeroes sizes and checksum | 87 callers: every stack reader (`bdb_ReadData` of BMP, `MCC_DataRead`, `CPetData::ReadData`, the `ITableBase` destructors, …) |
| `ITableBase` constructors of the item tables | `AccUpGradeTable` FUN_005b1020, `ActionRangeFactors` FUN_005b1660, `ItemActionConditions` FUN_005b16a0, `ItemActionEffects` FUN_005b16e0, `ItemActions` FUN_005b1720, `ActionEffectItemTable` FUN_005b1f80, `ActionEffectAbStateTable` FUN_005b1fc0 | the §7.3 `T::T()` template | each table's `ITableBase<…>::Load` (§7.3; `DataProcess` bodies Z17 / Z21) |

## 9. NPC roles, merchant cities, item authority, booths, repurchase list, guild containers, party table, finders, events

Part 8 of the work list (`Z31-parts.py 8`, 106 functions). The NPC role table, `nrb_Role` of every role and the click /
menu flow are Z02 §6 and Z08 §5.2; the shop handlers that call the price slots are Z04 §2. This section documents the
role objects themselves and the small containers around them. Names *(pdb2016)* unless marked.

### 9.1 NPC role objects (`NPCRoleBase` and its subclasses)

Layout *(pdb2016)*: `NPCRoleBase` (0x18) = vftable + `ORToken nrb_argument` (+0x4, 20 bytes: the NPC.txt `RoleArg0`).
`NPCRole_Merchant`, `_StoreManager`, `_MenuOpen`, `_JobManager`, `_ClientMenu`, `_Guard` add nothing. `NPCRole_Portal`
(0x9c) adds `nrb_BrenchNumber` +0x18, `LinkInformTemplete nrb_BrenchSpot` +0x1c (0x61 bytes), `nrb_levelFrom` +0x7e,
`nrb_levelTo` +0x80, `nrb_LinkNum` +0x84 and `LinkInformTemplete* nrb_pSaveLinkInfo[5]` +0x88. `NPCRole_ID_Portal` (0xa0)
adds `InstanceDungeonInfo* nrip_pIndunInfo` +0x9c, `NPCRole_Mode_ID_Portal` (0xa8) `nrmip_pIndunInfo[3]` +0x9c (easy,
normal, hard), `NPCRole_RandomMulti_Portal` (0x9c) nothing. `NPCManager::nm_Load` FUN_004c58c0 (Z02 §6.1) creates one role
object per NPC.txt row; `NPCManager::nm_SetNPC` (Z09 §5.9) calls slot 0x2c once the NPC has spawned.

Vtable (byte offsets; one table for all 11 classes, read from the RTTI vftables). Callers = calls through an NPC entry's
`func` pointer, plus the roles' calls on themselves:

| Slot | Name | Default (`NPCRoleBase`) | Overrides | Callers |
|---|---|---|---|---|
| 0x0 | `nrb_Role(p, entry, npcHnd)` | FUN_004c2430 (log only) | Z02 §6.5 table | NPC click / menu ACK (Z02 §6.2-§6.3) |
| 0x4 | `nrb_EndOfTrade(p)` | FUN_00549070 (empty fold) | Merchant FUN_004c4400, MenuOpen FUN_004c4560: `p.so_ply_dupmenu_close(0)` (vt 0x6b4); StoreManager FUN_004c44b0: `so_ply_dupmenu_close(1)`, `sp_MiscFlag.AccountStorage_opened = 0` | 0x200B END OF TRADE (Z02 §6.4) |
| 0x8 | `nrb_linkinform(i)` | FUN_004c5400: assert "NPCRoleBase::nrb_linkinform", null | all portals FUN_004c5420 (below) | portal `nrb_BriefInformSet`, 0x2070 auto-way-finding gate (Z02 §11) |
| 0xc | `nrb_ItemSellPrice(p, itemid)` | FUN_00449600 (`return 0` fold) | Merchant FUN_004c7050 | 0x3006 SELL (Z04 §2.4) |
| 0x10 | `nrb_ItemBuyPrice(p, itemid)` | FUN_00449600 | Merchant FUN_004c7190 | 0x3003 BUY (Z04 §2.1) |
| 0x14 | `nrb_ItemBuyFame(p, itemid)` | FUN_00449600 | Merchant FUN_004c7390 | 0x3003 BUY |
| 0x18 | `nrb_ItemBuyGBCoin(p, itemid)` | FUN_00449600 | Merchant FUN_004c7490 | 0x3003 BUY (Z04 §2.1 calls it `nrb_ItemBuyCoin`) |
| 0x1c | `nrb_ItemBuyGuildToken(p, itemid)` | FUN_00449600 | Merchant FUN_004c7290 | 0x3003 BUY → `so_ply_ItemBuyGuildToken` (Z04 §2.3) |
| 0x20 | `nrb_ItemBuyItemMoney(p, itemid, &id, &lot)` | FUN_004c5560: `id = 0xFFFF, lot = 0` | Merchant FUN_004c7590 (Z27 §6.7) | 0x3003 BUY (Z04 §2.1-§2.2) |
| 0x24 | `nrb_SaveLinkData(i)` | FUN_004a9c90 (`return null` fold) | portals FUN_004c23f0 | portal `nrb_Role`s, 0x181F MULTY_LINK_SELECT (Z01 §7.3) |
| 0x28 | `nrb_GetSaveLinkSize()` | FUN_00570b00 (`return 0` fold) | portals FUN_004c2410 | the same and the portal level slots below |
| 0x2c | `nrb_BriefInformSet(npc, arg)` | FUN_00509900 (empty fold) | Portal / RandomMulti FUN_004c2360, ID FUN_004c5680, Mode-ID FUN_004c5730 | `nm_SetNPC` with the row's `RoleArg` (Z09 §5.9) |
| 0x30 | `nrb_LinkBrench(p, n, link, from, to)` | FUN_004c7a00: notice "Not gate" | portals FUN_004c7ab0 | GM `&templink` (Z11 §4.1) |
| 0x34 | `nrb_LinkBrenchCheck(link)` | FUN_004c7b40: false | portals FUN_004c7b90 | `smfm_Link`, `sp_LinkReplyCheck` (Z11 §4.1, Z02 §6.5) |
| 0x38 | `nrb_CanItemRepurchase()` | FUN_004b8d20 (`return 0` fold) | Merchant FUN_004c7690 | `so_ply_CanItemRepurchase` FUN_005379f0 (vt 0xe6c, §4.2), `nrm_ShopMenuOpen` (Z02 §6.5) |
| 0x3c | `nrb_GetLevelFrom()` | – (portals only) | Portal / RandomMulti FUN_004c5580, ID FUN_004c56b0, Mode-ID FUN_004c5770 | Portal and Mode-ID `nrb_Role` (Z02 §6.5, Z08 §5.2) |
| 0x40 | `nrb_GetLevelTo()` | – | Portal / RandomMulti FUN_004c5600, ID FUN_004c56f0, Mode-ID FUN_004c57d0 | the same |

```pseudo
NPCRoleBase::NPCRoleBase(role, row)                                                     @ FUN_004c5370
    nrb_argument = row ? row.rolearg : ORToken("")              # 20-byte token, compared as 5 dwords
NPCRole_ID_Portal(row) FUN_004c5460, NPCRole_Mode_ID_Portal(row) FUN_004c54b0, NPCRole_RandomMulti_Portal(row) FUN_004c5510:
    base ctor, then nrb_BrenchNumber = 0, nrb_LinkNum = 0, the five nrb_pSaveLinkInfo = null, and the dungeon pointers = null
    # BrenchNumber 0 = the normal LinkTable behaviour (Z11 §4.1); callers: nm_Load only

# Merchant price slots: a plain column of the item's ItemInfo row (Z27 §6)
nrb_ItemSellPrice(p, id)                                                                @ FUN_004c7050
    p.so_mapindex() is 0xFF or 0xFFFF: assert "…nrb_ItemSellPrice : Wrong mapindex"; return 0
    row = itemdatabox[id]; none: assert "…nrb_ItemSellPrice : cannot found item inform"; return 0
    return row.SellPrice
nrb_ItemBuyPrice FUN_004c7190 → row.BuyPrice;  nrb_ItemBuyFame FUN_004c7390 → row.BuyFame;
nrb_ItemBuyGBCoin FUN_004c7490 → row.BuyGBCoin;  nrb_ItemBuyGuildToken FUN_004c7290 → row.BuyGToken
    # no map test; unknown item → assert + 0. The assert text of BuyPrice / BuyFame / BuyGBCoin is
    # "NPCRole_Merchant::nrb_ItemSellPrice : cannot found item inform" (copy-paste) (original bug) Z31-B17

NPCRole_Merchant::nrb_CanItemRepurchase(role)                                           @ FUN_004c7690
    return role.nrb_argument == ORToken("Item") or == ORToken("Weapon")
    # function-local static tokens built on first use (atexit destructors); only the "Item" and "Weapon" merchants
    # keep the buy-back list (0x305B, §4.2); Skill / SoulStone / WeaponTitle / Guild merchants do not

# Portal link rows
NPCRole_Portal::nrb_linkinform(i) → LinkTable row i or null                             @ FUN_004c5420
    OptionReader::or_SelectFromOrder(&npcmanager.nm_NPCInfo, ORToken("LinkTable"), i)
NPCRole_Portal::nrb_BriefInformSet(role, npc, arg)                                      @ FUN_004c2360
    for i = 0, 1, … while (row = role.vt[0x8](i)) != null:
        row.index == arg: role.nrb_pSaveLinkInfo[role.nrb_LinkNum++] = row
            # no bound: a sixth matching row writes past the 5-pointer array (original bug) Z31-B16;
            # latent: the 2016 NPC.txt has at most 4 LinkTable rows per argument (GBHouse01…05)
    nrb_LinkNum > 0: npc.so_SetGateBriefInform(row0.linktoclient)   # ShineNPC vt 0x4cc FUN_00557bc0: brief flag
                                                                     # +0xe = 1, 12-char client map name at +0xf
NPCRole_ID_Portal::nrb_BriefInformSet                                                   @ FUN_004c5680
    Portal version; nrip_pIndunInfo = fieldlist.fc_GetInstanceDungeonInfo(arg, ILT_NORMAL)
NPCRole_Mode_ID_Portal::nrb_BriefInformSet                                              @ FUN_004c5730
    Portal version; nrmip_pIndunInfo[k] = fc_GetInstanceDungeonInfo(arg, ILT_EASY + k) for k = 0, 1, 2
nrb_SaveLinkData(i) FUN_004c23f0: i > nrb_LinkNum → null, else nrb_pSaveLinkInfo[i]
    # i == nrb_LinkNum passes the test (off by one; part of Z31-B16): reads the null slot after the last row, or
    # past the array when 5 rows are stored; every caller loops i < nrb_GetSaveLinkSize, so no 2016 path reaches it
nrb_GetSaveLinkSize() FUN_004c2410: nrb_LinkNum

# Level range of a gate (FieldLevelDataBox::fldb_GetFieldLv(map, mode), Z14 §1.1: LvFrom / LvTo of the field)
NPCRole_Portal::nrb_GetLevelFrom                                                        @ FUN_004c5580
    no link rows: return shineparam.levellimit
    from = levellimit; for each stored row: lv = fldb_GetFieldLv(row.linktoserver, 0)
        lv missing: from = 1   else from = min(from, lv.LvFrom)
    return from                                  # lowest LvFrom over the destinations; a destination without a row opens it from 1
NPCRole_Portal::nrb_GetLevelTo                                                          @ FUN_004c5600
    no link rows: return 1
    to = 1; per row: lv missing: to = levellimit   else to = max(to, lv.LvTo)
    return to                                    # a missing row sets levellimit, a later row can only raise it
NPCRole_ID_Portal::nrb_GetLevelFrom / To                                                @ FUN_004c56b0 / FUN_004c56f0
    no dungeon info: From = levellimit, To = 0 (empty range)
    lv = fldb_GetFieldLv(info.MapIDClient, info.ModeIDLv): From = lv ? lv.LvFrom : 1;  To = lv ? lv.LvTo : levellimit
    # the ID gate's own nrb_Role (Z08 §5.2) does not call slots 0x3c / 0x40: these two bodies have no 2016 caller
NPCRole_Mode_ID_Portal::nrb_GetLevelFrom / To                                           @ FUN_004c5770 / FUN_004c57d0
    over the three dungeon infos (null skipped): From = min LvFrom (start levellimit; a missing level row → 1),
    To = max LvTo (start 0; a missing row → levellimit)   # no dungeon at all: [levellimit, 0], every level refused (code 2)

NPCManager::nm_MarkingNPC(nm, Name8 mobIndex)          (log name nm_StandNPC)          @ FUN_004c6870
    # WM 0x086A NC_MISC_EVENTNPC_STANDSTART_ZONE_CMD (Z01 §9 "nm_StandNPC start"): a scheduled event NPC appears
    for each static entry whose row.mobname (32 chars) == mobIndex:
        id = mobdatabox index of the name (unknown: assert "NPCManager::nm_StandNPC : Invalid mob id"; next)
        npc = som_GetObject(entry.handle); require npc and npc.so_mob_MobID (vt 0x708) == id
        npc.so_npc_SetLocation(row.map, row.coordx, row.coordy, row.direct_degree) (vt 0xb4c)
        so_MapMarking(npc, 0) ≠ FM_MARKSUCCESS: som_FreeObject(entry.handle, REMOVE_NOW, 0x22); stop the walk
        so_AllInMap(npc, so_BroadcastBriefInfo, 0)                   # show it to the players around
        npc.so_npc_FromTable() (vt 0xa80)                             # sn_FromTable = 1
    # the NPCs were spawned unmarked by nm_SetNPC (Z09 §5.9); the end command 0x086B is FUN_004c6ad0 (Z01 §9)

NPCManager::~NPCManager(nm)                                                             @ FUN_004c7cc0   (atexit of npcmanager)
    for the 1024 entries: entry.func → reset to the NPCRoleBase vftable and free (no virtual destructor)
    ~OptionReader(nm.nm_NPCInfo)                                    # the NPC.txt tables (Z09 §28.6)
```

### 9.2 Merchant cities (`MerchantCityData`, `ItemMerchantInfo.shn`)

`MerchantCityData` is a `BinaryDataBox<MerchantLocation>` (§7.1 row `MerchantLocation`, key 5, row 5 bytes:
`{char Map[4]; u8 Sub}`). Loader `MerchantCityData::mcd_Load` FUN_004c77b0 = `bdb_ReadData("../9Data/Shine/ItemMerchantInfo.shn")`
(start stage `zs_start_wide`, label `merchantcity`, Z10 §7.1). 2016 contents: Rou 0, Eld 1, Urg 2, All 3, Fer 4, Kas 5, Sad 6, Kor 7, Ver 8, Mys 9.

```pseudo
MerchantCityData::mcd_city(mcd, mapIndex) → city number                                @ FUN_004c7860
    info = mapdatabox.mdb_index[mapIndex] (index ≥ mdb_maxmapid or null: return 0)
    for each row: strcmp(row.Map, info.MapName as a 12-char string) == 0: return row.Sub
    return 0
    # callers: NPCRole_Merchant::nrm_ShopMenuOpen FUN_004c26b0 and nrm_GuildShopMenuOpen FUN_004c2990 (Z02 §6.5):
    # the city selects which "sold in this city" flag of ItemInfo the shop list uses
```

Only maps whose whole name equals a row (`Rou`, `Eld`, …) match. A merchant on any other map gets 0, the value of Roumen
(see "Not reconstructed").

### 9.3 Item authority: the box-to-box matrices (`CItemAuthorityBase`)

`CItemAuthorityBase` (0x368, base of `ItemBelongAttribute g_ItmBelongAttr`, Z04 §1.3) holds three
`bool [17][17]` matrices `[from box type][to box type]` (types of Z04 §1.1): `IA_Common` +0x4, `IA_ChrBelong` +0x125,
`IA_AccBelong` +0x246. `IA_CanInvenReloc` FUN_00632280 (Z04 §1.3 `BelongType_CanMove`, Z30 §8) uses the character-bound matrix
for character-bound items, the account-bound one for account-bound items, else `IA_CanStorage` and the common one.

```pseudo
CItemAuthorityBase::CItemAuthorityBase(a)                                               @ FUN_00631e50
    clear the three matrices; set true (from → to):
    common:    9→{0, 3, 6, 8, 9, 12, 13, 14, 15, 16}, 8→9, 0→{0, 9}, 2→9, 4→9, 5→9, 6→{6, 9}, 3→3, 12→12, 13→13, 14→14, 15→15, 16→16
    char-bound: the same without 9→0 and 9→6           # no academy reward storage, no account storage
    acc-bound:  the same without 9→0                    # account storage allowed
    # the [16][16] entries are set with one 2-byte write that also sets the next matrix's [0][0] (compiler-merged)
CItemAuthorityBase::~CItemAuthorityBase FUN_00632000 (vftable reset; from ItemBelongAttribute's deleting dtor FUN_0064b1e0
    and the atexit of g_ItmBelongAttr); scalar deleting dtor FUN_00632250 (vt 0, no caller: the object is a global)
```

So an item may enter a box other than its own only from the main inventory (9), and may leave any box only to the main
inventory. Equipment (8) is reached only from 9. No class allows 9 → 4 (guild storage): `ItemReloc_Do` refuses that
target earlier with 0x246 anyway (Z04 §4.1).

### 9.4 Duplicate-menu table, booth search categories, street booth objects

`DuplicatedMenuControl::dmc_Table` (static data DAT_00754380, 7 × 7 bytes, `dmc_Table[open][new]`, 1 = may be open together):

| open \ new | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| 0, 1, 2, 3, 6 | 0 | 0 | 0 | 0 | 1 | 1 | 0 |
| 4, 5 | 1 | 1 | 1 | 1 | 0 | 0 | 1 |

Menu numbers set by the 2016 code (`so_ply_dupmenu_Set` / `_close` / `_canmenuopen`, vt 0x6b0 / 0x6b4 / 0x6ac, §4.8):
0 shop (Merchant / MenuOpen `nrb_Role`), 1 account storage (StoreManager), 2 trade / street booth (`sp_NC_TRADE_PROPOSE_REQ`,
`so_CloseTradeMenu`, `sp_CloseStreetBooth`), 6 item upgrade (the three upgrade REQs, closed by their Item DB ACKs). 3, 4
and 5 are never set. Shop, storage, trade and upgrade therefore exclude each other, and none can be opened twice.

`BoothItemTypeMatchingInfo gMarketSearchInfo` (0x8: `bitmi_nSize`, `MarketSearchInfo* bitmi_MatchingArray`):

```pseudo
BoothItemTypeMatchingInfo::InitInfoArray(m, path) → ok                                 @ FUN_0062de00
    CDataReader.Read(path, key 0x12, row 8); fail → 0
    n = row count; 0 rows → 0 (array not built)
    array[i] = { AuctionSubType, MarketSearchType } of row i (a missing record → { AG_ALL, MS_ALL })
    # caller zs_start_sleep with "../9Data/Shine/MarketSearchInfo.shn" ("Fail to read 'MarketSearchInfo.shn'"; 34 rows
    # in 2016); the reader is GetValue FUN_0062df10 (Z06 §2.6: booth search by category, MAX_MARKETSEARCH when absent)
~BoothItemTypeMatchingInfo FUN_0062dde0: free the array (atexit)
```

Street booth objects (`StreetBooth` base, `StreetBoothSell`, `StreetBoothBuy`, Z06 §2.1): `sb_Type` (vt 0) returns
"Base" FUN_00401510, "Sell" FUN_0058f3c0, "Buy" FUN_0058f3d0 (only log texts; FUN_00401510 is also slot 0 of
`AbnormalStateElement`, an identical-code fold). Destructors `~StreetBooth` FUN_0058cbe0 (vftable reset), `~StreetBoothBuy`
FUN_0058f3b0 and `~StreetBoothSell` FUN_005905a0 (own vftable, then the base) run from `~BoothSell` FUN_005499e0 and
`~ShinePlayer` (§2.9). `BoothStoreManager::~BoothStoreManager` FUN_0043b530 (`std::list<BoothStoreInfo>` clear + free; the
booth search index of Z30 §8 / Z06 §2.1) runs only from the unwind funclets of `BoothManager`'s ctor / dtor.

### 9.5 Repurchase list (`CSellItemManager`, `p.sp_SellItemManager`)

`CSellItemManager` (0x141c) = `List<SellItemInfo>` of 42 over `simg_SellItemNode[42]` (ctor Z18 §4.8). `SellItemInfo`
(0x7a) = `{u16 nHandle, SHINE_ITEM_REGISTNUMBER nSellItemKey, ItemTotalInformation ItemTotalInfo}`; the list handle is
the slot index. List slots: vt 8 `l_AllocZ(h)`, 0xc `l_Free(h)`, 0x18 `l_PopA` (oldest).

```pseudo
CSellItemManager::simg_Insert(m, sellKey, item, &dropped) → handle                      @ FUN_0050e360
    item == null: return 0xFFFF
    dropped = 0xFFFF
    h = the free ring's next slot; h == 0xFFFF or l_AllocZ(h) fails:
        l_PopA(&old); dropped = old.nHandle                   # list full: the oldest entry leaves
        retry; still failing: assert "CSellItemManager::simg_Insert : Allocation fail"; return 0xFFFF
    e = { nHandle = h, nSellItemKey = sellKey, ItemTotalInfo = *item (0x6f bytes) }
    return h
    # caller so_ply_SellItemList_Insert FUN_00537a20 (Z05 §1.4: 0x305C INSERT, 0x305D DELETE for `dropped`)
CSellItemManager::simg_Delete(m, h) → ok                                                @ FUN_0050e170
    h == 0xFFFF: 0;  l_Free(h) fails: assert "CSellItemManager::simg_Insert : Free fail" (copy-paste text, Z31-B17); 0
    # caller so_ply_SellItemList_Delete FUN_00537ba0 (0x3059 REPURCHASE, Z04 §2.5 / Z05 §1.4)
CSellItemManager::simg_Initialize(m, n, PROTO_SELL_ITEM_INFO_SERVER* rec) → ok          @ FUN_0050e1b0
    n ≥ 43: assert "…simg_Initialize : Size over"; 0
    n times: e = l_AllocZ(rec.nHandle) (fail: assert "…AllocZ fail", the record is not skipped: the same record is tried again
             for the next count *(read: rec advances only on success)*)
             e.nHandle = rec.nHandle; iti_fill2struct_whole(&e.ItemTotalInfo, default class, 0xFFFF, &rec.ItemTotalInfo)
             rec += rec.nDataSize (counted from &rec.nHandle)
    return 1
    # caller so_ply_SetSellItemInfo FUN_00537930 (vt 0xe64) ← WM 0x1130 NC_CHAR_SELL_ITEM_INFO_ZONE_CMD (Z07 §1.2)
~CSellItemManager FUN_0050e340: free the list array (~ShinePlayer, the player ctor's unwind)
ListEraser<SellItemInfo>::~ListEraser FUN_0050e4c0: vftable reset (unwind of List<SellItemInfo>::l_ClearAll)
```

The list crosses a map change as `PROTO_SELL_ITEM_INFO_SERVER {u8 nDataSize, u16 nHandle, u64 nSellItemKey, item}`.
`simg_FillBuffer_Server` FUN_0050e4d0 (§4.2, to WM with the save) writes `nHandle`, the item and `nDataSize` (which counts the
8 key bytes) but never `nSellItemKey`. `simg_Initialize` never reads it either. After a map change every entry keeps whatever
key its list slot held before (−1 from the ctor, or an older entry's key). `sp_NC_ITEM_REPURCHASE_REQ` FUN_00538580 passes
`nSellItemKey` to `ii_RepurchaseLot` / `ii_RepurchaseAll`, and D03 §2 shows that the key only reaches the repurchase log rows
(original bug) Z31-B19.

### 9.6 Guild academy buffs, guild and academy storage elements

```pseudo
ShineGuildAcademyGuildBuff(cmd) FUN_0046e070 (Z08 §10: the 0x987A visitor)
    sgagb_GuildBuff = cmd; sgagb_dic = dic_abstate[BTree index of cmd.BuffName]   # unknown name: assert "…as_FromID : Invalid skill id", null
ShineGuildAcademyGuildBuff::lid_Call(v, o) → continue                                  @ FUN_0046e110   (over the player list)
    g = o.so_ply_isAcademyGuildMember() (vt 0x858) == 0 ? o.so_mobile_GetGuildRegnum() (vt 0x818)
      : == 1 ? o.so_ply_GetMyGuildAcademyNo() (vt 0x85c) : (the object pointer: never matches)
    for i < cmd.NumOfGuild: cmd.Guild[i] == g:
        sgagb_dic == null: stop
        o has abstate STA_ACAMSBUF10P (298) or STA_ACAMSBUF7P (300) (vt 0x3e4): stop      # the master buff wins
        sub = sgagb_dic.subabstate[1].assa_info; sub ≠ null and
        o.so_AbnormalState_Set(o, index, strength 1, dic, now, 0, −1, sub.KeepTime, 1, 0) (vt 0x638):
            so_AbnormalState_BitSet(o, index); so_AbnormalState_BroadcastSet(o, index, −1, 1); o.so_AbnormalState_Inform(index, −1, 1) (vt 0x3f0)
        stop
    return 1
ShineGuildAcademyMasterBuff::lid_Call(v, o) → continue                                 @ FUN_0046e2d0   (0x987B, Z08 §10)
    for i < cmd.NumOfMaster: cmd.MasterBuff[i].nMasterCharNo == o.charNo (vt 0x344):     # GUILD_MASTER_BUFF {char BuffName[32]; u32 nMasterCharNo}
        st = dic_abstate[BuffName] (unknown: assert, nothing); sub = st.subabstate[1].assa_info
        sub ≠ null: o.so_AbnormalState_Set(o, index, 1, st, now, 0, −1, sub.KeepTime, 0, 0)
        stop
    return 1
    # unlike the guild buff, no BitSet / BroadcastSet / Inform call follows (see "Not reconstructed")
```

Storage elements (Z14 §4 academy reward storage, Z14 §3 / Z05 §7.2 guild storage):

| Function | Behaviour | Caller |
|---|---|---|
| `GuildStorageElement::GuildStorageElement` FUN_00474920, `GuildAcademyRewardStorageElement::GuildAcademyRewardStorageElement` FUN_00470820 | bag ctor (`ItemGuildStorage` 36 cells / `ItemGuildAcademyRewardStorage` 72 cells of 0x74), `gse_Guild` / `garse_Guild` = 0 | the managers' array ctors; the stack search key of `gsm_FindStorage` FUN_004751f0 / `garsm_FindStorage` FUN_0046f710 (Z14) |
| `GuildStorageElement::operator=` FUN_00474fe0, `GuildAcademyRewardStorageElement::operator=` FUN_00471c30 | copy the 36 / 72 cells, `Cen` (u64), guild storage also `Token` (u64), `Guild`, `Activate` | the lists' `l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` (FUN_004754f0 … FUN_004755c0, FUN_00472dd0 … FUN_00472ea0) |
| `garse_SetMoney(cen)` FUN_004709a0, `garse_SetActivate()` FUN_00470880 | `garse_Cen = cen`; `garse_Activate = 1` | `so_ply_GuildAcademyRewardStorageWithdrawAck` / `…DepositAck` (Z14 §4); `so_ply_GuildAcademyRewardStoreFill` |
| `~GuildAcademyRewardStorageElement` FUN_00470860 | destroy the 72 cells, `ItemBag` vftable | the search key's unwind |
| `GuildAcademyRewardStorageManager` scalar deleting dtor FUN_00471ba0 | destroy the 500 elements (0x20b8), free the list | vt 0 only (the manager is a global) |
| `ListEraser<GuildStorageElement>` FUN_00474a70, `ListEraser<GuildAcademyRewardStorageElement>` FUN_0046f700 dtors | vftable reset | unwind of `l_MakeList`, the `FindStorage`s and the managers' initializers |

### 9.7 Party table, object finders, map kick

```pseudo
CParty::CParty → CParty::Init(partycontainer)                                           @ FUN_00645c10 / FUN_00645a80
    m_Array = malloc(4000 × 0xD0)                 # PARTY_SLOT {u8 NumOfMember; PARTY_MEMBER_SLOT Members[5]; CLooting
                                                  #  m_Looting; bool IsBelongItemDiceGameIng; bool isRaidTypeParty} (Z08 §1)
    m_NumOfParty = 0; per slot: NumOfMember = 0, one byte near the end and the five members' object pointers = 0
    m_EmptyPartySearchPoint = 0
    CParty::p_def = copy of slot 0                # the slot operator[] FUN_00645340 returns for party numbers ≥ 4000
    # malloc does not clear: the looting fields, the member records and p_def's copies of them are uninitialised
    # (original bug) Z31-B18; latent: a 0xCB200-byte block comes from fresh zero pages at start-up
    # caller: partycontainer's dynamic initializer (start-up)
```

Finders (visitors of `ShineObjectManager`, Z01 §4.2; each stops the walk at the first hit and stores the object):
`ShineCharRegnumFinder::lid_Call` FUN_005500b0 (charNo, vt 0x344) for `som_FindPlayer(charNo)` FUN_00550360;
`ShineCharIDFinder::lid_Call` FUN_00550180 (`Name5` name, vt 0x56c, five-dword compare) for `som_FindPlayer(name)`
FUN_00550430 and `som_FindNPC(name)` FUN_00550500; `ShineMobIDFinder::lid_Call` FUN_00550290 (mob ID, vt 0x708) for
`som_FindNPC(mobId)` FUN_005505d0 (Z11 §9.2).

```pseudo
FieldMap::fm_KickAll(map): so_AllInMap(map's centre object, KickPlayer{_Map = map}, 1)   (Z09 §28.8)
KickPlayer::ali_Work(k, sender, o) → 1                                                  @ FUN_00484e20
    o.so_ObjectType (vt 0x4d0) ≠ 2 (not a player): continue
    link = { linktoserver = linktoclient = fm_RegenCity(map) (12 chars), (x, y) = map.fm_FieldOption.regenloc[r],
             r = rndbox[regenspot count (+0x9a)] (≥ 4 → regenloc[0]), direct 0 }
    o.so_LinkToReserv(link, 0) (vt 0x3fc)
    # callers of fm_KickAll: MapCluster::mc_AllDropFilm FUN_00485290 and mc_DeleteInstanceDungeon FUN_00486710 (Z14 §1.7);
    # the same rule as wms_KickPlayerFromInstanceDungeon (Z14 §1.8) without its dead-player branch
~KickPlayer FUN_00484660: AxialListIterator dtor (fm_KickAll's unwind)
```

### 9.8 Events, random slots, cease fire, announce, item list maker, weapon titles

```pseudo
EventSaveCheck::EventSaveCheck(e)                                                       @ FUN_00455ff0
    vftable; esc_savebuffer.location.map / map_kq = ""; esc_abstate.pnt, esc_skill.pnt = their own buffers
    # members of WholeSaver: ws_savestore[2048] (unused ring, P02-B21) and ws_saveblock (ws_save2DB's buffer)
EventSaveCheck::erb_happen(e)                                                           @ FUN_00453d90   (vt 0, EventReserveBase)
    esc_savebuffer.handle.chrregnum ≠ −1:
        assert "EventSaveCheck::erb_happen : Error in Character save", chrregnum
        write the first 0x69 bytes of the save buffer to "NotSaved.bin" (fopen "wb", not checked; fclose)
    # dead: an erb_happen runs only for an event put into zonevent, and the only zonevent users are the KQ gate
    # keepers (Z16 §2.3), the two recurring start-up events (Z10 §7.1) and the main loop (Z09 §1.1)
EventReserveContainer::EventReserveContainer(c, n)                                      @ FUN_005b22a0   (zonevent: n = 1000)
    List<EventReserveListElement>::l_MakeList(n); erc_eventarr = new EventReserveListElement[n] (0x10: erle_happened,
    erle_event, erle_handle, erle_repeat); slot i → erc_eventarr[i]
    # scalar deleting dtor FUN_005b04a0 (vt 0, no caller) frees both; ListEraser dtor FUN_005b0490 = vftable reset
```

- `RandomSlot::rs_Init(n)` FUN_0063cd20 builds the 16 384-entry ring of one `RandomBox` box (Z23 §8.6): `slot[i] = (i·n) >> 14`,
  then 16 384 swaps of slot i with a random index (an index ≥ 16 384 skips the swap), then values ≥ n are set to 0. That last
  clamp never fires, because `(i·n) >> 14 < n` (dead check) (original bug) Z31-B20. Caller: `RandomBox::RandomBox` FUN_0063cdb0.
- `CeaseFireSender::cfs_Send` FUN_00566810 (our earlier name `BashStopNotify_Set`) sets `cfs_Flag = 1`; caller `smo_BashStop`
  FUN_0042e840 (vt 0xed8). `cfs_Routine` FUN_00566820 sends 0x243D on the next player tick (Z09 §2.3, Z03 §3.4).
- `CAnnounceSystem gAnnounceSystem`: ctor FUN_005b8d10 (a `CDataReader`; the same body is the ctor of `gBadNameFilterData`,
  §8.5), `Read(path, key, size)` FUN_0062df50 = `CDataReader::Read` (`zs_start_moon`: `AnnounceData.shn`, Z10 §7.1),
  `AnnounceSystem_ItemTake(name, itemid)` FUN_005b8f50 = `return 0`. Its caller `so_ply_PickupItem` FUN_0052faf0 gets no
  item-pickup announcement in 2016 (the roar uses `AnnounceSystem_Roar`, Z04 §6.4).
- `ItemListMaker` (reward item batches, Z05 §9.2 0x344D): ctor FUN_005956c0 (`ilm_ItemNum = 0`, `ilm_InvenType = type`);
  `ilm_ItemMake(item)` FUN_00595740: null → 0xFFFF; already 8 items → assert "ItemListMaker::ilm_ItemMake : Too many content",
  0xFFFF; else copy the 0x6f-byte item into `ilm_List[ilm_ItemNum++]` and return its item ID. Callers: Lua `cRewardItem`
  FUN_005e17e0 / `cRewardItem_AllInMap` FUN_005e1b30 and `SMS_StopButton` FUN_00625340 (Z32); `ilm_PutInto` is Z18 §4.8.
- `CWeaponTitle gWeaponTitle`: ctor FUN_006358a0 (reader, `m_ppWTDArray` null, `m_MaxArrayIndex` 0), dtor FUN_00635a50 (free
  the index array, reader dtor); loader and readers Z12 §2.3 / Z18 §6.6.

### 9.9 Constructors and destructors of the other containers

| Object | Function | Behaviour | Caller |
|---|---|---|---|
| `ItemOperateList ShineObject::so_defitemoperate` | ctor FUN_0052eb40, dtor FUN_0052d7b0, scalar dtor FUN_0052e930, `ListEraser<ItemOperateElement>` dtor FUN_0052d7a0 | `List<ItemOperateElement>` of 40 over `iol_array[40]` (0x78) / destroy and free | dynamic initializer / atexit only: no 2016 code uses the list (dead) |
| `BattleObjectGroup::BattleObjectList btlobjlist` | ctor FUN_00437610, scalar dtor FUN_00435e30, `ListEraser<BattleObject>` dtor FUN_00435e20 | list of 1024 `BattleObject` (0xe0) | initializer / atexit; users `so_Bash` FUN_0042e950, `smo_SkillBlast` FUN_00581160 (Z03, Z25 §1.2) |
| `JunctionPointContainer junctionpointlist` | ctor FUN_004ced20 | `List<PathFindCellLoc>` of 200 over `jpc_array` | initializer / atexit only: unused (dead; path finding is part 9) |
| `CGuildZone gGuild` | ctor FUN_005cd410, dtor FUN_005cc880, `ListEraser<GUILD_ZONE_LIST>` dtor FUN_005cccd0 | `m_bInit` 0, `gz_IsSendReq` 0, `List<GUILD_ZONE_LIST>` of 16 384 over `gz_GuildArray` (0x3c) / free | initializer / atexit; the guild-zone handlers are its vtable (Z08 §8) |
| `KingdomQuestContainer kqcontainer` | scalar dtor FUN_004976f0; `ListEraser<KQElement>` FUN_004953d0, `ListEraser<KQPlayerInform>` FUN_004972b0 dtors; `PROTO_KQ_INFO::~PROTO_KQ_INFO` FUN_0041d3a0 | destroy the 300 `KQElement`s (0x42c), free / vftable resets / the four `MapLink` (0x1a) | vt 0 only / unwind funclets, `~KQElement`, `KQPlayerInfoList` ctor (Z16 §1.1-§1.2) |
| `CLCReward gLCReward` | dtor FUN_0049d310 | free every reward group's item array, the group array, the item vector, the two boxes (`LCReward`, `LCGroupRate`) | atexit (capsule rewards, Z09 §28.13) |
| `GMEventManager gGMEventManager` | dtor FUN_0046dc80 | free the event vector | atexit (Z09 §3) |
| `TreasureChestLocationManager` (player member) | dtor FUN_0052d650 | free its buffer | `~ShinePlayer` and the ctor's unwind (Z09 §28.10) |
| `CCharacterTitleZone` (player member) | dtor FUN_005ca600 | empty | `~ShinePlayer`, the ctor's unwind, the atexit of a static object (Z12 §7.4) |
| `Raid`, `LuaScript`, `LuaScriptArgument::LuaArgumentDefault`, `LuaFuncTrigger::TriggerElement` | scalar dtors FUN_0063d1d0, FUN_005f2030 (`lua_close` the state), FUN_005f1ee0, FUN_00490800 | vftable reset (+ free) | vt 0 only: never deleted through the vtable |
| `LuaArgumentInstanceDungeon` | dtor FUN_005d7770 | resets the `LuaArgumentDefault` vftable: the identical-code fold of every Lua argument destructor | 73 callers (every function with a stack argument object: `so_DamagedBy`, `so_KilledBy`, …; Z09 §14.4) |
| `PineEventScriptNode::ScriptAtom` | dtor FUN_004d64b0 | vftable reset (fold) | the unwinds of `Express`, `Condition`, `Term`, … (18; map scripts, Z09) |
| `ListEraser<PineEventScriptNode::Statement>` / `<Block>` | FUN_004d9be0 / FUN_004d9bf0 | vftable reset | `l_MakeList` unwinds |
| `ListEraser<CardDeck::Card>`, `ListArray<CardDeck::Card>` | FUN_0064ca70, FUN_0064e140 (free `la_Array`) | vftable reset / free | unwinds of `cd_Load`, `iod_Load` (§8.1), `CardStack` |
| `BroadcastEventPopper` | dtor FUN_005497c0 | `g_BroadcastStackPoint −= 1` while ≥ 0 (the re-entrance counter of the broadcast walks; ctor FUN_005496d0, Z09 §28.1) | the unwinds of `so_AllInMapNomal` / `so_AllOfRangeNomal` |

## 10. Sessions, the player send buffer, broadcast visitors, path finding, library classes

The 154 functions of the part-9 bucket: the server-to-server session classes and their session manager, the player's
`PacketContainer`, the `AxialList*` visitors whose `ali_Work` no document cited, the map-cluster copies, the rest of the
dead path tracers, the start-up geometry tables, and the library / diagnostic classes. The rest are vftable resets
(§10.8).

### 10.1 Server-to-server sessions

Every session class is a `ZoneBaseSession` (0x100 bytes: +4 `m_Status`, +8 `m_Connected_Server_ID`, +0xc / +0x10
world / zone, +0x24 / +0x28 last receive / send tick, +0x2c `CSocket_IOCP`, +0xe0 `CPacket m_Packet`, +0xf8
`IOCPProcessSession`, +0xfc `m_LastHeartBeatSendTime`). Vtable: slot 0 `CheckHeartBeat` (`ZoneBaseSession::CheckHeartBeat`
FUN_005a67c0, Z18 §1.4; `ClientSession`'s FUN_0045b110 form passes 300, S02 §4.4), slot 1 `zbs_Parsing` (one per class),
slot 2 the folded empty destructor FUN_00417480; `ClientSession` adds slot 3 (FUN_005af8d0 `return 1`; in
`ClientSessionNull` FUN_004b8d20 `return 0`).

| Class | Constructor | `m_Connected_Server_ID` default | Owner |
|---|---|---|---|
| `GameDBSession` | FUN_00468510 | 2 | `SocketBundle<GameDBSession> sock2gameDB` (element ctor FUN_005ae730) |
| `GameLogSession` | FUN_00469f60 | 3 | `sock2gamelog` (element ctor FUN_005ae750) |
| `WorldManagerSession` | FUN_005a2ce0 | 5 | `sock2wldman` (element ctor FUN_005ae770) |
| `ZoneConnectSession` | FUN_005a6cd0 | 3 (the GameLog value; nothing rewrites or reads it for the ring link) (original bug) Z31-B25 | `zoneconnect` (`g_ZoneRingNext`, Z01 knowledge), dynamic initializer FUN_0069afa0 |
| `ClientSession` | FUN_0045b0a0: `cs_sessionMode = INACTIVE`, `cs_bClosingSession = 0` | 0 (`zs_connect` sets 20) | `ClientSessionManager` array (Z10 §6.5 `InitSessions`) |
| `ClientSessionNull` | FUN_0045b0d0: +0x104 = −1, +0x10c = 0 | 0 | `ShinePlayer::sp_defaultsocket` (initializer FUN_00698790): the null session of a player without a socket |

The `SocketBundle<T>::<sb_SocketStr>` element constructors (FUN_005ae730 / FUN_005ae750 / FUN_005ae770) only run the
session constructor; the bundle builds its four elements with `_eh_vector_constructor_iterator_`. Each element is
0x108 bytes: the session, then the reconnect tick (+0x100) and a state byte (+0x104).

```pseudo
GameDBSession::gds_DummyFunction(s, cmd, len)          @ FUN_00468690
GameLogSession::gls_DummyFunction(s, cmd, len)         @ FUN_00469fa0
WorldManagerSession::wms_DummyFunction(s, cmd, len)    @ FUN_005a2d20
    assert "<Class>::<name>" with "%d/%d:%d" (dept / cmd : len)         # the packet is dropped; the link stays up
OPToolSession::opts_DummyFunction(s, cmd)              @ FUN_004c7fb0
    assert "ZoneListenSession::opts_DummyFunction", dept, cmd           # wrong class in the text (original bug) Z31-B23
    # the default slot of each PROTOCOLFUNCTIONTEMPLETE parser (pft_deffunc), like sp_DummyFunction for the client (§4.1);
    # none of them is called directly
ZoneConnectSession::zbs_Parsing(s, sp, idx)            @ FUN_004fb5a0   (vt 4; the seventh zbs_Parsing, Z10 §6.4 lists six)
    sp ≠ null: assert "ZoneConnectSession::zbs_Parsing : sp entry!!!"
    m_Packet.GetIDPtr (CPacket slot 0x18), GetDataSize (0x14): read and ignored
    reply 0x0805 NC_MISC_HEARTBEAT_ACK (2 bytes, header only); too long → assert "…zbs_Parsing : Packet Too Long"
    # the outgoing ring link to the next zone (zcs_Send, Z01) has no handler table: whatever the next zone sends on
    # it (its 0x0804 keep-alive, Z18 §1.4) is answered with 0x0805
```

Session manager (`ZoneBaseSessionManager`, 0x18: +4 `m_pSessionListArray`, +8 `m_MaxSessions`, +0xc `m_NumSessions`, +0x10
active list, +0x14 empty list; nodes `LOGIN_SESSION_LIST {pLinkUp, pLinkDown, pSession}`). Its vtable is
`[ActiveSession, InactiveSession]`; `ClientSessionManager` keeps both. The bodies are the Login / WM ones (L01 §2.1,
W05 §4.1):

```pseudo
ZoneBaseSessionManager::ActiveSession(m, socket, addr) → node     @ FUN_005a6be0   (vt 0; zs_connect UserData 0x14, Z18 §1.3)
    m_NumSessions < m_MaxSessions and an empty node:
        node.session.m_Packet.Clear (CPacket slot 0x2c); m_Socket = socket; copy the 16-byte sockaddr
        m_Status = CONNECTING; EmptyToActive(node); return node
    else: debug message, return null
ZoneBaseSessionManager::EmptyToActive(m, node)                    @ FUN_005a6b60
    node == null: debug message; m_NumSessions += 1; return       # the count grows without a session (original bug) Z31-B21
    unlink node from the empty list; push it at the head of the active list; m_NumSessions += 1
ZoneBaseSessionManager::InactiveSession(m, node)                  @ FUN_005a6c80   (vt 4)
    unlink node from the active list (null: skipped, then the null node is dereferenced); push it on the empty list;
    m_NumSessions −= 1
    # caller: ZoneServer::zs_disconnect FUN_005abb60, after ZoneBaseSession::Close of a cut client session (Z09 §1.5)
ZoneBaseSessionManager::FreeSessions(m)                           @ FUN_005a6a10   delete m_pSessionListArray
    # caller ClientSessionManager::InitSessions FUN_0045c4c0 (Z10 §6.5)
```

Keep-alive of the three outgoing bundles (Z09 §1.5 left them unopened; called by `zs_disconnect` with "DB", "Log", "WMS"):

```pseudo
SocketBundle<T>::sb_HeartBeatCheck(b, name)            @ FUN_005aae80   (one body for the three T)
    for the 4 elements: session.CheckHeartBeat(30) (vt 0) == 0:
        ZoneBaseSession::Close; m_Status = EMPTY; reconnectAt = now + sb_ReconnectInterval × 10; state = 0
        SocketMultiplicateLog: name, " Cut by heartbeat ", index
SocketBundle<T>::sb_DisconnectCheck(b, name)           @ FUN_005ab2c0
    for the 4 elements: m_Status == 3 (CLOSEING): the same reset, log " Close during SESSION_STATUS_CLOSEING "
    # sb_Routine (Z09 §1.5) reconnects the elements whose reconnectAt has passed
```

`zs_disconnect` checks the ring link the same way inline: `zoneconnect` with a socket and `CheckHeartBeat(30) == 0` →
`CloseUseIOCP`, `Close`, status EMPTY.

Other session pieces:

- `PROTOCOLFUNCTIONTEMPLETE<…>` scalar deleting destructors, one per parser class: `ShinePlayer` FUN_004d44c0, `GameDBSession`
  FUN_004d3790, `GameLogSession` FUN_004d54d0, `OPToolSession` FUN_004d5570, `WorldManagerSession` FUN_004d5620,
  `ZoneListenSession` FUN_004d5e90. Each frees every one of the 0x400 outer slots `pft_funcpnt[i]` that is not the shared
  `pft_defaultdepartment` array (layout Z18 §1.8 `pft_IsRegisteredProtocol`), then the object when asked. vt 0 only:
  the parser globals are destroyed by their atexit functions, not through the vtable.
- `OPToolList optoollist` (0x1a8): ctor FUN_004c86d0 = `List<OPToolObject>::l_MakeList(50)`, 50 `OPToolObject` (8 bytes; the
  element ctor is the fold `TradeBoard::TradeBoard`), list slot i → `optl_Array[i]`; scalar deleting dtor FUN_004c84c0
  (destroy the 50 elements, free the list array); `ListEraser<OPToolObject>` dtor FUN_004c84b0 (vftable reset). Users:
  `zs_connect` (take one per OPTool connection, Z18 §1.4), `zs_mainthreadfunction`, `opts_NC_OPTOOL_CONNECT_BRIF_REQ`.
- `IOCPProcessSession::~IOCPProcessSession` FUN_0064f3f0 (resets to the `CIOCP_Process_Interfece` vftable; unwinds of the
  `ZoneBaseSession` / `CSocket_IOCP` ctors and `~CSocket_IOCP`) and `CIOCP_Process_Interfece` scalar deleting dtor
  FUN_0064f660 (vt 0 only). The IOCP callbacks are S02 §1.3.

### 10.2 The player's send buffer: `PacketContainer`

`ShinePlayer.sp_SocketContainer.stream` is a `PacketContainer` (0x200c: +4 `pc_Session`, +8 `pc_Buffer[0x2000]`, +0x2008
`pc_Pointer`), set up in the `ShinePlayer` ctor FUN_0055bc80 (session null, pointer 0). Vtables: `PacketContainer`
`[FUN_00653a60 set pc_Session (fold of uir_SetSkill), pcb_Clear, pcb_Flush, pcb_Append]`, `PacketContainerBase`
`[FUN_00549070 empty, FUN_00417480 empty, pcb_Flush FUN_0054b330 → 1, pcb_Append FUN_004c8ad0 empty]` (the do-nothing
stream).

```pseudo
PacketContainer::pcb_Clear(c)                          @ FUN_00549080   (vt 4)   pc_Pointer = 0
PacketContainer::pcb_Flush(c, session) → bool          @ FUN_0054b380   (vt 8)   = pcb_Flush_Try_Catch inside an SEH frame
PacketContainer::pcb_Flush_Try_Catch(c, session)       @ FUN_004c8800
    pc_Pointer == 0: return 1
    pc_Pointer ≥ 0x2000: assert "Too long packet"; pcb_Clear; disconnect   ┐
    session ≠ pc_Session: assert "Session wrong"; pcb_Clear; disconnect    ┘ disconnect = som_GetObject(session.cs_clienthandle)
                                                                              .so_Disconnect(0x0686, 0, 0) (vt 0x5f8); return 0
                                                                              (session null: return 0 without it)
    pc_Session == null: return 1                         # the buffer is kept, not cleared (original bug) Z31-B22
    r = ZoneBaseSession::Send(pc_Session, pc_Buffer, pc_Pointer); pcb_Clear; return r
    # callers: so_PacketBufferFlush (vt 0x2e8, §4.5) once per player tick and from zs_disconnect; pcb_Append FUN_004c8b20
    # flushes through vt 8 when the next packet would pass 0x17ff bytes (Z09 §9.6)
PacketContainerBase::pcb_Flush FUN_0054b330 → 1; PacketContainerBase::pcb_Append FUN_004c8ad0: nothing
```

`AssertClass::operator()(cond, text, a)` FUN_004010e0 (the three-argument twin of Z18 §1.6's FUN_00401110: `cond == 0` →
`ac_AssertFail(text, a)`, returns `cond == 0`) has `pcb_Flush_Try_Catch` as its only caller.

### 10.3 Broadcast visitors (`AxialList*`)

`so_AllOfRange` / `so_AllInMap` (Z09 §9.6) call the visitor's slot 0 `ali_Work(visitor, centre, o, distance)` for every
object; returning 1 continues the walk. The bodies not yet cited:

```pseudo
AxialListPacketBroadcast4ItemPickUp(v, packet, len)    @ FUN_00428dd0
    alpb_packet = packet; pp_SetPacketLen(len) ok → alpb_packetlength = len, else assert "…Too long packet", length 0
AxialListPacketBroadcast4ItemPickUp::ali_Work(v, centre, o)   @ FUN_00428f40
    length 0: return 0 (stop)
    o is a player (vt 0x4d0 == 2), in a game mode (vt 0x484 ≠ 0), same main layer as centre (or either −1),
    so_SubLayer_CanSee(centre, o) and not closing (vt 0x300): o.so_GetGameSocketStream (vt 0x2fc).pcb_Append(o, packet)
    return 1
    # the plain AxialListPacketBroadcast plus the mode test; ~ FUN_00428eb0
    # users: ShinePlayer::sp_Send_NC_ITEM_SOMEONEPICK_CMD FUN_0052f0e0 (below), ShineDropItem::so_LogoutPacketBroadcast
    # FUN_00553b30 (Z09 §11.4)
ShinePlayer::sp_Send_NC_ITEM_SOMEONEPICK_CMD(p)        @ FUN_0052f0e0   (from so_ply_PickupItem FUN_0052faf0, Z04 §3.3)
    0x3014 NC_ITEM_SOMEONEPICK_CMD { Name5 pickerID = p.so_CharName (vt 0x56c), u16 itemID = sp_pickitem.itemid,
                                     u32 nItemLot = sp_pickitem.itemlot }  (26 bytes)
    so_AllOfRange(p, sight (radius 0), AxialListPacketBroadcast4ItemPickUp(gpp, 0x1c), include self 0)
    # client FUN_004abc20: only when pickerID is a member of the client's party list and the item id is valid, chat
    # line "%s of the expedition group has received an item. %s" (text 0x397e6f6b); nItemLot is not read
AxialListPacketBroadcastByGuild::ali_Work(v, centre, o) @ FUN_00428d90
    o.so_mobile_GetGuildRegnum (vt 0x818) == m_GuildRegNum: AxialListPacketBroadcast::ali_Work(v, centre, o); else 1
    # ctor FUN_00428cd0 (Z11 §9.2); users GuildGroup::CheckManagerUser FUN_004798f0, GuildTournamentSystem::DeadPlayer
    # FUN_0047e640 (Z16 §4.3 / §4.6)
AxialListCount::ali_Work(v, centre, o)                 @ FUN_00428210
    centre is a player (vt 0x4d0 == 2): alc_Cnt += 1; return 1
    # tests the centre, not o: around a player every object counts (mobs, NPCs, drops, the player itself), around
    # anything else the count stays 0. Only user: cbd_DistanceSquar FUN_0043e740 (§10.6)
AxialListMobInAreaCounter::ali_Work(v, centre, o)      @ FUN_00428240
    return v.almc_Search(centre, o)        # the member pointer chosen by the ctor FUN_004e2d00 (ala_SearchMob / All / Ply /
                                           # Gld, Z09 §22.2); dtor FUN_004e2dd0
AxialListMobKillLog::ali_Work                          @ FUN_00429590   = D05 0x078E / 0x078F (MK2_START / MK2_SUCCESS GameLog
                                                                          records per player of the map; documented there)
AxialListNearScan::alns_GetBMPDamageRate(i) → 1000     @ FUN_004c1b00   base slot; the area-bitmap override FUN_004c1b10 is Z25 §6.6 / Z09 §12.5
```

### 10.4 Map clusters: copy and teardown

```pseudo
MapClusterManager::MapCluster::operator=(dst, src)     @ FUN_0049f1d0
    mc_MapIndex (Name3); the 0x200 InstanceMap records (0x50 bytes each) word by word; mc_MapNumber; mc_Pointer
    # callers: List<MapCluster>::l_PushA / l_PushZ / l_PopA / l_PopZ FUN_004a01f0 … FUN_004a02c0 (by-value list copies)
MapClusterManager::ClusterManager::~ClusterManager(m)  @ FUN_004a0310   (atexit of mapclustermanager)
    for the 10 Clusters[] pointers: destroy the 0x200 InstanceMaps, free the cluster
    cm_EmptyCheck (folded empty dtor); the 0x200 InstanceMaps of cm_ClassChangeElfForest, cm_ClassChangeGamble,
    cm_ClassChangeRou, cm_ClassChange; free the List<MapCluster> array
    # scalar deleting dtor FUN_004a05b0 (vt 0 only); ListEraser<MapCluster> dtor FUN_00486280 (vftable reset, the
    # unwinds of cm_DeleteInstanceDungeon / cm_FindEmpty / l_MakeList). Layout: Z14 §1.2
```

### 10.5 Path finding: the rest of the dead tracers and `CFindWay`

Completes §3.8 (`CellStack`) and Z09 §28.7 (`CFindWay`); nothing here is reached in 2016.

```pseudo
LinearStep::ls_Set(ls, fx, fy, tx, ty) → Tracer*        @ FUN_004cdd60   (caller CellStack::t_trace FUN_004ce470)
    each coordinate outside ±1200: assert "LinearStep::ls_step : Out of range" (the text names ls_step) (original bug) Z31-B23
    ls_from = ls_to = (fx, fy)  (ls_to is set to the start, not to (tx, ty))
    ls_linelength = max(|tx − fx|, |ty − fy|); ls_delta1024 = (dx·1024 / len, dy·1024 / len) (0 when len 0)
    ls_count = 0; ls_Prev = ls_from; return ls
LinearStep::ls_step(ls, n, &x, &y)                      @ FUN_004cdcd0   (caller LinearStep::t_trace FUN_004ce880)
    x = ls_from.x + (delta.x · n) / 1024; y likewise (rounded toward 0); outside ±1200 → the same assert
LinearStep::t_continue(ls, arg, out, r)                 @ FUN_004ce060   (vt 8)
    ls_Prev.x² + ls_Prev.y² < r²: out = ls_Prev; return 0; else 1
PathFindTable::operator()(t, x, y) → cell               @ FUN_004cdc60   |x|, |y| ≤ 1200 → pft_table[x + 1200][y + 1200];
    else assert "PathFindTable::operator () : Out of range", &pft_def      (callers cs_push, both t_trace)
PathFindCell::pfc_Getdistance(c, stamp)                 @ FUN_004cdc40   pfc_flag == stamp ? pfc_distance : 34 463 (0x869f)
MinWeightSearching::lid_Call(s, e, h)                   @ FUN_004ce400   e.weight < mws_minweight → remember weight and h; 1
    # the visitor CellStack::t_trace uses to pop the minimum-weight element
Tracer::~Tracer FUN_004cde60 (unwind of the CellStack ctor), Tracer scalar deleting dtor FUN_004ce030 (vt 0 of Tracer and
LinearStep); ListEraser<PathFindCellLoc> dtor FUN_004ce020 (l_MakeList unwind; the dead junctionpointlist, §9.9)

CFindWay::CFindWay(f)                                   @ FUN_00633630   (global findway, initializer FUN_006967e0)
    m_bLoaded = 0; m_pBlockInfoByte = null; Init(f)
CFindWay::Init(f)                                       @ FUN_00633540
    NoJunc = NumOfJunc = 0; LenMap = null; LenMapInit(256, 256)
    DirTbl[13] = {0, 3, 4, 6, 8, 0, 12, 0, 1, 2, 0, 0, 9}; XTbl[13] = {0, 0, 1, 2, −1, 0, 0, 0, −1, 1, 0, 0, −2};
    YTbl[13] = {0, −1, 1, 0, 1, 0, 2, 0, −1, −2, 0, 0, 0}          # direction tables of FindWay (not decoded: dead)
CFindWay::LenMapInit(f, sx, sy)                         @ FUN_00632620
    a LenMap of another size is freed; none → new u16[sx·sy], LenMapSx = sx, LenMapSy = sy
CFindWay::~CFindWay(f)                                  @ FUN_006324b0   (atexit FUN_0069d880)
    free m_pBlockInfoByte when m_bLoaded == 1; free LenMap
```

### 10.6 Start-up geometry tables

```pseudo
ShineRadian::ShineRadian(r)                             @ FUN_00579070   (global shineradian, initializer FUN_00698a50)
    for i in 0…179: a = i·π / 90 (2° steps); sr_sin[i] = trunc(sin a · 1024); sr_cos[i] = trunc(cos a · 1024)
    # the 1024-scaled tables of UnitVector::Rotation (Z09 §28.11); one "shine radian" = 2°
CalculateBroadcastDistance::CalculateBroadcastDistance(c)   @ FUN_0043c910   (global broadcastdistance, initializer FUN_00695240)
    cbd_DistSquar[0] = 1600² (0x271000); cbd_MinDist starts 0 (static storage)
    for i = 1 while i − cbd_MinDist < 500:
        d = trunc(√(75 000 000 / i))
        d > 1600: cbd_MinDist = i                     # the first 29 values exceed 1600: cbd_MinDist ends at 29
        else: cbd_DistSquar[i − cbd_MinDist] = d²
    # result: cbd_MinDist = 29, cbd_DistSquar[k] = trunc(√(75e6 / (k + 29)))² for k = 1…499 (k = 1: 1581², k = 499: 376²),
    # [0] = 1600². cbd_DistanceSquar (Z02 §5.2) uses it as: n = AxialListCount around o within 500 (§10.3, players only);
    # n < 29 → the map's Sight² (−1 for wide sight / a moving camera); else cbd_DistSquar[min(n − 29, 499)]: the sight
    # area shrinks as 75 000 000 / n
VectorClass::UnitVector::UnitVector(u, x, y)            @ FUN_00579ad0   the (x, y) overload of Z09 §28.11's FUN_0054b430:
    length = ddt_Distance(x, y); 0 → (1, 0); (x, y) ← (x·32 / len, y·32 / len); length ← ddt_Distance
    # used by the FanFormSectorArgument ctor FUN_0057bda0 (Z18 §3.5) and the ffsa initializer FUN_00698ec0
FanFormSectorArgument::~FanFormSectorArgument FUN_005792e0: resets ffsa_chardirect's vftable (unwind of sbe_BlastObject)
Navigator::NaviPoint::NaviPoint FUN_005c87d0: np_RealX = np_RealY = 0, np_IsDeleted = false (vector fill of the mob path,
    Z09 §9.5); Navigator::PathFindBuffer::~PathFindBuffer FUN_00439790 = `delete first member`, the fold also used by
    ~TreasureChestLocationManager, ~ShinePlayer, ~BoothManager and other unwinds
SlantedCoordList::ObjectYCoordNode::ocn_type FUN_00587d20 → 'Y' (0x59) (X node FUN_00587cf0 → 'X'): slot 0 of the
    coordinate nodes; cn_AppendList / cn_MakeLink / cn_MakeLink2 compare the two nodes' types and assert when a node is
    linked into the other axis' list (Z09 §9.6)
```

### 10.7 Library and diagnostic classes

| Function | Address | What it does | Callers |
|---|---|---|---|
| `CMD5Checksum::GetMD5(data, len)` | FUN_0063adf0 | standard MD5 (RFC 1321 initial state 0x67452301 …, `Transform` FUN_0063a450 with the RFC constants, `Update` FUN_0063ab30, `Final` FUN_0063abe0 = padding, length, 32 lower-case hex digits via `"0%x"` / `"%x"`) into a `std::string` | `CDataReader::Read` FUN_0062a780: `m_sFileMD5` of every SHN file, then `CShnDataFileCheckSum::InitDataFileCheckSum` (S01 knowledge; the WM form W05 §3.4) |
| `~CMD5Checksum` / scalar dtor | FUN_0063a410 / FUN_0063a420 | vftable reset (+ free) | `GetMD5`'s unwind / vt 0 only |
| `String::String()` / `String(char*)` | FUN_00653740 / FUN_006537d0 | own string class `{vptr, chData, stringLength, allocSize}`: 48-byte zeroed buffer / assign | `ZoneServer::ParseCmd` FUN_005aab10, `zs_start`, `WinService` (Z10 §1.1) |
| `String::operator=(char*)` / `(String&)` | FUN_006536a0 / FUN_00653800 | grows `allocSize` in 48-byte steps (old buffer freed, new one zeroed), copies, recounts the length | same |
| `String::makeUpper`, `~String`, scalar dtor | FUN_00653690 (`_mbsupr`), FUN_00653670, FUN_00653790 | | `ParseCmd` (command-line verbs are compared upper-case), `WinService` |
| `WinService` scalar dtor | FUN_00653360 | vftable, `~String(serviceName)`, free | vt 0 |
| `cWell512Random::cWell512Random` / `well512_InitState(seed[16])` | FUN_0063c990 / FUN_0063c9d0 | zero index, z0-z2 and the 16 state words / index and z cleared, state = seed | `RandomBox::RandomBox` FUN_0063cdb0: seed = 16 × `rand()` after `srand(_time32())` (Z23 §8.6) |
| `type_info::~type_info`, scalar dtor, `operator==`, `_Type_info_dtor` | FUN_0065628a, FUN_0065629a, FUN_006562bb, FUN_006634f6 | MSVC run-time (RTTI name list under lock 0xe, `strcmp` of the decorated names) | CRT only *(inferred: library code)* |
| `FunctionProfiler::PerformanceRecorder::PerformanceRecorder` | FUN_00468460 | `pr_Array` = empty `std::map` (head node 0x38), `QueryPerformanceFrequency` (0 → 1), `pr_CheckLoopCount_Command = pr_CheckLoopCount_Real = −1` | initializer of `_PerformanceRecorder` (report: Z11 §4.5) |
| `FunctionEntarance::~FunctionEntarance` | FUN_004028d0 | `fca_stackpoint −= 1`; `pr_Exit(fe_FunctionCode)`: the exit half of Z18 §1.6's ctor | 616 scope exits |
| `DebugLogging::operator<<(char*)` / `(int)` / `(DebugLineFeed&)` | FUN_00419210 / FUN_0043be30 / FUN_00419290 | when `dl_ActivAll` and the log's `dl_Activ`: `"%.255s"` / `"%d"` to the log file (`dl_FilePoint` opens it); the line feed writes `'\n'`, flushes and closes the file | 129 / 78 / 127 log lines (`TooLongPacket`, `InvalidSessionCutLog`, …) |
| `NameString::operator[](Name5*)` | FUN_00401140 | next `namestring` ring buffer, 20-byte name + NUL (the Name5 twin of Z18 §1.7) | log lines of `sp_NC_MAP_LOGIN_REQ`, `sp_NC_MAP_LOGINCOMPLETE_CMD`, GT, `&` commands (28) |
| `Name5::operator!=` | FUN_0044a8f0 | 5-dword compare, 0 only when all equal | guild / academy storage `lid_Call`s FUN_00472140 … FUN_004752d0 (Z14 §3, §4.1) |
| `StringMaker::Maker::operator<<(ItemInventoryCell*)` | FUN_0058def0 | `<< (int) item id` (Z18 §1.6 forms) | `so_SendInform2Admin` FUN_0058e310 (Z11 §5.7) |
| `TickTimer::TickTimer(delay)` | FUN_00591fa0 | `m_DelayTime = delay`, `m_CurDelayTime = 0`, disabled, `m_PrevCheckTime = now` | `GuildGroup::SetTournamentType` FUN_0047db00 (Z16 §5.3) |
| `HTTPString::~HTTPString` | FUN_006136a0 | MSVC `std::string` destructor (free when capacity > 15, reset to empty): the fold every `std::string` local uses | 91 (Pine `sa_Step`s and others) |
| `GppPacketSaver::~GppPacketSaver` | FUN_0061dc40 | copies the saved 0x2000 bytes back into the global send buffer `gpp`; the (inlined) ctor saved them, so a nested send cannot clobber a packet being built | unwinds of the slot machine (`SMS_StopButton`, `so_ply_IBurstJackPot`, `so_ply_SlotMachineDBResult`; Z32) |
| `Parameter::Container::~Container` | FUN_004c99e0 | frees the `cbcp_pValue` arrays of the seven `ChangeByConditionParam`s (Z12 §1.1) | `~ShineMobileObject` FUN_005554c0, ctor unwind |
| `Parameter::ChangeByConditionParam::cbcp_GetValue_Index(i)` | FUN_004c9010 | `i < cbcp_nMaxValueNum` → `cbcp_pValue[i]`, else 0 | the four `roe_HitRate` FUN_005011f0 / FUN_005020b0 / FUN_00502d30 / FUN_00503360 (Z03 §4.3) |
| `ZoneServer::<zs_serverinfo>` dtor | FUN_005aa6e0 | `CCsl::Close`, `~CToken` of the `ServerInfo` reader (S02 §2) | `~ZoneServer` / ctor unwinds |
| `BlockDistribute::BlockingDistribute::~BlockingDistribute` | FUN_00438a90 | clears `bd_Act` of its four `bd_Brench` children | unwinds of `bdl_New`, `bdm_Find` (Z09 §9.2 `BlockDistribute` quadtree) |
| `cShineLogSystem::SLS_SetLogName(name)` | FUN_00648500 | a non-empty name shorter than 256 chars is copied into `SLS_sLogName`; null, empty or longer → `"ShineLog"` | dynamic initializers of `gSocket_IOCP_Write` FUN_0069bf60 and `gZoneLinktoErrorLog` FUN_0069bfc0 (the two `SLS_AddLog` daily logs, W05 §5.7: socket write failures, `CSocket_IOCP::Send` / `WriteCallback`; zone link errors, `sp_NC_MAP_LOGIN_REQ`, `wms_NC_CHAR_REGISTNUMBER_ACK`, …) |
| `ListIter_AmpCmdLevel::~ListIter_AmpCmdLevel` | FUN_00419dd0 | profiler scope, vftable reset | `AmpCmdInit` unwind (Z11 §1.4) |

### 10.8 The remaining destructors

Every function below only resets the vftable to its base (and frees when the scalar flag is set); none has logic.

| Group | Functions |
|---|---|
| `AxialListIterator` base | ctor FUN_00427f00, dtor FUN_00428480 (151 callers: every visitor's dtor) |
| visitors → `AxialListIterator` | `AxialListNearScan` FUN_004c19e0, `…NearScanEnemyorAll` FUN_00401bc0, `…TargetChange` FUN_00434ca0, `…MobFind` FUN_00452a20, `…MobDistribute` FUN_004567d0, `…NumberCount` FUN_00461dd0, `…FlagCaptureCancel` FUN_00478da0, `IsAnybody` FUN_00484670, `…AggroAdjust` FUN_004a3100, `…NearFriend` FUN_004abd60, `…NPCTargetFind` FUN_004abd70, `…BriefExchangerAtMove` FUN_004bdca0, `…BriefDeleteAtMove` FUN_004bdcb0, `…ObjectList` FUN_004e2de0, `…MobVanish` FUN_004e7d00, `…LinkToByObserver` FUN_004e7d10, `…PlayerStateSet` FUN_004e7d20, `…Teleport` FUN_004e7d30, `…TeleportAnywhere` FUN_004e7d40, `…Count2` FUN_004e7d70, `…TeleportSplit` FUN_004e7dc0, `…FindItemOwner` FUN_004eb9d0, `…BriefDeleteAllOfRange` FUN_0054aaa0, `…DeathAura` FUN_0055e120, `…MobIndexVanish` FUN_005d6ca0 |
| visitors → `AxialListNearScan` | `…NearScanParty` FUN_00401870, `…NearScanGuildAcademy` FUN_00401910, `…NearScanFriend` FUN_004020b0, `…NearScanCenterFriendCasterEnemy` FUN_00402130, `…MagicFieldDamage` FUN_005668d0, `…MagicFieldHeal` FUN_005668e0, `…MagicFieldAggro` FUN_00579470, `…NearExecution_Enemy` FUN_005cf8f0 |
| visitors with members | `AxialListPacketBroadcast` FUN_00428d00 (287 callers; its profiler line writes `fca_stack[fca_stackpoint]` without the `++`, so the entry stays behind as a stale name for the hang dump, Z10 §6.4) (original bug) Z31-B24; `AxialListCameraMove` FUN_004412a0 (frees `alcm_PlayerList`, a `std::vector`); `AxialListKQResult` FUN_004e5320 (destroys the 128 entries of `alkqr_Array`, 0x34 each) |
| `ListEraser<T>` / `ListSearchSame<T>` | `ShineObject` FUN_0046df30, `HitMeList::Enemy` FUN_004816a0, `ShineObjectEachList` FUN_005538f0, `HuntLog::MobHuntElement` (`ListSearchSame`) FUN_004b6c10 (`l_MakeList` / search unwinds; template Z09 §28.11) |
| `ShineObjectEachList::~ShineObjectEachList` | FUN_0054f6f0: frees the `List<ShineObject>` array (unwinds of `~ShineObjectManager`) |
| scalar deleting dtors, vt 0 only | `Observer` FUN_0043f670 (`tick_` fold + `~IObserver`), `CallBackEvent` FUN_00444940 (+ dtor FUN_00444930, Z12 §7.3), `RoutionInterface` FUN_00478d20 (+ dtor FUN_00478d10, the GT base, Z16 §4.1), `ShineObjectManager` FUN_005541f0 (→ `~ShineObjectManager` FUN_0054f8b0), `SpyNet::IntelligenceOffice` FUN_0058a6a0 (Z09 §28.2), `IObjectTypeValidator` FUN_005cec00 (Z17 §1.4) |


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
| Z31-B8 | `AttackRhythm_Range::arb_Next` FUN_00427d50 §6.3 | `ca_point = (ca_point + 1) & 2`: from 0 the point stays 0 | every archer-line swing broadcasts animation 0 in 0x2447 | alternate the animations (`& 1` or `% 2`) *(inferred)* |
| Z31-B9 | `EngSklAtt::esa_masicaldamage` FUN_004fc630 §6.4 | advances the random box of `MaxMA − MinMA` but returns only `ena_physicdamage` (1): `MinMA` and the spread are never added | none in 2016 (`EngSklAtt` has no caller) | `MinMA + spread + slot 0xc`, as the physical twin |
| Z31-B10 | `LevelGap_Player_to_Player::GetLevelCapRate` FUN_005c81c0 §7.3 | reads the cell at `DefLv[def]` = column `TargetLv(def+1)`; `def < 150` sends a level-150 defender to the default | PvP level-gap rates shifted one target level; level-150 defenders always 1000 ‰; none in 2016 (every cell 1000) | `DefLv[def − 1]` with `def <= 150` *(inferred: the file's header row labels column N as level N)* |
| Z31-B11 | `ItemOptionsData::OptionCardStack::ocs_make` FUN_0064c8a0 §8.1 | draws every option value with `ocs_selectnumber(ocs_Number)`, the degree's IOT_NUMBER (count) row | the `Rate` / `Interval` columns of the type rows 1-11 of `ItemOptions.shn` are never used; reward items get option values 1-2 (degree 1) or 1-4 (degree 2), never the Interval-10 values of TH / TB / AC / WC / MA / MR | `ocs_selectnumber(row)` with the card's own row *(inferred)* |
| Z31-B12 | `iod_Load` FUN_0064cbc0 / `ocs_make` §8.1 | `OptionDegree` indexes the 500 stacks unchecked; the "Option not found" test compares the zero-extended u16 with −1 (dead); the option count is not capped at the 8 `optionlist` slots | none in 2016 (degrees 1-2, at most 4 options; card indexes are always valid rows) | bound `OptionDegree` < 500, compare with 0xFFFF, cap the count at 8 |
| Z31-B13 | `OptionCardStack::ocs_selectnumber` FUN_0064c4f0 §8.1 | picks index i with `r <= Rate[i]` for r in 0…999 | index 0 is 1 ‰ more likely and the last non-zero rate 1 ‰ less likely than the table says | `r < Rate[i]` |
| Z31-B14 | `BmpDataInfo::bdi_LoadBmpFile` FUN_004390f0 §8.6 | accepts 1-bit bitmaps but reads pixels only for 8-bit ones | a 1-bit area bitmap would give a skill area of uninitialised heap bytes and a random `AreaSize`; latent (all 52 `BMP.shn` files are 8-bit) | refuse 1-bit files or decode them |
| Z31-B15 | `ItemLotAnalyser::LotAnalyser::la_Store` FUN_0048a170 §8.7 | a new `LotChanger` gets only `delta`; `item` is never written | every inventory change applied through the lock list (the only caller of vt 0x7f8) is reported to the quest item hooks as item 0 (`so_ply_ItemLotChange(0, delta)`), so the quest item counters are not updated when items enter or leave the bag *(effect on quest completion not traced)*; the same item stored twice takes two entries | `e.item = id` when the entry is allocated |
| Z31-B16 | `NPCRole_Portal::nrb_BriefInformSet` FUN_004c2360 / `nrb_SaveLinkData` FUN_004c23f0 §9.1 | stores every LinkTable row whose argument matches into `nrb_pSaveLinkInfo[5]` without a bound; `nrb_SaveLinkData(i)` accepts `i == nrb_LinkNum` | a gate with six or more rows would overwrite the heap after the role object; the getter reads one slot past the last row; latent (2016: at most 4 rows per argument, callers loop below the count) | stop at 5 rows; test `i >= nrb_LinkNum` |
| Z31-B17 | `NPCRole_Merchant::nrb_ItemBuyPrice` / `nrb_ItemBuyFame` / `nrb_ItemBuyGBCoin` §9.1, `CSellItemManager::simg_Delete` §9.5 | the "item not found" / "free fail" asserts carry the text of `nrb_ItemSellPrice` / `simg_Insert` | misleading log lines | each function's own name |
| Z31-B18 | `CParty::Init` FUN_00645a80 §9.7 | `malloc` (not cleared) for the 4000 party slots; only a few fields are zeroed, then slot 0 is copied into `p_def` | looting, dice flags and the uncleared member fields start as heap contents, also in the default slot returned for invalid party numbers; latent (a fresh 0xCB200-byte block is zero pages) | `calloc` or clear every field |
| Z31-B19 | `simg_FillBuffer_Server` FUN_0050e4d0 / `simg_Initialize` FUN_0050e1b0 §9.5 | the map-change record has room for `nSellItemKey` (counted in `nDataSize`) but the key is never written nor read | after a map change every buy-back entry carries a stale key (−1 or an older entry's); the repurchase log rows (D03 §2) get it | copy `nSellItemKey` both ways |
| Z31-B20 | `RandomSlot::rs_Init` FUN_0063cd20 §9.8 | clamps values ≥ n to 0 after the shuffle | dead check (`(i·n) >> 14 < n` always) | drop it |
| Z31-B21 | `ZoneBaseSessionManager::EmptyToActive` FUN_005a6b60 §10.1 | a null node is logged and still counted (`m_NumSessions += 1`) | latent: the only caller `ActiveSession` passes a node; a null would make the pool look fuller than it is | return without counting |
| Z31-B22 | `PacketContainer::pcb_Flush_Try_Catch` FUN_004c8800 §10.2 | with no session (`pc_Session` null) it reports success and keeps the buffer | latent *(inferred)*: packets queued while unbound would go out to the next session bound by `so_SetSocketSession` (vt 0 sets only the pointer) | clear the buffer |
| Z31-B23 | `OPToolSession::opts_DummyFunction` FUN_004c7fb0, `LinearStep::ls_Set` FUN_004cdd60 §10.1 / §10.5 | assert texts name the wrong function (`ZoneListenSession::opts_DummyFunction`, `LinearStep::ls_step`) | misleading logs only | the own names |
| Z31-B24 | `AxialListPacketBroadcast::~AxialListPacketBroadcast` FUN_00428d00 §10.8 | writes its name into `fca_stack[fca_stackpoint]` without incrementing the pointer | the name stays above the stack top until overwritten; the hang dump (Z10 §6.4 prints every non-null entry) can list it although the function has returned | push and pop like the other profiled functions |
| Z31-B25 | `ZoneConnectSession::ZoneConnectSession` FUN_005a6cd0 §10.1 | `m_Connected_Server_ID = 3`, the `GameLogSession` value | none found: nothing reads the field for the ring link | 6 (zone) |
## Not reconstructed / uncertain

- §9.2: `mcd_city` returns 0 both for Roumen (`Rou`) and for any map not in `ItemMerchantInfo.shn` (dungeons, Gamble houses, …),
  so merchants there use Roumen's "sold in this city" column. Whether the 2016 data places a city-dependent merchant on
  such a map was not checked.
- §9.6: the academy master buff sets the abstate without the `so_AbnormalState_BitSet` / `BroadcastSet` / `Inform` calls
  that the guild buff makes right after. Whether `so_AbnormalState_Set` informs the client itself when its 9th argument is 0
  (master) and not 1 (guild) was not traced (Z03 §6.2 documents the set path but not that argument, `how`). If it does not, a master sees the
  buff only on the next brief-info or login refresh *(inferred)*.
- §9.6: `ShineGuildAcademyGuildBuff::lid_Call` compares the guild list with the object pointer when `so_ply_isAcademyGuildMember`
  returns neither 0 nor 1. Its body (FUN_0055a540) was not re-read; if it returns a bool, that branch is unreachable.
- §9.6: `GuildStorageElement::operator=` / `GuildAcademyRewardStorageElement::operator=` are reached only through the lists'
  Push / Pop slots. No call of those slots on the two storage lists was found (the storage code allocates with `l_AllocZ`
  and searches with `ListSearchSame`), so the copies are probably unused *(inferred)*.

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

- §6.2: slot meanings of the class vftable follow the classes whose override has a unique body; the PDB's folded stubs
  carry up to four names. No call through class vt 0x4c (`cc_NormalHitDelay_AfterSkill`) was found (slot scan of the
  functions that read `+0xfbc` / vt 0x49c only).
- §6.3: `smo_ply_NextBashTime` scales `arb_NextBash(bashinterval)` (= interval / 100) by `× speed / 1000 × 10 / 1000`
  again, which gives 0 ticks for the 1 000-1 800 ms `AtkSpeed` values of `ItemInfo.shn` unless the speed field
  (`Parameter +0xa18`) is far above 1 000; the units of that field were not traced (Z03 §3.2 / Z17 own the cadence).
- §6.5: a mob whose selector is the base `MobTargetSelector` would send 0x244C with an unwritten `number`; which
  selector the six `BroadAtDead` mobs get was not checked. That the WM drops 0x244C rests on its handler table only.
- §6.6: whether the capsule period (`KeepTime_Hour`) is meant as "openable until" or "openable after" is read from the
  comparison; the client's reaction to 0x726 (no text in `client-error-codes.json`) was not checked.
- §6.7: `CharaterSkillList::~CharaterSkillList`'s export ends after the first `operator delete`; that it frees both
  vectors is the standard `std::vector` destructor pair *(inferred)*.
- §8.1: the zone-wide rotation of option types (one deck per degree, never reshuffled after start-up) is read from the
  card handling; whether the designers meant a per-item draw was not checked against the client or a capture.
- §8.6: the meaning of the cell values (0…100 = red / 2, 1 = inside the area) is taken from the loader and the `AreaSize`
  test only; the skill code that reads `AreaBMP` is Z20 / Z25.
- §8.7: Z31-B15's effect assumes no quest counts item 0. vt 0x7f8 has no caller besides the two `icl_Apply_N_Free`
  forms, so the lot list is the only feed of `QuestPlayer_TakeItem` / `DestroyItem` (Z15 §4.5); whether the quest end
  check re-counts the inventory (`GetQuestPlayerItemLot`), so that item quests still complete, was not traced (Z15).

- §10.3: `AxialListCount::ali_Work` tests the centre object's type, not the visited one, so `cbd_DistanceSquar` counts
  every object around a player (mobs and drop items included) and nothing around a mob, pet or door (always the map's
  sight). Whether "count players" was meant (the test on `o` would be the usual pattern) or the type test is a
  deliberate "only players get the crowd-scaled sight" was not decided; not tagged.
- §10.1: `ZoneConnectSession::zbs_Parsing` reads the packet's id and size and drops them. Whether the next zone ever sends
  anything but its keep-alive on the ring link (all ring traffic travels the other way, `zcs_Send` → the next zone's
  `ZoneListenSession`, Z01) was inferred from the parser having no table, not from a capture.
- §10.5: `CFindWay::Init`'s `DirTbl` / `XTbl` / `YTbl` are listed raw; their meaning was not decoded because nothing
  reaches `FindWay` (Z09 §28.7).

## Coverage boundary

Filled in by the sweep part; rows found so far:

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `0x74AC` / `0x74B4` request handlers, `0x74B0` / `0x74B8` WM answers | Z08 §8.1 / §8.2 (done) | documented there; §2.1 adds the commit half |
| `0x74B1` / `0x74B9` / `0x4021` / `0x4032` on the WM | W03, W05 (done) | the WM handlers are cited there (W03 rename / retype, W05 table rows) |
| `0x4022` on the Character server | D02 (done) | `usp_SpamBlock_setTime` documented in D02 |
| `uib_AfterCast` / item DB consumption | Z04 §6.3, Z05 (done) | common path, documented there |
| lock-list slots 0x10-0x30, 0x38, 0x48-0x54, 0x60, 0x68 and the releasers' `icr_Apply` | Z05 §1.2-§1.4, Z04 §1.4 (done) | documented there; §3.2 links them |
| `LinearStep::*`, `Tracer`, `PathFindTable`, `MinWeightSearching` (dead tracer pair with `CellStack`, §3.8) | this item §10.5 | documented there; `CFindWay` ctor / `Init` / `LenMapInit` / dtor too (Z09 §28.7 has `FindWay`) |
| `TreasureChestMaker::tcm_ItemMake` FUN_00595d00 (caller of attribute vt 0x10) | Z09 §10.10 (done) | documented there (treasure chests); §3.5.1 documents the callee side |
| item wire sizes per attribute class | D07 §1.3 (done) | same library on the Character server; §3.5 maps the zone addresses |
| `CSellItemManager` (the sell list itself) | this item §9.5 | insert / delete / initialise / server fill documented there (Z31-B19); §4.2 documents the two player-side senders and `simg_FillBuffer_Client` |
| `ShineMiniHouse::so_mh_*` dice game, `CGambleDiceTaiSaiObject` | Z06 §3 (done), Z32 | §4.6 documents only the player-side state accessors they call |
| `GuildTournamentSystem::CaptureFlag` FUN_0047eae0 (caller of `ShineDynamicCast<ShineNPC>`) | Z16 §4.5 (done) | documented there (flag capture); §5.2 documents the cast |
| `List<ShineObject>::l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` (callers of `ShineObject::operator=`) | Z09 §28.11 (done) | the `List<T>` template is documented there; §5.1 documents the copy, §10.4 the `MapCluster` copy of the same four |
| per-class overrides of the object slots (mob, NPC, bandit, servant, door, effect, drop item, flag, pet, mover, mini-house) | Z09 §5 / §11-§13, Z13 §1.8 / §6.2 / §8.1 (done) | §5 documents only the base-class bodies and links the overrides |
| auto-arrange sort and step scheduling (`so_ply_ArrangeInven` FUN_00563500) | this item, part 10 (§11, Z04 open point) | §4.9 documents the grade rank and the login init |
| the owners of the `BinaryDataBox<T>` instances (`mdb_Load`, `idb_Load`, `mvdb_Load`, `sma_Load`, … in the §7.1 table) | the item named in each row (Z09, Z13, Z27, Z06, …; done) or this item §8 / §9 | §7.1 documents only the box template, the readers' keys and the destructors |
| the gamble rules that read `g_BanTime`, `g_TaxRate`, `g_EventCode`, `g_GBReward` (`go_Init` FUN_00614f10, `go_PlayerAction` FUN_00615180, `go_Enter_Player` FUN_00620d00, `SMS_StopButton` FUN_00625340) | Z06 §4-§5 (done), Z32 | §7.2 documents the tables and the finders |
| the guild tournament, GTI, item action and action effect `ITableBase` tables (their `Load` / `DataProcess`) | Z16, Z11, Z17, Z21 (done) | §7.4 lists only their destructors and `GetTotal` |
| the users of the §8 tables: `rot_FillOption` (random options), `iac_DropItemMake` (sockets), `augdb_*` getters, `Item_Upgrade_Table_mode`, `GetMixItemIndex`, `CSingleDataMap::GetValue`, `GetIsBadName`, the area-skill readers of `AreaBMP` | Z18 §4.5, Z11 §9.3, Z04 §9.4, Z30 §9, W05 §3.3 / Z12 §3.1, Z07, Z20 §3.1 (done) | §8 documents only the loaders and their data structures |
| `so_ply_ItemLotChange` and the quest item hooks it calls | Z15 §4.5 (done) | §8.7 documents the list that feeds it (Z31-B15) |
| the loaders of `MapDataBox`, `KQItemDataBox`, `cStateItemDataBox`, `BRAccUpgradeDataBox`, `MapBlockInformationBox`, `FieldContainer::fc_Load` | Z09, Z16, Z24 / Z20, Z18, Z09 §9.2 (done) | §8.9 documents only their constructors and destructors |
