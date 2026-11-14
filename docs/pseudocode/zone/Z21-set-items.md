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
| A | **Skill-effect sets** (legacy): equipped pieces per set → up to 10 "set effects" → per-cast multipliers (`SetIndex`, base 1000) on heal, damage, SP cost, cooldown, … of listed skills | `SetItem.shn`, `SetItemEffect.shn` | `ShinePlayer::sp_SetItemEffect` (`PlayerSetEffect`, p+0x2a7e0), `sp_SetEffectForJustSkill` (p+0x2a7de) | **dead**: neither table is loaded, the global tables stay empty, every multiplier stays 1000 (§3.8) |
| B | **Item-action sets**: equipped pieces with the same `ItemInfo.SetItemIndex` name → `SetEffect.shn` row (set, count) → item action id added to / removed from the player's item actions | `SetEffect.shn` (+ `ItemInfo.SetItemIndex`) | the player's item-action list | live (§4) |
| C | **Set-item abstate values**: up to 4 `{code, value}` pairs stored in an abnormal state when a skill sets it, refitting the target's stats or scaling its heal while it lasts; saved and restored with the state | — (fed by A and by B's item actions) | `AbstateElementInObject::aeo_SetItemEffect` (`SetItemAbstateEffect`) | live: the A source (codes 1…16) stores nothing, but the caster's `SkillEffectIncreaseType` item actions (codes 1000 + SEIT; 21 of them are set actions from `SetEffect.shn`) are stored, saved and restored (§5) |

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
"Table::Load<…>: SetEffect"); the loader, `SetEffectTable::FindActionID` @ FUN_005c7eb0 and the use are §4.

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

EffectDescription::ed_Compare(a, b) = *(u16*)a − *(u16*)b                    @ FUN_004a2ed0   (bsearch comparator;
    # one COMDAT body referenced by ten other functions (u16 bsearch / sort users), e.g. so_ply_ItemMakeItem @ FUN_0049c680)
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
| 4 ABSTATEKEEPTIMERATE | `so_SkillEnchant` FUN_00431ca0 | keep time sent in the inform / broadcast (scaled `x · v / 1000` below 3,600,000 ms, `v · (x / 1000)` above) | §5.7 |
| 5 SPCONSUMRATE | `CharaterSkillList::csl_SPCheck` FUN_0055b920 | SP cost | Z03 §5.3 |
| 6 HPSPRECOVERYRATE | `so_mobile_HPHealOverTime` FUN_0040e910, `so_mobile_SPHealOverTime` FUN_004055d0 | heal-over-time tick (HP and SP) | §5.8 |
| 7 COOLTIMERATE | `smo_ply_SkillCoolTime` FUN_0055b6a0 | cooldown (both times), only if ≠ 1000 | Z11 §8.5 |
| 9 HPDRAINRATE | `smo_SkillBlast` | own heal from damage (`bos_MyHealHit`) | Z03 §5.6 |
| 12 AGGRORATE | `smo_SkillBlast` | `bos_DamageRateAggro = arg − 1000 + AggroPerDamage` | Z03 §5.6 |
| 13 PROBABILITYRATE | `smo_SkillBlast` | hit chance, HP-up chance (`+ arg − 1000`) | Z03 §5.6 |
| 13 PROBABILITYRATE | `MiscDataTable::mdt_PostSkillBlast` FUN_004a3a90 | neutralization-item chance | Z09 §28.3 |
| (all) | `sbec_Routine` FUN_00437fc0 | load per blast from the queue, restore after | Z03 §5.6 |
| (all, clear) | `ShineMobileObject::so_Routine` FUN_0056a080 | `se_Clear` at the start of each object's routine | Z09 §5.5 |
| (snapshot) | `SetItemAbstateEffect::siae_SetItemEffectStore` FUN_005100f0 | copies values ≠ 1000 into a newly set abstate | §5.2 |

Slots 3 AC, 8 DEX, 10 move speed, 11 TH, 14 HP/SP max, 15 abstate rate and 16 damage-ignore have no direct reader; they
only matter through mechanism C (Z12 §2.5 maps them onto the stat matrix).

### 3.8 Net effect in 2016 *(inferred from §3.2)*

`sp_SetItemEffect.effectnumber` is always 0, so `smo_ply_SetItemEffect` only clears; every queue snapshot is 17 × 1000;
`setitemskilleffect` never holds anything but 1000 (its only other writer, `siel_AppendEffect`, is never reached with an
entry). Every multiplier in §3.7 is neutral, and `siae_SetItemEffectStore` (which skips values == 1000) never stores a
value into a new abnormal state (the item-action source of the same buffer is live, §5.3). A rebuild that loads the original tables unchanged reproduces 2016 behaviour by
**not** loading `SetItem.shn` / `SetItemEffect.shn` (or by keeping every multiplier at 1000); implementing the legacy path
would change game balance relative to 2016.

## 4. Mechanism B: item-action sets (`SetEffect.shn`)

The only set mechanism with an effect in 2016. A set is a **name**: every `ItemInfo` row whose `SetItemIndex` is not
`"-"` belongs to the set of that name. The number of equipped cells holding an item of the set is the piece count; each
`SetEffect.shn` row (set, `Count`) grants its `ItemActionID` while at least `Count` pieces are worn. The granted id is an
ordinary item action (`ItemAction.shn` → `ItemActionCondition.shn` / `ItemActionEffect.shn`), registered in the player's
`ItemActionObserveManager` (`sp_ItemActionObserves`, player vt 0x5d0 `so_GetItemActionObserves` @ FUN_00560830) with the
key `0xFFFF`. What an item action does once registered (conditions, effects, cooldowns) is Z17's subject; §4.4 lists
only what the set-granted actions use and the two effect classes that exist for sets.

### 4.1 Table load and lookup

```pseudo
Table::Load<SetEffectTable>("SetEffect.shn")                          @ FUN_005b5ec0
    # called once from ZoneServer_zs_start_sleep @ FUN_005b67c0 (Z01 §2.3), between AmpCmdInit and ActionEffectItem.shn
    path = GetTableDir() + name                                       # "../9Data/Shine/SetEffect.shn" (Z01 §2.3)
    if not ITableBase<SetEffect,SetEffectTable>::Load(path, true):
        shineassert "Fail to read  : SetEffect.shn"; ShineExit(same text)   # the zone does not start

ITableBase<SetEffect,SetEffectTable>::Load(path, _):                  @ FUN_005b35b0
    if ms_pkTable == NULL: ms_pkTable = new SetEffectTable (0xC4 bytes)   # ctor @ FUN_005b1ec0: CDataReader at +4,
                                                                          #   m_acFilename[128] at +0x44 = "" ; registers the
                                                                          #   atexit destructor @ FUN_006a02c0 once
    m_kDataReader.ClearBF(); ok = m_kDataReader.Read(path)            # generic SHN reader (cipher: tools/protocol-re/shn.py)
    if not ok or m_pHead == NULL or m_pHead.nVersionKey != 0x10: return false   # HEAD+0 = file u32 @0 (SetEffect.shn: 16)
    strcpy(m_acFilename, path)
    return vt[1]()                                                    # SetEffectTable vt 1 = FUN_005af8d0, returns 1: no row check

ITableBase<SetEffect,SetEffectTable>::GetTotal() = m_pHead ? m_pHead.nNumOfRecord : 0       @ FUN_005c7e30
destructors: scalar deleting dtor @ FUN_005b1f00 (ClearBF, ~CDataReader, free); atexit @ FUN_006a02c0 (vt 0 + delete, ms_pkTable = NULL)

SetEffectTable::FindActionID(char *setName, int count, u16 *actionId) → bool        @ FUN_005c7eb0
    if count == 0 or actionId == NULL: return false
    for i in 0 .. GetTotal()−1:                                       # linear scan, file order, first match wins
        row = GetRecord(i)                                            # SetEffect row, §2.3
        if strcmp(setName, row.SetItemIndex) == 0 and row.Count == count:   # exact count, case-sensitive
            *actionId = row.ItemActionID; return true
    return false
```

The rows are used in place (`GetRecord`), no copy, no index; with 1,043 rows a lookup is ≤ 1,043 `strcmp`.

### 4.2 Piece count: `ShinePlayer::so_EqualSetitemIndexNameCount` @ FUN_00549a70 (player vt 0x5cc)

```pseudo
so_EqualSetitemIndexNameCount(p, char *setName) → int
    if setName == NULL or strcmp("-", setName) == 0: return 0          # "-" = no set (14,062 of 14,989 ItemInfo rows)
    n = 0
    for slot in 0 .. 29:                                              # every ItemEquipEnum slot (MAX_ITEMEQUIPENUM = 30)
        cell = p.sp_Item.itembag.ci_Equipment.vt[0](slot)
        if cell and (info = ItemDataBox[cell.itemid]) != NULL and strcmp(info.data.SetItemIndex, setName) == 0:
            n += 1
    return n
```

Piece-count rules (code + the 2016 data):

- **Cells, not distinct items, are counted.** Two copies of the same item count twice. Rings have the single `Equip` value
  15 (`ITEMEQUIP_LEFTRING`) in `ItemInfo` but can go into slot 15 or 16 (Z04 §5.2), so two rings of one set count 2. The
  data relies on it: 11 rows need more pieces than the set has distinct equip locations (`GabrielleSet` / `GlorySet` /
  `StrikingSet` / `PointSet` 3 = necklace + 2 rings; `WarNSet` and `Arena_70Acc` … `Arena_115Acc` 4 = necklace +
  earring + 2 rings; `SetValen` 2 = 2 rings).
- **Every equipment slot counts**, the costume slots included: 9 costume items (`ITEMCLASS_DECORATION`, slots 8 / 20 / 22
  `BODYACC` / `LEGACC` / `SHOESACC`) form the 3-piece sets `CosMusaAcRate`, `CosMusaCri`, `CosMusaAllStat`. Weapons count
  as one piece each (11 `Lab_*` / `BrillianceSet` weapons, slots 10 / 12).
- **KQ items** (`ITEMCLASS_KQ` 17, `KQSTEP` 21) are not equipment and none has a set name: nothing to count.
- Pieces by class: 490 armour (6), 375 boots (8), 42 accessories (4), 11 weapons (5), 9 decorations (10); 927 items in
  260 sets. Every set name used by an item has `SetEffect` rows; 133 `SetEffect` sets have no item (dead rows).
- Thresholds need not be consecutive: the 10 `Lab_*` sets have rows at 2, 4 and 5 only, the three costume sets only at 3.
  A count without a row grants nothing.
- No level, class or durability check: a worn piece counts even when its own stats would not apply *(inferred: the
  function reads nothing but the name)*.

### 4.3 When the set action ids are added and removed

Invariant kept by the four call sites: while the player wears *n* pieces of set *S*, every `SetEffect` row (S, c) with
c ≤ n has its action registered once. Each equip or unequip changes *n* by one, so each hook only adds or removes the
row at exactly the current count; the login setup adds all rows 1…n.

```pseudo
InvenCellReleaser_EquipLocation::icr_Apply(obj, lockedCell, _)       @ FUN_0048ca20   (equip lock applied, Z05 §1.4)
    obj.so_ply_ChangeBriefInfo(equipcell, slot) and for the other slot if any (vt 0x608); so_allparametercalculate (vt 0x57c);
    look re-broadcast (vt 0x4b4); position restored                    # Z05 §1.4 / Z12 §2
    cell = lc.equipchange.equipcell; p = ShineDynamicCast<ShinePlayer>(obj)
    if cell and p and p.so_GetItemActionObserves() and ItemDataBox[cell.itemid]:
        doWithActionIDs<ItemAcion_Add>(cell.itemid, p)   else assert "…icr_Apply itemaction Can`t Add ActionID. ShineItemID="
        if cell.itemid != 0xFFFF:
            if ItemInfo.Class == ITEMCLASS_WEAPON: the 3 gem ids of the weapon → doWithActionIDs<ItemAcion_Add>   # Z17
            name = ItemInfo.SetItemIndex
            n = p.so_EqualSetitemIndexNameCount(name)                  # the new piece is already in the cell
            if SetEffectTable::FindActionID(name, n, &id):
                if not p.so_AddItemAction(id, 0xFFFF):                 # vt 0x5d8 @ FUN_00560840 → ItemActionObserveManager::AddAction
                    shineassert "InventoryLocking::InvenCellReleaser_EquipLocation::icr_Apply Setitem Can`t Add ActionID", id

InvenCellReleaser_UnEquipInfo::icr_Apply(obj, lockedCell, _)         @ FUN_0048cc60
    p = obj if its RTTI chain contains ShinePlayer
    if p and p.so_GetItemActionObserves() and (cell = lc.equipchange.equipcell):
        doWithActionIDs<ItemAcion_Del>(cell.itemid, p)  else assert "InvenCellReleaser_UnEquipInfo::icr_Apply ItemAction Can`t Del ActionID. ShineItemID="
        if ItemDataBox[cell.itemid] and cell.itemid != 0xFFFF:
            weapon: the 3 gem ids → doWithActionIDs<ItemAcion_Del>
            n = p.so_EqualSetitemIndexNameCount(SetItemIndex)          # the leaving piece is still in the cell
            if FindActionID(SetItemIndex, n, &id) and not p.so_DelItemAction(id, 0xFFFF):   # vt 0x5dc @ FUN_00560880
                shineassert "ShineObjectClass::ShinePlayer::sp_NC_ITEM_EQUIP_REQ SetItem Can`t Del ActionID", id
                # log text names the equip handler, not the releaser (original bug) Z21-B6

ShinePlayer::so_ply_ItemAction_UnEquip(p, cell)   (player vt 0x5e0)  @ FUN_00565020
    # only caller: ItemInventory::ii_DropAll @ FUN_00529a70 for a cell of the equipment (inven & 0xFC00 == 0x2000),
    # before the cell is cleared (Z05 §3.1: dropping an equipped item)
    if cell and p.so_GetItemActionObserves() and id = cell.iic_ItemIdent() != 0xFFFF and ItemDataBox[id].data:
        doWithActionIDs<ItemAcion_Del>(id, p)   else assert "ShinePlayer::so_ply_ItemAction_UnEquip. ShineItemID="
        weapon: the 3 gem ids → Del (same assert)
        n = so_EqualSetitemIndexNameCount(SetItemIndex)                # cell still filled
        if FindActionID(SetItemIndex, n, &id) and not so_DelItemAction(id, 0xFFFF):
            shineassert "ShinePlayer::so_ply_ItemAction_UnEquip. SetItem Can`t Del ActionID", id

ShinePlayer::sp_ItemActionSetup(p)                                   @ FUN_00566420
    # only caller: sp_NC_MAP_LOGINCOMPLETE_CMD @ FUN_00443390 (Z01 §6), i.e. on every zone entry
    ItemActionObserveManager::Clear(p.sp_ItemActionObserves)          # drops every action, item, set and abstate alike
    if not p.so_GetItemActionObserves(): return
    seen = vector<string>()                                           # set names already handled
    for slot in 0 .. 29:
        cell = equipment[slot]; if not cell or not ItemDataBox[cell.ident]: continue
        doWithActionIDs<ItemAcion_Add>(ident, p)  else assert "ShinePlayer::so_GetItemActionObserves itemAction Can`t Add ActionID. ShineItemID="
        if ident == 0xFFFF: return                                    # dead: ItemDataBox[0xFFFF] is NULL (original bug) Z21-B3
        weapon: the 3 gem ids → Add (same assert)
        name = ItemInfo.SetItemIndex
        if name ∉ seen:
            seen.push(name)
            n = so_EqualSetitemIndexNameCount(name)                    # 0 for "-": nothing
            for c in 1 .. n:
                if FindActionID(name, c, &id) and not so_AddItemAction(id, 0xFFFF):
                    shineassert "ShinePlayer::so_GetItemActionObserves Setitem Can`t Add ActionID", id
    for each abnormal state s of p (p vt 0x52c container, +0xcb4 … list):    # abstate-granted actions, Z17
        if ActionEffectAbStateTable::FindActionID(abstate name, &id): so_AddItemAction(id, 0xFFFF) else assert "… Abstate Can`t Add ActionID"
    ItemActionObserveManager::SendCoolTimes2Client(p.so_GetItemActionObserves())     # Z17
```

Ordering, which the "count includes / excludes the piece" comments depend on: `icl_Apply_N_Free` applies the reservations
of a lock index in list order (Z05 §1.3), and both requests reserve in the right order: `sp_NC_ITEM_UNEQUIP_REQ`
@ FUN_0053a990 reserves `UnEquipInfo` (lock-list vt 0x54 = `icl_UnEquipInfo` @ FUN_004894b0) before the two cell moves
(vt 0x30 / 0x40) and the `EquipLocation` (vt 0x50 = `icl_EquipLocation` @ FUN_00489380) of the now empty cell;
`sp_NC_ITEM_EQUIP_REQ` @ FUN_0052b8d0 does `UnEquipInfo` → moves → `EquipLocation` for every conflicting item and then
for the item being replaced (if the slot held one), then the moves and `EquipLocation` of the new item. So a swap of two
pieces of the same set removes the row at *n* and adds it again. *(inferred: that the list is walked in insertion order;
the releasers read the item id from the cell, so the opposite order would remove nothing on unequip)*

Registration semantics (`ItemActionObserveManager::AddAction` @ FUN_005d17f0 / `DelAction` @ FUN_005d15e0, details in Z17):
`AddAction` appends a new observer for the action id (no duplicate check), so an id granted twice (by two sets — the
1,043 rows use only 401 distinct action ids — or by a set and an item) is registered twice; `DelAction` removes the
first observer with the same (id, key). Since every set observer has key 0xFFFF (as do abstate-granted ones), removing a
set's row removes one copy and the others stay: correct for duplicates. `AddAction` fails when the id is not in
`ItemActions::_actions` (the `find` result's action pointer is NULL, *(inferred)* for the end node) or the observer buffer is full ("ItemActionObserveBuffer::alloc Buffer Full"); every
`SetEffect.ItemActionID` exists in `ItemAction.shn`.

Equipped items leave the equipment only through these paths in the 2016 zone (the only callers of `so_DelItemAction`
are the two hooks above and `ase_DetachObject` @ FUN_00402000 for abstate actions); other removals of an equipped item,
if any exist, would leave the set action registered until the next zone entry *(inferred; Z04 / Z05 own the removal
paths)*.

### 4.4 What the set-granted actions do

Statistics of the 401 distinct action ids reachable from `SetEffect.shn` (`ItemActionEffect.EffectActivity` / the
condition's `ConditionActivity`, enum `ActionActivityType`):

| Effect activity | Actions | Meaning (Z17 owns the effect classes) |
|---|---|---|
| 5 `AAT_SkillEffectIncreaseType` (`ActionImpowerTypeEffect`) | 295 | skill empowerment, condition 7 `AAT_ActiveSkillGroupIndex` (the skill group cast); 21 of them (the `STA_*` subtypes) are stored in the abnormal state the skill sets (§5.3) |
| 2 `AAT_ABSTATEINDEX` (`AbStateTypeEffect`) | 64 | an abnormal state (value = abstate id, e.g. 507, 525, 541) |
| 1 `AAT_RecoverType` (`RecoverTypeEffect`, below) | 32 | 12 × `RT_HPABSOLUTEPLUS` (5…30 HP), 18 × `RT_SPABSOLUTEPLUS` (5…21 SP), 2 × `RT_HPABSOLUTEMINUS` |
| 9 `AAT_SetItemEffectType` (`ActionEffectTypeEffect`) | 10 | damage rate 1100 / 900 (× 1.1 / × 0.9) against / from one mob type (`ObjectTarget` / `SubjectTarget` = `ATT_MobType` 0, 1, 2, 3, 5) |

Conditions: 295 × activity 7, 70 × 8 (`AAT_ActionETCType`), 10 × 6 (`AAT_ActionRangeType`), the rest attack-type
conditions; 28 actions have a `CoolTime`.

```pseudo
MakeEffect(ItemActionEffect *e)                                       @ FUN_005d0060  (one IActEffect per ItemActionEffect row)
    e.EffectTarget must be ATT_TargetType (0) else assert "USE TargetType for EffectTarget" + ShineExit
    EffectActivity 0 → AttackTypeEffect, 1 → RecoverTypeEffect, 2 → AbStateTypeEffect, 3 → DispelAttrTypeEffect,
                   5 → ActionImpowerTypeEffect, 9 → ActionEffectTypeEffect (the set-item effect class),
                   8 → assert "ActionETCType Effect is exist yet" + ShineExit, other → "Unexpected condition type" + ShineExit
    # IActEffect = { vtable, ItemActionEffect *_effectData @4 }; vt 4 fallback, 5 _execute, 6 _typeValidationCheck

ActionEffectTypeEffect   (vt: fallback @ FUN_005d0010, _execute = AttackTypeEffect::_execute @ FUN_005d0000,
                          _typeValidationCheck = AttackTypeEffect::_typeValidationCheck @ FUN_005cfb80)
    _typeValidationCheck(arg) = (u16)e.EffectActivity == arg.effect.type and e.EffectActivityValue == arg.effect.subtype
    _execute(arg, obj)        = e.Value                                # a rate, base 1000
    fallback(arg)             = 1000 when (u16)e.EffectActivity == arg.effect.type and subtype == AT_SKILL (1);
                                asserts "Unknown effect.subtype.actionEffectType" for AT_NORMAL or other subtypes
    # IActEffect::_typeValidationCheck @ FUN_005cfb50 (the default) is false for activities 0, 5, 9: those need a typed match
    # enum SetItemEffectType { SIET_DEFAULT 0, SIET_DAMAGE_RATE_INCREASE 1 } *(pdb2016)*: the 10 rows have
    # EffectActivityValue 1 = SIET_DAMAGE_RATE_INCREASE, numerically AT_SKILL

ItemActionObserveManager::EventRun_IncDmgRate(m, att, def, AttackType condSub, ActionResults *out)   @ FUN_005d2010
    if out and att and def:
        arg = { condition {AAT_AttackType, condSub}, effect {AAT_SetItemEffectType, AT_SKILL}, me = m.owner,
                subject = att, object = def }
        return _EventRun(m, out, arg, 0xFFFF)                          # Z17: runs every matching observer, collects rates
    # callers: roe_AttackPower of the four rules (NormalPY @ FUN_00506660, NormalMA @ FUN_005068d0,
    # PhisycalSkill @ FUN_00506b40, MagicalSkill @ FUN_00506ed0), for the attacker's and the defender's manager;
    # the collected rate scales min/max attack (Z03 §4.6, "item actions of either side match")
```

```pseudo
RecoverTypeEffect::_execute(arg, ShineObject *t) → 0                 @ FUN_005cfc70
    v = e.Value (u16); switch e.EffectActivityValue (enum RecoverType):
      0 RT_HPABSOLUTEPLUS:  t.so_GainHP(v) (vt 0x504);                 Send_SETITEMHEALEFFECT(t, isheal 1, v)
      1 RT_HPRATEPLUS:      t.so_GainHP(MaxHP·v/1000);                 Send_SETITEMHEALEFFECT(t, 1, MaxHP·v/1000)
      2 RT_SPABSOLUTEPLUS:  t.so_GainSP(v) (vt 0x4fc)                  # SP: no packet
      3 RT_SPRATEPLUS:      t.so_GainSP(MaxSP·v/1000)
      4 RT_HPABSOLUTEMINUS: d = v
      5 RT_HPRATEMINUS:     d = MaxHP·v/1000
          d = t.so_ply_CheckDamageAbsorption(d) (vt 0xbe8); d = t.so_smo_LastDamageOperation(d, 0) (vt 0xdb4)   # Z03
          if d < t.so_GetHP(): t.so_DamagedBy(arg.me, d, 1000, 1) (vt 0x5c0)
          else:                t.so_KilledBy(arg.me, t.so_GetHP()) (vt 0x5bc)
          Send_SETITEMHEALEFFECT(t, isheal 0, d)
      6 RT_SPABSOLUTEMINUS: t.so_LostSP(v) (vt 0x4f8)
      7 RT_SPRATEMINUS:     t.so_LostSP(MaxSP·v/1000)
      other: nothing
    t.so_mobile_NotifyParameterChange(1) (vt 0x34)                    # every case, also "other"; Z12 §4
    # MaxHP / MaxSP = vt 0x4f0 / 0x4f4. ShinePlayer::so_GainHP @ FUN_00559ca0: CurHP += v, then
    # "if so_GetHP() <= CurHP: CurHP = so_GetHP()" — so_GetHP @ FUN_00559b70 is CurHP itself, so the cap never
    # applies and a set heal can lift a player's HP above MaxHP (original bug) Z21-B4 (the mob twin is Z09-B126).
    # ShinePlayer::so_GainSP @ FUN_00559bc0 caps at so_MaxSP correctly; so_LostSP @ FUN_00559b90 floors at 0.
```

The heal is not otherwise sent to the healed player: no HP packet is built here, the client only gets the number
(§4.5); `so_mobile_NotifyParameterChange` sends `0x1035` changes of the maximum stats only (Z12 §4). *(inferred: the
client's HP gauge follows with the next HP update)*

### 4.5 `0x206F NC_ACT_SETITEMHEALEFFECT` (Z→C broadcast)

Struct `PROTO_NC_ACT_SETITEMHEALEFFECT` *(pdb2016; the 2017 client PDB has the same 5 bytes)*:

| Off | Type | Field | Value |
|---|---|---|---|
| 0 | u16 | `who` | handle of the healed / damaged object (`so_handle`) |
| 2 | u8 bit 0 | `flag.isheal` | 1 = HP gained (recover types 0 / 1), 0 = HP lost (4 / 5); bits 1–7 keep whatever the shared send buffer held (only bit 0 is merged) (original bug) Z21-B7 |
| 3 | u16 | `hpchange` | amount, the 32-bit value truncated to 16 bits (original bug) Z21-B5 |

```pseudo
Send_SETITEMHEALEFFECT(ShineObject *t, u8 isheal, u32 amount)          @ FUN_005cfbb0
    if t == NULL: return
    pkt = gpp.pp_NetCommand(8, 0x6F); pkt.who = t.handle; pkt.flag.isheal = isheal & 1; pkt.hpchange = (u16)amount
    t.so_AllOfRange(allofrangearg++ (visit stamp), t.location, range 0 (map sight), AxialListPacketBroadcast(pkt, 7 bytes),
                    include self = 1, 0xFFFF)                          # every player in sight of t, t itself included (Z01 §3.2; Z09 knowledge "range queries")
    # only caller: RecoverTypeEffect::_execute (other functions merely share its EH handler)
```

Client: `GameFrameWork::On_NC_ACT_SETITEMHEALEFFECT` *(pdb2017 name; 2016 client FUN_0049bd20)* calls FUN_00692d10
(`DAT_00b441d0`, who, hpchange, style = isheal·4 | 1, 0): if the object is known and close enough to the camera, it
spawns a floating number (`sprintf "%u"`, one digit sprite per character) in style 5 (heal) or 1 (damage). Nothing else
(no HP gauge change) *(inferred from the code shape: FUN_00692d10 is the shared damage/heal number display)*.

## 5. Mechanism C: set-item values in abnormal states

Every abnormal-state element (`AbstateElementInObject`, 0x74 bytes, in the object's `smo_Abstate.abstatelist`, Z03 §6)
carries a `SetItemAbstateEffect aeo_SetItemEffect`: four `{code, value}` pairs written when a skill sets the state on a
target, read while it lasts (stat refit, heal over time, party recharge) and carried through map change, logout and
login. Despite the name, its only live source in 2016 is the **caster's item actions** of activity
`AAT_SkillEffectIncreaseType` (`SetEffect.shn` set actions among them, §5.3); the set-item source of mechanism A
stores nothing (§3.8).

### 5.1 Data structure and codes *(pdb2016)*

```pseudo
class SetItemData::SetItemAbstateEffect {          # 0x10, AbstateElementInObject.aeo_SetItemEffect
    EffectBuffer siae_Buffer[4]                     # EffectBuffer { u16 eb_Index @0; u16 Argument_Base1000 @2 }
}
# empty slot = { eb_Index 0, Argument_Base1000 1000 }
# eb_Index 1…16       = SetIndex (§3.1), source: mechanism A (dead)
# eb_Index 1000 + t   = SkillEffectIncreaseType t (0…14), source: item actions (live)
# 17…999, ≥ 1015      = never written by the zone; possible only from DB rows; read as "no code"

enum SkillEffectIncreaseType {   # SEIT_*, the subtype of ItemActionEffect activity 5 AAT_SkillEffectIncreaseType
    0 DAMAGE_RATE_INCREASE, 1 COOLTIME_RATE_DECREASE, 2 KEEPTIME_RATE_INCREASE, 3 USESP_RATE_DECREASE,
    4 STA_AC_RATE_DECREASE, 5 AGGRO_RATE_INCREASE, 6 STA_DEX_RATE_DECREASE, 7 SS_RATE_THHPUP,
    8 STA_MAX_HPSP_RATE_INCREASE, 9 STA_DEAD_HPSP_RECOVER_RATE_INCREASE, 10 STA_SHIELDAC_RATE_INDREASE,
    11 HEAL_RATE_INCREASE, 12 STA_DOT_HEAL_RATE_INCREASE, 13 STA_WC_RATE_INCEASE, 14 STA_SHEILD_BLOCK_RATE_INCREASE,
    15 MAX_SKILLEFFECTINCREASETYPE }          # (sic) spellings are the official ones
# STA_* = "applies to the abnormal state": exactly the eight types §5.3 stores. The others are read at cast time
# by the skill code (Z03 / Z09 §12, owner of the item-action evaluation Z17)
```

Constructors and clearing (all leave the four empty slots):

```pseudo
SetItemAbstateEffect::SetItemAbstateEffect()   @ FUN_00510350    # ctor; called by the element ctor
                                                                  # AbstateElementInObject @ FUN_00406550 and for the
                                                                  # stack "key" element of asl_Abstate_IsSet @ FUN_00409b10
                                                                  # and asl_AbstateReset @ FUN_0040a930 (Z03 §6.2 / §6.4)
siae_Clear()                                   @ FUN_00510030    # same body; called by aeo_Set @ FUN_0040a340
# element ctor @ FUN_00406550 also: Metronome aeo_Tick, aeo_Index = MAX_ABSTATEINDEX, aeo_PartyEnchant[0..4].skillindex = null,
#   aeo_Caster = {nLevel 0, nAttackPower 0}
# no destructor body: ~AbstateElementInObject @ FUN_00401b20 calls a shared empty COMDAT for the member
```

Accessors:

```pseudo
siae_GetArgument_Base1000(SetIndex s) → u16                     @ FUN_00510050
    for i in 0..3: code = buf[i].eb_Index; if code > 16: code = 17 (MAX_SETINDEX)
                   if code == s: return buf[i].Argument_Base1000
    return 1000
siae_GetArgument_Base1000ByEffect(SkillEffectIncreaseType t) → u16   @ FUN_00510090
    for i in 0..3: code = buf[i].eb_Index; k = code < 1000 or code − 1000 > 14 ? 15 : code − 1000
                   if k == t: return buf[i].Argument_Base1000
    return 1000
    # first match wins; 1000 = neutral
```

### 5.2 Writer 1: `aeo_SetItemEffectStore` (mechanism A source, stores nothing in 2016)

```pseudo
AbstateElementInObject::aeo_Set(e, …)                            @ FUN_0040a340   (Z03 §6.2)
    … after e.aeo_RestCount is taken from the element class (vt 0x28), only when abstatetemplate has a node for
      e.aeo_Index (the same test the tick setup uses):
    siae_Clear(&e.aeo_SetItemEffect)                             # every (re)set starts empty: a refresh by another
    aeo_SetItemEffectStore(e)                                    # caster drops the previous caster's values
    …

AbstateElementInObject::aeo_SetItemEffectStore(e)                @ FUN_00510670
    siae_Clear(&e.aeo_SetItemEffect)                             # (inlined, again)
    sub = abstateidentarray[e.aeo_Index].AbStateStr->subabstate[e.aeo_Strength]   # SubAbState row of this strength
    for each of the 4 sub.assa_Effect[j].action (SubAbstateAction):
        s = SAA_WCPLUS 3, WCRATE 4, MAPLUS 13, MARATE 46, MAMINUS 83, MADOWNRATE 84, WCMINUS 94, WCDOWNRATE 95 → SET_DAMEGERATE (2)
            SAA_ACPLUS 5, ACRATE 6, ACMINUS 73, ACDOWNRATE 74                                   → SET_ACRATE (3)
            SAA_DEXPLUS 7, DEXMINUS 81                                                          → SET_DEXRATE (8)
            SAA_THPLUS 10, THRATE 11, THMINUS 92, THDOWNRATE 93                                 → SET_THRATE (11)
            SAA_SPEEDRATE 20, SPEEDDOWNRATE 88                                                  → SET_MOVESPEEDRATE (10)
            SAA_MAXHPRATE 22, MAXSPRATE 23, MAXHPPLUS 35, MAXSPPLUS 36, MAXHPDOWNRATE 85        → SET_HPSPMAXRATE (14)
            SAA_HEALAMOUNT 30, HEALAMOUNTMINUS 82                                               → SET_HEALRATE (1)
            any other action                                                                    → skip
        siae_SetItemEffectStore(&e.aeo_SetItemEffect, s)

siae_SetItemEffectStore(SetIndex s)                              @ FUN_005100f0
    if s > 16 or setitemskilleffect.se_Argument[s] == 1000: return            # always returns in 2016 (§3.8)
    i = first slot whose code (> 16 read as 17) == s, or whose eb_Index == 0  (codes ≥ 17, e.g. 1000+, count as used)
    if none of the 4: assert "SetItemData::SetItemAbstateEffect::siae_SetItemEffectStore : Too many effect"; return
    buf[i] = { s, (u16) setitemskilleffect.se_Argument[s] }
    # a second action of the same group overwrites the same slot (no duplicates). The values are the CASTER's
    # snapshot: aeo_Set runs inside the caster's skill, while setitemskilleffect holds the caster's per-cast copy
    # (§3.5) (inferred)
```

`siae_ParameterRefit` applies `SET_DAMEGERATE` to WC only, although the MA actions (13, 46, 83, 84) are filed under it
too (original bug) Z21-B9 (latent while mechanism A is dead).

### 5.3 Writer 2: the caster's item actions, `so_ItemActonAbstateApp` (vt 0x5d4, live)

```pseudo
ShineMobileObject::so_ItemActonAbstateApp(caster, AbstateElementInObject *e, SkillDataIndex *skill, ShineObject *target)
                                                                 @ FUN_0055dea0   (vt 0x5d4, every mobile-object class)
    if e == null or skill == null or target == null: return
    if caster.so_GetItemActionObserves() (vt 0x5d0) == null: return     # players: their manager (FUN_00560830);
                                                                        # mobs: FUN_00570b00 = shared `return 0`
                                                                        # COMDAT, so only player casters write
    for t in [SEIT_STA_AC_RATE_DECREASE 4, STA_DEX_RATE_DECREASE 6, STA_MAX_HPSP_RATE_INCREASE 8,
              STA_DEAD_HPSP_RECOVER_RATE_INCREASE 9, STA_SHIELDAC_RATE_INDREASE 10, STA_DOT_HEAL_RATE_INCREASE 12,
              STA_WC_RATE_INCEASE 13, STA_SHEILD_BLOCK_RATE_INCREASE 14]:         # this order
        results = {}
        if EventRunBySkillGroupIndex(manager, &results, skill, t, caster, target):
            aeo_SetItemActionEffect(e, t, GetRateAppliValue(&results, 1000))
        results.clear()

ItemActionObserveManager::EventRunBySkillGroupIndex(m, out, skill, t, me, object) → bool   @ FUN_005d1f50
    if skill == null or me == null or out == null: return false
    arg = { condition {AAT_ActiveSkillGroupIndex 7, group}, effect {AAT_SkillEffectIncreaseType 5, t},
            me = subject = me, object }
    for each group of skill.sdi_ActiveSkillGroups (its id at group+0x20):
        if _EventRun(m, out, arg, 0xFFFF): any = true                   # Z17: every matching observer appends a result
    return any

ItemActionObserveManager::ActionResults::GetRateAppliValue(results, base) → u32   @ FUN_005d0c20
    if base == 0: return 0
    for each result r (8 bytes, rate at +4): base = r.rate · base / 1000         # product of the rates, base 1000
    return base

AbstateElementInObject::aeo_SetItemActionEffect(e, t, v) → true   @ FUN_00510810
    siae_SetItemEffectAndValue(&e.aeo_SetItemEffect, t, v)

siae_SetItemEffectAndValue(SkillEffectIncreaseType t, int v)     @ FUN_00510170
    i = first slot whose code − 1000 == t (codes < 1000 or > 1014 never match) or whose eb_Index == 0
    if none of the 4: assert "SetItemData::SetItemAbstateEffect::siae_SetItemEffectAndValue : Too many effect"; return
    buf[i] = { 1000 + t, (u16) v }               # no "== 1000" filter; v truncated to 16 bits (original bug) Z21-B10
```

Call sites (both right after a successful `target.so_AbnormalState_Set(caster, …)` (vt 0x638) of a skill's abstate, on the
element found again with `asl_Abstate_IsSet`): `ShineMobileObject::so_SkillEnchant` @ FUN_00431ca0 (the enchant /
buff path) and `ShineMobileObject::smo_SkillBlast` @ FUN_00581160 (the damage-skill path, Z03 §5.6; `so_SkillEnchant` itself is §5.7). The order is:
`aeo_Set` clears the buffer → mechanism A stores nothing → the item-action values are written. `so_AbnormalState_Set`
only marks the stats dirty (`so_RecalcAbstateParamReady` vt 0x528 @ FUN_005556b0 sets `smo_Abstate.parameterchange`),
so the refit (§5.4) sees the values at the next recalculation. Party copies of the state (party enchant) and states set
by anything else than these two skill paths (items, scripts, GM, login restore, revive) get no item-action values.

What the 2016 data feeds in (ItemAction → ItemActionEffect with `EffectActivity` = {5, t}; condition always
`AAT_ActiveSkillGroupIndex`, i.e. the caster must cast a skill of the listed group):

| t | Read by | Item actions (of them set actions from `SetEffect.shn`) | Values |
|---|---|---|---|
| 4 STA_AC_RATE_DECREASE | refit `R.AC += v − 1000` | 2 (2) | 800 ×2 (target AC −20 %) |
| 6 STA_DEX_RATE_DECREASE | refit `R.Dex` | 1 (1) | 750 |
| 8 STA_MAX_HPSP_RATE_INCREASE | refit `P.MaxHP`, `P.MaxSP` scaled (Z12-B3) | 1 (1) | 1250 |
| 9 STA_DEAD_HPSP_RECOVER_RATE_INCREASE | `SubAbnormalStateActorPartyRecharge::sasa_Act_Killed` | 1 (1) | 1300 |
| 10 STA_SHIELDAC_RATE_INDREASE | refit `R.ShieldAC` | 1 (1) | 1250 |
| 12 STA_DOT_HEAL_RATE_INCREASE | HP heal-over-time routines | 10 (10) | 1250 ×8, 1300 ×2 |
| 13 STA_WC_RATE_INCEASE | refit `R.WCmin/WCmax` | 3 (3) | 750, 700, 1200 |
| 14 STA_SHEILD_BLOCK_RATE_INCREASE | refit `R.ShieldAC` (same cell as 10) | 3 (2) | 1250, 1300 (+ one non-set) |

So 21 of the 401 set actions (§4.4: 295 are `AAT_SkillEffectIncreaseType`) end up in abnormal states; the other 274
(types 0, 1, 2, 3, 5, 7, 11) act at cast time. `ShieldAC` = shield block (Z12 §1.1 stat 26) *(inferred from the enum
name of 14)*.

### 5.4 Readers

```pseudo
siae_ParameterRefit(&e.aeo_SetItemEffect, P)        @ FUN_005108c0, from aeo_ParameterEnchant @ FUN_004079f0 — Z12 §2.5
    pass 1 (codes 1…16): SET_DAMEGERATE → R.WC, ACRATE → R.AC, DEXRATE → R.Dex, MOVESPEEDRATE → R.MoveSpeed,
                         THRATE → R.TH, HPSPMAXRATE → P.MaxHP/MaxSP × v/1000
    pass 2 (codes ≥ 1000): 1000 (SEIT 0) and 1013 → R.WC; 1004 → R.AC; 1006 → R.Dex; 1008 → P.MaxHP/MaxSP (Z12-B3);
                           1010 and 1014 → R.ShieldAC
    # 1000 (DAMAGE_RATE_INCREASE) is never written by §5.3 (not in its list): only a DB row can carry it.
    # 1009 and 1012 are not refit codes; their readers follow.
    # The matrix is the TARGET's (the state's owner): e.g. a caster's AC-down rate 800 makes the debuff take 20 % AC.

SubAbnormalStateActorHPHeal::sasa_Routine(actor, e, o, idx)      @ FUN_00406e90   (SubAbState type 29, every tick; Z03 §6.1)
    caster = aeo_FindCasterObject(e, …)
    h = HEALAMOUNT − HEALAMOUNTMINUS (of this strength); if h == 0: h = o.MaxHP (vt 0x4f0) · HEALRATE / 1000
    h = h · siae_GetArgument_Base1000(SET_HEALRATE) / 1000                      # always 1000 in 2016
    h = h · siae_GetArgument_Base1000ByEffect(SEIT_STA_DOT_HEAL_RATE_INCREASE) / 1000
    o.vt[0x734](caster, h, idx)                                                 # heal (Z03)
    SubAbnormalStateActor::sasa_Routine(…)                                      # base tick bookkeeping
SubAbnormalStateActorHPSPHeal::sasa_Routine                      @ FUN_00407120   (type 66)
    HP: (HEALAMOUNT − HEALAMOUNTMINUS) scaled by the same two factors (no MaxHP-rate fallback), o.vt[0x734]
    SP: o.vt[0x738](caster, HEALAMOUNT)                                         # unscaled, no set-item factor
SubAbnormalStateActorPartyRecharge::sasa_Act_Killed(actor, killer p, e)   @ FUN_00407730
    if p's party (vt 0x550) != 0xFFFF:
        r = DEADHPSPRECOVRATE of the state · ByEffect(SEIT_STA_DEAD_HPSP_RECOVER_RATE_INCREASE) / 1000
            # guarded by "&e.aeo_SetItemEffect != null", always true (original bug) Z21-B11 (dead check)
        party has 2…5 members (else assert): every member found by pm_FindMember that is alive (vt 0x484 ∉ {0, 3})
        and within distance² < 1,000,000 of p: member.vt[0x7a0](r)                # recharge (Z03 / Z08)
```

### 5.5 Saving: `ABSTATEREADBLOCK.setitem[4]`

```pseudo
siae_FillSetItemEffect(buf, ABSTATEREADBLOCK *r)   @ FUN_00510300:  r.setitem[i] = { buf[i].eb_Index, buf[i].Argument_Base1000 }, i = 0..3
aeo_FillSetItemEffect(e, r)                       @ FUN_004534f0:  siae_FillSetItemEffect(&e.aeo_SetItemEffect, r)

ShinePlayer::so_SaveAbstate(p, PROTO_NC_CHARSAVE_ABSTATE_REQ *out, Name5 *charId, bool toDB) → bytes   @ FUN_00454d80 (vt 0x3a4)
    out.abstatenum = 0
    b = g_AbstateNeverShelter.as_GetAbstateBuffer(p.charNo (vt 0x344))   # FUN_00417d90, §5.6  # = Z03's g_ShelterDie DAT_0087c4c8: IsSaveDie states kept while dead (Z03 §7.2)
    if b: AbstateBuffer::ab_SaveAbstate(b, out, toDB)                    @ FUN_00417b90
    p.abstatelist (p+0xe7c).l_4AllInList(AbnormalStateSaver { out, charId, charNo, toDB })   # lid_Call per element
    return abstatenum == 0 ? 0 : 8 + abstatenum · 0x24

AbnormalStateSaver::lid_Call(s, e, i) → continue?    @ FUN_00454b10     (and ab_SaveAbstate, the same per element)
    row = dic_abstate[e.aeo_Index] (index ≥ 792: assert "…as_FromIndex : Invalid skill idx"); null: assert "Null Abstate"; next
    skip unless row.pSaveTypeInfo.(toDB ? IsSaveLogoff : IsSaveLink)       # AbStateSaveType table (Z03)
    row.index.ID == 0xFFFF: assert "Invalid ABState"; next
    # ab_SaveAbstate also skips sheltered states already past their end tick
    r = &out.abstate[out.abstatenum]   (0x24 bytes, layout Z12 §6.4)
    r.abstateid = row.index.ID;  r.strength = e.aeo_Strength;  r.restcount = e.aeo_RestCount;  r.empower = 0
    r.pasttime = (now − e.aeo_Tick.start) · 1000 / 10   (ms);  r.resttime = element class present ? aeo_GetRestTime(e) : 0
    aeo_FillSetItemEffect(e, r)  /  siae_FillSetItemEffect(&e.aeo_SetItemEffect, r)
    r.CasterInfo = { e.aeo_Caster.nLevel, e.aeo_Caster.nAttackPower }
    (lid_Call: if charId: NameString[charId], result unused)
    out.abstatenum++;  if abstatenum · 0x24 + 0x2c > 8000: stop             # at most 222 rows
```

Two senders (Z01 §8.4 `WholeSaver`): `ws_save2DB` @ FUN_00455a10 calls vt 0x3a4 with `(buf, null, true)` →
GameDB `0x4007 NC_CHARSAVE_ABSTATE_REQ` (states with `IsSaveLogoff`) → `p_Char_SetStateWithSetItemAndRestTime` per row,
`@nSetItemIndexA…D` / `@nSetItemValueA…D` = `setitem[0..3]` (D02 §6, D06 §7.2; table `tCharacterState`).
`ws_save2worldmanager` @ FUN_004536f0 calls it with `(buf, so_CharName())` and an implicit `false` (the `push 0` at
asm 0x453957 is left on the stack for the third argument: `so_CharName` @ FUN_00559780 takes none) → WM `0x4011`
(states with `IsSaveLink`), which the WM hands to the next zone as `0x1023 NC_CHAR_ZONE_ABSTATE_CMD` (W01 §6.3, row
"+0x590 abstate"). Both bind / copy `Value` as u16; the DB columns are `smallint` *(db-backup)*.

### 5.6 Restoring

- **Login / map change:** `0x100C NC_CHAR_ABSTATE_CMD` (from `p_Char_GetStateAllWithSetItemAndRestTime`, D02) or
  `0x1023` → `so_CharAbstateData` @ FUN_0044e0e0 → `asl_Store` @ FUN_0040afd0 (Z12 §6.4): the state is set again
  (`so_AbnormalState_Set` → `aeo_Set` clears the buffer), then
  `siae_SetItemEffectRestore(&el.aeo_SetItemEffect, r)` @ FUN_005102b0 copies `r.setitem[0..3]` back verbatim
  (`eb_Index = Index`, `Argument_Base1000 = Value`; no range check: any code reaches the readers of §5.4, which ignore
  unknown codes). So a buffed player keeps the caster's item-action rates on the state across map change and relog.
- **Revive:** the death shelter (`g_AbstateNeverShelter` *(pdb2016)* = Z03's `g_ShelterDie`, filled at death, Z03 §7.2–7.3) keeps whole element copies, but
  `AbstateBuffer::ab_Recover` @ FUN_00417ef0 → `AbstateElementInObject::aeo_Recover` @ FUN_004176c0 re-sets each state
  through `so_AbnormalState_Set(caster obj, index, strength, row, now, 0, restcount, rest ms, 0xb, 0)` and does not copy
  `aeo_SetItemEffect` back: `aeo_Set` has cleared it, so a revived player loses the values (original bug) Z21-B8 —
  while `ab_SaveAbstate` saves them from the shelter when the player logs out dead, so relogging instead of reviving
  keeps them.
- **Revive by item** (`UseItemJustReviveAtDead`, Z04 §12.3 `0x3039 NC_ITEM_REVIVEITEMUSE_CMD`: "on the DB success the actor's uib_Effect revives the player"):
  the same loss, through both shelters:

```pseudo
UseEffect::UseItemJustReviveAtDead::uib_Effect(actor, ShineObject *p, item, fns)   @ FUN_00418b60
    p.so_ReviveByItem() (vt 0xa98)               @ FUN_00417850  = sp_ReviveNow(p, 1000)  (full HP, Z03 §7.3)
    g_AbstateShelter[p.charNo].ab_Recover(p)     # = Z03's g_ShelterItem DAT_0087c4d8 (good buffs kept by the keep-buff item)
    g_AbstateNeverShelter[p.charNo].ab_Recover(p) # = g_ShelterDie DAT_0087c4c8 (IsSaveDie states)
    g_AbstateNeverShelter.as_Remove(p.charNo)
    # g_AbstateShelter's entry is not removed here (the 0x104E revive path and the skill revive free it, Z07 §3.1 /
    # Z03 §7.3); see §6
```

  Both `ab_Recover` calls go through `aeo_Recover` (Z21-B8): no set-item value survives an item revive either.
  The shelter helpers *(pdb2016)*, `AbstateShelter` = `std::vector<AbstateBuffer> as_Safe`, `AbstateBuffer` (0x14) =
  `{ u32 charNo @0 (0xFFFFFFFF = free); std::vector<AbstateElementInObject> ab_List @4 }` (elements of 0x74 bytes,
  whole copies, so the shelter copy keeps its `aeo_SetItemEffect`):

```pseudo
AbstateShelter::as_GetAbstateBuffer(sh, charNo) → AbstateBuffer* or null     @ FUN_00417d90   (linear search)
AbstateShelter::operator[](sh, charNo) → AbstateBuffer*                       @ FUN_00418890
    existing buffer of charNo, else the first free one (charNo written into it), else push_back a new empty buffer
AbstateShelter::as_Remove(sh, charNo)                                         @ FUN_00417520
    every buffer with this charNo: charNo = 0xFFFFFFFF   # marks it free; its ab_List elements are kept until reuse
# the filler, so_KilledBy @ FUN_00433be0 (Z03 §7.2), takes operator[](charNo) and resizes ab_List to 0 before copying
# (g_AbstateShelter only when the player carries itemdatabox.idb_specialid.sii_JustReviveItem, the NeverShelter always)
AbstateBuffer::~AbstateBuffer()                                               @ FUN_00418490   (destroys ab_List)
```
- Nothing about the buffer is sent to any client: it is server-side only.

### 5.7 The enchant path: `ShineMobileObject::so_SkillEnchant` (vt 0x5a0)

The abnormal-state part of every skill hit (Z03 §5.6 part E summarises it inline without the address). It is the place
where a skill's state, its keep time, the caster's item-action keep-time rate, the set-item keep-time rate
(`SET_ABSTATEKEEPTIMERATE`) and the mechanism C writer (§5.3) meet. Same body for every mobile-object class.

```pseudo
ShineMobileObject::so_SkillEnchant(caster, ShineObject *target, SmashArgument *a, BattleObjectStruct *bo,
                                   u8 *resisted, bool canDamage /* unused */) → bool enchanted   @ FUN_00431ca0   (vt 0x5a0)
    # SmashArgument (0xa): { u8 actionnumber, u8 attackcode, u8 iscritical, u8 isdead, SkillDataIndex *sklidx @4,
    #                        SKILL_EMPOWER empower @8 (u16 bit fields damage:4, sp:4, keeptime:4, cooltime:4) }
    if target == null or target.smo_GetMode() (vt 0x484) == 3 (dead): return false
    s = a.sklidx
    if s == null: assert "ShineObjectClass::ShinePlayer::sp_NC_BAT_SKILLENCHANT_REQ : Blast invalid spell"; return false
        # assert texts name another function (original bug) Z21-B12
    *resisted = 0;  enchanted = false
    if s.sdi_ToggleData is not empty:                                    # toggle skill
        if s.sdi_Activ == null: return false
        if not caster.so_ply_ToggleSkill_IsOn(s.sdi_Activ.ID) (vt 0xbc4):    # toggled off by this cast
            for each of the 4 entries s.sdi_Abstate[i] (12 bytes: abstateidx, strength, sucrate) with idx ≠ MAX_ABSTATEINDEX:
                if caster.so_mobile_AbstateList().asl_Abstate_IsSet(idx):  # on the CASTER, not the target
                    caster.so_AbnormalState_Reset(idx) (vt 0x650); BitReset(idx); BroadcastReset(idx)
            return false
    if target.so_AbnormalState_IsSet(STA_IMMORTAL 291) or IsSet(STA_ADLFLOUSSIERIMT 499) (vt 0x3e4): return false
    if s.sdi_Activ == null: assert "…sp_NC_BAT_SKILLENCHANT_REQ : Blast invalid spell activ"; return false
    if s.sdi_Activ.EffectType == SE_HEALING and not caster.smo_ICanHealTo(target) (vt 0xe94): return false
    for i in 0..3:  (idx, strength, sucrate) = s.sdi_Abstate[i]
        if idx == MAX_ABSTATEINDEX or rand(1000) (well512) ≥ sucrate or dic_abstate[idx] == null: continue
        row = dic_abstate[idx]
        if target.so_AbnormalState_Resist(row) (vt 0x634, Z03 §6.2): *resisted |= 1; continue
        bonus = a.empower.keeptime ≠ 0 ? s.sdi_Activ.nT2[empower.keeptime − 1] : 0
                # the code reads nT1[keeptime + 4] (asm 0x431ef8: [Activ + 4·k + 0x1e3]) = nT2[k − 1]; k ≥ 6 reads into nT3
        base  = row.subabstate[strength].assa_info ? SubAbStateInfo.KeepTime : 0           # ms
        if caster.so_GetItemActionObserves() (vt 0x5d0) and s.sdi_ActiveSkillGroups not empty:
            results = {}
            if EventRunBySkillGroupIndex(manager, &results, s, SEIT_KEEPTIME_RATE_INCREASE 2, caster, target):   # §5.3
                base = GetRateAppliValue(&results, base)                 # item-action (incl. set-action) keep-time rate
        extra = 0
        for each group g of s.sdi_ActiveSkillGroups until a null entry:
            if g.(+0x20) == 99:                                          # group 99 = buffs scaled by the passive rate
                x = bonus + base
                extra = x < 3,600,000 ? caster.smo_Param.PassiveBuffKeepTimeUPRate · x / 1000
                                      : PassiveBuffKeepTimeUPRate · (x / 1000)
                break
        keep = base + extra + bonus
        if not target.so_AbnormalState_Set(caster, idx, strength, row, now, 0, 0xFFFFFFFF, keep, 5, 0) (vt 0x638, Z03 §6.2):
            continue                                                     # aeo_Set applies SET_ABSTATEKEEPTIMERATE itself
        str = g_NewAbstateStrength                                       # the strength the set actually stored
        e = target.so_mobile_AbstateList().asl_Abstate_IsSet(row.index.AbStataIndex)
        if e: caster.so_ItemActonAbstateApp(e, s, target) (vt 0x5d4)     # §5.3: mechanism C values
        el = e ? aeo_GetAbstateElement(e) : null   (null: assert "BattleObjectGroup::BattleObject::bo_Routine: invalid abstate[ 2]")
        if el and not el.vt[0xc]():                                      # vt 0xc = shared `return 0` (FUN_004b8d20) for
                                                                         # all three element classes: always taken
            target.so_AbnormalState_BitSet(idx)
            v = setitemskilleffect[SET_ABSTATEKEEPTIMERATE]              # 1000 in 2016 (§3.8)
            k = keep < 3,600,000 ? v · keep / 1000 : v · (keep / 1000)
            target.so_AbnormalState_Inform(idx, k, 1) (vt 0x3f0, Z03 §6.3)    # players: the state packet to the owner
            target.so_AbnormalState_BroadcastSet(idx, k, str)                   # Z03 §6.3
        enchanted = true                                                 # asm 0x4321ba: set after every successful Set
    return enchanted
```

Callers: `smo_SkillBlast` @ FUN_00581160 (Z03 §5.6) once per target on the last hit step (`mha_HitStep < 0`) when the
target is not immune; the return value sets the result's
`isenchant`, `*resisted` ORs into `isresist`. The only other caller, `ShineMobileObject::smo_old_skill_blast`
@ FUN_00579b50 (player override @ FUN_0057be40 just forwards; it also calls `so_skillsmash` vt 0x59c), sits in vt 0xEA4,
which no code calls (no `+ 0xea4` virtual call in the zone): dead legacy code *(inferred)*.

So with the 2016 data the set-related inputs here are: the set actions with `SEIT_KEEPTIME_RATE_INCREASE` (§4.4, they
lengthen the caster's buffs/debuffs when cast from the listed skill group) and `SET_ABSTATEKEEPTIMERATE` (always 1000).
Z03 §5.6 part E describes the empower keep-time bonus as a bonus to the success *rate*; the code adds `nT2[k − 1]` to
the keep time and rolls the plain `sucrate`.

### 5.8 Heal over time: `so_mobile_HPHealOverTime` / `so_mobile_SPHealOverTime` (vt 0x734 / 0x738)

The heal step of the HoT actors (§5.4; Z09 §12.5 calls it for the magic-field heal with `MAX_ABSTATEINDEX`). Same body
for every mobile-object class.

```pseudo
ShineMobileObject::so_mobile_HPHealOverTime(o, ShineObject *caster, int heal, ABSTATEINDEX idx)   @ FUN_0040e910 (vt 0x734)
    f = setitemskilleffect[SET_HPSPRECOVERYRATE]                         # 1000 in 2016 (§3.8)
    before = o.so_GetHP() (vt 0x4e8)
    o.so_Heal(f · heal / 1000) (vt 0x4e4)                                # × HealRate ‰, capped at MaxHP (Z09 §17.3)
    resthp = o.so_GetHP() − o.so_batobj_GetDamage() (vt 0x65c, reads smo_BattleObject +4 = o+0x1d80)
    healed = o.so_GetHP() − before
    # RankingValue script events (Z09 §14.3, bug Z09-B39): Lua function 0xAC with
    #   { caster's field, caster as player (vt 0xbbc), dealt = healed } when the caster is a player on a field
    #   whose script has a RankingValue name, and { o's field, o as player, healed-part = healed } likewise for o
    Broadcast to every player in range of o (so_AllOfRange, AxialListPacketBroadcast, 15 bytes):
        0x243C NC_BAT_DOTDAMAGE_CMD { u16 object = o.handle, u32 resthp, u16 damage = 0, u16 abstate = idx,
                                      u16 hpchangeorder = o.so_mobile_GetHPChangeOrder() (vt 0x7e8), u8 IsMissDamage = 0 }
        # layout as the verified one in packets-zone.md (0x243C, basis alms_SelfKill). Client handler FUN_004b5740
        # (partly read): a damage number only when damage ≠ 0 (and abstate ∉ {0x0E, 0x153, 0x318}); resthp == 0 runs
        # the death display; so a HoT tick shows no number, only the HP update

ShineMobileObject::so_mobile_SPHealOverTime(o, ShineObject *caster, int sp)   @ FUN_004055d0 (vt 0x738)
    o.so_recoversp(setitemskilleffect[SET_HPSPRECOVERYRATE] · sp / 1000) (vt 0x5b8)    # no packet here, no ranking
```

The item-action rate `SEIT_STA_DOT_HEAL_RATE_INCREASE` (§5.3, 10 set actions) is applied by the HP actors before the
call (§5.4), never to SP; `SET_HPSPRECOVERYRATE` (mechanism A) is the only factor inside, and is neutral in 2016.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z21-B1 | `sp_SetItemCheck` FUN_00510b50, `sic_SetItemDefine` FUN_00510370, `siel_AppendEffect` FUN_005104c0 (§3.2) | `SetItem.shn` / `SetItemEffect.shn` are never loaded; `sic_TotalNumber` stays 0, `ItemDataBoxIndex.SetItemIndex` stays 0xFFFF, `setitemeffectlist` stays empty | the legacy skill-effect set bonuses (235 described effects) never apply; all `g_SetEffect` multipliers are 1000; the code runs on every equip change and cast for nothing | legacy path superseded by `SetEffect.shn` item actions *(inferred)*, left wired in |
| Z21-B2 | `sp_SetItemCheck` FUN_00510b50 (§3.3) | `break` when `ItemDataBox[id]` is NULL | pieces after an unknown item id in the bag are not counted (moot while B1 holds) | `continue` |
| Z21-B3 | `sp_ItemActionSetup` FUN_00566420 (§4.3) | after `ItemDataBox[ident]` succeeded, `ident == 0xFFFF` returns from the whole setup | dead: `ItemDataBox::operator[]` @ FUN_00419020 returns NULL for 0xFFFF; if reached, the remaining slots, the abstate actions and `SendCoolTimes2Client` would be skipped | `continue` (skip an empty cell) |
| Z21-B4 | `ShinePlayer::so_GainHP` FUN_00559ca0, reached from `RecoverTypeEffect::_execute` FUN_005cfc70 (§4.4) | caps CurHP at `so_GetHP` (= CurHP) instead of `so_MaxHP` | set (and other item-action) heals `RT_HPABSOLUTEPLUS` / `RT_HPRATEPLUS` can raise a player's HP above MaxHP until the next clamp (e.g. after an equip change, Z12 §3.2); 12 set actions heal HP | cap at `so_MaxHP` (player twin of Z09-B126) |
| Z21-B5 | `Send_SETITEMHEALEFFECT` FUN_005cfbb0 (§4.5) | `hpchange` is u16, the amount u32 | amounts ≥ 65,536 (rate types on very high MaxHP) show wrapped; latent with the 2016 set data (absolute 5…30) | u32 field, or clamp to 0xFFFF |
| Z21-B6 | `InvenCellReleaser_UnEquipInfo::icr_Apply` FUN_0048cc60 (§4.3) | the set-action delete failure logs "ShineObjectClass::ShinePlayer::sp_NC_ITEM_EQUIP_REQ SetItem Can`t Del ActionID" | misleading log (names the equip handler) | the releaser's own name |
| Z21-B7 | `Send_SETITEMHEALEFFECT` FUN_005cfbb0 (§4.5) | only bit 0 of the `flag` byte is written (`b ^= (b ^ isheal) & 1`) | bits 1–7 carry stale buffer bytes to the client; harmless, the client masks bit 0 | write the whole byte |
| Z21-B8 | `AbstateElementInObject::aeo_Recover` FUN_004176c0 via `ab_Recover` FUN_00417ef0, from the skill revive (Z03 §7.3) and the item revive `uib_Effect` FUN_00418b60 (§5.6) | re-sets each sheltered state through `so_AbnormalState_Set` → `aeo_Set` (which clears `aeo_SetItemEffect`) and does not copy the sheltered element's set-item buffer back | a revived player's states lose the caster's item-action rates (AC/Dex/WC/ShieldAC/MaxHPSP refit, DoT-heal and party-recharge factors); logging out dead keeps them (`ab_SaveAbstate` saves the shelter copy) | copy `aeo_SetItemEffect` back after the re-set, as `asl_Store` does at login |
| Z21-B9 | `aeo_SetItemEffectStore` FUN_00510670 / `siae_ParameterRefit` FUN_005108c0 (§5.2) | the MA actions (SAA 13, 46, 83, 84) are filed under `SET_DAMEGERATE`, which the refit applies to WC only | a magic-attack state would get its set rate on WC; latent (mechanism A stores nothing, Z21-B1) | refit MA too, or a separate MA index |
| Z21-B10 | `siae_SetItemEffectAndValue` FUN_00510170 (§5.3) | the 32-bit rate product of `GetRateAppliValue` is stored as u16 (and saved as `smallint`, D06 §7.2) | products ≥ 65,536 wrap (≥ 32,768 may fail the DB bind); latent with 2016 data (single rates 700…1300) | clamp, or a wider field |
| Z21-B11 | `SubAbnormalStateActorPartyRecharge::sasa_Act_Killed` FUN_00407730 (§5.4) | tests `&e.aeo_SetItemEffect != null` (address of a member of a non-null element) | dead check, always true; harmless | no test |
| Z21-B12 | `ShineMobileObject::so_SkillEnchant` FUN_00431ca0 (§5.7) | its asserts name `ShinePlayer::sp_NC_BAT_SKILLENCHANT_REQ` and `BattleObject::bo_Routine` | misleading logs (the function is the mobile-object enchant step, for every caster class) | the function's own name |

## 6. Not reconstructed / uncertain

- How the legacy tables were meant to be loaded (`SkillGroup` + `From`/`To` → `skilllist`, set name → set id in
  `ItemDataBoxIndex.SetItemIndex`): no loader exists in the 2016 zone; the mapping in §2.2 is *(inferred)* from the
  member names. The 2015 zone could be diffed for an older loader (not documented here: 2015 is out of scope).
- Whether `icl_Apply_N_Free` walks the lock list strictly in insertion order (§4.3 relies on it; the list class
  is `InventoryLocking::InventoryCellLockList`, Z05 §1.2–1.3).
- What the client does with `0x206F` beyond the floating number (FUN_00692d10 is unnamed in the 2016 client; the 2017
  PDB names only the handler). Whether the player's HP gauge is refreshed after a set heal (§4.4).
- §5.3 `EventRunBySkillGroupIndex` / `_EventRun` internals (which observers match, cooldowns, `ActivityRate` roll) are
  Z17's; the table of §5.3 assumes every matching action fires.
- `so_batobj_GetDamage` (vt 0x65c, FUN_005556f0, reads `smo_BattleObject` +4 = o+0x1d80) is subtracted from the HP sent as
  `resthp` in the HoT packet (§5.8): which pending damage it holds was not traced (Z03's battle object).
- The `0x243C` client handler FUN_004b5740 was read only as far as the damage number / death branch (§5.8).
- `uib_Effect` (§5.6) recovers `g_AbstateShelter` without freeing it, and the death filler only resets that entry when
  the player carries the keep-buff item: after an item revive the stale copy stays until a `0x104E` / skill revive frees
  it. It could only come back through another item revive after a death without the item (i.e. the item obtained while
  dead), so it is not listed as a bug *(inferred)*.
- Whether the WM keeps `0x4011` rows byte-exact into `0x1023` (W01 §6.3 says the blob is cached; the set-item words are
  assumed untouched).

## 7. Coverage boundary

Sweep method: every `//==== FUNC` of the zone PDB export whose name contains `SetItem`, `SetEffect`, `SkillEffect`,
`EffectBy` or `EffectDesc` (87; all set-item ones are cited here; the rest are `SkillEffectApply::*` blast code (Z03 §5.6)
or verbs like `SetItemDiceGameMode`, `so_mob_SetItemDropMobID`, `so_mh_reSetItemInfoOpen`, `sohu_SetEffectHandle`), every
string with `SetItem` / `SetEffect` (all referencing functions cited), the callers and callees of every function cited
here (profiler, logging, `std::` and iterator helpers skipped), and the `ShinePlayer` / `ShineMob` vtable slots used.
`coverage.py Z21` does not apply (no scope table).

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `ItemActionObserveManager::_EventRun` @ FUN_005d1df0, `AddAction` / `DelAction` internals, `doWithActionIDs`, `ActionEffectAbStateTable::FindActionID` @ FUN_005c7f40, `SendCoolTimes2Client` @ FUN_005d0d30, `ItemActionObserveManager::Clear` @ FUN_005d16e0 (reached from `sp_ItemActionSetup`, §4.3, and `EventRunBySkillGroupIndex`, §5.3), the item-action effect classes other than the two in §4.4 | Z17 (open; plan: "Item actions: the tables `ItemAction*.shn`, …, the player's item-action cooldown container (player `vt 0x5d0`), what triggers a check …, each condition and effect type") | generic item-action engine; set actions are ordinary item actions with observer key 0xFFFF (§4.3); Z21 documents only the set-specific entry points and the two effect classes the set data uses |
| `SubAbnormalStateActor*` bodies beyond the set-item factor (HPHeal / HPSPHeal / PartyRecharge rest, every other actor) | Z22 (open; goal: "Reconstruct each actor's attach / routine / detach / apply") | §5.4 gives only the set-item reads of three actors |
| `siae_ParameterRefit` @ FUN_005108c0, `aeo_ParameterEnchant` @ FUN_004079f0 | Z12 §2.5 (done, documents both) | cited in §5.4; Z12's "filled from the caster's set-item effects" is corrected in §5.3 and `docs/knowledge/Z21.md` |
| `smo_SkillBlast` @ FUN_00581160, `sbec_Routine` @ FUN_00437fc0, `aeo_Set` @ FUN_0040a340, `so_AbnormalState_Set` / `Resist` / `Inform` / `Reset`, `csl_SPCheck` @ FUN_0055b920 | Z03 §5.3, §5.6, §6.2–6.4 (done, documented) | the readers of §3.7 and the callers of §5.7; only their set-item parts are described here |
| `so_KilledBy` @ FUN_00433be0 (death shelters), skill revive `sp_NC_SKILL_REPLYREVIVE_CMD` @ FUN_00418a30, `sp_ReviveNow` @ FUN_0057d290 | Z03 §7.2–7.3 (done, documented) | §5.6 adds the shelter helpers and the item revive `uib_Effect` @ FUN_00418b60 / `so_ReviveByItem` @ FUN_00417850, which no doc had |
| `0x3039 NC_ITEM_REVIVEITEMUSE_CMD`, the revive item's use and DB consumption | Z04 §12.3 (done, documented) | §5.6 documents only the `uib_Effect` it ends in |
| `smo_ply_SkillCoolTime` @ FUN_0055b6a0 (SET_COOLTIMERATE reader) | Z11 §8.5 (done, documents the rate step) | §3.7 |
| `so_Routine` @ FUN_0056a080 (`se_Clear` per routine), `almfh_ApplyHeal` @ FUN_0056d2c0, `mdt_PostSkillBlast` @ FUN_004a3a90, the RankingValue script events of §5.8 | Z09 §5.5, §12.5, §28.3, §14.3 (done, documented) | readers / callers listed in §3.7 and §5.8 |
| `so_SaveAbstate` senders `ws_save2DB` / `ws_save2worldmanager`, GameDB `0x4007` → `p_Char_SetStateWithSetItemAndRestTime`, `0x100C` from `p_Char_GetStateAllWithSetItemAndRestTime` | Z01 §8.4, D02 §6, D06 §7.2 (done, documented) | §5.5 / §5.6 give the set-item words of the row |
| WM relay `0x4011` → `0x1023 NC_CHAR_ZONE_ABSTATE_CMD` | W01 §6.3 (done, documented) | §5.5; byte-exactness noted in §6 |
| login restore `so_CharAbstateData` @ FUN_0044e0e0 → `asl_Store` @ FUN_0040afd0 | Z12 §6.4 (done, documents it) | §5.6 adds `siae_SetItemEffectRestore` |
| `ItemInfo.SetItemIndex` column (the join key of §4.2) and the `ItemInfo.shn` loader `ItemDataBox::idb_Load` @ FUN_00649780 | Z01 §2.3 loader table (done, lists it) and §2.3 / §3.2 here (column offset +0x156; `ItemDataBoxIndex.SetItemIndex` set to 0xFFFF) | the set name is read straight from the item row; the loader's only set-item act is the 0xFFFF fill |
| equip / unequip / drop flows that run the releasers of §4.3 (`sp_NC_ITEM_EQUIP_REQ` …, `InventoryCellLockList`) | Z04 / Z05 (done, documented: Z05 §1.2–1.3 for the lock list) | §4.3 documents only the set-action add / delete inside the releasers |
| `0x206F` and `0x243C` client handlers (FUN_00692d10 / FUN_004b5740, 2016 client) beyond what §4.5 / §5.8 say | C01 (done: handler map in `re-data/client-handlers.json`) | the floating-number / HP display internals are client UI; noted in §6 |
| `smo_old_skill_blast` @ FUN_00579b50 / FUN_0057be40 (vt 0xEA4) | here (§5.7) | dead: no code calls vt 0xEA4 |
| Overlap rows of Z09 §31.2 "Items, equipment, set items, random options" (`Send_SETITEMHEALEFFECT` FUN_005cfbb0, `SkillEffect::operator[]` FUN_00510010, `se_Clear` FUN_005105e0, `SetItemAbstateEffect` ctor FUN_00510350, `ed_Compare` FUN_004a2ed0) | here (§4.5, §3.6, §5.1) | Z18 (no status yet) can cite Z21; recorded in `docs/knowledge/Z21.md` |
