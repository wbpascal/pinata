# Zone: collection-card data tables and card roll (Z28)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`. Code read with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …` (the 2016 exe re-analysed with the NA2016
`Zone.pdb`: official names *(pdb2016)*, same addresses as `re-data/exports/zone`). Raw data / disassembly read with
`objdump` and Python over the PE. 2016 table contents decoded with `tools/protocol-re/shn.py` from
`Files/Server/2016/9Data/Shine/`.

Related docs: Z07 §7 (card-collection packets COLLECT dept 49, `cca_IsRewardCondition`, `ccr_Load`), Z27 §2
(`CommonData<CollectCardMobGroup>` ctor / `cd_Load` / `cd_Find`, repeated here only as one row of the tables),
Z20 §2.1 (`BinaryDataBox<T>::bdb_ReadData` template, `CDataReader::Read` checks, identical-code folding), Z18 §4.5 /
§6 (short sketch of `g_CardCollectMake` and four finders; this document is the full specification), Z10 §7.1 /
Z01 §2.2 (`ZoneServer::zs_start_long`, the load stage).

---

## 1. The card tables at a glance

Seven `SHND::CommonData` / `SHND::IndexedCommonData` globals hold six SHN files. All are loaded once, in the start
stage `zs_start_long` FUN_005b8c00 (§2.4); the zone never reloads them.

| Global *(pdb2016)* | Address | Class (`SHND::`) | File (`../9Data/Shine/`) | Reader `bdb_ReadData` | key | row | rows 2016 | Lookup | Used by |
|---|---|---|---|---|---|---|---|---|---|
| `g_CollectCard_CardID` | DAT_14d7138c | `IndexedCommonData<CollectCard, CmpCardCollect<CollectCard>, u16>` (0x30) | CollectCard.shn | `BinaryDataBox<CollectCard>` FUN_005ae9b0 | 0x7e (126) | 0x2a | 334 | inline index by `CC_CardID` (§2.3) | `g_CardCollectMake` FUN_00628880, `so_ply_CollectCardOpen` FUN_006281b0, `cca_IsRewardCondition` FUN_00628d60 |
| `g_CollectCard_MobGroup` | DAT_14d71354 | `CommonData<CollectCard, CmpCollectCard_MobGroup>` (0x1c) | (shares the vector of `g_CollectCard_CardID`) | – | – | – | – | `cd_Find(group, &pos)` FUN_00627db0 | `g_CardCollectMake` |
| `g_CollectCard_ItemIndex` | DAT_14d7131c | `CommonData<CollectCard, CmpCollectCard_ItemIndex>` (0x1c) | (shares the vector) | – | – | – | – | `cd_Find(itemInx)` FUN_00627e30 | `sp_NC_COLLECT_CARDREGIST_REQ` FUN_00628560 |
| `g_CollectCardMobGroup_MobGroup` | DAT_14d713bc | `CommonData<CollectCardMobGroup, CmpCollectCardMobGroup>` | CollectCardMobGroup.shn | FUN_00648d50 (folded, Z27 §2) | 0x12 (18) | 0x24 | 1 180 | `cd_Find(mobInx)` FUN_00627ed0 | `g_CardCollectMake` |
| `g_CollectCardDropRate_CardID` | DAT_00871500 | `CommonData<CollectCardDropRate, CmpCardCollect<CollectCardDropRate>>` | CollectCardDropRate.shn | `BinaryDataBox<CollectCardDropRate>` FUN_00481440 | 0x7 (7) | 0x4 | 334 | (inlined in `g_CardCollectMake`, part 2) | `g_CardCollectMake` |
| `g_CollectCardStarRate` | DAT_14d71338 | `CommonData<CollectCardStarRate, CmpCollectCardStarRate>` | CollectCardStarRate.shn | `BinaryDataBox<CollectCardStarRate>` FUN_005aea80 | 0x10 (16) | 0x7 | 12 | `cd_Find(grade, &pos)` FUN_00627fd0 | `g_CardCollectMake` |
| `g_CollectCardReward` | DAT_14d71370 | `CommonData<CollectCardReward, CmpCollectCardReward>` | CollectCardReward.shn | `BinaryDataBox<CollectCardReward>` FUN_005aeb30 | 0x111 (273) | 0x4a | 18 | `cd_Find(rewardID, itemInx)` FUN_00628060 | `sp_NC_COLLECT_REWARD_REQ` FUN_00628ef0 |
| `g_CollectCardTitle` | DAT_14d71300 | `CommonData<CollectCardTitle, CmpCollectCardTitle>` | CollectCardTitle.shn | `BinaryDataBox<CollectCardTitle>` FUN_004a1b90 | 0x2c (44) | 0x24 | 52 | `cd_Find(itemInx)` FUN_00628110 | `sp_NC_COLLECT_CARDREGIST_REQ` |

Keys and row sizes are the `CDataReader::Read(this, path, key, rowSize)` arguments of each reader (Z20 §2.1: the file
header's `nVersionKey` must equal the key and its `nFieldSize − 2` the row size, else two assert lines and
`ShineExit("BinaryDataBox<T>::bdb_ReadData")`). All 2016 files pass; they agree with
`docs/knowledge/S01-shn-structs.tsv` (columns = members in order). Z07 §7 calls `DAT_14d71370` "the reward table
`CardCollection::CardCollectionReward`": it is `g_CollectCardReward` (the file table); `CardCollectionReward` is the
per-player vector of rewarded IDs (part 2).

`CollectCardGroupDesc.shn` (187 rows in the server folder, 227 in the client's) and `View/CollectCardView.shn` are not
loaded as tables by the zone: GroupDesc is client-only (group names, §3.7), CollectCardView is only checksummed
(`gSHNView_CollectCardView`, initialiser FUN_00699970; the view checksum list is Z01 §2.2).

## 2. `SHND::CommonData<T, Cmp>`: the template

### 2.1 Layout and vtable

```
SHND::CommonData<T, Cmp>   (size 0x1c)                              *(pdb2016)*
    +0x00  vftable            2 slots: [0] cd_Load(), [1] cd_Load(std::vector<T>* external)
    +0x04  char* cd_ShnName   file name below ../9Data/Shine/ (null = this instance never loads a file)
    +0x08  std::vector<T>* cd_Data    the vector the finders search: &cd_MyData, or another instance's vector
    +0x0c  std::vector<T>  cd_MyData  {begin, end, capacity}

SHND::IndexedCommonData<T, Cmp, K> : CommonData<T, Cmp>   (size 0x30)
    +0x1c  std::vector<T*> icd_IndexedData   index: icd_IndexedData[key] = row pointer or null
    +0x2c  K* icd_Index                      the key member as a byte offset into T (0 = CC_CardID)
```

vftables (two entries each, read from the PE): `0x707d0c` IndexedCommonData `{FUN_005b7b00, FUN_00629580}`;
`0x707d00` / `0x707d18` / `0x707d24` the three `CommonData<CollectCard, …>` `{FUN_00629e50, FUN_00629840}`;
`0x707d30` MobGroup `{FUN_005b7b10, FUN_00629840}`; `0x707d3c` DropRate `{FUN_005b7d20, FUN_00629840}`; `0x707d48`
StarRate `{FUN_005b7f50, FUN_00629840}`; `0x707d54` Reward `{FUN_005b80b0, FUN_00629840}`; `0x707d60` Title
`{FUN_005b83b0, FUN_00629840}`. `zs_start_long` calls the bodies directly; no virtual call through these slots was found *(inferred: the vftables are referenced only by the ctors / dtors)*.

### 2.2 Construction (static initialisers)

```pseudo
CommonData<T, Cmp>::CommonData(this, shnName)          @ FUN_00629490 (CollectCard, CmpCardCollect), FUN_00629700 (MobGroup),
                                                         FUN_00629770 (StarRate), FUN_006297d0 (Reward), FUN_00629850 (Title)
    vftable = CommonData<T, Cmp>::vftable
    cd_Data = &cd_MyData; cd_MyData = {null, null, null}; cd_ShnName = shnName
    if cd_Data.begin != cd_Data.end: cd_Data.end = cd_Data.begin        # clear(); a no-op on the fresh vector

CommonData<T, Cmp>::CommonData(this)                   @ FUN_00629620 (CollectCard, CmpCollectCard_MobGroup),
                                                         FUN_00629690 (CollectCard, CmpCollectCard_ItemIndex)
    same, cd_ShnName = null                            # these two are views; they never load (§2.4)
```

| Initialiser *(pdb2016)* | Address | Global | What it does | atexit destructor |
|---|---|---|---|---|
| `SHND::dynamic_initializer_for 'g_CollectCard_CardID'` | FUN_0069ba10 | DAT_14d7138c | ctor FUN_00629490(this, "CollectCard.shn") (string 0x707e3c), then vftable = 0x707d0c (IndexedCommonData), `icd_IndexedData` = empty, `icd_Index` = 0 (key member `CC_CardID` at +0) | FUN_006a1120 → `~IndexedCommonData` FUN_006295a0 (frees `icd_IndexedData`, then `cd_MyData`) |
| `… 'g_CollectCard_MobGroup'` | FUN_0069ba50 | DAT_14d71354 | ctor FUN_00629620 (no name) | FUN_006a1130 (frees `cd_MyData`, empty: the view never owns rows) |
| `… 'g_CollectCard_ItemIndex'` | FUN_0069ba70 | DAT_14d7131c | ctor FUN_00629690 (no name) | FUN_006a1170 (same) |
| `… 'g_CollectCardMobGroup_MobGroup'` | FUN_0069ba90 | DAT_14d713bc | ctor FUN_00629700(this, "CollectCardMobGroup.shn") (0x707e4c) | FUN_006a11b0 |
| `… 'g_CollectCardDropRate_CardID'` | FUN_0069bab0 | DAT_00871500 | **only registers the atexit destructor**: the object is constant-initialised in `.data` (bytes at 0x871500: vftable 0x707d3c, `cd_ShnName` 0x707e64 "CollectCardDropRate.shn", `cd_Data` 0x87150c = its own `cd_MyData`, vector zero) | FUN_006a11f0 |
| `… 'g_CollectCardStarRate'` | FUN_0069bac0 | DAT_14d71338 | ctor FUN_00629770(this, "CollectCardStarRate.shn") (0x707e7c) | FUN_006a1230 |
| `… 'g_CollectCardReward'` | FUN_0069bae0 | DAT_14d71370 | ctor FUN_006297d0(this, "CollectCardReward.shn") (0x707e94) | FUN_006a1270 |
| `… 'g_CollectCardTitle'` | FUN_0069bb00 | DAT_14d71300 | ctor FUN_00629850(this, "CollectCardTitle.shn") (0x707eac) | FUN_006a12b0 |

The destructors only free the vectors (process exit).

### 2.3 Loading and the CardID index

All `cd_Load()` bodies are the same template instance with the row type's size, default row and reader:

```pseudo
CommonData<T, Cmp>::cd_Load(this)        @ FUN_00629e50 (CollectCard, folded for all three CollectCard instances; PDB name
                                           `CommonData<CollectCard, CmpCollectCard_MobGroup>::cd_Load`), FUN_005b7b10 (MobGroup,
                                           Z27 §2), FUN_005b7d20 (DropRate), FUN_005b7f50 (StarRate), FUN_005b80b0 (Reward),
                                           FUN_005b83b0 (Title)
    if cd_ShnName == null:
        AssertFail "CommonData<T, C>::cd_Load : Name NULL"; ShineExit("CommonData<T, C>::cd_Load")
        # StarRate (FUN_005b7f50) has the test inverted in layout only (if name != null { load } else { assert; exit })
    path = sprintf("../9Data/Shine/%s", cd_ShnName)            # 0x200-byte stack buffer
    cd_Data.clear()                                             # end = begin; capacity kept
    reader = BinaryDataBox<T>; reader.bdb_defaultblock = default row (below)
    reader.bdb_ReadData(path)                                   # checked read, exits on failure (Z20 §2.1)
    for r in 0 .. reader.rowcount − 1:                          # rowcount = header u32 at reader data +0x28
        row = r < rowcount ? CDataReader::GetRecord(reader, r) : &bdb_defaultblock   # the default branch is dead
        cd_Data.push_back(copy of row)                          # sizeof T bytes; the vector grows ×1.5
    ~BinaryDataBox(reader)                                      # the file buffer is freed; rows live only in the vector

    default rows: CollectCard all 0 (memset 0x2a); DropRate {0, 0}; StarRate {CG_S_GRADE, 0, 0};
                  Reward all 0 (memset 0x4a); Title {ID_NONE, ""}; MobGroup {"", MG_NONE}

IndexedCommonData<CollectCard, CmpCardCollect<CollectCard>, u16>::cd_Load(this)    @ FUN_005b7b00
    CommonData<CollectCard, …>::cd_Load(this)                   # FUN_00629e50
    icd_Indexing(this)                                          # FUN_005b3f40
    # not called: zs_start_long inlines the same two calls (§2.4)

IndexedCommonData<…>::icd_Indexing(this)                        @ FUN_005b3f40
    for each row p in *cd_Data (file order):
        key = *(u16*)((byte*)p + icd_Index)                     # = p.CC_CardID
        while icd_IndexedData.size() <= key: icd_IndexedData.push_back(null)
        icd_IndexedData[key] = p                                # a duplicate CardID: the later row wins
    # icd_IndexedData is never cleared first: a second indexing keeps entries of IDs that left the file
    # (latent; nothing reloads, §2.4). The pointers point into cd_Data, which is not reallocated after the load.

inline lookup by CardID (in FUN_00628880, FUN_006281b0, FUN_00628d60):
    row = (id < icd_IndexedData.size() && icd_IndexedData[id] != null) ? icd_IndexedData[id] : none
    # 2016: index size 335, slots 1..334 filled, slot 0 null

CommonData<T, Cmp>::cd_Load(this, std::vector<T>* external)    @ FUN_00629840 (vtable slot 1 of every non-indexed instance)
    cd_Data = external                                          # use another instance's rows; no copy
    # identical-code folding: the same 3-instruction body is also called as "cd_Load" from the ShinePlayer ctor
    # FUN_0055bc80 on `sp_Item.invenlocklist` (sets that object's +8 owner pointer); it is not a card-table use
IndexedCommonData<…>::cd_Load(this, external)                  @ FUN_00629580
    cd_Data = external; icd_Indexing(this)                      # not called in 2016
```

### 2.4 Load order (`ZoneServer::zs_start_long`)

```pseudo
zs_start_long():                                               @ FUN_005b8c00 (stage list: Z10 §7.1)
    … speed factors, spammer penalty, abstate-in-field, map buff, boss content …
    CommonData<CollectCard, CmpCollectCard_MobGroup>::cd_Load(&g_CollectCard_CardID)   # FUN_00629e50: CollectCard.shn
    IndexedCommonData<…>::icd_Indexing(&g_CollectCard_CardID)                           # FUN_005b3f40
    g_CollectCard_MobGroup.cd_Data  = g_CollectCard_CardID.cd_Data      # (0x14d7135c ← [0x14d71394]) one shared vector
    g_CollectCard_ItemIndex.cd_Data = g_CollectCard_CardID.cd_Data      # (0x14d71324 ← [0x14d71394])
    g_CollectCardMobGroup_MobGroup.cd_Load()                   # FUN_005b7b10
    g_CollectCardDropRate_CardID.cd_Load()                     # FUN_005b7d20
    g_CollectCardStarRate.cd_Load()                            # FUN_005b7f50
    g_CollectCardReward.cd_Load()                              # FUN_005b80b0
    g_CollectCardTitle.cd_Load()                               # FUN_005b83b0
    … gamble tables (GBBanGame, GBTaxRate, GBEventCode, GBReward), slot machines, LC reward, movers (Z06 / Z13 / Z24) …
```

So `CollectCard.shn` is read once and searched three ways: by ID through the index, by mob group and by item
InxName through the two views. A missing or mismatching file ends the process at start-up. No GM command or timer
calls any `cd_Load` again (the only callers of FUN_00629e50 / FUN_005b3f40 / FUN_005b7b10 … FUN_005b83b0 are
`zs_start_long`), so the tables are fixed for the process lifetime.

### 2.5 Finders

All are linear scans over `*cd_Data` in file order and return the first match (the item-name compares are plain
`strcmp` on NUL-terminated strings: case-sensitive, stop at the first NUL). The iterator forms take `ulong* pos`: the
scan starts at `*pos`, and on return `*pos` is one past the row returned (or `size` when none is left), so a caller
loops `while (row = cd_Find(key, &pos))` to visit every match.

```pseudo
CommonData<CollectCard, CmpCardCollect<CollectCard>>::cd_Find(cardID)              @ FUN_00627d30
    first row with CC_CardID == cardID, else null
    # called once, from g_CardCollectMake (part 2); the index of §2.3 gives the same row for unique IDs

CommonData<CollectCard, CmpCollectCard_MobGroup>::cd_Find(group, &pos)              @ FUN_00627db0
    from pos: first row with CC_CardMobGroup (+0x26) == group; pos = index + 1

CommonData<CollectCard, CmpCollectCard_ItemIndex>::cd_Find(itemInx)                 @ FUN_00627e30
    first row with strcmp(CC_ItemInx (+0x02), itemInx) == 0, else null
    # the card of an opened card item; Z07 §7 0xC408 (error 0x2B95 when none)

CommonData<CollectCardMobGroup, CmpCollectCardMobGroup>::cd_Find(mobInx)            @ FUN_00627ed0
    first row whose 32-byte CC_MobInx equals the 32-byte mob InxName (Z27 §2)

CommonData<CollectCardStarRate, CmpCollectCardStarRate>::cd_Find(grade, &pos)       @ FUN_00627fd0
    from pos: first row with CC_CardGradeType (+0) == grade; pos = index + 1

CommonData<CollectCardReward, CmpCollectCardReward>::cd_Find(rewardID, itemInx)     @ FUN_00628060
    first row with CC_RewardID == rewardID and strcmp(CC_RewardItemInx (+0x08), itemInx) == 0, else null
    # several rows share one RewardID (a choice of reward items, §3.5), so the item name is part of the key

CommonData<CollectCardTitle, CmpCollectCardTitle>::cd_Find(itemInx)                 @ FUN_00628110
    first row with strcmp(CC_ItemInx (+0x04), itemInx) == 0, else null
```

## 3. The files: column → member maps and 2016 data invariants

Each file's columns are the members of the row struct in order (types: 2 = u16, 1 = u8, 9 = fixed string, 11 = u32
enum). A rebuild that keeps the struct layouts loads the original files unchanged. Invariants are those of the 2016
server files; "code relies on" marks the ones whose violation would change behaviour.

### 3.1 CollectCard.shn → `CollectCard` (0x2a, 4 columns, 334 rows)

| Column (type:size) | Member | Offset | 2016 values |
|---|---|---|---|
| CC_CardID (2:2) | `u16 CC_CardID` | 0x00 | 1 … 334, unique, contiguous, ascending in file order |
| CC_ItemInx (9:32) | `char CC_ItemInx[32]` | 0x02 | item InxName of the card item, unique; all 334 exist in ItemInfo.shn, all with `Class` 31 (opened collection card), item IDs 58273 … 65042 |
| CC_CardGradeType (11:4) | `CardGrade CC_CardGradeType` | 0x22 | 0 `CG_S_GRADE` 39 cards, 1 `CG_A_GRADE` 81, 2 `CG_B_GRADE` 91, 3 `CG_C_GRADE` 123 (`MAX_CARDGRADE` 4) |
| CC_CardMobGroup (11:4) | `CardMobGroupIndex CC_CardMobGroup` | 0x26 | 226 distinct groups in 1 … 234 (missing 18, 33, 136, 140, 171–173, 179); never 0 `MG_NONE` |

- Cards per group: 155 groups have 1 card, 49 have 2, 12 have 3, 7 have 4, 2 have 5, 1 has 7. 53 groups mix grades.
- The 2016 PDB enum `CardMobGroupIndex` ends at `MG_GOLEM` = 187 (`MAX_CARDMOBGROUPINDEX` 188); the data uses groups up to
  234 (80 cards in 47 groups ≥ 188, e.g. 188 "Devildom", 234 "ValeBattleBeak" in the client's GroupDesc). No code
  compares a group with the enum maximum, so the larger values work: a rebuild must keep the member a plain u32.
- Code relies on: unique `CC_CardID` (index, §2.3; duplicates: index takes the last row, `cd_Find` the first);
  unique `CC_ItemInx` (`cd_Find(itemInx)` takes the first); `CC_CardGradeType` < 4 (`cca_IsRewardCondition` skips
  ≥ 4; the star roll finds no StarRate row for other values, part 2).
- The client ships the same file (`ressystem/CollectCard.shn`, rows identical).

### 3.2 CollectCardMobGroup.shn → `CollectCardMobGroup` (0x24, 2 columns, 1 180 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| CC_MobInx (9:32) | `char CC_MobInx[32]` | 0x00 | mob InxName, unique (≤ 23 chars); 1 179 exist in MobInfo.shn, `RatmanWarlock` does not (that row can never match) |
| CC_CardMobGroup (11:4) | `CardMobGroupIndex CC_CardMobGroup` | 0x20 | the same 226 groups as CollectCard (every card group has mobs, every mob group has cards) |

Mobs per group: 1 to 24 (53 groups have one mob). A mob listed here can drop an unidentified card of its group
(part 2); a mob not listed never yields a card even if its drop table names the card item (Z18 §4.5: the roll's result is the
drop decision; detail in part 2). Code relies on: one row
per mob (first match wins).

### 3.3 CollectCardDropRate.shn → `CollectCardDropRate` (0x4, 2 columns, 334 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| CC_CardID (2:2) | `u16 CC_CardID` | 0x0 | exactly the CollectCard IDs, same order (1 … 334) |
| CC_CardGetRate (2:2) | `u16 CC_CardGetRate` | 0x2 | 5 … 100 (100 ×153, 50 ×37, 30 ×34, 20 ×21, 70 ×20, …); never 0 |

Weight sums per mob group: 221 groups sum to 100; groups 193–196 (one card each, `CC_DT_*Focalor_C`) sum to 25;
group 158 (`CC_Shella` + `CC_ValeShella`, 100 each) sums to 200. How the weights become odds is the roll (part 2).
Code relies on: one row per card (the roll's lookup, part 2).

### 3.4 CollectCardStarRate.shn → `CollectCardStarRate` (0x7, 3 columns, 12 rows)

| Column | Member | Offset |
|---|---|---|
| CC_CardGradeType (11:4) | `CardGrade CC_CardGradeType` | 0x0 |
| CC_StarLot (1:1) | `u8 CC_StarLot` (the star count) | 0x4 |
| CC_StarRate (2:2) | `u16 CC_StarRate` (weight) | 0x5 (unaligned; the struct is packed) |

The whole 2016 file:

| Grade | Stars (weight) |
|---|---|
| 0 S | 9 (10), 8 (50), 7 (80) |
| 1 A | 7 (10), 6 (50), 5 (80) |
| 2 B | 5 (50), 4 (50), 3 (50) |
| 3 C | 3 (50), 2 (50), 1 (50) |

Three rows per grade, grades in order; star counts 1 … 9, never 0 (the roll treats star 0 as "no card", part 2).

### 3.5 CollectCardReward.shn → `CollectCardReward` (0x4a, 5 columns, 18 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| CC_RewardID (2:2) | `u16 CC_RewardID` | 0x00 | 1 … 14; ID 8 has 4 rows, ID 9 has 2 (the player picks one item) |
| CC_CardRewardType (11:4) | `CardReward CC_CardRewardType` | 0x02 | 0 `CR_ALL`, 1 `CR_S`, 2 `CR_A`, 3 `CR_B`, 4 `CR_C` (`MAX_CARDREWARD` 5) |
| CC_CardLot (2:2) | `u16 CC_CardLot` | 0x06 | cards needed of that grade (type 0: any grade) |
| CC_RewardItemInx (9:64) | `char CC_RewardItemInx[64]` | 0x08 | reward item InxName (all exist in ItemInfo) |
| CC_RewardLot (2:2) | `u16 CC_RewardLot` | 0x48 | 1 in every row |

The 2016 rows (ID: type, cards needed → item [ItemInfo class]):

| ID | Condition | Item(s) |
|---|---|---|
| 1 | 14 S | Neck_Collect01 [4] |
| 2 | 28 A | Ear_Collect01 [4] |
| 3 | 35 B | Ring_Collect01 [4] |
| 4 | 48 C | Ring_Collect02 [4] |
| 5 | 28 S | Back_Collect01 [10] |
| 6 | 57 A | Cos_Collect01 [10] |
| 7 | 71 B | Hat_Collect01 [10] |
| 8 | 97 C | one of M_Collect_Coll, M_Collect_WhiteColl, M_Collect_Hobby, M_Collect_WhiteHobby [23] |
| 9 | 253 any | one of MiniHelga01, MiniHumar01 [10] |
| 10 | 334 any (all cards) | MiniAstanica [10] |
| 11 | 39 S (all S) | MiniFreloan [10] |
| 12 | 81 A (all A) | Cos_CollectS02 [10] |
| 13 | 91 B (all B) | Hat_CollectS02 [10] |
| 14 | 123 C (all C) | Back_CollectS02 [10] |

The type → grade mapping (`CR_S` = 1 → grade 0 …, `CR_ALL` → all grades) and the count test are
`cca_IsRewardCondition` (Z07 §7). Every condition is reachable: `CC_CardLot` never exceeds the number of cards of
that grade (IDs 10–14 need exactly all of them). Whether the zone reads `CC_RewardLot` (Z07 §7 makes the new item with `ItemKey_Make(RewardItem, …)` and names no
lot) is checked with `sp_NC_COLLECT_REWARD_REQ` in part 2.
The client ships the same file (rows identical).

### 3.6 CollectCardTitle.shn → `CollectCardTitle` (0x24, 2 columns, 52 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| Type (11:4) | `CHARACTER_TITLE_TYPE Type` | 0x00 | 61 … 112, one row each |
| CC_ItemInx (9:32) | `char CC_ItemInx[32]` | 0x04 | a CollectCard `CC_ItemInx`, unique |

Registering one of these 52 cards grants the character title `Type` (consumer: `sp_NC_COLLECT_CARDREGIST_REQ` →
`so_ply_CardRegist(…, CHARACTER_TITLE_TYPE)`, part 2). The enum names *(pdb2016)* are `ID_CC_<card>`, e.g. 61
`ID_CC_HUMAR02` = `CC_Humar02`; 50 of 52 match the card name exactly, 95 `ID_CC_SHYLPH` (`CC_Shylph01`) and 106
`ID_CC_LIVINGSTATUE02` (`CC_LivingStatue01`) differ only in the name. 113 is `ID_JOB_SENTINEL`, so the card titles
are exactly the enum range 61 … 112. The client ships the same file (rows identical).

### 3.7 Not loaded by the zone

- `CollectCardGroupDesc.shn` (`CC_CardMobGroup` u32, `CC_MobGroupName` char[64]): server copy 187 rows with Korean
  names (groups 1 … 187), client copy 227 rows in English up to group 234. Only the client reads it (`FUN_0045de90`,
  "CollectCardGroupDesc.shn InitError!!"); no zone string names it.
- `View/CollectCardView.shn`: checksum only (Z01 §2.2).
