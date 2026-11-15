# Character server: academy reward storage and tournament reward items (D07)

Source: the 2016 Character server (`Files/Server/2016/w00_Character/Character Release.exe`, export `re-data/exports/character`,
no server PDB). View the code with `python3 -I tools/protocol-re/clean.py re-data/exports/character tools/protocol-re/names/character
<addr>`. Ghidra merges several stack variables of FUN_0041de10, so §2 was read from the disassembly as well
(`objdump -d --x86-asm-syntax=intel --start-address=0x41de10 --stop-address=0x41ecf0`). In this section, stack offsets are
`ebp−x` (Ghidra's `Stack_x` names = `ebp−(x−4)`).

This item finishes two internals that D04 (`docs/pseudocode/db/D04-character-social.md` §6.4, §9.3, §12) only summarised:
how 0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ chooses, merges and moves stacks in the guild-academy reward storage, and how
0x74AA NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_REQ turns its ITEM_OPT records into item attributes. D04's handler blocks stay
valid for everything else (procedures, logs, cen codes). Evidence markers: *(pdb2017)*, *(db-backup)*, *(inferred)* as in
`AGENTS.md`. Packet layouts: `docs/protocol/annotations/D07.json` (key `character`). Names: `tools/protocol-re/names/character/D07.json`.

## 1. Helpers shared by both handlers

### 1.1 Item records of the academy reward storage

```pseudo
AcademyStorage_List(nGuildNo, out list, out size) → ≠ 0 ok, 0 failed (Ghidra shows it as void)   @ FUN_00403400 (D03 §5.3)
    ItemList_AcademyStorage(nGuildNo) = ItemList_ByStorage(owner = nGuildNo, storage type 0, max 100)  @ FUN_0046a3f0
        # box 0 = guild-academy reward storage (Z04 knowledge); only the first 100 rows are read
        ItemList_ByStorage(owner, type, max, out n, out rows[0x28 each])                             @ FUN_00469f70
            type > 16 → return 0 (no query)
            p_Item_GetListType(owner, type)   @ FUN_004615e0   # (db-backup) SELECT nItemKey, nStorage, nItemID, nFlags, dDate
                FROM tItem WITH(READUNCOMMITTED) WHERE nOwner = @nCharNo AND nStorageType = @nStorageType   (no ORDER BY)
            row = { u64 nItemKey @0, u16 nStorage (slot) @8, u8 storage type @0xA (= the argument), u32 nItemID @0xC,
                    u32 nFlags @0x10, dDate @0x14 }; stops after max rows
    ItemRecords_Build(rows → list)                                       @ FUN_00402e50
        list = { u16 ?, u8 count @2, records @3 }  # the 0x986B caller's buffer starts at ebp−0x1ca13, count at ebp−0x1ca11
        record = { u8 len (bytes after this one), ITEM_INVEN cell @1 (type << 10 | slot), u64 key @3, u16 itemId @0xB,
                   attr @0xD (class-sized wire form, written by the class's Write slot) }
        per row: CGameDB_Item_GetItemOptions(key) (D03 §1.3) fills the full attribute, then ItemStruct_Write  @ FUN_0044d300
        packs {key, itemId, attr} with the class object's vtable slot 1 (+4); a failed option load makes the whole list
        fail (returns 0, size not set); after the last row it returns whatever is left in eax (non-zero: a size / pointer
        difference; the caller only tests ≠ 0) *(inferred from the disassembly)*. A failed row fetch also returns 0
```

```pseudo
ItemStruct_Read(dst {u64 key, u16 itemId @8, attr[0x65] @0xA}, container, unused 0xFFFF, src = record + 3)   @ FUN_0044d340
    dst.key = src.key; dst.itemId = src.itemId
    cls = ItemAttributeClassContainer_Get(g_ItemAttrClassContainer, itemId)   @ FUN_0044d380
        # ItemInfo row's Class (+0x66) indexes the table at container+0x9C; class > 0x26 → log "ItemAttributeClassContainer::
        # operator [] : Invalid item class" and returns the container itself
    cls.vt[2](&dst.itemId, src + 0xA)     # slot 2 = Read: copies the class-sized wire attribute to dst.attr, returns the end
        # per-class sizes in §1.3 (e.g. ByteLot 1 byte, Weapon 0x41 + 3 per random option; unknown item → base class, nothing)
ItemAttrClassContainer_Self(container) → container                        @ FUN_0044ff60   (identity getter, our name)
```

The class objects are the 38 `ItemAttrCls_*` RTTI classes plus the base `ItemAttributeClass` (51 vtable slots each, `rtti.py`); §1.3.

### 1.2 Lot helpers

`ItemLotAfterUse` @ FUN_004038c0 and `ItemLot_Set` @ FUN_00403c00 are documented in D03 §1.2: ItemLotAfterUse returns 1 when the
item's class has a lot and gives the stored lot. `ItemAttr_MakeWithLot(itemId, lot, out attr)` @ FUN_00468000 builds a fresh
attribute for a newly created stack:

```pseudo
ItemAttr_MakeWithLot(itemId, lot, out attr[0x65]) → 0 when attr is null or the ItemInfo row is missing, else 1
    attr = zero (0x65 bytes)
    by Class:  BYTELOT 0, FEED 22, UPSOURCE 14, UPRED 19, UPBLUE 20, UPGOLD 25, NOEFFECT 33, ENCHANT 34 → u8 attr[0] = lot
               WORDLOT 1, QUESTITEM 3, KQSTEP 21, ACTIVESKILL 35                         → u16 attr[0] = lot
               DWRDLOT 2, AMOUNT 24                                                      → u32 attr[0] = lot
               RECALLSCROLL 12                                                           → u8 attr[0] = 1 (lot ignored,
                   although ItemLotAfterUse treats class 12 as a u8 lot class: (original bug) D07-B15)
               every other class                                                         → all zero (lot ignored)
```

### 1.3 Item attribute classes (`g_ItemAttrClassContainer`)

```pseudo
ItemAttributeClassContainer_Init(c)   @ FUN_0044f330   (our name; constructor of the global at DAT_006ef2e8)
    c[0] = base ItemAttributeClass object; c[1 … 0x26] = one object per ItemAttrCls_* class
    table[class] at c + 0x9C (39 entries, class 0 … 0x26): first all = c (the base object), then each class's object
    # class 32 (0x20, MONEY in ItemClassEnum, §3.2) keeps the base object: no ItemAttrCls for it (no 2016 ItemInfo row has it)
    # ItemAttributeClassContainer_Get (§1.1) also falls back to c, i.e. the base class, for a missing item or class > 0x26
```

Vtable slot 1 (+4) Write copies the attribute (`attr` = item struct + 2) to the wire and returns the end; slot 2 (+8) Read is
the mirror. Slot 10 (+0x28) returns the class number (read from each class's getter; they agree with the table). Both slots
copy the full struct size (= the 2017 PDB `ShineItemAttr_*` size, *(pdb2017)* names), but the wire length can be shorter.
The `ItemAttrCls_<class>_Write/_Read` function names are ours (`names/character/D07.json`), the class names are RTTI:

| Class | ItemAttrCls_* | Write / Read | Wire bytes |
|---|---|---|---|
| 0, 12, 14, 19, 20, 22, 25, 33, 34 | ByteLot, RecallScroll, UpSource, UpgradeRedGem, UpgradeBlueGem, Feed, UpgradeGoldGem, NoEffect, Enchant | FUN_0044dae0 / FUN_0044dce0 | 1 (u8 lot) |
| 1, 3, 21, 35 | WordLot, QuestLot, KQStep, ActiveSkill | FUN_0044d9b0 / FUN_0044dbc0 | 2 (u16) |
| 2, 18, 24, 26, 27, 37 | DwrdLot, MiniHouseSkin, Amount, CostumWeapon, ActionItem, CostumShield | FUN_0044dac0 / FUN_0044dc80 | 4 (u32) |
| 4 | Amulet | FUN_0044f6d0 / FUN_0044f760 | 0x26 + 3·n, n = attr[0x25] >> 1 (copies 0x3E) |
| 5 | Weapon | FUN_0044f700 / FUN_0044f790 | 0x41 + 3·n, n = attr[0x40] >> 1 (copies 0x59) |
| 6, 7, 8, 38 | Armor, Shield, Boot, Bracelet | FUN_0044f730 / FUN_0044f7c0 | 0xD + 3·n, n = attr[0xC] >> 1 (copies 0x25) |
| 9 | Furniture | FUN_0044d9d0 / FUN_0044dbe0 | 0x24 |
| 10 | Decoration | FUN_0044d9f0 / FUN_0044dc00 | 8 |
| 11, 16, 28 | SkillScroll, WeaponTitlaLicence, GBCoin | FUN_0044da70 for both | 1, never written or read: the pointer only advances (original bug) D07-B14 |
| 13 | BindItem | FUN_0044da10 / FUN_0044dc20 | 1 + 10·attr[0] (copies 0x65) |
| 15 | ItemChest | FUN_0044da40 / FUN_0044dc50 | 1 + 8·(attr[0] & 0xF) (copies 0x41) |
| 17 | KingdomQuestItem | FUN_0044dbb0 (ItemAttributeClass_ReadWriteNone) | 0 (the 2017 struct `ShineItemAttr_KingdomQuest` is 1 byte) |
| 23 | Riding | FUN_0044da80 / FUN_0044dca0 | 0x13 |
| 29 | Capsule | FUN_0044db00 / FUN_0044dd00 | 0xC |
| 30 | CardCollect_Close | FUN_0044db30 / FUN_0044dd30 | 9 |
| 31 | CardCollect | FUN_0044db60 / FUN_0044dd60 | 5 |
| 36 | Pet | FUN_0044db80 / FUN_0044dd80 | 0x1A |
| 32, unknown | base ItemAttributeClass | FUN_0044dbb0 | 0 |

The option count byte is `ItemOptionStorage.fixed.optionnumber` *(pdb2017)*: `ItemOptionStorage` = { u8 fixed, Element[8]
{u8 itemoption_type, u16 itemoption_value} }; its bits 1–7 are the count (the code uses `>> 1`; bit 0 is not read here). In
the Amulet it is `option` at 0x25 (an `UpgradeOption` storage sits at 0x0B), in the Weapon `option` at 0x40, in the Armor
family `option` at 0xC. Because Read copies the full struct while the wire record is shorter, Read also copies the bytes of the
next record (or stale buffer bytes) into the unused option slots; nothing reads them in 0x986B *(inferred: harmless)*.

## 2. 0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ (from the zone) @ FUN_0041de10

The zone sends it when an academy member levels up (Z03 §8.3 `sp_GainExp`). The handler pays the reward that the academy
master configured for that level (`tGuildAcademyReward`, set by 0x983B / 0x983F, D04 §9.3): cen from the academy's money and one
item kind out of the academy reward storage (box 0). The member's item goes into their **reward inventory** (box 2) in the DB.

### 2.1 Layouts

```pseudo
0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ { NETPACKETZONEHEADER packheader, u32 nCharNo @6, u32 nGuildNo @0xA,
        u8 nLevel @0xE }                                                                       (0xF)
0x986C NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_ACK (0x3D + 9·nModifyItemCnt) {
    NETPACKETZONEHEADER packheader @0     = request.packheader
    u16 Error @6                           0x18A0 ok; failure codes in §2.6
    u32 nCharNo @8, u32 nGuildNo @0xC      = request
    u64 nWantMoney @0x10                   reward cen − cen paid
    u32 nWantItemCnt @0x18                 lot still missing (see §2.6 for the "no item" case)
    GUILD_ACADEMY_REWARD_ITEM WantItem @0x1C { u8 nLevel = request.nLevel, u16 nItemID = reward item (0xFFFF none),
        u8 NumOfItemOption = number of option rows, GUILD_ACADEMY_REWARD_ITEM_OPTION ItemOption[1] {u32 nOptionType, u64 nOptionData}
        = the first option row }
    u64 nSubAcademyMoney @0x2C             cen paid (taken from the academy)
    u64 nStorageMoney @0x34                academy money after the payment (0 when no cen is configured: (original bug) D07-B4)
    u8  nModifyItemCnt @0x3C
    EACH_MODIFY_ITEM ModifyItem[n] @0x3D { u8 nStatus (0 whole stack taken, 1 part of the stack taken), u16 nItemID,
        ITEM_INVEN nLocation (the stack's cell in box 0), u32 nLot (amount taken) }
}
0x9882 NC_GUILD_ACADEMY_DB_REWARD_WANT_CMD (to the WM) { u32 nCharNo, u32 nGuildNo @4, u64 nWant_Cen @8,
        u16 nWant_ItemID @0x10, u32 nWant_ItemLot @0x12 }                                       (0x16)
```

All field names are the 2017 PDB's *(pdb2017)*; every offset was confirmed in the 2016 code (payload base `ebp−0x1eedb` for
0x986C, `ebp−0x20edf` for 0x9882). The answer is pre-filled before the first DB call: Error 0x18A0, money and counts 0,
WantItem {0, 0xFFFF, 0}.

### 2.2 Reading the configured reward

```pseudo
    CheckAlive(session, packet) fails → return, no answer                                    @ FUN_0043c640
    ok = usp_GuildAcademy_getReward(nGuildNo, (u16) nLevel, OUT nRet)      @ FUN_00456190 (ok: exec ok and nRet == 0)
        # (db-backup) SELECT nTypeID, nValue, nItemID FROM tGuildAcademyReward WHERE nNo = @nNo AND nLevel = @nLevel
        #   (no ORDER BY); −1511 bad guild, −1513 level ≤ 0, −1591 DB error
    !ok → Error 0x188D; log "ERROR - CPFsCharacter::fc_NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ : GuildNo=%d, nRet=%d"; send; end
    rewardCen = 0; item = 0xFFFF; nOpt = 0; wantLot = 1; fullLot = 1        # want = {u16 item @ebp−0x20efc, u32 wantLot,
                                                                            #  u32 fullLot, u8 nOpt, options[1] @ebp−0x20ef1}
    per row (u8 type, u64 data, u16 itemId), type = REWARD_ITEM_OPTION (pdb2017: 1 RIO_MONEY, 2 RIO_ITEM, 3 RIO_LOT, 4 RIO_UPGRADE):
        type 1: rewardCen = data                       # several cen rows: the last one wins
        else:   itemId == 0xFFFF, or item already set and itemId ≠ item →
                    close the cursor; Error 0x18A1; log "… DB에 보상 아이템 설정 이상함 GuildNo(%d)" ("reward item setting in the DB
                    is abnormal"); send; end
                item = itemId
                options[nOpt] = {type, data}; nOpt += 1
                    # only options[0] has room: a second option row writes into the following, not yet constructed 0x9882
                    # packet buffer (original bug) D07-B7
                type 3: wantLot = fullLot = (u32) data
```

The WM's 0x983F stores one row per item with that item's first option (D04 §9.3), so a level normally has at most one item row
and at most one cen row. An item reward is therefore "item X with lot N" (RIO_LOT), "item X with upgrade level U" (RIO_UPGRADE) or
"item X" (RIO_ITEM); without a RIO_LOT row the wanted amount is 1.

```pseudo
    if rewardCen ≠ 0:
        ok = usp_GuildAcademy_getMoney(nGuildNo, OUT nRet)                @ FUN_00456db0
        !ok: Error 0x18A1; log "… GuildNo=%d, Level=%d, nRet=%d"; r = send
             r == 0 → end; otherwise the handler continues (original bug) D07-B1
        money = first row's u64 (left unset when there is no row); ack.nStorageMoney = money
    # nothing configured (no cen row, item 0xFFFF): every step below is skipped and the answer is sent as 0x18A0 (§2.6)
```

### 2.3 Choosing stacks in the academy reward storage

```pseudo
    if item ≠ 0xFFFF:
        keys[] = the 0x240-byte local at ebp−0x1cc60 (first dword preset 0x1FF, rest 0; key i at +8·i)
        AcademyStorage_List(nGuildNo) fails (list read, or the options of any stored item) → Error 0x18A1; log "… 길드 아카데미 인벤토리 가져오기 실패" ("fetching the guild academy
            inventory failed"); send; end
        m = 0                                                    # = ack.nModifyItemCnt
        for each record r in list order (at most 100), while the loop has not stopped:
            s = ItemStruct_Read(r)                              (§1.1)
            s.itemId ≠ item → next record
            info = ItemInfo_Get(item); null → Error 0x18A1; log "… 길드 아카데미 인벤토리로의 아이템 확인중 오류 ItemID(%d)"
                ("error while checking the item in the guild academy inventory"); send; end
            # only options[0] is tested (loop bound 1, original bug D07-B7):
            stackable = 0
            options[0].type:
                2 RIO_ITEM:    match
                3 RIO_LOT:     stackable = ItemLotAfterUse(item, s.attr, out stackLot); match only when stackable
                4 RIO_UPGRADE: Class WEAPON 5 / ARMOR 6 / SHIELD 7 / BOOT 8 → upgrade = attr[0]; BRACELET 38 → upgrade = attr[8]
                               (ShineItemAttr_Weapon / Armor / Bracelet .upgrade, pdb2017); match when (u64) upgrade == data;
                               any other class never matches; AMULET 4 too, although ShineItemAttr_Amulet has upgrade @8
                               like Bracelet: the jump table at 0x41eca8 has no case 4 (original bug) D07-B16
                other:         no match
            no match → next record
            ModifyItem[m] = { nItemID = item, nLocation = r.cell }; keys[m] = s.key
                # keys[] holds 72 entries; the 73rd match (index 72) lands in ebp−0x1ca20…−0x1ca19, which nothing reads;
                # the 74th (index 73) writes its bytes 5–7 over the list header ebp−0x1ca13…−0x1ca11, byte 7 = the
                # count byte that bounds the loop (original bug) D07-B9
            if stackable:
                if wantLot ≥ stackLot: ModifyItem[m] = {nStatus 0, nLot = stackLot}; wantLot −= stackLot
                else:                  ModifyItem[m] = {nStatus 1, nLot = wantLot};  wantLot = 0
            else:                      ModifyItem[m] = {nStatus 0, nLot = 1};        wantLot = 0
                # RIO_ITEM on a stackable item takes the whole stack but reports nLot 1 (original bug) D07-B8
            m += 1
            wantLot == 0 → stop
```

So a lot reward takes whole stacks in storage-list order until the next stack is larger than what is still missing; that
stack is split. A non-lot reward takes the first matching item. Other attributes of the stack (upgrade, random options,
binding) are not compared for RIO_LOT / RIO_ITEM. No DB row changes in this phase.

### 2.4 Cen

```pseudo
    if rewardCen ≠ 0:
        amount = min(rewardCen, money); ack.nWantMoney = rewardCen − amount; ack.nSubAcademyMoney = amount
        if (i64) amount ≤ 0: ack.nStorageMoney = money − amount          # nothing to withdraw
        else:
            ok = usp_GuildAcademy_withdrawMoney(nGuildNo, nCharNo, amount, OUT nRet)      @ FUN_00456510
                # (db-backup) moves the cen from tGuildAcademy.nMoney to the character (D04 §9.3, D03 §5.3)
            !ok: Error by nRet 1 → 0xF99, 2 → 0xF9A, 3 → 0xF9B, 4 → 0xF9C, 5 → 0xF9D, 6 → 0xF9E, other → 0xF98
                 log "FAILED - fc_NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ, nGuildNo=%d, nCharNo=%d, nWithdrawMoney=%I64d, nRet=%d";
                 send; end            # no item has moved yet
            ack.nStorageMoney = money − amount
    ack.nWantItemCnt = wantLot; ack.WantItem = { request.nLevel, item, nOpt, options[0] }
        # options[0] is uninitialised stack when nOpt == 0 (original bug) D07-B6
```

The cen leaves the academy before any item moves, and nothing undoes it when the item part fails (original bug) D07-B2.

### 2.5 Moving the items

```pseudo
    m == 0: → answer (§2.6)
    m == 1 and ModifyItem[0].nStatus == 0:                       # one whole stack (or one non-lot item)
        ok = p_Item_SetStorageAndOwner_UseEmptyStorage(keys[0], owner = nCharNo, storage type 2, OUT slot, OUT nRet)
             @ FUN_00461fc0 (flag 1; ok = nRet == 1)
             # (db-backup) slot = p_Item_GetStorageEmpty(owner, 2): the lowest free slot, no upper bound; then UPDATE tItem
        !ok → Error 0x18A1; send; end
        → answer (§2.6)
    otherwise (several entries, or one split):                   # the taken amounts are merged into one new item
        for i in 0 … m−1:
            nStatus 0: Item_DropAll(keys[i], owner = nGuildNo)                         @ FUN_004628b0
                       # p_Item_IsValidOwner → 1 no item / 2 other owner, else p_Item_Delete (3 on error);
                       # the result is not checked (original bug) D07-B3
            nStatus 1: a = CGameDB_Item_GetItemOptions(keys[i])  (result unchecked; a failed load leaves lot 0, caught below)
                       b = copy of a
                       lot = ItemLotAfterUse(item, a)
                       lot ≤ ModifyItem[i].nLot → Error 0x44D; send; end
                       ItemLot_Set(item, b, lot − nLot)
                       ItemLot_Set(item, &s.itemId, nLot)      # writes into the item-id field of the last record copy, not
                                                               # an attribute; nothing reads it afterwards (original bug) D07-B11
                       e = ItemAttr_Save(keys[i], item, b): 1 → Error 0x44A, other ≠ 0 → Error 0x44B; send; end
        key = MakeItemKeyEx(item, 0xB, 0, g @0x4e2f6c)            @ FUN_0044d240 (D04 §6.4)
        rec = { key, owner = nCharNo, storage type 2, slot 0, u32 itemId = item, flags 0 }
        attr = ItemAttr_MakeWithLot(item, fullLot − wantLot)     (§1.2; the amount actually taken)
            fails → log "아이템 속성 셋팅 실패" ("setting the item attribute failed"); Error 0x44B; send; end
        Item_Insert(rec, attr, useEmptySlot 1) (p_Item_Create_UseEmptyStorage, D03 §1.2) ≠ 0 →
            log "… - 아이템 생성 에러" ("item creation error"); Error 0x44B; send; end
        # the merged lot is checked neither against ItemInfo.MaxLot nor against 0 (original bug) D07-B10
        → answer (§2.6)
```

The split codes 0x44A / 0x44B / 0x44D are the ones of 0x3434 NC_ITEMDB_SPLIT_REQ (D03 §3.3), but unlike that handler this one
restores nothing when the insert fails. A merged reward gets a new item key; the old stacks' keys disappear.

### 2.6 Answers

```pseudo
answer:
    Send 0x986C (size 0x3D + 9·m) to the zone session; r = result
    r ≠ 1 → log "… - 보상 아이템 정보 전송 에러" ("error sending the reward item info"); end
    if ack.nWantMoney ≠ 0 or ack.nWantItemCnt ≠ 0:
        Send to the WM (SendToWorldManager @ FUN_00402d80) 0x9882 { nCharNo, nGuildNo, nWant_Cen = nWantMoney,
            nWant_ItemID = nWantItemCnt ≠ 0 ? item : 0xFFFF, nWant_ItemLot = nWantItemCnt }
        failure → log "… - 미지급 보상 아이템 정보 전송 에러" ("error sending the unpaid reward item info")
```

Every error path sends the pre-filled 0x986C with Error changed and whatever the earlier steps already wrote, at the
pre-set size 0x3D (only the success path sets 0x3D + 9·m, 0x41eb26): an error after the match loop (withdraw 0xF98–0xF9E,
single move 0x18A1, split / create 0x44A / 0x44B / 0x44D) therefore sends nModifyItemCnt = m (written in the loop, 0x41e4db)
with no ModifyItem entries in the packet (original bug) D07-B18; harmless, since the zone ignores codes other than 0x18A0.
Error paths end without 0x9882, except D07-B1: after a failed `usp_GuildAcademy_getMoney` the handler goes on, and its final
answer (still Error 0x18A1) is followed by 0x9882 when that send succeeds and nWantMoney or nWantItemCnt ≠ 0 (the condition
does not test Error). Error codes: 0x18A0 success, 0x188D reward read failed, 0x18A1 reward setup / academy money / storage list /
ItemInfo / single move failed, 0xF98–0xF9E cen withdraw failed, 0x44A / 0x44B / 0x44D split or create failed. None of them is in
the client error table: the zone handler (Z14 §4.3 `so_ply_GuildAcademyRewardStorageRewardZoneRng` @ FUN_0046e750) treats every
code other than 0x18A0 as "receive error" and does nothing. On 0x18A0 the zone adds nSubAcademyMoney to the member's money,
applies ModifyItem to its copy of the academy storage (nStatus 0: the cell must hold exactly nLot, then it is cleared; nStatus 1:
lot −= nLot), sets the storage cen to nStorageMoney and relays all of it as 0x9885. It does not use nWantMoney / nWantItemCnt /
WantItem. The member's new item exists only in the DB's reward inventory (box 2); 0x986C does not carry it *(inferred: the zone
sees it the next time it reads the reward inventory from the DB)*. The WM turns 0x9882 into 0x9883 NC_GUILD_ACADEMY_REWARD_WANT_CMD
to the master and the member when money ≠ 0 or the item ≠ 0xFFFF (W03 §6.3).

With no item configured, wantLot keeps its initial 1, so nWantItemCnt = 1 and 0x9882 goes out with nWant_ItemID 0xFFFF / lot 1
after every cen-only or empty reward (original bug) D07-B5. The WM drops it when the cen was fully paid.

### 2.7 Outcome per storage situation

L = wanted lot (RIO_LOT data, else 1), stacks s₁, s₂ … of the reward item in storage-list order.

| Situation | ModifyItem | DB change for the item | nWantItemCnt / 0x9882 |
|---|---|---|---|
| no item configured | none | none | 1 / sent with item 0xFFFF (D07-B5) |
| no matching stack (also: stack not lot-capable for RIO_LOT, wrong upgrade, other class for RIO_UPGRADE, item beyond the first 100 rows) | none | none | L / sent |
| one stack, s₁ = L, or s₁ < L and no other match | {0, s₁} | stack moved to the member's box 2 (lowest free slot) | L − s₁ (0 when equal) / sent when ≠ 0 or cen missing |
| one stack, s₁ > L | {1, L} | stack lot s₁ − L saved; new item, lot L, in box 2 | 0 |
| s₁ … s_k whole (Σ < L), then s_{k+1} > rest | {0, s₁} … {0, s_k}, {1, rest} | the k stacks deleted, s_{k+1} reduced, one new item of lot L in box 2 | 0 |
| several whole stacks, Σ ≤ L, no more | {0, sᵢ}… | the stacks deleted, one new item of lot Σ in box 2 | L − Σ / sent when ≠ 0 |
| non-lot item (RIO_UPGRADE / RIO_ITEM) found | {0, 1} | that item moved to box 2 (RIO_ITEM on a stackable: the whole stack, D07-B8) | 0 |
| storage list fails / ItemInfo missing | none | none (before the cen) | 0x18A1, no 0x9882 |
| single move fails | {0, s₁} | none (cen already withdrawn, D07-B2) | 0x18A1, no 0x9882 |
| split / create fails | as computed | whole stacks before the failure already deleted, cen withdrawn (D07-B2) | 0x44A / 0x44B / 0x44D, no 0x9882 |

"Full storage" does not occur on the member's side: `p_Item_GetStorageEmpty` has no slot limit *(db-backup)*, so moves and
inserts into box 2 never fail for lack of space. On the academy side only the first 100 records of box 0 are read; stacks after
them count as missing.

## 3. 0x74AA ITEM_OPT and `GTReward_MakeItemAttr` @ FUN_00467c60

D04 §6.4 documents the handler (FUN_004076a0). It walks `nItem` records of 0x21 bytes from payload offset 0xC. The WM fills them
from `GuildTournamentReward.shn` rows of the reward rank (W03 §8.5); the record is that row without its first two columns.

### 3.1 ITEM_OPT (0x21 bytes)

| Off | Type | Name *(pdb2017; = GuildTournamentReward.shn column)* | ID_ITEM (0) | ID_GUILD_FAME…ID_GUILD_TOKEN (1–4) | ID_GUILD_MONEY_DIVISION (5) |
|---|---|---|---|---|---|
| 0x00 | u8 | RewardType (`GT_REWARD_TYPE`) | 0 | type | 5 |
| 0x01 | u32 | Value1 | item id: low 16 bits for ItemInfo, MakeItemKeyEx and the attribute; the full u32 goes to `p_Item_Create`'s nItemID ((original bug) D07-B13) | amount added | share in ‰ (clamped to ≤ 1000 and written back into the request) |
| 0x05 | u32 | Value2 | lot for the lot classes (§3.2) | unused | minimum share (0 = none) |
| 0x09 | u32 | Value3 | WEAPON upgrade level (attr[0], u8) | unused | maximum share (0 = none) |
| 0x0D | u32 | IO_Str | random option `IOT_STR` 1 | unused | unused |
| 0x11 | u32 | IO_Con | random option `IOT_CON` 5 | unused | unused |
| 0x15 | u32 | IO_Dex | random option `IOT_DEX` 3 | unused | unused |
| 0x19 | u32 | IO_Int | random option `IOT_INT` 2 | unused | unused |
| 0x1D | u32 | IO_Men | random option `IOT_MEN` 4 | unused | unused |

Option kinds are `ITEM_OPTION_TYPE` *(pdb2017)*: IOT_STR 1, IOT_INT 2, IOT_DEX 3, IOT_MEN 4, IOT_CON 5; the code writes exactly
these numbers for the five columns. Random-option values are stored as u16 (the high half of each u32 is dropped). Every byte of
the record is read for some type; none is padding. Types > 5 are skipped by the handler.

The shipped 2016 table uses only BYTELOT items (Rama's Potion 4033–4039, class 0, MaxLot 50) with Value2 = lot 50/30/20/10/5 and no
options, plus fame / money / exp / token / division rows (rank 1: 500 fame, 10 000 000 cen, 100 exp, 600 tokens, division 500 ‰).

### 3.2 Attribute per item class

```pseudo
GTReward_MakeItemAttr(opt, out attr[0x65]) → 0 when attr is null or ItemInfo row (u16) opt.Value1 is missing, else 1   @ FUN_00467c60
    attr = zero (0x65 bytes); class = ItemInfo.Class
    RandomOpts(base): n = 0; for (col, kind) in (IO_Str, 1), (IO_Con, 5), (IO_Dex, 3), (IO_Int, 2), (IO_Men, 4):
                          if opt.col ≠ 0: attr[base + 1 + 3n] = kind; u16 attr[base + 2 + 3n] = (u16) opt.col; n += 1
                      if n ≠ 0: attr[base] = n << 1 | 1      # ItemOptionStorage.fixed (count in bits 1…, bit 0 set); at most 5 of 8
    BYTELOT 0, FEED 22, NOEFFECT 33, ENCHANT 34: u8 attr[0] = Value2
    WORDLOT 1, ACTIVESKILL 35:                   u16 attr[0] = Value2
    DWRDLOT 2, AMOUNT 24:                        u32 attr[0] = Value2
    QUESTITEM 3, KQSTEP 21:                      u16 attr[0] = 1
    RECALLSCROLL 12, UPSOURCE 14, UPRED 19, UPBLUE 20, UPGOLD 25: u8 attr[0] = 1   (Value2 ignored: (original bug) D07-B12)
    AMULET 4:          RandomOpts(0x25)          (ShineItemAttr_Amulet.option; upgrade @8 stays 0: (original bug) D07-B17)
    WEAPON 5:          mob-kill slots: u16 attr[7] = attr[0xD] = attr[0x13] = 0xFFFF (mobkills[3].mob), u16 attr[0x19] = 0xFFFF
                       (CharacterTitleMobID); u8 attr[0] = Value3 (upgrade); RandomOpts(0x40) (ShineItemAttr_Weapon.option)
    ARMOR 6, SHIELD 7, BOOT 8, BRACELET 38: RandomOpts(0xC)   (ShineItemAttr_Armor / Bracelet .option; Value3 is not applied as
                       their upgrade although Armor @0 / Bracelet @8 have one: (original bug) D07-B17)
    DECORATION 10, HOUSESKIN 18: u32 attr[0] = 0 (deletetime; already zero)
    RIDING 23:         u16 hungrypoint = 100; deletetime @2 = 0; bitflag @6 &= 0x8000 (already 0); u32 nHP @0xC = 0
    CAPSULE 29:        u32 useabletime @8 = 0
    PUP 36:            u32 nPetRegNum @0 = nPetID @4 = 0xFFFFFFFF, sName @8 = "", bSummoning @0x19 = 0
    FURNITURE 9, SKILLSCROLL 11, BINDITEM 13, ITEMCHEST 15, WTLICENCE 16, KQ 17, COSWEAPON 26, ACTIONITEM 27, GBCOIN 28,
    CLOSEDCARD 30, OPENCARD 31, MONEY 32, COSSHIELD 37: all zero
```

Class names are `ItemClassEnum` and the struct offsets are `ShineItemAttr_<class>` *(pdb2017)*; they agree with D03 §1.3's save
table (option base of amulet 0x25, weapon 0x40, armor / shield / boot / bracelet 0xC). `ItemAttr_Save` then writes the
attribute as option rows (D03 §1.3). For the 0x74AA caller, the item goes into the guild storage (box 4) at the next free slot
of 0…35 (D04 §6.4). The two attribute builders disagree for UPSOURCE / UPRED / UPBLUE / UPGOLD / QUESTITEM / KQSTEP (this one
forces lot 1, ItemAttr_MakeWithLot uses the lot); for RECALLSCROLL both force 1, which on the 0x986B side loses lot (D07-B15).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D07-B1 | 0x986B | when `usp_GuildAcademy_getMoney` fails, the 0x18A1 answer is sent and the handler goes on if that send succeeded, with the academy money unset (stack) | cen may be withdrawn (amount from uninitialised money) and items moved; a second 0x986C, still Error 0x18A1, follows, and then possibly 0x9882 to the WM (its condition does not test Error); the zone ignores both answers | end after the error answer |
| D07-B2 | 0x986B | the cen is withdrawn before the items move, and no later failure (single move 0x18A1, split 0x44A/0x44B/0x44D, create 0x44B) undoes the withdraw or the stacks already deleted | the DB has moved the cen to the character and lost the stacks, but the zone ignores the error answer: the member's in-memory money lacks the cen *(inferred: lost when the zone next saves the character)* and the storage views are stale | one transaction, or items first and money last |
| D07-B3 | 0x986B | `Item_DropAll`'s result is ignored in the merge path | a whole stack that is not deleted (other owner, DB error) still counts in the merged new item: its lot exists twice | check it and fail with an item code |
| D07-B4 | 0x986B | nStorageMoney is only written when a cen reward is configured; item-only rewards answer 0 | the zone sets the academy storage cen to 0 and relays it in 0x9885 to every zone | read the academy money for every reward |
| D07-B5 | 0x986B | with no reward item, the wanted lot keeps its initial value 1 | nWantItemCnt = 1 with item 0xFFFF in 0x986C, and a 0x9882 {item 0xFFFF, lot 1} after every cen-only or empty reward (the WM drops it when no cen is missing) | initial wanted lot 0 when there is no item |
| D07-B6 | 0x986B | WantItem.ItemOption[0] is copied from a local that is only written by an option row | 12 bytes of uninitialised stack in 0x986C when no item is configured (unused by the zone) | zero it |
| D07-B7 | 0x986B | the option list has room for one entry, rows are appended without a bound, and only option 0 is matched; row order comes from a SELECT without ORDER BY | extra option rows (only possible with hand-made DB rows: 0x983F stores one) overwrite the not yet constructed 0x9882 buffer and are ignored when matching | bound the list and match all options |
| D07-B8 | 0x986B | RIO_ITEM never sets the stackable flag: the first matching stack is taken whole but reported with nLot 1 | the member receives the whole stack; the zone's apply for nStatus 0 needs cell lot == nLot, so it stops and keeps the stack in its storage view | take one unit (split) or report the stack's lot |
| D07-B9 | 0x986B | the key list of matched stacks holds 72 entries, the match loop is bounded only by the (≤ 100) records | the 73rd matched stack lands in an unused gap; the 74th writes its key's bytes 5–7 over the storage list header, byte 7 being the count byte that bounds the loop | 100 entries |
| D07-B10 | 0x986B | the merged lot fullLot − wantLot is checked neither against ItemInfo.MaxLot nor against 0 | a RIO_LOT larger than MaxLot creates an over-full stack; RIO_LOT 0 splits 0 off the first stack and creates a lot-0 item; for the u8 / u16 lot classes (ByteLot, Feed, UpSource …, WordLot …) ItemAttr_MakeWithLot stores only the low byte / word, so a merged lot > 255 (> 65535) is silently cut | validate the configured lot |
| D07-B11 | 0x986B | the second ItemLot_Set of the split writes the taken lot into the record copy's item-id field (`ebp−0x1cd2c`) instead of an attribute | none (never read again) | dead code, or meant for a new-item attribute |
| D07-B12 | 0x74AA | GTReward_MakeItemAttr gives lot 1 to RECALLSCROLL, UPSOURCE, UPRED, UPBLUE, UPGOLD, QUESTITEM and KQSTEP whatever Value2 says, although these classes have a lot | a reward row for gems etc. with Value2 > 1 yields one item (the shipped table has none) | use Value2 as for the other lot classes *(inferred; may be deliberate)* |
| D07-B13 | 0x74AA | the item row gets the full u32 Value1 as nItemID while the key, ItemInfo lookup and attribute use its low 16 bits | an id ≥ 0x10000 would create a row whose item id differs from its attribute's class (the shipped table has none) | u16 throughout |
| D07-B14 | attribute classes 11 / 16 / 28 (all item lists, 0x986B) | SkillScroll, WeaponTitlaLicence and GBCoin Write (FUN_0044da70) advance the output by one byte without writing it | one uninitialised buffer byte per such item in every item record list (D03 §1.4 lists to the zone, the 0x986B storage list); the matching Read ignores it | write the 1-byte attribute (or advance 0) |

| D07-B15 | 0x986B | ItemLotAfterUse treats RECALLSCROLL (12) as a u8 lot class, so RIO_LOT matches and splits recall-scroll stacks, but ItemAttr_MakeWithLot always gives class 12 lot 1 | a merged recall-scroll reward deletes / reduces stacks worth L and creates one item of lot 1: L − 1 scrolls lost | store the lot as for the other u8 lot classes |
| D07-B16 | 0x986B | the RIO_UPGRADE jump table (0x41eca8) has no case for AMULET (4), although its attribute has an upgrade @8 like Bracelet | an amulet reward with an upgrade level never matches a stored amulet; the whole amount is reported missing | read attr[8] for class 4 too |
| D07-B17 | 0x74AA | GTReward_MakeItemAttr applies Value3 as the upgrade level only to WEAPON; ARMOR / SHIELD / BOOT / BRACELET / AMULET ignore it | a tournament reward row for an upgraded armour piece yields +0 (the shipped table has none) | apply Value3 to every upgradable class *(inferred; may be deliberate)* |
| D07-B18 | 0x986B | error answers after the match loop keep the pre-set size 0x3D but carry nModifyItemCnt = m | packet says m entries, contains none (the zone ignores error answers) | reset nModifyItemCnt, or send the entries |

## 4. Not reconstructed / uncertain

- The order of the storage records (and so which stacks a lot reward takes first, and which records fall beyond the 100-row
  limit) is the order of `p_Item_GetListType`'s result set (§1.1; not `p_Item_GetStorageListType` @ FUN_00461660, the slot-only
  variant that `ItemStorage_GetUsedSlots` FUN_0046a500 uses for 0x74AA, D04 §6.4). The procedure has no ORDER BY and reads with READUNCOMMITTED
  *(db-backup)*, so the order is SQL Server's access path: unspecified. The w00 backup has a non-clustered primary key
  `PK_tItem_nItemKey_NC`; the clustered index (if any) and the index serving `nOwner, nStorageType` are not recoverable from
  the object names, so neither key order nor slot order is guaranteed *(inferred)*. A rebuild should fix one (e.g. by slot).
- The 2016 `usp_GuildAcademy_withdrawMoney` result codes 1–6 (0xF99–0xF9E) still have no known meaning (D04 §12, D06).
- The 0x1FF preset in the first dword of the key list (§2.3) has no visible purpose; the first match overwrites it.
- The zone reads the reward inventory (box 2) from the DB page by page: 0x302C NC_ITEM_REWARDINVENOPEN_REQ asks the Character
  server for slots page·24 … page·24+23 (Z04 §8.3), so an item the DB puts at any slot (lowest free, no upper bound) is shown
  when the client opens its page. Whether the client offers pages beyond some count (a slot the player can never page to) is
  not checked here *(inferred: client UI limit unknown)*.

## 5. Coverage boundary

Sweep (part 2): every callee of FUN_0041de10, FUN_00467c60, FUN_00468000 and FUN_004076a0 and every caller of FUN_00467c60,
FUN_00468000, FUN_0044d340, FUN_0044ff60, FUN_0044d300 and FUN_0044d380 was checked against the docs. FUN_00467c60 is called
only by 0x74AA (FUN_004076a0); FUN_00468000, FUN_0044d340 and FUN_0044ff60 only by 0x986B. The three log strings of
FUN_0041de10 in `strings.tsv` (0x004b2a08, 0x004b2b60, 0x004b2c38) and its Korean ones are quoted in §2.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| 0x986B procedures, cen codes, logging | D04 §9.3, §11 (done) | already documented there; this doc only adds the item internals |
| 0x74AA handler FUN_004076a0 (fame / money / exp / token / division, logs) | D04 §6.4 (done) | documented there; §3 here adds the ITEM_OPT / attribute mapping |
| zone side of 0x986C / 0x9885 | Z14 §4.3 (done) | the zone handler is documented there; §2.6 links to it |
| WM side of 0x9882 → 0x9883 and of 0x74AA's sender / 0x74AB | W03 §6.3, §8.5 (done) | WM handlers documented there |
| `ItemAttr_Save`, `CGameDB_Item_GetItemOptions`, `Item_Insert`, `ItemLotAfterUse`, `ItemLot_Set`, `ItemRecords_Build` FUN_00402e50, `ItemInfo_Get` FUN_00402d20 internals | D03 §1.2–1.4, §5.3 (done) | generic item helpers, documented there; §1.1 / §1.3 here add the list procedure and the per-class wire sizes |
| other users of `ItemAttributeClassContainer_Get` FUN_0044d380 / `ItemStruct_Write` FUN_0044d300: 0x3447 NC_ITEMDB_UPGRADE_REQ FUN_0040e0d0, 0x346D NC_ITEMDB_CHESTITEM_REQ FUN_0040f030, 0x34D1 NC_ITEMDB_NEW_UPGRADE_REQ FUN_00430a10 | D03 (done; its handler blocks cite these functions) | Character item handlers; they use the same container (§1.3) |
| `p_Item_GetStorageListType` FUN_00461660 / `ItemStorage_GetUsedSlots` FUN_0046a500 | D04 §6.4, §11 (done) | 0x74AA's free-slot count, documented there |
| `SendToWorldManager`, `Session_SendPacket(To)`, `CSendPacket_*`, `DB_*`, `CheckAlive`, `Log` FUN_00447960 | D02 (done) | Character server framework |
| FUN_0046f750 (empty function, 768 call sites) | none needed | compiled-out stub (returns at once); no behaviour |
| reward-inventory paging 0x302C NC_ITEM_REWARDINVENOPEN_REQ FUN_004fc060 (how the member sees the moved / new item) | Z04 §8.3 (done) | the zone reloads box 2 by pages of 24 slots from the DB; §4 links it |
| vtable slots of the attribute classes other than Write / Read / class (lot, bound, …) | Z04 knowledge (`IsLot`, `GetLot`, …), D03 §1.2 | 0x986B uses them only through `ItemLotAfterUse` / `ItemLot_Set` (D03 §1.2) |
