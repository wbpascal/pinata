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

### 1.2 Globals and structures

```pseudo
skillresultbuffer[64] (SkillResultBuffer, 0x18 bytes each)  @ 0x13283d18;  SkillResultBuffer::bufferpoint @ 0x13283d10
    { +0 ShineObject* target, +4 u32 resthp, +8 u8 isdamage, +9 IsCostumWeapon, +a IsCostumShield, +b iscritical,
      +c ismissed, +d isshieldblock, +e isheal, +f isenchant, +10 isresist, +11 isImmune, +14 u32 hpchange }
    # one slot per target of the current blast; bufferpoint is reset by sds_Initialize and read by sds_Finish (Z03 §5.6)
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

Rule-set slots (`sdi_DamageRule`, Z03 §4.2): 0x18 `roe_HitRate` (physical FUN_00502d30, magical FUN_00503360),
0x1c `roe_CalcDamage` FUN_00505c00 (Z03 §4.5), 0x20 `roe_IsDamageSkill` FUN_004ff840 (= `sdi_ServInf.UsualAttack`;
false without a skill), 0x2c `roe_HitRateByGlobalAction` (physical FUN_005055a0, magical FUN_005058d0).

## 2. `smo_SkillBlast`: one target, in code order  @ FUN_00581160

`ShineMobileObject::smo_SkillBlast(a = caster, s, d = target, empower, fixedDamage, hit, depth, bmpRate)`. Callers:
`sbe_BlastObject` FUN_00583bc0, `alsst_SkillBlast` FUN_00582de0, `alsst_SkillBlast_RandomTarget` FUN_00583180
(Z03 §5.6, Z17). `depth` is the chain step (1 for the first target), `bmpRate` the `AreaSkill` bitmap rate (1000 for
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

*(Continued in part 2: SS_HOLDME, the abstate keep-time specials, `so_SkillEnchant` / dispel run, SS_SUCKHP and the
multi-hit abstates from 0x582122 to the end.)*

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
        Lua ranking hook 0xac (fm_LuaScriptFuncExec) on a's map with heal = actual gain, then on t's map,
            each only if that object is a player and the map script has a RankingValue      # Z16 / Z09
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
    broadcast to a's sight (so_AllOfRange_Simple(a, …, 0); players only *(inferred: the simple broadcaster)*):
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

## 6. Not reconstructed / uncertain

- Part 2 (not yet written): `smo_SkillBlast` from 0x582122 (SS_HOLDME, SS_FIRETIMEADD / CURSETIMEADD /
  POSIONTIMEADD, `so_SkillEnchant`, the dispel runs, SS_SUCKHP, multi-hit abstates, item actions of d, the final
  `sds_TemplateStore`).
- `ShineObject::so_AllOfRange_Simple`'s receiver set for 0x245B (players in sight of the attacker) is *(inferred)*
  from the broadcaster's name.
- Client FUN_0057eeb0 calls in the 0x245B handler (own character hit): which HUD element they refresh is not traced.

## 7. Coverage boundary

(Completed in the sweep part.)

| Found | Covered by | Argument |
|---|---|---|
| `smo_JumpTo` FUN_0057db20, 0x482D | Z09 §9.3 (done) | movement helper with packet already documented |
| `so_SkillCure` / `so_Dispel` / `smo_Dispel` bodies | Z22 §7.5, Z23 §8 (done) | documented there; §5 adds only the data tables |
| `so_ply_Revival` FUN_0057ab90 | Z03 §7.3 (done) | revive by skill |
| `mdb_CanIKill` FUN_006424c0, `mdt_ArgumentLoad` FUN_004a6110, `so_mob_SkillParameterSet` FUN_005d2e90 | Z09 §5.1, §28.3 (done) | mob data and ExpandSkill checks |
| `so_ply_CheckDamageAbsorption` FUN_00579860, SpyAgent reports | Z09 (done) | damage absorb and aggro reports |
| `so_smo_LastDamageOperation` FUN_0040cbe0, HideDamage actor | Z22 §9.4, §9.7 (done) | abstate damage hooks |
