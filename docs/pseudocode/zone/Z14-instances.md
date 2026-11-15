# Zone: instance dungeons, zone-ring storage handlers, raid internals (Z14)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`. Read with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr…>` (official names from the NA2016 `Zone.pdb`,
same build; all class, member, struct and enum names below are *(pdb2016)* unless marked otherwise). Packet layouts:
`docs/protocol/annotations/Z14.json`. Evidence markers as in `AGENTS.md`; nothing here is *(captured)*.
This item extends Z08 (`Z08-content.md` §2, §5, §8, §10), which documented the senders and the WM-side flows.

Ticks: `clockwatch.cw_CurrTick` counts tenths of a second (Z09). `g_buf` = the global packet buffer `gpp`
(`PTR_DAT_0084d908`, opcode at +0). `p.vt 0xNNN` = `ShinePlayer` vtable slot (byte offset), names from `rtti.py` + PDB.

## 1. Instance dungeons: data and the cluster manager

### 1.1 Data tables

**`InstanceDungeon` table of `Field.txt`** (`../9Data/Shine/World/<world>/Field.txt`, else `../9Data/Shine/World/Field.txt`;
config-script reader, loaded by `FieldContainer::fc_Load` @ FUN_004655f0 into `fieldlist.fc_InstanceDungeon`
{`NumberOf`, `Attribute[]` indexed by IDNo}). Row struct `FieldOption::InstanceDungeonInfo` (0x6f bytes), columns in file
order:

| Off | Column (file) / member (PDB) | Type | Meaning |
|---|---|---|---|
| 0x00 | Argument | ORToken (INDEX, 20 B) | gate key: the NPC role argument / `LinkTable` key (e.g. `UrgFire017`, `IDGate011`) |
| 0x14 | IDNo | u8 | row index; must be < row count and unique ("Too large IDNo", "duplicate IDNo" → ShineExit) |
| 0x15 | ZoneNumber | u8 | zone that hosts the instances |
| 0x16 | MapIDClient | char[13] | instance map base name (`UrgDragon`, `Tower01`, …) |
| 0x23 | ScriptName | char[32] | instance script (film), e.g. `ID/GraveYard/GraveYard` |
| 0x43 | ModeIDLv | u8 | level type `ID_LEVEL_TYPE` (0 EASY, 1 NORMAL, 2 HARD); data uses 1 and 2 |
| 0x44 | EntranceType | u8 | group required (Z08 §5.1: 2 party, 3 raid, 4 party or raid) |
| 0x45 | Guild / 0x46 Individual | u8 | unused by the code read here (all 0 in the data) |
| 0x47 | NeedQuest | u16 | quest that must be done (`fc_CanEnterIndun`) |
| 0x49 | NeedItem | char[32] | item inx name or `-` |
| 0x69 | Consume | u8 | items consumed on entry (0 = only required) |
| 0x6a | LimitTime | u8 | time limit in minutes (0 = none); all 0 in the 2016 data |
| 0x6b | MaxUseChr / `MaxUseCount` | u8 | player limit per instance |
| 0x6c | CheckSum | u8 | must equal IDNo ("Checksum error in table InstanceDungeonInfo(Field.txt)") |
| 0x6d | Spacer / `NeedItemID` | u16 | filled by the loader: `idb_2itemid(NeedItem)`, 0xFFFF for `-`; unknown item → "Wrong Item ID", ShineExit |

For every row whose ZoneNumber is this zone, the loader calls `AddInstanceDungeonCluster(MapIDClient, IDNo)` (§1.3).
The 2016 file has 17 rows (IDNo 0–16; zones 0–3; `SD_Vale01` needs `ID_SD_Vale01_Ticket` and consumes 1; `WarH`/`SD_Vale01`
allow 20 players, the rest 5 or 9).

Lookups (all linear over `Attribute[]`):

```pseudo
fc_GetInstanceDungeonInfo(key, level)          @ FUN_00484470: row with Argument == key and ModeIDLv == level, else NULL
fc_GetFirstInstanceDungeonInfo(key)            @ FUN_00484380: first row with Argument == key;
                                                   no match → the LAST row pointer (loop variable), not NULL   (original bug) Z14-B1
fc_GetFirstInstanceDungeonInfo(Name3 map)      @ FUN_004843e0: first row with MapIDClient == map; same last-row fallback (Z14-B1)
fc_GetInstanceDungeonInfoByMapName(map, level) @ FUN_004844e0: MapIDClient == map and ModeIDLv == level, else NULL
fc_GetInstanceDungeonInfoCount / fc_GetInstanceDungeonInfo(i)  @ FUN_00462840 / FUN_00462850 (rank list, Z08 §5.3)
```

`fc_IndunMapRegist(wm)` @ FUN_00462af0 (at WM connect): 0xA419 NC_INSTANCE_DUNGEON_MAP_REGIST_CMD
`{u16 nMapCount, SHINE_INDUN_INFO[n] {Name3 MapIDClient (12 B, strncpy 0xc, no NUL) @0, u8 ModeIDLv @0xc}}` (4 + 0xD·n; the opcode is written as a
u32 `0x0000A419`, so `nMapCount` starts at 0) — one entry per row of **all** zones (W04 handles it).

**Map type.** `FieldOption::FieldAttr` (FieldList row) +0x36 is the column `KingdomQuestMap`, typed by enum
`FIELD_MAP_TYPE`: 0 NORMAL, 1 KINGDOMQUEST, 2 MINIHOUSE, **3 INSTANCEDUNGEON**, 4 TUTORIAL. The 2016 `Field.txt` marks
exactly the 13 instance maps with 3 (`UrgDragon`, `Tower01`–`03`, `Leviathan`, `AdlF`, `AdlFH`, `WarN`, `WarBL`, `WarH`,
`WarL`, `Siren`, `SD_Vale01`) and `RouT` with 4. This settles Z08's *(inferred)* "map data type 3 = instance".
The job-change dungeons (`Job1_Dn01`, `Job2_Dn01`, `Job2_Dn02`) are type 1.

**Instances are sub-maps.** A FieldList row with `subfrom`/`subto` ≠ `-` makes one `FieldMap` per suffix
(`MapSubString` from..to, e.g. `UrgDragon` 00–09 → `UrgDragon00` … `UrgDragon09`; `fc_MakeField`). Every such map whose
`fm_MapID` differs from its row name registers itself in the cluster of that name (`FieldMap::fm_Init` @ FUN_00464bc0 →
`mc_Regist`, §1.3).

**Field level table** (`g_IndunLevelData` DAT_0d026c30 in Z08 = global `fieldleveldatabox`, class `FieldLevelDataBox`):
`../9Data/Shine/FieldLvCondition.shn` (`fldb_Load` @ FUN_0046a350; row `FieldLvCondition`: `MapIndex` (char[33]),
`ModeIDLv` u8, `LvFrom` u16 (+0x22), `LvTo` u16 (+0x24)). `fldb_GetFieldLv(map, mode)` @ FUN_0046a370: first row with
`MapIndex == map` and (`mode == 0` or `ModeIDLv == mode`), else NULL. Used by every gate and field-entry check (Z02 /
Z08 / Z09), not only instances; e.g. `UrgDragon` 80–105, `Tower01` 20–70, `WarH` 105–120 (normal) / 105–150 (hard),
`RouN` 1–150.

**`TutorialMap` table** of `Field.txt` (`TutorialMapInfo` {MapIDClient char[13] @0, MaxChr u8 @0xd, ScriptName
char[32] @0xe}): every row gets a tutorial cluster on **every** zone (`cm_AddTutorialMapCluster`, no zone check) and,
after all maps are built, `cm_PlayAllFilm(MapIDClient, ScriptName)` starts the script on all its instances (failure →
"Fail to play tutorial script", ShineExit). `fc_Get_MaxcharInTutorialMap(map)` @ FUN_00461e20 = MaxChr.

### 1.2 Structures

```
mapclustermanager  (g_MapClusterMgr DAT_0d742b30)  : MapClusterManager::ClusterManager, 0x28098 B
    List<MapCluster> of 14 cells (l_MakeList(0xe) in the ctor @ FUN_004a0f00)
    +0x00018 cm_ClassChange          MapCluster "Job1_Dn01"   (embedded; list cell 0, cm_Init @ FUN_0049f270)
    +0x0a02c cm_ClassChangeRou       MapCluster "Rou"         (cell 1)
    +0x14040 cm_ClassChangeGamble    MapCluster "Job2_Dn01"   (cell 2)
    +0x1e054 cm_ClassChangeElfForest MapCluster "Job2_Dn02"   (cell 3)
    +0x28068 Clusters[10]            MapCluster* — only scanned, never written (§1.3, Z14-B2)
    +0x28090 cm_EmptyCheck           Metronome {150 ticks}  (15 s)

MapClusterManager::MapCluster, 0xa014 B   (heap-allocated for instance / tutorial clusters)
    +0x0000 Name3 mc_MapIndex            base map name (the search key: mc_CompName)
    +0x000c InstanceMap mc_Map[512]
    +0xa00c int mc_MapNumber             registered instances
    +0xa010 int mc_Pointer               round-robin cursor (searches start after it)

MapCluster::InstanceMap, 0x50 B   (one per instance FieldMap)
    +0x00 FieldMap* Field
    +0x04 u32  RegisterNumber            owner regnum; 0xFFFFFFFF = free
    +0x08 bool IsTimerSet                destroy countdown running (WM told 0xA401)
    +0x09 bool IsDelayTimerSet           "empty" grace delay running
    +0x0c Metronome TimeToDestroy        3000 ticks (5 min)
    +0x14 Metronome EmptytoMsgDelay      200 ticks (20 s)
    +0x1c bool bIsLimitTime;   +0x20 Metronome LimitExpirationTime
    +0x28 bool bIsFailDelayTime; +0x2c Metronome FailDelayTime   50 ticks (5 s)
    +0x34 bool bIsLimitTimeWarning; +0x38 / +0x40 Metronome LimitExpirationTimeWarningLevel_1 / _2
    +0x48 INSTANCE_DUNGEON::CATEGORY Category   −1 CLASSIC (free), 0 PARTY, 1 GUILD, 2 INDIVIDUAL, 3 RAID
    +0x4c ID_LEVEL_TYPE eIndunLevel             3 = ILT_MAX (free)
```

The owner key is `{Category, RegisterNumber}`: party → `{0, partyNo}`, raid → `{3, raidNo}`, guild → `{1, guildNo}`
(`so_GetInsDunGeonInRegNoAndType` = Z08's `ShinePlayer_GetPartyKey` FUN_005605f0, vt 0xa8c; `fc_CanEnterIndun` = Z08's
`IDCondition` FUN_004624d0). An instance is "owned" while `RegisterNumber != −1`; no other state marks it in use.

### 1.3 Registration (zone start)

```pseudo
ClusterManager ctor @ FUN_004a0f00: list of 14 cells; the 4 class-change clusters with names above; Clusters[] = NULL;
    cm_EmptyCheck = {now + 150, 150}
cm_Init() @ FUN_0049f270 (ZoneServer_zs_start_home): put the 4 embedded clusters into list cells 0..3 (else "Init error", ShineExit)

AddInstanceDungeonCluster(map, IDNo) @ FUN_00484850         (fc_Load, rows of this zone)
    if all 10 Clusters[] entries are non-NULL: return false   # never true: nothing writes Clusters[]   (original bug) Z14-B2
    take a free list cell; new MapCluster(map); store it
    no free cell → log "AddInstanceDungeonCluster : Cannot Add" (arg IDNo); ShineExit
    # no duplicate check: two rows with the same MapIDClient (UrgDragon IDNo 0/1, Leviathan 4/5, Tower03 6/7,
    # Siren 13/16) make two clusters; both receive every instance (mc_Regist below) but searches always find the
    # first, so the second is dead weight that still uses a cell                         (original bug) Z14-B3
cm_AddTutorialMapCluster(map) @ FUN_004a0860                (fc_Load, every TutorialMap row, every zone)
    a cluster with that name exists → "Exist MapName - " + ShineExit; same Clusters[] dead check; free cell or
    "Cannot Add, MapName - " + ShineExit
    # 14 cells − 4 class-change = 10 for instance + tutorial clusters; zone 3 of the 2016 data uses 9 + 1 (RouT)

mc_Regist(cluster, field, rowName) @ FUN_0049ed40           (FieldMap::fm_Init, for every list cluster)
    if cluster.mc_MapIndex == rowName and field.fm_MapID != rowName (an instance, not the base map):
        mc_MapNumber ≥ 512 → "Too many mapcluster", ShineExit
        mc_Map[n] = {Field = field, RegisterNumber = −1, IsTimerSet = IsDelayTimerSet = bIsFailDelayTime = false,
                     Category = CLASSIC, eIndunLevel = ILT_MAX}; n++
        # bIsLimitTime / bIsLimitTimeWarning are not written (heap memory); harmless: mc_FindEmptyByRegnum sets both
        #  before the routine reads them (the routine only visits owned entries)
```

### 1.4 Finding and taking an instance

Every `cm_*` lookup builds a temporary `MapCluster(name)` and runs `ListSearchSame` with `mc_CompName` over the list
(`cm_FindMapCluster(name)` @ FUN_00486580 returns the cluster). "Searches" below walk the cluster's `mc_Map[]` from
`mc_Pointer` round-robin, at most `mc_MapNumber` entries.

```pseudo
cm_FindExistByRegnum(map, regnum, category, &level) @ FUN_00486400 → mc_FindExistByRegnum @ FUN_00484be0
    first entry with RegisterNumber == regnum and Category == category: level = eIndunLevel; return its Field

cm_FindEmptyByRegnum(map, regnum, category, level) @ FUN_00486290 → mc_FindEmptyByRegnum @ FUN_00484960
    first entry (after advancing mc_Pointer) with RegisterNumber == −1:
        IsTimerSet = false; fm_ClearObject(Field, 0x3b6)             # wipe the old run, players included (§1.10)
        # a player still standing in the free instance (a GM, who sp_EscapeFromEmptyID lets stay) is flagged
        #  Retrate and disconnected                                     (original bug, inferred intent) Z14-B14
        RegisterNumber = regnum; Category = category; eIndunLevel = level; bIsFailDelayTime = false
        row = fc_GetFirstInstanceDungeonInfo(cluster.mc_MapIndex)   # by map name (Z14-B1 fallback)
        if row: bIsLimitTimeWarning = false
            if row.LimitTime == 0: bIsLimitTime = false
            else: bIsLimitTime = bIsLimitTimeWarning = true
                  LimitExpirationTime = {now + LimitTime·600, LimitTime·600}          # minutes → ticks
                  if LimitTime > 5: Warning_1 = (LimitTime−5)·600, Warning_2 = (LimitTime−1)·600 ticks
                  # LimitTime 1..5: the warning flag is set but the warning metronomes keep old values; an entry
                  #  never used with LimitTime > 5 still has the ctor values {next 0, interval 0} (Metronome::Metronome
                  #  @ FUN_005ad7f0, built by InstanceMap::InstanceMap @ FUN_004847c0), so both warnings fire on every
                  #  15-s routine pass (next += 0)                                      (original bug) Z14-B4
        return Field          # note: IsDelayTimerSet is not cleared here (it is cleared by the next routine pass)
    none free → NULL

cm_PlayerinToInstanceDungeon(&outMap, row, regnum, category) → code @ FUN_00486d80
    row == NULL → 2
    inst = cm_FindExistByRegnum(row.MapIDClient, regnum, category, &lvl)
    if inst:
        n = players in inst (AxialListMobCounter ALMC_PLAYER over fm_GetCenterObject, so_AllInMap)
        if n ≥ row.MaxUseCount: return 3                              # full
    else:
        inst = cm_FindEmptyByRegnum(row.MapIDClient, regnum, category, ILT_NORMAL)
        if !inst: return 1                                            # no free instance
        ZoneRingPacketFindInstanceDungeon.zrpb_Success(row, inst) @ FUN_005a8c20:
            fm_ClearObject(inst, 0x3b0 = NPC, mob, door, bandit, effect); cc_DropFilm(row.ScriptName); close all doors (mda_CloseAllDoor);
            cc_PlayFilm(row.ScriptName, CeaseFireSender, inst.fm_MapID)  # restart the instance script
    outMap = inst.fm_MapID; return 0
    # the level is always ILT_NORMAL here: IDGate dungeons have one level; ModeIDGate uses the WM flow (Z08 §5.3)

cm_FindEmpty(map) @ FUN_004a05e0 → mc_FindEmpty @ FUN_0049f460      (job-change dungeons, §2.3)
    first entry whose map has no film running (Field.fm_Multiflex film count == 0); RegisterNumber is not used
cm_FindNotFullMap(Name3 map) @ FUN_004a0b40 → mc_FindNotFullMap @ FUN_0049f010   (tutorial)
    cluster missing → log "don't find MapCluster"; entry at mc_Pointer: fm_GetPlayerCountInField < MaxChr → advance
    mc_Pointer and return it; otherwise log "Tutorial Map Full - MapNumber : " and NULL
    # the loop counts to mc_MapNumber but never advances mc_Pointer on a full map, so the same map is tested every
    #  time (disassembly 0x49f030–0x49f086: only the success path increments +0xa010)   (original bug) Z14-B5
so_ply_LoginTutorialMap() @ FUN_00561450: m = cm_FindNotFullMap("RouT"); if m and its FieldAttr type == 4 (TUTORIAL):
    the character's login map = m.fm_MapID; so_datasync (vt 0x4c0); return 1; else 0   (caller: Z01 login, new characters)
```

### 1.5 Changing the owner (raid creation)

```pseudo
cm_ChangeCategory(oldReg, oldCat, newReg, newCat) @ FUN_00485210: for every cluster in the list:
    mc_ChangeCategory @ FUN_00484d20: the FIRST entry (index order, not mc_Pointer) with {oldReg, oldCat} gets
    {newReg, newCat}; return 1 (only one instance per cluster moves)
    returns 1 always
# callers: wms_NC_RAID_ZONE_MAKE_CMD (Z08 §2: {PARTY, nRaidPartyNo[0]} → {RAID, raidNo}) and GM &makeraid (Z11 §7.1)
# timers, level and limit time stay with the instance
```

### 1.6 Routine: empty instances, time limit, failure

`ZoneServer::zs_mainthreadfunction` @ FUN_005aca30: when `cm_EmptyCheck` is due (every 150 ticks = 15 s), every list
cluster runs `mc_Routine` @ FUN_004868d0. For each entry with `RegisterNumber != −1`:

```pseudo
if fm_Exist(Field, 4 = 1 << type 2 player) (a player is in the instance):
    if IsTimerSet: → WM 0xA403 NC_INSTANCE_DUNGEON_RESET_COUNTDOWN_CMD {u8 Category, u32 RegisterNumber} (7 B total)
    IsTimerSet = IsDelayTimerSet = false
else (empty):
    if !IsTimerSet:
        if !IsDelayTimerSet: EmptytoMsgDelay = {now + 200, 200}; IsDelayTimerSet = true
        elif now > EmptytoMsgDelay.next: EmptytoMsgDelay.next += 200
             IsTimerSet = true; TimeToDestroy = {now + 3000, 3000}
             → WM 0xA401 NC_INSTANCE_DUNGEON_EMPTY_DUNGEON_CMD {u8 Category, u32 RegisterNumber}
               (the WM asks the leader "delete now?", answer 0xA402 → Z08 §5.3 / ring 0x10B1 §2.2)
    if IsTimerSet and now > TimeToDestroy.next: TimeToDestroy.next += 3000; mc_DeleteInstanceDungeon(i)   (§1.7)
if bIsLimitTime and now > LimitExpirationTime.next: next += interval; mc_MissoionFailInstance(Field, "DungeonTimeout")
if bIsFailDelayTime and now > FailDelayTime.next: next += interval; mc_DeleteInstanceDungeon(i)
if bIsLimitTimeWarning:
    Warning_1 due: next += interval; wall message ss_String(etc, "LimitTimeMessageFirst") to every object in the map
                   (AxialListWall over so_AllInMap; missing text → assert "Not Found ETC : …")
    Warning_2 due: same with "LimitTimeMessageSecond"
```

Effective timing: an instance found empty by two consecutive passes more than 20 s apart (in practice 30 s) starts the
5-minute countdown and tells the WM; it is deleted 5 min later (± 15 s) unless a player returns first. The time limit
counts from the moment the instance was taken; the warnings come 5 and 1 min before it.

```pseudo
mc_MissoionFailInstance(Field, textKey) @ FUN_0049ee70: entry with Field == Field:
    bIsFailDelayTime = true; FailDelayTime = {now + 50, 50}             # deleted 5 s later by the routine
    row = fc_GetInstanceDungeonInfoByMapName(Field's map row name, eIndunLevel); if row: cc_DropFilm(script); close doors
    wall message ss_String(etc, textKey) to the map (missing → "Not Found ETC : DungeonTimeout"); fm_ClearObject(Field, 0xb0 = NPC, mob, door)
mc_GetLimitTime(&rest, regnum) @ FUN_0049f610: first entry with RegisterNumber == regnum (any category):
    if bIsLimitTime: rest = LimitExpirationTime.next − now (ticks); true                (Z01 0x1803 map-login, Z11 &idtimechange)
mc_SetLimitItem(minutes, regnum) @ FUN_0049f740: first entry with that regnum and bIsLimitTime:
    LimitExpirationTime = {now + minutes·600, minutes·600}                                (Z11 &idtimechange)
# both match on RegisterNumber only: a party and a guild with the same number collide (inferred, harmless in data)
```

### 1.7 Deleting an instance; films

```pseudo
cm_DeleteInstanceDungeon(category, regnum, playerCheck) @ FUN_004866b0
    visitor DeleteDungeon{_Category, _RegisterNumber, _playerCheck} (lid_Call @ FUN_004874f0) over every cluster:
    mc_DeleteInstanceDungeon(regnum, category, playerCheck) @ FUN_004867d0: first entry with {regnum, category} →
mc_DeleteInstanceDungeon(i, playerCheck) @ FUN_00486710
    → WM 0xA403 RESET_COUNTDOWN_CMD {Category, RegisterNumber}     # the WM clears its countdown/leader prompt
    IsTimerSet = bIsFailDelayTime = bIsLimitTimeWarning = false
    fm_KickAll(Field)                                              # every player linked out (Z01 / Z09 FieldMap)
    row = fc_GetInstanceDungeonInfoByMapName(row name of Field, eIndunLevel); if row: fm_DropFilm(Field, row.ScriptName)
    fm_ClearObject(Field, 0x3b2 = drop item, NPC, mob, door, bandit, effect); RegisterNumber = −1; eIndunLevel = ILT_MAX
    # Category is left as it was; players were kicked just before, so 0x3b2 leaves them out
    # playerCheck is never read: callers cannot ask for "only if empty"            (original bug) Z14-B6
# callers: party dismiss (Z08 §1, {PARTY}), raid dismiss (Z08 §2, {RAID}), guild delete (Z08 §8.2, {GUILD}),
#          ring 0x10B1 (§2.2, leader confirmed "ID_DeleteNow"), and the routine (§1.6)

cm_PlayAllFilm(map, script) @ FUN_004a0d40 → mc_PlayAllFilm @ FUN_00485fb0: every entry (by-value copy of the
    InstanceMap): Field NULL → "Filed is NULL :" + return false; else fm_PlayFilm(Field, script, CeaseFireSender)
    cluster missing → "cm_PlayAllFilm : MapCluster Is NULL", false                     (tutorial maps at load)
cm_AllDropFilm(map) @ FUN_00486ec0 → mc_AllDropFilm @ FUN_00485290     (GM &reloadid, &ReloadKingdomQuest; Z11)
    for every entry with a film running (fm_PlayFilmNum ≠ 0) and a row by map name + level:
        fm_KickAll; fm_DropFilm(script); fm_ClearObject(0x3b2); → WM 0xA403 {Category, RegisterNumber}
        RegisterNumber = −1, timer flags cleared — but on a local COPY of the entry, so the real entry keeps its owner,
        level and timers                                                            (original bug) Z14-B7
    # effect: after &reloadid the group still owns the (now empty, scriptless) instance; the next entry finds it via
    #  cm_FindExistByRegnum and links into a map without a running script; the routine deletes it only after the
    #  empty countdown (WM was already told "countdown reset")
```

### 1.8 Player side

```pseudo
wms_KickPlayerFromInstanceDungeon(q, regnum, category) @ FUN_00486c00      (Z08 §5.4 "InstanceEjectAfterLeave")
    require q, q.mode (vt 0x484) ≠ 0, q on a map whose FieldAttr type (+0x36) == 3 INSTANCEDUNGEON
    inst = cm_FindExistByRegnum(base name of q's map, regnum, category); require inst is q's current map
    mode ≠ 3 (not dead): so_LinkToReserv (vt 0x3fc) to the map's regencity at a random regenloc (index from rndbox over
        regenspots; ≥ 4 → regenloc[0])
    dead: sp_ReviveReqProcess(q)

sp_EscapeFromEmptyID() @ FUN_00440910       (called from sp_NC_MAP_LOGINCOMPLETE_CMD @ FUN_00443390, Z01: every map login)
    require q on a type-3 map
    so_AdministratorLevel (vt 0x4d4) ≥ 100 → so_ply_Notice("You are administrator."), stay
    if the instance script is running (map.fm_Multiflex (+0x44, Movie::CinemaComplex*) → List<FilmCase>::l_ListNum
       (+0x14) ≠ 0, the running-film count) and its cluster exists and so_GetInsDunGeonInRegNoAndType
       (vt 0xa8c) gives a key whose instance is q's map and a row exists:
        if players in the map > row.MaxUseCount and fm_GetRegenCityLinkData(map, &link): so_LinkToReserv(link)
        return                                                      # otherwise q stays
    else: sp_2Roumen(q)                                             # not the group's instance → to Roumen
    # on arrival or relog into an instance: a player whose group does not own this instance (instance deleted or
    #  reassigned meanwhile, group left), or whose instance has no script running any more (script ended, or dropped
    #  by &reloadid: Z14-B7), goes to Roumen; an owner stays unless the instance is over-full
```

### 1.9 Lifecycle summary

```
load    : Field.txt rows of this zone → one cluster per row (MapIDClient); sub-maps register as free instances
create  : IDGate / ring 0xA404: cm_PlayerinToInstanceDungeon → existing {cat, reg} or first free one (+ script restart)
          ModeIDGate: 0xA410 cm_FindEmptyByRegnum(level) (Z08 §5.3); GM &PlayIns (Z11 §7.2)
own     : RegisterNumber/Category; no player list; capacity = players currently inside (MaxUseCount)
change  : raid creation cm_ChangeCategory {PARTY, p} → {RAID, r}
timeout : empty 20–30 s → 0xA401 + 5 min → delete; players back → 0xA403; LimitTime → "DungeonTimeout" + 5 s → delete
delete  : party dismiss / raid dismiss / guild delete / leader's "delete now" (ring 0x10B1) / routine
          → 0xA403, kick all, drop film, clear objects, RegisterNumber = −1
```

### 1.10 Object-kind masks

`fm_ClearObject(field, mask)` (visitor `AxialListObjectClear::ali_Work` @ FUN_00495940) and `fm_Exist(field, mask)`
(`IsAnybody::ali_Work` @ FUN_00484680) test `mask & (1 << so_ObjectType)` (vt 0x4d0; types in `docs/knowledge/Z01.md`
§2: 1 drop item, 2 player, 4 NPC, 5 mob, 7 door, 8 bandit, 9 effect). The clear calls `so_RetrateFromMap` (vt 0x3f4,
FUN_00495d20: sets `smo_Flag.Retrate`); a player with that flag is disconnected with 0x680 (`docs/knowledge/Z09.md`, the
Z03 §2 row).

| Mask | Kinds | Used by |
|---|---|---|
| 0x4 | player | `fm_Exist` in `mc_Routine` (§1.6) |
| 0xb0 | NPC, mob, door | `mc_MissoionFailInstance` (§1.6) |
| 0x3b0 | + bandit, effect | `ZoneRingPacketFindInstanceDungeon::zrpb_Success` (§1.4) |
| 0x3b2 | + drop item | `mc_DeleteInstanceDungeon`, `mc_AllDropFilm` (§1.7, after `fm_KickAll`) |
| 0x3b6 | + **player** | `mc_FindEmptyByRegnum` (§1.4), `so_ply_2JobDungeon` FUN_0049f880 and `ZoneRingPacketFindJobDungeon::zrpb_Success` FUN_005a8f40 (§2.3) |

The three 0x3b6 users take a map for a new run and disconnect anyone still standing in it: a GM left in a free instance
(`sp_EscapeFromEmptyID` lets administrators stay), or a player still in a job-change map whose film has ended (the map
counts as free as soon as no film runs, §1.4 `mc_FindEmpty`). The other clears leave players alone
(original bug, inferred intent: clear the old run's objects, not players; 0x3b2 as in the delete path) Z14-B14.

## 2. Zone-ring handlers: instance and job dungeons (ZoneListenSession)

`zls_TravelComplete(start)` @ FUN_0045b1f0: true when `start.machine ≥ 10` or `start.machine == own zone` (back at
the origin). Every ring packet starts with `ZONERINGLINKAGESTART {u8 machine, u16 handle, u32 regnum}` (7 B). The handlers
below are registered in the ZoneListenSession table (`pft_Store`, Z01 §10). Forwarding = copy into `g_buf` and
`ZoneConnectSession::zcs_Send(&g_buf, len)` @ FUN_005a6ed0 to the next zone.

Ring-request classes (RTTI vftables, slots Request / Success / Failure as in `ZoneRingPacketBase`): `ZoneRingPacketEmtpyInstanceDungeon` = {zrpb_Request FUN_005a8a70, zrpb_Success FUN_005a8b70, empty stub FUN_00509900}; `ZoneRingPacketFindInstanceDungeon` and `ZoneRingPacketFindJobDungeon` hold the empty stub in all three slots: their Request / Success / Query functions are non-virtual overloads called directly. **None of the three has a Failure callback**: a request that comes back unanswered is handled by the TravelComplete branch of the handler itself (error code in the packet), not by a callback.

### 2.1 0xA404 NC_INSTANCE_DUNGEON_FIND_RNG (IDGate, party / raid instance on another zone)

Layout `PROTO_NC_INSTANCE_DUNGEON_FIND_RNG` (0x46): `Start` @0, `INSTANCE_DUNGEON::CATEGORY InstanceCategory` (i32) @7,
`u32 IDRegisterNumber` @0xb, `ORToken Argument` @0xf, `char ServerMapName[33]` @0x23, `u16 Error` @0x44. Error: 0 found,
1 no free instance, 2 not handled yet (initial), 3 full.

```pseudo
origin request: ZoneRingPacketFindInstanceDungeon.zrpb_Request(p, buf, row) @ FUN_005a92e0   (smfm_LinkToDungeon, Z08 §5.2)
    if row.ZoneNumber == own zone:
        category = p.so_GetRaid (vt 0xa84) ? RAID : PARTY; PARTY needs p.so_PartyRegistNumber (vt 0x550) ≠ −1,
            else so_ply_Notice(ss_String(etc, "CannotAddAnymore")); return
        # the category is recomputed here and the regnum is buf.IDRegisterNumber (from the menu data)
        code = cm_PlayerinToInstanceDungeon(&map, row, buf.IDRegisterNumber, category)
        code ≠ 0: "CannotAddAnymore" (also for 3 = full; the ring-origin path below says "InstanceDungeonMaxPlayer"
            for 3: the same condition gives two different messages; cosmetic, not tagged)
        else: walk the NPC option "LinkTable" rows (or_SelectFromOrder) for the one whose key == row.Argument;
              link = that row with linktoserver = map
              NeedItemID == 0xFFFF or Consume == 0: if sp_LinkReplyCheck(link): so_LinkTo (vt 0x600)
              else: sp_DestroyItem(p, p.handle, NeedItemID, Consume, link)   # consume, then link
    else: g_buf = 0xA404 {buf with Start = {own zone, buf.handle, buf.regnum}} ; zcs_Send(0x48)

0xA404 at a zone on the way  @ FUN_00487510 (zls_NC_INSTANCE_DUNGEON_FIND_RNG), !zls_TravelComplete:
    code = Error
    if Error ≠ 0 and row = fc_GetInstanceDungeonInfo(Argument, ILT_NORMAL) and row.ZoneNumber == own zone:
        code = cm_PlayerinToInstanceDungeon(&map, row, IDRegisterNumber, InstanceCategory)
        (the hosting zone uses the category from the packet)
    forward g_buf = copy; if code changed and is 0: ServerMapName = map name; Error = code; zcs_Send(0x48)
    # a zone that does not host the row only forwards; after a success the later zones skip (Error 0)
    # the hosting zone answers 1 / 3 as well, so "no free" and "full" are reported back

0xA404 back at the origin (zls_TravelComplete):
    p = som_FindPlayer(Start.regnum) (charNo); none → drop
    Error 0: row = fc_GetInstanceDungeonInfo(Argument, ILT_NORMAL) (NULL → drop); title "LinkTitle" is formatted but unused;
             find the LinkTable row with key == row.Argument; link.linktoserver = ServerMapName
             NeedItemID == 0xFFFF or Consume == 0: so_LinkTo (vt 0x600) directly  — no sp_LinkReplyCheck here, unlike
                 the same-zone path FUN_005a92e0, which calls it before vt 0x600 (original bug; intent inferred) Z14-B8
             else sp_DestroyItem(p, p.so_GetZoneHandle_ItemLooter(), NeedItemID, Consume, link)
    Error 1: so_ply_Notice("CannotAddAnymore"); 2: "RecallDisableField" (no zone hosts the row); 3: "InstanceDungeonMaxPlayer"
    # the item and group conditions were checked at the gate (Z08 §5.2) and are not re-checked when the answer arrives
```

`ZoneRingPacketFindInstanceDungeon.zrpb_Query(p, buf)` @ FUN_005a6d10 is Z08's `IDGate_OpenMenu`: server menu
`ss_String(menu, "LinkTitle")` (sprintf with the destination map name of the LinkTable row matching `buf.Argument`),
menu argument `{sma_ItemBreak = IDRegisterNumber, Argument string, sma_linkDungeon.category = InstanceCategory}`,
"Yes" → `smfm_LinkToDungeon`, "No" → `smfm_Cancel`, range 1000.

### 2.2 0x10B1 NC_CHAR_EMPTY_INSTANCE_DUNGEON_RNG (delete an instance everywhere)

Layout `PROTO_NC_CHAR_EMPTY_INSTANCE_DUNGEON_RNG` (0xb): `Start` @0 (handle 0xFFFF, regnum = the group's RegisterNumber),
`CATEGORY Category` (i32) @7.

```pseudo
origin: ZoneRingPacketEmtpyInstanceDungeon.zrpb_Request(p, buf) @ FUN_005a8a70     (smfm_DeleteInstanceDungeon, Z08 §5.3)
    vt 4 of the ring object = zrpb_Success FUN_005a8b70 (RTTI vftable) on the origin itself → local delete
    g_buf = 0x10B1 {Start {own zone, 0xFFFF, buf.regnum}, Category = buf.Category}; zcs_Send(0xd)
on the way @ FUN_00485120: !zls_TravelComplete:
    zrpb_Success @ FUN_005a8b70: cm_DeleteInstanceDungeon(Category, Start.regnum, false)   (§1.7)
    forward unchanged (0xd)
at the origin: nothing (stops)
```

### 2.3 0x441F NC_QUEST_JOBDUNGEON_FIND_RNG (job-change dungeon on another zone)

Layout `PROTO_NC_QUEST_JOBDUNGEON_FIND_RNG` (0x73): `Start` @0, `u16 nError` @7 (0x30C0 found, 0x30C1 searching,
0x30C2 refused), `char ClientMapName[33]` @9, `char ServerMapName[33]` @0x2a, `char ScriptName[33]` @0x4b,
`PROTO_NC_QUEST_SCRIPT_CMD_ACK QuestScript {u16 nQuestID, u8 nQSC, u32 nResult}` @0x6c.

```pseudo
origin request: ZoneRingPacketFindJobDungeon.zrpb_Request(p, clientMap, script, &ack) @ FUN_005a8d30
    called from the quest script scenario runner CQuestZone::QuestPlayer_ScenarioRun @ FUN_005bd2f0 (Z15):
        scenario 8 → ("Job1_Dn01", "Promote/JobChange1"); 11 → ("Rou", "Promote/JobChange2-1");
        12 → ("Job2_Dn01", "Promote/Job2_Gamb/Job2_Gamb"); 13 → ("Job2_Dn02", "Promote/Job2_Forest/Job2_Forest")
        (ack = {questId, nQSC 3, nResult 0}; if nResult comes back 2 the runner answers the script at once)
    require p, names, ack
    mode (vt 0x484) ∉ {1, 2, 6} (cmc_AllowMode 0x46): so_SendErrorCode(17, 32, 0x30C2) = client 0x4420
        NC_QUEST_JOBDUNGEON_LINK_FAIL_CMD {u16 err} (client text "You cannot teleport to the saved locaion in current
        state." — it ignores the code); ack.nResult = 2; return
    so_ply_IsLink_OutMap_AndSendErrorMsg (vt 0xa74) false → return (the client got that check's message)
    inst = cm_FindEmpty(clientMap)                                    # §1.4: no film running
    inst: so_ply_2JobDungeon (vt 0x3d0) @ FUN_0049f880(inst, script):
        map row of inst (mdb) missing → assert "Null info"/"Null option", 0
        fm_ClearObject(inst, 0x3b6: players too, §1.10, Z14-B14); so_ply_BriefLink (vt 0x890) to the map's RegenX/RegenY;
        map flags ff_CanUseReviveItem = ff_CanUseReviveSkill = 0; cc_PlayFilm(script, CeaseFireSender, inst.fm_MapID); 1
    none: g_buf = 0x441F {Start {own zone, p.handle, p.charNo}, nError 0x30C1, ClientMapName, ServerMapName = 0,
          ScriptName, QuestScript = ack}; zcs_Send(0x75)

on the way @ FUN_005bfde0 (zls_NC_QUEST_JOBDUNGEON_FIND_RNG), !zls_TravelComplete:
    if nError == 0x30C1 and inst = cm_FindEmpty(ClientMapName):
        ZoneRingPacketFindJobDungeon.zrpb_Success(inst, ScriptName) @ FUN_005a8f40: CeaseFireSender;
            fm_ClearObject(inst, 0x3b6: players too, Z14-B14); cc_PlayFilm(ScriptName, …, inst.fm_MapID)   # reserves it
        nError = 0x30C0; ServerMapName = inst.fm_MapID (12 B + NUL)
    forward (0x75)

back at the origin:
    p = som_FindPlayer(Start.regnum); p.so_ply_QuestDiary (vt 0xd38) — p is not checked for NULL   (original bug) Z14-B9
    diary NULL → drop
    mode ∉ {1, 2, 6}: 0x4420 {0x30C2}; QuestScript.nResult = 2; CQuestZone::Recv_NC_QUEST_SCRIPT_CMD_ACK(QuestScript)
        # the reserved instance on the other zone keeps its film until it ends (no release message)
    nError == 0x30C0: mi = map row of ClientMapName; if mi: so_LinkTo (vt 0x600)({ClientMapName, ServerMapName,
        RegenX, RegenY}, 6, 9, 10)          # the quest answer follows from the arrival (Z15)
    else (0x30C1, nobody had a free one): QuestScript.nResult = 0; Recv_NC_QUEST_SCRIPT_CMD_ACK → the script step fails
```

`so_ply_FindJobDungeon(map)` (vt 0x3cc) @ FUN_004a07b0 = `cm_FindEmpty(map)`; no direct caller was found (only the
vtable slot).

## 3. Guild storage across zones: 0x7493

Shared guild storage record (`gldstoramanager` = Z08's `g_GuildStorage`, class `GuildStorage::GuildStorageManager`
0x134358 B): a `List` of 300 cells over `gsm_StorageArray[300]` of `GuildStorageElement` (0x1070 B: `ItemGuildStorage
gse_Storage` (ItemBag) @0, `u64 gse_Cen` @0x1058, `u64 gse_Token` @0x1060, `u32 gse_Guild` @0x1068, `u8 gse_Activate`
@0x106c). Ctor @ FUN_00475610. Each player keeps the list handle of the storage it has open (`so_ply_GetMyGuildStorageHandle`
vt 0x830 / `Set…` vt 0x834, 0xFFFF = none). Bag ctor `ItemGuildStorage` @ FUN_006449e0: vftable + 0x24 `ItemInventoryCell` (0x74 B each).

```pseudo
gsm_FindStorage(guildNo, &handle) @ FUN_004751f0: ListSearchSame with gse_GuildCompare @ FUN_00474990 (gse_Guild difference) → element, handle
gse_StoreItem(pkt 0x3473, p) @ FUN_00474a80 (Z05 §7.2): clear the bag, ib_Initializetotal(items), cen, token;
    p ← 0x7492 NC_GUILD_STORAGEOPEN_ACK {u16 0x1240 ok, u64 cen, u64 token, u8 count, items…} (so_fullbufferitem_box);
    count mismatch → assert "ItemNumber not match"
gse_GetMoney/SetMoney/GetToken/SetToken @ FUN_004749b0 / 004749c0 / 004749e0 / 004749f0; gse_GuildCheck @ FUN_00474900;
gse_SetActivate / gse_Deactivate @ FUN_00474980 / FUN_00474970 (gse_Activate = 1 / 0);
gse_FreeDeactivate(list, cell) @ FUN_00474950: inactive → free its list cell; run over the whole guild-storage list on
    every main-loop pass by ZoneServer::zs_mainthreadfunction @ FUN_005aca30 (l_4AllInList(&gldstoramanager, …)), so a
    deactivated guild storage cell is freed on the next pass

so_ply_GuildStorageDeactivate() (vt 0x82c) @ FUN_00477420  (0x74A0 close, guild leave; Z08 §8)
    if guildNo ≠ 0 and a handle is open: s = gsm_FindStorage(guildNo, handle)
        if s: count the players with {same guild, same handle} (ShineGuildStorageDeactive::lid_Call @ FUN_00475ea0
              over the player list); count < 2 → gse_Deactivate(s)          # the list cell is NOT freed here
        handle = 0xFFFF
```

Sender: on the zone where a member withdrew, `so_ply_GuildStorageWithdrawAck` @ FUN_00537640 (Z05 §7.2) and the cell
releasers FUN_0048aca0 / FUN_0048ab80 (Z05 §3) send 0x7493 once into the ring and call `gsm_SendWithdraw2Member` locally.

```pseudo
0x7493 NC_GUILD_STORAGEWITHDRAW_RNG (0x2c) {Start, u32 gldregnum @7, u8 type @0xb, u8 slot @0xc, u8 isBuy @0xd,
        Name5 charid @0xe, u16 item @0x22, u64 lot|cen @0x24}               @ FUN_00474f10 (zls_NC_GUILD_STORAGEWITHDRAW_RNG)
    if Start.machine < 10 and Start.machine ≠ own zone:
        gsm_SendWithdraw2Member(copy) @ FUN_00474d80
    # no zcs_Send: the packet is not forwarded, so only the next zone of the ring hears of it      (original bug) Z14-B10
    # (with the four 2016 zones, two zones never get the notice; their members see no 0x7494)

gsm_SendWithdraw2Member(r): visitor ShineGuildStorageWithdraw (ctor @ FUN_00474cf0 writes 0x7494 into g_buf) over
    the player list; lid_Call @ FUN_004752d0 for each player q:
    q.guildNo (so_mobile_GetGuildRegnum vt 0x818) ≠ r.gldregnum → next
    q ← 0x7494 NC_GUILD_STORAGEWITHDRAW_CMD (0x21) {u8 type, u8 isBuy, Name5 charid, u16 item, u8 slot, u64 lot|cen}
    if q has a storage handle and q's name (so_CharName vt 0x56c) ≠ r.charid:
        s = gsm_FindStorage(q.guildNo, handle); s missing or another guild → so_ply_GuildStorageDeactivate(q); stop
        cell = s.gse_Storage.vt0(r.slot); cell: so_ply_ChangeCell (vt 0x604)(ITEM_INVEN {slot, box 4}, cell)
        else stop
    # "stop" = lid_Call returns 0, which ends l_4AllInList: the remaining guild members of this zone get no 0x7494
    #  (original bug) Z14-B11
    # this zone's own storage copy is NOT updated: the refreshed cell shows the pre-withdraw content
    #  (inferred: the copy is reloaded from the DB on the next 0x7491 open, Z05 §7.2)
```

Client 0x7494 (FUN_006b4880, C01): chat line "Guild Member %s took out %s item from the Item Storage" / "… %d %s(s) …"
/ "… purchased %s item with Guild Item Exchange Token" (isBuy) / money variant; type selects item vs money.

## 4. Guild academy reward storage across zones: 0x9872, 0x9874, 0x9884, 0x9885

Record: `gldacademyrewardstoramanager` (`GuildAcademyRewardStorage::GuildAcademyRewardStorageManager`, 0x3fe778 B,
ctor @ FUN_00472ef0): `List` over `garsm_StorageArray[500]` of `GuildAcademyRewardStorageElement` (0x20b8 B:
`ItemGuildAcademyRewardStorage garse_Storage` @0, `u64 garse_Cen` @0x20a8, `u32 garse_Guild` @0x20b0, `u8 garse_Activate`
@0x20b4). Player: `sp_GuildAcademyRewardStorageManager` {storagehandle, `GuildAcademyRewardStoreageGrade`}, handle via
vt 0x83c / 0x840. The storage belongs to the guild: a non-academy member (vt 0x858 `so_ply_isAcademyGuildMember` == 0) uses `guildNo` (vt 0x818), an
academy member (== 1) `academyNo` (vt 0x85c). In ITEM_INVEN the storage is box 0 (`Inven & 0xfc00 == 0`); box 9
(`0x2400`) is the player's bag (Z04 §1).

```pseudo
garsm_FindStorage(guildNo, &handle) @ FUN_0046f710: ListSearchSame with garse_GuildCompare @ FUN_00470890 (garse_Guild
    difference) over a temporary element (ctor @ FUN_00470840, bag ctor ItemGuildAcademyRewardStorage @ FUN_00644a40: vftable + 0x48 `ItemInventoryCell`, bag dtor @ FUN_006432f0)
# helpers: packet copy operators PROTO_…_WITHDRAW_RNG::operator= @ FUN_004709c0 (0x35 B, also used for DEPOSIT),
#  PROTO_…_ITEM_INFO_ZONE_RNG::operator= @ FUN_00470ab0 (0xb0 B), PROTO_NC_INSTANCE_DUNGEON_FIND_RNG::operator= @ FUN_004846c0
#  (0x46 B); ItemInventoryCell::iic_Clear @ FUN_00470d20 = "clear the cell" in §4.2
garse_SlotInfoCheck(SHINE_INVEN_SLOT_INFO s) @ FUN_00470a50: cell at s.inven & 0x3ff has the same item key, item id and lot
so_ply_GuildAcademyRewordSrorageItemInfoCmd(cmd, kind) (vt 0x87c) @ FUN_00470b50:
    kind 0 → 0x9873 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_CMD, 1 → 0x9875 …_DEPOSIT_CMD, other → nothing
    body GUILD_ACADEMY_REWARDSTORAGE_ITEM_INFO_CMD = PROTO_…_WITHDRAW_CMD (0x29): {u8 who, u8 type, Name5 charid,
    u16 item, u8 slot, u64 lot|cen, u64 storage_cen}; sent to the player (0x2b with opcode)
so_ply_GuildAcademyRewardStoreGradeFill(grade) (vt 0x870) @ FUN_0046dea0: GuildAcademyRewardStoreageGrade = grade
    (from 0x9871 / 0x9886, Z08 §10); read by the withdraw request (Z05)
so_ply_GuildAcademyRewardStorageDeactivate() (vt 0x844) @ FUN_0046f7f0  (0x986F close, academy leave, error paths)
    no = academy member ? academyNo (vt 0x85c) : guildNo (vt 0x818)
    # the code tests vt 0x858 == 0, then vt 0x858 == 1 and leaves the number uninitialised otherwise; vt 0x858 is
    #  so_ply_isAcademyGuildMember @ FUN_0055a540 = `m_nMyGuildAcademyNo != 0` (0 or 1), so that branch is dead
    #  (same in the visitor FUN_004725c0, local_90); not a bug
    if no ≠ 0 and a handle is open: s = garsm_FindStorage(no, handle)
        s: count players with {same no, same handle} (ShineGuildAcademyRewardStorageDeactive::lid_Call @ FUN_0046df40);
           < 2 → garse_Deactivate(s) @ FUN_00470870 and l_Free(list, handle)    # unlike the guild storage, the cell is freed
        handle = 0xFFFF
```

### 4.1 Withdraw / deposit (money and lots)

Senders (Z05 §7.3): `so_ply_GuildAcademyRewardStorageWithdrawAck` FUN_0046f970 / `…DepositAck` FUN_0046fc80 after the DB
answer, and §4.3 below.

```pseudo
0x9872 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_RNG / 0x9874 …_DEPOSIT_RNG (0x35, same layout)
        {Start, u32 gldregnum @7, u8 why @0xb, u8 who @0xc, u8 type @0xd, u8 slot @0xe, Name5 charid @0xf,
         u16 item @0x23, u64 lot|cen @0x25, u64 storage_cen @0x2d}          @ FUN_00473050 / FUN_00473160
    if Start.machine < 10 and ≠ own zone:
        forward unchanged (zcs_Send 0x37)
        s = garsm_FindStorage(gldregnum); if s:
            withdraw (garse_WithdrawAtOther @ FUN_00470e50; manager @ FUN_00471e20):
                type 2 (money): garse_Cen = storage_cen
                type 1 (lot item): cell = storage[slot]; lot < cell.lot → cell.lot −= lot; else clear the cell
                type 0 (single item): clear the cell
            deposit (garse_DepositAtOther @ FUN_00470fe0; manager @ FUN_00471ee0):
                type 2: garse_Cen += cen; type 1: cell.lot += lot (no cap); type 0: clear the cell
                # type 0 deposit empties the slot; items are placed by 0x9884 instead (inferred: type 0 never sent here)
        garsm_SendWithdraw2Member @ FUN_00471600 / garsm_SendDeposit2Member @ FUN_00471780: visitor
            ShineGuildAcademyRewardStorageWithdraw / …Deposit (ctor @ FUN_00471550 / FUN_004716d0: own 0x49-B buffer,
            0x9873 / 0x9875 with {who, type, charid, item, slot, lot, storage_cen}, why kept aside);
            lid_Call @ FUN_00472140 / FUN_00472380 for each player q whose storage number (by kind) == gldregnum:
                why ≠ 0: q ← 0x9873 / 0x9875 (0x2b)
                q has the storage open, q.name ≠ charid and type ≠ 2:
                    storage missing or other guild → vt 0x844 close; stop                     (Z14-B11)
                    cell = storage[slot]: so_ply_ChangeCell(ITEM_INVEN {slot, box 0}, cell); else stop (Z14-B11)
```

### 4.2 0x9884 NC_GUILD_ACADEMY_REWARDSTORAGE_ITEM_INFO_ZONE_RNG (item moves)

Layout (0xb0): `Start` @0, `u32 nGldregnum` @7, `u8 Who` @0xb, `Name5 Charid` @0xc, `u8 Type` @0x20,
`SHINE_INVEN_SLOT_INFO From` @0x21, `SHINE_INVEN_SLOT_INFO To` @0x31 (each 0x10: `SHINE_ITEM_REGISTNUMBER ItmeReg` @0,
`u16 ItemID` @8, `ITEM_INVEN inven` @0xa, `u32 Lot` @0xc; pdb2016), `ItemTotalInformation ChangeIteminfo` @0x41. Sender: the cell releaser
`InvenCellReleaser_GuildAcademyRewardStorageInfoZoneRng::icr_Apply` FUN_00488250 (Z05 §3).

```pseudo
@ FUN_00473270 (profiler name "…DEPOSIT_RNG", copy-paste)
    if Start.machine < 10 and ≠ own zone: forward (0xb2); apply; notify
apply: garsm_ItemInfoZoneRngAtOther @ FUN_00471fa0 → garse_ItemInfoZoneRngAtOther @ FUN_00471110
    a side in the storage (box 0) whose cell no longer matches (garse_SlotInfoCheck) → garse_Activate = 0; return
    from = storage[From & 0x3ff], to = storage[To & 0x3ff]; either missing → return
    Type 0/1 (move): From in the storage → clear it; To in the storage → store ChangeIteminfo at to
    Type 2 (split out): From in the storage → from.lot −= lot of ChangeIteminfo; To in the storage → store ChangeIteminfo
    Type 3 (merge):     From in the storage → from.lot = To.Lot − (ChangeIteminfo.lot − from.lot); To → store
    Type 4 (swap):      From in the storage and To in the bag (0x2400) → store ChangeIteminfo at from;
                        both in the storage → from ← to's item, to ← ChangeIteminfo; otherwise nothing
notify: garsm_SendItemInfoZoneRng2Member @ FUN_00471920 → visitor ShineGuildAcademyRewardStorageItemInfoZonRng
    (ctor @ FUN_00471850: two ITEM_INFO_CMDs {who = Who, type 0, charid, item = From.ItemID, slot = From slot})
    lid_Call @ FUN_004725c0 for each player q of the guild/academy (From.ItemID == 0xFFFF → stop):
        if From or To is the bag (0x2400): type = From item stackable (MaxLot > 1)
            Type 0/1: storage From → 0x9873 {lot = From.Lot}; storage To → 0x9875 {lot = From.Lot}
            Type 2/3: the lot moved (from ChangeIteminfo, Type 3: − To.Lot) → 0x9873 / 0x9875 for the storage side(s)
            Type 4: 0x9873 {From item, From.Lot} and 0x9875 {To item (stackable flag of To), To.Lot}
        q has the storage open and is not Charid: refresh the storage cells From / To (so_ply_ChangeCell);
            missing storage → vt 0x844, stop; empty cell → stop                       (Z14-B11)
```

### 4.3 Academy rewards: 0x986C body and 0x9885

```pseudo
0x986C NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_ACK (Character DB → zone) @ FUN_0046f380:
    p = som_GetObject(ref.handle), not closing (vt 0x300), charNo matches → vt 0x878:
so_ply_GuildAcademyRewardStorageRewardZoneRng(ack) @ FUN_0046e750
    ack layout (0x3d + 9·n): {NETPACKETZONEHEADER ref, u16 Error @6, u32 nCharNo @8, u32 nGuildNo @0xc, u64 nWantMoney @0x10,
        u32 nWantItemCnt @0x18, GUILD_ACADEMY_REWARD_ITEM WantItem @0x1c, u64 nSubAcademyMoney @0x2c,
        u64 nStorageMoney @0x34, u8 nModifyItemCnt @0x3c, EACH_MODIFY_ITEM[n] {u8 nStatus, u16 nItemID,
        ITEM_INVEN nLocation, u32 nLot} @0x3d}
    Error ≠ 0x18A0 (success) → assert "receive error"; p not an academy member (vt 0x858 ≠ 1) → "guildacademy member";
    academyNo ≠ nGuildNo or 0 → "guildacademy number"                       # all: no reply to the client
    g_buf = 0x9885 {Start {own zone, p.handle, p.charNo}, nGuildNo, sCharID = p.name, Reward_Cen = nSubAcademyMoney,
        Storage_Cen = nStorageMoney, Reward_ItemNum = nModifyItemCnt, Reward_ItemInfo[] = ModifyItem[]}; zcs_Send(0x32 + 9n)
    apply locally (garsm_RewardInfoZoneRngAtOther) and notify locally (garsm_SendRewardInfoZoneRng2Member), as below
    if nSubAcademyMoney ≠ 0: p money += nSubAcademyMoney (vt 0x434 so_ply_CurrentMoney / 0x440 so_ply_StoreMoney
        / 0x448 so_ply_ChangeCen); no upper-bound check: StoreMoney @ FUN_0055a060 stores the u64 as is and the zone has no
        money cap on any path, so only a u64 wrap could go wrong (not a bug; the amount comes from the Character DB)
    # WantItem / nWantItemCnt / nWantMoney are not used here; the items reach the member through the storage withdraw
    #  rows (nStatus/nLot) — how the member's bag receives them is outside this function (inferred: DB side, D07)

0x9885 NC_GUILD_ACADEMY_REWARDSTORAGE_REWARD_ZONE_RNG (0x30 + 9n) {Start, u32 nGuildNo @7, Name5 sCharID @0xb,
        u64 Reward_Cen @0x1f, u64 Storage_Cen @0x27, u8 Reward_ItemNum @0x2f, EACH_MODIFY_ITEM[] @0x30}   @ FUN_00473370
    if Start.machine < 10 and ≠ own zone: forward (0x32 + 9n); apply; notify
apply: garsm_RewardInfoZoneRngAtOther @ FUN_00472070 → garse_RewardInfoZoneRngAtOther @ FUN_00471450
    garse_Cen = Storage_Cen
    for each item: cell = storage[nLocation & 0x3ff]; cell missing or cell.itemID ≠ nItemID → stop
        nStatus 0: cell.lot == nLot → clear the cell, else stop
        nStatus 1: cell.lot > nLot → cell.lot −= nLot, else stop
        # loop: index +1 and entry pointer +9 per pass, up to Reward_ItemNum
notify: garsm_SendRewardInfoZoneRng2Member @ FUN_00471ac0 → ShineGuildAcademyRewardStorageRewardInfoZonRng
    (ctor @ FUN_00471a00: CenCmd {who 3, type 2, charid = sCharID, item 0, slot 0, cen = Reward_Cen, storage_cen};
     ItemCmd {who 3, type 0, item = first entry's nItemID})
    lid_Call @ FUN_00472b20 for each player q of the guild/academy:
        Reward_Cen ≠ 0 → q ← 0x9873 CenCmd
        items: ItemCmd.lot = Σ nLot of all entries; type 1 if the first item is stackable; q ← 0x9873 ItemCmd
            # one line for all items, named after the first item only (inferred: rewards are one item kind)
        q has the storage open and is not sCharID: refresh every entry's cell; missing storage → vt 0x844, stop;
            empty cell → stop                                                          (Z14-B11)
```

Client: 0x9873 (FUN_006f4910) shows "Academy Member %s has received %s" (who 3) or "%s has retreived %s from the Guild
Storage." with "Gem"/"Gold" for money; 0x9875 (FUN_006f4eb0) "%s has deposited %s item into Guild Storage." /
"… %I64d of %s item(s) …" (C01).

`so_ply_GuildAcademyRewardStorageRewardAck` (vt 0x850) @ FUN_0046e430 is an older variant of the same reward handling
(money as one 0x9872 type 2 and each item as a 0x9872 type 1 withdraw, then the same money add); no code calls slot 0x850
(dead code).

## 5. Raid internals (zone copy)

### 5.1 Raid record and RaidSystem

The zone links the same `Raid` / `RaidSystem` library as the WM (W02 §2). Zone instance: function-static `raid`
(`RaidTask::GetRaidSystem` @ FUN_005cdda0, built on first use over `partycontainer` = Z08's `g_ZoneParties`; Z08's
`g_RaidTask` DAT_14d50830 is this `RaidSystem`; `RaidTask` itself is an empty class of static functions).

```
RaidSystem (0x6d60): Raid m_RaidSlot[500]; static CParty* sm_pPartyData
Raid (0x38): +4 u16 m_Raidnum (0xFFFF free) · +6 u8 m_NumOfMember · +8 u16 m_PartyNos[4] · +0x10 u32 m_Leader ·
             +0x14 u32 m_SubLeader[4] · +0x24 CLooting m_Looting
Raid::iterator (0xc): {Raid* m_pRaid, int m_nPartyIndex, int m_nSlot}; Begin {0,0}, End {4,0}, ++ = next slot, after 4 next party
```

| Zone function | Official name | W02 counterpart (WM, same logic) |
|---|---|---|
| FUN_0063d6a0 | RaidSystem::RaidSystem (sm_pPartyData = party registry) | — |
| FUN_0063d0f0 / FUN_0063d6d0 | RaidSystem::FindRaid / GetRaid (0xFFFF → NULL; slot must hold that number) | Raids_Get FUN_00462b10 |
| FUN_0063d6f0 | RaidSystem::CreateRaid(raidNo, partyNos[4], &err): slot raidNo free → InitRaid | (zone only: the WM's number is reused) |
| FUN_0063d760 | RaidSystem::CreateRaidAndParty(firstParty, &err): first free slot, 3 new raid parties | Raids_Create FUN_00462fb0 |
| FUN_0063d240 | Raid::InitRaid (codes 0x1EC1, 0x1EC2, 0x1E86; leader = looter = first party's member 0; see below) | Raid_Init FUN_00462c60 |
| FUN_0063e110 / FUN_0063d970 | RaidSystem::ResetRaid (not found → 8000) / Raid::Reset | Raid_Dismiss FUN_004631c0 |
| FUN_0063d360 / FUN_0063db20 | Raid::AddMember (two overloads; zone uses the MEMBER_JOIN_CMD one) | Raid_AddMember FUN_00463370 |
| FUN_0063de00 | Raid::DeleteMember | Raid_RemoveMember FUN_00463650 |
| FUN_0063dc10 / FUN_0063ded0 | Raid::SlotChangeMember / SwapMember | Raid_MoveMember FUN_00463460 / Raid_SwapMembers FUN_00463720 |
| FUN_0063e090 / FUN_0063df80 / FUN_0063cfa0 / FUN_0063e030 | SetLeader / AddSubLeader / DelSubLeader / SetLooter | FUN_004638e0 / 004637d0 / 00462980 / 00463880 |
| FUN_0063da80 | Raid::Find(charNo) → iterator | Raid_Find FUN_004632d0 |
| FUN_0063d4d0 | iterator::GetCharRegistNo: false only for a bad index or party slot 0xFFFF; positions past the party's member count give true with charNo −1 | |
| FUN_0063d5d0 / FUN_0063d0d0 / FUN_0063d590 | iterator::GetSlotInfo (member slot or NULL) / GetPartyRegNo / GetPartySlot | |
| FUN_0063d050 / 0063d060 / 0063d070 / 0063d470 / 0063d4a0 / 0063d8b0 / 0063cfe0 / 0063d410 / 0063d620 | GetNumOfMember / GetLooter / GetLooting / SetItemDiceGameMode / IsItemDiceGameIng / RaidSystem::GetInRaidNumber / _PartyLeaveCheckResult / GetMemberRegNoByIndex / iterator::UpdateMemberName | read by name only (not opened) |

```pseudo
Raid::InitRaid(raidNo, partyNos[4], &err) @ FUN_0063d240
    sm_pPartyData NULL → 0x1EC1; m_Raidnum ≠ 0xFFFF (slot taken) → 0x1EC2
    first = CParty[partyNos[0]]; m_Raidnum = raidNo; m_NumOfMember = first.NumOfMember; m_Leader = first.Members[0].chrregnum
        # `first` is dereferenced without the NULL check the loop below makes            (original bug) Z14-B15
    looting reset, looter = leader; first.isRaidTypeParty = true
    for i in 0..3: party = CParty[partyNos[i]]
        NULL → 0x1E86; reset the record (numbers, leader, sub-leaders −1, looting) — parties 0..i−1 keep
               isRaidTypeParty = true                                                 (original bug) Z14-B15
        party.isRaidTypeParty = true; m_PartyNos[i] = partyNos[i]
    true
# zone caller: RaidSystem::CreateRaid ← rt_CreateRaid ← 0xB004 NC_RAID_ZONE_MAKE_CMD (Z08 §2) with the WM's party numbers
```

### 5.2 RaidTask

```pseudo
rt_GetRaid(raidNo) @ FUN_005cdf80 = Z08 Raid_Find
rt_CreateRaid(raidNo, partyNos) @ FUN_005cde10: partyNos == NULL → CreateRaidAndParty(raidNo) (GM &makeraid);
    else CreateRaid(raidNo, partyNos); on success every online member gets so_SetRaid (vt 0xa88)(raid)
rt_ResetRaid(raidNo) @ FUN_005ce320: online members so_SetRaid(NULL); ResetRaid; on failure re-link them; result
rt_AddPlayer(MEMBER_JOIN_CMD) @ FUN_005ce4f0: Raid::AddMember; failure → assert "RaidTask::rt_AddPlayer" (err);
    the joining player, if here, so_SetRaid(raid) and is returned
rt_DelPlayer(raidNo, charNo) @ FUN_005ce5e0: Raid::DeleteMember (fail → "RaidTask::rt_DelPlayer :"); local player
    so_SetRaid(NULL) and returned
_GetRaidPlayer(&near, raidNo, center, range) @ FUN_005ce000: NearRaidPlayers {unNum, pPlayers[20]}: every online
    member (ShinePlayer) within range of center (range 0 or no center = all); rt_GetNearRaidPlayer = range 1000
    @ FUN_005ce6d0, rt_GetRaidPlayer = all @ FUN_005ce6f0
rt_QuestCheck(fn, p, mob, idx) @ FUN_005ce710 (profiler name "PartyManufacture::pm_QuestCheck"): for each raid member within
    1000 of the mob: so_ply_QuestCheck (vt 0x7f4)(fn, p, mob, idx)        # raid share of quest kill credit (Z09/Z15)
rt_Broadcast(p, pkt, len) @ FUN_005cd720: p NULL or not in a raid (vt 0xa84) → false; walk the raid positions
    (Raid::iterator): GetCharRegistNo false → return false at once (stop, not skip; unreachable in practice: a raid
    always holds 4 valid parties, Raid::InitRaid); else the member, if online and on p's map (same so_Field), gets the
    packet through the game socket (vt 0x2fc), p included; pp_SetPacketLen(len) failure → "RaidTask::rt_Broadcast : Packet
    Too Long"; true. (Profiler string copied from pm_QuestCheck.)
```

### 5.3 Raid status packets (zone → client)

`pp_SetPacketLen` takes the total length including the 2-byte opcode.

```pseudo
GetPlayerInfo(&RAID_MEMBERCLASS e, iterator) @ FUN_005cd5a0: e = {nPartyNo, nPartyIndex, nSlotIndex, level, charid,
    chrclass from the party slot}; if the member is online here: class (vt 0x49c → +0x38), level, name, maxhp/maxsp/maxlp,
    hp/sp/lp, loc = current x/y; else hp = sp = lp = 0, max = 1, loc = 0   (false when the slot is empty)

rt_SendPlayerData(p) @ FUN_005cd8f0 → rt_Broadcast 0xB022 NC_RAID_MEMBERINFORM_CMD (0x12 total)
    {u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 hp, u32 sp, u32 lp}           (caller: player tick, Z08 §1.2 counterpart)
rt_SendPlayerDataDetail(p) @ FUN_005cd9c0 → rt_Broadcast 0xB023 NC_RAID_MEMBERCLASS_CMD {u8 nNum = 1, RAID_MEMBERCLASS} (0x3d)
rt_SendPlayerDataDetail(raidNo, charNo) @ FUN_005ce190 → the same 0xB023 for that member to EVERY online raid member
    on this zone (any map; the walk stops at the first false GetCharRegistNo, as in rt_Broadcast)                                                           (Z08 §2 0xB013 when the joiner is remote)
rt_SendMeRaidPlayersData(p) @ FUN_005cda50 → p only: 0xB023 {u8 nNum, RAID_MEMBERCLASS[nNum]} for every filled position
    length = nNum·0x3a + 1 instead of nNum·0x3a + 3: the last entry loses its last 2 bytes (loc.y high half); with
    nNum = 0 the length (1) is shorter than the opcode                              (original bug) Z14-B12
rt_SendPlayerLocation(p) @ FUN_005cdb50 → rt_Broadcast 0xB026 NC_RAID_LOCATION_CMD {u8 nNum = 1, Memberinfo
    {u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 x, u32 y}} (0xf)
rt_SendPlayerLocationExChange(p) @ FUN_005cdc00: rt_SendPlayerLocation(p), then p ← 0xB026 {nNum, Memberinfo[nNum]} of every
    raid member on p's map (12-byte entries) with length nNum·0x3a + 1 (the MEMBERCLASS formula; assert text names
    rt_SendMeRaidPlayersData): far more bytes than written, the rest is stale g_buf content    (original bug) Z14-B13
```

0xB020 NC_RAID_LOGOUTINFO_CMD has no zone sender (WM sender, W02).

```pseudo
sp_partylogout() @ FUN_0056dd80        (only caller: so_CloseByLink vt 0x310 @ FUN_005934b0, the player leaves the map
                                        by a link; Z06 §"Who breaks a trade from outside")
    in a raid (vt 0xa84 so_GetRaid ≠ NULL):
        g_buf = 0xB021 NC_RAID_MAPOUT_CMD {Name5 sCharID = own name (vt 0x56c)} (0x16 total); rt_Broadcast(p, g_buf, 0x16)
            # raid members on the same map, p included
    else: g_buf = 0x384A NC_PARTY_MEMBERMAPOUT {Name5 memberid = own name} (0x16 total; client FUN_0049a750), for each slot of the last party (sp_LastPartyParam.pmi_PartySlot,
        0x24-byte members) whose chrregnum is not p's and whose memberobj is set:
            memberobj not closing (vt 0x300 == 0) and memberobj.charNo (vt 0x344) == the slot's chrregnum → send to it
                (game socket vt 0x2fc; pp_SetPacketLen failure → "…sp_partylogout : Packet Too Long")
            else: memberobj = NULL (stale pointer cleared)
```

Client handlers (C01):

| Opcode | Client | What it does |
|---|---|---|
| 0xB021 | FUN_0049bfd0 | finds the member by the 20-byte name in the raid table: clears its located flag (+0x40) and removes it from the minimap; same flag cleared in the party table |
| 0xB022 | FUN_0049c0c0 | reads {nPartyNo, idx, slot, hp, sp, lp}, updates the member's bars |
| 0xB023 | `On_NC_RAID_MEMBERCLASS_CMD` FUN_004a4890 | reads nNum then the entries: `RaidInfo::MemberInfoDetailInfo` per entry, rebuilds the minimap raid list, adds / updates own-party members (`Party::AddMember`); with Z14-B12 the last entry's loc.y high half comes from the 2 bytes after the packet (stale receive-buffer bytes) |
| 0xB026 | `On_NC_RAID_LOCATION_CMD` FUN_0049c160 | per entry (12 B): member = raid table[`nPartyIndex·5 + nSlotIndex`] (nPartyNo ignored); x/y → float, sets the online/located flags (+0x14, +0x40), adds the member to the minimap; nPartyIndex == own party index → also updates the party-window entry. Reads only nNum entries, so Z14-B13's extra bytes are ignored |
| 0xB020 | FUN_0049bea0 | (WM sender, W02) |

## 6. Z08-B5 and Z08-B9 re-checked

- **Z08-B5** (0xB01C passes the vanished member's charNo as the raid number, twice): `wms_KickPlayerFromInstanceDungeon`
  looks up `cm_FindExistByRegnum(map, charNo, RAID)`; an instance owned by `{RAID, charNo}` cannot exist (raid numbers
  are < 500, charNos are DB keys), so the lookup fails and the member is **never** linked out of the raid dungeon;
  the second call is a no-op. Effect confirmed: a vanished raid member stays inside the raid's instance.
- **Z08-B9** (level-select request flag left set): confirmed in `wms_NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_ACK`
  @ FUN_00485540: only the two "menu sent" paths call `sp_SetModeIDWaitState(0)`; the NPC/range failures and the
  "Indun Level Data Null" path do not. The flag is also cleared by `sp_NC_MAP_LOGINCOMPLETE_CMD` @ FUN_00443390 (every map
  change or relog) and the player ctor, so the block lasts until the next map change, not forever.

## 7. Original-server bugs

| ID | Handler / function | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z14-B1 | fc_GetFirstInstanceDungeonInfo FUN_00484380 / FUN_004843e0 | returns the last row instead of NULL when nothing matches | a lookup by an unknown key/map yields an unrelated row (LimitTime, MaxUseCount) | return NULL |
| Z14-B2 | AddInstanceDungeonCluster FUN_00484850, cm_AddTutorialMapCluster FUN_004a0860 | check "all 10 Clusters[] used" but never store into Clusters[] | dead limit; the real limit is the 14-cell list, overflow = ShineExit | store the cluster pointer or drop the array |
| Z14-B3 | AddInstanceDungeonCluster | no duplicate-name check; rows of two levels with the same MapIDClient make two clusters | second cluster unused but registers all instances and takes a list cell (zone 3 has 9 of 10 free cells in use) | one cluster per map name |
| Z14-B4 | mc_FindEmptyByRegnum FUN_00484960 | LimitTime 1–5: warning flag set, warning metronomes not set (ctor values {0, 0}, FUN_005ad7f0) | an entry never used with LimitTime > 5 fires both warnings on every 15-s pass; otherwise at stale times (latent: all LimitTime are 0) | only set the flag when LimitTime > 5 |
| Z14-B5 | mc_FindNotFullMap FUN_0049f010 | loop never advances to the next map when the current one is full (disassembly) | tutorial login fails ("Tutorial Map Full") while other RouT copies are free | advance mc_Pointer in the loop |
| Z14-B6 | mc_DeleteInstanceDungeon FUN_00486710 | `playerCheck` argument never read | callers cannot protect occupied instances (all pass false today) | honour it or remove it |
| Z14-B7 | mc_AllDropFilm FUN_00485290 (&reloadid) | resets a by-value copy of the InstanceMap | owner/level/timers stay; group re-enters a cleared map without a script | modify the entry in place |
| Z14-B8 | 0xA404 at the origin FUN_00487510 | links without `sp_LinkReplyCheck` (the same-zone path FUN_005a92e0 checks it) | link checks skipped for cross-zone instance entry | call sp_LinkReplyCheck as in zrpb_Request |
| Z14-B9 | 0x441F at the origin FUN_005bfde0 | `som_FindPlayer` result used without NULL check | zone crash if the player left while the request was on the ring | check for NULL |
| Z14-B10 | 0x7493 FUN_00474f10 | the ring packet is not forwarded | only the next zone notifies its guild members of a storage withdraw | forward like 0x9872 |
| Z14-B11 | ShineGuildStorageWithdraw::lid_Call FUN_004752d0 and the four academy visitors (FUN_00472140, FUN_00472380, FUN_004725c0, FUN_00472b20) | return 0 (stop the player iteration) when the viewer's storage is missing or the cell is empty | the remaining members on that zone get no notice / cell refresh | return 1 (continue) |
| Z14-B12 | rt_SendMeRaidPlayersData FUN_005cda50 | length nNum·0x3a + 1 (2 short) | last member's loc.y truncated; nNum 0 → invalid length | nNum·0x3a + 3 |
| Z14-B13 | rt_SendPlayerLocationExChange FUN_005cdc00 | 0xB026 list sent with the MEMBERCLASS length formula | 46 extra stale bytes per entry on the wire; client reads only nNum entries | nNum·12 + 3 |
| Z14-B14 | mc_FindEmptyByRegnum FUN_00484960, so_ply_2JobDungeon FUN_0049f880, ZoneRingPacketFindJobDungeon::zrpb_Success FUN_005a8f40 | `fm_ClearObject(0x3b6)` includes players (type 2): anyone in the map being taken is flagged Retrate | a GM in a free instance, or a player still in a job map whose film ended, is disconnected (0x680) when the next group takes the map | clear only non-player kinds (0x3b2 as in the delete path) *(inferred)* |
| Z14-B15 | Raid::InitRaid FUN_0063d240 (0xB004 → CreateRaid) | party 0 dereferenced without NULL check; on a missing party i the earlier parties keep `isRaidTypeParty = true` | zone crash if the WM names an unknown first party; parties left marked as raid parties after a failed create | check party 0 like the others; undo the flags on failure |

Z08-B5 and Z08-B9: effects refined in §6 (owned by Z08).

## 8. Not reconstructed / uncertain

- `ItemBag` vtable slot 0 (`gse_Storage.vt0(slot)`) is read as "cell at slot" from its use; not opened.
- The type 0 / type 1 branches of 0x9872 / 0x9874 are reached only by the dead `RewardAck` (vt 0x850) and by senders
  in Z05; whether a type 0 deposit is ever sent was not traced.
- `fm_KickAll` and `CinemaComplex` film internals belong to FieldMap / Movie (Z09 §28.8); the object-kind masks are
  decoded in §1.10.
- Z14-B14's intent (keep players out of the clear) is inferred; the code clears them on purpose or not.
- `so_LinkTo(link, 6, 9, 10)` extra arguments in the job-dungeon origin path are not decoded.
- No capture contains any of these messages.

## 9. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| WM side of 0xA401 / 0xA402 / 0xA403 / 0xA419 | W04 (done) `W04-social-misc.md` lines 1756–1880 | WM handlers of the instance countdown and map registry |
| IDGate / ModeIDGate gates, level-select flow, `fc_CanEnterIndun`, rank list | Z08 (done) §5 | senders and the WM flow are there; this item adds only the ring and cluster side |
| `CQuestZone::QuestPlayer_ScenarioRun` FUN_005bd2f0, `Recv_NC_QUEST_SCRIPT_CMD_ACK` | Z15 (open; plan: "quest script engine", `QuestPlayer_ScenarioRun`) | the job-dungeon request is one scenario step of the quest script |
| `so_ply_GuildStorageWithdrawAck` FUN_00537640, cell releasers FUN_0048aca0 / FUN_0048ab80 / FUN_00488250, academy withdraw/deposit ACKs FUN_0046f970 / FUN_0046fc80, `so_ply_GuildAcademyRewardStoreFill` FUN_0046ff90 | Z05 (done) §3, §7.2, §7.3 | the senders of the ring packets (DB answers) |
| Character-DB reward merge for 0x986B / 0x986C | D07 (open; plan: academy reward storage merge 0x986B) | DB side of the academy reward |
| `fm_ClearObject`, `fm_KickAll`, `fm_Exist`, `CinemaComplex::cc_PlayFilm` / `cc_DropFilm`, door blocks | Z09 (done) `Z09-world.md` §28.8 (helper table: `fm_Exist` FUN_00485040, `fm_KickAll` FUN_00484f70), §25.6 / §24.8 (`fm_ClearObject` FUN_00495a10 kinds) | map object and film engine; the masks used here are decoded in §1.10 |
| GM `&makeraid`, `&PlayIns`, `&idtimechange`, `&reloadid`, `&ReloadKingdomQuest` | Z11 (done) §3.3, §7.1, §7.2 | GM commands calling the cluster functions documented here |
| map-login limit-time display (`mc_GetLimitTime` in 0x1803 FUN_00443390) | Z01 (done) `Z01-core.md` line ~506 | map login |
| `sp_EscapeFromEmptyID` FUN_00440910 caller 0x1803 map-login complete FUN_00443390 | Z01 (done) map login | the call site is the map login; the function itself is documented here in §1.8 |
| Raid creation/dismiss/member handlers 0xB004…0xB03E | Z08 (done) §2 | the handlers; this item documents the record and RaidTask they call |
| `Raid::*` getters listed as "read by name only" in §5.1 | W02 (done) §2 (WM copy of the same library) | identical shared library; W02 documents the logic |
| `fc_MakeField`, `MapSubString`, FieldList loader | Z09 (done) `Z09-world.md` §10.3 (per-instance field set-up from `fc_MakeField`), §28.1 (map initialisation, `MapSubString` FUN_00461be0) | map creation; §1.1 records only what the clusters need |
| Lua side of instances: `cIndunRankResult` FUN_005ee4d0 (0xA413/0xA415 rank), `InstanceDungeonClear`, `cScoreBoard*`, `LuaArgumentInstanceDungeon` FUN_005d6e20 / FUN_005d6e40 | Z09 (done) §27.3, §28.12; WM side W04 §13.3 | script API used by the instance scripts started here |
