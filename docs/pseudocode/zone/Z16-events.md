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
                                         # write-only: kqe_QuestStart and KQElement::operator= FUN_00499140 are its
                                         # only writers, nothing reads it (no zone-side KQ time limit, see §2.2)
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
    # List<T> is the zone's fixed-slot free list (Z01): l_MakeList FUN_004973f0 (KQElement) / FUN_00497570 (KQPlayerInform,
    # §1.3), push / pop FUN_004998c0 / 00499900 / 00499940 / 00499990 and FUN_00495290 / 00497270 / 004952d0 / 00495320
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
            el.kqe_Stop = el.LimitTime · 600 + now                        # minutes → 100-ms ticks; never read:
                # the zone enforces no time limit itself; the KQ ends when the map script calls cEndOfKingdomQuest
                # (it reads the limit through cGetKQLimitSecond, §3.5) or the WM ends it (§2.5)
            for each map slot with a local instance f:
                f.fm_Multiflex.cc_DropFilm(kqe_Script)                    # stop a film of that name (Z09 §27.5)
                f.fm_BlockInfo.mbi_DoorBlockInform.mda_CloseAllDoor()     # FUN_0049e1e0: every door → DA_CLOSE
                                                                          # ("…mda_CloseAllDoor : Close error")
                f.fm_Multiflex.cc_PlayFilm(kqe_Script, kqe_InitValue, f)  # the KQ map script starts
        for each joiner j: el.kqe_PlayerList.kqpil_InsertPlayerInfo(j.chrregnum, j.nTeamType, isJoiner 1)
    slot = kqentrance[this body]                                          # §1.5 (≤ 100 joiners)
    link = { linktoserver = el map 0 MapName, linktoclient = map 0 MapBase, coordx/coordy = map 0 MapInfo RegenX/RegenY }
        # index[20], direct and Party stay uninitialised stack bytes; so_LinkTo (FUN_0049ad30) itself reads only the
        # names and coordinates (Z09 §17.7), but its link-reserve path (vt 0x3fc so_LinkToReserv) copies the whole
        # struct; whether those bytes are read later was not traced (Z01 §7.1, N.)
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
    # boilerplate: ctor FUN_0064c020 (empty map); the file is read by `BinaryDataBox<KQItem>::bdb_ReadData` FUN_00648f70
    # (CDataReader::Read; failure → assert "…bdb_ReadData : readfail" and ShineExit)
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
The other loaders are the same template with their own key: LvGap FUN_005b26c0 (0x17), Occupy FUN_005b27a0 (0x12),
Skill FUN_005b2880 (0xfb), MasterBuff FUN_005b2960 (0x2c), GTWinScore FUN_005b2dc0 (1). Boilerplate (no logic): the table
ctors FUN_005b10e0 (Score) / 005b11a0 (LvGap) / 005b11e0 (Occupy) / 005b1220 (Skill) / 005b12e0 (MasterBuff) / 005b1420
(GTWinScore) and the row counters `ITableBase<…>::GetTotal` FUN_005c6ee0 / 005c6f00 / 005c6f20 / 005c6f40 / 005c6f60.

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
    A.SendPlayerAllScoreInfo(p, 1); (A.no == B.no ? A : B).SendPlayerAllScoreInfo(p, 0)    # §5.2: full score lists to p,
                                                                    # p's own row to the whole map
    if g.m_FlagMultiple > 1: → p 0x74F2 NC_GUILD_TOURNAMENT_ITEM_FLAG_CMD {u8 FlagScoreMultiple, u32 nGuildRegNo = g.no}
    true

SendMapInPlayerInfoToObserber(p)                          @ FUN_0047fd10
    A.SendPlayerAllScoreInfo(p, 1); (A.no == B.no ? A : B).SendPlayerAllScoreInfo(p, 0)

PlayerUnRegister(p) → bool                                @ FUN_0047fd50
    g by p.guildNo (none → sink 0x1B4F, false); m = member with p's handle (none → false)
    g.m_mapOutMemberBackUps[p.name] = m (insert or overwrite); erase m from m_vecGuildMembers
    g.CheckManagerUser(); g.SetSkillPoint(g.m_unKillerPoint) (§5.2: re-sends 0x74CE to the, possibly new, manager user)
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
        # PlayerUnRegister has no other caller. `RemoveWhen` *(pdb2016)*: REMOVE_NOW 0, REMOVE_LOGOUT 1, REMOVE_WARP 2,
        # REMOVE_REVIVE 3. so_LinkTo FUN_0049ad30 passes REMOVE_NOW for a same-zone link and REMOVE_REVIVE when the reply
        # cmd is 0x4f (revive link, Z01 §7.1); the cross-zone link calls so_banning(p, 0) FUN_00558b70 = so_Unmark(REMOVE_NOW);
        # the WM kick-off so_banning(p, 1) (Z01 §8.3) is REMOVE_LOGOUT, which arms `sp_Schedule_Kickout` FUN_00558080 (10 s),
        # and that calls so_Unmark(REMOVE_NOW) (as does the normal logout); REMOVE_WARP comes only from smo_ShadowStep
        # FUN_0045ad10 / smo_LoginAfterLogout FUN_0055d880 (the object stays on the map). So only a same-zone revive link keeps the fighter
        # registered: the team-point revive inside the tournament map (sp_ReviveReqProcess, Z07 §3.1) needs exactly
        # that *(inferred)*. Should such a revive lead to another map, the entry (old handle) stays until Clear.
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
        # g.m_nCaptureFlagCount is not changed here: ChangeGateState above writes it (§5.4)
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
    → victim's guild members in range (AxialListPacketBroadcastByGuild, victim.so_AllOfRange with the all-of-range
        argument, centred on so_mob_RegenLocation(killer); 0x74DF below uses the same centre)
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
    13-byte entries `GTMap[i].mapname` (DAT_0d55a860) for i = 0…30 (§6.1: seed table, Z16-B17 settles Z08-B12)
fm_GuildTournamentEnemy(g1, g2) @ FUN_004632f0 = system && IsBattleGuild(g1, g2)

ShineMover::so_mobile_IsEnemy(v, d)  (vt 0x72c of a mover, a ridden vehicle)   @ FUN_004309a0
    # the mover copy of ShinePlayer::so_mobile_IsEnemy (Z03 §3.3); its two GT tests:
    d = d.owner (vt 0x9b0) or d; d == v or v has no map → false
    d mob-like (vt 0x89c):
        same side (vt 0xe60 ShineMover::so_IsAlliance) → false
        map has a GT system and d.guild reg num == v's (vt 0x828 so_mobile_GetGuildRegnum) → false   # own flags, gates, team NPCs
        v captivated (vt 0xf20) or d has abstate 499 → false
        StaImmortal (0x123) rest time (vt 0x3ec): 0 → true; < 3600 → reset it (vt 0x650), true; else false
    d.vt[0xc70]() (so_MoverSystem_NoDamage, *(pdb2016)*) == 0 → false     # the player version returns false on == 1
    d is a captivated player or v is captivated (vt 0xf20) → true
    fm_PKField (+0x54) == 1 → true
    fm_MapInfo (+0x10) != null → false                 # every real map: the rest is never reached
    # the rest reads fm_MapInfo->KingdomMap through that null pointer: assembly 0x430af1 `cmp byte ptr [0x3a], 4`
    KingdomMap == 4 and v.so_mobile_ICanDamageTo(d) (vt 0x980) → true
    party-battle map row (+0x69): v.party == −1 or parties differ → true
    CGuildZone::IsGuildEnemy(v.guild, d.guild) == 1 or fm_GuildTournamentEnemy(v.guild, d.guild) → true; else false
    # the null test is inverted against ShineMover::so_mobile_ICanDamageTo (Z09 §8.4: `fm_MapInfo == null` → false), so a
    # mover never counts an enemy-guild fighter as enemy in a tournament, a guild war or a party-battle map
    # (original bug) Z16-B21
```

## 5. Guild tournament: guild groups, guild skills, items and the dice game

Each `GuildTournamentSystem` holds two `GuildTournamentSystem::GuildGroup` objects (A, B; §4.1) and one `DiceGame`.
This section covers their methods, the guild-skill request (0x74CF), the item boxes (`GTIEffect` NPC action and the
GTI* tables) and the dice game (Pine `DiceGameStart`, 0x74D3). Errors go to the *error sink*: the group's own
`m_ErrorMessage` (+0x34) or the dice game's `m_ErrorDeleGate`, which `SetErrorDelegate` sets together with the system's
(§4.7); outside a request the sinks are empty and errors are silent. Error texts: `docs/protocol/client-error-codes.json`
(0x1B4B "You cannot use Guild Skill because of Point Lack", 0x1B4C "You have no authority on Guild Skill or Dice Game",
0x1B4D "Relevant Skill is invalid", 0x1B4E "The Dice is cast", 0x1B4F "You are not the participated Guild Tournament
user", 0x1B50 "Guild Skill on Cooltime", 0x1B53 "It is not a Dice Game period"; 0x1B40 = success).

### 5.1 `GuildGroup` and `DiceGame` layouts *(pdb2016)*

```pseudo
GuildGroup (0xb4)
    +0x00 m_GuildNumber          guild of this side (Initialize)
    +0x04 m_mapOutMemberBackUps  map<charName, GuildMemberInfo>: members who left the map (PlayerUnRegister), restored on return (§4.4)
    +0x14 m_vecGuildGates        vector<Gate> (0x40 each, GateResiter §4.4)
    +0x24 m_vecGuildMembers      vector<GuildMemberInfo> (0x1c), sorted by grade: [0] is the guild master when its grade is 0
    +0x34 m_ErrorMessage         FastDelegate1<int> error sink
    +0x3c m_unAllGuildScore      match score (flag ticks, kills, dice; the win check and the result use it)
    +0x40 m_unKillerPoint        guild-skill points (+1 per own death, §4.6; spent by UseGuildSkill)
    +0x44 m_unGuildScore         same increments as +0x3c (AddScore, flag tick in Update, DiceGameWinGuild; zeroed by Clear); no reader in the zone: write-only
    +0x48 m_UseSkillCount        only zeroed by GuildGroup::Clear FUN_00480460; never counted or read
    +0x4c m_nTournamentType      MAP_TYPE for the skill / master-buff tables
    +0x50 m_vecGuildBuffUseTime  vector<TickTimer>: one cool-down timer per guild skill (index = skill number)
    +0x60 m_LastGuildMasterReviveTime  TickTimer, delay 300 (30 s): master buff again after the master's revive
    +0x70 m_nCaptureFlagCount    gates of this side in the "used" state = flags it holds (ChangeGateState, §5.4)
    +0x74 m_pManageruser         ShineObject*: the first online member in grade order; anchor of broadcasts and the
                                 only member allowed to use guild skills and throw the dice
    +0x78 m_vecAdenItemInfo      vector<AdvanMobItemRegenInfo> (0x2c: Name3 mapName, string strGroupName, u32 AdvanIndex)
    +0x88 m_Advan                {bool m_IsAdvan, int m_nLevel 0…2} comeback advantage (ChangeAdvanRule §4.6)
    +0x90 m_FlagMultiple         flag-score multiplier, 1 normally, 2 for 60 s after a GTI_Bless item
    +0x94 m_FlagMultiplelTime    TickTimer, delay 600 (60 s)
    +0xa4 m_MyTeamNPCs           vector<u16> NPC handles of this side (Pine GTRegisterNPC → AddTeamNPC)

DiceGame (0x48; vftable +0: Update)
    +0x04 m_RedPlayerNumber, +0x08 m_BluePlayerNumber   charNo of A's / B's manager user at the start
    +0x0c m_RedDiceResult, +0x10 m_BlueDiceResult       0 = not thrown yet, else 1…6
    +0x14 m_StartTime (no access anywhere in the zone)
    +0x18 m_nDelayTic         TickTimer: throw period; enabled = "dice game running"
    +0x28 m_NotifyOfEndTimer  TickTimer: "5 seconds left" notice
    +0x38 m_ErrorDeleGate, +0x40 m_DiceGameEnd (= GuildTournamentSystem::DiceGameWinGuild, set by the ctor)
```

Boilerplate (no logic): `AdvanMobItemRegenInfo` dtor FUN_0047aa60, `PortalInfo` ctor FUN_0047b8b0 / dtor FUN_0047abc0,
`FlagInfo` ctors FUN_0047ac30 / FUN_0047bc80 and dtor FUN_0047ace0, `Gate` ctor FUN_0047b810 / dtor FUN_0047ad50,
`GuildGroup` dtor FUN_004802d0; table getters `ITableBase<GTIGetRateGap>::GetTotal` FUN_00479040, `<GTIServer>` FUN_00479060,
`<GTIGetRate>` FUN_005c6f80, `<GTIBreedSubject>` FUN_005c6fa0. The folded `CGambleObject::go_Get_MaxEnterPlayerCnt`
used on TickTimers reads `m_bEnable` (+8): "timer running".

### 5.2 Manager user, win event, scores

```pseudo
GuildGroup::CheckManagerUser()                               @ FUN_004798f0
    first member (grade order) whose handle is a live object:
        already m_pManageruser → return
        m_pManageruser = it; → guild members of this side in its map (AxialListPacketBroadcastByGuild(m_GuildNumber),
            so_AllInMap includeSelf 1) 0x74E1 NC_GUILD_TOURNAMENT_MANAGERUSERMSG_CMD {Name5 CharID = its CharName}
            # client GuildTask FUN_006b55d0: "Guild Skill Use Authority is transferred to %s"
    none online: m_pManageruser = NULL (no packet)
    # the pointer is not cleared when the object leaves; PlayerUnRegister re-runs CheckManagerUser (§4.4)

GuildGroup::GetGuildMaster() → ShineObject*                  @ FUN_004798a0
    members[0] if it is a live object and its grade is 0, else NULL

GuildGroup::SendWinEventToScript()                           @ FUN_0047a580
    anchor = m_pManageruser, else CheckManagerUser(); none → return (the win is not reported)
    fm_ScriptInterrupt(anchor's map, ScriptInterruptManager::sim_UnitEvent, InterruptEventWinGuild{m_GuildNumber})
    # the map script's `WinGuild` unit interrupt fires (Z09 §15.6); the script ends the match (gtresult, Z09 §24.8)

GuildGroup::AddScore(n)                                      @ FUN_0047af50   (DeadPlayer, §4.6)
    m_unAllGuildScore += n; m_unGuildScore += n
    win = GTWinScore row 0 (4000), 2000 when GTIGetRateGap is empty    # same wrong table test as Update (original bug) Z16-B9
    m_unAllGuildScore ≥ win → SendWinEventToScript()
    # no 0x74DD here: the caller sends it

GuildGroup::SetSkillPoint(n)                                 @ FUN_0047afa0
    m_unKillerPoint = n
    members not empty: anchor = m_pManageruser or CheckManagerUser() (none → return)
        → anchor only (data stream vt 0x2f8) 0x74CE NC_GUILD_TOURNAMENT_SKILLPOINT_CMD {u16 wSkillPoint = (u16)n}
        # client FUN_006b2660: updates GTTSkillWin / GTTMiniSkillWin and opens the mini skill window
        # only the manager user sees the points; PlayerUnRegister re-sends them to a new manager (§4.4)

GuildGroup::SendPlayerAllScoreInfo(p, mask)                  @ FUN_0047f260   (PlayerRegister and map login, §4.4)
    p NULL: return
    pkt = SendScorePacket {PartMask, regNumber m_GuildNumber, unAllScore m_unAllGuildScore,
                           unCaptureFlagCount m_nCaptureFlagCount}                       (§4.6)
    self = −1
    for each entry e (0x1c bytes) of m_vecGuildMembers, index i:
        e.handle == p's zone handle: self = i
        object at e.handle live: append row {CharID = its so_CharName (vt 0x56c), the entry's increase / decrease
            score, die / kill count, grade, capture-flag count}           # dead or offline entries send no row
        rows > 200: pkt.SendtoPlayer(p, mask); mask = 0     # the row vector is not emptied (original bug) Z16-B14
    pkt.SendtoPlayer(p, mask)                               # → p 0x74DD: every live member's row of this side
    self ≥ 0 (p belongs to this side) and its object is live:
        → all in p's map (SendtoAllinMap(p, 0)) 0x74DD {PartMask 0, regNumber, unAllScore, unCaptureFlagCount,
            unPlayerNum 1, [p's row]}
        # so every fighter registration also announces the newcomer's row to the whole map (both sides, observers)
    # the callers pass mask 1 for group A and 0 for group B: the client clears its score windows once, then adds B
```

### 5.3 Guild skills: 0x74CF and the cool-downs

```pseudo
GuildGroup::SetTournamentType(type)                          @ FUN_0047db00   (Initialize, §4.3)
    m_nTournamentType = type; n = GuildTournamentSkillTable::GetUseSkillCount(type, 0xFFFFFFFF)   # every row of the type
    m_vecGuildBuffUseTime cleared; for i in 0…n−1:
        row = GetStateByIndex(type, i); none → log only (the vector then has fewer entries than skills)
        push TickTimer(delay = row.DlyTime · 10 / 1000)             # ms → ticks; 2016: 30 (3 s), skill 5: 100 (10 s)

0x74CF NC_GUILD_TOURNAMENT_USESKILL_REQ {u16 wUseSkillNumber}   @ FUN_00477b20   (re-read of Z08 §8.1)
    gts = p's map system; none → 0x74D0 {err 0x1B42, 0xFFFF} (sp_NC_GUILD_TOURNAMENT_USESKILL_ACK @ FUN_00476d70)
    SetErrorDelegate(sp_NC_GUILD_TOURNAMENT_USESKILL_ACK of p)      # every error below → p 0x74D0 {err, 0xFFFF}
    if gts.GuildBuffUse(p, wUseSkillNumber):
        sp_NC_GUILD_TOURNAMENT_USESKILL(p, 0x1B40, n)               @ FUN_00475bd0
            → p (game stream) 0x74D0 NC_GUILD_TOURNAMENT_USESKILL_ACK {u16 err 0x1B40, u16 wUseSkillNumber n}
            n ≠ 0xFFFF → all in p's map 0x74D1 NC_GUILD_TOURNAMENT_USESKILL_CMD {u32 regGuildNumber = p.guildNo, u16 n}
    ClearErrorDelegate()
    # client 0x74D0 FUN_006b3440: 0x1B40 → GTTSkillWin::StartCoolTime(n), else the error text in the chat window;
    # 0x74D1 FUN_006b66e0: "%s Guild used the Skill %s" (guild name from the client's tournament info, skill
    # name from GuildTournamentStateDesc)

GuildTournamentSystem::GuildBuffUse(p, n) → bool             @ FUN_0047b9a0   (also GM `&useguildskill`, Z11 §6.3)
    g = group with m_GuildNumber == p.guildNo (vt 0x818)
    none → sink 0x1B4F, then sink 0x1B4F again, false       # two error acks (original bug) Z16-B15
    (g.m_pManageruser or g.CheckManagerUser()) ≠ p → sink 0x1B4C, false
    return g.UseGuildSkill(n, enemy = the other group)

GuildGroup::UseGuildSkill(n, enemy) → bool                   @ FUN_0047b140
    n < 0 or n ≥ |m_vecGuildBuffUseTime| → log, sink 0x1B4D, false
    row = GetStateByIndex(m_nTournamentType, n); none → log "GuildTourmentSystem::UseGuildSkill Not Find
        GuildTournamentState Type :<type>  ID:<n>", sink 0x1B4D, false
    cool-down timer[n] running → sink 0x1B50, false
    row.DeathPoint > m_unKillerPoint → sink 0x1B4B, false
    SetSkillPoint(m_unKillerPoint − row.DeathPoint)                 # → 0x74CE to the manager
    target = (row.TargetType == TARGET_MYGUILD) ? this : enemy; target ≠ NULL → target.EverythingGiveBuff(row.StaName)
    timer[n].Enable(true); true
    # 2016 rows (§4.2): 0 StaGldRestore 20 pts own, 1 StaGldMoveSpeedUp 15 own, 2 StaGldACMinus 80 enemy,
    # 3 StaGldSlow 50 enemy, 4 StaGldStun 60 enemy, 5 StaGldAtkUp 0 own (free, 10 s cool-down)

GuildGroup::EverythingGiveBuff(staName, unused)              @ FUN_00479760
    abstate = dic_abstate.as_FromName(staName); unknown → sink 0x1B4D (this group's), return
    for each member: live player, still in this guild (vt 0x818 == m_GuildNumber), active mode (smo_IsActiveMode):
        so_AbnormalState_Set_Simple(abstate, strength 1, 1) (vt 0x644)    # no range check: the whole side on the map

GuildGroup::Update(dt)                                       @ FUN_0047b480   (from GuildTournamentSystem::Update, §4.3)
    m_LastGuildMasterReviveTime fires → Enable(false); GuildMasterBuffRun()     # 30 s after the master's revive
    every cool-down timer that fires → Enable(false)                            # skill usable again
    m_FlagMultiplelTime fires → SetFlagMultiple(1); Enable(false)               # GTI_Bless over

GuildGroup::GuildMasterBuffRun()                             @ FUN_0047b040   (PlayerRegister of a grade-0 member, Update)
    m = members[0]; live object and grade 0:
        name = GuildTournamentMasterBuffTable::GetMasterBuff(m_nTournamentType) (2016: StaAcaMsBuf7PMain)
        known abstate → m.so_AbnormalState_Set(idx, 1, abstate, now, 0, 0xFFFFFFFF, 0, 0, 0) (vt 0x638)
```

### 5.4 Gates, team NPCs, advantage item boxes

```pseudo
GuildGroup::ChangeGateState(bUse, hFlag) → bool              @ FUN_0047e330   (CaptureFlag, §4.5)
    gate = first of m_vecGuildGates with hFlagNumber == hFlag; none → false
    bUse:  if !gate.bIsUse: m_nCaptureFlagCount++; look = gate.strUseGateName
    !bUse: if gate.bIsUse:  m_nCaptureFlagCount−−; look = gate.strunUseGateName
    gate.bIsUse = bUse
    anchor (m_pManageruser or CheckManagerUser()) → all in its map 0x74DD NC_GUILD_TOURNAMENT_SCORE_CMD
        {PartMask 0, regNumber m_GuildNumber, unAllScore, unCaptureFlagCount = m_nCaptureFlagCount, unPlayerNum 0}
    id = mdb_2MobID(look); 0xFFFF → log, false
    npc = object hGateNumber; none → false; not an NPC (so_ObjectType vt 0x4d0 ≠ 4) → log, sink 0x1B41, false
    npc.sm_InitBriefInfo(handle, id, 0) (vt 0xf70: the gate becomes that mob, e.g. open / closed gate); SendBriefChange(npc); true
    # so m_nCaptureFlagCount counts the flags this side holds that have a gate of this side

GuildTournamentSystem::AddTeamNPC(h)                         @ FUN_0047c700   (Pine GTRegisterNPC, Z09 §22.4)
    o = som_GetObject(h); none → assert "GuildTournamentSystem::AddTeamNPC Not Find Handle ", return
    g = group with m_GuildNumber == o.so_mobile_GetGuildRegnum (vt 0x828, set just before by so_mob_SetGuildRegNum)
    none → sink 0x1B4F, assert "…AddTeamNPC Not Find Cur Guild Group"
    GuildGroup::AddTeamNPC(h) @ FUN_0047c120: push h into m_MyTeamNPCs unless already present

GuildTournamentSystem::AddAdvanItemMonster(info {mapName, strGroupName, AdvanIndex}, guild)   @ FUN_00480f60
    (Pine `GTMobRegenKey <group> <AdvanIndex> <guild>`, Z09 §22.4; GuildTournament.ps: the `lose_Itembox_*` groups)
    bg = MobHatchery::mg_FindBreedGroup(mapName, strGroupName); none → assert "…Not Find BreedGroup :<name>", return
    bg.mbg_SetEnableNextRegen(false)                                    # item boxes start switched off
    g = group of guild: push info into g.m_vecAdenItemInfo
    none → sink 0x1B4F (push read in the assembly at 0x481004), assert "…AddAdvanItemMonster Not Find GuildGroup :<guild>"

GuildGroup::SetAdvan(adv)                                    @ FUN_00479ab0   (ChangeAdvanRule, §4.6)
    m_Advan = adv
    for each info in m_vecAdenItemInfo: bg = mg_FindBreedGroup(info.mapName, info.strGroupName)
        none → assert "GuildTournamentSystem::GuildGroup Not Find BreedGroup :"
        else bg.mbg_SetEnableNextRegen(adv.m_IsAdvan and adv.m_nLevel ≥ info.AdvanIndex)
    # the trailing side's item-box groups regenerate, more of them the larger the gap (level 0…2, GTIGetRateGap)
```

### 5.5 Item boxes: `GTIEffect` and the GTI* tables

The item boxes are NPCs whose click action is `GTIEffect` (`NPCAction::GTItemAction::exe` @ FUN_005c1120, Z09 §16.5):
box alive (mode ≠ 3), clicker on layer sub 0 or 1 (not an observer), clicker's map has a system → `CreateItemEffect(gts,
box, clicker, 0)`. The GM word `&gtieffect [id]` (Z11 §7.2) calls it with a fixed id.

| File (row, size) | Fields | Use | 2016 content |
|---|---|---|---|
| GTIGetRate.shn (`GTIGetRate`, 7) | u8 ID, u8 Win1, Lose1, Win2, Lose2, Win3, Lose3 | weights of the item roll; `DataProcess` @ FUN_005c7350 sums each column into `AllProbability[6]` (order Win1, Win2, Win3, Lose1, Lose2, Lose3) | 20 items, e.g. ID 2 (Speed) 150/150/160/100/180/90, ID 18 (Breed06) 2/2/1/18/0/25 |
| GTIServer.shn (`GTIServer`, 0x4c) | u8 ID, char InxName[33], TargetType SubjectTarget +0x22, u8 EnemyNumber +0x26, GTIActionType +0x27, char Index[32] +0x2b, u8 Value +0x4b | the effect rows; one ID may have several rows (Bomb 3, Virus 2) | see below |
| GTIBreedSubject.shn (`GTIBreedSubject`, 0x41) | char InxName[33], char MobIndex[32] | `GetByIndexName(name)` @ FUN_005c73e0 (linear, exact match): which mob may breed | GTI_Breed01…06 → GTI_TotemSummon |
| GTIGetRateGap.shn | §4.2 | advantage level (ChangeAdvanRule) | 200 / 500 / 1000 |

Loaded by `Table::Load<…>` FUN_005b48f0 / 005b4a30 / 005b4b70 / 005b4cb0 → `ITableBase<…>::Load` FUN_005b2a40 / 005b2b20 /
005b2c00 / 005b2ce0 (table objects FUN_005b1320 / 005b1360 / 005b13a0 / 005b13e0), same scheme as §4.2.
`GTIActionType`: 0 GTIT_ACTISKILL, 1 GTIT_ABSTATE, 2 GTIT_FLAG, 3 GTIT_MOBBREED. 2016 GTIServer rows: ABSTATE on
TARGET_ME (1): Speed, Protect, Mirror, Hide, Scan, Bomb (StaGTIBomb1 / 2 / Die); ABSTATE on TARGET_ENEMYGUILD (9): Blind,
Meta_Slime, Binding (EnemyNumber 3), ReverseOrder, Virus (Start / Move, EnemyNumber 3); ACTISKILL on TARGET_MYNPC (11):
Confusion (skill GTIConfusion), KnockBack (GTIKnockBack); MOBBREED on TARGET_MYNPC: Breed01…06 (2 × GTI_AngryWolf,
GTI_WereBear, GTI_KingSpider, GTI_Mandrake, GTI_FireNix, GTI_MiniDragon); FLAG: Bless (StaGTIRatePoint).

```pseudo
GTIGetRateTable::GetItemIDbyProbabilityCalculate(bAdvan, level) → u8 ID     @ FUN_005c7250
    level > 2 → assert "…Level Over Value :", level = 0
    col = level + (bAdvan ? 3 : 0)          # 0 Win1, 1 Win2, 2 Win3, 3 Lose1, 4 Lose2, 5 Lose3: the trailing side uses Lose
    r = rand() % AllProbability[col]
    for each row: r −= row[col]; if r < 1: return row.ID
        # picks a row when r ≤ its cumulative weight: weight-0 rows can be drawn and every row's share is off by one (original bug) Z16-B13
    (not reached with the 2016 data) assert "…Probability error :", 0

GuildTournamentSystem::CreateItemEffect(box, p, forcedID)    @ FUN_0047c1e0
    p NULL or not registered (IsPlayerRegister) → return
    g = p's group (vt 0x818); none → sink 0x1B4F, return
    id = forcedID ≠ 0 ? forcedID : GetItemIDbyProbabilityCalculate(g.m_Advan.m_IsAdvan, (u8)g.m_Advan.m_nLevel)
    → p (game stream) 0x74F0 NC_GUILD_TOURNAMENT_ITEM_PICK_CMD {u16 GTIiemID = id}
        # client FUN_006b5750: "Used %s" with the GTIView name; unknown id: nothing
    targets = []; first = true
    for each GTIServer row with ID == id (missing record → assert "GuildTournamentSystem::CreateItemEffect", stop):
        GTIT_FLAG: g.SetFlagMultiple(2); InitFlagAbStateSetup() (§4.5); continue
        targets empty → MakeGTItemTargets(targets, box, p, row) else first = false   # later rows reuse the first row's targets
        for each t in targets (stop at a NULL entry):
            GTIT_ABSTATE: a = abstate row.Index (unknown → assert "…Not Find Abstate ID :<id>", return)
                if !t.so_AbnormalState_Resist(a) (vt 0x634):
                    t.so_AbnormalState_Set_Simple(a, strength = row.Value, 1) fails → assert "templog :<id>"
                    first → t.so_ply_GtItemEffectMsg(id) (vt 0xab0, players only @ FUN_00560670):
                        → t 0x74F1 NC_GUILD_TOURNAMENT_ITEM_EFFECT_CMD {u16 GTIiemID = id}
                        # client FUN_006b57d0: GTIView kind 1 "{blue}%s Item works perfectly", 2 "{red}%s Debuff works perfectly"
            GTIT_ACTISKILL: skill = SkillDataBox::GetSkillIndexByName(row.Index) (none → assert
                "ShineObjectClass::ShineMob::sm_UseWeapon : Null skill", return)
                t is a ShineMob and sm_IsUseSkill(skill) == 1: smo_SkillBash_Casting(t, skill, target t, no spot, −1)
                    (the team NPC casts on itself; Z03); first → vt 0xab0 (no-op for mobs)
            GTIT_MOBBREED: s = GTIBreedSubject row.InxName
                s and t has a mob data box (vt 0x70c; players: none) and t's InxName ≠ s.MobIndex → skip t
                id2 = mdb_2MobID(row.Index); 0xFFFF → assert "…CreateItemEffect : Null MobIndex", return
                row.Value times: m = som_AllocObject(type 5) (none → assert "…Too many mob");
                    m.so_mob_Regenerate(t's map, t.so_mob_RegenLocation, handle, id2, …) (vt 0x6e0, Z09)
                    ok → m.so_mob_SetGuildRegNum(t's guild reg number, vt 0x828 → 0x900) (fights for t's side)
                    failed → som_FreeObject(m, REMOVE_NOW)
            other → assert "…Not Define ACtionType ID :<id>"
    # an ID with no GTIServer row does nothing after 0x74F0

GuildTournamentSystem::MakeGTItemTargets(out, box, p, row)   @ FUN_0047be70
    out NULL or row NULL → assert "GuildTournamentSystem::MakeGTItemTargets", return; out cleared
    TARGET_ME:          p if a mobile object in active mode
    TARGET_MYNPC:       g = group with m_GuildNumber == p.vt 0x828 (none → sink 0x1B4F, return); every live object of g.m_MyTeamNPCs
    TARGET_ENEMYGUILD:  the other group (A.no == p.guild ? B : A): every live member in active mode
    TARGET_BOX:         the box itself, then return (EnemyNumber ignored)
    other:              nothing
    row.EnemyNumber ≠ 0: std::random_shuffle(out); drop entries from the end until |out| ≤ EnemyNumber
```

`GuildGroup::SetFlagMultiple(n)` @ FUN_00479bd0: → all in the map of the first live member 0x74F2
NC_GUILD_TOURNAMENT_ITEM_FLAG_CMD {u8 FlagScoreMultiple = n, u32 nGuildRegNo = m_GuildNumber} (layout §4.4); m_FlagMultiple
= n; n > 1 → m_FlagMultiplelTime delay 600 (60 s); timer enabled iff n > 1. Update (§4.3) multiplies the flag score by it.
Client GuildTask FUN_006b6d40: FlagScoreMultiple > 1 → starts an effect on the object it keeps for that guild's side
(+0xbac / +0xbb0, chosen by `nGuildRegNo`; *(inferred)* the side marker) and shows TextData 0x21288084 "%s"War Cry"starts to work, Get double points from your
territories"; ≤ 1 → removes the effect and shows 0x24221e32 "Ended %s "War Cry"" (both sides see both texts).

### 5.6 The dice game

Started by the map script (`DiceGameStart 15`, Z09 §24.8: `DiceGameStart(gts, seconds × 10)` @ FUN_0047ada0, which
also sends 0x74D2 NC_GUILD_TOURNAMENT_DICEGAME_START_CMD; layout in Z09's annotation). Red = group A's manager user,
blue = group B's; nothing starts when either side has none.

```pseudo
DiceGame::Start(ticks, red, blue) → true                      @ FUN_00478ef0
    m_RedPlayerNumber = red; m_BluePlayerNumber = blue (charNo, vt 0x344); both results 0
    m_nDelayTic delay = ticks, enabled
    m_NotifyOfEndTimer delay = ticks > 50 ? ticks − 50 : ticks, enabled        # fires 5 s before the end

0x74D3 NC_GUILD_TOURNAMENT_DICEGAME_THROW_REQ {}               @ FUN_00477ba0   (re-read of Z08 §8.1)
    no system → p 0x74D4 NC_GUILD_TOURNAMENT_DICEGAME_THROW_ACK {u16 err 0x1B42} (@ FUN_00475e30)
    SetErrorDelegate(sp_NC_GUILD_TOURNAMENT_DICEGAME_THROW_ACK of p); DiceGameThrow(p) @ FUN_0047af20 = DiceThrow(p.charNo); ClearErrorDelegate()
    # no success ack: the result goes out as 0x74D5. Client 0x74D4 FUN_006b34c0: any code ≠ 0x1B40 → error text

DiceGame::DiceThrow(charNo)                                    @ FUN_0047a630
    m_nDelayTic not running → sink 0x1B53, return
    charNo == red:  red result 0 → roll; else sink 0x1B4E
    charNo == blue: blue result 0 → roll; else sink 0x1B4E
    other → sink 0x1B4C
    roll: result = rb_1000() % 6 + 1, rolled again while equal to the other side's result (no draws)
        Send_DiceThrowResult(charNo, result) @ FUN_00478f50: thrower found by charNo → all in its map 0x74D5
            NC_GUILD_TOURNAMENT_DICEGAME_THROW_CMD {u32 GuildRegNumber = thrower's guild (vt 0x818), u32 unDiceGameResult}
            (thrower gone: no packet)
        # client FUN_006b3530: stores the result under the side whose guild number 0x74D2 gave; shows own / other dice
    both results set → End()

DiceGame::End()                                                @ FUN_00479d00
    m_nDelayTic running: Enable(false); results differ and m_DiceGameEnd set → m_DiceGameEnd(winner charNo)

DiceGame::Update(dt)  (vt 0, from GuildTournamentSystem::Update)   @ FUN_0047b540
    only while m_nDelayTic runs:
    m_nDelayTic fires → DiceThrow(red); DiceThrow(blue); Enable(false)        # automatic throw for whoever has not
    m_NotifyOfEndTimer fires → o = red player, else blue player (by charNo); none → return (timer stays on)
        → all in o's map 0x74D6 NC_GUILD_TOURNAMENT_DICEGAME_BEFORE_END_TIME_MSG_CMD {u32 unEndTime = 5}; Enable(false)
        # client FUN_006b2830: only unEndTime == 5 → GTTDiceWin::SetCount(1) ("rolled automatically after 5 seconds")

GuildTournamentSystem::DiceGameWinGuild(charNo)                @ FUN_0047ba80   (= m_DiceGameEnd)
    w = som_FindPlayer(charNo); none → return                   # the winner's manager left the zone: no points
    g = w's group (vt 0x818); none → sink 0x1B4F
    g.m_unAllGuildScore += 100; g.m_unGuildScore += 100
    win check as AddScore (Z16-B9 pattern) → g.SendWinEventToScript()
    # no 0x74DD: clients see the 100 points only with the next score packet (original bug) Z16-B16
```

## 6. Guild tournament: the match lifecycle with the WM and the client

The WM owns the bracket and the schedule (W03 §8.4–§8.5). For one match it broadcasts 0x7481 to **every** zone; each
zone records the match in its seed table, the zone that hosts the instance map builds the match there, and every zone
asks the online members of both guilds to come (0x749B). The map film `Guild/GuildTournament` runs the match
(Z09 §24.7 / §24.8); its `endofgt` step reports the result (0x7482) and clears the seed. Lifecycle:

```pseudo
WM 0x7481 START_CMD ─► every zone: guildtournamentinfo[seed] = match            (§6.2)
   hosting zone:  clear map, play film, 0x74C6 ×2 → WM 0x74C7 grades, create / Initialize GuildTournamentSystem
   every zone:    online members of both guilds ← 0x749B recall prompt          (§6.3)
client 0x749C yes ─► entry window open? ─► so_ply_Summon2GuildTournament ─► so_LinkTo(instance map, team regen point)
map login on the GT map ─► PlayerRegister (§4.4) → fighting: flags (§4.5, §6.5), kills (§4.6), skills / dice (§5)
observers: 0x74D7 → WM → 0x74DA → link with StaObserverHideMode (§6.4)
film `endofgt w l` ─► fm_GuildTournamentEnd → WM 0x7482 END_CMD; fm_GuildTournamentClear (§6.6)
fallback (once a minute): film gone without a result → 0x7482 {w 0, l 0}       (§6.6)
```

### 6.1 Seed table and tournament map table

```pseudo
guildtournamentinfo  GuildTouramentLoginDataInfo[32]  @ DAT_0d55a3e0 (0x24 each; built by the vector ctor
                     FUN_00695fd0, count 0x20; ctor FUN_004757d0: gta_Field = "", nTournamentSeed = 0xFF)
    +0x00 gta_Struct         PROTO_NC_GUILD_TOURNAMENT_START_CMD (0x11): u8 nTournamentSeed (0xFF = free),
                             u16 nTournamentMapNo, u16 nExploerTimeMin, u16 nWaitPlayTimeSec, u16 nPlayTimeMin,
                             u32 nNo1 (guild A), u32 nNo2 (guild B)
    +0x11 gta_Field          Name3: the instance map of this seed (copied from GTMap[seed].mapname)
    +0x1d gta_Result2WMS     1 once 0x7482 was sent for this match
    +0x20 gta_MatchStartTime clockwatch tick of the start (0 = no match)
GTMap  {u8 mapid; Name3 mapname}[32]  @ DAT_0d55a860 (13 bytes each, directly after guildtournamentinfo)
    filled by the static initializer FUN_00695aa0: mapid = 0 for every entry (nothing writes it later),
    mapname = "GuildT0400" … "GuildT0407" repeated four times (entry i → "GuildT040" + (i mod 8))
fieldlist.fc_GuildTournamentMap  attr[GTMapNo] → FieldOption::GuildTournamentMapStr (0x131, pdb2016), loaded by
    FieldContainer::fc_Load FUN_004655f0 from table `GuildTournamentMap` of World/Field.txt:
    MapIDClient[13] (base map), GTMapNo, Stone X/Y/Dir, GldA/GldB regen X/Y, DoorA0…DoorB2, CheckSum (= GTMapNo,
    else ShineExit "Checksum error in table GuildTournamentMap(Field.txt)"; GTMapNo ≥ rows: "Too large GTMapNo";
    two rows with one number: "duplicate GTMapNo")
    2016 data: one row, MapIDClient "GuildT04", GTMapNo 0
```

So every match uses row 0 (`GuildT04`) whatever the WM chose (`nTournamentMapNo = rand() % 3` in W03 §8.4): the zone
overwrites it with `GTMap[seed].mapid` = 0. The instance is chosen by seed. The WM only starts pairs at even slots
(seed = first slot of the pair: 0…14 in round 1, 16…22, 24 / 26, final 28), so the 2016 matches use GuildT0400 / 02 / 04
/ 06. Round-1 seeds k and k + 8 share one instance, and the WM runs them at different times (Time_Match_161 for slots
0–7, Time_Match_162 for 8–15). The odd GTMap entries are never used.

The lookups below index `GTMap[gta_Struct.nTournamentMapNo].mapid`, and `nTournamentMapNo` was already replaced by
`GTMap[seed].mapid`: the row is `GTMap[GTMap[seed].mapid].mapid`, a double mapping *(inferred: probably meant
`GTMap[seed].mapid` once)*. It is harmless only because every 2016 `mapid` is 0.

**Z08-B12 settled.** `0x7481` accepts `seed ≤ 32` (assembly at 0x477a77: `cmp 0x20, seed; sbb; inc; jne`), but both
tables have 32 entries. `guildtournamentinfo[32]` is `GTMap[0…2]`: its `nTournamentSeed` byte is `GTMap[0].mapid` (0 ≠ 0xFF,
so the handler asserts "Seed not empty" and writes 0xFF there), and the start overwrites GTMap[0] / [1] and part of [2] with
the match record. `GTMap[32]` (the map number and name) is read past the array. After that, seeds 0, 1, 2 cannot start
(`GTMap[0].mapid` is no longer a valid `fc_GuildTournamentMap` index, "gtms NULL"), and `fm_IsGuildTournametnMap` no longer
recognises their instance names. Every other reader limits the seed to < 32 (0x749C, `sp_IsGuildTournamentAccessTime`,
observer enter, the check loop). This is latent in 2016 because the WM never sends a seed above 29 (W03 §8.3 / §8.4)
(original bug) Z16-B17. `fm_IsGuildTournametnMap` checks only entries 0…30. Entry 31 ("GuildT0407") repeats entry 7, so
that bound has no effect.

```pseudo
GuildTouramentLoginDataInfo::IsAccessTime() → bool                     @ FUN_004757f0
    gta_MatchStartTime ≠ 0 and now ≤ gta_MatchStartTime + nExploerTimeMin · 4800 / 10
    # 480 ticks per "minute"; clockwatch ticks are tenths of a second, so the entry window lasts
    # 0.8 · nExploerTimeMin minutes (original bug) Z16-B19
ShinePlayer::sp_IsGuildTournamentAccessTime(p) → bool                   @ FUN_00475830
    p.nTournamentSeed (p+0x5e0e) is 0xFF or > 31: false; else IsAccessTime() of that entry (inlined)
    # only reader: so_LinkTo's WM packet 0x180C byte +0x2e "inGuildTournament" (Z01 §6)
GetFieldGTMapInfo(p) → GuildTournamentMapStr*                           @ FUN_004782d0
    fc_GuildTournamentMap.attr[GTMap[gta_Struct.nTournamentMapNo].mapid]; NULL (or index ≥ rows):
    p ← 0x749D {0x1441} (_ErrorSendPlayer<…RECALL_ENTER_ACK> FUN_00478070) and NULL
GetMapInfo(p) → MapInfo*                                                @ FUN_00478320
    same lookup (0x1441 on failure); then mapdatabox[gtms.MapIDClient]; missing: p ← 0x749D {0x1443}, NULL
GetLinkData(&link, p) → bool                                            @ FUN_00478610
    gtms as above (0x1441 to p when missing; the first lookup still copies from the NULL pointer before the
        second lookup returns false: reachable only if Field.txt has no row 0)
    link.linktoserver = gta_Field (instance name), link.linktoclient = gtms.MapIDClient (12 chars)
    FieldAttr of MapIDClient (none: false)
    side = (p.guild (vt 0x818) == nNo2) ? 1 : 0          # guild B → regen slot 1; guild A and everyone else (observers) → 0
    link.coordx / coordy = FieldAttr.regenloc[side]; true
    # link.index[20], direct and Party are not written (stack bytes); so_LinkTo reads only names / coordinates,
    # the copy made by its link-reserve path (vt 0x3fc) was not traced (as §2.2)
```

### 6.2 Start: 0x7481 NC_GUILD_TOURNAMENT_START_CMD (WM → every zone)

```pseudo
0x7481 NC_GUILD_TOURNAMENT_START_CMD {u8 nTournamentSeed, u16 nTournamentMapNo, u16 nExploerTimeMin,
        u16 nWaitPlayTimeSec, u16 nPlayTimeMin, u32 nNo1, u32 nNo2}   (0x11)       @ FUN_00477a10
    seed > 32: assert "…: Invalid seed"; return                       # bound 33, Z16-B17
    guildtournamentinfo[seed].nTournamentSeed ≠ 0xFF: assert "…: Seed not empty. May be RE-Match."; set it 0xFF
    body.nTournamentMapNo = GTMap[seed].mapid (= 0)
    wms_GuildTournamantStart(body)

WorldManagerSession::wms_GuildTournamantStart(body)                   @ FUN_00476de0   (also GM `&startGT`, Z11 §6.3)
    gtms = fc_GuildTournamentMap.attr[GTMap[body.nTournamentMapNo].mapid]; NULL: assert
        "const FieldOption::GuildTournamentMapStr *gtms NULL"; return
    field = the local FieldMap named GTMap[seed].mapname (ListSearchSame over fieldlist)
    not on this zone:
        guildtournamentinfo[seed] = {gta_Struct = body, gta_Field = GTMap[seed].mapname,
                                     gta_MatchStartTime = now, gta_Result2WMS = 0}
    hosting zone:
        if field.fm_GuildTournamentInform.seed ≠ 0xFF (the instance still holds a match):
            assert "…: seed not empty. May be RE-Match."; that old seed's entry: nTournamentSeed = 0xFF,
            gta_MatchStartTime = 0; field seed = 0xFF; field's GuildTournamentSystem.Clear() (§4.3)
        field.fm_GuildTournamentInform = {seed, guildA 0, guildB 0}   # A / B are set by the film's guild battle
                                                                    # step (Movie::Theater::t_MapGuildBattle, Z09 §23.6)
        guildtournamentinfo[seed] = as above
        token = sprintf("%d %d %d %d", nNo1, nNo2, nExploerTimeMin, nPlayTimeMin)
            # an earlier sprintf of 36 values (gtms stone / regen / door coordinates, guild numbers) into the same
            # buffer is wiped by memset(0x400) before use: dead code; nWaitPlayTimeSec reaches nobody
        fm_ClearObject(field, 0x3B0)                 # NPCs, mobs, doors … of the last match leave the map (Z09 §24.8)
        cc_DropFilm(field.fm_Multiflex, "Guild/GuildTournament"); mda_CloseAllDoor(field's doors)
        cc_PlayFilm(field.fm_Multiflex, "Guild/GuildTournament", PineScriptToken(token))   # the match script, Z09
        → WM 0x74C6 NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_REQ {u8 seed, u32 nGuildNo = nNo1}
        → WM 0x74C6 {seed, nNo2}                                       # answers: 0x74C7 below (W03 §8.3)
        fm_CreateGuildTournamentSystem(field, nNo1, nNo2, type = GTMap[seed].mapid (0), seed)
    every zone, if gtms.MapIDClient is a known map (mapdatabox): every player in the player list
        (som_ListContainer[2]) → so_ply_Send2GuildTournamentLogIn(body, seed) (vt 0x928, §6.3)

FieldMap::fm_CreateGuildTournamentSystem(field, guildA, guildB, type, seed)   @ FUN_00464830
    first match on this instance: field.fm_pGuildTournamentSystem (+0xa8) = new GuildTournamentSystem (0x1e8, §4.3);
        cc_SetArgument(field.fm_Multiflex, field, axial flag[2]); flag[2].vt 0x670(cinema)   # re-binds the cinema
        push the system into flag[2]'s safm_vecRoutions (its Roution then runs with the films, §4.3)
    system.Initialize(guildA, guildB, type, seed)                       # §4.3; the object lives as long as the map
FieldMap::fm_GetGuildTournamentSystem() = fm_pGuildTournamentSystem    @ FUN_00463290

0x74C7 NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_ACK {u16 Error, u8 nTournamentSeed, u32 nGuildNo,
        u16 nGuildMemberCnt, {u32 charNo, u8 grade}[n]}               @ FUN_00476460
    Error 7000 (0x1B58): SetGuildMemberGrade(charNo, grade) for each entry
    0x1B59: log "…ERR_GUILDTOURNAMENT_MEMBERGRADE_NOT_FOUND"; 0x1B5A: "…_NOT_TOURNAMENT"; other: "%d" to GuildTournamentLog
GuildTournamentSystem::SetGuildMemberGrade(charNo, grade)  (static)   @ FUN_0047ccd0
    sm_mapGuildMemberGrades[charNo] = grade
    # one static map for all instances, never cleared: it keeps every fighter's last grade for the zone's lifetime;
    # read by PlayerRegister (§4.4). A fighter who enters before 0x74C7 arrives (or whose charNo is missing from it)
    # is not registered, and as IsPlayerRegister is then false too, the map-login hook sends them to Roumen (§4.4)
```

### 6.3 Recall: 0x749B prompt, 0x749C answer, summon

```pseudo
ShinePlayer::so_ply_Send2GuildTournamentLogIn(body, seed)  (vt 0x928)    @ FUN_00475950
    p.guild ∉ {nNo1, nNo2}: return
    p.so_ply_IsLink_OutMap_AndSendErrorMsg() (vt 0xa74, §2.3) == 0:   # the current map forbids leaving
        p ← notices "GTEntryMapErr0", "GTEntryMapErr1" (ScrString); return
    p.nTournamentSeed = seed
    p ← 0x749B NC_GUILD_TOURNAMENT_RECALL_ENTER_CMD (1 payload byte, never written: stale g_buf byte; the 2017
        struct is empty) (original bug) Z16-B18
    # client GuildTask FUN_006b5130: yes / no box "Will you accept the Tournament Recall?"; the answer is 0x749C

ShinePlayer::so_ply_GuildTournament_isSummon(p)  (vt 0x92c)              @ FUN_00475890
    # from sp_NC_MAP_LOGINCOMPLETE_CMD (Z01 §6), right after p.nTournamentSeed = 0xFF at every map login
    for seed in 0…31 with entry.nTournamentSeed ≠ 0xFF and p.guild ∈ {nNo1, nNo2}:
        entry.gta_MatchStartTime == 0 or the entry window is over (Z16-B19 formula): return
        p is on the entry's instance (map name == gta_Field): p.nTournamentSeed = seed; return
        else so_ply_Send2GuildTournamentLogIn(entry.gta_Struct, seed)      # prompt again, keep looking
    # the first matching entry whose window is over ends the whole search. Zones that do not host a match never
    # reset its entry (only fm_GuildTournamentClear on the hosting zone does), and the hosting zone keeps it when
    # the film ends without `endofgt`. A guild that played seed 2 in round 1 therefore gets no prompt at map
    # login for its round-2 match at seed 16 (original bug) Z16-B20

0x749C NC_GUILD_TOURNAMENT_RECALL_ENTER_REQ {u8 ack}                     @ FUN_004783c0
    reply 0x749D NC_GUILD_TOURNAMENT_RECALL_ENTER_ACK {u16 err} through the data stream (vt 0x2f8)
    ack == 0 (declined): err 0x1440
    p.nTournamentSeed is 0xFF or > 31: err 0x1441
    entry window closed (IsAccessTime): err 0x1444
    GetFieldGTMapInfo NULL: it sent 0x1441; assert "…RECALL_ENTER_REQ"; no further reply
    GetMapInfo NULL: it sent 0x1441 / 0x1443; no further reply
    else: err 0x1440; so_ply_Summon2GuildTournament(entry, NULL, NULL) (vt 0x924)
    # no check here that p's guild fights in the match; Summon checks it silently
    # client GuildTask FUN_006b5170: 0x1440 nothing; 0x1444 "Entry Time is Over"; any other code "Error : %d"
    # (corrects Z08 §8.1: a decline is answered with 0x1440, not 0x1441; a missing map table entry sends 0x1441
    #  itself instead of "log only")

ShinePlayer::so_ply_Summon2GuildTournament(start, gtms, mapinfo)  (vt 0x924)   @ FUN_00478750
    # gtms / mapinfo are unused (always NULL)
    p.so_IsEmpty() (vt 0x300): return
    p.mode ∈ {0, 3, 5, 7} (not in game, dead, …): return               # after 0x749D 0x1440: nothing happens
    p.guild ∉ {start.nNo1, start.nNo2}: return
    mode 4 (sitting): stand up (vt 0x488)
    GetLinkData(guildtournamentinfo[start.nTournamentSeed], &link, p): so_LinkTo(link, 6, 9, 10) (vt 0x600)
        # same zone 0x1809 / other zone 0x180A (Z01 §7.1); the map login then registers the fighter (§4.4)
```

### 6.4 Observers

```pseudo
0x74D7 NC_GUILD_TOURNAMENT_OBSERVER_ENTER_REQ {u8 nTournamentSeed}       @ FUN_00476c50
    → WM 0x74D9 NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_REQ {u8 seed, u16 nPlayerHnd = p.handle}   # no zone check
    # WM (W03 §8.3): seed > 29 → 0x1B61; seed rounded down to even; pair fighting → 0x1B60; else 0x1B62

0x74DA NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_ACK {u16 err, u8 nTournamentSeed, u16 nPlayerHnd}   @ FUN_00478be0
    q = ShinePlayer at nPlayerHnd (RTTI check); none: return
    err 0x1B60: sp_Guild_Tournamnet_Observer_Enter(q, seed)
    err 0x1B61: q ← 0x74D8 {0x1B61};  err 0x1B62: q ← 0x74D8 {0x1B54 "Relevant Guild Tournament is not in Progress"}
        (_ErrorSendPlayer<…OBSERVER_ENTER_ACK> FUN_004781a0: 11-byte payload, only err written: stale seed /
        nGuildRed / nGuildBlue bytes (original bug) Z16-B22; the client reads them only for 0x1B40)
    other codes: nothing

ShinePlayer::sp_Guild_Tournamnet_Observer_Enter(p, seed)                @ FUN_004788c0   (also GM `&observerlinkto`, Z11 §6.3)
    seed 0xFF or > 31: p ← 0x74D8 {0x1B42 "It is not the Guild Tournament Map"}; return
        # 11-byte payload, only err written: 9 stale g_buf bytes (original bug) Z16-B22
    p.mode ∈ {0, 3, 5, 7}: return (silent)
    p.so_AbnormalState_Set_Simple(0x121 StaObserverHideMode, 1, 0) (vt 0x644) fails: return (silent)
    mode 4: stand up
    GetLinkData(guildtournamentinfo[seed]) fails: return            # (the observer abstate stays set)
    p ← 0x74D8 NC_GUILD_TOURNAMENT_OBSERVER_ENTER_ACK {u16 err 0x1B40, u8 nTournamentSeed, u32 nGuildRed = nNo1,
        u32 nGuildBlue = nNo2}                                        # 11 bytes, data stream
    machine = fo_GetMechineNumber(server group, fieldserial[link.linktoserver], own zone); −1: assert, return
        # by then the client already has 0x1B40 (quit button shown) and StaObserverHideMode stays set with no link
        # (failure order, see N.)
    instance on this zone: so_LinkTo(link, 6, 9, 10); sp_SetRollBackPosEvent(new RollBackPosCallBackEvent(p) (0x68))
        # the roll-back event brings the observer back to where they stood (sp_RunRollBackPosEvent)
    other zone: → WM 0x4019 NC_CHARSAVE_2WLDMAN_LINK_FROM_CMD {u16 wldmanhandle (vt 0x340), u32 chrregnum,
        Name3 map = current map, u32 x, u32 y} (0x1a); so_LinkTo(link, 6, 9, 10)
    # an observer links to regen slot 0 (guild A's spawn point, §6.1); the map login sets layer {0, 2} (§4.4)
    # client GuildTask FUN_006b35b0: 0x1B40 → stores seed, red / blue guild numbers, shows the "quit" button
    # (MiniMapWin::ShowGTQuit); any other code → ErrMsgTable text

0x74DB NC_GUILD_TOURNAMENT_OBSERVER_OUT_REQ {u8 nTournamentSeed}  @ FUN_00476cc0
ShinePlayer::sp_Guild_Tournamnet_Observer_Out(p, 0)                     @ FUN_00475ba0   (GM `&observerout`, Z11 §6.3)
    (both bodies are the same; the seed is not read)
    sp_RunRollBackPosEvent(p) ran (same-zone observer): done
    else if p is on a tournament map (fm_IsGuildTournametnMap): sp_2Roumen(p)
    # no 0x74DC NC_GUILD_TOURNAMENT_OBSERVER_OUT_ACK is ever sent by the 2016 zone (client FUN_006b3840 exists)
# When the match ends the film moves everyone with StaObserverHideMode out: AxialListLinkToByObserver
# (ali_Work FUN_00428530, Z09 §25.4): stand up; players: roll-back event, else so_LinkToReserv(link)
```

### 6.5 Flag capture cast (0x74CA)

```pseudo
0x74CA NC_GUILD_TOURNAMENT_FLAGCAPTURE_REQ {u16 hTargetFlag}  @ FUN_00475b80 → so_ply_FlagCaptureCast (vt 0x930)
ShinePlayer::so_ply_FlagCaptureCast(p, hFlag)                            @ FUN_00477d90
    errors → sp_NC_GUILD_TOURNAMENT_FLAGCAPTURE_ACK(err) FUN_00475cd0 = p ← 0x74CB {u16 err} (game stream vt 0x2fc)
        # client GuildTask FUN_006b3670: 0x1B40 → nothing; any other code → its ErrMsgTable text (FUN_00416430) in
        # the system message channel (0x19); texts in Z08 §8.1
    no map or no tournament system on it: 0x1B42
    IsFlagCapture(p, hFlag) (§4.5; the flag already belongs to p's guild): 0x1B48
    not IsPlayerRegister(p): 0x1B4F
    no object at hFlag: return (silent)
    so_DistanceSquar(flag, p) > 10000 (100 units): 0x1B52
    mode 6 (riding): sp_MoverSystem_Type == MVST_MOVER ? sp_MoverSystem_GetOff(p, 0) : sp_HorseOff(p); continue
    mode ∈ {3, 4, 5} or abstate 0x123 StaImmortal (login protection): 0x1B45 "You are unable to capture the flag"
    so_parameter().IsNoAttacOrNoMove() or p+0x1e78 bit 2 or smo_IsCaptivate (vt 0xf20): 0x1B45
    p.sp_hGuildTorunamentFlagHandle (p+0x5e06) ≠ 0xFFFF: 0x1B46 "You are capturing the flag"
    casting something (smo_DuringCast vt 0xea0): so_ply_AllCastCancel (vt 0x8d0)
    remove abstates 0x4B StaHide and 0x175 StaGTIHide (vt 0x650) when set   # capturing reveals the player
    p ← 0x74CB {0x1B40}; sp_NC_GUILD_TOURNAMENT_FLAGCAPTURE_CMD(0x1B40)
    ts_Set(p.sp_TimerStr (p+0x2a784), so_ply_FlagCapture, TSCW_MISC, 4000)
    p.sp_hGuildTorunamentFlagHandle = hFlag
    p ← 0x2047 NC_ACT_CREATECASTBAR {u16 4000} (game stream)

sp_NC_GUILD_TOURNAMENT_FLAGCAPTURE_CMD(p, err)                          @ FUN_00475d40
    0x74CC NC_GUILD_TOURNAMENT_FLAGCAPTURE_CMD {u16 err, u16 hPlayer = p.handle} to everyone in range of p
    (so_AllOfRange with AxialListPacketBroadcast) and to p
    # client GuildTask FUN_006b3780: 0x1B40 → Char::ActFlagCapture(hPlayer) (capture animation);
    # 0x1B51 → Char::StopFlagCapture(hPlayer); other codes → ErrMsgTable text

ShinePlayer::so_ply_FlagCapture(p) → TSRT_RETURN   (timer callback after 4 s)   @ FUN_00477c00
    system = p's map system; none: return (the flag handle stays set)
    SetErrorDelegate(p.sp_NC_GUILD_TOURNAMENT_FLAGCAPTURE_ACK)        # CaptureFlag errors reach p as 0x74CB
    CaptureFlag(p, p.sp_hGuildTorunamentFlagHandle) (§4.5) true: p ← 0x74CB {0x1B40}
    ClearErrorDelegate; p.sp_hGuildTorunamentFlagHandle = 0xFFFF

ShinePlayer::sp_FlagCaptureFree(p)                                       @ FUN_00476cf0
    cast running (handle ≠ 0xFFFF): handle = 0xFFFF; stop the cast timer (ts_Limit 0, TSCW_NONE, no-op functions);
    p ← so_SendProtocol(8, 0x48) = 0x2048 NC_ACT_CANCELCASTBAR; sp_NC_GUILD_TOURNAMENT_FLAGCAPTURE_CMD(0x1B51)
    # callers: so_ply_AllCastCancel FUN_0055a310 (any cast cancel: hit, move, …, Z03) and
    # sp_FlagCaptureFreeCheck(p, hFlag) FUN_00476d50 (only if p casts on hFlag), which AxialListFlagCaptureCancel
    # (ali_Work FUN_004794b0) runs for every player in the map when CaptureFlag changes the owner (§4.5)
```

### 6.6 Match end and result to the WM

```pseudo
film step `endofgt w l` (ShineEndOfGuildTournament, Z09 §24.8): fm_ClearObject(0xb0);
    FieldMap::fm_GuildTournamentEnd(field, w, l) FUN_00475fa0 → WM 0x7482 NC_GUILD_TOURNAMENT_END_CMD
        {u8 seed, u16 nTournamentMapNo (always 0, §6.1), u8 nStatus = (w == l), u32 nWinnerGuildNo = w,
         u32 nLoseGuildNo = l}; gta_Result2WMS = 1      (field seed / entry not set: assert, nothing sent)
    FieldMap::fm_GuildTournamentClear(field) FUN_00475a30: entry seed 0xFF, start time 0, field seed 0xFF,
        system.Clear() (§4.3)
    # the score, winner and loser come from the script (`@GetWinnerGuild` / `gtresult`, Z09 §22.2 / §24.8; §4.7)
    # the WM side (bracket advance, 0x7490 results, rewards) is W03 §8.5

WorldManagerSession::wms_GuildTournamentCheck()     (once a minute, Z09 §1.2)   @ FUN_004776a0
    for seed in 0…31: entry.nTournamentSeed ≠ 0xFF and gta_Result2WMS == 0 and the instance is on this zone
        and its cinema runs no film (fm_Multiflex +0x14 l_ListNum == 0, assembly 0x4777a4):
            fm_GuildTournamentEnd(field, 0, 0)      # 0x7482 {seed, 0, nStatus 1, 0, 0}: "no result" (draw)
    # it does not call fm_GuildTournamentClear: the entry and the field seed stay set until the next start on
    # this instance (which then logs "seed not empty. May be RE-Match.") (part of Z16-B20)
```

### 6.7 Entry application (WM → zone → DB)

```pseudo
0x74E3 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_REQ {u16 hWMChar, u32 nCharNo, u32 nGTNo, u32 nGuildNo, u8 nMinLevel,
        u16 nMinMember, u64 nProposalMoney}  (0x19, WM → every zone, W03 §8.2)      @ FUN_004766f0
    nCharNo == −1 or the character is not on this zone or so_IsEmpty: nothing (another zone answers)
    e = q.so_ply_GuildTournamentJoinNew(body) (vt 0x934)
    e ≠ 0x1C40: → WM 0x74E4 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_ACK {u16 Error = e, the 0x19-byte body} (0x1b)

ShinePlayer::so_ply_GuildTournamentJoinNew(p, body) → u16                @ FUN_00476860
    p.guild == 0: 0x1C42
    money (vt 0x434) + the pending money change of p's lock list (icl_ReservedQuantity) < nProposalMoney: 0x1C44
    → DB 0x74E5 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_REQ {ref {u16 p.handle, u32 charNo}, u16 lockindex = the lock
        list's current index, u16 hWMChar, u32 nCharNo, u32 nGTNo, u32 nGuildNo, u8 nMinLevel, u16 nMinMember,
        u64 nProposalMoney} (0x21)
    lock list: icl_StoreMoney(lockindex, nProposalMoney, −1) (a pending −nProposalMoney change); icl_IncIndex
    0x1C40 (asked the DB; the WM gets its answer from 0x74E6)
    # the zone checks only the guild and the money; nMinLevel / nMinMember are passed on unchecked
    # (W03 §8.2's "checks level / members / money" is more than the 2016 zone does)

0x74E6 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_ACK {ref, u16 lockindex, u16 Error, hWMChar, nCharNo, nGTNo, nGuildNo,
        nMinLevel, nMinMember, nProposalMoney}                                      @ FUN_00476a10
    → WM 0x74E4 {Error, hWMChar, nCharNo, nGTNo, nGuildNo, (3 bytes not written: Z08-B13), nProposalMoney}
    q = object at ref.handle, not empty, charNo == ref.charNo:
        Error 0x1C40: lock list icl_Apply_N_Free(q, lockindex, 0) (money taken); failure → LockIndexLog
        else: icl_Free(lockindex) (money kept)
0x74F4 NC_GUILD_TOURNAMENT_GOLD_REFUND_ZONE_CMD @ FUN_00476c00: empty (profiler only); no refund on the zone
    (D06 / Z08 record the same)
```

### 6.8 0x74AC / 0x74B4 check order (Z08 open point, assembly)

`sp_NC_GUILD_RENAME_REQ` FUN_00473550 (0x4735e2…0x47362a) and `sp_NC_GUILD_RETYPE_REQ` FUN_00473860 (0x47390c…0x47393a):

```pseudo
mode ∉ mask 0x56 {1, 2, 4, 6}                         → 0x1A41 (retype 0x1A59)      # no client text
no map, or the map's FieldAttr byCanItem (+0x9e) == 0 → 0x1A42 (0x1A5A) "Request cannot be processed at a current location"
NPC menu / storage open (p+0x18248 & 0x0C)            → 0x1A41 (0x1A59)             # jumps back to the mode error
```

So Z08 §8.1's line "an NPC menu or storage open: 0x1A42" is wrong. The open menu shares the mode code 0x1A41 / 0x1A59,
and only the map test gives the "location" code.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z16-B1 | `ShineMob::so_KilledBy` FUN_00432760 (KQ branch) | a killer whose zone party record has < 2 or > 5 members, or a party number ≥ 4000, asserts and returns from the whole kill handler | on a KQ map such a kill gives no experience, no drop, no quest progress | assert and continue with the rest of the kill |
| Z16-B2 | 0x580D @ FUN_00497790 | the success flag is overwritten per map slot; the 0x580E reply is sent only when the last listed map is local | a KQ whose last map is on another zone is built but never acknowledged (refines Z08-B8) | track "all maps found" separately from "reply now" |
| Z16-B3 | 0x580D @ FUN_00497790 | maps claimed in earlier loop passes keep `fm_KQHandle` / `fm_KQID` when a later check or the container allocation fails | the instance is unusable for every later KQ ("Not empty2") until restart | reset the claimed maps on every error exit |
| Z16-B4 | 0x581A @ FUN_00496990 | links to map 0 for any known handle without checking the player is a joiner (and masks only the low 16 bits) | a non-joiner can be linked into the KQ map; it bounces to Roumen at map login unless GM | check `kqpil_IsKQJoiner` before the link |
| Z16-B5 | `sp_GetJoinKQTeamType` FUN_00563990 | compares the 32-bit `fm_KQHandle` with 0xFFFF | on a KQ map without a KQ, every map login logs "Cannot found KQ Element" | compare with 0xFFFFFFFF |
| Z16-B6 | Lua `cGetKQLimitSecond` FUN_005e5390 | tests the u16 `LimitTime` against 0xFFFFFFFF | dead check: the nil branch can never be taken, every KQ returns `LimitTime · 60`; 2016 `KingdomQuest.shn` row 3 "Gold Hill Adventure" has `LimitTime` 65535, so its script gets 3,932,100 s instead of nil (no limit) | compare with the u16 "no limit" value 0xFFFF (the value the 2016 table uses for that row) |
| Z16-B7 | `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 / `sp_ReviveReqProcess` FUN_00451bd0 | the `bs_ClearAtLink` reset runs only off KQ maps, where `so_GetBattleStat` returns the shared `so_DefBattleStat` | a player's KQ statistics are never reset by it; only the shared default object (written by every non-KQ fight) is cleared | keep the statistics per player and reset them at the link out of the KQ |
| Z16-B8 | `AxialListKQReward::ali_Work` FUN_00428490 (`reward` / `cReward`) | rewards every player on the map whose kill count reaches `DemandMobKill`, without a joiner or admin-level check (the result list skips GMs) | with `DemandMobKill` 0 GMs and non-joiners on the map get the KQ reward chest, cen, fame and EXP | reward joiners only (`kqpil_IsKQJoiner`), skip GMs |
| Z16-B9 | `GuildTournamentSystem::Update` FUN_0047e0e0 | the win-score lookup tests whether the GTIGetRateGap table has rows, then reads row 0 of GTWinScore | an empty or missing GTIGetRateGap falls back to 2000 points although GTWinScore says 4000; an empty GTWinScore with a non-empty GTIGetRateGap reads a missing row | test the GTWinScore table it reads |
| Z16-B10 | `GuildTournamentSystem::PlayerUnRegister` FUN_0047fd50 | 0x74C9 FIGHTER_OUT carries `(u8)m_nTournamentType` in its `nTournamentSeed` field (0x74C8 carries the seed) | wrong seed on the wire; harmless only because the 2016 WM ignores the field (W03 §8.3) | send `m_nTournamentSeed` |
| Z16-B11 | `GuildTournamentScoreTable::GetScore` FUN_005c7080 | a victim grade > 6 asserts but still reads `GradeScore[grade]` past the 7-entry row | the kill score comes from the next row's MAP_TYPE / scores | return 0 (or clamp) after the assert |
| Z16-B12 | `GuildTournamentSystem::ChangeAdvanRule` FUN_0047a2d0 | returns without touching either group when the scores are equal | after a tie the guild that trailed before keeps its comeback advantage although nobody trails | clear both advantages when the gap is 0 |
| Z16-B13 | `GTIGetRateTable::GetItemIDbyProbabilityCalculate` FUN_005c7250 | draws `r = rand() % sum` and returns the first row with `r − cumulative ≤ 0` (`< 1`) | a row with weight 0 can be drawn (r on its boundary, e.g. GTI_Bless in Win3 for r = 0) and every row's chance is shifted by one in `sum` | return the first row with `r < cumulative` |
| Z16-B14 | `GuildGroup::SendPlayerAllScoreInfo` FUN_0047f260 | after more than 200 rows it sends the list but never empties the row vector | each further member re-sends the whole growing list; lists over the packet limit fail with "Packet Too Long" (dead with real guild sizes) | clear the vector after each 200-row chunk |
| Z16-B15 | `GuildTournamentSystem::GuildBuffUse` FUN_0047b9a0 (0x74CF) | a requester whose guild is in neither group gets the 0x1B4F error twice (the else branch falls through to the final sink call) | two 0x74D0 error acks, the message shows twice | one sink call |
| Z16-B16 | `GuildTournamentSystem::DiceGameWinGuild` FUN_0047ba80 | adds the 100 dice points without sending 0x74DD | the score boards show the old score until the next flag tick or kill (up to 60 s) | broadcast 0x74DD as the flag tick does |
| Z16-B17 | 0x7481 @ FUN_00477a10 (settles Z08-B12) | accepts `seed ≤ 32`; `guildtournamentinfo` and `GTMap` have 32 entries, and `guildtournamentinfo[32]` overlaps `GTMap[0…2]` | seed 32 writes 0xFF and then the match record into the map table, reads `GTMap[32]` past the array; seeds 0–2 can no longer start and their instances are no longer tournament maps (latent: the 2016 WM sends seeds ≤ 29) | `seed < 32` as every other reader |
| Z16-B18 | `so_ply_Send2GuildTournamentLogIn` FUN_00475950 | 0x749B is sent with a 1-byte payload that is never written | one stale g_buf byte on the wire (the client ignores it) | send the empty struct without the pad byte, or zero it |
| Z16-B19 | `IsAccessTime` FUN_004757f0 / `sp_IsGuildTournamentAccessTime` FUN_00475830 / `so_ply_GuildTournament_isSummon` FUN_00475890 | entry window = `nExploerTimeMin · 4800 / 10` ticks = 480 ticks per minute with ticks of 0.1 s | players can answer the recall only for 80 % of the configured entry time; afterwards 0x749C gets 0x1444 "Entry Time is Over" | `nExploerTimeMin · 600` ticks |
| Z16-B20 | `so_ply_GuildTournament_isSummon` FUN_00475890 (+ `wms_GuildTournamentCheck` FUN_004776a0) | the seed loop returns at the first entry of the player's guild whose window is over; entries are only reset by `fm_GuildTournamentClear` on the hosting zone (the check fallback and non-hosting zones keep them) | a guild's earlier-round entry (lower seed) hides its next match: no 0x749B prompt at map login and `nTournamentSeed` stays 0xFF, so 0x749C fails with 0x1441; repeated "Seed not empty" asserts at the next start | skip (`continue`) entries whose window is over; reset the entry on every zone at the end (0x7482 / a WM broadcast) |
| Z16-B21 | `ShineMover::so_mobile_IsEnemy` FUN_004309a0 | tests `fm_MapInfo != null → not an enemy` (inverted against the mover's `so_mobile_ICanDamageTo`) before the KQ, party-battle, guild-war and tournament tests; the code after it would read `KingdomMap` through the null pointer (address 0x3a) | on every map (all have a MapInfo row) a mover's enemy test fails for player and mover targets except on PK fields or when captivated: the `fm_GuildTournamentEnemy` branch is dead | `fm_MapInfo == null → false`, as in `so_mobile_ICanDamageTo` |
| Z16-B22 | `sp_Guild_Tournamnet_Observer_Enter` FUN_004788c0 (seed check) / `_ErrorSendPlayer<…OBSERVER_ENTER_ACK>` FUN_004781a0 | the 0x74D8 error answers (0x1B42, 0x1B61, 0x1B54) are sent with the full 11-byte payload but only `err` written | 9 stale g_buf bytes on the wire (the client reads them only for 0x1B40) | write the error with a zeroed body |

## N. Not reconstructed / uncertain

- Parts 1–6 written (KQ §1–§3, GT core §4, groups / skills / items / dice §5, match lifecycle §6, sweep), reviewed
  with fresh context in part 7 (findings and fixes in `docs/plan/status/Z16.md`).
- `PROTO_KQ_MAP_INFO::PROTO_KQ_MAP_INFO` FUN_004194d0 is the trivial constructor of the 0x1a-byte map slot (§1.2).
- §2.2 / §6.1 `GetLinkData`: `LinkInformTemplete.index[20]`, `direct` and `Party` are left as stack bytes. `so_LinkTo`
  FUN_0049ad30 itself reads only the names and coordinates; its link-reserve path (vt 0x3fc `so_LinkToReserv`) copies
  the whole struct into the reserve queue, and whether a later reader uses the three fields was not traced (Z01 §7.1).
- §6.4: if `GetLinkData` fails after `StaObserverHideMode` was set, nothing removes the abstate; not reachable with the
  2016 Field.txt (row 0 exists), so not counted as a bug.
- §6.2: the token `nNo1 nNo2 nExploerTimeMin nPlayTimeMin` is what `Guild/GuildTournament` receives; how the script
  uses each value is Z09's (§24.7); `nWaitPlayTimeSec` reaches no zone code.
- §5.5 GTIT_MOBBREED: the argument of `so_mob_Regenerate` taken from the target's vt 0x6d0 (a folded 0-returning stub on
  mobs / NPCs, `so_GetCharBriefInfo` on players) and what `so_mob_RegenLocation` returns for a player target were not
  traced; with the 2016 data only team NPCs (TARGET_MYNPC) breed.
- §5.6: `rb_1000() % 6` is slightly biased towards 1…4 if `rb_1000` returns 0…999 (Z01 RandomBox, not checked).
- §4.4: a fighter stays in `m_vecGuildMembers` only after a same-zone 0x4F revive link (REMOVE_REVIVE). Whether the
  death menu can send a registered fighter to another map that way (instead of the team revive point) was not traced
  (Z07 §3.1); if it can, the entry keeps the old handle until `Clear`.
- §4.7 `ShineMover::so_mobile_IsEnemy`: slot 0xc70 is `so_MoverSystem_NoDamage` *(pdb2016)* (player: rides a mover with
  an ability; mover: has mover data but no ability), not "GM-invincible" as Z03 §3.3 / Z09 §8.4 label it. The mover
  version treats `== 0` as "not an enemy", the player version `== 1`; whether that mover-against-mover rule is intended
  was not settled, so it is not counted as a bug (Z16-B21 is the inverted MapInfo test after it).
- 0x580C NC_KQ_START_CMD (empty struct *(pdb2017)*): neither the 2016 zone nor the WM sends it; the client accepts and
  ignores it (`re-data/client-handlers.json`). The KQ start is 0x580F (WM → zone) and the gate keeper (§2.2–§2.3).
- §4.6: the radius of the 0x74DE / 0x74DF broadcasts (`allofrangearg`) was not resolved (read as the whole map); both
  are centred on the killer's location.
- §6.4: `sp_Guild_Tournamnet_Observer_Enter` sends 0x74D8 {0x1B40} and keeps StaObserverHideMode before
  `fo_GetMechineNumber` is checked; on −1 the client shows the quit button but no link follows. The GM path
  `&observerlinkto` (Z11 §6.3) skips the WM's "pair fighting" check, so for a seed without a match `GetLinkData`
  uses the entry's empty `gta_Field` and whatever `nTournamentMapNo` it holds; what `fieldserial[""]` /
  `fo_GetMechineNumber` then return was not traced (GM-only, not counted as a bug).
- `bs_SkillBlast`: the `so_Routine` branch that counts it tests `scs_ProduceSkill.sklidx`; whether that is every
  skill blast or only the production-skill step was not traced (Z03).
- 0x5817 after `sp_KQReward`: what the client shows for a reward-box chest whose DB rows were never created
  (the contents are already in `ItemsInChest`) was not traced.
- How the client produces `EncHandle` for 0x581A (Z08 open point) is still open.
- 0x5818 `number = 0` for unlimited revives: whether the client shows 0 or hides the counter was not traced in
  `KQuestTimeWin::SetRestLife`.

## N+1. Coverage boundary

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| KQ client ↔ WM packets 0x5801–0x580B, 0x581B–0x5839 (list, status, join, schedule, votes, team select, joining alarms), `KQIsVote.shn`, `KQVoteMajorityRate.shn`, `KingdomQuestMap.shn`, the WM `CKQ` object and 0x580D / 0x580F / 0x5810 senders | W04 §6 (done; documents them) | WM-side KQ; the zone only receives 0x580D / 0x580F and sends 0x580E / 0x5810 / 0x5822 (§2) |
| GT client ↔ WM and WM ↔ DB packets 0x747A–0x7480, 0x7485–0x749A, 0x74AA / 0x74AB, 0x74C3 / 0x74C4, 0x74E7–0x74EE, 0x74F6–0x74F9, `GuildTournamentRequire.shn`, `GuildTournamentReward.shn`, the WM side of 0x7481 / 0x7482 / 0x74C8 / 0x74C9 / 0x74E3–0x74E6 / 0x4019 | W03 §8 (done; documents them), D04 §6.4, D06 | WM scheduling, entry, rewards and DB rows; §6 documents the zone side and links W03 §8 where the two meet |
| KQ reward DB packet (dept 22 to the Character DB) behind 0x5815 | D04 §3 (done) | DB side of `sp_KQReward`; Z16 §3.4 links it, Z11 §8.4 documents `sp_KQReward` |
| Pine KQ / GT nodes and `@` functions (`AxialListKQResult` FUN_004e5390 / 004e5790 / 004e5d20 …, `SysFuncShineKQTop` / `KQResultList`, `ShineSendKQResult`, `ShineEndOfKingdomQuest`, `ShineEndOfGuildTournament`, `ShineDiceGameStart`, `GTMobRegenKey`, `linkto` by observer) | Z09 §22.3, §24.7, §24.8, §25.4, §25.6, §25.7, §26.1 (done) | map-script statements that only call the objects documented here (plan: "Map scripts … belong to Z09") |
| KQ / GT packets sent only from Pine nodes: 0x5836 / 0x583C / 0x583D, 0x7484, 0x74E0, 0x74E2, 0x748D | Z09 §28.12, §23.6, §19.5, §24.8, §25.2 (done) | their senders are script nodes; layouts: 0x7484 / 0x74E0 / 0x74E2 / 0x748D in Z09's annotations, 0x5836 / 0x583C / 0x583D in Z16's (from the Lua senders of Z09 §28.12 + pdb2016) |
| KQ dialog scripts `KQ*.txt` (`KQScriptManager::kqsm_Load` FUN_0064cee0) and `MobRegen/KingdomQuest/*.txt` (`KQRegenTable` FUN_004b3220 / 004b26b0) | Z09 §22.6, §10.6 (done) | script data, loaded at start-up; the KQ element only names the script |
| GM commands `&kingdomquest`, `&EndOfKingdomQuest`, `&Reroadkingdomquest`, `&kqreward`, `&GuildTournament`, `&StartGuildTournament`, `&FlagCapture`, `&GuildTournamentItemEffect`, `&ObserverLinkTo`, `&ObserverOut` | Z11 §5.5, §6.3, §7.2, §8.4 (done) | GM command parsing; §3.6 / §6 link the objects they call |
| `GTIView.shn` (`gSHNView_GTIView`, initializer FUN_00699990) | Z01 start table (done: "checksum only"), Z10 SHN check | the zone reads it only for the client checksum list (`CShnDataFileCheckSum` entry 0x26); the item names come from the client's copy (§5.5) |
| Raid / drop dice (`sd_DiceGameResult` FUN_00531470, `Raid::SetItemDiceGameMode`), `DiceDividind.shn`, `DiceRate.shn` | Z09 §11.6, Z06 §3–§4 (done) | loot and gambling dice, unrelated to the GT `DiceGame` (§5.6) |
| `Observer` / `IObserver` / `LuaScriptObserver` / `MapRearrangeObserver`, `ShinePlayer::notifyObservers` | Z09 §14.7, §14.8 (done) | the observer *pattern* classes; the GT spectators (§6.4) do not use them |
| generic callees of the documented hooks: party and raid quest checks (`pm_QuestCheck`, `rt_QuestCheck`), abstate helpers, map-login resets in `sp_NC_MAP_LOGINCOMPLETE_CMD`, `fm_GetRegenCityLinkData`, cluster loaders | Z01, Z03, Z07, Z09 (done) | reached from the kill, map-login, save-location and start-up functions only outside their KQ / GT branches |
| mover combat beyond the GT test (`ShineMover::so_mobile_ICanDamageTo` FUN_004368c0, the meaning of slot 0xc70) | Z09 §8.4 (done; documents ICanDamageTo); §4.7 here documents `so_mobile_IsEnemy` FUN_004309a0 | small gap closed here because its only GT link (`fm_GuildTournamentEnemy`) is dead code (Z16-B21) |
| `TickTimer::GetRestDelayTimeToSecond` FUN_00592000 / `CheckUpdateEvent_ClockWatch` FUN_00592050 | Z17 (open; plan: "the player's item-action cooldown container") | part 4 listed them as GT helpers; their only callers are `ItemActionObserveManager` (item cool-downs), no GT code |
| name-only matches of the sweep: `ShineMobileObject::smo_GetFlagDamageAbsorb` FUN_005558c0, `so_EncSeedSet` FUN_0054f660 / 004d8e30 | Z09 §16.6 (the `smo_Flag` damage-absorb bit of `DamageAbsorbAction`), Z01 §5.1 (the cipher seed) (done) | "Flag" / "Seed" in their names are not the GT flag or tournament seed |
| client handlers of the KQ / GT packets | C01 (done; `re-data/client-handlers.json`) | read per packet in §2–§6; client-side UI beyond the field meaning is not server behaviour |

No follow-up item was needed: everything found is either documented here or in a finished item's output (cited above), except the TickTimer helpers, which the open Z17 covers.
