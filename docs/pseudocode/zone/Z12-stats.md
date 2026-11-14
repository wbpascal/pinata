# Zone server: stat calculation, level/exp, login data parsing (Z12)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read through the PDB re-analysis `re-data/exports/zone-pdb`
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). All class, member and enum names below
come from the NA2016 `Zone.pdb` (same build) *(pdb2016)* unless marked otherwise. Evidence markers as in `AGENTS.md`:
*(pdb2017)*, *(inferred)*, *(captured)*. Earlier work this builds on: Z03 §4 (combat formulas that read the matrix),
Z07 §1 (login blobs, `CHAR_PARAMETER_DATA`), Z10 §5.4 (`ChrCommon.txt` loader, exp and free-stat tables).

`p` = the `ShineObjectClass::ShinePlayer`; `vt 0x…` = byte offset of a virtual slot in its vftable
(`rtti.py`, 986 slots). `P` = `p.smo_Param` (`Parameter::Container`, `p+0xfc0`, returned by `so_parameter` vt 0x430).

---

## 1. The stat matrix (`Parameter::Container`)

### 1.1 Layout

`Parameter::Cluster` (0xCC bytes) = 51 `int` members. `Parameter::Container` (0xDB0 bytes) = 16 clusters ("layers") and
some special fields. The layer numbers are the ones Z03 §4.1 uses (`layer * 0xcc`).

| Idx | Off | Cluster member | Idx | Off | Cluster member | Idx | Off | Cluster member |
|---|---|---|---|---|---|---|---|---|
| 0 | 0x00 | Str | 17 | 0x44 | AbsoluteHit | 34 | 0x88 | AttSpeed |
| 1 | 0x04 | Con (END) | 18 | 0x48 | AbsoluteBlock | 35 | 0x8c | MaxHP |
| 2 | 0x08 | Dex | 19 | 0x4c | MoveSpeed | 36 | 0x90 | MaxHP_2 |
| 3 | 0x0c | Int | 20 | 0x50 | HPRecover | 37 | 0x94 | MaxSP |
| 4 | 0x10 | Men (SPR) | 21 | 0x54 | SPRecover | 38 | 0x98 | HPAbsorption_Hitted |
| 5 | 0x14 | WCmin | 22 | 0x58 | CastingTime | 39 | 0x9c | SPAbsorption_Hitted |
| 6 | 0x18 | WCmax | 23 | 0x5c | Critical | 40 | 0xa0 | HPAbsorption_Hit |
| 7 | 0x1c | AC | 24 | 0x60 | PhisycalWeaponMastery | 41 | 0xa4 | SPAbsorption_Hit |
| 8 | 0x20 | TH | 25 | 0x64 | MagicalWeaponMastery | 42 | 0xa8 | CriticalTB |
| 9 | 0x24 | TB | 26 | 0x68 | ShieldAC | 43 | 0xac | RegistNone |
| 10 | 0x28 | MAmin | 27 | 0x6c | HitRate | 44 | 0xb0 | ResistPoison |
| 11 | 0x2c | MAmax | 28 | 0x70 | EvaRate | 45 | 0xb4 | ResistDeaseas |
| 12 | 0x30 | MR | 29 | 0x74 | MACri | 46 | 0xb8 | ResistCurse |
| 13 | 0x34 | MH | 30 | 0x78 | CriDam | 47 | 0xbc | ResistMoveSpdDown |
| 14 | 0x38 | MB | 31 | 0x7c | MagCriDam | 48 | 0xc0 | ResistGTI |
| 15 | 0x3c | AbsoluteAttack | 32 | 0x80 | CriDamRate | 49 | 0xc4 | MaxLP |
| 16 | 0x40 | AbsoluteDefend | 33 | 0x84 | MagCriDamRate | 50 | 0xc8 | LPRecover |

| Layer | `P+` | `p+` | Container member | Filled by (§) |
|---|---|---|---|---|
| 0 | 0x000 | 0xfc0 | `PureCharParam` | `c_Storepure` (§2.1) |
| 1 | 0x0cc | 0x108c | `Item.Plus` | `so_RecalcEquipParam` (§2.2) |
| 2 | 0x198 | 0x1158 | `Item.Rate` | `so_RecalcEquipParam`: used as a second flat cluster (critical, resistances) (§2.2) |
| 3 | 0x264 | 0x1224 | `ItemPowerRate.Plus` | reset only; no writer found |
| 4 | 0x330 | 0x12f0 | `ItemPowerRate.Rate` | `so_RecalcEquipParam` (item rates, charged attack/defence power) (§2.2) |
| 5 | 0x3fc | 0x13bc | `Upgrade.Plus` | `so_RecalcEquipParam` (enhancement) (§2.2) |
| 6 | 0x4c8 | 0x1488 | `Upgrade.Rate` | reset only; no writer found |
| 7 | 0x594 | 0x1554 | `WeaponTitle.Plus` | reset only; no writer found |
| 8 | 0x660 | 0x1620 | `WeaponTitle.Rate` | `smo_ply_WeaponTitleSet` per attack target (flat values, §2.3) |
| 9 | 0x72c | 0x16ec | `PassiveSkill.Plus` | `cpl_RecalcParam` (§2.4) |
| 10 | 0x7f8 | 0x17b8 | `PassiveSkill.Rate` | `cpl_RecalcParam` (§2.4) |
| 11 | 0x8c4 | 0x1884 | `AbnormalState.Plus` | `aeo_ParameterEnchant` (§2.5) |
| 12 | 0x990 | 0x1950 | `AbnormalState.Rate` | `aeo_ParameterEnchant`, `siae_ParameterRefit` (§2.5) |
| 13 | 0xa5c | 0x1a1c | `LastTune.Plus` | reset only (`so_RecalcLastParam`) |
| 14 | 0xb28 | 0x1ae8 | `LastTune.Rate` | `so_RecalcLastParam` (§2.6) |
| 15 | 0xbf4 | 0x1bb4 | `Total` | `c_MakeTotal` (§1.3) |

Special fields after the layers (`P+`): `0xcc0 DotDamagePlus {short Burn, Poison, Desease, Blooding, PitBlooding}`,
`0xcca short SPRate`, `0xccc short RangeEvasion`, `0xcce flag {bit0 cannotmove_stun, bit1 cannotmove_entangle,
bit2 cannotattack}`, `0xcd0 u16 MissPercentFix`, `0xcd2 u16 DamageReflection`, `0xcd4 u16 ChangeAbilityInfo`,
`0xcd6 u16 HealRate`, `0xcd8 u16 PassiveBuffKeepTimeUPRate`, `0xcda u16 PassiveHealRate`, `0xcdc u16 PassiveCriDamageRatePlus`,
seven `ChangeByConditionParam` (0x1C each: `PassiveHPDownRateWCMin` 0xce0, `…WCMax` 0xcfc, `…MAMin` 0xd18, `…MAMax` 0xd34,
`…AC` 0xd50, `…MR` 0xd6c, `PassiveMovingTBPlus` 0xd88), `0xda4 u16 PhysicalImmuneRate`, `0xda6 u16 MagicalImmuneRate`,
`0xda8 u32 RangeOver`, `0xdac u16 DMGMinusRate`.

This names the cells Z03 §4.1 left as labels: Z03's `+0xa18` attack-speed rate is `AbnormalState.Rate.AttSpeed`;
`+0xc30` "flat bonus damage" is `Total.AbsoluteAttack`; `+0xcd2` is `DamageReflection` (Z03: "splash rate");
`+0xda8` is `RangeOver` (Z03: "splash range"); the `+0xcce` bits are stun / entangle / cannot-attack (Z03 read bit 1 as
"no shadow-step"). Stat 26 is `ShieldAC`, 32/33 `CriDamRate` / `MagCriDamRate` (critical *rate*), 42 `CriticalTB`
(critical resistance), 24 `PhisycalWeaponMastery`.

### 1.2 Erasers and clearing

Two global template clusters, filled at start-up by the static initialiser `` `dynamic_initializer_for_'shineparam'` ``
@ FUN_00696e60:

| Global | Address | Value |
|---|---|---|
| `parameter_eraser_plus` | DAT_0da3fb48 | all 51 members 0 |
| `parameter_eraser_rate` | DAT_0da3fa78 | 1000 for 44 members; 0 for `CriticalTB` and `RegistNone … ResistGTI` (members 42–48) |

Every recalculation first copies the eraser into its layers (plus → `.Plus`, rate → `.Rate`), so a rate cell is
per mille with 1000 = neutral, and the seven resist/critical-TB cells of a rate cluster start at 0 and act as flat sums.

```pseudo
Parameter::Container::c_clear(P):                                  @ FUN_0043c370   (object creation; mobs, players)
    PureCharParam, every .Plus = eraser_plus; every .Rate = eraser_rate
    flag = 0; SPRate = 1000; DotDamagePlus = 0; RangeEvasion = 0; DamageReflection = 0; ChangeAbilityInfo = 0xFFFF
    MissPercentFix = 0; WeaponTitle.Rate.CriDamRate = WeaponTitle.Rate.MagCriDamRate = 0; HealRate = 1000
    PassiveBuffKeepTimeUPRate = PassiveHealRate = PassiveCriDamageRatePlus = 0
    cbcp_Clear(each of the seven ChangeByConditionParam)          @ FUN_004c8ed0
    RangeOver = 0; PhysicalImmuneRate = MagicalImmuneRate = 0; DMGMinusRate = 0
```

### 1.3 `Parameter::Container::c_MakeTotal` @ FUN_004c9a40 (the Total formula)

```pseudo
c_MakeTotal(P):
    Total = eraser_plus                                   # all 51 members 0
    Total += PureCharParam                                # Cluster::operator+=  @ FUN_004c9040
    Total += Item.Plus
    Total *= ItemPowerRate.Rate                           # Cluster::operator*=  @ FUN_004c9160
    Total *= AbnormalState.Rate
    Total *= PassiveSkill.Rate
    Total += Upgrade.Plus
    Total += PassiveSkill.Plus
    Total += AbnormalState.Plus
    Total += LastTune.Plus
    Total *= LastTune.Rate
    Total.Str/Con/Dex/Int/Men = max(that value, 1)

Cluster::operator+=(a, b):  members 0…31 (Str … MagCriDam): a.m += b.m          # members 32…50 untouched
Cluster::operator*=(a, b):  members 0…31: if b.m != 1000: a.m = a.m * b.m / 1000   # signed int, truncating, per step
                            CriDam is multiplied twice: the CriDam line is repeated (original bug) Z12-B1
```

So `Total[m] = ((((L0 + L1)·L4/1000)·L12/1000)·L10/1000 + L5 + L9 + L11 + L13)·L14/1000` for members 0–31, with
an integer division after every factor. This corrects Z03 §4.1 (`(L0+L1)·L12·L10·L4·L14/10¹² + L5+L7+L9+L11+L13`):
`LastTune.Rate` (L14) scales the flat bonuses too, and `WeaponTitle.Plus` (L7) is not part of the total.
Layers 2, 3, 6, 7, 8 never enter `Total`; their readers use them directly (Z03 §4.6 `roe_MinWC` reads L8 and L4;
`roe_CriticalRate` reads L2). `Total` members 32–50 (`CriDamRate` … `LPRecover`) stay 0: `MaxHP`, `MaxSP`, `MaxLP`,
`AttSpeed`, resistances and the critical rates are read from the individual layers (part 2 for the maxima).

### 1.4 `so_allparametercalculate` (vt 0x57c) @ FUN_0054f190 and when the matrix is rebuilt

```pseudo
so_allparametercalculate(p):
    cls = p.sp_CharData.toclient.shape.chrclass (u8)
    p.+0xfbc = (cls < 0x40) ? charclassmanager.ccm_array[cls] : &charclassmanager (= ccm_classdefault)    # CharClass*
    c_Storepure(P, p.+0xfbc, p)              # the class object (§2.1)
    p.vt[0x35c]()   so_RecalcEquipParam      @ FUN_004cab70   (§2.2)
    p.vt[0x360]()   so_RecalcAbstateParam    @ FUN_004cbe50   (ShineMobileObject; §2.5)
    p.vt[0x364]()   so_RecalcPassiveParam    @ FUN_004cb4a0   (§2.4)
    p.vt[0x368]()   so_RecalcLastParam       @ FUN_004cb570   (§2.6)
    c_MakeTotal(P)
    # sends nothing; callers send the refresh (part 2: vt 0x34 smo_mobile_NotifyParameterChange)
```

Callers (all read): `wms_NC_CHAR_ZONE_CHARDATA_ACK` @ FUN_005a3590 (login, Z07 §1.4), `wms_NC_CHAR_ZONE_CHARGEDBUFF_CMD`
@ FUN_0044bcf0, `sp_NC_MAP_LOGINCOMPLETE_CMD` @ FUN_00443390, `sp_GainExp` @ FUN_0042d830 (level-up, Z03 §8.3),
`so_ply_ClassChange` @ FUN_004521b0, `InvenCellReleaser_EquipLocation::icr_Apply` @ FUN_0048ca20 (equip lock released),
`~ChargedEffectListRouter` @ FUN_00450e80 (charged buff list rebuilt).

Partial rebuilds (the weapon-title layer is per attack, §2.3):

| Trigger | What runs |
|---|---|
| `so_RecalcAbstateParamReady` (vt 0x528) @ FUN_005556b0 | only sets `smo_Abstate.parameterchange = 1` |
| `ShineMobileObject::so_Routine` @ FUN_0056a080, after `asl_Routine`, when `parameterchange` is set | vt 0x360 abstate layer, vt 0x368 last-tune layer, vt 0xda4 `so_ply_Sen_RecalcLPRecover`, vt 0x34(1) notify, vt 0x7bc `so_mobile_SpeedChange`; `parameterchange = 0`; if `Parameter::Container::IsNoAttacOrNoMove(P)`: vt 0x8d0 `so_ply_AllCastCancel` |
| equipment changes: `gds_NC_ITEMDB_EQUIPSUC_ACK` @ FUN_0052cba0, `…UNEQUIPSUC_ACK` @ FUN_0053b0a0, `…DROPALLSUC_ACK` @ FUN_0052ab80, `…REINFORCEUNEQUIPSUC_ACK` @ FUN_004a5100, `so_ply_ChargedBuff` @ FUN_005970c0, `ciee_Free` @ FUN_00450a50 | vt 0x35c `so_RecalcEquipParam` (which itself sets `parameterchange`, so the abstate/last layers, `Total` and the notify follow on the next tick) |
| the per-minute charged-buff rebuild (Z09 §2, `PerMinutePlayerChecks`) | vt 0x35c and vt 0x368 when a buff expired, then vt 0x34(1) |

Note that the per-tick path (`parameterchange`) does not call `c_MakeTotal` itself; `Total` is refreshed by the notify
(vt 0x34, part 2) *(inferred until part 2 reads `so_mobile_NotifyParameterChange` @ FUN_00503c10)*.

---

## 2. The layer sources

### 2.1 `PureCharParam` (layer 0): class tables and `c_Storepure` @ FUN_00517b60

Class objects: `CharClassManager charclassmanager` (0x1E4658 bytes) holds one `CharClass` (0x10B38 bytes:
`OptionReader` base, `PrimaryParameter* cc_array[151]` +0x10858, `PrimaryParameter cc_def` +0x10AB4) per class and
`CharClass* ccm_array[64]` +0x1E4558. The constructor `CharClassManager::CharClassManager` @ FUN_00449aa0 points every
`cc_array[i]` at that class's `cc_def` and every `ccm_array[i]` at `ccm_classdefault`, then sets
`ccm_array[1…27]` = Fighter, CleverFighter, Warrior, Gladiator, Knight, Cleric, HighCleric, Paladin, HolyKnight, Guardian,
Archer, HawkArcher, Scout, SharpShooter, Ranger, Mage, WizMage, Enchanter, Warrock, Wizard, Joker, Chaser, Cruel, Closer,
Assassin, Sentinel, Savior and `ccm_array[28]` = `ccm_classmob`.

```pseudo
CharClassManager::ccm_Load(worldName):                        @ FUN_0044a5c0   (zone start, stage "house": Z10 §5.4, Z01 loader table)
    for each player class (the 27 above, in that order):
        CharClass::cc_Load(class, worldName, "Param<Class>Server")
    # ccm_classdefault and ccm_classmob are never loaded: their cc_array keeps pointing at cc_def

CharClass::cc_Load(cls, worldName, fileName):                 @ FUN_0044a3d0
    or_Read("../9Data/Shine/World/<worldName>/<fileName>.txt") else or_Read("../9Data/Shine/World/<fileName>.txt")
        else assert "CharClass::cc_Load : Error in read" (error line) + ShineExit(fileName)
    for level 1 … 150:
        cls.cc_array[level] = or_SelectFrom(table "Param", column "Level" == level)     # row pointer, used as PrimaryParameter
            missing → assert "CharClass::cc_Load : Error in level" (level) + ShineExit(fileName)
    # cc_array[0] stays &cc_def
```

`ParamXxxServer.txt` (27 files in `9Data/Shine/World/`, 150 `#record` rows each, table `Param`) columns = struct
`PrimaryParameter` (0x82 bytes): `Level, Strength, Constitution, Intelligence, Wizdom, Dexterity, MentalPower`
(u32), `SoulHP, MAXSoulHP, PriceHPStone` = `hpsoulstone {soul, maxsoul, buysoul}` +0x1c, `SoulSP, MAXSoulSP, PriceSPStone` =
`spsoulstone` +0x28, `AtkPerAP` (aap), `DmgPerAP` (dap), `MaxPwrStone, NumPwrStone, PricePwrStone, PwrStoneWC, PwrStoneMA,
MaxGrdStone, NumGrdStone, PriceGrdStone, GrdStoneAC, GrdStoneMR` (maxaep … depmr), `PainRes, RestraintRes, CurseRes,
ShockRes` (u32), `MaxHP` (u16 `LevelHP` +0x74), `MaxSP` (u16 `LevelSP` +0x76), `CharTitlePt` (u32), `SkillPwrPt` (u32),
`JobChangeDmgUp` (u16, 1000 in the Fighter file). Fighter level 1: STR 6, END 5, INT 1, DEX 3, SPR 1, MaxHP 52, MaxSP 10.

```pseudo
c_Storepure(P, cls, p):
    lv = p.vt[0x4d8]() so_GetLevel (u8)
    row = (lv < 0x97) ? cls.cc_array[lv] : cls.cc_array[0]        # level 0 or > 150 → cc_def
    PureCharParam = eraser_plus
    more = p.vt[0x8e0]() so_ply_ChargedStatPlus @ FUN_0055a490     # = sp_ChargedItem.ci_Effect.cec_MoreStat (u8, charged "stat up" item)
    Str = more + row.strength;  Con = more + row.constitution;  Dex = more + row.dexterity
    Int = more + row.intelligence;  Men = more + row.mentalpower                     # row.wizdom is not used
    WCmin = WCmax = cls.vt[0] CharClass::WC(p, P);  AC = cls.vt[1] AC;  MAmin = MAmax = cls.vt[2] MA;  MR = cls.vt[3] MR
    TH = cls.vt[4] TH;  TB = cls.vt[5] TB;  MH = cls.vt[6] MH;  MB = cls.vt[7] MB
        # all eight slots of every CharClass vftable are the shared stub @ FUN_00449600 `return 0` (one body, COMDAT-folded
        # with ShineObject::so_MH_GetFurnitureInven): the base WC/AC/MA/MR/TH/TB/MH/MB are 0 for every class
    MoveSpeed = HPRecover = SPRecover = 1000
    CastingTime = Critical = PhisycalWeaponMastery = MagicalWeaponMastery = ShieldAC = HitRate = EvaRate = MACri = CriDam = MagCriDam = 0
```

The spent free-stat points (`p+0x7f94…`, Z07 §2) are **not** added here: they act through the free-stat tables of
`ChrCommon.txt` (Z10 §5.4) inside the combat formulas (Z03 §4.6 "FreeStatBonus") *(inferred; part 2 checks the readers)*.
Weapon/defence values come from STR/END/DEX/INT/SPR in the `roe_*` formulas (Z03 §4.6), not from layer 0.

The other `CharClass` virtual slots (vt index: 8 `MaxHP` @ FUN_00449610, 9 `MaxSP` @ FUN_00449660, 10 `MaxLP`,
11 `LPRecover`, 12 `LPTick`, 13 `LPRecoveryRoutine`, … `cc_AttackRhythm`, `cc_CanNormalAttack`; Sentinel/Savior override
9–13 with @ FUN_0064f610 / FUN_0044a830 / FUN_0044a870 / FUN_0044a8b0 / FUN_00449a50) belong to part 2 (maxima, LP).

### 2.2 Equipment: `so_RecalcEquipParam` (vt 0x35c) @ FUN_004cab70

Fills `Item.Plus`, `Item.Rate`, `ItemPowerRate.Rate` and `Upgrade.Plus`; `ItemPowerRate.Plus` and `Upgrade.Rate`
are only reset.

```pseudo
so_RecalcEquipParam(p):
    Item.Plus = eraser_plus; Item.Rate = eraser_rate; ItemPowerRate.Plus = eraser_plus; ItemPowerRate.Rate = eraser_rate
    atk = p.sp_ChargedItem.ci_Effect.cec_ItemPowerAttack; def = …cec_ItemPowerDefence     # charged-item power (u16 per mille)
    ItemPowerRate.Rate.WCmin = WCmax = MAmin = MAmax = atk;  ItemPowerRate.Rate.AC = MR = def
    Upgrade.Plus = eraser_plus; Upgrade.Rate = eraser_rate
    Item.Rate.CriDamRate = 0
    skipLeft = RIGHTHAND (slot 12) item exists, has ItemInfoServer, and its ItemEquipTable row (iet_GetArray(ISET_Index)) has
               Equ_LeftHand == 2                                   # the right-hand item also occupies the left hand (inferred: two-hander)
    p.sp_MovingShot = 0; p.sp_PreventAttack = 0
    for each equipment slot s (ItemBoxIterItem over p.sp_Item.itembag.ci_Equipment):
        if s == LEFTHAND (10) and skipLeft: continue
        cell = equipment[s]; skip if empty or ItemDataBox[itemid] missing (row d = ItemInfo, ds = ItemInfoServer)
        # costume weapon / shield accessories (Z17 owns the charge logic):
        if s == LEFTHANDACC (11): require LEFTHAND item (id != 0xFFFF); if s == RIGHTHANDACC (13): require RIGHTHAND item;
            att = ItemAttributeClassContainer[itemid]; if !att: skip
            if att.vt[0x9c](cell) == 0 (no charge left):                       # (inferred meaning)
                p.sp_CostumWeaponChargeing = &ShineObject::so_CostumWeaponChargeing (the "none" sentinel)
                unless ChargedItemEffect(itemid).EffectEnum == EE_WEAPON_MAXENDURE: skip
            p.sp_CostumWeaponChargeing = cell
        if s == SHIELDACC (29): require LEFTHAND item, else sp_CostumShieldChargeing = sentinel and skip; same test → sp_CostumShieldChargeing
        p.sp_MovingShot |= ItemDataBoxIndex.MovingShot;  p.sp_PreventAttack |= ds.PreventAttack
        Item.Plus += { WCmin += d.MinWC, WCmax += d.MaxWC, AC += d.AC, MAmin += d.MinMA, MAmax += d.MaxMA, MR += d.MR,
                       TH += d.TH, TB += d.TB, ShieldAC += d.ShieldAC, HitRate += d.HitRatePlus, EvaRate += d.EvaRatePlus,
                       MACri += d.MACriPlus, CriDam += d.CriDamPlus, MagCriDam += d.MagCriDamPlus }
        Item.Rate.CriDamRate += d.CriRate;  Item.Rate.CriticalTB += d.CrlTB                    # flat sums in the rate cluster
        ItemPowerRate.Rate.WCmin/WCmax += d.WCRate − 1000;  .AC += d.ACRate − 1000
        ItemPowerRate.Rate.MAmin/MAmax += d.MARate − 1000;  .MR += d.MRRate − 1000
        o[15] = FillRandomOption(cell, row)                                                       (below)
        Item.Plus: Str += o[ROT_STR], Con += o[ROT_CON], Dex += o[ROT_DEX], Int += o[ROT_INT], Men += o[ROT_MEN],
                   TH += o[ROT_TH], CriDamRate += o[ROT_CRI], WCmin/WCmax += o[ROT_WC], AC += o[ROT_AC],
                   MAmin/MAmax += o[ROT_MA], MR += o[ROT_MR], TB += o[ROT_TB], MaxHP_2 += o[ROT_MAXHP]
        Item.Rate.CriticalTB += o[ROT_CRITICAL_TB]                                                # o[ROT_DEMANDLVDOWN] (13) unused here
        if row.itemoption (GradeItemOption, per-item grade options):
            Item.Rate.ResistPoison/ResistDeaseas/ResistCurse/ResistMoveSpdDown += the four Resist* columns
            ItemPowerRate.Rate.TH += ToHitRate − 1000;  ItemPowerRate.Rate.TB += ToBlockRate − 1000
            Item.Plus.MaxHP += MaxHP;  Item.Plus.MaxSP += MaxSP
        if KQItemDataBox[itemid] (KQItem.shn):
            ItemPowerRate.Rate.MoveSpeed += MoveSpdRate (a delta: KQ_InvincibleHammer 350 → ×1.35);  Item.Plus.AbsoluteAttack += AbsoluteAttack
        # enhancement
        if cell.attr.vt[0x28]() == 0x26 (ITEMCLASS_BRACELET):
            lv = cell.attr.vt[0x30](cell); if lv > 21: assert; continue
            u = BRAccUpgradeDataBox[d.BasicUpInx] (BRAccUpgradeInfo: UpFactor, u16 BRAccUpdata[21]); v = u.BRAccUpdata[lv]
        else:
            lv = cell.attr.vt[0x30](cell); if lv == 0: continue; if lv >= 13: assert; continue
            u = UpgradeDataBox[d.BasicUpInx] (UpGradeInfo: UpFactor, u16 Updata[12]); v = u.Updata[lv − 1]
        if u: switch u.UpFactor:
            UPG_AC: Upgrade.Plus.AC += v          UPG_WC: Upgrade.Plus.WCmin/WCmax += v      UPG_SHIELDAC: Upgrade.Plus.ShieldAC += v
            UPG_MA: Upgrade.Plus.MAmin/MAmax += v  UPG_MR: Upgrade.Plus.MR += v                UPG_WC_MA: WC and MA += v
            UPG_AC_MR: AC and MR += v              8 (UPG_CRIT, bracelet table only): Upgrade.Plus.CriDamRate and MagCriDamRate += v
            UPG_STAT (5): nothing
    p.sp_WeaponCell = p.vt[0x7ac]() so_ply_EquipWeapon @ FUN_0059d770
    p.vt[0x528]()                                         # parameterchange = 1 → abstate/last layers + notify next tick (§1.4)
    p.sp_RecoverPoint = sp_RecoverPoint_HPAfterItemEquip   # recovery mode after an equip change (part 2)
    sp_SetItemCheck(p)                                     @ FUN_00510b50   (set-item pieces → p.sp_SetItemEffect, §2.5)
    if sp_CostumWeaponChargeing / sp_CostumShieldChargeing points at a cell whose itemid is 0xFFFF: reset it to the sentinel
```

The `UpgradeFactor` enum has two definitions in the PDB (one without `UPG_CRIT`); this function was compiled with the
older one, so value 8 shows as `MAX_UPGRADEFACTOR` in the decompilation. The normal upgrade switch has no case 8, so a
crit factor only works through the bracelet table.

```pseudo
FillRandomOption(cell, row) → int o[15] (indexed by RandomOptionType):   @ FUN_004ca9e0
    o = 0
    if row.itemoption (GradeItemOption): o[STR, CON, DEX, INT, MEN] = its STR, CON, DEX, INT, MEN; o[ROT_WC] = WCPlus; o[ROT_MA] = MAPlus
    opt = cell.attr.vt[0x70](&cell.item)     # ItemOptionStorage { u8 fixed: bit0 identify, bits1-7 optionnum; Element[8] {u8 type, u16 value} }
    if opt and opt.identify and optionnum > 0:
        for each of the optionnum elements: if type < 15: o[type] += value else assert "FillRandomOption : Type err"
    if row.data.Class == ITEMCLASS_AMULET:                 # accessory enhancement bonus per option type
        for t in 0 … 14: o[t] += cell.attr.vt[0x7c](&cell.item, t) & 0xFFFF
```

`RandomOptionType` *(pdb2016)*: 0 STR, 1 CON, 2 DEX, 3 INT, 4 MEN, 5 TH, 6 CRI, 7 WC, 8 AC, 9 MA, 10 MR, 11 TB,
12 CRITICAL_TB, 13 DEMANDLVDOWN, 14 MAXHP.

### 2.3 Weapon title: `smo_ply_WeaponTitleSet` (vt 0xec8) @ FUN_00569cd0

The weapon-title layer depends on the current target and is rebuilt before each hit: `smo_SwingDamage` @ FUN_00432f30
(basic attack) and the skill blast in `so_Routine` @ FUN_0056a080 call `vt 0xec8(target.vt[0x708]())`; on a mob
`vt 0x708` is `so_mob_MobID` @ FUN_00556ab0 (other objects return 0xFFFF).

```pseudo
ShineMobileObject::smo_ply_WeaponTitleSet(o, mobId):       @ FUN_00567110   (mobs, NPCs: reset only)
    WeaponTitle.Plus = eraser_plus; WeaponTitle.Rate = eraser_rate; WeaponTitle.Rate.CriDamRate = MagCriDamRate = 0

ShinePlayer::smo_ply_WeaponTitleSet(p, mobId):
    base reset (above)
    w = p.vt[0x7ac]() so_ply_EquipWeapon; if !w: return
    t = CWeaponTitleZone::GetLevelData(&gWeaponTitle, mobId, w)    @ FUN_0059d6a0
        # the weapon has three title slots in its attributes: {u16 mob group at +5, u16 mob at +7, u32 kills & 0x0FFFFFFF at +9} (6 bytes each)
        # first slot whose mob species matches (MobDataBox::mdb_SpeciesDistance(slot.group, mobId) >= 0) →
        # CWeaponTitle::GetLevelData(slot.mob, slot.kills) = the WEAPON_TITLE_DATA row of the reached level (WeaponTitleData.shn)
    if t:
        WeaponTitle.Rate.WCmin = WeaponTitle.Rate.MAmin = t.MinAdd;  WeaponTitle.Rate.WCmax = WeaponTitle.Rate.MAmax = t.MaxAdd
        for (ref, type, value) in SP1, SP2, SP3: sp_WeaponTitleOption(p, ref, type, value)      @ FUN_005671a0
            ref 0: nothing; ref 1 and type 1: WeaponTitle.Rate.CriDamRate += value; anything else: assert
```

These are flat additions although they sit in the rate cluster (Z03 §4.6 adds `wpt` = L8 WC to the attack sum and reads
L8 stat 32 in the critical rate). `CWeaponTitleZone::GetLevelData(mob, weapon, &out)` @ FUN_0059d720 is the exact-mob
variant (slot.mob == mobId) used by the title commands (Z08).

### 2.4 Passive skills: `so_RecalcPassiveParam` (vt 0x364) @ FUN_004cb4a0 → `CharacterPassiveList::cpl_RecalcParam` @ FUN_00445940

```pseudo
so_RecalcPassiveParam(p):
    PassiveSkill.Plus = eraser_plus; PassiveSkill.Rate = eraser_rate
    cpl_RecalcParam(&p.sp_Passive, P, &p.sp_Item)

cpl_RecalcParam(list, P, bag):
    wid = itemid of equipment[RIGHTHAND 12]; if 0xFFFF: itemid of equipment[LEFTHAND 10]
    for id in 0 … 999 where bit id of list.cpl_Passive (BitSet) is set:
        s = passivedatabox.pdb_index[id] (PassiveSkill.shn row, PassiveSkillInfo) or pdb_default when id >= pdb_maxpassiveID
        if s.WeaponMastery != 0 and ItemDataBox[wid].data exists:
            w = that ItemInfo (assert "ItemDataBox::operator [] :Invalid Item index" if its ID != wid)
            (rateCol, plusCol) = pmv.pmv_var[w.TwoHand & 1][0 | 1][w.WeaponType]       # column of PassiveSkillInfo:
                # MstRt<Weapon> (rate) / MstPl<Weapon> (plus) for Sword1, Hammer1, Sword2, Axe2, Mace1, Bow2, CrossBow2,
                # Wand2, Staff2, Claw, DSword; weapon type out of range → the [1][…][0] entries
            if w.WeaponType in {WT_STAFF, WT_WAND}:
                if s[plusCol]: PassiveSkill.Plus.MagicalWeaponMastery = s[plusCol]
                if s[rateCol]: PassiveSkill.Rate.MagicalWeaponMastery = s[rateCol] + 1000
            else: same into PhisycalWeaponMastery
        if s.SPRecover:  PassiveSkill.Plus.SPRecover = s.SPRecover
        if s.TB:         PassiveSkill.Plus.TB = s.TB
        if s.Intel:      PassiveSkill.Plus.Int = s.Intel
        if s.CastingTime != 1000: PassiveSkill.Rate.CastingTime = s.CastingTime
        if s.MACriRate:  PassiveSkill.Rate.MagCriDamRate = s.MACriRate
        if s.MaxSP:      PassiveSkill.Plus.MaxSP = s.MaxSP
        if s.MaxLP:      PassiveSkill.Plus.MaxLP = s.MaxLP
        if s.WCRateUp:   PassiveSkill.Rate.WCmin = WCmax = s.WCRateUp + 1000
        if s.MARateUp:   PassiveSkill.Rate.MAmin = MAmax = s.MARateUp + 1000
        if s.HpDownDamegeUp and s.DownDamegeHp:
            cbcp_SetCondition(P.PassiveHPDownRateWCMin / WCMax / MAMin / MAMax, s.ID, s.DownDamegeHp, s.HpDownDamegeUp)
        if s.HpDownAcUp and s.DownAcHp: cbcp_SetCondition(P.PassiveHPDownRateAC / MR, s.ID, s.DownAcHp, s.HpDownAcUp)
        if s.MoveTBUpPlus: cbcp_SetCondition(P.PassiveMovingTBPlus, s.ID, 1000, s.MoveTBUpPlus)
        if s.HealUPRate:         P.PassiveHealRate = s.HealUPRate
        if s.KeepTimeBuffUPRate: P.PassiveBuffKeepTimeUPRate = s.KeepTimeBuffUPRate
        if s.CriDmgUpRate:       P.PassiveCriDamageRatePlus = s.CriDmgUpRate
        if s.DMG_MinusRate:      P.DMGMinusRate = s.DMG_MinusRate
```

Every field is **assigned**, not added: when two learned passives set the same field, the one with the higher id wins
(each passive level is its own id; *(inferred)* only one level of a passive is learned at a time). The special
fields (`PassiveHealRate`, the `ChangeByConditionParam`s, `DMGMinusRate`) are not reset here, only by `c_clear`
(object construction `ShineMobileObject::ShineMobileObject` @ FUN_005591c0 and every map login,
`so_FirstActionAfterSocketConnect` @ FUN_00554870), so a passive that is unlearned keeps its special-field effect until
the next map login (original bug) Z12-B2.

```pseudo
Parameter::ChangeByConditionParam (0x1C: u16 cbcp_nID, u32 cbcp_nCondition, u32 cbcp_nChange, int cbcp_nChangeParam,
                                   int cbcp_nCharged, u8 cbcp_nMaxValueNum, int* cbcp_pValue)
cbcp_SetCondition(c, id, condition, change):                @ FUN_004c8f10
    c.nID = 0xFFFF; c.nCondition = c.nChange = c.nChangeParam = c.nCharged = 0
    if condition and change:
        c.nID = id; c.nChange = change; c.nCondition = condition
        n = ceil(1000 / condition) (count of steps of `condition` per mille in 1000)
        if n != c.nMaxValueNum: c.nMaxValueNum = n; re-allocate c.pValue[n] (operator new[]), zero it
            (allocation failure → assert "")
cbcp_GetValue(c, lostPerMille):                             @ FUN_004c8fe0
    i = lostPerMille / c.nCondition; return (c.nMaxValueNum and i < c.nMaxValueNum) ? c.pValue[i] : 0
```

The step values `pValue[]` are computed, and sent to the client as `0x10DF NC_CHAR_CHANGEBYCONDITION_PARAM_CMD`, by
`cbcp_MakeParam` @ FUN_004cbb30 / `cbcp_MakeParam_Plus` @ FUN_004cbcd0, both called only from
`so_mobile_NotifyParameterChange` (part 2). Z03 §4.6 uses `cbcp_GetValue` as the "HP-loss curves" (`+0xce0` …).

### 2.5 Abnormal states: `so_RecalcAbstateParam` (vt 0x360) @ FUN_004cbe50 → `aeo_ParameterEnchant` @ FUN_004079f0

```pseudo
ShineMobileObject::so_RecalcAbstateParam(o):               (players and mobs)
    AbnormalState.Plus = eraser_plus; AbnormalState.Rate = eraser_rate
    flag = 0 (stun, entangle, cannotattack)
    AbnormalState.Rate.CriticalTB = 0; AbnormalState.Rate.CriDamRate = 0; Item.Rate.MagCriDamRate = 0   # (sic: the Item layer)
    RangeOver = 0; SPRate = 1000; RangeEvasion = 0; DotDamagePlus = 0; MissPercentFix = 0; DamageReflection = 0
    ChangeAbilityInfo = 0xFFFF; HealRate = 1000; PhysicalImmuneRate = MagicalImmuneRate = 0
    for each active element e of o.smo_Abstate.abstatelist (AbstateElementInObject) with aeo_GetAbstateElement(e) @ FUN_004067b0:
        aeo_ParameterEnchant(e, P)

aeo_ParameterEnchant(e, P):
    row = abstateidentarray(DAT_00875228)[e.aeo_Index] (12 bytes) +4 → per-strength table; t = entry[e.aeo_Strength]
        # entry (0x24 bytes) = { SubAbStateInfo* info; {SubAbstateAction action; int arg} × 4 }   = SubAbState.shn
        #                      ActionIndexA/ArgA … ActionIndexD/ArgD of the sub-state for that strength
    for each of the 4 (action, arg): apply the table below
    siae_ParameterRefit(&e.aeo_SetItemEffect, P)            # set-item modifiers of this element (below)
```

`SubAbstateAction` → matrix cell (`+=` unless noted; "P." = `AbnormalState.Plus`, "R." = `AbnormalState.Rate`):

| SAA | Name | Effect | SAA | Name | Effect |
|---|---|---|---|---|---|
| 1 | STRRATE | R.Str | 47 | HEALRATE | `HealRate = arg` |
| 2 | STRPLUS | P.Str | 49 (0x31) | AWAY | flag.cannotmove_stun |
| 3 | WCPLUS | P.WCmin, P.WCmax | 56 | GTIRESISTRATE | R.ResistGTI |
| 4 | WCRATE | R.WCmin, R.WCmax | 58 | METAABILITY | `ChangeAbilityInfo = arg` |
| 5 | ACPLUS | P.AC | 60 | MISSRATE | `MissPercentFix += arg` |
| 6 | ACRATE | R.AC | 61 | REFLECTDAMAGE | `DamageReflection += arg` |
| 7 | DEXPLUS | P.Dex | 68 | ADDALLDOTDMG | DotDamagePlus: all five |
| 8 | TBPLUS | P.TB | 69 | ADDBLOODINGDMG | DotDamagePlus.Blooding |
| 9 | TBRATE | R.TB | 70 | ADDPOISONDMG | DotDamagePlus.Poison |
| 10 | THPLUS | P.TH | 71 | EVASIONAMOUNT | `RangeEvasion += arg`, only when `info.Type == SUBAB_RANGEEVASION` (85) |
| 11 | THRATE | R.TH | 72 | USESPRATE | `SPRate += arg` |
| 12 | INTPLUS | P.Int | 73 | ACMINUS | P.AC −= arg |
| 13 | MAPLUS | P.MAmin, P.MAmax | 74 | ACDOWNRATE | R.AC −= arg |
| 14 | MENTALPLUS | P.Men | 75 | SUBTRACTALLDOTDMG | DotDamagePlus: all five −= |
| 15 | MRPLUS | P.MR | 76 / 77 | SUBTRACTBLOODING / POISONDMG | Blooding / Poison −= |
| 16 | MRRATE | R.MR | 78 | ATKSPEEDDOWNRATE | R.AttSpeed −= |
| 18 | SHIELDACRATE | R.ShieldAC | 80 | CRITICALDOWNRATE | R.CriDamRate −= |
| 19 | NOMOVE | flag.cannotmove_entangle; but flag.cannotmove_stun when `info.Type` is SUBAB_STUN (21) or SUBAB_AIRBORNE (96) | 81 | DEXMINUS | P.Dex −= |
| 20 | SPEEDRATE | R.MoveSpeed | 83 / 84 | MAMINUS / MADOWNRATE | P.MA / R.MA (min, max) −= |
| 21 | ATTACKSPEEDRATE | R.AttSpeed | 85 | MAXHPDOWNRATE | R.MaxHP −= |
| 22 | MAXHPRATE | R.MaxHP | 86 / 87 | MRMINUS / MRDOWNRATE | P.MR / R.MR −= |
| 23 | MAXSPRATE | R.MaxSP | 88 | SPEEDDOWNRATE | R.MoveSpeed −= |
| 25 | NOATTACK | flag.cannotattack | 89 | STRMINUS | P.Str −= |
| 31 / 32 / 33 | POISON / DISEASE / CURSERESISTRATE | R.ResistPoison / ResistDeaseas / ResistCurse | 90 / 91 | TBMINUS / TBDOWNRATE | P.TB / R.TB −= |
| 34 | CRITICALRATE | R.CriDamRate | 92 / 93 | THMINUS / THDOWNRATE | P.TH / R.TH −= |
| 35 / 36 | MAXHPPLUS / MAXSPPLUS | P.MaxHP / P.MaxSP | 94 / 95 | WCMINUS / WCDOWNRATE | P.WC / R.WC (min, max) −= |
| 37 | INTRATE | R.Int | 99 | MENDOWNRATE | R.Men −= |
| 39 | ALLSTATEPLUS | R.Str, Con, Dex, Int, Men (the **rate** cluster) | 102 | MRSHIELDRATE | `MagicalImmuneRate = arg` |
| 46 | MARATE | R.MAmin, R.MAmax | 103 | ACSHIELDRATE | `PhysicalImmuneRate = arg` |
| | | | 113 | LPAMOUNT | P.LPRecover |
| | | | 116 | SPEEDRESISTRATE | R.ResistMoveSpdDown |
| | | | 119 | ALLSTATPLUS | P.Str, Con, Dex, Int, Men |
| | | | 120 | RANGEOVER | `RangeOver += arg` |

All other actions (shield amount, tick, DoT, heal, fear, silence, exp/drop rate, …) do nothing here; their actor classes
act on them (Z03 §6.1). The `R.` cells are per-mille deltas on top of 1000 (data: `SubStaGoKingStrRate` STRRATE 1500 →
×2.5; `SubStaWeddingSub01` ALLSTATEPLUS 50 → +5 %).

```pseudo
SetItemData::SetItemAbstateEffect::siae_ParameterRefit(se, P):     @ FUN_005108c0
    # se = e.aeo_SetItemEffect: EffectBuffer[4] {u16 eb_Index, u16 Argument_Base1000}; filled when the state is set by
    #      aeo_SetItemEffectStore @ FUN_00510670 (index 0 / arg 1000 = none) from the caster's set-item effects
    pass 1, for each buffer with eb_Index (values > 16 treated as 17 = none) = SetIndex:
        SET_DAMEGERATE (2): R.WCmin/WCmax += arg − 1000      SET_ACRATE (3): R.AC += arg − 1000
        SET_DEXRATE (8): R.Dex += arg − 1000                 SET_MOVESPEEDRATE (10): R.MoveSpeed += arg − 1000
        SET_THRATE (11): R.TH += arg − 1000                  SET_HPSPMAXRATE (14): P.MaxHP = P.MaxHP·arg/1000; P.MaxSP = P.MaxSP·arg/1000
    pass 2, the same 4 buffers, eb_Index >= 1000:
        1000, 1013: R.WCmin/WCmax += arg − 1000     1004: R.AC += arg − 1000     1006: R.Dex += arg − 1000
        1008: P.MaxHP = P.MaxHP·arg/1000; P.MaxSP = arg·(the new P.MaxHP)/1000          (original bug) Z12-B3
        1010, 1014: R.ShieldAC += arg − 1000
```

`sp_SetItemCheck` @ FUN_00510b50, called at the end of every `so_RecalcEquipParam`: counts the equipped pieces per set
(`setitemclassifier.sic_ItemSetPiece[ItemDataBoxIndex.SetItemIndex]++`, sets below `sic_TotalNumber`) and
`SetItemClassifier::sic_SetItemDefine` @ FUN_00510370 writes up to 10 effect ids (`PlayerSetEffect.effectarray[10]`,
more → assert) for each set with 1…5 pieces present into `p.sp_SetItemEffect`. Those effects act on skills and on the
abnormal states the player casts (Z03 §5.6 `g_SetEffect`), not directly on the matrix; the whole set-item subsystem
(`SetItem.shn`, `SetItemEffect.shn`, the `siae_*` / `aeo_SetItemEffect*` functions) is outside this part (see the
coverage boundary).

### 2.6 `LastTune` (layers 13, 14): `so_RecalcLastParam` (vt 0x368) @ FUN_004cb570

```pseudo
so_RecalcLastParam(p):
    LastTune.Plus = eraser_plus; LastTune.Rate = eraser_rate
    if cpl_IsLearn(&p.sp_Passive, PassiveDataBox::sdb_SpecSkillStruct(&passivedatabox).ss_PowerOfLove):    @ FUN_004193b0, FUN_0059ebe0
        LastTune.Rate.Str, Con, Dex, Int, Men += 50                  # +5 % on the five stats, applied after all flat bonuses
```

`ss_PowerOfLove` is one passive id from the special-skill block of the passive data box *(the passive behind it is
not identified; inferred from the name: a wedding/couple passive)*. No other writer of layers 13–14 exists.

### 2.7 Summary: which source feeds which cell

| Source | Layer(s) | Cells |
|---|---|---|
| `ParamXxxServer.txt` level row + charged `cec_MoreStat` | PureCharParam | Str, Con, Dex, Int, Men; MoveSpeed/HPRecover/SPRecover = 1000 |
| equipped items (`ItemInfo`) | Item.Plus, Item.Rate, ItemPowerRate.Rate | WC, AC, MA, MR, TH, TB, ShieldAC, HitRate, EvaRate, MACri, CriDam, MagCriDam; CriDamRate, CriticalTB; WC/AC/MA/MR rates |
| grade options (`GradeItemOption`) + random options + amulet enhancement | Item.Plus, Item.Rate, ItemPowerRate.Rate | five stats, WC, MA, TH, TB, AC, MR, CriDamRate, MaxHP_2, MaxHP, MaxSP, resistances, TH/TB rates |
| KQ items (`KQItem.shn`) | ItemPowerRate.Rate, Item.Plus | MoveSpeed rate, AbsoluteAttack |
| charged item power (`cec_ItemPowerAttack/Defence`) | ItemPowerRate.Rate | start value of WC/MA/AC/MR rates |
| enhancement (`UpgradeInfo.shn` / `BRAccUpgradeInfo.shn`) | Upgrade.Plus | AC, WC, ShieldAC, MA, MR, Cri rates |
| weapon title vs the current target (`WeaponTitleData.shn`) | WeaponTitle.Rate | WC, MA (flat), CriDamRate |
| passives (`PassiveSkill.shn`) | PassiveSkill.Plus/Rate + special fields | masteries, SPRecover, TB, Int, CastingTime, MagCriDamRate, MaxSP, MaxLP, WC/MA rate, HP-down curves, heal/keep-time/crit-damage rates, DMGMinusRate |
| abnormal states (`SubAbState.shn`) + set-item modifiers | AbnormalState.Plus/Rate + special fields | table §2.5 |
| PowerOfLove passive | LastTune.Rate | five stats +5 % |
| — | ItemPowerRate.Plus, Upgrade.Rate, WeaponTitle.Plus, LastTune.Plus | never written (always 0 / 1000) |

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z12-B1 | `Parameter::Cluster::operator*=` @ FUN_004c9160 | the `CriDam` line appears twice; `MACri`, `MagCriDam` once | a CriDam rate ≠ 1000 in ItemPowerRate/AbnormalState/PassiveSkill/LastTune.Rate is applied squared | multiply once (the second line was probably meant for another member) |
| Z12-B2 | `cpl_RecalcParam` @ FUN_00445940 | the special fields (`PassiveHealRate`, `PassiveBuffKeepTimeUPRate`, `PassiveCriDamageRatePlus`, `DMGMinusRate`, the seven `ChangeByConditionParam`s) are assigned but never reset by the recalculation | after a passive is removed (unlearn, class change) its special effect stays until the next map login | reset them in `so_RecalcPassiveParam` like the clusters |
| Z12-B3 | `siae_ParameterRefit` @ FUN_005108c0, code 1008 | `MaxSP = arg × newMaxHP / 1000` | the set-item HP/SP-max modifier replaces the state's MaxSP bonus by one derived from its MaxHP bonus | `MaxSP = arg × MaxSP / 1000` (as in pass 1, code 14) |

## N. Not reconstructed / uncertain

- `ItemPowerRate.Plus`, `Upgrade.Rate`, `WeaponTitle.Plus`, `LastTune.Plus` have no writer in the 2016 zone (searched by
  member name and `p+` offset); whether a reader exists is checked in the sweep.
- The meaning of `ItemEquipTable.Equ_LeftHand == 2` (two-handed weapon in the right hand) and of `attr.vt[0x9c]` (costume
  charge left) is inferred; Z17 owns the costume charges.
- `SAA_ALLSTATEPLUS` (39) goes into the rate cluster while `SAA_ALLSTATPLUS` (119) is flat; data `SubStaEventAllStatsUp`
  uses 39 with arg 7 (= +0.7 %), which may have been meant as +7 flat.
- The ≥ 1000 `eb_Index` codes in `siae_ParameterRefit` pass 2 do not match the `SetIndex` enum; their source
  (`aeo_SetItemEffectStore`) was not traced.
- `pmv.pmv_var` (passive mastery column table) was read only through its use; its initialiser was not opened.
