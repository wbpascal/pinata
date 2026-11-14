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

The skills of a `ShineMover` (mount object, Z13). Only cooldowns are kept; §3.5 has the functions. `msl_Store`
fills it from `MoverUseSkill.shn` on every summon (§9.1); that table is empty in 2016, so the list is always empty.

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
| 0x91c | `so_ply_ItemUseResultPacket` FUN_0045e610 (item-use answer, Z04) | – |
| 0xed4 / 0xec0 | `smo_CastAbort` / `smo_ply_NextBashTime` (Z03 §5) | – |
| 0xedc | `smo_SPCheck` FUN_0055bc20 (§4) | mob FUN_005557f0 (SP test and pay), mover FUN_0055eeb0 (true) |
| 0xee0 | `smo_SPCheckConsume` FUN_0055bc50 (Z03 §5.4) | – |

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
| `ShinePlayer::so_LinkTo` FUN_0049ad30 (Z01 / Z09) | `csl_Toggle_AllOff` | both link-out branches: in the same-server branch after the link packet to the client and before the game stream is replaced by the dummy container; in the other branch after the save to DB / WM and before 0xC809. The player gets 0x245D for each skill that was on; the abstates are not removed (for a link to another zone server they are not carried either: §2.4 note below) |
| `sp_NC_ACT_PITCHTENT_REQ` FUN_00457760 (Z02) | `csl_Toggle_AllOffAndReset` | the tent shape was built (just before mode 4 is set) |
| `sp_NC_MOVER_RIDE_ON_REQ` FUN_00563270 (Z09 mover section) | `csl_Toggle_AllOffAndReset` | the mount is visible and within 300 units, before `sp_MoverSystem_GetOn` |
| `sp_MoverSystem_Cast` FUN_0045d550 (mount item cast, Z13) | `csl_Toggle_AllOffAndReset` | the mount item is valid, before the 0x2047 ride cast starts |

Toggle states across a link: the character's abnormal states are saved through `AbnormalStateSaver::lid_Call`
FUN_00454b10 (called per state by `so_SaveAbstate` FUN_00454d80, Z07), which writes a state only when its
`AbState.AbStateSaveType` row in `AbStateSaveTypeInfo.shn` has `IsSaveLogoff` (save to the DB, `ass_bSaveToDB`) or
`IsSaveLink` (otherwise) set. The only toggle skill line, BurnPain01–06 (`ToggleSkill.shn`), sets `StaBurnPainMe` on
the caster and `StaBurnPainFoe` on the target, both `AbStateSaveType 0` (no flag set). So after a link to another zone
server or a re-login the caster has neither the toggle (`csl_Store` loads it as off) nor its state: both sides agree.
Per saved state `lid_Call` writes one 0x24-byte `ABSTATEREADBLOCK` (id, strength, rest count, elapsed ms
`(g_Now − start)·1000/10`, rest time, set-item effect, caster level and attack power); the save path itself is Z07's.

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
        # comparator: `GatherProduce::RecipeBook::rb_Compare` FUN_0046a470 = first u16 of a − first u16 of b (ID order)
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

The actor class `SubAbnormalStateActorIgnoreCoolTime` (index string "IgnoreCoolTime" from its `sasa_IndexString`
FUN_00401710, the `ac_COOLTIMEREMOVE` member
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
`so_smv_SkillBash_Object` FUN_00580800 and `so_smv_SkillBash_Location` FUN_00580cf0 check `msl_CoolTimeCheck` (§9.2;
both have no caller in 2016); the mover's cast completion goes through the same `so_Routine` §3.1 (vt 0xeac → `msl_SetCoolTime`).

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

SP before the blast: `ShineMobileObject::so_Routine` FUN_0056a080 (§3.1) calls `smo_SPCheck` (vt 0xedc) with the
cast's skill, `SkillDataIndex` and `scs_Empower` before each blast pass; a false result runs `smo_CastAbort` (vt 0xed4)
and `smo_ply_NextBashTime` (vt 0xec0) and ends the routine without a blast. The cast request itself makes the same
test (Z03 §5.2, `consume = false`).

```pseudo
ShineMobileObject::smo_SPCheck(o, skill, s, empower) → bool                                    @ FUN_005557f0   (mob)
    if o.smo_Flag.InSkillShift: return true                      # second pass of a two-phase blast: already checked
    if s.sdi_Activ.SP ≤ o.so_GetSP() (vt 0x4ec): o.so_LostSP(s.sdi_Activ.SP) (vt 0x4f8); return true
    return false
ShinePlayer::smo_SPCheck(p, skill, s, empower) → bool                                          @ FUN_0055bc20   (vt 0xedc)
    if p.smo_Flag.InSkillShift: return true
    return csl_SPCheck(p.sp_SkillList, p, skill, s, empower, consume = 0)   # Z03 §5.3: test only
    # the cost is paid after the blast by smo_SPCheckConsume (vt 0xee0, FUN_0055bc50, consume = 1; Z03 §5.4)
ShineMover::smo_SPCheck(...) = true                                                            @ FUN_0055eeb0
```

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
| charged item: request below; GameDB 0x9008 NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_SUC_ACK FUN_00518780 (Z08 §11) | `ShinePlayer::so_ply_InitSkillEmpow` FUN_00518c00 (vt 0x37c): `csl_EmpowerClear`, then send 0x900D NC_CHARGED_SKILLEMPOW_INITIALIZE_SUC_CMD { u8 = vt 0x6b8() − csl_EmpowerSummary() } (3 bytes) | client `GameFrameWork::On_NC_CHARGED_SKILLEMPOW_INITIALIZE_SUC_CMD` FUN_0049b330: `Skill::ClearLearnActSkillInfo`, `Skill::SetRestEmpowerPoint(u8)`, `SkillIcon::RefreshSkillInfoAll` |

The charged reset request (Z08 §11 describes only the DB answers; D03 the DB side):

```pseudo
UseEffect::UseItemStatClear::uib_DirectUse(this, p, slot, item)                                @ FUN_00599990
    # two static instances (Z04 item-use table, `iuf_Load` FUN_0049b770 keys "StatClearStat" / "StatClearEmpow"):
    #   ui_StatClearStat  { uisc_DBReqCommand 5, uisc_ErrCommand 14 }   ui_StatClearEmpow { 6, 15 }   (read from the exe data)
    sp_StatEmpowInitialize(p, uisc_DBReqCommand, uisc_ErrCommand, slot, item)
    p.so_ply_ItemUseResultPacket(0x700, 9) (vt 0x91c)                # item-use answer, Z04
    return true

ShinePlayer::sp_StatEmpowInitialize(p, dbcmd, errcmd, slot, item)                             @ FUN_005183f0
    it = inventory item at slot; lot = it.class.vt[0x1c](it)        # remaining count
    GameDB ← 0x9000 | dbcmd  (0x9005 NC_CHARGED_STAT_INITIALIZE_DB_REQ / 0x9006 NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_REQ) {
        ref { u16 p.handle, u32 charNo (vt 0x344) }
        u16 lockindex       = p.invenlocklist counter
        u64 restatitemkey   = it.key
        u16 restatitemid    = it.id
        u8  isdelete        = lot == 1
        u16 attr            = isdelete ? 0 : 0x15          # a constant: offset of the attribute bytes after the opcode (inferred)
        [attribute block of the item with lot − 1]          # only when not deleting (class vt 0x20 sets the lot, vt 4 writes it)
    }                                                       # 0x17 bytes + attribute block
    lot == 1: lock the cell for deletion (lock list vt 0x30, location 0x2400 | slot)
    else:     lock the cell for an update to the copy with lot − 1 (lock list vt 0x40)
    counter += 1
    # errcmd is not used here; the DB-fail answers send 0x900E / 0x900F themselves (Z08 §11). Nothing is checked:
    # the item-use layer (Z04) already validated the item.
```

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
  `defskill.dsd_GetSkillMaxNum()` ids (`DefSkillData::dsd_GetSkillID` FUN_0045d380: `dsd_Array[i].skill` if
  `i < dsd_Max`, else 0; stops at the first 0 return) that no entry
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
        csl_Skill.erase(it); csl_SkillNumber -= 1        # vector::erase FUN_0057e8e0: moves the later 0x14-byte entries down
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

## 8. Dispel, cure and the miss result (Z03 leftovers)

`smo_SkillBlast` FUN_00581160 (Z03 §5.6, step D) removes abnormal states from the target for skills whose
`ActiveSkill.EffectType` is `SE_DISPEL` or `SE_CURE`. Z03 only names the step; this section is the full rule. The
skill specials read here (`sdi_CURE`, `sdi_DISPELDEBUFF`, `sdi_DISPELDISEASE`, `sdi_DISPELPOISON`, `sdi_DISPELCURSE`,
`sdi_BOMBDISPELALL`, `sdi_DISPELDEEPER`, `sdi_DETECT`, `sdi_DISPELONE`, `sdi_DISPELALL`, `sdi_DISPELRANDOM`,
`sdi_STEALENCHANT`, `sdi_DISPELABSTATE`) are `SkillDataIndex` members filled from the skill's special list (Z20 §4).

The kinds a dispel may remove form a bit mask `1 << DispelAttr` of the state's `AbState.DispelIndex`
(enum `DispelAttr` *(pdb2016)*: 1 DA_GOOD, 2 DA_DEBUFF, 3 DA_DISEASE, 4 DA_POISON, 5 DA_CURSE, 6 DA_STUN, 7 DA_FEAR,
8 DA_DEEPER, 9 DA_HIDE, 10 DA_BOMB, 11 DA_CHARGED). The abnormal-state list of an object is
`AbstateListInObject` (`smo_Abstate.abstatelist`, object + 0x1cc, size 0xcc8: 28 `AbstateElementInObject` slots + an
index-linked `List` at +0xcb0), reached through `so_mobile_AbstateList` (vt 0x52c).

### 8.1 The mask: `smo_Dispel`

```pseudo
ShineMobileObject::smo_Dispel(a, s, empower, d, bos):                   @ FUN_0057d8e0   (caller: smo_SkillBlast, §8.4)
    if s.sdi_Activ.EffectType not in {SE_DISPEL, SE_CURE}: return
    arg = SmashArgument { actionnumber = attackcode = iscritical = isdead = 0, sklidx = s, empower = *empower }
    mask = 0
    if not a.so_mobile_IsEnemy(d) (vt 0x72c):                 # friend: remove bad states
        if EffectType == SE_CURE: mask = DA_DISEASE | DA_POISON                                  # 0x18
        else: mask = (DISPELDEBUFF ? DA_DEBUFF 0x4) | (DISPELDISEASE ? 0x8) | (DISPELPOISON ? 0x10)
                   | (DISPELCURSE ? 0x20) | (BOMBDISPELALL ? DA_BOMB 0x400)
    else if not s.sdi_DISPELDEEPER:                           # enemy: remove buffs, or reveal
        mask = s.sdi_DETECT ? DA_HIDE (0x200) : DA_GOOD (0x2)
    else:                                                     # enemy, DISPELDEEPER: only my own Deeper state
        mask = DA_DEEPER (0x100) if some e in d's list has aeo_IsMine(e, a, STA_DEEPER) else 0
    a.so_SkillCure(d, &arg, bos)            (vt 0x5a4, §8.2)
    a.so_Dispel(d, &arg, bos, mask)         (vt 0x5a8, §8.3)
    r = skillresultbuffer[bufferpoint]:  r.target = d;  r.isenchant = 1;  r.isresist = 0
        # (original bug) Z23-B14: set whether or not anything was removed, and clears the resist flag the abstate
        # part (so_SkillEnchant, §2.5) set just before
```

```pseudo
AbstateElementInObject::aeo_IsMine(e, o, idx) → bool:                   @ FUN_00408880
    e.aeo_Index == idx and e.aeo_Caster.obj != null and o != null
    and e.aeo_Caster.obj.handle == o.handle and o.so_GetCharRegistNumber() (vt 0x344) == e.aeo_Caster.chrregnum
    # handle and character number: a handle re-used by another object does not match
```

Callers of `aeo_IsMine`: `smo_Dispel` and the inline copy in `smo_SkillBlast` (§8.4); both only for `STA_DEEPER`.

### 8.2 Cure: `so_SkillCure`

```pseudo
ShineMobileObject::so_SkillCure(a, d, arg, bos) → bool:                 @ FUN_0042c440 (vt 0x5a4)
    if d == null or d.smo_GetMode() (vt 0x484) == 3 (dead, as in Z03 §5.6) or not arg.sklidx.sdi_CURE: false
    grade = sdi_CURE.value
    for e in d's list, in list order:
        if rand(1000) < 1001:                                 # always true (original bug) Z23-B12
            ab = dic_abstate[e.aeo_Index]   (index >= 0x318 → assert "AbnormalStateDictionary::AbState::as_FromIndex : Invalid skill idx")
            if ab.DispelIndex in {DA_DISEASE, DA_POISON} and ab.StateGrade <= grade:
                e.aeo_Flag.f_Cured = 1;  e.aeo_Tick.terminate = g_Now;  return true    # one state per call
    false
```

It ignores the mask, so it also runs on an enemy target (only `sdi_CURE` decides; whether any CURE skill can target
an enemy is the skill table's `First`, Z20 *(inferred)*).

### 8.3 Dispel and steal: `so_Dispel`

```pseudo
ShineMobileObject::so_Dispel(a, d, arg, bos, mask) → bool:              @ FUN_0042bf70 (vt 0x5a8)
    if d == null or d.smo_GetMode() == 3: false
    if d.so_MiscTable() (vt 0x984).Dead.ByDebuff (+0x58 bit 0) and mask & DA_GOOD:
        d.so_DamagedBy(d, d.so_GetHP(), 1000, 1) (vt 0x5c0 / 0x4e8);  return true
        # servants marked "dies by dispel" (Z09 §13.3, `MiscData` `Dead`) are killed; the killer passed is d itself, not a,
        # so the caster gets no kill credit *(inferred)*
    s = arg.sklidx;  removed = false;  n = 1;  pick = null
    for e in d's list, in list order:                        # pass 1: remove
        if rand(1000) < 1001 (always, Z23-B12) and mask has bit ab(e).DispelIndex:
            if s.sdi_DISPELONE:   e.aeo_Tick.terminate = g_Now;  return true           # the first match only
            if s.sdi_DISPELALL:   e.aeo_Tick.terminate = g_Now;  removed = true;  continue
            if s.sdi_DISPELRANDOM:                            # reservoir pick, uniform over the matches
                if n == 1 or rndbox[n] == 0: pick = e         # rndbox[n] (RandomBox::operator[] FUN_00427c30): next value of
                n += 1                                        #   box n's shuffled ring (uniform 0…n−1, below); 0 for n > 100
            if s.sdi_BOMBDISPELALL: e.f_Dispeled = 1;  e.aeo_Tick.terminate = g_Now;  removed = true
    for e in d's list, walked through the other link (+6) from the end:   # pass 2: steal one buff
        if rand(1000) < 1001 and mask has bit ab(e).DispelIndex and s.sdi_STEALENCHANT:
            if e.aeo_GetAbstateElement() (FUN_004067b0) != null and its vt[0xc]() : continue
                # vt[0xc] is FUN_004b8d20 "return false" in all three AbnormalStateElement classes: never skips
            if rand(1000) < sdi_STEALENCHANT.value:
                e.aeo_Tick.terminate = g_Now
                if a.so_AbnormalState_Set(setter = a, e.aeo_Index, e.aeo_Strength, ab, setTime = e.aeo_Tick.start,
                                          0, keep = e.aeo_RestCount, 0, EF_JUSTENCHANTSTEALENCHANT (6), null) (vt 0x638, Z03 §6.2):
                    a.so_AbnormalState_BitSet(idx);  a.so_AbnormalState_Inform(idx, sub.KeepTime, 1) (vt 0x3f0, players only)
                    a.so_AbnormalState_BroadcastSet(idx, sub.KeepTime, strength)
                removed = true
            break                                             # one candidate only, whether the roll succeeded or not
    if n > 1: pick.f_Dispeled = 1;  pick.aeo_Tick.terminate = g_Now                     # random dispel; `removed` stays
    return removed                                            # ignored by smo_Dispel
```

- `aeo_Tick.terminate = g_Now` does not remove the element; the state ends at the target's next abnormal-state tick
  (Z03 §6). `f_Cured` / `f_Dispeled` (`aeo_Flag` bits 0 / 1 *(pdb2016)*, cleared by `aeo_Set` FUN_0040a340) make the
  end handlers skip their end effect: `SubAbnormalStateActorBomb::sasa_DetachObject` FUN_0040c520 (the bomb does not
  go off), `…DetachProcess` FUN_0040c1c0, `…ExpUpRate` FUN_00408f90, `…DropUpRate` FUN_00409230. `DISPELONE` and
  `DISPELALL` end the state without a flag, so these end effects still run *(inferred intent: the flag was meant for
  bombs only, which only `BOMBDISPELALL` reaches)*.
- Bits `DA_STUN`, `DA_FEAR`, `DA_CHARGED` are never set by `smo_Dispel`: no skill removes them through this path.

### 8.4 Order in `smo_SkillBlast` and the double run

Inside `smo_SkillBlast` FUN_00581160 (Z03 §5.6), after the hit roll succeeded (or with fixed damage):

```pseudo
    if mha.mha_HitStep < 1 and s.sdi_DISPELABSTATE and (ab = dic_abstate.as_FromID(sdi_DISPELABSTATE.value)) and ab.index:
        if asl_Abstate_IsSet(d's list, ab.index.AbStataIndex):          # one named state, every target kind
            d.so_AbnormalState_Reset(idx) (vt 0x650);  so_AbnormalState_BitReset(d, idx);  so_AbnormalState_BroadcastReset(d, idx)
    … heal / damage parts (Z03 §5.6 B, C) …
    if mha.mha_HitStep < 0:                                  # single-hit skill
        unless r.isImmune: so_SkillEnchant (vt 0x5a0, §2.5) → r.isenchant, r.isresist |= resisted
        smo_Dispel(a, s, empower, d, bos)
        then the same code once more, inlined (0x582a31…0x582b0c: mask, vt 0x5a4, vt 0x5a8, result flags)
            # (original bug) Z23-B13: dispel and cure run twice for every single-hit skill
        BattleObjectList::bol_Store(bos, g_Now + SwingTime·…);  item actions "on skill hit" of d …
    else:                                                    # multi-hit step (Z03 §5.6 E): the step's 4 abstates, then
        smo_Dispel(a, s, empower, d, bos)                    # once
```

Effect of the double run *(inferred: ended states stay in the list until the tick)*: cure, `DISPELONE` and the random
pick meet the same element again (no second removal, but `DISPELRANDOM` may pick another one, so up to two states
go); `DISPELALL` / `BOMBDISPELALL` are idempotent; `STEALENCHANT` rolls twice on the same buff, so the steal chance is
1 − (1 − p)², and a double success sets the state on the caster twice (a refresh).

### 8.5 The miss result: `smo_ClearSkillResultBuffer_Miss`

```pseudo
ShineMobileObject::smo_ClearSkillResultBuffer_Miss(a, t):               @ FUN_0057a550
    SkillResultBuffer::bufferpoint = 1
    skillresultbuffer[0] = { target = t, isdamage = 1, ismissed = 1, every other flag 0, hpchange = 0,
                             resthp = t.so_GetHP() (vt 0x4e8) }
```

Only caller: `smo_SkillBash_Blast(Obj)` FUN_0057cd40, when a `sdi_CROSSCOUNTER` skill fails (Z03 §5.4: no target, the
target is not attackable, or `so_smo_CrossCounterDamage` returns −1). It first sends 0x2457
NC_BAT_SKILLBASH_HIT_BLAST_CMD to the caster only, then this and `smo_SkillResultPacket` (0x2452 with one missed
entry, Z03 §5.6). `SkillResultBuffer` *(pdb2016)*: 0x18 bytes `{ target, resthp, isdamage, IsCostumWeapon,
IsCostumShield, iscritical, ismissed, isshieldblock, isheal, isenchant, isresist, isImmune, hpchange@0x14 }`.
With `t == null` both this function and `smo_SkillResultPacket` (`t.so_LocateInfo`) dereference null
(original bug) Z23-B17; latent, as `so_Routine` only calls the object blast with a target (Z03 §5.4) *(inferred)*.

## 9. Mount skills (`ShineMover`)

The skill code of mounts is complete but **unused in 2016**: `MoverUseSkill.shn` has no rows, and the two cast entry
points have no caller. A rebuild can drop it or keep it as below.

### 9.1 Who fills `MoverSkillList`

```pseudo
ShineMover::so_smv_SummonMover(m, map, x, y, dir, moverId, hp, layer):  @ FUN_0055fdf0   (the summon itself: Z13)
    m.smv_MoverData = MoverDataBox.mvdb_GetData(moverId);  …
    m.smv_MoverSkillList.msl_Skill.resize(0)
    MoverSkillList::msl_Store(&m.smv_MoverSkillList, copy of smv_MoverData.mvdbi_vUseSkill)
    *m.smo_Mode.mode = 1;  …

MoverSkillList::msl_Store(l, rows):                                      @ FUN_00449190
    for r in rows, until the end or a null pointer:
        s = SkillDataBox.GetSkillIndexByName(r.ActiveSkillIDX)          # Z20 §5.1
        null → assert "MoverSkillList::msl_Store : Skill data null";  no sdi_Activ → assert "… : ActiveSkillInfo data null"
        else push { ms_SkillID = s.sdi_Activ.ID, ms_EndOfCooltime = 0 }   # no learning, no save: rebuilt on every summon
    free the copied vector
```

`MoverUseSkill` *(pdb2016)*: `{ char MoverIDX[32]; char ActiveSkillIDX[32]; }` (0x40), loaded by FUN_004bf960 (Z01
§2.3) into `MoverDataBoxIndex.mvdbi_vUseSkill` (+0x10, `vector<MoverUseSkill*>`). The 2016 server file has
0 rows, so every mount's list is empty: `msl_CoolTimeCheck` / `msl_SetCoolTime` would assert "Did not learn skills".

### 9.2 Casting: `so_smv_SkillBash_Object` / `so_smv_SkillBash_Location`

ShineMover vt 0xcec / 0xcf0. Neither has a caller: each address occurs once in the exe (the vftable entry), and no
`call [reg+0xcec]` / `[reg+0xcf0]` exists. `r` is the rider (the requesting player). Errors go to `r` at once through
`ShinePlayer::so_SendErrorCode(r, 9, 0x34, code)` FUN_0054f050 = 0x2434 NC_BAT_SKILLBASH_CAST_FAIL_ACK `{ u16 err }`
(4 bytes), not through the per-tick `castResult` of the player path (Z03 §5.2; texts in its table). The allowed
mode set is a static `cmc_AllowMode = 6` (mover modes 1 and 2; the summon sets 1).

```pseudo
ShineMover::so_smv_SkillBash_Object(m, skill, target, r):               @ FUN_00580800 (vt 0xcec)
    if r == null: return
    if not (6 & 1 << m.mode):                                 → 0xFC0
    if m.smo_DuringCast() (vt 0xea0):                         → 0xFC4
    t = som_GetObject(target);  null                         → 0xFC4
    if no field or not field.CanSkill (+0x9f):                → 0xFC3
    for e in m's states: aeo_Attack(e)
    if m.smo_Flag & 4 (Fear):                                 → 0xFCC
    if m.smo_IsCaptivate() (vt 0xf20):                        → 0xFD2
    (vt 0x9e4 "Ethereal" is FUN_004b8d20 = false for movers)
    if m.smo_SkillBlastOption() == SB_SILENCE:                → 0xFC7
    if not mdb_CanIKill(t.vt[0x708](), MKID_USER):            → 0xFD6
    if not so_SubLayer_CanAttack(m, t):                       → 0xFC0
    if m has STA 291 (0x123):                                 → 0xFC1
    rest = t.so_AbnormalState_RestTime(291);  if rest > 0:
        if not t.vt[0x89c]() (mob-like, as Z03 §5.2):         → 0xFC2
        if rest > 3600: return (no answer);  t.so_AbnormalState_Reset(291)
    if m has STA 499:                                         → 0xFC1
    if t has STA 499:                                         → 0xFD6
    if m.so_parameter().IsNoAttack(): m.smo_CastAbort() (vt 0xed4); return
    if FindBlockLocate(m → t.pos, attack block) != t.pos:     → 0xFD1, m.smo_BashStop() (vt 0xed8)
    s = SkillDataBox[skill]; null, no sdi_Activ or SkillTargetState == TS_NONE:  assert "ShineMover::so_smv_SkillBash_Object : Not Skill" → 0xFC6
    if m.smo_MoveManager state (+0x18c) == 3 and (CastTime != 0 or SHOOTME or HOLDME):    → 0xFC8
    switch s.First:
        TARGET_ENEMY, TARGET_ENEMYUSER: if not m.so_mobile_ICanDamageTo(t) (vt 0x980): → 0xFD6;  then the heal test below
        TARGET_ALL: the heal test below
        heal test: if s.Area != 0 and not (First == TARGET_EVERY and t's mob type (+99) == 16)
                   and not m.smo_ICanHealTo(t) (vt 0xe94):    → 0xFD7
        other kinds: no target test
        # (original bug) Z23-B19: the player version (Z03 §5.2) runs the heal test for friendly HEALING skills with
        # Area == 0; here it runs for enemy / all skills with Area != 0, and friendly skills are not checked at all
    if not msl_CoolTimeCheck(&m.smv_MoverSkillList, skill):   → 0xFC8          # §3.5
    reach = t.so_BodySize() + s.sdi_AttackDist;  reach = min(reach·10/8, reach + 60)
    if so_DistanceSquar(m, t) > reach²:                       → 0xFCA
    smo_SkillBash_Casting(m, s, t, null, −1)                  # Z03 §5.4; completion → msl_SetCoolTime (§3.5)

ShineMover::so_smv_SkillBash_Location(m, skill, xy, r):                 @ FUN_00580cf0 (vt 0xcf0)
    if r == null: return
    if not (6 & 1 << m.mode):                                 → 0xFC0
    if no field:                                              → 0xFCC    # (original bug) Z23-B18: the Fear text, not 0xFC3
    if not field.CanSkill:                                    → 0xFC3
    for e in m's states: aeo_Attack(e)
    if m.smo_DuringCast():                                    → 0xFC4
    if Fear:                                                  → 0xFCC
    if m.smo_IsCaptivate():                                   → 0xFD2
    if m.smo_SkillBlastOption() == SB_SILENCE:                → 0xFC7
    if m has STA 291 or STA 499:                              → 0xFC1
    if FindBlockLocate(m → xy, attack block) != xy:           → 0xFD1, BashStop
    s = SkillDataBox[skill]; null / no sdi_Activ / TS_NONE:   assert (empty text) → 0xFC6
    if s.SHOOTME and FindBlockLocate(m → xy, move block) != xy:   → 0xFD1, BashStop
    if move state == 3 and (CastTime != 0 or SHOOTME or HOLDME):  → 0xFC8
    if not msl_CoolTimeCheck(…):  m.so_SendErrorCode(9, 0x34, 0xFC8); return
        # (original bug) Z23-B16: sent to the mover, whose slot 0x308 is FUN_004c2450 (`ret 0xc`): the rider gets no answer
    reach = m.so_BodySize() (ShineMover FUN_0055eb00) + s.sdi_AttackDist, same tolerance
    if dist²(m.pos, xy) > reach²:                             → 0xFCA
    smo_SkillBash_Casting(m, s, null, &xy, −1)
```

Compared with the player paths (Z03 §5.2 / §5.5) the mount paths have no cost check, no set-item load, no revive /
spouse / soul / toggle checks and no `sp_AbstateCheck`.

### 9.3 Mob weapons against a mount: `ShineMover::so_ply_CanMyTarget`

```pseudo
ShineMover::so_ply_CanMyTarget(m, attacker, i) → m or null:             @ FUN_004ae450 (vt 0x760)
    if attacker == null or (box = attacker.so_mob_DataBox() (vt 0x70c)) == null or box.weapons (+8) == null: null
    w = box.weapons[i] (0xc each);  w.row == null: null
    switch w.row.AtkType (+0x4f, enum ATKTYPE, Z09 §6.7):
        SKLTP_DAMAGE (0):  m
        SKLTP_ABSTATE (2): sk = SkillDataBox[w.skill];  null → null
                           m if one of sk's 4 abstates (≠ MAX_ABSTATEINDEX) is not set on m (l_GetInArray on m + 0xe7c), else null
        SKLTP_DISPEL (4):  m if m has NO good state (asl_IsHereGood false)
                           # (original bug) Z23-B15: inverted against ShinePlayer::so_ply_CanMyTarget FUN_004ae280 (Z09
                           # §6.7: the player is a dispel target when it HAS a good state); `not` + `and` at 0x4ae50c
        else: null
```

Same as the player version except the null checks and the inverted dispel test. Callers: the mob tactics
`MobActionAttack::mab_Think` FUN_004bba00 and `MobActionTargetting::mab_Think` FUN_004b99e0 (vt 0x760 at 0x4bbe7c /
0x4b9d11; Z09 §7.1 / §7.2), when the object they test is a mount.

## 10. Original-server bugs

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
| Z23-B12 | `so_SkillCure` FUN_0042c440, `so_Dispel` FUN_0042bf70 | each state is first rolled with `rand(1000) < 1001` | always true: every matching state is a candidate | a per-state dispel chance (some rate below 1000) |
| Z23-B13 | `smo_SkillBlast` FUN_00581160, single-hit path | calls `smo_Dispel` and then runs an inlined copy of it | cure / dispel / steal run twice per target: up to two states for `DISPELRANDOM`, steal chance 1 − (1 − p)² | one dispel per hit |
| Z23-B14 | `smo_Dispel` FUN_0057d8e0 (and its copy) | sets `isenchant = 1` and `isresist = 0` on the result entry unconditionally | the client shows an effect even when nothing was removed, and a resisted debuff of the same skill as not resisted | set `isenchant` only when something was removed; keep `isresist` |
| Z23-B15 | `ShineMover::so_ply_CanMyTarget` FUN_004ae450 | SKLTP_DISPEL weapon: returns the mount when it has **no** good state | mob dispel weapons pick mounts with nothing to dispel and skip buffed ones | `asl_IsHereGood` true → target, as the player version |
| Z23-B16 | `so_smv_SkillBash_Location` FUN_00580cf0 (latent) | cooldown error 0xFC8 is sent through the mover's own `so_SendErrorCode` (a no-op) | the rider gets no answer | send to the rider like every other code |
| Z23-B17 | `smo_SkillBash_Blast` FUN_0057cd40 → `smo_ClearSkillResultBuffer_Miss` FUN_0057a550 (latent) | the cross-counter failure branch for `t == null` reads `t`'s HP and position | null dereference (crash) if ever reached | send the miss without a target entry |
| Z23-B18 | `so_smv_SkillBash_Location` FUN_00580cf0 (latent) | mount without a field gets 0xFCC | "Cannot use the skill on Fear State." | 0xFC3 as in the object version |
| Z23-B19 | `so_smv_SkillBash_Object` FUN_00580800 (latent) | the `smo_ICanHealTo` test runs for enemy / all skills with `Area != 0`; friendly skills get no target test | heal-blocked targets refuse enemy area skills; friendly skills reach any target | test friendly HEALING skills with `Area == 0`, as the player version |

## 11. Not reconstructed / uncertain

- Toggle states and the same-server link branch of `so_LinkTo`: the states are not saved (§2.4 note), but whether the
  player object, and with it `StaBurnPainMe`, survives a map change inside the same zone process is not read here
  (Z01 / Z09 link code). If it does, the player keeps the state with the toggle marked off, and the next cast
  switches it on again *(inferred)*.
- Whether the 2016 client applies `SS_DMGCOLLTIMEDOWN` to its own cooldown display (the server sends nothing, §3.4).
- `setitemskilleffect` is a global reloaded by `so_Routine` before each blast; for the non-cast callers of
  `smo_ply_SkillCoolTime` (§3.6) it holds whatever the last routine left in it *(inferred)*.

- Which step ID the 2016 client sends in 0x4811 `skill` (decides how often Z23-B8 happens) and in 0x4824 (§6.4):
  the client side of the skill window is not read here.
- `csl_AddMastery` runs right after the GameDB 0x3457 produce request is sent; if the DB refuses the produce, the
  mastery gain stays *(inferred; the 0x3457 answer is Z05/Z07)*.

- §8: whether an ended state (`terminate = g_Now`) stays visible to the second dispel run of the same blast
  (Z23-B13) depends on when the abstate tick drops it (Z03 §6); the effects listed in §8.4 assume it stays.
- §8.3: `RandomBox` as read: the constructor `RandomBox::RandomBox` FUN_0063cdb0 (global `rndbox`, seeded with
  `srand(time)`) fills box n = 0…100 with 0x4000 u16 slots `⌊i·n / 0x4000⌋` (each of 0…n−1 equally often), swaps
  every slot with a `rand()`-scaled index (no swap when the index is ≥ 0x4000) and clears values ≥ n (none). `operator[]`
  (n = 1…100, else 0) advances box n's ring pointer and returns the slot, so `rndbox[n] == 0` has chance 1/n and the
  reservoir pick is uniform. The ring repeats every 16384 draws of the same n. `rb_1000` FUN_004012a0, `rb_random`
  FUN_0063ccf0 and `rb_largerandom` FUN_0063ccc0 (n ≤ 100 → box, else Well512) use the `cWell512Random` member instead.
- §9.2: the mover modes (1, 2) have no names in the 2016 PDB; which mode a ridden mount is in is Z13's.

## 12. Coverage boundary

Found while following the functions of this item, but documented elsewhere or left to another item.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `sp_MoverSystem_Cast` FUN_0045d550, `UseItemRide::uib_DirectUse` FUN_005995b0, `sp_RideInitialize` FUN_0043d140, `so_ply_LayerMoverRideOn` FUN_0054aef0, `ShineMover::so_Routine` FUN_0056af60, `so_smv_SummonMover` FUN_0055fdf0 (all but their skill-list lines, §2.4 / §9.1) | Z13 (open; plan "Mounts: mover creation (which item or NPC allocates a `ShineMover`) …") | mount lifecycle; only the toggle switch-off, the mover skill list and the ride cooldown are skill-list state |
| `sp_PetSystem_Summon` FUN_004d2640 (rest), `sp_PetSystem_LinkResummon` FUN_004d2a40 | Z13 (open; plan "Pets: the summon/unsummon flow …, the resummon after a map link") | §3.6 has the summon cooldown lines only |
| silver-wing item: `sp_SilverWingMenu` FUN_0059c090, `smfm_Silverwing_Portal` FUN_0059bbe0, `smfm_Silverwing_LocSet` FUN_0059bff0, `smfm_Silverwing_Cancel` FUN_0059bb30, `sp_SilverWing_PortalCast` FUN_00597b30 (beyond its cooldown check, §3.6), `sp_SilverWing_PortalBlast` FUN_00597cf0, `UseItemSilverWing::uib_CanUseItem` FUN_00598000 / `uib_AfterCast` FUN_0053ff70 | new item **Z25** (added by Z23) | an item-use and teleport flow (server menu, saved location, link); Z04 (done) lists the class only by address, no open item covers it |
| item-action cooldowns: `ItemActionObserveManager::SetCoolTime` FUN_005d1b60, `SendCoolTimes2Client` FUN_005d0d30, `SendCoolTimes2World` FUN_005d0fa0, item actions run by `EventRunBySkillGroupIndex` | Z17 (open; goal "what an item action is …, when it fires, its cooldowns") | a separate cooldown store keyed by action group, not `CharSkill.cs_EndOfCooltime` |
| `SubAbState.shn` rows with the `COOLTIMEREMOVE` sub-state (which abnormal states give a free cast, §3.3) | Z03 §6.1 (actor table row "31 COOLTIMEREMOVE") | table data; §3.3 documents the effect on the cooldown |
| abstate actor bodies reached from here: `sasa_DetachObject` FUN_0040c1c0 / FUN_00409230 / FUN_00408f90, `sasa_Act_LastDamegeInterceptByDef` FUN_0040ba30 (calls `aeo_Set`) | Z22 (open; plan lists the DetachProcess / DropUpRate / ExpUpRate bodies) | actor behaviour, not skill-list state; §8 only needs that dispel ends a state |
| abstate tick that drops ended states (decides the second dispel run, Z23-B13) | Z03 §6.4 (expiry and removal) | §11 records the open timing question |
| abnormal-state save path `so_SaveAbstate` FUN_00454d80 (rest of `AbnormalStateSaver`) | Z07 (owner per Z03 §6, line "Z07 owns the save path") | §2.4 uses only `lid_Call`'s save-type test, cited there |
| `ws_save2DB` FUN_00455a10 / `ws_save2worldmanager` FUN_004536f0 (when the skill saves run) | Z01 §8.4 | §7 documents what the skill part writes |
| produce cast and its checks (`sp_NC_ACT_PRODUCE_CAST_REQ` FUN_0046cf90, `ip_ProduceCheck`, the GameDB 0x3457 answer) | Z02 §8, Z07 §11 | §5 covers the mastery gain and 0x481D only |
| `uib_Effect` FUN_00599d30 of the skill scroll (0x4801 NC_SKILL_SKILLTEACH_REQ) | Z20 §5.2 table, Z04 §6 | §6.2 covers the skill-list checks of `uib_CanUseItem` |
| `MoverUseSkill.shn` loader (`MoverDataBox::mvdb_Load` FUN_004bf960) | Z24 (open; plan lists `mvdb_Load` 004bf960) | data loader; §9.1 states the 2016 file has 0 rows |
| mob tactics `mab_Think` FUN_004bba00 / FUN_004b99e0 (callers of the mount `so_ply_CanMyTarget`, §9.3) | Z09 §7 | world simulation |
| `RandomBox` (`operator[]` FUN_00427c30, constructor FUN_0063cdb0) | documented here (§11, §8.3 note) | a small utility no item documents; Z11 §11 and Z16 left its contents as inferred, which §11 now settles |
| GM commands `&skillcooltime`, `&ignoreskillcooltime`, `&itemactioncooltimereset` | Z11 §8.5 | §3.2 cites the ignore flag they set |
| GameDB answers of the empower resets (0x480D / 0x480E, 0x9008 / 0x900A) and their DB side | Z03 §9.2, Z08 §11, D03 / D04 | §4 documents the list functions and the charged reset request (FUN_00599990 / FUN_005183f0) that Z08 left uncited |
| `csl_Store`, `so_charskilldata` FUN_0044bf20 (0x103D client list) | Z12 §6.5 | §7.4 links to it |
| Z03 §9.5 says `csl_UnLearn` also removes the lower steps; Z03 §9.1 shortens `csl_EmpowerAlloc` | corrected here (§6.4, §4) | Z03 is done; the full reading is in this file |

