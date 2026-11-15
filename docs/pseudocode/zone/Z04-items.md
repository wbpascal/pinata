# Zone server: items, inventory, equipment, upgrades (Z04)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the
function it was reconstructed from (`@ FUN_xxxxxxxx`); view one with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Function names are the original profiler strings (Z01 names file) unless marked *(ours)*; Z04's additions are in
`tools/protocol-re/names/zone/Z04.json`. Opcode names: `docs/protocol/opcodes.json` (mostly *(pdb2017)*).
Packet layouts: [`../../protocol/annotations/Z04.json`](../../protocol/annotations/Z04.json).
Core facts (objects, send primitives, player modes, `g_Now` in tenths of a second, NPC roles, server menus) are in
[`Z01-core.md`](Z01-core.md), [`Z02-actions.md`](Z02-actions.md), [`Z03-combat.md`](Z03-combat.md) and
`docs/knowledge/Z01.md`–`Z03.md`; this file does not repeat them.

**Scope split.** This file covers the client requests (dept 12 ITEM, dept 20 SOULSTONE). Nearly every request ends
by locking inventory cells and sending an `NC_ITEMDB_*` request to the Character server (GameDB session); the
answer (`0x34xx` ACKs), the commit of the locked cells and the final client packets (`0x3001` CELLCHANGE,
`0x3002` EQUIPCHANGE, the `…_ACK` success codes) are **Z05**. Here, "→ DB `0x34xx`" marks that hand-off.

The **result codes** come from `so_SendErrorCode(dept, cmd, code)` (`vt 0x308`); the decompiler drops its stack
arguments in many places, so they were read from the disassembly (push order before `call [vt+0x308]`).
Error texts are what the 2016 client handler shows for the code (client function given per packet).

---

## 1. Data model

### 1.1 Cell address (`ITEM_INVEN`)

`u16 inven = type << 10 | slot` *(pdb2017 `union ITEM_INVEN { Pos:10, Type:6 }`, confirmed: every handler splits
with `>> 10` / `& 0x3ff`)*. Inventory types seen in the zone code (box object in parentheses):

| Type | `type<<10` | Box | Evidence |
|---|---|---|---|
| 0 | 0x0000 | guild-academy reward storage (`DAT_0d026fd8` manager, needs academy membership `p+0x17d02 ≠ -1`) | RELOC/SPLIT |
| 2 | 0x0800 | reward inventory `p+0x28760` (REWARDINVENOPEN clears it and loads a page with box type 2), owner = charNo; not reachable by SPLIT | RELOC, 0x302C |
| 3, 13, 14, 16 | 0x0c00 … | mini-house boxes, via `p.vt[0x50](type, &box)` (FUN_00570a40; result `0x1181` = OK, `0x1184` not in a house, `0x1187`/`0x1188` not the owner) *(inferred: furniture / accessory / tile / mini-game, matching the 2017 client `Inventory` arrays)* | DROP, RELOC |
| 4 | 0x1000 | guild storage (`DAT_0d426078` `GuildStorage`, needs a guild `p+0x17d00 ≠ -1`, owner = guild number, `vt 0x5f0` = storage right) | RELOC/SPLIT |
| 6 | 0x1800 | account storage `p+0x18258` (only while open: `p+0x5cb8 & 0x30`) | RELOC/SPLIT, DEPOSIT |
| 8 | 0x2000 | equipment `p+0x7fd8` (slot = `ItemEquipEnum`) | EQUIP |
| 9 | 0x2400 | main inventory `p+0x8e2c` | everywhere |
| 15 | 0x3c00 | small-item box `p+0xf758` (`sp_SmallItemReloc`) | RELOC |
| 5, 12 | | rejected ("Invalid Item from box") | RELOC |

`ItemEquipEnum` *(pdb2017, the 2016 code uses the same numbers)*: 1 hat, 5 face tattoo, 6 necklace, 7 body, 8 body acc,
9 back, **10 left hand, 11 left-hand acc (costume), 12 right hand, 13 right-hand acc**, 14 bracelet, 15/16 rings,
17 costume effect, 18 tail, 19 leg, 20 leg acc, 21 shoes, 22 shoes acc, 23 earring, 24 mouth, **25 minimon**, 26 eye,
27 hat acc, **28 minimon (right)**, **29 shield acc**.

### 1.2 Item cell and item

```pseudo
ItemCell  (box.vt[0](slot) returns it)
    +0x00 u64  item key ("SHINE_ITEM_REGISTNUMBER"), +0x08 u16 itemID (0xFFFF = empty), +0x0a attribute bytes
    +0x70 ItemAttributeClass*  (per item class; null for empty cells)
box.vt[4](p+0x2a5a0) = usable size (depends on the player's extra-inventory pages), box.vt[8]() = full size

ItemAttributeClass (FUN_0063e2a0(&g_ItemAttrCls DAT_150ba478, itemID) → the class object for that item)
    vt 0x14 init attribute for a new item       vt 0x18 IsLot (stackable)     vt 0x1c GetLot(attr)
    vt 0x20 SetLot(attr, n)                      vt 0x28 ItemClassEnum          vt 0x44 attr pointer (chests)
    vt 0xa4 "already bound" flag                vt 0xa8 SetBound(cell, 1)
```

One class per `ItemClassEnum` (RTTI `ItemAttrCls_*`, 38 classes). Enum *(pdb2017)*: 0 byte lot, 1 word lot, 2 dword lot,
3 quest, 4 amulet, 5 weapon, 6 armor, 7 shield, 8 boot, 9 furniture, 10 decoration, 11 skill scroll, 12 recall scroll,
**13 bind item**, 14 up source, **15 item chest**, 16 weapon-title licence, 17 KQ, 18 house skin, 19 up red, 20 up blue,
21 KQ step, 22 feed, 23 riding, 24 amount, 25 up gold, 26 costume weapon, 27 action item, 28 GB coin, **29 capsule**,
30/31 closed/open card, 32 money, 33 no effect, 34 enchant, 35 active skill, **36 pup (minimon)**, 37 costume shield, 38 bracelet.

`g_ItemData` (DAT_14d4fb90) `FUN_00419020(&g_ItemData, id)` → `{ ItemInfo row, ItemInfoServer row, … , [9] ItemMoney row }`.
`ItemInfo` offsets in 2016 match the 2017 PDB struct: `0x62 Type`, `0x66 Class`, `0x6a MaxLot`, `0x6e Equip`,
`0x7a TwoHand`, `0x7f DemandLv`, `0xcf UseClass`, `0xd3 BuyPrice`, `0xdb BuyDemandLv`, `0xe8 WeaponType`, `0x112 BT_Inx`.

### 1.3 Belong types (`BelongTypeInfo.shn`, `g_BelongType` DAT_150ba8b8)

Row *(pdb2017 `BelongTypeInfo`, offsets confirmed by the accessors)*: `+0 BT_Inx, +4 PutOnBelonged, +5 NoDrop, +6 NoSell,
+7 NoStorage, +8 NoTrade, +9 NoDelete`. `ItemInfo.BT_Inx` selects the row (FUN_00648830; 11 when the item is unknown).
For `PutOnBelonged` rows the restrictions apply only once the item is bound (`attr.vt[0xa4]`); before that row 0 (BT_COMMON) is used.

| Function *(ours)* | Test |
|---|---|
| `BelongType_CanDrop` FUN_00632010 (via FUN_00648870) | NoDrop == 0 |
| `BelongType_CanDelete` FUN_00632060 | NoDelete == 0 |
| `BelongType_CanTrade` FUN_00632090 | NoTrade == 0 |
| `BelongType_CanSell` FUN_006320e0 | NoSell == 0 |
| `BelongType_CanStore` FUN_00632110 | NoStorage == 0 (+ more) |
| `BelongType_CanMove(cell, fromType, toType)` FUN_00648910 → FUN_00632280 | box-to-box rule (RELOC/SPLIT) |
| FUN_00632230 | row has PutOnBelonged (EQUIP binds the item) |

### 1.4 Inventory locking and DB requests

Pattern used by every item-changing request (Z03 knowledge §2 described it; details here):

```pseudo
L = p.vt[0x7d4]()                       # InventoryLocking (p+0xfaa8); L+4 (= p+0xfaac) = next lock index
L.vt[0x10]() → true while any lock is open   → most handlers refuse (one item operation at a time)
L.vt[0x0c](type, slot) → cell is locked;  L.vt[0x08](&inven) same with an ITEM_INVEN
lock = L.index
L.vt[0x2c](lock, type, slot)            # plain cell lock (drop/break confirmation)
L.vt[0x40](lock, cellA, cellB, &invA, &invB)   # move/exchange reservation (released into a CellChange on commit)
L.vt[0x30](lock, cell, &inv, &inv)      # clear reservation (item leaves)
L.vt[0x48](lock, moneyLo, moneyHi, -1)  # money reservation   L.vt[0x4c](lock, fame, -1)   L.vt[0x70](lock, coin, …)
L.vt[0x54](lock, equipSlot, cell)       # equip-location reservation
L.vt[0x50](lock, slot, cell, -1, 0)     # equip/unequip reservation
L.vt[0x28](lock)                        # release (cancel) a lock
L.vt[0x64](&reserved)                   # sum of open money/fame/coin reservations (subtracted before price checks)
L.index += 1
send GameDB (SessionPool_Pick(g_GameDBSessions)): NC_ITEMDB_* { ref(objHandle,charNo) … lock … }
```

`ref` in DB packets = `{ u16 objHandle (or the handler's own-handle argument), u32 charNo }`. Most DB requests also
carry the map name (`*(p+0x7a)`, 12 bytes) and position (`*(p+0x66)`, x/y) for the item log.
**New item keys** are made on the zone: `ItemKey_Make(&key, itemID, kind, zoneNo, worldNo)` FUN_00640710 *(ours)*
(kind 1 bought, 4 split; world/zone from `g_ServerInfo` own row).

### 1.5 Server-menu confirmations

Drop and destroy are confirmed with a server menu (Z02 §ServerMenuActor) built by `ItemMenu_Open` FUN_0048ced0 *(ours)*:
title from `ScrString` (`ItemDropWarn`, `ItemBreakWarn0`, `ItemBreakWarn1`), buttons `ButtonOK` / `ButtonCancel`,
range 1000. A copy of the request (0x68 bytes) travels with the menu. Cancel: release the lock and send
`0x3025 NC_ITEM_BREAKFAIL_CMD { u16 err = 0x1829 }`.

---

## 2. Shop: buy and sell

### 2.1 NC_ITEM_BUY_REQ `0x3003` (C→Z) @ FUN_00524a60

Payload *(pdb2017, confirmed)*: `{ u16 itemid, u32 lot }`. Reply on error: `0x3004 NC_ITEM_BUY_ACK { u16 code }`.

```pseudo
sp_NC_ITEM_BUY_REQ(p, pkt, len, hnd):
    if p.mode ∉ {1,2,6} (mask 0x46) or L.locked() or p.menuBits(+0x18248) & 0x0C:   ack 0x204
    npc = NPCRangeCheck_Check(p+0x17d84, p)                 # Z02: the clicked NPC, within range
    if npc == null:                                          ack 0x203
    info = g_ItemData[itemid]; if info == null: return       # silently
    if !info.ItemInfo or !info.ItemInfoServer or no open NPC role (p+0x17d80): ack 0x203
    if p.level < ItemInfo.BuyDemandLv:                       ack 0x211
    list = NPCItemList.nilt_MenuPacket(role.row)             # the shop's item list (NPCItemList tables)
                                                             # @ FUN_004c5050: nilt_Index2Handle[name] < 100 → nilt_Packet[i], else null
    if itemid not in list:                                   ack 0x203
    # alternative currencies (NPCRole_Merchant vtable)
    (needItem, n) = npc.nrb_ItemBuyItemMoney(p, itemid)     # vt 0x20, ItemMoney.shn
    if needItem != 0xFFFF:  p.so_ply_ItemBuyItemMoney(pkt.payload, needItem, n)    (vt 0xe18, §2.2); return
    if npc.nrb_ItemBuyGuildToken(p, itemid) (vt 0x1c) != 0:  p.so_ply_ItemBuyGuildToken(price, pkt.payload) (vt 0x838, §2.3); return
    price = npc.nrb_ItemBuyPrice(vt 0x10); fame = npc.nrb_ItemBuyFame(vt 0x14); coin = npc.nrb_ItemBuyCoin(vt 0x18)
    if price == fame == coin == 0: log "try to buy the item which cannot be solt"; ack 0x203
    if lot * price > p.money + reserved.money:               ack 0x203 ("Too expencive")
    if p.fame (vt 0x43c) + reserved.fame < lot * fame:       ack 0x20c
    if p.GBcoin (vt 0xb04) + reserved.coin < lot * coin:     ack 0x20e
    if class(itemid) == 13 BINDITEM and the inventory already holds a bind item:   ack 0x20d
    if not IsLot(itemid):
        ItemInventory_ii_BuyAll(inv, p, hnd, payload, lot*price, fame, coin)
    else:
        lot = min(lot, ItemInfo.MaxLot)
        for each inventory cell holding itemid (ItemBoxIterator over box 9):
            if cell.lot + lot <= MaxLot:  ItemInventory_ii_BuyLot(p, hnd, cell, cell.lot + lot, slot, …); return
        ItemInventory_ii_BuyAll(…)                           # new stack in an empty cell
```

```pseudo
ItemInventory_ii_BuyAll(inv, p, hnd, req, money64, fame, coin):      @ FUN_00523ce0
    cell = first empty cell of box 9 (ItemBoxIterEmpty; starts at p.vt[0x498]() when set)
    if none:  ack 0x20a (inventory full)
    attr = new attribute (class vt 0x14), key = ItemKey_Make(itemid, 1), attr.SetLot(req.lot)
    if class == 29 CAPSULE:      ShinePlayer_so_MakeCapsuleItem(…) → DB 0x34A0 NC_ITEMDB_BUYCAPSULE_REQ (Z05)
    elif sp_MagicContainerMake(…) handled it: nothing more
    else → DB 0x340A NC_ITEMDB_BUYALL_REQ {
        ref, +0x08 u32 charNo, +0x0c map[12], +0x18 x, y, +0x20 u16 inven (0x2400|slot), +0x22 u64 key,
        +0x2a u16 itemid, +0x2c u16 attrLen, +0x2e u16 lock, +0x30 u64 money, +0x38 u32 fame, +0x3c u32 coin,
        +0x40 u32 userNo, +0x44 u16 npc mob id (p+0x17d7e), +0x46 attribute (variable) }
    reserve money/fame/coin under the lock, reserve the new cell (vt 0x40), lock += 1
    p.so_ply_HolyPromiseCenUseTry(money) (vt 0x9c4)          # guild-academy "holy promise" spending hook (W/Z08)
    p.vt[0xb40]()
    p.vt[0x420](key, npc mob id) → FUN_005cc020             # quest/collection hook (inferred)

ItemInventory_ii_BuyLot(p, hnd, cell, newLot, slot, money64, fame, coin):   @ FUN_005241f0
    → DB 0x340D NC_ITEMDB_BUYLOT_REQ { ref, +0x08 lock, +0x0a u64 key, +0x12 attrLen, +0x14 inven, +0x16 itemid,
                                      +0x18 u64 money, +0x20 fame, +0x24 coin, +0x28 userNo, +0x2c npc mob id, +0x2e attr }
    same reservations and hooks as BuyAll
```

### 2.2 Buying with items ("item money") @ FUN_00526ac0 `so_ply_ItemBuyItemMoney`

```pseudo
    if FUN_00561760(p) (an exclusive state, inferred: trade/booth):   ack 0x210
    bought class 29 CAPSULE or 15 ITEMCHEST, bad args:                 ack 0x203
    BINDITEM already owned:                                            ack 0x20d
    need = ItemMoney row (g_ItemData[id][9]).+0x40 × lot  pieces of the payment item in box 9
    if the inventory holds fewer:                                      ack 0x20f  ("You cannot trade due to lack of coins.")
    stack onto an existing cell → ItemInventory_ii_ItemMoneyBuyLot (FUN_00526600, → DB 0x34B1 NC_ITEMDB_ITEMMONEY_BUYLOT_REQ),
    else ii_ItemMoneyBuyAll (FUN_005259a0, → DB 0x34B0 NC_ITEMDB_ITEMMONEY_BUYALL_REQ)
```

### 2.3 Buying with guild tokens @ FUN_00526ef0 `so_ply_ItemBuyGuildToken`

The item goes into **guild storage** (type 4), paid from the guild's token balance.

```pseudo
    no guild (p+0x17d00 == -1), storage of another guild:    ack 0x246 (code with dept/cmd 12/12 = RELOC_ACK) (original bug) Z04-B3
    no storage right (vt 0x5f0):                             return
    tokens (FUN_004749e0(storage)) + reserved < lot × price: ack 0x20b
    BINDITEM already in the guild storage:                   ack 0x20d
    stack or new cell → ItemInventory_igs_BuyLot (FUN_00524860, → DB 0x3493 NC_ITEMDB_GUILD_TOKEN_BUYLOT_REQ)
    / igs_BuyAll (FUN_005244e0, → DB 0x3490 NC_ITEMDB_GUILD_TOKEN_BUYALL_REQ; full storage → ack 0x20a)
```

Client `0x3004` (GameFrameWork::On_NC_ITEM_BUY_ACK FUN_004ab770): `0x201` "Item has been purchased." + sound;
`0x205/0x207/0x20b` "Not enough money to buy the item."; `0x20a` "Inventory is full."; `0x20c` "Not enough Fame to buy
the item."; `0x20d` "The is item already in possession."; `0x20f` "You cannot trade due to lack of coins.";
`0x211` "You cannot purchase this. Please check item purchase level."; other codes (0x203, 0x204, 0x20e, 0x210) are silent
(original bug) Z04-B6.
The `0x201` success is sent by Z05 after the DB answer.

### 2.4 NC_ITEM_SELL_REQ `0x3006` (C→Z) @ FUN_00539020

Payload *(pdb2017, confirmed)*: `{ u8 slot, u32 lot }` (slot in box 9). Reply `0x3005 NC_ITEM_SELL_ACK { u16 code }`.

```pseudo
    if mode ∉ {1,2,6} or L.locked() or menuBits & 0x0C:   ack 0x382
    if no open NPC role:                                     0x3004 ack 0x203   (BUY_ACK!) (original bug) Z04-B1
    if cell (9, slot) is locked:                             ack 0x382
    if slot >= box size:                                     ack 0x384 ("Wrong slot")
    cell = inv[slot]; info = g_ItemData[cell.id]; if info == null: return
    if no ItemInfo row:                                      ack 0x383
    if not BelongType_CanSell(cell):                         ack 0x38f
    if cell.lot > ItemInfo.MaxLot:                           ack 0x385
    if ItemGroupClassifier_igc_ChargedDuringUse(cell):       ack 0x38f  (a premium item whose effect is running)
    npc = NPCRangeCheck_Check(…); if null:                   ack 0x382 ("Item sell in unactiv menu")
    unit = npc.nrb_ItemSellPrice(p, id) (vt 0x0c); if 0:     ack 0x383 ("cannot be solt")
    if not IsLot or req.lot >= cell.lot:  ItemInventory_ii_SellAll(p, hnd, cell, &slot, cell.lot * unit)   (FUN_00538990)
    else:                                 ItemInventory_ii_SellLot(p, hnd, cell, &slot, req.lot * unit)    (FUN_00538cb0)
        # → DB 0x3422 NC_ITEMDB_SELLALL_REQ / 0x3425 NC_ITEMDB_SELLLOT_REQ; the sold item also enters the
        #   repurchase list (§2.5, Z05 sends 0x305C SELL_ITEM_INSERT_CMD)
```

Client `0x3005` (FUN_004ab870): `0x381` success (sound only); `0x38f`/`0x390` error-table text "Bound item cannot be sold.";
anything else "Failed to sell the item."

### 2.5 NC_ITEM_REPURCHASE_REQ `0x3059` (C→Z) @ FUN_00538580

Payload *(pdb2017, confirmed)*: `{ u16 nHaldle }` = handle of an entry in the player's **repurchase list**
`p+0x2ac38` (items sold to NPCs this session; `FUN_0050e440` finds an entry: `+0 u64 key, +8 ?, +0xc ?, +0x12 itemid, +0x14 attr`).
Reply `0x305A NC_ITEM_REPURCHASE_ACK { u16 nError }`.

```pseudo
    if mode ∉ {1,2,6} or L.locked() or menuBits & 0x0C:      ack 0x3669
    if not p.vt[0xe6c]() (repurchase allowed, inferred):       ack 0x3671
    no NPC in range / no open role:                            ack 0x3669
    entry missing, item unknown, no attribute class, lot 0:     ack 0x366a
    if p.level < ItemInfo.BuyDemandLv:  so_SendErrorCode(12, 4, 0x366b)   # sent as 0x3004 BUY_ACK (original bug) Z04-B2; the client's
                                                                         # 0x305A handler would show "Please check item purchase level."
    lot = min(entry.lot, MaxLot); price = ItemInfo.SellPrice × lot      # bought back at the sell price
    if p.money < price:                                         ack 0x366c
    stack onto a cell with room → ItemInventory_ii_RepurchaseLot (FUN_00538010) → DB 0x34BB NC_ITEMDB_REPURCHASE_LOT_REQ
    else                        → ItemInventory_ii_RepurchaseAll (FUN_00537ca0) → DB 0x34B9 NC_ITEMDB_REPURCHASE_ALL_REQ
                                  (full inventory → 0x366a / 0x3669 / 0x366d from inside)
```

Client `0x305A` (FUN_004b46a0): `0x366b` purchase level, `0x366c` "Not enough money to buy the item.", otherwise "Inventory is full.".
The list itself reaches the client as `0x305B` SELL_ITEM_LIST / `0x305C` INSERT / `0x305D` DELETE (sent from the DB answers, Z05).

---

## 3. Dropping, destroying, picking up

### 3.1 NC_ITEM_DROP_REQ `0x3007` (C→Z) @ FUN_00529f50

Payload *(pdb2017, confirmed)*: `{ ITEM_INVEN slot, u32 lot, SHINE_XY_TYPE loc }`. Reply `0x3008 NC_ITEM_DROP_ACK { u16 code }`.

```pseudo
    if mode ∉ {1,2,6}:                                        ack 0x302
    if no field or FieldList.CanItem (+0x9e) == 0:            ack 0x30e   ("You cannot throw away items in that area.")
    if menuBits & 0x0C:                                       so_SendErrorCode(12, 12, 0x242)  (as RELOC_ACK) (original bug) Z04-B3
    if L.locked() or cell locked:                             ack 0x302
    box by slot.type:
        8 (equipment): refused in KQ maps (FieldList.KQ +0x36 == 2 → 0x30e); box = p+0x7fd8
        9 (inventory): refused in KQ maps (0x30e); refused while casting (p+0x1d84 > g_Now → 0x302);
                       riding (mode 6) and the cell is the ride item or its feed (p+0x2a760 / +0x2a762):  ack 0x30f
        3, 13, 14, 16 (mini-house): only in KQ maps … (box via vt 0x50, must return 0x1181) else 0x30e
        other:                                                ack 0x303 ("Invalid inventory type")
    cell = box[slot]; empty or bad slot:                      ack 0x303
    if not BelongType_CanDrop(cell):
        if slot.type ∉ {9, 3, 13, 14, 16}:                    ack 0x30d   ("You cannot drop a bound item.")
        # undroppable items are destroyed instead, after two confirmations
        if ItemBreaker_ib_Break(p, cell, slot, &err): ack 0x301 else ack err      # §3.2
        return
    if cell.lot > req.lot:                                    ack 0x303   # only whole stacks can be dropped; makes DropLot below dead (original bug) Z04-B4
    if ItemDropper_id_Drop(p, cell, req, &err): ack 0x301 else ack err        # 0x13c1 when a menu is already open
```

```pseudo
ItemDropper_id_Drop(p, cell, req):                         @ FUN_0048dc90
    if p's ServerMenuActor is busy: err 0x13c1 ("Cannot execute order for the menu is opened."); fail
    L.vt[0x2c](lock, type, slot); lock += 1
    ItemMenu_Open(cancel = smfm_ItemDropCancel, "ItemDropWarn", ok = smfm_ItemDropWarn, p, copy of req + lock)
smfm_ItemDropWarn → FUN_0052b060:                          @ FUN_0048da60, FUN_0052b060
    release the menu lock (FUN_0048d0a0)
    if IsLot and cell.lot > req.lot: ItemInventory_ii_DropLot(…) → DB 0x3419 NC_ITEMDB_DROPLOT_REQ  (FUN_00529c20)
    else:                            ItemInventory_ii_DropAll(…) → DB 0x3416 NC_ITEMDB_DROPALL_REQ  (FUN_00529a70)
        # the drop object (ShineDropItem) is created on the DB answer (Z05: so_ItemDrop)
smfm_ItemDropCancel:                                       @ FUN_0048db00
    L.vt[0x28](lock); send 0x3025 NC_ITEM_BREAKFAIL_CMD { 0x1829 }
```

The OK `0x301` only means "confirmation menu opened"; the client (`FUN_004ab990`) sets a "drop answered" flag for any code
and shows texts for `0x30d`, `0x30e`, `0x387`/`0x38b` ("You do not have the right to pick up the item."), `0x13c1`.

### 3.2 Destroying an item (ItemBreaker)

```pseudo
ItemBreaker_ib_Break(p, cell, inven, &err):                @ FUN_0048de20
    err = 0x30d; if not BelongType_CanDelete(cell): fail
    if the server menu is busy: err = 0x13c1; fail
    lock the cell; ItemMenu_Open(smfm_ItemBreakCancel, "ItemBreakWarn0", smfm_ItemBreakWarn0, p, {inven, lock})
smfm_ItemBreakCancel:  unlock sma_ItemBreak.lockindex (vt 0x7d4 → +0x28); p.vt0x308(0xc, 0x25, 0x1829) (0x3025 with 0x1829)  @ FUN_0048d990
smfm_ItemBreakWarn0:  ItemMenu_Open(…, "ItemBreakWarn1", smfm_ItemBreakWarn1, …)   # second confirmation  @ FUN_0048dbd0
smfm_ItemBreakWarn1 (@ FUN_0048d8e0, only forwards) → ItemBreaker_ib_OK(p, {inven, lock}):  @ FUN_0048d0d0
    box = inventory (9) or mini-house box (3/13/14/16); cell = box[slot]; class = cell.class
    if class == 36 PUP (minimon) and p+0xaad8*4 in 1..8 (a minimon is summoned, inferred):
        release lock; send 0xD411 NC_PET_USE_ITEM_FAIL_ACK { 0x345c }; return
    release lock, reserve "clear cell" (L.vt[0x30]) under a new lock
    → DB 0x346A NC_ITEMDB_ITEMBREAK_REQ { ref, +8 u16 lock, +0xa u64 key, +0x12 charNo, +0x16 itemid, +0x18 u32 lot,
                                          +0x1a u8 n, n × { u16 itemid, u64 key } (10 bytes) }
        # n lists the contents of a chest (class 15, up to 8 entries from the chest attribute) and the item inside a
        # capsule (class 29, +1 entry), so the DB deletes them too
```

### 3.3 NC_ITEM_PICK_REQ `0x3009` (C→Z) @ FUN_00530a50

Payload *(pdb2017, confirmed)*: `{ u16 itemhandle }`. Replies go through `so_ply_itempickresult(code, handle)` (vt 0x6c0,
FUN_005308d0): `0x300A NC_ITEM_PICK_ACK { u16 itemid, u32 lot, u16 error, u16 itemhandle }`; for `error 0x341` (success)
itemid/lot are the picked item (`p+0x29278`, `p+0x2927c`) and the map script gets `sim_PickUpItem(handle, itemid)`;
otherwise itemid = 0xFFFF, lot = 0.

```pseudo
    if mode ∉ {1,2,6} or menuBits & 0x0C or L.locked():      result 0x342
    o = som_GetObject(itemhandle); null:                       result 0x34b (handle echoed)
    other layer / sub-layer ("another dimension"):             result 0x343
    o is not a drop item (type 1):                             result 0x343
    DistanceSquare(p, o) > 0x3d08 (125²):                      result 0x344 ("The item is too far away…")
    not o.so_drpitm_CanLooting(p) (vt 0x53c):                  result 0x345 ("You do not have the right to pick up the item.")
    item = o.vt[0x548](); null:                                result 0x343
    o.vt[0xaa8]() (a dice roll is running on it):              result 0x34c
    if in a raid (p.vt[0xa84]):  mode = raid loot rule for the item grade (FUN_00644f60 on the raid's rule set)
    elif in a party (p.vt[0x550] ≠ -1): mode = party loot rule (party table DAT_0da50bdc, +0xb8)
    else: p.so_ply_PickupItem(o, item, handle) (vt 0x798); return
    # rule (item grade ItemInfo.ItemGradeType +0x76 → 0…3; >3 logs "Undef item type"); o.vt[0xe24] = "free for all" flag → 0
    #  0: normal pickup (money item DAT_14d50488 goes to the distributor)
    #  1: party/raid distributor (sp_partyitemdistribute / sp_RaidItemsidtribute); raid sets p+0x29338 = g_Now
    #  2: money → distributor, items → normal pickup
    #  3: items → dice game (FUN_0052ec70; refused → result 0x2003 "You are not authorized to roll the dice."), money → distributor
```

```pseudo
ShinePlayer_so_ply_PickupItem(p, drop, item):              @ FUN_0052faf0
    if item.id == g_MoneyItemID (DAT_14d50488):  p.vt[0x790](amount (item+0x28)); drop.vt[0x54c]() (remove); FUN_0052f0e0(p); ok
    remember id/lot in p+0x29278 / p+0x2927c
    if ItemInfo missing:  result 0x343 and remove the drop
    if not ItemLotInspector check (FUN_0064bc90(DAT_13388848, id, owned + lot)):  result 0x34a   (max-owned limit)
    if ItemInfo.Type ≠ 3 (not a quest item): p+0x29334 = g_Now
    not IsLot  → ItemInventory_ii_PickAll(inv, p, drop, handle, item, 9)  → DB 0x341C NC_ITEMDB_PICKALL_REQ (FUN_0052f1b0)
    IsLot      → first stack with room: ItemInventory_ii_PickMerge(…) → DB 0x341F NC_ITEMDB_PICKMERGE_REQ (FUN_0052f440)
                 else PickAll into an empty cell
    FUN_0052f0e0(p)   # after-pick hook
```

Client `0x300A` (On_NC_ITEM_PICK_ACK FUN_004aba00): `0x341` "[%s] has been obtained." / "[%s (%d)] has been obtained.";
`0x344` too far; `0x345` no right; `0x34d` "You cannot acquire other items while rolling the dice."; dice codes
`0x2001…0x2009`; `0x342` silent; the generic fallback is "Failed to obtain the item."; inventory full "Inventory is full."
(the code that selects it is `0x34a`/`0x346`, reached through nested branches the decompiler merged *(inferred)*).

---

## 4. Moving items

### 4.1 NC_ITEM_RELOC_REQ `0x300B` (C→Z) @ FUN_00537170 → FUN_00536780 `ItemReloc_Do` *(ours)*

Payload *(pdb2017, confirmed)*: `{ ITEM_INVEN from, ITEM_INVEN to }`. Reply `0x300C NC_ITEM_RELOC_ACK { u16 code }`.

```pseudo
    if mode ∉ {1,2,4,6} (mask 0x56) or L.locked() or a split is pending (p+0x1ea8):   ack 0x242
    if from or to is locked:                                   ack 0x242
    if from == to:                                             ack 0x241   (nothing to do; 0x241 is the success code)
    ItemReloc_Do(p, hnd, &from):
        fromBox by from.type (table §1.1). Errors: academy storage without membership 0x24d / not allowed 0x24e /
            no right 0x24f; guild storage of another guild 0x24e, no right 0x24f; account storage closed 0x246;
            mini-house box not available → the vt 0x50 code; types 5, 12, unknown → 0x243
        toBox likewise; to.type 4 (guild storage) is refused (0x246) — items enter guild storage only by guild-token purchase
            or by the guild storage window; to.slot ≥ usable size → 0x244
        a = fromBox[from.slot], b = toBox[to.slot]
        a non-empty and not BelongType_CanMove(a, from.type, to.type):  refused
        b non-empty and cannot move the other way: allowed only if both are the same stackable item (merge)
        moving a bound item into storage:                      ack 0x24a ("you cannot transfer an item that has been bound to yourself.")
        then by the cell contents:
            b empty                         → ItemRelocationManager_irm_Move       (FUN_00531860)
            same lot item, a+b ≤ MaxLot     → irm_Merge                             (FUN_005324b0)
            same lot item, a+b > MaxLot     → irm_Split_N_Merge(…, MaxLot − b)      (FUN_00532a20)
            otherwise                       → irm_Exchange                          (FUN_00531e90)
        # each locks both cells and sends the matching NC_ITEMDB_* move request (Z05); box owner ids (charNo,
        # userNo for account storage, guild number) travel with it
```

Client `0x300C` (FUN_004ab910): `0x241` success; `0x24a` "you cannot transfer an item that has been bound to yourself.";
`0x242…0x249`, `0x24c` and others "Failed to move the item.".

### 4.2 NC_ITEM_SPLIT_REQ `0x300D` (C→Z) @ FUN_00539a40

Payload *(pdb2017, confirmed)*: `{ ITEM_INVEN from, ITEM_INVEN to, u32 lot }`. Reply `0x300E NC_ITEM_SPLIT_ACK { u16 code }`.

```pseudo
    if mode ∉ {1,2,4,6} or L.locked() or a split pending:      ack 0x442
    either cell locked, or from == to:                          ack 0x442/0x443
    boxes: types 0 (academy), 4 (guild storage, from only), 6 (account storage), 9 (inventory); errors as RELOC
        (0x24d/0x24e/0x24f/0x246 with dept/cmd 12/14); type 5 / others → 0x44c
    from.slot ≥ size ("Invalid 'from' cell") / to.slot ≥ usable size ("Invalid 'to' cell"):  0x445 / 0x446
    unknown item:                                               0x448
    to cell not empty:                                          0x44c
    not BelongType_CanMove:                                     ack (12, 12, 0x24a)   # RELOC_ACK, not SPLIT_ACK (original bug) Z04-B3
    n = req.lot; if n == 0 or n >= from.lot: ack 0x442
    # remember the pending split (p+0x1ea8 = 1, slot record p+0x1eac + p+0x5cac*0xf8: item copy, from, to, lot)
    newKey = ItemKey_Make(itemid, 4)
    → DB 0x3434 NC_ITEMDB_SPLIT_REQ { ref, +8 u32 fromOwner, +0xc u32 toOwner, +0x10 u16 lock, +0x12 u16 itemid,
        +0x14 u64 fromKey, +0x1c charNo, +0x20 map[12], +0x2c x, y, +0x34 u16 to, +0x36 u64 newKey, +0x3e u16 itemid,
        +0x42 u32 lot (split amount), +0x44 u16 oldLot }                                  # 0x46 bytes with header
    reserve both cells (L.vt[0x40] twice); for guild-academy boxes (type 0) also L.vt[0x7c](… both items + lots …)
    lock += 1
```

Client `0x300E` (FUN_004a8360): only `0x447` has a text ("You can't store the premium item into storage.").

---

## 5. Equipment

### 5.1 NC_ITEM_EQUIP_REQ `0x300F` (C→Z) @ FUN_0052b8d0

Payload *(pdb2017, confirmed)*: `{ u8 slot }` (inventory slot). Reply `0x3011 NC_ITEM_EQUIP_ACK { u16 code }`
(the PDB has no struct of that name; 2016 sends the 2-byte code).

```pseudo
    if mode ∉ {1,2,6} or L.locked():                           ack 0x282
    slot ≥ box size, or unknown item:                          ack 0x283
    cell (9, slot) locked:                                     ack 0x282
    p.sp_castabort()                                           (vt 0xed4)
    no ItemInfo row:                                           ack 0x284
    class may not use it: UseClass table (FUN_00640e40(DAT_14d42140, ItemInfo.UseClass, (p+0x7fa6 >> 2) & 0x1f)):  ack 0x285
    reduce = attr option 0xd (FUN_0063ffe0(attr, item, 0xd)) (inferred: "required level −N" random option)
    if p.level < ItemInfo.DemandLv − reduce:                   ack 0x285
    equipSlot = EquipEnumChanger_eec_EquipLocation(ItemInfoServer, equipment)   # ItemServerEquipTypeInfo; 0 → 0x283
    bind = row has PutOnBelonged and the item is not yet bound
    if p+0x173cc (an equip change is already in flight):     ack 0x292
    equipment slot locked:                                     ack 0x282
    weapon skins (slots 10 left-hand / 29 shield acc): the right-hand weapon must not be two-handed
        (ItemInfo.TwoHand), and 29 needs 12 free or one-handed:                         ack 0x293 ("You have to remove Weapon Skin.")
    weapon 13 / 12 with TwoHand: the costume slots 10 / 29 must be empty:               ack 0x293
    weapon type (ItemInfo.WeaponType ∉ {0, 16}): the paired slots must hold the same WeaponType and TwoHand  → 0x293
    equipping a main weapon (11, 13, 29) while the matching costume slot (10, 12) is empty → p.smo_BashStop()
    conflicts = eec_ConflictWithNewEquip + eec_ConflictWithOldEquip     # equipment that must come off (two-hand vs shield, …)
    for each conflicting equipment slot: needs a free inventory cell (ItemBoxIterEmpty) → else ack 0x28e;
        reserve the move equipment → inventory (L.vt[0x54], 0x40, 0x30, 0x50)
    → DB 0x3410 NC_ITEMDB_EQUIP_REQ { ref, +8 u64 key, +0x10 u16 equip inven (0x2000|equipSlot), +0x12 u16 itemid,
        +0x14 u8 bind, +0x18 u64 key of the item now in the slot (−1 = none), +0x20 u16 inven (0x2400|slot),
        +0x22 u16 lock, +0x24 u8 n, n × { u64 key, u8 inventory slot } }               # 0x25 + 9n bytes
    if bind: attr.SetBound(cell, 1) (vt 0xa8) now
    reserve the exchange equipment ↔ inventory; lock += 1
    p+0x173cc = 1                                               # cleared when the DB answers (Z05)
    view slots (FUN_00643780 = "has hidden/view slots"): mark conflicting view slots dirty (FUN_006437e0)
    if the slot held an item: riding item (FUN_004a25e0 kind 1, mount) unequipped → FUN_005654d0(p, 0) dismount;
                              kind 2 → p.vt[0xe58]()
```

Client `0x3011` (FUN_004abd20): `0x281` success; `0x293` "You have to remove Weapon Skin."; others "The item cannot be equipped.".

### 5.2 NC_ITEM_RINGEQUIP_REQ `0x3010` (C→Z) @ FUN_0052c5b0

Payload *(pdb2017, confirmed)*: `{ u8 slot, u8 equip }`; the client chooses the ring finger. Reply `0x3011 { u16 code }`.

```pseudo
    if mode ∉ {1,2,6} or L.locked():                          ack 0x282
    slot ≥ box size:                                           ack 0x283 ("wrong slot")
    equip ∉ {15 LEFTRING, 16 RIGHTRING}:                       ack 0x283 ("wrong equip")
    equip change in flight (p+0x173cc):                        ack 0x292
    cell locked:                                               ack 0x282
    p.sp_castabort(); no ItemInfo row: 0x284; UseClass or level < DemandLv: 0x285    # no random-option reduction here
    bind as in EQUIP
    eec_EquipLocation(item) must be 15 or 16 (a ring), ItemInfo.Type must be 0 (EQU), equip slot locked → 0x282
    → DB 0x3410 NC_ITEMDB_EQUIP_REQ with equip inven = 0x2000 | req.equip, n = 0 (0x25 bytes); reservations; p+0x173cc = 1
```

### 5.3 NC_ITEM_MINIMON_EQUIP_REQ `0x3050` (C→Z) @ FUN_0052d020

Payload *(pdb2017, confirmed)*: `{ u8 nSlotNo, u8 nEquipSlot }`. Same as RINGEQUIP with `nEquipSlot ∈ {25 MINIMON, 28 MINIMON_R}`
(else 0x283), the extra check `FUN_00461a30(eec, ItemInfoServer, nEquipSlot)` (the item may go to that minimon slot) and
equip location 25/28. Reply `0x3011` codes 0x282/0x283/0x284/0x285/0x292 as above; sends `0x3410` with n = 0.

### 5.4 NC_ITEM_UNEQUIP_REQ `0x3012` (C→Z) @ FUN_0053a990

Payload *(pdb2017, confirmed)*: `{ u8 slotequip, u8 slotinven }`. Reply `0x3013 NC_ITEM_UNEQUIP_ACK { u16 code }`.

```pseudo
    if mode ∉ {1,2,6} or L.locked():                          ack 0x2c2
    slotequip ≥ equipment size, slotinven ≥ usable inventory size:   ack 0x2c2
    equipment cell slotequip locked, or equipment cell *slotinven* locked:  ack 0x2c2
        # 2016 tests the lock of (8, slotinven), not (9, slotinven): a copy-paste slip (original bug) Z04-B5
    p.sp_castabort()
    equipment cell empty, or the target inventory cell not empty:   ack 0x2c4
    if slotequip ∈ {10, 12} (left/right hand):
        ItemInventoryCell_iic_WeaponTitleSave(cell, p)       # saves the weapon's title/kill counter before it leaves
        if the costume pair (10 → 11, 12 → 13 and 29) still holds a weapon: p.smo_BashStop()
    → DB 0x3413 NC_ITEMDB_UNEQUIP_REQ { ref, +8 u64 key, +0x10 u16 inven (0x2400|slotinven), +0x12 u16 lock,
                                        +0x14 u16 equip inven (0x2000|slotequip) }          # 0x16 bytes
    reserve (L.vt[0x54], 0x30, 0x40, 0x50); lock += 1; mark view slots dirty
```

Client `0x3013` (FUN_004abd80): `0x2c1` success; anything else "Failed to unequip the item.".

---

## 6. Using items

### 6.1 NC_ITEM_USE_REQ `0x3015` (C→Z) @ FUN_005416b0

Payload *(pdb2017, confirmed)*: `{ u8 invenslot, u8 invenType }` (type 8 equipment or 9 inventory).
Every result goes through `so_ply_ItemUseResultPacket(code, invenType)` (vt 0x91c, FUN_0045e610):
`0x3016 NC_ITEM_USE_ACK { u16 error, u16 useditem (p+0x2a7c6, then reset to 0xFFFF), u8 invenType }`; `0x700` = success.

```pseudo
sp_NC_ITEM_USE_REQ(p, pkt):
    if mode ∉ {1,2,6}:                                   0x701 ("Cannot use the item due to an Abnormal State.")
    if no field or FieldList.CanItem (+0x9e) == 0:      0x710 ("cannot be used in this area")
    if p.IsInGambleGame(0) (vt 0xb24):                   0x701 (type 9)
    if L.locked():                                       0x701
    if menuBits & 0x08, or p.vt[0xae0]() or p.vt[0x9e4]() (other exclusive states):   0x701
    box = invenType 8 → equipment, 9 → inventory, else  0x702
    slot ≥ box size:                                     0x702
    if L.vt[4](type, slot, p+0x2a772) (cell locked for use):   0x70a
    cell = box[slot]; empty / unknown item:              0x703 ("Try to use empty cell")
    p+0x2a7c6 = itemid
    if p.level < ItemInfo.DemandLv:                      0x708
    lot < 1:                                             0x703;  lot > MaxLot: 0x702
    if FieldList.IsPKKQ (+0x67) and ItemInfoServer[+0xdb] == 0:   0x710   # only flagged items in PK kingdom quests
    run every Lua "use item" trigger registered for the player (FUN_00541470 → LuaFuncTrigger_TriggerUseItem_tui_PullTheTrigger(trigger, p, itemid))
    if invenType == 8:  ItemUse_Equipped(p, slot, cell, info)   @ FUN_005415d0 (ours)
        # equipped items with an ItemAction (vt 0x5d0 item-action container, FUN_005d1f20 with condition {8,1,10,0}):
        # result 0x700 if the action started, else 0x722
    else:               ItemUse_Inventory(p, slot, cell, info)  @ FUN_0053f5e0 (ours), below
```

```pseudo
ItemUse_Inventory(p, slot, cell, info):                    @ FUN_0053f5e0
    if ItemInfo.Type ≠ 1 (EXH, consumable):              0x704 ("The selected item is not usable.")
    if UseClass forbids p's class:                         0x709
    e = g_ItemUseTable[itemid] (DAT_132879e0, 16-byte entries {?, UseEffect actor, SkillEntry*}; index ≥ count → entry 0)
    code = e.actor.uib_CanUseItem(p, cell) (vt 4);  if code ≠ 0x700: result code
    if e.actor.uib_DirectUse(p, slot, cell) (vt 8): return     # immediate items answer themselves
    # cast items: the item's "use skill" (ItemInfo.ItemUseSkill → SkillEntry) gives the cast time
    if e.skill == null:                                    0x70d
    if (Fear flag +0x1e78 bit 2 and skill id ≠ 0x7213) or captivated (vt 0xf20):   0x701
    if skill on cooldown (CharaterSkillList_csl_CoolTimeCheck):   0x70d ("Cannot use the item yet.")
    if p.vt[0xea0]() (already casting):                    0x70e
    cast = p+0x1d84: endTime = g_Now + ActiveSkill.CastTime(+0xcb) / 100, skill id (+0x1d88), SkillEntry (+0x1d98),
           item info (+0x1da4), slot (+0x1da8), +0x1da0 = ActiveSkill +0xcf, +0x1da9 = 0
    # no reply now; when the cast completes the cast routine calls e.actor.uib_AfterCast(p, inventory, &info, slot) (vt 0xc)
    # (inferred from the cast fields; the call site is in the player tick, Z09)
```

### 6.2 NC_ITEM_USEABORT_CMD `0x3019` (C→Z) @ FUN_0053f960

No payload. `if mode ∈ {1,2,6}: p+0x1d84 (cast end time) = 0` — the pending item cast is dropped silently; nothing is consumed.

### 6.3 UseEffect actors

`UseEffect::*` classes (RTTI), 5 virtual slots: `+4 uib_CanUseItem → code (0x700 ok)`, `+8 uib_DirectUse → handled?`,
`+0xc uib_AfterCast`, `+0x10 uib_Effect` (run when the DB confirms the consumption). Base defaults: CanUse FUN_00596480
(0x700), DirectUse FUN_00514570 (false), Effect = no-op.

| Actor | CanUse | Direct | AfterCast | Effect |
|---|---|---|---|---|
| UseItemNormal / NoEffect | base | – | Normal | – |
| UseItemAmountHP / AmountSP / BossMobDetect / LicenseClear / StatClear / MysteryBolt / Chest / ActionItem | base* | **direct** (FUN_0059cae0, 00599a60, 00599b20, 00599880, 00599990, 005997c0, 00599710, 0059be50) | Normal or none | – |
| UseItemByTable / ChargedBuff / MemoryFeather / RecallScroll / SkillScroll | own (FUN_005981e0, 00598310, 00598ab0, 005980d0, 0059d1b0) | – | Normal | own (00599f10, 0059a000, 0059a320, 00599bf0, 00599d30) |
| UseItemRoar / SkillErase / WingStone / GuildReName / GuildReType / ItemPackage / JustReviveAtDead | base | – | Normal | own (0059a110, 0059a1c0, 0059a270, 0059a3d0, 0059a480, 0059a0c0, 00418b60) |
| UseItemRide / Pet / SilverWing | own (005988b0, 0059b2b0, 00598000) | direct (005995b0, 0059b660, 0059c260) | Normal / SilverWing (0053ff70) | – |
| UseItemMiniHouse / MiniHouseFurniture | base | direct (00599450 / 00599500) | Normal | – |
| UseItemGBCoin / Capsule / CardOpen | (0059aab0/0059bf00 coin), CardOpen own (006276f0) | direct | – | – |
| UseItemHorseFood / ByAbstate / Propose / ImmediateDivorce / SkillDummy2Real | own (00596500, 00596ad0, 00596660, 005967e0, 005965f0) | some | Normal | own |
| UseItemFurnitureEndureKit | base | – | `UseItemVariationProtocolBase` (0059a530) | (7 slots) |

`base*` = FUN_005965e0 (a variant of the base check). Each actor's details belong to the feature that owns it
(mounts/pets/mini-house Z07, quests Z08, skill scrolls Z03); the consumption path is common:

```pseudo
UseEffect::UseItemNormal::uib_AfterCast(actor, p, box, &info, slot):     @ FUN_00540080
    cell = box[slot]
    if cell.itemid ≠ info.ID: log "Item Changed"; result 0x702; return     # the item moved during the cast
    if cell.lot < 1: result 0x702 ("Zero lot")
    lot == 1 → DB 0x343F NC_ITEMDB_USEALL_REQ { ref, +8 u64 key, +0x10 u16 lock, +0x12 u16 itemid }            (0x14 bytes)
    lot > 1  → DB 0x343E NC_ITEMDB_USELOT_REQ { ref, +8 u64 key, +0x10 u16 itemid, +0x12 attrLen, +0x14 u16 lock,
                                               +0x16 attribute with lot − 1 }
    reserve: lot 1 → clear cell (L.vt[0x30]); else the reduced copy (L.vt[0x40])
    L.vt[0x58](lock, &copy, &inven, actor)     # InvenCellReleaser_ItemUse: on the DB success Z05 calls actor.uib_Effect(p, …)
    lock += 1
```

### 6.4 Megaphone (answers Z02 §9.2)

`NC_ACT_ROAR_REQ 0x204B` (Z02) stores the text in `g_RoarQueue` (DAT_008598c0, ring of 0x84-byte entries
`{ u16 objHandle, u8 len, char text[…] }`, `RoarQueue_Push` FUN_0053f900) and its index in `p+0x2a79c`, then starts the item
use; the megaphone item's actor is `UseItemRoar`, so the item is consumed by the normal AfterCast path above.

```pseudo
UseEffect::UseItemRoar::uib_Effect(p) = p.so_ply_RoarItemUseSuccess()   @ FUN_0059a110 → FUN_00540800 (vt 0x8e4)
    i = p+0x2a79c
    if i < 0x80 and g_RoarQueue[i].objHandle == p.handle:
        len = min(len, 0x7f); terminate the text
        AnnounceSystem_Roar(g_Announce DAT_13388678, p.name (vt 0x56c, 20 bytes), text)        @ FUN_005b91f0
            fmt = AnnounceData.shn row 11 Message ("%s:%s")      # only when the table has ≥ 12 rows
            CAnnounceSystem_Send_PROTO_NC_ANNOUNCE_Z2W_CMD(11, sprintf(fmt, name, text))       @ FUN_005b8d30
                → WM: 0x6401 NC_ANNOUNCE_Z2W_CMD { ANNOUNCE_MESSAGE (type 11, text) }   (WM re-broadcasts it to every
                  player of the world as 0x6402 NC_ANNOUNCE_W2C_CMD — WM side: W items)
        send p: so_SendErrorCode(8, 0x4c, 0x700) = 0x204C NC_ACT_ROAR_ACK { 0x700 }
    else:   # the queue entry was overwritten by later shouts (ring wrapped) or never set
        copy p.name into the debug ring DAT_0085dfb0 and write "Roar Null …" to the debug log; nothing is sent
        # the megaphone item is already consumed (original bug) Z04-B7
```

So the megaphone is a **world-wide** message relayed by the WM, not a zone broadcast; the text format is the
`AnnounceData` row, and the player only gets the ROAR_ACK after the DB confirmed the item consumption.

---

## 7. Storage

The NPC storage window is opened by the NPC menu (Z02 / Z06: `p+0x5cb8` bit 4 = storage open, set with the open-menu
bit 1 in `p+0x18248`); the account-storage item (premium "storage anywhere") sets bit 5. Both bits are tested together
(`p+0x5cb8 & 0x30`) by every storage handler. The account storage box is `p+0x18258`; its money is `p+0x18250` (u64).

### 7.1 NC_ITEM_DEPOSIT_REQ `0x301C` / NC_ITEM_WITHDRAW_REQ `0x301E` (C→Z) @ FUN_00533dc0 / FUN_005342b0

Payload *(pdb2017, confirmed)*: `{ u64 cen }`. Reply on error `so_SendErrorCode` with 12/29 (`0x301D`) / 12/31 (`0x301F`).

```pseudo
    if mode ∉ {1,2,6} or L.locked():                    err 0xf81
    if storage not open (p+0x5cb8 & 0x30 == 0):          err 0xf82
    deposit:  cen = min(cen, p.money);         withdraw:  cen = min(cen, storage money p+0x18250)
    if cen == 0:                                         err 0xf83 ("Not enough money to deposit." / "…to withdaw.")
    reserve money (L.vt[0x48](lock, cen, deposit ? -1 : +1))
    → DB 0x345F NC_ITEMDB_DEPOSIT_REQ / 0x3461 NC_ITEMDB_WITHDRAW_REQ
         { ref, +8 u16 lock, +0xa u32 userNo, +0xe u64 cen }                         # 0x16 bytes with header
    lock += 1
```

The PDB ACK is `{ u64 cen, u16 err }` and the client handlers (FUN_004ac170 / FUN_004ac1c0) read `err` at offset 8
(`0xf80` success, `0xf83` the text above). `so_SendErrorCode` sends only `{ u16 code }`, so for these error replies the
client reads past the payload *(inferred mismatch; the success ACK comes from Z05 with the full layout)* (original bug) Z04-B8.

### 7.2 NC_ITEM_OPENSTORAGEPAGE_REQ `0x3028` (C→Z) @ FUN_00536650

Payload *(pdb2017; the 2016 profiler string wrongly says DEPOSIT_REQ, C02)*: `{ u8 page }`.

```pseudo
    if mode ∉ {1,2,6}:                      so_SendErrorCode(12, 7, 0x802)   # sent as 0x3007 (cmd 7 = DROP_REQ's number) (original bug) Z04-B9
    if storage not open:                    so_SendErrorCode(12, 7, 0x803)   # (original bug) Z04-B9
    Storage_RequestPage(p, page, 0)                                          @ FUN_00535ce0 (ours; profiler string "DEPOSIT_REQ")
        if page ≥ 16: so_SendErrorCode(15, 7, 0x804) = 0x3C07 NC_MENU_OPENSTORAGE_FAIL_CMD
        → DB 0x3444 NC_ITEMDB_OPENSTORAGE_REQ { ref, +8 u8 page, +9 u32 userNo, +0xd u8 fromAccountStorageCmd }
```

### 7.3 NC_ITEM_ACCOUNT_STORAGE_OPEN_CMD `0x304C` / CLOSE_CMD `0x304D` (C→Z) @ FUN_0051c190 / FUN_0051c2b0

No payload. No mode check.

```pseudo
open:  if p.premium block (p+0x2a5a0).+0x24 == 0: return           # no account-storage right
       if already open (p+0x5cb8 bit 5): return
       Storage_RequestPage(p, 0..3, 1)                                # pages 0–3 from the DB
       reset the storage box (FUN_006446b0(p+0x18258)); set bit 5 (vt 0xd24 FUN_0054aa00)
close: clear bit 5 (vt 0xd28 FUN_0054aa10)
```

### 7.4 NC_ITEM_GUILD_STORAGE_WITHDRAW_REQ `0x3026` (C→Z) @ FUN_00537330

Payload *(pdb2017, confirmed)*: `{ u64 cen }` (money from the guild storage). Reply `0x3027 NC_ITEM_GUILD_STORAGE_WITHDRAW_ACK
{ u64 cen, u16 err }` (12 bytes); on the error paths only `err` (+8) is written, `cen` keeps whatever was left in `g_buf`
(original bug) Z04-B10.

```pseudo
    if mode ∉ {1,2,6} or L.locked():             err 0x1481
    storage = GuildStorage of p's guild (FUN_004751f0(DAT_0d426078, guildNo vt 0x818, …)); none:   err 0x1482 ("Storage is closed")
    no storage right (vt 0x5f0):                  err 0x1484 ("You have no authority")
    cen = min(cen, storage money FUN_004749b0); cen == 0:   err 0x1483 ("There is no money in the Storage")
    reserve money (+1); → DB 0x3474 NC_ITEMDB_GUILD_STORAGE_WITHDRAW_REQ { ref, +8 lock, +0xa u32 guildNo, +0xe u64 cen }
```

Client: GuildTask::Recv_NC_ITEM_GUILD_STORAGE_WITHDRAW_ACK (FUN_006b4f90), `0x1480` success.

### 7.5 Guild-academy reward storage money: NC_ITEM_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_REQ `0x302F` / DEPOSIT_REQ `0x3031` (C→Z) @ FUN_00470110 / FUN_00470490

Payload *(pdb2017, confirmed)*: `{ u64 cen }`. Replies `0x3030` / `0x3032 { u64 cen, u16 Error }` (12 bytes; on errors only
`Error` is written, `cen` is stale buffer content: (original bug) Z04-B10).

```pseudo
    if mode ∉ {1,2,6}:                 Error 0x17e2 / 0x19a2
    if L.locked():                     Error 0x17e1 / 0x19a1  ("One of the item is in locked status")
    guildNo = p.vt[0x858]() == 0 ? p.guildNo (vt 0x818) : p.academyGuildNo (vt 0x85c)     # academy member or master guild
    storage = GuildAcademyRewardStorage (FUN_0046f710(DAT_0d026fd8, guildNo, p.vt[0x83c]())); none:  0x17e3 / 0x19a3 ("Storage is closed")
    withdraw: no right (vt 0x874):     0x17e5 ("Only Guild Master may withdraw funds")
              cen = min(cen, storage money FUN_00470990); 0 → 0x17e4 ("Not enough money to withdaw.")
              (cen == 0 in the request: no reply at all) (original bug) Z04-B11
    deposit:  cen = min(cen, p.money); 0 → 0x19a4
    reserve money (withdraw +1, deposit −1) under the lock
    → DB 0x3485 NC_ITEMDB_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_REQ / 0x3487 …_DEPOSIT_REQ
         { ref, +8 u16 lock, +0xa u32 guildNo, +0xe u64 cen }; lock += 1 (FUN_0043c130)
```

Client: GuildAcademyTask (FUN_006f54c0): `0x17e0` success; `0x17e6` guild data not found, `0x17e7` "not registered in any guild",
`0x17e8` DB error come from the DB answer. `0x3032` is in C01's "ignored by this client build" list (no handler)
(original bug) Z04-B12.

---

## 8. Premium ("charged") and reward inventories

### 8.1 NC_ITEM_CHARGEDINVENOPEN_REQ `0x3020` (C→Z) @ FUN_004923c0

Payload *(pdb2017, confirmed)*: `{ u16 page }`. Mode mask 0x5E {1,2,3,4,6}.
Error: `so_SendErrorCode(12, 0x21, 0x1042)` (`0x3021` CHARGEDINVENOPEN_ACK).
`→ DB 0x3463 NC_ITEMDB_CHARGED_LIST_REQ { ref, +8 u32 userNo, +0xc u16 first = page*24, +0xe u16 last = page*24+23 }`
(24 premium purchases per page). The list returns in `0x3021 { u16 ErrorCode, u8 nPartMark, u16 NumOfChargedItem, … }` (Z05);
client `0x1041` → "fail to load item information".

### 8.2 NC_ITEM_CHARGED_WITHDRAW_REQ `0x3022` (C→Z) @ FUN_00492660

Payload *(pdb2017, confirmed)*: `{ u32 ItemOrderNo }` (a purchase in the item mall). Errors via `ChargedWithdraw_Fail(orderNo, code)`
FUN_00492110 *(ours)* = `0x3023 NC_ITEM_CHARGED_WITHDRAW_ACK { u32 ItemOrderNo, u16 err }` (8 bytes, "ItemMallError").

```pseudo
    if mode ∉ {1,2,3,4,6} or L.locked():     0x1042
    if no field:                              0x1046
    if the charged list was never loaded (p+0x2a5d0 == 0):   0x1043
    order = find in the loaded list p+0x2a5d4 (FUN_00632400) by ItemOrderNo → { u64 orderKey?, u32 goodsNo, … }
    goods = item-mall goods table (DAT_0d5745e8, 0x58-byte rows, FUN_00492020 by goodsNo) → { …, +4 u8 n, +0xc n × {u16 itemid, u32 lot} }
    order or goods missing:                   0x1044
    another withdraw pending (p+0x2a758 ≠ -1):   0x104b
    n ≥ 32:                                   0x1047
    need n empty inventory cells (ItemBoxIterEmpty); fewer:   0x1045
    for each goods item: unknown item → 0x104c; new key ItemKey_Make(itemid, 9); init attribute; SetLot(lot);
        class 24 AMOUNT: attr.vt[0x6c](MaxLot); attribute data > 7000 bytes in total → 0x1047; reserve the empty cell
    → DB 0x3465 NC_ITEMDB_CHARGED_WITHDRAW_REQ { ref, +8 u16 lock, +0xa u32 userNo, +0xe order (16 bytes),
        +0x1e u8 n, n × 0x26-byte log blocks { charNo, map[12], x, y, u16 inven }, then n × { u64 key, u16 itemid, …, attr } }
    lock += 1; p+0x2a758 = ItemOrderNo
```

### 8.3 NC_ITEM_REWARDINVENOPEN_REQ `0x302C` (C→Z) @ FUN_004fc060

Payload *(pdb2017, confirmed)*: `{ u16 page }`. Mode mask 0x56 {1,2,4,6}; otherwise `so_SendErrorCode(12, 0x2e, 0x1203)` =
`0x302E NC_ITEM_REWARDINVENOPENFAIL_ACK` ("Reward inventory cannot be accessed while you are resting or operating a private vendor.").

```pseudo
    clear the reward box (FUN_006446b0(p+0x28760))
    → Character 0x1099 NC_CHAR_GET_ITEMLIST_BY_TYPE_NUM_REQ { +2 u16 handle (FUN_00428390), +4 u32 charNo, +8 u8 box = 2,
        +9 u32 charNo, +0xd u8 1, +0xe u16 first = page*24, +0x10 u16 last = page*24+23 }
```

The answer fills inventory type 2 and the client gets `0x302D NC_ITEM_REWARDINVENOPEN_ACK { u8 itemcounter, PROTO_ITEMPACKET_INFORM[] }`.

### 8.4 NC_ITEM_MH_FURNITURE_ENDURE_KIT_USE_REQ `0x3033` (C→Z) @ FUN_00571340 → FUN_00571550

Payload *(pdb2017, confirmed)*: `{ u8 nInvenSlot, u16 nFurnitureHnd }`. Reply `0x3034 NC_ITEM_MH_FURNITURE_ENDURE_KIT_USE_ACK`;
the error replies of this handler are `pp_SetPacketLen(8)` = 6 payload bytes with the code at +4 (`{ ShineDateTime dEndEndureDate,
u16 Error }`, as the PDB; only `Error` is set). The other send site FUN_0059a990 (the DB answer path) sends 4 payload bytes (C02 §size table).

```pseudo
    if mode ∉ {1,2} or Fear (+0x1e78 bit 2) or captivated or menuBits & 0x0C or p.vt[0x9e4]():   0x1a71
    if not in a mini-house (vt 0x130):     0x1a76;  no field: 0x1a72;  L.locked(): 0x1a74
    MHFurnitureKit_Use(p, payload) (vt 0x13c, FUN_00571550 ours):
        house = som_GetObject(p.vt[0x138]()) must be owned by p (house.vt[0x80] == charNo)
        kit cell (9, slot) not locked for use; ItemInfo.ItemFunc (+0x176) == 2 (endure kit); lot ≥ 1
        kit row in the mini-house endure data (DAT_00aa4280: itemid → row; row.+0x24 == 0x1b, value +0x28 = added time)
        furniture cell = house.vt[0x54](nFurnitureHnd); furniture must have an end date (attr vt 0x8c)
        endure info of that furniture (MiniHouseEndure table DAT_0d76ac38 by ItemInfo +0x8f)
        new end date = attr.vt[0x90](copy, kit value, …)
        UseItemFurnitureEndureKit actor gets the furniture inven + new attribute, then
        UseEffect_UseItemVariationProtocolBase_uib_AfterCast(actor, p, inventory, kit info, slot)   # consumes the kit and updates the furniture
        any check failing: no reply (silent) (original bug) Z04-B13
        returns 0x1a70 (success, no packet now: the DB answer replies)
```

Client (FUN_004af590): `0x1a70` "Repair has been completed." and the furniture's end date is updated.

---

## 9. Upgrades (enhancement)

### 9.1 NC_ITEM_UPGRADE_REQ `0x3017` (C→Z) @ FUN_0053d220

Payload *(pdb2017, confirmed)*: `{ u8 equip, u8 raw, u8 raw_left, u8 raw_right, u32 gift_money, u8 raw_middle }` — all slots are
inventory (type 9) slots; `0xFF` = not used. `equip` is the item to enhance, `raw` the enhancement stone, `raw_left` / `raw_right`
protection stones, `raw_middle` an extra luck stone. Reply `0x3018 NC_ITEM_UPGRADE_ACK { u16 err }` (client:
`ItemUpgradeWin::UpGradeResult(code)`, FUN_0049a5d0; the codes have no entry in the generic error table).

```pseudo
sp_NC_ITEM_UPGRADE_REQ(p, pkt, len, hnd):
    if not p.vt[0x6ac](6) (another upgrade is running; vt 0x6b0(6) marks it):   0x8d7
    if mode ∉ {1,2,6}:              0x8d6;   L.locked(): 0x8d8;   FieldList.CanItem == 0: 0x8ce
    if no NPC in range (upgrades are done at an NPC):   0x8d9
    equip slot ≥ usable size or locked:                  0x8c8
    raw slot bad/locked, unknown, p.level < raw.DemandLv: 0x8c9;  raw lot < 1 or > raw.Class-max: 0x8cf
    p+0x29299 / +0x2929b / +0x2929d = item ids of left / right / middle stones (−1 none)
    left:  bad slot 0x8d2, lot bad 0x8d0;  right: 0x8d3 / 0x8d1;  middle: 0x8d4 / 0x8d1
    if p.money (+ reserved) < gift_money:   0x8cb
    r = Item_Upgrade_Table_mode(p, inventory, equip, raw, left, right, middle)     @ FUN_0053ca10, §9.4
    0 → 0x8c8 (not upgradable); 1 → 0x8ca (at the upgrade limit); 2, 8, 9, 10 → 0x8c9 (raw/left/right/middle not a valid source)
    copy = equip cell
    3 (+1):   Item_AdjUpgradeLevel(copy, +1), Item_AdjFailCount(copy, reset), stat info = FUN_005c5c60(UpgradeInfo, copy, &out, +1, lv)
    4 (+2):   same with +2
    5 (fail): level unchanged, fail count + 1
    6 (down): level − 1, fail count + 1, stat info −1
    7 (destroyed): result byte 'd' (100); the item is removed
    remember the outcome in p+0x2928d… (key, item id, old/new level, stat info) for the DB answer
    p.vt[0x6b0](6)
    → DB 0x3447 NC_ITEMDB_UPGRADE_REQ { ref, +8 u16 lock, +0xa u64 key, +0x12 u16 itemid, +0x14 i8 change (+1,+2,0,−1,100),
        +0x15 u8 destroyed, +0x16 u8 new level, +0x17 u8 fail-count flag, +0x18 u64 raw key, +0x20 u64 left key, +0x28 u64 right key,
        +0x30 u64 middle key, +0x38 u64 gift_money (hi = 0), +0x40 u16 raw id, +0x42 left id, +0x44 right id, +0x46 u8 raw lot,
        +0x47 u8 left lot, +0x48 u8 right lot, +0x49 middle id, +0x4b u8 middle lot, +0x4c u8 / +0x4d u16 / +0x4f u8 stat info }
    reservations: the equip cell is replaced by the copy (or cleared when destroyed); every stone loses one (cleared at lot 1);
                  money −gift_money; lock += 1
```

### 9.2 NC_ITEM_NEW_UPGRADE_REQ `0x306D` (C→Z) @ FUN_0053e360

Payload *(pdb2017, confirmed)*: `{ u8 equip, u8 raw }`. Reply `0x306E NC_ITEM_NEW_UPGRADE_ACK { u16 err }` (same client window).
Same checks and codes as 9.1 (0x8d6…0x8d9, 0x8ce, 0x8cf) with these differences: slot errors → 0x3806 (equip) / 0x3807 (raw);
**both items must have `ItemInfo.Grade` ≥ 6** (else 0x3807) and the same Grade (else 0x3801); no protection/luck stones, no gift money
(`Item_Upgrade_Table_mode(…, −1, −1, −1)`); outcome 0 → 0x3806, 1 → 0x3808, 2 → 0x3807; outcomes 3/5/6 as above (the grade-6 rule in
§9.4 makes "destroy" and "+2" impossible). → DB `0x34D1 NC_ITEMDB_NEW_UPGRADE_REQ`.

### 9.3 NC_ITEM_BRACELET_UPGRADE_REQ `0x306F` (C→Z) @ FUN_0053ec40

Payload *(pdb2017, confirmed)*: `{ u8 equip, u8 raw }`. Reply `0x3070 { u16 err }`. As 9.2 with codes 0x3c04 (equip / outcome 0),
0x3c02 (raw / outcome 2), 0x3c05 (limit); all outcomes 3…7 handled; → DB `0x34D3 NC_ITEMDB_BRACELET_UPGRADE_REQ`.

### 9.4 The roll @ FUN_0053ca10 `Item_Upgrade_Table_mode`

Tables: `ItemUpgrade.shn` (`g_ItemUpgrade` DAT_1328bb00; columns `ID, CriFail, DownFail, NormalFail, nCon, LuckySuc`, read at row
offsets +4, +6, +8, +10), `BRAccUpgrade.shn` (bracelets, DAT_1328bdb8), `UpgradeInfo.shn` (stat gain per level, DAT_1328bb40, used by
FUN_005c5c60). Item fields: `ItemInfo.Grade` (+0x83), `UpLimit` via `Item_GetUpgradeLimit`, `UpSucRatio` (+0xf3), `UpLuckRatio`
(+0xf5), `DemandLv` (+0x7f), `ItemGradeType` (+0x76). All rolls are `Random_Next(&g_Rng, 1000)` (0…999).

```pseudo
Item_Upgrade_Table_mode(p, inv, equip, raw, left, right, middle):
    item = inv[equip]; limit = Item_GetUpgradeLimit(item.id); 0 → return 0
    by attribute class: 4 amulet / 38 bracelet → lv = attr byte +0x12, fc = +0x14;  5/6/7/8 weapon/armor/shield/boot → lv = +0xa, fc = +0xc
                        other classes → return 0            # lv = upgrade level, fc = consecutive-failure counter (Item_AdjFailCount)
    if lv ≥ limit: return 1
    if not Item_IsUpSource(item, raw, lv) (FUN_0053c760): return 2
    left / right / middle given and not an up source (FUN_0053b3e0): return 8 / 9 / 10
    k = (left ? 13·fc : 0) + (right ? 12·fc : 0);  if k/10 ≠ 0: fc = k/10      # protection stones raise the failure-count weight
    row = ItemUpgrade[lv − 12 + Grade·12]  → D = CriFail (destroy), W = DownFail, K = NormalFail, F = nCon
        amulets: an override row FUN_0053c740 when present; bracelets: BRAccUpgrade row by (Grade, DemandLv, lv)
    luck = raw.UpSucRatio + middle.UpSucRatio;  base = 120;  dl = item.DemandLv
    bracelet: raw id = "BR_UPSORCE02" → D = 0;  "BR_UPSORCE03"/"04" → D = W = 0          (ids looked up by InxName)
    item.Grade > 5 and raw.Grade > 5: base = D = F = fc = dl = 0;  raw.ItemGradeType == 4 → also W = 0
    T = (D + W + K) − (F·fc − dl + base + luck)                 # failure threshold in ‰
    bracelet: T = max(K − luck, 0);   both grades > 5: T = K
    r = rand1000
    if r ≥ T:                                                    # success
        luckSum = raw.UpLuckRatio + left/right/middle UpLuckRatio
        if (bracelet or a grade < 6) and luckSum and rand1000 < luckSum and lv + 2 ≤ limit: return 4   (+2)
        return 3                                                                                            (+1)
    # failure: choose the kind, D and W renormalised to ‰ of D+W+K (W only when a grade < 6 and not a bracelet)
    r = rand1000
    if r < D':      left given and rand1000 < left.UpSucRatio → return 5 (kept) else return 7 (destroyed)
    if r < D' + W': right given and rand1000 < right.UpSucRatio → return 5; lv == 0 → return 5; else return 6 (level −1)
    return 5                                                     # plain failure, level kept
```

### 9.5 NC_ITEM_MOVER_UPGRADE_REQ `0x3051` (C→Z) @ FUN_0051c850

Payload *(pdb2017, confirmed)*: `{ u8 nMainSlotNo, u8 nSubSlotNo }` — two mount (mover) items of class 23 RIDING are merged.
Reply `0x3052 NC_ITEM_MOVER_UPGRADE_ACK` is always sent in its full 0x6C-byte form (zeroed, `nError` set) on errors:
`{ u16 nError, u8 bRare, u8 bUpgrade, u8 nSlot, u16 nItemID, SHINE_ITEM_ATTRIBUTE ItemAttr }` *(pdb2017, size agrees)*.

```pseudo
    if mode ∉ {1,2} or FUN_00561600(p) (busy state):           0x3229
    main == sub:                                                0x322d
    L.locked(), slot ≥ size or locked, menuBits & 0x0C, p.vt[0xae0]():   0x3229
    no empty inventory cell:                                    0x322b
    main is already a rare mover (FUN_004c0500(g_MoverUpgrade DAT_13388458, id)):  0x322e
    unknown items / no attribute / not both class 23 / not the same mover family:   0x322a
        # family check: MoverItem rows (DAT_13388f90, by InxName) or the riding-item list (DAT_00aa40d8) must give the same
        # base mover id (DAT_14d504d0) and no "+0x30"/"+0x82" exclusion flag
    g = main.grade (attr vt 0xc0), s = sub.grade, max = FUN_004c0450 (MoverUpgradeEffect max)
    if g ≥ max:   rare roll FUN_004c03b0(g_MoverUpgrade, main.vt[0xc8] value, s) (RareMoverRate / EachRate / SubRate tables)
                  success → new rare item id FUN_004c0490; failure: main.vt[0xc4](value + 1) (counter)
    else:         main.grade = min(g + s + 1, max) (attr vt 0xbc)
    no rare result → DB 0x34AC NC_ITEMDB_MOVER_UPGRADE_REQ { +2 lock, +4 charNo, +8 handle, +0xa u8 upgraded (g < max),
                     main key/inven/attribute, sub key/attribute … } (0xeb bytes)
    rare result   → new key ItemKey_Make(newId, 8), new attribute with the grade → DB 0x34AE NC_ITEMDB_MOVER_RAREMOVER_REQ
    reserve main (replace) and sub (clear); FUN_00561610(p, 1) marks the busy state
```

---

## 10. Enchanting (gem sockets)

Gem sockets live in the weapon's item cell *(offsets read from the code; meaning inferred)*: `cell+0x3a` up to 3 sockets of
`{ u16 gemID (0xFFFF = empty), u8 restCount }`, `cell+0x43` u8 socket count, `cell+0x44` u8 (incremented together with the count
when a socket is drilled). Only **weapons** (ItemInfo.Class 5) take gems; gems are class 34 ENCHANT items of the same Grade.

The three handlers are registered without a profiler string (`FUN_…`), and they have **no mode mask and no "any lock open"
check** — only the two cells involved must be unlocked (original bug) Z04-B14. Errors are sent by small helpers that also log the handler name
(`FUN_005221d0` / `FUN_00522300` / `FUN_00522430` *(ours: Enchant*_Fail)*): `ACK { u16 err, …rest from the request }` (9 bytes for ADD_GEM).

### 10.1 NC_ITEM_ENCHANT_ADD_GEM_REQ `0x3040` (C→Z) @ FUN_00522560

Payload *(pdb2017, confirmed)*: `{ ITEM_INVEN equipment, ITEM_INVEN gem }` (equipment in box 8 or 9, gem in box 9).
Reply `0x3041 NC_ITEM_ENCHANT_ADD_GEM_ACK { u16 err, ITEM_INVEN equipment, u16 GemID, u8 gemSocketIndex }`.

```pseudo
    either cell locked:                          0x2081
    a cell missing:                              0x2082
    equipment not a weapon (Class 5):            0x2083
    gem not Class 34 ENCHANT:                    0x2084
    gem.Grade ≠ weapon.Grade:                    0x2087
    the same gem is already in a socket:         0x2088
    no empty socket (or no sockets):             0x2085
    i = first empty socket; copy.socket[i] = { gemID, restCount = EnchantSocketRate(gem) (FUN_005c80a0) .+4, 0 → 0xFF }
    reserve copy, consume one gem (clear at lot 1); lock += 1
    → DB 0x3496 NC_ITEMDB_ENCHANT_ADD_GEM_REQ { ref, +8 lock, +0xa u64 weapon key, +0x12 u16 weapon id, +0x14 u16 equipment inven,
        +0x16 u64 gem key, +0x1e u16 gem id, +0x20 u16 gem inven, +0x22 u8 socket index, +0x23 u8 restCount }   (0x24 bytes)
```

Client (FUN_004b2d40): `0x2080` "Enchant Successed", other codes "An unknown error has occurred.".

### 10.2 NC_ITEM_ENCHANT_REMOVE_GEM_REQ `0x3042` (C→Z) @ FUN_00522990

Payload *(pdb2017, confirmed)*: `{ ITEM_INVEN equipment, ITEM_INVEN remover, u8 gemSocketIndex }`. Reply `0x3043 { u16 err, ITEM_INVEN
equipment, u8 gemSocketIndex }`. Codes: 0x2091 locked, 0x2092 missing, 0x2094 not a weapon, 0x2093 the remover is not the
configured gem-remover item (`g_GemRemoverItemID` DAT_14d504cc), 0x2095 that socket is empty. The socket becomes `{0xFFFF, 0}`,
one remover is consumed → DB `0x3498 NC_ITEMDB_ENCHANT_REMOVE_GEM_REQ` (same head as 10.1, then `+0x22 u8[3]` flags with 1 at the
removed index, `+0x25 u8 1`; 0x26 bytes). Client success code `0x2090`. The gem itself is destroyed, not returned.

### 10.3 NC_ITEM_ENCHANT_ADD_NEW_SOCKET_REQ `0x3044` (C→Z) @ FUN_00522cc0

Payload *(pdb2017; 2016 profiler string copy-pasted from REMOVE_GEM, C02)*: `{ ITEM_INVEN equipment, ITEM_INVEN drill }`.
Reply `0x3045 { u16 err, ITEM_INVEN equipment, u8 socketCount }`. Codes: 0x20a1 locked, 0x20a2 missing, 0x20a4 not a weapon,
0x20a3 not the drill item (`g_SocketDrillItemID` DAT_14d504ce), 0x20a5 the weapon already had a socket added (`cell+0x11` ≠ 0,
inferred meaning). Socket count +1 (and `+0x44` +1), one drill consumed → DB `0x349A NC_ITEMDB_ENCHANT_ADD_NEW_SOCKET_REQ` (0x22 bytes).
There is no cap check against 3 sockets in the zone handler (original bug) Z04-B15.

---

## 11. Random options

Items whose `ItemInfoServer` row (+0x89, the RandomOption key) has an entry in the RandomOption table (`g_RandomOption` DAT_0d6249d4,
`RandomOption.shn` / `RandomOptionCount.shn`) carry random stat options in their attribute (`attr.vt[0x70]` = option storage,
`vt[0x74]` = number of re-rolls already used (0xFF = not counted), `vt[0x78]` = set that number).

### 11.1 NC_ITEM_RANDOMOPTION_CHANGE_REQ `0x3053` (C→Z) @ FUN_00520e40

Payload *(pdb2017, confirmed)*: `{ u8 nItemSlotNo, u8 nStuffSlotNo }` (both inventory). Reply on error `0x3054
NC_ITEM_RANDOMOPTION_CHANGE_ACK { u16 nError, ItemOptionStorage changeAbleOption }` (0x1d bytes, options zero).

```pseudo
    if mode ∉ {1,2,6}:   no reply at all (original bug) Z04-B16
    L.locked(), slots out of range or locked, menuBits & 0x0C, p.vt[0xae0]():   0x3249
    item missing / no ItemInfo or ItemInfoServer / no attribute / no RandomOption entry / no option storage:   0x324a
    stuff item id ≠ g_OptionChangeItemID (DAT_14d504d2) or lot 0:                                           0x324a
    used = attr.vt[0x74](); limit = constant "LimitRandomOption" (named-value table DAT_1328c040, FUN_0062efc0)
    if used ≠ 0xFF and used ≥ limit:  0x324a
    the item copy gets newly rolled options (attr.vt[0x78] / reroll) and used + 1
    → DB 0x34C1 NC_ITEMDB_RANDOMOPTION_CHANGE_CONSUME_AND_COUNTING_REQ { +2 lock, +4 charNo, +8 handle, +0xa u64 stuff key,
        +0x12 u16 stuff id, +0x14 u32 stuff lot − 1, +0x18 item cell copy (key, id, attribute 0x66), +0x87 u8 item slot }   (0x88 bytes)
    consume one stuff item; lock += 1
```

The DB answer (Z05) sends the rolled options to the client (`changeAbleOption`) and keeps them pending in `p+0x2a959`
(a 0x6e-byte item-cell copy) with the slot in `p+0x2a958`. Client (FUN_004b45a0): `0x3248` "The stats cannot be changed right now.".

### 11.2 NC_ITEM_RANDOMOPTION_CHANGE_ACCEPT_REQ `0x3061` (C→Z) @ FUN_0051da80

No payload, **no mode check** (original bug) Z04-B16. Error: `so_SendErrorCode(12, 0x62, 0x324a)` (`0x3062` …ACCEPT_ACK).

```pseudo
    cell = inventory[p+0x2a958]; missing / no ItemInfo(Server) / no attribute:   0x324a
    if cell key ≠ pending copy key (p+0x2a959): 0x324a                           # the item changed since the roll
    swap: the pending copy takes the item's current options' slot, the item gets the pending options (6×4+2 bytes)
    reserve the cell = pending copy
    → DB 0x34B3 NC_ITEMDB_RANDOMOPTION_CHANGE_REQ { +2 lock, +4 charNo, +8 handle, +0xa u64 key, +0x12 u16 id,
        +0x14 new attribute (0x65), +0x79 old attribute (0x65) }   (0xde bytes)
```

### 11.3 NC_ITEM_RANDOMOPTION_RECOVER_COUNT_LIMIT_REQ `0x306B` (C→Z) @ FUN_0051dd40

Payload *(pdb2017, confirmed)*: `{ u8 nItemSlotNo, u8 nStuffUseLot }`. Reply `0x306C { u16 nError }`; client
(`RandomOptCountRecoverWin::ShowRecoverCountResult`, FUN_004a73d0): `0x3251` success.

```pseudo
    mode ∉ {1,2,6}, L.locked(), bad/locked slot, menuBits, p.vt[0xae0]():   0x3252  ("Current item cannot be recovered.")
    no RandomOption entry / options:                                          0x3253
    used = attr.vt[0x74](); used == 0xFF or used == 0 or used < nStuffUseLot:  0x3254
    copy.used = used − nStuffUseLot
    take nStuffUseLot pieces of g_OptionRecoverItemID (DAT_14d504d8) across inventory stacks (clear / reduce each)
        not enough pieces: release the lock, 0x3256;  item unknown: 0x3255   (client texts: "You are short in soul stone of armor…")
    → DB 0x34CD NC_ITEMDB_RANDOMOPTION_RECOVER_COUNT_LIMIT_REQ (item copy + consumed stacks)
```

---

## 12. Other item services

### 12.1 NC_ITEM_DISMANTLE_REQ `0x302A` (C→Z) @ FUN_005293c0

Payload *(pdb2017, confirmed)*: `{ u8 item }` (inventory slot). Reply `0x302B NC_ITEM_DISMANTLE_ACK { u16 err }`; texts from the
client error table (`0x1681`…`0x168c`).

```pseudo
    mode ∉ {1,2,6}:             0x1681 ("Unknown error.")
    L.locked() or cell locked:  0x1688 ("Dismantling is prohibited for this item.")
    FieldList.CanItem == 0:     0x1684 ("Cannot dismantle in current area.")
    no NPC in range:            0x1682 ("Too far from NPC.")
    bad slot / empty / no attribute / unknown:   0x1686 ("Incorrect item.")
    lv = upgrade level (amulet/bracelet attr +0x12, weapon/armor/shield/boot +0xa); other classes: 0x1689 ("cannot be dismantled")
    lot ≠ 1:                    0x1683
    ItemInfo.Class ∉ {4,5,6,7,8} or UpLimit (+0xf0) > 12:   0x1686
    lv > UpLimit:               0x1687 ("Upgrade info error.")
    row = ItemDismantle.shn[lv] (DAT_13295968); n = row column group by class (Armor +2, Boot +0x16, Shield +0x2a, Weapon +0x3e,
          Amulet +0x52; 5 u32 per group) [ItemInfo.Grade 1…5]; Grade 0 or > 5 → 0x1686; bracelets fall through the class switch → 0x1686
    n == 0:                     0x168a ("An item that will not produce Karis after dismantling.")
    ItemDismantleProducer(p, g_KarisItemID DAT_14d504c2, n, inventory, slot) (FUN_00528a90); check FUN_005290f0 ≠ 0x1680 → that code
        (e.g. 0x168c inventory full, 0x168b Karis not in ItemInfo)
    → DB 0x3476 NC_ITEMDB_DISMANTLE_REQ (built by ItemDismantleProducer_id_ProductExecute: the dismantled item + the Karis stacks)
```

### 12.2 NC_ITEM_WEAPONENDURE_CHARGE_REQ `0x3035` / NC_ITEM_SHIELDENDURE_CHARGE_REQ `0x3064` (C→Z) @ FUN_00519470 / FUN_00519a10

Costume weapons / shields have a charge counter (uses). Payload *(pdb2017, confirmed)*: `{ u8 ChargingSlot, ITEM_INVEN WeaponSlot }`
(resp. ShieldSlot). Reply `0x3036` / `0x3065 { u32 ChargedNumber, ITEM_INVEN slot, u16 Error }` (error replies: only `Error`, 8 bytes;
the 24-byte size C02 lists is the DB-answer send site). The two handlers are identical apart from the opcodes.

The "item usage" table `DAT_00aa4280` (FUN_0044fa10 by item id → row; row `+0x24` kind, `+0x28` value) drives both:
kind `0x1c` = chargeable costume item (value = max charges), kind `0x1b` = charge item (value = charges added; also the endure kit).

```pseudo
    mode ∉ {1,2}:                        0x1a81
    Fear (+0x1e78 bit 2):                0x1a82;   captivated (vt 0xf20): 0x1a8a
    L.locked():                          0x1a83;   menuBits & 0x0C: 0x1a84
    slot type ∉ {8, 9}:                  0x1a85
    target missing or not kind 0x1c or no attribute:   0x1a86
    cur = attr.vt[0x9c](cell); if cur ≥ max:   0x1a87          # already full
    charge item (9, ChargingSlot): ItemInfo.ItemFunc (+0x176) == 1, kind 0x1b, lot ≥ 1; else 0x1a88
    new = min(cur + add, max)
    → DB 0x348D NC_ITEMDB_WEAPONENDURE_CHARGE_REQ / 0x34C6 NC_ITEMDB_SHIELDENDURE_CHARGE_REQ
         { +2 u64 target key, +0xa u16 target inven, … charNo, charge item key/inven, +0x22 u16 lock, +0x24 u8 chargeItemGone, new value }
    consume one charge item; lock the target cell (L.vt[0x2c]); lock += 1
```

Client: ItemRepairTask (C01; FUN_0066cb20 / FUN_0066cc80) handles the ACKs and `0x3037` / `0x3066` *ENDURESET_CMD { u32 ChargedNumber }`.

### 12.3 NC_ITEM_REVIVEITEMUSE_CMD `0x3039` (C→Z) @ FUN_00417580

No payload, no mode mask (it is used while dead).

```pseudo
    if the field has a map and the revival bit is clear (field+0x20c & 1 == 0):
        so_SendErrorCode(18, 0x3a, 0x701)      # 0x483A — note: dept 18 SKILL, cmd 58; the PDB names cmd 58 of dept 12
                                                # NC_ITEM_REVIVEITEMUSEFAIL_CMD (0x303A), so 2016 sends it under the wrong dept
                                                # (original bug) Z04-B17
    id = the configured revive item (g_ItemData constant row FUN_00418fe0 → +0x40)
    unknown id:                                so_SendErrorCode(18, 0x2b, 0x71f)  = 0x482B NC_SKILL_REPLYREVIVEFAIL_CMD   # client ignores it (original bug) Z04-B17
    slot = sp_FindItemFromInventory(p, id); none:   0x482B { 0x71e }   # (original bug) Z04-B17
    UseEffect_UseItemNormal_uib_AfterCast(g_ReviveItemActor DAT_132878ec, p, inventory, info, slot)
        # consumes one; on the DB success the actor's uib_Effect revives the player (UseItemJustReviveAtDead → so_ReviveByItem, Z03/Z05)
```

### 12.4 NC_ITEM_DICE_GAME_START_REQ `0x303C` (C→Z) @ FUN_00517d70

Payload *(pdb2017; the 2016 string is copy-pasted from WEAPONENDURE, C02)*: `{ u16 itemhandle, u8 IsYes }`. No mode check.
`drop = som_GetObject(itemhandle)`; missing → error `0x2004`; else `drop.vt[0xaa4](p, IsYes == 1, &err)` (ShineDropItem FUN_00531690:
join or pass the party loot dice on that drop, §3.3 rule 3). Reply `0x303D NC_ITEM_DICE_GAME_START_ACK { u16 error }` with the code the
drop item set. The dice flow itself (`0x303B` DICE_GAME_CMD, `0x303E` START_CMD, `0x303F` RESULT_CMD) is run by the drop item (Z09/Z06).

### 12.5 NC_ITEM_AUTO_ARRANGE_INVEN_REQ `0x304A` (C→Z) @ FUN_0051c360

No payload. Reply `0x304B NC_ITEM_AUTO_ARRANGE_INVEN_ACK { u16 err }`, success `0x30a8` is sent **before** the work starts.

```pseudo
    mode ∉ {1,2,6}:                                  0x30aa
    mode 6 (riding) or a cell is locked (L.vt[0x18]):  0x30ab
    trading (p+0x17d5f) or a server menu open:       0x30aa
    open-menu bit 6 (p+0x18248 & 0x40):              0x30ac
    p.vt[0xd10]() (FUN_00560d90): less than 5 s (50 ticks) since the last arrange (p+0x2ab1c):   0x30a9
    FUN_00561600 / FUN_00561760 busy states:         0x30aa
    send 0x30a8; p+0x2ab18 = 0xC0 (vt 0xd18(1)); InvenArrange_Run(p) (vt 0xd1c, FUN_00563500)
        # builds a sort key per cell (item class, ItemSort group g_ItemData[7], ~DemandLv, …) and issues the moves as ordinary
        # relocation DB requests, a limited number per step (p+0x2ab18 / p+0x2ab18-counter, inferred)
```

### 12.6 NC_ITEM_EQUIP_BELONGED_CANCEL_USE_REQ `0x3048` (C→Z) @ FUN_0051b9a0

Payload *(pdb2017, confirmed)*: `{ u8 nCancelItemInvenSlot, u8 nBelongedItemInvenSlot }` — an "unbinding" item removes the bound
state of an item whose belong row has PutOnBelonged. Reply `0x3049 { u16 nError }` (`0x2880` success; client "Succesfully Unbound %s").

```pseudo
    mode ∉ {1,2}:                             0x2882
    Fear or captivated:                       0x2885/0x2886 (inferred from the code order)
    no field:                                 0x2883;   L.locked(): 0x2884;   menuBits & 0x0C: 0x2887
    bound item: cell missing 0x2888, unknown / no attribute 0x288a; its row has no PutOnBelonged → 0x288c (inferred), not bound (attr.vt[0xa4] == 0) → 0x288d
    cancel item: missing / unknown / lot < 1 → 0x288b; ItemInfo.ItemFunc (+0x176) ≠ 6 or Grade ≠ the bound item's Grade → 0x288e / 0x288f (inferred)
    → DB 0x34A6 NC_ITEMDB_EQUIP_BELONGED_CANCEL_USE_REQ { ref, +8 lock, bound item key/inven, cancel item key/inven/lot }
    consume one cancel item; the bound item copy with the bound flag cleared is reserved
```

### 12.7 NC_ITEM_USE_ACTIVESKILL_REQ `0x304E` (C→Z) @ FUN_00540b90

Payload *(pdb2017, confirmed)*: `{ u8 nInvenSlot, u16 nTargetHnd, SHINE_XY_TYPE TargetLoc }` — items that cast a skill (class 35).
Reply `0x304F NC_ITEM_USE_ACTIVESKILL_ACK { u16 nError }`; texts from the error table.

```pseudo
    mode check, exclusive states, smo_SkillBlastOption(p) == 2 (a blast is pending):   0x3129 ("Cannot use the item due to an Abnormal State.")
    no field / CanItem == 0, item not allowed here:   0x312b
    slot / item missing:                               0x312a;  level < DemandLv: 0x312c;  lot < 1: 0x312d;  lot > MaxLot: 0x312a
    the item's skill (ItemInfo.ItemUseSkill → SkillEntry) missing or inconsistent:   0x312e ("Incorrect Skill.")
    move state 3 (p+0x18c), cooldown (csl_CoolTimeCheck):                            0x3130 ("Cannot use the skill yet.")
    target handle 0xFFFF → ground target: TargetLoc must be reachable (so_FindBlockLocate, 10000) else 0x3131 ("Failed to Cast the Skill.")
    target out of skill range (+ body size, 60 units slack):                         0x3132 ("out of casting range")
    then the normal skill cast (Z03 §5) with the item as the cast source; the item is consumed when the cast fires (0x312f is a
    leftover Korean "???" text in the client table)
```

### 12.8 NC_ITEM_CHAT_COLOR_CHANGE_REQ `0x3055` (C→Z) @ FUN_0051e580

Payload *(pdb2017; 2016 profiler string "CHATC_OLOR", C02)*: `{ u8 nSlotNo }`. Reply `0x3056 { u16 nError, u8 nChangeColorID }`
(error default 0x3600 = success code; client FUN_0049da30: `0x3600` ok, `0x3601…0x3607` failure texts).

```pseudo
    mode ∉ {1,2,6}, gamble game, menuBits & 0x08, exclusive states, cell locked, L.locked():   0x3602
    no field / CanItem == 0 / PK kingdom quest map (+0x67 == 1):   0x3604
    slot bad / empty / lot 0:    0x3605;   no ItemInfo(Server), lot > MaxLot, no use-function entry:   0x3603
    level < DemandLv:            0x3606
    color = item usage row (DAT_00aa4280) value; g_ItemUseFunction (DAT_132878f0) entry must exist
    → DB 0x34B5 NC_ITEMDB_CHAT_COLOR_CHANGE_REQ (item consumed, new color id); the colour is saved with 0x4031
      NC_CHARSAVE_CHAT_COLOR_CMD by the DB-answer path (Z05/Z07)
```

### 12.9 NC_ITEM_TERMEXTEND_REQ `0x3057` (C→Z) @ FUN_0051eb40

Payload *(pdb2017, confirmed)*: `{ u8 nExtendItemSlot, u8 nTermItemSlot }` — extends the expiry of a time-limited item.
Reply `0x3058 { u16 nError }` (`0x3618` success, FUN_0049da90).

```pseudo
    mode / exclusive states:                0x361a (and when slots are out of range or locked)
    no field:                               0x361c;  CanItem == 0: 0x361a
    term item missing / empty:              0x361d;  extend item missing / unknown / lot bad: 0x361b
    level == DemandLv of the extend item … 0x361e (inferred: level requirement)
    extend item usage row (DAT_00aa4280) missing: 0x361f; row kind ≠ 0x25 or row +0x22 == 0: 0x3621
    TermExtendMatch table (DAT_13388858, FUN_0064bbc0) must pair the two items: else 0x3620
    → DB 0x34B7 NC_ITEMDB_TERMEXTEND_REQ (term item with the new end date, extend item consumed)
```

### 12.10 NC_ITEM_CLASS_CHANGE_REQ `0x305E` (C→Z) @ FUN_0051f5c0

Payload *(pdb2017, confirmed)*: `{ u8 nStuffSlotNo }` — switches the character to the sibling class of the same tier with a
class-change item (`g_ClassChangeItemID` DAT_14d504d4). Reply `0x305F NC_ITEM_CLASS_CHANGE_ACK { u16 nError }`.

```pseudo
    mode ∉ {1,2,6}, or a busy state (FUN_00517cc0):                     0x3681
    newClass = class table (DAT_14d42140) sibling of p.class (vt 0x4dc) (FUN_00640e80); none or 0x22:   0x3682 ("No Changable Class specialization found.")
    any equipment worn (FUN_00642e30(p+0x7fd8) > 0):                    0x3685 ("…Take them all of and try again.")
    stuff slot bad / locked / menu open / exclusive state:              0x3681
    stuff item missing or not the class-change item:                    0x3684
    the skills and passives of the old class are mapped to the new class (g_SkillData walk by class, passive list p+0x17d30)
    → DB 0x34BD NC_ITEMDB_CLASS_CHANGE_REQ (item consumed, new class, skill conversion list)
```

`0x3060 NC_ITEM_OPENCLASSCHANGEMENU_CMD { u8 nNewClass, u64 nTotalPrice, u16 nError }` (the menu offer) is sent from the NPC side, not here.

### 12.11 NC_ITEM_MAPLINK_SCROLL_REQ `0x3067` (C→Z) @ FUN_00520130

Payload *(pdb2017, confirmed)*: `{ WM_Link targetMap }` (first u16 = map id). Registered without a profiler string.
Reply `0x3068 NC_ITEM_MAPLINK_SCROLL_ACK { u16 nError, u8 lvFrom, u8 lvto }` via `MapLinkScroll_Ack(code, lvFrom, lvTo)` FUN_00517e40 *(ours)*.

```pseudo
    mode ∉ {1,2,6}:                         0x3751
    map id 0:                               0x374e;   unknown map (MapInfo FUN_0064eb20): 0x374c
    no field / link-out not allowed here:   0x3752
    the target map must be a link-scroll destination (FUN_0046a370 table DAT_0d026c30) and served by some zone (g_ServerGroup):  0x374f
    the target's level range (FUN_00462040): p.level outside → 0x374a with lvFrom/lvTo filled (inferred)
    a map-link scroll (g_MapLinkScrollID DAT_14d504d6) in the inventory; none: 0x374d
    menuBits & 0x0C / exclusive state:      0x3751
    scroll's use skill on cooldown:         0x374b;  level < scroll DemandLv: 0x374a
    → DB 0x34C9 NC_ITEMDB_MAPLINK_ITEM_CONSUME_REQ (one scroll consumed); the link (so_LinkTo, Z01) happens on the answer (Z05)
    other failures: 0x3749 / 0x3750
```

### 12.12 NC_ITEM_MIX_ITEM_REQ `0x3069` (C→Z) @ FUN_00521540

Payload *(pdb2017, confirmed)*: `{ u8 nSubRaw, u8 nRawLeft, u8 nRawRight }` — combine two identical upgraded items with a mix stone.
Reply `0x306A { u16 nError }`; texts from the error table.

```pseudo
    mode ∉ {1,2,6}, bad slots:                    0x37c5 ("Related data cannot be found.")
    sub raw must be the "AddMixItem" item (named constant):   0x37c6
    left / right must not be equipped (FUN_006435b0 over the equipment box):   0x37c2 ("Equipped items cannot be used…")
    left.id ≠ right.id:                            0x37c4
    both upgrade levels ≥ "MixMinUpgrade" (named constant):   else 0x37c6
    result = ItemMix.shn row by the item's InxName (DAT_133882c8); none: 0x37c6
    no empty cell for the result:                  0x37c7
    → DB 0x34CB NC_ITEMDB_MIX_ITEM_REQ (three items consumed, new item)
```

---

## 13. Soul stones (HP / SP potions)

Counters: HP stones `p+0x7f63` (u16), SP stones `p+0x7f65` (u16); they are not inventory items.
Per-class/per-level table: `p.vt[0x49c]()` (class data) `+0x10858 + level*4` (levels ≥ 151 use entry 0) → row
`{ +4 max-stock factor, +0x1c HP-stone value (price and heal base), … }`.

### 13.1 NC_SOULSTONE_HP_BUY_REQ `0x5001` / SP_BUY_REQ `0x5002` (C→Z) @ FUN_00588d20 / FUN_00588e90

Payload *(pdb2017, confirmed)*: `{ u16 number }`. Mode mask 0x46. Both call
`ShinePlayer_sp_PointStoneBuy(p, row(+0x1c HP / SP field), have, number, kind 0/1, reserved…, maxFactor p+0x2a5a2/+0x2a5a4)` @ FUN_00588510:

```pseudo
    mode ∉ {1,2,6}, L.locked(), no NPC in range:          0x5005 NC_SOULSTONE_BUYFAIL_ACK { 0x741 }
    if have + number + reserved > row.+4 × maxFactor / 1000:   0x5005 { 0x742 }        # stock limit (premium raises it)
    price = number × unit; if p.money + reserved < price:      0x5005 { 0x743 } (inferred: the branch order is merged by the decompiler)
    reserve money and the stone count (L.vt[0x5c](lock, kind, number))
    → DB 0x3441 NC_ITEMDB_SOULSTONEBUY_REQ; lock += 1; HolyPromise spending hook; vt 0xb40
```

Success: `0x5003` / `0x5004 { u16 totalnumber }` from the DB answer (Z05). Client FUN_00479fa0 shows the BUYFAIL / USEFAIL text.

### 13.2 NC_SOULSTONE_HP_USE_REQ `0x5007` / SP_USE_REQ `0x5009` (C→Z) @ FUN_00589510 / FUN_00589000

No payload. Mode mask 0x56 {1,2,4,6}. Failure: `so_SendProtocol(20, 6)` = `0x5006 NC_SOULSTONE_USEFAIL_ACK` (empty).

```pseudo
    if L.locked() or p.vt[0x9e4]():  fail
    require FieldList.CanStone (+0xa5), CanItem (+0x9e), HP ≠ 0, not dead, HP < MaxHP (SP: SP < MaxSP); else fail
    t1 = p+0x173b4 (next use), t0 = p+0x173b8 (queue window)
    if g_Now ≥ t1 and stones > 0:  sp_HPStoneUse(p)                       @ FUN_00589180
    elif t0 ≤ g_Now < t1 and stones > 0:  p+0x173bc = sp_HPStoneReserv     # queued: fires when the cooldown ends (player tick)
    else (too early): nothing
sp_HPStoneUse(p):
    send p: 0x5008 NC_SOULSTONE_HP_USESUC_ACK (empty, so_SendProtocol(20, 8)); p+0x173bc = no-op
    t1 = g_Now + 70 (7 s); t0 = g_Now + 50 (5 s); stones −= 1
    heal = p+0x2a5ae (‰ factor) × row.+0x1c / 1000; HP = min(HP + heal, MaxHP)
    broadcast 0x500B NC_SOULSTONE_HP_SOMEONEUSE_CMD { u16 player } (and refresh the party HP bar)
```

SP is the same with `p+0x7f65`, SP (+0x7f6b), `0x500A` / `0x500C`, and its own timers (`p+0x173c0…`).

---

## Original-server bugs

Behaviour of the 2016 zone item handlers that looks unintended. A faithful rebuild reproduces it; a fixed rebuild should
change it deliberately. All items are read in the code; none was observed in a capture.

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z04-B1 | 0x3006 SELL §2.4 | "no open NPC role" replies 0x3004 BUY_ACK 0x203 | the sell window gets no 0x3005; the code is silent in the buy handler too | 0x3005 with a sell code |
| Z04-B2 | 0x3059 REPURCHASE §2.5 | the level refusal 0x366b is sent as 0x3004 BUY_ACK | the 0x305A handler, which has the "purchase level" text, never sees it | 0x305A |
| Z04-B3 | 0x3007 DROP §3.1, guild-token buy §2.3, 0x300D SPLIT §4.2 | errors sent with dept/cmd 12/12 = 0x300C RELOC_ACK (0x242, 0x246, 0x24a) | the requesting window gets no answer; the client sees a stray relocation result | each handler's own ACK |
| Z04-B4 | 0x3007 DROP §3.1 | `cell.lot > req.lot` is refused (0x303) before the confirmation, so `ii_DropLot` (0x3419) is never reached | dead branch: partial-stack drops are impossible | allow partial drops, or remove DropLot |
| Z04-B5 | 0x3012 UNEQUIP §5.4 | checks the lock of (8, slotinven) instead of (9, slotinven) | an inventory cell that is locked by another transaction can be the unequip target | test (9, slotinven) |
| Z04-B6 | 0x3003 BUY §2.1 | codes 0x203, 0x204, 0x20e (not enough coin), 0x210 | silent in the client | codes with texts (0x20e: the coin text) |
| Z04-B7 | megaphone `uib_Effect` §6.4 | if the roar ring slot was overwritten, the item is consumed and nothing is sent | the player loses the megaphone without a message | keep the text with the cast, or refund |
| Z04-B8 | 0x301C / 0x301E §7.1 | error replies send only `{u16 code}`; the client reads `err` at +8 of `{u64 cen, u16 err}` | the client reads past the payload | the full 10-byte ACK |
| Z04-B9 | 0x3028 §7.2 | mode / storage-closed errors are sent as 0x3007 (NC_ITEM_DROP_REQ's number) | a client→server opcode reaches the client; the storage page request gets no answer | 0x3C07 NC_MENU_OPENSTORAGE_FAIL_CMD, as used for page ≥ 16 |
| Z04-B10 | 0x3026, 0x302F / 0x3031 §7.4, §7.5 | error replies write only the code; `cen` is stale `g_buf` content | stale bytes on the wire | zero `cen` |
| Z04-B11 | 0x302F §7.5 | `cen == 0` in the request: no reply | the client waits for an answer | a 0x3030 error |
| Z04-B12 | 0x3031 §7.5 | replies 0x3032 | the 2016 client has no handler | add one, or use a handled reply |
| Z04-B13 | 0x3033 §8.4 | every failing check inside `MHFurnitureKit_Use` returns without a reply | the repair silently does nothing | a 0x3034 error |
| Z04-B14 | 0x3040 / 0x3042 / 0x3044 §10 | no player-mode check and no "any lock open" check | enchanting works while dead, riding or during other item transactions (unchecked state) | the usual mode mask and `L.locked()` |
| Z04-B15 | 0x3044 §10.3 | no check that the weapon has fewer than 3 sockets | a 4th socket would write past the 3-entry socket array *(inferred; the 0x20a5 check may prevent repeats)* | cap at 3 |
| Z04-B16 | 0x3053 / 0x3061 §11 | 0x3053 sends no reply on a mode failure; 0x3061 has no mode check | silent refusal; options can be accepted in any mode | the error reply; the mode mask |
| Z04-B17 | 0x3039 §12.3 | the map refusal goes out as 0x483A (dept 18) instead of 0x303A; the other errors as 0x482B, which the client ignores | revive-item failures are invisible to the client | 0x303A NC_ITEM_REVIVEITEMUSEFAIL_CMD |

## 14. Not reconstructed / uncertain

- **DB answers** (all `0x34xx` ACKs), the commit of locked cells (`InventoryLocking::InvenCellReleaser_*::icr_Apply`), the final
  client packets `0x3001` CELLCHANGE / `0x3002` EQUIPCHANGE and the success codes (`0x201`, `0x281`, `0x2c1`, `0xf80`, …) are Z05.
  Many request layouts above list only the fields whose offsets were read; the ITEMDB request structs should be confirmed there.
- **Code-to-branch mapping.** Codes were recovered from the push sequence before each `vt 0x308` call; where the decompiler merged
  branches (SPLIT 0x445/0x446/0x448, PICK 0x34a vs 0x346, BELONGED_CANCEL 0x2885–0x288f, MAPLINK 0x3749/0x3750, soul-stone 0x743)
  the condition attached to a code is *(inferred)*.
- **Inventory type 2 / 3 / 13 / 14 / 16** meanings beyond "reward box" and "mini-house boxes" are inferred from the client
  `Inventory` class and the mini-house checks; types 1, 5, 7, 10, 11, 12 never appear as valid boxes in these handlers.
- **Item attribute layout** (`SHINE_ITEM_ATTRIBUTE` per class): only the bytes used here are named (upgrade level and failure counter,
  sockets, bound flag via attr vtable). The full per-class layout belongs to Z05 / D03.
- `ItemKey_Make` kinds (1 buy, 4 split, 8 mover, 9 charged) — the meaning of the kind field in the key is not decoded.
- The cast-completion caller of `uib_AfterCast` (player tick) and every individual `UseEffect` actor's `uib_CanUseItem` /
  `uib_DirectUse` / `uib_Effect` body are listed but not reconstructed (owners: Z07 mounts/pets/mini-house, Z08 quests, Z03 skills).
- `Item_AdjFailCount` exact semantics (reset on success / +1 on failure) are inferred from its call arguments.
- `FUN_005c5c60` (`UpgradeInfo` stat delta, the 4 bytes at `+0x4c…0x4f` of `0x3447`) not read.
- `ItemDismantleProducer` internals (Karis stack placement, `FUN_005290f0` codes) and `ItemsInChest` chest contents not read.
- Party/raid loot rules (`FUN_00644f60`), `sp_partyitemdistribute`, `sp_RaidItemsidtribute` and the drop-item dice game: Z06/Z09.
- Auto-arrange step scheduling (`p+0x2ab18`) and the sort key are summarized, not traced.
- The mover-upgrade rare roll (`RareMoverRate/EachRate/SubRate`) formula is not reconstructed.
- No item capture exists; nothing here is *(captured)*.
