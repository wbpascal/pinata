# Zone: skill data box loader (Z20)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (Zone; the four zone exes are identical). Code is read in the
PDB export: `python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …` (same addresses as
`re-data/exports/zone`). All function, member, enum and struct names are from the NA2016 `Zone.pdb` of the same build
*(pdb2016)*; names of ours are marked. Format arguments that Ghidra drops were read in the disassembly
(`objdump -d --start-address=…` on the exe). Table facts ("2016 data") come from `tools/protocol-re/shn.py` over
`Files/Server/2016/9Data/Shine/*.shn`.

What this item covers: how the zone turns the five active-skill tables into the `SkillDataBox::SkillDataIndex` array
everything else uses (`g_SkillData` / `SkillDataBox_Find` in Z03, `skilldatabox[…]` in Z09/Z11), and the passive
skills in `PassiveDataBox` (§6). Loader position in the start sequence: Z01 §2.3 (stage *wide*), Z10 §7
(`zs_start_wide`, after `dic_abstate` (home) and `bmpdatabox`); run-time reload: Z11 §8.6 (`&reloaddata ActiveSkill`).

## 1. SkillDataBox: data structures

### 1.1 Globals

| Global | Type | Meaning |
|---|---|---|
| `skilldatabox` (DAT_13286828, Z03's `g_SkillData`) | `SkillDataBox` (0x4e0) | the active skills |
| `skillnametree` | `BTree` | skill `InxName` → `SkillBTreeUnion` (shared by active and passive skills, §5.2) |
| `passivedatabox` | `PassiveDataBox` | the passive skills (§6) |
| `roe_physical`, `roe_magical`, `roe_always`, `roe_cure` | `RulesOfEngagement…Skill` / `…AlwaysHit` objects | damage rule per `SkillHitType` (§3.1 step 4); the rules themselves are Z03 |

`_dynamic_initializer_for_'skilldatabox'` FUN_00698ef0 runs the `sdb_BinData` constructor, sets
`sdb_ValidArray = null` and registers `_dynamic_atexit_destructor_for_'skilldatabox'` FUN_0069f1e0, which at exit
destroys the index array (vector-delete with the element count stored in the 4 bytes before it, §1.3) and then
`sdb_BinData` (FUN_00585680). The other members (`sdb_MaxValid`, `sdb_SpecSkill`, …) stay zero (static storage)
until `sdb_Load`.

### 1.2 `SkillDataBox` and `sdb_BinData`

```
class SkillDataBox {                                   // 0x4e0
  0x000 sdb_BinData {                                  // 0x4c4, ctor FUN_00585520, dtor FUN_00585680
          0x000 BinaryDataBox<ActiveSkillInfo>       info        // ActiveSkill.shn
          0x2e0 ActiveSkillInfoServerData             server      // ActiveSkillInfoServer.shn (class derived from
                                                                  //   BinaryDataBox<ActiveSkillInfoServer>, own vftable)
          0x370 BinaryDataBox<AreaSkill>              area_skill  // AreaSkill.shn
          0x3f8 BinaryDataBox<ActiveSkillGroup>       SkillGroup  // ActiveSkillGroup.shn
          0x45c BinaryDataBox<ToggleSkill>            ToggleInfo  // ToggleSkill.shn
        }
  0x4c4 ulong sdb_ActivSkillNum     // = ActiveSkill row count
  0x4c8 ulong sdb_MaxSkillHandle    // = max(ActiveSkillInfoServer.ID) + 1; not read by the loader itself
  0x4cc SkillDataIndex* sdb_ValidArray   // new[sdb_MaxValid], sorted by ID after load
  0x4d0 ulong sdb_MaxValid          // = ActiveSkillInfoServer row count = number of SkillDataIndex
  0x4d4 SpecialSkill sdb_SpecSkill  // 6 × u16 skill IDs, §3.1 step 9
}
```

`BinaryDataBox<T>` = `BinaryData` (= `CDataReader`, 0x40: `m_pHead` at +0x34, `m_pDataArray` at +0x3c) + `T
bdb_defaultblock` at +0x40. The record accessor used everywhere is `i < m_pHead->nNumOfRecord ? GetRecord(i) :
&bdb_defaultblock`; `CDataReader` itself (read, decrypt, row index, checksum) is S02 / W05 §3.1 and S01 §6. The
constructor FUN_00585520 builds the five readers (`BinaryData` ctor) and zeroes each default block
(`memset 0x29f`, `0x4e`, `0x46`; `ActiveSkillGroup` = 32 × `'\0'` + `NONE`; `ToggleSkill` = 32 × `'\0'`,
`TS_HPRATEOFF`, 0). The destructor FUN_00585680 runs the five `BinaryData` destructors in reverse order. The
`BinaryDataBox<…>` scalar-deleting destructors FUN_005853c0 / FUN_005853f0 / FUN_00585420 / FUN_00585450 /
FUN_00585480 and plain destructors FUN_00585020 / FUN_005850e0 / FUN_005851a0 only reset the vftable and call the
`BinaryData` destructor (the boxes are members, never deleted on their own).

### 1.3 `SkillDataIndex` (one per active skill, 0x268)

```
struct SkillDataBox::SkillDataIndex {                  // ctor FUN_00447e30, dtor FUN_00447e50
  0x000 ActiveSkillInfoServer* sdi_ServInf             // row i of ActiveSkillInfoServer.shn
  0x004 ActiveSkillInfo*       sdi_Activ               // row i of ActiveSkill.shn (sort key: sdi_Activ->ID)
  0x008 vector<ActiveSkillGroup*> sdi_ActiveSkillGroups   // {first, last, end}; rows of ActiveSkillGroup.shn
  0x018 vector<ToggleSkill*>      sdi_ToggleData          // rows of ToggleSkill.shn
  0x028 vector<AreaSkillInfo>     sdi_Area                // one per matching AreaSkill.shn row
  0x038 SkillDataIndex* sdi_PrevSkill                  // skill named in DemandSk (previous step), or null
  0x03c SkillDataIndex* sdi_NextSkill                  // the (last) skill whose DemandSk names this one, or null
  0x040 { ABSTATEINDEX abstateidx; int strength; int sucrate } sdi_Abstate[4]   // StaName/StaStrength/StaSucRate A–D
  0x070 RulesOfEngagement* sdi_DamageRule              // from ActiveSkillInfoServer.SkillHitType
  0x074 ulong sdi_AttackDist                           // Range + max(Range·10/100, 50)
  0x078 … 0x260  EnumStruct sdi_<SPECIAL> × 62         // { uchar exist; int value } (8 bytes), §4
}
struct AreaSkillInfo {                                 // 0x44
  0x00 uchar AreaStep; 0x01 char BMPIndex[32]; 0x24 ImagePinType EffectTarget; 0x28 uchar bIsDirection;
  0x2c int AreaCenter_X, AreaCenter_Y, AreaSize, AreaSize_X, AreaSize_Y; 0x40 uchar** AreaBMP   // copy of BMPInfo
}
struct SpecialSkill { u16 ss_PortionProductMain, ss_ScrollProductMain, ss_StoneProductMain,
                      ss_ResolveProductMain, ss_CompoundProductMain, ss_SummonMate }        // 0xc
union SkillBTreeUnion { struct { u16 skill; u8 ispassive; } skillstr; ulong skillbin; }      // 4 bytes
```

The constructor zeroes the three vectors only; every other member is set by `sdb_Load` (§3.1 steps 3–5). The
destructor frees the three vector buffers (the pointed-to rows belong to the readers). The array is allocated with
`new[]`: one `u32` element count, then `sdb_MaxValid` elements constructed by `_eh_vector_constructor_iterator_`.

## 2. Tables and column → member maps

### 2.1 Files and readers

All five are read with the checked `CDataReader::Read(path, key, rowSize)` (FUN_0062a9e0: `HEAD.nVersionKey == key`
and `HEAD.nFieldSize − 2 == rowSize`) through one `bdb_ReadData` per row type:

| File (`../9Data/Shine/`) | Row struct | Reader | key (`DataVersionKey`) | row size | rows 2016 |
|---|---|---|---|---|---|
| ActiveSkill.shn | `ActiveSkillInfo` | `BinaryDataBox<ActiveSkillInfo>::bdb_ReadData` FUN_00585030 | 0x15153 (86355) | 0x29f | 2791 |
| ActiveSkillInfoServer.shn | `ActiveSkillInfoServer` | `BinaryDataBox<ActiveSkillInfoServer>::bdb_ReadData` FUN_00584f70 | 0x410 (1040) | 0x4e | 2791 |
| ActiveSkillGroup.shn | `ActiveSkillGroup` | FUN_00648d50 (PDB name `BinaryDataBox<CollectCardMobGroup>::bdb_ReadData`: identical-code folding; the body checks 0x12 / 0x24, the `ActiveSkillGroup` key and size) | 0x12 (18) | 0x24 | 2198 |
| ToggleSkill.shn | `ToggleSkill` | `BinaryDataBox<ToggleSkill>::bdb_ReadData` FUN_005851b0 | 0x1d (29) | 0x26 | 6 |
| AreaSkill.shn | `AreaSkill` | `BinaryDataBox<AreaSkill>::bdb_ReadData` FUN_005850f0 | 0x98 (152) | 0x46 | 92 |

(`BinaryDataBox<PassiveSkillInfo>::bdb_ReadData` FUN_00585260, key 0x20f4 / size 0xfe, is the passive reader, §6.)
All 2016 files pass (keys and sizes = `docs/knowledge/S01-shn-structs.tsv`, row counts by `shn.py`). There is no
per-world override: the paths are fixed.

```pseudo
BinaryDataBox<T>::bdb_ReadData(this, path) → this             @ FUN_00585030, FUN_00584f70, FUN_00648d50, FUN_005851b0, FUN_005850f0
    if CDataReader::Read(this, path, KEY_T, sizeof T): return this               # FUN_0062a9e0
    AssertFail "BinaryDataBox<T>::bdb_ReadData : readfail", path                  # log only (FUN_0063c710)
    AssertFail sprintf("Code:%X:%d\tSHN:%X:%d", KEY_T, KEY_T, m_pHead->nVersionKey, m_pHead->nVersionKey)
        # (args read in the disassembly) the row size is never printed, so a size mismatch shows two equal keys;
        # when the file could not be opened at first load m_pHead is still null and this read faults before
        # ShineExit (original bug) Z20-B1
    ShineExit("BinaryDataBox<T>::bdb_ReadData")                                   # process ends
```

### 2.2 Column → member maps

`shn.py` column names equal the PDB member names, in order, for all five tables (S01 "columns_vs_members: same"), so
the rows are used as stored: each SHN row (after its 2-byte length) *is* the packed struct. Offsets below are struct
offsets; "Loader" = what `sdb_Load` does with the column; columns without an entry are only read at run time (Z03,
Z07, Z09, Z12).

**ActiveSkill.shn → `ActiveSkillInfo` (0x29f, packed)**

| Off | Column (type) | Loader |
|---|---|---|
| 0x000 | ID (u16) | sort / lookup key of the index; must equal server row ID ("SkillID Unsync") |
| 0x002 | InxName (char[32]) | must be a prefix-equal of the server InxName ("Index not match"); key of the area-skill match; DlyGroupNum check |
| 0x022 | Name (char[64]) | `"…[NN]"` suffix drives the step checks (§3.2) |
| 0x062 / 0x066 / 0x06a | Grade, Step, MaxStep (u32) | Step: checked against the name suffix |
| 0x06e | DemandType (`WeaponDemandType`) | – |
| 0x072 | DemandSk (char[32]) | `"-"` = none; else skill name → `sdi_PrevSkill` (fatal if unknown) |
| 0x092 … 0x09e | UseItem (u16), ItemNumber, ItemOption (u32), DemandItem1, DemandItem2 (u16) | – |
| 0x0a0 | SP (u32) | step check (must not decrease) |
| 0x0a4 … 0x0b0 | SPRate, HP, HPRate, LP (u32) | – |
| 0x0b4 | Range (u32) | `sdi_AttackDist = Range + max(Range·10/100, 50)` |
| 0x0b8 / 0x0bc | First, Last (`TargetType`) | – |
| 0x0c0 | IsMovingSkill (u8) | – |
| 0x0c1 / 0x0c3 / 0x0c5 | UsableDegree, DirectionRotate, SkillDegree (u16) | – |
| 0x0c7 | SkillTargetState (`TargetState`) | – |
| 0x0cb / 0x0cf | CastTime, DlyTime (u32) | – |
| 0x0d3 | DlyGroupNum (u32) | DlyGroupNum check (ID < 9000 only) |
| 0x0d7 | DlyTimeGroup (u32) | – |
| 0x0db … 0x0ff | MinWC, MinWCRate, MaxWC, MaxWCRate, MinMA, MinMARate, MaxMA, MaxMARate, AC, MR (u32) | – |
| 0x103 / 0x107 | Area, TargetNumber (u32) | – |
| 0x10b | UseClass (`UseClassType`) | – |
| 0x10f / 0x12f / 0x133 | StaNameA (char[32]), StaStrengthA, StaSucRateA (u32) | → `sdi_Abstate[0]` {abstate index by name, strength, sucrate}; name `"-"` = none, unknown name fatal |
| 0x137 / 0x157 / 0x15b | StaNameB, StaStrengthB, StaSucRateB | → `sdi_Abstate[1]` |
| 0x15f / 0x17f / 0x183 | StaNameC, StaStrengthC, StaSucRateC | → `sdi_Abstate[2]` |
| 0x187 / 0x1a7 / 0x1ab | StaNameD, StaStrengthD, StaSucRateD | → `sdi_Abstate[3]` |
| 0x1af | nIMPT (u32[4]; SHN type 22, one named + 3 unnamed columns) | – |
| 0x1bf / 0x1d3 / 0x1e7 / 0x1fb | nT0, nT1, nT2, nT3 (u32[5] each, type 22) | sanity checks "Power", "SP", "Delay Time", "Cool Time" (§3.2) |
| 0x20f | EffectType (`SkillEffectType`) | – |
| 0x213 … 0x237 | SpecialIndexA/ValueA … SpecialIndexE/ValueE (`SkillSpecial` + u32, ×5) | `sdi_SetArgument(index, value)` in order A–E (§4) |
| 0x23b / 0x25b / 0x27b | SkillClassifierA/B/C (char[32]) | – |
| 0x29b / 0x29c | CannotInside, DemandSoul (u8) | – |
| 0x29d | HitID (u16) | – |

**ActiveSkillInfoServer.shn → `ActiveSkillInfoServer` (0x4e)**: ID (u16, 0x00), InxName (char[32], 0x02),
UsualAttack (u8, 0x22), SkilPyHitRate, SkilMaHitRate, PsySucRate, MagSucRate (u32, 0x23–0x2f), StaLevel (u8, 0x33),
DmgIncRate (u32, 0x34), DmgIncValue (u16, 0x38), **SkillHitType** (`SkillHitTp`, 0x3a → `sdi_DamageRule`, §3.1
step 4), ItremUseSkill (u8, 0x3e), AggroPerDamage, AbsoluteAggro (u32, 0x3f / 0x43), AttackStart, AttackEnd (u8,
0x47 / 0x48), SwingTime, HitTime (u16, 0x49 / 0x4b), AddSoul (u8, 0x4d). The loader reads ID, InxName and
SkillHitType; the row count defines `sdb_MaxValid`.

**ActiveSkillGroup.shn → `ActiveSkillGroup` (0x24)**: InxName (char[32]) = skill name → the row is appended to that
skill's `sdi_ActiveSkillGroups`; ActiveSkillGroupIndex (`ActiveSkillGroupIndex` enum, 0 NONE … 118 SunLight, 119 MAX)
is kept in the row.

**ToggleSkill.shn → `ToggleSkill` (0x26)**: TS_SkillInx (char[32]) = skill name → appended to `sdi_ToggleData`;
TS_Condition (`ToggleSkillEnum`, only `TS_HPRATEOFF` = 0), TS_Value (u16). 2016 data: `BurnPain01`–`06`, all
`TS_HPRATEOFF`, 50.

**AreaSkill.shn → `AreaSkill` (0x46)** → one `AreaSkillInfo` in `sdi_Area` of the first skill whose
`ActiveSkillInfo.InxName` equals AS_SkillInx (`_mbsncmp`, 32 bytes): AS_SkillInx (char[32]), AS_Step (u8 →
`AreaStep`), AS_BMPIndex (char[32] → `BMPIndex`, looked up in `bmpdatabox`), AS_ImagePin (`ImagePinType` IPT_ME 0 /
IPT_TARGET 1 / IPT_SPOT 2 → `EffectTarget`), AS_IsDirection (u8 → `bIsDirection`).

## 3. `SkillDataBox::sdb_Load`

### 3.1 Pseudocode

`sdb_Load(this, Name4* unused)`: the parameter is never read (startup passes the world name *(inferred)*,
`&reloaddata` passes NULL). Every failure below is `AssertFail <text>` (log only) followed by `ShineExit(<name>)`
(process exit) unless marked *non-fatal*.

```pseudo
SkillDataBox::sdb_Load(this, _)                                         @ FUN_00585f40
  # 1. read the five tables (§2.1; any failure ends the process)
  info.bdb_ReadData("../9Data/Shine/ActiveSkill.shn")                    @ FUN_00585030
  server.bdb_ReadData("../9Data/Shine/ActiveSkillInfoServer.shn")        @ FUN_00584f70
  SkillGroup.bdb_ReadData("../9Data/Shine/ActiveSkillGroup.shn")          @ FUN_00648d50
  ToggleInfo.bdb_ReadData("../9Data/Shine/ToggleSkill.shn")               @ FUN_005851b0
  area_skill.bdb_ReadData("../9Data/Shine/AreaSkill.shn")                 @ FUN_005850f0

  # 2. size the index array from the SERVER table
  sdb_MaxValid = server.nNumOfRecord
  if sdb_MaxValid == 0: fatal "SkillDataBox::sdb_Load : Error in record number" (prints the old sdb_MaxSkillHandle)
  sdb_MaxSkillHandle = max(server row i .ID) + 1
  if sdb_ValidArray: delete[] sdb_ValidArray (dtor per element)          # &reloaddata: Z11-B37, §3.3
  sdb_ValidArray = new SkillDataIndex[sdb_MaxValid]                      # ctor FUN_00447e30
  if null: fatal "SkillDataBox::sdb_Load : Memory leak"
  sdb_ActivSkillNum = info.nNumOfRecord

  # 3. pair server rows with the index, pick the damage rule
  for i in 0 .. sdb_MaxValid-1:
      e = sdb_ValidArray[i]
      e.sdi_ServInf = server row i;  e.sdi_Activ = null;  e.sdi_ActiveSkillGroups.clear()
      e.sdi_NextSkill = e.sdi_PrevSkill = null
      if e.sdi_ServInf == null: fatal "SkillDataBox::sdb_Load : No server data"     # cannot happen (default block)
      e.sdi_DamageRule = by e.sdi_ServInf.SkillHitType:
          0 SHT_FROM_PY_NORMAL_HITRATE → &roe_physical      1 SHT_FROM_MA_NORMAL_HITRATE → &roe_magical
          2 SHT_ALWAYHIT, 5 SHT_MANABURN → &roe_always       3 SHT_CURE, 4 SHT_DISPEL → &roe_cure
          other → fatal "SkillDataBox::sdb_Load"
      # (sdi_ToggleData and sdi_Area are not cleared here; on a fresh array they are empty from the ctor)

  # 4. both tables must have the same rows in the same order
  if sdb_ActivSkillNum != server.nNumOfRecord:
      AssertFail "SkillDataBox::sdb_Load : Number mismatch"
      for i in 0 .. sdb_MaxValid-1:                                       # info rows past its end = default block (ID 0)
          if info[i].ID != server[i].ID: AssertFail "Error in", info[i].ID, server[i].ID; ShineExit
      ShineExit("SkillDataBox::sdb_Load")                                # always, even when every ID matched
  for i in 0 .. sdb_MaxValid-1:
      a = info[i];  s = server[i];  e = sdb_ValidArray[i]
      for each char c at k of a.InxName until its NUL:                   # a.InxName "" skips the check
          if s.InxName[k] != c: fatal "SkillDataBox::sdb_Load : Index not match", a.ID, s.ID
          # only a prefix test: a server name that continues past a.InxName passes (original bug) Z20-B2
      e.sdi_Activ = a
      if a.ID != s.ID: fatal "SkillID Unsync"
      e.sdi_AttackDist = a.Range + max(a.Range * 10 / 100, 50)            # integer division
      SkillDataIndex::sdi_Clear(e)                                        @ FUN_00584500 (§4)
      for X in A, B, C, D, E:  SkillDataIndex::sdi_SetArgument(e, a.SpecialIndexX, a.SpecialValueX)   @ FUN_00584800 (§4)

  # 5. abnormal states and the name tree
  for i in 0 .. sdb_MaxValid-1:
      e = sdb_ValidArray[i];  a = e.sdi_Activ
      for k, X in (0,A), (1,B), (2,C), (3,D):                            # inlined sdb_load_IndexSearch / sdi_SetAbstate
          id = BTree::operator[](dic_abstate.as_BTreeID, a.StaNameX)      @ FUN_0063cc30
          if id == 0xFFFFFFFF: idx = MAX_ABSTATEINDEX
          else:
              st = AbnormalStateDictionary::AbState::as_FromID(dic_abstate, (u16)id)
              if st == null: fatal "SkillDataBox::sdb_load_IndexSearch : Search error", a.StaNameX
              idx = st.index.AbStataIndex
          e.sdi_Abstate[k] = { abstateidx = idx, strength = a.StaStrengthX, sucrate = a.StaSucRateX }
          if a.StaNameX[0] != '-' and idx == MAX_ABSTATEINDEX:
              AssertFail "SkillDataBox::SkillDataIndex::sdi_SetAbstate : StateName wrong", a.StaNameX
              AssertFail (same text), a.ID;  ShineExit("SkillDataBox::SkillDataIndex::sdi_SetAbstate")
          # a name that only starts with '-' (e.g. "-x") is also "none"
      BTree::bt_Insert(skillnametree, e.sdi_ServInf.InxName, {skill = e.sdi_ServInf.ID, ispassive = 0})   @ FUN_0063cba0

  # 6. sort by ID (lookups are binary searches from here on)
  qsort(sdb_ValidArray, sdb_MaxValid, 0x268, sdb_compare)                @ FUN_005844e0: a.sdi_Activ.ID − b.sdi_Activ.ID

  # 7. group and toggle rows (unknown names are logged and skipped, non-fatal)
  for each row g of ActiveSkillGroup.shn (file order):
      id = skillnametree[g.InxName]                                       # inlined GetSkillIndexByName (§5.1)
      if id == 0xFFFFFFFF: AssertFail "SkillDataBox::GetSkillIndexByName : Invalid Skill", g.InxName;  continue
      e = SkillDataBox::operator[](this, (u16)id)                          @ FUN_00448140
      if e: e.sdi_ActiveSkillGroups.push_back(&g)
  for each row t of ToggleSkill.shn: same with t.TS_SkillInx → e.sdi_ToggleData.push_back(&t)

  # 8. step chain (DemandSk)
  for i in 0 .. sdb_MaxValid-1:  (sorted order)
      e = sdb_ValidArray[i]
      if e.sdi_Activ == null: fatal "Null skll", i
      if e.sdi_Activ.DemandSk[0] == '-': e.sdi_PrevSkill = null
      else:
          id = skillnametree[DemandSk];  id == 0xFFFFFFFF → fatal "SkillDataBox::sdb_Load : Invalid Prestep", DemandSk
          e.sdi_PrevSkill = operator[](id);  null → fatal (same text)
          e.sdi_PrevSkill.sdi_NextSkill = e          # several skills with the same DemandSk: the highest ID wins

  # 9. special skills (sdb_MakeSpecialSkill, inlined): each name must exist
  for (member, name) in (ss_PortionProductMain, "ProducePotion"), (ss_ScrollProductMain, "ProduceScroll"),
                        (ss_StoneProductMain, "ProduceSton"), (ss_ResolveProductMain, "ProduceResolve"),
                        (ss_CompoundProductMain, "ProduceCompound"), (ss_SummonMate, "SummonMate01"):
      id = skillnametree[name];  id == 0xFFFFFFFF → fatal "SkillDataBox::sdb_MakeSpecialSkill : Invalid Skill", name
      sdb_SpecSkill.member = (u16)id

  # 10. area skills
  n = area_skill.nNumOfRecord
  if n > sdb_MaxValid: fatal "SkillDataBox::sdb_Load : too many area_skill num", n
  for each row r of AreaSkill.shn (file order):
      if r == null: fatal "SkillDataBox::sdb_Load : undefined error - data get error", 0
      j = first index with _mbsncmp(r.AS_SkillInx, sdb_ValidArray[j].sdi_Activ.InxName, 32) == 0   # linear scan
      none: continue                                                      # row silently dropped
      bmp = BmpDataBox::bdb_GetBmpDataInfo(bmpdatabox, r.AS_BMPIndex)
      if null: fatal "… data get error", 1
      bi = BmpDataInfo::bdi_GetBmpInfo(bmp)                                @ FUN_00450350 (PDB public name
                                        #   so_ShineMobileObject: folded with a `return this` accessor)
      if null: fatal "… data get error", 1
      sdb_ValidArray[j].sdi_Area.push_back({ AreaStep = r.AS_Step, BMPIndex = r.AS_BMPIndex (_mbsnbcpy 32),
          EffectTarget = r.AS_ImagePin, bIsDirection = r.AS_IsDirection, AreaCenter_X … AreaBMP = *bi (6 dwords) })

  # 11. data sanity warnings (§3.2), all non-fatal except the "Null skll" check
```

### 3.2 Sanity warnings

After the index is built, `sdb_Load` checks the tables and writes each finding with
`sprintf` + `_DebugMessageNew(1, "Msg", "%s", text)` FUN_0064f3c0 → `_DebugMessageNew2` FUN_0064f1f0. That helper
(enabled when its first argument ≠ 0) formats the text, increments `gDebugMessageCounter`, and appends
`"%06d %s%s\n"` (counter, current time string, text) to `.\DebugMessage\Msg_<YYYY-MM-DD>.txt` (directory created
with `MakeSureDirectoryPathExists`; argument order read in the disassembly). Nothing is sent and the load continues.
All loops run over the sorted array; "step name" = `Name` ending in `]`, step number = `atoi(Name + len − 3)`
(assumes a two-digit `"[NN]"` suffix); "same skill line" = `Name[0 .. len−4)` equals the next element's.

| Check (in order) | Condition for a warning | Text (arguments read in the disassembly) |
|---|---|---|
| step number | step name and `atoi(suffix) ≠ Step` | `Skill Name : <InxName>(<Name>) : Invalid Step(<Step>)` |
| delay groups | only skills with ID < 9000; per `DlyGroupNum` the first skill (sorted) is the reference; a later one whose `InxName` without its last 2 chars is not a prefix of the reference | `Skill Name : <ref InxName> Vs <InxName>(<Name>) : Invalid DlyGroupNum(<n>)` |
| DemandSk | step name, step > 1 and `DemandSk ≠ InxName` of the previous array element (`strncmp` 32) | `Skill Name : <InxName>(<Name>) : Invalid DemandSk(<DemandSk>)` |
| SP along a line | step name, same line as the next element, next `SP` < this `SP` | `Skill Name : <InxName>(<Name>) : Invalid SP(<i>-<SP>, <i+1>-<next SP>)` |
| nT0 … nT3, inside a row | for k = 0..3: `nTx[k] ≠ 0` and `nTx[k+1] < nTx[k]` | `Skill Name : <InxName> : Invalid Power / SP / Delay Time / Cool Time(<k>-<v>, <k+1>-<v>)` (nT0 / nT1 / nT2 / nT3) |
| nT0 … nT3, along a line | same line as the next element, `this.nTx[k] ≠ 0` and `next.nTx[k] < this.nTx[k]` | `Skill Name : <InxName>(<Name>) : Invalid Power / SP / Delay Time / Cool Time(…)` |

The delay-group check builds a temporary table of `max(DlyGroupNum)+1` 33-byte strings (`malloc`, freed at the end).
The last loop also re-checks `sdi_Activ == null` → AssertFail "Null skll" + `exit(0)` (not `ShineExit`).

The DemandSk check reads element i−1 also for i = 0, and the two "same line" checks read element i+1 also for the
last element, outside the array (original bug) Z20-B3; with the 2016 data neither fires (the lowest ID 0 is
`"Slice and Dice [01]"`, step 1; the highest ID 60000 has a name without `]`).

2016 data: 1544 step names, 49 delay-group warnings (my reproduction of the rule), about 24 step-number warnings.

### 3.3 Invariants a rebuild needs (with the 2016 data)

- **Row pairing.** ActiveSkill.shn and ActiveSkillInfoServer.shn must have the same row count, the same ID in every
  row position and (prefix-)equal InxNames, else the process exits. 2016: 2791 rows each, all pairs equal.
- **IDs.** Any u16; the file need not be sorted (2016 is not: `qsort` sorts). IDs 0 … 60000; 1268 skills have
  ID ≥ 9000 (monster / system skills *(inferred)*; only the delay-group check treats them differently). Duplicate
  IDs are not detected (original bug) Z20-B4: 2016 has ID 9034 twice (`KQRoboAtkSk2` row 1549, `GoMasterAtkSkill2`
  row 1609). Both names map to 9034 in `skillnametree`, and `operator[]`'s `bsearch` returns one of the two equal
  elements (which one depends on `qsort`'s order), so one row is never used.
- **Names.** `skillnametree` is a case-sensitive trie (§5.2); a later insert of the same name overwrites the
  earlier one. 2016 active `InxName`s are unique and disjoint from the passive ones, but 156 IDs are used by both an
  active and a passive skill, so name lookups must keep the `ispassive` flag apart.
- **Rows dropped / tolerated.**
  - ActiveSkillGroup rows naming no skill: logged ("Invalid Skill"), skipped. 2016: 47 rows (`SnearKick07`–`16`,
    `SnearShout…`, `Dash…`, `HawkTalon…`, `Neglect…`, `Sacrifice…`, `ShiningPurge…`, one Korean name).
  - AreaSkill rows naming no skill: dropped without a log line. 2016: 22 rows (`SW_{F,I,S,T}Focalor_Skill05_N` × 5,
    `KDFargels_DKnight_Skill01_W`, `…02_W`). A skill can have several area rows (10 skills in 2016, up to 5:
    `DT_IFocalor_Skill04_W`), kept in file order; `sdb_GetAreaSkillInfo` (§5.1) picks the first with a given step.
  - ToggleSkill rows naming no skill: logged, skipped (none in 2016).
- **Fatal on bad data.** Unknown abnormal-state name (except `-…`), unknown DemandSk, a `SkillHitType` > 5, missing
  special skill names, an AreaSkill BMP missing from `bmpdatabox`, more AreaSkill rows than skills, invalid
  `SS_SETABSTATEFRIEND` / `SS_SETABSTATEME` / `SS_DISPELABSTATE` abstate IDs (§4). 2016 passes all of them.
- **Step chain.** `sdi_PrevSkill` is set for every DemandSk; `sdi_NextSkill` holds one successor only. 2016:
  `PowerHit09` is the DemandSk of 3 skills and `ThunderBolt04` of 2; the one with the highest ID is their
  `sdi_NextSkill` (the loop runs in ID order).
- **Unknown ID.** `operator[]` returns null for an ID that has no row (no default block); callers must test it.
- **Reload (`&reloaddata`, Z11 §8.6).** `sdb_Load` deletes the old `SkillDataIndex` array before building the new
  one, so every `SkillDataIndex*` kept elsewhere dangles (Z11-B37; the holders are listed in §7, part 2). The
  readers re-read their files into the same buffers when the new file is not larger (W05 §3.1 `CDataReader::Read`),
  so `ActiveSkillInfo*` / `ActiveSkillInfoServer*` row pointers kept elsewhere then point at whatever row now lies at
  that offset; a larger file frees the old buffer. `skillnametree` is never cleared: names removed from the files
  keep resolving to their old ID. `sdb_SpecSkill` is rewritten.

## 4. `sdi_Clear` and `sdi_SetArgument`: the special-effect members

```pseudo
SkillDataBox::SkillDataIndex::sdi_Clear(e)                                @ FUN_00584500
    for each of the 62 EnumStruct members sdi_HEALAMOUNT … sdi_RANDOMTARGETSPOT: { exist = 0, value = 0 }
        # writes exist as a dword whose upper 3 bytes are uninitialised stack bytes (struct padding, never read)

SkillDataBox::SkillDataIndex::sdi_SetArgument(e, SkillSpecial index, int value)   @ FUN_00584800
    member = MAP[index]  (table below); none: return (ignored)
    member.exist = 1;  member.value = value
    SS_DASH2 additionally: sdi_WARPING.value = value   (sdi_WARPING.exist is left as it was)
    SS_SETABSTATEFRIEND / SS_SETABSTATEME / SS_DISPELABSTATE:
        if as_FromID(dic_abstate, (u16)value) == null:
            fatal "SkillDataIndex::sdi_SetArgument : SS_SETABSTATEFRIEND invalid abstate"
                / "… : sdi_SETABSTATEME invalid abstate" / "… : SS_DISPELABSTATE invalid abstate"
```

Called five times per skill (SpecialIndexA … E with their values), after `sdi_Clear`: a later slot with the same
index overwrites the earlier value.

| `SkillSpecial` (value) | Member | `SkillSpecial` (value) | Member |
|---|---|---|---|
| SS_HEALAMOUNT (1) | sdi_HEALAMOUNT | SS_DISPELDEEPER (35) | sdi_DISPELDEEPER |
| SS_CURE (2) | sdi_CURE | SS_DASH (36) | **sdi_WARPING** (shared with 25) |
| SS_DISPEL (3) | sdi_DISPEL | SS_DASH2 (38) | sdi_WARPING_TARGET (+ sdi_WARPING.value) |
| SS_TELEPORT (4) | sdi_TELEPORT | SS_CURSETIMEADD (40) | sdi_CURSETIMEADD |
| SS_WHOLEHEALAMOUNT (5) | sdi_WHOLEHEALAMOUNT | SS_FIRETIMEADD (41) | sdi_FIRETIMEADD |
| SS_MANABURN (6) | sdi_MANABURN | SS_HOLDME (42) | sdi_HOLDME |
| SS_UNDEADTODMG (7) | sdi_UNDEADTODMG | SS_JWALK (43) | sdi_JWALK |
| SS_DISPELALL (8) | sdi_DISPELALL | SS_POSIONTIMEADD (44) | sdi_POSIONTIMEADD |
| SS_DISPELONE (9) | sdi_DISPELONE | SS_SHOOTME (45) | sdi_SHOOTME |
| SS_THHPUP (10) | sdi_THHPUP | SS_DMGCOLLTIMEDOWN (46) | sdi_DMGCOLLTIMEDOWN |
| SS_DIEHPUP (11) | sdi_DIEHPUP | SS_AREATYPE (47) | sdi_AREATYPE |
| SS_REVIVAL (12) | sdi_REVIVAL | SS_BOMBDISPELALL (48) | sdi_BOMBDISPELALL |
| SS_MAGICFIELD_TICK (13) | sdi_MAGICFIELD_TICK | SS_MAGICFIELDPARTY (49) | sdi_MAGICFIELD_PARTY |
| SS_MAGICFIELD_KEEP (14) | sdi_MAGICFIELD_KEEP | SS_HEALFRIENDRATE (50) | sdi_HEALFRIENDRATE |
| SS_STEALENCHANT (15) | sdi_STEALENCHANT | SS_SETABSTATEFRIEND (51) | sdi_SETABSTATEFRIEND (abstate checked) |
| SS_HPCONVERTSP (16) | sdi_HPCONVERTSP | SS_RANDOMTARGETNUMBER (52) | sdi_RANDOMTARGETNUMBER |
| SS_HPUPRATE (17) | sdi_HPUPRATE | SS_NEXTTARGETAREA (53) | sdi_NEXTTARGETAREA |
| SS_FLYDURINGCAST (18) | sdi_FLYDURINGCAST | SS_DMGDOWNRATE (54) | sdi_DMGDOWNRATE |
| SS_SILVERWING (19) | sdi_SILVERWING | SS_MAXDMGDOWNRATE (55) | sdi_MAXDMGDOWNRATE |
| SS_DISPELDEBUFF (20) | sdi_DISPELDEBUFF | SS_SHOTSPEED (56) | sdi_SHOTSPEED |
| SS_DISPELCURSE (21) | sdi_DISPELCURSE | SS_TARGETHPDOWNDMGUPRATE (57) | sdi_TARGETHPDOWNDMGUPRATE |
| SS_DISPELPOISON (22) | sdi_DISPELPOISON | SS_JUMP (58) | sdi_JUMP |
| SS_DISPELDISEASE (23) | sdi_DISPELDISEASE | SS_SETABSTATEME (59) | sdi_SETABSTATEME (abstate checked) |
| SS_WHOLEAGGRORATE (24) | sdi_WHOLEAGGRORATE | SS_NOTTARGET (60) | sdi_NOTTARGET |
| SS_WARPING (25) | sdi_WARPING | SS_ABKEEPTIME (61) | sdi_ABKEEPTIME |
| SS_DISPELRANDOM (26) | sdi_DISPELRANDOM | SS_TOPAGGRONO (62) | sdi_TOPAGGRONO |
| SS_DETECT (27) | sdi_DETECT | SS_RANDOMTARGET (63) | sdi_RANDOMTARGET |
| SS_WHOLEAGGRORANGE (28) | sdi_WHOLEAGGRORANGE | SS_MAGICFIELD_DELAY_START_TIME (64) | sdi_MAGICFIELD_DELAY_START_TIME |
| SS_CROSSCOUNTER (34) | sdi_CROSSCOUNTER | SS_DISPELABSTATE (65) | sdi_DISPELABSTATE (abstate checked) |
| | | SS_BMP_MAGICFIELD_ROTATIONSPEED_RIGHT (66) | sdi_BMP_MAGICFIELD_ROTATIONSPEED_RIGHT |
| | | SS_RECALL (70) / SS_DMGSHARE (71) / SS_SUCKHP (72) / SS_RANDOMTARGETSPOT (73) | sdi_RECALL / sdi_DMGSHARE / sdi_SUCKHP / sdi_RANDOMTARGETSPOT |

**Ignored by `sdi_SetArgument`** (no member): SS_NONE 0, SS_HIDE 29, SS_Silience 30, SS_MESMERIZE 31, SS_SUMMON 32,
SS_METAMORPHOSIS 33, SS_DISPELBUFF 37, SS_HPRATE 39, SS_MOVE_CHR 67, SS_HIDE_CHR_START 68, SS_HIDE_CHR_END 69. These
skills keep their index in `sdi_Activ->SpecialIndexX` only; any code using them reads the row directly *(inferred;
readers are Z03 / Z09)*. 2016 data uses all of them except SS_Silience (slot counts: SS_SUMMON 42,
SS_MOVE_CHR / SS_HIDE_CHR_START / SS_HIDE_CHR_END 22 each, SS_HIDE, SS_MESMERIZE, SS_METAMORPHOSIS, SS_HPRATE 1
each, SS_DISPELBUFF 2). The member `sdi_THHPUP` etc. names come from the PDB; what each effect does is Z03.

## 5. Lookups

### 5.1 By ID and name

```pseudo
SkillDataBox::operator[](this, u16 id) → SkillDataIndex* or null          @ FUN_00448140 (Z03 `SkillDataBox_Find`)
    key = a SkillDataIndex on the stack whose sdi_Activ points at a stack ActiveSkillInfo with ID = id
    return bsearch(&key, sdb_ValidArray, sdb_MaxValid, 0x268, sdb_compare)       # null when no row has that ID
    # the stack key's three vectors are freed afterwards (they stay empty)

SkillDataBox::sdb_compare(a, b) = a.sdi_Activ.ID − b.sdi_Activ.ID          @ FUN_005844e0   (qsort / bsearch)

SkillDataBox::GetSkillIndexByName(this, name) → SkillDataIndex* or null    @ FUN_00585ef0
    id = BTree::operator[](skillnametree, name)
    if id == 0xFFFFFFFF: AssertFail "SkillDataBox::GetSkillIndexByName : Invalid Skill", name; return null
    return operator[](this, (u16)id)
        # the ispassive byte is dropped: a passive skill's name returns the ACTIVE skill with the same ID number
        # (or null); 156 IDs exist in both tables in 2016. Latent: the tables its callers read (MoverUseSkill.shn, GuildTournamentSkill.shn)
        # name no passive skill in 2016 *(inferred: caller arguments not traced)*; the inlined copies in sdb_Load §3.1 steps 7–9 do the same (original bug) Z20-B5
        # callers: MoverSkillList::msl_Store FUN_00449190, GuildTournamentSystem::CreateItemEffect FUN_0047c1e0

SkillDataBox::sdb_GetAreaSkillInfo(this, e, u8 step) → AreaSkillInfo* or null   @ FUN_00585730
    e == null: null
    return the first element of e.sdi_Area with AreaStep == step, else null

SkillDataBox::sdb_SpecSkillStruct(this) = &sdb_SpecSkill                    @ FUN_0046a410
    # callers: ShinePlayer::so_RecalcLastParam FUN_004cb570, sp_NC_ITEM_USE_ACTIVESKILL_REQ FUN_00540b90,
    #          ShineMobileObject::so_Routine FUN_0056a080 (Z03 / Z07 / Z13)
```

Iteration over all skills (`SkillDataBox::sdb_Next` FUN_0050ffd0 / `sdb_Get` FUN_0050fff0, Z11 §9.3) walks
`sdb_ValidArray` in ID order.

### 5.2 `skillnametree` (`BTree`)

```pseudo
BTree::bt_Insert(node, uchar* key, ulong value) → 1, or 0 when out of memory     @ FUN_0063cba0 (char* wrapper FUN_0063cc70)
    for each byte b of key: node = node.bt_subtree[b] (new 0x404-byte node {bt_id = 0xFFFFFFFF, 256 null children} if absent)
    node.bt_id = value                     # overwrites an existing entry
BTree::operator[](node, uchar* key) → value or 0xFFFFFFFF                          @ FUN_0063cc30 (recursive char* form FUN_0063cc80)
    follow the bytes; a missing child → 0xFFFFFFFF; at the end → node.bt_id (0xFFFFFFFF if only a prefix of other keys)
```

A 256-way trie: exact, case-sensitive byte match, no removal. The value is a `SkillBTreeUnion`: active skills
`{skill = ID, ispassive = 0}` (§3.1 step 5), passive skills `{ID, 1}` (§6). The same `BTree` type is the abstate
name index (`dic_abstate.as_BTreeID`).

## 6. PassiveDataBox

*(part 2: `PassiveDataBox` ctor FUN_00585790, `pdb_Load` FUN_005858d0, `sdb_GetSetAbstate` FUN_00584f20,
`sdb_SpecSkillStruct` FUN_0059ebe0, accessors; PassiveSkill.shn / PSkillSetAbstate.shn column maps)*

## 7. Holders of `SkillDataIndex*`

*(part 2: the objects that keep `SkillDataIndex*` past a call, settling Z11-B37's holder list)*

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z20-B1 | `BinaryDataBox<T>::bdb_ReadData` (5 skill readers, §2.1) | on a failed read the second log line dereferences `m_pHead`, which is still null when the file could not be opened at startup; the row-size check result is never printed | missing file: access violation instead of the `ShineExit` line; row-size mismatch: the log shows two equal keys | print only when `m_pHead` is set; include expected/actual row size |
| Z20-B2 | `sdb_Load` "Index not match" (§3.1 step 4) | compares ActiveSkill `InxName` only up to its own NUL against the server row's | a server row whose `InxName` is longer (or an empty ActiveSkill name) passes | compare both names fully (`strcmp`) |
| Z20-B3 | `sdb_Load` warnings (§3.2) | DemandSk check reads element −1 for i = 0; "same line" SP / nT checks read element `sdb_MaxValid` for the last skill | heap read outside the array when the lowest-ID skill has a step > 1 name or the highest-ID skill has a step name; a crash or a bogus warning at load (not with 2016 data) | skip i = 0 / the last element |
| Z20-B4 | `sdb_Load` (§3.3) | duplicate skill IDs are not detected | 2016: ID 9034 (`KQRoboAtkSk2`, `GoMasterAtkSkill2`): both names resolve to the same one of the two rows, the other is never used | reject duplicates at load |
| Z20-B5 | `GetSkillIndexByName` (§5.1) | casts the `skillnametree` value to `u16`, dropping `ispassive` | latent: a passive skill's name would yield the active skill with the same ID (156 shared IDs in 2016) or null | refuse entries with `ispassive = 1` |

## 8. Not reconstructed / uncertain

- `SS_DASH2` sets `sdi_WARPING_TARGET` and copies the value into `sdi_WARPING.value` without setting
  `sdi_WARPING.exist`; whether the copy is meant for code that reads `sdi_WARPING.value` after testing
  `sdi_WARPING_TARGET.exist` depends on the readers (Z03); not classified as a bug.
- Which of the two ID-9034 rows `bsearch` returns (MSVC `qsort` order of equal keys) was not simulated.
- The per-world parameter of `sdb_Load` (`Name4*`) is unused; whether startup passes a world name or NULL was not
  read (Z10 §7 shows only the call).
- The 49 delay-group / 24 step-number warnings are my reproduction of the rules over the 2016 data, not a run of
  the server.

## 9. Coverage boundary

*(sweep part)*
