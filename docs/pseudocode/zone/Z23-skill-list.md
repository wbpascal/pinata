# Zone: per-player active skill list (Z23)

Source: the 2016 zone server (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`), read with the NA2016 zone PDB
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Class, member and function names are
from that PDB *(pdb2016)* unless marked. Vtable slots resolved with `tools/protocol-re/rtti.py` against the 2016 exe.
Evidence markers as in `AGENTS.md`. Packet layouts: `docs/protocol/annotations/Z23.json`; 0x4821 is verified in
`annotations/Z03.json`.

What this file covers, and where the neighbours are:

- Z03 §5 is the cast path (`sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ` 0x2440, `csl_SPCheck`, `smo_SkillBash_Casting`, the blast).
  This file is about the per-player state the cast path reads and writes: the learned skills, cooldowns, delay groups,
  toggle skills, empower points and mastery.
- Z20 is the skill tables (`SkillDataBox`, `SkillDataIndex`, `ActiveSkill.shn`, `ToggleSkill.shn`, `ActiveSkillGroup.shn`).
- Z12 §6.5 covers `csl_Store` (DB → zone load) and the 0x103D client list; §7 here covers the DB and WM saves
  (`csl_FillSaveBuffer`, `csl_FillSendBuffer_Server`). Empower allocation and learn / unlearn requests are Z03 §9.

Time base: `g_Now` = `clockwatch.cw_CurrTick`, in **tenths of a second** (Z09 knowledge). Table times
(`ActiveSkill.DlyTime`, `DlyTimeGroup`) are milliseconds, so a cooldown of `t` ms ends at `g_Now + t·10/1000`.

## 1. Data structures

### 1.1 `CharaterSkillList` (player + 0x17d08, `ShinePlayer::sp_SkillList`)

```
class CharaterSkillList {                                      // 0x24
  0x00 vector<CharSkill>            csl_Skill;                 // {alloc, _Myfirst (= p+0x17d0c), _Mylast, _Myend}; sorted by cs_SkillId
  0x10 int                          csl_SkillNumber;           // entries in use (equals the vector size once loaded)
  0x14 vector<CharacterToggleSkill> csl_ToggleSkill;           // one entry per learned toggle-skill step, unsorted
};
struct CharaterSkillList::CharSkill {                          // 0x14
  0x00 u16           cs_SkillId;
  0x04 u32           cs_EndOfCooltime;                         // g_Now at which the skill is usable again
  0x08 SKILL_EMPOWER cs_Empower;                               // u16 bitfield: damage:4, sp:4, keeptime:4, cooltime:4 (bits 0-3, 4-7, 8-11, 12-15)
  0x0c u32           cs_Mastery;
  0x10 int           cs_bSave;                                 // 1 = the DB row had a non-zero cooltime (csl_Store); copied by csl_Learn
};
struct CharaterSkillList::CharacterToggleSkill {               // 4
  0x00 u16 cts_nSkillID;
  0x02 u8  cts_bSkillOn;                                       // 1 = toggled on; byte 3 is zero padding
};
```

- **Every learned step is its own entry.** `csl_Learn` FUN_0055b810 pushes the new step and does not remove the step
  named in its `DemandSk`; it copies that step's `cs_EndOfCooltime` and `cs_bSave` (a fresh skill gets `g_Now`, so it
  is usable at once) and starts empower and mastery at 0, then re-sorts with `CharSkill::cs_Compare_STLVer` (by ID)
  and calls `csl_Toggle_Store` (§2.2). The toggle list therefore also holds every learned step of a toggle skill.
- Lookups use `std::_Lower_bound` on the sorted vector (`csl_GetSkillStruct` FUN_004465b0 and the inlined copies in
  `csl_SetCoolTime` / `csl_UpdateCoolTime`); a miss asserts `"… : Not learn"` and the call does nothing.
- `csl_Store` FUN_00449360 (DB load, W03/Z12): when `csl_SkillNumber == 0` it resizes `csl_Skill` to `nMaxNum` and
  **empties `csl_ToggleSkill`**; for each record it sets the cooldown end to
  `g_Now + max(0, cooltime − difftime(now, savetime))·10` (the saved cooltime is in **seconds**), and calls
  `csl_Toggle_Store` for the skill. No toggle state is saved or loaded: after a login or a zone change every toggle
  skill is off.

### 1.2 `MoverSkillList` (mount + 0x1f54, `ShineMover::smv_MoverSkillList`)

```
class MoverSkillList { 0x00 vector<MoverSkill> msl_Skill; };   // 0x10, unsorted, linear search
struct MoverSkillList::MoverSkill { 0x00 u16 ms_SkillID; 0x04 u32 ms_EndOfCooltime; };   // 8
```

The skills of a `ShineMover` (mount object, Z13). Only cooldowns are kept; §3.5 has the functions. Who fills the
vector is part of the mover creation (§9, part 3).

### 1.3 Vtable slots used here

| Slot | ShinePlayer | Other classes (ShineMover, ShineMob) |
|---|---|---|
| 0x374 | `so_ply_NewSkillCoolTime` FUN_00569260 (sends 0x4821) | no-op |
| 0x3d8 | `so_ply_SilverWingCoolTime` FUN_005596b0 = `cec_SilverWingCoolTime_Minute · 60000` (ms) | – |
| 0xbc4 / 0xbc8 / 0xbcc / 0xbd0 | `so_ply_ToggleSkill_IsOn` / `_On` / `_Off` / `_AllOff` (§2.3) | folded stubs (`IsOn` returns 0, the others do nothing) |
| 0xbd4 | `so_ply_DmgCoolTimeDown` FUN_00579680 (§3.4) | no-op |
| 0xea8 | `smo_ply_SkillCoolTimeUpdate` FUN_005596f0 → `csl_UpdateCoolTime` | mover: FUN_0055e9e0 → `msl_UpdateCoolTime`; mob: no-op |
| 0xeac | `smo_ply_SkillCoolTime` FUN_0055b6a0 (§3.2) | mover: FUN_0054a770 → `msl_SetCoolTime`; mob: no-op |
| 0xf60 | `smo_ChineCastCut` FUN_005794d0 (§3.3) | no-op |
| 0x37c | `so_ply_InitSkillEmpow` FUN_00518c00 (§4, 0x900D) | – |
| 0x3a8 | `so_SaveSkill` FUN_00456520 (§7.2) | – |
| 0x624 | `so_LearnSkill` FUN_0055bbf0 (§6.3) | – |
| 0x6bc | `so_ply_skillempowerclear` FUN_0055a010 (§4) | – |
| 0x97c | `so_UnlearnSkillAck` FUN_0057f200 (§6.4) | – |
| 0xaec | `so_Send_NC_CHARSAVE_2WLDMAN_SKILL_CMD` FUN_00455780 (§7.3) | – |
| 0xecc | `smo_ply_ItemProduce` FUN_0046c2d0 (§5) | – |

## 2. Toggle skills

A toggle skill is an active skill with at least one `ToggleSkill.shn` row (`SkillDataIndex.sdi_ToggleData` non-empty,
Z20 §2.2). Casting it switches it on; casting it again switches it off. While it is on, its abnormal states stay on
the caster; the server switches it off by itself when the condition or the weapon no longer fits. 2016 data: only
`BurnPain01`–`06` (IDs 7300, 7745–7749): `TS_HPRATEOFF` with value 50 (HP must stay above 5 %), `DemandType` 1
(`DT_TWOHAND`), target `First` = 1 (ME), abstates `StaBurnPainMe` and `StaBurnPainFoe`, `DlyTime` 5000 ms,
`DlyGroupNum` 207, `CastTime` 0.

### 2.1 Condition: `csl_Toggle_CanUseSkill` and the weapon check

```pseudo
CharaterSkillList::csl_Toggle_CanUseSkill(list, s, o) → bool:          @ FUN_00445710
    if o == null: return false
    if s == null: assert "INVALID Skill"; return false
    if s.sdi_ToggleData is empty: return false                          # not a toggle skill
    for row in s.sdi_ToggleData:
        if row == null: return false
        if row.TS_Condition == TS_HPRATEOFF (0):
            if o.so_GetHP() (vt 0x4e8) <= o.so_MaxHP() (vt 0x4f0) * row.TS_Value / 1000: return false
        # other conditions: none exist (MAX_TOGGLESKILLENUM = 1); a row with another value is ignored
    weapon = o.so_ply_EquipWeapon(&o) (vt 0x7ac)                         # equipped weapon cell, or null
    return csl_Toggle_CanUseSkill_WeaponType(list, s, weapon ? weapon.itemID (+8) : 0xFFFF)

CharaterSkillList::csl_Toggle_CanUseSkill_WeaponType(list, s, itemId) → bool:   @ FUN_00444bd0
    if s == null or s.sdi_Activ == null: assert ("CharacterToggleSkillList::ctsl_CanUseSkill_WeaponType : …"); return false
    d = s.sdi_Activ.DemandType                                           # WeaponDemandType
    if itemId == 0xFFFF:  return d in {DT_NONE (6), DT_ALL (2)}          # no weapon equipped
    it = ItemDataBox[itemId]; null → assert "INVALID Item"; return false
    if it.Class not in {ITEMCLASS_WEAPON, ITEMCLASS_SHIELD}: return false
    switch d:
        DT_ONEHAND (0): it.TwoHand == 0          DT_TWOHAND (1): it.TwoHand == 1
        DT_ALL (2), DT_NONE (6): true            DT_WEAPON (3): it.Class == WEAPON
        DT_SHIELD (7): it.Class == SHIELD
        DT_HAMMER 4 / DT_MACE 5 / DT_BOW 8 / DT_CBOW 9 / DT_STAFF 10 / DT_WAND 11 / DT_CLAW 12 / DT_DSWORD 13 / DT_BLADE 14:
            it.WeaponType == WT_HAMMER / WT_MACE / WT_BOW / WT_CROSSBOW / WT_STAFF / WT_WAND / WT_CLAW / WT_DSWORD / WT_BLADE
        else: false
```

The same check gates the cast (Z03 §5.2: a toggle skill whose condition fails is refused with 0xFD5, "Failed to Cast
the Skill.", also when the cast would switch it off) and keeps it on (§2.4). The weapon is the one in the weapon
slot; a shield-only `DemandType` therefore never matches the shield in the off-hand *(inferred: `so_ply_EquipWeapon`
returns the weapon slot)*.

### 2.2 The toggle list

```pseudo
CharaterSkillList::csl_Toggle_Store(list, skillId):                     @ FUN_00448c60
    s = SkillDataBox[skillId]; null → assert "CharacterSkillList::csl_Toggle_Store : INVALID Skill Data"; return
    if s.sdi_ToggleData is empty: return
    on = 0
    if s.sdi_PrevSkill and s.sdi_PrevSkill.sdi_Activ:
        e = csl_Toggle_GetToggleSkill(list, s.sdi_PrevSkill.sdi_Activ.ID); if e: on = e.cts_bSkillOn   # a new step inherits the previous step's state
    list.csl_ToggleSkill.push_back({ skillId, on, 0 })                   # no duplicate check

CharaterSkillList::csl_Toggle_GetToggleSkill(list, id) → entry or null: @ FUN_00445680   (linear search)
CharaterSkillList::csl_Toggle_IsOn(list, id) → u8:                      @ FUN_004456c0
    first entry with cts_nSkillID == id → its cts_bSkillOn; none → 0

CharaterSkillList::csl_Toggle_SetOnOff(list, id, on):                   @ FUN_00448ce0
    if list.csl_ToggleSkill is empty: return
    s = SkillDataBox[id]; null → assert "CharacterSkillList::csl_Toggle_Store : INVALID Skill Data"; return
    for x = s; x; x = x.sdi_PrevSkill:                                   # the step and every lower step
        x.sdi_Activ null → assert "… INVALID Skill Activ PrevSkill"; return
        first entry with ID x.sdi_Activ.ID: cts_bSkillOn = on
    for x = s.sdi_NextSkill; x; x = x.sdi_PrevSkill:                     # meant: every higher step
        x.sdi_Activ null → assert "… INVALID Skill Activ NextSkill"; return
        first entry with ID x.sdi_Activ.ID: cts_bSkillOn = on
    # (original bug) Z23-B1: the second walk starts at the next step but follows sdi_PrevSkill, so it sets that one
    # step and then the same chain again; steps two or more above `id` keep their old flag
```

Because all learned steps are in the list and the client casts the highest learned step, the flag is normally set on
every learned step at once. A lower step cast (B1) leaves the higher steps unchanged.

### 2.3 Player wrappers and packets

```pseudo
ShinePlayer::so_ply_ToggleSkill_IsOn(p, id) = csl_Toggle_IsOn(p.sp_SkillList, id)          @ FUN_005794f0   (vt 0xbc4)

ShinePlayer::so_ply_ToggleSkill_On(p, s, empower):                                           @ FUN_00579500   (vt 0xbc8)
    s null → assert "ShinePlayer::so_ply_ToggleSkill_On : INVALID Skill"; return
    if p.so_AbnormalState_IsSet(STA_IMMORTAL 291) or p.so_AbnormalState_IsSet(STA_ADLFLOUSSIERIMT 499): return   # stays off, no packet
    csl_Toggle_SetOnOff(p.sp_SkillList, s.ID, 1)
    p ← 0x245C NC_BAT_TOGGLESKILL_ON_CMD { u16 nSkillID = s.ID }                             # to the player only (vt 0x2fc stream)
    # `empower` is not used

ShinePlayer::so_ply_ToggleSkill_Off(p, s):                                                   @ FUN_005795d0   (vt 0xbcc)
    s null → assert "… : invalid spell"; return
    csl_Toggle_SetOnOff(p.sp_SkillList, s.ID, 0)                                             # no check that it was on
    p ← 0x245D NC_BAT_TOGGLESKILL_OFF_CMD { u16 nSkillID = s.ID }

ShinePlayer::so_ply_ToggleSkill_AllOff(p) = csl_Toggle_AllOff(p.sp_SkillList, p)           @ FUN_00579670   (vt 0xbd0; no caller found)
```

Neither wrapper touches the abnormal states; they are set and removed by the blast (§2.5). Both packets are
2 bytes (`PROTO_NC_BAT_TOGGLESKILL_ON_CMD` / `_OFF_CMD { ushort nSkillID }`, same in the 2016 and 2017 PDBs).

Client (`GameFrameWork`, 2016 client):

- `On_NC_BAT_TOGGLESKILL_ON_CMD` FUN_0049ce60: `ShortCutWin::OnToggleKey(nSkillID)` on all ten shortcut bars (marks the
  slot as active).
- `On_NC_BAT_TOGGLESKILL_OFF_CMD` FUN_004a5b70: `ShortCutWin::OffToggleKey(nSkillID)` on the same bars, then
  `Skill::RecordSkillUse(nSkillID, now)`: the client starts its own cooldown display **when the skill is switched off**,
  whoever switched it off. The server sets its cooldown only when the off-switch comes from a cast (§3.1), so after an
  automatic switch-off (§2.4) the client waits out a cooldown the server does not enforce.

### 2.4 Automatic switch-off

```pseudo
CharaterSkillList::csl_Toggle_CheckOnOff(list, p):                      @ FUN_00448e20   (every player tick, Z09 §2.1)
    if p == null or p.so_IsEmpty() (vt 0x300): return
    for e in list.csl_ToggleSkill with e.cts_bSkillOn != 0:
        s = SkillDataBox[e.cts_nSkillID]; null → skip
        if not csl_Toggle_CanUseSkill(list, s, p):                       # HP fell to the limit, or the weapon changed
            RemoveSkillAbstates(p, s)
            p.so_ply_ToggleSkill_Off(s)  (vt 0xbcc)                       # 0x245D; switches the whole step chain off

CharaterSkillList::csl_Toggle_AllOff(list, p):                          @ FUN_00448f30
    if p == null: return
    for e with cts_bSkillOn != 0 and a SkillDataIndex: p.so_ply_ToggleSkill_Off(s)          # abstates are kept

CharaterSkillList::csl_Toggle_AllOffAndReset(list, p):                  @ FUN_00448fa0
    if p == null: return
    for e in list.csl_ToggleSkill (on or not) with a SkillDataIndex s:
        p.so_ply_ToggleSkill_Off(s)                                       # 0x245D for every learned step
        RemoveSkillAbstates(p, s)
    # (original bug) Z23-B2: does not test cts_bSkillOn: one 0x245D per learned toggle step even when the skill was
    # never on (BurnPain06 learned = six packets), and each makes the client start the skill's cooldown display (§2.3)

RemoveSkillAbstates(p, s):        (inlined in the three functions above and in so_SkillEnchant)
    for i in 0..3 with s.sdi_Abstate[i].abstateidx != MAX_ABSTATEINDEX (792):
        if p.so_mobile_AbstateList() (vt 0x52c).asl_Abstate_IsSet(idx):
            p.so_AbnormalState_Reset(idx) (vt 0x650); so_AbnormalState_BitReset(p, idx); so_AbnormalState_BroadcastReset(p, idx)
    # removes the state whatever set it (the same abstate from another source is removed too)
```

Callers:

| Caller | Call | When |
|---|---|---|
| `ShinePlayer::so_Routine` FUN_0056c790 (Z09 §2.1) | `csl_Toggle_CheckOnOff` | every tick |
| `ShinePlayer::so_LinkTo` FUN_0049ad30 (Z01 / Z09) | `csl_Toggle_AllOff` | both link-out branches: in the same-server branch after the link packet to the client and before the game stream is replaced by the dummy container; in the other branch after the save to DB / WM and before 0xC809. The player gets 0x245D for each skill that was on; the abstates are not removed (see §Not reconstructed) |
| `sp_NC_ACT_PITCHTENT_REQ` FUN_00457760 (Z02) | `csl_Toggle_AllOffAndReset` | the tent shape was built (just before mode 4 is set) |
| `sp_NC_MOVER_RIDE_ON_REQ` FUN_00563270 (Z09 mover section) | `csl_Toggle_AllOffAndReset` | the mount is visible and within 300 units, before `sp_MoverSystem_GetOn` |
| `sp_MoverSystem_Cast` FUN_0045d550 (mount item cast, Z13) | `csl_Toggle_AllOffAndReset` | the mount item is valid, before the 0x2047 ride cast starts |

### 2.5 Switching by cast

The cast is the normal skill path (Z03 §5.2–5.4); toggle skills add three steps:

```pseudo
# 1. request 0x2440, Z03 §5.2 (sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ @ FUN_0057fa50)
    if s.sdi_ToggleData not empty and not csl_Toggle_CanUseSkill(p.sp_SkillList, s, p): → 0xFD5

# 2. blast, second pass (smo_SkillBash_Blast @ FUN_0057cd40, Z03 §5.4), after the movement specials:
    if s.sdi_ToggleData not empty:
        if o.so_ply_ToggleSkill_IsOn(cast.scs_Skill) == 1:  o.so_ply_ToggleSkill_Off(s)      # 0x245D
        else:                                               o.so_ply_ToggleSkill_On(s, empower)   # 0x245C (not when immortal)
        smo_SkillResultPacket(o, s, target.pos)
    # then the usual 0x2457 HIT_BLAST and sbec_Store

# 3. effect, per hit target (so_SkillEnchant @ FUN_00431ca0, called from the blast effect, Z03 §5.6 E):
    if s.sdi_ToggleData not empty:
        s.sdi_Activ null → skip
        if not caster.so_ply_ToggleSkill_IsOn(s.ID):                   # it was just switched off
            RemoveSkillAbstates(caster, s); return                       # no abstate roll
    # on (or not a toggle skill): the normal abstate roll on the target (Z03 §5.6 E)
```

So the "on" cast applies the skill's abstates like any buff, and the "off" cast removes them from the caster. Because
the target of BurnPain is the caster (`First` = ME), both happen on the same object.

## 3. Cooldowns and delay groups

### 3.1 When a cast sets the cooldown

`ShineMobileObject::so_Routine` FUN_0056a080 (every tick, for every mobile object; Z03 §5.4) after the blast call.
`InSkillShift` is `smo_Flag` bit 0x10 (`obj+0x1e78`): set on the first pass of a two-phase blast (the "arming" pass,
Z03 §5.4), clear on the pass that really hits.

```pseudo
    # before: the produce branch (recipe set) and the item branch (UseItem set) return early, see the table in §3.6
    count blast statistic (vt 0x428 +0x10)                                # Z16
    reduction = e.cooltime ? s.sdi_Activ.nT3[e.cooltime − 1] : 0          # e = cast.scs_Empower; nT3 = ActiveSkill "Cool Time" empower column (ms)
    if s.sdi_ToggleData is empty:
        setCd = smo_SkillCooltimeSet(o)                                   # false on the arming pass or when an IgnoreCoolTime state is consumed (§3.3)
    else:
        setCd = not o.so_ply_ToggleSkill_IsOn(cast.scs_Skill)             # toggle: cooldown only when the cast switched it off
    if setCd and not o.smo_Flag.InSkillShift:
        o.smo_ply_SkillCoolTime(skill, s.DlyTime, s.DlyGroupNum, s.DlyTimeGroup, reduction)   (vt 0xeac, §3.2)
    if not o.smo_Flag.InSkillShift:
        cast.scs_BlastTime = 0                                            # cast finished
        o.notifyObservers(2, skill, 0) (vt 0xa38)                         # script/quest observers (Z15)
    o.smo_ply_NextBashTime_AfterSkill(s.sdi_ServInf.SwingTime) (vt 0xec4)
    if s is "UseRide" (cached in DAT_00869290): cast.scs_BlastTime = 0
```

So switching a toggle skill on costs no cooldown; switching it off by cast starts the full cooldown (BurnPain: 5 s).
For a toggle skill the IgnoreCoolTime check (§3.3) is not made.

### 3.2 Setting: `smo_ply_SkillCoolTime` and `csl_SetCoolTime`

```pseudo
ShinePlayer::smo_ply_SkillCoolTime(p, skill, dly, group, groupDly, reduction):              @ FUN_0055b6a0   (vt 0xeac)
    if p.sp_isIgnoreSkillCoolTime (sp_IsIgnoreCoolTime FUN_00560210; GM &ignoreskillcooltime, Z11 §8.5):
        p.so_ply_NewSkillCoolTime(skill, 0) (vt 0x374)                    # 0x4821 { skill, sec = 0 }; no cooldown stored
        return
    changed = false
    r = setitemskilleffect[SET_COOLTIMERATE]                              # set-item rate (‰), loaded by smo_ply_SetItemEffect (vt 0xef8)
    if r != 1000: dly = r·dly/1000; groupDly = r·groupDly/1000; changed = true
    if p.so_GetItemActionObserves() (vt 0x5d0) and s = SkillDataBox[skill] has sdi_ActiveSkillGroups:
        if ItemActionObserveManager::EventRunBySkillGroupIndex(mgr, &res, s, SEIT_COOLTIME_RATE_DECREASE, p, null):
            dly = res.GetRateAppliValue(dly); groupDly = res.GetRateAppliValue(groupDly); changed = true   # item actions (Z17)
    csl_SetCoolTime(p.sp_SkillList, skill, dly, group, groupDly, reduction)
    if changed: p ← 0x4821 NC_SKILL_COOLTIME_CMD { u16 skill, u32 sec = (int)(dly − reduction) / 1000 }
    # unchanged: no packet; the client runs the cooldown from its own ActiveSkill table

CharaterSkillList::csl_SetCoolTime(list, skill, dly, group, groupDly, reduction):            @ FUN_00448ab0
    c = lower_bound(skill); none → assert "CharaterSkillList::csl_SetCoolTime : Not learn"; return
    c.cs_EndOfCooltime = g_Now + (int)((dly − reduction)·10)/1000 − 3                        # 0.3 s early
    for each entry x (csl_SkillNumber entries) with x.cs_SkillId != skill:
        if csl_GetDelayGroup(list, x.cs_SkillId, &unused) == group:
            end = g_Now + (int)((groupDly − reduction)·10)/1000 − 3
            if x.cs_EndOfCooltime < end: x.cs_EndOfCooltime = end                             # only lengthens
    # (original bug) Z23-B3: group 0 means "no group" for 1230 of the 2791 2016 skills but is matched like any group:
    # casting a group-0 skill with DlyTimeGroup > 0 (MineMelee_W / EggMelee_W 5 s, MineRange_W / EggRange_W 15 s) puts
    # every other learned group-0 skill on that cooldown. With DlyTimeGroup 0 the end is g_Now − 3, which never lengthens.

CharaterSkillList::csl_GetDelayGroup(list, skillId, &groupDly) → int:  @ FUN_00448950
    s = SkillDataBox[skillId]
    if s: groupDly = s.DlyTimeGroup; return s.DlyGroupNum
    if bsearch(recipebook (0x4c-byte rows), skillId) (a produce "skill"): groupDly = 0; return 0
    assert "CharaterSkillList::csl_GetDelayGroup : Cannot found Skill"; return −1                # groupDly untouched

ShinePlayer::so_ply_NewSkillCoolTime(p, skill, sec):                    @ FUN_00569260   (vt 0x374)
    p ← 0x4821 NC_SKILL_COOLTIME_CMD { u16 skill, u32 sec }                                  # 6 bytes, to the player
```

The `− 3` (0.3 s) matches the 0.3 s arming delay of the two-phase blast (Z03 §5.4), so a skill recast right after the
client's own cooldown ends is not refused *(inferred)*. The subtraction `dly − reduction` is done in unsigned 32-bit
and the product with 10 is cast to `int`, so a reduction larger than the delay gives a negative offset (the end lies
in the past), not a huge one.

Client: `GameFrameWork::On_NC_SKILL_COOLTIME_CMD` FUN_0049a9e0: `Skill::SetLastCoolTime(skill, (float)(u32)sec)`
(the cooldown display of that skill; `sec` is read unsigned).

### 3.3 IgnoreCoolTime abstates ("chain cast")

```pseudo
ShineMobileObject::smo_SkillCooltimeSet(o) → bool (true = set the cooldown):   @ FUN_0057c5b0
    if o.smo_Flag.InSkillShift: return false
    o.smo_Flag.ChineCast (bit 0x40) = 0
    for each active element e of o.smo_Abstate.abstatelist:
        if abstateidentarray[e.aeo_Index].actor.vt[0x20](e):          # true only for SubAbnormalStateActorIgnoreCoolTime
            o.smo_Flag.ChineCast = 1
            o.smo_ChineCastCut() (vt 0xf60)
            return false                                               # this cast sets no cooldown
    return true

ShinePlayer::smo_ChineCastCut(p):                                       @ FUN_005794d0   (vt 0xf60; no-op for other classes)
    p.flag1e78 |= 0x40; sp_ChineCastCut(p); p.flag1e78 &= ~0x40

ShinePlayer::sp_ChineCastCut(p):                                        @ FUN_00436e80
    if not (p.flag1e78 & 0x40): return
    p.flag1e78 &= ~0x40
    for each active element e of the abstate list (p+0xe80 size, +0xe84 array of {content, u16 next, u8 active}, +0xe8a head):
        if its actor.vt[0x20](e): e.endTime (+0x20) = g_Now                   # expires on the next abstate tick (→ 0x2428 erase, Z03 §6.4)
```

The actor class `SubAbnormalStateActorIgnoreCoolTime` (index string "IgnoreCoolTime", the `ac_COOLTIMEREMOVE` member
of the actor table) is the only one whose slot 0x20 returns 1 (FUN_00500380); all others return 0 (FUN_00615e70).
Effect: while the caster has such a state, the next non-toggle skill blast sets no cooldown and consumes the state. The
abnormal states that carry the `COOLTIMEREMOVE` sub-state are data (`SubAbState.shn`, Z03 §6).

`smo_ChineCastCut` is also called from the blast for `SS_WARPING` skills (Z03 §5.4, after `smo_WarpForward`), where it
consumes the IgnoreCoolTime states without the cooldown check.

### 3.4 Shortening: damage taken, item-set rates, charged buffs

```pseudo
ShinePlayer::so_ply_DmgCoolTimeDown(p) = csl_DmgCoolTimeDown(p.sp_SkillList)      @ FUN_00579680   (vt 0xbd4)
CharaterSkillList::csl_DmgCoolTimeDown(list):                           @ FUN_00449080   (profiler string "csl_SufferingAttack_CoolTimeMinus")
    for each entry x with g_Now < x.cs_EndOfCooltime:
        s = SkillDataBox[x.cs_SkillId]
        if s and s.sdi_DMGCOLLTIMEDOWN.exist == 1:
            x.cs_EndOfCooltime −= s.sdi_DMGCOLLTIMEDOWN.value · 10 / 1000          # value in ms; < 100 has no effect
    # no packet: the client's cooldown display is not shortened
```

Called on the victim for every hit: `ShineMobileObject::smo_AttackedDamage` FUN_0042aeb0 (basic attacks, Z03 §3) and
`SkillDamageSender::sds_TemplateStore` FUN_005803c0 (skill hits, both the damage and the non-damage branch; Z03
§5.6). 2016 data: `SS_DMGCOLLTIMEDOWN` (46) only on `GroundStrike01`–`06` (value 1000: each hit taken shortens the
24 s cooldown by 1 s).

```pseudo
ShinePlayer::smo_ply_SkillCoolTimeUpdate(p, skill, end) = csl_UpdateCoolTime(...)   @ FUN_005596f0   (vt 0xea8)
CharaterSkillList::csl_UpdateCoolTime(list, skill, end) → bool:         @ FUN_004468c0
    c = lower_bound(skill); none → assert "CharaterSkillList::csl_UpdateCoolTime : Not learn"; return false
    if end < c.cs_EndOfCooltime: c.cs_EndOfCooltime = end; return true                  # only shortens
    return false
```

Only caller: `ShinePlayer::so_ply_ChargedBuff` FUN_005970c0 (Z12) after a charged buff changed the silver-wing
cooldown: `if csl_UpdateCoolTime(0x7210 UseSilverWings, g_Now + SilverWingCoolTime·10/1000): p ← 0x4821 { 0x7210,
SilverWingCoolTime / 1000 }`.

### 3.5 Mount skills: `MoverSkillList`

```pseudo
MoverSkillList::msl_CoolTimeCheck(l, id) → bool:                        @ FUN_004463d0
    first entry with ms_SkillID == id → ms_EndOfCooltime <= g_Now
    none → assert "MoverSkillList::msl_CoolTimeCheck : Did not learn skills"; false

MoverSkillList::msl_UpdateCoolTime(l, id, end) → bool:                  @ FUN_00446370   (via ShineMover vt 0xea8 FUN_0055e9e0; no caller found)
    first entry: if end < ms_EndOfCooltime: ms_EndOfCooltime = end; true; else false
    none → assert "… : Did not learn skills"; false

ShineMover::smo_ply_SkillCoolTime(m, skill, dly, group, groupDly, reduction) = msl_SetCoolTime(…, no reduction)   @ FUN_0054a770 (vt 0xeac)
MoverSkillList::msl_SetCoolTime(l, id, dly, group, groupDly):           @ FUN_00449270
    x = first entry with ms_SkillID == id; none → assert "… : Did not learn skills"; return
    x.ms_EndOfCooltime = g_Now + dly·10/1000 − 3
    for each entry y (including x):
        s = SkillDataBox[y.ms_SkillID]; null → assert "Skill data null"; s.sdi_Activ null → assert "ActiveSkillInfo data null"
        else if s.DlyTimeGroup == group and y.ms_EndOfCooltime < g_Now + groupDly·10/1000 − 3: raise it
    # (original bug) Z23-B4: compares the other skill's DlyTimeGroup (a time in ms) with the group number; the
    # player version compares DlyGroupNum. The empower reduction is ignored (mounts have none).
```

No set-item rate, no item actions, no 0x4821 (a mount has no client session of its own). Users:
`so_smv_SkillBash_Object` FUN_00580800 and `so_smv_SkillBash_Location` FUN_00580cf0 check `msl_CoolTimeCheck` (part 3,
§9); the mover's cast completion goes through the same `so_Routine` §3.1 (vt 0xeac → `msl_SetCoolTime`).

### 3.6 Other callers that set or check skill cooldowns

The skill list is also the cooldown store for item "pseudo-skills" (rows 29200–29205 of `ActiveSkill.shn`:
`UseSilverWings`, `UseStageRecallScroll`, `UseSkill`, `UsePotion`, `UsePresentBox`, …; Z12 §6.5 lists them) and for
produce recipes. They pass group 0 / group delay 0 / no reduction, so the group loop of §3.2 never lengthens anything.

| Caller | Skill | Cooldown passed to vt 0xeac | Extra 0x4821 |
|---|---|---|---|
| `so_Routine` FUN_0056a080, produce cast (recipe set) | the recipe skill | `DlyTime` | – (only if a rate applied, §3.2); then `smo_ply_ItemProduce` (Z07) |
| `so_Routine`, item cast, silver wing (`idb_specialid.sii_silverwing`) | cast skill | `so_ply_SilverWingCoolTime()` (ms) | `{ skill, sec = SilverWingCoolTime }` **in ms** (original bug) Z23-B5 |
| `so_Routine`, other item casts | cast skill | `scs_UseItem.cooltime_millisec` | – |
| `GameDBSession::gds_NC_ITEMDB_MAPLINK_ITEM_CONSUME_ACK` FUN_004698a0 (Z05 §8.5), err 0x3748 | `skillID` of the answer | `skillCoolTime` | `{ skillID, skillCoolTime / 1000 }` |
| `ShinePlayer::sp_PetSystem_Summon` FUN_004d2640 (Z13) | `ui_Pet` summon skill | `gPetData.m_nSummonCoolTimeMil` | `{ skill, ms / 1000 }` |
| `ShinePlayer::sp_HorseOn` FUN_0045f270 (Z12 / Z13) | `ui_ride` skill | 10000 on one branch, the ride item's time on the other | – |
| `ShinePlayer::sp_MoverSystem_SummonItem` FUN_0045ec10 (Z12 / Z13) | `ui_ride` skill | ride time − `MoverUpgradeEffect.CastingCoolTime` ‰ | – |
| `ShinePlayer::so_ply_ChargedBuff` FUN_005970c0 (Z12) | 0x7210 UseSilverWings | via `csl_UpdateCoolTime` (§3.4) | `{ 0x7210, ms / 1000 }` when shortened |
| `SkillDamageSender::sds_Finish` FUN_00437110 (Z03) | blast skill | – | `{ skill, 0 }` to a caster with `sp_isIgnoreSkillCoolTime` (GM) |

When `smo_ply_SkillCoolTime` applies a rate (§3.2) it sends 0x4821 with the shortened time and the map-link / pet
callers then send their own 0x4821 with the unshortened time; the client keeps the last one (original bug) Z23-B6.

Checks (`csl_CoolTimeCheck` FUN_0046a420: `lower_bound(skill)`; not learned → assert "Invalid skill id" and **false**;
else `cs_EndOfCooltime <= g_Now`). "False" therefore means "not learned or still cooling down"; the callers do not
tell the two apart:

| Caller | Refusal |
|---|---|
| `sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ` FUN_0057fa50 / `_FLD_CAST_REQ` FUN_0057f400 (Z03 §5.2 / §5.5) | 0xFC8 "Cannot use the skill yet." |
| `sp_NC_ACT_PRODUCE_CAST_REQ` FUN_0046cf90 (Z02 §8: its "does not know the skill" also covers the cooldown) | 0x0B08 |
| `sp_ItemUseReq_Inven` FUN_0053f5e0, `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90, `sp_NC_ITEM_MAPLINK_SCROLL_REQ` FUN_00520130 (Z04) | 0x70D "Cannot use the item yet." (Z04 §6.1); 0x3130 in 0x304E (Z04 §12.7) |
| `sp_SilverWing_PortalCast` FUN_00597b30 | 0x70D via vt 0x91c (dept 9) |
| `UseItemRide::uib_CanUseItem` FUN_005988b0 (Z04 / Z13) | 0x10C2 (only when the ride skill is learned: `csl_GetSkillStruct` first) |
| `sp_UseItemMonimon_UseItem` FUN_00561b80 (minimon auto-use, Z09 §2.3 / Z13) | the item is skipped |

## 4. Empower points

`SKILL_EMPOWER` (u16, `cs_Empower` at `CharSkill`+8) holds four 4-bit counters: `damage` (bits 0–3), `sp` (4–7),
`keeptime` (8–11), `cooltime` (12–15). Each learned step has its own counters (§1.1); every reader adds up the steps
of one skill line. The cast path uses them through `csl_SPCheck` and `smo_SkillBash_Casting` (Z03 §5.3 / §5.6:
index = points − 1 into the `nT0…nT3` columns). Allocation is
`sp_NC_SKILL_EMPOWALLOC_REQ` 0x4811 + `csl_EmpowerAlloc` (Z03 §9.1); this section adds the list functions and two
corrections to that section.

```pseudo
CharaterSkillList::csl_MaximumSkill(this, u16 skill) → u16                                    @ FUN_00448240
    e = skilldatabox[skill]                          # SkillDataBox::operator[] FUN_00448140: bsearch, null if unknown
    while e.sdi_NextSkill: e = e.sdi_NextSkill        # no null check of the first e (original bug) Z23-B9
    return e.sdi_Activ.ID                             # the TOP step of the line in ActiveSkill.shn, learned or not

CharaterSkillList::csl_EmpowerStruct(this, u16 top, SKILL_EMPOWER* out)                       @ FUN_004482c0
    *out = {0,0,0,0}
    for e = skilldatabox[top]; e; e = e.sdi_PrevSkill:          # every step of the line, top down
        s = lower_bound(csl_Skill, e.sdi_Activ.ID); if s is an exact hit:
            out.damage += s.damage; out.sp += s.sp; out.keeptime += s.keeptime; out.cooltime += s.cooltime
            # each sum is kept in its 4-bit field: it wraps at 16
    for each field f: if out.f > 5: assert "csl_EmpowerStruct : Too many empow.damage" (the same text for all four), out.f = 5
    # callers: csl_SPCheck FUN_0055b920 (cast, Z03 §5.3) and csl_EmpowerAlloc FUN_00448570, both with
    # csl_MaximumSkill(skill): the result is the sum over all learned steps of the line, capped at 5 per field

CharaterSkillList::csl_EmpowerSummary(this) → int                                             @ FUN_00445070
    return Σ over csl_Skill[0 … csl_SkillNumber−1] of damage + sp + keeptime + cooltime     # points spent, no cap
    # callers: so_charskilldata FUN_0044bf20 (0x103D restempow, Z12), sp_NC_SKILL_EMPOWALLOC_REQ FUN_0044f150 (Z03 §9.1),
    # sp_GainExp FUN_0042d830 / so_AmpersandCommand_LevelUp FUN_0042fa00 (free points after a level-up, Z12 / Z03 §8),
    # so_ply_InitSkillEmpow FUN_00518c00 (below). Free points = so_ply_TotalSkillEmpower (vt 0x6b8, FUN_00559fd0, Z12) − this.

CharaterSkillList::csl_EmpowerClear(this)                                                    @ FUN_00445190
    for every entry of csl_Skill: cs_Empower = {0,0,0,0}         # memory only; the DB was reset before (callers below)
```

`csl_EmpowerAlloc` FUN_00448570, as read (Z03 §9.1 shortens it):

```pseudo
    cur = csl_EmpowerStruct(csl_MaximumSkill(req.skill))          # sum of the line (above), not one step's bits
    fail ("Too many point1…4") unless cur.f + plus.f ≤ 5 for every field f
    fail ("Too many point5…8") if minus.f > cur.f for some f
    s = csl_GetSkillStruct(req.skill); null → "Not learn", fail
    s.f = s.f + plus.f − minus.f  (4-bit, per field)             # the request's own step, not the line sum
    *out = s.cs_Empower; return true                              # the 0x4812 DB request carries *out (D04: the DB refuses any field > 5)
```

- The limit is per **line** (5 per field over all learned steps), but the points are stored on the step named in the
  request. Points given while a lower step was the highest one stay on that lower step's entry; `csl_Learn` starts the
  new step at 0 (Z20 §5.2). `minus` is checked against the line sum and subtracted from the request's step, so taking
  back such a point through the new step wraps that field to 15; the DB then refuses the row (`p_Skill_SetPowerAll`,
  value > 5 → 0x885) and the zone disconnects the player (0x68A, Z03 §9.1) (original bug) Z23-B8. Which step ID the
  2016 client puts in `req.skill` is not read here *(inferred: the highest learned step shown in the skill window)*.
- An unknown `req.skill` reaches `csl_MaximumSkill` without any check in `sp_NC_SKILL_EMPOWALLOC_REQ` (only the mode,
  the plus/minus overlap, the item count and the point total are checked first): `skilldatabox[skill]` is null and the
  first `sdi_NextSkill` read faults; one 0x4811 with all-zero plus/minus from any player in a normal mode is enough
  (original bug) Z23-B9.

Resets (both clear every entry's counters in memory after the DB has reset them):

| Path | Function | Then |
|---|---|---|
| empower-reset item: GameDB 0x480D NC_SKILL_EMPOW_RESET_DB_SUC_ACK (Z03 §9.2) | `ShinePlayer::so_ply_skillempowerclear` FUN_0055a010 (vt 0x6bc) = `csl_EmpowerClear` | 0x480F { u8 totalempow } |
| charged item: GameDB 0x9008 NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_SUC_ACK FUN_00518780 (Z08) | `ShinePlayer::so_ply_InitSkillEmpow` FUN_00518c00 (vt 0x37c): `csl_EmpowerClear`, then send 0x900D NC_CHARGED_SKILLEMPOW_INITIALIZE_SUC_CMD { u8 = vt 0x6b8() − csl_EmpowerSummary() } (3 bytes) | client `GameFrameWork::On_NC_CHARGED_SKILLEMPOW_INITIALIZE_SUC_CMD` FUN_0049b330: `Skill::ClearLearnActSkillInfo`, `Skill::SetRestEmpowerPoint(u8)`, `SkillIcon::RefreshSkillInfoAll` |

## 5. Mastery (production skills)

`cs_Mastery` (u32, `CharSkill`+0xc) is the experience of a **produce recipe skill** (one `ActiveSkill` row per
recipe, `RecipeBook` row `ProduceInfo.ProductID` = the skill). It is loaded and saved with the list (§7, Z12) and only
grows.

```pseudo
CharaterSkillList::csl_AddMastery(this, ShinePlayer* p, u16 skill, int gain)                 @ FUN_00446730
    s = lower_bound(csl_Skill, skill); not an exact hit: assert "csl_AddMastery : Not learn"; return
    s.cs_Mastery += gain                             # no cap, u32
    s.cs_bSave = 1                                   # include it in the next incremental DB save (§7.2)
    send p: 0x481D NC_SKILL_SKILLEXP_CLIENT_CMD { u16 skill, u32 mastery = s.cs_Mastery }   # 8 bytes with opcode

# only caller: ShinePlayer::smo_ply_ItemProduce FUN_0046c2d0 (vt 0xecc, Z07: produce cast finished), after
# ip_ProduceCheck == 0xB01 and the GameDB 0x3457 produce request was sent:
    csl_AddMastery(p.sp_SkillList, p, recipeSkill,
                   (u16 sp_ChargedItem.ci_Effect.cec_ProductMasteryRate · recipe.index.MasteryGain) / 1000)
                   # ‰ rate of the charged-item effects (Z12); the gain is applied before the DB answers the produce
```

Client: `0x481D` is handled only by `ProductTask::OnProcessNetMsg` FUN_00487400 (dept 0x12 cmd 0x1D):
`Skill::GetLearnProductSkill` FUN_0069edd0 looks the skill up in the client's learned production list (`DAT_00b44fc0`,
8-byte rows, count `DAT_00b50b5c`) and stores `mastery` at +4; unknown skill → ignored. No text.

Readers of the mastery: `csl_PreProduceCheck` (§6.2, recipe scroll), the produce checks of Z07/Z02, the 0x103D list
(Z12) and the saves (§7).

## 6. Learn, unlearn, load

### 6.1 Membership tests

```pseudo
CharaterSkillList::csl_IsLearn(this, u16 skill) → bool                                       @ FUN_00446630
    return lower_bound(csl_Skill, skill) is an exact hit          # same search as csl_GetSkillStruct FUN_004465b0 (§1.1)

CharaterSkillList::csl_PreSkillCheck(this, ShinePlayer* p, char* demandSk) → bool            @ FUN_00447110
    if demandSk[0] == '-': return true                            # no prerequisite
    v = skillnametree[demandSk]                                   # Z20 §5.2; unknown name → 0xFFFFFFFF, skill 0xFFFF
    return csl_IsLearn(v.skill)                                   # ispassive ignored
```

`csl_IsLearn` callers: `csl_Learn` FUN_0055b810 (Z20 §5.2), `csl_PreSkillCheck`, `csl_PreProduceCheck` (§6.2),
`uib_CanUseItem` FUN_0059d1b0 (§6.2), `sp_NC_SKILL_PRODUCTFIELD_REQ` FUN_0046c820 / `sp_NC_SKILL_UNLEARN_REQ`
FUN_0057ad80 (Z03 §9.4 / §9.5), `sp_NC_ITEM_CLASS_CHANGE_REQ` FUN_0051f5c0 / `sp_OpenClassChangeMenu` FUN_0051fd10
(Z04 / Z15 / Z20), `sp_NC_MINIHOUSE_BUILDING_REQ` FUN_005769d0 (Z07), `AmpersandCommand::ac_AllLearnSKill` FUN_004212e0
(Z11 / Z20).

### 6.2 Skill scroll: `UseItemSkillScroll::uib_CanUseItem`

The skill-book item's "can use" check (Z04 §6 use-effect classes; the effect itself, `uib_Effect` FUN_00599d30, sends
the GameDB 0x4801 NC_SKILL_SKILLTEACH_REQ, Z20 §5.2 / Z03 §9.3). The return value is the item-use result code.

```pseudo
UseEffect::UseItemSkillScroll::uib_CanUseItem(this, ShinePlayer* p, ItemTotalInformation* item) → u16   @ FUN_0059d1b0
    row = itemdatabox[item.itemid]; null (or ID mismatch "ItemDataBox::operator [] :Invalid Item index"):
        assert "sp_uie_skillscroll : Invalid item";                          return 0x702
    v = skillnametree[row.InxName]                       # the scroll's item InxName = the skill's InxName
    v == 0xFFFFFFFF: assert "sp_uie_skillscroll : Cannot found matched skill"; return 0x702
    if not v.ispassive:
        if csl_IsLearn(v.skill):                                             return 0x70B   # "You already have the skill."
        e = skilldatabox[v.skill]; null: assert "sp_uie_SkillScroll_CanUse : Invalid Activ"; return 0x702
        recipe = recipebook[v.skill]                     # GatherProduce::RecipeBook::operator[]
        if recipe: return csl_PreProduceCheck(p.sp_SkillList, p, v.skill, recipe)
        return csl_PreSkillCheck(e.sdi_Activ.DemandSk) ? 0x700 : 0x70C      # 0x70C "You must get the previous level skill(s) first."
    else:                                                # passive scroll
        if bit v.skill of p.sp_Passive.cpl_Passive.bs_bitlist:              return 0x70B
        info = passivedatabox.pdb_index[v.skill] (id ≥ pdb_maxpassiveID → pdb_default); null:
            assert "sp_uie_SkillScroll_CanUse : Invalid Passive";            return 0x702
        return CharacterPassiveList::cpl_PreSkillCheck(info.DemandSk) (FUN_00445810, Z20) ? 0x700 : 0x70C

CharaterSkillList::csl_PreProduceCheck(this, ShinePlayer* p, u16 skill, ProductIndex* recipe) → u16   @ FUN_0046ab70
    if recipe == null:                                                       return 0x702
    main = by recipe.index.MasteryType:  MT_STONE → sdb_SpecSkill.ss_StoneProductMain, MT_PORTION → ss_PortionProductMain,
           MT_SCROLL → ss_ScrollProductMain, MT_COMPOUND → ss_CompoundProductMain, MT_RESOLVE → ss_ResolveProductMain
           MT_SUMMON, MT_COOK, other: assert "csl_PreProduceCheck : Wrong mastery type"; return 0x702
    if not csl_IsLearn(p.sp_SkillList, main):                                return 0x717   # "Selected Production Skill cannot be learned."
    total = 0
    for i in 0 … recipebook.rb_Number−1:                 # every recipe of the game (rows of 0x4C)
        r = recipebook.rb_Array[i]
        s = csl_GetSkillStruct(r.index.ProductID)
        if s and r.index.MasteryType == recipe.index.NeededMasteryType: total += s.cs_Mastery
    return total < recipe.index.NeededMasteryGain ? 0x711 : 0x700            # 0x711 "You need more skill experience to learn the selected skill."
```

`0x700` is success (no text); the other texts are from `client-error-codes.json`. `skill` is not used by
`csl_PreProduceCheck`. The production base skills `sdb_SpecSkill.ss_*ProductMain` are Z20's (§1.3).

### 6.3 Learning and the default skills

- Learning a step: GameDB 0x4802 → `ShinePlayer::so_LearnSkill` FUN_0055bbf0 (vt 0x624) → `csl_Learn` (Z20 §5.2 has
  the pseudocode); `so_LearnSkill` then sets bit 0 of `sp_CharData.toclient.basedata.flags` *(inferred: "character
  data changed", read by the save)*.
- `csl_CheckDefSkill` FUN_00447fb0 (called by `csl_Store` once the last DB chunk is in, Z12 §6.5): for each of
  `defskill.dsd_GetSkillMaxNum()` ids (`DefSkillData::dsd_GetSkillID`, stops at the first 0 return) that no entry
  has (linear search over `csl_SkillNumber` entries), push `{ id, cs_EndOfCooltime = g_Now, empower 0, mastery 0,
  cs_bSave 0 }` and `csl_SkillNumber++`; `csl_Store` sorts afterwards. Dead in 2016: `defskill` is never filled
  (Z12 §6.5). So the item pseudo-skills (29200 UseSilverWings …, §3.6) come from the character's DB skill rows like
  any other skill (D02: the character-create / login paths insert missing default rows with `p_Skill_Set`).

### 6.4 Unlearning one step: `csl_UnLearn`

Called only by `ShinePlayer::so_UnlearnSkillAck` FUN_0057f200 (vt 0x97c) for an active skill after the DB deleted the
row (Z03 §9.5; the DB side is D04 `p_Skill_Del`, one `(nCharNo, nSkillNo)` row).

```pseudo
CharaterSkillList::csl_UnLearn(this, u16 skill)                                              @ FUN_0057e930
    if csl_Skill is empty: return
    it = lower_bound(csl_Skill, skill)
    if not (skill < it.cs_SkillId):                      # it is not compared with end first (original bug) Z23-B10
        csl_Skill.erase(it); csl_SkillNumber -= 1
    # csl_ToggleSkill is not touched, nothing is switched off, nothing is sent here (original bug) Z23-B11
```

- Only the named step is removed; its lower steps stay learned (Z03 §9.5's "and its lower steps" does not match the
  code or `p_Skill_Del`). Since the client shows the highest learned step of a line, one erase item lowers a skill by
  one step *(inferred)*.
- If the removed step was a toggle skill that is on, its `CharacterToggleSkill` entry stays with `cts_bSkillOn = 1` and
  the toggle's abnormal states stay on; the player can no longer cast the step to switch it off. Only the automatic
  switch-offs (§2.4) end it (original bug) Z23-B11.

## 7. Buffers: save to the DB and the WM, list to the client

All three fillers write `PROTO_SKILLREADBLOCK` / `PROTO_SKILLREADBLOCKCLIENT` records *(pdb2016)*:

```
PROTO_SKILLREADBLOCK (0x10)       { i32 savetime; PROTO_SKILLREADBLOCKCLIENT skilldata @4 }
PROTO_SKILLREADBLOCKCLIENT (0xC)  { u16 skillid; u32 cooltime @2 (seconds left); u16 empow @6 (SKILL_EMPOWER); u32 mastery @8 }
```

`cooltime = (cs_EndOfCooltime − g_Now) / 10` (whole seconds, rounded down) while the skill is cooling down, else 0;
above 10800 s (3 h) the server only complains (assert / `SkillCoolTimeLog`) and writes the value anyway. `savetime` =
`mysecond()` (time of day in seconds since 1970). The load side (`csl_Store`, §1.1) gives back
`g_Now + max(0, cooltime − (now − savetime))·10`, so a cooldown keeps running while the character is offline.

### 7.1 Which entries are written (`cs_bSave`)

The two save fillers take a mode; `1` = incremental, `0` = all:

```pseudo
for each entry s (from the start index):
    if s.cs_EndOfCooltime > g_Now:  write s with cooltime = seconds left;  s.cs_bSave = 1
    else if s.cs_bSave != 0 or mode != 1:  write s with cooltime 0;  s.cs_bSave = 0
    else: skip                                            # incremental save and nothing to tell the DB
```

So an incremental save writes every skill still cooling down, plus once more each skill whose cooldown ran out (to
store 0) or whose mastery changed (`csl_AddMastery` sets `cs_bSave`). Empower and learn/unlearn have their own DB
requests (0x4812, 0x4801, 0x4825) and need no flag.

### 7.2 Character DB: `so_SaveSkill` / `csl_FillSaveBuffer`

```pseudo
ShinePlayer::so_SaveSkill(p, PROTO_NC_CHARSAVE_SKILL_REQ* buf, int mode) → int (bytes)       @ FUN_00456520  (vt 0x3a8)
    csl_FillSaveBuffer(p.sp_SkillList, buf, mode)
    return buf.number == 0 ? 0 : buf.number·16 + 8

CharaterSkillList::csl_FillSaveBuffer(this, buf, mode)                                       @ FUN_00454f60
    buf.number = 0
    for i in 0 … csl_SkillNumber−1: rule of §7.1
        after each written record: if 0x18 + 16·buf.number > 8000: stop        # at most 499 records
    # (> 10800 s: line in SkillCoolTimeLog when DebugLogging is on, no assert)
```

`WholeSaver::ws_save2DB` FUN_00455a10 (Z01 §8.4) calls `so_SaveSkill(buf, 1)` on every save: 0 bytes → the skill part
is skipped (`esc_skill.handle.chrregnum = 0xFFFFFFFF`); else GameDB 0x4009 NC_CHARSAVE_SKILL_REQ { 6-byte zone ref,
`PROTO_NC_CHARSAVE_SKILL_REQ` { `PROTO_NC_CHARSAVE_ALL_ACK handle` {u16 bufferlocation, u32 chrregnum}, u16 number,
records } } = 16·(number + 1) bytes with the opcode; the DB writes each record with `p_Skill_Set` (D02 §6, 0x4009) and
answers 0x400A NC_CHARSAVE_SKILL_ACK, ignored (`gds_NC_CHARSAVE_SKILL_ACK` FUN_00455570, no-op). Only one packet per
save: with more than 499 records to write, the rest wait for the next save, and in mode 1 the ones already written lose
nothing; the skipped ones keep their `cs_bSave`.

### 7.3 World manager cache: `so_Send_NC_CHARSAVE_2WLDMAN_SKILL_CMD` / `csl_FillSendBuffer_Server`

```pseudo
ShinePlayer::so_Send_NC_CHARSAVE_2WLDMAN_SKILL_CMD(p, NETCOMMAND* buf)                      @ FUN_00455780  (vt 0xaec)
    # from WholeSaver::ws_save2worldmanager FUN_004536f0 (Z01 §8.4), between 0x4011 and 0x4013
    buf = 0x4012 NC_CHARSAVE_2WLDMAN_SKILL_CMD {
        u16 wldmanhandle = p.vt[0x340]()
        PARTMARK PartMark @2 = { bIsStart 1, bIsEnd 0, nOrder 0 }
        u16 nMaxNum @3 = csl_SkillNumber
        PROTO_NC_CHARSAVE_SKILL_REQ skill @5 { handle.bufferlocation @5 never written (original bug) Z23-B7,
                                               handle.chrregnum @7 = p.vt[0x344]() (charNo), u16 number @0xB, records @0xD } }
    if nMaxNum == 0: nothing is sent
    i = 0
    loop:
        i = csl_FillSendBuffer_Server(p.sp_SkillList, &buf.skill, i, mode 0)    # all skills
        if i < 1: return
        if i >= nMaxNum: PartMark.bIsEnd = 1
        send WM: 16·number + 0xF bytes  (pp_SetPacketLen fail → assert "WholeSaver::ws_save2worldmanager : Packet Too Long")
        PartMark: bIsStart = 0, bIsEnd kept, nOrder += 1
    while i < nMaxNum

CharaterSkillList::csl_FillSendBuffer_Server(this, buf, int start, int mode) → int next index   @ FUN_00445260
    buf.number = 0
    for i = start … csl_SkillNumber−1 while buf.number ≤ 499: rule of §7.1
    return i                                             # 500 records per chunk; asserts "csl_FillSaveBuffer : Too long cooltime" > 10800 s
```

The WM stores the chunks in its character cache (W01 §6.3, W05 0x4012: it reads `chrregnum` @7 and ignores
`bufferlocation`) and sends them back to the next zone as 0x1024 NC_CHAR_ZONE_SKILL_CMD on a map change, which ends
in `csl_Store` again (§1.1). Mode 0 also clears `cs_bSave` on every entry that is not cooling down; this loses no
mastery change because the only caller, `so_LinkTo` FUN_0049ad30, runs `ws_save2DB` (mode 1, §7.2) just before
`ws_save2worldmanager`.

### 7.4 Client list: `csl_FillSendBuffer_Client`

`csl_FillSendBuffer_Client` FUN_00445460 builds 0x103D NC_CHAR_CLIENT_SKILL_CMD after the load (Z12 §6.5 has the
pseudocode): the same loop with 500 records per chunk, no `cs_bSave` handling (every entry is written, cooltime 0 when
not cooling), and it skips — and subtracts from the header's `nMaxNum` — the hidden item pseudo-skills 29200–29205
(0x7210–0x7215), 29428/29429 (0x72F4/0x72F5) and 29535/29536 (0x735F/0x7360).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z23-B1 | `csl_Toggle_SetOnOff` FUN_00448ce0 | the upward walk starts at `sdi_NextSkill` but continues through `sdi_PrevSkill` | only one step above the cast step is updated; casting a lower step leaves higher learned steps with the old flag | follow `sdi_NextSkill` |
| Z23-B2 | `csl_Toggle_AllOffAndReset` FUN_00448fa0 (tent, mount) | calls `so_ply_ToggleSkill_Off` for every learned toggle step without testing `cts_bSkillOn`, and removes the skill's abstates whatever set them | one 0x245D per learned step even when off; the client starts each skill's cooldown display (`RecordSkillUse`) | only switch off the entries that are on |
| Z23-B3 | `csl_SetCoolTime` FUN_00448ab0 | group number 0 is matched like a real delay group | casting MineMelee_W / MineRange_W / EggMelee_W / EggRange_W (group 0, DlyTimeGroup 5 s / 15 s) cools down every other learned group-0 skill | skip group 0 |
| Z23-B4 | `msl_SetCoolTime` FUN_00449270 | compares `DlyTimeGroup` (ms) of the other mount skills with the group number | the shared delay of mount skills hits the wrong skills (or none) | compare `DlyGroupNum` |
| Z23-B5 | `ShineMobileObject::so_Routine` FUN_0056a080, silver-wing item cast | 0x4821 `sec` = `so_ply_SilverWingCoolTime()` in **ms** | client shows a cooldown 1000× too long (60 min → 3 600 000 s) | `/ 1000` as in `so_ply_ChargedBuff` |
| Z23-B6 | `gds_NC_ITEMDB_MAPLINK_ITEM_CONSUME_ACK` FUN_004698a0, `sp_PetSystem_Summon` FUN_004d2640 | send their own 0x4821 with the unshortened time after `smo_ply_SkillCoolTime` already sent the shortened one | with a cooldown set-item rate or item action, the client shows a longer cooldown than the server keeps | send once, after the rate |
| Z23-B7 | `so_Send_NC_CHARSAVE_2WLDMAN_SKILL_CMD` FUN_00455780 (0x4012) | `skill.handle.bufferlocation` (payload +5, 2 bytes) is never written | leftover bytes of the previous packet in `gpp` go to the WM, which ignores them | write 0 or the zone's buffer index |
| Z23-B8 | `csl_EmpowerAlloc` FUN_00448570 (0x4811) | `minus` is checked against the line sum of all learned steps but subtracted from the request's step | removing a point that sits on a lower step wraps the field of the higher step to 15; the DB refuses (> 5, 0x885) and the zone disconnects the player (0x68A) | check and subtract on the same step, or move points to the new step on learning |
| Z23-B9 | `sp_NC_SKILL_EMPOWALLOC_REQ` FUN_0044f150 → `csl_MaximumSkill` FUN_00448240 | the request's skill ID is not looked up before `skilldatabox[skill].sdi_NextSkill` is read | a 0x4811 with an unknown skill and zero plus/minus makes the zone read through a null pointer (crash) | refuse unknown or unlearned skills (0x884) first |
| Z23-B10 | `csl_UnLearn` FUN_0057e930 | compares with `*lower_bound` without testing for `end` | an unlearn answer for a skill above every learned ID reads past the vector and may erase `end` | test `it != end` |
| Z23-B11 | `csl_UnLearn` / `so_UnlearnSkillAck` FUN_0057f200 | removes the step but not its `csl_ToggleSkill` entry and does not switch an active toggle off | the toggle's abnormal states stay on with no step left to cast it off | switch the toggle off (`so_ply_ToggleSkill_Off`) and drop the entry |

## Not reconstructed / uncertain

- Whether toggle abnormal states survive a zone change: `so_LinkTo` switches the toggles off without removing the
  states, and `csl_Store` loads every toggle as off. If the states are saved with the character's abstates (Z03 §6,
  `NC_CHARSAVE_ABSTATE`), the player arrives with the states on and the toggle off; the next cast then switches it
  on again *(inferred; the abstate save path is not read here)*.
- Whether the 2016 client applies `SS_DMGCOLLTIMEDOWN` to its own cooldown display (the server sends nothing, §3.4).
- `setitemskilleffect` is a global reloaded by `so_Routine` before each blast; for the non-cast callers of
  `smo_ply_SkillCoolTime` (§3.6) it holds whatever the last routine left in it *(inferred)*.

- Which step ID the 2016 client sends in 0x4811 `skill` (decides how often Z23-B8 happens) and in 0x4824 (§6.4):
  the client side of the skill window is not read here.
- `csl_AddMastery` runs right after the GameDB 0x3457 produce request is sent; if the DB refuses the produce, the
  mastery gain stays *(inferred; the 0x3457 answer is Z05/Z07)*.

(Part 3 adds §8–§9; the coverage boundary is written in the sweep part.)
