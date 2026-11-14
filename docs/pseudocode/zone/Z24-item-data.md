# Zone: item-side data loaders (Z24)

Source: the 2016 zone `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read with the NA2016 PDB
(`clean.py re-data/exports/zone-pdb - <addr>`); names, types and row structs are *(pdb2016)* unless marked.
Data checks are against `Files/Server/2016/9Data/Shine/` (`shn.py`). Evidence markers as in `AGENTS.md`.

This item documents how the item-side tables are built at zone start: the per-item use table `useditemeffect`
(which actor runs an item, with which use-effect row and which "use skill"), and every loader that writes into it,
plus the class helpers of the class-change item. The item handlers that read these tables are Z04 (§6 item use),
Z05 (§9.8 mystery vault), Z07 / Z13 (mounts, mini-house); the start stages are Z10 §7, the loader list Z01 §2.3, the
SHN reader template Z20 §2.1, the text-table parser `OptionReader` Z09 §28.6.

Stage order of the writers (script order of Z10 §7.1: sky, earth, black, yellow, home, house, **wide**, **tough**,
**sun**, moon, **full**, sink, star, **sleep**, open, **long**): the last writer of an item's entry wins.

## 1. The item use table `useditemeffect` (`UseEffect::UsedItemEffect`)

### 1.1 Data structures

Global `UseEffect::UsedItemEffect useditemeffect` @ 0x132878f0 (0xf8 bytes; dynamic initializer FUN_00699070:
`BinaryData` ctor, `bdb_defaultblock` zeroed, `uie_FuncStruct = null`).

| Member | Offset | Type | Meaning |
|---|---|---|---|
| `uie_BinData` | +0x00 | `BinaryDataBox<ItemUseEffect>` (0x98) | the rows of ItemUseEffect.shn (reader buffer, kept for the process) |
| `uie_DefStruct` | +0x98 | `ItemUseEffect` (0x56) | the "no row" use effect every entry starts with: `UseEffectA/B/C = MAX_USEEFFECTTYPE (10)`, `UseAbstateIndex = MAX_ABSTATEINDEX (0x318 = 792)`, name fields zero (static storage) |
| `uie_FuncStruct` | +0xf0 | `UIE_Functions*` | array of `uie_MaxItemID` entries, indexed by item ID (the "g_ItemUseTable" @ 0x132879e0 of Z04 §6.1) |
| `uie_MaxItemID` | +0xf4 | u16 | `itemdatabox.idb_maxItemhandle` (= highest ItemInfo ID + 1; 65505 in 2016) truncated to 16 bits |

`UseEffect::UIE_Functions` (0x10): `ItemUseEffect* useeffectstruct` +0, `UseItemBase* useitemclass` +4 (the actor:
one global object per `UseEffect::UseItem*` class, Z04 §6.3), `SkillDataIndex* useskill` +8 (the "use skill" that
gives the cast time and cooldown, Z04 §6.1; dangles after `&reloaddata ActiveSkill`, Z20 §7), `u8 broadcast` +0xc
(send 0x3029 to the surroundings on use, §1.4).

Note for readers of Z04 / Z02: their "`g_ItemUseFunction` (DAT_132878f0)" is this object (`useditemeffect`); the
`ItemUseFunction itemusefunction` global (0x0d67a1ec) is an empty 1-byte class whose only code is its loader (§2).

### 1.2 ItemUseEffect.shn

Read by `BinaryDataBox<ItemUseEffect>::bdb_ReadData` FUN_00596b20 (the Z20 §2.1 template; key 0x23b = 571, row 0x56;
2016 file: key 571, 240 rows). No per-world override. Row `ItemUseEffect` (0x56):

| Column (shn type:size) | Member | Off | Use |
|---|---|---|---|
| ItemIndex (9:32) | `char ItemIndex[32]` | 0x00 | item InxName (`idb_btree` lookup); fatal if unknown |
| UseEffectA (11:4) | `UseEffectType UseEffectA` | 0x20 | effect kind: 0 HPUP, 1 SPUP, 2 POISONREMOVE, 3 DISEASEREMOVE, 4 ABSTATE, 5 CURSEREMOVE, 6 NONE, 7 HPSPALLUP, 8 DEBUFALLREMOVE, 9 ACTIONITEM (`UseEffectType`) |
| UseValueA (2:2) | `u16 UseValueA` | 0x24 | amount (HP/SP) or abstate strength (kind 4) |
| UseEffectB, UseValueB | same | 0x26, 0x2a | second effect |
| UseEffectC, UseValueC | same | 0x2c, 0x30 | third effect |
| UseAbstateName (9:32) | `char UseAbstateName[32]` | 0x32 | abstate InxName for kind 4, `-` = none |
| UseAbstateIndex (3:4) | `u32 UseAbstateIndex` | 0x52 | 0 in the file; **overwritten at load** with the `ABSTATEINDEX` of `UseAbstateName` (0x318 for `-`) |

The effects themselves are applied by `UseItemByTable::uib_Effect` FUN_00599f10 / `so_ply_ItemEffect` FUN_0059c730
(Z04 §6.3, Z09 heal table).

### 1.3 `uie_Load` (stage wide)

```pseudo
UsedItemEffect::uie_Load(this)                                                 @ FUN_0059cc30
    # needs itemdatabox and dic_abstate (stage home), skillnametree / skilldatabox (wide, sdb_Load runs first)
    this.uie_MaxItemID = (u16) itemdatabox.idb_maxItemhandle
    this.uie_FuncStruct = new UIE_Functions[uie_MaxItemID]       # (u16) truncation: (original bug) Z24-B3
    null: assert "UsedItemEffect::uie_Load : Memory leak"; ShineExit("UseEffect::UsedItemEffect::uie_Load")
    for id in 0 .. uie_MaxItemID-1:
        e[id] = { useeffectstruct = &uie_DefStruct, useitemclass = &ui_base, useskill = null, broadcast = 0 }

    # pass 1: one actor + use skill per ItemInfo row (by class)
    for row in ItemInfo rows (record order, 0 .. idb_Itemspacies-1):
        id = row.ID; ix = itemdatabox[id]           # inline ItemDataBox::operator[]: id < idb_maxItemhandle, index row
                                                    #   present, row.ID == id, else assert "ItemDataBox::operator [] :Invalid
                                                    #   Item index" (id*10000 + found ID) and null
        ix == null: assert "UsedItemEffect::uie_Load : Invalid ItemIndex" (id); ShineExit(same)
        switch ix.data.Class (ItemClassEnum):
            FURNITURE (9):        actor = ui_minihousefurniture; skill name = "UseSkill"
            SKILLSCROLL (11):     actor = ui_skillscroll;        "UseSkill"
            RECALLSCROLL (12):    actor = ui_recallscroll;       "UseStageRecallScroll"
            ITEMCHEST (15):       actor = ui_chestopen;          "UsePresentBox"
            ACTIONITEM (27):      actor = ui_actionitem;         "UseSkill"
            GBCOIN (28):          actor = ui_GBCoin;             "UseSkill"
            CAPSULE (29):         actor = ui_Capsule;            "UseSkill"
            NOEFFECT (33), ACTIVESKILL (35): actor = ui_NoEffect; skill name = ItemInfo.ItemUseSkill unless it is "-"
            PUP (36):             actor = ui_Pet;                skill name = ItemInfo.ItemUseSkill unless "-"
            any other class:      actor stays ui_base;           skill name = ItemInfo.ItemUseSkill unless "-"
        e[id].useitemclass = actor; if a skill name: e[id].useskill = uie_UseSkillID(name)     # "-": stays null
        # the fixed names win over ItemInfo.ItemUseSkill for the seven fixed classes (2016: ItemChest rows 2 × "UseSkill"
        # and Capsule 8 × "UsePresentBox" in ItemInfo, both overridden by the class rule)

    # special items (ItemDataBox::idb_MakeSpecialID inside idb_Load, Z04)
    e[sii_ProposeRing] = { actor ui_Propose, skill uie_UseSkillID("UseSkill") }           # ProposeRing, ID 4300 (2016)
    if sii_ImmediateDivorce == 0xffff: assert "UseEffect::UsedItemEffect::uie_Load : cannot find InstantDivorce item"
        # dead: idb_MakeSpecialID already ShineExits when "InstantDivorce" is missing (original bug) Z24-B1
    else: e[sii_ImmediateDivorce] = { ui_ImmediateDivorce, uie_UseSkillID("UseSkill") }  # InstantDivorce, ID 4309
    uie_DefStruct.UseEffectA = B = C = MAX_USEEFFECTTYPE; uie_DefStruct.UseAbstateIndex = 0x318
    BinaryDataBox<ItemUseEffect>::bdb_ReadData(&uie_BinData, "../9Data/Shine/ItemUseEffect.shn")   @ FUN_00596b20
        # fail: Z20 §2.1 (assert "readfail" + "Code:…SHN:…" + ShineExit)
    e[sii_JustReviveItem] = { ui_JustRevive, uie_UseSkillID("UseSkill") }
        # sii_JustReviveItem = the last ItemInfo row with ItemFunc == ITEMFUNC_JUSTREVIVAL (3) (JustRevival, ID 30168);
        # never initialised otherwise (original bug) Z24-B2

    # pass 2: one entry per ItemUseEffect row
    for r in ItemUseEffect rows:
        id = itemdatabox.idb_btree[r.ItemIndex] (u16; 0xffffffff → 0xffff)       # BTree::operator[] FUN_0063cc30
        id == 0xffff: assert "UseEffect::UsedItemEffect::uie_Load : Invalid item" (r.ItemIndex); ShineExit
        if r.UseAbstateName[0] == '-': r.UseAbstateIndex = 0x318
        else: r.UseAbstateIndex = dic_abstate.as_BTreeIndex[r.UseAbstateName]
              not found (0xffffffff): assert "…uie_Load : AbState wrong" (name); ShineExit
        ix = itemdatabox[id] (inline check as above); null: assert "…uie_Load : Null Item" (id); ShineExit
        e[id].useeffectstruct = &r                                  # pointer into the reader buffer
        if ix.data.Class != ACTIONITEM:                             # action items keep ui_actionitem and "UseSkill"
            e[id].useitemclass = ui_bytable
            e[id].useskill = uie_UseSkillID(ix.data.ItemUseSkill)  # "-" would assert "Not found" and give null
```

Only `r.UseAbstateIndex` is written into the row; the rows stay in `uie_BinData` for the life of the process.

### 1.4 Helpers

```pseudo
UsedItemEffect::uie_UseSkillID(this, name) → SkillDataIndex*                   @ FUN_0059cba0
    v = skillnametree[name]                       # BTree of SkillDataBox (Z20 §5.2): {u16 skill, u8 ispassive}
    v == 0xffffffff: assert "UseEffect::UsedItemEffect::uie_UseSkillID : Not found" (name); return null
    v.ispassive: assert "…uie_UseSkillID : Passive" (name); return null
    s = SkillDataBox::operator[](skilldatabox, v.skill); null: assert "…uie_UseSkillID : Skill" (name)
    return s                                      # no exit on any failure: the item then has no use skill (0x70d on use)

UsedItemEffect::uie_SetChargedBuffer(this, id, actor, skill)                    @ FUN_005963e0
    e[id] = { useeffectstruct = &uie_DefStruct, useitemclass = actor, useskill = skill }   # broadcast kept
    # no bounds check on id; resets the ItemUseEffect row of the item (see §1.5)

UsedItemEffect::uie_BroadCast(this, id, flag)                                   @ FUN_005963c0
    e[id].broadcast = flag                        # no bounds check

UsedItemEffect::operator[](this, id) → UIE_Functions*                           @ FUN_004878e0
    return id < uie_MaxItemID ? &e[id] : &e[0]    # out of range: entry 0 (the entry of item ID 0), not null

ShinePlayer::sp_ItemUseBroadcast(p, entry, itemID)                              @ FUN_0053f840
    if entry.broadcast == 0: return
    broadcast to every player in range of p (so_AllOfRange with allofrangearg, AxialListPacketBroadcast):
        0x3029 NC_ITEM_SOMEONEUSE_CMD { u16 user = p.handle, u32 useloc.x, u32 useloc.y = p's position, u16 useditem = itemID }  (12 bytes)
    # client FUN_004af820 (GameFrameWork::On_NC_ITEM_SOMEONEUSE_CMD, pdb2017): finds the user's object and the item's
    #   ItemInfo row; both present → plays the item-use effect on that character (object vt 0xc4, then FUN_0068fc00 with
    #   the item's name) *(inferred)*; useloc is not read
```

### 1.5 Writers of `uie_FuncStruct`, in stage order

| Stage | Writer | Items | Actor | Use skill | Effect row |
|---|---|---|---|---|---|
| wide | `uie_Load` pass 1 FUN_0059cc30 | every ItemInfo row | by class (§1.3) | by class / ItemUseSkill | `uie_DefStruct` |
| wide | `uie_Load` specials | ProposeRing, InstantDivorce, JustRevive item | ui_Propose, ui_ImmediateDivorce, ui_JustRevive | "UseSkill" | unchanged |
| wide | `uie_Load` pass 2 | ItemUseEffect.shn rows | ui_bytable (action items: unchanged) | ItemUseSkill | the row |
| tough | `ItemUseFunction::iuf_Load` FUN_0049b770 (§2) | ItemUseFunction.txt rows | by `UseFunction` | "UseSkill" / "UseSilverWings" | reset to `uie_DefStruct`; `broadcast` set for every row |
| tough | `MagicContainer::mc_Load` FUN_0049c7f0 (Z09) | TreasureReward.txt boxes | — | — | — |
| tough | `ChargedItemEffectDataBox<ChargedItemEffect / MiniHouse / MiniHouseFurniture>::cideb_Load` (part 3) | | | | |
| sun | `RidePetDataBox::rpdb_Load`, `ChargedItemEffectDataBox<RIDING>::cideb_Load` (part 3) | | | | |
| full | `MysteryVaultTable::DataProcess` FUN_005c8590 (§4) | every MysteryVaultServer.shn box | ui_mysterybolt | "UsePresentBox" | reset |
| sleep | `cStateItemDataBox::sidb_Load` FUN_0058c920 (§3) | every StateItem.shn item | ui_ByAbstate | ItemUseSkill | reset |
| long | `MoverDataBox::mvdb_Load` FUN_004bf960 (part 2) | | | | |

`uie_SetChargedBuffer` replaces the effect row by `uie_DefStruct`, so an item that is both in ItemUseEffect.shn and
in a later table silently loses its use-effect row (no warning). 2016: ItemUseEffect, ItemUseFunction, StateItem and
MysteryVaultServer have no item in common (checked pairwise; the part-2/3 tables are checked there).

### 1.6 Invariants with the 2016 data

- ItemUseEffect.shn: 240 rows, no duplicate ItemIndex (a duplicate would just overwrite the entry: last row wins),
  every ItemIndex in ItemInfo, every UseAbstateName in AbState (777 rows), kind 4 never with `-`. Item classes: 152
  BYTELOT, 75 ACTIONITEM, 13 QUESTITEM. ItemUseSkill of the 240 items: UsePotion 111, UseSkill 75, UseScroll 53,
  UseStageRecallScroll 1. UseEffectA uses kinds 0–5, 8, 9; B only 1, 6, 7; C only 4 (one row) and 6.
- Every `ItemUseSkill` value of ItemInfo other than `-` exists in ActiveSkill.shn and none is a passive, so
  `uie_UseSkillID` never fails with the 2016 data; the fixed names "UseSkill", "UseStageRecallScroll",
  "UsePresentBox", "UseSilverWings", "UseRide", "UseSumPup" exist too.
- Item IDs 0 … 65504, no 0xFFFF (Z24-B3 latent).

## 2. `ItemUseFunction` (World/ItemUseFunction.txt, stage tough)

`ItemUseFunction itemusefunction` @ 0x0d67a1ec has no members; the loader writes straight into `useditemeffect`.
The file is an `OptionReader` text table (Z09 §28.6). 2016 file (cp949, CRLF): `#Ignore \o042` (drops `"`),
`#Exchange # \x20` (a `#` inside a value becomes a space), `#Table ItemUseFunction`, columns, 22 `#Record`s, `#end`.
The Korean comment above the columns says: put any needed cell before UseFunction (so a structure change is noticed
without relying on a checksum); use `-` when (re)defining one that is already defined.

| Column (`#ColumnType`) | Record member (`ItemUseFunction::IUF_Function`, 0x36) | Off | Use |
|---|---|---|---|
| ItemIndex (`String[33]`) | `char ItemIndex[33]` | 0x00 | item InxName (`idb_btree`); fatal if unknown |
| BroadCast (`BYTE`) | `u8 BroadCast` | 0x21 | → `uie_BroadCast` (0x3029 on use, §1.4) |
| UseFunction (`Index`, 20 bytes) | `ORToken Func` | 0x22 | actor name, compared as 20 bytes (case-sensitive) |

```pseudo
ItemUseFunction::iuf_Load(this)                                                @ FUN_0049b770
    or = OptionReader(); ok = or.or_Read("../9Data/Shine/World/ItemUseFunction.txt")       # FUN_00646bf0
    !ok: assert "ItemUseFunction::iuf_Load : Option read error" (or_ErrorLine); ShineExit("ItemUseFunction::iuf_Load")
    n = or.or_SelectCountFrom("ItemUseFunction")
    for i in 0 .. n-1:
        rec = or.or_SelectFromOrder("ItemUseFunction", i)
        id = itemdatabox.idb_btree[rec.ItemIndex] (0xffffffff → 0xffff)
        id == 0xffff: assert "ItemUseFunction::iuf_Load : Invalid Item" (name); ShineExit
        uie_BroadCast(useditemeffect, id, rec.BroadCast)                               # for every record, also "-"
        skill = "UseSkill"
        switch rec.Func:
            "-":              nothing more (the entry keeps its actor, skill and effect row)
            "UseSilverWings": actor = ui_silverwing; skill = "UseSilverWings"
            "StatClearStat":  ui_StatClearStat          "StatClearEmpow": ui_StatClearEmpow
            "LicenceClear":   ui_LicenceClear           "AmountHP":       ui_amounthp
            "AmountMP":       ui_amountsp               "MemoryFeather":  ui_MemoryFeather
            "BossMobDetect":  ui_BossMobDetect          "NoEffect":       ui_NoEffect
            "Propose":        ui_Propose                "IM_Divorce":     ui_ImmediateDivorce
            "MobCardOpen":    ui_MobCardOpen
            anything else: assert "ItemUseFunction::iuf_Load : Invalid function" (the name); ShineExit
        if not "-": uie_SetChargedBuffer(useditemeffect, id, actor, uie_UseSkillID(skill))    # effect row reset
    ~OptionReader
```

The first five names are compared as five dwords inline, the rest with `ORToken::operator==`; same result.
2016 records: SilverWings → UseSilverWings; FreeStatusReloadAll → StatClearStat; SkillReloadbundleAll →
StatClearEmpow; LicenseClear → LicenceClear; 9 × AmountHP (HPMPotion0–5, HPMPotion2_1, E_SixYear_Cake) and 5 ×
AmountMP (SPMPotion0–3, SPMPotion2_1), all class AMOUNT; GoddessWing → MemoryFeather; KQ_SoulCrystal (BroadCast 1)
→ BossMobDetect; Firecracker02, HFirecracker00 (BroadCast 1) → NoEffect; CC_Closed → MobCardOpen. All 22 items exist,
none is in ItemUseEffect.shn, no `-`, `Propose` or `IM_Divorce` record (those two actors come from §1.3). Only these
three items broadcast 0x3029.

## 3. `cStateItemDataBox` (StateItem.shn, stage sleep) and the "by abstate" items

Items that put one random abnormal state on the user, chosen by weight. Global `cStateItemDataBox gStateItemDataBox`
(0x10 bytes: `std::vector<SIDB_Element> sidb_ElementList`; initializer FUN_00699a90 = an empty vector ctor folded
with `CardCollectionReward`'s, destructor at exit). `SIDB_Element` (0x14) = `{u16 se_nItemID +0, std::vector<StateItem>
se_StateItemList +4}`; the rows are **copied** into the vectors (the reader is a local and is freed).

StateItem.shn: `BinaryDataBox<StateItem>::bdb_ReadData` FUN_0058bfe0 (key 0x4d = 77, row 0x46; 2016: key 77, 60 rows).
Row `StateItem` (0x46):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| ItemIDX (9:32) | `char ItemIDX[32]` | 0x00 | item InxName |
| AbStateInx (9:32) | `char AbStateInx[32]` | 0x20 | abstate InxName (looked up again at use) |
| StaStrength (3:4) | `u32 StaStrength` | 0x40 | abstate strength, 1 … 39 checked at use |
| StaSucRate (2:2) | `u16 StaSucRate` | 0x44 | weight ‰; the rows of one item must sum to exactly 1000 |

```pseudo
cStateItemDataBox::sidb_Load(this) → bool                                      @ FUN_0058c920
    reader = local BinaryDataBox<StateItem>; bdb_ReadData(reader, "../9Data/Shine/StateItem.shn")   @ FUN_0058bfe0
    for r in reader rows:
        id = itemdatabox.idb_2itemid(r.ItemIDX)                                      # FUN_00418ff0 (BTree, 0xffff if none)
        id == 0xffff: assert "cStateItemDataBox::sidb_Load : not found item id " (r.ItemIDX); return false
        ix = ItemDataBox::operator[](itemdatabox, id)                                 # FUN_00419020
        ix == null or ix.data == null: assert "…sidb_Load : not found item data " (r.ItemIDX); return false
        a = dic_abstate.as_BTreeIndex[r.AbStateInx]; not found: assert "…not found abstate enum" (r.AbStateInx); return false
        AbState::as_FromIndex(dic_abstate, a) == null: assert "…not found abstate data" (r.AbStateInx); return false
        el = sidb_GetElement(this, id)                                               @ FUN_0058c190 (linear search; 0xffff → null)
        if el == null: push_back {se_nItemID = id, se_StateItemList = [r]}           # vector helpers FUN_0058c850,
                                                                                     #   FUN_0058c480 (resize 0), FUN_0058c560,
                                                                                     #   temp dtor FUN_005d49c0 (folded)
        else: el.se_StateItemList.push_back(r)                                       # FUN_0058c560
        uie_SetChargedBuffer(useditemeffect, id, ui_ByAbstate, uie_UseSkillID(ix.data.ItemUseSkill))   # per row
    for el in sidb_ElementList (in insertion order):
        sum = Σ StaSucRate of el's rows; sum != 1000: assert "cStateItemDataBox::sidb_Load : total suc rate error" (sum); return false
    return true
# caller zs_start_sleep: false → ShineExit("ZoneServer::zs_start_old") (wrong stage name: Z10-B20)
```

The rows of one item need not be adjacent (`sidb_GetElement` merges them). A failing row aborts the load after the
earlier rows were stored, but the zone exits anyway.

```pseudo
UseItemByAbstate::uib_CanUseItem(actor, p, item) → code                        @ FUN_00596ad0
    p or item null: 0x702
    return sidb_GetElement(gStateItemDataBox, item.itemid) ? 0x700 : 0x702       # 0x702 "You cannot use this" (client text; Z04 §6.1)

UseItemByAbstate::uib_Effect(actor, obj, item, entry)                          @ FUN_0059c310   (after the DB consumed it)
    obj, item or entry null, or no element for item.itemid: return
    roll = well512_GetRandom(1000)                                               # 0 … 999 (FUN_0063cb10)
    acc = 0
    for r in element rows (file order):
        acc += r.StaSucRate (u16)
        if roll <= acc:                                                          # (original bug) Z24-B4: "<=" with 0…999
            a = dic_abstate.as_BTreeIndex[r.AbStateInx]; none: assert "UseItemByAbstate::uib_Effect : not found abstate enum"; return
            r.StaStrength == 0: assert "…nStrength value 0"; return
            r.StaStrength > 39: assert "…nStrength value" (strength); return
            s = AbState::as_FromIndex(dic_abstate, a); null: assert "…not found abstate data"; return
            s.index == null: assert "…not found abstate data index"; return
            s.subabstate[strength].assa_info == null: assert "…not found subabstate data" (a, strength); return
            ok = obj.so_AbnormalState_Set(setter = obj, s.index.AbStataIndex, strength, s, clockwatch.cw_CurrTick,
                                          0, −1, 0, 0xb, 0)                     # vt 0x638 FUN_004162d0 (Z03 §6); args from the disassembly
            !ok: return
            ShineObject::so_AbnormalState_BitSet(obj, AbStataIndex)             # FUN_00401a00
            obj.so_AbnormalState_Inform(AbStataIndex, subabstate.KeepTime, 1)   # vt 0x3f0 (Z03)
            ShineObject::so_AbnormalState_BroadcastSet(obj, AbStataIndex, KeepTime, strength)   # FUN_004056a0
            obj.vt[0x99c]()                                                     # player: so_ply_AbstateMatchEquip FUN_004a48c0
            return
    assert "UseItemByAbstate::uib_Effect : not found abstate enum" (one past the last row's name)   # unreachable when the sum is 1000
```

2016 data: 60 rows, two items (`E_HwinCandy`, `E_HwinCandyM`: 27 and 33 rows), each class BYTELOT with ItemUseSkill
`UsePotion`, each summing to 1000; all StaStrength 1, no rate 0; every item and abstate name resolves; rows of an item
are adjacent.

## 4. `MysteryVaultTable` (MysteryVaultServer.shn, stage full)

The "mystery bolt" boxes: opening one creates items rolled from this table (Z05 §9.8 `sp_MysteryVaultMakeItem`).
Loaded through the `Table::Load<T>` / `ITableBase<Row,T>` template (Z16 §4.2 for GuildTournamentScore: one 0xc4
table object `ms_pkTable`, `CDataReader m_kDataReader` +4, `char m_acFilename[128]` +0x44, vt+4 = `DataProcess`).

```pseudo
Table::Load<MysteryVaultTable>("MysteryVaultServer.shn")                       @ FUN_005b5580
    path = GetTableDir() + name                                                  # "../9Data/Shine/" (stage earth)
    ITableBase<MysteryVaultServer,MysteryVaultTable>::Load(path, true)           @ FUN_005b2ea0
        ms_pkTable == null: ms_pkTable = new MysteryVaultTable                   # ctor FUN_005b14e0
        CDataReader::ClearBF; ok = CDataReader::Read(m_kDataReader, path)        # unchecked form: no row-size check
        ok and m_pHead and m_pHead.nVersionKey == 0x96 (150): copy path to m_acFilename; return vt[1]() = DataProcess
        else false
    false: assert "Fail to read  : MysteryVaultServer.shn"; ShineExit(same text)
```

Row `MysteryVaultServer` (0x48; 2016 file: key 150, row 72, 250 rows):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| MV_GroupItemInx (9:32) | `char MV_GroupItemInx[32]` | 0x00 | the box item (InxName); map key |
| ChrClass (11:4) | `ChrClassType ChrClass` | 0x20 | 0 FIGHTER, 1 ARCHER, 2 CLERIC, 3 MAGE, 4 JOKER, 5 SENTINEL, 6 COMMON (an enum, not a mask; Z05 §9.8 calls it "class mask") |
| ItemInx (9:32) | `char ItemInx[32]` | 0x24 | item created, `-` = nothing (a "miss" entry of a rate group) |
| Lot (1:1) | `u8 Lot` | 0x44 | count created; ≤ ItemInfo.MaxLot of ItemInx |
| Rate (2:2) | `u16 Rate` | 0x45 | ‰ |
| Group (1:1) | `u8 Group` | 0x47 | 0 = independent roll; ≠ 0 = one pick per group, whose rates must reach exactly 1000 |

```pseudo
MysteryVaultTable::DataProcess(this) → bool                                     @ FUN_005c8590
    n = ITableBase<…>::GetTotal()                                               @ FUN_005c83b0 (m_pHead.nNumOfRecord, 0 without header)
    n == 0: return true
    curGroup = 0; acc = 0 (u16)
    for i in 0 .. n-1 (GetTotal re-read each pass):
        r = CDataReader::GetRecord(i); null: assert " MysteryBoltTable::DataProcess() Vault data null :" (i); return false
        box = idb_2itemid(r.MV_GroupItemInx); 0xffff: assert " …Invalid Group ItemId :" (name); return false
        if r.Group != curGroup:
            if curGroup != 0 and acc < 1000: assert " …Group Rate Shortage :" (r.ItemInx); return false
            acc = 0; curGroup = r.Group
        if curGroup != 0:
            acc += r.Rate; acc > 1000: assert " …Group Rate Over :" (r.ItemInx); return false
        # (original bug) Z24-B5: groups are runs of equal Group values across the whole file, not per box, and the
        #   last run of the file is never checked for a shortage
        if r.ItemInx != "-":
            item = idb_2itemid(r.ItemInx); 0xffff: assert " …Invalid Make ItemId :" (name); return false
            if itemdatabox[item].data.MaxLot < r.Lot: assert " …Maxlot Over :" (name); return false
            sm_ItemLists.insert({box, &r})          # static multimap<u16 box id, MysteryVaultServer*> FUN_005c8520;
                                                    #   result == end(): assert " …InSert Fail :" → dead, a multimap insert
                                                    #   never fails (original bug) Z24-B6
        uie_SetChargedBuffer(useditemeffect, box, ui_mysterybolt, uie_UseSkillID("UsePresentBox"))   # per row
    return true
```

`sm_ItemLists` (initializer FUN_0069b3b0: empty tree head) keeps pointers into the reader buffer. Look-ups used by
Z05 §9.8: `MysteryVaultTable::Getloweriter(box)` FUN_005c83e0 / `GetUpperiter(box)` FUN_005c8420 (= `lower_bound` /
`upper_bound`: the rows of one box in file order) and `IsCheckClassType(type, class)` FUN_005c82e0:

```pseudo
MysteryVaultTable::IsCheckClassType(ChrClassType t, u8 chrclass) → bool          @ FUN_005c82e0
    c = CharClassManager::operator[](charclassmanager, chrclass)                  # FUN_0044a930 (≥ 64 → ccm_classdefault)
    c == null: return false                                                       # never null
    base = c.cc_ClassType()                                                       # vt 0x48: the first class of the line
    # cc_ClassType per class object (RTTI vftables): fighter line FUN_00557bb0 (folded, returns 1), cleric line
    #   FUN_00449780 → 6, archer line FUN_00449820 → 11, mage line FUN_004498e0 → 16, joker line FUN_0063e440 → 21,
    #   sentinel line FUN_0063e470 → 26; CharClass (default) and CharClassMob FUN_00570b00 → 0
    FIGHTER: base == 1; ARCHER: 11; CLERIC: 6; MAGE: 16; JOKER: 21; SENTINEL: 26; COMMON: true
    other: assert "MysteryVaultTable::IsCheckClassType Not Define Type"; false
```

2016 data: 250 rows for 34 boxes (all ItemInfo class DECORATION; the actor comes from this table, not the class),
every box and item name resolves, no `-`, Lot 1 … MaxLot. ChrClass: 195 COMMON, 11 per base class except SENTINEL
(none). Groups: 142 rows group 0; the three `MVault_KQSpring_Win/Draw/Lose` boxes each have groups 1, 2, 3 summing to
exactly 1000, every group run belongs to one box, and the file's last run is group 0, so Z24-B5 is latent.

## 5. `MoverDataBox` (MoverMain / MoverAbility / MoverHG / MoverItem / MoverUseSkill, stage long)

*(part 2)*

## 6. `ChargedItemEffectDataBox` and `RidePetDataBox` (ChargedEffect, MiniHouse, MiniHouseFurniture, Riding)

*(part 3)*

## 7. `CharClassDataBox` and the other helpers

*(part 4)*

## 8. Reload behaviour

`&reloaddata` (Z11 §8.6) only accepts `ActiveSkill` and reruns `SkillDataBox::sdb_Load`. None of the tables of this
item can be reloaded at run time: `useditemeffect` (ItemUseEffect.shn), ItemUseFunction.txt, StateItem.shn and
MysteryVaultServer.shn are read once at start; after `&reloaddata ActiveSkill` every `useskill` of §1.5 dangles
(Z20 §7). (`ITableBase::Load` clears and re-reads its reader, so a second `Table::Load<MysteryVaultTable>` would
re-run `DataProcess` and insert every row again into the never-cleared `sm_ItemLists`; nothing calls it twice.)

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z24-B1 | `uie_Load` FUN_0059cc30 | asserts "cannot find InstantDivorce item" when `sii_ImmediateDivorce == 0xffff` | dead: `idb_MakeSpecialID` already exits when the item is missing | one check |
| Z24-B2 | `uie_Load` | `sii_JustReviveItem` is only set when an ItemInfo row has ItemFunc 3; never initialised | without such a row, entry 0 (item ID 0, `LeatherBoots` in 2016) gets the revive actor *(inferred: zero static storage)*; latent in 2016 | 0xffff default + check |
| Z24-B3 | `uie_Load` | the table size is `idb_maxItemhandle` truncated to u16 | an item with ID 0xFFFF makes a 0-entry table and every write runs past it; latent (max ID 65504) | u32 size, or refuse ID 0xFFFF |
| Z24-B4 | `UseItemByAbstate::uib_Effect` FUN_0059c310 | roll 0…999 tested with `roll <= cumulative` | the first row wins (rate + 1)‰, the last (rate − 1)‰; a leading rate-0 row still wins on roll 0 | `roll < cumulative` |
| Z24-B5 | `MysteryVaultTable::DataProcess` FUN_005c8590 | rate groups = runs of equal `Group` across the file; the last run is not checked | adjacent boxes with the same group number add up ("Group Rate Over" or a masked shortage); a short last group loads; latent in 2016 | check per (box, group), and at the end |
| Z24-B6 | `MysteryVaultTable::DataProcess` | asserts "InSert Fail" when `multimap::insert` returns `end()` | dead check | – |

## 9. Not reconstructed / uncertain

- §1.4 client side of 0x3029: what object vt 0xc4 and FUN_0068fc00 do is *(inferred)* from the call shape (effect by
  item name); C01 lists only the two reads.
- Z24-B2's "item 0" depends on `itemdatabox` living in zero-initialised static storage (no write to
  `sii_JustReviveItem` other than the one in `idb_Load` was found).

## 10. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| `UseItemByTable` / actor bodies (`uib_CanUseItem`, `uib_Effect` of every `ui_*`) | Z04 §6.3 (done; lists every actor with its functions) | this item only builds the table; only the "by abstate" actor (StateItem's consumer) is documented here because Z04 cites just its CanUse |
| `sp_MysteryVaultMakeItem` FUN_005658f0 (the roll) | Z05 §9.8 (done) | the consumer of §4's map |
| `MagicContainer::mc_Load` FUN_0049c7f0 (TreasureReward.txt) | Z09 (done; `OptionReader` caller list §28.6) | writes into `useditemeffect`; listed in §1.5 only; sweep part to confirm Z09 documents its body |
| `ItemDataBox::idb_Load` FUN_00649780, `idb_MakeSpecialID` | Z04 (done) | source of `idb_btree`, `idb_specialid`; `ItemDataBox::ReadData` is part 4 of this item |
