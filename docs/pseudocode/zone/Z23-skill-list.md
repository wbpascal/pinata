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
- W03 / W04 / Z12 cover `csl_Store` (DB → zone load) and `csl_FillSaveBuffer`; this file only adds the parts they skip.

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

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z23-B1 | `csl_Toggle_SetOnOff` FUN_00448ce0 | the upward walk starts at `sdi_NextSkill` but continues through `sdi_PrevSkill` | only one step above the cast step is updated; casting a lower step leaves higher learned steps with the old flag | follow `sdi_NextSkill` |
| Z23-B2 | `csl_Toggle_AllOffAndReset` FUN_00448fa0 (tent, mount) | calls `so_ply_ToggleSkill_Off` for every learned toggle step without testing `cts_bSkillOn`, and removes the skill's abstates whatever set them | one 0x245D per learned step even when off; the client starts each skill's cooldown display (`RecordSkillUse`) | only switch off the entries that are on |
| Z23-B3 | `csl_SetCoolTime` FUN_00448ab0 | group number 0 is matched like a real delay group | casting MineMelee_W / MineRange_W / EggMelee_W / EggRange_W (group 0, DlyTimeGroup 5 s / 15 s) cools down every other learned group-0 skill | skip group 0 |
| Z23-B4 | `msl_SetCoolTime` FUN_00449270 | compares `DlyTimeGroup` (ms) of the other mount skills with the group number | the shared delay of mount skills hits the wrong skills (or none) | compare `DlyGroupNum` |
| Z23-B5 | `ShineMobileObject::so_Routine` FUN_0056a080, silver-wing item cast | 0x4821 `sec` = `so_ply_SilverWingCoolTime()` in **ms** | client shows a cooldown 1000× too long (60 min → 3 600 000 s) | `/ 1000` as in `so_ply_ChargedBuff` |
| Z23-B6 | `gds_NC_ITEMDB_MAPLINK_ITEM_CONSUME_ACK` FUN_004698a0, `sp_PetSystem_Summon` FUN_004d2640 | send their own 0x4821 with the unshortened time after `smo_ply_SkillCoolTime` already sent the shortened one | with a cooldown set-item rate or item action, the client shows a longer cooldown than the server keeps | send once, after the rate |

## Not reconstructed / uncertain

- Whether toggle abnormal states survive a zone change: `so_LinkTo` switches the toggles off without removing the
  states, and `csl_Store` loads every toggle as off. If the states are saved with the character's abstates (Z03 §6,
  `NC_CHARSAVE_ABSTATE`), the player arrives with the states on and the toggle off; the next cast then switches it
  on again *(inferred; the abstate save path is not read here)*.
- Whether the 2016 client applies `SS_DMGCOLLTIMEDOWN` to its own cooldown display (the server sends nothing, §3.4).
- `setitemskilleffect` is a global reloaded by `so_Routine` before each blast; for the non-cast callers of
  `smo_ply_SkillCoolTime` (§3.6) it holds whatever the last routine left in it *(inferred)*.

(Parts 2–3 add §4 onward; the coverage boundary is written in the sweep part.)
