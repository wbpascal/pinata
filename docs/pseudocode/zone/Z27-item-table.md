# Zone: item table loader `ItemDataBox::idb_Load` (Z27)

Source: the 2016 `Zone.exe` (`Files/Server/2016/Zone00`). Read the code with the 2016 PDB names
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - 649780`); the class, member and enum names below are
from the NA2016 `Zone.pdb` *(pdb2016)*, which belongs to the same build. Plain statements are read in the code;
*(inferred)* marks deductions. No packet is sent or received here: this is start-up data loading.

What this item adds to the existing docs: Z04 §1.2 uses the index (`g_ItemData` = `itemdatabox`), Z24 §7.3 covers the
constructor and the dead stand-alone reader `ItemDataBox::ReadData`, Z24 §1.3 reads the special IDs, Z20 §2.1 documents
the `bdb_ReadData` template and §5.2 the `BTree` trie. This document is the loader that builds all of it.

## 1. Data structures

### 1.1 `ItemDataBox` (global `itemdatabox` DAT_14d4fb90, size 0x94c)

```pseudo
ItemDataBox                                                  # one global; built by its ctor with path −1 (no read, Z24 §7.3)
    +0x000 ulong          idb_Itemspacies      # number of ItemInfo rows (file order index range)
    +0x004 ulong          idb_maxItemhandle    # max(ItemInfo.ID) + 1 = number of idb_index entries
    +0x008 BTree          idb_btree            # trie ItemInfo.InxName → ID (Z20 §5.2: exact, case-sensitive, last insert wins)
    +0x40c idb_BinData    idb_BinData          # the seven readers that keep the rows in memory (§2)
    +0x8f4 ItemDataBoxIndex* idb_index         # new[idb_maxItemhandle], indexed by item ID (§1.2)
    +0x8f8 SpecialItemIdent idb_specialid      # 41 special item IDs (§4)

idb_BinData (unnamed struct, size 0x4e8; one BinaryDataBox<T> each = BinaryData (CDataReader, 0x40) + default row T)
    +0x000 itminf       BinaryDataBox<ItemInfo>        (default row +0x40, 0x17a bytes)
    +0x1bc itminfsrv    BinaryDataBox<ItemInfoServer>  (0xde)
    +0x2dc itmgrade     BinaryDataBox<GradeItemOption> (0x3e)
    +0x35c itemdroplog  BinaryDataBox<ItemDropLog>     (0x04)
    +0x3a0 itmsort      BinaryDataBox<ItemSort>        (0x20)
    +0x400 iteminvendel BinaryDataBox<ItemInvenDel>    (0x24)
    +0x464 itemmoney    BinaryDataBox<ItemMoney>       (0x42)
```

The rows stay in the readers for the whole process: every pointer in `idb_index` points into them. Each "row i"
access in the code is `i < rowcount ? CDataReader::GetRecord(reader, i) (FUN_0062a0f0) : &reader.bdb_defaultblock`
(the default row is all zero); below it is written `reader[i]`.

```pseudo
idb_BinData::idb_BinData(this)                                               @ FUN_00649280
    for each of the seven readers: BinaryData::BinaryData (FUN_0063cf30), set the BinaryDataBox<T> vftable,
        zero the default row (memset for ItemInfo / ItemInfoServer / GradeItemOption / ItemMoney,
        field by field for ItemDropLog, ItemSort, ItemInvenDel: ItemID = 0, name bytes = 0, DelCondition = DCT_NONE)
idb_BinData::~idb_BinData(this)                                              @ FUN_00649420
    reverse order: reset the vftable, BinaryData::~BinaryData (FUN_0063cf50) frees the file image
ItemDataBox::~ItemDataBox(this)                                              @ FUN_00649700
    if idb_index: operator delete(idb_index)          # scalar delete of a new[] array of PODs (harmless *(inferred)*)
    ~idb_BinData; BTree::~BTree(idb_btree)
    # runs at process exit through _dynamic_atexit_destructor_for_'itemdatabox' FUN_006a00b0 (Z24 §7.3)
```

### 1.2 `ItemDataBox::ItemDataBoxIndex` (one per item ID, size 0x28)

| Off | Member | Type | Initial value (§3.3) | Set from (§3) |
|---|---|---|---|---|
| 0x00 | `data` | `ItemInfo*` | null | ItemInfo row with this ID (§3.4) |
| 0x04 | `dataserv` | `ItemInfoServer*` | null | ItemInfoServer row at the same file position (§3.4) |
| 0x08 | `itemoption` | `GradeItemOption*` | null | GradeItemOption row whose `ItemIndex` names it (§3.6) |
| 0x0c | `MovingShot` | u8 | 0 | WeaponAttrib `IsUsableInMoving` of its `WeaponType` (§3.8) |
| 0x0e | `AttackAngle` | u16 | 0 | WeaponAttrib `UsableDegree` (§3.8) |
| 0x10 | `SetItemIndex` | u16 | 0xFFFF | never written again: no set-item loader exists in 2016 (Z21 §3.2, Z21-B1) |
| 0x12 | `HitTimeArray[3]` | u16×3 | **not initialised** | WeaponAttrib `HitRate[3]` (§3.8) |
| 0x18 | `itemdroplog` | `ItemDropLog*` | null | first ItemDropLog row with its ID (§3.4) |
| 0x1c | `ItemSortOrder` | u8 | 0xFF | position of its `ItemSort_Index` in ItemSort.shn (§3.4) |
| 0x20 | `eDelConditionType` | `DelConditionType` | `DCT_NONE` (0) | ItemInvenDel `DelCondition` (§3.10) |
| 0x24 | `pBuyItemData` | `ItemMoney*` | null | ItemMoney row whose `IM_ItemIDX` names it (§3.11) |

Entries for IDs that no ItemInfo row has keep `data = null`; every accessor treats them as "no such item" (§5).
`DelConditionType`: `DCT_NONE` 0, `DCT_LINKIN_ALL` 1, `MAX_DELCONDITIONTYPE` 2.

### 1.3 `SpecialItemIdent` (`idb_specialid`, size 0x52)

41 `u16` item IDs, one per hard-coded item the server code needs (§4). `sii_recall` is a one-member struct
`{ u16 stage }`. `idb_Load` writes every member; the global is in zero-initialised data, so a member the loader skips
stays 0 (only `sii_JustReviveItem` can be skipped, §3.4).

## 2. Files and readers

All readers are instances of the checked template `BinaryDataBox<T>::bdb_ReadData` (Z20 §2.1:
`CDataReader::Read(this, path, key, rowSize)` FUN_0062a9e0; on failure two log lines, then `ShineExit`). The paths are
fixed (no per-world override).

| File (`../9Data/Shine/`) | Member | Row struct | Reader | key (`DataVersionKey`) | row size |
|---|---|---|---|---|---|
| ItemInfo.shn | `itminf` | `ItemInfo` | `BinaryDataBox<ItemInfo>::bdb_ReadData` FUN_00648a50 | 0x4b67 (19303) | 0x17a |
| ItemInfoServer.shn | `itminfsrv` | `ItemInfoServer` | `BinaryDataBox<ItemInfoServer>::bdb_ReadData` FUN_00648b10 | 0x12a2 (4770) | 0xde |
| GradeItemOption.shn | `itmgrade` | `GradeItemOption` | `BinaryDataBox<GradeItemOption>::bdb_ReadData` FUN_00648bd0 | 0x268 (616) | 0x3e |
| ItemDropLog.shn | `itemdroplog` | `ItemDropLog` | FUN_00641580 (PDB name `BinaryDataBox<ItemDropLog>::bdb_ReadData`; one body also reads MobKillLog.shn, key 0xb / size 4) | 0xb (11) | 0x4 |
| ItemSort.shn | `itmsort` | `ItemSort` | `BinaryDataBox<ItemSort>::bdb_ReadData` FUN_00648ca0 | 0x1 (1) | 0x20 |
| ItemInvenDel.shn | `iteminvendel` | `ItemInvenDel` | FUN_00648d50 (PDB name `BinaryDataBox<CollectCardMobGroup>::bdb_ReadData`: identical-code folding of every key-0x12 / size-0x24 reader, also ActiveSkillGroup, Z20 §2.1) | 0x12 (18) | 0x24 |
| ItemMoney.shn | `itemmoney` | `ItemMoney` | `BinaryDataBox<ItemMoney>::bdb_ReadData` FUN_00648df0 | 0x37 (55) | 0x42 |
| WeaponAttrib.shn | local, freed at the end of §3.8 | `WeaponAttrib` | inlined `BinaryDataBox<WeaponAttrib>::bdb_ReadData` in `idb_Load` (same two log lines and `ShineExit`) | 0x134 (308) | 0xd |

So `idb_Load` reads **eight** files, not seven: the plan's "CollectCardMobGroup" is the folded reader name of
ItemInvenDel.shn (CollectCardMobGroup.shn itself is not read here), and WeaponAttrib.shn is read by an inlined local
reader. The keys and row sizes match `docs/knowledge/S01-shn-structs.tsv` (all "same", columns = members in order).
The column → member maps and the 2016 data invariants of each file are §6 *(part 2 of this item)*.

## 3. `ItemDataBox::idb_Load` (stage home)

Called once, from `ZoneServer::zs_start_home` FUN_005adce0, after `MapDataBox::mdb_Load` and before
`ItemBelongAttribute::iba_Load`, `DropIndexCluster::dic_Load`, `RecallPointTable::rpt_Load` and
`ItemGroupClassifier::igc_Load` (Z24 §7.2), which all look items up in it. Every "fatal" below is
`AssertClass::ac_AssertFail` (log line, FUN_0063c6c0 / FUN_0063c710 / FUN_0063c760) followed by `ShineExit`
(FUN_0063c7c0, ends the process); "log only" is the assert without the exit. `itemdatabox[name]` is
`BTree::operator[](idb_btree, name)` FUN_0063cc30 (0xFFFFFFFF when absent).

The code inlines one helper several times, `idb_MakeSpecialID(name)` (named only by its assert strings):

```pseudo
idb_MakeSpecialID(name) → u16                                                 (inlined in @ FUN_00649780)
    v = idb_btree[name]; id = (v == 0xFFFFFFFF) ? 0xFFFF : (u16)v               # = idb_2itemid, §5
    if id == 0xFFFF: fatal "ItemDataBox::idb_MakeSpecialID : Wrong Item Id", name; ShineExit("ItemDataBox::idb_MakeSpecialID")
    return id
```

### 3.1 Reading the files

```pseudo
ItemDataBox::idb_Load(this)                                                   @ FUN_00649780
    bdb_ReadData(itminf,       "../9Data/Shine/ItemInfo.shn")          # FUN_00648a50
    bdb_ReadData(itminfsrv,    "../9Data/Shine/ItemInfoServer.shn")    # FUN_00648b10
    bdb_ReadData(itmgrade,     "../9Data/Shine/GradeItemOption.shn")   # FUN_00648bd0
    bdb_ReadData(itemdroplog,  "../9Data/Shine/ItemDropLog.shn")       # FUN_00641580
    bdb_ReadData(itmsort,      "../9Data/Shine/ItemSort.shn")          # FUN_00648ca0
    bdb_ReadData(iteminvendel, "../9Data/Shine/ItemInvenDel.shn")      # FUN_00648d50
    bdb_ReadData(itemmoney,    "../9Data/Shine/ItemMoney.shn")         # FUN_00648df0
    # any failure: the reader exits the process (Z20 §2.1)
```

### 3.2 ItemInfo and ItemInfoServer must have the same rows in the same order

```pseudo
    idb_Itemspacies = itminf.rowcount
    if idb_Itemspacies ≠ itminfsrv.rowcount:
        log "ItemDataBox::idb_Load : DataNumber not match"
        for i in 0 .. idb_Itemspacies−1:                         # diagnostic only: find the first differing row
            if (u32)itminf[i].ID ≠ itminfsrv[i].ID:              # u16 vs u32; rows past ItemInfoServer's end are the
                log "Diff : ", itminf[i].ID, itminfsrv[i].ID      #   zero default row (ID 0)
                ShineExit("ItemDataBox::idb_Load")
        ShineExit("ItemDataBox::idb_Load")                       # a count mismatch is always fatal
```

The pairing is by **file position**, not by ID or name: row i of ItemInfo.shn and row i of ItemInfoServer.shn describe
the same item, and §3.4 checks their IDs. The two `InxName` columns are never compared.

### 3.3 Allocating the index

```pseudo
    idb_maxItemhandle = 0
    for i in 0 .. idb_Itemspacies−1: idb_maxItemhandle = max(idb_maxItemhandle, itminf[i].ID)
    idb_maxItemhandle += 1                                       # IDs are u16, so at most 0x10000 entries
    idb_index = operator new[](idb_maxItemhandle × 0x28)         # FUN_00654f0b (64-bit size check: overflow → −1 request)
    if idb_index == null: fatal "ItemDataBox::idb_Load : Memory leak for index in Item", idb_maxItemhandle
    for every entry e:
        e.data = e.dataserv = e.itemoption = null; e.MovingShot = 0; e.AttackAngle = 0; e.SetItemIndex = 0xFFFF
        e.itemdroplog = null; e.ItemSortOrder = 0xFF; e.eDelConditionType = DCT_NONE; e.pBuyItemData = null
        # e.HitTimeArray[0..2] is not written: heap garbage unless §3.8 sets it (original bug) Z27-B1
```

### 3.4 The per-item pass (index, name trie, ItemDropLog, ItemSort)

```pseudo
    dropRows = itemdroplog.rowcount; found = 0
    for i in 0 .. idb_Itemspacies−1:
        id = itminf[i].ID
        if id ≠ itminfsrv[i].ID: fatal "ItemDataBox::idb_Load : iteminfo iteminfoserver Order not match", id
        if idb_index[id].data or idb_index[id].dataserv: fatal "Duplicate Item handle", id      # duplicate ID
        idb_index[id].data     = &itminf[i]
        idb_index[id].dataserv = &itminfsrv[i]
        BTree::bt_Insert(idb_btree, itminf[i].InxName, id)       # FUN_0063cba0; a duplicate InxName silently
                                                                 #   overwrites: the later row's ID wins (Z24 §7.3)
        if itminf[i].ItemFunc == ITEMFUNC_JUSTREVIVAL (3):
            idb_specialid.sii_JustReviveItem = id                # the last such row wins; none → stays 0
        # ItemDropLog: linear search, first match only
        for r in 0 .. dropRows−1:
            if itemdroplog[r].ItemID == id: idb_index[id].itemdroplog = &itemdroplog[r]; found += 1; break
        # ItemSort: the item's ItemInfoServer.ItemSort_Index must be one of the ItemSort rows
        n = (u8) itmsort.rowcount                                # truncated to 8 bits (original bug) Z27-B2
        for k in 0 .. n−1:                                       # k is a u8 too
            if strcmp(itmsort[k].ItemSort_Index, itminfsrv[i].ItemSort_Index) == 0:
                idb_index[id].ItemSortOrder = k; break
        if no row matched (also when n == 0):
            fatal "ItemDataBox::idb_Load : Invalid ItemSort Index", id
```

- `ItemSortOrder` is therefore defined for every item (0 … rows−1); the value 0xFF from §3.3 survives only for IDs
  without an ItemInfo row.
- The ItemSort match uses `itminfsrv[i]` of the same file position, i.e. of the same item (checked above).

### 3.5 ItemDropLog count check

```pseudo
    if found ≠ dropRows: log "ItemDataBox::idb_Load : ItemDropLog - Not found item cnt", found    # log only
```

`found` counts items that got a row, so the check catches ItemDropLog IDs that are not items **and** duplicate
ItemDropLog IDs (the second row of an ID is never matched), but only as a log line: the zone keeps running and those
rows are ignored.

### 3.6 GradeItemOption → `itemoption`

```pseudo
    for g in 0 .. itmgrade.rowcount−1:
        row = itmgrade[g]
        id  = idb_MakeSpecialID(row.ItemIndex)          # inlined: fatal "ItemDataBox::idb_MakeSpecialID : Wrong Item Id",
                                                        #   row.ItemIndex when the name is not an ItemInfo InxName
        if (u32)id == 0xFFFFFFFF:  fatal "ItemDataBox::idb_Load(GradeItemOption) : Invalid Item Index", row.ItemIndex
        if id ≥ idb_maxItemhandle: fatal "ItemDataBox::idb_Load(GradeItemOption) : Invalid Item Index", row.ItemIndex
            # both checks are dead: id is a u16 ≠ 0xFFFF that came from the trie, so always < idb_maxItemhandle;
            # the unknown-name case already exited with the misleading MakeSpecialID text (original bug) Z27-B3
        if idb_index[id].itemoption: fatal "ItemDataBox::idb_Load(GradeItemOption) : Duplicate Item handle", row.ItemIndex
        idb_index[id].itemoption = &row
```

The join is by **InxName** (`GradeItemOption.ItemIndex` = `ItemInfo.InxName`), so with a duplicated InxName the
grade options go to the later item of that name (§3.4 trie rule).

### 3.7 Special IDs, first batch

```pseudo
    sii_cenid = idb_MakeSpecialID("Cen"); sii_silverwing = …("SilverWings"); sii_kqrewardchest = …("PresentBox")
    sii_recall.stage = 0xFFFF                                    # constant, no lookup
    … then, in this order, the names of §4 from "FreeStatusReloadAll" to "RandomOption_Recover"
    # each missing name is fatal (ShineExit "ItemDataBox::idb_MakeSpecialID")
```

### 3.8 WeaponAttrib.shn → `MovingShot`, `AttackAngle`, `HitTimeArray`

```pseudo
    wa = local BinaryDataBox<WeaponAttrib> (BinaryData ctor FUN_0063cf30, zero default row)
    if !CDataReader::Read(wa, "../9Data/Shine/WeaponAttrib.shn", 0x134, 0xd):
        log "BinaryDataBox<T>::bdb_ReadData : readfail", path; log "Code:%X:%d\tSHN:%X:%d"; ShineExit("BinaryDataBox<T>::bdb_ReadData")
    for r in 0 .. wa.rowcount−1:
        for id in 0 .. idb_maxItemhandle−1:                     # every index entry, rows × IDs comparisons
            e = idb_index[id]
            if e.data and e.data.WeaponType (ItemInfo +0xe8) == wa[r].WeaponType:
                e.MovingShot     = wa[r].IsUsableInMoving       # u8
                e.AttackAngle    = wa[r].UsableDegree           # u16
                e.HitTimeArray[j] = wa[r].HitRate[j], j = 0..2  # u16, read unaligned at row +7
    ~BinaryData(wa)                                              # FUN_0063cf50: WeaponAttrib rows are not kept
```

- The join is by **weapon type** (`WeaponTypeEnum`), not by item: every item whose `ItemInfo.WeaponType` equals a row's
  `WeaponType` gets that row's values, armour and non-equipment included if a row has their (usually 0) weapon type
  (2016 rows: §6 *(part 2)*). Two rows with the same `WeaponType`: the later row wins, unnoticed.
- A row whose `WeaponType` matches no item changes nothing and is not reported.

### 3.9 Special IDs, second batch

```pseudo
    sii_ProposeRing = idb_MakeSpecialID("ProposeRing"); sii_InvitationCard = …("InvitationCard")
    sii_WeddingCoupon = …("WeddingCoupon"); sii_WeddingPresent = …("MiniWedding01_1"); sii_ImmediateDivorce = …("InstantDivorce")
```

### 3.10 ItemInvenDel → `eDelConditionType`

```pseudo
    for r in 0 .. iteminvendel.rowcount−1:
        v = idb_btree[iteminvendel[r].InxName]
        if v == 0xFFFFFFFF or (u16)v == 0xFFFF:
            fatal "ItemDataBox::idb_Load : Invalid ItemInvenDel Index", InxName; ShineExit(same text)
        if (u16)v ≥ idb_maxItemhandle:                            # dead (trie values are valid IDs) (original bug) Z27-B4
            fatal "ItemDataBox::idb_Load : Invalid ItemInvenDel ID", (u16)v; ShineExit(same text)
        idb_index[(u16)v].eDelConditionType = iteminvendel[r].DelCondition
        # no duplicate check: a second row for the same item overwrites; DelCondition is not range-checked
```

### 3.11 ItemMoney → `pBuyItemData`

```pseudo
    for r in 0 .. itemmoney.rowcount−1:
        row = itemmoney[r]
        item = idb_btree[row.IM_ItemIDX]
        if item == 0xFFFFFFFF or (u16)item == 0xFFFF: fatal "ItemDataBox::idb_Load : Invalid ItemMoney IM_ItemIDX", row.IM_ItemIDX
        money = idb_btree[row.IM_MoneyIDX]
        if money == 0xFFFFFFFF or (u16)money == 0xFFFF: fatal "ItemDataBox::idb_Load : Invalid ItemMoney IM_MoneyIDX", row.IM_MoneyIDX
        if (u16)item == (u16)money: fatal "ItemDataBox::idb_Load : Same ItemIndex, MoneyIndex", row.IM_ItemIDX
        if idb_index[item].pBuyItemData:
            fatal "ItemDataBox::idb_Load : Duplicate ItemMoney IM_ItemIDX", row.IM_MoneyIDX
            # logs the money name, not the duplicated IM_ItemIDX (original bug) Z27-B5
        cls = ItemAttributeClassContainer::operator[](itmattcontainer, money).vt[0x28/4]()   # FUN_0063e2a0, ItemClassEnum
        if cls == ITEMCLASS_CAPSULE (29) or cls == ITEMCLASS_ITEMCHEST (15):
            fatal "ItemDataBox::idb_Load : ItemMoney Invalid Item Class", row.IM_MoneyIDX
        idb_index[item].pBuyItemData = &row
    return
```

- The join is by **InxName** on both sides. Every message here ends in `ShineExit(<the same text>)`.
- `ItemAttributeClassContainer::operator[]` (§5) reads `idb_index` that this function has just filled, so it works
  at this point; the class objects are members of the global container and `iacc_Array` is filled by its constructor
  `ItemAttributeClassContainer::ItemAttributeClassContainer` FUN_00640170 (static init), so nothing needs loading. In effect the test is `ItemInfo[money].Class ∉ {15, 29}` (a class > 0x26 would yield the default
  class object instead, with a log line).
- `IM_MoneyLot` (the price in money items) is not checked (0 or any value passes); Z04 §2.2 uses it when buying.

## 4. Special item IDs (`idb_specialid`)

All but two come from `idb_MakeSpecialID(<InxName>)` (fatal when the name is missing). Order = order in `idb_Load`.

| Off | Member | Source | § |
|---|---|---|---|
| 0x40 | `sii_JustReviveItem` | last ItemInfo row with `ItemFunc == ITEMFUNC_JUSTREVIVAL` (3); 0 if none (no check) | 3.4 |
| 0x00 | `sii_cenid` | `"Cen"` | 3.7 |
| 0x04 | `sii_silverwing` | `"SilverWings"` | 3.7 |
| 0x06 | `sii_kqrewardchest` | `"PresentBox"` | 3.7 |
| 0x02 | `sii_recall.stage` | constant 0xFFFF | 3.7 |
| 0x08 | `sii_FreeStatRedistAll` | `"FreeStatusReloadAll"` | 3.7 |
| 0x0a | `sii_SkillEmpowRedistAll` | `"SkillReloadbundleAll"` | 3.7 |
| 0x0c | `sii_FreeStatRedistPoint` | `"FreeStatusReloadOne"` | 3.7 |
| 0x0e | `sii_SkillEmpowRedistPoint` | `"SkillReloadbundleOne"` | 3.7 |
| 0x10 | `sii_WeaponLicenseClear` | `"LicenseClear"` | 3.7 |
| 0x12 | `sii_MiniHouse_MushRoom` | `"House_MushRoom"` | 3.7 |
| 0x14 | `sii_MagicPortionHP0` | `"HPMPotion1"` | 3.7 |
| 0x16 | `sii_MagicPortionHP1` | `"HPMPotion2"` | 3.7 |
| 0x18 | `sii_MagicPortionHP2` | `"HPMPotion0"` | 3.7 |
| 0x1a | `sii_MagicPortionHP3` | `"HPMPotion3"` | 3.7 |
| 0x1c | `sii_MagicPortionSP0` | `"SPMPotion1"` | 3.7 |
| 0x1e | `sii_MagicPortionSP1` | `"SPMPotion2"` | 3.7 |
| 0x20 | `sii_MagicPortionSP2` | `"SPMPotion0"` | 3.7 |
| 0x22 | `sii_MagicPortionSP3` | `"SPMPotion3"` | 3.7 |
| 0x24 | `sii_Roar` | `"Roar"` | 3.7 |
| 0x26 | `sii_SkillErase` | `"ProdReload01"` | 3.7 |
| 0x28 | `sii_SparrowWing` | `"GoddessWing"` | 3.7 |
| 0x2a | `sii_SparrowFeather` | `"MemoryFeather"` | 3.7 |
| 0x2c | `sii_WingStone` | `"WingStone01_1"` | 3.7 |
| 0x2e | `sii_BossMobDetector` | `"KQ_SoulCrystal"` | 3.7 |
| 0x3a | `sii_Karis` | `"Karis"` | 3.7 |
| 0x3c | `sii_GuildReName` | `"GuildName"` | 3.7 |
| 0x3e | `sii_GuildReType` | `"GuildTendency"` | 3.7 |
| 0x42 | `sii_DiceTaiSaiMoneyCard` | `"IN_MoneyCard00"` | 3.7 |
| 0x44 | `sii_EnchantSocketRemover` | `"EnchantSocketReload"` | 3.7 |
| 0x46 | `sii_EnchantSocketDrill` | `"EnchantSocketAdd"` | 3.7 |
| 0x48 | `sii_UpgradeMoverFeedType` | `"LifeDust"` | 3.7 |
| 0x4a | `sii_RandomOptionChange` | `"RandomOption"` | 3.7 |
| 0x4c | `sii_ClassChange` | `"ClassChange"` | 3.7 |
| 0x4e | `sii_MapLink` | `"WorldLink"` | 3.7 |
| 0x50 | `sii_RandomOptionRecoverCountLimit` | `"RandomOption_Recover"` | 3.7 |
| 0x30 | `sii_ProposeRing` | `"ProposeRing"` | 3.9 |
| 0x32 | `sii_InvitationCard` | `"InvitationCard"` | 3.9 |
| 0x34 | `sii_WeddingCoupon` | `"WeddingCoupon"` | 3.9 |
| 0x36 | `sii_WeddingPresent` | `"MiniWedding01_1"` | 3.9 |
| 0x38 | `sii_ImmediateDivorce` | `"InstantDivorce"` | 3.9 |

- The HP / SP potion slots are rotated against the names: slot 0 = `…Potion1`, 1 = `…Potion2`, 2 = `…Potion0`,
  3 = `…Potion3` (deliberate or not, a rebuild must keep the mapping) *(inferred: the slot numbers do not follow the
  names; which slot means which potion is for the consumers, §7 part 2)*.
- Every lookup is by **InxName**: renaming one of these items in ItemInfo.shn stops the zone at start-up.
- The 2016 IDs of these names and the consumers of each member: §7 *(part 2)*.

## 5. Accessors over the index

```pseudo
ItemDataBox::operator[](db, id) → ItemDataBoxIndex*                          @ FUN_00419020
    if id < idb_maxItemhandle and idb_index[id].data:
        if idb_index[id].data.ID == id: return &idb_index[id]
        log "ItemDataBox::operator [] :Invalid Item index", id × 10000 + data.ID      # unreachable: §3.4 stores row ID at its ID
    return null
ItemDataBox::idb_2itemid(db, name) → u16 = idb_btree[name] (0xFFFFFFFF → 0xFFFF)       @ FUN_00418ff0
ItemDataBox::idb_SpecialItems(db) → &db.idb_specialid                                   @ FUN_00418fe0
ItemAttributeClassContainer::operator[](c, id) → ItemAttributeClass*                    @ FUN_0063e2a0
    same id / data / ID test on itemdatabox (same log text, then) → c.iacc_default
    cls = data.Class; cls > 0x26 → log "ItemAttributeClassContainer::operator [] : Invalid item class", cls; → iacc_default
    return c.iacc_Array[cls]
```

`idb_GetItemInxName` FUN_006487d0 and `idb_iter_next` / `idb_iter_Get` (file-order walk over `idb_Itemspacies`) are
Z24 §7.3.
