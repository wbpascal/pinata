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
until `sdb_Load`. `_dynamic_initializer_for_'skillnametree'` FUN_00698f30 constructs the empty trie (`BTree::BTree`) and
registers `_dynamic_atexit_destructor_for_'skillnametree'` FUN_0069f150 (`BTree::~BTree`); the trie is never cleared
in between, so `&reloaddata ActiveSkill` re-inserts every name over the old entries (§5.2).

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
  0x4c4 ulong sdb_ActivSkillNum     // = ActiveSkill row count; read only by sdb_Load's own row-count check
  0x4c8 ulong sdb_MaxSkillHandle    // = max(ActiveSkillInfoServer.ID) + 1; no reader outside sdb_Load (only
                                    //   its "Error in record number" message prints the old value)
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
`BinaryData` destructor (the boxes are members, never deleted on their own). `ActiveSkillInfoServerData`'s own
destructor FUN_00585510 does the same for the `server` member; only the exception-unwind funclets of the
`sdb_BinData` ctor / dtor call it (the normal dtor path is inlined in FUN_00585680).

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
    AssertFail "BinaryDataBox<T>::bdb_ReadData : readfail", path                  # log only (FUN_0063c710: when
        #   ac_Write2File, appends "<text> : AssertClass::ac_AssertFail : <msg>[<n>]" to Assert<YYYYMMDD><hh>.txt;
        #   the file name comes from AssertClass::ac_DateTime FUN_0063c640 *(inferred: the "%02d" is the hour)*)
    AssertFail sprintf("Code:%X:%d\tSHN:%X:%d", KEY_T, KEY_T, m_pHead->nVersionKey, m_pHead->nVersionKey)
        # (args read in the disassembly) the row size is never printed, so a size mismatch shows two equal keys
        # (original bug) Z20-B1; a null m_pHead is tested first (test/je at 0x585071 and in all 7 readers) and
        # prints 0 for both version values, so a missing file still reaches ShineExit
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
is kept in the row (+0x20). The box itself never reads it; the only readers are item actions: the four
`RulesOfEngagementPhisycalSkill` / `RulesOfEngagementMagicalSkill` `roe_CriticalRateByGlobalAction` (FUN_00504d30 /
FUN_00504ee0) and `roe_HitRateByGlobalAction` (FUN_005055a0 / FUN_005058d0) run, for each group row of the attack's
skill, an `AAT_ActiveSkillGroupIndex` condition (subtype = that row's ActiveSkillGroupIndex) through
`ItemActionObserveManager::EventRun` on the attacker's item-action manager (vt 0x5d0) and add the plus value to the
rate; `ItemActionObserveManager::EventRunBySkillGroupIndex` FUN_005d1f50 does the same with effect
`AAT_SkillEffectIncreaseType`. What the conditions and effects do is Z17 (§9).

**ToggleSkill.shn → `ToggleSkill` (0x26)**: TS_SkillInx (char[32]) = skill name → appended to `sdi_ToggleData`;
TS_Condition (`ToggleSkillEnum`, only `TS_HPRATEOFF` = 0), TS_Value (u16). 2016 data: `BurnPain01`–`06`, all
`TS_HPRATEOFF`, 50.

**AreaSkill.shn → `AreaSkill` (0x46)** → one `AreaSkillInfo` in `sdi_Area` of the first skill whose
`ActiveSkillInfo.InxName` equals AS_SkillInx (`_mbsncmp`, 32 bytes): AS_SkillInx (char[32]), AS_Step (u8 →
`AreaStep`), AS_BMPIndex (char[32] → `BMPIndex`, looked up in `bmpdatabox`), AS_ImagePin (`ImagePinType` IPT_ME 0 /
IPT_TARGET 1 / IPT_SPOT 2 → `EffectTarget`), AS_IsDirection (u8 → `bIsDirection`).

## 3. `SkillDataBox::sdb_Load`

### 3.1 Pseudocode

`sdb_Load(this, Name4* unused)`: the parameter is never read (startup `zs_start_wide` FUN_005ad9a0 passes
`&zoneserver.zs_serverinfo.worldname`, `&reloaddata` passes NULL). Every failure below is `AssertFail <text>` (log only) followed by `ShineExit(<name>)`
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
      # push_back is inlined; on growth it calls vector<AreaSkillInfo>::reserve FUN_00585df0 (capacity × 1.5, at least
      #   size + 1; "vector<T> too long" above 0x3c3c3c3 elements), which allocates through
      #   allocator<AreaSkillInfo>::allocate FUN_00585d50 (0x44 bytes per element, bad_alloc on overflow) and moves
      #   the old elements with _Uninit_move FUN_00585db0 (a 0x44-byte copy each). The 2016 data puts at most a
      #   handful of steps on one skill, so a rebuild can use any growable array.

  # 11. data sanity warnings (§3.2), all non-fatal except the "Null skll" check
```

### 3.2 Sanity warnings

After the index is built, `sdb_Load` checks the tables and writes each finding with
`sprintf` + `_DebugMessageNew(1, "Msg", "%s", text)` FUN_0064f3c0 → `_DebugMessageNew2` FUN_0064f1f0. That helper
(enabled when its first argument ≠ 0) formats the text, increments `gDebugMessageCounter`, and appends
`"%06d %s%s\n"` (counter, current time string from `GetCurrentTimeString(0)` FUN_0064f050 = local time
`"YYYY-MM-DD hh:mm:ss "` in a static buffer, UTC when the argument ≠ 0, text) to `.\DebugMessage\Msg_<YYYY-MM-DD>.txt` (directory created
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

2016 data: 1544 step names, 49 delay-group warnings (my reproduction of the rule), 27 step-number warnings (my reproduction of the rule).

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
  one, so every `SkillDataIndex*` kept elsewhere dangles (Z11-B37; the holders are listed in §7). The
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
        # intended: smo_SkillBash_Blast FUN_0057cd40 tests sdi_WARPING_TARGET.exist, computes the spot next to the
        # target and calls smo_WarpTo FUN_004a7de0, which uses sdi_WARPING.value as the free-cell search radius
        # (so_FindBlockLocate); SS_WARPING / SS_DASH skills test sdi_WARPING.exist (smo_WarpTo / smo_WarpForward
        # FUN_004a83e0, value = forward distance)
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

**Who writes the trie.** `sdb_Load` (actives, `ispassive` 0), `pdb_Load` (passives, 1; startup order: after
`sdb_Load`, §6.3) and, in the same `zs_start_wide` stage after both, `GatherProduce::GatherTable::gt_Load`
FUN_0046a660 (Z02 §8, `Gather.shn`), which inserts every Gather row's `Index` name with the value `GatherID` (u16,
so `ispassive` 0). In 2016 the three Gather names `Herbing` / `Mining` / `WoodCutting` are also active-skill names
with the same IDs 29000 / 29001 / 29002, so the insert rewrites identical values. A rebuild must keep
`Gather.GatherID` equal to the active skill of the same name: a different ID would silently redirect that skill name
for every later lookup (the gather action is cast as that skill *(inferred)*), and a Gather name equal to a passive
name would turn it into an active entry. `&reloaddata ActiveSkill` re-runs only `sdb_Load` (§3.1), so after a reload
the active entries win again over Gather until the next start.

**Who reads it** (every `&skillnametree` reference of the zone; all treat the value as `{u16 skill, u8 ispassive}`):

| Reader | Key | Unknown name (0xFFFFFFFF) | `ispassive` |
|---|---|---|---|
| `GetSkillIndexByName` FUN_00585ef0, sdb_Load / pdb_Load internals | §5.1, §3.1, §6.3 | as described there | dropped (Z20-B5, B7) |
| `UsedItemEffect::uie_UseSkillID` FUN_0059cba0 (item use-effect table, §7) | effect skill name | assert "Not found", null | ≠ 0: assert "Passive", null; then `operator[]`, null → assert "Skill" |
| `UseItemSkillScroll::uib_CanUseItem` FUN_0059d1b0 / `uib_Effect` FUN_00599d30 | the scroll item's own `InxName` | assert "sp_uie_skillscroll : Cannot found matched skill", nothing sent | kept: `uib_Effect` sends Character DB 0x4801 NC_SKILL_SKILLTEACH_REQ (0x11 bytes) {handle, charNo (vt 0x344) twice, skill, ispassive, 0xFFFF}; layout and reply: D04 §2 / Z03 §9.3 |
| `CharaterSkillList::csl_Learn` FUN_0055b810, `csl_PreSkillCheck` FUN_00447110 | `DemandSk` of the skill | not checked: `csl_IsLearn(0xFFFF)` (false unless an entry has ID 0xFFFF) | ignored |
| `CharacterPassiveList::cpl_PreSkillCheck` FUN_00445810 | `DemandSk` | not checked (Z20-B8) | ignored |
| `ShineMobileObject::so_Routine` FUN_0056a080 | `"UseRide"`, once, cached in DAT_00869290 | 0xFFFF cached | ignored |
| `MiscDataTable::mdt_StateCondition` FUN_004a3550, `mdt_SkillBufferAlloc` FUN_004a3d90, `mdt_SkillBreedMob` FUN_004a6880, `MobAttackSequence::mas_Load` FUN_004a8990 / `SkillChange::sc_Store` FUN_004a8520, `NPCAction::ActionGen_OptionReader::operator()` FUN_005c18c0 / `CondGen_OptionReader::createCondition_` FUN_005c29c0 (load-time tables, Z09) | skill names in their SHN / script rows | fatal (`ShineExit`), except `mdt_StateCondition` (row skipped / list ends) | ignored (low 16 bits) |
| `MobDataBox::mdb_SkillStore` FUN_00642630 (gets the trie as argument from `zs_start_sleep` FUN_005b67c0) | mob weapon skill names | assert "Invalid MobSkill Name", skill 0xFFFF stored | ignored |
| Lua `cNPCSkillUse` FUN_005ef5c0, `cSkillBlast` FUN_005f0960 | script argument | not checked (0xFFFF passed on) | ignored |
| Lua `cSkillDamageCalculate` FUN_005f1370, `cMagicFieldSpread` FUN_005f17c0 | script argument | function does nothing | ignored; then `operator[]` |

```pseudo
CharaterSkillList::csl_Learn(this, u16 skill)          @ FUN_0055b810
    # only caller: ShinePlayer::so_LearnSkill FUN_0055bbf0 = csl_Learn(p.sp_SkillList, skill), then sets bit 0 of
    #   sp_CharData.toclient.basedata.flags; it is ShinePlayer vtable slot 0x624 (rtti.py), the p.vt[0x624](skillid)
    #   of the 0x4802 answer (Z03 §9.3)
    e = skilldatabox[skill]; null: AssertFail "… csl_Learn … NotFind Skill ID", skill; return
    end = clockwatch.cw_CurrTick; save = 0
    if e.sdi_Activ.DemandSk[0] ≠ '-':                                  # step > 1 of a skill line
        prev = skillnametree[DemandSk].skill                            # no 0xFFFFFFFF check
        if csl_IsLearn(prev): c = csl_GetSkillStruct(prev); end = c.cs_EndOfCooltime; save = c.cs_bSave
    csl_Skill.push_back(CharSkill {      # vector<CharSkill>::push_back FUN_00447cc0 cs_SkillId = skill, cs_EndOfCooltime = end, cs_bSave = save,
                                    cs_Empower = {0,0,0,0}, cs_Mastery = 0 })        # 0x14 bytes
    csl_SkillNumber += 1
    sort csl_Skill by CharSkill::cs_Compare_STLVer (std::_Sort FUN_004476d0)                    # ascending skill ID (csl_IsLearn binary-searches it)
    csl_Toggle_Store(skill)                                             # FUN_00448c60 (Z21)
```

The new step inherits the cooldown end of the learned previous step (learning a step does not reset a running
cooldown); the previous step stays in the list.

## 6. PassiveDataBox

Passive skills get no index structure: the zone uses the `PassiveSkillInfo` rows of PassiveSkill.shn directly,
through an ID-indexed pointer array. PSkillSetAbstate.shn adds "passive sets an abnormal state on a condition" rows.
Loaded once at startup (`zs_start_wide` FUN_005ad9a0, right after `sdb_Load`); there is no reload path
(`pdb_Load` has no other caller).

### 6.1 Data structures

```
class PassiveDataBox {                                  // 0x1e4, global passivedatabox
  0x000 PassiveSkillInfo* pdb_default                   // = &pdb_databox.bdb_defaultblock (set by the ctor)
  0x004 BinaryDataBox<PassiveSkillInfo> pdb_databox     // PassiveSkill.shn (row 0xfe), default block at +0x40
  0x144 PassiveSkillInfo** pdb_index                    // new[pdb_maxpassiveID]; [id] = row, or the default block
  0x148 int pdb_passivenumber                           // = PassiveSkill row count
  0x14c int pdb_maxpassiveID                            // = max(ID) + 1 = length of pdb_index
  0x150 SpecialSkill sdb_SpecSkill { u16 ss_PowerOfLove }   // ID of "PowerofLove01"
  0x154 BinaryDataBox<PSkillSetAbstate> pdb_SetAbstateDataBox   // PSkillSetAbstate.shn (row 0x47)
  0x1dc int pdb_nMaxPSkillSetAbstateNum                 // = PSkillSetAbstate row count
  0x1e0 PSSetAbstateIndex* pdb_pPSkillSetAbstate        // new[pdb_nMaxPSkillSetAbstateNum], one per row
}
struct PassiveDataBox::PSSetAbstateIndex {              // 0x10
  0x0 u16 pssabs_nID                                    // passive skill ID of the row's PS_InxName
  0x4 PSkillSetAbstate* pssabs_pPSkillSetAbstate        // the row
  0x8 PSSetAbstateIndex* pssabs_Prev                    // entry of the passive named in this passive's DemandSk
  0xc PSSetAbstateIndex* pssabs_Next                    // entry whose Prev is this one (last writer wins)
}
```

```pseudo
_dynamic_initializer_for_'passivedatabox'                               @ FUN_00698f10
    PassiveDataBox::PassiveDataBox(&passivedatabox); atexit(FUN_0069f160)
PassiveDataBox::PassiveDataBox(this)                                    @ FUN_00585790
    construct both readers (BinaryData ctor), vftables BinaryDataBox<PassiveSkillInfo> / <PSkillSetAbstate>
    memset(pdb_databox.bdb_defaultblock, 0, 0xfe); memset(pdb_SetAbstateDataBox.bdb_defaultblock, 0, 0x47)
    pdb_default = &pdb_databox.bdb_defaultblock
    default.ID = 0xFFFF
    default.MstRt{Sword1, Hammer1, Sword2, Axe2, Mace1, Bow2, CrossBow2, Wand2, Staff2} = 1000
        # MstRtClaw, MstRtDSword stay 0; CastingTime stays 0 (cpl_RecalcParam's neutral value is 1000, §6.5)
        # (original bug) Z20-B10
    (the other default members are written 0 again); pdb_index = null; pdb_nMaxPSkillSetAbstateNum = 0;
    pdb_pPSkillSetAbstate = null       # pdb_passivenumber / pdb_maxpassiveID: static zero until pdb_Load
_dynamic_atexit_destructor_for_'passivedatabox'                         @ FUN_0069f160
    delete[] pdb_pPSkillSetAbstate (if set); destroy pdb_SetAbstateDataBox, then pdb_databox (BinaryData dtor)
    # pdb_index is never freed (process exit)
```

The `BinaryDataBox<PassiveSkillInfo>` destructors FUN_00585250 (plain) / FUN_005854b0 (scalar-deleting) and
`BinaryDataBox<PSkillSetAbstate>` scalar-deleting destructor FUN_005854e0 only reset the vftable and run the
`BinaryData` destructor, like the active-skill boxes (§1.2).

### 6.2 Tables and column → member map

| File | Reader | Row | Rows (2016) | Map |
|---|---|---|---|---|
| `../9Data/Shine/PassiveSkill.shn` | `BinaryDataBox<PassiveSkillInfo>::bdb_ReadData` FUN_00585260 | 0xfe | 503 | 48 columns = the 48 `PassiveSkillInfo` members, same names, order and offsets (checked against `shn.py`) |
| `../9Data/Shine/PSkillSetAbstate.shn` | `BinaryDataBox<PSkillSetAbstate>::bdb_ReadData` FUN_00585310 | 0x47 | 16 | 5 columns = the 5 `PSkillSetAbstate` members, same names, order and offsets |

Both readers are the same template as the active-skill readers (§2.1): `CDataReader::Read(this, path, key, rowsize)`
with key 0x20f4 (PassiveSkill) / 0xa9 (PSkillSetAbstate); on failure `AssertFail "BinaryDataBox<T>::bdb_ReadData :
readfail" <path>`, the `"Code:%X:%d\tSHN:%X:%d"` line (row size not printed, Z20-B1; null `m_pHead` printed as 0) and
`ShineExit("BinaryDataBox<T>::bdb_ReadData")`.

Because the rows are used as they are, the column meaning is defined by the readers (§6.5 for the details):

| Column (PassiveSkillInfo member) | Type | Read by | Meaning |
|---|---|---|---|
| ID | u16 | pdb_Load, every lookup | passive skill ID; index into `pdb_index` and into the player's 1000-bit `cpl_Passive` |
| InxName | char[32] | pdb_Load (`skillnametree`, ispassive 1), class-change code (`itemdatabox.idb_btree` lookup) | unique name |
| Name | char[32] | – (not read by the loader or the readers below) | display name |
| WeaponMastery | u32 | cpl_RecalcParam | ≠ 0: the row is a weapon mastery (Mst* columns apply to the equipped weapon) |
| DemandSk | char[32] | pdb_Load (set-abstate chain), cpl_PreSkillCheck (scroll use) | prerequisite passive `InxName`, `-` = none |
| MstRtTmp, MstPlTmp | u32 | – | zeroed by pdb_Load for every row; the "no mastery" slot of the `pmv` table |
| MstRt<Weapon> (11 columns) | u32 | cpl_RecalcParam | weapon damage rate bonus in ‰ (Rate = value + 1000) for that weapon class |
| MstPl<Weapon> (11 columns) | u32 | cpl_RecalcParam | flat weapon damage bonus |
| SPRecover, TB, MaxSP, MaxLP, Intel | u32 | cpl_RecalcParam | Plus.SPRecover / TB / MaxSP / MaxLP / Int |
| CastingTime | u32 | cpl_RecalcParam | Rate.CastingTime (1000 = neutral) |
| MACriRate | u16 | cpl_RecalcParam | Rate.MagCriDamRate |
| WCRateUp, MARateUp | u32 | cpl_RecalcParam | Rate.WCmin/WCmax, Rate.MAmin/MAmax = value + 1000 |
| HpDownDamegeUp, DownDamegeHp | u16 | cpl_RecalcParam | WC/MA min/max rate + HpDownDamegeUp while HP ≤ DownDamegeHp (both ≠ 0) |
| HpDownAcUp, DownAcHp | u16 | cpl_RecalcParam | AC/MR rate + HpDownAcUp while HP ≤ DownAcHp (both ≠ 0) |
| MoveTBUpPlus | u16 | cpl_RecalcParam | moving TB plus (condition 1000) |
| HealUPRate, KeepTimeBuffUPRate, CriDmgUpRate, DMG_MinusRate | u16 | cpl_RecalcParam | PassiveHealRate, PassiveBuffKeepTimeUPRate, PassiveCriDamageRatePlus, DMGMinusRate |
| ActiveSkillGroupInx | `ActiveSkillGroupIndex` (u32) | – (no reader: none of the zone's passive-row readers, §6.4 / §6.5, reads +0xf8) | 2016: 0 in 495 rows, 98 / 99 in 4 each; a rebuild can ignore it |

PSkillSetAbstate.shn: `PS_InxName` char[32] (passive `InxName`), `PS_Condition` `PS_ConditionEnum`
(PS_CBOWATKRATEKNOCKBACK 0, PS_SKILLSPUSEDOWN 1, PS_AREAENEMYSPDOWN 2, PS_MEDMGMISSCRIUPRATE 3), `PS_ConditioRate`
u16 (chance in ‰), `PS_AbStateInx` char[32] (abstate name, `dic_abstate.as_FromName`), `Strength` u8 (abstate
strength).

### 6.3 `PassiveDataBox::pdb_Load`

```pseudo
PassiveDataBox::pdb_Load(this, Name4* unused)                          @ FUN_005858d0
  # parameter never read; zs_start_wide passes &zoneserver.zs_serverinfo.worldname
  pdb_databox.bdb_ReadData("../9Data/Shine/PassiveSkill.shn")              @ FUN_00585260
  pdb_SetAbstateDataBox.bdb_ReadData("../9Data/Shine/PSkillSetAbstate.shn") @ FUN_00585310
  # 1. ID index
  pdb_passivenumber = PassiveSkill row count
  pdb_maxpassiveID = max(row.ID) + 1          # 0 + 1 = 1 for an empty table
  pdb_index = new PassiveSkillInfo*[pdb_maxpassiveID]
      null: fatal "PassiveDataBox::pdb_Load : Fail to alloc memory"
  every slot = &pdb_databox.bdb_defaultblock
  for each row i:
      if pdb_index[row.ID] ≠ default block: fatal "PassiveDataBox::pdb_Load : Dublicate id" (prints ID)
      pdb_index[row.ID] = row;  row.MstPlTmp = 0;  row.MstRtTmp = 0      # writes into the reader's buffer
      bt_Insert(skillnametree, row.InxName, {skill = row.ID, ispassive = 1})   # §5.2; overwrites an equal name
  # 2. special skill
  v = skillnametree[“PowerofLove01”]
      0xFFFFFFFF: fatal "PassiveDataBox::sdb_MakeSpecialSkill : Invalid Skill" "PowerofLove01"
  sdb_SpecSkill.ss_PowerOfLove = (u16) v       # ispassive not checked (original bug) Z20-B7
  # 3. set-abstate index
  pdb_nMaxPSkillSetAbstateNum = PSkillSetAbstate row count
  pdb_pPSkillSetAbstate = new PSSetAbstateIndex[n]     # NOT initialised
      null: fatal "PassiveDataBox::pdb_Load : Fail to alloc memory"
  for k in 0 … n−1 (row r_k):
      v = skillnametree[r_k.PS_InxName]
          0xFFFFFFFF: fatal "PassiveDataBox::sdb_MakeSpecialSkill : Invalid Skill" <PS_InxName>
      if (u16)v == 0xFFFF or (v & 0xFFFF) ≥ pdb_maxpassiveID: skip (entry k stays uninitialised) (original bug) Z20-B6
      e_k = { pssabs_nID = (u16)v, pssabs_pPSkillSetAbstate = r_k, Prev = null, Next = null }
      d = pdb_index[(u16)v].DemandSk           # (u16)v may be an ACTIVE skill's ID (Z20-B7)
      if d ≠ "-":
          w = skillnametree[d]
              0xFFFFFFFF: fatal "PassiveDataBox::sdb_MakeSpecialSkill : Invalid Skill" <d>
          j = the first entry (0 … n−1, including later, not yet written ones) with pssabs_nID == (u16)w
          found: e_k.Prev = &e_j;  e_j.Next = &e_k
          # not found: Prev stays null (no message)
```

The fatal messages say `sdb_MakeSpecialSkill`: the set-abstate step reuses the special-skill error text (the
function `PassiveDataBox::sdb_MakeSpecialSkill` exists only as these strings, inlined here).

### 6.4 Lookups and iteration

```pseudo
passive row by ID (inlined in every reader: cpl_RecalcParam, uib_CanUseItem FUN_0059d1b0, …)
    id < pdb_maxpassiveID ? pdb_index[id] : pdb_default        # an unknown ID gives the default block (ID 0xFFFF)

PassiveDataBox::sdb_Home(this, int* i): *i = −1                          @ FUN_0050ffc0
PassiveDataBox::sdb_Next(this, int* i): return ++*i < pdb_passivenumber  @ FUN_00584f00
PassiveDataBox::sdb_Get(this, int* i) → PassiveSkillInfo*                @ FUN_00585d10
    *i ≥ pdb_passivenumber: pdb_default;  else row *i (file order, not ID order)
    # callers: ac_AllLearnSKill FUN_004212e0 (Z11), sp_NC_ITEM_CLASS_CHANGE_REQ FUN_0051f5c0,
    #          sp_OpenClassChangeMenu FUN_0051fd10
    # FUN_0050ffc0 is a shared body (identical-code folding): sp_NC_ITEM_MOVER_UPGRADE_REQ FUN_0051c850 and
    #          sp_Gamble_UseCoinItem FUN_006174e0 call it as another class's "set to −1"

PassiveDataBox::sdb_GetSetAbstate(this, u16 id) → PSSetAbstateIndex* or null   @ FUN_00584f20
    linear scan of all pdb_nMaxPSkillSetAbstateNum entries (uninitialised ones included, Z20-B6); first with
    pssabs_nID == id                     # a passive with two PSkillSetAbstate rows: only the first is ever used
    # caller: CharacterPassiveList::cpl_StoreSetAbstateList FUN_00447340

PassiveDataBox::sdb_SpecSkillStruct(this) = &sdb_SpecSkill               @ FUN_0059ebe0
    # caller: ShinePlayer::so_RecalcLastParam FUN_004cb570 (knows ss_PowerOfLove: four parameters +0x32)
    # ss_PowerOfLove read directly: so_ply_DivorceProcess FUN_0059f550, gds_NC_CHAR_WEDDING_DO_ACK FUN_005a1830
```

`std::_List_val<PSSetAbstateIndex*>::_Buynode` FUN_00446430 is the node allocator of `cpl_SetAbstateList`
(`new` 0xc {next, prev, value}; `bad_alloc` on failure).

### 6.5 The per-player side: `CharacterPassiveList`

`ShinePlayer::sp_Passive` is a `CharacterPassiveList` (0x18): `BitSet cpl_Passive` (1000 bits, ctor FUN_00447200)
and `std::list<PSSetAbstateIndex*> cpl_SetAbstateList` (dtor FUN_004472c0 frees all nodes, then the BitSet). It holds
only IDs and pointers into `passivedatabox.pdb_pPSkillSetAbstate`, so passive IDs must stay below 1000. Who fills it
(`so_charpassivedata` FUN_0044e5a0 from the Character DB, learning, unlearning) is Z12 / Z03; the functions that touch the
PassiveDataBox:

```pseudo
CharacterPassiveList::cpl_Store(this, PROTO_NC_CHAR_SKILL_PASSIVE_CMD* p, Name5 char)   @ FUN_00447aa0
    for each u16 id in p (count p.number):          # from so_charpassivedata FUN_0044e5a0
        id ≥ 1000: AssertFail "CharacterPassiveList::cpl_Store : Invalid passive" id (char name in namestring); next
        set bit id (if id < bs_maxbit); cpl_StoreSetAbstateList(id)
CharacterPassiveList::psl_Store(this, u16 id, Name5 char)               @ FUN_00447810   (so_LearnPassive FUN_00559e50)
    id ≥ 1000: same assert; return
    set bit id; cpl_StoreSetAbstateList(id)
    player = som_FindPlayer(char); if found: for the cpl_SetAbstateList entries with PS_Condition == PS_AREAENEMYSPDOWN (2):
        same roll-and-apply as cpl_SetAbstate below, target = caster = the player (inlined copy)
CharacterPassiveList::cpl_StoreSetAbstateList(this, u16 id)             @ FUN_00447340
    e = passivedatabox.sdb_GetSetAbstate(id); null: return
    if e.pssabs_Prev: remove the first list node whose entry's pssabs_nID == e.pssabs_Prev.pssabs_nID
        # replaces the previous level of the same passive; the scan stops early at a node with a null value
    append e
CharacterPassiveList::cpl_UnLearn(this, u16 id)                         @ FUN_0057b4d0   (so_UnlearnSkillAck FUN_0057f200)
    id > 999: AssertFail "CharacterPassiveList::cpl_Store : Invalid passive" id   (continues)
    if bit id is set (read before the bound check) and id < bs_maxbit: clear bit id   (original bug) Z20-B8
    # cpl_SetAbstateList is not touched: the passive's set-abstate entry stays (original bug) Z20-B9
CharacterPassiveList::cpl_IsLearn(this, u16 id) = bit id                @ FUN_004193b0   (no bound check)
CharacterPassiveList::cpl_PreSkillCheck(this, player, char* demand) → bool   @ FUN_00445810
    demand[0] == '-': true
    v = skillnametree[demand]                  # not checked for 0xFFFFFFFF nor ispassive (original bug) Z20-B8
    bit (v & 0xFFFF) set: true;  else player.vt[0x91c/4](0x70c, 9, …) (error message to the player, Z03/Z07); false
CharacterPassiveList::cpl_SetAbstate(this, PS_ConditionEnum c, caster, target, u8 flag, ulong)   @ FUN_00446a10
    # via ShinePlayer::so_ply_PassiveSetAbstate(c, target, flag, x) FUN_005798e0 = cpl_SetAbstate(p.sp_Passive, c,
    #   caster = p, target, flag, x); vtable slot 0xbf8 (rtti.py), so only players react; trigger table below
    caster, target non-null, list non-empty, c < 4, else return
    for each entry e in list order (stops at a null value):
        row = e.pssabs_pPSkillSetAbstate; null: AssertFail "… : INVALID PSkillSetAbstate Data" e.pssabs_nID; stop
        row.PS_Condition ≠ c: next
        c gate: 0 PS_CBOWATKRATEKNOCKBACK needs flag and the caster's weapon (vt[0x7ac/4]) to be WT_CROSSBOW;
                1, 2: none; 3 PS_MEDMGMISSCRIUPRATE needs flag; gate fails: return
        if rb_1000() < row.PS_ConditioRate:
            a = dic_abstate.as_FromName(row.PS_AbStateInx); null / no index: AssertFail "… : INVALID Abstate (Index) Data"; stop
            target.vt[0x634/4](a) == 1 (already has it): stop
            target.vt[0x644/4](caster, a.index.AbStataIndex, row.Strength, 1); next entry
        else stop                              # only entries up to the first failed roll are tried
    # trigger sites of vt 0xbf8 (all the calls in the zone):
    #   c 0 PS_CBOWATKRATEKNOCKBACK, target = the hit object, flag = hit:
    #       ShineMobileObject::smo_SwingDamage FUN_00432f30 (normal attack, flag 1),
    #       SkillDamageSender::sds_TemplateStore FUN_005803c0 (skill damage, flag = isdamage)
    #   c 3 PS_MEDMGMISSCRIUPRATE, target = the attacker itself, flag = missed: the same two sites, right after c 0
    #   c 1 PS_SKILLSPUSEDOWN, target = the caster: SkillBlastEffect::sbe_BlastObject FUN_00583bc0 /
    #       sbe_BlastLocate FUN_00584160, after the caster's skill-use call (vt 0xee0)
    #   c 2 PS_AREAENEMYSPDOWN, target = the player: sp_NC_MAP_LOGINCOMPLETE_CMD FUN_00443390 (once per map login;
    #       psl_Store applies the same condition when the passive is learned)
CharacterPassiveList::cpl_RecalcParam(this, Container* param, ItemBag* bag)   @ FUN_00445940
    # via ShinePlayer::so_RecalcPassiveParam FUN_004cb4a0 (resets the passive plus/rate block first)
    weapon = item ID in equipment slot 12, or slot 10 if empty (0xFFFF) *(inferred: slot meaning)*
    for id in 0 … 999 with bit id set:
        r = passive row by ID (§6.4; unknown → default block)
        if r.WeaponMastery ≠ 0 and weapon < idb_maxItemhandle and idb_index[weapon].data ≠ null:
          if idb_index[weapon].data->ID ≠ weapon:
            AssertFail "ItemDataBox::operator [] :Invalid Item index", (bit id * 10000 + data->ID)  # log only;
            # no mastery from this row *(the multiplier is the loop variable as decompiled)*
          else:
            rateCol = pmv.pmv_var[TwoHand & 1][0][WeaponType]; plusCol = pmv.pmv_var[TwoHand & 1][1][WeaponType]
                  (WeaponType ≥ 22: pmv_var[1][0][0] / [1][1][0]; table below)
              staff / wand: Plus.MagicalWeaponMastery = r[plusCol] (if ≠ 0); Rate.MagicalWeaponMastery = r[rateCol] + 1000 (if ≠ 0)
              else:         Plus/Rate.PhisycalWeaponMastery the same way
        each other column as in §6.2, assigned only when ≠ 0 (CastingTime: when ≠ 1000)
        # assignments, not sums: for each member the highest learned ID with a non-zero value wins
```

The two HP-condition pairs and `MoveTBUpPlus` are not plain members: `cpl_RecalcParam` passes them to
`Parameter::ChangeByConditionParam::cbcp_SetCondition(param, id, condition, change)` FUN_004c8f10:
HpDownDamegeUp / DownDamegeHp → `PassiveHPDownRateWCMin`, `…WCMax`, `…MAMin`, `…MAMax`; HpDownAcUp / DownAcHp →
`PassiveHPDownRateAC`, `…MR`; MoveTBUpPlus → `PassiveMovingTBPlus` with condition 1000.

```pseudo
ChangeByConditionParam::cbcp_SetCondition(this, u16 id, u32 condition, u32 change)   @ FUN_004c8f10
    cbcp_nID = 0xFFFF; cbcp_nCondition = cbcp_nChange = cbcp_nChangeParam = cbcp_nCharged = 0
    if condition == 0 or change == 0: return                     # cleared
    cbcp_nID = id; cbcp_nCondition = condition; cbcp_nChange = change
    n = ceil(1000 / condition)                                   # loop: count steps of `condition` until 1000 is used up
    if n ≠ cbcp_nMaxValueNum:                                    # u8
        cbcp_nMaxValueNum = n; delete[] cbcp_pValue; cbcp_pValue = new int[n] (all 0)
        null: AssertFail "", 0; return
```

So `condition` is a step in ‰ of the HP rate (or 1000 = one step for the moving-TB bonus) and the object keeps one
value slot per step; how the slots are filled from the current HP (`cbcp_nChangeParam`, `cbcp_nCharged`) is the
stat calculation (Z12). Because `cpl_RecalcParam` assigns, the last learned row with both columns set wins, as for the
plain members.
2016 data: 4 rows each set both HP pairs with condition 50 (‰ steps → 20 slots) and change 10 / 20 / 30 / 40;
`MoveTBUpPlus` is 0 in every row. The slot count is stored in a `u8`: a condition below 4 gives n > 255, which is
truncated (n = 1000 for condition 1 is stored as 232) while the step logic would expect n slots (original bug)
Z20-B11 (latent, not reached with the 2016 data).

`PassiveMasteryVariable` `pmv` (ctor FUN_00444db0, initializer FUN_00695330): `pmv_var[twohand][0 = rate, 1 =
plus][WeaponTypeEnum]` = byte offset of the PassiveSkillInfo column. Every entry not listed is MstRtTmp / MstPlTmp
(zeroed by pdb_Load, so no bonus):

| twohand | Weapon type → Rt / Pl column |
|---|---|
| 0 | WT_SWORD → Sword1, WT_MACE → Mace1, WT_HAMMER → Hammer1, WT_DSWORD → DSword, WT_CLAW → Claw |
| 1 | WT_BOW → Bow2, WT_STAFF → Staff2, WT_AXE → Axe2, WT_CROSSBOW → CrossBow2, WT_WAND → Wand2, WT_DSWORD → DSword, WT_CLAW → Claw, WT_TSWORD → Sword2 (two-handed WT_SWORD → MstPlTmp for both, also no bonus) |

### 6.6 Invariants a rebuild needs (with the 2016 data)

- IDs: unique (duplicate = fatal), 0 … 842 in 2016 (503 rows, 340 unused IDs in the range); must be < 1000 or the
  player list refuses them (`cpl_Store` / `psl_Store`) and `cpl_RecalcParam` never looks at them.
- Unknown IDs (gaps, ≥ `pdb_maxpassiveID`) resolve to the default block, never null (Z20-B10).
- `InxName` shares `skillnametree` with the active skills: passives are inserted after the actives at startup, so a
  name in both tables would resolve to the passive; `&reloaddata ActiveSkill` re-inserts the actives and would flip it
  back. 2016: no name in both tables (156 numeric IDs exist in both, §3.3).
- `PowerofLove01` must exist (2016: ID 400, passive). Every `PS_InxName` and every non-`-` `DemandSk` of a
  set-abstate passive must be a known name (fatal otherwise). 2016: all 16 PSkillSetAbstate rows name passives, no
  name twice, conditions 1 × 8, 2 × 4, 3 × 4; four chains of four levels (MagicDance, DeepFear, Shame, PointAttack)
  whose prerequisite row always comes earlier in the file, so the uninitialised-entry paths of Z20-B6 are not hit.
- All 503 `DemandSk` values are `-` or a passive name. 34 rows (WCMastery01–13, MAMastery01–13, LightMastery01–05,
  BackgroundDefenseG01/J01/S01) have CastingTime 0 instead of the neutral 1000 (§8).

## 7. Holders of `SkillDataIndex*`

Settles the holder list of Z11-B37 (`&reloaddata ActiveSkill` deletes and reallocates `sdb_ValidArray`, §3.1). Found
by scanning every 2016 PDB type for members of type `SkillDataIndex*` / `AreaSkillInfo*` / skill-row pointers, then
every write to those members. No struct outside the two boxes keeps a pointer to an `ActiveSkillInfo`,
`ActiveSkillInfoServer`, `ActiveSkillGroup`, `ToggleSkill` or `AreaSkill` row.

| Holder (member) | Set by | Lifetime | After `&reloaddata ActiveSkill` |
|---|---|---|---|
| `UseEffect::UIE_Functions::useskill` in `useditemeffect.uie_FuncStruct[itemID]` | `UsedItemEffect::uie_Load` FUN_0059cc30 (stage wide, after sdb_Load) and `uie_SetChargedBuffer` FUN_005963e0 from `ChargedItemEffectDataBox<…>::cideb_Load` (Riding FUN_00450070, ChargedEffect FUN_005af300, MiniHouse FUN_005af4d0, MiniHouseFurniture FUN_005af6d0), `RidePetDataBox::rpdb_Load` FUN_00450270, `ItemUseFunction::iuf_Load` FUN_0049b770, `MagicContainer::mc_Load` FUN_0049c7f0, `MoverDataBox::mvdb_Load` FUN_004bf960, `cStateItemDataBox::sidb_Load` FUN_0058c920, `MysteryVaultTable::DataProcess` FUN_005c8590; pointer from `uie_UseSkillID` FUN_0059cba0 | process | **dangles** (never rebuilt): every item use reads the freed array |
| `UseEffect::UseItemRide::uir_RideSkill` (`ui_ride`), `UseEffect::UseItemPet::uip_PetSummonSkill` (`ui_Pet`) | `uir_SetSkill` FUN_00653a60 / `uip_SetSkill` FUN_00596b10 in `zs_start_sun` FUN_005adbd0 ("UseRide", "UseSumPup") | process | **dangles** |
| `NPCAction::SkillAction::skillIndex_` | ctor FUN_005c0fe0 (`operator[]`; fatal "SkillAction::SkillAction : Invalid skill index") from `ActionGen_OptionReader::operator()` FUN_005c18c0 | NPC action tables (load time *(inferred)*) | **dangles** |
| `ShineMagicField::smfm_skillindex` (+0x1bc) | `so_mgcfld_MagicFieldSpread` FUN_0057ea30 / `…_Friend` FUN_0057ee80 | until the field expires | dangles while a field exists |
| `SkillEffectApply::SkillBlastEffect::sbe_SkillIndex` in each object's `SkillBlastEffectContainer::sbec_List` | `sbec_Store` FUN_00438380, `MobExplosionBase::meb_Explosion` FUN_004a7960 | until the blast tick | dangles for pending hits |
| `ShineMobileObject::smo_SkillCast.scs_ProduceSkill.sklidx` (obj+0x1d84+0x14) | `smo_SkillBash_Casting` FUN_0057bef0, cleared by `SkillCastStruct::scs_Clear` FUN_005691f0 | one cast | dangles for casts in progress |
| `AxialListLimitAreaScan::allas_pArea` (`AreaSkillInfo*`, element of `sdi_Area`) | ctor FUN_004c19c0, `allas_Init` FUN_004c19f0 / FUN_004c1a00 | one scan *(inferred)* | – |
| `EngageArgument::sklinfo`, `EngageFlag::efm_sklinfo`, `SmashArgument::sklidx` | `EngageArgument` ctor FUN_0042abf0, `smo_SkillBlast` FUN_00581160, `so_attack` FUN_0042cab0 | stack, one call | – |
| `SkillDataIndex::sdi_PrevSkill` / `sdi_NextSkill` | sdb_Load step 8 | the array | rebuilt |

Not holders (they keep skill IDs and look the index up on use): `CharaterSkillList` (`CharSkill.cs_SkillId`,
`CharacterToggleSkill.cts_nSkillID`), `MoverSkillList::MoverSkill.ms_SkillID`, `SkillCastStruct.scs_Skill`,
`MobAttackSequence` (`ae4m_skillID[500]`, `SkillChange.sc_From/sc_To`), `DefSkillData`, `MiscData_Skill`,
`NPCAction::SkillCondition::skillID_`, the abnormal states (no skill-pointer member). The `sdb_BinData` rows the
index points to live in the reader buffers, which `CDataReader::Read` reuses when the new file is not larger (§3.3),
but no holder outside the index keeps a row pointer, so that only matters for the index itself.

`uir_SetSkill`'s body (store the argument at +4) is shared by identical-code folding: `DiceGame::Start` FUN_00478ef0,
`ShineMobileObject` ctor FUN_005591c0 and `DataRecordArgument::lid_Call` FUN_00647510 call FUN_00653a60 for
unrelated "set member +4" writes; those are not skill holders. In `lid_Call` it is the per-column callback of
`ORTable::ort_ReadData` (Z09 §28.6, the `#record` text tables): `field = ORRecord::orr_AllocObject(record, &id,
column.vt[1]())` FUN_00653dc0 (first free of the 512 `orr_FieldArray` slots; type 1 index, 2 string, 3 byte, 4 word,
5 dwrd → a 0xc-byte `ORField<type>`; no free slot or other type → null → `ortr_SetError "Cannot alloc field memory"`),
`field.column = header` (the folded FUN_00653a60), `ORRecord::orr_AllocMemory(record, field)` FUN_00653d90 (hands the
field its slice `orr_Buffer + orr_Pointer` via `field.vt[1]` and advances `orr_Pointer` by the returned size), then
`field.vt[2](token reader)` reads the value.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z20-B1 | `BinaryDataBox<T>::bdb_ReadData` (5 skill readers, §2.1) | on a failed read the second log line prints the expected key and the file's `nVersionKey` (0 when `m_pHead` is null, which is tested) but never the row size | a row-size mismatch logs two equal keys, so the cause of the fatal exit is not visible (cosmetic) | include expected / actual row size |
| Z20-B2 | `sdb_Load` "Index not match" (§3.1 step 4) | compares ActiveSkill `InxName` only up to its own NUL against the server row's | a server row whose `InxName` is longer (or an empty ActiveSkill name) passes | compare both names fully (`strcmp`) |
| Z20-B3 | `sdb_Load` warnings (§3.2) | DemandSk check reads element −1 for i = 0; "same line" SP / nT checks read element `sdb_MaxValid` for the last skill | heap read outside the array when the lowest-ID skill has a step > 1 name or the highest-ID skill has a step name; a crash or a bogus warning at load (not with 2016 data) | skip i = 0 / the last element |
| Z20-B4 | `sdb_Load` (§3.3) | duplicate skill IDs are not detected | 2016: ID 9034 (`KQRoboAtkSk2`, `GoMasterAtkSkill2`): both names resolve to the same one of the two rows, the other is never used | reject duplicates at load |
| Z20-B5 | `GetSkillIndexByName` (§5.1) | casts the `skillnametree` value to `u16`, dropping `ispassive` | latent: a passive skill's name would yield the active skill with the same ID (156 shared IDs in 2016) or null | refuse entries with `ispassive = 1` |
| Z20-B6 | `pdb_Load` set-abstate index (§6.3) | `new PSSetAbstateIndex[n]` is not initialised; a row whose name resolves to ID 0xFFFF or ≥ `pdb_maxpassiveID` is skipped and its entry left as garbage; the prerequisite search scans all n entries, later unwritten ones included | latent (2016: all 16 rows valid, prerequisites always earlier): `sdb_GetSetAbstate` / the Prev search can match a garbage `pssabs_nID` and hand out a wild `PSkillSetAbstate*` | zero the array, compact skipped rows, search only entries written so far |
| Z20-B7 | `pdb_Load` name lookups (§6.3) | `PowerofLove01`, `PS_InxName` and `DemandSk` are resolved in the shared `skillnametree` without checking `ispassive` | latent: an active skill's name yields the passive with the same number, or the default block, whose empty `DemandSk` then fails the lookup and ends the process with "Invalid Skill" and an empty name | accept only `ispassive = 1` entries |
| Z20-B8 | `cpl_PreSkillCheck`, `cpl_UnLearn` (§6.5) | the bit index is not bounded: `cpl_PreSkillCheck` tests bit `0xFFFF` for an unknown name (and the passive bit of an active skill's number); `cpl_UnLearn` logs an ID > 999 but reads `bs_bitlist[id >> 3]` before its `bs_maxbit` check | heap read up to 8 KB past the 125-byte bit list; a bogus "prerequisite learned" | bound the index (`< bs_maxbit`) and check the lookup result |
| Z20-B9 | `cpl_UnLearn` (§6.5) | clears the bit but leaves the passive's `PSSetAbstateIndex` in `cpl_SetAbstateList` | after unlearning a set-abstate passive (MagicDance, DeepFear, Shame, PointAttack) its proc keeps firing until the list is rebuilt at the next login *(inferred: no other remover found)* | remove the entry (and restore the previous level) |
| Z20-B10 | `PassiveDataBox` ctor default block (§6.1) | `CastingTime` 0 and `MstRtClaw` / `MstRtDSword` 0, while `cpl_RecalcParam` treats 1000 as the neutral cast rate | a learned bit with no row (an ID that is a gap, or ≥ `pdb_maxpassiveID`, e.g. from stale Character DB data) sets `Rate.CastingTime = 0` | default `CastingTime = 1000` like the other rates |
| Z20-B11 | `cbcp_SetCondition` (§6.5) | the slot count `ceil(1000 / condition)` is stored in the `u8` `cbcp_nMaxValueNum` | latent: a PassiveSkill row with `DownDamegeHp` / `DownAcHp` 1…3 gets a truncated slot array (1000 → 232), so the Z12 step code can index past it | reject conditions < 4 or store the count in 16 bits |

## 8. Not reconstructed / uncertain

- Which of the two ID-9034 rows `bsearch` returns (MSVC `qsort` order of equal keys) was not simulated.
- What `Rate.CastingTime = 0` does: 34 PassiveSkill rows (WCMastery, MAMastery, LightMastery, BackgroundDefense)
  have CastingTime 0, so `cpl_RecalcParam` writes 0 for players who learned them (Z20-B10 is the same value from the
  default block). The rate layer is applied by `Parameter::Cluster::operator*=` FUN_004c9160, which multiplies each
  member by the rate in ‰ unless the rate is 1000 (`x = x · rate / 1000`), so a `Rate.CastingTime` of 0 zeroes the
  cast-time member of the cluster it is applied to. Which cluster that is and whether the cast code reads that
  member (instant cast for those players) is the stat calculation (Z12, open) and was not followed.
- `cpl_StoreSetAbstateList` removes the previous level only when it is already in the list: if the Character DB lists
  a higher level before a lower one (`cpl_Store` keeps the packet order), both entries stay. The DB order was not
  checked (Z12 / `p_Char_GetPassive…` procedures).
- `PassiveSkillInfo.ActiveSkillGroupInx` (8 rows ≠ 0 in 2016): no reader found, by member name or by a +0xf8 read in
  any function that touches `passivedatabox` (§6.4 / §6.5 list). A read through an untyped pointer elsewhere cannot be
  ruled out completely.
- The 49 delay-group / 24 step-number warnings are my reproduction of the rules over the 2016 data, not a run of
  the server.

## 9. Coverage boundary

How it was checked (no scope table, so `coverage.py Z20` does not apply): every PDB function whose name contains
`SkillDataBox`, `PassiveDataBox`, `SkillDataIndex`, `PassiveSkillInfo`, `ActiveSkillInfo`, `AreaSkill`,
`ToggleSkill`, `PSSetAbstate`, `CharacterPassiveList` or `SpecialSkill` is cited (exception-unwind funclets aside);
every direct callee of every `FUN_` this document cites (`coverage.py`'s `Bin`, same `TINY` / `HUB` limits) is cited
by some doc or listed below; every caller of the box functions (`operator[]`, `GetSkillIndexByName`, `sdb_Get`,
both `sdb_SpecSkillStruct`, `sdb_GetSetAbstate`, `sdb_GetAreaSkillInfo`, the `CharacterPassiveList` functions) and
every `&skillnametree` / `passivedatabox` reference is cited; the strings of the five skill files, `PassiveSkill`,
`PSkillSetAbstate`, `SkillDataBox` and `PassiveDataBox` lead only to cited functions (plus the client-view checksum
`ActiveSkillView.shn` / `PassiveSkillView.shn` in `zs_start_*` and FUN_00631450, which is Z10's certification list).

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `CharaterSkillList` toggle / cooldown / delay-group / empower / mastery / buffer functions (`csl_Toggle_*` 00444bd0 00445680 004456c0 00448c60 00448ce0, `csl_UpdateCoolTime`, `csl_GetDelayGroup`, `csl_SetCoolTime`, `csl_DmgCoolTimeDown`, `csl_EmpowerClear`, `csl_EmpowerStruct`, `csl_AddMastery`, `csl_FillSendBuffer_*`, `csl_CheckDefSkill`, `csl_MaximumSkill`, `csl_PreProduceCheck`, `csl_UnLearn`), `MoverSkillList::msl_UpdateCoolTime / msl_CoolTimeCheck / msl_SetCoolTime`, `ShinePlayer::so_ply_ToggleSkill_*` (vt 0xbc4 / 0xbc8 / 0xbcc) and packets 0x245C / 0x245D / 0x4821; mount skill users `so_smv_SkillBash_Location` 00580cf0, `ShineMover::so_ply_CanMyTarget` 004ae450 | new item **Z21** (added by Z20) | the per-player active skill list, ~1.4k lines that read the box only through `operator[]`; Z03 (done) only names toggles and cooldowns (Z03 §11), so no existing item will document them |
| Z03 skill-blast leftovers reached from §7 holder sites: `smo_Dispel` 0057d8e0, `smo_ClearSkillResultBuffer_Miss` 0057a550, `AbstateElementInObject::aeo_IsMine` 00408880 | new item **Z21** | callees of `smo_SkillBlast` / `smo_SkillBash_Blast` (Z03, done; "only named" in Z03 §11) that no doc cites |
| Item-side data loaders that store `SkillDataIndex*` (§7): `uie_Load` 0059cc30, `uie_SetChargedBuffer` 005963e0, `uie_BroadCast` 005963c0, `cideb_Load` ×4 and the `cideb_*` accessors, `rpdb_Load` 00450270, `iuf_Load` 0049b770, `mvdb_Load` 004bf960, `sidb_Load` 0058c920, `MysteryVaultTable::DataProcess` 005c8590, their `BinaryDataBox<…>::bdb_ReadData` readers and STL helpers; `CharClassDataBox::ccdb_*` 00640c20 / 00640b90 / 00640850 (from the class-change handlers that read `sdb_Get`); `RecipeBook::operator[]` 00444b50; `ItemDataBox::ReadData` 006494f0 and `igc_Store` 004900f0 (other `bt_Insert` users) | new item **Z22** (added by Z20) | Z01 §2.3 lists them as one loader row each; only the `SkillDataIndex*` they keep is this item's (§7); their own tables (item use effects, mounts, mini-house, mover upgrade, state items, mystery vault, class data) are item data, ~2k lines |
| Callees of §7 holder sites listed in Z09 §31.2 (`Parameter::Container` ctor / `c_clear` / `IsNoAttack`, `ItemActionObserveManager::EventRunBySkillGroupIndex` / `GetRateAppliValue`, `MultiHitArgument`, `SkillBlastEffect` vector helpers, `sds_Initialize`, `BattleObjectStruct`, `ListTraveler`, `ItemActionArgument`, `se_Clear`, `learnSkill` 005a1790, `PROTO_NC_CHAR_WEDDINGDATA_ACK::operator=`, mover-upgrade accessors, `UsedItemEffect::operator[]`, `ed_Compare`, `lua_next`) | Z09 §31.2 / §31.4 rows (owners Z12, Z13, Z17, Z18 as assigned there) | already assigned by Z09's boundary; this item reaches them only through code it cites as a pointer holder or name-trie reader |
| Who fills the passive `Plus` / `Rate` blocks into the final stats, the `ChangeByConditionParam` slot logic (`cbcp_nChangeParam`, `cbcp_nCharged`) and the cast-time use of `Rate.CastingTime` (§6.5, §8, Z20-B10) | Z12 (plan line 12: "`so_allparametercalculate` … what fills each layer … passives") | stat calculation; this item documents only what `cpl_RecalcParam` writes |
| `CharacterPassiveList` callers: `so_charpassivedata` 0044e5a0 (Character DB passive list) | Z12 (plan line 14 lists `so_charpassivedata` FUN_0044e5a0) | login data parsing; §6.5 documents `cpl_Store` it calls |
| `so_LearnPassive` 00559e50, `so_UnlearnSkillAck` 0057f200, `so_LearnSkill` 0055bbf0 (vt 0x620 / 0x624), the 0x4802 / 0x4803 answers | Z03 §9.3 / §9.5 (done; documents the learn / unlearn packet flow, calling the list functions only as `p.vt[0x620]()` / `p.vt[0x624](skillid)`, without these addresses) | this document covers the bodies: `so_LearnSkill` → `csl_Learn` (§5.2), `so_LearnPassive(u16 id)` = `psl_Store(sp_Passive, id, vt[0x56c]())` (§6.5) |
| `Gather.shn` loader `gt_Load` 0046a660 (writes `skillnametree`, §5.2) | Z02 §8 (done, documented there) | §5.2 records only the trie side effect and its invariant |
| Load-time tables that look skills up by name: `MiscDataTable::mdt_*`, `MobAttackSequence::mas_Load` / `sc_Store`, `MobDataBox::mdb_SkillStore`, `NPCAction` option readers, Lua `cNPCSkillUse` / `cSkillBlast` / `cSkillDamageCalculate` / `cMagicFieldSpread` | Z09 (done; each cited in `docs/pseudocode/zone/Z09-world.md`) | §5.2 states their lookup behaviour; their tables are world content |
| MSVC STL internals under `csl_Learn`'s `std::_Sort` / `push_back` (`_Unguarded_partition` 00446c50, `_Make_heap` 00445fc0, `_Insertion_sort1` 00446110, `_Sort_heap` 00447040, `vector<CharSkill>` growth 00447580) | library code (no item) | standard introsort and vector growth; a rebuild uses any sort by `cs_SkillId` |
| `CDataReader` (read, decrypt, row index, checksum) | W05 §3.1 / S01 §6 (done, documented) | the generic SHN reader under every `BinaryDataBox<T>` |
| The `BTree` callers on other tries (item `idb_btree`, abstate, mob, map, NPC, mini-house …) | the owners of those functions | `BTree::operator[]` / `bt_Insert` are shared helpers (over 25 callers); only `skillnametree` users are this item's (§5.2) |
| `RulesOfEngagementPhisycalSkill` / `…MagicalSkill::roe_CriticalRateByGlobalAction` 00504d30 / 00504ee0, `roe_HitRateByGlobalAction` 005055a0 / 005058d0, `ItemActionObserveManager::EventRunBySkillGroupIndex` 005d1f50 (the only readers of `sdi_ActiveSkillGroups`, §2.2) | Z17 (open; plan line 12: "what triggers a check (item use, equip, hit, …), each condition and effect type") | item-action triggers on hit / crit rate and skill effects; §2.2 records which box member they read |
| `ActiveSkillGroupCondition` (item-action condition on a skill group, ctor 005cedd0) | Z17 (plan: item actions) | an `ItemActionCondition` validator; it only names `ActiveSkillGroupIndex`, it does not read the box |
