# Zone server: abnormal-state actor classes (Z22)

Source: the 2016 zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`), read in the PDB export
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Class, method, member and enum names
come from the NA2016 zone PDB (same build) *(pdb2016)* unless marked otherwise. Vtables were recovered from RTTI
(`tools/protocol-re/rtti.py`). SubAbState data facts come from `Files/Server/2016/9Data/Shine/SubAbState.shn` /
`AbState.shn` (`tools/protocol-re/shn.py`).

This file documents the per-effect "actor" layer of the abnormal-state (abstate) system. It builds on
`docs/pseudocode/zone/Z03-combat.md` §6 (container, `aeo_Set`, `asl_AbstateSet`, packets 0x2427 / 0x2428 / 0x1C18,
expiry) and `docs/pseudocode/zone/Z12-stats.md` §2.5 / §4.1 (stat matrix, `roe_FreeState*` slots, Z12-B6 / B7). Terms:

- **element** = `AbstateElementInObject` (0x74 bytes, one active state on one object, Z03 §6.1), written `e`.
- **row** = the element's `AbStateStrArgument` = `SubAbState.shn` row of `(index, strength)`: `aeo_GetIndexArgument`
  @ FUN_00401210 = `abstateidentarray[e.aeo_Index].strength[e.aeo_Strength]` (4 × `{SubAbstateAction action, int value}`
  = `ActionIndexA…D / ActionArgA…D`). `row.Has(SAA_X)` = `assa_IsHaveEffect` @ FUN_00416190, `row.Arg(SAA_X)` =
  `assa_FindEffect` @ FUN_00416160 (value of the first slot with that action, 0 if none).
- **bearer** = the object that carries the state (the routine's `ShineMobileObject *` argument), **caster** = the
  setter stored in `e.aeo_Caster`.

Parts done: §1–§6 (framework, base actor, damage over time, area damage, heal over time). Still to come (see
`docs/plan/status/Z22.md`): bomb / detach-process / dispel / rate actors and the damage, skill and death hooks (part 2),
the `AbnormalStateElement` subclasses (part 3).

## 1. Framework

### 1.1 The actor cluster: SubState → actor  @ FUN_00405a10

`AbnormalStateContainer::ActorCluster::ActorCluster` builds the global `actorcluster` (0x384 bytes): one member object
per kind (`ac_STRRATE`, `ac_POISON`, …; each is just a vftable pointer) and `ac_SubStateList[120]` (+0x1a4), indexed by
`SubAbState.Type` (enum `SubState`, names below from the 2016 member names; the 2017 client PDB enum agrees except
where noted). After filling it asserts every slot is non-null ("ActorCluster : Buffer not full", `ShineExit`).
`aeo_GetActor` @ FUN_00401240 returns `abstateidentarray[e.aeo_Index].actor` (the `g_AbActiveInfo` slot of Z03 §6.1,
filled by `aeo_Set` from `ac_SubStateList[sub.Type]`).

| Actor class (vftable) | SubState types (value name) |
|---|---|
| `SubAbnormalStateActor` (base, no override) | 0–15 stat types, 18 SHIELDACRATE, 19 MOVESPEED, 20 ATKSPEED, 21 STUN, 23 ENTANGLE, 35 CURSE, 36 REGIST, 37 CRITICALRATE, 38 DEFAULT, 42 QUESTSTUN, 43–57 MINUS / CURSE stat types, 60 HIDE, 61 BLIND, 62 DEADLYBLESSING, 63 GUILDBUFAC, 65 QUESTENTANGLE, 96 AIRBORNE, 98 CROSSDROP, 99 METEOR, 102 SPDOWNRATE (2017: MENDOWNRATE), 103 CRIUPRATE, 104 DMGSHIELD, 108 MINEREWARD, 111 MARATE, 112 SURPRISE |
| `ac_DefaultSubStateActor` (also the base class, a separate instance) | 64 NATURALENEMY, 68 FATALKNOCKBACK, 69 EVENTTRANSFORM, 71 CANTHEAL, 72 CANTCHAT, 73 ACMODE, 74 MRMODE, 79 HUMARWCRATE, 80 HUMARACRATE, 81 ACDOWNRATE, 85 RANGEEVASION, 86 USESPRATE, 87 SOULFREE, 89 MOBAPU, 90 HELGANONE, 91 HELGBALL (2017 names; these slots have no own 2016 member) |
| `SubAbnormalStateActorPoison` | 22 BLOODING, 27 DOTDAMAGE, 33 POISON, 67 KNOCKBACK (shares `ac_POISON`), 83 BURN, 84 FITBLOODING, 94 BURNPAINME |
| `SubAbnormalStateActorDisease` | 34 DISEASE |
| `SubAbnormalStateActorAreaDamage` | 82 GTI, 95 BURNPAINFOE, 101 SPDOWNRATEME (2017: MENDOWNRATEME) |
| `SubAbnormalStateActorHPHeal` / `SPHeal` / `HPSPHeal` | 29 CONHEAL / 41 CONSPHEAL / 66 CONHPSPHEAL |
| `SubAbnormalStateActorMagicField` | 107 MAGICFIELD |
| `SubAbnormalStateFear` / `SubAbnormalStateCaptivate` / `SubAbnormalStateCannotTarget` | 28 FEAR / 70 CAPTIVATE / 105 CANNOTTARGET |
| `SubAbnormalStateMaxHP` | 24 MAXHPRATE, 25 MAXSPRATE, 39 MAXHPPLUS, 40 MAXSPPLUS |
| `SubAbnormalStateActorShield` / `ManaShield` / `ShieldHPRate` | 16 DAMAGESHIELD, 92 UBAUP, 93 UBADOWN / 17 MANASHIELD / 115 DMGSHIELDRATE |
| `SubAbnormalStateActorRangeIntercept` | 59 RANGESHIELDCOUNTER |
| `SubAbnormalStateActorLastDmgRatio` / `…_DefSide` / `SubAbnormalStateActerTimeAttack` | 75 (2016 member `ac_TOTALDAMAGERATE`; 2017 name ANGRY) / 76 (`ac_TOTALDAMAGERATE_BYDEF`; 2017 DAMAGENEGLECT) / 77 TIMEATTACK |
| `SubAbnormalStateDamageMinus` / `SubAbnormalStateRangeDamageMinusAtk` / `SubAbnormalStateActorDamageDownRate` | 114 RANGEDMGDOWNRATE / 119 RANGEDMGDOWNRATEATK / 116 DMGDOWNRATE |
| `SubAbnormalStateActorPartyRecharge` / `SelfRevive` | 26 DEADHPSPRECOVRATE / 58 SELFREVIVE |
| `SubAbnormalStateActorCastDelay` / `DelCastTime` / `IgnoreCoolTime` | 30 CASTINGTIMEPLUS / 118 DELCASTING / 31 COOLTIMEREMOVE |
| `SubAbnormalStateActorSilence` / `Silencetoone` | 32 MAGICATTACKNOUSE / 88 MAGICNOTATTACKONEUSE (2017: ONETIMECANNOTUSESKILL) |
| `SubAbnormalStateActorUseSPDown` / `HideDamage` / `MinHP` | 100 USESPDOWN / 106 HIDEDAMAGE / 117 MINHP |
| `SubAbnormalStateActorDetachProcess` / `Bomb` / `Dispel` | 78 DETACHPROCESS / 97 BOMBSHOT / 113 DISPEL |
| `SubAbnormalStateActorExpUpRate` / `DropUpRate` | 109 EXPUPRATE / 110 DROPUPRATE |
| `SubAbnormalStateActorDmgState` (`ac_DOTWCRATE`) | **none**: the member is built but no `ac_SubStateList` slot points to it (§4.2) |

Slot writes of the damage-ratio classes: `ac_TOTALDAMAGERATE` → 0x4b (75), `ac_TOTALDAMAGERATE_BYDEF` → 0x4c (76),
`ac_TIMEATTACK` → 0x4d (77). The 2017 enum calls 75 / 76 ANGRY / DAMAGENEGLECT; the 2016 data agrees with the 2016
use (type 75 rows SubStaAngry / SubStaAiriBuff / SubStaWarNSetBuff carry `SAA_TOTALDAMAGERATE`). 67 KNOCKBACK points
at the `ac_POISON` instance.

Corrections to the class table of Z03 §6.1 (read here from the constructor): the shield actor serves 16 / 92 / 93
(104 DMGSHIELD is the plain base actor); RangeIntercept is 59 (not 114: 114 is `SubAbnormalStateDamageMinus`);
MagicField is 107 and Dispel 113; Poison serves 22 / 27 / 33 / 67 / 83 / 84 / 94 and `DmgState` serves nothing.
Which `SubAbState.shn` kinds the 2016 data actually uses (rows per type) is listed per actor below.

### 1.2 Actor virtual slots

All actor classes have 27 slots. Base implementations are shared folded stubs (the PDB gives every slot name at the
stub address). "Override" lists the classes that replace the slot.

| Slot | Name *(pdb2016)* | Base behaviour | Overrides | Called from |
|---|---|---|---|---|
| 0x00 | `sasa_IndexString` | "Actor" @ FUN_004015e0 | every class: its own name (FUN_00401600…00401810) | logging |
| 0x04 | `sasa_AttachObject(e, o)` | §2.1 @ FUN_0040bbd0 | Dispel 0040ca20, Captivate 0040d3f0 (Z03 §6.6) | `ase_AttachObject` (§1.3) |
| 0x08 | `sasa_DetachObject(e, o)` | §2.2 @ FUN_0040bc60 | DetachProcess 0040c1c0, Bomb 0040c520, ExpUpRate 00408f90, DropUpRate 00409230, Captivate 0040d460 | `ase_DetachObject` (§1.3) |
| 0x0c | `sasa_Routine(e, bearer, index) → bool` | §2.3 @ FUN_00406d50 | Poison 0040d4c0, Disease 0040b8a0, AreaDamage 0040d640, DmgState 0040dc60, HPHeal 00406e90, SPHeal 00407030, HPSPHeal 00407120, MagicField 00408d80, Fear 00406e30 | `AbnormalStateTickRoutine::ase_Routine`, `AbnormalStateEachTickRoutine::ase_Routine` (§1.3), base `sasa_DetachObject` (§2.2) |
| 0x10 | `sasa_Act_DamegeAbsorpt(o, e, &dmg)` | no-op FUN_004c2450 | Shield 00407370, ManaShield 00407400 | `roe_AttackPowerCalcDamage` (§3.3); part 2 |
| 0x14 | `sasa_Act_Killed(p, e)` | no-op FUN_00509900 | PartyRecharge 00407730, SelfRevive 00407910 | part 2 |
| 0x18 | `sasa_Act_CastDelay(e) → int` | 0 FUN_004a9c90 | CastDelay 004072b0 | part 2 |
| 0x1c | `sasa_Act_SkillBlast(e) → SkillBlast` | 0 FUN_004a9c90 | Silence 0063ecc0, Silencetoone 00401d20 | `smo_SkillBlastOption` (Z03 §6.1); part 2 |
| 0x20 | `sasa_Act_CoolTimeIgnore(e) → bool` | 0 FUN_00615e70 | IgnoreCoolTime 00500380 (returns 1) | `smo_SkillCooltimeSet` (Z03 §6.6) |
| 0x24 | `sasa_AfterEnchant(o)` | no-op FUN_00549070 | MaxHP 00401990 | `ase_AfterEnchant` (§1.3); part 2 |
| 0x28 | `sasa_Act_DamegeIntercept(e, &dmg)` | no-op FUN_00509900 | RangeIntercept 004074f0 | part 2 |
| 0x2c | `sasa_Act_LastDamegeInterceptByAtk(e, &dmg)` | no-op FUN_00509900 | LastDmgRatio 00407570, HideDamage 00407570 (same function) | part 2 |
| 0x30 | `sasa_Act_LastDamegeInterceptByDef(o, e, &dmg)` | no-op FUN_004c2450 | LastDmgRatio_DefSide 00407650, TimeAttack 0040ba30 | `so_mobile_DamageOverTime` (§3.5); part 2 |
| 0x34 | `sasa_ApplyAbstate(e, o) → bool` | 0 FUN_004021b0 | Bomb 0040c640 | part 2 |
| 0x38 | `sasa_Act_UseSPDown(e, sp) → sp` | returns `sp` FUN_004021c0 | UseSPDown 004021d0 | part 2 |
| 0x3c | `sasa_IsTargetable() → bool` | 1 FUN_005af8d0 | CannotTarget 004b8d20 (returns 0) | target checks (Z03 §2.2) |
| 0x40 | `sasa_Act_AttackCount(…)` | no-op FUN_00549070 | HideDamage 00408ef0 | `smo_SwingDamage` FUN_00432f30; part 2 |
| 0x44 | `sasa_Act_ExpUpRate(e) → u32` | 0 FUN_004a9c90 | ExpUpRate 00402240 | exp calculation (Z03 §8.2); part 2 |
| 0x48 | `sasa_Act_DropUpRate(e) → u32` | 0 FUN_004a9c90 | DropUpRate 004022a0 | drop rate (Z09); part 2 |
| 0x4c | `sasa_Act_DamageMinusRate(e) → u32` | 0 FUN_004a9c90 | DamageMinus 00402300 | part 2 |
| 0x50 | `sasa_Act_DagamgeMinusByRange(o, e, …, &dmg)` | no-op FUN_00402370 | DamageMinus 004094d0 | part 2 |
| 0x54 | `sasa_Act_AllDamageAbsorb(e, &dmg)` | no-op FUN_00509900 | ShieldHPRate 00402390 | `so_smo_LastDamageOperation` FUN_0040cbe0; part 2 |
| 0x58 | `sasa_Act_NormalDamageDown(e, &dmg)` | no-op FUN_00509900 | DamageDownRate 004023d0 | `so_smo_LastDamageOperation` (normal hits); part 2 |
| 0x5c | `sasa_Act_DotDamageDown(e, &dmg)` | no-op FUN_00509900 | DamageDownRate 00402450 | `so_smo_LastDamageOperation` (DoT); part 2 |
| 0x60 | `sasa_Act_DelCastTime(e, &t)` | no-op FUN_00509900 | DelCastTime 004024d0 | part 2 |
| 0x64 | `sasa_Act_MinHP(e, &minHP)` | no-op FUN_00509900 | MinHP 004024f0 | `so_smo_LastDamageOperation`; part 2 |
| 0x68 | `sasa_Act_DagamgeMinusByRangeAtk(o, e, …, &dmg)` | no-op FUN_00402370 | RangeDamageMinusAtk 004095f0 | part 2 |

The destructor of every class is the shared `~SubAbnormalStateActor` @ FUN_00402380 (no-op).

### 1.3 How an element reaches its actor (the element layer)

Every `ABSTATEINDEX` has one `AbnormalStateElement` object (`abstatetemplate.asl_AbstateList`, built by
`AbnormalStateList::AbnormalStateList` @ FUN_0040f1e0; the subclasses are part 3). Its slots dispatch to the actor:

```pseudo
asl_Routine(list, o)  (every object tick, Z03 §6.4)                                   @ FUN_00406840
    for each element e in o's abstate list (l_4AllInList @ FUN_00487c50):
        node = abstatetemplate.asl_AbstateList[e.aeo_Index]   (missing → skip, continue)
        ok = ListIter_ObjectAbStateRoutine::lid_Call → node.vt[1] ase_Routine(o, slot, e, &removed)   @ FUN_004067e0
        if not ok: stop the walk for this tick            # l_4AllInList returns at the first false (see Z22-B1)

AbnormalStateElement::ase_Routine(o, slot, e, &removed)          (base: expiry only)    @ FUN_00406910
    if e.aeo_Tick.terminate <= g_CurrTick:
        o.so_AbnormalState_Reset(e.aeo_Index)  (vt 0x650 → asl_AbstateReset, detach hook, Z03 §6.4)
        clear bit e.aeo_Index in o.so_Getabstatebit() (vt 0x4a0, brief-info bitmap)
        so_AbnormalState_BroadcastReset(o, index)          # 0x2428 NC_BAT_ABSTATERESET_CMD to sight (Z03 §6.3)
        e.aeo_Index = MAX_ABSTATEINDEX (0x318); e.aeo_Strength = 0
        free the slot (o.so_mobile_AbstateList().list.vt[3](slot));  removed = 1
    return 1

AbnormalStateTickRoutine::ase_Routine(o, slot, e, &removed)                             @ FUN_00406a40
    base ase_Routine; if removed: return 1
    if e.aeo_Tick.nextaction.m_NextTick < g_CurrTick:
        m_NextTick += m_TickInterval                      # interval = SAA_TICK of the row (aeo_Set, Z03 §6.2)
        return actor(e).sasa_Routine(e, o, e.aeo_Index)   # 1 when the actor is missing
    return 1

AbnormalStateEachTickRoutine::ase_Routine(o, slot, e, &removed)                         @ FUN_00406b70
    base ase_Routine; if removed: return 1
    return actor(e).sasa_Routine(e, o, slot)              # every object tick; passes the list slot as "index"
                                                          #   (only Fear uses this class and ignores the argument)

ase_AttachObject(e, o)                                                                  @ FUN_00401d40 (Z18)
    actor(e).sasa_AttachObject(e, o);  if ActionEffectAbStateTable has an item action for the row's InxName:
    o.vt[0x5d8](action, 0xffff) (player: so_AddItemAction)
ase_DetachObject(e, o)                                                                  @ FUN_00402000
    actor(e).sasa_DetachObject(e, o);  same lookup → o.vt[0x5dc](action, 0xffff) (player: so_DelItemAction)
AbnormalStateElementRecover::ase_DetachObject(e, o)                                     @ FUN_004084e0
    ase_DetachObject; then o.vt[0xd4c](0) (player: so_SendSpeedInformation)        # only StaCannotControl uses it
ase_AfterEnchant(o)                                                                     @ FUN_00405500
    actor(this.ase_index).sasa_AfterEnchant(o)            # after each stat recalculation (Z03 §6.2)
```

Consequences for the actors:

- `sasa_Routine` runs **only** for states whose element is an `AbnormalStateTickRoutine` (every `SAA_TICK` ms; 189
  states, all damage / heal / area states) or an `AbnormalStateEachTickRoutine` (every object tick; the 21 fear
  states). The other element classes (`ElementNormal`, `PartyEnchant`, `RestCount`, `ReinforcedMove`, …) never call
  slot 0x0c, so an abstate whose `SubAbState.Type` maps to a routine actor but whose element is `ElementNormal`
  never ticks. In the 2016 data that happens for StaChainLightningStun (84) and StaThunderBolt (89) (Type 22, rows
  with `SAA_TICK` + `SAA_DOTDAMAGE`; ThunderBolt's damage is 0, ChainLightningStun's KeepTime equals its tick, so at
  most one tick would be lost) and StaAdlFLoussierIMT (499, Type 34, damage 0) *(table join of AbState.shn,
  SubAbState.shn and the element constructor)*.
- The tick catches up: `m_NextTick` advances by the interval, not to `now + interval`, so after a stall the next
  routine calls fire back to back until the schedule is caught up *(inferred from the arithmetic)*.
- **Return value contract:** an actor routine that returns 0 stops the bearer's whole abstate walk for that tick:
  the remaining elements neither run nor expire until the next tick (original bug) Z22-B1. Every routine below
  states when it returns 0.

### 1.4 Shared helpers

```pseudo
aeo_GetCaster(e) → obj | null                                                           @ FUN_00401b90
    c = e.aeo_Caster.obj; if c and c.so_GetCharRegistNumber() (vt 0x344) == e.aeo_Caster.chrregnum: return c
    e.aeo_Caster.obj = null; return null                  # the setter left / the handle was reused

aeo_FindCasterObject(e, near) → player | null                                            @ FUN_00402800
    c = e.aeo_Caster.obj
    if c and c.so_ObjectType() (vt 0x4d0) == 2 (player) and not c.so_IsEmpty() (vt 0x300)
         and c.charRegNum == e.aeo_Caster.chrregnum and dist²(c, near) < 100,000,000 (10,000 units):
        return c
    e.aeo_Caster.obj = null; return null                  # mob casters are never "found": their DoT / HoT
                                                          #   is applied with attacker = null (and the pointer is wiped)
aeo_GetCasterLevel / aeo_GetCasterAttackPower  @ FUN_00401260 / FUN_00401270  = e.aeo_Caster.nLevel / .nAttackPower
    (the snapshot aeo_Set takes for SAA_DOTWCRATE / SAA_DOTMARATE rows, Z03 §6.2)
aeo_GetRestCount @ FUN_004011f0 = e.aeo_RestCount;  aeo_GetIndexStrength @ FUN_00401230 = abstateidentarray[index].str
aeo_TickStruct @ FUN_0042ab00 = &e.aeo_Tick  ({start, terminate, Metronome nextaction})

so_AbnormalState_Set_Simple(o, setter, index, strength, inform) → bool   (vt 0x644)     @ FUN_004163d0
    index ≥ 0x318: assert "as_FromIndex : Invalid skill idx", return 0
    s = dic_abstate.as_StateIndexList[index]; s null or s.subabstate[strength] missing: return 0
    ok = o.so_AbnormalState_Set (vt 0x638)(setter, index, strength, s, g_CurrTick, 0, keep −1, 0, 0, 0)   (Z03 §6.2)
    if not ok: return inform ? 0 : 1
    if inform:                                            # g_NewAbstateStrength = the strength aeo_Set settled on
        so_AbnormalState_BitSet(o, index); o.so_AbnormalState_Inform (vt 0x3f0)(index, row(str).KeepTime, 1)
        so_AbnormalState_BroadcastSet(o, index, row(str).KeepTime, str)                      (0x2429 / 0x2427 / 0x1C18)
    return 1
    # no resist roll: area-applied states always land unless asl_AbstateSet refuses them

AxialListNearScan (scan buffer, 200 entries {member, distance²})                        @ FUN_004c17c0
    ali_Work(o, d²) (per object so_AllOfRange visits):                                  @ FUN_004c1cf0
        keep o when o.smo_GetMode() (vt 0x484) ∉ {0, 3}, this.alns_ValidObject(o) (vt +4), fewer than 200 kept,
        and o has neither STA_IMMORTAL (291) nor STA_ADLFLOUSSIERIMT (499) (so_AbnormalState_IsSet, vt 0x3e4)
    alns_GetNumber / alns_GetMember(i)  @ FUN_004c17e0 / FUN_004c17f0;  alns_Sort (qsort by d², FUN_00401460 with
        alns_Compare FUN_004c1810) is not called by the actors: members come in sight-list order
AxialListNearScanEnemyorAll(center, isAllTarget, isNotMe)                               @ FUN_004c1830
    alns_ValidObject(o):                                                                @ FUN_004c1870
        reject 291 / 499 holders, NPCs (so_ObjectType 4), objects so_SubLayer_CanSee(o, center) refuses
        killer = center.so_mob_MobID (vt 0x708) ≠ −1 ? MKID_MOB : MKID_USER
        reject unless mobdatabox.mdb_CanIKill(o.so_mob_MobID, killer)
        reject o == center when isNotMe
        isAllTarget: accept players (2), mobs (5), servants (10) only — friend or foe
        else: accept when center.so_mobile_ICanDamageTo(o) (vt 0x980) and center.so_mobile_IsEnemy(o) (vt 0x72c)
    (o.vt[0x70c] so_mob_DataBox is called and its result ignored)
so_AllOfRange_Simple(center, iterator, range)                                           @ FUN_00553c20
    so_AllOfRange(center, sight, center.location, range, no sector, iterator, 1, 0xffff)
    # here `range` is the row's SAA_AREA value (distance units around center)
```

## 2. The base actor `SubAbnormalStateActor`

Used directly by all stat-only kinds (§1.1); every derived class inherits the slots it does not override, so the
three behaviours below apply to every abstate unless noted.

### 2.1 Attach  @ FUN_0040bbd0

```pseudo
sasa_AttachObject(e, o):
    if e and o and row.Has(SAA_METASKIN):                 # 41 GTI rows (Type 82) and a few others
        p = o as player (ShineDynamicCast); not a player: return
        sp_StateChangeToNormal(p)                                                        @ FUN_005606e0
            mode 4 (tent / camp): so_ply_ReinforceFoldtent (vt 0x488)
            mode 6 (riding): sp_MoverSystem_Type ≠ MVST_MOVER ? sp_HorseOff : sp_MoverSystem_GetOff(0)
        sp_SetAbstatePolymorph(p, skin = row.Arg(SAA_METASKIN), e.aeo_Index)             @ FUN_004a33c0
```

```pseudo
ShinePlayer::sp_SetAbstatePolymorph(p, skin, index)                                    @ FUN_004a33c0
    if skin == 0xFFFF:                                     # end of a skin state
        if p.sp_nPolymorphAbstateIndex == index: sp_SkinPolymorph(p, 0xFFFF, index, 1)   (FUN_004a3280, Z18)
        return
    if p.brief.polymorph ≠ 0xFFFF:                         # already transformed: undo the current form first
        cur = p.sp_nPolymorphAbstateIndex
        if cur == MAX_ABSTATEINDEX:                        # transformed by an item / skill (NC_CHAR_POLYMORPH, Z07 §3.4)
            reset STA_POLYMORPH (97) and STA_IMMORTAL (291) when set (so_AbnormalState_Reset, vt 0x650)
            cur = STA_POLYMORPH
        sp_SkinPolymorph(p, 0xFFFF, cur, 1)
    sp_SkinPolymorph(p, skin, index, 1)                    # shows the new form (0x10AF NC_CHAR_POLYMORPH_CMD, Z07)
```

### 2.2 Detach  @ FUN_0040bc60

```pseudo
sasa_DetachObject(e, o):
    if e null or o null: return
    if row.Has(SAA_RELESEACTION):                         # "release action": one last routine run on removal
        m = o as mobile object; none: return               # (skips the METASKIN part too)
        if m.smo_IsActiveMode() (FUN_0055d780: mode ∈ {1, 2, 4, 6}, mask 0x56):
            this.sasa_Routine(e, m, e.aeo_Index)          # virtual: the class's own routine (e.g. a final DoT tick)
    if row.Has(SAA_METASKIN) and o is a player: sp_SetAbstatePolymorph(p, 0xFFFF, e.aeo_Index)   # back to normal
```

### 2.3 Routine  @ FUN_00406d50

```pseudo
sasa_Routine(e, bearer, index) → 1:
    if row.Has(SAA_SCANENEMYUSER) and bearer.field and field.fm_GetGuildTournamentSystem():
        GuildTournamentSystem::ScanEnemyUser(gts, bearer)     # FUN_0047a3d0, guild tournament (Z16)
    return 1
```

Every derived routine ends by calling this one, so `SAA_SCANENEMYUSER` works on any ticking state.

### 2.4 Applying states to an area

Two helpers used by the area actors (§4) and the bomb (part 2). `action` is the `SubAbstateAction` whose rows carry
the state to apply; the row value is an **AbState ID** (the `ID` column of `AbState.shn`, looked up with
`as_FromID`, assert "as_FromID : Invalid skill id"), turned into its `AbStataIndex`. Each of the four row slots
that carries `action` is applied in turn.

```pseudo
sasa_SetAbstateToArea(e, setter, scan, action) → bool                                   @ FUN_00401bd0
    e, setter or scan null: return 0;  row missing: assert, return 0
    for each row slot with action:  idx = AbState[slot.value].AbStataIndex  (bad ID: assert, return 0)
        for each member t of scan:
            if not t.so_AbnormalState_IsSet(idx) (vt 0x3e4): t.so_AbnormalState_Set_Simple(setter, idx, 1, 1)
    return 1                                              # strength is always 1; holders are not refreshed

sasa_SetAbstateToArea_TargetNum(e, setter, scan, action, maxTargets, reapply) → bool    @ FUN_0040b670
    e, setter or scan null: return 0;  row missing: assert, return 0
    for each row slot with action:  idx = …as above…; n = 0
        for each member t of scan, while maxTargets == 0 or n < maxTargets:
            skip t in mode 3 (dead) or t.so_AmIAlreadyDead() (vt 0x28)
            skip t already holding idx unless reapply
            if t.so_AbnormalState_Set_Simple(setter, idx, 1, 1):
                if this row has SAA_DOTMARATE or SAA_DOTWCRATE:   # spread DoT keeps the original caster's snapshot
                    t's new element: aeo_Caster.nLevel / nAttackPower = e's
                n += 1
    return 1
```

## 3. Damage over time

### 3.1 Data

Rows of the Poison / Disease kinds in the 2016 `SubAbState.shn` (distinct InxNames / rows; actions used):

| Type | Kinds / rows | Actions |
|---|---|---|
| 22 BLOODING | 53 / 138 | `SAA_TICK`, `SAA_DOTDAMAGE` (one row also ATKSPEEDDOWNRATE) |
| 33 POISON | 16 / 63 | TICK, DOTDAMAGE |
| 34 DISEASE | 25 / 52 | TICK, DOTDAMAGE |
| 83 BURN / 84 FITBLOODING | 2 / 23, 1 / 20 | TICK, DOTDAMAGE |
| 94 BURNPAINME | 1 / 6 (SubStaBurnPainMe) | TICK, `SAA_MAXHPRATEDAMAGE` (self damage, ‰ of max HP) |

`SAA_DOTDIEDAMAGE`, `SAA_HPRATEDAMAGE`, `SAA_DOTWCRATE` and `SAA_DOTMARATE` appear only in area kinds (§4.1) and the
bomb. Type 27 DOTDAMAGE and 67 KNOCKBACK have no ticking rows (67 rows are knock-back moves; their element is
`AbnormalStateReinforcedMove`, part 3).

### 3.2 Poison actor  @ FUN_0040d4c0 (types 22, 27, 33, 67, 83, 84, 94)

```pseudo
SubAbnormalStateActorPoison::sasa_Routine(e, bearer, index) → bool:
    if e null: return 0                                   # Z22-B1
    if bearer null: return 0
    if bearer has STA_IMMORTAL (291) or STA_ADLFLOUSSIERIMT (499): return 0      # Z22-B1: also blocks the rest
    caster = aeo_FindCasterObject(e, bearer.location)     # a player within 10,000 units, else null (§1.4)
    dmg = sasa_GetDamage(e, bearer, bearer.location)
    if dmg ≠ 0: bearer.so_mobile_DamageOverTime (vt 0x730)(caster, dmg, index, send = 1, out = null)   (§3.5)
    return SubAbnormalStateActor::sasa_Routine(e, bearer, index)       # §2.3, returns 1
```

### 3.3 `sasa_GetDamage`  @ FUN_0040b360

```pseudo
SubAbnormalStateActorPoison::sasa_GetDamage(e, victim, attackLoc) → int dmg:
    e or victim null: return 0
    dmg = 0
    if row.Has(SAA_DOTDAMAGE):
        dmg = max(1, row.Arg(SAA_DOTDAMAGE) + smo_DotDamageAppend(victim, e))
        if dmg ≥ victim.HP (vt 0x4e8, unsigned): dmg = HP − 1          # the flat part never kills
    if row.Has(SAA_DOTDIEDAMAGE):
        dmg = max(1, dmg + row.Arg(SAA_DOTDIEDAMAGE) + smo_DotDamageAppend(victim, e))   # no cap: can kill
    if v = row.Arg(SAA_MAXHPRATEDAMAGE): dmg += victim.MaxHP (vt 0x4f0) × v / 1000   (unsigned)
    if v = row.Arg(SAA_HPRATEDAMAGE):    dmg += victim.HP × v / 1000
    if row.Has(SAA_DOTWCRATE):
        ap = e.aeo_Caster.nAttackPower × row.Arg(SAA_DOTWCRATE) / 1000
        dmg += roe_normalPY.roe_AttackPowerCalcDamage(EngageArgument(att = null, def = victim, attackloc), ap,
                                                      e.aeo_Caster.nLevel)
    if row.Has(SAA_DOTMARATE): same with SAA_DOTMARATE and roe_normalMA
    return dmg

ShineMobileObject::smo_DotDamageAppend(o, e) → int                                     @ FUN_00408a60
    by the element's SubAbState.Type: 22 → o.smo_Param.DotDamagePlus.Blooding, 33 → .Poison, 34 → .Desease,
    83 → .Burn, 84 → .PitBlooding, any other type → 0
    # DotDamagePlus (Parameter::Container +0xcc0) is filled from SAA_ADDBLOODINGDMG / SAA_ADDPOISONDMG /
    #   SAA_ADDALLDOTDMG / SAA_SUBTRACT* rows by the matrix (Z12 §2.5)
```

```pseudo
RulesOfEngagement::roe_AttackPowerCalcDamage(roe, ctx, ap, casterLevel) → int          @ FUN_005047d0
    ctx.def null: assert "RulesOfEngagementroe_AttackPowerCalcDamage : Null Obj", return 0
    if def.so_mobile_IsImmortal() (vt 0x1c): return 0
    if def has STA_MONKEYDEFENSE (365): return 1
    defence = roe.roe_DefendPower(ctx) (vt 0xc) + roe.roe_FreeStateDefendPower(ctx) (vt 0x34)   # the second is 0
                                                          #   here (att = null), Z12-B7
    r = (casterLevel + 1) × ap / defence                  # double
    r = r × 1024 / def.so_ply_ChargedEffectContainer().cec_DefendForceRate1024 (vt 0x498, +0x14; 1024 without
                                                          #   charged items)
    angle = 1000; if ctx.attackloc and attackloc ≠ def.location:
        angle = (def is a player ? damagebyangle_Ply : damagebyangle_Mob)[def.direction − ddt_DirectSR(attackloc − def)]
    r = r × angle / 1000                                  # the DoT passes the bearer's own location → no angle factor
    if def is a mob (5):    r = r × LevelGap_Player_to_Monster::GetLevelCapRate(casterLevel, def.level) / 1000
    if def is a player (2): r = r × LevelGap_Player_to_Player::GetLevelCapRate(casterLevel, def.level) / 1000
    dmg = (int) r
    for each element x of def: actor(x).sasa_Act_DamegeAbsorpt(def, x, &dmg)          # shields (slot 0x10, part 2)
    return dmg
```

So a DoT state's attack-power part is `(level+1) × AP·rate/1000 / DefendPower`, scaled by the defender's charged-item
defence rate and the level-gap table; the defender's free-stat defence never enters (Z12-B7).

### 3.4 Disease actor  @ FUN_0040b8a0 (type 34)

```pseudo
SubAbnormalStateActorDisease::sasa_Routine(e, bearer, index) → bool:
    caster = aeo_FindCasterObject(e, bearer.location)     # no null test of e / bearer (Poison has one)
    if bearer has STA_IMMORTAL or STA_ADLFLOUSSIERIMT: return 0          # Z22-B1
    dmg = max(1, row.Arg(SAA_DOTDAMAGE) + smo_DotDamageAppend(bearer, e));  if dmg ≥ HP: dmg = HP − 1
    if dmg ≠ 0: bearer.so_mobile_DamageOverTime(caster, dmg, index, 1, null)
    return SubAbnormalStateActor::sasa_Routine(e, bearer, index)
    # = the DOTDAMAGE term of §3.3 only (Disease rows have no other damage action); the damage is at least 1 even
    #   when the row has no DOTDAMAGE, except on a 1-HP bearer (HP − 1 = 0 → no damage)
```

### 3.5 Applying the damage: `so_mobile_DamageOverTime`  (vt 0x730)  @ FUN_00409cd0

Also used by magic fields (Z09 §12.5, index 0x318) and the area actors (with `send = 0`).

```pseudo
ShineMobileObject::so_mobile_DamageOverTime(o, attacker, dmg, abIndex, send, *outDmg):
    if attacker: for each element of attacker: aeo_Attack (FUN_004a42a0: states whose MiscData reset
        condition "attack" is set end now)                # dealing DoT counts as attacking
    if o.sp_IsEthereal() (vt 0x9e4; mobs 0): return
    P = o.so_parameter() (Parameter::Container, smo_Param)
    miss = false
    if P.MissPercentFix (+0xcd0, ‰) ≠ 0:                  # SAA_MISSRATE (GTI states)
        if attacker null:                miss = rand1000 < MissPercentFix
        else if P.RangeOver (+0xda8) ≠ 0 and dist²(o, attacker) > RangeOver²:
                                         miss = rand1000 < MissPercentFix     # SAA_RANGEOVER: only far attackers
    if miss:
        to sight of o (so_AllOfRange, incl. o): 0x243C NC_BAT_DOTDAMAGE_CMD {
            u16 object = o.handle, u32 resthp = o.HP, u16 damage = 0,
            u16 abstate = abIndex == 0x318 ? 0xFFFF : abIndex, u16 hpchangeorder = o.so_mobile_GetHPChangeOrder (vt 0x7e8),
            u8 IsMissDamage = 1 }
        return
    for each element x of o: actor(x).sasa_Act_LastDamegeInterceptByDef(o, x, &dmg)    # slot 0x30 (part 2)
    dmg = o.vt[0xbe8](dmg)       # player: so_ply_CheckDamageAbsorption (Z09 §16.6: protectors take it); mob: identity
    if dmg < 1: return
    dmg = o.so_smo_LastDamageOperation (vt 0xdb4)(dmg, isDot = 1)   # FUN_0040cbe0: DoT-down, absorb, min-HP hooks (part 2)
    left = o.HP − o.so_batobj_GetDamage() (vt 0x65c, damage already reserved by pending hits)
    if dmg < left: o.so_DamagedBy (vt 0x5c0)(attacker, dmg, aggro 1000, 0); left −= dmg
    else:          o.so_KilledBy (vt 0x5bc)(attacker, left, 1000, 1); left = 0; o.so_mobile_DeadCheck (vt 0x8d4)(1)
    so_DamageLog(o, "so_mobile_DamageOverTime", hpChangeOrder, …)        (debug log, Z09 §31)
    if outDmg: *outDmg = dmg
    if send:
        to sight of o (incl. o): 0x243C NC_BAT_DOTDAMAGE_CMD { object = o.handle, resthp = left, damage = (u16) dmg,
            abstate = abIndex == 0x318 ? 0xFFFF : abIndex, hpchangeorder, IsMissDamage = 0 }   (0xF bytes with opcode)
```

`PROTO_NC_BAT_DOTDAMAGE_CMD` *(pdb2016)*: `{ u16 object, u32 resthp, u16 damage, u16 abstate, u16 hpchangeorder,
u8 IsMissDamage }` (13 bytes; layout already annotated by Z09). `damage` is truncated to 16 bits although the
server value is an int.

Client `FUN_004b5740` (GameFrameWork scene): unknown handle → ignored; shows `damage` as a number (vt 0x198) unless
`abstate` is 14 STA_VIOLENCE, 339 STA_KARENDOTHEAL or 0x318; `resthp == 0` plays the death; sets the HP bar from
`resthp` ordered by `hpchangeorder` (older orders are ignored, so out-of-order HP packets do not roll the bar back
*(inferred from the order argument)*); `damage == 0` with `IsMissDamage == 1` shows "miss"; `abstate ≠ 0xFFFF` plays
that abstate's view effect from the client AbState view table when it has one.

## 4. Area damage

### 4.1 Data

| Type | States (element) | Row actions |
|---|---|---|
| 82 GTI | 55 kinds; ticking: StaGTIScan, GTIBinding, GTIBomb1/2, GTIVirusStart, GTIVirusMove, StaEglackMad05 (TickRoutine); the 48 others (event skins StaE_*, StaGTIMetaSlime, …) are `ElementNormal` | METASKIN 41, NOATTACK 40, SPEEDRATE, MISSRATE, REFLECTDAMAGE, MAXHPRATEDAMAGE, AREA 4, SETABSTATE 2, TARGETALL / TARGETNOTME 2, SCANENEMYUSER 1, RELESEACTION 2, RANGEOVER 2, DOTDIEDAMAGE 1, HPRATEDAMAGE 1, TICK 6 |
| 95 BURNPAINFOE | StaBurnPainFoe (462), StaSDVale01_Wheel (760) | TICK, AREA, DOTWCRATE |
| 101 SPDOWNRATEME | StaDeepFearMenDownRate01 (468) | TICK, AREA, TARGETNUMVER, SETABSTATE |

Rows without `SAA_AREA` behave exactly like Poison (§3.2); the `ElementNormal` GTI kinds never tick at all
(§1.3: they are stat / skin states that only use the attach / detach part).

### 4.2 AreaDamage actor  @ FUN_0040d640 (types 82, 95, 101)

```pseudo
SubAbnormalStateActorAreaDamage::sasa_Routine(e, bearer, index) → bool:
    area = row.Arg(SAA_AREA)
    if area == 0: return SubAbnormalStateActorPoison::sasa_Routine(e, bearer, index)          # §3.2
    c = e.aeo_Caster.obj                                  # any object kind (not aeo_FindCasterObject)
    if c and c.charRegNum ≠ e.aeo_Caster.chrregnum: e.aeo_Caster.obj = null; return base routine (§2.3)
    if c null: return base routine                        # caster gone: the area part stops, the state stays
    if row.Has(SAA_SETABSTATE):                           # "spread a state" variant (e.g. StaDeepFearMenDownRate01)
        scan = AxialListNearScanEnemyorAll(center = c, isAllTarget = 0, isNotMe = 1)   # enemies of the caster
        so_AllOfRange_Simple(c, scan, area)               # around the CASTER
        n = row.Arg(SAA_TARGETNUMVER)
        n < 1 ? sasa_SetAbstateToArea(e, c, scan, SAA_SETABSTATE)
              : sasa_SetAbstateToArea_TargetNum(e, c, scan, SAA_SETABSTATE, n, reapply = 1)       # §2.4
        return base routine                               # no damage, no packet
    all   = row.Has(SAA_TARGETALL) or row.Has(SAA_TARGETNOTME)
    scan  = AxialListNearScanEnemyorAll(c, isAllTarget = all, isNotMe = row.Has(SAA_TARGETNOTME))
    so_AllOfRange_Simple(c, scan, area)                   # around the caster
    num = scan count; if num > 30: assert, num = 30       # targets past the 30th are ignored
    records[30] = zero
    for i in 0 … num−1:
        t = scan member i as mobile object; not mobile: return 0 (nothing sent; Z22-B1)
        if t has 499, t in mode 3, t dead (vt 0x28) or t has 291: continue        # record i stays all-zero
        if bearer null: return 0                          # (checked per target; unreachable from the tick path)
        d = sasa_GetDamage(e, t, bearer.location)         # §3.3 with t as the victim
        if d ≠ 0:
            got = 0; t.so_mobile_DamageOverTime(c, d, index, send = 0, &got)        # §3.5 without its own packet
            records[i] = { object = t.handle, resthp = t.HP (after), damage = got, hpchangeorder = t.vt[0x7e8]() }
    to sight of the caster (so_AllOfRange around c): 0x245A NC_BAT_AREADOTDAMAGE_CMD {
        u16 abstate = e.aeo_Index, u16 Centerobject = c.handle, u8 num, targetinfo target[num] = records[0 … num−1] }
                                                          # 7 + 12·num bytes with the opcode
    return base routine
```

- The damage is centred on the **caster** and credited to the caster (`so_DamagedBy(c, …)`), while the state sits on
  the bearer; for the self-buff kinds (BurnPainFoe: the caster carries the state) both are the same object.
  `TARGETALL` makes it hit players, mobs and servants alike (friend or foe), `TARGETNOTME` additionally spares the
  caster; without them only the caster's enemies are hit. Targets in miss / immortal states get an all-zero record.
- `num` counts scanned targets, not damaged ones: a target that was skipped or took no damage still occupies a record
  with `object = 0` (original bug) Z22-B2.

`PROTO_NC_BAT_AREADOTDAMAGE_CMD` *(pdb2016)*: `{ u16 abstate, u16 Centerobject, u8 num, targetinfo target[] }`,
`targetinfo = { u16 object, u32 resthp, u32 damage, u16 hpchangeorder }` (12 bytes) — matches the writes above.
Client `FUN_004b62f0`: looks up `Centerobject` (unknown → ignored); with `num == 0` it only plays the abstate's area
effect on the centre (attachment point "Ground" / "HairLink" / "Chest" from the effect table); otherwise it plays the
centre effect, then per record: unknown `object` (also 0) skipped; damage number when `damage > 0` and the abstate is
not 14 / 339 / 0x318; `resthp == 0` → death; HP bar from `resthp` / `hpchangeorder`; the abstate's hit effect on the
target. Sender list in `re-data/client-handlers.json`: only this routine.

### 4.3 DmgState actor (dead code)  @ FUN_0040dc60

`SubAbnormalStateActorDmgState` is constructed (`ac_DOTWCRATE`) but not entered in `ac_SubStateList`, so no element
can ever use it (original bug) Z22-B3. Its routine would be a variant of §4.2:

```pseudo
SubAbnormalStateActorDmgState::sasa_Routine(e, bearer, index) → bool:
    e or bearer null: return 0
    all = TARGETALL or TARGETNOTME; notMe = TARGETNOTME; n = row.Arg(SAA_TARGETNUMVER); area = row.Arg(SAA_AREA)
    area == 0: return Poison routine;  caster stale or null: base routine
    scan = AxialListNearScanEnemyorAll(center = caster, all, notMe); so_AllOfRange_Simple(BEARER, scan, area)   # around the bearer
    if SAA_SETABSTATE: SetAbstateToArea / _TargetNum(…, n, reapply 1) as in §4.2 — and then still deals damage
    packet 0x245A { abstate = index, Centerobject = caster.handle, num = 0 }
    limit = (n < 1 or count < n) ? count : n
    for i in 0 … limit−1:
        t = member i as mobile (not mobile: return 0)
        skip mode 3 / dead / 291 (499 is not tested here)
        d = sasa_GetDamage(e, t, bearer.location); if d ≠ 0:
            t.so_mobile_DamageOverTime(caster, d, index, 0, &got)
            write record at position i (not at position num) ; num += 1; size += 12
        if size > 7999: stop
    broadcast to the bearer's sight; return base routine
    # if a target in the middle is skipped, records land at their scan position while `num` only counts hits:
    #   the client reads `num` records from position 0 and misses the last ones (part of Z22-B3)
```

## 5. Heal over time

### 5.1 Data

| Type | Kinds / rows | Actions |
|---|---|---|
| 29 CONHEAL | 15 / 78 (HP potions, food, Restore, title restore, set heal, …) | TICK, `SAA_HEALAMOUNT` (77 rows), `SAA_HEALRATE` (1 row, ‰ of max HP) |
| 41 CONSPHEAL | 6 / 17 (SP potions, title SP restore) | TICK, HEALAMOUNT |
| 66 CONHPSPHEAL | 1 / 1 (SubStaSoleFire) | TICK, HEALAMOUNT |

No 2016 heal row uses `SAA_HEALAMOUNTMINUS`.

### 5.2 Actors

```pseudo
SubAbnormalStateActorHPHeal::sasa_Routine(e, bearer, index) → 1                         @ FUN_00406e90
    caster = aeo_FindCasterObject(e, bearer.location)
    h = row.Arg(SAA_HEALAMOUNT) − row.Arg(SAA_HEALAMOUNTMINUS)
    if h == 0: h = bearer.MaxHP × row.Arg(SAA_HEALRATE) / 1000          # unsigned
    h = h × e.aeo_SetItemEffect.siae_GetArgument_Base1000(SET_HEALRATE) / 1000            # FUN_00510050
    h = h × e.aeo_SetItemEffect.siae_GetArgument_Base1000ByEffect(SEIT_STA_DOT_HEAL_RATE_INCREASE) / 1000   # FUN_00510090
    bearer.so_mobile_HPHealOverTime (vt 0x734)(caster, h, index)
    return base routine

SubAbnormalStateActorSPHeal::sasa_Routine(e, bearer, index) → 1                         @ FUN_00407030
    bearer.so_mobile_SPHealOverTime (vt 0x738)(aeo_FindCasterObject(e, …), row.Arg(SAA_HEALAMOUNT))
    return base routine

SubAbnormalStateActorHPSPHeal::sasa_Routine(e, bearer, index) → 1                       @ FUN_00407120
    h = (HEALAMOUNT − HEALAMOUNTMINUS) × SET_HEALRATE / 1000 × SEIT_STA_DOT_HEAL_RATE_INCREASE / 1000   # no HEALRATE fallback
    bearer.so_mobile_HPHealOverTime(caster, h, index)
    bearer.so_mobile_SPHealOverTime(caster, HEALAMOUNT)   # SP part: no MINUS and no set-item rates (original bug) Z22-B4
    return base routine

SetItemAbstateEffect::siae_GetArgument_Base1000(set, idx) / …ByEffect(set, effect)       @ FUN_00510050 / FUN_00510090
    scan the element's 4 set-item effect slots {eb_Index, Argument_Base1000}: the first whose eb_Index is the
    SetIndex (≤ 0x10) / the SkillEffectIncreaseType + 1000 (1000…1014) asked for → its Argument_Base1000; none → 1000
    # the slots are filled when the state is set by a set-item effect (aeo_FillSetItemEffect / aeo_SetItemEffectStore, Z21)
```

```pseudo
ShineMobileObject::so_mobile_HPHealOverTime(o, caster, amount, index)   (vt 0x734)       @ FUN_0040e910
    before = o.HP
    o.so_Heal (vt 0x4e4)(amount × setitemskilleffect[SET_HPSPRECOVERYRATE] / 1000)   # HealRate ‰ applied inside,
                                                          #   capped at max HP (Z09 §17.3 cHeal)
    left   = o.HP − o.so_batobj_GetDamage()
    healed = o.HP − before
    RankingValue Lua event 0xac (caster's map, caster as player: dealt = healed) and (o's map, o as player:
        healed = healed) when the map has a ranking function (Z09 §14.3, Z09-B39)
    to sight of o (incl. o): 0x243C NC_BAT_DOTDAMAGE_CMD { object = o.handle, resthp = left, damage = 0,
        abstate = index, hpchangeorder = o.vt[0x7e8](), IsMissDamage = 0 }
    # index 0x318 (magic-field heals, Z09 §12.5) is sent as 0x318, not mapped to 0xFFFF as in §3.5 (original bug) Z22-B5;
    #   the client then looks up abstate 0x318 (no view entry) and suppresses the number — harmless in practice

ShineMobileObject::so_mobile_SPHealOverTime(o, caster, amount)   (vt 0x738)              @ FUN_004055d0
    o.so_recoversp (vt 0x5b8; player FUN_0042d0b0, mob FUN_0042cf30)(amount × setitemskilleffect[SET_HPSPRECOVERYRATE] / 1000)
    # no packet here; the SP change reaches the client through so_recoversp (Z03 / Z12)
```

The client shows a heal tick as a 0x243C with `damage = 0`: no number, the HP bar moves to `resthp`, and the
abstate's effect plays (§3.5).

## 6. Other routine actors (documented elsewhere)

- **MagicField** (type 107) `sasa_Routine` @ FUN_00408d80: Z09 §12.2 (2). The 2016 users are StaEglack04 (494) and
  StaEglackMad04 (501) (`SAA_TICK` + `SAA_SETACTIVESKILL`, TickRoutine elements): every tick a magic field of that
  skill appears at the bearer's feet. Its two `return 0` paths (missing skill / no free object / caster gone) stop
  the bearer's abstate walk for the tick (Z22-B1). This answers Z09 §12.8's open point "which SubAbState kinds use
  the magic-field actor".
- **Fear** (type 28) `sasa_Routine` @ FUN_00406e30: sets `smo_Flag.InFear` (Z03 §6.6, bit 2); runs every object tick
  (EachTickRoutine).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z22-B1 | `asl_Routine` + actor routines (Poison 0040d4c0, Disease 0040b8a0, AreaDamage 0040d640, DmgState, MagicField 00408d80) | the routines return 0 when the bearer has STA_IMMORTAL / STA_ADLFLOUSSIERIMT, on a null element / non-mobile scan member, or when MagicField cannot spawn; `l_4AllInList` stops at the first 0 | the bearer's later abstates neither tick nor expire while e.g. a poisoned player is under the login / map immortality | return 1 ("skip this effect") so the walk goes on |
| Z22-B2 | AreaDamage `sasa_Routine` 0040d640 | 0x245A `num` = scanned targets (≤ 30) including untouched ones, whose records are all zero | wasted bytes; the client skips object 0 | count and pack only damaged targets |
| Z22-B3 | `ActorCluster` 00405a10 / DmgState 0040dc60 | the DmgState actor is built but no SubState slot points to it; its routine also writes records at scan positions while counting only hits | dead code; if it were wired, records after a skipped target would be lost | register it (2017 has no matching SubState) or remove it; pack records by `num` |
| Z22-B4 | HPSPHeal `sasa_Routine` 00407120 | SP part ignores `HEALAMOUNTMINUS` and both set-item heal rates; HP part has no `HEALRATE` fallback | SoleFire-type HP+SP heals scale only the HP part | treat HP and SP alike (as HPHeal does for HP) |
| Z22-B5 | `so_mobile_HPHealOverTime` 0040e910 | sends `abstate = index` unmapped; `so_mobile_DamageOverTime` maps 0x318 → 0xFFFF | magic-field heals (index 0x318) make the client look up a non-existent abstate | map 0x318 to 0xFFFF |

## 7. Not reconstructed / uncertain

- The floating-point steps of `roe_AttackPowerCalcDamage` were read from the x87 instructions (the decompiler hides
  them behind `_ftol2_sse`); operand order is certain, but `roe_DefendPower`'s own formula is Z03 §4.6's.
- `GetLevelCapRate` tables (`LevelGap_Player_to_Monster` / `_Player_to_Player`) and `damagebyangle_*` are Z03's
  combat tables; not re-read here.
- Whether a 0x243C with `IsMissDamage = 1` but a non-zero `damage` can occur: the server never sends one.
- Part 2 / 3 items are listed in `docs/plan/status/Z22.md`.

## 8. Coverage boundary

(Preliminary, completed in the sweep part.)

| Found | Covered by | Argument |
|---|---|---|
| `GuildTournamentSystem::ScanEnemyUser` FUN_0047a3d0 | Z16 (guild tournament system class, via Z09 §31 row "Guild tournament") | GT state logic; the actor only triggers it |
| `ShinePlayer::sp_SkinPolymorph` FUN_004a3280, `ase_AttachObject` FUN_00401d40 | Z18 (Z09 §31.2 rows owned by Z03, `docs/knowledge/Z09.md` §3) | listed there as Z03 leftovers |
| set-item effect slots (`aeo_FillSetItemEffect`, `aeo_SetItemEffectStore`, `setitemskilleffect`) | Z21 (plan: "set-item abstates and skill effects") | the actors only read the stored rates |
| `so_Heal` / `so_recoversp`, `so_DamagedBy` / `so_KilledBy`, `roe_DefendPower`, level-gap and angle tables | Z03 §4, §7 (done) / Z09 §17.3 | combat core, already documented |
| `so_smo_LastDamageOperation` FUN_0040cbe0 and the damage hooks | this item, part 2 | hook actors |
