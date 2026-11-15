# Zone: party experience tables and the group experience split (Z29)

Source: 2016 Zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`). Code read with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>` (function, class and member names from the
NA2016 `Zone.pdb`, same build *(pdb2016)*), constants and static data from the PE image (`objdump`, Python over the PE).
Tables decoded with `tools/protocol-re/shn.py`. Evidence markers as in `AGENTS.md`.

Related: Z03 §8.1 (mob death, `ShineMob::so_KilledBy` FUN_00432760 → `el_ExpDistribute`), Z03 §8.2 (overview of the
split; §2.6 below corrects several of its statements), Z03 §8.3 (`sp_GainExp`), Z28 §3.8 (the level-handicap table
`lh4ed`, `PartyBonusByLvDiff.shn`), Z09 §28.8 (`el_EnemyExpDistCheck`), Z14 §5.2 (`RaidTask::_GetRaidPlayer`), Z20 §2.1
(`bdb_ReadData`, `ac_AssertFail` = log only). No packet is defined here: the experience reaches the client through
`sp_GainExp` (0x240B `NC_BAT_EXPGAIN_CMD`, Z03 §8.3).

## 1. Tables and loaders

### 1.1 Load order

```pseudo
HitMeList::hml_Load(Name4* worldname /*unused*/)                    @ FUN_004824d0
    # called once by ZoneServer::zs_start_yellow FUN_005ae4e0 (Z10 §7.1); no world-specific path
    LevelHandicap4ExperienceDouble::lh4ed_Load(&lh4ed, NULL)         @ FUN_00481a80   # PartyBonusByLvDiff.shn, Z28 §3.8
    PartyExperienceBonusDouble::pebd_Load(&pebd, NULL)               @ FUN_00481bf0   # PartyBonusByMember.shn, §1.2
    MaxExpGainAtGroup::megag_Load(&g_MaxExpGainAtGroup)              @ FUN_00481980   # PartyBonusLimit.shn, §1.3
```

The three globals (names *(pdb2016)*):

| Global | Address | Type (size) | Static initialiser | Reader |
|---|---|---|---|---|
| `lh4ed` | 0x0d55aa30 | `LevelHandicap4ExperienceDouble { double lh4ed_Table[301] }` (0x968) | `dynamic_initializer_for_'lh4ed'` FUN_006960d0 → ctor FUN_00481260 (Z28 §3.8), atexit FUN_0069d110 (empty) | `ed_GiveExperience` FUN_00481890 (§2.2) |
| `pebd` | 0x0075d480 | `PartyExperienceBonusDouble { double pebd_Bonus[21]; +0xa8 int pebd_MaxNum }` (0xb0) | FUN_006960f0 (§1.2), atexit FUN_0069d120 (empty) | `ExperienceDistribute::lid_Call` FUN_00483360 |
| `g_MaxExpGainAtGroup` | 0x0d55b398 | `MaxExpGainAtGroup { u32 megag_ExpLimit[151] }` (0x25c) | FUN_00696160 (only registers the empty atexit FUN_0069d130; BSS = 0) | `nfis_ExpLimitCut` FUN_00482560 |

`pebd` is the table Z03 §8.2 calls `g_PartyExpBonus` (DAT_0075d480): the same object.

The `OptionReader*` parameter of `lh4ed_Load` and `pebd_Load` is never read (both callers pass NULL). It is the
remainder of an older text-file loader *(inferred)*, see §1.4.

### 1.2 `PartyBonusByMember.shn` → `pebd` (party bonus factor by member count)

Row struct `PartyBonusByMember` (size 3, *(pdb2016)*), read by `BinaryDataBox<PartyBonusByMember>::bdb_ReadData`
FUN_004814f0 = `CDataReader::Read(path, key 7, row size 3)`; on failure the readfail asserts and `ShineExit` of Z20 §2.1.

| Column (shn.py) | Offset / type | Member it fills | Meaning |
|---|---|---|---|
| `PB_PartyMember` | +0 u8 | index into `pebd_Bonus[]` | number of *bonus-valid* members (§2.4 `nfis_BonusCheck`) |
| `PB_BonusRatio` | +1 u16 | `pebd_Bonus[PB_PartyMember] = PB_BonusRatio / 1000.0` | total experience factor in ‰ (1000 = no bonus) |

```pseudo
dynamic_initializer_for_'pebd'()                                     @ FUN_006960f0
    # the PE image already holds pebd_Bonus[0] = 1.0 and pebd_MaxNum = 20 (static data at 0x75d480 / 0x75d528)
    copy pebd_Bonus[0] forward over pebd_Bonus[1 … 20]               # rep movsd 0x28 dwords 0x75d480 → 0x75d488: all 21 = 1.0
    pebd_Bonus[0] = 1.0; [1] = 1.0; [2] = 1.2; [3] = 1.4; [4] = 1.6; [5] = 1.8      # built-in defaults; [6 … 20] stay 1.0
    atexit(FUN_0069d120)                                             # empty destructor
    # pebd_MaxNum is never written by code: it is the constant 20 of the image

PartyExperienceBonusDouble::pebd_Load(OptionReader* unused)          @ FUN_00481bf0
    rows = BinaryDataBox<PartyBonusByMember>.bdb_ReadData("../9Data/Shine/PartyBonusByMember.shn")   # FUN_004814f0
    maxIdx = max(row.PB_PartyMember over all rows)  (0 if no rows)
    if maxIdx > pebd_MaxNum (20):
        AssertFail "PartyExperienceBonusDouble::pebd_Load - Buffer max num", maxIdx, pebd_MaxNum
        ShineExit("PartyExperienceBonusDouble::pebd_Load")           # process ends
    pebd_Bonus[0 … 20] = −1.0                                        # marker for "no row" (the built-in defaults are discarded)
    for each row in file order: pebd_Bonus[row.PB_PartyMember] = row.PB_BonusRatio / 1000.0    # later duplicates win
    for i in 0 … 20:
        if pebd_Bonus[i] < 0 (or NaN):                               # fldz/fcomp/test ah,0x41: 0.0 itself passes
            AssertFail "PartyExperienceBonusDouble::pebd_Load : Data error", i
            # log only: the server keeps running with factor −1.0 for that count (original bug) Z29-B4
```

2016 file (identical in 2015 and NA2016; 21 rows, key 7, row size 3): `PB_PartyMember` 0 … 20, each exactly once, in
ascending order. `PB_BonusRatio`: 0 → 1000, 1 → 1000, 2 → 1200, 3 → 1400, 4 → 1600, 5 → 1800, 6 … 20 → 1800. So the
loaded factors are 1.0, 1.0, 1.2, 1.4, 1.6, then 1.8 for 5 … 20. They equal the built-in defaults for 0 … 5 and
replace the default 1.0 by 1.8 for 6 … 20 (only raids reach more than 5 members, §2.3). Invariants a rebuild must keep:
every index 0 … 20 present (otherwise Z29-B4) and every ratio ≥ 1000 (a ratio below 1000 gives a negative bonus, which
wraps, Z29-B4).

### 1.3 `PartyBonusLimit.shn` → `g_MaxExpGainAtGroup` (per-level experience cap inside a group)

Row struct `PartyBonusLimit` (size 5, packed, *(pdb2016)*), read by `BinaryDataBox<PartyBonusLimit>::bdb_ReadData`
FUN_00481390 = `CDataReader::Read(path, key 10, row size 5)`, failure as in Z20 §2.1.

| Column (shn.py) | Offset / type | Member it fills | Meaning |
|---|---|---|---|
| `PSE_ChrLv` | +0 u8 | index into `megag_ExpLimit[]` | character level |
| `PSE_ExpLimit` | +1 u32 | `megag_ExpLimit[PSE_ChrLv]` | most experience a member of that level keeps from one group kill before the cut (§2.4) |

```pseudo
MaxExpGainAtGroup::megag_Load()                                      @ FUN_00481980
    rows = BinaryDataBox<PartyBonusLimit>.bdb_ReadData("../9Data/Shine/PartyBonusLimit.shn")      # FUN_00481390
    megag_ExpLimit[0 … 150] = 0
    for each row in file order:
        megag_ExpLimit[row.PSE_ChrLv] = row.PSE_ExpLimit              # no bound check: PSE_ChrLv 151 … 255 writes past the
                                                                      # 151-entry array (original bug) Z29-B2, latent
    for lv in 1 … 150:
        if megag_ExpLimit[lv] == 0:
            AssertFail "PartyExperienceBonusDouble::pebd_Load : Data error", lv
            # log only; the text names the wrong loader (copied from pebd_Load) (original bug) Z29-B1
            # a missing level keeps limit 0: that member keeps nothing before the redistribution of §2.4
```

2016 file (identical in 2015 and NA2016; 151 rows, key 10, row size 5): `PSE_ChrLv` 0 … 150, each once, ascending.
`PSE_ExpLimit(0) = 0` and for 1 ≤ L ≤ 150 exactly `PSE_ExpLimit(L) = 2·L² − 4·L + 20` (checked for every row: 18, 20,
26, 36, 50, … 4820 at 50, 19620 at 100, 30770 at 125, 44420 at 150). Index 0 is never checked and never used for real
players (level ≥ 1).

### 1.4 `World/ExpRecalculation.txt` is not read

`9Data/Shine/World/ExpRecalculation.txt` (2015, 2016 and NA2016) holds the tables `ByPartyMem` (0, 1: 1000; 2: 1200;
3: 1400; 4: 1600; 5: 1800), `ByLevelDiff` (the `PartyBonusByLvDiff.shn` rows) and `StandardDeviation`
(`LowerBound100` / `HandicapRate`). No 2016 binary (Zone, WM, Login, Account, AccountLog, Character, GameLog, client)
contains the file name or any of its table or column names (`ExpRecalc`, `ByPartyMem`, `ByLevelDiff`,
`StandardDeviation`, `HandicapRate`: no hit in any `strings.tsv` nor in the raw Zone/WM images). The Zone's generic
`Data/Shine/World/%s.txt` path is only used with the names listed by the items that own those loaders. So the file
does not override the SHN values: the SHN files of §1.2, §1.3 and Z28 §3.8 are the only source. The `StandardDeviation`
table has no counterpart in 2016 at all. Z03 §8.2's mention of this file as a source is therefore historical only
*(inferred: the unused `OptionReader*` parameters suggest the SHN loaders replaced an OptionReader over this file)*.

## 2. Experience split per attacker unit

### 2.1 Data structures

All names *(pdb2016)*.

```pseudo
HitMeList::Enemy (0x18)                     # one per attacker unit in the mob's EnemyList (Z03 §8.2)
    +0x00 e_Type          E_PLAYER 0 / E_PARTY 1 / E_RAID 2
    +0x04 e_AttackerInfo  (for party/raid: u16 partyregnum = party or raid number; 0xffff = none)
    +0x0c e_LastHitTime   ei_LastHitTime of the player entry that set e_Attacker
    +0x10 e_TotalDamage   damage of the unit (minus out-of-range players, Z09 §28.8)
    +0x14 e_Attacker      a player of the unit: the one whose el_vecEnemyPlayer entry comes last (see below)

# How the unit list is built (Z09 §6.9 documents the functions; restated here because e_Attacker depends on it):
#   every hit: ShineMob::so_DamagedBy FUN_00431750 → el_StoreDamage FUN_00482f00 adds to the per-player vector
#     el_vecEnemyPlayer {ei_nCharRegNo, ei_Attacker, ei_LastHitTime, ei_TotalDamage} (≤ 100 entries, in order of
#     first hit; when full the entry with the oldest ei_LastHitTime is overwritten in place). A servant (vt 0x4d0 == 10)
#     is replaced by its master (vt 0x9b0); only objects of kind 2 (players) are stored.
#   at the kill: ShineMob::so_KilledBy FUN_00432760 → el_StoreLastDamage FUN_00483030: el_StoreDamage(killer, damage),
#     then for each player entry in vector order (stale pointer → som_FindPlayer(charNo), gone → skipped)
#     el_Store FUN_00482070 (entry.player, entry.damage, entry.time): adds the damage to its unit and overwrites
#     e_Attacker = entry.player, e_LastHitTime = entry.time.
# So e_Attacker is always a player (el_Store's own servant branch is never reached from this path), and for a party
# or raid it is the member whose entry is last in the vector (the member whose first hit came latest, or who took
# over an overwritten slot), not necessarily the latest hitter.

ExperienceDistribute (0x18) : ListIteratorDefault<HitMeList::Enemy>      # built on the stack by el_ExpDistribute
    +0x04 ed_MobInf       MobDataBoxIndex* (data = MobInfo, serv = MobInfoServer)
    +0x08 ed_TotalDamage  EnemyList.el_nTotalDamage (all units, read after el_EnemyExpDistCheck)
    +0x0c ed_Mob          the dead mob
    +0x10 ed_MobInfoServ  MobInfoServer*
    +0x14 ed_MobHandle    u16

GroupExpDistribute::NearFriendInformation (0xc)                           # one per member found near the mob
    +0x0 nfi_PlayerObject ShineObject*
    +0x4 nfi_Level        u8 (vt 0x4d8 & 0xff)
    +0x5 nfi_CanBonus     bool
    +0x8 nfi_ExpGain      u32, starts 0

GroupExpDistribute::NearFriendInformationSummary (0x10)                   # on the stack of lid_Call
    +0x0 nfi_ExpRange                      = MobInfoServer.EXPRange (u16)
    +0x4 nfis_MaxLevel                     highest member level
    +0x8 nfis_SummaryOfLevelScore_All      Σ (level + 5)²   over all members
    +0xc nfis_SummaryOfLevelScore_Valid    Σ level²         over bonus-valid members
static std::vector<NearFriendInformation> NearFriendInformationSummary::nfis_FriendInfo   # global 0x0d55aa20, shared;
    # initialiser FUN_006960c0 only registers the atexit FUN_0069d140 (frees the buffer)
```

### 2.2 `el_ExpDistribute` and `ExperienceDistribute::lid_Call`

```pseudo
HitMeList::EnemyList::el_ExpDistribute(list, mob, mobInf, mobHandle)          @ FUN_004828b0   (from so_KilledBy, Z03 §8.1)
    el_EnemyExpDistCheck(list, mob)                         @ FUN_00482720   # Z09 §28.8: removes far players' damage from their unit
    ed = ExperienceDistribute{ ed_MobInf = mobInf, ed_TotalDamage = list.el_nTotalDamage, ed_Mob = mob,
                               ed_MobInfoServ = mobInf.serv, ed_MobHandle = mobHandle }
    for each Enemy e in list: ed.lid_Call(e)                # List::l_4AllInList

ExperienceDistribute::lid_Call(ed, Enemy e) → 1                                @ FUN_00483360
    base = ed_MobInf.serv.MonEXP (u32)
    if ed_Mob.vt[0xb9c]() != 0: base = ed_Mob.vt[0xb9c]()   # script override (Z03 §8.2); 0 means "no override"
    share = TRUNC(base * (e.e_TotalDamage / ed_TotalDamage))  # u32 operands; see TRUNC below
    # ed_TotalDamage is not reduced by el_EnemyExpDistCheck, so removed damage is experience nobody gets (Z09 §28.8)
    if e.e_Attacker == NULL: AssertFail "ExperienceDistribute::lid_Call : Free fail"; return 1
    if e.e_Type == E_PLAYER:
        ed_GiveExperience(ed, e.e_Attacker, share); return 1
    summary = { nfi_ExpRange = MobInfoServer.EXPRange, 0, 0, 0 };  nfis_FriendInfo.resize(0)
    n = 0
    if e.e_Type == E_PARTY:
        if e.partyregnum == 0xffff: AssertFail "ExperienceDistribute::lid_Call : Invalid Party Regnum"
        else: n = ed_FindPartyInfo(ed, e.partyregnum, &summary)          # §2.3
    elif e.e_Type == E_RAID:
        if e.partyregnum == 0xffff: AssertFail "ExperienceDistribute::lid_Call : Invalid Raid Regnum"
        else: n = ed_FindReidInfo(ed, e.partyregnum, &summary)           # §2.3
    if n < 1:  AssertFail "ExperienceDistribute::lid_Call : friendnumber zero", n;  return 1   # the share is lost
    if n == 1: ed_GiveExperience(ed, e.e_Attacker, share);  return 1
        # gives to e_Attacker (the unit's last member in el_vecEnemyPlayer, §2.1), not to the one member found near
        # the mob (original bug) Z29-B6
    nfis_TopLevelFind(&summary)                              @ FUN_00481790
    valid = nfis_BonusCheck(&summary)                        @ FUN_00482500
    nfis_ExpBase(&summary, share)                            @ FUN_004825a0
    f = (valid < 21) ? pebd.pebd_Bonus[valid] : 1.0          # constant 21 (0x15), not pebd_MaxNum; valid ≤ 20 in practice
    bonus = (u32)(i64) TRUNC(share * (f − 1.0))              # f < 1.0 → negative → wraps (original bug) Z29-B4
    nfis_ExpBonus(&summary, bonus)                           @ FUN_00482620
    cut = nfis_ExpLimitCut(&summary)                         @ FUN_00482560
    nfis_ExpBonus(&summary, cut)                             # the cut amount is handed out again (original bug) Z29-B5
    nfis_ExpDistribute(&summary, (u16) MobInfoServer.ID, ed_MobHandle)   @ FUN_004826b0
    return 1

ExperienceDistribute::ed_GiveExperience(ed, obj, int share)                    @ FUN_00481890   (single receiver only)
    h = lh4ed_Handicap(&lh4ed, obj.vt[0x550]() /*party regnum, unused*/, obj.vt[0x4d8]() & 0xff, MobInfo.Level)  # Z28 §3.8
    obj.vt[0x5c4](trunc(share * h), MobInfoServer.ID, ed_MobHandle)   # so_GetExperienceFromMob FUN_004302a0 (Z03 §8.2);
                                                                      # _ftol2_sse: truncation toward zero
```

### 2.3 Collecting the members near the mob

```pseudo
ExperienceDistribute::ed_FindPartyInfo(ed, u16 party, summary) → n             @ FUN_00483260
    if party > 3999: AssertFail "… ed_FindPartyInfo : Too large party handle"; return 0
    m = partycontainer.m_Array[party].NumOfMember
    if not (1 < m < 6): AssertFail "… ed_FindPartyInfo : Invalid party member number", m; return 0
    for i in 0 … m−1:
        obj = PartyManufacture::pm_FindMember(&partymanufacture, party, i)    @ FUN_004cc390
            # returns PARTY_SLOT.Members[i].memberobj (NULL when that member is not in this zone:
            # WorldManagerSession::wms_PartyMemberRefresh FUN_004cd1a0 sets it to som_FindPlayer(charNo) or NULL);
            # asserts "Too large party regnum" / "Invalid party member number" / "sub is too big" and returns NULL
        if obj != NULL and so_DistanceSquar(obj, ed_Mob) ≤ EXPRange²:
            nfis_FriendInfo.push({ obj, level = obj.vt[0x4d8]() (u8), CanBonus = false, ExpGain = 0 })
    return nfis_FriendInfo.size()
    # no alive check: dead members near the mob are counted for the bonus (they raise `valid` and the factor) and get a
    # share that sp_GainExp then drops (Z03 §8.3: mode 0/3 get nothing) (original bug) Z29-B8

ExperienceDistribute::ed_FindReidInfo(ed, u16 raid, summary) → n               @ FUN_00483190   ("Reid" sic, pdb2016)
    if RaidTask::rt_GetRaid(raid) == NULL: AssertFail "… ed_FindReidInfo : FindRaid fail", raid; return 0
    if not RaidTask::rt_GetNearRaidPlayer(&near, raid, ed_Mob): return 0      @ FUN_005ce6d0
        # = _GetRaidPlayer(&near, raid, mob, 1000) FUN_005ce000 (Z14 §5.2): online members within 1000 units, max 20.
        # The raid radius is the constant 1000, not MobInfoServer.EXPRange as for parties and el_EnemyExpDistCheck.
    for each p in near.pPlayers[0 … near.unNum−1]:
        if p == NULL: AssertFail "… ed_FindReidInfo : Null raid member"; return 0   # entries pushed so far stay; n = 0
        nfis_FriendInfo.push({ p, level = p.vt[0x4d8]() (u8), CanBonus = false, ExpGain = 0 })
    return near.unNum
    # no alive check either (Z29-B8)
```

A party unit thus has 2 … 5 candidates (party size), a raid unit up to 20. `pebd_MaxNum` 20 matches the raid maximum.

### 2.4 The `nfis_*` steps

```pseudo
nfis_TopLevelFind(s)                                          @ FUN_00481790
    s.nfis_MaxLevel = max(k.nfi_Level for k in nfis_FriendInfo)

nfis_BonusCheck(s) → valid                                    @ FUN_00482500
    s.All = 0; s.Valid = 0; valid = 0
    for k in nfis_FriendInfo:
        s.All += (k.nfi_Level + 5)²
        if s.nfis_MaxLevel − k.nfi_Level < 21:                # within 20 levels of the highest member
            k.nfi_CanBonus = true;  s.Valid += k.nfi_Level²;  valid += 1
        else: k.nfi_CanBonus = false
    return valid                                              # ≥ 1 (the top member always qualifies)

nfis_ExpBase(s, share)                                        @ FUN_004825a0
    for k in nfis_FriendInfo: k.nfi_ExpGain += (int) TRUNC(((k.nfi_Level + 5)² / s.All) * share)

nfis_ExpBonus(s, amount)                                      @ FUN_00482620   # amount is read as unsigned
    for k in nfis_FriendInfo where k.nfi_CanBonus:
        k.nfi_ExpGain += (int)(i64) TRUNC(amount * (k.nfi_Level² / s.Valid))

nfis_ExpLimitCut(s) → cut                                     @ FUN_00482560
    cut = 0
    for k in nfis_FriendInfo:                                  # all members, valid or not
        lim = g_MaxExpGainAtGroup.megag_ExpLimit[k.nfi_Level]  # no bound check: level > 150 reads past the table
                                                               # (original bug) Z29-B3, latent
        if k.nfi_ExpGain > lim: cut += k.nfi_ExpGain − lim;  k.nfi_ExpGain = lim
    return cut

nfis_ExpDistribute(s, mobId, mobHandle)                       @ FUN_004826b0
    for k in nfis_FriendInfo:
        if k.nfi_PlayerObject == NULL: AssertFail "NearFriendInformationSummary::nfis_ExpDistribute : k->nfi_PlayerObject NULL"
        else: k.nfi_PlayerObject.vt[0x5c4](k.nfi_ExpGain, mobId, mobHandle)   # so_GetExperienceFromMob, no level handicap
```

### 2.5 The formula

For one attacker unit with share `S` (from §2.2) and `n` members near the mob (§2.3):

- **n = 0**: nobody gets anything ("friendnumber zero").
- **n = 1** (and every `E_PLAYER` unit): `e_Attacker` gets `trunc(S · lh4ed(level − mobLevel))` (Z28 §3.8), then the
  abstate and rest-exp modifiers of `so_GetExperienceFromMob` (Z03 §8.2).
- **n ≥ 2**: with levels `Lᵢ`, `M = max Lᵢ`, valid set `V = { i : M − Lᵢ ≤ 20 }`, `v = |V|`,
  `A = Σᵢ (Lᵢ+5)²`, `W = Σ_{i∈V} Lᵢ²`, `f = pebd_Bonus[v]` (2016: v = 1 → 1.0, 2 → 1.2, 3 → 1.4, 4 → 1.6, ≥ 5 → 1.8),
  `B = trunc(S · (f − 1))`:
  1. `gᵢ = trunc(S · (Lᵢ+5)² / A)` for every member;
  2. `gᵢ += trunc(B · Lᵢ² / W)` for i ∈ V;
  3. `C = Σ max(0, gᵢ − cap(Lᵢ))`, `gᵢ = min(gᵢ, cap(Lᵢ))` with `cap(L) = megag_ExpLimit[L]` (2016: 2L² − 4L + 20);
  4. `gᵢ += trunc(C · Lᵢ² / W)` for i ∈ V (no second cap);
  5. each member gets `gᵢ` through `so_GetExperienceFromMob` (abstate modifiers, then `sp_GainExp`). No level
     handicap is applied (original bug) Z29-B7.

So the group total before modifiers is `S · f` minus the truncation losses (at most 1 per member per step): the cap moves experience between members but never
removes it (Z29-B5). Non-valid members (more than 20 levels below the top) get only their base part and do not raise
`v`; they still count in `A`, so they dilute the others' base part.

Worked example (2016 tables): party of a level 50 and a level 40 near the mob, `S = 1000`. `A = 55² + 45² = 5050`;
base 599 / 400. Both valid, `f = 1.2`, `B = trunc(1000 · 0.19999999999999996) = 199`, `W = 2500 + 1600 = 4100`: bonus
121 / 77 → 720 / 477. Caps 4820 / 3060 are not reached, so the members receive 720 and 477 (total 1197, not 1200).

Cap example: levels 5 and 20, `S = 1000`. `A = 100 + 625 = 725`: base 137 / 862. `W = 25 + 400 = 425`, `B = 199`, bonus
11 / 187 → 148 / 1049. Caps 50 / 740: cut 98 + 309 = 407, gains 50 / 740. Redistribution of 407: +23 / +383 →
**73 / 1123**, both above their cap again.

**TRUNC.** Ghidra shows these conversions as `ROUND`, but each `fistp` (0x4825fd `nfis_ExpBase`, 0x482683
`nfis_ExpBonus`, 0x483429 / 0x483587 `lid_Call`) runs under a control word `fnstcw | 0x0C00` (RC = 11, round toward
zero), restored afterwards: the MSVC inline `(__int64)double` cast, i.e. truncation, the same as `_ftol2_sse` in
`ed_GiveExperience`. Every `u32` operand (`MonEXP`, damages, `share`, sums) is converted as unsigned (`+ 2³²` when the
sign bit is set). `pebd_Bonus[v] = PB_BonusRatio / 1000.0` (fdiv by the double 1000.0 at 0x481cf5), so `f − 1.0` is
slightly below the decimal value for 1200 and 1400 (1.2 − 1.0 = 0.19999999999999996, 1.4 − 1.0 = 0.3999999999999999) and
slightly above it for 1600 and 1800 (0.6000000000000001, 0.8000000000000000444): with 2 or 3 valid members `B` is one less
than `S · (ratio − 1000) / 1000` whenever that product is an integer. A rebuild must use IEEE double arithmetic in this
order and truncate to reproduce the exact numbers.

### 2.6 Corrections to Z03 §8.2

Z03 is done, so the corrections are recorded here (and in `docs/knowledge/Z29.md` for X01):

- "split among the members by level …, each through the same level handicap": the group path (n ≥ 2) never calls
  `ed_GiveExperience` / `lh4ed_Handicap`. Only single receivers (solo units and units with one member near the mob) get
  the level-difference factor of `PartyBonusByLvDiff.shn`.
- "members = living members of that party/raid near the mob": there is no alive check (§2.3, Z29-B8); dead members are
  dropped only later by `sp_GainExp`, after they have been counted.
- "share += round(share * (g_PartyExpBonus[n] − 1.0))", n = members: the index is the number of *bonus-valid* members
  (within 20 levels of the top member), and the bonus is split by `level²` among those only (§2.4).
- The tables come only from the SHN files (§1.4); `ExpRecalculation.txt` is not read.
- `share = round(base * entry.damage / totalDamage)` and `round(share * (…− 1.0))`: every conversion truncates toward
  zero (control word RC = 11, §2.5 "TRUNC"), and the share is `base * (damage / total)` in that order.
- "e_Attacker = the latest hitter" (implied): it is the unit's player whose `el_vecEnemyPlayer` entry is last (§2.1).

## 3. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z29-B1 | `megag_Load` FUN_00481980 | a level 1 … 150 without a `PartyBonusLimit` row logs "PartyExperienceBonusDouble::pebd_Load : Data error" | the log names the wrong file/loader | its own text ("MaxExpGainAtGroup::megag_Load : Data error") |
| Z29-B2 | `megag_Load` FUN_00481980 | `megag_ExpLimit[PSE_ChrLv]` written with no bound check (u8 index, 151 entries) | a row with level 151 … 255 overwrites memory after `g_MaxExpGainAtGroup`; latent (2016 max 150) | reject or ignore levels > 150 |
| Z29-B3 | `nfis_ExpLimitCut` FUN_00482560 | `megag_ExpLimit[level]` read with no bound check | a member above level 150 reads a random cap; latent (2016 `levellimit` 125, Z12 §5.1) | clamp the level or size the table to 256 |
| Z29-B4 | `pebd_Load` FUN_00481bf0 / `lid_Call` FUN_00483360 | a missing `PB_PartyMember` 0 … 20 leaves −1.0 and only logs "Data error"; any factor below 1.0 gives a negative bonus that is cast to u32 and read as unsigned by `nfis_ExpBonus` | each valid member adds (2³²·w − \|B\|·w) mod 2³² (w = its `level²` share): huge gains when more than one member is valid, then capped and re-inflated by B5; latent (2016 file complete, all ratios ≥ 1000) | refuse to start on a missing row, and treat the bonus as signed |
| Z29-B5 | `lid_Call` FUN_00483360 (`nfis_ExpLimitCut` + second `nfis_ExpBonus`) | the amount cut above `PartyBonusLimit` is redistributed by `level²` to all bonus-valid members, the capped ones included, with no second cut | the cap is not a cap: members end above it (example §2.5: 74 for cap 50); with equal levels the cap has no effect at all | give the excess only to members below their cap (or drop it) *(inferred)* |
| Z29-B6 | `lid_Call` FUN_00483360 | a party/raid unit with exactly one member near the mob gives the share to `e_Attacker` (the unit's member whose `el_vecEnemyPlayer` entry is last, §2.1) | if that member has run out of EXP range (or is dead) and another member is near, the far member gets the experience and the near one nothing | give it to the single member found (`nfis_FriendInfo[0]`) |
| Z29-B7 | `lid_Call` FUN_00483360 / `nfis_ExpDistribute` FUN_004826b0 | units with ≥ 2 members near the mob skip the level handicap (`lh4ed`, `PartyBonusByLvDiff.shn`) | a group gets full experience from mobs far above (solo: 0 from 30 levels above, Z28 §3.8) or below its level | apply `lh4ed_Handicap` per member *(inferred: the file is named "PartyBonus…")* |
| Z29-B8 | `ed_FindPartyInfo` FUN_00483260 / `ed_FindReidInfo` FUN_00483190 | members near the mob are collected without an alive check | dead members raise the bonus count and take a share that `sp_GainExp` discards | skip dead members |

## 4. Not reconstructed / uncertain

- **x87 precision control.** The numbers of §2.5 assume IEEE double operations (MSVC's default 53-bit precision
  control; no `_controlfp` / `fldcw` with a precision change was looked for outside the conversion sites). With 64-bit
  precision the intermediate quotients `(L+5)² / A`, `L² / W` and products could differ in the last bits, which can
  move a truncated result by 1 when the exact value is an integer *(inferred: not checked at the process start-up)*.
- **`ed_Mob.vt[0xb9c]` (script EXP override).** Only its use here is read: a non-zero return replaces `MonEXP`. What
  sets it is Z03 §8.2 (done); not re-read.
- **"Free fail" in `lid_Call`** (`e_Attacker == NULL`) is unreachable from the 2016 kill path: `el_StoreLastDamage`
  FUN_00483030 skips entries whose player is gone, and `el_Store` stores only non-NULL objects *(inferred from the
  code of both)*.
- **`ed_FindReidInfo` on a NULL raid member** returns 0 but leaves the entries pushed so far in the shared
  `nfis_FriendInfo`; the next `lid_Call` resizes the vector to 0 first, so the leftovers have no effect *(inferred)*.
  A NULL entry in `NearRaidPlayers` is not produced by `_GetRaidPlayer` (Z14 §5.2) as far as that item documents.
- **Raid radius.** Raid members are collected within the constant 1000 units (`rt_GetNearRaidPlayer`), party members
  within `MobInfoServer.EXPRange`, and `el_EnemyExpDistCheck` already removed raid players beyond `EXPRange`. For a mob
  with `EXPRange` < 1000 a raid member between the two radii gets a share although its own damage was removed; with
  `EXPRange` > 1000 a member who dealt damage at range gets none. Not tagged as a bug: the two radii may be intended.
- **`ExpRecalculation.txt`** (§1.4): whether an older build read it is not known (only 2015/2016 binaries are here,
  neither names the file).
- **Timing of `nfis_FriendInfo` reuse.** The vector is a process-wide static; `lid_Call` is not re-entrant through it.
  All experience splits run on the zone's main thread (Z01), so no race is possible *(inferred)*.

## 5. Coverage boundary

`coverage.py Z29` reports "no scope table; coverage does not apply", so the callers and callees of every function in
§1–§2 were checked by hand (each one has exactly one call site, as listed), plus every zone string naming the classes
(`HitMeList`, `ExperienceDistribute`, `GroupExpDistribute`, `NearFriendInformation`, `PartyExperienceBonusDouble`,
`MaxExpGainAtGroup`, `lh4ed`, `PartyBonus*`). No client binary and no other server names any of the three files or
classes: the tables exist only on the zone, and no packet carries them.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `HitMeList::EnemyList::el_Store` FUN_00482070, `el_StoreDamage` FUN_00482f00, `el_StoreLastDamage` FUN_00483030, `HitMeList::Enemy::e_ObjCompare` FUN_004816b0, `List<HitMeList::Enemy>::l_Search` FUN_00481e20 | Z09 §6.9 (done; documents all of them) | build the attacker-unit list that `el_ExpDistribute` iterates; §2.1 here restates only what `e_Attacker` / `e_LastHitTime` end up holding |
| `HitMeList::EnemyList::el_EnemyExpDistCheck` FUN_00482720 | Z09 §28.8 (done) | removes far players' damage before the split; cited in §2.2 |
| `HitMeList::EnemyList::el_FindLooter` FUN_004822f0 | Z09 §11.4 (done) | same class, loot rights, not experience |
| `ShineMob::so_KilledBy` FUN_00432760, `ShineMob::so_DamagedBy` FUN_00431750 | Z03 §8.1 (done) | callers of the death / damage paths |
| `so_GetExperienceFromMob` FUN_004302a0 (vt 0x5c4), mob script EXP override vt 0xb9c, `sp_GainExp` / 0x240B `NC_BAT_EXPGAIN_CMD` | Z03 §8.2 / §8.3 (done) | what happens to a member's gain after `nfis_ExpDistribute` / `ed_GiveExperience`; the client side of the experience packet |
| `LevelHandicap4ExperienceDouble` ctor FUN_00481260, `lh4ed_Load` FUN_00481a80, `lh4ed_Handicap` FUN_00481810, `PartyBonusByLvDiff.shn` | Z28 §3.8 (done) | third table loaded by `hml_Load`; used only by `ed_GiveExperience` |
| `RaidTask::rt_GetRaid` FUN_005cdf80, `rt_GetNearRaidPlayer` FUN_005ce6d0, `_GetRaidPlayer` FUN_005ce000 | Z14 §5.2 (done) | raid container; §2.3 cites the result used here |
| `PartyManufacture::pm_FindMember` FUN_004cc390 | this item §2.3 (and Z22 FUN_004cc390 note) | documented here |
| `WorldManagerSession::wms_PartyMemberRefresh` FUN_004cd1a0 | Z08 §1.3 | sets `memberobj`; cited in §2.3 for the NULL case only |
| `ShineObjectManager::som_FindPlayer` FUN_00550360 | Z01 | object registry |
| `ShineObject::so_DistanceSquar` FUN_004028f0 | Z09 §28.8 (done) | distance² helper |
| `ZoneServer::zs_start_yellow` FUN_005ae4e0 | Z10 §7.1 (done) | start-up stage that calls `hml_Load` |
| `BinaryDataBox<T>::bdb_ReadData` template, `CDataReader::GetRecord` FUN_0062a0f0 / `Read` FUN_0062a9e0, `BinaryData` ctor / dtor FUN_0063cf30 / FUN_0063cf50 | Z20 §2.1, Z27 (done) | generic SHN reader; the two instances FUN_004814f0 / FUN_00481390 and their checks are in §1.2 / §1.3 |
| `BinaryDataBox<PartyBonusLimit>` dtor FUN_00481380 / scalar deleting dtor FUN_004815d0, `BinaryDataBox<PartyBonusByMember>` dtor FUN_004814e0 / scalar deleting dtor FUN_00481630 | boilerplate | free the temporary row buffer of the loaders; no behaviour |
| `AssertClass::ac_AssertFail` FUN_0063c6c0 / FUN_0063c710 / FUN_0063c760, `ShineExit` FUN_0063c7c0 | Z20 §2.1 (assert = log only), Z01 | log / terminate helpers |
| `FunctionProfiler::PerformanceRecorder::pr_Entrance` / `pr_Exit` FUN_004682d0 / FUN_00468360, `List<…>::l_4AllInList` FUN_00487c50 | Z11 §4.5, Z09 | profiler and list-walk boilerplate |
| `std::vector<NearFriendInformation>::resize` FUN_004830c0, `std::vector<…>::push_back` FUN_005c9040 (folded instance), `_ftol2_sse` FUN_00657200 | boilerplate (STL / CRT) | container growth and the truncating double→int cast |
| `AxialListNearFriend::ali_Work` FUN_004aca50 | Z09 §6.7 (done) | mob-AI friend scan; shares only the word "NearFriend" with this subsystem |
| `World/ExpRecalculation.txt` | this item §1.4 | no 2016 reader: nothing to document beyond its absence |
