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
| 0x12 | `HitTimeArray[3]` | u16×3 | **not initialised** | WeaponAttrib `HitRate[3]` (§3.8; effect §7.3) |
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
The column → member maps and the 2016 data invariants of each file are §6.

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
  (2016: the WT_NONE row gives 11 799 non-weapons values, §6.8). Two rows with the same `WeaponType`: the later row
  wins, unnoticed.
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
  names; no consumer reads any of the eight slots in 2016, §7.1)*.
- Every lookup is by **InxName**: renaming one of these items in ItemInfo.shn stops the zone at start-up.
- The 2016 IDs of these names and the consumers of each member: §7.1.

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

## 6. The files: column → member maps and 2016 data invariants

Every file's columns are its row struct's members in order, same SHN key and row size (`docs/knowledge/S01-shn-structs.tsv`:
"same"); `CDataReader` copies each row 1:1, so the member offsets below are the column positions in the row. Format:
`` `Column` +offset type (SHN type:size) ``. Counts are from `Files/Server/2016/9Data/Shine` (checked with `shn.py`); the
NA2016 set (`Files/Server/NA2016/9Data/Shine`) has 10 more ItemInfo / ItemInfoServer rows and passes the same checks.
**Read by `idb_Load`** lists what the loader itself uses; the other columns are read by the consumers through
`idb_index[id].data` / `.dataserv` (Z04, Z05, Z09, Z12 …).

### 6.1 ItemInfo.shn → `ItemInfo` (0x17a, 57 columns, 14 989 rows)

`ID` +0x0 u16 (2:2) · `InxName` +0x2 char[32] (9:32) · `Name` +0x22 char[64] · `Type` +0x62 ItemTypeEnum (11:4) ·
`Class` +0x66 ItemClassEnum (11:4) · `MaxLot` +0x6a u32 · `Equip` +0x6e ItemEquipEnum · `ItemAuctionGroup` +0x72 AuctionGroup ·
`ItemGradeType` +0x76 GradeType · `TwoHand` +0x7a u8 · `AtkSpeed` +0x7b · `DemandLv` +0x7f · `Grade` +0x83 · `MinWC` +0x87 ·
`MaxWC` +0x8b · `AC` +0x8f · `MinMA` +0x93 · `MaxMA` +0x97 · `MR` +0x9b · `TH` +0x9f · `TB` +0xa3 · `WCRate` +0xa7 · `MARate` +0xab ·
`ACRate` +0xaf · `MRRate` +0xb3 · `CriRate` +0xb7 · `CriMinWc` +0xbb · `CriMaxWc` +0xbf · `CriMinMa` +0xc3 · `CriMaxMa` +0xc7 ·
`CrlTB` +0xcb (all u32, 3:4) · `UseClass` +0xcf UseClassType · `BuyPrice` +0xd3 u32 · `SellPrice` +0xd7 u32 · `BuyDemandLv` +0xdb u8 ·
`BuyFame` +0xdc · `BuyGToken` +0xe0 · `BuyGBCoin` +0xe4 (u32) · `WeaponType` +0xe8 WeaponTypeEnum · `ArmorType` +0xec ArmorTypeEnum ·
`UpLimit` +0xf0 u8 · `BasicUpInx` +0xf1 u16 · `UpSucRatio` +0xf3 u16 · `UpLuckRatio` +0xf5 u16 · `UpResource` +0xf7 u8 ·
`AddUpInx` +0xf8 u16 · `ShieldAC` +0xfa · `HitRatePlus` +0xfe · `EvaRatePlus` +0x102 · `MACriPlus` +0x106 · `CriDamPlus` +0x10a ·
`MagCriDamPlus` +0x10e (u32) · `BT_Inx` +0x112 E_BelongType · `TitleName` +0x116 char[32] · `ItemUseSkill` +0x136 char[32] ·
`SetItemIndex` +0x156 char[32] · `ItemFunc` +0x176 ItemFuncEnum. (Enums are u32, SHN type 11.)

Read by `idb_Load`: `ID` (index slot, §3.3/§3.4), `InxName` (trie), `ItemFunc` (§3.4), `WeaponType` (§3.8), `Class` (through
`ItemAttributeClassContainer`, §3.11).

2016 invariants:
- IDs 0 … 65 504, all distinct (ID 0 is a real item, `LeatherBoots`), **not sorted** (52 descents in file order); so
  `idb_maxItemhandle` = 65 505 and 50 516 index entries stay empty (`data = null`); the index is 65 505 × 0x28 =
  2 620 200 bytes.
- `InxName`: never empty, at most 31 characters (always NUL-terminated inside char[32]). **17 names occur twice**, all
  quest items `Q_…` (Q_Pickaxe 3178/3228, Q_Mud 3182/3394, Q_ShylphFeather 3451/9320, Q_PergyHorn 4612/9026,
  Q_BattleBeakBill 4614/9416, Q_ApeLeather 9025/9417, Q_GtRedCondorBlood 9028/9418, Q_RugaBlood 9029/9419,
  Q_GoodsUrg 9032/9420, Q_ElementalWater 9034/9422, Q_BloodShadow 9036/9423, Q_DarkShadow 9037/9426,
  Q_SpiritBottle 9039/9424, Q_FogNepilim 9041/9425, Q_FogLence 9042/9427, Q_SilberkTooth 9044/9429,
  Q_HeartBlack 9151/9421): the trie maps each to the **second** ID (§3.4); none of them is a special ID, a
  GradeItemOption, ItemInvenDel or ItemMoney name, so this loader is not affected (name lookups elsewhere are, Z24 §7.3).
- `ItemFunc`: 14 964 × 0, and exactly one row with `ITEMFUNC_JUSTREVIVAL` (3): ID 30168 `JustRevival` → `sii_JustReviveItem`.
- `Class` ≤ 38 and `WeaponType` ≤ 21 for every row (no "Invalid item class" log at §3.11).
- One row's `InxName` differs from its ItemInfoServer row (§6.2): ID 9157 is `A piece of Mimic's box` in ItemInfo
  (also in the client's ItemInfo.shn) and `Q_JokerCard01` in ItemInfoServer. The loader never compares them; only the
  ItemInfo name is in the trie, so `Q_JokerCard01` is not a known name on the zone.

### 6.2 ItemInfoServer.shn → `ItemInfoServer` (0xde, 17 columns, 14 989 rows)

`ID` +0x0 u32 (3:4) · `InxName` +0x4 char[32] · `MarketIndex` +0x24 char[20] · `City` +0x38 u8[1] (20:1) ·
`DropGroupA` +0x39 char[40] · `DropGroupB` +0x61 char[40] · `RandomOptionDropGroup` +0x89 char[33] · `Vanish` +0xaa u32 ·
`looting` +0xae u32 · `DropRateKilledByMob` +0xb2 u16 · `DropRateKilledByPlayer` +0xb4 u16 · `ISET_Index` +0xb6 ISEType (11:4) ·
`ItemSort_Index` +0xba char[32] · `KQItem` +0xda u8 · `PK_KQ_USE` +0xdb u8 · `KQ_Item_Drop` +0xdc u8 · `PreventAttack` +0xdd u8.

Read by `idb_Load`: `ID` (§3.2 / §3.4 order check), `ItemSort_Index` (§3.4).

2016 invariants: same row count as ItemInfo and row i has the same ID as ItemInfo row i for every i (both fatal checks
pass); `InxName` equal to ItemInfo's except ID 9157 (§6.1); every `ItemSort_Index` (≤ 15 characters) is an ItemSort row.

### 6.3 GradeItemOption.shn → `GradeItemOption` (0x3e, 16 columns, 3 857 rows)

`ItemIndex` +0x0 char[32] (9:32) · `STR` +0x20 · `CON` +0x22 · `DEX` +0x24 · `INT` +0x26 · `MEN` +0x28 · `ResistPoison` +0x2a ·
`ResistDeaseas` +0x2c · `ResistCurse` +0x2e · `ResistMoveSpdDown` +0x30 · `ToHitRate` +0x32 · `ToBlockRate` +0x34 · `MaxHP` +0x36 ·
`MaxSP` +0x38 · `WCPlus` +0x3a · `MAPlus` +0x3c (all u16, 2:2).

Read by `idb_Load`: `ItemIndex` (= an ItemInfo `InxName`, §3.6). 2016 invariants: every `ItemIndex` is a known name,
no name twice, none of them a duplicated InxName, so every row lands on its own item and none is fatal. The rows cover
weapons (665), armour (831), shields (50), boots (326), amulets (433), decorations (946), costume weapons (504), mounts
(67), house skins (29) and 6 class-0 items. `ToHitRate` / `ToBlockRate` are non-zero in every row (base 1000, up to
1100 / 1090: Z12 §2.2 adds `value − 1000`); the stats are sparse (STR 1 041 rows … WCPlus / MAPlus 7 rows).

### 6.4 ItemDropLog.shn → `ItemDropLog` (0x4, 1 column, 57 rows)

`ItemID` +0x0 u32 (3:4). Read by `idb_Load`: `ItemID` (linear match by ID, §3.4). 2016 invariants: 57 distinct IDs
57140 … 58271 (52 weapons, 5 shields: the `Karen…` set and similar), all existing items, so `found` = 57 and the
§3.5 log line does not appear.

### 6.5 ItemSort.shn → `ItemSort` (0x20, 1 column, 59 rows)

`ItemSort_Index` +0x0 char[32] (9:32). Read by `idb_Load`: the row position is `ItemSortOrder` (§3.4). 59 rows (< 256,
so Z27-B2 does not trigger), no duplicates. Order (= the `ItemSortOrder` value): 0 IS_MYSTERYVAULT, 1 IS_EVENT, 2 IS_KQ,
3 IS_POTION01, 4 IS_POTION02, 5 IS_BUFF, 6 IS_UTIL, 7 IS_RECALLSCROLL, 8 IS_MOVER, 9 IS_FEED, 10 IS_PUP,
11 IS_COLECTCARD, 12 IS_SKILLSCROLL, 13 IS_CAPSULE, 14 IS_MHOUSE, 15 IS_ACTIONITEM, 16 IS_ITEMCHEST, 17 IS_USE,
18 IS_COSWEAPON, 19 IS_BODYACC, 20 IS_LEGACC, 21 IS_SHOESACC, 22 IS_HATACC, 23 IS_BACK, 24 IS_TAIL, 25 IS_MOUTH, 26 IS_EYE,
27 IS_MINIMON, 28 IS_ONEHANDSWORD, 29 IS_TWOHANDSWORD, 30 IS_AXE, 31 IS_MACE, 32 IS_HAMMER, 33 IS_BOW, 34 IS_CBOW,
35 IS_STAFF, 36 IS_WAND, 37 IS_CLAW, 38 IS_DSWORD, 39 IS_BLADE, 40 IS_SHIELD, 41 IS_HAT, 42 IS_BODY, 43 IS_LEG, 44 IS_SHOES,
45 IS_EARRING, 46 IS_NECK, 47 IS_RING, 48 IS_BRACELET, 49 IS_UPSOURCE01, 50 IS_UPSOURCE02, 51 IS_ENCHANT, 52 IS_WTLICENCE,
53 IS_STARTQUEST, 54 IS_QUEST, 55 IS_TOOL, 56 IS_PRODRAW, 57 IS_FURNITURE, 58 IS_ETC. Three rows are used by no item
(IS_ITEMCHEST, IS_USE, IS_STARTQUEST); the largest groups are IS_SKILLSCROLL (2 264 items), IS_QUEST (1 184), IS_BODYACC (870).

### 6.6 ItemInvenDel.shn → `ItemInvenDel` (0x24, 2 columns, 19 rows)

`InxName` +0x0 char[32] (9:32) · `DelCondition` +0x20 DelConditionType (11:4). Read by `idb_Load`: both (§3.10).
2016 rows, all `DCT_LINKIN_ALL` (1), all known names, no duplicates: BallSnow01 4695, BallCrush01 4696, E_BallHive02 62566,
BallEgg01 62567, Egg_Melee 62569, Egg_Range 62570, Egg_Ice 62571, Egg_Stun 62572, E_BallSnow02 48806, E_BallCrush02 48807,
E_M_RentaBoard01–05 48859–48863, BallWater 65061, BallCannon 65062, BallCake01 1480, BallCannon01 1481 (event throwing
balls / eggs and rental boards: removed from the inventory at every map login, §7.2).

### 6.7 ItemMoney.shn → `ItemMoney` (0x42, 3 columns, 540 rows)

`IM_ItemIDX` +0x0 char[32] (9:32) · `IM_MoneyIDX` +0x20 char[32] (9:32) · `IM_MoneyLot` +0x40 u16 (2:2). Read by
`idb_Load`: both names (§3.11). 2016 invariants: every name known, item ≠ money in every row, no `IM_ItemIDX` twice (so
no Z27-B5 log), no duplicated InxName involved. The 540 buyable items (armour 151, boots 146, weapons 72, costume weapons
60, decorations 51, amulets 28, shields 12, house skins 10, class 0: 6, mounts 2, costume shields 2) are paid with 11
money items, all `ITEMCLASS_BYTELOT` (0), so the class test passes: IM_Arena01 (318 rows), IM_SirenCrystal 48,
IM_SD_Vale01 44, IM_Xmas01 41, IM_Cake01 22, IM_Haloween01 18, IM_Soccer 18, IM_Water 9, IM_WSoccer01 9, IM_Egg2014 7,
IM_Olympic01 6. `IM_MoneyLot` 5 … 300 (never 0).

### 6.8 WeaponAttrib.shn → `WeaponAttrib` (0xd, 4 members / 6 SHN columns, 14 rows)

`WeaponType` +0x0 WeaponTypeEnum (11:4) · `UsableDegree` +0x4 u16 (2:2) · `IsUsableInMoving` +0x6 u8 (1:1) ·
`HitRate[3]` +0x7 u16×3 (three SHN columns of type 21, size 2: only the first carries the name `HitRate`, the other two
have empty names). Read by `idb_Load`: all (§3.8).

| WeaponType | UsableDegree | IsUsableInMoving | HitRate |
|---|---|---|---|
| 0 WT_NONE, 1 SWORD, 2 BOW, 3 STAFF, 4 AXE, 5 MACE, 10 CROSSBOW, 11 WAND, 13 HAMMER, 16 INVINCIBLEHAMMER, 19 BLADE, 21 TSWORD | 90 | 0 | 500, 0, 0 |
| 17 WT_DSWORD | 90 | 0 | 1, 360, 833 |
| 18 WT_CLAW | 90 | 0 | 1, 100, 633 |

2016 consequences (§3.8 join by weapon type):
- One row per type, no duplicates. **The WT_NONE row matches 11 799 items** (all armour, accessories, consumables …):
  they all get `AttackAngle` 90 and `HitTimeArray` {500, 0, 0}, harmlessly, since only the weapon in the weapon cell is
  read (§7.3).
- Weapon types used by items but without a row: only 15 `WT_PRODUCTIONTOOL` (4 class-5 weapons: 4500 Pickaxe, 4503 Hoe,
  4506 Axe, 35252 Kebypick). Their `MovingShot` / `AttackAngle` stay 0 and `HitTimeArray` stays uninitialised (Z27-B1,
  effect §7.3). Types 6–9, 12, 14, 20 are used by no item and have no row.
- `IsUsableInMoving` is 0 in every row, so `MovingShot` is 0 for every item in 2016.

## 7. What the loaded data is used for

### 7.1 Special item IDs: 2016 values and consumers

The 2016 ID of each name (ItemInfo.shn; every name exists once, so the loader passes). "Readers" are all places that
read the member in the zone (`rg 'sii_<name>'` over the PDB-named export, plus the six `idb_SpecialItems` callers, which
read `sii_JustReviveItem`, `sii_GuildReName`, `sii_GuildReType`).

| Member | Name → 2016 ID (item name, class) | Readers (owning item) |
|---|---|---|
| `sii_cenid` | Cen → 2502 (Sen, DWRDLOT) | `sp_partyitemdistribute` FUN_0052f630, `sp_RaidItemsidtribute` FUN_0052f8a0 (Z09), `so_ply_PickupItem` FUN_0052faf0, `sp_NC_ITEM_PICK_REQ` FUN_00530a50 (Z04): the money drop item |
| `sii_silverwing` | SilverWings → 2504 (Silver Wing, BINDITEM) | `ShineMobileObject::so_Routine` FUN_0056a080 (Z09), `sp_SilverWing_PortalBlast` FUN_00597cf0 (Z23), `sp_silverwing_Setloc` FUN_0059bc80 (cell's item must be this ID) |
| `sii_kqrewardchest` | PresentBox → 2507 (Present Box, ITEMCHEST) | `sp_KQReward` FUN_0052da70 (Z09, Z16) |
| `sii_recall.stage` | constant 0xFFFF | **never read** |
| `sii_FreeStatRedistAll` | FreeStatusReloadAll → 30023 | **never read** |
| `sii_SkillEmpowRedistAll` | SkillReloadbundleAll → 30017 | **never read** |
| `sii_FreeStatRedistPoint` | FreeStatusReloadOne → 30022 | `sp_NC_CHAR_STAT_DECPOINT_REQ` FUN_0058b3f0 (Z07) |
| `sii_SkillEmpowRedistPoint` | SkillReloadbundleOne → 30016 | `sp_NC_SKILL_EMPOWALLOC_REQ` FUN_0044f150 (Z23) |
| `sii_WeaponLicenseClear` | LicenseClear → 30036 | `sp_NC_WT_LICENSE_REQ` FUN_0059e410 (Z08) |
| `sii_MiniHouse_MushRoom` | House_MushRoom → 31000 (HOUSESKIN) | `sp_MakeMiniHouse` FUN_0043eab0 (Z13) |
| `sii_MagicPortionHP0` … `HP3` | HPMPotion1 30041, HPMPotion2 30042, HPMPotion0 30084, HPMPotion3 30086 (AMOUNT) | **never read** |
| `sii_MagicPortionSP0` … `SP3` | SPMPotion1 30043, SPMPotion2 30044, SPMPotion0 30085, SPMPotion3 30087 (AMOUNT) | **never read** |
| `sii_Roar` | Roar → 30069 | `sp_NC_ACT_ROAR_REQ` FUN_005404d0 (Z02) |
| `sii_SkillErase` | ProdReload01 → 30104 | `sp_NC_SKILL_UNLEARN_REQ` FUN_0057ad80 (Z23) |
| `sii_SparrowWing` | GoddessWing → 30071 (BINDITEM) | `so_ply_SparrowWingExpand` FUN_00589b10, `sp_NC_MAP_WING_SAVE_REQ` FUN_00589c80, `sp_NC_MAP_WING_FLY_REQ` FUN_00589f00 (Z01), `UseItemMemoryFeather::uib_CanUseItem` FUN_00598ab0 |
| `sii_SparrowFeather` | MemoryFeather → 30072 | **never read** (the feather's use check looks for the wing, above) |
| `sii_WingStone` | WingStone01_1 → 30068 | `sp_NC_MAP_WING_FLY_REQ` FUN_00589f00 (Z01) |
| `sii_BossMobDetector` | KQ_SoulCrystal → 3247 (KQ) | **never read** |
| `sii_ProposeRing` | ProposeRing → 4300 | `uie_Load` FUN_0059cc30 (Z24 §1.3), `sp_NC_ACT_WEDDING_PROPOSEACK_ACK` FUN_0059f900 (Z02) |
| `sii_InvitationCard` | InvitationCard → 4301 | `ac_WeddingGuestEnter` FUN_0041ef10 (Z11), `sp_NC_ACT_WEDDING_HALL_GUEST_ENTER_REQ` FUN_0059fcb0, `…_HALL_RESERV_REQ` FUN_005a2330 (Z02) |
| `sii_WeddingCoupon` | WeddingCoupon → 4302 | `so_ply_WeddingPrepareItem` FUN_0059f490, `WeddingHall::wh_RecallCouple` FUN_005a27f0 (Z13) |
| `sii_WeddingPresent` | MiniWedding01_1 → 38115 (Wedding [Mini couple Lulu], ARMOR) | `so_ply_DivorceProcess` FUN_0059f550 (Z13), `gds_NC_CHAR_WEDDING_DO_ACK` FUN_005a1830 (Z07) |
| `sii_ImmediateDivorce` | InstantDivorce → 4309 | `uie_Load` FUN_0059cc30 only (Z24 §1.3) |
| `sii_Karis` | Karis → 8046 (UPSOURCE) | `sp_NC_ITEM_DISMANTLE_REQ` FUN_005293c0 (Z04) |
| `sii_GuildReName` | GuildName → 30118 | `sp_NC_GUILD_RENAME_REQ` FUN_00473550, `so_ply_GuildReName` FUN_00474650 (Z08) |
| `sii_GuildReType` | GuildTendency → 30119 | `sp_NC_GUILD_RETYPE_REQ` FUN_00473860, `so_ply_GuildReType` FUN_00473c00 (Z08) |
| `sii_JustReviveItem` | ItemFunc 3 → 30168 (JustRevival) | `sp_NC_ITEM_REVIVEITEMUSE_CMD` FUN_00417580 (Z04), `so_KilledBy` FUN_00433be0 (Z03), `uie_Load` (Z24 §1.3) |
| `sii_DiceTaiSaiMoneyCard` | IN_MoneyCard00 → 51001 (FURNITURE) | `sp_DiceTaiSaiItemIDChange` FUN_00514b40, `so_mh_DiceTaiSai_GetReceiptIncomeMoney` FUN_00516c40 (Z06) |
| `sii_EnchantSocketRemover` | EnchantSocketReload → 30240 | `sp_NC_ITEM_ENCHANT_REMOVE_GEM_REQ` FUN_00522990 (Z04) |
| `sii_EnchantSocketDrill` | EnchantSocketAdd → 30239 | `sp_NC_ITEM_ENCHANT_ADD_NEW_SOCKET_REQ` FUN_00522cc0 (Z04) |
| `sii_UpgradeMoverFeedType` | LifeDust → 2529 (Ration, FEED) | `sp_NC_ITEM_MOVER_UPGRADE_REQ` FUN_0051c850 (Z04) |
| `sii_RandomOptionChange` | RandomOption → 62965 | `sp_NC_ITEM_RANDOMOPTION_CHANGE_REQ` FUN_00520e40 (Z04) |
| `sii_ClassChange` | ClassChange → 64859 | `sp_NC_ITEM_CLASS_CHANGE_REQ` FUN_0051f5c0 (Z04) |
| `sii_MapLink` | WorldLink → 814 | `sp_NC_ITEM_MAPLINK_SCROLL_REQ` FUN_00520130 (Z04) |
| `sii_RandomOptionRecoverCountLimit` | RandomOption_Recover → 1797 | `sp_NC_ITEM_RANDOMOPTION_RECOVER_COUNT_LIMIT_REQ` FUN_0051dd40 (Z04) |

- **13 of the 41 members are written and never read**: `sii_recall`, `sii_FreeStatRedistAll`,
  `sii_SkillEmpowRedistAll`, the eight magic-potion slots, `sii_SparrowFeather`, `sii_BossMobDetector`. The twelve
  of them that are looked up by name must still exist in ItemInfo.shn, because a missing one stops the zone (§3.7).
  So the HP/SP potion slot rotation of §4 has no effect in 2016.
- The three small readers no other doc cites, in one line each: `so_ply_SparrowWingExpand(p, n)` FUN_00589b10
  (n capped at 10) finds the first GoddessWing in the inventory, and if its class is `ITEMCLASS_BINDITEM` (13) and it has
  fewer than n saved locations, appends one location {map 0xFFFF, x 10000, y 10000}, writes the item to the DB
  (`sp_AttrChange2DB`) and sends code 0x700 through vt 0x91c; `UseItemMemoryFeather::uib_CanUseItem` FUN_00598ab0 returns
  0x701 when vt 0x47c fails, else looks for a GoddessWing (class 13) in the unlocked inventory: none → 0x718, more than
  4 saved locations → 0x719, else 0x700 (OK); `sp_silverwing_Setloc` FUN_0059bc80 acts only when the given inventory
  cell holds item `sii_silverwing` (location-save logic belongs to the silver-wing feature, §10).

### 7.2 Index members: consumers

| Member | Readers | Use |
|---|---|---|
| `data`, `dataserv` | everywhere through `ItemDataBox::operator[]` FUN_00419020 (Z04 §1.2) | the item's two rows |
| `itemoption` | `so_RecalcEquipParam` FUN_004cab70 (Z12 §2.2): resistances, `ToHitRate − 1000`, `ToBlockRate − 1000`, MaxHP, MaxSP; `FillRandomOption` FUN_004ca9e0 (Z12 §2.2): STR, CON, DEX, INT, MEN, WCPlus, MAPlus | per-item fixed bonus of an equipped item |
| `MovingShot` | `so_RecalcEquipParam` FUN_004cab70 (Z12 §2.2): `sp_MovingShot \|= MovingShot` per equipped item | always 0 in 2016 (§6.8) |
| `AttackAngle` | none (no read of the member in the PDB-named export) *(inferred: an offset-only read would not show the name)* | dead data |
| `HitTimeArray` | `sp_Schedule_SwingStart` FUN_00430bc0, `sp_Schedule_SwingDamage` FUN_0042f550 (Z03 §3.2) | §7.3 |
| `SetItemIndex` | Z21 §3.2 (always 0xFFFF, Z21-B1) | — |
| `itemdroplog` | `ShineDropItem::so_ItemDrop` FUN_0052a7a0 (Z09 §11.3): row present and `ItemID` == the dropped ID → GameLog 0x0798 | drop logging of the 57 IDs (§6.4) |
| `ItemSortOrder` | `so_ply_ArrangeInven` FUN_00563500 (Z04 §12.5): sort key byte of each cell (0xFF for empty / unknown cells) | inventory auto-arrange order (§6.5) |
| `eDelConditionType` | `sp_ItemInvenDelete(p, cond)` FUN_0051c590: deletes every inventory item whose condition is ≠ `DCT_NONE` and == cond; called only with `DCT_LINKIN_ALL` (1) by `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 (Z01 §6) | the 19 event items of §6.6 vanish at every map login |
| `pBuyItemData` | `NPCRole_Merchant::nrb_ItemBuyItemMoney` FUN_004c7590 (below), `so_ply_ItemBuyItemMoney` FUN_00526ac0 (Z04 §2.2: `IM_MoneyLot × lot` money items needed, lot capped at `MaxLot`) | item-money shop prices (§6.7) |

```pseudo
NPCRole_Merchant::nrb_ItemBuyItemMoney(npc, player, itemid, &moneyId, &moneyLot)        @ FUN_004c7590 (vt 0x20, Z04 §2.1)
    moneyId = 0xFFFF; moneyLot = 0
    e = itemdatabox[itemid]                                       # operator[] FUN_00419020
    if e == null: log "NPCRole_Merchant::nrb_ItemBuyItemMoney : cannot found item inform", itemid; return
    if e.pBuyItemData:
        moneyId  = idb_2itemid(e.pBuyItemData.IM_MoneyIDX)        # FUN_00418ff0: name looked up again at every buy
        moneyLot = e.pBuyItemData.IM_MoneyLot
    # moneyId 0xFFFF = "not an item-money item": the caller (Z04 §2.1) falls back to the normal buy
```

Matches of these member names in `ii_ItemMoneyBuyAll` FUN_005259a0, `sp_NC_ITEM_MOVER_UPGRADE_REQ` FUN_0051c850,
`sp_NC_ITEM_MIX_ITEM_REQ` FUN_00521540 and `sp_NC_ITEM_NEW_UPGRADE_REQ` FUN_0053e360 are the decompiler reusing the
`ItemDataBoxIndex*` type for other objects (offsets such as `pBuyItemData + 3`, `[2].eDelConditionType`, a `FeedType`
string at `itemoption + 0x20`): those functions do not read the index members.

### 7.3 `HitTimeArray` and the multi-hit swing

`sp_Schedule_SwingStart` (Z03 §3.2) takes the item in the player's weapon cell and, for i = 0..2, queues one damage tick
at `AttackSpeed × HitTimeArray[i] / 1000` ms while that is ≥ 1; `HitTimeArray[0] == 0` stops the swing instead.
`sp_Schedule_SwingDamage` cycles `sp_MultiHitNotIndex` back to 0 when the next slot is 0 or the index passes 2. With the
2016 data: every weapon type with a row hits once at half the swing time (500); dual swords hit three times
(1, 360, 833 ‰) and claws three times (1, 100, 633 ‰).

The only weapons without a row are the four production tools (§6.8), so Z27-B1 matters only for them: if the heap block
is zeroed they cannot auto-attack (`HitTimeArray[0] == 0` → swing stops); with garbage they would queue up to three
ticks at arbitrary delays. The block is 2.6 MB, far above the Windows heap's virtual-allocation threshold, so in
practice it is fresh zero-filled pages *(inferred: allocator behaviour, not visible in the code)*.

## 8. Reload behaviour

`idb_Load` runs once, at start-up (§3, only caller `zs_start_home` FUN_005adce0). No GM command or packet reloads the
item table: `&reloaddata` accepts only `ActiveSkill` (Z11 §8.6), and the stand-alone `ItemDataBox::ReadData`
FUN_006494f0 is dead (Z24 §7.3). Changing any of the eight files therefore needs a zone restart.

A second call would not be safe either *(inferred from §3)*: `idb_index` is allocated again without freeing the old
array (the old one leaks), the readers re-read their files into new images while the other loaders that ran after
`idb_Load` (Z24 §7.2: `iba_Load`, `dic_Load`, `rpt_Load`, `igc_Load`) and live objects keep pointers into the old rows,
`idb_btree` only gains / overwrites names (a renamed item would keep its old name too), `sii_JustReviveItem` keeps an old
value if the JustRevival row is gone, and every `ItemSortOrder` / `eDelConditionType` / `pBuyItemData` default is
reset only on the new array.
