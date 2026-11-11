# Zone server core: process, maps, objects, player session, map login/logout (Z01)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (the four zone directories hold the same binary). Each block cites
the function it was reconstructed from (`@ FUN_xxxxxxxx`). View the original decompilation with:

```
python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone 452590
```

Names: almost every zone function stores its own name in the profiler stack on entry
(`(&DAT_007545a8)[depth] = "ShineObjectClass::ShinePlayer::sp_NC_MAP_LOGIN_REQ"`). Those strings are the
original names; `tools/protocol-re/names/zone/Z01.json` carries ~2750 of them (namespace `ShineObjectClass::`
dropped, `::` → `_`). Names marked *(ours)* are descriptive. *(inferred)* marks behaviour deduced from context.
`this->vt[0x344]` means a call through the object's vtable at byte offset 0x344 (slot 0x344/4).
Packet offsets are **payload** offsets (after the 2-byte opcode) unless written `buf+N`.

Related: [W01 world manager core](../wm/W01-core.md) (the other side of every zone↔WM message),
[`docs/knowledge/Z01.md`](../../knowledge/Z01.md) (class hierarchy, member offsets, globals),
[`../../protocol/packets-zone.md`](../../protocol/packets-zone.md).

---

## 1. Process structure

```
ZoneServer (DAT_1328baf8, "this" of the zs_* functions)
├── config          : ZoneServerInfo/ZoneServerInfo.txt (MY_SERVER "PG_W00_Z00", "_2015_Zone00", type 6, world, zone)
│                     + #INCLUDE ../9Data/ServerInfo/ServerInfo.txt ; ../9Data/ServerInfo/_ServerGroup.txt (world name "Fiesta")
│                     own row = ServerInfo(+0x538): +0x0c worldNo, +0x10 zoneNo        @ FUN_005a9920 (returns &DAT_14d45b70+0x538)
├── listeners       : client (listen type 20), zone ring (type 6), OPTool (type 8)       (ServerInfo.txt rows of this zone)
├── outgoing links  : session pools of up to 4 sessions each, 0x108 bytes per entry
│   ├── g_WMSessions      DAT_14d41a88   WorldManagerSession  (to WM, server type 5)
│   ├── g_GameDBSessions  DAT_14d454b8   GameDBSession        (to the Character DB server, type 2)
│   ├── g_GameLogSessions DAT_14d43958   GameLogSession       (to GameLog, type 3)
│   └── g_ZoneRingNext    DAT_13388e90   ZoneConnectSession   (to the next zone of the ring, §10)
├── incoming        : ClientSession[] (players), ZoneListenSession (previous zone of the ring), OPToolSession
├── g_Objects       : ShineObjectManager DAT_132826b8 – all map objects by 16-bit handle (§4)
├── g_FieldList     : FieldContainer DAT_0cfd2b70 – map instances ("fields") from World/Field.txt
├── data tables     : ~140 SHN tables + text tables (§2.3)
└── threads         : main thread (zs_mainthreadfunction), IOCP workers (2 × CPUs + 1), acceptor,
                      stack checker, certification
```

Session pools (`@ FUN_004199b0` SessionPool_Pick *(ours)*): a 4-entry round-robin; the cursor (+0x424, mask +0x428)
advances to the next entry whose state (+8) is 1 or 2 and whose "ready" byte (entry+0x108) is set; if none is found
in 4 tries the first entry is returned. `@ FUN_00468550` SessionPool_MarkReady *(ours)* sets that byte when the peer
acknowledged the handshake (0x0803).

Server time: `DAT_14d41a70` is the millisecond clock every timer compares with ("now" below). It starts when the
WM first sends the time (§9, 0x0821).

---

## 2. Startup

### 2.1 Entry and the downloaded start script

```pseudo
zs_start(server):                                        @ FUN_005a9d90  ("ZoneServer::zs_start")
    server.running = 1
    read "ZoneServerInfo/ZoneServerInfo.txt", else "../9Data/ServerInfo/ZoneServerInfo.txt"
        else FATAL "ZoneServer::zs_start : Fail to read ZoneServerInfo.txt"
    parse rows → server+0x538 (own SERVER_INFO), else FATAL "Fail Serverinfo"   @ FUN_0064d130
    ShineObjectManager.som_Initialize()                    @ FUN_0055c260 (object pools, §4)
    FUN_0045fc80(0xaf0d598)
    putenv("LUA_PATH=<old>;../9Data/Shine/LuaScript/?.lua")
    zs_start_old(server)                                   @ FUN_005b0f60 (below)
    if Lua_CallGlobal("tmfpemfjs"):                         @ FUN_005d7bc0  (Korean keyboard spelling of "스레드런", thread run)
        wait while server.running; set server.stopped = 1
    else log "ZoneServer::zs_start_old : function call error"

zs_start_old(server):                                    @ FUN_005b0f60
    truncate Message.txt and MapLoad.txt          # Message.txt receives a line before every load step below
    if !FetchStartScript(server, "127.0.0.1", 58492):      @ FUN_005b07a0 *(ours)*
        FetchStartScript(server, "cert1.fo.gamigo", 80)

FetchStartScript(server, host, port):                    @ FUN_005b07a0
    loop:
        request a script from host:port (FUN_00613440, request carries world/zone numbers)   # certification server
        answer = "[a][b]<encrypted text>" ; sscanf "[%d][%d]"
        require 1 ≤ a ≤ 0x2760 and b < 11
        keys = registry HKLM\SOFTWARE\GBO values "Natural" and "Desert" (two int64, "%I64d")
        decrypt answer with the keys (FUN_00613750 / FUN_00613950)
        Lua.dostring(answer) else log "ZoneServer::zs_start_old : Script error"     @ FUN_005d6d40
        wipe the script text from memory
        Lua_CallGlobal("chrlghk")          # "초기화", initialize
        return ok
        (on failure: Sleep(1000), retry once, then give up: "Fly")
```

The **order** in which the start stages run is decided by that downloaded script, which is not in the binary
or in `Files/Server/2016/`. The binary only registers the stages as Lua globals (§2.2). A rebuilt server must call them
in a sensible order itself: services first (IOCP, acceptor, threads), data before NPCs and fields, "open" last
(it prints "Load end"). *(inferred)*

### 2.2 Lua globals registered for the start script

`@ FUN_005d7ca0` registers C functions with `lua_pushcclosure` (FUN_005f82d0) + `lua_setglobal` (FUN_005f8820):

| Lua name | Function | What it does |
|---|---|---|
| `vmflsxm` ("print") | FUN_005d5c70 | append "Script : %s" to Message.txt |
| `fpwltmxmcheck` ("registry check") | FUN_005d5ce0 | read HKLM\SOFTWARE\<arg1> value <arg2>, return the string |
| `dhsmfskfWk` ("today's date") | FUN_005d5e10 | push 5 date fields from DAT_00aa43b8 |
| `zs_service_multisocket` | FUN_00570b00 | |
| `zs_service_acceptor` | LAB_005aa7c0 | open the listeners (FUN_005a9c60), else FATAL "ZoneServer::zs_servicestart : Acceptor fail" |
| `zs_service_mainthread` | LAB_005ad780 | start `zs_mainthreadfunction`, wait until it reports running ("MainThread fail") |
| `zs_service_iocp` | FUN_005aa800 | IOCP with 2 × CPUs + 1 worker threads |
| `zs_service_stackchecker` | LAB_005ab800 | start thread FUN_005a9f10 ("StackCheck fail") |
| `zs_service_certification` | LAB_005ac9b0 | start thread FUN_005ab9c0 ("Certification fail") |
| `zs_start_black` | LAB_005ad910 | FUN_005aa080("Assert"); build the 6 packet-handler tables (OPTool, ZoneListen, GameDB, GameLog, ShinePlayer, WM: `pft_Store` constructors FUN_004d55c0 / 4d5ee0 / 4d37e0 / 4d5520 / 4d4510 / 4d5670) |
| `zs_start_earth` | LAB_005ad970 | set the data root "../9Data/Shine/" (FUN_005c74d0); PineScript (FUN_00509750) |
| `zs_start_wide` | LAB_005ad9a0 | BMP, **Field.txt (map instances)**, skills, passives, upgrade, merchant city, gather/recipe, item use effect, KQ reward |
| `zs_start_home` | LAB_005adce0 | DamageBySoul, mob resist, **MobInfo & co.**, MobChat, map clusters, town portal, item options, rewards, drop locations, **MapInfo**, **ItemInfo & co.**, drop tables, recall coords, item groups, abstates, random options, sublayer interact, damage by angle, UseClassTypeInfo, FieldLvCondition |
| `zs_start_moon` | LAB_005ae250 | item shop, ItemServerEquipTypeInfo, **ring next IP** (`zipc_SetNextIP`, FUN_005a9850 with own zone number), character titles, announce data, class names, ItemUpgrade |
| `zs_start_star` | LAB_005adfa0 | mini-house furniture effect, mini-house endure, dice game tables, ItemMix |
| `zs_start_yellow` | LAB_005ae4e0 | FUN_004824d0; World/Script; requires the script block "DeamonDead" ("ZoneServer_zs_start_yellow : DeamonDead needed") |
| `zs_start_sky` | FUN_005ae560 | log "Player Buffer size : 1500" |
| `zs_start_long` | LAB_005b8c00 | spammer penalty, abstate-in-field, map buff, boss content, slot machines (GBSM*), LC reward, movers |
| `zs_start_house` | LAB_005b64e0 | ShineCommonParameter, CharClass (ChrCommon.txt), NPCManager.nm_Load (NPC.txt), guild tournament tables |
| `zs_start_open` | LAB_005b6640 | EnchantSocketRate; 2 recurring events (300 s and 10 s, "ZoneServer::zs_Init : EventReserve error"); NPCManager.nm_SetNPC (spawn NPCs); `fieldlist.l_4AllInList`; "Load end" |
| `zs_start_sink` | LAB_005aeff0 | ItemDismantle, **QuestData** (≤ 3000 quests), QuestParser.txt, quest buffers for all 1500 player slots |
| `zs_start_sleep` | LAB_005b67c0 | MobDataBox link, WeaponTitleData, NPCAction.txt, item actions, view info, map link/way points, gamble, NpcSchedule, ReactionType, AdminLvSet, set effects, JobEquipInfo, **client-checked View SHN checksums** (§5.2), and the "SHN - …" list |
| `zs_start_tough` | LAB_005b0540 | ItemUseFunction.txt, treasure rewards, mob attack sequences, ChargedEffect, MiniHouse(+Furniture), mini-house object animation, KQ regen, AI and pet Lua scripts |
| `zs_start_full` | LAB_005b6580 | AccUpGrade, DamageLvGap (PVE/EVP/PVP), BelongDice, MysteryVaultServer, MultiHitType |
| `zs_start_sun` | LAB_005adbd0 | Riding, ride/summon item use, mob roaming, MiscDataTable |
| `ekfflrlthreh` ("달리기속도", run speed) | FUN_005ad890 | g_runFactor `_DAT_0da50470 = round(arg)` (default 5) |
| `rjerlthreh` ("걷기속도", walk speed) | FUN_005ad8d0 | g_walkFactor `_DAT_0da50474 = round(arg)` (default 10) |

A failed load ends the process through FUN_0063c7c0("ZoneServer::ZoneServer_zs_start_<stage>") after logging
"Fail to read X.shn".

### 2.3 Data tables and their loaders

All paths are relative to `../9Data/Shine/`. `World/%s/…` means a per-world override is tried first.

| Table | Loader | Stage |
|---|---|---|
| AbState.shn, AbStateSaveTypeInfo.shn | FUN_00416e80 (AbstateDic) | home |
| SubAbState.shn, ../9Data/SubAbStateClass.txt | FUN_00416bd0 (SubAbstateDic) | home |
| ActiveSkill, ActiveSkillInfoServer, ActiveSkillGroup, ToggleSkill, AreaSkill | FUN_00585f40 (skilldatabox) | wide |
| PassiveSkill, PSkillSetAbstate | FUN_005858d0 (passivedatabox) | wide |
| UpGradeInfo | UpgradeDataBox_udb_Load FUN_00596240 | wide |
| BMP.shn (+ BMPIndex) | FUN_00439550 (bmpdata) | wide |
| World/Field.txt | FUN_004655f0 (fieldlist) | wide |
| Gather, Produce | GatherTable_gt_Load / RecipeBook_rb_Load (FUN_0046a660 / FUN_0046a840) | wide |
| ItemUseEffect | FUN_0059cc30 | wide |
| KingdomQuestRew | FUN_0049a940 | wide |
| MobResist | FUN_00644e80 (MobRegist) | home |
| MobInfo, MobInfoServer, MobSpecies, MobWeapon, MobKillAble, MobKillAnnounce, MobKillLog, MobLifeTime, MobRegenAni, QuestSpecies, GroupAbState | FUN_00641e60 (MobDataBox) | home |
| World/MobChat.txt | FUN_004af640 | home |
| TownPortal | TownPortalData_tpd_Load FUN_0049fbc0 | home |
| ItemOptions / ShineReward / FriendPointReward | FUN_0064cbc0 / FUN_0064c830 / FUN_0064ca60 | home |
| MapInfo | FUN_0064ebf0 (MapData, global DAT_14d4f670) | home |
| ItemInfo, ItemInfoServer, ItemDropLog, ItemInvenDel, ItemMoney, ItemSort, WeaponAttrib | FUN_00649780 (ItemData, DAT_14d4fb90) | home |
| BelongTypeInfo | FUN_0064b210 | home |
| World/ItemDropGroup.txt, ItemDropTable.txt | FUN_0048fa30 | home |
| World/RecallCoord.txt | FUN_004fbf10 | home |
| RandomOption, RandomOptionCount | FUN_00494570 | home |
| World/SubLayerInteract.txt (+ SubLayerInteractLoader.txt) | FUN_0049aa10 | home |
| World/DamageByAngle.txt (mob, chr), DamageBySoul.txt | FUN_0045ca10, FUN_0045d070 | home |
| UseClassTypeInfo | FUN_00640990 | home |
| FieldLvCondition | FUN_0046a350 | home |
| ItemShop / ItemServerEquipTypeInfo | FUN_00493250 / FUN_00493140 | moon |
| CharacterTitleData, CharacterTitleStateServer, AnnounceData, ClassName, ItemUpgrade | inline | moon |
| MiniHouseFurnitureObjEffect, DiceRate, DiceGame, DiceDividind, ItemMix | inline | star |
| MiniHouseEndure | MiniHouseEndureDataBox_mhe_Load FUN_004a11e0 | star |
| World/Script/%s.txt (+ "DeamonDead") | FUN_0064cd30 | yellow |
| SpamerPenalty, SpamerPenaltyRule | FUN_005897f0 | long |
| StateField (abstate in field), MapBuff | FieldContainer_fc_AbstateInFieldLoad FUN_00464950, MapBuffDataBox_mbdb_Load FUN_004670b0 | long |
| GBSMAll, GBSMCenter, GBSMGroup, GBSMLine / GBSMBetCoin, GBSMCardRate, GBSMNPC / GBSMJPRate | FUN_006239b0 / FUN_00624820 / FUN_00624270 | long |
| LCGroupRate, LCReward | FUN_0049d420 | long |
| MoverMain, MoverAbility, MoverHG, MoverItem, MoverUseSkill | FUN_004bf960 | long |
| World/ChrCommon.txt | CharClassManager_ccm_Load | house |
| World/NPC.txt | NPCManager_nm_Load FUN_004c58c0 | house |
| GuildTournamentScore/LvGap/Occupy/Skill/MasterBuff, GTIGetRate, GTIGetRateGap, GTIServer, GTIBreedSubject, GTWinScore | FUN_005b42b0 … FUN_005b4df0 | house |
| EnchantSocketRate | FUN_005b56c0 | open |
| ItemDismantle, QuestData, World/QuestParser.txt | inline, FUN_00636f30, FUN_00639c90 | sink |
| WeaponTitleData | FUN_006358c0 | sleep |
| World/NPCAction.txt (conditions, actions) | FUN_005b5800, FUN_005b58e0, trigger dictionary FUN_005c4420 | sleep |
| ActionRangeFactor, ItemActionCondition, ItemActionEffect, ItemAction | FUN_005b59c0 … FUN_005b5d80 | sleep |
| ActionViewInfo, MapLinkPoint, MapWayPoint, GBHouse, GBExchangeMaxCoin, GBJoinGameMember, GBDiceDividind, GBDiceGame, GBDiceRate, NpcSchedule, ReactionType, AdminLvSet, JobEquipInfo, SingleData, MarketSearchInfo, BadNameFilter | inline | sleep |
| SetEffect, ActionEffectItem, ActionEffectAbState | FUN_005b… (named after the file) | sleep |
| View/AbStateView, ActiveSkillView, CharacterTitleStateView, EffectViewInfo, ItemShopView, ItemViewInfo, MapViewInfo, MobViewInfo, NPCViewInfo, PassiveSkillView, ProduceView, CollectCardView, GTIView, ItemViewEquipTypeInfo | checksum only, FUN_006311a0 into g_ShnChecksums (§5.2) | sleep |
| MobConditionServer, MoverUpgradeEffect + RareMover{Rate,EachRate,SubRate}, PupMain/Server/Mind/Priority/Case/CaseDesc/FactorCondition, StateItem, ChatColor, TermExtendMatch, MinimonInfo, MinimonAutoUseItem, ChargedDeletableBuff, KQItem, BRAccUpGrade, BRAccUpgradeInfo | FUN_004b0460, FUN_004c0660, FUN_004cf870, FUN_0058c920, FUN_0044fe70, FUN_0064c090, FUN_004a27f0, FUN_004a2b80, FUN_0044fe80, FUN_0064bd80, FUN_0043bb00 | sleep |
| World/ItemUseFunction.txt, World/TreasureReward.txt, MobAttackSequence/%s.txt | FUN_0049b770, FUN_0049c7f0, FUN_004a8990 | tough |
| ChargedEffect, MiniHouse, MiniHouseFurniture, MiniHouseObjAni | FUN_005af300, FUN_005af4d0, FUN_005af6d0, FUN_004a1970 | tough |
| MobRegen/KingdomQuest/%s.txt, MobRegen/Instant/%s.txt | FUN_004b3220 → FUN_004b26b0 | tough |
| LuaScript/AIScript/%s.lua, LuaScript/PetSystem/%s.lua | FUN_006264b0, FUN_00626630 | tough |
| AccUpGrade, DamageLvGapPVE/EVP/PVP, BelongDice, MysteryVaultServer, MultiHitType | FUN_005b4f40 … FUN_005b5580, FUN_004c0ff0 | full |
| Riding, World/MiscDataTable.txt, mob roaming (World/PineScript.txt, MobRoam/%s.txt) | FUN_00450270, FUN_004a82d0, FUN_004b8690 | sun |
| World/%s/MobRegen/%s.txt, MobRoam/%s.txt, NPCItemList/%s.txt, World/%s.txt | FUN_004b6330, FUN_004b8320, FUN_004c5130, FUN_0044a3d0 | per map (field/NPC load) |

SHN files are decoded by FUN_0062a780 / FUN_0062a9e0 (same cipher as `tools/protocol-re/shn.py`); the two
numbers passed to the inline loaders (e.g. `ItemDismantle.shn, 0x253a, 0x66`) are the expected record count
bound and record size *(inferred)*.

---

## 3. Network layer

### 3.1 Packet buffer and send primitives

```pseudo
g_buf = PTR_DAT_0084d908      # one global send buffer: opcode at +0, payload at +2

pp_SetPacketLen(&g_buf, n):                              @ FUN_004c8ce0 ("ProtocolPacket::pp_SetPacketLen")
    if n ≥ capacity: return false        # caller logs "<handler> : Packet Too Long" and drops the packet
    g_buf.len = n; return true

pp_SendPacket(&g_buf, session):                          @ FUN_004c89c0 ("ProtocolPacket::pp_SendPacket")
    if len ≥ 0x1ffd: log "Too long buffer"; return
    frame = len < 0x100 ? [u8 len] : [0, u16 len]       # same framing as Login/WM (protocol README)
    session.Send(frame + g_buf[0:len])                  @ FUN_005a66b0

Send to the player itself:   player.vt[0x2f8]() → send object (player+0x7e2c), .vt[0xc](player, &g_buf)
                             player.vt[0x2fc]() → second send object (player+0x7e28), same call
                             # both end in the player's client session; +0x7e28 is swapped to PTR_vftable_00865fb8
                             # during a same-zone map change (§7.1). Which packets use which is not significant
                             # for the protocol. (inferred)
Send to the WM:              pp_SendPacket(&g_buf, SessionPool_Pick(g_WMSessions))
Send to the Character DB:    pp_SendPacket(&g_buf, SessionPool_Pick(g_GameDBSessions))
Send to GameLog:             pp_SendPacket(&g_buf, SessionPool_Pick(g_GameLogSessions))
Send into the zone ring:     zcs_Send(&g_buf, n)                        @ FUN_005a6ed0 (§10)

Result code to the player:   so_SendErrorCode(dept, cmd, code)          @ FUN_0054f050 (ShinePlayer vt 0x308)
                             = send (dept<<10|cmd) { u16 code }
```

### 3.2 Broadcast (who receives a packet)

Broadcasts are visitor objects passed to the map's sight iteration:

```pseudo
AxialListPacketBroadcast(&g_buf, n):                     @ FUN_00428a40 (constructor; sets the length, 0 if too long)
so_AllInMap0..5(object, visitor, …):                     @ FUN_0054b8c0 … (call the field's iterator, field+0x58 …)
    for each object in the cells around `object` (sight range of the field): visitor.ali_Work(sender, receiver)

AxialListPacketBroadcast.ali_Work(sender, receiver):     @ FUN_00428b20
    skip unless receiver is a player (type 2) and receiver.mode ≠ 0       # mode: §4.3
    skip unless same layer: *(sender+0x76) == *(receiver+0x76) or either is -1   (sub-layer / instance id, inferred)
    skip unless in sight: FUN_0049ac70(sender, receiver)
    skip if receiver is closing (vt 0x300)
    if receiver has "hide except me" on (vt 0x79c):
        deliver only if sender == receiver, or sender is a mover (type 11) whose owner charNo == receiver.charNo
    receiver.send(&g_buf)
```

`CalculateBroadcastDistance_cbd_DistanceSquar` (FUN_…) computes the squared sight distance used by the
"exchange brief info" passes after login and teleports. Other visitors in the RTTI list
(`AxialListPacketBroadcastByGuild`, `AxialListNearExecution_Party` / `_MyRaid` / `_MyGuild` …) select party,
raid or guild members in range; party-wide sends outside sight go through the WM. Example (logout of any object):

```pseudo
so_LogoutPacketBroadcast(obj):                           @ FUN_00553a40
    broadcast to sight: 0x1805 { u16 objHandle }          # client GameFrameWork FUN_004bd620 removes the object
```

### 3.3 Server-to-server handshake and heartbeat

Each outgoing link (WM, GameDB, GameLog) is opened by the zone; the peer sends `0x0801 NC_MISC_S2SCONNECTION_RDY`:

```pseudo
0x0801 S2SCONNECTION_RDY (WM / GameDB / GameLog):        @ FUN_005a3210 / FUN_00468770 / FUN_0046a080
    reply 0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo (not set), u8 server_id_to, u8 server_id_from = 6,
                                             u8 worldNo, u8 zoneNo, u16 key = to + from }
        to = 5 (WM), 2 (GameDB = Character server), 3 (GameLog)
    # the WM checks it (W01 §7.1) and answers 0x0803

0x0803 from the WM:                                      @ FUN_005a3320
    SessionPool_MarkReady(g_WMSessions, s)
    FieldContainer.fc_MapRegist(s):   0x180F { u16 n, n × 14-byte map entry }           @ FUN_00463a70 / FUN_00461cf0
    FieldContainer.fc_IndunMapRegist(s): 0xA419 { u16 n, n × { char map[12], u8 } }   @ FUN_00462af0  (instance maps)
    CGuildZone.Send_NC_GUILD_ZONE_LIST_REQ()                                           (Z08)
0x0803 from GameDB:  SessionPool_MarkReady(g_GameDBSessions, s); FUN_00626220(&DAT_14d712a8)   @ LAB_00468880
0x0803 from GameLog: SessionPool_MarkReady(g_GameLogSessions, s)                             @ LAB_0046a190

0x0804 HEARTBEAT_REQ (WM, GameDB, GameLog, ZoneListen, OPTool):  reply 0x0805   @ FUN_005a3360 / FUN_004688a0 / FUN_0046a1a0 / FUN_0045b3f0 / FUN_004c81d0
0x0805 HEARTBEAT_ACK: no-op                              @ FUN_00509900 / FUN_00549070
0x0804 / 0x0805 from a client: no-op                     @ FUN_004c2450   (the client answers the zone's 0x0804, C01 §1)
```

OPTool (incoming, `OPToolSession`):

```pseudo
0x0802 S2SCONNECTION_REQ { u8 echo, u8 to, u8 from, … }:  @ FUN_004c8070
    reply 0x0803 { u8 echo, u16 err = (to == 6 and from == 8) ? 0 : 1 }
0x0803: no-op                                            @ LAB_004c8180
0x2807 NC_OPTOOL_CONNECT_BRIF_REQ { u8 echo }:           @ FUN_004c82b0
    reply 0x2808 { u8 echo, u8 6 (zone), per server type t: u16 count at payload 2 + 8t   # 1 per connected GameDB, GameLog, WM link
                   …, u16 DAT_0da3d2cc @+0x42, u16 playerCount (g_Objects player list +0x14) @+0xa2 }   (0xaa bytes)
```

---

## 4. Objects

### 4.1 Class hierarchy (RTTI)

```
ShineObject (type 0xff)
├── ShineAxialFlag (0)   ShineDropItem (1)   ShineMiniHouse (3)   ShineMagicField (6)   ShineEffectObject (9)
└── ShineMobileObject (0xff)
    ├── ShinePlayer (2)   ShineDoor (7)   ShineMover (11)
    └── ShineMob (5)
        ├── ShineNPC (4)   ShineBandit (8)   ShineServant (10)   ShinePet (12)
```

The number is the object type returned by `vt[0x4d0]`. Details, vtable sizes and member offsets:
[`docs/knowledge/Z01.md`](../../knowledge/Z01.md).

### 4.2 ShineObjectManager and handles

```pseudo
som_Initialize():                                        @ FUN_0055c260
    one fixed pool per object type (constructed in place, "__LARGEOBJECTBUFFER Needed" if allocation fails)

ObjectHandle_Decode(handle) → (type, index):             @ FUN_00633650 *(ours)*
    handle range        type   pool size  object size
    0     ..  7999       5 mob        8000   0x2568
    8000  ..  9499       2 player     1500   0x2c058
    9500  .. 10499       3 mini-house 1000   0xd100
    10500 .. 13499       1 drop item  3000   0x28b
    13500 .. 17083       0 axial flag 3584   0x188
    17084 .. 17339       4 NPC         256   0x256c
    17340 .. 19387       8 bandit     2048   0x266c
    19388 .. 20387       9 effect     1000   0x1d3
    20388 .. 20637       6 magic field 250   0x1c8
    20638 .. 21637       7 door       1000   0x1f14
    21638 .. 22137      10 servant     500   0x2598
    22138 .. 23137      11 mover      1000   0x202c
    23638 .. 25137      12 pet        1500   0x25d4
    anything else: invalid (0xffff)
    # the pool type equals the object type code, so a handle tells the client what kind of object it is

som_GetObject(handle):  pool[type][index] if that slot is in use, else null      @ FUN_0054fd10
som_FreeObject(handle, arg, reason):                     @ FUN_00557d70
    if arg == 1: return true                              # "deferred": the caller only marks the object
    obj.vt[0x2c](); obj.vt[0x2f0](…); pool[type].Free(index)
    unknown handle: log "ShineObjectList::som_FreeObject : Try to free unalloced object"
som_FindPlayer by name / by charNo:                      @ FUN_00550430 / FUN_00550360
```

### 4.3 Player mode

Every player has a mode byte (`*(player+0xe9c)`, read by `vt[0x484]`). Handlers test it with a bit mask
(`mask & (1 << mode)`), built once in a static:

| Mask | Modes | Used by |
|---|---|---|
| 0x01 | 0 | 0x0806 seed, 0x1801 map login |
| 0x46 | 1, 2, 6 | 0x1814, 0x1816, 0x181A, 0x181F, 0xB410, map link (so_LinkTo) |
| 0x7E | 1–6 | 0x0C18 logout, 0x0817, 0x0818 |

Known values: 0 = not on a map (logging in, linking out, or moving to the normal location); 1 = in game (set by
0x1803); 3 = rejected by the link reserve answer ("Link Fail Player Die", together with HP 0) *(inferred: dead)*;
4 = a state left through `vt[0x488]` before a link *(not identified)*. Packets are broadcast only to players with
mode ≠ 0.

---

## 5. Map login

Sequence (first login and every map change that crosses zones):

```
client → zone  0x0806 SEED_REQ            → 0x0807 SEED_ACK { u16 seed }
client → zone  0x1801 MAP_LOGIN_REQ       → zone → WM 0x104B REGISTNUMBER_REQ
WM → zone      0x104C REGISTNUMBER_ACK    → zone → WM 0x101C CHAR_ZONE_CHARDATA_REQ
WM → zone      0x101F … 0x1130 (character blobs, Z07)  then 0x101D CHAR_ZONE_CHARDATA_ACK
zone → client  0x1802 MAP_LOGIN_ACK (or 0x1804 on failure)
client → zone  0x1803 MAP_LOGINCOMPLETE_CMD → zone → WM 0x180C, client: login burst (§6)
```

### 5.1 Seed

```pseudo
0x0806 NC_MISC_SEED_REQ:                                 @ FUN_00451a30
    if player.mode != 0: ignore
    g_seedCounter = (g_seedCounter + 1), wrapped to 0 at 499 (DAT_00707fd8)
    send 0x0807 NC_MISC_SEED_ACK { u16 seed = g_seedCounter }
    # client: Net.SetSeed(seed) → XOR-499 start index for client→zone packets (C01, protocol README)
```

The seed is a global counter, not random: consecutive connections get consecutive seeds.

### 5.2 0x1801 NC_MAP_LOGIN_REQ

Payload `{ u16 wmHandle, char charName[20], u8 shnChecksum[49][32] }` (0x636 bytes, client FUN_004779d0).

```pseudo
0x1801 NC_MAP_LOGIN_REQ(s, p):                           @ FUN_00452590
    idx = ShnChecksum_FindMismatch(g_ShnChecksums, p.shnChecksum)    @ FUN_00631350
          # g_ShnChecksums DAT_14d713e8: 49 entries × 0x41 bytes { …, +5 char md5hex[32], +0x25 name[32] }
          # filled at startup from the View/*.shn and other client-side tables (zs_start_sleep, FUN_006311a0)
    if idx < 49:                                          # the client's copy of table idx differs
        log "sp_NC_MAP_LOGIN_REQ : DataFail [CharID=%s]" (+ the table name and both hashes)
        send 0x1804 { u16 0x147, u8 idx }
        so_Disconnect(0x68E)                              # §8.3
        return
    if player.mode != 0: log "sp_NC_MAP_LOGIN_REQ : Invalid Mode [CharID=%s]"; return
    send WM 0x104B NC_CHAR_REGISTNUMBER_REQ {
        u16 handle  = the session's handle (3rd handler argument)     # ref[0..1]
        u32 -1                                                        # ref[2..5]
        u16 wmHandle = p.wmHandle
        char charName[20] = p.charName }                              (0x1c bytes)
    reset 4 player containers (+0x7fd8, +0x8e2c, +0xe530, +0xe778) and +0xf758
    player.requestedName (+0x2ab49) = p.charName
    FUN_0050eb10(player+0x2ac38)
```

Client cross-check (`ZoneLoginNetFrameWork` FUN_004778c0, `LinkFrameWork` FUN_00626140): `0x1804` with code
0x147 marks the client's checksum entry `idx` as bad and shows "The client has been illegally manipulated.
Please reinstall the client." (first login) or "Failed to move to another map." (map change). Any other code
leaves the scene without a message.

### 5.3 WM answers

```pseudo
WM 0x104C NC_CHAR_REGISTNUMBER_ACK { ref[6], u32 userNo, u32 charNo, u16 wmHandle, char charName[20] }:   @ FUN_0044aa60
    p = g_Objects.GetObject(ref.handle); if p == null or p is closing: log "Invalid Player [CharID=%s]"; return
    so_SetRegistNumber(p, payload+6):                     @ FUN_0044e900
        if charName != p.requestedName:
            log "so_SetRegistNumber : CharID Not Match [%s/%s]"; so_Disconnect(0x689); return
        if userNo == -1 or charNo == -1:                  # the WM refused (no map-login ticket, W01 §7.2)
            log "so_SetRegistNumber : Invalid Regnum [CharID=%s]"; so_Disconnect(0x689); return
        FUN_00560730(p)
        p.userNo (+0x7f39) = userNo; p.charNo (+0x7f3d) = charNo; p.wmHandle (+0x2931c) = wmHandle
        send WM 0x101C NC_CHAR_ZONE_CHARDATA_REQ { u16 p.handle, u32 charNo, u16 wmHandle, char charName[20] }
        reset per-login state (FUN_0044e8c0, vt 0xc78(0), vt 0xc80(10), vt 0xc8c, quest containers +0x7fd8)
        p+0x2a9c8 = 0x318; tutorial object (vt 0x5d0) → FUN_005d19b0

WM 0x101F … 0x1130: character blobs (base, shape, quests, skills, items, …) → Z07 (table in W01 §6.3)

WM 0x101E NC_CHAR_ZONE_CHARDATAFAIL_ACK { ref[6], … }:   @ FUN_005a3440
    p = GetObject(ref.handle); if null or closing: log "Invalid ClientHandle [%d]"; return
    send 0x1804 { u16 = payload u16 at +0 (the ref handle!), u8 0xFF }
    # the code sent is the player's own handle, not the WM's error (0x141 / 0x590); looks like an original bug.
    # The client then just leaves the zone-login scene (no message).

WM 0x101D NC_CHAR_ZONE_CHARDATA_ACK { ref[6], u16 wmHandle }:   @ FUN_005a3590   (end of the blobs)
    p = GetObject(ref.handle); if null or closing: log "Invalid Object"; return
    p.vt[0x4b4](wmHandle, …)                              # build the character from the blobs: equipment brief, flags  @ FUN_0055ab60
    tutorial = p.vt[0xdfc]()                              # +0x2ab44; null → log "TutorialInfo Is Null - CharNo : "
    if tutorial.state == 0 (tutorial not finished) and p.vt[0xdf4]() finds no free tutorial map:
        log "Not Find Empty TutorialMap"; send 0x1804 { u16 0x31EC, u8 0xFF }
    if so_MapMarking(p) fails:                            # place the player on the field at the saved position
        so_Unmark(0, 1, 3); if so_MapMarkingAtDefaultCoord(p) also fails:
            send 0x1804 { u16 0x142, u8 0xFF }; so_ply_ToNormalLoc(2) (§7.5); return
    p.vt[0x4c0]()                                         # snapshot position + direction into +0x7f8b
    so_allparametercalculate(p)                           @ FUN_0054f190 (stats, Z07)
    send 0x1802 NC_MAP_LOGIN_ACK (242 bytes):             @ FUN_005a3140 so_fill_PROTO_NC_CHAR_MAPLOGIN_ACK
        { u16 objHandle, CHAR_PARAMETER_DATA (so_fill_CHAR_PARAMETER_DATA FUN_005a2e00, Z07), u32 x @+0xe8, u32 y @+0xec }
```

Client: `0x1802` stores map/position, sends `0x7004`, `0x700C`, `0x7C06` and enters the game scene; the
link scene rebuilds the world and enters the game (C01). Then the client sends `0x1803`.

---

## 6. 0x1803 NC_MAP_LOGINCOMPLETE_CMD (login burst)

`@ FUN_00443390` (750 decompiled lines). Order of the main steps; feature details belong to the items named.

```pseudo
0x1803 NC_MAP_LOGINCOMPLETE_CMD(p):
    so_allparametercalculate(p); p.vt[0xae4](); card collection: ShinePlayer.sp_CardCollectionSend   (Z07)
    if p.mode != 0: goto end                              # mask 0x01
    level = p.vt[0x4d8]()
    *(p.direction) = 0x5a; NormalAttackDamageTick.Clear
    sp_RegistNumberVarification(p)                         # sends 0x10B3 NC_CHAR_REGNUM_VARIFICATION_REQ (Z07)
    if level == 0 or level > 150: so_Disconnect(); goto end
    if the player has no field (+0x7a): log "sp_NC_MAP_LOGINCOMPLETE_CMD Field"; goto end
    reset combat/target state; party block (+0x7e34) init from the class data (FUN_0043c1e0 / FUN_0043c180)
    p.mode = 1                                            # *** now in game ***
    abstate 0x120 (KQ map?) / 0x121 (guild tournament) handling; GT system join (FUN_0047fd10)
    re-apply / drop abstates that are not allowed on this map
    p.vt[0x638](p, 0x123, 1, …); FUN_00401a00(p, 0x123)  # login protection abstate 0x123 (inferred)
    sight: CalculateBroadcastDistance; so_AllInMap0(p, so_ExchageBriefInfo)   # everyone in sight ↔ p (Z02)
    AbstateListInObject.asl_SendAfterLogin                 (Z03)
    timers: +0xe9c.., +0x5f60 …, save timer (+0xa58b = now)
    send WM 0x180C (map login done) {                     # 0x2f bytes
        u16 wmHandle, u16 objHandle, u32 charNo, char map[12], u8 zoneNo, u32 x, u32 y,
        u8 99, u64 exp (vt 0x438), u64 money (vt 0x434), u8 inGuildTournament (FUN_00475830) }
        # WM: W01 §7.3 (sets zoneNo, refreshes party/guild/friends, sends client 0x182A)
    party (vt 0x554 raid == -1, vt 0x550 party ≠ -1): find party DAT_0da50bdc[partyNo]; fill this member's
        slot { charNo, objHandle, wmHandle, name, level, zoneNo } and notify the other members  (Z08)
        else log "sp_NC_MAP_LOGINCOMPLETE_CMD : Party not found"
    weapon speed / range, KQ items removed (sp_RemoveKQItem 8, 9), expired items (sp_ItemInvenDelete)
    next experience-save point (sp_NextSaveExperience)
    send 0x203E { u16 walkSpeed (vt 0x514), u16 runSpeed (vt 0x518) }    # opcode stored at p+0x29620 by the player ctor FUN_0055bc80
        # walkSpeed = base × g_walkFactor / 1000, runSpeed = base × g_runFactor / 1000; base = p+0x1c00, or the
        # mode-6 values (+0x2a76e / +0x2a770, riding, inferred). Factors: `rjerlthreh` / `ekfflrlthreh` from the
        # start script, defaults 10 / 5 (zs_start_long). Client: GameFrameWork FUN_00499e90 (2 reads)
    mini-house (sp_MakeMiniHouse, mhs_Init), sp_LoginInit, KQ / instance escape (sp_EscapeFromEmptyKQ / …ID),
    sp_2Roumen (send to Roumen if the GT map does not accept the player)
    if partyNo ≠ -1: send WM 0x384E { u16 partyNo }
    sp_ConnectFromWhere(p)                                 # WM 0x082A … (W01 §7.6) → answer 0x082B (§9)
    send GameDB 0x1080 { u16 objHandle, u32 charNo }       # wedding info (Z08)
    sp_GhostBan; sp_KeepFromDoubleLogin
    KQ contribution (KQContributeList.kqcl_SendMobKill)
    title / abstate effects of the class (CharacterTitleStateServer)
    if the map belongs to a map cluster with a time limit (MapCluster.mc_GetLimitTime):
        send 0x0810 { u8 1, u16 minutes = limit / 10 }
    if prison minutes (+0x7f9f) ≠ 0: send 0x7C05 { u16 0x0DA9, u32 seconds = minutes × 60 }   (W04 prison)
    if +0x7fa1 ≠ 0: send 0x10C6 { u8 +0x7fa1 }
    charged item effects (sp_ChargedEffectAfterLoginComplete), FUN_00566420, sp_RemoveField
    send 0x10D4 { u8 +0x2aa44 }
    … pets, minimon, mover, quests, tutorial, gamble (vt 0xbdc … 0xe80, Z07/Z08)
    if field.type (+0x214) < 3: send 0x182C { u32 field.type }
    map scenario hook (FUN_004645c0)
    send GameDB 0x34CF NC_ITEMDB_MAPLINK_ITEM_COMPARE_MAP_REQ { u32 charNo }   (Z05)
    field script "player login" event (FUN_005d7310 + FUN_00463ae0(field, 4, …))
end:
```

Client handlers of the burst packets: `0x0810` GameFrameWork FUN_004997a0 `{u8, u16}`; `0x10D4` FUN_004b33b0;
`0x182C` FUN_0054bb10 (hero text); `0x7C05` FUN_0049b1b0 `{u16, u32}`; `0x10C6` handled without payload reads.

---

## 7. Moving between maps

### 7.1 so_LinkTo (gate, NPC, script, skill teleport)

`so_LinkTo(link, replyDept, replyCmd)` is the common path. `link` is a 0x61-byte link record (MapLinkPoint
style): `+0x14 char destMap[12]`, `+0x35 char destMapForClient[12]` (index into MapInfo), `+0x56 u32 x`,
`+0x5a u32 y`.

```pseudo
so_LinkTo(p, link, dept, cmd):                           @ FUN_0049ad30
    if a pending link reservation exists (FUN_00570b70, state 1): link = reservation; clear it
    if p.mode == 4: p.vt[0x488]()
    if p.mode not in {1, 2, 6}: return
    if p has a trade partner (+0x17d5f):
        if p's field is of kind 3 (+0xc → +0x36): close the trade for both (code 0x13/0xb, 0x13/0xc); p.vt[0x3fc](link) (retry)
        return
    if items are locked (+0xfaa8 .vt[0x10]): log "so_LinkTo : Link during item operation"; return
    destZone = g_ServerGroup.ZoneOfMap(worldName, link.destMap)          @ FUN_0063e200 (DAT_0cfd2b88)
    if destZone == -1: log "so_LinkTo : machine number"; return
    if destZone == 99: destZone = myZone
    send WM 0x180B { u16 wmHandle, u32 charNo }           # "leaving for a link" (W01: s.linking = 1)
    remember mount/pet for re-summon on the other side (+0x2aad4..), unsummon (FUN_0045d910)
    if p+0x2ab60 in {5, 6}: keep a key (+0x2aba8..) to restore that state after the link   (inferred)
    if destZone == myZone:                                # same zone: no reconnect
        so_Unmark(p, mode = (cmd == 0x4f) ? 3 : 0, 1)
        if p.savedMap (+0x7f7f) != link.destMap: p.vt[0xafc](old map …)   # leave-map hook
        p.savedMap = link.destMap; p.pos = (link.x, link.y); p.vt[0x4c0](); p.mode = 0
        if so_MapMarking(p) fails:
            so_Disconnect(0x685); restore the old field, map and position; return
        send (dept<<10 | cmd) { u16 mapIndex(link.destMapForClient), u32 x, u32 y }
            # callers pass (6, 9, 10) → 0x1809 (client GameFrameWork FUN_0049feb0 copies the 10 bytes and starts the
            # map change); FUN_00451bd0 passes (4, 0x4f, 0x50) → 0x104F (revive at another map, cmd 0x4f also selects unmark mode 3)
        FUN_00448f30(p+0x17d0c, p); p+0x7e28 = PTR_vftable_00865fb8
        # the client reloads the map and sends 0x1803 again → §6 (mode 0 → 1)
    else:                                                 # other zone
        ws_save2DB(p, full = 0, reason = 2)               # §8.4
        ws_save2worldmanager(p)                           # §8.4
        p.mode = 0
        row = ServerInfo(type 6, world, destZone, listen 20)   # the client port of the destination zone
        if row found:
            send WM 0x180D (link reserve) {               # 0x3b bytes
                u16 objHandle, u32 charNo, u16 wmHandle, u8 destZone, char destMap[12], u32 x, u32 y,
                u16 mapIndex, u32 x, u32 y, char zoneIp[16], u16 zonePort, u16 wmHandle }
        p.flags (+0x5cb8) |= 2                            # "linking out"
        FUN_00448f30(p+0x17d0c, p)
        send GameLog 0xC809 { u32 userNo, u32 charNo, u8 destZone, u8 myZone, u8 level }

WM 0x180E NC_MAP_LINKRESERVE_ACK { ref[6] (objHandle, charNo), copy of the 0x180D bytes from mapIndex on }:   @ FUN_0049b510
    p = GetObject(ref.handle); require p.charNo == ref.charNo and p not closing,
        else log "wms_NC_MAP_LINKRESERVE_ACK : Invalid player"
    if p.hp (vt 0x4e8) == 0 or p.mode == 3: log "Link Fail Player Die"; return
    send 0x180A { u16 mapIndex, u32 x, u32 y, char zoneIp[16], u16 zonePort, u16 wmHandle }   (0x1e bytes)
    client session .vt[8](…)                              # flush/close after this packet (inferred)
    so_banning(p, 0)                                      # remove the player from this zone (§8.3)
    # client GameFrameWork FUN_004b4ab0: connects to zoneIp:zonePort and starts the map login again (0x0806, 0x1801)
```

### 7.2 Wing (saved locations)

```pseudo
0x1814 NC_MAP_WING_SAVE_REQ { u8 slot }:                 @ FUN_00589c80
    if mode not in {1,2,6}:                 → 0x1815 { u16 0x1146 }   "You cannot use the Wing item in current state."
    if no field, or the map forbids saving (MapInfo +0x6b == 0) → 0x1143   "Location of current map cannot be saved."
    wing = first inventory item with id DAT_14d504b0 whose attribute class is 13
    if found and slot < wing.slotCount:
        wing.slot[slot] = { u16 mapIndex, u32 x, u32 y }; sp_AttrChange2DB (item attribute save, Z05)
        so_ply_ItemUsePacket(0x700, 9); → 0x1141   "Current location has been saved."
    elif found: → 0x1144   "Selected slot does not have any saved location."
    # 0x1142 is never sent by this handler

0x1816 NC_MAP_WING_FLY_REQ { u8 slot }:                  @ FUN_00589f00
    if mode not in {1,2,6}:                 → 0x1817 { u16 0x1146 }
    if FUN_00596440(p) != 0x700:            → 0x1143   "You cannot teleport to the saved locaion in current state."
    wing missing (id DAT_14d504b0, class 13) → 0x1142 (client: no text)
    slot ≥ count or slot empty (mapIndex == -1) → 0x1144
    stone = inventory item DAT_14d504b4 (Wing Stone); missing → 0x1145   "You do not have Wind Stone."
    use the stone (UseItemNormal.uib_AfterCast); queue a teleport { handle, mapIndex, x, y } in the ring DAT_0086dc30,
        p+0x2a7a4 = queue index → 0x1141   "1 Wing Stone was consumed."
    # the teleport itself runs when the cast ends (item-use path, Z04) (inferred)
```

### 7.3 Town portal and multi-link NPC

```pseudo
0x181A NC_MAP_TOWNPORTAL_REQ { u8 index }:               @ FUN_0049fe70
    if mode not in {1,2,6}: 0x181B { u16 0x19C2 }        # client error table: "cannot use town transfer in the current state" (Korean)
    row = TownPortal[index] (TownPortal.shn: +1 u8 minLevel, +3 char map[12], +0x23 x, +0x27 y); none → 0x19C3 "invalid index"
    if not riding a mover (vt 0xc74 == null):
        level < minLevel → 0x19C4 "level too low"; else 0x19C1, so_ply_BriefLink(map, x, y)   @ FUN_00452c10 (vt 0x890)
    else (mover; only its owner may ask): every passenger (vt 0xcd8 count, 0xcdc(i)) must have level ≥ minLevel, else 0x19C4;
        0x19C1; every passenger and the owner get the mover state and BriefLink to the same place

0x181F NC_MAP_MULTY_LINK_SELECT_REQ { char map[12] }:     @ FUN_0055b430
    reply 0x1820 { u16 code } (FUN_00558e40)
    if mode not in {1,2,6} or the last clicked NPC (+0x17d7c) is gone: 0x2029
    if distance² to the NPC ≥ 1 000 001: 0x202B
    if the NPC role (MobInfo) is 0x11: 0x202C
    find the NPC's link entry whose map (+0x35) == map: ServerMenuFuncter.smfm_Link(p, entry) → 0x2028
    none: 0x202D
```

The client handler of `0x1820` (FUN_008b80a0) reads no payload; the codes have no client text.

### 7.4 0x181C NC_MAP_TONORMALCOORD_CMD and so_ply_ToNormalLoc

```pseudo
0x181C NC_MAP_TONORMALCOORD_CMD:  so_ply_ToNormalLoc(p, 1)      @ FUN_005522a0

so_ply_ToNormalLoc(p, reason):                           @ FUN_00552350 (vt 0xa24)
    m = MapInfo of the current field (FUN_0063e160)
    dest = m has its own return point (+0x36 ≠ 0) ? (m+0x6e map, m+0x7a x, m+0x7e y) : (current map, m+0x7a, m+0x7e)
    if the return map is a KQ-type map (MapInfo +0x3a == 7):
        dest = the player's previous map (+0x2aa58) with that map's default point, else ("RouN", 6445, 8630)
    send GameDB 0x4003 { u16 objHandle, u32 charNo, u32 charNo, char map[12], u32 x, u32 y, u32 -1, char[12] "", u32 0, u32 0, … }   (0x36 bytes)
    send GameLog 0x05EA { u32 charNo, char map[12], u32 x, u32 y, u32 -1, u32 curX, u32 curY, u16 9999 }
    p.mode = 0; vt[0x330](1); sp_RefreshWMSSocket(p) (0x0C31, §8.2); so_Disconnect(0x685)
    # the client reconnects and logs in at the saved town position (inferred)
```

---

## 8. Logout, kick and character save

### 8.1 Normal logout

```pseudo
0x0C18 NC_USER_NORMALLOGOUT_CMD:                         @ FUN_00558690
    if mode not in 1..6: ignore
    if p.logoutBlockedUntil (+0x2a798) < now: sp_Schedule_Logout(p)

sp_Schedule_Logout(p):                                   @ FUN_00558160
    if !p.vt[0x17c]():                                    # not ready to leave yet
        arm the player's TimeScheduler: retry sp_Schedule_Logout (ts_TimerCheck), "ShinePlayer::TimeScheduler::ts_Set - "
        return
    if !p.vt[0xb2c]():  re-arm (FUN_0042ab50(+0x2a784, 0x558160, …)); return    # pending save/operation (inferred)
    unsummon the mover/pet (FUN_0045d910)
    so_Unmark(0, 1, 9)
    send WM 0x0C31 NC_USER_POSSIBLE_NEW_CONNECT_CMD { u16 0xFFFF, u32 -1, u16 wmHandle, u32 charNo }
        # WM: playingCharNo = -1 → character select allowed again (W01 §7.3)
    som_FreeObject(p.handle, 0, 0x12) else log "sp_Schedule_Kickout : Fail to object free"
    client session state = 3 (close)
```

### 8.2 sp_RefreshWMSSocket

```pseudo
sp_RefreshWMSSocket(p):                                  @ FUN_00552190 (vt 0x338)
    if p.vt[0x334]() == 1: send WM 0x0C31 { u16 0xFFFF, u32 -1, u16 wmHandle, u32 charNo }
```

### 8.3 Disconnect and kick

```pseudo
so_Disconnect(p, reason, arg, silent):                   @ FUN_0054f340 (vt 0x5f8)
    if reason != 0x681: log "ShineObjectClass::ShinePlayer::so_Disconnect"
    if !silent:
        send WM 0x0C1A { u16 0xFFFF, u32 -1, u32 userNo, u16 wmHandle, u16 reason }   (0x0e bytes)
        # WM: W01 §5.2 (CharacterLogout with that reason)
    so_banning(p, arg)

so_banning(p, deferred):                                 @ FUN_00558b70 (vt 0x5fc)
    if p.mode != 0: p.vt[0x910](…)
    client session state = 3; p.closing (+0x2a944) = 1
    so_Unmark(deferred, 1, 4)
    som_FreeObject(p.handle, deferred, 0x10)             # deferred == 1: the slot is freed later

WM 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD { ref[6], u32 userNo }:   @ FUN_005a5f90
WM 0x0C19 NC_USER_CONNECTCUT2ZONE_CMD  { ref[6], u32 userNo }:   @ FUN_005a6040
    wms_kickoff(userNo):                                  @ FUN_005a3860
        find the player with that userNo in the player list; so_banning(p, 1)
```

Disconnect reasons seen in this item (internal codes sent to the WM in `0x0C1A`; none has a client text):

| Reason | Where |
|---|---|
| 0x0685 | map marking failed after a same-zone link; so_ply_ToNormalLoc |
| 0x0686 | seed request without packet encryption ("No PacketEncrypt") |
| 0x0689 | 0x104C name mismatch or userNo/charNo −1 |
| 0x068B | kicked by a GM through the zone ring (§10) |
| 0x068E | SHN checksum mismatch in 0x1801 |

### 8.4 Character save (WholeSaver)

```pseudo
ws_save2DB(saver, p, partial, reason):                   @ FUN_00455a10  (to the Character DB)
    if p.mode == 0: return
    p.nextSave (+0x2aa40) = now + 6000
    GameDB 0x4018 { u16 objHandle, u32 charNo, u32 charNo, PK count (so_ply_SavePKCount) }
    if p has a field:
        GameDB 0x4001 NC_CHARSAVE_ALL_REQ { u16 objHandle, u32 charNo, u32 saverSeq|charNo…,
            SaveLevel @+0xc, SaveLocation @+0x1d, SaveStat @+0x4d }        (0x6f bytes)
    if !partial: GameDB 0x4005 NC_CHARSAVE_QUEST_DOING_REQ (n × 32 bytes)  if any
    GameDB 0x4007 abstates (n × 0x24) — the name ABSTATE_REQ is inferred from its ACK 0x4008
    GameDB 0x4009 skills (n × 0x10) — SKILL_REQ inferred from 0x400A — when the skill list changed
    GameDB 0x400B character titles, if any
    ws_saveassure()
    GameLog 0x0410 { u32 charNo, char map[12], u32 x, u32 y, u8 reason, u64 exp, u64 money }
    GameDB 0x401A { u16, u32 } (rest-exp time; ACK 0x401B NC_CHARSAVE_REST_EXP_LAST_EXEC_TIME_SAVE_ACK)
    if !partial: p.vt[0xab8]()
    tutorial save (FUN_005d0e60), more subsystem saves

ws_save2worldmanager(saver, p):                          @ FUN_004536f0  (WM cache, W01 §6.3)
    0x400E level/exp/position (ws_savelevel2worldmamager FUN_00453580), 0x400F quest doing, 0x4029 quest read,
    0x402B, 0x4011 abstates, 0x4013 items, 0x4015 NC_CHARSAVE_2WLDMAN_GAME_CMD, 0x4014, 0x4016 char title,
    0x4017 money; gamble previous map / coins, chat colour, pet re-summon info, …
```

Who calls the save (periodic timer every 6000 ms tick check, link, logout) is spread over the player tick
(Z07/Z09). Reason values seen: 2 = zone link.

GameDB answers:

```pseudo
0x4002 NC_CHARSAVE_ALL_ACK { …, u32 charNo @+8 }:       @ FUN_00455260
    p = FindPlayer(charNo); if p and level ≥ 60: send WM 0x750C { u32 charNo }   # guild academy graduation check (inferred)
0x4006 NC_CHARSAVE_QUEST_DOING_ACK, 0x4008 NC_CHARSAVE_ABSTATE_ACK, 0x400A NC_CHARSAVE_SKILL_ACK,
0x401B NC_CHARSAVE_REST_EXP_LAST_EXEC_TIME_SAVE_ACK:     no-op   @ FUN_004553b0 / FUN_00455490 / FUN_00455570 / FUN_00455650
0x401D NC_CHARSAVE_AUTO_PICK_SAVE_ACK:                   no-op   @ LAB_00455730
0x4028 NC_CHARSAVE_DB_UI_STATE_SAVE_ACK { ref[6], u16 result }:   @ FUN_00551360
    send the player 0x4026 { u16 result }
```

---

## 9. Other client and WM messages in scope

```pseudo
# Latency tests through every server. Each hop writes timeGetTime() into its own slot of the copied payload.
0x0812 NC_MISC_PINGTEST_CLIENT_ZONE_DB (client):         @ FUN_005509a0
    copy the client's 0x5a bytes; +0xc objHandle; +0x1a time
    only if inventory cell 0 holds item 0x9C9: append { cell key, u16 0x5a, …, objHandle, charNo } and that item
    serialised with lot + 1 (FUN_006406f0); +0xe time; send GameDB 0x0812
GameDB 0x0812:                                           @ FUN_00550fc0
    copy 0x5a bytes back, +0x12 time; player = GetObject(+0xc); if cell 0 still holds 0x9C9: its lot += 1 (in memory),
    +0x16 time, send the player 0x0812 (0x5a bytes)
    # each round trip adds one to that item stack: a debug counter, harmless unless item 0x9C9 sits in cell 0
0x0813 NC_MISC_PINGTEST_TOOL_WM_CLIENT_ZONE_DB (client): @ FUN_00550b90   same idea (0x82-byte header, + item), to GameDB
GameDB 0x0813:                                           @ FUN_00551130   stamp +0x3a/+0x3e, send the player 0x0813 (0x82 bytes; no lot change)
0x0815 NC_MISC_PINGTEST_TOOL_WM_ZONE_DB (WM):            @ FUN_00550e90   stamp +0x1a/+0x26, forward to GameDB (0x3a + n bytes)
GameDB 0x0815:                                           @ FUN_00551250   stamp +0x1e/+0x22, send back to the WM
0x0816 NC_MISC_PINGTEST_TOOL_WM_ZONE (WM):               @ FUN_00550d90   stamp +0x1a/+0x1e, send back to the WM (0x22 bytes)

0x0817 NC_MISC_HIDE_EXCEPT_ME_ON_CMD:                    @ FUN_0043e880
    if mode in 1..6 and the map is "RouN", "Eld" or "Urg"
       and (no mover, or the mover's owner is the player):
        p.flags (+0x5cb8) |= 8           # from now on this player receives only its own broadcasts and its mover's (§3.2)
0x0818 NC_MISC_HIDE_EXCEPT_ME_OFF_CMD:                   @ FUN_00441940
    if mode in 1..6: clear bit 8; re-send the brief info of every character, mob, mini-house, abstate, mover and pet
    in sight (so_HideExceptMeOff_BriefInfo + BriefInfoExchanger.*_Send)

0x082F NC_MISC_SERVERPARAMETER_REQ:                      @ FUN_005517c0
    send 0x0830 { u8 DAT_0da5047c, u16 DAT_0da50480 }      # DAT_0da5047c is also used as a level bound elsewhere; source not found

0x0C23 NC_USER_REGISENUMBER_REQ:                          @ FUN_0056e8b0
    send 0x0C24 { u32 userNo }

0x0C32 NC_USER_USE_BEAUTY_SHOP_CMD:                       @ FUN_005520d0
    p+0x2a800 = 1          # every handler clears it on entry (vt 0x330(0)); meaning not traced

0xB410 NC_USER_CONNECTION_CHANGE_CHAR_ID_ITEM_USE_REQ { u8 slot }:   @ FUN_0051b090
    errors → client 0xB413 { u16 code }:
        mode not in {1,2,6}, flag +0x1e78 bit 2, or vt 0xf20 → 0x20B1;  no field → 0x20B2;  items locked → 0x20B4
        bad slot / no item → 0x20B3;  item class not 4/5 → 0x1A78;  empty item cell → 0x20B6;  lot 0 → 0x20B5
    lock the inventory cell (type 9), then send GameDB 0xB411 {
        item key (8 bytes), u16 cell = 0x2400 | slot, u8 premium (class ≠ 4), u16 itemId, u32 userNo, u16 objHandle,
        u32 charNo, item key, u16 itemId, u16 lot-after or 0, u16 lockId, u8 last, [item attributes if lot > 1] }
    # the DB answers 0xB412 (Z04/Z07); client 0xB413: 0x20B0 success "Name Change activated…", 0x20B9 already used,
    # 0x20BA guild master; every code sent here shows "Cannot use the item due to an Abnormal State."
```

WM → zone:

```pseudo
0x0821 NC_MISC_TIMEFROMWORLD_CMD { struct tm (36 bytes) }:   @ FUN_004511a0
    g_worldTm = tm; g_timeOffset = mktime(tm) − time(); SetLocalTime(tm)     # the zone sets the machine clock
    first time only: start the ms clock (DAT_14d41a70 = 0, timeGetTime base)
    ServentBuffBossTable.sbbt_TimerReset
0x0823 NC_MISC_START_THE_BOOM_CMD: no-op                 @ LAB_005a47b0
0x0825 NC_MISC_WHSHANDLEREPAIR_CMD { u16 objHandle, u32 charNo, …, u16 wmHandle @+6 }:   @ FUN_00551670
    p = GetObject(objHandle); if p.charNo == charNo and not closing: p.wmHandle = wmHandle   (so_ply_…REPAIR FUN_00551750)
0x082B NC_MISC_CONNECTFROMWHERE_ACK { u16 objHandle, u32 charNo, u8 where @+6 }:   @ FUN_0043f2f0
    p.connectFrom (+0x2a7d4) = where
0x0865 NC_CHAR_GET_CHAT_BLOCK_SPAMER_CMD { char name[20], u32 until @+0x14 }:   @ FUN_005a5710
    p = FindPlayer(name) else log "wms_NC_MISC_SPAMMER_ZONE_CHAT_BAN_CMD - shineobject null"; p.chatBlockUntil (+0x2aa54) = until
0x086A NC_MISC_EVENTNPC_STANDSTART_ZONE_CMD { char npcIndex[32] }:   @ FUN_005a57e0
0x086B NC_MISC_EVENTNPC_STANDEND_ZONE_CMD   { char npcIndex[32] }:   @ FUN_005a5950
    find the NpcSchedule.shn row with that index; NPCManager.nm_StandNPC start (FUN_004c6870) / end (FUN_004c6ad0)
```

---

## 10. Zone ring (ZoneListenSession / ZoneConnectSession)

The zones of a world form a ring: each zone connects to the "next" zone (`zipc_SetNextIP` at startup, the
`ZoneConnectSession` DAT_13388e90, reconnected on demand in `zcs_Send` @ FUN_005a6ed0) and accepts the previous
one on its zone listen port (type 6). Requests that must find a player in "any zone" travel around the ring.

Ring header (payload): `{ u8 originZone, u16 originObjHandle, u32 originCharNo, u8 …, … }`.

```pseudo
generic RNG handler(packet):                             # ZoneListenSession.zbs_Parsing @ FUN_004fb4a0 dispatches
    if packet.originZone < 10 and originZone != myZone:   # on its way round
        handle locally if the target is here (found → send the "found/answer" opcode into the ring),
        else forward the packet unchanged to the next zone (zcs_Send)
    else:                                                 # back at the origin
        p = GetObject(originObjHandle); if p.charNo == originCharNo: deliver the result (zrpb_Success / zrpb_Faulure)
```

| Opcode | Handler | What happens |
|---|---|---|
| 0x0811 NC_MISC_ZONERINGLINKTEST_RNG | FUN_0045b4d0 | each zone appends its 16-byte address entry; at the origin the GM gets "%d mechines travel complete" and one chat line per zone (`vt 0x784`) (AmpersandCommand ac_ZoneLinkTest) |
| 0x1068 NC_CHAR_PLAYERSEARCH_RNG | FUN_0045b870 | target (name @+9) found here → 0x1069 with its map[12], x, y; back at origin → "%s is not in game" |
| 0x1069 NC_CHAR_PLAYERFOUND_RNG | FUN_0045ba60 | forwarded to the origin → zrpb_Success (GM sees the location) |
| 0x106A NC_CHAR_PLAYERSUMMON_RNG | FUN_0045b700 | target found → ZoneRingPacketSummonPlayer.zrpb_Success: target `so_ply_BriefLink(map, xy)` to the GM's place |
| 0x106B NC_CHAR_KICKPLAYEROUT_RNG | FUN_0045bc30 | target found → so_Disconnect(0x68B), answer 0x106C into the ring |
| 0x106C NC_CHAR_PLAYERBANNED_RNG | FUN_0045bdf0 | forwarded to the origin (origin calls the kick result function) |
| 0x10AD / 0x10AE …_BY_NORMAL_USER_RNG | FUN_0045c0b0 / FUN_0045c340 | same as 0x1068 / 0x1069 for the normal-user search |
| 0x1810 NC_MAP_EXPBONUS_RNG | FUN_0045bf30 | not origin: apply the EXP bonus event (ZoneRingPacketExpBonus success) |
| 0x1811 NC_MAP_ITEMBONUS_RNG | FUN_0045bff0 | not origin: ZoneRingPacketItemBonus request |
| 0x1095, 0x10AA, 0x10AB, 0x2055 (wedding) | FUN_005a0a40, FUN_005a0c90, FUN_005a0e00, FUN_005a2b60 | partner info / summon / refresh / couple entrance (Z08) |
| 0x10B1, 0xA404 (instance dungeon), 0x441F (job dungeon) | FUN_00485120, FUN_00487510, FUN_005bfde0 | find an empty / existing instance in any zone (Z08) |
| 0x7493, 0x9872, 0x9874, 0x9884, 0x9885 (guild / academy storage) | FUN_00474f10, FUN_00473050, FUN_00473160, FUN_00473270, FUN_00473370 | storage withdraw/deposit across zones (Z08). The handlers of 0x9884 and 0x9885 carry the profiler name "…DEPOSIT_RNG" too (copy-paste in the original) |
| 0x9436 NC_HOLY_PROMISE_CENTRANSFER_RNG | FUN_004839b0 | money transfer to the holy-promise partner (Z08) |
| 0x0804 / 0x0805 | FUN_0045b3f0 / FUN_00549070 | heartbeat |

---

## 11. Client cross-check (summary)

| Zone → client | Client scene / handler | Client behaviour |
|---|---|---|
| 0x0807 SEED_ACK { u16 } | Net.SetSeed via the zone-login scene | XOR start index |
| 0x1802 MAP_LOGIN_ACK | ZoneLoginNet FUN_00477950 / Link FUN_006261b0 | enter the game |
| 0x1804 { u16 code, u8 idx } | ZoneLoginNet FUN_004778c0 / Link FUN_00626140 | 0x147: checksum message; else leave the scene silently |
| 0x1805 { u16 handle } | GameFrameWork FUN_004bd620 | remove object |
| 0x180A { mapIndex, x, y, ip, port, wmHandle } | GameFrameWork FUN_004b4ab0 | connect to the other zone |
| 0x1809 (same-zone link reply) { u16 mapIndex, u32 x, u32 y } | GameFrameWork FUN_0049feb0 | copies the 10 bytes, reloads the map |
| 0x1815 / 0x1817 { u16 code } | FUN_004aeed0 / FUN_004aeff0 | wing texts (§7.2) |
| 0x181B { u16 code } | FUN_0049ba50 | town portal result (texts from the error table) |
| 0x1820 { u16 code } | FUN_008b80a0 | no payload read |
| 0x0810 { u8, u16 } | FUN_004997a0 | map time limit |
| 0x10D4 { u8 } / 0x182C { u32 } / 0x7C05 { u16, u32 } | FUN_004b33b0 / FUN_0054bb10 / FUN_0049b1b0 | login burst |
| 0xB413 { u16 code } | FUN_004b2bc0 | name-change item texts (§9) |
| 0x0830, 0x0C24, 0x4026 | no client handler in C01's table | ignored by this client build |

---

## 12. Not reconstructed / uncertain

- **Start order.** The order of the `zs_start_*` / `zs_service_*` stages is in the script downloaded from the
  certification server (§2.1); it is not available. The table in §2.2 lists what each stage does.
- The certification protocol itself (`FUN_00613440`, `FUN_00613750`, `FUN_00613950`, threads FUN_005ab9c0 /
  FUN_005a9f10) was not followed. A rebuilt server does not need it.
- The main thread (`zs_mainthreadfunction`) and the player tick: periodic save, heartbeat to clients, timers.
  Only the entry points are known here; the tick belongs to Z09/Z07.
- Player modes other than 0 and 1 are only partly identified (§4.3).
- 0x203E (walk/run speed) has no name in the binaries; the field meaning comes from the Lua global names.
- `0x0830` values (DAT_0da5047c / DAT_0da50480): no writer found in the decompiled code (probably set by the
  start script).
- Meaning of `p+0x2a800` (set by 0x0C32, cleared on every handler entry).
- 0x101E sends the player's handle as the 0x1804 code (§5.3); checked twice, kept as read.
- The exact fields of 0x4001 (SaveLocation is 172 lines) are left to Z05/Z07; only the frame is given here.
- The client-checked table list (which 49 files, their order) is filled by FUN_006311a0 calls in zs_start_sleep;
  only the View/*.shn calls were read. The client side is `DAT_00b533c0` (C01).
- Ring packets of Z08 features are listed, not detailed.
- The plan named `FUN_00434ae0` as a broadcast helper; it is not one (it copies a 0x16-byte block into an object at +0x168).
  The broadcast path is `AxialListPacketBroadcast` (FUN_00428a40, ali_Work FUN_00428b20) with `so_AllInMap*` (§3.2).
