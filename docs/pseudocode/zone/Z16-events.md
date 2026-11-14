# Zone server: kingdom quest element and guild tournament system (Z16)

Source: the 2016 zone (`Files/Server/2016/w00_Zone00/5ZoneServer2.exe`), read in the PDB export
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). Class, member and global names are from the
NA2016 zone PDB (same build) *(pdb2016)* unless marked otherwise; vtable slots were resolved with `rtti.py` against the
2016 exe. Evidence markers as in `AGENTS.md`: *(pdb2017)*, *(inferred)*, *(fh-doc)*; nothing here is *(captured)*.

This item takes the internals Z08 left out (Z08-content §4 and §8, §15). Z08 documents the packet handlers at summary
level; the blocks below re-read them in full and correct Z08 where marked. The Pine map-script nodes and the Lua
functions that only *call* the KQ / GT objects are Z09's (§22.3, §24.7–§24.8, §25.6–§25.7, §26.1, §28.12); the GM
commands are Z11's (§5.5, §6.3, §7.2, §8.4). Layouts: `docs/protocol/annotations/Z16.json`.

## 1. Kingdom quest: data structures and tables

A kingdom quest (KQ) is a scheduled event owned by the WM (W04 §6). The WM builds it on one zone (0x580D), starts it with
the joiner list (0x580F), may remove single joiners (0x583B) or kick banned players (0x5833) and destroys it (0x5811).
The zone ends it itself through the map script (`endofkq`, Z09 §26.1) or the GM (`&endofkq`, Z11), which send 0x5810 to
the WM.

### 1.1 Globals

| Global | Address | Type / size | Use |
|---|---|---|---|
| `kqcontainer` | DAT_0d624a00 | `KingdomQuest::KingdomQuestContainer` (0x4e3a8) = `List<KQElement>` of 300 + `KQElement kqc_array[300]` (+0x18) | running KQs (Z08 named it `g_KingdomQuests`) |
| `g_KQContributeList` | DAT_0d67a048 | `KQContribute::KQContributeList` = `std::vector<PlayerList>` (reserve 30) | mob kills per KQ and player |
| `kqentrance` | DAT_0083c818 | `KingdomQuestEntrance` (0xfe08): 128 entrance lists + `BitANDInt kqe_Number` (mask 0x7f, starts at 0) | joiner lists waiting to be pulled in |
| `kqgate` | DAT_0d672da8 | `KingdomQuestGate` (0x7008): `KingdomQuestGateKeeper kqg_keeper[256]` + `BitANDInt kqg_keeperpoint` (mask 0xff) | the timed pull-in events |
| `sec` | DAT_0083c798 | `int[5]` = {0, 2, 5, 7, 10} | pull-in delays in seconds |
| `notfound` / `notempty` | DAT_0083c788 / DAT_0083c790 | `u16[4]` = {0x984…0x987} / {0x988…0x98b} | per-map-slot error codes of 0x580E |
| `gKQItemDataBox` | DAT_13388848 | `KQItemDataBox` = `std::map<u16 itemId, KQItem>` | `KQItem.shn` (§1.6) |
| `kqreward` | DAT_0d67a058 | `KQRewardDataBox` = `BinaryDataBox<KINGDOM_QUEST_REW>` | `KingdomQuestRew.shn` (§3) |
| `kqscriptmanager` | DAT_150e04e8 | `KQScriptManager` | dialog-string files; despite the name general script data (Z09 §22.6) |
| `zonevent` | DAT_13388e70 | `EventReserveContainer` | zone timed-event queue the gate keepers are put in (Z09 §1.4) |

Debug log channels (all off unless enabled in the zone's debug config): `KQLogging`, `KQEntryCheckLog`, `KQEntryLog`,
`KQRankingLog`, `KQRewardLog`, `KQLogoutLog`, `KQTournamentLog`, `GuildTournamentLog`.

### 1.2 The KQ element

```pseudo
KingdomQuest::KQElement {                                     # 0x42c bytes, one per running KQ
    u32 kqe_Stop                +0x000   # end tick = LimitTime · 600 + now (set by kqe_QuestStart; 100-ms ticks)
    PROTO_KQ_INFO kqe_kqinfo    +0x004   # copy of the WM's 0x580D body (0x179 bytes, below)
    KQElementMap kqe_mapinfo[4] +0x180   # 0x24 each: PROTO_KQ_MAP_INFO mapinfo (0x1a) +0, FieldMap* fld +0x1c,
                                         #   MapInfo* mapinf +0x20 (row of MapInfo.shn for MapBase)
    PineScriptToken kqe_Script  +0x210   # 0x100 bytes: ScriptLanguage (film / script name)
    PineScriptToken kqe_InitValue +0x310 # 0x100 bytes: ScriptInitValue (film arguments)
    KQPlayerInfoList kqe_PlayerList +0x410   # joiners (§1.3)
}
PROTO_KQ_INFO : PROTO_KQ_INFO_CLIENT {                         # 0x179 bytes; the first 0x8d bytes are also sent to clients (W04)
    u32 Handle +0; u8 Status +4; u16 NumOfJoiner +5; u16 ID +7; char Title[64] +9; u16 LimitTime +0x49 (minutes);
    i32 StartTime +0x4b; tm tm_StartTime +0x4f; u16 StartWaitTime +0x73; u8 MinLevel +0x75, MaxLevel +0x76;
    u16 MinPlayers +0x77, MaxPlayers +0x79; u8 PlayerRepeatMode +0x7b; u16 PlayerRepeatCount +0x7c;
    u8 PlayerRevivalMode +0x7e; u8 PlayerRevivalCount +0x7f; u16 DemandQuest +0x80, DemandItem +0x82;
    i64 DemandClass +0x84; u8 DemandGender +0x8c
    -- server part --
    u8 NextStartMode +0x8d; u16 NextStartDelayMin +0x8e; u8 RepeatMode +0x90; u16 RepeatCount +0x91;
    u16 RewardIndex +0x93; u16 DemandMobKill +0x95; i32 ScheduleTime +0x97; tm tm_ScheduleTime +0x9b; u8 RunCounter +0xbf;
    PROTO_KQ_MAP_INFO MapLink[4] +0xc0 { u8 MapIndex +0; Name3 MapBase +1; Name3 MapName +0xd; u8 MapClear +0x19 };
    u8 ScriptLanguage[32] +0x128; u8 ScriptInitValue[32] +0x148; u8 IsTeamPVP +0x168;
    SHINE_XY_TYPE TeamRegenXY[2] +0x169 (u32 x, u32 y)
}
```

`MapBase` is the map *kind* (row of `MapInfo.shn`, e.g. `KDEddyHill`), `MapName` the map *instance* (a `FieldMap` with that
`fm_MapID`, e.g. `KDEddyHill03`; the instances come from `KingdomQuestMap.shn` on the WM side, W04). Z08 §4 wrote that
the instance is searched by MapBase: it is searched by **MapName**; MapBase only selects the MapInfo row. A `FieldMap`
carries `fm_KQHandle` (+0x3c, −1 = none) and `fm_KQID` (+0x40, 0xFFFF = none); `FieldMap::fm_GetKQhandle` FUN_00419370
returns the handle. `FieldOption::FieldAttr.KingdomQuestMap` (+0x36 of `fm_FieldOption`, from `FieldList` data) marks a
map kind as a KQ map.

```pseudo
KingdomQuestContainer::KingdomQuestContainer()                 @ FUN_00499a40
    List<KQElement>::l_MakeList(300); every kqc_array[i].kqe_kqinfo.Handle = −1; list slot i → &kqc_array[i]
KingdomQuestContainer::kqc_SearchHandle(handle, &slot) → KQElement*   @ FUN_004954f0
    walk the used slots; first element with kqe_kqinfo.Handle == handle (slot index returned); none → null
KingdomQuestContainer::kqc_MapUseCheck(Name3 mapName) → 1 free / 0 in use    @ FUN_00495710
    l_4AllInList with ListIteratorKingdomQuestMapFind{mapName}:
    ListIteratorKingdomQuestMapFind::lid_Call(el)               @ FUN_00495620
        stop (return 0) when one of el.kqe_mapinfo[0..3].fld is a map whose fm_MapID == mapName; else continue (1)
    # only slots with a local instance (fld ≠ null) are compared
KQElement::KQElement / ~KQElement                              @ FUN_00422e40 / FUN_00422ef0   (constructs the 4+4 map
    records, the two script tokens and the player list; destructor in reverse)
KQElement::operator=(other)                                    @ FUN_00499140   (field-wise copy incl. the list header;
    no caller found outside the container code)
PROTO_KQ_INFO::operator=                                       @ FUN_00494f90   (plain copy of the 0x179 bytes)
KQElement::kqe_GetKQLimitMin() → LimitTime                     @ FUN_005e4d20
    # profiler string "KingdomQuest::KQElement::kqe_SetLimitTime_void_" (the plan's `kqe_SetLimitTime`); only caller:
    # Lua cGetKQLimitSecond (§3)
KQElement::kqe_ReviveNumber(&reviveHere) → revives             @ FUN_00496b90
    switch PlayerRevivalMode:
        1: revives = 99999 (unlimited), reviveHere = 0
        2: revives = PlayerRevivalCount, reviveHere = 0
        3: revives = 99999, reviveHere = 1
        4: revives = PlayerRevivalCount, reviveHere = 1
        other: revives = 0, reviveHere = 0
    # KingdomQuest.shn 2016 uses mode 1 (29 rows, count 0) and mode 4 (28 rows, counts 3/5/8)
```

`reviveHere = 1` makes the death-menu revive (`sp_ReviveReqProcess`, Z07 §3.1) put the player back at the death spot
instead of the map's regen point; `revives` is compared with the player's knock-down count there and in §2.4.

### 1.3 Joiners: `KQPlayerInfoList`

```pseudo
KingdomQuest::KQPlayerInfoList : CommonList<KQPlayerInform>    # 0x1c; CommonList of 100 (FUN_004999e0)
KingdomQuest::KQPlayerInform {                                  # 0x38
    u32 kqpi_PlyRegnum +0; i32 kqpi_KnockDown +4; BattleStat kqpi_BattleStat +8 (0x2c, §3);
    u8 kqpi_IsKQJoiner +0x34; u8 kqpi_nTeamType +0x35 (0 red, 1 blue, 2 none)
}
search key: KQPlayerInform::regnumcomp (a.kqpi_PlyRegnum − b.kqpi_PlyRegnum)  @ FUN_00495250 (ListSearchSame, linear)

kqpil_InsertPlayerInfo(charNo, team, isJoiner) → ok            @ FUN_00498f30
    charNo == −1: return 0
    already listed: return 1                                    # the old record (team, knock-downs, stats) is kept
    no free slot: return 0
    new record: charNo, KnockDown 0, BattleStat zeroed except bs_ClearAtLink (+8, left as it was) and
        bs_Score = 10000 (+0x30); kqpi_IsKQJoiner = isJoiner; kqpi_nTeamType = team; return 1
kqpil_DeletePlayerInfo(charNo) → ok                             @ FUN_00499030
    charNo == −1 or not listed: return 0;  l_Free (fails: assert "…kqpil_DeletePlayerInfo : l_Free fail")
kqpil_IsKQJoiner(charNo) → kqpi_IsKQJoiner of the record, 0 when not listed   @ FUN_00498e90
kqpil_StorePlayer_GetKnockDownNumber(charNo) → kqpi_KnockDown, 99999 when not listed   @ FUN_00498ba0
kqpil_PlayerInformFunc(memberFn, charNo) → memberFn(record), 0 when not listed   @ FUN_00498c40
    member functions used:  kqpi_GetTeamType FUN_00495260 (team), kqpi_KnockDownGet FUN_00496e50,
        kqpi_KnockDownPlus FUN_00496de0 (++, returns new), kqpi_KnockDownMinus FUN_00496d70 (−−, returns new)

ShinePlayer::sp_MyKQElement(p) → KQElement*                      @ FUN_00496c50
    p.so_Field (+0x7a) with an fm_FieldOption and fm_KQHandle ≠ −1: kqc_SearchHandle(handle)
        (missing: assert "…sp_MyKQElement : Cannot found KQ Element"); else null
ShinePlayer::sp_KQElementFunction(p, memberFn) → int            @ FUN_00499710
    el = sp_MyKQElement(p); none: 0; else kqpil_PlayerInformFunc(memberFn, p.charNo)
    # callers: ShinePlayer::so_KilledBy (KnockDownPlus, Z03 §7.2), sp_ReviveNow (KnockDownMinus, Z03 §7.3),
    #          sp_ReviveReqProcess (KnockDownGet, Z07 §3.1)
ShinePlayer::so_ply_IsKQJoiner (vt 0xe10)                       @ FUN_005615d0
    el = sp_MyKQElement(p); el ? kqpil_IsKQJoiner(p.charNo) : 0      # caller: Lua cIsKQJoiner (§3)
ShinePlayer::so_GetBattleStat (vt 0x428)                        @ FUN_00498d60
    el = sp_MyKQElement(p) and p listed: &record.kqpi_BattleStat; else &ShineObject::so_DefBattleStat
```

So a skill revive (`sp_ReviveNow`) gives the knock-down back: only the deaths that end in the death-menu revive or in a
logout count against `revives`.

### 1.4 Mob kills: `KQContribute::KQContributeList`

```pseudo
KQContributeList { std::vector<PlayerList> kqcl_List }          # global g_KQContributeList, reserve 30
PlayerList { u32 pl_KQHandle +0; std::vector<PlayerContribute> pl_PlayerList +4 }   # 0x14
PlayerContribute { u32 pc_ChrRegNum; i32 pc_MobKillNumber }                       # 8

kqcl_FindKQ(handle) → PlayerList* (linear; null when absent)    @ FUN_00499ca0
kqcl_NewKQ(handle)                                              @ FUN_0049a770
    exists: clear its player vector (and set the handle again); else push_back {handle, empty}
kqpl_EndOfKQ(handle)                                            @ FUN_0049a500
    std::remove of every PlayerList with that handle, then erase       # the player vectors are not freed (std::_Remove
                                                                       # moves entries; erase of the tail)
kqcl_KQListNumber() → number of lists (vector size / 0x14)       @ FUN_00499bd0   (GM &amibusy, Z11 §6.6)
kqcl_GetMobKill(handle, obj) → kills of obj.charNo in that KQ, 0 when either is absent   @ FUN_00499d80
kqcl_SendMobKill(handle, player, demand, add)                    @ FUN_00499ff0
    list = kqcl_FindKQ(handle); none: return                     # nothing sent either
    the player's entry: kills += add; else push {player.charNo, add} (kills = add)
    → player (game stream): 0x5822 NC_KQ_MOBKILLNUMBER_CMD { u16 CurrentMobKill = kills, u16 DemandMobKill = demand }
```

Who adds kills (`ShineMob::so_KilledBy` FUN_00432760, the KQ branch Z03 §8.1 summarises):

```pseudo
    h = mob.so_Field.fm_KQHandle; h == −1 or no element: skip
    party = killer.vt 0x550 (party number)
    party == 0xFFFF:  kqcl_SendMobKill(h, killer, el.DemandMobKill, 1)
    party < 4000 and 2 ≤ members ≤ 5: for each member m of the zone's party record (pm_FindMember) that exists,
        is alive (mode ∉ {0, 3}) and is within 1000 units of the mob (distance² < 1,000,000):
        kqcl_SendMobKill(h, m, DemandMobKill, 1)                # every near member gets the full kill
    party ≥ 4000: assert "…Too large party handle"; members < 2 or > 5: assert "…Invalid party member number";
        both then **return from so_KilledBy** (original bug) Z16-B1: quest progress, the hit list, experience and
        the drop of that mob are skipped
```

The kill counter is per KQ and character, kept until the KQ ends, and counts kills of a non-joiner as well. At every map
login on a KQ map the player gets the current count (`kqcl_SendMobKill(h, p, DemandMobKill, 0)`, §2.4). It is read by the
Pine `questmobkill` / `revival` nodes and the reward helpers (Z09 §25.6, §3 below).

Client (GameFrameWork `ON_NC_KQ_MOBKILLNUMBER_CMD` FUN_0049bb30): shows `DemandMobKill − CurrentMobKill` (0 when ≤ 0)
as the required kills in the KQ time window (`KQuestTimeWin::SetRequiredKillMobNums`).

### 1.5 Entrance lists and gate keepers

```pseudo
KingdomQuestEntrance { struct { i32 joinnumber; i32 entrynumber; PROTO_NC_KQ_JOINER players[100] } kqe_entrancelist[128];
                       BitANDInt kqe_Number }
PROTO_NC_KQ_JOINER { u32 chrregnum; u8 nTeamType }               # 5 bytes, packed

KingdomQuestEntrance::operator[](startCmd) → slot                 @ FUN_00496150   # "kqe_newentrance"
    slot = (kqe_Number + 1) & 0x7f; n = NumOfJoiner; n > 100: assert "…Too many entrance", n = 100
    list[slot] = {joinnumber n, entrynumber 0, players = the first n joiners}; return slot
    # ring of 128: the 129th start reuses slot 1 without any check
kqe_sort(slot) / kqe_search(&key, slot) / kqe_entry(slot)        @ FUN_004960a0 / FUN_004960f0 / FUN_004950f0
    qsort / bsearch of players by kqe_Compare (FUN_00495140: b.chrregnum − a.chrregnum, signed: descending);
    kqe_entry: entrynumber += 1; slot > 127: assert "…Subscript over"

KingdomQuestGate::KingdomQuestGateKeeper : EventReserveBase {    # 0x70; KingdomQuestGateKeeper() FUN_00495150
    i32 kqgk_entrancehandle +4; NPCManager::LinkInformTemplete kqgk_lnkinf +8 (0x61); u16 kqgk_QuestID +0x6a;
    u32 kqgk_QuestHandle +0x6c }
LinkInformTemplete { u8 index[20]; char linktoserver[33] +0x14; char linktoclient[33] +0x35; u32 coordx +0x56,
                     coordy +0x5a; u16 direct +0x5e; u8 Party +0x60 }
```

## 2. KQ lifecycle

### 2.1 Make: 0x580D NC_KQ_W2Z_MAKE_REQ (WM → zone)

```pseudo
0x580D NC_KQ_W2Z_MAKE_REQ { PROTO_KQ_INFO KQInfo }               @ FUN_00497790 (wms_NC_KQ_W2Z_MAKE_REQ;
                                                                   log texts "…wms_NC_KQ_W2Z_MAKED_CMD")
    reply buffer: 0x580E NC_KQ_Z2W_MAKE_ACK { u32 hquest = Handle, u16 err }   (8 bytes; sent to the WM on every
        exit except the one noted below)
    kqc_SearchHandle(Handle) exists: err 0x982 (ERR_KINGDOMQUEST_MAKE_DUPLICATEHANDLE); reply; return
    book = ScenarioBookShelf::sbs_GetScenarioBook(ScriptLanguage[32])          # Z09 §27
    none: err 0x98C (ERR_KINGDOMQUEST_MAKE_SCRIPTNOTFOUND), assert "…Script not found"; reply; return
    local = 1
    for i in 0..3, link = MapLink[i]:
        link.MapName empty (== the static empty name `nousemap`):
            i == 0: err notfound[0] = 0x984; reply; return
            else: stop the loop
        kqc_MapUseCheck(link.MapName) == 0: err notempty[i] = 0x988+i, assert "Submap in use"; reply; return
        inst = the FieldMap in fieldlist with fm_MapID == link.MapName (ListSearchSame, fm_Compare), or null
        row  = MapInfo row of link.MapBase (mapdatabox B-tree; index ≥ mdb_maxmapid → none)
        slot[i] = {link, inst, row}
        row missing: err notfound[i] = 0x984+i ("Not found2"); reply; return
        inst == null: local = 0; continue                         # the map instance lives on another zone
        local = 1                                                 # (set again for every local map)
        inst.fm_KQHandle ≠ −1: err notempty[i] = 0x988+i ("Not empty2"); reply; return
        inst.fm_KQHandle = Handle; inst.fm_KQID = ID
        link.MapClear: FieldMap::fm_ClearObject(inst, 0x3b6)      # object kinds by mask (Z09 §24.8)
    el = container.New(); none: err 0x983 ("Buffer full"); reply; return
    el.kqe_kqinfo = KQInfo; clear el.kqe_PlayerList (ListEraser); el.kqe_mapinfo = slot[0..3] (0x90 bytes)
    el.kqe_Script = PineScriptToken(ScriptLanguage); el.kqe_InitValue = PineScriptToken(ScriptInitValue)
    if local == 1: err 0x981 (ERR_KINGDOMQUEST_MAKE_NOERR); reply
    KQContribute.kqcl_NewKQ(Handle)
```

- `local` holds the state of the **last** listed map, not "all maps local" as Z08 §4 wrote: the success reply is sent
  exactly when the last non-empty map slot has an instance on this zone. When it has none, the KQ is built but the WM
  hears nothing from this zone (original bug) Z16-B2 (refines Z08-B8; the WM side is W04 §6).
- A map claimed by an earlier loop pass keeps `fm_KQHandle` / `fm_KQID` (and was already cleared) when a later check
  fails (map 1 in use / not found / not empty, or the container is full): no element owns it, `wms_NC_KQ_W2Z_DESTROY_CMD`
  cannot find it, and every later KQ on that instance fails with "Not empty2" until the zone restarts
  (original bug) Z16-B3.
- The element is made even when no map is local (`kqe_mapinfo[0].fld` null): the start then pulls nobody in (§2.2).

Error codes (`KINGDOMQUEST_MAKE` errors; no client text, the WM consumes them): 0x981 ok, 0x982 duplicate handle,
0x983 container full, 0x984…0x987 map slot 0…3 not found (empty name for slot 0, or MapInfo row missing), 0x988…0x98B map
slot 0…3 in use, 0x98C script not found. Strings in the binary also name ERR_KINGDOMQUEST_MAKE_TOOMANYQUEST (logged by the
0x983 path).

### 2.2 Start: 0x580F NC_KQ_W2Z_START_CMD (WM → zone)

```pseudo
0x580F NC_KQ_W2Z_START_CMD { PROTO_KQ_INFO KQInfo; u16 NumOfJoiner +0x179; PROTO_NC_KQ_JOINER JoinerArray[] +0x17b }
        @ FUN_00499240
    el = kqc_SearchHandle(KQInfo.Handle); none: assert "…Not exist KingdomQuest"; return
    if el.kqe_mapinfo[0].fld (map 0 is local):
        KQElement::kqe_QuestStart(el)                                     @ FUN_004953e0
            el.kqe_Stop = el.LimitTime · 600 + now                        # minutes → 100-ms ticks
            for each map slot with a local instance f:
                f.fm_Multiflex.cc_DropFilm(kqe_Script)                    # stop a film of that name (Z09 §27.5)
                f.fm_BlockInfo.mbi_DoorBlockInform.mda_CloseAllDoor()     # FUN_0049e1e0: every door → DA_CLOSE
                                                                          # ("…mda_CloseAllDoor : Close error")
                f.fm_Multiflex.cc_PlayFilm(kqe_Script, kqe_InitValue, f)  # the KQ map script starts
        for each joiner j: el.kqe_PlayerList.kqpil_InsertPlayerInfo(j.chrregnum, j.nTeamType, isJoiner 1)
    slot = kqentrance[this body]                                          # §1.5 (≤ 100 joiners)
    link = { linktoserver = el map 0 MapName, linktoclient = map 0 MapBase, coordx/coordy = map 0 MapInfo RegenX/RegenY }
        # index[20], direct and Party stay uninitialised stack bytes; so_LinkTo reads only names and coordinates (Z09 §17.7)
    for d in sec[] = {0, 2, 5, 7, 10}:
        k = kqgate.kqg_keeper[++kqg_keeperpoint & 0xff]                   # ring of 256, no in-use check
        e = zonevent.New(); none: assert "…EventReserve error"; stop
        k = { entrancehandle slot, kqgk_lnkinf link, QuestID = ID, QuestHandle = Handle }
        e = { time = now + d · 10, object = k, +0xc = 0 }                 # fires KingdomQuestGateKeeper::erb_happen
```

When map 0 is on another zone the joiners are not inserted on this zone, but the five gate-keeper events still run
(and link local players to map 0's name, i.e. to the other zone, Z01 §7.1).

### 2.3 Pull-in: the gate keeper and the client's entry answer

```pseudo
KingdomQuestGate::KingdomQuestGateKeeper::erb_happen(k)          @ FUN_00496280 (zonevent timer)
    list = kqentrance.kqe_entrancelist[k.entrancehandle] (slot > 127: assert "…kqe_allentry : Subscript over")
    list.joinnumber ≤ list.entrynumber: return                   # everybody pulled in already
    sort list; el = kqc_SearchHandle(k.QuestHandle); none: assert "…pKQElement NULL"; return
    for every player p of the zone (shineobjmanager list 2):
        mode 0 or 3 (not in a map / dead): log only; next
        charNo == −1: assert "…Invalin registnumber"; next
        j = kqe_search(p.charNo); none: next
        erb_CheckLinkMap(p) false: next                           # below; retried at the next tick
        mode 5 (vending booth): p ← notices ScrString "KQEntryInCamp0", "KQEntryInCamp1" (so_ply_Notice, vt 0x784);
            log " is in Booth"; next (not marked: retried)
        mode 4 (sitting): stand up (vt 0x488 so_ply_ReinforceFoldtent)
        kqe_entry(slot)                                           # counted before the link is tried
        p.so_GetCharacterTitle().CT_KQJoin()                      # FUN_005cbf90, title counter (Z07 §1.3 / Z08 §7.2)
        j.nTeamType < 2: so_LinkTo(k.lnkinf with coords = el.TeamRegenXY[team], 6, 9, 10)
        else:            so_LinkTo(k.lnkinf, 6, 9, 10)           # 0x1809 NC_MAP_LINKSAME / 0x180A LINKOTHER (Z01 §7.1)
        if p.so_Field (still the old map):
            → GameLog 0x0441 NC_LOG_GAME_KQ_ENTER { u32 charNo, Name3 map, u32 x, u32 y, u16 KQ ID, u32 Handle } (0x20)
        j.chrregnum = −1                                          # used
    # players offline, on another zone, or in mode 0/3 at all five ticks stay outside

KingdomQuestGateKeeper::erb_CheckLinkMap(k, p) → may leave       @ FUN_00495160
    p.so_ply_IsLink_OutMap_AndSendErrorMsg() (vt 0xa74, FUN_005603d0) ≠ 0: true
    else p ← notices "KQEntryMapErr0", "KQEntryMapErr1" (ScrString, section "Script"); false
ShinePlayer::so_ply_IsLink_OutMap_AndSendErrorMsg(p)             @ FUN_005603d0
    no map: 0
    FieldAttr.LinkOut (+0x6c) == 0: p ← 0x181D NC_MAP_LINK_FAIL_CMD { u16 0x1E42 }; 0
    FieldAttr.SystemMap (+0x6d) == 1: p ← 0x181D { 0x1E41 }; 0
    else 1
    # the client has no text for 0x1E41 / 0x1E42 in client-error-codes.json; the KQ notices carry the message
```

So a player on a map that forbids leaving gets 0x181D and two notices at every tick (up to five times).

```pseudo
0x581A NC_KQ_ENTRYRESPONCE_ACK { u8 Reply; u32 EncHandle } (C → zone)   @ FUN_00496990, mode mask 0x56 {1, 2, 4, 6}
    Reply == 0 or mode not allowed: return
    mode 4: stand up
    el = kqc_SearchHandle((p.so_GetWMSHandle() & 0xFFFF) ^ EncHandle)   # vt 0x340; only the low 16 bits are masked
    el: so_LinkTo({map 0 MapName, map 0 MapBase, map 0 MapInfo RegenX/RegenY}, 6, 9, 10)
    # no reply, no joiner / level / status check: (original bug) Z16-B4. A non-joiner that sends a valid handle is linked
    # to map 0 and sent back to Roumen by sp_EscapeFromEmptyKQ on arrival (§2.4), unless it is a GM
```

How the 2016 client builds `EncHandle` is open (Z08 §4: the GameFrameWork ignores 0x5819 NC_KQ_ENTRYRESPONCE_REQ).

### 2.4 Playing: what the zone does on a KQ map

At every map login (`sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390, Z01 §6), in this order:

```pseudo
    p.so_SetKQTeamType(2)                                         # vt 0xe04 → brief info nKQTeamType
    ShinePlayer::sp_GetJoinKQTeamType(p)                          @ FUN_00563990
        map is a KQ map (FieldAttr.KingdomQuestMap == 1) and fm_KQHandle ≠ 0xFFFF:
            # compares the u32 handle with 0xFFFF: "no KQ" (−1) still searches and logs
            # "ShinePlayer::sp_GetoJinKQTeamType : Cannot found KQ Element" (original bug) Z16-B5
            el and kqpil_IsKQJoiner(p.charNo): p.so_SetKQTeamType(kqpi_GetTeamType)
    ShinePlayer::sp_SendKQTeamType(p)                             @ FUN_00561560
        p ← 0x583A NC_KQ_TEAM_TYPE_CMD { u8 nTeamType = so_GetKQTeamType }   (data stream, vt 0x2f8; every map login)
    …
    sp_RemoveKQItem(p, 9); sp_RemoveKQItem(p, 8)                  # inventory, then equipment (§2.6)
    …
    ShinePlayer::sp_EscapeFromEmptyKQ(p)                          @ FUN_0043fa40
        map not a KQ map (or no map / option): return
        fm_KQHandle == −1 (KQ over or never made):
            the map's cinema has no film running (fm_Multiflex.l_ListNum == 0): sp_2Roumen(p) (FUN_0043cf80, Z06 §4.3)
            else: nothing                                         # a film still runs: stay
            return
        el = kqc_SearchHandle; none: assert "…Cannot found KQ Element"; return
        joiner (kqpil_IsKQJoiner == 1):
            down = knock-downs; p.so_SetKQTeamType(team); revives = kqe_ReviveNumber(el, &here)
            down < revives: p ← 0x5818 NC_KQ_RESTDEADNUM_CMD { u8 number = revives == 99999 ? 0 : revives − down }
                (game stream, vt 0x2fc)
            else: sp_2Roumen(p)                                   # no lives left
        not a joiner: GM (so_AdministratorLevel ≠ 0): notice "Doing KQ"; else sp_2Roumen(p)
    sp_EscapeFromEmptyID(p) (instance dungeons, Z14) …
    so_IsTeamPVPKQ(p) == 1: p ← 0x1828 NC_MAP_KQTEAMBATTLEZONE_ON_CMD {} (vt 0x304 so_SendProtocol(6, 0x28))
        else the map's free-PK (0x1812) / party-battle (0x1818) zone flags (Z01 §6)
    …
    fm_KQHandle ≠ −1 and el: kqcl_SendMobKill(h, p, el.DemandMobKill, 0)   # 0x5822 with the current count (§1.4)
```

Client: 0x5818 → `GameFrameWork::On_NC_KQ_RESTDEADNUM_CMD` FUN_0049af10 `KQuestTimeWin::SetRestLife(number)` (0 is
also shown for "unlimited" *(inferred)*); 0x583A is handled inline in the GameFrameWork dispatcher FUN_004be490 (stores
the byte at player object +0xb78); 0x1828 sets bit 2 of a map flag byte (+0xfef) (C01).

Team rules:

```pseudo
ShineObject::so_IsTeamPVPKQ(o)                                    @ FUN_0055d6c0
    o's map has a KQ element: el.IsTeamPVP ≠ 0; else 0
ShineMobileObject::so_smo_TargetIsEnemyKQTeam(a, b) (vt 0xe0c)    @ FUN_0055d700
    b and a's map has a KQ element with IsTeamPVP: ta = a.so_GetKQTeamType, tb = b.so_GetKQTeamType;
        ta ≠ 2 and tb ≠ 2: ta ≠ tb; else false
    else false                                                    # caller: the player / mover hit rules (Z03 §3.3, Z09 §8.4)
so_GetKQTeamType / so_SetKQTeamType (vt 0xe08 / 0xe04):
    ShinePlayer FUN_0055a830 / FUN_0055a810: brief info nKQTeamType;  ShineMob FUN_00556cc0 / FUN_00556ca0: mob brief
    nKQTeamType (set at regen, so_mob_RegenComplete, Z09); ShineServant FUN_00557190: the master's team, else its own
    brief byte +0x93;  ShineObject FUN_005551b0: 2 (none)
```

Deaths and revives: the player's death adds a knock-down (`sp_KQElementFunction(kqpi_KnockDownPlus)`, Z03 §7.2), a skill
revive removes one (Z03 §7.3), and the death-menu revive (`sp_ReviveReqProcess`, Z07 §3.1) compares
`kqe_ReviveNumber` with `kqpi_KnockDownGet`: with lives left the player revives at the KQ (team regen point, or in place
for revival modes 3 / 4); otherwise at the map's normal point *(as Z07 §3.1 reads it)*. A player who logs back in
without lives is sent to Roumen by `sp_EscapeFromEmptyKQ` above. `sp_ReviveNow` also sends a player whose KQ map has no KQ
any more to Roumen (Z03 §7.3).

### 2.5 Removing joiners, bans, end and destroy

```pseudo
0x583B NC_KQ_PLAYER_DISJOIN_CMD { u32 nHandle; u32 nCharNum } (WM → zone)   @ FUN_00499100
    el = kqc_SearchHandle(nHandle); el: kqpil_DeletePlayerInfo(nCharNum)
    # the player's knock-downs and BattleStat go; at the next map login there it is a non-joiner (→ Roumen)

0x5833 NC_KQ_LINK_TO_FORCE_BY_BAN_CMD { u32 nCharNum; Name3 sMapName[4] } (WM → zone)   @ FUN_00497120
    q = som_FindPlayer(nCharNum); q, mode ≠ 0 and a map:
        q's fm_MapID equals sMapName[i] for some i < 4: so_LinkTo({"RouN", "RouN", 6445, 8630}, 6, 9, 10)

ShineEndOfKingdomQuest / &endofkq → WorldManagerSession::wms_EndOfKQPacket(handle)   @ FUN_005a4800
    → WM 0x5810 NC_KQ_Z2W_END_CMD { u32 Handle }   (assert text "PineEventScriptNode::ShineEndOfKingdomQuest::sa_Step :
       Packet Too Long")
    KQContribute.kqpl_EndOfKQ(handle)                              # mob kills dropped at once
    # the element and the map marks stay until the WM answers with 0x5811

0x5811 NC_KQ_W2Z_DESTROY_CMD { u32 hquest } (WM → zone)            @ FUN_004972c0
    el = kqc_SearchHandle(hquest); none: return
    KQContribute.kqpl_EndOfKQ(hquest)
    for each map slot with a local instance f:
        MapClear: fm_ClearObject(f, 0x3b0)
        f.fm_KQHandle = −1; f.fm_KQID = 0xFFFF
        f.fm_Multiflex.cc_DropFilm(kqe_Script); mda_CloseAllDoor
    l_Free(container, slot)                                       # the element slot (player list kept until reuse;
                                                                  # MAKE clears it)
    # players still on the map are not moved: their next map login, revive (sp_ReviveNow) or death-menu revive sends
    # them to Roumen (§2.4) unless a film still runs on the map
```

### 2.6 KQ items

`ItemInfoServer` flags (`ItemInfoServer.shn`): `KQItem` (+0xda), `PK_KQ_USE` (+0xdb, not read by the code of this item),
`KQ_Item_Drop` (+0xdc). Extra stats of KQ pick-up items come from `KQItem.shn`:

```pseudo
KQItem { char ItemIndex[32]; u16 MoveSpdRate +0x20; u16 AbsoluteAttack +0x22; u16 PickupLimit +0x24 }   # 0x26
KQItemDataBox::kqidb_Load()                                       @ FUN_0064bd80   (start stage zs_start_sleep)
    read "../9Data/Shine/KQItem.shn"; for each row: itemId = ItemInfo B-tree[ItemIndex]
        default block: assert "…def data block"; unknown item: "…invalid extend itemid"; twice: "…duplicate Item";
        each → ShineExit("KQItemDataBox::kqidb_Load")
    map[itemId] = row
    # 2016 data: KQ_InvincibleHammer {350, 30000, 1}, KQ_Ice01 {0, 0, 1}
kqidb_GetData(itemId) → KQItem* | null                            @ FUN_0064bc60
    # ShinePlayer::so_RecalcEquipParam FUN_004cab70: for every equipped item with a row: move speed += MoveSpdRate,
    # +0x10c8 (absolute attack) += AbsoluteAttack (Z12)
kqidb_CanPickUp(itemId, u64 total) → may pick up                  @ FUN_0064bc90
    no row or PickupLimit == 0: 1; else total ≤ PickupLimit
    # caller so_ply_PickupItem FUN_0052faf0 with total = lot picked + lot already held; refusal = pick result 0x34a
    # (Z04 §3.3, "max-owned limit")
ItemAttrCls_KQStep::iac_itemcreate(id, item, text)                @ FUN_0063f1e0
    attribute text "…O…" / "…o…" (2nd char): item attr u16 (+riding.hungrypoint offset) = 0;
    "…S<n>" / "…s<n>": = n (sscanf %d)                              # the KQ-step item class's create argument
```

```pseudo
ShinePlayer::sp_KQItemDrop(p)                                     @ FUN_00496f00
    # called by ShinePlayer::so_Unmark FUN_00558900 for RemoveWhen REMOVE_NOW (0) and REMOVE_REVIVE (3): leaving the map
    # by a same-zone link, a revive elsewhere or the final logout step (Z01 §7.1, §8.1); not REMOVE_LOGOUT / REMOVE_WARP
    for every inventory cell (limit = charged-effect pages, vt 0x498) with an item whose ItemInfoServer.KQ_Item_Drop ≠ 0:
        copy = the item with a new key (iti_mkregnum(id, 3, zone, world))
        so_IsDropping(p, copy, ONLY_REGISTNUMBER, owner = p, p.handle, p.charNo, attribute class, 2)   (Z09 §11.3)
        fail: assert "…sp_KQItemDrop : Drop fail"
    # the original stays in the inventory: sp_RemoveKQItem deletes it at the next map login

ShinePlayer::sp_RemoveKQItem(p, type)                             @ FUN_0050f8c0
    no map: assert "…NULLMAP"; no option: "…NULLOp"; type 8 = equipment, 9 = inventory, else return
    for every unlocked cell (UnlockedInventoryIterator) with ItemInfoServer.KQItem ≠ 0 and
        (map is not a KQ map or KQ_Item_Drop ≠ 0):
        add the item key to the request (≤ 127)
        equipment: lock list icl_UnEquipInfo (vt 0x54); icl_ClearItem (vt 0x30); equipment: icl_EquipLocation(−1) (vt 0x50)
    any: → Character DB 0x3459 NC_ITEMDB_DESTROY_REQ { u16 p.handle, u32 charNo, u16 lockindex, u8 count (bit 7 = 0),
            …, u64 keys[count] at +0x17 }   (D03 §7.5; answer 0x345A, Z05 §6.4); lock index += 1
         (assert text "…sp_MakeItem : Packet Too Long")
```

So KQ items vanish from the character outside KQ maps, and drop-flagged ones are left on the KQ map whenever the holder
leaves it.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z16-B1 | `ShineMob::so_KilledBy` FUN_00432760 (KQ branch) | a killer whose zone party record has < 2 or > 5 members, or a party number ≥ 4000, asserts and returns from the whole kill handler | on a KQ map such a kill gives no experience, no drop, no quest progress | assert and continue with the rest of the kill |
| Z16-B2 | 0x580D @ FUN_00497790 | the success flag is overwritten per map slot; the 0x580E reply is sent only when the last listed map is local | a KQ whose last map is on another zone is built but never acknowledged (refines Z08-B8) | track "all maps found" separately from "reply now" |
| Z16-B3 | 0x580D @ FUN_00497790 | maps claimed in earlier loop passes keep `fm_KQHandle` / `fm_KQID` when a later check or the container allocation fails | the instance is unusable for every later KQ ("Not empty2") until restart | reset the claimed maps on every error exit |
| Z16-B4 | 0x581A @ FUN_00496990 | links to map 0 for any known handle without checking the player is a joiner (and masks only the low 16 bits) | a non-joiner can be linked into the KQ map; it bounces to Roumen at map login unless GM | check `kqpil_IsKQJoiner` before the link |
| Z16-B5 | `sp_GetJoinKQTeamType` FUN_00563990 | compares the 32-bit `fm_KQHandle` with 0xFFFF | on a KQ map without a KQ, every map login logs "Cannot found KQ Element" | compare with 0xFFFFFFFF |

## N. Not reconstructed / uncertain

- Part 1 only (KQ core). KQ end, results and rewards (§3) and the guild tournament (§4 ff.) follow in later parts; see
  `docs/plan/status/Z16.md`.
- How the client produces `EncHandle` for 0x581A (Z08 open point) is still open.
- 0x5818 `number = 0` for unlimited revives: whether the client shows 0 or hides the counter was not traced in
  `KQuestTimeWin::SetRestLife`.

## N+1. Coverage boundary

(Written in the sweep part.)
