# Zone: skill special effects (Z25)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read in the PDB re-analysis
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>` (NA2016 `Zone.pdb`, same build: class,
member and function names are *(pdb2016)* unless marked). Raw instructions where the decompile is unclear:
`objdump -d --start-address=0x… Files/Server/2016/w00_Zone00/5ZoneServer2.exe`. Virtual slots were resolved with
`tools/protocol-re/rtti.py` (vftables of `ShinePlayer` / `ShineMob` / the rule classes) against the PDB function names.
Data checks use `tools/protocol-re/shn.py` on the 2016 `9Data/Shine/*.shn`.

This item continues Z03 §5.6 (`smo_SkillBlast` summary) and does not repeat what other items already document:
the `SkillDataIndex` special members and their `SkillSpecial` codes (Z20 §1.3, §4), the dispel / cure / steal bodies
(Z22 §7.5, Z23 §8), `so_SkillEnchant` (Z22 §10.7), movement helpers `smo_JumpTo` / `smo_WarpTo` / `smo_ShadowStep`
(Z09 §9.3), summons from skills (`mdt_SkillBlast_Summon`, Z09 §13.3), magic fields (Z09),
toggle skills (Z23 §2), set-item multipliers `setitemskilleffect.se_Argument[]` (Z21 §3; all neutral = 1000 in 2016).

Packets: `docs/protocol/packets-zone.md`; verified layouts of this item: `docs/protocol/annotations/Z25.json`.

## 1. Data used by the special effects

### 1.1 Special members of `SkillDataIndex`

Each special is an `EnumStruct { u8 exist; int value }` at `0x078 + 8·k` (Z20 §1.3; filled by `sdi_SetArgument`
from `ActiveSkill.shn` `SpecialIndexA…E` / `SpecialValueA…E`, Z20 §4). Offsets of the members this item reads
(PDB layout; replaces the *(inferred)* list in Z03 §5.1, several of whose guesses were wrong):

| Off | Member | Off | Member | Off | Member |
|---|---|---|---|---|---|
| 0x078 | sdi_HEALAMOUNT | 0x120 | sdi_HPCONVERTSP | 0x1e0 | sdi_DMGDOWNRATE |
| 0x0a0 | sdi_MANABURN | 0x128 | sdi_HPUPRATE | 0x1e8 | sdi_MAXDMGDOWNRATE |
| 0x0a8 | sdi_UNDEADTODMG | 0x180 | sdi_FIRETIMEADD | 0x1f8 | sdi_TARGETHPDOWNDMGUPRATE |
| 0x0e0 | sdi_DETECT | 0x188 | sdi_CURSETIMEADD | 0x200 | sdi_JUMP |
| 0x0f0 | sdi_THHPUP | 0x190 | sdi_HOLDME | 0x240 | sdi_DISPELABSTATE |
| 0x0f8 | sdi_DIEHPUP | 0x198 | sdi_POSIONTIMEADD | 0x248 | sdi_RECALL |
| 0x100 | sdi_REVIVAL | | | 0x258 | sdi_SUCKHP |

Z03 §5.1's guesses corrected: +0x168 is `sdi_WARPING_TARGET` (SS_DASH2), +0x170 `sdi_JWALK`, +0x1d0
`sdi_RANDOMTARGETNUMBER` (not a summon member), +0x208 `sdi_SETABSTATEME`, +0x210 `sdi_NOTTARGET`, +0x240
`sdi_DISPELABSTATE` (not NOTTARGET).

#### 1.1.1 Who reads each special member (sweep)

Every function of the zone-pdb export that names an `sdi_*` special, outside `sdi_Clear` FUN_00584500 /
`sdi_SetArgument` FUN_00584800 (Z20 §4, which fill them). Raw-offset readers were checked in the disassembly
(byte reads `0x<off>(%reg)` of the six members without a named reader): only `sdi_SetArgument` writes them.

| Member (off) | Readers → where documented |
|---|---|
| HEALAMOUNT (0x78) | smo_SkillBlast §2.4, roe_CalcDamage FUN_005002a0 §2.5.1, `almfh_ApplyHeal` FUN_0056d2c0 Z09 §12.5 |
| CURE (0x80) | so_SkillCure FUN_0042c440 Z22 §7.5 / §5 here |
| DISPEL (0x88), TELEPORT (0x90), WHOLEHEALAMOUNT (0x98), SILVERWING (0x138), AREATYPE (0x1a8), HEALFRIENDRATE (0x1c0) | **no reader**: set from the SHN, never used. Teleport skills go by `EffectType` SE_TELEPORT (§6.1), not by SS_TELEPORT |
| MANABURN, UNDEADTODMG, THHPUP, DIEHPUP, HPCONVERTSP, HPUPRATE, DMGDOWNRATE, MAXDMGDOWNRATE, TARGETHPDOWNDMGUPRATE, DISPELABSTATE, SUCKHP, FIRETIMEADD, CURSETIMEADD, POSIONTIMEADD | smo_SkillBlast only (§2.3 – §2.9) |
| DISPELALL / ONE / RANDOM, STEALENCHANT, BOMBDISPELALL | so_Dispel FUN_0042bf70 (Z23 §8); BOMBDISPELALL also smo_Dispel FUN_0057d8e0, smo_SkillBlast |
| DISPELDEBUFF / CURSE / POISON / DISEASE / DEEPER, DETECT | smo_Dispel (mask, Z17 §3.7), smo_SkillBlast §2.9 |
| WHOLEAGGRORATE / RANGE (0xc8 / 0xd0) | so_Routine FUN_0056a080 §6.1 |
| WARPING (0xd8) | smo_SkillBash_Blast Obj / Loc §6.2 / §6.3, smo_WarpTo / smo_WarpForward (Z09 §9.3) |
| CROSSCOUNTER, WARPING_TARGET, JWALK | smo_SkillBash_Blast(Obj) §6.2 |
| REVIVAL (0x100) | smo_SkillBlast, `sbec_Routine` FUN_00437fc0 (Z03 §5.6), cast handler 0x2440 FUN_0057fa50 (Z03 §5.2), item skill 0x304E FUN_00540b90 (Z04 §12.7) |
| HOLDME, SHOOTME | cast handlers 0x2441 FUN_0057f400 / 0x2440 FUN_0057fa50 (Z03 §5.5 / §5.2), 0x304E FUN_00540b90 (Z04 §12.7), mover casts FUN_00580800 / FUN_00580cf0 (Z13, unreachable); HOLDME also §2.7, SHOOTME also §6.3 |
| MAGICFIELD_TICK / KEEP / PARTY / DELAY_START_TIME, BMP_MAGICFIELD_ROTATIONSPEED_RIGHT | magic-field functions (Z09 §12.2 – §12.5), `sasa_Routine` FUN_00408d80 (Z22 §6) |
| FLYDURINGCAST (0x130) | `sm_UseWeapon` FUN_004ab9c0 (Z09 §7.4 "+0x130"), `sm_UseSkillSimple` FUN_0057d880 (Z03 §6.6) |
| DMGCOLLTIMEDOWN (0x1a0) | `csl_DmgCoolTimeDown` FUN_00449080 (Z23 §3.4) |
| SETABSTATEFRIEND (0x1c8) | `almfh_ApplyHeal` FUN_0056d2c0 (Z09 §12.5) only |
| RANDOMTARGETNUMBER, RANDOMTARGET, TOPAGGRONO, NEXTTARGETAREA, DMGSHARE, SHOTSPEED | §6.4 – §6.8 (RANDOMTARGET also `sm_UseWeapon`, Z09 §7.4) |
| RANDOMTARGETSPOT (0x260) | `sm_UseWeapon` only (Z09 §7.4 "+0x260"; the `sdb_Load` hit is the array-end bound) |
| JUMP, RECALL | smo_SkillBlast §2.5 / §2.6, smo_JumpTo FUN_0057db20 (Z09 §9.3) |
| SETABSTATEME, NOTTARGET, ABKEEPTIME | smo_SkillBash_Blast(Obj) §6.2, smo_MagicFieldSpread FUN_0057c880 (Z09 §12.2) |

`SS_MOVE_CHR`, `SS_HIDE_CHR_START` / `_END` and the other enum values without a member (SS_HIDE 29, SS_Silience 30,
SS_MESMERIZE 31, SS_SUMMON 32, SS_METAMORPHOSIS 33, SS_DISPELBUFF 37, SS_HPRATE 39) are dropped by `sdi_SetArgument`
(Z20 §4). Z20 §4 leaves open whether other code reads them from the row: **nothing does**. The only reader of
`ActiveSkillInfo.SpecialIndexA … SpecialValueE` (+0x213 … +0x237, unaligned) in the zone is `sdb_Load` FUN_00585f40
(the five `sdi_SetArgument` calls); no zone-pdb function names `SpecialIndex*`, and the disassembly has no other
`0x213 / 0x21b / 0x223 / 0x22b / 0x233(%reg)` load of the row (the five hits outside `sdb_Load` are in CRT / log
code). So these specials (2016 data: SS_SUMMON 42 slots, MOVE_CHR / HIDE_CHR_START / _END 22 each, …) have **no
server effect**; summons and metamorphoses go by `EffectType` and the abstates (§6.1, Z09 §13.3), if at all.

### 1.2 Globals and structures

```pseudo
skillresultbuffer[64] (SkillResultBuffer, 0x18 bytes each)  @ 0x13283d18;  SkillResultBuffer::bufferpoint @ 0x13283d10
    { +0 ShineObject* target, +4 u32 resthp, +8 u8 isdamage, +9 IsCostumWeapon, +a IsCostumShield, +b iscritical,
      +c ismissed, +d isshieldblock, +e isheal, +f isenchant, +10 isresist, +11 isImmune, +14 u32 hpchange }
    # one slot per target of the current blast; bufferpoint is reset by sds_Initialize, the blasts and each chain wave (§6); sds_Finish sends sds_List, not this buffer
skilldamagesender (SkillEffectApply::SkillDamageSender)   .sds_List = vector<SkillDamage> sent as 0x2452 by sds_Finish
EngageArgument (0x2c) { att, def, sklinfo, SKILL_EMPOWER empower, u8 actionnumber, attackcode, iscritical, ismiss,
    isdead, isshieldblock, isresist, isDamege2Heal, isImmune, SHINE_XY_TYPE* attackloc, int damagerate, crirateadd,
    MultiHitArgument* pMultiHitArg, int nBMPDamageRate }                 # the "ctx" of Z03 §4
MultiHitArgument (0x3c) { int mha_HitStep; int mha_DamageRate; int mha_AraeStep; mha_AbState[4] }   # "hit" of Z03 §5.6
SKILL_EMPOWER (u16 bit fields) { damage:4, sp:4, keeptime:4, cooltime:4 }
BattleObjectGroup::BattleObjectStruct (0x98) { u16 bos_Attacker, bos_Defender; int bos_Damage, bos_Heal,
    bos_AbsoluteAggro, bos_DamageRateAggro, bos_MyHealHit, bos_MyHealKill; bos_AbstateList; bos_DispelLst;
    ABSTATEINDEX bos_StealedEnchant }
```

`BattleObjectList::bol_Store` @ FUN_00434ee0 is empty in 2016 (profiler entry/exit only). Every `BattleObjectStruct`
that `smo_SkillBlast` fills is therefore discarded when the function returns: the `bos_*` writes below are dead stores,
and the values that matter are passed to `sds_TemplateStore` (§3) as plain arguments instead. The struct's
destructor is the folded `so_Gamble_ChangeCoin` stub at the function end.

Set-item multipliers read here (`setitemskilleffect.se_Argument[i]`, Z21 §3; base 1000): 1 HEALRATE, 2 DAMEGERATE,
9 HPDRAINRATE, 12 AGGRORATE, 13 PROBABILITYRATE.

### 1.3 Virtual slots called by `smo_SkillBlast` (players / mobs)

| Slot | Player | Mob | Use here |
|---|---|---|---|
| 0x24 | `so_YouHaveAlreadyDead` FUN_00555780: `smo_BattleObject.alreadydead = 1` | same | lethal hit marker |
| 0x28 | `so_AmIAlreadyDead` FUN_005557a0 | same | target already dead |
| 0x3e4 | `so_AbnormalState_IsSet(idx)` FUN_00555a20 | same | |
| 0x430 | `so_parameter` FUN_00555720 (`DamageReflection` +0xcd2, `RangeOver` +0xda8, Z12) | same | reflection |
| 0x484 | `smo_GetMode` (3 = dead) | same | |
| 0x4d0 | object type: 2 (folded stub FUN_005551b0) | `so_ObjectType` = 5 | "caster is a player" |
| 0x4e8 / 0x4f0 | `so_GetHP` / `so_MaxHP` | same names | |
| 0x4f8 / 0x4fc | `so_LostSP` / `so_GainSP` (Z21 §3) | same names | MANABURN / HPCONVERTSP |
| 0x588 | `so_SetLastBattle` FUN_00555560: `smo_duringbattle.db_lasthit = now` | `ShineMob::so_SetLastBattle` (Z09) | |
| 0x5ac | 1 (folded stub FUN_005af8d0) | `so_CanSkillTarget` FUN_00556b20: `MobInfo.GradeType != MGT_NONE` | target filter |
| 0x5d0 | `so_GetItemActionObserves` | 0 | item-action rates (Z17) |
| 0x700 | no-op (folded FUN_00509900) | `so_mob_AppendAggro(attacker, points)` | aggro |
| 0x708 | 0xFFFF (folded FUN_005550b0) | `so_mob_MobID` | `mdb_CanIKill` |
| 0x70c | 0 | `so_mob_DataBox` → `{ MobInfo*, MobInfoServer* }` | mob type checks |
| 0x7e0 | `so_ply_Revival` FUN_0057ab90 (Z03 §7.3) | no-op | SS_REVIVAL |
| 0x980 | `so_mobile_ICanDamageTo(t, "smo_SkillBlast")` | same name | |
| 0xb8c | `so_ShineMobileObject` FUN_00450350 (returns `this`) | same | RECALL |
| 0xb90 | `so_mob_SkillParameterSet` FUN_005d2e40 (returns 0) | FUN_005d2e90 (Z09: sets the mob weapon for this skill) | |
| 0xf04 / 0xf08 | `smo_ply_IsCostumCharged` / `smo_ply_IsCostumShieldCharged` | 0 | result flags (Z06) |
| 0xf5c | `smo_ReflectionDamage` FUN_0055dbc0 (§4) | same | reflection |
| 0x2fc | `so_GetGameSocketStream` FUN_00559870 | `so_GetDataSocketStream` FUN_00554fa0 → `so_dummypacketcontainer` | 0x242A of §2.8 (mobs: nothing sent) |
| 0x3f0 | `so_AbnormalState_Inform` FUN_00405900 (0x2429 / 0x242A, Z03 §6.3) | no-op (folded FUN_004c2450) | §2.7, §2.10 |
| 0x52c | `so_mobile_AbstateList` FUN_005555b0 (`smo_Abstate.abstatelist`) | same | |
| 0x5a0 | `so_SkillEnchant` FUN_00431ca0 (Z22 §10.7) | same | §2.9 |
| 0x5a4 / 0x5a8 | `so_SkillCure` FUN_0042c440 / `so_Dispel` FUN_0042bf70 (Z23 §8.2, §8.3) | same | §2.9 inline dispel |
| 0x5d4 | `so_ItemActonAbstateApp` FUN_0055dea0 (Z22 §10.7) | same | §2.10 |
| 0x634 | `so_AbnormalState_Resist` FUN_00416730 | FUN_00416660 | §2.10 (Z03 §6.2) |
| 0x638 | `so_AbnormalState_Set` FUN_004162d0 | FUN_004161c0 | §2.7, §2.10 (Z03 §6.2) |
| 0x654 | empty `ret 4` FUN_00549070 (PDB fold name `so_ply_CollectCardOpen`; every `ShineObjectClass` vftable) | same | §2.9: nothing |
| 0x72c | `so_mobile_IsEnemy` FUN_00430570 | FUN_004304c0 | dispel mask (Z23 §8.1) |
| 0xa5c | `so_smo_AbStateKeepTimeAdd` FUN_0040bd20 (§2.8; every mobile class, objects without HP: `ret 8` FUN_00509900) | same | §2.8 |

Rule-set slots (`sdi_DamageRule`, Z03 §4.2): 0x18 `roe_HitRate` (physical FUN_00502d30, magical FUN_00503360),
0x1c `roe_CalcDamage` FUN_00505c00 (Z03 §4.5), 0x20 `roe_IsDamageSkill` FUN_004ff840 (= `sdi_ServInf.UsualAttack`;
false without a skill), 0x2c `roe_HitRateByGlobalAction` (physical FUN_005055a0, magical FUN_005058d0).

### 1.4 Sub-state rows by strength, and how a keep time is chosen

Every `so_AbnormalState_Set` in this item passes a strength and a keep time; which `SubAbState` row and which
duration the state gets is decided here.

```pseudo
AbnormalStateDictionary::AbState::as_Load()                               @ FUN_00416e80   (zone start)
    read ../9Data/Shine/AbState.shn and AbStateSaveTypeInfo.shn
    as_AbstateArray = new AbStateStr[max ID + 1] (0x5ac each);  as_StateIndexList[0x318] = null
    for each AbState row:
        BTree as_BTreeID: InxName → ID;  as_BTreeIndex: InxName → AbStataIndex
        arr[ID].index = row;  arr[ID].pSaveTypeInfo = save-type row with the same AbStateSaveType
        arr[ID].debuffresist = resist slot by DispelIndex: DA_DISEASE 0xb4, DA_POISON 0xb0, DA_CURSE 0xb8;
                               SubDispelIndex SDA_MOVESPEED 0xbc / SDA_GTIRESIST 0xc0 override it
                               (the member offset so_AbnormalState_Resist reads, Z03 §6.2)
        as_StateIndexList[AbStataIndex] = &arr[ID]
        for k in 0..39: arr[ID].subabstate[k] = { assa_info = sas_Find(row.SubAbState, k),
                                                  assa_Effect[4] = its ActionIndexA…D / ActionArgA…D }
    for idx in 0..0x317 with an entry: null index → assert "as_Load : Null Index" + ShineExit;
                                        null save type → "Null SaveTypeInfo" + ShineExit

AbnormalStateDictionary::SubAbState::sas_Find(name, strength) → SubAbStateInfo*       @ FUN_00416c10
    if name[0] == '-': return sas_DefAbstate
    for each SubAbState.shn row in file order:
        if row.Strength != 999 and row.Strength > 40: assert "sas_Find : Wrong MaxStrength"; return sas_DefAbstate
        if row.InxName == name and (row.Strength == 999 or row.Strength == strength): return row
    name never seen: assert "sas_Find : Not found" (name);  return sas_DefAbstate
(sas_Load @ FUN_00416bd0 reads SubAbState.shn and truncates ../9Data/SubAbStateClass.txt, S01)
```

So a `SubAbState` row with **Strength 999 matches every strength** 0…39 (e.g. `SubStaKeepTime_7Sec` of
StaCannotChangeTarget, §2.7; `SubStaE_UserComeback_Main01…05`, the open question of Z22 §13): the state behaves the same
whatever strength the setter passes. A missing strength falls back to `sas_DefAbstate`.

Keep time, from `aeo_Set` FUN_0040a340 (Z03 §6.2): `so_AbnormalState_Set(setter, idx, strength, entry, setTime,
extra, restCount, keepMs, how, origin)` passes `extra` and `keepMs` through `asl_AbstateSet` unchanged.

```pseudo
    if keepMs == 0: ms = SubAbState.KeepTime + 999 + extra      # row time, rounded up, plus the extra
    else:           ms = keepMs                                 # explicit time: extra is ignored
    ticks = ms <= 60000 ? ms·10/1000 : (ms/1000)·10;  terminate = setTime + ticks · SET_ABSTATEKEEPTIMERATE / 1000
```

`so_SkillEnchant` (Z22 §10.7) folds every bonus into `keepMs`; the multi-hit loop (§2.10) passes the empower bonus as
`extra` next to a non-zero `keepMs`, which drops it (Z25-B9).

## 2. `smo_SkillBlast`: one target, in code order  @ FUN_00581160

`ShineMobileObject::smo_SkillBlast(a = caster, s, d = target, empower, fixedDamage, hit, depth, bmpRate)`. Callers:
`sbe_BlastObject` FUN_00583bc0, `alsst_SkillBlast` FUN_00582de0, `alsst_SkillBlast_RandomTarget` FUN_00583180
(Z03 §5.6, Z17) and the servant blast `smo_SkillBash_Blast_Trap(Obj)` FUN_005838a0 (fixedDamage −1, its own
`MultiHitArgument`, depth 1, rate 1000; Z18). `depth` is the chain step: 1 for a single target (`sbe_BlastObject`,
Trap(Obj)), 2, 3 … for chain waves (§6.8), but **−1** for every target of the area loops `alsst_*` (§6.7), which only
SS_DMGDOWNRATE reads (§2.5, Z25-B21). `bmpRate` the `AreaSkill` bitmap rate (1000 for
single targets). Every exit path runs the `BattleObjectStruct` destructor; nothing is returned.

### 2.1 Entry filters  (0x581160 – 0x5812f0)

```pseudo
    copy a.so_CharName (vt 0x56c) into the debug name ring (namestring)      # logging only
    if bufferpoint > 63 or d == null or not d.vt[0x5ac]() (mobs: GradeType != MGT_NONE)
       or d.so_AbnormalState_IsSet(STA_IMMORTAL 291) or d.so_AbnormalState_IsSet(STA_ADLFLOUSSIERIMT 499): return
    kind = a.vt[0x708]() != 0xFFFF ? MKID_MOB : MKID_USER
    if not mdb_CanIKill(&mobdatabox, d.vt[0x708](), kind) (Z09 §5.1: players 0xFFFF → yes) or s == null or s.sdi_Activ == null: return
    a.so_mob_SkillParameterSet (vt 0xb90)(s.sdi_Activ.ID)                     # mobs: weapon of this skill (Z09)
    so_SubLayer_CanAttack(a, d)            # FUN_0049acb0 (Z03 §3.1): result ignored (original bug) Z25-B1
    if d.so_layer.layer.l_Sub != 0 and not (s.sdi_DETECT.exist and l_Sub == 1): return
                                           # sub-layer targets: only DETECT skills, and only sub-layer 1
    if s.sdi_REVIVAL.exist: d.vt[0x7e0]() (player: so_ply_Revival, Z03 §7.3; mob: nothing); return
                                           # no result slot: the revive has its own packets
    if d.smo_GetMode() == 3 (dead) or d.so_AmIAlreadyDead(): return
    a.so_SetLastBattle(); d.so_SetLastBattle()                                # in-battle timers (Z07 / Z09)
    bos = BattleObjectStruct(a.handle, d.handle)
    if a is a player (vt 0x4d0 == 2): bos.bos_AbsoluteAggro = (sdi_ServInf.AggroPerDamage or .AbsoluteAggro) ? 1 : 0   # dead store
    hp0 = d.so_GetHP()
    r = skillresultbuffer[bufferpoint]: clear isdamage, IsCostumWeapon, IsCostumShield, iscritical, ismissed,
        isshieldblock, isheal, isenchant, isresist, isImmune
    ctx = EngageArgument(a, d, s, empower, a.so_LocateInfo.location)          # FUN_0042abf0
```

### 2.2 Hit roll and the miss result  (0x5812f0 – 0x581640)

Only when `fixedDamage < 0` (no cross-counter / magic-field damage):

```pseudo
    c1 = rule.roe_HitRate(ctx) (vt 0x18) + (se_Argument[13] PROBABILITYRATE − 1000)
                # the offset is converted as an unsigned 32-bit value: a negative offset becomes +4 294 967 296 − x,
                # i.e. a certain hit (original bug) Z25-B2 (latent: every set multiplier is 1000 in 2016, Z21)
    n = rand(1000)                                         # well512, one number for both tests
    hit = n <= c1 and n <= rule.roe_HitRateByGlobalAction(ctx) (vt 0x2c, only evaluated when the first test passed)
    if not hit:
        r = { target d, iscritical 0, ismissed 1, isshieldblock = ctx.isshieldblock, isheal 0, isenchant 0,
              hpchange 0, resthp hp0 }
        sds_TemplateStore(a, r, absAggro 0, rateAggro 1000, healOnHit 0, healOnKill 0)          # §3
        bufferpoint += 1
        if a is a player: bol_Store(bos, now + 10)                                              # no-op (§1.2)
        reflection (§4.1) with dmg = rule.roe_CalcDamage(ctx) (vt 0x1c), computed only for this
        return
```

Z03 §5.6 A shows two random numbers; the code draws one (`well512_GetRandom(1000)` at 0x58133b) and compares it with
both rates, so the hit chance is `min(c1, c2) / 1000`, not `c1 · c2`. A miss still reflects damage: the
reflected part is computed from a fresh `roe_CalcDamage` as if the skill had hit (same rule as the swing, Z03 §3.2).

With `fixedDamage ≥ 0` there is no roll: the skill always hits.

### 2.3 Hit: DISPELABSTATE, result slot, aggro  (0x581640 – 0x581790)

Everything below runs only when `hit` (the `MultiHitArgument*`) is non-null; with a null `hit` the target gets no
result at all (no caller passes null *(inferred from the three callers, which pass `&e.hit` / their own)*).

```pseudo
    if hit.mha_HitStep < 1 and s.sdi_DISPELABSTATE.exist == 1
       and (ab = as_FromID(&dic_abstate, (u16) sdi_DISPELABSTATE.value)) and ab.index:
        if asl_Abstate_IsSet(d.so_mobile_AbstateList(), ab.index.AbStataIndex):
            d.so_AbnormalState_Reset (vt 0x650)(idx); so_AbnormalState_BitReset(d, idx)
            so_AbnormalState_BroadcastReset(d, idx)           # FUN_00405800: 0x2428 NC_BAT_ABSTATERESET_CMD
                                                              #   { u16 object = d, u32 abstate = idx } to d's sight (Z03 §6.3)
        # one named state, removed at once (no deferred terminate, no f_* flag; compare Z22 §7.5), on friends and
        # enemies alike. 2016 data: BallHive_Skill01_W removes 9101 StaKQSpringSlow (ABSTATEINDEX 576)
    r = { target null, resthp 0, all flags 0, +0x12 = 0, hpchange 0 }
    absAggro  = sdi_ServInf.AbsoluteAggro                     # also bos.bos_AbsoluteAggro += (dead)
    rateAggro = se_Argument[12] AGGRORATE − 1000 + sdi_ServInf.AggroPerDamage
    if a.so_GetItemActionObserves() (vt 0x5d0):
        if EventRunBySkillGroupIndex(results, s, SEIT_AGGRO_RATE_INCREASE, a, d): rateAggro = results.GetRateAppliValue(rateAggro)   # Z17
    canDamage = a.so_mobile_ICanDamageTo(d, "smo_SkillBlast") (vt 0x980)
```

### 2.4 Heal part: SS_HEALAMOUNT  (0x581790 – 0x5818f0)

```pseudo
    if s.sdi_HEALAMOUNT.value < 1 or d.so_AmIAlreadyDead() or canDamage:
        r.resthp = hp0                                         # no heal on enemies or the dead
    else:
        h = sdi_HEALAMOUNT.value
        if a.so_GetItemActionObserves(): item action SEIT_HEAL_RATE_INCREASE on h (as above)
        h = se_Argument[1] HEALRATE · h / 1000
        if empower.damage != 0: h += sdi_Activ.nT0[empower.damage − 1]
                # read as nIMPT[damage + 3] (0x1af + 4·(damage+3) = nT0 + 4·(damage−1)); Z03 §5.6 B writes nT0[damage]
        for g in s.sdi_ActiveSkillGroups (stops at a null entry):
            if g.ActiveSkillGroupIndex == HealReinforce (98): h += a.smo_Param.PassiveHealRate · h / 1000; break
        r = { target d, iscritical 0, ismissed 0, isheal 1, isenchant 0, isresist 0, hpchange h,
              resthp hp0 + h (not capped; the packet takes the real HP later, §3), isImmune 0 }
```

### 2.5 Damage part  (0x5818f0 – 0x582080)

```pseudo
    rule = s.sdi_DamageRule
    db = d.vt[0x70c]()                                         # mobs only
    if db and db.MobInfo.Type == MT_DEVIL (16) and s.sdi_Activ.First == TARGET_EVERY (8):
        rule = &roe_alwaysHealAttack                           # RuleOfEngagementHealAttack, §2.5.1
    if rule.roe_IsDamageSkill(ctx) (vt 0x20) and canDamage:
        r.isdamage = 1
        r.IsCostumWeapon = a.vt[0xf04](); r.IsCostumShield = a.vt[0xf08]()     # Z06 charges
        mdt_ArgumentLoad(&miscdatatable, &ctx)                 # FUN_004a6110 (Z09 §28.3 ExpandSkill: damage / crit rate bonus and a new state when d has the row's abstate attribute)
        ctx.pMultiHitArg = hit; ctx.nBMPDamageRate = bmpRate
        if fixedDamage < 0: fixedDamage = rule.roe_CalcDamage(ctx) (vt 0x1c)      # Z03 §4.5
        d0  = se_Argument[2] DAMEGERATE · fixedDamage / 1000
        dmg = d0 · hit.mha_DamageRate / 1000
        if d0 != 0 and dmg == 0:
            if hit.mha_DamageRate < 1: r.isdamage = 0          # a 0 % multi-hit step deals nothing
            else: dmg = 1
        # SS_TARGETHPDOWNDMGUPRATE (Judge01…06, value 1000)
        if s.sdi_TARGETHPDOWNDMGUPRATE.exist == 1 and (mx = d.so_MaxHP()) != 0:
            lost = (u64)(mx − d.so_GetHP()) · 1000 / mx        # lost HP per mille (64-bit, 0x581b3e…0x581b65)
            V = sdi_TARGETHPDOWNDMGUPRATE.value
            dmg = dmg + (lost · V / 1000) · dmg / V
                # V cancels except for rounding: the bonus is always ≈ lost‰ of the damage; V = 0 divides by zero
                # (original bug) Z25-B3
        # SS_DMGDOWNRATE / SS_MAXDMGDOWNRATE (LightningWave…: 100 / 900; one skill 300 / 910, one 200 / 200)
        if s.sdi_DMGDOWNRATE.exist == 1:
            cut = sdi_DMGDOWNRATE.value · depth
            if s.sdi_MAXDMGDOWNRATE.exist == 1 and sdi_MAXDMGDOWNRATE.value < cut: cut = sdi_MAXDMGDOWNRATE.value
            dmg = dmg − cut · dmg / 1000                        # signed /1000 (magic −0x10624dd3), so each chain
                                                                #   step loses value‰, the first target already one step
                # area targets (alsst_*, depth −1): cut = −value, so dmg grows by value‰ (the cap only limits from
                #   above). (original bug) Z25-B21: DT_TFocalor_Skill04_W (TargetNumber 5, HitID 30, 300 / 910) deals
                #   +30 % to its first-wave area targets; its chain waves (depth 2, 3 …, §6.7) get the cut
        # SS_JUMP (Judge01…06, value 200): the caster leaps to the target
        if s.sdi_JUMP.exist == 1 and not smo_JumpTo(a, d.so_LocateInfo.location, s, a):   # FUN_0057db20 (Z09):
            return                                              #   lands sdi_JUMP.value beyond the target, 0x482D NC_SKILL_JUMP_CMD
                                                                #   no free cell / blocked path: this target gets no result and no damage
        # SS_UNDEADTODMG (HolySmite…, 150 … 500)
        if s.sdi_UNDEADTODMG.exist and db and db.MobInfo.Type == MT_UNDEAD (5):
            dmg = dmg + sdi_UNDEADTODMG.value · dmg / 1000
        bos.bos_Damage = dmg                                    # dead
        reflection (§4.1) with dmg                              # before the GM override below
        # SS_HPUPRATE + SS_THHPUP (PowerDrain01…20: rate 1000 (three lower ones 500/400/350), heal 490 … 1154 HP)
        healOnHit = 0
        if s.sdi_HPUPRATE.exist:
            if rand(1000) < sdi_HPUPRATE.value − 1000 + se_Argument[13] PROBABILITYRATE:
                healOnHit = (sdi_THHPUP.value + 0) · se_Argument[9] HPDRAINRATE / 1000   # flat HP, not a share of dmg
                if a.so_GetItemActionObserves(): item action SEIT_SS_RATE_THHPUP on healOnHit (Z17 §3)
        if a.smo_admindamage > 0: dmg = a.smo_admindamage       # GM &admindamage (Z11): fixed damage per hit
        # SS_DIEHPUP (no 2016 skill uses it)
        healOnKill = 0
        if s.sdi_DIEHPUP.exist:
            bos.bos_MyHealKill += sdi_DIEHPUP.value · dmg / 1000                         # dead
            if rand(1000) < sdi_HPUPRATE.value − 1000 + se_Argument[13]:                 # HPUPRATE's chance
                healOnKill = sdi_DIEHPUP.value · se_Argument[9] / 1000
                # without SS_HPUPRATE the chance is PROBABILITYRATE − 1000 = 0: never (original bug) Z25-B4
        rest = dmg < hp0 ? hp0 − dmg : 0
        r = { target d, iscritical = ctx.iscritical, ismissed = ctx.ismiss, isheal 0, isresist 0,
              resthp rest, isImmune = ctx.isImmune, hpchange dmg }
        if not d.so_AmIAlreadyDead():
            if not ctx.ismiss and ((rule == &roe_physical and d has STA_ACMODE 201)
                                or (rule == &roe_magical  and d has STA_MRMODE 202)):
                r.isdamage = 0; r.isheal = 1; r.hpchange = dmg; r.resthp = hp0 + dmg      # damage becomes healing
                bos.bos_Damage = 0; bos.bos_Heal = dmg                                     # dead
            elif rest < 1:
                d.so_YouHaveAlreadyDead() (vt 0x24)            # alreadydead = 1: later hits of this blast skip d (§2.1)
                r.hpchange = dmg; r.resthp = 0
        else:
            r.hpchange = dmg; r.resthp = 0
        for each element e of a's own abstate list (a.smo_Abstate.abstatelist):
            abstateidentarray[e.aeo_Index].actor.sasa_Act_AttackCount (actor slot 0x40)(e)
                # HideDamage counts the attacker's hits (Z22 §9.4); Z22 lists only smo_SwingDamage as caller
```

The `canDamage` test means a skill that both heals and damages (none in 2016) heals friends and damages enemies.
On a target that may not be damaged and has no heal part, `r.isdamage = 0` and the slot still goes out (as an
enchant-only result, §2.7 onwards).

#### 2.5.1 `RuleOfEngagementHealAttack::roe_CalcDamage`  @ FUN_005002a0

The rule set the six `Heal` skills (`First = TARGET_EVERY`) use against `MT_DEVIL` mobs:

```pseudo
    db = ctx.def.vt[0x70c]()
    if db == null or db.MobInfo.Type != MT_DEVIL: return 0
    span = db.MobInfoServer.DmgByHealMax (+0xa3) − DmgByHealMin (+0xa1);  if span < 2: span = 1
    n = rand(1000000)
    roe_LevelGapDamageRevision(this, ctx.att, ctx.def, ctx.att ? ctx.att.vt[0xd2c](ctx.def, 0) : 0)
        # FUN_00500180 returns the level-gap-adjusted damage; the result is discarded (original bug) Z25-B5
    return (u16)(DmgByHealMin + n % span) · s.sdi_HEALAMOUNT.value / 1000
```

`roe_IsDamageSkill` of this class is the folded stub FUN_00500380 (`return 1`), so the heal deals damage even though
heal skills have `UsualAttack = 0`. The hit roll still used the skill's own rule (§2.2). 64 `MobInfoServer` rows
carry DmgByHeal values (e.g. `DevilHoneying` 1000…10000, Cracker mobs 83).

### 2.6 After the damage part: RECALL, HPCONVERTSP, MANABURN  (0x582080 – 0x582122)

These run on every hit target, whether or not it took damage.

```pseudo
    if not d.so_AmIAlreadyDead() and s.sdi_RECALL.exist == 1 and (m = d.so_ShineMobileObject()) != null:
        smo_JumpTo(m, a.so_LocateInfo.location, s, a)          # pull d to the caster: lands sdi_RECALL.value short
                                                                #   of the caster (Z09 §9.3 smo_JumpTo, row+0x248/+0x24c),
                                                                #   0x482D NC_SKILL_JUMP_CMD; failure is ignored
        # 2016: S_Anika_Skill02_N (100), KDFargels_Skill07_W (50)
    if s.sdi_HPCONVERTSP.exist: a.so_GainSP (vt 0x4fc)(sdi_HPCONVERTSP.value)     # VitalConversion01…20: +162 … +854 SP
        # to the caster, once per hit target; no packet here (SP reaches the client with the next stat update, Z12)
    if s.sdi_MANABURN.exist:                                                       # ManaBurn01…20: 150 … 3050
        d.so_LostSP (vt 0x4f8)(sdi_MANABURN.value)                                 # floors at 0 (Z21)
        so_AllOfRange(d, range, d.pos, …, so_ply_Send2WhoTargetMe)                 # FUN_00568ee0: HP/SP bar to
                                                                                   #   everyone targeting d (Z03 §2.3)
```

The skills' own HP cost (VitalConversion's "HP → SP") is the normal skill cost (Z03 §5.3); the special only adds SP.

### 2.7 SS_HOLDME: the caster holds still  (0x582122 – 0x58221c)

Runs on every hit target, whatever the damage part did (also on each multi-hit step).

```pseudo
    if s.sdi_HOLDME.exist:                                     # FatalShadow01…05 (value 500 on all five)
        r.target = d                                           # the slot goes out even when nothing else happened
        for idx in (STA_CANNOTCHANGETARGET 392 = StaCannotChangeTarget, STA_SHADOWBINDING 393 = StaShadowBinding):
            if dic_abstate.as_StateIndexList[idx] == null: continue          # AbState row present (2016: both)
            a.so_AbnormalState_Set (vt 0x638)(a, idx, strength 1, entry, now, extra 0, restCount 0,
                                              keepMs = sdi_HOLDME.value, EF_JUSTENCHANTBATTLEOBJECT 5, null)
            so_AbnormalState_BitSet(a, idx)                    # FUN_00401a00: brief bit (obj vt 0x4a0 bit array)
            so_AbnormalState_BroadcastSet(a, idx, sdi_HOLDME.value, 1)       # FUN_004056a0: 0x2427 + 0x1C18 to a's sight (Z03 §6.3)
            a.so_AbnormalState_Inform (vt 0x3f0)(idx, sdi_HOLDME.value, 0)   # player FUN_00405900: 0x242A
                                                                             #   NC_BAT_ABSTATEINFORM_NOEFFECT_CMD to a; mobs: no-op
            # the result of so_AbnormalState_Set is not tested: bit, broadcast and inform also go out when the set
            # fails (map refusal fm_IsRefuseAbstate, Z22 §7.5; a stronger state of the same group, Z03 §6.2)
            # (original bug) Z25-B8
```

The states go on the **caster** (`a` in ECX and as setter, checked at 0x58216d / 0x582170), not on the target:
FatalShadow's own abstates (`StaFatalKnockBack` 1, `StaFitMoveDown` 8, both rate 1000) go to the target through
`so_SkillEnchant` (§2.9), and the caster is pinned for 500 ms. 2016 rows: 392 `StaCannotChangeTarget`
(SubAbState `SubStaKeepTime_7Sec`, Strength 999 = any strength (§1.4), Type 38 DEFAULT, no action) and 393
`StaShadowBinding` (`SubStaShadowBinding` strength 1, Type 23 ENTANGLE, action 19 NOMOVE: `cannotmove_entangle`,
Z12 §2.5). The keep time is HOLDME's value, not the rows' KeepTime (7000 / 500), because a non-zero `keepMs` wins in
`aeo_Set` (§1.4). 392 is read by `sp_NC_BAT_TARGETTING_REQ` FUN_0042ffe0 (Z03 §2.2: a player with it cannot change
target); nothing else tests 392 or 393 by index.

### 2.8 Keep-time specials: SS_FIRETIMEADD, SS_CURSETIMEADD, SS_POSIONTIMEADD  (0x58221c – 0x5824ad)

Also on every hit target and every multi-hit step, in this order:

```pseudo
    for (special, types) in ((sdi_FIRETIMEADD,   [SUBAB_BURN 83]),
                             (sdi_CURSETIMEADD,  [SUBAB_CURSE 35, SUBAB_CURSEMR 50, CURSETH 51, CURSEAC 52,
                                                  CURSETB 53, CURSEDEX 54, CURSEWC 55, CURSECRITICAL 57]),
                             (sdi_POSIONTIMEADD, [SUBAB_POISON 33])):
        if not special.exist: continue
        v = special.value                                      # ms; signed (CURSETIMEADD rows are negative)
        if a.so_GetItemActionObserves() (vt 0x5d0) and s.sdi_ActiveSkillGroups not empty:
            if EventRunBySkillGroupIndex(results, s, SEIT_KEEPTIME_RATE_INCREASE, a, d): v = results.GetRateAppliValue(v)   # Z17 §3.4.3
        for type in types: d.so_smo_AbStateKeepTimeAdd (vt 0xa5c)(type, v)
```

```pseudo
ShineMobileObject::so_smo_AbStateKeepTimeAdd(o, SubState type, int ms)          @ FUN_0040bd20 (every mobile class; vt 0xa5c)
    list = o.so_mobile_AbstateList() (vt 0x52c)
    for each element e of list (index-linked list +0xcb0, in list order):
        sub = abstateidentarray[e.aeo_Index].entry.subabstate[e.aeo_Strength].assa_info      # the element's SubAbState row
        if sub.Type != type: continue
        rest = e.aeo_Tick.terminate − now                       # ticks of 100 ms
        e.aeo_Tick.terminate += ms · 10 / 1000                  # signed: a negative ms shortens; no clamp at now
        send o (vt 0x2fc: player game socket; others so_dummypacketcontainer = nothing):
            0x242A NC_BAT_ABSTATEINFORM_NOEFFECT_CMD { u32 abstate = e.aeo_Index, u32 keeptime_millisec = rest·100 + ms }
            # 10 bytes with the opcode; the "Packet Too Long" assert text is copied from so_AbnormalState_Inform
```

No 0x2427 / 0x1C18 goes to the others in sight: only the bearer's own icon timer is refreshed. A state that ends
earlier than `now` through a negative `ms` is removed by the normal expiry on its next routine (Z03 §6.4).
With `|ms| > rest·100` the sent `keeptime_millisec` is negative; the client's handler
`GameFrameWork::On_NC_BAT_ABSTATEINFORM_NOEFFECT_CMD` FUN_004b55d0 converts it as unsigned (`< 0` → `+ 2^32`), so
the icon shows about 49.7 days until the reset arrives (original bug) Z25-B13. The client handler also prints a
system message by the state's client `DispelIndex`: 3 "An illness spell is casted on you." (0x4EFACDCB), 4 "A poison
spell is casted on you." (0x6808C3CC), 5 text 0x0A653383 (not in the 2016 TextData tables); state 0x151 adds "You
have temporarily lost hearing.". So DeepFire / FragranceOfPoison re-announce the state to the victim.

2016 data (all `TargetNumber` 1, EffectType 0, `UsualAttack` 0, skill hit type 2):

| Special | Skills (value, ms) | Effect |
|---|---|---|
| SS_FIRETIMEADD 41 | DeepFire01…05 (5000, 10000, 20000, 50000, 60000) | burns (Type 83) on the target last longer |
| SS_CURSETIMEADD 40 | ResistCurse01…05 (−20000, −25000, −30000, −40000, −50000; stored as u32 4294947296 …) | the friend's curses end sooner |
| SS_POSIONTIMEADD 44 | FragranceOfPoison01…04 (5000, 10000, 20000, 50000) | poisons of Type 33 last longer; the other poison-actor types (22 BLOODING, 27 DOTDAMAGE, 67, 84 FITBLOODING, 94; Z22 §3.2) are not touched |

### 2.9 Single-hit tail: abstates, dispel, item actions, SS_SUCKHP  (`hit.mha_HitStep < 0`: `cmp -1` at 0x5824ad → 0x5828c8 – 0x582d5b)

```pseudo
    if hit.mha_HitStep < 0:
        if not ctx.isImmune:
            smash = SmashArgument { flags 0, sklidx = s, empower = *empower }
            ok = a.so_SkillEnchant (vt 0x5a0, FUN_00431ca0)(d, &smash, &bos, &resisted, canDamage)   # Z22 §10.7
                                                       # (the 5th argument, canDamage, is unused there)
            if ok: r.isenchant = 1
            r.target = d;  r.isresist |= resisted
        smo_Dispel(a, s, empower, d, &bos)             # FUN_0057d8e0 (Z23 §8.1)
        inline copy of smo_Dispel's body (same mask, vt 0x5a4 so_SkillCure, vt 0x5a8 so_Dispel, r.target = d,
            r.isenchant = 1, r.isresist = 0)           # Z23 §8.4: everything runs twice (Z23-B13 / Z22-B16, Z22-B22)
        bol_Store(&bos, now + SwingTime·…)             # no-op (§1.2)
        if d.so_GetItemActionObserves() (vt 0x5d0):    # target-side item actions (Z17 §3.4.3)
            EventRun(d's manager, { cond {AAT_AttackType, AT_SKILL}, me = object = d, subject = a })
            EventRun(… AT_PHYSIC if sdi_ServInf.SkillHitType == SHT_FROM_PY_NORMAL_HITRATE else AT_MAGIC …)
        healOnHit = (the HPUPRATE result of §2.5, else 0)
        if s.sdi_SUCKHP.exist == 1:                    # KDFargels_Skill06_N (value 999; mob skill, UsualAttack 1)
            mx = d.so_MaxHP() (vt 0x4f0)
            n = (value == 999) ? mx − 1 : mx · value / 1000
            if n >= d.so_GetHP(): n = d.so_GetHP() − 1          # leave the target 1 HP …
            if n < 1: n = 1                                     # … except at 1 HP, where the 1-point drain kills
            r.hpchange = n;  r.resthp = d.so_GetHP() − n       # replaces the damage part's values
            bos.bos_MyHealHit += n;  healOnHit = bos.bos_MyHealHit   # = HPUPRATE heal + n
            bos.bos_MyHealKill += n; healOnKill = bos.bos_MyHealKill
                # bos_MyHealKill held DIEHPUP·dmg/1000 (§2.5), so the rolled healOnKill is replaced by it (latent:
                # no 2016 skill has both)
            # r.isdamage / r.isheal / r.isImmune are left as the damage part set them: n is dealt as damage
            # through sds_TemplateStore (§3) and the caster heals n on the hit (a.so_Heal(healOnHit))
            # (original bug) Z25-B10: the drain ignores immunity (an immune target keeps isdamage = 1 and loses n)
            # and the AC / MR-mode conversion (r.isheal = 1: the target is *healed* by n)
        d.vt[0x654](n or the damage of §2.5)           # empty for every class (shared `ret 4` FUN_00549070; the PDB
                                                       #   folds the name so_ply_CollectCardOpen onto it): nothing
        if r.target == null: return                     # nothing to report: no slot, no aggro (bufferpoint unchanged)
```

### 2.10 Multi-hit tail: the step's abstates  (`hit.mha_HitStep ≥ 0`: 0x5824b6 – 0x5828c8; common end 0x582d5b – 0x582d8b)

`hit.mha_AbState[4]` = `{ int mha_AbStateRate; ABSTATEINDEX mha_AbStateIndex; int mha_AbStateStrength }` *(pdb2016)*,
filled by `sbec_Store` (§6.4): for a MultiHit step only entry 0 (the step's `oh_AbState`); a negative `mha_HitStep` (no
`HitID`, or a chain wave) takes the single-hit tail of §2.9 instead.

```pseudo
    else:
        if not d.so_AbnormalState_IsSet(STA_ADLFLOUSSIERIMT 499) and not d.so_AbnormalState_IsSet(STA_IMMORTAL 291):
                                                       # already refused at entry (§2.1): always true here (original bug) Z25-B12
            for k in 0..3: (rate, idx, str) = hit.mha_AbState[k]
                if rand(1000) >= rate: continue
                entry = as_FromIndex(&dic_abstate, idx)
                if entry == null or entry.index == null:
                    assert "BattleObjectGroup::BattleObject::bo_Routine : Invalid abstateidx" (idx); continue
                if d.so_AbnormalState_Resist (vt 0x634)(entry): r.isresist = 1; continue       # Z03 §6.2
                bonus = empower.keeptime ? s.sdi_Activ.nT1[keeptime + 4] : 0      # = nT2[keeptime − 1], as Z22 §10.7
                keep  = entry.subabstate[str].assa_info ? .KeepTime : 0
                if a.so_GetItemActionObserves() and s.sdi_ActiveSkillGroups not empty:
                    keep = item-action SEIT_KEEPTIME_RATE_INCREASE rate applied to keep        # Z17 §3.4.3
                # unlike so_SkillEnchant: no BiffTimeIncrease passive bonus (Z22 §10.7)
                if d.so_AbnormalState_Set (vt 0x638)(a, idx, str, entry, now, extra = bonus, restCount −1,
                                                     keepMs = keep, EF_JUSTENCHANTBATTLEOBJECT 5, null):
                    x = asl_Abstate_IsSet(d's list, idx)                     # FUN_00409b10
                    if x: a.so_ItemActonAbstateApp (vt 0x5d4, FUN_0055dea0)(x, s, d)     # Z22 §10.7
                    if entry.index.PartyRange == 0 or entry.index.PartyEnchantNumber == 0:  # not a party state
                        so_AbnormalState_BitSet(d, idx)
                        shown = keep + bonus
                        d.so_AbnormalState_Inform (vt 0x3f0)(idx, shown, 1)  # 0x2429 NC_BAT_ABSTATEINFORM_CMD to d (player)
                        so_AbnormalState_BroadcastSet(d, idx, shown, str)   # 0x2427 + 0x1C18 to d's sight
                    r.isenchant = 1
                # (original bug) Z25-B9: aeo_Set uses `extra` only when keepMs == 0 (§1.4); with a row KeepTime the
                # empower bonus is shown (0x2429 / 0x1C18) but never applied. `shown` is also not scaled by
                # SET_ABSTATEKEEPTIMERATE as aeo_Set scales the real time (latent: 1000 in 2016), and BroadcastSet
                # sends the requested strength, not the stacked one (g_NewAbstateStrength, Z22 §10.7)
        smo_Dispel(a, s, empower, d, &bos)             # once (Z23 §8.4)
        if not rule.roe_IsDamageSkill(ctx) (vt 0x20; rule as chosen in §2.5):
            d.vt[0x700](a, bos.bos_AbsoluteAggro)      # mobs: so_mob_AppendAggro. bos_AbsoluteAggro = AbsoluteAggro,
                                                       #   +1 when a is a player and the skill has AggroPerDamage or AbsoluteAggro
            # sds_TemplateStore adds AbsoluteAggro once more for the same slot (§3): (original bug) Z25-B11
        if hit.mha_HitStep == 0 and d.so_GetItemActionObserves():
            the two target-side EventRun calls of §2.9 (first step only)
        healOnHit = (the HPUPRATE result of §2.5, else 0);  healOnKill = (the DIEHPUP result, else 0)
    sds_TemplateStore(a, r, absAggro = sdi_ServInf.AbsoluteAggro, rateAggro (§2.3), healOnHit, healOnKill)   # §3
    bufferpoint += 1
```

The multi-hit path calls `sds_TemplateStore` even when `r.target` is null (it returns at once, §3) and still
advances `bufferpoint`, so an empty step uses one of the 64 result slots of the blast (§2.1 refuses targets at
`bufferpoint > 63`). Single-hit skills never reach this branch with an empty slot: `r.target` is set by §2.9's
enchant call whenever the target is not immune.

Summary of what one blast target receives, by path: hit roll (§2.2) → DISPELABSTATE (§2.3) → heal or damage
(§2.4, §2.5) → RECALL / HPCONVERTSP / MANABURN (§2.6) → HOLDME (§2.7) → keep-time specials (§2.8) → either the
skill's own abstates + double dispel + SUCKHP (§2.9) or the step's abstates + one dispel (§2.10) → result record
(§3). All packets of the hit itself go out later in the one 0x2452 of `sds_Finish` (Z03 §5.6); the abstate packets
(0x2427 / 0x1C18 / 0x2429 / 0x242A) and 0x2428 go out at once.

## 3. Committing a result: `SkillDamageSender::sds_TemplateStore`  @ FUN_005803c0

Called once per result slot by `smo_SkillBlast` (miss and hit paths) after the slot is filled. Applies HP changes and
queues the `SkillDamage` record that `sds_Finish` sends in `0x2452 NC_BAT_SKILLBASH_HIT_DAMAGE_CMD` (Z03 §5.6).

```pseudo
sds_TemplateStore(this = &skilldamagesender, a, r, absAggro, rateAggro, healOnHit, healOnKill)
    t = r.target;  if t == null: return
    rec.handle = t.handle
    rec.flag byte 0 = isdamage | iscritical<<1 | ismissed<<2 | isshieldblock<<3 | isheal<<4 | isenchant<<5
                      | isresist<<6 | IsCostumWeapon<<7
    rec.flag byte 1 = (r.resthp == 0) (isDead) | isImmune<<1 | IsCostumShield<<2 | bits 3–7 of the stack byte
                      # never initialised (0x5804a6…0x5804db) (original bug) Z25-B6
    rec.hpchange = r.hpchange
    rec.hpchangeorder = t.so_mobile_GetHPChangeOrder() (vt 0x7e8: ++t.smo_HPChangeOrder)
    t.vt[0x700](a, absAggro)                                   # mobs: so_mob_AppendAggro; players: nothing
    if r.isdamage:
        dmg = t.vt[0xbe8](r.hpchange)                          # player: so_ply_CheckDamageAbsorption FUN_00579860 (Z09);
                                                               #   mob: identity (folded stub FUN_00642df0)
        dmg = t.so_smo_LastDamageOperation (vt 0xdb4)(dmg, 0)  # Z22 §9.7 (min-HP states, damage hooks)
        r.hpchange = dmg
        if dmg < t.so_GetHP(): clear isDead in rec.flag        # the absorbed damage no longer kills
        if not isDead:
            t.so_DamagedBy (vt 0x5c0)(a, dmg, rateAggro, 1)    # Z03 §7 (player FUN_00431500, mob FUN_00431750)
            a.so_Heal (vt 0x4e4)(healOnHit)                    # SS_THHPUP
            t.vt[0xbd4]()                                      # player: so_ply_DmgCoolTimeDown (Z23 §3.4); mob: nothing
            t.so_RecoverAlreadyDead (vt 0xdb0)()               # FUN_00555790: alreadydead = 0 (undoes §2.5's marker)
        else:
            t.so_KilledBy (vt 0x5bc)()                         # Z03 §7 / §8
            a.so_Heal(healOnKill); a.so_Heal(healOnHit)
            t.vt[0xbd4]()
        a.vt[0xa38](8, t.handle, 0)                            # player: notifyObservers EV_ATTACKMOB (Z09); mob: nothing
    if r.isheal:
        before = t.so_GetHP(); t.so_Heal(r.hpchange); r.hpchange = t.so_GetHP() − before    # actual gain
        t.so_SpyAgent() (vt 0x480) report ring: { SRT_GETHEAL 1, healer a, amount = rec.hpchange (the requested
            heal, not the actual gain), rateAggro }            # read by mob aggro (Z09 §28.2, which says "HP actually healed")
        Lua ranking hook 0xac (fm_LuaScriptFuncExec), each only if that object is a player (vt 0xbbc) on a map whose
            script has a RankingValue (Z09 §14 table: `LuaArgumentRankingValue(map, p, dealt, taken, healed)` FUN_005d7a40):
            a's map:  LuaArgumentRankingValue(map, a, dealt = gain, taken = 0, healed = 0)
            t's map:  LuaArgumentRankingValue(map, t, dealt = 0, taken = 0, healed = gain)
            # (original bug) Z25-B22: the healer's heal is ranked as damage dealt, and the healed target is ranked
            #   as the one who did the healing
    rec.hpchange = r.hpchange;  rec.resthp = t.so_GetHP()
    a.vt[0xbf8](0, t, r.isdamage, 0); a.vt[0xbf8](3, a, r.ismissed, 0)    # player: so_ply_PassiveSetAbstate (Z17)
    if not t.smo_GetFlagDamageAbsorb() (vt 0xbec, smo_Flag.DamageAbsorb): sds_List.push_back(rec)
        # targets flagged DamageAbsorb (Z16) take the effect but are left out of 0x2452
```

The killing hit's `so_KilledBy` runs here, inside the blast, before `sds_Finish` broadcasts 0x2452; the packet then
carries `resthp = 0` and `isDead`. A heal's `resthp` in the slot (`hp0 + h`, §2.4) only matters for the isDead bit;
the packet takes the real HP.

## 4. Damage reflection

### 4.1 Trigger (in `smo_SwingDamage` FUN_00432f30 and `smo_SkillBlast`)

```pseudo
    P = d.so_parameter()                                       # vt 0x430
    if P.DamageReflection (+0xcd2, u16) != 0:
        part = P.DamageReflection · dmg / 1000                 # dmg = the hit's damage (miss: a fresh roe_CalcDamage)
        if P.RangeOver (+0xda8) == 0 or dist²(a, d) > RangeOver²:
            a.smo_ReflectionDamage (vt 0xf5c)(part, d)
```

`DamageReflection` / `RangeOver` are summed from abnormal-state actions `SAA_REFLECTDAMAGE` (61) and
`SAA_RANGEOVER` (60) (Z12 §2.5 table). So the reflection only hits attackers farther away than
`RangeOver` (ranged / magic attackers) when that is set. 2016 states with action 61 (`SubAbState.shn`):
`SubSta_B_Albi_Reflect` (500 ‰, RangeOver 500), `SubSta_BH_Albi_Reflect` (750 ‰, 900), `SubStaGTIReflect`
(2000 ‰, 900), `SubStaBH_HelgaDRT01` (5000 ‰, 500): boss states only.

### 4.2 `ShineMobileObject::smo_ReflectionDamage(a, dmg, d)`  @ FUN_0055dbc0

`this = a` is the attacker who gets hurt, `d` the reflecting defender.

```pseudo
    if d == null: return
    ctx = EngageArgument(a, d, null skill, null empower, a.so_mob_RegenLocation()); ctx.ismiss = 0
    h = a.handle (vt 0x568, folded so_GetZoneHandle_ItemLooter = so_handle.sohu_Handle)
    o = som_GetObject(&shineobjmanager, h)
    if o == null: assert "ShineMobileObject::smo_ReflectionDamage Not Find Handle" (h); return
    am = ShineDynamicCast<ShineMobileObject>(o);  dm = ShineDynamicCast<ShineMobileObject>(d);  either null: return
    dm.smo_AttackedDamage (vt 0xef0)(am, dmg, &ctx)            # FUN_0042aeb0 (Z03 §7.1): d damages a; may kill a
    list = asl_GetAbstateList(dm.so_mobile_AbstateList());  null: return     # damage dealt, no packet
    ab = 0x318 (none)
    for e in list (oldest first): if aeo_GetIndexArgument(e).assa_IsHaveEffect(SAA_REFLECTDAMAGE): ab = e.aeo_Index; break
    if ab == 0x318: assert "ShineMobileObject::smo_ReflectionDamage Not Find Aicton" (0); return
    broadcast to a's sight (so_AllOfRange_Simple FUN_00553c20 = so_AllOfRange(a, allofrangearg, a.pos, radius 0,
        no sector, it, 1, 0xffff): the same sight broadcast as the 0x2457 of §6.2):
        0x245B NC_BAT_REFLECTIONDAMAGE_CMD {                    # 14 bytes
            u16 abstate          = ab                          # ABSTATEINDEX of d's (first) reflecting state
            u16 ReflectionObject = d.handle
            u16 TargetObject     = a.handle
            u32 resthp           = a.so_GetHP()                # after the damage
            u16 damage           = (u16) dmg                   # the requested amount, truncated (original bug) Z25-B7
            u16 hpchangeorder    = a.so_mobile_GetHPChangeOrder()
        }
```

The reflected damage goes through `smo_AttackedDamage`, so the attacker's own damage hooks, StaACMode / MRMode
healing and death apply; the packet's `damage` is the amount requested, not what the hooks let through, while
`resthp` is the true HP.

Client (`GameFrameWork`, FUN_004b6980 via dispatcher FUN_004be490, `re-data/client-handlers.json`):

- `ReflectionObject` known and `abstate` resolves to an abstate view row with an effect: plays that effect on the
  reflector, attached at "Ground", "HairLink" or "Chest" by the effect's attach name.
- `TargetObject` unknown: stop. If it is the own character and `damage != 0`, the client refreshes some own-character
  UI parts (FUN_0057eeb0 on the HUD gauges *(inferred)*).
- Damage number (vt 0x198) when `damage > 0` and `abstate ∉ { 14 STA_VIOLENCE, 339 STA_KARENDOTHEAL, 0x318 }`.
- `resthp == 0`: the target's death animation (vt 0x280 or FUN_0063d130). Then the HP is set with
  `hpchangeorder` (FUN_006327b0), and the target bar too when the target is the own selection (FUN_006328e0).
- A combat-log entry (FUN_00693d40 with the target and damage) unless the death branch applied.

## 5. Dispel and cure: what the masks remove

The bodies are documented: mask construction `smo_Dispel` FUN_0057d8e0 and `so_SkillCure` FUN_0042c440 /
`so_Dispel` FUN_0042bf70 in Z22 §7.5 and Z23 §8.1–8.4 (with the double run of Z23-B13 and the servant kill through
`so_MiscTable` vt 0x984 `mds_Dead.ByDebuff`, Z09 §13.3 `Debuff = Dead`). Removal sends nothing at once: the element's
`terminate` is set to now and the next abstate walk sends 0x2428 NC_BAT_ABSTATERESET_CMD and runs the detach (Z03 §6.4,
Z22 §7.1); the slot only gets `isenchant = 1` (and the client shows the skill's effect). This section adds the data
side.

A state is removable when its `AbState.shn` `DispelIndex` bit is in the mask (`mask & (1 << DispelIndex)`).
`SubDispelIndex` is not read by any dispel code; it selects resist classes (`so_AbnormalState_Resist`, Z03 §6.2).
2016 `AbState.shn` (777 rows) by `DispelIndex`:

| DispelIndex | Mask bit | Rows | Examples | Set by `smo_Dispel` when |
|---|---|---|---|---|
| 0 DA_NONE | 0x001 | 291 | StaMightySoul…, party sub-states | never: undispellable |
| 1 DA_GOOD | 0x002 | 229 | StaSpeedShield, StaBersekerFrenzy, StaBlessingMain | enemy target, no DISPELDEEPER, no DETECT |
| 2 DA_DEBUFF | 0x004 | 98 | StaSeverBone, StaMoraleDecreaseWC, StaBreak | friend, SS_DISPELDEBUFF |
| 3 DA_DISEASE | 0x008 | 23 | StaPoisonShot, StaSkelKnightDisease | friend, SS_DISPELDISEASE, or SE_CURE (0x18) |
| 4 DA_POISON | 0x010 | 43 | StaRedSlash, StaPsychicChopBlood, StaBoneArrow | friend, SS_DISPELPOISON, or SE_CURE |
| 5 DA_CURSE | 0x020 | 24 | StaKebingCurse, StaKingCrabCurse | friend, SS_DISPELCURSE |
| 6 DA_STUN | 0x040 | 47 | StaBattleBlowStun, StaIceField | never |
| 7 DA_FEAR | 0x080 | 15 | StaDrainMindFear, StaGhostFear | never |
| 8 DA_DEEPER | 0x100 | 1 | StaDeeper | enemy, SS_DISPELDEEPER, the caster's own StaDeeper on it |
| 9 DA_HIDE | 0x200 | 3 | StaHide, StaEntrapHide, StaPolymorph | enemy, SS_DETECT (without DISPELDEEPER) |
| 10 DA_BOMB | 0x400 | 1 | StaBombShot | friend, SS_BOMBDISPELALL |
| 11 DA_CHARGED | 0x800 | 2 | StaACRedDragon, StaMRBlueDragon | never |

Stun, fear and the charged dragon states cannot be dispelled by any skill. `so_SkillCure` (SS_CURE grade) works on
DA_DISEASE / DA_POISON with `StateGrade ≤ sdi_CURE.value` and is independent of the mask.

2016 dispel / cure skills (`ActiveSkill.shn`, EffectType 8 SE_CURE / 9 SE_DISPEL; specials in brackets):

| Skills | EffectType | Specials | Friend target | Enemy target |
|---|---|---|---|---|
| GreatCure01…03 | CURE | SS_CURE 1…3 | cures the oldest disease/poison up to that grade (`so_SkillCure`; mask 0x18 has no remover flag) | the same cure (`so_SkillCure` has no friend test); mask 0x02: nothing |
| DispelPurge, KarenCaptivate, E_Zombie_Atk | DISPEL | DISPELALL | mask 0: nothing | all buffs (DA_GOOD) |
| DispelMagic | DISPEL | DISPELALL, DISPELDEBUFF, DISPELCURSE | all debuffs and curses | all buffs |
| DispelPillar, SunLight | DISPEL | DISPELALL, DEBUFF, CURSE, POISON, DISEASE | all four bad kinds | all buffs |
| Detect, FireTotemDetect | DISPEL | DISPELALL, DETECT | nothing | all hide states |
| Bleach | DISPEL | DISPELONE | nothing | the oldest buff |
| DispelTrick01…04 | DISPEL | DISPELONE, DEBUFF, CURSE | the oldest debuff / curse | the oldest buff |
| Release | DISPEL | DISPELONE, CURSE, DISPELDEEPER | the oldest curse | the caster's own StaDeeper |
| DispelField | DISPEL | DEBUFF, POISON, DISEASE, DISPELRANDOM | one random bad state | one random buff |
| Purification, Psy_Mist_Skill_W | DISPEL | DISPELRANDOM | nothing | one random buff |
| StealEnchant | DISPEL | STEALENCHANT 500 | nothing | 50 % to steal the newest buff |
| GhKnightBufSkill | DISPEL | DISPELDEBUFF | mask 0x04, no remover flag: nothing | mask 0x02: nothing |
| BombDispel | DISPEL | BOMBDISPELALL | the bomb, defused (f_Dispeled) | mask 0x02, no remover: nothing |
| RStone_Skill01_W, AdlF_Loussier_Skill01_N | DISPEL | none | nothing | nothing |

("Friend" / "enemy" = `so_mobile_IsEnemy`, vt 0x72c; a remover flag is DISPELONE / DISPELALL / DISPELRANDOM /
BOMBDISPELALL / STEALENCHANT, Z22 §7.5. With the double run of Z23-B13, the DISPELONE and DISPELRANDOM rows can
remove a second state and StealEnchant rolls twice.) The SS_DISPELABSTATE path (§2.3) is separate and needs no
EffectType.

## 6. Blast entry points, target scans and chained blasts (outside `smo_SkillBlast`)

This section covers what happens between the end of a cast and the per-target `smo_SkillBlast` (§2). Z03 §5.4 / §5.6
give a summary of it. Z23 §2.5 (toggle switch) and Z17 §3.4.3 (the item-action `EventRun` calls in these functions)
already document parts of it; this section cites them and does not repeat them.

### 6.1 Which blast runs: `ShineMobileObject::so_Routine`  @ FUN_0056a080

The cast part of `so_Routine` (after the abstate, fear and move steps of Z09 §5.5) runs these checks, then picks
one blast:

```pseudo
    if cast.scs_BlastTime == 0: return;  s = cast.scs_ProduceSkill.sklidx;  if s == null: cast.scs_BlastTime = 0; return
    if g_Now < cast.scs_BlastTime:                                # still casting
        if o.so_parameter().IsNoAttack() or smo_SkillBlastOption(o) == SB_SILENCE: o.smo_CastAbort (vt 0xed4)
        return
    o.vt[0xef8](s.ID)                                             # set-item skill effect of this cast (Z21 l. 200)
    produce branch (prdidx) / item branch (scs_UseItem): Z23 §3.6, Z13 — return
    if cast.target and not cast.target.vt[0x7e4](s.SkillTargetState):         # target state (live / corpse) changed
        o.smo_CastAbort();  o.smo_ply_NextBashTime (vt 0xec0);  return
    if not o.smo_SPCheck (vt 0xedc)(skill, s, &empower): CastAbort; NextBashTime; return
        # player FUN_0055bc20 = csl_SPCheck test only (Z23 §4); mob FUN_005557f0 tests **and pays** SP unless InSkillShift
    if o.so_parameter().IsNoAttack() or smo_SkillBlastOption(o) == SB_SILENCE: o.smo_CastAbort(); return   # Z22 §10.2
    so_AllOfRange(o, sight, member function so_ply_Send2WhoTargetMe)            # 0x2402 refresh for whoever targets o (Z22 §10.6)
    o.smo_ply_WeaponTitleSet (vt 0xec8)(cast.target ? cast.target.so_mob_MobID() : 0xFFFF)   # Z12 l. 310
    if s.sdi_WHOLEAGGRORATE.exist:                                # no 2016 skill
        o.vt[0xee0](skill, s, &empower)                           # player smo_SPCheckConsume: cost paid here …
        o.smo_ply_AggroAdjust (vt 0xebc)(WHOLEAGGRORATE.value, WHOLEAGGRORANGE.value)   # Z09 §6.2 (its "+200 / +0xcc / +0xd4")
    if s.EffectType == SE_TELEPORT (6):  o.vt[0xee0](…);  o.so_mobile_Teleport (vt 0x6d8)()      # Z09 §9.3; no blast; no 2016 skill
    else if s.EffectType == SE_VOLLEY (12):  o.vt[0xee0](…);  o.so_ply_Volley (vt 0x994)()       # below; no blast
    else if s.sdi_MAGICFIELD_KEEP.exist or s.sdi_MAGICFIELD_PARTY.exist:
        smo_MagicFieldSpread(o, s)                                # Z09 §12 (its SETABSTATEME / NOTTARGET: Z09 l. 3689)
    else if cast.scs_Skill == sdb_SpecSkillStruct().ss_SummonMate: partner summon   # Z13 §4.6 (0x2457 to sight, sbec_Store with target = o)
    else if s.sdi_RANDOMTARGETNUMBER.exist:                                      # chain skills (§6.8)
        if s.sdi_Activ.TargetNumber == 1:
            if s.IsMovingSkill: smo_Flag.InSkillShift = 1
            if not InSkillShift: cast.scs_BlastTime += 3; InSkillShift = 1; return     # arming pass, as in §6.2
            InSkillShift = 0
            o.smo_LightningWaveSkill (vt 0xbf4)(s, o.smo_SkillIndexLastCasting, from = o, to = cast.target,
                                                 o.smo_SetEffectForJustSkill() (vt 0xefc), depth = 1)
            # depth 1 is the `push 1` at 0x56a7e2, left on the stack across the vt 0xefc call
        else:
            smo_SkillBash_Blast(Loc)(o, cast.target ? cast.target.pos : &cast.locate, &cast.empower)   # §6.3
    else if cast.target == null: smo_SkillBash_Blast(Loc)(o, &cast.locate, &cast.empower)
    else:                        smo_SkillBash_Blast(Obj)(o, cast.target, &cast.empower)
```

The cost is paid twice for mobs on every skill: `smo_SPCheck` above pays, and `sbe_BlastObject` / `sbe_BlastLocate`
pay again through vt 0xee0, which is the same function for mobs (§6.5) (original bug) Z25-B19. A WHOLEAGGRORATE skill
would also pay twice for a player, here and in §6.5 (latent).

`ShinePlayer::so_ply_Volley(p)` @ FUN_004a44a0 (Volley01: First ME, Last PARTY; mobs: no-op):

```pseudo
    require p on a map, in a party (vt 0x550 ≠ 0xFFFF, sp_LastPartyParam.pmi_PartySlot) and with a target t
    for each party member m (memberobj ≠ null) with so_DistanceSquar(p, m) < 1 000 000 (1000 units):
        m.so_ply_TargetChange (vt 0x998)(t)                       # Z03 §2.4: 0x244D, m's attack and cast stop
    smo_SkillResultPacket(p, s, t.pos)                            # §6.9
    p.smo_CeaseFireSend (vt 0xf48)
    send p only: 0x244E NC_BAT_SKILLBASH_HIT_OBJ_START_CMD { u16 skill = s.ID, u16 targetobj = t.handle, u16 index = sbec_GetIndex() }
        # the "Packet Too Long" log text is copied from smo_SkillBash_Blast
```

Volley sends no 0x2457 and queues no blast. The client of the caster gets a cast-start (0x244E, Z03 §5.4) as the
skill's only visible result *(inferred: what the client draws for it was not traced)*.

This corrects Z03 §5.4 ("servant/summon skills and self-target single skills take a variant path through vt 0xbf4")
and Z03 §5.6 ("summon skills: caster.vt[0xbf4](…)"). vt 0xbf4 is `ShineMobileObject::smo_LightningWaveSkill`
FUN_005796a0 for every class. It starts a **chain** blast. A chain skill never reaches `smo_SkillBash_Blast(Obj)`, so
CROSSCOUNTER, SETABSTATEME, WARPING, JWALK, WARPING_TARGET and the toggle switch (§6.2) are not run for it. An area
chain skill blasts at the target's **position** (the location blast), not at the target object.

### 6.2 `ShineMobileObject::smo_SkillBash_Blast(Obj)(o, t, empower)`  @ FUN_0057cd40

```pseudo
    s = cast.scs_ProduceSkill.sklidx;  fixedDamage = −1
    if s.sdi_CROSSCOUNTER.exist:                                  # CrossCounter01…: First = Last = 7 ENEMYUSER, IsMovingSkill 1
        if t == null or not o.so_mobile_ICanDamageTo (vt 0x980)(t)
                or (dmg = t.so_smo_CrossCounterDamage (vt 0x9ac)(o)) == −1:          # Z09 §8.3
            o.smo_CeaseFireSend (vt 0xf48)                        # player: CeaseFireSender::cfs_Routine FUN_00566820: if a
                                                                  #   cease-fire is pending, 0x243D NC_BAT_CEASE_FIRE_CMD { u16 handle }
                                                                  #   to sight now; mobs: no-op
            send o (vt 0x2fc → stream vt 0xc): 0x2457 NC_BAT_SKILLBASH_HIT_BLAST_CMD
                { u16 index = o.smo_SkillIndexLastCasting, u16 caster = o.handle, u16 skill = s.ID }   # caster only
            smo_ClearSkillResultBuffer_Miss(o, t)                 # Z23 §8.5
            smo_SkillResultPacket(o, s, t.pos)                    # §6.9: sends nothing
                # (original bug) Z25-B23: t == null enters this path and then reads t.pos (null dereference);
                #   dead in 2016 because so_Routine only calls the object blast with a target (§6.1)
            return                                                # (original bug) Z25-B15: the miss result is never sent
        InSkillShift = 1;  fixedDamage = dmg * 2                  # no arming pass; fixed damage skips the hit roll (§2.2)
    if s.IsMovingSkill: InSkillShift = 1
    if not InSkillShift:                                          # first ("arming") pass: blast 0.3 s later
        cast.scs_BlastTime += 3;  smo_Flag |= 0x10 (InSkillShift);  return
    smo_Flag &= ~0x10
    (name copy into namestring ring: log only)
    SkillResultBuffer::bufferpoint = 0
    if s.sdi_SETABSTATEME.exist: o.so_AbnormalState_Set_SS_SETABSTATEME (vt 0x648)(&s.sdi_SETABSTATEME, &s.sdi_ABKEEPTIME)
    if s.sdi_NOTTARGET.exist:
        o.vt[0x648](&s.sdi_NOTTARGET, &s.sdi_ABKEEPTIME)
        o.so_EscapeFromTarget (vt 0x64c)()
    if s.sdi_WARPING.exist:                                       # SS_WARPING (25) / SS_DASH (36)
        smo_WarpForward(o, s)                                     # FUN_004a83e0, Z09 §9.3: sdi_WARPING.value units forward
        smo_SkillResultPacket(o, s, t.pos)
        o.smo_ChineCastCut (vt 0xf60)()                           # player FUN_005794d0: smo_Flag |= 0x40, sp_ChineCastCut (Z23 §3.3),
                                                                  #   smo_Flag &= ~0x40; mobs: no-op
    if s.sdi_JWALK.exist and not o.so_parameter().flag.cannotmove_entangle (Container+0xcce bit 1):
        smo_ShadowStep(o, t)                                      # FUN_0045ad10, Z09 §9.3 (0x206A); sdi_JWALK.value is not read
    if s.sdi_WARPING_TARGET.exist:                                # SS_DASH2 (38): dash to the target's edge
        v = t.pos − o.pos;  v.length = t.so_BodySize() + o.so_BodySize()          # vt 0x6cc; vwl_Scale
        smo_WarpTo(o, t.pos − v, s)                               # FUN_004a7de0, Z09 §9.3: free-cell radius = sdi_WARPING.value
        smo_SkillResultPacket(o, s, t.pos)
    if s.sdi_ToggleData not empty: on / off switch                # Z23 §2.5 (0x245C / 0x245D)
    origin = s.First == TARGET_ME ? o.pos : t.pos
    broadcast to o's sight (incl. o): 0x2457 { u16 index = o.smo_SkillIndexLastCasting, u16 caster, u16 skill = cast.scs_Skill }
    sbec_Store(index, s, o, t, origin, fixedDamage, o.smo_SetEffectForJustSkill (vt 0xefc)(), from = null, depth = 1)   # §6.4
```

`ShineObject::so_AbnormalState_Set_SS_SETABSTATEME(o, special, keep)` @ FUN_00416880 (one body for every class):

```pseudo
    row = dic_abstate.as_FromID((u16)special.value)               # the special's value is an AbState.shn ID
    if out of range: assert "AbnormalStateDictionary::AbState::as_FromID : Invalid skill id"; return 0
    if row == null or row.index == null: return 0
    keepMs = keep.exist ? keep.value : −1                         # SS_ABKEEPTIME; −1 = the row's own keep time (§1.4)
    if o.so_AbnormalState_Set (vt 0x638)(o, row.AbStataIndex, strength 1, row, g_Now, 0, 0, keepMs, 0xd, null):
        so_AbnormalState_BitSet(o, idx);  so_AbnormalState_BroadcastSet(o, idx, 0, 1)      # 0x2427 / 0x1C18 (Z03 §6.3)
        o.so_AbnormalState_Inform (vt 0x3f0)(idx, 0, 0)                                    # player: 0x242A
        return 1
    return 0
```

Unlike SS_HOLDME (§2.7, Z25-B8), it tests the result of the set. The states go on the **caster**.

`ShineObject::so_EscapeFromTarget(o)` @ FUN_00435ba0 runs `AxialListTargetChange { altc_From = o.handle, altc_To =
null }` over o's sight. Its `ali_Work` FUN_00435ac0 calls, for each player (`so_ObjectType` vt 0x4d0 == 2) whose
target (`so_GetTargetObject` vt 0xa04) has handle `altc_From`, `so_ply_TargetChange(null)` (vt 0x998, Z03 §2.4:
0x244D with 0xFFFF, the player's attack and cast stop). Mobs keep their target.

2016 data: the only object-blast skill with SETABSTATEME / NOTTARGET / ABKEEPTIME is `DNepilim_Skill_W` (StaMobImmortal
4306 and StaNotTarget 8987 for 8566 ms on the caster). It is a magic-field skill, so `smo_MagicFieldSpread` runs the
same three steps (Z09 l. 3689) and this branch is not reached. `SD_DragonSkill07_W` (First 4 SPOT,
SETABSTATEME 9335 StaSDVale01_WCMAUp) blasts at a location (§6.3), and only the object blast and
`smo_MagicFieldSpread` read `sdi_SETABSTATEME`. Its self-buff is never applied (original bug) Z25-B16. WARPING: 26
skills (Blink01, TeleportCharm01, PsyAtkSkill03 by object, the rest by location), DASH2: SilberkDash, ECrabDash,
Lab_19_Dash_Atk, Lab_23_Dash_Atk (value 0: no free-cell search), JWALK: ShockEnemy01…05, CROSSCOUNTER: CrossCounter01.

### 6.3 `ShineMobileObject::smo_SkillBash_Blast(Loc)(o, xy, empower)`  @ FUN_0057cb10

```pseudo
    s = cast.scs_ProduceSkill.sklidx
    if s.IsMovingSkill: InSkillShift = 1
    if not InSkillShift: cast.scs_BlastTime += 3; smo_Flag |= 0x10; return               # arming pass
    smo_Flag &= ~0x10
    if s.sdi_SHOOTME.exist:                                       # BodyForce01… (9 skills, value 1)
        if o.smo_Param.flag.cannotmove_entangle or o.smo_MoveManager.mm_state == MM_REINFORCEMOVE:
            o.smo_CastAbort (vt 0xed4)();  return                 # Z03 §5.4 sp_castabort: 0x2438 to sight; no blast, no cost
        smo_ShootMeTo(o, xy)                                      # FUN_00459940, Z09 §9.3 (states 391 / 350, 0x2069)
    SkillResultBuffer::bufferpoint = 0
    if s.sdi_WARPING.exist:  smo_WarpTo(o, xy, s);  smo_SkillResultPacket(o, s, xy)       # Dash01, Advent01, LightJump01 …
    broadcast to sight (incl. o): 0x2457 { index = o.smo_SkillIndexLastCasting, caster, skill = cast.scs_Skill }
    sbec_Store(index, s, o, target = null, xy, −1, o.vt[0xefc](), from = null, depth = 1)
```

The location blast reads no CROSSCOUNTER / SETABSTATEME / NOTTARGET / JWALK / WARPING_TARGET / toggle data. For the
toggle part, Z23 §2.5 (Z23-B20) already says so.

### 6.4 Queuing: `SkillBlastEffectContainer::sbec_Store`  @ FUN_00438380

This answers the open question of §2.10: who makes `mha_HitStep` negative and who fills `mha_AbState[]`.

```pseudo
sbec_Store(index, s, caster, target, xy, fixedDamage, setEffSlot, from, depth):
    require caster, s, s.sdi_Activ, s.sdi_ServInf
    e = SkillBlastEffect();  e.sbe_nLightningWaveCnt = depth;  e.sbe_nSetEffectForJustSkill = setEffSlot
    caster.so_ply_setSwingTime (vt 0xc64)(g_Now + ServInf.SwingTime·10/1000)   # player FUN_00560ae0; mobs: no-op
    soulRate = s.DemandSoul ? SoulDamageContainer[DemandSoul].sde_DamageRateBySoul[caster.smo_HowMachSoul (vt 0xf38)(s, …, target)]
                            : 1000                                              # Z03 §5.6 souls
    e.sbe_Empow = caster.cast.scs_Empower;  e.sbe_Index = index;  e.sbe_LastDamage = fixedDamage
    e.sbe_SkillIndex = s;  e.sbe_CasterObject = caster;  e.sbe_CasterRegistNumber = caster.so_GetCharRegistNumber (vt 0x344)
    e.sbe_TargetObject = target;  e.sbe_TargetRegistNumber = target ? target.vt[0x344]() : 0xFFFFFFFF
    e.sbe_TargetLocate = xy ?? caster.pos
    if s.HitID == 0 or depth > 1:                                 # one hit
        e.hit = { mha_HitStep = −1, mha_DamageRate = soulRate, mha_AraeStep = 0,
                  mha_AbState[0..3] = mha_SetAbState(i, StaName A–D, StaSucRate A–D, StaStrength A–D) }
        tick = caster.smo_SkillBlastTick (vt 0xf14)(s)            # Z09 §8.5 (player: HitTime)
        if s.sdi_SHOTSPEED.exist and from != null:                # chain waves (§6.8)
            tick = max(1, ddt_Distance(target.pos − from) · 1000 / SHOTSPEED.value · 10 / 1000)
            if depth == 1: tick += smo_SkillBlastTick(s)
        e.sbe_BlastTick = g_Now + tick − (s.sdi_RANDOMTARGETNUMBER.exist ? 0 : 2)
        insert e before the first queued effect with a later sbe_BlastTick (else at the end); sbec_ListCheck (empty)
    else:                                                         # multi-hit: one effect per MultiHit row step
        m = _MultiHitTable[s.HitID]; require m and m.mhe_ID == s.HitID      # else nothing is queued (no blast at all)
        for step k in 0 … m.mhe_ArrayCnt − 1, stop at the first oh_HitTimeRate == 0:
            e.sbe_BlastTick = g_Now + oh_HitTimeRate·10/1000 − 2
            e.hit = { mha_HitStep = k, mha_AraeStep = oh_AreaStep, mha_DamageRate = oh_DamageRate · soulRate / 1000,
                      mha_AbState[0] = { oh_AbStateRate, oh_AbState, oh_AbStrength } }   # [1..3] keep the defaults
            insert e (sorted as above)
```

`MultiHitArgument::MultiHitArgument` FUN_00434b30: `{ HitStep −1, DamageRate 1000, AraeStep 0, AbState[i] =
{ rate 0, MAX_ABSTATEINDEX, strength 0 } }`. `mha_SetAbState(i, name, rate, strength)` FUN_00434de0 resolves
`name` in the abstate name tree. `-` or an unknown name leaves the entry empty. `sbec_GetIndex` FUN_00434c40 returns
`sbec_Index = (sbec_Index + 1) & 0x7fff`.

So **`mha_HitStep < 0` means a skill without `HitID`, or a chain wave after the first**: the single-hit tail of §2.9
(`so_SkillEnchant`) runs, and the `mha_AbState[]` that `sbec_Store` filled from StaName A–D is not read.
**`mha_HitStep ≥ 0` means a MultiHit step**: §2.10's loop applies the step's single abstate (index 0). The MultiHit
table (`_MultiHitTable`, `MultiHitType` loader of Z01) has its row layout in `MultiHitData::OneHit` *(pdb2016)*; loader in §6.4.1. 2016:
182 object skills and 10 location skills have a `HitID`.

#### 6.4.1 The MultiHit table: `MultiHitData::MultiHitTable::mht_Load`  @ FUN_004c0ff0

Global `_MultiHitTable` (`std::vector<MultiHitElement> mht_Array`), loaded once at start by the Lua start
script's `zs_start_full` (Z01 §2.2 / §2.3, row "MultiHitType"). Row structs *(pdb2016)*: SHN `MultiHitType` (0x2a bytes: `u16 ID; u16 HitTime; char AbIndex[32];
u8 AS_Step; u8 AbStr; u16 AbRate; u16 DmgRate`), element `MultiHitElement` (0xa8: `u16 mhe_ID; OneHit mhe_Array[10];
u8 mhe_ArrayCnt` at +0xa4), `OneHit` (0x10: `u16 oh_HitTimeRate; ABSTATEINDEX oh_AbState +4; u8 oh_AbStrength +8;
u16 oh_AbStateRate +0xa; u16 oh_DamageRate +0xc; u8 oh_AreaStep +0xe`).

```pseudo
mht_Load():                                                       @ FUN_004c0ff0
    t = BinaryDataBox<MultiHitType>.bdb_ReadData("../9Data/Shine/MultiHitType.shn")   # FUN_004c09b0: row 0x2a; read fail → assert, ShineExit
    n = max(row.ID) + 1
    mht_Array.resize(n, { mhe_ID = 0xFFFF, every OneHit = { 0, MAX_ABSTATEINDEX (792), 0, 0, 0, 0 }, mhe_ArrayCnt = 0 })
    for row in t (file order):
        if row.ID >= n: assert "mht_Load : Invalid ID", ShineExit          # cannot happen
        e = mht_Array[row.ID];  e.mhe_ID = row.ID;  k = e.mhe_ArrayCnt
        e.mhe_Array[k].oh_HitTimeRate = row.HitTime        # no check k < 10 (original bug) Z25-B20
        if row.HitTime == 0: continue                      # row ignored; slot k is reused by the next row
        e.mhe_Array[k].oh_AbStateRate = row.AbRate
        if row.AbRate != 0:
            e.mhe_Array[k].oh_AbState = dic_abstate name tree[row.AbIndex]   # unknown name → assert "Abstate not found", ShineExit
            e.mhe_Array[k].oh_AbStrength = row.AbStr                         # 0 → assert "Strength Zero", ShineExit
        e.mhe_Array[k].oh_DamageRate = row.DmgRate          # ‰ of the skill damage (§2.10)
        e.mhe_Array[k].oh_AreaStep   = row.AS_Step          # → mha_AraeStep
        e.mhe_ArrayCnt += 1

MultiHitTable::operator[](id):                                    @ FUN_004c0a90
    return id < mht_Array.size and mht_Array[id].mhe_ID == id ? &mht_Array[id] : null     # gaps (mhe_ID 0xFFFF) → null
```

Steps are numbered in **file order**; `sbec_Store` sorts the queued effects by time, so `mha_HitStep` need not grow
with time. 2016 data: 182 rows, IDs 1–62 (61 unused), at most 10 rows per ID (ID 62 exactly 10), no row with HitTime 0,
every `AbRate ≠ 0` row names an abstate and no other row does; only ID 8 is out of time order (step 4 at 2733, step 5
at 2700 HitTime units).

Other callees of `sbec_Store` (§6.4): `SkillBlastEffect::SkillBlastEffect` FUN_00434c60 (the `MultiHitArgument`
defaults above), `sbec_ListCheck` FUN_004358a0 (empty), `DamageBySoul::SoulDamageContainer::operator[]` FUN_00434db0
(index beyond the table → `sdc_Default`). Scanner constructors (`AxialListScanSkillTarget` FUN_0057e0f0 and the four
`AxialListNearScanSkill{Enemy,Party,Friend,EnemyUser}` FUN_0057e1a0 / FUN_0057e260 / FUN_0057e360 / FUN_0057e420 used by
§6.8) only set the vtable and an empty `alsst_RandomTargetList`; `alsst_SetAttacker` FUN_005793b0 stores the attacker
and its position.

### 6.5 Firing: `SkillBlastEffect::sbe_BlastObject` / `sbe_BlastLocate`

`sbec_Routine` (Z03 §5.6) calls these between `sds_Initialize` and `sds_Finish` (0x2452). "First step" below means
`hit.mha_HitStep ∈ {−1, 0}`.

```pseudo
sbe_BlastObject(e):                                                                    @ FUN_00583bc0
    if e.caster == null: assert "… : Caster Null Ptr"; return
    if first step and e.depth == 1:
        caster.vt[0xee0](s.ID, s, &e.empower)                     # player smo_SPCheckConsume FUN_0055bc50 (cost paid, Z03 §5.6);
                                                                  #   mobs smo_SPCheck FUN_005557f0
        caster.vt[0xbf8](1, caster, 0, 0)                         # player so_ply_PassiveSetAbstate (Z20 l. 732); mobs: no-op
    if s.ServInf.AggroPerDamage or AbsoluteAggro: e.target.vt[0x700](caster, 1)          # mobs: so_mob_AppendAggro(+1)
    if s.TargetNumber == 1 or e.depth > 1:                        # single target (also every chain wave)
        smo_SkillBlast(caster, s, e.target, &e.empower, e.sbe_LastDamage, &e.hit, depth = e.depth, rate 1000)   # §2
        item actions "after skill" on the caster                  # Z17 §3.4.3
        if s.sdi_RANDOMTARGETNUMBER.exist:                        # next chain wave (§6.8)
            caster.smo_LightningWaveSkill (vt 0xbf4)(s, sbec_GetIndex(), from = e.target, to = null,
                                                     e.sbe_nSetEffectForJustSkill, depth = e.depth + 1)
    else:                                                         # area
        scan = by s.Last:  0 ENEMY → alnse,  1 ME / 3 FRIEND → alnsf,  2 PARTY / 6 GROUP → alnsp,  5 ALL → alnsst,
                           7 ENEMYUSER → alnseu;  other → assert "… : Invalid TargetType" (ID, First); return
        scan.alsst_attacker = caster;  scan.alsst_nEffectForJustSkill = e.sbe_nSetEffectForJustSkill;  count = 0
        area = sdb_GetAreaSkillInfo(s, e.hit.mha_AraeStep)        # Z20 §5 (AreaSkill.shn bitmap of this step)
        if area == null:
            allas_Init(scan)                                      # no bitmap (Z09 §12.5)
            if s.SkillDegree == 360: so_AllOfRange(caster, centre = e.sbe_TargetLocate, radius = s.Area / 2, scan)
            else: fan = FanFormSectorArgument(caster, e.target) (FUN_0057bda0) with half-angle SkillDegree / 2,
                      direction rotated by sr_degree2sr(DirectionRotate) when ≠ 0
                  so_AllOfRange(caster, centre = e.target.pos, radius = s.Area / 2, fan, scan)
        else:
            allas_Init(scan, area, from = caster.pos, to = e.sbe_TargetLocate, dir = caster direction)
            so_AllOfRange(caster, centre = allas_GetEffectCoord(scan), radius = area.AreaSize, scan)
        qsort(scan entries, alns_Compare)                         # nearest first; see §6.6 (Z25-B14)
        scan.alsst_attackPos = e.target.pos
        if s.sdi_RANDOMTARGET.exist:
            if value ∈ {1, 2}: alsst_SkillBlast_RandomTarget(scan, s, &e.empower, s.TargetNumber, &e.hit)   # §6.7
            # value 0 (or other): nobody is hit
        else: alsst_SkillBlast(scan, s, &e.empower, s.TargetNumber, &e.hit)                                # §6.7
    if first step:
        if e.target == null or s == null or s.sdi_Activ == null: return            # skips the script hook below too
        mdt_PostSkillBlast(caster, e.target, s.ID, e.target.pos)                   # Z09 §28.3
        mdt_SkillBlast_Summon(caster, e.target, s.ID, e.target.pos, MST_NONE)      # Z09 §13.3
    if caster has a MobAttack script name: caster.so_AIScriptFuncExec (vt 0xb68)(0xac, LuaArgumentMobAttack(map, caster))   # Z09 §14.3

sbe_BlastLocate(e):                                                                    @ FUN_00584160
    SkillResultBuffer::bufferpoint = 0
    if first step: caster.vt[0xee0](…);  caster.vt[0xbf8](1, caster, 0, 0)            # cost, as above (depth is not tested)
    scan = by s.Last as above but: 1 ME → assert "… : Invalid TargetType"; 18 NONE → return (silently); both after the cost
    alsst_attackPos = e.sbe_TargetLocate;  same bitmap / circle scan around e.sbe_TargetLocate (never a fan)
    qsort;  RANDOMTARGET 1/2 → alsst_SkillBlast_RandomTarget, value 0 → nobody, absent → alsst_SkillBlast
    smo_SkillResultPacket(caster, s, xy)                                           # §6.9
    mdt_PostSkillBlast(caster, null, s.ID, xy);  mdt_SkillBlast_Summon(caster, null, s.ID, xy, MST_NONE)
        # on every step, not only the first (latent: no MiscDataTable row names one of the 10 multi-hit location skills)
    script hook 0xac as above
```

`Dash01` (First 4 SPOT, Last 1 ME, TargetNumber 1, SS_DASH 850) is the only 2016 location skill with Last = ME: every
cast logs the "Invalid TargetType" assert after the warp (original bug) Z25-B18. `LightJump01` (Last 18 NONE) returns
without the log. `RANDOMTARGET` 0 is used by `Eglack_Skill04_N` / `EglackMad_Skill04_N`: single target, so they do
not reach the area branch, and the mob AI picks their target at cast time (Z09 §7.4, `sm_UseWeapon`: values {0, 2}). It
is also used by `DT_SFocalor_Skill04_W` and `WarH_SFocalor_Skill04_W`: magic fields, whose spread blast
(`sbe_BlastLocate`) therefore hits nobody (original bug) Z25-B17. RANDOMTARGET 1: 12 mob skills (`Salare_Skill03_N`, the
Focalor `…Skill02_N`), all with TOPAGGRONO.

### 6.6 The skill target scanners

Five global scanners *(pdb2016)*, all `AxialListScanSkillTarget` (an `AxialListLimitAreaScan`: up to 200
`{ object, d² }` entries, `allas_MemberBMPDamageRate[200]`, `alsst_attacker`, `alsst_attackPos`,
`alsst_nEffectForJustSkill`, `deque alsst_RandomTargetList`). vftable slots: +0 `AxialListLimitAreaScan::ali_Work`
FUN_004c1e20 (Z09 §12.5: mode ∉ {0, 3}, the class filter, the bitmap cell; no bitmap → `AxialListNearScan::ali_Work`
FUN_004c1cf0, which also refuses STA_IMMORTAL / STA_ADLFLOUSSIERIMT, Z17 §2.6), +4 the filter below, +8
`alns_GetBMPDamageRate(i)` FUN_004c1b10 (`allas_MemberBMPDamageRate[i] · 10`, 1000 without a bitmap).

| Scanner (global) | `alns_ValidObject(o)` | keeps |
|---|---|---|
| `alnsst` `AxialListScanSkillTarget` (ALL) | FUN_00579320: `o.vt[0x5ac]()` (skill-targetable: mobs `so_CanSkillTarget`) and not an NPC (`so_mob_IsNPC` vt 0xd48) and o ≠ attacker and not (kind 11 and `so_MoverSystem_NoDamage` vt 0xc70) and mode ≠ 3 and not `so_AmIAlreadyDead` (vt 0x28) | everyone but the caster |
| `alnse` `AxialListNearScanSkillEnemy` | FUN_0057a250: `mdb_CanIKill(o.so_mob_MobID, attacker is a mob ? MKID_MOB : MKID_USER)` and `attacker.so_mobile_IsEnemy(o)` (vt 0x72c) and `attacker.so_mobile_ICanDamageTo(o)` (vt 0x980) | enemies the caster may damage |
| `alnsf` `AxialListNearScanSkillFriend` | FUN_0057a490: not `attacker.so_mobile_IsEnemy(o)` | everyone not hostile, **the caster included** |
| `alnsp` `AxialListNearScanSkillParty` | FUN_0057a3b0: attacker without party (`so_PartyRegistNumber` vt 0x550 = 0xFFFF): o == attacker; else o's party == attacker's | the party in range |
| `alnseu` `AxialListNearScanSkillEnemyUser` | FUN_0057a130: `o.vt[0xbbc]()` ≠ 0 (players: self; others 0) and `attacker.so_mobile_ICanDamageTo(o)` | players the caster may damage |

The subclass filters do not call the ALL filter, so for them the "not dead / not the caster" tests are only those of
`ali_Work` (mode 3) and of `smo_SkillBlast` (§2.1). The heal check for SE_HEALING skills is made per target in §6.7.

The distance `qsort` (8-byte entries) does not move `allas_MemberBMPDamageRate[]`, and §6.7 reads the rate by
**position after sorting** (`vt[8](i)`). With an AreaSkill bitmap whose cells differ, a target gets the cell rate of
whichever object was inserted i-th (original bug) Z25-B14. The random path of §6.7 makes it worse: it reads the rate
by its own list index.

### 6.7 Per-target loops: `alsst_SkillBlast` / `alsst_SkillBlast_RandomTarget`

```pseudo
AxialListScanSkillTarget::alsst_SkillBlast(scan, s, empower, n = s.TargetNumber, hit)                  @ FUN_00582de0
    n = min(n, scan.count)
    if s == null: assert "… : idx null" (continues)
    else if s.sdi_DMGSHARE.exist and hit and n > 0:               # B_Albireo_Skill05_W / BH_…: the damage is shared
        hit.mha_DamageRate = (int)(hit.mha_DamageRate / n)        # fild / fidiv at 0x582e96; n counts blocked targets too
    item actions "on skill use" per scanned target                # Z17 §3.4.3
    for i in 0 … n − 1:                                           # the n nearest; a blocked one still uses its slot
        t = scan.entry[i].object; if t == null: continue
        if so_FindBlockLocateFrom(attacker, from = scan.alsst_attackPos, to = t.pos, 10000, mbi_IsAttackBlock) != t.pos:
            continue                                              # wall between the impact point and t (not the caster)
        if s.sdi_Activ == null: assert "… : idx->Activ null"; break
        if s.EffectType == SE_HEALING and not attacker.smo_ICanHealTo (vt 0xe94)(t): continue    # Z09 §8.4
        h = hit ?? MultiHitArgument()                             # sbe always passes its own
        smo_SkillBlast(attacker, s, t, empower, fixedDamage −1, h, depth −1, rate = scan.vt[8](i))   # §2; rate: §6.6
            # depth −1 turns SS_DMGDOWNRATE into a bonus for these targets: (original bug) Z25-B21 (§2.5)
        if hit and first step: mdt_SkillBlast_Summon(attacker, t, s.ID, t.pos, MST_MULTI)        # Z09 §13.3
        if s.sdi_RANDOMTARGETNUMBER.exist:                        # area chain skill: a chain from every hit target
            attacker.smo_LightningWaveSkill (vt 0xbf4)(s, sbec_GetIndex(), from = t, to = null, scan.alsst_nEffectForJustSkill, depth 2)

AxialListScanSkillTarget::alsst_SkillBlast_RandomTarget(scan, s, empower, n, hit)                      @ FUN_00583180
    if s == null: return
    exclude = 0xFFFF
    if s.sdi_TOPAGGRONO.exist and n < scan.count and (top = attacker.so_mob_GetTopAggroTarget (vt 0xc18)()):   # Z09 §6.4
        exclude = top.handle                                      # spare the tank when there are more candidates than hits
    alsst_MakeRandomTargetList(scan, n, exclude)
    item actions per listed target                                # Z17 §3.4.3
    for i, t in alsst_RandomTargetList:                           # same per-target body as alsst_SkillBlast (block test
        …                                                         #   again, heal check, smo_SkillBlast with rate vt[8](i),
                                                                  #   MST_MULTI summon, chain start); no DMGSHARE here

AxialListScanSkillTarget::alsst_MakeRandomTargetList(scan, n, exclude)                                 @ FUN_0057e4e0
    clear alsst_RandomTargetList;  n = min(n, scan.count)
    while list.size < n and scan.count ≥ 1:
        k = scan.count ≤ 100 ? rndbox[scan.count] : 0             # uniform 0 … count−1 (Z23 §8.6); above 100: always slot 0
        t = scan.entry[k].object
        if t != null and t.handle != exclude and so_FindBlockLocateFrom(attacker, attackPos → t.pos, attack block) reaches t:
            list.push_back(t)
        scan.count −= 1;  entry[k].object = entry[count].object;  entry[count].object = null      # drawn without replacement
```

### 6.8 Chain blasts ("lightning wave"): `smo_LightningWaveSkill`  @ FUN_005796a0

```pseudo
ShineMobileObject::smo_LightningWaveSkill(o, s, index, from, to, setEffSlot, depth):     (vt 0xbf4, every class)
    require s, s.sdi_RANDOMTARGETNUMBER.exist, depth ≤ RANDOMTARGETNUMBER.value, from, s.sdi_Activ
    SkillResultBuffer::bufferpoint = 0                            # restarts the 64-slot count (results already queued stay)
    if to == null: to = from.so_smo_GetRandomTarget_Object (vt 0xc1c)(s, s.sdi_NEXTTARGETAREA.value, o)
    if to == null: return                                         # chain ends
    sbec_Store(index, s, o, to, to.pos, −1, setEffSlot, from = from.pos, depth)          # §6.4: travel time by SHOTSPEED
    broadcast to o's sight (incl. o): 0x245E NC_BAT_SKILLBLAST_LIGHTNINGWAVE_CMD
        { u16 nBIndex = index, u16 nSkillID = s.ID, u16 nShotHnd = from.handle, u16 nTargetHnd = to.handle }   # 8 bytes
    if depth == 1: broadcast 0x2457 { index, caster = o.handle, skill = s.ID }            # the cast's blast animation
```

The chain: wave 1 (from `so_Routine`, §6.1) goes caster → cast target. When it fires, `sbe_BlastObject` (§6.5,
`depth > 1` or TargetNumber 1) hits that target and calls wave `depth + 1` from it. Each wave gets a new blast index,
so each one's damage goes out in its own 0x2452. The chain stops at `depth > RANDOMTARGETNUMBER.value` or when no
next target is found. `smo_SkillBlast` lowers the damage per step with SS_DMGDOWNRATE / SS_MAXDMGDOWNRATE (§2.5).
Cost is paid on wave 1 only (§6.5: `depth == 1`). Area chain skills start one depth-2 chain per hit target (§6.7). 2016:
`LightningWave01…` (10 waves, area 300, speed 400, −100 ‰ per step down to 900 ‰), `DT_TFocalor_Skill04_W` (5,
area, multi-hit), `FRangerH_Skill_N_PSN` (2).

```pseudo
ShineMobileObject::so_smo_GetRandomTarget_Object(c, s, range, caster):                  @ FUN_0057e660   (vt 0xc1c)
    # c = the centre object: the previous target in a chain; the mob itself in sm_UseWeapon (Z09 §7.4)
    if s == null or s.sdi_Activ == null or c has no position: return null
    scan = a local scanner by s.Last (0 → Enemy, 2 / 6 → Party, 3 → Friend, 5 → ALL, 7 → EnemyUser; 1 ME and others → null)
    alsst_SetAttacker(scan, caster.vt[0xb8c]())                   # so_ShineMobileObject: the caster itself
    so_AllOfRange(caster, centre = c.pos, radius = range, scan);  alns_Sort(scan)
    exclude = c.handle
    if s.sdi_TOPAGGRONO.exist and scan.count > 1 and (top = c.so_mob_GetTopAggroTarget()): exclude = top.handle
    alsst_MakeRandomTargetList(scan, 1, exclude);  return the first entry or null
```

Only the previous target is excluded, so a chain can come back (A → B → A). With TOPAGGRONO the exclusion moves to
the previous target's top-aggro object, so the previous target itself can be picked again. No 2016 skill has both
RANDOMTARGETNUMBER and TOPAGGRONO.

`ShineMobileObject::so_smo_GetRandomTarget_Locate(o, s, &xy)` @ FUN_00579910 (vt 0xc20; used only by `sm_UseWeapon`,
Z09 §7.4): `r = rb_largerandom(s.Range)`, `a = rndbox[64] · 180 / 64` (Shine-radian 2° units: the whole circle), point =
o.pos + r·(sin a, cos a) / 1024. It snaps that point to the nearest non-attack-block cell, then to the nearest
non-move-block cell, each within 2r (`so_FindBlockLocate`). It returns false when either snap fails.

Client (`GameFrameWork::On_NC_BAT_SKILLBLAST_LIGHTNINGWAVE_CMD` FUN_004a5bf0): if the attack-sequence manager already
holds damage info for `nBIndex`, it does nothing. Otherwise it looks up `nSkillID` in the active-skill table and the
two characters, then plays `EffectMgr::CreateLightningShootEff` from `nShotHnd` to `nTargetHnd` with the skill's
effect names and speed. It sets a "lightning pending" flag (`this+0x1334 = 1`, `+0x1336 = nSkillID`).

### 6.9 `smo_SkillResultPacket` sends nothing

`ShineMobileObject::smo_SkillResultPacket(o, s, xy)` @ FUN_0057a630 copies o's name to the name ring and sets the
dept bits of the global packet buffer's opcode word (`(op & 0x3ff) | 0x2400`; nothing is sent with it). Then it calls
`o.smo_CharClass.vt[0x40](o)`. That slot is `CharClassMage::cc_JustAfterSkill` FUN_00449900 = `o.smo_BashStop()` (vt
0xed8, Z03 §3.4) for Mage, WizMage, Enchanter, Warrock and Wizard, and the empty `ret 4` FUN_00549070 for every other
class (mobs too). The `s` and `xy` arguments are not used. So the function stops a mage's auto-attack after a skill.
It sends no 0x2452. This corrects Z23 §8.5 and Z03 §5.4, which read it as the result send.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z25-B1 | `smo_SkillBlast` §2.1 | calls `so_SubLayer_CanAttack(a, d)` and ignores the result; only the inline sub-layer test remains | skills hit targets the caster cannot see (StaMobInvisible, sub-layer pairs the swing refuses) once they are in the area | `if not so_SubLayer_CanAttack: return` |
| Z25-B2 | `smo_SkillBlast` §2.2 | hit chance adds `PROBABILITYRATE − 1000` converted as unsigned | a set-item PROBABILITYRATE below 1000 would make every skill hit (latent: all 1000 in 2016) | signed addition |
| Z25-B3 | `smo_SkillBlast` §2.5 SS_TARGETHPDOWNDMGUPRATE | `dmg += (lost‰ · V / 1000) · dmg / V` | V only changes rounding; V = 0 is a division by zero (2016 data: V = 1000, so the result equals the likely intent) | `dmg += lost‰ · V / 1000 · dmg / 1000` |
| Z25-B4 | `smo_SkillBlast` §2.5 SS_DIEHPUP | the kill heal rolls with `sdi_HPUPRATE.value`; `bos_MyHealKill` is a dead store | a DIEHPUP skill without HPUPRATE never heals on kill (no 2016 skill has DIEHPUP) | its own chance, or always |
| Z25-B5 | `RuleOfEngagementHealAttack::roe_CalcDamage` §2.5.1 | `roe_LevelGapDamageRevision`'s return value is discarded | heal damage on devil mobs ignores the level gap | use the revised value |
| Z25-B6 | `sds_TemplateStore` §3 (0x2452) | `SkillDamage.flag` bits 11–15 are never written (stack garbage) | random high flag bits on the wire (the client reads bits 0–10) | zero them |
| Z25-B7 | `smo_ReflectionDamage` §4.2 (0x245B) | `damage` is the requested amount, cast to u16 | the number shown differs from the HP lost when hooks reduce it, and wraps above 65535 (boss reflections up to 5000 ‰) | the applied damage, u32 |
| Z25-B8 | `smo_SkillBlast` §2.7 SS_HOLDME | the result of `so_AbnormalState_Set` on the caster is ignored; bit, 0x2427 / 0x1C18 and 0x242A go out anyway | when the set fails (map refuses the state, stronger state of the group) clients show a hold the server does not apply, and the brief bit stays set with no element to clear it *(inferred)* | bit / broadcast / inform only on success, as in §2.10 |
| Z25-B9 | `smo_SkillBlast` §2.10 multi-hit abstates | the empower keep-time bonus is passed as `extra`, which `aeo_Set` ignores when `keepMs ≠ 0`; the shown time is `keep + bonus`, unscaled by SET_ABSTATEKEEPTIMERATE; BroadcastSet sends the requested strength | empowered multi-hit states last their row time while the client shows the longer time | `keepMs = keep + bonus` (as `so_SkillEnchant`) |
| Z25-B10 | `smo_SkillBlast` §2.9 SS_SUCKHP | the drain overwrites `hpchange` / `resthp` without looking at `isImmune` or the AC / MR-mode conversion; `healOnKill` becomes `bos_MyHealKill + n` | an immune target still loses the drain; a target in StaACMode / StaMRMode is healed by up to MaxHP − 1; a 1 HP target dies; a DIEHPUP roll is replaced (latent) | skip the drain on immune / converted hits, keep the rolled kill heal |
| Z25-B11 | `smo_SkillBlast` §2.10 | for non-damage multi-hit steps `vt 0x700` adds `bos_AbsoluteAggro`, then `sds_TemplateStore` adds `AbsoluteAggro` again | mobs get about twice the absolute aggro (+1 for player casters) per non-damage step | one aggro add per step |
| Z25-B12 | `smo_SkillBlast` §2.10 | re-tests StaAdlFloussierImt / StaImmortal on the target, already refused at entry (§2.1) | dead check | none needed |
| Z25-B13 | `so_smo_AbStateKeepTimeAdd` §2.8 (0x242A) | `keeptime_millisec = rest·100 + ms` with a negative `ms` (CURSETIMEADD) is not clamped | ResistCurse on a curse with less time left than the cut: the client icon shows ~49.7 days until 0x2428 arrives | clamp at 0 (or end the state at once) |
| Z25-B14 | area scans §6.6 / §6.7 | `qsort` sorts the `{object, d²}` entries but not `allas_MemberBMPDamageRate[]`; the per-target rate is read by sorted (or random-list) position | with an AreaSkill bitmap whose cells differ, targets get another object's cell rate (more or less damage than their cell) | sort the rates with the entries, or store the rate in the entry |
| Z25-B15 | `smo_SkillBash_Blast(Obj)` §6.2 CROSSCOUNTER | on failure the miss result is built (`smo_ClearSkillResultBuffer_Miss`) but never sent: `smo_SkillResultPacket` sends nothing (§6.9), no `sbec_Store` | the caster's client gets only 0x2457, others nothing; nobody sees the "miss" | send 0x2452 with the miss entry |
| Z25-B16 | location blast §6.3 | `sdi_SETABSTATEME` / `NOTTARGET` are read only by the object blast and `smo_MagicFieldSpread` | `SD_DragonSkill07_W` (SPOT, SETABSTATEME StaSDVale01_WCMAUp) never buffs its caster | apply them in the location blast too |
| Z25-B17 | `sbe_BlastObject` / `sbe_BlastLocate` §6.5 | with `sdi_RANDOMTARGET.exist` and a value outside {1, 2}, neither per-target loop runs | the spread blast of `DT_SFocalor_Skill04_W` / `WarH_SFocalor_Skill04_W` (value 0, area) hits nobody; only field ticks hurt | value 0 (cast-time random spot, Z09 §7.4) → the normal `alsst_SkillBlast` |
| Z25-B18 | `sbe_BlastLocate` §6.5 | `Last` = TARGET_ME is not a case: assert "Invalid TargetType" after the cost is paid | `Dash01` logs an assert on every cast (no other effect: the dash is done in §6.3) | treat ME like NONE |
| Z25-B19 | `so_Routine` §6.1 / `sbe_BlastObject` §6.5 | mobs: vt 0xedc and vt 0xee0 are both `smo_SPCheck` FUN_005557f0, which pays SP; players: a WHOLEAGGRORATE skill pays at vt 0xee0 in `so_Routine` and again in the blast | mob skills cost twice their SP (latent for players: no 2016 WHOLEAGGRORATE skill) | test only at cast end, pay once at the blast |
| Z25-B20 | `mht_Load` §6.4.1 | writes row k of an ID into `mhe_Array[mhe_ArrayCnt]` without checking `mhe_ArrayCnt < 10` | an 11th row of one ID overwrites `mhe_ArrayCnt` (+0xa4) and the next element (2016 data: at most 10 rows, latent) | refuse (assert) more than 10 rows per ID |
| Z25-B21 | `smo_SkillBlast` §2.5 SS_DMGDOWNRATE | `cut = value · depth`, and the area loops `alsst_*` pass depth −1 | area targets of a DMGDOWNRATE skill take +value‰ damage instead of −value‰ (2016: `DT_TFocalor_Skill04_W` +30 % on its first-wave area targets) | depth 1 for area targets (or `cut = 0` below depth 1) |
| Z25-B22 | `sds_TemplateStore` §3 Lua ranking 0xac | caster's map gets `(dealt = heal, healed = 0)`, target's map `(healed = heal)` | ranking maps count heals as the healer's damage dealt and credit the healed player with healing done | caster: `healed = heal`; target: nothing (or `taken`) |
| Z25-B23 | `smo_SkillBash_Blast(Obj)` §6.2 CROSSCOUNTER | `t == null` is tested, then the failure path reads `t.pos` | null dereference if reached (dead in 2016: `so_Routine` always passes a target) | return before reading t |

## 7. Not reconstructed / uncertain

- What the 2016 client draws for Volley's lone 0x244E (§6.1) and for a failed cross counter, which sends only a
  caster-side 0x2457 (§6.2, Z25-B15), was not traced in the client.
- `so_dummypacketcontainer`'s send (§2.8, mobs) is taken to send nothing from its name *(inferred)*.
- Client text 0x0A653383 (0x242A for a curse, §2.8) is in none of the 2016 `TextData*.shn`; what the client shows
  for a missing id was not traced.
- Client FUN_0057eeb0 calls in the 0x245B handler (own character hit): which HUD element they refresh is not traced.

## 8. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| `smo_JumpTo` FUN_0057db20, 0x482D | Z09 §9.3 (done) | movement helper with packet already documented |
| `so_SkillCure` / `so_Dispel` / `smo_Dispel` bodies | Z22 §7.5, Z23 §8 (done) | documented there; §5 adds only the data tables |
| `so_ply_Revival` FUN_0057ab90 | Z03 §7.3 (done) | revive by skill |
| `so_SkillEnchant` FUN_00431ca0, `so_ItemActonAbstateApp` FUN_0055dea0 | Z22 §10.7 (done) | called from §2.9 / §2.10; bodies documented there |
| target-side `EventRun` / `EventRunBySkillGroupIndex` (SEIT_KEEPTIME_RATE_INCREASE) | Z17 §3.4.3 (done) | item-action engine; §2.8–§2.10 only cite the call sites |
| `so_AbnormalState_Set` / `asl_AbstateSet` / `aeo_Set` FUN_004162d0 / FUN_0040d020 / FUN_0040a340, 0x2427 / 0x1C18 / 0x2429 | Z03 §6.2, §6.3 (done) | abstate container; §1.4 adds only the keep-time rule |
| `sp_NC_BAT_TARGETTING_REQ` FUN_0042ffe0 (reads state 392) | Z03 §2.2 (done) | targeting handler |
| `mdb_CanIKill` FUN_006424c0, `mdt_ArgumentLoad` FUN_004a6110, `so_mob_SkillParameterSet` FUN_005d2e90 | Z09 §5.1, §28.3 (done) | mob data and ExpandSkill checks |
| `so_ply_CheckDamageAbsorption` FUN_00579860, SpyAgent reports | Z09 (done) | damage absorb and aggro reports |
| `so_smo_LastDamageOperation` FUN_0040cbe0, HideDamage actor | Z22 §9.4, §9.7 (done) | abstate damage hooks |
| `smo_WarpForward` / `smo_WarpTo` / `smo_ShadowStep` / `smo_ShootMeTo` / `so_mobile_Teleport` (FUN_004a83e0 / FUN_004a7de0 / FUN_0045ad10 / FUN_00459940 / FUN_0057a8b0), 0x4828 / 0x206A / 0x2069 | Z09 §9.3 (done) | movement bodies reached from §6.1–§6.3 |
| `so_smo_CrossCounterDamage` FUN_004a5360 / FUN_004a54b0 / FUN_004a56a0 | Z09 §8.3 (done) | counter damage value used by §6.2 |
| `smo_ICanHealTo` FUN_00435390 / FUN_004357c0 / FUN_004356b0, `so_mobile_ICanDamageTo` | Z09 §8.4 (done), Z03 §5.2 | per-target tests of §6.6 / §6.7 |
| `AxialListLimitAreaScan::ali_Work` FUN_004c1e20, `allas_Init` FUN_004c19f0 / FUN_004c1a00, `allas_GetEffectCoord` FUN_004c1ae0, `AxialListNearScan::ali_Work` FUN_004c1cf0 | Z09 §12.5, Z17 §2.6 (done) | scan walkers; §6.6 adds the skill filters and the rate mismatch |
| `smo_MagicFieldSpread` FUN_0057c880 | Z09 §12.2 / §12.3 (done) | magic-field branch of §6.1 |
| `ZoneRingPacketSummonPartner::zrpb_Request` FUN_005a83b0 (SummonMate) | Z13 §4.6 (done) | partner summon branch of §6.1 |
| `smo_ply_AggroAdjust` FUN_004a4a40 | Z09 §6.2 (done) | WHOLEAGGRORATE branch of §6.1 |
| `mdt_PostSkillBlast` FUN_004a3a90, `mdt_SkillBlast_Summon` | Z09 §28.3, §13.3 (done) | MiscDataTable hooks after a blast |
| `so_ply_TargetChange` FUN_004a4680 (0x244D), `so_ply_Send2WhoTargetMe` FUN_00568ee0 (0x2402) | Z03 §2.4, Z22 §10.6 (done) | target packets sent by §6.1 / §6.2 |
| item-action `EventRun` calls in `sbe_BlastObject` / `alsst_*` | Z17 §3.4.3 (done) | cited in §6.5 / §6.7 |
| toggle switch in the object blast (0x245C / 0x245D) | Z23 §2.5 (done) | cited in §6.2 |
| `so_AIScriptFuncExec` 0xac MobAttack | Z09 §14.3 (done) | script hook at the end of §6.5 |
| `sm_UseWeapon` FUN_004ab9c0 (reads FLYDURINGCAST, RANDOMTARGET, RANDOMTARGETSPOT), `sm_UseSkillSimple` FUN_0057d880 | Z09 §7.4, Z03 §6.6 (done) | mob skill choice before the cast; §1.1.1 only names the raw offsets |
| `csl_DmgCoolTimeDown` FUN_00449080 (SS_DMGCOLLTIMEDOWN) | Z23 §3.4 (done) | cooldown shortening on damage taken |
| `almfh_ApplyHeal` FUN_0056d2c0 and the magic-field functions reading `sdi_MAGICFIELD_*` / SETABSTATEFRIEND | Z09 §12.2 – §12.5 (done) | magic fields are Z09's, as the plan says |
| `sbec_Routine` FUN_00437fc0 (REVIVAL, fires queued effects) | Z03 §5.6 (done) | effect queue tick; §6.4 covers the queuing |
| cast handlers FUN_0057fa50 / FUN_0057f400 / FUN_00540b90 and mover casts FUN_00580800 / FUN_00580cf0 (HOLDME, SHOOTME, REVIVAL, AttackDist) | Z03 §5.2 / §5.5, Z04 §12.7, Z13 (done) | cast-time checks of the specials |
| `smo_SkillBash_Blast_Trap` FUN_005835e0 (Loc) / FUN_005838a0 (Obj), 0x2442 / 0x2443 | Z18 (open; its plan names 0x2442 / 0x2443 and `smo_SkillBash_Blast_Trap`) | servant explosions. Z09 §8.8 only names the calls (Z09 §31.3 points to Z03, which has nothing on them). Seen in passing: Trap(Obj) calls `smo_SkillBlast` (§2) on the servant's `scs_BattleSkill.target` with `scs_Empower`, not on its own arguments; Trap(Loc) passes a null `hit` to `alsst_SkillBlast` *(for Z18 to confirm)* |
| `sdi_Clear` / `sdi_SetArgument` FUN_00584500 / FUN_00584800, `sdb_Load` FUN_00585f40 | Z20 §4 (done) | fill the special members from the SHN |
| player normal-attack combo `sp_MultiHitNotIndex` (`sp_Schedule_SwingDamage` FUN_0042f550, item `HitTimeArray`), | Z03 §3.2 (done) | swing combo, not the skill MultiHit table. `smo_ply_GetMultiHitSequance` FUN_0042b050 (not in Z03) is only `return sp_MultiHitNotIndex` (u16), documented here |
| container code reached from §6 (`std::deque` / `std::vector` helpers FUN_0057dfb0, FUN_00577990, FUN_00437f30, FUN_00437ec0, FUN_0057e0a0, FUN_0057e060, FUN_00576df0, FUN_0057de20, FUN_00437000, FUN_00437b20, FUN_00447600; `BinaryDataBox<AbnormalStateInfo>::bdb_ReadData` FUN_00416a00; `TargetObject::to_GetTargetObject` FUN_0042abe0; `~AxialListScanSkillTarget` FUN_0057e320) | none needed | STL / reader boilerplate with no game logic |
