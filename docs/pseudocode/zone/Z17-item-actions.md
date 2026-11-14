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
meaningful depends on how the callers fill the argument (open point for part 3).

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
  effects (area application, part 2).

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z17-B1 | `ItemActions::DataProcess` FUN_005b78e0 | for a repeated `ItemActionID`, only the first row's `CoolTime` / `CoolGroupActionID` is kept | action 752 (first row `0/0`, second `1250 ms / group 3`) has no cool-down | one cool time per action (data fix) or take the non-zero row |
| Z17-B2 | `RangeCondition::_check` FUN_005ceef0 | `RangeStart ≤ v < RangeEnd` while the range rows are inclusive by name (`Lv_0_19` = 0…19, `Lv_20_49` = 20…49) | levels 19, 40, 49, 79, 99, 150 match none of their ranges (latent: 2016 conditions use only `HP_RATE_0_20`) | `v ≤ RangeEnd` |
| Z17-B3 | `TargetTypeValidator::check` FUN_005ce860, `TARGET_MYGUILD` | compares the two guild numbers without testing for 0 (`TARGET_ENEMYGUILD` does) | two guildless objects count as the same guild (latent: no 2016 condition uses it) | require `guild ≠ 0` |
| Z17-B4 | `MakeEffect` FUN_005d0060 | an effect row with activity 4/6/7 aborts with the text "Unexpected condition type" | misleading fatal log text only | "Unexpected effect type" |
| Z17-B5 | `IActCondition::check` FUN_005cee70 | passes when `rb_1000() ≤ ActivityRate` with `rb_1000 ∈ [0, 999]` | every rate is 1 ‰ higher than written (rate 1 → 2 ‰, rate 0 still 1 ‰) | `rb_1000() < ActivityRate` |
