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

Sections: §1–§12 (framework, base actor, damage over time, area damage, heal over time, detach actions and the
removers dispel / cure / steal / map refusal, rate actors, damage / skill / death hooks, the skill enchant, element
classes). Facts other items need: `docs/knowledge/Z22.md`.

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
| 0x00 | `sasa_IndexString` | "Actor" @ FUN_004015e0 | every class: its own name (FUN_00401620, FUN_00401630, FUN_00401640, FUN_00401650, FUN_00401660, FUN_00401670, FUN_00401680, FUN_00401690, FUN_004016a0, FUN_004016b0, FUN_004016c0, FUN_004016d0, FUN_004016e0, FUN_00401700, FUN_00401710, FUN_00401720, FUN_00401730, FUN_00401740, FUN_00401750, FUN_00401760, FUN_00401770, FUN_00401780, FUN_00401790, FUN_004017a0, FUN_004017c0, FUN_004017d0, FUN_004017e0, FUN_004017f0, FUN_00401800) | logging |
| 0x04 | `sasa_AttachObject(e, o)` | §2.1 @ FUN_0040bbd0 | Dispel 0040ca20 (§7.4), Captivate 0040d3f0 (Z03 §6.6) | `ase_AttachObject` (§1.3) |
| 0x08 | `sasa_DetachObject(e, o)` | §2.2 @ FUN_0040bc60 | DetachProcess 0040c1c0, Bomb 0040c520, ExpUpRate 00408f90, DropUpRate 00409230 (§7), Captivate 0040d460 | `ase_DetachObject` (§1.3) |
| 0x0c | `sasa_Routine(e, bearer, index) → bool` | §2.3 @ FUN_00406d50 | Poison 0040d4c0, Disease 0040b8a0, AreaDamage 0040d640, DmgState 0040dc60, HPHeal 00406e90, SPHeal 00407030, HPSPHeal 00407120, MagicField 00408d80, Fear 00406e30 | `AbnormalStateTickRoutine::ase_Routine`, `AbnormalStateEachTickRoutine::ase_Routine` (§1.3), base `sasa_DetachObject` (§2.2) |
| 0x10 | `sasa_Act_DamegeAbsorpt(o, e, &dmg)` | no-op FUN_004c2450 | Shield 00407370, ManaShield 00407400 (§9.2) | defender's states in `roe_CalcDamage` FUN_00505c00 and `roe_AttackPowerCalcDamage` FUN_005047d0 (§9.1) |
| 0x14 | `sasa_Act_Killed(p, e)` | no-op FUN_00509900 | PartyRecharge 00407730, SelfRevive 00407910 (§11) | dead player's states in `ShinePlayer::so_KilledBy` FUN_00433be0 (Z03 §7.2) |
| 0x18 | `sasa_Act_CastDelay(e) → int` | 0 FUN_004a9c90 | CastDelay 004072b0 (§10.1) | caster's states in `smo_SkillBash_Casting` FUN_0057bef0 (Z03 §5.4): summed into the cast time |
| 0x1c | `sasa_Act_SkillBlast(e) → SkillBlast` | 0 FUN_004a9c90 | Silence 0063ecc0, Silencetoone 00401d20 (§10.2) | `smo_SkillBlastOption` FUN_0057c750 (maximum over the states) |
| 0x20 | `sasa_Act_CoolTimeIgnore(e) → bool` | 0 FUN_00615e70 | IgnoreCoolTime 00500380 (returns 1, §10.3) | `smo_SkillCooltimeSet` FUN_0057c5b0, `ShinePlayer::sp_ChineCastCut` FUN_00436e80 |
| 0x24 | `sasa_AfterEnchant(o)` | no-op FUN_00549070 | MaxHP 00401990 (§10.6) | `ase_AfterEnchant` (§1.3), only from `asl_AbstateSet` FUN_0040d020 |
| 0x28 | `sasa_Act_DamegeIntercept(e, &dmg)` | no-op FUN_00509900 | RangeIntercept 004074f0 (§9.3) | defender's states in `roe_CalcDamage` when the attack range is > 300 |
| 0x2c | `sasa_Act_LastDamegeInterceptByAtk(e, &dmg)` | no-op FUN_00509900 | LastDmgRatio 00407570, HideDamage 00407570 (same function, §9.4) | attacker's states in `roe_CalcDamage` and `roe_GetAttackPower` FUN_005045e0 |
| 0x30 | `sasa_Act_LastDamegeInterceptByDef(o, e, &dmg)` | no-op FUN_004c2450 | LastDmgRatio_DefSide 00407650, TimeAttack 0040ba30 (§9.4, §9.5) | defender's states in `roe_CalcDamage` and `so_mobile_DamageOverTime` (§3.5) |
| 0x34 | `sasa_ApplyAbstate(e, o) → bool` | 0 FUN_004021b0 | Bomb 0040c640 (§7.2) | `asl_AbstateSet` FUN_0040d020 on the **old** element when a held state is set again (before `aeo_Set`), Bomb's own `sasa_DetachObject` |
| 0x38 | `sasa_Act_UseSPDown(e, sp) → sp` | returns `sp` FUN_004021c0 | UseSPDown 004021d0 (§10.4) | caster's states in `CharaterSkillList::csl_SPCheck` FUN_0055b920 (Z03 §5.3) |
| 0x3c | `sasa_IsTargetable() → bool` | 1 FUN_005af8d0 | CannotTarget 004b8d20 (returns 0, §10.5) | target's states in `sp_NC_BAT_TARGETTING_REQ` FUN_0042ffe0 (Z03 §2.2) |
| 0x40 | `sasa_Act_AttackCount(e)` | no-op FUN_00549070 | HideDamage 00408ef0 (§9.4) | attacker's states after each swing in `smo_SwingDamage` FUN_00432f30 (Z03 §4) |
| 0x44 | `sasa_Act_ExpUpRate(e) → u32` | 0 FUN_004a9c90 | ExpUpRate 00402240 (§8) | `ShinePlayer::so_GetExperienceFromMob` FUN_004302a0 (Z03 §8.2) |
| 0x48 | `sasa_Act_DropUpRate(e) → u32` | 0 FUN_004a9c90 | DropUpRate 004022a0 (§8) | killer's states in `dilfs_ItemDrop` FUN_0048ef80 (Z09 §11.2) |
| 0x4c | `sasa_Act_DamageMinusRate(e) → u32` | 0 FUN_004a9c90 | DamageMinus 00402300 (§9.6) | **no caller** (Z22-B11) |
| 0x50 | `sasa_Act_DagamgeMinusByRange(e, def, att, &dmg)` | no-op FUN_00402370 | DamageMinus 004094d0 (§9.6) | defender's states in `roe_CalcDamage` |
| 0x54 | `sasa_Act_AllDamageAbsorb(e, &dmg)` | no-op FUN_00509900 | ShieldHPRate 00402390 (§9.2) | `so_smo_LastDamageOperation` FUN_0040cbe0 (§9.7) |
| 0x58 | `sasa_Act_NormalDamageDown(e, &dmg)` | no-op FUN_00509900 | DamageDownRate 004023d0 (§9.6) | `so_smo_LastDamageOperation` (hits) |
| 0x5c | `sasa_Act_DotDamageDown(e, &dmg)` | no-op FUN_00509900 | DamageDownRate 00402450 (§9.6) | `so_smo_LastDamageOperation` (DoT) |
| 0x60 | `sasa_Act_DelCastTime(e, &t)` | no-op FUN_00509900 | DelCastTime 004024d0 (§10.1) | caster's states in `smo_SkillBash_Casting` |
| 0x64 | `sasa_Act_MinHP(e, &minHP)` | no-op FUN_00509900 | MinHP 004024f0 (§9.7) | `so_smo_LastDamageOperation` |
| 0x68 | `sasa_Act_DagamgeMinusByRangeAtk(e, att, def, &dmg)` | no-op FUN_00402370 | RangeDamageMinusAtk 004095f0 (§9.6) | attacker's states in `roe_CalcDamage` |

Every caller walks the object's whole abstate list (`so_mobile_AbstateList()`, vt 0x52c: `l_MaxSize` u16 +0xcb4,
`l_Array` +0xcb8 of 12-byte nodes `{content, u16 next +4, u8 active +8}`, head `l_Finger.store` +0xcbe) and calls
the slot of each element's actor; the walks of `so_smo_LastDamageOperation` (slots 0x54 / 0x58 / 0x5c) stop early
once the damage is below 1.

The destructor of every class is the shared `~SubAbnormalStateActor` @ FUN_00402380 (no-op).

### 1.3 How an element reaches its actor (the element layer)

Every `ABSTATEINDEX` has one `AbnormalStateElement` object (`abstatetemplate.asl_AbstateList`, built by
`AbnormalStateList::AbnormalStateList` @ FUN_0040f1e0; the subclasses are §12). Its slots dispatch to the actor:

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
ActionEffectAbStateTable::FindActionID(inxName, *actionId) → bool                       @ FUN_005c7f40
    linear scan of ActionEffectAbState.shn { char InxName[32]; u32 Strength; u16 ItemActionID } (0x26, pdb2016):
    first row whose InxName equals (case-sensitive) → *actionId = ItemActionID; the Strength column is not read
    # the 2016 table has 0 rows: no abstate ever adds an item action
AbnormalStateElementRecover::ase_DetachObject(e, o)                                     @ FUN_004084e0
    ase_DetachObject; then o.vt[0xd4c](0) (player: so_SendSpeedInformation)        # only StaCannotControl uses it
ase_AfterEnchant(o)                                                                     @ FUN_00405500
    actor(this.ase_index).sasa_AfterEnchant(o)            # only caller: asl_AbstateSet FUN_0040d020, after the
                                                          #   recalculation that follows setting a state (Z03 §6.2)
```

Consequences for the actors:

- `sasa_Routine` runs **only** for states whose element is an `AbnormalStateTickRoutine` (every `SAA_TICK` ms; 132
  states, all damage / heal / area states) or an `AbnormalStateEachTickRoutine` (every object tick; the 20 fear
  states; class table §12.2). The other element classes (`ElementNormal`, `PartyEnchant`, `RestCount`, `ReinforcedMove`, …) never call
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
         and c.charRegNum == e.aeo_Caster.chrregnum and dist²(c, near) < 6,250,000 (0x5F5E10: 2,500 units):
        return c
    e.aeo_Caster.obj = null; return null                  # mob casters are never "found": their DoT / HoT
                                                          #   is applied with attacker = null (and the pointer is wiped)
aeo_GetCasterLevel / aeo_GetCasterAttackPower  @ FUN_00401260 / FUN_00401270  = e.aeo_Caster.nLevel / .nAttackPower
    (the snapshot aeo_Set takes for SAA_DOTWCRATE / SAA_DOTMARATE rows, Z03 §6.2)
aeo_GetRestCount @ FUN_004011f0 = e.aeo_RestCount;  aeo_GetIndexStrength @ FUN_00401230 = abstateidentarray[index].str
aeo_TickStruct @ FUN_0042ab00 = &e.aeo_Tick  ({start, terminate, Metronome nextaction})
AbstateElementInObject ctor @ FUN_00406550 (per slot of the object's element vector, filled by FUN_00431a30): Metronome
    and aeo_SetItemEffect constructed, aeo_Index = 0x318 (free), aeo_PartyEnchant[0…4].skillindex = null,
    aeo_Caster.nLevel = 0, .nAttackPower = 0; nothing else is cleared (aeo_Set writes the rest)

so_AbnormalState_Set_Simple(o, setter, index, strength, inform) → bool   (vt 0x644)     @ FUN_004163d0
    index ≥ 0x318: assert "as_FromIndex : Invalid skill idx", return 0
    s = dic_abstate.as_StateIndexList[index]; s null or s.subabstate[strength] missing: return 0
    ok = o.so_AbnormalState_Set (vt 0x638)(setter, index, strength, s, g_CurrTick, extraKeep 0, restCount −1, keep 0
                                         (→ row KeepTime + 999), EnchantFrom 0, null)   (Z03 §6.2)
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
        alns_Compare FUN_004c1810) is called only by the bomb (§7.2): elsewhere members come in sight-list order
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
`AbnormalStateReinforcedMove`, §12.7).

### 3.2 Poison actor  @ FUN_0040d4c0 (types 22, 27, 33, 67, 83, 84, 94)

```pseudo
SubAbnormalStateActorPoison::sasa_Routine(e, bearer, index) → bool:
    if e null: return 0                                   # Z22-B1
    if bearer null: return 0
    if bearer has STA_IMMORTAL (291) or STA_ADLFLOUSSIERIMT (499): return 0      # Z22-B1: also blocks the rest
    caster = aeo_FindCasterObject(e, bearer.location)     # a player within 2,500 units, else null (§1.4)
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
    if o.sp_IsEthereal() (vt 0x9e4; mobs 0): return     # no packet, *outDmg untouched
    P = o.so_parameter() (Parameter::Container, smo_Param)
    miss = false
    if P.MissPercentFix (+0xcd0, ‰) ≠ 0:                  # SAA_MISSRATE (GTI states)
        if attacker null:                miss = rand1000 < MissPercentFix
        else if P.RangeOver (+0xda8) ≠ 0 and dist²(o, attacker) > RangeOver²:
                                         miss = rand1000 < MissPercentFix     # SAA_RANGEOVER: only far attackers
    if miss:                                             # sent even when send = 0 (area actors, §4.2)
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
            got = 0; t.so_mobile_DamageOverTime(c, d, index, send = 0, &got)        # §3.5; on a miss it still
                                                          #   broadcasts its own 0x243C miss (Z22-B20)
            records[i] = { object = t.handle, resthp = t.HP (vt 0x4e8, raw), damage = got, hpchangeorder = t.vt[0x7e8]() }
                                                          # written whenever d ≠ 0, also on miss / ethereal (got 0)
    to sight of the caster (so_AllOfRange around c): 0x245A NC_BAT_AREADOTDAMAGE_CMD {
        u16 abstate = e.aeo_Index, u16 Centerobject = c.handle, u8 num, targetinfo target[num] = records[0 … num−1] }
                                                          # 7 + 12·num bytes with the opcode
    return base routine
```

- The damage is centred on the **caster** and credited to the caster (`so_DamagedBy(c, …)`), while the state sits on
  the bearer; for the self-buff kinds (BurnPainFoe: the caster carries the state) both are the same object.
  `TARGETALL` makes it hit players, mobs and servants alike (friend or foe), `TARGETNOTME` additionally spares the
  caster; without them only the caster's enemies are hit. Targets skipped by the 499 / mode 3 / dead / 291 test or
  with `d = 0` get an all-zero record. A target that **misses** (SAA_MISSRATE, §3.5) gets a full record
  `{handle, HP, damage 0, order}` in the 0x245A **and** its own 0x243C with `IsMissDamage = 1`, because the miss
  branch of `so_mobile_DamageOverTime` ignores `send` (original bug) Z22-B20; an ethereal target gets the same
  record without a 0x243C. The record's `resthp` is the raw HP, while the single-target 0x243C sends
  `HP − so_batobj_GetDamage()` (HP minus damage reserved by pending hits), so the two packets can show different HP.
- `num` counts scanned targets, not damaged ones: a target that was skipped or took no damage still occupies a record
  with `object = 0` (original bug) Z22-B2.

`PROTO_NC_BAT_AREADOTDAMAGE_CMD` *(pdb2016)*: `{ u16 abstate, u16 Centerobject, u8 num, targetinfo target[] }`,
`targetinfo = { u16 object, u32 resthp, u32 damage, u16 hpchangeorder }` (12 bytes) — matches the writes above.
Client `FUN_004b62f0`: looks up `Centerobject` (unknown → ignored); with `num == 0` it only plays the abstate's area
effect on the centre (attachment point "Ground" / "HairLink" / "Chest" from the effect table); otherwise it plays the
centre effect, then per record: unknown `object` (also 0) skipped; damage number when `damage > 0` and the abstate is
not 14 / 339 / 0x318; `resthp == 0` → death; HP bar from `resthp` / `hpchangeorder`; the abstate's hit effect on the
target. Sender list in `re-data/client-handlers.json`: this routine and the dead DmgState routine FUN_0040dc60 (§4.3).

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
  skill appears at the bearer's feet. It returns 0 in five cases (null element or bearer, missing skill, no free object,
  caster gone, a skill with neither `MAGICFIELD_KEEP` nor `MAGICFIELD_PARTY` (the allocated object is freed)); each
  stops the bearer's abstate walk for the tick (Z22-B1). This answers Z09 §12.8's open point "which SubAbState kinds use
  the magic-field actor".
- **Fear** (type 28) `sasa_Routine` @ FUN_00406e30: sets `smo_Flag.InFear` (Z03 §6.6, bit 2); runs every object tick
  (EachTickRoutine).

## 7. Detach actions: bomb, detach process, exp / drop chains, dispel

### 7.1 Removal flags and the friend scans

Four detach overrides skip their effect when the element was removed "abnormally". The flags are the bit field
`aeo_Flag` (+0x00) of the element *(pdb2016)*; `aeo_Set` clears all three, and they are set only here:

| Flag | Bit | Set by (then `aeo_Tick.terminate = now`, so the state expires on the next routine walk) |
|---|---|---|
| `f_Cured` | 0 | `ShineMobileObject::so_SkillCure` @ FUN_0042c440: states with `DispelIndex` DA_DISEASE / DA_POISON and `StateGrade` ≤ the cure grade (behind a `rand(1000) < 1001` test that always passes) |
| `f_Dispeled` | 1 | `ShineMobileObject::so_Dispel` @ FUN_0042bf70: skills with `sdi_BOMBDISPELALL` (every matching state) and the one state picked by `sdi_DISPELRANDOM`; `sdi_DISPELONE` / `sdi_DISPELALL` end states **without** the flag |
| `f_SystemRemove` | 2 | `ShinePlayer::sp_RemoveField` @ FUN_00440b40: states the destination map refuses (`FieldMap::fm_IsRefuseAbstate`) |

So a bomb or a detach-process state still fires when a plain dispel (DISPELONE / DISPELALL) removes it; only a
"bomb dispel", a cure of a poison / disease, or a map change that refuses the state defuses it. Expiry and every
other removal path (Z03 §6.4) fire it *(inferred: no other writer of the flags exists)*.

```pseudo
AxialListNearScanFriend(center)                     ctor @ FUN_00402080
    alns_ValidObject(o) = center and o and center.so_IsAlliance(o) (vt 0xe60)           @ FUN_004020c0
AxialListNearScanCenterFriendCasterEnemy(center, caster)   ctor @ FUN_00402100
    alns_ValidObject(o):                                                                @ FUN_00402140
        center and o, and not center.so_mobile_ICanDamageTo(o) (vt 0x980)   # o is on the bearer's side
        and caster.so_mobile_ICanDamageTo(o) and caster.so_mobile_IsEnemy(o) (vt 0x72c) # and the caster's enemy
        # caster is dereferenced unchecked; the bomb only builds this scan when the caster is valid
```

Both also apply the base filter of `AxialListNearScan::ali_Work` (§1.4: modes 0 / 3 out, at most 200, no
291 / 499 holders).

### 7.2 Bomb actor (type 97)  @ FUN_0040c520 / FUN_0040c640

Data: one kind, SubStaBombShot (AbState 8963 StaBombShot, index 464), strengths 1–6 all equal: KeepTime 5000,
`SAA_SETABSTATEFRIEND` 8963 (itself), `SAA_AREA` 300, `SAA_TARGETNUMVER` 10, `SAA_DOTWCRATE` 4000.

```pseudo
SubAbnormalStateActorBomb::sasa_DetachObject(e, o):                                     @ FUN_0040c520
    e null or e.f_Cured / f_Dispeled / f_SystemRemove: return          # defused (§7.1)
    if o and o.smo_GetMode() ≠ 3 (dead) and o has neither STA_IMMORTAL (291) nor STA_ADLFLOUSSIERIMT (499)
         and this.sasa_ApplyAbstate(e, o) (slot 0x34):
        SubAbnormalStateActor::sasa_DetachObject(e, o)                 # §2.2 (RELESEACTION / METASKIN)

SubAbnormalStateActorBomb::sasa_ApplyAbstate(e, o) → bool:                              @ FUN_0040c640
    e or o null, o dead (mode 3), o has 291 or 499: return 0
    dmg = 0
    if row.Has(SAA_DOTWCRATE):
        ctx = EngageArgument(att = null, def = o, skill none, attackloc = o.location); ctx.level = e.aeo_Caster.nLevel
        dmg = roe_normalPY.roe_AttackPowerCalcDamage(ctx, e.aeo_Caster.nAttackPower × Arg(SAA_DOTWCRATE) / 1000,
                                                     e.aeo_Caster.nLevel)          # §3.3 (shields absorb, slot 0x10)
    if row.Has(SAA_DOTMARATE): dmg += the same with roe_normalMA and SAA_DOTMARATE
        # (the decompiler shows the EngageArgument destructor as the folded name so_Gamble_ChangeCoin)
    caster = aeo_GetCaster(e)                    # §1.4: any object type, no distance limit (unlike DoT's FindCaster)
    if dmg ≠ 0: o.so_mobile_DamageOverTime (vt 0x730)(caster, dmg, 0x318, send = 1, null)
                                                 # 0x243C to o's sight with abstate 0xFFFF (§3.5); can kill o
    if caster and not caster.so_IsEmpty() (vt 0x300) and o.smo_GetMode() == 3:     # the explosion killed o:
        n = Arg(SAA_TARGETNUMVER); r = Arg(SAA_AREA) / 2                             #   chain to its neighbours
        if row.Has(SAA_SETABSTATE):
            scan = AxialListNearScanEnemyorAll(o, isAllTarget = 1, isNotMe = 0)      # §1.4
            so_AllOfRange_Simple(o, scan, r); alns_Sort(scan)                        # nearest first
            sasa_SetAbstateToArea_TargetNum(e, caster, scan, SAA_SETABSTATE, n, reapply = 0)       # §2.4
        if row.Has(SAA_SETABSTATEFRIEND):
            scan = AxialListNearScanCenterFriendCasterEnemy(o, caster)               # §7.1: o's friends, caster's enemies
            so_AllOfRange_Simple(o, scan, r); alns_Sort(scan)
            sasa_SetAbstateToArea_TargetNum(e, caster, scan, SAA_SETABSTATEFRIEND, n, reapply = 0)
    return 1
```

So a bomb set on a mob explodes when its 5 s run out, for `(level + 1) × 4 × AP / defence`-style damage (§3.3), and
if that kills the mob, up to 10 of its allies within 150 units that do not already carry the bomb get a new one with the
same caster, nearest first. `sasa_SetAbstateToArea_TargetNum` copies the caster snapshot (`nLevel`, `nAttackPower`)
because the row has `SAA_DOTWCRATE`, so the chain keeps the original caster's attack power. The new bombs are set
with `so_AbnormalState_Set_Simple` (no resist roll; 0x2427 / 0x2429 / 0x1C18 broadcasts, §1.4). The bomb's damage
formula itself (defence term) is Z12-B7.

Setting the bomb again on a holder (e.g. a second cast) makes `asl_AbstateSet` call slot 0x34 on the old element
first: the old bomb explodes at once (damage, and the chain if that kills), then `aeo_Set` starts a new 5 s bomb.
Z03 §6.2 calls this call "detach the old strength first"; it is the actor's `sasa_ApplyAbstate`, a no-op (returns 0)
for every other class. The chain itself never refreshes (`reapply = 0` skips holders).

### 7.3 Detach process, exp-up and drop-up detach  @ FUN_0040c1c0 / FUN_00408f90 / FUN_00409230

The three detach overrides share one body; DetachProcess adds a damage step and the base detach:

```pseudo
sasa_DetachObject(e, o):                         # DetachProcess FUN_0040c1c0, ExpUpRate FUN_00408f90, DropUpRate FUN_00409230
    e or o null, or e.f_Cured / f_Dispeled / f_SystemRemove: return    # §7.1
    if row.Has(SAA_SETABSTATEME):
        s = AbState[Arg(SAA_SETABSTATEME)] (as_FromID; unknown ID → nothing)
        o.so_AbnormalState_Set_Simple (vt 0x644)(setter = o, s.AbStataIndex, strength 1, inform 1)   # §1.4
    if row.Has(SAA_SETABSTATE):
        scan = AxialListNearScanEnemyorAll(o, isAllTarget = 1, isNotMe = 0)          # every player / mob / servant
        so_AllOfRange_Simple(o, scan, Arg(SAA_AREA))                                 #   in range, incl. o, friend or foe
        sasa_SetAbstateToArea(e, setter = o, scan, SAA_SETABSTATE)                   # §2.4: strength 1, holders skipped
    if row.Has(SAA_SETABSTATEFRIEND):
        scan = AxialListNearScanFriend(o)                                            # o's allies (so_IsAlliance)
        so_AllOfRange(o, sight, o.location, Arg(SAA_AREA), no sector, scan, includeSelf = 0, 0xffff)
        sasa_SetAbstateToArea(e, setter = o, scan, SAA_SETABSTATEFRIEND)
    # DetachProcess only:
    dmg = 0
    if v = (u16) Arg(SAA_MAXHPRATEDAMAGE): dmg = o.MaxHP (vt 0x4f0) × v / 1000
    if v = Arg(SAA_HPRATEDAMAGE):          dmg += o.HP (vt 0x4e8) × v / 1000
    if dmg ≠ 0: o.so_mobile_DamageOverTime(attacker = null, dmg, 0x318, send = 1, null)   # 0x243C, abstate 0xFFFF
    SubAbnormalStateActor::sasa_DetachObject(e, o)                                   # §2.2
    # ExpUpRate / DropUpRate do not call the base detach: a METASKIN or RELESEACTION action on their rows would
    #   have no end effect (no 2016 row has one)
```

The setter of every chained state is the bearer itself. `includeSelf = 0` (the flag meaning is from
`docs/knowledge/Z09.md`, range queries) keeps the bearer out of the friend scan; the all-target scan includes it.

Data (2016 `SubAbState.shn`, SubState 78 DETACHPROCESS, 8 kinds / 17 rows):

| Kind | Rows | At the end |
|---|---|---|
| SubStaCrackerDisease (AbState 8907) | 1, KeepTime 4000 | itself to allies within 500 (`SETABSTATEFRIEND` 8907, `AREA` 500) and StaCrackerCurse (8908) on the bearer |
| SubStaSalare04 | 1, 15000 | `WCRATE` 1000 / `HEALRATE` 2000 while active; 90 % of max HP as damage at the end (`MAXHPRATEDAMAGE` 900) |
| SubStaBallSnow | 10 (speed-down 10…95 %, 10 s; strength 10: 50 ms) | strength 10 turns the bearer into StaSnowMan (9057) |
| SubStaE_UserComeback_Main01…05 | 1 each (10 min … 2 h; Strength column 999 / 999 / 999 / 999 / 999) | the next `StaE_UserComeback_Main0n` (9272 … 9275), Main05 → Main01 (9271): an endless loop *(data)* |

ExpUpRate (109) rows with `SETABSTATEME`: SubStaE_UserNewbie01…05 (exp +3 / 5 / 7 / 10 / 15 %, 10 min … 2 h), each
chaining to the next and 05 back to 01 (9266): also a loop. No DropUpRate (110) row chains.

### 7.4 Dispel actor (type 113)  @ FUN_0040ca20

```pseudo
SubAbnormalStateActorDispel::sasa_AttachObject(e, o):           # replaces the base attach (no METASKIN handling)
    e or o null, or o has no abstate list (vt 0x52c): return
    p = row.Has(SAA_POISONRESISTRATE); d = row.Has(SAA_DISEASERESISTRATE)
    c = row.Has(SAA_CURSERESISTRATE);  m = row.Has(SAA_SPEEDRESISTRATE)
    for each element x of o (next node read before x is removed):
        x.aeo_Index ≥ 0x318: assert "as_FromIndex : Invalid skill idx", continue
        info = AbState of x
        if (p and info.DispelIndex == DA_POISON) or (d and DA_DISEASE) or (c and DA_CURSE)
           or (m and info.SubDispelIndex == SDA_MOVESPEED):
            o.so_AbnormalState_Reset (vt 0x650)(info.AbStataIndex)          # detach hooks run (no f_ flag set)
            so_AbnormalState_BitReset(o, index); so_AbnormalState_BroadcastReset(o, index)   # 0x2428 (Z03 §6.3)
```

The only 2016 kind is SubStaKQSpImBuff (`SAA_SPEEDRESISTRATE` 1000): when it lands, every movement-speed debuff on
the bearer ends at once. The resist values themselves are matrix stats (Z12 §2.5); the actor only uses the presence
of the action.

### 7.5 The removers: dispel, cure, steal and map refusal  @ FUN_0057d8e0, FUN_0042c440, FUN_0042bf70, FUN_00440b40

These are the only writers of the §7.1 flags. They walk the bearer's element list `so_mobile_AbstateList` (vt 0x52c)
+0xcb0, a `List<AbstateElementInObject>`. Every zone `List<T>` has the layout built by `l_MakeList` (example
`List<AbnormalStateNode>::l_MakeList` @ FUN_0040e0d0): +4 `u16 l_MaxSize`, +8 `l_Array` of `MaxSize + 1` 12-byte
`ListStruct { T *ls_Content; u16 ls_Next; u16 ls_Prev; u8 ls_IsActiv }`, the sentinel at index `MaxSize`
(`l_Finger.store`, +0xe), free nodes chained from `l_Finger.empty`. "For each element" = from `sentinel.ls_Next`
while the index is `< MaxSize`; "from the newest" = from `sentinel.ls_Prev` backwards.

```pseudo
ShineMobileObject::smo_Dispel(c, s, empower, t, bo)                                     @ FUN_0057d8e0
    # called by smo_SkillBlast FUN_00581160 for every target hit (Z03 §5.6 step D); twice on one path (§10.7, Z22-B16)
    if s.sdi_Activ.EffectType ∉ { SE_DISPEL 9, SE_CURE 8 }: return
    smash = SmashArgument { sklidx = s, empower = *empower }
    if not c.so_mobile_IsEnemy (vt 0x72c)(t):          # friend: remove its bad states
        if EffectType == SE_CURE: mask = 0x18                                       # DA_DISEASE | DA_POISON
        else: mask = DISPELDEBUFF ? 0x04 : 0 | DISPELDISEASE ? 0x08 | DISPELPOISON ? 0x10 | DISPELCURSE ? 0x20
                     | BOMBDISPELALL ? 0x400                                        # bit = 1 << DispelAttr
    elif not s.sdi_DISPELDEEPER: mask = s.sdi_DETECT ? 0x200 (DA_HIDE) : 0x02 (DA_GOOD)   # enemy: strip buffs / reveal
    else: mask = 0x100 (DA_DEEPER) if t carries a STA_DEEPER element set by c (aeo_IsMine(x, c, STA_DEEPER)), else 0
        # aeo_IsMine(x, c, idx) @ FUN_00408880: x.aeo_Index == idx, x.aeo_Caster.obj and c non-null, same object
        #   handle (+4), and c.so_GetCharRegistNumber (vt 0x344) == x.aeo_Caster.chrregnum
    c.so_SkillCure (vt 0x5a4)(t, &smash, bo)
    c.so_Dispel    (vt 0x5a8)(t, &smash, bo, mask)
    skillresultbuffer[bufferpoint] .target = t, .isenchant = 1, .isresist = 0       # both return values are ignored

ShineMobileObject::so_SkillCure(c, t, smash, bo) → bool                                 @ FUN_0042c440
    if t null, t dead (smo_GetMode 3) or the skill has no sdi_CURE: return 0
    grade = s.sdi_CURE.value
    for each element x of t:
        if rand(1000) < 1001:                          # always true (original bug) Z22-B17
            info = AbState of x  (index ≥ 0x318: assert "as_FromIndex : Invalid skill idx")
            if info.DispelIndex ∈ { DA_DISEASE, DA_POISON } and info.StateGrade ≤ grade:
                x.aeo_Flag |= f_Cured; x.aeo_Tick.terminate = now; return 1          # only the oldest match
    return 0

ShineMobileObject::so_Dispel(c, t, smash, bo, mask) → bool                              @ FUN_0042bf70
    if t null or dead: return 0
    if t.so_MiscTable (vt 0x984).mds_Dead.ByDebuff (+0x58 bit 0) and mask & 0x02:   # servant row Debuff = Dead (Z09 §10)
        t.so_DamagedBy (vt 0x5c0)(t, t.so_GetHP (vt 0x4e8)(), aggro 1000, 1); return 1   # the attacker is t itself
        # (disassembly 0x42c00e–0x42c02b: push 1; push 0x3e8; call [vt+0x4e8]; push eax; push t; call [vt+0x5c0]).
        # ShineMob::so_DamagedBy FUN_00431750 (servants use it too) only does sm_HP −= dmg (→ 0) plus aggro / Lua /
        # hit-list work; it neither calls so_KilledBy nor the dead check (see §13)
    result = 0; picks = 1; chosen = null
    # pass 1: dispel, oldest first
    for each element x of t (next index read before x):
        if rand(1000) < 1001 and mask & (1 << AbState(x).DispelIndex):               # rand test always true (Z22-B17)
            if s.sdi_DISPELONE:   x.terminate = now; return 1                          # first match only; no flag,
                                                                                       #   no steal, no random pick
            elif s.sdi_DISPELALL: x.terminate = now; result = 1                        # no flag
            else:
                if s.sdi_DISPELRANDOM:                                                 # reservoir sample, uniform
                    if picks == 1 or RandomBox[picks] == 0: chosen = x
                    picks += 1
                if s.sdi_BOMBDISPELALL: x.aeo_Flag |= f_Dispeled; x.terminate = now; result = 1
    # pass 2: steal, newest first (only reached without DISPELONE)
    for each element x of t from the newest:
        if mask & (1 << AbState(x).DispelIndex) and s.sdi_STEALENCHANT:
            if x's element class is a party main (element vt 0x0c, §12.1): continue
            if rand(1000) < s.sdi_STEALENCHANT.value:
                x.terminate = now                                                       # no flag: its detach runs
                if c.so_AbnormalState_Set (vt 0x638)(c, x.aeo_Index, x.aeo_Strength, entry, setTime = x.aeo_Tick.start,
                                                     0, restCount = x.aeo_RestCount, keep 0,
                                                     EF_JUSTENCHANTSTEALENCHANT 6, null):
                    so_AbnormalState_BitSet(c, AbStataIndex)
                    if row info: c.so_AbnormalState_Inform (vt 0x3f0)(index, KeepTime, 1)     # 0x2429 to c
                                 so_AbnormalState_BroadcastSet(c, index, KeepTime, strength)  # 0x2427 / 0x1C18
                result = 1
            break                                       # only the newest eligible state gets a steal roll
    if picks > 1: chosen.aeo_Flag |= f_Dispeled; chosen.terminate = now              # DISPELRANDOM's pick
    return result          # 0 for a DISPELRANDOM-only dispel that removed a state (original bug) Z22-B18
```

Notes:

- Removal is deferred: `terminate = now` makes the state expire on the bearer's next routine walk (Z03 §6.4), which
  sends 0x2428 and runs the detach hooks (§7.1: only the flagged removals defuse bombs / detach processes).
- The stolen copy is set with the victim's **start** tick and keep 0, so `aeo_Set` FUN_0040a340 ends it at
  `start + ticks(KeepTime + 999) × SET_ABSTATEKEEPTIMERATE / 1000`: the victim's original row time, without the
  victim's extensions; a state set long ago is stolen already expired. The thief's client is told the full
  `KeepTime` from now (original bug) Z22-B19.
- Masks are `1 << DispelAttr` (`DA_GOOD 1, DEBUFF 2, DISEASE 3, POISON 4, CURSE 5, …, DEEPER 8, HIDE 9, BOMB 10`).
  The friendly `BOMBDISPELALL` sets bit 10 (DA_BOMB), so a bomb dispel removes bombs (and the debuff kinds also
  selected) with `f_Dispeled`: the bomb is defused (§7.2).

```pseudo
ShinePlayer::sp_RemoveField(p)                                                          @ FUN_00440b40
    # called once from the map-login completion (Z01 §6, 0x1803 login burst: "… sp_RemoveField")
    f = p.field (+0x7a FieldMap*);  if f null or no abstate list: return
    for each element x of p:
        if abstateidentarray[x.aeo_Index].entry and f.fm_IsRefuseAbstate(entry.index.AbStataIndex):
            x.aeo_Flag |= f_SystemRemove; x.terminate = now          # expires on the next walk, defused (§7.1)

FieldMap::fm_IsRefuseAbstate(f, index) → bool = index ∈ f.fm_RefuseAbstate (std::set)            @ FUN_00464540
    # other caller: ShineMobileObject::so_AbnormalState_Set FUN_004161c0 returns 0 for such a state on the object's
    #   current map (so_CurMapname = &field.fm_MapID, offset 0) before asl_AbstateSet; Z03 §6.2 omits this step

FieldContainer::fc_AbstateInFieldLoad()                                                 @ FUN_00464950
    rows = StateField.shn { char AbStateInx[32]; Name3 MapName; StateSetType StateSet }   (0x30 bytes, pdb2016)
    for each field map m, for each row r:
        idx = dic_abstate.as_BTreeIndex[r.AbStateInx]
        SST_SET_HERE 1: if m.name ≠ r.MapName: m.fm_SetRefuseAbstate(idx)   (FUN_00464480)   # only allowed on MapName
        SST_NOT_HERE 0: if m.name == r.MapName: m.fm_SetRefuseAbstate(idx)                   # forbidden on MapName
```

2016 `StateField.shn` has 6 rows: StaCrackerACDownRate / WCDownRate / Disease / Curse only on `B_Cracker`, StaHide
forbidden on `BH_Helga` and `BH_Cracker`. So a player who leaves the Cracker map with a Cracker debuff loses it (without
its detach effect) when the next map's login completes, and an existing StaHide ends on entering those two maps.

## 8. Exp and drop rate actors (types 109, 110)

```pseudo
SubAbnormalStateActorExpUpRate::sasa_Act_ExpUpRate(e)   = row.Arg(SAA_EXPRATE)  (0 without)      @ FUN_00402240
SubAbnormalStateActorDropUpRate::sasa_Act_DropUpRate(e) = row.Arg(SAA_DROPRATE) (0 without)      @ FUN_004022a0
```

- Exp: `ShinePlayer::so_GetExperienceFromMob` FUN_004302a0 (formula in Z03 §8.2) multiplies the exp (double) by
  `(rate + 1000) / 1000` **per state** (read from the x87 code: `fild (vt 0x44 result + 1000)`, `/1000.0`, `fmul`),
  so two exp states multiply. The sum is formed in 32 bits and loaded as unsigned (2^32 is added when the sign bit is set).
  Final exp < 1 becomes 1.
- Drop: `dilfs_ItemDrop` FUN_0048ef80 adds the rates of all the killer's states into `rr_ByAbstate`, a ‰ term added
  to the map rate and the charged-item bonus before scaling `DrItemR` (Z09 §11.2).
- 2016 data: 109 EXPUPRATE 12 kinds, `SAA_EXPRATE` 30…200 (+3…+20 %; the newbie chain of §7.3 and quest / event
  rewards); 110 DROPUPRATE 13 kinds, `SAA_DROPRATE` 20…1000 (SubStaQDayDropUp, SubStaKQEggReward, puzzle rewards …).
  Some carry stat actions as well (matrix, Z12 §2.5).

## 9. Damage hooks

### 9.1 Where they run

```pseudo
RulesOfEngagement::roe_CalcDamage(ctx) → dmg   (hits and skills, Z03 §4.5)                @ FUN_00505c00
    … base damage, angle, charged-item rates, roe_LevelGapDamageRevision; dmg = max(dmg, 1)
    range = ctx.skill ? skill.Range : att.vt[0x510](def) (attack range)
    if range > 300: for x in def's states: slot 0x28 DamegeIntercept(x, &dmg)          # RangeIntercept (§9.3)
    for x in def's states: slot 0x10 DamegeAbsorpt(def, x, &dmg)                       # Shield, ManaShield (§9.2)
    for x in att's states: slot 0x2c LastDamegeInterceptByAtk(x, &dmg)                 # LastDmgRatio, HideDamage (§9.4)
    for x in def's states: slot 0x30 LastDamegeInterceptByDef(def, x, &dmg)            # DefSide, TimeAttack (§9.4, 9.5)
    for x in def's states: slot 0x50 DagamgeMinusByRange(x, def, att, &dmg)            # DamageMinus (§9.6)
    for x in att's states: slot 0x68 DagamgeMinusByRangeAtk(x, att, def, &dmg)         # RangeDamageMinusAtk (§9.6)
    return dmg                                   # no lower clamp after the hooks: 0 is possible
roe_AttackPowerCalcDamage (DoT / bomb, §3.3): slot 0x10 only.
roe_GetAttackPower(ctx) (the DoT caster snapshot of aeo_Set, Z03 §6.2)                     @ FUN_005045e0
    ap = the rule set's attack power (vt 8, free-stat vt 0x30, charged items; Z12 §4.1);  then for x in att's states:
        slot 0x2c(x, &ap)
so_mobile_DamageOverTime (§3.5): slot 0x30 on the bearer, then vt 0xdb4.
vt 0xdb4 so_smo_LastDamageOperation (§9.7), the last step of every damage path: so_attack FUN_0042cb80, so_smash
    FUN_0042c650, so_skillsmash FUN_0042ba90, smo_SwingDamage FUN_00432f30, SkillDamageSender::sds_TemplateStore
    FUN_005803c0 (isDot 0), RecoverTypeEffect::_execute FUN_005cfc70 (isDot 0), so_mobile_DamageOverTime (isDot 1).
```

Order matters: a shield (0x10) absorbs the damage before the attacker's damage ratio (0x2c) and the defender's
reductions (0x30 / 0x50 / 0x68) are applied, and `ShieldHPRate` / the damage-down rates / min HP (vt 0xdb4) come last.

### 9.2 Shields  @ FUN_00407370, FUN_00407400, FUN_00402390

`aeo_RestCount` holds the remaining shield points; it is filled by the element's `ase_MaxRestCount` when the state
is set (`aeo_Set`, element vt 0x28: `AbnormalStateRestCount` = the row's value of its action, e.g. `SAA_SHIELDAMOUNT`;
`AbnormalStateRestCountHPRate` = bearer MaxHP × the value / 1000; §12.3).

```pseudo
SubAbnormalStateActorShield::sasa_Act_DamegeAbsorpt(o, e, &dmg):                       @ FUN_00407370
    if dmg < e.aeo_RestCount: e.aeo_RestCount −= dmg; dmg = 0
    else: dmg −= e.aeo_RestCount; e.aeo_RestCount = 0; e.aeo_Tick.terminate = now        # used up: expires at the next walk
SubAbnormalStateActorManaShield::sasa_Act_DamegeAbsorpt(o, e, &dmg):                   @ FUN_00407400
    sp = o.so_GetSP() (vt 0x4ec)
    if dmg < sp: o.so_LostSP (vt 0x4f8)(dmg); dmg = 0
    else: dmg −= sp; o.so_LostSP(sp); e.aeo_Tick.terminate = now                         # SP pays 1:1
SubAbnormalStateActorShieldHPRate::sasa_Act_AllDamageAbsorb(e, &dmg):  (vt 0xdb4 path)  @ FUN_00402390
    same as Shield (RestCount; ends when used up)
```

Data: 16 DAMAGESHIELD 4 kinds / 21 rows (`SAA_SHIELDAMOUNT` 1040…3547; SubStaDivineShield / SubStaNeglect use
1 000 000 000, practically invulnerable); 92 / 93 UBAUP / UBADOWN (SubStaAdlUBAUP / DOWN: 60000 points + `SAA_NOMOVE` +
`SAA_NOATTACK`); 17 MANASHIELD SubStaRingShield (no actions); 115 DMGSHIELDRATE SubStaLightTouch (`SAA_SHIELDRATE`
250…400 ‰ of max HP). Shield and ManaShield work on hits and DoT (`roe_AttackPowerCalcDamage`), ShieldHPRate on
everything that ends in vt 0xdb4.

### 9.3 Range intercept (type 59)  @ FUN_004074f0

```pseudo
SubAbnormalStateActorRangeIntercept::sasa_Act_DamegeIntercept(e, &dmg):     (ranged attacks only, range > 300)
    if e.aeo_RestCount < 1: e.aeo_Tick.terminate = now                 # count used up: this hit passes, state ends
    else: e.aeo_RestCount −= 1; dmg = 0                                # blocked
```

SubStaBuckler (`SAA_COUNT` 2, 60 s): blocks two ranged hits completely; the state stays (and shows) after the second
block and only ends on the third ranged hit, which goes through (original bug) Z22-B8.

### 9.4 Damage ratios and hide damage  @ FUN_00407570, FUN_00407650, FUN_00408ef0

```pseudo
LastDmgRatio::sasa_Act_LastDamegeInterceptByAtk(e, &dmg)       dmg = dmg × row.Arg(SAA_TOTALDAMAGERATE) / 1000   @ FUN_00407570
LastDmgRatio_DefSide::sasa_Act_LastDamegeInterceptByDef(o, e, &dmg)  the same formula on the defender           @ FUN_00407650
SubAbnormalStateActorHideDamage::sasa_Act_AttackCount(e):       (after each smo_SwingDamage of the bearer)       @ FUN_00408ef0
    e null: return
    if e.aeo_RestCount < 1 or --e.aeo_RestCount < 1: e.aeo_Tick.terminate = now
```

- 75 (`ac_TOTALDAMAGERATE`): SubStaAngry / SubStaAiriBuff / SubStaWarNSetBuff (`SAA_TOTALDAMAGERATE` 1025 / 1050 /
  2000): the bearer's hits, skills **and** DoT snapshots (`roe_GetAttackPower`) are scaled.
- 76 (`ac_TOTALDAMAGERATE_BYDEF`): the only kind, SubStaSpirit (5 s), has **no** actions, so the rate is 0 and every
  hit and DoT tick on the bearer becomes 0 (the 2017 enum name DAMAGENEGLECT matches this use). The client still
  gets a 0x243C / damage packet with damage 0.
- 106 HIDEDAMAGE: SubStaHideWC (`SAA_TOTALDAMAGERATE` 2000, `SAA_MONSTERSTICK` 1): double damage on the bearer's
  hits and skills (slot 0x2c is the LastDmgRatio function); the state ends after `aeo_RestCount` normal swings
  (`smo_SwingDamage` is the only caller of slot 0x40; skills do not count). Its RestCount comes from the element
  (§12.3: `SAA_MONSTERSTICK` 1).

### 9.5 Time attack (type 77)  @ FUN_0040ba30

```pseudo
SubAbnormalStateActerTimeAttack::sasa_Act_LastDamegeInterceptByDef(o, e, &dmg):   (bearer is hit; dmg unchanged)
    if e.aeo_Strength ≥ 2: return                                       # only the first hit
    rate = row(strength 2).Arg(SAA_DISPELSPEEDRATE) or 1000 when 0      # always reads the strength-2 row (+0x54)
    rest = aeo_GetRestTime(e)                                           # FUN_00408990: ceil(ticks left / 10) × 1000 ms
    aeo_Set(e, caster = e.aeo_Caster.obj, e.aeo_Index, strength 2, now, AbState of e, o, 0, e.aeo_RestCount,
            keepMs = (rest / rate) × 1000, EF_JUSTENCHANTPINESCRIPT, null)       # Z03 §6.2
    set bit e.aeo_Index in o.so_Getabstatebit() (vt 0x4a0)
    so_AbnormalState_BroadcastSet(o, index, rest, strength 2)           # 0x2427 / 0x2429 / 0x1C18 (Z03 §6.3)
    o.so_AbnormalState_Inform (vt 0x3f0)(index, rest, 0)
```

SubStaTimeAttack: strength 1 = 180 s of `SAA_NOMOVE` + `SAA_NOATTACK` with `DISPELSPEEDRATE` 1000; strength 2 the same
with 50000. The first hit therefore cuts the remaining time to `rest / 50` (integer seconds: 180 s → 3 s). The
switch bypasses `asl_AbstateSet` (no detach / attach hooks, no recalculation; both strengths have the same actions).

- `rest / 50000` is integer division: with less than 50 s left the new keep time is 0, which `aeo_Set` treats as
  "use the row's KeepTime", so the state restarts with the full 180 s (original bug) Z22-B6.
- The broadcast and the inform send `rest` (the old remaining time), not the new keep time, so the client shows
  the old timer until the state ends early (original bug) Z22-B7.

### 9.6 Damage reductions  @ FUN_004023d0, FUN_00402450, FUN_004094d0, FUN_004095f0, FUN_00402300

```pseudo
DamageDownRate::sasa_Act_NormalDamageDown(e, &dmg):   (vt 0xdb4, isDot = 0)                   @ FUN_004023d0
    if row.Has(SAA_DMGDOWNRATE): v = Arg; dmg = v ≥ 1000 ? 0 : dmg − dmg × v / 1000
DamageDownRate::sasa_Act_DotDamageDown(e, &dmg):      (vt 0xdb4, isDot = 1)                   @ FUN_00402450
    the same with SAA_DOTDMGDOWNRATE
SubAbnormalStateDamageMinus::sasa_Act_DagamgeMinusByRange(e, def, att, &dmg):  (on the defender) @ FUN_004094d0
SubAbnormalStateRangeDamageMinusAtk::sasa_Act_DagamgeMinusByRangeAtk(e, att, def, &dmg): (on the attacker) @ FUN_004095f0
    e, def or att null, or no / zero SAA_DMGDOWNRATE: return
    R = (def.so_BodySize() (vt 0x6cc) × 5 + 600) / 4                   # 150 + 1.25 × the defender's body size
    d² = so_DistanceSquar(def, att)
    if row.Has(SAA_RANGE): applies only when d² > R²                    # ranged attacker
    else if row.Has(SAA_MELEE): applies only when d² ≤ R²               # melee attacker
    else: return
    dmg = max(0, dmg − dmg × Arg(SAA_DMGDOWNRATE) / 1000)
SubAbnormalStateDamageMinus::sasa_Act_DamageMinusRate(e) = e ? row.Arg(SAA_DMGDOWNRATE) : 0   @ FUN_00402300
    # slot 0x4c: no caller in the 2016 zone (dead code) (original bug) Z22-B11
```

Data: 116 DMGDOWNRATE SubStaLightMark (10 rows, `DMGDOWNRATE` = `DOTDMGDOWNRATE` = 30…75 ‰): hits and DoT on the
bearer are reduced by 3…7.5 %. 114 RANGEDMGDOWNRATE: SubStaStrongerRangeAttack (`DMGDOWNRATE` 700 + `SAA_RANGE`) /
SubStaStrongerMeleeAttack (700 + `SAA_MELEE`): the bearer takes 70 % less from ranged / melee attackers. 119
RANGEDMGDOWNRATEATK has no 2016 rows (the attacker-side variant is unused).

### 9.7 `so_smo_LastDamageOperation` (vt 0xdb4) and min HP  @ FUN_0040cbe0, FUN_004024f0

```pseudo
ShineMobileObject::so_smo_LastDamageOperation(o, dmg, isDot) → int:
    for x in o's states while dmg ≥ 1: isDot ? slot 0x5c DotDamageDown(x, &dmg) : slot 0x58 NormalDamageDown(x, &dmg)
    for x in o's states: if dmg < 1: return 0; slot 0x54 AllDamageAbsorb(x, &dmg)       # ShieldHPRate
    if dmg < 1: return 0
    minHP = 0; for x in o's states: slot 0x64 MinHP(x, &minHP)
    hp = o.HP (vt 0x4e8)
    if minHP < hp: return min(dmg, hp − minHP)
    return 0                                                          # already at / below the floor: no damage
SubAbnormalStateActorMinHP::sasa_Act_MinHP(e, &minHP):  if row.Has(SAA_MINHP): minHP = max(minHP, Arg)  @ FUN_004024f0
```

117 MINHP: SubStaMinHP and SubStaArenaMinHP (`SAA_MINHP` 1): the bearer cannot drop below 1 HP from anything that
ends in vt 0xdb4 (hits, skills, DoT). `ShineObject`'s own slot is the empty FUN_00631170 (Z09 §31): objects that are
not mobile objects skip all of this.

## 10. Skill, targeting and parameter hooks

### 10.1 Cast time  @ FUN_004072b0, FUN_004024d0

```pseudo
SubAbnormalStateActorCastDelay::sasa_Act_CastDelay(e) = row.Arg(SAA_CASTINGTIMEPLUS)                     @ FUN_004072b0
SubAbnormalStateActorDelCastTime::sasa_Act_DelCastTime(e, &t): t = 0; e.aeo_Tick.terminate = now        @ FUN_004024d0
```

`smo_SkillBash_Casting` FUN_0057bef0 (Z03 §5.4) first adds slot 0x18 of every caster state to the cast time, then
runs slot 0x60 over them: a DelCastTime state makes this one cast instant and is used up. Data: 30 CASTINGTIMEPLUS
SubStaCurseMagicCasTime (+2…4 s); 118 DELCASTING SubStaDelCastTime (no actions).

### 10.2 Silence  @ FUN_0063ecc0, FUN_00401d20

```pseudo
SubAbnormalStateActorSilence::sasa_Act_SkillBlast(e) = SB_SILENCE                                         @ FUN_0063ecc0
SubAbnormalStateActorSilencetoone::sasa_Act_SkillBlast(e): e.aeo_Tick.terminate = now; return SB_SILENCE   @ FUN_00401d20
```

`smo_SkillBlastOption` FUN_0057c750 returns the maximum over the states; `SB_SILENCE` (2) makes the skill checks
refuse with 0xFC7 "Cannot use the skill due to Silence State." (Z03 §5.2) and mobs fall back to weapon 0 (Z09 §7.4). The
one-time variant ends itself at the first query, so one refused (or AI-checked) attempt uses it up. Data: 32
MAGICATTACKNOUSE SubStaReverseOrder / SubStaGTIReverseOrder / SubStaMobSLC01; 88 SubStaVacant.

### 10.3 Ignore cooldown (type 31)  @ FUN_00500380, FUN_0057c5b0, FUN_005794d0, FUN_00436e80

```pseudo
SubAbnormalStateActorIgnoreCoolTime::sasa_Act_CoolTimeIgnore(e) = 1     # folded constant function (PDB name at the
                                                                         #   address: CGambleObject::go_Init)
ShineMobileObject::smo_SkillCooltimeSet(o) → bool "set the cooldown":                   @ FUN_0057c5b0
    if o.smo_Flag.InSkillShift: return 0
    o.smo_Flag.ChineCast (bit 6, 0x40) = 0
    for x in o's states: if slot 0x20 CoolTimeIgnore(x):
        o.smo_Flag.ChineCast = 1; o.vt[0xf60]() (player: smo_ChineCastCut); return 0     # no cooldown this time
    return 1
ShinePlayer::smo_ChineCastCut(p): flag |= 0x40; sp_ChineCastCut(p); flag &= ~0x40     @ FUN_005794d0
ShinePlayer::sp_ChineCastCut(p):                                                        @ FUN_00436e80
    if flag & 0x40: flag &= ~0x40; for x in p's states: if slot 0x20(x): x.aeo_Tick.terminate = now
```

So a cooldown-remove state (SubStaCrossCastingCoolTime / SubStaNatureCastingCoolTime / SubStaChainCastingCoolTime /
SubStaBH_Helga_None, no actions) lets exactly one skill of a **player** skip its cooldown and then all such states
end. On mobs and servants vt 0xf60 is the empty base stub FUN_00417480 (RTTI: `ShineMob`, `ShineServant` and
`ShineMobileObject` slot 0xf60; folded, PDB name `so_Gamble_ChangeCoin`), so the states are never used up: every skill
skips its cooldown until the state expires, and `ChineCast` stays set (original bug) Z22-B21. The flag
name `ChineCast` ("chain cast") is the PDB name of Z03 §6.6's bit 6.

### 10.4 SP cost  @ FUN_004021d0

`SubAbnormalStateActorUseSPDown::sasa_Act_UseSPDown(e, sp)` = `sp − Arg(SAA_USESPDOWN) × sp / 1000` (unsigned; `sp`
without the action), applied per state in `csl_SPCheck` FUN_0055b920 (Z03 §5.3). Data: 100 USESPDOWN
SubStaMagicDanceUseSPDown01…05 (25 rows, 60…700 ‰).

### 10.5 Cannot target (type 105)  @ FUN_004b8d20

`SubAbnormalStateCannotTarget::sasa_IsTargetable` returns 0 (folded constant function; PDB name at the address
`SlotMachine::SlotMachineScreen::go_IsFullCheck`). `sp_NC_BAT_TARGETTING_REQ` FUN_0042ffe0 (Z03 §2.2) walks the
target's states and untargets (vt 0x998(0)) at the first that returns 0. Data: SubStaNotTarget,
SubStaKDFargels_DmgNeglect.

### 10.6 Max HP / SP actor (types 24, 25, 39, 40)  @ FUN_00401990

```pseudo
SubAbnormalStateMaxHP::sasa_AfterEnchant(o):            (after asl_AbstateSet set the state and recalculated)
    if o.smo_GetMode() ≠ 0:
        o.so_RecalcAbstateParam() (vt 0x360, FUN_004cbe50)            # the abstate matrix again (Z12 §2.5)
        so_AllOfRange(o, sight, o.location, range 0, no sector, member function so_ply_Send2WhoTargetMe, 0, 0xffff)
            # FUN_00568ee0 per object in sight: obj.so_GetTargetInfo(o) (vt 0x42c): a player whose target (or main
            #   body) is o gets 0x2402 NC_BAT_TARGETINFO_CMD via TargetObject::to_SendInform (Z03 §2.2)
```

So observers' target frames show the new max HP / SP as soon as such a state lands. There is no detach override:
when the state ends nobody targeting the bearer is told (original bug) Z22-B12. The max values themselves come from
the matrix actions (`SAA_MAXHPPLUS` / `MAXSPPLUS` / `MAXHPRATE` / `MAXSPRATE`). Data: 24 MAXHPRATE 9 kinds / 24 rows
(SubStaSafeProtection, set-item states SubStaSetF4HPUp …), 39 MAXHPPLUS 5 HP scrolls, 40 MAXSPPLUS 10 kinds
(SubStaSoulEdge1…5, SP scrolls); 25 MAXSPRATE has no rows.

### 10.7 Skill enchant (vt 0x5a0)  @ FUN_00431ca0

`smo_SkillBlast` FUN_00581160 (Z03 §5.6) applies a skill's four abstate entries in one of two ways. With
`hit.mha_HitStep ≥ 0` (a multi-hit step) it uses the inline loop Z03 §5.6 step E describes. With `mha_HitStep < 0`
(when it is negative was not traced: `AxialListScanSkillTarget::alsst_SkillBlast` FUN_00582de0 overwrites it only for
`SS_DMGSHARE` skills and treats −1 like 0 as "first hit") and a target that is not immune, it calls
the virtual `so_SkillEnchant` (player and mob vt 0x5a0 both = FUN_00431ca0) and sets `r.isenchant` when that returns 1,
`r.isresist |= resisted`. Then it calls `smo_Dispel` (§7.5) **and** runs a second, inline copy of `smo_Dispel`'s body
(checked in the disassembly: `call 0x57d8e0` at 0x58295c, then the inline vt 0x5a4 / 0x5a8 calls at 0x582aeb /
0x582b0c): every cure / dispel / steal of that path runs twice (original bug) Z22-B16. Only the `so_SkillEnchant` call
sits inside `if (!isImmune)`: `smo_Dispel` and its inline copy run whatever the immunity, so a target that resists
the skill's states as immune still loses its buffs to dispel / steal (original bug) Z22-B22. The other caller,
`ShineMobileObject::smo_old_skill_blast` FUN_00579b50 (and its player override FUN_0057be40), sits in vt slot 0xea4,
which nothing calls (no `[reg + 0xea4]` call in the 2016 disassembly): dead code.

```pseudo
ShineMobileObject::so_SkillEnchant(c, t, smash, bo, *resisted, unused) → bool          @ FUN_00431ca0
    if t null or dead: return 0
    s = smash.sklidx;  if s null: assert "…sp_NC_BAT_SKILLENCHANT_REQ : Blast invalid spell", return 0
    *resisted = 0
    if s.sdi_ToggleData not empty:                      # toggle skill (ToggleSkill.shn, Z03 §5)
        if s.sdi_Activ null: return 0
        if not c.so_ply_ToggleSkill_IsOn (vt 0xbc4)(s.ID):          # mobs: stub returning 0 (FUN_00615e70)
            for each of the 4 entries with idx ≠ MAX: if c has idx (asl_Abstate_IsSet):
                c.so_AbnormalState_Reset (vt 0x650)(idx); so_AbnormalState_BitReset(c, idx)
                so_AbnormalState_BroadcastReset(c, idx)                                  # 0x2428 to sight
            return 0                                    # turning the toggle off removes the caster's own states
    if t has STA_IMMORTAL 291 or STA_ADLFLOUSSIERIMT 499 (vt 0x3e4): return 0
    if s.sdi_Activ null: assert "… Blast invalid spell activ", return 0
    if EffectType == SE_HEALING and not c.smo_ICanHealTo (vt 0xe94)(t): return 0
    result = 0
    for k in 0..3: (idx, strength, sucrate) = s.sdi_Abstate[k]           # ActiveSkill AbstateIndex / Strength / Rate
        if idx == MAX or rand(1000) ≥ sucrate or not (entry = as_FromIndex(idx)): continue
        if t.so_AbnormalState_Resist (vt 0x634)(entry): *resisted |= 1; continue    # Z03 §6.2 resist roll
        bonus = empower.keeptime ? s.sdi_Activ.<+0x1e3 + 4·keeptime> : 0         # = nT2[keeptime − 1] (ActiveSkill T columns)
        keep  = entry.subabstate[strength].KeepTime (0 without a row)
        if c has an item-action container (vt 0x5d0) and s has skill groups:
            keep = item-action rate of SEIT_KEEPTIME_RATE_INCREASE for s's groups applied to keep  (Z17)
        passive = 0
        if one of s's ActiveSkillGroups has ActiveSkillGroupIndex 99 BiffTimeIncrease:
            passive = (bonus + keep) × c.smo_Param.PassiveBuffKeepTimeUPRate / 1000    # Z12 §2 (KeepTimeBuffUPRate)
        keep += passive + bonus                         # (both products divide first above 3 600 000 ms)
        if t.so_AbnormalState_Set (vt 0x638)(c, idx, strength, entry, now, 0, restCount −1, keep,
                                            EF_JUSTENCHANTBATTLEOBJECT 5, null):
            str = g_NewAbstateStrength                  # the strength asl_AbstateSet actually stored
            x = t's element of entry.AbStataIndex
            if x: c.so_ItemActonAbstateApp (vt 0x5d4, FUN_0055dea0)(x, s, t)
                # 8 item-action kinds (SEIT_STA_AC_RATE_DECREASE, _DEX_, _MAX_HPSP_, _DEAD_HPSP_RECOVER_, _SHIELDAC_,
                #   _DOT_HEAL_, _WC_RATE_INCEASE, _SHEILD_BLOCK_) → aeo_SetItemActionEffect(x, kind, rate) (Z17 / Z21)
            x null or no element class: assert "bo_Routine: invalid abstate" / "… invalid abstate 2"
            elif not element.vt[0x0c]():                # party mains inform through their own routine (§12.4)
                so_AbnormalState_BitSet(t, index)
                shown = keep × SET_ABSTATEKEEPTIMERATE / 1000                                # as aeo_Set scales it
                t.so_AbnormalState_Inform (vt 0x3f0)(index, shown, 1)                       # 0x2429 to t (player)
                so_AbnormalState_BroadcastSet(t, index, shown, str)                         # 0x2427 / 0x1C18
            result = 1
    return result
```

The setter passed to `so_AbnormalState_Set` is the caster `c`, so a party-main state (§12.4) set by a skill on
another object has `aeo_Caster.obj` ≠ bearer; the party routines then use that raw pointer (§13).

## 11. Death hooks (slot 0x14)  @ FUN_00407730, FUN_00407910

`ShinePlayer::so_KilledBy` FUN_00433be0 (Z03 §7.2) calls slot 0x14 for every state of the dying player.

```pseudo
SubAbnormalStateActorPartyRecharge::sasa_Act_Killed(p, e):                       # type 26 DEADHPSPRECOVRATE
    e null: return
    party = p.so_PartyRegistNumber() (vt 0x550); 0xFFFF (no party): return
    rate = row.Arg(SAA_DEADHPSPRECOVRATE)
    if &e.aeo_SetItemEffect ≠ null (always true (original bug) Z22-B10):
        rate = rate × e.aeo_SetItemEffect.siae_GetArgument_Base1000ByEffect(SEIT_STA_DEAD_HPSP_RECOVER_RATE_INCREASE) / 1000
    party ≥ 4000: assert "… : Too large party handle", return
    n = partycontainer.m_Array[party].NumOfMember; n ∉ 2…5: assert "… : Invalid party member number", return
    for i in 0 … n−1:
        m = pm_FindMember(partymanufacture, party, i)                                  @ FUN_004cc390
            # party ≥ 4000 → assert "Too large party regnum"; raid party (isRaidTypeParty): Members[i].memberobj if
            #   i < NumOfMember else null; normal party: needs 2…5 members ("Invalid party member number") and
            #   i < NumOfMember ("sub is too big"), then Members[i].memberobj (null for an offline slot)
        if m and m.smo_GetMode() ∉ {0, 3} and so_DistanceSquar(p, m) < 1,000,000:     # alive, within 1000 units
            m.so_ply_PartyRecharge (vt 0x7a0)(rate)
ShinePlayer::so_ply_PartyRecharge(m, rate):                                                  @ FUN_0055a0a0
    sp_HPChangeCheck(m, MaxHP × rate / 1000, 1, "…so_ply_PartyRecharge")    # FUN_0055e130: no effect (Z11, `&sethp`)
    CurHP += so_MaxHP() × rate / 1000;  CurSP += so_MaxSP() × rate / 1000
    if so_GetHP() < CurHP: CurHP = so_GetHP()        # compares the value with itself: never clamps
    if so_GetSP() < CurSP: CurSP = so_GetSP()        #   (original bug) Z22-B9
    # no packet: the member's client is not told about the gain here

SubAbnormalStateActorSelfRevive::sasa_Act_Killed(p, e):                          # type 58 SELFREVIVE  @ FUN_00407910
    p.so_ply_setIsRebirth (vt 0xc48, FUN_0055a780)(1)                 # sp_RebirthState.bIsRebirth
    p.so_ply_setHealRate (vt 0xc50, FUN_0055a790)(row.Arg(SAA_REVIVEHEALRATE))     # .nHealRate
```

Data: SubStaSacrifice (13 rows, `DEADHPSPRECOVRATE` 500…1100): when the bearer dies, every living party member
within 1000 units regains 50…110 % of max HP and SP, which can exceed the maximum (Z22-B9). SubStaRebirth /
SubStaE_Egg2014_SelfRevive (`REVIVEHEALRATE` 200…600): the dead player may revive in place with 20…60 % HP: the
client's 0x1102 NC_CHAR_REBIRTH_CMD then calls `sp_ReviveNow(p, nHealRate)` (Z07 §3.2); `so_KilledBy` reads
`bIsRebirth` (the "not set" value is the character `'0'` = 0x30, which every reader compares against, so the actor's
1 counts as set). Both values are cleared at login complete, on revive and on 0x1103 NC_CHAR_REBIRTH_REJECT_CMD.

## 12. Element classes (`AbnormalStateElement` subclasses)

The element is the per-`ABSTATEINDEX` **template** object in `abstatetemplate` (one `AbnormalStateList`, §1.3); it
holds no per-bearer state (that is the `AbstateElementInObject`, Z03 §6.2). Class layouts *(pdb2016)*, slot
targets from the RTTI vftables (`tools/protocol-re/rtti.py`).

### 12.1 Slots and callers

Every element vftable has 11 slots. Base stubs are folded functions named after unrelated classes in the decomp
(`549070` / `4c2450` = empty, `5af8d0` = return 1, `4b8d20` / `401a80` = return 0, `450350` = return this).

| Slot | Meaning | Base | Overridden by | Called from |
|---|---|---|---|---|
| 0x00 | `ase_IndexString()` → class tag | `401510` (no tag) | every class: `"Normal"` FUN_00401520, `"Party"` FUN_00401530, `"GldAca"` FUN_00401540, `"WedCpl"` FUN_00401550, `"Recover"` FUN_00401560, `"ReinforcedMove"` FUN_00401570, `"RestCount"` FUN_00401580, `"Tick"` FUN_00401590, `"EachTick"` FUN_004015a0, `"Hide"` FUN_004015b0, `"Polymorph"` FUN_004015c0, `"RestCountHPRate"` FUN_004015d0 | no slot call found (debug text) |
| 0x04 | `ase_Routine(bearer, slot, e, &removed)` → bool | 00406910 (expiry, §1.3) | Tick 00406a40, EachTick 00406b70 (§1.3), Party 0040ebc0, WedCpl 0040e5e0, GldAca 0040ef70, Polymorph 00406c80, Hide 00409c10 | `ListIter_ObjectAbStateRoutine::lid_Call` FUN_004067e0 (§1.3) |
| 0x08 | `ase_SetMain(entry)` | empty | Party / WedCpl 00408680, GldAca 004087b0 | `aeo_Set` FUN_0040a340, every set |
| 0x0c | "is a party enchant" *(our name; no symbol)* | return 0 | Party, WedCpl, GldAca: return 1 | `aeo_Set` (tick interval), `aeo_IsPartyChant` FUN_00409ab0, `aeo_InformAfterLogin` FUN_00409a20, `asl_Store` FUN_0040afd0 (Z12 §6.4: party states restored with setter = the player and no bitmap bit), `so_Dispel` FUN_0042bf70, `so_SkillEnchant` FUN_00431ca0 |
| 0x10 | unknown | empty | none | none |
| 0x14 | `ase_GetActMilliSec()` | FUN_00401480: 999 999 999 | Party / WedCpl / GldAca FUN_004014a0: 5000 | **none**: `aeo_Set` hard-codes the 5 s party interval instead (dead slot) |
| 0x18 | `ase_PreAttachObject(setter, bearer, strength, …)` | empty | ReinforcedMove 004083a0 | `aeo_Set`, every set (also refreshes), before the element is filled |
| 0x1c | `ase_AttachObject(e, o)` | 00401d40 (§1.3) | ReinforcedMove 00401db0 (Z18) | `asl_AbstateSet` FUN_0040d020 |
| 0x20 | `ase_DetachObject(e, o)` | 00402000 (§1.3) | Recover 004084e0 (§1.3), ReinforcedMove 004085b0 | `asl_AbstateReset` FUN_0040a930 |
| 0x24 | `ase_This()` → element | `450350` return this | base, Party, WedCpl, RestCount, RestCountHPRate: FUN_00401820 = assert "AbnormalStateElement *AbnormalStateElement::ase_This called" + `ShineExit` | only the `AbnormalStateList` ctor; the classes whose `ase_This` aborts are stored by address instead |
| 0x28 | `ase_MaxRestCount(entry, strength, bearer)` → `aeo_RestCount` | `401a80`: 0 | RestCount 00401a90, RestCountHPRate 00401ab0 (§12.3) | `aeo_Set` |

(`AbnormalStateList::operator[](i)` FUN_00401850 = `asl_AbstateNode[i].asn_Abstate` for i < 0x318, else null.)

### 12.2 Which abstate uses which class  (`AbnormalStateList::AbnormalStateList` @ FUN_0040f1e0)

The constructor builds one member per class name (`asl_<NAME>`, 932 members) and fills
`asl_AbstateNode[0x318]` (and the `asl_AbstateList` list of 0x318 entries, `l_MakeList`). All 792 indices get an
element *(join of the ctor's `asl_AbstateNode[i] = …asl_X` lines; the part-1 join missed 13 multi-line ones)*:

| Class | Indices | Which |
|---|---|---|
| `AbnormalStateElementNormal` | 598 | everything else (no routine, base expiry only) |
| `AbnormalStateTickRoutine` (`Metronome astr_Tick`, unused: the tick lives in the bearer's element) | 132 | DoT / HoT / area / magic-field states (§3–§6) |
| `AbnormalStateEachTickRoutine` | 20 | the fear states (§6): 85, 113–115, 316–325, 343, 371, 625, 626, 639, 664 |
| `AbnormalStatePartyEnchant` (`aspe_Soul[5]`, `aspe_SklIdxMain`, `aspe_SkillIndex[5]`) | 14 | 3 MightySoulMain, 18 BlessingMain, 26 MentalShoutMain, 29 DivineWeaponWCMain, 53 WindChargeMain, 59 MistChargeMain, 90 SoulEdgeMain, 602 SenPartyHPUpMain, 716 MoverStatUpParty, 733–737 E_UserComeback_Main01…05 |
| `AbnormalStateCouplePartyEnchant` (same members) | 1 | 293 WeddingBuff |
| `AbnormalStateGuildAcademyMasterEnchant` (`asgame_Soul`, `asgame_SklIdxMain`, `asgame_SkillIndex`) | 2 | 297 AcaMsBuf10PMain, 299 AcaMsBuf7PMain |
| `AbnormalStateRestCount` (`asrc_RestCount` unused, `asrc_Action`) | 8 | 15 Buckler (`SAA_COUNT`), 16 Neglect, 28 DivineShield, 333 KarenDivine, 459 AdlUBAUP, 460 AdlUBADOWN, 596 DmgShield (all `SAA_SHIELDAMOUNT`), 493 HideWC (`SAA_MONSTERSTICK`) |
| `AbnormalStateRestCountHPRate` (`asrc_Action`) | 1 | 590 LightTouch (`SAA_SHIELDRATE`) |
| `AbnormalStateReinforcedMove` | 13 | 346–349 KnockBack / KnockBackFly / KnockBackRoll / FatalKnockBack, 383 GTIKnockBackRoll, 504 MineFireVivi, 546 EnKnockBackRate, 559 AwayBackSpot, 633 / 634 Siren_KnockBack1 / 2, 662 B_Albi_Knock, 691 Arena_DragOut, 768 SDVale01_Knock |
| `AbnormalStateElementRecover` | 1 | 350 CannotControl |
| `AbnormalStatePolymorph` | 1 | 97 Polymorph |
| `AbnormalStateHide` (`ash_SubLayer` = 3) | 1 | 288 GMHideMode |

So the counts in §1.3 are: 132 ticking states and 20 fear states. The class has 140 more members (57
`TickRoutine`: FOODHP00…, FOODSP00…, FOODTYPEA/B00…15, GTIVIRUSRTMAIN / MOVEMAIN, STA_BLA_DOT, STA_BHKARENDOT /
DOTHEAL; RestCount NEGLECT2…5, REUJELBLESSING, BHKARENDIVINE; RestCountHPRate MAGICSAFEGUARD; PartyEnchant
STA_DODGEMAIN; ReinforcedMove FETTERCHAIN, TIEARROW, BLA_KNOCK; EachTick BLA_FEAR; 72 `ElementNormal`, e.g. the
GMEVENTEXPUP / DROPUP and CHRTITLE*UP/DOWN sets) that no node points to: their names are not in the 2016
`ABSTATEINDEX` enum (newer or removed states compiled into the class), so they are dead. NEGLECT2…5 and the three
others also never get `asrc_Action`.

### 12.3 Rest counts  @ FUN_00401a90, FUN_00401ab0

```pseudo
AbnormalStateRestCount::ase_MaxRestCount(entry, strength, bearer)                       @ FUN_00401a90
    return assa_FindEffect(entry.subabstate[strength], this.asrc_Action)      # the row's value of that action
AbnormalStateRestCountHPRate::ase_MaxRestCount(entry, strength, bearer)                 @ FUN_00401ab0
    bearer null: return 0
    return bearer.so_MaxHP() (vt 0x4f0) × assa_FindEffect(row, asrc_Action) / 1000    # 64-bit multiply / divide
# aeo_Set stores the result in e.aeo_RestCount (+0x54) on every set and refresh; other classes give 0
```

| Index | Row | Action → RestCount | Consumer |
|---|---|---|---|
| 28 DivineShield | SubStaDivineShield ×18 (Type 16) | `SAA_SHIELDAMOUNT` 1040, 1352, … | Shield `sasa_Act_DamageAbsorb` §9.2 |
| 16 Neglect, 596 DmgShield | Type 16 | `SAA_SHIELDAMOUNT` 1 000 000 000 (7 s / 0.5 s) | §9.2 (absorbs everything) |
| 333 KarenDivine | Type 16 | 999 999 | §9.2 |
| 459 / 460 AdlUBAUP / DOWN | Types 92 / 93 | `SAA_SHIELDAMOUNT` 60 000 | §9.6 damage-down actors |
| 15 Buckler | Type 59 | `SAA_COUNT` 2 (blocks) | RangeIntercept §9.3 |
| 493 HideWC | Type 106 | `SAA_MONSTERSTICK` 1 (swings) | HideDamage §9.4 |
| 590 LightTouch | SubStaLightTouch ×16 (Type 115) | MaxHP × `SAA_SHIELDRATE` (250, 260, …) / 1000 | ShieldHPRate §9.2 |

### 12.4 Party enchant  @ FUN_00408680, FUN_00405280, FUN_0040ebc0

A party "main" state sits on the caster (self-cast skill, or restored at login with setter = the player, Z12 §6.4)
and every 5 s hands one of five member states (`PartyState1…5` of AbState.shn) to the party members around the caster
and to itself. The choice depends on how many members are near.

```pseudo
AbnormalStatePartyEnchant::ase_SetMain(entry)              (element slot 0x08, every aeo_Set)   @ FUN_00408680
    this.aspe_SklIdxMain = entry                           # the shared template: last set entry wins (one AbState per index)
    if this.aspe_SkillIndex[0] already resolved: return    # once per server run
    for i in 0..4: aspe_FindSubState(i, entry.index.PartyState<i+1>)                                  @ FUN_00405280
        # dic_abstate.as_BTreeID[name] → AbStateStr (id > as_maxhandle: assert "as_FromID : Invalid skill id");
        # aspe_SkillIndex[i] = it, aspe_Soul[i] = its AbStataIndex; missing name → stop
    any missing: assert "…AbnormalStatePartyEnchant::ase_SetMain"; aspe_SkillIndex[0] = null (retried next set)

aeo_Set, party classes (slot 0x0c true):                   (FUN_0040a340, the part Z03 §6.2 summarises)
    e.aeo_Tick.nextaction = { m_TickInterval = 50 (5 s in 0.1-s ticks), m_NextTick = now − SAA_TICK·10/1000 }
        # main rows have no SAA_TICK → first routine run on the next clock tick
    if e.aeo_PartyEnchant[0].skillindex null: aeo_FindSubState(e, i, PartyState<i+1>) for i 0..4  @ FUN_00406670
        # a per-bearer copy of the five {soul, skillindex}; any failure nulls [0]; nothing ever reads the copy
    # other classes: interval = SAA_TICK·10/1000, m_NextTick = now

AbnormalStatePartyEnchant::ase_Routine(bearer, slot, e, &removed)                      @ FUN_0040ebc0
    base ase_Routine (expiry); if removed or e.aeo_Tick.nextaction.m_NextTick >= now: return 1
    m_NextTick += 50
    caster = e.aeo_Caster.obj                              # raw pointer, not checked with aeo_GetCaster (§1.4)
    caster null: e.aeo_Tick.terminate = now; return 1      # main state ends on the next walk
    if caster.so_PartyRegistNumber() (vt 0x550) == 0xFFFF (no party):
        asl_AbstateSet(bearer list, setter caster, aspe_Soul[0], e.aeo_Strength, aspe_SkillIndex[0], bearer, now,
                       keep 0 (row KeepTime + 999 ms), EF_PARTYBUFF2ME, no data)      # result not checked (original bug) Z22-B15
        rest = (e.aeo_Tick.terminate − now) × 100 ms
        bearer.so_AbnormalState_Inform (vt 0x3f0)(aspe_Soul[0], rest, 0)     → 0x242A NOEFFECT to the bearer
        so_AbnormalState_BroadcastSet(bearer, aspe_Soul[0], rest, strength)  → 0x2427 / 0x1C18 (Z03 §6.3)
        return 1
    scan = AxialListNearScanParty { alnsp_PartyRegnum = caster's party }
    so_AllOfRange(caster, sight, caster.location, main.index.PartyRange, no sector, scan, includeSelf 0, 0xffff)
        # alns_ValidObject @ FUN_00401880: o.so_PartyRegistNumber() == alnsp_PartyRegnum (mobs answer 0xFFFF);
        # plus ali_Work's base filter (§1.4: modes 0 / 3 out, max 200, no 291 / 499 holders)
    qsort(scan, alns_Compare)                              # nearest first
    n = clamp(scan.count, 0, 4)                            # other members near the caster
    alnsp_Buffing(scan, main.index.PartyEnchantNumber, caster, aspe_Soul[n], strength, aspe_SkillIndex[n], 0)
    if asl_AbstateSet(bearer, setter caster, aspe_Soul[n], strength, aspe_SkillIndex[n], bearer, now, keep 0,
                      EF_PARTYBUFF2ME):
        restTicks = e.aeo_Tick.terminate − now
        restTicks < 6 000 000 (≈ 6.9 days): t = restTicks × 100 ms, effect 0;   else: t = 900 000 000, effect 1
        bearer.so_AbnormalState_Inform(aspe_Soul[n], t, effect);  so_AbnormalState_BroadcastSet(bearer, aspe_Soul[n], t, strength)
    return 1                                               # never stops the walk

AxialListNearScanParty::alnsp_Buffing(scan, max, caster, soul, strength, entry, 0)      @ FUN_0040e250
    for the first min(max, scan.count) members m (nearest first):
        if m.smo_GetMode() (vt 0x484) ≠ 3 (dead):
            if asl_AbstateSet(m list, setter caster, soul, strength, entry, m, now, keep 0, EF_PARTYBUFF2MEMBER):
                so_AbnormalState_BroadcastSet(m, soul, −1, strength);  m.so_AbnormalState_Inform(soul, 0xFFFFFFFF, 0)
```

Effects for the client: members get 0x242A `NC_BAT_ABSTATEINFORM_NOEFFECT_CMD {abstate, keeptime 0xFFFFFFFF}`
(no timer) and the sight 0x2427 / 0x1C18 with keep −1; the caster's own copy carries the main state's remaining time.
The member state really lasts its `SubAbState.KeepTime` + 999 ms (6 s + 1 s for most rows, 5 s for the Comeback rows,
10 s for MoverStatUp), so it is refreshed every 5 s while the member stays within `PartyRange` and expires (0x2428)
within ~2 s after leaving. Ending the main state removes nothing directly; the member and self states run out the
same way. 2016 data *(AbState.shn × SubAbState.shn)*:

| Main (index) | Main keep | PartyState1…5 (n = 0…4 members near) | PartyRange / PartyEnchantNumber |
|---|---|---|---|
| MightySoulMain (3) | 30 min | MightySoul (4, Type 38, 60 s), MightySoul2…5 (10–13, Type 0, `SAA` 1 = 112 / 162 / 212 / 312) | 1600 / 5 |
| BlessingMain (18) | 60 min | Blessing, Blessing2…5 (19, 36–39, Type 4) | 1600 / 5 |
| MentalShoutMain (26) | 60 min | MentalShout, …2…5 (27, 40–43, Type 14) | 1600 / 5 |
| DivineWeaponWCMain (29) | 60 min | DivineWeaponWC, …2…5 (30, 44–47, Type 2) | 1600 / 5 |
| WindChargeMain (53) | 60 min | Dodge (50) ×5 | 1600 / 5 |
| MistChargeMain (59) | 10 min | MistCharge, …2…5 (60, 71–74, Type 37) | 1600 / 5 |
| SoulEdgeMain (90) | 30 min | SoulEdge, …2…5 (81, 91–94, Type 40) | 1600 / 5 |
| SenPartyHPUpMain (602) | 60 min | SenPartyHPUp (603, 0 ‰), SenPartyHPUp1 (604, 300 ‰) ×4 (Type 24, max HP) | 2400 / 5 |
| MoverStatUpParty (716) | 10 min | MoverStatUp (717) ×5 | 1000 / 5 |
| E_UserComeback_Main01…05 (733–737) | 10 / 20 / 30 / 60 / 120 min | E_UserComeback01…05 (738–742) ×5 (Type 110 `SAA` 108 = 20…100: exp rate, §8) | 2400 / 10 |

### 12.5 Couple party enchant (wedding)  @ FUN_0040e5e0

`AbnormalStateCouplePartyEnchant` inherits the party element (`ase_SetMain` FUN_00408680, slots 0x0c / 0x14); only
the routine differs. Its one user is StaWeddingBuff (293; KeepTime 4 000 000 000 ms) with five times StaWeddingSub01
(294, Type 0, 6 s, `SAA` 39 = 50), range 1600, PartyEnchantNumber 5.

```pseudo
AbnormalStateCouplePartyEnchant::ase_Routine(bearer, slot, e, &removed)                 @ FUN_0040e5e0
    base ase_Routine; if removed or not due: return 1;  m_NextTick += 50
    caster null: terminate = now; return 1
    caster not in a party (vt 0x550 == 0xFFFF): return 1   # nothing, not even the self copy
    scan = AxialListNearScanCoupleParty { alnsp_PartyRegnum = caster's party,
                                          alnsp_PartnerRegnum = caster.so_ply_WeddingStatus() (vt 0x958).Partner.RegisterNumber }
    so_AllOfRange(caster, …, PartyRange, scan, includeSelf 0);  qsort nearest first
        # alns_ValidObject @ FUN_004018c0: same party and o.so_GetCharRegistNumber() (vt 0x344) == partner
    n = clamp(scan.count, 0, 4)                            # 0 or 1 in practice
    AxialListNearScanCoupleParty::alnsp_Buffing(scan, PartyEnchantNumber, caster, aspe_Soul[n], strength,
                                                aspe_SkillIndex[n], 0)                 @ FUN_0040e380
        # as §12.4's Buffing, but Inform(soul, 0xFFFFFFFF, effect 1) → 0x2429 NC_BAT_ABSTATEINFORM_CMD
    if scan.count > 0:                                     # the partner is near
        asl_AbstateSet(bearer, caster, aspe_Soul[n], strength, aspe_SkillIndex[n], bearer, now, keep 0, EF_PARTYBUFF2ME)
        t = restTicks < 6 000 000 ? restTicks × 100 ms : 900 000 000      # the wedding main always gives 900 000 000
        bearer.so_AbnormalState_Inform(aspe_Soul[n], t, 1); so_AbnormalState_BroadcastSet(bearer, aspe_Soul[n], t, strength)
        # sent whatever asl_AbstateSet returned (original bug) Z22-B15
    return 1
```

The wedding status itself is not checked: an unmarried caster's partner number is whatever `sp_WeddingData` holds
(0 *(inferred)*), which no party member has.

### 12.6 Guild academy master enchant  @ FUN_004053c0, FUN_004087b0, FUN_0040ef70

```pseudo
AbnormalStateGuildAcademyMasterEnchant::ase_SetMain(entry)                              @ FUN_004087b0
    asgame_SklIdxMain = entry; if asgame_SkillIndex unresolved: asgame_FindSubState(entry.index.PartyState1)  @ FUN_004053c0
        (same lookup as aspe_FindSubState, one sub-state: asgame_SkillIndex / asgame_Soul); failure: assert, null

AbnormalStateGuildAcademyMasterEnchant::ase_Routine(bearer, slot, e, &removed)          @ FUN_0040ef70
    base ase_Routine; if removed or not due: return 1;  m_NextTick += 50
    caster null: terminate = now; return 1
    scan = AxialListNearScanGuildAcademy { alnsga_GuildRegnum = caster.so_mobile_GetGuildRegnum() (vt 0x818, m_nMyGuildNo) }
    so_AllOfRange(caster, …, PartyRange, scan, includeSelf 0);  qsort nearest first
        # alns_ValidObject @ FUN_00401920: o.so_ply_isAcademyGuildMember() (vt 0x858) == 0 → o's guild == the caster's guild;
        #   == 1 → o.so_ply_GetMyGuildAcademyNo() (vt 0x85c) == the caster's guild; mobs answer 0 / 0
    AxialListNearScanGuildAcademy::alnsga_Buffing(scan, scan.count, caster, asgame_Soul, strength, asgame_SkillIndex, 0)
                                                                                         @ FUN_0040e4b0
        # as §12.4's Buffing (effect 0); every scanned member, PartyEnchantNumber is not used (original bug) Z22-B14
    asl_AbstateSet(bearer, caster, asgame_Soul, strength, asgame_SkillIndex, bearer, now, keep 0, EF_PARTYBUFF2ME)  # unchecked (original bug) Z22-B15
    bearer.so_AbnormalState_Inform(asgame_Soul, restTicks < 6 000 000 ? 0xFFFFFFFF : 900 000 000, 1)
    so_AbnormalState_BroadcastSet(bearer, asgame_Soul, 900 000 000, strength)          # (original bug) Z22-B14
    return 1
```

Data: StaAcaMsBuf10PMain (297) / 7PMain (299), main row SubStaKeepTime_70Sec (70 s), PartyState1 StaAcaMsBuf10P (298)
/ 7P (300) (Type 63, 6 s, four stat actions 4 / 6 / 46 / 16 = 100 resp. 70), PartyRange 3000. A caster without a
guild (`m_nMyGuildNo` 0 *(inferred)*) would buff every guildless non-academy player and every mob in range; the
masters these states are made for always have a guild.

### 12.7 Forced movement and recover  @ FUN_004083a0, FUN_004085b0, FUN_004084e0

```pseudo
AbnormalStateReinforcedMove::ase_PreAttachObject(setter, bearer, strength, …)  (slot 0x18, every set)  @ FUN_004083a0
    if bearer and setter:
        if bearer.smo_GetMode() == 4 (camp / tent): bearer.so_ply_ReinforceFoldtent() (vt 0x488)
        bearer.so_ply_AllCastCancel() (vt 0x8d0)           # players; mobs: folded no-ops
        skilleffectapplyer.sbec_SkillCancel(bearer)        # drops the bearer's pending skill blasts (Z03)
            # @ FUN_00437ca0: std::remove of every queued SkillBlastEffect that equals (SkillBlastEffect::operator==)
            #   a template with sbe_CasterObject = bearer (FUN_005794a0 compares only the caster), then erase; the blasts never fire (no packet)
        0x2456 NC_BAT_SUMEONESKILLCUT_CMD { u16 caster = bearer.handle } to the bearer's sight range incl. the bearer
AbnormalStateReinforcedMove::ase_AttachObject  @ FUN_00401db0 — the knock-back / pull movement (vt 0xa28), Z18 (Z09 §31.5)
AbnormalStateReinforcedMove::ase_DetachObject(e, o)                                     @ FUN_004085b0
    ase_DetachObject (base, §1.3); if o: o.so_SendSpeedInformation(0) (vt 0xd4c)       # players: speed back to normal
AbnormalStateElementRecover::ase_DetachObject  @ FUN_004084e0: the same (§1.3)
```

0x2456 layout `{u16 caster}` (2 bytes, *(pdb2016)* `PROTO_NC_BAT_SUMEONESKILLCUT_CMD`, packets-zone.md). Client
`GameFrameWork::On_NC_BAT_SUMEONESKILLCUT_CMD` FUN_0049bcd0: looks the handle up (`CharMgr`); if that character is
in a skill action (vt 0x1f0) it calls `Char::CancelSkillAction` and `AttackSequenceManager::ApplicateSkillSeqImmediately`
(the cast animation is cut).

StaCannotControl (350), the only `ElementRecover` state, has no SubAbState row (`SubAbState` = "-"), so
`so_AbnormalState_Set` finds no sub-state and the set fails *(inferred: aeo_Set needs `subabstate[strength].assa_info`)*;
its setter `smo_ShootMeTo` (Z09 §9.3: "same for 350 StaCannotControl") still sends the 0x2429 inform.

### 12.8 Polymorph and GM hide  @ FUN_00406c80, FUN_00409c10

```pseudo
AbnormalStatePolymorph::ase_Routine(bearer, slot, e, &removed)                          @ FUN_00406c80
    base ase_Routine (expiry)
    if removed: bearer.smo_ply_Polymorph(null) (vt 0xeb0, Z09 §28.3 `smo_ply_Polymorph` @ FUN_004a5830)   # back to the own look
    return 1
    # StaPolymorph (97): SubStaKeepTime_5Min. Only the expiry path restores the look here; an early reset (vt 0x650)
    #   runs only the detach, which this class does not override (see §13)

AbnormalStateHide::ase_Routine(bearer, slot, e, &removed)                               @ FUN_00409c10
    base ase_Routine (expiry)
    if &removed == null: bearer.so_layer.layer→l_Sub = this.ash_SubLayer (3)
        # tests the pointer, which is never null: the sub-layer refresh never runs (original bug) Z22-B13
    return 1
```

StaGMHideMode (288) is set by the GM `&hide` command, which writes `l_Sub = 3` itself; `&show` resets the state and
writes 0 (Z11 §3.1, `ac_Hide` FUN_0041a3a0 / `ac_Show` FUN_0041a4d0). Its keep time (SubStaKeepTime_Eternal,
4 200 000 000 ms) makes the expiry branch practically unreachable.

### 12.9 Element side effects elsewhere

- `aeo_InformAfterLogin(e, p)` @ FUN_00409a20: for non-party states (slot 0x0c false) sends
  `Inform(index, ⌈rest ticks / 10⌉ × 1000 ms, 0)` (0x242A) and `BroadcastSet(index, same, strength)`; party mains are
  skipped (their routine informs the copies).
- `aeo_IsPartyChant(e)` @ FUN_00409ab0 = element slot 0x0c of `e.aeo_Index` (0 when no element).
- `so_SkillEnchant` (FUN_00431ca0): after setting a skill's state, sets the bitmap bit and sends Inform /
  BroadcastSet (keep × `SET_ABSTATEKEEPTIMERATE`) only for non-party states. The function as a whole is not
  documented by any item (see §14).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z22-B1 | `asl_Routine` + actor routines (Poison 0040d4c0, Disease 0040b8a0, AreaDamage 0040d640, DmgState, MagicField 00408d80) | the routines return 0 when the bearer has STA_IMMORTAL / STA_ADLFLOUSSIERIMT, on a null element / non-mobile scan member, or when MagicField cannot spawn; `l_4AllInList` stops at the first 0 | the bearer's later abstates neither tick nor expire while e.g. a poisoned player is under the login / map immortality | return 1 ("skip this effect") so the walk goes on |
| Z22-B2 | AreaDamage `sasa_Routine` 0040d640 | 0x245A `num` = scanned targets (≤ 30) including untouched ones, whose records are all zero | wasted bytes; the client skips object 0 | count and pack only damaged targets |
| Z22-B3 | `ActorCluster` 00405a10 / DmgState 0040dc60 | the DmgState actor is built but no SubState slot points to it; its routine also writes records at scan positions while counting only hits | dead code; if it were wired, records after a skipped target would be lost | register it (2017 has no matching SubState) or remove it; pack records by `num` |
| Z22-B4 | HPSPHeal `sasa_Routine` 00407120 | SP part ignores `HEALAMOUNTMINUS` and both set-item heal rates; HP part has no `HEALRATE` fallback | SoleFire-type HP+SP heals scale only the HP part | treat HP and SP alike (as HPHeal does for HP) |
| Z22-B5 | `so_mobile_HPHealOverTime` 0040e910 | sends `abstate = index` unmapped; `so_mobile_DamageOverTime` maps 0x318 → 0xFFFF | magic-field heals (index 0x318) make the client look up a non-existent abstate | map 0x318 to 0xFFFF |
| Z22-B6 | TimeAttack `sasa_Act_LastDamegeInterceptByDef` 0040ba30 | new keep time = `(rest / 50000) × 1000` (integer); 0 when less than 50 s are left, and `aeo_Set` treats keep 0 as "use KeepTime" | a hit on a SubStaTimeAttack holder with < 50 s left restarts the 180 s freeze instead of shortening it | round up, or pass at least 1 ms |
| Z22-B7 | TimeAttack 0040ba30 | `so_AbnormalState_BroadcastSet` / `so_AbnormalState_Inform` get the old remaining time, not the new keep time | client timers keep showing the long time after the hit shortened the state | send the new keep time |
| Z22-B8 | RangeIntercept `sasa_Act_DamegeIntercept` 004074f0 | the state is ended only by the ranged hit that finds the count at 0, which is let through | after its 2 blocks SubStaBuckler stays visible (and active) until the next ranged hit | end the state when the count reaches 0 (as Shield / HideDamage do) |
| Z22-B9 | `ShinePlayer::so_ply_PartyRecharge` 0055a0a0 (PartyRecharge actor 00407730) | clamps CurHP / CurSP against `so_GetHP` / `so_GetSP` (the current values) instead of `so_MaxHP` / `so_MaxSP`; sends nothing | party members of a dying SubStaSacrifice holder can go above max HP / SP; their clients are not told | clamp to the maxima and send the HP / SP change |
| Z22-B10 | PartyRecharge `sasa_Act_Killed` 00407730 | tests `&e.aeo_SetItemEffect != null` (an address inside the element) | dead check: the set-item factor always applies (harmless: base 1000) | test whether a set-item effect is stored |
| Z22-B11 | `SubAbnormalStateDamageMinus::sasa_Act_DamageMinusRate` 00402300 (slot 0x4c) | no caller in the 2016 zone | dead code | remove, or call it where a flat damage-minus rate was planned |
| Z22-B12 | `SubAbnormalStateMaxHP` 00401990 | sends the new max HP to the players targeting the bearer only when the state is set (`sasa_AfterEnchant`); no detach override | observers' target frames keep the raised max HP / SP after the state ends, until the next target info | also refresh them on detach |
| Z22-B13 | `AbnormalStateHide::ase_Routine` 00409c10 | tests the `removed` **pointer** for null instead of the flag | the per-tick write of `ash_SubLayer` (3) to the GM's `so_layer.layer→l_Sub` never runs; GM hide relies on `ac_Hide`'s own write | `if (!*removed)` (keep the hidden sub-layer while the state lasts) |
| Z22-B14 | `AbnormalStateGuildAcademyMasterEnchant::ase_Routine` 0040ef70 | buffs every scanned guild / academy member (up to 200), ignoring `PartyEnchantNumber` (5); informs the master with keep 0xFFFFFFFF while < 6 000 000 ticks remain (always: the main lasts 70 s) and broadcasts 900 000 000 ms | unlimited targets; the master's client and sight show a wrong (endless) time for its own copy, where the party routine sends the real remaining time | cap at `PartyEnchantNumber`; send the remaining time as `AbnormalStatePartyEnchant::ase_Routine` does |
| Z22-B15 | `AbnormalStatePartyEnchant::ase_Routine` 0040ebc0 (no-party branch), `…CouplePartyEnchant::ase_Routine` 0040e5e0, `…GuildAcademyMasterEnchant::ase_Routine` 0040ef70 | send `so_AbnormalState_Inform` / `BroadcastSet` for the bearer's own copy without checking `asl_AbstateSet`'s result (the party-member path and the in-party branch do check) | when the set is refused (a stronger copy present, a refusing map, …) the client is told of a state / time the server did not set | inform only after a successful set |
| Z22-B16 | `smo_SkillBlast` FUN_00581160 (path `mha_HitStep < 0`, §10.7) | calls `smo_Dispel` FUN_0057d8e0 and then runs an inline copy of its body | every cure / dispel / steal of a single hit runs twice: SE_CURE and DISPELONE remove two states, DISPELRANDOM picks twice, STEALENCHANT rolls twice | apply the dispel once (the `mha_HitStep ≥ 0` path already does) |
| Z22-B17 | `so_SkillCure` FUN_0042c440, `so_Dispel` FUN_0042bf70 | each candidate state passes `rand(1000) < 1001` first | dead check (always true) | a per-state success rate (a skill or row column) was probably planned |
| Z22-B18 | `so_Dispel` FUN_0042bf70 | a dispel with only `sdi_DISPELRANDOM` returns 0 even when its pick was removed; DISPELONE / DISPELALL / BOMBDISPELALL / a steal return 1 | harmless today: both callers ignore the result | return 1 when the random pick removes a state |
| Z22-B19 | `so_Dispel` FUN_0042bf70 (steal) | the stolen copy is set with the victim's start tick and keep 0 (`aeo_Set`: ends at start + row KeepTime), but Inform / BroadcastSet send the full `KeepTime` | the thief's copy ends earlier than its client shows; a state set more than `KeepTime` ago (e.g. extended by a passive) is stolen already expired | set the copy with `now` and the victim's remaining time, and send that |
| Z22-B20 | `so_mobile_DamageOverTime` FUN_00409cd0 (miss branch) via AreaDamage `sasa_Routine` FUN_0040d640 | the miss branch broadcasts 0x243C `IsMissDamage = 1` without checking `send`; the area routine (send = 0) still writes the target's 0x245A record `{handle, HP, 0, order}` | an area-DoT miss reaches the client twice (a single-target miss packet plus an area record with damage 0) | honour `send` in the miss branch and mark the miss in the area record (or skip it) |
| Z22-B21 | `smo_SkillCooltimeSet` FUN_0057c5b0 → vt 0xf60 on `ShineMob` / `ShineServant` (stub FUN_00417480) | only the player override `smo_ChineCastCut` FUN_005794d0 ends the cooldown-ignore states; mobs and servants have the empty base stub | a mob or servant with a type-31 state skips every skill cooldown until the state expires; `smo_Flag.ChineCast` stays set | end the states on mobs too (move `sp_ChineCastCut` into `ShineMobileObject`) |
| Z22-B22 | `smo_SkillBlast` FUN_00581160 (`mha_HitStep < 0`) | `so_SkillEnchant` is skipped for an immune target, `smo_Dispel` and its inline copy are not | an immune target is still cured / dispelled / robbed (twice, Z22-B16) | *(inferred)* skip the hostile removers for immune targets too (friendly cures may be intended) |

## 13. Not reconstructed / uncertain

- The floating-point steps of `roe_AttackPowerCalcDamage` were read from the x87 instructions (the decompiler hides
  them behind `_ftol2_sse`); operand order is certain, but `roe_DefendPower`'s own formula is Z03 §4.6's.
- `GetLevelCapRate` tables (`LevelGap_Player_to_Monster` / `_Player_to_Player`) and `damagebyangle_*` are Z03's
  combat tables; not re-read here.
- Whether a 0x243C with `IsMissDamage = 1` but a non-zero `damage` can occur: the server never sends one.
- `so_KilledBy`'s order of setting the dead mode and running slot 0x14 was not re-read: whether the dying
  SubStaSacrifice holder recharges itself (it is a party member) depends on it (`smo_GetMode() ∉ {0, 3}`).
- `SB_SILENCE` = 2 is taken from Z03 §5.2 (`smo_SkillBlastOption() == 2`); the `SkillBlast` enum was not found in
  the 2016 PDB dump by name.
- `so_AllOfRange`'s `includeSelf` meaning of the 7th argument and "range 0 = sight" come from
  `docs/knowledge/Z09.md`; not re-read here.
- How a `SubAbState` row with Strength 999 (SubStaE_UserComeback_Main01…05) is stored and found by `aeo_Set`
  (`AbStateStr.subabstate[strength]`) was not checked; the chain of §7.3 assumes the row is reachable.
- Element vt slot 0x0c has no symbol name ("is a party enchant" is ours) and slot 0x10 has no override and no caller;
  neither name is in the 2016 PDB dump (no method lists).
- `AbnormalStatePolymorph` resets the look only on expiry (§12.8). Whether an early reset of StaPolymorph (dispel,
  `so_AbnormalState_Reset`) restores it elsewhere (the Type 38 actor's detach, `sp_nPolymorphAbstateIndex`) was not
  followed; Z09 §28.3 documents `smo_ply_Polymorph`.
- The party routines use `e.aeo_Caster.obj` without the register-number check of `aeo_GetCaster`; safe while the
  caster is the bearer (self-cast mains, login restore with setter = the player). `so_SkillEnchant` (§10.7) passes the
  caster as setter, so a party-main skill aimed at another object would leave a pointer that dangles once the caster
  logs out; whether any 2016 `ActiveSkill` row with a party-main abstate targets others was not checked.
- When `smo_SkillBlast`'s `hit.mha_HitStep` is negative (§10.7 path) was not traced into the blast container
  (`SkillBlastEffect.sbe_MultiHitArgument` starts at −1; Z03 §5.4).
- The servant kill of `so_Dispel` (§7.5) is `so_DamagedBy(t, HP, 1000, 1)` (disassembly checked). `ShineMob::so_DamagedBy`
  FUN_00431750 sets `sm_HP` to 0 but does not start the death; whether a later dead check (vt 0x8d4, e.g. from the
  servant's own tick) then kills the servant was not traced, unlike the DoT path, which calls `so_KilledBy` when
  the damage reaches the HP (§3.5).
- The ctor's member → index join is a regex over the decompiled ctor (scratch script); all 792 nodes resolved, but
  a member assigned through an unusual expression would be misattributed.

## 14. Coverage boundary

Gap check (sweep): every `FUN_` cited here, expanded one call deep with `coverage.py`'s call graph (hubs > 25 callers,
registered handlers and < 6-line functions skipped), against all docs: the rows below are what remained.

| Found | Covered by | Argument |
|---|---|---|
| `GuildTournamentSystem::ScanEnemyUser` FUN_0047a3d0 | Z16 (guild tournament system class, via Z09 §31 row "Guild tournament") | GT state logic; the actor only triggers it |
| `ShinePlayer::sp_SkinPolymorph` FUN_004a3280, `ase_AttachObject` FUN_00401d40 | Z18 (Z09 §31.2 rows owned by Z03, `docs/knowledge/Z09.md` §3) | listed there as Z03 leftovers |
| `AbnormalStateReinforcedMove::ase_AttachObject` FUN_00401db0 (knock-back / pull movement) | Z18 (Z09 §31.5 row "Skill-side helpers … skill movers 00401db0", owner Z03) | movement code; §12.7 documents the element's other slots |
| set-item effect slots (`aeo_FillSetItemEffect`, `aeo_SetItemEffectStore`, `aeo_SetItemActionEffect`, `SetItemAbstateEffect::siae_Clear` FUN_00510030, `SetItemData::SkillEffect::operator[]` FUN_00510010) | Z21 (plan: "`SetItemAbstateEffect::siae_*` 00510030…00510350", "`aeo_SetItemActionEffect` 00510810") | the actors only read the stored rates |
| item-action observers: `ItemActionObserveManager::EventRunBySkillGroupIndex` FUN_005d1f50, `ActionResults::GetRateAppliValue` FUN_005d0c20, `ItemActionArgument` ctor FUN_0042aad0, `Send_SETITEMHEALEFFECT` FUN_005cfbb0 (from `RecoverTypeEffect::_execute`) | Z17 (plan: "Item actions … the player's item-action cooldown container (player `vt 0x5d0`)") | §10.7 / §5 use them only as "item-action rate of kind X" |
| `so_Heal` / `so_recoversp`, `so_DamagedBy` / `so_KilledBy`, `roe_DefendPower`, level-gap tables, `DamageByAngle::DamageTable::operator[]` FUN_0045c9a0 | Z03 §4.5 / §4.6 / §7 (done) / Z09 §17.3 | combat core, already documented |
| `smo_SkillBlast` FUN_00581160 apart from the enchant / dispel calls, its `mha_HitStep ≥ 0` abstate loop | Z03 §5.6 (done; steps D / E) | skill blast core; §10.7 adds only the `mha_HitStep < 0` path and Z22-B16 |
| callees of `so_KilledBy` FUN_00433be0 reached through §11: `sp_HorseOff` FUN_0045f7c0 (also from `sp_StateChangeToNormal`) | Z13 (plan: "Mounts: mover creation …, `so_smv_GetOff` …") | dismounting a horse is mount code; Z03 §7.2 / Z08 name the call |
| `AbstateShelter::operator[]` FUN_00418890, `std::vector<AbstateElementInObject>` push_back / resize FUN_00433b70 / FUN_00433ac0, `~AbstateElementInObject` FUN_00401b20 (from `so_KilledBy`) | Z03 §7.2 (done: `g_ShelterItem` keeps the saved states) / Z18 (Z09 §31 row "Abnormal states: … ~AbstateElementInObject 00401b20") | STL container instances; the stored data is described in Z03 |
| `PartyManufacture_pm_QuestCheck` FUN_004ccbf0, `ShineQuestDiary::sqd_MobDead` FUN_00578170 (from `so_KilledBy`) | Z15 (plan: "mob kill (… `ShineQuestDiary_sqd_MobDead` …), party quest checks (`PartyManufacture_pm_QuestCheck_*`)") | quest engine |
| `sp_KQElementFunction` FUN_00499710, `KQPlayerInfoList::kqpil_KnockDownPlus` FUN_00496de0 (from `so_KilledBy`) | Z16 (plan: "`KQPlayerInfoList` (… knock-down counters …)") | kingdom-quest counters |
| `CharaterSkillList::csl_EmpowerStruct` FUN_004482c0, `csl_MaximumSkill` FUN_00448240 (from `SkillCostCheck`) | Z03 §5.2 (done: "the SKILL_EMPOWER bits of the highest learned step") | skill list; §10.4 only reads the SP cost hook |
| `std::operator!=<char>` FUN_0040e090, `vector<SkillDamage>::push_back` FUN_0057f350, `ShinePlayer::GetMode` FUN_00549800 | none needed | library code / one-line accessor |
| second-order callees of the rows above, reached only because a row cites its parent: `sp_HorseItemSave` FUN_0045e810; `QuestPlayer_NPCMobKill` FUN_005c08d0; `kqpil_PlayerInformFunc` FUN_00498c40, `sp_MyKQElement` FUN_00496c50; `ItemActionObserveManager::_EventRun` FUN_005d1df0; `aeo_SetItemActionEffect` FUN_00510810; `BattleObjectList::bol_Store` FUN_00434ee0 | the row of the parent (Z13 / Z15 / Z16 / Z17 / Z21 / Z03 §5.6) | same subsystem as the parent |
| `BinaryDataBox<StateField>::bdb_ReadData` FUN_004628e0 (SHN reader instance) | Z01 §2.3 (data tables and their loaders; StateField row) | §7.5 documents the StateField rows and their use |
| STL and list templates: `std::_Tree<ABSTATEINDEX>` `_Linsert` / `find` / `_Buynode` FUN_00463f90 / FUN_004642e0 / FUN_00463f20, `std::_Remove<SkillBlastEffect>` FUN_00435dd0, vector `_Reserve` / `erase` / `_Uninit_def_fill_n` / `clear` FUN_004339f0 / FUN_00431b00 / FUN_00431a30 / FUN_0055de70 / FUN_004378d0, `vector<AbstateBuffer>::push_back` FUN_004187c0, `basic_string::compare` FUN_00409710, `ListTraveler::lt_Next` FUN_00402740, ctors `MultiHitArgument` FUN_00434b30 / `BattleObjectStruct` FUN_00434bb0 / FUN_00434b70, `ITableBase<ActionEffectAbState>::GetTotal` FUN_005c7e70, `ProtocolPacket::pp_NetCommand` FUN_00401280 | none needed | library / container code with no game logic (the `List<T>` layout is in §7.5) |
