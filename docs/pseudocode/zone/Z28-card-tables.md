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
| `g_CollectCardDropRate_CardID` | DAT_00871500 | `CommonData<CollectCardDropRate, CmpCardCollect<CollectCardDropRate>>` | CollectCardDropRate.shn | `BinaryDataBox<CollectCardDropRate>` FUN_00481440 | 0x7 (7) | 0x4 | 334 | (inlined in `g_CardCollectMake`, §4.2) | `g_CardCollectMake` |
| `g_CollectCardStarRate` | DAT_14d71338 | `CommonData<CollectCardStarRate, CmpCollectCardStarRate>` | CollectCardStarRate.shn | `BinaryDataBox<CollectCardStarRate>` FUN_005aea80 | 0x10 (16) | 0x7 | 12 | `cd_Find(grade, &pos)` FUN_00627fd0 | `g_CardCollectMake` |
| `g_CollectCardReward` | DAT_14d71370 | `CommonData<CollectCardReward, CmpCollectCardReward>` | CollectCardReward.shn | `BinaryDataBox<CollectCardReward>` FUN_005aeb30 | 0x111 (273) | 0x4a | 18 | `cd_Find(rewardID, itemInx)` FUN_00628060 | `sp_NC_COLLECT_REWARD_REQ` FUN_00628ef0 |
| `g_CollectCardTitle` | DAT_14d71300 | `CommonData<CollectCardTitle, CmpCollectCardTitle>` | CollectCardTitle.shn | `BinaryDataBox<CollectCardTitle>` FUN_004a1b90 | 0x2c (44) | 0x24 | 52 | `cd_Find(itemInx)` FUN_00628110 | `sp_NC_COLLECT_CARDREGIST_REQ` |

Keys and row sizes are the `CDataReader::Read(this, path, key, rowSize)` arguments of each reader (Z20 §2.1: the file
header's `nVersionKey` must equal the key and its `nFieldSize − 2` the row size, else two assert lines and
`ShineExit("BinaryDataBox<T>::bdb_ReadData")`). All 2016 files pass; they agree with
`docs/knowledge/S01-shn-structs.tsv` (columns = members in order). Z07 §7 calls `DAT_14d71370` "the reward table
`CardCollection::CardCollectionReward`": it is `g_CollectCardReward` (the file table); `CardCollectionReward` is the
per-player vector of rewarded IDs (§5.1).

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
    # called once, from g_CardCollectMake (§4.2); the index of §2.3 gives the same row for unique IDs

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
  ≥ 4; the star roll finds no StarRate row for other values, §4.2).
- The client ships the same file (`ressystem/CollectCard.shn`, rows identical).

### 3.2 CollectCardMobGroup.shn → `CollectCardMobGroup` (0x24, 2 columns, 1 180 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| CC_MobInx (9:32) | `char CC_MobInx[32]` | 0x00 | mob InxName, unique (≤ 23 chars); 1 179 exist in MobInfo.shn, `RatmanWarlock` does not (that row can never match) |
| CC_CardMobGroup (11:4) | `CardMobGroupIndex CC_CardMobGroup` | 0x20 | the same 226 groups as CollectCard (every card group has mobs, every mob group has cards) |

Mobs per group: 1 to 24 (53 groups have one mob). A mob listed here can drop an unidentified card of its group
(§4.2); a mob not listed never yields a card even if its drop table names the card item (Z18 §4.5: the roll's result is the
drop decision; §4.2 / §4.3). Code relies on: one row
per mob (first match wins).

### 3.3 CollectCardDropRate.shn → `CollectCardDropRate` (0x4, 2 columns, 334 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| CC_CardID (2:2) | `u16 CC_CardID` | 0x0 | exactly the CollectCard IDs, same order (1 … 334) |
| CC_CardGetRate (2:2) | `u16 CC_CardGetRate` | 0x2 | 5 … 100 (100 ×153, 50 ×37, 30 ×34, 20 ×21, 70 ×20, …); never 0 |

Weight sums per mob group: 221 groups sum to 100; groups 193–196 (one card each, `CC_DT_*Focalor_C`) sum to 25;
group 158 (`CC_Shella` + `CC_ValeShella`, 100 each) sums to 200. How the weights become odds is the roll (§4.3).
Code relies on: one row per card (the roll's lookup, §4.2; a missing row crashes, Z28-B3).

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

Three rows per grade, grades in order; star counts 1 … 9, never 0 (the roll treats star 0 as "no card", §4.2).

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
that grade (IDs 10–14 need exactly all of them). The zone never reads `CC_RewardLot` (§5.4, Z28-B4).
The client ships the same file (rows identical).

### 3.6 CollectCardTitle.shn → `CollectCardTitle` (0x24, 2 columns, 52 rows)

| Column | Member | Offset | 2016 values |
|---|---|---|---|
| Type (11:4) | `CHARACTER_TITLE_TYPE Type` | 0x00 | 61 … 112, one row each |
| CC_ItemInx (9:32) | `char CC_ItemInx[32]` | 0x04 | a CollectCard `CC_ItemInx`, unique |

Registering one of these 52 cards grants the character title `Type` (consumer: `sp_NC_COLLECT_CARDREGIST_REQ` →
`so_ply_CardRegist(…, CHARACTER_TITLE_TYPE)`, §5.3). The enum names *(pdb2016)* are `ID_CC_<card>`, e.g. 61
`ID_CC_HUMAR02` = `CC_Humar02`; 50 of 52 match the card name exactly, 95 `ID_CC_SHYLPH` (`CC_Shylph01`) and 106
`ID_CC_LIVINGSTATUE02` (`CC_LivingStatue01`) differ only in the name. 113 is `ID_JOB_SENTINEL`, so the card titles
are exactly the enum range 61 … 112. The client ships the same file (rows identical).

### 3.7 Not loaded by the zone

- `CollectCardGroupDesc.shn` (`CC_CardMobGroup` u32, `CC_MobGroupName` char[64]): server copy 187 rows with Korean
  names (groups 1 … 187), client copy 227 rows in English up to group 234. Only the client reads it (`FUN_0045de90`,
  "CollectCardGroupDesc.shn InitError!!"); no zone string names it.
- `View/CollectCardView.shn`: checksum only (Z01 §2.2).

---

## 4. The card roll and the card item classes

A mob drops collection cards as one item: the sealed card `CC_Closed` (ItemInfo ID 58272, `Class` 30, the only class-30
item in 2016). Whether it drops at all is the mob's drop table (Z09 §11.2: `dilig_Drop` FUN_0048e260 picks the item,
then asks the item class for the attributes). For the sealed card the attribute builder is the card roll below. It
picks the card and the star count at drop time. Opening the card (Z05 §6.6) only turns that result into the opened
card item.

### 4.1 Item attribute classes

`ItemAttrCls_CardCollect_Close` (class 30, sealed) and `ItemAttrCls_CardCollect` (class 31, opened) *(pdb2016)*. Their
vftables (51 slots, `rtti.py`) differ only in the slots below. The other slots are the shared defaults: vt 0x1c `GetLot`
FUN_0063ec90 returns 1 and vt 0x20 `SetLot` FUN_00509900 does nothing (both folded code), so `dilig_Drop`'s
`lot × lotFactor` and its upgrade roll have no effect on cards.

| Slot | Sealed (`…_Close`) | Opened |
|---|---|---|
| 0x04 `iac_fill2buffer` | FUN_0063e9b0: 9 bytes = the whole `ShineItemAttr_MobCardCollect_Unident` | FUN_0063e9e0: 5 bytes `{u32 SerialNumber, u8 Star}` |
| 0x08 `iac_fill2struct` | FUN_0063eba0: the same 9 bytes back | FUN_0063ebd0: the same 5 bytes back |
| 0x0c `iac_GetAttrSize` | FUN_0063ecb0: 9 | FUN_00643140 (folded): 5 |
| 0x14 `iac_itemcreate` | FUN_0063f390 (below) | FUN_0063f3b0 (below) |
| 0x28 `iac_ItemClass` | FUN_0063e4c0 (folded): 0x1e = 30 | FUN_0063e4d0: 0x1f = 31 |
| 0x2c `iac_DropItemMake` | FUN_0063faf0: `g_CardCollectMake` | FUN_00510f50 (folded): 0, an opened card never drops |

Attribute layouts *(pdb2016)*: `ShineItemAttr_MobCardCollect_Unident` (9 bytes, packed) = `{u32 SerialNumber @0,
u16 CardID @4, u8 Star @6, u16 Group @7}`; `ShineItemAttr_MobCardCollect` (5 bytes) = `{u32 SerialNumber @0, u8 Star @4}`.
The Ghidra union member names in the export (`dlot.lot`, `amulet.IsPutOnBelonged`, `furniture.deletetime.field_0x1`,
`binditem.portal[0].x + 1`, `weapon.mobkills[0].monster`) are these offsets of `SHINE_ITEM_ATTRIBUTE` (0x65 bytes);
the attribute starts at `ItemTotalInformation` +0xa (`SHINE_ITEM_STRUCT` +2).

```pseudo
ItemAttrCls_CardCollect_Close::iac_DropItemMake(ItemTotalInformation* item, ItemGroup* row, int roll, u16 mobID)   @ FUN_0063faf0
    return g_CardCollectMake(mobID, &item.iti_itemstruct.itemattr.MobCard_Unident)      # row and roll unused
    # false = the item is not dropped (dilig_Drop / itemdrop return without a drop, Z09 §11.2 / §24.1)

ItemAttrCls_CardCollect_Close::iac_itemcreate(u16 itemID, ItemTotalInformation* item, char* opts)   @ FUN_0063f390
    attr.SerialNumber = 26 999 999 (0x019BFCBF); attr.CardID = 1; attr.Group = 1     # Star is not written; opts unused
ItemAttrCls_CardCollect::iac_itemcreate(itemID, item, opts)                         @ FUN_0063f3b0
    a = RandomBox[26] (0…25); b = RandomBox[98] (0…97); c = well512_GetRandom(1000) (0…999)
    attr.SerialNumber = (101 + 100·a + b) · 10 000 + c            # 1 010 000 … 26 980 999
    attr.Star = low byte of RandomBox[10] (0…9)                   # opts unused
```

`RandomBox[n]` = the next value of shuffled ring n (uniform 0…n−1, `rndbox.rb_box[n]`, read inline here; `docs/knowledge/Z23.md`,
Z09 §8). vt 0x14 runs only for items made outside the drop path: admin `&makeitem` (Z11 §4.3), the Pine
item nodes (Z09 §23.8 / §24.2) and the reward item (§5.4 below). A GM-made `CC_Closed` therefore opens as card 1 (§4.4), with star 0 when the caller
zeroed the attribute *(inferred)*. A GM-made opened card gets a random serial and star 0…9, independent of the card's
grade; the serial is not unique.

Mob drops never call vt 0x14: `dilig_Drop` zeroes the 0x67 bytes of item ID + attribute (FUN_0048e260), so a dropped
sealed card has `SerialNumber` 0. The Character DB numbers it when it stores a class-30 item with serial 0
(`CollectionCardSerial::GetCollectionCardSerial` per card ID, D03 §12).

### 4.2 `g_CardCollectMake`

```pseudo
g_CardCollectMake(u16 mobID, ShineItemAttr_MobCardCollect_Unident* card) → bool      @ FUN_00628880
    mob = mobdatabox[mobID]; no row: return false
    name = MobInfo.InxName (strncpy 32 bytes into a zeroed Name8)
    mg = g_CollectCardMobGroup_MobGroup.cd_Find(name)            # FUN_00627ed0 (§2.5); none: return false
    card.Group  = (u16) mg.CC_CardMobGroup
    card.CardID = 0xFFFF; W = 0; pos = 0
    while (c = g_CollectCard_MobGroup.cd_Find(mg.CC_CardMobGroup, &pos)) != null:   # FUN_00627db0, file order
        d = first row of g_CollectCardDropRate_CardID.cd_Data with d.CC_CardID == c.CC_CardID   # inline linear search
            # none: d = null and d.CC_CardGetRate reads address 2: access violation (original bug) Z28-B3, latent
        W += d.CC_CardGetRate                                     # u32
        r = RandomBox::rb_1000000() (FUN_0048dfb0, well512 0…999 999)
        if (double)W · r / 1 000 000.0 < d.CC_CardGetRate: card.CardID = d.CC_CardID
    if card.CardID == 0xFFFF: return false                        # group without cards, or every weight 0
    c = g_CollectCard_CardID index[card.CardID]                   # inline index (§2.3); none: return false
    card.Star = 0; S = 0; pos = 0
    while (s = g_CollectCardStarRate.cd_Find(c.CC_CardGradeType, &pos)) != null:      # FUN_00627fd0, file order
        S += s.CC_StarRate
        r = rb_1000000()
        if (double)S · r / 1 000 000.0 < s.CC_StarRate: card.Star = s.CC_StarLot
    return card.Star != 0           # grade without StarRate rows, or all weights 0: no drop
    # on false, Group / CardID may already be written; the item is discarded anyway
    # SerialNumber is never touched (0 from dilig_Drop, §4.1)
```

`Group` is stored in the sealed card but nothing in the zone reads it back (opening uses only `CardID` and `Star`).
The client receives the 9 attribute bytes with the item, so card and star are known before opening *(inferred: the
client's class-30 item display was not opened)*.

### 4.3 Odds

Both loops are a one-pass weighted pick (reservoir sampling): step k replaces the pick with probability
`p_k = ⌈w_k · 10⁶ / W_k⌉ / 10⁶` (strict `<` over the integers `r` = 0…999 999; `W_k` = sum of the weights so far).
The first step always picks (p_1 = 1 for w_1 > 0). The final pick is item k with probability
`p_k · Π_{j>k}(1 − p_j)`, which equals `w_k / W` up to 10⁻⁶ rounding. So:

- **Card:** P(card) = `CC_CardGetRate / (sum of CC_CardGetRate over all cards of the mob's group)`. Only ratios count:
  groups 193–196 (one card, weight 25) and group 158 (two cards × 100, sum 200) behave like groups that sum to 100.
  Single-card groups (155 of 226) always give their card. Examples (2016): group 164 Slime: `CC_Slime02` (S) 20 % ·
  `CC_Slime01` (A) 75 % · `CC_Slime03` (C) 5 %; group 103: `CC_MageBook03` (S) 15 %, `…02` (A) 35 %, `…01` (B) 50 %.
- **Star:** by the card's grade (`CC_CardGradeType`); 2016 odds, with the exact 10⁻⁶ results:

| Grade | Stars: probability | Mean |
|---|---|---|
| 0 S | 9★ 7.1428 % (10/140), 8★ 35.7143 % (50/140), 7★ 57.1429 % (80/140) | 7.50 |
| 1 A | 7★ 7.1428 %, 6★ 35.7143 %, 5★ 57.1429 % | 5.50 |
| 2 B | 5★ / 4★ / 3★ 33.3333 % each (3★ 33.3334 %) | 4.00 |
| 3 C | 3★ / 2★ / 1★ 33.3333 % each (1★ 33.3334 %) | 2.00 |

- **Drop or not:** with the 2016 data the roll never fails for a mob that has a `CollectCardMobGroup` row. Every one of
  the 226 MobGroup groups has cards, every weight is > 0, every grade has StarRate rows and no `CC_StarLot` is 0. So a
  `CC_Closed` drop chosen by the drop table (Z09 §11.2) always happens. For a mob without a MobGroup row (a MobInfo InxName that is not one of the
  1 180 `CC_MobInx` names) the drop is silently cancelled.
- A rebuild must keep: the file order of cards within a group and of StarRate rows (only for exact random-stream
  reproduction; the distribution does not depend on it), `rb_1000000` as the random source, and star 0 = "no drop".

### 4.4 Opening: sealed attribute → opened card

`so_ply_CollectCardOpen` FUN_006281b0 (vt 0xc08) is the `0x34A9` answer of Z05 §6.6, which has its packets and errors.
The attribute transfer:

```pseudo
so_ply_CollectCardOpen(p, PROTO_NC_ITEMDB_ITEMINFO_ACK* a)                      @ FUN_006281b0
    cell = first unlocked inventory cell (box 9) whose item key == a.ItemInfo.iti_registnum      # none → 0xC407 err 0x2B82, 0x3016 {0x706}
    id = a.ItemInfo attr.CardID; row = g_CollectCard_CardID index[id]; item = ItemDataBox::idb_2itemid(row.CC_ItemInx)
        # id out of range, no row, or unknown item → same 0xC407 0x2B82 path
    new = { key = iti_mkregnum(item, 3, zoneNo, worldNo), itemid = item,
            attr (opened, 5 bytes) = { SerialNumber = sealed.SerialNumber, Star = sealed.Star } }
    → DB 0x34AA NC_ITEMDB_ITEMREBUILD_REQ (erase the sealed card, create `new` in the same slot; Z05 §6.6); p ← 0x3016 {0x700}
```

The card ID and stars are therefore fixed at drop time (§4.2). The serial is the Character DB's number (§4.1).

---

## 5. Per-player card state

### 5.1 Containers

Three STL vectors in `ShinePlayer` *(pdb2016)*, each 0x10 bytes, built by the folded empty-vector ctor
`CardCollection::CardCollectionReward::CardCollectionReward` FUN_00629150 (Z18 §6.5):

| Member | Offset | Class | Element |
|---|---|---|---|
| `sp_CardCollectAlbum` | p+0x2aa94 | `CardCollection::CardCollectionAlbum` | `PROTO_NC_CHAR_CARDCOLLECT_CMD::CardInform` (11 bytes): `long RegistTime @0, u32 SerialNumber @4, u16 CardID @8, u8 StarNumber @0xa` |
| `sp_CardCollectBookmark` | p+0x2aaa4 | `CardCollection::CardCollectionBookmark` | `CardBookmarkInfo` (4): `u16 Slot, u16 CardID` |
| `sp_CardCollectReward` | p+0x2aab4 | `CardCollection::CardCollectionReward` | `u16` RewardID |

Readers: `cca_IsRewardCondition` FUN_00628d60 (album card IDs → grades, Z07 §7), `sp_NC_COLLECT_BOOKMARK_REGIST_REQ`
FUN_00628b80 (album membership), `sp_NC_COLLECT_REWARD_REQ` FUN_00628ef0 (rewarded IDs), `sp_CardCollectionSend`
FUN_0044cc30 (all three to the client after the map login, Z18 §6.5). The base `ShineObject::so_ply_CardRegist`
FUN_00402370 (vt 0xc0c for non-players) does nothing.

### 5.2 Loading from the WorldManager (0x10E3 / 0x10E6 / 0x10E9)

The WM forwards the three lists it got from the Character DB at character login (W01 §6.3, row "+0x6c8 / +0x6d0 / +0x6d8
card collection"). Z07 §1.2 lists the dispatch. Payload = 6-byte `ref` `{u16 handle, u32 charNo}` (Z01) + the PROTO struct.

```pseudo
0x10E3 NC_CHAR_ZONE_CARDCOLLECT_CMD { ref, PROTO_NC_CHAR_CARDCOLLECT_CMD { u32 chrregnum, u16 number, CardInform[number] } }
                                                                           @ FUN_0044cef0
0x10E6 NC_CHAR_ZONE_CARDCOLLECT_BOOKMARK_CMD { ref, { u32 chrregnum, u16 number, CardBookmarkInfo[number] } }   @ FUN_0044d090
0x10E9 NC_CHAR_ZONE_CARDCOLLECT_REWARD_CMD { ref, { u32 chrregnum, u16 number, u16 RewardID[number] } }         @ FUN_0044d230
    p = som_GetObject(ref.handle)
    if p and p.vt[0x344]() (charNo) == ref.charNo and not p.vt[0x300]() (so_IsEmpty):
        0x10E3: p.vt[0xbfc] so_ply_CardCollect(&body)           @ FUN_0044cfe0 → sp_CardCollectAlbum.cca_Load(body)    @ FUN_006298c0
        0x10E6: p.vt[0xc00] so_ply_CardCollectBookMark(&body)   @ FUN_0044d180 → sp_CardCollectBookmark.ccb_Load(body) @ FUN_00629a50
        0x10E9: p.vt[0xc04] so_ply_CardCollectReward(&body)     @ FUN_0044d320 → sp_CardCollectReward.ccr_Load(body)   @ FUN_00629160
    else: assert "WorldManagerSession::wms_NC_CHAR_ZONE_CARDCOLLECT[_BOOKMARK|_REWARD]_CMD : Invalid player"; nothing else

cca_Load / ccb_Load / ccr_Load(list):
    clear the vector (end = begin)
    for i in 0 … number−1: push_back(list[i])         # 11 / 4 / 2 bytes copied as is, file order kept
    # number is trusted: no check against the packet length (the length argument is unused), no cap, no
    # de-duplication; chrregnum is ignored. (The self-aliasing branch in the decompile is STL push_back.)
```

### 5.3 Changes during the session

```pseudo
# card registration: 0xC408 → DB 0xC409 → 0xC40A err 0x2B90 → InvenCellReleaser_CardRegist (Z07 §7)
sp_NC_COLLECT_CARDREGIST_REQ (Z07 §7)                                     @ FUN_00628560
    after sending 0xC409: title = g_CollectCardTitle.cd_Find(card item InxName)      # FUN_00628110 (§2.5); may be null
    lock the cell: InventoryCellLockList::icl_CardRegist(lockindex, cell, inven, inven, &req, title)   @ FUN_00488b60
        lock entry: releaser = icll_Releaser_CardRegist, +0x14 CardID, +0x18 Serial, +0x1c Star, +0x20 slot (Inven & 0x3ff),
            +0x24 title ? title.Type (CHARACTER_TITLE_TYPE) : 0x80 MAX_CHARACTER_TITLE_TYPE
        list full: assert "…icl_CardOpen : List Full" (copy-pasted text), no lock
InvenCellReleaser_CardRegist::icr_Apply(p, cell, …)                         @ FUN_0048b700
    clear the cell (InvenCellReleaser_CellClear::icr_Apply: the card item leaves the inventory)
    p ← 0xC40B NC_COLLECT_CARDREGIST_ACK { u8 invenslot = slot, u16 CardID, u8 Star, u32 Serial, u16 err = 0x2B90 }  (12 bytes)
    p.vt[0xc0c] so_ply_CardRegist(CardID, Serial, Star, title type)

ShinePlayer::so_ply_CardRegist(u16 CardID, u32 Serial, int Star, CHARACTER_TITLE_TYPE t)        @ FUN_00629c10
    e = first album entry with e.CardID == CardID
    if e: e.SerialNumber = Serial; e.StarNumber = Star          # RegistTime kept; a lower star replaces a higher one
    else: push_back { RegistTime = ?, SerialNumber, CardID, StarNumber }
        # RegistTime is uninitialised stack memory (original bug) Z28-B1
    if t != 0x80: sp_CharacterTitle.TitleSetValue(t, 1)          # CCharacterTitleZone, Z18 §6.2 (title progress)

# bookmark: 0xC40C → DB 0xC40D → 0xC40E err 0x2BA0 (Z07 §7)
ShinePlayer::so_ply_CardBookmarkRegist(PROTO_NC_COLLECT_BOOKMARK_REGIST_ACK* a)   @ FUN_00629d30  (vt 0xc10)
    e = first bookmark with e.Slot == a.BookMarkSlot
    if e: a.CardID == 0xFFFF ? erase e (order kept) : e.CardID = a.CardID
    else: push_back { a.BookMarkSlot, a.CardID }
        # also when a.CardID == 0xFFFF: clearing an empty slot appends a {slot, 0xFFFF} entry (original bug) Z28-B2
```

Registering the same card again (any star) overwrites the zone's album entry. The 0xC408 handler does not compare stars
(Z07 §7); the DB does the same (`usp_Collection_setCard` upserts the new serial and star, D03 §12). The zone checks no
bookmark slot range; the DB stores the slot as u8 (D03 §12).

The rewarded list is never changed after login: `sp_NC_COLLECT_REWARD_DB_ACK` FUN_00627a40 does not add the ID (Z07 §7
"possible original bug"; tagged in Z07's scope, not repeated here).

### 5.4 Reward request: which table columns are used

`sp_NC_COLLECT_REWARD_REQ` FUN_00628ef0 (Z07 §7) reads the `CollectCardReward` row found by
`cd_Find(RewardID, item InxName)` FUN_00628060 only through `cca_IsRewardCondition` (`CC_CardRewardType`,
`CC_CardLot`). The new item is `iti_mkregnum(RewardItem, 0xb, zoneNo, worldNo)` plus the item class's default
attributes `iac_itemcreate(RewardItem, &item, "-o")` (vt 0x14, the option string at DAT_006a6d74). The request goes to
the Character DB (`sock2gameDB`) as 0xC411, length 0x79. `CC_RewardLot` (+0x48) is read by no function (no member access
in the PDB export), so the reward is always one item with class-default attributes (original bug) Z28-B4, latent: every
2016 row has `CC_RewardLot` 1. The item ID is the client's `RewardItem`. It must match the row's `CC_RewardItemInx`
(that is the `cd_Find` key), so the client can only choose among the rows of one ID (IDs 8 and 9, §3.5).
