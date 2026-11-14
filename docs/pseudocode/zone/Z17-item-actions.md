# Zone server: item actions and costume weapon/shield charges (Z17)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read through the PDB re-analysis `re-data/exports/zone-pdb`
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Class, member and enum names come from
the NA2016 `Zone.pdb` (same build) *(pdb2016)* unless marked otherwise. Evidence markers as in `AGENTS.md`: *(pdb2017)*,
*(inferred)*, *(captured)*. SHN contents are from `Files/Server/2016/9Data/Shine` (decoded with `shn.py`; the
`TYPE_LIST_TWO_INX` (29) columns are 8 bytes = `{u32 enum, u32 value}`, which `shn.py` prints as empty strings).

Earlier work this builds on: Z01 §2 table-load list (the tables of §1.1 are loaded in `zs_start_sleep`), Z03 §4 (the
combat rule sets that query the item actions), Z04 §6 (equip / item use), Z07 §2 (`0x10D0` cool-time restore at login),
Z12 §2 (costume charge cells in `so_RecalcEquipParam`), Z04 §12.2 / Z05 §8.7 (costume charge refill).

`p` = the `ShineObjectClass::ShinePlayer`; `vt 0x…` = byte offset of a virtual slot in its vftable (`rtti.py`).

---

## 1. Item-action data model

An **item action** is a rule "when *condition* happens (with probability, in range), apply *effect*", attached to a
player by an equipped item, a socketed gem, a set bonus or an abnormal state. The rules live in four SHN tables; at
startup they are compiled into C++ objects: `Action` (one per `ItemActionID`) holding a `std::set<IActCondition*>` and a
`std::set<IActEffect*>`. The player keeps the actions that apply to it in an `ItemActionObserveManager` (vt 0x5d0,
part 2 / §2) that the combat and skill code queries at fixed hook points (§3).

### 1.1 Tables and loading

Loaded in `ZoneServer::zs_start_sleep` (Z01 §2, Z10 §5) in this order; each is a `Table::Load<T>(file)` that builds the
path from `GetTableDir()` + file name, calls `ITableBase<Row,T>::Load(path, true)` and on failure asserts
`"Fail to read  : <file>"` and calls `ShineExit` (zone stops). `ITableBase::Load` creates the singleton
`ms_pkTable` (0xC4 bytes: `CDataReader m_kDataReader` at +4, `char m_acFilename[128]` at +0x44), reads the file, checks
the SHN header `nVersionKey`, copies the file name and calls the virtual `DataProcess()` (vt +4).

| File | Loader `Table::Load<…>` / `ITableBase::Load` | VersionKey | Row struct (size) | Index built by `DataProcess` |
|---|---|---|---|---|
| ActionRangeFactor.shn | `ActionRangeFactors` @ FUN_005b59c0 / (ITableBase) | (not read here) | `ActionRangeFactor` (0xC) | `ActionRangeFactors::_rangeFactors` DAT_14d57594, `std::map<u32 ActionRangeIndex, row*>` @ FUN_005cf5a0 |
| ItemActionCondition.shn | `ItemActionConditions` @ FUN_005b5b00 / FUN_005b3310 | 0x117 (279) | `ItemActionCondition` (0x1E) | `ItemActionConditions::_conditions` DAT_14d575a4, `map<u16 ConditionID, IActCondition*>` @ FUN_005cf820 |
| ItemActionEffect.shn | `ItemActionEffects` @ FUN_005b5c40 / FUN_005b33f0 | 0x9A (154) | `ItemActionEffect` (0x16) | `ItemActionEffects::_effects` DAT_14d575b4, `map<u16 EffectID, IActEffect*>` @ FUN_005d0790 |
| ItemAction.shn | `ItemActions` @ FUN_005b5d80 / FUN_005b34d0 | 0x40 (64) | `ItemAction` (0xC) | `ItemActions::_actions` DAT_14d6fc84, `map<u16 ItemActionID, Action*>` @ FUN_005b78e0 |
| ActionEffectItem.shn | `ActionEffectItemTable` @ FUN_005b6000 / FUN_005b3690 | 0xE (14) | `ActionEffectItem` (5) | `ActionEffectItemTable::_actions` DAT_14d507e4, **multimap** `<u16 SHINE_ITEM_ID, row*>` @ FUN_005c80d0 |
| ActionEffectAbState.shn | `ActionEffectAbStateTable` @ FUN_005b6140 / FUN_005b3770 | 0x15 (21) | `ActionEffectAbState` (0x26) | none: `FindActionID` scans the rows (§1.8) |
| SetEffect.shn | `SetEffectTable` @ FUN_005b5ec0 / FUN_005b35b0 | – | `SetEffect {SetItemIndex, Count, ItemActionID}` | Z21 (set items); `SetEffectTable::FindActionID` FUN_005c7eb0 |

The order matters: conditions are built after `ActionRangeFactor` (a `RangeCondition` resolves its range row in its
constructor), and `ItemAction` last (it resolves condition and effect ids). Every "conflict" or "cannot find" below is
fatal: `AssertClass::ac_AssertFail` then `ShineExit(<function name>)`.

Row structs *(pdb2016; the 2016 SHN columns match byte for byte, `S01-shn-structs.tsv`)*:

```
ItemAction          { u16 ItemActionID; u16 ConditionID; u16 EffectID; u32 CoolTime (ms); u16 CoolGroupActionID }   # packed, 0xC
ItemActionCondition { u16 ConditionID;
                      ActionTargetType SubjectTarget; u32 SubjectTargetValue;      # one SHN column "SubjectTarget"
                      ActionTargetType ObjectTarget;  u32 ObjectTargetValue;       # one SHN column "ObjectTarget"
                      ActionActivityType ConditionActivity; u32 ConditionActivityValue;   # one SHN column
                      u16 ActivityRate (‰); u16 Range }                                                          # 0x1E
ItemActionEffect    { u16 EffectID; ActionTargetType EffectTarget; u32 EffectTargetValue;
                      ActionActivityType EffectActivity; u32 EffectActivityValue; u16 Value; u16 Area }             # 0x16
ActionRangeFactor   { ActionRangeType ActionRangeIndex; RangeFactor RangeType; u16 RangeStart; u16 RangeEnd }       # 0xC
ActionEffectItem    { u16 SHINE_ITEM_ID; u16 ItemActionID; u8 EnchantMaxLot }
ActionEffectAbState { char InxName[32]; u32 Strength; u16 ItemActionID }
```

C02 reports that the **2017** client PDB renamed the paired value columns (`SubjectTargetValue`, `EffectTargetValue`);
in the 2016 server PDB they already exist as struct members, and the 2016 SHN files store each pair as one 8-byte
`TYPE_LIST_TWO_INX` column, so the layouts agree.

Enums *(pdb2016)*:

- `ActionTargetType`: 0 `ATT_TargetType` (value = `TargetType`), 1 `ATT_MobGradeType` (`MobGradeType`), 2 `ATT_MobType`
  (`MobType`), 3 `ATT_ChrClassType` (`ChrClassType`).
- `ActionActivityType`: 0 `AAT_AttackType`, 1 `AAT_RecoverType`, 2 `AAT_ABSTATEINDEX`, 3 `AAT_DispelAttr`,
  4 `AAT_TargetAction`, 5 `AAT_SkillEffectIncreaseType`, 6 `AAT_ActionRangeType`, 7 `AAT_ActiveSkillGroupIndex`,
  8 `AAT_ActionETCType`, 9 `AAT_SetItemEffectType`.
- Sub-type enums (the `…Value` column): `AttackType` {0 NORMAL, 1 SKILL, 2 MAGIC, 3 PHYSIC, 4 CRITICAL, 5 MISS, 6 BLOCK};
  `RecoverType` {0 HP absolute +, 1 HP rate +, 2 SP absolute +, 3 SP rate +, 4 HP absolute −, 5 HP rate −, 6 SP absolute −,
  7 SP rate −}; `DispelAttr` {0 NONE, 1 GOOD, 2 DEBUFF, 3 DISEASE, 4 POISON, 5 CURSE, 6 STUN, 7 FEAR, 8 DEEPER, 9 HIDE,
  10 BOMB, 11 CHARGED}; `TargetAction` {0 TA_DIE}; `ActionRangeType` {0 HP_RATE_0_20, 1 Lv_0_40, 2 SP_ABSOLUTE_0_1000,
  3 Lv_0_19, 4 Lv_20_49, 5 Lv_50_79, 6 Lv_80_99, 7 Lv_100_150}; `ActionETCType` {0 AET_ITEMEQUIP, 1 AET_ITEMUSE};
  `SkillEffectIncreaseType` {0 DAMAGE_RATE_INCREASE, 1 COOLTIME_RATE_DECREASE, 2 KEEPTIME_RATE_INCREASE,
  3 USESP_RATE_DECREASE, 4 STA_AC_RATE_DECREASE, 5 AGGRO_RATE_INCREASE, 6 STA_DEX_RATE_DECREASE, 7 SS_RATE_THHPUP,
  8 STA_MAX_HPSP_RATE_INCREASE, 9 STA_DEAD_HPSP_RECOVER_RATE_INCREASE, 10 STA_SHIELDAC_RATE_INDREASE,
  11 HEAL_RATE_INCREASE, 12 STA_DOT_HEAL_RATE_INCREASE, 13 STA_WC_RATE_INCEASE, 14 STA_SHEILD_BLOCK_RATE_INCREASE};
  `SetItemEffectType` {0 DEFAULT, 1 DAMAGE_RATE_INCREASE}; ABSTATEINDEX = `AbState.shn.AbStataIndex`;
  ActiveSkillGroupIndex = `ActiveSkill` skill group (Z03 §3).
- `RangeFactor`: 0 `RF_HP_RATE` (‰ of max HP), 1 `RF_HP_ABSOLUTE`, 2 `RF_SP_RATE`, 3 `RF_SP_ABSOLUTE`, 4 `RF_LV`.

### 1.2 `ItemAction` rows → `Action`

```pseudo
ItemActions::DataProcess()                                                   @ FUN_005b78e0
    for each row r (file order):
        a = _actions.find(r.ItemActionID)
        if none:
            a = new Action(r)                                                  @ FUN_005b77b0
                # Action (0x2c) { u16 _ID; u32 _coolTime = r.CoolTime; u16 _coolGroupID = r.CoolGroupActionID;
                #                 set<IActCondition*> _conditions (+0xc); set<IActEffect*> _effects (+0x1c) }
                a.addCondition(r.ConditionID)                                  @ FUN_005b2380
                a.addEffect(r.EffectID)                                        @ FUN_005b23f0
            _actions.insert(r.ItemActionID → a); duplicate → fatal "ItemAction Element Conflict" (cannot happen after find)
        else:                                                                  # same ID again: inlined addCondition/addEffect
            a._conditions.insert(getCond(r.ConditionID))   none → fatal "Invalid ItemActionCondition-ID" / ShineExit("Action::addCondition")
            a._effects.insert(getEffect(r.EffectID))        none → fatal "Invalid ItemActionEffect-ID" / ShineExit("Action::addEffect")
            # r.CoolTime and r.CoolGroupActionID of the later rows are ignored (original bug) Z17-B1
    return true

ItemActionConditions::getCond(id)  @ FUN_005cf390 / ItemActionEffects::getEffect(id)  @ FUN_005d0740
    map lookup; missing → assert "Cannot find ItemActionCondition" / "Cannot find ItemActionEffect", return null
```

- One `Action` therefore means: **any** of its conditions × **all** of its effects (the evaluation is `Action::raise`,
  part 2 / §2). Conditions and effects are shared objects: two actions naming condition 212 hold the same pointer.
- The sets are ordered by pointer value, so two rows with the same (condition, effect) pair collapse into one
  (2016 data: actions 802 and 803 have duplicate rows).
- 2016 `ItemAction.shn`: 1114 rows, 762 distinct actions; 311 actions have a cool-down group. Groups and cool times
  (ms): 1 = 150000, 2 = 60000, 3 = 1250, 4 = 1500, 5 = 10000, 6 = 12000, 7 = 6000, 8 = 6000, 9/10/11 = 5000,
  12 = 0 (action 758, group without cool time), 13 = 150000. Only action 752 has rows with different cool data
  (`(0, 0)` first, `(1250, group 3)` second), so it loads without a cool-down (Z17-B1).

### 1.3 `ItemActionCondition` rows → condition objects

```pseudo
ItemActionConditions::DataProcess()                                          @ FUN_005cf820
    for each row c: _conditions.insert(c.ConditionID → MakeCondition(c)); duplicate id → fatal "ItemActionCondition ID Conflict"

MakeCondition(c)                                                             @ FUN_005cf640
    switch c.ConditionActivity:
        AAT_AttackType (0):           new AttackTypeCondition(c)         @ FUN_005cece0
        AAT_ABSTATEINDEX (2):         new ABStateCondition(c)            @ FUN_005ced30
        AAT_TargetAction (4):         new TargetActionCondition(c)       @ FUN_005ced80
        AAT_ActionRangeType (6):      new RangeCondition(c)              @ FUN_005cf3e0
        AAT_ActiveSkillGroupIndex (7): new ActiveSkillGroupCondition(c)  @ FUN_005cedd0
        AAT_ActionETCType (8):        new EtcCondition(c)                @ FUN_005cee20
        other (1 Recover, 3 Dispel, 5 SkillEffectIncrease, 9 SetItemEffect):
                                      fatal "Unexpected condition type" (ConditionID), ShineExit("::MakeCondition")

every constructor:                    # IActCondition (0x10) { vptr; _subjectValidator (+4); _objectValidator (+8); _conditionData (+0xc) }
    _conditionData   = c
    _subjectValidator = MakeValidator(c.SubjectTarget, c.SubjectTargetValue)
    _objectValidator  = MakeValidator(c.ObjectTarget,  c.ObjectTargetValue)
RangeCondition additionally (0x14, +0x10 _rangeData):
    _rangeData = ActionRangeFactors::_rangeFactors[c.ConditionActivityValue]
                 missing → fatal "Cannot find ActionRangeFactor", ShineExit("ActionRangeFactors::getRangeFactor")
```

The five non-range classes differ only in their vftable: all of them use the base methods, so the condition's
behaviour depends on `ConditionActivity` alone. vftables (`??_7…@@6B@`): `IActCondition` 006fe36c,
`AttackTypeCondition` 006fe37c, `ABStateCondition` 006fe38c, `TargetActionCondition` 006fe39c,
`ActiveSkillGroupCondition` 006fe3ac, `EtcCondition` 006fe3bc, `RangeCondition` 006fe430. Slots: +0 scalar deleting
destructor (FUN_005cf4c0: deletes both validators; plain destructor FUN_005cec30), +4 `_typeValidationCheck`
(FUN_005cec60 for all), +8 `_check` (FUN_005cec90; `RangeCondition::_check` FUN_005ceef0).

### 1.4 Target validators

```pseudo
MakeValidator(kind, value)                                                   @ FUN_005ceb60
    ATT_TargetType   → TargetTypeValidator{value}       (vftable 006fe33c)
    ATT_MobGradeType → MobGradeTypeValidator{value}     (006fe348)
    ATT_MobType      → MobTypeValidator{value}          (006fe354)
    ATT_ChrClassType → CharClassValidator(value)        (006fe360)  @ FUN_005ceaa0
    other            → null      # a null validator would crash in _check; the 2016 data has none
CharClassValidator(value): _value = {CCT_FIGHTER 0 → 1, CCT_ARCHER 1 → 11, CCT_CLERIC 2 → 6, CCT_MAGE 3 → 16,
                                     CCT_JOKER 4 → 21, CCT_SENTINEL 5 → 26}[value]   (other values, e.g. CCT_COMMON 6, kept as is)
```

`IObjectTypeValidator` (8 bytes) = `{ vptr; u32 _value }`; slot +4 `check(me, other)`. In a condition the subject
validator is called as `check(arg.me, arg.subject)` and the object validator as `check(arg.me, arg.object)` (§1.5).

```pseudo
TargetTypeValidator::check(me, other)                                        @ FUN_005ce860
    switch _value (TargetType):
        TARGET_ENEMY 0, TARGET_DAMAGEBYME 16:  return me.so_mobile_IsEnemy(other) (vt 0x72c) == 1
        TARGET_ME 1, TARGET_ATTACKME 15:       return me ≠ null and me == other
        TARGET_PARTY 2:                        return me.so_PartyRegistNumber() (vt 0x550, u16) ≠ 0xFFFF
                                                      and me.party == other.party
        TARGET_ALL 5, TARGET_THISACTION 14, TARGET_THISSKILL 17:  return true
        TARGET_ENEMYUSER 7:                    return me.IsEnemy(other) ≠ 0 and other.so_ObjectType() (vt 0x4d0) == 2 (player)
        TARGET_ENEMYGUILD 9:                   return me.so_mobile_GetGuildRegnum() (vt 0x828) ≠ 0
                                                      and CGuildZone::IsGuildEnemy(gGuild, me.guild, other.guild)
        TARGET_MYGUILD 10:                     return me.guild == other.guild          # no "≠ 0" test (original bug) Z17-B3
        TARGET_MYRAID 12:                      return me.so_GetRaidNumber() (vt 0x554, u16) ≠ 0xFFFF and me.raid == other.raid
        FRIEND 3, SPOT 4, GROUP 6, EVERY 8, MYNPC 11, BOX 13, NONE 18, other:  return false

MobGradeTypeValidator::check(me, other)                                      @ FUN_005cea20
    other ≠ null and (m = other.so_mob_DataBox() (vt 0x70c)) ≠ null and m.MobInfo.GradeType (+0x5f) == _value
MobTypeValidator::check(me, other)                                           @ FUN_005cea60
    other ≠ null and m ≠ null and m.MobInfo.Type (+0x63) == _value
        # players: vt 0x70c is a shared "return 0" body, so both mob validators are false for players
CharClassValidator::check(me, other)                                         @ FUN_005ceb20
    other ≠ null and other.so_CharacterClass() (vt 0x49c, ShineMobileObject::smo_CharClass).cc_ClassType() (vt 0x48) == _value
        # cc_ClassType returns the class line: CharClassFighter… 1, CharClassCleric 6 (also HighCleric…),
        # CharClassArchar 11, CharClassMage 16, CharClassJoker 21, CharClassSentinel 26; the base CharClass and
        # CharClassMob return 0, so a mob never matches
```

`me` is the owner of the item action (the player whose manager runs it); which object becomes `subject` and `object`
is set by each hook point (§3). Note that `TARGET_ATTACKME` is tested as identity with `me` here; whether that is
meaningful depends on how the callers fill the argument: §3.4.2 (the hook puts the attacked owner in `object`, so
both are "that slot is the owner").

### 1.5 Condition test

```pseudo
IActCondition::check(arg)                                                    @ FUN_005cee70
    if not this._typeValidationCheck(arg) (vt +4): return false
    if RandomBox::rb_1000() > c.ActivityRate: return false      # rb_1000 ∈ [0, 999] (Z09 knowledge §2): chance = (ActivityRate+1)/1000 (original bug) Z17-B5
    if arg.subject ≠ null and arg.object ≠ null and so_DistanceSquar(arg.subject, arg.object) > c.Range²: return false
    return this._check(arg) (vt +8)

IActCondition::_typeValidationCheck(arg)                                     @ FUN_005cec60
    return c.ConditionActivity == arg.condition.type and c.ConditionActivityValue == arg.condition.subtype
        # i.e. the hook point announces "what happened" (e.g. AAT_AttackType / AT_CRITICAL) and only conditions
        # written for exactly that event pass

IActCondition::_check(arg)                                                   @ FUN_005cec90
    return _subjectValidator.check(arg.me, arg.subject) and _objectValidator.check(arg.me, arg.object)

RangeCondition::_check(arg)                                                  @ FUN_005ceef0
    if not _subjectValidator.check(arg.me, arg.subject): return false        # the object validator is not consulted
    v = switch _rangeData.RangeType:                                         # always measured on arg.me
        RF_HP_RATE:     me.so_GetHP() × 1000 / me.so_MaxHP()          (vt 0x4e8 / 0x4f0; unsigned)
        RF_HP_ABSOLUTE: me.so_GetHP()
        RF_SP_RATE:     me.so_GetSP() × 1000 / me.so_MaxSP()          (vt 0x4ec / 0x4f4)
        RF_SP_ABSOLUTE: me.so_GetSP()
        RF_LV:          me.so_GetLevel() & 0xFF                        (vt 0x4d8)
        other:          return false
    return RangeStart ≤ v < RangeEnd                                         # upper bound exclusive (original bug) Z17-B2
```

`ActionRangeFactor.shn` (2016, 8 rows): 0 HP_RATE 0–200 ‰, 1 LV 0–40, 2 SP_ABSOLUTE 0–1000, 3 LV 0–19, 4 LV 20–49,
5 LV 50–79, 6 LV 80–99, 7 LV 100–150. With the exclusive bound, levels 19, 40, 49, 79, 99 and 150 are outside the
ranges whose names include them (Z17-B2). In the 2016 condition data only `HP_RATE_0_20` is used (one condition), so the
level gaps are latent.

`ItemActionArgument` (0x1C) *(pdb2016)*, cleared by its constructor @ FUN_0042aad0 (types = `MAX_ACTIONACTIVITYTYPE`,
sub-types 0, objects null):

```
struct ItemActionArgument {
    struct { ActionActivityType type; u32 subtype; } condition;   # +0  what happened (the event of the hook point)
    struct { ActionActivityType type; u32 subtype; } effect;      # +8  which effect kind the hook point wants back
    ShineObject* me;        # +0x10  the observer (item-action owner)
    ShineObject* subject;   # +0x14  acting object of the event
    ShineObject* object;    # +0x18  the other object of the event
}
# subtype is a union: AttackType / ABSTATEINDEX / TargetAction / ActionRangeType / ActiveSkillGroupIndex / ActionETCType
# (condition) and AttackType / RecoverType / ABSTATEINDEX / DispelAttr / SkillEffectIncreaseType / ActionETCType /
# SetItemEffectType (effect)
```

### 1.6 `ItemActionEffect` rows → effect objects

```pseudo
ItemActionEffects::DataProcess()                                             @ FUN_005d0790
    for each row e: _effects.insert(e.EffectID → MakeEffect(e)); duplicate id → fatal "ItemActionEffect ID Conflict"

MakeEffect(e)                                                                @ FUN_005d0060
    if e.EffectTarget (kind) ≠ ATT_TargetType: fatal "USE TargetType for EffectTarget", ShineExit("::MakeEffect")
    switch e.EffectActivity:                       # IActEffect (8 bytes) = { vptr; ItemActionEffect* _effectData }
        AAT_AttackType 0:              AttackTypeEffect          (vftable 006fe5a0)
        AAT_RecoverType 1:             RecoverTypeEffect         (006fe5c0)
        AAT_ABSTATEINDEX 2:            AbStateTypeEffect         (006fe5e0)
        AAT_DispelAttr 3:              DispelAttrTypeEffect      (006fe600)
        AAT_SkillEffectIncreaseType 5: ActionImpowerTypeEffect   (006fe620)
        AAT_SetItemEffectType 9:       ActionEffectTypeEffect    (006fe66c)
        AAT_ActionETCType 8:           fatal "ActionETCType Effect is exist yet"
        other (4, 6, 7):               fatal "Unexpected condition type"   # text copied from MakeCondition (original bug) Z17-B4
```

Effect vftable slots (names from the PDB publics of `IActEffect`; +4/+8 order *(inferred)*, both are empty in every class):

| Slot | Method | Base `IActEffect` (006fe56c) | Overrides |
|---|---|---|---|
| +0 | scalar deleting destructor | FUN_005d05c0 | – |
| +4 / +8 | `takeOn(obj)` / `takeOff(obj)` | empty (shared body FUN_00549070) | none |
| +0xc | `equipTick(obj, obj)` | empty (FUN_00509900) | `AbStateTypeEffect::equipTick` FUN_005cfee0 |
| +0x10 | `fallback(arg)` → u32 | returns 0 (FUN_004a9c90) | `ActionImpowerTypeEffect::fallback` FUN_005cffc0, `ActionEffectTypeEffect::fallback` FUN_005d0010 |
| +0x14 | `_execute(arg, target)` → u32 | pure (`_purecall`) | `AttackTypeEffect` FUN_005d0000 (returns `Value`; also used by `ActionImpowerTypeEffect` and `ActionEffectTypeEffect`), `RecoverTypeEffect` FUN_005cfc70, `AbStateTypeEffect` FUN_005cff20, `DispelAttrTypeEffect` FUN_005d05f0 |
| +0x18 | `_typeValidationCheck(arg)` | FUN_005cfb50 | `AttackTypeEffect::_typeValidationCheck` FUN_005cfb80 (also for `ActionImpowerTypeEffect` / `ActionEffectTypeEffect`) |

```pseudo
IActEffect::_typeValidationCheck(arg)                                        @ FUN_005cfb50
    return arg.effect.type ∉ {AAT_AttackType, AAT_SkillEffectIncreaseType, AAT_SetItemEffectType}
        # "immediate" effects (recover, abstate, dispel) run whenever the hook point does not ask for a value
AttackTypeEffect::_typeValidationCheck(arg)                                  @ FUN_005cfb80
    return (u16)e.EffectActivity == arg.effect.type and e.EffectActivityValue == arg.effect.subtype
        # "value" effects only answer a hook point that asks for exactly their kind and sub-type
AttackTypeEffect::_execute(arg, target)                                      @ FUN_005d0000
    return e.Value
```

So there are two kinds of effects: **value effects** (`AttackType`, `SkillEffectIncrease`, `SetItemEffect`) return a
number to the hook point that asked for them (a rate or a bonus, `ActionResults`, part 2), and **immediate effects**
(`Recover`, `AbState`, `Dispel`) change the target directly. `IActEffect::execute` (FUN_005d0210), the effect bodies
and the area application (`Area`, `AxialListNearExecution_*`) are part 2 (§2).

### 1.7 Where action ids come from

```pseudo
ActionEffectItemTable::GetByID(itemID) → first ActionEffectItem row of that item or null      @ FUN_005c80a0
ActionEffectItemTable::doWithActionIDs<ItemAcion_Add>(itemID, {player})                       @ FUN_0048c8c0
    for each row with SHINE_ITEM_ID == itemID (multimap equal range):
        if player.so_AddItemAction(row.ItemActionID, itemID) (vt 0x5d8) ≠ 1: return false        # stops at the first failure
    return true
ActionEffectItemTable::doWithActionIDs<ItemAcion_Del>(itemID, {player})                       @ FUN_0048c970
    same with player.so_DelItemAction (vt 0x5dc)
ActionEffectAbStateTable::FindActionID(inxName, &out)                                         @ FUN_005c7f40
    null arguments → 0; linear scan; first row whose InxName == inxName (strcmp; Strength ignored) → out = ItemActionID, 1; else 0
```

Sources of actions on a player (callers in part 3): equipped items and socketed gems via `ActionEffectItem`
(`EnchantMaxLot` is read by the gem-socket handler, Z04 `sp_NC_ITEM_ENCHANT_ADD_GEM_REQ` FUN_00522560), set bonuses via
`SetEffect.ItemActionID` (Z21), abnormal states via `ActionEffectAbState` (the 2016 file has **no rows**, so no abstate
grants an action in 2016).

### 1.8 The 2016 data in short

- `ActionEffectItem.shn`: 372 items, one action each. 345 are gems (`ITEMCLASS_ENCHANT` 34: `EnM_<MobType>_…`
  vs a mob type, `EnC_<Class>_…` vs a player class, `EnS_…` generic; `EnchantMaxLot` 0/10/30/50), 24 weapons and 3
  shields: the `WarH…` set (action 758: 1 ‰ on a skill hit / 20 % (rate 200) on a normal hit → abstate 587
  `StaBRNWarHWpn` on the damaged target) and the `Karen_…` set (weapons 802, shield 803: on item use (`AET_ITEMUSE`) →
  abstate 670 `StaLCWCMAUp` / 687 `StaLCACMRUp` on self, cool time 150 s, groups 1 / 13).
- `ItemActionCondition.shn` (322 rows), by `ConditionActivity`: `AttackType` 202 (NORMAL 86, SKILL 86, CRITICAL 30),
  `ActiveSkillGroupIndex` 116 (subject ME, object ALL: "when I use a skill of group n"), `ActionETCType` 3 (ITEMEQUIP 2,
  ITEMUSE 1), `ActionRangeType` 1 (HP below 20 %). Subjects are `TARGET_ME` except 4 rows `TARGET_ALL` and 10 rows with a
  `MobType` subject; objects are `TARGET_ALL`/`TARGET_ME`, a `MobType` or a `ChrClassType`. `Range` is 2400 everywhere;
  `ActivityRate` 1–1000 ‰. No condition uses `ABSTATEINDEX` or `TargetAction`.
- `ItemActionEffect.shn` (202 rows), by `EffectActivity`: `ABSTATEINDEX` 87, `SkillEffectIncrease` 52, `Recover` 44,
  `SetItemEffect` 2 (`DAMAGE_RATE_INCREASE`); none uses `AttackType` or `DispelAttr`. `EffectTarget` values: ME 88,
  THISSKILL 36, DAMAGEBYME 31, THISACTION 17, PARTY 17, ATTACKME 7, ENEMY 6. `Area` is 0 except 400 / 800 on 23 abstate
  effects (area application, §2.6).

---

## 2. Item-action runtime engine

Every player owns one `ItemActionObserveManager` (`ShinePlayer::sp_ItemActionObserves`, `p+0x2a920`), built in the
`ShinePlayer` constructor @ FUN_0055bc80 and returned by `so_GetItemActionObserves` (vt 0x5d0). Mobs have none: the mob
slot 0x5d0 is a shared "return 0" body, and every caller tests the pointer first. The manager holds the actions the
player currently has (one *observer* per action source) and the running cool-down groups. A hook point (§3) builds an
`ItemActionArgument` (§1.5), asks the manager to run it, and gets back the list of successful results.

### 2.1 Structures *(pdb2016)*

```
class ItemActionObserveManager {                                   # 0x24
    vector<ItemActionObserve*> iaom_Observes;                      # +0x00  in insertion order
    vector<GroupCoolTime>      iaom_CoolTimeList;                  # +0x10
    ShineObject*               iaom_pObject;                       # +0x20  the owner (SetObject @ FUN_005d0890, from the ShinePlayer ctor)
}
struct GroupCoolTime { TickTimer CoolTimer; u32 ActionGroupID; u32 ActionID; u32 LastCheckTime; }      # 0x1c
class  TickTimer     { u32 m_CurDelayTime; u32 m_DelayTime; bool m_bEnable; u32 m_PrevCheckTime; }      # 0x10
class ItemActionObserve {                                          # 0x14 (vptr at +0)
    u16 iao_ListHandle;   # +4   slot in the pool
    Action* iao_pAction;  # +8   null = free
    u16 iao_ActionID;     # +0xc 0xFFFF = free
    u16 iao_itemid;       # +0xe the item (or gem) that granted the action
    bool iao_IsEnchant;   # +0x10 the source is a gem (ITEMCLASS_ENCHANT)
}
struct ActionResult { bool checkSuccess; u32 value; }             # 8
class  ActionResults { vector<ActionResult> m_Results; }           # what a hook point collects
```

- **Constructor / destructor**: `ItemActionObserveManager()` @ FUN_005d1910 zeroes both vectors and the owner;
  `~ItemActionObserveManager()` @ FUN_005592c0 only frees the two vectors. It does **not** give the observers back to the
  pool; that relies on `Clear` having run before (lifecycle in §3).
- **Observer pool**: `ItemActionObserveBuffer` @ FUN_005d1430, a function-local static (`ItemActionObserveBuffer::Instance`,
  DAT_14d575c8, built on first use, guard bit `_S4 & 1`) = `List<ItemActionObserve>` of **5000** slots
  (`l_MakeList(5000)`, Z09 §28.11 for `List<T>`) whose contents point into `iaob_buffer[5000]`. The pool is shared by
  all players of the zone process; `ItemActionObserve()` @ FUN_005d0830 only sets the vftable.

### 2.2 Adding and removing actions

```pseudo
ItemActionObserveManager::AddAction(obj, actionID, itemID) → bool                    @ FUN_005d17f0
    if obj == null: return false                      # obj is only null-tested
    a = ItemActions::_actions.find(actionID).value    # no end() test: an unknown id reads the map head node (original bug) Z17-B7
    if a == null: return false
    o = pool.alloc()  (pool full, free finger 0xFFFF, or alloc null → assert "ItemActionObserveBuffer::alloc Buffer Full", return false)
    o.iao_ListHandle = slot
    o.Attach(a, actionID, itemID)                                                        @ FUN_005d0850
        o.iao_pAction = a; o.iao_ActionID = actionID; o.iao_itemid = itemID
        o.iao_IsEnchant = (itemdatabox[itemID] exists and its Class == ITEMCLASS_ENCHANT (34))
    iaom_Observes.push_back(o)
    return true
    # no duplicate test: the same (action, item) pair can be added several times (e.g. two equal items worn)

ItemActionObserveManager::DelAction(obj, actionID, itemID) → bool                    @ FUN_005d15e0
    if obj == null: return false
    first o in iaom_Observes with o.iao_ActionID == actionID and o.iao_itemid == itemID:
        remove it from the vector (order kept); o.iao_pAction = null; o.iao_ActionID = 0xFFFF
        pool.free(o.iao_ListHandle)   fail → assert "ItemActionObserveManager::DelAction Can`t Free"
        return true                   # only one observer per call
    return false

ItemActionObserveManager::Clear()                                                    @ FUN_005d16e0
    for each o: o.iao_pAction = null; o.iao_ActionID = 0xFFFF; pool.free(o.iao_ListHandle)
                (fail → assert "ItemActionObserveManager::Clear Can`t Free")
    iaom_Observes.clear()             # the cool-down list is kept
```

The player wrappers `so_AddItemAction` / `so_DelItemAction` (vt 0x5d8 / 0x5dc) and their callers are §3.

### 2.3 Running a hook point

```pseudo
ItemActionObserveManager::_EventRun(results, arg, itemFilter) → bool                 @ FUN_005d1df0
    if results == null or arg == null or arg.me == null: return false
    for each o in iaom_Observes (index loop, insertion order):
        o == null → assert "ItemActionObserveManager::EventRun NULL Observer"; continue
        o.iao_pAction == null → assert "ItemActionObserveManager::EventRun NULL Action"; continue
        if itemFilter ≠ 0xFFFF and itemFilter ≠ o.iao_itemid: continue
        if not IsActiveGroup(o.iao_pAction._coolGroupID): continue                   # group on cool-down
        r = o.EventRun(arg)                                                          # = o.iao_pAction.raise(arg)
        if r.checkSuccess:
            results.push_back(r)
            SetCoolTime(a._coolTime, a._coolGroupID, o.iao_ActionID)                 # §2.5 (no-op when _coolTime == 0)
            if o.iao_IsEnchant: arg.me.so_ply_EnchantActionUse(o.iao_itemid)         # vt 0x5e4, §2.7 (the gem uses one charge)
    return results.m_Results not empty      # also true when the vector already held results from an earlier call

EventRun(results, arg)                        = _EventRun(results, arg, 0xFFFF)      @ FUN_005d1f30
EventRunByItemUse(results, arg, itemID)       = _EventRun(results, arg, itemID)      @ FUN_005d1f20
    # only the actions granted by that item take part (callers and their argument: §3)

EventRunBySkillGroupIndex(results, skill, seit, me, object) → bool                  @ FUN_005d1f50
    if skill == null or me == null or results == null: return false
    arg = { condition = {AAT_ActiveSkillGroupIndex, ·}, effect = {AAT_SkillEffectIncreaseType, seit},
            me = me, subject = me, object = object }
    any = false
    for each group g in skill.sdi_ActiveSkillGroups (vector of pointers):
        arg.condition.subtype = g+0x20 (the group index)
        if _EventRun(results, arg, 0xFFFF): any = true *(inferred: the decompiler shows a constant byte)*
    return any

EventRun_IncDmgRate(subject, object, attackType, results) → bool                    @ FUN_005d2010
    if results == null or subject == null or object == null: return false
    arg = { condition = {AAT_AttackType, attackType}, effect = {AAT_SetItemEffectType, SIET_DAMAGE_RATE_INCREASE (1)},
            me = iaom_pObject, subject, object }
    return _EventRun(results, arg, 0xFFFF)
```

`ItemActionObserve::EventRun(arg)` @ FUN_005d1250: null `arg` → assert "ItemActionObserveBuffer::EventRun pArgument is
NULL", null action → assert "…iao_pAction is NULL"; both return `{false, 0}`; otherwise `Action::raise(arg)`.

Reading the results (the hook points pick one per value they want):

```pseudo
ActionResults::GetRateAppliValue(base) → u32                                          @ FUN_005d0c20
    if base == 0: return 0
    for each r: base = r.value × base / 1000        # integer, in result order: rates chain multiplicatively (‰)
    return base
ActionResults::GetPlusAppliValue() → u32                                              @ FUN_005d0c80
    return Σ r.value                                # flat bonus (hit / crit / block rate points)
```

### 2.4 `Action::raise`: conditions, then effects

```pseudo
Action::raise(arg) → ActionResult                                                    @ FUN_005d10d0
    r = { checkSuccess = false, value = 0 }
    for each c in _conditions (set order = pointer order):
        r.checkSuccess = c.check(arg)               # §1.5; every tested condition rolls its own ActivityRate
        if r.checkSuccess: break                    # any one condition is enough
    if not r.checkSuccess:
        for each e in _effects: r.value = e.fallback(arg)      # vt +0x10; value thrown away by _EventRun
        return r
    for each e in _effects: r = e.execute(arg)       # §2.6; every effect runs, the LAST one decides the result
    return r
```

With several effects, the action's result is the result of the last effect in the set, i.e. of the effect object with
the highest address (normally the highest `EffectID`, since they are allocated in file order *(inferred)*). An effect that
does not answer the asked value kind returns `{false, fallback}`, so it can hide the answer of an earlier effect of the
same action (original bug) Z17-B6. 2016 data: 17 actions have two effects. Actions 196, 197, 199, 201, 204 combine two
`SkillEffectIncrease` effects of different sub-types (e.g. 196 = `SEIT_USESP_RATE_DECREASE` 750 (effect 18) +
`SEIT_STA_DOT_HEAL_RATE_INCREASE` 1250 (effect 105)): only the sub-type of the last effect can ever be granted; action 200
has two of the same sub-type (`SEIT_COOLTIME_RATE_DECREASE` 750 and 900): only one of the values is used. The other 11
(747–756, 761: `AET_ITEMEQUIP` → two abstates on the wearer; 752 an HP heal + abstate) are immediate effects and run
both.

The `fallback` values (base `IActEffect::fallback` 0 (FUN_004a9c90, an identical-code-folded "return 0" body);
`ActionImpowerTypeEffect::fallback` @ FUN_005cffc0: 1000 when `EffectActivity == arg.effect.type` and the sub-type is
< 15, else assert "Unknown effect.subtype.actionImpowerType" and 0; `ActionEffectTypeEffect::fallback` @ FUN_005d0010:
1000 for sub-type `SIET_DAMAGE_RATE_INCREASE`, for `SIET_DEFAULT` assert "Unknown effect.subtype.actionEffectType" and
still 1000, other → assert and 0) are the neutral rate 1000 ‰ *(inferred intent)*, but no caller ever reads them:
`_EventRun` keeps only results with `checkSuccess`.

### 2.5 Cool-down groups and `0x482C`

```pseudo
ItemActionObserveManager::IsActiveGroup(group) → bool                                @ FUN_005d0cc0
    for each t in iaom_CoolTimeList:
        if t.ActionGroupID == group and t.LastCheckTime ≠ g_Now: return false
    return true
    # an entry created in the current tick (g_Now = clockwatch.cw_CurrTick, 0.1 s, Z09 knowledge) does not block yet:
    # other actions of the same group may still fire in that tick (e.g. one AoE skill hitting several targets)

ItemActionObserveManager::SetCoolTime(coolMs, group, actionID)                        @ FUN_005d1b60
    if coolMs == 0: return
    if any t.ActionGroupID == group: assert "ItemActionObserveManager::SetCoolTime ActionIDGroup" (group); return
        # the second success of a group in the same tick: its cool-down is not restarted, no packet
    t = { CoolTimer: m_DelayTime = coolMs × 10 / 1000 (0.1 s units, truncated), enabled, started now;
          ActionGroupID = group, ActionID = actionID, LastCheckTime = g_Now }
        # the setter called is an identical-code-folded body named UseEffect::UseItemRide::uir_SetSkill @ FUN_00653a60 (writes +4)
    iaom_CoolTimeList.push_back(t)
    if iaom_pObject ≠ null:
        Send to the owner (vt 0x2f8 so_GetDataSocketStream → .vt 0xc) 0x482C NC_SKILL_ITEMACTIONCOOLTIME_CMD {
            u16 num = 1
            { u16 ItemActionID = actionID; u16 ItemActionGroupID = group; u32 SecondCoolTime = coolMs }
        }   # 10 bytes; Packet-Too-Long assert text is copied from "GuildTourmentSystem::PlayerRegiste"

ItemActionObserveManager::UpDate()            # every so_Routine pass of a live player (so_Routine @ FUN_0056c790, §3)   @ FUN_005d1930
    for each t in iaom_CoolTimeList:
        if TickTimer::CheckUpdateEvent_ClockWatch(t.CoolTimer, g_Now): erase t           # @ FUN_00592050
    # no packet: the client counts the cool-down down itself
TickTimer::CheckUpdateEvent_ClockWatch(now):  if enabled: cur += now − prev; prev = now;
                                              if cur > delay: cur −= delay; return true.   return false

ItemActionObserveManager::ResetCoolTime()                                            @ FUN_005d1a00
    Send to the owner 0x482C { u16 num = n; n × { ItemActionID, ItemActionGroupID, SecondCoolTime = 0 } }   # 4 + 8n bytes
    iaom_CoolTimeList.clear()
    # caller: the GM command &iareset (Z11 §7.4)
ItemActionObserveManager::CoolTimeListClear()  → iaom_CoolTimeList.clear(), no packet          @ FUN_005d19b0
```

Layout of `0x482C`: `docs/protocol/packets-zone.md` (verified, `PROTO_NC_SKILL_ITEMACTIONCOOLTIME_CMD`); the client
handler `GameFrameWork::On_NC_SKILL_ITEMACTIONCOOLTIME_CMD` (2016 FUN_0049c600) and the save / restore of the list
(`SendCoolTimes2Client/DB/World`, `0x10D0`) are §3. The cool-down is per group, not per action: all actions of one
group share it. 2016 groups and times: §1.2. A group-0 action never gets an entry because every 2016 action with a
cool time has a group (only action 758 has group 12 with cool time 0).

### 2.6 Effects: target selection and bodies

```pseudo
IActEffect::execute(arg) → ActionResult                                              @ FUN_005d0210
    if not this._typeValidationCheck(arg) (vt +0x18, §1.6): return { false, this.fallback(arg) }
    me = arg.me; other = (arg.subject ≠ me) ? arg.subject : arg.object
    switch e.EffectTargetValue (TargetType):
        TARGET_ME 1, TARGET_THISACTION 14, TARGET_THISSKILL 17:
            return { true, this._execute(arg, me) }          # value effects return e.Value here
        TARGET_ENEMYUSER 7:   if other.so_ObjectType() (vt 0x4d0) == 2: return { true, _execute(arg, other) }
        TARGET_ATTACKME 15, TARGET_DAMAGEBYME 16:
                              if me.so_mobile_IsEnemy(other) (vt 0x72c): return { true, _execute(arg, other) }
        TARGET_ENEMY 0:       area(AxialListNearExecution_Enemy{me},          includeSelf = 0)
        TARGET_PARTY 2:       me.so_PartyRegistNumber() (vt 0x550) == 0xFFFF → fail;
                              area(AxialListNearExecution_Party{party},       includeSelf = 1)
        TARGET_ALL 5:         area(AxialListNearExecution_All,                includeSelf = 1)
        TARGET_ENEMYGUILD 9:  me guild (vt 0x818 so_mobile_GetGuildRegnum) == 0 → fail;
                              area(AxialListNearExecution_EnemyGuild{guild},  includeSelf = 0)
        TARGET_MYGUILD 10:    guild == 0 → fail; area(AxialListNearExecution_MyGuild{guild}, includeSelf = 1)
        TARGET_MYRAID 12:     me.so_GetRaidNumber() (vt 0x554) == 0xFFFF → fail;
                              area(AxialListNearExecution_MyRaid{raid},       includeSelf = 1)
        other (3, 4, 6, 8, 11, 13, 18): fail
    fail = return { false, this.fallback(arg) }
    area(filter, includeSelf):
        me.so_AllOfRange(AllOfRangeArgument (DAT_132826b4), centre = me location, radius = e.Area, no fan,
                         visitor = filter, includeSelf, 0xFFFF)                        # FUN_0054bc80, Z09 knowledge
            # radius 0 means the map's sight range (Z09): the 2016 PARTY / ENEMY abstate effects use 400 or 800
        filter.apply(this, arg)
        return { true, 0 }       # success even when nobody was in range: the cool-down still starts
```

Area application (`IAxialListNearExecution` = `AxialListNearScan` with a 200-entry buffer, *(pdb2016)*):

```pseudo
AxialListNearScan::ali_Work(obj, d²) (visitor slot +0, shared by all filters)       @ FUN_004c1cf0
    keep obj when its mode (vt 0x484 smo_GetMode) ∉ {0 spawning, 3 dead}, filter.alns_ValidObject(obj) (vt +4),
    fewer than 200 kept, and obj has neither STA_IMMORTAL (291) nor STA_ADLFLOUSSIERIMT (499) (vt 0x3e4 so_AbnormalState_IsSet)
IAxialListNearExecution::apply(effect, arg)                                          @ FUN_005cf9c0
    for each kept obj: if obj mode ≠ 3: effect._execute(arg, obj) (vt +0x14)
alns_ValidObject:
    _Enemy      @ FUN_005cfa20: me.so_mobile_IsEnemy(obj) == 1                  (ctor FUN_005cf8c0, _me)
    _Party      @ FUN_005cfa40: obj.so_PartyRegistNumber() == _partyRegisterNum (ctor FUN_005cf900)
    _All        @ FUN_005cfa70: obj.so_ObjectType() ∈ {2 player, 5 mob, 8 bandit} (kinds: Z09 knowledge)
    _EnemyGuild @ FUN_005cfac0: CGuildZone::IsGuildEnemy(gGuild, _guildRegisterNum, obj guild (vt 0x828))   (ctor FUN_005cf930)
    _MyGuild    @ FUN_005cfaf0: obj guild (vt 0x818) == _guildRegisterNum       (ctor FUN_005cf960)
    _MyRaid     @ FUN_005cfb20: obj.so_GetRaidNumber() == _raidRegisterNum      (ctor FUN_005cf990)
    vftables 006fe508 / 51c / 530 / 544 / 558 / 58c; slot +8 AxialListNearScan::alns_GetBMPDamageRate, +0xc FUN_005d01e0 (scalar deleting dtor)
```

Effect bodies (`t` = the target chosen above; all return 0):

```pseudo
RecoverTypeEffect::_execute(arg, t)                       # sub-type = RecoverType, v = e.Value      @ FUN_005cfc70
    RT_HPABSOLUTEPLUS 0:  t.so_GainHP(v) (vt 0x504);                  Send_SETITEMHEALEFFECT(t, heal = 1, v)
    RT_HPRATEPLUS 1:      t.so_GainHP(t.MaxHP × v / 1000);            Send_SETITEMHEALEFFECT(t, 1, t.MaxHP × v / 1000)
    RT_SPABSOLUTEPLUS 2:  t.so_GainSP(v) (vt 0x4fc)
    RT_SPRATEPLUS 3:      t.so_GainSP(t.MaxSP × v / 1000)
    RT_HPABSOLUTEMINUS 4, RT_HPRATEMINUS 5 (d = v or t.MaxHP × v / 1000):
        d = t.vt 0xdb4 so_smo_LastDamageOperation(t.vt 0xbe8 (player: so_ply_CheckDamageAbsorption FUN_00579860; mob:
            returns d unchanged), 0)                     # shields / absorption, as in the swing damage (Z03 §3.2)
        if d < t.HP: t.so_DamagedBy(arg.me, d, 1000, 1) (vt 0x5c0)
        else:        t.so_KilledBy(arg.me, t.HP) (vt 0x5bc)                  # the item action can kill
        Send_SETITEMHEALEFFECT(t, heal = 0, d)
    RT_SPABSOLUTEMINUS 6: t.so_LostSP(v) (vt 0x4f8)
    RT_SPRATEMINUS 7:     t.so_LostSP(t.MaxSP × v / 1000)
    always: t.so_mobile_NotifyParameterChange(1) (vt 0x34)
    # SP changes send no 0x206F; MaxHP / MaxSP are vt 0x4f0 / 0x4f4

AbStateTypeEffect::_execute(arg, t)                       # sub-type = ABSTATEINDEX, v = e.Value (strength)   @ FUN_005cff20
    entry = dic_abstate.as_FromIndex(sub-type); null → return
    if t.so_AbnormalState_Resist(entry) (vt 0x634, Z03 §6.2): return                     # resisted
    if arg.condition == {AAT_ActionETCType, AET_ITEMEQUIP} or arg.condition.type == AAT_ActionRangeType:
        this.equipTick(arg.me, t)                                                        # vt +0xc
    else:
        t.so_AbnormalState_Set_Simple(arg.me, sub-type, v, broadcast = 1) (vt 0x644)     # @ FUN_004163d0
AbStateTypeEffect::equipTick(me, t)                                                     @ FUN_005cfee0
    t.so_AbnormalState_Set_Simple(me, sub-type, v, 1, 2500, keep = −1, EF_JUSTENCHANTGLOBALACTION (12)) (vt 0x640)   # @ FUN_004164c0

DispelAttrTypeEffect::_execute(arg, t)                                                  @ FUN_005d05f0
    for each active element x of t's abstate list (vt 0x52c so_mobile_AbstateList, asl_GetAbstateList):
        if dic_abstate.as_FromIndex(x.index).DispelIndex == e.Value: AbstateElementInObject::ase_Terminate(x)
    # compares e.Value, not the DispelAttr sub-type (original bug) Z17-B8 (latent: no 2016 effect is a dispel)
AttackTypeEffect::_execute = return e.Value  (§1.6; also the slot of ActionImpowerTypeEffect / ActionEffectTypeEffect)
```

The two abstate helpers (generic `ShineObject` code, documented here because no other item gives their bodies):

```pseudo
so_AbnormalState_Set_Simple(setter, idx, strength, broadcast) → bool  (vt 0x644)          @ FUN_004163d0
    idx ≥ 0x318 → assert "AbnormalStateDictionary::AbState::as_FromIndex : Invalid skill idx", false
    entry = dic_abstate.as_StateIndexList[idx]; entry null or entry.subabstate[strength].assa_info null → false
    ok = so_AbnormalState_Set(setter, entry.AbStataIndex, strength, entry, g_Now, 0, 0xFFFFFFFF, 0, 0, 0) (vt 0x638, Z03 §6.2)
    if ok and broadcast:
        so_AbnormalState_BitSet(idx); vt 0x3f0(idx, entry.subabstate[g_NewAbstateStrength].KeepTime, 1)
        so_AbnormalState_BroadcastSet(idx, that KeepTime, g_NewAbstateStrength)
    return ok or not broadcast
so_AbnormalState_Set_Simple(setter, idx, strength, broadcast, arg5, keep, origin) → bool  (vt 0x640)   @ FUN_004164c0
    idx > 0x317 → assert, false; entry null → false
    if origin == EF_JUSTENCHANTGLOBALACTION and this.so_AbnormalState_IsSet(idx) (vt 0x3e4): broadcast = false
    ok = so_AbnormalState_Set(setter, entry.AbStataIndex, strength, entry, g_Now, 0, 0xFFFFFFFF, arg5, origin, 0)
    if ok and broadcast: BitSet; vt 0x3f0(idx, keep, 1); BroadcastSet(idx, keep, strength)
    return ok
```

So an `AET_ITEMEQUIP` or HP-range abstate is set through the "global action" path with keep time −1 (a state that
stays while the source is worn *(inferred)*; how it is removed again is §3), and re-equipping refreshes it without a
second broadcast. Abstates from attack / skill / item-use conditions use the state's own keep time.

### 2.7 Packets sent by the effects

```pseudo
Send_SETITEMHEALEFFECT(t, heal, amount)                                               @ FUN_005cfbb0
    if t == null: return
    Broadcast to the players around t (AxialListPacketBroadcast, so_AllOfRange radius 0 = sight, includeSelf = 1)
    0x206F NC_ACT_SETITEMHEALEFFECT {                        # 5 bytes, PROTO_NC_ACT_SETITEMHEALEFFECT (pdb2016)
        u16 who      = t's zone handle (so_GetZoneHandle_ItemLooter, identical-code-folded handle getter)
        u8  flag     : bit 0 isheal = heal (1 = HP gained, 0 = HP lost); bits 1–7 left as they were in the send buffer
        u16 hpchange = amount (truncated to 16 bits)
    }
```

Client `GameFrameWork::On_NC_ACT_SETITEMHEALEFFECT` (2016 FUN_0049bd20): `TextEffMgr::AddNumTextEff(who, hpchange,
style = isheal × 4 | 1)`: a floating number over the object, heal and damage in two styles. Nothing else changes on the
client (the HP bar follows from the normal HP updates sent by `so_GainHP` / `so_DamagedBy`).

```pseudo
ShinePlayer::so_ply_EnchantActionUse(gemItemID)   (vt 0x5e4; mobs: empty body)          @ FUN_00562cb0
    # a gem action has fired: the gem in the equipped weapon loses one charge
    cell = p.so_ply_EquipWeapon(&inv) (vt 0x7ac); if cell == null or gemItemID == 0xFFFF: return
    copy = the weapon's item attribute; removed[3] = 0; anyRemoved = false
    for socket i in 0..2 (each {u16 gemID, u8 restCount}):
        if socket.gemID == gemItemID and socket.restCount ≠ 0xFF (0xFF = unlimited):
            if restCount == 0: assert "ShinePlayer::so_ply_EnchantActionUse RestCount Empty"
            else: restCount −= 1                                     # written into the live item
            Send to the player (vt 0x2fc so_GetGameSocketStream) 0x3046 NC_ITEM_ENCHANT_SET_GEM_LOT_CMD {
                ITEM_INVEN equipment = inv; u8 gemSocketIndex = i; u8 restCount }   # 4 bytes
            if restCount == 0:
                copy.socket[i] = { 0xFFFF, 0xFF }; removed[i] = 1; anyRemoved = true   # the gem is used up
    if anyRemoved:
        lock = p.sp_Item.invenlocklist current index
        p.so_ply_GetInventoryLockList() (vt 0x7d4).vt +0x40(lock, cell, &copy, inv, inv)   # lock the cell with the new attribute
        Send to CharDB 0x3498 NC_ITEMDB_ENCHANT_REMOVE_GEM_REQ {     # 0x24 bytes, PROTO (pdb2016); D03 FUN_004236e0
            hdr { u16 handle = p+4; u32 charNo = so_GetCharRegistNumber (vt 0x344) }
            u16 itemLockIndex = lock
            equipment { u64 key = the weapon's item key; u16 id = iic_ItemIdent(cell); ITEM_INVEN cell = inv }
            remover   { 12 bytes never written: whatever the send buffer held (original bug) Z17-B9 }
            u8 gemSlot[3] = removed;  u8 needItem = 0
        }   # Packet-Too-Long assert text says "sp_NC_ITEM_ENCHANT_REMOVE_GEM_REQ"
        lock list .icl_IncIndex()
    # the CharDB answer 0x3499 goes to the same handler as a manual gem removal (Z04 §10.2; §3)
```

Client `GameFrameWork::On_NC_ITEM_ENCHANT_SET_GEM_LOT_CMD` (2016 FUN_004b3260): accepts `equipment` only in the
equipped (`>> 10 == 9`, slot < 0xC0) or inventory (`== 8`, slot < 0x1E) store, sets the socket's rest count on the
item (`item.vt 0x50(gemSocketIndex, restCount)`), and refreshes the open `EnchantGemWin` (`SignGemSuccess`) and the gem
tooltip. 2016 lots: `ActionEffectItem.EnchantMaxLot` 0 / 10 / 30 / 50 (§1.8; how a lot becomes `restCount` when the gem
is socketed is §3). Because every successful gem action (each hit, each crit) uses a charge, the 10…50 lots are
spent quickly; the gem item itself is gone once its socket is cleared.

### 2.8 `so_ItemActonAbstateApp`: skill-group rates on a state just cast

```pseudo
ShineMobileObject::so_ItemActonAbstateApp(element, skill, target)  (vt 0x5d4)           @ FUN_0055dea0
    # called after a skill set the abnormal state `element` on `target` (callers so_SkillEnchant / smo_SkillBlast, §3)
    if element, skill, target all set and this.so_GetItemActionObserves() (vt 0x5d0) ≠ null:
        for seit in [SEIT_STA_AC_RATE_DECREASE 4, SEIT_STA_DEX_RATE_DECREASE 6, SEIT_STA_MAX_HPSP_RATE_INCREASE 8,
                     SEIT_STA_DEAD_HPSP_RECOVER_RATE_INCREASE 9, SEIT_STA_SHIELDAC_RATE_INDREASE 10,
                     SEIT_STA_DOT_HEAL_RATE_INCREASE 12, SEIT_STA_WC_RATE_INCEASE 13, SEIT_STA_SHEILD_BLOCK_RATE_INCREASE 14]:
            results = {}
            if manager.EventRunBySkillGroupIndex(results, skill, seit, me = this, object = target):
                element.aeo_SetItemActionEffect(seit, results.GetRateAppliValue(1000))
AbstateElementInObject::aeo_SetItemActionEffect(seit, rate)                            @ FUN_00510810
    SetItemAbstateEffect::siae_SetItemEffectAndValue(&element.aeo_SetItemEffect, seit, rate)    @ FUN_00510170
        i = first of the 4 EffectBuffers whose eb_Index − 1000 == seit, or the first free one (eb_Index 0)
        none (4 used) → assert "…siae_SetItemEffectAndValue : Too many effect"; return
        buffer[i] = { eb_Index = 1000 + seit, Argument_Base1000 = rate }
```

The `1000 + seit` buffers are read when the state's owner recalculates its parameters (`siae_ParameterRefit`, Z12 §2.5:
1004 AC, 1006 Dex, 1008 MaxHP/SP, 1010 and 1014 shield AC, 1013 WC) and by the set-item value getters
(`siae_GetArgument_Base1000ByEffect` FUN_00510090; set-item subsystem, Z21). The state therefore carries the caster's
item-action bonus: e.g. a gem "+25 % to the AC debuff of skill group n" makes that debuff 25 % stronger. Only
`SkillEffectIncrease` effects with target `THISSKILL` / `THISACTION` answer here (§1.6).

---

## 3. Item-action lifecycle and hook points

Where actions are added to and removed from a player (§3.1–§3.3), which game events run them and how each fills
`ItemActionArgument` (§3.4), and how the cool-down list survives map changes and logouts (§3.5–§3.6). Only players own a
manager: `vt 0x5d0 so_GetItemActionObserves` returns `&p.sp_ItemActionObserves` for a `ShinePlayer` and null for every other
object, so every hook below starts with "if X has a manager".

### 3.1 Login: cool-time restore, then the action setup

```pseudo
WM 0x104C NC_CHAR_REGISTNUMBER_ACK → ShinePlayer::so_SetRegistNumber(ack)           @ FUN_0044e900 (Z01 §4)
    … (char data request 0x101C to the WM, skill list clear, view/deco slots cleared, …)
    p.so_GetItemActionObserves().CoolTimeListClear()           # @ FUN_005d19b0: the list a reused player object still held

WM 0x10D0 NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD {                                     @ FUN_0044e710 (Z07 §1.2)
        NETPACKETZONEHEADER { u16 clienthandle; u32 charregistnumber }               # (pdb2016)
        u16 num; ActionCooltime group[num] { u16 actionID; i64 expiredTime (time64) } }   # 8 + 10·num bytes
    p = player by clienthandle; null, charregistnumber ≠ p charNo, or p closing (vt 0x300):
        assert "…Invalid player", kick (0x689); return
    m = p.vt 0x5d0(); now = _time64()
    for each record:
        a = ItemActions::_actions.find(actionID).value          # no end() test (original bug) Z17-B11
        if expiredTime ≤ now or a == null: next
        m.SetCoolTime((expiredTime − now) × 1000 (low 32 bits, ms), a._coolGroupID (+8), a._actionID (+0))   # §2.5
            # each restored entry sends its own one-entry 0x482C to the client
    # Z07 §1.2 calls the key "group"; the 2016 PDB names it ActionCooltime.actionID and the code looks it up in
    # ItemActions::_actions (push order checked at 0x44e843…0x44e865)

client 0x1803 NC_MAP_LOGINCOMPLETE_CMD → sp_NC_MAP_LOGINCOMPLETE_CMD @ FUN_00443390 (Z01 §6):
    p.sp_EquipTick = Metronome(20 ticks = 2 s)                 # the equip/range hook of §3.4.1
    p.sp_ItemActionSetup()

ShinePlayer::sp_ItemActionSetup()                                                    @ FUN_00566420
    m.Clear()                                                  # §2.2: all observers back to the pool, cool-downs kept
    seenSets = []                                              # vector<string>
    for slot in 0 .. 29 (equipment box, ci_Equipment vt 0):
        cell = equipment[slot]; empty or no ItemDataBox row: next
        doWithActionIDs<ItemAcion_Add>(itemID, p)              # §1.7, itemID as filter key
            fail → assert "ShinePlayer::so_GetItemActionObserves itemAction Can`t Add ActionID. ShineItemID=" (id)
        if ItemInfo.Class == ITEMCLASS_WEAPON:
            for each of the 3 gem sockets ({u16 gemID, u8 restCount}, 3-byte stride after the item key):
                doWithActionIDs<ItemAcion_Add>(gemID, p)       # itemID = gemID → observer IsEnchant (gem charge use, §2.7)
                    fail → same assert with the gem id   # empty socket 0xFFFF has no row: nothing added, no assert
        set = ItemInfo.SetItemIndex
        if set ∉ seenSets:                                     # each set once, even when several pieces are worn
            seenSets.push_back(set)
            n = p.so_EqualSetitemIndexNameCount(set) (vt 0x5cc, @ FUN_00549a70; Z21)      # pieces of that set worn
            for i in 1 .. n:
                if SetEffectTable::FindActionID(set, i, &id) (@ FUN_005c7eb0: row name == set and count +0x20 == i
                                                               → id = row+0x21 ItemActionID):
                    p.so_AddItemAction(id, 0xFFFF) fail → assert "ShinePlayer::so_GetItemActionObserves Setitem Can`t Add ActionID"
        # items without a set have SetItemIndex "" and go through the same lookup once (no SetEffect row has an
        # empty name in 2016 *(inferred)*, so nothing is added)
    for each abstate e in p's abstate list (vt 0x52c, +0xcb0):
        if ActionEffectAbStateTable::FindActionID(e.InxName, &id) == 1:      # §1.7; no rows in 2016
            p.so_AddItemAction(id, 0xFFFF) fail → assert "…Abstate Can`t Add ActionID"
    m.SendCoolTimes2Client()                                   # §3.5: the full list restored from 0x10D0
```

All failures only assert; the player keeps whatever was added. So the set bonus actions at login are **all levels
1…n** of every worn set, each with item filter 0xFFFF.

`ShinePlayer::so_AddItemAction(actionID, itemID)` @ FUN_00560840 (vt 0x5d8) and `so_DelItemAction` @ FUN_00560880
(vt 0x5dc) forward to `ItemActionObserveManager::AddAction` / `DelAction(p, actionID, itemID)` (§2.2) when the manager
exists (always, for a player).

### 3.2 Equip, unequip, drop

Equipment changes go through the inventory lock list (Z05 §1, §5.1): the request reserves releasers, the CharDB
answer applies them in order. Two releasers carry the item actions:

| Lock-list slot (`InventoryCellLockList` vftable 006bb37c) | Reservation | Releaser apply |
|---|---|---|
| +0x50 `icl_EquipLocation(lock, slot, cell, otherSlot, otherCell)` @ FUN_00489380 | after the cell exchange | `InvenCellReleaser_EquipLocation::icr_Apply` @ FUN_0048ca20 |
| +0x54 `icl_UnEquipInfo(lock, slot, cell)` @ FUN_004894b0 | before the cell exchange | `InvenCellReleaser_UnEquipInfo::icr_Apply` @ FUN_0048cc60 |

```pseudo
InvenCellReleaser_EquipLocation::icr_Apply(p, lc)                                    @ FUN_0048ca20
    p.so_ply_ChangeBriefInfo (vt 0x608)(lc.equipcell, slot); if otherslot ≠ −1: same for (othercell, otherslot)   # Z05 §1.3
    p.vt 0x57c(); p.vt 0x4b4(handle, …) with the position saved and restored around it          # recalc + look rebroadcast
    cell = lc.equipcell; if cell and p is a ShinePlayer with a manager and the item has an ItemDataBox row:
        doWithActionIDs<ItemAcion_Add>(itemID, p)   fail → assert "InventoryLocking::InvenCellReleaser_EquipLocation::icr_Apply itemaction Can`t Add ActionID. ShineItemID="
        weapon: the 3 gem ids, same (same assert text)
        n = p.vt 0x5cc(set)                                    # the cell already holds the new item: n counts it
        if SetEffectTable::FindActionID(set, n, &id): p.so_AddItemAction(id, 0xFFFF)
            fail → assert "…icr_Apply Setitem Can`t Add ActionID"
        # only the set level n is added; levels 1…n−1 are already there from the earlier pieces (or from §3.1)

InvenCellReleaser_UnEquipInfo::icr_Apply(p, lc)                                      @ FUN_0048cc60
    the mirror image with doWithActionIDs<ItemAcion_Del> (@ FUN_0048c970) for the item and its gems, and
    so_DelItemAction(FindActionID(set, n), 0xFFFF) with n counted while the piece is still worn
    assert texts "ShinePlayer::sp_NC_ITEM_EQUIP_REQ … Can`t Del ActionID" (copied from the request handler)
```

Who reserves them: `sp_NC_ITEM_EQUIP_REQ` @ FUN_0052b8d0 (Z04 §5.1) reserves, for each conflicting piece that must come
off, `UnEquipInfo(slot, equipCell)` → cell change → `EquipLocation(inventory slot, equipCell, −1)` (applied after the
move, the equip cell is empty, so it adds nothing), and for the target slot `UnEquipInfo(slot, cell)` when the slot holds
an item, the two cell changes, then `EquipLocation(slot, cell)`. So a **swap** removes the old item's actions before the
new ones are added; unequip `sp_NC_ITEM_UNEQUIP_REQ` (Z04 §5.4, Z05 §5.1 `0x3414`) reserves `UnEquipInfo` + cell change.
The ring and minimon equips (`0x3010` @ FUN_0052c5b0, `0x3050` @ FUN_0052d020, Z04 §5.2/§5.3) and the unequip request
(@ FUN_0053a990) reserve the same releasers (lock-list slots +0x50 / +0x54).

Set levels on unequip: removing a piece removes level n only; level n−1 … 1 stay, matching the n−1 pieces still worn.
`DelAction` removes the first observer with that `(actionID, 0xFFFF)` pair (§2.2), so set observers stay consistent as long
as every add has its del.

```pseudo
ShinePlayer::so_ply_ItemAction_UnEquip(cell)   (vt 0x5e0)                             @ FUN_00565020
    # only caller: ItemInventory::ii_DropAll @ FUN_00529a70 (Z04 §3.1, Z05 §3.1) for a cell of the equipment box, before
    # the cell is cleared (the "drop everything" path does not go through the lock list)
    if cell == null or no manager or item id 0xFFFF or no ItemDataBox row / ItemInfo: return
    doWithActionIDs<ItemAcion_Del>(itemID, p)                  fail → assert "ShinePlayer::so_ply_ItemAction_UnEquip. ShineItemID="
    weapon: the 3 gem ids, same
    n = p.vt 0x5cc(set); if SetEffectTable::FindActionID(set, n, &id) == 1: p.so_DelItemAction(id, 0xFFFF)
        fail → assert "ShinePlayer::so_ply_ItemAction_UnEquip. SetItem Can`t Del ActionID"
```

### 3.3 Gems and abnormal states

```pseudo
sp_NC_ITEM_ENCHANT_ADD_GEM_REQ (Z04 §10.1)                                           @ FUN_00522560
    the new socket's restCount = ActionEffectItemTable::GetByID(gemID).EnchantMaxLot (§1.7, @ FUN_005c80a0)
        EnchantMaxLot 0 → restCount 0xFF (unlimited, never decremented by §2.7)
        no ActionEffectItem row → assert "…Not Find ActionEffectItemTable", restCount 0
        # Z04 §10.1 calls this lookup "EnchantSocketRate"; it is GetByID → EnchantMaxLot
CharDB 0x3497 → ITEMDB_ENCHANT_ADD_GEM_ACK                                           @ FUN_00522fc0 (Z05 §8.2)
    after the apply: if the weapon is equipped: doWithActionIDs<ItemAcion_Add>(gemID, p)
CharDB 0x3499 → gds_NC_ITEMDB_ENCHANT_REMOVE_GEM_ACK                                 @ FUN_005233d0 (Z05 §8.2)
    reads the gem ids of the flagged sockets before the apply; equipped weapon: doWithActionIDs<ItemAcion_Del>(gemID, p)
    the request's remover cell is read only when useRemover (+0x1b) ≠ 0 (GameLog); the gem-charge path sends
    needItem = 0, so the stale remover bytes of Z17-B9 are never used
```

Gem charge use (`so_ply_EnchantActionUse`, §2.7) and the window until `0x3499`: the socket keeps
`{gemID, restCount 0}` in the live item, and the gem's observer stays, until the CharDB answer applies the copy and deletes
the action. Every further success of that gem's action in this window asserts "RestCount Empty", sends `0x3046`
(`restCount` 0) again, reserves another lock on the weapon cell and sends another `0x3498` (the lock result is not checked)
(original bug) Z17-B12. If the CharDB refuses the removal, the `{gemID, 0}` socket stays and so does its action, firing
for free.

Abnormal states: `AbnormalStateContainer::ase_AttachObject` @ FUN_00401d40 / `ase_DetachObject` @ FUN_00402000
call `ActionEffectAbStateTable::FindActionID(state InxName)` and add / delete that action with item 0xFFFF. With the empty
2016 `ActionEffectAbState.shn`, no state carries an action.

### 3.4 Hook points: the events that run the actions

Notation: `{type, subtype}` for `arg.condition` and `arg.effect` (§1.5); "immediate" = `effect = {MAX_ACTIONACTIVITYTYPE, 0}`
(or any type that is not one of the three value kinds), which runs Recover / AbState / Dispel effects (§2.6); `att` / `def`
= attacker / defender. Every run uses `EventRun` (all observers, §2.3) unless noted.

#### 3.4.1 Periodic, item use, kill

```pseudo
ShinePlayer::so_Routine (each pass, mode vt 0x484 ≠ 0)                               @ FUN_0056c790
    m.UpDate()                                                 # §2.5: expired cool-downs dropped, no packet
    … every sp_EquipTick (2 s) after the HP/SP/LP/party informs:
        EventRun { cond {AAT_ActionETCType, AET_ITEMEQUIP}, effect {AAT_ABSTATEINDEX, 0}, me = subject = object = p }
        sp_LevelChangeRoutineEvent(); sp_HPChangeRoutineEvent(); sp_SPChangeRoutineEvent()

sp_LevelChangeRoutineEvent()                                                         @ FUN_00565790
    lv = p level; arg { cond {AAT_ActionRangeType, ·}, immediate, me = subject = object = p }
    if lv ≤ 40: run with subtype Lv_0_40 (1)
    run with the first of: lv < 20 → Lv_0_19 (3), < 50 → Lv_20_49 (4), < 80 → Lv_50_79 (5), < 100 → Lv_80_99 (6),
                            ≤ 150 → Lv_100_150 (7)              # RangeCondition re-checks with RangeEnd exclusive (Z17-B2)
sp_HPChangeRoutineEvent()                                                            @ FUN_00565600
    if HP × 100 / MaxHP < 20: run {AAT_ActionRangeType, HP_RATE_0_20 (0)}, immediate, me = subject = object = p
sp_SPChangeRoutineEvent()                                                            @ FUN_005656d0
    always run {AAT_ActionRangeType, SP_ABSOLUTE_0_1000 (2)}, immediate, me = subject = object = p
```

AbState effects under an `AET_ITEMEQUIP` or `ActionRangeType` condition go through `AbStateTypeEffect::equipTick`
(§2.6): `so_AbnormalState_Set_Simple(…, arg5 = 2500, keep = −1, EF_JUSTENCHANTGLOBALACTION)` @ FUN_004164c0 passes 2500
as the state's **keep time in ms** to `so_AbnormalState_Set` (vt 0x638, Z03 knowledge: `(setter, idx, strength, entry,
g_Now, 0, flag, keepMs, how, origin)`), and −1 only as the keep time shown to the client (vt 0x3f0, broadcast). So the
state lasts 2.5 s and the 2-s tick renews it while the item is worn / the range holds; nobody removes it explicitly: it
runs out at most 2.5 s after unequip or after HP / level leaves the range *(inferred: renewal of an already-set state
is Z03's `so_AbnormalState_Set`)*. The client is told "no end time" and gets no second broadcast on renewal.

```pseudo
sp_NC_ITEM_USE_REQ (Z04 §6) on an equipped cell → ShinePlayer::sp_ItemUseReq_Equip(slot, cell, info)   @ FUN_005415d0
    if info == null or no manager: return                      # no answer at all in that case
    results = EventRunByItemUse(itemID = info.ID,
              { cond {AAT_ActionETCType, AET_ITEMUSE}, immediate, me = subject = object = p })    # only that item's observers
    p.so_ply_ItemUseResultPacket(results ? 0x700 : 0x722, 8)   # vt 0x91c @ FUN_0045e610 → 0x3016 NC_ITEM_USE_ACK (Z04 §6)
        # 0x700 success; 0x722 = no action fired (on cool-down, condition roll failed, or the item has none); 0x722
        # has no entry in client-error-codes.json
```

The 2016 `Karen_…` weapons / shield are the only `AET_ITEMUSE` items (§1.8): "use" an equipped one to get a 150-s
buff, then the group cool-down (`0x482C`).

```pseudo
ShineMobileObject::so_KilledBy(killer, …)  (the dead object's routine)                @ FUN_00432240
    … after the death scripts / guild-tournament hook:
    if killer has a manager:
        EventRun on killer { cond {AAT_TargetAction, TA_DIE}, immediate, me = subject = killer, object = the dead }
    # no 2016 condition uses AAT_TargetAction (§1.8): latent
```

#### 3.4.2 Normal attacks (swing) and the rule-set rates

```pseudo
ShineMobileObject::smo_SwingDamage(def, …)  (att = this)                              @ FUN_00432f30 (Z03 §4.2)
    … after damage, hit lists and the 0x2448 / 0x2449 sends (no hit / miss test before this block):
    kind = AT_PHYSIC if att.smo_RulesOfNormalAttack == roe_normalPY, AT_MAGIC if roe_normalMA, else AT_NORMAL
    if att has a manager: me = att, subject = att, object = def; immediate
        EventRun cond {AAT_AttackType, AT_NORMAL}; EventRun cond {AAT_AttackType, kind}
    if def has a manager: me = def, subject = att, object = def; same two runs
    # Z03 §4.2's "item-action triggers" comment on att.vt 0xbf8 is wrong: vt 0xbf8 is so_ply_PassiveSetAbstate
    # (@ FUN_005798e0, passive-skill states); the item actions are this block
```

The rule sets (`RulesOfEngagement*`, Z03 §4) ask value effects. In every function below one `ActionResults` vector
collects the results of **all** its runs and is never cleared in between, while the running total adds
`GetPlusAppliValue()` (the sum over the whole vector) after each run. A result from an earlier run is therefore counted
again by every later run (original bug) Z17-B10 (latent in 2016: no effect uses `AAT_AttackType`, §1.8).

```pseudo
roe_CriticalRateByGlobalAction(ctx) → ‰    (roe vt 0x24)
    NormalPY @ FUN_00504b10 / NormalMA @ FUN_00504c20:
        me = subject = att, object = def; effect {AAT_AttackType, AT_CRITICAL}
        total  = Σ after EventRun cond {AttackType, AT_NORMAL}
        total += Σ after EventRun cond {AttackType, AT_PHYSIC (PY) | AT_MAGIC (MA)}
    PhisycalSkill @ FUN_00504d30 / MagicalSkill @ FUN_00504ee0:
        run cond AT_PHYSIC | AT_MAGIC; if total ≥ 1000: return total
        if ctx.sklinfo: run cond AT_SKILL; then for each active skill group g: run cond {AAT_ActiveSkillGroupIndex, g+0x20}
    # called by roe_CalcDamage only when the normal crit roll failed: second roll rand1000 < total (Z03 §4.5)

roe_ShieldBlockByGlobalAction(ctx) → ‰    (roe vt 0x28; the only implementation is NormalPY @ FUN_00505090, so every rule set uses it *(inferred: no other class defines it in the PDB)*)
    effect {AttackType, AT_BLOCK}, cond {AttackType, AT_NORMAL}, subject = att, object = def
    if def has a manager: me = def, run;  if att has a manager: me = att, run
    # used in roe_HitRate: rand1000 < total → shield block (Z03 §4.3)

roe_HitRateByGlobalAction(ctx) → ‰    (roe vt 0x2c)
    effect {AttackType, AT_MISS}, subject = att, object = def; each run first on def (me = def), then on att (me = att)
    NormalPY @ FUN_005051c0 / NormalMA @ FUN_005053b0: cond AT_NORMAL (def, att), then AT_PHYSIC | AT_MAGIC (def, att)
    PhisycalSkill @ FUN_005055a0 / MagicalSkill @ FUN_005058d0: cond AT_PHYSIC | AT_MAGIC (def, att);
        if total ≥ 1000: return 0;  if ctx.sklinfo: AT_SKILL (def, att), then each active skill group (def, att)
    return 1000 − min(total, 1000)                              # the chance the hit is not evaded
```

Who answers what follows from the validators (§1.4): in a run on `def`, `me = def` and `subject = att`, so a subject
validator `TARGET_ME` fails and only conditions whose subject accepts the attacker (`TARGET_ALL`, a `MobType`, …) and
whose object is `TARGET_ME` / `TARGET_ATTACKME` (= "the object is me") pass. In a run on `att`, `me = subject = att`, so
subject `TARGET_ME` ("I attack") passes. This answers the open point of §1.4: `TARGET_ATTACKME` and `TARGET_ME` are the
same identity test, and the hook decides whether the owner is the attacker or the attacked through `subject` / `object`.
The same condition subtype (`AT_NORMAL`, `AT_SKILL`, …) is used on both sides. Note that a run on `att` with effect
`AT_BLOCK` adds to the **defender's** block chance and `AT_MISS` lowers the attacker's own hit chance; which side's
bonus is meant is left to the data (none in 2016).

```pseudo
RulesOfEngagement::roe_CalcDamage(ctx)                                                @ FUN_00505c00 (Z03 §4.5)
    crit = rand1000 < roe.vt 4(ctx) + ctx.crirateadd
    if not crit and att has a manager: crit = rand1000 < roe_CriticalRateByGlobalAction(ctx)    (vt 0x24, above)
        # an item-action crit goes straight to roe_CriticalStun, skipping the multi-hit damage-rate test of a normal crit
    if def has a manager and crit:                              # the defender's answer to a crit
        arg { cond {AttackType, AT_CRITICAL}, me = def, subject = att, object = def }
        effect {AttackType, AT_BLOCK}:  v = Σ;  if rand1000 < v: crit = 0; ctx.isshieldblock = 1; return 0
        effect {AttackType, AT_MISS}:   v = Σ (includes the AT_BLOCK results, Z17-B10); if rand1000 < v: crit = 0; ctx.ismiss = 1; return 0
        immediate:                      EventRun (e.g. a state on the attacker, "when I am hit critically")
    if att has a manager and crit:
        EventRun on att { cond {AttackType, AT_CRITICAL}, immediate, me = subject = att, object = def }
    … damage (roe vt 8 / 0xc / 0x10 = roe_AttackPower below)

roe_AttackPower(ctx)                                    NormalPY @ FUN_00506660, NormalMA @ FUN_005068d0
    min, max = roe_MinWC, roe_MaxWC (+ the HP-loss condition params, Z03)
    results = []
    a = att has a manager and EventRun_IncDmgRate(att, def, AT_NORMAL, results)     # me = att (§2.3)
    d = def has a manager and EventRun_IncDmgRate(att, def, AT_NORMAL, results)     # me = def, subject = att, object = def
    if a or d: min = GetRateAppliValue(results, round(min)); max = GetRateAppliValue(results, round(max))   # ‰ chained
    return (min + rb_largerandom(max − min)) × att.param+0x858 / 1000
                                                        PhisycalSkill @ FUN_00506b40, MagicalSkill @ FUN_00506ed0
    min / max first get the skill's MinWC(Rate) / MaxWC(Rate) and the empower damage step (Z03); then the same with
    AT_SKILL, plus on att EventRunBySkillGroupIndex(results, skill, SEIT_DAMAGE_RATE_INCREASE, att, def) when the skill
    has active skill groups; all results in one vector, one GetRateAppliValue per bound (no double count here)
```

`EventRun_IncDmgRate` asks `{AAT_SetItemEffectType, SIET_DAMAGE_RATE_INCREASE}`: the two 2016 `SetItemEffect` rows.
A defender-side success multiplies the damage the defender **takes** (there is no decrease kind), so such conditions
need a subject that excludes the attacker.

#### 3.4.3 Skills

```pseudo
AxialListScanSkillTarget::alsst_SkillBlast(skill, empower, n, …)                      @ FUN_00582de0
AxialListScanSkillTarget::alsst_SkillBlast_RandomTarget(…)                            @ FUN_00583180
    if the caster has a manager: for each target t (the first n scanned, 8-byte stride / the random target list):
        EventRun on caster { cond {AttackType, AT_SKILL}, immediate, me = subject = caster, object = t }
        EventRun on caster { cond {AttackType, AT_PHYSIC if SkillHitType == SHT_FROM_PY_NORMAL_HITRATE else AT_MAGIC}, … }
    # runs before the per-target smo_SkillBlast, so before hit / miss is known *(inferred from the order)*

ShineMobileObject::smo_SkillBlast(skill, t, …)  (caster = this)                       @ FUN_00581160 (Z03 §5, Z09)
    caster-side value lookups, each EventRunBySkillGroupIndex(results, skill, kind, caster, t) when the caster has a
    manager (and, where noted, the skill has active skill groups), then v = GetRateAppliValue(results, v):
        SEIT_AGGRO_RATE_INCREASE:     v = (setEffect[12] − 1000) + ServerInfo.AggroPerDamage → bos_DamageRateAggro
        SEIT_HEAL_RATE_INCREASE:      v = HEALAMOUNT (heal skills; runs on ctx.att with ctx.def)
        SEIT_SS_RATE_THHPUP:          v = bos_MyHealHit after a successful HPUPRATE roll
        SEIT_KEEPTIME_RATE_INCREASE:  v = FIRETIMEADD (→ t.so_smo_AbStateKeepTimeAdd (vt 0xa5c)(0x53, v)), CURSETIMEADD (→ states 0x23, 0x32…0x37,
                                      0x39), POSIONTIMEADD (→ 0x21), and the keep time of each abstate the skill sets (groups required)
    target side, if t has a manager (twice: in the buff / enchant branch, and in the damage branch only on multi-hit step 0):
        EventRun on t { cond {AttackType, AT_SKILL}, immediate, me = t, subject = caster, object = t }
        EventRun on t { cond {AttackType, AT_PHYSIC | AT_MAGIC by SkillHitType}, … }
```

Other `EventRunBySkillGroupIndex` users (all `me = subject = caster`, §2.3), each scaling one value with
`GetRateAppliValue`:

| Caller | `SkillEffectIncreaseType` | Value scaled | object |
|---|---|---|---|
| `ShinePlayer::smo_ply_SkillCoolTime` @ FUN_0055b6a0 | `SEIT_COOLTIME_RATE_DECREASE` | both cool times (after the set-item `SET_COOLTIMERATE`); any change → `so_ply_NewSkillCoolTime` (vt 0x374) with `(cool − elapsed)/1000` s | null |
| `CharaterSkillList::csl_SPCheck` @ FUN_0055b920 | `SEIT_USESP_RATE_DECREASE` | SP cost (after `SET_SPCONSUMRATE` and `so_smo_SPExhByAbState` vt 0xa60, before the per-state SP hooks) | null |
| `ShineMobileObject::so_SkillEnchant` @ FUN_00431ca0 | `SEIT_KEEPTIME_RATE_INCREASE` | keep time of each abstate a buff skill sets | the target |
| `ShineMagicField::so_mgcfld_MagicFieldSpread` @ FUN_0057ea30 / `_Friend` @ FUN_0057ee80 | `SEIT_KEEPTIME_RATE_INCREASE` | the field's vanish time (Z09 §12.3) | caster |
| `AxialListMagicFieldHeal::almfh_ApplyHeal` @ FUN_0056d2c0 | `SEIT_HEAL_RATE_INCREASE` | heal amount per tick (Z09 §12.3) | the healed |
| `so_ItemActonAbstateApp` @ FUN_0055dea0 | several | the state just cast (§2.8) | |
| `roe_AttackPower` (skills, above) | `SEIT_DAMAGE_RATE_INCREASE` | damage bounds | def |

With `object = null` (cool time, SP), the distance test of §1.5 is skipped and an object validator other than
`TARGET_ALL` / `THISACTION` / `THISSKILL` fails. `ShineMover::smo_ply_SkillCoolTime` @ FUN_0054a770 (mount skills) only
sets the mover's cool time: no item actions. The `SEIT_STA_*` kinds and `SEIT_STA_SHEILD_BLOCK_RATE_INCREASE` are read only
by `so_ItemActonAbstateApp` (§2.8).

### 3.5 Cool-down persistence: `0x482C` (full list), `0x4023`, `0x4034`

```pseudo
ItemActionObserveManager::SendCoolTimes2Client()                                     @ FUN_005d0d30
    Send to the owner (vt 0x2f8 data socket .vt 0xc) 0x482C NC_SKILL_ITEMACTIONCOOLTIME_CMD {
        u16 num = list size
        num × { u16 ItemActionID = t.ActionID (+0x14); u16 ItemActionGroupID = t.ActionGroupID (+0x10);
                u32 SecondCoolTime = TickTimer::GetRestDelayTimeToSecond(t) × 1000 }   # @ FUN_00592000: (delay − cur)/10 s, 0 if run out
    }   # 4 + 8·num bytes; sent also when the list is empty (num 0); too long → assert "…SendCoolTimes2Client : Packet Too Long", nothing sent
    # callers: sp_ItemActionSetup (§3.1). The remaining time is rounded down to whole seconds.

ItemActionObserveManager::SendCoolTimes2DB()       (from WholeSaver::ws_save2DB @ FUN_00455a10, Z01 §8.4)   @ FUN_005d0e60
    if the list is empty: return                                # the DB keeps its old rows (Z11-B44)
    now = _time64()
    Send to CharDB (sock2gameDB) 0x4023 NC_CHARSAVE_ITEMACTIONCOOLTIME_REQ {
        NETPACKETZONEHEADER { u16 clienthandle = p handle; u32 charregistnumber = p charNo (vt 0x344) }
        u16 num
        num × ActionCooltime { u16 actionID = t.ActionID; i64 expiredTime = now + rest seconds }
    }   # 10 + 10·num bytes incl. opcode (D02: CharDB FUN_00424140, usp_Character_setItemActionCoolTime)
    # Z01 §8.4 lists FUN_005d0e60 as "tutorial save": it is this cool-time save

ItemActionObserveManager::SendCoolTimes2World()    (from WholeSaver::ws_save2worldmanager @ FUN_004536f0, Z01 §8.4)   @ FUN_005d0fa0
    if the list is empty: return
    Send to the WM (sock2wldman) 0x4034 NC_CHARSAVE_2WLDMAN_ITEMACTIONCOOLTIME_CMD {
        u32 nCharNo; u16 num; num × ActionCooltime { u16 actionID; i64 expiredTime = now + rest s }
    }   # 8 + 10·num bytes incl. opcode; the WM caches it (+0x668, W05 §5.5 / W01 §7.4, W05-B16) and replays it as 0x10D0 (§3.1)
```

Round trip: zone list → `0x4034` (map change / logout) or `0x4023` (DB save) as absolute `time64` end times → `0x10D0` at
the next zone login → `SetCoolTime(rest ms)` per entry. Cool-downs therefore run in real time while the character is
offline or changing maps. Two losses: the rest is rounded down to seconds at every hop, and an empty list is never sent,
so after `&iareset` (Z11 §7.4, `ResetCoolTime`) or once every cool-down has run out, the WM cache and the DB still hold
the last non-empty list. Entries that ended meanwhile are skipped at `0x10D0`, so only `&iareset` is visibly undone
(Z11-B44 for the DB; the same for the WM cache).

Client `GameFrameWork::On_NC_SKILL_ITEMACTIONCOOLTIME_CMD` (2016 FUN_0049c600, Z11 §7.4): per entry
`Skill::SetLastCoolTimeByItemActionID(ItemActionID, SecondCoolTime / 1000)`, i.e. the cool-down display of every skill /
item tied to that action restarts with the given rest (0 = ready). `ItemActionGroupID` is not used by the client.

### 3.6 Teardown

There is no removal at logout: `Clear` (§2.2) has one caller, `sp_ItemActionSetup`, and `~ItemActionObserveManager`
(@ FUN_005592c0) / `~ShinePlayer` free only the vectors. Player objects live in a fixed pool of 1500 (Z01 §4.2) and are
reused, so a logged-out character's observers keep their slots in the zone-wide 5000-entry `ItemActionObserveBuffer`
until a later login on the same player object runs `Clear` (original bug) Z17-B13. The cool-down list is cleared at the
next `so_SetRegistNumber`. Map changes inside one zone process do not leave the player object, so nothing is lost there.

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z17-B1 | `ItemActions::DataProcess` FUN_005b78e0 | for a repeated `ItemActionID`, only the first row's `CoolTime` / `CoolGroupActionID` is kept | action 752 (first row `0/0`, second `1250 ms / group 3`) has no cool-down | one cool time per action (data fix) or take the non-zero row |
| Z17-B2 | `RangeCondition::_check` FUN_005ceef0 | `RangeStart ≤ v < RangeEnd` while the range rows are inclusive by name (`Lv_0_19` = 0…19, `Lv_20_49` = 20…49) | levels 19, 40, 49, 79, 99, 150 match none of their ranges (latent: 2016 conditions use only `HP_RATE_0_20`) | `v ≤ RangeEnd` |
| Z17-B3 | `TargetTypeValidator::check` FUN_005ce860, `TARGET_MYGUILD` | compares the two guild numbers without testing for 0 (`TARGET_ENEMYGUILD` does) | two guildless objects count as the same guild (latent: no 2016 condition uses it) | require `guild ≠ 0` |
| Z17-B4 | `MakeEffect` FUN_005d0060 | an effect row with activity 4/6/7 aborts with the text "Unexpected condition type" | misleading fatal log text only | "Unexpected effect type" |
| Z17-B5 | `IActCondition::check` FUN_005cee70 | passes when `rb_1000() ≤ ActivityRate` with `rb_1000 ∈ [0, 999]` | every rate is 1 ‰ higher than written (rate 1 → 2 ‰, rate 0 still 1 ‰) | `rb_1000() < ActivityRate` |
| Z17-B6 | `Action::raise` FUN_005d10d0 | with several effects, the action's result is that of the last effect in pointer order; an effect not matching the asked value kind returns `{false, fallback}` | 2016 actions 196, 197, 199, 201, 204: the bonus of the first `SkillEffectIncrease` effect is never granted (no result, no cool-down); action 200: only one of its two cool-time reductions applies | combine the results (any success; one result per matching effect) |
| Z17-B7 | `ItemActionObserveManager::AddAction` FUN_005d17f0 | `_actions.find(actionID)` result is dereferenced without an `end()` test | an unknown action id reads the value slot of the map's head node (uninitialised; crash or a bogus `Action*`); latent: every 2016 `ActionEffectItem` / `SetEffect` id exists | return false when not found |
| Z17-B8 | `DispelAttrTypeEffect::_execute` FUN_005d05f0 | compares each state's `DispelIndex` with the effect's `Value`, not with its `DispelAttr` sub-type | a dispel effect would remove the wrong class of states; latent: no 2016 effect uses `AAT_DispelAttr` | compare `EffectActivityValue` |
| Z17-B9 | `so_ply_EnchantActionUse` FUN_00562cb0 → CharDB `0x3498` | the 12-byte `remover` block is never written (stale send-buffer bytes); `needItem` = 0 | harmless for CharDB (it reads the remover only when `needItem` = 1, D03), but stale bytes go on the wire and come back in `0x3499` | zero the block |
| Z17-B10 | `roe_CriticalRateByGlobalAction` / `roe_HitRateByGlobalAction` / `roe_ShieldBlockByGlobalAction` (FUN_00504b10…FUN_005058d0), `roe_CalcDamage` FUN_00505c00 | one `ActionResults` vector collects all runs and is never cleared, but the total adds the sum over the whole vector after each run | a success of an early run is counted once more by every later run (normal hit rate: up to 4×; skill variants: once per skill group more); in `roe_CalcDamage` the defender's crit-block results are added to its crit-miss chance; latent in 2016 (no `AttackType` effects) | clear the vector per run, or sum once at the end |
| Z17-B11 | `0x10D0` `wms_NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD` FUN_0044e710 | `_actions.find(actionID)` dereferenced without an `end()` test (same pattern as B7) | a stored id that is no longer in `ItemAction.shn` reads the map head node: bogus group / crash | skip unknown ids |
| Z17-B12 | `so_ply_EnchantActionUse` FUN_00562cb0 + `0x3499` FUN_005233d0 | the emptied socket keeps `{gemID, 0}` and the gem's observer until CharDB answers | each further success in that window asserts "RestCount Empty", re-sends `0x3046` (0) and another lock + `0x3498`; a refused removal leaves the gem action firing without charges | delete the gem's action (or mark the socket empty) when the count reaches 0 |
| Z17-B13 | player teardown (`~ItemActionObserveManager` FUN_005592c0; `Clear` FUN_005d16e0 called only by `sp_ItemActionSetup`) | a logged-out player's observers are not returned to the 5000-slot `ItemActionObserveBuffer` | slots stay used until the same pooled player object logs in again; with many distinct player objects (pool 1500) the buffer can fill → "Buffer Full", actions silently missing for new logins *(inferred: effect depends on load)* | `Clear` on logout |
