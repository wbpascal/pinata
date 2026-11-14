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

Shared reader and dictionary helpers called by every loader of this item (bodies trivial; the reader itself is S02 /
W05 §3.1, the template Z20 §2.1):

```pseudo
CDataReader::CDataReader(r)                     @ FUN_0062a050   vftable; m_sFileMD5 = 0 ×8; m_pHead = null; m_nBFSize = m_nDataArraySize = m_nFileCheckSum = 0
CDataReader::ClearBF(r)                         @ FUN_0062a080   m_nBFSize ≠ 0: delete m_pHead; m_nFileCheckSum = m_nBFSize = 0
CDataReader::GetRecord(r, i) → row              @ FUN_0062a0f0   m_pHead set and i < m_pHead.nNumOfRecord: m_pDataArray[i]; else null
BinaryData::BinaryData / ~BinaryData            @ FUN_0063cf30 / FUN_0063cf50   CDataReader ctor / dtor + vftable
OptionReader::or_ErrorLine / or_ErrorString     @ FUN_00645f00 / FUN_00645f10   or_Argument.errmsg.orem_Line / orem_Message (§2, Z09 §28.6)
AbnormalStateDictionary::AbState::as_FromIndex(d, idx) → AbStateStr*   @ FUN_00401420
    idx > 0x317 (MAX_ABSTATEINDEX − 1): assert "AbnormalStateDictionary::AbState::as_FromIndex : Invalid skill idx"; null
    else d.as_StateIndexList[idx]                 # §3 (sidb_Load, uib_Effect)
```

### 1.5 Writers of `uie_FuncStruct`, in stage order

| Stage | Writer | Items | Actor | Use skill | Effect row |
|---|---|---|---|---|---|
| wide | `uie_Load` pass 1 FUN_0059cc30 | every ItemInfo row | by class (§1.3) | by class / ItemUseSkill | `uie_DefStruct` |
| wide | `uie_Load` specials | ProposeRing, InstantDivorce, JustRevive item | ui_Propose, ui_ImmediateDivorce, ui_JustRevive | "UseSkill" | unchanged |
| wide | `uie_Load` pass 2 | ItemUseEffect.shn rows | ui_bytable (action items: unchanged) | ItemUseSkill | the row |
| tough | `ItemUseFunction::iuf_Load` FUN_0049b770 (§2) | ItemUseFunction.txt rows | by `UseFunction` | "UseSkill" / "UseSilverWings" | reset to `uie_DefStruct`; `broadcast` set for every row |
| tough | `MagicContainer::mc_Load` FUN_0049c7f0 (Z09) | TreasureReward.txt boxes | — | — | — |
| tough | `ChargedItemEffectDataBox<ChargedItemEffect / MiniHouse / MiniHouseFurniture>::cideb_Load` FUN_005af300 / FUN_005af4d0 / FUN_005af6d0 (§6.3) | every ChargedEffect / MiniHouse / MiniHouseFurniture row, except items of class ACTIONITEM, GBCOIN, CAPSULE | ui_chargedbuff; ui_minihouse; ui_minihousefurniture | "UseSkill" | reset |
| sun | `RidePetDataBox::rpdb_Load` FUN_00450270 → `ChargedItemEffectDataBox<RIDING>::cideb_Load` FUN_00450070 (§6.4) | Riding.shn items (same class filter); their FeedType food items | ui_ride; ui_horsefood | "UseRide"; "UseSkill" | reset |
| full | `MysteryVaultTable::DataProcess` FUN_005c8590 (§4) | every MysteryVaultServer.shn box | ui_mysterybolt | "UsePresentBox" | reset |
| sleep | `cStateItemDataBox::sidb_Load` FUN_0058c920 (§3) | every StateItem.shn item | ui_ByAbstate | ItemUseSkill | reset |
| long | `MoverDataBox::mvdb_Load` FUN_004bf960 (§5.3) | MoverHG.shn food items (FeedType ≠ `-`); MoverItem.shn summon items | ui_horsefood; ui_ride | "UseSkill"; "UseRide" | reset |

`uie_SetChargedBuffer` replaces the effect row by `uie_DefStruct`, so an item that is both in ItemUseEffect.shn and
in a later table silently loses its use-effect row (no warning). 2016: ItemUseEffect, ItemUseFunction, StateItem and
MysteryVaultServer have no item in common (checked pairwise); ChargedEffect overlaps MiniHouse (159 items) and MoverItem (221), Riding overlaps MoverItem (`Coll`) and MoverHG (food `Hay`); details §6.6.

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

The mount ("mover") definition tables. Global `MoverDataBox moverdatabox` (0x13388f90; 0xab4 bytes; built by the
dynamic initializer FUN_0069af40 = ctor `MoverDataBox::MoverDataBox` FUN_004bf8a0 + `atexit` of FUN_006a00c0 →
`~MoverDataBox` FUN_004c0310). Loaded once by `zs_start_long` (Z10 §7.1, D10: reads `useditemeffect` (wide) and
`itemdatabox`); the consumers (mover summon, ride, feeding, upgrade) are Z13.

### 5.1 Data structures

```pseudo
MoverDataBox (0xab4)
    +0x000 mvdb_BinData { BinaryDataBox<MoverMain> m_MoverMain +0x000, <MoverAbility> m_MoverAbility +0x074,
                          <MoverHG> m_MoverHG +0x118, <MoverItem> m_MoverItem +0x1a4, <MoverUseSkill> m_MoverUseSkill +0x224 }
                        # ctor FUN_004bf6f0: BinaryData ctor + vftable + bdb_defaultblock zeroed per reader; dtor FUN_004bf7f0
    +0x2a4 u32 mvdb_MaxID                      # ctor 0
    +0x2a8 MoverDataBoxIndex* mvdb_Index        # new[MaxID + 1] (count stored in the 4 bytes before), ctor null
    +0x2ac BTree mvdb_BTree_MoverIndex          # MoverMain.MoverIDX → MoverID
    +0x6b0 BTree mvdb_BTree_ItemIndex           # MoverItem.ItemIDX (item InxName) → MoverID

MoverDataBoxIndex (0x20), one per MoverID 0 … MaxID      # ctor FUN_004bf950 (empty vector), dtor FUN_004bf920 (frees it)
    +0x00 MoverMain*    mvdbi_pBase         # null = no MoverMain row with this ID (holes in the ID range)
    +0x04 MoverAbility* mvdbi_pAbility      # null = no MoverAbility row (every mover in 2016)
    +0x08 MoverHG*      mvdbi_pHG           # null = no MoverHG row
    +0x0c MoverItem*    mvdbi_pSummonItem   # null = no MoverItem row
    +0x10 std::vector<MoverUseSkill*> mvdbi_vUseSkill     # every MoverUseSkill row of the mover, file order
```

All pointers point into the readers' row arrays, which live as long as the process (the box is never reloaded, §8).
`enum MOVER_SYSTEM_TYPE { MVST_RIDE 0, MVST_RIDE_ADEL 1, MVST_MOVER 2, MVST_MAX 3 }`.

### 5.2 Files, readers, column maps

| File (`../9Data/Shine/`) | Row struct | Reader | key | row size | rows 2016 |
|---|---|---|---|---|---|
| MoverMain.shn | `MoverMain` | `BinaryDataBox<MoverMain>::bdb_ReadData` FUN_004bf320 | 0xba (186) | 0x33 | 461 |
| MoverAbility.shn | `MoverAbility` | `BinaryDataBox<MoverAbility>::bdb_ReadData` FUN_004bf3e0 | 0x388 (904) | 0x61 | **0** |
| MoverHG.shn | `MoverHG` | `BinaryDataBox<MoverHG>::bdb_ReadData` FUN_004bf4a0 | 0x95 (149) | 0x4a | 461 |
| MoverItem.shn | `MoverItem` | `BinaryDataBox<MoverItem>::bdb_ReadData` FUN_004bf560 | 0x2c (44) | 0x40 | 461 |
| MoverUseSkill.shn | `MoverUseSkill` | the **same** FUN_004bf560 (the call casts `m_MoverUseSkill` to `BinaryDataBox<MoverItem>*`; key and row size are equal) | 0x2c (44) | 0x40 | **0** |

All five use the Z20 §2.1 template (`CDataReader::Read(path, key, size)`, readfail → two asserts + `ShineExit`); the
2016 files pass (keys and sizes = `S01-shn-structs.tsv`). Fixed paths, no per-world override. Columns = members in
order (S01: "same"); "Read by" lists the functions that read the member (`->member` in the PDB decompile; bodies Z13):

MoverMain (0x33):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| MoverID (3:4) | `u32 MoverID` | 0x00 | index into `mvdb_Index`; must be unique (fatal). 2016: 1 … 476 (index entry 0 and 15 other IDs unused). Read by `smv_RegenComplete` 00441fd0, `sp_MoverSystem_SummonItem` 0045ec10, `so_smv_GetMoverID` 0055efa0 |
| MoverIDX (9:32) | `char MoverIDX[32]` | 0x04 | key of `mvdb_BTree_MoverIndex`; the other four files refer to it |
| CastingTime (3:4) | `u32 CastingTime` | 0x24 | ms; `sp_MoverSystem_Cast` 0045d550 (2016: 1500) |
| CoolTime (3:4) | `u32 CoolTime` | 0x28 | ms; `sp_MoverSystem_SummonItem` |
| RunSpeed (2:2) | `u16 RunSpeed` | 0x2c | `so_RunSpeed` 0055ec40, `so_WalkSpeed` 0055eb20 (speed check: Z10 §5.4) |
| WalkSpeed (2:2) | `u16 WalkSpeed` | 0x2e | `so_WalkSpeed` |
| DurationHour (2:2) | `u16 DurationHour` | 0x30 | `sp_MoverSystem_SummonItem` (item lifetime *(inferred)*) |
| MaxCharSlot (1:1) | `u8 MaxCharSlot` | 0x32 | seats; `so_smv_SummonMover` 0055fdf0 |

MoverAbility (0x61; packed):

| Column | Member | Off | Use |
|---|---|---|---|
| MoverIDX (9:32) | `char MoverIDX[32]` | 0x00 | mover (fatal if unknown) |
| MoverLv (1:1) | `u8 MoverLv` | 0x20 | `so_GetLevel` 0055eae0 |
| HP (3:4) | `u32 HP` | 0x21 | `RidingInitHP` 0044f930 (also `so_MaxHP` 0055ed80, `so_SetHP` 0054a610, `sp_HorseItemSave` 0045e810, `so_MoverSystem_NoDamage` 0055efc0 test the pointer) |
| WCMin, WCMax, MAMin, MAMax (3:4 each) | `u32` | 0x25, 0x29, 0x2d, 0x31 | no reader found *(inferred: unused)* |
| AC, MR, TH, TB (2:2 each) | `u16` | 0x35, 0x37, 0x39, 0x3b | no reader found *(inferred: unused)* |
| ResIndex (9:32) | `char ResIndex[32]` | 0x3d | `so_smv_SummonMover` |
| AbsoluteSize (3:4) | `u32 AbsoluteSize` | 0x5d | `so_BodySize` 0055eb00 |

MoverHG (0x4a; hunger gauge):

| Column | Member | Off | Use |
|---|---|---|---|
| MoverIDX (9:32) | `char MoverIDX[32]` | 0x00 | mover (fatal if unknown) |
| FeedType (9:32) | `char FeedType[32]` | 0x20 | food item InxName or `-` (no food); the item gets the horse-food actor (§5.3). Also `so_smv_CanUseFeedItem` 0055f840, `sp_NC_ITEM_MOVER_UPGRADE_REQ` 0051c850 |
| RestoreAmount (2:2) | `u16` | 0x40 | `so_smv_Feeding` 0055f8e0 |
| MaxHG (2:2) | `u16` | 0x42 | `RidingInitHungry` 0044fe00, `smv_FoodEat` 0055f110, `so_smv_CanUseFeedItem`, `so_smv_Feeding` |
| CreateHG (2:2) | `u16` | 0x44 | no reader found *(inferred: unused; 2016: equal to MaxHG in all 461 rows)* |
| Tick (2:2) | `u16` | 0x46 | `smv_FoodEat`, `so_smv_SummonMover` |
| ConsumeHG (2:2) | `u16` | 0x48 | `smv_FoodEat` |

MoverItem (0x40): `char MoverIDX[32]` +0x00 (mover, fatal if unknown), `char ItemIDX[32]` +0x20 (the summon item's
InxName, fatal if not in ItemInfo; key of `mvdb_BTree_ItemIndex`).
MoverUseSkill (0x40): `char MoverIDX[32]` +0x00 (mover, fatal if unknown), `char ActiveSkillIDX[32]` +0x20 (skill
InxName; **not checked at load**: the vector is copied into the mover's skill list by `so_smv_SummonMover` →
`MoverSkillList::msl_Store` FUN_00449190, Z13).

### 5.3 `mvdb_Load`

```pseudo
MoverDataBox::mvdb_Load(this)                                                  @ FUN_004bf960   (void; caller zs_start_long)
    bdb_ReadData(m_MoverMain, "../9Data/Shine/MoverMain.shn")                  @ FUN_004bf320
    bdb_ReadData(m_MoverAbility, "../9Data/Shine/MoverAbility.shn")            @ FUN_004bf3e0
    bdb_ReadData(m_MoverHG, "../9Data/Shine/MoverHG.shn")                      @ FUN_004bf4a0
    bdb_ReadData(m_MoverItem, "../9Data/Shine/MoverItem.shn")                  @ FUN_004bf560
    bdb_ReadData(m_MoverUseSkill, "../9Data/Shine/MoverUseSkill.shn")          @ FUN_004bf560 (same reader, see §5.2)
    # each failure: Z20 §2.1 (ShineExit)

    # index array
    for r in MoverMain rows: if r.MoverID > mvdb_MaxID: mvdb_MaxID = r.MoverID        # starts at 0 (ctor), unsigned
    n = mvdb_MaxID + 1
    mvdb_Index = new MoverDataBoxIndex[n]        # 0x20 × n + 4, saturating on overflow (n × 0x20 ≥ 2³², or + 4 > 2³²)
    null: assert "Memory leak for index in MoverMain" (n); ShineExit("MoverDataBox::mvdb_Load")
    for id in 0 … MaxID: pBase = pAbility = pHG = pSummonItem = null; vUseSkill.clear()    # already so from the ctor

    # MoverMain
    for i, r in MoverMain rows:
        if r is the reader's default block: assert "MoverMain Data defblock" (i); ShineExit("MoverDataBox::mvdb_Load")
            # (row i < count always gives a real row: dead check; same in the four loops below)
        if mvdb_Index[r.MoverID].pBase != null: assert "Data duplicate in MoveMain.shn" (MoverID); ShineExit(same)
        mvdb_Index[r.MoverID].pBase = r
        mvdb_BTree_MoverIndex.bt_Insert(r.MoverIDX, r.MoverID)        # FUN_0063cba0; an equal name overwrites (Z20 §5.2):
            # a second MoverID with the same MoverIDX is not detected; the first one can then get no Ability / HG /
            # Item / UseSkill row (original bug) Z24-B7

    # MoverAbility (one optional row per mover)
    for i, r in MoverAbility rows:
        default block: assert "MoverAbility Data defblock" (i); ShineExit                    # dead
        id = mvdb_BTree_MoverIndex[r.MoverIDX]                                              # BTree::operator[] FUN_0063cc30
        id == 0xffffffff: assert "Data duplicate in MoverAbility.shn invalid mover" (−1); ShineExit
        mvdb_Index[id].pAbility != null: assert "Data duplicate in MoverAbility.shn not null" (id); ShineExit
        mvdb_Index[id].pAbility = r

    # MoverHG (one optional row per mover) + food items
    food = uie_UseSkillID(useditemeffect, "UseSkill")                               # FUN_0059cba0 (§1.4)
    null: assert "Food skill null" (0); ShineExit
    for i, r in MoverHG rows:
        default block: assert "MoverMain Data defblock" (i); ShineExit                       # dead; wrong file name in the text
        id = mvdb_BTree_MoverIndex[r.MoverIDX]
        id == 0xffffffff: assert "Data duplicate in MoverHG.shn invalid mover" (−1); ShineExit
        mvdb_Index[id].pHG != null: assert "Data duplicate in MoverHG.shn not null" (id); ShineExit
        mvdb_Index[id].pHG = r
        if r.FeedType[0] != '-':                                                     # only the first char is tested
            item = itemdatabox.idb_2itemid(r.FeedType)                               # FUN_00418ff0
            item == 0xffff: assert "Data duplicate in MoverHG.shn invalid food item" (r.FeedType); ShineExit
            uie_SetChargedBuffer(useditemeffect, item, ui_horsefood, food)            # FUN_005963e0: actor
                # UseItemHorseFood (Z04 §6.3), effect row reset to uie_DefStruct; many movers share one food item
                # (2016: 7 items for 163 rows), each row rewrites the same entry with the same values

    # MoverItem (one optional row per mover) = the summon items
    ride = uie_UseSkillID(useditemeffect, "UseRide")
    null: assert "Ride skill null" (0); ShineExit
    for i, r in MoverItem rows:
        default block: assert "MoverMain Data defblock" (i); ShineExit                       # dead
        id = mvdb_BTree_MoverIndex[r.MoverIDX]
        id == 0xffffffff: assert "Data duplicate in MoverItem.shn" (−1); ShineExit
        mvdb_Index[id].pSummonItem != null: assert "Data duplicate in MoverItem.shn" (id); ShineExit
        item = itemdatabox.idb_2itemid(r.ItemIDX)
        item == 0xffff: assert "Data duplicate in MoverItem.shn invalid mover item" (r.ItemIDX); ShineExit
        mvdb_Index[id].pSummonItem = r
        mvdb_BTree_ItemIndex.bt_Insert(r.ItemIDX, id)          # an item used by two movers: the last row wins, unnoticed (Z24-B7)
        uie_SetChargedBuffer(useditemeffect, item, ui_ride, ride)          # actor UseItemRide, effect row reset

    # MoverUseSkill (any number of rows per mover)
    for i, r in MoverUseSkill rows:
        default block: assert "MoverMain Data defblock" (i); ShineExit                       # dead
        id = mvdb_BTree_MoverIndex[r.MoverIDX]
        id == 0xffffffff: assert "Data duplicate in MoveMain.shn" (−1); ShineExit        # text names the wrong file
        mvdb_Index[id].vUseSkill.push_back(r)                                        # inlined vector growth (×1.5),
                                                                                     # "vector<T> too long" → _Xlength_error
```

The fatal-check texts in the HG / Item / UseSkill loops name the wrong file ("MoverMain Data defblock", "Data
duplicate in MoveMain.shn") and an unknown mover is reported as "Data duplicate … invalid mover"; log only
(original bug) Z24-B8. There is no check that a mover has an HG, Item or Ability row, that the summon item is of
class `ITEMCLASS_RIDING`, or that the food item is `ITEMCLASS_FEED`; the consumers test the pointers (Z13).

### 5.4 Accessors

```pseudo
MoverDataBox::mvdb_GetData(this, u32 id) → MoverDataBoxIndex*               @ FUN_004bf290
    id != 0xffffffff and mvdb_Index != null and id <= mvdb_MaxID: return &mvdb_Index[id]     # entry may be all null (hole)
    else null                                                                # caller so_smv_SummonMover 0055fdf0

MoverDataBox::mvdb_GetData_ItemIndex(this, char* itemInxName) → MoverDataBoxIndex*   @ FUN_004bf2c0
    name null: null; id = mvdb_BTree_ItemIndex[name]; id != 0xffffffff and index != null and id <= MaxID: &mvdb_Index[id]
    # callers: RidingInitHP 0044f930, RidingInitHungry 0044fe00, sp_MoverSystem_Cast 0045d550, sp_MoverSystem_MapLogin
    #   0045d9e0, sp_HorseItemSave 0045e810, sp_MoverSystem_SummonItem 0045ec10, sp_NC_ITEM_MOVER_UPGRADE_REQ 0051c850

MoverDataBox::mvdb_GetMoverType(this, u16 itemid) → MOVER_SYSTEM_TYPE         @ FUN_004bf240
    itemid != 0xffff and (name = itemdatabox.idb_GetItemInxName(itemid)) != null:
        return mvdb_BTree_ItemIndex[name] != 0xffffffff ? MVST_MOVER (2) : MVST_MAX (3)
    return MVST_MAX
    # only caller UseItemRide::uib_DirectUse FUN_005995b0 (actor ui_ride, Z04 §6.3): player mode (vt 0x484, Z01 §4.3) 1 or 2 →
    #   MVST_MOVER: sp_MoverSystem_Cast, else sp_HorseCast; mode 6 (riding) → get off (sp_MoverSystem_Type
    #   FUN_0045d540 == MVST_MOVER: sp_MoverSystem_GetOff, else sp_HorseOff); returns 1 (also for other modes, no effect)
```

So a riding item (`ui_ride`) is a "mover" when it is in MoverItem.shn, otherwise a classic horse (Riding.shn,
`ridedatabox`, §6). `MVST_RIDE_ADEL` is not produced here.

### 5.5 Invariants with the 2016 data

- MoverMain 461 rows, MoverID 1 … 476 unique (entries 0 and 15 unused IDs keep all pointers null), MoverIDX unique.
- MoverAbility.shn and MoverUseSkill.shn have **no rows**: every `pAbility` is null and every `vUseSkill` empty. So
  every mover counts as `so_MoverSystem_NoDamage` (mover with data but no ability, `docs/knowledge/Z16.md`) and no
  mover has its own skills.
- MoverHG and MoverItem: one row per mover, same 461 MoverIDX as MoverMain, no unknown mover, no duplicate.
- FeedType: 298 × `-`, 163 rows with 7 food items (LifeDust 123, Hay 18, FlyStone 15, Djewel 4, Sap, Dew, Scales);
  all exist, all `ITEMCLASS_FEED` (22). The other 6 FEED items (JewelCarrot01_1/2/3/5/6, Meat) are no mover's food:
  JewelCarrot01_1/2/3/5/6 are EE_FEED ChargedEffect items (`ui_chargedbuff`, §6.6), `Meat` keeps the
  stage-wide actor (`ui_base`, §1.3).
- MoverItem: 461 distinct summon items, all `ITEMCLASS_RIDING` (23), all with ItemUseSkill "UseRide". The only RIDING
  item without a MoverItem row is `Claude`: a Riding.shn horse (`ui_ride` from `rpdb_Load`, §6.6).
- Overlap with the other writers of `useditemeffect` (§1.5): none with ItemUseEffect, ItemUseFunction (empty),
  StateItem, MysteryVaultServer (box column), MiniHouse, MiniHouseFurniture; no item is both food and summon item.
  **221 summon items also have a ChargedEffect.shn row** and `Coll` also has a Riding.shn row: mvdb_Load runs last
  (stage long), so their `useditemeffect` entry ends as `ui_ride` + "UseRide" + `uie_DefStruct`, and
  `mvdb_GetMoverType` makes `Coll` a mover, not a Riding.shn horse. What the earlier ChargedEffect / Riding writes
  meant is lost only for the actor: their rows stay in `chargedbuffdatabox` / `ridedatabox` (§6.6).

## 6. `ChargedItemEffectDataBox` and `RidePetDataBox` (ChargedEffect, MiniHouse, MiniHouseFurniture, Riding)

Four item-keyed tables built by one template, `ChargedItemEffectDataBox<T>` (a `BinaryDataBox<T>` plus an array of
`{item ID, row}`), each loaded once with an actor and a use skill that it writes into `useditemeffect` for every listed
item. `RidePetDataBox` is the RIDING instance plus a food pass. Consumers: charged buffs Z12 / Z07 §4 (their per-effect application is §6.7), mini-house
Z07 §6, horses Z13 (§10).

### 6.1 Data structures

```pseudo
ChargedItemEffectDataBox<T> : BinaryDataBox<T>          # BinaryData (0x40) + T bdb_defaultblock at +0x40
    CIDEB_Element<T>* cideb_Array                        # new[cideb_Total], one per file row, file order; ctor null
    int               cideb_Total                        # = reader row count (static storage: 0 before the load)
CIDEB_Element<T> (8) { u16 ce_ItemID +0 (ItemInfo ID of T.ItemID); T* ce_Data +4 (the reader's row) }
ChargedItemEffectFinger (4) { int cief_Finger }          # iteration cursor; "home" = −1, end = −10
RidePetDataBox : ChargedItemEffectDataBox<RIDING> { }    # no own members; vftable RidePetDataBox
```

| Global | Addr | Type (size) | `cideb_Array` / `cideb_Total` | Dyn. initializer / atexit dtor / scalar-deleting dtor | Loaded by (stage) |
|---|---|---|---|---|---|
| `chargedbuffdatabox` | 0xaa4280 | `ChargedItemEffectDataBox<ChargedItemEffect>` (0x74) | +0x6c / +0x70 | FUN_006953e0 / FUN_0069c950 / FUN_0044fbb0 | `zs_start_tough` FUN_005b0540 |
| `minihousedatabox` | 0xaa42f8 | `ChargedItemEffectDataBox<MiniHouse>` (0xb8) | +0xb0 / +0xb4 | FUN_00695420 / FUN_0069c980 / FUN_0044fc20 | tough |
| `minihousefurnituredatabox` | 0xaa3fb0 | `ChargedItemEffectDataBox<MiniHouseFurniture>` (0xdc) | +0xd4 / +0xd8 | FUN_00695460 / FUN_0069c9b0 / FUN_0044fca0 | tough |
| `ridedatabox` | 0xaa40d8 | `RidePetDataBox` (0x1a4) | +0x19c / +0x1a0 | FUN_006954a0 / FUN_0069c9f0 / FUN_0044fb30 | `zs_start_sun` FUN_005adbd0 |

Initializer: `BinaryData` ctor, `bdb_defaultblock` zeroed (row size bytes), vftable, `cideb_Array = null`, `atexit`
(dtor). Dtors: `delete cideb_Array` if set, then `~BinaryData`. `ChargedItemEffect` 0x2b, `MiniHouse` 0x6f,
`MiniHouseFurniture` 0x94, `RIDING` 0x15a: `bdb_defaultblock` + row size, rounded up to 4, is the array's offset.

### 6.2 Files, readers, column maps

| File (`../9Data/Shine/`) | Row struct | Reader | key | row size | rows 2016 |
|---|---|---|---|---|---|
| ChargedEffect.shn | `ChargedItemEffect` | `BinaryDataBox<ChargedItemEffect>::bdb_ReadData` FUN_005ae790 | 0x8d (141) | 0x2b | 4542 |
| MiniHouse.shn | `MiniHouse` | `BinaryDataBox<MiniHouse>::bdb_ReadData` FUN_005ae840 | 0x1e8 (488) | 0x6f | 356 |
| MiniHouseFurniture.shn | `MiniHouseFurniture` | `BinaryDataBox<MiniHouseFurniture>::bdb_ReadData` FUN_005ae8f0 | 0x3f9 (1017) | 0x94 | 89 |
| Riding.shn | `RIDING` | `BinaryDataBox<RIDING>::bdb_ReadData` FUN_0044fd50 | 0x15d1 (5585) | 0x15a | 2 |

The Z20 §2.1 template (`CDataReader::Read(path, key, size)`; readfail → assert "BinaryDataBox<T>::bdb_ReadData :
readfail" (path), a second assert with the "Code:%X:%d\tSHN:%X:%d" text, `ShineExit`); the 2016 files pass (keys and
sizes = `S01-shn-structs.tsv`; NA2016's ChargedEffect has 4546 rows). Paths fixed in the callers (§6.3, §6.4), no
per-world override. Columns = members in file order (S01 "same"). Every file starts with `u16 Handle` +0x00 (unique
per file, §6.3) and `char ItemID[32]` +0x02 (item InxName; fatal if not in ItemInfo; becomes `ce_ItemID`).
"Read by" = functions that read the member (`->member` in the PDB decompile; bodies in the consumer items, §10); for
member names shared by several row structs (`Handle`, `KeepTime_Hour`, `Tick`, `RunSpeed`, `CastingTime`,
`CoolTime`) the function is assigned to a struct by its subsystem *(inferred)*.

ChargedItemEffect (0x2b, packed):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| Handle (2:2) | `u16 Handle` | 0x00 | the charged-buff id a player's stored buffs refer to: `cideb_FindFromHandle` FUN_00450390 (§6.5) from `so_CharChargedBuffData` 0044e1e0 (Z12 §6.8), `ciee_Free` 00450a50, `sp_ChargedItemTest` 00451360, GM command Z11 l.1099 |
| ItemID (9:32) | `char ItemID[32]` | 0x02 | the item; `cideb_GetItemID` FUN_0044fa10 (§6.5) by 14 callers (capsule, term extend, chat colour, weapon/shield endure charge, buy-all, `so_RecalcEquipParam`, …) |
| KeepTime_Hour (2:2) | `u16 KeepTime_Hour` | 0x22 | hours; `so_ply_ChargedBuff` 005970c0, `sp_NC_ITEM_TERMEXTEND_REQ` 0051eb40, `sp_MakeCapsuleItem` 0049cce0, `sp_SmallItemActivCheck<ItemInform_ActionItem>` 005697e0 |
| EffectEnum (11:4) | `EffectEnumerate EffectEnum` | 0x24 | `EE_*` 0 … 39 (`MAX_EFFECTENUMERATE` 40): 0 SILVERWINGCOOLTIME, 1 NOLOSTINKILLED, 2 MOREINVENTORY, 3 MORESTORAGE, 4 MOREBOOTHSLOT, 5 FASTMINING, 6–8 MOREHP/SP/HSPSTONE, 9 COSTUM, 10 AKPOWER, 11 DPPOWER, 12 ALLPOWER, 13–15 HP/SP/ALLINCREASE, 16 DROP_RATE, 17 FEED, 18 EXP_RATE, 19 STATUS, 20–22 ITEMAT/ITENDF/ITEMAL_RATE, 23–25 PRODUCTSPEED/MASTERY/ALLRATE, 26 JUSTREVIVE_HP, 27 ENDURE_KIT, 28 WEAPON_MAXENDURE, 29 ADDPRODSKILL, 30 JUSTRREVIVAL, 31 SETABSTATE, 32 GBCOIN, 33 STORAGE_ANYWHERE, 34 LPINCREASE, 35 AUTOPATHFIND, 36 CHATCOLOR, 37 TERMEXTEND, 38 EXPHOLD, 39 CLASSCHANGE. Read by `ChargedItemEffectList::ChargedItemEffectElement::ciee_Activ` 00450550, `ciee_AfterLoginComplete` 00417910, `ChargedEffectChatColorItemFree::lid_Call` 00450fe0, `so_RecalcEquipParam` 004cab70, `WeaponCostumInitCharge` 00517d40, `sp_NC_ITEM_WEAPONENDURE_CHARGE_REQ` 00519470 / `…SHIELDENDURE…` 00519a10, `sp_NC_ITEM_CHAT_COLOR_CHANGE_REQ` 0051e580, `so_ply_ChatColorInfoApply` 00563ac0 / `…Clear` 00564a70, `sp_NC_ITEM_TERMEXTEND_REQ`, `so_ply_MH_FurnitureEndureUse` 00571550, `so_ply_ChargedBuff`, `UseItemChargedBuff::uib_CanUseItem` 00598310 |
| EffectValue (2:2) | `u16 EffectValue` | 0x28 | amount / rate of the effect; the same readers plus `sp_CanChargedEnchant` 00418080, `sp_Gamble_UseCoinItem` 006174e0 |
| StaStrength (1:1) | `u8 StaStrength` | 0x2a | abstate strength of the EE_SETABSTATE rows (§6.7); `ciee_AfterLoginComplete`, `sp_CanChargedEnchant`, `smo_SwingDamage` 00433a70, `so_ply_ChargedBuff` |

MiniHouse (0x6f; the house-skin items):

| Column | Member | Off | Use |
|---|---|---|---|
| Handle (2:2), ItemID (9:32) | `u16 Handle`, `char ItemID[32]` | 0x00, 0x02 | as above; looked up by item with `cideb_GetItemID` FUN_00531820 (`sp_MiniHouseActivCheck` 00534fe0) |
| DummyType, Backimage (9:32) | `char[32]` | 0x22, 0x42 | no reader found *(inferred: client presentation)* |
| KeepTime_Hour (2:2) | `u16` | 0x62 | hours; `sp_MiniHouseActivCheck` (also `sp_DecorationActivCheck` 00534c60 by name) |
| HPTick, SPTick, HPRecovery, SPRecovery (2:2) | `u16` | 0x64, 0x66, 0x68, 0x6a | in-house regeneration: `ShinePlayer::MiniHouseStr::mhs_Init` 00534a30 |
| Casting (2:2) | `u16` | 0x6c | no reader found by name |
| Slot (1:1) | `u8` | 0x6e | `mhs_Init` |

MiniHouseFurniture (0x94; the furniture items):

| Column | Member | Off | Use |
|---|---|---|---|
| Handle (2:2), ItemID (9:32) | `u16`, `char[32]` | 0x00, 0x02 | as above; `cideb_GetItemID` FUN_00543400 (`icr_Apply` 0048a560, `smh_FurnitureActiveCheck` 005472e0); iterated with `cideb_Next` FUN_00514ae0 / `cideb_GetIndex` FUN_00514b10 (`so_mh_DiceTaiSai_GetExpectIncomeMoney` 00516970, `so_mh_SaveMHInven` 005435d0, `so_mh_CreateFurniture` 00544f00, `so_mh_CanFurnitureEmotion` 005485c0, `so_ply_MH_FurnitureEndureUpdate` 00570fe0, `so_ply_MH_FurnitureEndureUse`) |
| FurnitureType (9:32) | `char[32]` | 0x22 | no reader found |
| InvenType (9:32) | `char[32]` | 0x42 | `so_mh_Move2MiniHouseFurniture` 005354a0, `smh_SendFurnitureInfo` 00546930 |
| GameType (11:4) | `GameType` | 0x62 | `GT_NOGAME 0`, `GT_DICE 1` (`MAX_GAMETYPE 2`): `sp_DiceTaiSaiItemIDChange` 00514b40, `so_mh_DiceTaiSai_GetExpectIncomeMoney`, `so_mh_SaveMHInven`, `so_mh_CreateFurniture`, `smh_FurnitureActiveCheck` |
| CanSet (1:1) | `u8` | 0x66 | `so_mh_CreateFurniture` |
| Backimage (9:32) | `char[32]` | 0x67 | no reader found |
| WALL, BOTTOM, CEILING, IsAnimation (1:1) | `u8` | 0x87 … 0x8a | no reader found |
| Weight (2:2) | `u16` | 0x8b | no reader found |
| KeepTime_Hour (2:2) | `u16` | 0x8d | `icr_Apply`, `so_mh_Move2MiniHouseFurniture`, `smh_FurnitureActiveCheck` |
| KeepTime_Endure (2:2) | `u16` | 0x8f | `so_mh_SaveMHInven`, `so_mh_CreateFurniture`, `so_mh_EndureGradeDownTimeUpdate` 00547f60, `so_mh_DoingEndureGradeDown` 00548270, `so_ply_MH_FurnitureEndureUpdate`, `so_ply_MH_FurnitureEndureUse` |
| Grip, MHEmotionID (1:1) | `u8` | 0x91, 0x93 | no reader found |
| MaxSlot (1:1) | `u8` | 0x92 | `so_mh_CanFurnitureEmotion` |

RIDING (0x15a; the horse items of the old ride system, `sp_HorseCast`):

| Column | Member | Off | Use |
|---|---|---|---|
| Handle (2:2), ItemID (9:32) | `u16`, `char[32]` | 0x00, 0x02 | as above; `cideb_GetItemID` FUN_0043caa0 (`sp_RideInitialize` 0043d140); iterated with `cideb_Next` FUN_0044f9e0 / `cideb_GetIndex` FUN_0045e0b0 (`sp_NC_ITEM_MOVER_UPGRADE_REQ` 0051c850, Z04 §9.5) |
| Name, BodyType, Shape (9:32) | `char[32]` | 0x22, 0x42, 0x62 | no reader found *(inferred: client presentation)* |
| UseTime (2:2) | `u16` | 0x82 | `sp_HorseOn` 0045f270, `sp_NC_ITEM_MOVER_UPGRADE_REQ` |
| FeedType (9:32) | `char[32]` | 0x84 | food item InxName or `-`: `rpdb_Load` (§6.4), `sp_GetHorseFeed` 0045d510, `sp_NC_ACT_RIDE_FEEDING_REQ` 0045f9e0, `sp_NC_ITEM_MOVER_UPGRADE_REQ` |
| Texture (9:32) | `char[32]` | 0xa4 | no reader found |
| FeedGauge (2:2) | `u16` | 0xc4 | `so_ply_HorseFeed` 0045eaa0, `sp_NC_ACT_RIDE_FEEDING_REQ` |
| HGauge (2:2) | `u16` | 0xc6 | `sp_HorseNotHungry` 0045d460, `so_ply_HorseFeed`, `sp_NC_ACT_RIDE_FEEDING_REQ`, `ShinePlayer::so_Routine` 0056c790 |
| InitHgauge (2:2) | `u16` | 0xc8 | no reader found |
| Tick (2:2) | `u16` | 0xca | `sp_HorseOn`, `so_Routine` |
| UGauge (2:2) | `u16` | 0xcc | `so_Routine` |
| RunSpeed, FootSpeed (2:2) | `u16` | 0xce, 0xd0 | `sp_HorseOn` (RunSpeed also `so_RunSpeed` 005567b0) |
| CastingTime (2:2) | `u16` | 0xd2 | ms; `sp_HorseCast` 0045e0e0 |
| CoolTime (3:4) | `u32` | 0xd4 | `sp_HorseOn` |
| IconFileN (9:16), IconIndex (2:2), ImageN / ImageH / ImageE (9:16) | | 0xd8, 0xe8, 0xea, 0xfa, 0x10a | no reader found *(inferred: client UI)* |
| DummyA, DummyB (9:32) | `char[32]` | 0x11a, 0x13a | no reader found |

### 6.3 `cideb_Load` (one template, four instances)

`ChargedItemEffectDataBox<RIDING / ChargedItemEffect / MiniHouse / MiniHouseFurniture>::cideb_Load`
FUN_00450070 / FUN_005af300 / FUN_005af4d0 / FUN_005af6d0: the four bodies are identical but for the types (diffed).

```pseudo
ChargedItemEffectDataBox<T>::cideb_Load(this, path, actor, skill)              @ FUN_005af300 (and the three above)
    bdb_ReadData(this, path)                       # per-T reader, §6.2; failure exits
    cideb_Total = reader row count
    cideb_Array = new CIDEB_Element[cideb_Total]   # 8 × n, saturating; no null check; an old array is not freed
    for i in 0 … cideb_Total−1:
        r = GetRecord(i)                           # (i < count always; the default-block branch is dead)
        r == null: assert "ChargedItemEffectDataBox::cideb_Load : Null argument" (i); ShineExit("ChargedItemEffectDataBox<T>::cideb_Load")   # dead
        v = itemdatabox.idb_btree[r.ItemID]        # BTree::operator[] FUN_0063cc30 (inlined idb_2itemid)
        cideb_Array[i] = { ce_ItemID = (v == 0xffffffff ? 0xffff : u16 v), ce_Data = r }
        ce_ItemID == 0xffff: assert "ChargedItemEffectDataBox::cideb_Load : Invalid item" (r.ItemID); ShineExit(same)
        for j in 0 … i−2:                          # loop bound j < i − 1: row i−1 is never compared
            if cideb_Array[j].ce_Data.Handle == r.Handle:
                assert "ChargedItemEffectDataBox<T>::cideb_Load : Same Handle" (Handle); ShineExit(same)
            # (original bug) Z24-B9: a Handle equal to the previous row's is not detected (2016: §6.6)
        # inlined ItemDataBox::operator[] (FUN_00419020): id < idb_maxItemhandle and idb_index[id].data set,
        #   data.ID ≠ id → assert "ItemDataBox::operator [] :Invalid Item index" (id × 10000 + ID), no exit, no write
        if itemdatabox[ce_ItemID].Class ∉ {ITEMCLASS_ACTIONITEM 27, ITEMCLASS_GBCOIN 28, ITEMCLASS_CAPSULE 29}:
            uie_SetChargedBuffer(useditemeffect, ce_ItemID, actor, skill)       # FUN_005963e0 (§1.4): actor + skill,
                                                                                # effect row reset to uie_DefStruct
        # action items, GB coins and capsules keep the entry an earlier stage gave them (their own actor);
        # they still get an element, so cideb_GetItemID finds their row
```

No check that an item appears only once (the second row's `uie_SetChargedBuffer` repeats the same write;
`cideb_GetItemID` returns the first row, a later one is reachable only by `Handle`), nor of `KeepTime_Hour`,
`EffectEnum` (< 40) or `GameType` (< 2) ranges. `Handle` uniqueness costs n²/2 comparisons (ChargedEffect: ~10⁷).

Callers and arguments:

| Caller | Box | File | Actor (Z04 §6.3) | Skill (`uie_UseSkillID`, §1.4) |
|---|---|---|---|---|
| `zs_start_tough` FUN_005b0540 (after `iuf_Load`, `mc_Load`, `mas_Load`) | `chargedbuffdatabox` | ChargedEffect.shn | `ui_chargedbuff` (`UseItemChargedBuff`) | "UseSkill" |
| same, next | `minihousedatabox` | MiniHouse.shn | `ui_minihouse` (`UseItemMiniHouse`) | "UseSkill" |
| same, next | `minihousefurnituredatabox` | MiniHouseFurniture.shn | `ui_minihousefurniture` (`UseItemMiniHouseFurniture`) | "UseSkill" |
| `RidePetDataBox::rpdb_Load` (§6.4) | `ridedatabox` | Riding.shn | `ui_ride` (`UseItemRide`) | "UseRide" |

A missing skill gives `skill = null` (assert only, Z10 §7.1 note); `mvdb_Load` exits in that case ("Food skill null"),
these callers do not. The stage then runs `mhoadb_Load`, `kqrt_Load`, the AI script containers (Z10 §7.1).

### 6.4 `RidePetDataBox::rpdb_Load` and `zs_start_sun`

```pseudo
zs_start_sun()                                                                  @ FUN_005adbd0 (Z10 §7.1)
    RidePetDataBox::rpdb_Load(ridedatabox)                                      @ FUN_00450270
    UseItemRide::uir_SetSkill(ui_ride, uie_UseSkillID("UseRide"))               @ FUN_00653a60: uir_RideSkill = arg
    UseItemPet::uip_SetSkill(ui_Pet, uie_UseSkillID("UseSumPup"))               @ FUN_00596b10: uip_PetSummonSkill = arg; returns 1
    MobRoamingSet::mrs_Load(worldname), MiscDataTable::mdt_Load                 # Z09 / Z10
    # uir_RideSkill is read by UseItemRide::uib_CanUseItem 005988b0 (sdi_Activ.ID, no null test); both pointers
    # dangle after &reloaddata ActiveSkill (Z20 §7 table)

RidePetDataBox::rpdb_Load(this)                                                 @ FUN_00450270
    cideb_Load(this, "../9Data/Shine/Riding.shn", &ui_ride, uie_UseSkillID("UseRide"))      @ FUN_00450070 (§6.3)
    for each element e (finger −1, cideb_Next):                                 # inlined
        if e.ce_Data.FeedType[0] == '-': continue                              # only the first char is tested
        food = itemdatabox.idb_btree[e.ce_Data.FeedType]                       # FUN_0063cc30, 0xffff = none
        food == 0xffff: assert "RidePetDataBox::rpdb_Load : Invalid food" (FeedType); ShineExit("RidePetDataBox::rpdb_Load")
        uie_SetChargedBuffer(useditemeffect, food, &ui_horsefood, uie_UseSkillID("UseSkill"))
            # skill looked up again per row; the food item's class is not checked (cf. §5.3 MoverHG)
```

### 6.5 Accessors

```pseudo
cideb_Next(this, finger) → bool       # RIDING FUN_0044f9e0, ChargedItemEffect FUN_00570cf0, MiniHouseFurniture FUN_00514ae0
    if finger.cief_Finger ≥ −1 and ++finger.cief_Finger < cideb_Total: return true
    finger.cief_Finger = −10; return false                # once ended, stays ended until reset
    # reset ("home") = cief_Finger = −1: callers use PassiveDataBox::sdb_Home FUN_0050ffc0 (identical-code folding; it
    # just writes −1); the finger's constructor is folded into the empty ShineMobileObject::so_ShineMobileObject FUN_00450350

cideb_GetIndex(this, finger) → CIDEB_Element*         # RIDING FUN_0045e0b0, MiniHouseFurniture FUN_00514b10
    return 0 ≤ cief_Finger < cideb_Total ? &cideb_Array[cief_Finger] : null

ChargedItemEffectDataBox<ChargedItemEffect>::cideb_GetItem(this, finger) → u16 = cideb_Array[cief_Finger].ce_ItemID    @ FUN_00570d40
ChargedItemEffectDataBox<ChargedItemEffect>::cideb_Get(this, finger) → ChargedItemEffect* = cideb_Array[cief_Finger].ce_Data  @ FUN_00570d20
    # neither checks the finger (callers loop with cideb_Next first: so_ply_MH_FurnitureEndureUse 00571550)

cideb_GetItemID(this, itemID) → CIDEB_Element*        # RIDING FUN_0043caa0, ChargedItemEffect FUN_0044fa10,
    for i in 0 … cideb_Total−1:                       #   MiniHouse FUN_00531820, MiniHouseFurniture FUN_00543400
        if cideb_Array[i].ce_ItemID == itemID: return &cideb_Array[i]      # first row of the item, linear search
    return null

ChargedItemEffectDataBox<ChargedItemEffect>::cideb_FindFromHandle(this, int handle) → ChargedItemEffect*   @ FUN_00450390
    first row with u32(Handle) == handle, else null   # linear search; callers: so_CharChargedBuffData (Z12 §6.8), ciee_Free, sp_ChargedItemTest
```

### 6.6 Invariants with the 2016 data

- **ChargedEffect.shn** 4542 rows, Handles 9 … 4865, not in row order. **Handle 1738 occurs twice, in adjacent rows**
  1709 (`Cos_Uniform_USA_Boots01_2`, KeepTime 0) and 1710 (`Hat_Uniform01`, KeepTime 168; both EE_COSTUM value 1): the
  load accepts it only because of Z24-B9; `cideb_FindFromHandle(1738)` always returns the boots row. No other duplicate.
- All ItemIDs exist; 4533 distinct items, 8 with more than one row (APower2, DPower2, ADPower1, MightyPotion01_1,
  Cos_Made006_16/17/18 twice, JustRevival three times; e.g. APower2 KeepTime 2 h and 1 h): by item the first row wins.
- EffectEnum: EE_COSTUM 3692 rows (the item's own lifetime: costumes, equipment, house skins, mounts),
  EE_WEAPON_MAXENDURE 610, the other 31 used kinds ≤ 25 rows each; unused: 0, 20, 21, 23, 24, 26, 29.
- Class filter: 85 rows not written (75 `ITEMCLASS_ACTIONITEM`, all also ItemUseEffect.shn rows, so they keep their
  stage-wide action entry, §1.3; 7 CAPSULE; 3 GBCOIN with EE_GBCOIN); 4448 items get `ui_chargedbuff` + "UseSkill".
  Among them the FEED items JewelCarrot01_1/2/3/5/6 (EE_FEED), and many equipment items (weapons, armour,
  costumes) whose use entry is then `ui_chargedbuff`.
- **MiniHouse.shn** 356 rows, Handles 0 … 358 unique, all `ITEMCLASS_HOUSESKIN` (18). **MiniHouseFurniture.shn**
  89 rows, Handles 0 … 1008 unique, all `ITEMCLASS_FURNITURE` (9). No duplicate items in either.
- **Riding.shn** 2 rows, both `ITEMCLASS_RIDING`: `Coll` (Handle 0, FeedType `Hay`, an `ITEMCLASS_FEED` item) and
  `Claude` (Handle 1, FeedType `-`).
- Overlaps between the writers of `useditemeffect` (§1.5; last stage wins):
  - 159 MiniHouse items also have a ChargedEffect row (EE_COSTUM, their lifetime): MiniHouse loads after ChargedEffect
    in the same stage, so they end as `ui_minihouse`.
  - 221 ChargedEffect items are MoverItem summon items (EE_COSTUM): they end as `ui_ride` + "UseRide" (§5.3, stage long).
  - `Coll` (Riding.shn, stage sun) is also a MoverItem summon item: `mvdb_Load` writes the same actor and skill again,
    so its entry does not change, but `mvdb_GetMoverType` makes it a mover (MVST_MOVER), so its Riding.shn row is
    reached only by the `ridedatabox` lookups (§6.2 RIDING Handle row). `Claude` is the only Riding.shn horse.
  - `Hay` (Coll's food) is also a MoverHG food: written by `rpdb_Load` and again by `mvdb_Load` with the same values.
  - None with ItemUseEffect (rows written), ItemUseFunction, StateItem, MysteryVaultServer.
  - The last FEED item without a writer is `Meat`: it keeps the stage-wide `ui_base` entry (§1.3).
- The ChargedEffect rows of mini-house and mount items stay in `chargedbuffdatabox`: lookups by item
  (`cideb_GetItemID`: lifetime, term extension) still find them; only the use actor is replaced.

### 6.7 Applying the charged buffs (`ChargedItemEffectList`, the readers of `EffectEnum` / `EffectValue` / `StaStrength`)

A player's stored buffs are `p.sp_ChargedItem` (`ChargedItemEffectList::ChargedItem` 0x2a0: `ChargedEffectList ci_List`
+0 (the Z09 §28.11 `List<T>` with 50 slots, built by `ChargedEffectList` FUN_00451890, Z09 l.10116), `ChargedEffectContainer
ci_Effect` +0x270 (p+0x2a5a0), `u8 ci_bRecalcParam` +0x29e). Each slot holds a `ChargedItemEffectElement` (0xc)
`{ ChargedItemEffect* ciee_Index +0 (the §6.2 row); u8 ciee_Year +4 (since 2000), ciee_Month, ciee_Date, ciee_Hour,
ciee_Minute +8 }` = the end time; the slot number is the buff's `ChargedBuffKey` (`so_CharChargedBuffData` allocates the
slot with `l_AllocZ(key)`, Z12 §6.8). `ci_Effect` is rebuilt from the template `ShineObject::so_ChargedEffectContainerClear`
(filled by `so_Initstaticvar` FUN_00549530, called from Z10 §1.1) and one `ciee_Routine` per slot, by `so_Routine` once a minute
(Z09 §2.4 `PerMinutePlayerChecks`), `sp_NC_MAP_LOGINCOMPLETE_CMD` 00443390, `sp_NC_CHAR_CHARGEDBUFF_ERASE_REQ` 005645e0
(Z07 §4.2), `so_ply_ChargedBuff` 005970c0 and `so_FirstActionAfterSocketConnect` 00554870 (template copy).

`ChargedEffectContainer` (0x2e) members, template value, and the `EffectEnum` that sets them (`ciee_Activ`):

| Off | Member | Template | Set by (EffectValue v) | Rule |
|---|---|---|---|---|
| 0x00 | `u8 cec_SilverWingCoolTime_Minute` | 60 | 0 SILVERWINGCOOLTIME | min(cur, v) (2016: v = 0) |
| 0x02 / 0x04 | `u16 cec_HPStoneLimit` / `cec_SPStoneLimit` | 1000 / 1000 | 6 MOREHPSTONE / 7 MORESPSTONE / 8 MOREHSPSTONE (both) | max (‰ of the stone stock, Z12 l.618) |
| 0x06 | `cec_ProveOfBless { u8 bless; u16 blesshandle @2 }` | 0 | 1 NOLOSTINKILLED | bless = 1, blesshandle = the slot number |
| 0x0a / 0x0b / 0x0c | `u8 cec_MoreInven` / `cec_MoreStorage` / `cec_StreetBoothSlot` | 0 | 2 MOREINVENTORY / 3 MORESTORAGE / 4 MOREBOOTHSLOT | sum, capped at 6 / 2 / 20 |
| 0x0d | `u8 cec_LighteningPickParts` | 0 | 5 FASTMINING | = 1 |
| 0x0e / 0x10 / 0x26 | `u16 cec_MaxHPRate` / `cec_MaxSPRate` / `cec_MaxLPRate` | 1000 | 13 HP / 14 SP / 34 LPINCREASE; 15 ALLINCREASE (all three) | max (‰, Z12 §3.2) |
| 0x12 / 0x14 | `u16 cec_AttackForceRate1024` / `cec_DefendForceRate1024` | 0x400 | 10 AKPOWER / 11 DPPOWER / 12 ALLPOWER (both) | max of `(v << 10) / 1000` (‰ → /1024) |
| 0x16 | `u16 cec_ItemDropRate` | 1000 | 16 DROP_RATE | max (Z09 l.3314) |
| 0x18 | `u8 cec_MoverNotHungry` | 0 | 17 FEED | = u8(v), last slot wins |
| 0x19 | `u8 cec_MoreStat` | 0 | 19 STATUS | = u8(v), last slot wins (Z12 l.205) |
| 0x1a | `u16 cec_ExpBonus` | 1000 | 18 EXP_RATE | = v, **last slot wins** (original bug) Z24-B13 |
| 0x1c / 0x1e | `u16 cec_ItemPowerAttack` / `cec_ItemPowerDefence` | 1000 | 20 ITEMAT / 21 ITENDF / 22 ITEMAL_RATE (both) | max (Z12 l.232) |
| 0x20 / 0x22 | `u16 cec_ProductCastTimeRate` / `cec_ProductMasteryRate` | 1000 | 23 PRODUCTSPEED / 24 PRODUCTMASTERY / 25 PRODUCTALLRATE (both) | max |
| 0x24 | `u8 cec_StorageAnywhere` | 0 | 33 STORAGE_ANYWHERE | max (u8 of v) |
| 0x28 | `u8 cec_IsAutoPathFind` | 0 | 35 AUTOPATHFIND | = 1 |
| 0x29 / 0x2a / 0x2b | `u8 cec_ChatFontColor` / `cec_ChatBalloonColor` / `cec_ChatColor` | 0 | 36 CHATCOLOR with v = 1 / 2 / 3 | = 1 (other v: nothing) |
| 0x2c | `u8 cec_ExpHold` | 0 | 38 EXPHOLD | = 1 |

`ciee_Activ` ignores 9 COSTUM, 26 JUSTREVIVE_HP, 27 ENDURE_KIT, 28 WEAPON_MAXENDURE, 29 ADDPRODSKILL, 30 JUSTRREVIVAL,
31 SETABSTATE, 32 GBCOIN, 37 TERMEXTEND, 39 CLASSCHANGE: those rows act at item use or elsewhere (Z04 / Z17; 31 below).

```pseudo
ChargedEffectListRouter(r, ci, p)                                                       @ FUN_00450e10
    r.celr_ChargedItem = ci; r.celr_Player = p; r.celr_MoreStat = p.so_ply_ChargedEffectContainer().cec_MoreStat (vt 0x498)
ChargedEffectListRouter::lid_Call(r, el, slot) = ciee_Routine(el, r.celr_ChargedItem, slot, r.celr_Player); continue   @ FUN_00450f00
~ChargedEffectListRouter                                                                @ FUN_00450e80   (Z09 l.10118)
    cec_MoreStat changed during the walk: so_allparametercalculate (vt 0x57c), smo_mobile_NotifyParameterChange(1) (vt 0x34)

ChargedItemEffectElement::ciee_Routine(el, ci, slot, p)                                 @ FUN_00450c40
    now = chargeditemcheck.ct_Current (Z09 §1.2; packed year:8 month:5 date:6 hour:6 minute:7)
    (now.year, month, date, hour, minute) ≤ (el.ciee_Year, Month, Date, Hour, Minute) (field by field, the end minute
        itself still counts): ciee_Activ(el, ci, slot)
    else: ciee_Free(el, ci, slot, p)                                   # expired

ChargedItemEffectElement::ciee_Activ(el, ci, slot)                                      @ FUN_00450550
    switch el.ciee_Index.EffectEnum: apply EffectValue to ci.ci_Effect as in the table above

ChargedItemEffectElement::ciee_Free(el, ci, slot, p)                                    @ FUN_00450a50
    ci.ci_List.l_Free(slot) (List vt 0xc)
    pkt = 0x9002 NC_CHARGED_RESETBUFF_CMD { u32 CharRegistNumber = p.so_GetCharRegistNumber (vt 0x344),
        u32 ChargedBuffKey = slot, u16 ChargedBuffID = el.ciee_Index.Handle,
        u32 nUserNo = p.so_GetCharRegistNumber again }      # (original bug) Z24-B14: the character number, not the user number
    Character DB (sock2gameDB) ← pkt (D03 §9: p_Char_DelChargedBuff(charNo, key), log 0x043A); WM ← the same pkt (W04 §11)
    p ← 0x9004 NC_CHARGED_BUFFTERMINATE_CMD { u32 ChargedBuffKey = slot }   (game socket, vt 0x2fc)
    so_RecalcEquipParam (vt 0x35c), so_RecalcLastParam (vt 0x368), smo_mobile_NotifyParameterChange(1) (vt 0x34)
    so_ply_ChatColorInfoClear(p, el.ciee_Index) (vt 0xe40)
    ci.ci_bRecalcParam = 1                                             # the per-minute caller recalculates again (Z09 §2.4)
    # "Packet Too Long" asserts name ciee_Free1 / 2 / 3

ShinePlayer::so_ply_ChatColorInfoClear(p, eff)                                          @ FUN_00564a70
    eff null or EffectEnum ≠ 36 CHATCOLOR: return
    font = p.sp_nChatFontColor; balloon = p.sp_nChatBalloonColor
    eff.EffectValue 1: font = 0;  2: balloon = 0;  3: font = balloon = 0;  else: assert "so_ply_ChatColorInfoClear : Invalid EffectCalue"; return
    for each remaining slot with a CHATCOLOR row of another EffectValue w:   # a second buff of the same value does not restore
        w 1: font = p.sp_nChatFontColor;  2: balloon = p.sp_nChatBalloonColor;  3: both restored
    Character DB ← 0x4031 NC_CHARSAVE_CHAT_COLOR_CMD { u32 nCharNo, u8 font, u8 balloon }   (D02: CheckAlive only, nothing saved)
        # its "Packet Too Long" assert names sp_NC_ITEM_CHAT_COLOR_CHANGE_REQ (copied code)
    p.sp_nChatFontColor = font; p.sp_nChatBalloonColor = balloon       # the client is not told here

ShinePlayer::sp_ChargedEffectAfterLoginComplete(p)                                      @ FUN_00417ad0   (Z09 l.10112)
    l_4AllInList(p.sp_ChargedItem, ChargedEffectAfterLoginComplete { cealc_Player = p })   # List::l_4AllInList FUN_00487c50
ChargedEffectAfterLoginComplete::lid_Call(it, el, slot) = ciee_AfterLoginComplete(el, slot, it.cealc_Player); continue   @ FUN_00417fd0

ChargedItemEffectElement::ciee_AfterLoginComplete(el, slot, p)                          @ FUN_00417910
    row = el.ciee_Index; row.EffectEnum ≠ 31 SETABSTATE: return
    st = dic_abstate.as_FromID(row.EffectValue) (AbState ID); st null or st.index null: return
    keepMs = ftol(difftime(mktime(end of el: year + 100, month − 1, date, hour, minute, 0 s), mktime(chargeditemcheck.ct_TimeStr)) × 1000.0)
    if p.so_AbnormalState_Set(p, st.index.AbStataIndex, row.StaStrength, st, clockwatch.cw_CurrTick, 0, 0, keepMs, how 0xb, 0) (vt 0x638, Z03 knowledge):
        st.index.PartyRange == 0 or PartyEnchantNumber == 0:
            so_AbnormalState_BitSet(p, idx); so_AbnormalState_BroadcastSet(p, idx, keepMs, StaStrength)
            p.so_AbnormalState_Inform(idx, keepMs, 1) (vt 0x3f0)
        so_RecalcAbstateParamReady (vt 0x528)
    # 2016: rows 31 = AbState 8873 / 8874 (strength 1), 1 / 168 / 720 h; a party-range abstate is set without the bit / broadcast

ShinePlayer::sp_CanChargedEnchant(p, row) → bool                                        @ FUN_00418080
    # caller UseItemChargedBuff::uib_CanUseItem FUN_00598310 (Z04 §6.3) for a SETABSTATE row
    any slot whose row has EffectEnum 31, the same EffectValue (AbState) and StaStrength ≥ row.StaStrength: false
    else true                                                        # a stronger one may replace a weaker one
ShinePlayer::sp_RemoveEE_SETABSTATE(p, abstateId)                                       @ FUN_004181c0
    every slot whose row has EffectEnum 31 and EffectValue == abstateId: el.ciee_Year = 1   # end date → 2001: freed (and
        reported, ciee_Free) by the next per-minute ciee_Routine; the abstate itself stays until its own timer ends *(inferred)*

UseItemChargedBuff::uib_CanUseItem(actor, p, item) → code                               @ FUN_00598310   (Z04 §6.3 actor table)
    row = first chargedbuffdatabox row with ce_ItemID == item.itemid (cideb_Next walk); none or ce_Data null:
        log to ChargedItemLog; return 0x712                                  # no client text in client-error-codes.json
    c = p.so_ply_ChargedEffectContainer() (vt 0x498, the current ci_Effect)
    return 0x700 (usable) when the new row would change something, else 0x713 "The selected item does not have any effect when used.":
        0 SILVERWINGCOOLTIME: v < c.cec_SilverWingCoolTime_Minute
        1 NOLOSTINKILLED / 5 FASTMINING / 17 FEED: c.bless / cec_LighteningPickParts / cec_MoverNotHungry == 0
        2 / 3 / 4 MOREINVENTORY / MORESTORAGE / MOREBOOTHSLOT: cur + v < 7 / < 3 / < 20
            # (original bug) Z24-B15: the booth test allows a sum of 19 at most, ciee_Activ caps at 20
        6 / 7 / 8 STONE, 13 / 14 / 15 INCREASE, 16 DROP_RATE, 18 EXP_RATE, 19 STATUS, 20 / 21 / 22 ITEM*_RATE, 23 / 24 / 25
            PRODUCT*, 34 LPINCREASE: some covered member < v (10 / 11 / 12 POWER: < (v << 10) / 1000)
        31 SETABSTATE: sp_CanChargedEnchant(p, row) → sp_RemoveEE_SETABSTATE(p, v), 0x700; else 0x713
        33 STORAGE_ANYWHERE: cec_StorageAnywhere == 0;  35 AUTOPATHFIND / 38 EXPHOLD: flag ≠ 1
        every other EffectEnum (COSTUM, 26–30, 32, 36 CHATCOLOR, 37, 39): 0x713   # those items have their own actors / handlers
    # a local object is constructed and destroyed around the returns (folded ctor/dtor names: so_ShineMobileObject /
    #   so_Gamble_ChangeCoin), no effect on the result

ChargedEffectChatColorItemFree(it, ci, p, eff, all)                                     @ FUN_00450fb0   (dtor FUN_00417900 = base vftable)
    it.ceccif_pChargedItem = ci; ceccif_pPlayer = p; ceccif_pCIEffect = eff; ceccif_All = all (never read)
ChargedEffectChatColorItemFree::lid_Call(it, el, slot) → continue                       @ FUN_00450fe0
    # walked by so_ply_ChatColorInfoApply FUN_00563ac0 (Z05 §8.5 0x34B6) before the new chat-colour buff is stored
    ci, eff null or eff.EffectEnum ≠ 36: stop the walk
    el's row not CHATCOLOR: continue
    v = eff.EffectValue (new), u = el's EffectValue (stored)
    v == u or v == 3: ciee_Free(el, ci, slot, p)                       # same kind, or "all colours" replaces every one
    v == 1 and u == 3 and ci.ci_Effect.cec_ChatBalloonColor: ciee_Free  # the "all" buff is only dropped when a balloon
    v == 2 and u == 3 and ci.ci_Effect.cec_ChatFontColor:    ciee_Free  #   (resp. font) buff also covers its other half
    continue
```

The same per-minute block also expires time-limited items (their own end date, not a §6.2 row; Z09 §2.4 calls it):

```pseudo
ShinePlayer::sp_ChargedItemLimitCheck(p, bag, kind) (vt 0x38)                           @ FUN_00451530
    # kind 9 inventory, 8 equipment, 0xc mini-house bag (Z09 §2.4)
    for each cell of bag not locked (UnlockedInventoryIterator over ItemBoxIterItem, lock list vt 0x7d4):
        attr = cell.iic_AttrProc
        attr item class (vt 0x28) == 23 RIDING and player mode (vt 0x484) == 6 (riding, Z01 knowledge): skip   # a mount in use does not expire
        end = attr.vt[0x34](cell item) (ShineDateTime*; null = no end date): skip
        end.year ≠ 0 and end < chargeditemcheck.ct_Current (year, month, date, hour, then minute; strictly earlier):
            sp_ItemDelete(p, cell, kind, slot, end)
ShinePlayer::sp_ItemDelete(p, cell, kind, slot, end)                                     @ FUN_00451090
    copies the player name (vt 0x56c) into the rotating namestring buffer (log text; no reader found)
    sp_DestroyItem(p, p.handle, cell, inven = kind << 10 | slot & 0x3ff)                    # FUN_00527870 (Z09 l.7976: 0x3459 to the item DB, cell cleared)
```

(`sp_SmallChargedItemLimitCheck` FUN_0056b900 is Z09 §2.4; the dice-game variant `so_DiceTaiSaiChargedItemLimitCheck`
FUN_00517770 is §10, Z13.)

2016 data per `EffectEnum` (rows, values): 0 ×7 (0 min), 2 ×9 / 3 ×10 (1–2), 4 ×4 (10), 6–8 ×15/15/18 (1200–4000 ‰),
10–12 ×3/3/2 and 13–15 ×8/8/15 (1200–2000 ‰), 16 ×13, 18 ×25 (1100–2000 ‰), 17 ×5 (1), 19 ×6 (10), 22 ×9, 25 ×3,
31 ×6, 33 ×2, 34 ×12, 35 ×1, 36 ×3 (v 1 / 2 / 3), 38 ×4; none for 20, 21, 23, 24, 26, 29. The longest SETABSTATE
row is 720 h: its `keepMs` (2.59·10⁹) exceeds 2³¹ (§9).

## 7. `CharClassDataBox` and the other helpers

Four small tables that item code reads: the class masks of `UseClassTypeInfo.shn` (§7.1), the item drop groups
built from `ItemInfoServer.shn` (§7.2), the unused stand-alone ItemInfo reader (§7.3) and the gathering / production
tables (§7.4). All readers are the Z20 §2.1 template (`CDataReader::Read(path, key, size)`, readfail → two asserts +
`ShineExit`); keys and row sizes equal `S01-shn-structs.tsv`, columns = members in order ("same").

### 7.1 `CharClassDataBox` (`UseClassTypeInfo.shn`, stage home)

`charclassdatabox` 0x14d42140 *(pdb2016)*: `class CharClassDataBox { BinaryDataBox<UseClassTypeInfo> ccdb_classbits; }`
(0x60 bytes). `_dynamic_initializer_for_'charclassdatabox'` FUN_0069af60 runs the ctor `CharClassDataBox::CharClassDataBox`
FUN_00640950 (`BinaryData` base, all-zero default row: `UseClass = UCT_NONE`, every class byte 0) and registers
`_dynamic_atexit_destructor_for_'charclassdatabox'` FUN_006a00d0 → `~CharClassDataBox` FUN_00640980 (`~BinaryData`);
`BinaryDataBox<UseClassTypeInfo>::scalar_deleting_destructor` FUN_00640920 is the vftable's copy.

```pseudo
zs_start_home:  … ItemDataBox::idb_Load, …, ItemGroupClassifier::igc_Load (§7.2), …, DamageTable::dt_Load ×2,
    CharClassDataBox::ccdb_Load(&charclassdatabox, "../9Data/Shine/UseClassTypeInfo.shn")   @ FUN_00640990 (call 0x5adf82)
        BinaryDataBox<UseClassTypeInfo>::bdb_ReadData(&ccdb_classbits, path)               @ FUN_00640870
            CDataReader::Read(path, key 0x48A (1162), row 0x1F); fail → asserts + ShineExit("BinaryDataBox<T>::bdb_ReadData")
    # nothing else is built: every query below scans the rows linearly
```

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| UseClass (11:4) | `UseClassType UseClass` | 0x00 | the row's key; the queries take the **first** row with that value |
| Fig … Sav (1:1 ×27) | `u8 Fig, Cfig, War, Gla, Kni, Cle, Hcle, Pal, Hol, Gua, Arc, Harc, Sco, Sha, Ran, Mag, Wmag, Enc, Warl, Wiz, Jok, Chs, Cru, Cls, Ass, Sen, Sav` | 0x04 … 0x1E | 1 = class may use; class ID n (1 … 27) is column n |

`UseClassType` *(pdb2016)*: 0 NONE, 1 ALL, 2 FIGHTER_ALL, 3 CLEVERFIGHTER_AND_OVER, 4 WARRIOR_AND_OVER, 5 WARRIOR_OVER,
6 GLADIATOR_ONLY, 7 KNIGHT_ONLY, 8 CLERIC_ALL, 9 HIGHCLERIC_AND_OVER, 10 PALADIN_AND_OVER, 11 GUARDIAN_ONLY,
12 HOLYKNIGHT_ONLY, 13 PALADIN_OVER, 14 ARCHER_ALL, 15 HAWKARCHER_AND_OVER, 16 SCOUT_AND_OVER, 17 RANGER_ONLY,
18 SHARPSHOOTER_ONLY, 19 SCOUT_OVER, 20 MAGE_ALL, 21 WIZMAGE_AND_OVER, 22 ENCHANTER_AND_OVER, 23 WIZARD_ONLY,
24 WARLOCK_ONLY, 25 ENCHANTER_OVER, 26 SENTINEL_EXCLUDE, 27 JOKER_ALL, 28 CHASER_AND_OVER, 29 CRUEL_AND_OVER,
30 ASSASSIN_ONLY, 31 CLOSER_ONLY, 32 CRUEL_OVER, 33 SENTINEL_ALL, 34 SAVIOR_ONLY, 35 DEEPER_SKILL, 36 SHIELD,
37 CLASS_CHANGE, 38 SHIELD_NOT_GLA (MAX 39). Item, skill and passive rows carry it as `UseClass`.

```pseudo
CharClassDataBox::ccdb_UseClassTypeToBit(uct) → u64                                @ FUN_006409a0
    for i in 0 … rowcount−1:                       # row i ≥ count would be the default row (cannot happen)
        r = row i
        if r.UseClass == uct:
            return Horner(Sav, Sen, …, Cfig, Fig) << 1   # ((…(Sav·2 + Sen)·2 + …)·2 + Fig)·2, 64-bit with carries
            # = Σ r.<class n> << n: bit n = class ID n, bit 0 always 0. The bytes are added, not ORed: a cell > 1
            #   would carry into the next class (2016 cells are all 0/1)
    return 0                                       # unknown UseClass: no class may use it

CharClassDataBox::ccdb_ClassToBit(class) → u64 = 1 << class (64-bit _allshl; class ≥ 64 → 0)        @ FUN_00640850

CharClassDataBox::ccdb_CheckClass(uct, class) → bool                              @ FUN_00640e40
    return (ccdb_UseClassTypeToBit(uct) & ccdb_ClassToBit(class)) ≠ 0

CharClassDataBox::ccdb_BitToClass(bits u64) → u8 class                            @ FUN_00640b90
    c = (u8) trunc(log((double)(i64)bits) / log(2.0))          # CRT _CIlog twice; constant 2.0 at 0x7001a0;
                                                               #   fistp with round-toward-zero
    p = 2.0^c (inlined integer power, x87) → _ftol2 → i64
    return c if p == bits else 0                               # only an exact single bit gives its class;
    # 0, several bits or bit 63 (negative as i64: log → NaN) → 0. Exact for every bit 0 … 62 with IEEE doubles
    #   (checked: trunc(log(2^n)/log 2) = n for n < 64)

CharClassDataBox::ccdb_ClassToUseClassType(class) → UseClassType                  @ FUN_00640c20
    b = 1 << class
    for each row i in order: if mask(row i) == b: return row i.UseClass            # mask as in UseClassTypeToBit
    return UCT_NONE                                # only the "…_ONLY" rows have exactly one class

CharClassDataBox::ccdb_GetThirdClassGroup(class) → UseClassType                   @ FUN_00640e80
    b = 1 << class
    for g in (UCT_WARRIOR_OVER, UCT_PALADIN_OVER, UCT_SCOUT_OVER, UCT_ENCHANTER_OVER):
        if ccdb_UseClassTypeToBit(g) & b: return g
    if ccdb_CheckClass(UCT_CRUEL_OVER, class): return UCT_CRUEL_OVER
    return UCT_SAVIOR_ONLY if ccdb_CheckClass(UCT_SAVIOR_ONLY, class) else UCT_NONE
```

Callers. The four class-change helpers have exactly two callers each (call sites in the binary): the class-change
item handler `sp_NC_ITEM_CLASS_CHANGE_REQ` FUN_0051f5c0 (Z04 §12.10: `g = GetThirdClassGroup(class)`, NONE or
SAVIOR_ONLY → 0x3682; new class = `BitToClass(UseClassTypeToBit(g) ^ ClassToBit(class))` written into the DB request;
`ClassToUseClassType(class)` selects the skills of the own class) and `sp_OpenClassChangeMenu` FUN_0051fd10 (Z15
§6.5, Lua `cClassChangeOpen`: the same computation for the menu's `nNewClass` and price). `ccdb_UseClassTypeToBit` is also
called by `ItemGroupClassifier::igc_Getitem` FUN_004903e0 (Z09 §28.10 / §10.10, KQ rewards: only the low 32 bits of the mask are
tested against the 32-bit class mask, enough for bits 1 … 27); `ccdb_CheckClass` by `ac_AllLearnSKill` FUN_004212e0
(Z11), `sp_NC_BOOTH_SEARCH_ITEM_LIST_CATEGORIZED_REQ` FUN_00439c70 (Z06). Other readers of `charclassdatabox` (they
inline the same check): `so_ply_ViewSlot_Equip` 0052b110, `sp_NC_ITEM_EQUIP_REQ` 0052b8d0, `sp_NC_ITEM_RINGEQUIP_REQ`
0052c5b0, `sp_NC_ITEM_MINIMON_EQUIP_REQ` 0052d020, `sp_ItemUseReq_Inven` 0053f5e0, `sp_UseItemMonimon_UseItem`
00561b80 (Z04).

**2016 data** (39 rows, `UseClass` = row index 0 … 38, every cell 0/1, so the first-row rule never matters). Results
per class ID (1 Fig … 27 Sav) of the class-change helpers, computed from the file with the functions above:

| Class (ID) | `ClassToUseClassType` | `GetThirdClassGroup` | new class (`BitToClass(group ^ own)`) |
|---|---|---|---|
| Gla 4 / Kni 5 | 6 GLADIATOR_ONLY / 7 KNIGHT_ONLY | 5 WARRIOR_OVER | 5 / 4 |
| Hol 9 / Gua 10 | 12 HOLYKNIGHT_ONLY / 11 GUARDIAN_ONLY | 13 PALADIN_OVER | 10 / 9 |
| Sha 14 / Ran 15 | 18 SHARPSHOOTER_ONLY / 17 RANGER_ONLY | 19 SCOUT_OVER | 15 / 14 |
| Warl 19 / Wiz 20 | 24 WARLOCK_ONLY / 23 WIZARD_ONLY | 25 ENCHANTER_OVER | 20 / 19 |
| Cls 24 / Ass 25 | 31 CLOSER_ONLY / 30 ASSASSIN_ONLY | 32 CRUEL_OVER | 25 / 24 |
| Sav 27 | 34 SAVIOR_ONLY | 34 SAVIOR_ONLY (refused by both callers) | – |
| every other class (1st–3rd job, Sen 26) | 0 NONE | 0 NONE (refused) | – |

So a class change swaps the two 4th-job classes of one line (the masks of the five "…_OVER" rows hold exactly those
two). Shared types: 35 DEEPER_SKILL = War Gla Kni Sco Sha Ran; 36 SHIELD = War Gla Kni Pal Hol Gua;
37 CLASS_CHANGE = the ten 4th-job classes; 38 SHIELD_NOT_GLA = SHIELD without Gla; 26 SENTINEL_EXCLUDE = classes
1 … 25. The WM reads the same file with the same function (W05 §3.2 row 25, `ccdb_UseClassTypeToBit` FUN_00465a90,
identical code): its mask also has Fig at **bit 1** (W05's "bit 0 = Fig … bit 26 = Sav" is one bit low).

### 7.2 `ItemGroupClassifier` (item drop groups of `ItemInfoServer.shn`, stage home)

`itemgroupclassifier` 0x0d56c4a0 *(pdb2016)*: `{ BTree igc_btree +0; CardDeck::CardStack igc_itemgroup[1000] +0x404
(0x20 each); u32 igc_point +0x8104 }` (0x8108 bytes). `_dynamic_initializer_for_'itemgroupclassifier'` FUN_006963f0
builds the trie (`BTree::BTree`) and the 1000 stacks (`CardStack::CardStack` FUN_0064e560, Z11 §9.3), atexit
`_dynamic_atexit_destructor_for_'itemgroupclassifier'` FUN_0069d480 (stack dtors FUN_0064e190, `~BTree`); unwind
funclet FUN_00686390.

```pseudo
ItemGroupClassifier::igc_Load(this)                                           @ FUN_00490330 (zs_start_home, call 0x5ade9b,
                                                                              #   after idb_Load and dic_Load, Z10 §7.1)
    igc_point = 0                                  # the trie and the stacks are not cleared (one call only)
    for i in 0 … itemdatabox.idb_Itemspacies−1:    # ItemInfo rows in file order
        id = BinaryDataBox<ItemInfo>::operator[](itminf, i).ID
        ix = itemdatabox[id]                       # inlined ItemDataBox::operator[] FUN_00419020 (Z04 §1.2): id < idb_maxItemhandle,
                                                   #   ix.data ≠ null, ix.data.ID == id, else assert
                                                   #   "ItemDataBox::operator [] :Invalid Item index" (id*10000+found)
                                                   #   and ix = null
        igc_Store(id, ix.dataserv.DropGroupA)      # ix = null → null dereference (original bug) Z24-B11 (latent)
        igc_Store(id, ix.dataserv.DropGroupB)

ItemGroupClassifier::igc_Store(this, itemID u16, name)                         @ FUN_004900f0
    if name[0] == '\0' or name[0] == '-': return
    g = BTree::operator[](igc_btree, name)                                     # Z20 §5.2 trie, case-sensitive
    if g == 0xFFFFFFFF:
        if igc_point > 999: assert "ItemGroupClassifier::igc_Load : Too many groups" (igc_point);
                            ShineExit("ItemGroupClassifier::igc_Store")         # at most 1000 groups
        g = igc_point++; bt_Insert(igc_btree, name, g)
    elif g ≥ igc_point: assert "ItemGroupClassifier::igc_Load : invalid index" (g); ShineExit(…)   # dead check (original bug) Z24-B11
    CardStack::cs_InsertTop(igc_itemgroup[g], itemID)                          @ FUN_0064e2c0 (Z11 §9.3)
    CardStack::cs_Suffle(igc_itemgroup[g], 1)                                  @ FUN_0064e200 (one random pair swap, CRT rand; Z09 §28.10)
```

`ItemInfoServer` columns read: `DropGroupA` (+0x39) and `DropGroupB` (+0x61), both `char[40]` (Z09 §11.1);
the other ItemInfoServer columns belong to `idb_Load` (§10 row). The groups are read by `igc_Getitem` FUN_004903e0
(Z09 §28.10: an item name wins over a group name; draws by class mask, §7.1) and `igc_ChargedDuringUse` FUN_00490630
(Z04); `itemgroupclassifier` itself is also referenced by `sp_ItemReloc` 00536780, `sp_NC_ITEM_SELL_REQ` 00539020,
`sp_NC_BOOTH_OPEN_REQ` 0058e900, `TradeBoard::tb_CanTradeItem` 00593560, `sp_NC_TRADE_UPBOARD_REQ` 00595280 (the
`igc_ChargedDuringUse` check, Z04 / Z06) and `tcm_ItemMake` 00595d00 (Z09). Not reloadable (§8).

**2016 data**: 789 groups (limit 1000), largest 84 items. Two items name the same group in both columns
(`UniqRing01` 2280, `UniqNeck01` 2480): they are inserted twice and drawn twice as often from their group. 152 of the
789 group names are also item `InxName`s (e.g. `MaraRing`, `SkullRing`): `igc_Getitem` with such a name returns the
item itself, so those groups can never be drawn by name (the drop table's `dilig_AppendByName`, Z09 §11.1, does the
same lookup order).

### 7.3 `ItemDataBox::ReadData` (stand-alone ItemInfo reader, unused)

```pseudo
ItemDataBox::ItemDataBox(this, path, checkExists)                             @ FUN_0064b5d0
    BTree::BTree(idb_btree); construct idb_BinData (the seven readers); idb_index = null; idb_maxItemhandle = 0
    if path ≠ (char*)−1:
        path = path or "../9Data/Shine/ItemInfo.shn"
        if checkExists and fopen(path, "rb") fails: return       # (fclose otherwise)
        ItemDataBox::ReadData(this, path)                        # its only call (0x64b65e)
_dynamic_initializer_for_'itemdatabox' FUN_0069af20: ItemDataBox(&itemdatabox, (char*)−1, false)  # → no read
    atexit _dynamic_atexit_destructor_for_'itemdatabox' FUN_006a00b0 → ~ItemDataBox FUN_00649700

ItemDataBox::ReadData(this, path) → bool                                      @ FUN_006494f0
    if !CDataReader::Read(idb_BinData.itminf, path, key 0x4B67 (19303), row 0x17A): return false   # no assert, no exit
    idb_Itemspacies = rowcount
    idb_maxItemhandle = max(row.ID) + 1
    delete[] idb_index; idb_index = new ItemDataBoxIndex[idb_maxItemhandle] (0x28 each); null → return false
    each entry: data = dataserv = itemoption = itemdroplog = null; SetItemIndex = 0xFFFF; ItemSortOrder = 0xFF
        # MovingShot, AttackAngle, HitTimeArray, eDelConditionType, pBuyItemData stay uninitialised (idb_Load sets them)
    for each row: idb_index[row.ID].data = row                  # a duplicate ID keeps the last row
    for each row: bt_Insert(idb_btree, row.InxName, row.ID)    # trie never cleared; a duplicate name keeps the last
    return true
```

The only global `ItemDataBox` is built with path −1, and the zone loads ItemInfo through `idb_Load` FUN_00649780 (stage
home, all seven item files, §10 row), so `ReadData` never runs in the 2016 zone (dead code with a partly initialised index,
(original bug) Z24-B12). It reads only `ItemInfo.ID` (+0x00, u16) and `ItemInfo.InxName` (+0x02, char[32]); the
other ItemInfo columns are the members in order (S01: "same"; offsets Z04 §1.2). 2016 ItemInfo: 14989 rows, IDs unique,
17 `InxName`s used twice (all quest items `Q_…`, e.g. `Q_Pickaxe` 3178 / 3228): the trie keeps the later ID (also in
`idb_Load`'s trie, *(inferred: same insert loop)*).

Small `ItemDataBox` accessors reached from this item's tables (the rest of the index API is Z04 §1.2 / the follow-up Z25):

```pseudo
ItemDataBox::idb_GetItemInxName(db, id) → char*                                         @ FUN_006487d0
    id < idb_maxItemhandle, id ≠ 0xffff and idb_index[id].data set: return data.InxName (ItemInfo +0x02); else null
    # callers: mvdb_GetMoverType (§5.4), sp_MoverSystem_Cast / SummonItem / MapLogin, sp_HorseItemSave, RidingInitHP /
    #   RidingInitHungry, sp_NC_ITEM_MOVER_UPGRADE_REQ, sp_PetSystem_Cast / VirtualCast, UseItemPet::uib_DirectUse
ItemDataBox::idb_iter_next(db, &i) → bool = (++i < idb_Itemspacies)                      @ FUN_004900a0
ItemDataBox::idb_iter_Get(db, &i) → u16                                                   @ FUN_004900c0
    i ≥ idb_Itemspacies: 0xffff; else BinaryDataBox<ItemInfo>::operator[](itminf, i).ID   (row i in file order, FUN_004ae550)
    # the pair walks the ItemInfo rows in file order; only caller DropItemListInGroup::dilig_StoreItem (Z09 drop groups)
```

### 7.4 Gathering and production tables (`Gather.shn`, `Produce.shn`, stage wide)

`gathertable` 0x0d026cd0 `GatherProduce::GatherTable { BinaryDataBox<GatherInfo> gt_BinData; GatherIndex* gt_Array
+0xf0; u32 gt_Number +0xf4 }` and `recipebook` 0x0d026dc8 `GatherProduce::RecipeBook { BinaryDataBox<ProduceInfo>
rb_BinData; ProductIndex* rb_Array +0x1f8; int rb_Number +0x1fc }` *(pdb2016)* (Z02 §8's "DAT_0d026dc0" /
Z07's "DAT_0d026fc0" are the two arrays). Initializers `_dynamic_initializer_for_'gathertable'` FUN_00695990 /
`…'recipebook'` FUN_006959d0 (`BinaryData` base, zeroed default row, array null) and atexit destructors FUN_0069ce40 /
FUN_0069ce70 (delete the array, `~BinaryData`); the vftable copies `BinaryDataBox<GatherInfo>::scalar_deleting_destructor`
FUN_0046a600 / `<ProduceInfo>` FUN_0046a630. Both loaders run in `zs_start_wide` after `sdb_Load` / `pdb_Load` (Z10 §7.1).

```pseudo
GatherProduce::GatherTable::gt_Load(this)                                     @ FUN_0046a660
    BinaryDataBox<GatherInfo>::bdb_ReadData(gt_BinData, "../9Data/Shine/Gather.shn")   @ FUN_0046a4a0  key 0x3BF (959), row 0xAE
    gt_Number = rowcount; gt_Array = new GatherIndex[gt_Number] (12 bytes: { GatherInfo* index; u16 tool[3] })
    null → assert "GatherProduce::GatherTable::gt_Load : Memory leak"; ShineExit
    for each row i:
        gt_Array[i].index = row
        gt_Array[i].tool[k] = idb_btree[row.NeededTool<k>] (0xFFFFFFFF → 0xFFFF), k = 0 … 2
            # '-' and '' are looked up like names (→ 0xFFFF); an unknown tool name also becomes 0xFFFF = "no tool
            #   needed" without any message (original bug) Z24-B10
        bt_Insert(skillnametree, row.Index, row.GatherID)         # Z20 §5.2: the gather "skill" names

GatherProduce::RecipeBook::rb_Load(this)                                      @ FUN_0046a840
    BinaryDataBox<ProduceInfo>::bdb_ReadData(rb_BinData, "../9Data/Shine/Produce.shn") @ FUN_0046a550  key 0x18A5 (6309), row 0x1B6
    rb_Number = rowcount; rb_Array = new ProductIndex[rb_Number] (0x4C bytes)
    null → assert "GatherProduce::RecipeBook::rb_Load : Memory leak"; ShineExit
    for each row i:
        e = rb_Array[i]; e.index = row
        e.product = idb_btree[row.Product] (unknown → 0xFFFF, no message; the cast answers 0x0B09, Z02 §8)
        e.productlot = row.Lot
        for k in 0 … 7:
            e.raw[k].quantity = row.Quantity<k>
            e.raw[k].item = 0xFFFF if row.Raw<k> is '-' or ''
                            else idb_btree[row.Raw<k>]; unknown → assert "GatherProduce::RecipeBook::rb_Load : Invalid Raw"
                                 (name); ShineExit("GatherProduce::RecipeBook::rb_Load")
    qsort(rb_Array, rb_Number, 0x4C, rb_Compare)                  # rb_Compare FUN_0046a470: index.ProductID ascending

GatherProduce::RecipeBook::operator[](this, skillID u16) → ProductIndex*        @ FUN_00444b50
    key = a stack ProductIndex whose index points at a stack ProduceInfo with ProductID = skillID
    return bsearch(key, rb_Array, rb_Number, 0x4C, rb_Compare)    # null = no recipe; equal IDs: any of them
```

`ProductIndex` *(pdb2016)*: `{ ProduceInfo* index +0; u16 product +4; int productlot +8; { u16 item; int quantity }
raw[8] +0xC }`. `operator[]` is called by `sp_NC_ACT_PRODUCE_CAST_REQ` FUN_0046cf90 (call 0x46d0c2, Z02 §8) and
`UseItemSkillScroll::uib_CanUseItem` FUN_0059d1b0 (call 0x59d432, Z04 §6.3 / Z20 §5.2: a recipe scroll needs a recipe);
`csl_GetDelayGroup` 00448950 and `csl_PreProduceCheck` 0046ab70 (both Z23) and `smo_ply_ItemProduce` 0046c2d0 (Z07 §11)
read `rb_Array` directly. `gt_Array` is read only by `sp_GatherCheck` FUN_0046ad70 (Z02 §8).

Gather.shn (0xAE):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| GatherID (2:2) | `u16 GatherID` | 0x00 | the gather skill ID (value in `skillnametree`) |
| Index (9:32) | `char Index[32]` | 0x02 | gather skill name (key in `skillnametree`) |
| Type (11:4) | `GatherType Type` | 0x22 | 0 GT_HERBING, 1 GT_MINING, 2 GT_WOODCUTTING, 3 GT_FISHING *(pdb2016)*; `sp_GatherCheck` selects rows by it |
| NeededTool0 … 2 (9:32 ×3) | `char NeededTool0/1/2[32]` | 0x26 / 0x46 / 0x66 | item names → `tool[3]` (0xFFFF = none) |
| EqipItemView (9:32) | `char EqipItemView[32]` | 0x86 | not read by the zone (client view) |
| AniNumber (3:4) | `u32 AniNumber` | 0xA6 | not read by the zone |
| Gauge (3:4) | `u32 Gauge` | 0xAA | not read by the zone (Z02 §8: the client's gather time) |

Produce.shn (0x1B6):

| Column (type:size) | Member | Off | Use |
|---|---|---|---|
| ProductID (2:2) | `u16 ProductID` | 0x00 | the production skill ID; sort / search key |
| ProduceIndex (9:32) | `char ProduceIndex[32]` | 0x02 | not read (equals the skill's InxName in 2016) |
| Name (9:64) | `char Name[64]` | 0x22 | not read |
| Product (9:32) | `char Product[32]` | 0x62 | item name → `product` |
| Lot (3:4) | `u32 Lot` | 0x82 | → `productlot` (`ip_WhereProductStore` 0046b880) |
| Raw0 … Raw7 / Quantity0 … 7 (9:32 / 3:4) | `char Raw<k>[32]; u32 Quantity<k>` | 0x86 + 0x24·k / 0xA6 + 0x24·k | → `raw[k]` |
| MasteryType (11:4) | `TotalMasteryType MasteryType` | 0x1A6 | `csl_PreProduceCheck` (MT_STONE 0, PORTION 1, SCROLL 2, SUMMON 3, COMPOUND 4, RESOLVE 5, COOK 6) |
| MasteryGain (3:4) | `u32 MasteryGain` | 0x1AA | `smo_ply_ItemProduce` |
| NeededMasteryType (11:4) | `TotalMasteryType NeededMasteryType` | 0x1AE | `csl_PreProduceCheck` |
| NeededMasteryGain (3:4) | `u32 NeededMasteryGain` | 0x1B2 | `csl_PreProduceCheck` |

**2016 data.** Gather.shn: 6 rows: 29000 `Herbing` (type 0, no tool), 29002 `WoodCutting` (2, no tool) and four
29001 `Mining` rows (1) with tools `Pickaxe`, `MinerPickaxe`, `AlchemistPickaxe`, `Kebypick` (that order; `Mining` is
inserted four times with the same ID). `MinerPickaxe` and `AlchemistPickaxe` are not in ItemInfo, so rows 3 and 4
need no tool: `sp_GatherCheck` returns 0x0B01 with picker 0xFFFF for them and `so_mob_CanGathered` turns that into
0x0B0C for mining; a player with only a `Kebypick` reaches row 3 before row 6 and can never mine (Z24-B10). Produce.shn:
216 rows, ProductID 20000 … 24082, unique and already sorted, every `ProduceIndex` = the InxName of the active skill
with the same ID, every `Product` and `Raw` name known (at most 4 raws per recipe, no empty strings), Lot 1 … 4+.

## 8. Reload behaviour

`&reloaddata` (Z11 §8.6) only accepts `ActiveSkill` and reruns `SkillDataBox::sdb_Load`. None of the tables of this
item can be reloaded at run time: `useditemeffect` (ItemUseEffect.shn), ItemUseFunction.txt, StateItem.shn,
MysteryVaultServer.shn, the five Mover*.shn files (`mvdb_Load`, §5) and ChargedEffect / MiniHouse /
MiniHouseFurniture / Riding.shn (`cideb_Load`, §6; a second call would leak the old `cideb_Array` and re-read the reader) are read once at start; after `&reloaddata ActiveSkill` every `useskill` of §1.5 dangles
(Z20 §7). (`ITableBase::Load` clears and re-reads its reader, so a second `Table::Load<MysteryVaultTable>` would
re-run `DataProcess` and insert every row again into the never-cleared `sm_ItemLists`; nothing calls it twice.)

The §7 tables are not reloadable either: `UseClassTypeInfo.shn` (`ccdb_Load`, home), the drop groups (`igc_Load`,
home; a second call would reset `igc_point` but keep the trie and the stacks, so every item would be appended again),
`Gather.shn` / `Produce.shn` (`gt_Load` / `rb_Load`, wide; a second call would leak the old array). `ItemDataBox::ReadData`
could re-read ItemInfo (it frees the old index) but has no caller after start-up (§7.3).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z24-B1 | `uie_Load` FUN_0059cc30 | asserts "cannot find InstantDivorce item" when `sii_ImmediateDivorce == 0xffff` | dead: `idb_MakeSpecialID` already exits when the item is missing | one check |
| Z24-B2 | `uie_Load` | `sii_JustReviveItem` is only set when an ItemInfo row has ItemFunc 3; never initialised | without such a row, entry 0 (item ID 0, `LeatherBoots` in 2016) gets the revive actor *(inferred: zero static storage)*; latent in 2016 | 0xffff default + check |
| Z24-B3 | `uie_Load` | the table size is `idb_maxItemhandle` truncated to u16 | an item with ID 0xFFFF makes a 0-entry table and every write runs past it; latent (max ID 65504) | u32 size, or refuse ID 0xFFFF |
| Z24-B4 | `UseItemByAbstate::uib_Effect` FUN_0059c310 | roll 0…999 tested with `roll <= cumulative` | the first row wins (rate + 1)‰, the last (rate − 1)‰; a leading rate-0 row still wins on roll 0 | `roll < cumulative` |
| Z24-B5 | `MysteryVaultTable::DataProcess` FUN_005c8590 | rate groups = runs of equal `Group` across the file; the last run is not checked | adjacent boxes with the same group number add up ("Group Rate Over" or a masked shortage); a short last group loads; latent in 2016 | check per (box, group), and at the end |
| Z24-B6 | `MysteryVaultTable::DataProcess` | asserts "InSert Fail" when `multimap::insert` returns `end()` | dead check | – |
| Z24-B7 | `MoverDataBox::mvdb_Load` FUN_004bf960 | MoverIDX (MoverMain) and ItemIDX (MoverItem) go into BTrees whose `bt_Insert` overwrites an equal key; only MoverID and per-mover duplicates are checked | a second mover with the same name silently takes all Ability / HG / Item / UseSkill rows of that name (the first has none); an item named by two movers summons only the last; latent in 2016 (all unique) | fatal "duplicate" check on the names too |
| Z24-B8 | `mvdb_Load` | the fatal texts of the HG / Item / UseSkill loops say "MoverMain Data defblock" / "Data duplicate in MoveMain.shn", an unknown mover is reported as "Data duplicate … invalid mover"; the five default-block checks can never fire | misleading Assert log on bad data; dead checks | name the file and the real error |
| Z24-B9 | `ChargedItemEffectDataBox<T>::cideb_Load` FUN_00450070 / FUN_005af300 / FUN_005af4d0 / FUN_005af6d0 | the "Same Handle" check compares row i with rows 0 … i−2 (`j < i − 1`, confirmed in the disassembly at 0x5af3e8 … 0x5af42e) | a Handle equal to the previous row's passes; 2016 ChargedEffect.shn rows 1709 / 1710 share Handle 1738, and `cideb_FindFromHandle` maps a stored buff 1738 always to the first one (`Cos_Uniform_USA_Boots01_2`, not `Hat_Uniform01`) | `j < i` |
| Z24-B10 | `GatherProduce::GatherTable::gt_Load` FUN_0046a660 | an unknown `NeededTool<k>` name becomes tool 0xFFFF ("no tool") without a message (`rb_Load` exits on an unknown raw) | 2016: the Mining rows with `MinerPickaxe` / `AlchemistPickaxe` (not in ItemInfo) need no tool; `sp_GatherCheck` stops at them with picker 0xFFFF and mining is refused with 0x0B0C, so a player holding only a `Kebypick` (the later row) can never mine | fatal on an unknown tool, or skip the row *(inferred)* |
| Z24-B11 | `ItemGroupClassifier::igc_Load` FUN_00490330 | after the "Invalid Item index" assert of the inlined `itemdatabox[id]` the null index is dereferenced (`ix.dataserv`); the "invalid index" check of `igc_Store` FUN_004900f0 can never fire | latent: the index is built from the same rows, so the assert cannot fire in a loaded zone | skip the row |
| Z24-B12 | `ItemDataBox::ReadData` FUN_006494f0 (via the ctor FUN_0064b5d0) | dead code (the only `ItemDataBox` is built with path −1); it leaves `MovingShot`, `AttackAngle`, `HitTimeArray`, `eDelConditionType`, `pBuyItemData` of every index entry uninitialised and loads no ItemInfoServer / option rows | none in 2016 (never runs) | remove, or share `idb_Load`'s index setup |
| Z24-B13 | `ChargedItemEffectElement::ciee_Activ` FUN_00450550 | EE_EXP_RATE (and FEED, STATUS) assign `EffectValue` instead of taking the maximum like every other rate | with two exp buffs active, the one in the later list slot wins, which may be the weaker one (slots are reused, not in buy order); `uib_CanUseItem` only refuses a buff weaker than the current total | max, as for the other rates |
| Z24-B14 | `ciee_Free` FUN_00450a50 | 0x9002 NC_CHARGED_RESETBUFF_CMD `nUserNo` = `so_GetCharRegistNumber` (the character number again) | the Character server's log 0x043A NC_LOG_GAME_CHARGED_BUFF_CLR records the character number as the user number (D05) | the account number |
| Z24-B15 | `UseItemChargedBuff::uib_CanUseItem` FUN_00598310 | EE_MOREBOOTHSLOT is usable only while `cec_StreetBoothSlot + v < 20`; `ciee_Activ` caps the sum at 20 (inventory / storage tests match their caps 6 / 2) | 2016 (v = 10): a second booth-slot buff is refused although the cap would allow it | `< 21` (≤ 20) |

## 9. Not reconstructed / uncertain

- §6.7 `ciee_AfterLoginComplete` passes the remaining time in ms (`ftol(seconds × 1000.0)`, low 32 bits) to
  `so_AbnormalState_Set`: a 720 h SETABSTATE row gives up to 2.59·10⁹ ms, above 2³¹; whether the abstate keeps it as
  unsigned (then fine up to 49.7 days) or signed was not checked in `so_AbnormalState_Set` (Z03 / Z22). Abstates set
  by such a buff during play (`so_ply_ChargedBuff`, Z12 §6.8) were not compared.
- §6.7 `ChargedEffectChatColorItemFree::ceccif_All` is stored but never read; `so_ply_ChatColorInfoClear` does not tell
  the client the reset colours (the client presumably learns them at the next 0x3056 / login) *(inferred)*.

- §7.1 `ccdb_BitToClass` relies on the CRT `log` / x87 rounding; the exactness claim is checked with IEEE doubles in
  Python, not on the original CRT (an off-by-one would only matter for bits whose double logarithm lands just below n).
- §7.2 the draw order inside a group depends on the CRT `rand` state at stage home (one `cs_Suffle(1)` per insert);
  whether `srand` ran before is not checked. §7.3 duplicate names in `idb_Load`'s trie *(inferred)* from the same
  `bt_Insert` loop; `idb_Load` itself is not documented here (§10).

- §6.2 "no reader found" (ChargedEffect none; MiniHouse DummyType, Backimage, Casting; MiniHouseFurniture
  FurnitureType, Backimage, WALL/BOTTOM/CEILING, IsAnimation, Weight, Grip, MHEmotionID; RIDING Name, BodyType, Shape,
  Texture, InitHgauge, icons, DummyA/B) is the same `->member` name search as §5.2; members shared by several row
  structs were assigned to a struct by the function's subsystem *(inferred)*. EE_COSTUM as the item's own lifetime
  is *(inferred)* from the item classes that carry it.

- §5.2 "no reader found" (MoverAbility WC/MA/AC/MR/TH/TB, MoverHG CreateHG) comes from a search for `->member` in the
  PDB decompile of the whole zone; a read through a raw offset or a copied row would be missed (Z13 reads the bodies).
  `DurationHour` as item lifetime is *(inferred)* from its name and its reader `sp_MoverSystem_SummonItem`.
- §1.4 client side of 0x3029: what object vt 0xc4 and FUN_0068fc00 do is *(inferred)* from the call shape (effect by
  item name); C01 lists only the two reads.
- Z24-B2's "item 0" depends on `itemdatabox` living in zero-initialised static storage (no write to
  `sii_JustReviveItem` other than the one in `idb_Load` was found).

## 10. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| `UseItemByTable` / actor bodies (`uib_CanUseItem`, `uib_Effect` of every `ui_*`) | Z04 §6.3 (done; lists every actor with its functions) | this item only builds the table; only the "by abstate" actor (StateItem's consumer) is documented here because Z04 cites just its CanUse |
| `sp_MysteryVaultMakeItem` FUN_005658f0 (the roll) | Z05 §9.8 (done) | the consumer of §4's map |
| `MagicContainer::mc_Load` FUN_0049c7f0 (TreasureReward.txt) | Z09 §10.10 (done; documents the file, both tables, the load checks and the `UsePresentBox` / `UseSkill` writes) | writes into `useditemeffect`; listed in §1.5 only |
| Mover consumers: `ShineMover` (`so_smv_SummonMover` 0055fdf0, `so_smv_GetOn` 0055f380, `smv_FoodEat` 0055f110, `so_smv_CanUseFeedItem` 0055f840, `so_smv_Feeding` 0055f8e0, `so_MaxHP` / `so_SetHP` / `so_GetLevel` / `so_BodySize` / `so_WalkSpeed` / `so_RunSpeed` / `so_smv_GetMoverID`, `smv_RegenComplete` 00441fd0), player `sp_MoverSystem_Cast` / `SummonItem` / `MapLogin`, `sp_HorseItemSave`, `RidingInitHP` / `RidingInitHungry`, `MoverSkillList::msl_Store` 00449190 | Z13 (open; plan line 16 "Mounts: mover creation …, hunger") | they read the rows this item loads (§5.2 lists which member each reads); the mover lifecycle is Z13's |
| `UseItemRide::uib_DirectUse` FUN_005995b0, `UseItemHorseFood` actor | Z04 §6.3 (done; actor table row "UseItemRide" / "UseItemHorseFood") | the ride dispatch is summarised in §5.4 because it is `mvdb_GetMoverType`'s only caller; `sp_HorseCast` / `sp_MoverSystem_Cast` bodies are Z13 |
| `sp_NC_ITEM_MOVER_UPGRADE_REQ` FUN_0051c850 (reads `pHG.FeedType`) | Z04 §9.5 (done) | handler; this item only documents the row it reads |
| `ItemDataBox::idb_Load` FUN_00649780 (ItemInfo, ItemInfoServer, GradeItemOption, ItemDropLog, ItemSort, CollectCardMobGroup, ItemMoney: 1036 decompiled lines), `idb_MakeSpecialID` | new item **Z25** (added by Z24) | Z04 (done) uses the index (§1.2) but does not document the loader; Z01 §2.3 lists it in one row; `ReadData` (the dead stand-alone reader) is §7.3 |
| Mini-house table consumers: `sp_MiniHouseActivCheck` 00534fe0, `mhs_Init` 00534a30, `so_mh_CreateFurniture` 00544f00, `so_mh_SaveMHInven` 005435d0, `so_mh_Move2MiniHouseFurniture` 005354a0, `smh_SendFurnitureInfo` 00546930, `smh_FurnitureActiveCheck` 005472e0, `so_mh_CanFurnitureEmotion` 005485c0, endurance `so_mh_EndureGradeDownTimeUpdate` 00547f60 / `so_mh_DoingEndureGradeDown` 00548270 / `so_ply_MH_FurnitureEndureUpdate` 00570fe0 / `so_ply_MH_FurnitureEndureUse` 00571550, dice `so_mh_DiceTaiSai_GetExpectIncomeMoney` 00516970 / `sp_DiceTaiSaiItemIDChange` 00514b40 | Z13 (open; plan line 11 "furniture create/rearrange/delete …, endurance, … the in-house dice game state, furniture emotions") | they read the MiniHouse / MiniHouseFurniture rows (§6.2 lists which member each reads); the house object is Z13's |
| Riding.shn horse consumers: `sp_HorseCast` 0045e0e0, `sp_HorseOn` 0045f270, `so_ply_HorseFeed` 0045eaa0, `sp_HorseNotHungry` 0045d460, `sp_GetHorseFeed` 0045d510, `sp_NC_ACT_RIDE_FEEDING_REQ` 0045f9e0 (Z02 §9.1), `sp_RideInitialize` 0043d140, `UseItemRide::uib_CanUseItem` 005988b0 | Z13 (open; plan line 16 "Mounts: …, hunger (link to Z02 §9.1)") and Z04 §6.3 (actor) | readers of the RIDING rows (§6.2); the ride lifecycle is Z13's |
| Charged-buff consumers by item: `sp_NC_ITEM_WEAPONENDURE_CHARGE_REQ` 00519470, `…SHIELDENDURE…` 00519a10, `sp_NC_ITEM_CHAT_COLOR_CHANGE_REQ` 0051e580, `sp_NC_ITEM_TERMEXTEND_REQ` 0051eb40, `UseItemChargedBuff::uib_CanUseItem` 00598310 | Z04 (done; cites each handler) | handlers that look up a ChargedEffect row by item; this item only documents the table |
| `so_CharChargedBuffData` 0044e1e0, `so_ply_ChargedBuff` 005970c0, `ciee_Free` 00450a50, `sp_ChargedItemTest` 00451360 (GM) | Z12 §6.8 (done), Z11 (done) | stored charged buffs → `cideb_FindFromHandle` |
| `WeaponCostumInitCharge` 00517d40 (EE_WEAPON_MAXENDURE rows) | Z17 (open; plan "Costume weapon/shield charges … how charges are refilled") | costume charge consumer |
| Gathering / production consumers: `sp_GatherCheck` 0046ad70, `so_mob_CanGathered`, `sp_NC_ACT_PRODUCE_CAST_REQ` 0046cf90 | Z02 §8 (documented there) | readers of `gt_Array` / `RecipeBook::operator[]`; §7.4 documents the tables |
| `smo_ply_ItemProduce` 0046c2d0, `ItemProducer::ip_WhereProductStore` 0046b880 / `ip_ProductExecute` 0046bf80 | Z07 §11 (done, documented there) | production result; reads `ProductIndex` |
| `csl_PreProduceCheck` 0046ab70, `csl_GetDelayGroup` 00448950 | Z23 (open; plan title "CharaterSkillList … delay groups … mastery") | read `rb_Array` / the mastery columns |
| Class checks by `UseClass`: equip handlers 0052b110 / 0052b8d0 / 0052c5b0 / 0052d020, `sp_ItemUseReq_Inven` 0053f5e0, `sp_UseItemMonimon_UseItem` 00561b80, booth search 00439c70, `ac_AllLearnSKill` 004212e0 | Z04 (done; equip / use handlers), Z06 §2.6 booth search (done), Z11 §9.3 (done) | callers of `ccdb_CheckClass` / `charclassdatabox` (§7.1 lists them); the class-change pair is cited from Z04 §12.10 / Z15 §6.5 |
| `igc_Getitem` 004903e0, `igc_ChargedDuringUse` 00490630, `CardStack` helpers | Z09 §28.10 / §10.10 (done), Z04 (done), Z11 §9.3 (done) | readers of §7.2's groups |
| W05 §3.2 "bit 0 = Fig … bit 26 = Sav" for the WM's `ccdb_UseClassTypeToBit` FUN_00465a90 | this item §7.1 (correction; recorded in `docs/knowledge/Z24.md`) | same code as the zone: Fig is bit 1 |
| Charged-buff effect application `ciee_Activ` 00450550, `ciee_AfterLoginComplete` 00417910, `ChargedEffectChatColorItemFree::lid_Call` 00450fe0, `sp_CanChargedEnchant` 00418080, `ciee_Routine`, `ciee_Free`, the routers, `so_ply_ChatColorInfoClear`, `sp_RemoveEE_SETABSTATE`, `UseItemChargedBuff::uib_CanUseItem`, `sp_ChargedItemLimitCheck` / `sp_ItemDelete` | this item §6.7 | documented in the sweep part (small: they read the §6.2 columns; the per-minute caller is Z09 §2.4, the DB / WM side D03 §9 / W04 §11) |
| `so_DiceTaiSaiChargedItemLimitCheck` FUN_00517770 (dice-game item expiry, calls `sp_DiceTaiSaiItemIDChange`), the other `ShineMiniHouse::so_mh_*` functions that name MiniHouse in their strings (portal, kick-out, title, arrange mode, `so_mh_BuildingMiniHouse` 00548810, …) | Z13 (open; plan line 11 "the in-house dice game state", mini-house object) | house object and dice game; they do not read the loader's tables beyond the §6.2 rows listed above |
| `sp_DestroyItem` overloads (00527870 used by `sp_ItemDelete`) | Z09 l.7976 (one line) and Z18 (open; plan "`sp_DestroyItem` overloads") | item deletion body |
