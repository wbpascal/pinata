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

## 3. KQ scoring, end, results and rewards

A KQ ends from its map script. The 2016 data has two script kinds: the Pine books (`9Data/Shine/Script/…`, the
`KQHBat*`, UnderHall, Honeying, GordonMaster books; nodes in Z09 §24.7, §25.6, §26.1) and the Lua scripts
(`9Data/Shine/LuaScript/KQ/<name>/`, 18 KQs: AntiHenis, EmperorSlime, GoldHill, HMiniDragon, KDArena, KDCake, KDEgg,
KDFargels, KDMine, KDSoccer, KDSoccer_W, KDSpring, KDWater, Kingkong, KingSlime, LegendOfBijou, MaraPirate, MiniDragon).
Both use the same zone objects. The order in a script is: results (window + title counters + GameLog), rewards, send
the players home, end. For example GoldHill `Progress.lua`: `cQuestResult(map, "Success")`, `cReward(map, "KQ")`, …,
`cEndOfKingdomQuest(map)`.

| Step | Pine node (Z09) | Lua function (this §) | Zone object |
|---|---|---|---|
| per-player battle score | — | — | `BattleStat` (§3.1) |
| ranking packets 0x5814 / 0x5821 | `@KQResultList`, `@KQTopList` (§22.3) | `cScoreResultList`, `cScoreTopList` (Z09 §28.12) | `AxialListKQResult` (Z09 §22.3) |
| result for the whole map | `questresult` (§25.6) | `cQuestResult` | `AxialListKQEnd(Lua)` (§3.3) |
| result for one player | `sendquestresult` (§26.1) | `cQuestResult_Individual` | vt 0x304 (§3.3) |
| reward for the whole map | `reward` (§25.6) | `cReward` | `AxialListKQReward(Lua)` (§3.4) |
| reward by row name, one player | `invidualreward` (§24.7) | `cKQRewardIndex` | `so_ply_KQRewardIndex` (§3.4) |
| end | `endofkq` (§26.1) | `cEndOfKingdomQuest` | `wms_EndOfKQPacket` (§2.5, §3.2) |

### 3.1 Battle statistics: `BattleStat`

```pseudo
BattleStat {                                   # 0x2c (pdb2016); one per KQ joiner record (KQPlayerInform +8, §1.3)
    u8  bs_ClearAtLink +0                      # see below
    i32 bs_KillScore +4, bs_DamageAmount +8, bs_HealAmount +0xc, bs_SkillBlast +0x10, bs_CriticalNum +0x14,
        bs_HittedNum +0x18, bs_KnockDownNum +0x1c, bs_Dead +0x20, bs_Kill +0x24
    u32 bs_Score +0x28                         # PvP rating, starts at 10000
}
BattleStat::bs_Clear()                                            @ FUN_0043be00
    every counter = 0, bs_Score = 10000 (bs_ClearAtLink untouched)
so_GetBattleStat (vt 0x428):
    ShinePlayer                                                   @ FUN_00498d60   (§1.3)
        on a KQ map with the player listed: &record.kqpi_BattleStat; else &ShineObject::so_DefBattleStat
    every other object (ShineObject)                              @ FUN_00496eb0
        &ShineObject::so_DefBattleStat (DAT_132729c4)            # one static shared by all mobs, NPCs and non-KQ players
```

Writers (every caller of vt 0x428; the shared default object takes the writes of every non-KQ attacker or victim):

| Counter | Changed by | Where |
|---|---|---|
| `bs_DamageAmount` += dmg | the **attacker**, on every hit that does not kill | `ShineObject::so_DamagedBy` FUN_0042d130, `ShineMover::so_DamagedBy` FUN_0042d170, `ShinePlayer::so_DamagedBy` FUN_00431500, `ShineMob::so_DamagedBy` FUN_00431750 (Z03 §7) |
| `bs_DamageAmount` += dmg, `bs_KillScore` += victim.`smo_BattleKillScore` (vt 0xee8) | the **killer**, on the killing hit | `ShineMobileObject::so_KilledBy` FUN_00432240 (Z03 §7.1); `smo_BattleKillScore`: players 150 (FUN_0055a300), mobs `MobInfoServer.KQKillPoint` (FUN_00556b70) |
| `bs_HittedNum` += 1 | the player **hit**, when the hit counts (5th argument `countHit` ≠ 0) | `ShinePlayer::so_DamagedBy` FUN_00431500 |
| `bs_CriticalNum` += 1 | the attacker, per critical hit | `RulesOfEngagement::roe_CalcDamage` FUN_00505c00 (Z03 §4) |
| `bs_SkillBlast` += 1 | the caster, on the routine step that runs a cast with `smo_SkillCast.scs_ProduceSkill.sklidx` set | `ShineMobileObject::so_Routine` FUN_0056a080 (Z03) |
| `bs_KnockDownNum` += 50 | the player who dies (every death: by a player, a mob or nothing) | `ShinePlayer::so_KilledBy` FUN_00433be0 (Z03 §7.2), right after `kqpi_KnockDownPlus` |
| `bs_Dead` += 1, killer `bs_Kill` += 1, rating transfer | player killed by a player (a pet / summon kill counts for its owner) | `ShinePlayer::so_KilledBy` FUN_00433be0 |
| `bs_HealAmount` | never written (always 0) | — |
| `bs_ClearAtLink` | see below | `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390, `sp_ReviveReqProcess` FUN_00451bd0 |

```pseudo
rating transfer in ShinePlayer::so_KilledBy(victim v, killer k)   @ FUN_00433be0
    sv = v.bs_Score, sk = k.bs_Score  (as floats); f = min(sv, sk) / (sv + sk)
    sk ≤ sv: f = 1 − f            # weaker or equal killer: f in [0.5, 1)
    else:    f = 2·f²              # stronger killer: f < 0.5
    d = (int)(f · 1000)            # x87 truncation
    v.bs_Score = max(v.bs_Score − d, 1000)  (unsigned compare; d < 1000 and the score never falls below 1000, so no wrap)
    k.bs_Score += d

bs_ClearAtLink:
    map login on a map with fm_KQHandle == −1 (sp_NC_MAP_LOGINCOMPLETE_CMD, Z01 §6):
        s = p.so_GetBattleStat()                 # off a KQ map this is always the shared so_DefBattleStat
        s.bs_ClearAtLink ≠ 0: bs_Clear(s);  s.bs_ClearAtLink = 1
    death-menu revive (sp_ReviveReqProcess, Z07 §3.1, after it picked the revive point, either choice):
        p.so_GetBattleStat().bs_ClearAtLink = 0
    # (original bug) Z16-B7: the clear only ever reaches the shared default object (a KQ map has fm_KQHandle ≠ −1, and
    #   off a KQ map so_GetBattleStat never returns a joiner record), so it never resets a player's statistics
```

So a joiner's statistics live exactly as long as its `KQPlayerInform` record: from `kqpil_InsertPlayerInfo` (0x580F,
fresh 10000 rating) to `kqpil_DeletePlayerInfo` (0x583B) or the next KQ in the same container slot. Readers: the
score functions of `AxialListKQResult` (Z09 §22.3: `alkqr_Score_Default` = kill score − knock-downs; `zerosumWorker`
= `bs_Score` with `bs_Kill` / `bs_Dead` shown). So each death costs 50 points in the default ranking, a killed mob
gives its `KQKillPoint`, a killed player 150.

### 3.2 End: `cEndOfKingdomQuest`

```pseudo
Lua cEndOfKingdomQuest(mapName) → 1 | nil                         @ FUN_005df1f0   # 25 calls in the 2016 Lua KQs
    f = FieldContainer::fc_FindMap(mapName); none: return nil
    f.fm_KQHandle == −1: assert "cEndOfKingdomQuest : Invalid Shine Quest"; return nil
        # the scripts then log "ReturnToHome::Function cEndOfKingdomQuest failed"
    WorldManagerSession::wms_EndOfKQPacket(f.fm_KQHandle)        # → WM 0x5810 + kqpl_EndOfKQ (§2.5)
    FieldMap::fm_ClearObject(f, 0xb0)                             # NPCs, mobs, doors removed next tick (Z09 §24.8)
    return 1
```

Same effect as the Pine `endofkq` (Z09 §26.1), without its missing return (Z09-B117). The element itself goes when
the WM answers with 0x5811 (§2.5). Other end paths: the GM word `&endofkq <handle>` (Z11 §5.5: no map clear) and the
WM's own end (time limit, W04 §6), which sends 0x5811 directly.

### 3.3 Results: `cQuestResult`, `cQuestResult_Individual` and `AxialListKQEnd`

```pseudo
Lua cQuestResult(mapName, word) → 1 | nil                         @ FUN_005e30d0   # 21 calls
    f = fc_FindMap(mapName); c = fm_GetCenterObject(f); either null or word not a string: return nil
    word == "Success" (exact, case-sensitive): it = AxialListKQEndLua(0x16, 0x12)      # ctor FUN_004289d0
    word == "Fail":                            it = AxialListKQEndLua(0x16, 0x13)
    other: return nil                                             # nothing done
    so_AllInMap(c, it, includeSelf 0)
    fm_ClearObject(f, 0x1b0)                                      # also the bandits (kind 8); the Pine node does the same
    return 1

AxialListKQEnd / AxialListKQEndLua :: ali_Work(o)                 @ FUN_00429e00   # one body for both classes (vftables)
    o is not a player (vt 0x4d0 ≠ 2): continue
    cmd == 0x12 ? o.so_ply_KQSuccess() (vt 0x7fc, FUN_0055ae10) : o.so_ply_KQFail() (vt 0x800, FUN_0055ae30)
        both: o's map FieldAttr.KingdomQuestMap (+0x36) == 1:
            CCharacterTitleZone::CT_KQSuccess FUN_005cbfb0 / CT_KQFail FUN_005cbfd0:
            m_TitleValues[ID_KQ_SUCCESS 21 / ID_KQ_FAIL 22].TitleValue += 1 (u64), bTitleSave = 1, CheckNewTitle(id)
            # CHARACTER_TITLE_TYPE (pdb2016); ID_KQ_ATT 20 is counted at the pull-in (CT_KQJoin FUN_005cbf90, §2.3);
            # title award logic CheckNewTitle FUN_005cb5f0 is Z18's
    o has a map: → GameLog 0x0442 NC_LOG_GAME_KQ_LEAVE {
            u32 chrregnum = charNo (vt 0x344); MAPPOS mappos { Name3 MapName = map fm_MapID; u32 x, y = o's position };
            u16 KQ_ID = map.fm_KQID; u32 KQ_Handle = map.fm_KQHandle; u8 Leave_Status = (cmd == 0x12) }   # 0x1f bytes
        (too long: assert with the copied text "KingdomQuestGate::KingdomQuestGateKeeper::erb_happen : Packet Too Long")
    o.so_SendProtocol(0x16, cmd) (vt 0x304)       # empty 0x5812 NC_KQ_COMPLETE_CMD / 0x5813 NC_KQ_FAIL_CMD
    continue

Lua cQuestResult_Individual(handle, word) → 1 | nil               @ FUN_005ecca0   # not called by the 2016 scripts
    o = som_GetObject(handle); a player (vt 0x4d0 == 2); word "Success" → cmd 0x12, "Fail" → 0x13, else nil
    o.so_SendProtocol(0x16, cmd); return 1        # the window packet only: no title counter, no GameLog, no clear
```

So the KQ result shown to the client is the empty 0x5812 / 0x5813 (client game scene FUN_004a31f0 / FUN_004a3270: the
complete / fail window and its sound, Z09 §24.8). Every player on the map gets it, joiner or not (GMs too). The Pine
`questresult` reads the word differently (lower-cased; `suc` = success, any other word = fail, Z09 §25.6).

### 3.4 Rewards: `cReward`, `cKQRewardIndex`, `sp_KQReward` and 0x5815–0x5817

```pseudo
Lua cReward(mapName, word) → 1 | nil                              @ FUN_005df060   # 11 calls: cReward(map, "KQ")
    f = fc_FindMap(mapName); c = fm_GetCenterObject(f); word a string; else nil
    word == "KQ" (exact):
        f.fm_KQHandle == −1: assert "cReward : No KQ info"; return nil
        it = AxialListKQRewardLua(f.fm_KQHandle)                  # ctor FUN_004288c0 = AxialListKQReward FUN_00428410:
                                                                  #   alkqrl_kqe = kqc_SearchHandle(handle),
                                                                  #   alkqrl_DemandKill = kqe.DemandMobKill (left unset when null)
        so_AllInMap(c, it, 0)
    return 1                                                      # also for another word, when nothing was done

AxialListKQReward / AxialListKQRewardLua :: ali_Work(o)           @ FUN_00428490   # one body for both classes
    no kqe: continue
    kills = kqcl_GetMobKill(&g_KQContributeList, kqe.kqe_kqinfo.Handle, o)   # FUN_00499d80 (§1.4); 0 when not listed
        # Z09 §25.6 calls the key "kqinfo id": it is the first u32 of PROTO_KQ_INFO, the Handle
    kills ≥ DemandKill: o.vt[0x76c](kqe) = so_ply_KQRewardStruct      (players; other objects: no-op FUN_00549070)
    else: o.so_SendErrorCode(0x16, 0x23, 0x1104) (vt 0x308)
        → 0x5823 NC_KQ_NOREWARD_CMD { u16 err = 0x1104 }   (client FUN_004b0830: "You haven't hunted enough monsters to
          receive a reward.")
    # no joiner and no GM check (original bug) Z16-B8: with DemandMobKill 0 (30 of the 57 KingdomQuest.shn rows) every
    #   player on the map gets the reward, GMs watching the KQ (§2.4 "Doing KQ") and non-joiners included

Lua cKQRewardIndex(handle, indexString)                           @ FUN_005e4000   # 7 calls (KDArena: per team result)
    o = som_GetObject(handle); o and not leaving (vt 0x300 so_IsEmpty ≠ 1) and indexString a string:
        o.vt[0x770](indexString) = so_ply_KQRewardIndex
    returns nothing                                               # no KQ, map or kill check: the script decides

ShinePlayer::so_ply_KQRewardStruct(p, kqe) (vt 0x76c)              @ FUN_0052e9c0
    row = KQRewardDataBox::operator[](kqreward, kqe.kqe_kqinfo.RewardIndex)   # FUN_0049a950, linear search on ID
    row: sp_KQReward(p, row)
ShinePlayer::so_ply_KQRewardIndex(p, name) (vt 0x770)              @ FUN_0052ea80
    row = KQRewardDataBox::operator[](kqreward, name)             # FUN_0049a9a0, linear search on IndexString
    row: sp_KQReward(p, row)
```

Callers of vt 0x76c: `AxialListKQReward(Lua)::ali_Work`, the GM word `&kqreward` (Z11 §8.4). Callers of vt 0x770: the
Pine `invidualreward` (Z09 §24.7), `cKQRewardIndex`. `sp_KQReward` FUN_0052da70 itself is fully written in Z11 §8.4. In
short: the player must be alive and present; a treasure chest of `KQBoxItemIDX` (default
`idb_specialid.sii_kqrewardchest`) is filled from the 15 `Reward[i]` `ShineReward` rows, each kept with chance
`RewardRate[i]` / 1000; item rewards go into the chest; EXP, cen and fame are summed. The chest goes to reward-box
slot 0 (box 2) and its contents into `ItemsInChest` (Z09 §10.10). Then `0x5815 NC_KQ_REWARD_REQ` goes to the
Character DB, cen and fame are reserved under the inventory lock index, and the EXP is given at once
(`sp_GainExp`, before the DB answers). It is the only sender of 0x5815.

`KingdomQuestRew.shn` (2016): 64 rows, 43 named (`IndexString`, e.g. `HERO_1_0` … for the KQHBat books,
`REW_KQ_ARENA_WIN/LOSE/DRAW` for KDArena) and 21 found by `ID` = `KingdomQuest.shn` `RewardIndex` (22 distinct values
there). Six filler rows have ID 0 and no name; `operator[](0)` finds the first ID-0 row (`KQBox_KingSlime`).

```pseudo
0x5815 NC_KQ_REWARD_REQ (zone → Character DB) { u32 fame; u64 cen; PROTO_NC_ITEMDB_CREATEITEMLIST_REQ itmlst {
        header { u16 handle, u32 charNo }, u32 owner, u16 lockindex, u16 map, u64 price = 0, items } }   # sp_KQReward
    DB side: D04 §3 (CreateChestItemList, p_Char_MoneyAdd, AddCharFame) → 0x5816 or 0x5817

0x5816 NC_KQ_REWARDSUC_ACK { NETPACKETZONEHEADER header { u16 handle, u32 charNo }; u16 lockindex }   (8)
        GameDBSession::gds_NC_KQ_REWARDSUC_ACK                    @ FUN_0052e570
    p = som_GetObject(header.handle); p, not leaving (vt 0x300 == 0) and p.charNo (vt 0x344) == header.charNo; else ignore
    L = p.so_ply_GetInventoryLockList() (vt 0x7d4)
    L.icl_Apply_N_Free(p, lockindex, 0) (vt 0x1c, FUN_0048be90, Z05 §1.3)   # applies the cen and fame reservations (their
                                                                             # releasers, Z05 §1.4, update the client)
    nothing applied: LockIndexLog "GameDBSession::gds_NC_KQ_REWARDSUC_ACK : <lockindex>"

0x5817 NC_KQ_REWARDFAIL_ACK { header; u16 lockindex; u16 error }   (0xA)   GameDBSession::gds_NC_KQ_REWARDFAIL_ACK @ FUN_0052e680
    same player check; L.icl_Free(lockindex) (vt 0x28, FUN_0048b2c0)   # cen / fame reservations dropped
    # error (0x1101 chest, 0x1102 money; 0x1103 fame is dead code, D04-B7) is neither logged nor shown
```

On a failure the EXP stays given and the chest contents stay in `ItemsInChest` without DB rows *(inferred from the
order in sp_KQReward; what the zone shows for that reward box is Z09 §10.10's)*. A player who left before the answer
loses only the in-memory update; the DB already holds cen and fame.

### 3.5 Other KQ Lua functions

```pseudo
Lua cGetKQLimitSecond(mapName) → seconds | nil                    @ FUN_005e5390   # 10 calls
    f = fc_FindMap(mapName) with fm_KQHandle ≠ −1; el = kqc_SearchHandle(f.fm_KQHandle); else nil
    m = kqe_GetKQLimitMin(el) (FUN_005e4d20, u16 LimitTime)
    m ≠ 0xFFFFFFFF: return m · 60                 # the check compares a u16 with 0xFFFFFFFF: always true (original bug) Z16-B6
    else nil

Lua cGetKQTeamType(handle) → 0 | 1 | 2                            @ FUN_005e81c0   # 11 calls; scripts use team + 1
    o = som_GetObject(handle); o: o.so_GetKQTeamType() (vt 0xe08) & 0xff (§2.4); no handle or object: 2 (none)

Lua cIsKQJoiner(handle) → boolean                                 @ FUN_005e82d0   # 4 calls
    o = som_GetObject(handle); o: o.so_ply_IsKQJoiner() (vt 0xe10, FUN_005615d0 for players, §1.3) ≠ 0; else false

Lua cShowKQTimerWithLife(mapName, seconds) → 1 | nil              @ FUN_005e54f0   # 12 calls
    f = fc_FindMap(mapName); c = fm_GetCenterObject(f); null: nil
    broadcast to the map (AxialListPacketBroadcast over c, so_AllInMap):
        0x0810 NC_MISC_RESTMINUTE_CMD { u8 flag = 1; u16 second = (int)seconds }     # 3 bytes, truncated to 16 bits
    return 1
Lua cShowKQTimerWithLife_Obj(handle, seconds) → 1 | nil           @ FUN_005e5690   # 10 calls (map login of one player)
    o = som_GetObject(handle), a player (vt 0x4d0 == 2); else nil
    o ← 0x0810 { 1, (u16) seconds } (data stream, vt 0x2f8; "cShowKQTimerWithLife_Obj : Packet Too Long" on overflow)
    return 1
```

Client 0x0810 (GameFrameWork FUN_004997a0, C01): flag 1 → `KQuestTimeWin::ResetTime(second)`: the KQ time window
counts down from `second`. "WithLife" only names that window: it also shows the lives (0x5818, §2.4) and the
kills still needed (0x5822, §1.4), but these functions send only the time. The third Lua sender of 0x0810,
`cVanishTimer` FUN_005e5840, is a general script timer (Z09 Lua table).

### 3.6 Logout log and GM words

```pseudo
ShinePlayer::so_LogoutLog(p, reason) (vt 0x910)                   @ FUN_00549f90
    p has a mode, is not dead (mode ≠ 0, ≠ 3) and has a map; map without FieldAttr: assert "…so_LogoutLog : NULLOp"
    map FieldAttr.KingdomQuestMap (+0x36) ≠ 0:
        KQLogoutLog "<reason> : <charName>[<handle>/<userNo vt 0x348>/<charNo>]<mapName>/<x>/<y>"
    # callers: so_banning FUN_00558b70 (reason "Ban"), ZoneServer::zs_disconnect FUN_005abb60 ("Socket"); a file log only
```

GM words: `&endofkq` and `&Reroadkingdomquest` are in Z11 §5.5, and `&kqreward`, `&kingdomquest` and `&bigbang` in
Z11 §8.4 (`&kingdomquest` starts a map script without a KQ element, so `cReward` / `reward` find no KQ handle there
*(inferred from Z11 §8.4)*).

## 4. Guild tournament: the system core

One `GuildTournamentSystem` (0x1e8 bytes) per tournament map, `FieldMap::fm_pGuildTournamentSystem` (read by
`fm_GetGuildTournamentSystem` @ FUN_00463290). It is created and filled by `fm_CreateGuildTournamentSystem` @ FUN_00464830
(from `wms_GuildTournamantStart`, §6) and holds the two fighting guilds, the flags and the dice game. Its group behaviour
(scores, skills, master buff, gates, items) is `GuildTournamentSystem::GuildGroup` (§5); the match start / end with
the WM and the client requests are §6. The map script (`Guild/GuildTournament.ps`) registers flags, gates and portals
and ends the match through Pine nodes (Z09 §24.8, §25.7, `RegisterGTPortal` Z09 §22.4).

### 4.1 Data structures

```pseudo
GuildTournamentSystem : RoutionInterface   (0x1e8)                     # vftable: +0 dtor, +4 Roution
    +0x004 m_ErrorMessage     FastDelegate1<int>   error sink of the request in progress (SetErrorDelegate)
    +0x00c m_vecFlags         vector<FlagInfo>     in FlagRegister order
    +0x01c m_GroupA, +0x0d0 m_GroupB   GuildGroup (0xb4, §5.1)     # A = nNo1, B = nNo2 of 0x7481
    +0x184 m_nTournamentType  int   MAP_TYPE key of every GuildTournament*.shn table (all 2016 rows: 0)
    +0x188 m_nTournamentSeed  int   −1 = none
    +0x18c m_diceGame         DiceGame (0x48, §5)
    +0x1d4 m_OldTime          tick of the previous Roution
    +0x1d8 m_FlagAllConnectTime TickTimer, delay 600 (60 s): runs while one guild holds every flag

FlagInfo (0xc4): +0 m_GuildNumber (owner; 0 = neutral), +4 u16 m_ObjectNumber (flag NPC handle),
    +8 m_strFlagAType, +0x24 m_strFlagBType, +0x40 m_strFlagNormalType (mob index names of the three looks),
    +0x5c m_FlagScoreTimer TickTimer (delay = OccupyTime·10/1000), +0x6c m_PortalInfo
PortalInfo (0x58): +0 u16 m_Handle (0xFFFF = none), +4 m_strAType, +0x20 m_strBType, +0x3c m_strNormalType
Gate (0x40): +0 bIsUse, +2 u16 hFlagNumber, +4 u16 hGateNumber, +8 strunUseGateName, +0x24 strUseGateName
GuildMemberInfo (0x1c): +0 u16 m_hHandle, +4 m_nGuildMemberGrade (0 = guild master, see 0x74DE), +8 m_unInCreaseScore,
    +0xc m_unDeCreaseScore, +0x10 m_DieCount, +0x14 m_KillCount, +0x18 m_CaptureFlagCount
GuildGroup fields used here (full list §5.1): +0 m_GuildNumber, +4 m_mapOutMemberBackUps map<charName, GuildMemberInfo>,
    +0x14 m_vecGuildGates, +0x24 m_vecGuildMembers (sorted by grade, GradeSort @ FUN_00478d80: a.grade < b.grade),
    +0x3c m_unAllGuildScore, +0x40 m_unKillerPoint, +0x44 m_unGuildScore, +0x70 m_nCaptureFlagCount,
    +0x74 m_pManageruser (the member used as the map anchor for broadcasts), +0x88 m_Advan {bool m_IsAdvan, int m_nLevel},
    +0x90 m_FlagMultiple (≥ 1; > 1 while a "War Cry" item runs, §5)
GuildTournamentSystem::sm_mapGuildMemberGrades   map<charNo, grade>, filled by SetGuildMemberGrade from 0x74C7 (§6)

TickTimer (0x10): +0 m_CurDelayTime, +4 m_DelayTime, +8 m_bEnable, +0xc m_PrevCheckTime; units = clockwatch ticks
    (tenths of a second). Enable(b) @ FUN_00591fd0: m_bEnable = b, m_CurDelayTime = 0.
    CheckUpdateEvent(dt) @ FUN_00592020: if enabled: cur += dt; if cur > delay: cur −= delay, return true (periodic).
    The delay is written by the folded setter FUN_00653a60 (named `UseItemRide::uir_SetSkill` in the PDB: `*(this+4) = v`).
```

### 4.2 Tables

Loaded at zone start by `Table::Load<T>` (GuildTournamentScore 005b42b0, LvGap 005b43f0, Occupy 005b4530, Skill 005b4670,
MasterBuff 005b47b0, GTIGetRate 005b48f0, GTIGetRateGap 005b4a30, GTIServer 005b4b70, GTIBreedSubject 005b4cb0,
GTWinScore 005b4df0; file-name strings 006fa920…006fa9ec, called from `zs_start_house` LAB_005b64e0, Z01 start table): `GetTableDir()` + file name →
`ITableBase<Row,T>::Load` (e.g. FUN_005b25e0: allocate the 0xc4 table object once, `CDataReader::Read`, accept only
`nVersionKey == DataVersionKey` (0x36f for GuildTournamentScore; `docs/knowledge/S01.md` SHN header), then the table's vt+4 post-processing);
failure → assert "Fail to read  : <file>" and `ShineExit`. The GTI* item tables are used by §5.

| File (row struct, size) | Fields | Getter | 2016 rows (MAP_TYPE 0) |
|---|---|---|---|
| GuildTournamentScore.shn (`GUILD_TOURNAMENT_SCORE`, 0x10) | MAP_TYPE, u16 GradeScore[7] | `GetScore(type, killerGrade, victimGrade)` @ FUN_005c7080: the killerGrade-th row of the type, column victimGrade; victimGrade > 6 → assert "…GetScore : No Script" and still reads `row[victimGrade+1]` (original bug) Z16-B11; no row → 0 | 7 rows, e.g. killer grade 0: 18 12 10 8 4 4 3; grade 6: 20 16 14 12 10 8 5 |
| GuildTournamentLvGap.shn (`GUILD_TOURNAMENT_LVGAP`, 8) | MAP_TYPE, float LvGap, u16 PointRate | `DataProcess` @ FUN_005c7d00 groups the rows per MAP_TYPE into `sm_mapBalanceDatas` (file order); `BalanceScoreMediate(type, score, killerLv, victimLv)` @ FUN_005c7c50: gap = victimLv − killerLv; first row with `LvGap ≤ gap` (else the last row) → `PointRate · score / 100`; type unknown → assert "GuildTournamentBalanceTable::BalanceScoreMediate Not Find" and 0 | LvGap 11 → 150 %, 6 → 120 %, −5 → 100 %, −10 → 80 %, −11 → 50 %, −130 → 50 % |
| GuildTournamentOccupy.shn (`GUILD_TOURNAMENT_OCCUPY`, 6) | MAP_TYPE, u16 OccupyTime (ms), u16 Score | `GetOccupyTime(type)` @ FUN_005c70f0 (none: assert, 0xFFFFFFFF), `GetScore(type)` @ FUN_005c7150 (none: assert, 0) | 60000 ms, 20 points |
| GuildTournamentSkill.shn (`GUILD_TOURNAMENT_SKILL`, 0x2e) | MAP_TYPE, Index, DeathPoint, char StaName[32], TargetType, u32 DlyTime | `GetStateByIndex(type, index)` @ FUN_005c71b0, `GetUseSkillCount(type, points)` @ FUN_005c7200 (rows with DeathPoint ≤ points); used in §5 | 0 StaGldRestore 20 pts; 1 StaGldMoveSpeedUp 15; 2 StaGldACMinus 80; 3 StaGldSlow 50; 4 StaGldStun 60; 5 StaGldAtkUp 0 |
| GuildTournamentMasterBuff.shn (`GUILD_TOURNAMENT_MASTERBUFF`, 0x22) | MAP_TYPE, char StateName[32] | `GetMasterBuff(type)` @ FUN_005c7500 (string; "" if none) | StaAcaMsBuf7PMain |
| GTWinScore.shn (`GTWinScore`, 2) | u16 WinScore | row 0 read in `Update` (§4.3) | 4000 |
| GTIGetRateGap.shn (`GTIGetRateGap`, 3) | u8 ID, u16 Gap | `ChangeAdvanRule` (§4.6) | 1: 200, 2: 500, 3: 1000 |

### 4.3 Lifetime and the tick

```pseudo
GuildTournamentSystem()                                   @ FUN_00480d30
    groups constructed (GuildGroup() @ FUN_00480c10: revive timer delay 300, GuildGroup::Clear); dice game zeroed;
    m_OldTime 0, seed −1, type 0; m_diceGame.m_DiceGameEnd = this.DiceGameWinGuild (§5); m_FlagAllConnectTime delay 600
~GuildTournamentSystem @ FUN_00480e40 (groups, flag vector); scalar deleting dtor FUN_00480ee0

Initialize(guildA, guildB, type, seed)                    @ FUN_00480f10   (from fm_CreateGuildTournamentSystem, §6)
    Clear(); A.m_GuildNumber = guildA; A.SetTournamentType(type); B likewise (§5); m_nTournamentType = type; seed = seed

Clear()                                                   @ FUN_004808f0   (also fm_GuildTournamentClear, wms_GuildTournamantStart)
    empty m_vecFlags; GuildGroup::Clear(A), Clear(B) (@ FUN_00480460: removes the master buff from the first member if
    that member is still the grade-0 master, empties gates / members / buff timers / out-member backups / advan item list /
    team NPCs, zeroes scores, m_FlagMultiple = 1, m_pManageruser = NULL); seed −1, type 0, both guild numbers 0
    # m_FlagAllConnectTime and the dice game are not reset here

Roution()  (RoutionInterface vt+4)                        @ FUN_0047eab0
    driver: ShineAxialFlag::so_Routine @ FUN_00569e00 of the map's axial flag object (FieldMap flag[2]) runs the map's
    films, then Roution() of every entry of its safm_vecRoutions (fm_CreateGuildTournamentSystem pushes the system there)
    dt = now − m_OldTime (first call: 0); m_OldTime = now; Update(dt)

Update(dt)                                                @ FUN_0047e0e0
    for each flag f:
        g = group whose m_GuildNumber == f.m_GuildNumber
        none (neutral flag): m_ErrorMessage(0x1B4F) if a sink is set (only during a request); continue
        if f.m_FlagScoreTimer.CheckUpdateEvent(dt):                      # every OccupyTime (60 s) the flag is held
            pts = OccupyTable.GetScore(type) · max(g.m_FlagMultiple, 1)  # 20, 40 with War Cry
            g.m_unAllGuildScore += pts; g.m_unGuildScore += pts
            win = GTWinScore row 0 (4000), 2000 if the GTIGetRateGap table is missing or empty
                # tests GTIGetRateGap's header but reads GTWinScore (original bug) Z16-B9
            if g.m_unAllGuildScore ≥ win: g.SendWinEventToScript()      # §5: the script ends the match
            ChangeAdvanRule()                                            # §4.6
            anchor = g.m_pManageruser, else g.CheckManagerUser() (§5)
            if anchor: → all in anchor's map 0x74DD NC_GUILD_TOURNAMENT_SCORE_CMD
                {PartMask 0, regNumber g.no, unAllScore, unCaptureFlagCount = g.m_nCaptureFlagCount, unPlayerNum 0}
    if m_FlagAllConnectTime.CheckUpdateEvent(dt):                         # one guild held all flags for 60 s
        m_FlagAllConnectTime.Enable(false)
        if there is a flag: g = owner of flag[0]: g.SendWinEventToScript() (no group: 0x1B4F to the sink)
    A.Update(dt), B.Update(dt) (§5); m_diceGame.Update(dt) (vt 0, §5)
```

### 4.4 Registration of fighters, flags, gates and portals

```pseudo
PlayerRegister(p) → bool                                  @ FUN_0047f970
    only if p's layer sub index (so_layer.layer +4 l_Sub) is 0 or 1 and p is not yet registered (IsPlayerRegister):
        # observers stand on layer 2 (map login, below); GM hide mode on layer 3
    g = group with m_GuildNumber == p.guildNo (vt 0x818); none → sink(0x1B4F), false
    grade = sm_mapGuildMemberGrades[p.charNo]; missing → log "GuildTourmentSystem::PlayerRegiste Not Find Grade Info :
        <name>" to GuildTournamentLog, false
    info = {handle p, grade, all counters 0}
    if g.m_mapOutMemberBackUps has p's name: info = the backup (all seven fields), handle = p's handle  # rejoin keeps scores
    insert info into g.m_vecGuildMembers after the last member with grade ≤ info.grade (upper_bound, GradeSort)
    if grade (from sm_map) == 0: g.GuildMasterBuffRun() (§5)
    → p (data stream vt 0x2f8) 0x7483 NC_GUILD_TOURNAMENTSTART_CMD {u32 nGuildA = A.no, u32 nGuildB = B.no,
        u16 nGuildTourNamentType = type, u32 nGuildMyRegNumber = p.guildNo (0 → assert)}            # 14 bytes
    → WM 0x74C8 NC_GUILD_TOURNAMENT_ZONE_FIGHTER_ENTER_CMD {u8 nTournamentSeed = seed, u32 nGuildNo, u32 nCharNo}
        # WM sets the character's inArena flag (W03 §8.3)
    A.SendPlayerAllScoreInfo(p, 1); (A.no == B.no ? A : B).SendPlayerAllScoreInfo(p, 0)    # §5: full score lists
    if g.m_FlagMultiple > 1: → p 0x74F2 NC_GUILD_TOURNAMENT_ITEM_FLAG_CMD {u8 FlagScoreMultiple, u32 nGuildRegNo = g.no}
    true

SendMapInPlayerInfoToObserber(p)                          @ FUN_0047fd10
    A.SendPlayerAllScoreInfo(p, 1); (A.no == B.no ? A : B).SendPlayerAllScoreInfo(p, 0)

PlayerUnRegister(p) → bool                                @ FUN_0047fd50
    g by p.guildNo (none → sink 0x1B4F, false); m = member with p's handle (none → false)
    g.m_mapOutMemberBackUps[p.name] = m (insert or overwrite); erase m from m_vecGuildMembers
    g.CheckManagerUser(); g.SetSkillPoint(g.m_unKillerPoint) (§5: re-evaluates the usable skills)
    → WM 0x74C9 NC_GUILD_TOURNAMENT_ZONE_FIGHTER_OUT_CMD {u8 nTournamentSeed = (u8)m_nTournamentType (!), u32 nGuildNo,
        u32 nCharNo}     # writes the tournament type into the seed field (original bug) Z16-B10; the 2016 WM ignores it
    true

IsPlayerRegister(p) @ FUN_0047a160: p's guild is A or B (else sink 0x1B4F, false) and its member list has p's handle
IsBattleGuild(g1, g2) @ FUN_00478db0: {g1, g2} == {A.no, B.no} in either order
GetGuildRegIndex(p) @ FUN_00478df0: 0 = guild A, 1 = guild B, 100 = neither (no member check)

Zone hooks:
    map login complete (sp_NC_MAP_LOGINCOMPLETE_CMD @ FUN_00443390, Z01), on a tournament map (fm_IsGuildTournametnMap):
        early: off a tournament map → vt 0x650 (reset abstate); on one with abstate STA_OBSERVERHIDEMODE: layer = {0, 2};
               SendMapInPlayerInfoToObserber(p) if the map has a system
        late:  not observer: system and (PlayerRegister(p) or IsPlayerRegister(p)) → stay; else sp_2Roumen(p)
               observer: no system → sp_2Roumen(p)
    so_Unmark(REMOVE_NOW) @ FUN_00558900: PlayerUnRegister(p) if the map has a system
        # REMOVE_NOW is the logout (sp_Schedule_Logout) and the same-zone link (Z01 map link); REMOVE_REVIVE (link
        # command 0x4f), REMOVE_WARP and REMOVE_LOGOUT skip it: such a fighter stays in m_vecGuildMembers with a stale
        # handle until the system is cleared *(inferred)*
    0x204B NC_ACT_ROAR_REQ @ FUN_005404d0 (Z02 §9.2): a registered fighter gets 0x0720
    `NPCAction::GT_TeamCondition` @ FUN_005c2890 / FUN_005c2920 (Z09 §16.4): GetGuildRegIndex == team
    combat enemy test `fm_GuildTournamentEnemy(g1, g2)` @ FUN_004632f0 = IsBattleGuild (Z03 §3.1, §3.3)

FlagRegister(flag, nameA, nameB) → true                   @ FUN_00480970   (Pine `RegisteFlag`, Z09 §25.7)
    push FlagInfo {guild 0, handle flag, AType nameA, BType nameB, NormalType = flag's current mob index name (vt 0x894),
        score timer delay OccupyTime(type)·10/1000 (60000 ms → 600 ticks), disabled; portal handle 0xFFFF}
GateRegister(gate, guildNo, hFlag, useName) → bool        @ FUN_00480ab0   (Pine `RegisteGate`, Z09 §25.7)
    g = group with m_GuildNumber == guildNo (none → sink 0x1B4F, false)
    g.m_vecGuildGates.push {bIsUse false, hFlagNumber hFlag, hGateNumber gate, strunUseGateName = gate's index name,
        strUseGateName = useName}; true                                     # the gate's open / closed looks
PortalResiter(portal, hFlag, nameA, nameB) → true         @ FUN_0047ccf0   (Pine `RegisterGTPortal`, Z09 §22.4)
    every flag with m_ObjectNumber == hFlag: m_PortalInfo = {portal handle, AType nameA, BType nameB,
        NormalType = portal's index name}
```

### 4.5 Flag capture

The cast (0x74CA, `so_ply_FlagCaptureCast`, 4 s cast bar) and its end callback `so_ply_FlagCapture` are §6; they set the
error sink and call these.

```pseudo
IsFlagCapture(p, hFlag) → bool                            @ FUN_00479510
    p's guild must be A or B (else sink 0x1B4F, false); flag with handle hFlag: true when its owner == p's guild
    (vt 0x828, the same guild getter) # "already captured by you" test (0x1B48 in the cast)
IsUseGate(p, hFlag, hGate) → bool                         @ FUN_004795d0   (Pine `@IsGateUse`, Z09 §22.2)
    IsFlagCapture(p, hFlag) and p's group has a gate {hFlagNumber hFlag, hGateNumber hGate}

CaptureFlag(p, hFlag) → bool                              @ FUN_0047eae0
    g = p's group (none → sink 0x1B4F, false); isA = (g == A)
    f = flag entry with handle hFlag (none → false)
    o = som_GetObject(hFlag): missing → sink 0x1B41 ("You tried to capture NPC, not the flag"), log, false;
        so_ObjectType (vt 0x4d0) ≠ 4 (NPC) → log name, sink 0x1B41, false
    cur = o.so_mob_MobID (vt 0x708); idA = mobID(f.AType); idB = mobID(f.BType)
    new = isA ? (cur == idB ? Normal : idA) : (cur == idA ? Normal : idB)      # enemy flag → neutral; else → own colour
    new == 0xFFFF → log "GuildTourmentSystem::FlagCapture Not Find Flag Change Type ", false
    portal = NPC at f.m_PortalInfo.m_Handle (may be none)
    if cur == idA or cur == idB:                         # neutralising an owned flag
        f.m_GuildNumber = 0; owner = 0; f.m_FlagScoreTimer.Enable(true)
        (the group that is not p's).ChangeGateState(false, hFlag) (§5)
        portal: look = Normal
    else:                                                # taking a neutral flag
        f.m_GuildNumber = owner = p.guildNo; f.m_FlagScoreTimer.Enable(true)    # scoring restarts from 0
        g.ChangeGateState(true, hFlag)
        portal: look = isA ? AType : BType
    portal: sm_InitBriefInfo(handle, mobID(look), 0) (vt 0xf70: becomes that mob) and SendBriefChange(portal)
    flag:   sm_InitBriefInfo(handle, new, 0); SendBriefChange(flag)
    AxialListFlagCaptureCancel{hFlag} over all in the flag's map: every player → sp_FlagCaptureFreeCheck(hFlag)
        (ali_Work @ FUN_004794b0; cancels other casts on this flag, §6)
    → all in the flag's map 0x74CD NC_GUILD_TOURNAMENT_FLAGCAPTURE_RESULT_CMD {Name5 CIDPlayer = p.name,
        Name5 CIDFlag = flag name, u32 gRegGuildNo = p.guildNo, u32 gRegFlagCaptureGuild = owner (0 = neutralised)}
    p's member: m_CaptureFlagCount++; → all in p's map 0x74DD {PartMask 0, g.no, g.m_unAllGuildScore,
        g.m_nCaptureFlagCount, 1, [p's TOURNAMENT_PLAYER_SCORE]}
        # g.m_nCaptureFlagCount is not changed here (§5 decides who writes it)
    m_FlagAllConnectTime.Enable(every flag owned by p.guildNo)    # restarts the 60 s countdown on every capture
    InitFlagAbStateSetup(); true

InitFlagAbStateSetup()                                     @ FUN_00479680   (also after a War Cry item, §5)
    for each flag: owner group with m_FlagMultiple ≥ 2 → flag NPC so_AbnormalState_Set_Simple(0, STA_GTIRATEPOINT
        (366), 1, 1); else (neutral or multiple 1) → so_AbnormalState_Reset(STA_GTIRATEPOINT)

SendBriefChange(o)                                         @ FUN_00478e40
    → all in o's map 0x1C09 NC_BRIEFINFO_MOB_CMD {u8 count 1, o.so_FillBriefInformation (vt 0x4c4, 0x95 bytes)}
```

Client 0x74CD (GuildTask FUN_006b64f0): ignored when `gRegGuildNo` is 0; text TextData2 0x20588487 "%s of %s Guild
captured the flag of %s" or, when `gRegFlagCaptureGuild` is 0, 0x14542566 "%s of %s Guild neutralized the flag of %s"
(player, guild name from the client's tournament list, flag), coloured by whether the capturer is the enemy; then
`Char::StopFlagCapture` on the capturing character (ends its capture animation).

### 4.6 Kills, scores, advantage and the enemy scan

```pseudo
DeadPlayer(victim, killer)                                 @ FUN_0047e640
    caller: ShineMobileObject::so_KilledBy @ FUN_00432240 (any victim with a map, Z03 §7) when the map has a system
    both non-NULL; vg = victim's group, kg = killer's group (either missing → sink 0x1B4F, return)
    vm = victim's member, km = killer's member (missing → log "GuildTourmentSystem::DeadPlayer Not Find Player : <name>")
    # a monster or non-fighter killer stops here: no score, no message
    if victim.guild ≠ killer.guild:
        s = ScoreTable.GetScore(type, km.grade, vm.grade)
        s = LvGapTable.BalanceScoreMediate(type, s, killer.level (vt 0x4d8, low byte), victim.level)
        kg.AddScore(s) (§5); km.m_unInCreaseScore += s; km.m_KillCount++
        vg.SetSkillPoint(vg.m_unKillerPoint + 1)        # the dying side earns a guild skill point (§5)
        vm.m_unDeCreaseScore += s; vm.m_DieCount++
        → all in the map (anchor vg.m_pManageruser / CheckManagerUser) 0x74DD {0, vg.no, vg.all, vg.capt, 1, [victim row]}
        → same anchor 0x74DD {0, kg.no, kg.all, kg.capt, 1, [killer row]}
    → victim's guild members in range (AxialListPacketBroadcastByGuild, so_AllOfRange with the all-of-range argument)
        0x74DE NC_GUILD_TOURNAMENT_PLAYERDIEMSG_CMD {Name5 VictimCharID, Name5 MurderCharID, int VictimGuildGrade = vm.grade}
    → killer's guild members likewise 0x74DF NC_GUILD_TOURNAMENT_PLAYERKILLMSG_CMD {same body}
    ChangeAdvanRule()

ChangeAdvanRule()                                          @ FUN_0047a2d0
    gap = |A.all − B.all| (low 16 bits); bLeads = B.all > A.all
    if gap == 0 or the GTIGetRateGap table is empty: return     # equal scores keep the old advantage (original bug) Z16-B12
    level = first row index i with gap < row[i].Gap, else count − 1      # 2016: < 200 → 0, < 500 → 1, else 2
    A.SetAdvan({m_IsAdvan = bLeads, level}); B.SetAdvan({!bLeads, level})   # the trailing guild gets the advantage (§5)

SendScorePacket(g)  (0x28: buffer[17], m_pPacket → buffer, vector<TOURNAMENT_PLAYER_SCORE>)   @ FUN_0047ddb0
    header {PartMask 0, regNumber g.no, unAllScore g.m_unAllGuildScore, unCaptureFlagCount g.m_nCaptureFlagCount, 0}
    SendtoPlayer(p, mask) @ FUN_00479d50: → p (game stream vt 0x2fc) 0x74DD with PartMask = mask, unPlayerNum = rows
    SendtoAllinMap(o, mask) @ FUN_00479ec0: same packet to all in o's map; o NULL → nothing
    dtor FUN_0047dad0
Make_TOURNAMENT_PLAYER_SCORE(row, p, m) @ FUN_00479080: {CharID p.name, unIncreaseScore, unDecreaseScore, unDieCount,
    unKillCount, unGuildGreade = grade, unCaptureFlag} from m

ScanEnemyUser(p)                                           @ FUN_0047a3d0
    caller: SubAbnormalStateActor::sasa_Routine @ FUN_00406d50 for an abstate with the SAA_SCANENEMYUSER effect (a GT
    item, §5), when p's map has a system
    p registered; e = the other group (A if p is not in A)
    → p 0x74F3 NC_GUILD_TOURNAMENT_ITEM_SCAN_CMD {u16 nNum, SHINE_XY_TYPE loc[nNum]}: every member of e that exists and
        has neither STA_HIDE (75) nor STA_GTIHIDE (373) (vt 0x3e4 so_AbnormalState_IsSet)
```

Client: 0x74DD (GuildTask FUN_006b26d0) feeds `GTStatusMiniWin` / `GTStatusWin`: PartMask 1 clears both windows and
adds the rows (with 0 rows the guild totals are not updated), PartMask 0 adds / updates rows or, with 0 rows, only the
guild totals; the mini window is shown unless the big one is open. 0x74DE (FUN_006b5440): victim == me → TextData2
0xe5f5ec07 "You have been killed by %s"; else VictimGuildGrade 0 → 0x4f3d8783 "Our Guild Master %s has been killed by
%s", else 0x90a3a8ed "%s has been killed by %s". 0x74DF (FUN_006b5680): 0xdd093b47 "%s has killed %s". 0x74F3
(FUN_006b3b40): nNum 0 → ignored; else `MiniMapWin::ClearGTEnemyPos` and one `AddGTEnemyPos(x, y)` per entry. 0x7483
(FUN_006b4730): stores A, B, type and the own number; A or B 0 → TextData 0x38281f8b "There is no match opponent"; else
the enemy is B if the client's guild is A, otherwise A (name from `CClientGuild::FindGttEnemyInfo`).

### 4.7 Result, master revive, error sink, map helpers

```pseudo
EndBattle(&tGuildTournamentResult) → true                 @ FUN_004803f0   (Pine `gtresult result`, Z09 §24.8)
    {AGuildRegNumber A.no, u16 AGuildScore = (u16)A.all, BGuildRegNumber B.no, u16 BGuildScore = (u16)B.all}
    empties m_vecFlags (captures and flag scoring stop; groups and members stay until Clear)
GetVictoryGuild() @ FUN_004790e0 / GetLoseGuild() @ FUN_00479100: by m_unAllGuildScore; equal → 0 (Pine
    `@GetWinnerGuild` / `@GetLoseGuild`, Z09 §22.2)
GuildMasterRevive(p)                                       @ FUN_0047a260   (from sp_ReviveReqProcess, Z07 §3.1)
    p's group (none → sink 0x1B4F); if p is the group's master (GetGuildMaster, §5): m_LastGuildMasterReviveTime.Enable(true)
SetErrorDelegate(d) @ FUN_0047a1f0 / ClearErrorDelegate() @ FUN_0047a230: set / clear the sink of the system, both
    groups and the dice game; set around the 0x74CF / 0x74D3 requests and so_ply_FlagCapture (§6)

so_SaveLocation(p, &NC_CHARSAVE_LOCATION_CMD) @ FUN_004542f0, tournament branch (map has a system, no roll-back event):
    map = the current map, coord = p's position; if p is dead (mode 3): CurHP = maxHP / 3 and coord = the map's
    regenloc[GetGuildRegIndex(p)] (index 100: position kept; ≥ 4 otherwise: regenloc[0] + assert "…Guild Map Revive
    Point Low") — the same team revive points as sp_ReviveReqProcess

fm_IsGuildTournametnMap() @ FUN_00475770: cached in m_nGuildTournamentMapFlag (1 yes, 2 no); compares fm_MapID with the
    13-byte entries `GTMap[i].mapname` (DAT_0d55a860) for i = 0…30 (§6: seed table, Z08-B12)
fm_GuildTournamentEnemy(g1, g2) @ FUN_004632f0 = system && IsBattleGuild(g1, g2)
```

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z16-B1 | `ShineMob::so_KilledBy` FUN_00432760 (KQ branch) | a killer whose zone party record has < 2 or > 5 members, or a party number ≥ 4000, asserts and returns from the whole kill handler | on a KQ map such a kill gives no experience, no drop, no quest progress | assert and continue with the rest of the kill |
| Z16-B2 | 0x580D @ FUN_00497790 | the success flag is overwritten per map slot; the 0x580E reply is sent only when the last listed map is local | a KQ whose last map is on another zone is built but never acknowledged (refines Z08-B8) | track "all maps found" separately from "reply now" |
| Z16-B3 | 0x580D @ FUN_00497790 | maps claimed in earlier loop passes keep `fm_KQHandle` / `fm_KQID` when a later check or the container allocation fails | the instance is unusable for every later KQ ("Not empty2") until restart | reset the claimed maps on every error exit |
| Z16-B4 | 0x581A @ FUN_00496990 | links to map 0 for any known handle without checking the player is a joiner (and masks only the low 16 bits) | a non-joiner can be linked into the KQ map; it bounces to Roumen at map login unless GM | check `kqpil_IsKQJoiner` before the link |
| Z16-B5 | `sp_GetJoinKQTeamType` FUN_00563990 | compares the 32-bit `fm_KQHandle` with 0xFFFF | on a KQ map without a KQ, every map login logs "Cannot found KQ Element" | compare with 0xFFFFFFFF |
| Z16-B6 | Lua `cGetKQLimitSecond` FUN_005e5390 | tests the u16 `LimitTime` against 0xFFFFFFFF | dead check: the nil branch can never be taken, every KQ returns `LimitTime · 60` (0 for `LimitTime` 0) | compare with the u16 "no limit" value (0xFFFF, *(inferred)*) |
| Z16-B7 | `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 / `sp_ReviveReqProcess` FUN_00451bd0 | the `bs_ClearAtLink` reset runs only off KQ maps, where `so_GetBattleStat` returns the shared `so_DefBattleStat` | a player's KQ statistics are never reset by it; only the shared default object (written by every non-KQ fight) is cleared | keep the statistics per player and reset them at the link out of the KQ |
| Z16-B8 | `AxialListKQReward::ali_Work` FUN_00428490 (`reward` / `cReward`) | rewards every player on the map whose kill count reaches `DemandMobKill`, without a joiner or admin-level check (the result list skips GMs) | with `DemandMobKill` 0 GMs and non-joiners on the map get the KQ reward chest, cen, fame and EXP | reward joiners only (`kqpil_IsKQJoiner`), skip GMs |
| Z16-B9 | `GuildTournamentSystem::Update` FUN_0047e0e0 | the win-score lookup tests whether the GTIGetRateGap table has rows, then reads row 0 of GTWinScore | an empty or missing GTIGetRateGap falls back to 2000 points although GTWinScore says 4000; an empty GTWinScore with a non-empty GTIGetRateGap reads a missing row | test the GTWinScore table it reads |
| Z16-B10 | `GuildTournamentSystem::PlayerUnRegister` FUN_0047fd50 | 0x74C9 FIGHTER_OUT carries `(u8)m_nTournamentType` in its `nTournamentSeed` field (0x74C8 carries the seed) | wrong seed on the wire; harmless only because the 2016 WM ignores the field (W03 §8.3) | send `m_nTournamentSeed` |
| Z16-B11 | `GuildTournamentScoreTable::GetScore` FUN_005c7080 | a victim grade > 6 asserts but still reads `GradeScore[grade]` past the 7-entry row | the kill score comes from the next row's MAP_TYPE / scores | return 0 (or clamp) after the assert |
| Z16-B12 | `GuildTournamentSystem::ChangeAdvanRule` FUN_0047a2d0 | returns without touching either group when the scores are equal | after a tie the guild that trailed before keeps its comeback advantage although nobody trails | clear both advantages when the gap is 0 |

## N. Not reconstructed / uncertain

- Parts 1–3 (KQ, GT core §4). GT groups / dice / items (§5) and the match lifecycle (§6) follow in later parts; see
  `docs/plan/status/Z16.md`.
- §4.4: a fighter who leaves the tournament map through `so_Unmark` with REMOVE_REVIVE / REMOVE_WARP / REMOVE_LOGOUT
  is not unregistered there; whether another path (`sp_2Roumen`, the cross-zone link, §6) removes the entry from
  `m_vecGuildMembers` was not traced.
- §4.6: the range of the 0x74DE / 0x74DF broadcasts (`allofrangearg`) was not resolved; read as the whole map.
- `bs_SkillBlast`: the `so_Routine` branch that counts it tests `scs_ProduceSkill.sklidx`; whether that is every
  skill blast or only the production-skill step was not traced (Z03).
- 0x5817 after `sp_KQReward`: what the client shows for a reward-box chest whose DB rows were never created
  (the contents are already in `ItemsInChest`) was not traced.
- How the client produces `EncHandle` for 0x581A (Z08 open point) is still open.
- 0x5818 `number = 0` for unlimited revives: whether the client shows 0 or hides the counter was not traced in
  `KQuestTimeWin::SetRestLife`.

## N+1. Coverage boundary

(Written in the sweep part.)
