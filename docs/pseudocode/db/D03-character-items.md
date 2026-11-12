# Character server: items (ITEMDB), economy, pets, house (D03)

Source: `Files/Server/2016/w00_Character/Character Release.exe` (export `re-data/exports/character`). Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/character tools/protocol-re/names/character <addr>`. Names:
`tools/protocol-re/names/character/D03.json` (handlers `fc_NC_*`: the original name where a log string carries it, otherwise
the opcode name; helpers are ours). Framework (CheckAlive, DB getters, sends, `SQL_<procedure>` wrappers): D02 §1
(`docs/pseudocode/db/D02-character.md`). Zone side of every request/answer: Z05 (`docs/pseudocode/zone/Z05-itemdb.md`, §1.7
request table, §10 client handling of the codes). Layouts: `docs/protocol/annotations/D03.json` (key `character`).

Evidence markers as in `CLAUDE.md`: plain = read in the 2016 binary; *(db-backup)* = only from the procedure source in
`Files/Server/2016/_Database` (version used: `w00_Character.bak` unless stated; where `Character.bak` differs it is said);
*(pdb2017)* = 2017 PDB only; *(inferred)*.

**Conventions in this file.**
- `hdr` = `NETPACKETZONEHEADER { u16 clienthandle, u32 charregistnumber }` (6 bytes), the zone's player reference. Offsets are
  payload offsets (after the 2-byte opcode). Almost every answer starts with the request's `hdr` copied back.
- `lock` = the zone's per-player lock index (Z05 §1.1); the Character server only copies it back.
- `cell` = `ITEM_INVEN` (u16 `type << 10 | slot`); the server splits it into `nStorageType = cell >> 10`, `nStorage = cell & 0x3FF`.
- `key` = u64 `SHINE_ITEM_REGISTNUMBER`; new keys are made by the zone (Z05 §1.7), the Character server only stores them.
- `attr` = the `SHINE_ITEM_ATTRIBUTE` bytes (0x65 in 2016) that follow a request; stored by `ItemAttr_Save` (§1.3).
- "Send X" = `CSendPacket_SetOpcode(X, size)` + `Session_SendPacket` on the requesting link (the zone).
- "Log X" = the same packet to `g_GameLogLink` if it is connected (D05 documents the GameLog side); `0x04xx` = `NC_LOG_*`,
  `0xC8xx` = `NC_SYSLOG_*` (names from the 2017 PDB enum `PROTOCOL_COMMAND_LOG` / `_SYSLOG`).
- Every handler starts with `if !CheckAlive(pkt): return` (D02 §1.1); it is not repeated below. No handler checks the packet
  length (the CParser checks only the registered opcode); every request is trusted.
- The Character server never answers on a timer and keeps no per-player state: each handler is one DB call chain and one answer.

## 1. Item persistence model

### 1.1 Tables (as the procedures use them, *(db-backup)*)

| Table | Columns | Used for |
|---|---|---|
| `tItem` | nItemKey (bigint), nOwner (int), nStorageType (tinyint), nStorage (smallint), nItemID (int), nFlags (int) | one row per item; `nOwner` = character number, or guild number for guild storage (type 4, §2.3), or user number for account storage (*inferred*, §5.1) |
| `tItemOptions` | nItemKey, nOptionType (smallint), nOptionData (bigint) | the attribute, one row per field (§1.3) |
| `tItemMobList` / title (`p_Item_SetMobList`, `p_Item_SetTitle`) | key, slot, mob id, kill count / title text | weapon licence mob kills and weapon title (§1.3) |
| `tCharacter.nMoney`, `nFame` | | cen and fame (`p_Char_MoneyGet/Set/Add/Sub`, `p_Char_FameSub`) |
| `tHolyPromise`, `tHolyPromiseReward` | nCharNo, nUpCharNo / nCharNo, nSeqNo, nType (1 in, 2 out), nMoney, nRemainMoney, nReceiptCharNo | "cen use reward" to the holy-promise upper member (§1.5) |
| `tGuildToken` | nNo (guild), nToken (bigint) | guild-token shop (§2.3) |

Money procedures *(db-backup, KR header "2004.8 By CJC")*: `p_Char_MoneyGet(charNo, out money, out nRet)` nRet 1 = found;
`p_Char_MoneySub(charNo, sub, out nRet)` nRet 1 = OK, 0 = no character **or the result would be negative**;
`p_Char_MoneyAdd(charNo, add, out nRet)` nRet 1 = OK (no upper limit). `p_Item_Create(key, owner, type, slot, itemId, flags, out
nRet)` = `INSERT tItem`, nRet = `@@ERROR`; `p_Item_Create_UseEmptyStorage` (same, `@nStorage` OUTPUT) first picks a free slot of
that storage type with `p_Item_GetStorageEmpty` and returns -1 when there is none. `p_Item_Delete(key, out nRet)` = `DELETE FROM
tItem` (the option rows are not deleted by this procedure; *inferred*: a cascade or trigger, not visible in the backups).
`p_Item_SetOption(key, type, data, out nRet)` = UPDATE the row, INSERT when no row matched; nRet = `@@ERROR`.

### 1.2 Item helpers

```pseudo
ItemInfo_Get(itemId) → row or null                                  @ FUN_00402d20 (`ItemDataBox::operator[]`, g_ItemInfo)
    row = g_ItemInfo.rows[itemId] (stride 0x28); its first u16 must equal itemId, else log
    "ItemDataBox::operator [] :Invalid Item index" (FUN_0044cba0) and null.  row+0x66 = ItemInfo.Class (`ItemClassEnum`)

ItemLotAfterUse(itemId, attr, out lot, out lotOptType) → 1 if the class has a lot                @ FUN_004038c0 (D02)
ItemLotOption(itemId, out lotOptType)                                                           @ FUN_00403aa0 (D02)
ItemLot_Set(itemId, attr, lot) → 1 if the class has a lot: writes the lot into attr               @ FUN_00403c00
    class → (lot option type, width):  BYTELOT 0, RECALLSCROLL 12, UPSOURCE 14, UPRED 19, UPBLUE 20, FEED 22, UPGOLD 25 → (1, u8)
        WORDLOT 1, KQSTEP 21 → (2, u16)    DWRDLOT 2 → (3, u32)    QUESTITEM 3 → (300, u16)    AMOUNT 24 → (4, u32)
        NOEFFECT 33 → (2500, u8)    ENCHANT 34 → (2000, u8)    ACTIVESKILL 35 → (2600, u16)
    (ItemLot_Set agrees except that it writes QUESTITEM and ACTIVESKILL as u16 and has the same widths otherwise)

Item_Insert(db, rec {key, owner, type, slot, itemId, flags 0}, attr, useEmptySlot) → 0 ok         @ FUN_0046be10 (D02)
    p_Item_Create or (useEmptySlot) p_Item_Create_UseEmptyStorage              @ FUN_00461270
    fail → log "ERROR - CreateItem's p_Item_Create( Key=…, Error=%d )", return the error
    err = ItemAttr_Save(key, itemId, attr)                             (§1.3)
    if err: log "ERROR - CreateItem's SetItemOptions(…)"; p_Item_Delete(key) (its failure logged too); return err

ItemBuy_Create(db, rec, attr, u64 price, u32 fame, u32 coin) → 0 ok, 1 = not enough, other = error   @ FUN_0046bbf0
    r = p_Item_BuyAll(key, owner, type, slot, itemId, flags 0, price, fame, coin)                     @ FUN_00462380
        # (db-backup) 10 params (w00 only; Character.bak has 9, no @nCoin): all three ≤ 0 → nRet 2; in one transaction:
        # p_Char_MoneySub(price) / p_Char_FameSub(fame) / usp_Gamble_subCoin(coin) — any failure → rollback, nRet 1;
        # p_Item_Create; its error → rollback, nRet = that error; commit, nRet 0
    if r != 0: return r
    err = ItemAttr_Save(key, itemId, attr)
    if err:
        p_Item_Delete(key)  (failure logged)
        p_Char_MoneyAdd(owner, price)  (failure logged)   # refund of the cen only (original bug) D03-B1
        return err

ItemGuildTokenBuy_Create(db, rec, attr, u32 price, …, out attrErr) → 0 ok                       @ FUN_0046bd30
    r = usp_Item_GuildToken_BuyAll(key, owner, type, slot, itemId, 0, price)                        @ FUN_004641e0
        # (db-backup) one transaction: usp_Guild_TokenSub(@nOwner, price) ≠ 0 → rollback, nRet 1; p_Item_Create → its error
    if r == 0 and (attrErr = ItemAttr_Save(...)) != 0: p_Item_Delete(key)
    return r or attrErr
```

Framework pieces these handlers reach (no item logic): `CSendPacket_SetSize` @ FUN_0044f8a0 (payload + 2 < 0x100 → 1-byte length
header, < 0x1FFC → 3-byte header, larger → log "ERROR - CSendPacket::SetSize=%d …" and an empty packet; used by
`CSendPacket_Append` @ FUN_0044f980 for the variable lists), `SessionList_FindByType(type, start)` @ FUN_0043dc20 (walks the
authenticated sessions under the list lock FUN_0044a970 / FUN_0044a990; `SendToWorldManager` @ FUN_00402d80 uses type 5),
`Name3_Copy` / `Name4_Copy` @ FUN_004029c0 / FUN_004029e0 (zero the 12/16-byte name, strncpy), `vector::reserve` @ FUN_0046e210
and `std::_Xlength_error` @ FUN_0048ceae (inside `CollectionCardSerial`).

### 1.3 Attribute storage: `ItemAttr_Save` @ FUN_0046a730 and `ItemAttr_Load` @ FUN_004681a0

The 0x65-byte `SHINE_ITEM_ATTRIBUTE` is never stored as a blob. `ItemAttr_Save(db, key, itemId, attr)` switches on the item's
`ItemInfo.Class` and writes one `p_Item_SetOption(key, nOptionType, value)` per field (stops at the first error and returns it;
0 = all written). `ItemAttr_Load(db, key, out attr[0x65])` zeroes the buffer, runs `p_Item_GetOptionAll(key)` (rows `{u16 type,
i64 data}`) and puts each row back by its type, so the type alone decides the field: the option type numbering is
`class base + field index`. Both are used by every handler that sends or receives a full attribute (ITEMTOTALINFORM, item lists
in D02 §10, chests, capsules, item money …).

Per class (from the save switch; jump table @ 0x46BAF4; offsets from the load switch; field names from the 2017 PDB
`ShineItemAttr_<class>` structs (pdb2017), matched by offset):

| Class | Option types written |
|---|---|
| 0 BYTELOT, 12, 14, 19, 20, 22, 25 | 1 (lot u8) |
| 1 WORDLOT, 21 KQSTEP | 2 (lot u16) |
| 2 DWRDLOT | 3 (lot u32) |
| 24 AMOUNT | 4 (amount u32) |
| 3 QUESTITEM | 300 (lot u16) |
| 4 AMULET | 400 + random-option block (FUN_00469a80), 417–420, 426–428 (deletetime, upgrade, strengthen, failcount, IsPutOnBelonged, randomOptionChangedCount, UpgradeOption), random options again |
| 5 WEAPON | 500–502 (upgrade, strengthen, upgradefailcount @+0..2), 503–519 the random-option block (`ItemOptionStorage` @+0x40, FUN_00469a80), 520 CharacterTitleMobID (@+0x19), 521 deletetime (@+0x3B), 522 IsPutOnBelonged (@+3), 523 maxSocketCount (@+0x39), 524 createdSocketCount (@+0x3A), 525 randomOptionChangedCount (@+0x3F). Licence mob kills (3 × {u16 mob, kill count} @+7) go to `p_Item_SetMobList` (one call per slot whose mob ≠ 0xFFFF), the weapon title (@+0x1B, 21 chars) to `p_Item_SetTitle` when not empty; gem sockets live in `tItemEnchant` (§6.2) |
| 6 ARMOR / 7 SHIELD / 8 BOOT | base 600 / 700 / 800: +0 upgrade, +1 strengthen, +2 failcount, +3 option, random options (+11 … +35: up to 8 × {u8 type, u16 value} pairs, FUN_00469a80), +20 deletetime (u32 @+7), +21 IsPutOnBelonged (u32 @+3), +22 randomOptionChangedCount (@+11) |
| 9 FURNITURE | 900–909: LocX, LocY, Direct, LocZ, flag (bit 0), furnicherID, deletetime, dEndureEndTime, nEndureGrade, nRewardMoney |
| 10 DECORATION | 1001 deletetime, 1002 IsPutOnBelonged |
| 13 BINDITEM (teleport scroll) | 1100 portalnum, then 10 × {1110+10n: u16 map, +1: u32 x, +2: u32 y} |
| 15 ITEMCHEST | 1400 (lo nibble = count) / 1401 (hi nibble), 1402–1409: 8 × u64 content keys (@+1 +8n) |
| 18 MINIHOUSESKIN | 1500 (u32) |
| 23 RIDING | 1600–1606: hungrypoint, deletetime, bitflag (15 bits), IsPutOnBelonged, nHP, nGrade, nRareFailCount |
| 26 COSWEAPON / 37 COSSHIELD | 1800 / 1850 (`CostumCharged`, u32) |
| 27 ACTIONITEM | 1900 deletetime |
| 29 CAPSULE | 2100 content key (u64 low half @0), 2101 useabletime (@+8) |
| 30 CLOSEDCARD / 31 OPENCARD | 2200–2203 (2202 = a serial taken from `FUN_0046e7e0(&DAT_00a4593c, card id)` when the attribute holds 0, §11.5) / 2300, 2302 |
| 33 NOEFFECT | 2500 (lot u8) |
| 36 PUP (pet) | 2700 (pet number, i32 @0); when ≠ −1 also `usp_Pet_setName(petNo, name[16] @+8)` (§12) |
| 38 BRACELET | 2801–2804 (upgrade, strengthen, failcount, option), random options, 2821 deletetime, 2822 IsPutOnBelonged |
| 11, 16, 17, 28, 32, 34, 35 | nothing (11 SKILLSCROLL, 16 WTLICENCE, 17 KQ, 28 GBCOIN, 32 MONEY, 34 ENCHANT, 35 ACTIVESKILL keep no option rows; ENCHANT/ACTIVESKILL lots go through `ItemLotAfterUse` types 2000/2600 only) |

Load (`CGameDB_Item::GetItemOptions`, name from its log string) has three extra reads: any weapon row 0x1F7–0x207 or 0x209 makes
it read `p_Item_GetMobListAll(key)` (3 licence slots; unused slots 0xFFFF / 0) and `p_Item_GetTitle` (title text, empty when
none); rows 0x20B/0x20C (socket counts) make it read `usp_Item_Get_EnchantAll(key)` rows `{u8 nSlot, u32 nGemItemID, u8
nRestCount}` into `gemSockets[nSlot]` (slots preset to 0xFFFF/0xFF; gem id ≥ 0xFFFF → log "Invalid Gem Item., ShineItemID = %u" and
stop, slot > 2 → "Too many socket exists., Key = %I64d" and stop); type 0xA8C (pet) with a pet number ≠ −1 reads `usp_Pet_getInfo`
(§12) and copies the pet name (16 chars) to attr+8.
Rows of an unknown type are logged and skipped. `ItemAttr_SaveRandomOptions` @ FUN_00469a80 writes the random-option block (`ItemOptionStorage`): one row for the header byte
(element count = header >> 1), then two rows (kind, value) per element, at most 8 elements.

### 1.4 Item lists sent to the zone

```pseudo
ItemRecords(list, out buf, out len)                                @ FUN_00402e50
    buf[2] = count; records from buf+3:
    per listed item: attr = CGameDB_Item::GetItemOptions(key)      (§1.3)
        failure → return at once without setting `len`: the caller appends a stale length (original bug) D03-B17
        record = { u8 datasize, cell (type << 10 | slot), u64 key, u16 itemId, attr[class size] }
            # class size from the ItemAttributeClassContainer (DAT_006ef2e8, FUN_0044d380 "…operator [] : Invalid item class"),
            # copied by the class's vtable+4 writer (FUN_0044d300); datasize = record length − 1
    len = end − buf                                                  # includes the 3 header bytes
```

Used by the storage opens (§5). Same layout as the item lists of D02 §10 (`PROTO_ITEMPACKET_TOTAL` + `SHINE_ITEM_VAR_STRUCT`).

### 1.5 Holy-promise cen reward

After a successful purchase that cost cen (NPC buy all/lot, soul stones, capsule with price ≠ 0):

```pseudo
usp_HolyPromise_setMoney(charNo, nRewardMoney = price × 100 / 1000, nLevelGap = 10)          @ wrapper FUN_00457bd0
    # (db-backup, KR "cen use reward 2009.4 By Luunar"): the buyer's upper member (tHolyPromise.nUpCharNo, not deleted) gets a
    # tHolyPromiseReward row {nType 1, nMoney = reward, nRemainMoney += reward}; only if upper.level − my.level ≥ 10.
    # nRet: 0 ok, -2211 charNo ≤ 0, -2212 reward ≤ 0, -2221 no upper member, -2222 upper deleted/level 0, -2223 level gap,
    # -2292 insert error. The handler ignores the result.
```

So 10 % of every cen purchase is credited to the mentor's reward box (paid out by D04's holy-promise handlers). Repurchase (§2.2),
item-money and guild-token purchases give no reward.

## 2. Shop (CParserCharacter, registered @ FUN_0043b040)

Client handling of every code below: Z05 §10 (`0x3004` BUY_ACK: `0x205`/`0x207` "Not enough money to buy the item.", other
`0x20x` codes of this section silent; `0x3005` SELL_ACK: anything but `0x381` → "Failed to sell the item.").

### 2.1 NPC purchase

```pseudo
0x340A NC_ITEMDB_BUYALL_REQ { hdr, PROTO_ITEM_CREATE itembuy {u32 owner @6, MAPPOS map @0xA, cell @0x1E, key @0x20,
        u16 itemid @0x28, u16 attr @0x2A}, u16 lock @0x2C, u64 price_cen @0x2E, u32 price_fame @0x36, u32 price_gamblecoin @0x3A,
        u32 UserNo @0x3E, u16 Vendor @0x42, attr[] @0x44 }          @ FUN_00409300
    # 2016 has no CharID[30]/CharLevel (2017 adds them before attr)
    r = ItemBuy_Create(rec{key, owner, cell, itemid}, attr, price_cen, price_fame, price_gamblecoin)            (§1.2)
    if r == 0:
        Send 0x340B NC_ITEMDB_BUYALLSUC_ACK { hdr, u16 lock }                                                  # 8 bytes
        Log 0x0448 NC_LOG_GAME_ITEM_BUY { owner, u8 0, itemid, key, lot (ItemLotAfterUse), cell, price_cen }    # 0x17
        Log 0xC80D NC_SYSLOG_CHAR_ITEM_BUY { UserNo, owner, itemid, u64 price_cen, Vendor }                    # 0x14
        usp_HolyPromise_setMoney(owner, price_cen / 10, 10)                                                   (§1.5)
    else:
        log the request; Send 0x340C NC_ITEMDB_BUYALLFAIL_ACK { hdr, u16 err, u16 lock }
            err = 0x205 if r == 1 (not enough cen/fame/coins) else 0x206 (DB error, or r == 2 "all prices ≤ 0", (db-backup))

0x340D NC_ITEMDB_BUYLOT_REQ { hdr, u16 lock @6, PROTO_ITEM_ATTRCHANGE {key @8, u16 attr @0x10, cell @0x12}, u16 itemid @0x14,
        u64 price_cen @0x16, u32 price_fame @0x1E, u32 price_gamblecoin @0x22, u32 UserNo @0x26, u16 Vendor @0x2A, attr[] @0x2C }
                                                                    @ FUN_004096d0
    if !ItemLotAfterUse(itemid, attr, out newLot, out optType): err = 0x209 → fail
    r = p_Item_BuyLot(key, owner = charNo, optType, newLot, price_cen, fame, coin)                 @ wrapper (8 params)
        # (db-backup, w00 only = 8 params; Character.bak 7) same money/fame/coin transaction as BuyAll, then
        # p_Item_SetOption(key, optType, newLot): the zone sends the stack's lot after the purchase; error → rollback, its code
    r == 0: Send 0x340E NC_ITEMDB_BUYLOTSUC_ACK { hdr, u16 lock }; Log 0x0448 {…, lot = newLot}; Log 0xC80D; holy-promise reward
    else: err = 0x207 if r == 1 else 0x208 → Send 0x340F NC_ITEMDB_BUYLOTFAIL_ACK { hdr, u16 err, u16 lock }
```

The DB never compares the zone's new lot with the stored one: a buy-lot request sets the stack to whatever lot the zone sends.

### 2.2 Sell and repurchase

```pseudo
0x3422 NC_ITEMDB_SELLALL_REQ { hdr, u16 lock @6, PROTO_ITEM_VANISH {key @8, cell @0x10}, u32 price @0x12, u16 itemid @0x16,
        u32 UserNo @0x18, u16 Vendor @0x1C, u64 nLot @0x1E, u8 nDeleteChestItem @0x26, PROTO_ITEM_VANISH DeleteChestItem[] @0x27 }
                                                                    @ FUN_00409a20 (`CPFsCharacter::fc_NC_ITEMDB_SELLALL_REQ`)
    optType = ItemLotOption-style switch on the class (1/2/3/300/4/2500/2000/2600; any other class or unknown id → 1)
    p_Item_SellAll_LotCheck(key, owner = charNo, optType, nLot, (u64) price, out nRet)           @ wrapper
        # (db-backup) p_Item_IsValidOwner(key, owner): 1 no item, 2 other owner → that code; if nLot > 1: stored lot of optType
        # missing → 4, stored lot < nLot → 5; then in a transaction p_Char_MoneyAdd(price) (fail → 3), p_Item_Delete(key)
    nRet 0:
        Send 0x3423 NC_ITEMDB_SELLALLSUC_ACK { hdr, u16 lock }
        Log 0x0449 NC_LOG_GAME_ITEM_SELL { charNo, u8 0, itemid, key, u16 0, cell, price }
        for i < min(nDeleteChestItem, 8): p_Item_Delete(DeleteChestItem[i].key)       # contents of a sold chest; errors logged
            ("ERROR - CPFsCharacter::fc_NC_ITEMDB_SELLALL_REQ, CHEST INVEN : DBError=%d, Owner=%d, ItemKey=%I64d")
        Log 0xC80E NC_SYSLOG_CHAR_ITEM_SELL { UserNo, charNo, itemid, u64 price, Vendor }
    else: Send 0x3424 NC_ITEMDB_SELLALLFAIL_ACK { hdr, u16 err, u16 lock }
        err: 1 → 0x386 (no item), 2 → 0x387 (other owner), 3 → 0x388 (money), else → 0x389

0x3425 NC_ITEMDB_SELLLOT_REQ { hdr, u16 lock @6, PROTO_ITEM_ATTRCHANGE {key @8, u16 attr, cell @0x12}, u16 itemid @0x14,
        u32 price @0x16, u32 UserNo @0x1A, u16 Vendor @0x1E, attr[] @0x20 }                     @ FUN_00409ec0
    if !ItemLotAfterUse(itemid, attr, out newLot, out optType): err = 0x38E → fail
    r = p_Item_SellLot_LotCheck(key, charNo, optType, newLot, price)
        # (db-backup) owner check (1/2); stored lot missing → 4; stored lot < newLot → 5; MoneyAdd → 3; p_Item_SetOption(newLot)
    r 0: Send 0x3426 NC_ITEMDB_SELLLOTSUC_ACK { hdr, u16 lock }; Log 0x0449 {…, lot = newLot}; Log 0xC80E
    else: err 1 → 0x38A, 2 → 0x38B, 3 → 0x38C, other → 0x38D; Send 0x3427 NC_ITEMDB_SELLLOTFAIL_ACK { hdr, u16 err, u16 lock }
```

The sold lot is not checked: `SellLot` only refuses when the stored stack is *smaller* than the remaining lot the zone sends, so
the zone decides both how many items go and how much cen comes in (the price is never compared with ItemInfo).

```pseudo
0x34B9 NC_ITEMDB_REPURCHASE_ALL_REQ { u16 handle @0, u32 charNo @2, u16 lock @6, PROTO_ITEM_CREATE {owner @8, map, cell @0x20,
        key @0x22, itemid @0x2A, attr16 @0x2C}, u32 nPrice @0x2E, u64 nSellItemKey @0x32, u32 UserNo @0x3A, u16 Vendor @0x3E,
        attr[] @0x40 }                                              @ FUN_0042e060
    r = ItemBuy_Create(rec{key, owner, cell, itemid}, attr, price = nPrice, fame 0, coin 0)      # a NEW item with the zone's key
    r 0: err = 0x3668
        Log 0x07FD NC_LOG_GAME_DATA_TYPE_L { u32 0x7F8 (sub-type), charNo, u32 0, itemid, key, lot, cell, u64 nSellItemKey, … }   # 0x2C
        Log 0xC815 NC_SYSLOG_CHAR_ITEM_REBUY { UserNo, charNo, itemid, nPrice, u32 0, Vendor }
    r 1: err = 0x366E; other: err = 0x366F (both logged "Item Repurchase DB Error - (…)")
    Send 0x34BA NC_ITEMDB_REPURCHASE_ALL_ACK { u16 handle, u32 charNo, u16 err, u16 lock }

0x34BB NC_ITEMDB_REPURCHASE_LOT_REQ { u16 handle, u32 charNo, u16 lock @6, u16 nItemID @8, PROTO_ITEM_ATTRCHANGE {key @0xA,
        attr16, cell @0x14}, u32 nPrice @0x16, u64 nSellItemKey @0x1A, u32 UserNo @0x22, u16 Vendor @0x26, attr[] @0x28 }
                                                                    @ FUN_0042e380
    if ItemLotAfterUse(nItemID, attr, out newLot, out optType) != 1: err = 0x209   # a buy code, not a 0x366x one
    else r = p_Item_BuyLot(key, charNo, optType, newLot, price = nPrice, 0, 0):
        0 → err 0x3668; Log 0x07FD {0x7F8, …}; Log 0xC815     1 → 0x366E     other → 0x366F
    Send 0x34BC NC_ITEMDB_REPURCHASE_LOT_ACK { u16 handle, u32 charNo, u16 err, u16 lock }
```

The sold item's key (`nSellItemKey`) only goes to the logs: the sold row was deleted by SELL (§2.2), the zone's repurchase list is
memory only (Z05 §2.2), and nothing in the DB ties the repurchase to an earlier sale. `0x366E`/`0x366F` are not texts the
2016 client shows (Z05 §10: `0x366b` level, `0x366c` money, `0x366d` full); a failed repurchase is silent (original bug)
D03-B2.

### 2.3 Guild-token purchase (into guild storage)

```pseudo
0x3490 NC_ITEMDB_GUILD_TOKEN_BUYALL_REQ { hdr, u32 nNo (guild) @6, PROTO_ITEM_CREATE ItemBuy {owner @0xA, map, cell @0x22,
        key @0x24, itemid @0x2C, attr16 @0x2E}, u16 lock @0x30, u32 nPriceGuildToken @0x32, attr[] @0x36 }   @ FUN_00420250
    r = ItemGuildTokenBuy_Create(rec{key, owner = nNo, cell, itemid}, attr, price, out attrErr)            (§1.2)
        # the item row is owned by the GUILD number (guild storage, Z04 §2.3), tokens come from tGuildToken[nNo]
    if attrErr:                                                       # attribute write failed after the purchase committed
        usp_Guild_GetToken(nNo, out token); usp_Guild_SetToken(nNo, token + price)   # refund, logged
    r 0: Send 0x3491 NC_ITEMDB_GUILD_TOKEN_BUYALLSUC_ACK { hdr, u16 lock, u32 nNo, u32 price }           # 0x10
         Log 0x0448 { charNo = ItemBuy.owner, … , lot, cell, price }
    else: err = 0x205 if r == 1 else 0x206; Send 0x3492 …BUYALLFAIL_ACK { hdr, u16 err, u16 lock }

0x3493 NC_ITEMDB_GUILD_TOKEN_BUYLOT_REQ { hdr, u16 lock @6, u32 nNo @8, PROTO_ITEM_ATTRCHANGE {key @0xC, attr16, cell @0x16},
        u16 nItemID @0x18, u32 nPriceGuildToken @0x1A, attr[] @0x1E }                                    @ FUN_00420710
    !ItemLotAfterUse(nItemID, attr) → err 0x209
    r = usp_Item_GuildToken_BuyLot(key, nNo, optType, newLot, price)
        # (db-backup) transaction: usp_Guild_TokenSub(nNo, price) ≠ 0 → nRet 1; p_Item_SetOption(newLot)
    r 0: Send 0x3494 …BUYLOTSUC_ACK { hdr, u16 lock, u32 nNo, u32 price }; Log 0x0448
    else: err 0x207 (r 1) / 0x208; Send 0x3495 …BUYLOTFAIL_ACK { hdr, u16 err, u16 lock }
```

`usp_Guild_GetToken` (*db-backup*): `nToken = ISNULL(MAX(nToken), 0)`, nRet stays 0 on success (−1 on error; the header comment
says 1 = OK). The handler treats a 0 return as success. The zone, on the SUC answer, also sends `0x74C0
NC_GUILD_ZONE_USE_GUILD_TOKEN_CMD {guild, price}` to the WM (Z05 §2.3), so the balance the WM keeps in memory is lowered once
more there; whether the WM writes it back is W03's.

### 2.4 Soul stones

```pseudo
0x3441 NC_ITEMDB_SOULSTONEBUY_REQ { hdr, u32 chrregnum @6, u8 flag @0xA, u16 number @0xB, u64 price @0xD, u16 lock @0x15 }
                                                                    @ FUN_0040d940
    ok = p_Char_MoneySub(chrregnum, price)
    ok: raw frame { u8 0x0A, u16 0x3442 NC_ITEMDB_SOULSTONEBUYSUC_ACK, hdr, u16 lock }
        usp_HolyPromise_setMoney(hdr.charNo, price / 10, 10)
    else: raw frame { u8 0x0C, u16 0x3443 NC_ITEMDB_SOULSTONEBUYFAIL_ACK, hdr, u16 lock, u16 err 0x744 }
```

Only the cen is written here. `flag` (HP/SP) and `number` are not used by the Character server: the stone counts reach the DB
only with the character save (`tCharacter.nHPS/nSPS`, D02 §6). A crash between the two loses the stones but keeps the payment.
No GameLog entry is written (the zone logs `0x0458 SOULSTONEBUY`, Z05 §2.4 / D05).

### 2.5 Capsule purchase

```pseudo
0x34A0 NC_ITEMDB_BUYCAPSULE_REQ { hdr, u16 nBuyNpcHandle @6, u16 nLockIndex @8, u16 nMap @0xA, u64 nPrice @0xC, u32 nFame @0x14,
        u32 nGbCoin @0x18, cell CapsuleLocation @0x1C, u64 capsuleKey @0x1E, u16 capsuleItemId @0x26, attr capsuleAttr @0x28,
        u64 contentKey @0x8D, u16 contentItemId @0x95, attr contentAttr @0x97 }      (2016: 0xFA bytes; 2017 PDB has only up to @0x1E)
                                                                    @ FUN_00425900
    answer = 0x34A1 NC_ITEMDB_BUYCAPSULE_ACK { hdr, u16 nBuyNpcHandle, u16 nLockIndex, u16 nError = 0x201 }
    1. Item_Insert(rec{contentKey, owner = charNo, type 10, slot 0, contentItemId}, contentAttr, useEmptySlot = 1)
       # the capsule content is stored as an item of storage type 10 (inferred: the capsule's hidden content box) in a free slot
       fail → p_Item_Delete(content key?) (logged), nError = 0x206
    2. r = ItemBuy_Create(rec{capsuleKey, charNo, CapsuleLocation, capsuleItemId}, capsuleAttr, nPrice, nFame, nGbCoin)
       r ≠ 0 → nError = 0x205 (r 1) / 0x206; p_Item_Delete(contentKey) (logged)
       r 0  → Log 0x044F NC_LOG_GAME_ITEM_CREATE {content}, Log 0x0448 {capsule, …, price}
              if nPrice ≠ 0: usp_HolyPromise_setMoney(charNo, nPrice / 10, 10)
    Send 0x34A1
```

### 2.6 Item-money purchase (paying with an item, e.g. tokens / medals)

No transaction: each step commits on its own, and a failure in the middle leaves the earlier steps done (original bug) D03-B3.

```pseudo
0x34B0 NC_ITEMDB_ITEMMONEY_BUYALL_REQ { u16 nLockIndex @0, u32 nCharRegNum @2, u16 nHandleNum @6, u16 nVendor @8, u32 nUserNo @0xA,
        u64 nItemMoneyKey @0xE, u16 nItemMoneyID @0x16, u32 nDecreaseLot @0x18, u32 nMoneyTotalLot @0x1C, u8 nDeleteItemCount @0x20,
        u8 nCreateItemCount @0x21, CREATE_ITEM_INFO CreateItem[nCreateItemCount] @0x22 {u64 key, u16 itemId, cell, attr} (0x71 each),
        PROTO_ITEM_VANISH DeleteItem[nDeleteItemCount] (after the creates, 10 each) }          @ FUN_0042a6d0
                                                    (`CPFsCharacter::fc_NC_ITEMDB_ITEMMONEY_BUYALL_REQ`)
    err = 0x3240
    if nItemMoneyKey != all-ones:                                   # the money item is a stack that stays (partly used)
        ItemAttr_Load(nItemMoneyKey) fails → err 0x3243 (".. MoneyItem Get Attr Error"), send, stop
        !ItemLotAfterUse(nItemMoneyID, attr, out lot) → 0x3244 ("MoneyItem Not Lot Item"), send, stop
        lot ≤ nDecreaseLot → 0x3244 ("Not Enough MoneyItem"), send, stop      # equal is refused too: a used-up stack is sent as a delete
        ItemLot_Set(lot − nDecreaseLot) fails → 0x3245; ItemAttr_Save(new attr) fails → 0x3245 (send, stop)
    for each DeleteItem: p_Item_Delete(key); failure → logged, err = 0x3246, continue
    for i, c in CreateItem: Item_Insert(rec{c.key, nCharRegNum, c.cell, c.itemId}, c.attr, useEmptySlot = (i != 0))
        failure → log "… Item Create Error …", err 0x3242, send now (earlier creates, the deletes and the lot decrease stay)
    Log 0x079C NC_LOG_ITEMMONEY_BUY {charNo, nHandleNum?, CreateItem[0] itemId/key/lot, nItemMoneyID, nMoneyTotalLot …}  # 0x1A
    Log 0x044F for every further created item; Log 0xC814 NC_SYSLOG_CHAR_ITEMMONEY_BUY {nUserNo, charNo, itemId, lot, …}
    if money key given: Log 0x0459 NC_LOG_GAME_ITEM_USELOT {charNo, moneyKey, nItemMoneyID, lot − nDecreaseLot}
    Log 0x045A NC_LOG_GAME_ITEM_USEALL per deleted item
    Send 0x34B2 NC_ITEMDB_ITEMMONEY_BUY_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 err }   # 0x3240 = success

0x34B1 NC_ITEMDB_ITEMMONEY_BUYLOT_REQ { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nVendor, u32 nUserNo, u64 nItemKey @0xE,
        u16 nItemID @0x16, u32 nAddLot @0x18, u32 nMoneyTotalLot @0x1C, u64 nItemMoneyKey @0x20, u16 nItemMoneyID @0x28,
        u32 nDecreaseLot @0x2A, u8 nDeleteItemCount @0x2E, PROTO_ITEM_VANISH DeleteItem[] @0x2F }          @ FUN_0042aeb0
    same money-item step as BUYALL (on nItemMoneyKey / nItemMoneyID / nDecreaseLot; codes 0x3243 / 0x3244 / 0x3245)
    deletes as BUYALL (0x3246)
    target stack: ItemAttr_Load(nItemKey) fails → 0x3243; not a lot item → 0x3244;
                  ItemLot_Set(lot + nAddLot) fails → 0x3245; ItemAttr_Save fails → 0x3245
    success: Log 0x079C, 0xC814, 0x0459 (money item), 0x045A per delete
    Send 0x34B2 { nLockIndex, nCharRegNum, nHandleNum, err }
```

`0x3241` and `0x3247` are never produced here. The zone tests only `0x3240` and replaces every other code by `0x3241` in `0x3004`
(Z05 §2.6), so the DB codes `0x3242`–`0x3246` never reach the client.

## 3. Inventory: equip, move, stack, drop, pick, money

Answers here are mostly hand-built raw frames (`Session_SendRaw`, `{u8 len, u16 op, payload}`) with the same payload the
`CSendPacket` ones would have. Fail answers are `{hdr, u16 err, u16 lock}` unless stated. The zone applies drop / pick / money
before the DB answer and disconnects on any failure (Z05 §3, style 2), so for those requests the error code only reaches logs.

Lot checks used below: `Item_GetLot(key, optType, out lot)` @ FUN_00403800 (`p_Item_GetOption` @ FUN_00468170; logs "ERROR -
GetItem_Option : GetItemOption Error ItemKey[%I64d]" and returns 0 when the row is missing). A stack request is accepted only when
the stored lot equals the lot the zone believes and the result is ≤ `ItemInfo.MaxLot` (row +0x6A). `p_Item_IsValidOwner(key,
owner, out nRet)` *(db-backup)*: 0 ok, 1 no such item, 2 other owner (the handlers also map a 3, which the procedure never returns).

### 3.1 Equip / unequip

```pseudo
0x3410 NC_ITEMDB_EQUIP_REQ { hdr, PROTO_ITEM_RELOC relocA {key @6, newloc @0xE}, u16 relocA_ItemID @0x10,
        u32 relocA_IsPutOnBelonged @0x12, PROTO_ITEM_RELOC relocB {key @0x16, newloc @0x1E}, u16 lock @0x20, u8 unequipnum @0x22,
        { u64 item, u8 invenslot } unequip[unequipnum] @0x23 }        @ FUN_0040a8f0 (`CPFsCharacter::fc_NC_ITEMDB_EQUIP_REQ`)
    # A = the item being equipped (newloc = equip cell), B = the item it replaces (newloc = A's old cell) or key all-ones
    for each unequip[i]: p_Item_SetStorage(item, type 9 (inventory), invenslot) == 0 → err 0x28A
        # (db-backup) UPDATE tItem SET type/slot WHERE key; nRet = @@ROWCOUNT
    if relocA_IsPutOnBelonged == 1:                                  # equipping binds the item ("belonged on equip")
        relocA_ItemID == 0xFFFF → log "… ItemDataBox::ItemDataBoxIndex = NULL (nItemID=%d)", err 0x294
        id out of range / row id mismatch → same log, err 0x28A; row data NULL → log "… pidbi->data = NULL", err 0x28A
        belongType = by class: AMULET 0x1AA, WEAPON 0x20A, ARMOR 0x26D, SHIELD 0x2D1, BOOT 0x335, DECORATION 0x3EA, RIDING 0x643,
                     BRACELET 0xB06 (the `IsPutOnBelonged` option of §1.3); other classes → err 0x28A
            # kept in the global DAT_006edd58, shared by all session-worker threads (original bug) D03-B4
        if relocB.key == all-ones:
            ok = usp_Item_setPutOnBelonged(relocA.key, newloc type/slot, belongType, data = IsPutOnBelonged (1))
                # (db-backup, w00 only, kodong 2009.9): move + UPSERT the option row; nRet 0 ok, -2593 update, -2592 insert
        else:
            ok = usp_Item_setPutOnBelongedExchange(A.key, A.newloc, B.key, B.newloc, belongType, 1)        @ FUN_00464710
                # (db-backup) A → temp type 11, B → B.newloc, A → A.newloc, UPSERT A's option; the wrapper is true only for nRet 0
            nRet 1/2/3 → 0x28B/0x28C/0x28D (dead: nRet is 0 whenever the wrapper returns true)
            p_Guild_GetMyNo(charNo) (result unused)
        ok: Log 0x0554 NC_LOG_GAME_ITEM_PUT_ON_BELONGED { charNo, A.key, B.newloc?, A.newloc } → success
        else err 0x28A
    else if relocB.key != all-ones:
        p_Item_ExchangeStorage(A.key, A.newloc, B.key, B.newloc, out nRet)      @ FUN_004620c0
            # (db-backup) one transaction: A → type 11 (temp), B → B.newloc, A → A.newloc; nRet 1–3 = failing step
        wrapper false → 0x28A; nRet 1 → 0x28B, 2 → 0x28C, 3 → 0x28D; 0 → p_Guild_GetMyNo (unused) → success
    else:
        p_Item_SetStorage(A.key, A.newloc) == 0 → 0x28A
    success: Send 0x3411 NC_ITEMDB_EQUIPSUC_ACK { hdr, u16 lock }
    fail:    Send 0x3412 NC_ITEMDB_EQUIPFAIL_ACK { hdr, u16 err, u16 lock }
    # the unequip[] moves are not undone when a later step fails (no transaction across the calls)

0x3413 NC_ITEMDB_UNEQUIP_REQ { hdr, PROTO_ITEM_RELOC unequ {key @6, newloc @0xE}, u16 lock @0x10, cell equloc @0x12 }
                                                                    @ FUN_0040afc0
    p_Item_SetStorage(unequ.key, newloc) != 0 → Send 0x3414 NC_ITEMDB_UNEQUIPSUC_ACK { hdr, u16 lock }
    else Send 0x3415 NC_ITEMDB_UNEQUIPFAIL_ACK { hdr, u16 err = 0x28A, u16 lock }
        # an EQUIP code (the zone reads the lock at the err offset, Z05-B5) (original bug) D03-B5
```

Owners are never checked on equip/unequip: the zone's keys are trusted. `0x3411` is the only success the zone turns into
`0x3011 {0x281}`, for unequip too (Z05-B2).

### 3.2 Relocation and exchange (inventory ↔ storage ↔ other owner)

```pseudo
0x3428 NC_ITEMDB_RELOC_REQ { hdr, u32 ownerA @6, u32 ownerB @0xA, u16 lock @0xE, PROTO_ITEM_RELOC item {key @0x10, newloc @0x18},
        cell inven_from @0x1A, u16 nFromItemID @0x1C, u32 nFromItemLot @0x1E }                          @ FUN_0040a1e0
    key == all-ones → err 0x245
    p_Item_IsValidOwner(key, ownerA): 1 → 0x247, 2 → 0x248, 3 → 0x249
    if nFromItemLot > 1: !(ItemLotOption(nFromItemID) and Item_GetLot(key) == nFromItemLot ≤ MaxLot) → 0x249
    guildNo = p_Guild_GetMyNo(hdr.charNo)                              # only for the log
    p_Item_SetStorageAndOwner(key, owner = ownerB, newloc type, slot) (flag 0 = fixed slot) false → 0x249   @ FUN_00461fc0
        # (db-backup) UPDATE tItem SET nOwner, type, slot; nRet = @@ROWCOUNT
    unless both cells are type 9 (inventory): Log 0x044C NC_LOG_GAME_ITEM_INVEN_MOVE { charNo, key, from cell, to cell, guildNo }
    raw { 0x0A, 0x3429 NC_ITEMDB_RELOCSUC_ACK, hdr, u16 lock }        |  fail raw { 0x0C, 0x342A RELOCFAIL_ACK, hdr, u16 err, u16 lock }

0x342B NC_ITEMDB_EXCHANGE_REQ { hdr, u32 ownerA @6, u32 ownerB @0xA, u16 lock @0xE, PROTO_ITEM_RELOC relocA {key @0x10, newloc @0x18},
        PROTO_ITEM_RELOC relocB {key @0x1A, newloc @0x22}, u16 relocA_ID @0x24, u16 relocB_ID @0x26, u32 relocA_Lot @0x28,
        u32 relocB_Lot @0x2C }                                         @ FUN_0040a4b0
    A.key all-ones → 0x844; IsValidOwner(A, ownerA): 1 → 0x846, 2 → 0x848, 3 → 0x84A
    B.key all-ones → 0x845; IsValidOwner(B, ownerB): 1 → 0x847, 2 → 0x849, 3 → 0x84B
    each lot > 1 must equal the stored lot and be ≤ MaxLot, else 0x84F
    p_Item_ExchangeStorageAndOwner(A.key, owner ownerB, A.newloc, B.key, owner ownerA, B.newloc, out nRet)   @ FUN_004621c0
        # A goes to B's owner and B to A's (swap across inventory/storage); (db-backup) transaction via temp type 11, nRet 1–3 = step
        wrapper false → 0x84F; nRet 1 → 0x84C, 2 → 0x84D, 3 → 0x84E
    p_Guild_GetMyNo(charNo); unless both cells type 9: Log 0x044C for A and for B
    raw { 0x0A, 0x342C EXCHANGESUC_ACK, hdr, lock } | fail raw { 0x0C, 0x342D EXCHANGEFAIL_ACK, hdr, err, lock }
```

### 3.3 Merge and split

```pseudo
0x342E NC_ITEMDB_MERGE_REQ { hdr, u32 ownerA @6, u32 ownerB @0xA, u16 lock @0xE, u16 itemid @0x10, u64 lotmain @0x12, u64 lotsub @0x1A,
        u32 nMainLot @0x22, u32 nSubLot @0x26 }                       @ FUN_0040bbb0
    optType = the class's lot option (1/2/3/300/4/2500/2000/2600); unknown id or no lot class → 0x402
    stored lots of main and sub must equal nMainLot / nSubLot and their sum ≤ MaxLot, else 0x407
    p_Item_Merge_New(ownerFrom = ownerA, ownerTo = ownerB, keyFrom = lotsub, keyTo = lotmain, optType, out subLot, out resultLot)
        # (db-backup, KR 2007.11) owner checks (1/2 from, 3/4 to), read both lots (5/6), transaction: SetOption(to, sum) (7),
        # p_Item_Delete(from) (8)
    0: raw { 0x14, 0x342F NC_ITEMDB_MERGESUC_ACK, hdr, u16 lock, u64 lotmain, u16 MergeResultLot = (u16) resultLot }
       Log 0x0456 NC_LOG_GAME_ITEM_MERGE { charNo, "Need", itemid, main key, sub key, 0, subLot, resultLot }
    1 → 0x403, 2 → 0x404, 3 → 0x405, 4 → 0x406, 5 → 0x40E, 6 → 0x40F, 7 → 0x410, 8 → 0x411, other → 0x407
    fail raw { 0x0C, 0x3430 MERGEFAIL_ACK, hdr, err, lock }

0x3431 NC_ITEMDB_SPLIT_N_MERGE_REQ { hdr, u16 lock @6, u16 Itemid @8, u16 MoveLot @0xA, u32 FromOwner @0xC, u64 FromItemKey @0x10,
        u32 ToOwner @0x18, u64 ToItemKey @0x1C, u32 nFromItemLot @0x24, u32 nToItemLot @0x28 }     @ FUN_0040c000
    MoveLot == 0 → 0x412; no lot class → 0x408
    stored lots == nFromItemLot / nToItemLot, both ≤ MaxLot and storedTo + MoveLot ≤ MaxLot, else 0x40D
    p_Item_Split_N_Merge_New(FromKey, FromOwner, optType, out fromLot, ToKey, ToOwner, optType, out toLot, MoveLot)
        # (db-backup) owner checks 1–4, from lot read 5, from < MoveLot 6, to lot read 7, transaction: set from (8), set to (9)
    0: raw { 0x20, 0x3432 SPLIT_N_MERGESUC_ACK, hdr, u16 lock, u64 FromItemKey, u64 ToItemKey, u16 MoveLot, u16 ResultLotFrom,
             u16 ResultLotTo }; Log 0x0456 { …, MoveLot, fromLot, toLot }
    1 → 0x409, 2 → 0x40A, 3 → 0x40B, 4 → 0x40C, 5 → 0x413, 6 → 0x414, 7 → 0x415, 8 → 0x416, 9 → 0x417, other → 0x40D
    fail raw { 0x0C, 0x3433 SPLIT_N_MERGEFAIL_ACK, hdr, err, lock }

0x3434 NC_ITEMDB_SPLIT_REQ { hdr, u32 ownerA @6, u32 ownerB @0xA, u16 lock @0xE, u16 itemid @0x10, u64 lotmain @0x12,
        PROTO_ITEM_CREATE lotcreate {owner @0x1A, map, cell @0x32, key @0x34, itemid @0x3C, attr16 @0x3E}, u16 splitlot @0x40,
        u16 MainLot @0x42 }                                            @ FUN_004104b0
    no lot class → 0x444; stored lot ≠ MainLot or MainLot > MaxLot or splitlot > MaxLot → 0x449
    attr = ItemAttr_Load(lotmain) fails → 0x44B
    lot = ItemLotAfterUse(lotcreate.itemid, attr); splitlot ≥ lot → 0x44D
    mainAttr = attr with lot − splitlot; newAttr = attr with splitlot (ItemLot_Set) — the new stack copies every other field
    e = ItemAttr_Save(lotmain, mainAttr): 1 → 0x44A, other ≠ 0 → 0x44B
    Item_Insert(rec{lotcreate.key, owner = ownerB, lotcreate.cell, lotcreate.itemid}, newAttr, fixed slot)
        fail → ItemAttr_Save(lotmain, attr) (restore; failure logged) → 0x44B
    ok: raw { 0x14, 0x3435 SPLITSUC_ACK, hdr, u16 lock, u64 lotmain, u16 RemainLot = lot − splitlot }
        Log 0x0457 NC_LOG_GAME_ITEM_SPLIT { charNo, owners, keys, cells, itemid, splitlot, remain }
    fail raw { 0x0C, 0x3436 SPLITFAIL_ACK, hdr, err, lock }
    # no owner check at all (merge and split-n-merge check both owners in the procedure)
```

### 3.4 Drop and pick-up

```pseudo
0x3416 NC_ITEMDB_DROPALL_REQ { hdr, u16 itemid @6, PROTO_ITEM_VANISH dropitem {key @8, cell @0x10},
        SHINE_ITEM_STRUCT echo {u64 key @0x12, u16 itemID @0x1A, attr @0x1C} }  (2016: 0x81 bytes)
                                                                    @ FUN_0040b140 (`fc_NC_ITEMDB_DROPALL_REQ`)
    lot = ItemLotAfterUse(itemid, echo.attr)
    if lot ≥ 2 and !(Item_GetLot(key) == lot ≤ MaxLot): Send 0x3418 { hdr, u16 0x348 }   # a PICK code (the zone ignores it, Z05-B1)
    r = Item_DropAll(key, owner = charNo)                             @ FUN_004628b0
        # p_Item_IsValidOwner → 1/2; then p_Item_Delete → 3 on error; 0 ok
    0: Send 0x3417 NC_ITEMDB_DROPALLSUC_ACK { hdr, echo (0x6F bytes copied from the request) }      # 0x75 bytes
       Log 0x0447 NC_LOG_GAME_ITEM_DROP { charNo, map "Need", key, 0, cell, itemid }
       # the map field of the item logs 0x043F/0x0446/0x0447/0x0456 is the literal "Need" / "Need Cen" (original bug) D03-B11
    else: log "FAILED - fc_NC_ITEMDB_DROPALL_REQ, ItemKey=%I64d, Owner=%d, err=%d, nRet=%d"
          Send 0x3418 NC_ITEMDB_DROPALLFAIL_ACK { hdr, u16 err }  err 1 → 0x306, 2 → 0x307, else 0x308   (no lock field)

0x3419 NC_ITEMDB_DROPLOT_REQ { hdr, u16 itemid @6, PROTO_ITEM_ATTRCHANGE iteminfo {key @8, attr16, cell @0x12},
        { u64 itemregnum @0x14, u32 lot @0x1C } dropitem, u32 nCurLot @0x20 }           @ FUN_0040b4d0
    attr = ItemAttr_Load(key) fails → 0x30B; !ItemLotAfterUse → 0x30C
    storedLot ≠ nCurLot or dropitem.lot ≥ storedLot → 0x310
    r = Item_DropLot(key, owner = charNo, optType, storedLot − dropitem.lot)              @ FUN_00462900
        # IsValidOwner → 1/2; p_Item_SetOption → 3
    0: Send 0x341A NC_ITEMDB_DROPLOTSUC_ACK { hdr }; Log 0x0447 { charNo, "Need", key, 0, 0, dropped lot, cell, itemid }
    1 → 0x309, 2 → 0x30A, other → 0x30B; Send 0x341B NC_ITEMDB_DROPLOTFAIL_ACK { hdr, u16 err }
    # the dropped part (dropitem.itemregnum) is never stored: a partial drop only lowers the stack

0x341C NC_ITEMDB_PICKALL_REQ { hdr, PROTO_ITEM_CREATE {owner @6, map @0xA, cell @0x1E, key @0x20, itemid @0x28, attr16 @0x2A},
        attr[] @0x2C }                                                @ FUN_0040b760
    Item_Insert(rec{key, owner, cell, itemid}, attr, fixed slot)
    0: Send 0x341D NC_ITEMDB_PICKALLSUC_ACK { hdr }; Log 0x0446 NC_LOG_GAME_ITEM_TAKE { owner, "Need", key, 0, itemid }
    else Send 0x341E NC_ITEMDB_PICKALLFAIL_ACK { hdr, u16 0x347 }

0x341F NC_ITEMDB_PICKMERGE_REQ { hdr, u16 itemid @6, u64 itemonfield @8, u32 nCellItemLot @0x10,
        PROTO_ITEM_ATTRCHANGE itempick {key @0x14, attr16, cell @0x1E}, attr[] @0x20 }               @ FUN_0040b980
    !ItemLotAfterUse(itemid, attr, out newLot) → 0x349
    Item_GetLot(itempick.key) must equal nCellItemLot and newLot ≤ MaxLot, else 0x348
    Item_SetLot(itempick.key, optType, newLot) (FUN_00462960 = p_Item_SetOption) ≠ 0 → 0x348
    ok: Send 0x3420 NC_ITEMDB_PICKMERGESUC_ACK { hdr }            (no GameLog entry, unlike PICKALL)
    fail: Send 0x3421 NC_ITEMDB_PICKMERGEFAIL_ACK { hdr, u16 err }

0x3437 NC_ITEMDB_MOB_DROP_CMD { hdr, PROTO_NC_ITEMDB_MOB_DROP_CMD {mobkiller @6, map, key, createitemid @0x26, attr16, dropmobid}, attr @0x2C }
                                                                    @ FUN_0040c4b0
    ItemLotAfterUse(createitemid, attr) and nothing else: no DB write, no log, no answer
    # the mob-drop log (0x0455 NC_LOG_GAME_ITEM_MOB_DROP) is not sent from here (inferred: removed; dead handler)
```

The field item of PICKALL is not checked against anything (a drop is not stored in the DB, §3.4 DROPALL deletes the row), so the
Character server creates whatever item the zone sends.

### 3.5 Money

```pseudo
0x3438 NC_ITEMDB_PICKMONEY_REQ { hdr, u32 owner @6, u64 itemonfield @0xA, u32 cen @0x12 }     @ FUN_0040c500
    p_Char_MoneyAdd(owner, cen)
    ok: Send 0x3439 NC_ITEMDB_PICKMONEYSUC_ACK { hdr, u8 ? }   # size 7: the 7th byte is never written (original bug) D03-B6
        Log 0x0446 { owner, "Need Cen", itemid = DAT_006edd00 (the money item id, inferred), lot = (u16) cen, 0 }
            # map x/y and item key (16 bytes) of this log are never written: stale stack to the GameLog (D03-B6);
            # the request's itemonfield key is unused
    else: Send 0x343A NC_ITEMDB_PICKMONEYFAIL_ACK { hdr, u16 0x641 }

0x347A NC_ITEMDB_INC_DEC_MONEY_REQ { hdr, u32 owner @6, u32 cen @0xA, u8 Positive @0xE }        @ FUN_0040c700
    ok = Positive ? p_Char_MoneyAdd(owner, cen) : p_Char_MoneySub(owner, cen)    # Sub refuses to go below 0 (db-backup)
    ok: Send 0x347B NC_ITEMDB_INC_DEC_MONEYSUC_ACK { hdr, u8 ? }  (7 bytes, last byte unwritten, D03-B6)
        if p_Char_MoneyGet(owner, out now):
            Log 0x0462 NC_LOG_GAME_MONEY_CHANGE { owner, before = now + cen, after = now, cen, 0 }
            # for an increase "before" should be now − cen (original bug) D03-B7
    else: Send 0x347C NC_ITEMDB_INC_DEC_MONEYFAIL_ACK { hdr, u16 0x643 }
```

## 4. Using and changing items

```pseudo
0x343E NC_ITEMDB_USELOT_REQ { hdr, PROTO_CHANGEATTR {key @6, u16 itemid @0xE, u16 attr16 @0x10}, u16 lock @0x12, attr[] @0x14 }
                                                                    @ FUN_0040d5e0
    !ItemLotAfterUse(itemid, attr, out newLot) → err 0x705
    if newLot ≥ 2: require Item_GetLot(key) > newLot and newLot ≤ MaxLot, else 0x706     # the stack must shrink
    e = ItemAttr_Save(key, itemid, attr)                                # the whole attribute, not only the lot
    e == 0: err 0x700; Log 0x0459 NC_LOG_GAME_ITEM_USELOT { charNo, key, itemid, newLot }   else err 0x706
    raw { 0x0C, 0x3440 NC_ITEMDB_USE_ACK, hdr, u16 lock, u16 err }

0x343F NC_ITEMDB_USEALL_REQ { hdr, u64 key @6, u16 lock @0xE, u16 itemid @0x10 }      @ FUN_0040d800
    p_Item_Delete(key) == 0: err 0x700; Log 0x045A NC_LOG_GAME_ITEM_USEALL { charNo, key, itemid }   else 0x707
    raw { 0x0C, 0x3440, hdr, u16 lock, u16 err }
    # no owner check: any key the zone names is deleted

0x3449 NC_ITEMDB_ITEMCHANGE_REQ { hdr, u16 lock @6, u64 itemkey @8, SHINE_ITEM_STRUCT { u16 itemid @0x10, attr @0x12 } }
                                                                    @ FUN_0040e630
    e = ItemAttr_Save(itemkey, itemid, attr)
    raw { 0x0C, 0x344A NC_ITEMDB_ITEMCHANGE_ACK, hdr, u16 lock, u16 err = e ? 0x902 : 0x901 }
```

`ITEMCHANGE` is the generic "rewrite this item's attribute" request (12 zone senders, Z05 §1.7: expiry, pet, title, mount …). The
row's `nItemID` is not changed, only its option rows; an attribute of a different class than the stored item is written under
the new class's option types and the old rows stay (inferred from §1.3; no delete of option rows anywhere in `ItemAttr_Save`).

## 5. Storage

### 5.1 Account storage (shared by the account's characters) and its money

```pseudo
0x3444 NC_ITEMDB_OPENSTORAGE_REQ { hdr, u8 page @6, u32 usrregnum @7, u8 nOpenType @0xB }
                                                                    @ FUN_0040da60 (`CPFsCharacter::fc_NC_ITEMDB_OPENSTORAGE_REQ`)
    p_User_MoneyGet(usrregnum, out cen) fails → log "FAILED - fc_NC_ITEMDB_OPENSTORAGE_REQ, GetUserMoney, nUserNo=%d";
        raw { 0x0A, 0x3445 NC_ITEMDB_OPENSTORAGE_FAIL_ACK, hdr, u16 err }   # the 2 err bytes are never written (D03-B6)
        # (db-backup) p_User_MoneyGet creates the tUserMoney row with 0 when the user has none
    list = StorageList(usrregnum, page)                                 @ FUN_00403180 → FUN_0046a330 → FUN_0046a040
        p_Item_GetListType(owner = usrregnum, type 6) rows {u64 key, u16 slot, u32 itemId, u32, ts}; keep slot in
        [page·36, page·36 + 35], at most 0x240 rows      # account storage = type 6, owned by the USER number, 36 slots a page
        records = ItemRecords(list)                                     @ FUN_00402e50 (§1.4)
    list fails → raw 0x3445 (same, "FAILED - …, Get, nUserNo=%d")
    Send 0x3446 NC_ITEMDB_OPENSTORAGE_ACK { hdr, u8 curpage = page, u8 nOpenType, u64 cen, u8 itemcounter, records }
        (appended with FUN_0044f980; too large → "* FATAL ERROR … OVER MAX PACKET SIZE", nothing sent;
         send failure logged "SEND FAILED")
        # the record bytes are copied from list+3 with the length measured from list+0: 3 bytes of stale stack follow the
        # last record (original bug) D03-B8 (the zone parses by itemcounter)

0x345F NC_ITEMDB_DEPOSIT_REQ / 0x3461 NC_ITEMDB_WITHDRAW_REQ { hdr, u16 lock @6, u32 nUserNo @8, u64 money @0xC }
                                                                    @ FUN_00410fa0 / FUN_00411200
    ok = p_User_Deposit / p_User_Withdraw(nUserNo, charNo, money, out storageMoney, out nRet)
        # (db-backup, CJC 2006.5) tCharacter.nUserNo must be nUserNo (1); transaction: deposit = char MoneySub (2), user MoneyAdd (3),
        # read result (4); withdraw = user MoneySub (2), char MoneyAdd (3), read (4). nRet 0 = ok
    ok: err 0xF80; Log 0x045E NC_LOG_GAME_MONEY_DEPOSIT / 0x045F …_WITHDRAW { nUserNo, charNo, money, storageMoney }
    deposit fail: 1 → 0xF89, 2 → 0xF8A, 3 → 0xF8B, 4 → 0xF8C, else 0xF88
    withdraw fail: 1 → 0xF90, 2 → 0xF91, 3 → 0xF92, 4 → 0xF93, else 0xF94      (logged "FAILED - fc_NC_ITEMDB_…_REQ, …")
    Send 0x3460 NC_ITEMDB_DEPOSIT_ACK / 0x3462 NC_ITEMDB_WITHDRAW_ACK { hdr, u16 lock, u64 storageMoney, u16 err }
        # on failure the u64 is not written (stale stack, D03-B6)
```

The client shows a text for `0xF83` only ("Not enough money to deposit/withdraw", Z05 §10); the DB's not-enough codes are
`0xF8A` / `0xF91`, so a refused deposit or withdrawal is silent (original bug) D03-B9.

Account-storage items are moved in and out with RELOC/EXCHANGE (§3.2): `ownerB` there is the user number for a move into the
account storage and the character number for a move out (inferred from type 6 being listed by user number).

### 5.2 Guild storage

```pseudo
0x3471 NC_ITEMDB_OPEN_GUILD_STORAGE_REQ { hdr, u32 guildNo @6 }   @ FUN_0040dd30 (`CPFsCharacter::fc_NC_ITEMDB_OPEN_GUILD_STORAGE_REQ`)
    p_Guild_Get(guildNo) fails (no row) → log; raw { 0x0A, 0x3472 …_FAIL_ACK, hdr, u16 0x801 }      @ FUN_00453640
        # (db-backup) SELECT sName, sPassword, nMaxMembers, nMoney, nType, nGrade, nFame, nStoneLevel, nExp, dCreateDate,
        # dWarRequestDate, dWarStartDate, dWarEndDate, nWarEnemy, nWarWinCount/LoseCount/DrawCount, nDismissStatus, dDismissDate,
        # dNotifyDate, sNotifyCharID, sNotify, sIntro FROM tGuild (the binary reads the 23 columns in this order)
    usp_Guild_GetToken(guildNo, out token) fails → same 0x3472 {0x801}
    list = ItemList_ByStorage(guildNo, type 4, max 36) → records (§1.4)      @ FUN_00403280 → FUN_0046a380
    list fails → 0x3472 {0x801} ("FAILED - …, Get, nGuildNo=%d")
    Send 0x3473 NC_ITEMDB_OPEN_GUILD_STORAGE_ACK { hdr, u64 cen = tGuild.nMoney, u64 nToken, u8 itemcounter, records } (+3 stale bytes, D03-B8)

0x3474 NC_ITEMDB_GUILD_STORAGE_WITHDRAW_REQ { hdr, u16 lock @6, u32 guildNo @8, u64 money @0xC }    @ FUN_00411460
    p_Guild_MoneySub(guildNo, charNo, money, out memberMoney, out guildMoney, out nRet)
        # (db-backup, Lunar 2007.11) read guild money (1), money > guild money (2); transaction: UPDATE tGuild (3),
        # p_Char_MoneyAdd (4), read member money (5), read guild money (6); 0 ok. No rank/permission check (the zone's)
    ok: err 0x1480; Log 0x04AA NC_LOG_GAME_GUILD_K_MONEY_WITHDRAW { guildNo, charNo, money, guildMoney }
    fail: 1 → 0xF99, 2 → 0xF9A, 3 → 0xF9B, 4 → 0xF9C, 5 → 0xF9D, 6 → 0xF9E, else 0xF98
    Send 0x3475 NC_ITEMDB_GUILD_STORAGE_WITHDRAW_ACK { hdr, u16 lock, u64 guildMoney (stale on failure), u16 err }
```

The client understands `0x1481`–`0x1483` for this answer and shows "You have no authority" for anything else (Z05 §10), so the
DB's `0xF9A` (not enough guild money) reads as a permission error (D03-B9). Guild money is deposited by the WM / D04 (dept 29),
not here; items enter guild storage only through the guild-token shop (§2.3) and leave through RELOC/EXCHANGE.

### 5.3 Guild-academy reward storage

```pseudo
0x3482 NC_ITEMDB_GUILD_ACADEMY_REWARD_STORAGE_OPEN_REQ { hdr, u32 guildregnum @6, u8 nOpenType @0xA }   @ FUN_0041c580
    usp_GuildAcademy_getMoney(guildNo, out nRet) false → raw { 0x0A, 0x3483 …OPEN_FAIL_ACK, hdr, u16 0x17DB }
        # (db-backup, Ko Dong Gyun 2008.5) SELECT nMoney FROM tGuildAcademy WHERE nNo; no row → nRet -1521 and no result set
    cen = first row's i64 (0 when there is no row: the handler does not test nRet)
    list = ItemList_ByStorage(guildNo, type 0, max 100) → records         @ FUN_00403400 → FUN_0046a3f0
    list fails → 0x3483 {0x17DB}
    Send 0x3484 …OPEN_ACK { hdr, u64 cen, u8 nOpenType, u8 itemcounter, records } (+3 stale bytes, D03-B8)

0x3485 …WITHDRAW_REQ / 0x3487 …DEPOSIT_REQ { hdr, u16 lock @6, u32 guildregnum @8, u64 cen @0xC }   @ FUN_0041c880 / FUN_0041caa0
    ok = usp_GuildAcademy_withdrawMoney / depositMoney(guildNo, charNo, cen, out nRet)              (wrapper: nRet == 0)
        # (db-backup) -1511/-1512/-1514 bad guild/char/amount, -1524 character deleted, -1525 no academy row,
        # withdraw: academy money < cen → -1527 (header says -1524); deposit: char money < cen → -1526; -1593 DB
        # (w00 withdraw adds WITH(UPDLOCK, HOLDLOCK) "Modify 2011.7.11"; Character.bak's copy has no lock hint)
    ok: err 0x17E0 / 0x19A0; Log 0x04AA NC_LOG_GAME_GUILD_K_MONEY_WITHDRAW { charNo, guildNo, cen, cen }   (deposits too)
    fail: err 0x17E8 / 0x19A7 (every DB result maps to the one code)
    Send 0x3486 …WITHDRAW_ACK / 0x3488 …DEPOSIT_ACK { hdr, u16 lock, u64 cen = the requested amount (not the new balance), u16 err }
```

Type 0 is the academy reward storage box (Z04 knowledge: "Boxes: 0 guild-academy reward storage"); its items are created by
D04's academy reward handlers and moved out with RELOC.

### 5.4 Premium ("charged") items from the item shop

The item-shop purchases live in the **Account** database (`tChargeItem`); the Character DB reaches them through wrapper procedures
*(db-backup)*: `usp_ChargeItem_GetList(@USER_NO)` = `EXEC Account.dbo.usp_Charge_ItemSelectList` (rows `rowNo, goodsNo, amount,
registerDate` of `tChargeItem WHERE userNo AND isDraw = 0 ORDER BY rowNo`), `usp_ChargeItem_Draw(@ROW_NO, @USER_NO, @RET OUTPUT)` =
`EXEC Account.dbo.usp_Charge_ItemDraw` (sets `isDraw = 1, drawDate`; `@RET` 1 ok, 0 DB error, -1 already drawn, -2 other user).
The `Fixes/ChargeItem (Premium Inventory Slot)` scripts only re-create the same two bodies with `ALTER PROCEDURE` (no change).

```pseudo
0x3463 NC_ITEMDB_CHARGED_LIST_REQ { hdr, u32 nUserNo @6, u16 from @0xA, u16 to @0xC }        @ FUN_004116e0
    part = { nPartMark = 1 (first) }; index = 0
    loop:
        ok = ChargeItem_GetList(nUserNo, &part, &index, from, to)           @ FUN_0046a5a0
            first part: usp_ChargeItem_GetList(nUserNo); failure → mark |= 2, return false
            per row: index++; rows with from ≤ index ≤ to become PROTO_CHARGED_ITEM_INFO { u32 ItemOrderNo = rowNo,
                u32 ItemCode = goodsNo, u32 ItemAmount = amount, ShineDateTime ItemRegisterDate (year − 2000, month, day, hour, min) };
            stop at 0x2000 bytes (one packet); end of rows → mark |= 2 (last part), close cursor
        !ok: Send 0x3464 { hdr, u16 ErrorCode 0x104A, u8 nPartMark, u16 n, items } ; log "FAILED - ChargeItemGetList, …"; stop
        Send 0x3464 NC_ITEMDB_CHARGED_LIST_ACK { hdr, u16 ErrorCode 0x1041, u8 nPartMark, u16 NumOfChargedItem, items[] }  (0xB + 16n)
        mark &= ~1 (not first); until the last part was sent
    # later parts do not call the procedure again: they keep fetching from the open cursor. The row index is advanced per
    # row inside FUN_0046a5a0 and then once more by the part's count in the handler, so on the second and later parts
    # (only with more than 511 rows) the index jumps past `to`, so with from = 0, to = N every row after the first 511 is
    # dropped (original bug) D03-B10

0x3465 NC_ITEMDB_CHARGED_WITHDRAW_REQ { hdr, u16 lock @6, u32 nUserNo @8, PROTO_CHARGED_ITEM_INFO info @0xC {OrderNo, ItemCode,
        Amount, Date}, u8 NumOfItemCreate @0x1C, PROTO_ITEM_CREATE ItemCreate[n] @0x1D (0x26 each), attribute blocks after them }
                                                                    @ FUN_004118a0 (`fc_NC_ITEMDB_CHARGED_WITHDRAW_REQ`)
    err = 0x1041
    for each ItemCreate[i]: Item_Insert(rec{key, owner, cell, itemid}, attr = payload + ItemCreate[i].attr, fixed slot)
        # PROTO_ITEM_CREATE.attr is used as the payload offset of that item's attribute block
        fail → log "ERROR - fc_NC_ITEMDB_CHARGED_WITHDRAW_REQ Create FAILED-(…)", err 0x1049 → undo
    if all created: usp_ChargeItem_Draw(info.ItemOrderNo, nUserNo) must return @RET 1     @ FUN_0046a720
        else err 0x1048, log "FAILED - ChargeItemDraw, nUserNo=%d, nOrderNo=%d, nCharNo=%d" → undo
    undo: p_Item_Delete for every item created so far (errors logged)
    success: Log 0x04BE NC_LOG_GAME_CHARGE_WITHDRAW { charNo, OrderNo, ItemCode, Amount }; Log 0x044F per created item
    Send 0x3466 NC_ITEMDB_CHARGED_WITHDRAW_ACK { hdr, u16 lock, PROTO_CHARGED_ITEM_INFO info (echo), u16 err }
```

The goods number → items mapping is done by the zone (Z04 §8, Z05 §7.4); the Character server creates exactly the items it is
sent, so a modified zone could turn any undrawn row into any items. Draw-after-create keeps one row from being drawn twice: a second
concurrent withdraw of the same row gets `@RET -1` and deletes its items.

## 6. Upgrades, enchanting and item services

Several services share one "consume one item of a stack" step (`ConsumeOne`, inline in each handler; ours):

```pseudo
ConsumeOne(stuffKey, stuffId, expectedRemaining) → ok / fail
    attr = GetItemOptions(stuffKey) fails → fail ("… Get Attr Error")
    !ItemLotAfterUse(stuffId, attr, out lot) → fail ("Not Lot Item")      (MIX: a non-stack counts as lot 1)
    lot == 0 → fail ("Invalid Item Option")
    lot − 1 ≠ expectedRemaining → fail ("Not Matching … Lot")            # the zone sends the lot AFTER use
    lot − 1 == 0 → p_Item_Delete(stuffKey) (Log 0x045A)  else ItemLot_Set(lot − 1) + ItemAttr_Save (Log 0x0459)
```

None of the services below runs in one transaction: each `p_Item_*` call commits by itself, so a failure after `ConsumeOne`
keeps the consumed item (original bug) D03-B3 (also item-money §2.6, random-option recover, class change, mix, friend points).

### 6.1 Upgrade (`p_Item_Upgrade_CelllInAll`)

```pseudo
p_Item_Upgrade_CelllInAll(@nOwner, @nItemKey, @nItemDestroy, @nUpgradeOptionType, @nUpgradeOptionValue, @nUpgradeFailCountType,
    @nUpgradeFailCountValue, @nRawKey, @nRawLeftKey, @nRawRightKey, @nRawMiddleKey, @nGiftMoney, then {OptionType, Lot} for raw,
    left, right, middle, OUT @nRet)                         (db-backup, KR "2008.2 By Lunar", same text in both backups; 21 params = binary)
    IsValidOwner(item) → 1/2; transaction: gift money > 0 → p_Char_MoneySub (3); destroy == 1 → p_Item_Delete(item) (4) else
    SetOption(upgrade type, value) and SetOption(fail-count type, value) (4); each raw key ≠ 0: lot 1 → delete, lot > 1 →
    SetOption(type, lot − 1) (5 raw, 6 left, 7 right, 8 middle); commit, 0
ItemUpgradeOptionTypes(itemId, out upgradeType, out failCountType, out strengthenType)      @ FUN_00403cd0
    AMULET 0x1A2/0x1A4/0x1A3, WEAPON 500/502/501, ARMOR 600/602/601, SHIELD 700/702/701, BOOT 800/802/802, BRACELET 0xAF1/0xAF3/0xAF2
    other classes → 0. (BOOT's strengthen type is the fail-count type 802; no caller uses the third output, so no effect.)

0x3447 NC_ITEMDB_UPGRADE_REQ { hdr, u16 lock @6, u64 upgrade_item_regnum @8, u16 upgrade_item_id @0x10, u8 adj_level @0x12,
        u8 destroy @0x13, u8 new_level @0x14, u8 fail_count @0x15, u64 raw @0x16, u64 raw_left @0x1E, u64 raw_right @0x26,
        u64 raw_middle @0x2E, u64 gift_money @0x36, u16 raw_item_id @0x3E, u16 left_id @0x40, u16 right_id @0x42, u8 raw_lot @0x44,
        u8 left_lot @0x45, u8 right_lot @0x46, u16 middle_id @0x47, u8 middle_lot @0x49, u8 ro_enable @0x4A, u8 ro_count @0x4B,
        u16 ro_value @0x4C }   (2016 layout read from the code; the 2017 struct differs after @0x3E)
                                                                    @ FUN_0040e0d0 (`fc_NC_ITEMDB_UPGRADE_REQ`)
    raw option types = ItemLotOption(raw ids) (0xFFFE when the id is 0xFFFF or not a stack)
    !ItemUpgradeOptionTypes(upgrade_item_id) → err 0x8C8
    r = p_Item_Upgrade_CelllInAll(charNo, key, destroy, upgradeType, new_level, failCountType, fail_count, raws, gift_money, …)
    if ro_enable == 1 and r == 0:                                    # amulet random options re-rolled by the zone
        ro_count > 14 → r = 1; item class ≠ AMULET → r = 1
        attr = GetItemOptions(key) (fail → r = 9, "FAILED - fc_NC_ITEMDB_UPGRADE_REQ, Get upgrade item option fail")
        new_level == 0: class handler vt+0x84 (clear the option block) else vt+0x80(attr, ro_count, ro_value)
        r = ItemAttr_Save(key, attr)
        # the upgrade itself is already committed: an error here reports failure for a done upgrade (original bug) D03-B12
    err: r 0 → destroy == 1 ? 0x8C7 : adj_level 1 → 0x8C3, 2 → 0x8C4, 0xFF → 0x8C6, other → 0x8C5
         r 1, 2 → 0x8C8; 3 → 0x8CB (gift money); 4–9 and > 9 → 0x8CC
    raw { 0x0C, 0x3448 NC_ITEMDB_UPGRADE_ACK, hdr, u16 lock, u16 err }

0x34D1 NC_ITEMDB_NEW_UPGRADE_REQ { hdr, u16 lock @6, u64 key @8, u16 id @0x10, u8 adj_level @0x12, u8 new_level @0x13,
        u8 fail_count @0x14, u64 raw @0x15, u16 raw_id @0x1D, u8 raw_lot @0x1F, u8 ro_enable @0x20, u8 ro_count @0x21, u16 ro_value @0x22 }
                                                                    @ FUN_00430a10 (`fc_NC_ITEMDB_NEW_UPGRADE_REQ`)
    as 0x3447 with destroy 0, gift 0, one raw; !types → 0x3806
    err: r 0 → adj 1 → 0x3803, 0xFF → 0x3805, other → 0x3804; 1, 2 → 0x3806; 4, 5 → 0x3809; 3, 6–9, > 9 → 0x8CC (an UPGRADE code)
    raw { 0x0C, 0x34D2 NC_ITEMDB_NEW_UPGRADE_ACK, hdr, lock, err }

0x34D3 NC_ITEMDB_BRACELET_UPGRADE_REQ { hdr, u16 lock @6, u64 key @8, u16 id @0x10, u8 adj_level @0x12, u8 destroy @0x13,
        u8 new_level @0x14, u8 fail_count @0x15, u64 raw @0x16, u16 raw_id @0x1E, u8 raw_lot @0x20 }   @ FUN_00430e70
    !ItemUpgradeOptionTypes(id): Send 0x34D4 { hdr, lock, 0x3806 } — and then continues: the procedure is still called with
        uninitialised option types and a second 0x34D4 follows (original bug) D03-B13
    r = p_Item_Upgrade_CelllInAll(…)
    err: r 0 → destroy 1 → 0x3C0B, adj 1 → 0x3C07, 2 → 0x3C08, 0xFF → 0x3C0A, other → 0x3C09; r 1, 2 → 0x3C04; others → 0x3C06
    Send 0x34D4 NC_ITEMDB_BRACELET_UPGRADE_ACK { hdr, u16 lock, u16 err }
```

The upgrade result (level, success, destruction) is decided by the zone; the DB only writes what it is told. No GameLog here.

### 6.2 Enchanting (gem sockets, `tItemEnchant`)

The four procedures exist only in `w00_Character` with the SSMS template header "Author: <KHRISMIZER>, 2010.08.13" (marked
`3RD?` by `bak.py`); their parameter order and every result code the binary tests (−101, −201, −202, −301, −302) match them, so they
are at least compatible with the 2016 binary *(db-backup)*. Table `tItemEnchant { nItemKey, nSlot, nGemItemID, nRestCount }`;
the socket counts are weapon options 523 (`maxSocketCount`) and 524 (`createdSocketCount`).

```pseudo
0x3496 NC_ITEMDB_ENCHANT_ADD_GEM_REQ { hdr, u16 itemLockIndex @6, equipment {u64 key @8, u16 id @0x10, cell @0x12},
        gem {u64 key @0x14, u16 id @0x1C, cell @0x1E}, u8 gemSocketIndex @0x20, u8 gemLot @0x21 }
                                                                    @ FUN_00423500 (`CPFsCharacter::fc_NC_ITEMDB_ENCHANT_ADD_GEM_REQ`)
    usp_Item_Add_EnchantGem(charNo, equipKey, gemKey, socket, gemId, restCount = gemLot, out nRet)      @ FUN_00465540
        # transaction: INSERT tItemEnchant (fail −101), p_Item_Delete(gem) (fail −202). No check that the socket exists or is free
    nRet 0 → 0x2080, −202 → 0x2082, −101 → 0x208A, other → 0x2089 (logged "DB_ERROR[UPDATE]")
    Send 0x3497 { hdr, u16 err, u16 lock, {equip cell, u8 socket, u16 gemId, u8 restGemCount = gemLot}, {gem cell} }   # 0x12

0x3498 NC_ITEMDB_ENCHANT_REMOVE_GEM_REQ { hdr, u16 lock @6, equipment {key @8, id, cell @0x12}, remover {key @0x14, id, cell @0x1E},
        u8 beDeleted[3] @0x20, u8 needItem @0x23 }                  @ FUN_004236e0
    err = 0x2090
    for socket i in 0..2 with beDeleted[i]:
        usp_Item_Del_EnchantGem(charNo, equipKey, removerKey, i, needItem (only for the first removed socket, then 0),
                                removerLotType 0, out removerLot, out nRet)                               @ FUN_00465640
            # needItem 1 → p_Item_Delete(remover) (−101); DELETE tItemEnchant row (none → −201)
        0 → deleted[i] = 1; −201 → err 0x2095; −101 → 0x2092; other → 0x2096 (deleted[i] = 0)
    Send 0x3499 { hdr, u16 err, u16 lock, equip cell, remover {cell, u64 lot (0)}, u8 deleted[3], u8 needItem }    # 0x1A
    # the remover is deleted whole even when it is a stack (its lot is never lowered)

0x349A NC_ITEMDB_ENCHANT_ADD_NEW_SOCKET_REQ { hdr, u16 lock @6, equipment {key @8, id, cell @0x12}, drill {key @0x14, id, cell @0x1E} }
                                                                    @ FUN_00423930
    usp_Item_Add_EnchantSocket(charNo, equipKey, drillKey, out allSocketCount, drillLotType 0, out drillLot, out nRet)  @ FUN_00465760
        # transaction: delete the drill (−101), read 523 (−201) and 524 (−202), write both + 1 (−301/−302). No maximum check
    0 → 0x20A0, −101 → 0x20A2, −201/−202/−301/−302/other → 0x20A6
    Send 0x349B { hdr, u16 err, u16 lock, {equip cell, u8 allSocketCount}, {drill cell, u64 lot} }        # 0x17

0x349C NC_ITEMDB_ENCHANT_SET_GEM_LOT_REQ { hdr, u64 key @6, u8 socketCount @0xE, {u16 gemItemIndex, u8 restGemCount}[3] @0xF }
                                                                    @ FUN_00423b90
    for each socket with gemItemIndex ≠ 0xFFFF: usp_Item_Set_EnchantGemLot(charNo, key, slot, rest) (UPDATE; ≠ 1 row → −101, logged)
    no answer (the 2017 PDB has a 0x349D ACK; the zone's 0x349D handler is an empty stub, Z05 §8.2)
```

### 6.3 Mounts (movers)

```pseudo
0x34AC NC_ITEMDB_MOVER_UPGRADE_REQ { u16 nLockIndex @0, u32 nCharRegNum @2, u16 nHandleNum @6, u8 bUpgrade @8, u64 subKey @9,
        u16 subId @0x11, attr subAttr @0x13, u64 mainKey @0x78, u16 mainId @0x80, cell mainLoc @0x82, attr mainAttr @0x84 }
                                                                    @ FUN_00429e70 (`CPFsCharacter::fc_NC_ITEMDB_MOVER_UPGRADE_REQ`)
    answer prefilled: err 0x3230, bUpgrade, nSlot = (u8) mainLoc, mainId, mainAttr
    old = GetItemOptions(mainKey) fails → 0x3231
    ItemAttr_Save(mainKey, mainAttr) fails → 0x3232
    p_Item_Delete(subKey) ok → Log 0x079A NC_LOG_MOVER_UPGRADE
                          fails → ItemAttr_Save(mainKey, old): ok → 0x3233, fails → 0x3234 ("Attr Recovery Error")
    Send 0x34AD NC_ITEMDB_MOVER_UPGRADE_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError, u8 bUpgrade, u8 nSlot,
        u16 nItemID, attr } (0x73)

0x34AE NC_ITEMDB_MOVER_RAREMOVER_REQ { u16 lock, u32 charNo, u16 handle, u64 mainKey @8, u16 mainId, attr @0x12, u64 subKey @0x77,
        u16 subId, attr @0x81, u64 rareKey @0xE6, u16 rareId @0xEE, cell rareLoc @0xF0, attr rareAttr @0xF2 }    @ FUN_0042a230
    Item_Insert(rareKey, charNo, rareLoc, rareId, rareAttr) fails → 0x3239
    p_Item_Delete(mainKey) fails → delete the rare again: ok → 0x323A, fails → 0x323B
    p_Item_Delete(subKey) fails → delete the rare again (0x323A / 0x323B); the main mover is already gone and is not
        recreated (original bug) D03-B14
    ok → Log 0x079B NC_LOG_MOVER_RAREMOVER
    Send 0x34AF NC_ITEMDB_MOVER_RAREMOVER_ACK { lock, charNo, handle, err (0x3238 ok), u8 nSlot = (u8) rareLoc, u16 rareId, attr } (0x72)
```

### 6.4 Random options

```pseudo
ItemRandomOption_Get(itemId, attr, out ItemOptionStorage[25])      @ FUN_0042c650
    AMULET → attr+0x25, WEAPON → attr+0x40, ARMOR/SHIELD/BOOT/BRACELET → attr+0x0C; else 0
RandOptChangedCount_Type(itemId, attr, out type, out value)        @ FUN_00469d60
    AMULET 0x1AB (attr+0x24), WEAPON 0x20D (+0x3F), ARMOR 0x26E / SHIELD 0x2D2 / BOOT 0x336 / BRACELET 0xB07 (+0x0B)

0x34B3 NC_ITEMDB_RANDOMOPTION_CHANGE_REQ { u16 lock, u32 charNo, u16 handle, u64 key @8, u16 id @0x10, attr new @0x12, attr old @0x77 }
                                                                    @ FUN_004359c0
    ItemAttr_Save(key, id, new) ≠ 0 → err 0x3250 (logged)
    ok: err 0x3248; Log 0x079E NC_LOG_RANDOMOPTION_CHANGE_BEFORE (old options) and 0x079F …_AFTER (new), each split into two
        packets tagged "1" (option kinds 0–8) and "2" (kinds 9–14)
    Send 0x34B4 NC_ITEMDB_RANDOMOPTION_CHANGE_ACK { u16 lock, u32 charNo, u16 handle, u16 err }

0x34C1 NC_ITEMDB_RANDOMOPTION_CHANGE_CONSUME_AND_COUNTING_REQ { u16 lock, u32 charNo, u16 handle, u64 stuffKey @8, u16 stuffId @0x10,
        u32 stuffLot @0x12, u64 itemKey @0x16, u16 itemId @0x1E, attr @0x20, u8 slot @0x85 }        @ FUN_0042c120
    ConsumeOne(stuff, stuffLot): attr fail 0x324B, not lot 0x324C, lot 0 0x324D, lot mismatch 0x324E, delete 0x324F, save 0x3250
    p_Item_SetOption(itemKey, RandOptChangedCount_Type(itemId, attr)) (FUN_00402cd0 → FUN_0046bb90) fails → 0x3250
    ok: err 0x3248; Log 0x07F8 NC_LOG_GAME_DATA_TYPE_G { 0x3A0, charNo, "UseBijouH", stuffLot, stuffId, stuffKey, count, itemKey, itemId }
    Send 0x34C2 { u16 lock, u32 charNo, u16 handle, u16 err, u64 itemKey, u16 itemId, u8 slot } (0x15)

0x34CD NC_ITEMDB_RANDOMOPTION_RECOVER_COUNT_LIMIT_REQ { u16 lock, u32 charNo, u16 handle, u64 itemKey @8, u16 itemId, attr @0x12,
        u32 ROCount_before @0x77, u32 ROCount_after @0x7B, u16 stuffId @0x7F, u32 stuffTotalDecreaseLot @0x81, u64 stuffKey @0x85,
        u32 decreaseLot @0x8D, u8 deleteCount @0x91, u64 deleteKey[] @0x92 }                       @ FUN_0042c750
    if stuffKey ≠ all-ones: attr fail 0x3259; not lot / lot ≤ decreaseLot → 0x325A; set lot / save fail → 0x325B
    each deleteKey: p_Item_Delete fail → 0x325C, send now
    ItemAttr_Save(itemKey, attr) fails → 0x3258
    ok: err 0x3251; Log 0x07F8 { 0x3A5, "RORecover", … before/after }, 0x0459 (stuff), 0x045A per delete
    Send 0x34CE { u16 lock, u32 charNo, u16 handle, u16 err }
```

The counter the zone wants changed travels inside `attr`; the DB never compares `ROCount_before`/`after` with anything.

### 6.5 Other item services

```pseudo
0x34B5 NC_ITEMDB_CHAT_COLOR_CHANGE_REQ { u16 lock @0, u32 charNo @2, u64 itemKey @6, u16 itemId @0xE, u32 itemLot @0x10,
        u32 eChatColorItemType @0x14, u8 nChangeColor @0x18 }    @ FUN_0042cfc0 (`CPFsCharacter::fc_NC_ITEMDB_CHAT_COLOR_CHANGE_REQ`)
    ConsumeOne(item, itemLot) (every failure → 0x3601)
    type 1: usp_ChatColor_setFont(charNo, color); 2: usp_ChatColor_setBalloon(charNo, color); 3: both
        # (db-backup, w00 only) UPDATE tChatColor or INSERT {nCharNo, nFontColorID, nBalloonColorID = 0}; −1 / −2 on error
        font failure → 0x3601; balloon failure only logged (err stays 0x3600)
    other type: logged "Invalid ChatColorITemType", err stays 0x3600: the item is consumed and nothing set (original bug) D03-B20
    Send 0x34B6 NC_ITEMDB_CHAT_COLOR_CHANGE_ACK { u16 err, u16 lock, u32 charNo, u64 itemKey, u16 itemId, u32 type, u8 color } (0x17)
    # the zone looks the player up by charNo (Z05 §2); the colours are sent at login by D02 (SendChatColor)

0x34B7 NC_ITEMDB_TERMEXTEND_REQ { u16 lock, u32 charNo, u16 handle, u64 extendKey @8, u16 extendId @0x10, u32 extendLot @0x12,
        u64 termKey @0x16, u16 termId @0x1E, attr termAttr @0x20, ShineDateTime newTime @0x85, … }   @ FUN_0042d500
    ConsumeOne(extend item) (failures → 0x3619)
    ItemAttr_Save(termKey, termId, termAttr) (FUN_00402cb0) fails → 0x3619
    ok: err 0x3618; Log 0x07E8 NC_LOG_GAME_DATA_TYPE_0 { 0x7EE, charNo, keys/ids, new date split into y/m/d/h/min }
    Send 0x34B8 NC_ITEMDB_TERMEXTEND_ACK { u16 lock, u32 charNo, u16 handle, u16 err }

0x34BD NC_ITEMDB_CLASS_CHANGE_REQ { u32 nCharRegNum @0, u16 nHandleNum @4, u64 nStuffKey @6, u16 nStuffID @0xE, u32 nStuffLot @0x10,
        u8 nMaxStat @0x14, u8 nFreeStat[5] @0x15, u8 nNewClass @0x1A, u64 nTotalPrice @0x1B, u16 lock @0x23,
        u32 nDeleteSkillCount @0x25, u16 nDeleteSkillID[] @0x29 }    @ FUN_0042e6b0 (`CPFsCharacter::fc_NC_ITEMDB_CLASS_CHANGE_REQ`)
    p_Char_ChangeClass(charNo, nNewClass) fails → 0x3686                       (procedure: D02 §7.1)
    each skill: p_Skill_Del(charNo, id) fails → 0x3687
    p_Skill_ResetPower(charNo) fails → 0x3688   # (db-backup) clears tCharacter.nFlags bit 31 and every tSkill power column
    for stat i in 0..4: nFreeStat[i] × p_Char_StatPoint_Dec(charNo, i) (fails → 0x3689)   # (db-backup) one point off nStrength… each call
    nTotalPrice ≠ 0: p_Char_MoneyAdd(charNo, nTotalPrice) fails → 0x368A      # money is GIVEN back (inferred: refund of spent points)
    ConsumeOne(stuff, nStuffLot) failures → 0x368B
    usp_Character_getShortCutList(charNo) false → log (unless nRet −2721 "not found") and return WITHOUT an answer
        (original bug) D03-B15
    every listed shortcut slot: usp_Character_setShortCut(charNo, slot, 0, 0) (clears all shortcuts; failures logged)
    Log 0x07E8 { 0x3A2, charNo, old/new class, free stats, skill count, stuff, price }
    Send 0x34BE NC_ITEMDB_CLASS_CHANGE_ACK { u32 charNo, u16 handle, u16 lock, u16 err (0x3680 ok) }
    # every step commits on its own (D03-B3): a failure after p_Char_ChangeClass leaves the new class with the old skills/stats

0x34BF NC_ITEMDB_UES_FRIEND_POINT_REQ { hdr, cell itemInven @6, u16 friendUsePoint @8, u16 lock @0xA, u64 key @0xC, u16 itemId @0x14,
        attr @0x16 }   (2016: 0x7B bytes)                           @ FUN_0042ef20
    usp_Character_getFriendpoint(charNo) fails → 0x36C2; points = first row (0 if none)
    friendUsePoint > points → 0x36C3 ("Lack FriendPoint")
    usp_Character_setFriendpoint(charNo, points − use) fails → 0x36C2
    to the WM: 0x541C NC_FRIEND_DB_POINT_CMD { u16 1, { charNo, u16 points − use, u16 0 } }   (SendToWorldManager @ FUN_00402d80)
    Item_Insert(key, charNo, itemInven, itemId, attr) fails → 0x36C2 — the points are already spent (D03-B3)
    ok: err 0x36C0; Log 0x07F2 NC_LOG_GAME_DATA_TYPE_A { 0x3A1, … }
    Send 0x34C0 NC_ITEMDB_UES_FRIEND_POINT_ACK { hdr, u16 err, u16 itemID, u16 friendpoint (left), u16 lock, u8 numofitem (lot) } (0xF)

0x34C9 NC_ITEMDB_MAPLINK_ITEM_CONSUME_REQ { u16 lock, u32 charNo, u16 handle, Name3 mapName @8, u16 skillID @0x14,
        u32 skillCoolTime @0x16, u64 stuffKey @0x1A, u16 stuffId @0x22, u32 stuffLot @0x24 }
                                                    @ FUN_0042fd10 (`CPFsCharacter::fc_NC_ITEMDB_MAPLINK_ITEM_CONSUME_REQ`)
    ConsumeOne(stuff, stuffLot) failures → 0x3750
    ok: usp_LinkScroll_SetDestMap(charNo, mapName) (failure only logged, with the COMPARE_MAP log text)    @ wrapper (3 params)
    Send 0x34CA NC_ITEMDB_MAPLINK_ITEM_CONSUME_ACK { lock, charNo, handle, mapName, skillID, skillCoolTime, u16 err (0x3748 ok) }

0x34CF NC_ITEMDB_MAPLINK_ITEM_COMPARE_MAP_REQ { u32 charNo }  (2017 name NC_ITEMDB_RESET_SCROLL_LINK_MAP_INFO_CMD (pdb2017),
        which matches the 4-byte body)                              @ FUN_00430290
    usp_LinkScroll_SetDestMap(charNo, "") — clears the stored destination; failure logged; no answer
```

`usp_LinkScroll_SetDestMap` has no source in any backup (D06): `(@nCharNo int, @sMapName char(13), @nRet OUTPUT)` from the binds.

```pseudo
0x34CB NC_ITEMDB_MIX_ITEM_REQ { u32 charNo @0, u16 handle @4, u64 subRawKey @6, u16 id @0xE, u32 lot @0x10, u64 leftKey @0x14,
        u16 id @0x1C, u32 lot @0x1E, u64 rightKey @0x22, u16 id @0x2A, u32 lot @0x2C, cell MixItemLoc @0x30, u64 newKey @0x32,
        u16 newId @0x3A, attr @0x3C, u16 lock @0xA1 }   (2016: 0xA3 bytes)      @ FUN_00430380 (`CPFsCharacter::fc_NC_ITEMDB_MIX_ITEM_REQ`)
    for sub raw, left, right: ConsumeOne-like (lot = the CURRENT lot, a non-stack counts 1; any failure → 0x37C8)
    Item_Insert(newKey, charNo, MixItemLoc, newId, attr) fails → p_Item_Delete(newKey), 0x37C8 (raws stay consumed, D03-B3)
    Send 0x34CC NC_ITEMDB_MIX_ITEM_ACK { u32 charNo, u16 handle, u16 lock, u16 err (0x37C0 ok) }
```

### 6.6 Dismantle, endurance, bound items, reinforce

```pseudo
0x3476 NC_ITEMDB_DISMANTLE_REQ { hdr, u16 lock @6, raw { u8 vanish @8, u16 rawid @9, u16 rawuselot_log @0xB,
        {VANISH | ATTRCHANGE} @0xD }, u8 producenumber @0x19, produce[n] @0x1A { u8 create, u16 product, u16 productuselot_log,
        {PROTO_ITEM_CREATE | PROTO_ITEM_ATTRCHANGE} } (0x2B each), attribute blocks }       @ FUN_00419c00
    # the u16 `attr` field of each ATTRCHANGE / CREATE is the payload offset of that item's attribute block
    for each produce: create ? Item_Insert(…) (fail → 0xB0D) : ItemAttr_Save(key, product, attr) (fail → 0xB0E); stop at the first error
    raw: vanish ? p_Item_Delete(raw key) (fail → 0xB0F) : ItemAttr_Save(raw key, rawid, attr) (fail → 0xB10)
    Send 0x3477 NC_ITEMDB_DISMANTLE_ACK { hdr, u16 lock, u16 err (0x1680 ok) }
    then, even after a failure: Log 0x0453 NC_LOG_GAME_ITEM_PRODUCT per produce and 0x045D …_PRODUCT_STUFF for the raw
    # products made before a failure stay (D03-B3)

0x348B NC_ITEMDB_FURNITURE_ENDURE_REQ { u16 nFurnitureHnd @0, u64 nItemKey @2, ShineDateTime dNewEndureTime @0xA,
        PROTO_NC_ITEMDB_USE_VARIATION_ITEM_REQ CommonData @0xE { hdr, PROTO_CHANGEATTR {kit key @0x14, kit id @0x1C, attr16},
        u16 lock @0x20, u8 isClear @0x22 }, kit attr @0x23 }        @ FUN_0041fad0
    kitLot = isClear ? 0 : ItemLotAfterUse(kit id, kit attr)
    p_Item_Furniture_Endure_Update(charNo, kitKey, kitOptType, kitLot, furnitureKey, 0x38B (907 dEndureEndTime), dNewEndureTime)
        # (db-backup, Lunar 2008.10) owner checks of both items; transaction: kit lot 0 → delete else SetOption; SetOption(furniture)
    ok → 0x700, Log 0x0459 (kit); fail → 0x706
    Send 0x348C { hdr, u16 lock, u16 nFurnitureHnd, u64 nItemKey, ShineDateTime, u16 err } (0x18)

0x348D NC_ITEMDB_WEAPONENDURE_CHARGE_REQ / 0x34C6 NC_ITEMDB_SHIELDENDURE_CHARGE_REQ { u64 key @0, cell slot @8,
        u32 ChargedNumber @0xA, CommonData @0xE (as above), kit attr @0x23 }        @ FUN_0041fcf0 / FUN_0041ffa0
    p_Item_CostumWeapon_Endure_Update(charNo, kitKey, kitOptType, kitLot, key, 0x708 (weapon skin) / 0x73A (shield skin), ChargedNumber)
        (both opcodes use the weapon procedure; wrappers @ FUN_004631b0 / FUN_00463700)
    ok → 0x1A80, Log 0x0459; fail → 0x1A89
    Send 0x348E / 0x34C7 { hdr, u16 lock, u64 key, cell slot, u32 ChargedNumber, u16 err } (0x18)

0x348F NC_ITEMDB_WEAPONENDURESET_CMD / 0x34C8 NC_ITEMDB_SHIELDENDURESET_CMD { u64 key, u32 ChargedNumber }  @ FUN_0041ff10 / FUN_004201c0
    p_Item_CostumWeapon_Endure_Set(key, 0x708 / 0x73A, ChargedNumber)  (wrappers @ FUN_004634a0 / FUN_004639f0); no answer
    # (db-backup) one SetOption in a transaction; nRet 5 on error (the header comment is copied from the upgrade procedure)

0x34A6 NC_ITEMDB_EQUIP_BELONGED_CANCEL_USE_REQ { hdr, u16 lock @6, u64 belongedKey @8, u16 belongedId @0x10, u64 cancelKey @0x12,
        u16 cancelId @0x1A, u32 cancelLot @0x1C }      @ FUN_00426460 (`CPFsCharacter::fc_NC_ITEMDB_EQUIP_BELONGED_CANCEL_USE_REQ`)
    belongedId 0xFFFF / unknown → 0x288A; belong option type by class as EQUIP (§3.1), other class → 0x288C
    cancel item unknown or not a stack class → 0x288B
    usp_Item_setPutOnBelongedCancel(charNo, cancelKey, cancelOptType, cancelLot, belongedKey, belongType, 0)
        # (db-backup, w00, Ko Dong Gyun 2011.6.23) −2511 bad char, −2512/−2513 an item not owned, −2521 cancel lot ≠ stored lot,
        # lot > 1 → SetOption(lot − 1) (−2522) else delete (−2523), target option ≠ 1 (not bound) −2524, write 0 (−2525)
    −2524 → 0x288D; every other failure → 0x2881; ok 0x2880
    Send 0x34A7 { hdr, u16 lock, u16 err, u64 belongedKey, u16 belongedId, u64 cancelKey, u16 cancelId, u32 cancelLot } (0x22)

0x347F NC_ITEMDB_REINFORCEUNEQUIP_REQ { hdr, PROTO_ITEM_RELOC unequ {key @6, newloc @0xE}, u16 lock @0x10, cell equloc @0x12 }
                                                                    @ FUN_0041f660
    as UNEQUIP (§3.1): 0x3480 { hdr, lock } / 0x3481 { hdr, err 0x28A, lock } (D03-B5)
```

## 7. Creating, opening and destroying items

Storage type 10 holds the hidden contents of chests and capsules (chest contents get free type-10 slots, §7.2; capsule contents
are created there, §2.5). `p_Item_GetData(key)` @ FUN_00468150 returns the row (`nOwner`, type, slot, `nItemID`, …).

### 7.1 Direct creation

```pseudo
0x3401 NC_ITEMDB_ADMINCREATE_REQ / 0x3467 NC_ITEMDB_CREATEMUSHROOM_REQ { hdr, u16 lock @6, PROTO_ITEM_CREATE {owner @8, map @0xC,
        cell @0x20, key @0x22, itemid @0x2A, attr16 @0x2C}, attr @0x2E }               @ FUN_00407420 / FUN_00408ba0
    Item_Insert(rec{key, owner, cell, itemid}, attr, fixed slot)
    ok: Send 0x3402 ADMINCREATESUC / 0x3468 CREATEMUSHROOMSUC { hdr, u16 lock }; Log 0x044F NC_LOG_GAME_ITEM_CREATE { owner, owner, key, itemid, cell }
    fail: log; Send 0x3403 / 0x3469 { hdr, u16 lock, u32 owner }

0x3404 NC_ITEMDB_QUESTALL_REQ { hdr, u16 quest @6, PROTO_ITEM_CREATE @8 (as above), attr @0x2E }      @ FUN_00408e20
    Item_Insert ok: Send 0x3405 { hdr }; Log 0x043F NC_LOG_GAME_QUEST_ITEM_GET { owner, "Need", quest, key, itemid, lot }
    fail: Send 0x3406 { hdr, u16 0x3C2 }
0x3407 NC_ITEMDB_QUESTLOT_REQ { hdr, u16 quest @6, u16 itemid @8, PROTO_ITEM_ATTRCHANGE {key @0xA, attr16, cell @0x14}, attr @0x16 }
                                                                    @ FUN_00409080
    !ItemLotAfterUse → 0x3C4; p_Item_SetOption(key, optType, lot) ≠ 0 → 0x3C3
    ok: Send 0x3408 { hdr }; Log 0x043F;  fail: Send 0x3409 { hdr, u16 err }

0x345D NC_ITEMDB_QUESTITEMGET_REQ                                   @ LAB_0040e6e0 (not a Ghidra function; read in the asm)
    log "여기작업중 - CPFsCharacter::fc_NC_ITEMDB_QUESTITEMGET_REQ" ("work in progress here", CP949); return. No DB call, no answer
```

### 7.2 Item lists (scripts, quests, events) @ FUN_00432090

```pseudo
0x344D NC_ITEMDB_CREATEITEMLIST_REQ { hdr, u32 owner @6, u16 lock @0xA, u16 map @0xC, u64 price @0xE,
        PROTO_ITEM_CMD itemlist { u8 numofitem @0x16, records @0x17 { u8 datasize, cell, u64 key, u16 itemid, attr } } }
    first record's item unknown → log; raw { 0x0C, 0x344F CREATEITEMLISTFAIL_ACK, hdr, u16 lock, u16 0x9AA }
    first item is an ITEMCHEST → CreateChestItemList, else CreateItemList
    ok → raw { 0x0A, 0x344E CREATEITEMLISTSUC_ACK, hdr, u16 lock }; fail → 0x344F { …, 0x9AA }

CreateItemList(req) @ FUN_0040e710:
    price ≠ 0: p_Char_MoneySub(owner, price) fails → log "… SubCharMoney - NO MONEY …", fail
    per record: Item_Insert(rec{key, owner, cell, itemid}, attr, useEmptySlot = cell type is 2 (reward box) or 10 (contents))
        fail → price ≠ 0: p_Char_MoneyAdd(owner, price) (refund, logged on error);
               delete the items created so far — but the walk advances by `datasize × 0x72` instead of `datasize + 1`, so only the
               first item is deleted and the other keys are read from wrong offsets (original bug) D03-B19; fail
        ok → Log 0x044F
    price ≠ 0: p_Char_MoneyGet → Log 0x0462 MONEY_CHANGE { owner, before = now + price, after = now, price };
               usp_HolyPromise_setMoney(owner, price / 10, 10)
CreateChestItemList(req) @ FUN_0040f370:
    p_Item_GetStorageEmptyList(owner, type 10, numofitem − 1, out nRet)        @ FUN_00464b40
        # (db-backup, w00 only, 2009.9.14) the first N free slots of that storage type (dynamic SQL; owner −1 → −1000)
    rows read: at most 8 i32 slots; fewer than numofitem − 1 → log "… Owner is full empty chest …", fail
    records 2..n get cell = 10 << 10 | slot (the chest's contents); record 1 (the chest) keeps its cell; then CreateItemList
```

### 7.3 Chests and capsules

```pseudo
0x346D NC_ITEMDB_CHESTITEM_REQ { hdr, u64 chest @6, cell location @0xE }          @ FUN_0040f030 (`fc_NC_ITEMDB_CHESTITEM_REQ`)
    err = 0x9B5 (ok)
    p_Item_GetData(chest) fails → 0x9B6; chest attr = GetItemOptions fails → 0x9B7
    for each content key in the chest attribute (count = attr[0] & 0x0F, u64 keys from attr+1):
        GetData + GetItemOptions → record { u8 datasize, cell (the content's own type-10 cell), u64 key, u16 id, attr }
        failure → err 0x9B8, that content is left out; the zone treats only 0x9B6/0x9B7 as errors (Z05 §6.2), opens the chest
            and deletes it with the content still in storage type 10 (original bug) D03-B16
    Send 0x346E NC_ITEMDB_CHESTITEM_ACK { hdr, u64 chest, cell location, u16 err, u8 count, records } (length = what was built)

0x3450 NC_ITEMDB_GETFROMCHEST_REQ { hdr, u32 owner @6, u16 lock @0xA, u64 chest @0xC, u8 relocnum @0x14,
        PROTO_ITEM_RELOC reloc[relocnum] @0x15 }                    @ FUN_0040eb50 (`fc_NC_ITEMDB_GETFROMCHEST_REQ`)
    for each reloc: p_Item_GetStorageAndOwner(key) (remember owner/type/slot) fails → 0x9B4
    for each reloc: p_Item_SetStorageAndOwner(key, owner, newlocation) fails → 0x9B2 → undo
    p_Item_Delete(chest) fails → 0x9B3 → undo
    undo: put every moved item back to its remembered owner/cell (errors logged "ROLLBACK's p_Item_SetStorageAndOwner")
    ok: Log 0x0445 NC_LOG_GAME_ITEM_BREAK { owner, chest key, … }, p_Guild_GetMyNo, Log 0x044C per item;
        raw { 0x0A, 0x3451 GETFROMCHESTSUC_ACK, hdr, u16 lock }
    fail: raw { 0x0C, 0x3452 GETFROMCHESTFAIL_ACK, hdr, u16 lock, u16 err }
    # this is the one multi-item handler with a real rollback

0x34A2 NC_ITEMDB_CAPSULEITEM_REQ { hdr, u64 nItemReg @6, cell nLocation @0xE }      @ FUN_00425dd0 (`fc_NC_ITEMDB_CAPSULEITEM_REQ`)
    p_Item_IsValidOwner(capsule, charNo) ≠ 0 → 0x2845
    capsule attr fails → 0x2846; content key = attr.content (option 2100)
    content GetData / GetItemOptions fails → 0x2847 — and the answer still carries whatever was copied; the zone treats only
        0x2845/0x2846 as errors (Z05 §6.3), so it builds a GETFROMCAPSULE for a broken content record (original bug) D03-B18
    Send 0x34A3 NC_ITEMDB_CAPSULEITEM_ACK { hdr, u16 nError (0x2844 ok), u64 nItemReg, cell nLocation,
        content { u64 key, u16 slot?, u16 id, attr } } (0x81)

0x34A4 NC_ITEMDB_GETFROMCAPSULE_REQ { hdr, u32 nOwner @6, u16 nLockIndex @0xA, u64 capsule @0xC, PROTO_ITEM_RELOC nReloc @0x14 }
                                                    @ FUN_00426050 (log strings say `fc_NC_ITEMDB_GETFROMCHEST_REQ`, copy-paste)
    p_Item_GetStorageAndOwner(content) fails → 0x2843
    p_Item_SetStorageAndOwner(content, nOwner, nReloc.newlocation) fails → restore, 0x9B2
    p_Guild_GetMyNo; p_Item_Delete(capsule) fails → restore the content, 0x9B3
    ok: Log 0x0445, 0x044C; err 0x2840
    Send 0x34A5 NC_ITEMDB_GETFROMCAPSULE_ACK { hdr, u16 lock, u16 err }
```

### 7.4 Mystery vault, card rebuild, item info

```pseudo
0x349E NC_ITEMDB_MYSTERY_VAULT_MAKEITEM_REQ { hdr, u16 itemLockIndex @6, u64 UseVaultItemRegNo @8, u16 UseVaultItemID @0x10,
        u8 itemcreatecount @0x12, PROTO_ITEM_CREATE itemcreate[] @0x13 (attr = payload offset of the attribute block) }
                                                                    @ FUN_00410a80
    Item_Insert each; failure → delete the ones made (twice: the second pass only logs), err 0x2141
    p_Item_Delete(vault item) fails → delete the made items, 0x2141
    ok 0x2140: Log 0x044F per item, Log 0x0445 { charNo, vault key, id, 1 }
    Send 0x349F NC_ITEMDB_MYSTERY_VAULT_MAKEITEM_ACK { hdr, u16 lock, u16 err }

0x34A8 NC_ITEMDB_ITEMINFO_REQ { u32 clientregnum, u16 clientzonehandle, u64 ItemKey @6, u16 FailProtocol @0xE }   @ FUN_004269b0
    GetData fails → 0x2B01; GetItemOptions fails → 0x2B02 (the item fields of the answer are then stale)
    Send 0x34A9 NC_ITEMDB_ITEMINFO_ACK { u32 regnum, u16 handle, u16 err (0x2B00 ok), u16 FailProtocol, u64 key, u16 itemId, attr } (0x79)

0x34AA NC_ITEMDB_ITEMREBUILD_REQ { u32 regnum, u16 handle, u16 lock @6, u64 EraseItemKey @8, PROTO_ITEM_CREATE CreateItem @0x10
        {owner @0x10, map, cell @0x28, key @0x2A, id @0x32, attr16}, attr @0x36 }   @ FUN_00426c20 (`…fc_NC_ITEMDB_ITEMREBUILD_REQ`)
    Item_Insert(new key, owner, cell type, id, attr, useEmptySlot = 1) fails → 0x2B41
    p_Item_Delete(EraseItemKey) fails → p_Item_Delete(new) (logged), 0x2B42
    p_Item_SetStorage(new key, cell) (move into the sealed card's cell, now free) fails → 0x2B43 (the new card stays in the
        temporary slot, the sealed one is gone)
    ok: Log 0x044F; err 0x2B40
    Send 0x34AB NC_ITEMDB_ITEMREBUILD_ACK { u32 regnum, u16 handle, u16 lock, u16 err }

0x344B NC_ITEMDB_ITEMTOTALINFORM_REQ { u64 itemregnum }  (no hdr)  @ FUN_00431ea0 (`fc_NC_ITEMDB_ITEMTOTALINFORM_REQ`)
    Send 0x344C NC_ITEMDB_ITEMTOTALINFORM_ACK { u64 key, SHINE_ITEM_STRUCT { u16 itemId, attr } } (0x6F)
        GetData or GetItemOptions failure → key all-ones, itemId 0xFFFF, attr zero
```

### 7.5 Breaking, destroying, producing, quest rewards

```pseudo
0x346A NC_ITEMDB_ITEMBREAK_REQ { hdr, u16 lock @6, u64 BreakItemKey @8, u32 Owner @0x10, u16 nID @0x14, u16 nLot @0x16,
        u8 nDeleteChestItem @0x18, PROTO_ITEM_VANISH DeleteChestItem[] @0x19 }  @ FUN_00411c90 (`…fc_NC_ITEMDB_ITEMBREAK_REQ`)
    e = p_Item_Delete(BreakItemKey)
    0: Send 0x346B ITEMBREAKSUC_ACK { hdr, u16 lock }; Log 0x0445 { Owner, key, nID, nLot }; delete ≤ 8 chest contents (errors logged)
    else: Send 0x346C ITEMBREAKFAIL_ACK { hdr, u16 lock, u16 ErrorCode = e (the SQL error number) }

0x3459 NC_ITEMDB_DESTROY_REQ { hdr, u16 lock @6, u8 flags @8 (bit 7 = rewrite one item, bits 0–6 = number of keys to delete),
        u16 itemId @9, u64 key @0xB, u16 attrOffset @0x13, … keys to delete }                        @ FUN_004325e0 → FUN_00412420
    bit 7: ItemAttr_Save(key, itemId, payload + attrOffset) fails → r 1
    n deletes: p_Item_Delete fails → r 2 (stop)
    err = r ? 0xB82 : 0xB81 (r logged)
    Send 0x345A NC_ITEMDB_DESTROY_ACK { hdr, u16 lock, u16 err }

0x3457 NC_ITEMDB_PRODUCE_REQ { hdr, u16 lock @6, u16 product @8, produce { u8 create @0xA, {PROTO_ITEM_CREATE | ATTRCHANGE} @0xB },
        u8 rawnumber @0x31, raw[] @0x32 { u8 vanish, u16 rawid, u16 rawuselot_log, {VANISH | ATTRCHANGE} } (0x11 each) }
                                                                    @ FUN_004324f0 → FUN_00431230
    product: create ? Item_Insert : ItemAttr_Save(key, product id, attr)  — failure → 0xB0D
    each raw: vanish ? p_Item_Delete (fail → 0xB0F) : ItemAttr_Save (fail → 0xB0E)
    ok 0xB01 (codes from the function's return sites; the decompiler hides them)
    Send 0x3458 NC_ITEMDB_PRODUCE_ACK { hdr, u16 lock, u16 product, u16 err }      # no GameLog here

0x345B NC_ITEMDB_QUESTREWARD_REQ { hdr, u16 lock @6, u16 nQuestID @8, u32 money @0xA, u32 exp @0xE, u32 fame @0x12,
        u64 current_money @0x16, u64 current_exp @0x1E, u32 current_fame @0x26, u8 ct_type @0x2A, u8 ct_elementno @0x2B,
        u8 itemcreatecount @0x2C, PROTO_ITEM_CREATE itemcreate[] @0x2D }      @ FUN_00432770
    Item_Insert each item (attr = offset); failure → delete the made ones, 0xBC2
    money ≠ 0: p_Char_MoneyAdd fails → 0xBC3 (+ delete items)
    exp ≠ 0: p_Char_AddExp(charNo, exp) (failure only logged "CharAddExp ERROR")
    fame: not written here (only logged; the zone saves fame with NC_CHAR_FAMESAVE_CMD, D02 §7.1) (inferred)
    ct_type ≠ 0: SetCharTitles(charNo, 1, {ct_type, ct_elementno | 0x80}) (FUN_0046d3e0 → p_Char_SetTitle, D04) fails →
        0xBC5, p_Char_SubExp(exp) (FUN_00410ea0), p_Char_MoneySub(money), delete items
    ok 0xBC1: Log 0x051A …QUEST_REWARD_ITEM per item, 0x0519 _MONEY, 0x0518 _EXP, 0x051C _FAME, 0x051F _TITLE (only non-zero ones)
    Send 0x345C NC_ITEMDB_QUESTREWARD_ACK { hdr, u16 lock, u16 nQuestID, u16 err }
```

`ITEMBREAK` and `DESTROY` take every key on trust (no owner check), like `USEALL`.

### 7.6 Mini-house resources

```pseudo
0x347D NC_ITEMDB_MINIHOUSE_EFFECT_DEMANDGOOD_REQ { hdr, u16 lock @6, u64 nDemandItemRegNum @8, u16 nDemandItemID @0x10,
        u32 nNeedItemLot @0x12, u64 nDemandMoney @0x16, u16 nEffectHandle @0x1E }   @ FUN_0041a230
    r = p_Item_MiniHouse_Effect_Resource_Del(charNo, nDemandMoney, item key, ItemLotOption(id) or 0xFFFE, nNeedItemLot, out)
        # 6 parameters; no source in any backup (D06). r ≠ 0 is logged with all inputs
    r 0 → 0x1700, 1 → 0x1702, 2 → 0x1703, 3 → 0x1704, 4 → 0x1705, 5 → 0x1706, other → 0x1701
    raw { 0x0E, 0x347E NC_ITEMDB_MINIHOUSE_EFFECT_DEMANDGOOD_ACK, hdr, u16 lock, u16 nEffectHandle, u16 err }
```

`0x3489 MINIHOUSE_PORTAL_EFFECT_DEMANDGOOD_REQ` has no handler (Z05-B12).

## 8. Mini-house (dept 35, CParserCharacter)

All answers go to the zone (Z07 §6 / Z13 own the mini-house object). Tables *(db-backup, Ko Dong Gyun 2008.6)*: `tMinihouse
{ nCharNo, nVisitor, … }` (a row is created on first use), `tMinihouseGate { nCharNo, nItemID, bType (0 permanent, 1 timed),
dEndDate }`.

```pseudo
0x8C39 NC_MINIHOUSE_DB_OWNERBLOG_GET_REQ { hdr, u32 nUserNo @6 }    @ FUN_00417ac0 (`fc_NC_MINIHOUSE_DB_OWNERBLOG_GET_REQ`)
    p_MiniHouseURL_Get(nUserNo, out url[0x200])  (no source in any backup, D06)
    ok: Send 0x8C3A NC_MINIHOUSE_DB_OWNERBLOG_GET_ACK { hdr, u16 Error 0x11DA, u32 nUserNo, u8 bloglen = min(strlen, 255),
        blogaddr (string with its NUL) }   (size 0xE + len)
    fail: Error 0x11DB, bloglen 0 (size 0xD); log "FAILED - …, nUserNo=%d"
    # bloglen is clipped to 255 but the copy runs to the NUL (up to 0x1FF bytes) while the size uses the clipped length

0x8C3B NC_MINIHOUSE_DB_OWNERBLOG_SET_REQ { hdr, u32 nUserNo @6, u8 bloglen @0xA, blogaddr @0xB }    @ FUN_00417c80
    p_MiniHouseURL_Set(nUserNo, blogaddr)  — the string is passed up to its NUL; bloglen is not used for the DB (D06)
    ok: Send 0x8C3C { hdr, u16 0x11DA, u32 nUserNo, u8 bloglen, bloglen bytes of blogaddr (strncpy, no NUL) } (size bloglen + 0xE:
        one byte more than written, D03-B6)
    fail: { hdr, 0x11DC, nUserNo, 0 } (size 0xD)

0x8C59 NC_MINIHOUSE_DB_PORTAL_LIST_REQ { hdr }                       @ FUN_00433bb0 (`CPFsCharacter::fc_NC_MINIHOUSE_DB_PORTAL_LIST_REQ`)
    usp_Minihouse_getGateList(charNo, out nRet) false → Error 0x1A09 (logged), but the rows are still fetched
        # (db-backup) creates the tMinihouse row if missing; SELECT nCharNo, nItemID, bType, ISNULL(dEndDate, 0) FROM tMinihouseGate
        # WHERE not expired (dEndDate > now or NULL)
    per row: PORTAL_INFO { u16 nItemID, i32 dEndDate = bType ? mktime(dEndDate) : 0 }   (6 bytes)
    Send 0x8C5A NC_MINIHOUSE_DB_PORTAL_LIST_ACK { hdr, u16 Error (0x1A08 ok), u16 nPortalCnt, PortalInfo[] }

0x8C5B NC_MINIHOUSE_DB_VISITER_COUNT_REQ { hdr, u32 nVisiterCharNo @6 }   @ FUN_00417f50
    usp_Minihouse_setVisitorCount(nVisiterCharNo, out)   # (db-backup) tMinihouse.nVisitor + 1 for that character (row created
                                                          # if missing); the parameter is named nCharNo: the house OWNER (inferred)
    Send 0x8C5C { hdr, u16 0x1A20 ok / 0x1A21 }

0x8C5D NC_MINIHOUSE_DB_PORTAL_ADD_REQ { hdr, u16 nPortalItemID @6, u8 bType @8, i32 dEndDate @9 (time_t), u16 lockindex @0xD,
        PROTO_ITEM_RELOC Item {u64 key @0xF, cell @0x17} }          @ FUN_00433e80
    usp_Minihouse_setGate(charNo, nPortalItemID, bType, dEndDate (time_t → TIMESTAMP, FUN_00414340), Item.key, out nRet)
        # (db-backup) removes an existing row for that gate first; still there → −1621; bType 0 → dEndDate NULL;
        # p_Item_Delete(scroll key) then INSERT (−1692)
    Send 0x8C5E NC_MINIHOUSE_DB_PORTAL_ADD_ACK { hdr, u16 nPortalItemID, u8 bType, i32 dEndDate, u16 lockindex, u16 Error 0x1A10 / 0x1A11 }

0x8C5F NC_MINIHOUSE_DB_PORTAL_DEL_REQ { hdr, u16 nItemID @6 }       @ FUN_00417df0
    usp_Minihouse_delGate(charNo, nItemID, out)   # (db-backup) −1622 no gate, −1694 delete error
    Send 0x8C60 { hdr, u16 0x1A18 ok / 0x1A19 }
```

## 9. Premium buffs and re-initialise items (dept 36)

```pseudo
0x9001 NC_CHARGED_SETBUFF_CMD { u32 CharRegistNumber @0, u64 ItemKey @4, u16 ItemId @0xC, PROTO_CHARGEDBUFF_INFO { u32 key @0xE,
        u16 id @0x12, ShineDateTime use @0x14, ShineDateTime end @0x18 }, u32 nUserNo @0x1C }   @ FUN_00416ae0 (`fc_NC_CHARGED_SETBUFF_CMD`)
    p_Char_SetChargedBuffer(charNo, key, id, dUseDate, dEndDate)   (ShineDateTime → TIMESTAMP, year = byte + 2000)
        # (db-backup) UPDATE tCharacterChargedBuffer {nID, dUseDate, dEndDate} WHERE nCharNo, nKey, else INSERT
    ok: Log 0x0439 NC_LOG_GAME_CHARGED_BUFF_SET { charNo, id, key, end, userNo, itemKey }; failure only logged. No answer.

0x9002 NC_CHARGED_RESETBUFF_CMD { u32 CharRegistNumber, u32 ChargedBuffKey, u16 ChargedBuffID, u32 nUserNo }   @ FUN_00416d30
    p_Char_DelChargedBuff(charNo, key) ok → Log 0x043A …_CLR; no answer

0x9005 NC_CHARGED_STAT_INITIALIZE_DB_REQ / 0x9006 NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_REQ { hdr, u16 lockindex @6,
        u64 restatitemkey @8, u16 restatitemid @0x10, u8 isdelete @0x12, attr @0x15 }        @ FUN_00416e60 / FUN_00417160
    isdelete == 0:
        !ItemLotAfterUse(restatitemid, attr, out newLot) → 0x1089 / 0x1091
        usp_ChargeItem_UseStatPointInitLotChange / …UseSkillPowerInitLotChange(charNo, key, optType, newLot, out nRet)
            nRet 1 → 0x1086 / 0x108E, 2 → 0x1087 / 0x108F, 3 → 0x1088 / 0x1090, other failure → 0x108A / 0x1092
    else:
        usp_ChargeItem_UseStatPointInitDel / …UseSkillPowerInitDel(charNo, key, out nRet)
            nRet 1 → 0x1083 / 0x108B, 2 → 0x1084 / 0x108C, 3 → 0x1085 / 0x108D, other → 0x108A / 0x1092
        # (db-backup, KR) 1 = resetting the stats (tCharacter) / skill powers (tSkill) failed, 2 = item lot change / delete failed;
        # no transaction: with nRet 2 the stats are already reset
    ok: Send 0x9007 …STAT_INITIALIZE_DB_SUC_ACK / 0x9008 { hdr, u16 lock }; Log 0x0459 (lot) / 0x045A (deleted)
    fail: Send 0x9009 / 0x900A …_FAIL_ACK { hdr, u16 lock, u16 err }
```

## 10. Dice "TaiSai" game machine (dept 43)

A player places a dice-game machine item (the "house"); other players bet; the zone rolls and sends the results here. The
procedures *(db-backup, both backups, Ko Dong Gyun 2009.6–7, file `KR_procedureDice.sql`)* keep the games and dividends;
codes: −2411 bad charNo, −2412 bad item key, −2413 (dice string), −2414 bad game no, −2415 bad customer, −2416 bad dividend,
−2421 not enough money, −2492 insert, −2493 update, −2494 delete error. All answers start with `u16 nError` (PDB layouts).

```pseudo
0xAC0C NC_DICE_TAISAI_DB_EXPECT_INCOME_MONEY_REQ { hdr, cell nInvenSlot @6, u64 nTaiSaiItemKey @8, u64 nRewardMoney @0x10,
        u16 GetMasterRate @0x18 }                                   @ FUN_00421190
    usp_Dice_getDiceExpect(charNo, key) → row { u32 nCount (games), i64 nTotalDividend } (sum over this machine's games)
        nRet −2412 → 0x1D0E, −2411 → 0x1D0D, other / call failure → 0x1D0C
    expect = nTotalDividend ≥ 0 ? nRewardMoney : max(nRewardMoney, −nTotalDividend × GetMasterRate / 1000)
        # the house's income is the players' negative dividend total, at the master's rate per mille
    Send 0xAC0D …EXPECT_INCOME_MONEY_ACK { u16 nError (0x1D00 ok), hdr, cell, u64 key, u32 nGameCnt, i64 nExpectIncomeMoney } (0x1E)

0xAC10 NC_DICE_TAISAI_DB_RECEIPT_INCOME_MONEY_REQ { u16 lockindex @0, hdr @2, cell nInvenSlot @8, u64 nTaiSaiItemKey @0xA }
                                                    @ FUN_00435120 (`fc_NC_DICE_TAISAI_DB_RECEIPT_INCOME_MONEY_REQ`)
    money card: p_Item_GetData + GetItemOptions(key) fail → 0x1D14; money = the card's stored dividend (attribute, logged "DEBUG …")
    usp_Dice_setDicePay(charNo, key, money): −2416 → 0x1D10, −2494 → 0x1D11, −2493 → 0x1D12, −2492 → 0x1D13, −2412 → 0x1D0F,
        −2411 → 0x1D0E, other / call failure → 0x1D0D; ok 0x1D00     # (db-backup) pays the master, deletes the money card, logs
    Send 0xAC11 …RECEIPT_INCOME_MONEY_ACK { u16 nError, u16 lock, hdr, cell, u64 key, u64 nReceiptIncomeMoney (0 on failure) } (0x1C)

0xAC17 NC_DICE_TAISAI_DB_RANK_REQ { hdr, u32 nReqCharNo @6, u64 nTaiSaiItemKey @0xA }    @ FUN_00421420
    usp_Dice_getDiceRank(charNo, key): −2412 → 0x1D20, −2411 → 0x1D1F, other → 0x1D1E; rows (TOP 20) { sID, nWinCount }
    Send 0xAC18 …RANK_ACK { u16 nError (0x1D18 ok), hdr, u32 nReqCharNo, u8 nRankCnt, { char name[20], u32 wins }[≤ 20] }

0xAC23 NC_DICE_TAISAI_DB_DICE_ROLL_RESULT_REQ { hdr, u64 nActiveDiceTaiSaiKey @6, u8 DiceNum[3] @0xE, u16 nResultCnt @0x11,
        DiceRollApplyResult[n] @0x13 { u16 nError, u16 lockindex, u32 nPlayerNo, i64 nTotalDividend } }     @ FUN_00420d50
    usp_Dice_setDice(charNo, key, "abc" (dice as digits)) → row: i32 nGameNo
        −2412 → 0x1CF4, −2492 → 0x1CF2, −2413 → 0x1CF5, −2411 → 0x1CF3, other → 0x1CF1 (answer without results)
    per result: usp_Dice_setDiceResult(nGameNo, nPlayerNo, nTotalDividend)   # (db-backup) pays / charges the customer
        result.nError = call ok ? 0x1CF0 : 0x1CF1
        # the specific codes (0x1CF6–0x1CFA for −2414/−2415/−2421/−2493/−2492) test the nRet of setDice, not of
        # setDiceResult, so they never apply (original bug) D03-B23
    # setDice error: the answer copies nResultCnt from the request but carries no results (count ≠ size);
    # setDice ok without a result row: nGameNo is never initialised but used for every setDiceResult and echoed (D03-B23)
    Send 0xAC24 …DICE_ROLL_RESULT_ACK { u16 nError (0x1CF0), i32 nGameNo, hdr, u64 key, u16 nResultCnt, results[] (copied, nError set) }

0xAC25 NC_DICE_TAISAI_DB_DICE_ROLL_RESULT_LOG_CMD { hdr, u64 key @6, i32 nGameNo @0xE, u16 nResultLogCnt @0x12,
        DiceRollApplyResultLog[n] @0x14 { u32 nPlayerNo, u32 nBetting, u32 nBettingMoney, u16 nBattingRate, u8 bStatus,
        u16 nSysRate, u32 nDividendMoney } (0x15 each) }            @ FUN_004210c0
    per entry usp_Dice_setDiceLog(nGameNo, player, slot = nBetting, money, rate, status, tax = nSysRate, dividend); results ignored; no answer

0xAC2C NC_DICE_TAISAI_DB_ITEM_ID_CHANGE_REQ (handlers.json: NC_DICE_TAISAI_TIMER_CMD; both names have cmd 44 in the 2017 enum,
        the body is the ITEM_ID_CHANGE one) { hdr, cell nInvenSlot @6, u16 lockindex @8, u64 nDiceTaiSaiKey @0xA, u16 nGameItemID @0x12,
        u16 nMoneyCardItemID @0x14, u64 nRewardMoney @0x16, u16 GetMasterRate @0x1E }      @ FUN_00421660
    expect as 0xAC0C (getDiceExpect; −2412 → 0x1D2B, −2411 → 0x1D2A, other → 0x1D29)
    usp_Dice_chgMachineToMoneycard(key, nGameItemID, nMoneyCardItemID, option 0x38D (909 furniture nRewardMoney), expect)
        # (db-backup) turns the machine item into a money card worth `expect` (and takes a placed machine back to the inventory)
        −2423 → 0x1D32, −2493 → 0x1D30, −2419 → 0x1D2E, −2422 → 0x1D31, −2416 → 0x1D2F, −2418 → 0x1D2D, −2417 → 0x1D2C,
        −2412 → 0x1D2B, other → 0x1D29; ok 0x1D28
    Send 0xAC2D …ITEM_ID_CHANGE_ACK { u16 nError, hdr, cell, u16 lock, u64 key, u16 nGameItemID, u16 nMoneyCardItemID, u64 money } (0x20)
```

## 11. Gamble coins, house dice and slot machines (dept 47)

Procedures only in `w00_Character` (2017); their header comments are copied from the dice procedures, the codes in the bodies
are the ones the binary tests: −3311/−3312/−3313 bad char/money/coin, −3322 not enough coins, −3324 character money missing,
−3327 exchange limit, −3328 not enough money, −3331 coin item missing, −3332 delete failed *(db-backup)*. Tables `tGambleCoin
{nCharNo, nCoin}`, `tGambleCoinExchangeLog`, `tGambleSlotMachineLog`, `tGambleJackpot {sGameName, nBattingUnit, nJackpotCoin}`,
`tGambleJackpotLog`.

```pseudo
0xBC06 NC_GAMBLE_COIN_DB_ADD_REQ { hdr, u16 nLockIndex @6, u64 nCoin @8 }    @ FUN_004248b0 (`CPFsCharacter::fc_NC_GAMBLE_COIN_DB_ADD_REQ`)
    usp_Gamble_addCoin(charNo, itemKey = never written (stack garbage), nCoin)
        # (db-backup) coins are added only when that key is an item of the character, which is then deleted: with an
        # uninitialised key the call fails (original bug) D03-B21 (only if the 2016 procedure body is the w00 one)
    Send 0xBC07 { hdr, u16 nError (0x2828 ok / 0x2829), u16 nLockIndex }

0xBC0A NC_GAMBLE_EXCHANGEDCOIN_DB_INFO_REQ { u32 nCharNo, i32 dChackDate (time_t) }   @ FUN_00424a40
    GambleSystem_GetExchangedCoin: usp_Gamble_getExchangedCoin(charNo, date) → SUM(nExchangedCoin)    @ FUN_0046e020
    Send 0xBC0B { u32 nCharNo, u64 nExchangedCoin (0 on error) }

0xBC11 NC_GAMBLE_COIN_DB_BUY_REQ { hdr, u16 lock @6, u64 nCoin @8, u64 nMoney @0x10, u32 nCanExchangeMaxCoin @0x18,
        i32 tExchangedCoinDate @0x1C }                              @ FUN_00424bb0
    usp_Gamble_setMoneyToCoin(charNo, nMoney, nCoin, limit, date) : −3324 → 0x280A, −3328 → 0x280D, −3327 → 0x280C,
        other → 0x2811, call failure → 0x280B; ok 0x2808
    Send 0xBC12 { hdr, u16 lock, u16 nError }
0xBC15 NC_GAMBLE_COIN_DB_SELL_REQ { hdr, u16 lock, u64 nCoin @8, u64 nMoney @0x10 }     @ FUN_00424dd0
    usp_Gamble_setCoinToMoney(charNo, nMoney, nCoin): −3324 → 0x2812, −3322 → 0x2814, other → 0x2811, call failure → 0x2813; ok 0x2810
    Send 0xBC16 { hdr, u16 lock, u16 nError }
0xBC19 NC_GAMBLE_COIN_DB_USE_COINITEM_REQ { hdr, u64 nItemReg @6, u64 nCoin @0xE, u16 nLockIndex @0x16 }     @ FUN_00424fc0
    usp_Gamble_addCoin(charNo, nItemReg, nCoin): 0 → 0x700, −3331 → 0x702, other → 0x706, call failure → 0x2813
    Send 0xBC1A { hdr, u64 nCoin, u16 lock, u16 nError }

0xBC6C NC_GAMBLE_DICE_TAISAI_DB_ALL_RANK_REQ { hdr }                 @ FUN_00421e30
    usp_Gamble_getDiceRank() rows (TOP 20) { name, u32 } → Send 0xBC6D { u16 nError (0x2690 / 0x2694), hdr, u8 cnt, ranks[] }
0xBC78 NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_REQ { hdr, u8 DiceNum[3] @6, u16 nResultCnt @9, GDT_DiceRollApplyResult[n] @0xB }
                                                                    @ FUN_00421a30
    as 0xAC23 with usp_Gamble_setDice / usp_Gamble_setDiceResult (house game, no machine key): −2492 → 0x2682, −2413 → 0x2683,
    other → 0x2681, ok 0x2680; per-result codes 0x2684–0x2688 dead in the same way (D03-B23)
    Send 0xBC79 { u16 nError, hdr, i32 nGameNo, u16 cnt, results[] }
0xBC7A NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_LOG_CMD             @ FUN_00421d60
    as 0xAC25 with usp_Gamble_setDiceLog; no answer

0xBCD3 NC_GAMBLE_SLOTMACHINE_DB_RESULT_REQ { hdr, u16 lockindex @6, u32 PlayerRegistNumber @8, char CardDisplay[10] @0xC,
        u8 IsJackPot @0x16, u32 JackPotAccumulate @0x17, u16 BetUnit @0x1B, u8 BetLine @0x1D, u16 nJackpotRate @0x1E, u32 WinMoney @0x20 }
                                                    @ FUN_004251a0 (`CPFsCharacter::fc_NC_GAMBLE_SLOTMACHINE_DB_RESULT_REQ`)
    usp_Gamble_setSlotMachineResult(player, BetUnit, BetLine, CardDisplay, isWin = WinMoney ≠ 0, WinMoney, IsJackPot, rate, …)
        # (db-backup) log row, coin updates (−3333 …), jackpot pot / jackpot log (−3335 … −3339)
    nRet −3339 → 0x2901, −3338 … −3333 → 0x2906, −3316 → 0x2905, −3315 → 0x2904, −3314 → 0x2903, −3311 → 0x2902,
        anything else (incl. 0) → 0x2900; call failure → 0x2906
    Send 0xBCD4 { hdr, u16 lock, u16 nError }

0xBCD5 NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_REQ { u8 nSlotMachineNum, { u8 Machine, u16 BetUnits }[n] }   (no hdr)   @ FUN_00425490
    n > 3 → logged "too many machine req", processed anyway
    per machine: answer { u8 Machine, u16 nError 0x2940, u32 JackPotPrice, u8 RankNumber, SLOTMACHINE_JackPotRank[] {name[20], u32} }
        usp_Gamble_getJackpotCoin("SlotMachine", BetUnits) rows { u64 unit, u64 coin } → JackPotPrice when unit matches;
            failure → Send { …, 0x2941 }, then continue with the ranking (nError is not reset: later sends still say 0x2941)
        usp_Gamble_getJackpotRanking("SlotMachine", BetUnits) rows { name, u32 } (≤ 0x1C12 bytes); failure → Send { …, 0x2942 }
            and fall through to the common send below as well
        Send 0xBCD6 NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_ACK
        # one machine can thus produce up to three answers
    # the packet size starts at 8 once and grows with every rank of every machine, so the answers for the second and third
    # machine carry the earlier machines' rank bytes as trailing garbage (original bug) D03-B22
```

## 12. Card collection (dept 49)

Tables *(db-backup, w00 only)*: `tCollectionCard { nCharNo, nCardID, nSerialNo, nStarNumber }`, `tCollectionFavorites { nCharNo,
nSlotNo, nCardID }`, `tCollectionReward { nCharNo, nReward }`, card serial counters (`usp_Collection_getSerialList` /
`usp_Collection_setSerial`).

```pseudo
CollectionCardSerial (global @ DAT_00a4593c: critical section + vector<{i32 cardId, u64 count}> + db pointer)
    load @ FUN_0046ea70: usp_Collection_getSerialList() rows { i32 cardId, u64 count } (log "…GetDBCollectionCardCount - DB Error")
    GetCollectionCardSerial(cardId) @ FUN_0046e7e0: not loaded → log, return 0; else under the lock count += 1 (new card: 1),
        usp_Collection_setSerial(cardId, count) (log "… DB Error : CardID = %d / %d, Count"), return count
    used by ItemAttr_Save for a sealed card (class 30) whose serial is 0 (§1.3): serial 0 returned → the save returns 0 without
    writing any option row

0xC414 NC_COLLECT_CHARACTERDB_UP_GET_CARDCOUNT_CMD {}                @ LAB_00427cf0 (read in the asm)
    CollectionCardSerial.load(db); failure → log "ERROR - fc_NC_COLLECT_CHARACTERDB_UP_GET_CARDCOUNT_CMD, DB Data Get Fail"; no answer
    # the only caller of the load: until a zone sends 0xC414 every new sealed card is stored without serial and options

0xC402 NC_COLLECT_PEEPING_DB_REQ { u32 clientregnum, u16 clientzonehandle, Name5 targetcharname @6 }     @ FUN_00427040
    charNo = p_Char_GetCharNo(name); 0 → both answers with 0x2BC1
    usp_Collection_getCardList(charNo) rows { u16 cardId, u32 serial, u8 star, datetime → time_t } (11 bytes each)
        failure → 0x2BC2
    Send 0xC403 NC_COLLECT_PEEPING_DB_COLLECT_ACK { regnum, handle, name, u16 err 0x2BC0, { u16 count, cards[] } }
    usp_Collection_getFavoritesList(charNo) rows { u16 slot, u16 cardId }; failure → 0x2BC3
    Send 0xC404 NC_COLLECT_PEEPING_DB_COLLECT_BOOKMARK_ACK { regnum, handle, name, u16 err, { u16 count, entries[] } }

0xC409 NC_COLLECT_REGIST_REQ { u32 regnum, u16 handle, u16 lock @6, u64 CardKey @8, CardInfo { u8 invenslot @0x10, u16 CardID @0x11,
        u8 Star @0x13, u32 Serial @0x14, u16 err } }                @ FUN_004275c0
    usp_Collection_setCard(regnum, CardID, Serial, Star, CardKey)   # (db-backup) card item must exist; UPSERT tCollectionCard
                                                                     # (an existing card gets the new serial/star); delete the item
    Send 0xC40A { regnum, handle, lock, CardInfo (8 bytes), u16 err 0x2B90 ok / 0x2B96 }

0xC40D NC_COLLECT_BOOKMARK_REGIST_DB_REQ { u32 regnum, u16 handle, u16 BookMarkSlot @6, u16 CardID @8 }   @ FUN_004277a0
    usp_Collection_setFavorites(regnum, (u8) slot, CardID, set = CardID ≠ 0xFFFF)   # 0xFFFF = clear the slot
        failure: nRet −5555 → 0x2BA3, else 0x2BA2; ok 0x2BA0
    Send 0xC40E { regnum, handle, slot, CardID, u16 err }

0xC411 NC_COLLECT_REWARD_DB_REQ { u32 regnum, u16 handle, u16 RewardID @6, u64 itemKey @8, u16 itemId @0x10, attr @0x12 }
        (2016: 0x77 bytes; the 2017 struct stops at RewardID)       @ FUN_00427970
    Item_Insert(rec{itemKey, owner = regnum, type 2 (reward storage), free slot, itemId}, attr, useEmptySlot) fails → 0x2BAD
    usp_Collection_setReward(regnum, RewardID)
        # (db-backup) an existing (nCharNo, nReward) row → −2222: a reward is given once per character
        fails → p_Item_Delete(itemKey); nRet −2222 → 0x2BA9, else 0x2BAE
            # if that delete fails too, the reward item stays (only logged): the one way to get a second reward item
    ok: Log 0x044F; err 0x2BA8
    Send 0xC412 NC_COLLECT_REWARD_DB_ACK { regnum, handle, RewardID, u16 err }
```

**Answer to Z07 §7:** a repeated `0xC411` for the same `RewardID` is refused by `usp_Collection_setReward` (`−2222` → `0x2BA9`), and
the reward item created first is deleted again, so the zone's missing "already rewarded" bookkeeping does not duplicate rewards
(as long as the 2016 procedure has the w00 body's duplicate check).

## 13. Pets (dept 53)

Pet procedures have no source in any backup (D06); parameters from the binds. Pets live in a table read by `usp_Pet_getInfo`
(columns: u32, name, u8 mind, u8 stress). Common checks (log only, **no answer**): no session (`Error=0x31C1`), no DB (`0x31C0`),
`nPetRegNum == −1` (`0x3400`) for SET_TENDENCY, SET_NAME, LOAD_INFO and REMOVE.

```pseudo
0xD40D NC_PET_CREATE_DB_REQ { u16 nMasterHandle, u32 nMasterRegNo @2, Name4 sPetName @6, u8 nPetMind @0x16, u8 nPetStress @0x17 }
                                                                    @ FUN_0042b6b0 (`fc_NC_PET_CREATE_DB_REQ`)
    usp_Pet_setCreate(master, name[16], mind, stress, out nRet) → result row u32 petNo
    call failure → 0x3409, petNo −1; petNo == −1 → 0x3400; else 0x3408
    Send 0xD40E NC_PET_CREATE_DB_ACK { u16 nError, u16 nMasterHandle, u32 nPetRegNum }
0xD40B NC_PET_LOAD_INFO_DB_REQ { u16 nMasterHandle, u32 nPetRegNum }  @ FUN_0042bcc0
    usp_Pet_getInfo(petNo, out nRet) row { u32, name, u8 mind, u8 stress }
    Send 0xD40C NC_PET_LOAD_INFO_DB_ACK { u16 nError 0x3420 ok / 0x3421 (name "", mind/stress 0), u16 handle, u32 petNo, Name4 name,
        u8 mind, u8 stress } (0x1A)
0xD403 NC_PET_SET_NAME_DB_REQ { u16 nMasterHandle, u32 nPetRegNum, Name4 sPetName }    @ FUN_0042ba70
    usp_Pet_setName(petNo, name[16]) → Send 0xD404 { u16 nError 0x3418 ok / 0x3419, u16 handle, u32 petNo }
0xD401 NC_PET_SET_TENDENCY_DB_REQ { u16 nMasterHandle, u32 nPetRegNum, u8 nPetMind, u8 nPetStress }   @ FUN_0042b920
    usp_Pet_setTendency(petNo, mind, stress); failure logged; no answer
0xD40F NC_PET_REMOVE_DB_REQ { u16 nMasterHandle, u32 nPetRegNum, u32 nMasterRegNo }    @ FUN_0042bf30
    usp_Pet_setDelete(petNo, master) → Send 0xD410 { u16 nError 0x3428 ok / 0x3429, u16 handle }
```

**Answer to Z07 §9:** the codes the zone expects are the Character server's: create `0x3408` (else `0x3409`, or `0x3400` when the
procedure returns pet number −1), load `0x3420` / `0x3421`, rename `0x3418` / `0x3419`, remove `0x3428` / `0x3429`. A pet number of
−1 in LOAD/SET_NAME/REMOVE produces no answer at all (the zone's request then never completes, D03-B24). The pet item's
attribute keeps only the pet number (option 2700) and the name (`usp_Pet_setName` from `ItemAttr_Save`, §1.3).

## 14. Trade and booths (Z06 owns the windows)

```pseudo
TradeMoveContents(key, itemId, fromOwner, toOwner) → ok                         @ FUN_00403e90
    attr = GetItemOptions(key) (fails → not ok)
    ITEMCHEST: for each content key (count = attr[0] & 0x0F): p_Item_IsValidOwner(content, …) ≠ 0 → stop;
        p_Item_SetStorageAndOwner_UseEmptyStorage(content, toOwner, type 10) fails → move the earlier ones back to fromOwner
        (errors logged) and fail
    CAPSULE: the same for its one content key (back-move on failure)
    other classes: nothing to move
    # the contents of a traded chest/capsule follow it into the new owner's type-10 box

0x343B NC_ITEMDB_ITEMTRADE_REQ { hdr A @0, hdr B @6, u16 lockindexA @0xC, u16 lockindexB @0xE, cen { u8 from ('A' or 'B') @0x10,
        u64 cen @0x11, u64 result_money_from @0x19, u64 result_money_to @0x21 }, u8 tradenumber @0x29,
        tradeitem[n] @0x2A { invenA { u64 regnum, u16 id, u16 lot, u8 invenloc }, invenB { … } } (0x1A each) }
                                                                    @ FUN_0040ca80 (`fc_NC_ITEMDB_ITEMTRADE_REQ`)
    if cen ≠ 0: p_Char_MoneyMove(from = from=='A' ? A : B, to = the other, cen) fails → err 0x84A
    for each tradeitem (A side set = key ≠ all-ones, B likewise):
        only A: p_Item_IsValidOwner(A item, A) must be 0; TradeMoveContents(A item, A → B);
                p_Item_SetStorageAndOwner(A item, owner B, type 9 (inventory), slot invenB.invenloc); any failure → 0x84F
        only B: the mirror image; failure → 0x850
        both:   both owner checks, both TradeMoveContents, p_Item_ExchangeStorageAndOwner(B item → A at invenA.invenloc,
                A item → B at invenB.invenloc): call failure → 0x84B, nRet 1/2/3 → 0x84C/0x84D/0x84E; owner check failures → 0x84F/0x850
        on a failure: money moved back (MoneyMove reversed, error logged), then every earlier item moved back to its old
            owner/slot (errors logged) — the contents moved by TradeMoveContents are not moved back
    success: Log 0x0460 NC_LOG_GAME_MONEY_TRADE_INCOME / 0x0461 …_OUTGO (if cen), 0x044A NC_LOG_GAME_ITEM_TRADE per item;
             raw { 0x0A, 0x343D NC_ITEMDB_ITEMTRADESUC_ACK, hdr A, lockA } and the same for B
    failure: raw { 0x0C, 0x343C NC_ITEMDB_ITEMTRADEFAIL_ACK, hdr A, lockA, err } and the same for B
    # the zone's lot fields (invenX.lot) are only logged: stacks change hands whole

0x3453 NC_ITEMDB_BOOTHTRADE_ALL_REQ { hdr seller @0, hdr buyer @6, u32 boothSeller @0xC, u32 boothBuyer @0x10, u16 lockSeller @0x14,
        u16 lockBuyer @0x16, u8 isSellBooth @0x18, u64 itemregnum @0x19, u16 itemid @0x21, u8 invenslotBuyer @0x23, u64 nLot @0x24,
        u64 price @0x2C, u64 sellerResultMoney @0x34, u64 buyerResultMoney @0x3C }    @ FUN_0040f510 (`…fc_NC_ITEMDB_BOOTHTRADE_ALL_REQ`)
    answer = 0x3456 NC_ITEMDB_BOOTHTRADE_ACK { hdr seller, hdr buyer, u16 lockSeller, u16 lockBuyer,
        u32 nBoothTradeType = isSellBooth ? 4 SELL_BOOTH_TRADE_ALL : 1 BUY_BOOTH_TRADE_ALL, u64 nItemKey (sell booths only),
        u16 nLotTraded (always 0 here: never written except the zero init), u16 err } (0x20)
    TradeMoveContents(item, seller → buyer) fails → err 0xA4E
    usp_SafeTrade_setAll(buyer, seller, price, item, type 9, invenslotBuyer)
        # (db-backup, w00 only, KR) −2621 item not the seller's, −2622 bad storage type, −2623 p_Char_MoneyMove, −2624 p_Item_SetStorageAndOwner
        −2624 → 0xA4E, −2623 → 0xA4A, −2621 / other → 0xA44 — the chest/capsule contents already moved stay with the buyer
            (original bug) D03-B25
    ok 0xA41: Log 0x045B NC_LOG_GAME_ITEM_BOOTH_BUY and 0x045C …_BOOTH_SELL
    Send 0x3456 (one packet; the zone applies both locks, Z05 §9.11)

0x3454 NC_ITEMDB_BOOTHTRADE_MERGE_REQ { hdrs, booth chars, locks, u8 isSellBooth, u16 itemid @0x19, u64 lotseller @0x1B,
        u64 lotbuyer @0x23, u16 mergelot @0x2B, u64 price @0x2D, u8 allmove @0x35, u16 sellerResultLot, u16 buyerResultLot, … }
                                                                    @ FUN_0040f950
    no lot class → 0xA63
    usp_SafeTrade_setMerge(buyer, buyerKey, optType, seller, sellerKey, optType, price, mergelot)
        −2627 / −2625 → 0xA4F, −2626 → 0xA50, −2624 → 0xA4E, −2623 → 0xA4A, other → 0xA44; ok 0xA41 (logs 0x045B / 0x045C)
    Send 0x3456 { …, type 5 / 2, … }

0x3455 NC_ITEMDB_BOOTHTRADE_LOT_REQ { hdrs, booth chars, locks, u8 isSellBooth, u16 itemid @0x19, u64 lotseller @0x1B,
        PROTO_ITEM_CREATE lotcreate @0x23, u16 createlot @0x49, u64 price @0x4B, u16 sellerResultLot @0x53, u16 buyerResultLot @0x55, … }
                                                                    @ FUN_0040feb0
    no lot class → 0xA63
    usp_SafeTrade_setLot(buyer, new key, type, slot, itemId, flags, optType, seller, sellerKey, optType, price, createlot)
        # (db-backup) splits createlot off the seller's stack into a new buyer item (13 params, = binary)
        −2629 / −2626 → 0xA50, −2628 → 0xA52, −2627 / −2625 → 0xA4F, −2624 → 0xA4E, −2623 → 0xA4A, other → 0xA44; ok 0xA41
    Send 0x3456 { …, type 6 / 3, … }
```

The booth price and lots come from the zone; the procedures move the money with `p_Char_MoneyMove` *(db-backup)* without a price
check. The client shows `0xA4D`–`0xA52` as DB-failure texts (Z05 §10), so `0xA44`, `0xA4A`, `0xA4E`, `0xA4F`, `0xA50`, `0xA52` are
understood; `0xA63` falls back to "Failed to sell the item.".

## 15. Procedures called by these handlers

Every `{CALL}` of the handlers above (wrapper = the `SQL_<procedure>` function, D02 names); `MISSING` = no source in any backup (D06). Some procedures have a second wrapper copy: `usp_GuildAcademy_depositMoney` @ FUN_00456640,
`usp_ChargeItem_UseSkillPowerInitDel` @ FUN_00464070, `usp_ChargeItem_UseSkillPowerInitLotChange` @ FUN_00464110 (the ones the
0x3487 / 0x9006 handlers call).

| Procedure | Params | Wrapper(s) | Sources (`=` same param count; C = Character.bak, w00 = w00_Character.bak) |
|---|---|---|---|
| `p_Char_AddExp` | 2 | FUN_00459c60 | C:=[KR] w00:=[KR] |
| `p_Char_ChangeClass` | 2 | FUN_00459d60 | C:=[KR] w00:=[KR] |
| `p_Char_DelChargedBuff` | 3 | FUN_0045a9a0 | C:=[KR] w00:=[KR] |
| `p_Char_GetCharNo` | 2 | FUN_00458790 | C:=[KR] w00:=[KR] |
| `p_Char_MoneyAdd` | 3 | FUN_00459440 | C:=[KR] w00:=[KR] |
| `p_Char_MoneyGet` | 3 | FUN_004593a0 | C:=[KR] w00:=[KR] |
| `p_Char_MoneyMove` | 4 | FUN_00459580 | C:= w00:= |
| `p_Char_MoneySub` | 3 | FUN_004594e0 | C:=[KR] w00:=[KR] |
| `p_Char_SetChargedBuffer` | 6 | FUN_0045a8b0 | C:=[KR] w00:=[KR] |
| `p_Char_SetTitle` | 5 | FUN_00459880 | C:=[KR] w00:=[KR] |
| `p_Char_StatPoint_Dec` | 3 | FUN_00459a60 | C:=[KR] w00:=[KR] |
| `p_Char_SubExp` | 2 | FUN_00459ce0 | C:=[KR] w00:=[KR] |
| `p_Guild_Get` | 1 | FUN_00453640 | C:=[KR] w00:=[KR] |
| `p_Guild_GetMyNo` | 2 | FUN_00454750 | C:=[KR] w00:=[KR] |
| `p_Guild_MoneySub` | 6 | FUN_00453b10 | C:=[KR] w00:=[KR] |
| `p_Item_BuyAll` | 10 | FUN_00462380 | C:9[KR] w00:= |
| `p_Item_BuyLot` | 8 | FUN_00462600 | C:7[KR] w00:= |
| `p_Item_CostumWeapon_Endure_Set` | 4 | FUN_004634a0, FUN_004639f0 | C:=[KR] w00:=[KR] |
| `p_Item_CostumWeapon_Endure_Update` | 8 | FUN_004631b0, FUN_00463700 | C:=[KR] w00:=[KR] |
| `p_Item_Create` | 7 | FUN_00461270 | C:=[KR] w00:=[KR] |
| `p_Item_Create_UseEmptyStorage` | 7 | FUN_00461270 | C:=[KR] w00:=[KR] |
| `p_Item_Delete` | 2 | FUN_00461560 | C:=[KR] w00:=[KR] |
| `p_Item_ExchangeStorage` | 7 | FUN_004620c0 | C:=[KR] w00:=[KR] |
| `p_Item_ExchangeStorageAndOwner` | 9 | FUN_004621c0 | C:=[KR] w00:=[KR] |
| `p_Item_Furniture_Endure_Update` | 8 | FUN_00462f40 | C:=[KR] w00:=[KR] |
| `p_Item_GetData` | 8 | FUN_004616e0 | C:=[KR] w00:=[KR] |
| `p_Item_GetListType` | 2 | FUN_004615e0 | C:=[KR] w00:=[KR] |
| `p_Item_GetMobListAll` | 1 | FUN_00461a90 | C:=[KR] w00:=[KR] |
| `p_Item_GetOption` | 4 | FUN_004618b0 | C:=[KR] w00:=[KR] |
| `p_Item_GetOptionAll` | 1 | FUN_00461960 | C:=[KR] w00:=[KR] |
| `p_Item_GetStorageAndOwner` | 5 | FUN_00461e30 | C:=[KR] w00:=[KR] |
| `p_Item_GetStorageEmptyList` | 4 | FUN_00464b40 | w00:=[KR] |
| `p_Item_GetTitle` | 5 | FUN_00461bb0 | C:=[KR] w00:=[KR] |
| `p_Item_IsValidOwner` | 3 | FUN_004622f0 | C:=[KR] w00:=[KR] |
| `p_Item_Merge_New` | 8 | FUN_00462990 | C:=[KR] w00:=[KR] |
| `p_Item_MiniHouse_Effect_Resource_Del` | 6 | FUN_00462e70 | MISSING |
| `p_Item_SellAll_LotCheck` | 6 | FUN_00462710 | C:=[KR] w00:=[KR] |
| `p_Item_SellLot_LotCheck` | 6 | FUN_004627e0 | C:=[KR] w00:=[KR] |
| `p_Item_SetMobList` | 5 | FUN_004619c0 | C:=[KR] w00:=[KR] |
| `p_Item_SetOption` | 4 | FUN_00461800 | C:=[KR] w00:=[KR] |
| `p_Item_SetStorage` | 4 | FUN_00461f00 | C:=[KR] w00:=[KR] |
| `p_Item_SetStorageAndOwner` | 5 | FUN_00461fc0 | C:=[KR] w00:=[KR] |
| `p_Item_SetStorageAndOwner_UseEmptyStorage` | 5 | FUN_00461fc0 | C:=[KR] w00:=[KR] |
| `p_Item_SetTitle` | 5 | FUN_00461af0 | C:=[KR] w00:=[KR] |
| `p_Item_Split_N_Merge_New` | 10 | FUN_00462aa0 | C:=[KR] w00:=[KR] |
| `p_Item_Upgrade_CelllInAll` | 21 | FUN_00462be0 | C:=[KR] w00:=[KR] |
| `p_MiniHouseURL_Get` | 2 | FUN_0045aaa0 | MISSING |
| `p_MiniHouseURL_Set` | 2 | FUN_0045ab20 | MISSING |
| `p_Skill_Del` | 3 | FUN_00452e90 | C:=[KR] w00:=[KR] |
| `p_Skill_ResetPower` | 2 | FUN_00453070 | C:=[KR] w00:=[KR] |
| `p_User_Deposit` | 5 | FUN_0045a670 | C:=[KR] w00:=[KR] |
| `p_User_MoneyGet` | 3 | FUN_0045a810 | C:=[KR] w00:=[KR] |
| `p_User_Withdraw` | 5 | FUN_0045a740 | C:=[KR] w00:=[KR] |
| `usp_Character_getFriendpoint` | 2 | FUN_00460600 | w00:=[KR] |
| `usp_Character_getShortCutList` | 2 | FUN_0045d820 | w00:=[KR] |
| `usp_Character_setFriendpoint` | 2 | FUN_00460710 | w00:3[KR] |
| `usp_Character_setShortCut` | 5 | FUN_0045d920 | w00:=[KR] |
| `usp_ChargeItem_Draw` | 3 | FUN_00463cb0 | C:=[KR] w00:=[KR] Fixes:usp_ChargeItem_Draw.sql:=[KR] |
| `usp_ChargeItem_GetList` | 1 | FUN_00463c50 | C:=[KR] w00:=[KR] Fixes:usp_ChargeItem_GetList.sql:=[KR] |
| `usp_ChargeItem_UseStatPointInitDel` | 3 | FUN_00463f00 | C:=[KR] w00:=[KR] |
| `usp_ChargeItem_UseStatPointInitLotChange` | 5 | FUN_00463fa0 | C:=[KR] w00:=[KR] |
| `usp_ChatColor_setBalloon` | 3 | FUN_0045fed0 | w00:=[KR] |
| `usp_ChatColor_setFont` | 3 | FUN_0045fda0 | w00:=[KR] |
| `usp_Collection_getCardList` | 2 | FUN_00466970 | w00:=[KR] |
| `usp_Collection_getFavoritesList` | 2 | FUN_00466a70 | w00:=[KR] |
| `usp_Collection_getSerialList` | 1 | FUN_00467170 | w00:=[KR] |
| `usp_Collection_setCard` | 6 | FUN_00466b70 | w00:=[KR] |
| `usp_Collection_setFavorites` | 5 | FUN_00466ce0 | w00:=[KR] |
| `usp_Collection_setReward` | 3 | FUN_00466e30 | w00:=[KR] |
| `usp_Collection_setSerial` | 3 | FUN_00467050 | w00:=[KR] |
| `usp_Dice_chgMachineToMoneycard` | 6 | FUN_0045d4e0 | C:=[KR] w00:=[KR] |
| `usp_Dice_getDiceExpect` | 3 | FUN_0045cef0 | C:=[KR] w00:=[KR] |
| `usp_Dice_getDiceRank` | 3 | FUN_0045d2f0 | C:=[KR] w00:=[KR] |
| `usp_Dice_setDice` | 4 | FUN_0045c840 | C:=[KR] w00:=[KR] |
| `usp_Dice_setDiceLog` | 9 | FUN_0045cc60 | C:=[KR] w00:=[KR] |
| `usp_Dice_setDicePay` | 4 | FUN_0045d0e0 | C:=[KR] w00:= |
| `usp_Dice_setDiceResult` | 4 | FUN_0045ca50 | C:=[KR] w00:= |
| `usp_Gamble_addCoin` | 4 | FUN_00466320 | w00:= |
| `usp_Gamble_getDiceRank` | 1 | FUN_0045f210 | w00:=[KR] |
| `usp_Gamble_getExchangedCoin` | 3 | FUN_004663f0 | w00:=[KR] |
| `usp_Gamble_getJackpotCoin` | 2 | FUN_004668e0 | w00:= |
| `usp_Gamble_getJackpotRanking` | 3 | FUN_00466830 | w00:= |
| `usp_Gamble_setCoinToMoney` | 4 | FUN_00466610 | w00:= |
| `usp_Gamble_setDice` | 2 | FUN_0045eba0 | w00:=[KR] |
| `usp_Gamble_setDiceLog` | 9 | FUN_0045ef80 | w00:=[KR] |
| `usp_Gamble_setDiceResult` | 4 | FUN_0045ed70 | w00:= |
| `usp_Gamble_setMoneyToCoin` | 6 | FUN_00466510 | w00:= |
| `usp_Gamble_setSlotMachineResult` | 9 | FUN_004666e0 | w00:= |
| `usp_Guild_GetToken` | 3 | FUN_00453f50 | C:= w00:= |
| `usp_Guild_SetToken` | 3 | FUN_00454140 | C:= w00:= |
| `usp_GuildAcademy_getMoney` | 2 | FUN_00456db0 | C:=[KR] w00:=[KR] |
| `usp_GuildAcademy_withdrawMoney` | 4 | FUN_00456510 | C:=[KR] w00:= |
| `usp_HolyPromise_setMoney` | 4 | FUN_00457bd0 | C:=[KR] w00:=[KR] |
| `usp_Item_Add_EnchantGem` | 7 | FUN_00465540 | w00:=[3RD?] |
| `usp_Item_Add_EnchantSocket` | 7 | FUN_00465760 | w00:=[3RD?] |
| `usp_Item_Del_EnchantGem` | 8 | FUN_00465640 | w00:=[3RD?] |
| `usp_Item_Get_EnchantAll` | 2 | FUN_00465930 | w00:=[3RD?] |
| `usp_Item_GuildToken_BuyAll` | 8 | FUN_004641e0 | C:=[KR] w00:=[KR] |
| `usp_Item_GuildToken_BuyLot` | 6 | FUN_00464400 | C:=[KR] w00:=[KR] |
| `usp_Item_Set_EnchantGemLot` | 5 | FUN_00465860 | w00:=[3RD?] |
| `usp_Item_setPutOnBelonged` | 6 | FUN_004644d0 | w00:= |
| `usp_Item_setPutOnBelongedCancel` | 8 | FUN_004649a0 | w00:= |
| `usp_Item_setPutOnBelongedExchange` | 9 | FUN_00464710 | w00:=[KR] |
| `usp_LinkScroll_SetDestMap` | 3 | FUN_00460950 | MISSING |
| `usp_Minihouse_delGate` | 3 | FUN_0045adf0 | C:=[KR] w00:=[KR] |
| `usp_Minihouse_getGateList` | 2 | FUN_0045aba0 | C:=[KR] w00:=[KR] |
| `usp_Minihouse_setGate` | 6 | FUN_0045ac90 | C:=[KR] w00:=[KR] |
| `usp_Minihouse_setVisitorCount` | 2 | FUN_0045af00 | C:=[KR] w00:=[KR] |
| `usp_Pet_getInfo` | 2 | FUN_00467670 | MISSING |
| `usp_Pet_setCreate` | 5 | FUN_00467260 | MISSING |
| `usp_Pet_setDelete` | 3 | FUN_00467810 | MISSING |
| `usp_Pet_setName` | 3 | FUN_00467430 | MISSING |
| `usp_Pet_setTendency` | 4 | FUN_00467540 | MISSING |
| `usp_SafeTrade_setAll` | 7 | FUN_00464d50 | w00:=[KR] |
| `usp_SafeTrade_setLot` | 13 | FUN_00465250 | w00:=[KR] |
| `usp_SafeTrade_setMerge` | 10 | FUN_00464fb0 | w00:=[KR] |

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D03-B1 | 0x340A, 0x34A0, 0x34B9 (`ItemBuy_Create`) | when the attribute write fails after `p_Item_BuyAll` committed, the item is deleted and only the cen price is refunded | fame and gamble coins of a failed purchase are lost | refund fame and coins too, or one transaction |
| D03-B2 | 0x34B9 / 0x34BB | DB failures answer `0x366E`/`0x366F`, codes the 2016 client has no text for | a failed repurchase is silent | use the client's `0x366B`–`0x366D` |
| D03-B3 | 0x34B0/0x34B1, 0x34BD, 0x34BF, 0x34C1, 0x34CB, 0x34CD, 0x34B5, 0x34B7, 0x34C9, 0x3476, 0x9005/0x9006 | multi-step changes run as separate committed procedure calls; a later failure keeps the earlier steps (consumed stuff, spent friend points, new class, made products) | items/points lost or half-applied state on any DB error | one transaction per request |
| D03-B4 | 0x3410 EQUIP | the belong option type is kept in the global `DAT_006edd58`, shared by all session-worker threads | two concurrent equips of different classes can write the wrong option type | a local variable |
| D03-B5 | 0x3413, 0x347F | UNEQUIP/REINFORCEUNEQUIP failures send the EQUIP code `0x28A`, laid out `{err, lock}` where the zone reads the lock first (Z05-B5) | wrong lock freed on the zone | own code, `{lock, err}` |
| D03-B6 | 0x3438, 0x347A, 0x3444, 0x345F/0x3461, 0x8C3B | packets sized larger than what is written (`0x3439`/`0x347B` 7th byte, `0x3445` error word, deposit/withdraw cen on failure, `0x8C3C` one byte, PICKMONEY's `0x0446` log map x/y + item key) | stale stack bytes on the wire | exact sizes / zeroed fields |
| D03-B7 | 0x347A (Positive) | `0x0462` MONEY_CHANGE log writes "before" = now + cen for an increase | wrong GameLog value | now − cen |
| D03-B8 | 0x3444, 0x3471, 0x3482 | item records appended from list+3 with a length measured from list+0 | 3 stale bytes after the last record | length − 3 |
| D03-B9 | 0x345F/0x3461, 0x3474 | not-enough-money results `0xF8A`/`0xF91`/`0xF9A` are not the codes the client knows (`0xF83`; guild withdraw `0x1481`–`0x1483`) | refused deposits are silent; a poor guild reads as "You have no authority" | the client's codes |
| D03-B10 | 0x3463 | the row index is advanced per row and again per part | with > 511 rows everything after the first part is dropped | advance once |
| D03-B11 | item logs 0x043F/0x0446/0x0447/0x0456 | the map field is the constant "Need" / "Need Cen" | GameLog has no map | the player's map |
| D03-B12 | 0x3447 / 0x34D1 (amulet random options) | the option re-roll runs after the upgrade committed; its failure answers an upgrade failure | zone frees the reservation while the DB has the upgrade (fixed by relog) | report success, or one transaction |
| D03-B13 | 0x34D3 | no upgrade option types → `0x3806` sent, then the procedure still runs with uninitialised types and a second answer follows | DB writes with garbage option types; two answers for one lock | return after the first answer |
| D03-B14 | 0x34AE | a failed sub-mover delete only deletes the new rare mover; the main mover is already gone | player loses the main mover | restore the main mover |
| D03-B15 | 0x34BD | `usp_Character_getShortCutList` failure returns without any answer | zone lock never freed (class already changed) | send `0x34BE` with an error |
| D03-B16 | 0x346D | a content read failure gives `0x9B8`, which the zone does not treat as an error | chest opened and deleted, the unread content stays orphaned in type 10 | fail the whole request |
| D03-B17 | 0x3444/0x3471/0x3482 (`ItemRecords_Build`) | an attribute read failure returns without setting the length | the answer is appended with an undefined length | fail the open |
| D03-B18 | 0x34A2 | content read failure `0x2847` still sends the (stale) content record, the zone treats it as success | broken GETFROMCAPSULE request | an error code the zone tests |
| D03-B19 | 0x344D (`CreateItemList`) | rollback walks the records with `datasize × 0x72` instead of `datasize + 1` | after a mid-list failure only the first item is deleted while the price is refunded | correct stride |
| D03-B20 | 0x34B5 | an unknown chat-colour type consumes the item and answers success | item lost, no colour | an error before consuming |
| D03-B21 | 0xBC06 | `usp_Gamble_addCoin` gets an uninitialised item key (w00 body: coins only added when that key is the player's item) | coin additions fail (if the 2016 body is the w00 one) | pass 0 and a body that accepts it |
| D03-B22 | 0xBCD5 | the answer size starts at 8 once and grows over all machines; a jackpot or ranking read failure sends an extra answer (up to three per machine) and nError is not reset | trailing garbage in the 2nd/3rd machine's answer; duplicate answers with stale codes | reset per machine; stop after a failure |
| D03-B23 | 0xAC23, 0xBC78 | per-player result codes test the nRet of `setDice` instead of `setDiceResult`; a setDice error answer keeps the request's result count with no results; a missing game-number row leaves nGameNo uninitialised | specific errors never reported; inconsistent answers; results stored under a garbage game number | test the right variable |
| D03-B24 | 0xD403, 0xD40B, 0xD40F | pet number −1 (and no session/DB) only logs, no answer | the zone's pet request never completes | answer with `0x3400` |
| D03-B25 | 0x3453 | a failed `usp_SafeTrade_setAll` does not move the chest/capsule contents back | the buyer owns the contents of a chest the seller keeps | move them back |

## 16. Not reconstructed / uncertain

- Option-type → field names (§1.3) come from the 2017 PDB attribute structs matched by offset; the 2016 offsets are read from the
  load switch, the per-class lists from the save jump table (one asm block per class). Weapon types 503–519 and the exact
  per-element layout of the random-option rows are inferred from the code shape. Classes whose load rows did not resolve
  (CLOSEDCARD/OPENCARD/COSWEAPON/NOEFFECT/PUP) are listed from the save side only.
- `TradeMoveContents` (FUN_00403e90) for classes other than chest/capsule: the decompiler hides the return value; it is taken as
  success (otherwise every non-chest trade would fail).
- Return values of helpers shown as `void` by Ghidra (`ItemBuy_Create`, `ItemGuildTokenBuy_Create`, `CreateItemList`, produce codes)
  were read from the asm where stated; `FUN_0046bd30`'s exact return on attribute failure is inferred from the caller.
- Procedures with no source (D06): `usp_Pet_*` (5), `usp_LinkScroll_SetDestMap`, `p_Item_MiniHouse_Effect_Resource_Del`,
  `p_MiniHouseURL_Get/Set`; meanings of their results are inferred from the codes the handlers map.
- Private-server-marked procedures (`usp_Item_*Enchant*`, author `<KHRISMIZER>`) agree with the binary's codes but their bodies may
  differ from 2016. `p_Item_BuyAll`/`p_Item_BuyLot` were read from w00 (the only version with the binary's parameter count).
  Every dice/gamble/collection procedure exists only in w00 (2017); the binary's tested codes match them.
- `usp_Gamble_addCoin` for 0xBC06: whether the 2016 body accepted a missing item key (D03-B21 depends on it).
- Storage type 6 owned by the user number and type 10 as the chest/capsule content box are inferred from how the handlers list
  and create items (no table definition in the backups).
- Charged list paging (0x3463) beyond one part was not traced with real data.
- `0x3437 MOB_DROP_CMD` computes a lot and does nothing: whether a log send was removed or never existed is unknown.
- Client cross-check: the DB answers go to the zone, not the client; the client-side handling of every code is Z05 §10 (zone
  re-codes most of them). Codes here not listed there were not checked against the client.

## 17. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| Zone handling of every answer (`0x3402` … `0xD410`) | Z05 (ITEMDB), Z06 (trade/booth/gamble/dice), Z07/Z13 (mini-house, pets, cards) | Z05 §1.7 table lists every request/answer pair; this file is the DB side |
| Client texts for the codes | Z05 §10 | the client never sees these packets; the zone re-codes them |
| GameLog packets `0x043F` … `0x07FD`, `0xC80D`/`0xC80E`/`0xC814`/`0xC815` | D05 (GameLog server, `NC_LOG_GAME_*` handlers) | only sent here; their storage is the GameLog server's |
| `SetCharTitles` FUN_0046d3e0 → `p_Char_SetTitle` | D04 (`0x6005 NC_CT_DB_SET_CMD` in its scope table) | shared helper of the character-title handlers |
| Holy-promise reward payout, `tHolyPromiseReward` reads | D04 (`0x941E`… holy-promise handlers) | D03 only writes the 10 % credit |
| `usp_Character_getFriendpoint/setFriendpoint`, `0x541C` at the WM | D04 (friends, `0x5414` …), W04 (friend points at the WM) | 0x34BF only uses them |
| `0x74C0 NC_GUILD_ZONE_USE_GUILD_TOKEN_CMD` balance at the WM | W03 (guild) | sent by the zone after 0x3491 |
| Chat colour and card lists at login | D02 (0x111E, 0x10E3–0x10E8) | read at load; written here |
| Pet data with the pet item | this file §1.3 (`usp_Pet_getInfo` inside `GetItemOptions`) | D02 defers it here |
| Link-scroll destination (`usp_LinkScroll_SetDestMap`) | no reader in the 2016 Character server; zone use: Z04 §12.11 (map-link scroll) | the binary only writes it; whether anything reads it is a D06 question (procedure missing) |
| Procedures without source (pets, link scroll, mini-house URL / effect resource) | D06 (scope: "missing procedures") | listed in §15 as MISSING |
| `0x3489 MINIHOUSE_PORTAL_EFFECT_DEMANDGOOD_REQ` (no handler) | Z05-B12 | nothing to document on the DB side |
| `CSQLPCharacter` wrapper bodies (bind/execute/log) | D02 §1.1 | same pattern for all 310 wrappers, named by D02 |
