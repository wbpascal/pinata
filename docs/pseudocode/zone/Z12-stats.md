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

## 3. Maxima: HP, SP, LP and the soul-stone stock

All maxima are computed on demand from the layers (they are not in `Total`, §1.3). The class object is
`p.vt[0x49c]()` `so_CharacterClass` (= `p+0xfbc`, §2.1); its slot `+0x20` is `MaxHP`, `+0x24` `MaxSP`, `+0x28` `MaxLP`,
`+0x2c` `LPRecover`, `+0x30` `LPTick`, `+0x34` `LPRecoveryRoutine`, `+0x38` `cc_ClassType`.

### 3.1 Class slots

| Slot | `CharClass` (all 25 non-LP classes) | `CharClassSentinel` / `CharClassSavior` | `CharClassMob` |
|---|---|---|---|
| +0x20 MaxHP | `CharClass::MaxHP` @ FUN_00449610 | same | `CharClassMob::MaxHP` @ FUN_004496f0 = `MobInfo.MaxHP` of `o.vt[0x70c]()` (+0x46) |
| +0x24 MaxSP | `CharClass::MaxSP` @ FUN_00449660 | `CharClassSentinel::MaxSP` @ FUN_0064f610 `return 1` | as CharClass |
| +0x28 MaxLP | `return 0` (FUN_00570b00, a folded stub) | `CharClassSentinel::MaxLP` @ FUN_0044a830 = `SingleData["SenMaxLP"]` | `return 0` |
| +0x2c LPRecover | `return 0` | @ FUN_0044a870 = `SingleData["SenSPRecover_Amount"]` | `return 0` |
| +0x30 LPTick | `return 0` | @ FUN_0044a8b0 = `SingleData["SenSPRecover_Time"]` × 1000 (ms) | `return 0` |
| +0x34 LPRecoveryRoutine | no-op (FUN_00549070, folded) | @ FUN_00449a50 (§3.4) | no-op |
| +0x38 cc_ClassType | `return 0` | 26 / 27 | 28 |

`cc_ClassType` returns the class id (`CharClassFighter` 1 … `CharClassSavior` 27, one `mov eax, n; ret` stub per class)
and is the column index into `ChrCommon.txt StatTable` (§5.1). `SingleData` = `gSingleData` (`CSingleDataMap::GetValue`,
the `SingleData.shn` key → u16 table that W05 §3.3 documents for the WM; the zone loads the same file).

```pseudo
CharClass::MaxHP(cls, o, cl = &Total):  row = cls.cc_array[o.so_GetLevel()]          @ FUN_00449610
    return row.LevelHP + (cl.Con − row.constitution) × 5          # 5 HP per END point above the class table's END
CharClass::MaxSP(cls, o, cl = &Total):                                                 @ FUN_00449660
    return row.LevelSP + (cl.Men − row.mentalpower) × 5           # 5 SP per SPR point above the table's SPR
```

`cc_array[level]` is indexed without a bound check here (`so_GetLevel` is a u8; levels > 150 would read past the array;
`c_Storepure` guards the same access with `< 0x97`) *(inferred: unreachable, `LevelLimit` = 125)*.

### 3.2 `ShinePlayer::sp_MaxHP` @ FUN_0054a670 and `sp_MaxSP` @ FUN_0055a8b0

```pseudo
sp_MaxHP(p):
    base = cls.MaxHP(p, &P.Total) + so_ply_FreeStatCon(p).MaxHP (vt 0x474, §4.1) + P.Item.Plus.MaxHP_2
    p.+0xea8 = (P.AbnormalState.Rate.MaxHP − 1000 + p.sp_ChargedItem.ci_Effect.cec_MaxHPRate) × base / 1000
    p.+0xea8 += P.Item.Plus.MaxHP + P.AbnormalState.Plus.MaxHP
    if P.ChangeAbilityInfo (P+0xcd4) != 0xFFFF and mobdatabox[it]:  p.+0xea8 = MobInfo.MaxHP      # polymorph (SAA_METAABILITY)
    return p.+0xea8                                               # signed int arithmetic, truncating

sp_MaxSP(p):
    base = cls.MaxSP(p, &P.Total) + so_ply_FreeStatMen(p).MaxSP (vt 0x478)
    p.+0xeac = (P.AbnormalState.Rate.MaxSP − 1000 + cec_MaxSPRate) × base / 1000
    p.+0xeac += P.Item.Plus.MaxSP + P.PassiveSkill.Plus.MaxSP + P.AbnormalState.Plus.MaxSP
    if P.ChangeAbilityInfo != 0xFFFF and mobdatabox[it]:  p.+0xea8 = MobInfo.MaxHP               # (original bug) Z12-B4
    return p.+0xeac

ShinePlayer::so_MaxHP (vt 0x4f0) @ FUN_0055ac10 / so_MaxSP (vt 0x4f4) @ FUN_0055ac50:
    sp_MaxHP(p) / sp_MaxSP(p); a result < 1 is stored as 1; CurHP / CurSP (p.sp_CharData.toclient.basedata) clamped to it
```

So `cec_MaxHPRate` / `cec_MaxSPRate` (charged items; 1000 by default, `so_ChargedEffectContainerClear`, Z10 §1.1) and the
abstate rate add their per-mille excess, and only the class value, the free-stat bonus and the random-option `MaxHP_2`
are scaled; item and abstate flat bonuses are added after the rate. `Item.Rate`, `PassiveSkill.Plus.MaxHP` and all
`LastTune` cells are not read. `MaxHP` / `MaxSP` of `PassiveSkill.Rate`, `ItemPowerRate` and `Upgrade` are not read
either. A polymorphed player (P+0xcd4 = mob id) gets the mob's MaxHP; its MaxSP stays the player's (Z12-B4: the
polymorph branch of `sp_MaxSP` overwrites the HP cache with the mob's MaxHP and returns the unchanged SP value).

Callers: `so_MaxHP`/`so_MaxSP` (vt 0x4f0/0x4f4: everything that clamps or refills HP/SP, the notify §4) and
`so_fill_CHAR_PARAMETER_DATA` (§4.3, calls `sp_MaxHP` / `sp_MaxSP` directly, without the ≥ 1 clamp).

`sp_RecoverPoint_HPAfterItemEquip` @ FUN_0056b280 (installed as the one-shot `sp_RecoverPoint` hook by
`so_RecalcEquipParam`, §2.2): `c_MakeTotal(P)`; clamp CurHP to `so_MaxHP` and CurSP to `so_MaxSP`;
`so_AllOfRange(…, so_ply_Send2WhoTargetMe)` (the HP to everyone targeting `p`, Z09 §2.4); then the hook is reset to
the no-op (`so_Gamble_ChangeCoin` is the folded empty function).

### 3.3 LP (Sentinel / Savior): `so_ply_Sen_MaxLP` (vt 0xd94) @ FUN_005611e0 and the recovery

`p.sp_Sen_LP` (`ShinePlayer::LPInfo`) = `{ nCurLP, nMaxLP, nCurLPRecover, nLastLP, nLastMaxLP, RecoverTick {m_NextTick,
m_TickInterval} }` (member names *(pdb2016)*).

```pseudo
so_ply_Sen_MaxLP(p):                                                     # vt 0xd94
    t = round((float)(P.AbnormalState.Rate.MaxLP × cls.MaxLP()) / 1000.0)  # products converted as unsigned
    t = round((float)(cec_MaxLPRate × t) / 1000.0)
    p.sp_Sen_LP.nMaxLP = t + P.AbnormalState.Plus.MaxLP + P.PassiveSkill.Plus.MaxLP
    return nMaxLP                                                        # 0 + bonuses for every other class

so_ply_Sen_RecalcLPRecover(p):                       @ FUN_00561330      # vt 0xda4; run by the per-tick abstate rebuild (§1.4)
    nCurLPRecover = round((float)(P.AbnormalState.Rate.LPRecover × cls.LPRecover()) / 1000.0) + P.AbnormalState.Plus.LPRecover
so_ply_Sen_GetLPRecover (vt 0xda0) @ FUN_00561320 = nCurLPRecover
so_ply_Sen_GetLPRecoverInterval (vt 0xda8) @ FUN_005613c0 = cls.LPTick()
so_ply_Sen_GetLP (vt 0xd90) @ FUN_005611d0 = nCurLP
so_ply_Sen_GainLP(n) (vt 0xd98) @ FUN_005612c0:  nCurLP = min(nCurLP + n, nMaxLP)
so_ply_Sen_LostLP(n) (vt 0xd9c) @ FUN_005612f0:  nCurLP = (n < nCurLP) ? nCurLP − n : 0

so_ply_Sen_InitLP(p):                                @ FUN_00563920      # vt 0xd8c; called by sp_NC_MAP_LOGINCOMPLETE_CMD @ FUN_00443390
    GainLP(MaxLP())                                  # full LP at every map login
    nLastLP = nLastMaxLP = 0xFFFFFFFF                # forces the first 0x245F / 0x1035 MaxLP entry
    RecoverTick.m_TickInterval = LPRecoverInterval() × 10 / 1000;  m_NextTick = now + interval     # clockwatch ticks (100 ms, inferred)

CharClassSentinel::LPRecoveryRoutine(cls, p):        @ FUN_00449a50      # class slot +0x34, run every player tick (Z09 §2.3)
    if p.smo_GetMode() (vt 0x484) != 3 (dead) and so_ply_Sen_LP_Tick(p) (vt 0xdac):
        so_ply_Sen_GainLP(p, so_ply_Sen_GetLPRecover(p))
so_ply_Sen_LP_Tick(p):                               @ FUN_005613e0
    if RecoverTick.m_NextTick < clockwatch.cw_CurrTick: m_NextTick += m_TickInterval; return 1   # one step per tick, no catch-up
    return 0
```

The client learns LP through `0x245F NC_BAT_LPCHANGE_CMD` (`sp_SendLPinform`, Z09 §2.4) and MaxLP through the `0x1035`
entry 0x24 (§4.2). LP costs and LP damage are Z03's (skill cost §5.3).

### 3.4 Soul-stone stock maxima

`PrimaryParameter.hpsoulstone` / `spsoulstone` (+0x1c / +0x28, §2.1) = `PointSoulStone { soul, maxsoul, buysoul }` of the
level row. The stock limit is `maxsoul × cec_HPStoneLimit / 1000` (resp. `cec_SPStoneLimit`; `sp_ChargedItem.ci_Effect`
`p+0x2a5a2 / p+0x2a5a4`, 1000 by default, raised by charged "stone bag" items *(inferred)*):

- `so_fill_CHAR_PARAMETER_DATA` (§4.3) sends it as `MaxHPStone` / `MaxSPStone` (`& 0xFFFF`).
- `sp_PointStoneBuy` @ FUN_00588510 (Z04 §13.1) refuses a purchase with `0x742` when `have + number + reserved >
  maxsoul × limit / 1000`; the price is `buysoul × number`.
- `soul` is the heal amount of one stone (Z04 §13.2).

---

## 4. The refresh: `so_mobile_NotifyParameterChange` (vt 0x34) @ FUN_00503c10

The profiler string calls it `ShinePlayer::smo_NotifyParameterChange`. It finishes every rebuild: it is the only place
apart from `so_allparametercalculate` and `sp_RecoverPoint_HPAfterItemEquip` that runs `c_MakeTotal`, it replaces the
displayed attack/defence cells of `Total` by the combat-formula values, and with `send = 1` it sends the differences.

### 4.1 Free-stat bonus rows (`ChrCommon.txt`, Z10 §5.4)

```pseudo
so_ply_FreeStatStr/Int/Dex/Con/Men(p)   vt 0x468 / 0x46c / 0x470 / 0x474 / 0x478     @ FUN_0055a350 / 0055a390 / 0055a3d0 / 0055a410 / 0055a450
    n = p.so_GetStatDistStr() (vt 0x424, = p.sp_CharData…statdistribute = p+0x7f94) [stat]      # spent points STR, END, DEX, INT, SPR
    return shineparam.scp_param.freestat<Xxx>[n > MaxFreeStat ? 0 : n]                          # row pointer
ShineObject::so_ply_FreeStat* @ FUN_00555140 … FUN_00555180 (mobs, NPCs): freestat<Xxx>[0] (the all-zero row)
```

| Table (row struct, 2016 values for 1 / 10 / 180 points) | Field | Read by |
|---|---|---|
| `FreeStatStrTable` `{Stat, WCAbsolute, checksum}`: 1 / 12 / 216 | WCAbsolute | `NormalPY::roe_Damage` +att (Z03 §4.6), notify WCmin/WCmax, 0x1035 #0x12, `NormalMA::roe_FreeStateAttackPower` (Z12-B6) |
| `FreeStatIntTable` `{Stat, MAAbsolute}`: 1 / 12 / 216 | MAAbsolute | `NormalMA::roe_Damage` +att, notify MAmin/MAmax, #0x14, `NormalPY::roe_FreeStateAttackPower` (Z12-B6) |
| `FreeStatDexTable` `{Stat, THRate, TBRate}`: 3,2 / 30,20 / 280,230 | THRate (+1), TBRate (+3) | every `roe_HitRate` (Z03 §4.3: TH + att, TB + def), notify TH / TB, #0x16 / #0x17 |
| `FreeStatConTable` `{Stat, ACAbsoulte, BlockRate, MaxHP}`: 1,1,5 / 5,10,50 / 90,100,900 | ACAbsoulte (+1) | `NormalPY::roe_Damage` −def, notify AC, #0x13, `NormalMA::roe_FreeStateDefendPower` (Z12-B7) |
| | BlockRate (+3) | `NormalPY::roe_ShieldBlock` @ FUN_004ff860 (added when the shield block rate > 0), #0x19 |
| | MaxHP (+5) | `sp_MaxHP` (§3.2), #0x1a |
| `FreeStatMenTable` `{Stat, MRAbsolute, CriRate, MaxSP}`: 1,2,5 / 5,20,50 / 90,130,900 | MRAbsolute (+1) | `NormalMA::roe_Damage` −def, notify MR, #0x15, `NormalPY::roe_FreeStateDefendPower` (Z12-B7) |
| | CriRate (+3) | `RulesOfEngagement::roe_FreeStatCriRate` @ FUN_004ffdb0: `rate + CriRate` (NormalPY, NormalMA and MagicalSkill critical rates; not PhisycalSkill), #0x18 |
| | MaxSP (+5) | `sp_MaxSP` (§3.2), #0x1b |

So spent stat points act only through these rows; they never enter the matrix (§2.1 confirmed).
The two `roe_FreeState*` vtable slots (+0x30 attack, +0x34 defence) are only used by `roe_GetAttackPower` @ FUN_005045e0
(`AttackPower + slot 0x30`, the DoT snapshot of `aeo_Set` @ FUN_0040a340, Z03 §6.2) and `roe_AttackPowerCalcDamage`
@ FUN_005047d0 (`DefendPower + slot 0x34`, the DoT / bomb damage of `sasa_GetDamage` @ FUN_0040b360 and
`SubAbnormalStateActorBomb::sasa_ApplyAbstate` @ FUN_0040c640). Both slots are wrong:

```pseudo
NormalPY::roe_FreeStateAttackPower(ctx)  @ FUN_005003c0 = att ? att.FreeStatInt.MAAbsolute : 0     # physical rule set reads INT (original bug) Z12-B6
NormalMA::roe_FreeStateAttackPower(ctx)  @ FUN_00500390 = att ? att.FreeStatStr.WCAbsolute : 0     # magical rule set reads STR
NormalPY::roe_FreeStateDefendPower(ctx)  @ FUN_00500420 = att ? att.FreeStatMen.MRAbsolute : 0     # attacker, and the magic stat (original bug) Z12-B7
NormalMA::roe_FreeStateDefendPower(ctx)  @ FUN_005003f0 = att ? att.FreeStatCon.ACAbsoulte : 0
    # sasa_GetDamage builds its EngageArgument with att = NULL, def = victim → the defence term is always 0
```

(The PhisycalSkill / AlwaysCritical rule sets share the NormalPY slots, MagicalSkill the NormalMA ones.)

### 4.2 The notify

```pseudo
so_mobile_NotifyParameterChange(p, send):                               @ FUN_00503c10
    m = p.so_ply_ChargedStatPlus() (vt 0x8e0, cec_MoreStat)
    p.sp_LastStat.last.Str/Con/Int/Dex/Men −= m                         # see the note below
    c_MakeTotal(P)                                                      # §1.3
    ctx = EngageArgument(att = p, def = p)
    if P.ChangeAbilityInfo == 0xFFFF:                                   # not polymorphed: the combat formulas on the static roe_normalPY
        Total.WCmin = (int) roe_MinWC(ctx) + FreeStatStr.WCAbsolute     # RulesOfEngagement::roe_MinWC @ FUN_004fdbe0 (Z03 §4.6)
        Total.WCmax = (int) roe_MaxWC(ctx) + FreeStatStr.WCAbsolute     # @ FUN_004fea10
        Total.MAmin = (int) roe_MinMA(ctx) + FreeStatInt.MAAbsolute − P.Item.Plus.MAmin      # @ FUN_004fd640 (formula below)
        Total.MAmax = (int) roe_MaxMA(ctx) + FreeStatInt.MAAbsolute − P.Item.Plus.MAmax      # @ FUN_004fd910
        Total.AC    = (int) roe_AC(ctx) + FreeStatCon.ACAbsoulte        # @ FUN_004fcbc0 (Z03 §4.6 roe_DefendPower: Total(END) + Total(AC))
        Total.MR    = (int) roe_MR(ctx) + FreeStatMen.MRAbsolute        # @ FUN_004fd3b0
        Total.TH    = (int) roe_TH(ctx) + FreeStatDex.THRate            # @ FUN_004fc700: max(Total(DEX),1) + Total(TH), min 1
        Total.TB    = (int) roe_TB(ctx) + FreeStatDex.TBRate            # @ FUN_004fc950
    else:                                                               # polymorphed into mob m = mobdatabox[ChangeAbilityInfo]
        m missing → assert "…Not Find MobID :" (no further work, nothing sent)
        Total.AC, MR, TB = MobInfoServer AC, MR, TB
        Total.WCmin/WCmax/MAmin/MAmax/TH = m.weapon MinWC/MaxWC/MinMA/MaxMA/TH if m.weaponnumber == 0 else 0
    if !send: return                                                    # Total keeps the values above; sp_LastStat untouched
    body = PROTO_NC_CHAR_BASEPARAMCHANGE_CMD at gpp+2 { u8 changenum = 0, CHAR_PARAMCHANGE_CMD param[] {u8 flag, u32 value} }
    add(flag, new, old) = Cluster::c_compareelement @ FUN_004c9660: if new != old: param[changenum++] = {flag, new}
    hp = so_MaxHP() (vt 0x4f0); sp = so_MaxSP() (vt 0x4f4)              # also clamps CurHP / CurSP
    add(0x10, hp, last.lastmaxhp); add(0x11, sp, lastmaxsp); lastmaxhp = hp; lastmaxsp = sp
    lp = so_ply_Sen_MaxLP(); add(0x24, lp, sp_GetLastMaxLP() @ FUN_00561430); sp_SetLastMaxLP(lp) @ FUN_00561440
    add(0x12, Str.WCAbsolute, −1); add(0x13, Con.ACAbsoulte, −1); add(0x14, Int.MAAbsolute, −1); add(0x15, Men.MRAbsolute, −1)
    add(0x16, Dex.THRate, −1); add(0x17, Dex.TBRate, −1); add(0x18, Men.CriRate, −1); add(0x19, Con.BlockRate, −1)
    add(0x1a, Con.MaxHP, −1); add(0x1b, Men.MaxSP, −1)                  # compared with 0xFFFFFFFF: these ten are always sent
    copy = Total                                                        # 51 ints
    atk = cec_AttackForceRate1024; def = cec_DefendForceRate1024         # so_ply_ChargedEffectContainer (vt 0x498) +0x12 / +0x14
    Total.WCmin/WCmax/MAmin/MAmax = v × atk / 1024;  Total.AC/MR = v × def / 1024           # (signed, rounded toward 0)
    n = Cluster::c_compare(Total, last, body) @ FUN_004c96f0:
        add for Str 0, Con 1, Dex 2, Int 3, Men 5, WCmin 6, WCmax 7, AC 8, TH 9, TB 10, MAmin 11, MAmax 12, MR 13, MH 14, MB 15
        (flag 4 Wizdom is never sent); returns the total changenum
    if n > 0 (always: the ten free-stat entries):
        send p (game stream): 0x1035 NC_CHAR_CHANGEPARAMCHANGE_CMD, length 3 + 5·changenum
        (pp_SetPacketLen fails → assert "…smo_NotifyParameterChange : Packet Too Long")
    ChangeByConditionParam::cbcp_MakeParam(P.PassiveHPDownRateWCMin, copy.WCmin, atk, 0x1c, p)   @ FUN_004cbb30
                                       (…WCMax, copy.WCmax, atk, 0x1d), (…MAMin, copy.MAmin, atk, 0x1e), (…MAMax, copy.MAmax, atk, 0x1f),
                                       (…AC, copy.AC, def, 0x20), (…MR, copy.MR, def, 0x21)
    cbcp_MakeParam_Plus(P.PassiveMovingTBPlus, copy.TB, 0x400, 0x23, p)                       @ FUN_004cbcd0
    Total = copy                                                        # undo the force-rate scaling
    so_BackupParameter(&sp_LastStat.last) (vt 0x358) @ FUN_0052b0f0: last = Total
```

Notes on the comparison:
- `last` stores the **unscaled** `Total`, but the comparison uses the scaled one, so with a charged attack/defence
  force item (`cec_*ForceRate1024` ≠ 1024) WC/MA/AC/MR are re-sent on every refresh *(inferred: harmless traffic)*.
- `last.Str…Men −= cec_MoreStat` before the comparison makes STR/END/DEX/INT/SPR differ whenever a charged "stat up"
  item is active, so they too are re-sent each time *(inferred; the intent is unclear, the values sent are correct)*.
- `sp_LastStat.lastmaxhp/lastmaxsp/lasthp/lastsp` and `nLastLP/nLastMaxLP` are set to 0xFFFFFFFF by
  `sp_NC_MAP_LOGINCOMPLETE_CMD` @ FUN_00443390 (and `so_ply_Sen_InitLP`), so the first refresh after a map login sends
  MaxHP, MaxSP and MaxLP. `last` itself is not reset there.

`roe_MinMA` / `roe_MaxMA` (Z03 §4.6 leaves the magical side "not traced"; cells as `layer.member`, `T(x)` = the
`Total` formula of Z03 §4.1 recomputed in double: `(L0+L1)·L12·L10·L4·L14/10¹² + L5+L7+L9+L11+L13`):

```pseudo
roe_MinMA(ctx):                                                          @ FUN_004fd640
    int  = max(T(Int), 1)
    rst  = T(MAmin) + int + L9.MagicalWeaponMastery + L1.MAmin × L10.MagicalWeaponMastery × L8.MAmax / 10⁶
    return max(rst × L4.MAmin / 1000, 1)
roe_MaxMA(ctx): the same with MAmax everywhere                          @ FUN_004fd910
```

`L4` (ItemPowerRate.Rate) thus scales MA twice (inside `T(MAmin)` and at the end) while `roe_MinWC` applies it once
*(inferred: may be intended, the two formulas are built differently)*; `roe_MinMA` reads the weapon-title **max** cell
`L8.MAmax` (P+0x68c) where `roe_MinWC` reads `L8.WCmin` (original bug) Z12-B5. (`roe_MinWC` reads `L12.WCmax` (P+0x9a8)
as its abstate rate; `SAA_WCRATE` writes both cells with the same value, §2.5, so that has no effect.)

`Total.MAmin/MAmax` then subtract the flat item MA again (`− Item.Plus.MAmin/MAmax`, p+0x10b4/+0x10b8), WC does not
*(inferred: the client adds the weapon's MA itself; not checked)*.

### 4.3 Packets

```pseudo
0x1035 NC_CHAR_CHANGEPARAMCHANGE_CMD (Z→C) { u8 changenum; CHAR_PARAMCHANGE_CMD param[changenum] { u8 flag; u32 value } }
```

| flag | value | client field (`User::ChangeChangeParam` *(pdb2017 client)*) |
|---|---|---|
| 0, 1, 2, 3 | Total STR, END, DEX, INT | `param.Strength/Constitute/Dexterity/Intelligence.change` |
| 4 | (never sent) | `param.Wizdom.change` |
| 5 | Total SPR | `param.MentalPower.change` |
| 6, 7, 8, 9, 10, 11, 12, 13 | WCmin, WCmax, AC, TH, TB, MAmin, MAmax, MR (after §4.2 and the force rates) | `WClow, WChigh, AC, TH, TB, MAlow, MAhigh, MR .change` |
| 14, 15 | Total MH, MB (c_MakeTotal value) | `MH, MB .change` |
| 0x10, 0x11 | MaxHP, MaxSP | `param.MaxHp` (+ main character HP bar), `param.MaxSp` |
| 0x12 … 0x1b | free-stat WC, AC, MA, MR, TH, TB, critical, block, MaxHP, MaxSP | `m_kFreeStatPoint.dwFreeWC … dwFreeMAXSP` (the character window's "+n" column) |
| 0x24 | MaxLP | `param.MaxLp` |

Client: 2016 `FUN_00499810` → `FUN_00662de0` (= 2017 `GameFrameWork::On_NC_CHAR_CHANGEPARAMCHANGE_CMD` → `User::ChangeChangeParam`),
then the status bars are redrawn. Unknown flags are ignored.

```pseudo
0x10DF NC_CHAR_CHANGEBYCONDITION_PARAM_CMD (Z→C) { u16 nSkillID; u16 nChangeRate; u16 nParamNum;
                                                  CHAR_CHANGEBYCONDITION_PARAM aParam[nParamNum] { u8 nFlag; u8 nIndex; u32 nValue } }
cbcp_MakeParam(c, base, charged, flag, p):                               @ FUN_004cbb30
    if (c.cbcp_nCondition or c.cbcp_nChange) and c.cbcp_nMaxValueNum and (base, charged) != (c.cbcp_nChangeParam, c.cbcp_nCharged):
        c.cbcp_nChangeParam = base; c.cbcp_nCharged = charged
        for i < nMaxValueNum: c.cbcp_pValue[i] = base × i × c.cbcp_nChange / 1000       # bonus at step i of the HP-loss curve
        send p: 0x10DF { nSkillID = c.cbcp_nID, nChangeRate = (u16) c.cbcp_nCondition, nParamNum = nMaxValueNum,
                         aParam[i] = { flag, i, (c.cbcp_pValue[i] + base) × charged >> 10 } }       # len 8 + 6·n
        (more than 7999 bytes → assert "cbcp_FillSendBuffer: Buffer Over"; pp_SetPacketLen fails → "cbcp_SendBuffer : Packet Too Long")
cbcp_MakeParam_Plus (TB curve):                                           @ FUN_004cbcd0
    same, but cbcp_pValue[i] = c.cbcp_nChange × (i + 1)                   # flat steps; charged = 0x400 (no scaling)
```

`nFlag` uses the 0x1035 numbering of the target cell: 0x1c WCmin, 0x1d WCmax, 0x1e MAmin, 0x1f MAmax, 0x20 AC, 0x21 MR,
0x23 TB (0x22 unused). The `ChangeByConditionParam` blocks are the passive "lower HP → more attack/defence" curves
(`PassiveHPDownRate*`, `PassiveMovingTBPlus`, filled by `cbcp_SetCondition`, §2.4); the packet is sent only when the
base value or the force rate changed. Client: `GameFrameWork::On_NC_CHAR_CHANGEBYCONDITION_PARAM_CMD` *(pdb2017 client;
2016 FUN_0049cec0)* enables the character window's condition display for passive `nSkillID`, sets the section rate
`nChangeRate` and stores each `{nFlag, nIndex, nValue}` (`CharInfoWin::SetConditionInfo`).

`so_fill_CHAR_PARAMETER_DATA` @ FUN_005a2e00 (Z07 §1.5, for 0x1802 and `0x240C` level-up) calls the notify with
`send = 0` first, so its `change` values are the §4.2 cells. Exp indexing (corrects Z07 §1.5):
`PrevExp = nextexp[level − 1]`, `NextExp = nextexp[level]` (§5.1).

Callers of the notify: with `send = 1`: `ShineMobileObject::so_Routine` (the `parameterchange` path, §1.4),
`ShinePlayer::so_Routine` @ FUN_0056c790, `so_ply_ChargedBuff` @ FUN_005970c0, `ciee_Free` @ FUN_00450a50,
`~ChargedEffectListRouter` @ FUN_00450e80, `sp_NC_CHAR_CHARGEDBUFF_ERASE_REQ` @ FUN_005645e0, `so_ply_InitFreeStat`
@ FUN_00518ab0, `RecoverTypeEffect::_execute` @ FUN_005cfc70, the GM commands `&godmode`, `&hpchange`, `&spchange`,
`&gmtestmode` (Z11); with `send = 0`: `so_KilledBy` @ FUN_00432240 and `so_fill_CHAR_PARAMETER_DATA`; with a
computed flag: `sp_MoverSystem_SummonItem` @ FUN_0045ec10, `sp_HorseOn` @ FUN_0045f270, `icr_Apply` (furniture
relocation) @ FUN_0048a560, `sp_DecorationActivCheck` @ FUN_00534c60.

---

## 5. Level and experience

### 5.1 Tables (`ChrCommon.txt`, loader Z10 §5.4)

`shineparam.scp_param` (`ShineParameter`, DAT_0da50470) members used here:

| Member | Address | Use |
|---|---|---|
| `levellimit` (u8, 125) | DAT_0da50484 | Z03's `g_MaxLevel`: no exp at or above it (`sp_GainExp`); also the level caps of portals / instance gates / `&templink` |
| `LostExpLevel` (u8, 21) | DAT_0da504a8 | death exp loss starts at this level (`sp_LostExperienceByKilled` @ FUN_0042e210, Z03 §7.2) |
| `MaxFreeStat` (u8, 180) | DAT_0da504a9 | per-stat cap: index guard of the free-stat rows (§4.1) and `so_ply_StatIncrease` @ FUN_0058b0c0 |
| `nextexp[151]` (u64) | DAT_0da504b0 | `nextexp[l]` = cumulative exp at which level `l + 1` starts (StatTable column `NextExp` of row `l`; `nextexp[0] = 0`) |
| `commonparam[151]` (row ptr) | DAT_0da50968 | StatTable row per level (`commonparam[0] = commonparam[1]`) |
| `RestExpRate`, `MaxExpBonus` | +0x20, +0x18 | loaded but never read by the 2016 zone (searched by member name) |
| `MinNeedTime`, `DefaultBonusTime`, `IntervalTime`, `AddBuffTime`, `MaxBuffTime` | +0x24 … +0x34 | rest-exp buff (§5.4) |

So the "`g_LevelExp` DAT_0da504a8, u64 per level" of Z03 / Z07 is the address of `nextexp[−1]`: every read in the code
is `nextexp[level − 1]` (start of the current level) or `nextexp[level]` (start of the next). At level 0 the first would
read `LostExpLevel`, `MaxFreeStat` and six padding bytes as a u64; no player has level 0 (the DB starts at 1), so
`MaxFreeStat` merely lies next to the table. StatTable 2016: level 1 `NextExp 10`, level 10 `2350`, level 20 `43539`,
level 150 `1469080243062`.

StatTable columns after `NextExp`: `dummy`, then one u16 per class in `cc_ClassType` order (`Fig, Cfig, War, Gla, Kni,
Cle, Hcle, Pal, Hol, Gua, Arc, Harc, Sco, Sha, Ran, Mag, Wmag, Enc, Warl, Wiz, Jok, Chs, Cru, Cls, Ass, Sen, Sav`) =
`CommonParameter.stat[28]` (+0x33), `ExpLostAtPvP` (u32), `CheckSum`. `stat[class]` = **total stat points owned at that
level**: `sp_CalcTotalStat` @ FUN_00517cc0 = `commonparam[level].stat[cls.cc_ClassType()]` (Z07's `FreeStat_Max`).
2016 values: the five base classes 1 point per level (level 20: 20), the first promotions start at 25 at level 20,
… level 150: Fig 150, Cfig 155, War 165, Gla/Kni 180, Sen 165, Sav 180. `ExpLostAtPvP` (level 20: 300, 150: 681220) is the
exp lost on a PK-field death by a player (`sp_LostExpWhenKilledByPlayerInPKField` @ FUN_0042e130, Z03 §7.2).
`sp_CalcCurrentStat` @ FUN_0044a980 = sum of the five spent-point bytes (Z07 `FreeStat_Spent`).

### 5.2 Level-up side effects (completing Z03 §8.3)

After the level-up packets of Z03 §8.3, `sp_GainExp` @ FUN_0042d830 continues:

```pseudo
    free = so_ply_TotalSkillEmpower(p) − csl_EmpowerSummary(p.skills)
        so_ply_TotalSkillEmpower (vt 0x6b8) @ FUN_00559fd0 = cls.cc_array[level < 0x97 ? level : 0].SkillPwrPt   # PrimaryParameter +0x7c
        if free > 0: send p 0x4810 NC_SKILL_EMPOWPOINT_CMD { u8 restempow = free }
    sp_StatRemainSend(p)                                                @ FUN_0058bd10
        total = commonparam[level].stat[cls.cc_ClassType()]; spent = sp_CalcCurrentStat(p)
        spent > total → assert "sp_StatRemainSend : Too many StatPoint", nothing sent
        else send p (data stream, vt 0x2f8): 0x105B NC_CHAR_STAT_REMAINPOINT_CMD { u8 remain = total − spent }   # 3 bytes
        # profiler label copy-pasted as "gds_NC_CHAR_STAT_DECPOINTFAIL_DB_ACK", length assert as "so_charbasedata"
    so_GainFame(p, level) (vt 0x20)                                     @ FUN_0042df00
        if fame < 1,000,000: fame += level (capped at 1,000,000, the gain reduced accordingly)
            send p: 0x2446 NC_BAT_FAMEGAIN_CMD { u32 famegain }          # client: basedata.fame += famegain
    so_ply_SaveFame(p) (vt 0x450)                                       @ FUN_00518160
        → CharDB (sock2gameDB): 0x1070 NC_CHAR_FAMESAVE_CMD { u32 charregnum = vt 0x344, u32 fame }    # D02: p_Char_FameSet, no reply
    so_ply_ChangeFame(p) (vt 0x44c)                                     @ FUN_00518070
        send p: 0x106F NC_CHAR_FAMECHANGE_CMD { u32 fame }               # client: basedata.fame = fame
    p.sp_NextSaveExp = sp_NextSaveExperience(p)                         # §5.3
    p.sp_CharBriefInfo.bic_BriefInfo.Level = level
    so_Gamble_ChangeExchangedCoin(p) (vt 0xb18)                         @ FUN_00617360
        cap = GambleExchangeMaxCoin row whose first byte == level (u32 at +1), else 0
        send p: 0xBC05 NC_GAMBLE_EXCHANGECOIN_CHANGE_CMD { u64 remain = (cap > p.sp_Gamble_nTotalExchangedCoin) ? cap − total : 0 }   # Z06 §4.1 (coin exchange cap per level)
    GMEventManager::GMEM_CheckAllConditionAndApply(&gGMEventManager, p) @ FUN_0046d8e0     # GM events by level/class/map (Z09 §3)
```

So a level-up gives `level` fame points (one-off; the name "fame" is the PDB's `basedata.fame`). `sp_StatRemainSend`
also runs at map login (`sp_NC_MAP_LOGINCOMPLETE_CMD`), after a class change (`so_ply_ClassChange` @ FUN_004521b0)
and after `&levelup` (`so_AmpersandCommand_LevelUp` @ FUN_0042fa00, Z11).

Client: `On_NC_CHAR_STAT_REMAINPOINT_CMD` sets `m_iRemainStatPoint = remain`; `On_NC_BAT_FAMEGAIN_CMD` adds,
`On_NC_CHAR_FAMECHANGE_CMD` sets the fame *(pdb2017 client; 2016 inline in FUN_004be490 / FUN_0049a580)*.

### 5.3 `sp_NextSaveExperience` @ FUN_0042d6f0

```pseudo
sp_NextSaveExperience(p):
    lo = nextexp[level − 1]; hi = nextexp[level]; range = hi − lo
    if range == 0: return lo
    k = (exp − lo) × 16 / range                                         # u64, truncating
    return lo + (k + 1) × range / 16                                    # the next 1/16 mark of the current level
```

`sp_GainExp` refreshes `sp_NextSaveExp` (p+0x7fb0) when the exp passes it; nothing in the 2016 zone acts on the mark
(readers: `sp_GainExp`, `&levelup`, `sp_NC_MAP_LOGINCOMPLETE_CMD`, all only writing it) *(inferred: a leftover of an
"exp save every 1/16 level" scheme; the exp now goes to the WM with every gain, 0x1073)*.

### 5.4 Rest-exp buff: `RestExpCalculate::RestExpAbstateApplication` @ FUN_0059d510

`RestExpCalculate` @ FUN_0059d4b0 copies `MinNeedTime` (21600 s), `DefaultBonusTime` (600), `IntervalTime` (3600),
`AddBuffTime` (600), `MaxBuffTime` (7200) from `scp_param` into `m_NeedTime, m_FirstAddBuffTime, m_InterValTime,
m_AddBuffTime, m_BuffMaxTime`. The caller (a stack object in `wms_NC_CHAR_ZONE_SINGLE_OPTION_CMD` @ FUN_005a6200, part 4)
passes the time of the last logout.

```pseudo
RestExpAbstateApplication(calc, p, &lastTime):
    if !p: return false
    now = _time32(); off = now − lastTime
    if !p.so_AbnormalState_IsSet(345 StaRestExp) (vt 0x3e4):
        ms = (off > 0 and off ≥ NeedTime) ? min(((off − NeedTime) / IntervalTime × AddBuffTime + FirstAddBuffTime) × 1000, BuffMaxTime × 1000) : 0
    else:
        add = (off > 0 and off ≥ NeedTime) ? min(((off − NeedTime) / IntervalTime + 1) × AddBuffTime × 1000, BuffMaxTime × 1000) : 0
        e = asl_Abstate_IsSet(p.abstates, STA_RESTEXP); if !e: return false
        ms = e.aeo_GetRestTime() + add
    if ms != 0:
        ms = min(ms, BuffMaxTime × 1000)
        row = dic_abstate.as_FromIndex(STA_RESTEXP)
        if row and p.vt[0x638](p, row.index, strength 1, row, now_tick, 0, −1, keep = ms, 0, 0):        # set / replace the state
            so_AbnormalState_BitSet(p, row.index)
            if row.subabstate[1].assa_info: p.vt[0x3f0](row.index, assa_info.KeepTime, 1);
                                             so_AbnormalState_BroadcastSet(p, row.index, assa_info.KeepTime, 1)
    return true
```

With the 2016 values: after 6 h offline a fresh buff lasts 10 min, plus 10 min per further full hour, at most 2 h; an
existing buff is extended by (full hours past 6 h + 1) × 10 min. `so_AbnormalState_Inform` (vt 0x3f0) and the broadcast carry the row's `KeepTime`, not `ms`
(original bug) Z12-B8. The exp bonus itself is the abstate's `SubAbnormalStateActorExpUpRate` (Z03 §8.2), not
`RestExpRate`.

---

## 6. Login data parsing (WM → zone character blobs)

At a map login (first login or map change) the WM streams the character's cached blobs to the zone, each as its own
packet `{ NETPACKETZONEHEADER ref (u16 clienthandle, u32 charNo), body }` (W01 §6.3 table, §7.2 order), ending with
`0x101D NC_CHAR_ZONE_CHARDATA_ACK`. The zone-side wrappers (player lookup by `ref`, "Invalid player" →
`so_Disconnect(0x689)`) are Z07 §1.2; each passes `body = payload + 6` to one `ShinePlayer` method. This section is those
methods: the body layout (2016 server PDB struct; the 2017 client PDB has the same sizes), the members they fill and the
copy most of them forward to the client. All client copies go through `so_GetDataSocketStream` (vt 0x2f8) `→ vt 0xc`
(send to this player), built in the global packet buffer `gpp` (opcode at +0, body at +2; `pp_SetPacketLen` takes the
length including the opcode, "Packet Too Long" asserts and drops).

### 6.1 Summary

| WM → Z | Body (pdb2016) | Method (vt) @ | Members filled | Client copy |
|---|---|---|---|---|
| 0x101F BASE | `PROTO_NC_CHAR_BASE_CMD` 0x69 | `so_charbasedata` (0x674) @ FUN_0044d890 | `sp_CharData.toclient.basedata` (p+0x7f3d, Z07 §1.1), position | 0x1038 NC_CHAR_CLIENT_BASE_CMD |
| 0x1020 SHAPE | `PROTO_AVATAR_SHAPE_INFO` 4 | `so_charsharpdata` (0x678) @ FUN_0044ae80 | `sp_CharData.toclient.shape` (p+0x7fa6) | 0x1039 NC_CHAR_CLIENT_SHAPE_CMD |
| 0x1021 QUEST_DOING | `PROTO_NC_CHAR_QUEST_DOING_CMD` | `so_StoreQuestDoing` (0x67c) @ FUN_0044b3c0 | `sp_QuestDiary` (`CQuest`, p+0x173e8) | 0x103A NC_CHAR_CLIENT_QUEST_DOING_CMD |
| 0x1022 QUEST_DONE | `PROTO_NC_CHAR_QUEST_DONE_CMD` | `so_StoreQuestDone` (0x680) @ FUN_0044b500 | `sp_QuestDiary` | 0x103B NC_CHAR_CLIENT_QUEST_DONE_CMD |
| 0x10CD QUEST_READ | `PROTO_NC_CHAR_QUEST_READ_CMD` | `so_StoreQuestRead` (0x684) @ FUN_0044b640 | `sp_QuestDiary` | 0x10CE NC_CHAR_CLIENT_QUEST_READ_CMD |
| 0x10D6 QUEST_REPEAT | `PROTO_NC_CHAR_QUEST_REPEAT_CMD` | `so_StoreQuestRepeat` (0x688) @ FUN_0044b770 (profiler string says `so_StoreQuestRead`) | `sp_QuestDiary` | 0x10D7 NC_CHAR_CLIENT_QUEST_REPEAT_CMD |
| 0x1023 ABSTATE | `PROTO_NC_CHAR_ABSTATE_CMD` | `so_CharAbstateData` (0x68c) @ FUN_0044e0e0 | `smo_Abstate.abstatelist` (p+0x1cc), abstate bits | none (0x103C is never sent) |
| 0x1024 SKILL | `PROTO_NC_CHAR_SKILL_CMD` (chunked) | `so_charskilldata` (0x690) @ FUN_0044bf20 | `smo_CharClass` (p+0xfbc), `sp_SkillList` (p+0x17d0c) | 0x103D NC_CHAR_CLIENT_SKILL_CMD (after the last chunk) |
| 0x1025 PASSIVE | `PROTO_NC_CHAR_SKILL_PASSIVE_CMD` | `so_charpassivedata` (0x698) @ FUN_0044e5a0 | `sp_Passive` (p+0x17d30) | 0x103E NC_CHAR_CLIENT_PASSIVE_CMD |
| 0x1029 GUILD | `u32 guildNo` | `so_ply_SetMyGuildNo` (0x81c) @ FUN_0055a1f0 | `m_nMyGuildNo` (p+0x2a31c) | none |
| 0x1098 GUILD_ACADEMY | `u32 academyNo` | `so_ply_SetMyGuildAcademyNo` (0x860) @ FUN_0055a530 | `m_nMyGuildAcademyNo` (p+0x2a328) | none |
| 0x102E ITEM (×6) | `PROTO_NC_CHAR_ITEM_CMD` | `so_StoreInventoryFromServer` (0x69c) @ FUN_0044ddf0 | `sp_Item.itembag` (p+0x7fd8) boxes | 0x1047 NC_CHAR_CLIENT_ITEM_CMD |
| 0x102F CHESTINFO | `PROTO_NC_CHAR_CHESTINFO_CMD` | `so_ply_Getchestinform` (0x6c4) @ FUN_0044c8a0 | `sp_ChestItemBox` (p+0x29326) | none |
| 0x1030 GAME | `PROTO_GAMEDATA_CMD` 5 | `so_Storegamedata` (0x6a0) @ FUN_0044c220 | `sp_GameData` (p+0x7fb8) | 0x1048 NC_CHAR_CLIENT_GAME_CMD |
| 0x1032 CHARGEDBUFF | `PROTO_NC_CHAR_CHARGEDBUFF_CMD` | `so_CharChargedBuffData` (0x694) @ FUN_0044e1e0 | `sp_ChargedItem.ci_List` (p+0x2a330) | 0x104A NC_CHAR_CLIENT_CHARGEDBUFF_CMD |
| 0x101D CHARDATA_ACK | `u16 wldmanhandle` | Z07 §1.4 → `so_StoreCharData` (0x4b4) @ FUN_0055ab60 | `sp_CharBriefInfo`, `sp_MiscFlag.DataRecieve` | (0x1802 login ACK, Z07 §1.4) |

The other blobs of W01 §6.3 have their own owners: 0x1031 title (Z07 §1.3), 0x10D3 single option and 0x10B8 link-from
(part 4 of this item, Z07 §1.2), 0x10D0 item cool-times (Z07 §1.2), card collection, chat colour, minimon, tutorial, coin,
repurchase list, mover link data (Z07 §1.2 table). **0x1026 (house), 0x1028 ("maspup"), 0x102A (emblem), 0x102B (pet),
0x102C (arena), 0x102D (sea war) have no handler in the 2016 zone** (no `pft_Store` for dept 4 cmd 38, 40, 42–45 in
`handlers.json`): a WM that sends them has them dropped by the parser.

Order dependencies: `so_charskilldata` takes the class from `shape` (0x1020 must come first, which the WM order
guarantees); the stat matrix is built only in `0x101D` (`so_allparametercalculate`, §1.4) and after 0x1032 (Z07 §1.2),
so the blobs themselves never recalculate. `CharClass` (`smo_CharClass`, used by every class slot of §3.1) is first set by
`so_charskilldata` (§6.5), so the skill blob's `so_ply_TotalSkillEmpower` already reads the right class; it is set again
from `shape.chrclass` by every `so_allparametercalculate` (§1.4) and by `so_ply_ClassChange` (FUN_004521b0, class change).

### 6.2 Base and shape

```pseudo
so_charbasedata(p, b: PROTO_NC_CHAR_BASE_CMD)                                     @ FUN_0044d890
    # b { u32 chrregnum, Name5 charid, u8 slotno @0x18, u8 Level @0x19, u64 Experience @0x1a, u16 CurPwrStone @0x22,
    #     u16 CurGrdStone @0x24, u16 CurHPStone @0x26, u16 CurSPStone @0x28, u32 CurHP @0x2a, u32 CurSP @0x2e,
    #     u32 CurLP @0x32, u32 fame @0x36, u64 Cen @0x3a, LoginLocation logininfo @0x42 { Name3 currentmap,
    #     SHINE_COORD_TYPE currentcoord { u32 x, u32 y, u8 dir } }, CHARSTATDISTSTR statdistribute @0x57 (6 bytes),
    #     u8 pkyellowtime @0x5d, u32 pkcount @0x5e, u16 prisonmin @0x62, u8 adminlevel @0x64, flags @0x65 (4 bytes) }
    if p.sp_CharData.basedata.chrregnum != b.chrregnum:
        log to "RegistNumberLog" (file opened on first use): new name, old name, old and new charNo      # no reject
    p.sp_CharData.toclient.basedata = b                                   # whole 0x69 bytes
    if basedata.Level >= 151:  so_Disconnect(0x689, 0, 0); return        # 151 = size of the level tables (§5.1)
    *p.so_LocateInfo.location = (currentcoord.x, currentcoord.y)          # object position (p+0x66 points at it)
    copy = b;  f = fieldlist search by fm_MapID == b.logininfo.currentmap (FieldMap::fm_Compare)
    if f == null: assert "so_charbasedata : Map not fount"; return        # nothing sent (the login then stalls, inferred)
    copy.logininfo.currentmap = f.fm_FieldOption.mapidclient              # the client's map id (instance maps, Field.txt)
    p ← 0x1038 NC_CHAR_CLIENT_BASE_CMD { PROTO_NC_CHAR_BASE_CMD copy }     # 0x69 bytes

so_charsharpdata(p, s: PROTO_AVATAR_SHAPE_INFO)                                   @ FUN_0044ae80
    # s { u8 race:2, chrclass:5, gender:1; u8 hairtype; u8 haircolor; u8 faceshape }
    p.sp_CharData.toclient.shape = s
    p ← 0x1039 NC_CHAR_CLIENT_SHAPE_CMD { s }                              # 4 bytes
```

Client: `0x1038` → character object (FUN_006631f0; in the zone-login scene also copies the name to DAT_00b1b3d0),
`0x1039` → class = `(b0 >> 2) & 0x1f` (FUN_006614c0; zone login writes `UserInfo.txt`) (C01).

### 6.3 Quests

All four go through the shared quest library into one array: `CQuest` (= `sp_QuestDiary.sqd_QuestDiary`, a `CQuestZone`,
Z08 §3) `{ m_NumOfQuest +8, m_NumOfQuestBF +0xc (capacity), PLAYER_QUEST_INFO* m_pQuestArray +0x10, m_ProcessedTime +0x14 }`.
`PLAYER_QUEST_INFO` (0x20) = `{ u16 ID, u8 Status (PLAYER_QUEST_STATUS), PLAYER_QUEST_DATA Data (0x1d) { i64 StartTime,
i64 EndTime @+8, u32 RepeatCount @+0x10, u8 ProgressStep @+0x14, u8 End_NPCMobCount[5] @+0x15, u8 End_Location:1 /
End_Scenario:1 @+0x1a, u16 End_RunningTimeSec @+0x1b } }`. Each `Recv_*` upserts one record per entry: the first record
with the same `ID` is overwritten, else it is appended while `m_NumOfQuest < m_NumOfQuestBF` (a full array silently drops
the entry; the function then returns 0, which no caller reads).

```pseudo
so_StoreQuestDoing(p, b { u32 chrregnum, u8 bNeedClear @4, u8 nNumOfDoingQuest @5, PLAYER_QUEST_INFO[n] @6 })   @ FUN_0044b3c0
    CQuest::Recv_NC_CHAR_QUEST_DOING_CMD_ACK                                       @ FUN_0062f6e0
        if bNeedClear: m_NumOfQuest = 0; m_ProcessedTime = _time32()          # first chunk empties the whole array
        upsert each 32-byte record as is
    p ← 0x103A NC_CHAR_CLIENT_QUEST_DOING_CMD { u32 chrregnum, u8 bNeedClear, u8 n, PLAYER_QUEST_INFO[n] }   # 6 + 32n

so_StoreQuestDone(p, b { u32 chrregnum, u16 nTotalDoneQuest @4, u16 nTotalDoneQuestSize @6, u16 nDoneQuestCount @8,
                         u16 nIndex @0xa, PLAYER_QUEST_DONE_INFO[n] @0xc { u16 ID, i64 tEndTime } })   @ FUN_0044b500
    CQuest::Recv_NC_CHAR_QUEST_DONE_CMD_ACK                                        @ FUN_0062f7c0
        per entry upsert { ID, Status = PQS_DONE (2), Data.EndTime = tEndTime }
        # built in a stack record: only ID, Status, the first StartTime byte (0) and EndTime are written; the other
        # 21 bytes (StartTime bytes 1-7, RepeatCount, ProgressStep, counters, flags) are uninitialised stack (original bug) Z12-B10
    p ← 0x103B NC_CHAR_CLIENT_QUEST_DONE_CMD { the 12-byte header as received, PLAYER_QUEST_DONE_INFO[n] }   # 0xc + 10n

so_StoreQuestRead(p, b { u32 chrregnum, u16 nNumOfReadQuest @4, u16 QuestReadIDArray[n] @6 })   @ FUN_0044b640
    CQuest::Recv_NC_CHAR_QUEST_READ_CMD_ACK                                        @ FUN_0062f890
        per ID upsert { ID, Status = PQS_READ_ABLE (20), Data byte 0 = 0, rest uninitialised (same as B10) }
    p ← 0x10CE NC_CHAR_CLIENT_QUEST_READ_CMD { u32 chrregnum, u16 n, u16 ID[n] }   # 6 + 2n

so_StoreQuestRepeat(p, b { u32 chrregnum, u16 nNumOfRepeatQuest @4, PLAYER_QUEST_INFO[n] @6 })   @ FUN_0044b770
    CQuest::Recv_NC_CHAR_QUEST_REPEAT_CMD_ACK                                      @ FUN_0062f960
        upsert each 32-byte record as is (Status as stored by the DB, normally PQS_REPEAT 4, inferred)
    p ← 0x10D7 NC_CHAR_CLIENT_QUEST_REPEAT_CMD { u32 chrregnum, u16 n, PLAYER_QUEST_INFO[n] }   # 6 + 32n
```

The client copies are byte-identical forwards of the bodies; only the chunked DONE list (W01 §6.3: ≤ 8000 bytes per
chunk) can arrive several times. Client: `0x103A` `{u8 reset @4, u8 n @5, 32-byte records @6}` (FUN_00727fd0),
`0x103B` `{u16 n @8, 10-byte records @0xc}` (FUN_007280b0), `0x10CE` `{u16 n @4, u16[n] @6}` (FUN_007281b0), `0x10D7`
`{u16 n @4, 32-byte records @6}` (FUN_00728280) (C01) — the same offsets.

### 6.4 Abnormal states

```pseudo
so_CharAbstateData(p, b { u32 chrregnum, u16 number @4, ABSTATEREADBLOCK[number] @6 })   @ FUN_0044e0e0
    if number >= 792 (0x318): assert "Too many ABState"; return
    empty the list smo_Abstate.abstatelist.+0xcb0 (p+0xe7c)
    AbstateListInObject::asl_Store(&p.smo_Abstate (p+0x1cc), p, b)                @ FUN_0040afd0
        p.so_Getabstatebit() (vt 0x4a0) = so_emptyabstate               # 99-byte ABNORMAL_STATE_BIT cleared
        empty so_mobile_AbstateList() (vt 0x52c) +0xcb0 again
        for each r: ABSTATEREADBLOCK (0x24) { u16 abstateid, u8 strength @2, u32 pasttime @3 (ms), u32 resttime @7 (ms),
                    u16 restcount @0xb, SKILL_EMPOWER empower @0xd, CasterInfo { u8 nLevel @0xf, i32 nAttackPower @0x10 },
                    { u16 Index, u16 Value } setitem[4] @0x14 }:
            start = max(0, now − pasttime × 10 / 1000)                  # clockwatch ticks of 0.1 s (Z09 knowledge)
            e = dic_abstate[abstateid] (AbStateStr); id > as_maxhandle or no row: assert "No dic"; next
            node = abstatetemplate.asl_AbstateList[e.index.AbStataIndex]; null: assert "invalid abstate"
            party = node.asn_Abstate.vt[0xc]()     # true only for AbnormalStatePartyEnchant, …CouplePartyEnchant,
                                                   # …GuildAcademyMasterEnchant (all other element classes return 0)
            if resttime == 0:  p.so_AbnormalState_Set(party ? p : null, AbStataIndex, strength, e, start, 0, restcount, 0, 0, 0)
            else:              p.so_AbnormalState_Set(party ? p : null, AbStataIndex, strength, e, now, 0, restcount, resttime …)
                               # vt 0x638 @ FUN_004162d0 (Z03 §6.2; Z11 §3.1 uses the same order, keep = 8th); the decompile shows
                               # no 9th/10th argument on this call (uncertain). The set is refused while so_GetHP() == 0
            el = asl_Abstate_IsSet(list, AbStataIndex); null: assert "Null abstate" (e.g. dead at login)
            else: el.aeo_SetItemEffect = r.setitem[0..3] (siae_SetItemEffectRestore @ FUN_005102b0: eb_Index = Index,
                      Argument_Base1000 = Value); el.aeo_Caster.nLevel = r.CasterInfo.nLevel; .nAttackPower = r.nAttackPower
            if not party: set bit AbStataIndex in so_Getabstatebit()
            # empower (r+0xd) is not read
```

Nothing is sent to the client here; the client learns the states through the brief info (`abstatebit`, built after
0x101D) and the abstate informs of Z03 §6. The client handler for `0x103C` (FUN_00661d60, `{u16 n @4, 36-byte records @6}`,
C01) is never fed by the 2016 zone (no write of opcode 0x103C in the zone binary).

### 6.5 Skills

`CharaterSkillList` (p+0x17d0c) = `{ vector<CharSkill> csl_Skill, int csl_SkillNumber +0x10, vector<CharacterToggleSkill>
csl_ToggleSkill +0x14 }`; `CharSkill` (0x14) = `{ u16 cs_SkillId, u32 cs_EndOfCooltime @4 (tick), SKILL_EMPOWER cs_Empower @8
{damage:4, sp:4, keeptime:4, cooltime:4}, u32 cs_Mastery @0xc, int cs_bSave @0x10 }`.

```pseudo
so_charskilldata(p, b { u32 chrregnum, PARTMARK PartMark @4 {bIsStart:1, bIsEnd:1, nOrder:6}, u16 nMaxNum @5,
                        u16 number @7, PROTO_SKILLREADBLOCK[number] @9 })   @ FUN_0044bf20
    # PROTO_SKILLREADBLOCK (0x10) { i32 savetime (time32 of the save), PROTO_SKILLREADBLOCKCLIENT skilldata @4
    #     { u16 skillid, u32 cooltime @2 (remaining s at savetime), u16 empow @6, u32 mastery @8 } }
    p.smo_CharClass = charclassmanager.ccm_array[shape.chrclass] (chrclass < 64, else &charclassmanager)   # §3.1
    p.so_GetCharRegistNumber()                                            # result unused
    CharaterSkillList::csl_Store(&p.sp_SkillList, b)                               @ FUN_00449360
        if number >= 3000: assert "Too many skills"; return
        if csl_SkillNumber == 0: csl_Skill.resize(nMaxNum); csl_ToggleSkill.clear()   # first chunk
        for each r: s = csl_Skill[csl_SkillNumber]                        # no bound check against nMaxNum (original bug) Z12-B11
            s.cs_SkillId = r.skillid; s.cs_Empower = r.empow (4 nibbles); s.cs_Mastery = r.mastery
            s.cs_bSave = (r.cooltime != 0)
            rest = max(0, r.cooltime − (int)difftime(now, r.savetime));  s.cs_EndOfCooltime = now_tick + rest × 10
            csl_Toggle_Store(r.skillid)                                            @ FUN_00448c60
                row = skilldatabox[skillid] (null: assert "INVALID Skill Data"); if row.sdi_ToggleData not empty:
                    csl_ToggleSkill.push({ skillid, bSkillOn = toggle state of row.sdi_PrevSkill's skill if listed, else 0 })
            csl_SkillNumber++
        if csl_SkillNumber == nMaxNum:                                    # last chunk
            csl_CheckDefSkill()                                                    @ FUN_00447fb0
                # appends every `defskill` id missing from the list (cs_EndOfCooltime = now, rest 0); `defskill`
                # (DefSkillData @ 0x0af0d288, 32 × {u16 skill, u8 exist, u8 only2mage}, dsd_Max) is never written in the
                # 2016 zone (only the atexit initialiser), so dsd_Max = 0 and this is a no-op (dead code)
            sort csl_Skill by CharSkill::cs_Compare_STLVer
    if csl_SkillNumber != nMaxNum: return                                 # wait for the next chunk
    hdr = gpp+2:  hdr.restempow (u8 @0) = so_ply_TotalSkillEmpower() (vt 0x6b8 @ FUN_00559fd0: PrimaryParameter[level].+0x7c
                  of smo_CharClass, level ≥ 151 → row 0) − csl_EmpowerSummary()   (negative: assert "Too many empow", 0)
                  hdr.PartMark (u8 @1) = bIsStart; hdr.nMaxNum (u16 @2) = csl_SkillNumber; hdr.skill.chrregnum (u32 @4)
    i = 0
    loop:
        i = csl_FillSendBuffer_Client(&hdr.skill, i, &hdr.nMaxNum)                 @ FUN_00445460
            # from list index i: at most 500 records per packet; skips (and decrements hdr.nMaxNum for) the item-use
            # pseudo-skills 29200–29205 (UseSilverWings, UseStageRecallScroll, UseSkill, UsePotion, UsePresentBox,
            # UseScroll), 29428 MineStun_W, 29429 UseMineNormalScroll, 29535/29536 M_WarH_* (ActiveSkill.shn)
            # record PROTO_SKILLREADBLOCKCLIENT { skillid, cooltime = remaining (cs_EndOfCooltime − now)/10 s
            #   (> 10800 s: assert "Too long cooltime", still sent), empow, mastery }; returns the next list index
        if i < 1: break
        if i >= hdr.nMaxNum: PartMark.bIsEnd = 1                         # list index vs visible count (original bug) Z12-B9
        p ← 0x103D NC_CHAR_CLIENT_SKILL_CMD { u8 restempow, PARTMARK, u16 nMaxNum, u32 chrregnum, u16 number,
                                             PROTO_SKILLREADBLOCKCLIENT[number] }   # 12 + 12·number
        PartMark: bIsStart = 0, nOrder += 1
        while i < hdr.nMaxNum
```

Client `Skill::InitSkill` (FUN_006a0690): `bIsStart` → `ClearLearnSkill`; stores `nMaxNum` and `restempow`; learns each
record (id @+10, empower nibbles @+16/17, mastery @+18 of the payload) and, if `cooltime ≠ 0`, records the skill as used
`(EmpowerAppliedCoolTime − cooltime·k)` ago (cool-down continues); then refreshes all skill icons. It never reads
`bIsEnd`/`nOrder`.

### 6.6 Passives

```pseudo
so_charpassivedata(p, b { u16 number, u16 passive[number] @2 })                @ FUN_0044e5a0
    sp_Passive.cpl_Passive.bs_clear(); sp_Passive.cpl_SetAbstateList.clear()
    CharacterPassiveList::cpl_Store(&p.sp_Passive, b, so_CharName())                @ FUN_00447aa0
        for each id: id >= 1000: assert "Invalid passive"; next
                     set bit id in cpl_Passive (if < bs_maxbit)
                     cpl_StoreSetAbstateList(id)                                    @ FUN_00447340
                         s = passivedatabox.sdb_GetSetAbstate(id); if s: if s.pssabs_Prev (lower step) is listed, remove it;
                         append s                                     # passive-granted abstates, read by §2.4
    p ← 0x103E NC_CHAR_CLIENT_PASSIVE_CMD { u16 number, u16 passive[number] }   # as received, invalid ids included
```

Client FUN_0069f430: `{u16 n, u16 id[n]}`, at most 3001 (C01).

### 6.7 Inventory

```pseudo
so_StoreInventoryFromServer(p, b: PROTO_NC_CHAR_ITEM_CMD)                        @ FUN_0044ddf0
    # b { u8 PacketOrder { nPacketOrderNum:7, nIsLastOfInven:1 }, u8 nPartMark @1, PROTO_ITEM_CMD ItemCmd @2
    #     { u8 numofitem, PROTO_ITEMPACKET_TOTAL[ ] @3 { u8 datasize, ITEM_INVEN location { Pos:10, Type:6 }, item data } } }
    box = nPartMark & 4    → 9  ci_Inventory   ItemBag::ib_Initializetotal              @ FUN_00643a00
          else & 8         → 8  ci_Equipment   ib_Initializetotal
          else & 0x10      → 12 ci_MiniHouse   ib_Initializetotal
          else & 0x20      → 15 ci_ActionBox   ItemSmallBag::isb_Initializetotal          @ FUN_0044d5d0
          none             → no store; `box` keeps the low byte of the body pointer (original bug) Z12-B12
        # both initialisers, per record: skip it unless location.Type == box; Pos ≥ bag size: assert "Invalid slot";
        # else iti_fill2struct_whole (default attribute class, item data) into the cell at Pos, and set the cell's
        # attribute class from itmattcontainer[itemid] (isb_: ItemInform_ActionItem::sii_Import). Next record at
        # +1+datasize. Cells not in the packet are not cleared (the bags start empty at object creation).
    for every item of ci_Inventory: item.attrclass.vt[0x44](item)     # only ItemAttrCls_ItemChest overrides it
                                                                     # (iac_Getitemchest @ FUN_0063e410 returns a pointer,
                                                                     # discarded): no effect
    if not PacketOrder.nIsLastOfInven: return                         # inventory arrives in several chunks (W01 §6.3)
    hdr = gpp+2: { u8 numofitem, u8 box @1, u8 flag @2 (bit 0 invenclear), PROTO_ITEMPACKET_INFORM[ ] @3 }
    if box == 15:
        size = isb_FullBufferItem2Client(ActionBox, &numofitem, records, 15)          @ FUN_0044d6d0
            # every non-empty cell (iic_ItemIdent ≠ 0xFFFF): sii_Export, location = (15 << 10) | slot, iti_fill2buffer_union
            # with the cell's attribute class, datasize = 2 + item bytes; stops after ≥ 8000 bytes
        numofitem ≠ ItemCmd.numofitem: assert "ItemNumber not match" (still sent)
        flag bit 0 = 1;  p ← 0x1047 { hdr, records }                  # one packet
    else:
        sent = 0; first = 1
        while (size = CharacterInventory::ci_FillBufferInventoryItem(&itembag, &numofitem, records, box, &sent, 8000, null)) > 0:
                                                                                      @ FUN_00643d40
            # bag = charinvenman.cim_Array[box] (box < 17); skip `sent` non-empty cells, then write each further
            # non-empty cell { datasize, location = (box << 10) | slot, iti_fill2buffer_union(item) } until ≥ 8000 bytes;
            # an item id missing from ItemInfo stops the packet (return 0; its "Invalid ItemID found" assert is dead)
            flag bit 0 = first;  p ← 0x1047 { hdr, records }          # size + 5 bytes with the opcode
            first = 0
        # an empty box sends nothing (the client keeps whatever it had); flag bits 1–7 are left from earlier gpp use
```

Client `0x1047`: item manager load (FUN_00666eb0 on DAT_00a8d120), `invenclear` empties the box first, then the shortcut bar
is refreshed (C01). `PROTO_NC_CHAR_CLIENT_ITEM_CMD.flag` has only `invenclear` (pdb2016), so the stale upper bits are
unused.

### 6.8 Chest locations, game data, charged buffs

```pseudo
so_ply_Getchestinform(p, b { u16 itemnum, u16 location[itemnum] @2 })          @ FUN_0044c8a0
    sp_ChestItemBox.bs_clear()            # TreasureChestLocationManager = BitSet (p+0x29326; maxbit at +4)
    for each loc: loc < bs_maxbit: set bit loc; else assert "Too large location"
    # the occupied "inside a treasure chest" cells (Z09 §10.10: chest contents live at inven 0x2800 + n; tcm_PutInto
    # allocates from this set, inferred); the reverse is so_SaveChestInfo @ FUN_004547a0 (u16 n, u16 loc[n],
    # stops at 3995 entries), the body of the dept-16 chest save 0x4014 that the WM caches (W05 table, inferred). No client copy.

so_Storegamedata(p, b: PROTO_GAMEDATA_CMD { ZoneServer zone { u8 bIsGM }, Client client @1 { u16 partyno, u16 nRaidNo } })   @ FUN_0044c220
    p.sp_GameData = b (5 bytes)
    p.sp_GameData.client.partyno = partymanufacture.pm_FindParty(charNo)   # the zone's own party table wins
    p ← 0x1048 NC_CHAR_CLIENT_GAME_CMD { u16 partyno, u16 nRaidNo }        # 4 bytes; the client ignores it (C01)

so_CharChargedBuffData(p, b { u16 NumOfChargedBuff, PROTO_CHARGEDBUFF_INFO[n] @2 })   @ FUN_0044e1e0
    # PROTO_CHARGEDBUFF_INFO (0xe) { u32 ChargedBuffKey, u16 ChargedBuffID @4, ShineDateTime UseTime @6, ShineDateTime EndTime @0xa }
    # ShineDateTime (u32) { year:8 (since 2000, inferred), month:5, date:6, hour:6, minute:7 }
    empty sp_ChargedItem.ci_List; ci_bRecalcParam = 0
    for each r (out = record slot i of the client copy):
        eff = chargedbuffdatabox.cideb_FindFromHandle(ChargedBuffID)              @ FUN_00450390
        eff == null: log to ChargedItemLog; the slot is skipped but still counted (original bug) Z12-B13
        el = ci_List.vt[8](ChargedBuffKey)                                  # new element for this key
        el == null: log; return                                            # no client copy at all
        ChargedItemEffectElement::ciee_SetEndTime(el, eff, EndTime fields)          @ FUN_004504d0
            # ciee_Index = eff; ciee_Year/Month/Date/Hour/Minute = EndTime (UseTime is not stored)
        out = r (14 bytes)
    p ← 0x104A NC_CHAR_CLIENT_CHARGEDBUFF_CMD { u16 NumOfChargedBuff, PROTO_CHARGEDBUFF_INFO[NumOfChargedBuff] }
    # the wrapper (0x1032, Z07 §1.2) then runs so_allparametercalculate: the buffs' stat effects (§2.5 / Z07 §4)
```

Client `0x104A`: `{u16 n, n × 14-byte records @2}`, FUN_006d2540 per record (C01).

### 6.9 End of data: `so_StoreCharData` (vt 0x4b4) and `sp_LoginInit`

```pseudo
so_StoreCharData(p, handle, tag)                                               @ FUN_0055ab60
    # called by 0x101D (Z07 §1.4) with handle = its ref.clienthandle (the player's zone handle) and tag = the
    # handler's name string, before the map marking and so_allparametercalculate
    if p.so_Field and p.so_Field.fm_FieldOption and fm_FieldOption.NameHide (FieldAttr +0x6a): return    # see below
    title = so_GetCharacterTitle() (vt 0x420) +0x488 (CHARTITLE_BRIEFINFO { u8 Type, u8 ElementNo, u16 MobID })
    BriefInformationCharacter::bic_InitBriefInfo(&p.sp_CharBriefInfo, handle, smo_GetMode(), &p.sp_CharData, &title, tag)
                                                                                   @ FUN_0055a9b0
        if mode in {0, 1, 2}:   # the cached PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD (0xeb, bic_BriefInfo)
            coord = basedata.logininfo.currentcoord; charid = basedata.charid; shape; chrclass = shape.chrclass
            emoticon = { id 0xFF, frame 0 }; chartitle = title; polymorph = 0xFFFF; handle = handle
    sp_BriefEquipmentSetting()                                                     @ FUN_00576010
        mode 0–3: so_briefequipset (vt 0x5c8 @ FUN_0054df70); 4, 5: so_BriefEquipSetBackup; 6: so_BriefEquipSetRiding
    sp_MiscFlag.DataRecieve = 1
```

At the first login `so_Field` is not yet set (the map marking follows in 0x101D), so the `NameHide` test can only
matter for a re-login on a live object *(inferred)*; on such a map the brief info would keep its old content. `tag`
is not read.

```pseudo
ShinePlayer::sp_LoginInit(p)                                                    @ FUN_00440d80
    # called by sp_NC_MAP_LOGINCOMPLETE_CMD (FUN_00443390, Z01) and sp_ReviveNow (FUN_0057d290, the revive path of Z07 §3.1 / Z11)
    sp_LastBoothSlotSend = 0xFF; so_ply_SendBoothSize() (vt 0x3e0)
    sp_TimerStr = { ts_Limit 0, ts_CallFunc / ts_TimerFunc = no-op stubs, ts_CurWork TSCW_NONE }
    sp_DuringItemEquip = 0; so_InitAIScript() (vt 0xc14); sp_RideInitialize()
    smo_DeadCheck (p+0x180) = 0; pmi_Clear(sp_LastPartyParam); smo_Flag.DeadProcessComplete = smo_Flag.InSkillShift = 0
    sp_NormalLogoutTick = 0xFFFFFFFF; empty sp_MobHuntLog
    sp_LastStat.last = parameter_eraser_plus      # all zero: the next notify (§4.2) reports every stat as changed
```

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z12-B1 | `Parameter::Cluster::operator*=` @ FUN_004c9160 | the `CriDam` line appears twice; `MACri`, `MagCriDam` once | a CriDam rate ≠ 1000 in ItemPowerRate/AbnormalState/PassiveSkill/LastTune.Rate is applied squared | multiply once (the second line was probably meant for another member) |
| Z12-B2 | `cpl_RecalcParam` @ FUN_00445940 | the special fields (`PassiveHealRate`, `PassiveBuffKeepTimeUPRate`, `PassiveCriDamageRatePlus`, `DMGMinusRate`, the seven `ChangeByConditionParam`s) are assigned but never reset by the recalculation | after a passive is removed (unlearn, class change) its special effect stays until the next map login | reset them in `so_RecalcPassiveParam` like the clusters |
| Z12-B3 | `siae_ParameterRefit` @ FUN_005108c0, code 1008 | `MaxSP = arg × newMaxHP / 1000` | the set-item HP/SP-max modifier replaces the state's MaxSP bonus by one derived from its MaxHP bonus | `MaxSP = arg × MaxSP / 1000` (as in pass 1, code 14) |
| Z12-B4 | `sp_MaxSP` @ FUN_0055a8b0 | the polymorph branch (`ChangeAbilityInfo` set) writes `MobInfo.MaxHP` into the MaxHP cache `p+0xea8` and returns the player's MaxSP | a polymorphed player keeps its own MaxSP; the HP cache is overwritten (harmless, `sp_MaxHP` writes the same value) | `p+0xeac = MobInfo.MaxSP` |
| Z12-B5 | `RulesOfEngagement::roe_MinMA` @ FUN_004fd640 | reads the weapon-title cell `L8.MAmax` (P+0x68c) | the weapon title's `MaxAdd` scales the **minimum** magic attack (displayed and in combat) | `L8.MAmin` (P+0x688), as `roe_MinWC` reads `L8.WCmin` |
| Z12-B6 | `NormalPY/NormalMA::roe_FreeStateAttackPower` @ FUN_005003c0 / FUN_00500390 | the physical rule set adds `FreeStatInt.MAAbsolute`, the magical one `FreeStatStr.WCAbsolute` | DoT snapshots (`roe_GetAttackPower`) of physical states grow with spent INT, magical ones with STR | physical STR, magical INT (as `roe_Damage`) |
| Z12-B7 | `NormalPY/NormalMA::roe_FreeStateDefendPower` @ FUN_00500420 / FUN_005003f0 | read the **attacker** (`ctx.att`), and the other kind's stat (PY: Men.MRAbsolute, MA: Con.ACAbsoulte); the only caller (`roe_AttackPowerCalcDamage` from DoT / bomb damage) passes `att = NULL` | the free-stat defence never reduces DoT / bomb damage (always 0) | `ctx.def`, PY Con.ACAbsoulte, MA Men.MRAbsolute |
| Z12-B8 | `RestExpAbstateApplication` @ FUN_0059d510 | `so_AbnormalState_Inform` / `BroadcastSet` get `SubAbState.KeepTime` of the row, not the computed duration | the client shows the rest-exp buff with the table duration, not the real remaining time | pass `ms` |
| Z12-B9 | `so_charskilldata` @ FUN_0044bf20 | the chunk loop compares the next **list index** (hidden skills included) with `nMaxNum`, which `csl_FillSendBuffer_Client` decrements for every hidden skill | with more than 500 skills and hidden ones in the first chunk, `bIsEnd` is set and the loop stops early: the last skills are never sent (practically unreachable: ≤ 10 hidden ids) | count visible records, or compare with `csl_SkillNumber` |
| Z12-B10 | `CQuest::Recv_NC_CHAR_QUEST_DONE_CMD_ACK` / `…READ_CMD_ACK` @ FUN_0062f7c0 / FUN_0062f890 | the 32-byte record is built on the stack with only `ID`, `Status`, the first `StartTime` byte and (DONE) `EndTime` written | the stored done / read records carry stack garbage in `StartTime`, `RepeatCount`, `ProgressStep`, the counters and flags; anything that reads or saves them sees random values | zero the record first |
| Z12-B11 | `CharaterSkillList::csl_Store` @ FUN_00449360 | the vector is sized `nMaxNum` on the first chunk; later records are written at `csl_SkillNumber` without a bound check (only `number < 3000` per chunk) | a WM whose chunks add up to more than `nMaxNum` writes past the vector (heap corruption) and the client list is never sent (`csl_SkillNumber` never equals `nMaxNum`) | check `csl_SkillNumber < nMaxNum` per record |
| Z12-B12 | `so_StoreInventoryFromServer` @ FUN_0044ddf0 | when `nPartMark` has none of the bits 4/8/0x10/0x20, nothing is stored but the box number used for the client copy is the low byte of the body pointer | a malformed last chunk sends a random box (or nothing when the byte is ≥ 17) | return without a client copy |
| Z12-B13 | `so_CharChargedBuffData` @ FUN_0044e1e0 | a buff id missing from `chargedbuffdatabox` is skipped, but its 14-byte slot in the client copy is still counted (`NumOfChargedBuff` unchanged, the output pointer advances) | the client gets a record of stale `gpp` bytes and shows a bogus charged buff | compact the list and send the stored count |

## N. Not reconstructed / uncertain

- §6.4: the `so_AbnormalState_Set` call for states with a remaining time shows only eight arguments in the decompile;
  `how` / `origin` were not checked in the assembly. The `party` test is read from the element classes' vt 0xc bodies.
- §6.8: the meaning of the chest-location numbers (cells inside treasure chests) is inferred from `tcm_PutInto` taking
  `sp_ChestItemBox` (Z11 §8.4 `&kqreward`, Z09 §10.10); `TreasureChestLocationManager` was not read beyond
  its constructor (`BitSet(8)`).
- §6.9: whether `so_Field` can be set when 0x101D arrives (the `NameHide` early return) was not traced through the
  map-change path.
- §6.1: whether the 2016 WM ever sends 0x1026 / 0x1028 / 0x102A–0x102D (unhandled in the zone) depends on the CharDB
  sending their source blobs (W01 §6.3); not checked in captures.
- §4.2: why the notify subtracts `cec_MoreStat` from `sp_LastStat.last` and why `Total.MAmin/MAmax` subtract the flat
  item MA (`Item.Plus.MAmin/MAmax`) while WC does not; the client side (how `CharInfoWin` combines `change` with item
  values) was not traced.
- §4.2 `roe_MR` / `roe_TB` / `roe_MaxWC` were checked only for the cells they read (offset lists), not line by line;
  their formulas are taken as the magical / evasion analogues of `roe_AC` / `roe_TH` / `roe_MinWC` *(inferred)*.
- §3.3: the clockwatch tick unit (100 ms) behind `RecoverTick` is inferred from `ms × 10 / 1000`.
- §5.3: no reader of `sp_NextSaveExp` acts on it; a GameLog or DB path keyed on it was not found (searched by member name).
- `ItemPowerRate.Plus`, `Upgrade.Rate`, `WeaponTitle.Plus`, `LastTune.Plus` have no writer in the 2016 zone (searched by
  member name and `p+` offset); whether a reader exists is checked in the sweep.
- The meaning of `ItemEquipTable.Equ_LeftHand == 2` (two-handed weapon in the right hand) and of `attr.vt[0x9c]` (costume
  charge left) is inferred; Z17 owns the costume charges.
- `SAA_ALLSTATEPLUS` (39) goes into the rate cluster while `SAA_ALLSTATPLUS` (119) is flat; data `SubStaEventAllStatsUp`
  uses 39 with arg 7 (= +0.7 %), which may have been meant as +7 flat.
- The ≥ 1000 `eb_Index` codes in `siae_ParameterRefit` pass 2 do not match the `SetIndex` enum; their source
  (`aeo_SetItemEffectStore`) was not traced.
- `pmv.pmv_var` (passive mastery column table) was read only through its use; its initialiser was not opened.
