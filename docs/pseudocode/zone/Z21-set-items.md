# Zone server: set items (Z21)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (all four zones are identical). Read the code with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …` (official names from the NA2016 Zone.pdb,
*(pdb2016)*: every `Class::Method`, member and struct name below comes from there unless marked otherwise). Data tables:
`Files/Server/2016/9Data/Shine/{SetItem,SetItemEffect,SetEffect}.shn`, decoded with `tools/protocol-re/shn.py`; the client
ships byte-identical copies in `Files/Client/2016/ressystem/` (same MD5). Evidence markers as in `AGENTS.md`.

Related documents: Z12 §2.5 (`siae_ParameterRefit`, the set-item part of an abnormal state's stat refit), Z12 §6.4
(set-item values restored with the saved abnormal states at login), Z03 §5.4 / §5.6 (casting, the blast queue and the
effect application that reads `g_SetEffect`), Z03 §6.2 (abstate keep time), Z09 §5.5 (`so_Routine` clears it), Z09 §12.5 (magic-field heal, bug Z09-B30).

## 1. Overview: three set-item mechanisms

The 2016 zone contains three separate mechanisms, of which only the second has any effect with the shipped data:

| # | Mechanism | Tables | Per-player state | 2016 status |
|---|---|---|---|---|
| A | **Skill-effect sets** (legacy): equipped pieces per set → up to 10 "set effects" → per-cast multipliers (`SetIndex`, base 1000) on heal, damage, SP cost, cooldown, … of listed skills | `SetItem.shn`, `SetItemEffect.shn` | `ShinePlayer::sp_SetItemEffect` (`PlayerSetEffect`, p+0x2a7e0), `sp_SetEffectForJustSkill` (p+0x2a7de) | **dead**: neither table is loaded, the global tables stay empty, every multiplier stays 1000 (§3.9) |
| B | **Item-action sets**: equipped pieces with the same `ItemInfo.SetItemIndex` name → `SetEffect.shn` row (set, count) → item action id added to / removed from the player's item actions | `SetEffect.shn` (+ `ItemInfo.SetItemIndex`) | the player's item-action list | live (§4, part 2) |
| C | **Set-item abstate values**: up to 4 `{SetIndex, value}` pairs stored in an abnormal state when it is set, refitting the stats while it lasts; saved and restored with the state | — | `AbstateElementInObject::aeo_SetItemEffect` (`SetItemAbstateEffect`) | fed from mechanism A's `g_SetEffect`, so new states store nothing; DB-restored values still apply (§5, part 3) |

## 2. Tables

### 2.1 `SetItem.shn` (row struct `SetItem`, 0x41 bytes, 442 rows, 187 sets)

| Column (shn type:size) | Member | Offset | Content |
|---|---|---|---|
| `Index` (9:32) | `char Index[32]` | 0x00 | set name (`BoneAttackSet`, `WinSet`, …) |
| `Piece` (1:1) | `u8 Piece` | 0x20 | pieces needed: 2 (187 rows), 3 (158), 4 (87), 5 (10) |
| `Effect` (9:32) | `char Effect[32]` | 0x21 | `SetItemEffect.Effect` key; every value exists in `SetItemEffect.shn` |

One row per (set, piece count): no (set, piece) pair has more than one row, no set has more than 3 rows.
The server row struct exists in the 2016 Zone.pdb (`SetItem`, size 0x41 = the row size, `docs/knowledge/S01-shn-structs.tsv`),
but **no zone function reads this file** (no `SetItem.shn` string, no `Table::Load<…>`, no writer of the global that
would hold it, §3.2). The file is used only by the client (set tooltips, *(inferred)*: the client also has
`SetItemName.shn` / `SetItemView.shn`; C01 territory).

### 2.2 `SetItemEffect.shn` (row struct `SetItemEffect`, 0xF1 bytes, 235 rows)

| Column | Member | Offset | Content |
|---|---|---|---|
| `Effect` (9:32) | `char Effect[32]` | 0x00 | effect key (`BoneAttackABStatekeeptime`, …) |
| `Desc` (9:128) | `char Desc[128]` | 0x20 | English description ("Increases Bone Slicer skill duration") |
| `UseSubject` (1:1) | `u8 UseSubject` | 0xA0 | 0 in every row |
| `SkillGroup` (9:64) | `char SkillGroup[64]` | 0xA1 | skill (group) name the effect applies to (`SeverBone`, `IceBolt`, `SWAI` = several) |
| `From` (9:4) / `To` (9:4) | `char From[4]`, `char To[4]` | 0xE1 / 0xE5 | skill level range, `01`…`99` (224 rows) or `-` (11 rows) |
| `Index` (11:4) | `SetIndex Index` | 0xE9 | which multiplier (§3.1 enum): 5 SP (78 rows), 2 damage (56), 7 cooldown (50), 4 abstate keep time (28), 1 heal (8), 12 aggro (7), 13 probability (2), 14 HP/SP max (2), 3, 6, 8, 9 (1 each) |
| `Argument` (3:4) | `u32 Argument` | 0xED | multiplier, base 1000 (700…1300) |

As for `SetItem.shn`: struct in the PDB, file never opened by the zone. Its fields map 1:1 onto the in-memory
`EffectDescription` (§3.1: `index` ← Effect, `seteffect` ← Index, `setargument` ← Argument, `skilllist` ← the skill ids of
SkillGroup within From…To *(inferred)*), but the loader that would do that conversion is not in the 2016 binary.

### 2.3 `SetEffect.shn` (row struct `SetEffect`, 0x23 bytes, 1043 rows, 393 sets)

| Column | Member | Offset | Content |
|---|---|---|---|
| `SetItemIndex` (9:32) | `char SetItemIndex[32]` | 0x00 | set name, matched against `ItemInfo.SetItemIndex` (`char[32]` at ItemInfo+0x156) |
| `Count` (1:1) | `u8 Count` | 0x20 | pieces needed: 2 (390), 3 (363), 4 (279), 5 (11) |
| `ItemActionID` (2:2) | `u16 ItemActionID` | 0x21 | `ItemAction.shn` id granted at that count |

No duplicate (set, count) pairs. Loaded at boot by `Table::Load<SetEffectTable>` @ FUN_005b5ec0 (Z01 §2.3, Z10 §7.1
"Table::Load<…>: SetEffect"); the loader, `SetEffectTable::FindActionID` @ FUN_005c7eb0 and the use are §4 (part 2).

## 3. Mechanism A: skill-effect sets (legacy, dead in 2016)

### 3.1 Data structures *(pdb2016)*

```pseudo
enum SetIndex { SET_NONE 0, SET_HEALRATE 1, SET_DAMEGERATE 2, SET_ACRATE 3, SET_ABSTATEKEEPTIMERATE 4,
                SET_SPCONSUMRATE 5, SET_HPSPRECOVERYRATE 6, SET_COOLTIMERATE 7, SET_DEXRATE 8, SET_HPDRAINRATE 9,
                SET_MOVESPEEDRATE 10, SET_THRATE 11, SET_AGGRORATE 12, SET_PROBABILITYRATE 13, SET_HPSPMAXRATE 14,
                SET_ABSTATERATE 15, SET_DAMEGEIGNORERATE 16, MAX_SETINDEX 17 }

struct SetItemData::EffectByPiece {              # 0x50, one per set
    Name8   ebp_Index                            # +0x00 set name
    u16     ebp_EffectArray[6][4]                # +0x20 [pieces][slot] = effect handle (index into setitemeffectlist), 0xFFFF = none; row 0 never read
}
class SetItemData::SetItemClassifier {           # 0x5108, global `setitemclassifier` DAT_1326ae00
    EffectByPiece sic_SetItemStruct[256]         # +0x0000
    int     sic_MaxType                          # +0x5000 (never read or written)
    u8      sic_ItemSetPiece[256]                # +0x5004 scratch: pieces counted per set id
    int     sic_TotalNumber                      # +0x5104 number of sets loaded (never written: stays 0, .bss)
}
struct SetItemData::EffectDescription {          # 0x30, one per set effect
    Name8   index                                # +0x00 effect name
    SetIndex seteffect                           # +0x20 multiplier slot
    u32     setargument                          # +0x24 value, base 1000
    u16*    skilllist                            # +0x28 sorted skill ids it applies to (NULL = every skill), freed by the dtor
    int     skillnumber                          # +0x2C
}
class SetItemData::SetItemEffectList {           # 0xC004, global `setitemeffectlist` DAT_1325edf8
    EffectDescription siel_SetItemEffectList[1024]
    int     siel_MaxEffect                       # +0xC000 (never read or written)
}
struct SetItemData::PlayerSetEffect {            # 0x16, ShinePlayer::sp_SetItemEffect (p+0x2a7e0)
    u16     effectarray[10]                      # effect handles, 0xFFFF = none
    u8      effectnumber
}
class SetItemData::SkillEffect { u32 se_Argument[17] }   # 0x44, indexed by SetIndex, base 1000
    # global `setitemskilleffect` DAT_1325edb0 (= Z03's g_SetEffect)
MemoryQueue<SetItemData::SkillEffect> setitemskilleffectqueue   # DAT_1326ff08, 0x2408
    MemoryQueueElement { u16 handle; SkillEffect content } mq_Buffer[128]   # 0x48 each
    BitANDInt mq_Pointer { value @+0x2400, mask @+0x2404 = 0x7F }           # ring of 128 snapshots
ItemDataBox::ItemDataBoxIndex.SetItemIndex       # u16 at +0x10 of each item's index entry: set id of the item
ShinePlayer::sp_SetEffectForJustSkill            # u16 p+0x2a7de: queue slot of the current cast, 0xFFFF = none
```

### 3.2 Globals and their initialisation

```pseudo
dynamic initializer for setitemclassifier          @ FUN_006983c0
    vector-construct 256 × EffectByPiece (EffectByPiece::EffectByPiece @ FUN_00510240:
        ebp_Index = 8 × 0; all 24 ebp_EffectArray cells = 0xFFFF); atexit FUN_0069e8c0
dynamic initializer for setitemeffectlist          @ FUN_006983f0
    vector-construct 1024 × EffectDescription (ctor @ FUN_00510200: index = 0, skilllist = NULL, skillnumber = 0;
        seteffect / setargument left 0 from .bss); atexit FUN_0069e8e0 → dtor @ FUN_00510230 (delete[] skilllist if set)
dynamic initializer for setitemskilleffect         @ FUN_00698420   (atexit FUN_0069e900 only; contents 0 until the first se_Clear)
dynamic initializer for setitemskilleffectqueue    @ FUN_00698430
    128 elements (no-op element ctor); mq_Pointer.mask = 0x7F, value = 0; atexit FUN_0069e910
```

A scan of the whole code section for any address inside `setitemclassifier` (0x1326ae00…0x1326ff07) or
`setitemeffectlist` (0x1325edf8…0x1326adfb) finds only these initializers / destructors, `sp_SetItemCheck` and
`smo_ply_SetItemEffect`. Nothing ever fills `sic_SetItemStruct`, `sic_TotalNumber` or `siel_SetItemEffectList`, and
`ItemDataBox::idb_Load` @ FUN_00649780 initialises every `ItemDataBoxIndex.SetItemIndex` to 0xFFFF and never writes it
again. **(original bug) Z21-B1**: the whole mechanism is wired into equip recalculation and every skill cast but has no
data: both tables ship, are never loaded, and every lookup falls through to the neutral value 1000.

### 3.3 `ShinePlayer::sp_SetItemCheck` @ FUN_00510b50 (count pieces per set)

Called at the end of `so_RecalcEquipParam` @ FUN_004cab70 (Z12 §2.2), i.e. after every equipment change and at login.

```pseudo
sp_SetItemCheck(p):
    memset(setitemclassifier.sic_ItemSetPiece, 0, 256)
    for cell in ItemBoxIterItem(p.sp_Item):                  # the equipped-item bag, every occupied cell
        idx = itemdatabox[cell.iic_ItemIdent()]               # ItemDataBox::operator[] @ FUN_00419020
        if idx == NULL: break                                  # (original bug) Z21-B2: an unknown item id ends the count
                                                               #   instead of skipping that cell
        if idx.SetItemIndex < setitemclassifier.sic_TotalNumber:   # 2016: 0xFFFF < 0 never true (§3.2)
            sic_ItemSetPiece[idx.SetItemIndex] += 1            # u8, no overflow check
    setitemclassifier.sic_SetItemDefine(&p.sp_SetItemEffect)
```

Piece-count rules *(of the dead code)*: every occupied equipment cell counts once, so two copies of the same piece
(e.g. both rings) count twice; costume / KQ items count like any other item when their `SetItemIndex` is set; there is no
class or level check. The live mechanism B has its own rules (§4).

### 3.4 `SetItemClassifier::sic_SetItemDefine` @ FUN_00510370 (pieces → effect list)

```pseudo
sic_SetItemDefine(cls, out: PlayerSetEffect):
    out.effectnumber = 0; out.effectarray[0..9] = 0xFFFF
    for set in 0..255:                                         # all 256, regardless of sic_TotalNumber
        for piece in 1..5:
            if piece > cls.sic_ItemSetPiece[set]: continue
            for slot in 0..3:
                h = cls.sic_SetItemStruct[set].ebp_EffectArray[piece][slot]
                if h == 0xFFFF: break
                if out.effectnumber > 9:
                    assert "SetItemData::SetItemClassifier::sic_SetItemDefine : Too many Effect"(effectnumber); break
                out.effectarray[out.effectnumber++] = h
```

So a set with n pieces equipped grants the effects of every threshold 1…min(n,5) (cumulative, as in the tables'
2/3/4/5 rows); row 0 of `ebp_EffectArray` is never used, 6+ pieces count as 5. Overflow beyond 10 effects asserts and drops
the rest of that piece's slots (the outer loops continue and assert again for each further effect).

### 3.5 Per-cast snapshot: `smo_ply_SetItemEffect` (vt 0xEF8) and the queue

```pseudo
ShineMobileObject::smo_ply_SetItemEffect(o, skillID):          @ FUN_00510c80   (mobs, NPCs, pets, … and the player's base)
    setitemskilleffect.se_Clear()                              # all 17 values = 1000

ShinePlayer::smo_ply_SetItemEffect(p, skillID):                @ FUN_00510d20
    ShineMobileObject::smo_ply_SetItemEffect(p, skillID)       # clear
    for i in 0 .. p.sp_SetItemEffect.effectnumber-1:
        setitemeffectlist.siel_AppendEffect(p.sp_SetItemEffect.effectarray[i], skillID)    # §3.6
    if p.sp_SetEffectForJustSkill == 0xFFFF:                   # no snapshot taken for the current cast yet
        q = setitemskilleffectqueue
        q.mq_Pointer.value = (q.mq_Pointer.value + 1) & 0x7F
        q.mq_Buffer[value].handle  = p.handle
        q.mq_Buffer[value].content = setitemskilleffect        # 17 × u32
        p.sp_SetEffectForJustSkill = value
    # setitemskilleffect is left holding p's values for skillID (the caller's checks read it directly)

ShinePlayer::smo_SetEffectForJustSkill(p)      (vt 0xEFC)   @ FUN_00510290: return p.sp_SetEffectForJustSkill
ShinePlayer::smo_SetEffectForJustSkillClear(p) (vt 0xF00)   @ FUN_005102a0: p.sp_SetEffectForJustSkill = 0xFFFF
    # non-players: vt 0xEFC = FUN_005550b0 (returns 0xFFFF), vt 0xF00 = FUN_00417480 (no-op)
```

Who calls them (vt slots from RTTI, `tools/protocol-re/rtti.py`):

| Slot | Caller | When |
|---|---|---|
| 0xEF8 | `sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ` FUN_0057fa50, `sp_NC_BAT_SKILLBASH_FLD_CAST_REQ` FUN_0057f400 (Z03 §5.2, §5.5) | cast request: before the SP / cooldown checks |
| 0xEF8 | `sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90 | item-triggered active skill |
| 0xEF8 | `ShineMobileObject::so_Routine` FUN_0056a080 | cast completes (`sdi_Activ->ID`), before the blast is queued |
| 0xEFC | `so_Routine` (→ `sbec_Store`, → vt 0xBF4), `smo_MagicFieldSpread` FUN_0057c880, `smo_SkillBash_Blast` FUN_0057cb10 / FUN_0057cd40 | the slot is stored in the queued blast effect (`SkillBlastEffect`+0x6a, Z03 §5.6) |
| 0xF00 | `SkillBlastEffectContainer::sbec_Routine` FUN_00437fc0 (after `sds_Finish`), `so_Routine` (item-use cast end) | cast's snapshot released |
| init | `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 | `sp_SetEffectForJustSkill = 0xFFFF` |

`sbec_Routine` (Z03 §5.6) saves `setitemskilleffect`, and for each due blast effect: if its slot < 0x80 and
`queue[slot].handle == caster.handle` it copies `queue[slot].content` into `setitemskilleffect`, otherwise `se_Clear`; after
all effects it restores the saved copy. The handle check guards against the 128-slot ring having been reused by other
casts in the meantime (then the effect runs with neutral values).

### 3.6 `SetItemEffectList::siel_AppendEffect` @ FUN_005104c0 and the `SkillEffect` accessors

```pseudo
siel_AppendEffect(list, h, skillID):
    if h >= 0x400: assert "SetItemData::SetItemEffectList::siel_AppendEffect : EffectHandle wrong"(h); return
    d = list.siel_SetItemEffectList[h]
    if d.skilllist != NULL and bsearch(skillID, d.skilllist, d.skillnumber, 2, ed_Compare) == NULL: return
    setitemskilleffect.se_Argument[d.seteffect] += d.setargument - 1000      # effects of one slot add up around 1000

EffectDescription::ed_Compare(a, b) = *(u16*)a − *(u16*)b                    @ FUN_004a2ed0   (bsearch comparator)
SkillEffect::se_Clear(se):        se_Argument[0..16] = 1000                    @ FUN_005105e0
SkillEffect::operator[](se, i):   return i < 17 ? se_Argument[i] : 1000        @ FUN_00510010
```

No bounds check on `d.seteffect` (it would come from the table's `Index` column; values ≤ 14 in the shipped file).
Two effects on the same slot are additive (1200 and 1300 → 1500), not multiplicative.

### 3.7 Readers of `setitemskilleffect` (= `g_SetEffect`)

Every reader multiplies by `value / 1000` (or adds `value − 1000` to a per-mille chance). All are documented by their
own items; listed here so the subsystem's contract is in one place:

| SetIndex | Reader | Use | Documented in |
|---|---|---|---|
| 1 HEALRATE | `smo_SkillBlast` FUN_00581160 | heal = arg × heal / 1000 | Z03 §5.6 |
| 1 HEALRATE | `AxialListMagicFieldHeal::almfh_ApplyHeal` FUN_0056d2c0 | magic-field heal (stale global, Z09-B30) | Z09 §12.5 |
| 2 DAMEGERATE | `smo_SkillBlast` | skill damage | Z03 §5.6 |
| 4 ABSTATEKEEPTIMERATE | `AbstateElementInObject::aeo_Set` FUN_0040a340 | abstate end time | Z03 §6.2 |
| 4 ABSTATEKEEPTIMERATE | `so_SkillEnchant` FUN_00431ca0 | duration, only if < 3,600,000 ms | here (factor only); function not yet cited elsewhere, sweep part checks its owner |
| 5 SPCONSUMRATE | `CharaterSkillList::csl_SPCheck` FUN_0055b920 | SP cost | Z03 §5.3 |
| 6 HPSPRECOVERYRATE | `so_mobile_HPHealOverTime` FUN_0040e910, `so_mobile_SPHealOverTime` FUN_004055d0 | heal-over-time tick | here (factor only); function not yet cited elsewhere, sweep part checks its owner |
| 7 COOLTIMERATE | `smo_ply_SkillCoolTime` FUN_0055b6a0 | cooldown (both times), only if ≠ 1000 | here (factor only); function not yet cited elsewhere, sweep part checks its owner |
| 9 HPDRAINRATE | `smo_SkillBlast` | own heal from damage (`bos_MyHealHit`) | Z03 §5.6 |
| 12 AGGRORATE | `smo_SkillBlast` | `bos_DamageRateAggro = arg − 1000 + AggroPerDamage` | Z03 §5.6 |
| 13 PROBABILITYRATE | `smo_SkillBlast` | hit chance, HP-up chance (`+ arg − 1000`) | Z03 §5.6 |
| 13 PROBABILITYRATE | `MiscDataTable::mdt_PostSkillBlast` FUN_004a3a90 | neutralization-item chance | Z09 §28.3 |
| (all) | `sbec_Routine` FUN_00437fc0 | load per blast from the queue, restore after | Z03 §5.6 |
| (all, clear) | `ShineMobileObject::so_Routine` FUN_0056a080 | `se_Clear` at the start of each object's routine | Z09 §5.5 |
| (snapshot) | `SetItemAbstateEffect::siae_SetItemEffectStore` FUN_005100f0 | copies values ≠ 1000 into a newly set abstate | §5 (part 3) |

Slots 3 AC, 8 DEX, 10 move speed, 11 TH, 14 HP/SP max, 15 abstate rate and 16 damage-ignore have no direct reader; they
only matter through mechanism C (Z12 §2.5 maps them onto the stat matrix).

### 3.8 Net effect in 2016 *(inferred from §3.2)*

`sp_SetItemEffect.effectnumber` is always 0, so `smo_ply_SetItemEffect` only clears; every queue snapshot is 17 × 1000;
`setitemskilleffect` never holds anything but 1000 (its only other writer, `siel_AppendEffect`, is never reached with an
entry). Every multiplier in §3.7 is neutral, and `siae_SetItemEffectStore` (which skips values == 1000) never stores a
value into a new abnormal state. A rebuild that loads the original tables unchanged reproduces 2016 behaviour by
**not** loading `SetItem.shn` / `SetItemEffect.shn` (or by keeping every multiplier at 1000); implementing the legacy path
would change game balance relative to 2016.

## 4. Mechanism B: item-action sets (`SetEffect.shn`)

*(Part 2: `SetEffectTable` loader FUN_005b1ec0 / FUN_005b5ec0 / FUN_005b35b0, `SetEffectTable::FindActionID` FUN_005c7eb0,
`so_EqualSetitemIndexNameCount` FUN_00549a70, the item-action hooks `icr_Apply` FUN_0048ca20 / FUN_0048cc60,
`so_ply_ItemAction_UnEquip` FUN_00565020, `sp_ItemActionSetup` FUN_00566420, `Send_SETITEMHEALEFFECT` FUN_005cfbb0,
`RecoverTypeEffect::_execute` FUN_005cfc70.)*

## 5. Mechanism C: set-item values in abnormal states

*(Part 3: `SetItemAbstateEffect::*` FUN_00510030…FUN_00510350, `aeo_SetItemEffectStore` FUN_00510670,
`aeo_SetItemActionEffect` FUN_00510810, `aeo_FillSetItemEffect` FUN_004534f0, save `p_Char_SetStateWithSetItemAndRestTime`
and restore at login; `siae_ParameterRefit` FUN_005108c0 is Z12 §2.5.)*

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z21-B1 | `sp_SetItemCheck` FUN_00510b50, `sic_SetItemDefine` FUN_00510370, `siel_AppendEffect` FUN_005104c0 (§3.2) | `SetItem.shn` / `SetItemEffect.shn` are never loaded; `sic_TotalNumber` stays 0, `ItemDataBoxIndex.SetItemIndex` stays 0xFFFF, `setitemeffectlist` stays empty | the legacy skill-effect set bonuses (235 described effects) never apply; all `g_SetEffect` multipliers are 1000; the code runs on every equip change and cast for nothing | legacy path superseded by `SetEffect.shn` item actions *(inferred)*, left wired in |
| Z21-B2 | `sp_SetItemCheck` FUN_00510b50 (§3.3) | `break` when `ItemDataBox[id]` is NULL | pieces after an unknown item id in the bag are not counted (moot while B1 holds) | `continue` |

## 6. Not reconstructed / uncertain

- How the legacy tables were meant to be loaded (`SkillGroup` + `From`/`To` → `skilllist`, set name → set id in
  `ItemDataBoxIndex.SetItemIndex`): no loader exists in the 2016 zone; the mapping in §2.2 is *(inferred)* from the
  member names. The 2015 zone could be diffed for an older loader (not documented here: 2015 is out of scope).
- Parts 2–3 pending (§4, §5).

## 7. Coverage boundary

*(Completed in the sweep part.)*
