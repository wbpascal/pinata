# Zone server: world simulation — main loop, timers, mobs, NPCs, spawns, drops, scripts (Z09)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (export `re-data/exports/zone`). Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`. Names: the zone's
official names from the NA2016 `Zone.pdb` (same build, work item S01; export `re-data/exports/zone-pdb`, read with
`clean.py re-data/exports/zone-pdb - <addr>`): they count as read in the code *(pdb2016)*. The namespace
`ShineObjectClass::` is left out (`ShineMob::so_Routine` = `ShineObjectClass::ShineMob::so_Routine`). Where an earlier
part of this file used a name of ours, it was replaced by the official one (part R1); the few names still marked
*(ours)* have no PDB name. Global variables keep their PDB symbol (`mobdatabox`, `shineobjmanager`, `sock2wldman`, …);
three short aliases stay because the other zone docs use them: `g_Now` = `clockwatch.cw_CurrTick` (DAT_14d41a70),
`g_Rng` (DAT_150ba418, a `cWell512Random`), `g_SightDistSq` (DAT_008b7834). Evidence markers as in `AGENTS.md`: plain =
read in the 2016 code (2016 server PDB included), *(pdb2017)*, *(inferred)*.

Time unit: `g_Now` (`clockwatch.cw_CurrTick`, DAT_14d41a70; `ClockWatch` 0x20 bytes) counts **tenths of a second**
(Z02 §1); "`g_Now + 50`" = 5 s.

This file is written in parts (status: `docs/plan/status/Z09.md`). Sections so far: §1 main loop and global timers,
§2 the player tick, §3 GM events, §4 prison (no zone timer), §5 mob object core (data, spawn, routines, NPC, bandit),
§6 mob AI 1 (brain, target selectors, aggro, battle / recover, calls for help), §7 mob AI 2a (tactic state machine,
weapons, attack sequences, captivated players, the dead `so_attack` / `so_Bash` path), §8 mob AI 2b (script-ordered
skills and weapon rates, cross-counter, hit / heal rules of the non-player classes, skill blast delay, mob chat, mob
shout, servant explosions, boss-field hooks, the charmed player's target selector). §9 movement (MoveManager, block
bitmaps and doors, server-driven moves, random spots, Navigator, MobRoam, scenario moves) and sight (coordinate lists,
range queries, 0x1C0E on moves). §10 spawns (MobHatchery / breeder groups / breeders, MobRegen files, adaptive regen
time, families, the 1-s regen event, script and Lua spawners, KQ / instant regen tables) and the treasure-chest maker.
§11 drops (tables, roll, drop objects, loot rights, party/raid loot, dice game). §12 magic fields (ground-effect skills:
spread, tick, damage / heal / aggro, 0x1C0C / 0x1C0D) and axial flags (map anchors that run the map cinema and the
guild tournament). §13 doors (script-built gates, 0x1C0F / 0x1C10 / 0x6C09), effect objects (0x1C11 /
0x1C12) and servants (skill summons: `MiscDataTable` SkillBreedMob, master link, roaming, flags, vanish). §14 the Lua
engine (script objects, AI / pet / map scripts, object and map script events, argument objects, Lua triggers, the Lua
observer, player observers, script timers, script server menus and casting bars, the table of all 248 Lua functions).
§15 script interrupts of Pine map scripts (kinds, events, `waitinterrupt`, unit interrupts, `&scrint`) and script
areas (`.aid`, the client's area tests 0x6C05…0x6C08, area and map counters). §16 NPCAction proximity triggers
(`World/NPCAction.txt` conditions and actions, `MobSetting/Action/` trigger files, the neighbourhood scan, player
observers, damage absorption by protector mobs). §17 the Lua functions that control objects (moves, animations,
damage / kill / revive, abstates, mob settings, map rules, links and parties, player items / money / stats / view slots). §18 the
Lua query functions (time / random, object state, positions and areas, searches and lists, object effects, sounds, map
marks). §19 the Lua message functions (`ScriptMsg.shn` messages, dialogs, notices, shouts, camera, fog, screen effects,
timers, sounds). §20 the Pine map-script language, reading side (`World/PineScript.txt`, tokens, the string value
model, expressions, variables, the process stack; `MobBehaviorDescript/` is unused). §21 the Pine language, running side
(grammar, the statement registry, blocks, how a film steps, `var` / assignment / `if` / `while` / `infinite` / `call` /
`break` / `print` / `permillage`, conditions, `@` system functions, which 2016 books load). §22 the Pine action
statement base (`OtherStatement` loader, object build / change helpers), the 25 `@` system functions, the nine
auto-registered nodes (save link, GT portal / NPC / item box, party scenario code, abstate test, code notices), the
scenario book shelf (Pine or Lua books, reload) and the dialog-string files (`Script/*.txt`). §23–§26 the Pine action
nodes, §27 films and the boss-field tables, §28 the sweep additions (map query functions per map kind, heal reports,
the rest of `MiscDataTable.txt`, answers to the sweep leftovers, the `OptionReader` text-table format, the dead
`CFindWay` path finder, the methods reached only through vtables, the data-file and opcode check, the last helpers of the gap list, the game's own `List` / `BTree` / vector
templates; review additions: the Lua score / ranking functions, the instance-dungeon rank result, the hunt log, and the small
leftovers of finished items: capsule creation, class change, charged effects, guild-war request, tutorial Lua functions), §29 the original-server bugs
register (Z09-B1 … B131), §30 what is not reconstructed or uncertain, §31 the coverage boundary.

---

## 1. Main loop and global timers

### 1.1 `ZoneServer::zs_mainthreadfunction`

One thread runs the whole world: network polling of the server links, **all client packet handling** (inside each
player's tick, §2.5), every object's routine, and the global containers. IOCP workers only move bytes.

```pseudo
zs_mainthreadfunction(ctl)                                          @ FUN_005aca30
    # ctl = thread control block: +0 u8 running, +1 u8 stopRequest, +0xc u32 tickCounter
    ctl.running = 1; ctl.tickCounter = 1
    srand(time()); r[16] = 16 × rand(); InitWELLRNG512a(r) FUN_0063c890   # seeds the zone's WELL512a RNG
    BalanceLog.dl_Activ (DAT_14d44a34) = 0                            # switches one debug log off
    while !ctl.stopRequest:
        _PerformanceRecorder (DAT_0d026c10): pr_MainLoopHead FUN_004678e0 … pr_MainLoopTail FUN_004681f0 at the end of the tick
            # profiler bracket of one tick (an earlier part of this file read it as a lock; the PDB names settle it)
        # clock
        clockwatch.cw_TotalMilliSec (u64) += timeGetTime() − cw_LastMilliSec;  g_Now = cw_CurrTick = cw_TotalMilliSec · 10 / 1000
            # tenths of a second since the first WM 0x0821
        clockwatch.cw_DeltaTick (DAT_14d41a74) = tenths since cw_LastMilliSecByDelta (step of this tick)
        ShineObject::so_CostumWeaponChargeing / so_CostumShieldChargeing (static members, DAT_1327281a / DAT_13272bca):
            item SerialNumber = −1                                     # two per-tick caches reset (users not traced)
        ZoneServer::zs_disconnect(server)                                    @ FUN_005abb60   §1.5
        ZoneServer::zs_connect(server)                                   @ FUN_005aa840   §1.5
        SocketBundle<GameDBSession>::sb_Packet(sock2gameDB); (sock2gamelog); (sock2wldman)   @ FUN_005ab030
        ZoneServer::zs_PacketProcess("ZoneCon", zoneconnect); ZoneServer::zs_PacketProcess("ZoneLis", ring previous DAT_0af0cff0)   @ FUN_005a9f70
        if timefromworld.tm_min ≠ chargeditemcheck.ct_Current.minute (bits 25..31):  PerMinuteBlock()   # §1.2
        GMEventManager::GMEM_ReflushRunState(&gGMEventManager)                                  @ FUN_0046d7e0   §3 (every 1 s)
        SocketBundle<GameDBSession>::sb_Routine(sock2gameDB, type 2); (sock2gamelog, 3); (sock2wldman, 5)   @ FUN_005aa340
        List<FieldMap>::l_4AllInList(&shineobjmanager, ShineObjectEachList.soel_Routine)      @ FUN_004026e0 → FUN_0054f710   §1.3
        SkillBlastEffectContainer.sbec_Routine(&g_BlastEffects)        @ FUN_00437fc0   (Z03 §5.4)
        ForEach(&zonevent DAT_13388e70, erle_Routine)        @ FUN_005af1e0   §1.4
        ForEach(&optoollist DAT_0da3d2b8, OPToolObject.opto_Routine)   @ FUN_004c7e60   §1.5
        ForEach(&gldstoramanager, FUN_00474950)                         # drops records whose +0x106c "in use" byte is 0 (Z14)
        chargeditemcheck.ct_1MinuteFlow = ct_1DayFlow = 0 (DAT_00aa43e0 / DAT_00aa43e1)   # the per-minute flags live for exactly one tick
        if BossFieldContent::g_ServentBuffBossTable.sbbt_NextTick (DAT_14d6fcb4) < g_Now: sbbt_NextTick = g_Now + 50   # 5-second pulse, §1.4
        SleepManager.sm_Routine(&sleepmanager DAT_0086ed54)                 @ FUN_005aa610   §1.4
        if DAT_0d76abc0 < g_Now:                                       # instance-cluster interval
            DAT_0d76abc0 += DAT_0d76abc4
            ForEach(&mapclustermanager, MapCluster.mc_Routine)           @ FUN_004868d0   (Z14)
        performancechech.pc_Buffer[pc_point++ & mask] = g_Now  (DAT_0084fb20, `PerformanceChecker`)   # ring of tick start times (diagnostic)
        CGambleObjectManager::gom_Routine(&gGambleObjectManager)                                @ FUN_006158d0: every game object vt 0x20 (Z06 §5 routines)
        ctl.tickCounter++
    ctl.running = 0
```

There is no fixed tick length: the loop runs as fast as it can, throttled only by the sleep manager (§1.4).

### 1.2 Per-minute block (world time)

The WM sends `0x0821 NC_MISC_TIMEFROMWORLD_CMD { struct tm }` every 60 s and when the zone connects (W01 §2,
`Zones_TimeSync`). The zone handler (`wms_NC_MISC_TIMEFROMWORLD_CMD` @ FUN_004511a0, Z01 §9) copies it into
`timefromworld` (DAT_00aa43e4, 9 ints: sec, min, hour, mday, mon, year, wday, yday, isdst), sets the machine clock and
`diffence2world` (DAT_00aa4408 = mktime(tm) − time()). `mysecond(&t)` @ FUN_00450360 = `time() + diffence2world`.
So the block below runs once per WM time message whose minute differs from the last one (≈ once a minute); while the
WM link is down no minute passes *(inferred)*.

```pseudo
PerMinuteBlock():                                                   (inline in FUN_005aca30)
    # certification counters (Z10), struct LuaArgument g_LuaArgument DAT_14d6fcd8 (pdb2016):
    #   MaxSkip (+8) < SkipNumber (+0x10) → ctl.stopRequest = 1 (the zone stops);
    #   else Summary (+0xc)++, and when ≥ Interval (+4): CertifyArg (+0x14) = next non-zero (rndbox.rb_box[100] slot − 50), Summary = 0
    clear globalset (DAT_13295a68, std::set<ulong>; entries added by som_FreeObject FUN_00557d70; freed-handle bookkeeping, inferred)
    chargeditemcheck.ct_Current (DAT_00aa43b8, ShineDateTime bitfield: year:8 month:5 date:6 hour:6 minute:7)
        = min<<25 | hour<<19 | mday<<13 | (mon+1)<<8 | (u8)(year − 100)
        # packed "now" that charged / time-limited items compare with field by field (e.g. §2.4 SmallChargedItemLimitCheck)
    chargeditemcheck.ct_TimeStr (DAT_00aa43bc) = timefromworld
    chargeditemcheck.ct_1MinuteFlow (DAT_00aa43e0) = 1 "a minute passed";
    chargeditemcheck.ct_1DayFlow (DAT_00aa43e1) = 1 when min == 0 and hour == 0 "a new day"
    sleepmanager.sm_MaxPacketInLoop (DAT_0086ed5c) −= itself / 100  # 1 % decay per minute of the peak used by sm_Routine (§1.4)
    wms_GuildTournamentCheck()                                      @ FUN_004776a0   (Z16)
    wms_GuildWarStatusRequest(sock2wldman)                         @ FUN_005a45f0   (Z08 / W03)
    WeddingHall.wh_Routine(&weddinghall)                          @ FUN_005a2a10   (Z13)
    object-pool consistency check: for each of the 13 pools (DAT_132828a4[0..12]) and each used slot:
        ShineObjectHandleUnion::sohu_HandleSplit(obj.handle) must give (pool, slot); otherwise log
        "ZoneServer::zs_mainthreadfunction - so_GetZoneHandle[h] ObjType[t] Index[i] inlist[…]" (log only)
    if !g_LUA_SCRIPT_SECURITYFactor.lsf_IsFreeze (DAT_00870de0): lsf_Factor (DAT_00870dd8, double) *= 1.01   # read by the script (Z10)
    LuaScript::ls_FunctionCall(&g_LUA_SCRIPT_SECURITY DAT_14d6fdf0, "xlrfunction", no arguments)   @ FUN_005d7bc0
        # a function defined by the downloaded start script (Z10); failure → log "…zs_mainthreadfunction : function call error"
```

Everything that "runs once a minute" in the zone keys off `chargeditemcheck.ct_1MinuteFlow` during that one tick (player checks §2.4).
`chargeditemcheck` is a `ChargedItemEffectList::CheckTime` (0x2c bytes: `ct_Current`, `ct_TimeStr`, the two flags) *(pdb2016)*.

### 1.3 Object routines

`shineobjmanager` holds one `ShineObjectEachList` per object pool (13 lists, Z01 §4.2). The main loop visits each list
(`List<FieldMap>::l_4AllInList` @ FUN_004026e0, a template instance shared by every list type); each list visits its objects:

```pseudo
ShineObjectEachList.soel_Routine(list)                              @ FUN_0054f710
    ok = List<ShineObject>::l_4AllInList(list, obj → obj.vt[0x4ac]())            @ FUN_0054b160, thunk LAB_0054b320 (jmp [vt+0x4ac])
    if !ok: list.failCount (+0x1c)++                                # a visit stopped at a free slot
    if list.nextReport (+0x18) < g_Now:
        if failCount: log "ShineObjectEachList::soel_Routine - ObjectType[…] LISTNO Count[n]"; failCount = 0
        nextReport = g_Now + 600                                    # once a minute
```

`vt 0x4ac` = `so_Routine` per class (from the RTTI vftables):

| Class | so_Routine | Section |
|---|---|---|
| ShineObject (base) | FUN_0064c820 `return 1` | — |
| ShineAxialFlag | `ShineAxialFlag::so_Routine` FUN_00569e00 | §12.7 |
| ShineDropItem | `ShineDropItem::so_Routine` | later part (drops) |
| ShineMiniHouse | FUN_00567400 | Z06 §3.4 / Z13 |
| ShineMagicField | `ShineMagicField::so_Routine` FUN_0056d7e0 | §12.4 |
| ShineEffectObject, ShineDoor, ShineServant | FUN_00569ef0, FUN_00567280, FUN_0056c070 | §13.2, §13.1, §8.8 |
| ShineBandit | `ShineBandit::so_Routine` FUN_0056c630 | §5.10 |
| ShineMobileObject (base of all movers) | FUN_0056a080 (cast completion: Z03 §5) | §5.5 |
| ShinePlayer | FUN_0056c790 | §2 |
| ShineMob, ShineNPC | `ShineMob::so_Routine` FUN_0056baa0, `ShineNPC::so_Routine` FUN_0056a9e0 | §5.4, §5.9 |
| ShineMover, ShinePet | `…::so_Routine` | Z13 |

### 1.4 Other global containers

```pseudo
EventReserveListElement.erle_Routine(e, list, idx)                  @ FUN_005af1e0
    # e = { u32 fireAt (g_Now), → action (vt +0 = run), ?, u32 repeat (tenths; 0 = once) }
    if e.fireAt ≤ g_Now:
        e.action.vt[0]()
        if e.repeat == 0: list.vt[0xc](idx)   (remove)   else e.fireAt += e.repeat
    # only producer found: wms_NC_KQ_W2Z_START_CMD (FUN_00499240) reserves the KQ entrance announcements
    # at g_Now + table DAT_0083c798[i]·10 (Z16)

SleepManager.sm_Routine(s)                                          @ FUN_005aa610
    # s = sleepmanager { sm_PacketNumber (DAT_0086ed54), sm_LoopNumber, sm_MaxPacketInLoop }; sm_PacketNumber is incremented once per processed packet
    #     (player tick §2.5, ZoneServer::zs_PacketProcess, opto_Routine)
    peak = max(peak, work)
    if work · 2500 / peak < step²:  SleepManager.sm_Sleep(s)        @ FUN_005aa5b0: Sleep(1 ms); step = 0
    else step++
    work = 0
    # an idle zone sleeps 1 ms every other tick; a busy one sleeps after ~√(2500·work/peak) ticks
```

`BossFieldContent::g_ServentBuffBossTable.sbbt_NextTick` (DAT_14d6fcb4; our earlier name `g_Pulse5s`) is "true" (`< g_Now`) for exactly one tick every 5 s, because the main loop re-arms it after
the object routines (it is a member of the boss-field servant-buff table, §8.9, not a general pulse). `ShineMob.sm_IBuffToBuffee` (FUN_005d48c0) and FUN_0069b690 test it (mob part).

### 1.5 Session polling and reaping (network side of the tick)

```pseudo
ZoneServer::zs_PacketProcess(name, s)                                               @ FUN_005a9f70
    if s.state ∉ {1, 2}: return 2
    r = s.io.vt[0xc]()                     # 0 nothing, 1 packet ready, 2 error
    1 → s.vt[4](0, 0xFFFF) (dispatch with handle −1); s.io.vt[0x24]() (release); sleepmanager.sm_PacketNumber++; return 0
    2 → s.io.vt[0x10](&n); if n < 0 return 1; s.io.vt[0x18](); s.state = 3; return 1
    0 → if s.io.vt[0x28]() (flush) fails: FUN_005a66c0(s) (close)
SocketBundle<GameDBSession>::sb_Packet(pool)                                           @ FUN_005ab030
    for the 4 entries in state 1/2: if ZoneServer::zs_PacketProcess ≠ 0: close (FUN_005a6690), state 0,
        reconnectAt (+0xfc) = g_Now + pool.reconnectSeconds (+0) · 10, ready = 0, log
SocketBundle<GameDBSession>::sb_Routine(pool, info, type)                             @ FUN_005aa340
    for entries not in state 1/2 whose reconnectAt ≤ g_Now: FUN_005a9b50(info, entry, type, 1) (connect + handshake, Z01 §3.3)
ZoneServer::zs_connect(server)                                        @ FUN_005aa840
    per accepted socket by listen type: 6 zone ring (ZoneListenSession), 8 OPTool (OPToolSession; refused when
    no OPTool object is free), 0x14 client (ClientSession from the free pool; full → socket closed)
ZoneServer::zs_disconnect(server)                                         @ FUN_005abb60
    also polls the ring-next link (reconnect when down) and the pools' keep-alives (FUN_005aae80, FUN_005ab2c0, not opened)
    for each client session:
        phase (FUN_0045b190) ∈ {0, 1} and g_Now − connectTime (FUN_0045b1b0) > 72000 (2 h): log, state = 3
        FUN_0045b1d0 == 1: log, state = 3
        state 3 ("Socket cut"): obj = som_GetObject(session.objHandle +0x102)
            if obj is a player in a game mode: obj.vt[0x910]("Socket"); sp_RefreshWMSSocket   (Z01 §8.2)
            so_PacketBufferFlush; so_Unmark(…, 1, 7); som_FreeObject(handle) (log "…zs_disconnect : Fail to object free")
            release the session to the pool
OPToolObject.opto_Routine(o, list, idx)                             @ FUN_004c7e60
    same receive/dispatch as ZoneServer::zs_PacketProcess for an OPTool session; dead session → removed from the list
```

---

## 2. Player tick (`ShinePlayer::so_Routine`)

### 2.1 Order of work

```pseudo
ShinePlayer.so_Routine(p, _, poolIndex)                             @ FUN_0056c790
    if p.mode ≠ 0 and p.field == null: p.so_Disconnect(0x685, 0, 0); return
    if p.field and (p.x ≥ field.xsize (+0x18) or p.y ≥ field.ysize (+0x1c)):
        log "fm_IsInFieldSize : Player"; p.flags1e78 |= 0x01          # → disconnect below
    sp_ElderineRegionCheck(p)                                       @ FUN_005529d0   §2.2
    if p.mode == 3 (dead) and p.autoReviveAt (+0x2aa4c) ≠ 0 and ≤ g_Now:
        sp_ReviveReqProcess(p) (FUN_00451bd0, Z05); end of tick
    ShineMobileObject.so_Routine(p)                                 @ FUN_0056a080   (casts / abstates, Z03 §5–6)
    soul-collect target (p+0x2a90c, armed flag +0x2a910, until +0x2a914; Z03 NC_BAT_TARGETTING_REQ):
        if armed and (target closing or target.vt[0x28]() or until < g_Now): disarm;
        p ← 0x2453 NC_BAT_SOULCOLLECT_CMD { u16 target = 0xFFFF, u8 soulnumber = 0 }
    p.questZone (+0x173e8, CQuestZone).vt[0x24]()                  # quest routine (Z15)
    handle = p.vt[0x4a4](poolIndex) = 8000 + poolIndex              @ FUN_00559d40 (−1 if index > 1499)
    if p.flags1e78 & 0x01: p.so_Disconnect(0x680, 0, 0); end of tick
    if p.actionTimer.check (+0x2a794)(…) == 1: end of tick           # TimeScheduler at +0x2a784 (Z03 §3): the
        # check pointer is ts_TimerCheck while armed and FUN_004a9c90 (returns 0) when idle; 1 = the fired
        # callback asks to stop this tick (inferred)
    if p.mode ≠ 0:  GameModeWork(p)                                 # §2.3
    if p.flags1e78 & 0x04 (Fear, Z03):
        CancelOnAction (vt 0x8d0); if actionTimer.state ∈ {2, 3} (swing): smo_BashStop (vt 0xed8)
        if casting (+0x1d84) and skill (+0x1d88) ≠ 0x7213: once (+0x2928c bit 1): p.deferredErr (+0x7f37) = 0xFCC; sp_castabort (vt 0xed4)
    ShinePlayer::notifyObservers(p, 0, 0, 0)  (vt 0xa38)                      @ FUN_00577c10   §2.6
    ScriptTrigger range check                                       §2.6
    CharaterSkillList::csl_Toggle_CheckOnOff(p.skillList +0x17d0c, p)               @ FUN_00448e20
        for each toggled skill (entry +2 ≠ 0) that csl_Toggle_CanUseSkill refuses now: remove its up to 4 abstates
        (vt 0x650, so_AbnormalState_BitReset, so_AbnormalState_BroadcastReset) and p.vt[0xbcc](skill) (toggle off)
    ShinePlayer::notifyObservers(p, 6, 0, 0)
    ReceivePackets(p, handle)                                       # §2.5
    slanted-list check: if the player's x/y nodes (+0x16, +0x22) fail
        SlantedCoordList::CoordedNode::cn_IsValid (FUN_0054b4c0: "Not inlist", "Link error", "Order error"):
        FieldMap.fm_Relink(field)                                   @ FUN_00462bd0   (the same check runs again on exit: destructor of the scope guard `SlantedListNormalizer`, FUN_005670c0)
```

Disconnect reasons used here: `0x680` player outside the map rectangle, `0x685` in a game mode without a map.
Bit 0 of `obj+0x1e78` is therefore the "invalid position" flag for players: it is set only by the routines' bounds
checks (players here; FUN_00567280, FUN_0056baa0, FUN_0056c1e0 for other classes) and cleared by FUN_004424f0,
FUN_00442eb0, FUN_0055fdf0 (re-placement). This corrects Z03 §2 ("routine ran once") *(inferred from the writers)*.

### 2.2 Region check on Elderine

```pseudo
sp_ElderineRegionCheck(p)                                           @ FUN_005529d0
    if p.field.mapName == "Eld" and (x ∉ [6000, 20000] or y ∉ [6000, 20000]):
        log x, y, charNo and dump p.sp_ProtocolLog (+0x2a804, `ProtocolLogger`: ring of the last 16 received packets
        {tick, locate x/y, NETCOMMAND}, index pl_Pointer +0x100) via ProtocolLogger::pl_Logging FUN_0054a120   # log only, no correction
```

### 2.3 Work done for a player in a game mode

```pseudo
GameModeWork(p):                                                    (inline in FUN_0056c790, when p.mode ≠ 0)
    NormalAttackDamageTick.nadt_Routine(p+0x173d0, p)               @ FUN_00577520   (Z03 §3)
    if p.itemActions (vt 0x5d0): FUN_005d1930(it)                    # item-action cooldown routine (Z17)
    character-title minute counters: FUN_005cc4e0(p+0x29638)
        when mysecond()/60 changes: +0x4c8++ (cond 3), +0x4d8++ (cond 4), +0x728++ (cond 0x29), and
        +0x748 = FUN_0062e3b0() (cond 0x2b); each through the title-condition update FUN_005cb5f0 (Z07 / Z12)
    ride timer: if rideItemSlot (+0x2a760) ≥ 0 and +0x2a768 ≤ g_Now:
        on a ShineMover (ride kind 2): if !FUN_0045ec10(p, 1): CancelOnAction, rideKind = 3;  else sp_HorseOn(p, 1)   (Z13)
    mount hunger: mode 6, ride kind 0, +0x2a774 ≤ g_Now:
        no ride info / item → sp_HorseOff(p)
        else if !+0x2a5b8 and info.hungerStep (+0xcc) ≠ 0: item.vt[0x3c](−step, +0xc6); sp_SendHorseHungry(p, item.vt[0x40]());
             next = g_Now + info.hungerInterval (+0xca) ms / 100                              (Z02 §9.1, Z13)
    FUN_004d2d20(p)                                                 # pet routine (Z13)
    pet reactions: pet state (+0x2ab60) 5 or 6: mode 5 and timer +0x2abd4 → PetReaction(10);
        emote shown (+0x7f32+0x54 ≠ −1) and timer +0x2abdc and ActionViewInfo row (+0x2abe4) matches with +0x71 == 1 → PetReaction(1)
    hooks (function pointers; the no-op FUN_00417480 unless set):
        +0x29628 HP/SP recovery (Z02: sp_RecoverPoint_House in a tent), +0x173bc, +0x173c8,
        +0x29634 (ShinePlayer::sp_MoverUpgradeEffect_ON FUN_0056b5f0 while on a mover)
    class object (vt 0x49c) .vt[0x34](p)                            # per-class routine (CharClass*, Z12)
    if chargeditemcheck.ct_1MinuteFlow: PerMinutePlayerChecks(p)               # §2.4
    sp_SendHPinform, sp_SendSPinform, sp_SendLPinform               # §2.4 packets
    sp_SendPartyMemberInform(p)                                     @ FUN_0056e340
    sp_SendMyInform2PartyMember(p)                                  @ FUN_0056df80   (Z08 §1.2: party HP/SP to members)
    item-action level/HP/SP triggers: if itemActions and timer +0x2a314 expired:
        FUN_005d1f30(itemActions, {8, 0, 2}, …)                     # condition 8 "periodic"
        FUN_00565790(p)  level brackets: condition {6, k, 10}: k = 1 (< 41), 3 (< 20), 4, 5 (50..79), 6 (80..99), 7
        FUN_00565600(p)  HP < 20 % → condition {6, 0, 10}
        FUN_005656d0(p)  SP → condition {6, 2, 10}                  (all Z17)
    +0x29318 hook (default LAB_0055e150; FUN_0041dd70 swaps it with FUN_0055e2a0)
    pending relink (+0x5cb8 bit 0x40): clear; target = FUN_00551910(p, +0x292a2); if p.so_LinkTo(target, 6, 9, 10) fails and
        +0x5cb9 bit 0: set bit 0x40 again (retry next tick); clear +0x5cb9 bit 0
    +0x5cb9 bit 1: clear; p.vt[0x6d4](p+0x292a4)  (FUN_0057d1d0)
    CeaseFireSender::cfs_Routine(p+0x7f36, p)                                @ FUN_00566820   (Z03: 0x243D)
    if p.deferredErr (+0x7f37): so_SendErrorCode(9, 0x34, err) = 0x2434 {u16 err}; deferredErr = 0   (Z03 §4)
    if p.nextSave (+0x2aa40) ≤ g_Now: WholeSaver.ws_save2DB(p, 1, 10)   (Z01 §8.4; every 600 s)
    minimon auto-use: if vt 0xe54 (+0x2abec or +0x2abed set) and +0x2abe8 ≤ g_Now: +0x2abe8 = g_Now + 10 (1 s);
        FUN_00564d40(p): on maps with CanItem (FieldList +0x9e), not trading (vt 0xb24), +0xfaa8.vt[0x10]() false,
        +0x18248 bit 3 clear, vt 0xae0 false: FUN_00564040 (12 HP slots +0x2abee) and FUN_00564230 (12 SP slots +0x2ac06)
        use the first matching inventory item via FUN_00561b80                 (minimon, Z13 / Z07)
```

### 2.4 Status packets and per-minute player checks

```pseudo
sp_SendHPinform(p)                                                  @ FUN_0056d9a0
    v = max(0, p.HP (vt 0x4e8) − p.vt[0x65c]())
    if v ≠ p.lastSentHP (+0x172d8): lastSentHP = v
        p ← 0x240E NC_BAT_HPCHANGE_CMD { u32 hp = v, u16 hpchangeorder = ++order (vt 0x7e8) }   (8 bytes)
    p.vt[0xa84]()
sp_SendSPinform(p)                                                  @ FUN_0056daf0
    if SP (vt 0x4ec) ≠ lastSentSP (+0x172dc): p ← 0x240F NC_BAT_SPCHANGE_CMD { u32 sp }
sp_SendLPinform(p)                                                  @ FUN_0056dc20
    if LP (vt 0xd90) ≠ last (FUN_00561410): store (FUN_00561420); p ← 0x245F NC_BAT_LPCHANGE_CMD { u32 nLP };
        then so_AllOfRange(…, so_ply_Send2WhoTargetMe): the same to everyone who targets p
sp_SendPartyMemberInform(p)                                         @ FUN_0056e340
    # keeps the party record's member → object pointer current; sends nothing itself
    if p.partyNo (vt 0x550) ≠ −1 and vt 0xa84() == 0 and the first byte of the party record (+0x29244) < 2 (meaning not traced):
        find p's charNo among the members (0x24-byte entries); repair entry.object = p;
        clear entry.object if it is closing or its charNo no longer matches
```

Client: 0x240E / 0x240F / 0x245F are handled by GameFrameWork (FUN_0049a1b0 / FUN_0049a240 / FUN_0049d840); fields match
the 2017 PDB structs `PROTO_NC_BAT_HPCHANGE_CMD { ulong hp; ushort hpchangeorder }`, `…SPCHANGE_CMD { ulong sp }`,
`…LPCHANGE_CMD { ulong nLP }`.

```pseudo
PerMinutePlayerChecks(p):                                           (inline; chargeditemcheck.ct_1MinuteFlow)
    p.sp_PlayTimeDay (+0x2a7c8)++; reset to 0 on a new day (ct_1DayFlow)   # minutes played today (name pdb2016; reader not found)
    sp_MiniHouseActivCheck(p)                                       @ FUN_00534fe0   (Z13)
    sp_DecorationActivCheck(p)                                      @ FUN_00534c60   (Z07)
    sp_SmallItemActivCheck<ItemInform_ActionItem>(p, p+0xf758, 15)                        @ FUN_005697e0   (premium emote items, Z04 / Z02 §9.3)
    charged buffs: rebuild p+0x2a5a0 from the template DAT_132728f8 and the buff list p+0x2a330 (FUN_00450e10, FUN_00487c50);
        p+0xe94 = 1; if a buff expired (+0x2a5ce): so_RecalcEquipParam (vt 0x35c), so_RecalcLastParam (vt 0x368)
    smo_NotifyParameterChange(1) (vt 0x34); so_ply_SendBoothSize (vt 0x3e0)
    sp_ChargedItemLimitCheck (vt 0x38) on the inventory (p+0x8e2c, kind 9), the equipment (p+0x7fd8, kind 8) and, unless
        mode 4/5, the mini-house bag (p+0xe778, kind 0xc)           (expiry of time-limited items, Z04)
    sp_SmallChargedItemLimitCheck(p, p+0xf758, 15)                  @ FUN_0056b900
        for each item of that bag with an expiry date (FUN_00643400): if expiry ≤ chargeditemcheck.ct_Current
        (compared year, month, day, hour, minute in that order): sp_SmallItemDelete
    wedding status (+0x5cd0 low nibble): 1 Checker::ApplicationLimit (FUN_0059f1b0), 2 Checker::DivorceLimit
        (FUN_005a1c90), 3 Checker::DelayLimit (FUN_0059f2d0)                                            (Z13)
```

### 2.5 Client packets are handled inside the player tick

```pseudo
ReceivePackets(p, handle):                                          (inline in FUN_0056c790)
    s = p.clientSession (+0x5e10); if s.state ∉ {1, 2}: skip
    up to 1000 times:
        r = s.io.vt[0xc]()
        0 (nothing left): if s.io flush (vt 0x28) fails: close s (FUN_005a66c0)
                          if !p.so_PacketBufferFlush (vt 0x2e8): log "Char as write fail ", s.state = 3
                          stop
        1 (one packet):   p.sp_LogoutWait.lastpacket (+0x17d48) = g_Now; s.vt[4](p, handle) → ClientSession.zbs_Parsing (Z02 §1);
                          if s.vt[0xc]() == 1: s.io.vt[0x24]() (release); sleepmanager.sm_PacketNumber++
        2 (malformed):    s.state = 3; log "Char as abnormal packet "; end of tick
```

So a player's requests are executed in that player's slot of the object walk, after its own timers; replies queued
in its send buffer go out at the next `so_PacketBufferFlush`. At most 1000 packets per player per tick.

### 2.6 Script triggers held by the player

`p+0x2a948 … +0x2a94c` is `ShinePlayer::observers_`, a vector of 0x18-byte `Observer` entries `{ vtable, master_
(owner object), next_ (IObserver), birth_, tick_ }` added by `registerObsersver` (vt 0xa2c FUN_00577f90) for the
NPCAction proximity triggers; class, event names and producers in §14.8 (the Lua chat / jump triggers are a separate
mechanism, §14.5).

```pseudo
ShinePlayer::notifyObservers(p, kind, a, b)       vt 0xa38                    @ FUN_00577c10
    for each entry e: r = e.vt[4](0, p, kind, a, b, 0, 0); if r & 2: destroy e and remove it
    # kind = IObserver::Event: 0 EV_IDLE every tick, 6 EV_TICK_PARTY after the skill check, 7 EV_LOCATION moved,
    # 4 EV_EMOTION; all values and producers in §14.8
ShinePlayer::unregisterObsersvers(p, owner)       vt 0xa34                    @ FUN_00577ba0
    remove the entries whose owner == owner
range check (so_Routine): for each entry whose owner is not closing:
    d² = distance² between p and owner (999999999 if either has no map, the maps differ or the layers differ)
    if d² > owner.vt[0xa54]()² (FUN_005551a0 returns 1000 → 1000 units): ShinePlayer::unregisterObsersvers(p, owner)
```

### 2.7 Player members used in this file *(pdb2016)*

Part R1 checked every `p+0x…` / `player+0x…` offset of this file against `ShineObjectClass::ShinePlayer` (0x2c058
bytes) of the NA2016 `Zone.pdb` (most are also in `docs/knowledge/S01-player-offsets.tsv`): all land on a member start
or inside a named sub-struct. The ones this item owns or relies on:

| Offset | Member | Used for (section) |
|---|---|---|
| +0x5cb8 / +0x5cb9 | `sp_MiscFlag` | teleport-reserve bit (+0x5cb9 bit 1, §2.3) |
| +0x5cd0 | `sp_WeddingData` (`PROTO_NC_CHAR_WEDDINGDATA_ACK`) +8 | wedding status nibble (§2.4) |
| +0x7e34 / +0x7f32 | `sp_CharBriefInfo` (`BriefInformationCharacter`) / its `bic_BriefInfo` | emote shown (§2.3) |
| +0x7f36 | `sp_CeaseFireSender` | 0x243D sender (§2.3) |
| +0x7f39 (+0x66 = +0x7f9f) | `sp_CharData` (`ZoneCharData`), `toclient.basedata.prisonmin` | prison minutes (§4) |
| +0x7fd8 … +0x10854 | `sp_Item` (bags: `ci_Equipment` +0x7fd8, `ci_Inventory` +0x8e2c, `ci_MiniHouse` +0xe778, `ci_ActionBox` +0xf758) | item checks (§2.4) |
| +0x172d8 / +0x172dc | `sp_LastStat` | last sent HP / SP (§2.4) |
| +0x173b4 / +0x173c0 | `sp_HPStoneManager` / `sp_SPStoneManager` | stone timers |
| +0x173d0 | `sp_NormalAttackDamageTick` | swing damage queue (§8.3) |
| +0x173e8 | `sp_QuestDiary` (`ShineQuestDiary`) | quest drops (§11.4) |
| +0x17d0c | `sp_SkillList` (`CharaterSkillList`) | toggle check (§2.1) |
| +0x17d48 | `sp_LogoutWait.lastpacket` | time of the last received packet (§2.5) |
| +0x17d7c (+0x4cc = +0x18248) | `sp_NPCProcess` | NPC-dialog state bit 3 (§2.4 minimon) |
| +0x29244 | `sp_LastPartyParam` (`PartyMemberInform`) | party status (§2.4) |
| +0x292a2 / +0x292a4 | `sp_Linkreserv` / `sp_TeleportReserv` | reserved link / teleport target (§2.3) |
| +0x29334 | `sp_LastItemPickup` | last pick time (§11.4) |
| +0x29634 | `sp_MoverUpgradeEffect` | mover recovery (§2.3) |
| +0x29638 | `sp_CharacterTitle` (`CCharacterTitleZone`) | title minute counters (§2.3) |
| +0x2a314 | `sp_EquipTick` (`Metronome`) | equipment check |
| +0x2a330 / +0x2a5a0 | `sp_ChargedItem` (`ChargedItemEffectList::ChargedItem`) / `ci_Effect` inside it | charged buffs, drop-up (§2.4, §11.2) |
| +0x2a760 | `sp_RideCast` | mount cast |
| +0x2a784 | `sp_TimerStr` (`TimeScheduler`) | timers |
| +0x2a7c8 | `sp_PlayTimeDay` | minutes played today (§2.4) |
| +0x2a804 | `sp_ProtocolLog` (`ProtocolLogger`, 16 × `{tick, locate, cmd}`) | the last 16 received packets (§2.2) |
| +0x2a90c | `sp_SoulCollect` (`SoulCollectStruct`) | soul-collect target / armed / until (§2.3) |
| +0x2a918 | `sp_EntrancePoint` | last good position of the block check (§9.2) |
| +0x2a948 | `observers_` (`std::vector<Observer>`) | script triggers (§2.6) |
| +0x2a9cc / +0x2a9d0 / +0x2aa28 | `m_pCaptivateAI` / `m_TargetSelect` (`MobTargetPlayerCaptivate`) / `m_pAITarget` | charmed-player brain (§7.7, §8.10) |
| +0x2aa40 / +0x2aa4c | `tAutoSaveTime` / `sp_ReviveReqProcessTime` | auto save, revive request |
| +0x2ab60 … +0x2abe4 | `sp_PetInfo`, `sp_Pet_BoothTick`, `sp_Pet_DanceTick`, `sp_Pet_DanceDataIndex` | pet reactions (§2.3) |
| +0x2abe8 / +0x2abec | `sp_UseItemMinimonCheckTime` / `sp_UseItemMinimon` (`USEITEM_MINIMON_INFO`; HP slots +2, SP slots +0x1a) | minimon auto-use (§2.3) |

---

## 3. GM events (`gGMEventManager`, DAT_14d42940)

The WM pushes `GM_EVENT_DATA` records (0xD00B add/update, 0xD00C delete; Z08 §13, W04 §16). The zone keeps them in
a vector (`GMEM_m_vecEventList`) of 0x958-byte `ZONE_GM_EVENT_DATA` entries: the 0x553-byte `GM_EVENT_DATA` (`Common`)
followed by a derived map table and five state bytes (layouts *(pdb2016)*; `GMEventManager` = 0x1014 bytes).
A GM event in the 2016 zone only **grants up to three abnormal states** to the players it matches; it changes no
rate (exp/drop) directly; any rate change comes from the abstates' own effects *(inferred from the only effect code)*.

| Offset | Field (`GM_EVENT_DATA` / `ZONE_GM_EVENT_DATA`) | Use |
|---|---|---|
| +0x000 | u16 nEventNo | key |
| +0x002 / +0x006 | i32 dStartTime / dEndTime | `time_t` (machine clock, which the WM sets via 0x0821) |
| +0x00a | u16 nRewardAbstateIndex[3] | abstate IDs (0xFFFF = none), looked up in `dic_abstate` (FUN_004013e0) |
| +0x010 | u8 bIsPlayerLevel[255] | by level (vt 0x4d8) |
| +0x10f | u8 bIsPlayerClass[64] | by class (vt 0x4dc) |
| +0x14f | u8 bIsMapID[1024] | by map id |
| +0x54f…+0x552 | u8 bIsField_KQ / _Battle / _ID / _Normal | add every map of that kind |
| +0x553 | u8 Zone_bIsMapID[1024] | effective map set = bIsMapID ∪ kind tables |
| +0x953 | u8 Zone_bIsFlagRunning | start ≤ now < end |
| +0x954 / +0x955 / +0x956 / +0x957 | u8 Zone_bIsFlagSetReward / Zone_bIsFlagLevel / Zone_bIsFlagClass / Zone_bIsFlagMap | has abstate / level filter / class filter / map filter (derived) |

The four map-kind tables are 1024-byte arrays inside the manager: `GMEM_bIsKQMapID` +0x10, `GMEM_bIsBattleMapID` +0x410,
`GMEM_bIsIDMapID` +0x810, `GMEM_bIsNormalMapID` +0xc10; the 1-s timer is `GMEM_dNextReflushRunStateTime` +0x1010. They
are filled only by the constructor:

```pseudo
GMEventManager::GMEventManager(mgr)                                @ FUN_0046dbd0
    # called once, by the CRT static initialiser `dynamic_initializer_for_'gGMEventManager'` FUN_0069ae70
    clear the vector and the four tables
    for id in 0..1023 with id < mapdatabox.mdb_maxmapid and mapdatabox.mdb_index[id] ≠ null:
        MapInfo.KingdomMap 0 → normal, 1 → KQ, 3 → ID (instance), 4 → battle   (2: none)
    GMEM_dNextReflushRunStateTime = g_Now
```

(original bug) Z09-B24: the static initialiser runs before `main`, but `MapDataBox::mdb_Load` FUN_0064ebf0 fills
`mapdatabox` only in the start stage `ZoneServer_zs_start_home` FUN_005adce0; at construction `mdb_maxmapid` is 0, so
all four tables stay empty. An event that selects maps by kind (`bIsField_KQ` … `bIsField_Normal`) still sets
`Zone_bIsFlagMap`, so the filter is on but matches no map: such events grant nothing unless `bIsMapID` also lists maps.
Likely intent: fill the tables after the map data is loaded *(the effect on the WM-side event tool is inferred)*.

```pseudo
GMEventManager::GMEM_ReflushZoneInfo(mgr, e)                (after 0xD00B)              @ FUN_0046d5c0
    e.hasAbstate = any nRewardAbstateIndex ≠ 0xFFFF
    e.levelFilter = any bIsPlayerLevel[i] == 1;  e.classFilter = any bIsPlayerClass[i] == 1
    e.map[] = 0; for each bIsField_X == 1: e.map |= mgr.kindTable[X]; e.mapFilter = 1 (even if the table is empty, Z09-B24)
    e.map |= bIsMapID; e.mapFilter = 1 if any bIsMapID entry is set
    if time() ∉ [start, end): e.active = 0
    else e.active = 1; for every player: GMEM_CheckConditionAndApply(p, e)
GMEventManager::GMEM_ReflushRunState(mgr)                   (main loop)                 @ FUN_0046d7e0
    every 1 s (mgr+0x1010 = g_Now + 10):
        for each e: if time() ∉ [start, end): e.active = 0
                    else if !e.active: e.active = 1; for every player: GMEM_CheckConditionAndApply(p, e)
    # an event that ends is only marked inactive; already granted abstates run out on their own timer
GMEventManager::GMEM_CheckAllConditionAndApply(mgr, p)                                           @ FUN_0046d8e0
    for each e: GMEM_CheckConditionAndApply(p, e)
    # called from sp_NC_MAP_LOGINCOMPLETE_CMD (FUN_00443390), sp_GainExp (FUN_0042d830, i.e. level change)
    # and so_ply_ClassChange (FUN_004521b0): a player who enters, levels or changes class gets the running events
GMEventManager::GMEM_CheckConditionAndApply(p, e)                                         @ FUN_0046d4d0
    if !(e.active and e.hasAbstate): return
    if e.levelFilter and !bIsPlayerLevel[p.level]: return          @ FUN_0046d260
    if e.classFilter and !(p.class < 64 and bIsPlayerClass[p.class]): return   @ FUN_0046d2a0
    if e.mapFilter and !(mapId(p) < 1024 and e.map[mapId]): return @ FUN_0046d300 (map id via FUN_004013d0 → FUN_0042ab10)
    GMEventManager::GMEM_RewardApply(p, e)                                      @ FUN_0046d380
        for each of the 3 abstate IDs that exists with a strength-1 block:
            keep = (end − time()) · 1000 ms when end is in the future, else the row's default keep time (block +0x2b)
            if p.vt[0x638](p, idx, 1, row, g_Now, 0, −1, keep, 0, 0) (set abstate, Z03 §2):
                so_AbnormalState_BitSet; strength = DAT_00875220 clamped to 1..40 (1 if outside);
                if a block exists for it: so_AbnormalState_Inform (vt 0x3f0) and so_AbnormalState_BroadcastSet
```

Note the level filter: `bIsPlayerLevel` has 255 entries indexed by the u8 level, so level 255 would read
`bIsPlayerClass[0]` *(inferred; levels stop far below)*.

---

## 4. Prison: the zone has no release timer

`so_Prison_Go` (vt 0x8a4 @ FUN_005b94b0, from WM 0x7C13, Z08 §12) links the player to map `EldPri` (a dead player is
first set to mode 1 with 30 % HP) and stores the minutes in `p+0x7f9f`; `so_Prison_End` (vt 0x8a8 @ FUN_005b9730)
clears them, resets the action timer and links the player to `RouN` (or the given map/coordinates). Its only caller is
the WM command `0x7C12 NC_ZONE_PRISON_END_CMD` (FUN_005a60f0). No zone routine counts the minutes down: the release
timer lives in the WM (W04) and the minutes reach the client at login (0x7C05, Z01). *(Answers Z08 knowledge §2.)*

---

## 5. Mob object core (`ShineMob`, `ShineNPC`, `ShineBandit`)

Class tree and pools: Z01 knowledge §2–§3 (mob type 5, NPC 4, bandit 8, servant 10, pet 12 all derive from `ShineMob`).
Mob death, experience and drops are in Z03 §8.1–§8.2; aggro, brain and targets are part 3 (§6); weapons and skills part 4;
movement part 5; regen breeders part 6. This section covers the data the mob is built from, spawning, the per-tick
routine and the NPC and bandit variants.

### 5.1 Mob data: `MobDataBox` (`mobdatabox` DAT_14d44a38)

`MobDataBox::mdb_Load` @ FUN_00641e60 (start stage `home`, Z01-core §2.3) loads eleven SHN tables into `BinaryDataBox`es
inside the box, checks that MobInfo, MobInfoServer, MobSpecies and QuestSpecies have the same row count and the same ID in
every row ("MobDataBox::mdb_Load : Mob number mismatch" / "DataOrder mismatch", fatal), then builds one **entry per mob ID**
(`mdb_index` box+0x65c, `(maxID + 1) × 0x34` bytes; max ID `mdb_maxmobhandle` box+0x664; name → ID index `mdb_btree`
box+0x668, `BTree::operator[]` FUN_0063cc30(&DAT_14d450a0, name)). `MobDataBox` (0xa7c) holds the eleven `BinaryDataBox`es in
`mdb_BinData` (`mobinf`, `mobinfserv`, `mobweapon`, `mobspec`, `questspec`, `mobkillannounce`, `mobkilllog`, `moblifetime`,
`mobKillablePermission`, `mobRegenAni`, `groupAbstate`) and the GroupAbState multimap at +0xa6c *(pdb2016)*. Entry =
`MobDataBox::MobDataBoxIndex` (0x34); its member names are in the first column:

| Entry offset | Content | Filled by |
|---|---|---|
| +0x00 `data` | → MobInfo row (client table, `struct MobInfo` 0x6c *(pdb2016)*: `ID +0, InxName[32] +2, Name[32] +0x22, Level +0x42, MaxHP +0x46, WalkSpeed +0x4a, RunSpeed +0x4e, IsNPC +0x52, Size +0x53, WeaponType +0x57, ArmorType +0x5b, GradeType +0x5f, Type +0x63, IsPlayerSide +0x67, AbsoluteSize +0x68`) | mdb_Load |
| +0x04 `serv` | → MobInfoServer row (0xa7 bytes, see below) | mdb_Load |
| +0x08 `weapon` / +0x0c `weaponnumber` | MobWeapon list: array of `_MobWeaponIndex { MobWeapon* weapon, u16 skill, ABSTATEINDEX abstate +8 (0x318 = none) }` (0xc each) / count | `mdb_SkillStore` @ FUN_00642630 |
| +0x10 `species` | → MobSpecies row (`ID u16, MobName[33], 3 more names`) | mdb_Load |
| +0x14 `registindex` | u16 mobresisttable row index (from MobInfoServer.ResIndex; 0xFFFF = "-") | mdb_Load, `mobresisttable` table DAT_150ba618 (FUN_00644e80) |
| +0x18 `questspecies` | → QuestSpecies row (`ID u16, MobGroupName[33] × 5`) | mdb_Load |
| +0x1c `p_mobkillannounce` | → MobKillAnnounce row (`MobID u32, TextIndex u32`), or 0 | mdb_Load |
| +0x20 `p_mobkilllog` | → MobKillLog row (`MobID u32`), or 0 | mdb_Load |
| +0x24 `p_MobLifeTime` | u32 MobLifeTime.LifeTime (seconds; row `MobLifeTime {MobIndex[32], u16 LifeTime +0x20}`), 0 = none | mdb_Load |
| +0x28 `MobIndexFlag` | bit 0 `IsBufferToBoss` (set by `ServentBuffBossTable::sbbt_Load` FUN_005d4580, read by `ShineMob::so_Routine` §5.4), bit 1 `MobAutoAction_Damaged` (set by `MobAutomaticActionList::maal_Load` FUN_005d49f0, read by `ShineMob::so_DamagedBy` FUN_00431750); cleared at load | §27.6 loaders |
| +0x2c `pRegenAni` | → MobRegenAni row (`MobIDX[32], RegenTime u16 +0x20 (ms), GroupAbStateIDX[32] +0x22, IsAggro u8 +0x42`), or 0 | mdb_SkillStore |
| +0x30 `nRegenAbstateGroup` | GroupAbState group number of the RegenAni row (−1 = none) | mdb_SkillStore |

`mdb_SkillStore(skillNames, abstateNames)` @ FUN_00642630 (start stage `sleep`, "MobDataBox link") runs over MobWeapon twice
(count, then fill), resolving `Skill` (+0x25, "-" = none) and `StaName` (+0x71) by name; unknown names are logged and the
weapon keeps 0xFFFF / 0x318. GroupAbState rows are grouped by `GroupAbStateIDX` into a multimap `box+0xa6c` (group number →
row; `AbstateIDX` +0x20, `Strength` u8 +0x40). Each MobRegenAni row is attached to its mob (duplicates and unknown names are
fatal) and its group is looked up by name.

MobInfoServer.shn (2016, 0xa7 bytes; column names from the SHN header, equal to the members of `struct MobInfoServer` *(pdb2016)*, which types `EnemyDetectType` as enum `EnemyDetect`, `MobKillInx` as `MobKillType`, `MobRaceType` as `MobRace`): `ID u32 +0, InxName[32] +4, Visible u8 +0x24,
AC u16 +0x25, TB +0x27, MR +0x29, MB +0x2b, EnemyDetectType u32 +0x2d, MobKillInx u32 +0x31, MonEXP u32 +0x35, EXPRange u16
+0x39, DetectCha u16 +0x3b, ResetInterval u8 +0x3d, CutInterval u16 +0x3e, CutNonAT u32 +0x40, FollowCha u32 +0x44,
PceHPRcvDly u16 +0x48, PceHPRcv +0x4a, AtkHPRcvDly +0x4c, AtkHPRcv +0x4e, Str +0x50, Dex +0x52, Con +0x54, Int +0x56, Men +0x58,
MobRaceType u32 +0x5a, Rank u8 +0x5e, FamilyArea u32 +0x5f, FamilyRescArea u32 +0x63, FamilyRescCount u8 +0x67, BloodingResi
u16 +0x68, StunResi +0x6a, MoveSpeedResi +0x6c, FearResi +0x6e, ResIndex[32] +0x70, KQKillPoint u16 +0x90, Return2Regen u8 +0x92,
IsRoaming u8 +0x93, RoamingNumber u8 +0x94, RoamingDistance u16 +0x95, RoamingRestTime u16 +0x97, MaxSP u16 +0x99, BroadAtDead
u8 +0x9b, TurnSpeed u16 +0x9c, WalkChase u16 +0x9e, AllCanLoot u8 +0xa0, DmgByHealMin u16 +0xa1, DmgByHealMax u16 +0xa3,
RegenInterval u16 +0xa5`. `EnemyDetectType` values = enum `EnemyDetect` *(pdb2016)*: 0 ED_BOUT, 1 ED_AGGRESSIVE, 2 ED_NOBRAIN,
3 ED_AGGRESSIVE2, 4 ED_AGGREESIVEALL, 5 ED_ENEMYALLDETECT (2016 data: 220 / 1872 / 728 / 12 / 1 / 9 rows; the NOBRAIN rows
are shop NPCs and gates). The columns used by this section are named below; the AI columns are read in part 3.
Columns with no member access anywhere in the PDB export (part R1, `rg` over `re-data/exports/zone-pdb/decomp.c`; a raw
offset read is not excluded): `PceHPRcvDly`, `PceHPRcv`, `AtkHPRcvDly`, `AtkHPRcv`, `BloodingResi`, `StunResi`,
`MoveSpeedResi`, `FearResi`, `Rank`, `AllCanLoot`, `DmgByHealMin`, `DmgByHealMax`. The FiestaHeroes MobInfoServer page
calls the four regen columns "not used" and the four `*Resi` columns "replaced by MobResist, not used" *(fh-doc)*; mob
HP regeneration comes from `sm_DuringRecover` (§6.5) instead.

`MobDataBox::mdb_CanIKill(mobId, identity)` @ FUN_006424c0 — may this kind of attacker kill the mob:

```pseudo
    if mobId == 0xFFFF: return true
    k = MobInfoServer.MobKillInx                               # enum MobKillType (pdb2016): 0 MKT_DEFAULT, 1 MKT_ONLYSCRIPT, 2 MKT_MOB
    if k >= 3: log "…Invalid MobKillType"; return false
    row = MobKillAble[k]                                       # MobKillAble.shn { MobKillInx, Cheat u8, Mob u8, User u8 }
    identity 0 → row.Cheat, 1 → row.Mob, 2 → row.User, 3 → true, other → log "Unknown identity", true
```

2016 rows: DEFAULT {1,1,1}, ONLYSCRIPT {0,0,0}, MOB {0,1,0}. Callers: player attacks and skills, `so_mobile_ICanDamageTo`,
the mob target selectors and the magic-field damage (Z03, part 3).

Other mob tables loaded elsewhere and read in this part:

- `MobConditionServer.shn` → `MobConditionChecker::MCC_DataRead` @ FUN_004b0460 into `gMobConditionChecker` DAT_1328bcd0 (mob ID →
  vector of conditions, `MCC_GetCondition` FUN_004b0140(&gMobConditionChecker, mobId); §5.6). Only `MC_Type` 0 is accepted (enum
  `MobCondition_Type` *(pdb2016)*: `MCT_HP = 0` is the only member before `MAX_MOBCONDITION_TYPE`); any other type fails with "Memory Alloc Fail" and the
  whole table is dropped. Consecutive rows of the same mob form one vector, in file order.
- `MobDeadCount` (`mdc_Clear` @ FUN_004b07b0, `mdc_Count` @ FUN_004b0820, `mdc_DeadCountGet` @ FUN_004b08f0, created by
  `MobDeadCount::mdc_Init` FUN_004b09f0): one u16 counter per mob ID, incremented by `ShineMob::so_KilledBy` (Z03 §8.1); readers are the map
  scripts (part 14–16).
- `MobAutoAction.shn` belongs to `BossFieldContent::MobAutomaticActionList::maal_Load` @ FUN_005d49f0 (§27.6).

### 5.2 Mob members (offsets from the object start)

Checked in part R1 against `ShineObjectClass::ShineMob` (0x2568 bytes, base `ShineMobileObject` 0x1ea8, base
`ShineObject` 0x167) of the NA2016 `Zone.pdb` *(pdb2016)*: every offset below is a member start (or inside a named
sub-struct). Column "Member" = the PDB name; "Meaning" = what the 2016 code does with it.

| Offset | Member *(pdb2016)* | Meaning |
|---|---|---|
| +0x4e / +0x56 | `so_slantedlist.LayerRegistInfo`: `LayerRegNumberUnion` (u64, +0x4e/+0x52) / `nViewType` (+0x56) | layer ids / "visible in all layers" flag (Z03 `SameLayer`); NPC.txt NPCs set `nViewType` = 1 (`so_SetLayerObjectViewType` FUN_0054aae0) |
| +0x66 → / +0x6a → | `so_LocateInfo.location` / `.direct` | position `{x, y}` / u8 direction (degrees / 2) |
| +0x6e / +0x76 → | `so_layer.templyr` / `so_layer.layer` (`SubLayer::Layer {l_Main, l_Sub +4}`) | sub-layer (`so_SubLayer_CanSee`, Z02 §5): `l_Sub` 0 normal, 3 hidden (StaGMHideMode) |
| +0x7a | `so_Field` | → FieldMap |
| +0x7e | `so_AIScript` (`LuaAi`, 0xe4): `AIScript` (+0x7e, `LuaScriptScenario*`), then 8 `std::string` function names `Entrance` +0x82, `NPCClick` +0x9e, `NPCMenu` +0xba, `MobDamaged` +0xd6, `ObjectDied` +0xf2, `NPCAction` +0x10e, `MobAttack` +0x12a, `RankingValue` +0x146 | AI Lua script of the mob type (`g_AIScriptMobContainer` DAT_14d712d0, keyed by MobInfoServer.ID); `Entrance` = MobInfo.InxName; the others are set by scripts (`cAIScriptFunc`, §14.3); all cleared by vt 0xc14 `so_InitAIScript` FUN_00558c80 |
| +0x180 | `smo_DeadCheck` (`DC_DeadCause`: 0 LIVE, 1 DOT, 2 ATTACK, 3 ATTACK2, 4 SELFKILL, 5 SKILL) | cause of death |
| +0x184 / +0x186 | `smo_WhoKillMe` / `smo_WhoClickMe` | killer handle (`ShineMobileObject::so_KilledBy`) / last clicker |
| +0x18c…+0x1cb | `smo_MoveManager` | MoveManager (§9.1): +0x18c state, +0x1ac active |
| +0x1cc | `smo_Abstate` | abstate container (Z03) |
| +0xe98 / +0xe9c → | `smo_Mode.tempmode` / `smo_Mode.mode` | mode byte (`GetMode` vt 0x484): 0 while spawning, 2 alive, 3 dead |
| +0xea0…+0xeac | `smo_Recover {lasthp, lastsp, maxhp, maxsp}` | +0xea0 / +0xea4 set to g_Now at spawn (last HP / SP recovery time, §6.5); +0xea8 / +0xeac MaxHP (vt 0x4f0) / MaxSP (vt 0x4f4) |
| +0xfc0 | `smo_Param` (`Parameter::Container`) | stat matrix (Z03 knowledge §2); base layer from MobInfoServer (`Parameter::Container::c_StoreMob`, §5.3) |
| +0x1d84 | `smo_SkillCast` | cast block (Z03 §5) |
| +0x1db0 | `smo_SceneMoveManager` | scenario move queue (§9.3) |
| +0x1e74 | `smo_RulesOfNormalAttack` | rule set: `RulesOfEngagementNormalPY` (no weapon or first weapon `HitType` 0) or `…NormalMA` |
| +0x1e78 | `smo_Flag` bits: 0 `Retrate`, 1 `DuringFlying`, 2 `InFear`, 3 `DeadProcessComplete`, 4 `InSkillShift`, 5 `InCaptivate`, 6 `ChineCast`, 7 `DamageAbsorb` | bit 0 set = invalid position (out of map; a player is kicked, §2), bit 2 Fear, bit 3 killed, bit 4 blast armed, bit 7 (vt 0xbf0) |
| +0x1e8c…+0x1e9f | `smo_moveState` (`MoveStateStruct {eMoveState, PrevLocation +4, nStartTime +0xc, nCheckTime +0x10}`) | movement detector (`smo_CheckMoveState` FUN_0055d610): 1 = moving, last position, time of the last change, next check |
| +0x1ea8 / +0x1eac | `sm_WanderChat` (`Metronome {m_NextTick, m_TickInterval}`) | wander-chat timer `g_Now + t` / `t`, t = interval of the mob ID's `mobchatman.mcm_Wander` element (DAT_0084cc8c[mobId].vt[0](), ms → tenths; 10⁹ ms without a PIECE row) (§8.6) |
| +0x1eb0 | `sm_TargetAnalyser` (`TargetAnalyser_Player`) | (not read by the mob code of §5–§8) |
| +0x1eb8 / +0x1ebc | `sm_RoamingPath` / `sm_CurrRoamInterval` (`MobRoamingPoint`: `pointer`:15, `direct`:1) | MobRoam path and position on it (§9.5) |
| +0x1ec0 | `sm_MobRegnum` (ulong) | 8th argument of vt 0x6e0: the global `mobregnum` (DAT_0da2932c, never written → **0**) for breeder spawns (§10.4), −1 for NPC.txt NPCs and script / Lua spawns; it does not identify the breeder |
| +0x1ec4 / +0x1ec8 | `sm_HP` / `sm_SP` | HP / SP |
| +0x1ecc | `sm_MobBriefInfo` (`BriefInformationMob` 0xac: `bim_pack`, `bim_array`[152], `bim_nc`, `bim_BriefInfo` +0x1f74) | the mob's own brief-info packet 0x1C08 `NC_BRIEFINFO_REGENMOB_CMD`; its payload pointer is +0x1f74 (§5.3) |
| +0x1f78 / +0x1f84 | `sm_LoginLoc` (`LoginLocation {currentmap Name3, currentcoord}`) | char map[12] (vt 0x4bc `so_LoginLocation`), the map the mob is spawned on / spawn x, y, dir copied from the brief (vt 0xf6c) |
| +0x1f90 | `sm_MobDataBox` | → MobDataBox entry (vt 0x70c) |
| +0x1f94 | `sm_MobLevel` | u8 level (MobInfo.Level unless the spawn gives one) |
| +0x1f98 | `sm_ReadyWeapon.nextblast` (`vector<ulong>`) | per-weapon cooldown: "usable again at" g_Now (one u32 per MobWeapon, zeroed at spawn; §7.4) |
| +0x1fa8 | `sm_ReadyWeapon.weaponindex` | current weapon index (−1 at spawn / none; §7.4) |
| +0x1fac / +0x1fb0 | `sm_ReadyWeapon.attacksequence` / `.attacksequenceindex` | `MobAttackSequence` record of the mob ID (`mobattseq` DAT_0d76e9e8, `mas_Find` FUN_0043f6e0) / sequence position (§7.6) |
| +0x1fb4 / +0x1fb6 | `sm_ReadyWeapon.NextSaveSkill` / `.bUseNextSaveSkill` | chained NextSkill skill ID (0xFFFF none) / "do not advance the sequence after this use" (§7.6) |
| +0x1fb8 / +0x1fba | `sm_ReallyDead.senddeadpacket` / `.attacker` | death broadcast sent / killer handle (Z03 §8.1) |
| +0x1fbc / +0x1fc0 | `sm_DeadTime` / `sm_DeadDelayTime` | death time / extra corpse time (vt 0xc3c, `cSetDeadDelayTime`) |
| +0x1fc4 / +0x1fc8 | `sm_ArtificalIntelligence` (`MobTacticElement::MobActionArgument`, 0x324): `maa_MobHandle` (u16) / `maa_Mob` | brain context: the mob's own handle / self |
| +0x1fcc | `maa_TargetSelect` (`Selector`, 0x26c): `targetlist` (`MobAggroManager`, 10 `MobTargetStruct` in `mam_Array` +0x18), then `bout` +0x2124, `aggresive` +0x213c, `nobrain` +0x2174, `aggresive2` +0x218c, `aggresiveall` +0x21c4, `aggresiveNoLevel` +0x21fc | aggro list followed by one selector object per `EnemyDetect` value (§6.1) |
| +0x2234 | `maa_TargetSelect.selector` | → active target selector (§6.1; vt +8 per tick, +0x14 reset) |
| +0x2238 | `maa_MobActionStruct` (`Actor`, 0xb0): `inmove`, `inmove_cancelable` +0x2240, `inmove_chase` +0x2248, `wander` +0x2260, `attack` +0x227c, `chase` +0x2294, `backstep` +0x229c, `avoidoverlap` +0x22a8, `waitskillend` +0x22b0, `swingdamage` +0x22c0, `turning` +0x22d0 | tactic set (§7.1), bound to the target cell `sm_MyTarget` +0x24e0 by `Actor::SetTargetPoint` FUN_004b8c80 at spawn |
| +0x22e4 | `maa_MobActionStruct.action` | current tactic state (`MobActionWander`, `MobActionRoaming` 0x84cfc4, `MobActionNoBrain` 0x84cfc8) |
| +0x22e8 | `sm_Breeder` | the spawning `MobBreeder` (10th argument of vt 0x6e0; §10.2: +0x4c spawn time set by RegenComplete, +0x50 death time set by `so_KilledBy`), 0 for other spawns |
| +0x22ec | `sm_Guild` | guild number shown with the mob (`so_mob_SetGuildRegNum`, §5.8) |
| +0x22f0 | `sm_HitMeList` (`HitMeList::EnemyList`) | damage list (Z03 §8.2) |
| +0x249c / +0x24a4 | `sm_RegenLoc` / `sm_LastHittedLoc` | spawn point / "last hit" point; both = spawn position at spawn |
| +0x24ac | `sm_Flag` bits: 0 `MobAggro`, 1 `HealAtPiece`, 2 `InNormalAttack`, 3 `JustAttacked` | bits 0, 1 set at spawn; 2, 3 cleared |
| +0x24ae | `sm_CurrentTarget` | current fight target handle (`so_mob_CurrentTarget` vt 0xb78, §6.5); 0xFFFF at spawn |
| +0x24b0 | `sm_DuringFuncIndex` | battle state: 0 idle, 1 battle (`sm_DuringBattle`), 2 recover (`sm_DuringRecover`) (§6.5) |
| +0x24b1 / +0x24b5 | `sm_FamilyList.fml_Prev` / `.fml_Next` | family ring (prev / next mob of the same family; self when alone); vt 0x744 returns +0x24b1 |
| +0x24bc, +0x24c0, +0x24c4 | `sm_Rescue {bit (bitrequest, bitscreamack, bitrescuechat), rescuewho, lasthp}` | rescue flags (bit 0 healed / not asking, bit 1 called by a dying friend, bit 2 help chat said), → friend to help (0), friend's last seen HP (60000) (§6.6) |
| +0x24c8 | `sm_WeaponUseRate` (`vector<u16>`) | script weapon rates (§8.2) |
| +0x24d8 / +0x24da | `sm_RoamingInfo` (`isroaming`:1, `maxroamingnum`:7, `roamingnum`:8 / `maxroamingdist` u16) | `IsRoaming`, `RoamingNumber`, position count / RoamingDistance |
| +0x24dc / +0x24e0 / +0x24e4 / +0x24e5 | `sm_LastTarget` / `sm_MyTarget` / `sm_bSendTargetInfo` / `sm_bTarget` | last broadcast target / current target (vt 0xa04) / target-dirty flag / target order (vt 0xa08) |
| +0x24e8 | `triggers_` (`vector<NPCAction::Trigger>*`) | NPCAction triggers of this mob ID (`triggerDic` DAT_14d50784, `NPCAction::Util::loadTriggers` FUN_005c4420), or 0 |
| +0x24ec | `m_LifeTimer` (`TickTimer {m_CurDelayTime, m_DelayTime, m_bEnable, m_PrevCheckTime}`) | lifetime timer (vt 0xabc `so_mob_SetLifeTime` FUN_0055e5b0) |
| +0x24fc | `sm_StaNumberForDrop` | abstate level at death, picks the drop list (`smo_BossAbstateSet` / `sm_BossAbstateGet`, §8.9, §11.2) |
| +0x2500 | `tNextRoamingWaitTime` | resting until (vt 0xb34 / 0xb38, §7.1) |
| +0x2504 / +0x2508 | `sm_MaxHPAtMobInfo` / `sm_MonEXPAtMobInfo` | script overrides MaxHP / MonEXP (0 = table) |
| +0x250c | `sm_IsItemDrop` | u8 drops enabled (1; `cSetNPCIsItemDrop` → vt 0xbb0 `so_mob_IsItemDropSetAtScript` FUN_004aa810) |
| +0x250d | `sm_MobResist` (struct `MobResist`, 0x34) | copy of the mob's MobResist row |
| +0x2544 | `sm_EnemyDetect` (enum `EnemyDetect`) | `MAX_ENEMYDETECT` (6) at spawn, then the MobInfoServer value (§6.1) |
| +0x2548 / +0x254c / +0x2550 / +0x2554 | `sm_MobIsPlayerSide` / `sm_WalkSpeedAtMobInfo` / `sm_RunSpeedAtMobInfo` / `sm_HPRegen` | −1 at spawn; script WalkSpeed / RunSpeed / HPRegen (−1 = table) |
| +0x2558 | `sm_ItemDropMobID` | u16 0xFFFF; drop table of another mob ID (`cSetItemDropMobID`, §11.8) |
| +0x255c | `sm_pMobConditionList` | → MobConditionServer vector of the mob ID (or 0) |
| +0x2560 / +0x2564 | `sm_tRegenAniTime` / `sm_bRegenAniComplete` | spawn time / "regen animation over" flag (AI waits for it) |
| NPC +0x2568 | `ShineNPC::sn_FromTable` | u8 "from NPC.txt" (`so_npc_FromTable` vt 0xa80 FUN_004b19b0) |
| servant +0x2568…+0x2580 | `ShineServant` members (part 8b) | servant row, master, follow target, explosion state / next time / count left (§8.8) |
| bandit +0x2568 | `ShineBandit::sb_MobBriefInfo` (`BriefInformationCharacter`, 0x102) | bandit brief; +0x2666 = `bic_BriefInfo` → its payload (`+0xc2` u8 object type, §5.10) |

### 5.3 Spawn: `so_mob_Regenerate` and `so_mob_RegenComplete`

Every spawner (breeders, scripts, NPCManager, GM commands) allocates a pool slot and calls vt 0x6e0:

```pseudo
ShineMob::so_mob_Regenerate(m, Name3* map, x, y, dirDeg, u16 handle, u16 mobId,
        PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD* banditBrief, ulong mobRegnum, ShineObject* familyLeader,
        MobBreeder* breeder, int level, u8 _, u64 layerRegNum) → FM_MarkingError (0 = ok)      @ FUN_004b41b0
    # parameter types from the PDB signature (pdb2016); the names are ours, after the members they fill
    m.sm_MobRegnum (+0x1ec0) = mobRegnum;  m.sm_LoginLoc.currentmap (+0x1f78) = map;  mode = 0
    m.sm_EnemyDetect (+0x2544) = MAX_ENEMYDETECT (6)
    m.vt[0xf70](handle, mobId, banditBrief)     # brief: FUN_004b1120 → FUN_004b0d20: handle, mobid, flagstate 0,
                                                #   sAnimation "", nAnimationLevel 0, bRegenAni 0; entry = mobdatabox[mobId]
    m.pos = (x, y);  m.dir = (dirDeg / 2, +180 if negative)
    entry = mobdatabox[mobId]   (null when the ID is out of range or the row ID differs: "MobDataBox::operator [] :Invalid mob index")
    m.level = level >= 1 ? level : MobInfo.Level
    m.roaming (+0x24d8/+0x24da) from MobInfoServer.IsRoaming / RoamingNumber / RoamingDistance
    m+0x1eb8 = 0;  aggro list reset unless the current target is a pet (type 12)
    sm_SetBrain(m)                                                                  # part 3
    m.vt[0xf6c]()                                # spawn x/y/dir copied from the brief
    m.sm_Breeder (+0x22e8) = breeder
    if (r = so_MapMarking(m, 0)) != 0: return r                                     # §5.7
    brief.flag (vt 0x4a0, 0x63 bytes) = template DAT_13272928
    remove every abnormal state (ListEraser over +0xcb0 of the abstate container)
    if entry.regenAni == null:
        regenAniOver = 1
        if g_AbState[291] (StaImmortal): set 291, strength 1, keep 5000 ms, how 8   # 5 s spawn protection
    else:
        brief.bRegenAni (+0x94) = 1;  regenAniOver = 0
        for each GroupAbState row of entry.regenGroup:   set that state (strength = row.Strength,
                                                        keep = MobRegenAni.RegenTime)   ("…as_FromIndex : Invalid skill idx" if ≥ 0x318)
    m.layer = (layerA, layerB);  m+0x163 = 0
    m.vt[0x6f4](handle)                          # so_mob_RegenComplete, below
    m.HP = MaxHP();  m.SP = MaxSP()
    stat matrix base layer from MobInfoServer (FUN_0043c550)
    m+0x1fb4 = 0xFFFF;  m+0x1fb6 = 0;  weapon vector resized to entry.weaponCount and zeroed;  m+0x1fa8 = −1
    family ring: with a leader, insert m after the leader's ring position (logs "…Null FamilyList - Leader / member");
                 else m.prev = m.next = m
    m.rules (+0x1e74) = (no weapon list or weapon[0].HitType == 0) ? RulesOfEngagementNormalPY : RulesOfEngagementNormalMA
    m.corpseExtra (+0x1fc0) = 0
    m.conditions (+0x255c) = MobConditionServer vector of mobId
    movement detector reset (FUN_0055d5e0)
    return 0
```

`MaxHP()` (vt 0x4f0, FUN_005568b0) = `(override +0x2504 or MobInfo.MaxHP) × stat +0xa1c / 1000`, at least 1, cached in
+0xea8 (the NPC version FUN_00557c10 has no minimum). `MaxSP()` (vt 0x4f4, FUN_00556920) = MobInfoServer.MaxSP → +0xeac.

Base stat layer (FUN_0043c550, from a zero template): STR = Str, END = Con, DEX = Dex, INT = Int, SPR = Men, stat 7 AC = AC,
9 TB = TB, 12 MR = MR, 14 MB = MB, the three rate stats 19–21 = 1000, everything else 0.

```pseudo
ShineMob::so_mob_RegenComplete(m, handle)   (vt 0x6f4; NPC: FUN_00442ba0 just calls this)     @ FUN_004424f0
    overrides MaxHP / MonEXP = 0;  dropsEnabled = 1;  resist block = MobResist row (or zeros)
    m+0x1e88 = 2;  m+0x2544 = 6;  speed / HP-regen overrides = −1;  m+0x168 = 0;  m+0x2284 = 0;  guild = 0;  firstAttacker = 0xFFFF
    AI script: m.script = DAT_14d712d0[MobInfoServer.ID] (or none), m.funcName = MobInfo.InxName
    MobActionAttack.maa_SkillFromScriptClear(m+0x227c)
    brief.nKQTeamType (+0x93) = 2 (none)  (vt 0xe04)
    if MobInfoServer.Visible == 0:                             # "so_mob_RegenComplete2": hidden mobs (InvisibleMan, EventManagerA/Z …)
        sub-layer = 3;  set StaGMHideMode (288), keep eternal                      # nobody is told
    else:                                                      # "so_mob_RegenComplete1"
        sub-layer = 0
        g_SightDistSq = MapInfo.Sight² of the field (−1 = unlimited on special fields; 0 without a field)
        so_AllOfRange(m, so_ExchageBriefInfo)           # brief info both ways with everything in sight (Z02 §5)
    deathSent = 0;  killer = 0xFFFF
    tactic state = roaming flag ? MobActionRoaming (and +0x24d9 = 0) : MobActionWander.maw_MetronomeReset()
    if EnemyDetectType == 2 (ED_NOBRAIN): tactic state = MobActionNoBrain
    brain context = { self, handle };  mode = 2 (alive)
    stat matrix reset, base layer, c_MakeTotal;  HitMeList cleared
    move state cleared (+0x18c…+0x1b8), invalid-position bit cleared, cast cleared
    m+0xea0 = m+0xea4 = g_Now;  spawn point = return point = position;  battle state = 0
    m+0x1fac = DAT_0d76e9e8.find(mobId);  m+0x24e8 = NPCAction trigger of mobId
    killer handle (+0x184) = −1;  so_RecalcAbstateParam;  rescue state reset;  m+0x24c4 = 60000
    m+0x1d70 = (+0xfbc).vt[0x3c]();  smo_ply_WeaponTitleSet(0xFFFF)
    m+0x1ea8 = g_Now + behaviour[mobId].vt[0]() / 100
    breeder.lastSpawn = g_Now
    flags1e78 &= ~(bit1 | bit3 | bit4);  target selector reset;  target / last target / dirty = 0;  flags1e78 bit 7 = 0
    brief.bRegenAni = 0 (after the brief went out);  m.spawnTime (+0x2560) = g_Now
```

The brief packet goes out with `bRegenAni = 1` for mobs with a MobRegenAni row. The client handler of 0x1C08
(`GameFrameWork::On_NC_BRIEFINFO_REGENMOB_CMD`, client FUN_004a9a90) adds the mob and its minimap mark, adds a KQ mob mark
on KQ maps and a KQ team mark when `+0x93 nKQTeamType ≠ 2`, and plays the "Regen" effect for a mob whose MobInfo.IsNPC is 0.
2016 confirms the 2017 PDB offsets of `PROTO_NC_BRIEFINFO_REGENMOB_CMD` from +0x72 on with the `flag` union 4 bytes shorter:
`sAnimation[32] +0x72, nAnimationLevel +0x92, nKQTeamType +0x93, bRegenAni +0x94` (2017: +0x76…+0x98).

### 5.4 `ShineMob::so_Routine` (every tick)

```pseudo
ShineMob::so_Routine(m, _, handle)                                               @ FUN_0056baa0
    if mode == 0: return 1                                     # not spawned yet
    if the position is outside the field: log "fm_IsInFieldSize : Mob"; flags1e78 |= 1
    MobConditionServer step (FUN_00554420, §5.6)
    ShineMobileObject::so_Routine(m)                           # §5.5 (abstates, movement, casts)
    if flags1e78 & 1:  so_Unmark(0, 1, 3); som_FreeObject(m, reason 7); return
    if mode != 3 and m.npcAction (+0x24e8):                    # NPCAction proximity triggers (§16)
        so_AllOfRange(m, range = MobInfoServer.DetectCha, NeighborhoodChecker(m.npcAction))   @ FUN_005c2ee0 / FUN_005c2fe0
    regen animation over? (FUN_0055e760): if no RegenAni row or g_Now > spawnTime + RegenTime/1000·10: regenAniOver = 1
    if m has StaImmortal (291) or StaAdlFLoussierIMT (499):
        run the AI Lua function only (below); return           # no AI while protected
    if battle state == 1: sm_DuringBattle(m)  elif == 2: sm_DuringRecover(m)        # part 3
    if flags1e78 & 4 (Fear): run the AI Lua function only; return
    if m.rescue (+0x24c0): so_RescueRoutine(m)                                       # part 3
    if mode == 3 (dead):
        if not deathSent:
            to sight (incl. players only, so_AllOfRange … 1):
                0x244A NC_BAT_REALLYKILL_CMD { u16 dead = m.handle, u16 attacker = m.killer (+0x1fba) }   # size 6
            deathSent = 1
        if m.deadAt and g_Now − m.deadAt >= (m.corpseExtra · 5 + 50) · 2:          # = 10 s + corpseExtra seconds
            so_Unmark(0, 1, 3); som_FreeObject(m, reason 8)                         # respawn is the breeder's job (part 6)
        run the AI Lua function; return
    if m.entry == null: return
    if MobInfo row flag bit 0 of entry+0x28: sm_IBuffToBuffee(m)                     # part 4
    r = 2
    if m.script and clockwatch.cw_IsReset (DAT_14d41a7c, set by the first WM time message FUN_004511a0; our earlier name g_AIScriptOn):
        r = LuaScriptScenario.lss_Routine(m.script, m.funcName, ctx{handle, field})  @ FUN_00507200 (ctx FUN_005d6ef0, result ctx+8)
            # calls the global Lua function named like the mob (MobInfo.InxName);
            # error → "LuaScriptScenario::lss_Routine : function call error"
    if regenAniOver and alive and HP != 0 and (not MoveManager.active or move state != 3):
        brain context: maa_Mob = self, maa_MobHandle = handle
        if r == 2:                                             # 2 = "let the built-in AI run"
            m.tactic (+0x22e4) = m.tactic.vt[0](&context)      # one step of the tactic state machine (part 3)
            m.targetSelector.vt[8]()
        if m.target and m.target.HP == 0: m.vt[0xa08](0)       # target-dirty
        if m.target != m.lastTarget or dirty:
            m.lastTarget = m.target;  so_mobile_Broadcast2ndTarget(m, target, 1) (Z03 §2.3);  dirty = 0
    if lifetime timer (+0x24ec) expired (accumulates the tick step DAT_14d41a74, FUN_00592020):
        stop it;  m.so_KilledBy(m, MaxHP())                    # the mob kills itself: normal death path (Z03 §8.1)
    slanted-list relink check (scope guard, §1.3)
```

"Run the AI Lua function only" is the same `lss_Routine` call without the brain step; its return value is ignored there.
The tick argument is the second argument of the routine thunk (not traced further). Lifetime: `vt 0xabc(seconds)`
(FUN_0055e5b0; 0 stops the timer) is called by the breeders and the `cMobRegen_*` script functions with
MobLifeTime.LifeTime (part 6); the period is `seconds × 10` tenths. `ShineServant` has its own timed suicide
(vt 0xf7c FUN_004a3490: deadAt = g_Now + n·10, `AxialListMobSuicide::alms_SelfKill`; part 8).

`vt 0xdf0` (FUN_00553760) sends the same 0x244A immediately and sets `deathSent`; it is used by `cKillObject` (part 10).
Client: `GameFrameWork::ON_NC_BAT_REALLYKILL_CMD` (client FUN_004a28e0) looks up `dead` and `attacker`; without the
attacker it plays the death at once (`vt 0x280`), otherwise it lets the attacker's running attack sequence finish the
death (`Char::ModifyExistDyingSeq`), and counts a tutorial mob kill when the attacker is the own character and the dead
one is a mob. Name: the 2017 PDB gives 0x244A two names; the 2016 zone sends the 4-byte `PROTO_NC_BAT_REALLYKILL_CMD
{ ushort dead; ushort attacker; }` here (C02 §alias table).

### 5.5 `ShineMobileObject::so_Routine`: the part before the cast (all mobile objects)

```pseudo
ShineMobileObject::so_Routine(o)                                                @ FUN_0056a080
    SetItemData_SkillEffect.se_Clear(&setitemskilleffect)
    flags1e78 &= ~4                                            # Fear is re-set by the abstate tick if still on
    if mode == 0 or mode == 3: return 1                        # nothing runs for dead or unspawned objects
    if sub-layer not in {2, 3}: sub-layer = 0                  # transient sub-layers last one tick
    AbstateListInObject.asl_Routine(o+0x1cc, o)                # abstate expiry and periodic effects (Z03 §6)
    if o.paramDirty (+0xe94):                                  # set when abstates change parameters
        so_RecalcAbstateParam (vt 0x360);  vt 0x368 (player: so_RecalcLastParam);  vt 0xda4
        smo_NotifyParameterChange(1) (vt 0x34);  so_mobile_SpeedChange (vt 0x7bc);  paramDirty = 0
        if stat flags +0xcce & 7 (cannot move / attack / cast): vt 0x8d0 (player: CancelOnAction)
    if mode == 4:                                              # player-only state (Z01-core §4.3); mobs have no-op slots
        if Fear or captivated (vt 0xf20): vt 0x488();  return
    if Fear and not (+0xcce & 1) and not (+0xcce & 2): smo_RunInFear(o)               # part 5
    if captivated: vt 0xf24()                                  # player FUN_005601e0; mobs no-op
    if o.move.active (+0x1ac) and not IsDead: MoveManager.mm_Step(o+0x18c, 0)        # part 5
    else: o.move.state (+0x18c) = 0
    movement detector (FUN_0055d610): every 0.2 s compare the position (FUN_00554ee0) with the last one;
        moving (+0x1e8c) flips 0↔1 and +0x1e98 = g_Now when it changes
    if o.cast.castEnd (+0x1d84): cast completion — Z03 §5 ("ShineMobileObject::so_Routine … fires the cast")
```

### 5.6 MobConditionServer: animation levels

```pseudo
MobCondition step (in ShineMob::so_Routine)                                     @ FUN_00554420
    if m.conditions:
        lv = m.vt[0xd44]()                                     # brief.nAnimationLevel (+0x92), FUN_0054aa90
        if lv < len(conditions) and conditions[lv].vt[4](m):   # MobHPcondition::check @ FUN_004b0040
            m.vt[0xd40](lv + 1)                                # FUN_00553460

MobHPcondition { u8 AniLv +4, u32 MC_ValueMin +8, u32 MC_ValueMax +0xc }.check(m):
    m has a data row (vt 0x708 = mob ID ≠ 0xFFFF, FUN_00556ab0) and lv < AniLv and HP < MaxHP · MC_ValueMax / 100

set animation level (m, lv):                                                    @ FUN_00553460
    to sight: 0x2076 NC_ACT_ANIMATION_LEVEL_CHANGE_CMD { u16 nMonsterHandle = m.handle, u8 nAnimationLevel = lv }   # size 5
    brief.nAnimationLevel = lv
```

`MC_ValueMin` is stored but never tested; the levels only go up (reset with the brief at the next spawn). 2016 data: two
mobs, `WarL_Pore` (60 % → 1, 30 % → 2) and `WarL_BrainWash` (80/59/39/19 % → 1…4). The client
(`GameFrameWork::On_NC_ACT_ANIMATION_LEVEL_CHANGE_CMD`, client FUN_004a6740) stores the level in the character
(+0xb60), which picks the animation set (client table MobConditionView *(pdb2017)*: `MobInx, AniType, AniLv, EventCode`).
Layout matches `PROTO_NC_ACT_ANIMATION_LEVEL_CHANGE_CMD` *(pdb2016)*.

### 5.7 Placing the mob: `so_MapMarking` → `FieldMap::fm_Marking`

```pseudo
ShineMob::so_MapMarking(m, force) → 0 | 3                                       @ FUN_004665f0
    field = the FieldMap whose map name equals m.map (ListSearchSame over fieldlist)
    if none: return (no marking; caller treats non-zero as failure)
    spacing = MobInfoServer.RegenInterval (0 → 1; no server row → 25)
    return FieldMap.fm_Marking(field, m, spacing, 0, force)

FieldMap::fm_Marking(f, o, spacing, dropArg, force)                             @ FUN_00452fd0
    o.field = f
    if o.pos is outside f (x ≥ width or y ≥ height): note f in the "bad field" ring DAT_0085dfb0; return 3
    if x or y ≥ 0xFFFFFF: log "fm_Marking : Invalid coordinate"; return 3
    add o to the 5×5 slanted coordinate lists of f (index = coord·5 / size, max 4);
        on failure: o.vt[0x8a0](0), MapRearrangeObserver "MapMarking", fm_Relink
    if force: o.marked (+0x162) = 1; return 0
    DropLocationManager.dlm_home(dropArg)                      # spiral search around the wanted point
    loop:
        if the cell is not blocked (FUN_0049df70 on the block map) and
           no object within `spacing` collides (so_AllOfRange(o, spacing, so_collesioncheck)):
            o.marked = 1; return 0
        next spiral point (FUN_00460910; at most 32 levels, "DropLocationManager::dlm_Getloc");
        none left: log "FieldMap::fm_Marking : Fail mark"; return 3
        outside the field: return 3
        ShineObject::so_MoveTo(o, point);  dlm_next
    final check of the last point: free → marked = 1, return 0;  else return 3
```

So mobs of one breeder never stand on top of each other: each spawn moves outward until it is `RegenInterval` (25 for
2804 of 2842 mobs) away from every other object. NPC.txt NPCs and the GM/Lua NPC spawns use the same path (vt 0x6e0).

### 5.8 Small mob services

| Function | What |
|---|---|
| `so_SetHP(h)` vt 0xaac @ FUN_00552d40 | HP = min(h, MaxHP()) |
| `so_recoverhp(n)` vt 0x5b4 @ FUN_0042ceb0 / `so_recoversp(n)` vt 0x5b8 @ FUN_0042cf30 | HP / SP += n, capped at +0xea8 / +0xeac (no packet; callers: `sm_DuringRecover`, GM `&HPChange/&SPChange`, house/mover recovery) |
| `so_mob_GetMonEXP()` vt 0xb9c @ FUN_004aa2f0 | returns the script override +0x2508; `ExperienceDistribute::lid_Call` uses MonEXP when it is 0 (Z03 §8.2) |
| `so_mob_ParamSetAtScript(name, value)` vt 0xb80 @ FUN_005d29c0 (Lua `cSetNPCParam`) | "HP" → HP; "MaxHP" → +0x2504; "MobEXP" → +0x2508; "AC" → stat matrix L0 AC (+0xfdc); "MR" → L0 MR (+0xff0); "WalkSpeed" → +0x254c; "RunSpeed" → +0x2550; "HPRegen" → +0x2554; other names → false. No recalculation and no packet: a new MaxHP shows in the next brief/HP packet, AC/MR only after the next `c_MakeTotal` *(inferred)* |
| `so_mob_SetMobResist(offset, value)` vt 0xba0 @ FUN_004a9d00 (Lua `cSetNPCResist` @ FUN_005db0a0) | writes the u16 at resist block + offset. `cSetNPCResist(handle, {name = value, …})` maps `ResDot 0x20, ResStun 0x22, ResMoveSpeed 0x24, ResFear 0x26, ResBinding 0x28, ResReverse 0x2a, ResMesmerize 0x2c, ResSeverBone 0x2e, ResKnockBack 0x30, ResTBMinus 0x32` (the MobResist column offsets); unknown keys are skipped; returns 1 (true) to Lua, nothing for a missing object or a non-table argument |
| resist roll vt 0x634 @ FUN_00416660 | `rand(1000) < value`, value by the AbState row's `SubDispelIndex` (+0xf8): 1 ResStun, 2 ResMoveSpeed, 3 ResFear, 4 ResDot, 7 ResReverse, 8 ResBinding, 9 ResMesmerize, 10 ResSeverBone, 11 ResKnockBack, 12 ResTBMinus, other 0; always 0 when the mob has no MobResist row. This is the "isresist" roll of Z03 §5/§6 |
| `so_scene_DetectRange(r)` vt 0x8bc @ FUN_0050dd30 | target selector +0x10 = r (map-script node `ShineMobDetectRange`) |
| `so_scene_Duplicate(n)` vt 0x8c0 @ FUN_0050dda0 | allocates **one** object of the same type (log text on failure "PineEventScriptNode::ShineMobRegen::sa_Step : Too many mob"), then calls its `so_mob_Regenerate(m.field, m.x, m.y, m.dir, handle, m.mobId, vt 0x6d0() (0 for mobs), −1, 0, 0, −1, 1, 0, 0)` `n` times. (original bug) Z09-B1: the same object is spawned `n` times, so at most one copy appears. (original bug) Z09-B3: `m.dir` is the stored byte (degrees / 2) and is halved again |
| `so_scene_IsIdle()` vt 0x8c4 @ FUN_0050def0 | true when no cast is running |
| `sm_scene_SetWeaponRate(rates)` @ FUN_0050e0c0 | stores weapon rates at +0x24c8 (FUN_0050dfa0; part 4) |
| `so_mob_SetGuildRegNum(g)` vt 0x900 @ FUN_00476110 | +0x22ec = g; to sight: 0x748D NC_GUILD_MOBGUILD_CMD { u16 mobhandle, u32 mobguild } (pdb2016; size 8 with the opcode); `mb_SendMyGuildInfo` @ FUN_00475a80 sends the same to one newcomer when g ≠ 0 (Z02 §5). Client `ON_NC_GUILD_MOBGUILD_CMD` (client FUN_004ba6b0) keeps a map handle → guildNo in `CGuildMonster` (replacing an older entry). Used for guild-tournament / guild objects (Z08/Z16) |
| `so_mob_IsItemDropSetAtScript(b)` vt 0xbb0 @ FUN_004aa810 | dropsEnabled = b |
| `so_SendInform2Admin(gm)` vt 0x8d8 @ FUN_0058e5d0 | only calls `ShineMobileObject::so_SendInform2Admin` (the GM object-info dump; GM commands item) |

### 5.9 `ShineNPC` and `NPCManager`

`NPCManager` = `npcmanager` DAT_0da29a60: 1024 entries of 12 bytes `{ → NPC.txt row, → NPCRole, u16 handle }`, +0x3000
= number of NPC.txt rows (the static part). Row and role classes: Z02 §6.1.

```pseudo
NPCManager::nm_SetNPC(nm)   (start stage `open`)                               @ FUN_004c6560
    for each static entry:
        mobId = mobdatabox.index(row.MobName);  unknown → log "nm_SetNPC : Invalid mob id"; next
        npc = som_AllocObject(type 4)  (none → "Too many npc")
        r = npc.so_mob_Regenerate(row.Map, row.x, row.y, row.Direct, handle, mobId, 0, breeder −1, 0, 0, level −1, 1, 0, 0)
        npc.so_npc_FromTable()                                 # +0x2568 = 1
        if r != 0: som_FreeObject(reason 0x22); next
        npc.allLayers (+0x56) = 1;  entry.handle = handle;  entry.role.vt[0x2c](npc, row + 0x54)   # role init with RoleArg
        if NpcSchedule.shn has a row whose index (32 chars) equals row.MobName: so_Unmark(npc, 0, 1, 3)
                                                              # scheduled event NPCs stay off the map until WM 0x086A (Z01-core §10)
    qsort the static part by handle (FUN_004c52f0)            # NPCManager::nm_FindNPCFunc bsearches it, then scans the dynamic part

NPCManager::nm_DynamicRegenerateNPC(nm, from, name[32], map, x, y, dir)        @ FUN_004c6cd0
        # callers: GM command `&RegenNPC` (FUN_00421e50) and Lua `cNPCRegen` (FUN_005de700)
    from == null → "PFrom is not set: "; from's field option missing → "Unable to get Field Optionj: "
    mobId = index(name)  (unknown → "…Invalid mob id")
    find the static entry with MobName == name and Map == from's map ("i == nm_BufferPoint: " when none)
    npc = som_AllocObject(type 4) ("…Too many npc")
    x, y, dir = −1 → the row's values
    npc.allLayers = 1;  r = npc.so_mob_Regenerate(map, x, y, dir, handle, mobId, 0, −1, 0, 0, −1, 1, 0, 0);  npc.so_npc_FromTable()
    r != 0 → log "NPCRegenResult != FM_MARKSUCCESS: ", free (reason 0x2c)
    else: put NPCIndexArray { pnt = row, func = role (NPCRoleBase*), handle } into the first slot at index ≥ count whose handle is 0xFFFF
          (original bug) Z09-B2: when no slot is free the loop ends at index 0x400 and the entry is written there anyway,
          over `count` and the words after the table (PDB layout: `nm_BufferArray[1024]` of 0xc-byte `NPCIndexArray`, then
          `nm_BufferPoint` +0x3000 = count and `nm_NPCInfo` +0x3004); the "nm_BufferArray Full" branch (free, reason 0x2d)
          is unreachable

`NPCManager::nm_DynamicReleaseNPC` (FUN_004c5310): clear the dynamic entry with that handle (row, role = 0, handle = 0xFFFF);
    static entries are never released.
```

```pseudo
ShineNPC::so_Routine(n)                                                         @ FUN_0056a9e0
    if n.fromTable and mode != 2: log "ShineNPC::so_Routine : NPC from table is killed"; mode = 2   # table NPCs cannot stay dead
    if outside the field: log "fm_IsInFieldSize : NPC"; flags1e78 |= 1
    smo_MoveByScenario(n)                                      # scripted walking (part 5)
    ShineMobileObject::so_Routine(n)                           # §5.5
    if mode != 3:
        NPCAction proximity triggers as for mobs (+0x24e8, range DetectCha)
        AI Lua function (no brain: NPCs have no tactic step)
        if flags1e78 & 1: release role entry; so_Unmark(0, 1, 3); som_FreeObject(reason 0xc)
    else (dead, only NPCs not from the table):
        once: to sight 0x244A NC_BAT_REALLYKILL_CMD { n.handle, n.killer }
        if g_Now − n.deadAt > 49 (5 s): release role entry; so_Unmark; som_FreeObject(reason 0xb)
        slanted-list relink when a node is invalid (FieldMap.fm_Relink)

ShineNPC::so_KilledBy(n, …)                                                     @ FUN_004b1a10
    if not n.fromTable: ShineMob::so_KilledBy(n, …)            # Z03 §8.1
    else: log "ShineNPC::so_KilledBy : NPC from table is killed" (file log DAT_0da28d68); nothing else

ShineNPC::so_NPCRevive(n, gm)   (vt 0xa7c, GM `&NPCRevive` FUN_004231a0)        @ FUN_00452430
    tell the GM "Changed from <mode> to 2";  mode = 2;  so_AllOfRange(n, so_BroadcastBriefInfo)

ShineNPC::so_mob_Regenerate @ FUN_004b4bc0: fromTable = 0, then ShineMob::so_mob_Regenerate (§5.3).
```

### 5.10 `ShineBandit` (scenario objects that switch between NPC and mob)

```pseudo
brief for bandits (vt 0xf70 FUN_004b11a0(handle, _, src)):  copy the brief from src (FUN_004b0bf0) into +0x2666,
    handle, type (+0xc2) = 4, +0xbe = 0, +0xc3 = 0;  spawn x/y/dir from +0x16/+0x1a/+0x1e of it (vt 0xf6c FUN_004b10c0)

ShineBandit::so_Routine(b, _, handle)                                          @ FUN_0056c630
    if b.type (+0x2666 → +0xc2) == 5 or invalid position: return ShineMob::so_Routine(b, _, handle)   # acts as a mob
    if outside the field: log "fm_IsInFieldSize : Bandit"; so_Unmark(0, 1, 3); som_FreeObject(reason 6); return
    smo_MoveByScenario(b);  ShineMobileObject::so_Routine(b)  # no AI while it is an NPC

ShineBandit::so_bandit_ChangeType(b, t)   (vt 0x898; map-script nodes ShineChange2Mob / ShineChange2NPC, §23.2)   @ FUN_005508b0
    b.type = t
    to the whole map (so_AllInMap1): 0x6C0B NC_SCENARIO_OBJTYPECHANGE_CMD { u16 handle, u8 type }   # size 5
```

The client (`GameFrameWork::On_NC_SCENARIO_OBJTYPECHANGE_CMD`, client FUN_004a3580) stores `type` in the character
(+0x78c). Layout matches `PROTO_NC_SCENARIO_OBJTYPECHANGE_CMD` *(pdb2016)*. Which value each script node passes
(5 = mob, 4 = NPC *(inferred from the routine test and the spawn value)*) is read in §23.2. The bandit name for
`vt 0x4a0` is `+0x2666 + 0x5b` (FUN_00556f20).

---

## 6. Mob AI 1: brain, target selectors, aggro, rescue

The mob's AI has two layers. The **target selector** (`MobTarget*`, one object per mob, chosen by `EnemyDetectType`)
keeps the aggro list and answers "whom do I fight". The **tactic state machine** (`MobTacticElement::*`, `+0x22e4`,
part 4) decides what to do each tick and asks the selector. This section covers the selector, the aggro list, the
battle / recover states and the call for help. Tactics, weapons and skills are part 4; movement is part 5.

### 6.1 Brain objects in the mob (`MobAggroManager` at +0x1fcc)

The constructor `MobTacticElement::MobActionArgument::Selector::Selector` FUN_0054ee00 builds `maa_TargetSelect` at
`mob+0x1fcc`: `targetlist`, a `MobAggroManager` (FUN_004bda50: a `List<MobTargetStruct>` with **10 preallocated nodes**
`mam_Array` of 0x20 bytes), and right after it one selector object of every class (`bout`, `aggresive`, `nobrain`,
`aggresive2`, `aggresiveall`, `aggresiveNoLevel`). `sm_SetBrain` points `selector` (+0x2234) at one of them:

| Mob offset | Class (constructor) | `EnemyDetectType` *(enum names pdb2016)* | 2016 rows |
|---|---|---|---|
| +0x2124 | `MobTargetBout` (FUN_004bd2c0) | 0 ED_BOUT, and every unknown value | 220 |
| +0x213c | `MobTargetAggresive` (FUN_004bd2e0) | 1 ED_AGGRESSIVE | 1872 |
| +0x2174 | `MobTargetNoBrain` (FUN_004bd410) | 2 ED_NOBRAIN | 728 |
| +0x218c | `MobTargetAggresive2` (FUN_004bd340) | 3 ED_AGGRESSIVE2 | 12 |
| +0x21c4 | `MobTargetAggresiveALL` (FUN_004bd2e0, vftable replaced) | 4 ED_AGGREESIVEALL | 1 |
| +0x21fc | `MobTargetAggresiveNoLevel` (same) | 5 ED_ENEMYALLDETECT | 9 |

`MobTargetPlayerCaptivate` is not in the mob; its only vftable write is in FUN_0055bc80 at `player+0x2a9d0`
(`param_1[0xaa74]`) = the player member `m_TargetSelect`, next to `m_pCaptivateAI` (+0x2a9cc) and `m_pAITarget`
(+0x2aa28) *(pdb2016)*: the charmed-player brain (§7.7, §8.10).

```pseudo
ShineMob::sm_SetBrain(m)                                                        @ FUN_004b2480
    t = m.enemyDetect (+0x2544)                    # 6 = "use the table" (set at spawn, §5.3)
    if t == 6: t = MobInfoServer.EnemyDetectType
    sel = selector object for t (table above); unknown t → MobTargetBout and
          log "ShineObjectClass::ShineMob::sm_SetBrain Not Case EnemyDetectType"
    m.targetSelector (+0x2234) = sel.vt[0x10](m, &m.aggroManager)     # mts_Initialize, returns sel
```

Callers: `so_mob_Regenerate` (§5.3), the teleport FUN_005793e0 (`ShineMob::so_mobile_Teleport`, log string `smo_Teleport`; §9.3) and the
two setters below. `ShineObject::so_mob_SetEnemyDetect` exists as vt 0xba4 FUN_004aa630 (value 0…5, other → 6) and vt
0xba8 FUN_004aa3a0 (name `"ED_BOUT"` … `"ED_ENEMYALLDETECT"`, other → 6, null → 6 without re-brain); both call
`sm_SetBrain`. No caller of either slot was found in the 2016 zone (players / base objects: empty FUN_004aa5e0).

**Selector object layout** (all classes, base `MobTargetSelector` FUN_004a9b40, which is also an `AxialListIterator`):

| Offset | Member *(pdb2016)* | Meaning |
|---|---|---|
| +0x04 | `mts_Current.target` | → current target entry (`MobTargetStruct`); `&mobtargeteraser` DAT_0da28aac = the empty entry (no target) |
| +0x08 | `mts_Current.distsquar` | squared search radius during a scan; best distance² found so far |
| +0x0c | `mts_MyBody` | → mob |
| +0x10 | `mts_SightRange` | `MobInfoServer.DetectCha` (detection radius) |
| +0x14 | `MobTargetBout::mtb_targetlist` | → `MobAggroManager` (the aggro list, mob+0x1fcc) |
| +0x18 … +0x37 | `MobTargetAggresive::mta_InstanceTarget` (`MobTargetStruct`) | built-in entry `{u16 handle, identity, → object}` filled by a scan (`ali_Work`) |
| +0x2c | `mta_InstanceTarget.mts_EnemyAnalyzer` | Aggresive classes: its `IntelligenceOffice4Mob` (ctor FUN_0058a630; not used by the code read here) |

**`MobTargetStruct`** (0x20, list entry): `+0 u16 handle, +4 identity (vt 0x344: player = character number, mob =
spawning breeder; protects against reused handles), +8 → object, +0xc s32 aggro points, +0x10 time of the last
aggro (g_Now), +0x14 `mts_EnemyAnalyzer` (`IntelligenceOffice4Mob`: read position in the target's heal-report ring, §28.2), +0x18 report
mask`. An entry with 0 aggro counts as free.

**Selector vtable** (byte offsets; names from profiler strings unless marked):

| Slot | Bout / NoBrain / Aggresive* | Meaning |
|---|---|---|
| 0x00 | `ali_Work` FUN_004a9e20 (Aggresive, ALL, NoLevel), FUN_004aa020 (Aggresive2), FUN_004add20 (Captivate) | one candidate of a range scan (§6.3) |
| 0x08 | `mts_Routine` FUN_004ac940 | per tick: expire entries (§6.2); called from `ShineMob::so_Routine` (§5.4) |
| 0x0c | `mts_InitRegen` FUN_004aced0 | `mob = arg`; erase all entries |
| 0x10 | FUN_004abf00 → `mts_Initialize` FUN_004abe40 | `(mob, aggroManager)`: store both, radius = DetectCha, target = none; returns the selector |
| 0x14 | `mts_AggroClear` FUN_004ad6f0 | erase all entries (battle over, §6.6) |
| 0x18 | FUN_004ad7b0 *(ViewAggroList; it carries the profiler string "MobTargetBout::mts_AppendAggroPoint")* | GM list (§6.8) |
| 0x1c | `mts_AppendAggroPoint` FUN_004ad9a0 | §6.2 |
| 0x20 | `mts_DecreaseAggroPoint` FUN_004ac3d0 | §6.2 |
| 0x24 | `mts_InitThink` FUN_004abf20 | target = none; radius = DetectCha; +8 = DetectCha² |
| 0x28 | `mts_SelectTarget`: Bout FUN_004acfc0, Aggresive/2/NoLevel FUN_004ad290, ALL FUN_004ab1b0, NoBrain FUN_004ac0d0, base FUN_004ac000 | §6.3; called by the tactics (part 4) |
| 0x2c | `mts_StoreAggroList` FUN_005d5250 (base FUN_005d30d0 returns −1) | append the handle of every entry with an object to a `vector<u16>`; returns the count |
| 0x30 | FUN_004bd630 | run a `MobTargetBout::mts_SlayerList` iterator over the list (the kill-credit list of 0x244C NC_BAT_MOBSLAYER_CMD, Z03 §8.1 *(inferred)*) |
| 0x34 | `mts_AggroAdjust` FUN_004a7c50 | §6.2 |
| 0x38 | `mts_GetTopAggroTarget`: Bout/NoBrain FUN_004aa8d0, Aggresive* FUN_004aab80, ALL FUN_004aaf30 | §6.4 |
| 0x3c | "target is protected": Aggresive* FUN_004a9b90 (StaAdlFLoussierIMT 499, StaImmortal 291, StaHide 75), ALL FUN_004a9cb0 (291, 499) | `IsNoAttackAbstate` *(pdb2016)*: no caller anywhere (dead slot, §28.4) |
| 0x40 | "level gap too big": FUN_004a9b70 `mobLevel − candLevel > 10`; NoLevel FUN_004021b0 always false | used by `ali_Work` |

Abstate numbers are `AbStataIndex` values (Z03 §1): 75 StaHide, 77 StaEntrapHide, 291 StaImmortal, 335 StaKarenCaptivate,
499 StaAdlFLoussierIMT, 562 StaWarLBrainWash.

### 6.2 The aggro list

Entry = `MobTargetStruct` (0x20) *(pdb2016)*: `mts_Handle` u16 +0 (`handle`), `mts_CharRegnum` +4 (`identity`, vt 0x344:
the character number of a player), `mts_Object` +8 (`obj`), `mts_AggroPoint` s32 +0xc (`aggro`), `mts_LastHit` +0x10
(`time`), `mts_EnemyAnalyzer` +0x14 (`SpyNet::IntelligenceOffice4Mob`, 0xc; the `mask` word below sits in it at +0x1c).
Selector base `MobTargetSelector` (0x14, an `AxialListIterator`): `mts_Current {target, distsquar}` +4, `mts_MyBody` +0xc,
`mts_SightRange` +0x10; `MobTargetBout` adds `mtb_targetlist` +0x14 (→ the mob's `MobAggroManager`); `MobTargetAggresive`
adds `mta_InstanceTarget` +0x18 (a `MobTargetStruct` for the scan winner); `MobTargetPlayerCaptivate` adds `PlayerTarget`
+0x38 (its `mts_Object` +0x40 is the `found` of §8.10).

```pseudo
MobTargetBout::mts_AppendAggroPoint(sel, obj, points)            (vt 0x1c)      @ FUN_004ad9a0
    e = entry with e.handle == obj.handle
    if e:
        if e.identity == obj.identity (vt 0x344): e.aggro += points; e.time = g_Now
        else:                                     # handle reused by another object
            e.identity = obj.identity; e.time = g_Now; e.obj = obj; e.aggro = points
    else:
        e = a new node from the list's free nodes (10 in total), else the first entry with aggro == 0
        if none: return                           # list full: an 11th attacker is not recorded
        e = { handle, identity, aggro = points, obj, time = g_Now, mask = (obj.intelligence (vt 0x480 = obj+0xeb0) +0x100) & e.+0x1c }
    mts_TargetChange(sel, e)

MobTargetSelector::mts_TargetChange(sel, e)                                     @ FUN_004ac4e0
    if e.aggro > sel.target.aggro * 0x466 / 1024 (≈ 1.1 ×):        # 10 % hysteresis
        sel.target = e
        mob.vt[0x8f8]()                           # FUN_004abd30: if not tactic.vt[0x1c](): tactic = tactic.vt[0x10](ctx)  (re-plan, part 4)

MobTargetBout::mts_DecreaseAggroPoint(sel, obj, permille)        (vt 0x20)      @ FUN_004ac3d0
    for e in list (MobTarget_AggroClear::lid_Call @ FUN_004ac2c0):
        if e.handle == obj.handle and e.identity == obj.identity:
            e.aggro −= e.aggro * permille / 1000;  if e.aggro < 1: e.aggro = 1     # stays in the list with 1 point
    sel.target = none;  sel.+8 = 0                # the next tick selects again
    # iterator object MobTarget_AggroClear {obj, permille}: ctor FUN_004ac180, dtor FUN_004ac230

MobTargetBout::mts_AggroAdjust(sel, obj, permille) → sel        (vt 0x34)      @ FUN_004a7c50
    e = entry of obj (same handle and identity): e.aggro = e.aggro * permille / 1000

MobTargetBout::mts_Routine(sel)                  (vt 0x08, every mob tick)     @ FUN_004ac940
    an = MobTarget_EnemyAnalysis(mob, list)                                     @ FUN_004ac5b0
        keepTime = MobInfoServer.CutNonAT / 1000 * 10       # ms → tenths, whole seconds only
        keepDist² = MobInfoServer.CutInterval²              # (null data: "MobTarget_EnemyAnalysis::MobTarget_EnemyAnalysis : Null info", both 0)
    for e in list (lid_Call @ FUN_004ac800):
        o = som_GetObject(e.handle)
        if g_Now <= e.time + keepTime and o and dist²(mob, o) <= keepDist²:
            SpyNet::IntelligenceOffice::io_ReadReport(&e.report, mob, o.intelligence)   # heal reports → healer aggro, §28.2
        else: free the entry (mtea_free @ FUN_004ac750 → list.vt[0xc])               # forgotten
    # dtor of the iterator: FUN_004ac6c0
```

So an attacker is forgotten after `CutNonAT` ms without new aggro or when it is farther than `CutInterval` from the mob.

The callers that add or remove aggro (all through the mob's vtable):

```pseudo
ShineMob::so_mob_AppendAggro(m, a, points)       (vt 0x700)                    @ FUN_0042d470
    if a == null or m.vt[0xe60](a) == 1: return              # same side (vt 0x8cc equal; FUN_0054b050)
    if the field has a guild-tournament system and m.guild (vt 0x828) != −1 and a.guild == m.guild: return
    if not regenAniOver (§5.4) and not MobRegenAni.IsAggro (entry+0x2c → +0x42): return   # no aggro while spawning
    m.targetSelector.AppendAggroPoint(a, points)
    if a.owner (vt 0x9b0; servant FUN_00557090: its living master on the same field): the owner is added too
        (same points *(inferred)*: the decompiled call lost its arguments)
    share = points > 0 ? max(points / 4, 1) : points
    for every other mob f in m's family ring (+0x24b5 chain, §5.3): f.targetSelector.AppendAggroPoint(a, share)

ShineServant::so_mob_AppendAggro(s, a, points)   (vt 0x700)                    @ FUN_0042d630
    only if s.so_mobile_IsEnemy(a) (vt 0x72c): ShineMob::so_mob_AppendAggro(s, a, points)

ShineMob::so_mob_DecreaseAggro(m, a, permille)   (vt 0x704)                    @ FUN_0042d380
    m.targetSelector.DecreaseAggroPoint(a, permille);  the same for every mob of the family ring

ShineMob::so_mob_AggroAdjust(m, a, permille)     (vt 0x990)                    @ FUN_004a4b30
    m.targetSelector.AggroAdjust(a, permille).vt[0x28](m)    # scale, then select a target again

ShinePlayer::smo_ply_AggroAdjust(p, permille, range)   (vt 0xebc)              @ FUN_004a4a40
    so_AllOfRange(p, range (0 = sight), AxialListAggroAdjust{permille})
        → every object o: o.vt[0x990](p, permille)           # ali_Work @ FUN_004a4990
```

Who calls them: `so_DamagedBy` / `so_KilledBy` (`dmg × aggroRate / 1000`, Z03 §7 / §8.1), a miss (1 point, Z03 §3),
skills with `AbsoluteAggro` / `AggroPerDamage` (Z03 §5), `smo_SwingDamage` and `so_Bash` with an aggro decrease
(vt 0x704), the Lua functions (§6.8), the magic-field aggro iterator `AxialListMagicFieldAggro` (part 8) and
`smo_ply_AggroAdjust`, which `ShineMobileObject::so_Routine` (FUN_0056a080, §5.5) calls for a player while the skill in
its cast block (+0x1d98) has the flag at +200: `(permille = skill +0xcc, range = skill +0xd4)` (aggro-reducing skills
*(inferred)*; the skill columns are Z03's).

### 6.3 Selecting a target (`mt_SelectTarget`, vt 0x28)

All variants walk the aggro list the same way and skip entries in this order:

```pseudo
for e in list:
    if not mdb_CanIKill(e.obj.mobId (vt 0x708; players 0xFFFF → yes), identity 1 = mob): e.aggro = 0; continue
    if e.obj is dead (vt 0x28):                                          e.aggro = 0; continue
    if e.obj has StaImmortal (291) or StaAdlFLoussierIMT (499):          continue   # kept, but not chosen
    if e.obj has StaKarenCaptivate (335) or StaWarLBrainWash (562):      continue
    … variant rule …
```

```pseudo
MobTargetBout::mt_SelectTarget(sel)                                            @ FUN_004acfc0   (Bout, NoBrain via mts_InitThink)
    sel.target = entry with the highest aggro (> 0), else none (sel.+8 = 0)
    # Bout mobs never look for targets themselves: they fight only who hit them

MobTargetAggresive::mt_SelectTarget(sel, m)                                    @ FUN_004ad290   (Aggresive, Aggresive2, NoLevel)
    for each entry: w = e.aggro
        if e.obj is not in Fear (vt 0x9e8 = flags1e78 bit 2):
            d² = DistanceSquare(m, e.obj);  if d² > 500²: w /= 2;  if d² > 1000²: w = 0
        else: w = 1                                       # a fleeing target counts 1 point
    if some w > 0: sel.target = entry with the highest w;  return
    if m.vt[0x6ec]() != 0: sel.target = none; sel.+8 = 0; return
        # FUN_00556ad0: squared distance from the spawn point (vt 0x614 = +0x249c) when it is > 3000², else 0
    # scan for a new enemy (§6.3.1)
    sel.+8 = DetectCha²;  sel.target = none
    centre = m.vt[0x8f4](DetectCha)                       # FUN_004abcd0: the mob's position moved 0.4 × DetectCha
                                                          # forward along its direction (FUN_004a2db0)
    so_AllOfRange(m, centre, DetectCha, sel)       # sel.ali_Work for each object
    if found: m.so_mob_AppendAggro(found, m.level × 5)    # the new enemy enters the list with level × 5 points

MobTargetAggresiveALL select                                                    @ FUN_004ab1b0
    sel.target = the FIRST entry that passes the skip rules (not the highest aggro)
    if none and within 3000 of the spawn point: sel.+8 = DetectCha²; scan with sel over the field's sight range
        (FUN_00553c20: so_AllOfRange with range 0 = the map's sight radius); the found object becomes the
        target directly (sel.+4 = built-in entry), without aggro points
    else sel.+8 = 0

MobTargetNoBrain::mt_SelectTarget(sel)  = sel.vt[0x24]() (mts_InitThink): never a target         @ FUN_004ac0d0
MobTargetSelector::mt_SelectTarget(sel, m): scan around m.vt[0x8f4]() within DetectCha with sel   @ FUN_004ac000
```

#### 6.3.1 Scan candidate test (`MobTargetSelector::ali_Work`, slot 0)

```pseudo
MobTargetSelector::ali_Work(sel, m, o, d²) → continue                          @ FUN_004a9e20
    accept o only if all hold:
        mdb_CanIKill(o.mobId, 1)
        o.side (vt 0x8cc) != 0                          # player 2; mob 1 (IsPlayerSide 0/3) or 2 (1/2), override +0x2548; NPC 3 (IsPlayerSide 0) or 2
        m.so_mobile_ICanDamageTo(o, "MobTargetAggresive::ali_Work")   (vt 0x980, Z03)
        o.vt[0x904]()                                   # player 1; mob: flags +0x24ac bit 0
        o has neither StaImmortal nor StaAdlFLoussierIMT
        o.mode not in {3 dead, 0 spawning}
        SubLayer::SubLayerInteractLoader::slil_Interact(o, m) and so_SubLayer_CanSee(o, m)  (Z02 §5)
        not hidden (FUN_004a9be0): o has StaHide (75) or StaEntrapHide (77) and m is not ED_AGGREESIVEALL
        not sel.vt[0x40](m.level, o.level)              # aggressive mobs ignore targets more than 10 levels below them
        d² < sel.+8                                     # nearest wins
    accepted: sel.+8 = d²;  built-in entry = { o.handle, o.identity, o };  sel.target = built-in entry
    always returns "continue" (all objects are visited)

FUN_004aa020 (MobTargetAggresive2): skip players whose byte +0x2a7f6 is set (vt 0x9e0; mobs 0), else as above
```

### 6.4 Top aggro (`so_mob_GetTopAggroTarget`, vt 0xc18)

`ShineMob::so_mob_GetTopAggroTarget(m)` @ FUN_0042fea0 returns `m.targetSelector.vt[0x38](m)` (0 without a selector;
`ShineObject` FUN_0042fe50 returns 0). Bout FUN_004aa8d0: object of the highest-aggro entry; Aggresive FUN_004aab80: the
same with the distance weighting of §6.3; ALL FUN_004aaf30: the first valid entry. The entries are filtered as in §6.3
(failing `mdb_CanIKill` or dead → aggro set to 0). Callers: the skill-blast random target `AxialListScanSkillTarget::
alsst_SkillBlast_RandomTarget` FUN_00583180 and the skill target scan FUN_0057e660 (Z03 / part 4).

### 6.5 Current target and battle state

- `ShineMob::so_mob_CurrentTarget` (vt 0xb78) @ FUN_005d2790 returns the u16 at **+0x24ae** (`ShineObject` FUN_005d2740:
  0xFFFF). It is the mob's current fight target (correction of §5.2's "first attacker"): `so_DamagedBy` fills it with
  the attacker when it is 0xFFFF (Z03 §7), the tactic `MobActionTargetting::mab_Think` (part 4) sets it through
  FUN_004b8930, which on a change raises the map-script interrupt `sim_TargetChange { mob handle, target handle }`
  (FUN_0050c730; not for 0xFFFF). `so_mob_RegenComplete` resets it to 0xFFFF.
- vt 0x754 (FUN_00556b00) = `tactic.vt[8]()` = handle of the tactic's target (base `MobActionBase` 0xFFFF; Attack,
  Chase, BackStep and AvoidOverlap return their target cell, §7.1); vt 0x75c (FUN_00556b10)
  = `tactic.vt[0xc]()` = the target object.
- **Battle state** `+0x24b0`: 0 idle, 1 battle, 2 recover. `vt 0x588` FUN_00556d70 is "I am fighting":
  `m.lastBattle (+0xfb8) = g_Now`; on the change 0 → 1, if the mob has a MobKillLog row, a map-wide notice
  `AxialListMobKillLog(1, 0x38e, mobId)` (the MK2_START announcement, D05 / Z03 §8.1); state = 1. It is called by every
  attack path: `so_attack`, `so_smash`, `so_skillsmash`, `so_Bash`, `smo_SwingDamage`, `smo_SkillBlast`, both
  `so_smo_CrossCounterDamage` and the tactic `MobActionWaitSkillEnd` (Z03 / part 4).
- `vt 0x58c` FUN_00555570: in battle = `g_Now <= lastBattle + 100` (10 s).

```pseudo
ShineMob::sm_DuringBattle(m)                     (battle state 1, each tick)  @ FUN_00568d30
    if not regenAniOver: return
    if m.vt[0x58c]():                                       # fought within the last 10 s
        if m.HP < MobInfo.MaxHP * 0x19a / 1024 (≈ 40 %):
            t = som_GetObject(m.vt[0x754]())
            if t:
                if not rescueFlags (+0x24bc) bit 2: MobChatManager::mcm_HelpReqChat(m); set bit 2     # part 4
                sm_Scream4Rescue(m, t, MobInfoServer.FamilyRescArea, MobInfoServer.FamilyRescCount, 1)
            rescueFlags bit 0 = 0
        return
    # 10 s without fighting: the battle is over
    if m is on a field and its position is blocked in either block bitmap of the map (FUN_0049df00 / FUN_0049df70,
       cell = coord × 8 / 50; outside the bitmap counts as blocked):
        m.vt[0xf28]()                                       # FUN_0055d5b0 → vt 0xf2c(spawn point +0x249c): back to the spawn point (part 5)
    rescueFlags bit 2 = 0                                   # may chat again
    battle state = flags24ac & 2                            # 2 = recover (bit 1 is set at spawn, §5.3), else 0
    m.+0x1fb0 = 0                                           # (part 4)
    HitMeList reset (FUN_00482e80): attacker units, the per-character damage list (+0x198) and the total (+0x1a8)
    m.targetSelector.vt[0x14]()                             # mts_AggroClear: the mob forgets everyone

ShineMob::sm_DuringRecover(m)                    (battle state 2, each tick)  @ FUN_0056b710
    if not regenAniOver or g_Now <= m.lastHPRecover (+0xea0) + 30: return          # one step every 3 s
    if mode == 3: battle state = 0; return
    m.so_recoverhp(scriptHPRegen (+0x2554) >= 0 ? scriptHPRegen : MaxHP / 10);  lastHPRecover = g_Now   (vt 0x5b4)
    m.so_recoversp(MaxSP / 10);  lastSPRecover (+0xea4) = g_Now                                          (vt 0x5b8)
    if HP >= MaxHP (+0xea8) and SP >= MaxSP (+0xeac):
        battle state = 0
        if on a field: cc_ScriptInterrupt(field.cinema (+0x44), sim_MobHPFull (FUN_0050c840), { u16 m.handle })
            # "mob HP full" interrupt to the map scripts (part 9b). Z09-B5 is withdrawn: part 3 had read FUN_0050c840
            # as sim_ObjectDead (that is FUN_0050c950); the PDB names settle it
        rescueFlags bit 0 = 1
    so_AllOfRange(m, sight, so_ply_Send2WhoTargetMe)  # every player whose target is m gets 0x2402 NC_BAT_TARGETINFO_CMD (Z03 §2.4)
```

So a mob regains 10 % HP and SP every 3 s after a fight (or the script value per step), and the players who target it
see the bar fill. During battle the mob does not regenerate (the `PceHPRcv*` / `AtkHPRcv*` columns are not read by the
code of this section; part 4 checks the tactics).

### 6.6 Calling for help (`sm_Scream4Rescue`, `so_RescueRoutine`)

```pseudo
ShineMob::sm_Scream4Rescue(m, target, range, count, flag)                       @ FUN_00568bf0
    race = MobInfoServer.MobRaceType;  if race == 0 or range <= 0: return
    if target == null: log "ShineObjectClass::ShineMob::sm_Scream4Rescue : Target not found"; return
    so_AllOfRange(m, m.pos, range, AxialListRescueRequest{ target, target.handle, race, count, flag })

AxialListRescueRequest::ali_Work(req, m, o) → continue                          @ FUN_00568ad0
    if req.count < 1: return stop
    if o.MobInfoServer.MobRaceType == race and (o.vt[0x754]() == 0xFFFF or == req.target.handle):   # idle or already on it
        o.vt[0x764](m, flag)           # FUN_00556b30: o.rescueOf (+0x24c0) = m; rescueFlags bit 1 = flag
        req.count −= 1

ShineMob::so_RescueRoutine(h)                    (each tick while h.rescueOf != 0, §5.4)          @ FUN_00569050
    v = h.rescueOf
    if v.mode != 2 (alive) or v.vt[0x754]() == 0xFFFF: h.rescueOf = 0; h.lastSeenHP (+0x24c4) = 60000; return
    t = som_GetObject(v's target handle);  if t == null: log "…so_RescueRoutine : Null target"; same reset; return
    if v.HP < h.lastSeenHP:                             # the friend was hurt since the last look
        h.so_mob_AppendAggro(t, 1)                      # the helper joins with 1 aggro point (and spreads it to its own family)
        h.lastSeenHP = v.HP
        if not rescueFlags bit 2: (bit 1 ? MobChatManager::mcm_HelpAckChat : mcm_DetectBattleChat)(h); set bit 2
```

Two kinds of calls: **every hit** on a mob (`so_DamagedBy`, Z03 §7) calls `sm_Scream4Rescue(attacker,
FamilyArea, 999, 0)`: all idle mobs of the same `MobRaceType` within `FamilyArea` start watching (2016 data: 676 mob
types have a FamilyArea, mostly 350). **Below 40 % HP** in battle the mob calls `(target, FamilyRescArea,
FamilyRescCount, 1)` every tick (count 1…5 helpers). The helper attacks only after its friend loses HP again.
(original bug) Z09-B4: `lastSeenHP` starts at 60000 and is reset to 60000, so for a friend with more than 60000 HP
(155 mob types with a MobRaceType in 2016 data) the helper joins only once that friend is below 60000 HP.

### 6.7 Target-type checks for mob weapons (`so_mob_CanMyTarget`, `so_ply_CanMyTarget`, friends, NPCs)

These answer "may weapon `i` of the attacker's list be used on this object" from `MobWeapon.AtkType` (+0x4f; enum
`ATKTYPE` *(pdb2016)*: 0 SKLTP_DAMAGE, 1 SKLTP_HEAL, 2 SKLTP_ABSTATE, 3 SKLTP_SPECIAL, 4 SKLTP_DISPEL). `list` is the
attacker's MobDataBox entry (+8 = weapon list, §5.1); a non-null result is the object itself. Callers are the tactics
(`MobActionAttack` vt 0x760, `MobActionTargetting` vt 0x748 / 0x750, part 4).

```pseudo
ShineMob::so_mob_CanMyTarget(me, list, i)        (vt 0x74c, "use it on myself")               @ FUN_004ade40
    HEAL: me if HP < MaxHP / 2
    ABSTATE: me if one of the weapon skill's 4 abstates (ActiveSkill +0x40, 3 ints each, 0x318 = none) is not on me
             (FUN_0042b060 = abstate slot lookup in me+0xe7c)
    DISPEL: me if I have a bad abstate (asl_IsHereBad)
    DAMAGE / SPECIAL: null
ShineMob::so_ply_CanMyTarget(o, attacker, i)     (vt 0x760, mob o as target)                  @ FUN_004ae010
    o.vt[0x4d0]() == 4 (object kind 4): null
    DAMAGE: o if not same side;  HEAL: o if same side;  ABSTATE: not same side and an abstate missing (as above)
    DISPEL: same side → o if it has a bad abstate; else → o if it has a good one;  SPECIAL: null
ShinePlayer::so_ply_CanMyTarget(p, attacker, i)  (vt 0x760)                                    @ FUN_004ae280
    DAMAGE: p;  ABSTATE: p if an abstate is missing;  DISPEL: p if it has a good abstate;  HEAL / SPECIAL: null
ShineObject versions (FUN_004accd0, FUN_004ace80): null

ShineMob::so_mob_FindMyRaceTarget(m, list, i)    (vt 0x748)                                    @ FUN_004acbd0
    so_AllOfRange(m, 500, AxialListNearFriend{list, i}) → first hit, or 0
    AxialListNearFriend::ali_Work @ FUN_004aca50: skip dead; o.race (vt 0x714) != 0 and == m.race:
        result = o.so_mob_CanMyTarget(list, i); stop at the first result
    (base ShineObject FUN_004acb80: 0)
ShineObject::so_mob_CanNPCTarget(m)              (vt 0x750, mob version)                        @ FUN_004acd70
    so_AllOfRange(m, 500, AxialListNPCTargetFind{ mobId 0xbc (188), n = 1 }) → result
    AxialListNPCTargetFind::ali_Work @ FUN_004abd80: for objects with mob ID 188: the first one is taken; for later ones
        (n in 1…100) a value from the per-n random ring DAT_14d720d0 (0x8008-byte blocks) decides whether it replaces
        the choice (reservoir-style pick *(inferred)*); n += 1
    (base FUN_004acd20: 0)
```

`MOBATTACKTARGET` *(pdb2016)*: `MAT_ENEMY 0, MAT_ME 1, MAT_MYRACE 2, MAT_NONE 3, MAT_NPC 4` = `MobWeapon.MopAttackTarget`
(+0x69); the mapping to the four functions above (ME → vt 0x74c, MYRACE → vt 0x748, NPC → vt 0x750) is part 4's tactic code.
Mob ID 188 is the only NPC type a mob can pick as a target (MobInfo row 188; the escort / defence NPC *(inferred)*).

### 6.8 Script and GM access to aggro and AI

| Function | Behaviour |
|---|---|
| `cAggroSet(mob, obj, n)` FUN_005d9370 | `mob.vt[0x700](obj, n or 1)` |
| `cAggroReset(mob, obj)` FUN_005e1280 | `mob.vt[0x704](obj, 1000)`: obj's aggro drops to 1 |
| `cAggroListSize(mob)` FUN_005f2f70 | count from `vt 0xb88` |
| `cAggroList(mob)` FUN_005f3250 | pushes every handle of `vt 0xb88`; returns their number |
| `cTargetHandle(mob)` FUN_005ef430 | if `so_mob_CurrentTarget` (vt 0xb78) is an object within 999999999 distance² and the mob is not dead: returns that handle |
| `so_mob_GetAggroList(m, vec)` vt 0xb88 FUN_005d4dd0 | clears vec, `selector.vt[0x2c](vec)` (base FUN_005d4d50: −1) |
| GM `&viewaggrolist` (level 50, FUN_004196f0) | target = `gm.vt[0x75c]()` or the GM; if on a field: `target.so_mob_ViewAggroList(gm)` |
| `so_mob_ViewAggroList(m, gm)` vt 0x6fc FUN_0042d2a0 | `selector.vt[0x18](gm)`: GM notice per entry `"%d) %s : %d"` (index, name, aggro); without a selector a fixed notice (DAT_006aa168) |
| `so_AILearn(o, script)` vt 0xb60 FUN_005d5430 / mob FUN_005d5500 | null → vt 0xc14 (clear); else `o.script (+0x7e) = script`, function name (+0x82) = `"Entrance"`, for mobs `MobInfo.InxName` |
| `so_AITraining(o, other)` vt 0xb5c FUN_005d2680 | `other.so_AILearn(o.script)` (copy the AI script) |
| `so_EscapeFromTarget(o)` vt 0x64c FUN_00435ba0 | `AxialListTargetChange{o.handle, null}` over sight: every player (kind 2, vt 0x4d0) whose target (vt 0xa04) is o gets `so_ply_TargetChange(null)` (vt 0x998, Z03 §2.3 → 0x244D) (ali_Work FUN_00435ac0). Callers: magic-field damage, `smo_MagicFieldSpread`, `smo_SkillBash_Blast_Obj` |

The Lua bindings themselves (argument reading FUN_005f7680 / FUN_005f7ad0, result push FUN_005f8110) are part 9;
`cSetAIScript` / `cAIScriptSet` (callers of vt 0xb60 / 0xb5c) are listed for part 10.

### 6.9 Not in this section

- `MobTargetPlayerCaptivate` (`ali_Work` FUN_004add20, `mts_Initialize` FUN_004abde0, `mts_SelectTarget` FUN_004abe10): §8.10.
- `FamilyMobManagement::FamilyMobManager` (`fmm_Initialize` FUN_004b5050, `fmm_Dead` FUN_004b5120, `fmm_Remove`
  FUN_004b5a40, `fmm_Regist` FUN_004b5cf0) is a per-breeder-group table `{u16 mobId, u16 limit (default 60000), u16
  dead count}`: `fmm_Dead` counts a death and returns `count >= limit`. All callers are `MobBreeder` /
  `MobBreederGroup` (part 6), which documents it with the regen data.
- `HitMeList::EnemyList::el_Store` FUN_00482070 (attacker units: kind 0 single `{charNo vt 0x564, u16 vt 0x568}`, 1 party
  `vt 0x560`, 2 raid `vt 0xa84 → +4`; compare `e_ObjCompare` FUN_004816b0; when the list is full the unit with the
  least damage is replaced (`ListMaximumSearch`), else log "HitMeList::EnemyList::el_Store") is called only from the
  death path FUN_00483030 (Z03 §8.1). The per-character damage list FUN_00482f00 (Z03's "Add"): up to 100 entries
  `{charNo, → object, time, damage}` (pets resolve to their owner through vt 0x9b0; only kind-2 objects = players are
  counted); when full, the oldest entry is overwritten. `el_FindLooter` FUN_004822f0 is part 7.
- `MobBehaviorDescript/` (`DefaultBehavior.ps` and 7 `KQ/*.ps`): PineScript text (`whoistarget`, `permillage`, `chat`,
  `whokillme`); no zone string names the folder or a `.ps` path of it: the 2016 zone does not read it (§20.1).
- Other aggro sources, documented with their owners: the map-script node `PineEventScriptNode::ShineAggro::sa_Step`
  FUN_004f2d10 (§23.4), `AxialListMagicFieldAggro` (`alns_ValidObject` FUN_0057a980, `almfa_AppendAggro` FUN_0057aad0;
  part 8), the tactic base `MobActionElement::mae_Action` FUN_004aa880 (part 4).
- `MobChatManager` (`DAT_0084cc84`; `mcm_HelpReqChat`, `mcm_HelpAckChat`, `mcm_DetectBattleChat`, `mcm_DamageChat`) and
  the per-mob-ID objects `DAT_0084cc8c` (= `MobChatManager`+8, the PIECE array; they give the `+0x1ea8` delay of §5.2):
  §8.6.

---

## 7. Mob AI 2a: tactic state machine, weapons, attack sequences

Part 4a. The brain of §6 picks *whom*; the tactic state machine here decides *what to do next* (wander, chase, turn,
attack, back off, go home), which weapon (normal attack or skill) to use, and when. Script-side setters
(`so_mob_Skill*AtScript`, weapon rates, `cMobWeaponRate`), mob chat, explosions, cross-counter, boss abstates and the
damage / heal target checks are §8 (part 4b).

### 7.1 The tactic context and its states

`ShineMob::so_Routine` (§5.4) runs one step per tick: `m.tactic = m.tactic.vt[0](&ctx)`. The context `ctx` is the block
at **mob+0x1fc4**, member `sm_ArtificalIntelligence`, type `MobTacticElement::MobActionArgument` (0x324 bytes) *(pdb2016)*:
`ctx+0 maa_MobHandle` (u16, the list slot index the routine walk passes, §1.3), `ctx+4 maa_Mob` (→ self). Everything
below gives context offsets, in brackets mob offsets, and the PDB member (`Selector maa_TargetSelect` +8, `Actor
maa_MobActionStruct` +0x274).
The same block is allocated for a **captivated player** (§7.7), so the code never uses mob offsets directly.

| ctx offset [mob] | Object | Kind |
|---|---|---|
| +0x008 [+0x1fcc] | `MobAggroManager` `targetlist` + selectors (§6.1) | |
| +0x270 [+0x2234] | `selector`: → active target selector (§6.1) | |
| +0x274 [+0x2238] | `inmove`: `MobActionInMove` `{vt, maim_NextReserv}` | tactic set (`Actor`), built by `MobActionArgument::Actor::Actor` FUN_00549bc0 (so `+0x2238` is not an "aggro container" as §5.2 said: `MobActionArgument::Actor::SetTargetPoint FUN_004b8c80(set, cell)` at spawn stores the shared **target cell** `&mob+0x24e0` into every element through vt 0x14) |
| +0x27c [+0x2240] | `inmove_cancelable`: `MobActionInMove_Cancelable` `{vt, maim_NextReserv}` | |
| +0x284 [+0x2248] | `inmove_chase`: `MobActionInChase` `{vt, maic_Target, maic_NextAttack (next on arrival), maic_NextChase (next if the target moved), maic_WhereIsTargetGoing (target destination x, y)}` | |
| +0x29c [+0x2260] | `wander`: `MobActionWander` `{vt, Metronome maw_ReturnTick, maw_SearchTick, maw_WanderTick}` (`Metronome {m_NextTick, m_TickInterval}`; ctor FUN_004b8ad0) | |
| +0x2b8 [+0x227c] | `attack`: `MobActionAttack` `{vt, mant_Target (→ cell, a MobBrainTargetObject), mat_NextAttackTick, maa_SkillFromScript {u16 nextskillid (0xFFFF none) +0xc, int nextskillorder (weapon index) +0x10, → target +0x14}}` (ctor FUN_004b9540) | |
| +0x2d0 [+0x2294] | `chase`: `MobActionChase` `{vt, mant_Target (→ cell)}` | |
| +0x2d8 [+0x229c] | `backstep`: `MobActionBackStep` `{vt, mant_Target, u8 mabs_Mode}` (used as an extra distance, §7.3) | |
| +0x2e4 [+0x22a8] | `avoidoverlap`: `MobActionAvoidOverlap` `{vt, mant_Target}` | |
| +0x2ec [+0x22b0] | `waitskillend`: `MobActionWaitSkillEnd` `{vt, mawse_EndTime, mawse_NextAction, mawse_Target}` | |
| +0x2fc [+0x22c0] | `swingdamage`: `MobActionSwingDamage` `{vt, masd_Delay, masd_Target, masd_Next}` | |
| +0x30c [+0x22d0] | `turning`: `MobActionTurning` `{vt, mat_NextAction, mat_Target, u16 mat_TurnSpeed, mat_LastTurn}` | |
| +0x320 [+0x22e4] | `action`: → current state | |

Singletons (one object for all mobs; static members of `MobActionArgument::Actor` *(pdb2016)*): `base` (`MobActionBase`)
0x84cfb8, **`targetting` (`MobActionTargetting`) 0x84cfbc** (the hub every state falls back to), `toregion`
(`MobAction2Region`) 0x84cfc0, `roaming` (`MobActionRoaming`) 0x84cfc4, `nobrain` (`MobActionNoBrain`) 0x84cfc8,
`return2regen` (`DuringReturn2Regen`) 0x84cfcc. The "cell" is a pointer to the shared target slot
(mob+0x24e0, read by vt 0xa04); writing `*cell = obj` before switching state hands the target over.

**Element vtable** (byte slots; all classes):

| Slot | Meaning | Implementations |
|---|---|---|
| 0x00 | `mab_Think(ctx)` → next state | per class (below); `MobActionBase` FUN_004b8ec0 → Targetting; `MobActionNoBrain` FUN_004b8c50 → itself (never moves, never fights; the PDB gives this address the name of an identical folded function, `PineScriptTracer::ScriptTracer::operator<<`) |
| 0x04 | damaged notify (`so_DamagedBy`, §6) | `MobActionWander` and `InMove_Cancelable` `MobActionInMove_Cancelable::mab_Damaged` FUN_004b8c10: `so_mobile_StopHere` (vt 0xa48), state = Targetting; others no-op |
| 0x08 / 0x0c | target handle / object (mob vt 0x754 / 0x75c, §6.5) | Attack, Chase, BackStep, AvoidOverlap: `MobActionNeededTarget::mab_GetTargetHandle` FUN_004b8a60 / `MobActionNeededTarget::mab_GetTargetObject` FUN_004b8a80 (`*cell`); others 0xFFFF / 0; `WaitSkillEnd` +0xc: FUN_00461b70 (folded body; PDB symbol `AxialListMobCounter::almc_HowMany`) |
| 0x10 | re-plan (mob vt 0x8f8, §6) | `MobActionBase::mab_TargetChange` FUN_004b8c40 → Targetting (all) |
| 0x14 | bind the target cell | FUN_00653a60 (folded body; PDB symbol `UseEffect::UseItemRide::uir_SetSkill`) (`this+4 = cell`) for Attack, Chase, BackStep, AvoidOverlap; others no-op |
| 0x18 | `mab_SkillRegistAtScript` | Attack FUN_004b9400 (§8); base FUN_004b93b0 returns false |
| 0x1c | "waiting for a skill to end" | `WaitSkillEnd` FUN_005af8d0 → 1 (a folded `return 1` the PDB names `ShineObject::so_Gamble_IsGambleHouse`); others 0 |

`MobActionElement` (vftable 0x6c15b4, ctor FUN_004a9b00, dtor `MobActionElement::scalar deleting destructor` FUN_004a9dc0) is an unrelated base whose `mae_Action`
FUN_004aa880 returns a static empty object; no caller of it was found.

Helpers used throughout (mob slots unless noted):

| Helper | Meaning |
|---|---|
| `MobTargetSelector::mts_TargetObject FUN_004b8830(selector)` | the selector's current target object, or **0 when it has StaImmortal (291) or StaAdlFLoussierIMT (499)** (the name is copied to a debug ring) |
| `ShineMob::sm_SetTarget` FUN_004b8930 | +0x24ae, raises `sim_TargetChange` (§6.5) |
| vt 0x510(t) `ShineMob::so_AttackRange` FUN_005566c0 | attack reach to `t` = `t.vt[0x6cc]()` (body size) + current weapon `Range` (+0x67); 99999 without a weapon |
| vt 0x514 / 0x518 | walk / run speed: script override (vt 0xe84/0xe8c, 0xe88/0xe90) else (script +0x254c / +0x2550 ≥ 0 ? it : MobInfo.WalkSpeed / RunSpeed) × speed rate (+0x1c00) / 1000, clamped ≥ 0 (`ShineMob::so_WalkSpeed` FUN_00556740 / `ShineMob::so_RunSpeed` FUN_005567b0) |
| vt 0x610 | moving (`MoveManager` +0x1ac, part 5); vt 0x7b4 move mode (+0x18c: 1 walk, 2 run), vt 0x7b0 current speed (+0x194) |
| vt 0x60c | the object's move destination (+0x1a0) |
| vt 0x614 / 0x618 | spawn point +0x249c / return point +0x24a4 |
| vt 0x61c | leash² = `MobInfoServer.FollowCha` (+0x44)² |
| vt 0xb34(t) / vt 0xb38 | rest until `t` (+0x2500) / resting (`g_Now < +0x2500`, else clears it) |
| vt 0xa08(v) | target-order byte +0x24e5; sets the dirty flag +0x24e4 when target or order changed (§5.2) |
| vt 0xf54 / 0xf4c / 0xf50 | set / read "was chasing" (+0x24ac bit 3) / spawn point := the current scenario path point (`ShineMob::smo_RegenSpotAsNextRoamingSpot` FUN_004b7690, path vector +0x1eb8, 0x2a-byte points, index +0x1ebc) |
| vt 0xa18 | scenario path vector +0x1eb8 (part 5); non-zero = walk the path instead of wandering |
| `Metronome::operator unsigned char FUN_004011c0(timer)` | periodic timer `{next, period}`: fires when `next < g_Now`, then `next += period` |
| `ShineObject::so_FindBlockLocate(o, pos, r, out, bitmap)` | nearest unblocked point to `pos` within `r` (part 5) |
| `g_NewBlockRule DAT_0084cfb4` | "use `Navigator`" byte, initial value **1** and never written: the old block path finder branches (`FieldMap::fm_FindWayInit` FUN_004a9ae0 + `CFindWay::FindWay` FUN_00632ba0 / `CFindWay::SetLoadedData` FUN_00632450, "Path not found", "MobThink_Chase::mtc_pathfind : Zero path") are dead in 2016 |

### 7.2 Idle states: Targetting, Wander, Roaming, going home

```pseudo
MobActionTargetting::mab_Think(ctx)                                             @ FUN_004b99e0
    s = ctx.self
    if s is not a ShineMob:                         # captivated player (§7.7)
        sel.vt[0x28](s);  t = FUN_004b8830(sel)
        if s.vt[0xa04]() != t and player state (+0x2a790) in {2, 3}: s.smo_BashStop()          # vt 0xed8
        if t and SameLayer(s, t): *cell = t; return Attack
        return Wander
    f = s.vt[0xf78]()                               # ShineServant: +0x2570 (part 8); ShineMob: 0
    if f and f != s.vt[0x9b0]() (master) and SameLayer(s, f): s.vt[0xa08](1); Chase.cell = f; return Chase
    sel.vt[0x28](s)                                 # mt_SelectTarget (§6.3)
    t = FUN_004b8830(sel)
    if not t or not SameLayer(s, t):
        SetCurrentTarget(s, 0xFFFF)
        return roaming flag (+0x24d8 bit 0) ? Roaming : Wander
    SetCurrentTarget(s, t.handle)
    i = s.so_mob_SelectWeapon(t, advance = 0)       # vt 0x73c, §7.4
    if i < 0: return Targetting                     # nothing usable now; try next tick
    w = weapon i of the MobDataBox entry; if no row: log "MobActionTargetting::mab_Think : Null Weapon"; return Targetting
    o = weapon target (§7.5) by w.MopAttackTarget
    if o:
        (t or o having 291 / 499 is only logged)
        s.vt[0xa08](1); *cell = t; return Attack    # note: the cell gets the selector's target, not o
    # the weapon cannot be used on anybody now: skip it
    ShineMob::sm_NextAttackSequence FUN_004b8c60(s)                                 # advance the attack sequence (§7.6)
    s.vt[0x718]()                                   # weapon cooldown (§7.4)
    return Targetting
```

```pseudo
MobActionWander::mab_Think(ctx)          (per mob, +0x2260)                     @ FUN_004bb790
    s.vt[0xa08](0)
    if s.param.flags (+0xcce) & 3  or  MobInfo.WalkSpeed == 0: return Targetting   # bits 0/1: movement blocked (inferred)
    if s.vt[0xa18]():                                # scenario path
        InMove_Cancelable.next = this
        return mab_RandomDirectWalk(s, -1, InMove_Cancelable, this)
    if maw_ReturnTick fired: return 2Region          # every (r + 55) s: go home
    if maw_SearchTick fired: return Targetting       # every 1 s: look for targets
    if s is a ShineMob and its chat timer (+0x1ea8, §5.2) fired: MobChatManager::mcm_WanderChat(s)    # §8
    if maw_WanderTick fired (1 s) and rand(100) < 5:        # random ring rndbox DAT_14d720d0
        InMove_Cancelable.next = this
        return mab_RandomDirectWalk(s, 30 + rand(20), InMove_Cancelable, this)
    return this

MobActionWander::maw_MetronomeReset(w)                                          @ FUN_004b9210
    r = next value of the u16 random ring DAT_14dc2120 (= RandomRing(10): 0…9, §28.4)
    maw_ReturnTick = { g_Now + (r + 55) × 10, (r + 55) × 10 };  maw_SearchTick = maw_WanderTick = { g_Now + 10, 10 }
```

`maw_MetronomeReset` runs at spawn when the mob starts in Wander (§5.3).

```pseudo
MobActionRoaming::mab_Think(ctx)                                                @ FUN_004bc3a0
    s = ShineMob(ctx.self) or return Targetting
    if s.kind (vt 0x4d0) == 10 (ShineServant):
        InMove_Cancelable.next = this; return mab_RandomDirectWalk(s, RoamingDistance (+0x24da), InMove_Cancelable, this)
    n = RoamingNumber ((+0x24d8 >> 1) & 0x7f)
    if n == 0:
        return position != spawn point ? 2Region : Targetting
    if walks done (u8 +0x24d9) >= n: walks done = 0; return 2Region
    if not resting (vt 0xb38):
        walks done += 1; InMove_Cancelable.next = this
        return mab_RandomDirectWalk(s, RoamingDistance, InMove_Cancelable, this)
    return Targetting

MobAction2Region::mab_Think(ctx)               ("back to the region")          @ FUN_004ba1d0
    s.vt[0xa08](0)
    if MobInfoServer.Return2Regen (+0x92):
        mab_RunTo(s, spawn point (vt 0x614));  ShineMob: return point (+0x24a4) = spawn point (+0x249c)
        return DuringReturn2Regen
    # no return: the mob makes its current place its home
    ShineMob: spawn point = return point = current position
              rest until g_Now + RoamingRestTime (+0x97) × 10 / 1000          # vt 0xb34; ms → tenths
    return Targetting

DuringReturn2Regen::mab_Think(ctx)                                              @ FUN_004b9010
    if s is moving: return this
    rest until g_Now + RoamingRestTime × 10 / 1000; return Targetting

MobActionInMove::mab_Think(ctx)        (both InMove classes)                    @ FUN_004b8f10
    sel.vt[0x28](s)
    if FUN_004b8830(sel): return Targetting          # a target appeared: stop wandering
    return s.moving ? this : this.next
```

The `mab_RandomDirectWalk(s, dist, inMove, stay)` @ FUN_004babe0 helper (ShineMob only, else returns `stay`):

```pseudo
    if dist == -1:                                   # scenario path
        if resting: return Targetting
        if not ShineMob::sm_NextPathPoint(s, &dx, &dy, &dist, &atEnd) (part 5): return stay
        if atEnd: rest until g_Now + 50 (5 s); return Targetting
        if s.vt[0xf4c]() (was chasing): s.vt[0xf50]() (spawn point := current path point); return 2Region
    else:
        if not s.vt[0xc58](&dir, &dist) (ShineMob: always false): dir = next value of ring DAT_14f722d0 × 180 / 64
        dx, dy = cos/sin table shineradian DAT_13283770 (ShineRadian::sr_sin1024 FUN_005790e0 / ShineRadian::sr_cos1024 FUN_00579110) × dist / 1024
    p = FindBlockLocate(s, pos + (dx, dy), 2 × dist, bitmap A); then FindBlockLocate(that, 2 × dist, bitmap B)
    if both found and p != position: mab_WalkTo(s, p); return inMove
    (vt 0xc5c / 0xc60: ShineMob no-op)
    return stay
```

### 7.3 Fighting states

```pseudo
MobActionAttack::mab_Think(ctx)        (per mob, +0x227c)                       @ FUN_004bba00
    t = *cell
    if g_Now < this.nextAttack (+8): Chase.cell = t; return Chase          # cooling down: keep up with the target
    if ShineMob and (f = vt 0xf78()) != 0: Chase.cell = f; return Chase    # servant
    if s.param.flags (+0xcce) & 4: return Targetting                        # cannot attack (Z03 §4)
    if not t: log "MobActionAttack::mab_Think : Target Null"; return Targetting
    if t closing (vt 0x300) or t.mode in {3 dead, 0 spawning} or t.IsDead(): return Targetting
    if s.IsCasting(): return this
    if not SameLayer(s, t) or t is a captivated player: return Targetting
    if t has StaImmortal (291) or StaAdlFLoussierIMT (499): return Targetting
    if MobInfoServer.TurnSpeed (+0x9c) != 0 and the angle from s's direction to t > 15 (2° units, ddt_ShineRadianDiff):
        return Turning.set(next = this, s, t)                              # MobActionTurning::mat_Reserv FUN_004b8a00, §7.3 Turning
    if FindBlockLocate(s, t.pos, 10000, bitmap A) != t.pos:                # target stands on a blocked cell
        return rand(1000) < 800 ? (Chase.cell = t; Chase) : Targetting
    if s moving: StopHere
    if this.nextskillid (+0xc) == 0xFFFF: s.so_mob_SelectWeapon(t, advance = 1)   # §7.4
    else: s.so_mob_SetWeaponAsScript(low byte of this.nextskillorder (+0x10))        # vt 0xb74, §8
    if s is not a ShineMob:                                                 # captivated player
        return MobActionAttack::mab_CaptivatePlayerAttack FUN_004ba0d0(this, ctx)                                      # §7.7
    sm_SkillExchange_HPLow(s); ShineMob::sm_SkillExchange_HPLow_ChangeOrder FUN_004bb600(s) (HPLow_ChangeOrder)          # §7.6
    i = current weapon (+0x1fa8, vt 0x740); if i < 0: return this
    o = weapon target of weapon i (§7.5)                                    # MAT_NONE / unknown → log, o = 0
    if this.maa_SkillFromScript.target (+0x14): o = it; maa_SkillFromScriptClear(this)    # FUN_004b9470
    if not o: return Targetting
    d² = dist²(o, s)
    if d² > reach(o)²: sm_SkillExchange_TargetState(s, o)                   # §7.6 (yes: only when out of reach)
    if d² > reach(o)² (reach of the possibly exchanged weapon) and not sm_SkillExchange_OutOfRange(s):
        return rand(1000) < 800 ? (Chase.cell = o; Chase) : Targetting
    # attack now
    sm_UseWeapon(s, o)                                                      # §7.4
    s.vt[0x718]()                                                           # weapon cooldown
    r = min(reach(t) / 4, 150)
    swing = SwingTime (+0x4b) tenths (vt 0x71c);  cast = skill CastTime (ShineMob::sm_GetWeaponCastTime FUN_004b88e0, 0 for weapon 0)
    next = d² < r² ? (i == 0 and rand(5) == 0 ? (BackStep.cell = t, BackStep.extra = 0, BackStep) : this) : Targetting
    if 0 <= i < weapon count:
        k = max(1, SwingTime_ms × 128 / max(1, AtkSpd))
        rate = param[0xa18] (attack-speed rate, Z03 knowledge)
        A = (SwingTime_t × 128 / k) × rate / 1000       # whole swing ≈ AtkSpd scaled by the rate
        B = (HitTime_t  × 128 / k) × rate / 1000       # moment of the hit
        D = AtkDly_t × rate / 1000                     # pause after the swing   (all ≥ 0; _t = ms × 10 / 1000)
        this.nextAttack = g_Now + D + A + cast
    if i == 0:                                         # normal attack: two-phase
        s.flags24ac |= 4
        SwingDamage.set(delay = A − B, next, target = o)                    # masd_SetDelay FUN_004b9340
        return WaitSkillEnd.set(B, SwingDamage, o)                          # mawse_SetNextAction FUN_004b92c0
    return WaitSkillEnd.set(cast + swing, next, o)                          # (A / B are not used for skills)

MobActionWaitSkillEnd::mab_Think(ctx)                                           @ FUN_004b9140
    s.vt[0x588]()                                    # "I am fighting" (§6.5)
    return g_Now >= this.until ? this.next : this

MobActionSwingDamage::mab_Think(ctx)                                            @ FUN_004baac0
    ShineMob: flags24ac &= ~4
    s.vt[0xeec](this.target, 0x318, 0, 0, 0)        # ShineMob FUN_00433a70: smo_SwingDamage(s, target, weapon abstate,
                                                    #   StaStrength +0x92, StaRate +0x94, AggroInitialize +0x96) (Z03 §2)
    return WaitSkillEnd.set(this.delay, this.next, this.target)
```

So a mob's normal attack is: `0x2447 NC_BAT_SWING_START_CMD` (from `smo_SwingStart` in `sm_UseWeapon`), wait `B`, the damage
packet of `smo_SwingDamage` (Z03 §2), wait `A − B`, then the next state; the next attack is allowed after
`D + A` from the start. `AggroInitialize` (5679 of 5818 weapons: 0) is passed to `smo_SwingDamage` (Z03 reads it).

```pseudo
MobActionChase::mab_Think(ctx)                                                  @ FUN_004bc950
    t = *cell
    if walk speed == 0 or s.param.flags & 3: return Targetting
    s.vt[0xf54]()                                    # mark "was chasing" (+0x24ac bit 3)
    if dist²(s, return point) > FollowCha²:          # leash
        ShineMob: s.vt[0xf74]() (ShineServant ShineServant::sm_TooLongChase FUN_004a3480: vt 0xf7c(0); mob no-op)
        return 2Region
    if dot(s − t.pos, s − t.destination) < 1:        # the target is coming at us / passing us
        mab_RunTo(s, t.pos); Attack.cell = t
        return InChase.set(t, Attack, this)          # MobActionInChase::maic_SetReserv FUN_004b89c0 (stores t's destination)
    # Navigator path (DAT_0084cfb4 = 1)
    if t.destination is blocked in the map's virtual map (field +0xa4, vm_IsBlocked): Attack.cell = t; return Attack
    n = Navigator::MapNavigator::mn_PathFind(field +0xa4, s.pos, t.destination, path)   (part 5)
    if n < 1: BackStep.extra = 10; BackStep.cell = t; return BackStep        # no path: step back
    wp = path[0];  direct = (n == 2)
    if direct:
        wp = t.destination
        if dist(s, wp) < reach(t): Attack.cell = t; return Attack
        wp += (s − wp) × (reach(t) × 8 / 10) / dist        # stop at 80 % of the reach
    if s is a ShineMob:
        dist(s, wp) <= MobInfoServer.WalkChase (+0x9e) ? mab_WalkTo(s, wp) : mab_RunTo(s, wp)
    else: s.smo_BashStop(); mab_RunTo(s, wp)       # captivated player
    Attack.cell = t
    return InChase.set(t, Attack, this)

MobActionInChase::mab_Think(ctx)                                                @ FUN_004b9760
    t = this.target
    if t invalid (closing, mode 3 / 0, dead): return 2Region
    if dist²(s, return point) > FollowCha²: ShineMob s.vt[0xf74](); return 2Region
    if t.destination != stored destination: return this.ifMoved (Chase: plan again)
    if not s.moving: return this.onArrival (Attack)
    # still moving: follow speed changes (slow / haste abstates)
    if move mode 1 and current speed != walk speed: mab_WalkTo(s, t.destination)
    if move mode 2 and current speed != run speed:  mab_RunTo(s, t.destination)
    return this

MobActionTurning (set FUN_004b8a00, think MobActionTurning::mab_Think FUN_004b9ea0):
    set(next, s, t): store; TurnSpeed = MobInfoServer.TurnSpeed; if 0: return next (no turning) else start = g_Now, return this
    think: if TurnSpeed == 0 or no s or no t: return next
        if dist(s, t) < 5: s.vt[0x660](t.pos, 1, 2, 0) (MoveStart); s.vt[0x7c4](); return next
        diff = angle from s.direction to t (2° units, sign)
        allowed = (g_Now − start) × 180000 / (TurnSpeed × 10)          # TurnSpeed = ms per full turn
        if allowed < diff:
            if allowed > 14: dir = s.direction + sign × allowed (mod 180); mab_RunTo(s, 3 units towards dir); start = g_Now
            return this
        mab_RunTo(s, 3 units towards t); start = g_Now; return next     # a 3-unit "run" is how a mob turns on the client

MobActionBackStep::mab_Think(ctx)                                               @ FUN_004ba390
    t = *cell
    if walk speed == 0 or flags & 3: return Targetting
    v = s − t;  if |v| == 0: AvoidOverlap.cell = t; return AvoidOverlap
    len = extra (+8) != 0 ? extra + |v| : reach(t) × 8 / 10
    p = t.pos + v scaled to len                      # straight away from the target
    if p blocked in bitmap A or B, or not fm_IsStraightPath(t.pos → p) in A or B: AvoidOverlap.cell = t; return AvoidOverlap
    if no field or not vm_IsStreight(s.pos, p): return Targetting
    mab_RunTo(s, p); Chase.cell = Attack.cell = t
    return InChase.set(t, Attack, Chase)

MobActionAvoidOverlap::mab_Think(ctx)            (two mobs on one spot)         @ FUN_004ba750
    t = *cell
    dir = random (ring DAT_14f722d0);  p = t.pos + (cos, sin)(dir) × reach(t) × 8 / 10
    if p blocked (bitmap A): Attack.cell = t; return Attack
    if no field or not vm_IsStreight(s.pos, p): return Targetting
    mab_RunTo(s, p); Chase.cell = Attack.cell = t
    InChase = { t, Attack, Chase, t.destination }; return InChase
```

**Movement packets** (`mab_WalkTo` @ FUN_004b8d30, `mab_RunTo` @ FUN_004b9590): `s.vt[0x660](dest, speed)` starts the
`MoveManager` (part 5), then

```pseudo
sight (so_AllOfRange, radius allofrangearg DAT_132826b4) ← 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD / 0x201A NC_ACT_SOMEONEMOVERUN_CMD {
    u16 handle, u32 from.x, from.y (current position), u32 to.x, to.y, u16 speed (vt 0x514 / 0x518), u16 flags (bit 0 = 0) }
the same 0x18-byte packet is kept in the object (+0x168 opcode, +0x16a… payload) for players who see the mob later (Z02 §5)
```

A player (captivated) does not send these itself: `mab_RunTo` calls `so_MoveByServer(dest, 0x1a, 0x49, 2, 0)` (vt 0x5b0,
part 5) instead. The layouts are the verified ones of Z02 (`docs/protocol/packets-zone.md` 0x2018 / 0x201A).

### 7.4 Weapons: choosing and using

A mob's weapons are its MobWeapon rows (`MobDataBox` entry +8, §5.1; index 0 = the normal attack, the others skills).
`MobWeapon.shn` (2016, 5818 rows, 0x98 bytes; columns from the SHN header): `ID u32 +0, InxName[33] +4, Skill[32] +0x25,
AtkSpd u16 +0x45, BlastRate +0x47, AtkDly +0x49, SwingTime +0x4b, HitTime +0x4d (ms), AtkType u32 +0x4f, MinWC +0x53,
MaxWC +0x57, TH u16 +0x5b, MinMA u32 +0x5d, MaxMA +0x61, MH u16 +0x65, Range +0x67, MopAttackTarget u32 +0x69, HitType u32
+0x6d, StaName[33] +0x71, StaStrength u16 +0x92, StaRate +0x94, AggroInitialize +0x96`.

Mob members: **+0x1fa8 current weapon index** (−1 none), +0x1f98 vector of per-weapon "usable again at" times,
+0x24c8/+0x24cc script vector of per-weapon rates (`sm_scene_SetWeaponRate`, §8).

```pseudo
ShineMob::sm_GetUseWeaponRate(m, i)                                                        @ FUN_004aa060
    i < script rate vector size ? vector[i] : (i < weapon count ? MobWeapon.BlastRate (+0x47) : 0)   # per mille

ShineMob::so_mob_SelectWeapon(m, t, advance)     (vt 0x73c)                     @ FUN_004ab720
    if smo_SkillBlastOption(m) == 2: weapon = 0; return 0         # FUN_0057c750: max over m's abstates of
                                                                  #   actor.vt[0x1c]; 2 = "normal attack only" (Z03)
    if m.attackSequence (+0x1fac) == 0:                            # no MobAttackSequence file
        for i = count−1 down to 0:                                 # last weapon first
            if row present and (no skill or m.SP (vt 0x4ec) >= skill SP (+0xa0)) and cooldown[i] <= g_Now
               and rand(1000) <= rate(m, i):
                weapon = i; return i
        weapon = −1; return −1
    pos = advance ? &m.sequencePos (+0x1fb0) : &copy                # a preview does not move the sequence
    weapon = ae4m_NextSkill(m.attackSequence, m, pos, advance)      # §7.6
    if dist²(m, t) > reach(t)² × 1.2 (double DAT_006c19f8): sm_SkillExchange_OutOfRange(m)
    return weapon
```

A sequence mob ignores cooldowns; a plain mob tries its skills from the last row down and falls back to the normal
attack only if the normal attack's own rate roll succeeds (BlastRate 1000 for 4794 rows). Callers: Targetting (preview),
Attack (advance), the script node `ShineMobWeaponRate` path (§8).

```pseudo
ShineMob::sm_UseWeapon(m, t)                                                    @ FUN_004ab9c0
    i = weapon; if i < 0: return
    m.flags1e78 &= ~2
    copy weapon i into m's stat matrix: +0x10a0 MinWC, +0x10a4 MaxWC, +0x10ac TH, +0x10b4 MinMA, +0x10b8 MaxMA, +0x10c0 MH
    if i == 0:
        smo_SwingStart(m, t)                         # 0x2447 NC_BAT_SWING_START_CMD to sight (Z03 §2)
        MobChatManager::mcm_AttackChat(m)            # §8
    else:
        sk = SkillDataBox::operator[](weapon skill)
        if not sk: log "ShineObjectClass::ShineMob::sm_UseWeapon : Null skill"; return
        if m.SP < sk.SP (+0xa0): log "…sm_UseWeapon : Minus sp"; return
        if sk.+0x130: m.flags1e78 |= 2               # "alternate damage path" (Z03 knowledge bit 1)
        tgt = sk.First (+0xb8) == 1 (ME) ? m : t;  pos = tgt.pos
        if sk.+0x220 == 1 and sk.+0x224 in {0, 2}:   # a SkillSpecial "random target" kind (offset mapping inferred, Z03 §5.1)
            if sk.First == 4 (SPOT): if not m.vt[0xc20](sk, &pos) (ShineMobileObject::so_smo_GetRandomTarget_Locate FUN_00579910: random point within Range): pos = tgt.pos
            else: o = m.vt[0xc1c](sk, Range, m) (ShineMobileObject::so_smo_GetRandomTarget_Object FUN_0057e660: random object of the Last target class in sight); if o: tgt = o
        if sk.+0x260 == 1 and sk.First == 4 and (o = m.vt[0xc1c](sk, Range, m)): pos = o.pos
        smo_SkillBash_Casting(m, sk, First == 4 ? null : tgt, First == 4 ? &pos : null, CastTime (+0xcb))   (Z03 §5)
        if sk.+0x238 == 1: ShineObject::so_DirectInfoBroadcast FUN_00553510(m, 0)        # sight ← 0xBC1C {u16 handle, u8 direction} (the "face direction"
                                                     #   broadcast that Z06 also uses under the 2017 name NC_GAMBLE_ENTER_PLAYER_DIRECT_CMD)
    if m.+0x1fb6 == 1: m.+0x1fb6 = 0                 # a chained NextSkill was used: the sequence does not advance
    else: FUN_004b8c60(m)                            # advance the sequence position (§7.6)
    for each abstate on m: aeo_Attack                # abstates that react to attacking (Z03 §6)

ShineMob::so_mob_SetWeaponHitTime (vt 0x718: cooldown)                                                             @ FUN_00556d00
    if weapon >= 0: cooldown[weapon] = g_Now + ceil(AttackSpeed / 100)       # tenths
ShineMob::so_attackspeed1000 (vt 0x508)                                                          @ FUN_00556640
    AtkSpd (+0x45) × param[0xa18] / 1000 (≥ 0); 99999 when weapon < 0 or the row is missing
    (the row is read before the index is checked; the only mob caller, vt 0x718, checks the index first, so this
     does not fault; the other vt 0x508 callers are the player schedule functions ShinePlayer::sp_Schedule_SwingDamage FUN_0042f550 / ShinePlayer::sp_Schedule_SwingStart FUN_00430bc0, Z03)
swing time (vt 0x71c)  ShineMob::so_mob_SetWeaponAniTime FUN_005564f0: SwingTime × 10 / 1000 tenths (0 without a weapon)
```

### 7.5 Weapon target by `MopAttackTarget`

Both Targetting and Attack resolve "on whom is weapon `i` used" the same way (`MOBATTACKTARGET` *(pdb2016)*; 2016 data:
ENEMY 4898, ME 80, MYRACE 173, NONE 667 rows):

| Value | Call | Result (§6.7) |
|---|---|---|
| 0 MAT_ENEMY | `t.so_ply_CanMyTarget(m, i)` (vt 0x760 of the **target**) | `t` if the weapon's AtkType fits it |
| 1 MAT_ME | `m.so_mob_CanMyTarget(entry, i)` (vt 0x74c) | `m` itself (heal / buff self) |
| 2 MAT_MYRACE | `m.so_mob_FindMyRaceTarget(entry, i)` (vt 0x748) | a friend of the same race within 500 |
| 4 MAT_NPC | `m.so_mob_CanNPCTarget(entry)` (vt 0x750) | a mob-188 NPC within 500 |
| 3 MAT_NONE, other | log "MobAction::ma_think : MobTarget Wrong" | none |

The NONE rows are the weapons of shop NPCs and gates (651 of 667 have no skill), which never reach a fighting state
because their brain is NoBrain (§6.1). A mob whose current weapon has no target goes back to Targetting, which skips
the weapon (sequence advanced, cooldown set).

### 7.6 `MobAttackSequence`: scripted skill orders

Loader `MobAttackSequence::mas_Load` @ FUN_004a8990 (called once at start-up from the undecompiled block at 0x5b05d8,
step label `mobattseq`, before `chargedbuffdatabox`) into `mobattseq` **DAT_0d76e9e8** `{u32 count; record[400]}`
(records built by `_eh_vector_constructor_iterator_` with `MobAttackSequence::AttackElement4Mob::AttackElement4Mob` FUN_0043be70, sorted by mob ID with `qsort` after each append,
looked up with `bsearch` `MobAttackSequence::mas_Find` FUN_0043f6e0 at spawn → mob+0x1fac; sequence position mob+0x1fb0 = 0):

```pseudo
for every MobInfo row (in table order):
    file = "../9Data/Shine/MobAttackSequence/<MobInfo.InxName>.txt"; skip if it does not open
    parse (ShineDataFile); on error log "MobAttackSequence::mas_Load : Option read error" and stop the server
    if count > 399: "…mas_Append : Too many element" (fatal); record = { mobId, length 0 }; count += 1; qsort
    table AttSeq (columns Order WORD, Attack STRING[33]): for i = 0, 1, 2 …: the Attack value of the row whose Order == i
      (OptionReader::or_Select FUN_006483d0(file, "Attack", …, "Order", i), key lookup *(inferred)* from the arguments), until none is found:
        "-"            → 0xFFFF (normal attack)
        "*RepeatStart" → repeatStart (+0x1be8) = row index + 1, and the row itself is stored as 0xFFFF
                         (original bug) Z09-B6: the marker row becomes an extra normal-attack step; other "*…" → "Invalid Command" (also stored as 0xFFFF)
        skill InxName  → skill ID (unknown: "…mas_Load : Null skill", fatal)
        record.seq[length++] = value         (u16 array at +4; length u8 at +2; longest 2016 file: 75 rows)
    table SkillChange (Condition, Value, From, To); each row goes to a list created on first use (heap SkillChangeList,
    100 entries; "…ExchangeSkill too many" fatal when full):
        OutOfRange  → +0x1244 { from skill, to skill, atoi(Value) (unused) }
        HPLow       → +0x1248 { from, to, Value = HP per mille }
        TargetState → +0x124c { from, to, abstate index of Value ("-" → 0xFFFF; unknown → "Invalid ABState", fatal) }
        NextSkill   → +0x1250 { from, to }
        HPLow_ChangeOrder → +0x1be4 { 0xFFFF, to skill, Value = HP per mille, From = atoi = sequence position }
        other       → "…mas_Load : Invalid condition" (fatal)
    skill names in From / To: "-" = 0xFFFF (normal attack), unknown → "MobAttackSequence::SkillChange::sc_Store : Null skill" (fatal)
```

The record also embeds five `SkillChangeList` objects (+0x3ec, +0x8b4, +0xd7c, +0x1254, +0x171c, constructed by
FUN_0043be70) that the code never uses; the five pointers above are separate heap lists. 2016 data: 297 files, 289 match
a MobInfo name; SkillChange rows: 367 HPLow_ChangeOrder, 28 OutOfRange, 3 HPLow, 2 NextSkill (only `Karen.txt`).

```pseudo
MobAttackSequence::AttackElement4Mob::ae4m_NextSkill(rec, m, pos, advance)     @ FUN_004a9730
    if m is not a ShineMob: return −1
    if advance and m.chainedSkill (+0x1fb4) != 0xFFFF:      # set by a NextSkill row (below)
        k = chainedSkill; chainedSkill = 0xFFFF
        i = first weapon ≥ 1 whose skill == k
        if found: m.+0x1fb6 = 1 (vt 0xaf4: do not advance the sequence after this use); return i
        log "MobAttackSequence::AttackElement4Mob::ae4m_NextSkill : skill not found"; return 0
    s = rec.seq[*pos];  result = 0                           # 0 = normal attack
    if s != 0xFFFF:
        i = first weapon ≥ 1 whose skill == s
        if found and the skill exists, m.SP >= its SP and rand(1000) <= rate(m, i): result = i
    if advance:
        look up rec.NextSkill (+0x1250) for an entry whose from == skill of weapon result
            # (original bug) Z09-B7: +0x1250 is read without a null check; only Karen.txt has NextSkill rows
            #   (disassembly 0x4a999b: `mov eax,[rec+0x1250]; movzx ecx,[eax+0xe]`). For the other 288 sequence mobs the
            #   list is never created, so every advancing select would fault; no writer of +0x1250 other than the loader and
            #   no zone-wide exception trap were found: a fault ends the zone with a minidump (§30.1); open why 2016 servers survived
        if found and to != 0xFFFF and some weapon ≥ 1 has skill to: m.chainedSkill = to
    return result

advance (FUN_004b8c60 → MobAttackSequence::AttackElement4Mob::ae4m_NextSkill FUN_004a8500):  *pos += 1; if *pos >= length: *pos = repeatStart
```

So a sequence mob walks its list one step per attack (a failed rate roll uses the normal attack for that step), loops
from `repeatStart`, and the conditions below may replace the chosen weapon. All three `sm_SkillExchange_*` share one shape:
find, among the condition's entries whose **from** equals the skill of the current weapon (0xFFFF for weapon 0), the
first one that matches; then `to == 0xFFFF` → weapon 0, else the first weapon ≥ 1 whose skill is `to` (none: log
"…Changed skill not found"); return true when the weapon was replaced.

| Function | List | Match | Called by |
|---|---|---|---|
| `ShineMob::sm_SkillExchange_OutOfRange` @ FUN_004baef0 | +0x1244 | the first entry with that `from` (no condition) | `so_mob_SelectWeapon` (out of reach × factor), Attack (out of reach): a successful exchange attacks at once instead of chasing |
| `ShineMob::sm_SkillExchange_HPLow` @ FUN_004bb100 | +0x1248 | `HP < MaxHP × Value / 1000` | Attack, every attempt |
| `ShineMob::sm_SkillExchange_TargetState` @ FUN_004bb390 | +0x124c | the target has abstate `Value` (vt 0x3e4) | Attack, only when the target is out of reach |
| `ShineMob::sm_SkillExchange_HPLow_ChangeOrder` @ FUN_004bb600 *(pdb2016; part 4a had guessed this name)* | +0x1be4 | entry position == sequence position (+0x1fb0) and `HP < MaxHP × Value / 1000` | Attack, after HPLow |

`HPLow_ChangeOrder` (367 of 400 rows) lets a boss play a different skill at given sequence positions once its HP drops
below a threshold (e.g. `EglackMad`: below 40 % / 70 %). Unlike the others it ignores `from`.

### 7.7 Captivated players

When a player becomes captivated (StaKarenCaptivate 335 / StaWarLBrainWash 562, Z03 §6.6), `ShinePlayer` vt 0xf1c
FUN_00564e50 (wraps `smo_SetCaptivate`) builds a 0x324-byte brain: `+4 → player`, `+8` brain objects
(`MobActionArgument::Selector::Selector` FUN_0054ee00), `+0x270` = the player's `MobTargetPlayerCaptivate` selector (+0x2a9d0,
§6.9) initialised with them, `+0x274` the tactic set bound to the cell `player+0x2aa28`, state = Targetting; the pointer is
kept at `player+0x2a9cc`. Captivate off destroys it and clears the pointer (Ghidra cuts the decompile at the
`operator delete`, `operator_delete` FUN_0065677f is wrongly marked no-return; the disassembly at 0x564f74 clears +0x2a9cc).
`ShineMobileObject::so_Routine` (§5.5) calls vt 0xf24 `ShinePlayer::smo_CaptivateStateTask` FUN_005601e0 for a captivated object: one tactic step.

The tactic code branches on "not a ShineMob": Targetting attacks the selector's choice (a player only, §6.9), Chase runs
(after `smo_BashStop`), and Attack ends in

```pseudo
captivated attack(this, ctx)                                                    @ FUN_004ba0d0
    p = ctx.self (ShinePlayer);  t = *cell
    if dist²(p, t) > reach²: Chase.cell = t; return Chase
    if t != p:
        p.so_ply_TargetChange(t)                    # vt 0x998
        ShineMobileObject::smo_SetMode FUN_005497e0(p, 2)
        if player state (+0x2a790) not in {2, 3}: run the client handler 0x242B NC_BAT_BASHSTART_CMD for p (Z03 §2)
    return Targetting
```

so the victim auto-attacks other players with normal attacks through the ordinary player attack path.

### 7.8 `so_attack` and `so_Bash` are dead code in 2016

`ShineMob::so_attack` FUN_0042ce00 (vt 0x580 of ShineMob / NPC / Bandit / Pet / Servant) → `ShineMobileObject::so_attack`
FUN_0042cab0 (damage from the rule set at 0x858ecc through `EngNormAtt::ena_attack` FUN_004fc4a0) → vt 0x584 FUN_0042cb80, which logs
"ShineObjectClass::ShineMobileObject::so_attack called", applies the damage and broadcasts **0x2404 / 0x2405
NC_BAT_SOMEONEDAMAGED_SMALL / LARGE_CMD** `{u16 attacker, u16 target, u8|u16 damage, u8 action}` (or 0x2406 / 0x2407
`NC_BAT_SOMEONEDEAD_SMALL / LARGE_CMD`, same layout, when the hit kills; small when damage < 256) *(names pdb2016)*. No
code calls vt 0x580 or 0x584 (no `+ 0x580` / `+ 0x584` call in the export except `ShineMobileObject::so_attack` FUN_0042cab0 itself, and no direct
call of `ShineMob::so_attack` FUN_0042ce00). Likewise `so_Bash` (vt 0x598: `ShineMobileObject::so_Bash` FUN_0042e950, `ShinePlayer::so_Bash`
FUN_0042efb0, packets 0x242C–0x2431, Z03 §3.5) has no caller at all. The live mob attack is §7.3 (`SWING_START` +
`smo_SwingDamage`) and `smo_SkillBash_Casting`. This corrects Z03 §3.5 ("reached from `so_attack` … and the `&`
commands") and narrows Z03 §7.1 (0x2406 / 0x2407 exist only in this dead path).

### 7.9 Continued in §8

The script-driven skills and weapon rates, mob chat, servant explosions, boss-field hooks, the cross-counter and the
hit / heal rules of the non-player classes are §8.

---

## 8. Mob AI 2b: script control, chat, servant explosions, boss hooks, hit rules

Part 4b. Helpers as in §7.1. `RandomRing(n)` *(ours: inlined, no function)*: the next value of a pre-filled ring of random numbers below `n`
(`rndbox.rb_box[n]` = `DAT_14d720d0 + n × 0x8008` *(pdb2016)*: 0x4000 u16 values `rs_slot`, `rs_point` {value, mask}, index at +0x8000, mask at +0x8004); only for `1 ≤ n ≤ 100`, else 0.
A mob's weapon vector (`MobDataBox` entry +8, §5.1) holds 0xC-byte slots `{→ MobWeapon row, u16 skill ID (+4), u8 present (+8)}`;
"the weapon of skill `k`" below means the first slot whose skill ID is `k`.

### 8.1 Skills ordered by scripts

Three virtuals let Lua scripts make a mob use a skill. The base versions (`ShineObject::…`, all non-mob classes including
players: `so_mob_SkillRegistAtScript` FUN_005d27f0, `so_mob_SkillBlastAtScript` FUN_005d2c80,
`so_mob_SkillParameterSetAtScript` FUN_005d2fc0, `so_mob_SkillParameterSet` FUN_005d2e40) return false; the mob versions belong to `ShineMob` and are inherited by NPC, bandit, pet and servant.

```pseudo
ShineMob::so_mob_SkillRegistAtScript(m, target, skillId)     (vt 0xb7c)        @ FUN_005d2840
    if m.param.flags (+0xfc0+0xcce) & 4: return false            # "cannot attack" abstate bit (Z03)
    if m is casting (vt 0xea0, cast block +0x1d84 ≠ 0): return false
    smo_CastAbort(m)                                              # vt 0xed4 FUN_00579d50: no-op here (it acts only while casting)
    Attack = m+0x227c;  maa_SkillFromScriptClear(Attack)         # FUN_004b9470: skill 0xFFFF, weapon −1, target 0
    *Attack.cell = target                                        # MobActionNeededTarget::mant_SetTarget FUN_004b89a0 (returns Attack)
    i = weapon index of skillId;  if none: return false
    return Attack.vt[0x18](target, skillId, i)                   # mab_SkillRegistAtScript FUN_004b9400:
                                                                 #   +0x14 = target, +0xc = skillId, +0x10 = i; true
    # the tactic state is NOT changed: the order waits for the next MobActionAttack::mab_Think (§7.3)
```

`MobActionAttack::mab_Think` (§7.3) then calls **`so_mob_SetWeaponAsScript`** (vt 0xb74) instead of `so_mob_SelectWeapon`
while `+0xc ≠ 0xFFFF`, and uses `+0x14` as the weapon target (clearing the order) once a weapon is chosen:

```pseudo
ShineMob::so_mob_SetWeaponAsScript(m, i8)                    (vt 0xb74)        @ FUN_004ab5e0
    i = i8 & 0xFF                                     # (the 0xFFFFFFFF "none" test after the mask can never hit)
    sk = SkillDataBox::operator[](skill ID of weapon slot i)
    if sk and m.SP (vt 0x4ec) >= sk.SP (+0xa0): weapon (+0x1fa8) = i; return i
    weapon = −1; return −1
ShinePlayer / other classes: FUN_004d8e20 (folded body; PDB symbol std::basic_streambuf<char,std::char_traits<char>_>::overflow) returns −1
```

(original bug) **Z09-B11**: when the mob lacks the SP for the ordered skill, `SetWeaponAsScript` gives −1 and
`mab_Think` returns `this` before the order is consumed (§7.3: "if i < 0: return this"); the order is only cleared when a
weapon was chosen. Each tick the mob re-enters the same branch, so it neither attacks nor uses another weapon until its
SP reaches the skill's cost, as long as it keeps its target in the Attack state. Weapon slot 0 (the normal attack, no
skill row) can never be ordered this way for the same reason.

```pseudo
ShineMob::so_mob_SkillBlastAtScript(m, target, skillId)      (vt 0xb84)        @ FUN_005d2cd0
    if m.param.flags & 4: return false
    if target == null or no weapon of skillId: return false
    m.weapon (+0x1fa8) = i
    sm_UseWeapon(m, target)                            # §7.4: cast starts at once (no range, cooldown or casting check;
                                                       #   cooldown vt 0x718 is not armed)
    m.tactic (+0x22e4) = WaitSkillEnd.set(swing time (vt 0x71c), next = Targetting, target)   # mawse_SetNextAction FUN_004b92c0
    return true                                        # even when sm_UseWeapon refused for lack of SP

ShineMob::so_mob_SkillParameterSetAtScript(m, p)             (vt 0xb94)        @ FUN_005d3010
    ShineMob::sm_PrepareWeapon FUN_004a9d50(m, …): stat matrix +0x10a0 MinWC = p[0], +0x10a4 MaxWC = p[1], +0x10ac TH = (u16) p[2],
                        +0x10b4 MinMA = p[3], +0x10b8 MaxMA = p[4], +0x10c0 MH = (u16) p[5];  return true
ShineMob::so_mob_SkillParameterSet(m, skillId)               (vt 0xb90)        @ FUN_005d2e90
    the same six values from the MobWeapon row of skillId (MinWC +0x53, MaxWC +0x57, TH +0x5b, MinMA +0x5d, MaxMA +0x61,
    MH +0x65); false when the mob has no such weapon
```

Callers (all Lua C functions, documented in part 10): `cNPCSkillUse(caster, target, skillName)` FUN_005ef5c0 → vt 0xb7c;
`cSkillBlast(caster, target, skillName, range)` FUN_005f0960 → vt 0xb84 after `dist² ≤ range²` (range 0 → 1000);
`cSkillDamageCalculate(caster, skillName, target, params)` FUN_005f1370 → vt 0xb94 when `params` is a table, else vt 0xb90,
then returns the skill's computed damage. Skill names resolve through `BTree::operator[] FUN_0063cc80(&skillnametree DAT_13286d08, name)`.

### 8.2 Weapon rates set by scripts

`sm_GetUseWeaponRate(m, i)` (§7.4, FUN_004aa060) prefers the vector **+0x24c8 / +0x24cc** (`vector<u16>`, per mille) over
`MobWeapon.BlastRate`; it is only read by `so_mob_SelectWeapon` for mobs without a `MobAttackSequence`. The vector is
replaced as a whole and lives until the mob object is reused (the respawn in §5.3 does not reset it *(inferred: no write
to +0x24c8 found outside `std::vector<u16>::operator=` FUN_0050dfa0)*).

```pseudo
ShineMob::sm_scene_SetWeaponRate(m, rates)                                     @ FUN_0050e0c0
    m.weaponRates (+0x24c8) = rates                    # std::vector<u16> assignment FUN_0050dfa0

PineEventScriptNode::ShineMobWeaponRate::sa_Step(node, ctx)                    @ FUN_004fa8c0
    # map-script command:  mobweaponrate <mob> <rate0> <rate1> … (up to 8)      e.g. Kingkong.ps "mobweaponrate Kingkong 1000 200 100 0."
    o = os_ShineObject(node, ctx);  require o to be a ShineMob (class-chain test)
    rates = []
    for k in 0..7: operand node+0x30+4k; stop when absent, when it fails to evaluate, or when its value is 0
        rates.append(value)
    sm_scene_SetWeaponRate(o, rates)

cMobWeaponRate(handle, r0, r1, …)                    (Lua)                     @ FUN_005f3e30
    o = GetObject(handle) as ShineMob; if none: return
    rates = []
    for a = 1 .. 9: if arg a is not a number or (u16) arg a == 0: break; rates.append((u16) arg a)
    sm_scene_SetWeaponRate(o, rates)
```

(original bug) **Z09-B8**: `cMobWeaponRate` starts its loop at Lua argument **1**, which is the handle, so the stored
vector is `[handle, r0, r1, …]`: every rate moves up one weapon. The 2016 scripts call it as
`cMobWeaponRate(Handle, 1000, 200, 100, 0)` (`LuaScript/KQ/MiniDragon`, `HMiniDragon`, `Kingkong`, the same numbers as the
PineScript `mobweaponrate` lines); the result is weapon 0 = handle (≥ 1000, so always), **weapon 1 = 1000 (always)**,
weapon 2 = 200, weapon 3 = 100. Because `so_mob_SelectWeapon` tries the last weapon first, the boss now uses skill 1 every
time it is off cooldown, and its normal attack only in between.

(original bug) **Z09-B12**: both setters treat a rate of 0 as the end of the list (Pine: `value == 0 → break`; Lua:
`(u16) arg == 0 → break`). The weapons after it fall back to their `MobWeapon.BlastRate` instead of being switched off:
`mobweaponrate Kingkong 1000 200 100 0` leaves the fourth weapon (KQ_MiniDragon `KQ_MD_AtkSkil1_3`, BlastRate 200) at 20 %.

### 8.3 Cross-counter (`so_smo_CrossCounterDamage`, vt 0x9ac)

Called by `smo_SkillBash_Blast_Obj` (Z03 §5) when the attacker's skill is a counter skill: `dmg = t.so_smo_CrossCounterDamage(attacker)`;
−1 = nothing to counter (the skill misses), otherwise the attacker deals `2 × dmg` as fixed damage.

```pseudo
ShineMobileObject::so_smo_CrossCounterDamage(t, a)                             @ FUN_004a5360   (base; doors, movers)
    if t.flags1e78 & 0x10 (skill blast armed, second phase pending) and t.cast.skill (+0x1d98) has an effect object (+0x70):
        ctx = damage context (t, a, skill, empower +0x1dac, t.position)          # EngageArgument::EngageArgument FUN_0042abf0
        if effect.vt[0x20](ctx):                       # the effect applies to a
            dmg = effect.vt[0x1c](ctx)                 # damage t's skill would have dealt to a
            t.flags1e78 &= ~0x10;  t.cast (+0x1d84) = 0     # t's skill is cancelled
            return dmg
    return −1

ShinePlayer::so_smo_CrossCounterDamage(p, a)                                   @ FUN_004a54b0
    if (d = base(p, a)) >= 0: return d
    if p's attack schedule (+0x173d0) is running and its current target handle == a.handle (vt 0x344):  # NormalAttackDamageDelay::NormalAttackDamageTick::nadt_IsEmpty FUN_00576000 / NormalAttackDamageDelay::NormalAttackDamageTick::nadt_TargetCompare FUN_005776d0
        p.vt[0x588](); a.vt[0x588]()                   # both "in battle" (§6.5)
        dmg = p.rules (+0x1e74).vt[0x1c](ctx);  hit = rules.vt[0x18](ctx)     # normal-attack damage and hit rate
        if rand(1000) <= hit: advance the schedule past this swing (NormalAttackDamageDelay::NormalAttackDamageTick::nadt_PopFront FUN_00577780); return max(dmg, 1)
    return −1

ShineMob::so_smo_CrossCounterDamage(m, a)          (pet, NPC, bandit, servant too)  @ FUN_004a56a0
    if (d = base(m, a)) >= 0: return d
    if m.flags24ac & 4 (between swing start and hit of a normal attack, §7.3):
        m.vt[0x588](); a.vt[0x588]()
        dmg = m.rules.vt[0x1c](ctx);  m.flags24ac &= ~4
        m.tactic = Targetting
        m.vt[0xed8]()                                  # ShineMob::smo_BashStop FUN_0042adf0: 0x243D NC_BAT_CEASE_FIRE_CMD { u16 handle } to sight
        return max(dmg, 1)
    return −1
```

A mob's swing is countered unconditionally (no hit roll, unlike the player branch); the pending `MobActionSwingDamage`
is abandoned because the state is reset to Targetting.

### 8.4 Who may hit or heal whom (non-player classes)

`so_mobile_ICanDamageTo(a, d)` (vt 0x980) and `smo_ICanHealTo(a, d)` (vt 0xe94). The base test and the player versions are
Z03 §3.3 / §5; these are the other classes:

```pseudo
ShineMob::so_mobile_ICanDamageTo(m, d)         (mob, NPC, bandit)              @ FUN_00435140
    if not base(m, d) (FUN_00434f30): return false
    d = d.vt[0x9b0]() or d                         # a pet or servant counts as its master
    if d is a pet (kind 12): return false
    if d is a player (2) or mover (11):
        if d.vt[0xc70]() == 1: return false        # GM-invincible
        if the field has a guild tournament (fm_GetGuildTournamentSystem) and d.guild (vt 0x828) == m.guild: return false
    return m.vt[0xe60](d) != 1                     # not on the same side (§6)

ShinePet::so_mobile_ICanDamageTo                                               @ FUN_004350f0   → false (pets never hit)
ShinePet::smo_ICanHealTo                                                       @ FUN_00435770   → false

ShineServant::so_mobile_ICanDamageTo(s, d, why)                                @ FUN_00436790
    if s.+0x2594 bit 0 (vt 0xdec ShineServant::so_serv_GetMobCanDamageTo FUN_0054af90: "independent" servant): return ShineMob rule (above)
    return s.master (+0x256c) ? master.vt[0x980](d, why) : false              # otherwise the master's (player) rules
ShineServant::smo_ICanHealTo(s, d)                                             @ FUN_004356b0
    return s.master ? master.vt[0xe94](d) : false
ShineServant same side (vt 0xe60)  FUN_0054b100: master ? master.vt[0xe60](d) : ShineMob::so_IsAlliance(s, d)

ShineMobileObject::smo_ICanHealTo(a, d)        (base: doors, movers)           @ FUN_004352d0
    return not a.vt[0x980](d, "smo_ICanHealTo")    # whatever a may not attack, a may heal
ShineMob::smo_ICanHealTo(m, d)                 (mob, NPC, bandit)              @ FUN_004357c0
    return base(m, d) and m.vt[0xe60](d) == 1      # not attackable and on the same side

ShineMover::so_mobile_ICanDamageTo(v, d)                                       @ FUN_004368c0
    the ShinePlayer rule set (Z03 §3.3) with the mover as attacker, in this order:
    base; d = owner or d;
    d player / mover: GM-invincible → false; StaImmortal (291) or StaAdlFLoussierIMT (499) on either side → false;
        d or v captivated (vt 0xf20) → true;
        **if the field has no kingdom-quest object (field+0x10 == 0): false**;
        KQ type 4: party / raid / guild / guild-war rules as for players;
        freePK (+0x54) → true; same party → false; IsPartyBattle (row +0x69) → true; same raid → false;
        different guilds: tournament enemy → true, EnemyGuild (row +0x63) and guild war → true;
        vt 0xe0c(d) (KQ team enemy) → true; else false
    d mob / bandit / NPC: not same side (vt 0xe60, ShineMover::so_IsAlliance FUN_0054b130 = the rider's answer through vt 0xcb0),
        not the mover's guild, and d has a mob row (vt 0x70c) → true
```

**Correction (part 8b):** the test written above as "field has no kingdom-quest object (field+0x10 == 0)" reads
`fm_MapInfo` (FieldMap +0x10, the map's MapInfo row) *(pdb2016)*: only a field without a MapInfo row (none in practice)
refuses; `MapInfo.KingdomMap` (+0x3a) == 4 selects the KQ branch. So the mover follows the player rule set (Z03 §3.3)
step for step, and movers may hit players on PK fields, party-battle maps and in guild wars like their riders do.
In the KQ branch the raid test compares the mover's own raid number with itself (`this->vt 0xa84` twice), so any mover
whose rider is in a raid counts every target that is also in a raid as "same raid" (original bug) Z09-B31; the player
version FUN_004361a0 has the same self-compare in its KQ branch (Z03 did not record it).

### 8.5 `smo_SkillBlastTick` (vt 0xf14): delay between a skill's blast and its damage

Used by `SkillBlastEffectContainer::sbec_Store` FUN_00438380 (Z03 §5: the effect is queued at `g_Now + tick`).

| Class | Function | Value (tenths) |
|---|---|---|
| base (door, mover) | `ShineMobileObject::smo_SkillBlastTick` FUN_004358e0 | 0 |
| player | `ShinePlayer::smo_SkillBlastTick` FUN_00435930 | `skill.server.HitTime (+0x4b) × 10 / 1000`; 100000 without a skill |
| mob, NPC, bandit, pet, servant | `ShineMob::smo_SkillBlastTick` FUN_004359b0 | the **current weapon's `MobWeapon.HitTime` (+0x4d)** × 10 / 1000 when the weapon index is valid, else as the player (99999 without a skill) |

This corrects Z03 §5 ("mobs 0"): only doors and movers use 0.

### 8.6 Mob chat (`MobChat::MobChatManager` `mobchatman`, DAT_0084cc84)

Data: `World/<world>/MobChat.txt`, falling back to `World/MobChat.txt` (2016: only the fallback exists), loaded by
**`MobChatManager::mcm_Load`** FUN_004af640, called once at start-up right after `mdb_Load` (call at 0x5add9b, argument =
the world folder name DAT_14d460bc). If neither file reads: log "MobChat::MobChatManager::mcm_Load : Error in Script read"
(the server continues with empty tables).

Seven tables, identical columns `MobIndex (mob InxName), Rate0 u32, Rate1 u32, Script0…Script3 char[65]` (row struct
`MobChat::MobChatRecord` 0x120 `{ORToken mobindex, rate0, rate1, script0…script3}`; manager `{mcm_MaxMobHandle,
mcm_Default, mcm_Wander, mcm_Attack, mcm_Damage, mcm_Killed, mcm_HelpReq, mcm_HelpAck, mcm_DetectBattle}` *(pdb2016)*):

| Table (code name) | Array (manager +) | Element class, slot | Fired by | 2016 rows |
|---|---|---|---|---|
| `PIECE` | +0x08 `mcm_Wander` (DAT_0084cc8c) | `MobChatElementWander` (0x130 bytes): vt 0 interval, vt 4 `mceb_WanderChat` | idle timer +0x1ea8 in `MobActionWander::mab_Think` FUN_004bb790 (§7.2) | 330 |
| `ATTACK` | +0x0c | `MobChatElement` (0x128), vt 8 `mceb_AttackChat` | normal attack (weapon 0) in `sm_UseWeapon` (§7.4) | 330 |
| `DAMAGED` | +0x10 | vt 0xc `mceb_DamageChat` | every hit, `ShineMob::so_DamagedBy` FUN_00431750 (Z03) | 330 |
| `DEAD` | +0x14 | vt 0x10 `mceb_KilledChat` | `ShineMob::so_KilledBy` FUN_00432760, after the kill bookkeeping | 330 |
| `HELPMAIN` | +0x18 | vt 0x14 `mceb_HelpReqChat` | the mob calling for help, `sm_DuringBattle` FUN_00568d30 (§6.6, once per fight: rescue flag bit 2) | 32 |
| `HELPSUB` | +0x1c | vt 0x18 `mceb_HelpAckChat` | a helper answering, `so_RescueRoutine` FUN_00569050 (§6.6, flag bit 1) | 32 |
| `RACERESCU` | +0x20 | vt 0x1c `mceb_DetectBattleChat` | a helper noticing a fight, `so_RescueRoutine` (§6.6) | **0 loaded** (file: 32 `RACERESCUE` rows) |

```pseudo
MobChatManager::mcm_Load(mgr, world)                                           @ FUN_004af640
    mgr.mcm_MaxMobHandle (+0, the array length) = maxMobId (DAT_14d4509c) + 1
    7 arrays of count pointers, every slot = &mgr.mcm_Default (+4)    # a static MobChatElementBase (vftable 0x6c1f94): every chat is a
                                                       #   no-op, interval MobChat::MobChatElementBase::mceb_MobChatInterval FUN_004ae540 = 1 000 000 000
    for every MobInfo row r (r < DAT_14d45098):
        e = mobdatabox entry of r.ID; if none: log "…mcm_Load : Null inf" (fatal log)
        for each of the 7 table names (char[20], compared as 5 dwords: TableNameCompareArgument TableNameCompareArgument::lid_Call FUN_006470f0):
            rec = record of that table with MobIndex == MobInfo.InxName (OptionReader::or_SelectFrom FUN_00647c00); if none: continue
            if slot already set: log "…mcm_Load : Duplicate entry"          # cannot happen: each mob is visited once
            slot[r.ID] = new element(rec)                                    # MobChat::MobChatElement::MobChatElement FUN_004aeb20 copies the record
            PIECE only: range = Rate1 − Rate0; mult = 1; while range > 99: range /= 2, mult *= 2
                        element mcew_Dice (+0x128) = range, mcew_Roll (+0x12c) = mult
            (a record of an unknown table logs "Invalid Flag": unreachable, the names are fixed)
    element.mce_Number (+0x124) = number of Script columns before the first one that starts with '-' (0…4)

MobChatManager::mcm_<X>Chat(mgr, m)                (Wander MobChat::MobChatManager::mcm_WanderChat FUN_004ae570, Attack MobChat::MobChatManager::mcm_AttackChat FUN_004ae640, Damage MobChat::MobChatManager::mcm_DamageChat FUN_004ae710,
                                                    Killed MobChat::MobChatManager::mcm_KilledChat FUN_004ae7e0, HelpReq MobChat::MobChatManager::mcm_HelpReqChat FUN_004ae8b0, HelpAck MobChat::MobChatManager::mcm_HelpAckChat FUN_004ae980,
                                                    DetectBattle MobChat::MobChatManager::mcm_DetectBattleChat FUN_004aea50)
    id = m.mobId (vt 0x70c row → u16 ID); if id < mgr.mcm_MaxMobHandle: array_X[id].vt[slot_X](m)

MobChatElement::mceb_<event>Chat(e, m)             (ATTACK … RACERESCU; MobChat::MobChatElement::mceb_AttackChat FUN_004aedd0, MobChat::MobChatElement::mceb_DamageChat FUN_004aef00, MobChat::MobChatElement::mceb_KilledChat FUN_004af030,
                                                    MobChat::MobChatElement::mceb_HelpReqChat FUN_004af160, MobChat::MobChatElement::mceb_HelpAckChat FUN_004af290, MobChat::MobChatElement::mceb_DetectBattleChat FUN_004af3c0: identical bodies)
    if e.lines == 0: return
    if rand(1000) <= e.mce_Record.rate0 (+0x18):                  # Rate0 = chance in per mille (data: 10…100); Rate1 unused
        text = e.Script[RandomRing(e.lines)]
        m.so_Chat(0xFFFF, text, strlen(text), chatwin 0, links 0)          # vt 0x530 → 0x2002 below

MobChatElementWander::mceb_WanderChat(e, m)                                    @ FUN_004aecb0
    the same without the Rate0 roll (the timer already decided)
MobChatElementWander::mceb_MobChatInterval(e)      (vt 0)                      @ FUN_004aebb0
    e.lines == 0 ? 10⁹ : Rate0 + RandomRing(range) × mult       # milliseconds; e.g. 1 800 000 … 3 400 000 = 30–57 min
```

The interval is drawn **once per spawn**: `so_mob_RegenComplete` (§5.3) arms the periodic timer +0x1ea8/+0x1eac with
`interval / 100` tenths; it then repeats with the same period while the mob wanders. (This resolves the "behaviour object
`DAT_0084cc8c`" of §5.2 / §6.9: it is the PIECE array.) The destructor `MobChat::MobChatManager::~MobChatManager` FUN_004af4f0 frees every non-default element.

The line goes out as **0x2002 NC_ACT_SOMEONECHAT_CMD** (`ShineMobileObject::so_Chat` FUN_00458c90, layout in Z02 §3.1)
to everyone in sight of the mob: `handle` = the mob, `flag` GMColor = vt 0xef4 (0 for mobs), font / balloon colour from
vt 0xe2c / 0xe34. The client shows it like a player's chat line over the mob *(inferred: same handler as player chat)*.

(original bug) **Z09-B9**: the loader looks up the table name `"RACERESCU"` (9 letters), but `MobChat.txt` declares
`#Table RACERESCUE`; the file parser stores table names with `strncpy(…, 20)` (`OptionReader::or_ExecTable` FUN_00646100) and the lookup compares all
20 bytes, so the table is never found and the 32 `RACERESCUE` rows are ignored: `mcm_DetectBattleChat` always hits the
default no-op element.

### 8.7 Mob shout and scripted mob chat

```pseudo
ShineMob::so_Shout(m, target, speaker, content, len) (vt 0x534; mob, NPC, bandit, pet, servant)   @ FUN_00459250
    0x201F NC_ACT_SOMEONESHOUT_CMD {
        u8 itemLinkDataCount = 0,
        speaker (20 bytes): speaker != "" ? speaker[20] : u16 mobID (vt 0x708) in the first two bytes,
        u8 flag: isMob (bit 1) = (speaker == ""), GMColor (bit 0) = vt 0xef4 (0); other bits = stale buffer bits,
        u8 len, u8 content[len] }
    size sent = len + 0x1A                       # (original bug) Z09-B10: one byte more than the packet (the player
                                                 #   version ShineMobileObject::so_Shout FUN_00459080 sends len + 0x19); the extra byte is stale buffer
    target == 0xFFFF ? so_AllInMap1(m, …)        # the whole map instance
                     : send only to GetObject(target)   ("…ShineMob::so_Shout : Packet Too Long" when the length is refused)
ShineObject::so_Shout                                                            @ FUN_00459030   (non-mobile objects: no-op)
```

The client reads `speaker` as a u16 mob ID when `isMob` is set (client handler reads offset 1 as u16, C01 table
`re-data/client-handlers.json` 0x201f) and shows the mob's name. Callers: the Lua `cMobShout` FUN_005dbcd0 (part 12) and the
map-script node `ShineNPCShout` `PineEventScriptNode::ShineNPCShout::sa_Step` FUN_004eecd0 (§25.3).

```pseudo
cMobChat(handle, scriptName, key, chatwin)           (Lua)                       @ FUN_005e2560
    o = GetObject(handle); set = script-string set scriptName (KQScriptManager::operator[] FUN_0064ce70(&kqscriptmanager DAT_150e04e8, name): "Invalid script name")
    text = set.ScrString(key) (ShineScript::ss_String FUN_0048ce60; "" when missing)
    o.so_Chat(0xFFFF, text, strlen(text), chatwin & 0xFF, 0)        # vt 0x530 → 0x2002 to sight
    return 0 values
```

### 8.8 Servant explosions (`MobExplosionElement`)

Only `ShineServant` (object kind 10, summoned by a player's skill) uses these; the servant object itself is part 8.
State at servant **+0x2574** = one of five singletons (`mobexplosebase` 0x84c9c0, `mobexploseenemy` …c4, `mobexplosetarget` …c8, `mobexplosealways`
…cc, `mobexplosetargetall` …d0; one slot each, `meb_Routine(servant, row) → next state`). Servant members *(pdb2016, `ShineServant` 0x2598)*:
+0x2568 `ss_MiscTable` → servant row, +0x256c `ss_Master`, +0x2570 `ss_TargetOfSummon` follow target (vt 0xf78 `ShineServant::so_serv_TargetOfSummonMob` FUN_00557110), +0x2574 `ss_ExplosionManager` (the state), +0x257c `ss_NextExplosion`, +0x2580 i16 `ss_RestExplosion` (explosions left),
+0x1fbc death time; also `ss_AIType` +0x2578, `ss_RoamingType` +0x2584 … `ss_RoamingCenterLoc` +0x258c, `ss_Flag` +0x2594
(part 8b). The row is a **`MiscDataTable::MiscData_Skill`** (0x80 bytes, `World/MiscDataTable.txt`, Z01 §2) *(pdb2016)*:
+0x54 `mds_LifeTime_MilliSec` (0 = unlimited), +0x5c `mds_ExploseTriggerObject` (explosion kind: `ETO_NONE 0, ETO_ENEMY 1,
ETO_TARGET 2, ETO_ALWAYS 3, ETO_CASTERTARGET 4, ETO_TARGETALL 5`), +0x60 `mds_ExploseTriggerRange` (trigger radius),
+0x64 `ExploseEffectSkill` (u16 skill ID, 0xFFFF none), +0x68 `ExploseEffectSkillTo` (blast mode: `EEST_NONE 0, EEST_MYLOC
1, EEST_MYOBJ 2, EEST_TARGETLOC 3, EEST_TARGETOBJ 4`), +0x6c u16 `mds_ExplosionNumber`, +0x70 `mds_ExplosionDelay` (ms).
So ETO_CASTERTARGET (4) runs the same `MobExplosionEnemy` state as ETO_ENEMY.

```pseudo
ShineServant::so_mob_RegenComplete(s, arg)                                      @ FUN_00442c50
    ShineMob::so_mob_RegenComplete(s, arg)   (§5.3);  master = follow = 0
    s.deathTime (+0x1fbc) = row.lifetime ? g_Now + lifetime/100 : 0
    state by row.kind: 1, 4 → Enemy;  2 → Target;  3 → ss_ExplosionReady(s);  5 → TargetAll;  else → Base

ShineServant::ss_ExplosionReady(s)                                              @ FUN_0057b5d0
    s.nextBlast = g_Now + row.interval/100;  s.left = row.count;  return Always

ShineServant::so_Routine(s, …)                                                  @ FUN_0056c070
    if s not dead:
        if no master (vt 0x9b0 ShineServant::so_serv_FindMaster FUN_00557090: +0x256c not removed, mode 1/2/4, same field): s.vt[0x33c](0,1,3); FreeObject(s, 9); return
        if deathTime and deathTime < g_Now: mode = 3; s.vt[0x33c](0,1,3); FreeObject(s, 10); return
    ShineMob::so_Routine(s, …)                       (§5.4: tactics, AI)
    if alive (mode ∉ {0, 3}): s.state = s.state.meb_Routine(s, row)

Base::meb_Routine                                    FUN_0057b660   → Base (never explodes)
Enemy::meb_Routine(s, row)                           FUN_0057b6b0
    if no master: meb_Vanish(s, 0); → Base
    scan row.radius around s with AxialListNearScanSkillEnemy (alnse DAT_13286090; s as caster)
    any enemy found → ss_ExplosionReady(s) (Always) else stay
Target::meb_Routine                                  FUN_0057b830
    if no master: Vanish(0); → Base
    f = follow target; if f present, not removed (vt 0x300), mode ∉ {0, 3} and not dead (vt 0x28 `IsDead` ShineMobileObject::so_AmIAlreadyDead FUN_005557a0: flag +0x1d7c or HP 0):
        if dist²(s, f) <= radius²: → ss_ExplosionReady(s)    else stay
    else Vanish(0) (stays Target until removed)
TargetAll::meb_Routine                               FUN_0057bb20
    if no master: Vanish(0); → Base
    scan radius with AxialListScanSkillTarget (alnsst DAT_13284318); ready if it found ≥ 2 objects, or one that is not the master
Always::meb_Routine                                  FUN_0057b9d0
    if no master: Vanish(0); → Base
    if s.left <= 0: Vanish(3); → Base
    if s.nextBlast <= g_Now:
        if meb_Explosion(s, row, master): s.left −= 1
        if s.left < 1: Vanish(1); → Base
        s.nextBlast = g_Now + row.interval/100
    stay

MobExplosionBase::meb_Vanish(s, sec)                                            @ FUN_004a4110
    s.vt[0xf7c](sec)       # ShineServant ShineServant::sm_serv_VanishReserv FUN_004a3490: state = Base, deathTime = g_Now + sec × 10,
                           #   vt 0x24, AxialListMobSuicide::alms_SelfKill(s) (part 8)

MobExplosionBase::meb_Explosion(s, row, master) → bool                          @ FUN_004a7960
    sds_Initialize(damage sender skilldamagesender DAT_0087efc4)                        (Z03 §5)
    if not s or not master or row.skill == 0xFFFF or not (sk = SkillDataBox::operator[](row.skill)): return false
    stat matrix ← the servant's MobWeapon row of that skill (as so_mob_SkillParameterSet, §8.1)
    row.blastMode: 1 smo_SkillBash_Blast_Trap_Loc(s, s.pos, sk)   (FUN_005835e0)
                   2 smo_SkillBash_Blast_Trap_Obj(s, s, sk)       (FUN_005838a0)
                   3 Trap_Loc at the follow target's position;  4 Trap_Obj on the follow target;  else nothing
    if s has StaEntrapHide (abstate 77): reset it (vt 0x650), clear its brief bit, broadcast the reset   # the trap shows itself
    sds_Finish({time g_Now, skill sk, credited attacker = master, position s.pos, …})   # sends the damage results (Z03)
    return true
ShineServant::so_serv_LastExplosionReady(s)                                     @ FUN_00552f80
    if row and not s.IsDead (vt 0x28): nextBlast = g_Now; left = 1; if row.kind ≠ 0: state = Always   # one last blast at once
```

### 8.9 Boss-field hooks on mobs

**Abstate level at death** (`smo_BossAbstateSet`, vt 0xf64; called by `ShineMobileObject::so_KilledBy` FUN_00432240 before
the abstates are cleared):

```pseudo
ShineMob::smo_BossAbstateSet(m)                                                 @ FUN_005d3ab0
    m.bossAbstate (+0x24fc) = 0
    c = ListOfMobStateCheckAtDead[m.mobId]   (BossFieldContent::g_ListOfMobStateCheckAtDead DAT_14d6fcb8, BossFieldContent::ListOfMobStateCheckAtDead::operator[] FUN_005d2580; 0x14-byte entries {DropType, vector<abstate index>, …};
                                              loaded from MobAbStateDropSetting.shn by lomscad_Load FUN_005d5970, §27.6)
    if c: m.bossAbstate = macad_AbstateCheck(c, m.abstates (+0x1cc))          # FUN_005d3880
macad_AbstateCheck:
    list empty → 0
    DropType 0: number of m's abstates whose index is in the list               # e.g. WereBear: StaPuryImpactStun, StaBoneArrow, StaDeeper
    DropType 1: the strength (element +0x18) of the first of m's abstates equal to the single listed abstate, else 0
ShineMobileObject::smo_BossAbstateSet                                           @ FUN_005d25e0   (players, doors, movers: no-op)
ShineMob::sm_BossAbstateGet(m) = m.bossAbstate                                  @ FUN_005d2620
```

The only reader is `ItemDropFromMob::DropItemListForSpecies::dilfs_ItemDrop` FUN_0048ef80, which picks drop list
`[bossAbstate]` of the species (part 7). 2016 data: 6 mobs, DropType 0 (MaxCount 2 or 3) and one DropType 1 (MaxCount 10).

**Buff from a "buffer" mob** (`sm_IBuffToBuffee`, called by `ShineMob::so_Routine` §5.4 when the MobDataBox entry flag
+0x28 bit 0 is set; `sbbt_Load` FUN_005d4580 sets it for every ConditionMob):

```pseudo
ShineMob::sm_IBuffToBuffee(m)                                                   @ FUN_005d48c0
    if g_ServentBuffBossTable.sbbt_NextTick >= g_Now: return                      # once per 5 s (§1.4)
    b = ServentBuffBossTable.sbbt_FindBuffer(m.mobId)  # DAT_14d6fca4, FUN_005d47f0: the StateMob.shn row whose
                                                       #   ConditionMobInx is m: {target mob ID, abstate index, abstate, strength}
    if b: so_AllInMap1(m, AxialListMobStateSet{targetMob, abstate, strength, keep 6000 ms})    # FUN_004eb880
AxialListMobStateSet::ali_Work(o)                                            @ FUN_004f0fc0 → almss_AbStateSet FUN_004eb8d0
    if o is a mob (kind 5) and (targetMob == 0xFFFF or o.mobId == targetMob):
        abstate data == null ? reset the abstate on o
                             : o.so_AbnormalState_Set(o, abstate, strength, data, g_Now, 0, 0, 6000 ms, how 9, 0)
                               → brief bit, broadcast set, vt 0x3f0 inform, recalc (vt 0x528)
```

So while a condition mob lives, every target mob in the same map instance carries the abstate (renewed every 5 s for 6 s);
2016 `StateMob.shn` (6 rows): B_CrackerGuardian / B_CrackerLooter → B_CrackerHumar (StaCrackerWCUpRate / ACUpRate 1),
BH_Looter / BH_Guardian → BH_Humar (strength 2), BH_Helga → BH_KaraTemplerAC (StaMobACPlus), BH_HelgaBall →
BH_KaraTemplerMR (StaMobMRPlus).

### 8.10 `MobTargetPlayerCaptivate`: the target selector of a charmed player

Built in the player constructor at p+0x2a9d0 and used by the captivated-player brain (§7.7).

```pseudo
mts_Initialize(sel, owner, arg)                                                 @ FUN_004abde0
    sel.mts_MyBody (+0xc) = owner;  sel.mtb_targetlist (+0x14) = arg;  sel.mts_SightRange (+0x10) = 600
    # result = sel.PlayerTarget (+0x38, a MobTargetStruct; class MobTargetPlayerCaptivate : MobTargetAggresive, 0x58) (pdb2016)
mts_SelectTarget(sel, p)                (vt 0x28)                                @ FUN_004abe10
    sel.found (+0x40 = PlayerTarget.mts_Object) = 0;  if p: ShineObject::so_AllOfRange_Simple(p, sel)        # calls ali_Work per object in sight
ali_Work(sel, p, o)                    (vt 0)                                   @ FUN_004add20
    skip unless mdb_CanIKill(o.mobId (vt 0x708), 1 = by a mob) and o.side (vt 0x8cc) ≠ 0
    if o has StaImmortal (291) or StaAdlFLoussierIMT (499): copy o's name to the debug ring namestring DAT_0085dfb0; skip
    skip if o is dead (mode 3) or not placed (mode 0), has StaHide (75), is not a player, or is captivated itself (vt 0xf20)
    if same layer and o can be seen from p's sub-layer:
        PlayerTarget.mts_Object (+0x40) = o; .mts_Handle (+0x38) = o.handle; .mts_CharRegnum (+0x3c) = o.vt[0x344](); stop the scan
```

The charmed player therefore attacks the first visible, uncharmed, unprotected **player** in scan order (radius 600 is set
but `ShineObject::so_AllOfRange_Simple` FUN_00553c20 calls `so_AllOfRange` with range 0, i.e. the whole sight list, and
`ali_Work` has no distance test, so the radius is not applied *(inferred: range 0 = sight)*).

### 8.11 Open points of this section

- The servant row table behind +0x2568 and `vt 0x33c` / `FreeObject` reasons 9 / 10: settled in §13.3 / §12 (part 8b).
- ~~`ShineMover::so_mobile_ICanDamageTo` refuses all player targets outside KQ maps~~: misread, settled in §8.4 (part 8b).
- The scanner classes `AxialListNearScanSkillEnemy` / `AxialListScanSkillTarget` belong to Z03's skill targeting.

---

## 9. Movement, map blocks, path finding and sight

Every mobile object (player, mob, NPC, servant, pet, mover, bandit) moves the same way: a `MoveManager` at obj+0x18c
interpolates the position from a start point to a destination at a fixed speed, one step per tick, and every step goes
through the block bitmaps and the sight update. Client-driven moves (Z02 §2) and all server-driven moves (tactics §7,
fear, scripts, skills) start it with `MoveStart` (vt 0x660).

### 9.1 `MoveManager` (obj+0x18c)

`MoveManager` is 0x40 bytes *(pdb2016)*; PDB member names below.

| Off (in MoveManager) | obj | PDB member | Meaning |
|---|---|---|---|
| +0x00 | +0x18c | `mm_state` (`MMState`: `MM_HALT 0, MM_WALK 1, MM_RUN 2, MM_REINFORCEMOVE 3`) | move kind: 0 idle, 1 walk, 2 run, 3 server push (`so_ReinforceMove`; kept through `mm_Halt`) |
| +0x04 | +0x190 | `mm_object` | owner object |
| +0x08 | +0x194 | `mm_charSpeed` | speed (units per second; vt 0x7b0 reads it) |
| +0x0c / +0x10 | +0x198 | `mm_startPos` | start point |
| +0x14 / +0x18 | +0x1a0 | `mm_goalPos` | destination (vt 0x60c returns its address; a player on a mover returns the mover's) |
| +0x1c | +0x1a8 | `mm_startTime_ms` | start time (`timeGetTime`, ms) |
| +0x20 | +0x1ac | `mm_fullTime_ms` | duration in ms = distance × 1000 / speed (min 1); **non-zero = moving** (vt 0x610 `ShineMobileObject::so_mobile_IsInMoving` FUN_005555c0) |
| +0x24 / +0x28 | +0x1b0 / +0x1b4 | `mm_currTime_ms` / `mm_lastTime_ms` | last / previous step time (ms) |
| +0x2c | +0x1b8 | `mm_leftTime_ms` | ms of the move already applied (despite the name; `mm_Step` adds to it and moves `start + vector × it / full`) |
| +0x30…+0x3c | +0x1bc | `mm_vector {x, xPositive, y, yPositive}` | \|dx\| / dx > 0, \|dy\| / dy > 0 |

```pseudo
ShineMobileObject::so_mobile_MoveReserve(o, dest, speed, kind, backwards)  (vt 0x660, all classes)        @ FUN_00555970
    o.direction (*o+0x6a, 0..179 in 2° steps) = DirectDistanceTable::ddt_DirectSR(backwards ? pos − dest : dest − pos)   @ FUN_00401330
    mm_MoveStart(o+0x18c, dest, speed, kind)                                 @ FUN_004bdcc0
        if speed ≤ 0: return;  if !dest: log "Where am I to go?"; return
        if dest == o.pos: return                                             # nothing is (re)started
        kind, start = o.pos, start/last/prev step time = now, applied = 0, destination = dest
        mm_RecalcSpeed(speed)                                                @ FUN_004bdbe0
            |dx|, |dy|, signs; duration = ddt_Distance(dx, dy) × 1000 / speed (≥ 1); speed stored
            speed ≤ 0: log "mm_RecalcSpeed : speed zero"
MoveManager::mm_Halt(mm)  (also inlined in many places)                                   @ FUN_0043f780
    if kind ≠ 3: kind = 0; times, duration, applied, speed = 0; destination = o.pos
MoveManager::_mm_ReserveHaltState(mm)                                                                   @ FUN_0043cc60
    times, duration, applied, speed = 0; destination = o.pos                 # kind is left as it was

MoveManager::mm_Step(mm, force)  # called by so_Routine every tick while moving (§5.5), by STOP_REQ (Z02 §2.3) with force=1
                                                                             @ FUN_004be7e0
    if duration == 0: kind = 0; return
    p = o.GetParam (vt 0x430)
    if kind == 3:  stop if p.flags (+0xcce) & 2
    else:          if p.flags & 1 or p.flags & 2: mm_Halt (keeps kind 3); StopHere (vt 0xa48); vt 0xa50; return
                   stop if o.IsInGambleGame (vt 0xb24; players at a gamble seat, Z06)
    stop = mm_Halt; so_mobile_StopHere (vt 0xa48); vt 0xa50 (player: 0x204A REINFORCE_STOP to itself); return
    now = timeGetTime(); elapsed = min(now − start, duration)
    if !force and duration ≥ 100 and (lastStep − now) < 100 (unsigned) and now − start < 100: return
        # (original bug) Z09-B15: the throttle subtracts the wrong way round; as unsigned it is true only when
        # lastStep == now, so steps are practically never skipped (intent: skip when < 100 ms since the last step);
        # R2: the PDB export reads `99 < mm_currTime_ms − now`, confirming the order
    prevStep = lastStep; lastStep = now
    applied = (elapsed − applied < 100) ? elapsed : applied + 100
    loop while applied ≤ elapsed:                       # walks the time in slices of at most 100 ms
        point = (applied == duration) ? destination : start ± |d| × applied / duration (per axis)
        if o.IsInFear (vt 0x9e8, +0x1e78 bit 2) and (no map or mbi_IsAttackBlock(point) or mbi_IsMoveBlock(point)): stop (see above); return
        if !o.smo_BlockCheck(point) (vt 0xf40, §9.2): return
        old = o.pos
        smo_NewObjBriefInfoChange(o, point)             # §9.6: objects that come into sight
        SetPosition(o, point)                           # Z02 §2 (re-sorts the coordinate lists, §9.5; script hook 7)
        smo_OldObjectDelete(o, old)                     # §9.6: objects that leave sight → 0x1C0E
        if applied == elapsed: if elapsed == duration: _mm_ReserveHaltState(mm); return
        applied += min(100, elapsed − applied)
```

Stat flags in `GetParam()+0xcce` (bit 0 and bit 1 stop every move except kind 3, bit 1 stops kind 3 too) are set by
abstates (Z03 §6; §5.5 calls them "cannot move / attack / cast"). Pushes (kind 3) therefore survive a root but not a stun
*(inferred from the bits)*.

**Stops.**

```pseudo
so_mobile_StopHere(o)  (vt 0xa48)                                            @ FUN_0045a0c0
    mm_Halt(o.mm) (keeps kind 3); o.lastMoveCmd (+0x168) = 0                  # newcomers no longer see a move (Z02 §5)
    broadcast to sight 0x2013 NC_ACT_SOMEONESTOP_CMD { u16 handle, u32 pos.x, pos.y }
    # a ShineMover (kind 11) broadcasts around the object vt 0xcb0 returns instead (nothing if none)
ShinePlayer.smo_ply_ReinforceStopHere(p)  (vt 0xa50; other classes no-op FUN_00417480 (folded body; PDB symbol ShineObject::so_Gamble_ChangeCoin))   @ FUN_00456ef0
    p ← 0x204A NC_ACT_REINFORCE_STOP_CMD { u32 loc.x, loc.y = p.pos }        # client: put the main character there
```

### 9.2 Block bitmaps and the per-class block checks

Each map has a `MapBlock::MapBlockInformation` (0xb3c bytes *(pdb2016)*; field+0x14), loaded once per map name by
`MapBlockInformationBox::mbib_Load` (FUN_0049e940; `mbib_array[256]` of 0xb50-byte entries, "Too many block info") →
`mbi_Load` FUN_0049e3b0. Members: `mbi_mapxsize` / `mbi_mapysize` +0/+4, `mbi_blockxsize` / `mbi_blockysize` +8/+0xc
(cells), `mbi_xbyte` +0x10 (bytes per row), and the rows below:

| File (`9Data/Shine/BlockInfo/`) | Read into | Content |
|---|---|---|
| `<map>.shab` (optional, 8 maps in 2016) | +0x18 `mbi_AttackBlockBuffer` | `u32 bytesPerRow, u32 rows`, then rows × bytesPerRow bytes; bit set = blocked. Read first; missing file is not an error |
| `<map>.shbd` (required: "Map block information not found" stops the server) | +0x14 `mbi_MoveBlockBuffer` | same format; **after loading, every byte of .shab is OR-ed into .shbd** |
| `<map>.aid` (optional) | +0x24 `mbi_AreaData` | `AreaInfoData` (FUN_0062d990): `u32 n` (≤ 256), then per area `char name[32], u32 type`; type 0 `AE_Circle` + 3 × 4 bytes, type 1 `AE_Square` + 5 × 4 bytes (the last one is an angle in degrees converted to radians). Script areas (part 9) |
| `<map>.sbi` (optional) | +0x430 `mbi_DoorBlockInform` | door blocks (`MapDoorArray::mda_Load` FUN_0049dd30; `MapDoorArray {mda_TotalHeadCnt, mda_Array[32], mda_Number, mda_BlockBuffer}`): `u32 n` (≤ 31, "Too many doors"), n × `MapDoorBlockElement` (0x38: `Name8 mdbe_BlockName, mdbe_StartX, StartY, EndX, EndY, mdbe_DataSize, mdbe_Address`; `MapBlock::MapDoorBlockElement::mdbe_Load` FUN_0049dc20: `char name[32], u32 x0, y0, x1, y1` in cells, `u32 len, u32 offset`; x1−x0+1 must be a multiple of 8, len = (x1−x0+1)/8 × (y1−y0+1)), then all door images (2 × len per door: closed image, open image) |

Cell size: 50/8 = **6.25 units**; map size in units = bytesPerRow × 50 (x) and rows × 6.25 (y) (`mbi_Load` returns
both; all 158 `.shbd` of 2016 are square). Also built at load: the `BlockDistribute` quadtree (+0x42c `mbi_BlockDistribute`, §9.4).

```pseudo
mbi_IsAttackBlock(map, x, y)  = .shab bit at cell (x·8/50, y·8/50); outside the map → blocked; no .shab → free     @ FUN_0049df00
mbi_IsMoveBlock(map, x, y)  = .shbd|.shab bit; outside → blocked                                               @ FUN_0049df70
mbi_OccupCellCheck(map, x, y, r)                                                                      @ FUN_0049e230
    true when any cell in the (2r+1)² square around (x, y) is inside the map and free in .shbd   # Z02 CellFree uses r = 1
mbi_DoorAction(map, name[32], action)                                                                 @ FUN_0049ec60
    # action = MapBlock::DoorAction: DA_CLOSE 0, DA_OPEN 1, DA_BREAK 2 (pdb2016); everything but DA_OPEN closes
    find the door element whose 32-byte name matches (mda_DoorAction FUN_0049eb60 / mdbe_DoorAction FUN_0049ea40)
    mdbe_DoorAction(door, map, doors, action)   (4-argument overload; log text "mdbe_DoorAction2")      @ FUN_0049e080
        DA_OPEN:  copy the open image (doors.mda_BlockBuffer + mdbe_Address + mdbe_DataSize) row by row over the
                  door's rectangle of .shbd; a row outside the map logs "…mdbe_DoorAction : Null block"
        else (close / break): OR the closed image (mda_BlockBuffer + mdbe_Address) into the rectangle; a row outside the
                  map is not checked here: the OR goes through a null row pointer (original bug) Z09-B25
mda_CloseAllDoor(doors, map): mdbe_DoorAction(each, DA_CLOSE) ("Close error")                            @ FUN_0049e1e0
    callers: bdm_Find (map load), &bigbang (Z11), guild-tournament start, KQ start / destroy (Z16), instance dungeon
    reuse (ZoneRingPacketFindInstanceDungeon::zrpb_Success FUN_005a8c20, MapClusterManager::MapCluster::mc_MissoionFailInstance FUN_0049ee70 dungeon timeout: also clears the map), FieldMap::fm_DropFilm FUN_00419340, cDropFilm FUN_005d6b00
```

Doors are opened by `ShineDoor::so_door_DoorAction` FUN_00550770 (part 8). Only `.shbd` changes, so `.shab` areas can
never be opened.

**Block checks during a move** (vt 0xf40 `smo_BlockCheck(point)` in `mm_Step`; vt 0xf44 after a client stop):

```pseudo
ShineMobileObject.smo_BlockCheck / smo_StopBlockCheck: return true            @ FUN_004be3a0 / FUN_004be5c0
    # mobs, NPCs, servants, pets never test blocks while moving: their paths are checked when planned (§7, §9.3)
ShinePlayer.smo_BlockCheck(p, point)                                          @ FUN_004bec00
    if no map: mm_Halt; StopHere; ReinforceStopHere (0x204A); return false
    if !mbi_IsAttackBlock(point) and !mbi_IsMoveBlock(point) (sp_MoveBlockCheck FUN_004be3f0): lastGood = p.sp_EntrancePoint (+0x2a918/+0x2a91c) = p.pos; return true
    if dist²(p.pos, lastGood) > 899:                  # more than ~30 units into blocked cells
        if (point ± 10 on x or y) all four blocked (sp_MoveFindEmpty FUN_004be4c0; a free one becomes lastGood):
            SetPosition(p, lastGood); mm_Halt; StopHere; ReinforceStopHere; return false
    return true                                      # the step onto the blocked cell is accepted
ShinePlayer.smo_StopBlockCheck(p)  (Z02 "StopBlockCheck")                      @ FUN_004bee40
    if p.pos ≠ lastGood:
        no map: mm_Halt; StopHere; ReinforceStopHere; return false
        if p.pos blocked: SetPosition(p, lastGood); mm_Halt; StopHere; ReinforceStopHere
    return true
ShineMover.smo_BlockCheck(m, point)                                           @ FUN_004bf020
    same as the player with lastGood at +0x2021/+0x2025 (smv_MoveBlockCheck FUN_004be610, smv_MoveFindEmpty
    FUN_004be6e0); on rollback: StopHere only (no 0x204A)
```

So a player is only pulled back after more than ~30 units inside blocked cells, and only if no free cell lies within 10
units of the point; the client is told with 0x2013 + 0x204A.

**Straight-line and "how far can I go" helpers.**

```pseudo
so_FindBlockLocateFrom(from, to, maxDist, out, blockedFn)                     @ FUN_004be1c0
    if ddt_Distance(from, to) > maxDist + 10: return false
    out = from; n = Distance/8 + 1
    for k = 1..n: q = from + (to − from)·k/n; if blockedFn(q): break; out = q
    return true                                      # out = last free point on the line (from if the first step is blocked)
so_FindBlockLocate(o, to, maxDist, out, fn) = so_FindBlockLocateFrom(o.pos, …) @ FUN_004beb40
FieldMap.fm_FindBlockLocation(from, maxDist, to, out, fn)                     @ FUN_004630f0
    same walk with n = Distance/16 + 1; returns 2 = too far, 1 = stopped at a block, 0 = reached `to`
FieldMap.fm_IsStraightPath(a, b, fn) / Navigator::VirtualMap::vm_IsStreight(a, b)   @ FUN_004636e0 / FUN_005ca2f0
    true if dist² < 25; else false if the midpoint is blocked (fn / mbi_IsAttackBlock), else both halves recursively
```

`vm_IsStreight` and the Navigator test **only .shab** (mbi_IsAttackBlock): mob paths ignore `.shbd` walls (and closed doors) unless
the map also has a `.shab`; the per-step check does not run for mobs either. All 8 maps with a `.shab` and the 150
without are treated so *(inferred consequence; whether the 150 maps then let mobs walk through walls was not checked in a
capture)*.

### 9.3 Server-driven moves

```pseudo
so_MoveByServer(o, dest, cmd, lastCmd, kind, logArg)  (vt 0x5b0)              @ FUN_00569510
    o.SendMoveSpeed(1) (vt 0xd4c; player ShinePlayer::so_SendSpeedInformation FUN_00459540: 0x203E MOVESPEED to itself, Z02 §2.2)
    speed = kind == 2 ? GetRunSpeed (vt 0x518) : GetWalkSpeed (vt 0x514)
    MoveStart(o, dest, speed, kind, 0)
    g = (8<<10 | cmd) { u16 handle, u32 pos.x, pos.y, u32 dest.x, dest.y, u16 speed, u16 moveattr (bit 0 cleared) }
    o.lastMoveCmd = lastCmd; remembered payload = g's 22 bytes          # note: lastCmd, not cmd
    broadcast g to sight
    o.vt[0xe98](dest, lastCmd, logArg)                                  # player: smo_ply_ReinforceRun FUN_00566ab0
        p ← (8<<10 | lastCmd) { u32 dest.x, dest.y }                    # 0x2049 REINFORCE_RUN (lastCmd 0x49)
        if dist²(p.pos, dest) > 1,000,000: log both points and logArg
```

Callers: `mab_RunTo` (§7.3, cmd 0x1A), `smo_RunInFear`, `so_mobile_SpeedChange` (players), the map-script node
`ShinePlayerWalk` `PineEventScriptNode::ShinePlayerWalk::sa_Step` FUN_004f6d40 (§25.2: walk, cmd 0x18 / lastCmd 0x4D). The run callers pass lastCmd 0x49 *(as read at the fear / speed-change sites)*.
(original bug) Z09-B14: the remembered command is `lastCmd` (0x49), so a player who comes into sight of an object moved
this way gets `ResendLastMove` (Z02 §5) as **0x2049 NC_ACT_REINFORCE_RUN_CMD** with the 22-byte move payload; the client
reads its first 8 bytes (`handle | from.x<<16`, …) as a destination for its *own* character. The client obeys only
while its main character has the state checked at `MainChar+0x20 / +0x2c` (not identified) *(effect inferred from the
client handler FUN_004aa210)*.

```pseudo
smo_RunInFear(o)  (from so_Routine when feared and not rooted, §5.5)          @ FUN_00569360
    if o rides a mover (vt 0xc74): return
    if o.cast skill (+0x1d88) ≠ 0x7213: o.castEnd (+0x1d84) = 0       # drop any cast except skill 0x7213
    if moving: mm_Step(o.mm, 0); return
    dir = next value of the fear ring DAT_14f722d0 (index DAT_14f7a2d0) × 180 / 64
    target = o.pos + 320 units in direction dir
    if so_FindBlockLocate(o, target, 450, &q, mbi_IsMoveBlock): so_MoveByServer(o, q, 0x1A, 0x49, run, 2)
so_mobile_SpeedChange(o)  (vt 0x7bc, from so_Routine when parameters changed)  @ FUN_00435ec0
    if kind == 1 and speed ≠ GetWalkSpeed: MoveStart(o, destination, walk speed); RememberMove 0x18;
        broadcast 0x2018 SOMEONEMOVEWALK { handle, pos, destination, speed, moveattr }
    if kind == 2 and speed ≠ GetRunSpeed:  MoveStart(o, destination, run speed)
        player: so_MoveByServer(destination, 0x1A, 0x49, 2, 0)           # also 0x2049 to the player
        others: RememberMove 0x1A; broadcast 0x201A SOMEONEMOVERUN
    # MoveStart(dest, speed, kind 1 / 2, backwards 0): the decompile shows (1, 0) as arguments of GetWalkSpeed;
    #   the disassembly (0x435f75 / 0x43609c) pushes them for vt 0x660
so_ReinforceMove(o, dest, speed, backwards, out)  (vt 0xa28, base)            @ FUN_00459600
    if no map: log "…sp_NC_ACT_STOP_REQ : Invalid map" (copied text); return
    if o+0x1c8e & 2: return
    o.CancelOnAction (vt 0x8d0); o.vt[0xed8] (player smo_BashStop, mob SendCeaseFire)
    if !mbi_OccupCellCheck(map, dest, 1): return
    MoveStart(o, dest, speed, kind 3, backwards)
    broadcast to sight (players only, flag 1) 0x2069 NC_ACT_REINFORCERELOC_CMD
        { u16 handle, u32 pos.x, pos.y, u32 dest.x, dest.y, u16 speed, u16 moveattr: bit 0 = backwards }
    out (if given) = the 22 payload bytes
ShinePlayer.so_ReinforceMove(p, dest, speed, backwards, _, clearFlag)  (vt 0xa28 player)   @ FUN_004597f0
    base version; if clearFlag: `p.sp_CeaseFireSender` (+0x7f36).cfs_Flag = 0 (`CeaseFireSender::cfs_Initialize` FUN_00566800); sp_SkillShiftCancel(p)
    p.lastMoveCmd = 0x69 with the payload (newcomers see the push); ClearEmoticon
```

Callers of vt 0xa28: `smo_ShootMeTo` (below), the skill knock-back / pull handler `AbnormalStateContainer::AbnormalStateReinforcedMove::ase_AttachObject` FUN_00401db0 and `NPCAction::BallAction::exe` FUN_005c1390 (Z03
skill effects). Client 0x2069 (FUN_004a4180): `ClearTraceMove`, sets walk/run speed to `speed`, moves the character to
`to`; with bit 0 it keeps facing `from` (pushed backwards).

```pseudo
smo_ShootMeTo(o, dest)  (skill bash "shoot me" to a location)                 @ FUN_00459940
    t = AbState 391 StaBodyForce row's keep time (+0x30 → +0x2b), default 1000
    set abstate 391 (vt 0x638), brief bit, broadcast, inform (vt 0x3f0); same for 350 StaCannotControl
    speed = ddt_Distance(o.pos, dest) × 1000 / t (100 if t == 0); o.so_ReinforceMove(dest, speed, 0, 0, 1)
smo_WarpTo(o, dest, skillRow)  (dash / blink skills)                          @ FUN_004a7de0
    dest.x += 5
    if !so_FindBlockLocate(o, dest, skillRow+0xdc, &q, mbi_IsMoveBlock): return
    kind = 0; StopHere; NewObjBriefInfoChange(q); SetPosition(q); OldObjectDelete(old)
    o ← 0x2450 NC_BAT_SKILLBASH_HIT_FLD_START_CMD { u16 skillId, u32 dest.x, dest.y, u16 counter++ (DAT_0087efe4 & 0x7fff) }
        # to the warping object only; the log text on failure says "smo_SkillBash_BlastA" (copied)
    broadcast to sight (players) 0x4828 NC_SKILL_WARP_CMD { u16 object, from (old), to (q), u16 skill }
    mm_Halt(o.mm)
smo_WarpForward(o, skillRow): dest = o.pos + skillRow+0xdc units in o's direction; smo_WarpTo   @ FUN_004a83e0 / DirectDistanceTable::ddt_GetFoward FUN_004a2db0
smo_JumpTo(o, target, skillRow, _)  (skill blast "jump")                      @ FUN_0057db20
    v = target − o.pos scaled to (row+0x248 == 1 ? |v| − row+0x24c : |v| + row+0x204)   # land short of / beyond the target
    land = o.pos + v
    if so_FindBlockLocateFrom(target, land, that length, &q, mbi_IsMoveBlock) and the straight walk o.pos → q has no mbi_IsAttackBlock cell:
        StopHere; NewObj/SetPosition/OldObj; broadcast 0x482D NC_SKILL_JUMP_CMD { u16 nObject, From, To, u8 nDirect, u16 SkillID }
        mm_Halt(o.mm); return true
    return false
```

`smo_ShadowStep` FUN_0045ad10 (0x206A REINFORCEMOVEBYPATH, Z03 §5) builds its curved path with `RadianMoveTrack`:
`rmt_Calculate` FUN_00460450 turns the angle between the facing and the target into an arc and `rmt_MakePath`
FUN_00460250 splits it recursively (≤ 30 levels, ≤ 19 direction steps per piece) into points whose chords pass
`FieldMap::fm_IsStreight` (both arc directions are tried).

**Teleports.**

```pseudo
ShineMob::so_mobile_Teleport(m, xy)  (vt 0x6d4 for non-players; log text "smo_Teleport")                      @ FUN_005793e0
    StopHere; so_Unmark (vt 0x33c, 0, 1, 3); m.pos = xy; spawn point (+0x249c/+0x24a0) = xy; sm_SetBrain (§6.1)
    if fm_Marking(map, m) fails: log "smo_Teleport : Fail"; mode = 3 (dead); +0x1ec4 = 0
    if m has a brief packet (+0x1f90 → +4 → +0x24): full brief exchange around m (ShineMob::sm_SendMyBriefInfo_AllOfRange FUN_00441f60, so_ExchageBriefInfo)
ShinePlayer::so_mobile_Teleport(p, xy)  (vt 0x6d4 player)                            @ FUN_0057d1d0
    kind = 0; StopHere; SetPosition; ShinePlayer::sp_ReSetSendMyBriefInfo; OldObjectDelete(old); mm_Halt; SendMoveFail (vt 0xa4c)
so_mobile_Teleport()  (vt 0x6d8, random spot)                                       @ FUN_0057a8b0
    q = BlockDistribute random free spot of the map (BlockDistribute::BlockingDistribute::bd_FindEmptyCoord FUN_00438960, §9.4); vt 0x6d4(q)
    callers: so_Routine (§5.5 table), ShineTeleport script node PineEventScriptNode::ShineTeleport::sa_Step FUN_004f4cc0, cCastTeleport FUN_005e5b10, ac_CastTeleport FUN_004229b0, AxialListTeleportAnywhere::ali_Work FUN_00428730
ShineMobileObject::so_smo_SetLocation(o, x, y, dir)  (vt 0xc98, only if o+0x162)               @ FUN_0045a000
    NewObjBriefInfoChange; direction = dir; SetPosition; OldObjectDelete
```

### 9.4 `BlockDistribute`: random free spots

`BlockDistributeManager::bdm_Find` FUN_00438f70 (global `blockdistmanager` DAT_008b7018, ≤ 64 maps, "Too many BlockDistribute") closes all
doors of the map, then builds a quadtree (`BlockingDistribute` ctor `BlockDistribute::BlockingDistribute::bd_Initialize` FUN_00438c80, nodes from the pool DAT_008b7008,
"Too small size" above 59999 units): a node splits into four until both spans are under 100 units; a leaf counts 1 if
its centre is free in `.shbd`; every node (`BlockingDistribute`, 0x20 bytes *(pdb2016)*: `bd_Top, bd_Bottom, bd_Left,
bd_Right` u16, `bd_Brench[4]` +8, `bd_Brenchs` +0x18 child count, `bd_EmptyCellNum` +0x1a free-leaf count, `bd_Act` +0x1c)
keeps its child and free-leaf counts; empty children are dropped. Manager: `bdm_Array[64]` of `{Name3 mapid, → root}`. The tree is built over x ∈ [0, map height] and y ∈ [0, map width] (the arguments are passed swapped; harmless
because every 2016 map is square).

```pseudo
BlockDistribute::BlockingDistribute::bd_FindEmptyCoord(tree)                                                         @ FUN_00438960
    node = root
    while node has children:
        pick a child weighted by its free-leaf count (Random 0..999 against the per-mille shares; 10 tries, else the first child)
    return the leaf's centre
```

Used by `so_mobile_Teleport` vt 0x6d8, `&linkto` (Z11) and the script statement `os_ObjectRegen` FUN_004f8c40 (part 14).

### 9.5 Mob paths: Navigator and MobRoam

**Navigator** (`Navigator::MapNavigator` at field+0xa4, grid step at +0xc, `PathFindBuffer` at +4; used only when
`g_NewBlockRule` DAT_0084cfb4 is set, §7.3):

```pseudo
mn_PathFind(nav, from, to, outPath)                                           @ FUN_005c9ee0
    if to is blocked (vm_IsBlocked = mbi_IsAttackBlock FUN_005ca230): mn_ExitFromBlock FUN_005c8ab0 moves `to` to the first free
        point on growing squares (1..49 units); none → return −1
    PathAnalyzer.pa_Analyze FUN_005c9870: points [from, first block on from→to (vm_FindBlock FUN_005ca470 via
        fm_FindBlockLocation), first block on to→from, to]  (2 points when the line is free)
    2 points: outPath = straight line; return 2
    4 points: outPath = [from, …] + mn_Search(block A → block B) + [to]
        mn_Search FUN_005c9c90: best-first search on the grid around block A (PathFindBuffer FUN_005c8800: a
            (2r+1)² array of 0x14-byte cells {stamp, parent x, parent y, h, g}, Navigator::PathFindBuffer::operator[] FUN_005c88f0 index), 8 neighbours
            (wl_StoreNeighbor FUN_005c9a90, free cells only, g+1, h = Distance to the goal Navigator::VirtualMap::vm_DistanceCalc FUN_005ca210), open list
            sorted by h (wl_Push FUN_005c9980 / wl_Pop FUN_005c90d0); gives up when the best h exceeds the start h + 30;
            on reaching the goal nm_MakePath FUN_005c94a0 follows the parents (≤ 1000) and converts cells back to points
        then the path is shortened: binary search for the furthest point still in straight line (vm_IsStreight) from
        the start, which replaces the second point
    return number of points or −1
```

**MobRoam** (`MobRoaming::MobRoamingSet`, `mrs_Load` FUN_004b8320): a roaming path is
`9Data/Shine/World/<map>/MobRoam/<name>.txt` or else `9Data/Shine/MobRoam/<name>.txt` (28 files in 2016), table
`Roaming` with columns `WORD ID, DWRD X, DWRD Y, STRING[32] EventIndex` (0x2a-byte records). Loaded on demand by the
breeders (`MobHatchery::mh_Load` FUN_004b6330, `mh_ScriptBreed` FUN_004b3e40: part 6) and cached by name
(`mrs_Get` FUN_004b7a00). The breeder hands the vector to the mob with vt 0xa14:

```pseudo
so_mob_RoamingPathSet(m, path): m+0x1eb8 = path; if path: index (+0x1ebc) = 1            @ FUN_004b7400
sm_NextPathPoint(m, &dx, &dy, &dist, &advanced)  (used by mab_RandomDirectWalk, §7.2)   @ FUN_004b7480
    no path or index ≥ count: return false
    p = path[index & 0x7fff]
    if ddt_Distance(m, p) ≤ 100: mrp_Next(m+0x1ebc, path); p = new point; clear "was chasing" (+0x24ac bit 3); advanced = 1
    dx, dy, dist = p − m.pos; spawn point (+0x249c/+0x24a0) = p              # leash and "go home" follow the path
    return true
MobRoamingPoint::mrp_Next(idx, path)                                                     @ FUN_004b71f0
    bit 15 set (walking back): index−1; at 0 → index = 1 forward
    else index+1; at the end: walk back (bit 15, index = count − 2)
        EventIndex of the reached point (first 20 bytes): "-" nothing; "return" → walk back from here;
        "rotate" → index 0 (loop)
ShineMob::smo_RegenSpotAsNextRoamingSpot (vt 0xf50): spawn point = current path point          @ FUN_004b7690
```

**Scenario moves** (NPCs and bandits moved by map scripts):

```pseudo
so_scene_MovePathSet(o, x, y, kind)  (vt 0x8ac; script nodes `run` ShineRun §25.2 / `walk` ShineWalk §26.4)   @ FUN_0050d450
    append {x, y, kind} to the queue o+0x1db0 (16 × 12 bytes, count +0x1e70); full → ignored
smo_MoveByScenario(o)  (from ShineNPC / ShineBandit so_Routine, §5.9 / §5.10)               @ FUN_0050d520
    if queue empty or moving: return
    pop the first entry; kind 1: MoveStart(walk speed, 1), RememberMove + broadcast 0x2018; else run speed, 2, 0x201A
```

### 9.6 Sight: how objects appear and disappear (answers Z02 §5)

The coordinate lists: each object has the block `so_slantedlist` at obj+6 (0x60 bytes *(pdb2016)*: `Xnode` +6, `Ynode` +0xe,
`Xlist` +0x16, `Ylist` +0x22, `eventnumber[4]` +0x2e, `listcheck` +0x3e, `LayerRegistInfo` +0x4e). The two list links are
`SlantedCoordList::CoordedNode {cn_node, cn_prev +4, cn_next +8}`: obj+0x16 `Xlist` (its `cn_node` = `Xnode`, an
`ObjectXCoordNode` whose vt+4 gives the key x, `SlantedCoordList::ObjectXCoordNode::ocn_Getlocation` FUN_00587d00) and
obj+0x22 `Ylist` (`ObjectYCoordNode`, key = y, `SlantedCoordList::ObjectYCoordNode::ocn_Getlocation` FUN_00587d30);
`cn_prev` holds the smaller key (`cn_Rearrange` compares with it). (Part 5 wrote `{vptr, next +4, prev +8}`: corrected.)
Every map keeps two sentinel objects (`fm_SlantedListPoint.zero` field+0x20 at (0, 0) and `.infinite` field+0x24 at
(0xFFFFFF, 0xFFFFFF)) and five anchors (`.flag[5]`, field+0x28…+0x38) on the diagonal at (w/10 + i·w/5, h/10 + i·w/5) — the "slanted" entry points.

```pseudo
cn_Rearrange(node, map, o)  (SetPosition, for both nodes)                     @ FUN_005883a0
    if o's key is still between its neighbours: return
    cn_RemoveList FUN_00553900 then cn_AppendList FUN_00587d60 (walk from the old neighbours to the new place,
        ≤ 10000 steps, consistency checks "Infinite Loop!!!", "Pointer is wandering", "List damaged", "Next & Prev split")
    failure: o.vt[0x8a0](9 | 10); MapRearrangeObserver.mro_Set; fm_Relink(map)
fm_Relink(map)                                                                @ FUN_00462bd0
    reset the nodes of every object of every class container (DAT_00754474 → DAT_132828a4) on this map;
    relink the sentinels (cn_MakeLink2 FUN_00588220) and the five anchors (cn_AppendList), then fm_Marking every
    object again (§5.7)
```

`so_AllOfRange(o, stamp, centre, range, …, work, includeSelf, skipHandle)`, two overloads FUN_0054baf0 / FUN_0054bc80 (Z01 named them `…_Class0` / `…_Class1`): range
0 means the sight radius = MapInfo.Sight (`fm_MapInfo` field+0x10 → +0x48), 99,999,999 when `o.so_eSightState` (+0x163)
== `OSS_WIDE` (1) or `fm_CameraState` (field+0x124) == `CS_MOVING` (1: a script camera move, part 12). It calls the map's query function `fm_BroadFunc.fm_fp_AllOfRange1` (field+0x88, a
member-function pointer; the block `fm_BroadFunc` +0x58 holds `fm_fp_AllInMap1/2`, `fm_fp_AllOfRange1/2`); for normal maps `so_AllOfRangeNomal` FUN_0054c900:

```pseudo
    walk o's X list both ways while |Δx| < range, stamping each object (`so_slantedlist.eventnumber[depth]`, obj+0x2e + depth·4 = stamp; nesting depth g_BroadcastStackPoint DAT_0074d71c)
    walk o's Y list both ways while |Δy| < range; for each stamped object with handle ≠ skipHandle and dist² < range²
        (and inside the cone when a direction is given: dot product ≥ cos(angle/2)):
        if same layer (`LayerRegistInfo.LayerRegNumberUnion`, obj+0x4e/+0x52) or either object's `nViewType` (+0x56, "all layers"): if !work(o, other, dist²): stop
    includeSelf: work(o, o, 0)
    > 10000 steps on one list: log "Too many loop" and stop; a node pointing at itself: o.vt[0x8a0](1..4) and fm_Relink
```

(Mini-house maps use `so_AllOfRangeMiniHouse` FUN_00553f60 / FUN_00554100 instead: §28.1.)

**Appear and disappear on every step.** `mm_Step`, `smo_WarpTo`, `smo_JumpTo`, `ShinePlayer::so_mobile_Teleport` and vt 0xc98
wrap `SetPosition` like this:

```pseudo
smo_NewObjBriefInfoChange(o, newPos)                                          @ FUN_004bdef0
    so_AllOfRange(o, around newPos, sight, AxialListBriefExchangerAtMove)
    ali_Work(o, other)                                                        @ FUN_004bdde0
        s = MapInfo.Sight² (0xFFFFFFFF on unlimited maps); if dist²(o's *old* position, other) < s: skip   # already in sight
        if SubLayer_CanSee(o, other): o.so_SendMyBriefInfo(other) (vt 0x4c8, Z02 §5) + o's abstate list 0x1C19 to other
            # (BriefInformationAbstate::bia_Fill; 0x1C19 only when the list count ≠ 0)
        if SubLayer_CanSee(other, o): other.so_SendMyBriefInfo(o) + other's abstates to o (same count ≠ 0 rule)
smo_OldObjectDelete(o, oldPos)                                                @ FUN_004be0d0
    so_AllOfRange(o, around oldPos, sight, AxialListBriefDeleteAtMove)
    ali_Work(o, other)                                                        @ FUN_004bdfe0
        if other is an NPC (kind 4): skip                                     # NPCs are never removed by moving
        if dist²(o's *new* position, other) < s: skip                          # still in sight
        if SubLayer_CanSee(o, other): other ← 0x1C0E NC_BRIEFINFO_BRIEFINFODELETE_CMD { u16 hnd = o.handle }
        if SubLayer_CanSee(other, o): o ← 0x1C0E { hnd = other.handle }
```

So **the zone does send 0x1C0E** (correction of Z02 §5 / knowledge "no 0x1C0E sender"). The packet is a static buffer
built at start-up (`dynamic initializer of briefinfodelete` FUN_006951d0: buffer 0x74df98, opcode 0x1C0E, payload pointer DAT_0074e028). The same packet goes
out from `AxialListBriefDeleteAllOfRange::ali_Work` FUN_005535c0 (both directions, skipped for objects with the +0x56
"all layers" flag) through the player's vt 0xdc4 (`ShinePlayer::so_ply_DeleteObject_AllOfRange` FUN_00553650, objects in sight) and vt 0xdd0 (`ShinePlayer::so_ply_DeleteObject_AllInMap` FUN_005536f0, whole
map), which the four layer-move entries vt 0xdbc…0xdcc call before changing the layer (Z06 §2 lists them); after the
change vt 0xdd8 `ShinePlayer::so_ply_SendBriefInfo_MoveLayer` FUN_00441ed0 recomputes `g_SightDistSq`, runs `so_ExchageBriefInfo` over the sight range, flushes the
batches (`BriefInfoExchanger::BriefInfoExchangeAll::bixall_Send` FUN_0043fc80) and sends the abstates (`asl_SendAfterLogin`). Other ways out of the client: 0x1805 logout
broadcast (Z01 §3.2) and the death/corpse removal of mobs (§5.4).

Note the distance used here is the plain MapInfo.Sight², not the crowd-reduced `g_SightDistSq` used by the full
exchanges (Z02 §5.2): in crowded places an object can be announced by the full exchange at a smaller radius and then be
deleted/announced at the map radius by moves *(inferred from the two formulas; not observed)*.

(original bug) Z09-B13: in both delete workers the second send ("tell o that other left") calls
`o.sendObject.pcb_Append(other, packet)` with **other** as the first argument (the exchanger passes `o`). The packet still
lands in o's buffer, but when that buffer is full (> 0x17ff bytes) `PacketContainer::pcb_Append` FUN_004c8b20 flushes it
to `other.GetClientSession()` (vt 0xa70): to the other player's client, or to no session (0) when other is a mob.

Client (C01): `On_NC_BRIEFINFO_BRIEFINFODELETE_CMD` FUN_004b99f0 removes NPC/resource/gate effects, puts the handle into
`CharMgr.m_kmapDeletedChar` (CharMgr+0x18 *(pdb2017)*) unless char+0x9be is set, removes a mover's effect, the minimap
mark, decals and the KQ team mark. No client-side distance culling was looked for: the server drives it.

### 9.7 Collision for placement

`so_collesioncheck(o, other)` FUN_00452b00 (the `fm_Marking` spacing test, §5.7) answers "keep looking" (true) unless
`other` takes part in collisions (vt 0x4b8) and is of the same class (vt 0x4b8 values equal and ≠ 3) *(the vt 0x4b8
value is a bool here: players `ShineMobileObject::so_OverlapFactor` FUN_00557240 = mode ≠ 3 (alive); mobs `ShineMob::so_OverlapFactor` FUN_00556540 = always for MobInfoServer +0x5f ∈
{1, 2}, else mode ≠ 3)*.

### 9.8 Open points of this section

- `MainChar+0x20 / +0x2c` (client 0x2049 guard) and player byte +0x7f36 (cleared by pushes) are not identified.
- The meaning of `GetParam()+0xcce` bits 0/1 (which abstates set them): Z03 §6.
- `so_AllOfRangeMiniHouse` (mini-house interiors) and the field+0x88 selection in `FieldMap::fm_Init` FUN_00464bc0: answered in §28.1.
- Callers of vt 0xc98 (`SetPositionWithSight`): the mover passenger moves only (§28.4).

## 10. Spawns: MobHatchery, breeder groups, breeders, script spawners

Mobs placed by the map data respawn through *breeders*. Scripts, Lua and GM commands either create breeders too
(timed, counted) or spawn a mob once without a breeder. The spawn itself is `so_mob_Regenerate` (§5.3); the death and
removal of the mob is §5.4. Mob roaming paths handed over at spawn: §9.5.

### 10.1 Data files

`MobRegen/<map>.txt` (one per map instance of Field.txt; the zone also tries `World/<…>/MobRegen/<map>.txt` first, see
§10.3). Script-file format (`#table`, `#columntype`, rows packed by column type: INDEX = 20 bytes, STRING[n] = n bytes):

| Table | Column (offset in the packed row) |
|---|---|
| `MobRegenGroup` | `GroupIndex` INDEX +0, `IsFamily` STRING[1] +0x14 ('Y' / 'N'), `CenterX` +0x15, `CenterY` +0x19, `Width` +0x1d, `Height` +0x21, `RangeDegree` +0x25 (DWRD each); row 0x29 bytes |
| `MobRegen` | `RegenIndex` INDEX +0 (= GroupIndex), `MobIndex` STRING[33] +0x14, `MobNum` BYTE +0x35, `KillNum` BYTE +0x36, then 12 DWRD from +0x37: `RegStandard`, `RegMin`, `RegMax`, `RegDelta0`, `RegSec0`, `RegDelta1`, `RegSec1`, `RegDelta2`, `RegSec2`, `RegDelta3`, `RegSec3`, `RegDelta4` (seconds); row 0x67 bytes |

Region: `Height == 0` → a circle of radius `RangeDegree` around the centre (`Width` ignored); otherwise a rectangle of
half-extents `Width` × `Height`, rotated by `RangeDegree` degrees. `KillNum` is the family kill limit (§10.5).

`MobRegen/KingdomQuest/*.txt` and `MobRegen/Instant/*.txt`: same two tables, loaded whole at start-up into the
`KQRegenTable` (§10.6) and spawned only by scripts. *(Data note: `KD_Kingkong.txt`, `KDKingkong2.txt`, `KDKingkong3.txt`
and the root file `MobRegen/KingdomQuest.txt` have no `KillNum` column; because rows are packed by the declared types
their regen times sit one byte earlier than the code reads them (+0x37), so those rows get garbled regen times. Data
problem, not code.)*

Not zone data: `MobNoFadeIn.shn` (`MobInx` list of projectile-like mobs) is loaded only by the client
(`MobNoFadeInTab::IsNoFadeIn` client FUN_004c4190): mobs that appear without the fade-in. `MobSetting/Action/*.txt`
(`Trigger { ConditionID, ActionID }`) is loaded by the NPCAction trigger loader `NPCAction::Util::loadTriggers` FUN_005c4420 (§16.1). `MobRegenAni.shn`:
§5.1 / §5.3.

### 10.2 Objects

Layouts *(pdb2016)*; PDB member names first, our description after.

```pseudo
mobhatchery  DAT_0da28ad0 → MobHatchery (0x19b8018 bytes)
    +0x0        mh_Array: MobBreederGroup[4096] (inline, 0x19b8 each; the 4096 of part 6's inference is confirmed)
    +0x19b8000  mh_Groups: MobRegenGroupList = List<MobBreederGroup> (+4 capacity, +8 entries {ptr, u16 next, u16 prev,
                u8 used}, +0xc free head, +0xe used head, +0x14 count). `MobRegenGroupList::l_AllocA` /
                `l_AllocZ` FUN_004b2260 / FUN_004b22a0 (list vt overrides) set the group's mbg_AIType to "Def".

MobBreederGroup : List<MobBreeder>  (0x19b8; ctor MobBreederGroup::MobBreederGroup FUN_004b3ce0; copy MobRegenClass::MobBreederGroup::operator= FUN_004b2af0)
    +0x00   List<MobBreeder> header (capacity 64, count u16 +0x14)
    +0x18   mbg_array: 64 × MobBreeder (0x64 bytes each)   "Too many mob in regengroup" when full
    +0x1918 mbg_GroupName (ORToken: name[20], GroupIndex)   +0x192c mbg_isFamily ('Y' for file / script groups; 0/1 for mh_MobBreed)
    +0x192d mbg_regentime (MobBreedSecond, 12 × u32: copy of the MobRegen row, only for the GM view)
    +0x195d mbg_RegenMap (Name3, map[12])
    +0x196c mbg_AIType (ORToken; "Def", or the AI-type argument of mbg_ScriptDataStore FUN_004b3820; written, never compared)
    +0x1980 mbg_RegenRegion.region (RegenRegion {rgs_CenterX, rgs_CenterY, rgs_Width, rgs_Height, rgs_Rotate = RangeDegree})
    +0x1994 .rectangle: half-width, half-height, cos / sin of RangeDegree × 1024
    +0x19a4 .circular: radius, radius²
    +0x19ac mbg_RegenDirect: copied out by mbg_RegenLoc; never written except by the copy (always 0; the callers overwrite it)
    +0x19b0 mbg_Leader (family leader breeder; file / script loaders)    +0x19b4 mbg_RoamingPath (MobRoaming path, §9.5) or 0
    l_AllocA / l_AllocZ (FUN_004b20a0 / FUN_004b2180) clear the breeder's family links; l_Free (FUN_004b5c00) clears them,
    calls fmm_Remove(breeder) (§10.5) and frees the slot (FUN_004b1300, a shared `List<…>::l_Free` instance)

MobBreeder (0x64 bytes; ctor LAB_004b0e40: mobId 0, level −1, count −1, active 1)
    +0x00 mb_Group → group     +0x04 u8 mb_IsRegenEnable (cRegenGroupActiv)     +0x06 u16 mb_MobID     +0x08 mb_Level (−1 = MobInfo)
    +0x0c mb_RegenTime (MobBreedSecond {standard, minsec, maxsec, long timedist[9]}): RegStandard, RegMin, RegMax,
          RegDelta0, RegSec0, RegDelta1, RegSec1, RegDelta2, RegSec2, RegDelta3, RegSec3, RegDelta4
    +0x3c u16 mb_MobHandle of the current mob (0xFFFF none)
    +0x40 mb_NextRegen {+0x40 leftregen: next spawn time (g_Now), +0x44 u8 waitregen (1 = timer armed, 0 = mob out),
          +0x48 currentregensec (current regen time, s), +0x4c regentime_tick (spawn time, set by so_mob_RegenComplete),
          +0x50 deadtime_tick (death time, set by ShineMob::so_KilledBy)}
    +0x54 mb_RegenCount: spawns left (−1 = unlimited)
    +0x58 mb_Family {prev, next +0x5c}: the family chain (head = leader, prev == 0)
    +0x60 mb_BanditTemplete (PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD *): non-null → the pool object is a ShineBandit (kind 8)
          and mb_regen passes it to so_mob_Regenerate as the bandit's brief template (§5.3); null → ShineMob (kind 5)
```

`mb_Set(b, group, mobId, times[12], count)` FUN_004b3110: copies the 12 times, `+0x48 = RegStandard`, `+0x44 = 1`,
`+0x40 = RegDelta2 × 10`, `+0x54 = count`; the handle +0x3c is set neither here nor by the ctor (harmless: the first
spawn overwrites it; a stale value can at most count one extra family death before `fmm_Initialize` resets the counts). `mb_Setregentime(b, sec)` FUN_004b1b90
sets all 12 times to `sec` (a fixed regen time). `mb_SetLeader(b, leader)` FUN_004b2400 appends `b` at the end of the
leader's family chain.

### 10.3 Loading the map's regen file

Called once per map instance hosted by this zone, from the field set-up FUN_00464bc0 (`FieldContainer::fc_MakeField`
FUN_004650a0 ← Field.txt loader `FieldContainer::fc_Load` FUN_004655f0), after the block files:

```pseudo
MobHatchery::mh_Load(h, fieldRow, map[12])                                           @ FUN_004b6330
    f = new ScriptFile
    if f.open("../9Data/Shine/World/<fieldRow.MapIDClient>/MobRegen/<map>.txt"):    # argument order from the pushes (inferred)
        return            # (original bug) Z09-B17: an override file is opened and then nothing is parsed
    if not f.open("../9Data/Shine/MobRegen/<map>.txt"): return                       # map without mobs
    for each row g of table "MobRegenGroup":
        if g.CenterX ≥ 0xFFFFFF or g.CenterY ≥ 0xFFFFFF: log "mh_Load : Invalid LoginLoc"; continue
        grp = new group  (none: FATAL "MobHatchery::mh_Load : Too many MobRegenGroup")
        mbg_Set(grp, g.GroupIndex, map, g.IsFamily, &g.CenterX)                     # below
        grp.roam (+0x19b4) = roamingpaths.mrs_Load(&DAT_0da29330, fieldRow, g)      # §9.5
    for each row r of table "MobRegen":
        (current row DAT_0da28adc, map DAT_0da28ad8)
        if ForEach(group, mbg_StoreData) found no group: log "RegenMob without RegenGroup in <map>",
            "RegenGroup is <r.RegenIndex>", FATAL "MobHatchery::mh_Load"

mbg_Set(grp, name, map, family, region)                                              @ FUN_004b1f30
    grp.name = name; grp.IsFamily = family; grp.map = map; grp.region = region (5 u32); grp.leader = 0
    if Height == 0: radius = RangeDegree; radius² = RangeDegree²
    else: halfW = Width; halfH = Height
          a = RangeDegree as an UNSIGNED 32-bit value × 0.01745329 (rad)   # (original bug) Z09-B16: negative angles
          cos1024 = ftol(cos(a)·1024); sin1024 = ftol(sin(a)·1024)         #   become 2³²−n degrees (−2° → 353.9°);
                                                                           #   R2: the field is `ulong rgs_Rotate` in the PDB

mbg_StoreData(grp)  (ForEach functor; true = keep searching)                        @ FUN_004b5e70
    if r.RegenIndex ≠ grp.name or map ≠ grp.map: return true
    grp.times = r.times (12 u32)
    if r.RegStandard ≥ 604800 (7 days; negatives included): log "Minus regen time" (twice), return true
        # → no other group matches → FATAL "RegenMob without RegenGroup" (a bad regen time stops the zone)
    repeat r.MobNum times:
        b = new breeder in grp  (none: log + FATAL "mbg_StoreData : Too many mob in regengroup")
        mobId = mobdatabox.IdByName(r.MobIndex) (BTree::operator[] FUN_0063cc30 on DAT_14d450a0); unknown: log "Wrong mob name", mobId = 1
        if grp.IsFamily == 'Y':
            first breeder → grp.leader; later ones → mb_SetLeader(b, grp.leader)
            fmm_Regist(g_FamilyMobManager, grp.leader, mobId, r.KillNum)            # §10.5
        mb_Set(b, grp, mobId, r.times, −1 unlimited) (failure → free b; it never fails)
    return false (stop)
```

So every MobRegen row adds `MobNum` breeders of one mob to its group; a family group (`IsFamily = Y`) becomes one chain
whose leader spawns and respawns the whole family together. The first spawn is due at `g_Now = RegDelta2 × 10`, i.e.
at the first regen tick after start-up (g_Now is far larger) *(inferred: probably meant as an initial delay)*.

### 10.4 The regen tick: `EventMobRegen`

The static object `eventmobregen` (DAT_14d41eb4, vftable 0x6c25fc, ctor `EventMobRegen::EventMobRegen` FUN_004b0e00 from a static initialiser) is put
into the event-reserve list (§1.4) by `zs_start_open` with first run `g_Now + 10` and **repeat 10 (1 s)**. (The other
event reserved there repeats every 300 tenths = 30 s; Z01 §2.2 says "300 s and 10 s": both values are tenths.)

```pseudo
EventMobRegen::erb_happen()                                                          @ FUN_004b56a0
    ForEach(mobhatchery+0x19b8000, mbg_Routine)

mbg_Routine(grp, list, idx)                                                          @ FUN_004b55a0
    if grp.count == 0: list.vt[0xc](idx)          # empty group (all script breeders used up) is freed
    else ForEach(grp, mb_Routine)

mb_Routine(b, grp, idx)                                                              @ FUN_004b52c0
    if b.count == 0:                              # limited breeder used up
        if som_GetObject(b.handle) == 0: grp.vt[0xc](idx)       # free the breeder (l_Free) once its mob is gone
        return
    if b.handle ≠ 0xFFFF and som_GetObject(b.handle) == 0:      # its mob has disappeared (killed, expired, removed)
        b.handle = 0xFFFF
        leader = head of b's family chain (follow +0x58)
        if fmm_Dead(g_FamilyMobManager, leader, b.mobId):        # kill limit of this mob reached (§10.5)
            log "mb_Routine - FAMILYANIHILATED"
            for m in leader's chain: o = som_GetObject(m.handle)
                if o and o.mode ≠ 3 and not o.IsDead (vt 0x28): o.so_KilledBy(o, o.GetHP())   # vt 0x5bc: killed by itself
    if b is not a leader (+0x58 ≠ 0) or not b.active: return     # members are handled by their leader
    if b.waiting == 0:                            # the family is out
        if any m in chain (from b) still has an object: return
        life = (b.deathTime − b.spawnTime) / 10   (unsigned division, then compared as signed seconds)
        delta = life < RegSec0 ? RegDelta0 : life < RegSec1 ? RegDelta1 : life > RegSec3 ? RegDelta4
              : life > RegSec2 ? RegDelta3 : 0                     # RegDelta2 is never used here
        t = b.regen + delta;  b.regen = (t < RegMin or t > RegMax) ? (the violated bound) : t   (unsigned compares)
        b.waiting = 1;  b.nextAt = g_Now + b.regen × 10
    elif b.nextAt < g_Now:                        # time to spawn the family
        fmm_Initialize(g_FamilyMobManager, b)     # dead counts of this family back to 0
        for m in chain from b: m.waiting = 0; m.handle = mb_regen(m, b); if m.count > 0: m.count −= 1
```

Adaptive regen time: a mob killed quickly (lived `< RegSec0` s) shortens its next regen time by `RegDelta0` (negative in
the data), one that lived long lengthens it, always within `[RegMin, RegMax]`, starting from `RegStandard`. Only the
leader's times and timestamps count for a family. `deathTime` is written only by `so_KilledBy`: a mob that vanished
without a kill leaves the previous value, `deathTime < spawnTime` makes the unsigned division huge, and the mob counts
as long-lived (`RegDelta4`) *(inferred from the arithmetic)*.

```pseudo
mb_regen(b, leader) → handle | 0xFFFF                                                @ FUN_004b2cf0
    h, o = som_AllocObject(kind 8 if b.bandit else 5)      none: log "MobBreeder::mb_regen : Too many mob", return 0xFFFF
    if b == leader:
        pos = mbg_RegenLoc(grp)                            # always succeeds; the "free reason 0x23" branch is dead
        familyLeaderObj = 0
    else:
        familyLeaderObj = som_GetObject(leader.handle)
        if familyLeaderObj == 0: return 0xFFFF             # (original bug) Z09-B18: o stays allocated, never freed
        pos = familyLeaderObj.SpawnPoint (vt 0x614)        # members spawn on the leader's spawn point
    dirDeg = RandomRing(72) × 5                            # ring DAT_14fb2310: 0, 5, … 355
    if grp.roam: pos = first point of the roaming path (MobRoaming::MobRoamingPath::mrp_RegenLoc FUN_004b77c0)
    if pos.x ≥ 0xFFFFFF or pos.y ≥ 0xFFFFFF: log "mb_regen : Invalid locate" + group name, free(o, reason 0x24), return 0xFFFF
    if o.so_mob_Regenerate(grp.map, pos, dirDeg, h, b.mobId, banditBrief = b.bandit, mobRegnum = mobregnum DAT_0da2932c (always 0),
                           familyLeaderObj, breeder = b, level = b.level, 1, 0) ≠ 0:   # §5.3
        free(o, reason 0x25), return 0xFFFF
    o.vt[0xa14](grp.roam)                                  # roaming path (§9.5)
    o.SetLifeTime(MobLifeTime of the mob, entry[9]) (vt 0xabc, §5.4) when the mob has a data entry
    return h

mbg_RegenLoc(grp, &pos, &out) → 1                                                    @ FUN_004b1d60
    out = grp+0x19ac
    circle (Height == 0): pos = RandomPointInCircle(Center, radius)                 (MobRegenClass::MobRegenLoc_Circular::mrlc_Get FUN_004b0e80)
    rectangle: if halfW < 1: log "mbg_RegenLoc : Width Zero" + group name; dx = dy = 0
               else dx = rand() % (2·halfW) − halfW;  dy = rand() % (2·halfH) − halfH       (CRT rand FUN_006594b2)
               pos.x = CenterX + (cos1024·dx + sin1024·dy) / 1024;  pos.y = CenterY + (cos1024·dy − sin1024·dx) / 1024

RandomPointInCircle(c{x, y, r}, &pos)                                                @ FUN_004b0e80
    k = RandomRing(3):  frac = k==0 ? RandomRing(64) : k==1 ? 64 + RandomRing(32) : 96 + RandomRing(32)   # of 128
    d = r·frac / 128;  a = RandomRing(64) · 180 / 64        # 64 directions in the 0..179 (2°) unit
    pos = (c.x + cos(a)·d / 1024, c.y + sin(a)·d / 1024)    # FUN_005790e0 / FUN_00579110: ×1024 tables (DAT_13283770)
    # a third of the spawns fall in the inner half radius, a third in 0.5–0.75 r, a third in 0.75–1 r (≈ area-uniform)
```

A spawn that fails (`0xFFFF`) leaves `handle = 0xFFFF`; the next tick sees the family "out" and re-arms the timer, so a
failed spawn is retried one regen period later.

### 10.5 `FamilyMobManagement::FamilyMobManager` (`g_FamilyMobManager` DAT_0da29314)

`fmm_List`: a vector of `FamilyMob {MobBreeder* fm_Key (leader), vector<MobSpeciesSlot> fm_FamilyList}` (0x14 bytes),
`MobSpeciesSlot {u16 mss_Species (mob ID), u16 mss_MinKilled (limit), u16 mss_Killed (dead)}` *(pdb2016)*.

```pseudo
fmm_Regist(fm, leader, mobId, limit)        @ FUN_004b5cf0   add the leader record if new (std::vector<FamilyMob>::push_back FUN_004b5b30); add {mobId, limit or
                                                             60000 when 0, 0} unless that mobId is already listed
fmm_Dead(fm, leader, mobId) → bool          @ FUN_004b5120   ++dead of that mobId; return dead ≥ limit (false when not listed)
fmm_Initialize(fm, leader)                  @ FUN_004b5050   every dead count of the leader's record = 0 (FamilyMobManagement::MobSpeciesSlot::mss_Clear FUN_004b12d0)
fmm_Remove(fm, breeder)                     @ FUN_004b5a40   erase the record whose leader is this breeder (from l_Free)
```

Only file families register limits (`KillNum`; 0 → 60000 = never). Example data: `R_Helga01` group `boss` (Helga,
`KillNum 1`) and `AdlThorn01` `21c` (IncubusRock, `KillNum 1`): when that mob disappears once, every other living mob of
its family dies with it. Script families from `mb_MobBreed` register `limit 3` (§10.6); `mbg_ScriptDataStore` registers
none, so `fmm_Dead` is always false for them.

### 10.6 Breeders created by scripts, Lua and GM commands

```pseudo
MobHatchery::mh_MobBreed(h, map, pos, _ (0), mobId, _, mobNum, regenSec, family, count, key[20], bandit, _, _, level)
                                                                                     @ FUN_004b6960
    grp = new group (none: return 0)  → mbg_MobBreed(grp, …)

mbg_MobBreed(grp, map, pos, outArg, mobId, _, mobNum, regenSec, family, count, key, bandit, _, _, level) → last breeder | 0
                                                                                     @ FUN_004b6770
    grp.IsFamily = family; grp.map = map
    mbg_SetRegenLoc(grp, pos)    @ FUN_004b1c90: circle of radius 50 around pos (radius² 2500), rectangle fields 0
    grp+0x19ac = outArg; grp.key = key
    if mobNum < 1: log "mbg_MobBreed : Minus mobnum"; mobNum = −mobNum
    repeat mobNum times:
        b = new breeder (none: return 0)
        leader = first breeder when family ≠ 0
        if not mb_MobBreed(b, grp, mobId, regenSec, count, leader, bandit, level): free b, return 0
    return b
    # an empty group (mobNum 0) is freed by the next mbg_Routine

mb_MobBreed(b, grp, mobId, regenSec, count, leader, bandit, level) → bool            @ FUN_004b6150
    b.level = level; b.group = grp; b.mobId = mobId
    mobdatabox[mobId] missing: log "mb_MobBreed : Invalid mob index", return false
    if leader and leader ≠ b: insert b right after the leader in the chain; fmm_Regist(leader, mobId, 3)
    mb_Setregentime(b, regenSec)        # fixed regen time, no adaptation (Min = Max = Standard)
    b.handle = 0xFFFF; b.count = count; b.waiting = 1; b.nextAt = regenSec × 10 (≈ now: spawns on the next tick); b.bandit = bandit
```

Callers: GM `ac_MobBreed` FUN_0041b510 (all arguments from the command; family, count, regen, level) and `AmpersandCommand::ac_MobBreed_simple` FUN_0041b790
(one mob, count 1, regen 0) (Z11); Pine node `ShineSummonMob::sa_Step` FUN_004ef160 (mobNum from the node, regen 0,
no family, count 1, level −1: each mob spawns once around the script object's position) (§26.3). With `count 1` the
breeder spawns once; after its mob is gone the breeder, then the empty group, is freed.

```pseudo
MobHatchery::mh_ScriptBreed(h, map, regenRow, groupRow, key[20])                    @ FUN_004b3e40
    grp = new group (none: log "mh_ScriptBreed : Too many MobRegenGroup", return)
    mbg_Set(grp, regenRow.RegenIndex, map, groupRow.IsFamily, &groupRow.CenterX)   # §10.3
    grp.roam = roamingpaths.mrs_Get(&DAT_0da29330, regenRow.RegenIndex)          # cached roaming path by group name
    mbg_ScriptDataStore(grp, regenRow, key)

mbg_ScriptDataStore(grp, r, key)                                                     @ FUN_004b3820
    grp.times = r.times; grp.key = key
    mobId = IdByName(r.MobIndex); missing or row mismatch: log "Invalid mob name" (and "MobDataBox::operator [] :Invalid
        mob index"), return
    repeat r.MobNum: b = new breeder (none: log "Too many mob in regengroup", stop)
        mb_Set(b, grp, mobId, r.times, count 1)                 # adaptive times, but one spawn per breeder
        family 'Y': first → grp.leader, others mb_SetLeader      # no fmm_Regist: no kill limit
    # the "Wrong mob name" branch inside the loop is dead (the name was checked before)
```

The roaming paths that script groups find with `mrs_Get` are preloaded at start-up (stage zs_start_sun) by FUN_004b8690
= `MobRoaming::MobRoamingSet::mrs_Load` *(pdb2016; our earlier name `MobRoamingSet_LoadScriptPaths`)*: every `RoamingFile` (string, column type 2 checked: "sbs_LoadScripts : Type
error") of table `RoamingData` in `World/PineScript.txt` is loaded with `mrs_Load` (FATAL "Roaming Data(in
PineScript.txt)not found" when missing; FATAL "Option read error" without the file).

Callers of `mh_ScriptBreed`: Pine node `ShineRegenGroup::sa_Step` FUN_004ee0f0 (optional x/y override of the group
centre, restored afterwards; §25.1), Lua `cGroupRegenInstance(map, regenIndex)` FUN_005ddaa0 and
`cGroupRegenInstance_XY(map, regenIndex, x, y)` FUN_005ddc40 (centre replaced by x, y for this call; both return 1 / push
true). All pass key "Def" and take the rows from the `PineScriptMobRegenerator`:

```pseudo
scriptmobregen DAT_13249728 = { entries (0x90 each: group row 0x29 + MobRegen row 0x67 at +0x29), u16 capacity
    +4 (doubles when full; "psmr_Store : Memory overflow"), u16 count +6, name index +8 }
psmr_find(psmr, file, regenIndex) → entry | 0                                        @ FUN_004e7bd0
    key = "<file>:<regenIndex>" (psmr_makeindex FUN_004e7640); not cached → psmr_Load(psmr, file); look up again
psmr_Load(psmr, file)                                                                @ FUN_004e7990
    t = bsearch(file (12 bytes), kqregentable.kqrt_Array DAT_0da28ff0, count kqrt_Number DAT_0da29310)   # loaded at start-up, below
    for each MobRegen row r of t not yet cached: g = the MobRegenGroup row with GroupIndex = r.RegenIndex
        (OptionReader::or_SelectFrom); missing: log "psmr_Load : Group name not found"; else psmr_Store(psmr, r, g, key) @ FUN_004e7790
KQRegenTable::kqrt_Load (all)  FUN_004b3220: every MobRegen/KingdomQuest/*.txt, then every MobRegen/Instant/*.txt
    ("Path Invalid" FATAL when a directory is missing) → `kqrt_Load(file)` FUN_004b26b0 per file: name without extension (12 bytes) + parsed
    ScriptFile, ≤ 50 files ("Too many kq regen table" FATAL), "Error found" FATAL when the file cannot be parsed; sorted
    by name (KQRegenTable::Element::Comp FUN_004b1290). Start-up stage zs_start_tough (Z01 §2.2). Layout *(pdb2016)*:
    `KQRegenTable {Element kqrt_Array[50] {Name3 tablename, OptionReader* or}, int kqrt_Number +0x320}`.
```

The Lua callers use the map's base name (map record +0xc → name) as the file name: `cGroupRegenInstance("Tower01",
"…")` spawns the group `…` of `MobRegen/Instant/Tower01.txt` on that map instance.

Group control from Lua (both find the group with `MobHatchery::mg_FindBreedGroup` FUN_004b2320: `(map[12], name[20])` over the hatchery's group list):

```pseudo
cGroupRegen(map, groupName)          @ FUN_005efc60   for every breeder b of the group: mb_regen(b, b) (MobRegenClass::MobBreederGroup::mbg_RegenFromLua FUN_004b30c0)
                                                      → one extra mob per breeder at a random group spot; the handles
                                                      are not stored (untracked, never respawned); push 1
cRegenGroupActiv(map, groupName, on = 1)  @ FUN_005efdc0   every breeder.active = on (functor MobBreedRegenEnable
                                                      MobBreedRegenEnable::lid_Call FUN_004b1d40 via MobRegenClass::MobBreederGroup::mbg_SetEnableNextRegen FUN_004b3060); push 1. Inactive leaders neither
                                                      re-arm nor spawn; deaths are still counted
```

### 10.7 Direct spawns from Lua (`cMobRegen_*`)

All allocate a pool `ShineMob` (kind 5), call `so_mob_Regenerate(map, x, y, dir, h, mobId, banditBrief 0, mobRegnum −1,
leader 0, breeder 0, level −1, flag 0, layerRegNum)`, set the MobLifeTime (vt 0xabc) and push the handle (one return
value); on a failed Regenerate they log and free the slot (reason 0x16) and return nothing. No breeder: the mob never
respawns. Map = `FieldContainer::fc_FindMap FUN_00466a60(name)` (field by name) whose centre object exists (`fm_GetCenterObject`).

| Lua function | Arguments | Position / direction |
|---|---|---|
| `cMobRegen_XY` FUN_005d8440 | map, mob, x, y, dir | as given ("som_AllocObject fail", "map regen fail") |
| `cMobRegen_Obj` FUN_005d8690 | mob, handle | the object's map and position; direction = `*(newMob+0x6a)`, the **new** pool object's stale direction (original bug) Z09-B19 |
| `cMobRegen_Circle` FUN_005e1ea0 | map, mob, x, y, r | `RandomPointInCircle`; dir = RandomRing(90) × 4 |
| `cMobRegen_Rectangle` FUN_005e2100 | map, mob, x, y, w, h, deg | `MobRegenClass::MobRegenLoc_Rectangle::MobRegenLoc_Rectangle FUN_004b0f90` / `MobRegenClass::MobRegenLoc_Rectangle::mrlr_Get FUN_004b1000` (same rotated rectangle as §10.4; here `deg` is signed); dir = RandomRing(90) × 4; log "cMobRegen_Rectangl Fail" |
| `cMobRegen_XY_Layer` FUN_005e7680 | map, mob, x, y, dir, a6, a7, handle | layers = `ref.vt[0xdb8](a6, a7)` of the object `handle`: only players implement it (`ShinePlayer::so_ply_MakeLayerRegNum` FUN_0054ab40: the player's private layer +0x7f3d when a7 == 1; 0 for 2) *(partly inferred)*; others (0, 0) |

### 10.8 `ScriptMobBreeder` (Pine `SysFunc` helpers)

```pseudo
smb_ShineObject(ctx, handle)            @ FUN_004e3080   som_GetObject or log "smb_ShineObject : NO Object"
smb_ObjectRegen(ctx, o, h, node) → bool @ FUN_004e3180
    args (Pine expression evaluator PineEventScriptNode::ArgumentList::al_GetArgument FUN_004d64c0): 0 mob name, 1 x, 2 y, 3 dir, 4 (evaluated; its use is not visible in
    the decompile); map = the script's map (Movie::Theater::t_MapNameServer FUN_004e3010 on ctx+0x10118, "smb_ObjectRegen" 0 when none); a failing
    argument logs "smb_ObjectRegen" with its index
    o.kind (vt 0x4d0) 4 / 5 (NPC / mob): vt 0x6e0 Regenerate(map, x, y, dir, h, mobId, 0, −1, 0, 0, −1, 1, 0, 0);
        failure: free(h, reason 200), return false
    kind 7: vt 0x6dc `ShineDoor::so_door_Build`(map, x, y, dir, h, mobId, scale 1000, layer 0)   # doors (§13.1)
    other kinds: log "smb_ObjectRegen : Invalid ObjType"
smb_ObjectChange(ctx, o, h, node)       @ FUN_004e3540   arg 0 = handle of an existing object, arg 1 = mob name: spawn o
    at that object's map / position / direction (same kind rules; "Null map" when it has none); the old object is
    not removed here
```

Callers: `SysFuncShineMobRegen` `PineEventScriptNode::SysFuncShineMobRegen::sfb_Calculate` FUN_004e3850 (allocates kind 5; "Too many mob"; on failure frees the slot again with
`List<ItemActionObserve>::l_Free` FUN_004b1300 after smb already freed it *(effect of the second free not checked)*), `SysFuncShineDoorBuild`,
`SysFuncShineNPCStand`, `SysFuncShineChange2Mob/Door/NPC` (part 14).

### 10.9 GM view

`MobHatchery::mh_View(h, gm)` FUN_004b3a60 (`&mobhatchery`, Z11) → `mh_View` per group `MobRegenClass::MobBreederGroup::mbg_View` FUN_004b3370: groups of the GM's
map print `"%s [%d/%d/%d]%d/%d/%d/%d/%d/%d/%d/%d/%d %s"` (name, the 12 times, map) as a GM chat line (vt 0x784) and to
the hatchery log, then `mb_View` FUN_004b2880 per breeder: `"  Mob[%d] RgNum[%d] Hnd[%d[%s]] NxtRg[%d/%d[%d]]"` (mobId,
spawns left, handle, alive mark, waiting, nextAt, g_Now).

### 10.10 Treasure chests: `MagicContainer` and `TreasureChestMaker`

Not a world object: the content generator for "item chest" items (item class 15), used when such an item is bought
(Z04 §`ii_BuyAll` → `sp_MagicContainerMake`) and for KQ rewards (`sp_KQReward` FUN_0052da70, Z16).

`World/TreasureReward.txt` (`MagicContainer::mc_Load` FUN_0049c7f0 into `magiccontainer` DAT_0d67a1f0, stage zs_start_tough;
`MagicContainer {OptionReader mc_OptionTable}`; the maker is `TreasureChestMaker {ItemTotalInformation tcm_rewarditem[9],
int tcm_ItemNum +0x3e8}` *(pdb2016)*, so the chest plus at most 8 contents):

| Table | Columns |
|---|---|
| `Container` | `ItemID` DWRD +0 (replaced by the item ID of `CardInx`), `Index` WORD +4, `CardInx` [33] +6, `MinLot` +0x27, `MaxLot` +0x29 (number of contents, ≤ 7), `DummyInx` [33] +0x2b ('-' = none) |
| `Content` | `ItemID` +0 (replaced by the ID of `RewardInx`), `Index` +4, `RewardInx` [33] +6, `RewardLot` WORD +0x27, `UpgradeLow` +0x29, `UpgradeHigh` +0x2a, `RewardRate` DWRD +0x2b (per million), `CheckSum` WORD +0x2f (must equal ItemID) |

Load checks (each FATAL): table empty, unknown card ("Invalid card"), more than 7 contents, unknown dummy, checksum,
unknown reward, rates of a container not summing to 1 000 000 ("TotalRate not 1000"). The container item gets the
item-use function "UsePresentBox"; the dummy card gets "UseSkill" and an `ItemConversionMap` entry dummy → container
(`itemconvmap` DAT_0d67a168, ≤ 32, "icm_Store : Too many item map").

```pseudo
ShinePlayer::sp_MagicContainerMake(p, item, priceLo, priceHi)                       @ FUN_0049c050
    item class (attribute class vt 0x28) ≠ 15: return
    chest = TreasureChestMaker(item.id, kind 6, 0)   @ FUN_00595a40: ItemData.class must be 15 ("Not ItemChest"), key =
            ItemTotalInformation::iti_mkregnum(id, 6, zone, world); tcm_ItemNum (+0x3e8) = 1 (the chest itself)
    c = Container row with ItemID = item.id ("sp_MagicContainerMake : Null Container" → return)
    n = MinLot + RandomRing(MaxLot − MinLot + 1)
    repeat n: roll = cWell512Random::well512_GetRandom(g_Rng, 1 000 000); walk the Content rows of c.Index subtracting RewardRate until
              roll ≤ rate ("Content Null" / "Content Null2" when none); new item: lot RewardLot ("-L%d"), upgrade
              in [UpgradeLow, UpgradeHigh] ("-U%d", RandomRing(High − Low + 1) when < 100) via attribute vt 0x14;
              key kind 6; tcm_ItemMake(iti) FUN_00595ba0 appends it (≤ 8, "Too many content")
    cell = first empty inventory cell (box 9, InventoryLocking::UnlockedInventoryIterator::uii_Home FUN_004879d0); none or tcm_PutInto == 0: return (nothing sent)
    Character DB ← 0x344D NC_ITEMDB_CREATEITEMLIST_REQ {      # PROTO_NC_ITEMDB_CREATEITEMLIST_REQ (pdb2016) matches
        header { u16 clienthandle = p.handle, u32 charNo }, u32 owner = charNo, u16 lockindex = L.index,
        u16 map = map id of p's map, u64 price = (priceLo, priceHi),
        itemlist (tcm_PutInto FUN_00595f50): u8 count, per item { u8 len, u16 inven, item data }: first = the chest
            in the free cell (0x2400 | slot), the others "inside the chest" (inven 0x2800) }
    L.vt[0x40](reserve the cell), L.vt[0x48](lock, priceLo) (money reservation), L.index++, p.vt[0xb40]()
    # the "Packet Too Long" log of this function names sp_KQReward (copied code); the answer 0x344E / 0x344F is Z05 §9.2
```

`tcm_ItemMake(ShineReward, clsmask)` FUN_00595d00 (KQ rewards): item from an item group (`igc_Getitem` `itemgroupclassifier` DAT_0d56c4a0 by
class mask), attribute from the reward row, random options (`rot_FillOption`) when ItemInfo names a RandomOption row.

### 10.11 Open points of this section

- `som_GetObject(handle)` alone decides "my mob still lives" in `mb_Routine`; whether a pool handle can be reused by
  another object before the 1-s regen tick sees the death (and so delay that breeder) depends on the pool's reuse
  order (not checked).
- `+0x60` (bandit) and the timestamps `+0x4c` / `+0x50` are not set by the breeder ctor or `mb_Set`; file breeders rely
  on the hatchery memory being zero *(inferred: no bandit groups appear in practice)*.
- The arguments 5, 12, 13 of `mh_MobBreed` and the `mbg_RegenLoc` out value are unused; the group key "Def" is stored
  but never compared.
- The 30-s event next to `EventMobRegen` (object 0x86fae8) is `eventheartping`, a no-op in 2016 (§28.4).

---

## 11. Drops: mob drop tables, drop items, loot rights, party/raid loot, the dice game

Mob death calls the drop roll from `ShineMob::so_KilledBy` (Z03 §8.1); this section covers everything after that call: the
drop tables, the roll, the `ShineDropItem` object (owner time, expiry, pickable bit), who may pick it up, the party / raid
distribution and the drop-item dice game. The pickup request itself (`0x3009 NC_ITEM_PICK_REQ` and `so_ply_PickupItem`)
is Z04 §3.3; `0x303C NC_ITEM_DICE_GAME_START_REQ` is Z04 §12.4; the DB side of picking is Z05.

### 11.1 Data files

| File | Loader | Held in | Use |
|---|---|---|---|
| `World/<server>/ItemDropTable.txt`, else `World/ItemDropTable.txt` (table `ItemGroup`) | `dic_Load` @ FUN_0048fa30 (part of `DropItemManager::dim_Load`) | `ItemDropFromMob::DropIndexCluster {OptionReader dic_Table, dic_DropItemBySpecies +0x10854}` *(pdb2016)*: `dic_DropItemBySpecies` → array indexed by mob ID of `DropItemListForSpecies {DropTable* dilfs_List[100]}` (0x190 each) | drop lists per mob |
| `World/<server>/ItemDropGroup.txt`, else `World/ItemDropGroup.txt` (table `ItemDropGroup`) | same function | map name → `DropItemListInGroup` (`dropgroupcluster DAT_0d55bc30`, sorted by the 20-byte name, lookup `std::map<ORToken, DropItemListInGroup>::find` FUN_0048e890) | items of a drop group |
| `BelongDice.shn` (one column `DiceTimeLimit`, 2016 value 15) | FUN_005b3150 → `ITableBase<BelongDice>::ms_pkTable DAT_132723c4` | first row, byte column | dice time in seconds (default 15) |
| `ItemDropLog.shn` (one column `ItemID`, 57 items) | `idb_Load` @ FUN_00649780 | `itemdatabox[id]` slot 6 (+0x18) | items whose drop is logged to GameLog (0x0798, D05) |
| `MobAbStateDropSetting.shn` | `lomscad_Load` @ FUN_005d5970 | §8.9 | selects the drop list by the mob's abstates |
| `ItemInfoServer.shn` columns `DropGroupA` +0x39, `DropGroupB` +0x61, `RandomOptionDropGroup` +0x89, `Vanish` +0xaa, `looting` +0xae (ms) | Z04 | `itemdatabox[id]` slot 1 | group membership, random options, drop timers |

Both text files are tried in the server's own sub-directory first (the `%s` is the 16-byte server name block passed to
the loader); a missing file in both places logs `DropItemManager::dim_Load : Error in …` and ends with the fatal path
`ShineExit` FUN_0063c7c0("…dic_Load") (the abort helper every loader uses).

**ItemGroup record** (0x61c bytes, column offsets from the file header, all read by the code at these offsets; row struct
`DropItemStruct::DropTable` *(pdb2016)*: `index {area, mobindex, minlev, maxlev, abstatecount}` +0, `cen {mincen, maxcen,
rate}` +0x47, `treasurebox` +0x53, `droptable[45]` (`Group {dropitemgroup, droprate, upgrademin, upgrademax, char droptype,
dropnumber}`) +0x9b, `exgroup {exclusive[5]}` +0x5b4, `dt_CheckSum` +0x618):

```pseudo
+0x000 MapArea  char[33]   breeder-group filter: "-" = any; else must equal the killing mob's breeder-group name (first 20 bytes)
+0x021 MobId    char[33]   mob InxName → mob ID (MobDataBox::mdb_2MobID FUN_00419080 on mobdatabox); unknown names are skipped silently
+0x042 MinLevel u16, +0x044 MaxLevel u16      only in the checksum
+0x046 AbStateCnt u8       slot 0..99 of the mob's 100 lists (chosen at drop time by sm_BossAbstateGet, §8.9)
+0x047 MinCen, +0x04b MaxCen, +0x04f CenRate u32   only in the checksum
+0x053 TradeBoxA/B/C name[20] + Rate u32 (×3)      not read
+0x09b 45 × DropEntry (0x1d bytes):
         +0x00 DrItem  name[20]   drop-group name ("-" = empty slot)
         +0x14 DrItemR u32        rate in millionths
         +0x18 UpGradeMin u8, +0x19 UpGradeMax u8
         +0x1a Rule    char       only 'r' entries are rolled ("R : ratio, M : Minute" says the header; 'M' has no code)
         +0x1b Num     u16 `dropnumber`: 0xFFFF (−1) unlimited; n > 0: decremented on each drop; 0: never drops
+0x5b4 ExcItem1..5 name[20]   not read
+0x618 CheckSum u32 = MinLevel + MaxLevel + AbStateCnt + MinCen + MaxCen + CenRate   (else "Checksum error in DropTable", fatal)
```

Load rules: a second record for the same (mob, AbStateCnt) is fatal ("AbstateNum is duplicate"), AbStateCnt > 99 is fatal
("AbstateNum is too big"). Every non-"-" DrItem name creates an empty group entry in `DAT_0d55bc30` (`ItemDropFromMob::DropGroupCluster::dgc_Append` FUN_0048f8e0).

**ItemDropGroup record** (`DropItemStruct::ItemGroup` 0x64 *(pdb2016)*): `+0x00 ItemGroupIdx name[20]` (`ig_itemgroupidx`),
`+0x14 ItemID char[40]` (`ig_itemid`), `+0x3c MinQtty u16` (`ig_quantitylow`), `+0x3e MaxQtty u16` (`ig_quantityhigh`),
`+0x40 Upgrade00..15 u16[16]` (`ig_upgraderate`), `+0x60 CheckSum` (`ig_CheckSum`) (= sum of the 18 words; else "Checksum error in ItemGroup at", fatal).
Rows whose group name was not referenced by ItemDropTable are ignored. For a referenced group, `ItemDropFromMob::DropItemListInGroup::dilig_StoreItem` FUN_0048e6b0 adds items:

```pseudo
dilig_AppendByName(group, ItemID, row):                    @ FUN_0048e6b0
    id = item with InxName == ItemID (ItemDataBox::idb_2itemid FUN_00418ff0)
    found: dilig_AppendItem(group, id, row)                @ FUN_0048e1d0
    else:  ItemID is a drop-group name: for every item whose ItemInfoServer.DropGroupA (+0x39) or DropGroupB (+0x61)
           equals it (20 bytes), dilig_AppendItem(group, item, row)
dilig_AppendItem: dilig_ItemList[n] (0x66 bytes at group+0x14) = { u16 itemid, itemgroup = copy of the row (DropItemStruct::ItemGroup::operator= FUN_0048dfd0) }; n (dilig_MaxItem +0x27ec) < 100,
                  else "dilig_AppendItem : Too many item" (fatal)
```

2016 data: 1485 ItemGroup records, all with MapArea "-" and AbStateCnt 0 (so only list 0 is used for normal mobs;
MobAbStateDropSetting mobs fall back to nothing when their count selects an empty list, §8.9), TradeBox/Cen/Exc unused,
Upgrade range 1–5 on 143 entries; Num 1 on 297 entries (all weapon-title licences, e.g. `TRUMPYLicence`).
ItemDropGroup: 970 rows / 959 groups, every row `Upgrade00 = 1000`, MinQtty 1, MaxQtty 1–10.

### 11.2 The drop roll

```pseudo
DropIndexCluster::dic_ItemDrop(cluster, killer, mobData, breeder, mob, looter, lotFactor):   @ FUN_0048f690 (thiscall)
    # called from ShineMob::so_KilledBy (Z03 §8.1) when mob.dropsEnabled (+0x250c, Lua cSetNPCIsItemDrop) == 1;
    # mobData = the row of mob+0x2558 (Lua cSetItemDropMobID, vt 0xbb4 ShineMob::so_mob_SetItemDropMobID FUN_004a9d20) if set, else the mob's own row
    if mobData null or mobId ≥ mob count or killer / mob null: return
    if killer.kind (vt 0x4d0) == 5 (a mob): return             # mobs killing mobs drop nothing
    name = "-";  if breeder: name = breeder.group.GroupIndex (MobRegenClass::MobBreeder::mb_RegenGroupIndex FUN_0048e040: *(breeder+0) + 0x1918)
    species = cluster+0x10854 [mobData.id] (0x190 bytes = 100 record pointers)
    dilfs_ItemDrop(species, name, killer, mob, looter, lotFactor)

DropItemListForSpecies::dilfs_ItemDrop(species, name, killer, mob, looter, lotFactor):        @ FUN_0048ef80
    bonus    = killer.vt[0x498]().+0x16 − 1000          # player: `ChargedEffectContainer` p+0x2a5a0, +0x16 `cec_ItemDropRate` ‰
                                                         # (1000 by default, template DAT_132728f8; ChargedEffect.shn
                                                         #  EffectEnum 16 "SNS_DropUp" 1100 *(inferred)*); mobs: 1000 → 0
    d = killer.level − mob.level (vt 0x4d8, u8)
    gate     = (d < 0 ? 1000 : (10 − d) × 100) + bonus   # killer ≥ 10 levels above the mob: gate ≤ 0, nothing drops
    mapRate  = mob has a field ? max(field.fm_FieldBonus.fb_DropRate (+0x50), 0) : 1000   # always 1000 in 2016 (below)
    if killer.vt[0x944]() == 1 (player: `ShinePlayer::so_ply_GetFromWhere` FUN_0043c9d0 = `sp_ConnectFrom` +0x2a7d4, set by WM
        0x082B NC_MISC_CONNECTFROMWHERE_ACK `connectfrom`): mapRate += 200   # *(inferred)* PC-room bonus (meaning of value 1)
    abRate   = Σ over killer's abstates of SubActor.vt[0x48](state)   # drop-up abstates (AbnormalStateContainer::AbstateElementInObject::aeo_GetActor FUN_00401240 → g_AbActiveInfo)
    list = species[ sm_BossAbstateGet(mob) ]  (§8.9; 0 for normal mobs);  null: return
    dilfs_Drop(list, name, killer, mob, looter, {bonus, gate, mapRate, abRate}, lotFactor)

dilfs_Drop(rec, name, …):                                   @ FUN_0048eb90
    if rec.MapArea ≠ "-" and rec.MapArea[0..19] ≠ name: return
    for i in 0..44: if rec.entry[i].DrItem ≠ "-" and Rule == 'r': dilfs_DropByRate(i, rec, …)

dilfs_DropByRate(i, rec, killer, mob, r, looter, lotFactor):   @ FUN_0048e920
    if not (int)rand(1000) < r.gate: return                  # one gate roll per entry (rr_ByLevel)
    if not (uint)rand(1000000) < (uint)((int)((r.abRate + r.mapRate + r.bonus) × DrItemR) / 1000): return
        # unsigned compare: a negative sum (an abstate actor's vt 0x48 below 0, or cec_ItemDropRate far below 1000)
        # becomes a huge bound and the entry always passes (original bug) Z09-B129 (latent: mapRate ≥ 1000 keeps the
        # sum ≥ 0 with the 2016 data)
    if Num == 0: return;  if Num ≠ −1: Num −= 1             # the count lives in the shared table record (original bug) Z09-B20
    group = DAT_0d55bc30[DrItem]; none: return
    dilig_Drop(group, killer, mob, looter, lotFactor, UpGradeMin, UpGradeMax)
```

So with neutral bonuses a list entry drops with probability `gate/1000 × DrItemR/1 000 000`; every entry is rolled
independently, so one kill can drop several items (up to 45).

```pseudo
DropItemListInGroup::dilig_Drop(group, killer, mob, looter, lotFactor, upMin, upMax):         @ FUN_0048e260
    if group.count (+0x27ec) == 0: return
    k = RandomRing(count) (uniform 0..count−1; 0 when count > 100);  id = entry[k].itemId
    item = { key = ItemTotalInformation::iti_mkregnum(id, 3, server ids) (FUN ItemTotalInformation::iti_mkregnum), id, attr zeroed }
    cls = ItemAttr class of id (g_ItemAttrCls)
    if !cls.vt[0x2c](&item, &entry[k].row, rand(1000), mob.mobId (vt 0x708)): return   # builds the attributes from the group
                                                         # row (MinQtty..MaxQtty, Upgrade00..15 weights) *(inferred)*
    if ItemInfo/ItemInfoServer missing: return
    if ItemInfoServer.RandomOptionDropGroup (+0x89) names a RandomOption table: rot_FillOption(cls.vt[0x70](&item), table)
    lot = cls.vt[0x1c](&item) × lotFactor;  capped at ItemInfo +0x6a (max lot);  cls.vt[0x20](&item, lot)
    up = random in [upMin, upMax] (RandomBox::rb_random FUN_0063ccf0), capped at ItemInfo +0xf0;  Item_ForcedUpgrade(&item, cls, up, &log)
    killer.vt[0x344]()  (result unused)
    ShineObject::so_IsDropping(mob, &item, 1, looter, killer.handle, killer.charNo, cls, 1)     # §11.3
```

`lotFactor` is the 4th argument of `so_KilledBy`: 1 on the combat paths (Z03 §7: `so_KilledBy(a, hp, hp, 1)`) and the
script kills seen (`…, 1000, 1)`); gathering (`sp_GatherComplete(p, how)` FUN_0046b2f0, Z02 §8) calls
`so_KilledBy(p, hp, 0, how')` (read from the disassembly: `GetHP` takes no argument) with `how'` = `how` for resources of
MobInfo.Type 8/9/10 and 1 otherwise. 0x2032 passes `how` = 2, so a gather the client completes drops **double lots**
(this answers the Z02 open point "gather loot"; the timer path `sp_Schedule_Gather` FUN_0046cb40 passes 1). The aggro share is 0 (aggroRate 0).
`sp_NC_ACT_GATHERCOMPLETE_REQ` FUN_0046cbf0 only clears the gather timer (`sp_TimerStr`) and calls `sp_GatherComplete(p, 2)`:
it never checks how long the gather has run, so a client that sends 0x2032 right after 0x202E gets the resource at once,
with lots × 2 for resource types 8/9/10 (original bug) Z09-B128. Whether the factor 2 for the client-side completion is
meant (the normal path: the client's `Gather.shn` time is shorter than the server's 4-s fallback timer) is not visible.

### 11.3 Creating the drop object

```pseudo
ShineObject::so_IsDropping(dropper, item, flag, looter, …):                                   @ FUN_004b0a20
    o = som_AllocObject(type 1 drop item); none: log "so_IsDropping : itembuf full"; return false
    r = o.so_ItemDrop(handle, dropper, item, flag, looter)   (vt 0x544; pushes 5 arguments, the callee takes 6)
    r ≠ 0x301: log "so_IsDropping : Drop mark fail"; return false       # the allocated object is not freed here
    dropitemanalyzer.dia_Set(DAT_0cf15b40, dropper.mobId, item.id)  @ FUN_00460670       # counts per (mob, item); no reader found
    if dropper.field: note field+0xc in the ring DAT_0085dfb0 (NameString::operator[] FUN_00418ec0; same ring as fm_Marking, §5.7)
    return true

ShineDropItem::so_ItemDrop(o, handle, dropper, item, flag, looter, questOnly):              @ FUN_0052a7a0 (vt 0x544)
    dropper has no field: log "Dropper have no map"; return 0x305
    ItemInfo missing:     log "No Item Data"; return 0x305
    ShineDropItem::sd_DiceGameBufferReset(o, 0)                                           # FUN_0052f020, §11.6
    o.looter (+0x208) = *looter (12 bytes, §11.4);  o.map key (+0x275) = dropper's field key; +0x289 = 0
    o.pos = dropper.pos (also +0x281 / +0x285);  o.item (+0x18d) = item (0x6f bytes: u64 key, u16 id +0x195, attr)
    o.flag (+0x204) = flag
    o.ownerUntil (+0x1fc) = g_Now + ItemInfoServer.looting (+0xae) / 100     # ms → tenths of a second (20 s in the data)
    o.vanishAt   (+0x200) = g_Now + ItemInfoServer.Vanish  (+0xaa) / 100     # 60 s in the data
    if so_MapMarking(o, 0) fails (no free spot): return 0x305
        # FUN_00466470 → fm_Marking(field, o, spacing 25, dropArg 0): spiral search from the dropper's position (§5.7)
    o.layer = dropper.layer;  o.vt[0xe20](questOnly) → +0x28a
    brief (0x1C0A, buffer +0x167, payload +0x189): { handle, itemid, x, y, dropmobhandle = dropper.handle, attr = 0 }
    sight broadcast: so_AllOfRange(o, …, so_drpitm_BriefInfo)        @ FUN_00567ff0
        for each player in range: o.so_drpitm_CanLootingBitSet(p) (vt 0x538 FUN_0052a420, attr bit 3 = CanLooting(p)); p ← brief
    if ItemDropLog has a row for the item (itemdatabox slot 6 first u32 == id):
        GameLog ← 0x0798 { u16 itemId, u16 lot, u64 key, u16 dropper.vt[0x344](), map key, x, y }  (0x22 bytes; D05)
    return 0x301
```

**questOnly (+0x28a)** is set to 1 only by `ShinePlayer::sp_QuestItemGet` FUN_00528240 (quest drops, Z15) and 0 by the
player's own drop (Z05 §3.1). `so_IsDropping` pushes only five arguments, so for every drop made through it (mob drops,
`sp_KQItemDrop`, Pine `ShineItemDrop`, Lua `cDropItem`) the sixth is the word on top of its frame, the security cookie
`DAT_00873bd8 ^ ebp`; the byte stored is its low byte (original bug) Z09-B21. R2 re-check against the PDB signature
`so_ItemDrop(u16 handle, ShineObject* dropper, ItemTotalInformation*, ulong DataBase, ShineMultiTypeHandle*, uchar quest)`:
the call at 0x4b0aea pushes five words, the callee reads the sixth at `[ebp+0x1c]` and returns with `ret 0x18`, so it also
pops one word too many (harmless: `so_IsDropping` restores `esp` from `ebp`). The PDB-typed decompile shows a literal `0`
for this argument, which is a Ghidra artefact. When that byte happens to be 1, the drop is
pickable only by players whose quest wants the item and ignores party loot rules (§11.4).

`0x1C0A NC_BRIEFINFO_DROPEDITEM_CMD` is the object's appear packet (Z02 §5 "+0x167"); newcomers get it through
`so_SendMyBriefInfo` FUN_00555280 (vt 0x4c8) with the attr byte last written for some other player
*(inferred: the bit is only rewritten by so_drpitm_BriefInfo, not by the sight-entry path)*. The client keeps the item
in `DropItemMgr` with `m_bPickable` from that bit *(pdb2017)*.

### 11.4 `ShineDropItem` object and loot rights

`ShineDropItem : ShineObject` is 0x28b bytes *(pdb2016)*; PDB member names in the second column.

| Offset | PDB member | Field |
|---|---|---|
| +0x167 | `sdi_ItemBriefInfo` (`BriefInformationDropItem` 0x26: `bidi_Pack`, `bidi_Array[18]`, `bidi_nc` +0x1e, `bidi_BriefInfo` +0x22) | brief packet 0x1C0A (header, length 0x11, built by `BriefInformationDropItem::BriefInformationDropItem` FUN_005492d0 in the ctor); +0x189 pointer to its payload (vt 0x4c4 `ShineDropItem::so_FillBriefInformation` FUN_00555250 copies it); +0x66 position pointer (= payload +4) |
| +0x18d | `sdi_ItemOnField` (`ItemTotalInformation`) | the item (u64 key, +0x195 u16 itemId, 0xFFFF = empty, +0x197 attr 0x65 bytes); vt 0x548 `ShineDropItem::so_drpitm_itemview` FUN_00555310 returns it, vt 0x54c / `so_RetrateFromMap` FUN_00495c40 / `ShineDropItem::so_itempicked` FUN_00555340 clear it |
| +0x1fc / +0x200 | `sdi_LootLostTick` / `sdi_EraseTime` | owner-only until / vanish at (tenths) |
| +0x204 | `sdi_DataBaseType` (`ShineObjectClass::DataBase`: `TOTAL_ITEM_STRUCT 0`, `ONLY_REGISTNUMBER 1`) | 1 from `so_IsDropping` (a new item: the DB only needs its number) / 0 player drop; not read by the code found |
| +0x208 | `sdi_LooterHandle` | looter `ShineMultiTypeHandle` (12 bytes, below) |
| +0x214 | `sdi_DicePick.DiceGameStart` (`TickTimer {m_CurDelayTime, m_DelayTime, bool m_bEnable +8, m_PrevCheckTime}`) | dice timer (active byte +0x21c = `m_bEnable`, vt 0xaa8 `ShineDropItem::so_IsDiceGamePlay` FUN_0052edb0 "dice running"); part 7 called it `PeriodTimer` |
| +0x224 | `sdi_DicePick.PickerNum` (u8) | number of dice slots in use |
| +0x225 | `sdi_DicePick.MemberInfos[20]` `{u16 Handle, u16 Result}` | 20 × { player handle (0xFFFF ends), roll (0 = not yet, 1..100, 0xFFFE = passed) } |
| +0x275 | `sdi_loginloc` (`PROTO_NC_CHAR_BASE_CMD::LoginLocation`) | field key (12 bytes; vt 0x4bc `ShineDropItem::so_LoginLocation` FUN_005552b0) |
| +0x28a | `sdi_bQuestDropItem` | questOnly (vt 0xe20 `ShineDropItem::so_drpitm_bQuestDropItem_Set` FUN_00555320 set / 0xe24 `ShineDropItem::so_drpitm_bQuestDropItem_Get` FUN_00555330 get) |

Destructor `ShineDropItem::vector deleting destructor` FUN_00555f10 (vt 4).

`ShineMultiTypeHandle` `{ HandleType m_type, u32 m_ShineHandle, u32 m_LooterCharRegNo }` *(pdb2016)*: `ALONE 0` one player
(id = charNo), `PARTY 1` (id = party number, +8 = the party's looter), `RAID 2` (id = raid number, +8 = raid looter),
`ALL 3` (id −1: anyone may pick it up). Init `ShineMultiTypeHandle::ShineMultiTypeHandle` FUN_004c1460 / clear `ShineMultiTypeHandle::SetEmptyHandle` FUN_004c1480 → {3, −1}; set `ShineMultiTypeHandle::SetShineObject` FUN_004c14a0 / `ShineMultiTypeHandle::SetShinePartyRegnum` FUN_004c14d0 / `ShineMultiTypeHandle::SetShineRaidRegnum` FUN_004c14f0; "nobody"
test `ShineMultiTypeHandle::IsEmptyHandle` FUN_004c1470 (id == −1); "one player" `ShineMultiTypeHandle::IsAloneType` FUN_004c1490 (vt 0x540 `so_drpitm_IsIndividualType` FUN_0052a630); looter charNo of a party / raid handle
`ShineMultiTypeHandle::GetLooterCharRegNo` FUN_004c1510 (−1 for other kinds).

```pseudo
HitMeList::EnemyList::el_FindLooter(list) → handle:                    @ FUN_004822f0
    e = the entry with the largest damage (+0x10; first one on ties; none → {3, −1})
    kind 2 raid:  {2, raidNo, raid looter (Raid::GetLooter FUN_0063d060)}      # raid not found: looter −1
    kind 1 party: {1, partyNo, party's looter (party slot +0xb8, FieldMap::fm_GetMapInfo FUN_0042ab10)}
    kind 0:       player = som_FindPlayer(e.charNo); found → {0, charNo}; gone → {3, −1} (free for all at once)

ShineMultiTypeHandle::IsCanItemPick(h, p, item, drop):                 @ FUN_004c15e0   (CanLooting, vt 0x53c @ ShineDropItem::so_drpitm_CanLooting FUN_0052a4e0)
    h.id == −1: true
    kind 2: p must be in raid h.id; rule = drop.questOnly ? 0 : CLooting rule of the raid for the item (CLooting::GetItemLootingTypeConVert FUN_00644f60);
            rule > 3: log "…Not Find Raid Loot Type", false;  rule 2 ("particular person"): p.charNo == h.looterCharNo; else true
    kind 1: same with p's party (party slot +0xb8); "…Not Find Party Loot Type"
            (a player no longer in the party / raid falls through to the next line)
    otherwise: h.id == p.charNo
so_drpitm_CanLooting(drop, p):  item ID valid in itemdatabox and IsCanItemPick(...) and (questOnly ≠ 1 or p.vt[0xe28](itemId))
                                # vt 0xe28 = CQuestZone::IsQuestDropItem on the player's quest diary (ShinePlayer::so_ply_QuestItemCheck FUN_00561790)

CLooting::GetItemLootingTypeConVert(rules[4], itemInfo):               @ FUN_00644f60
    ItemInfo.Type (+0x62) == ITEMTYPE_QUEST (3): LOOTING_TYPE_FREE (0)        # quest items are always free
    by ItemInfo.ItemGradeType (+0x76): GT_NORMAL → rules[0], GT_NAMED → rules[1], GT_RARE or GT_SET → rules[2],
                                       GT_UNIQUE → rules[3], GT_CHARGE → 0; other → log "…undefine GradeType", 0
    # rules = CLooting.m_ItemLootingType[4] (LOOTING_TYPE: FREE 0, ORDER 1, LOOTER 2, DICE 3) (pdb2016)
    # rules = PARTY_LOOT / RAID loot types from WM (W02 §1: 0 free for all, 1 alternating, 2 particular person, 3 dice)
```

The rule chosen here also drives the pickup handler (Z04 §3.3 rules 0–3).

```pseudo
ShineDropItem::so_Routine(o):                                           @ FUN_0056ad00 (vt 0x4ac)
    handle check (ShineDropItem::so_RemakeHandle FUN_005552c0: handle = 0x2904 + pool index, pool 10500..13499): mismatch → log, repair
    if o.item.id == 0xFFFF (taken):  DiceReset(o, 1); o.vt[0x33c](0, 1, 3); som_FreeObject(o, reason 0xd); relink; return
    if dice timer fires (TickTimer::CheckUpdateEvent): sd_DiceGameResult(o, 1)  (§11.6)
    if o.looter.id ≠ −1 and g_Now ≥ ownerUntil:  o.looter = {3, −1}; re-broadcast 0x1C0A with fresh pickable bits
    if g_Now > vanishAt:  DiceReset(o, 1); clear item; o.vt[0x33c](0, 1, 3); som_FreeObject(o, reason 0xe)
    slanted-list relink
```

`so_LogoutPacketBroadcast` FUN_00553b30 (vt 0x14): 0x1805 `{ u16 handle }` to the whole map
(`AxialListPacketBroadcast4ItemPickUp`); `so_scene_EraseItem` FUN_0050dc70 (vt 0x8b8, map scripts): clears the item if
its ID matches. `ShineObject::so_ItemDrop` FUN_0052a6f0 (base vt 0x544) only logs and returns 0x303.

### 11.5 Party / raid distribution (loot rule 1, and money)

```pseudo
ShinePlayer::sp_partyitemdistribute(p, drop, item, handle):                                   @ FUN_0052f630
    party = p's party; number ≥ 4000: log "Too large party handle"; return
    n = member count; n ∉ 2..5: log "Invalid party member number"; return
    near = members within 1000 units of p (DistanceSquare < 1000001); picker = the one with the oldest last pickup
           (vt 0x41c ShinePlayer::sp_lastpickuptime FUN_0055a090 = p+0x29334, set by so_ply_PickupItem; a member never picking has 0 → first)
    money item (g_MoneyItemID): share = max(amount / |near|, 1)
        for slot in 0..4: slot.vt[0x790](share)      # all 5 slots, no null check (original bug) Z09-B22:
            # far / absent members' slots hold 0 (set at 0x52f71e), slots n..4 are never written (stack garbage);
            # the call reads slot->vtable → access violation → MiniDumper ends the zone (§30.1)
        drop.vt[0x54c]()  (removed)
    else: picker null: log "Null picker"
          picker ≠ p: p ← 0x301B NC_ITEM_PICKOTHER_ACK { u16 itemid, u16 towho = picker.handle }   # no client handler (C01)
          picker.so_ply_PickupItem(drop, item, handle)  (vt 0x798, Z04 §3.3)

ShinePlayer::sp_RaidItemsidtribute(p, drop):                                                  @ FUN_0052f8a0
    near = raid members within 1000 units (RaidTask::rt_GetNearRaidPlayer FUN_005ce6d0 → RaidTask::_GetRaidPlayer FUN_005ce000(list, raidNo, p, 1000), max 20)
    money: share = amount / |near|; the remainder is given 1 each to the first members; drop removed
    else: picker = oldest last pickup among near; 0x301B to p if someone else; picker.so_ply_PickupItem(drop, item, handle)
```

Callers (`sp_NC_ITEM_PICK_REQ` FUN_00530a50, Z04 §3.3): in a party, money goes to `sp_partyitemdistribute` under the
loot rules LOOTER, ORDER and DICE (the DICE case falls through to ORDER for money); FREE pays the picker
(`so_ply_PickupItem`, vt 0x798). With B22 the money branch survives only with 5 members all within 1000 units; then
each member gets at least 1 coin even when the amount is smaller than the member count (original bug) Z09-B23; the raid
version splits exactly.

### 11.6 Dice game on a drop (loot rule 3)

Entry from the pickup handler (Z04 §3.3, rule 3, `ShinePlayer::sp_DicePicking` FUN_0052ec70):

```pseudo
ShinePlayer::sp_DicePicking(p, drop):                                     @ FUN_0052ec70
    item = drop.vt[0x548](); none: p.so_ply_itempickresult(0x343)
    p's party / raid already runs a dice game (party slot +0xcc CParty::IsItemDiceGameIng FUN_006452d0, raid slot +0xcc Raid::IsItemDiceGameIng FUN_0063d4a0): result 0x34d
        "You cannot acquire other items while rolling the dice."
    drop is owned by one player (vt 0x540): normal pickup (vt 0x798)
    drop.so_DiceItemPickInit(p) (vt 0xaa0) == 1: result 0x34e ("The game continues with dice acquisition." *(inferred
        from the client text list of 0x300A)*)
    else: false → the caller answers 0x2003 (Z04 §3.3)

ShineDropItem::so_DiceItemPickInit(drop, p):                 @ FUN_00531020 (vt 0xaa0)
    raid: players = raid members within 1000 units (FUN_005ce6d0); need ≥ 2; raid dice flag = 1 (Raid::SetItemDiceGameMode FUN_0063d470)
    party: number < 4000 ("Too large party handle"), member count 2..5 ("Invalid party member number");
           players = members within 1000 units (DistanceSquare < 1000001); need ≥ 2; party dice flag = 1 (CParty::SetItemDiceGameMode FUN_00645300)
    no party / raid: players = none (the game starts with nobody; it ends on the timer with 0x2009)
    start: dice timer active, period = DiceTimeLimit × 10 tenths (BelongDice.shn, 15 s; 15 when the table is empty)
           participants (+0x225) = players (max 20, list RaidTask::NearRaidPlayers::Clear FUN_005cd530 / RaidTask::NearRaidPlayers::Add FUN_005cd580), rolls 0
           each player ← 0x303B NC_ITEM_DICE_GAME_CMD { u16 itemhandle = drop.handle, s32 nGameTimesec = DiceTimeLimit }
    return true

0x303C handler (Z04 §12.4) → ShineDropItem::so_DiceItemStart(drop, p, isYes, &err):  @ FUN_00531690 (vt 0xaa4)
    err = 0x2000;  p is not a ShinePlayer (RTTI check): err 0x2002 "This character cannot roll the dice."
    p not among the participants: err 0x2003 "You are not authorized to roll the dice."
    already decided: err 0x2005 "The dice are already rolling."
    roll = isYes ? sd_GetPlayerDiceGameResult(drop) : 0xFFFE
           # FUN_0052edc0: rand(1000) % 100 + 1, retried up to 30 times until no participant has it, else the first
           # free value 1..99 (log "sd_GetPlayerDiceGameResult" and 0 if none)
    sd_DiceMyGameResultBroadCast(drop, p.handle, roll)        @ FUN_00531310
        every participant on the same field as p who is still in the drop's party / raid (ShineMultiTypeHandle::IsCanItemPickForPartyRaid FUN_004c1530)
        ← 0x303E NC_ITEM_DICE_GAME_START_CMD { u16 charhandle, s32 diceresult }
    sd_DiceGameResult(drop, 0)

sd_DiceGameResult(drop, timeout):                            @ FUN_00531470
    repeat (at most 20 rounds; then log "ShineDropItem::sd_DiceGameResult" and stop):
        for each participant: no longer in the party / raid → roll = 0xFFFE
            timeout and roll 0 → roll = 0xFFFE, broadcast 0x303E { handle, 0xFFFE }
            not timeout and roll 0 → return (still waiting)
        best = highest roll ≠ 0xFFFE (first on ties; rolls are distinct)
        none: sd_DiceGameSendMsgResult(0x2009, name "", 0, 0); DiceReset(drop, 1); return
              # client 0x2009 "Everyone has decided to give up the chance to roll the dice."
        w = the winner object; w and drop on the same field (field +0x10 id):
            if !w.so_ply_PickupItem(...) (vt 0x798 fails, e.g. inventory full):
                drop.looter = {0, w.charNo}; sd_DropTimeReStart (FUN_0052ef50: owner/vanish timers restart from now);
                re-broadcast 0x1C0A
            sd_DiceGameSendMsgResult(0x2008, w.name (vt 0x56c), roll, …); DiceReset(drop, 1); return
        else: that roll = 0xFFFE, next round

sd_DiceGameSendMsgResult(drop, code, name, roll):            @ FUN_0052ee60
    every participant still in the party / raid ← 0x303F NC_ITEM_DICE_GAME_RESULT_CMD
        { u16 error = code, char WinnerID[20], s32 diceresult, u16 PickItemID = drop.item.id }
    # client: 0x2008 → "%s acquired the %s item by rolling %d with the dice." when PickItemID is a known item;
    #         other codes → the error text

ShineDropItem::sd_DiceGameBufferReset(drop, clearFlag):                                  @ FUN_0052f020
    dice timer off; for the first participant still found: if clearFlag, clear the dice flag of its raid (FUN_0063d470) or
    party (FUN_00645300); every slot = { 0xFFFF, 0 }
```

Client (2016): `0x303B` opens `RollingDiceWin` with the item and the time (FUN_0049c530); `0x303E` prints "%s rolled the dice
and the result was %d." or "%s decided to give up the chance to roll the dice." for 0xFFFE (FUN_004b26c0); `0x303D` prints
the error text unless 0x2000 (FUN_0049c570).

Notes: if the winner's pickup succeeds, the item leaves the drop only after the DB answer (Z05), so `PickItemID` is still
the item ID when 0x303F is built *(inferred)*. A successful pickup does not touch the dice flag; it is cleared by
`DiceReset(…, 1)`, which looks only at the first participant still found, so a party whose first participants all left
keeps the flag set until another drop resets it (only possible through that same path) *(inferred)*.

### 11.7 `DropLocationManager` (spiral placement)

`DropLocationManager` (0x188 *(pdb2016)*: `dlm_array[32]` of `DropLoc::SameDistanceCluster {sdc_Number, sdc_Store, LocationDelta*
sdc_Array}`, cursor `dlm_index {cluster, subscript}` +0x180). `dlm_Load` FUN_00460980 builds the 32 rings of offsets (count,
capacity, points):
ring 0 is the single point (0, 0); odd ring r gets 6 points from `sdc_Setsixpoint(ring, (r+1)/2 × 1024, 0)` FUN_004607f0, even ring r
gets `r/2 × 6` points from `r/2` calls `sdc_Setsixpoint(ring, x, (r/2+1) × 0x4400 / 20)` with x stepping by 1024
(not opened: the rings form widening bands around the centre *(inferred)*; overflow log
"DropLoc::SameDistanceCluster::sdc_Setdelta : Buffer overflow", a log text that keeps an older name).
`dlm_home(start)` FUN_00460bb0 sets ring = start, index 0; `dlm_next` FUN_00460c20 moves to the next point and, when a ring
is exhausted, shuffles one random point of the next ring to the front (`RandomBox::operator[]` FUN_00427c30 on the random ring); false after ring
31. `sdc_Getdelta` FUN_00460910 scales the offset by `spacing / 1024`. `fm_Marking` (§5.7) is the only user, with
`start = 0` for drops (so the first candidate is the dropper's own spot) and spacing 25.

### 11.8 Other drop entry points (owned elsewhere)

| Entry | Owner | Note |
|---|---|---|
| `ShinePlayer::sp_QuestItemGet` FUN_00528240 | Z15 | quest drop, looter = the player, questOnly 1 |
| `ShinePlayer::sp_KQItemDrop` FUN_00496f00 | Z16 | KQ reward drop through `so_IsDropping` |
| Pine `ShineItemDrop::sa_Step` FUN_004eff00 | §24.1 | killer-only looter, no lot factor; failed roll retries (B102) |
| Lua `cDropItem` FUN_005d9a30 | part 13 | |
| Lua `cSetItemDropMobID(handle, mobName)` FUN_005ebea0 | here | mob+0x2558 = mob ID of `mobName` (0xFFFF if unknown), so the mob drops another mob's table; handle −1 pushes false |
| Lua `cSetNPCIsItemDrop(handle, 0/1)` FUN_005daf40 | here | vt 0xbb0 → +0x250c; other values: nothing, returns 0 |
| GM `&mobbreed … ItemDropMobIndex …`, `ac_MobItemDrop` | Z11 | |
| Player drop `0x3007` → DB `0x3417` | Z04 §3.1 / Z05 §3.1 | same `so_ItemDrop` with questOnly 0 |

### 11.9 Open points of this section

- **Settled in R2:** `field+0x4c` is `FieldMap::fm_FieldBonus` (`FieldBonus {int fb_Experience, int fb_DropRate}`
  *(pdb2016)*); the drop roll reads `fb_DropRate` (+0x50). The only writers are `FieldMap::fm_Init` FUN_00464bc0 (both = 1000)
  and the copy `FieldMap::operator=` FUN_00467580, so the map drop rate (and the map EXP bonus) is a constant ×1 in 2016:
  an unused hook.
- `ItemAttr` class vt 0x2c (how MinQtty/MaxQtty and the `Upgrade00..15` weights become the item's lot and upgrade) was not
  read; the per-class functions are Z04's item model.
- **Settled in part 8a:** vt 0x33c(0, 1, 3) on removal is `ShineObject::so_Unmark(REMOVE_NOW, 1, 3)` FUN_00553970 →
  `so_BroadcastLogout` → `so_Logout` → vt 0x14, for drop items `ShineDropItem::so_LogoutPacketBroadcast` FUN_00553b30
  (0x1805 to the whole map, §11.4), then the object leaves the coordinate lists (§12.4 has the full chain).
- `dropitemanalyzer` (DAT_0cf15b40, 256 buckets × 500 `{mobId, itemId, count}`) has no reader in the zone.
- `+0x204` (flag 1 from `so_IsDropping`) is never read by the drop functions found.

---

## 12. Other world objects 1: magic fields and axial flags

Part 8a. Two object classes without a mover: `ShineMagicField` (object kind 6, pool 20388–20637 = 250 objects, handle
= 0x4FA4 + pool index, `ShineMagicField::so_RemakeHandle` FUN_00555ca0 / `ShineObjectHandleUnion::sohu_SetMagicFieldHandle`
FUN_00548f80) are the ground areas left by "field" skills (Frost Nova, Inferno, God's Benevolence, boss breaths), and
`ShineAxialFlag` (kind 0, pool 13500–17083, handle 0x34BC + index, `ShineAxialFlag::so_RemakeHandle` FUN_005562c0)
are the invisible anchor objects of each map's coordinate lists (§9.6). All names *(pdb2016)*.

### 12.1 `ShineMagicField` members (0x1c8 bytes)

`ShineMagicField::ShineMagicField` FUN_0055afd0 / `~ShineMagicField` FUN_00555c20 (`vector_deleting_destructor` FUN_00556090):

| Offset | Member | Meaning |
|---|---|---|
| +0x000 | `ShineObject` | base (handle +4, `so_LocateInfo` +0x66 {location*, direct*}, layer +0x6e, `so_Field` +0x7a) |
| +0x167 | `smfm_MagicFieldBriefInfo` (`BriefInformationMagicField`, 0x27) | ready packet 0x1C0C: `ProtocolPacket bimfm_Pack` +0, buffer `bimfm_Array[19]` +0xc (2-byte opcode + 16-byte body), `bimfm_nc` +0x1f, `bimfm_BriefInfo` +0x23 → the body. Built by `BriefInformationMagicField::BriefInformationMagicField` FUN_00549330 (length 0x12, opcode 0x1C0C) |
| +0x190 | `smfm_VanishTick` | `g_Now` at which the field disappears |
| +0x194 | `smfm_Cener` (sic) | centre (x, y) |
| +0x19c | `smfm_Tick` (`Metronome {m_NextTick, m_TickInterval}`) | effect tick |
| +0x1a4 | `smfm_Empower` (`SKILL_EMPOWER`, 2 bytes: 4-bit damage / sp / keeptime / cooltime) | the caster's skill empowerment |
| +0x1a8 | `smfm_CasterInform` (`MagicFieldOwnerInform`, 0x14) | `mfoi_Object` +0 caster, `mfoi_Regnum` +4 its `so_GetCharRegistNumber` (vt 0x344), `mfoi_CharClass` +8 (class, vt 0x49c → vt 0x38), `mfoi_CastCoord` +9 the caster's position at the spread |
| +0x1bc | `smfm_skillindex` | `SkillDataBox::SkillDataIndex*` of the field skill |
| +0x1c0 | `smfm_MagicFieldType` | 1 = damage field (`…MagicFieldSpread`), 2 = heal field (`…_Friend`) |
| +0x1c1 | `smfm_RsDirect` | caster direction at the spread (rotation start) |
| +0x1c4 | `smfm_RsTick` | rotation start = spread time + `MAGICFIELD_DELAY_START_TIME` |

The constructor points `so_LocateInfo.location` at `bimfm_BriefInfo->location` (the packet body is the position storage)
and `so_LocateInfo.direct` at `ShineObject::so_TempLocation.dir` (DAT_132729c0), a static byte shared by every magic field
(always 0). Overridden virtual slots: 0x4a4 `so_RemakeHandle`, 0x4ac `so_Routine`, 0x4c8 `so_SendMyBriefInfo` (folded body
of `ShineDropItem::so_SendMyBriefInfo` FUN_00555280: sends the packet at +0x167, the same offset in both classes), 0x4d0
`so_ObjectType` FUN_00555c90 = 6, 0x8 `so_BriefInfoRange` = 2 (`BIR_SIGHT`, folded FUN_00647230), 0x7d8 / 0x7dc the two
spread functions, 0xb98 `so_mgcfld_FirstTickDelay`. The base versions are no-ops: `ShineObject::so_mgcfld_MagicFieldSpread`
FUN_004879b0 (also slot 0x7dc of all other classes), `ShineObject::so_mgcfld_FirstTickDelay` FUN_00552ec0.

**Skill data.** The field parameters are decoded `SkillSpecial` entries of the skill (`ActiveSkill.shn`
`SpecialIndexA…E` / `SpecialValueA…E`, decoded into `SkillDataIndex` `EnumStruct {exist, value}` members, Z03 §5.1),
values in milliseconds (the code converts `value × 10 / 1000` to `g_Now` tenths):

| `SkillSpecial` | Member | Use |
|---|---|---|
| 13 `SS_MAGICFIELD_TICK` | `sdi_MAGICFIELD_TICK` +0x108 | tick interval; a field without it never ticks (shown only) |
| 14 `SS_MAGICFIELD_KEEP` | `sdi_MAGICFIELD_KEEP` +0x110 | lifetime of a **damage** field (and its presence selects slot 0x7d8) |
| 49 `SS_MAGICFIELDPARTY` | `sdi_MAGICFIELD_PARTY` +0x1b8 | lifetime of a **heal** field (slot 0x7dc) |
| 64 `SS_MAGICFIELD_DELAY_START_TIME` | `sdi_MAGICFIELD_DELAY_START_TIME` +0x230 | delay before the first tick and the rotation start |
| 66 `SS_BMP_MAGICFIELD_ROTATIONSPEED_RIGHT` | `sdi_BMP_MAGICFIELD_ROTATIONSPEED_RIGHT` +0x238 | the area bitmap turns clockwise *(inferred from "RIGHT")* |
| 1 `SS_HEALAMOUNT` | `sdi_HEALAMOUNT` +0x78 | heal per tick (heal field) |
| 51 `SS_SETABSTATEFRIEND` | `sdi_SETABSTATEFRIEND` +0x1c8 | abstate ID put on every healed target |

In the 2016 `ActiveSkill.shn`: damage fields `FrostNova01…20`, `Inferno…`, `ThunderBolt…`, the `*FlowerWide` traps
(tick 3 s, keep 12 s), boss skills (`Chimera_Skill_W…`, `Eglack…`, `DNepilim_Skill_W`, `WarH_SFocalor…` with a 3-s
delay, `WarH_FAvanas…` with rotation, `ArenaCrystal_Skill01_W`); heal field `CrossDrop01…03` "God's Benevolence"
(party 15 s, tick 1 s, `HEALAMOUNT` 240 / 252 / 267, `SETABSTATEFRIEND` 8964). `DT_Airi_FrostNova01_W` /
`DT_Airi_Inferno01_W` have `KEEP` but no `TICK`: they only show. The field radius is `ActiveSkill.Area / 2`.

### 12.2 Who creates a field

```pseudo
(1) skill cast completion, in ShineMobileObject::so_Routine                               @ FUN_0056a080 (Z03 §5)
    after the cast checks (target state vt 0x7e4, use check vt 0xedc, IsNoAttack / silence) and the aggro rate block:
    if skill.EffectType is SE_TELEPORT or SE_VOLLEY: their own paths
    elif skill has MAGICFIELD_KEEP or MAGICFIELD_PARTY: smo_MagicFieldSpread(o, skill)

ShineMobileObject::smo_MagicFieldSpread(o, skill)                                         @ FUN_0057c880
    s = o.smo_SkillCast.scs_ProduceSkill.sklidx
    if s.SETABSTATEME: o.vt[0x648](&s.SETABSTATEME, &s.ABKEEPTIME)                         # abstate on the caster
    if s.NOTTARGET:    o.vt[0x648](&s.NOTTARGET, &s.ABKEEPTIME); o.vt[0x64c]()
    if skill == null: assert "…smo_MagicFieldSpread : SkillDataIndex NULL"; return
    if skill.MAGICFIELD_KEEP: f = som_AllocObject(kind 6)  (none: assert "… : Too many FieldObject")
        f.so_mgcfld_MagicFieldSpread (vt 0x7d8)(f.handle, o, s, &cast.scs_BattleSkill.locate, &cast.scs_Empower)
    if skill.MAGICFIELD_PARTY: f = som_AllocObject(kind 6) …
        f.so_mgcfld_MagicFieldSpread_Friend (vt 0x7dc)(same arguments)                    # a skill with both makes two fields
    SkillResultBuffer.bufferpoint = 0; smo_SkillResultPacket(o, s, &locate); o.smo_Flag.InSkillShift = 0
    to sight (incl. o): 0x2457 NC_BAT_SKILLBASH_HIT_BLAST_CMD { u16 index = o.smo_SkillIndexLastCasting,
                                                               u16 caster = o.handle, u16 skill = cast.scs_Skill }   (Z03 §5)
    skilleffectapplyer.sbec_Store(index, s, o, target = null, &locate, −1, o.vt[0xefc](), 0, 1)

(2) abstate actor "MagicField"                                                             @ FUN_00408d80
AbnormalStateContainer::SubAbnormalStateActorMagicField::sasa_Routine(actor, elem, victim, index)
    (sasa_IndexString FUN_00401760 = "MagicField"; the actor of the SubAbState kinds listed in Z03 §6.1)
    if elem.strength row has effect SAA_SETACTIVESKILL:
        skill = skilldatabox[that effect's value];  f = som_AllocObject(kind 6);  either missing: return 0
        caster = aeo_GetCaster(elem);  none: som_FreeObject(f, REMOVE_NOW, 4); return 0
        if skill.MAGICFIELD_KEEP:    f.vt[0x7d8](f.handle, caster, skill, victim.position, &empower 0)
        elif skill.MAGICFIELD_PARTY: f.vt[0x7dc](…same…)
        else: som_FreeObject(f, REMOVE_NOW, 4); return 0
    return SubAbnormalStateActor::sasa_Routine(actor, elem, victim, index)       @ FUN_00406d50 (Z03 §6)
    # a field appears at the victim's feet each time the abstate's routine runs (rate: Z03 §6)

(3) Lua cMagicFieldSpread(casterHandle, x, y, dir, skillName, firstTickDelay)               @ FUN_005f17c0
    caster = som_GetObject(arg1) (none: return 0 values)
    skill = skilldatabox[skillnametree[arg5]] (unknown: return 0); f = som_AllocObject(kind 6) (none: return 0)
    f.vt[0x7d8](f.handle, caster, skill, &(x, y), &empower 0)       # always the damage slot, even for a heal skill
    if arg6 == 1: f.so_mgcfld_FirstTickDelay (vt 0xb98)            # first tick one interval later
    push f.handle; return 1                                          # arg4 is read and ignored
```

Scripts: `AIScript/Chimera.lua` (`cMagicFieldSpread(ChimeraHandle, …MagicFieldLocX, …LocY, 0, …MagicFieldSkill, 1)`),
`KQ/KDArena/Functions/Routine.lua` (arena crystal, last argument 0). FiestaHeroes lists the function without arguments
*(fh-doc)*.

### 12.3 Spreading: `so_mgcfld_MagicFieldSpread` (damage) and `…_Friend` (heal)

```pseudo
ShineMagicField::so_mgcfld_MagicFieldSpread(f, handle, caster, s, xy, empower)              @ FUN_0057ea30
    if caster == null or s == null: return                             # the object stays allocated and unplaced
    start = g_Now − TICK×10/1000
    f.smfm_skillindex = s;  f.smfm_VanishTick = g_Now + KEEP×10/1000
    if caster.so_GetItemActionObserves (vt 0x5d0, players only) and s has ActiveSkillGroups:
        if EventRunBySkillGroupIndex(results, s, kind 2 (keep time), caster, caster):
            VanishTick += (GetRateAppliValue(results, KEEP) − KEEP)×10/1000     # item-action bonus on the duration (Z04/Z06)
    if s.MAGICFIELD_DELAY_START_TIME: start += DELAY×10/1000
    f.smfm_Tick = { m_TickInterval = TICK×10/1000, m_NextTick = start + interval }   # = g_Now (+ delay): first tick at once
    f.so_Field = caster.so_Field;  f.position = xy
    if fm_Marking(f.so_Field, f, 0, 0, 1) ≠ FM_MARKSUCCESS:                            # §5.7
        assert "…so_mgcfld_MagicFieldSpread : Mark err"; som_FreeObject(f, REMOVE_NOW, 4); return
    f.layer = caster.layer (8 bytes at *(+0x76));  f.smfm_Cener = xy;  f.smfm_Empower = *empower
    f.smfm_CasterInform = { caster, caster.so_GetCharRegistNumber(), caster class, caster position }
    f.smfm_MagicFieldType = 1
    f.smfm_RsTick = g_Now + DELAY×10/1000;  f.smfm_RsDirect = caster direction
    so_SetLayerRegNum(f, so_GetLayerRegNum(caster))
    packet 0x1C0C body = { handle, caster = caster.handle, skillid = s.sdi_Activ.ID, location = xy,
                           radious = s.sdi_Activ.Area / 2 }
    so_AllOfRange(f, f.position, range 0 = sight, so_ExchageBriefInfo)        # tells everyone in sight (§12.6)
    so_AllOfRange(f, f.smfm_Cener, Area/2, includeSelf 1, AxialListMagicFieldAggro{f, &f.smfm_CasterInform})
    almfa_AppendAggro                                                          # §12.5

ShineMagicField::so_mgcfld_MagicFieldSpread_Friend(f, …)                                  @ FUN_0057ee80
    caster == null: assert "…_Friend : Caster NULL"; s == null: assert "…_Friend : SkillDataIndex NULL"; return
    f.smfm_VanishTick = g_Now + MAGICFIELD_PARTY×10/1000
    item-action bonus: VanishTick += (GetRateAppliValue(results, KEEP) − KEEP)×10/1000
        # (original bug) Z09-B28: the heal field's lifetime is PARTY, but the bonus is computed on KEEP
        # (0 for heal skills such as CrossDrop), so a duration bonus never lengthens a heal field
    same tick / delay / marking / owner / rotation / packet setup (Mark err message is the damage one's),
    smfm_MagicFieldType = 2, smfm_skillindex set only after a successful marking
    so_AllOfRange(f, sight, so_ExchageBriefInfo)                               # no aggro pass
```

### 12.4 The field tick: `ShineMagicField::so_Routine` (vt 0x4ac)

```pseudo
ShineMagicField::so_Routine(f, list, index)                                                @ FUN_0056d7e0
    f.vt[0x4a4](index)                                     # so_RemakeHandle; result unused
    if g_Now < f.smfm_VanishTick:
        if f.smfm_Tick.m_NextTick < g_Now:
            m_NextTick += m_TickInterval                   # from the old value: a late field catches up one tick per routine
            if f.smfm_skillindex == null: return 0
            if skill has MAGICFIELD_TICK and f.smfm_CasterInform.mfoi_Object ≠ null:
                type 1: smfm_MagicFieldDamage(f);  type 2: smfm_MagicFieldHeal(f)
    else:
        f.so_Unmark (vt 0x33c)(REMOVE_NOW, broadcast 1, 3)  → ShineObject::so_Unmark FUN_00553970:
            vt 0x310 (no-op here); so_BroadcastLogout (vt 0x51c, FUN_0054f290) → so_Logout FUN_0054b780:
                if f is linked in the coordinate lists: close a booth with its handle (never for fields);
                so_LogoutPacketBroadcast (vt 0x14, FUN_00553a40): to sight 0x1805 { u16 handle } (Z01 §3.2)
            remove f from both coordinate lists; so_bIsMapMarking = 0
        som_FreeObject(f.handle, REMOVE_NOW, reason 0xf)
    return 1

ShineMagicField::so_mgcfld_FirstTickDelay(f)   (vt 0xb98)       @ FUN_00552f00
    f.smfm_Tick.m_NextTick = g_Now + m_TickInterval
```

The caster pointer is re-validated at every tick (below): when the caster logged out, died and was freed, or its pool slot
holds another object (`so_IsEmpty` vt 0x300, or `so_GetCharRegistNumber` ≠ `mfoi_Regnum`), `mfoi_Object` is cleared and
the field does nothing for the rest of its life (it still shows until `VanishTick`).

### 12.5 Damage, heal and aggro

```pseudo
ShineMagicField::smfm_MagicFieldDamage(f)                                                  @ FUN_00568810
    c = f.smfm_CasterInform.mfoi_Object
    if c and (c.so_IsEmpty() or c.so_GetCharRegistNumber() ≠ mfoi_Regnum): mfoi_Object = null
    if mfoi_Object == null: return
    scan = AxialListMagicFieldDamage { almfd_Owner = &f.smfm_CasterInform,
            almfd_BattleField = map.fm_PKField, slmfd_GuildWarMap = map.fm_FieldOption.attack.EnemyGuild,   # both never read
            slmfd_FieldCenter = f.position }
    if s.sdi_Area is empty (no area bitmap):
        allas_Init(scan) FUN_004c19f0 (allas_pArea = null: plain near scan);  centre = f.smfm_Cener, range = Area/2
    else:
        if s.BMP_MAGICFIELD_ROTATIONSPEED_RIGHT:
            d = smfm_GetRotationDirect(f);  to = f.position + 50·(sin d, cos d)    (sr_sin1024 / sr_cos1024)
            allas_Init(scan, s.sdi_Area[0], from = f.position, to, d)
        else:
            allas_Init(scan, s.sdi_Area[0], from = mfoi_CastCoord, to = f.smfm_Cener, dir = *f.direct (always 0))
        centre = allas_GetEffectCoord(scan), range = sdi_Area[0].AreaSize (+0x34)
    so_AllOfRange(f, centre, range, scan, includeSelf 1)
    almfd_ApplyDamage(scan, s, &f.smfm_Empower, f)
    if mfoi_Object: c.so_mob_SkillParameterSet_WeaponIndex (vt 0xc40)(c.so_mob_CurSelectWeapon (vt 0x740)())
        # mobs: restore the stat matrix of the current weapon after the field skill's (§8.1); players: no-op

ShineMagicField::smfm_GetRotationDirect(f)                                                 @ FUN_00579a50
    Δ = g_Now − f.smfm_RsTick
    return u8( f.smfm_RsDirect + (ROTATIONSPEED × Δ / 10) / 2 )      # direction byte in 2° units: speed in °/s *(inferred)*

AxialListMagicFieldDamage::alns_ValidObject(scan, t)       (scan filter; class AxialListLimitAreaScan → NearScan)   @ FUN_005680c0
    require t.so_GetHP() ≠ 0, t.so_Field, owner c ≠ null, t ≠ c
    (mdb_CanIKill(t.mobId, c is a mob ? MKID_MOB : MKID_USER) is computed and not used here)
    if c and t are players: c.so_mobile_ICanDamageTo(t, "…alns_ValidObject") — result unused
    require c.so_mobile_ICanDamageTo(t, "…alns_ValidObject2")            (vt 0x980, §8.4 / Z03)
    require not c.so_IsAlliance(t)                                       (vt 0xe60)
    if c.so_mobile_GetGuildRegnum() (vt 0x828) ≠ 0: require t's guild ≠ c's guild

AxialListMagicFieldDamage::almfd_ApplyDamage(scan, s, empower, f)                         @ FUN_005682c0
    ctx = EngageArgument { att = c, def, sklinfo = s, empower, attackloc = f.position, damagerate 1000, crirateadd 0,
                           pMultiHitArg null, nBMPDamageRate 1000 }
    for i, t in scan.alns_buffer[0 .. alns_bp):                         # entries {member, distancesquar}
        if t == null: stop
        if not mdb_CanIKill(t.so_mob_MobID(), c is a mob ? MKID_MOB : MKID_USER): stop
        if so_FindBlockLocate(f, t.position, 10000, mbi_IsAttackBlock) moves the point (an attack block between): stop
            # (original bug) Z09-B26: "stop" leaves the whole loop: every target after the first unkillable one or the
            # first one behind a wall gets no damage and no abstate this tick (checked in the disassembly: both
            # branches jump to the function exit 0x5685ee)
        c.so_mob_SkillParameterSet (vt 0xb90)(s.ID)                     # mobs: stats of the MobWeapon row (§8.1)
        if s.sdi_DamageRule.roe_IsDamageSkill (vt 0x20, FUN_004ff840 = ActiveSkillInfoServer.UsualAttack) == 1:
            ctx.def = t; ctx.nBMPDamageRate = scan.alns_GetBMPDamageRate(i)          # area bitmap cell × 10, else 1000
            dmg = s.sdi_DamageRule.roe_CalcDamage (vt 0x1c, FUN_00505c00, Z03 §4.5)(ctx)
            t.so_mobile_DamageOverTime (vt 0x730, FUN_00409cd0)(c, dmg, MAX_ABSTATEINDEX 0x318, 1, 0)
                # Z03 §6: abstate hooks, HP loss/kill, to sight 0x243C NC_BAT_DOTDAMAGE_CMD with abstate 0xFFFF
        if s.sdi_Activ.Last ∈ {TARGET_ENEMY 0, TARGET_ALL 5, TARGET_ENEMYUSER 7}:
            for each of the skill's 4 abstate slots (sdi_Abstate[k] {abstateidx, strength, rate}):
                if idx ≠ MAX and rand1000 < rate and (as = dic_abstate.as_FromIndex(idx)) and not t.so_AbnormalState_Resist(as) (vt 0x634):
                    if t.so_AbnormalState_Set (vt 0x638)(c, idx, strength, as, g_Now, 0, 0, 0, 5, &f.position):
                        so_AbnormalState_BitSet(t, idx)
                        if as.subabstate[strength].assa_info: t.so_AbnormalState_Inform (vt 0x3f0)(idx, KeepTime, 1);
                            so_AbnormalState_BroadcastSet(t, idx, KeepTime, strength)        (Z03 §6)

ShineMagicField::smfm_MagicFieldHeal(f)                                                    @ FUN_0056d6b0
    caster check as above (but the pointer is not cleared on failure; the tick just does nothing)
    scan = AxialListMagicFieldHeal { almfh_Owner, almfh_FieldCenter = f.position }      (an AxialListNearScan, no bitmap)
    so_AllOfRange(f, f.smfm_Cener, Area/2, scan, includeSelf 1);  almfh_ApplyHeal(scan, s, &f.smfm_Empower, f)

AxialListMagicFieldHeal::alns_ValidObject(scan, t)                                         @ FUN_00568620
    require t.so_GetHP() ≠ 0, t.so_Field, owner c ≠ null   (checked in the disassembly; the decompile drops the return)
    if c.so_GetCharRegistNumber() == t.so_GetCharRegistNumber(): accept                # the caster itself
    if c.so_mobile_IsEnemy (vt 0x72c)(t) == 1: reject
    if t.so_GetRaidNumber (vt 0x554) ≠ 0xFFFF: accept iff c's raid number == t's
    elif t.so_PartyRegistNumber_InAttack (vt 0x560) ≠ 0xFFFF: accept iff c's party == t's
    else reject                                          # only the caster, its party or its raid; mobs return 0xFFFF

AxialListMagicFieldHeal::almfh_ApplyHeal(scan, s, empower, f)                             @ FUN_0056d2c0
    owner null: assert "…almfd_ApplyDamage - MagicField Owner NULL" (copy-pasted labels); s or s.sdi_Activ null: return
    for each scanned t:
        if not c.smo_ICanHealTo (vt 0xe94)(t): next                       (§8.4)
        ctx = EngageArgument(c, t, s, empower, f.position)
        heal = s.HEALAMOUNT
        if c.so_GetItemActionObserves and EventRunBySkillGroupIndex(results, s, SEIT_HEAL_RATE_INCREASE, c, t):
            heal = GetRateAppliValue(results, heal)
        heal = setitemskilleffect[SET_HEALRATE] × heal / 1000
            # (original bug) Z09-B30: `setitemskilleffect` (Z03 g_SetEffect) is a scratch global that a cast fills
            # with its caster's set-item effects and every ShineMobileObject::so_Routine resets to 1000 (§5.5); the
            # field tick runs outside both, so it reads whatever the last processed mobile object left there
            # *(inferred from the call order)*, not the field caster's set bonus
        if empower.damage: heal += s.sdi_Activ.nIMPT[empower.damage + 3]
        if so_FindBlockLocate(f, t.position, 10000, mbi_IsAttackBlock) moves the point: stop     # Z09-B26, heal side
        t.so_mobile_HPHealOverTime (vt 0x734, FUN_0040e910)(c, heal, MAX_ABSTATEINDEX)        (Z03 §6)
        if s.SETABSTATEFRIEND:
            as = dic_abstate.as_FromID(value); if as == null or as.index == null: next   # also skips the rolls below
            t.so_AbnormalState_Set_Simple (vt 0x644)(c, as.index.AbStataIndex, 1, 1)
        if s.sdi_Activ.Last ∈ {TARGET_ME, TARGET_PARTY, TARGET_FRIEND, TARGET_ALL, TARGET_GROUP}:
            the 4 abstate rolls as in the damage path, but BitSet / Inform / BroadcastSet run even when
            so_AbnormalState_Set returned false
            # (original bug) Z09-B29: a refused abstate (stronger one present, immune) is still flagged in the brief
            # bits and announced to sight with its full KeepTime

AxialListMagicFieldAggro::alns_ValidObject(scan, t)                                        @ FUN_0057a980
    require t.so_GetHP() ≠ 0, t.so_IsMob() (vt 0x89c: 1 for ShineMob and ShineServant (folded FUN_005af8d0), ShineBandit
        `so_IsMob` FUN_00556e90 (its mob form, §5.10); 0 for players, NPCs and the rest), c.so_mobile_ICanDamageTo(t),
        no attack block between f and t
AxialListMagicFieldAggro::almfa_AppendAggro(scan)                                          @ FUN_0057aad0
    for each t: t.so_mob_AppendAggro (vt 0x700)(c, 1)        # every mob in the field notices the caster once (§6.2)
```

`AxialListLimitAreaScan` (the bitmap filter shared with area skills, Z03): `allas_Init(area, from, to, dir)` FUN_004c1a00
puts the bitmap centre on `from` (EffectTarget `IPT_ME`) or `to` (`IPT_TARGET` / `IPT_SPOT`) and, for directional
bitmaps (`bIsDirection`), takes the direction from→to (or `dir` when both are equal); `ali_Work` FUN_004c1e20 keeps an
object (mode ≠ 0 and ≠ 3, `alns_ValidObject`, < 200 entries) whose position, rotated into the bitmap frame, falls on a
non-zero `AreaBMP` cell and stores that cell value as the target's damage rate (`alns_GetBMPDamageRate` FUN_004c1b10 =
cell × 10 ‰, 1000 without a bitmap); `allas_GetEffectCoord` FUN_004c1ae0 = the bitmap centre. Without a bitmap it is a
plain `AxialListNearScan` (all valid objects, ≤ 200).

### 12.6 Packets and the client

```pseudo
0x1C0C NC_BRIEFINFO_MAGICFIELDSPREAD_CMD { u16 handle; u16 caster; u16 skillid; SHINE_XY_TYPE location; u16 radious }   (16 bytes)
    stored at f+0x167; sent by f.so_SendMyBriefInfo (vt 0x4c8):
      - at the spread to every player in sight (so_ExchageBriefInfo → bixc_Exchange → f.so_SendMyBriefInfo, Z02 §5.2)
      - to a player walking into sight (AxialListBriefExchangerAtMove, §9.6)
0x1C0D NC_BRIEFINFO_MAGICFIELDINFO_CMD { u8 magicfields; NC_BRIEFINFO_MAGICFIELDSPREAD_CMD magicfield[] }   (batch, ≤ 28)
    batch `briefmagfld` (BriefInfoExchanger::BriefInfoExchangeMagicField, buffer 464 bytes)
    bixmfm_Exchange(batch, me, field)  (so_ExchageBriefInfo case 6: a player's full exchange meets a field)   @ FUN_004402d0
        if same layer (or either −1) and so_SubLayer_CanSee(field, me) and me is a player:
            if batch.magicfields > 27: bixmfm_Send(batch, me); magicfields = 0
            field.vt[0x4c4](&batch.magicfield[magicfields])     # ShineObject default: empty body (folded FUN_00549070)
            # magicfields is never incremented
    bixmfm_Send(batch, me): if magicfields ≠ 0 and me is a player in a mode ≠ 0: me ← 0x1C0D (3 + 16·n bytes)   @ FUN_0043db60
        (profiler label "BriefInfoExchangeItem::bixi_Send", copy-pasted)
    # (original bug) Z09-B27: ShineMagicField does not override the brief copy (vt 0x4c4) and bixmfm_Exchange never
    # counts, so 0x1C0D is never sent. Fields are announced only by the spread and by moves into sight (§9.6, which
    # also covers teleports): a player who enters the map (login, map link) or changes layer next to an active field
    # does not see it until one of them moves out of and back into sight (the field still hits them)
0x1805 { u16 handle } at vanish (§12.4)
```

Client (2016 `GameFrameWork`; names *(pdb2017)* from C02): `On_NC_BRIEFINFO_MAGICFIELDSPREAD_CMD` FUN_004a09b0 looks up the
skill (`skillid`) and the caster; when the caster is known and the skill's client row byte +0x213 is 0x42 it calls the
caster's vt 0xd4(1) (an animation switch, not traced); then `MagicField::AddMagicField` FUN_00611a60 creates the effect
from the skill's view row (two effect names at +0x1c7 / +0x207, a scale from +0x21f when +0x21b == 14) and keeps the
packet in a list. `On_NC_BRIEFINFO_MAGICFIELDINFO_CMD` FUN_00499a90 calls `AddMagicField` for each of the `magicfields`
records. 0x1805 (FUN_004bd620) calls `MagicField::DeleteMagicField(handle)` FUN_00611960. The client ignores `radious`
(the effect file sets the size). Damage and heals arrive as 0x243C / HP-heal packets of the targets (Z03).

### 12.7 `ShineAxialFlag`: the map anchors (0x188 bytes)

| Offset | Member | Meaning |
|---|---|---|
| +0x167 | `safm_allofrange_this` | what the flag stands for in a list walk: 0 for the two sentinels, the flag itself for the five anchors |
| +0x16b | `safm_Screen` | `Movie::CinemaComplex*` run by this flag (anchor 2 only) |
| +0x16f | `safm_DefaultCoord` (`SHINE_COORD_TYPE`, 9) | position storage (`so_LocateInfo` points here) |
| +0x178 | `safm_vecRoutions` (`vector<RoutionInterface*>`) | extra per-tick objects (the guild tournament) |

```pseudo
ShineAxialFlag::ShineAxialFlag(a)              @ FUN_00559050: vector and screen empty; location → safm_DefaultCoord, direct → its dir
ShineAxialFlag::~ShineAxialFlag(a)             @ FUN_00556220 (vector_deleting_destructor FUN_005578b0): frees the vector storage
ShineAxialFlag::so_SlantedFlag(a, x, y, map, self)   (vt 0x590)   @ FUN_00556270
    a.position = (x, y); dir = 0; a.safm_allofrange_this = self; a.so_Field = map
ShineAxialFlag::so_AllOfRange_Getthis(a)       (vt 0x66c)   @ FUN_005562a0: return a.safm_allofrange_this
    # every other class returns itself (folded ShineMobileObject::so_ShineMobileObject FUN_00450350); the list walks of
    # so_AllOfRangeNomal / so_AllInMapNomal stop at a 0 (the sentinels) and so_Logout FUN_0054b780 uses it to see
    # whether the object is linked
ShineAxialFlag::so_safm_SetCinema(a, cc)       (vt 0x670)   @ FUN_005562b0: a.safm_Screen = cc
ShineAxialFlag::so_DefaultCoord(a)             (vt 0xc)     @ FUN_0054a100: &a.safm_DefaultCoord
ShineAxialFlag::so_BroadcastLogout(a)          (vt 0x51c)   @ FUN_00549d90: assert only (flags never leave a map)
so_ObjectType (vt 0x4d0) = 0 and so_BriefInfoRange (vt 8) = 0 (folded bodies): brief exchanges skip flags.

ShineAxialFlag::so_Routine(a)                  (vt 0x4ac)   @ FUN_00569e00
    if a.safm_Screen: List<…>::l_4AllInList(a.safm_Screen, Movie::FilmCase::fc_Routine)    # the map's cinema (§27.3)
    for each r in a.safm_vecRoutions: r.vt[4]()                                              # e.g. GuildTournamentSystem (Z16)
    return 1
```

Creation, in `FieldMap::fm_Init` FUN_00464bc0 (map load): `zero` = flag at (0, 0) and `infinite` = flag at
(0xFFFFFF, 0xFFFFFF), both with `self` = 0, linked as the ends of both coordinate lists; five anchors `flag[0..4]` at
(w/10 + i·w/5, h/10 + i·w/5) with `self` = the flag, appended to both lists (§9.6); then `fm_Multiflex` = a new
`Movie::CinemaComplex` (0x12E798 bytes; failure: "FieldMap::fm_Init : Memory Leak", `ShineExit`), and
`flag[2].so_safm_SetCinema(cc_SetArgument(fm_Multiflex, map, flag[2]))`. `FieldMap::fm_CreateGuildTournamentSystem`
FUN_00464830 creates the map's `GuildTournamentSystem` (0x1E8 bytes), sets the cinema again and pushes the system into
`flag[2].safm_vecRoutions`. `FieldMap::fm_Relink` FUN_00462bd0 re-places the sentinels and anchors with `so_SlantedFlag`.
So the per-map cinema (scripted scenes, §27) and the guild tournament run once per tick from the object routine of
the axial-flag pool (§1.3), not from the map. Flags are never freed while the server runs (the pool is freed in
`ShineObjectManager::~ShineObjectManager` FUN_0054f8b0).

### 12.8 Open points of this section

- Which SubAbState kinds use the "MagicField" actor and how often its `sasa_Routine` runs: Z03 §6.1 (the actor table).
- The client byte +0x213 == 0x42 / vt 0xd4 in `On_NC_BRIEFINFO_MAGICFIELDSPREAD_CMD` (a caster animation) was not traced.
- `almfd_BattleField` / `slmfd_GuildWarMap` are filled and never read: maybe a planned guild-war rule.
- `smo_MagicFieldSpread`'s `vt 0x648` / `vt 0x64c` (abstate on the caster, NOTTARGET) are the cast-side helpers of Z03.

---

## 13. Other world objects 2: doors, effect objects, servants

Part 8b. Three object classes that scripts and skills put on a map. Doors and effect objects are passive (no AI);
servants are mobs summoned by a skill and owned by their caster. Movers (kind 11) belong to Z13; only their hit rule
is here (§8.4, corrected in this part). Object kinds and handle ranges (Z01 knowledge, pool table): door 7 (handles
20638…21637, 1000 slots), effect 9 (19388…20387, 1000), servant 10 (21638…22137, 500).

### 13.1 `ShineDoor` (kind 7, 0x1f14 bytes): script-built gates

Members *(pdb2016)* on top of `ShineMobileObject`:

| Offset | Member | Use |
|---|---|---|
| +0x1ea8 | `sd_DoorBriefInfo` (`BriefInformationDoor` 0x47: `bid_pack`, `bid_array[51]`, `bid_nc`, `bid_BriefInfo` +0x1eeb) | ready-made 0x1C0F packet; the object's position pointers (+0x66 / +0x6a) point into its `coord` |
| +0x1eef | `sd_Locate` (`LoginLocation`: map Name3, x, y, dir) | `so_LoginLocation` (vt 0x4bc) |
| +0x1f04 | `sd_MobDataBox` | the door's MobInfo entry (model, `so_mobile_GetIdxName` vt 0x894 = `InxName`) |
| +0x1f08 | `sd_HP` | set to MobInfo.MaxHP at build, **never read** |
| +0x1f0c | `sd_Retrate` | 1 = remove at the next tick (`so_RetrateFromMap` vt 0x3f4) |
| +0x1f10 | `sd_BlockInfo` (`MapDoorBlockElement*`) | **never written or read** (only zeroed by the pool) |

Packets *(pdb2016)*: 0x1C0F `NC_BRIEFINFO_BUILDDOOR_CMD` = `PROTO_NC_BRIEFINFO_BUILDDOOR_CMD` (0x30: u16 `handle`, u16
`mobid`, `SHINE_COORD_TYPE coord` (x, y, u8 dir), u8 `doorstate` +0xd, `Name8 blockindex` +0xe (32 bytes), u16 `scale`
+0x2e); 0x1C10 `NC_BRIEFINFO_DOOR_CMD` { u8 `doornum`, BUILDDOOR[doornum] }; 0x6C09 `NC_SCENARIO_DOORSTATE_CMD`
{ u16 `door`, u8 `doorstate` } (`MapBlock::DoorAction`: `DA_CLOSE 0`, `DA_OPEN 1`, `DA_BREAK 2`).

```pseudo
ShineDoor::ShineDoor()                                                          @ FUN_0055af50
    ShineMobileObject ctor; BriefInformationDoor ctor (FUN_00549260: packet 0x1C0F, length 0x32, scale 1000); sd_Locate.map = ""

ShineDoor::so_door_Build(map Name3*, x, y, dirDeg, handle, mobId, scale, u64 layer) → FM_MarkingError   (vt 0x6dc) @ FUN_0043f7b0
    lastMoveCmd (+0x168) = 0
    sd_Locate = { map, x, y, dir = dirDeg/2 (+180 if negative) }      # 2-degree units, as for mobs
    brief.coord = (x, y, dir);  brief.doorstate = 0 (closed);  brief.blockindex = ""     # the block name stays empty
    sd_MobDataBox = mobdatabox[mobId]; none → assert "…so_door_Build : Not in MobDataBox", return FM_BLOCKED (3)
    r = so_MapMarking(1) (§5.7); r ≠ FM_MARKSUCCESS → return r                      # caller frees the slot
    sd_HP = row.MaxHP;  brief.handle = handle; brief.mobid = mobId; brief.scale = scale
    so_SetLayerRegNum(layer)
    vt 0x6f8 so_door_BuildComplete(handle)
    if MoveManager kind (+0x18c) ≠ 3: clear the MoveManager (kind, speed, duration, …), dest = current position
    return FM_MARKSUCCESS (0)

ShineDoor::so_door_BuildComplete(handle)                     (vt 0x6f8)          @ FUN_004422a0
    so_InitAIScript (vt 0xc14, ShineObject::so_InitAIScript FUN_00558c80: script pointer 0, the 8 function names "")
    lastMoveCmd = 0;  mode byte (*(+0xe9c)) = 1;  sd_Retrate = 0;  sub-layer word (+0x76 → +0/+4) = 0
    briefdoor batch count = 0
    sight² (g_SightDistSq) = 0 without map / MapInfo; −1 for OSS_WIDE sight or fm_CameraState (+0x124) == 1; else MapInfo.Sight²
    so_AllInMap(so_ExchageBriefInfo FUN_00441460)            # Z02 §5.2: every player in sight gets 0x1C0F
    +0x1e78 &= ~2

ShineDoor::so_door_DoorAction(blockName, action) → 1         (vt 0x318)          @ FUN_00550770
    brief.doorstate = action;  brief.blockindex = blockName (32 bytes)
    mbi_DoorAction(field.fm_BlockInfo, brief.blockindex, action)                    (§9.2: changes .shbd)
    broadcast to every player of the map (so_AllInMap, AxialListPacketBroadcast):
        0x6C09 NC_SCENARIO_DOORSTATE_CMD { door = own handle, doorstate = action }
    # (other classes: vt 0x318 is a folded "return 0" body, CGambleObject::GDTSO_SetDiceProbability FUN_004021b0)

ShineDoor::so_Routine(list, h)                                (vt 0x4ac)         @ FUN_00567280
    if position outside fm_XSize / fm_YSize: assert "fm_IsInFieldSize : Door"; +0x1e78 |= 1 (invalid position)
    if so_RemakeHandle(h) ≠ own handle: assert "…so_handle is invalid!!!", fix the handle
    if sd_Retrate: so_Unmark(0, 1, 3) (0x1805 to the map, §12.6), som_FreeObject(handle, REMOVE_NOW, reason 6)
    if either slanted-list node is invalid: FieldMap::fm_Relink(field)     # same tail as every object routine (§9.6)
    return 1
ShineDoor::so_RetrateFromMap()  (vt 0x3f4)  sd_Retrate = 1                                   @ FUN_00495e50
    # vt 0x3f4 callers: map clear (`AxialListObjectClear::ali_Work` FUN_00495940), `so_RetreatFromMapByImmeditely`,
    #   vanish iterators (`AxialListMobVanish::almv_Vanish` FUN_004283a0 / `::ali_Work` FUN_004283c0,
    #   `AxialListMobIndexVanish::ali_Work` FUN_005f0050, `AxialListVanishDropItem::ali_Work` FUN_00428a00), cNPCVanish FUN_005d8be0, &releasenpc (Z11)
ShineDoor::so_RemakeHandle(i) = i < 1000 ? i + 20638 : 0xFFFF                                @ FUN_00555ba0
ShineDoor::so_ObjectType() = 7                                                               @ FUN_00643150
ShineDoor::so_FillBriefInformation(dst)  (vt 0x4c4) copy the 0x30-byte brief into a 0x1C10 batch slot @ FUN_00555c00
ShineDoor::so_SendMyBriefInfo(rcv)       (vt 0x4c8) rcv ← 0x1C0F (rcv.vt[0x2fc] sender, vt 0xc)     @ FUN_00555b60
ShineDoor::so_LoginLocation = &sd_Locate (FUN_00555b90);  so_mobile_GetIdxName = row.InxName (FUN_00555bf0)

BriefInfoExchangeDoor::bixd_Exchange(batch, rcv, door)                           @ FUN_0043ff60
    only for rcv kind 2 (player); copies rcv's name (vt 0x56c) into the `namestring` ring and never uses it
    if batch.doornum > 27: bixd_Send(rcv); doornum = 0
    door.vt[0x4c4](&batch.doors[doornum]); doornum++
BriefInfoExchangeDoor::bixd_Send(batch, rcv)                                     @ FUN_0043d7d0
    if doornum and rcv is a player in a mode ≠ 0: rcv ← 0x1C10 { doornum, doors } (length 3 + 0x30·n)
```

The other inherited slots keep the `ShineMobileObject` behaviour: `so_KilledBy` is the base one, but no class may hit
a door (the player and mob damage rules of Z03 §3.3 / §8.4 accept only players, movers, mobs, bandits and NPCs as
targets), so doors are indestructible and `sd_HP` is dead data. Nothing passes `DA_BREAK`.

**Who builds and switches doors.** Every caller allocates a pool slot of kind 7 first and frees it (reason 0x17) when
the build fails.

```pseudo
cDoorBuild(mapName, mobIndexName, x, y, dirDeg, scale) → handle | nothing        @ FUN_005dc5f0
    field = fc_FindMap(mapName); needs fm_GetCenterObject(field) (the map's axial flag, §12.7)
    mobId = mdb_2MobID(mobIndexName) (≠ 0xFFFF); slot = som_AllocObject(kind 7)
    so_door_Build(field (its Name3 fm_MapID), x, y, dir, slot, mobId, scale, layer 0)
    success: push slot handle, return 1;  failure: free slot (0x17), return 0
cDoorAction(handle, blockName, "open" | "close") → 1 | nothing                   @ FUN_005dc840
    o = som_GetObject(handle); o.kind must be 7; blockName and the word must be strings
    "close" → o.so_door_DoorAction(blockName, DA_CLOSE); "open" → DA_OPEN; any other word: no action, still returns 1
PineEventScriptNode::ShineDoorBuild::sa_Step                                     @ FUN_004f9440
    slot = AllocObject(7) ("…ShineDoorBuild::sa_Step : Too many mob"); OtherStatement::os_ObjectRegen(…, slot) (§10.8 / part 14)
    failure: free (0x17)
PineEventScriptNode::SysFuncShineDoorBuild::sfb_Calculate → handle or 0xFFFF     @ FUN_004e3990
    slot = AllocObject(7); ScriptMobBreeder::smb_ObjectRegen (§10.8) → kind 7 builds with scale 1000
    failure: List::l_Free(slot) (FUN_004b1300), result 0xFFFF
PineEventScriptNode::ShineDoorOpen::sa_Step / ShineDoorClose::sa_Step            @ FUN_004ed970 / FUN_004edb30
    o = os_ShineObject(stack) (statement's object argument); if o.kind == 7: evaluate the block-name argument
    → o.so_door_DoorAction(name, DA_OPEN / DA_CLOSE); else assert "…ShineDoorOpen::sa_Step : Invalid object"
    (the Close node logs the Open node's text: copy-paste, harmless)
&doorbuild (AmpersandCommand::ac_DoorBuild FUN_0041aa50): GM command, Z11
```

The 2016 Lua scripts always build and close a door in one go (`cDoorBuild` then `cDoorAction(h, block, "close")`,
e.g. `ID/GraveYardH/Functions/Progress.lua`, `Promote/Job2_Gamb/Functions/Progress.lua`) and open it later; `WarHH`
opens doors and locks that the map file placed.

**Client** (2016 `GameFrameWork` handlers, names from the 2017 PDB *(pdb2017)*):

- 0x1C0F `On_NC_BRIEFINFO_BUILDDOOR_CMD` (FUN_004a0a60): unless the handle is the player's own, `CharMgr::AddMob`
  (FUN_00648290) creates a door character from `mobid` at `coord`, scale `scale`/1000, **stores `blockindex` in the
  character (+0x9bf)** and shows the closed (doorstate 0) or open (1, 2) pose; then updates the client's own copy of the
  door block (FUN_0067a700 → FUN_0067aa10: block found by case-insensitive name; closed for 0, open for 1 / 2, other
  values ignored; "Error Door Block Data" message box when the block's width is not a multiple of 8).
- 0x1C10 `On_NC_BRIEFINFO_DOOR_CMD` (FUN_004a0b00): the same per entry (without the own-handle check).
- 0x6C09 `On_NC_SCENARIO_DOORSTATE_CMD` (FUN_004a3510): finds the character (asks 0x1C01 when unknown), plays the
  close (state 0) or open (1 / 2) animation (FUN_0063f490) and updates the client block **by the name stored at
  +0x9bf**; other states are ignored.

Because `so_door_Build` sends the brief with an empty `blockindex` and 0x6C09 carries no name, every client that saw
the door appear before its first `so_door_DoorAction` keeps the name "" and its door block is never switched by
0x6C09 (the lookup matches no block); only clients that get the brief later (entering sight, 0x1C01) learn the name.
The server's `.shbd` and those clients' collision then disagree until they leave and re-enter sight (original bug)
Z09-B33.

### 13.2 `ShineEffectObject` (kind 9, 0x1d3 bytes): a visual effect placed by a script

Derives from `ShineObject` (not mobile: no HP, no MoveManager). Members *(pdb2016)*: +0x167 `seo_EffectBriefInfo`
(`BriefInformationEffect` 0x47, payload pointer `bie_BriefInfo` +0x1aa), +0x1ae `seo_VanishTime` (tick), +0x1b2
`seo_LoginLoc`, +0x1c7 `seo_Detach` (object followed, raw pointer), +0x1cb `seo_DetachCheck` (`Metronome`).

Packets *(pdb2016)*: 0x1C11 `NC_BRIEFINFO_EFFECTBLAST_CMD` = `PROTO_NC_BRIEFINFO_EFFECTBLAST_CMD` (0x30: u16 `handle`,
`Name8 effectname` +2 (32 bytes), `SHINE_COORD_TYPE coord` +0x22, u16 `detach` +0x2b (followed object's handle,
0xFFFF none), u16 `scale` +0x2d, u8 `flag` +0x2f bit 0 `loop`); 0x1C12 `NC_BRIEFINFO_EFFECT_CMD` { u8 `effectnum`,
EFFECTBLAST[effectnum] }.

```pseudo
ShineEffectObject::ShineEffectObject()                                          @ FUN_00559130
    ShineObject ctor; BriefInformationEffect ctor (FUN_005491f0: packet 0x1C11, length 0x32, scale 1000); Metronome

so_effect_EffectBlast(handle, map, obj, Name8 name, ms, scale, loop)      (vt 0x6e4: on an object)    @ FUN_004b1540
so_effect_EffectBlast(handle, map, x, y, dirDeg, Name8 name, ms, scale, loop) (vt 0x6e8: at a spot) @ FUN_004b1770
    seo_Detach = obj (spot version: null)
    seo_VanishTime = g_Now + ms·10/1000                   # ms → tenths
    seo_DetachCheck = every 50 ticks (5 s), first at g_Now + 50
    brief = { handle, effectname = name, detach = obj.handle (spot: 0xFFFF), scale, flag.loop = loop & 1 }
    object version: brief.coord = obj's position and direction; seo_LoginLoc = obj.vt[0x4bc]() with that position
                    (the `map` argument is ignored: the effect goes on obj's map)
    spot version:   brief.coord = (x, y, dirDeg/2 (+180 if negative)); seo_LoginLoc = { map, x, y, dir }
    r = so_MapMarking(1); r ≠ 0 → return r                 # caller frees the slot
    vt 0x6f0 so_effect_BlastComplete(handle); return 0

ShineEffectObject::so_effect_BlastComplete(handle)            (vt 0x6f0)         @ FUN_004423e0
    so_InitAIScript (no script); sub-layer word = 0; briefeffect batch count = 0; sight² as for doors (§13.1)
    so_AllInMap(so_ExchageBriefInfo)                       # every player in sight gets 0x1C11

ShineEffectObject::so_Routine(list, h)                        (vt 0x4ac)         @ FUN_00569ef0
    if position outside the field: assert "fm_IsInFieldSize : Effect"; seo_VanishTime = 0
    if seo_DetachCheck due: next += 50
        if seo_Detach and dist²(self, seo_Detach) > 100: so_MoveTo(detach.x, detach.y, 5)   # keep up within 10 units
    if seo_VanishTime <= g_Now: so_Unmark(0, 1, 3) (0x1805 to the map); som_FreeObject(handle, REMOVE_NOW, reason 5)
    if so_AIScript.AIScript (+0x7e): LuaScriptScenario::lss_Routine(script, Entrance name, LuaArgumentMobAI(handle, field))
        # runs even in the tick that freed the object; a script is only present if one was attached later (part 9a)
    return 1
ShineEffectObject::so_RetrateFromMap() (vt 0x3f4): seo_VanishTime = 0  (removed next tick)  @ FUN_00495cc0
so_RemakeHandle(i) = i < 1000 ? i + 19388 : 0xFFFF (FUN_00555450);  so_ObjectType() = 9 (FUN_00643070)
so_LoginLocation = &seo_LoginLoc (FUN_00555440);  so_FillBriefInformation: copy the 0x30-byte brief (FUN_005554a0)
so_SendMyBriefInfo (vt 0x4c8) = the drop item's body FUN_00555280: rcv ← 0x1C11
BriefInfoExchangeEffect::bixe_Exchange / bixe_Send                               @ FUN_004400a0 / FUN_0043d900
    as for doors (§13.1) without the name copy; 0x1C12 { effectnum, effects } (length 3 + 0x30·n, ≤ 28 per packet)
```

`seo_Detach` is a raw pointer that nothing clears: when the followed object is removed first, the effect keeps
following whatever the pool slot holds next (a re-used slot or the freed object's last position) until its own
vanish time (original bug) Z09-B34 *(effect inferred; no crash, the pool memory stays allocated)*. The client
attaches the effect to the `detach` character itself, so this only shifts the server-side position used for later
briefs.

**Creators** (all allocate a kind-9 slot, free it on failure):

```pseudo
cEffectRegen_Object(mapName, effectName, handle, seconds, loop, scale) → handle | nothing   @ FUN_005e4f30
    needs two strings and a non-zero existing handle; scale 0 → 1000
    vt 0x6e4(slot, mapName, obj, effectName, seconds × 1000, scale, loop); failure: free (reason 0x32)
cEffectRegen_XY(mapName, effectName, x, y, dirDeg, seconds, loop, scale) → handle | nothing  @ FUN_005f0b50
    scale 0 → 1000; vt 0x6e8(slot, map, x, y, dir, effectName, seconds × 1000, scale, loop); failure: free (0x32)
    # argument order read from the disassembly (0x5f0cc4…): the decompile swaps arguments 7 and 8
PineEventScriptNode::ShineEffectObject::sa_Step  (var = ShineEffectObject(handle, name, ms, scale))   @ FUN_004f2570
    o = GetObject(handle) ("…: no Object" / "…: no effect"); slot = AllocObject(9) ("…: Too many Effect")
    if o has a field: vt 0x6e4(slot, script map name, o, name, ms, scale, loop 0); var = slot; failure: free (0x1f)
    if o has no field: nothing; the allocated slot is not freed here, but its first `so_Routine` finds a vanish
        time in the past (0 or the previous occupant's) and frees it (reason 5) *(inferred: pool memory not reset)*
PineEventScriptNode::ShineEffectLocate::sa_Step (var = ShineEffectLocate(name, x, y, dir, ms, scale)) @ FUN_004f28e0
    slot = AllocObject(9); vt 0x6e8(slot, script map name, x, y, dir, name, ms, scale, loop 0); var = slot; failure: free (0x20)
```

Lua takes seconds, Pine milliseconds. The FH documentation *(fh-doc)* gives the same order for `cEffectRegen_XY`
but only five arguments for `cEffectRegen_Object` (Scale as the 5th); the code and the 2016 scripts use six (5th =
loop, 6th = scale: `KQ/EmperorSlime` `cEffectRegen_Object(MapIndex, effect, Handle, 3600000, 1, 1000)`). That script
passes 3600000 as if it were milliseconds: × 1000 and then × 10 overflow 32 bits, and the effect lasts ≈ 45 h instead
of 1 h (a script data mistake, not a server bug). Lua users: the roulette of `Promote/Job2_Gamb`, AI scripts
(`E_XTreeBig`, `E_MomSlime`) and KQ boss effects.

**Client** (`On_NC_BRIEFINFO_EFFECTBLAST_CMD` FUN_004bd900 / `On_NC_BRIEFINFO_EFFECT_CMD` FUN_004bd920 →
`EffectObjectMgr::AddEffectObject` *(pdb2017)* FUN_004c4560): loads the effect file named `effectname`; `detach`
0xFFFF → placed at `coord` (direction × 2°), else attached to that character (no effect when the character is
unknown); scale `scale`/1000; `loop` bit kept; an effect already registered under the same handle is replaced. It
disappears with the object's 0x1805 logout broadcast (§12.6).

### 13.3 `ShineServant` (kind 10, 0x2598 bytes): mobs summoned by a skill

A `ShineMob` with a master. Members (+0x2568…+0x2594, *(pdb2016)*) and the explosion states: §8.8. This section adds
the summon, the master link, the overrides and the end of life.

**Table: `World/MiscDataTable.txt`, table `SkillBreedMob`** (`MiscDataTable::mdt_Load` FUN_004a82d0 at `zs_start_sun`;
read error → "Error in read MiscDataTable.txt", ShineExit). The loader reads five tables in order: `SkillBreedMob`
(`mdt_SkillBreedMob` FUN_004a6880, this section), then `AbStateReset`, `Neutralization`, `Polymorph`,
`StateCondition` (`mdt_AbStateReset` FUN_004a6580 / `mdt_Neutralization` FUN_004a64c0 / `mdt_Polymorph`
FUN_004a63e0 / `mdt_StateCondition` FUN_004a3550: skill side effects, §28.3; see Coverage
boundary). Skill rows are `MiscData_Skill` (0x80, ≤ 100, kept sorted by skill ID; `mdt_SkillBufferAlloc`
FUN_004a3d90 finds or adds the row of a skill name: unknown skill "Imvalid skill name" / > 100 "Too many Data" →
ShineExit; new rows from `mds_Init` FUN_004a2e50: BreedMob 0xFFFF, Polymorph 0xFFFF, all else 0 / none).

| Column (type) | Member | Values |
|---|---|---|
| Skill (String[33]) | `mds_SkillID` | row key |
| MobIndex (String[33]) | `mds_BreedMob` +2 | mob to summon (unknown → "Imvalid mob name", ShineExit) |
| SummonNum (BYTE) | `mds_SummonNumber` +4 | servants per cast |
| AI (Index) | `mds_AI` +8 | `Root` 0 `SAI_ROOT`, `Chase` 1, `Rampage` 2, `Roam` 3 |
| RegenLoc (Index) | `mds_RegenLoc` +0xc | `Caster` 0 `RL_CASTER`, `Target` 1 |
| RegenDistance (WORD) | `mds_RegenDistance` +0x78 | ring radius around the spawn point, 0 = same spot |
| MobRoam (Index) | `mds_RoamingType` +0x7c | `-` 0, `Straight` 1, `Random` 2 |
| LifeTime (DWRD) | `mds_LifeTime_MilliSec` +0x54 | ms, 0 = until the master leaves |
| AbState (String[33]) | `mds_Abstate` +0x10 | abstate put on the servant at summon (`-` = none) |
| TriggerObject (Index) | `mds_ExploseTriggerObject` +0x5c | `-` `Enemy` `Target` `Always` `CasterTarget` `TargetAll` (§8.8) |
| TriggerRange (DWRD) | `mds_ExploseTriggerRange` +0x60 | |
| Delay (WORD) | `mds_ExplosionDelay` +0x70 | ms between blasts |
| ExplNo (WORD) | `mds_ExplosionNumber` +0x6c | number of blasts |
| Explosion (String[33]) | `ExploseEffectSkill` +0x64 | skill fired (`-` = 0xFFFF) |
| ExplosionWhere (Index) | `ExploseEffectSkillTo` +0x68 | `-` `MyLoc` `MyObj` `TargetLoc` `TargetObj` |
| Debuff (Index) | `mds_Dead.ByDebuff` +0x58 bit 0 | `Dead` = the servant can be killed by a dispel (vt 0x984 `so_MiscTable` in `ShineMobileObject::so_Dispel` FUN_0042bf70, Z03) |
| MultiTarget (Index) | `mds_MultiSummonType` +0x74 | `-` `MST_NONE`, `Multi` `MST_MULTI` |

2016 rows: traps (`Entrap01…10`, Root + StaEntrapHide + Enemy trigger), homing arrows (`SlowShot*`, Chase + Target
trigger), summons (`Summon01` 3 skeletons, Rampage), fire poles (Roam + Always, blasts every 7–10 s), the light fields
and orbs of class skills (Root, no explosion) and many boss summons.

```pseudo
MiscDataTable::mdt_SkillBlast_Summon(caster, target, skillId, pos, multiType)    @ FUN_004a7530
    # callers (Z03 skill blast): SkillBlastEffect::sbe_BlastObject FUN_00583bc0 and sbe_BlastLocate FUN_00584160
    #   (multiType MST_NONE, target null for the location version); AxialListScanSkillTarget::alsst_SkillBlast
    #   FUN_00582de0 and alsst_SkillBlast_RandomTarget FUN_00583180 (MST_MULTI, per hit target, first hit step only)
    if not caster or not pos: return
    row = bsearch(skillId) or the default row mdt_DefSkill (BreedMob 0xFFFF)
    if row.BreedMob == 0xFFFF or row.MultiSummonType ≠ multiType: return      # Multi rows only from the multi-target blast
    if caster has no field: assert "…Map name null"; return
    for i in 0 … SummonNumber−1:
        slot = som_AllocObject(kind 10) ("…: Too many mob" → stop)
        s.vt[0x9b4] so_serv_ServantMissionSet(row)  (FUN_0044a970: ss_MiscTable = row)
        mdt_Summon_RegenLoc(row, i, caster, pos, &at, &dir) fails → "…Get regenLocation fail", stop   # slot stays allocated, see below
        r = s.vt[0x6e0] so_mob_Regenerate(caster.field, at, dir·2, slot, row.BreedMob, brief 0, regnum −1,
                                           family 0, breeder 0, level −1, 1, caster's layer)
        r ≠ 0: free(slot, reason 0x26); stop
        if the field has a Lua script: fm_LuaScriptFuncExec(field, 0x90, LuaArgumentServantSummon(field, s, caster))   # part 9a
        if s has STA_IMMORTAL (spawn protection *(inferred)*): reset it (vt 0x650(0x123), bit reset, broadcast reset)
        s.vt[0xc54] so_serv_SetRoamingData(row.RoamingType, dir, (180/SummonNumber)/2, caster.x, caster.y)
        t = target;  if row.TriggerObject == ETO_CASTERTARGET or no target: t = caster.vt[0x75c]() (its current target)
        if row.AI == SAI_CHASE and t and t ≠ caster:
            s.so_mob_AppendAggro(t, 100000);  s.vt[0x98c] so_serv_SetTarget(t);  reset STA_IMMORTAL again
        s.vt[0x988] so_serv_SetMaster(caster, row)
        if row.Abstate set and as_FromIndex finds it: s.vt[0x638](s, abstate, 1, …, g_Now, keep 4200000000)
            → bit set + broadcast set (keep −0x5a91600)
```

When `mdt_Summon_RegenLoc` fails, the slot allocated in that round is neither regenerated nor freed here; the next
`ShineServant::so_Routine` (§8.8) finds no master and frees it with reason 9 *(inferred: assumes the pool cleared
`ss_Master` and the mode of the previous occupant; not checked)*. The remaining servants of that cast are not made.

```pseudo
MiscDataTable::mdt_Summon_RegenLoc(row, i, caster, pos, out at, out dir) → bool  @ FUN_004a2f50
    (null row / caster / at / dir → assert "…MiscData_Skill NULL" / "Caster NULL" / "pRegenLoc NULL" / "pDirect NULL", false)
    at = RL_CASTER ? caster position : pos (RL_TARGET); other → "…mds_RegenLoc type default", false
    dir = caster's direction
    if RegenDistance == 0: return true                     # all servants on one spot
    dir = sr_ShineDirectCheck(dir + i × (180 / SummonNumber))   # spread evenly on a circle (2° units)
    goal = at + RegenDistance × (sin, cos)(dir) / 1024
    if so_FindBlockLocateFrom(caster, at, goal, RegenDistance, &p, mbi_IsMoveBlock) and p ≠ at: at = p; return true
    return false                                          # also when the free spot found is the centre itself

ShineServant::ShineServant()   ShineMob ctor; ss_MiscTable = &ShineObject::so_MiscTableDef           @ FUN_0055b340
ShineServant::so_mob_Regenerate(… same 14 args as ShineMob …)  (vt 0x6e0)                          @ FUN_004b4780
    r = ShineMob::so_mob_Regenerate(…) (§5.3); then vt 0xabc(mobdatabox[mobId].p_MobLifeTime)   # MobLifeTime row (§5.1)
    (wrong index → "MobDataBox::operator [] :Invalid mob index"); return r
ShineServant::so_mob_RegenComplete           (vt 0x6f4)  §8.8 (deathTime from the row, explosion state)

ShineServant::so_serv_SetMaster(master, row)                 (vt 0x988)          @ FUN_004a3c50
    if not master: return
    ss_Master = master;  so_mob_SetGuildRegNum (vt 0x900) = master's guild (vt 0x828)
    ss_AIType = row.AI;  tactic state (+0x22e4) by AI:
        SAI_ROOT → MobActionNoBrain (never moves or attacks)
        SAI_CHASE → mant_SetTarget(+0x2294, ss_TargetOfSummon) if a target is set (else unchanged)
        SAI_RAMPAGE → MobActionWander.maw_MetronomeReset (+0x2260) (normal mob AI: targets by aggro, §7.2)
        SAI_ROAM → MobActionRoaming.mar_Init (+0x24d8)
ShineServant::so_serv_SetTarget(t)  (vt 0x98c): ss_TargetOfSummon = t; +0x1d8c = t; state = mant_SetTarget(t)   @ FUN_00557120
ShineServant::so_serv_TargetOfSummonMob (vt 0xf78) = ss_TargetOfSummon                                @ FUN_00557110

ShineServant::so_serv_SetRoamingData(type, dir, spread, cx, cy)   (vt 0xc54)    @ FUN_0054a7c0
    ss_RoamingType = type; ss_RoamingDirect = dir; ss_RoamingDirectArea = spread; ss_RoamingCenterLoc = (cx, cy)
    ss_RoamingDirectMin / Max = dir ∓ spread (all through sr_ShineDirectCheck, 0…179)
ShineServant::so_serv_ServantRoaming(&dir, &dist) → bool          (vt 0xc58)    @ FUN_0054a840
    # asked by mab_RandomDirectWalk (§7.2) before it picks a random direction; ShineMob answers false
    RT_NONE: false
    RT_STRAIGHT: dir = ss_RoamingDirect; true                       # keeps walking away along the summon direction
    RT_RANDOM: r = Random(dist) + sqrt(…); a = RoamingDirect ± Random(DirectArea) (sign from rndbox[2])
        dir = direction from the servant to centre + r·(sin, cos)(a)/1024; dist = min(dist, distance to that point); true
ShineServant::so_serv_GetRoamingType (vt 0xc5c) = ss_RoamingType                                        @ FUN_0054a9f0

ShineServant::so_serv_InitFlag  (vt 0xde4)  ss_Flag.MobCanDamageTo = 0   (called by ShineMob::so_mob_RegenComplete FUN_004424f0 and ShinePet::spt_RegenComplete FUN_00442eb0) @ FUN_0054af60
ShineServant::so_serv_SetMobCanDamageTo(b) (vt 0xde8) / so_serv_GetMobCanDamageTo (vt 0xdec)   @ FUN_0054af70 / FUN_0054af90
ShineServant::so_serv_SetFlag(name, v)     (vt 0xde0): name "MobCanDamageTo" → SetMobCanDamageTo(v); other names ignored   @ FUN_0054afa0
cSetServantFlag(handle, flagName, value) → nothing                                @ FUN_005e4be0
    o = GetObject(handle); o.vt[0xde0](flagName, value)   # other classes: no-op slot
```

With `MobCanDamageTo` set the servant uses the mob hit rule instead of its master's (§8.4).

**Everything else answers for the master** (null master → the mob value):

| Slot | Function | Servant |
|---|---|---|
| 0x4d8 | `so_GetLevel` FUN_00557000 | master's level, else `sm_MobLevel` (+0x1f94) |
| 0x510 | `so_AttackRange` FUN_00557020 | 0 for `SAI_CHASE` (the homing servant only explodes), else ShineMob's |
| 0x560 | `so_PartyRegistNumber_InAttack` FUN_004811c0 | master's party (vt 0x550), else 0xFFFF |
| 0x564 / 0x568 | `so_GetCharRegistNumber_ItemLooter` FUN_00481200 / `so_GetZoneHandle_ItemLooter` FUN_00481230 | master's char number / handle (drops of its kills go to the master, §11) |
| 0x5c4 | `so_GetExperienceFromMob` FUN_0042adc0 | forwards the EXP to the master (vt 0x5c4) |
| 0x72c | `so_mobile_IsEnemy` FUN_004308b0 | master's answer; no master → false |
| 0x8cc | `so_mobile_BattleCamp` FUN_00556f70 | master's camp; else from `sm_MobIsPlayerSide` (+0x2548, −1 → MobInfo.IsPlayerSide +0x67): 0 / 3 → BC_MOB 1, 1 / 2 → BC_CHAR 2 |
| 0x9b8 | `so_mob_CanBeAttackedByPlayer` FUN_004a5c90 | player.vt[0x980](master) (a player may hit the servant iff it may hit the master); no master → true. Caller: `sp_NC_BAT_BASHSTART_CMD` FUN_00430fa0 (Z03) |
| 0xe08 | `so_GetKQTeamType` FUN_00557190 | master's KQ team; else the brief's team byte (+0x1f74 → +0x93) |
| 0xe60 | `so_IsAlliance` FUN_0054b100 | §8.4 |
| 0xf68 | `sm_IsPlayerSide` FUN_00557150 | master is a player; else +0x2548 / MobInfo.IsPlayerSide (asked by `ShineMob::so_IsAlliance` FUN_0054b050) |
| 0x700 | `so_mob_AppendAggro` FUN_0042d630 | §6.2 |
| 0x980 / 0xe94 | hit / heal rules | §8.4 |
| 0x984 | `so_MiscTable` FUN_005572e0 | `ss_MiscTable` |
| 0x4a4 | `so_RemakeHandle` FUN_00557040 | i < 500 ? i + 21638 : 0xFFFF |

**End of life.** `so_Routine` (§8.8) frees the servant with reason 9 when the master is gone (`so_serv_FindMaster`)
and with reason 10 at `deathTime`. Early ends go through vt 0xf7c:

```pseudo
ShineServant::sm_serv_VanishReserv(sec)                      (vt 0xf7c)          @ FUN_004a3490
    ss_ExplosionManager = Base;  deathTime (+0x1fbc) = g_Now + sec × 10
    vt 0x24 so_YouHaveAlreadyDead (FUN_00555780: dead flag +0x1d7c = 1)
    if it has a mob row: AxialListMobSuicide{alms_MobID = row.ID}.alms_SelfKill(self)
ShineServant::sm_TooLongChase()  (vt 0xf74, from the chase states §7.3) = vt 0xf7c(0)          @ FUN_004a3480
cVanishReserv(handle, sec) → nothing                                              @ FUN_005ede60
    o = GetObject(handle), not empty (vt 0x300); o.vt[0xc28]() (as mobile object) .vt[0xf7c](sec)   # no-op on non-servants

AxialListMobSuicide::alms_SelfKill(m)                                            @ FUN_004f1720
    if m.so_AmIAlreadyDead (vt 0x28: dead flag or HP 0): return
    hp = m.HP (vt 0x4e8); m.vt[0x5bc] so_KilledBy(m, hp, 1000, 1)         # killed by itself
    broadcast in sight (so_AllOfRange): 0x243C NC_BAT_DOTDAMAGE_CMD {
        object = m.handle, resthp = 0, damage = m.HP after the kill, abstate = 0x318 (MAX_ABSTATEINDEX: none),
        hpchangeorder = vt 0x7e8, IsMissDamage = 0 }
    so_DamageLog("alms_SelfKill"); m.vt[0x8d4] so_mobile_DeadCheck(4)
AxialListMobSuicide::ali_Work(it, me, o) → continue                              @ FUN_004f18b0
    if o is a mob (kind 5) and (alms_MobID == 0xFFFF or o's mob ID == alms_MobID): alms_SelfKill(o)
    # range users: cMobSuicide FUN_005e28c0 (part 10), Pine ShineSuicide FUN_004f1980 (§26.4)
```

`sm_serv_VanishReserv` sets the dead flag before it calls `alms_SelfKill`, which returns at once for a dead object:
a vanishing servant never gets the self-kill and its 0x243C death packet; it just stops (dead flag: no longer a
target, explosions stop) and disappears with 0x1805 at `deathTime` (original bug) Z09-B32 *(likely intent: kill
first, then mark)*.

### 13.4 Open points of this section

- The `namestring` copy in `bixd_Exchange` (receiver's name into a ring) has no reader; leftover debug code.
- `MiscDataTable`'s other tables (`AbStateReset`, `Neutralization`, `Polymorph`, `StateCondition`, `mdt_PostSkillBlast`
  FUN_004a3a90, `mdt_ArgumentLoad` FUN_004a6110, `mdt_FindAbStateAlways` FUN_004a2ef0) are skill side effects; see
  the coverage boundary of the sweep part.
- Lua event 0x90 (`LuaArgumentServantSummon`): the map event `ServantSummon`, §14.3.

---

## 14. Scripts 1: the Lua engine, script events, triggers, observers, timers

Part 9a of the plan. The zone embeds **Lua 5.2** (the "Lua 5.2" version string; `luaL_loadfilex`, `lua_pcallk`,
`lua_tonumberx`; `luaL_openlibs` opens base, bit32, coroutine, debug, io, math, os, package, string and table). Every
script file gets its **own `lua_State`**; there is no shared global state between files. `LUA_PATH` gets
`../9Data/Shine/LuaScript/?.lua` appended at start (`ZoneServer::zs_ServiceThreadFunction` FUN_005a9d90, Z01 §2), so
scripts `require` their helpers (`common.lua`, `ID/<map>/Functions/*.lua`) from that root. Lua arguments are read with
the plain Lua API (`lua_type`, `lua_tonumberx`, `lua_tolstring`); handles are passed as Lua numbers.

### 14.1 Script objects (`LuaScript`, 8 bytes) *(pdb2016)*

| Class | vt[1] (`ls_FuncSet`) | Use |
|---|---|---|
| `LuaScript` { +0 vftable, +4 `ls_LuaObject` (`lua_State*`) } | pure | base |
| `LuaScriptScenario` | FUN_005f5350: registers the 248 game functions of §14.9 (`lua_pushcclosure` + `lua_setglobal`) | AI scripts, pet scripts, map scripts (scenario books) |
| `LuaScriptSecurity` (`g_LUA_SCRIPT_SECURITY` DAT_14d6fdf0) | FUN_005d7ca0: the start-stage functions | the downloaded start script, Z01 §2.1 / §2.2 |

```pseudo
LuaScript::LuaScript / ~LuaScript                        @ FUN_005d6000 / FUN_005d7ff0 (lua_close if open)
LuaScript::ls_FromFile(s, path) -> bool                    @ FUN_005d6cc0
    if s.L: lua_close(s.L)
    s.L = luaL_newstate(); luaL_openlibs(s.L)
    if !s.vt[1]() (ls_FuncSet): return false                # functions are registered BEFORE the file runs
    return luaL_loadfilex(s.L, path) == 0 and lua_pcallk(s.L, 0, 0, 0) == 0   # runs the file's top level once
LuaScript::ls_FromString(s, text) -> bool                  @ FUN_005d6d40
    same, but runs the text first and registers the functions after it (start script, Z01)
LuaScript::ls_FunctionCall(s, funcName, arg) -> bool       @ FUN_005d7bc0
    lua_getglobal(s.L, funcName)
    nargs = arg.vt[1](s.L)                                  # lad_ArgumentSet: pushes the arguments (§14.4)
    nres  = arg.vt[3]()                                     # = arg.lad_ReturnNumber (0 or 1)
    if lua_pcallk(s.L, nargs, nres, 0) != 0: return false
        # the error value stays on the Lua stack: nothing pops it (original bug) Z09-B40. In Lua 5.2 every
        # later call grows the stack to fit, so each failure costs one slot of that state for good; after
        # LUAI_MAXSTACK (1 000 000) failures in one state every call fails with "stack overflow" (inferred)
    arg.vt[2](s.L)                                          # lad_ReturnSet, below
    return true
LuaScriptScenario::lss_FuncExec(s, funcName, arg) -> int   @ FUN_00461a90
LuaScriptScenario::lss_Routine(s, funcName, arg)           @ FUN_00507200   (same, returns nothing)
    if !ls_FunctionCall(s, funcName, arg):
        text = funcName + <2-byte separator> + LuaScriptScenario::ls_Pointer           # last cExecCheck marker
        AssertClass::ac_AssertFail("LuaScriptScenario::lss_FuncExec : function call error" | "…lss_Routine : …", text)
        LuaScriptObserver::lso_Send(&g_LuaScriptObserver, "function call error", text)  # §14.7
    return ok (lss_FuncExec only)
```

`LuaScriptScenario::ls_Pointer` (DAT_14d6fcf0, `char[256]`) holds the text of the last `cExecCheck(name)` call
(§14.6); scripts call it at the top of each function so that an error message names the function that ran last.

### 14.2 Where the script objects come from

| Source | Loader | Key / use |
|---|---|---|
| `../9Data/Shine/LuaScript/AIScript/<MobInfo.InxName>.lua` (23 files in 2016) | `AIScriptMobContainer::aismc_Load` FUN_006264b0 (start stage "tough", Z01 §2.3) | `g_AIScriptMobContainer` DAT_14d712d0 = `std::map<u16 MobInfo.ID, LuaScriptScenario*>`: one script per mob type that has a file (`fopen` test; a missing file means no script). Load error → assert "AIScriptMobContainer::aismc_Load : AIScript load error" and `ShineExit`. `ShineMob::so_mob_RegenComplete` gives each spawned mob / NPC the script of its ID (§5.2 `so_AIScript`) |
| `../9Data/Shine/LuaScript/PetSystem/<name>.lua` | `AIScriptPetContainer::aispc_Load` FUN_00626630; names from its ctor FUN_006270e0: `PAT_DUMMY` 0 → "PetDummy", `PAT_BASE` 1 → "PetBase" (`aispc_GetFileName` FUN_00626440) | `g_AIScriptPetContainer` DAT_14d712e0, `std::map<PET_AI_TYPE, LuaScriptScenario*>`; same error handling. Users (`ShinePet::spt_RegenComplete`, `&` reload) → Z13 |
| `../9Data/Shine/LuaScript/<book>.lua` | `ScenarioBookShelf::ScenarioBookLua::sb_Load` FUN_00507800 (file name `ScenarioBook::sb_GetFileName` FUN_00507440: extension "lua" → `LuaScript/`, else `ScenarioBookShelf/`) | the map scripts (`ID/*`, `KQ/*`, `Tutorial`, `Promote/*`): one state per scenario book; reached by name through `scenarioshelf` (`sbs_GetScenarioBook`; the shelf itself is part 14c) and attached to a map by `cSetFieldScript` or to an object by `cSetAIScript` (§14.6) |

Consequences for a rebuild:
- All mobs of one type **share one Lua state**: script globals are per mob type, not per mob. The 2016 scripts keep
  per-instance data in tables keyed by the handle passed as the first argument.
- A map script and the objects it controls usually share the scenario book's state: `cSetFieldScript(map, handle)`
  attaches the AI script of an object to the map, and `cSetAIScript(book, handle)` gives an object the book's state.

### 14.3 Script events: object events (`LuaAi`) and map events (`LuaField`) *(pdb2016)*

An object holds `so_AIScript` (`ShineObject::LuaAi`, obj+0x7e, 0xe4 bytes: script pointer + 8 `std::string`s, §5.2);
a map holds `fm_LuaScript` (`FieldMap::LuaField`, field+0x128, 0xc8 bytes: script pointer + 7 strings). Each string
is the **name of the Lua function** to call for one event. The "event numbers" the callers pass (0x20 click, 0x3c
menu answer, Z02 §6) are the **byte offsets of these strings** inside the struct. A script fills them with
`cAIScriptFunc` / `cFieldScriptFunc` (§14.6); the event names below are the keys those functions accept.

Object events (`ShineObject` vt 0xb68 `so_AIScriptFuncExec(offset, arg)` FUN_004ab3f0 "… 3", unless noted):

| Key (`cAIScriptFunc`) | Offset | Fired by | Argument (§14.4) | Lua call |
|---|---|---|---|---|
| `Entrance` | 0x04 | every tick of the owner: `ShineMob::so_Routine` (§5.4), `ShineNPC::so_Routine` (§5.9), `ShineEffectObject::so_Routine` (§13.2), `ShinePet::so_Routine` (Z13), through `lss_Routine` directly. `so_AILearn` sets it to "Entrance" (mobs: `MobInfo.InxName`, §6.8) | `LuaArgumentMobAI` | `f(handle, mapName)` → result: 2 = run the built-in AI (§5.4) |
| `NPCClick` | 0x20 | 0x200A NC_ACT_NPCCLICK_CMD on a mob (kind 5), door (7) or NPC with a script (Z02 §6.2) | `LuaArgumentNPCClick(npc, p, "")` | `f(npcHandle, playerHandle, charNo, "")` |
| `NPCMenu` | 0x3c | 0x2073 NC_ACT_NPC_MENU_CMD (Z02 §6.4; `Ack` = the chosen line); end of a script casting bar (§14.6, select 0) | `LuaArgumentNPCMenu(npc, p, select)` | `f(npcHandle, playerHandle, charNo, select)` |
| `MobDamaged` | 0x58 | `ShineMob::so_DamagedBy` FUN_00431750, after HP is lowered, when the name is set | `LuaArgumentMobDamaged(map, attacker, MaxHP, HP, mob)` | `f(mapName, attackerHandle, maxHP, curHP, mobHandle)` |
| `ObjectDied` | 0x74 | `ShineMobileObject::so_KilledBy` FUN_00432240 on the dead object itself, when the name is set | `LuaArgumentObjectDied(map, killer, dead)` | `f(mapName, killerHandle, deadHandle)` |
| `NPCAction` | 0x90 | `NPCAction::CallLuaAction::exe` FUN_005c1720 (proximity triggers, §16.5) | `LuaArgumentNPCAction(map, npc, player)` | `f(mapName, npcHandle, playerHandle, charNo)` |
| `MobAttack` | 0xac | `ShineMobileObject::smo_SwingDamage` FUN_00432f30 (melee), `SkillBlastEffect::sbe_BlastObject` FUN_00583bc0 / `sbe_BlastLocate` FUN_00584160 (skills) on the attacker, when the name is set | `LuaArgumentMobAttack(map, attacker)` | `f(mapName, attackerHandle)` |
| `RankingValue` | 0xc8 | **never fired** (the ranking event is the map's, below) | – | – |

Other entry points into an object's script:
- vt 0xb64 `so_AIScriptFuncExec(funcName, arg)` FUN_004aa1b0 ("…2"): a named function; used by the Lua triggers
  (§14.5) and by server-menu answers (`ServerMenuFuncter::smfm_LuaFuncExec`, §14.6).
- vt 0xb6c `so_AIScriptFuncExec(funcName, text)` FUN_004aa0b0: one string argument (`LuaArgumentFuncExec`); only the
  GM command `&luafuncexec <function> <text>` (`AmpersandCommand::ac_LuaFuncExec` FUN_00419760) on the GM's current
  target (player vt 0x75c `so_CurrentTargetObject`).
- vt 0xb70 `so_LuaFunctionSet(offset, name)` FUN_004ab4f0: stores a name (refused without a script); vt 0xc14
  `so_InitAIScript` FUN_00558c80 clears pointer and names.
- All three return 0 when the object has no script. **None of them checks that the name is set**: a click on a mob
  or door that has a script without `NPCClick`, a menu answer or casting-bar end without `NPCMenu` call Lua with
  the empty name; the call fails, is logged as "function call error" and leaves an error value on the stack
  (Z09-B40) (original bug) Z09-B41 (callers of 0x58 / 0x74 / 0xac do check).

Map events (`FieldMap::fm_LuaScriptFuncExec(field, offset, arg)` FUN_00463ae0: returns 0 without a script or with an
empty name, else `lss_FuncExec`):

| Key (`cFieldScriptFunc`) | Offset | Fired by | Argument | Lua call |
|---|---|---|---|---|
| `MapLogin` | 0x04 | 0x1803 NC_MAP_LOGINCOMPLETE_CMD `ShinePlayer::sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 (Z01) | `LuaArgumentPlayerLogin(map, p)` | `f(mapName, playerHandle)` |
| `ItemUse` | 0x20 | `ShinePlayer::smo_ply_ItemUse` FUN_0053fd10 (Z04) | `LuaArgumentPlayerItemUse(map, p, itemID)` | `f(mapName, playerHandle, itemID)` |
| `Tutorial` | 0x3c | `ShinePlayer::sp_NC_CHAR_TUTORIAL_STEP_ACK` FUN_00576480 (sender 0), `GameDBSession::gds_NC_CHAR_TUTORIAL_STEP_SAVE_ACK` FUN_00468a60 (sender 1) (Z07) | `LuaArgumentTutorialStep(map, p, sender, step)` | `f(mapName, playerHandle, sender, step)` |
| `MapLogout` | 0x58 | `ShinePlayer::so_Unmark` FUN_00558900 (the player leaves the map) | `LuaArgumentPlayerLogout(map, p)` (same pushes as login) | `f(mapName, playerHandle)` |
| `ObjectDied` | 0x74 | `ShineMobileObject::so_KilledBy` FUN_00432240, when the map's name is set | `LuaArgumentObjectDied(map, killer, dead)` | `f(mapName, killerHandle, deadHandle)` |
| `ServantSummon` | 0x90 | `MiscDataTable::mdt_SkillBlast_Summon` FUN_004a7530 (servant created, §13.3) | `LuaArgumentServantSummon(map, servant, master)` | `f(mapName, servantHandle, servantIdxName, masterHandle)` (idx name: vt 0x894 `so_mobile_GetIdxName`) |
| `RankingValue` | 0xac | damage, kills and heals in a map whose name is set (table below) | `LuaArgumentRankingValue(map, p, dealt, taken, healed)` | `f(mapName, playerHandle, dealt, taken, healed)` (three u64 as Lua numbers) |

`RankingValue` producers (read from the pushes at the call sites; amounts are the event's value):

| Caller | Player credited | dealt / taken / healed |
|---|---|---|
| `ShineMob::so_DamagedBy` FUN_00431750 | the attacking player | damage / 0 / 0 |
| `ShineMob::so_KilledBy` FUN_00432760 | the killing player | killing blow / 0 / 0 |
| `ShinePlayer::so_DamagedBy` FUN_00431500 | the damaged player | 0 / damage / 0 |
| `ShinePlayer::so_KilledBy` FUN_00433be0 | the dead player | 0 / last damage / 0 |
| `SkillEffectApply::SkillDamageSender::sds_TemplateStore` FUN_005803c0 | the caster | damage / 0 / 0 (damage skill); 0 / 0 / heal (heal skill) |
| `ShineMobileObject::so_mobile_HPHealOverTime` FUN_0040e910 | the caster; the healed player | **heal / 0 / 0**; 0 / 0 / heal |
| `ShinePlayer::sp_HPStoneUse` FUN_00589180, `sp_UseAmountHP` FUN_0059c500, `so_ply_ItemEffect` FUN_0059c730 | the player | **heal / 0 / heal** |

Heal-over-time and item heals add the healed amount to *dealt* too (original bug) Z09-B39 *(likely intent: healed
only, as the skill-heal branch does)*. No 2016 script registers a `RankingValue` function, so the event is unused
with the shipped data (the instance-dungeon ranking lists use `cScore*`, Z14).

### 14.4 Argument objects (`LuaScriptArgument::*`) *(pdb2016)*

Base `LuaArgumentDefault` (0xc bytes): +0 vftable, +4 `lad_ReturnNumber` (0 or 1), +8 `lad_ReturnValue`. vtable:
[0] destructor, [1] `lad_ArgumentSet(L)` → number of pushed arguments, [2] `lad_ReturnSet` FUN_005d6dd0, [3] return
`lad_ReturnNumber`, [4] `lad_GetReturnValue` FUN_005d6dc0.

```pseudo
lad_ReturnSet(a, L):                                     @ FUN_005d6dd0
    a.lad_ReturnValue = -1
    if a.lad_ReturnNumber == 1:
        if lua_isnumber(L, -1): a.lad_ReturnValue = (int) lua_tonumber(L, -1)
        lua_settop(L, -2)                                 # pops the one result
```

Common pushes: `mapName` = the map's 12-byte `fm_MapID` as a string ("" without a map), a missing object or player
pushes −1, `charNo` = `so_GetCharRegistNumber` (player vt 0x344).

| Class (ctor, ArgumentSet) | Members | Pushes | Results |
|---|---|---|---|
| `LuaArgumentMobAI` (FUN_005d6ef0, FUN_005d6f20) | +0xc `lamai_HostHandle`, +0x10 `lamai_Map` | handle, mapName | 1 |
| `LuaArgumentInstanceDungeon` (FUN_005d6e20, FUN_005d6e40) | +0xc `laid_FieldMap` | mapName | 1; users `Movie::Theater::t_Routine` ("Main") and `Movie::CinemaComplex::cc_DropFilm` ("InstanceDungeonClear") → §27.3 |
| `LuaArgumentFuncExec` (FUN_005d6eb0, FUN_005d6ed0) | +0xc `lafe_Arg` | the string | 0 |
| `LuaArgumentNPCClick` (FUN_005d6fa0, FUN_005d6fd0) | +0xc `lanc_NPC`, +0x10 `lanc_Player`, +0x14 `lanc_String` | npc handle, player handle, charNo, string (all −1 and "" if either object is null) | 0 |
| `LuaArgumentItemUse` (FUN_005d70b0, FUN_005d70e0) | +0xc NPC, +0x10 player, +0x14 `lanc_UseItem` | npc, player, charNo, item ID | 0 |
| `LuaArgumentNPCMenu` (FUN_005d71e0, FUN_005d7210) | +0xc `lanm_NPC`, +0x10 `lanm_Player`, +0x14 `lanm_SelectMenu` | npc, player, charNo, select | 0 |
| `LuaArgumentPlayerLogin` / `…PlayerLogout` / `…MobAttack` (FUN_005d7310 / FUN_005d7630 / FUN_005d7870; one ArgumentSet FUN_005d78a0) | +0xc map, +0x10 player / object | mapName, handle | 0 |
| `LuaArgumentPlayerItemUse` (FUN_005d7340, FUN_005d7370) | +0xc map, +0x10 player, +0x14 `lapiu_ItemID` | mapName, player, item ID | 0 |
| `LuaArgumentMobDamaged` (FUN_005d7410, FUN_005d7450) | +0xc map, +0x10 `lamd_Object` (attacker), +0x14 `lamd_nMaxHP`, +0x18 `lamd_nCurHP`, +0x1c `lamd_Defender` | mapName, attacker, MaxHP, HP, defender | 0 |
| `LuaArgumentTutorialStep` (FUN_005d7540, FUN_005d7570) | +0xc map, +0x10 object, +0x14 `lats_nSender`, +0x15 `lats_nStep` | mapName, handle, sender, step | 0 |
| `LuaArgumentObjectDied` (FUN_005d7660, FUN_005d7690) | +0xc map, +0x10 `laod_KillerObject`, +0x14 `laod_DeadObject` | mapName, killer, dead | 0 |
| `LuaArgumentNPCAction` (FUN_005d7740, FUN_005d7780) | +0xc map, +0x10 NPC, +0x14 player | mapName, npc, player, charNo | 0 |
| `LuaArgumentServantSummon` (FUN_005d7930, FUN_005d7960) | +0xc `lass_pMap`, +0x10 `lass_pServant`, +0x14 `lass_pMaster` | mapName, servant, servant idx name, master | 0 |
| `LuaArgumentRankingValue` (FUN_005d7a40, FUN_005d7a90) | +0xc map, +0x10 player, +0x18 / +0x20 / +0x28 u64 dealt / taken / healed | mapName, player, dealt, taken, healed | 0 |

`LuaArgumentDefault` itself (no arguments) is the static `LuaScriptArgument::lsa_NoLuaArgument` (DAT_00870de8).

### 14.5 Lua triggers (`LuaFuncTrigger`): chat, jump and item use near an object

Three global vectors of `TriggerElement` (0x4c bytes: +0 vftable, +4 `te_NPC` (`ShineObject*`), +8 `te_Function`
`char[64]`, +0x48 `te_RangeSquar`): `LuaFuncTrigger::g_FuncTrigger_Chat` DAT_0d5745c8, `g_FuncTrigger_Jump`
DAT_0d5745b8, `g_FuncTrigger_UseItem` DAT_0d5745a8 (emptied by their static initializers FUN_00696460 / FUN_006964c0 /
FUN_00696520). The classes `TriggerChat` / `TriggerJump` / `TriggerUseItem` share the layout (ctors FUN_004901f0 /
FUN_00490230 / FUN_00490270).

```pseudo
cTriggerRegist(objHandle, kind, funcName, range)          @ FUN_005f4c50
    obj = som_GetObject(objHandle); require obj, kind, funcName and range ≥ 0, else return nothing
    element = { te_NPC = obj, te_Function = funcName (strncpy 63), te_RangeSquar = range² }
    kind "Chat" → g_FuncTrigger_Chat; "Jump" → g_FuncTrigger_Jump; "ItemUse" → g_FuncTrigger_UseItem; else return nothing
    push_back; return 1

FuncTrigger<T>::ft_Find(list, player, out) -> count       @ FUN_00541470 (one body for all three lists)
    out = every element e with TriggerElement::te_TriggerEvent(e, player)   @ FUN_004901c0
          (e.te_NPC and player set and so_DistanceSquar(e.te_NPC, player) < e.te_RangeSquar)

producers (Z02 §2.4 / §3.1, Z04):
    0x2024 NC_ACT_JUMP_CMD      sp_NC_ACT_JUMP_CMD FUN_0045a250:  for e in ft_Find(Jump):  TriggerJump::tj_PullTheTrigger(e, p)        @ FUN_00490830
    0x2001 NC_ACT_CHAT_REQ      sp_NC_ACT_CHAT_REQ FUN_0045a400:  for e in ft_Find(Chat):  TriggerChat::tc_PullTheTrigger(e, p, text) @ FUN_00490720
    item use                    sp_NC_ITEM_USE_REQ FUN_005416b0:  for e in ft_Find(UseItem): TriggerUseItem::tui_PullTheTrigger(e, p, item.ID) @ FUN_00490910
pull(e, p, x):
    if e.te_NPC: e.te_NPC.so_AIScriptFuncExec(e.te_Function, arg)          # vt 0xb64: the NPC's own script
        arg = LuaArgumentNPCClick(npc, p, chat text | "")  or  LuaArgumentItemUse(npc, p, itemID)
        → f(npcHandle, playerHandle, charNo, text | itemID)
```

Nothing ever removes an element (only the static initializers clear the vectors): a trigger outlives its object, and
because objects are pooled (`som_FreeObject`) the stored pointer later designates whatever object reuses that slot;
registering twice fires twice (original bug) Z09-B36. No 2016 script calls `cTriggerRegist`, so the feature is idle
with the shipped data.

### 14.6 Lua functions of the script infrastructure

All return nothing (0 results) on a missing or wrong argument, else push `1` unless stated.

```pseudo
cAIScriptFunc(handle, event, funcName)                    @ FUN_005f05f0
    obj = som_GetObject(handle); event ∈ {"Entrance" 4, "NPCClick" 0x20, "NPCMenu" 0x3c, "MobDamaged" 0x58,
        "ObjectDied" 0x74, "NPCAction" 0x90, "MobAttack" 0xac, "RankingValue" 0xc8}, else return nothing
    if obj.so_LuaFunctionSet(offset, funcName) (vt 0xb70: false without a script): return 1

cFieldScriptFunc(mapName, event, funcName)                @ FUN_005e0f90
    field = FieldContainer::fc_FindMap(&fieldlist, mapName)
    event ∈ {"MapLogin" 4, "ItemUse" 0x20, "Tutorial" 0x3c, "MapLogout" 0x58, "ObjectDied" 0x74,
        "ServantSummon" 0x90, "RankingValue" 0xac}
    if FieldMap::fm_LuaFunctionSet(field, offset, funcName) (FUN_00465250, false without a map script): return 1

cSetFieldScript(mapName [, handle | bookName | nil])       @ FUN_005e0dd0
    field = fc_FindMap(mapName)
    arg 2: none → script = null;  number → the AI script of som_GetObject(handle) (object must exist);
           string → scenarioshelf.sbs_GetScenarioBook(name).vt[0x10]() (the book's LuaScriptScenario; must exist)
    FieldMap::fm_LuaScriptLearn(field, script)             @ FUN_004651b0
        field.fm_LuaScript.LuaScript = script; if script == null: all 7 event names = ""
        # a new script keeps the old names
    return 1
    (FieldMap::fm_GetLuaScript FUN_004012c0 returns &field.fm_LuaScript)

cSetAIScript(bookName, handle)                            @ FUN_005dc050
    book = sbs_GetScenarioBook(bookName); obj = som_GetObject(handle)
    obj.so_AILearn(book.vt[0x10]())                       # vt 0xb60 (§6.8): Entrance = "Entrance" / InxName
    return 1
cAIScriptSet(handle [, sourceHandle])                     @ FUN_005eef50
    obj = som_GetObject(handle)
    arg 2 not a number: obj.so_AILearn(null)               # clears the script and all names (vt 0xc14)
    else src = som_GetObject(sourceHandle); src.so_AITraining(obj)   # vt 0xb5c: obj learns src's script
    return 1

cServerMenu(playerHandle, npcHandle, title, text1, func1 [, text2, func2 …])   @ FUN_005dab40
    p = som_GetObject(playerHandle).vt[0xbbc]() (the object as a player, else null)
    sp_ServerMenuTitle(p, title)
    for each (text, func) pair while both are strings:
        data = ServerMenuArgument.sma_LuaInterface { u16 smli_NPCHandle = npcHandle, char smli_LuaFunction[20] = strncpy(func, 20) }
        sp_ServerMenuItem(p, ServerMenuFuncter::smfm_LuaFuncExec, text, data)
    sp_ServerMenuOpen(p, priority 0, npc 0xFFFF, no position, range 1000)          # 0x3C01, Z02 §6.5
    return 1
ServerMenuFuncter::smfm_LuaFuncExec(p, data)              @ FUN_0050f290   (the player chose that line)
    npc = som_GetObject(data.smli_NPCHandle); if npc:
        npc.so_AIScriptFuncExec(data.smli_LuaFunction, LuaArgumentNPCClick(npc, p, ""))   # vt 0xb64
    # the function name is not terminated when it has 20 characters (strncpy into an uninitialised
    # stack copy); 2016 scripts use short names ("LinkToVillage", "GateDummy")

cCastingBar(playerHandle, npcHandle, ms, animation)        @ FUN_005dd120
    p = som_GetObject(playerHandle).vt[0xbbc](); npc must exist
    ShinePlayer::sp_CreateCastingBar(p, npcHandle, ms, animation)                  @ FUN_005762a0
        npc = som_GetObject(npcHandle); require npc, animation, dist²(npc, p) < 20001
        require (0x78 & (1 << p.mode)) == 0                # modes 3, 4, 5, 6 refuse (cmc_AllowMode 0x78)
        p.so_ply_AllCastCancel() (vt 0x8d0); p.so_mobile_StopHere() (vt 0xa48)
        p.sp_CastingBarTargetHandle (+0x2aacc) = npcHandle; brief.sAnimation = animation (32)
        TimeScheduler::ts_Set(p.sp_TimerStr, sp_Schedule_CastingBar, TSCW_MISC, ms)
        sight incl. p ← 0x2074 NC_ACT_ANIMATION_START_CMD { u16 nHandle = p, char sAnimationIndex[32] = animation }
        p ← 0x2047 NC_ACT_CREATECASTBAR { u16 millisec = ms }
    return 1
ShinePlayer::sp_Schedule_CastingBar(p)                     @ FUN_00576100   (timer end)
    if p.sp_CastingBarTargetHandle != 0xFFFF and npc = som_GetObject(it) and dist² < 20001 and mode allowed (as above):
        npc.so_AIScriptFuncExec(0x3c NPCMenu, LuaArgumentNPCMenu(npc, p, 0))       # the NPC's script gets "menu 0"
        sight incl. p ← 0x2075 NC_ACT_ANIMATION_STOP_CMD { nHandle = p, sAnimationIndex = brief.sAnimation }
        sp_CastingBarTargetHandle = 0xFFFF; brief.sAnimation = ""
    # otherwise nothing is reset or sent: the handle and the animation stay (original bug) Z09-B38
ShinePlayer::sp_CastingBarFree(p)                          @ FUN_00570bd0   (only caller: so_ply_AllCastCancel FUN_0055a310, Z03)
    if p.sp_CastingBarTargetHandle != 0xFFFF:
        handle = 0xFFFF; clear p.sp_TimerStr (no callback)
        p ← 0x2048 NC_ACT_CANCELCASTBAR (so_SendProtocol(8, 0x48), no payload)
        brief.sAnimation = ""; sight incl. p ← 0x2075 { p, sAnimationIndex = brief.sAnimation }  # already ""
        # (original bug) Z09-B37: the name is cleared before it is copied, so 0x2075 carries ""
```

Client (2016): 0x2074 `On_NC_ACT_ANIMATION_START_CMD` FUN_0049d120 plays the named action on the character; 0x2075
`On_NC_ACT_ANIMATION_STOP_CMD` FUN_0049d150 stops the current action **only if its name equals `sAnimationIndex`**;
0x2047 shows the cast bar (FUN_00499c10), 0x2048 removes it (FUN_004d8f90). With Z09-B37 a cancelled script cast
leaves the character in the animation on every client.

```pseudo
cTimer(mapName, seconds)                                  @ FUN_005dd310
    field = fc_FindMap(mapName); centre = FieldMap::fm_GetCenterObject(field); require centre
    every player of the map (so_AllInMap) ← 0x6C16 NC_SCENARIO_TIMER_CMD { u16 nSecond = seconds }; return 1
cTimer_Obj(playerHandle, seconds)                          @ FUN_005dd4b0
    obj must be a player (vt 0x4d0 == 2): obj ← 0x6C16 { u16 nSecond } through so_GetDataSocketStream (vt 0x2f8); return 1
cTimerStart(handle | mapName)                              @ FUN_005eb5a0   (returns nothing in all cases)
    number ≠ 0xFFFF: a player that is not empty (vt 0x300 so_IsEmpty) ← 0x6C21 NC_SCENARIO_TIMER_START_CMD
    string: every player of the map ← 0x6C21
    # payload 1 byte: PROTO_NC_SCENARIO_TIMER_START_CMD is empty (C++ size 1); the byte is not written (stale)
cTimerEnd(handle | mapName, seconds)                       @ FUN_005eb770   (returns nothing)
    same targets ← 0x6C22 NC_SCENARIO_TIMER_END_CMD { u32 nDeleteSec = seconds }
```

Client: 0x6C16 `GameFrameWork::On_NC_SCENARIO_TIMER_CMD` FUN_0049d100 resets the instance-dungeon time window
(`IDTimeWin::ResetTime(nSecond)`); 0x6C21 FUN_004a62c0 starts and shows the event stop-watch (`EventTimeWin::Start`);
0x6C22 FUN_0049d4a0 stops it (`EventTimeWin::Stop(nDeleteSec)`: the window disappears after that many seconds).

```pseudo
tonumber(s)        @ FUN_005d81c0   replaces Lua's tonumber: atof(lua_tolstring(1)) → number (nil argument → nothing)
cExecCheck(name)   @ FUN_005d82a0   strcpy(LuaScriptScenario::ls_Pointer, name)         # no length limit:
                   # a name of 256+ characters runs into g_LUA_SCRIPT_SECURITY (DAT_14d6fdf0, the start-script
                   # state) right behind the buffer (original bug) Z09-B35; 2016 names are short
cDebugLog(text)    @ FUN_005d8350   lso_Send(&g_LuaScriptObserver, "QuestEvent : " + text)   (§14.7)
cAssertLog(text)   @ FUN_005d63a0   AssertClass::ac_AssertFail("", text)                    (server assert log)
```

### 14.7 The Lua observer (`g_LuaScriptObserver`, DAT_0087ef88)

`LuaScriptObserver` { +0 `lso_Observer` (`ShinePlayer*`), +4 `iso_RegistNumber` } (ctor FUN_005d5ef0 via the static
initializer FUN_00694f60: null, 0xFFFFFFFF). One GM at a time receives the Lua error and debug texts:

```pseudo
&luaobserver [x]   AmpersandCommand::ac_LuaObserver FUN_00419730:  empty argument → observer = null, else observer = the GM
LuaScriptObserver::operator=(o, p)                        @ FUN_005d5f00   (o.lso_Observer = p; o.iso_RegistNumber = p ? p.charNo : 0xFFFFFFFF)
LuaScriptObserver::lso_Send(o, text, detail)              @ FUN_005d5f30
    if o.lso_Observer and not so_IsEmpty (vt 0x300) and its charNo == o.iso_RegistNumber:
        o.lso_Observer.so_ply_Notice(detail ? text + "[" + detail + "]" : text)   # vt 0x784, a GM notice
        return true
    o = (null, 0xFFFFFFFF); return false                  # the GM left: stop observing
```

### 14.8 Player observers (`Observer`, `IObserver`) *(pdb2016)*

`ShinePlayer::observers_` (p+0x2a948, `std::vector<Observer>`, §2.6) holds `Observer` objects (0x18 bytes): +0 vftable,
+4 `master_` (`ShineObject*`, the watching object), +8 `next_` (`IObserver*`, the watcher logic), +0xc `birth_`
(`g_Now` at creation), +0x10 `tick_` (`Metronome {m_NextTick, m_TickInterval}`). The only `IObserver` implementation is
`NPCAction::Trigger` (proximity triggers, §16).

```pseudo
Observer::Observer(master, next)                          @ FUN_005cc5d0   (birth_ = g_Now; tick_ = (g_Now, 0)); default ctor FUN_005cc720
Observer::notify(o, _, player, ev, a, b, …)               @ FUN_005cc680
    if o.master_ == null: return 2                        # bit 1 = remove me
    if o.next_: return o.next_.vt[1](o.master_, player, ev, a, b, o.birth_, &o.tick_)
    return 0
Observer::needToAttach(o)                                 @ FUN_005cc6d0   (master and next set: next.vt[2]())
Observer::SetTick(o)                                      @ FUN_005cc6f0   (tick_ = Metronome(birth_, next.vt[3]()) = the trigger's condition tick)
Observer::operator==(a, b)                                @ FUN_005cc650   (same master_ and next_); ~Observer FUN_0043cb40
ShinePlayer::registerObsersver(p, o)      vt 0xa2c        @ FUN_00577f90   (SetTick, push_back; base ShineObject version FUN_00575fb0 does nothing)
ShinePlayer::unregisterObsersver(p, o)    vt 0xa30        @ FUN_00577b50   (std::remove of the equal entries)
ShinePlayer::unregisterObsersvers(p, master) vt 0xa34     @ FUN_00577ba0   (all entries of that master, §2.6)
ShinePlayer::hasObserver(p, master)       vt 0xa3c        @ FUN_00576d50   (true if an entry == Observer(master, null) under
                                                                              operator==, i.e. same master_ and next_ == null; the marker of §16.3)
ShinePlayer::notifyObservers(p, ev, a, b) vt 0xa38        @ FUN_00577c10   (§2.6)
```

`IObserver::Event` values and their producers (`notifyObservers(ev, a, b)`):

| Event | Value | Producer | a |
|---|---|---|---|
| `EV_IDLE` | 0 | `ShinePlayer::so_Routine` every tick (§2.1) | 0 |
| `EV_DIE` | 1 | `ShinePlayer::so_KilledBy` FUN_00433be0 | 0 |
| `EV_SKILL` | 2 | **no producer** | – |
| `EV_ABSTATE` | 3 | `ShinePlayer::so_AbnormalState_Set` FUN_004162d0 / `…_Set_CharAllMode` FUN_004165c0 | their 2nd argument (the abstate) |
| `EV_EMOTION` | 4 | `ShinePlayer::sp_DoEmotion` FUN_00458860 (Z02 §4) | emotion |
| `EV_DAMAGE` | 5 | `ShinePlayer::so_ply_CheckDamageAbsorption` FUN_00579860 | 0 |
| `EV_TICK_PARTY` | 6 | `ShinePlayer::so_Routine` after the skill check (§2.1) | 0 |
| `EV_LOCATION` | 7 | `ShineObject::so_MoveTo` FUN_00452a70 (Z02 §2) | 0 |
| `EV_ATTACKMOB` | 8 | `ShineMobileObject::smo_SwingDamage` FUN_00432f30, `SkillDamageSender::sds_TemplateStore` FUN_005803c0 | target handle |

Who registers observers (`NeighborhoodChecker::ali_Work` FUN_005c2fe0 via `hasObserver` / vt 0xa2c,
`NPCAction::doTriggers_` FUN_005c4880) and what the triggers do with the events: §16.3 / §16.4.

### 14.9 The Lua function table (`LuaScriptScenario::ls_FuncSet` FUN_005f5350)

248 registrations (247 functions: `cEmoticon` and `cEmotion` are the same function 005e3e60; `tonumber` replaces
Lua's own). The table lists every Lua name with its function address and where it is (or will be) documented; the
part split is the status file's plan (parts 10–13 may still move a function). FiestaHeroes' `fiesta.lua` lists 272
names for the NA build *(fh-doc)*; the 2016 zone registers only these.

| Documented in | n | Lua name, address (section / item when done) |
|---|---|---|
| already documented | 45 | `cAddCharacterTitle` 005eb310 W04, `cAggroList` 005f3250 §6.8, `cAggroListSize` 005f2f70 §6.8, `cAggroReset` 005e1280 §6.8, `cAggroSet` 005d9370 §6.8, `cCastTeleport` 005e5b10 §9.3, `cDoorAction` 005dc840 §13.1, `cDoorBuild` 005dc5f0 §13.1, `cDropFilm` 005d6b00 §9.2, `cDropItem` 005d9a30 §11.8, `cEffectRegen_Object` 005e4f30 §13.2, `cEffectRegen_XY` 005f0b50 §13.2, `cGroupRegen` 005efc60 §10.6, `cGroupRegenInstance` 005ddaa0 §10.6, `cGroupRegenInstance_XY` 005ddc40 §10.6, `cIndunRankResult` 005ee4d0 §28.12 (WM side W04 §13.3), `cMagicFieldSpread` 005f17c0 §12.2, `cMobChat` 005e2560 §8.7, `cMobRegen_Circle` 005e1ea0 §10.7, `cMobRegen_Obj` 005d8690 §10.7, `cMobRegen_Rectangle` 005e2100 §10.7, `cMobRegen_XY` 005d8440 §10.7, `cMobRegen_XY_Layer` 005e7680 §10.7, `cMobShout` 005dbcd0 §8.7, `cMobSuicide` 005e28c0 §13.3, `cMobWeaponRate` 005f3e30 §8.2, `cMoveLayer` 005e7c90 Z06, `cNPCRegen` 005de700 §5.9, `cNPCSkillUse` 005ef5c0 §8.1, `cNPCVanish` 005d8be0 §13.1, `cPet_IsMasterCalling` 005e9320 Z02, `cRegenGroupActiv` 005efdc0 §10.6, `cRewardItem` 005e17e0 Z05, `cRewardItem_AllInMap` 005e1b30 Z05, `cSaveTutorialInfo` 005e70b0 D05, `cSendGameLogDataType_4` 005f1a10 D05, `cSendGameLogDataType_5` 005f1d40 D05, `cSetItemDropMobID` 005ebea0 §11.8, `cSetNPCIsItemDrop` 005daf40 §11.8, `cSetNPCResist` 005db0a0 §5.8, `cSetServantFlag` 005e4be0 §13.3, `cSkillBlast` 005f0960 §8.1, `cSkillDamageCalculate` 005f1370 §8.1, `cTargetHandle` 005ef430 §6.8, `cVanishReserv` 005ede60 §13.3 |
| this section (§14.6) | 16 | `cAIScriptFunc` 005f05f0, `cAIScriptSet` 005eef50, `cAssertLog` 005d63a0, `cCastingBar` 005dd120, `cDebugLog` 005d8350, `cExecCheck` 005d82a0, `cFieldScriptFunc` 005e0f90, `cServerMenu` 005dab40, `cSetAIScript` 005dc050, `cSetFieldScript` 005e0dd0, `cTimer` 005dd310, `cTimerEnd` 005eb770, `cTimerStart` 005eb5a0, `cTimer_Obj` 005dd4b0, `cTriggerRegist` 005f4c50, `tonumber` 005d81c0 |
| §17 (part 10: object / mob control) | 57 | `cActByEventCode` 005eaa70, `cAnimate` 005dd690, `cAnimateForcedly` 005dd8a0, `cCharTitleAddValue` 005ded30, `cDamaged` 005f10d0, `cDePolymorph` 005e9210, `cDePolymorph_Area` 005f30d0, `cFollow` 005dc1f0, `cFreeStatInit` 005e7dc0, `cHeal` 005de540, `cHideOtherPlayer` 005e6a50, `cInvenItemDestroy` 005d63d0, `cItemErase` 005ecb40, `cKillObject` 005e6d40, `cLevelUp` 005e7590, `cLinkTo` 005dde20, `cLinkToAll` 005df4b0, `cLocationRotate` 005ed000, `cMapObjectControl` 005e2ad0, `cMobDetectRange` 005e80b0, `cMobIDFind` 005eee50, `cMove2Where` 005df6e0, `cMoveStop` 005edf90, `cPartyJoin` 005e3460, `cPartyLeave` 005e3610, `cResetAbstate` 005ef120, `cRevivalAll` 005ec100, `cRunTo` 005da040, `cRunToUntilBlock` 005da590, `cSetAbstate` 005d97a0, `cSetAbstateInArea` 005e2c40, `cSetAbstate_Range` 005f2560, `cSetCanUseReviveItem` 005e8520, `cSetCanUseReviveSkill` 005e8660, `cSetDeadDelayTime` 005de090, `cSetFreeBattle` 005ebfe0, `cSetMobAttr` 005e13d0, `cSetNPCParam` 005f0320, `cSetObjectDirect` 005e8fa0, `cSetReviveDelayTime` 005e8740, `cSetSightState` 005e7b80, `cSetTeamBattle` 005e83e0, `cStaticDamage` 005de8c0, `cStaticDamage_smo` 005e48f0, `cStaticMoverSpeed` 005debb0, `cStaticRunSpeed` 005ed3c0, `cStaticSpeed` 005dea30, `cStaticWalkSpeed` 005ed500, `cTargetChangeNull` 005d6b80, `cUseMoney` 005e6450, `cVanishAll` 005f0150, `cVanishTimer` 005e5840, `cViewSlotEquip` 005e3c00, `cViewSlotUnEquipAll` 005e3d40, `cWaitIdle` 005e7f70, `cWalkTo` 005da300, `cWillMovement` 005df340 |
| part 11 (queries, lists) | 60 | `cAbstateRestTime` 005ef750, `cCurSec` 005d8cd0, `cCurrentSecond` 005d8d60, `cDistanceSquar` 005d88c0, `cFindAttackBlockLocate` 005ee1a0, `cFindNearPlayer` 005f37d0, `cFindNearestMobList` 005e6eb0, `cGetAbstate` 005e5e20, `cGetAdminLevel` 005e42a0, `cGetAreaObject` 005dca40, `cGetAreaObjectList` 005f4620, `cGetAroundCoord` 005de220, `cGetBaseClass` 005deee0, `cGetCharNo` 005e4110, `cGetCoord_Circle` 005d6720, `cGetCurMapIndex` 005e59b0, `cGetCurrentSkillInfo` 005f2070, `cGetDirect` 005de400, `cGetItemIndex` 005e5cf0, `cGetItemLot` 005dad80, `cGetLevel` 005e0c90, `cGetMapName` 005e8d50, `cGetMaster` 005e32c0, `cGetMobID` 005e47b0, `cGetMoveState` 005e2f30, `cGetNPCHandle` 005d8df0, `cGetNearObjListByCoord` 005f4ef0, `cGetNearestObjByCoord` 005f3a50, `cGetObjectMode` 005d6880, `cGetPlayerList` 005f4410, `cGetPlayerName` 005d9240, `cGetRegistNumber` 005d6500, `cGetRunSpeed` 005ed140, `cGetScriptString` 005e8b30, `cGetTargetList` 005f0e40, `cGetWalkSpeed` 005ed280, `cGetWhoKillMe` 005ee350, `cIsEquipItem` 005e23b0, `cIsInArea` 005ead70, `cIsInMap` 005ef2c0, `cIsMovable` 005da9c0, `cIsNoAttacOrNoMove` 005eac30, `cIsObjectAlreadyDead` 005ee090, `cIsObjectDead` 005d94f0, `cMapMark` 005df860, `cMapMark_FieldSight` 005e0640, `cMapMark_Obj` 005dffc0, `cNearObjectList` 005f22e0, `cObjectCount` 005e26c0, `cObjectEffect` 005ea8b0, `cObjectFind` 005f33d0, `cObjectHP` 005d9630, `cObjectLocate` 005d9ef0, `cObjectLocateDirection` 005e4d80, `cObjectSound` 005ea6f0, `cObjectType` 005f04b0, `cPermileRate` 005da8b0, `cPlayerExist` 005d8aa0, `cRandom` 005ed640, `cRandomInt` 005eed70 |
| §19 (part 12: messages, dialogs, effects) | 36 | `cCameraMove` 005dbe30, `cCameraMove_Obj` 005e7920, `cDelDirectionalArrow` 005e89d0, `cDirectionalArrow` 005e8810, `cEffectMsg` 005e4540, `cEffectMsg_AllInMap` 005e4670, `cEffectTimer` 005e6bb0, `cEmoticon` 005e3e60, `cEmotion` 005e3e60, `cEndCinematicText` 005eeb30, `cMapFog` 005e6260, `cMessage` 005ef8f0, `cMobDialog` 005db690, `cMobDialog_FileName` 005e4a00, `cMobDialog_Obj` 005db860, `cMobDialog_Range` 005dbaa0, `cMobDialog_String` 005ece70, `cNPCChat` 005efaa0, `cNPCChatTest` 005db4b0, `cNPCMenuOpen` 005dcf50, `cNotice` 005e15b0, `cNoticeRedWarningCode` 005e5ff0, `cNoticeString` 005e16e0, `cNotice_Obj` 005e8e50, `cPlaySound` 005e4410, `cScriptMessage` 005dcbe0, `cScriptMessage_Obj` 005dcd80, `cScriptMessage_Range` 005f27e0, `cScriptMsg` 005ebb40, `cScriptMsg_World` 005eb970, `cShowCinematicText` 005eec40, `cSimpleChatScriptMsg` 005ea530, `cSomebodyShout` 005e5150, `cStartMsg_AllInMap` 005e3af0, `cSystemMessage_Obj` 005e6890, `cTopView` 005e6600 |
| part 13 (rest) | 0 | none: checked in part 13 (the 248 `lua_setglobal` names of FUN_005f5350 = the 248 names of this table, and every address is cited as `FUN_…` in a pseudocode or knowledge file) |
| Z13 (pets) | 8 | `cPet_ChangeMind` 005ea1d0, `cPet_GetActionRecord` 005e9d00, `cPet_GetMind` 005e9520, `cPet_GetRunSpeed` 005e9b10, `cPet_GetStress` 005e9720, `cPet_GetWalkSpeed` 005e9920, `cPet_SaveTendency` 005ea410, `cPet_Unsummon` 005d65a0 |
| §28.12 (scores, rankings; part 18 — was "Z14", which no plan line supports) | 8 | `cScoreBoard` 005ed860, `cScoreBoard_AllInMap` 005edad0, `cScoreInfo` 005e3790, `cScoreInfo_AllInMap` 005e3970, `cScoreResultList` 005ec6a0, `cScoreTopList` 005ec1f0, `cSendRankingList` 005eaee0, `cWinter_Event_ScoreBoard_AllInMap` 005edcf0 |
| Z15 (quests, rewards, tutorial) | 11 | `cClassChangeOpen` 005ed720, `cGetQuestHero_ItemUse` 005d9140, `cGetQuestHero_NPC` 005d8f60, `cGetTutorialInfo` 005e7450, `cProgressTutorial` 005e72f0, `cQuestMobKill` 005d6010, `cQuestMobKill_AllInMap` 005d6150, `cQuestResult` 005e30d0, `cQuestResult_Individual` 005ecca0, `cReward` 005df060, `cRewardItem_CharInven` 005d6a10 |
| Z16 (kingdom quests) | 7 | `cEndOfKingdomQuest` 005df1f0, `cGetKQLimitSecond` 005e5390, `cGetKQTeamType` 005e81c0, `cIsKQJoiner` 005e82d0, `cKQRewardIndex` 005e4000, `cShowKQTimerWithLife` 005e54f0, `cShowKQTimerWithLife_Obj` 005e5690 |

Part 17d (§31.2) moved the tutorial functions to Z07; part 18 (review) documents the score / ranking functions here (§28.12).

FiestaHeroes' `fiesta.lua` *(fh-doc)* has 272 names; 245 of them are registered by the 2016 zone. Not in 2016 (part 13):
`cViewEquip` is the 2016 `cViewSlotEquip` under another name, `InstanceDungeonClear` is a Lua function the script
defines (`cc_DropFilm` calls it, §14.4 / §27.3), and the other 25 are C functions the NA private server added (FH marks
most "Hook only"): `cAddFame`, `cAddMoney`, `cFinishKey`, `cGainFame`, `cGainMoney`, `cGetClass`, `cGetExactClass`,
`cGetExactTime`, `cGetExp`, `cGetItemPower`, `cGetTarget`, `cHasSubAbstate`, `cKickout`, `cObjectSP`, `cPartyMembers`,
`cPartyMembersZone`, `cPlayerStatSkilled`, `cPlayerStatTotal`, `cPostDiscord`, `cRevive`, `cRoar`, `cSendRoar`,
`cSendShout`, `cShout`, `cStartKey`. They are not documented (no 2016 code). The 2016 names FH lacks: `cEmoticon`
(alias), `cViewSlotEquip`, `tonumber`.

### 14.10 Open points of this section

- `RankingValue` (map event 0xac): no 2016 script sets it, so its intended meaning of the three values is not
  confirmed by data (Z09-B39 is read from the call sites only).
- `hasObserver` compares with `next_ == null`: answered in §16.3 (it matches the marker `Observer(me, null)` that
  `ali_Work` registers).
- `cTimer_Obj` sends through the player's data stream (vt 0x2f8), the other timer functions through the game stream
  (vt 0x2fc); what separates the two streams is Z01's.
- `cmc_AllowMode` 0x78 refuses player modes 3–6 for casting bars; the mode names are Z02's.

## 15. Scripts 2: script interrupts and script areas

Part 9b of the plan. A **script interrupt** is an event a map script waits for: an NPC click, a player entering an
area, a death, a timer, an HP threshold, a GM call. Only **Pine** map scripts (`.ps` scenario books, `PSFilm`) have
them; Lua map scripts get their events through the `LuaField` / `LuaAi` functions of §14.3 instead. In 2016 33 scenario
books under `9Data/Shine/ScenarioBookShelf/` (guild tournament, KQs, instance dungeons, job change, wedding, OX field,
quest maps) use them. The Pine statements themselves (`interruptset`, `waitinterrupt`, `interrupterase`,
`interruptclear`) are documented here because they are the whole API; the rest of the Pine engine is part 14, the
`Movie::*` film objects §27.

### 15.1 Objects *(pdb2016)*

| Object | Layout | Role |
|---|---|---|
| `Movie::CinemaComplex` (field+0x44 `fm_Multiflex`, 0x12e798) | `List<Movie::FilmCase>` + `cc_FilmCase[8]`, `cc_PSFilm[8]`, `cc_LuaFilm[8]` | the films (running scripts) of a map instance; §27.1 |
| `Movie::FilmCase` (0x108) | +0 `fc_ScriptName`, +0x100 `fc_ScriptID`, +0x104 `fc_Film` | one list entry |
| `Movie::FilmBase` / `PSFilm` / `LuaFilm` (0x12df4) | +4 `fb_Theater` | vt[1] `fb_ScriptInterrupt`, vt[2] `fb_SetInterruptClear`: PSFilm FUN_00507ae0 / FUN_00508f00; `FilmBase` and `LuaFilm` have the folded no-op FUN_00509900 in both slots |
| `Movie::Theater` (0x12df0) | +0 `t_SenarioType`, +4 `t_LuaScript`, +8 `t_Screen` (Pine process stack), +0x1023c `t_TimeLimit`, **+0x1024c `t_InterruptManager`**, +0x12ce4 `t_ScriptName`, +0x12de4 `t_ScriptID`, +0x12de8 `t_Field`, +0x12dec `t_CenterFlag` (the map's `ShineAxialFlag`, §12.7) | the run state of one script |
| `ScriptInterrupt::ScriptInterruptManager` (0x2a98) | `List<ScriptInterruptArgument>` (0x18, 20 entries) + +0x18 `sim_ArgArray[20]` | the interrupts of one theater; ctor FUN_0050d270 (`l_MakeList` FUN_0050d0f0 with 20, then binds slot i to `sim_ArgArray[i]`), dtor FUN_00509a90 / FUN_0050c070 |
| `ScriptInterrupt::ScriptInterruptArgument` (0x220) | +0 `sib_Instance` (the kind singleton), +4 `sib_InterruptBlock` (`PineScriptToken`, 256 chars: the name of the block to call), +0x104 `sib_InterruptBlast` (u8: event seen, not yet consumed), +0x108 `sib_BlastNumber` (fires left), +0x10c `sib_InterruptIndex` (`Name4`, 16 chars: the script's name for the interrupt), +0x11c `sib_Argument` (union, 0x104, below) | one interrupt; ctor FUN_005098c0, `operator=` FUN_00509a10 |
| kind singletons `si_AreaEntry`, `si_AreaLeave`, `si_NPCClickHandle`, `si_NPCClickIndex`, `si_NPCClickAny`, `si_ObjectDeadHandle`, `si_ObjectDeadIndex`, `si_Interval`, `si_HPLow`, `si_HPUpper`, `si_HPFull`, `si_MobEliminate`, `si_PlayerEliminate`, `si_GuildEliminate`, `si_TimeOut`, `si_KillEnemy`, `si_TargetChange`, `si_PlayerDead`, `si_PickUpItemIndex`, `si_Admin` | 4 bytes (vftable only) | one class per kind, derived from `ScriptInterruptBase` (pure vt[0]) |

`sib_Argument` members used per kind (union `ScriptInterruptArgument::<sib_Argument>`): `area {char areaname[32],
u16 player +0x20, int num +0x24}`, `npcclickhandle {u16 npchandle, u16 clicker}`, `npcclickindex {char npcindex[32],
u16 npchandle}`, `npcclickany {u16 npchandle}`, `objdeadhandle {u16 victim}`, `objdeadindex {char mobindex[32], u16
victim}`, `interval {int tick, u32 nexttick}`, `hplow` / `hpupper {u16 objhandle, int hprate +4, u32 maxhp +8}`,
`killenemy` / `HPRecover` / `detectenemy {u16 mobhandle}`, `targetchange {u16 mobhandle, u16 targethandle}`,
`playerdead {u16 victim}`, `guild {u32 regnum, u32 DelayTime, u32 StartTime}`, `pickupitem {u16 itemindex, u16
owner}`, `admin {char callblock[256], u16 admin +0x100}`. Event data (`InterruptHappenArgument`, 0x104):
`npcclick {char index[32], u16 npc}`, `area {char areaname[32], u16 player}`, `objdead {u16 victim, char
victimindex[32], u16 murdurer +0x22, char murdurerindex[32]}`, `targetchange {u16 mobhandle, u16 targethandle}`,
`pickupitem {u16 itemindex, u16 owner}`, `admin {char callblock[256], u16 admin}`, `Event {InterruptEventArgument*
pEvent}`, `HPRecover {u16 mobhandle}`.

Container and destructor boilerplate (no logic): `~ScriptInterruptArgument` FUN_005098f0, `List<ScriptInterruptArgument>`
dtors FUN_005099b0 / FUN_005099d0 and `l_PushA` / `l_PushZ` / `l_PopA` / `l_PopZ` FUN_0050bf50 / FUN_0050bf90 / FUN_0050bfd0 /
FUN_0050c020 (copy with `operator=`; the interrupt code itself only uses `l_AllocZ` and `l_Free`), `ListEraser<…>` dtor
FUN_004f8a00, `InterruptEventArgument` / `InterruptEventWinGuild` dtors FUN_00478d50 / FUN_00478ee0, `ScriptInteruptWinGuild`
dtor FUN_0050d0c0, the atexit destructors of the two singletons FUN_0069e840 / FUN_0069e850. The rest of
`Movie::CinemaComplex` (ctor FUN_00509330, dtors FUN_00507d40 / FUN_005086a0, `cc_SetArgument` FUN_005086d0,
`cc_IsDuringPlay` FUN_00508fc0, `cc_PlayFilm`, `cc_DropFilm`) is §27.

Kind vtable (`ScriptInterruptBase`, 10 slots; unused slots = no-op FUN_00509900):

| Slot | Method | Classes with a body |
|---|---|---|
| 0x00 | `sib_BlastCheck(arg, outBlock, outArgument, timeLimit, list, listIndex, centerFlag)` → fired? | every kind (§15.4) |
| 0x04 | `sib_AreaEntry(arg, happen)` | AreaEntry FUN_0050bbf0 |
| 0x08 | `sib_AreaLeave` | AreaLeave FUN_0050bcd0 |
| 0x0c | `sib_NPCClicked` | NPCClickHandle FUN_0050b580, NPCClickIndex FUN_0050b600, NPCClickAny FUN_0050b710 |
| 0x10 | `sib_ObjectDead` | ObjectDeadHandle FUN_0050b980, ObjectDeadIndex FUN_0050ba00, KillEnemy FUN_0050ba90, PlayerDead FUN_0050bb10 |
| 0x14 | `sib_TargetChange` | TargetChange FUN_0050b880 |
| 0x18 | `sib_ItemPickedUp` | PickUpItemIndex FUN_0050bed0 |
| 0x1c | `sib_AdminInterrupt` | Admin FUN_0050b780 |
| 0x20 | `sib_HPFull` | HPFull FUN_0050b900 |
| 0x24 | `InterruptEvent(arg, InterruptEventArgument*)` | `ScriptInteruptWinGuild` FUN_00509910 (§15.6) |

### 15.2 Setting an interrupt: Pine `interruptset`

Script form: `interruptset <flag> <index> <count> [a0 [a1 [a2]]].`, e.g. `interruptset HPLow "BossHPLow" 1 Boss 500
"onBoss_HP50Percent".` (node members: +0x24 flag identifier, +0x30 index, +0x34 count, +0x38/+0x3c/+0x40 up to three
argument expressions; a missing one gives an empty token).

```pseudo
PineEventScriptNode::ShineInterruptSet::sa_Step(node, stack)          @ FUN_004ec1e0 (ctor FUN_004e85e0, clone FUN_004e91a0)
    flag  = lower(node.flag token)                                   # PineScriptToken::pst_ToLower FUN_004d6240: flags are case-blind
    if !eval(node.index): assert "…ShineInterruptSet::sa_Step : No Index"; pop; return
    index = Name4(first 16 chars of the index)                       # "" is allowed and common
    if !eval(node.count): assert "…ShineInterruptSet::sa_Step : No num"; pop; return
    count = number(count);  a[0..2] = eval(argument expressions)
    t = stack.theater
    switch flag (table below)                                        # each setter calls sim_Alloc
    pop                                                              # continue with the next statement

ScriptInterruptManager::sim_Alloc(m, index, kind, block, count) -> arg | null      @ FUN_00509b10
    slot = m.list.vt[2] l_AllocZ()                                   # appended at the END of the list
    if !slot: assert "ScriptInterrupt::ScriptInterruptManager::sim_Alloc : Too many ScriptInterrupt"; return null
        # max 20 interrupts per running script; the 21st is silently not set
    slot.sib_Instance = kind; slot.sib_InterruptBlock = block (256 bytes); slot.sib_InterruptBlast = 0
    slot.sib_BlastNumber = count; slot.sib_InterruptIndex = index
    # sib_Argument is NOT cleared: kinds that set only part of it see the previous user's bytes (Z09-B44)
```

| Flag | Kind (class) | Setter `@` | a0 / a1 / a2 | Stored | Use in 2016 scripts |
|---|---|---|---|---|---|
| `areaentry` | AreaEntry | `Theater::t_SetInterruptAreaEntry` FUN_004e7fe0 | area name / block | `area.areaname` (32, zero-padded); then **0x6C05 NC_SCENARIO_AREAENTRY_REQ `{char areaindex[32] = a0}`** to every object in the map of `t_CenterFlag` (`so_AllInMap1(flag, AxialListPacketBroadcast, 0)`; no flag → assert "Movie::Theater::t_AllInMap : Null flag", nothing sent) | 5 |
| `arealeave` | AreaLeave | `t_SetInterruptAreaLeave` FUN_004e8050 | area / block | same, packet **0x6C07 NC_SCENARIO_AREALEAVE_REQ** | 0 |
| `npcclickhandle` | NPCClickHandle | `t_SetInterruptNPCClickHandle` FUN_004e80c0 | NPC handle / block | `npcclickhandle.npchandle` | 58 |
| `npcclickindex` | NPCClickIndex | `t_SetInterruptNPCClickIndex` FUN_004e8110 | NPC index / block | `npcclickindex.npcindex` | 0 |
| `npcclickany` | NPCClickAny | `sim_Alloc` | block | — | 1 |
| `millisec` / `sec` / `minute` / `hour` | Interval | `t_SetInterruptTimeInterval` FUN_004e8180 → `sim_InterruptSet_SecondInterval` FUN_004e7dd0 (unit 'm' / 'S' / 'M' / 'H') | n / block | `tick` = n·10/1000, n·10, n·600, n·36000 tenths; `nexttick = g_Now + tick` (any other unit letter keeps the slot's old `tick`; no caller passes one) | `sec` 113 |
| `hplow` | HPLow | `t_SetInterruptHPLow` FUN_004e81c0 | object handle / rate (‰) / block | `objhandle`, `hprate`, `maxhp = 0` | 151 |
| `hpupper` | HPUpper | `t_SetInterruptHPUpper` FUN_004e8460 | same | same | 0 |
| `mobeliminate` | MobEleminate | `sim_Alloc` | block | — | 6 |
| `playereliminate` | PlayerEleminate | `sim_Alloc` | block | — | 128 |
| `guildeliminate` | GuildEleminate | `t_SetInterruptGuildEliminate` FUN_004e8230 | guild regnum / block / delay (tenths) | `guild.regnum`, `DelayTime`, `StartTime = 0` | 4 (`600`) |
| `timeout` | TimeOut | `sim_Alloc` | block | — | 141 |
| `deadhandle` | ObjectDeadHandle | `t_SetInterruptDeadHandle` FUN_004e8290 | handle / block | `victim` | 63 |
| `deadindex` | ObjectDeadIndex | `t_SetInterruptDeadIndex` FUN_004e82e0 → `sim_InterruptSet_ObjectDeadIndex` FUN_004e7eb0 | mob index or `_NONE_` / block | index ≠ "_NONE_": `mobindex` = a0, `victim = 0`; "_NONE_": only `victim = 0xFFFF` (= any death) | 50 (none with `_NONE_`) |
| `killenemy` | KillEnemy | `t_SetInterruptKillEnemy` FUN_004e8310 | handle / block | `mobhandle` | 0 |
| `targetchange` | TargetChange | `t_SetInterruptTargetChange` FUN_004e8360 | mob handle / block | `mobhandle` | 5 |
| `playerdead` | PlayerDead | `sim_Alloc` | block | — | 16 |
| `admin` | Admin | `t_SetInterruptAdmin` FUN_004e84d0 | — | block empty, **count forced to 9 999 999** | 7 |
| `pickupitemindex` | PickUpItemIndex | `t_SetInterruptPickUpItemIndex` FUN_004e8400 | item InxName / block | `itemindex` = ItemInfo ID (`itemdatabox.idb_btree[name]`; unknown name → 0xFFFF) | 10 |
| `hpfull` | HPFull | `t_SetInterruptHPFull` FUN_004e83b0 | mob handle / block | `mobhandle` | 0 |
| anything else | a registered *unit* (§15.6) | `sim_InterruptSet_Unit` FUN_0050d3b0 | block | index = the **flag** name, not the script's index; unknown flag → assert "…ShineInterruptSet::sa_Step : Invalid flag" | `WinGuild` 2 |

Usage counts: `interruptset` lines in the 2016 `.ps` files (first word after the statement, case folded).

### 15.3 Events: who raises them

Every event goes to all films of the map instance; each film's interrupts check whether the event is theirs and, if
so, only **mark** themselves (`sib_InterruptBlast = 1`, plus the value they pass on). Nothing runs until the script
reaches `waitinterrupt` (§15.4).

```pseudo
Movie::CinemaComplex::cc_ScriptInterrupt(cinema, simFunction, happen)         @ FUN_005088a0
    for each FilmCase fc in cinema (list order): fc.fc_Film.vt[1](simFunction, happen)
Movie::PSFilm::fb_ScriptInterrupt(film, simFunction, happen)                   @ FUN_00507ae0
    simFunction(&film.fb_Theater.t_InterruptManager (film+0x10250), happen)    # LuaFilm: no-op
FieldMap::fm_ScriptInterrupt(field, simFunction, happen)                        @ FUN_00419380
    jmp cc_ScriptInterrupt(field.fm_Multiflex (+0x44), …)

ScriptInterruptManager::sim_<event>(m, happen)     # all walk m's list in order and call the kind's event slot
    sim_AreaEntry FUN_0050ca60 (vt 4), sim_AreaLeave FUN_0050cb70 (vt 8), sim_NPCClick FUN_0050c3f0 (vt 0xc),
    sim_ObjectDead FUN_0050c950 (vt 0x10), sim_TargetChange FUN_0050c730 (vt 0x14), sim_PickUpItem FUN_0050cc80 (vt 0x18),
    sim_AdminInterrupt FUN_0050c500 (vt 0x1c), sim_MobHPFull FUN_0050c840 (vt 0x20),
    sim_UnitEvent FUN_0050c610 (vt 0x24, passes happen.Event.pEvent)
```

| Event | Raised by | `happen` | Documented |
|---|---|---|---|
| `sim_NPCClick` | `ShinePlayer::sp_NC_ACT_NPCCLICK_CMD` FUN_004c4b70 (0x200A), player in an allowed mode and on a field, **before** the NPC lookup | `npc` = packet handle; `index[32]` = **uninitialised stack** (Z09-B42) | Z02 §6.2 |
| `sim_AreaEntry` / `sim_AreaLeave` | `sp_NC_SCENARIO_AREAENTRY_ACK` FUN_0050cd90 (0x6C06) / `…AREALEAVE_ACK` FUN_0050cf00 (0x6C08) | `areaname` = packet (32 bytes), `player` = sender | Z02 §12 |
| `sim_ObjectDead` | `ShineMobileObject::so_KilledBy` FUN_00432240, only with a killer, victim on a field | `victim`, `victimindex` = victim vt 0x894 `so_mobile_GetIdxName` (MobInfo InxName; "" for players, FUN_00555110), `murdurer`, `murdurerindex` | Z03 §7.1 |
| `sim_TargetChange` | `ShineMob::sm_SetTarget` FUN_004b8930 on a change to a real target (not 0xFFFF) | `mobhandle`, `targethandle` | §6.5 |
| `sim_MobHPFull` | `ShineMob::sm_DuringRecover` FUN_0056b710 when HP and SP reach their targets | `mobhandle` | §6.5 |
| `sim_PickUpItem` | `ShinePlayer::so_ply_itempickresult` FUN_005308d0 on success (0x341) | `itemindex` = item ID, `owner` = player | Z05 §3.2 |
| `sim_AdminInterrupt` | GM command `&scrint <block>` (`AmpersandCommand::ac_ScriptInterrupt` FUN_0041abe0, stored by `ac_Store("&scrint", 10, …)` FUN_0041a310; the 10 is presumably the required admin level *(inferred)*): exactly one argument ("Called block needed"), GM on a map ("Null map") | `callblock` = the argument, `admin` = GM handle | here |
| `sim_UnitEvent` | `GuildTournamentSystem::GuildGroup::SendWinEventToScript` FUN_0047a580, through `fm_ScriptInterrupt` on the map of the group's manager user | `pEvent` → `InterruptEventWinGuild {RegNo = m_GuildNumber}` | Z16 (caller) |

What each kind does with its event:

```pseudo
NPCClickHandle::sib_NPCClicked(a, h)   @ FUN_0050b580:  if a.npchandle == h.npc: blast
NPCClickIndex::sib_NPCClicked(a, h)    @ FUN_0050b600:  if a.npcindex == h.index (32 bytes): a.npchandle = h.npc; blast
    # h.index is never filled by the click handler (original bug) Z09-B42: an npcclickindex interrupt never fires
NPCClickAny::sib_NPCClicked(a, h)      @ FUN_0050b710:  a.npchandle = h.npc; blast               # every click
AreaEntry::sib_AreaEntry / AreaLeave::sib_AreaLeave(a, h)   @ FUN_0050bbf0 / FUN_0050bcd0
    if a.areaname == h.areaname (32 bytes): a.player = h.player; a.num = 100; blast
ObjectDeadHandle::sib_ObjectDead       @ FUN_0050b980:  if a.victim == h.victim: blast
ObjectDeadIndex::sib_ObjectDead        @ FUN_0050ba00
    if a.victim == 0xFFFF or Name8::operator==(a.mobindex, h.victimindex) (FUN_00427d80):
        a.victim = h.victim; blast
    # "_NONE_" matches the first death only: afterwards a.victim is a handle and a.mobindex holds whatever the slot
    # held before (sim_Alloc does not clear it) (original bug) Z09-B44
KillEnemy::sib_ObjectDead              @ FUN_0050ba90:  if a.mobhandle == h.murdurer: blast
PlayerDead::sib_ObjectDead             @ FUN_0050bb10
    if ShineObjectHandleUnion::sohu_HandleSplit(h.victim) (FUN_00633650) == pool 2 (handles 8000…9499 = players):
        a.victim = h.victim; blast
TargetChange::sib_TargetChange         @ FUN_0050b880:  if a.mobhandle == h.mobhandle: a.targethandle = h.targethandle; blast
PickUpItemIndex::sib_ItemPickedUp      @ FUN_0050bed0:  if a.itemindex == h.itemindex: a.owner = h.owner; blast
HPFull::sib_HPFull                     @ FUN_0050b900:  if a.mobhandle == h.mobhandle: blast
Admin::sib_AdminInterrupt              @ FUN_0050b780:  a.callblock = h.callblock; a.admin = h.admin; blast
```

A blast flag stays set until a `waitinterrupt` consumes it; a second event of the same kind before that only
overwrites the stored value (one firing, the last handle).

### 15.4 Waiting: `waitinterrupt` and the per-kind checks

Script form, the same in every 2016 book: an endless loop `waitinterrupt InterruptBlock "InterruptArg". call
InterruptBlock.` The node stores into the two script variables the block name and the event value, and the script
then calls the block by name.

```pseudo
PineEventScriptNode::ShineWaitInterrupt::sa_Step(node, stack, state)        @ FUN_004ecd10 (ctor FUN_004e8620)
    if state == 0:                                                   # first step of this statement
        state = 1
        stack.ps_Shine.block    = variable named by node+0x24 (Identify::i_GetVariable)
        stack.ps_Shine.argument = ps_FindVariable(eval(node+0x30))  # the variable whose name is the string
    t = stack.ps_Shine.theater
    if sim_InterruptBlast(&t.t_InterruptManager, block, argument, &t.t_TimeLimit, t.t_CenterFlag, t.t_Field.fm_KQHandle):
        return ps_Pop(stack)                                         # go on: the next statement calls the block
    return 1                                                         # stay on this statement; checked again next step

ScriptInterruptManager::sim_InterruptBlast(m, outBlock, outArgument, timeLimit, centerFlag, kqHandle) -> bool   @ FUN_0050c100
    for each interrupt a in m (list order = order of interruptset):
        if a.sib_Instance.vt[0] sib_BlastCheck(a, outBlock, outArgument, timeLimit, m, a's list index, centerFlag):
            return true                                              # at most ONE interrupt fires per step
    return false                                                     # kqHandle is passed but unused
```

So the list order is the priority: an interrupt set earlier wins when two are ready in the same step; the other stays
marked and fires on a later step.

Common shape of `sib_BlastCheck` ("fire"): copy `a.sib_InterruptBlock` into `outBlock`; for kinds with a value,
clear `outArgument` and append the value as decimal text (`CeaseFireSender::CeaseFireSender` FUN_004d6300 = empty
token, `PineScriptToken::pst_MergeNumber` FUN_004d7310); `a.sib_BlastNumber -= 1`, and when it drops below 1 free the
slot (list vt 0xc `l_Free`); clear the blast flag; return true. Kinds without a value **leave `InterruptArg` as it
was** (the last value of another interrupt).

| Kind | `sib_BlastCheck` | Fires when | `InterruptArg` | Notes |
|---|---|---|---|---|
| AreaEntry | FUN_00509f70 | blast and `num > 0`: `num -= 1`; player object exists, mode ∉ {0, 3}, on a field, and `FieldMap::fm_AreaEntry(field, areaname, x, y)` (§15.7) | unchanged | the server re-tests the position with its own `.aid` up to 100 times (one per step) after the client's report. The blast flag is **not cleared** on firing (original bug) Z09-B43 |
| AreaLeave | FUN_0050a0f0 | same with `fm_AreaLeave` (not inside) | unchanged | Z09-B43 too |
| NPCClickHandle | FUN_00509e50 | blast | NPC handle | |
| NPCClickIndex | FUN_0050a270 | blast | NPC handle | never blasts (Z09-B42) |
| NPCClickAny | FUN_0050a390 | blast | NPC handle | |
| ObjectDeadHandle | FUN_0050a4b0 | blast | the handle | |
| ObjectDeadIndex | FUN_0050a5d0 | blast | victim handle | |
| KillEnemy | FUN_0050af40 | blast | unchanged | |
| PlayerDead | FUN_0050b170 | blast | victim handle | |
| TargetChange | FUN_0050b050 | blast | new target handle | |
| PickUpItemIndex | FUN_0050bdb0 | blast | picker handle | |
| HPFull | FUN_00509d50 | blast | unchanged | |
| Admin | FUN_0050b290 | blast | GM handle | `outBlock` = the **GM's** block name, not the stored one; the slot is freed after **every** firing (the 9 999 999 count is never used) |
| Interval | FUN_0050ab90 | `g_Now ≥ nexttick`; then `nexttick += tick` | unchanged | catch-up: after a long gap it fires on consecutive steps until `nexttick` passes `g_Now` |
| HPLow | FUN_0050aca0 | object gone → **fire and free** (whatever the count); else `rate = HP (vt 0x4e8) × 1000 / maxhp`, `maxhp` = vt 0x4f0 read at the first check and kept; `rate ≤ hprate` | unchanged | fires on every step while the HP stays low until the count runs out; maxhp 0 → rate 0 |
| HPUpper | FUN_0050b3e0 | same, `rate ≥ hprate` | unchanged | a vanished object also fires it |
| MobEliminate | FUN_0050a6f0 | no live mob left in the map: `so_AllInMap1(centerFlag, AxialListMobCounter{SearchAll, max 1}, 1)` counts 0 | unchanged | §15.7 counter rules |
| PlayerEliminate | FUN_0050a860 | no live player left (`ala_SearchPly`) | unchanged | |
| GuildEliminate | FUN_0050a9d0 | no live player of `guild.regnum` in the map; `StartTime` = first tick seen empty; fires when `g_Now ≥ StartTime + DelayTime`; a guild member present resets `StartTime = 0` | unchanged | the guild tournament's "other side left" rule |
| TimeOut | FUN_0050ae40 | `Movie::TimeLimit::tl_LeftTick(timeLimit)` FUN_00507f60 ≤ 0 | unchanged | `tl_LeftTick` also broadcasts 0x0810 NC_MISC_RESTMINUTE_CMD when the rest minute changes (§27.4) |
| unit (WinGuild) | `ScriptInterruptUnitBase::sib_BlastCheck` FUN_00509c30 | blast (after unit vt 0x2c, a no-op for WinGuild) | unit vt 0x30 `UpdateArgument`: the winning guild's number | §15.6 |

### 15.5 Removing interrupts

```pseudo
PineEventScriptNode::ShineInterruptErase::sa_Step(node, stack)      @ FUN_004ecb80   ("interrupterase <index>.")
    if !eval(node+0x30): assert "PineEventScriptNode::ShineInterruptErase::sa_Step"; pop; return
    sim_InterruptErase(&theater.t_InterruptManager, Name4(first 16 chars))
ScriptInterruptManager::sim_InterruptErase(m, index)                  @ FUN_0050c260
    free every interrupt whose sib_InterruptIndex equals index (16 bytes)     # "" erases all unnamed ones
PineEventScriptNode::ShineInterruptClear::sa_Step                     @ FUN_004f8b30   ("interruptclear [all].")
Movie::PSFilm::fb_SetInterruptClear(film)                             @ FUN_00508f00   (film vt[2])
    free all interrupts of the theater (ListEraser over the list)
    # vt[2] is called by Movie::CinemaComplex::cc_PlayFilm FUN_005089a0 and cc_DropFilm FUN_00509150 (§27.2 / §27.3)
```

A unit interrupt is stored under its flag name ("winguild", lower case), so `interrupterase` with the index the script
wrote does not find it. No 2016 script erases one.

### 15.6 Unit interrupts: the registry and `WinGuild`

`ScriptInterrupt::ScriptInterruptRegisterManager` (`GetInstance()::_ins`, `std::vector<ScriptInterruptUnitBase*>
m_vecInterrupts`) is a name → kind registry for kinds that are not built into `ShineInterruptSet`. The static
initializer `ScriptInterrupt::testInter` (FUN_00698320) registers the only one, the singleton
`ScriptInterruptUnit<ScriptInteruptWinGuild>::GetInstance()::_Instance` (class `ScriptInteruptWinGuild`, 8 bytes:
vftable + `RegNo`).

```pseudo
ScriptInterruptManager::sim_InterruptSet_Unit(m, flagName, args, count) -> bool          @ FUN_0050d3b0
    unit = ScriptInterruptRegisterManager::GetInterruptByName(registry, flagName as C string)   @ FUN_0050c380
        # first unit whose vt 0x34 GetName() _stricmp-equals the name; WinGuild: "WinGuild" (FUN_0050d090)
    if !unit: return false                                           # caller asserts "Invalid flag"
    sim_Alloc(m, index = flagName, unit, block = args[0], count); return true
ScriptInteruptWinGuild::InterruptEvent(w, a, event)                  @ FUN_00509910  (vt 0x24, from sim_UnitEvent)
    if a.sib_InterruptBlast != 1 and event.vt[1]() == 1 (EAT_GuildNo; folded body FUN_00557bb0 returns 1):
        a.sib_InterruptBlast = 1
        w.RegNo = event.RegNo                       # stored in the shared singleton, not in the interrupt
ScriptInteruptWinGuild::UpdateArgument(w, outArgument)               @ FUN_0050d0a0  (vt 0x30)
    outArgument = decimal(w.RegNo)
```

The winning guild number lives in one global object for all maps: when two guild-tournament maps report a winner
before their scripts reach `waitinterrupt`, both scripts read the later number (original bug) Z09-B45. Used by
`GuildTournament.ps` / `GuildTournament1.ps` (`interruptset WinGuild "" 1 "WinnerGuildCheck".`).

### 15.7 Script areas (`.aid`) and area queries

Each map's optional `<map>.aid` (23 files in 2016, 1–11 areas each, 32 circles and 62 rectangles) is loaded into
`MapBlockInformation.mbi_AreaData` (§9.2) by `AreaInfoData::Load` FUN_0062d990.

```pseudo
AreaInfoData { +4 IAreaData* m_pData[256], +0x404 u32 m_uiTotalDataCnt }   (ctor FUN_0062d870, dtor FUN_0062d950 / FUN_0062dc40)
IAreaData { +0 vftable (vt[0] IntersectTest(x, y)), +4 Name8 Name (32), +0x24 int nAreaType (0 CIRCLE, 1 SQUARE) }
AreaInfoData::Load(d, path) -> bool                                  @ FUN_0062d990
    missing file → false (no error); RemoveAll (FUN_0062d910)
    read u32 count; for i < count and i < 256:
        read char name[32], u32 type
        type 0: AE_Circle (0x34) { f32 fCenterX, fCenterY, fRadius }
        type 1: AE_Square (0x3c) { f32 fCenterX, fCenterY, fRadiusU, fRadiusV, fAngle (file: degrees → radians) }
        other: slot left null and nothing skipped (the file is misread from there; no 2016 file has one)
AreaInfoData::GetData(d, name) -> area | null                        @ FUN_0062d8a0
    linear search by the 32-byte name; stops at the first null slot
AE_Circle::IntersectTest(x, y)  = (x−cx)² + (y−cy)² < r²                              @ FUN_0062d740
AE_Square::IntersectTest(x, y)                                                       @ FUN_0062d7a0
    dx, dy = x−cx, y−cy;  u = dy·sin(a) + dx·cos(a);  v = dy·cos(a) − dx·sin(a)
    inside = |v| ≤ fRadiusV and |u| ≤ fRadiusU                       # half-widths; edges count as inside
FieldMap::fm_AreaEntry(field, name, x, y) = area exists and IntersectTest(x, y)        @ FUN_00427e80
FieldMap::fm_AreaLeave(field, name, x, y) = area exists and !IntersectTest(x, y)       @ FUN_00509950
    # an unknown area name is neither entered nor left
```

The client keeps its own copy of the areas: `GameFrameWork::On_NC_SCENARIO_AREAENTRY_REQ` / `…AREALEAVE_REQ`
(client FUN_004be410 / FUN_004be450) queue `AreaInfoMgr::AddRequestAreaTest(area, 1 entry | 2 leave)` (client
FUN_00661010); `AreaInfoMgr::Update` (client FUN_00661130, every frame) tests the own position with
`World::TestArea` and, at the first frame the condition holds, sends 0x6C06 / 0x6C08 **once** and drops the request.
So one `interruptset AreaEntry` gives at most one report per player that was on the map when it was set; a player who
arrives later never got the request (inferred from the code; no 2016 script re-sends it). A leave request is answered
at once by a player who is outside when it arrives.

Area and map counters used by the interrupts and by other script functions (all are `AxialListIterator`s run over a
map with `so_AllInMap1`, §12; `ali_Work` returning false stops the walk):

| Class `@` | Built by | Counts / collects |
|---|---|---|
| `AxialListMobCounter` (0x18: `almc_MobID`, `almc_GuildRegNum`, `almc_Counter`, `almc_MaxCount`, `almc_Search`), ctor FUN_004e2c70, `ali_Work` FUN_00427f10, `almc_HowMany` FUN_00461b70 | MobEliminate / PlayerEliminate / GuildEliminate checks (built inline), Pine `SysFunc*` (part 14c) | search chosen by the ctor: mob ID ≠ 0xFFFF → `ala_SearchMob` FUN_00427f30 (vt 0x708 mob ID equal, mode 0/1/2); else type `ALMC_PLAYER` 0 → `ala_SearchPly` FUN_00428020 (kind 2, mode 1/2/4/6), `ALMC_GUILD` 2 → `ala_SearchGld` FUN_004280a0 (player as before and vt 0x828 guild = regnum), otherwise `ala_SearchAll` FUN_00427fa0 (vt 0x89c `so_IsMob`, sub-layer ≠ 3 hidden, kind ≠ 10 servant, mode 0/1/2). Walk stops once `almc_Counter > almc_MaxCount` |
| `AxialListMobInAreaCounter` (0x40: the same + `almc_Areaname`, `almc_AreaInfo`, `almc_Field`), ctor FUN_004e2d00 | Pine `SysFuncShinePlayerInArea::sfb_Calculate` FUN_004e6150 (part 14c) | the same four searches FUN_00429370 / FUN_004293f0 / FUN_00429470 / FUN_004294f0, each also requiring `ala_InArea` FUN_00428260 (area looked up once from the first object's field; unknown area → nothing counts) |
| `AxialListAreaObjectList` (0x20: `alaol_Map`, `alaol_Area`, `alaol_ObjectType`, vector), ctor FUN_0042a390, `ali_Work` FUN_0042a7c0, `alaol_GetList` FUN_0042a970, `alaol_GetCount` FUN_00429df0 | Lua `cGetAreaObjectList` FUN_005f4620 (part 11), `cDePolymorph_Area` FUN_005f30d0 (part 10) | objects of kind `alaol_ObjectType` (vt 0x4d0) inside the area and not dead (mode ≠ 3) |
| `AxialListBanArea` (0x30: `alba_Map`, `alba_BanArea`, `alba_ToWhereMap`, `alba_ToWhereCoord`, vector), ctor FUN_0042a100, `ali_Work` FUN_0042a570, `alba_Banish` FUN_00429f70 | Pine `ShineBanFromArea::sa_Step` FUN_004f99c0 (part 15a) | players (kind 2) with `so_AdministratorLevel` (vt 0x4d4) 0 inside the area; `alba_Banish` then moves each with vt 0x890 `so_ply_BriefLink(toMap, toCoord)` |

Lua `cGetAreaObject` FUN_005dca40 and `cIsInArea` FUN_005ead70 (part 11) call `fm_AreaEntry` directly. The mini-house
functions (`ShineMiniHouse::so_mh_CompulsionMoveTo` FUN_00543a40, `so_mh_CreateFurniture` FUN_00544f00,
`so_mh_ReArrangeFurniture` FUN_00546150, `smh_SendFurnitureInfo` FUN_00546930) read the furniture areas
(`FURNITURE_ARE1…6`) of the same data: Z13.

### 15.8 Answers to the open questions (Z02 §5 / §12 / §15)

- **NPC clicks** reach scripts two ways: the clicked object's own AI script (event `NPCClick`, 0x20, §14.3) and every
  Pine film of the map (`sim_NPCClick`). Lua map scripts see clicks only through the object's script.
- **Area entry / leave** are Pine-only. The client reports, but the server does re-check: the report only arms the
  interrupt, which fires when `fm_AreaEntry` / `fm_AreaLeave` agrees with the server's own `.aid` geometry for the
  reported player (up to 100 polls). Z02-B12 ("the server does not check the position") is therefore too strong: a
  false report can make a player who is really inside count as the one who entered, but it cannot fire the
  interrupt for a player outside the area.
- The **map-script interrupts** never run script code at event time; a film reacts only at its next
  `waitinterrupt` step, one interrupt per step.

### 15.9 Open points of this section

- How often a film steps (and so how long the 100 area re-checks last) is answered in §27.3: one step per main-loop pass, so 100 passes.
- `so_AllInMap1`'s last argument (0 for the area requests, 1 for the counters) is passed through to the map's
  `fm_fp_AllInMap2` broadcast function; its meaning is not read here.

---

## 16. Scripts 3: NPCAction proximity triggers

Part 9c of the plan. An **NPCAction trigger** is a data-driven reaction of a mob or NPC to players near it: open the
map-link menu of a gate when a player walks up, buff or dispel a player who performs an emote next to a tree, take the
damage a player receives (multi-protect totems), feed a guild-tournament item box to the right team. No script runs
(except the `CallLua` action): a trigger is one **condition** and a list of **actions**, both taken from
`World/NPCAction.txt`, attached to a mob type by a file `MobSetting/Action/<MobInxName>.txt`. The mob's routine scans
its surroundings; for each player newly in range it tests the conditions once and, for the event-driven ones, leaves an
**observer** on the player (`ShinePlayer::observers_`, §2.6 / §14.8) that the player's own events (emotes, abstates,
damage, death, attacks, the tick) feed until the player walks out of range. All names *(pdb2016)*.

### 16.1 Data files and loading

`ZoneServer_zs_start_sleep` FUN_005b67c0 (Z01 §2) loads, in this order and ignoring every return value:

```pseudo
loadFromOptionReader<CondGen_OptionReader, Manager<ICondition>>(&conditionManager, "../9Data/Shine/World/NPCAction.txt")   @ FUN_005b5800
loadFromOptionReader<ActionGen_OptionReader, Manager<IAction>>(&actionManager,    "../9Data/Shine/World/NPCAction.txt")    @ FUN_005b58e0
NPCAction::Util::loadTriggers()                                                                                          @ FUN_005c4420

loadFromOptionReader<Gen, Manager>(mgr, file):              # both managers
    OptionReader.or_Read(file) (fails → return false, manager stays empty)
    n = Gen.size() = or_SelectCountFrom(Gen::tableName_)    @ FUN_005c2840 / FUN_005c16b0
    Manager::generate_n(n, Gen)                             @ FUN_005b4170 / FUN_005b4210   (deletes old entries; vector of n
                                                                pointers; row i → Gen() = createCondition_ / action factory)
```

`Gen::tableName_` are static strings set by the dynamic initialisers FUN_0069b1c0 (`"NPCCondition"`), FUN_0069b1a0
(`"NPCAction"`) and FUN_0069b280 (`"Trigger"`). `conditionManager` DAT_14d50794 and `actionManager` DAT_14d507a4 are
`Manager<T>` = one `std::vector<T*> container_`. **The ID columns are not read**: a trigger's `ConditionID` /
`ActionID` *n* is the *n*-th row of the table (`container_[n−1]`), so the rows must stay in ID order (they do in 2016).

| Table (file `World/NPCAction.txt`) | Row struct *(pdb2016)* | Columns |
|---|---|---|
| `NPCCondition` (20 rows) | `CondGen_OptionReader::ConditionData_` 0x95 | `u8 ConditionID`, `char ConditionA[33]` +0x01, `char TypeA[33]` +0x22, `u32 AX` +0x43, `u32 AY` +0x47, `char ConditionB[33]` +0x4b, `char TypeB[33]` +0x6c, `u32 BX` +0x8d, `u32 BY` +0x91 |
| `NPCAction` (50 rows) | `ActionGen_OptionReader::ActionData_` 0x4b | `u8 ActionID`, `char ActionIndex[33]` +0x01, `char Type[33]` +0x22, `u32 X` +0x43, `u32 Y` +0x47 |
| `Trigger` (one file per mob type, 57 files in `MobSetting/Action/`) | `TriggerGen_OptionReader::TriggerData_` 8 | `u32 ConditionID`, `u32 ActionID` |

**Condition factory** `CondGen_OptionReader::operator()` FUN_005c2e60 → `createCondition_(name = ConditionA, type =
TypeA, AX, AY, row, termLow = 0, termHigh = 0)` FUN_005c29c0. Names compared with `strncmp(…, 33)`:

```pseudo
if name == "Term":                           # a time window around another condition
    termLow = AX; termHigh = AY; name = ConditionB; type = TypeB; AX = BX; AY = BY
    while name == "Term": (same assignments)  # (original bug) Z09-B51: never ends if ConditionB is also "Term"
# terms are milliseconds in the file, stored as ticks: t × 10 / 1000
"AbState"         → ABStateCondition { index_ = dic_abstate[type] (fatal "CondGen_OptionReader : Invalid ABState" if unknown), termLow_, termHigh_ }
"LvGap"           → LvGapCondition { low_ = (u8)AX, high_ = (u8)AY }
"Class"           → ClassCondition { classID_ = ClassName.shn row whose acEngName (16 chars) == type }   (gClassName DAT_1328bc50;
                                      fatal "CondGen_OptionReader : Invalid Class Name" if none)
"Skill"           → SkillCondition { skillID_ = skillnametree[type] (fatal "Invalid Skill"), terms }   @ FUN_005c27b0
"Die"             → DeadCondition
"Emotion"         → EmotionCondition { emoticonID_ = (u8)AX, terms }                                    @ FUN_005c2800
"Default", "None" → NoneCondition { termLow_, termHigh_ }
"GTITeam"         → GT_TeamCondition { m_Team = AX }            (m_DelayTime +8 never written and never read)
"DmgAbsorb"       → DamageApplyCondition
"CheckCycleParty" → CheckCyclePartyCondition { m_Tick = AX }    (milliseconds; converted when the observer's Metronome is set)
"AttackMob"       → AttackMobCondition
"Location"        → LocationCondition { m_nInDistance = AX, m_nOutDistance = AY }   (no 2016 row uses it)
anything else     → assert "CondGen_OptionReader::createCondition_ : Unsupported Condition" (not fatal), then a
                    NoneCondition with the terms   # (original bug) Z09-B52: an unknown name becomes "fire at once"
```

**Action factory** `ActionGen_OptionReader::operator()` FUN_005c18c0 (compare order as listed; strings read from the
disassembly, the decompiler lost the compares):

| `ActionIndex` | Object | Built from |
|---|---|---|
| `Dispell` | `DispelAction { index_ }` | `dic_abstate[Type]` (fatal "ActionGen_OptionReader-Dispell : Invalid ABState") |
| `Link` | `InteractAction` | – |
| `Emotion` | `EmotionlAction { emoticonID_ }` | `(u8)X` |
| `AbState` | `AbStateAction { index_, strength_ }` | `dic_abstate[Type]` (fatal "…-Abstate : Invalid ABState"); strength = X, 0 and 1 → 1 |
| `Skill` | `SkillAction { skillIndex_ }` | `skillnametree[Type]` (fatal "ActionGen_OptionReader : Invalid Skill"); ctor FUN_005c0fe0 fatal "SkillAction::SkillAction : Invalid skill index" if `skilldatabox` has no row |
| `Notice` | `NoticeAction { std::string content_ }` | `Type` (ctor FUN_005c17f0) |
| `Die` | `DieAction` | – |
| `GTIEffect` | `GTItemAction` | – |
| `DmgAbsorb` | `DamageAbsorbAction` | – |
| `Ball` | `BallAction` | – |
| `RestoreRate` | `RestoreRateAction { nValue = X, eType }` | `Type == "HP"` → `eType = RT_SP` (1); any other `Type` (incl. `"SP"`) → `RT_HP` (0); the "Unsupported Action" exit is only reachable if `Type` equals both. (original bug) Z09-B46: HP and SP are swapped |
| `CallLua` | `CallLuaAction` | – |
| anything else | – | assert + `ShineExit("ActionGen_OptionReader : Unsupported Action")` |

`NoneAction` exists (vtable: no-op `exe`) but the factory never builds it. All actions share the destructor
FUN_005c1680 (`NoticeAction`: FUN_005c1870); `IAction::~IAction` FUN_005c0ee0. Conditions share FUN_005c2470
(`NoneCondition` scalar deleting destructor); `Trigger`'s is FUN_005c32b0. Reader ctors / dtors: `CondGen_OptionReader`
FUN_005c0ef0 (also used for the action reader), `~TriggerGen_OptionReader` FUN_005c3160.

**Triggers.** `NPCAction::Util::loadTriggers` FUN_005c4420:

```pseudo
for each file f in "../9Data/Shine/MobSetting/Action/*.txt" (_findfirst32; none → fatal "ZoneServer::zs_start_old : Invalid file path"):
    v = vector<Trigger>; if !loadFromOptionReader<TriggerGen_OptionReader, Trigger>(v, path): skip   @ FUN_005c4120
    name = f without its extension (cut at the last '.')
    mobId = mobdatabox.mdb_2MobID(name)                     @ FUN_00419080   (0xFFFF if no MobInfo row has that InxName)
    triggerDic.insert(mobId, v)                             # std::map<u16, vector<Trigger>> DAT_14d50784; a key already
                                                            # present keeps its first vector
TriggerGen_OptionReader::TriggerGen_OptionReader(reader)    @ FUN_005c4b90
    if or_SelectCountFrom("Trigger") < 1: fatal "TriggerGen_OptionReader : Invalid Table"
    walk the rows in order; consecutive rows with the same ConditionID form ONE Trigger:
        condition_ = conditionManager[ConditionID−1]  (0 / out of range / null → fatal "…Invalid condition(0|1). ConditionID")
        actions_  += actionManager[ActionID−1]         (fatal "…Invalid action(0|1). ActionID")
    so "1 27 / 1 28" is one trigger with two actions; a ConditionID that comes back after another one starts a new trigger
TriggerGen_OptionReader::size → number of triggers built   @ FUN_005c47c0;  operator() copies trigger i   @ FUN_005c4a10
```

Condition and action objects are shared: every trigger that names row *n* points to the same object, for every mob
type. They hold only configuration; per-player state lives in the observer (§16.3).

Five 2016 file names are not mob names (`B_Slime`, `KDSoccer_Ball`, `KDSoccer_Ball_14`, `KDSoccer_Invincible`,
`KDSoccer_SpeedUp`): they all map to key 0xFFFF (the first one read wins) and no mob ever uses them. Data residue,
harmless.

Mob link: `ShineMob::so_mob_RegenComplete` FUN_004424f0 sets `m.triggers_` (+0x24e8) = `&triggerDic[mobId]` or null
(§5.3); the `ShineMob` ctor FUN_0055b140 clears it. NPCs (`ShineNPC` derives from `ShineMob`) get it the same way.

### 16.2 Objects *(pdb2016)*

| Class | Size | Members | vtable (slot: function) |
|---|---|---|---|
| `IObserver` | 4 | – | 0 dtor, 1 `notify`, 2 `needToAttach`, 3 `GetConditionTick` (base: 0) |
| `NPCAction::ICondition : IObserver` | 4 | – | + 4 `check(player)` |
| `NPCAction::Trigger : IObserver` | 0x18 | +4 `condition_`, +8 `std::vector<IAction*> actions_` | 1 `notify` FUN_005c47e0, 2 `needToAttach` FUN_005c49d0 (= `condition_.needToAttach()`), 3 `GetConditionTick` FUN_005c49f0 (= `condition_.GetConditionTick()`); ctor FUN_005c49b0, dtor FUN_005c30f0 (frees only the pointer vector) |
| `NPCAction::IAction` | 4 | – | 0 dtor, 1 `exe(me, player)` |
| `NPCAction::doTriggers_` | 8 | +0 `me_`, +4 `target_` | functor, ctor FUN_005c47a0, `operator()` FUN_005c4880 |
| `NeighborhoodChecker : AxialListIterator` | 8 | +4 `triggerCollection_` (`vector<Trigger>*`) | 0 `ali_Work` FUN_005c2fe0; ctor FUN_005c2ee0, dtor FUN_005c2f00 |
| `Observer` (on the player) | 0x18 | §14.8 | – |

The other `std::` instantiations of `vector<Trigger>` / the `triggerDic` tree (FUN_005c2f60 `for_each`, FUN_005c3120…
FUN_005c4320, FUN_005c4ab0 `push_back`, FUN_004e7210 `vector<IAction*>::_Ufill`) are container boilerplate.

### 16.3 Running the triggers

```pseudo
ShineMob::so_Routine / ShineNPC::so_Routine (§5.4 / §5.9), every tick, if mode ≠ 3 (dead) and m.triggers_ ≠ null:
    so_AllOfRange(m, m.pos, range = MobInfoServer.DetectCha (row +0x3b), NeighborhoodChecker(m.triggers_))   @ FUN_0054bc80
        # range 0 = the map's sight (99999999 with wide sight or a moving camera) — see Z09-B49

NeighborhoodChecker::ali_Work(chk, me, o, dist²)                         @ FUN_005c2fe0   (returns 1: keep walking)
    if o == null or o.so_IsEmpty() (vt 0x300) or o.kind (vt 0x4d0) ≠ 2 (player): return
    if o.hasObserver(me) (vt 0xa3c, §14.8): return           # this player was already handled and has not left range
    o.registerObsersver(Observer(me, null))   (vt 0xa2c)     # the "already handled" marker (next_ = null)
    for each trigger t in chk.triggerCollection_: doTriggers_(me, o)(t)

NPCAction::doTriggers_::operator()(f, t)                                 @ FUN_005c4880
    if t.condition_ == null or t.condition_.check(f.target_) (vt 0x10):  # entry test
        for each a in t.actions_: a.exe(f.me_, f.target_)
    if t.needToAttach():                                                 # event-driven condition
        f.target_.registerObsersver(Observer(f.me_, t))                  # birth_ = g_Now; tick_ = Metronome(birth_, GetConditionTick ms)
```

`so_IsEmpty` (vt 0x300): player FUN_00559880 = about to disconnect (`sp_WillDisconnect`, or the socket session reports
closed); mob / NPC / servant FUN_00556610 = mode 3 (dead).

**Event delivery.** `ShinePlayer::notifyObservers(ev, a, b)` (§2.6) calls each observer; `Observer::notify` (§14.8)
returns 0 for the marker and otherwise `Trigger::notify(me, player, ev, a, b, birth_, &tick_)`:

```pseudo
NPCAction::Trigger::notify(t, me, player, ev, a, b, birth, tick)        @ FUN_005c47e0
    if t.condition_ == null: assert "NPCAction::Trigger::notify : null condition_"; return IObserver::notify(…)
    r = t.condition_.notify(me, player, ev, a, b, birth, tick)
    if r & 1: for each a in t.actions_: a.exe(me, player)       # fire
    return r                                                     # r & 2: notifyObservers destroys this observer
```

**Leaving range.** In `ShinePlayer::so_Routine` (§2.1, after the `EV_IDLE` notify and before `EV_TICK_PARTY`), each
observer whose owner is null or `so_IsEmpty` (dead mob, leaving player), or whose owner is farther than
`owner.so_getDetectRange()` (vt 0xa54: mobs FUN_00556c00 = the same `DetectCha`; base FUN_005551a0 = 1000), triggers
`unregisterObsersvers(owner)`: **all** entries of that owner go, the marker included. The next mob scan that finds the
player again runs the entry tests again. So: entry tests fire once per approach; event observers live from approach to
departure, the owner's death, or their own "remove" answer (bit 2). The marker answers the part-9a question: `hasObserver`
looks for `next_ == null`, and that entry is exactly the marker `ali_Work` registers.

(original bug) Z09-B49: with `DetectCha` 0 (2016: `IDLeviathanGate01`, `DT_RadionOre`) the scan covers the whole sight,
but the leave test compares d² with 0², so the player's next tick removes the marker and the mob's next tick runs the
entry tests again: `IDLeviathanGate01`'s `Default → Link` trigger calls `InteractWithNPC` for every player in sight on
every tick, and `DT_RadionOre`'s `AttackMob` observer only exists between the mob's scan and the player's next range
check *(inferred effect)*.

### 16.4 Conditions

`check` = entry test (`doTriggers_`); `attach` = `needToAttach` (observer kept on the player); `notify` = answer to the
player's events (1 fire, 2 remove, 3 both, 0 nothing). Every `notify` first returns 2 when `me` or the player is null or
`so_IsEmpty` (`AttackMob` checks only the player). Terms (`termLow`, `termHigh`, ticks) count from the observer's `birth_`;
`elapsed = g_Now − birth_`.

| Condition (file name) | check | attach | notify (event, a = event argument) @ |
|---|---|---|---|
| `NoneCondition` (`Default`, `None`, `Term`+`None`) | no term: true; with a term: false  @ FUN_005c24a0 | only with a term @ FUN_005c1f00 | `EV_IDLE` only: no term → 3; `elapsed < termLow` → 0; `elapsed > termHigh` and `termLow < termHigh` → 2 (window missed); else 3 (fire once). @ FUN_005c1e70 |
| `ABStateCondition` (`AbState`) | player has the abstate (vt 0x3e4 `so_AbnormalState_IsSet`) @ FUN_005c2510 | yes (FUN_005af8d0, folded `return true`) | `EV_ABSTATE` with `a == index_`: no term → 1 (fire, keep); with a term: `elapsed < termLow` → 0; in the window (`elapsed ≤ termHigh`, or `termHigh ≤ termLow`) → fire on match, keep; after the window → 2. @ FUN_005c1f20 |
| `SkillCondition` (`Skill`) | false (FUN_00615e70, folded `return false`) | yes | as AbState with `EV_SKILL`, `a == skillID_` @ FUN_005c1fb0. (original bug) Z09-B50: nothing produces `EV_SKILL` (§14.8), so this never fires |
| `EmotionCondition` (`Emotion`) | false | yes | as AbState with `EV_EMOTION`, `a == emoticonID_` @ FUN_005c2090 (window logic read in the disassembly; the decompile is wrong) |
| `DeadCondition` (`Die`) | false | yes | `EV_DIE` → 1 @ FUN_005c2040 (the player died near the mob) |
| `LvGapCondition` (`LvGap`) | `low_ ≤ level (vt 0x4d8) ≤ high_` (`high_ < low_`: no upper bound) @ FUN_005c25f0 | no @ FUN_005c25e0 | `IObserver::notify` @ FUN_005c25d0 (never called) |
| `ClassCondition` (`Class`) | player's `CharClass` (vt 0x49c `so_CharacterClass`) `cc_IsDescendantsOf(classID_)` (vt 0x54) or `cc_ClassType() == classID_` (vt 0x38) @ FUN_005c26e0 | no (LvGap's) | LvGap's |
| `GT_TeamCondition` (`GTITeam`) | player on a guild-tournament map (`fm_GetGuildTournamentSystem`) and `GuildTournamentSystem::GetGuildRegIndex(player) == m_Team` @ FUN_005c2890 | no (FUN_004b8d20, folded `return false`) | same test on `EV_IDLE` → 1 @ FUN_005c2920 (unreachable: never attached) |
| `DamageApplyCondition` (`DmgAbsorb`) | false | yes | `EV_DAMAGE`: `master = me.vt 0x9b0` (servants: `so_serv_FindMaster`; every other class returns null → 2); fire (1) if master is the player, or (master's raid ≠ −1 and same raid as the player), or (master not in a raid, master's party ≠ −1 and same party); else 0 @ FUN_005c2120 |
| `CheckCyclePartyCondition` (`CheckCycleParty`) | false | yes; `GetConditionTick` = `m_Tick` (FUN_0045ff90, folded `return this+4`) | `EV_TICK_PARTY` and the observer's `Metronome` due (`m_Tick` ms, re-armed each time): same master / raid / party test as `DmgAbsorb` → 1 @ FUN_005c2220 |
| `AttackMobCondition` (`AttackMob`) | false | yes | `EV_ATTACKMOB` with `a == me.handle` → 1 (the player hit this mob) @ FUN_005c2330 |
| `LocationCondition` (`Location`) | false | yes | `EV_LOCATION`: d = `ddt_Distance(me − player)`; `d > m_nOutDistance` → 2; `d ≤ m_nInDistance` → 1 @ FUN_005c2390 (no 2016 row) |

`Metronome::operator unsigned char` FUN_004011c0 (due when `m_NextTick < g_Now`, then `m_NextTick += m_TickInterval`),
`Metronome::m_SetInterval(start, ms)` FUN_00401190 (interval = ms × 10 / 1000), ctor FUN_005ad7f0.

### 16.5 Actions

`exe(me, player)`; `me` = the mob / NPC that owns the trigger.

```pseudo
InteractAction::exe ("Link")                     @ FUN_005c0f10
    player.InteractWithNPC(me)   (vt 0xa20, Z02 §6.2: quest dialog, role action or 0x201C NC_ACT_NPCMENUOPEN_REQ)
    # used by the map-link gates: walking up to a gate opens its menu as if the player had clicked it
DispelAction::exe ("Dispell")                    @ FUN_005c0f30
    player.so_AbnormalState_Reset(index_)   (vt 0x650, Z03)
EmotionlAction::exe ("Emotion")                  @ FUN_005c0f50
    player.so_mobile_StopHere() (vt 0xa48, 0x2013 to sight); player.smo_ply_ReinforceStopHere() (vt 0xa50)
    player.sp_DoEmotion(player.handle, emoticonID_)   (vt 0xa40, Z02 §4: 0x2021 to sight; raises EV_EMOTION again)
AbStateAction::exe ("AbState")                   @ FUN_005c0fa0
    player.so_AbnormalState_Set_Simple(caster = me, index_, strength_, 1)   (vt 0x644, Z03)
SkillAction::exe ("Skill")                       @ FUN_005c1070
    if skillIndex_.sdi_Activ: target = (sdi_Activ.First == TARGET_ME) ? me : player
        me.sm_UseSkillSimple(skillIndex_, target, 0)   (vt 0xa44 FUN_0057d880, the cast wrapper Z03 names next to `smo_SkillBash_Casting`)
DieAction::exe ("Die")                           @ FUN_005c10c0
    if me.mode ≠ 3 and player's layer l_Sub ∈ {0, 1}:
        me.so_KilledBy(killer = player, dmg = me.HP, aggroRate 0, dropArg 1)   (vt 0x5bc, Z03: kill credit, quest kill, drops)
GTItemAction::exe ("GTIEffect")                  @ FUN_005c1120
    if both set, player's layer l_Sub ∈ {0, 1}, me.mode ≠ 3 and the player's map has a GuildTournamentSystem:
        GuildTournamentSystem::CreateItemEffect(gts, me, player, 0)   (Z16)
DamageAbsorbAction::exe ("DmgAbsorb")            @ FUN_005c11a0   (§16.6)
BallAction::exe ("Ball")                         @ FUN_005c1390
    if me.mode == 3 or me is moving (vt 0x610): return
    speed = player.so_mobile_MoveSpeed() (vt 0x7b0); if 0: return
    dist = (RandomBox[100] + 50) × speed / 100            # 50…149 % of the player's speed
    if rb_1000() < speed: dest = me.pos + a vector of length dist turned by rb_largerandom(360)°   # random kick
    else: dest = me.pos + (me.pos − player.pos) scaled to dist   (same spot: y += dist)            # pushed away
    if so_FindBlockLocate(me, dest, dist, &spot, mbi_IsMoveBlock) (§9.2):
        me.so_ReinforceMove(spot, speed × 2, 1, 0, 0)   (vt 0xa28, §9.3: a forced move, no animation)
    # (vector arithmetic garbled in the decompile; helper names VectorWithLength / vwl_Scale / v_Rotation)
RestoreRateAction::exe ("RestoreRate")           @ FUN_005c15f0
    switch eType:
        RT_HP: player.so_mobile_HPHealOverTime(me, MaxHP × nValue / 1000, 0x318)   (vt 0x734)
               # falls through (original bug) Z09-B47
        RT_SP: player.so_mobile_SPHealOverTime(me, MaxSP × nValue / 1000)            (vt 0x738)
    # with Z09-B46: a "RestoreRate HP" row restores SP only; a "RestoreRate SP" row restores HP and SP
NoticeAction::exe ("Notice")                     @ FUN_005c1700
    player.so_ply_Notice(content_)   (vt 0x784 FUN_005977e0):
        0x2011 NC_ACT_NOTICE_CMD { u8 unk (never written: (original bug) Z09-B54), u8 len = strlen & 0xFF, char text[len] }
        # the 2016 game scene shows it as an announce line "[Notice] %s" (GameFrameWork::On_NC_ACT_NOTICE_CMD
        #   FUN_004b5420, §19.3; corrected in part 12: C01 lists it as ignored, which holds only for the other scenes)
CallLuaAction::exe ("CallLua")                   @ FUN_005c1720
    if me has an AI script and its "NPCAction" function name is not empty:
        me.so_AIScriptFuncExec(0x90, LuaArgumentNPCAction(map, me, player))   (vt 0xb68, §14.3: f(mapName, npc, player, charNo))
```

### 16.6 Damage absorption (`DmgAbsorb`)

The only producer of `EV_DAMAGE` is the player's damage filter, called by the swing and skill damage paths of Z03
(`ShineMobileObject::smo_SwingDamage` FUN_00432f30, `SkillDamageSender::sds_TemplateStore` FUN_005803c0, through vt 0xbe8):

```pseudo
ShinePlayer::so_ply_CheckDamageAbsorption(p, dmg) → damage still to apply      @ FUN_00579860
    p.smo_SetFlagDamageAbsorb(0)   (vt 0xbf0, smo_Flag bit 7)
    if dmg < 1: sp_nDamageAbsorb = 0; sp_nRemainingDamageAbsorb = 0; return dmg
    sp_nDamageAbsorb = dmg (vt 0xbdc); sp_nRemainingDamageAbsorb = dmg (vt 0xbe4)
    p.notifyObservers(EV_DAMAGE)                   # every DmgAbsorb trigger of a protector in range fires
    sp_nDamageAbsorb = 0
    return sp_nRemainingDamageAbsorb               # vt 0xbe0

DamageAbsorbAction::exe(me, p)                                                     @ FUN_005c11a0
    if me null, me.mode == 3, me.so_AmIAlreadyDead (vt 0x28), p null, p.mode == 3 or p dead: return
    absorb = p.so_ply_GetDamageAbsorb()  (vt 0xbd8 FUN_0055a720); if absorb < 1: return
    left = me.HP − me.so_batobj_GetDamage() (vt 0x65c, damage already queued)
    if absorb < left:
        me.so_DamagedBy(me, absorb, 1000)          # the protector takes all of it (attacker = itself)
        p.so_ply_SetRemainingDamageAbsorb(0); flag = 1
    else:
        me.so_KilledBy(me, left, 1000, 1)          # it dies, the rest goes through
        p.so_ply_SetRemainingDamageAbsorb(absorb − left); flag = 0
    p.smo_SetFlagDamageAbsorb(flag)                # smo_SwingDamage skips its own 0x2448 when the flag is set (Z03)
    so_AllOfRange(me, me.pos, range 0 = sight, AxialListPacketBroadcast, except me.handle *(inferred: last argument)*):
        0x2449 NC_BAT_SOMEONESWING_DAMAGE_CMD { u16 attacker = p.handle, u16 defender = me.handle,
                 u8 flag (bits 0–2 cleared; bits 3–7 left from the previous packet in the shared buffer: (original bug) Z09-B53),
                 u32 resthp = me.HP, u16 hpchangeorder = me.so_mobile_GetHPChangeOrder() (vt 0x7e8),
                 u8 damageindex = 1, u8 attacksequence = 0 }           # 13 bytes; client FUN_004a2850 (layout in `packets-zone.md`)
```

(original bug) Z09-B48: every protector reads `sp_nDamageAbsorb`, the **original** amount, not what the previous one
left: with two protectors in range both take the full damage, and if the second one dies its `absorb − left`
overwrites the first one's 0, so the player is hurt although the first protector absorbed everything.

### 16.7 What the 2016 data uses

| Mob types (file names) | Trigger (condition → actions) | Effect |
|---|---|---|
| 17 gates (`DetectCha` 50–150; `IDLeviathanGate01` 0, see B49): `MapLinkGate`, `MapLinkGate01`, `IDMapLinkGate00…03`, `IDLeviathanGate01`, `KarenGate`, `C_Gate01`, `T_Gate01/02`, `Gate_AdlF`, `Gate_Lab`, `DT_EntranceGate`, `DT_ExitGate`, `WarBL_EntranceGate`, `WarH_EntranceGate` | `Default` → `Link` | walking into `DetectCha` (50–150) opens the gate's menu |
| `BallCake01`, `BallWater`, `E_Ski_Snowman`, `E_SkiFlag_Blue/Gold/Red`, `Egg2014_BigEgg` | `Default` → `CallLua` | the mob's AI script `NPCAction` function runs (event mini-games); the four `KDSoccer_*` files (same trigger, two with `Die`) name no mob and are never used |
| `E_Ski_IDHoneying` | `Default` → `Ball` | pushed away by the player |
| `GTI_BoxAll` / `GTI_BoxTeamA` / `GTI_BoxTeamB` | `Default` / `GTITeam 0` / `GTITeam 1` → `GTIEffect`, `Die` | guild-tournament item box: effect for (the right team's) player, then the box dies |
| `SpUpShoes`, `SpImShield` | `Default` → action 35 / 36, `Die` | KQ pick-ups; rows 35 / 36 are `AbState StaOrbAtkRateUp` strength 5 / 6, while the KQ buffs `StaKQSpUpBuff` / `StaKQSpImBuff` are rows 40 / 41: the files most likely still point at the row numbers from before rows 34–38 were inserted *(inferred; data, not code)* |
| `ChristmasTree`, `E_SixYear_Dance` | `Emotion 23/24/25/26` → dispel the other event buffs, set one (`StaEventHpUp`, `SpUp`, `AllStatsUp`, `Speed`, `AcUp`) | emote next to the tree to choose a buff |
| `B_Slime` (unused name), `LightField01…05`, `MultiProtect`, `MultiProtect02/03` | `DmgAbsorb` → `DmgAbsorb` (+ `CheckCycleParty 1500 ms` → `AbState StaMultiHeal` strength 1/2/3 for MultiProtect) | the summoned protector takes its master's / party's damage (only servants have a master) |
| `LightOrb01…10` | `CheckCycleParty` → `AbState StaOrbAtkRateUp` strength 4…13 | party aura every 1.5 s |
| `DT_RadionOre` | `AttackMob` → `AbState StaRadionBuff`, `RestoreRate HP 1000`, `RestoreRate SP 1000` | hitting the ore buffs and refills (with B46/B47: HP once, SP twice) |

Unused rows: conditions 2–11 (`LvGap`, `Class`, `AbState`, `Term`+`Skill`, `Term`+`None`, `Term`+`Emotion`, `Die`,
`Emotion 12`) and actions 2–16 (incl. all `Notice` rows), 19 (`StaEventAllStatsUp`) and 39–41 (the KQ buffs). No row
uses `Location`.

### 16.8 Answers to open questions

- **9a / §14.8:** `hasObserver`'s `next_ == null` compare matches the marker `Observer(me, null)` that `ali_Work`
  registers before running the triggers; it is how a mob remembers which players it already handled (§16.3).
- **Z02 §4:** `sp_DoEmotion`'s `vt 0xa38(4, id, 0)` is `notifyObservers(EV_EMOTION, id)`: the emote triggers of §16.4.
- **Z02 §15 / §14.3:** the `NPCAction` object-script event (0x90) is raised only by the `CallLua` action.

### 16.9 Open points of this section

- `GuildTournamentSystem::CreateItemEffect` (what a guild-tournament box gives) is Z16.
- Whether a hit on `DT_RadionOre` ever meets its `AttackMob` observer (B49) depends on the object walk order between
  the ore and the player in the same tick; not traced.

## 17. Scripts 4: Lua functions that control objects

The 57 functions of the §14.9 row "part 10" (registered by `LuaScriptScenario::ls_FuncSet` FUN_005f5350). Common
rules, as in §14.6: arguments are 1-based Lua stack slots; a handle is resolved with `ShineObjectManager::som_GetObject`
FUN_0054fd10 (`GetObject` below); "returns nothing" = 0 results (Lua sees `nil`), "returns 1" = pushes the number 1
(`lua_pushnumber` FUN_005f8110) unless stated. Numbers are rounded (`ROUND` / `_ftol2`). Usage counts are calls / files in the 2016
`9Data/Shine/LuaScript` tree. FiestaHeroes' signatures *(fh-doc)* were compared; where they differ, the code is given.

Helpers used below:

- `so_IsEmpty` (vt 0x300): true for a player that is leaving and for a dead mob (§16, working notes); most functions
  refuse such an object.
- `vt 0xbbc` = the object as a player (`ShineMobileObject::so_ShineMobileObject` FUN_00450350 `return this` for players;
  folded `return 0` FUN_00570b00 for mobs and NPCs); `vt 0x4d0` = object kind (player 2, mob 5, §8 notes).
- `cLuaBroadcast(o, toHandle, packet, len)` @ FUN_005d8030: `toHandle == 0xFFFF` → `so_AllOfRange(o, sight, include
  self 1)`; else the packet goes only to `toHandle`, which must be a live player (kind 2, mode ≠ 0, not empty); returns
  false (and sends nothing) otherwise.
- Map-wide functions find the map with `FieldContainer::fc_FindMap(&fieldlist, mapName)` and walk it with
  `so_AllInMap(FieldMap::fm_GetCenterObject(field), iterator, 0)` (the map's axial flag, §12.7); without the flag
  they do nothing.

### 17.1 Moving objects

```pseudo
cWalkTo(handle, x, y [, rate = 1000])                      @ FUN_005da300   (3 calls / 1 file)
    o = GetObject(handle); if o == null or o.so_IsEmpty: push false; return 1     # the only boolean result here
    speed = o.so_WalkSpeed (vt 0x514) × rate / 1000
    o.so_mobile_MoveReserve (vt 0x660)((x, y), speed, kind 1 walk, backwards 0)   # §9.1
    payload = { u16 handle, u32 from.x, from.y = o.pos, u32 to.x = x, to.y = y, u16 speed, u16 moveattr (bit 0
        cleared, other bits = stale g_buf, as Z02-B2) }
    o.so_SetMovePacket (vt 0xbb8)(0x18, payload)                                   # remembered for newcomers (§9.3)
    sight (not o) ← 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD (payload); push true
cRunTo(handle, x, y [, rate = 1000])                       @ FUN_005da040   (97 / 32)
    o = GetObject(handle); no empty / mode test (a dead object is moved too)
    the same with so_RunSpeed (vt 0x518), kind 2 run, so_SetMovePacket(0x1a), 0x201A NC_ACT_SOMEONEMOVERUN_CMD; returns 1
cRunToUntilBlock(handle, x, y [, rate = 1000])            @ FUN_005da590   (3 / 3)
    o must exist and mode ≠ 3 (dead)
    q = so_FindBlockLocate(o, (x, y), |(x, y) − o.pos|, out, MapBlock::MapBlockInformation::mbi_IsMoveBlock)   # §9.3:
        # the last free point on the straight line to (x, y)   (the length comes from VectorClass::VectorWithLength
        # FUN_00462a70; `AxialListMobCounter::almc_HowMany` FUN_00461b70 is a folded body reading vwl_Length)
    if found: run there as cRunTo (0x201A); returns 1;  else returns nothing
cFollow(handle, targetHandle [, gap = 100] [, maxDist = 1000])   @ FUN_005dc1f0   (33 / 23)
    o (mode ≠ 3) and target must exist, else returns nothing; gap 0 → 100, maxDist 0 → 1000
    d² = so_DistanceSquar(o, target) (FUN_004028f0)
    if d² < gap²: returns 1                                 # close enough, no move
    if d² > maxDist²: returns nothing                       # too far: the script gives up
    p = o.pos + (target.pos − o.pos) × (√d² − gap) / √d²    # the point `gap` units before the target
    run there at so_RunSpeed (×1000 / 1000), 0x201A as cRunTo; returns 1
    # the decompile shows gap / maxDist as a speed rate; the disassembly (0x5dc3a0…0x5dc3f7) compares them as distances
    # and scripts call it so: cFollow(guard, leader, 100, 1000), pets cFollow(pet, master, PetFollowGap, PetFollowStop)
cMoveStop(handle)                                          @ FUN_005edf90   (2 / 2)
    o not empty: o.so_mobile_StopHere (vt 0xa48, §9.3); returns nothing
cMove2Where(handle) → x, y                                 @ FUN_005df6e0   (4 / 3)
    o.so_mobile_Move2Where (vt 0x60c): mobile objects `&MoveManager.mm_goalPos` FUN_005555d0 (the last destination,
        also after the move ended); a player on a mover asks the mover (FUN_005596c0)
    returns 2 numbers (x, y); nothing for an unknown handle
cWaitIdle(handle)                                          @ FUN_005e7f70   (1 / 1)
    returns 1 if o.vt[0x8c4]() (mobs `ShineMob::so_scene_IsIdle` FUN_0050def0: no cast running; players the folded
        `return true` FUN_005af8d0), else nothing
cWillMovement(handle)                                      @ FUN_005df340   (8 / 3)
    m = o as mobile object (vt 0xb8c); returns 1 when m.smo_Param.flag (Parameter::Container +0xcce) has neither
        cannotmove_stun (bit 0) nor cannotmove_entangle (bit 1) and not m.so_mobile_IsInFear (vt 0x9e8); else nothing
cSetObjectDirect(handle, dir [, includeSelf])               @ FUN_005e8fa0   (10 / 6)
cSetObjectDirect(handle, x, y [, includeSelf])
    o not empty; arg 2 must be a number
    arg 3 none / nil      → direction = arg 2 (0…179, the 2° unit of §9)
    arg 3 boolean         → direction = arg 2, includeSelf = arg 3
    arg 3 anything else   → direction = DirectDistanceTable::ddt_DirectSR(x − o.x, y − o.y) (face the point),
                            includeSelf = arg 4 when given
    *o.so_LocateInfo.direct = direction
    ShineObject::so_DirectInfoBroadcast(o, includeSelf)    @ FUN_00553510
        sight ← 0xBC1C NC_GAMBLE_ENTER_PLAYER_DIRECT_CMD { u16 nHandle, u8 nDirect }   (the face-direction packet, §7.4)
    returns nothing
cLocationRotate(x, y, angle) → x', y'                      @ FUN_005ed000   (4 / 2)
    v = (x, y); VectorClass::Vector::v_Rotation(v, angle)   @ FUN_0045ffa0
        angle < 0 → + a multiple of 180; x' = (cos·x − sin·y) >> 10, y' = (sin·x + cos·y) >> 10
        (ShineRadian::sr_sin1024 / sr_cos1024: 1024-scaled tables)
    returns 2 numbers (`v_GetX` FUN_0045ff80 and the folded y getter FUN_0045ff90). SubFunc.lua turns offsets with it.
```

The script moves above have no block test of their own (only `cRunToUntilBlock` looks for walls); scripts pick free
points. Speeds: `so_WalkSpeed` / `so_RunSpeed` return the static speed of §17.5 when one is set (vt 0xe84 / 0xe88 →
0xe8c / 0xe90, `ShineMob::so_WalkSpeed` FUN_00556740 / `so_RunSpeed` FUN_005567b0, `ShinePlayer::so_WalkSpeed`
FUN_00559960 / `so_RunSpeed` FUN_005599c0).

### 17.2 Animations, actions, visibility

```pseudo
cAnimate(handle, action, animation = "")                   @ FUN_005dd690   (113 / 35)
    o = GetObject(handle); action must be a string, else returns nothing
    action == "start": o.so_SetAnimation (vt 0xc30)(animation[32])
        ShinePlayer::so_SetAnimation @ FUN_00553070 / ShineMob::so_SetAnimation @ FUN_00553140:
            sight (not o) ← 0x2074 NC_ACT_ANIMATION_START_CMD { u16 handle, char sAnimationIndex[32] }
            remember it in the brief info (player: bic_BriefInfo.sAnimation; mob: vt 0xe48
            `so_SetAnimationBriefInfo` FUN_00556cd0) so that newcomers see it (Z02 §5)
    action == "stop": o.so_ResetAnimation (vt 0xc34)                        @ FUN_00553200 / FUN_005532d0
            sight (not o) ← 0x2075 NC_ACT_ANIMATION_STOP_CMD { u16 handle, char[32] = the remembered animation };
            the remembered animation = ""
    returns 1 for every action string (also unknown ones, which do nothing)
cAnimateForcedly(handle, action, animation)                @ FUN_005dd8a0   (unused in 2016)
    arg 1 must be a number; "start" with an animation: o.vt[0xc38]                    # returns 1
        ShineMob::so_SetForcedAnimation @ FUN_00553390: sight (not o) ← 0x6C0D NC_SCENARIO_ANIMATE_CMD
            { u16 handle, Name8 anicode (32 bytes, zero-filled then strncpy) }; not remembered
        players: folded no-op FUN_00549070
    "stop": so_ResetAnimation as above (returns nothing);  other: returns nothing
cActByEventCode(handle, eventCode)                         @ FUN_005eaa70   (7 / 1, PetBaseIdleActionFunc.lua)
    both numbers; o exists
    cLuaBroadcast(o, 0xFFFF, 0x207C NC_ACT_EVENT_CODE_ACTION_CMD { u16 nHandle, u32 nActionEventCode }) (sight incl. o)
    returns 1 (nothing for an unknown handle)
cSetSightState(handle, state)                              @ FUN_005e7b80   (6 / 1, Tutorial.lua)
    o not empty, state < 2: ShineObject::so_SetSightState FUN_0054aff0: o.so_eSightState = state
        (OBJECT_SIGHT_STATE: OSS_NONE 0, OSS_WIDE 1): with OSS_WIDE every range query of o (range 0) uses
        99,999,999 instead of the map's sight (§9.6), so o sees and is seen map-wide; returns nothing
cHideOtherPlayer(handle, hide)                             @ FUN_005e6a50   (6 / 3)
    o ← (through its data stream vt 0x2f8) 0x6C1C NC_SCENARIO_HIDE_OTHER_PLAYER_CMD { u8 bIsHide = hide }
    returns nothing; non-players have a dummy stream (ShineObject::so_GetDataSocketStream FUN_00554fa0)
cMapObjectControl(mapName, objectName, enable, controlType)   @ FUN_005e2ad0   (8 / 4)
    every object in the map ← 0x6C18 NC_SCENARIO_MAP_OBJECT_CONTROL_CMD {
        char sObjectIndex[32] = objectName, u8 IsEnableObject = enable, u32 eControlType = controlType
        (MAP_OBJECT_CONTROL_TYPE: MOCT_NORMAL 0, MOCT_ALPHA 1) }      # 37 bytes, as the 2016 PDB struct
    returns nothing. The zone keeps no state: a player entering later does not get it.
cVanishTimer(mapName)                                      @ FUN_005e5840   (18 / 9)
    every object in the map ← 0x0810 NC_MISC_RESTMINUTE_CMD { u8 1, u16 0 }   # rest minutes 0: ends the map timer display (Z01 §6)
    returns 1
```

Client handlers (C01 map): `0x2074` FUN_0049d120 plays the named animation; `0x2075` FUN_0049d150 stops it only if the
object's current animation has that name; `0x6C0D` FUN_004a3610 first stops the current animation (FUN_004c27a0)
and then plays the new one, which is what makes it "forced"; `0x207C` FUN_004a6300 splits the code into
`code / 10000 × 10000` and `(code / 100 mod 100) × 100` and plays that action on the object (pet idle / attack / dance
/ die codes in PetBaseIdleActionFunc.lua); `0x6C18` FUN_004a6650 finds the map object by name: type 0 shows /
hides it (enable 0 → hidden flag), type 1 fades it (FUN_0066d610); `0x6C1C` FUN_004a6d60 hides (1) or shows (0)
the other players; `0x0810` FUN_004997a0 (Z01). `0xBC1C` has a handler only in `MHDiceGameTask` (C01 §4, the gamble
house dice table); the main game dispatcher has none, so a `cSetObjectDirect` turn outside that task is not shown
*(inferred from C01's dispatcher map; whether that task exists outside the gamble house was not checked)*.

### 17.3 Damage, healing, killing, revival

```pseudo
cDamaged(handle, damage [, attackerHandle])                @ FUN_005f10d0   (41 / 14)
    o = GetObject(handle); damage == 0 → returns nothing
    no arg 3 (not a number): o.so_LostHP (vt 0x500)(damage)       # mob FUN_005569d0 / player FUN_00559c10:
        HP −= damage, but at least 1 is left: "environment" damage never kills
    else a = GetObject(attackerHandle) (unknown → returns nothing, nothing applied)
        damage < o.HP: o.so_DamagedBy (vt 0x5c0)(a, damage, aggroRate 1000, 1)    # Z03 §7: aggro, hit list, AI events
        else:          o.so_KilledBy (vt 0x5bc)(a, o.HP, aggroRate 0, lot 1)       # death, drops, exp (Z03 §7, §11)
    sight incl. o ← 0x243C NC_BAT_DOTDAMAGE_CMD { u16 object = handle, u32 resthp = o.HP after, u16 damage,
        u16 abstate = 0x1C1, u16 hpchangeorder = vt 0x7e8, u8 IsMissDamage = 0 }
    returns 1
    # (original bug) Z09-B57: abstate 0x1C1 = 449 = STA_MOBACPLUS; alms_SelfKill (§13.3) and the DOT code send
    #   0x318 (MAX_ABSTATEINDEX, "none") there. The client (FUN_004b5740) looks the index up and plays that abstate's
    #   view effect when it has one, so script damage shows STA_MOBACPLUS's effect, if any.
cKillObject(handle [, killerHandle])                       @ FUN_005e6d40   (9 / 8)
    o = GetObject(handle); k = killerHandle given ? GetObject(killerHandle) : null
    o.so_KilledBy(k, o.HP, 0, 1)                           # a mob killed twice is safe: ShineMob::so_KilledBy returns
                                                           #   when smo_Flag bit 3 (+0x1e78 & 8, "already killed") is set
    o.vt[0xdf0]()    # mob: ShineMob::so_mob_SendReallyKill FUN_00553760 = sight incl. o ← 0x244A NC_BAT_REALLYKILL_CMD
                     #   { u16 dead, u16 attacker = sm_ReallyDead.attacker } now and senddeadpacket = 1 (§5.4);
                     #   players: folded no-op FUN_00417480
    returns nothing
cHeal(handle, amount)                                      @ FUN_005de540   (16 / 14)
    o exists, amount ≠ 0: o.so_Heal (vt 0x4e4)(amount)    # mob FUN_00556840 / player FUN_00559ab0:
        HP += amount × Parameter.HealRate (+0xcd6, ‰) / 1000, capped at MaxHP (vt 0x4f0)
    so_AllOfRange(o, sight, ShineObject::so_ply_Send2WhoTargetMe)   # the new HP to everyone targeting o (§2.4)
    returns 1  (a player's own HP packet follows from the player tick, §2.4)
cStaticDamage(playerHandle, damage)                        @ FUN_005de8c0   (58 / 3)
    p = object as player (else returns nothing); p.smo_admindamage (+0x1e7c) = damage; returns 1
cStaticDamage_smo(handle, damage)                          @ FUN_005e48f0   (1 / 1)
    any mobile object: ShineMobileObject::so_smo_StaticDamage (vt 0xddc) FUN_0055d6b0: smo_admindamage = damage
    returns nothing
    # smo_admindamage (default −1, set by the ShineMobileObject ctor FUN_005591c0; GM &staticdamage FUN_0041dfd0,
    #   &godmode 1000000) is the fixed damage of every normal swing (Z03 §4.2 smo_SwingDamage / so_Bash: ≥ 1 skips
    #   the hit and damage rolls); skills ignore it
cRevivalAll(mapName)                                       @ FUN_005ec100   (unused in 2016)
    AxialListRevival::ali_Work FUN_0042a4b0 collects every player (kind 2) of the map; alr_Revive FUN_00429f40 runs
    ShinePlayer::sp_ReviveReqProcess FUN_00451bd0 for each (Z07 §3.1: only dead players revive, at their revive point)
    returns nothing
cSetDeadDelayTime(handle, ticks)                           @ FUN_005de090   (4 / 4)
    o as mobile (vt 0xc28) → vt 0xc3c: mobs ShineMob::so_mob_SetDeadDelayTime FUN_00556c60 (sm_DeadDelayTime, §5.2:
        extra time the corpse stays); players folded no-op; returns 1
```

### 17.4 Abnormal states

```pseudo
cSetAbstate(handle, abstateName, strength, keepMs [, setterHandle])   @ FUN_005d97a0   (291 / 91)
    o = GetObject(handle); idx = dic_abstate.as_BTreeIndex[abstateName] (unknown → returns nothing)
    row = AbnormalStateDictionary::AbState::as_FromIndex(idx)
    setter = o; arg 5 a number → setter = GetObject(arg 5) when it exists (a following `lua_type == 0` test is dead:
        lua_isnumber FUN_005f77a0 already passed)
    ok = o.so_AbnormalState_Set (vt 0x638)(setter, idx, strength, row, g_Now, 0, 0, keepMs,
                                           EF_JUSTENCHANTPINESCRIPT 9, null)          # Z03 §6.2
    if ok: so_AbnormalState_BitSet(o, idx); so_AbnormalState_BroadcastSet(o, idx, keepMs, g_NewAbstateStrength);
        o.so_AbnormalState_Inform (vt 0x3f0)(idx, keepMs, 1); o.so_RecalcAbstateParamReady (vt 0x528)
        returns 1
    else returns nothing
    # g_NewAbstateStrength (DAT_00875220) = the strength aeo_Set really applied (stacking may raise it, Z03 §6.2)
cSetAbstate_Range(centreHandle, range, objectType, abstateName, strength, keepMs)   @ FUN_005f2560   (13 / 10)
    c = GetObject(centreHandle); range ≠ 0, objectType ≠ 0 (u8), name known, row exists
    list = AxialListNearObjectList(objectType) over so_AllOfRange(c, range, include self 0)
        (ali_Work FUN_0042a8f0: kind == objectType and mode ≠ 3)
    for each t in list: same as cSetAbstate with setter = c
    returns nothing
    # (original bug) Z09-B56: the strength register is replaced by g_NewAbstateStrength after every success
    #   (0x5f2753), so the 2nd, 3rd … objects get the strength that was applied to the previous one, not `strength`
cSetAbstateInArea(mapName, abstateName, strength, keepMs, bmpName, x, y)   @ FUN_005e2c40   (4 / 2)
    field, centre flag, abstate idx, bmp = BmpDataBox::bdb_GetBmpDataInfo(&bmpdatabox, bmpName) (FUN_00439520;
        `BMP.shn` row → bitmap, the same bitmaps as area skills, §12.5 / Z01) must exist
    scan = AxialListSetAbstateInArea (0x654: AxialListNearScan buffer of 200, alsa_pBmpInfo, alsa_nCenterLocation)
    AxialListSetAbstateInArea::alsa_Init(scan, bmp, (x, y))                @ FUN_004c1bf0
    so_AllOfRange(flag, range = bmp.AreaCenter_X (first BMPInfo member), centre (x, y), include self 1)
    AxialListSetAbstateInArea::ali_Work(scan, me, o, d²)                   @ FUN_004c21a0
        keep o when it is a player (vt 0xbbc), mode ∉ {0, 3}, < 200 kept, and the bitmap cell
        AreaBMP[CenterX + (o.y − y)][CenterY + (x − o.x)] is inside AreaSize_X × AreaSize_Y and ≠ 0
    AxialListNearScan::alns_Sort (FUN_00401460, qsort by distance)
    AxialListSetAbstateInArea::alsa_SetAbstate(scan, idx, strength, keepMs, setter null)   @ FUN_004c1c20
        for each kept player: vt 0x638(null, idx, strength, row, g_Now, 0, 0, keepMs, 9, null);
            then always BitSet, BroadcastSet, Inform, vt 0x528;  strength = g_NewAbstateStrength
    returns nothing
    # (original bug) Z09-B55: the result of vt 0x638 is not checked (0x4c1c88): a refused state (dead player, weaker
    #   than one already held) is still flagged in the brief bits and announced to the player and the sight; and,
    #   as in B56, every player after the first gets the previous player's applied strength
    # only players are affected (ali_Work requires vt 0xbbc); NPCs and mobs inside the area are skipped
cResetAbstate(handle, abstateName)                         @ FUN_005ef120   (175 / 52)
    o exists, name known: o.so_AbnormalState_Reset (vt 0x650)(idx)   (Z03 §6.3); returns 1
    # args 3 and 4 are read and ignored
cDePolymorph(handle)                                       @ FUN_005e9210   (1 / 1)
    o not empty, kind 2: ShinePlayer::so_ply_DePorymorph (vt 0xe1c) FUN_004a3120 = the 0x10B0 request path of Z07 §3.4
        (no polymorph abstate: brief polymorph = 0xFFFF, sight incl. p ← 0x10AF { p, 0xFFFF, 0x318 }, reset 0x61 /
        0x123; else erase that abstate); returns nothing
cDePolymorph_Area(mapName, areaName)                       @ FUN_005f30d0   (unused in 2016)
    AxialListAreaObjectList(field, areaName, kind 2) over the map (§15.7); vt 0xe1c for each player found (the loop
    stops at the first null entry); returns nothing
```

### 17.5 Mob and NPC settings

```pseudo
cSetMobAttr(handle, attribute, value)                      @ FUN_005e13d0   (unused in 2016)
    o kind 5 (mob; NPCs are kind 4 and refused)
    "MobAggro":    ShineMob::so_mob_MobAggro (vt 0x728) FUN_00556bb0: sm_Flag.MobAggro = value
        # read back by so_mobile_MobAggroRate (vt 0x904) FUN_00556bd0 in MobTargetAggresive::ali_Work (§6.3.1):
        #   false = aggressive mobs of the other side ignore this mob
    "CanRecovery": ShineMob::so_mob_CanRecover (vt 0x724) FUN_00556b90: sm_Flag bit 1 (PDB name HealAtPiece) = value
        # read by sm_DuringBattle at the end of a fight: battle state = flag & 2, i.e. 2 = recover, 0 = idle (§6.5)
    returns 1;  other attributes: returns nothing.  Both bits are set again at every spawn (§5.3)
cSetNPCParam(handle, name, value)                          @ FUN_005f0320   (64 / 13)
    value ≥ 0 (int); o.so_mob_ParamSetAtScript (vt 0xb80)(name, value) (§5.8: HP, MaxHP, MobEXP, AC, MR, WalkSpeed,
        RunSpeed, HPRegen; players: folded `CGambleObject::GDTSO_SetDiceProbability` FUN_004021b0)
    returns 1 when accepted, else nothing
cMobDetectRange(handle, range)                             @ FUN_005e80b0   (6 / 5)
    range a number: o.vt[0x8bc](range) (ShineMob::so_scene_DetectRange FUN_0050dd30, §5.8); returns nothing
cMobIDFind(mobIndexName) → id                              @ FUN_005eee50   (unused)
    MobDataBox::mdb_2MobID(&mobdatabox, name) (0xFFFF when unknown, §5.1); returns the id
cTargetChangeNull(playerHandle, targetHandle)              @ FUN_005d6b80   (3 / 2)
    p = object as player, not empty, kind 2; if p.so_CurrentTargetHandle (vt 0x754) == targetHandle:
        ShinePlayer::so_ply_TargetChange (vt 0x998)(null)   (Z03 §2.3: the player's target is dropped); returns nothing
cStaticWalkSpeed(handle, on, speed)                        @ FUN_005ed500   (8 / 6)
cStaticRunSpeed(handle, on, speed)                         @ FUN_005ed3c0   (8 / 6)
    any object: ShineMobileObject::so_smo_SetStaticWalkSpeed (vt 0xe7c) FUN_005558f0 / so_smo_SetStaticRunSpeed
        (vt 0xe80) FUN_00555910: smo_bStaticWalkSpeed / smo_bStaticRunSpeed = (on == true), smo_nStatic…Speed = speed
        (u16); read through so_smo_IsStatic…Speed / so_smo_GetStatic…Speed (FUN_00555930 / FUN_00555940 /
        FUN_00555950 …) by so_WalkSpeed / so_RunSpeed (§17.1); returns nothing
        # FiestaHeroes lists (Handle, Speed) *(fh-doc)*; the code reads (handle, boolean, speed)
cStaticSpeed(playerHandle, speed)                          @ FUN_005dea30   (2 / 2)
    p = object as player; speed < 1000 → 1000
    ShinePlayer::sp_SetTotalMoveSpeed FUN_00560150: Parameter PureCharParam.MoveSpeed (+0x100c) = speed;
        Parameter::Container::c_MakeTotal (the run speed is Total.MoveSpeed (+0x1c00) × chrrunspeed / 1000); returns 1
cStaticMoverSpeed(playerHandle, speed)                     @ FUN_005debb0   (1 / 1)
    p = object as player; speed < 1000 → 1000; ShinePlayer::sp_SetMoverRunSpeed FUN_00560130 (again min 1000):
        sp_RideCast.runspd = speed (the mount run speed of mode 6, so_RunSpeed); returns 1
```

Neither speed setter sends a packet; a moving object keeps its speed until the next move, and a player's new
`MoveSpeed` reaches the client with the next parameter-change pass (`so_mobile_SpeedChange`, §9.3) *(inferred:
`c_MakeTotal` marks the change; not traced)*.

### 17.6 Map rules

```pseudo
cSetFreeBattle(mapName, on)                                @ FUN_005ebfe0   (unused in 2016)
    field.fm_PKField (+0x54) = on
    every object in the map ← AxialListProtocolSend(6, on ? 0x12 : 0x13): 0x1812 NC_MAP_FREEPKZONE_ON_CMD /
        0x1813 NC_MAP_FREEPKZONE_OFF_CMD (no payload); returns nothing
cSetTeamBattle(mapName, on)                                @ FUN_005e83e0   (1 / 1)
    kq = KingdomQuest::KingdomQuestContainer::kqc_SearchHandle(&kqcontainer, field.fm_KQHandle) (none → nothing)
    kq.kqe_kqinfo.IsTeamPVP = on (read by ShineObject::so_IsTeamPVPKQ FUN_0055d6c0, Z16)
    every object in the map ← 0x1828 NC_MAP_KQTEAMBATTLEZONE_ON_CMD / 0x1829 …_OFF_CMD (no payload); returns nothing
cSetCanUseReviveItem(mapName, on)                          @ FUN_005e8520   (1 / 1)
    field.fm_FieldFlag.ff_CanUseReviveItem (+0x20c bit 0) = on
    every object in the map ← 0x182B NC_MAP_CAN_USE_REVIVEITEM_CMD { u8 bCanUseReviveItem }; returns nothing
cSetCanUseReviveSkill(mapName, on)                         @ FUN_005e8660   (1 / 1)
    ff_CanUseReviveSkill (+0x20c bit 1) = on; no packet; returns nothing
cSetReviveDelayTime(mapName, seconds)                      @ FUN_005e8740   (1 / 1)
    field.fm_ReviveDelaySec (+0x210) = seconds; returns nothing
```

Readers: `ff_CanUseReviveItem` gates `sp_NC_ITEM_REVIVEITEMUSE_CMD` (FUN_00417580) and is re-sent to each player by
`ShinePlayer::so_ply_SendCanUseReviveItem` FUN_005616f0 (0x182B); `ff_CanUseReviveSkill` gates the revive skills
(`sp_NC_SKILL_REPLYREVIVE_CMD` FUN_00418a30, `sp_NC_BAT_SKILLBASH_FLD_CAST_REQ` FUN_0057f400 / `…OBJ_CAST_REQ`
FUN_0057fa50) and the rebirth flag of the death menu; `fm_ReviveDelaySec` is the wait of 0x104D NC_CHAR_DEADMENU_CMD
(`ShinePlayer::so_KilledBy` FUN_00433be0, Z03 §7). Map defaults (FieldMap init): both flags 1, 180 s; the job-change
dungeon (`so_ply_2JobDungeon` FUN_0049f880) clears both. Client: `0x1812` FUN_004b4eb0 shows "This area is enabled
for PvP." and sets the own PK flag; `0x182B` FUN_0049d9a0 passes the flag to the revive UI; `0x1813` / `0x1828` /
`0x1829` are handled inline in the game dispatcher (not traced).

### 17.7 Moving players between maps, parties

```pseudo
cLinkTo(handle, mapName, x, y)                             @ FUN_005dde20   (51 / 40)
    o = GetObject(handle); attr = FieldOption::fo_GetFieldAttr(&fieldlist.fc_FieldOption, mapName) (the server map
        row); its client map (mapidclient) must be in MapInfo (mapdatabox)
    link = NPCManager::LinkInformTemplete { linktoserver = mapName (12 + NUL), linktoclient = client map name
        (12 + NUL), coordx = x, coordy = y }        # index, direct, Party are left as stack garbage; so_LinkTo
                                                     # (FUN_0049ad30) reads only the map names and coordinates
    if o.mode == 4 (camp): o.so_ply_ReinforceFoldtent (vt 0x488) FUN_0055ae50   # fold the mini-house tent first:
        mode 1, restore the saved look, sight ← 0x202C
    o.so_LinkToReserv (vt 0x3fc)(link, tryUntilSuccess 0)    @ FUN_00495f00 (players; other kinds: no-op FUN_00495eb0)
        ShinePlayer::sp_LinkReservStore FUN_005518c0 copies the record into the 128-entry ring `queue_linkreserv`
        (MemoryQueue<NPCManager::LinkInformTemplete>); sp_Linkreserv = its slot; sp_MiscFlag.LinkReserv_link = 1
        # the player tick performs the link (§2.3: so_LinkTo(target, 6, 9, 10))
    returns 1
cLinkToAll(mapName, toMap, x, y)                           @ FUN_005df4b0   (35 / 35)
    the same record for every object in mapName: AxialListLinkToLua (ctor FUN_00428930; ali_Work
        `AxialListLinkTo::ali_Work` FUN_00428950: fold a camp, then so_LinkToReserv(link, 0)); returns 1
cPartyJoin(masterHandle, joinerHandle)                     @ FUN_005e3460   (2 / 2)
    both live players (kind 2, not empty), joiner in no party (so_PartyRegistNumber vt 0x550 == −1)
    joiner.so_ply_PartyZoneJoinCmd (vt 0xd58)(master's charNo)          @ FUN_004cd910
        → WM 0x3860 NC_PARTY_ZONE_JOIN_CMD { u32 nMasterCharNo, u32 nJoinCharNo }   (W02 §3.2)
    returns nothing
cPartyLeave(handle)                                        @ FUN_005e3610   (3 / 2)
    live player in a party: → WM 0x3861 NC_PARTY_ZONE_LEAVE_CMD { u32 nCharNo }   (W02 §3.3; the assert text says
        "cPartyJoin : Packet Too Long", a copy); returns nothing
cVanishAll(mapName [, mobIndexName])                       @ FUN_005f0150   (38 / 20)
    no arg 2: AxialListMobVanish { almv_MobID = 0xFFFF } over the map: ali_Work FUN_004283c0 calls vt 0x3f4
        `so_RetrateFromMap` (removed next tick, §13.1) on every kind-5 object (mobs; NPCs, servants, doors stay)
        returns 1
    with arg 2: AxialListMobIndexVanish(name, &n) (FUN_005eff60; n = 0) over the map: ali_Work FUN_005f0050 removes
        every object whose data entry (vt 0x70c, the MobInfo row) InxName equals name, n += 1; returns n
```

### 17.8 Player items, money, stats, titles, equipment view

```pseudo
cInvenItemDestroy(playerHandle, itemIndexName, count)      @ FUN_005d63d0   (9 / 8)
    p = object as player, not empty, kind 2; itemId = ItemDataBox::idb_2itemid(name) (≠ 0xFFFF); count ≠ 0
    ShinePlayer::sp_DestroyItem(p, p.handle, itemId, count, null) @ FUN_00527b60 (the `sp_DestroyItemB` of Z02 /
        Z08: counts the unlocked inventory lots; count ≤ 0 = all; more than owned → assert "Try to delete too many
        lot", false; else locks the cells and sends DB 0x3459 NC_ITEMDB_DESTROY_REQ, Z05)
    returns 1 when the request was sent, else nothing
cItemErase(mapName, itemIndexName)                         @ FUN_005ecb40   (unused in 2016)
    AxialListObjectCollect (ali_Work FUN_0042a650 collects every object) over the map; for each o:
        o.so_scene_EraseItem (vt 0x8b8)(itemId, −1)
            players ShinePlayer::so_scene_EraseItem FUN_0050dba0: sp_DestroyItem(p, h, itemId, −1 = all lots) from the
                inventory, then sp_DestroyItem(p, h, itemId, p.itembag, inventory type 8) FUN_00527a70 (first matching
                cell of type 8 *(inferred: the equipped items)*)
            drop items `ShineDropItem::so_scene_EraseItem` FUN_0050dc70 (§11.4); others: folded no-op FUN_00509900
    returns nothing
cUseMoney(handle, amount)                                  @ FUN_005e6450   (3 / 3)
    o exists; money = o.so_ply_CurrentMoney (vt 0x434, u64); require money ≥ amount (u32)
    o.so_ply_IncDecMoney (vt 0x794)(amount, decrease 0)     @ FUN_0052ffc0 (Z05 §3.3: Cen −= amount; DB 0x347A;
        vt 0x448 so_ply_ChangeCen to the client)
    returns 1;  not enough money: returns nothing.  Non-players: CurrentMoney folded 0 → fails unless amount 0
cLevelUp(handle)                                           @ FUN_005e7590   (1 / 1)
    o.vt[0xe00]: ShinePlayer::so_ply_LevelUpAtLua FUN_00561530:
        sp_GainExp(p, nextexp[level] − Experience, 0xFFFF, 0xFFFF)    # exactly the exp to the next level (Z03 §8.3)
    others: no-op; returns nothing
cFreeStatInit(handle)                                      @ FUN_005e7dc0   (unused in 2016)
    o not empty, not already locked (vt 0xac8 sp_CharFreeStat_IsLock FUN_0055a650), stat block (vt 0x424
        so_GetStatDistStr: the 5 spent stat points)
    → DB 0x111A NC_CHAR_TUTORIAL_FREESTAT_INIT_REQ { u32 nCharNo, u8 nMaxStat, u8 nFreeStat[5] = spent STR…SPR }
        (D02: decrements the stat points in the DB, answers 0x111B; Z07 §2: then so_ply_InitFreeStat and unlock)
    vt 0xacc sp_CharFreeStat_Lock FUN_0055a660: sp_bCharFreeStatLock = 1; returns nothing
    # (original bug) Z09-B58: nMaxStat (payload byte 4) is never written: stale g_buf content; D02 does not read it
cCharTitleAddValue(playerHandle, titleType, value)         @ FUN_005ded30   (9 / 6)
    p = object as player; t = p.so_GetCharacterTitle (vt 0x420); 0 < titleType < 128; value (u64) ≠ 0
    CCharacterTitleZone::TitleAddValue(t, titleType, value) FUN_005cbc80: m_TitleValues[type].TitleValue += value,
        bTitleSave = 1, CheckNewTitle FUN_005cb5f0 (Z07, titles); returns 1
cViewSlotEquip(playerHandle, itemIndexName)                @ FUN_005e3c00   (7 / 7)
    live player; item known: ShinePlayer::so_ply_ViewSlot_Equip (vt 0xd64)(itemId)   @ FUN_0052b110
        require ItemInfo + ItemInfoServer rows and CharClassDataBox::ccdb_CheckClass(UseClass, p's class)
        slot = EquipEnumChanger::eec_EquipLocation(row) (NONE → nothing)
        hide the real items that conflict (eec_ConflictWithNewEquip / …OldEquip, unless already covered by a view
            slot): so_ply_EquipmentChange (vt 0xd60)(0xFFFF, slot, null, 1)
        clear conflicting view slots (eec_ConflictWithNew/OldViewSlot) with so_ply_ViewSlot_UnEquip (vt 0xd68)
        so_ply_EquipmentChange(itemId, slot, null, 1)        # sight sees the item worn (Z05 §5.1 FUN_0052ce60)
        ItemEquipment::ie_ViewSlot_Set(slot, slot, itemId) and the extra slots of the item (eec_GetEquipSlotList)
            set to 0xFFFF; so_briefequipset (vt 0x5c8)
    returns nothing.  A "view slot" shows an item the player does not own (costume preview); nothing is stored in
    the DB *(inferred: no DB packet in the path)*
cViewSlotUnEquipAll(playerHandle)                          @ FUN_005e3d40   (2 / 2)
    live player: ShinePlayer::so_ply_ViewSlot_UnEquipAll (vt 0xd6c)(1) FUN_0052b510: slots 1…29: clear each used view
        slot and send 0xFFFF for it (or for every slot when none is in use), then re-send every real equipped item
        (so_ply_EquipmentChange(itemId, slot, cell, 1)); so_briefequipset; returns nothing
```

### 17.9 Answers and open points

- Every part-10 row of §14.9 is now documented here; part 11 starts with the query functions.
- `cAnimate` on a player: `so_SetAnimation` broadcasts with include-self 0, so the player's own client does not get
  0x2074 (the casting bar of §14.6 does include the player). 2016 scripts animate NPCs and mobs; whether a script
  animates a player was not checked.
- `0xBC1C` (`cSetObjectDirect`, mob skill facing §7.4) is handled only by the client's `MHDiceGameTask`; see §17.2.
- `cSetAbstateInArea`'s range is `BMPInfo.AreaCenter_X` (the first member, read as `pSVar4->_padding_`): bitmaps whose
  centre is not their half size reach only part of the bitmap *(inferred from the member order)*.
- `cViewSlotEquip`: how the view slots are stored across logout (`ItemEquipment` view-slot members) is Z05 / Z07.

## 18. Scripts 5: Lua functions that query objects, maps and lists

The 60 functions of the §14.9 row "part 11". Common rules as in §17 (1-based Lua slots, `GetObject` =
`ShineObjectManager::som_GetObject` FUN_0054fd10, "returns nothing" = 0 results, numbers rounded, usage counts =
calls / files in the 2016 `9Data/Shine/LuaScript` tree). Unsigned values are pushed as unsigned (`+ 2^32` when the
int is negative). Function names are *(pdb2016)*; FiestaHeroes' signatures *(fh-doc)* were compared, and where they
differ the code is given.

Search visitors used below (`ali_Work(centre, object, dist²)`, returning false stops the walk; map walks use
`so_AllInMap(fm_GetCenterObject(map), visitor, 0)`, range walks `so_AllOfRange(centre, stamp, pos, range, fan = null,
visitor, includeSelf, 0xFFFF)`, where range 0 means the map's sight range (§16, `so_AllOfRange` FUN_0054bc80)):

| Visitor `@` | Collects |
|---|---|
| `AxialListObjectCollect` ctor FUN_0042a1e0, `ali_Work` FUN_0042a650, `aloc_Home` FUN_004288b0 / `aloc_Next` FUN_00429db0 / `aloc_Get` FUN_00429dd0, dtor FUN_0042a2b0 | every object (vector `aloc_List`, cursor `aloc_Finger`) |
| `AxialListPlayerList` ctor FUN_0042a2f0, `ali_Work` FUN_0042a700, `alpl_GetList` FUN_0042a940, `alpl_GetCount` FUN_00429de0, dtor FUN_0042a330 | players (kind 2, any mode, dead included) |
| `AxialListNearObjectList` ctor FUN_0042a450, `ali_Work` FUN_0042a8f0, dtor FUN_0042a470 (§17.4) | kind == `alnol_ObjectType` and mode ≠ 3 |
| `AxialListAreaObjectList` (§15.7) | kind == type, in the `.aid` area, mode ≠ 3 |
| `AxialListNearScanObjectType` ctor FUN_004c1b40, `alns_ValidObject` FUN_004c1b80, `ali_Work` FUN_004c2080 | kind == `alnsot_nObjectType`, not `so_AmIAlreadyDead` (vt 0x28) when `alnsot_DeadCheck`, mode ≠ 0 and ≠ 3; at most 200 (`alns_buffer[200]` of `AxialListNearScan`) |
| `AxialListEnemyInAray` (an `AxialListNearScan` 0x64c: `alena_Mob` +0x648; vt set inline), `alns_ValidObject` FUN_005f0d80, base `AxialListNearScan::ali_Work` FUN_004c1cf0, `alns_GetMember` FUN_004c17f0, ctor FUN_004c17c0, dtor FUN_005d6cb0 | `alena_Mob.so_mobile_IsEnemy` (vt 0x72c, Z03 §3.3) objects with mode ≠ 0 and ≠ 3, without `STA_IMMORTAL` (291) and `STA_ADLFLOUSSIERIMT` (499) (vt 0x3e4 `so_AbnormalState_IsSet`); at most 200 |
| `AxialListFindNearPlayer` ctor FUN_00428990, `ali_Work` FUN_00429fb0, `alfnp_GetNearPlayer` FUN_004289c0 | nearest object that has a `CharClass` (vt 0x49c `so_CharacterClass` FUN_00555590), is not dead (mode ≠ 3) and whose base class (`cc_ClassType`, below) is in the list; start `alfnp_MinDist` 99 999 999 (strictly closer wins) |
| `AxialListNPCSearch` ctor FUN_004299d0, `ali_Work` FUN_00429ab0 | first object whose mob row (vt 0x70c `so_mob_DataBox`) `InxName` equals `alns_Name` (32 bytes, `strncpy`); stops the walk |

`AllOfRangeArgument::operator unsigned long` FUN_00427ef0 is the walk stamp (`++aora_argument`).

### 18.1 Time and random numbers

```pseudo
cCurSec() → seconds                                       @ FUN_005d8cd0   (62 / 9)
    returns g_Now / 10 (integer seconds of the zone clock, §1)
cCurrentSecond() → seconds                                @ FUN_005d8d60   (544 / 136)
    returns g_Now / 10.0 (with the tenth: e.g. 1234.5)
cRandom(min, max) → n                                     @ FUN_005ed640   (12 / 2)
    min, max truncated to int; RandomBox::rb_random FUN_0063ccf0 → cWell512Random::well512_GetRandom(min, max)
        FUN_0063cab0: max ≤ min (unsigned) → min; else min + (round(well512() × 1e11) mod (max − min + 1))
    returns n in [min, max]
cRandomInt(min, max) → n                                  @ FUN_005eed70   (105 / 47)
    n = max − min + 1
    if n > 1 and (max − min) < 100 (unsigned): returns min + RandomRing(n) value (ring DAT_14d720d0 + n×0x8008, §8 notes)
    else returns min
    # (original bug) Z09-B62: a range of more than 100 values (or max < min) always gives min; RandomRing only has
    #   rings up to 100. 2016 scripts use it with list sizes (`cRandomInt(1, #PlayerAggroList)`, 34 calls), which
    #   return 1 once a list has more than 100 entries
cPermileRate(rate) → 1 | nothing                           @ FUN_005da8b0   (3 / 3)
    rate truncated; returns 1 when well512_GetRandom(1000) FUN_0063cb10 (0…999) < rate, else nothing (probability rate/1000)
```

### 18.2 Object state

```pseudo
cObjectType(handle) → kind                                @ FUN_005f04b0   (5 / 5)
    returns vt 0x4d0 (player 2, NPC 4, mob 5, door 7, bandit 8, effect 9, servant 10, mover 11, pet 12; §7 notes)
cGetObjectMode(playerHandle) → name                       @ FUN_005d6880   (2 / 2)
    handle a number ≠ 0xFFFF, object kind 2; vt 0x484 mode → "linking" 0, "normal" 1, "fight" 2, "corpse" 3, "house" 4,
        "booth" 5, "riding" 6, "logoutwait" 7; other modes and non-players: nothing
cIsObjectDead(handle) → 1 | nothing                        @ FUN_005d94f0   (338 / 87)
    no argument: nothing; object missing or mode 3 (dead): returns 1; else nothing
cIsObjectAlreadyDead(handle) → boolean                    @ FUN_005ee090   (5 / 4)
    returns true when the object is missing or `so_AmIAlreadyDead` (vt 0x28, the +0x1d7c flag of §13) is set; else false
cPlayerExist(handle) → 1 | nothing                         @ FUN_005d8aa0   (6 / 4)
    returns 1 when the object exists and mode ≠ 3 (any kind, despite the name)
cObjectHP(handle) → hp, maxHP                             @ FUN_005d9630   (71 / 39)
    returns vt 0x4e8 so_GetHP, vt 0x4f0 so_MaxHP (non-mobile objects: folded `return 0`)
cGetLevel(handle) → level                                 @ FUN_005e0c90   (4 / 3)
    vt 0x4d8 so_GetLevel (player: Level clamped to 1…150 FUN_005598a0; mob: sm_MobLevel FUN_00556630); 0 → nothing
cGetBaseClass(handle) → class                              @ FUN_005deee0   (10 / 5)
    c = so_CharacterClass (vt 0x49c); c == null → nothing; returns c.cc_ClassType (CharClass vt 0x48): Fighter line
        1 (FUN_00557bb0, folded name), Cleric line 6 (CharClassCleric::cc_ClassType FUN_00449780), Archer line 11
        (FUN_00449820), Mage line 16 (FUN_004498e0), Joker line 21 (FUN_0063e440), Sentinel line 26 (FUN_0063e470),
        `CharClassMob` 0 (folded `return 0`) = the base class ID of the class's line
cGetCharNo(playerHandle) → charNo                         @ FUN_005e4110   (8 / 8)
    not so_IsEmpty, kind 2: returns so_GetCharRegistNumber (vt 0x344, basedata.chrregnum)
cGetRegistNumber(handle) → regnum                         @ FUN_005d6500   (3 / 2)
    handle a number ≠ 0xFFFF; vt 0x344 so_GetCharRegistNumber: player chrregnum FUN_00559a30, mob sm_MobRegnum FUN_00556820 (§5); −1 → nothing
cGetMobID(handle) → mobId                                 @ FUN_005e47b0   (8 / 3)
    vt 0x708 so_mob_MobID FUN_00556ab0; players: folded `return 0xFFFF` FUN_005550b0 → nothing
cGetPlayerName(handle) → name                             @ FUN_005d9240   (11 / 11)
    always returns a string: "" without an argument, for a missing or dead (mode 3) object; else
        NameString[vt 0x56c so_CharName] (player: basedata.charid FUN_00559780; mob / NPC: the MobInfo Name FUN_00556530)
cGetAdminLevel(handle) → level                            @ FUN_005e42a0   (1 / 1)
    not so_IsEmpty: returns vt 0x4d4 (player: so_AdministratorLevel = basedata.adminlevel FUN_00559740; others: folded `return false` → 0)
cGetMaster(handle) → masterHandle                         @ FUN_005e32c0   (8 / 6)
    kind 10 (servant): vt 0x9b0 master (§13.3); kind 12 (pet): ShinePet::spt_FindMaster (Z13); other kinds: nothing
    returns master.so_handle (+4) when found
cGetWhoKillMe(handle) → killerHandle                      @ FUN_005ee350   (2 / 2)
    object dead (mode 3): k = so_mobile_WhoIsKillMe (vt 0x80c, smo_WhoKillMe FUN_00555740); returns k when GetObject(k)
        still exists, else nothing
cGetCurrentSkillInfo(mobHandle) → skillIndex, readySec     @ FUN_005f2070   (3 / 1)
    handle a number; m = ShineDynamicCast<ShineMob> (mobs, NPCs, servants); w = so_mob_CurSelectWeapon (vt 0x740,
        sm_ReadyWeapon.weaponindex FUN_004a9cf0) ≥ 0; skill = weapon slot w of the mob row (vt 0x70c +8, 0xC-byte
        slots, skill u16 at +4, §8 notes) ≠ 0 and known to SkillDataBox
    returns skill row InxName, sm_ReadyWeapon.nextblast[w] / 10.0 (the zone-clock second the weapon fires; compare
        with cCurrentSecond)
cGetMoveState(handle) → state, seconds                    @ FUN_005e2f30   (17 / 10)
    s = smo_GetMoveState (vt 0xd50, FUN_0055d690), t = smo_GetMoveStateStartTime (vt 0xd54, FUN_0055d6a0)
    s ≠ MS_MAX (2) and t ≠ 0: returns s (MS_HALT 0 / MS_MOVE 1, the movement detector of §5), (g_Now − t) / 10
        (integer seconds in this state)
    # FiestaHeroes lists three results *(fh-doc)*; the 2016 code returns two
cGetWalkSpeed(handle) / cGetRunSpeed(handle) → speed      @ FUN_005ed280 / FUN_005ed140   (0 / 0, 2 / 2)
    returns vt 0x514 so_WalkSpeed / vt 0x518 so_RunSpeed (with the static speeds of §17.5)
cIsMovable(handle) → 1 | nothing                          @ FUN_005da9c0   (2 / 1)
    no argument: nothing
    o found and (so_parameter (vt 0x430).flag.cannotmove_stun or .cannotmove_entangle) (Parameter::Container +0xcce
        bits 0 / 1): nothing
    else returns 1
    # (original bug) Z09-B67: a missing object returns 1 (movable); the found-object test is skipped
cIsNoAttacOrNoMove(handle) → 1 | nothing                   @ FUN_005eac30   (2 / 1)
    handle not a number, or object missing: returns 1
    Parameter::Container::IsNoAttacOrNoMove FUN_004c8e80 (stun, entangle or cannotattack bit): returns 1; else nothing
cGetAbstate(handle, abstateIndex) → strength, restSec     @ FUN_005e5e20   (6 / 4)
    idx = dic_abstate.as_BTreeIndex[name] (≠ −1)
    st = so_AbnormalState_Strength (vt 0x3e8) FUN_00555a60 (aeo_Strength, 0 when not set)
    rest = so_AbnormalState_RestTime (vt 0x3ec) FUN_00555a90 ((aeo_Tick.terminate − g_Now) / 10, seconds)
    st ≠ 0 and rest ≠ 0: returns st, rest; else nothing (a state with less than 1 s left counts as absent)
cAbstateRestTime(handle, abstateIndex) → restSec          @ FUN_005ef750   (9 / 7)
    handle ≠ 0xFFFF, name known: rest as above; returns rest when > 0, else nothing
```

### 18.3 Positions, maps and areas

```pseudo
cObjectLocate(handle) → x, y                              @ FUN_005d9ef0   (191 / 58)
cObjectLocateDirection(handle) → x, y, dirDeg             @ FUN_005e4d80   (unused)
    direction byte < 180 (else nothing); dirDeg = byte × 2
cGetDirect(handle) → dirDeg                               @ FUN_005de400   (10 / 6)
    returns (u16)(direction byte × 2)
cDistanceSquar(h1, h2) | (x1, y1, x2, y2) → d²            @ FUN_005d88c0   (124 / 44)
    arg 3 a number: returns (x1 − x2)² + (y1 − y2)² (doubles, no rounding)
    else both handles given: so_DistanceSquar(GetObject(h2), GetObject(h1)) FUN_004028f0; a missing object → 99 999 999
    (the handle form pushes the value twice and returns 1: harmless)
cGetAroundCoord(handle, dirDeg, dist) → x, y              @ FUN_005de220   (33 / 18)
    p = o.position; DirectDistanceTable::ddt_GetFoward(&ddt, (dirDeg mod 360) / 2, dist, &p) FUN_004a2db0 (negative
        directions wrap); returns the point dist units from o in that direction
    # argument order from the disassembly (Ghidra swaps the two ftol results)
cGetCoord_Circle(x, y, radius) → x, y                     @ FUN_005d6720   (9 / 5)
    all three numbers (type 3); MobRegenLoc_Circular(x, y, radius).mrlc_Get FUN_004b0e80 (random point in the circle, §10.4)
cFindAttackBlockLocate(handle, x, y) → boolean            @ FUN_005ee1a0   (4 / 2)
    no argument: false.  o missing or so_IsEmpty: false
    ok = ShineObject::so_FindBlockLocate(o, (x, y), 10000, &out, MapBlock::MapBlockInformation::mbi_IsAttackBlock)
        FUN_004beb40 (walk o → (x, y) until an attack-block cell, §9.2)
    returns ok and out == (x, y): true when the straight line from o to (x, y) (≤ 10 010 units) crosses no
        attack-block cell (KDWater: may the water balloon reach the player)
    # Ghidra drops the out == (x, y) compare; read from the disassembly (0x5ee2ef…0x5ee303)
cGetCurMapIndex(handle) → mapIndex                        @ FUN_005e59b0   (21 / 12)
    o.so_Field ≠ null and fm_MapID (12-byte Name3) not empty: returns the map index string
cGetMapName(mapIndex) → name                              @ FUN_005e8d50   (2 / 2)
    FieldContainer::fc_FindMap; returns fm_MapInfo.Name (the display name of MapInfo.shn)
cIsInMap(handle, mapIndex) → 1 | nothing                  @ FUN_005ef2c0   (14 / 11)
    returns 1 when o.so_Field == fc_FindMap(mapIndex)
cIsInArea(handle, mapIndex, areaName) → boolean           @ FUN_005ead70   (13 / 3)
    handle ≠ 0xFFFF, object, map found: FieldMap::fm_AreaEntry(map, areaName, o.x, o.y) FUN_00427e80 (§15.7)
    returns true / false (always one boolean)
cGetAreaObject(mapIndex, areaName, handle) → 1 | nothing  @ FUN_005dca40   (13 / 9)
    arg 3 present, map has an axial flag: returns 1 when fm_AreaEntry(map, areaName (Name8), o.x, o.y)
    # neither area test checks that o is on that map: only its coordinates are tested against the map's area
```

### 18.4 Items and script strings

```pseudo
cGetItemIndex(itemId) → itemIndex                         @ FUN_005e5cf0   (unused)
    ItemDataBox[itemId].data.InxName when shorter than 31 characters
cGetItemLot(playerHandle, itemIndex) → lot, 0             @ FUN_005dad80   (11 / 7)
    vt 0xbc0 ShinePlayer::so_GetItemLot FUN_0055da60 (non-players: folded `UseItemBase::uib_DirectUse` → nothing):
        inventory locked (sp_Item.invenlocklist vt 0x10 true, e.g. during a trade): fails → nothing
        id = idb_2itemid(name) (unknown → nothing); lot = ItemBag::ib_GetItemLot(ci_Inventory, id)
            + ib_GetItemLot(ci_Equipment, id)  (bag + worn items; quest box, mini-house and action boxes not counted)
    returns lot (u64), 0  (the second result is the lock flag, always 0 when a lot is returned)
cIsEquipItem(playerHandle, itemIndex) → 0 | 1             @ FUN_005e23b0   (2 / 2)
    id known: returns vt 0xd30 ShinePlayer::so_ply_IsEquipItem(ItemInfo.Equip, id) FUN_00560f30 = 1 when the
        equipment slot of that item's Equip type holds this item ID; non-players: folded `return 0` (FUN_00449600)
cGetScriptString(scriptFile, key [, a1 … a5]) → text      @ FUN_005e8b30   (6 / 2)
    set = "ETC" → shinescriptetc; "MenuString" → shinescriptmenusting (both loaded at start, `zs_start_yellow`, Z01);
        else KQScriptManager::operator[] FUN_0064ce70 (the KQ script string files, §8.7; unknown → assert, nothing)
    fmt = ShineScript::ss_String(set, key) FUN_0048ce60 (`ScrString` table of the option file, "" when missing)
    char buf[256] = 0; sprintf(buf, fmt, a1, a2, a3, a4, a5)   (missing arguments are null strings); returns buf
    # (original bug) Z09-B66: sprintf into the 256-byte stack buffer is unbounded; a long text or long arguments
    #   overrun it (the arguments come from scripts, e.g. the map name in the server-menu title)
```

### 18.5 Searches and lists

The list functions return the handles as separate results (`{ f(...) }` in the scripts).

```pseudo
cGetNPCHandle(mapIndex, npcIndex) → handle                @ FUN_005d8df0   (1 / 1)
    map with axial flag: walk with AxialListNPCSearch(npcIndex); returns the first object (NPC, mob, …) whose MobInfo
        InxName matches; nothing when none
cObjectCount(mapIndex, kind) → n                          @ FUN_005e26c0   (41 / 18)
    unknown map / no axial flag / no name: returns 0
    walk AxialListNearScanObjectType(kind, deadCheck 1) over the map; n = members (≤ 200)
    kind 5 (mob): count only members whose mob row is missing or whose MobInfo.IsNPC (+0x52, `struct MobInfo`) ≠ 1
        (mob-kind objects whose MobInfo row is flagged as NPC are not counted)
    returns n
    # (original bug) Z09-B63: the count saturates at 200 (the scan buffer); "more than 200 of a kind" reads as 200
cGetPlayerList(mapIndex) → h1, h2, …                      @ FUN_005f4410   (234 / 34)
    walk AxialListPlayerList over the map; lua_checkstack(count) (fails: assert "cGetPlayerList Lua Stack Lack -",
        nothing); returns every player's handle (dead players included)
cGetAreaObjectList(mapIndex, areaName, kind) → h1, …      @ FUN_005f4620   (36 / 20)
    AxialListAreaObjectList(map, area, kind) over the map (§15.7); lua_checkstack first ("cGetAreaObjectList Lua
        Stack Lack -"); returns the handles
cFindNearestMobList(mapIndex [, mobIndex]) → h1, …        @ FUN_005e6eb0   (1 / 1)
    walk AxialListObjectCollect over the map; for each kind-5 object (mob; NPCs are kind 4) whose so_mob_MobID equals
        mdb_2MobID(mobIndex) (no index: every mob): lua_pushinteger(handle)
    then lua_checkstack(count) (fails: assert "cFindNearestMobList Lua Stack Lack -", returns nothing); returns count
    # not sorted by distance, despite the name
    # (original bug) Z09-B59: the handles are pushed before lua_checkstack; a C function only has LUA_MINSTACK (20)
    #   free slots, so more than about 20 matching mobs write past the Lua stack (heap corruption) before the check
cNearObjectList(centreHandle, range, kind) → h1, …        @ FUN_005f22e0   (16 / 9)
    range ≠ 0 and kind ≠ 0; AxialListNearObjectList(kind) over so_AllOfRange(c, range, includeSelf 0) (kind matches,
        not dead); lua_checkstack first ("cNearObjectList Lua Stack Lack -"); returns the handles (walk order)
    (the list accessor is a folded body named `RollBackPosCallBackEvent::GetLinkData`, the count `alpl_GetCount`)
cGetTargetList(handle, x, y, range) → h1, …               @ FUN_005f0e40   (3 / 3)
    o = GetObject(handle); scan AxialListEnemyInAray { alena_Mob = o } over so_AllOfRange(o, centre (x, y), range,
        includeSelf 0): o's enemies around (x, y), alive, without STA_IMMORTAL / STA_ADLFLOUSSIERIMT, ≤ 200
    returns their handles (no argument / no object: nothing)
    # (original bug) Z09-B60: no lua_checkstack at all; more than about 20 targets overrun the Lua stack (as B59)
cFindNearPlayer(handle, range, classList) → handle        @ FUN_005f37d0   (5 / 3)
    classList must be a table (type 5), else nothing
    list = []; for each (key, value) of classList (lua_next): v = (int)value; if v ≠ 0: list.push(v); pop value
    AxialListFindNearPlayer(list) over so_AllOfRange(o, range, includeSelf 0)
    returns the nearest live object (in practice a player) whose base class (cc_ClassType: 1, 6, 11, 16, 21, 26) is
        in the list; nothing when none
    # (original bug) Z09-B61: the value is popped only when it is non-zero (`lua_settop(-2)` inside the `v ≠ 0`
    #   branch, 0x5f393a); a 0 in classList leaves it on the stack, so the next lua_next uses it as the key
    #   (Lua error "invalid key to 'next'" or a wrong walk)
cObjectFind(centreHandle, range, value, method) → handle  @ FUN_005f33d0   (36 / 10)
    c = GetObject(centreHandle); collect every object within range of c (so_AllOfRange, **includeSelf 1**)
    method (32 bytes, Name8 compare):
        "so_ObjectType":        keep objects whose kind (vt 0x4d0) == (int)value
        "so_mobile_GetIdxName": keep objects whose vt 0x894 so_mobile_GetIdxName == value (mob: MobInfo InxName
                                FUN_00556b60; other objects "" FUN_00555110)
        other: keep none
    returns the kept object with the smallest so_DistanceSquar(c, x) < range² (signed compare); nothing when none
    # the centre itself is a candidate (distance 0) and wins when it matches
cGetNearestObjByCoord(mapIndex, x, y, range, value, method) → handle   @ FUN_005f3a50   (unused)
    the same over so_AllOfRange(map axial flag, centre (x, y), range, includeSelf 1); distance from (x, y)
cGetNearObjListByCoord(mapIndex, x, y, range, value, method [, max]) → h1, …   @ FUN_005f4ef0   (3 / 3)
    the same filter; entries ObjectWithDistanceSquare {owds_pObject, owds_dwDistanceSquare} (8 bytes, distance from
        (x, y)); std::sort with CompareDistanceSquare (nearest first)
    max = (int)arg 7, 0 → unlimited; lua_checkstack(min(count, max)) ("cGetNearObjListByCoord Lua Stack Lack -")
    returns the first max handles
    # x / y order checked in the disassembly (0x5f4fae…0x5f4fcf)
    # (original bug) Z09-B68: the method (and, for so_mobile_GetIdxName, the value) string is not checked; a
    #   missing argument passes a null pointer to strncpy / the compare (crash) in cObjectFind and both ByCoord
    #   functions
```

FiestaHeroes documents cObjectFind as "the first matching object"; the code returns the nearest one *(fh-doc vs code)*.

### 18.6 Effects, sounds and map marks (client packets)

```pseudo
cObjectEffect(handle, effectId) → 1 | nothing             @ FUN_005ea8b0   (1 / 1)
    both numbers; cLuaBroadcast(o, 0xFFFF = sight incl. o, …)
    0x207B NC_ACT_OBJECT_EFFECT_CMD { u16 nHandle = handle; u32 nEffectID = effectId }   (6 bytes)
    returns 1 when sent
cObjectSound(handle, soundFile) → 1 | nothing             @ FUN_005ea6f0   (2 / 2)
    handle a number, soundFile a string; to sight:
    0x207A NC_ACT_OBJECT_SOUND_CMD { u16 nHandle; char sSoundFileName[32] = 32 bytes copied from the Lua string }  (34 bytes)
    # (original bug) Z09-B64: always 32 bytes are copied: for a shorter name the bytes after its terminator are
    #   whatever follows the Lua string in memory; a name of 32+ characters arrives unterminated
cMapMark(mapIndex, marks) → 1 | nothing                   @ FUN_005df860   (17 / 12)
cMapMark_Obj(playerHandle, marks) → 1 | nothing           @ FUN_005dffc0   (2 / 2)
cMapMark_FieldSight(mapIndex, x, y, marks) → 1 | nothing  @ FUN_005e0640   (1 / 1)
    marks must be a table; for each entry e (lua_next), fields read by name, each must have the right type:
        Group (number), x (number), y (number), IconIndex (string), KeepTime (number)
        IconIndex → MiniMapIconType *(pdb2016)*: "MobNormal" 27, "MobChief" 25, "Gate" 5 (MMIT_NPCLink), "RedFlag" 16,
            "BlueFlag" 17, "MobDmg" 26, "Templer" 12, "Mine" 6, "Normal" 13, "LinkTown" 23; cMapMark also knows
            "NotDamaged" 28, "AlreadyDamaged" 29, "MobChrLocFlag" 30, "Kingdom" 4
        a missing / mistyped field or unknown icon name: stop, return nothing, send nothing
    0x6C17 NC_SCENARIO_MAPMARK_CMD { u16 nNum; IconInfo[nNum] { u16 nGroup; SHINE_XY_TYPE nCoord (u32 x, u32 y);
        u8 eMapIcon; u32 nKeepTime } }   (15 bytes per mark, payload 2 + 15·n)
    cMapMark:            AxialListPacketBroadcast to every player in the map (so_AllInMap of the axial flag)
    cMapMark_FieldSight: AxialListPacketBroadcast over so_AllOfRange(map axial flag, centre (x, y), range 0 = map
                         sight, includeSelf 0): the players in sight of (x, y)
    cMapMark_Obj:        kind 2 only; pp_SetPacketLen (too long: assert "cMapMark_Obj : Packet Too Long", nothing
                         sent, still returns 1); else to the player (vt 0x2f8 send object)
    returns 1
    # (original bug) Z09-B65: the entries are written into g_buf while reading the table and the length is checked
    #   only afterwards (pp_SetPacketLen / the broadcaster's constructor): a large table writes past the send buffer
```

The client (`GameFrameWork::On_NC_ACT_OBJECT_EFFECT_CMD` FUN_004b6fa0) reads `nEffectID` as a u16 and plays
`ActionEffectInfo` row `nEffectID & 0xFFFF` on the object (nothing when the handle is not known to it).
`On_NC_ACT_OBJECT_SOUND_CMD` FUN_0049d4d0 plays `sSoundFileName` at the object's position (`SoundMgr`).
`On_NC_SCENARIO_MAPMARK_CMD` FUN_0049d1c0 → `MiniMapWin::AddMapMark` FUN_0054ead0 (also the full map,
`FullMapWin::AddMapMark`): per mark it creates a `MapMarkWin` at (x, y) with an icon (5, 16 and 17 have their own
textures, every other value the default mark), expiry = now + nKeepTime / 1000 (milliseconds), and stores it by
`nGroup`: a new mark replaces the one with the same group. Layouts in `docs/protocol/annotations/Z09.json`.

The two copies `cMapMark_Obj` / `cMapMark_FieldSight` know only the first ten icon names, so a script that uses
"Kingdom" or a `Mob*Damaged` icon with them sends nothing; 2016 scripts use them with the shared names only
*(inferred: older copy of the list, not tagged as a bug)*.

### 18.7 Answers and open points

- Every part-11 row of §14.9 is documented here. Part 12 starts with the message / dialog functions.
- Several functions treat a missing object as a positive answer (`cIsObjectDead`, `cIsObjectAlreadyDead`: dead;
  `cIsNoAttacOrNoMove`: cannot act). Only `cIsMovable`'s case is contradictory (B67).

## 19. Scripts 6: Lua functions for messages, dialogs and screen effects

The 36 functions of the §14.9 row "part 12" (35 bodies: `cEmoticon` = `cEmotion`). Common rules as in §17 (1-based
Lua slots, `GetObject`, "returns nothing" = 0 results, numbers rounded, usage = calls / files in the 2016
`9Data/Shine/LuaScript` tree, `cLuaBroadcast`, map lookup `fc_FindMap` FUN_00466a60 + `fm_GetCenterObject`). Function
names are *(pdb2016)*; FiestaHeroes' signatures *(fh-doc)* were compared (several are listed there without arguments:
`cEffectTimer`, `cMobDialog_String`, `cSomebodyShout`, `cTopView`); the code is given.

Helpers used below:

- **Two send paths per player.** `vt 0x2f8` = `so_GetDataSocketStream` (player FUN_00559860 → `sp_SocketContainer.datastream`,
  live from `so_FirstActionAfterSocketConnect` FUN_00554870 on), `vt 0x2fc` = `so_GetGameSocketStream` (FUN_00559870 →
  `gamestream`, live only from `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 until `so_LinkTo` FUN_0049ad30 sets it back to
  the dummy). Both lead to the same client connection; a packet sent on the game stream before the map login completes
  or after a link-out is dropped. Non-players return `ShineObject::so_dummypacketcontainer` for both
  (`ShineObject::so_GetDataSocketStream` FUN_00554fa0): a send to them does nothing. Below, "→ p (data)" / "→ p (game)".
- **Script strings.** `set = KQScriptManager::operator[](&kqscriptmanager, fileName)` FUN_0064ce70 (null for an unknown
  file), `ShineScript::ss_String(set, key)` FUN_0048ce60 ("" when the key is missing; §18.4). The texts live in the
  script-string files of `cGetScriptString` (§18.4).
- **Mob names.** `MobDataBox::mdb_2MobID(&mobdatabox, inxName)` FUN_00419080 (0xFFFF when unknown; the function then
  sends nothing).
- **`ScriptMsg.shn` (client).** Every "message index" below is a `SM_Inx` (32 bytes) of the client table `ScriptMsg.shn`
  (columns `SM_ID`, `SM_Inx`, `SM_Msg` (512, may hold `%s`), `SM_Pos`, `R`, `G`, `B`, `SM_Size`, `SM_LifeTime` (ms)). The
  server never reads this table. The client looks the index up with `ScriptMsgTab::GetScriptMsgInfo` FUN_00424d00 and
  shows it with `ScriptMsgCtrl::AddMsg(info, text, handle)` FUN_00439cf0: text = the given text, or `SM_Msg` when none;
  colour R/G/B; lifetime `SM_LifeTime / 1000` s (a default when 0); `SM_Pos` 0 = chat bubble over `handle`
  (`OnChat`), 1 = announce, 2 = remain, 3 = autorun, 4 = face-cut message (`FaceCutMsg.shn` row by index), 5 = box
  announce. An unknown index is ignored.
- **Formatted script messages** (`0x6C15`, `0x2079`, `0x207D`): the script passes up to five strings (Lua slots after
  the index; a missing or non-string slot gives length 0). The server writes `nlen[5]` = each string's length as a u8
  and the five strings back to back, without separators or a terminating NUL. The client re-splits the content by
  `nlen` and formats `SM_Msg` with them (`printf`-style `%s`).
  # (original bug) Z09-B75: each length is stored as `strlen & 0xFF` and only that many bytes are copied: a string
  #   of 256+ characters is cut to its length mod 256 (the text stays consistent, but is shortened)

### 19.1 Script messages from `ScriptMsg.shn`

```pseudo
cScriptMessage(mapName, msgIndex, s1…s5)                      @ FUN_005dcbe0   (90 / 27)
    map, its axial flag and msgIndex (string) must exist, else nothing
    0x6C15 NC_SCENARIO_SCRIPTMESSAGE_CMD { char DialogIndex[32] = strncpy(msgIndex, 31); u8 nlen[5];
        char sContent[Σ nlen] }   (payload 0x25 + Σ nlen)
    to every object of the map (AxialListPacketBroadcast + so_AllInMap; players only receive)
    returns nothing
    # (original bug) Z09-B73: strncpy(…, 31) never writes DialogIndex[31]: an index of 31+ characters keeps the byte
    #   the shared send buffer held there (the client's lookup fails unless it happens to be 0)
cScriptMessage_Obj(handle, msgIndex, s1…s5)                   @ FUN_005dcd80   (11 / 5)
    o = GetObject(handle), kind 2 (player), msgIndex a string, else nothing
    same packet → o (game); pp_SetPacketLen refuses (assert "cScriptMessage_Obj : Packet Too Long") → nothing
    returns nothing
cScriptMessage_Range(handle, range, msgIndex, s1…s5)          @ FUN_005f27e0   (1 / 1)
    o = GetObject(handle); range ≠ 0 and msgIndex a string, else nothing
    players = AxialListNearObjectList(kind 2) over so_AllOfRange(o, o.pos, range, include self 0)
        (§18: kind 2, mode ≠ 3: dead players are skipped; the list getter is a folded body named
         RollBackPosCallBackEvent::GetLinkData)
    same packet → each listed player (game)       (strings from slot 4 on)
    returns nothing

cScriptMsg(target, speaker, msgIndex, s1…s5)                  @ FUN_005ebb40   (70 / 11)
    slot 1 nil → nothing; speaker = slot 2 as a number, 0xFFFF when nil; msgIndex (slot 3) must be a string
    0x2079 NC_ACT_SCRIPT_MSG_CMD { u16 nHandle = speaker; char sScriptMsgIndex[32] = 32 bytes copied from msgIndex;
        u8 nlen[5]; char sContent[Σ nlen] }   (payload 0x27 + Σ nlen)
    # (original bug) Z09-B72: the 32 bytes are copied whatever the string's length (same pattern as B64): bytes after
    #   a short index's NUL are whatever follows the Lua string; an index of 32+ characters arrives unterminated
    target is a number (lua_type 3): p = GetObject(target), ≠ 0xFFFF, kind 2, not leaving (so_IsEmpty) → p (game)
    target is a string (lua_type 4): a map name; map and axial flag must exist
        speaker given and found: to the players in sight of the speaker (so_AllOfRange(flag, speaker.pos, range 0 =
            map sight, include self 0), AxialListPacketBroadcast)
        else: to the whole map
    any other type: nothing; returns nothing
cScriptMsg_World(speaker, msgIndex, s1…s5)                    @ FUN_005eb970   (4 / 1)
    speaker = slot 1 (0xFFFF when nil); msgIndex (slot 2) a string
    0x207D NC_ACT_SCRIPT_MSG_WORLD_CMD (same layout as 0x2079, same 32-byte copy, B72) → World Manager
        (sock2wldman); the WM re-sends it as 0x2079 to every player of the world (W04 §2.4)
    returns nothing
cSimpleChatScriptMsg(handle, msgIndex)                        @ FUN_005ea530   (1 / 1)
    slot 1 a number and slot 2 a string (lua_type 3 / 4), o = GetObject(handle), else nothing
    0x2079 { nHandle = handle; sScriptMsgIndex = 32 bytes (B72); nlen = 0 × 5 }  (payload 0x27)
    cLuaBroadcast(o, 0xFFFF): sight of o incl. o; returns 1 when sent
cMessage(handle, msgIndex [, toHandle])                       @ FUN_005ef8f0   (1 / 1)
    o = GetObject(handle), msgIndex a string; toHandle = slot 3 if a number, else 0xFFFF
    0x6C12 NC_SCENARIO_MESSAGE_CMD { char DialogIndex[17] = strncpy(msgIndex, 16) }   (17 bytes)
    # (original bug) Z09-B73: DialogIndex[16] is never written (stale buffer byte for 16+ character indexes)
    cLuaBroadcast(o, toHandle); returns 1 when sent
cNPCChat(handle, msgIndex [, toHandle])                       @ FUN_005efaa0   (3 / 2)
    o = GetObject(handle), msgIndex a string; toHandle = slot 3 if a number, else 0xFFFF
    0x6C11 NC_SCENARIO_NPCCHAT_CMD { char DialogIndex[33] = strncpy(msgIndex, 32); u16 NPCHandle = handle }  (35 bytes)
    # (original bug) Z09-B73: DialogIndex[32] is never written
    cLuaBroadcast(o, toHandle); returns 1 when sent
```

Client (`GameFrameWork`, 2016): `On_NC_SCENARIO_SCRIPTMESSAGE_CMD` FUN_004bbd60 → `AddMsg(info, formatted, 0xFFFF)`
(no speaker); it reads `sContent` up to the next NUL (the server sends none, so stale bytes after the packet are read,
then cut by `nlen`) and formats with `info.SM_Msg` **without checking that the index exists**: a non-empty content with
an unknown index crashes the client (client bug). `On_NC_ACT_SCRIPT_MSG_CMD` FUN_004bc020: same, checks the index, uses
`nHandle` as the speaker (chat bubble for `SM_Pos` 0). `On_NC_SCENARIO_MESSAGE_CMD` FUN_004b6f60: `AddMsg(info, —,
0xFFFF)` (plain `SM_Msg`). `On_NC_SCENARIO_NPCCHAT_CMD` FUN_004bb040: `AddMsg(info, —, NPCHandle)`, and when the NPC is
known to the client, a speech balloon (character vt 0x54) and a chat line `"[%s] : %s"` (name, `SM_Msg`); unknown
handle: debug message "SCENARIO_NPCCHAT_CMD Error. There's no NpcHandle".

### 19.2 Dialog windows and face cuts

```pseudo
cMobDialog(mapName, mobInxName, scriptFile, key)              @ FUN_005db690   (157 / 54)
    map + axial flag, mobId = mdb_2MobID(mobInxName) ≠ 0xFFFF, set = scriptFile, text = ss_String(set, key);
    strlen(text) < 256, else nothing
    0x6C0C NC_SCENARIO_CHATWIN_CMD { u16 mob = mobId; u8 len; char content[len] }  (no NUL)
    to the whole map; returns nothing
cMobDialog_Obj(handle, mobInxName, scriptFile, key)           @ FUN_005db860   (6 / 3)
    o = GetObject(handle): not leaving, kind 2, on a map with an axial flag; same checks and packet → o (data)
cMobDialog_Range(handle, mobInxName, range, scriptFile, key)  @ FUN_005dbaa0   (2 / 1)
    o = GetObject(handle) (any kind), not so_IsEmpty (a dead mob refuses); same checks and packet
    → so_AllOfRange(o, o.pos, range (0 = map sight), include self 0) with AxialListPacketBroadcast
    (its log name string is "cMobDialog_Obj", copied)
cMobDialog_String(mapName, mobInxName, text)                  @ FUN_005ece70   (0 / 0)
    as cMobDialog with a literal text; strlen(text) < 255 (one less than the others)
cMobDialog_FileName(mapName, faceCut, scriptFile, key)        @ FUN_005e4a00   (1 / 1)
    map + flag, set, text < 256 as above
    0x6C19 NC_SCENARIO_DIALOG_CMD { char sFacecutIndex[33] = faceCut (zeroed, strncpy 32: always terminated);
        u8 nLen; char sContents[nLen] }
    to the whole map; returns nothing
```

Client: `On_NC_SCENARIO_CHATWIN_CMD` FUN_0049b0c0 opens the NPC script dialog of mob `mob` with the text
(`NpcDialogWin::OpenNpcScriptDialog` FUN_005f6820, the mob's own face cut) and shows the window;
`On_NC_SCENARIO_DIALOG_CMD` FUN_0049d6a0 does the same with the image `game\NPCFaceCut\<sFacecutIndex>.png` / `.tga`
(FUN_005f6980). Both copy at most `len` bytes into a zeroed 2 KB buffer.

### 19.3 Notices, system messages, NPC chat and shouts

```pseudo
cNotice(mapName, scriptFile, key)                             @ FUN_005e15b0   (88 / 37)
    map + flag, set and key must exist; text = ss_String(set, key)
    so_AllInMap(flag, AxialListWall(text))          AxialListWall ctor FUN_004281a0, ali_Work FUN_004281c0:
        every object: vt 0x784 so_ply_Notice(text) (players only; folded no-op for the rest)
        → 0x2011 NC_ACT_NOTICE_CMD to each player (game), layout §16.5
    returns nothing
cNoticeString(mapName, text)                                  @ FUN_005e16e0   (5 / 3)
    as cNotice with slot 2 as the text, which is not checked
    # (original bug) Z09-B70: a missing / non-string slot 2 gives so_ply_Notice a null text; its strcpy crashes the
    #   zone as soon as the map holds a player
cNotice_Obj(handle, scriptFile, key)                          @ FUN_005e8e50   (34 / 5)
    o = GetObject(handle), not leaving, kind 2, set + key strings: o.so_ply_Notice(ss_String(set, key))
cSystemMessage_Obj(handle, scriptFile, key)                   @ FUN_005e6890   (44 / 4)
    o = GetObject(handle) (kind not checked), set and key; text = ss_String(set, key); strlen < 256
    0x6C1B NC_SCENARIO_SYSTEM_MESSAGE_CMD { u8 nLen; char sMessage[nLen] } → o (data)   (non-players: dummy stream)
cNoticeRedWarningCode(mapName, code)                          @ FUN_005e5ff0   (16 / 2)
    strlen(slot 2) is taken before any check   # (original bug) Z09-B70: a nil slot 2 crashes the zone
    code (≥ 2 characters) → value: "Started" 0x2020, "Remain1min" 0x2023, "Remain30sec" 0x2021,
        "BeAwakened" 0x2022; any other string: return nothing
    0x6C04 NC_SCENARIO_MESSAGENOTICE_CMD { u32 message = value } to the whole map (map + flag must exist)
    returns true (a boolean, the only one in this section); else nothing
cNPCChatTest(handle, text [, toHandle])                       @ FUN_005db4b0   (4 / 2)
    o = GetObject(handle), text a string; toHandle = slot 3 if a number, else 0xFFFF
    buf[256] (stack) = strcpy(text)    # (original bug) Z09-B69: no length check: a text of 256+ characters
                                       #   overruns the stack buffer
    o.so_Chat(toHandle, buf, strlen, chatwin = (toHandle ≠ 0xFFFF), links 0)   (vt 0x530, ShineMobileObject::so_Chat
        FUN_00458c90, Z02 §3.1: 0x2002 NC_ACT_SOMEONECHAT_CMD to sight, or to toHandle only; len is a u8)
    non-mobile objects: ShineObject::so_Chat no-op; returns nothing
cSomebodyShout(mapName, mobInxName, scriptFile, key)          @ FUN_005e5150   (0 / 0)
    map + flag, set, mobId ≠ 0xFFFF, text = ss_String(set, key), strlen < 256
    0x201F NC_ACT_SOMEONESHOUT_CMD (layout §8.7): speaker.mobID = mobId, flag = (flag & ~1) | 2 (isMob, no GM
        colour), len, content; size = len + 0x17 (correct, unlike B10)
    # (original bug) Z09-B71: itemLinkDataCount (byte 0), speaker bytes 2…19 and flag bits 2…7 are never written; the
    #   client reads itemLinkDataCount × 0x67 bytes of item links after the content, so a stale non-zero byte makes it
    #   parse past the packet
    to the whole map; returns 1 when so_AllInMap returns true
```

Client: **0x2011 is shown** by the game scene: `GameFrameWork::On_NC_ACT_NOTICE_CMD` FUN_004b5420 (2016 client) copies
`len` bytes (`len` ≠ 0) into a 128-byte stack buffer, formats it with TextData `0x3830508A` "[Notice] %s" and adds the
line to the announce and author message lists; the text "Admin level is 100" also sets a flag in the frame work. (A
`len` over 127 overruns that client buffer: client bug; the zone sends up to 255.) This corrects §16.5 and the C01
table, which list 0x2011 as ignored (only the non-game scenes ignore it). `On_NC_SCENARIO_SYSTEM_MESSAGE_CMD`
FUN_004ba610 adds `sMessage` as a system message (`AddSysMsg`) when not empty; FiestaHeroes' "doesn't do anything" for
`cSystemMessage_Obj` is wrong for the 2016 pair. `On_NC_SCENARIO_MESSAGENOTICE_CMD` FUN_004ae4a0 re-opens the guild-war
inform window and sets its text from `TextData2`: 0x2020 "Experiment tube has been cracked!", 0x2023 "Experiment subject
will be awakened in 1 minute!", 0x2021 "… in 30 seconds!", 0x2022 "Warning!  Experiment subject has been awakened!";
another value leaves the window showing its old text. `On_NC_ACT_SOMEONESHOUT_CMD` FUN_004a0ec0 shows nothing for
`len` 0 or > 128.

### 19.4 Camera, top view, fog

```pseudo
cCameraMove(mapName, x, y, angleXZ, angleY, dist, moveType)   @ FUN_005dbe30   (153 / 15)
    map + flag must exist; slots 2–7 read as numbers (moveType as an integer)
    if moveType < 2 (signed):
        field.fm_CameraState = moveType          # CS_NONE 0 / CS_MOVING 1 (FieldMap::CameraState)
        0x6C14 NC_SCENARIO_CAMERA_MOVE_CMD { u8 MoveType; SHINE_XY_TYPE ViewCoord = (x, y); u16 AngleXZ = angleXZ;
            u16 AngleY = angleY; u16 Dist = dist }   (15 bytes) to the whole map
        flag.so_CameraMoveSendBriefInfo((x, y), dist)   vt 0xc24, ShineObject::so_CameraMoveSendBriefInfo FUN_00441e00:
            AxialListCameraMove (ali_Work FUN_00441b90) collects every player of the map; alcm_SendBriefInfo
            FUN_00441c50, per player: reset the brief-info batches, sight² as g_SightDistSq (unlimited while
            fm_CameraState is CS_MOVING), so_AllOfRange(player, (x, y), dist, so_ExchageBriefInfo FUN_00441460),
            send the batches (bixall_Send) and the player's own abstates (asl_SendAfterLogin)
    returns nothing
    # (original bug) Z09-B74: the "< 2" test is signed: a negative moveType is stored as the camera state (sight stays
    #   normal, since only 1 counts) and sent as MoveType 0x80…0xFF, which the client ignores
cCameraMove_Obj(handle, x, y, angleXZ, angleY, dist, moveType) @ FUN_005e7920  (4 / 1)
    o = GetObject(handle), not leaving, kind 2; moveType < 2 (signed, B74): same 0x6C14 → o (game);
    then o.so_ply_SendBriefInfo_MoveLayer() (vt 0xdd8 FUN_00441ed0, §9.6: sight exchange around the player)
    the map camera state is not touched, so objects near a far camera point are not sent (inferred: the 2016 use
    keeps the camera near the player)
cTopView(handle, moveType, x, y, distance, angle)             @ FUN_005e6600   (6 / 3)
    o = GetObject(handle) (any kind); sight² as g_SightDistSq for o (0 without map, unlimited with OSS_WIDE or a
    moving camera)
    if moveType == 1 and dist²(o, (x, y)) > sight² / 2: nothing
    0x6C1A NC_SCENARIO_TOPVIEW_CMD { u8 nMoveType; SHINE_XY_TYPE CenterPos = (x, y); u16 nDistance = distance;
        u16 nAngle = angle }   (13 bytes) → o (data)
cMapFog(mapName, fog, depth)                                  @ FUN_005e6260   (1 / 1)
    map + flag, slots 2 and 3 numbers: 0x6C0E NC_SCENARIO_FOG_CMD { u8 fog; u16 depth } to the whole map; returns 1
    no server state: a player who enters the map later does not get it (its log name string is
    "PineEventScriptNode::ShineMapFog::sa_Step", copied from the map-script node)
```

Client: `On_NC_SCENARIO_CAMERA_MOVE_CMD` FUN_004a5df0 (only with its `CameraEffect` object): MoveType 0 → camera back
to the player (effect mode 4); 1 → ground point of `ViewCoord`, `CameraEffect::SetAngle(AngleXZ, AngleY)`, distance
`Dist`, mode 3; other values ignored. `On_NC_SCENARIO_TOPVIEW_CMD` FUN_004a6bf0: 0 → camera back and top-view flag
(GameFrameWork+0x13e0) cleared; 1 → ground point `CenterPos`, angle `nAngle` with a fixed pitch, distance `nDistance`,
flag set. `On_NC_SCENARIO_FOG_CMD` FUN_004a35b0: stores `depth` and sets `World::SetFogDepth(fog / constant)` (0 = off).
2016 use: `cCameraMove` in instance dungeons (War*, AdlF), the class-change gamble and kingdom quests (gate openings, then `cCameraMove(map, 0, 0, 0, 0, 0,
0)` to reset); `cTopView` and `cEffectTimer` in the Oluming / Xiaoming mini games.

### 19.5 Screen effects, timers, sounds, emotions, NPC menu

```pseudo
cEffectMsg(handle, type)                                      @ FUN_005e4540   (18 / 12)
    o = GetObject(handle), not leaving; type < 15: o.so_ply_EffectMsg(type) (vt 0xd88, players only)
    ShinePlayer::so_ply_EffectMsg FUN_00560fc0: type < 15 → 0x2077 NC_ACT_EFFECT_MESSAGE_CMD { u32 nEffectEnum } → p (game)
cEffectMsg_AllInMap(mapName, type)                            @ FUN_005e4670   (6 / 4)
    map + flag, type < 15: 0x2077 to the whole map
    type = EFFECT_MSG_TYPE (fh-doc): 0 WIN, 1 LOSE, 2 DRAW, 3 START, 4 COUNT_8_SEC, 5 SUCCESS, 6 FAIL,
        7 START_OLYMPIC, 8 GOAL_OLYMPIC, 9 SOCCER_WIN, 10 SOCCER_LOSE, 11 SOCCER_DRAW, 12 SOCCER_KICK_OFF,
        13 SOCCER_GOAL, 14 WATER_START (15 values; the client's EffectMsg has 15 slots (pdb2017))
cEffectTimer(handle, function, seconds)                       @ FUN_005e6bb0   (6 / 3)
    o = GetObject(handle) (any kind); function = integer < 2 (signed, B74)
    0x6C1D NC_SCENARIO_EFFECT_TIMER_CMD { u8 nTimerFunction (EFFECT_TIMER_FUNC (pdb2017): 0 ETF_TIMER, 1 ETF_REMOVE);
        u16 nSecond } → o (data); returns nothing
cStartMsg_AllInMap(mapName)                                   @ FUN_005e3af0   (2 / 2)
    map + flag: 0x74E0 NC_GUILD_TOURNAMENT_STARTMSG_CMD { s32 nStartBeforeTime = 5 } to the whole map
cDirectionalArrow(handle, x, y)                               @ FUN_005e8810   (1 / 1)
    o = GetObject(handle), not leaving, kind 2:
    0x6C1E NC_SCENARIO_DIRECTIONAL_ARROW_CMD { SHINE_XY_TYPE DirectionalPos = (x, y) } → o (data)
cDelDirectionalArrow(handle)                                  @ FUN_005e89d0   (3 / 2)
    same checks: 0x6C1F NC_SCENARIO_DEL_DIRECTIONAL_ARROW_CMD {} → o (data)
cPlaySound(handle, soundName)                                 @ FUN_005e4410   (3 / 2)
    o: not leaving, kind 2; name a string: o.so_ply_PlaySound(name) (vt 0xd7c)
    ShinePlayer::so_ply_PlaySound FUN_00561130: len = strlen (u16); len ≤ 256:
        0x2078 NC_ACT_PLAY_SOUND_CMD { u16 FileNameLen; char FileName[len] (no NUL) } → p (game); longer: nothing
cShowCinematicText(handle, text)                              @ FUN_005eec40   (0 / 0)
    o: not leaving, kind 2; text a string: o.so_ply_ShowCinematicText(text) (vt 0xd80)
    ShinePlayer::so_ply_ShowCinematicText FUN_00561090: len ≤ 256 → 0x2082 NC_ACT_SHOW_CINEMATIC { u16 len;
        char text[len] } → p (game)   (no struct in either PDB)
cEndCinematicText(handle)                                     @ FUN_005eeb30   (0 / 0)
    o: not leaving, kind 2: vt 0xd84 ShinePlayer::so_ply_EndCinematicText FUN_00561030 → 0x2083 NC_ACT_END_CINEMATIC {}
cEmotion(handle, actionIndex) = cEmoticon                     @ FUN_005e3e60   (6 / 4 and 1 / 1)
    p = GetObject(handle) as a player (vt 0xbbc), not leaving; id = u8(actionIndex)
    if some ActionViewInfo row (gActionViewInfo, the server's ActionViewInfo.shn) has nIndex == id:
        p.sp_DoEmotion(handle, id)   (vt 0xa40 FUN_00458860, Z02 §4: mode 1/2/6 only, 0x2021 to sight, brief
            emoticon, observer EV_EMOTION, pet dance)
    unlike the client request 0x2020 NC_ACT_EMOTICON_CMD (Z02 §4) the charged-emote check (eActionType 2) is skipped
    returns nothing
cNPCMenuOpen(npcHandle, playerHandle)                         @ FUN_005dcf50   (9 / 9)
    both slots non-nil, both objects exist, npc.vt 0x708 (mob ID) ≠ 0xFFFF, else nothing
    player.so_ply_SendMenuOpenReq(npc)   (vt 0xc2c; non-players: folded no-op)
        ShinePlayer::so_ply_SendMenuOpenReq FUN_00560a40: sp_EndOfTrade(p, 1) (FUN_004c25b0, Z02 §6.4);
        sp_NPCProcess.npchandle = npc.handle; .npcid = npc mob ID
        0x201C NC_ACT_NPCMENUOPEN_REQ { u16 mobid } → p (game)       (Z02 §6.2; client opens that NPC's dialog)
    returns 1 (also when the second object is not a player)
```

`cNPCMenuOpen` sets no role entry (`sp_NPCProcess.npc`) and no range check, unlike `InteractWithNPC` (Z02 §6.2), so a
`0x201D` answer is dropped ("not during npc process"); the menu answer reaches the script through `0x2073` (which uses
`npchandle`) and the NPC's `NPCMenu` event (§14.3) *(inferred from the 2016 use: class-change master and mini-game
NPCs open their menu from their `NPCClick` function)*.

Client: `On_NC_ACT_EFFECT_MESSAGE_CMD` FUN_0049d890 → `EffectMsg::Play(nEffectEnum)` (a full-screen animated word
with its sound). `On_NC_SCENARIO_EFFECT_TIMER_CMD` FUN_0049d8f0: 0 → `PuzzleTimeWin::ResetTime(nSecond)`, the window is
shown only while the top-view flag of 0x6C1A is set; 1 → window closed. `GuildTask::Recv_NC_GUILD_TOURNAMENT_STARTMSG_CMD`
FUN_006b38b0: only `nStartBeforeTime == 5` starts the full-screen count-down effect and its sound (the same packet as
the guild-tournament start). `On_NC_SCENARIO_DIRECTIONAL_ARROW_CMD` FUN_004bc2f0 places the look-at effects
"MarketSearchMe1/2/3" at the ground point (client effect key 1; an existing arrow is moved); 0x6C1F →
`EffectMgr::RemoveClientEff` FUN_0068d420 (key 1 *(inferred)*). `On_NC_ACT_PLAY_SOUND_CMD` FUN_004ba560 plays the named
file through `SoundMgr::PlayInterfaceSound` when not empty. `On_NC_ACT_SHOW_CINEMATIC` FUN_004ba400 starts the
letter-box `TextScreenEffect` with the text; `On_NC_ACT_END_CINEMATIC` FUN_004a6980 stops it. Layouts of all packets of
this section: `docs/protocol/annotations/Z09.json`.

### 19.6 Answers and open points

- Every part-12 row of §14.9 is documented here. 2016 scripts never call `cMobDialog_String`, `cSomebodyShout`,
  `cShowCinematicText`, `cEndCinematicText`.
- §16.5 / C01: 0x2011 is shown by the 2016 game scene (§19.3); corrected in §16.5 and the annotation.
- Open: which `TextData` / sound a `cEffectMsg` type plays (client `EffectMsg` table, C-side); whether a 2016 client
  dialog opened by `cNPCMenuOpen` answers with 0x2073 or 0x201D (client NPC dialog code, C01).

---

## 20. Scripts 7: the Pine map-script language 1 — files, tokens, expressions, the process stack

Pine (`PineEventScript`, files `*.ps`) is the zone's older map-script language: kingdom quests, job changes, wedding,
the guild tournament and some instance dungeons run as Pine "films" (`Movie::PSFilm`, §15, §27). This section is
the reading side: which files exist, how a file is turned into tokens, the value model (every value is a 256-byte
string), expressions, variables and the process stack a running script uses. Statements, blocks and conditions are
§21 (part 14b), the `SysFunc*` / `OtherStatement` nodes and `ScenarioBookShelf` §22 (part 14c), the `Shine*` action
nodes parts 15a–15d. All class and member names are *(pdb2016)*; there are no packets in this section.

### 20.1 Files

- `9Data/Shine/World/PineScript.txt` (option-file format, `OptionReader`; read three times, by three loaders):
  - table `PineScript`, column `ScriptName` (String[32]): one record per script book, a path below
    `9Data/Shine/ScenarioBookShelf/` without extension (`KQ/KingSlime/KingSlime`, `Quest/Quest`, `Guild/GuildTournament`,
    `Wedding/Wedding`, `ID/GraveYard/GraveYard`, …; 58 records in 2016, 16 of them exist as `.ps`, §21.7). A trailing comment `; LuaScript` marks the
    books that were rewritten in Lua; the loader decides the type itself. Loader: `ScenarioBookShelf::sbs_LoadScripts`
    FUN_00509750 (book path format `../9Data/Shine/ScenarioBookShelf/%s.%s`, `sb_GetFileName` FUN_00507440; §22).
  - table `DialogFile`, column `ScriptName`: the script-string files `9Data/Shine/Script/<name>.txt` (`KQKingSlime`,
    `JobChange1`, `Wedding`, `GraveYard`, …) loaded by `KQScriptManager::kqsm_Load` FUN_0064cee0 into `kqscriptmanager`
    (the sets read by `ss_String`, §18.4 / §19; loader in §22).
  - table `RoamingData`, column `RoamingFile`: read by `MobRoaming::MobRoamingSet::mrs_Load` FUN_004b8690 (§10.6). The
    2016 file has **no** `RoamingData` table: `or_Select` finds nothing and the loader returns without loading a path
    (no error), so `mrs_Get` finds no preloaded roaming path in 2016.
- `9Data/Shine/ScenarioBookShelf/**/*.ps`: the Pine scripts (46 files in 2016, Korean comments, CP949).
- `9Data/Shine/MobBehaviorDescript/` (`DefaultBehavior.ps`, 7 `KQ/*.ps`): **not read by the 2016 zone** (answers §6.9).
  No string of the zone binary contains "behavior" (any case, ASCII or UTF-16), and the only `.ps` path format is the
  ScenarioBookShelf one above. The files are leftovers: `DefaultBehavior.ps` uses the words `whoistarget` and
  `getname`, which appear nowhere in the binary (no statement could parse them); the `KQ/*.ps` files are older copies
  of KQ book scripts (`KingSlime.ps` = regen layers with `mobregen` / `call`).

### 20.2 Reading a file: `PineEventScript::pes_Load`

```pseudo
PineEventScript { Script pes_Script }                      # 0xc; ctor FUN_004e1960 → Script ctor FUN_004e1690
Script : ScriptAtom { List<Block>* s_BlockList; ListArray<Block>* s_BlockArray }
    # ctor: block array of 4 Blocks (0x118 bytes each, Block ctor/dtor, §21), list over it; grows by 4

pes_Load(path, int* lineOut) → ok                          @ FUN_004d6c40
    fp = fopen(path, "r")                                  # text mode
    TokenReader tr on the stack: tr_CharReader = {fp, cr_Line = lineOut, cr_UngetBuffer = −1},
        tr_UngetToken = "", tr_Buffer = "", tr_Line = lineOut;  *lineOut = 1
    if !fp: return 0
    ok = pes_Script.sa_Load(&tr)                           # vt 0
    fclose(fp); return ok                                  # *lineOut = line reached (the caller logs it, §22)
    # (original bug) Z09-B78: the reader stores a reason in tr_ErrCode ("Unexpected EOF", "String over line",
    #   "File end in string", "Number read fail"), but nothing ever reads tr_ErrCode: a load error is reported with
    #   the line number only

Script::sa_Load(tr) → ok                                   @ FUN_004e1830
    loop:
        t = tr_GetToken(tr); if t == null: return 1        # end of file = success
        if t != "open": return 0
        unget t
        b = next free Block of s_BlockList (none: l_Enlargement(4); still none → return 0)
        if !b.sa_Load(tr): return 0                         # Block::sa_Load: "open [name] … close", §21
    # tr_GetToken also returns null on a token error, so a broken token after the last block (e.g. an unterminated
    # string) ends the file "successfully" and the rest is ignored (part of Z09-B78)
```

A script file is therefore a list of blocks `open [name] … close` (the top level only checks the token `open`, as
written, case-sensitive; the block syntax is §21). Only `pes_Load`'s caller (`ScenarioBookPS::sb_Load` FUN_005076b0, §22) uses
it.

### 20.3 Characters and tokens: `PineScriptReader`

```pseudo
CharacterReader { _iobuf* cr_fp; int* cr_Line; int cr_UngetBuffer }               # 0xc
TokenReader { CharacterReader tr_CharReader; PineScriptToken tr_UngetToken; PineScriptToken tr_Buffer;
              int tr_BufPnt; char* tr_ErrCode; int* tr_Line }                       # 0x218
PineScriptToken { uchar pst_Buffer[256] }                                           # every token and every value

cr_GetCh() → c                                             @ FUN_004d6730
    c = fgetc; '\n' → ++*cr_Line, return '\n'
    ';' → skip to the end of the line (++*cr_Line at '\n') and read on      # ';' starts a comment anywhere
cr_SkipSpace()                                             @ FUN_004d6770
    take the unget char or read one (same comment rule); repeat while c ≤ 0x20 and c ≠ EOF; keep c as unget char

tr_GetToken(out) → out | null                              @ FUN_004da340
    if tr_UngetToken ≠ "": out = tr_UngetToken; tr_UngetToken = ""; return out      # one token of look-back
    cr_SkipSpace; c = next char; EOF → tr_ErrCode = "Unexpected EOF", return null
    tr_Buffer = c
    c == '"'          → tr_ReadString      @ FUN_004d67f0: read to the closing '"' (kept: the token is "\"text\"");
                                              '\n' → "String over line", EOF → "File end in string" (null)
    c is a digit      → tr_ReadNumber      @ FUN_004d8a60: read digits; stop at a non-alnum char (pushed back);
                                              a letter or '_' right after the digits → "Number read fail" (null)
    c is alnum or '_' → tr_ReadIdent       @ FUN_004d8b30: read [0-9A-Za-z_]*
    else              → a one-character operator token (every punctuation char is its own token:
                        "<=" is '<' '=', "=!=" is '=' '!' '=')
tr_isAlNum(c) @ FUN_004d6900 = [0-9A-Za-z_]; tr_IsOper(c) @ FUN_004d6940 = its negation (EOF included)
~TokenReader @ FUN_004d67e0: fclose(cr_fp) when set
```

- No sign and no decimal point: `-5` is the operator `-` and the number `5`, `1.5` is `1`, `.`, `5`. Statements end
  with the token `.` in the scripts (`wait sec 10.`) *(inferred from the files; read by the statements, §21)*.
- (original bug) Z09-B76: the three readers append to the 256-byte `tr_Buffer` with no length check: a string, number
  or name longer than 255 characters writes past the buffer into `tr_BufPnt` / `tr_ErrCode` / `tr_Line` of the
  reader on `pes_Load`'s stack. The 2016 scripts stay far below (longest string 48 characters).
- (original bug) Z09-B77: the comment rule also applies inside strings: in `"a;b"` the `;b"` and the rest of the line
  are skipped and the string goes on with the next line (no "String over line" error, the newline was eaten by the
  comment skip). No 2016 script has a `;` inside a string.

`PineScriptToken` helpers (all on the 256-byte buffer, none bounds-checked):

| Function | Address | Effect |
|---|---|---|
| ctor(`uchar*`) | FUN_004d62c0 | strcpy |
| ctor(`int`) | FUN_004d62e0 | `sprintf("%d")` |
| `pst_ToLower` | FUN_004d6240 | ASCII A–Z → a–z (keyword arguments of the action nodes are compared after this) |
| `pst_RemoveQuatator` | FUN_004d6310 | `"text"` → `text` (only when the first and last chars are `"`); returns 1 when done |
| `pst_GetNumber(cut)` | FUN_004d6360 | **the value of the trailing decimal digits** (`"abc12"` → 12, `"-3"` → 3, `"abc"` → 0); `cut` ≠ 0 removes them from the token |
| `pst_GetChar` / `pst_SetChar` | FUN_004d63c0 / FUN_004d63d0 | byte read / write by index (used by `SysFuncShineRemoveFisrt`) |
| `pst_Merge(tok)` | FUN_004d63e0 | strcat |
| `pst_MergeString(char*)` | FUN_004d72a0 | strcat through a 256-byte stack copy |
| `pst_MergeNumber(n)` | FUN_004d7310 | strcat of `sprintf("%d", n)` (results of conditions and system functions) |
| `operator==` / `!=` | FUN_004d6420 / FUN_004d6470 | strcmp, case-sensitive |
| `operator+=` `-=` `*=` | FUN_004d7390 / FUN_004d74b0 / FUN_004d75d0 | `this = prefix(this) + sprintf("%d", num(this) op num(other))`: the trailing digits of both are the operands, the non-digit prefix of `this` is kept |
| `operator/=` | FUN_004d76f0 | same with `/` (C integer division); `num(other)` = 0 (also: no digits) → returns **null** (the expression fails) |

### 20.4 Values and numbers

Every Pine value is a `PineScriptToken` string. Numbers are not a separate type: an arithmetic operator or a numeric
comparison reads each side with `pst_GetNumber`, i.e. the run of decimal digits at the end of the string. A name with a
number suffix stays a name: `"Mob1" + 1` = `"Mob2"` (the prefix of the left side is kept). Handles, counts and HP rates
are stored as decimal strings (`pst_MergeNumber`); the action nodes read them back with `pst_GetNumber`.

- (original bug) Z09-B79: there are no negative numbers. `pst_GetNumber` ignores a `-`, so a negative result such as
  `0 - 1` = `"-1"` is read back as 1 by every comparison and by the next operation; `+=` keeps the `"-"` as the
  prefix: `"-1" + 1` = `"-2"`. Every subtraction that can go below zero is affected. The 2016 scripts subtract
  constants in brackets (`(120 - 60)`) and one counter that stops at 0 (`KQ/GordonMaster.ps`: `NextTeleportHP -
  200` from 800, loop ends on `=!= 0`): nothing goes negative in 2016.
- (original bug) Z09-B81: concatenation (`%`, `pst_Merge*`) and the arithmetic operators append to the 256-byte token
  without a length check: a value longer than 255 characters overwrites what follows the token (the stack frame of
  the expression, or the next variable of the variable stack). Values built from player names in a loop (the KQ result
  lists `#(S % Count) = @CharName(…)`, `AxialListKQResult`) are the risky ones.

### 20.5 Expressions: `Express`, `Term`, `Identify`, atoms

Grammar, as the loaders read it (`sa_Load`, ScriptAtom vt 0):

```text
Express   := Term [ CalcOp Express ]                          # right-recursive
CalcOp    := '+' (9) | '-' (10) | '*' (11) | '/' (12) | '%' (13 = concatenate)
Term      := '#' Term                                         # indirection: the variable named by the term's value
           | Identify | Number | String | SystemFunction | '(' Express ')'
Identify  := '#' Express | Id                                 # (inside a Term the '#' case is taken by Term)
Id        := token whose first char is [A-Za-z_]              # a variable name
Number    := token of digits only
String    := token starting with '"' (quotes removed)
SystemFunction := '@' name ArgumentList                       # 0x34 bytes, ctor FUN_004d7cf0; form from the scripts
                                                              #   (`@CharName(PlayerHandle)`) (inferred), loader §21
ArgumentList   := '(' { Express } ')'                         # at most 10, no separators
CompareOp := "==" (1) | "!=" (2) | '<' (3) | '>' (4) | "<=" (5) | ">=" (6) | "===" (7) | "=!=" (8)
```

```pseudo
Express { Term e_Term; CalculateOperator e_Oper; Express* e_Express }               # 0x11c; ctor FUN_004d7db0
Express::sa_Load(tr)                                      @ FUN_004d8530
    if !e_Term.sa_Load: return 0
    if !e_Oper.sa_Load: return 1                              # no operator: the term alone
    e_Express = new Express; return e_Express.sa_Load
Express::sa_Calculate(out, ps)                            @ FUN_004d8640
    if !e_Term.sa_Calculate(out, ps): return null
    if !e_Express: return out
    rhs = e_Express.sa_Calculate(…)                            # the whole rest of the expression
    switch e_Oper.co_OperType: 9 out += rhs, 10 out −= rhs, 11 out *= rhs, 12 out /= rhs (null on 0), 13 out = out ‖ rhs
    # (original bug) Z09-B80: no precedence and right-associative: a - b - c = a - (b - c), a / b * c = a / (b * c),
    #   a * b + c = a * (b + c). The 2016 scripts put brackets everywhere it would matter; only `60 * 60 * 1000` chains
~Express @ FUN_004d7de0 (deletes e_Express, the term's parts)

CalculateOperator::sa_Load(tr)                            @ FUN_004db250
    t = token; first char '%' → 13, '*' → 11, '+' → 9, '-' → 10, '/' → 12; else unget t, return 0
    { PineScriptToken co_Oper; int co_OperType }                                       # 0x108 (both operator classes)

Term { Term* t_Term; ScriptAtom* t_Atom }                                              # 0xc
Term::sa_Load(tr)                                          @ FUN_004dbde0
    t = token (none: 0)
    t == "#" → t_Term = new Term; return t_Term.sa_Load
    unget t; try in turn, each a new atom that is deleted when its sa_Load fails:
        Identify (vt FUN_004db410), Number (FUN_004db370), String (FUN_004db330), SystemFunction
    all failed: t = token; t == "(" → Express; then the token must be ")" → 1; else delete, t_Atom = null, 0
    # (original bug) Z09-B83: when the token is not "(" it is not pushed back: a failed Term eats one token. Harmless
    #   where the whole statement fails, wrong where a caller treats a failed term as "no further argument" (§21)
Term::sa_Calculate(out, ps)                                @ FUN_004da2e0
    t_Atom → t_Atom.sa_Calculate(out, ps)
    t_Term → name = t_Term.sa_Calculate(out, ps); out = ps_FindVariable(ps, name)        # '#X' = value of variable "value of X"
    neither → null
~Term @ FUN_004d7d30

Identify { Id* i_Id; Express* i_Exp }                                                  # 0xc; ctor FUN_004d6500, dtor FUN_004dad20
Identify::sa_Load(tr)                                      @ FUN_004db410
    t = token (none: 0); t ≠ "#" → unget, i_Id = new Id, return i_Id.sa_Load; else i_Exp = new Express, return i_Exp.sa_Load
Identify::sa_Calculate(out, ps)                            @ FUN_004d6650      # vt 8 (value use)
    i_Id  → Id::sa_Calculate (the variable's value)
    i_Exp → out = value of the expression                     # the computed NAME, not the variable's value (see open points)
Identify::i_GetToken(out, ps)                              @ FUN_004d9ea0      # keyword-style arguments of the action nodes
    i_Id  → out = the identifier itself (the word as written: "all", "sec", …)
    i_Exp → out = value of the variable named by the expression
Identify::i_GetVariable(ps) → PineScriptToken*             @ FUN_004d9f60      # write target of the action nodes
    i_Id  → ps_FindVariable(ps, the identifier)
    i_Exp → ps_FindVariable(ps, value of the expression)      # `#(S % Count) = …` writes variable "S"+Count
    expression failed → null

Id { PineScriptToken i_Identify }                                                       # 0x104
Id::sa_Load(tr)          @ FUN_004db3c0   token; first char a letter or '_' → 1; else unget, 0
Id::sa_Calculate(out,ps) @ FUN_004da2b0   out = *ps_FindVariable(ps, i_Identify)   (the null check after it is dead)
Number { PineScriptToken n_Number }   sa_Load @ FUN_004db370: token of digits only (else unget, 0)
String { PineScriptToken s_String }   sa_Load @ FUN_004db330: token starting with '"' → pst_RemoveQuatator; else unget, 0
Number::sa_Calculate @ FUN_004d6710 = String's vt 8 too (same body): out = the stored token
```

Compare operators (used by `Condition`, §21) are read by `CompareOperator::sa_Load` FUN_004db1b0 from the first char:
`!` → `co_Excremation` FUN_004dabb0 (needs `=`: `!=` = 2), `<` / `>` → `co_NotEqual` FUN_004dac50 (`<=` 5 / `>=` 6;
without `=` the token is pushed back: `<` 3 / `>` 4), `=` → `co_Equal` FUN_004daa50 (`=` then `=` or `!`; a third `=`
gives `===` 7 / `=!=` 8, otherwise the token is pushed back and only `==` (1) is accepted; a lone `=` is not a compare
operator). Their meaning (`Condition::sa_Calculate` FUN_004d87a0; result written as `"1"` / `"0"` with
`pst_MergeNumber`):

| Type | Text | Test |
|---|---|---|
| 1 / 2 | `==` / `!=` | `num(left) == / != num(right)` (trailing digits) |
| 3 / 4 / 5 / 6 | `<` / `>` / `<=` / `>=` | numeric, same reading (so `"-3" < "2"` is false: Z09-B79) |
| 7 | `===` | string equality (case-sensitive): 1 / 0 |
| 8 | `=!=` | string compare: 0 when equal, else the strcmp sign as a u16 (`1` or `65535`): "not equal" is any non-zero |

2016 usage (lines of the ScenarioBookShelf scripts): `===` 27, `=!=` 13, `==` 43, `!=` 7, `<=` 10, `>=` 13.

`ArgumentList { ScriptAtom* al_Express[10] }` (0x2c): `sa_Load` FUN_004db570 reads `(`, then up to 10 expressions until
`)` (a failed expression fails the list; after 10 the next token must be `)`); a first token other than `(` is pushed
back (0). `al_GetArgument(i, out, ps)` FUN_004d64c0: `out = ""`, then the value of argument `i` when `i < 10` and it
exists (a missing argument gives `""`).

`ScriptAtom` vtable (all node classes, §21–§22 too): vt 0 `sa_Load(tr)`, vt 4 `sa_Step(arg, ps, &ip)` (statements),
vt 8 `sa_Calculate(out, ps)` (values), vt 0xc "is this the block named …" (blocks). The defaults are folded `return 0`
bodies (FUN_00401a80 / FUN_00449600 / FUN_004a9c90): an atom that is not a statement steps as "done", one that is not a
value calculates to null, one that is not a block never matches. `ScriptAtom` itself has `_purecall` at vt 0.

### 20.6 Variables and the process stack: `PineScriptStack`

```pseudo
ProcessStack {                                                        # 0x10234, one per Pine film
    { ScriptAtom* node; int ip } ps_Stack[32]                         # call stack of nodes; ip = the node's own cursor
    int ps_StackPoint
    VariableStack ps_VarStack                                         # { VarArray vs_Stack[128]; int vs_StackPoint }
                                                                      #   VarArray = { token varname; token varcontent }
    Script* ps_Script
    ps_Shine { u32 waittick; int player; int mobnum; Movie::Theater* theater; MobBreeder* mobbreeder; int hprate;
               PineScriptToken* block; PineScriptToken* argument; ShineObject* currentmob; ShineScript* shinescript }
    PineScriptToken ps_ScriptName
}
ctor @ FUN_004d8c00 (built by Movie::PSFilm and Movie::LuaFilm ctors; VarArray ctor FUN_004d69e0 empties both tokens)
dtor @ FUN_004d6b20

ps_Ready(script)                       @ FUN_004d6b40   # Movie::Theater::t_PlayFilm (§27.2)
    ps_StackPoint = 0; ps_Stack[0] = {script, ip 0}; ps_Script = script
    ps_Shine.argument = block = shinescript = currentmob = null; ps_VarStack.vs_StackPoint = 0      # variables dropped
    # waittick, player, mobnum, theater, mobbreeder, hprate are left as they were (t_PlayFilm resets none of them, §27.2)
ps_Step(arg) → r                       @ FUN_004d6b90   # Movie::Theater::t_Routine, every film step
    top = ps_Stack[ps_StackPoint]; top.node == null → 0
    return top.node.sa_Step(arg, this, &top.ip)        # vt 4; the meaning of r and of ip per node: §21
ps_Push(node) → ok                     @ FUN_004d6be0   # StateIf / StateCall
    ps_StackPoint > 30 → 0 (depth limit 32: nothing pushed)
    ps_Stack[++ps_StackPoint] = {node, ip 0}; 1
ps_Pop() → ok                          @ FUN_004d6c20   # every statement node when it is done (94 callers)
    ps_StackPoint == 0 → 0; else --ps_StackPoint, 1
ps_ExitBlock(name) → found             @ FUN_004d8c70   # StateBreak ("break \"main\".")
    walk from the top: if node.vt 0xc(name) → that entry's ip = 9999 (= finished), return 1
    else pop and test the next; at the bottom (sp 0) without a match → return 0     # the stack is then fully unwound
ps_PushVariable(name) → content*       @ FUN_004d6bd0   = vs_Push (no caller outside the class; `var` uses vs_Push via §21)
ps_FindVariable(name) → content*       @ FUN_004d8ce0
    name == null → assert "Null variable", return &deftkn
    vs_FindVariable(name) or &deftkn                    # deftkn: one static empty token
vs_Push(name) → content*               @ FUN_004d6a90
    vs_StackPoint ≥ 127 → assert "Variable stack overflow" (name), null      # 127 usable of 128 slots
    vs_Stack[vs_StackPoint++] = {name, (content kept)}; return &content
    # the content of a reused slot is not cleared here (the `var` statement sets it, §21)
vs_FindVariable(name) → content*       @ FUN_004d69f0
    search from the newest slot down (an inner `var` hides an outer one of the same name), case-sensitive
    not found → assert "PineScriptStack::VariableStack::vs_FindVariable : Variable not found" (name), null
```

- Scope: `Block::sa_Step` FUN_004d81b0 saves `vs_StackPoint` when a block starts (ip 0) and restores it when its last
  statement is done, so the variables a block declares (`StateVarDeclear::sa_Step` FUN_004da040: `vs_Push(name)`, then
  the initial value = its expression) disappear at the block's `close`; `ps_Ready` empties the whole stack (§21).
- (original bug) Z09-B82: a missing variable returns the address of the static `deftkn` (`ps_FindVariable`'s local
  static, destructor FUN_0069e080). The action nodes write their results through `i_GetVariable` (e.g. a handle into
  the named variable); when the variable was not declared they write into `deftkn`, and from then on every lookup of
  any missing variable, in every film, returns that value instead of `""`. Each miss also writes an assert log line.

### 20.7 `ScriptParameterPaser`: typed arguments for four nodes

Used only by the action nodes `SaveLinkto`, `RegisterGTPortal`, `GTRegisterNPC`, `GTMobRegenKey` (§22).

```pseudo
ScriptParameterPaser { Express** m_ppExpress; ProcessStack* m_pPS; std::string m_strErrorMsg; PineScriptToken m_tkn }  # 0x128
ctor(express array, ps) @ FUN_004dd650; dtor FUN_004dd680 / FUN_004e0970; SetErrorMsg(text) @ FUN_004e2380 (prefix of the assert text)
GetByObject(i, ShineObject*& o) → ok  @ FUN_004e2510
    m_tkn = m_ppExpress[i].sa_Calculate(m_pPS); failed → assert "<ErrorMsg>Parameter Index : <i>", false
    o = som_GetObject(&shineobjmanager, (u16)pst_GetNumber(m_tkn)); return o ≠ null       # no assert when missing
GetByDWARD(i, u32& v) → ok            @ FUN_004e2780   same, v = pst_GetNumber(m_tkn)
GetByString(i, std::string& s) → ok   @ FUN_004e29d0   same, s = m_tkn
# index i is not range-checked and m_ppExpress[i] is called without a null test: whether a node can pass a missing
# argument is checked with the nodes (§22)
```

### 20.8 Logging

`PineScriptLog` (DAT_14d458e6) is a `DebugLoggingNull`: its static initialiser FUN_0069a2a0 only writes a line to
`Dbg.txt` and calls `EraseOldLogList("PineScript")` (exit destructor FUN_0069fdf0); it logs nothing. The script tracer
`PineScriptTracer::ScriptTracer::operator<<` FUN_004b8c50 is an empty body. Pine errors therefore surface only as
`AssertClass::ac_AssertFail` lines (variable not found, stack overflow, parameter index) and as the load-error line of
§22.

### 20.9 Open points of this section

- `Identify::sa_Calculate` on a `#expr` form returns the computed name, while `i_GetToken` / `i_GetVariable` resolve
  the variable. A `Term` never builds that case (it handles `#` itself); whether a statement calls vt 8 on an
  `Identify` it loaded with `#` is checked in §21 / §22.
- What `sa_Step`'s result and `ip` mean per node: §21.
- Both answered in §21.8.

## 21. Scripts 8: the Pine map-script language 2 — statements, blocks and how a film runs

This section is the running side of Pine (§20 is the reading side): the grammar of a script file, the registry of
all statements, blocks and the script, how a film steps through its process stack, and the control statements
(`var`, assignment, `if`, `while`, `infinite`, `call`, `break`, `print`, `permillage`) with conditions and the `@`
system-function call. The action statements (`Shine*` nodes and the nine `OtherStatement` nodes) only appear here in
the registry table: their loader `OtherStatement::sa_Load` and the `SysFunc*` bodies are §22 (part 14c), the `Shine*`
steps parts 15a–15d. All class, member and function names are *(pdb2016)*; there are no packets in this section.

### 21.1 Grammar of a script file

```text
Script    := { Block }                                              # §20.2; the film starts at the block named main
Block     := "open" [ "[" Id "]" ] { Statement } "close"            # Id: [A-Za-z_][0-9A-Za-z_]*; no name = ""
Statement := one registered statement (§21.2), tried in reverse registration order:
  action     := keyword [ Identify ] { Express } "."                # Shine* / OtherStatement nodes (§22, §23–§26)
  break      := "break" [ Express ] "."                             # name of the block to leave
  permillage := "permillage" Identify "."
  print      := "print" Express "."
  call       := "call" Express [ Express ] "."                      # block name [default block name]
  if         := "if" Condition [ "then" Block ] [ "else" ( if | Block ) ]
  while      := "while" Condition Block
  infinite   := "infinite" Block
  var        := "var" { Identify Express } "."                      # 1…64 pairs, each name with an initial value
  Block                                                             # an anonymous nested block is a statement too
  assign     := Identify "=" Express "."
Condition := Express CompareOp Express                              # §20.5
```

Keywords are compared case-sensitively as whole tokens (`if` / `then` / `else` / `open` / `close` / `var` / …).
Every statement except `if`, `while`, `infinite` and a nested block ends with the token `.`. A 2016 example
(`KQ/GordonMaster.ps`, Korean comments removed):

```text
open [KeyDrop]
    if KeyDropRate > @Random(0 99) then
    open
        itemdrop InterruptArg KeyDropIndex 1000000.
        interrupterase "KeyDrop".
    close
    else
    open
        KeyDropRate = KeyDropRate + 5.
    close
close
```

### 21.2 The statement registry: `ps_statementlist`

```pseudo
StatementList { StatementBase* sl_Array[128]; int sl_Point; int sl_Pnt }           # 0x208; global ps_statementlist
Statement : ScriptAtom { ScriptAtom* s_Statement }                                  # 8; the slot type of a block

StatementList::StatementList(sl)                   @ FUN_004de8d0
    # static initialiser `dynamic_initializer_for_'ps_statementlist'' FUN_00697310 (CRT init table entry 0x6a2608)
    sl_Point = 0
    append 94 prototypes in the order of the table below (index 0…93): `new` of each class with its constructor
    # full (sl_Point > 127) → assert "Too many statement" and the prototype is dropped
StatementList::sl_AddStatement(sl, st)             @ FUN_004d6990   # the same append (used by the ctor for the last 13)
AutoRegList::AutoRegList(reg, st)                  @ FUN_004d6d10   # the same append into ps_statementlist
    # the nine `…AutoReg` static initialisers FUN_00697bc0, FUN_00697c40, FUN_00697cc0, FUN_00697d40, FUN_00697dc0,
    # FUN_00697e40, FUN_00697ec0, FUN_00697f40, FUN_00697fc0 (CRT entries 0x6a2750…0x6a2770, after the list ctor)
    # each build one ScriptBase<X> prototype = OtherStatement(keyword, idRead, min, max) with X's vtable: index 94…102

Statement::sa_Load(slot, tr) → ok                  @ FUN_004d85d0   # a block reading one statement
    for i = sl_Point−1 down to 0:                                   # sl_Pnt = i (global cursor); the LAST registered first
        slot.s_Statement = sl_Array[i].vt[0x10]()                   # sb_CloneMe: a fresh empty node of that class
        if slot.s_Statement.vt[0](tr): return 1                     # its sa_Load
        node vtable = ScriptAtom; operator delete(node)             # (original bug) Z09-B84 / B88, see below
    return 0                                                        # no statement matched: the file fails to load
Statement::Statement @ FUN_004d6520 (s_Statement = null); ~Statement @ FUN_004d6530: deletes s_Statement with the
    plain ScriptAtom vtable (no node destructor runs)
```

`sb_CloneMe` (vt 0x10) of each prototype builds an empty node of its class; the prototypes themselves are never
loaded. `ScriptBase<X>` (the template of the nine auto-registered nodes) only adds this `sb_CloneMe` and a virtual
`scalar_deleting_destructor` at vt 0x14 (`~OtherStatement`, then free): FUN_004f8610 / FUN_004f8a10 (`RegisterGTPortal`),
FUN_004f8680 / FUN_004ebaf0 (`SaveLinkto`), FUN_004f86f0 / FUN_004f8a40 (`ClearSaveLinkto`), FUN_004f8760 / FUN_004f8a70
(`NPCChatNoFacecut`), FUN_004f87d0 / FUN_004f8aa0 (`ScinarioCodeParty`), FUN_004f8840 / FUN_004f8ad0 (`HasAbstate`),
FUN_004f88b0 / FUN_004ebb20 (`BroadcastCode`), FUN_004f8920 / FUN_004ebb50 (`GTRegisterNPC`), FUN_004f8990 / FUN_004f8b00
(`GTMobRegenKey`). The generic deletes in `Statement::sa_Load` / `~Statement` do not use vt 0x14 (no caller of it
found in the §21 code).

All 84 `Shine*` nodes and the nine `ScriptBase<>` nodes are `OtherStatement`s (0xBC bytes, ctor
`OtherStatement::OtherStatement(keyword, os_IDRead, os_ExpressNumMin, os_ExpressNumMax)` FUN_004dae40; their vt 0 is
`OtherStatement::sa_Load`, §22). The columns "target" (= `os_IDRead`: an `Identify` is read after the keyword) and
"args" (= expression count min–max) are the constructor arguments; how the loader uses them is §22. "Uses" = statements
in the 46 `.ps` files of 2016 / files that use it (counted from the files, the listed and the unlisted ones, §21.7).

| # | Keyword | Class | `sb_CloneMe` | target | args | Uses | Where |
|---|---|---|---|---|---|---|---|
| 0 | `(X =)` | `StateAssignment` | FUN_004db0b0 |  |  | 248/27 | §21.5 |
| 1 | `open` | `Block` | FUN_004de520 |  |  | 878/46 (all blocks) | §21.3 |
| 2 | `var` | `StateVarDeclear` | FUN_004dafe0 |  |  | 77/36 | §21.5 |
| 3 | `infinite` | `StateInfinite` | FUN_004de590 |  |  | 164/35 | §21.5 |
| 4 | `while` | `StateWhile` | FUN_004de600 |  |  | 11/7 | §21.5 |
| 5 | `if` | `StateIf` | FUN_004d8070 |  |  | 131/30 | §21.5 |
| 6 | `call` | `StateCall` | FUN_004d80b0 |  |  | 422/33 | §21.5 |
| 7 | `print` | `StatePrint` | FUN_004da010 |  |  | 1/1 | §21.5 |
| 8 | `permillage` | `StatePermillage` | FUN_004db080 |  |  | 0/0 | §21.5 |
| 9 | `break` | `StateBreak` | FUN_004d6570 |  |  | 213/31 | §21.5 |
| 10 | `printf` | `ShinePrintf` | FUN_004e8fe0 | — | 1 | 7/4 | §25 |
| 11 | `scriptfile` | `ShineScriptFile` | FUN_004e9050 | — | 1 | 37/27 | §26.2 |
| 12 | `timelimit` | `ShineTimeLimit` | FUN_004e90c0 | yes | 1 | 43/27 | §26.5 |
| 13 | `interruptclear` | `ShineInterruptClear` | FUN_004e9130 | — | 0 | 153/30 | §15 |
| 14 | `interruptset` | `ShineInterruptSet` | FUN_004e91a0 | yes | 3–5 | 760/33 | §15 |
| 15 | `interrupterase` | `ShineInterruptErase` | FUN_004e9210 | — | 1 | 36/9 | §15 |
| 16 | `waitinterrupt` | `ShineWaitInterrupt` | FUN_004e9280 | yes | 1 | 153/33 | §15 |
| 17 | `mobregen` | `ShineMobRegen` | FUN_004e92f0 | yes | 6–7 | 206/20 | §25 |
| 18 | `doorbuild` | `ShineDoorBuild` | FUN_004e9360 | yes | 6 | 27/9 | §13 |
| 19 | `npcstand` | `ShineNPCStand` | FUN_004e93d0 | yes | 6 | 81/9 | §25 |
| 20 | `change2mob` | `ShineChange2Mob` | FUN_004e9440 | yes | 1 | 2/1 | §23 |
| 21 | `change2door` | `ShineChange2Door` | FUN_004e94b0 | yes | 1 | 0/0 | §23 |
| 22 | `change2npc` | `ShineChange2NPC` | FUN_004e9520 | yes | 1 | 3/2 | §23 |
| 23 | `exchange2mob` | `ShineExchange2Mob` | FUN_004e9590 | yes | 1 | 2/2 | §24.5 |
| 24 | `dooropen` | `ShineDoorOpen` | FUN_004e9600 | yes | 1 | 32/9 | §13 |
| 25 | `doorclose` | `ShineDoorClose` | FUN_004e9670 | yes | 1 | 40/9 | §13 |
| 26 | `vanish` | `ShineObjectVanish` | FUN_004e96e0 | yes | 0 | 21/5 | §25 |
| 27 | `regengroup` | `ShineRegenGroup` | FUN_004e9750 | — | 2–4 | 854/23 | §25 |
| 28 | `waitlogin` | `ShineWaitUserLogin` | FUN_004e97c0 | yes | 0 | 26/26 | §26.5 |
| 29 | `pause` | `ShinePause` | FUN_004e9830 | yes | 1 | 505/32 | §25 |
| 30 | `npcchat` | `ShineNPCChat` | FUN_004e98a0 | yes | 1 | 47/5 | §25 |
| 31 | `npcshout` | `ShineNPCShout` | FUN_004e9910 | yes | 1 | 11/2 | §25 |
| 32 | `chatwin` | `ShineChatWindow` | FUN_004e9980 | — | 2–9 | 215/17 | §23 |
| 33 | `chatwinrange` | `ShineChatWindowRange` | FUN_004e99f0 | — | 4–9 | 25/2 | §23 |
| 34 | `summonmob` | `ShineSummonMob` | FUN_004e9ad0 | yes | 2 | 225/13 | §26.3 |
| 35 | `questresult` | `ShineQuestResult` | FUN_004e9b40 | yes | 0 | 31/15 | §25 |
| 36 | `reward` | `ShineReward` | FUN_004e9bb0 | yes | 0 | 14/13 | §25 |
| 37 | `someoneshout` | `ShineSomeoneShout` | FUN_004e9a60 | — | 2 | 0/0 | §26.2 |
| 38 | `broadcast` | `ShineBroadcast` | FUN_004e9c20 | yes | 1–2 | 268/33 | §23 |
| 39 | `linkto` | `ShineLinkTo` | FUN_004e9c90 | yes | 4 | 64/34 | §25 |
| 40 | `whoclickme` | `ShineWhoClickMe` | FUN_004e9d70 | yes | 1 | 28/7 | §26.6 |
| 41 | `whokillme` | `ShineWhoKillMe` | FUN_004e9de0 | yes | 1 | 1/1 | §26.6 |
| 42 | `itemdrop` | `ShineItemDrop` | FUN_004e9d00 | yes | 2 | 21/7 | §24.1 |
| 43 | `invensearch` | `ShineInvenSearch` | FUN_004e9e50 | yes | 2 | 12/3 | §24.3 |
| 44 | `itemcreate` | `ShineItemCreate` | FUN_004e9ec0 | yes | 1 | 2/2 | §24.2 |
| 45 | `itemerase` | `ShineItemErase` | FUN_004e9f30 | yes | 1–2 | 32/9 | §24.2 |
| 46 | `findhandle` | `ShineFindHandle` | FUN_004e9fa0 | yes | 2 | 7/3 | §24.4 |
| 47 | `abstateset` | `ShineAbstatSet` | FUN_004ea010 | yes | 3–4 | 26/15 | §23 |
| 48 | `abstatereset` | `ShineAbstatReset` | FUN_004ea080 | yes | 1 | 9/2 | §23 |
| 49 | `suicide` | `ShineSuicide` | FUN_004ea0f0 | yes | 0 | 32/7 | §26.4 |
| 50 | `run` | `ShineRun` | FUN_004ea160 | yes | 2 | 4/1 | §25 |
| 51 | `walk` | `ShineWalk` | FUN_004ea1d0 | yes | 2 | 0/0 | §26.4 |
| 52 | `maplight` | `ShineMapLight` | FUN_004ea240 | — | 3 | 9/2 | §25 |
| 53 | `mapfog` | `ShineMapFog` | FUN_004ea2b0 | — | 2 | 1/1 | §25 |
| 54 | `effectobj` | `ShineEffectObject` | FUN_004ea320 | yes | 4 | 4/2 | §13 |
| 55 | `effectloc` | `ShineEffectLocate` | FUN_004ea390 | yes | 6 | 25/2 | §13 |
| 56 | `aggro` | `ShineAggro` | FUN_004ea400 | yes | 2 | 2/1 | §23 |
| 57 | `mobweaponrate` | `ShineMobWeaponRate` | FUN_004ea470 | yes | 1–8 | 40/4 | §8.2 |
| 58 | `mobdetectrange` | `ShineMobDetectRange` | FUN_004ea4e0 | yes | 1 | 10/5 | §25 |
| 59 | `heal` | `ShineHeal` | FUN_004ea550 | yes | 1 | 5/5 | §24.6 |
| 60 | `animate` | `ShineAnimate` | FUN_004ea5c0 | yes | 1 | 11/6 | §23 |
| 61 | `duplicate` | `ShineDuplicate` | FUN_004ea630 | yes | 1 | 0/0 | §24.5 |
| 62 | `waitidle` | `ShineWaitIdle` | FUN_004ea6a0 | — | 0 | 11/6 | §26.5 |
| 63 | `deathcountclear` | `ShineDeathCountClear` | FUN_004ea710 | — | 0 | 4/1 | §24.6 |
| 64 | `itemattrset` | `ShineItemAttrSet` | FUN_004ea780 | yes | 2 | 0/0 | §24.2 |
| 65 | `scinariocode` | `ShineScinarioCode` | FUN_004ea7f0 | yes | 1 | 1/1 | §26.1 |
| 66 | `battlestart` | `ShineBattleStart` | FUN_004ea860 | yes | 0–2 | 10/8 | §23 |
| 67 | `battlestop` | `ShineBattleStop` | FUN_004ea8d0 | yes | 0 | 22/8 | §23 |
| 68 | `sendquestresult` | `ShineSendKQResult` | FUN_004ea940 | yes | 1 | 17/8 | §26.1 |
| 69 | `invidualreward` | `ShineInvidualReward` | FUN_004ea9b0 | — | 2 | 15/8 | §24.7 |
| 70 | `returnvalue` | `ShineReturnValue` | FUN_004eaa20 | — | 2 | 6/1 | §25 |
| 71 | `sublayershift` | `ShineSubLayerShift` | FUN_004eaa90 | yes | 2 | 0/0 | §26.4 |
| 72 | `teleport` | `ShineTeleport` | FUN_004eab00 | yes | 1–3 | 13/4 | §26.4 |
| 73 | `itemowner` | `ShineItemOwner` | FUN_004eab70 | yes | 2 | 2/1 | §24.3 |
| 74 | `mobattr` | `ShineMobAttribute` | FUN_004eabe0 | yes | 2 | 4/1 | §25 |
| 75 | `collect` | `ShineObjectCollect` | FUN_004eac50 | yes | 4 | 0/0 | §25 |
| 76 | `endofkq` | `ShineEndOfKingdomQuest` | FUN_004eacc0 | — | 0 | 43/21 | §26.1 |
| 77 | `endofgt` | `ShineEndOfGuildTournament` | FUN_004ead30 | — | 2 | 4/2 | §24.8 |
| 78 | `gtresult` | `ShineGuildTorunamentResult` | FUN_004eada0 | yes | 1–2 | 4/2 | §24.8 |
| 79 | `costumecreate` | `ShineCostumeCreate` | FUN_004eae10 | yes | 3 | 0/0 | §23 |
| 80 | `costumetakeoff` | `ShineCostumeTakeOff` | FUN_004eae80 | yes | 2 | 0/0 | §23 |
| 81 | `weddingcomplete` | `ShineWeddingComplete` | FUN_004eaef0 | — | 2 | 1/1 | §26.7 |
| 82 | `playerwork` | `ShinePlayerWalk` | FUN_004eaf60 | yes | 2 | 6/1 | §25 |
| 83 | `findplayer` | `ShineFindPlayer` | FUN_004eafd0 | yes | 1–2 | 6/1 | §24.4 |
| 84 | `teleportall` | `ShineTeleportAll` | FUN_004eb040 | yes | 0–4 | 1/1 | §26.4 |
| 85 | `briefeffect` | `ShineBriefEffect` | FUN_004eb0b0 | yes | 1 | 2/1 | §23 |
| 86 | `banfromarea` | `ShineBanFromArea` | FUN_004eb120 | — | 5 | 3/1 | §23 |
| 87 | `RegisteFlag` | `ShineRegesteFlag` | FUN_004eb190 | — | 3 | 10/2 | §25 |
| 88 | `RegisteGate` | `ShineRegesteGate` | FUN_004eb200 | — | 4 | 20/2 | §25 |
| 89 | `DiceGameStart` | `ShineDiceGameStart` | FUN_004eb270 | — | 1 | 2/2 | §24.8 |
| 90 | `revival` | `ShineRevival` | FUN_004eb2e0 | yes | 0 | 5/5 | §25 |
| 91 | `spawn` | `ShineSpawn` | FUN_004eb350 | — | 1–2 | 7/3 | §26.3 |
| 92 | `hpset` | `ShineHPSet` | FUN_004eb3c0 | yes | 1 | 1/1 | §24.6 |
| 93 | `questmobkill` | `ShineQuestMobkill` | FUN_004eb430 | — | 3 | 10/9 | §25 |
| 94 | `RegisterGTPortal` | `RegisterGTPortal` | FUN_004f8610 | — | 4 | 10/2 | §22 |
| 95 | `SaveLinkto` | `SaveLinkto` | FUN_004f8680 | — | 4 | 2/2 | §22 |
| 96 | `ClearSaveLinkto` | `ClearSaveLinkto` | FUN_004f86f0 | — | 0 | 2/2 | §22 |
| 97 | `NPCChatNoFacecut` | `NPCChatNoFacecut` | FUN_004f8760 | yes | 1 | 0/0 | §22 |
| 98 | `ScinarioCodeParty` | `ScinarioCodeParty` | FUN_004f87d0 | yes | 1 | 0/0 | §22 |
| 99 | `HasAbstate` | `HasAbstate` | FUN_004f8840 | yes | 3 | 0/0 | §22 |
| 100 | `BroadcastCode` | `BroadcastCode` | FUN_004f88b0 | yes | 1 | 0/0 | §22 |
| 101 | `GTRegisterNPC` | `GTRegisterNPC` | FUN_004f8920 | — | 2 | 20/1 | §22 |
| 102 | `GTMobRegenKey` | `GTMobRegenKey` | FUN_004f8990 | — | 3 | 10/1 | §22 |

Trial order and its effects:

- The registry is tried from index 102 down to 0: the nine `ScriptBase<>` nodes first, then the `Shine*` nodes, then
  `break` … `var`, a nested block, and the assignment last. Keywords are distinct, so the order only matters for
  a variable whose name is a keyword: `pause = 1.` is taken by the `pause` node and fails; keywords are reserved
  words in practice *(inferred from the order)*.
- A candidate that fails after it has read past its keyword (e.g. `if` with a broken condition, `call` without `.`)
  does not give the tokens back (only the first token is pushed back, §20.3): the remaining candidates see the
  wrong tokens and all fail, so the load fails at a later line than the real error. Error reporting only, the
  outcome (file not loaded) is the same.
- (original bug) Z09-B84: a failed candidate is freed but `slot.s_Statement` keeps the freed pointer. When no
  candidate matches, `Statement::sa_Load` returns 0 with that dangling pointer in a slot of the block's statement
  list; `ScenarioBookPS::sb_Load` FUN_005076b0 keeps the half-loaded `PineEventScript` after the "load failed" assert,
  and its next destruction (`sb_Load` of the same book again, or the book's delete; §22) runs `~Statement` on the slot
  and frees the pointer a second time (heap corruption). Only a script with a syntax error reaches it; every listed
  2016 Pine book passes the statement check of §21.7.
- (original bug) Z09-B88: nodes are freed without their destructors (the vtable is reset to `ScriptAtom` first, and
  only the `ScriptBase<>` nodes have a virtual destructor, which these deletes do not call): everything a node allocated while
  loading (an `if`'s blocks, `call`'s default expression, an expression's `Express` / `Term` chain) leaks, for every
  failed candidate and for every node when a script is unloaded. `List<Block>::l_Enlargement` FUN_004e13b0 also leaks:
  it constructs the new `Block`s (each allocating a statement list) and then overwrites their list pointers with
  the moved ones. Load-time only; a reload of the books leaks the old script.

### 21.3 Blocks and the script

```pseudo
Block : StatementBase { BlockName b_BlockName; int b_VarStackPoint; List<Statement>* b_StatementList;
                        ListArray<Statement>* b_StatementArray }                       # 0x118
BlockName : ScriptAtom { Id bn_Name }                                                  # 0x108

Block::Block(b)                                    @ FUN_004de410
    name ""; statement array of 16 Statement slots + a List over them; b_VarStackPoint is not initialised
Block::~Block(b)                                   @ FUN_004dada0   # deletes the list (vt 0, scalar dtor), then the slots (~Statement each)
BlockName::~BlockName @ FUN_004d6560 (vtable resets only); Block::sb_CloneMe @ FUN_004de520 (new Block)

Block::sa_Load(b, tr) → ok                         @ FUN_004dc1e0
    t = token; t ≠ "open" → unget t, return 0
    b_BlockName.sa_Load(tr)                                         # result ignored (a broken "[name" still loads)
    loop:
        t = token; none (EOF / token error) → return 0              # a block must be closed
        t == "close" → return 1
        unget t
        slot = next free slot of b_StatementList (list vt 2; none → List<Statement>::l_Enlargement(8) FUN_004d9720;
               still none → return 0)                                # slots are appended: file order = run order
        if !Statement::sa_Load(slot, tr): return 0

BlockName::sa_Load(bn, tr) → ok                    @ FUN_004dc0c0
    t = token; t ≠ "[" → unget t, return 1                          # anonymous block, name ""
    bn_Name.sa_Load(tr) (Id: first char a letter or '_') fails → return 0
    t = token; t == "]" → return 1; else unget t, return 0

Block::sa_BlockNameCheck(b, name) → match          @ FUN_004d65f0   # vt 0xc, used by ps_ExitBlock (§20.6)
    name == null → 1 (any block matches); else strcmp(bn_Name, name) == 0 (case-sensitive)

Script::sa_FindBlock(s, name) → Block*             @ FUN_004d7fd0
    walk s_BlockList in file order; first block with bn_Name == name; name == null or none → null
    # top-level blocks only: blocks nested in statements are not in s_BlockList and cannot be called
Script::Script @ FUN_004e1690 / ~Script @ FUN_004e1790 (block array of 4, grown by 4: List<Block>::l_Enlargement
    FUN_004e13b0 moves name, var mark and list pointers into new Blocks, B88); PineEventScript::~PineEventScript
    @ FUN_004e1970 = the same inline
```

Containers (template instances, nothing script-specific beyond the copy noted): `List<Statement>` ctor FUN_004dd8d0,
`l_MakeList` FUN_004dd350, `l_GetInList(index, &cursor)` FUN_004d6e90 (the `index`-th entry in list order, null past
the end), `l_Enlargement` FUN_004d9720 (moves the `s_Statement` pointers, nulls the old ones), `l_PushA` FUN_004dda70 /
`l_PushZ` FUN_004dd950 (copy `s_Statement` into a new head / tail slot), `l_PopA` FUN_004dd990, `l_PopZ` FUN_004dd9e0,
`scalar_deleting_destructor` FUN_004dda30 (frees only the link array); `List<Block>` ctor FUN_004ddab0, `l_MakeList`
FUN_004dd4d0, `l_PushA` FUN_004ddb70 / `l_PushZ` FUN_004ddbe0 (copy name, var mark and list pointers), `l_PopA`
FUN_004ddc50, `l_PopZ` FUN_004ddce0, `scalar_deleting_destructor` FUN_004ddb30. Only `l_GetInList`, the free-slot
slot (vt 2) and `l_Enlargement` are used by the script code.

### 21.4 How a film runs

A film owns one `ProcessStack` (§20.6). `ps_Ready` puts the `Script` at the bottom (`ps_Stack[0]`, ip 0). After that:

```pseudo
# once per main-loop pass: ShineAxialFlag flag[2] of the map runs its cinema (§12.7) →
Movie::FilmCase::fc_Routine(fc, list, arg)         @ FUN_00508e40
    if fc.fc_Film and !Movie::FilmBase::fb_Routine(fc.fc_Film, arg): list.vt[0xc](…)     # film removed (§27.3)
Movie::FilmBase::fb_Routine(f, arg) @ FUN_005085f0 = Movie::Theater::t_Routine(&f.fb_Theater, arg)
Movie::Theater::t_Routine(t, arg) → keep           @ FUN_00508090
    t_SenarioType == ST_PS:  return ps_Step(&t.t_Screen, arg) ≠ 0                         # one node step
    t_SenarioType == ST_LUA: t_LuaScript: lss_Routine(t_LuaScript, "Main", LuaArgumentInstanceDungeon(t_Field)); return 1
                             (no script: return 0)
```

So a Pine film makes **exactly one node step per main-loop pass**, and **any step that returns 0 ends the film**
(the Lua films call `Main` every pass instead). Each node's `sa_Step(arg, ps, &ip)` follows one convention: `ip` is the
node's own cursor in its stack entry (0 when pushed); the node pushes a child and returns 1 (the child runs from the
next pass), or pops itself (`ps_Pop` / `--ps_StackPoint`) and returns 1 when it is done, or returns 1 without popping
to be stepped again next pass (the waiting action nodes: `pause` §25.5, `waitlogin` §26.5, `waitinterrupt` §15), or returns 0 on an error. `arg` is not used by the
nodes of this section.

```pseudo
Script::sa_Step(s, arg, ps, &ip)                   @ FUN_004d8100   # the bottom entry
    ip == 0: b = sa_FindBlock("main"); none → return 0              # no [main]: the film ends at its first step
             ip = 1; push b (sp ≥ 31 → return 0); return 1
    ip ≠ 0: sp == 0 → return 0                                      # main finished (or was left by break): film ends
Block::sa_Step(b, arg, ps, &ip)                    @ FUN_004d81b0
    ip == 0: b_VarStackPoint = ps.vs_StackPoint                      # variable scope starts
    st = l_GetInList(b_StatementList, ip)                            # ip-th statement; past the end (ip 9999 after a break) → null
    st: ip++; push st (sp ≥ 31 → return 0); return 1
    none: if b_VarStackPoint ≥ 0: vs_StackPoint = b_VarStackPoint;   # the block's variables are dropped
              sp ≠ 0 → pop, return 1
          return 0
Statement::sa_Step(slot, arg, ps, &ip)             @ FUN_004d8250   # the slot wrapper around every statement
    ip == 0: ip = 1; push slot.s_Statement (sp ≥ 31 → return 0); return 1
    ip ≠ 0: sp ≠ 0 → pop, return 1; else return 0
```

- **Cost:** a statement takes at least four passes: the block pushes the slot, the slot pushes the node, the node
  runs and pops, the slot pops. A control statement adds its own step and its block's start / end. Time-based waits
  in the action nodes compare against `g_Now` (§25.5, §26.5), so the pass rate changes only how fast the script moves
  between waits.
- **Depth:** 32 stack entries (`ps_Push` and the inline pushes refuse when `sp > 30`). Each nesting level (a block
  inside `if` / `while` / `infinite` / `call`, or a nested block) costs three entries (slot, control node, block):
  with the script and `main` at the bottom, an action can sit at most 9 levels below `main`. A deeper push returns 0
  and the film ends without a log line *(depth count inferred from the push rules)*.
- (original bug) Z09-B86: `b_VarStackPoint` belongs to the `Block` object, not to the stack entry. A block that is
  on the stack twice (a block that `call`s itself directly or through a handler block) overwrites the mark of the
  outer run; when the inner run ends both restore the inner mark, so the outer run's variables stay on the variable
  stack until an enclosing block ends (or overflow it, "Variable stack overflow", which ends the film at the next
  `var`). No 2016 block calls its own name; handler blocks reached through `call InterruptBlock.` were not traced.

### 21.5 Control statements

```pseudo
StateVarDeclear { Identify svd_VarName[64]; Express svd_Express[64]; int svd_VarNum }   # 0x4a08 (`var`)
StateVarDeclear::sa_Load(v, tr)                    @ FUN_004dc3a0
    t = token; t ≠ "var" → unget, 0
    svd_VarNum = 0
    while svd_VarNum < 64:
        t = token (none → 0); t == "." → return 1; unget t
        svd_VarName[n].sa_Load (Identify: a name, or `#` expression) fails → 0
        svd_Express[n].sa_Load fails → assert "Var : Not init", 0   # every variable needs an initial value
        n++
    after 64 names the next token must be "." (else 0)               # `var .` with no names is valid
StateVarDeclear::sa_Step(v, arg, ps, &ip)          @ FUN_004da040
    for each pair i < svd_VarNum:
        name = svd_VarName[i].i_GetToken(ps)                         # the word as written (or the value of `#expr`)
        slot = vs_Push(ps.ps_VarStack, name); null (stack full, "Variable stack overflow") → return 0   # film ends
        svd_Express[i].sa_Calculate(out = slot, ps) fails (division by 0) → return 0                       # film ends
    pop; return 1                                                     # all in one step
    # the variables live until the enclosing block ends (§21.4); a `var` inside a loop body is re-declared on every
    # pass of the body and dropped at its end. Lookups search newest first, so an inner `var X` hides an outer X.
StateVarDeclear::sb_CloneMe @ FUN_004dafe0

StateAssignment { Identify sa_LeftValue; Express sa_Express }                         # 0x12c (`X = …`)
StateAssignment::sa_Load(a, tr)                    @ FUN_004dcc00
    sa_LeftValue.sa_Load; t = token; t == "="; sa_Express.sa_Load; t = token; t == "." → 1; anything else → 0
    # no token is pushed back on failure; it is the last candidate, so the file fails to load anyway
StateAssignment::sa_Step(a, arg, ps, &ip)          @ FUN_004db110
    i_GetToken(sa_LeftValue, ps)                                     # computed and unused (left for the tracer)
    target = sa_LeftValue.i_GetVariable(ps)                          # missing variable → &deftkn (Z09-B82, §20.6)
    target null (the `#` expression failed) → return 0               # film ends
    sa_Express.sa_Calculate(out = target, ps) fails → return 0       # film ends
    pop; return 1
    # (original bug) Z09-B85: the expression is computed straight into the variable: Express::sa_Calculate writes its
    #   first term into `out` before it evaluates the rest (§20.5), so when the assigned variable appears after the
    #   first term it reads the new partial value: `X = 1 + X` gives 2 for any X, `S = "a" % S` gives "aa". With X
    #   inside the first term it works (`KeyCore0 = (KeyCore0 * TotalCore) / 100.`, Quest/GoldHill.ps). A failed
    #   expression (division by 0) also leaves the partial value in the variable. No 2016 assignment has the bad form.
StateAssignment::sb_CloneMe @ FUN_004db0b0

StateIf { Condition si_Condition; ScriptAtom* si_True; ScriptAtom* si_False }        # 0x350
StateIf::StateIf @ FUN_004d7fa0 (branches null); StateIf::sb_CloneMe @ FUN_004d8070
StateIf::sa_Load(s, tr)                            @ FUN_004de670
    t = token; t ≠ "if" → unget, 0
    si_Condition.sa_Load fails → 0                                   # Condition::sa_Load, §21.6
    t = token (none → 0)
    t == "then": si_True = new Block; its sa_Load fails → 0
    else: unget t                                                    # (original bug) Z09-B87, below
    t = token (none → 0)
    t ≠ "else": unget t; return 1
    si_False = new StateIf; its sa_Load ok → return 1                # "else if …" chains
    free it (B88); si_False = new Block; its sa_Load fails → 0; return 1
StateIf::sa_Step(s, arg, ps, &ip)                  @ FUN_004d8400
    ip == 0: ip = 1
             r = si_Condition.sa_Calculate(ps)                        # "1" / "0" (or 65535 for =!=, §20.5)
             branch = pst_GetNumber(r) ≠ 0 ? si_True : si_False
             branch: return ps_Push(branch)                           # depth full → 0, the film ends
    sp ≠ 0 → pop, return 1; else 0                                    # no branch, or the branch has finished
    # (original bug) Z09-B87: without `then` the true branch is silently absent (si_True = null, no error) and the
    #   `open … close` that was meant as the branch is read as the next statement, a nested block that always runs.
    #   `if c then open … close` is the only working form; all 131 `if`s of 2016 have `then`.

StateWhile { Condition sw_Condition; Block sw_Block }                                 # 0x460
StateWhile::sa_Load(w, tr)                         @ FUN_004dc640   "while", Condition, Block (no `then`); else unget / 0
StateWhile::sa_Step(w, arg, ps, &ip)               @ FUN_004d8300   # ip unused
    r = sw_Condition.sa_Calculate(ps); n = trailing digits of r (inline pst_GetNumber)
    n ≠ 0: push &sw_Block (sp > 30 → return 0); return 1          # the body; when it pops, the while steps again
    else: sp ≠ 0 → pop, return 1; else 0
    # the condition is re-evaluated after every pass of the body; the body is one Block object, re-pushed each time
StateWhile::sb_CloneMe @ FUN_004de600

StateInfinite { Block si_Block }                                                       # 0x11c
StateInfinite::sa_Load(i, tr)                      @ FUN_004dc590   "infinite", then si_Block.sa_Load
StateInfinite::sa_Step(i, arg, ps, &ip)            @ FUN_004d82c0
    push &si_Block (sp > 30 → return 0); return 1                   # never pops itself: only a break that names an
                                                                     # enclosing block (or the end of the film) leaves it
StateInfinite::sb_CloneMe @ FUN_004de590

StateCall { Express sc_CallBlock; Express* sc_DefaultBlock }                          # 0x124
StateCall::sa_Load(c, tr)                          @ FUN_004dc880
    t ≠ "call" → unget, 0; sc_CallBlock.sa_Load fails → 0
    t = token; "." → 1; else unget, sc_DefaultBlock = new Express, load it, then the token must be "." (else 0)
StateCall::sa_Step(c, arg, ps, &ip)                @ FUN_004da180
    ip == 0: ip = 1
        name = sc_CallBlock.sa_Calculate(ps); b = sa_FindBlock(ps.ps_Script, name)
        b: push b (sp ≥ 31 → return 0); return 1
        sc_DefaultBlock: b = sa_FindBlock(value of sc_DefaultBlock); b: return ps_Push(b)
        assert "PineEventScriptNode::StateCall::sa_Step : not exist default routine" (name); return 0   # film ends
    ip ≠ 0: sp ≠ 0 → pop, return 1; else 0                           # the called block has finished
    # the block name is an expression: `call "SelfHealStart".`, `call InterruptBlock.` (variable set by
    # `waitinterrupt`, §15.4), `call InterruptBlock "Default".` (Map/OXFieldInit.ps); only top-level blocks are found
StateCall::sb_CloneMe @ FUN_004d80b0

StateBreak { Express* b_Break }                                                         # 8
StateBreak::sa_Load(b, tr)                         @ FUN_004dc710
    t ≠ "break" → unget, 0; t = token; "." → 1 (b_Break null)
    else unget; b_Break = new Express; load; then the token must be "." (else 0)
StateBreak::sa_Step(b, arg, ps, &ip)               @ FUN_004da120
    name = b_Break ? b_Break.sa_Calculate(ps) : null
    return ps_ExitBlock(ps, name)                                   # §20.6: pops every entry above the nearest Block
        # whose name matches (null: the nearest block), sets that entry's ip = 9999 and returns 1; no match: the
        # stack is unwound to the script and 0 is returned (film ends)
StateBreak::sb_CloneMe @ FUN_004d6570
```

What `break` does, from these rules:

- `break "main".` (55 uses): `main` gets ip 9999, ends on the next pass, the script sees `sp == 0`: **the film ends**.
- `break "<called block>".` from a handler: leaves the named block and everything it started (loops, calls), and
  goes on after the `call` that started it; this is how the 2016 interrupt loops end:
  `open [HeroDoorClick] … infinite open waitinterrupt InterruptBlock "InterruptArg". call InterruptBlock. close close`
  with `break "HeroDoorClick".` in the handler block `[HDC_DoorHeroClick]` (KQ/GordonMaster.ps).
- A break that names a loop body (`infinite open [Loop] … break "Loop".`) or a bare `break.` (nearest block, no 2016
  use) only ends the current pass of the body: `while` re-tests its condition, `infinite` starts the body again.
- A name that is not on the stack ends the film (whole stack unwound, `ps_ExitBlock` returns 0).

```pseudo
StatementBaseExpress { uchar sbe_Command[32]; Express sbe_Express }                  # 0x140
StatementBaseExpress::StatementBaseExpress(e, command) @ FUN_004d9e40   (strcpy of the keyword)
StatementBaseExpress::sa_Load(e, tr)               @ FUN_004dcb00   token == sbe_Command, Express, "."
StatePrint : StatementBaseExpress ("print")        sb_CloneMe @ FUN_004da010
StatePrint::sa_Step(p, arg, ps, &ip)               @ FUN_004d84c0
    sbe_Express.sa_Calculate(ps) into a stack token; result dropped; pop; return 1
    # prints nothing (the tracer is empty, §20.8): only the side effects of `@` functions in the expression remain.
    # One 2016 use: `print #("GateHandle" % Count).` (KQ/RoumenGate.ps, not listed in PineScript.txt)

StatePermillage { Identify sp_Var }                                                     # 0x10
StatePermillage::sa_Load(p, tr)                    @ FUN_004dc9f0   "permillage", Identify, "."
StatePermillage::sa_Step(p, arg, ps, &ip)          @ FUN_004ebcc0
    v = sp_Var.i_GetVariable(ps)                                     # missing → &deftkn
    v: *v = "" then pst_MergeNumber(v, well512_GetRandom(1000))      # 0…999 (§18.1); the "" comes from a folded
                                                                     # body that only clears the first byte
    return ps_Pop(ps)
    # no 2016 script uses it (scripts use @Random(0 99) in a condition)
StatePermillage::sb_CloneMe @ FUN_004db080
```

`CeaseFireSender::CeaseFireSender` FUN_004d6300 is the folded body (`byte[0] = 0`) that `permillage` calls on the token.

### 21.6 Conditions and `@` system functions

```pseudo
Condition : ScriptAtom { Express c_Left; CompareOperator c_Oper; Express c_Right }   # 0x344
Condition::Condition @ FUN_004d7ea0 (empty expressions, operator type 0); ~Condition @ FUN_004d7f30
Condition::sa_Load(c, tr) → ok                     @ FUN_004d6590
    c_Left.sa_Load and c_Oper.sa_Load and c_Right.sa_Load            # §20.5; no token pushed back on failure
Condition::sa_Calculate(c, out, ps)                @ FUN_004d87a0   # fully in §20.5: both sides evaluated into stack
    # tokens, their failures ignored (a failed side keeps its partial value or ""), result "1" / "0" (=!= : 0 / 1 / 65535)
```

`if` uses `pst_GetNumber` of the result, `while` the same digit scan inline: a comparison is true when its result's
trailing digits are non-zero, so `=!=` (1 or 65535 when different) works as "not equal".

```pseudo
SystemFunction : ScriptAtom { ArgumentList sfm_ArgumentList; SysFuncBase* sfm_Function }   # 0x34
SystemFunction::SystemFunction @ FUN_004d7cf0      # 10 empty arguments; sfm_Function = &sysfuncbase
SystemFunction::sa_Load(f, tr) → ok                @ FUN_004db7c0   # one of the Term alternatives (§20.5)
    t = token (none → 0); t ≠ "@" → unget, return 0
    name = token (none → 0); sfm_ArgumentList.sa_Load fails → 0      # parentheses are required: @DeathNum()
    sfm_Function = the singleton of `name` (table below, case-sensitive compare)
    unknown: assert "PineEventScriptNode::SystemFunction::sa_Load : undefined function" (name); return 0
        # the tokens are not pushed back: the statement around it fails to load
SystemFunction::sa_Calculate(f, out, ps)           @ FUN_004d66f0
    return sfm_Function.vt[0](out, ps, &sfm_ArgumentList)            # sfb_Calculate(out, ps, args); bodies §22
SysFuncBase::sfb_Calculate(out, ps, args) @ FUN_004d64f0: out = "", return out   # the default (unused after a load)
```

| `@` name | Singleton (global) | Uses 2016 |
|---|---|---|
| `SquarRoot` | `sysfuncsqrt` (`SysFuncSQRT`) | 0 |
| `Distance` | `sysfuncdistance` (`SysFuncDistance`) | 0 |
| `Random` | `sysfuncrand` (`SysFuncRand`) | 15 |
| `mobregen` / `doorbuild` / `npcstand` | `sysfuncshinemobregen` / `sysfuncshinedoorbuild` / `sysfuncshinenpcstand` | 0 |
| `change2mob` / `change2door` / `change2npc` | `sysfuncshinechange2mob` / `…change2door` / `…change2npc` | 0 |
| `Count` | `sysfuncshinecount` | 22 |
| `RestSec` | `sysfuncshinerestsec` | 1 |
| `CharClass` / `CharName` | `sysfuncshinecharclass` / `sysfuncshinecharname` | 1 / 12 |
| `DeathNum` | `sysfuncshinedeadnum` | 16 |
| `CircularScatter` | `sysfuncshinecircularlocate` | 2 |
| `RemoveFirst` | `sysfuncshineremovefisrt` | 48 |
| `GetObjectList` | `sysfuncshinegetobjectlist` | 2 |
| `KQResultList` / `KQTopList` | `sysfuncshinekqresultlist` / `sysfuncshinekqtoplist` | 8 / 10 |
| `DistanceBetween` | `sysfuncshinedistance` | 2 |
| `PlayerInArea` | `sysfuncshineplayerinarea` | 10 |
| `Range` | `sysfuncshinerange` | 0 |
| `IsGateUse` | `sysfuncshineisgateuse` | 10 |
| `GetWinnerGuild` / `GetLoseGuild` | `sysfuncshinegetwinnerguild` / `sysfuncshinegetloseGuild` | 4 / 0 |

25 functions (the 25 `SysFunc*` classes of §22). `mobregen`, `doorbuild`, `npcstand` and the `change2*` names exist
both as action statements (`mobregen X "Mob" x y d r "…".`) and as `@` functions; the scripts use only the statements.

### 21.7 The 2016 scripts against this grammar

A first-level check of every `.ps` file (statement starts against the registry, ignoring comments) gives:

- The 16 of the 58 `World/PineScript.txt` books that exist as `.ps` (`KQ/UnderHall`, `KQ/UnderHall2`, `KQ/Honeying`,
  `KQ/GordonMaster`, `KQ/KQHBat1…5`, `Quest/Quest`, `Promote/JobChange1`, `Promote/JobChange2-1`, `Guild/GuildTournament`,
  `Wedding/Wedding`, `ID/d_NestOfLeviathan`, `Map/Monkey`) use only registered statements. The other 42 records have
  no `.ps` at that path (18 of them are marked `; LuaScript`; how the shelf picks Lua or Pine and what it does with a
  missing file is §22).
- The files with an older dialect are not listed: `KQ/KickOut`, `KQ/TesScript`, `KQ/Quest`, `KQ/KingSlime/{Main,Suc,Fail}`,
  `KQ/UnderHall/{Main,Suc,Fail}`, `KQ/ConditionOfHero/…` and the `Quest/` copies of some of them use `WaitTime`,
  `wait`, `Regen`, `Terminate`, `shout`, `freepk`, `remove`, which are not statements in 2016: they would not load.
- Never used in 2016 (statement exists, no file uses it): `permillage`, `someoneshout`, `walk`, `duplicate`,
  `itemattrset`, `sublayershift`, `collect`, `costumecreate`, `costumetakeoff`, `change2door`, `NPCChatNoFacecut`,
  `ScinarioCodeParty`, `HasAbstate`, `BroadcastCode`; system functions `SquarRoot`, `Distance`, `Range`,
  `GetLoseGuild`, the `@` forms of the six object builders.

### 21.8 Answers to §20.9 and open points

- `Identify::sa_Calculate` on a `#expr` form: none of the statements of this section calls vt 8 on an `Identify`
  (`var` uses `i_GetToken`, assignment and `permillage` `i_GetVariable`); `Condition` and `Express` go through `Term`,
  which handles `#` itself. The `OtherStatement` target (`os_Ident`) is checked in §22.
- `sa_Step` results and `ip`: §21.4 (convention) and §21.5 (each control statement).
- B83 (a failed `Term` eats a token) has no effect in this section's statements: each treats a failed expression as a
  failed statement. The `OtherStatement` argument loop (min…max expressions) is checked in §22.
- Answered in §27.3: `arg` is the film's cell index (0–7); a film that ends is unlinked from the cinema, a dropped one also loses its interrupts.
- Open: whether a handler block reached through `call InterruptBlock.` can re-enter a block already on the stack
  (Z09-B86) depends on the interrupt targets of each book (§15); not traced per book.

## 22. Scripts 9: Pine action statements (base), `@` system functions, scenario books and dialog files

This section covers what §21 left to "§22": the common loader and helpers of every action statement
(`OtherStatement`), the bodies of the 25 `@` system functions (§21.6 table), the nine statements registered through
`ScriptBase<>` (§21.2 rows 94–102), the scenario book shelf (which file a book name loads, Pine or Lua, reload) and
the dialog-string files of `World/PineScript.txt` table `DialogFile`. The 84 `Shine*` action steps are parts 15a–15d.
Class, member and function names are *(pdb2016)*. Packets sent here: 0x5814, 0x5821 (KQ score lists, §22.3) and
0x6C04 (`BroadcastCode`, §22.4).

### 22.1 `OtherStatement`: the action-statement base

```pseudo
OtherStatement : StatementBase {                                   # 0xBC
    u8 os_Command[32] +4            # the keyword (copied by the ctor)
    Identify os_Ident +0x24         # the target, loaded when os_IDRead ≠ 0
    Express* os_Express[32] +0x30   # the arguments
    int os_ExpressNumMin +0xb0, os_ExpressNumMax +0xb4; u16 os_IDRead +0xb8 }
OtherStatement::OtherStatement(keyword, idRead, min, max)   @ FUN_004dae40   # all 32 expression slots null
OtherStatement::~OtherStatement                             @ FUN_004daf20   # deletes the 32 expressions and the target
    # never reached by the generic node deletes of §21.2 (Z09-B88): only the ScriptBase<> vt 0x14 destructors call it

OtherStatement::sa_Load(n, tr) → ok                         @ FUN_004dccf0   # vt 0 of every Shine* / ScriptBase<> node
    t = token; none or t ≠ os_Command (case-sensitive): unget t, return 0
    if os_IDRead and not os_Ident.sa_Load(tr): return 0     # the keyword stays consumed (§21.2 trial order)
    for i = 0 …:
        t = token
        if t == ".":
            if os_ExpressNumMax < 1: return 1               # no maximum: any number of arguments is accepted
            if os_Express[max] == null and (min == 0 or os_Express[min−1] ≠ null): return 1
            unget "."; return 0                             # wrong argument count: the statement fails
        unget t; os_Express[i] = new Express; if not Express.sa_Load(tr): return 0   # the failed Express stays in the slot
        if i + 1 > 31: return 1                             # 32 arguments: returns without reading the "." (the next
                                                            # statement then starts at "." and the file fails to load)
```

A statement is `keyword [target] expr … .`; the argument count must lie in [min, max] of the §21.2 table, except for
nodes with max 0 (`interruptclear`, `vanish`, `waitlogin`, `questresult`, `reward`, `waitidle`, `deathcountclear`,
`suicide`, `battlestop`, `endofkq`, `revival`, `ClearSaveLinkto`, …), which accept and ignore any arguments. A failed
expression fails the statement and so the file (§21.2); B83 (a failed `Term` eats a token) changes nothing here.
Arguments are evaluated only when the node steps (`os_Express[i].vt[8](token, ps)`), never at load time.

Helpers shared by the action nodes:

```pseudo
os_ShineObject(n, ps) → obj | null                          @ FUN_004ebbb0
    v = os_Ident.i_GetVariable(ps) (FUN_004d9f60); missing: assert "…OtherStatement::sa_Step", null
    return ShineObjectManager::som_GetObjectAbsolute(pst_GetNumber(v))  @ FUN_0054fc20   # the variable holds a handle

os_ObjectRegen(n, arg, ps, &ip, o, h, brief) → ok           @ FUN_004f8c40   # build a fresh pool object o (handle h)
    # callers: ShineMobRegen / ShineNPCStand (§25.1), ShineDoorBuild (§13); they allocate o and free it on failure
    v = os_Ident.i_GetVariable(ps); missing: assert "…os_ObjectRegen", return 0
    name = os_Express[0]; mobId = mob ID of name (`BTree::operator[]` FUN_0063cc30 on `mobdatabox.mdb_btree`); unknown: assert "…os_ObjectRegen : Invalid mob", return 0
    x, y, dir, e4 = numbers of os_Express[1…4]; os_Express[5] must evaluate (value unused here)
        # any failing argument: assert "…os_ObjectRegen" with its index, return 0
    map = Movie::Theater::t_MapNameServer(ps_Shine.theater) (FUN_004e3010); none: assert "…os_ObjectRegen : Not map name", return 0
    if x == 0 or y == 0:                                    # "anywhere": a random free cell of the map
        field = fieldlist search by map; none → return 0
        BlockDistribute::BlockingDistribute::bd_FindEmptyCoord(field.fm_BlockInfo.mbi_BlockDistribute) (FUN_00438960) fails → return 0; else x, y = that cell
    if o.so_ObjectType (vt 0x4d0) == 7 (door):
        r = o.vt[0x6dc] so_door_Build(map, x, y, dir, h, mobId, scale = e4, layer 0)        # §13.1
    else:
        r = o.vt[0x6e0] so_mob_Regenerate(map, x, y, dir, h, mobId, brief, −1, 0, 0, −1, 1, 0, 0)   # §5.3; brief = copied look or null
    if r ≠ 0: assert "…os_ObjectRegen : Marking fail"; som_FreeObject(h, REMOVE_NOW, 0x16); return 0
    v = "<h>"                                               # the target variable now holds the new handle
    return 1
    # also traced: Ghidra shows the x/y == 0 branch skipping the build; the disassembly (0x4f8f6f…0x4f901a) builds in both cases

os_ObjectChange(n, arg, ps, &ip, o, h) → ok                 @ FUN_004ecec0   # replace the target object by a new one in place
    old = os_ShineObject(ps); missing → return 0 (no assert)
    v = os_Ident.i_GetVariable(ps); missing: assert "…os_ObjectChange", return 0
    mobId = mob ID of os_Express[0]; argument fails → assert, return 0; unknown name → assert "…Invalid mob", return 0
    pos, dir, map = old's location, direction, field map ID; old has no field: assert "…os_ObjectChange : Null map", return 0
    if o is a door (kind 7): r = o.so_door_Build(map, x, y, dir, h, mobId, 1000, layer 0)
        r ≠ 0 → return 0                                    # no free of h here (the mob branch frees it)
    else: r = o.so_mob_Regenerate(map, x, y, dir, h, mobId, null, −1, 0, 0, −1, 1, 0, 0)
        r ≠ 0 → som_FreeObject(h, REMOVE_NOW, 0x16), return 0
    v = "<h>"; return 1                                     # the old object is left in place: removing it is the caller's job (only `exchange2mob` does, §24.5)
```

`so_mob_Regenerate` / `so_door_Build` return 0 on success (an error code), hence "r ≠ 0 = failure".

### 22.2 `@` system functions

Calling convention (§21.6): `SystemFunction::sa_Calculate` returns `sfm_Function.sfb_Calculate(out, ps, args)`.
`ArgumentList::al_GetArgument(args, i, tok, ps)` FUN_004d64c0 sets `tok = ""` and, when `i < 10` and argument `i`
exists, evaluates it (returns null when the expression fails). A **missing argument therefore reads as "" / 0**; a
failed one usually makes the function return null, and a null result makes the surrounding expression fail (§20.5).
`ps_assert(cond, text, detail)` FUN_004d61f0 logs and returns 1 when `cond` is false. Results are strings: numbers via
`pst_MergeNumber` (`%d`), lists as `"h1 h2 … "` (each value followed by one space, read back with `@RemoveFirst`).

```pseudo
@Random(a, b)          SysFuncRand          @ FUN_004d77d0   a + rand() % (b − a + 1)       # CRT rand(), 0…32767
    # (original bug) Z09-B89: no check of b ≥ a: b == a − 1 divides by zero (zone crash); b < a − 1 gives values ≥ a.
    # The 2016 scripts call it with constant ranges (0 360, 0 99, 40 70, …)
@SquarRoot(n)          SysFuncSQRT          @ FUN_004d7960   (int) sqrt(n)
@Distance(x1, y1, x2, y2) SysFuncDistance   @ FUN_004d7a60   (int) sqrt((x1 − x2)² + (y1 − y2)²)      # unused in 2016
@mobregen / @npcstand / @doorbuild(name, x, y, dir, a4)                                      # unused in 2016
    SysFuncShineMobRegen FUN_004e3850 (pool kind 5) / SysFuncShineNPCStand FUN_004e3ad0 (kind 4) /
    SysFuncShineDoorBuild FUN_004e3990 (kind 7):
    o = som_AllocObject(kind); none: assert "…Too many mob", return null
    if ScriptMobBreeder::smb_ObjectRegen(&mobbreeder, ps, o, h, args) (§10.8) fails:
        List<…>::l_Free(&shineobjmanager, h) (FUN_004b1300); result "65535"
    else result "<h>"
@change2mob / @change2npc / @change2door(handle, name)                                       # unused in 2016
    SysFuncShineChange2Mob FUN_004e3c10 (kind 5) / …Change2NPC FUN_004e3e90 (kind 4) / …Change2Door FUN_004e3d50 (kind 7):
    same with smb_ObjectChange (§10.8): a new object at the old one's place; the old one stays
```

The second free in the six builders is `List::l_Free` on `shineobjmanager`'s own base `List<ShineObjectEachList>` (13
entries, `ShineObjectManager::ShineObjectManager` FUN_00557550; the PDB name `List<ItemActionObserve>::l_Free` is a
folded body) with the object handle as index: for handles ≥ 13 it returns at once, for mob handles 0…12 it would unlink
an entry of that base list if it were in use (no allocation from it was found *(inferred)*). (original bug) Z09-B95:
the intended call is the pool free; `smb_ObjectRegen` already freed mobs / NPCs (reason 200), doors stay allocated
and unbuilt until the pool walk reclaims them (§13).

```pseudo
@Count(what)           SysFuncShineCount    @ FUN_004e3fd0   # 22 uses (e.g. `@Count("player") <= 0`)
    what == "player": counter = AxialListMobCounter{ALMC_PLAYER, max 99999}; so_AllInMap(theater.t_CenterFlag, counter, 0)
        (null flag: assert "Movie::Theater::t_AllInMap : Null flag", count 0)
    what == "all":    counter {mob 0xFFFF → ala_SearchAll, max 99999}; Movie::Theater::t_AllInMap (FUN_004e2c30, same walk)
    else: mobId = mob ID of `what`; unknown: ps_assert "…SysFuncShineCount::sfb_Calculate : MobName wrong", result "0"
          counter {mobId → ala_SearchMob}; t_AllInMap
    result = counter.almc_Counter                           # rules of the three searches: §15.7 (live objects only)
@RestSec()             SysFuncShineRestSecond @ FUN_004e42e0  Movie::TimeLimit::tl_GetTimeLimit_Second(theater.t_TimeLimit) FUN_00507df0
    = (tl_EndTick − g_Now) / 10, unsigned                   # seconds left of the `timelimit` statement
    # (original bug) Z09-B90: tl_IsActiv is not tested and the subtraction is unsigned: with no limit set or after it
    # ran out the result is about 429 million instead of 0 (the one 2016 use, JobChange1, reads it while the limit runs)
@CharClass(handle)     SysFuncShineCharClass @ FUN_004e43a0  argument fails: assert, null
    o missing → ""; else by base class (CharClass vt 0x48 cc_ClassType, §18): 1 "Fighter", 6 "Cleric", 11 "Archer",
    16 "Mage", 21 "Joker", 26 "Sentinel", other ""        # JobChange1: `@CharClass(PlayerHandle) % "-m"` builds a menu key
@CharName(handle)      SysFuncShineCharName  @ FUN_004e45a0  argument fails: assert, null; o missing → ""
    else o.vt[0x56c] so_CharName (20 bytes, through the `namestring` ring buffer) appended
@DeathNum(mobName)     SysFuncShineDeadNumber @ FUN_004e4780 # 16 uses
    unknown name: ps_assert "…SysFuncShineCount… MobName wrong" (Count's text), null; argument fails: null
    result = MobDeadCount::mdc_DeadCountGet(theater.t_Field.fm_MobDeadCount, mobId) (FUN_004b08f0); no field → 0
    # the per-map death counter of §5.1 (`MobDeadCount`; reset by the `deathcountclear` statement, §24.6)
@CircularScatter(x, y, r) SysFuncShineCircularScatter @ FUN_004e4940
    any argument fails → null
    MobRegenClass::MobRegenLoc_Circular(x, y, r) FUN_004b0e60 + mrlc_Get FUN_004b0e80 (the circle spawn point of §10.4)
    result = "<px> <py>"                                    # split with @RemoveFirst (JobChange2-1)
@RemoveFirst(varName, sep) SysFuncShineRemoveFisrt @ FUN_004e4b70   # 48 uses: the list reader
    c = first character of sep; v = ProcessStack::ps_FindVariable(ps, varName) (FUN_004d8ce0); fails / missing → null
    result = characters of v up to the first c (or the end)
    skip the c's that follow; v = the rest moved to the front ("" when nothing is left)
@GetObjectList(handle, kind…) SysFuncShineGetObjectList @ FUN_004e4fd0
    o = object of handle; missing: ps_assert "Invalid Object", null
    flags = OR over arguments 1…9, lower-cased, until the first "" or failed one:
        "player" 1<<2, "npc" 1<<4, "mob" 1<<5, "bandit" 1<<8 (= 1 << object kind); other: ps_assert "Invalid flag", null
    walk = AxialListObjectList{flags}; so_AllInMap(o, walk, 1)                  # every object of o's map
        AxialListObjectList::ali_Work FUN_004e4de0: kind bit set → store {handle, so_DistanceSquar(o, x)}; stops at 64
    result = AxialListObjectList::alol_MakeList FUN_004e4ed0: "h1 h2 … " in walk order (the stored distance is not
        used, no sorting), appending only while the text is ≤ 240 characters
@DistanceBetween(h1, h2) SysFuncShineDistance @ FUN_004e5f40   # GordonMaster: `@DistanceBetween(GordonMaster RubiMan) > 1000`
    result starts as "999999999" (appended to `out`)
    both objects exist: result = DirectDistanceTable::ddt_Distance(dx, dy) (FUN_004012d0, §9)
    missing object: ps_assert "…SysFuncShineDistance::sfb_Calculate : Invalid Object", result stays "999999999"
@PlayerInArea(what, area) SysFuncShinePlayerInArea @ FUN_004e6150   # 10 uses: `@PlayerInArea("player" "ID_UrgDragonArea") <= 0`
    area = Name8 (32 bytes) of argument 1
    "player": AxialListMobInAreaCounter(0xFFFF, area, 0, ALMC_PLAYER, 99999) (FUN_004e2d00) over the centre flag
    "all":    (0xFFFF, area, 0, ALMC_MOB, 99999) through t_AllInMap
    mob name: (mobId, …, ALMC_MOB, …); unknown: ps_assert (Count's text), result "0"
    result = almc_Counter                                   # area test and counter rules: §15.7
@KQResultList(name, base, limit) / @KQTopList(name, n, base)   # §22.3
@IsGateUse(flag, opener, arg) SysFuncShineIsGateUse @ FUN_004e6b50   # GuildTournament1: `@IsGateUse(FlagCapture_1 Opener InterruptArg)`
    f = object of flag (missing: assert "SysFuncShineIsCaptureFlag::sfb_Calculate : NO Object", null); field of f's map (vt 0x4bc so_LoginLocation, map name)
    p = object of opener (missing: same assert, null); a = number of arg
    result = GuildTournamentSystem::IsUseGate(fm_GetGuildTournamentSystem(field), p, f.handle, a) (FUN_004795d0) ? "1" : ""
    # no null test of the field's tournament system: only used on tournament maps (GT internals: Z16)
@GetWinnerGuild() / @GetLoseGuild()   SysFuncShineGetWinnerGuild FUN_004e6e10 / SysFuncShineGetLoseGuild FUN_004e7000
    map = t_MapNameServer(theater); none: assert "…os_ObjectRegen : Not map name" (copied text), null
    gts = FieldMap::fm_GetGuildTournamentSystem (FUN_00463290) of that field; none → "" (unchanged out)
    g = GuildTournamentSystem::GetVictoryGuild (FUN_004790e0) / GetLoseGuild (FUN_00479100); result = g ? "<g>" : ""
@Range(from, to, order) SysFuncShineRange   @ FUN_004e72b0   # unused in 2016
    a failing argument → ""
    vector<int>(to − from + 1); order (lower-cased) "asc": from, from+1, …; "desc": to, to−1, …;
    "shuffle": ascending then std::random_shuffle; other: ps_assert "…Invalid order" (the vector stays all 0)
    result = every value followed by " "
    # (original bug) Z09-B92: no length check: more than about 50 values overrun the 256-byte result token
    # (original bug) Z09-B93: to < from − 1 makes a negative vector size (std::length_error / bad_alloc thrown inside a
    #   script step)
```

### 22.3 KQ score lists: `@KQResultList`, `@KQTopList` and 0x5814 / 0x5821

Both functions walk the players of the script's map with an `AxialListKQResult` and sort them by score (used by the
KQ books `KQHBat1…5` and the older `Quest/ConditionOfHero`; the Lua twins `cScoreResultList` / `cScoreTopList`
FUN_005ec6a0 / FUN_005ec1f0 send the same packets without sorting: §28.12).

```pseudo
AxialListKQResult : AxialListIterator {                      # 0x1A18
    alkqr_ScoreFunction +4, alkqr_worker +8 (member-function pointers),
    ALKQR alkqr_Array[128] +0xc { u16 handle; ShineObject* obj; PROTO_NC_KQ_SCORE_CMD::KQScore scorestr (38); int score },
    int alkqr_BasePoint +0x1a0c, alkqr_Pointer +0x1a10, alkqr_LimitPoint +0x1a14 }
mode by name (argument 0, case-sensitive):
    "ConditionOfHero"    → score function alkqr_Score_ConditionOfHero FUN_004e2df0, worker defaultWorker
    "NewConditionOfHero" → worker zerosumWorker (no score function)          # the 2016 KQHBat books
    other                → alkqr_Score_Default FUN_004e2ec0, worker defaultWorker
ali_Work(w, centre, x)            @ FUN_004e5390   skip x with an admin level (vt 0x4d4 ≠ 0, GMs); else worker(x)
defaultWorker                     @ FUN_004e5480   players only (kind 2), ≤ 128: handle, obj, charid = so_CharName; score function(x)
zerosumWorker                     @ FUN_004e55d0   players only, ≤ 128; s = x.so_GetBattleStat (vt 0x428, `BattleStat`):
    killpoint = s.bs_Kill, downpoint = s.bs_Dead, contribute = 0, score = base + s.bs_Score
alkqr_Score_Default               s = BattleStat: killpoint = bs_KillScore, downpoint = bs_KnockDownNum, contribute = 0,
                                  score = contribute − downpoint + killpoint + base
alkqr_Score_ConditionOfHero       killpoint = bs_KillScore + 500, downpoint = bs_KnockDownNum,
                                  contribute = RandomRing(10) (0…9, a random bonus), score as above
    # (original bug) Z09-B91: both score functions set score = 0 when the sum is negative and then overwrite it
    #   with the sum: negative scores stay negative (zerosumWorker has no clamp at all)
alkqr_CalcScore                   @ FUN_004e2f80   per entry: flag.medal = 0, flag.gender = vt 0x804 so_ply_GetGender,
                                  flag.chrcls = class (CharClass vt 0x38)
alkqr_ScoreCompare                @ FUN_004e2ff0   qsort comparator: descending score

@KQResultList(name, base, limit)  SysFuncShineKQResultList @ FUN_004e6420   # `@KQResultList("NewConditionOfHero" 0 5000)`
    base / limit = arguments 1 / 2 when not "" (else 0); walk the map from the centre flag (null: assert, empty list)
    alkqr_CalcScore; alkqr_MakeList FUN_004e5790:
        sort; packet num = count, base
        entry i = {charid, flag (medal 1 / 2 / 3 for ranks 0 / 1 / 2), killpoint, downpoint, contribute, score}
        result = "h " for every entry with limit == 0 or score ≥ limit, while the text is ≤ 240 characters
    broadcast to the map (AxialListPacketBroadcast over the centre flag):
    0x5814 NC_KQ_SCORE_CMD { u8 num; u32 base; KQScore[num] { char charid[20]; u8 medal|gender; u8 chrcls;
        u32 killpoint, downpoint, contribute, score } }      # 5 + 38·num bytes (up to 128 players)
@KQTopList(name, n, base)         SysFuncShineKQTop @ FUN_004e6760          # `@KQTopList("NewConditionOfHero" 10 0)`
    base = argument 2 when not "" ; n = number of argument 1; same walk and alkqr_CalcScore
    alkqr_MakeSimpleList FUN_004e5d20: sort; result = handles of the first min(n, count); packet entries for every
        player {charid, kill = killpoint, down = downpoint, score}; then num = min(count, n)
    for every player i of the walk (sorted order, not only the top n) that exists, is not leaving (vt 0x300
        so_IsEmpty), has a mode (vt 0x484 ≠ 0) and is not in soloing mode (vt 0x79c so_ply_SoloingMode):
        self = {rank i (0-based), kill, down, score of entry i}; length 2 + 18 + 32·num ("Packet Too Long" assert
        when it does not fit); send to that player only (game stream, vt 0x2fc)
    0x5821 NC_KQ_SCORE_SIMPLE_CMD { u8 num; u32 base; u8 self.rank; u32 self.kill, self.down, self.score;
        KQScore[num] { char charid[20]; u32 kill, down, score } }
```

Client (2016, game scene dispatcher FUN_004be490): 0x5814 → FUN_004a32f0 clears the KQ result window, sets `base`,
adds one row per entry (name and the entry data) and opens the window; 0x5821 → FUN_004a33c0 adds one row per entry
(name, score, down, kill) to the score board; it does **not** read the `self` block.

### 22.4 The nine `ScriptBase<>` statements

All load with `OtherStatement::sa_Load` (§22.1; target / argument counts in §21.2) and pop themselves when done, also
after a failure, unless noted. Four of them read their arguments through `ScriptParameterPaser` (§20.7): their min =
max argument count guarantees that every `m_ppExpress[i]` it reads exists.

```pseudo
SaveLinkto server client x y.          SaveLinkto::sa_Step        @ FUN_004fa650   # GuildTournament(1).ps: SaveLinkto "Eld" "Eld" 17214 13445.
    strings 0, 1 and numbers 2, 3 (ScriptParameterPaser, error prefix "SaveLinkto::sa_Step"); a failing one: pop only
    rec = NPCManager::LinkInformTemplete (0x61 bytes) zeroed; rec.linktoserver = server (12 chars), rec.linktoclient = client
        (12 chars), rec.coordx = x, rec.coordy = y      # index "", direct 0, Party 0
    FieldMap::fm_SetSaveLinktoData(Movie::Theater::GetFieldMap(theater), rec)   @ FUN_004634a0 → field.m_SaveLinktoData
ClearSaveLinkto.                       ClearSaveLinkto::sa_Step   @ FUN_004f7340
    fm_SetSaveLinktoData(field, all zero)
    # FieldMap::fm_GetSaveLinktoData FUN_004633e0 returns the record only when coordx ≠ 0. Users: the client's
    # 0x10B9 NC_CHAR_SAVE_LINK_REQ (Z07 §3.5, `sp_NC_CHAR_SAVE_LINK_REQ` FUN_005622d0) and
    # `ShinePlayer::sp_LinktoCurMapSaveData` FUN_00560170 (called only by the GM command `ac_LinktoSaveData`, Z11):
    # both link the player there (vt 0x600 so_LinkTo(rec, 6, 9, 10)). The tournament script sets the Eld exit while
    # the match runs and clears it at the end
RegisterGTPortal portal flag red blue. RegisterGTPortal::sa_Step  @ FUN_004fa3d0   # GuildTournament.ps (3 portals)
    object 0, number 1, strings 2, 3 (prefix "RegisterGTPortal::sa_Step"); failure: pop
    gts = fm_GetGuildTournamentSystem(field of portal's map); gts: GuildTournamentSystem::PortalResiter(gts, portal, flag, red, blue) (FUN_0047ccf0)
GTRegisterNPC npc guild.               GTRegisterNPC::sa_Step     @ FUN_004fa1a0   # GuildTournament.ps (A1…B3 NPCs)
    object 0, number 1 (prefix "GTMobRegenKey::sa_Step", copied text); failure or missing object: pop
    map = t_MapNameServer(theater); none: assert "GTRegisterNPC : Not map name", **return 0 without pop** (ends the film)
    gts of that field: npc.vt[0x900] so_mob_SetGuildRegNum(guild) (FUN_00476110); GuildTournamentSystem::AddTeamNPC(gts, npc.handle) (FUN_0047c700)
GTMobRegenKey key count guild.         GTMobRegenKey::sa_Step     @ FUN_004fb0b0   # GTMobRegenKey "lose_Itembox_a1" 1 GuildA.
    string 0, numbers 1, 2; failure: pop
    map as above (none: assert "…os_ObjectRegen : Not map name", return 0 without pop)
    gts: GuildTournamentSystem::AddAdvanItemMonster(gts, AdvanMobItemRegenInfo {map name, key, count}, guild) (FUN_00480f60)
    # what the tournament does with portals, team NPCs and item-box regen keys: Z16
HasAbstate var handle abstate strength. HasAbstate::sa_Step       @ FUN_004f9f00   # unused in 2016
    v = target variable (missing: assert, pop); v = "0"
    o = object of argument 0 (fails: assert "…ShineWhoClickMe::sa_Step : no Player", copied text; missing: assert "… No obj")
    idx = abstate index of argument 1 (dic_abstate; unknown name: v stays 0, no assert); s = number of argument 2
    if o.vt[0x52c] so_mobile_AbstateList().asl_Abstate_IsSet(idx) (FUN_00409b10) has index idx and strength == s exactly: v = "1"
NPCChatNoFacecut npc key.              NPCChatNoFacecut::sa_Step  @ FUN_004f7420   # unused in 2016
    o = os_ShineObject (null: assert "…Null obj"); key = argument 0 (fails: assert)
    if ps_Shine.shinescript (the dialog set chosen by the `scriptfile` statement, §26.2):
        text = ShineScript::ss_String(set, key) (§22.6); o.so_Chat(0xFFFF, text, strlen, 0, 0)   # vt 0x530 → 0x2002 to sight (§8 / Z02 §3.1)
    # = `npcchat` (§25.3) without the face-cut window
ScinarioCodeParty player code.         ScinarioCodeParty::sa_Step @ FUN_004f7600   # unused in 2016
    p = os_ShineObject (null: log, pop); code = argument 0 (fails: assert "…no code", log "Fail 1")
    party = p.vt[0x550] so_PartyRegistNumber
    no party (0xFFFF): p.vt[0x808] so_ply_QuestDiary → CQuestZone::QuestPlayer_ScenarioDone_Server(code) (FUN_005bd750, Z15)
        (no diary: log "Fail 2-1")
    else for each member m of CParty::operator[](party) (FUN_00645340) with an object and a quest diary:
        same map as p and so_DistanceSquar(p, m) ≤ 1 000 000 (1000 units): m's diary ScenarioDone(code), log "Suc-2"
        else log "Except/NotInMap " / "Except/NotInRange " with m's char number
    # every step is written to the `ScinarioCodeLog` debug log; = `scinariocode` (§26.1) for the whole party
BroadcastCode target "CODE" [handle].  BroadcastCode::sa_Step     @ FUN_004f7ae0   # unused in 2016
    m = argument 0 (fails: assert "…no message", pop)
    code = "ERR_NOERR_TIMEATK_START" 0x2020, "…_WARNING" 0x2021, "…_EXPLODE" 0x2022, "…_WARNING_2" 0x2023; other: pop, nothing sent
    0x6C04 NC_SCENARIO_MESSAGENOTICE_CMD { u32 message = code }            # §19.3 (client texts: the four time-attack notices)
    t = os_Ident.i_GetToken (FUN_004d9ea0), lower-cased
    t == index_all: broadcast to the whole map over the centre flag (null flag: assert)
    t == index_handle: o = object of argument 1 (fails: assert "…no Player with handle"); o exists: send to o only
    other: nothing
    # (original bug) Z09-B94: the "handle" form needs two arguments, but the node registers max 1 (§21.2), so a
    # statement with a handle never loads; the branch that reads os_Express[1] is dead (it would read a null slot)
```

`index_all` / `index_handle` are global `PineScriptToken`s (the target words, "all" / "handle" by their names
*(inferred)*); the same globals serve `broadcast` (§23.5).

### 22.5 The scenario book shelf

```pseudo
ScenarioBookShelf { vector<ScenarioBook*> sbs_Array; BTree sbs_Tree +0x10 (name → index) }   # global scenarioshelf, 0x414
ScenarioBook vt: 0 scalar deleting destructor, 4 sb_Load(name), 8 type (1 Pine, 2 Lua), 0xc Pine script, 0x10 Lua script
    ScenarioBookPS  { PineEventScript* sbps_Script }: vt 8 → 1 (folded FUN_00557bb0), vt 0xc → sbps_Script (FUN_0045ff90), vt 0x10 → 0
    ScenarioBookLua { LuaScriptScenario* sbl_Script }: vt 8 → 2 (FUN_00647230), vt 0xc → 0, vt 0x10 → sbl_Script
    # (the folded slot bodies carry unrelated PDB names: go_Get_GambleType, go_Get_NpcObject, GDTSO_GetGameStatus)

sbs_LoadScripts(shelf)                       @ FUN_00509750   # start stage zs_start_earth (Z01 §2.2)
    read World/PineScript.txt (fails: assert "…Option read error", ShineExit)
    for each record of table PineScript, column ScriptName (not a string: assert "…Type error", ShineExit):
        sbs_Read(name) fails → assert "ScenarioBookShelf::sbs_ReadNAssert : Script Load Error", ShineExit
sbs_ReadNAssert(shelf, name)                 @ FUN_00509710   same, one name; caller FieldContainer::fc_Load FUN_004655f0
    # for every World/Field.txt FieldList record whose ScriptName ≠ "-" (2016: one map, OX_field → `Map/OXFieldInit`,
    # a Pine book that is not in PineScript.txt); start stage zs_start_wide, after the shelf
sbs_Read(shelf, name) → ok                   @ FUN_00509570
    ScenarioBook::sb_GetFileName(buf, name, ext) FUN_00507440: ext "lua" → "../9Data/Shine/LuaScript/<name>.lua",
        else "../9Data/Shine/ScenarioBookShelf/<name>.<ext>"
    if the .ps file opens: b = new ScenarioBookPS
    else if the .lua file opens: b = new ScenarioBookLua
    else: assert "ScenarioBookShelf::sbs_Read : File not found", return 0
    b.sb_Load(name)                          # result ignored
    sbs_Tree.bt_Insert(name, index); sbs_Array.push_back(b); return 1
ScenarioBookPS::sb_Load(b, name) → ok        @ FUN_005076b0
    delete the old sbps_Script (~PineEventScript); sbps_Script = new PineEventScript
    ok = PineEventScript::pes_Load(script, "<…>.ps", &line) (§20.2); fails: assert(name, line)
    return ok
ScenarioBookLua::sb_Load(b, name) → 1        @ FUN_00507800
    delete the old sbl_Script (vt 0); sbl_Script = new LuaScriptScenario; LuaScript::ls_FromFile (§14.1)
    fails: assert "…ScenarioBookLua::sb_Load : Lua load error", ShineExit
sbs_GetScenarioBook(shelf, name, &index) → book | null   @ FUN_00507b90   BTree lookup, index < size
    # callers: Movie::Theater::t_PlayFilm, CinemaComplex::cc_PlayFilm / cc_DropFilm (§27), cSetAIScript /
    # cSetFieldScript (§14), wms_NC_KQ_W2Z_MAKE_REQ (Z08 / Z16), GM ac_ReroadKingdomQuest (Z11)
sbsReLoad(shelf, name)                       @ FUN_00507c90   found: book.sb_Load(name) again (unknown name: nothing)
    # callers: GM commands ac_IndunReload FUN_00419810 and ac_ReroadKingdomQuest FUN_0041dc80 (Z11 / Z16)
~ScenarioBookShelf                           @ FUN_005094d0   deletes every book (vt 0), the tree and the vector (atexit)
ScenarioBook / ScenarioBookPS / ScenarioBookLua destructors: FUN_00507430, FUN_00507610, FUN_00508430 (deletes the
    PineEventScript), FUN_00507640 (deletes the Lua script)
```

2016 data: all 58 `PineScript` records exist, 16 as `.ps` under `ScenarioBookShelf/` and 42 as `.lua` under
`LuaScript/` (the `; LuaScript` comment marks only 18 of them; the loader goes by the files). A `.ps` file shadows a
`.lua` of the same name. With `Map/OXFieldInit` from `Field.txt`, 17 Pine books are loaded (§21.7 lists 16).

(original bug) Z09-B96: a Pine book that fails to load only asserts; `sbs_Read` ignores `sb_Load`'s result, so the
zone keeps a half-loaded book (the Lua path exits instead). Its blocks hold the dangling statement pointer of Z09-B84,
which the next `sbsReLoad` of that book (GM reload) or the shelf's destructor frees a second time.

### 22.6 Dialog-string files: `KQScriptManager` and `ShineScript`

```pseudo
KQScriptManager { BTree kqsm_BTree; ShineScript kqsm_Script[64] +0x404; u32 kqsm_Number +0x421904 }   # global kqscriptmanager
ShineScript : OptionReader                                                                         # 0x10854, one text file
KQScriptManager::kqsm_Load(m, worldName)     @ FUN_0064cee0   # start stage zs_start_home, worldName = zs_serverinfo.worldname
    read World/PineScript.txt (fails: assert with the shelf's text "…sbs_LoadScripts : Option read error", ShineExit)
    for each record of table DialogFile, column ScriptName (not a string: assert "…Type error", ShineExit):
        kqsm_Number > 63: assert "Too many KQ Script", ShineExit
        ShineScript::ss_Load(&kqsm_Script[n], worldName, name); bt_Insert(name, n); n++
    no record at all: assert "KQScriptManager::kqsm_Load : No Script", ShineExit
ShineScript::ss_Load(s, worldName, name)     @ FUN_0064cd30
    read "../9Data/Shine/World/<worldName>/Script/<name>.txt", else "../9Data/Shine/Script/<name>.txt"
        neither: assert "ShineScript::ss_Load : Error in Script read" + the reader's error line, ShineExit
    primary key of table "Script" on column "ScrIndex" (fails: assert "…Error in indexing", ShineExit)
KQScriptManager::operator[](m, name) → set | null   @ FUN_0064ce70   unknown: assert "Invalid script name", null
ShineScript::ss_String(s, key) → text        @ FUN_0048ce60   column "ScrString" of the "Script" record `key`; missing → ""
```

2016: 43 `DialogFile` records, all present in `Script/` (no `World/<world>/Script/` override directory). A file is a
table `Script` with columns `ScrIndex` (INDEX) and `ScrString` (STRING[64]); `#exchange # \x20` turns `#` into
spaces. Users: the `scriptfile` statement (sets `ps_Shine.shinescript`, §26.2), `npcchat` / `NPCChatNoFacecut`, the
Lua `cGetScriptString` and message functions (§18.4 / §19).

### 22.7 Answers to open questions and open points

- §20.9 / §21.8 `Identify::sa_Calculate` on a `#expr` target: `OtherStatement` and the nine nodes use the target only
  through `i_GetVariable` (`os_ShineObject`, `os_ObjectRegen`, `os_ObjectChange`, `HasAbstate`) or `i_GetToken`
  (`BroadcastCode`); a search of the whole PDB export finds no vt 8 call on `os_Ident` (only `StatePrint`, §21.5).
- §20.7 missing `ScriptParameterPaser` arguments: impossible for its four users (exact argument counts, §22.4).
- §20.9 / §21.8 B83 in the argument loop: no effect (a failed expression fails the file).
- §21.7 the 42 books without `.ps`: all exist as `LuaScript/<name>.lua` and load as Lua books (§22.5).
- §10.8 the second free after a failed `smb_*` spawn: Z09-B95 (no effect in practice).
- Answered in §23.9 (part 15a): nobody removes the old object after `os_ObjectChange` (Z09-B98); `ShineChange2Door`
  frees the slot of a failed door build itself (reason 0x1a).
- Answered in §27.2: the book type picks the film object (`PSFilm` / `LuaFilm`); a Lua film uses the book's shared `LuaScriptScenario`.

---

## 23. Scripts 10: Pine action nodes A–C (abstates, aggro, animation, battle modes, messages, object change, costumes, area ban)

The `sa_Step` bodies of the 16 `Shine*` action statements whose class names start with A–C (§21.2 rows 20–22, 32,
33, 38, 47, 48, 56, 60, 66, 67, 79, 80, 85, 86). They load with `OtherStatement::sa_Load` and read their target and
arguments as §22.1 describes (`os_ShineObject`, `os_ObjectChange`). Class, member and function names are *(pdb2016)*.
Packets sent here: 0x6C0B (via `so_bandit_ChangeType`), 0x6C0C, 0x6C0D, 0x6C10, 0x1812 / 0x1813, 0x7483, 0x7484,
0x74E0, 0x2011 (via `so_ply_Notice`), and 0x3401 / 0x3459 to the item DB (costumes).

### 23.1 Common shape

- Every node writes a trace line `[<film>] Shine… : …` to the Pine tracer `scrpttrcr` (§20.8) and **pops itself in
  every case** (success, failed argument, missing object): none of them waits or ends the film (step convention §21.4).
  A failed argument evaluation (`os_Express[i].vt[8]` returns 0) logs an assert and pops.
- Target words: several nodes read the target with `Identify::i_GetToken` (FUN_004d9ea0, the word itself), lower-case it
  (`pst_ToLower`) and compare it with the global `PineScriptToken`s set by static initialisers: `index_all` "all"
  (FUN_006975a0), `index_handle` "handle" (FUN_00697960), `index_guild` "guild" (FUN_00697980), `index_pk` "pk"
  (FUN_006979e0), `index_GuildTournamentStart` "guildtournamentstart" (FUN_00697a40), `index_CostumeHeadAcc` "headacc"
  (FUN_00697ae0), `index_CostumeBodyAcc` "bodyacc" (FUN_00697b00). The other nodes read a variable holding a handle
  (`os_ShineObject` FUN_004ebbb0, or `i_GetVariable` FUN_004d9f60 + `som_GetObject` FUN_0054fd10).
- "Whole map" = `so_AllInMap(theater.t_CenterFlag, list, includeSelf 0)` (FUN_0054b9e0; `Movie::Theater::t_AllInMap`
  FUN_004e2c30 is the same call, null flag → assert "…t_AllInMap : Null flag", nothing sent). `so_AllInMapNomal`
  FUN_0054be00 skips the walker itself when `includeSelf` is 0, which matters only when the walker is a player
  (`abstateset all … handle`, §23.3). Packets go through `AxialListPacketBroadcast` (FUN_00428a40, `ali_Work` FUN_00428b20:
  live players on the same layer, Z01 §3.2) or `AxialListProtocolSend(dept, cmd)` (FUN_004282f0, `ali_Work` FUN_00428310:
  `so_SendProtocol` vt 0x304 of an empty packet to every object; non-players ignore it).
- Several assert texts are copied from other nodes (`ShineFindHandle … no skip / no keep / no handle` in the abstate
  nodes, `ShineFindPlayer … no part` in `briefeffect`, `ShineChatWindow … no mob` in `chatwinrange`,
  `SysFuncShineChange2Mob::sfb_Calculate : Too many mob` in the three change nodes): log text only.

Constructors (`OtherStatement(keyword, idRead, min, max)` + the class vtable, values in §21.2) and `sb_CloneMe`:

| Keyword | Class | ctor | `sb_CloneMe` | `sa_Step` | § |
|---|---|---|---|---|---|
| `change2mob` | `ShineChange2Mob` | FUN_004e86a0 | FUN_004e9440 | FUN_004ed1e0 | 23.2 |
| `change2door` | `ShineChange2Door` | FUN_004e86c0 | FUN_004e94b0 | FUN_004ed350 | 23.2 |
| `change2npc` | `ShineChange2NPC` | FUN_004e86e0 | FUN_004e9520 | FUN_004ed4c0 | 23.2 |
| `abstateset` | `ShineAbstatSet` | FUN_004e8a00 | FUN_004ea010 | FUN_004f1010 | 23.3 |
| `abstatereset` | `ShineAbstatReset` | FUN_004e8a20 | FUN_004ea080 | FUN_004f1480 | 23.3 |
| `aggro` | `ShineAggro` | FUN_004e8b20 | FUN_004ea400 | FUN_004f2d10 | 23.4 |
| `animate` | `ShineAnimate` | FUN_004e8ba0 | FUN_004ea5c0 | FUN_004f3240 | 23.4 |
| `broadcast` | `ShineBroadcast` | FUN_004e88e0 | FUN_004e9c20 | FUN_004ef830 | 23.5 |
| `chatwin` | `ShineChatWindow` | FUN_004e8820 | FUN_004e9980 | FUN_004f50f0 | 23.5 |
| `chatwinrange` | `ShineChatWindowRange` | FUN_004e8840 | FUN_004e99f0 | FUN_004f5520 | 23.5 |
| `briefeffect` | `ShineBriefEffect` | FUN_004e8ec0 | FUN_004eb0b0 | FUN_004f6ec0 | 23.5 |
| `battlestart` | `ShineBattleStart` | FUN_004e8c60 | FUN_004ea860 | FUN_004f3cb0 | 23.6 |
| `battlestop` | `ShineBattleStop` | FUN_004e8c80 | FUN_004ea8d0 | FUN_004f4070 | 23.6 |
| `banfromarea` | `ShineBanFromArea` | FUN_004e8ee0 | FUN_004eb120 | FUN_004f99c0 | 23.7 |
| `costumecreate` | `ShineCostumeCreate` | FUN_004e8e00 | FUN_004eae10 | FUN_004f65a0 | 23.8 |
| `costumetakeoff` | `ShineCostumeTakeOff` | FUN_004e8e20 | FUN_004eae80 | FUN_004f68c0 | 23.8 |

### 23.2 Changing an object's kind: `change2mob`, `change2npc`, `change2door`

```pseudo
change2mob obj mobName.                ShineChange2Mob::sa_Step   @ FUN_004ed1e0   # JobChange1.ps: change2mob ShadowHandle ShadowMobIndex.
    old = os_ShineObject(ps); null → pop
    if old.so_ObjectType (vt 0x4d0) == 8 (bandit):
        old.vt[0x898] so_bandit_ChangeType(5)            # §5.10 FUN_005508b0: type = 5 (acts as a mob), 0x6C0B to the whole map
    else:
        o = som_AllocObject(&h, pool 5 mob) (FUN_0054fe20); none: assert "…Too many mob", pop
        ok = os_ObjectChange(o, h) (§22.1)               # new mob mobName at old's place; target variable = h
        if !ok: som_FreeObject(h, REMOVE_NOW, 0x19)      # (original bug) Z09-B97 when the regenerate failed
    pop
change2npc obj mobName.                ShineChange2NPC::sa_Step   @ FUN_004ed4c0   # JobChange2-1.ps: change2npc NPC "Slime".
    as change2mob with: bandit → so_bandit_ChangeType(4) (acts as an NPC); else pool 4 (NPC), free reason 0x1b
    # between alloc and os_ObjectChange it tests the NEW object: kind 8 → o.so_bandit_ChangeType(4) and skip the
    # change. A pool-4 object is always an NPC (kind 4): (original bug) Z09-B99 dead check (meant for `old`)
change2door obj mobName.               ShineChange2Door::sa_Step  @ FUN_004ed350   # unused in 2016
    o = som_AllocObject(&h, pool 7 door) first (none: assert, pop); no bandit branch
    ok = os_ObjectChange(o, h)                           # door: so_door_Build(…, scale 1000); old missing → 0
    if !ok: som_FreeObject(h, REMOVE_NOW, 0x1a)          # also frees a failed door build (os_ObjectChange does not)
    pop
```

- The mob name argument is an `InxName` of `MobInfo` (`mobdatabox.mdb_btree`); it is read only on the non-bandit path
  (the bandit path ignores it).
- 2016 uses (`JobChange1.ps`, `JobChange2-1.ps`) apply both nodes only to **bandits** made by the 7-argument
  `mobregen` (part 15c): the scripts' own comment says a bandit is spawned as a mob and then turned into an NPC.
  So in 2016 only the in-place `so_bandit_ChangeType` path runs; the object, its handle and its brief info stay.
- (original bug) Z09-B98: on a non-bandit, the three nodes build a second object at the old one's place and write
  its handle into the target variable, but never remove the old object (`os_ObjectChange` leaves it, §22.1). Both stay
  in the world and the script has lost its handle to the old one. `exchange2mob` (§24.5) unmarks and frees the old
  object first, which is what a "change" most likely meant too *(inferred)*.
- (original bug) Z09-B97: when `so_mob_Regenerate` fails, `os_ObjectChange` already frees the new handle (reason 0x16)
  and returns 0; the node frees it again. `som_FreeObject` (FUN_00557d70) finds no object and logs "Try to free
  unalloced object" (once per handle and reason, kept in `globalset`). Log noise only; door failures are freed once.

### 23.3 Abnormal states: `abstateset`, `abstatereset`

```pseudo
abstateset target abstate strength keepMs [handle].   ShineAbstatSet::sa_Step   @ FUN_004f1010
    name = argument 0 (fails: assert "…ShineFindHandle::sa_Step : no skip", pop)
    idx = dic_abstate.as_BTreeIndex[name] (FUN_0063cc30; the AbState InxName); unknown → pop (no assert)
    strength = number of argument 1 (fails: same "no skip" assert, pop)
    keep = number of argument 2 (fails: assert "…no keep", pop)        # milliseconds (§17.4)
    data = AbnormalStateDictionary::AbState::as_FromIndex(&dic_abstate, idx)
    if lower(i_GetToken(target)) == "all":                             # players
        list = AxialListPlayerStateSet(idx, strength, data, keep)      # FUN_004285c0
        no argument 3: t_AllInMap(theater, list)                       # every player of the map
        else: h = number of argument 3 (fails: assert "…no Player with handle", pop)
              o = som_GetObject(h); null → pop
              so_AllInMap(o, list, includeSelf 0)                       # every player of o's map EXCEPT o
    else:
        v = i_GetVariable(target); m = mdb_2MobID(value of v) (FUN_00419080)
        m ≠ 0xFFFF (the variable holds a mob InxName):
            t_AllInMap(theater, AxialListMobStateSet(m, idx, strength, data, keep))   # every mob of that type (§8.9)
        else: o = os_ShineObject(ps) (the variable holds a handle); null → pop
            AxialListMobStateSet(0xFFFF, …).almss_AbStateSet(o)        # o directly, any kind (players too)
    pop
abstatereset target abstate.           ShineAbstatReset::sa_Step  @ FUN_004f1480
    name = argument 0 (fails: assert "…ShineFindHandle::sa_Step : no handle", pop); unknown abstate → pop
    variable value is a mob InxName (mdb_btree): t_AllInMap(theater, AxialListMobStateSet(mobId, idx, 0, data null, 0))
    else o = os_ShineObject(ps); o: AxialListMobStateSet(0xFFFF, idx, 0, null, 0).almss_AbStateSet(o)
    pop                                                                # no "all" form: `all` is looked up as a variable
AxialListPlayerStateSet::ali_Work(walker, o)   @ FUN_00429800   # o.so_ObjectType == 2 → alpss_AbStateSet(o); continue
AxialListPlayerStateSet::alpss_AbStateSet(l, o) @ FUN_004285f0
    skip o when mode (vt 0x484) == 3 (dead) or vt 0x28 `so_YouHaveAlreadyDead`
    then the same body as almss_AbStateSet:
AxialListMobStateSet::almss_AbStateSet(l, o)    @ FUN_004eb8d0   (ctor FUN_004eb880, ali_Work FUN_004f0fc0: mobs of almss_MobID, §8.9)
    data == null (reset): o.vt[0x650](idx); o.so_mobile_AbstateList (vt 0x52c).asl_AbstateReset(o, idx); o.vt[0x528] recalc
    else if o.vt[0x638](o, idx, strength, data, g_Now, 0, 0, keep, how 9, 0):          # set (§17.4)
        so_AbnormalState_BitSet(o, idx); so_AbnormalState_BroadcastSet(o, idx, keep, strength);
        o.vt[0x3f0](idx, keep, 1); o.vt[0x528]()
```

- The direct form (`abstateset PlayerHandle …`, `abstateset GordonMaster …`) reaches `almss_AbStateSet` without the
  kind and dead tests of the walks: players, NPCs and dead objects are set too.
- `abstateset all "StaCommonStun01" 1 3000 LooterHandle.` (`KQHBat1…5.ps`): every player in the looter's map except
  the looter is stunned for 3 s, as the script's own broadcast announces ("Everyone else will be immobilized for 3
  seconds"). The handle selects whom to spare (and the map), not whom to hit.
- `GordonMaster.ps` writes `" StaMobImmortal"` with a leading space in one `abstateset` / `abstatereset` pair: the
  dictionary lookup fails and both statements do nothing (script data, not a server bug).

### 23.4 Mobs and animation: `aggro`, `animate`

```pseudo
aggro mob target amount.               ShineAggro::sa_Step        @ FUN_004f2d10   # JobChange1.ps: aggro ChiefAA PlayerHandle 1.
    m = os_ShineObject(ps); null → pop
    h = number of argument 0 (fails: assert "…ShineAggro::sa_Step : no Player", pop); t = som_GetObject(h); null → pop
    a = number of argument 1 (fails: assert "…no aggro", pop)
    m.vt[0x700](t, a)                                  # ShineMob::so_mob_AppendAggro FUN_0042d470 (§6.2; bandits too);
    pop                                                # players / NPCs: folded no-op FUN_00509900
animate obj animation.                 ShineAnimate::sa_Step      @ FUN_004f3240   # d_graveyard.ps, KQ / Quest Kingkong, MiniDragon
    o = os_ShineObject(ps); null → pop; argument 0 fails → pop (no assert)
    0x6C0D NC_SCENARIO_ANIMATE_CMD { u16 handle = o; Name8 anicode = argument 0 (32 bytes zeroed, strncpy 32) }
    → so_AllOfRange(o, allofrangearg, o.pos, range 0 = map sight, no fan, AxialListPacketBroadcast, includeSelf 0, 0xFFFF)
        (FUN_0054bc80, §9.6)                           # sight of o, any object kind
    pop
```

`animate` is the Pine twin of Lua `cAnimateForcedly "start"` (§17.2) with one difference: it builds the packet itself,
so it also works on players (the Lua path goes through vt 0xc38, a no-op for players). The animation is not
remembered in the brief info; the client stops the current animation and plays the new one (client FUN_004a3610).

### 23.5 Messages: `broadcast`, `chatwin`, `chatwinrange`, `briefeffect`

```pseudo
broadcast target text [handle].        ShineBroadcast::sa_Step    @ FUN_004ef830   (268 uses: 251 `all`, 17 `handle`)
    t = argument 0 (fails: assert "…ShineBroadcast::sa_Step : no message", pop)
    msg = t; if ps_Shine.shinescript (set by `scriptfile`, §26.2): s = ShineScript::ss_String(set, t) (FUN_0048ce60);
          s ≠ "" → msg = s                             # a dialog key, else the literal text (`scriptfile ""` = literal)
    lower(i_GetToken(target)) == "all": so_AllInMap(flag, AxialListWall(msg) (FUN_004281a0), 0)   # null flag: assert
        # AxialListWall::ali_Work FUN_004281c0 = so_ply_Notice (vt 0x784) on every object: players get 0x2011 (§19.3)
    == "handle": h = number of argument 1 (fails: assert "…no Player with handle"); o = som_GetObject(h);
        o: o.vt[0x784] so_ply_Notice(msg) (FUN_005977e0)  # non-players: folded no-op
    other target words: nothing
    pop
chatwin mobName key [p1 … p7].        ShineChatWindow::sa_Step   @ FUN_004f50f0   (215 uses)
    name = argument 0 (fails: assert, pop); mob = mdb_btree[name]; unknown: assert "…ShineChatWindow::sa_Step : no mob", pop
    key = argument 1 (fails: assert, pop); no ps_Shine.shinescript → pop (nothing sent)
    fmt = ss_String(set, key); p[i] = arguments 2…8 (missing or failing → "")
    sprintf(g_buf + 5, fmt, p1, …, p7)                  # up to 7 `%s` in the dialog string
    n = strlen; n ≥ 256 → pop (nothing sent)
    0x6C0C NC_SCENARIO_CHATWIN_CMD { u16 mob; u8 len = n; char content[n] } → whole map (null flag: assert)
    pop
chatwinrange obj range mobName key [p1 … p5].  ShineChatWindowRange::sa_Step  @ FUN_004f5520   (25 uses, `Quest/Quest.ps`)
    o = som_GetObject(number of argument 0) (fails: assert, pop; null → pop)
    range = number of ARGUMENT 2                        # (original bug) Z09-B100: argument 1 is never read
    name = argument 2; mob = mdb_btree[name]; unknown: assert "…ShineChatWindow::sa_Step : no mob", pop
    key = argument 3 (fails: assert, pop); no shinescript → pop
    fmt = ss_String(set, key); p[i] = arguments 4…8; sprintf / length check as chatwin (5 values)
    0x6C0C (as above) → so_AllOfRange(flag, allofrangearg, o.pos, range, no fan, list, includeSelf 1, 0xFFFF)
        # around o; range 0 = map sight (null flag: assert "…t_AllOfRange : Null flag")
    pop
briefeffect target code.               ShineBriefEffect::sa_Step  @ FUN_004f6ec0   # OXFieldInit.ps: briefeffect all 1. / 2.
    c = argument 0 (fails: assert "…ShineFindPlayer::sa_Step : no part", pop)
    lower(i_GetToken(target)) == "all": 0x6C10 NC_SCENARIO_BRIEFEFFECT_CMD { u8 effectcode = c } → whole map
    other target words: nothing sent
    pop
```

- `chatwin` / `chatwinrange` are the Pine counterparts of Lua `cMobDialog` / `cMobDialog_Range` (§19.2: same packet,
  same client handler; the mob only chooses the face cut). Their texts can carry parameters (`chatwin "KQ_G_Boss"
  "GM_Teleport" % NextTeleportHP.` concatenates instead; the `%s` form is unused in the listed books *(not counted)*).
- B100 in 2016: every `chatwinrange` of `Quest/Quest.ps` (the only listed book using it) is written
  `chatwinrange Mara 1000 "Scenario" "Mara01".`, i.e. handle, range, **dialog file**, key. The code reads `"Scenario"`
  as the mob name (no such mob: assert, nothing shown) and as the range (no digits: 0). That book also never runs
  `scriptfile`, so even a correct mob would send nothing. The script form looks older than the 2016 node (the older
  `KQ/Quest.ps` has yet another order, `"Mara" "Mara01" Mara 1000`); `chatwinrange` shows nothing in 2016.
- Client 0x6C10 (`GameFrameWork`, client FUN_004a3d80): resets a display timer; code 1 → if the frame's object at
  +0x9a0 exists, flags +0xa44 = 1, +0xa45 = 1; code 2 → object +0x9a4, +0xa44 = 1, +0xa45 = 0; then plays sound 0x1e;
  other codes are ignored. In `OXFieldInit.ps` code 1 follows the GM's "O" answer and code 2 the "X" answer, so the two
  objects are the O / X answer effects of the OX quiz *(inferred from the script)*.

### 23.6 Map battle modes: `battlestart`, `battlestop`

```pseudo
battlestart flag [a b].                ShineBattleStart::sa_Step  @ FUN_004f3cb0
    f = lower(i_GetToken(target))
    f == "pk":                                          # KQHBat1…5.ps, ConditionOfHero (unlisted)
        flag = theater.t_CenterFlag (null: assert "Movie::Theater::t_MapPKFlag CenterFlag"); field = flag.so_Field
            (null: assert "…t_MapPKFlag Map"); field.fm_PKField = 1        # free PvP on the map (as Lua cSetFreeBattle, §17.6)
        whole map ← AxialListProtocolSend(6, 0x12): 0x1812 NC_MAP_FREEPKZONE_ON_CMD {}   # client: "This area is enabled for PvP."
    f == "guild":                                       # unused in 2016
        arguments 0 and 1 must exist (else assert "…Argument error"); a, b = their numbers
            (a failing one: assert "…ShineBattleStart::sa_Step : no Player" with its index)
        Movie::Theater::t_MapGuildBattle(theater, a, b) (FUN_004ebb80): theater.t_Field.fm_GuildTournamentInform.guildA/B = a, b
        whole map ← 0x7483 NC_GUILD_TOURNAMENTSTART_CMD { u32 nGuildA = a; u32 nGuildB = b;
            u16 nGuildTourNamentType, u32 nGuildMyRegNumber: not written }   # (original bug) Z09-B101
    f == "guildtournamentstart":                       # GuildTournament.ps / GuildTournament1.ps: … 5. and … 0.
        s = number of argument 0 (fails: assert "…no Time")
        whole map ← 0x74E0 NC_GUILD_TOURNAMENT_STARTMSG_CMD { s32 nStartBeforeTime = s }   # §19.5 (cStartMsg_AllInMap sends 5)
    other: ps_assert "…ShineBattleStart::sa_Step : invalid flag" with the word
    pop
battlestop flag.                       ShineBattleStop::sa_Step   @ FUN_004f4070
    "pk": field (via the centre flag, asserts as above).fm_PKField = 0; whole map ← 0x1813 NC_MAP_FREEPKZONE_OFF_CMD {}
    "guild": theater.t_Field (if any).fm_GuildTournamentInform.guildA = guildB = 0;
             whole map ← AxialListProtocolSend(0x1d, 0x84): 0x7484 NC_GUILD_TOURNAMENTSTOP_CMD {}   # GuildTournament*.ps
    other: ps_assert "…ShineBattleStop::sa_Step : invalid flag", nothing changed
    pop
```

- `fm_PKField` is the same map flag as Lua `cSetFreeBattle` and GM `ac_SetPVP` (Z11) set; who reads it (the PvP target
  rules) is Z03. `fm_GuildTournamentInform` is also written by `FieldMap::fm_GuildTournamentClear` FUN_00475a30 /
  `fm_GuildTournamentEnd` FUN_00475fa0 / `fm_Init`; its readers are the guild-tournament system (Z16).
- (original bug) Z09-B101: the `guild` form sends a 14-byte 0x7483 but writes only the first 8 bytes; bytes 8–13 are
  whatever the previous packet left in the global send buffer. The client (`GuildTask::Recv_NC_GUILD_TOURNAMENTSTART_CMD`
  client FUN_006b4730) stores both stale fields (type at task+0xb48, own guild number at +0x4c), then shows the
  enemy guild's name when one of a / b is its own guild, or the text "There is no match opponent" (TextData
  0x38281f8b) when a or b is 0. The real sender (`GuildTournamentSystem::PlayerRegister` FUN_0047f970, Z16) fills all
  four fields. No 2016 script uses `battlestart guild`.
- Client 0x7484 (`GuildTask::Recv_NC_GUILD_TOURNAMENTSTOP_CMD` client FUN_006b3240): sets the tournament state to 1,
  clears the opponent data, closes the tournament windows and ends the status windows (`GTStatusWin::EndGame`).

### 23.7 Banning players from an area: `banfromarea`

```pseudo
banfromarea map area toMap x y.        ShineBanFromArea::sa_Step  @ FUN_004f99c0   # OXFieldInit.ps (3 uses)
    map = argument 0 (12 chars), area = argument 1 (32 chars) (either fails: assert "…ShineBanFromArea::sa_Step : no area", pop)
    toMap = argument 2 (12 chars; fails: assert "…no map", pop); x, y = numbers of arguments 3, 4 ("…no X" / "…no Y")
    field = fieldlist.l_Search(fm_Compare, FieldMap(map)) (FUN_004239a0, temporary FieldMap FUN_004662e0 / FUN_00465490);
        none → pop                                      # the first field of that map name (not the theater's own instance)
    ban = AxialListBanArea(area, field, toMap, x, y)   # FUN_0042a100 (§15.7 table)
    t_AllInMap(theater, ban)                            # ali_Work FUN_0042a570: players (kind 2) with admin level
                                                        #   (vt 0x4d4) 0 inside fm_AreaEntry(field, area, pos) are collected
    AxialListBanArea::alba_Banish(ban)                  # FUN_00429f70: each → vt 0x890 ShinePlayer::so_ply_BriefLink(toMap, (x, y)) (Z01 §7.3)
    pop                                                 # ~AxialListBanArea FUN_0042a180
```

The OX quiz (`Map/OXFieldInit`, the `OX_field` map script, §22.5): after the GM's answer (`interruptset admin`, §15)
the script shows the O / X effect (§23.5), waits, and bans the players standing in the wrong answer zone
(`OZone01` / `XZone01`, areas of `OX_field.aid`) to `OX_field` 6467 4771; `ArenaClear` bans both zones. GMs stay.
The area test uses the area table of the searched field, while the walk covers the theater's map; with one
`OX_field` instance both are the same map.

### 23.8 Costumes: `costumecreate`, `costumetakeoff`

```pseudo
costumecreate player part item options.   ShineCostumeCreate::sa_Step   @ FUN_004f65a0   # unused in 2016
    v = i_GetVariable(target); null → pop; p = som_GetObject(number of v); null → pop
    part = lower(argument 0) (fails: assert "…ShineCostumeCreate::sa_Step : no part", pop):
        "headacc" → slot 27 (ITEMEQUIP_HATACC), "bodyacc" → slot 8 (ITEMEQUIP_BODYACC), other → pop
    item = itemdatabox.idb_btree[argument 1] (fails: assert "…no item", pop; unknown item → pop)
    opts = argument 2 (fails: assert "…no item", pop)
    p.vt[0x948](slot, item, opts)                      # non-players: folded no-op FUN_00514570
    pop
ShinePlayer::so_ply_Script_CostumeCreate(p, slot, item, opts) → ok     @ FUN_00518fb0
    slot ≥ equipment size → 0; the equipment cell 0x2000|slot locked (InventoryLocking vt 0x7d4, vt 8) → 0
    info = ItemTotalInformation::iti_mkregnum(item, 7, zoneNo, worldNo); attr = ItemAttributeClassContainer[item]
    attr.vt[0x14] iac_itemcreate(item, info, "-o"); then for every '-' in opts: iac_itemcreate(item, info, opts from that '-')
        # the option syntax of the GM make-item command (Z05)
    info.itemid = item; ShinePlayer::sp_CreateItemByAdmin(p, 8, slot, info, equipment cell) (FUN_00527270)
        # 0x3401 NC_ITEMDB_ADMINCREATE_REQ for location 0x2000|slot (equipment), Z05 §9.1
    return 1
costumetakeoff player part item.          ShineCostumeTakeOff::sa_Step  @ FUN_004f68c0   # unused in 2016
    player, part and item as costumecreate (argument 1 fails: assert "…ShineCostumeTakeOff::sa_Step : no item"; unknown → nothing)
    p.vt[0x94c](slot, item)                            # non-players: folded no-op FUN_004021b0
    pop
ShinePlayer::so_ply_Script_CostumeTakeOff(p, slot, item) → ok          @ FUN_005191b0
    slot range and equipment-cell lock as above, else 0
    e = equipment cell of slot; c = ShinePlayer::sp_FindItemFromInventory(p, item) (FUN_00589990: first unlocked
        inventory cell 0x2400|n holding that item); either missing → 0
    e empty (itemid 0xFFFF): ShinePlayer::sp_DestroyItem(p, c) (FUN_00527870): 0x3459 to the item DB, cell cleared
    else: ShinePlayer::sp_DestroyNReloc(p, e, c) (FUN_00535af0): 0x3459 for c's item, c cleared, then
          ItemRelocationManager::irm_Move moves the equipped item from the equipment slot into c's inventory cell
```

Both nodes are unused in 2016, and `costumetakeoff` searches the inventory, not the equipment slot that
`costumecreate` fills: as written, a take-off after a create destroys another copy of the item from the inventory
and moves the costume into that cell *(inferred from the calls; the item DB answers are Z05)*.

### 23.9 2016 use, answers and open points

- Use counts per keyword: §21.2. Never used in 2016: `change2door`, `costumecreate`, `costumetakeoff`,
  `battlestart guild`; `chatwinrange` loads but shows nothing (B100).
- §22.7 open question: after `os_ObjectChange` nobody removes the old object in `change2mob` / `change2npc` /
  `change2door` (B98); a failed door build is freed by `ShineChange2Door` (reason 0x1a). `exchange2mob` removes the old
  object (§24.5).
- Keep times above 2³¹ − 1 (`4200000000`, `4000000000` in `JobChange1.ps`, `GordonMaster.ps`, `Monkey.ps`) pass through
  `pst_GetNumber` (`int`) and arrive with the same 32-bit pattern; whether `so_AbnormalState_Set` (vt 0x638) reads them
  as unsigned (about 48 days) or as a negative keep was not traced.
- `chatwin` / `chatwinrange` `sprintf` into the global send buffer before the `< 256` check; the buffer capacity
  (`gpp.pp_BufferSize`, set statically) and a dialog string with more `%s` than values (stack garbage) were not traced.

## 24. Scripts 11: Pine action nodes D–I (items, drops, finding objects and players, heal / HP, guild-tournament end)

The `sa_Step` bodies of the 17 `Shine*` action statements whose class names start with D–I and that no earlier section
covers (§21.2 rows 23, 42–46, 59, 61, 63, 64, 69, 73, 77, 78, 83, 89, 92). Already documented, not repeated here:
`ShineDoorBuild` / `ShineDoorOpen` / `ShineDoorClose` / `ShineEffectObject` / `ShineEffectLocate` (§13),
`ShineInterruptSet` / `ShineInterruptErase` / `ShineInterruptClear` (§15); `ShineEndOfKingdomQuest` is in §26.1.
They load with `OtherStatement::sa_Load` and read target and arguments as §22.1 describes; the common shape of §23.1
holds (trace line, copied assert texts are log text only), with the exceptions noted per node (`itemdrop` can wait,
`DiceGameStart` can end the film). Class, member and function names are *(pdb2016)*. Packets sent here: 0x5812 /
0x5813 / 0x74E2 (guild-tournament result), 0x74D2 (dice game, via `GuildTournamentSystem`), 0x7482 to the WM, 0x3401
and 0x3449 to the item DB (item create / attribute change), 0x3459 (item erase, via `sp_DestroyItem`), the drop
object's 0x1C0A (§11.3).

| Keyword | Class | ctor | `sb_CloneMe` | `sa_Step` | § |
|---|---|---|---|---|---|
| `itemdrop` | `ShineItemDrop` | FUN_004e8960 | FUN_004e9d00 | FUN_004eff00 | 24.1 |
| `itemcreate` | `ShineItemCreate` | FUN_004e89a0 | FUN_004e9ec0 | FUN_004f0810 | 24.2 |
| `itemerase` | `ShineItemErase` | FUN_004e89c0 | FUN_004e9f30 | FUN_004f0570 | 24.2 |
| `itemattrset` | `ShineItemAttrSet` | FUN_004e8c20 | FUN_004ea780 | FUN_004f37a0 | 24.2 |
| `invensearch` | `ShineInvenSearch` | FUN_004e8980 | FUN_004e9e50 | FUN_004f09e0 | 24.3 |
| `itemowner` | `ShineItemOwner` | FUN_004e8d40 | FUN_004eab70 | FUN_004f4ec0 | 24.3 |
| `findhandle` | `ShineFindHandle` | FUN_004e89e0 | FUN_004e9fa0 | FUN_004f0ca0 | 24.4 |
| `findplayer` | `ShineFindPlayer` | FUN_004e8e80 | FUN_004eafd0 | FUN_004f9720 | 24.4 |
| `exchange2mob` | `ShineExchange2Mob` | FUN_004e8700 | FUN_004e9590 | FUN_004ed650 | 24.5 |
| `duplicate` | `ShineDuplicate` | FUN_004e8bc0 | FUN_004ea630 | FUN_004f3430 | 24.5 |
| `heal` | `ShineHeal` | FUN_004e8b80 | FUN_004ea550 | FUN_004f3070 | 24.6 |
| `hpset` | `ShineHPSet` | FUN_004e8fa0 | FUN_004eb3c0 | FUN_004f8060 | 24.6 |
| `deathcountclear` | `ShineDeathCountClear` | FUN_004e8c00 | FUN_004ea710 | FUN_004f36a0 | 24.6 |
| `invidualreward` | `ShineInvidualReward` | FUN_004e8cc0 | FUN_004ea9b0 | FUN_004f4470 | 24.7 |
| `endofgt` | `ShineEndOfGuildTournament` | FUN_004e8dc0 | FUN_004ead30 | FUN_004f6100 | 24.8 |
| `gtresult` | `ShineGuildTorunamentResult` | FUN_004e8de0 | FUN_004eada0 | FUN_004f6290 | 24.8 |
| `DiceGameStart` | `ShineDiceGameStart` | FUN_004e8f40 | FUN_004eb270 | FUN_004f9cc0 | 24.8 |

Use in the 17 Pine books loaded in 2016 (§22.5; the §21.2 counts include files that are not loaded): `itemerase`
27 (KQHBat1–5, GordonMaster, JobChange2-1), `itemdrop` 9 (KQHBat1–5, GordonMaster), `invidualreward` 10 (KQHBat1–5),
`findplayer` 6 (Wedding), `invensearch` 3, `itemowner` 2 (GordonMaster), `exchange2mob` 2 (GordonMaster, JobChange2-1),
`itemcreate` 2, `findhandle` 2 (JobChange1, JobChange2-1), `endofgt` 2, `gtresult` 2, `DiceGameStart` 1
(GuildTournament), `hpset` 1 (Monkey). Not used by a loaded book: `heal` (only in unloaded files), `duplicate`,
`deathcountclear`, `itemattrset`.

### 24.1 Script drops: `itemdrop`

```pseudo
itemdrop dropper item rate.          ShineItemDrop::sa_Step   @ FUN_004eff00   # KQHBat1.ps: itemdrop InterruptArg Maul 1000000.
    dropper = os_ShineObject(ps); null: assert "…Null dropper", pop
    k = dropper.vt[0x80c] so_mobile_WhoIsKillMe (FUN_00555740, the killer's handle); killer = som_GetObject(k)
        killer: killerHandle = k, killerCharNo = killer.vt[0x344] (players: charNo); none: 0xFFFF, −1
    item = argument 0 → ItemInfo InxName (`itemdatabox.idb_btree`); fails: assert "…no item", pop; unknown name:
        assert "…Item Not Found", pop
    rate = argument 1 (fails: assert "…no droprate", pop)
    if well512_GetRandom(1 000 000) >= rate:               # rate in millionths, as ItemDropTable's DrItemR (§11.2)
        return 1 WITHOUT pop                                # (original bug) Z09-B102: the node runs again next pass
    info = { key = iti_mkregnum(item, 3, zoneNo, worldNo) (the mob-drop key type, §11.2), itemid = item }
    cls  = itmattcontainer[item]
    row  = a local ItemDropGroup row: MinQtty = MaxQtty = 1 (+0x3c = 0x10001), the 16 Upgrade weights 0, +0…+0x10 zero
           (the InxName bytes +0x14…+0x3b are left uninitialised; whether vt 0x2c reads them was not traced)
    if not cls.vt[0x2c](&info, &row, rand(1000), dropper.vt[0x708] mob ID):   # the same attribute builder as
        return 1 WITHOUT pop                                                   # `dilig_Drop` (§11.2): lot 1, no upgrade
    ItemDataBox row or its ItemInfoServer missing: pop (no drop, no log)
    if ItemInfoServer.RandomOptionDropGroup (+0x89) names a RandomOption table: rot_FillOption(cls.vt[0x70](&info), table)
    looter = ShineMultiTypeHandle() {ALL, −1}; killer: SetShineObject(killer) → {ALONE, killer.vt[0x344]}
    ShineObject::so_IsDropping(dropper, &info, ONLY_REGISTNUMBER, &looter, killerHandle, killerCharNo, cls, …)   # §11.3
        fails: assert "…Drop fail"
    pop
```

- Unlike a mob's own drop (§11.2) there is no lot factor, no lot cap, no forced upgrade, no `ItemDropFromMob` table and
  no party or raid looter: the item belongs to the killer **alone** (`IsCanItemPick` kind 0: `h.id == p.charNo`, §11.4)
  until `ownerUntil`, or to anybody when the dropper has no live killer. The 2016 uses drop KQ items (`Maul`, keys,
  `KQ_FireSword`, …) on the object of an `ObjectDead` interrupt (`InterruptArg`). `questOnly` comes from the stack
  cookie as for every `so_IsDropping` caller (B21).
- (original bug) Z09-B102: a failed roll (and a failed attribute build) returns 1 without `ps_Pop`, which by the step
  convention (§21.4) means "step me again next pass". The node rolls again on every main-loop pass until it succeeds,
  so the rate only delays the drop (expected 10⁶ / rate passes) and blocks the rest of the film meanwhile; with
  `rate ≤ 0` the roll never succeeds and the film never continues. All 2016 uses pass 1 000 000 (always drops), so the
  bug is latent. Likely intent: pop on a failed roll (no drop).

### 24.2 Player items: `itemcreate`, `itemerase`, `itemattrset`

```pseudo
itemcreate obj item.                 ShineItemCreate::sa_Step  @ FUN_004f0810   # JobChange1.ps: itemcreate PlayerHandle "JOB_GradeSymbol".
    o = os_ShineObject(ps); null → pop
    item = argument 0 (fails: assert "…no Item", pop); unknown name (or ID 0xFFFF): nothing
    o.vt[0x8b4](item)                    # players: ShinePlayer::so_scene_CreateItem FUN_0050d770; others: folded no-op FUN_00549070
    pop
ShinePlayer::so_scene_CreateItem(p, item)                                @ FUN_0050d770
    info.key = iti_mkregnum(item, 2, zoneNo, worldNo); info.itemid = item
    ItemDataBox row missing: assert "…so_scene_CreateItem : Invalid item"; ItemInfo missing: nothing
    cls = itmattcontainer[item]; cls.vt[0x14] iac_itemcreate(item, &info, "-o")   # default attributes (Z05's option syntax, §23.8)
    cls.vt[0x20](&info.item, 1)                                                    # lot 1
    ShinePlayer::sp_MakeItem(p, p.handle, &info)                         @ FUN_00528690
        first empty, unlocked inventory cell (ItemBoxIterEmpty over `ci_Inventory`, limit with the charged-effect
            expansions, lock list vt 0x7d4, inventory type 9); none: nothing (no message, the item is not made)
        ShinePlayer::sp_CreateItemByAdmin(p, 9, cell, &info, cellPtr) (FUN_00527270)   # → 0x3401 NC_ITEMDB_ADMINCREATE_REQ (Z05 §9.1)

itemerase all item.                  ShineItemErase::sa_Step   @ FUN_004f0570   # KQHBat1.ps: itemerase all Maul.
itemerase obj item [count].                                                       # JobChange2-1.ps: itemerase PlayerHandle "Job2_STpiece1".
    item = argument 0 (fails: assert "…no Item", pop); unknown name → item ID 0xFFFF (not checked)
    if the target word (i_GetToken, lower-cased) == index_all "all":
        theater.t_CenterFlag null: assert "Movie::Theater::t_AllInMap : Null flag"
        else so_AllInMap(t_CenterFlag, AxialListItemErase4All{item} (ctor FUN_004285a0), includeSelf 0)
            AxialListItemErase4All::ali_Work FUN_00429750: every object o: o.vt[0x8b8] so_scene_EraseItem(item, −1)
    else:
        o = os_ShineObject(ps)                           # no null check: (original bug) Z09-B103
        if argument 1 exists: count = its number (fails: assert "…no Num", pop without erasing)
        else count = −1
        o.vt[0x8b8] so_scene_EraseItem(item, count)
    pop
    # so_scene_EraseItem: players ShinePlayer::so_scene_EraseItem FUN_0050dba0 (sp_DestroyItem of `count` lots from the
    # inventory, −1 / ≤ 0 = all, more than owned → nothing; then the first matching equipped cell), drop items
    # ShineDropItem::so_scene_EraseItem FUN_0050dc70 (§11.4), others: folded no-op FUN_00509900. Full text: §17.8 cItemErase.

itemattrset obj item attrString.     ShineItemAttrSet::sa_Step @ FUN_004f37a0   # unused in 2016
    o = os_ShineObject(ps); null → pop
    item = argument 0 (fails: assert "…no Item"; unknown: assert "…Item Invalid"; both pop)
    argument 1 is evaluated into the same buffer, result NOT checked: (original bug) Z09-B107
    o.vt[0x8b0](item, attrString)        # players: ShinePlayer::so_scene_ItemAttrSet FUN_0050d8c0; others: folded no-op FUN_00509900
    pop
ShinePlayer::so_scene_ItemAttrSet(p, item, attrString)                  @ FUN_0050d8c0
    first unlocked inventory cell (type 9) holding item (ItemBoxIterIdent); none: nothing
    copy = the cell's item (0x6f bytes); cls = itmattcontainer[copy.itemid]; cls.vt[0x14](copy.itemid, &copy, attrString)
        # rebuilds the attributes from the option string, as the GM make-item command parses it (Z05)
    p.sp_Item.invenlocklist.vt[0x40](lockIndex, cell, &copy, 0x2400 | cell, …)   # lock the cell until the DB answers
    → item DB 0x3449 NC_ITEMDB_ITEMCHANGE_REQ { u16 handle, u32 charNo, u16 lockIndex, u64 key, u16 itemid,
          attr (cls.vt[0xc] bytes) }   (length 0x14 + attribute size; too long: assert with the copied text
          "…so_scene_KQStepSet : Packet Too Long"); lockIndex += 1      # answer 0x344A: Z05 §5.4
```

- `itemcreate` gives one lot of a new item into the first free inventory cell; a full inventory loses the item without
  any message. JobChange1 / JobChange2-1 give the promotion symbols this way.
- (original bug) Z09-B103: `itemerase obj …` calls `o.vt[0x8b8]` without testing `os_ShineObject`'s result. A handle
  outside every pool (`som_GetObjectAbsolute` → null, e.g. the `65535` that `findhandle` writes when it finds
  nothing, §24.4) crashes the zone; a stale handle acts on whatever object now uses the slot (`som_GetObjectAbsolute`
  does not check the slot is in use). Likely intent: `null → pop` as in `itemcreate`.
- (original bug) Z09-B107: `itemattrset` (and `findplayer`'s map argument, §24.4) ignore a failed argument: the
  node continues with what the shared 256-byte token holds (the item name here). Unused in 2016.

### 24.3 Searching inventories: `invensearch`, `itemowner`

```pseudo
invensearch var player item.         ShineInvenSearch::sa_Step @ FUN_004f09e0   # GordonMaster.ps: invensearch Slot Opener KeyDropIndex.
    v = os_Ident.i_GetVariable(ps); missing: assert "…ShineInvenSearch::sa_Step", pop
    v = ""                                                        # cleared before anything else
    h = number of argument 0 (fails: assert "…no Player"); o = som_GetObject(h) (in use); none: assert "…No player"
    item = argument 1 (fails: assert "…no Item"; unknown: assert "…Item Invalid")
    it = ItemBoxIterIdent(o.so_ItemInventory (vt 0x47c).ci_Inventory (+0xe54), item, o.vt[0x498] charged effects)
        # ItemBoxIterIdent ctor FUN_0043c0a0: limit = bag vt 4 (with the charged inventory expansions) or vt 8
    if ItemBoxIterator::ibi_Home(it) (FUN_0043c0e0, first cell whose item ID == item, ibi_isvalid FUN_0043cbe0):
        v = "<cell index>"                                        # pst_MergeNumber(v, it.ibi_finger)
    pop
    # non-players: `so_ItemInventory` FUN_00554ef0 returns the empty `so_defiteminven` → never found
    # scripts test `if Slot =!= ""` (has the item) and then `itemerase all …` / `itemerase Opener … 1`

itemowner var item delimiter.        ShineItemOwner::sa_Step   @ FUN_004f4ec0   # GordonMaster.ps: itemowner Sword "KQ_FireSword" " ".
    item = argument 0 (fails: assert "…no item", pop); unknown name → 0xFFFF, then a dead check:
        (original bug) Z09-B104: compares the stored 0xFFFF with 0xFFFFFFFF, so it never pops early; the walk runs
        for item 0xFFFF and finds nothing
    delim = argument 1 (fails: assert "…no delimiter", pop); v = os_Ident.i_GetVariable (missing: assert "…No variable", pop)
    t_AllInMap(theater, AxialListFindItemOwner{item, delim, v, n = 0}) (ctor FUN_004eb990)
        AxialListFindItemOwner::ali_Work FUN_004eb9e0, every object o of the map:
            o's inventory (as invensearch, first cell with the item) has the item:
                n == 0: v = "<o.handle>"  else: v = v + delim + "<o.handle>"     (pst_Merge, pst_MergeNumber);  n += 1
    pop
```

- `itemowner` writes the variable only when somebody owns the item: with no owner the variable keeps its old value
  (GordonMaster declares it `""` right before, so 2016 is not affected). The list has no trailing delimiter;
  GordonMaster splits it with `@RemoveFirst("Sword" " ")` (§22.2).
- The search is the inventory only (`ci_Inventory`, type 9): equipped items and the quest / mini-house / action boxes
  are not searched.

### 24.4 Finding objects and players: `findhandle`, `findplayer`

```pseudo
findhandle var what skip.            ShineFindHandle::sa_Step  @ FUN_004f0ca0   # JobChange1.ps: findhandle PlayerHandle "Player" 0.
    v = os_Ident.i_GetVariable(ps); missing: assert "…ShineFindHandle::sa_Step", pop
    what = argument 0 (fails: assert "…no mob", pop); lower-cased copy == index_ply "player" (FUN_006975e0)?
        yes: kind 2 (player), id 0xFFFF
        no:  kind 5 (mob), id = MobInfo ID of `what` (unknown → 0xFFFF)
    skip = number of argument 1 (fails: assert "…no skip", pop)
    t_AllInMap(theater, AxialListMobFind{id, handle = 0xFFFF, skip, kind})
        AxialListMobFind::ali_Work FUN_00428130: o.so_ObjectType (vt 0x4d0) == kind and o.vt[0x708] == id:
            skip < 1: handle = o.handle, stop the walk;  else skip −= 1
    v = "<handle>"                                     # 65535 when nothing matched
    pop
```

- Players match because their vt 0x708 is the folded `return 0xFFFF` (FUN_005550b0); mobs return their mob ID
  (`so_mob_MobID` FUN_00556ab0). Only kind 5: NPCs (4), bandits (8), servants (10) are never found by name. `skip`
  picks the n-th match in map walk order (0 = first).

```pseudo
findplayer var charName [mapName].   ShineFindPlayer::sa_Step  @ FUN_004f9720   # Wedding.ps: findplayer GroomHandle GroomName "Wedding".
    v = os_Ident.i_GetVariable(ps); missing: assert (copied text "…ShineFindHandle::sa_Step"), pop
    name = argument 0 (fails: assert "…no part", pop; v unchanged), copied into a Name5 (20 bytes, strncpy)
    p = ShineObjectManager::som_FindPlayer(name)        # every player of the zone, any map
    if argument 1 exists:
        evaluate it (fails: assert "…no area", then continues with the buffer: Z09-B107)
        f = fieldlist search for the map ID (Name3, 12 bytes); f missing, p missing or p.so_Field ≠ f: p = none
    v = p ? "<p.handle>" : "0"
    pop
```

- Wedding.ps finds the groom and the bride by the names its film was given and restricts the search to map `Wedding`
  where the ceremony runs.

### 24.5 Replacing and copying objects: `exchange2mob`, `duplicate`

```pseudo
exchange2mob obj mobName.            ShineExchange2Mob::sa_Step @ FUN_004ed650  # GordonMaster.ps: exchange2mob MidBossHandle "KQ_G_AncientStatue".
    old = os_ShineObject(ps); null → pop
    x, y, dir = old's position and direction
    old.vt[0x33c] so_Unmark(0, broadcast 1, reason 3)              # disappears from sight (§12 notes)
    som_FreeObject(old.handle, REMOVE_NOW, 0x1c)                   # removed BEFORE the new one exists
    o = som_AllocObject(&h, pool 5 mob); none: assert "…Too many mob", pop
    map = Movie::Theater::t_MapNameServer(theater); none: assert "…ShineExchange2Mob::os_ObjectRegen : Not map name", pop
    name = argument 0 (fails: assert "…os_ObjectChange", pop); mob ID unknown: assert "…os_ObjectRegen : Invalid mob", pop
    r = o.vt[0x6e0] so_mob_Regenerate(map, x, y, dir, h, mobId, brief null, −1, 0, 0, −1, 1, 0, 0)   # §5.3
    r == 0: target variable = "<h>"
    else:   assert "…os_ObjectRegen : Marking fail"; som_FreeObject(h, REMOVE_NOW, 0x1d)
    pop
```

- This answers the part 15a question (§23.2): unlike `change2mob` / `change2npc` (B98), `exchange2mob` removes the old
  object (unmark + free, reason 0x1c) and builds the new mob in its place, then points the target variable at it. Pool
  kind 5 means the new object is always a mob, also when the old one was an NPC (JobChange2-1 turns its NPC into the
  `Job2_Zombie` mob).
- (original bug) Z09-B105: the old object is freed first and every later failure (pool full, no map, failed argument,
  unknown mob name) leaves the map without either object while the variable still holds the freed handle; on the three
  failures after the allocation the new slot is also never freed (a mob slot in mode 0 is skipped by
  `ShineMob::so_Routine`, §5.4, so it stays allocated). Only a failed `so_mob_Regenerate` frees it. Likely intent:
  check the new mob first, then remove the old one.

```pseudo
duplicate obj n.                     ShineDuplicate::sa_Step   @ FUN_004f3430   # unused in 2016
    o = os_ShineObject(ps); o and argument 0: o.vt[0x8c0] so_scene_Duplicate(n)   # mobs / NPCs: FUN_0050dda0 (§5.2
        # table: one copy allocated, regenerated n times: Z09-B1, B3); players / doors: folded no-op FUN_00549070
    pop
```

### 24.6 HP and death counts: `heal`, `hpset`, `deathcountclear`

```pseudo
heal obj amount.                     ShineHeal::sa_Step        @ FUN_004f3070   # only in unloaded books
    o = os_ShineObject(ps); o and argument 0:
        o.vt[0x4e4] so_Heal(amount)                       # as Lua cHeal (§17.3): HP += amount × HealRate ‰, capped at MaxHP
        so_AllOfRange(o, sight, ShineObject::so_ply_Send2WhoTargetMe FUN_00568ee0)   # new HP to everyone targeting o
        trace "    HP <o.vt[0x4e8]>"
    pop                                                   # amount 0 is not filtered (cHeal filters it)

hpset var hp.                        ShineHPSet::sa_Step       @ FUN_004f8060   # Monkey.ps: hpset BossHandle 99999999.
    argument 0 evaluated once and discarded (fails: assert with the copied text "…ShineSpawn::sa_Step : no script", pop)
    v = os_Ident.i_GetVariable(ps) (missing: assert, pop); o = som_GetObjectAbsolute(number of v) (none: assert "…No Object", pop)
    hp = number of argument 0 (evaluated again; fails: assert "…no hp")
    o.vt[0xaac] so_SetHP(hp)                              # mobs / NPCs: ShineMob::so_SetHP FUN_00552d40, HP = min(hp, MaxHP);
                                                          # players / doors: ShineObject::so_SetHP FUN_00552cf0 does nothing
    pop                                                   # no packet: the new HP shows with the next HP / brief packet

deathcountclear.                     ShineDeathCountClear::sa_Step @ FUN_004f36a0   # unused by loaded books
    MobDeadCount::mdc_Clear(theater.t_Field.fm_MobDeadCount)   @ FUN_004b07b0   # memset the (maxmobhandle + 1) u16 counters to 0
    pop
    # the counters of §5.1 (`mdc_Count` from `ShineMob::so_KilledBy`), read by `@DeadCount` (§22.2); t_Field is not
    # tested for null (map films always have a field *(inferred)*)
```

- Monkey.ps uses `hpset BossHandle 99999999.` to fill its boss's HP to MaxHP (the min clamps it).

### 24.7 KQ rewards: `invidualreward`

```pseudo
invidualreward player rewardIndex.   ShineInvidualReward::sa_Step @ FUN_004f4470   # KQHBat1.ps: invidualreward PlayerHandle "HERO_" % InitFlag % "_" % Count.
    h = number of argument 0 (fails: assert with the copied text "…ShineSendKQResult::sa_Step : no Player", pop)
    p = som_GetObject(h) (in use); none → pop
    index = argument 1 (fails: assert "…ShineSendKQResult::sa_Step : no Reward", pop)
    p.vt[0x770](index)                     # players: ShinePlayer::so_ply_KQRewardIndex FUN_0052ea80; others: folded no-op FUN_00549070
    pop
ShinePlayer::so_ply_KQRewardIndex(p, index)                              @ FUN_0052ea80
    row = KQRewardDataBox::operator[](kqreward, index)    # KINGDOM_QUEST_REW by index name; unknown → nothing
    ShinePlayer::sp_KQReward(p, row) (FUN_0052da70)       # the KQ reward itself: Z16
```

- KQHBat1–5 build the index from the player's rank and the battle round (`HERO_<flag>_<n>`), so each ranked player gets
  the reward row of their place.

### 24.8 Guild-tournament end: `gtresult`, `endofgt`, `DiceGameStart`

The guild tournament itself (`GuildTournamentSystem`, groups, dice game, scores) is Z16; these three nodes are its map
script's hooks (`Guild/GuildTournament.ps`: blocks `EndOfTournament`, `CancelOfTournament`, `DiceGame`).

```pseudo
gtresult suc guild.                  ShineGuildTorunamentResult::sa_Step @ FUN_004f6290
gtresult result winner loser.                                    # GuildTournament.ps: gtresult Result Winner Loser.
gtresult <other word> guild.
    g = number of argument 0 (fails: assert with the copied text "…ShineFindHandle::sa_Step : no skip", pop)
    word = os_Ident.i_GetToken lower-cased
    word == index_suc "suc" (FUN_006976a0):
        so_AllInMap(t_CenterFlag, AxialListGTEnd{0x16, 0x12, g} (ctor FUN_00428840), includeSelf 0)   # null flag: assert
    word == index_Result "result" (FUN_00697a60):
        l = number of argument 1 (fails: the same "no skip" assert, pop)
        pkt 0x74E2 NC_GUILD_TOURNAMENTSTOPMSG_CMD { u32 WinnerGuild = g, u32 LoseGuild = l, u32 AGuildRegNumber,
            u16 AGuildScore, u32 BGuildRegNumber, u16 BGuildScore }       # payload 0x14 (pdb2016 struct)
        field = Movie::Theater::GetFieldMap (FUN_005074b0); field has a GuildTournamentSystem:
            GuildTournamentSystem::EndBattle(gt, &result) (FUN_004803f0, Z16) fills the four A/B fields
        else the four fields keep the old send-buffer bytes: (original bug) Z09-B106
        t_AllInMap(theater, AxialListPacketBroadcast(0x74E2, 0x16 bytes))   # live players of the map (§23.1)
    any other word:
        t_AllInMap(theater, AxialListGTEnd{0x16, 0x13, g})
    pop
AxialListGTEnd::ali_Work(o)                                         @ FUN_00428870
    o.vt[0x818] guild regnum == g: o.vt[0x304] so_SendProtocol(0x16, cmd)   # an empty packet
        # players: ShinePlayer::so_mobile_GetGuildRegnum FUN_0056d950; others: folded `return 0` → only g == 0 matches
        # them, and non-players ignore so_SendProtocol
```

- `suc` sends `0x5812 NC_KQ_COMPLETE_CMD`, any other word `0x5813 NC_KQ_FAIL_CMD` (both empty) to every member of guild
  `g` on the map. The 2016 client handles them in the game scene (FUN_004a31f0 / FUN_004a3270): it shows its
  "complete" / "fail" window (`+0x994` / `+0x998`) and plays sound 0 / 1 *(inferred from the code shape)*. The 2016
  GuildTournament.ps uses only the `result` form, so these two are never sent there.
- `0x74E2` client (GuildTask FUN_006b6800, C01): shows "%s Guild won %s Guild by %d vs %d" / "…lost…" (`GuildTWin` /
  `GuildTSLose`) and asks "Do you want to quit the Guild Tournament?". The cancel block sends `gtresult Result 0 0.`
  (WinnerGuild = LoseGuild = 0).

```pseudo
endofgt winner loser.                ShineEndOfGuildTournament::sa_Step @ FUN_004f6100   # GuildTournament.ps: endofgt Winner Loser.
    w = number of argument 0, l = number of argument 1
        (either fails: assert with the copied text "…ShineChatWindowRange::sa_Step", pop)
    field = theater.t_Field; none → pop
    FieldMap::fm_ClearObject(field, 0xb0)                  @ FUN_00495a10
        so_AllInMap(field.fm_SlantedListPoint.flag[2], AxialListObjectClear{0xb0}, 1)
        AxialListObjectClear::ali_Work FUN_00495940: kind bit set in 0xb0 (4 NPC, 5 mob, 7 door) → o.vt[0x3f4]
            so_RetrateFromMap (removed next tick, §13)
    FieldMap::fm_GuildTournamentEnd(field, w, l)           @ FUN_00475fa0
        field seed (fm_GuildTournamentInform.seed) 0xFF, or guildtournamentinfo[seed].nTournamentSeed 0xFF:
            assert "…Seed not set" / "…Seed not set<2>", nothing sent
        → WM 0x7482 NC_GUILD_TOURNAMENT_END_CMD { u8 seed, u16 nTournamentMapNo, u8 (w == l), u32 w, u32 l }
            (W03; too long: assert with the copied text "…ShineEndOfKingdomQuest::sa_Step : Packet Too Long")
        guildtournamentinfo[seed].gta_Result2WMS = 1
    FieldMap::fm_GuildTournamentClear(field)               @ FUN_00475a30
        guildtournamentinfo[seed].nTournamentSeed = 0xFF, .gta_MatchStartTime = 0; field seed = 0xFF
        GuildTournamentSystem::Clear(gt) when the map has one (Z16)
    pop
```

- `fm_GuildTournamentClear` indexes `guildtournamentinfo[seed]` without the 0xFF test that `fm_GuildTournamentEnd`
  makes; whether the array has a slot 255 was not checked (Z16, see §24.9).

```pseudo
DiceGameStart seconds.               ShineDiceGameStart::sa_Step @ FUN_004f9cc0   # GuildTournament.ps: DiceGameStart 15.
    s = number of argument 0 (fails: assert "…no Object", pop)
    map = t_MapNameServer(theater) (none: assert "…Not map name"); field = fieldlist search (ListSearchSame<FieldMap>)
    field and field.fm_GetGuildTournamentSystem (FUN_00463290):
        GuildTournamentSystem::DiceGameStart(gt, s × 10)  @ FUN_0047ada0; pop
    else: return 0 WITHOUT pop                         # (original bug) Z09-B108: the film ends
GuildTournamentSystem::DiceGameStart(gt, ticks)                            @ FUN_0047ada0   (Z16)
    A, B = the manager users of group A / B (GuildGroup::CheckManagerUser when unset); either missing: nothing
    DiceGame::Start(gt.m_diceGame, ticks, A.charNo, B.charNo)
    to every live player of A's map (so_AllInMap(A, …, includeSelf 1)):
        0x74D2 NC_GUILD_TOURNAMENT_DICEGAME_START_CMD { u32 AGuildRegNumber = A.vt[0x818], u16 AGuildDelegate =
            ShineObject::so_GetZoneHandle_ItemLooter(A), Name5 AGuildDelegateName = A.vt[0x56c], u32 BGuildRegNumber,
            u16 BGuildDelegate, Name5 BGuildDelegateName }   # payload 0x34 (pdb2016 struct)
```

- Client (GuildTask FUN_006b63a0, C01): shows "The Dice will be rolled automatically after 5 seconds". The dice game
  (rolls, result, `interruptset TimeOut … "fnDieGameEnd"` in the script) is Z16.
- (original bug) Z09-B108: on a map without a guild-tournament system (or without a map name) the node returns 0
  without popping, which ends the whole film (§21.4), while its argument failure pops like every other node. The 2016
  script runs it only on the tournament map, so it is latent. Likely intent: pop.

### 24.9 2016 use, answers and open points

- Part 15a's open question (who removes the old object after `os_ObjectChange`): only `exchange2mob` removes it
  (§24.5); `change2*` leave it (B98).
- The Pine drop paths (`itemdrop`) now join the Lua one (`cDropItem`, §11.8) and the mob drops (§11) at
  `so_IsDropping`; B21 (questOnly from the cookie) applies to all of them.
- Not traced (Z16): `GuildTournamentSystem::EndBattle` (how the A/B scores are computed), `GuildTournamentSystem::Clear`,
  `DiceGame::Start`, `ShinePlayer::sp_KQReward`, the bounds of `guildtournamentinfo` (slot 255 written by
  `fm_GuildTournamentClear` when the seed is not set).
- Not traced (Z04 / Z05): what `cls.vt[0x2c]` does with the synthetic row of `itemdrop` (MinQtty = MaxQtty = 1, no
  upgrade weights) and whether it reads the uninitialised InxName bytes; `iac_itemcreate`'s parsing of the `itemattrset`
  attribute string.
- `som_FindPlayer`'s name comparison (case, which player list) was not traced (`findplayer`).

## 25. Scripts 12: Pine action nodes L–R (spawns, NPC talk, map light / fog, links, waits, KQ results and rewards, GT flags)

The `sa_Step` bodies of the 24 `Shine*` action statements whose class names start with L–R (§21.2 rows 10, 17, 19,
26, 27, 29–31, 35, 36, 39, 50, 52, 53, 57, 58, 70, 74, 75, 82, 87, 88, 90, 93). `ShineMobWeaponRate` is already in
§8.2 (FUN_004fa8c0, not repeated). They load with `OtherStatement::sa_Load` (§22.1) and follow the common shape of
§23.1 (trace line, pop in every case, copied assert texts are log only) with these exceptions: `pause` waits (returns
1 without pop until its time is up); `mobregen` / `npcstand` build objects through `os_ObjectRegen` (§22.1). Class,
member and function names are *(pdb2016)*. Ghidra merges the pop / assert tails of most of these nodes (it shows
"no argument" asserts after the success path of `maplight` / `mapfog`, loses the calls of `mobattr`, `npcchat`,
`npcshout`, `run`, `RegisteFlag` and the waits of `pause`): every step below was checked in the disassembly of the
2016 exe. Packets sent here: 0x6C0A / 0x6C0E (map light / fog), 0x2002 / 0x201F (NPC chat / shout), 0x2018 + 0x204D
(scripted player walk), 0x5812 / 0x5813 (KQ complete / fail), 0x5823 (KQ no reward), 0x0442 to the GameLog server.

| Keyword | Class | ctor | `sb_CloneMe` | `sa_Step` | § |
|---|---|---|---|---|---|
| `linkto` | `ShineLinkTo` | FUN_004e8900 | FUN_004e9c90 | FUN_004efb10 | 25.4 |
| `collect` | `ShineObjectCollect` | FUN_004e8d80 | FUN_004eac50 | FUN_004f5ca0 | 25.4 |
| `mobregen` | `ShineMobRegen` | FUN_004e8640 | FUN_004e92f0 | FUN_004f9170 | 25.1 |
| `npcstand` | `ShineNPCStand` | FUN_004e8680 | FUN_004e93d0 | FUN_004f95b0 | 25.1 |
| `regengroup` | `ShineRegenGroup` | FUN_004e8780 | FUN_004e9750 | FUN_004ee0f0 | 25.1 |
| `vanish` | `ShineObjectVanish` | FUN_004e8760 | FUN_004e96e0 | FUN_004edcf0 | 25.1 |
| `mobattr` | `ShineMobAttribute` | FUN_004e8d60 | FUN_004eabe0 | FUN_004f5a00 | 25.2 |
| `mobdetectrange` | `ShineMobDetectRange` | FUN_004e8b60 | FUN_004ea4e0 | FUN_004f2f10 | 25.2 |
| `mobweaponrate` | `ShineMobWeaponRate` | FUN_004e8b40 | FUN_004ea470 | FUN_004fa8c0 | §8.2 |
| `run` | `ShineRun` | FUN_004e8a60 | FUN_004ea160 | FUN_004f1cf0 | 25.2 |
| `playerwork` | `ShinePlayerWalk` | FUN_004e8e60 | FUN_004eaf60 | FUN_004f6d40 | 25.2 |
| `npcchat` | `ShineNPCChat` | FUN_004e87e0 | FUN_004e98a0 | FUN_004eeaf0 | 25.3 |
| `npcshout` | `ShineNPCShout` | FUN_004e8800 | FUN_004e9910 | FUN_004eecd0 | 25.3 |
| `maplight` | `ShineMapLight` | FUN_004e8aa0 | FUN_004ea240 | FUN_004f20f0 | 25.3 |
| `mapfog` | `ShineMapFog` | FUN_004e8ac0 | FUN_004ea2b0 | FUN_004f2350 | 25.3 |
| `pause` | `ShinePause` | FUN_004e87c0 | FUN_004e9830 | FUN_004ee650 | 25.5 |
| `printf` | `ShinePrintf` | FUN_004e8560 | FUN_004e8fe0 | FUN_004eb6c0 | 25.5 |
| `questresult` | `ShineQuestResult` | FUN_004e88a0 | FUN_004e9b40 | FUN_004ef450 | 25.6 |
| `reward` | `ShineReward` | FUN_004e88c0 | FUN_004e9bb0 | FUN_004ef650 | 25.6 |
| `questmobkill` | `ShineQuestMobkill` | FUN_004e8fc0 | FUN_004eb430 | FUN_004f8270 | 25.6 |
| `returnvalue` | `ShineReturnValue` | FUN_004e8ce0 | FUN_004eaa20 | FUN_004f45f0 | 25.6 |
| `revival` | `ShineRevival` | FUN_004e8f60 | FUN_004eb2e0 | FUN_004f7070 | 25.6 |
| `RegisteFlag` | `ShineRegesteFlag` | FUN_004e8f00 | FUN_004eb190 | FUN_004fab70 | 25.7 |
| `RegisteGate` | `ShineRegesteGate` | FUN_004e8f20 | FUN_004eb200 | FUN_004fae00 | 25.7 |

Use in the 17 Pine books loaded in 2016 (§22.5; statements outside comments): `regengroup` 317 (UnderHall, UnderHall2,
Honeying, GordonMaster, KQHBat1–5, d_NestOfLeviathan), `pause` 291 (all 17), `npcstand` 57 (GuildTournament 40,
JobChange2-1, Wedding, GordonMaster, d_NestOfLeviathan), `mobregen` 37 (JobChange1 24), `npcchat` 34 (GordonMaster,
JobChange1, JobChange2-1), `linkto` 30 (14 books), `vanish` 20, `questresult` 13, `RegisteGate` 10 and `RegisteFlag`
5 (GuildTournament), `maplight` 9 (JobChange1, JobChange2-1), `questmobkill` 6, `playerwork` 6 (Wedding),
`returnvalue` 6 (Quest), `npcshout` 5 (Honeying), `reward` 5, `revival` 5 (KQHBat1–5), `mobattr` 4 (GordonMaster),
`run` 4 (JobChange1), `mapfog` 1, `printf` 1 (JobChange2-1). Not used by a loaded book: `mobdetectrange`,
`mobweaponrate` (only in unloaded files), `collect`.

### 25.1 Spawning and removing objects: `mobregen`, `npcstand`, `regengroup`, `vanish`

```pseudo
mobregen var mobName x y dir scale mode [look].   ShineMobRegen::sa_Step  @ FUN_004f9170
    # JobChange1.ps: mobregen ShadowHandle ShadowMobIndex 1033 704 180 1000 "Shadow" PlayerHandle.
    # JobChange2-1.ps: mobregen NPC "Slime" x y d 1000 "Normal" "Beggar".   (args 0–5 = os_ObjectRegen's, §22.1;
    #   arg 5 "Normal" / "Shadow" is evaluated there but not used)
    pool = 5 (mob)
    brief = ScriptBriefMaker::sbr_MakeBeggar(&scriptbriefmaker, stack brief)   @ FUN_004eb630   # always built
    if argument 6 present:
        fails: assert "…ShineMobRegen::sa_Step" (index 4), pop, return                  # nothing spawned
        word = lower-case value
        if word == index_beggar "beggar" (FUN_00697aa0): pool = 8 (bandit)              # random look, no equipment
        else: p = som_GetObject(number(value))
            if p: brief = copy of p.vt[0x6d0] so_GetCharBriefInfo() (0xEB bytes)          # player FUN_00559920
                  p.vt[0xd04] so_ply_getBanditBriefinfo(&brief)  (players FUN_00560b00; others folded no-op FUN_00549070)
                  pool = 8                                                              # a bandit that looks like p
            # unknown handle: stays a plain mob (pool 5); the brief is then ignored (ShineMob::sm_InitBriefInfo)
            # (original bug) Z09-B110: a mob / NPC / door handle reaches the copy too: their vt 0x6d0 is the folded
            #   `return 0` FUN_00570b00, and the 0xEB-byte copy reads from address 0 (zone crash)
    o = som_AllocObject(&h, pool) (FUN_0054fe20); none: assert "…ShineMobRegen::sa_Step : Too many mob", pop
    if not os_ObjectRegen(o, h, &brief) (§22.1): som_FreeObject(h, REMOVE_NOW, 0x16)   # second free, as B97 (log only)
    pop
```

- A pool-8 object is a `ShineBandit` (§5.10): `ShineBandit::sm_InitBriefInfo` (vt 0xf70, FUN_004b11a0) copies the
  brief into `sb_MobBriefInfo` and sets handle, `type` 4 (acts as an NPC), `myguild` 0, `isGuildAcademyMember` 0;
  `ShineBandit::sm_BriefLocateSet` (vt 0xf6c, FUN_004b10c0) copies the brief's coordinate into
  `sm_LoginLoc.currentcoord` (+0x1f84). The object itself stands at the node's x / y (so_mob_Regenerate writes the
  location before; §5.3). So a player copy keeps the player's name, class, shape, equipment and title in its brief;
  the beggar's coordinate bytes are never written (stack) *(the coordinate copy has no reader found; uncertain)*.
- The script comment in JobChange2-1.ps (cp949) says it: "there is no way to make a bandit-shaped NPC, so make a mob
  and change it to an NPC; if the last argument is a player handle a copy is made, with "Beggar" a figure without
  equipment, any class". `change2npc` / `change2mob` (§23.2) then switch the bandit's `type`.

```pseudo
ScriptBriefMaker::sbr_MakeBeggar(sbm, b)                         @ FUN_004eb630
    sbr_RandomShape(sbm, b)                                      @ FUN_004eb4a0
        class from ring rndbox box 5 (0…4 → 1 Fighter, 6 Cleric, 11 Archer, 16 Mage, 21 Joker), race chosen with it,
        gender from box 2, hair colour / face from box 3, hair type from box 4 (+4 for one gender)
        handle 0xFFFF, charid = 5 zero codes + name "???", mode 1, Level 1, polymorph 0xFFFF
    shapedata (first 0x28 bytes) = 0xFF (no equipment), emoticon 0xFF / 0, chartitle 0, abstatebit 0 (99 bytes),
    myguild 0, type 4, isGuildAcademyMember 0
ShinePlayer::so_ply_getBanditBriefinfo(p, b)                     @ FUN_00560b00   # default gear for a copied player
    row = first JobEquipInfo row (gJopEquipInfo, `JobEquipInfo.shn`: ChrClass, Equ_RightHand, Equ_LeftHand,
        Equ_Shoes, Equ_Head, Equ_Leg, Equ_Body, Equ_ETC, InxNames) with so_ply_CheckCharType(row.ChrClass) (vt 0xd08
        FUN_00560cc0: the player's base class 1/11/6/16/21/26 against CCT_FIGHTER…CCT_SENTINEL; CCT_COMMON always)
        # no row matches: the last row is used
    if b.RightHand (+0x29) == 0xFFFF:
        if b.LeftHand (+0x2d) ≠ 0xFFFF:                          # something in the left hand only
            left item missing in ItemInfo → return
            if its Class == 7 (shield): RightHand = row.Equ_RightHand, or row.Equ_ETC when that item is two-handed
        else: RightHand = row.Equ_RightHand (missing item → return); if not two-handed: LeftHand = row.Equ_LeftHand
    elif b.LeftHand == 0xFFFF: right item missing → return; if not two-handed: LeftHand = row.Equ_LeftHand
    Head / Body / Pant / Boot = row.Equ_Head / Equ_Body / Equ_Leg / Equ_Shoes where 0xFFFF
    # 2016 rows (5): class 0 BroadSword / Buckler / Chain set, 2 SpikedClub / RoundShield / Bless set, 1 LightBow /
    #   HardLeather set, 3 MagicStaff / Magic set, 4 CrimsonClaw / Mario set
```

```pseudo
npcstand var mobName x y dir scale mode.   ShineNPCStand::sa_Step  @ FUN_004f95b0
    # GuildTournament.ps 40×, e.g. npcstand Book "PledgeBook" 557 1137 0 1000 "Normal".
    o = som_AllocObject(&h, pool 4 NPC); none: assert "…ShineNPCStand::sa_Step : Too many mob", pop
    if not os_ObjectRegen(o, h, brief null): som_FreeObject(h, REMOVE_NOW, 0x18)   # second free, as B97 (log only)
    pop
    # ShineNPC::so_mob_Regenerate FUN_004b4bc0 (fromTable 0, §5.9): a script NPC without an NPC-table row; the
    #   mob name must be a MobInfo InxName of an NPC-type mob; its clicks reach the map script (NPCClick, §15)

regengroup file regenIndex [x y].        ShineRegenGroup::sa_Step  @ FUN_004ee0f0
    # UnderHall2.ps: regengroup "KDKingkong" "KQ_Kingkong_03_10".   ConditionOfHero: regengroup "KDHero" "HERO" % InitFlag.
    file = argument 0 (fails: assert "…: no map"), index = argument 1 (fails: assert "…: no index")
    map = Movie::Theater::t_MapNameServer(theater) (FUN_004e3010); none: assert "…: Not map name"
    r = PineScriptMobRegenerator::psmr_find(&scriptmobregen, file, index) (FUN_004e7bd0, §10.6)
        none: assert "…ShineMobRegen::sa_Step : No regen index" (copied text)
    if arguments 2 and 3 are present and evaluate: r.group CenterX / CenterY = x / y (only for this call)
    MobHatchery::mh_ScriptBreed(mobhatchery, map, &r.rs_data, &r.rs_group, key "Def") (FUN_004b3e40, §10.6)
    restore CenterX / CenterY; pop
    # the file argument names a `MobRegen/KingdomQuest/*.txt` or `MobRegen/Instant/*.txt` table (KQRegenTable); no
    #   loaded 2016 book passes x / y

vanish word [arg].                        ShineObjectVanish::sa_Step  @ FUN_004edcf0   # target read, max 0 → any args
    # JobChange1.ps: vanish ShadowHandle.   Wedding.ps: vanish mobindex "PledgeBook".
    word = target word (i_GetToken, lower-cased); arg = argument 0 when present (evaluated, result unchecked)
    word == "all" (index_all):     AxialListMobVanish { almv_MobID 0xFFFF } over the map (so_AllInMap of
                                   t_CenterFlag; null → assert "…t_AllInMap : Null flag"): every kind-5 object (mob)
    word == "mobindex" (index_mobindex FUN_00697b80): id = mob ID of arg's string (mobdatabox.mdb_btree);
                                   unknown → nothing; else AxialListMobVanish { id } over the map: every object
                                   whose vt 0x708 mob ID == id (mobs, NPCs, bandits; players / doors never match)
    word == "handle":              o = som_GetObject(number(arg)) (FUN_0054fd10); AxialListMobVanish::almv_Vanish(o)
    otherwise (a variable):        o = os_ShineObject (the variable's handle); almv_Vanish(o)
        # missing object (both forms): log "…ShineObjectVanish::sa_Step : Invalid mob Object T…"
    pop
AxialListMobVanish::almv_Vanish(o) = o.vt[0x3f4] so_RetrateFromMap      @ FUN_004283a0   # (ali_Work FUN_004283c0, §17)
```

- `so_RetrateFromMap` for mobile objects (`ShineMobileObject::so_RetrateFromMap` FUN_00495d20) only sets
  `smo_Flag.Retrate` (+0x1e78 bit 0); the object's next `so_Routine` removes it (mobs / NPCs / bandits: unmark,
  free; §13.1 for doors). The `handle` and variable forms do not check the kind: on a player the same bit is the
  "invalid position" flag of §2 (player kicked with 0x680) *(inferred from §2)*; no 2016 book passes a player.

### 25.2 Mob settings and scripted moves: `mobattr`, `mobdetectrange`, `run`, `playerwork`

```pseudo
mobattr attribute handleExpr value.      ShineMobAttribute::sa_Step  @ FUN_004f5a00
    # GordonMaster.ps: mobattr NoAggro HeroHandle 0.   mobattr Recover Door2Boss 0.
    word = target word, lower-cased
    h = number of argument 0 (fails: assert "…ShineChatWindowRange::sa_Step", copied text; pop)
    o = som_GetObject(h); null → pop
    v = number of argument 1 (fails: assert "…ShineMobAttribute::sa_Step", pop)
    "guild"   (index_guild):   o.vt[0x900] so_mob_SetGuildRegNum(v)    FUN_00476110 (§5.8: 0x748D to sight)
    "recover" (index_recover FUN_006979a0): o.vt[0x724] so_mob_CanRecover(v)  FUN_00556b90 (§17.5: back to idle after a fight)
    "noaggro" (index_noaggro FUN_006979c0): o.vt[0x728] so_mob_MobAggro(v)    FUN_00556bb0 (§17.5: other-side aggressive
                                                                               mobs ignore it when 0)
    other words: nothing;  pop
    # players: all three slots are the folded no-op FUN_00549070. Same setters as Lua cSetMobAttr (§17.5), which
    #   refuses NPCs; this node does not (the NPC class has the mob bodies)

mobdetectrange var range.                ShineMobDetectRange::sa_Step  @ FUN_004f2f10   # only in unloaded files
    o = os_ShineObject; null → pop
    range = argument 0; when it evaluates: o.vt[0x8bc](range)   (ShineMob::so_scene_DetectRange FUN_0050dd30, §5.8)
    pop

run var x y.                             ShineRun::sa_Step  @ FUN_004f1cf0   # JobChange1.ps 4× (the shadow runs)
    o = os_ShineObject; null → pop
    x = argument 0 (fails: assert "…ShineRun::sa_Step : no locx"), y = argument 1 (fails: "… no locy")
    o.vt[0x8ac] so_scene_MovePathSet(x, y, 2 run)   (FUN_0050d450, §9.5: queued; NPCs / bandits walk it in their
                                                     so_Routine via smo_MoveByScenario, 0x201A to sight)
    ps_Shine.currentmob (+0x1012c) = o              # written here (and by `walk`), read by no node in 2016
    pop                                             # the trace name is "PineEventScriptNode::ShineAct::sa_Step"

playerwork var x y.                      ShinePlayerWalk::sa_Step  @ FUN_004f6d40   # Wedding.ps: playerwork GroomHandle 536 620.
    o = os_ShineObject; null → pop
    x = argument 0 (fails: assert "…ShineCostumeTakeOff::sa_Step : no part", copied text; pop); y = argument 1
        # (original bug) Z09-B111: the result of argument 1 is not checked (a failed y keeps the token of x)
    o.vt[0x5b0] so_MoveByServer(&{x, y}, cmd 0x18, lastCmd 0x4D, kind 1 walk, logArg 1)   (§9.3)
        → 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD to sight; players also get 0x204D NC_ACT_REINFORCE_WALK_CMD { dest }
          (ShinePlayer vt 0xe98 smo_ply_ReinforceRun with lastCmd 0x4D) and the 0x203E speed packet
    pop
```

`playerwork` is the one caller of `so_MoveByServer` that passes the walk pair (0x18 / 0x4D); the §9.3 remark "all pass
lastCmd 0x49" holds for the run callers only. B14 (the remembered command is `lastCmd`) applies: a newcomer sees the
walking groom as 0x204D instead of 0x2018.

### 25.3 NPC talk, map light and fog: `npcchat`, `npcshout`, `maplight`, `mapfog`

```pseudo
npcchat var key.                         ShineNPCChat::sa_Step  @ FUN_004eeaf0   # GordonMaster.ps: npcchat InterruptArg "Hero00".
    o = os_ShineObject; null: assert "…ShineNPCChat::sa_Step : Null obj", pop
    key = argument 0 (fails: assert, pop)
    if ps_Shine.shinescript (set by `scriptfile`, §26.2):
        text = ShineScript::ss_String(set, key) (FUN_0048ce60, §22.6; "" when missing)
        o.vt[0x530] so_Chat(0xFFFF, text, strlen(text), chatwin 1, links 0)   (ShineMobileObject::so_Chat FUN_00458c90)
            → 0x2002 to sight (§8.7 / Z02 §3.1); chatwin 1 = the client's NPC dialog window with face cut
    pop                                                        # NPCChatNoFacecut (§22.4) is the same with chatwin 0
npcshout var key.                        ShineNPCShout::sa_Step  @ FUN_004eecd0   # Honeying.ps: npcshout Boss "Summon01".
    as npcchat, then o.vt[0x534] so_Shout(0xFFFF, speaker "", text, strlen(text))
        (mobs / NPCs / bandits ShineMob::so_Shout FUN_00459250, §8.7: 0x201F to the whole map with isMob = 1 and the
        mob ID as speaker; B10's extra byte applies; players ShineMobileObject::so_Shout FUN_00459080)

maplight r g b.                          ShineMapLight::sa_Step  @ FUN_004f20f0   # JobChange1.ps: maplight 72 72 72.
    r, g, b = numbers of arguments 0–2 (any fails: assert "…ShineMapLight::sa_Step : no argument", pop)
    0x6C0A NC_SCENARIO_LIGHT_CMD { u8 red = r; u8 green = g; u8 blue = b }   (5 bytes with the opcode)
        to the whole map: AxialListPacketBroadcast over t_AllInMap (live players, same layer; §23.1)
    pop
mapfog fog depth.                        ShineMapFog::sa_Step  @ FUN_004f2350   # JobChange2-1.ps: mapfog 100 1400.
    fog, depth = arguments 0, 1 (either fails: assert "…ShineMapFog::sa_Step : no argument", pop)
    0x6C0E NC_SCENARIO_FOG_CMD { u8 fog; u16 depth } to the whole map (same walk; null flag → assert, nothing)
    pop                                                        # = Lua cMapFog (§19.4)
```

- Both packets are fire-and-forget: the server keeps no light / fog state, so a player who enters the map later (or
  relogs) has the default scene *(as cMapFog, §19.4)*. Client: 0x6C0A `FUN_0049b010` (game scene) divides each byte
  by a constant (DAT_00968ac8) and sets the colour of the scene light object DAT_00a8e358 (0 = 0.0); 0x6C0E
  `On_NC_SCENARIO_FOG_CMD` FUN_004a35b0 (§19.4). JobChange1 dims the light step by step (0 … 255) during the shadow
  fight. Layouts confirmed against `PROTO_NC_SCENARIO_LIGHT_CMD` / `…FOG_CMD` *(pdb2017 names)*.

### 25.4 Sending players to other maps: `linkto`, `collect`

```pseudo
linkto word serverMap clientMap x y.     ShineLinkTo::sa_Step  @ FUN_004efb10   # UnderHall2.ps: linkto all "Eld" "Eld" 17214 13445.
    serverMap, clientMap, x, y = arguments 0–3 (each failure: assert "…: no ServerMap" / "no ClientMap" / "no xcoord"
        / "no ycoord", pop)
    link = LinkInformTemplete { linktoserver = serverMap (12 + NUL), linktoclient = clientMap (12 + NUL), coordx, coordy }
        # not validated against the map tables (cLinkTo does, §17.7)
    word == "all":       AxialListLinkTo(link) (ctor FUN_00428510, ali_Work FUN_00428950, §17.7: fold a camp,
                         so_LinkToReserv(link, 0)) over t_AllInMap: every player of the map
    word == "observer" (index_observer FUN_00697a20):
                         AxialListLinkToByObserver over t_AllInMap, ali_Work FUN_00428530 for each object:
        abstate 289 STA_OBSERVERHIDEMODE set (vt 0x3e4) only:
            mode 4 (camp) → so_ply_ReinforceFoldtent (vt 0x488)
            players: ShinePlayer::sp_RunRollBackPosEvent FUN_00570b80
                stored sp_punMarkEvent (a RollBackPosCallBackEvent set by sp_SetRollBackPosEvent FUN_00570b30 when the
                player entered as a guild-tournament observer, sp_Guild_Tournamnet_Observer_Enter FUN_004788c0, Z08 §8;
                or by the WM zone-link handler) → clear it; if mode ≠ 0: doEventRun FUN_00444a10 = so_LinkTo(saved
                place, 6, 9, 10) (vt 0x600, §2.3: back where the observer came from); delete it; result true
                none → so_LinkToReserv(link, 0)                  # only observers without a saved place use the node's map
    otherwise (a variable): o = os_ShineObject; if o: mode 4 → fold the camp; o.vt[0x3fc] so_LinkToReserv(link, 0)
        (players FUN_00495f00; other kinds no-op FUN_00495eb0)
    pop

collect word map x y guild.              ShineObjectCollect::sa_Step  @ FUN_004f5ca0   # unused in 2016
    word = target word, lower-cased
    map = argument 0 (fails: assert "…ShineChatWindowRange::sa_Step", copied text; pop)
    x, y, guild = numbers of arguments 1–3
        # (original bug) Z09-B111: only argument 1 is checked (fails: assert, pop); a failed y / guild keeps the
        #   previous token's value
    attr = FieldOption::fo_GetFieldAttr(&fieldlist.fc_FieldOption, map); its client map must be in MapInfo (else pop)
    link = { map, client map name, x, y }
    if word == "guild": AxialListObjectCollector(link, guild) (ctor FUN_00429f10) over t_AllInMap:
        ali_Work FUN_004298e0: compare = ala_CompareGuild FUN_00429830 (object vt 0x828 guild regnum == guild) when
        guild ≠ 0, else none; no compare → returns 0 (the walk stops at the first object: nothing happens);
        match → so_LinkToReserv(link, 0) (no camp fold)
    pop
```

### 25.5 Waiting and tracing: `pause`, `printf`

```pseudo
pause unit amount.                       ShinePause::sa_Step  @ FUN_004ee650   # 321× "pause sec 5.", MilliSec, Minute
    if *ip ≠ 0 (stepped before):
        if ps_Shine.waittick (+0x1010c) ≥ g_Now: return 1         # still waiting (no pop: stepped again next pass)
        pop; return
    *ip += 1
    unit = target word, lower-cased; n = number of argument 0
    "hour" (index_hour FUN_00697600):      waittick = g_Now + n × 36000
    "minute" (index_minute FUN_00697620):  waittick = g_Now + n × 600
    "sec" (index_sec FUN_00697640):        waittick = g_Now + n × 10
    "millisec" (index_millisec FUN_00697660): waittick = g_Now + (n × 10) / 1000        # 100-ms ticks, truncated
        argument fails (any unit): assert "PineEventScriptNode::ShineWait::sa_Step : no time" (index 0…3), pop
    other units: assert "…ShineWait::sa_Step : Invalid flag", trace "Error : ", pop     # e.g. "pause 3." in two
                                                                                        #   unloaded files: no wait
    then the wait test above (waittick ≥ g_Now → return 1)
```

- `g_Now` is in 100-ms ticks (§1); one node step per main-loop pass (§21.4), so the wait ends on the first pass after
  `waittick` (granularity = main-loop period). `pause sec 0.` still waits one pass. The wait time lives in the
  stack's `ps_Shine.waittick`, shared by the whole film (one waiting node at a time per film).
- The trace / assert texts say `ShineWait` (an older class name).

```pseudo
printf expr.                             ShinePrintf::sa_Step  @ FUN_004eb6c0   # JobChange2-1.ps: printf "Zombie : " % ZombieNum.
    value = argument 0 (fails: assert "…ShinePrintf::sa_Step: wrong argument")
    when file logging and the Pine tracer (scrpttrcr, §20.8) are on: write "@@@printf : " + value + "\n" to the
        tracer file and close it
    pop                                                        # no packet, no state
```

### 25.6 KQ results and rewards: `questresult`, `reward`, `questmobkill`, `returnvalue`, `revival`

```pseudo
questresult word.                        ShineQuestResult::sa_Step  @ FUN_004ef450   # questresult Suc. / questresult Fail.
    word = target word, lower-cased
    k = AxialListKQEnd(dept 0x16, cmd = word == "suc" (index_suc FUN_006976a0) ? 0x12 : 0x13)   (ctor FUN_004284f0)
    so_AllInMap(t_CenterFlag, k, includeSelf 0)   (null flag: assert "…t_AllInMap : Null flag", nothing)
    if theater.t_Field: FieldMap::fm_ClearObject(field, 0x1b0) (FUN_00495a10, §24.8): kinds 4 NPC, 5 mob, 7 door,
        8 bandit are removed next tick (so_RetrateFromMap)
    pop
AxialListKQEnd::ali_Work(o)                                       @ FUN_00429e00   # players (kind 2) only
    success ? o.vt[0x7fc] so_ply_KQSuccess FUN_0055ae10 : o.vt[0x800] so_ply_KQFail FUN_0055ae30
        # on a map whose FieldAttr.KingdomQuestMap (+0x36) == 1: CCharacterTitleZone::CT_KQSuccess FUN_005cbfb0 /
        #   CT_KQFail FUN_005cbfd0 (title counters, Z07)
    if o has a field: → GameLog 0x0442 NC_LOG_GAME_KQ_LEAVE { u32 chrregnum (vt 0x344); MAPPOS mappos = field
        fm_MapID (12 bytes) + o's x, y; u16 KQ_ID = field.fm_KQID; u32 KQ_Handle = field.fm_KQHandle;
        u8 Leave_Status = success }   (0x21 bytes with the opcode; too long → assert with the copied text
        "KingdomQuestGate::KingdomQuestGateKeeper::erb_happen : Packet Too Long"); D05 stores it
    o.vt[0x304] so_SendProtocol(0x16, cmd): empty 0x5812 NC_KQ_COMPLETE_CMD / 0x5813 NC_KQ_FAIL_CMD to the player
        # client: complete / fail window and sound (FUN_004a31f0 / FUN_004a3270, §24.8)
```

`questresult` is the KQ end signal of the KQ books (UnderHall, UnderHall2, Honeying, GordonMaster) and of the job-change
books (JobChange1 / 2-1 send 0x5812 / 0x5813 for the promotion test); it ends nothing by itself: the book then runs
`reward` and `endofkq` (§26.1, `ShineEndOfKingdomQuest`), which removes the KQ instance (Z16). Answer for Z08's open
question: the KQ result is sent by this node, per player of the map, with the GameLog leave record.

```pseudo
reward word.                             ShineReward::sa_Step  @ FUN_004ef650   # reward KingdomQuest.
    word = target word, lower-cased; word ≠ "kingdomquest" (index_kq FUN_00697680) → pop (nothing)
    kq = theater.t_Field.fm_KQHandle (no field → 0xFFFFFFFF); 0xFFFFFFFF: assert "…ShineEventReward::sa_Step :
        No KQ info" (older class name), pop
    r = AxialListKQReward(kq) (ctor FUN_00428410): kqe = KingdomQuestContainer::kqc_SearchHandle(&kqcontainer, kq)
        (FUN_004954f0); DemandKill = kqe.kqe_kqinfo.DemandMobKill (QuestData KQ row)
    so_AllInMap(t_CenterFlag, r, 0)
    pop
AxialListKQReward::ali_Work(o)                                    @ FUN_00428490
    no kqe: nothing
    kills = KQContribute::KQContributeList::kqcl_GetMobKill(&g_KQContributeList, kqe.kqinfo id, o)  (FUN_00499d80, Z16)
    kills ≥ DemandKill: o.vt[0x76c] so_ply_KQRewardStruct(kqe) (FUN_0052e9c0, Z16: the KQ reward items / money / exp)
    else: o.vt[0x308] so_SendErrorCode(0x16, 0x23, 0x1104) (FUN_0054f050)
        → 0x5823 NC_KQ_NOREWARD_CMD { u16 err = 0x1104 } (4 bytes); client FUN_004b0830 (game scene): "You haven't
          hunted enough monsters to receive a reward."
    # non-players: vt 0x76c / 0x308 are no-ops for them *(not checked per class; kills are 0 for non-players)*

questmobkill quest mobName count.        ShineQuestMobkill::sa_Step  @ FUN_004f8270   # questmobkill 2668 "Daliy_Check" 1.
    q = number of argument 0 (fails: assert "…: no quest", pop); 0xFFFF = every quest
    mob = mob ID of argument 1 (mobdatabox.mdb_btree; unknown: assert "…ShineSummonMob::sa_Step : no mob", copied
        text; argument fails: assert "…ShineQuestMobkill::sa_Step : no mob"; pop)
    count = number of argument 2 (fails: assert "… no mob", pop)
    s = AxialListNearScanObjectType(kind 2 players, 0) (FUN_004c1b40) over t_AllInMap (≤ 200 players, §18)
    n = alns_GetNumber(s) (FUN_004c17e0); limit = min(n, count)
        # (original bug) Z09-B109: the per-player repeat count is capped by the number of players on the map
    for each player p of s (alns_GetMember FUN_004c17f0), not leaving (vt 0x300 so_IsEmpty ≠ 1), with a quest diary
        (vt 0x808 so_ply_QuestDiary):
        repeat up to limit times while the call returns ≠ 0:
            q == 0xFFFF ? CQuestZone::QuestPlayer_ScriptMobKill_All(diary, mob) (FUN_005c0cf0)
                        : CQuestZone::QuestPlayer_ScriptMobKill(diary, q, mob) (FUN_005c0b40)      # Z15
    pop
```

`questmobkill` credits a scripted "kill" of a (dummy) mob to every player's quest: the 2016 books use it for the
daily-check quests (`Daliy_Check`, `Daliy_Check_d_Leviathan` 5 in d_NestOfLeviathan). With count 5 and fewer than 5
players on the map, B109 gives each player fewer than 5 credits (one player alone gets 1).

```pseudo
returnvalue handleExpr value.            ShineReturnValue::sa_Step  @ FUN_004f45f0   # Quest.ps: returnvalue CharHandle 1.
    h = number of argument 0 (fails: assert "…ShineSendKQResult::sa_Step : no Player", copied text; pop)
    o = som_GetObject(h); null → pop
    v = number of argument 1 (fails: assert "…ShineSendKQResult::sa_Step : no value")
    o.vt[0x8fc](v): players ShinePlayer::so_ply_Return2Quest FUN_005bfa80 → CQuestZone::PsEnd(diary, v)
        (FUN_005bf990, Z15: the result of a quest's Pine scenario); others folded no-op
    pop

revival word.                            ShineRevival::sa_Step  @ FUN_004f7070   # KQHBat1–5: revival all.
    (target word not read) AxialListRevival (ctor FUN_0042a060) over the whole map (null flag: assert), then
    AxialListRevival::alr_Revive FUN_00429f40 (§17.5 cRevivalAll: every dead player revives at its revive point,
    sp_ReviveReqProcess, Z07 §3.1); pop
```

### 25.7 Guild-tournament flags and gates: `RegisteFlag`, `RegisteGate`

```pseudo
RegisteFlag flagHandle nameA nameB.      ShineRegesteFlag::sa_Step  @ FUN_004fab70
    # GuildTournament.ps: RegisteFlag FlagCapture_1 "Red_Flag00" "Blue_Flag00".
    o = som_GetObject(number of argument 0) (fails: assert "…ShineRegesteGuildTorunamentFlag::sa_Step : no Object");
        null → pop
    a = argument 1 (fails: "… no Guild Name A", pop), b = argument 2 (fails: "… Guild Name B", pop)  (std::string)
    field = fieldlist search by o.vt[0x4bc] so_LoginLocation (the map o stands on); gts = fm_GetGuildTournamentSystem
        (FUN_00463290); none → pop
    GuildTournamentSystem::FlagRegister(gts, o, a, b) (FUN_00480970, Z16)
    pop
RegisteGate gateHandle team flagHandle gateName.   ShineRegesteGate::sa_Step  @ FUN_004fae00
    # GuildTournament.ps: RegisteGate Guild_A1_Gate GuildA FlagCapture_1 "GuildGate01".
    g = som_GetObject(arg 0) (fails: assert "…ShineRegesteGate::sa_Step : no Object"); team = number of arg 1;
    f = som_GetObject(arg 2); name = arg 3 (fails: assert "…ShineRegesteGuildTorunamentFlag::sa_Step : no
    UseGateName", copied text); any missing object / failed argument 1–2 → assert "… no Guild Name A" (copied), pop
    gts as above (by g's map); GuildTournamentSystem::GateRegister(gts, g, team, f.handle, name) (FUN_00480ab0, Z16)
        false → assert "ShineRegesteGuildTorunamentGate Bad GateRegiste"
    pop
```

What the tournament does with registered flags and gates (capture, gate opening, the A/B score) is Z16.

### 25.8 2016 use, answers and open points

- Part 15b's question "which `mobregen` form makes bandits": the 7-argument form, with a player handle (copy) or
  `"Beggar"` (§25.1); JobChange1 (shadow of the player) and JobChange2-1 (slime NPC) are the 2016 users.
- Z08's open question (`ShineQuestMobkill`, `ShineQuestResult`): §25.6. `ShineEndOfKingdomQuest`: §26.1.
- Not traced (Z16): `GuildTournamentSystem::FlagRegister` / `GateRegister`, `so_ply_KQRewardStruct`,
  `kqcl_GetMobKill`; (Z15) `QuestPlayer_ScriptMobKill(_All)`, `CQuestZone::PsEnd`; (Z07) `CT_KQSuccess` /
  `CT_KQFail`; (Z08) where else `sp_SetRollBackPosEvent` is set (`wms_NC_CHAR_ZONE_LINK_FROM_CMD` FUN_00476600).
- Open: whether the bandit's `sm_LoginLoc.currentcoord` (the copied brief coordinate, garbage for a beggar) is read
  anywhere (no reader found by member name).

## 26. Scripts 13: Pine action nodes S–W and `endofkq` (KQ end, scenario codes, dialog files, summons, suicides, teleports, time limits, waits, wedding)

The `sa_Step` bodies of the 17 `Shine*` action statements whose class names start with S–W (§21.2 rows 11, 12, 28,
34, 37, 40, 41, 49, 51, 62, 65, 68, 71, 72, 81, 84, 91; `waitinterrupt`, row 16, is in §15) plus `endofkq`
(`ShineEndOfKingdomQuest`, row 76, left over from part 15b). They load with `OtherStatement::sa_Load` (§22.1) and
follow the common shape of §23.1 (trace line, copied assert texts are log only), with these exceptions: `waitlogin`
waits (returns 1 without pop) until a player is in the map or 240 s have passed; `waitidle` would wait but never
does (Z09-B114); `timelimit` and `scriptfile` end the film when their argument fails (Z09-B116). Class, member and
function names are *(pdb2016)*. Every step below was checked in the disassembly of the 2016 exe (Ghidra drops the
calls of `walk`, `suicide`'s word test, `scinariocode`'s quest call and the wait of `waitidle`). Packets sent here:
0x5810 to the WM, 0x1091 to the Character DB, 0x5812 / 0x5813 (KQ complete / fail), 0x201F (shout), 0x0810 (time
limit), 0x243C (via `alms_SelfKill`), 0x1805 (sub-layer logout).

| Keyword | Class | ctor | `sb_CloneMe` | `sa_Step` | § |
|---|---|---|---|---|---|
| `endofkq` | `ShineEndOfKingdomQuest` | FUN_004e8da0 | FUN_004eacc0 | FUN_004f5fc0 | 26.1 |
| `sendquestresult` | `ShineSendKQResult` | FUN_004e8ca0 | FUN_004ea940 | FUN_004f4300 | 26.1 |
| `scinariocode` | `ShineScinarioCode` | FUN_004e8c40 | FUN_004ea7f0 | FUN_004f39d0 | 26.1 |
| `scriptfile` | `ShineScriptFile` | FUN_004e8580 | FUN_004e9050 | FUN_004ebde0 | 26.2 |
| `someoneshout` | `ShineSomeoneShout` | FUN_004e8860 | FUN_004e9a60 | FUN_004eeeb0 | 26.2 |
| `summonmob` | `ShineSummonMob` | FUN_004e8880 | FUN_004e9ad0 | FUN_004ef160 | 26.3 |
| `spawn` | `ShineSpawn` | FUN_004e8f80 | FUN_004eb350 | FUN_004f7eb0 | 26.3 |
| `suicide` | `ShineSuicide` | FUN_004e8a40 | FUN_004ea0f0 | FUN_004f1980 | 26.4 |
| `teleport` | `ShineTeleport` | FUN_004e8d20 | FUN_004eab00 | FUN_004f4cc0 | 26.4 |
| `teleportall` | `ShineTeleportAll` | FUN_004e8ea0 | FUN_004eb040 | FUN_004f4930 | 26.4 |
| `walk` | `ShineWalk` | FUN_004e8a80 | FUN_004ea1d0 | FUN_004f1ef0 | 26.4 |
| `sublayershift` | `ShineSubLayerShift` | FUN_004e8d00 | FUN_004eaa90 | FUN_004f4770 | 26.4 |
| `timelimit` | `ShineTimeLimit` | FUN_004e85a0 | FUN_004e90c0 | FUN_004ebfc0 | 26.5 |
| `waitlogin` | `ShineWaitUserLogin` | FUN_004e87a0 | FUN_004e97c0 | FUN_004ee430 | 26.5 |
| `waitidle` | `ShineWaitIdle` | FUN_004e8be0 | FUN_004ea6a0 | FUN_004f3590 | 26.5 |
| `waitinterrupt` | `ShineWaitInterrupt` | FUN_004e8620 | FUN_004e9280 | FUN_004ecd10 | §15 |
| `whoclickme` | `ShineWhoClickMe` | FUN_004e8920 | FUN_004e9d70 | FUN_004f03a0 | 26.6 |
| `whokillme` | `ShineWhoKillMe` | FUN_004e8940 | FUN_004e9de0 | FUN_004f7170 | 26.6 |
| `weddingcomplete` | `ShineWeddingComplete` | FUN_004e8e40 | FUN_004eaef0 | FUN_004f6b70 | 26.7 |

Use in the 17 Pine books loaded in 2016 (§22.5; statements outside comments): `summonmob` 79 (GordonMaster, Honeying,
Monkey, UnderHall, UnderHall2, d_NestOfLeviathan), `scriptfile` 23 (13 books), `timelimit` 21 (14 books), `endofkq` 19
(the nine KQ books), `waitlogin` 12, `whoclickme` 12 (GordonMaster, GuildTournament, Wedding, d_NestOfLeviathan),
`suicide` 12 (GordonMaster, d_NestOfLeviathan), `sendquestresult` 10 (KQHBat1–5), `teleport` 8 (GordonMaster,
GuildTournament, Wedding), `scinariocode` 1 (JobChange2-1), `teleportall` 1 and `weddingcomplete` 1 (Wedding),
`whokillme` 1 (d_NestOfLeviathan). Not used by a loaded book: `someoneshout`, `spawn` (only the unlisted
`Map/MonkeyBreed0x.ps`), `sublayershift`, `waitidle` (only unlisted books: Kingkong, MiniDragon, HMiniDragon,
d_graveyard), `walk`.

### 26.1 KQ end and results: `endofkq`, `sendquestresult`, `scinariocode`

```pseudo
endofkq.                                 ShineEndOfKingdomQuest::sa_Step  @ FUN_004f5fc0   # last statement of the KQ books
    field = theater.t_Field; h = field ? field.fm_KQHandle : 0xFFFFFFFF
    if h == 0xFFFFFFFF: assert "…ShineEndOfKingdomQuest::sa_Step : Invalid Shine Quest"   # (original bug) Z09-B117: no return
    WorldManagerSession::wms_EndOfKQPacket(sock2wldman, h)                            @ FUN_005a4800
        → WM 0x5810 NC_KQ_Z2W_END_CMD { u32 Handle = h }  (6 bytes with the opcode; too long → assert with the text
          "…ShineEndOfKingdomQuest::sa_Step : Packet Too Long", nothing sent)
        KQContribute::KQContributeList::kqpl_EndOfKQ(&g_KQContributeList, h)      @ FUN_0049a500
            # removes the contribution entry (PlayerList) of handle h from the vector kqcl_List (made by kqcl_NewKQ, Z08)
    if field: FieldMap::fm_ClearObject(field, 0xb0)    # FUN_00495a10 (§24.8): kinds 4 NPC, 5 mob, 7 door removed next tick
    pop
```

The WM ends the KQ (`fc_NC_KQ_Z2W_END_CMD` FUN_0042aac0, W04 §6: status 5, broadcast 0x5811 NC_KQ_W2Z_DESTROY_CMD,
free its map slots); every zone then runs its 0x5811 handler (Z08: `kqpl_EndOfKQ` again, `fm_ClearObject(map, 0x3b0)`,
map KQ handle −1, the map's film is dropped). So `endofkq` itself removes the mobs, NPCs and doors at once; the bandits
(kind 8, mask 0x100) and the film go with 0x5811. The KQ books run it last, after `questresult` / `reward` (§25.6) and
after sending the players home themselves (KQHBat1: `broadcast all "KQReturn10"`, two pauses, `linkto all "Eld" "Eld"
17214 13445`, `endofkq`; its `PickUpMaulFirst` block ends the same way).

```pseudo
sendquestresult word handleExpr.         ShineSendKQResult::sa_Step  @ FUN_004f4300   # KQHBat2.ps: sendquestresult Suc PlayerHandle.
    v = argument 0 (fails: assert "…ShineSendKQResult::sa_Step : no Player", pop)
    o = som_GetObject(pst_GetNumber(v)) (FUN_0054fd10); null → pop (no assert)
    word = target word, lower-cased; cmd = word == index_suc "suc" (FUN_006976a0) ? 0x12 : 0x13
    o.vt[0x304] so_SendProtocol(0x16, cmd)      # empty 0x5812 NC_KQ_COMPLETE_CMD / 0x5813 NC_KQ_FAIL_CMD to that player only
    pop                                          # non-players: vt 0x304 is the no-op FUN_00509900
```

Unlike `questresult` (§25.6: every player of the map, `so_ply_KQSuccess` / `KQFail` title counters, GameLog 0x0442,
object clear), `sendquestresult` only sends the window packet to one player: the KQHBat books walk the ranking (`@KQResultList`, §22.3) and send `Suc` with
`invidualreward` to the first three players and `Fail` to the others. Client: the complete / fail
window and sound (FUN_004a31f0 / FUN_004a3270, §24.8).

```pseudo
scinariocode var codeExpr.               ShineScinarioCode::sa_Step  @ FUN_004f39d0   # JobChange2-1.ps: scinariocode PlayerHandle 16.
    o = os_ShineObject (§22.1); null: log line, pop
    code = argument 0 (fails: assert "…ShineScinarioCode::sa_Step : no code", log "Fail 1", pop)
    q = o.vt[0x808] so_ply_QuestDiary (FUN_0055a270; non-players: folded `return 0` FUN_00570b00)
    q ? CQuestZone::QuestPlayer_ScenarioDone_Server(q, code) (FUN_005bd750, Z15) and log "Suc"  :  log "Fail 2"
    pop
```

This is the single-player form of `ScinarioCodeParty` (§22.4, which walks the party). `QuestPlayer_ScenarioDone_Server`
completes the quest-script condition `code` of the player's running quests (quest engine, Z15; the item upgrade uses
code 5, Z05; the tutorial 7, Z08). JobChange2-1 reports scenario code 16 in its `QuestSuccess` block, right after
`questresult Suc`.

### 26.2 Dialog files and shouts: `scriptfile`, `someoneshout`

```pseudo
scriptfile name.                         ShineScriptFile::sa_Step  @ FUN_004ebde0   # d_NestOfLeviathan.ps: scriptfile "d_NestOfLeviathan".
    name = argument 0
        fails: assert "…ShineScriptFile::sa_Step: wrong argument"; return 0   # (original bug) Z09-B116: the film ends (§21.4)
    if name == "": ps_Shine.shinescript (+0x10130) = null                    # trace "Unset script file"
    else: ps_Shine.shinescript = KQScriptManager::operator[](&kqscriptmanager, name)   (FUN_0064ce70, §22.6;
        unknown name: assert "Invalid script name", null)
    pop
```

`ps_Shine.shinescript` is the dialog-string set read by `npcchat` / `npcshout` (§25.3), `NPCChatNoFacecut` (§22.4) and
`someoneshout`; with no set (never set, or unknown name) those nodes send nothing. It belongs to the film's process
stack, so each running film has its own.

```pseudo
someoneshout speakerKey textKey.         ShineSomeoneShout::sa_Step  @ FUN_004eeeb0   # unused in 2016
    a = argument 0 (fails: assert "…ShineChat::sa_Step : Null body", pop)
    b = argument 1 (fails: assert "…ShineChat::sa_Step : Null chat", pop)
    if ps_Shine.shinescript:
        speaker = ss_String(set, a); text = ss_String(set, b)   (FUN_0048ce60; "" when missing)
        0x201F NC_ACT_SOMEONESHOUT_CMD (layout §8.7) {
            speaker[20] = the first 20 bytes at `speaker` (a plain 20-byte copy: no terminator when ≥ 20 characters,
                bytes after a shorter string's terminator come from the string table),
            flag &= ~3 (GMColor 0, isMob 0: the client shows `speaker` as a name), other bits stale,
            len = strlen(text) as u8, content = text }
        to the whole map: AxialListPacketBroadcast over t_AllInMap (live players, same layer, §23.1); size len + 0x19
        # (original bug) Z09-B112: itemLinkDataCount (payload byte 0) is never written (stale, as in Z09-B71: the
        #   client then parses item links past the packet); a text of 256+ characters wraps the u8 length
    pop
```

`someoneshout` is the named-speaker counterpart of `npcshout` (which shouts as the NPC object, §25.3) and of Lua
`cSomebodyShout` (§19.3, which shouts as a mob ID).

### 26.3 Summoning mobs and starting films: `summonmob`, `spawn`

```pseudo
summonmob var mobName count.             ShineSummonMob::sa_Step  @ FUN_004ef160   # d_graveyard.ps: summonmob GiantMagmaton01 "ID_EarthCalerben" 2.
    o = os_ShineObject (the place); null → pop
    name = argument 0 (fails: assert "…ShineSummonMob::sa_Step : no mob", pop)
    mobId = mob ID of name (BTree::operator[] FUN_0063cc30 on mobdatabox.mdb_btree); unknown: assert "… no mob", pop
    n = number of argument 1 (fails: assert "… no number", pop)
    MobHatchery::mh_MobBreed(mobhatchery, o.so_Field.fm_MapID, o's position, 0, mobId, "-", mobNum n, regenSec 0,
        family 0, count 1, key "Def", brief null, "-", 0xFFFF, level −1, layer 0)            (FUN_004b6960, §10.6)
    pop
```

A new breeder group around the object's position (circle of radius 50) with `|n|` breeders (a negative `n` is made
positive, `mbg_MobBreed`); each spawns one mob on the next breeder tick and is freed after its mob is gone (§10.6). The
summoned mobs are ordinary breeder mobs: they are not written into a script variable, so a book that must count them
uses `@` counters or interrupts (§22.2, §15). The place object is the boss in the 2016 books (GordonMaster:
`summonmob GordonMaster "KQ_G_Gordon" 3.`; Monkey: `summonmob BossHandle SummonIndex 10.`). `o.so_Field` is read without
a check (a slot object without a field would pass a null map; not reached by the 2016 books).

```pseudo
spawn film [argument].                   ShineSpawn::sa_Step  @ FUN_004f7eb0   # MonkeyBreed01.ps: spawn "Map/Monkey" "2713 2311".
    film = argument 0 (fails: assert "…ShineSpawn::sa_Step : no script", pop)
    arg = argument 1 (os_Express[1].vt[8]); fails → arg = ""
        # (original bug) Z09-B118: the slot is used without a null check: `spawn "X".` (one argument, allowed by
        #   the 1–2 count of §21.2) dereferences a null expression and crashes the zone when the node steps
    if theater and its field:
        Movie::CinemaComplex::cc_PlayFilm(field.fm_Multiflex, film, arg, field.fm_MapID)   (FUN_005089a0, §27.2)
    pop
```

`spawn` starts another film of the scenario book shelf on the same map with an argument string (the Monkey books pass
a coordinate pair); the new film runs in parallel with the caller (the argument is its variable `InitFlag`, §27.2).

### 26.4 Killing and moving objects: `suicide`, `teleport`, `teleportall`, `walk`, `sublayershift`

```pseudo
suicide what.                            ShineSuicide::sa_Step  @ FUN_004f1980   # GordonMaster.ps: suicide #("InterruptArg").
    w = Identify::i_GetToken(target) (the word, or the value of a `#` variable, §20.5)
    if lower-case(w) == "all":                                  # literal string, same text as index_all
        so_AllInMap(t_CenterFlag, AxialListMobSuicide{alms_MobID 0xFFFF}, 0)   # every live mob of the map (§13.3)
        (null flag: assert "…t_AllInMap : Null flag")
    else if w == "<pst_GetNumber(w)>" (w is a plain number): # a handle
        o = som_GetObject(n); o: AxialListMobSuicide{0xFFFF}.alms_SelfKill(o)   (FUN_004f1720, §13.3: any object kind)
    else:                                                       # a mob name: every live mob of that type
        id = mob ID of w (unknown → 0xFFFF): assert "…ShineSuicide::sa_Step : Invalid mob id" with the name
        so_AllInMap(t_CenterFlag, AxialListMobSuicide{alms_MobID = id}, 0)
        # (original bug) Z09-B113: the assert does not return, so an unknown name walks with id 0xFFFF and kills
        #   every mob of the map
    pop
```

`alms_SelfKill` kills with the object as its own killer (`so_KilledBy(o, HP, 1000, 1)`), broadcasts 0x243C to sight and
runs the death check (§13.3) with the object as its own killer, so the death interrupts and the breeder bookkeeping
run as for any death. The handle form takes any kind (a player handle kills the player). 2016: `suicide
BombBoogySum01.` (d_NestOfLeviathan, mob names) and `suicide #("InterruptArg").` (GordonMaster: the hero NPC of the
interrupt dies after its last `npcchat`).

```pseudo
teleport word var [x y].                 ShineTeleport::sa_Step  @ FUN_004f4cc0
    # GuildTournament.ps: teleport SomeWhere Opener 5084 3326.   GordonMaster.ps: teleport AnyWhere GordonMaster.
    anywhere = lower-case(target word) == index_anywhere "anywhere" (FUN_00697940)
    v = argument 0 (fails: assert "…ShineSubLayerShift::sa_Step : no Player", copied text; pop)
    o = som_GetObject(pst_GetNumber(v)); null → pop
    anywhere: o.vt[0x6d8] so_mobile_Teleport()  (FUN_0057a8b0: a random free cell of the map, §9.3)
    else: x = argument 1 ("… no X"), y = argument 2 ("… no Y"); o.vt[0x6d4] so_mobile_Teleport(&{x, y})
        (players FUN_0057d1d0, mobs FUN_005793e0, §9.3: immediate move with sight update)
        # Z09-B118: with fewer than 3 arguments (allowed by 1–3) the missing slot is dereferenced (crash)
    pop
```

Any word other than "anywhere" means "to x y" (the books write `SomeWhere`). Non-mobile objects assert in the base
`so_mobile_Teleport` (FUN_0057a800 / FUN_0057a750) and stay.

```pseudo
teleportall word [x y | x1 y1 x2 y2].    ShineTeleportAll::sa_Step  @ FUN_004f4930   # Wedding.ps: teleportall Split 304 833 808 833.
    w = lower-case(target word)
    w == "anywhere": so_AllInMap(t_CenterFlag, AxialListTeleportAnywhere, 0)
        AxialListTeleportAnywhere::ali_Work(walker, o)          @ FUN_00428730
            if walker.so_ObjectType (vt 0x4d0) == 2:            # tests the walker, not o
                if o.vt[0x484] mode == 4: o.vt[0x488] so_ply_ReinforceFoldtent   # stand up from a tent
                o.vt[0x6d8] so_mobile_Teleport()
    w == index_split "split" (FUN_00697b20):
        x1, y1, x2, y2 = arguments 0–3 (x fails: assert "…ShineSubLayerShift::sa_Step : no X"; y: "… no Y"; pop)
        c = AxialListCount2 (ctor FUN_004e7d50); t_AllInMap(c)    # ali_Work FUN_00428780: counts objects of kind 2
        s = AxialListTeleportSplit(c.alc_Cnt, &{x1, y1}, &{x2, y2})   (ctor FUN_004e7d80: _Half = count / 2, _Current 0)
        t_AllInMap(s):  AxialListTeleportSplit::ali_Work(walker, o)  @ FUN_004287b0
            o not a player → continue
            o mode 4 → vt 0x488 (stand up)
            o.vt[0x400] so_TeleportReserv(_Current < _Half ? &{x2, y2} : &{x1, y1}); _Current++
    else: x, y = arguments 0, 1 (same asserts); so_AllInMap-walk AxialListTeleport{&{x, y}} via t_AllInMap
        AxialListTeleport::ali_Work(walker, o)                  @ FUN_004286e0
            walker kind == 2: o mode 4 → vt 0x488; o.vt[0x6d4] so_mobile_Teleport(&{x, y})
    pop
    # (original bug) Z09-B115: the "anywhere" and "x y" visitors test the kind of the walker (the map's centre flag,
    #   a ShineAxialFlag whose vt 0x4d0 is the folded `return 0` FUN_004b8d20) instead of the visited object, so they
    #   teleport nobody; only "split" (which tests o) works. Z09-B118 also applies (missing slots dereferenced).
```

`ShinePlayer::so_TeleportReserv` (vt 0x400, FUN_00496020; other objects: no-op FUN_00495fd0) only stores the target
(`sp_TeleportReserv`, flag `sp_MiscFlag.TeleportReserv`); the player tick (`ShinePlayer::so_Routine` FUN_0056c790,
§2.3) clears the flag and calls vt 0x6d4 on the next pass. The split counts players on all layers of the map
instance (the counter has no layer test) and sends the first half (in walk order) to the second point and the rest
to the first: the wedding puts the guests on the two sides of the aisle.

```pseudo
walk var x y.                            ShineWalk::sa_Step  @ FUN_004f1ef0   # unused in 2016
    as run (§25.2), with o.vt[0x8ac] so_scene_MovePathSet(x, y, 1 walk); ps_Shine.currentmob = o
    # asserts are the copied "…ShineRun::sa_Step : no locx / no locy"
sublayershift word var value.            ShineSubLayerShift::sa_Step  @ FUN_004f4770   # unused in 2016
    logout = lower-case(target word) == index_logout "logout" (FUN_00697920)
    v = argument 0 (fails: assert "…ShineSubLayerShift::sa_Step : no Player", pop)
    o = som_GetObject(pst_GetNumber(v)); null → pop
    n = argument 1 (fails: assert with the copied text "…ShineSendKQResult::sa_Step : no value", pop)
    if logout: ShineObject::so_Logout(o) (FUN_0054b780, §12: 0x1805 to sight; a booth is closed)
    o.so_layer.layer→l_Sub = n (u8)                       # the visibility class of so_SubLayer_CanSee (Z02 §5)
    pop
```

`l_Sub` selects the row / column of the 6 × 6 `World/SubLayerInteract.txt` table (Z01, Z02 §5: 0 normal, 3 GM hide).
Changing it sends nothing by itself; the `logout` form first removes the object from the clients in sight, so that
the next sight exchange (moves, §9) shows it only to those the new class may see *(inferred: no re-announce is made
here)*.

### 26.5 Time limits and waits: `timelimit`, `waitlogin`, `waitidle`

```pseudo
timelimit unit n.                        ShineTimeLimit::sa_Step  @ FUN_004ebfc0   # KQHBat1.ps: timelimit Min 15.  timelimit Sec 30.
    unit = target word (i_GetToken, case kept); n = argument 0
        fails: assert "…ShineTimeLimit::sa_Step: wrong argument"; return 0      # Z09-B116: the film ends
    Movie::TimeLimit::tl_SetTimeLimit(&theater.t_TimeLimit (+0x1023c), unit, n)   @ FUN_00507e60
        tl_IsActiv = 1
        seconds = n × 3600 if unit starts with 'H' / 'h', n × 60 if 'M' / 'm', else n
        tl_EndTick = g_Now + seconds × 10; tl_RestMinuteSend = 99999999
    Movie::TimeLimit::tl_LeftTick(&theater.t_TimeLimit)                           @ FUN_00507f60
        left = tl_EndTick − g_Now (ticks); s = left / 10
        if s / 60 ≠ tl_RestMinuteSend: tl_RestMinuteSend = s / 60
            0x0810 NC_MISC_RESTMINUTE_CMD { u8 flag = 1; u16 second = s }   (5 bytes with the opcode) to the whole map
            (AxialListPacketBroadcast via so_AllInMap(t_CenterFlag); null flag → assert, nothing)
        return left
    pop
```

The reset of `tl_RestMinuteSend` makes the first `tl_LeftTick` always send, so the client's map timer starts at once;
afterwards `tl_LeftTick` is called by the `TimeOut` interrupt check (§15.4) and sends again each time the remaining
time crosses a minute. The u16 is **seconds** (`second` in `PROTO_NC_MISC_RESTMINUTE_CMD`, *(pdb2016)* and
*(pdb2017)*): this answers part 9b's question; Z01's annotation of 0x0810 calls it "minutes = limit / 10" (correction
for the knowledge file). A later `timelimit` replaces the running limit. Who clears `tl_IsActiv` and the rest of
`Movie::TimeLimit` (`tl_GetTimeLimit_Second` FUN_00507df0, KQ timer functions): §27.4.

```pseudo
waitlogin var.                           ShineWaitUserLogin::sa_Step  @ FUN_004ee430   # KQHBat1.ps: waitlogin Players.
    first step (*ip == 0): *ip = 1; ps_Shine.waittick (+0x1010c) = g_Now + 2400      # 240 s
    v = target.i_GetVariable (null only for a failed `#` form: assert "…ShineWaitUserLogin::sa_Step", pop)
    k = AxialListMobCounter{almc_MobID 0xFFFF, guild 0, counter 0, max 1, search ala_SearchPly}   (§15.7: live players,
        mode 1/2/4/6); so_AllInMap(t_CenterFlag, k, 0) (null flag: assert)
    if k.almc_Counter < 1 and g_Now ≤ waittick: return 1               # wait, stepped again next pass
    v = "" then pst_MergeNumber(v, counter ≥ 1 ? 1 : 0)                 # 1 = a player came, 0 = timed out
    pop
```

The KQ, promotion and guild-tournament books use it before their first round (KQHBat1: `waitlogin Players.` then
`if Players === 0 then … call "QuestEnd"`): an instance whose players never arrive ends itself after 4 minutes.

```pseudo
waitidle.                                ShineWaitIdle::sa_Step  @ FUN_004f3590   # Kingkong.ps (unlisted): waitidle.  ; wait while the boss casts
    first step: *ip = 1 (trace only)
    o = os_ShineObject(ps)                    # the node has no target (os_IDRead 0): os_Ident is empty, i_GetVariable
                                              #   returns null → assert "…OtherStatement::sa_Step", o = null
    if o and not o.vt[0x8c4] so_scene_IsIdle (ShineMob FUN_0050def0: smo_SkillCast end time (+0x1d84) ≠ 0, a cast
        is running; players / others: folded `return true`): return 1    # wait
    pop
    # (original bug) Z09-B114: with no target the object is always null, so `waitidle` never waits (and asserts every
    #   time); the intended "wait until the boss's cast ends" cannot work. No loaded 2016 book uses it.
```

### 26.6 Who clicked, who killed: `whoclickme`, `whokillme`

```pseudo
whoclickme var handleExpr.               ShineWhoClickMe::sa_Step  @ FUN_004f03a0   # GuildTournament.ps: whoclickme Opener InterruptArg.
whokillme var handleExpr.                ShineWhoKillMe::sa_Step   @ FUN_004f7170   # d_NestOfLeviathan.ps: whokillme bufftarget InterruptArg.
    t = target.i_GetVariable (failed `#` form: assert "…sa_Step", pop; a missing name writes the shared deftkn, Z09-B82)
    a = argument 0 (fails: assert "… : no Player", pop)
    o = som_GetObject(pst_GetNumber(a)); null: assert "… : No npc", pop
    h = whoclickme ? o.vt[0x810] so_mobile_WhoIsClickMe (FUN_00555750: smo_WhoClickMe +0x186)
                   : o.vt[0x80c] so_mobile_WhoIsKillMe  (FUN_00555740: smo_WhoKillMe +0x184)
    t = "" then pst_MergeNumber(t, h)          # a handle; 0 / stale for an object never clicked / killed
    pop
```

`smo_WhoClickMe` is written by `ShineMobileObject::so_mobile_SetClicker` (vt 0x814, FUN_00555760), called from the
NPC-click handler `sp_NC_ACT_NPCCLICK_CMD` FUN_004c4b70 (Z02) right after it raises the `sim_NPCClick` interrupt
(§15); the film steps on a later main-loop pass (§21.4), so the clicker is already stored when `whoclickme` runs.
`smo_WhoKillMe` is written by `ShineMobileObject::so_KilledBy` (§5). Both slots resolve to these two getters for
players, mobs, NPCs and bandits (other kinds not traced; the 2016 books pass NPC and mob handles).

### 26.7 Wedding: `weddingcomplete`

```pseudo
weddingcomplete a b.                     ShineWeddingComplete::sa_Step  @ FUN_004f6b70   # Wedding.ps: weddingcomplete ClickGroom ClickBride.
    # the two arguments are never evaluated
    g = som_FindPlayer(weddinghall.Groom.RegistNumber) (FUN_00550360; global weddinghall, Z07 / Z13)
    b = som_FindPlayer(weddinghall.Bride.RegistNumber)
    if g and b and both are players (kind 2):
        → Character DB 0x1091 NC_CHAR_WEDDING_DO_REQ { NETPACKETZONEHEADER { u16 clienthandle = g.handle,
            u32 charregistnumber = g (vt 0x344) }, u32 Partner = b (vt 0x344) }   (12 bytes with the opcode; to
            sock2gameDB; too long → assert "…ShineWeddingComplete::sa_Step : Packet Too Long")
    pop                                       # either partner absent: nothing (no message, no retry)
```

The DB marks both characters married (`p_Char_Wedding_Do`, D02) and answers 0x1092 NC_CHAR_WEDDING_DO_ACK, handled by
the zone `GameDBSession::gds_NC_CHAR_WEDDING_DO_ACK` FUN_005a1830 (Z07: reload both, wedding item and skills on success). The partners are taken from the hall
reservation, not from the script's click variables; they must be on this zone (any map). The hall timetable and the
ceremony flow around this statement are Z13.

### 26.8 2016 use, answers and open points

- Part 15c's list for 15d is closed: `ShineEndOfKingdomQuest` (§26.1), `ShineSummonMob` (§26.3), `ShineScriptFile`
  (§26.2), `ShineWalk`, `ShineTeleport`, `ShineSuicide` (§26.4), `ShineWaitIdle` (§26.5) and the rest of the table.
  With this section every `Shine*` node of §21.2 is documented (§13, §15, §23–§26, §8.2).
- Part 9b's open point (0x0810 unit): seconds (§26.5).
- Z08's open point "the map scripts that run kingdom quests": the KQ end is `questresult` → `reward` → `endofkq`
  (§25.6, §26.1); the WM's 0x5811 removes the rest (Z08, W04).
- Not traced: `QuestPlayer_ScenarioDone_Server` (Z15); the wedding
  hall registration (`weddinghall.Groom` / `.Bride`, Z13); whether a `sublayershift` without `logout` leaves stale
  objects on clients (sight refresh, Z02 §5).

---

## 27. Scripts 14: films (`Movie::*`) and the boss-field tables (`BossFieldContent::*`)

A **film** is one running scenario book (§22.5) on one map instance: a Pine script (`PSFilm`, run one node step per
main-loop pass, §21.4) or a Lua script (`LuaFilm`, whose `Main` is called every pass). Every map has one
`Movie::CinemaComplex` (`fm_Multiflex`, field+0x44) with **8 film slots**; its anchor flag 2 runs it (§12.7). This
section documents the cinema itself (start, stop, step, time limit) and who starts and stops films; the interrupt API
of the films is §15, the Pine engine §20–§26, the Lua engine §14. Names *(pdb2016)* (`Zone.pdb`).

### 27.1 Objects

| Object | Layout *(pdb2016)* | Notes |
|---|---|---|
| `Movie::CinemaComplex` (0x12E798) | base `List<Movie::FilmCase>` (+0 vftable, +4 `l_MaxSize` = 8, +8 `l_Array`, +0xc `l_Finger {empty, store}`, +0x14 `l_ListNum`), +0x18 `cc_FilmCase[8]` (0x108 each), +0x858 `cc_PSFilm[8]`, +0x977F8 `cc_LuaFilm[8]` (0x12DF4 each) | list slot *i* always uses `cc_FilmCase[i]` and, by book type, `cc_PSFilm[i]` or `cc_LuaFilm[i]`: a film object belongs to a slot, not to a book |
| `Movie::FilmCase` (0x108) | +0 `fc_ScriptName` (`PineScriptToken`), +0x100 `fc_ScriptID` (book index), +0x104 `fc_Film` | the list entry |
| `Movie::FilmBase` → `PSFilm` / `LuaFilm` (0x12DF4) | +4 `fb_Theater` | vt 0 scalar deleting destructor FUN_005084b0, vt 4 `fb_ScriptInterrupt`, vt 8 `fb_SetInterruptClear` (PSFilm FUN_00507ae0 / FUN_00508f00; FilmBase and LuaFilm: the folded no-ops FUN_00509900 / FUN_00417480) |
| `Movie::Theater` (0x12DF0) | §15.1 | +0 `t_SenarioType` (`ST_NONE` 0, `ST_PS` 1, `ST_LUA` 2), +4 `t_LuaScript`, +8 `t_Screen` (`ProcessStack`, §20.6), +0x1023C `t_TimeLimit`, +0x1024C `t_InterruptManager`, +0x12CE4 `t_ScriptName`, +0x12DE4 `t_ScriptID`, +0x12DE8 `t_Field`, +0x12DEC `t_CenterFlag` |
| `Movie::TimeLimit` (0x10) | +0 `tl_EndTick`, +4 `tl_RestMinuteSend`, +8 `tl_IsActiv`, +0xc `tl_Theater` | §27.4 |

```pseudo
Movie::CinemaComplex::CinemaComplex(cc)        @ FUN_00509330
    List<Movie::FilmCase>::l_MakeList(cc, 8)    @ FUN_00508cc0   # 9 ListStruct cells (8 + sentinel 8); all free, l_ListNum 0
    construct cc_FilmCase[8] (Movie::FilmCase::FilmCase FUN_005072d0: name "", fc_ScriptID −1, fc_Film null),
              cc_PSFilm[8] (Movie::PSFilm::PSFilm FUN_00507950), cc_LuaFilm[8] (Movie::LuaFilm::LuaFilm FUN_00507a50)
    list cell i → content &cc_FilmCase[i]
PSFilm / LuaFilm ctor: FilmBase vftable; ProcessStack ctor (theater+8); ScriptInterruptManager ctor (theater+0x1024C);
    t_ScriptName = ""; t_Screen.ps_Shine.theater = t_TimeLimit.tl_Theater = &fb_Theater; own vftable
    # tl_EndTick, t_SenarioType, t_LuaScript are not initialised (CinemaComplex comes from operator new)
Movie::CinemaComplex::cc_SetArgument(cc, map, flag) → cc   @ FUN_005086d0
    for i in 0..7: cc_PSFilm[i].fb_Theater.{t_Field = map, t_CenterFlag = flag}; same for cc_LuaFilm[i]
    # called by FieldMap::fm_Init (flag = anchor 2) and again by fm_CreateGuildTournamentSystem (§12.7)
```

Destruction (`~CinemaComplex` FUN_00507d40 / `scalar_deleting_destructor` FUN_005086a0, `~FilmCase` FUN_00507370,
`~PSFilm` FUN_005079e0, also used for the Lua films): maps are never freed while the zone runs, so these only run at
exit. Container boilerplate: `List<Movie::FilmCase>` dtor FUN_005074c0 / `scalar_deleting_destructor` FUN_005075c0 /
`l_PushA` FUN_005074e0 / `l_PushZ` FUN_005083f0 / `l_PopA` FUN_00507520 / `l_PopZ` FUN_00507570 (copies, never used by
the cinema), `ListEraser<Movie::FilmCase>` dtor FUN_00507600. The list's own slots (CinemaComplex vftable): vt 4
`l_AllocA(index)` FUN_0054b1e0 (take the given free cell, link it **first**), vt 8 `l_AllocZ`, vt 0xc `l_Free(index)`
FUN_004b1300 (unlink, back to the free ring; refuses the sentinel). So the **newest film is first** in every walk.

### 27.2 Starting a film

```pseudo
Movie::CinemaComplex::cc_PlayFilm(cc, bookName, argument, mapID) → book index | −1   @ FUN_005089a0
    log "Movie::CinemaComplex::cc_PlayFilm 1" (KQLogging, also "… 2", "… 3", "… Free" below)
    i = cc.l_Finger.empty (the first free cell); i == 0xFFFF → fc = null
    else fc = cc.l_AllocA(i)                                         # cell i taken, linked at the head
    fc null: assert "Movie::CinemaComplex::cc_PlayFilm : Too many film"; return −1        # 8 films already
    book = scenarioshelf.sbs_GetScenarioBook(bookName, &index)      # FUN_00507b90, §22.5
    book null: return −1                                             # (original bug) Z09-B119: cell i stays allocated
    type = book.vt[8]()     # 1 Pine, 2 Lua
    type 0: assert "…cc_PlayFilm : Wrong scenario type"; return −1  # Z09-B119 too (no 2016 book has type 0)
    fc.fc_Film = type 1 ? &cc_PSFilm[i] : &cc_LuaFilm[i]
    fc.fc_ScriptName = bookName; fc.fc_ScriptID = index
    fc.fc_Film.vt[8]()                                               # fb_SetInterruptClear: drop the slot's old interrupts (PSFilm)
    r = Movie::FilmBase::fb_PlayFilm(fc.fc_Film, bookName, argument, mapID)   @ FUN_00508540 → t_PlayFilm(&fb_Theater, …)
    r == −1: assert "Script Error" (bookName); cc.l_Free(i)          # cannot happen: the same name was just found
    return r
Movie::Theater::t_PlayFilm(t, bookName, argument, mapID) → t_ScriptID | −1   @ FUN_005081f0
    t.t_SenarioType = ST_NONE; t.t_LuaScript = null; t.t_ScriptName = bookName
    book = sbs_GetScenarioBook(t_ScriptName, &t.t_ScriptID); null → return −1
    t.t_SenarioType = book.vt[8]()
    ST_PS:  script = book.vt[0xc]()   (null: assert "Movie::Theater::t_PlayFilm : Null PSScript", the stack is left as it was)
            PineScriptStack::ProcessStack::ps_Ready(&t.t_Screen, script)     # §20.6: Script at ps_Stack[0], ip 0
            t.t_TimeLimit.tl_IsActiv = 0
            v = ps_PushVariable(&t.t_Screen, "InitFlag"); if v: v = argument (256 bytes)
    ST_LUA: t.t_LuaScript = book.vt[0x10]()                          # the book's LuaScriptScenario (shared, below)
    other:  t_SenarioType = ST_NONE; assert "Invalid Script Type" (then also reads vt[0x10])
    return t.t_ScriptID
    # mapID is not used: the map comes from cc_SetArgument
```

- **The film argument** is a string. A Pine film sees it as the global variable **`InitFlag`** (pushed at the bottom of
  the variable stack before `[main]` runs, so every block can read it): `ConditionOfHero.ps` / `KQHBat2.ps` build
  regen-group and reward keys from it (`"HERO" % InitFlag`), the Monkey books get a coordinate pair from `spawn`
  (§26.3), the guild tournament gets four numbers (below). A **Lua film ignores the argument**.
- **Lua films share one Lua state.** `t_LuaScript` is the book's own `LuaScriptScenario` (one `lua_State` per file,
  §14.1), so every map running the same Lua book uses the same globals. The 2016 instance scripts therefore key all
  their state by map: `common.lua` `Main(Field)` starts with `InstanceField[Field]` (created on the first call) and
  `InstanceDungeonClear(Field)` sets it to nil.
- Two films with the same book can run on one map (only the quest starter checks `cc_IsDuringPlay` first); a drop by
  name stops the newest of them.

### 27.3 Running and stopping films

```pseudo
# once per main-loop pass, from ShineAxialFlag::so_Routine of anchor 2 (§12.7):
List<FieldMap>::l_4AllInList(cc, Movie::FilmCase::fc_Routine)      @ FUN_004026e0
    # walks from the sentinel's next cell (newest first); reads the next cell before the call, so the visited
    # film may free its own cell; stops at a cell that is not active
Movie::FilmCase::fc_Routine(fc, list, i) → 1                         @ FUN_00508e40
    if fc.fc_Film and !Movie::FilmBase::fb_Routine(fc.fc_Film, i):  list.l_Free(i)     # vt 0xc: the film has ended
        # fc_Film and fc_ScriptName are left in the free cell (cc_PlayFilm overwrites them on reuse)
Movie::FilmBase::fb_Routine(f, i) = Movie::Theater::t_Routine(&f.fb_Theater, i)   @ FUN_005085f0
Movie::Theater::t_Routine(t, i) → keep                               @ FUN_00508090
    ST_PS:  return PineScriptStack::ProcessStack::ps_Step(&t.t_Screen, i) ≠ 0      # one node step (§21.4)
    ST_LUA: t_LuaScript null → return 0
            LuaScriptScenario::lss_Routine(t_LuaScript, "Main", LuaArgumentInstanceDungeon(t_Field))   # §14.1 / §14.4: Main(mapID)
            return 1                                                  # a Lua film never ends by itself
    else:   return 0
```

The `ushort` passed down to `ps_Step` (§21.4's `arg`) is the **film's cell index 0–7**; no Pine node reads it. A
film steps once per main-loop pass, and the loop has no fixed tick (§1.1: it runs as fast as it can and sleeps 1 ms
at most every other pass when idle), so Pine timing never relies on the step count: waits use `g_Now`
(`pause` §25.5, `waitlogin` §26.5, `timelimit` §27.4, the `interval` interrupt §15.4). The 100 area re-checks of an
area interrupt (§15.4) therefore last 100 passes, a fraction of a second on an idle zone and longer on a busy one
*(inferred: pass rate not measured)*.

```pseudo
Movie::CinemaComplex::cc_DropFilm(cc, bookName, map) → found          @ FUN_00509150
    fc = the first film (newest first) whose fc_ScriptName == bookName
         (ListSearchSame<Movie::FilmCase>::lid_Call FUN_00474e40 + Movie::FilmCase::fc_NameCompare FUN_00507410)
    none: return 0
    book = sbs_GetScenarioBook(bookName); lua = book ? book.vt[0x10]() : null      # Pine books: null
    if lua: LuaScriptScenario::lss_FuncExec(lua, "InstanceDungeonClear", LuaArgumentInstanceDungeon(map))   # Lua films only
    fc.fc_Film.vt[8]()                     # fb_SetInterruptClear, no null check (see Z09-B119)
    fc.fc_Film = null; cc.l_Free(cell); return 1
    # the theater is not reset (its Pine stack, time limit and variables stay until the cell is reused)
Movie::CinemaComplex::cc_IsDuringPlay(cc, bookName) → bool            @ FUN_00508fc0   any film with that name
FieldMap::fm_PlayFilm(map, bookName, argument)                       @ FUN_00419320 = cc_PlayFilm(map.fm_Multiflex, …, map.fm_MapID)
FieldMap::fm_DropFilm(map, bookName)                                 @ FUN_00419340
    cc_DropFilm(map.fm_Multiflex, bookName, map); MapBlock::MapDoorArray::mda_CloseAllDoor(map)   # §9.2: every door of the map closed
FieldMap::fm_PlayFilmNum(map) = map.fm_Multiflex.l_ListNum           @ FUN_0043f770   (films running; user: mc_AllDropFilm, Z14)
FieldMap::fm_QuestPS_Start(map, bookName, argument) → index | −1     @ FUN_005b9970 = cc_PlayFilm(…, PineScriptToken(argument), …)
FieldMap::fm_StartScript(map, list, i) → 1                           @ FUN_005ad800
    if map.fm_FieldOption.script ≠ "-": cc_PlayFilm(map.fm_Multiflex, script, "", map.fm_MapID)
    # visitor run over every map by ZoneServer_zs_start_open FUN_005b6640 (last start stage, after nm_SetNPC):
    # the Field.txt map scripts (2016: OX_field → Map/OXFieldInit, §22.5) start once at boot and run forever
cDropFilm(mapName, bookName)                                         @ FUN_005d6b00   (Lua, returns nothing)
    both arguments present and the map found (fc_FindMap): cc_DropFilm(map.fm_Multiflex, bookName, map); mda_CloseAllDoor(map)
    # 2016 use: Promote/Job2_Forest and Job2_Gamb Progress.lua drop their own film (MainLuaScriptPath) when the
    # player leaves; the Lua state is re-entered for InstanceDungeonClear while Main is still on the C stack
    # (inferred: Progress functions are called from Main)
```

(original bug) Z09-B119: `cc_PlayFilm` takes the free cell before it looks the book up and does not give it back when
the book is unknown (or has type 0). The cell stays in the list with `fc_Film` = null and the name of the film that
last used the cell ("" for a fresh one, the old name after a drop): `fc_Routine` skips it, so the map has one film slot
fewer until the zone restarts, and `cc_IsDuringPlay` still reports the old name as playing (a quest `PsStart` of that
book is refused). A later `cc_DropFilm` of that old name finds this cell first and calls `fc_Film.vt[8]` through the
null pointer (crash). Reachable through the book names that come from input: GM `&kingdomquest` /
`&playinstancedungeon` names, Pine `spawn` arguments, quest `CALLPS` names (Z15).

### 27.4 Time limits (`Movie::TimeLimit`, Pine `timelimit`)

```pseudo
Movie::TimeLimit::tl_SetTimeLimit(tl, unit, n)                       @ FUN_00507e60   (ShineTimeLimit, §26.5)
    tl.tl_IsActiv = 1
    seconds = unit[0] in 'H','h' ? n·3600 : unit[0] in 'M','m' ? n·60 : n          # "Sec", anything else = seconds
    tl.tl_EndTick = g_Now + seconds·10; tl.tl_RestMinuteSend = 99999999            # forces a send at the next check
Movie::TimeLimit::tl_LeftTick(tl) → left (tenths, may be negative)   @ FUN_00507f60
    left = tl_EndTick − g_Now; s = left / 10; m = s / 60
    if m ≠ tl_RestMinuteSend:
        tl_RestMinuteSend = m
        to every object of the map (so_AllInMap(tl.tl_Theater.t_CenterFlag, AxialListPacketBroadcast, 0); null flag:
            assert "Movie::Theater::t_AllInMap : Null flag"):
            0x0810 NC_MISC_RESTMINUTE_CMD { u8 flag = 1; u16 second = s }        # §26.5; once per minute boundary
    return left
Movie::TimeLimit::tl_GetTimeLimit_Second(tl) = (tl_EndTick − g_Now) / 10   (unsigned)   @ FUN_00507df0   (`@RestSec`, §22.2, B90)
```

Callers: `ShineTimeLimit::sa_Step` (set + first check, §26.5), the `TimeOut` interrupt (`ScriptInterruptTimeOut::
sib_BlastCheck` FUN_0050ae40: fires when `tl_LeftTick ≤ 0`, §15.4) and `@RestSec`. Nothing else. Other 0x0810 senders
(Lua timer functions §17, the instance timeout of `mc_Routine` Z14) do not use a `TimeLimit`.

(original bug) Z09-B120: `tl_IsActiv` is written (1 by `timelimit`, 0 by `t_PlayFilm`) and never read. The `TimeOut`
interrupt and `@RestSec` use `tl_EndTick` whether or not this film set a limit, so in a film without `timelimit` the
interrupt fires at a time left over from the cell's previous film (or from uninitialised memory on the first use of the
cell) and its check broadcasts 0x0810 with that time to the map. Every 2016 book that uses `TimeOut` sets `timelimit`
first, so this is latent.

### 27.5 Who starts and stops films

| Caller | Item | Film call | Argument / notes |
|---|---|---|---|
| `FieldMap::fm_StartScript` FUN_005ad800 | Z09 (§27.3) | play `Field.txt` ScriptName at boot | "" |
| Pine `spawn` FUN_004f7eb0 | Z09 (§26.3) | `cc_PlayFilm` | the node's second argument |
| Lua `cDropFilm` FUN_005d6b00 | Z09 (§27.3) | `cc_DropFilm` + doors | — |
| `CQuestZone::PsStart` FUN_005bbd00 → `fm_QuestPS_Start` | Z15 (quest `CALLPS`) | play, refused when `cc_IsDuringPlay(name)`; `m_ScriptIdent` = book index | the player's name (vt 0x56c) |
| `KingdomQuest::KQElement::kqe_QuestStart` FUN_004953e0 | Z16 | per KQ map (up to 4): drop `kqe_Script`, close doors, play | `kqe_InitValue` |
| `wms_NC_KQ_W2Z_DESTROY_CMD` FUN_004972c0 | Z16 / Z08 | drop `kqe_Script` + doors on every KQ map | — |
| `wms_GuildTournamantStart` FUN_00476de0 | Z16 | `fm_ClearObject(0x3b0)`, drop + doors, play `Guild/GuildTournament` | `"%d %d %d %d"` (tournament numbers) |
| `WeddingHall::wh_Start` FUN_005a25a0 | Z13 | play `Wedding/Wedding` | the couple (not read here) |
| `ZoneRingPacketFindInstanceDungeon::zrpb_Success` FUN_005a8c20 | Z14 | `fm_ClearObject(0x3b0)`, drop + doors, play the dungeon's ScriptName | "" |
| `ZoneRingPacketFindJobDungeon::zrpb_Success` FUN_005a8f40, `ShinePlayer::so_ply_2JobDungeon` FUN_0049f880 | Z14 | `fm_ClearObject(0x3b6)`, play (the second also clears the map's revive flags) | "" |
| `MapCluster::mc_PlayAllFilm` FUN_00485fb0 (← `cm_PlayAllFilm` FUN_004a0d40, `FieldContainer::fc_Load`) | Z14 | `fm_PlayFilm` per instance map | "" |
| `MapCluster::mc_AllDropFilm` FUN_00485290, `mc_DeleteInstanceDungeon` FUN_00486710, `mc_MissoionFailInstance` FUN_0049ee70, `cm_AllDropFilm` FUN_00486ec0 | Z14 | `fm_DropFilm` / `cc_DropFilm` (+ `fm_PlayFilmNum`) | — |
| `wms_NC_INSTANCE_DUNGEON_LEVEL_SELECT_JOIN_ECHO_REQ` FUN_004871a0 | Z08 / Z14 | `fm_ClearObject(0x3b0)`, `fm_DropFilm`, `fm_SetIndunLevelType`, `fm_PlayFilm` | "" |
| GM `ac_PlayInstanceDungeon` FUN_00421190, `ac_KingdomQuest` FUN_00423dd0, `ac_BigBang` FUN_004240d0, `ac_IndunReload` FUN_00419810 / `ac_ReroadKingdomQuest` FUN_0041dc80 (`cm_AllDropFilm` then `sbsReLoad`) | Z11 | play / drop | GM text |

The drop-and-restart pattern (clear the map's objects, drop the old film, close all doors, play again) is how every
reused map (instance, KQ, tournament) is reset; `cc_DropFilm` alone does not touch objects or doors.

### 27.6 Boss-field tables (`BossFieldContent`)

Three tables loaded by `ZoneServer_zs_start_long` FUN_005b8c00 right after `FieldContainer::fc_AbstateInFieldLoad` and
`MapBuffDataBox::mbdb_Load` (so after `MobInfo` and the abstate dictionary); their users are §8.9 and §11.

```pseudo
BossFieldContent::ServentBuffBossTable::sbbt_Load(t)                  @ FUN_005d4580   g_ServentBuffBossTable DAT_14d6fca4
    for each row of ../9Data/Shine/StateMob.shn (StateMob 0x64: TargetMobInx, ConditionMobInx, AbStateInx, u32 Strength):
        buffer = mdb_2MobID(ConditionMobInx); 0xFFFF → assert "ServentBuffBossTable::sbbt_Load : ConditionMob not found", ShineExit
        buffee = mdb_2MobID(TargetMobInx);    0xFFFF → assert "… TargetMob not found", ShineExit
        a = dic_abstate.as_BTreeIndex[AbStateInx]; missing → assert "… Abstate not fount", ShineExit (exit text "FieldContainer::fc_AbstateInFieldLoad": copied)
        mobdatabox[buffer].MobIndexFlag.IsBufferToBoss = 1                       # ShineMob::so_Routine calls sm_IBuffToBuffee (§8.9)
        t.sbbt_List.insert(ServentBossTable{ sbt_Buffer = buffer, sbt_Buffee = buffee, sbt_AbstateIndex = a,
                                             sbt_Dictionary = as_FromIndex(a), sbt_AbstateStrength = Strength })
        # std::set ordered by sbt_Buffer: one row per buffer mob (a second row of the same buffer is dropped, inferred)
sbbt_FindBuffer(t, mobId) → row | null                                @ FUN_005d47f0   (§8.9)
sbbt_TimerReset(t): t.sbbt_NextTick = 0                               @ FUN_005d2520
    # called at the end of every WM 0x0821 (wms_NC_MISC_TIMEFROMWORLD_CMD FUN_004511a0, §1.2): the first message
    # resets g_Now to 0, so the 5-s pulse must restart; the later (per-minute) calls only add one extra buff pulse a minute
BossFieldContent::`dynamic_initializer_for_'g_ServentBuffBossTable'' FUN_0069b690: empty set, sbbt_NextTick = 0

BossFieldContent::ListOfMobStateCheckAtDead::lomscad_Load(l)          @ FUN_005d5970   g_ListOfMobStateCheckAtDead DAT_14d6fcb8
    lomscad_StructList = [ empty entry ]                              # entry 0 = "no check": operator[] returns it for every other mob
    lomscad_IndexList = one int per MobInfo ID, all 0
    for each row of ../9Data/Shine/MobAbStateDropSetting.shn (0x47: MobInx, ABStateInx, StateDropType DropType, u8 MaxCount):
        id = mdb_2MobID(MobInx); 0xFFFF → assert "…lomscad_Load : Invalid mob", ShineExit
        if IndexList[id] == 0: IndexList[id] = StructList.size; StructList.push_back(empty entry)
        s = as_FromName(ABStateInx); null → assert "…lomscad_Load : Invalid abstate", ShineExit
        MobAbstateCheckAtDead::macad_PushBack(StructList[IndexList[id]], s.index.AbStataIndex, DropType)
    # MaxCount is not read (the drop table's own list count decides how far bossAbstate can go, §11)
BossFieldContent::MobAbstateCheckAtDead::macad_PushBack(e, abstate, type)   @ FUN_005d50f0
    abstate already in e.macad_List → assert "…lomscad_Load : Duplicate abstate", ShineExit
    list empty: e.macad_Type = type
    else: type ≠ e.macad_Type → assert "…macad_PushBack : DropType not same", ShineExit
          e.macad_Type ≠ SDT_STA (0) → assert "…macad_PushBack : SDT_STA must be one", ShineExit
              # i.e. only SDT_STA (count the listed abstates) may list several; SDT_STRENGTH (1) takes exactly one
              # (the message names the wrong type: log text only)
    e.macad_List.push_back(abstate)
operator[] FUN_005d2580: id ≥ IndexList size or index ≥ StructList size → entry 0, else StructList[IndexList[id]]
    # macad_AbstateCheck FUN_005d3880 and smo_BossAbstateSet: §8.9

BossFieldContent::MobAutomaticActionList::maal_Load(l)                @ FUN_005d49f0   g_MobAutomaticActionList DAT_14d6fc94
    for each row of ../9Data/Shine/MobAutoAction.shn (0x51: MobInx, ATKTYPE Attack, TargetType Target, GTIActionType
                                                     ActionType, StateInx, u8 Strength, u16 EffectRate, u16 Range):
        id = mdb_2MobID(MobInx); 0xFFFF → assert "…maal_Load : Invalid mob in MobAutoAction", ShineExit
        if Attack == SKLTP_DAMAGE (0): mobdatabox[id].MobIndexFlag.MobAutoAction_Damaged = 1
        ActionType ≠ GTIT_ABSTATE (1) → assert "…maal_Load : ActionType not defined", ShineExit
        a = dic_abstate.as_BTreeIndex[StateInx]; missing → assert "…maal_Load : Abstate not fount", ShineExit
        l.maal_Set.insert(MobAutomaticAction{ maa_MobID = id, maa_ActionType = ActionType,
                                              maa_Abstate = { Index a, Strength, Rate = EffectRate, Range } })   # one per mob
    # Target is not read: the action always hits the attacker
BossFieldContent::MobAutomaticActionList::maal_MobDamaged(l, mobId, attacker, mob)   @ FUN_005d4c40
    # from ShineMob::so_DamagedBy FUN_00431750 after the aggro / hit-list update, when attacker ≠ null and the mob's
    # data entry has MobAutoAction_Damaged
    e = maal_Set.find(mobId); none, or e.maa_ActionType ≠ GTIT_ABSTATE, or attacker null: return
    if rndbox.rb_1000() < e.Rate and so_DistanceSquar(attacker, mob) < e.Range²:
        attacker.so_AbnormalState_Set_Simple(caster = attacker, e.Index, e.Strength, 1)   (vt 0x644, Z03)
BossFieldContent::`dynamic_initializer_for_'g_MobAutomaticActionList'' FUN_0069b720 / `…g_ListOfMobStateCheckAtDead'' FUN_0069b710:
    empty containers; atexit destructors FUN_006a0cd0 / FUN_006a0d30 / FUN_006a0d90
```

2016 data: `StateMob.shn` 6 rows (the Cracker bosses: `B_CrackerGuardian` / `B_CrackerLooter` buff `B_CrackerHumar`
with `StaCrackerWCUpRate` / `StaCrackerACUpRate` strength 1, the `BH_` versions with strength 2; `BH_Helga` /
`BH_HelgaBall` buff `BH_KaraTemplerAC` / `…MR` with `StaMobACPlus` / `StaMobMRPlus`); `MobAutoAction.shn` 4 rows (the same
guardians and looters put `StaCrackerWCDownRate` / `StaCrackerACDownRate` on every attacker within 1600 units, rate
1000 ‰ = always, Target 15 `TARGET_ATTACKME`); `MobAbStateDropSetting.shn` 6 rows (§8.9). So the Cracker fight is:
kill the guardian and looter first, or the boss keeps its buffs and every hit on them debuffs the hitter.

Container boilerplate (no logic): the `std::_Tree` / `_Tree_val` / iterator instances of both sets (`_Max`, `_Min`,
`operator++` / `--`, `_Lrotate`, `_Rrotate`, `_Insert`, `_Buynode`, `erase` ×2, `_Erase`, `_Linsert`, `find`, `clear`;
`ServentBossTable` set: FUN_005d2080, FUN_005d20a0, FUN_005d2100, FUN_005d2460, FUN_005d3120, FUN_005d3180, FUN_005d3310,
FUN_005d3770, FUN_005d3bf0, FUN_005d4090, FUN_005d4110, FUN_005d42d0, FUN_005d43b0, FUN_005d4ee0; `MobAutomaticAction`
set: FUN_005d20c0, FUN_005d20e0, FUN_005d2150, FUN_005d24c0, FUN_005d31e0, FUN_005d3240, FUN_005d3540, FUN_005d37f0,
FUN_005d3e40, FUN_005d40d0, FUN_005d41f0, FUN_005d4340, FUN_005d4400, FUN_005d4f80) and the `vector<MobAbstateCheckAtDead>`
helpers (`_Uninit_move` FUN_005d55f0, `erase` FUN_005d56a0, `reserve` FUN_005d5710, `_Reserve` FUN_005d5820,
`push_back` FUN_005d58a0).

**Boss detector item** (`UseEffect::UseItemBossMobDetect`, singleton `ui_BossMobDetect` DAT_0086e9f4, initializer
FUN_00699240 / atexit FUN_0069f650; the item-use frame is Z04 §6):

```pseudo
UseEffect::UseItemBossMobDetect::uib_DirectUse(u, player, slot, item) → 1    @ FUN_00599b20
    so_AllInMap(player, AxialListBossFind, 0)                         # ctor FUN_00428190
    player.so_ply_ItemUseResultPacket(0x700, 9)                       # vt 0x91c → 0x3016 success, invenType 9 (Z04 §6.1)
AxialListBossFind::ali_Work(walker, o, dist) → 1                       @ FUN_00429080
    if o's mode (vt 0x484) ≠ 3 (not dead) and o's data entry (vt 0x70c) has MobInfo.GradeType == MGT_BOSS (2):
        so_AllInMap(o, ShineObject::so_BroadcastBriefInfo FUN_0057acd0, 0)   # o.vt[0x4c8] so_SendMyBriefInfo to every object of the map
```

Every living boss of the map sends its brief info (its appear packet, §5.3 / §9.6) to every player of the map, so
the client learns bosses outside its sight; nothing removes them later except the normal sight updates (§9.6).

### 27.7 Answers and open points

- §21's open point "what `arg` is": the film's cell index (§27.3). §15.9 "how often a film steps": once per main-loop
  pass (§27.3). §22's "how films use the book type": §27.2. §26's "`cc_PlayFilm` and the film argument": `InitFlag`.
- `Movie::TimeLimit`: `tl_IsActiv` is dead (Z09-B120); `tl_GetTimeLimit_Second` has one caller (`@RestSec`); the
  teleport visitors (`AxialListTeleport`, `…Anywhere`, `…Split`, `AxialListCount2`) are created only by
  `ShineTeleportAll::sa_Step` (§26.4), so Z09-B115 has no other victim.
- Not traced: the 0x1C08 layout a boss sends through `so_BroadcastBriefInfo` to players outside its sight and whether
  the client keeps such a far object (C01 / Z02 §5).

## 28. Sweep additions: map query functions, heal reports, the rest of MiscDataTable, leftovers (part 17a)

`coverage.py` does not apply to Z09 (no scope table). The sweep used its own check instead: every function called
directly by a function this file cites, not cited by any doc (scratch script over `coverage.Bin`, same TINY / HUB
filters). Result before this part: 688 functions / 26 k lines, nearly all owned by other items (player login work, pets,
guild tournament, quests, skills, brief-info exchange, sessions; listed in the Coverage boundary). This section
documents the Z09-owned ones and answers every "→ sweep" leftover of the status file.

### 28.1 Map initialisation and the query functions per map kind

`FieldMap::fm_Init(field, FieldAttr* attr, Name4 regenFile, Name3 mapId)` runs once per map at start-up (from
`FieldContainer::fc_MakeField`, Z01):

```pseudo
FieldMap::fm_Init(f, attr, regenName, mapId)                                    @ FUN_00464bc0
    f.fm_GuildTournamentInform = {seed 0xFF, guildA 0, guildB 0};  f.fm_PKField = 0
    f.fm_MapInfo = MapInfo row of attr.mapidclient (mapdatabox B-tree; unknown → null)
    f.fm_FieldBonus = {fb_Experience 1000, fb_DropRate 1000};  f.fm_KQHandle = −1
    if mapId == rouname: fm_Rou = f                          # the global "Rou" map pointer
    f.fm_MapID = mapId;  f.fm_FieldOption = attr
    if attr.KingdomQuestMap == 2:                            # mini-house interior (Field.txt kind)
        fm_MiniHouseInteriorMap = mapId
        fm_BroadFunc = {AllInMap1/2 = so_AllInMapMiniHouse, AllOfRange1/2 = so_AllOfRangeMiniHouse}
    else:
        fm_BroadFunc = {AllInMap1/2 = so_AllInMapNomal,     AllOfRange1/2 = so_AllOfRangeNomal}
    f.fm_BlockInfo = mbib_Load(mapId, attr.mapidclient, &fm_XSize, &fm_YSize)     (§9.2)
    MobHatchery::mh_Load(mobhatchery, regenName, mapId)                            (§10.3)
    the two sentinels zero / infinite: som_AllocObject(…, 0), placed by vt 0x590 at (0, 0) and (0xFFFFFF, 0xFFFFFF);
        zero gets the default title object (ctz_SetObject(so_DefCharTitle)); cn_MakeLink(zero, infinite) on the
        X and Y lists (SlantedCoordList::CoordedNode::cn_MakeLink @ FUN_00588060)
    five anchors flag[0..4] at (w/10 + i·w/5, h/10 + i·w/5), cn_AppendList on both lists        (§9.6)
    f.fm_Multiflex = new CinemaComplex (0x12e798 bytes; failure: "FieldMap::fm_Init : Memory Leak", ShineExit)
    flag[2].vt[0x670](cc_SetArgument(fm_Multiflex, f, flag[2]))                    # the anchor that runs the films (§12.7, §27)
    if attr.isfreepk: f.fm_PKField = 1
    every MapCluster of mapclustermanager: mc_Regist(cluster, f, attr.mapidclient)  (Z14: instance clusters)
    MobDeadCount::mdc_Init(&f.fm_MobDeadCount);  m_nGuildTournamentMapFlag = 0;  fm_CameraState = CS_NONE
    fm_LuaScript = {null, all seven event names ""}                                (§14.3)
    fm_FieldFlag = {revive item 1, revive skill 1};  fm_ReviveDelaySec = 180;  fm_eLevelType = ILT_MAX
```

The four members of `fm_BroadFunc` (field+0x58) are member-function pointers; `so_AllOfRange` / `so_AllInMap` call
form 1 when the caller passes an `AxialListIterator` object and form 2 when it passes a member function of
`ShineObject` (e.g. `ShineMobileObject::so_Routine` passes `so_ply_Send2WhoTargetMe`):

| Slot | Normal map | Mini-house interior (`KingdomQuestMap` 2) |
|---|---|---|
| AllInMap, iterator | `so_AllInMapNomal` FUN_0054c370 | `so_AllInMapMiniHouse` FUN_00553dd0 |
| AllInMap, member function | `so_AllInMapNomal` FUN_0054be00 | `so_AllInMapMiniHouse` FUN_00553c60 |
| AllOfRange, iterator | `so_AllOfRangeNomal` FUN_0054c900 (§9.6) | `so_AllOfRangeMiniHouse` FUN_00553f60 |
| AllOfRange, member function | `so_AllOfRangeNomal` FUN_0054d360 (same walk as FUN_0054c900) | `so_AllOfRangeMiniHouse` FUN_00554100: **empty**, returns 1 |

```pseudo
guard of every normal walk:
    BroadcastEventPopper()                                                      @ FUN_005496d0
        if g_BroadcastStackPoint < 3: depth += 1, legal          # at most 4 nested walks (depth 0..3)
        else: log, illegal → the walk returns 0 without visiting anybody (the popper's dtor restores the depth)
    if both list neighbours of o resolve to o itself: MapRearrangeObserver.mro_Set("Unlinked object") @ FUN_00462e90; return 0
    so_SlantedListChecker.lcs_ListCheck[depth] += 1                # a new visit stamp for this walk
    per visited object: so_SlantedListCheck(obj)                                @ FUN_0054a500
        if obj.listcheck[depth] == the stamp: log, return 0        # already visited in this walk (damaged list)
        obj.listcheck[depth] = stamp; return 1

so_AllInMapNomal(o, work, includeSelf)                                          @ FUN_0054c370 (iterator) / FUN_0054be00
    walk o's Y list towards smaller y, then towards larger y (whole map, ≤ 10000 steps per direction, "Too many loop")
        first direction: a repeat visit ends the walk (return 0)
        a node whose neighbour is itself: o.vt[0x8a0](1), mro_Set("AllInMap2" / "AllInMap3"), fm_Relink (§9.6)
        same layer (LayerRegNumberUnion equal) or either object's nViewType ≠ 0: work(o, other, so_DistanceSquar(o, other))
    includeSelf: return work(o, o, 0);  else return 1

so_AllInMapMiniHouse(o, work, includeSelf)                                      @ FUN_00553dd0 / FUN_00553c60
    if o.vt[0x130]() (ShinePlayer::so_ply_MH_GetActiveMH: o is inside a house):
        h = som_GetObject(o.vt[0x138]())   (so_ply_MH_GetMyHandle; missing → return 0)
        for i = 5 − h.so_mh_GetInnerGMCount() … h.so_mh_GetInnerPlayerCount() − 1:      # vt 0x70 / 0x6c
            m = h.so_mh_GetMemberPlayer(i)  (vt 0x68: smh_Info.pEnterPlayerIndex[i])
            if m and m ≠ o: work(o, m, dist²)
    includeSelf: return work(o, o, 0);  else return 1
so_AllOfRangeMiniHouse(o, stamp, centre, range, cone, work, includeSelf, skip)  @ FUN_00553f60
    the same member loop, work only when dist²(member, centre) ≤ range² (no layer, cone or skip test)
so_AllOfRangeMiniHouse(member-function form)                                    @ FUN_00554100
    return 1                                                       # visits nobody, not even o (original bug)
```

(original bug) Z09-B121: the member-function form of the mini-house range query (FUN_00554100) is an empty stub: on a
mini-house map every range call made with a member function (e.g. `so_ply_Send2WhoTargetMe` in the mobile routine)
reaches nobody, and its `includeSelf` is ignored, while the iterator form walks the house members.

(original bug) Z09-B122: the mini-house member walk runs from slot `5 − EnterGMCount` up to `EnterPlayerCount − 1`, but
`so_mh_Enter` FUN_00543cb0 stores players from slot 0 upwards and GMs downwards from slot 4 (`pEnterPlayerIndex[4 − n]`).
With no GM inside and at most 5 players the loop body never runs: map-wide and range walks on a mini-house map reach
only the caller (`includeSelf`). With GMs, only the slots `5 − GMs … players − 1` are visited (some players or GMs
are skipped). The likely intent is "every occupied member slot". (How the two groups share the 104 slots is Z13's.)

### 28.2 Heal reports: how mobs learn who healed their enemy (`SpyNet`)

Every mobile object has a `SpyNet::EspionageAgent smo_Spy` (+0xeb0, 0x108 bytes: `SecretReport ea_SecretReport[16]`
{`sr_Type`, union `sr_Report`}, `BitANDInt ea_Pointer` +0x100 {value, mask 0xf}); `so_SpyAgent` (vt 0x480) returns it
(`ShineMobileObject::so_SpyAgent` FUN_005555a0); other objects return the shared static `ShineObject::so_spy`
(`ShineObject::so_SpyAgent` FUN_00554f30, static initialiser FUN_00698540). Report kinds `SecretReportType`
*(pdb2016)*: `SRT_EOR` 0 (end of reports), `SRT_GETHEAL` 1, `SRT_SOMEONE_GIVE_ABSTATE` 2, `SRT_SOMEONE_REMOVE_ABSTATE` 3,
`SRT_VANISH_ABSTATE` 4. Only `SRT_GETHEAL` is ever written.

```pseudo
EspionageAgent ctor                                                             @ FUN_0058a5f0
    ea_Pointer = {0, mask 0xf};  all 16 reports = {SRT_GETHEAL, healer null, healingup −1, aggrorate 1000}   # no EOR (original bug)
ea_Clear(agent): agent.ea_SecretReport[ea_Pointer].sr_Type = SRT_EOR           @ FUN_0043c610
    (only caller: ShineMover::so_smv_SummonMover, Z13)

writer: a heal lands (SkillEffectApply::SkillDamageSender::sds_TemplateStore @ FUN_005803c0, Z03)
    a = target.so_SpyAgent();  a.report[a.ea_Pointer] = {SRT_GETHEAL, healer = caster, healingup = HP actually healed, aggrorate = arg 4}
    a.ea_Pointer = (a.ea_Pointer + 1) & 0xf;  a.report[a.ea_Pointer].sr_Type = SRT_EOR

aggro entry created (MobTargetBout::mts_AppendAggroPoint @ FUN_004ad9a0, §6.2):
    entry.mts_EnemyAnalyzer.io_Pointer = target.so_SpyAgent().ea_Pointer   # read only reports written from now on

each analysis pass, per aggro entry still in time and range (MobTarget_EnemyAnalysis::lid_Call @ FUN_004ac800, §6.2):
    IntelligenceOffice::io_ReadReport(&entry.mts_EnemyAnalyzer, mob, target.so_SpyAgent())   @ FUN_0058a6d0
        up to 16 times: r = agent.report[io_Pointer & 0xf]
            SRT_EOR: return                                          # stop at the end mark (next pass resumes here)
            SRT_GETHEAL / GIVE / REMOVE / VANISH: office vt 4 / 8 / 0xc / 0x10 (mob, r)
            io_Pointer = (io_Pointer + 1) & 0xf
        no EOR within 16: assert "SpyNet::IntelligenceOffice::io_ReadReport : Cannot found EOR(End of Report)" (log)
IntelligenceOffice4Mob (ctor FUN_0058a630, dtor FUN_0058a650):
    vt 4 io_SRT_GETHEAL(mob, r): mob.so_mob_AppendAggro(r.healer, r.aggrorate × r.healingup / 1000)   @ FUN_0058a660
    vt 8 / 0xc / 0x10: folded no-op FUN_00509900
```

So a healer gets aggro from every mob that has the healed player on its aggro list (§6.2's family sharing applies, the
call is the normal vt 0x700). A ring of 16: more than 15 heals on one target between two passes of a mob overwrite
reports the mob has not read yet.

(original bug) Z09-B123: the agent constructor fills all 16 slots with `SRT_GETHEAL` and writes no `SRT_EOR`. For a
target that was never healed, every analysis pass of every mob that has it on its list reads 16 reports with a null
healer (`so_mob_AppendAggro` returns on null, so no aggro changes) and then logs the "Cannot found EOR" assert:
pure log spam and wasted work, until the first heal writes an end mark. Likely intent: `ea_Clear` in the constructor.

### 28.3 The rest of `World/MiscDataTable.txt`: Polymorph, Neutralization, AbStateReset, ExpandSkill

`MiscDataTable::mdt_Load` FUN_004a82d0 reads, after `SkillBreedMob` (§13.3), four more tables (each with a `Serial` byte
first and a `CheckSum` byte last that must be equal, else "<loader> : Checksum error" + ShineExit). The table object
(`miscdatatable`, ctor FUN_004a39a0) also holds the defaults `mdt_DefSkill` (no polymorph 0xFFFF, no neutralization,
`ETO_NONE`, …) and `mdt_DefAbState` (all reset conditions 0, `EW_NONE` / `EC_NONE`).

| Table (2016 rows) | Columns | Loader | Stored in |
|---|---|---|---|
| `Polymorph` (1: `Metamorphosis01` → `Metamorphosis_bird`) | Skill, MobIndex, CanMove, CanAttack | `mdt_Polymorph` @ FUN_004a63e0 | skill row (`mdt_SkillBufferAlloc`, §13.3): `mds_Polymorph` = mob ID (unknown name → 0xFFFF, silently), `mds_PolymorphAction.Move` / `.Attack` bits |
| `Neutralization` (4) | Skill, Weapon, Shield, Body, Leg (per-mille words) | `mdt_Neutralization` @ FUN_004a64c0 | skill row: `mds_IsThereNeutralizationItem` = 1, `mds_NeutralizationItemArray[30]` (equip slot → rate): Weapon → [12], Shield → [10], Body → [7], Leg → [19] |
| `AbStateReset` (7: `StaBuckler`, `StaNeglect`, `StaHide`, `StaMesmerize`, `StaEntrapHide`, `StaGTIConfusion`, `StaGTIHide`) | AbState, Run, Walk, Attack, Attacked (bytes), EquipWhere (`-` / `LeftHand`), EquipClass (`-` / `Shield`) | `mdt_AbStateReset` @ FUN_004a6580 | `MiscData_AbState` (0xc bytes, ≤ 50, sorted by abstate ID; `mdt_AbStateBufferAlloc` @ FUN_004a3f50: unknown abstate → assert "Imvalid skill name" (copied text) + ShineExit, 51st → "Too many Data" + ShineExit): `mdas_ResetCondition {run, walk, attack, attacked}`, `mdas_ResetEquipment {eqwhere, eqclass}`; other EquipWhere / EquipClass words: assert only (the field keeps its default); EquipWhere set with EquipClass `-`: "Invalis match" + ShineExit |
| `ExpandSkill` (4: `PowerBenTear`, `PowerWeaponBlast`, `FinalSwordForce`, `WeaponBlast`) | Skill, Condition (`Stun` / `Slow` / `ACMRMinus`), Dmg (word), AbState (name or `-`), Critical (word) | `mdt_StateCondition` @ FUN_004a3550 | `MiscData_VarifyByAbstate` array (0x14 bytes, ≤ 100, sorted by skill ID after loading): `{mdvba_Skill, mdvba_Condition (AbnormalStateAttr STUN / SLOW / ACMRMINUS; other words: "Invalid Condition" + ShineExit), mdvba_DamageRate = Dmg, mdvba_NewState (unknown or `-` → MAX_ABSTATEINDEX), mdvba_Crirate = Critical}` |

```pseudo
mdt_StateCondition, per record:
    if Skill itself is a skill name: store one row for it, record counter += 1
    for name in MapSubString(Skill + "01" … Skill + "99")       # MapSubString ctor FUN_00461be0, mss_Home FUN_00461c20, mss_Next FUN_00461c60
        stop at the first name that is not a skill; else store a row with the same values      # every level of the skill
    record counter += 1
```

(original bug) Z09-B124: when the `Skill` word of an `ExpandSkill` record is itself a skill name, the record counter
is advanced twice, so the next record is never read. Latent in 2016: none of the four base names is a skill (the
skills are `PowerBenTear01…`, `FinalSwordForce01…`), so only the level expansion stores rows.

Who uses the tables (the consumers are Z03's skill and abstate code; listed here so the data has a meaning):

```pseudo
skill blast damage setup (ShineMobileObject::smo_SkillBlast, Z03) → MiscDataTable::mdt_ArgumentLoad(arg)   @ FUN_004a6110
    row = ExpandSkill row of the skill's ActiveSkill ID (bsearch); none → return
    if arg.def.so_smo_AbnormalStateAttribute(row.Condition) (vt 0xa64: the target has an abstate of that attribute):
        arg.damagerate = row.DamageRate;  arg.crirateadd = row.Crirate
        if row.NewState valid and arg.def.so_AbnormalState_Set(att, NewState, strength 1, …, g_Now, …, kind 6) (vt 0x638):
            set the abstate bit, inform (vt 0x3f0) with the sub-state's KeepTime, broadcast the set

after each blast hit (SkillBlastEffect::sbe_BlastObject / sbe_BlastLocate, Z03) → mdt_PostSkillBlast(caster, target, skillId, xy)   @ FUN_004a3a90
    row = skill row (default when none)
    if row.mds_Polymorph ≠ 0xFFFF: caster.vt[0xeb0](row)          # players: smo_ply_Polymorph FUN_004a5830; others: folded no-op
    if row.mds_IsThereNeutralizationItem:
        for slot 0..29: if well512(1000) < rate[slot] − 1000 + setitemskilleffect[SET_PROBABILITYRATE]:
            slot 10 → target.so_ply_ReinforceRemoveShield (vt 0x9a4);  slot 12 → …RemoveWeapon (vt 0x9a0);
            else → …RemoveEquip(slot) (vt 0x9a8)                    # players only; mobs: folded no-ops
    caster.smo_SoulManage(target, skill) (vt 0xf34, Z03)

ShinePlayer::smo_ply_Polymorph(p, row)                                          @ FUN_004a5830
    row == null (end): if abstate 0x123 is set (vt 0x3e4): reset it (vt 0x650);  mob = 0xFFFF
    else: mob = row.mds_Polymorph; set abstate 0x123 (StaImmortal's row) for 1,000,000,000 ms, kind 9
    if brief.polymorph == 0xFFFF or p.sp_nPolymorphAbstateIndex == MAX_ABSTATEINDEX:
        brief.polymorph = mob;  0x10AF NC_CHAR_POLYMORPH_CMD {u16 handle, u16 mob, u32 0x318} to the sight range incl. p

abstate element set (AbstateElementInObject::aeo_Set, Z03) keeps aeo_MiscData = mdt_FindAbStateAlways(id)   @ FUN_004a2ef0 (default row when none)
    aeo_Run / aeo_Walk / aeo_Attack / aeo_Attacked                              @ FUN_004a41c0 / FUN_004a4230 / FUN_004a42a0 / FUN_004a4310
        if the row's flag is set: aeo_Tick.terminate = g_Now               # the abstate ends now
        (called from the run / walk handlers, bash start, damage-over-time and every so_DamagedBy, Z02 / Z03)
    aeo_ItemChange(inventory)                                                   @ FUN_004a4380 (via ListIteratorAbstateEquip::lid_Call FUN_004a4810)
        EW_LEFTHAND rows: if the left-hand item (equip slot 10) is missing from ItemInfo, or the row wants EC_SHIELD and
        the item class is not ITEMCLASS_SHIELD: terminate now          # StaBuckler ends when the shield comes off
```

`mds_PolymorphAction` (CanMove / CanAttack) is written by the loader and never read: those two columns have no effect.
The neutralization chance uses `setitemskilleffect`, a global scratch buffer of set-item effects (as in Z09-B30): its
`SET_PROBABILITYRATE` value at that moment decides how much of the table rate applies *(inferred: with 1000 there the
chance is rate / 1000)*.

### 28.4 Answers to the leftovers marked "sweep"

- **Selector slot 0x3c** (§6.1): its official name is `IsNoAttackAbstate` *(pdb2016)* (`MobTargetAggresive` FUN_004a9b90,
  `MobTargetAggresiveALL` FUN_004a9cb0). No method of any `MobTarget*` class and no tactic calls slot 0x3c (`rg` over
  the PDB export); only `IsNoTargetAbstate` (FUN_004a9be0) is called, from `MobTargetAggresive::ali_Work`. The slot is
  dead in 2016; the tactics test abstates 291 / 499 directly (§7.3).
- **`PceHPRcv*` / `AtkHPRcv*`** (MobInfoServer +0x48…+0x4e): no member access anywhere in the PDB export (where every
  MobInfoServer access is typed); the tactics do not read them either. Mob regeneration is only `sm_DuringRecover`
  (§6.5). (§5.1's list of unread columns stands.)
- **Ring DAT_14dc2120** (Wander `maw_ReturnTick`, §7.2): it is `RandomRing(10)` (base DAT_14d720d0 + 10 × 0x8008), values
  0…9, so an idle wandering mob returns home every 55…64 s.
- **The 30-s event** next to `EventMobRegen`: `ZoneServer_zs_start_open` FUN_005b6640 reserves `eventheartping`
  (`EventHeartPing`, DAT_0086fae8) every 300 tenths; its `erb_happen` is the folded no-op FUN_00417480, so it does
  nothing in 2016. The same start step loads `EnchantSocketRate.shn`, sets the NPCs (`nm_SetNPC`, §5.9) and starts every
  map's Lua script (`FieldMap::fm_StartScript`, §14.2).
- **Callers of vt 0xc98** (`SetPositionWithSight`, §9.6): only the mover passenger moves `ShineMover::smv_PassengerMove`
  FUN_0055efe0 and `ShineMover::so_smv_GetOn` FUN_0055f380 (Z13). **FUN_00428730** (vt 0x6d8 caller) is
  `AxialListTeleportAnywhere::ali_Work` (§26.4).
- **Field+0x88 selection and mini-house queries** (§9.8): §28.1.
- **SpyNet** (§6.2 "part 4"): §28.2.
- **MiscDataTable skill side tables** (part 8b leftover): §28.3; the consumers stay Z03's.
- **`Item_ForcedUpgrade`** FUN_0053c510 (called by the drop roll, §11.2): the upgrade itself is item code (Z04).
- **Wedding partner summon**: the skill `ss_SummonMate` at cast end in `ShineMobileObject::so_Routine` sends
  `ZoneRingPacketSummonPartner::zrpb_Request` FUN_005a83b0 (local partner → level / map checks; else zone ring 0x10AA) —
  Z13 (wedding), not world simulation.

### 28.5 Small helpers reached from documented code

Constructors, accessors and loader plumbing; listed so the sweep can show them as read.

| Function | What it does |
|---|---|
| `BinaryDataBox<T>::bdb_ReadData` for MobInfo FUN_00641110, MobInfoServer FUN_006411d0, MobWeapon FUN_00641290, MobSpecies FUN_00641350, QuestSpecies FUN_00641410, MobKillAnnounce FUN_006414d0, ItemDropLog FUN_00641580, MobLifeTime FUN_00641630, AbStateSaveTypeInfo FUN_006416e0, MobRegenAni FUN_00641790, GroupAbState FUN_00641830 (all from `MobDataBox::mdb_Load`, §5.1), MobResist FUN_00644da0, MobAutoAction FUN_005d2320, MobAbStateDropSetting FUN_005d2270, StateMob FUN_005d21b0 (§27.6) | `CDataReader::Read(file, rowSize, …)`; failure: "BinaryDataBox<T>::bdb_ReadData : readfail" + ShineExit |
| `MobResistTable::operator[](name)` FUN_00644ec0 / `operator[](index)` FUN_00644e90 | name → row index (linear search; unknown → "MobResistTable::operator [] : Invalid index" + ShineExit); index → row (out of range → null) |
| `MobDataBox::GetGroupAbstateLoweriter` FUN_006425b0 / `…Upperiter` FUN_006425f0, `MobDataBox::operator[]` FUN_004190b0, `mdb_iter_Get` FUN_004a84d0 | lower / upper bound in the GroupAbState multimap (the regen abstates of §5.3); mob row by ID; row by position |
| `TickTimer::TickTimer` FUN_00591f80, `Enable` FUN_00591fd0, `CheckUpdateEvent_ClockWatch` FUN_00592050 | `{m_CurDelayTime, m_DelayTime, m_bEnable, m_PrevCheckTime}`; enable resets the accumulator; the check adds `now − prev` and fires (subtracting `m_DelayTime`) when the sum exceeds `m_DelayTime` (mob lifetime §5.2, dice §11.6) |
| `FieldMap::fm_IsStreight` FUN_004600e0 | straight-line test by bisection: true below 5 units; false if the midpoint is a move block; else both halves (§9.5) |
| `DirectDistanceTable::ddt_ShineRadianDiff` FUN_00460050 | difference of two directions in 2° units folded to 0…90 with a turn sign (±1) (§7.3 TurnSpeed) |
| `DropLoc::SameDistanceCluster::sdc_Init` FUN_00460790, `ShineRadian::sr_degree2sr` FUN_00579180 | allocate n zeroed `{dx1024, dy1024}` offsets; degrees → Shine radian (§11.7) |
| `HitMeList::EnemyList::EnemyList` FUN_00482ca0, `ShineDynamicCast<ShineServant>` FUN_00481ea0, `ShineDynamicCast<ShineMob>` FUN_00479460, `ListTraveler<MobTargetStruct>::operator*` FUN_004a9d90 | containers and RTTI casts of §6 |
| `MobAttackSequence::SkillChangeList::SkillChangeList` FUN_004a8820, `SkillChange::sc_Store` FUN_004a8520 | the skill-change list of §7.6 |
| `Navigator::NaviPoint::NaviPoint` FUN_005c87e0, `MobRegenStruct::RegenMobStruct::operator=` FUN_004e75b0 | path point (§9.5); regen record copy (§10.8) |
| `FieldMap::LuaField::LuaField` FUN_00464170, `~LuaField` FUN_004641e0, `operator=` FUN_004646c0 | the map script names of §14.3 |
| `BelongDiceTable::BelongDiceTable` FUN_005b1620, `AxialListMobKillLog` ctor FUN_00428340, `AxialListObjectClear` ctor / dtor FUN_004957f0 / FUN_004958a0, `AxialListMobCounter` dtor FUN_004e2cf0, `AxialListAreaObjectList` dtor FUN_0042a3f0, `AxialListRevival` dtor FUN_0042a0a0, `AxialListSetAbstateInArea` ctor FUN_004c1bd0, `AxialListMobStateSet` dtor FUN_004eb8c0 | visitor objects: dice table (§11.1), mob-kill log on entering battle (§6.5 vt 0x588, GameLog 910 in D05), `fm_ClearObject` (§24.8), area / map counters (§15.7), Lua area functions (§17, §18), boss buffs (§8.9) |
| Pine node ctors `ShineEffectLocate` FUN_004e8b00, `ShineEffectObject` FUN_004e8ae0, `ShineDoorClose` FUN_004e8740, `ShineDoorOpen` FUN_004e8720, `ShineDoorBuild` FUN_004e8660, `ShineInterruptErase` FUN_004e8600, `ShineInterruptClear` FUN_004e85c0 | `OtherStatement(keyword, …)` constructors registered by `StatementList` (§21.2) |
| `SlantedCoordList::CoordedNode::cn_MakeLink` FUN_00588060, `ShineObject::so_Reset_SlantedList` FUN_00554370, `MapRearrangeObserver::mro_Set` FUN_00462e90 | sentinel link (§28.1), node reset in `fm_Relink`, list-damage reason record (§9.6) |

### 28.6 `OptionReader`: the `#`-command text tables

Every text table of the zone goes through one parser, `OptionReader` *(pdb2016)*. Callers of `or_Read`: in this file
`MobHatchery::mh_Load`, `MobRoamingSet::mrs_Load`, `KQRegenTable::kqrt_Load`, `MobAttackSequence::mas_Load`,
`MobChatManager::mcm_Load`, `DropIndexCluster::dic_Load`, `MagicContainer::mc_Load`, `MiscDataTable::mdt_Load`,
`NPCManager::nm_Load`, the three `NPCAction::Util::loadFromOptionReader<…>`, `ScenarioBookShelf::sbs_LoadScripts`,
`KQScriptManager::kqsm_Load`, `ShineScript::ss_Load`; elsewhere `CharClass::cc_Load`, `ShineCommonParameter::scp_Load`,
`DamageTable::dt_Load`, `SoulDamageContainer::sdc_Load`, `FieldContainer::fc_Load`, `SubLayerInteractLoader::slil_Load`,
`ItemUseFunction::iuf_Load`, `NPCItemListTable::nilt_ReadTable`, `RecallPointTable::rpt_Load`. No other item documents
the parser (Z01's loader table only names the files), so its format is here.

Objects *(pdb2016)*: `OptionReader` 0x10854 = `{TokenArgument or_Argument +0 (error message, delimiter list, exchange
list, comment char, brace pair, ignore list), List<ORTable> or_TableList +0x9c, ORTable or_TableArray[32] +0xb4,
ORTable* or_CurrentTable +0x10834, std::string m_strFileName +0x10838}` (ctor `OptionReader::OptionReader` FUN_00646a30:
32 empty tables in the free list). `ORTable` 0x83c = `{ORToken ort_TableName (20 bytes), int ort_RecordLength,
ORColumnHeaderList ort_HeaderList (512 column pointers), List<ORRecord> ort_DataRecord +0x820 (count u16 +0x834),
ORKeyList* ort_PrimaryKey +0x838}`. `ORRecord` = `{ORField* orr_FieldArray[512], char* orr_Buffer, int orr_Pointer}`:
one packed buffer per record, fields in column order.

```
OptionReader::or_Read(reader, path) -> bool                                   @ FUN_00646bf0
    fopen(path, "r"); fails: error "File not found", return false
    ok = true
    loop while ok:
        cmd = ORTokenReader::ortr_ReadCommand(&tr, &token)                     @ FUN_0064dcf0
            # reads the next line that is not blank (blank = delimiters, control chars < 0x20, or a line whose first
            # non-blank char is the comment char: the rest of that line is dropped, ortr_SkipBlank FUN_0064d700);
            # its first non-blank char must be '#' (else error "# comment expected" → fail); the word after '#' is read
            # up to the next delimiter, cut to 20 bytes and lowercased (ORToken::ort_ToLower) → commands are case-blind
            # end of file → error "Unexpected EOF" → fail (a file must end with `#end`)
        switch word:
            "comment"    : comment char ← next char                          ORComment::orc_Exec    @ FUN_0064de50
            "brace"      : open / close chars of string lengths (2 chars)    ORBrace::orb_Exec      @ FUN_0064de80
            "ignore"     : add a char that is dropped from values (≤ 32)     ORDelimiter::ord_Exec  @ FUN_0064dd90
            "delimiter"  : add a field separator char (≤ 32, "Too many delimiters")          (same function)
            "exchange"   : pair (from, to): `from` is replaced by `to` in values (≤ 32, "Too many exchange")
                                                                             ORExchange::ore_Exec   @ FUN_0064dde0
            "table"      : or_CurrentTable ← next free table (32 max, "Too many tables"); name = next value, strncpy 20
                                                                             or_ExecTable           @ FUN_00646100
            "columntype" : ORTable::ort_ReadColumnHeader                       @ FUN_00645c20  (no table: "ColumnHeader without table")
                           per value (lowercased): "index" 20-byte key, "string" + `<brace>n<brace>` n bytes (n ≥ 1; errors
                           "String need length", "Error in string length", "String length must be bigger then 0",
                           "Brace must be closed in same line"; ORColumnHeaderString::ortr_SetLength FUN_00647160), "byte" 1,
                           "word" 2, "dwrd" / "dword" 4; anything else → "Undefined column type"; ≤ 512 columns
                           (ORColumnHeaderList::orchl_AllocObject FUN_00647260, "Too many columns or memory leak");
                           record length = sum of the lengths; no column → "At least one column needed"
            "columnname" : one name per column (ort_ReadColumnName FUN_006477a0), then end of line ("Extra data exist",
                           ortr_isEOL FUN_0064da70)                          or_ExecColumnName      @ FUN_00645f20
            "record"     : one record of the current table                   or_ExecRecord          @ FUN_006482c0
            "recordin"   : first value = table name (any table already declared; "#recordin has no table name",
                           "Unknown table name"), then the record            or_ExecRecordIn        @ FUN_006481c0
                ORTable::ort_ReadData                                                            @ FUN_006480a0
                    new record ("Too many records"), buffer of ort_RecordLength bytes; each column reads its value:
                    index / string: ortr_ReadString (index: strncpy 20, ORFieldIndex::orf_Read FUN_00653a70;
                    string: zero-filled then strncpy n, ORFieldString::orf_Read FUN_00653ed0); byte / word / dwrd:
                    ortr_ReadNumber (byte > 255 → "Cannot read byte data", ORFieldByte::orf_Read FUN_00653b60;
                    ORFieldDwrd::orf_Read FUN_00653c80); then end of line
            "end"        : stop
            anything else: error "Undefined command", stop      # ok is still true → or_Read returns true (original bug, Z09-B125)
    fclose; return ok

ORTokenReader::ortr_ReadString(tr, braceMode)                                   @ FUN_0064db40
    skip blanks; value = chars up to the next delimiter (≤ 2047 chars); `ignore` chars dropped; `exchange` applied;
    in BIS_EXCLUDEBRACE mode (names, commands) a brace char ends the value and `\d…` / `\o…` / `\x…` escapes give one
    byte (decimal / octal / hex, > 255 → "Invalid character"); null at end of line
ORTokenReader::ortr_ReadNumber(tr, &ok)                                         @ FUN_0064d9f0
    '-' → −(number); "0x…" hex; leading '0' octal; else decimal
```

Look-ups *(pdb2016)*, all by table name (20-byte compare, the reason for Z09-B9):

| Function | Returns |
|---|---|
| `or_SelectFrom(table, column, value, skip)` FUN_00647c00, int-value form FUN_00648310 (`"%d"`) | buffer of the (skip+1)-th record whose `column` equals `value` (linear, `ORTable::ort_RecordBuffer` FUN_006479b0 with `RecordDataCompareArgument::lid_Call` FUN_006475a0); null if none |
| `or_Select(column, table, keyColumn, keyValue, skip, &type)` FUN_00647cb0, int form FUN_006483d0 | pointer to field `column` of that record and its type (`ORTable::ort_FindData` FUN_006478c0, `TargetColumnFindArgument::lid_Call` FUN_00647080) |
| `or_Select(column, table, key, &type)` FUN_00647b30 | the same through the primary key (bsearch, `ORKeyList::okl_Searching` FUN_006539d0, `ORRecord::orr_GetFieldData` FUN_00647830); null without a key |
| `or_MakePrimaryKey(table, column)` FUN_00647d70 → `ORTable::ort_MakePrimaryKey` FUN_00647680 | builds a key list of ≤ 1024 `{20-byte key, record}` (`okl_AddKey` FUN_006538d0, `MakePrimaryKey::lid_Call` FUN_00647410) sorted by `qsort` (`okl_Sorting` FUN_006539a0, compare = the five dwords as signed differences, `okl_KeyCompare` FUN_00653930); 0 records or 1024 and more → no key (false). Only `ShineScript::ss_Load` (§22.6) uses keys; the 2016 `Script/*.txt` tables are far below 1024 records |
| `or_SelectCountFrom(table)` FUN_00648460, `or_SelectCount()` FUN_00647e10, `or_SelectFromOrder(table, i)` FUN_00647a60 | record count of a table; number of tables; buffer of the i-th record |

Reader plumbing (read, no further logic): `ORTokenReader` ctor FUN_0064d6d0, `ortr_ReadChar` FUN_0064dab0 (one char or a
`\d` / `\o` / `\x` escape), `ortr_GetDigit` / `ortr_GetOctal` / `ortr_GetHexa` FUN_0064d930 / FUN_0064d8e0 / FUN_0064d980,
`ortr_ReadNumber10` / `…8` / `…16` FUN_0064d800 / FUN_0064d7a0 / FUN_0064d860, `ortr_SetError` FUN_0064d780 (message +
line number), `ORLinebuffer::orlb_LineRead` FUN_0064d520 (one `fgets` line) / `orlb_FGetc` FUN_0064d5b0,
`ORDelimiter::operator[]` FUN_0064d5f0 (is a delimiter) and ctor FUN_0064d5e0, `ORBrace` ctor / `orb_IsOpen` / `orb_IsClose`
FUN_0064d650 / FUN_0064d660 / FUN_0064d670, `ORErrorMessage` ctor / `orem_Clear` / `operator=` FUN_0064dec0 / FUN_0064d690 /
FUN_0064d6b0, `ORToken::ort_ToLower` FUN_0064d460, `ort_GetString` FUN_0064d4f0, `ort_IsNull` FUN_0064d4e0, ctor
FUN_00418e90, `operator=` FUN_00401030, `ORTable` ctor / dtor FUN_00646950 / FUN_006462f0,
`ORColumnHeaderList::orchl_4AllInList` FUN_006473d0, `ORRecord::orr_MakeBuffer` FUN_00653d60 / `orr_GetBuffer` FUN_00653d50.

The 2016 files use only `#table`, `#columntype`, `#columnname`, `#record`, `#recordin`, `#ignore`, `#exchange`,
`#delimiter`, `#end` (any case; counted over `World/*.txt`), so Z09-B125 is latent there.

### 28.7 `CFindWay`: the old path finder is dead in 2016

`g_NewBlockRule` (DAT_0084cfb4, §7.1) is only read: the 2016 exe has exactly four `cmpb $0x0, 0x84cfb4` and no write
(objdump), and the PDB export has the same four reads. Its three users, `MobActionBackStep::mab_Think` FUN_004ba390,
`MobActionAvoidOverlap::mab_Think` FUN_004ba750 and `MobActionChase::mab_Think` FUN_004bc950, therefore always take the
`Navigator` branch (§9.5). The other branch is dead code: `FieldMap::fm_FindWayInit` FUN_004a9ae0, `CFindWay::SetLoadedData`
FUN_00632450 and `CFindWay::FindWay` FUN_00632ba0 (global `findway`, built at start-up by its dynamic initializer FUN_006967e0
and never used). For completeness, what `FindWay` does: if the end cell is blocked or off the map, `SearchMoveable`
FUN_00632810 moves the end to a free cell near it (none → path = start only); if `LineIntersect` FUN_00632500 finds no
block on the straight line, the path is the end point alone; otherwise a best-first search over a local length map
(`LenMapClear` FUN_006326a0, `LenMapSet` FUN_006327a0; priority = Manhattan distance to the end; at most 0x300 open cells)
keeps the nearest reached cell for an unreachable end. Not traced further because nothing reaches it.

### 28.8 Methods of the Z09 classes reached only through vtables

The call-graph check of part 17a cannot see virtual calls. A per-class pass (every function of a class that this file
owns, i.e. cites more of than any other doc, against every doc) found these; all read in the PDB export.

| Function | What it does |
|---|---|
| `ShineMob::so_mobile_BattleCamp` FUN_00556460 | the mob form of vt 0x8cc (§13.3 lists the servant form): `sm_MobIsPlayerSide` (+0x2548) or, when < 0, `MobInfo.IsPlayerSide` (+0x67): 0 / 3 → `BC_MOB` 1, 1 / 2 → `BC_CHAR` 2, other → `BC_NONE` 0 (jump tables read in objdump) |
| `ShineMob::sm_IsPlayerSide` FUN_00556be0, `so_mob_SetIsPlayerSide` FUN_004aa7a0 | same override / table value (vt 0xf68); the setter is a vt slot with no caller in 2016 (so +0x2548 stays −1 and the table decides) |
| `ShineMob::so_mob_CanBeAttackedByPlayer` FUN_004a5bc0 | `!so_IsAlliance(player)` (vt 0xe60) |
| `ShineMob::so_GainHP` FUN_00556a00 (vt 0x504), `so_GainSP` FUN_00556980 (vt 0x4fc), `so_LostSP` FUN_00556950 (vt 0x4f8), `smo_ZeroHP` FUN_005569c0 | add HP / SP and cap; SP is capped at `so_MaxSP` (vt 0x4f4), but **HP is capped at `so_GetHP` (vt 0x4e8, the current HP) instead of `so_MaxHP` (vt 0x4f0)**, so the cap never applies and a mob's HP can pass its maximum (original bug, Z09-B126; objdump confirms the slot). Only caller of vt 0x504: the item action `RecoverTypeEffect::_execute` FUN_005cfc70 (recover types 0 / 1), i.e. latent unless an item action heals a mob. `so_LostSP` subtracts or sets 0 |
| `ShineMob::sm_IsUseSkill(skill)` FUN_0055e530 | the skill is one of the mob's weapon skills (weapon slots of §7.4); caller `GuildTournamentSystem::CreateItemEffect` (Z16) |
| `ShineMob::so_mob_SkillParameterSet_WeaponIndex(i)` FUN_0055e6d0 | `sm_PrepareWeapon` with weapon row i's skill parameters (vt 0xc40); caller `ShineMagicField::smfm_MagicFieldDamage` (§12.5, the field owner's current weapon) |
| `ShineMob::so_mob_IsNPC` FUN_00556c70 | `MobInfo.IsNPC == 1` or `MobInfo.Type == MT_NPC` (6) |
| `ShineMob::so_FillBriefInformation` FUN_00556570, `ShineBandit::so_FillBriefInformation` FUN_00556f30, `ShineBandit::so_GetCharBriefInfo` FUN_00556ec0, `ShineBandit::so_SendMyBriefInfo` FUN_00556e50 | copy of the 0x95-byte 0x1C08 REGENMOB brief; the bandit's character-shaped brief (`BriefInformationCharacter`, the 0x1C06 LOGINCHARACTER payload, §5.2 / §5.10): sent through the receiver's game stream, then vt 0xa10 |
| `ShineMob::so_RemakeHandle` FUN_00556a40, `ShineNPC::so_RemakeHandle` FUN_00557c70, `ShineBandit::so_RemakeHandle` FUN_00556ed0 | handle from a pool index (mob: index ≥ 8000 asserts; NPC: 0x42BC + index, index > 255 asserts; §15.3 pools) |
| `ShineMob::so_FreeFromList` FUN_00554280 | unlinks the family ring (§10.5) and both coordinate lists; asserts "ShineObjectList::som_FreeObject : one of SlantedList is removed" if only one list was linked |
| `ShineMob::smo_LoginAfterLogout` FUN_0055d9b0, `so_relink` FUN_00566ea0, `ShineDropItem::so_relink` FUN_00566e80, `ShineMob::sm_BriefLocateSet` FUN_004b1090 | base re-login + restart the roaming interval (`MobRoamingPoint::mrp_Start`); `fm_MoveCenter` re-link (§28.1); login location ← brief coordinate |
| `ShineMob::so_GetTargetInfo(o)` FUN_00566900, `so_Mob_SetSendTagetInfo(flag)` FUN_0042ac70, `so_IsTarget` FUN_0042acb0, `so_GetTargetObject` FUN_0042ac60 | target broadcast (vt 0xa00, §6.5) when `o` is the tactic's target; the "send target info" dirty flag is set when the target or the flag changes |
| `ShineMob::so_mobile_IsImmortal` FUN_0042b010 | abstate test 198 (vt 0x3e4) |
| `ShineMob::so_mob_ReturnToRegen` FUN_004abe30 | tactic state ← `Actor::toregion` (go home, §7.2) |
| `ShineMob::so_CanSkillTarget` FUN_00556b20 | `MobInfo.GradeType != MGT_NONE` |
| `ShineMob::so_mob_ChaseRangeSquar` FUN_005564e0, `so_Getabstatebit` FUN_00556a90, `smo_BattleKillScore` FUN_00556b70 | `FollowCha²`; the brief's abstate bits (or the default set when the brief's flag state is set); `MobInfoServer.KQKillPoint` |
| `ShineMob` setters / getters FUN_0054a4e0 / FUN_0054a4d0 (next skill), FUN_00556c30 / FUN_00556c20 (use next skill), FUN_00556c50 / FUN_00556c40 / FUN_0055e6b0 (next roaming wait: `CheckNextRoamingWait` is true until the tick, then clears it), FUN_0055e730 / FUN_0055e740 / FUN_0055e750 (regen animation time / complete, §5.3), FUN_00556ca0 / FUN_00556cc0 (brief `nKQTeamType`), FUN_0054a600 / FUN_004b7110 (`sm_Flag.JustAttacked`), FUN_0055e810 (`so_mob_FindLooter` → `el_FindLooter`, §11.4), FUN_004b7100, FUN_005564c0, FUN_005564d0, FUN_00556620, FUN_005566a0, FUN_00556720, FUN_00556730, FUN_00556830, FUN_005568a0, FUN_00556940, FUN_00556ac0, FUN_0056d940, FUN_00556450 | member accessors (roaming path, regen / last-hit location, object type, body size, data box, race, login location, HP, SP, family list, guild, RTTI) |
| `ShineNPC::so_npc_SetLocation(map, x, y, deg)` FUN_00557cc0, `ShineNPC::so_SetGateBriefInform(map)` FUN_00557bc0 | place the NPC (direction = deg / 2, negative + 180); mark the brief as a gate (+0xe = 1) with a 12-byte destination map name. `so_npc_SetLocation` (vt 0xb4c) has no caller in 2016; `so_SetGateBriefInform` (vt 0x4cc) is called by `NPCRole_Portal::nrb_BriefInformSet` FUN_004c2360 with the portal's link target (portal NPCs, Z02) |
| `ShineNPC::so_TentDistance(xy)` FUN_0058cbf0 | true for NPC mob IDs 5606 (`HouseZonePost`), 5607, 5700 when `xy` is farther than 45 units (distance² > 2025); false for other NPCs. Vt 0x768, asked by `ShineObject::so_TentPoint` FUN_0058d260 (rest / booth / tent rules, Z02 §7, Z06) |
| `NPCManager::nm_FindNPCInfo(handle)` FUN_005600f0 | bsearch of the NPC info table (§5.9) by handle; caller `sp_NC_ACT_AUTO_WAY_FINDING_USE_GATE_REQ` (Z02) |
| `HitMeList::EnemyList::el_EnemyExpDistCheck(mob)` FUN_00482720 | run by `el_ExpDistribute` (Z03 §8.2) before the EXP split: every player entry `{key, obj, …, damage}` of `el_vecEnemyPlayer` is refreshed (stale object → `som_FindPlayer(key)`, not found → key −1, skipped); a player farther from the mob than `MobInfoServer.EXPRange` (+0x39) has its damage subtracted from its unit (raid → kind 2, party → 1, else single), and a unit whose total drops below 1 is removed. So players out of EXP range at the kill get no share and shrink their party's share |
| `ShineMob::sm_DamageSet` FUN_0055e5f0 | the `&mobdamage` command body (`AmpersandCommand::ac_mobdamage`, Z11): arguments freeze `Y/N`, recover `Y/N`, factor (`%lg`) → `g_LUA_SCRIPT_SECURITYFactor.lsf_IsFreeze` / `lsf_IsRecover` / `lsf_Factor` (the factor of §1.1); replies with the factor as a notice (vt 0x784) |
| `MobDataBox::mdb_SpeciesDistance(id1, id2)` FUN_00640f50, `mdb_IsSpeciesDistanceByQuest(id1, id2, col)` FUN_00641020 | compare the four `MobSpecies` names (first match not `-` → its column, else −1) / one `QuestSpecies.MobGroupName` column of two mobs *(column return inferred from the loop)*; callers weapon titles (`CWeaponTitleZone::GetLevelData`, `so_weapontitle`, Z07) and quests (`CQuestZone::IsConnectionEnd` / `…Action`, Z15) |
| `ShineObject::so_DistanceSquar` FUN_004013b0 (x, y) / FUN_004028f0 (object), `so_GetXCoord` FUN_00401390, `so_GetYCoord` FUN_004013a0, `so_GetLayer` FUN_00419420, `so_InitLayerRegNum` FUN_005536e0 / `so_SetLayerRegNum` FUN_0054aab0 / `so_GetLayerRegNum` FUN_0054aad0 | distance², coordinates, layer, 64-bit layer registration number (§9.6 sub-layers) |
| `ShineObject::so_DamageLog` FUN_0054b5e0, `so_smo_LastDamageOperation` FUN_00631170 | the first only creates `Dbg.txt` and the "DamageLog" log once (its caller `so_Bash` is dead, §7.8); the second is an empty base slot |
| `ShineMobileObject::so_SendInform2Admin(gm)` FUN_0058e0d0 (mob: `ShineMob::so_SendInform2Admin`) | GM inspect lines "Name", "Level", "Mode", "Location map/x/y" (or "Null"), "HP cur/max" to the GM (command side: Z11) |
| `ShineMobileObject::smo_CureCurse(subState, rank)` FUN_0040a1a0 | every abstate of that SubState with rank ≤ `rank` gets end time = now (ends next tick); caller `so_ply_ItemEffect` (item use, Z04 / Z03) |
| `ShineMobileObject::smo_SkillResultPacket` FUN_0057a630, `so_FirstActionAfterSocketConnect` FUN_0054b6d0 | dept-9 header then the skill-result sender (vt 0x49c → +0x40; Z03); base first action + mode byte 0 (Z01) |
| `FieldMap::fm_GuildTournamentEnemy(g1, g2)` FUN_004632f0, `fm_GetKQhandle` FUN_00419370, `fm_GetFieldBonus` FUN_004193a0, `fm_IsBlock(x, y, test)` FUN_00419300 | GT system `IsBattleGuild` (mover hit rule §8.4); `fm_KQHandle`; `&fm_FieldBonus` (drop rate §11.2); calls the given block test |
| `FieldMap::fm_Exist(kind)` FUN_00485040, `fm_KickAll` FUN_00484f70, `fm_SetIndunLevelType` FUN_00461b60, `fm_Compare` FUN_00452a30 | `IsAnybody` walk over the map (`so_AllInMap` from `flag[2]`); `KickPlayer` walk; dungeon level type; map-ID order of `List<FieldMap>`: instance-dungeon cluster (Z14) and GT start (Z16) |
| Constructors / destructors: `ShineObject` FUN_00558f70 / FUN_00554e30, `ShineNPC` FUN_0055c230, `ShineBandit` FUN_0055b2c0, `ShineDropItem` FUN_00559090, `MobHatchery` FUN_004b3fc0 / FUN_004b22e0, `KQRegenTable` FUN_004b1220 / FUN_004b2630, `ItemDropFromMob::DropGroupCluster` FUN_0048ffc0, `Navigator::MapNavigator` FUN_005c89f0, `PineScriptMobRegenerator` FUN_004e76e0, `MobAttackSequence` FUN_004a8920, `BlockDistribute::BlockDistributeManager` FUN_00438ac0 (+ `BlockingDistribute::bd_Inactiv` FUN_00438950), `LuaScriptScenario` FUN_005d8020, `MobDataBox` FUN_00642cf0 / FUN_00642c50 (+ iterators FUN_00490090 / FUN_004a84b0), `MobConditionChecker` FUN_004b06e0 / FUN_004b03f0 / `MCC_DeInit` FUN_004b02b0, `MobActionArgument::Actor` FUN_00549c90, `…::Selector` FUN_0054eec0, `MapBlockInformation` FUN_0049de60, `MobActionWander` FUN_004b8b40 | the `ShineObject` ctor links both coordinate nodes to the object, points layer / location at shared temporaries and clears the map-marking flag and layer number; the rest allocate / free the members listed in §5–§13 |

### 28.9 Data files and opcodes against this file

- **9Data:** every `.shn` in `9Data/Shine/` and every `World/*.txt` is named by some doc except the 27
  `World/Param<Class>Server.txt` files; they are loaded by `CharClassManager::ccm_Load` FUN_0044a5c0 together with
  `ChrCommon.txt` (Z01's loader table: `World/ChrCommon.txt | CharClassManager_ccm_Load`): per-class player parameters,
  not world simulation (coverage boundary). The directories `AIScript`, `AreaBMP`, `BlockInfo`, `LuaScript`,
  `MobAttackSequence`, `MobBehaviorDescript`, `MobRegen`, `MobRoam`, `MobSetting`, `ScenarioBookShelf`, `Script` are in
  §5–§27. Of the rest, `NPCItemList` (Z01 / Z02 / Z04), `View/*.shn` (Z01's loader list) and
  `DefaultCharacterData.txt` / `TutorialCharacterData.txt` (D02) are documented elsewhere; `AbState/*.dat` (11 files) is
  named by no doc: abnormal-state data, Z03's (coverage boundary).
- **Opcodes:** 162 opcodes are sent from functions this file cites (generated layouts, `s2c` send sites). 98 of
  them are described here; the other 64 are sent by functions cited only as callers or callees (`sp_GainExp`,
  `so_KilledBy`, `so_LinkTo`, `sp_NC_MAP_LOGINCOMPLETE_CMD`, `so_Bash`, `sp_SendMyInform2PartyMember`, mini-house,
  mover, wedding, GT and instance-dungeon code). All but six are documented by their owners (Z01, Z02, Z03, Z04, Z05,
  Z06, Z07, Z08, W01–W04, D02–D05); the six without any doc are in the coverage boundary (§31.3; the `layouts.json` hit
  0x0E0D in `ShineMiniHouse::smh_SendFurnitureInfo` is no packet: the bytes are the local inventory-kind array `{3, 0xd, 0xe, 0x10}`;
  that function sends 0x8C08 / 0x8C09 and DB 0x3449): 0x8C4F (`ShineMiniHouse::so_Routine`), 0x1059 / 0x105A
  (`so_ply_ClassChange`; documented in §28.13 since part 18, so four remain), 0x2442 / 0x2443
  (`ShineMobileObject::smo_SkillBash_Blast_Trap`), 0x74F2 (`GuildTournamentSystem::PlayerRegister`).

### 28.10 Last Z09 helpers of the gap list (part 17d)

The part-17d re-run of the gap check (§31.1) still listed 66 functions of Z09's own classes. Most are constructors,
destructors and accessors; the few with logic are written out here. Everything else on the list belongs to other items
(§31).

| Function | What it does |
|---|---|
| `ShineMobileObject::smo_LoginAfterLogout(xy)` FUN_0055d880 | base form of the re-login that `ShineMob::smo_LoginAfterLogout` FUN_0055d9b0 extends (§28.8): `so_mobile_StopHere` (vt 0xa48), `so_LogoutPacketBroadcast` (vt 0x14), `so_Unmark(2, 0, 3)` (vt 0x33c); regen location ← `xy`; `fm_Marking(map, self, 0, 0, 1)`; success → `so_AllOfRange(sight range, regen location, so_BroadcastBriefInfo)`; failure → `so_RetrateFromMap` (vt 0x3f4) |
| `MobRoaming::MobsInRoaming::mir_MoveInfoSendTo(p)` FUN_004b78b0 | calls `so_mobile_SendMyMoveInfo(p)` (vt 0xa10) for every listed mob, then empties the list; called from the player's brief-info sends (`sp_NC_MISC_HIDE_EXCEPT_ME`, `sp_ReSetSendMyBriefInfo`, `so_ply_SendBriefInfo_Mover`, `sp_NC_MAP_LOGINCOMPLETE_CMD`, Z02 / Z01): the mobs collected there get their move packet after their brief info *(inferred from the callers)* |
| `MobRoamingPoint::mrp_Start` FUN_004b70f0 | restart a roaming route: point index 1, direction 0 (§9.5) |
| `ItemGroupClassifier::igc_Getitem(name, classMask)` FUN_004903e0 | used by `tcm_ItemMake(ShineReward)` (§10.10). `name` is an item index name in `itemdatabox` → that item ID. Otherwise `name` is an item group (`igc_btree`): shuffle the group's card stack once (`cs_Suffle`), then draw cards in order, each drawn card goes back to the bottom (`cs_InsertBottom`); return the first item whose `UseClass` bit (`ccdb_UseClassTypeToBit`) is in `classMask`. 0xFFFF for an unknown group ("Invalid group name"), an empty stack, an invalid item, or no usable item |
| `RewardData::rd_FindHandle(h)` FUN_0064c850 | linear search of the `ShineReward` rows for `RewardHandle == h`, null if none; only caller `sp_KQReward` FUN_0052da70 (Z16) |
| `RollBackPosCallBackEvent::RollBackPosCallBackEvent(o)` FUN_00444a40, `GetLinkData` FUN_00444a30 | the stored "go back" position of §25.4: both link names (`linktoserver`, `linktoclient`, 12 bytes) ← the object's current map name, coordinates ← its regen location. Ghidra shows the map-name reads as calls to unrelated folded bodies (`so_ShineMobileObject`, `almc_HowMany`); `GetLinkData` is such a folded accessor (§18.5). Only constructor call: `sp_Guild_Tournamnet_Observer…` FUN_004788c0 (Z16) |
| `cWell512Random::well512_GetRandom()` FUN_0063ca00, `(n)` FUN_0063cb10, `(min, max)` FUN_0063cab0; `RandomBox::rb_1000` FUN_004012a0 | the zone's random generator (`g_Rng`, header): WELL512a over 16 state words; `()` returns state / 2³² in [0, 1); `(n)` = `round(r × 10¹¹) mod n`; `(min, max)` = `min + round(r × 10¹¹) mod (max − min + 1)`, `min` when `max ≤ min`. `rb_1000` = `(1000)`, a per-mille roll 0…999 (callers: passives, dice, random options, pets, `NPCAction::BallAction`) |
| `ShineRadian::sr_ShineDirectCheck(d)` FUN_00579150 | folds a direction (2° units) into 0…180 by one step: `d < 0 → d + 180`, `d > 180 → d − 180` (§26.3 summons) |
| `CompareDistanceSquare` FUN_005d64e0, `AxialListNearScan::alns_Compare` FUN_004c1810 | sort predicates: distance² ascending (§18.5 `cGetNearObjListByCoord`); `qsort` compare on the entry's +4 (distance) |
| `FieldMap::fm_MoveCenter(xy)` FUN_00461d60 | map centre `(fm_XSize / 2, fm_YSize / 2)` (§28.8 re-link) |
| `FieldOption::fo_Store(attr)` FUN_0063e270 | append a `FieldAttr` pointer, at most 512 (more are dropped without a message); caller `FieldContainer::fc_MakeField` FUN_004650a0 |
| `ListCheckStruct::lcs_Init(src)` FUN_00552c70 | copies the four list-check counters of `src` minus 1, so the next walk sees every list as not yet visited *(inferred)*; callers `fm_Marking` FUN_00452fd0 and `so_FirstActionAfterSocketConnect` FUN_00554870 |
| `ShineObjectManager::som_Getlist(kind)` FUN_004193f0 | object list per kind 0…12; a larger kind returns list 0 |
| `BlockDistribute::BlockingDistributeList::bdl_New` FUN_00438be0 | appends an empty `BlockingDistribute` node (no branches, `bd_Act` 0) to the list and marks it in use; returns it (§9.4) |
| `OptionReader::or_ExecColumnType` FUN_00645f70 | the `#columntype` command of §28.6 (error "ColumnHeader without table" before a `#table`) |
| `ShineObject::LuaAi::LuaAi` FUN_00554c90 / `~LuaAi` FUN_00554d10 | the eight empty event-function names of §14.3 (`Entrance`, `NPCClick`, `NPCMenu`, `MobDamaged`, `ObjectDied`, `NPCAction`, `MobAttack`, `RankingValue`), built by the `ShineObject` constructor |
| `MobDataBox::<mdb_BinData>` constructor FUN_00641ae0, `MobDataBox::operator int` FUN_004ae530 | builds the table boxes of §5.1 (MobInfo, MobInfoServer, MobWeapon, MobSpecies, QuestSpecies, MobKillAnnounce with default text `MKL_Helga`, MobKillLog, …) with zeroed default rows; `operator int` = `mdb_maxmobhandle + 1` (row count) |
| `IObserver::notify` FUN_005cc5c0, `~IObserver` FUN_005cc5b0 | base `notify` returns 2 and is never called (§14.8, §16.4) |
| `AxialListPacketBroadcast4ItemPickUp` ctor FUN_00428dd0 / dtor FUN_00428eb0 | the pickup / drop-object broadcast walker (`sp_Send_NC_ITEM_SOMEONEPICK…` Z04, `ShineDropItem::so_LogoutPacketBroadcast` §11): stores the packet; a length the packet cannot hold asserts "Too long packet" and sends length 0 |
| `AxialListLimitAreaScan` ctor FUN_004c19c0 | area-scan walker with no area yet (`allas_pArea` null); used by `smfm_MagicFieldDamage` (§12) and the Z03 skill target scans |
| `NPCManager::operator->` FUN_004c52e0, `MapSubString::mss_Get` FUN_00461c50, `TreasureChestMaker::tcm_GetItemNum` FUN_005956b0, `ORField::orf_ColumnName` FUN_00653a50, `BitSet::bs_clear` FUN_00438930, `Navigator::VirtualMap` ctor FUN_005ca200, `SlantedCoordList::CoordedNode::cn_Reset` FUN_00550710 | accessors: the NPC table `nm_NPCInfo` (§5.9); the current map sub-string; `tcm_ItemNum`; the column header's name; zero all bytes; `vm_Map ← map`; self-linked ring node |
| `CardDeck::CardStack::cs_Suffle(n)` FUN_0064e200, `cs_InsertBottom(card)` FUN_0064e310 | the item-group deck of `igc_Getitem`: `cs_Suffle` does `n` random swaps of two cards (positions `rand() % count`, CRT `rand`, not `g_Rng`), so `igc_Getitem`'s `cs_Suffle(1)` changes one pair per draw and the draws stay close to a rotation through the group *(inferred)*; with an empty group `count` is 0 and `rand() % 0` divides by zero (original bug, Z09-B127). `cs_InsertBottom` puts a card into the first free entry (`l_Enlargement(5)` when full); 0 when the list cannot grow |
| `BitSet::BitSet(bits)` FUN_00438900 | `bs_maxbyte = ⌈bits / 8⌉`, `new` byte array (not cleared; `bs_clear` does that) |
| `ORColumnHeader::orch_GetColumnName` FUN_00647140, `ORRecord::l_Clone(src)` FUN_00653d20 | the column's name; record move: copy the 512 field pointers and the buffer pointer, then null them in `src` (used by `l_Enlargement`) |
| Constructors / destructors | `MobActionAvoidOverlap` FUN_004b8be0, `MobActionBackStep` FUN_004b8bd0, `~MobActionBase` FUN_004b8ab0, `MobActionChase` FUN_004b8bc0, `MobActionInChase` FUN_004b8aa0, `MobActionInMove` FUN_004b8a90, `MobActionInMove_Cancelable` FUN_004b8ac0, `MobActionSwingDamage` FUN_004b8c00, `MobActionTurning` FUN_004b8bb0, `MobActionWaitSkillEnd` FUN_004b8bf0 (vtable only, §7.1); `MobActionRoaming::mar_Init` FUN_0043c620 (`roamingnum ← 0`, returns the element); `MobTargetStruct` FUN_004a9b20; `~MobTargetAggresive` FUN_004bd3a0, `~MobTargetBout` FUN_004bd430, their base `~MobTargetSelector` FUN_004a9b60, `~MobAggroManager` FUN_004bd500 (§6.1); `~AttackElement4Mob` FUN_0043bf00, `~SkillChangeList` FUN_004a8670 and the static `mas_Find` key destructor FUN_0069c790 (§7.6); `~MobBreederGroup` FUN_004b1c20 (§10.2); `TreasureChestLocationManager` FUN_0052d640 (= `BitSet(8)`), `~TreasureChestMaker` FUN_00595b60 (§10.10); `~TriggerChat` FUN_004902b0 (§14.5); `TargetAnalyser_Player` FUN_00591d60; `SlantedCoordList::CoordedNode` FUN_00587d50, `ObjectXCoordNode` FUN_00587ce0 / FUN_00587d40, `ObjectYCoordNode` FUN_00587d10 (§9.6); `ORColumnHeaderList` FUN_00647240 (512 null columns) / FUN_00647650, `ORComment` FUN_0064d640, `ORExchange` FUN_0064d630, `ORKeyList` FUN_00653970 / FUN_006538b0, `~ORRecord` FUN_00653f40 (§28.6) |

### 28.11 The game's own container and vector templates

Not the MSVC library (§31.4): these are the server's own templates, used all over the zone and read here because the
gap list reached them through Z09 classes.

```
List<T>        fixed array of (max + 1) ListStruct<T> { T* ls_Content, u16 ls_Prev, u16 ls_Next, u8 ls_IsActiv } (12 bytes)
               l_Finger { u16 store = first used entry, u16 empty = first free entry }, u16 l_ListNum, u16 l_MaxSize
  l_MakeList(n)      @ FUN_004b36a0 (same body per T: MobBreeder; MobBreederGroup FUN_004b3b20, HitMeList::Enemy FUN_00481ef0,
                       SkillChange FUN_004a86a0, MobTargetStruct FUN_004bd730, ORTable FUN_00646650, ShineObject FUN_005546f0,
                       ShineObjectEachList FUN_00554b10, HuntLog::MobHuntElement FUN_004b6d20, ChargedItemEffectElement FUN_00451710 (part 18))
      n == 0xFFFF: no array. Else new[(n + 1) × 12], all contents null; entries 0…n−1 form the free ring
      (prev = i−1, next = i+1, entry 0's prev = n−1, entry n−1's next = 0), inactive; entry n is the sentinel
      (self-linked, active); store = n, empty = 0, count 0; then the ListEraser walk over the (empty) used ring
  l_AllocZ(i)        @ FUN_005d08c0 (ItemActionObserve)
      take entry i (i < max, inactive) out of the free ring, link it at the end of the used ring, active, count + 1;
      returns its content pointer; null when i is out of range or already used
  l_AllocationZ(&i)  @ FUN_004025d0 (ShineObject): i ← first free entry (`empty`); none → null; else vt 8 (= l_AllocZ(i))
  l_Search(...)      @ FUN_00481e20 (HitMeList::Enemy): ListSearchSame walk over the used entries; returns the match and
                       its index (0xFFFF when none)
  List<ORRecord>     ctor FUN_006468d0 (→ l_MakeList FUN_006464d0), l_Enlargement FUN_00647e20 (grow the array when full; `List<CardDeck::Card>` form FUN_0064df00, called by
                       `cs_InsertBottom` with 5; the leak of Z09-B88 is the
                       `List<Block>` form of the same template)
BTree          256-way trie on the bytes of a name: node = { u32 bt_id (0xFFFFFFFF = none), BTree* bt_subtree[256] } (0x404 bytes)
  BTree() FUN_0063cb50 (id none, 256 null children), ~BTree FUN_0063cb70 (deletes every sub-tree recursively)
  bt_Insert(name, id)  @ FUN_0063cba0 (the `char*` overload FUN_0063cc70 forwards): walk / create one node per byte; at the terminating 0 store id;
                       returns 1, 0 when a node cannot be allocated. Look-up (`operator[]`) returns bt_id or 0xFFFFFFFF.
                       Used for every "index name → row" table (ItemDataBox, item groups `igc_btree`, …)
VectorClass::VectorWithLength { x, y, vwl_Length }   ctor(a, b) FUN_00462ab0: (a − b), length ← ddt_Distance
  vwl_Scale(L)         @ FUN_00461b80: length 0 → (1, 0, 1) first; (x, y) ← (x, y) × L / length; length ← ddt_Distance(x, y)
VectorClass::UnitVector (VectorWithLength of length 32)
  UnitVector(a, b)     @ FUN_0054b430: (a − b); zero length → (1, 0); scaled to (x × 32 / len, y × 32 / len); dtor FUN_00549490
  Rotation(angle)      @ FUN_00579250: rotate by `angle` with the 1024-scaled sin / cos tables of `shineradian`
                       (x' = (cos·x − sin·y) / 1024, y' = (sin·x + cos·y) / 1024, rounded toward 0)
```

### 28.12 Score boards, rankings, the instance-dungeon rank and the hunt log (review)

Found by the review (part 18): Lua functions that §14.9 had handed to Z14 / Z16 although neither plan names them, and
the player's hunt log. All Lua functions below are registered by `LuaScriptScenario::ls_FuncSet` FUN_005f5350 (§14.9).
"Player" = `som_GetObject(handle)` non-null, not `so_IsEmpty` (vt 0x300) and kind (vt 0x4d0) 2. "Map" = `fc_FindMap(name)`
and its centre object (`fm_GetCenterObject`); a broadcast "to the map" is `so_AllInMap(centre, AxialListPacketBroadcast)`
(every player on the map, §18). Per player sends go through the data stream (vt 0x2f8) or the game stream (vt 0x2fc) as
noted. Every function returns 0 Lua results unless stated.

```pseudo
cScoreInfo(handle, n, score0, score1)                                   @ FUN_005e3790
    arg 1 nil or not a player: return
    0x5836 NC_KQ_SCORE_INFO_CMD { u32 nScore[2] }  (both 0, then nScore[i] = arg 3 + i for i < min(n, 2))   → player (vt 0x2f8)
cScoreInfo_AllInMap(map, n, score0, score1)                              @ FUN_005e3970
    map / centre missing: return;  same packet, broadcast to the map
    # 2016 scripts: KDArena, KDSoccer(_W), KDSpring (`cScoreInfo(Handle, #TeamNumberList, red, blue)`)
    # client GameFrameWork::On_NC_KQ_SCORE_INFO_CMD FUN_0049d8b0: if the KQ score window (+0x13cc) exists, open it
    #   (OpenKQScoreWin) and KQScoreWin::SetScore for both teams

cScoreBoard(handle, useRound, round, redWin, redScore, blueWin, blueScore)    @ FUN_005ed860
    arg 1 nil or not a player: return
    0x583C NC_KQ_SCORE_BOARD_INFO_CMD { u8 bUseRound = toboolean(arg 2), u8 nRound = arg 3,
        TEAM_SCORE_INFO Red { u8 nWinFlag = min(arg 4, 5), u8 nScore = min(arg 5, 99) },
        TEAM_SCORE_INFO Blue { u8 nWinFlag = min(arg 6, 5), u8 nScore = min(arg 7, 99) } }  (8 bytes)   → player (vt 0x2f8)
    # the length-error text says "cScoreInfo : Packet Too Long" (copied; never reached)
cScoreBoard_AllInMap(map, useRound, round, redWin, redScore, blueWin, blueScore)   @ FUN_005edad0
    same packet and limits, broadcast to the map
    # 2016 scripts: KDCake, KDWater (`cScoreBoard(Handle, true, Round, red.RoundResultCount.Win, red.Score, …)`):
    #   nWinFlag carries the rounds won
cWinter_Event_ScoreBoard_AllInMap(map, red, blue)                        @ FUN_005edcf0
    0x583D NC_KQ_WINTER_EVENT_2014_SCORE_CMD { Red { 0, u8 red }, Blue { 0, u8 blue } }  (6 bytes, no limit), broadcast
    # 2016 script: KDSoccer_W
    # client: 0x583C FUN_0049af40 / 0x583D GameFrameWork::On_NC_KQ_WINTER_EVENT_2014_SCORE_CMD FUN_004ae2b0: if the team
    #   score window (+0x1418, KDTeamScoreWin) exists: show it (FUN_0048ce20), SetUseRound (0 for 0x583D), per team the
    #   score and SetWinFlag; 0x583C then SetRound, 0x583D sets the title text 0xf821dc11

cSendRankingList(handle, previous, current)                              @ FUN_005eaee0
    handle 0xFFFF or not a player: return
    0x6C20 NC_SCENARIO_RANKING_LIST_CMD { SCENARIO_RANKING_INFO PreviousRanking[20] @0, CurrentRanking[20] @0x1F4 }  (0x3E8, zeroed)
        SCENARIO_RANKING_INFO (0x19) { u8 nRanking, Name5 sCharID @1, u32 nScore @0x15 }
    for list in (arg 2 → Previous, arg 3 → Current), when the argument is a table: for each value (lua_next order):
        nRanking = number field "nRanking", sCharID = strncpy(string field "sCharID", 20), nScore = number field "nScore"
        a field of another type: return at once, nothing sent (asm 0x5eb2d7)
        # no limit of 20 per list (original bug) Z09-B130
    → player (vt 0x2fc)
    # 2016 script: AIScript/E_Ski_CongressNPC.lua (ski congress ranking NPC)
    # client GameFrameWork::On_NC_SCENARIO_RANKING_LIST_CMD FUN_0049d3f0: if the event rank window (+0x135c) exists:
    #   every entry with nRanking ≠ 0 → EventRankWin::AddPrevRank / AddCurRank (25 bytes each), then shows the window

cScoreResultList(map, mode, base, limit, list)                           @ FUN_005ec6a0
    map / centre missing or mode not a string: return
    0x5814 NC_KQ_SCORE_CMD { u8 num, u32 base = arg 3, KQScore[num] @5 (0x26) }       (layout §22.3)
    if arg 5 is a table: for each value i (lua_next order):
        e.charid = strncpy("CharName", 20); e.killpoint = "Kill"; e.downpoint = "Death"; e.score = "Score" (integers)
        o = GetObject(number "Handle"); "Handle" not a number, o null, so_IsEmpty, smo_GetMode (vt 0x484) == 0 or
            ShinePlayer::so_ply_SoloingMode (vt 0x79c) == 1: return, nothing sent
        mode "ConditionOfHero":    killpoint += 500; contribute = RandomRing(10) (0…9); score = killpoint − downpoint + contribute + base
        mode "NewConditionOfHero": contribute = 0; score = Score + base
        other:                     contribute = 0; score = killpoint − downpoint + base
        flag.gender = so_ply_GetGender (vt 0x804); flag.chrcls = class (vt 0x49c → vt 0x38)
    count > 0: medals 1 / 2 / 3 written into entries 0 / 1 / 2 (the first three of the table, **not sorted**: unlike the
        Pine `@KQResultList` of §22.3 the Lua version keeps the script's order); num = count, or min(count, limit) when limit ≠ 0
        broadcast to the map (7 + 0x26 · num bytes)
    # no 2016 script calls it; no count limit (num is a u8) (original bug) Z09-B130

cScoreTopList(map, mode, base, limit, list)                              @ FUN_005ec1f0
    same checks; 0x5821 NC_KQ_SCORE_SIMPLE_CMD { u8 num, u32 base, self { u8 rank, u32 kill, down, score } @5,
        KQScore[num] @0x12 (0x20: Name5 charid, u32 kill, down, score) }
    per table value: the same fields and the same three score rules (contribute is not sent); the handles are kept in a
        local u16 array (ebp−0x50)
    count > 0: num = count, or min(count, limit) when limit ≠ 0
        for i in 0..count−1: o = GetObject(handle[i]); null / empty / mode 0 / soloing: stop
            self = { i, kill, down, score of entry i };  o ← the packet (0x14 + 0x20 · num bytes, vt 0x2fc)
    # no 2016 script calls it; no count check against the handle array (original bug) Z09-B130

cIndunRankResult(mapName, seconds, players)                              @ FUN_005ee4d0
    map = fc_FindMap(arg 1) (string); missing: return 0
    t = tointeger(arg 2)
    DB packet in gpp: 0xA413 NC_INSTANCE_DUNGEON_RANK_SAVE_DB_CMD { SHINE_INDUN_INFO { Name3 MapIDClient =
        map.fm_FieldOption.mapidclient, u8 ModeIDLv = map.fm_eLevelType (ILT_MAX → 1) }, u32 nPlayTime = t @0xD,
        u16 nRankCount @0x11, SHINE_INDUN_RANK[n] @0x13 (0x20: u32 nCharRegNum, u64 nDamageDealt @8, nDamageTaken @0x10,
        nHealingDone @0x18) }
    client packet in a 4 KB stack buffer: 0xA412 NC_INSTANCE_DUNGEON_RANK_RESULT_CMD { u8 nPlayTimeHour = t / 3600,
        u8 nPlayTimeMinute = t % 3600 / 60, u8 nPlayTimeSecond = t % 60, u16 nRankCount @3,
        SHINE_INDUN_RANK_CLIENT[n] @5 (0x30: Name5 nCharID, u8 nCharClass @0x14, u64 dealt @0x18, taken @0x20, healing @0x28) }
    map has no fm_FieldOption, or arg 3 not a table: return 0, nothing sent
    for each value of arg 3:
        value not a table; "Handle" missing or not a number; object missing; no name (vt 0x56c so_CharName);
        no character data (vt 0x49c); "DamageDealt" / "DamageTaken" / "HealingDone" not numbers:
            return 0, nothing sent (asm 0x5ee66e)
        DB entry: nCharRegNum = o.vt[0x344]() (charNo), the three values
        client entry: nCharID = name (20 bytes), nCharClass = class (vt 0x49c → vt 0x38), the three values
        n += 1                                # no limit (original bug) Z09-B130
    Character server ← 0xA413 (0x15 + 0x20 · n bytes, `sock2gameDB`)   # dropped there in 2016 (W04 §13.3, W04-B43)
    broadcast to the map 0xA412 (7 + 0x30 · n bytes, so_AllInMap with include flag 1)
    return 1 (the number 1)
    # no 2016 script calls it (FH documents `cIndunRankResult(MapInx, Time, PlyList)`, NA scripts *(fh-doc)*)
    # client GameFrameWork::On_NC_INSTANCE_DUNGEON_RANK_RESULT_CMD FUN_0049de70: PartyScoreWin (+0x1424)
    #   SetPartyScore(ranks @5, count @3), then opens that window (FUN_0048cf00, client names file:
    #   `OpenKDTeamScoreWin`); the play time is not read there
```

**Hunt log** (`HuntLog::MobHuntLog`, member `ShinePlayer::sp_MobHuntLog`, built in the player ctor FUN_0055bc80 by
`MobHuntLog::MobHuntLog` FUN_004b70d0 = `CommonList<MobHuntElement>(50)` FUN_004b6fe0: the §28.11 `List<T>` with
`l_MakeList(50)` plus one `new[50]` element array `cl_Array` whose element i becomes the content of list entry i):

```pseudo
MobHuntElement { u16 mobid, u16 number, u32 expgain }
mhl_Logging(log, p, mobId, exp)                                          @ FUN_004b6ea0   (exp path, Z03 §8.2)
    e = search the used entries by mobid (MobHuntElement::mhe_Compare FUN_004b6aa0: mobid difference)
    found: e.expgain += exp; e.number += 1; e.number ≥ 65000: mhe_Send2Log(e, p)   # flush before the u16 overflows
    else:  take a free entry (none: the kill is not logged; 50 mob kinds per session) = { mobId, 1, exp }
mhe_Send2Log(e, p)                                                       @ FUN_004b6ae0
    e.number == 0: return
    GameLog ← 0x042D NC_LOG_GAME_MK_GETEXPINFIELD { u32 chrregnum = p.vt[0x344](), u16 mobid, u16 number, u32 exp }
        (14 bytes with the opcode; GameLog side D05 §2.3, `p_GameLog_Add_Type4`)
    e.number = 0; e.expgain = 0
mhl_SendAll2Log(log, p)                                                  @ FUN_004b6c20
    called from ShinePlayer::so_Unmark FUN_00558900 (logout): mhe_Send2Log for every used entry
    # the inlined accessor returns null for an inactive entry inside the used ring, which would crash in
    # mhe_Send2Log; unreachable while the ring is consistent
```

Small helper: `MapDataBox::mdb_2mapid(name)` FUN_00419470 (from `cLinkToAll`, §17) = the map name's id in `mdb_btree`
(BTree, §28.11), 0xFFFF when unknown.

### 28.13 Small leftovers of finished items: capsule creation, class change, charged effects, guild-war request

Their owners (Z05, Z07, Z08, Z01) were already done when part 18 re-owned them, and each is too small for a follow-up
session, so they are documented here (the larger leftovers of finished items: `docs/knowledge/Z09.md` §3).

```pseudo
ShinePlayer::sp_MakeCapsuleItem(p, capsule, u64 price, u32 fame, u32 gbcoin)          @ FUN_0049cce0
    # caller: sp_CreateItemByAdmin FUN_00527270 when the created item's ItemAttr class (vt 0x28) is 0x1D (capsule),
    #   with price = fame = gbcoin = 0 (asm 0x527320); the profiler string says "so_MakeCapsuleItem"
    every failure below: p.so_SendErrorCode(12, 4, code) (vt 0x308) = 0x3004 NC_ITEM_BUY_ACK { u16 code } (Z04),
        0x0203 or 0x020A (no client error text)
    capsule null, class ≠ 0x1D, or no ChargedItemEffect row for its id (`chargedbuffdatabox.cideb_GetItemID`): 0x0203
    class.vt[0xb0](capsule, row.KeepTime_Hour, now = chargeditemcheck.ct_Current)       # sets the capsule's expiry
    cell = first free unlocked cell of the inventory (ItemBoxIterEmpty over the bag + charged list, lock list
           vt 0x7d4 so_ply_GetInventoryLockList, inventory type 9); none: 0x020A
    reward = CLCReward::clcr_GetRandomLCRewardData(gLCReward, capsule.id)                # random content row
    reward null or reward.Item_Inx unknown: 0x0203
    content = { key = iti_mkregnum(id, 1, zone, world), id }, attributes from its class (vt 0x14, "-o"),
              RandomOption fill when ItemInfoServer names a table (as dilig_Drop, §11.2), lot = reward.LCR_Lot (vt 0x20)
    capsule's attribute keeps the content key (attr dwords ← content key)
    Character server ← 0x34A0 NC_ITEMDB_BUYCAPSULE_REQ (0xFC) { hdr { u16 handle, u32 charNo }, nBuyNpcHandle = p.sp_NPCProcess.npchandle,
        nLockIndex = lock list +4, nMap = NameString[p+0x7a] (FUN_00418ec0 on DAT_0085dfb0), nPrice, nFame, nGbCoin,
        CapsuleLocation = cell, CapsuleInfo = capsule (ItemTotalInformation), ContentInfo = content }   (layout D03 §2.5)
    lock: the cell (lock vt 0x40), money price (vt 0x48), fame (vt 0x4c), coin gbcoin (vt 0x70); lock index += 1
    p.so_ply_ReactionNpcHandle() (vt 0xb40)
    # the answer 0x34A1 NC_ITEMDB_BUYCAPSULE_ACK is Z05's (scope line 117, FUN_00525840)

CLCReward::clcr_GetRandomLCRewardData(r, capsuleId)                                    @ FUN_0049cbc0
    # tables LCGroupRate / LCReward (loader 0049d420, Z01 §2.3 table list); groups clcr_LCRewardGroup[clcr_nMaxNum]
    #   (16 bytes: LCGroupRate m_Group { Item_ID, LCR_Group, LCR_Rate }, m_pItem, m_ItemCnt)
    no groups: null
    total = clcr_LCItemList entry of capsuleId (sum of its rates), 1 000 000 when the capsule is not listed
    roll = rand(1 000 000); cum = 0
    for g in groups (in table order): if g.Item_ID == capsuleId: cum += g.LCR_Rate × 1 000 000 / total (integer);
                                      if roll ≤ cum: take g, stop
    no group taken: g = the **last group of the whole table** (any capsule) (original bug) Z09-B131
    g.m_pItem null: null;  else g.m_pItem[RandomRing(g.m_ItemCnt)] (index 0 when the count is 0 or > 100)

ShinePlayer::so_ply_ClassChange(p, newclass)                                          @ FUN_004521b0 (vt 0x6c8)
    # callers: 0x1057 NC_CHAR_CLASSCHANGE_ACK (Z07), Lua cClassChangeOpen / quest rewards
    newclass == 0: assert "None Class"; 0x1059 still sent with newclass 0
    else: shape bits 2…6 (sp_CharData.toclient.shape) ← newclass; class manager (+0xfbc) ← ccm_array[newclass]
          (newclass ≥ 0x40: the manager object itself (unchecked; classes come from the DB / quest data))
    p ← 0x1059 NC_CHAR_PROMOTE_ACK { u8 newclass }                         (game stream vt 0x2fc)
    newclass ≠ 0: so_allparametercalculate (vt 0x57c); sp_StatRemainSend
    brief info (sp_CharBriefInfo): chrclass ← newclass; shape class bits too when mode ∈ {1, 2, 6}
    WM ← 0x1058 NC_CHAR_CLASSCHANGE_CMD { hdr { u16 handle, u32 charNo }, u16 wldmanhandle = so_GetWMSHandle (vt 0x340),
        u8 newclass = class manager vt 0x38 }  (W01 scope line 246)
    newclass ≠ 0: sight ← 0x105A NC_CHAR_SOMEONEPROMOTE_CMD { u16 handle, u8 newclass } (so_AllOfRange, include self 0)
    GMEM_CheckAllConditionAndApply(p)                                     (GM events by class, §1)
    # client: On_NC_CHAR_PROMOTE_ACK FUN_004b5b20: 0 → system message text 0xdaebbeca; else "SkillLevelUp" effect,
    #   message 0xd6433c22 with the class name (class table +0x15), SetMainCharClass, char-info window; classes
    #   4, 5, 9, 10, 14, 15, 19, 20, 24, 25, 27 also get the "Aura100" effect. On_NC_CHAR_SOMEONEPROMOTE_CMD
    #   FUN_004b5d30: own handle → SetMainCharClass; the character by handle gets the class and an effect

ShinePlayer::sp_GuildWarRequest(guildA, guildB)  (static)                              @ FUN_0042e5f0
    # caller: the PvP hit rule on an attack between guilds (Z03 §3.3)
    both ≠ 0: WM ← 0x7478 NC_GUILD_GUILDWARCONFIRM_REQ { u32 guildA, u32 guildB }   (W03 scope line 154; answer 0x7479 is Z08's)
ShinePlayer::sp_ChargedEffectAfterLoginComplete(p)                                      @ FUN_00417ad0
    # from the login-complete handler 0x1803 (Z01-core line 510)
    walk the player's charged-item list (sp_ChargedItem) with a ChargedEffectAfterLoginComplete iterator (applies each
    effect after login *(inferred: the iterator's vt[0] was not opened)*)
ChargedItemEffectList::ChargedEffectList::ChargedEffectList                            @ FUN_00451890
    the §28.11 List<T> with 50 entries + a 50-element ChargedItemEffectElement array (12 bytes each), element i = entry i's content
ChargedItemEffectList::ChargedEffectListRouter::~ChargedEffectListRouter               @ FUN_00450e80
    if the container's byte +0x19 (vt 0x498 so_ply_ChargedEffectContainer) ≠ celr_MoreStat (the value when the walk
    started): so_allparametercalculate (vt 0x57c) and so_mobile_NotifyParameterChange(1) (vt 0x34)
CChargedItem::CChargedItem                                                             @ FUN_006323a0   m_NumOfChargedItem = 0
CParty::p_defaultslot                                                                  @ FUN_00645330   returns the static empty slot p_def
```

The tutorial Lua functions (§14.9 listed them under Z15, part 17d under Z07; they are Lua C functions like the rest of
§17–§19, used by `LuaScript/Tutorial/Tutorial.lua`). Tutorial info = `so_ply_GetTutorialInfo` (vt 0xdfc,
`PROTO_TUTORIAL_INFO` at p+0x2ab44 { u32 nTutorialState, u8 nTutorialStep @4 }, filled by 0x1115, Z07 §1.2):

```pseudo
cGetTutorialInfo(handle)                                                                @ FUN_005e7450
    arg 1 nil, object or tutorial info missing: 0 results;  else returns nTutorialStep (1 result)
cProgressTutorial(handle, step)                                                         @ FUN_005e72f0
    object missing: return;  object ← 0x1116 NC_CHAR_TUTORIAL_STEP_REQ { u8 nTutorialStep = step } (data stream vt 0x2f8;
        no player-kind check)
    # client GameFrameWork::On_NC_CHAR_TUTORIAL_STEP_REQ FUN_004a6a70: creates the client tutorial Lua script and the
    #   Tutorial object on first use and runs the step there
cSaveTutorialInfo(handle, state, step)                                                  @ FUN_005e70b0
    object or tutorial info missing: return
    info = { nTutorialState = state (integer), nTutorialStep = step }
    Character server ← 0x1118 NC_CHAR_TUTORIAL_STEP_SAVE_REQ { u32 nCharNo, u32 nUserNo (vt 0x348 so_GetUserRegistNumber), info }
    WM ← 0x111C NC_CHAR_TUTORIAL_STEP_SAVE_CMD { u32 nCharNo, info }
    state == 1 (finished): GameLog ← NC_LOG_GAME_DATA_TYPE_5 (nType 2025, charNo, state, step)   (D05 §4.4)
    # Tutorial.lua calls it with state 1 at the end and 0 to store a step
```

---

## 29. Original-server bugs (decide for a rebuild)

Behaviour of the 2016 zone world simulation that looks unintended, one row per `Z09-B<n>`; the "Where" column links the
section that describes it (with the function). A faithful rebuild reproduces it; a fixed rebuild should change it
deliberately. Every row is read in the code (the PDB names and types of the 2016 build confirm several, noted in
their sections); none was observed in a capture. Rows marked *(inferred)* in the effect column describe a consequence
deduced from the code, not observed.

### 29.1 Objects, mob core, AI, movement, spawns, drops (parts 1–7, R1, R2)

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z09-B1 | `so_scene_Duplicate` FUN_0050dda0, §5.8 | allocates one object, then calls its `so_mob_Regenerate` `n` times | Pine / Lua duplicate of `n` objects spawns one copy | allocate and regenerate `n` objects |
| Z09-B2 | `NPCManager::nm_DynamicRegenerateNPC` FUN_004c6cd0, §5.9 | with all 1024 `nm_BufferArray` slots used, the loop ends at index 0x400 and writes the entry there | overwrites `nm_BufferPoint` (count) and `nm_NPCInfo`; corrupts the NPC manager *(inferred)* | take the "nm_BufferArray Full" branch (free, fail) |
| Z09-B3 | `so_scene_Duplicate` FUN_0050dda0, §5.8 | passes the stored direction byte (degrees / 2) where degrees are expected; it is halved again | duplicates face half the original angle | pass `dir × 2` |
| Z09-B4 | `ShineMob::so_RescueRoutine` FUN_00569050, §6.6 | `lastSeenHP` starts and is reset at 60000 | for a friend with more than 60000 HP (155 race-typed mob kinds in 2016 data) a helper only joins once the friend is below 60000 HP | start at the friend's current / max HP |
| Z09-B5 | – (§6.5) | **withdrawn in R1**: the "mob HP full" call is the map-script interrupt `sim_MobHPFull`, not a bug | – | – |
| Z09-B6 | `MobAttackSequence::mas_Load` FUN_004a8990, §7.6 | the `*RepeatStart` marker row is stored as one more sequence value (0xFFFF, a normal attack) | each repeat cycle has an extra normal-attack step | skip the marker / store the repeat position only |
| Z09-B7 | `AttackElement4Mob::ae4m_NextSkill` FUN_004a9730, §7.6 | reads the NextSkill list (`rec+0x1250`) without a null check | only Karen.txt has NextSkill rows; an advancing select on any of the other 288 sequence mobs dereferences null (no exception trap found; how 2016 servers survived it is open, §30) | check for a null list |
| Z09-B8 | Lua `cMobWeaponRate` FUN_005f3e30, §8.2 | rate loop starts at Lua argument 1, the handle | weapon 0 gets the handle as its rate, every rate shifts by one | start at argument 2 |
| Z09-B9 | `MobChat::MobChatManager::mcm_Load` FUN_004af640, §8.6 | looks up table `"RACERESCU"`; `MobChat.txt` declares `RACERESCUE`, the parser compares 20 bytes | the 32 race-rescue chat lines are never loaded; rescue shouts never happen | look up `RACERESCUE` |
| Z09-B10 | `ShineMob::so_Shout` FUN_00459250, §8.7 | sends `len + 0x1A` bytes (the player version sends `len + 0x19`) | one stale buffer byte after every mob / NPC shout | `len + 0x19` |
| Z09-B11 | `so_mob_SetWeaponAsScript` FUN_004ab5e0 / `mab_Think`, §8.1 | an ordered script skill without enough SP gives −1 and `mab_Think` returns before the order is consumed | the mob stalls (no attack, no other weapon) until SP regenerates | drop the order or fall back to the normal choice |
| Z09-B12 | `cMobWeaponRate` FUN_005f3e30 and Pine `ShineMobWeaponRate`, §8.2 | a rate of 0 ends the rate list | a script cannot disable one weapon while giving later ones a rate | use the argument count as the end |
| Z09-B13 | sight delete workers (`ali_Work` FUN_004bdfe0 and twin), §9.6 | second send calls `o.sendObject.pcb_Append(other, packet)` with the wrong object argument | when o's buffer is full (> 0x17FF bytes) the flush goes to the wrong object *(inferred)* | pass `o` |
| Z09-B14 | `so_MoveByServer` FUN_00569510, §9.3 | remembers `lastCmd` (0x49) as the object's last move | a player entering sight gets 0x2049 NC_ACT_REINFORCE_RUN_CMD with a 22-byte move payload it misreads as a destination | remember the move command actually sent |
| Z09-B15 | `MoveManager` step throttle FUN_004be7e0, §9.1 | the unsigned "time since last step" subtraction is reversed | the 100-ms step throttle never skips a step | skip steps < 100 ms apart |
| Z09-B16 | `mbg_Set` FUN_004b1f30, §10.3 | `RangeDegree` (`rgs_Rotate`, ulong) is used unsigned | negative region rotations become ≈ 2³² degrees (−2° → 353.9°) | signed degrees |
| Z09-B17 | `MobHatchery::mh_Load` FUN_004b6330, §10.3 | when a `World/` override regen file exists it is opened and then nothing is parsed | a map with an override file gets no mobs from either file | parse the override file |
| Z09-B18 | `mb_regen` FUN_004b2cf0, §10.4 | a family member whose leader object is gone returns 0xFFFF without freeing the allocated mob | pool slot leak per failed member spawn | free the object |
| Z09-B19 | Lua `cMobRegen_Obj` FUN_005d8690, §10.7 | direction taken from the new pool object (`newMob+0x6a`), not the source object | spawned mob faces a stale direction | the source object's direction |
| Z09-B20 | `ItemDropFromMob::dilfs_DropByRate` FUN_0048e920, §11.2 | the drop count `Num` is decremented in the shared table record | a limited drop (`Num` > 0) runs out for the whole server, not per kill / per mob *(inferred)* | count per drop event |
| Z09-B21 | drop sight broadcast FUN_00567ff0, §11.3 | the "quest only" byte is the low byte of the stack cookie | random quest-only flag on drop briefs | the drop's real flag |
| Z09-B22 | `sp_partyitemdistribute` FUN_0052f630, §11.5 | the money loop (0x52f7a0) calls `vt[0x790](share)` through all 5 member slots without a null check; far / absent members' slots are 0, slots from the member count to 4 are never written (uninitialised stack) | every party money pickup that reaches the distributor (party loot rule LOOTER, ORDER or DICE, `sp_NC_ITEM_PICK_REQ` FUN_00530a50; FREE pays the picker directly) crashes the zone (access violation → `MiniDumper::TopLevelFilter`, §30.1) unless the party has 5 members all within 1000 units of the picker | pay only the near members (loop over the filled slots) |
| Z09-B23 | `sp_partyitemdistribute` FUN_0052f630, §11.5 | each share is at least 1 coin | a small amount creates money (n × 1 > amount); the raid version splits exactly | exact split |
| Z09-B24 | `GMEventManager` ctor FUN_0046dbd0, §3 | the map-kind tables are filled by a static constructor before `mdb_Load` has read the maps | GM events that select maps by kind match no map | fill the tables after map load |
| Z09-B25 | `mdbe_DoorAction` (4-arg) FUN_0049e080, §9.2 | close / break ORs block bits through a null row pointer when a door row lies outside the map | crash on a misplaced door row *(inferred)* | bounds check |

### 29.2 World objects and script infrastructure (parts 8a–9c)

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z09-B26 | `AxialListMagicFieldDamage::almfd_ApplyDamage` FUN_005682c0, §12.5 | "unkillable" and "behind a wall" leave the whole target loop, not the current target | every target after the first such one gets no damage and no abstate that tick | skip that target, continue |
| Z09-B27 | magic-field brief exchange (`bixmfm_Exchange` / `bixmfm_Send`), §12.6 | `ShineMagicField` does not override vt 0x4c4 and the exchanger never counts | 0x1C0D NC_BRIEFINFO_MAGICFIELDSPREAD is never sent: a player who enters the map or changes layer next to an active field does not see it | send fields with the other briefs |
| Z09-B28 | `so_mgcfld_MagicFieldSpread_Friend` FUN_0057ee80, §12.3 | the duration bonus is computed on the skill's KEEP time while the heal field lives for PARTY | a duration bonus never lengthens a heal field | compute the bonus on the time actually used |
| Z09-B29 | `AxialListMagicFieldHeal::almfh_ApplyHeal` FUN_0056d2c0, §12.5 | a refused abstate (stronger one present, immune) is still flagged in the brief bits and announced with its full KeepTime | clients show a state the target does not have | flag only on success |
| Z09-B30 | `almfh_ApplyHeal` FUN_0056d2c0, §12.5 | reads the scratch global `setitemskilleffect`, which casts fill and `so_Routine` resets | the heal amount uses whatever set-item effect the last processed object left *(inferred from the call order)* | the field caster's own set effect |
| Z09-B31 | `ShineMover::so_mobile_ICanDamageTo` FUN_004368c0, §8.4 (player twin FUN_004361a0) | in the KQ branch the raid test compares the mover's own raid number with itself | a mover (or player) in a raid treats every raided target as same-raid on KQ maps (cannot hit it) | compare with the target's raid number |
| Z09-B32 | `sm_serv_VanishReserv` / `AxialListMobSuicide::alms_SelfKill`, §13.3 | the dead flag is set before `alms_SelfKill`, which returns at once for dead objects | a vanishing servant never gets its self-kill and 0x243C death packet; it just stops and disappears with 0x1805 | kill first, then mark |
| Z09-B33 | `ShineDoor::so_door_Build` + 0x6C09, §13.1 | the build brief carries an empty `blockindex`; 0x6C09 carries no name | clients that saw the door built never switch its block; server and client collision disagree until they re-enter sight | send the block name at build |
| Z09-B34 | `ShineEffectObject` `seo_Detach`, §13.2 | raw pointer to the followed object, never cleared | after that object is freed, the effect follows whatever reuses the pool slot until it vanishes *(effect inferred)* | clear on removal / store a handle |
| Z09-B35 | Lua `cExecCheck` FUN_005d82a0, §14.6 | `strcpy` into `LuaScriptScenario::ls_Pointer` without a length limit | a name of 256+ characters overwrites `g_LUA_SCRIPT_SECURITY` behind it (2016 names are short) | bounded copy |
| Z09-B36 | `cTriggerRegist` vectors (§14.5) | trigger elements are never removed; they keep raw object pointers | a trigger outlives its object and fires for the pooled slot's next user; registering twice fires twice (no 2016 script registers one) | remove with the object, refuse duplicates |
| Z09-B37 | `ShinePlayer::sp_CastingBarFree` FUN_00570bd0, §14.6 | clears `brief.sAnimation` before copying it into 0x2075 | the cancel's NC_ACT_ANIMATION_STOP_CMD names "" (the client may not stop the animation) *(inferred effect)* | copy first, then clear |
| Z09-B38 | `ShinePlayer::sp_Schedule_CastingBar` FUN_00576100, §14.6 | when the target NPC is gone / far / the mode is wrong nothing is reset or sent | the casting-bar handle and animation stay set | reset and send 0x2075 in every case |
| Z09-B39 | `RankingValue` producers (heal over time FUN_0040e910, item heals), §14.3 | heal amounts are added to *dealt* too | ranking scripts count heals as damage dealt (no 2016 script uses the event) | healed only |
| Z09-B40 | `LuaScript::ls_FunctionCall` FUN_005d7bc0, §14.1 | after a failed `lua_pcallk` the error value is not popped | each failure costs one stack slot of that state; after 1 000 000 failures every call fails *(inferred)* | `lua_pop` the error |
| Z09-B41 | `so_AIScriptFuncExec` family (FUN_004ab3f0 …), §14.3 | none checks that the function name is set | a click / menu answer / bar end on an object whose script lacks `NPCClick` / `NPCMenu` calls Lua with "" and leaves an error on the stack (B40) | skip empty names (as the callers of 0x58 / 0x74 / 0xac do) |
| Z09-B42 | `sp_NC_ACT_NPCCLICK_CMD` FUN_004c4b70 → `sim_NPCClick`, §15.3 | the `index[32]` argument is an uninitialised stack buffer | `NPCClickIndex` interrupts never fire (compare with garbage) | pass the NPC's index name |
| Z09-B43 | `sib_BlastCheck` of AreaEntry / AreaLeave FUN_00509f70 / FUN_0050a0f0, §15.4 | the blast flag is not cleared when the interrupt fires | one client report keeps the interrupt armed: it fires again on later re-checks while the player is still inside / outside and `num` > 0 *(inferred effect)* | clear the flag |
| Z09-B44 | `ScriptInterruptManager::sim_Alloc` FUN_00509b10, §15.2 | `sib_Argument` is not cleared on allocation | kinds that set only part of it read the previous user's bytes (e.g. the `deadindex` `_NONE_` compare) | zero the argument |
| Z09-B45 | `ScriptInteruptWinGuild::UpdateArgument` FUN_0050d0a0, §15.6 | the winning guild number lives in one global object for all maps | two guild-tournament maps reporting before `waitinterrupt` both read the later winner | per-map storage |
| Z09-B46 | `ActionGen_OptionReader` "RestoreRate", §16.1 | HP and SP types are swapped | a "RestoreRate HP" row restores SP only | map HP → HP |
| Z09-B47 | `RestoreRateAction::exe` FUN_005c15f0, §16.5 | the HP case falls through into the SP case | with B46, a "RestoreRate SP" row restores HP and SP | `break` after HP |
| Z09-B48 | `DamageAbsorbAction::exe` FUN_005c11a0, §16.6 | every protector reads the original `sp_nDamageAbsorb`, not what the previous one left | two protectors both take the full damage; if the second dies its remainder overwrites the first one's 0 and the player is hurt anyway | chain the remaining amount |
| Z09-B49 | `NeighborhoodChecker` scan with `DetectCha` 0, §16.3 | the scan covers the whole sight but the leave test compares d² with 0 | `IDLeviathanGate01` calls `InteractWithNPC` for every player in sight each tick; `DT_RadionOre`'s `AttackMob` observer lives for one tick *(inferred effect)* | treat 0 as "sight" in both tests, or give the rows a range |
| Z09-B50 | `SkillCondition` (FUN_00615e70), §16.4 | nothing produces `EV_SKILL` (§14.8) | "Skill" trigger conditions never fire | raise `EV_SKILL` on skill use |
| Z09-B51 | `CondGen_OptionReader` / `createCondition_` FUN_005c29c0, §16.1 | `while name == "Term"` copies ConditionB into itself | a row with ConditionA and ConditionB both "Term" hangs the loader | one level of Term, or error |
| Z09-B52 | `createCondition_` FUN_005c29c0, §16.1 | an unknown condition name asserts (not fatal) and becomes a NoneCondition | a misspelt condition fires at once | fatal error, like actions |
| Z09-B53 | `DamageAbsorbAction::exe` FUN_005c11a0, §16.6 | 0x2449 flag bits 3–7 are left from the previous packet in the shared buffer | stale damage flags shown by clients | zero the byte |
| Z09-B54 | `NoticeAction::exe` FUN_005c1700, §16.5 | 0x2011 NC_ACT_NOTICE_CMD byte 0 is never written | stale byte on the wire (the client ignores it *(inferred)*) | zero it |
| Z09-B55 | `AxialListSetAbstateInArea::alsa_SetAbstate` FUN_004c1c20, §17.4 | the result of vt 0x638 is not checked; the applied strength replaces the argument | a refused state is still flagged and announced; later players get the previous player's applied strength | check the result, keep `strength` |
| Z09-B56 | Lua `cSetAbstate_Range` FUN_005f2560, §17.4 | the strength register is replaced by `g_NewAbstateStrength` after every success | the 2nd, 3rd … objects get the previous one's applied strength | keep `strength` |
| Z09-B57 | Lua `cDamaged` FUN_005f10d0, §17.3 | 0x243C carries abstate 0x1C1 = 449 (STA_MOBACPLUS); the other kill paths send 0x318 (none) | clients play STA_MOBACPLUS's view effect (if any) on script damage deaths | 0x318 |
| Z09-B58 | Lua `cFreeStatInit` FUN_005e7dc0, §17.8 | 0x111A `nMaxStat` (payload byte 4) is never written | stale byte (unused in 2016; D02 does not read it) | the real maximum |

### 29.3 Lua C functions (parts 10–12)

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z09-B59 | `cFindNearestMobList` FUN_005e6eb0, §18.5 | pushes the handles before `lua_checkstack` | more than about 20 matching mobs write past the Lua stack (LUA_MINSTACK 20): heap corruption | check first |
| Z09-B60 | `cGetTargetList` FUN_005f0e40, §18.5 | no `lua_checkstack` at all | more than about 20 targets overrun the Lua stack (as B59) | check the stack |
| Z09-B61 | `cFindNearPlayer` FUN_005f37d0, §18.5 | a classList value is popped only when it is non-zero | a 0 in the list stays on the stack and becomes the next `lua_next` key (Lua error or wrong walk) | always pop |
| Z09-B62 | `cRandomInt` FUN_005eed70, §18.1 | a range of more than 100 values (or max < min) always returns min (RandomRing has rings up to 100) | `cRandomInt(1, #PlayerAggroList)` (34 calls in 2016 scripts) returns 1 once a list has over 100 entries | a real random range |
| Z09-B63 | `cObjectCount` FUN_005e26c0, §18.5 | the count saturates at 200 (the scan buffer) | "more than 200 of a kind" reads as 200 | count without the buffer limit |
| Z09-B64 | `cObjectSound` FUN_005ea6f0, §18.6 (0x207A) | always copies 32 bytes of the name | bytes after a short name's NUL come from the Lua heap; a 32+ name is unterminated | bounded copy with NUL |
| Z09-B65 | `cMapMark*` (FUN_005df860, `cMapMark_FieldSight` FUN_005e0640), §18.6 | entries are written into the send buffer before the length is checked | a large mark table writes past the send buffer | check before writing |
| Z09-B66 | `cGetScriptString` FUN_005e8b30, §18.4 | unbounded `sprintf` into a 256-byte stack buffer | a long text or long script arguments overrun the stack | `snprintf` |
| Z09-B67 | `cIsMovable` FUN_005da9c0, §18.2 | the found-object test is skipped: a missing object returns 1 (movable) | scripts treat a vanished object as movable | return nothing for missing objects |
| Z09-B68 | `cObjectFind`, `cGetNearObjListByCoord` FUN_005f4ef0 and the other ByCoord function, §18.5 | the method (and for `so_mobile_GetIdxName` the value) string is not checked | a missing argument passes null to `strncpy` / the compare: crash | check the argument |
| Z09-B69 | `cNPCChatTest` FUN_005db4b0, §19.3 | `strcpy` of the text into a 256-byte stack buffer | a 256+ character text overruns the stack | bounded copy |
| Z09-B70 | `cNoticeRedWarningCode` / `cNoticeString` FUN_005e16e0, §19.3 | `strlen` / `so_ply_Notice` on a missing or non-string text slot | null text: zone crash as soon as the map holds a player | check the argument |
| Z09-B71 | `cSomebodyShout` FUN_005e5150, §19.3 | itemLinkDataCount (byte 0), speaker bytes 2…19 and flag bits 2…7 are never written | a stale non-zero count makes the client parse `count × 0x67` bytes of item links past the packet | zero the header |
| Z09-B72 | `cScriptMsg` FUN_005ebb40 / `_World` / `cSimpleChatScriptMsg`, §19.1 | always copies 32 bytes of the message index | stale Lua-heap bytes after a short index; a 32+ index is unterminated | bounded copy with NUL |
| Z09-B73 | `cScriptMessage` FUN_005dcbe0 family (0x6C15 [31], 0x6C12 [16], 0x6C11 [32]), §19.1 | `strncpy(…, n)` never writes the last index byte | an index of n+ characters keeps the shared buffer's byte; the client lookup fails unless it is 0 | write the NUL |
| Z09-B74 | `cCameraMove` FUN_005dbe30 (and the effect-timer twin), §19.4 | the "< 2" test is signed | a negative moveType is stored as the camera state and sent as 0x80…0xFF, which the client ignores | unsigned test / reject |
| Z09-B75 | message builders of §19 | each string length is stored as `strlen & 0xFF` and that many bytes are copied | strings of 256+ characters are cut to length mod 256 | reject or clamp to 255 |

### 29.4 Pine engine (parts 14a–14c)

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z09-B76 | `PineScriptReader` token readers, §20.3 | strings, numbers and names are appended to the 256-byte `tr_Buffer` without a length check | a 256+ character token overwrites `tr_BufPnt` / `tr_ErrCode` / `tr_Line` on `pes_Load`'s stack | length check |
| Z09-B77 | token reader comment rule, §20.3 | `;` starts a comment inside strings too | `"a;b"` loses `;b"` and the line end; the string continues on the next line (no 2016 script has one) | ignore `;` in strings |
| Z09-B78 | `pes_Load` FUN_004d6c40, §20.2 | `tr_ErrCode` is set but never read; a token error at top level reads as end of file | load errors report a line only; a bad token ends the file "successfully" and the rest is ignored | report the error, fail the load |
| Z09-B79 | `pst_GetNumber`, §20.4 | ignores a `-` | no negative numbers: `0 - 1` reads back as 1; `"-1" + 1` = `"-2"` | signed numbers |
| Z09-B80 | `Express::sa_Calculate` FUN_004d8640, §20.5 | no precedence, right-associative | `a - b - c` = `a - (b - c)`, `a * b + c` = `a * (b + c)` (2016 scripts bracket everything that matters) | usual precedence, left-assoc |
| Z09-B81 | concatenation / arithmetic on tokens, §20.4 | append to the 256-byte token without a length check | a 256+ character value overwrites the following stack / variable storage | length check |
| Z09-B82 | `vs_FindVariable` FUN_004d69f0, §20.6 | a missing variable returns the shared static `deftkn` | action nodes write results into it; later missing-variable reads see that value | fail the statement |
| Z09-B83 | `Term::sa_Load` FUN_004dbde0, §20.5 | a non-`(` token is not pushed back | a failed term eats one token; wrong where a caller treats it as "no further argument" | unget the token |
| Z09-B84 | `Statement::sa_Load` FUN_004d85d0, §21.2 | a failed candidate node is freed but `s_Statement` keeps pointing at it | the statement's destructor frees it again (double free), e.g. on reload (see B96) | clear the pointer |
| Z09-B85 | `StateAssignment::sa_Step` FUN_004db110, §21.5 | the expression is computed straight into the target variable | `X = 1 + X` reads the partial value 1 for X (gives 2) | compute into a temporary |
| Z09-B86 | `Statement::sa_Step` FUN_004d8250 / `Block`, §21.4 | `b_VarStackPoint` belongs to the block, not to the stack entry | a block on the stack twice (recursion) loses the outer run's variable mark; both restore the inner one | store the mark per stack entry |
| Z09-B87 | `StateIf::sa_Load` FUN_004de670, §21.5 | an `if` without `then` drops the true branch | the block after it runs always | require `then` / error |
| Z09-B88 | node deletes (§21.2), `List<Block>::l_Enlargement` FUN_004e13b0 | nodes are freed without their destructors; the list enlargement leaks the old array | memory leak per failed candidate and per unloaded script | virtual destructor / free the old array |
| Z09-B89 | `@Random` `SysFuncRand` FUN_004d77d0, §22.2 | `a + rand() % (b − a + 1)` without `b ≥ a` | `b == a − 1` divides by zero (zone crash); `b < a − 1` gives values ≥ a | check the range |
| Z09-B90 | `@RestSec` `SysFuncShineRestSecond` FUN_004e42e0, §22.2 | `tl_IsActiv` not tested; unsigned subtraction | without a limit or after it ran out the result is about 429 million instead of 0 | 0 when inactive / expired |
| Z09-B91 | KQ score functions (`alkqr_CalcScore` FUN_004e2f80, `zerosumWorker` FUN_004e55d0), §22.3 | score = 0 when the sum is negative, then overwritten with the sum (zerosum has no clamp) | negative KQ scores stay negative | keep the clamp |
| Z09-B92 | `@Range` `SysFuncShineRange` FUN_004e72b0, §22.2 | no length check of the result token | more than about 50 values overrun the 256-byte token (unused in 2016) | length check |
| Z09-B93 | `@Range` FUN_004e72b0, §22.2 | `to < from − 1` gives a negative vector size | `std::length_error` / `bad_alloc` thrown inside a script step | check the order |
| Z09-B94 | `BroadcastCode::sa_Step` FUN_004f7ae0, §22.4 | the handle form needs two arguments but the node registers max 1 | a statement with a handle never loads; the handle branch is dead | allow 2 arguments |
| Z09-B95 | the six `@mobregen`-family builders, §22.2 | the second free is `List::l_Free` on `shineobjmanager`'s 13-entry base list with the handle as index | a no-op (or an unrelated unlink for handles 0…12 *(inferred)*); doors stay allocated and unbuilt until the pool walk reclaims them | the pool free |
| Z09-B96 | `ScenarioBookShelf::sbs_Read`, §22.5 | ignores `sb_Load`'s result; a failed Pine book only asserts | the zone keeps a half-loaded book with B84's dangling pointer: double free at its next `sbsReLoad` | fail like the Lua path |

### 29.5 Pine action nodes, films, sweep (parts 15a–17d)

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z09-B97 | `ShineChange2Mob::sa_Step` FUN_004ed1e0 / `ShineChange2NPC` FUN_004ed4c0, §23.2 | after a failed regenerate the object is freed a second time | the second free only logs (no damage) | one free |
| Z09-B98 | change2mob / change2npc / change2door (`os_ObjectChange`), §23.2 | on a non-bandit a second object is built at the old one's place; the old one is never removed | both objects stay; the script loses its handle to the old one | free the old object first, as `exchange2mob` does *(inferred)* |
| Z09-B99 | `ShineChange2NPC::sa_Step` FUN_004ed4c0, §23.2 | tests the **new** pool-4 object for bandit | dead check (a pool-4 object is always an NPC) | test the old object |
| Z09-B100 | `ShineChatWindowRange::sa_Step` FUN_004f5520, §23.5 | reads argument 2 as the range; argument 1 is never read | the range is the mob name's number (0 for names) *(inferred)*; 25 uses in 2016 books | argument 1 = range |
| Z09-B101 | `ShineBattleStart::sa_Step` FUN_004f3cb0, §23.6 | `battlestart guild`'s 0x7483 bytes 8–13 (`nGuildTourNamentType`, `nGuildMyRegNumber`) are not written | stale send-buffer bytes | fill them |
| Z09-B102 | `ShineItemDrop::sa_Step` FUN_004eff00, §24.1 | a failed roll returns 1 without pop | the node retries every pass until it drops; a rate ≤ 0 stalls the film for good | pop after one roll |
| Z09-B103 | `ShineItemErase::sa_Step` FUN_004f0570, §24.2 | `os_ShineObject` result used without a null check | handle 65535 (object gone) crashes the zone | check the object |
| Z09-B104 | `ShineItemOwner::sa_Step` FUN_004f4ec0, §24.3 | compares the stored 0xFFFF with 0xFFFFFFFF | the unknown-item check is dead; the walk runs for item 0xFFFF and finds nothing | compare with 0xFFFF |
| Z09-B105 | `ShineExchange2Mob::sa_Step` FUN_004ed650, §24.5 | frees the old object before the new one is ready | on any later failure neither object is left and the variable holds a freed handle; three failures also leak the new mob slot | build first, then free |
| Z09-B106 | `ShineGuildTorunamentResult::sa_Step` FUN_004f6290, §24.8 | without a GT system the four A/B fields of 0x74E2 keep old send-buffer bytes | stale result fields on clients | zero them |
| Z09-B107 | `ShineItemAttrSet` FUN_004f37a0 / `findplayer`, §24.2 / §24.4 | an argument evaluated into the shared buffer is used without checking the result | a failed argument passes the previous token (unused in 2016) | check the result |
| Z09-B108 | `DiceGameStart` node, §24.8 | without a GT system returns 0 without pop | the film ends | pop and continue |
| Z09-B109 | `ShineQuestMobkill::sa_Step` FUN_004f8270, §25.6 | the per-player repeat count is capped by the number of players on the map | fewer kills credited than `count` when few players are on the map | cap by `count` only |
| Z09-B110 | `ShineMobRegen::sa_Step` (copy branch) / `sbr_MakeBeggar` FUN_004eb630, §25.1 | a mob / NPC / door handle reaches the 0xEB-byte brief copy, whose source (vt 0x6d0) is null for them | zone crash | player handles only |
| Z09-B111 | `ShinePlayerWalk::sa_Step` FUN_004f6d40 and `collect`, §25.2 / §25.4 | argument results not checked | a failed y keeps the token of x (walk to x, x) | check each argument |
| Z09-B112 | `ShineSomeoneShout::sa_Step` FUN_004eeeb0, §26.2 | itemLinkDataCount (byte 0) never written; u8 text length | as B71 (client parses links past the packet); 256+ texts wrap | zero the header, clamp |
| Z09-B113 | `ShineSuicide::sa_Step` FUN_004f1980, §26.4 | the unknown-name assert does not return | the walk runs with id 0xFFFF and kills every mob of the map | return after the assert |
| Z09-B114 | `waitidle` node, §26.5 | the target object is always null (no target argument) | `waitidle` never waits and asserts every time (no loaded 2016 book uses it) | resolve a target (the boss) |
| Z09-B115 | `AxialListTeleport::ali_Work` FUN_004286e0 (`teleportall`), §26.4 | the "anywhere" and "x y" forms test the walker's kind (the centre flag), not the visited object | those forms teleport nobody; only "split" works | test `o` |
| Z09-B116 | `ShineTimeLimit` / `ShineScriptFile::sa_Step`, §26.5 / §26.2 | a failed argument returns 0 | the film ends | assert, pop and continue |
| Z09-B117 | `ShineEndOfKingdomQuest::sa_Step` FUN_004f5fc0, §26.1 | the "Invalid Shine Quest" assert does not return | WM still gets 0x5810 NC_KQ_Z2W_END_CMD { Handle = −1 } | return |
| Z09-B118 | `ShineSpawn::sa_Step` FUN_004f7eb0 and other optional slots, §26.3 / §26.4 | optional argument slots dereferenced without a null check (`spawn` with 1 argument, `teleport` with < 3, short `teleportall` forms) | null expression → zone crash when the node steps | check the slot |
| Z09-B119 | `Movie::CinemaComplex::cc_PlayFilm` FUN_005089a0, §27.2 | for an unknown book (or type 0) cell i stays allocated | lost film slot; a later drop of it crashes on a null film | free the cell |
| Z09-B120 | `Movie::TimeLimit` `tl_IsActiv`, §27.4 | written, never read | in a film without `timelimit`, `TimeOut` fires at a time left over from the cell's previous film (or uninitialised) and broadcasts 0x0810 with it (every 2016 `TimeOut` book sets a limit) | test `tl_IsActiv` |
| Z09-B121 | `so_AllOfRangeMiniHouse` (member-function form) FUN_00554100, §28.1 | empty stub | on a mini-house map every member-function range call reaches nobody | implement like the other forms |
| Z09-B122 | mini-house member walk, §28.1 | runs from slot `5 − EnterGMCount` to `EnterPlayerCount − 1`; `so_mh_Enter` FUN_00543cb0 fills players from 0 up, GMs from 4 down | with no GM inside walks reach only the caller; with GMs some members are skipped | walk 0…players−1 and 5−GMs…4 |
| Z09-B123 | `SpyNet` agent constructor, §28.2 | fills 16 slots with `SRT_GETHEAL`, no `SRT_EOR` | every analysis pass for a never-healed target reads 16 null reports and logs "Cannot found EOR" (log spam, no aggro change) | `ea_Clear` in the constructor |
| Z09-B124 | `ExpandSkill` reader (`MiscDataTable`), §28.3 | a `Skill` word that is itself a skill name advances the record counter twice | the next record is skipped (latent: no 2016 base name is a skill) | advance once |
| Z09-B125 | `ORTable::ort_ReadData` FUN_006480a0, §28.6 | "Undefined command" stops reading but `ok` stays true | `or_Read` reports success for a truncated table | return false |
| Z09-B126 | `ShineMob::so_GainHP` FUN_00556a00 (vt 0x504), §28.8 | caps HP at `so_GetHP` (current HP) instead of `so_MaxHP` | the cap never applies; a mob's HP can pass its maximum (latent: only `RecoverTypeEffect::_execute` FUN_005cfc70 heals through it) | cap at MaxHP |
| Z09-B127 | `CardDeck::CardStack::cs_Suffle` FUN_0064e200 from `ItemGroupClassifier::igc_Getitem` FUN_004903e0, §28.10 | shuffles before the empty-group check; with 0 cards it computes `rand() % 0` | integer division by zero → the minidump handler ends the zone (§30.1) (latent: needs an item group without items) | check the card count first |
| Z09-B128 | `sp_NC_ACT_GATHERCOMPLETE_REQ` FUN_0046cbf0 (0x2032), §11.2 | clears the gather timer and calls `sp_GatherComplete(p, 2)` without checking how long the gather has run | a client can finish every gather at once after 0x202E (and gets lots × 2 for resource types 8/9/10, the factor of the client-side completion) | reject 0x2032 before the gather time has passed |
| Z09-B129 | `DropItemListForSpecies::dilfs_DropByRate` FUN_0048e920, §11.2 | the rate roll compares `(uint)rand(1000000) < (uint)(sum × DrItemR / 1000)`; a negative sum becomes a huge unsigned bound | latent: an abstate actor's negative drop rate or a `cec_ItemDropRate` far below 1000 would make every entry drop instead of none (the 2016 map rate 1000 keeps the sum ≥ 0) | signed compare / clamp the sum at 0 |
| Z09-B130 | Lua `cIndunRankResult` FUN_005ee4d0, `cSendRankingList` FUN_005eaee0, `cScoreTopList` FUN_005ec1f0, `cScoreResultList` FUN_005ec6a0, §28.12 | copy a script table into fixed buffers without a count limit: 0x30-byte entries into a 4 KB stack buffer (> 85 entries), 20 per ranking list (the 21st Previous entry lands in Current[0], Current beyond 20 past the 1000-byte payload), a local u16 handle array (ebp−0x50), a u8 count | latent (scripts pass party / ranking lists; no 2016 script calls three of them): a long table overwrites the stack (cookie check → the zone ends, §30.1) or sends wrapped counts | cap the count at the buffer size |
| Z09-B131 | `CLCReward::clcr_GetRandomLCRewardData` FUN_0049cbc0, §28.13 | the cumulative rates are integer quotients `rate × 1e6 / total`; when the roll exceeds their sum (rounding, or rates that do not add up to the listed total) the loop ends on the last group of the whole table | a capsule can open with the content of another capsule (the last LCGroupRate row), rarely with consistent data | take the last *matching* group, or compare against the exact sum |

---

## 30. Not reconstructed / uncertain

Collected from the "open points" subsections of §6–§28 (items answered later, in §21.8 / §22.7 / §23.9 / §24.9 /
§27.7 / §28, are left out) and the "not traced" notes inside the pseudocode. Smaller *(inferred)* marks stay where they
are; the bug consequences marked *(inferred)* are listed in §29. Items that belong to another item's code are only
named here; §31 gives their owners.

### 30.1 Answered in this part

- **Z09-B7: does the zone survive a fault?** No. The only exception trap is the process-wide filter
  `MiniDumper::TopLevelFilter` FUN_0064e810 *(pdb2016)*, installed by `MiniDumper::MiniDumper` FUN_0064eb00
  (`SetUnhandledExceptionFilter`). It loads `DBGHELP.DLL`, writes `<exe>_<time>.mdmp` with `MiniDumpWriteDump` and
  returns 1 (`EXCEPTION_EXECUTE_HANDLER`) on success, 0 otherwise: either way the process ends. Every "crash" in §29
  (B7, B70, B89, B103, B110, B118, …) stops the zone and leaves a minidump. `EHConvertSimpleException` FUN_00654060
  (exception code → name, e.g. "EXCEPTION_ACCESS_VIOLATION") is the CRT's text helper. Still open: why 2016 servers did
  not crash on B7 (whether any of the 288 non-Karen sequence mobs ever reaches the advancing select; not traced per
  tactic).

### 30.2 Main loop, player tick, mob core (§1, §2, §5)

- §1.1: the two per-tick caches reset each pass (`ShineObject::so_CostumWeaponChargeing` / `so_CostumShieldChargeing`,
  item SerialNumber = −1): their readers were not traced (costume weapon charging is item code).
- §1.5: the session pools' keep-alives FUN_005aae80 / FUN_005ab2c0 polled by `zs_disconnect` were not opened (Z01's
  session layer).
- §2.4: the meaning of the party record's first byte (`+0x29244 < 2`) in `sp_SendPartyMemberInform` FUN_0056e340.
- §5.5: the tick argument of the routine thunk was not traced further.

### 30.3 Spawns and drops (§10, §11)

- §10.11: whether a pool handle can be reused by another object before the 1-s regen tick sees the death (which would
  delay that breeder) depends on the pool's reuse order; not checked.
- §10.11: breeder members `+0x60` (bandit) and the timestamps `+0x4c` / `+0x50` are not set by the ctor or `mb_Set`;
  file breeders rely on zeroed hatchery memory *(inferred)*. Arguments 5, 12, 13 of `mh_MobBreed` and the `mbg_RegenLoc`
  out value are unused; the group key "Def" is stored and never compared.
- §11.9: how `ItemAttr` vt 0x2c turns MinQtty / MaxQtty and the `Upgrade00…15` weights into lot and upgrade (Z04's
  item model); the same for the synthetic row of Pine `itemdrop` (§24.9: MinQtty = MaxQtty = 1, no weights; whether
  it reads the uninitialised InxName bytes).
- §11.9: `dropitemanalyzer` (DAT_0cf15b40, 256 buckets × 500 `{mobId, itemId, count}`) has no reader in the zone; the
  drop object's `+0x204` (flag 1 from `so_IsDropping`) is never read by the drop functions found.
- §11.2: whether the lot factor 2 of a client-completed gather (0x2032) against 1 for the server timer is meant (B128).

### 30.4 Movement, sight, world objects (§9, §12, §13, §27)

- §9.8: `MainChar+0x20 / +0x2c` (the client's 0x2049 guard) and player byte `+0x7f36` (cleared by pushes) are not
  identified; the meaning of `GetParam()+0xcce` bits 0 / 1 (which abstates set them) is Z03 §6.
- §27.7: the 0x1C08 layout a boss sends through `so_BroadcastBriefInfo` to players outside its sight, and whether the
  client keeps such a far object (C01 / Z02 §5).
- §26.8: whether a `sublayershift` without `logout` leaves stale objects on clients (sight refresh, Z02 §5).
- §12.8: which SubAbState kinds use the "MagicField" actor and how often its `sasa_Routine` runs (Z03 §6.1); the client
  byte `+0x213 == 0x42` / vt 0xd4 in `On_NC_BRIEFINFO_MAGICFIELDSPREAD_CMD` (a caster animation) was not traced;
  `almfd_BattleField` / `slmfd_GuildWarMap` are filled and never read (maybe a planned guild-war rule).
- §13.4: the `namestring` copy in `bixd_Exchange` (receiver's name into a ring) has no reader (leftover debug code).

### 30.5 Script infrastructure and Lua functions (§14–§19)

- §14.10: `RankingValue` (map event 0xac): no 2016 script sets it, so the intended meaning of its three values is read
  from the call sites only (B39).
- §14.10: `cTimer_Obj` sends through the player's data stream (vt 0x2f8), the other timer functions through the game
  stream (vt 0x2fc); what separates the streams is Z01's. `cmc_AllowMode` 0x78 refuses player modes 3–6; the mode names
  are Z02's.
- §15.9: `so_AllInMap1`'s last argument (0 for area requests, 1 for the counters) is passed to the map's
  `fm_fp_AllInMap2` broadcast function; its meaning was not read.
- §16.9: whether a hit on `DT_RadionOre` ever meets its `AttackMob` observer (B49) depends on the walk order of the ore
  and the player in the same tick; not traced.
- §17.9: whether a 2016 script animates a player with `cAnimate` (the player's own client would not get 0x2074) was not
  checked. `cSetAbstateInArea`'s range is `BMPInfo.AreaCenter_X`: bitmaps whose centre is not their half size reach only
  part of the bitmap *(inferred from the member order)*. View-slot storage across logout for `cViewSlotEquip` is Z05 / Z07.
- §19.6: which `TextData` / sound a `cEffectMsg` type plays (client `EffectMsg` table); whether a 2016 client dialog
  opened by `cNPCMenuOpen` answers with 0x2073 or 0x201D (client NPC dialog code, C01).
- §28.12: which client window FUN_0048cf00 opens after 0xA412 (the client names file calls it `OpenKDTeamScoreWin`, but it
  shows the `PartyScoreWin` of +0x1424); `KDTeamScoreWin::SetRound` takes no visible round argument (C01).

### 30.6 Pine engine and action nodes (§20–§26)

- §21.8: whether a handler block reached through `call InterruptBlock.` can re-enter a block already on the stack
  (B86) depends on each book's interrupt targets; not traced per book.
- §23.9: keep times above 2³¹ − 1 (`4200000000`, `4000000000` in `JobChange1.ps`, `GordonMaster.ps`, `Monkey.ps`) pass
  `pst_GetNumber` (`int`) with the same 32-bit pattern; whether `so_AbnormalState_Set` (vt 0x638) reads them as
  unsigned (about 48 days) or negative was not traced.
- §23.9: `chatwin` / `chatwinrange` `sprintf` into the global send buffer before the `< 256` check: the buffer capacity
  (`gpp.pp_BufferSize`, set statically) and a dialog string with more `%s` than values (stack garbage) were not traced.
- §24.9: `som_FindPlayer`'s name comparison (case, which player list) for `findplayer`; `iac_itemcreate`'s parsing of
  the `itemattrset` attribute string (Z04 / Z05).
- §25.8: whether the bandit's `sm_LoginLoc.currentcoord` (the copied brief coordinate, garbage for a beggar) is read
  anywhere (no reader found by member name).
- Owned by other items and not traced here (§24.9, §25.8, §26.8): `GuildTournamentSystem::EndBattle` / `Clear` /
  `FlagRegister` / `GateRegister`, `DiceGame::Start`, `ShinePlayer::sp_KQReward`, `so_ply_KQRewardStruct`,
  `kqcl_GetMobKill`, the bounds of `guildtournamentinfo` (slot 255 written by `fm_GuildTournamentClear` when the seed is
  not set) (Z16); `QuestPlayer_ScriptMobKill(_All)`, `CQuestZone::PsEnd`, `QuestPlayer_ScenarioDone_Server` (Z15);
  `CT_KQSuccess` / `CT_KQFail` (Z07); other setters of `sp_SetRollBackPosEvent` (`wms_NC_CHAR_ZONE_LINK_FROM_CMD`
  FUN_00476600, Z08); the wedding-hall registration `weddinghall.Groom` / `.Bride` (Z13).

### 30.7 Not reconstructed on purpose

- `CFindWay` (§28.7): the old path finder has no caller in 2016; its algorithm is summarised, not written out.
- `MobBehaviorDescript/` (`DefaultBehavior.ps`, 7 `KQ/*.ps`): no zone code reads the folder (§20.1); the files are not
  documented.
- `sdc_Setsixpoint` FUN_004607f0 (drop-spot rings, §11): only its use is described; the point placement inside was
  not written out (cosmetic).

---

## 31. Coverage boundary

Everything this item reached but does not document, with the item that owns it. "Plan line" = the line of
`docs/plan/items/<ID>.md` whose scope includes the thing.

### 31.1 How the boundary was checked

Gap check (part 17d, scratch script on `coverage.py`'s `Bin` / `cited`): roots = every `FUN_` cited in this file,
depth 1, `coverage.py`'s TINY / HUB / registered filters, "covered" = cited by any zone doc. Result before part 17d:
**612 functions / 23.3 k lines**. 89 of them are Z09's own classes and are now in §28.10 / §28.11 (the re-run found 8
more helpers one level further; also added there). The other **523 functions / 21.1 k lines** are below, by owner; a
re-run with §1–§30 as roots finds exactly these 523 and nothing else. Their addresses are written without the `FUN_`
prefix (as in §14.9) on purpose: `coverage.py` counts a `FUN_` citation in any zone doc as covered, so the owners' own
gap lists keep showing them. (Taking §31's functions as roots too would reach 262 more, one level inside those other
items: their code, not a Z09 gap.)

Part 18 (review) re-ran the check in a stricter form: "covered" = cited in a **pseudocode** doc (knowledge files no
longer count, because a knowledge-file citation had hidden `sp_MakeCapsuleItem` (C02.md) and `mdb_2mapid` (Z01.md)).
It moved six functions out of this section into §28.12 (the hunt log `MobHuntLog` / `mhl_SendAll2Log`,
`cIndunRankResult`, `cScoreInfo`, `cScoreInfo_AllInMap`, `cSendRankingList`: their plan lines did not name them) and,
because their owners Z01 / Z05 / Z07 / Z08 were already finished, the seven small leftovers of those items into §28.13
(capsule creation, class change sends, charged-effect lists, guild-war request, party default slot) plus the three
tutorial Lua functions (Lua C functions are Z09 scope, as in §28.12); the helpers they
reach (`CommonList` / `l_MakeList` forms, `clcr_GetRandomLCRewardData`) are documented there too. Result with §1–§30 as
roots: **509 functions / 20.2 k lines**, exactly the 509 of this section. Counts per owner: library code 146 (STL 120,
Lua 16, CRT 10), Z01 74, Z03 53, Z04 49, Z13 47, Z16 38, Z02 29, Z15 23, Z14 18, Z07 9, Z17 8, Z06 7, Z12 4, D05 3
(already documented in `D05-gamelog.md` §4.4; the zone check reads zone docs only), Z11 1. No function is left without
an owner whose plan line includes it, so no follow-up item is proposed. **Owners already finished** (Z01, Z02, Z03, Z04,
Z06, Z07: 221 functions + 0x2442 / 0x2443) will not reach these through their own gap lists: their follow-up list is
`docs/knowledge/Z09.md` §3 (one short session per owner).

### 31.2 Functions of other items

| Found (functions) | Covered by | Argument |
|---|---|---|
| Player login, links and save: `ShinePlayer::<unnamed-type-sp_Item>` constructor 00549820; `ShinePlayer` sp_ConnectFromWhere 0043f1f0, sp_GhostBan 0043f3d0, sp_KeepFromDoubleLogin 0043cc90, sp_LoginInit 00440d80, sp_NextSaveExperience 0042d6f0, sp_RegistNumberVarification 00551950, sp_RemoveField 00440b40 | Z01 (plan line 9: "the ShinePlayer lifecycle … map login … map links … logout and character save") | callees of the player functions this file cites (§2, §17.7, §28.8; `sp_GhostBan` from `sp_NC_MAP_LOGINCOMPLETE_CMD`); they run the player's login, double-login guard, field removal on a link and the save timer, not world simulation |
| Object handles: `ShineObjectHandleUnion` sohu_SetAxialHandle 00548ec0, sohu_SetBanditHandle 00548ef0, sohu_SetDoorHandle 00548fb0, sohu_SetDropItemHandle 00548e90, sohu_SetEffectHandle 00548f50, sohu_SetMiniHouseHandle 00548e60, sohu_SetMobHandle 00548e00, sohu_SetMoverHandle 00549010, sohu_SetNPCHandle 00548f20, sohu_SetPetHandle 00549040, sohu_SetPlayerHandle 00548e30, sohu_SetServantHandle 00548fe0 | Z01 (plan line 9: "object handles and the object class hierarchy") | the handle allocator per object class; Z09 only uses handles |
| Network and sessions: `CPacket` GetWriteDataPtr 00650280, GetWriteableBufferSize 00650270; `CServerInfo` GetServerInfo 0064d420, ReadServerInfo 0064d0f0; `CSocket_Acceptor` GetAccepted 00652980; `CSocket_IOCP` Close 0064f690, CloseUseIOCP 0064f5f0, Receive 0064f410, Shutdown 0064f530; `ClientSession` Send_NC_MISC_SEED_ACK 0045b120, cs_GetRawIPAddress 0045b1c0, cs_SetActiveTimeToCurrent 0045b1a0, cs_SetBoolClosingSession 0045b1e0, cs_SetSessionMode 0045b180; `ClientSessionManager` csm_AddClientSessionToIPGroup 0045c720, csm_RemoveClientSessionFromIPGroup 0045c620; `OPToolObject` opto_SetSocketSession 004c7d40; `OPToolSession` opts_ActivSession 004c7db0, opts_ConnectReady 004c7d60; `ProtocolPacket` pp_NetCommand 00401280; `ShineObject` so_FirstActionAfterSocketConnect 0054b670; `ZoneBaseSession` CheckHeartBeat 005a67c0, Connect 005a68b0, Socket_Register_To_IOCP 005a6700; `ZoneBaseSessionManager` ProcHeartBeat 005a6a40; `ZoneIPContainer` zipc_Store 005a9640; `ZoneServer` zs_GetServerGroup 005a9950, zs_Getportinfo 005a9960, zs_mechineinfo 005a9910 | Z01 (plan line 9; title "player session"; Z01-core §10 has the session classes and OPTool §9) | socket, IOCP, heartbeat and session bookkeeping reached from the main loop's session polling (§1.5) |
| Diagnostics and logging: `AssertClass` operator() 00401110; `DebugLogging` dl_MakeFileName 00419100; `FunctionEntarance` FunctionEntarance 00402880; `FunctionProfiler::PerformanceRecorder` pr_Report 004680d0; `GetCurrentTimeString2` 0064f110; `MiniDumper` MinidumpCallStack 0064e5f0; `ProtocolLogger` pl_Clear 005528a0; `StringMaker::Maker` `operator<<` 0058dd40, `operator<<` 0058dcb0, `operator<<` 0058de10, `operator<<` 0058dc10, `operator<<` 0058dfd0 | Z01 (plan line 9: "startup", the process skeleton; Z01-core §2) | profiler, assert, file logs and the minidump writer (§30.1 cites only its exception filter); shared by every item |
| SHN boxes and fixed strings: `BinaryDataBox<GradeItemOption>` bdb_ReadData 00648bd0; `BinaryDataBox<MapInfo>` bdb_ReadData 0064eb40; `MapBuffDataBox` mbdb_GetModeIDLvType 00462870; `MapDataBox` operator[] 00419440; `Name3` Name3 00418e00, operator!= 00401000, operator= 00418e30; `Name4` Name4 004566e0, operator= 0049ad00, operator== 004d1f90; `Name8` Name8 00418e50, operator= 00427de0; `NameString` operator[] 0045b060 | Z01 (plan line 9: "SHN data loading (list every table and its loader)") | the generic `BinaryDataBox<T>` loader and the `Name3/4/8` string types; the tables' contents belong to their users |
| Brief info: `BriefInfoBackup` BriefInfoBackup 0043c9b0, bib_Restore 0042ab20; `BriefInfoExchanger::BriefInfoExchangeAbstate` bixa_Exchange 00440510, bixa_Init 0043c6b0, bixa_Send 0043df50; `BriefInfoExchanger::BriefInfoExchangeAll` bixall_Init 0043d500; `BriefInfoExchanger::BriefInfoExchangeItem` bixi_Exchange 004401a0, bixi_Send 0043da30; `BriefInfoExchanger::BriefInfoExchangeMiniHouse` bixmh_Exchange 004403e0, bixmh_Send 0043dc90; `BriefInfoExchanger::BriefInfoExchangeMob` bixm_Exchange 0043fe40, bixm_Init 0043c630, bixm_Send 0043d6a0; `BriefInfoExchanger::BriefInfoExchangeMover` bixmv_Exchange 00440690, bixmv_Init 0043c810, bixmv_Send 0043e0d0; `BriefInfoExchanger::BriefInfoExchangePet` bixp_Exchange 004407d0, bixp_Init 0043c8a0, bixp_Send 0043e200; `BriefInformationCharacter` BriefInformationCharacter 00549090, bic_SetAnimation 0043c250; `BriefInformationMob` BriefInformationMob 00549120; `PROTO_NC_BRIEFINFO_BUILDDOOR_CMD` operator= 00555af0; `PROTO_NC_BRIEFINFO_EFFECTBLAST_CMD` operator= 005553d0 | Z02 (plan line 9: "object appear/disappear (BRIEFINFO: what other players see)") | the per-kind brief-info exchange is Z02's sight protocol; §9.6 only documents when Z09 objects enter or leave sight |
| NPC menus and chat ban: `ServerMenuActor` ServerMenuActor 0050ec70, sma_SetPlayer 0050ecb0; `ShinePlayer` so_SetSpamerChatBan 00560a20, sp_ServerMenuItem 0054e990, sp_ServerMenuTitle 0054e8a0 | Z02 (plan line 9: "chat types …, NPC click/menu flow") | the server-menu actor behind Lua `cServerMenu` (§14.6 documents the script side) and the spam chat ban |
| Abnormal states: `AbnormalStateContainer::AbnormalStateElement` ase_AttachObject 00401d40; `AbnormalStateContainer::AbstateElementInObject` aeo_CompName 004065c0, aeo_GetAbstateElement 004067b0, aeo_GetCaster 00401b90, aeo_GetRestTime 00408990, aeo_GetStrength 004011e0, ~AbstateElementInObject 00401b20; `AbnormalStateContainer::AbstateListInObject` AbstateListInObject 0040cf10, asl_Check_SameAbstate 0040c180, asl_GetAbstateList 00401250, asl_IsHereBad 0040ad40, asl_IsHereGood 0040abb0, asl_SendAfterLogin 0040aed0; `AbnormalStateDictionary::AbState::AbStateStr::AbStateStrArgument` assa_IsHaveEffect 00416190; `AbnormalStateShelter::AbstateBuffer` ab_Recover 00417ef0; `AbnormalStateShelter::AbstateShelter` as_Remove 00417520, operator[] 00418890; `ListTraveler<AbnormalStateContainer::AbstateElementInObject>` lt_Next 00402740 | Z03 (plan line 9: "abstates (buffs/debuffs, AbState.shn, SubAbState.shn)") | the abstate container and shelter; Z09's Lua / Pine functions only call `so_AbnormalState_Set` and the queries (§17.4) |
| Skills, attacks and target scans: `AxialListNearScanSkillEnemy` AxialListNearScanSkillEnemy 0057e1a0; `AxialListNearScanSkillEnemyUser` AxialListNearScanSkillEnemyUser 0057e420; `AxialListNearScanSkillFriend` AxialListNearScanSkillFriend 0057e360; `AxialListNearScanSkillParty` AxialListNearScanSkillParty 0057e260; `AxialListScanSkillTarget` AxialListScanSkillTarget 0057e0f0, alsst_MakeRandomTargetList 0057e4e0, alsst_SetAttacker 005793b0, ~AxialListScanSkillTarget 0057e320; `BattleObjectGroup::BattleObjectList` bol_Store 00434ee0; `BattleObjectGroup::BattleObjectStruct` BattleObjectStruct 00434bb0; `BattleStat` bs_Clear 0043be00; `CharacterPassiveList` CharacterPassiveList 00447200; `CharaterSkillList` CharaterSkillList 00447eb0, csl_EmpowerSummary 00445070; `DamageByAngle::DamageTable` operator[] 0045c9a0; `DamageBySoul::SoulDamageContainer` operator[] 00434db0; `FanFormSectorArgument` FanFormSectorArgument 0057bda0; `MultiHitArgument` MultiHitArgument 00434b30, mha_SetAbState 00434de0; `MultiHitData::MultiHitTable` operator[] 004c0a90; `NormalAttackDamageDelay::NormalAttackDamageTick` NormalAttackDamageTick 00577cd0, nadt_Clear 00577e30; `ShinePlayer::TimeScheduler` TimeScheduler 005697c0, ts_IsInNormalAttack 0042abb0; `ShinePlayer` so_ply_setSwingTime 00560ae0, sp_HPChangeCheck 0055e130, sp_IsNormalAttack 00560230, sp_SkillShiftCancel 0057bcd0, sp_SkinPolymorph 004a3280; `SkillDataBox` sdb_SpecSkillStruct 0046a410; `SkillEffectApply::SkillBlastEffect` SkillBlastEffect 00434c60; `SkillEffectApply::SkillBlastEffectContainer` sbec_ListCheck 004358a0; `SkillEffectApply::SkillDamageSender` sds_Initialize 00437ba0; `SkillEffectApply::SkillEffectEraser` ~SkillEffectEraser 00437c40; `learnSkill` 005a1790 | Z03 (plan line 9: "Attack flow (basic attack, skill cast/bash …), target validation … damage formulas") | skill target lists, multi-hit, blast effects, attack timing, skill lists and `learnSkill` (Lua / GM learn); the mob side that calls them is §7–§8 |
| Items, equipment, set items, random options: `BinaryDataBox<ItemInfo>` bdb_ReadData 00648a50, operator[] 004ae550; `BinaryDataBox<ItemInfoServer>` bdb_ReadData 00648b10; `BinaryDataBox<ItemMoney>` bdb_ReadData 00648df0; `BinaryDataBox<ItemSort>` bdb_ReadData 00648ca0; `CSellItemManager` CSellItemManager 0050eb60; `EquipEnumChanger` eec_ConflictWithNewEquip 004611c0, eec_ConflictWithNewViewSlot 004616c0, eec_ConflictWithOldEquip 00461360, eec_ConflictWithOldViewSlot 00461840, eec_EquipLocation 00460ff0, eec_GetEquipSlotList 00461590; `InventoryLocking::InventoryCellLockList` icll_ClearItem 00440d20; `ItemAccountStorage` ItemAccountStorage 00644910; `ItemBag` ib_GetItemLot 00642e80; `ItemBoxIterEmpty` ItemBoxIterEmpty 0043c050; `ItemDataBox` idb_GetItemInxName 006487d0, idb_iter_Get 004900c0, idb_iter_next 004900a0; `ItemEquipment` ie_DecoActList_Insert 00643940, ie_ViewSlot_Clear 00643660, ie_ViewSlot_GetItemID 006437b0, ie_ViewSlot_Set 00643630, ie_ViewSlot_UseCheck 00643750; `ItemInform_ActionItem` sii_Export 00643440; `ItemLotInspector` ItemLotInspector 00490be0, ili_Clear 00490c30, ili_Reset 0043bf90; `ItemRandomOption::RandomOptionTable` operator[] 00493ff0, rot_FillOption 00493590; `ItemRewardStorage` ItemRewardStorage 00644c20; `ItemTotalInformation` iti_clear 00470cf0, iti_fill2buffer_whole 006407d0; `Item_AdjFailCount` 0053b700, `Item_AdjUpgradeLevel` 0053b560, `Item_GetUpgradeLimit` 0053b2a0, `Send_SETITEMHEALEFFECT` 005cfbb0; `SetItemData::EffectDescription` ed_Compare 004a2ed0; `SetItemData::SetItemAbstateEffect` SetItemAbstateEffect 00510350; `SetItemData::SkillEffect` operator[] 00510010, se_Clear 005105e0; `ShinePlayer` sp_GetAutoPick 00560370, sp_GetItemWhoEquip_ClassGroup 005630f0, sp_ItemInvenDelete 0051c590, sp_ItemUseBroadcast 0053f840, `sp_SmallItemDelete<ItemInform_ActionItem>` 00569b80; `UseEffect::UsedItemEffect` operator[] 004878e0, uie_SetChargedBuffer 005963e0, uie_UseSkillID 0059cba0 | Z04 (plan line 9: "Inventory model …, equip/unequip, use item, drop/pickup, enchant/upgrade … RandomOption") | reached from drops (§11), treasure chests (§10.10) and the Lua / Pine item functions (§17.8, §24.2); the item model itself is Z04's (view-slot persistence: Z05) |
| Trade, booths, gambling: `BoothManager` BoothManager 0043b550, operator= 00467500, ~BoothManager 0043b620; `CGambleObject` go_Get_MaxEnterPlayerCnt 00591ff0; `StreetBoothBuy` StreetBoothBuy 0058f390; `StreetBoothSell` StreetBoothSell 00590580; `TradeBoard` TradeBoard 00427ee0 | Z06 (plan lines 15 / 17: TRADE, BOOTH, GAMBLE) | constructors reached through the player object |
| Titles: `CCharacterTitleDataStateServer` GetStateData 005ca9b0; `CCharacterTitleZone` CCharacterTitleZone 005ca5c0, ctz_SetObject 005ca610; `ShinePlayer` sp_SetCharTitleChangeAvailableTime 00560900; `cAddCharacterTitle` 005eb310 | Z07 (plan line 9: "titles") | Lua `cAddCharacterTitle` sends 0x6005 / 0x6009 (W04 / D04 document the other servers' side); `cCharTitleAddValue` (§17.8) feeds the same engine |
| Collection cards: `BinaryDataBox<CollectCardMobGroup>` bdb_ReadData 00648d50; `CardCollection::CardCollectionReward` CardCollectionReward 00629150; `SHND::CommonData<CollectCard,SHND::CmpCardCollect<CollectCard>_>` cd_Load 00629840; `ShinePlayer` sp_CardCollectionSend 0044cc30 | Z07 (plan line 9: "collection cards") | card tables and the card send at login |
| GM command: `AmpersandCommand` ac_MobBreedUsage 0041a260 | Z11 (plan line 7: every `AmpersandCommand_ac_*`) | usage text of `&mobbreed` (the breeder it creates is §10.6) |
| Stat containers: `Parameter::Container` Container 004c98a0, IsNoAttack 004c8ea0, c_MakeTotal 004c9a40, c_clear 0043c370 | Z12 (plan line 12: "`so_allparametercalculate` … what fills each layer") | the stat-matrix container; `IsNoAttack` is read by `ShineMobileObject::so_Routine` (§5.5) and the skill-bash handlers, but the container is Z12's |
| Pets: `CPetData` GetPetID 004cef80, GetPetIDX 004cf030; `ItemAttrCls_Pet` iac_GetPetName 004d0650, iac_SetPetName 004d05f0; `ShinePet` spt_FindMaster 00419a80; `ShinePlayer` sp_PetSystem_InitPetInfo 004d1ff0, sp_PetSystem_InitPetInfoLink 004d2090, sp_PetSystem_LinkResummon 004d2a40, sp_PetSystem_Summon 004d2640, sp_PetSystem_VirtualCast 004d2180, sp_Send_NC_PET_ASK_NEW_NAME_REQ 004d0c90; `cPet_ChangeMind` 005ea1d0, `cPet_GetActionRecord` 005e9d00, `cPet_GetMind` 005e9520, `cPet_GetRunSpeed` 005e9b10, `cPet_GetStress` 005e9720, `cPet_GetWalkSpeed` 005e9920, `cPet_SaveTendency` 005ea410, `cPet_Unsummon` 005d65a0 | Z13 (plan line 15: "Pets: the summon/unsummon flow …, the `ShinePet` object") | pet summon / name / mind; the Lua `cPet_*` functions (§14.9 "Z13" row) are the pet AI script's interface |
| Mounts: `BriefInformationMover` bimv_SetSlotHandle 0055e8a0; `CMoverUpgradeData` GetUpgradeEffectInfo 004c0460; `MoverDataBox` mvdb_GetData 004bf290, mvdb_GetData_ItemIndex 004bf2c0; `MoverSkillList` msl_Store 00449190; `Parameter::Container` c_StoreMover 0055e8d0; `ShineMover` smv_RegenComplete 00441fd0; `ShinePlayer` so_MoverSystem_ClearLinkData 0045e040, sp_HorseFree 0045d3e0, sp_HorseItemSave 0045e810, sp_HorseOff 0045f7c0, sp_HorseOn 0045f270, sp_MoverSystem_MapLogin 0045d9e0, sp_MoverSystem_Type 0045d540 | Z13 (plan line 16: "Mounts: mover creation …, `sp_HorseItemSave` …") | mover summon, link data and stats |
| Minimon: `ShinePlayer` sp_SendUseItemMinimonInfo_Client 00561990, sp_UseItemMinimon_ChargedSlotClear 00564150, sp_UseItemMinimon_NormalSlotClear 00563f60 | Z13 (plan line 17: "minimon list kinds") | minimon auto-use slots |
| Mini-house: `ChargedItemEffectDataBox<MiniHouse>` cideb_GetItemID 00531820; `ChargedItemEffectDataBox<MiniHouseFurniture>` cideb_GetIndex 00514b10; `ShineMiniHouse` smh_FurnitureActiveCheck 005472e0; `ShinePlayer::MiniHouseStr` mhs_Init 00534a30; `ShinePlayer` so_ply_MH_InitFurnitureEmotionInfo 0056fe60, so_ply_MH_SetMyHandle 00570a10, sp_MiniHouseFree 0045d420 | Z13 (plan line 12: "ShineMiniHouse … furniture … emotions") | §28.1 documents only the mini-house range queries |
| Wedding: `CAnnounceSystem` AnnounceSystem_WeddingStart 005b9380; `PROTO_NC_CHAR_WEDDINGDATA_ACK` Reset 0043bdb0, operator= 0059f250; `WeddingHall` wh_RecallCouple 005a27f0 | Z13 (plan line 13: "Wedding hall and married state") | wedding hall recall / start notice, the wedding-data record; Pine `weddingcomplete` (§26.7) and `wh_Start`'s film (§27.5) are the script side |
| Instance-dungeon clusters: `FieldContainer` fc_GetInstanceDungeonInfoByMapName 004844e0; `MapClusterManager::ClusterManager` AddInstanceDungeonCluster 00484850, cm_AddTutorialMapCluster 004a0860, cm_FindMapCluster 00486580; `MapClusterManager::MapCluster::InstanceMap` ~InstanceMap 00484730; `MapClusterManager::MapCluster` MapCluster 0049f400, mc_CompName 0049f580, mc_GetLimitTime 0049f610, mc_Regist 0049ed40, ~MapCluster 0049ed20; `ShinePlayer` sp_EscapeFromEmptyID 00440910 | Z14 (plan line 15: "`MapClusterManager::ClusterManager` … and `MapCluster`") | the clusters behind the film restarts of §27.5 and the map kinds of §28.1 |
| Raids: `Raid` Begin 0063d200, End 0063d220, GetLooting 0063d070; `Raid::iterator` GetCharRegistNo 0063d4d0, operator!= 0063d550, operator++ 0063d080; `ShinePlayer` so_SetRaid 005604a0 | Z14 (plan line 17: "Raid internals: the shared `Raid` record") | `Raid::GetLooting` = the raid's loot mode, read by the pickup checks (`ShineMultiTypeHandle::IsCanItemPick` 004c15e0, `sp_NC_ITEM_PICK_REQ`); the record is Z14's |
| Quests: `CQuest` DoingQuestUpdateStatus 00630510, GetQuestIndex 0062f1d0, GetQuestInfoByIndex 0062f260; `CQuestZone` InitNewPlayer 005b9d40, IsConnectionEnd 005b9af0, IsQuestDropItem 005bc900, Send_NC_QUEST_CLIENT_SCENARIO_DONE_ACK 005bb0c0, Send_NC_QUEST_NOTIFY_MOB_KILL_CMD 005bdb00, qz_SetObject 005b9ae0; `PartyManufacture` pm_FindMember 004cc390, pm_QuestCheck 004ccbf0; `RaidTask` rt_QuestCheck 005ce710; `ShineQuestDiary` ShineQuestDiary 00578040, sqd_MobDead 00578170; `cClassChangeOpen` 005ed720, `cGetQuestHero_ItemUse` 005d9140, `cGetQuestHero_NPC` 005d8f60, `cQuestMobKill` 005d6010, `cQuestMobKill_AllInMap` 005d6150, `cQuestResult` 005e30d0, `cQuestResult_Individual` 005ecca0, `cReward` 005df060, `cRewardItem_CharInven` 005d6a10 | Z15 (plan line 12: "Quest data …", line 16: "Other entry points: NPC click …, mob kill (`ShineQuestDiary_sqd_MobDead`, 0x440D …), party quest checks (`PartyManufacture_pm_QuestCheck_*`), quest items (`IsQuestDropItem`)") | the quest engine; Z09's mob kill (`so_KilledBy`) and drop roll (§11) call into it |
| Kingdom quests: `KQContribute::KQContributeList` kqcl_FindKQ 00499ca0, kqcl_SendMobKill 00499ff0; `KQRewardDataBox` operator[] 0049a9a0; `KingdomQuest::KQElement` kqe_ReviveNumber 00496b90; `KingdomQuest::KQPlayerInform` kqpi_KnockDownGet 00496e50, kqpi_KnockDownPlus 00496de0; `ShinePlayer` sp_EscapeFromEmptyKQ 0043fa40, sp_GetJoinKQTeamType 00563990, sp_KQElementFunction 00499710, sp_RemoveKQItem 0050f8c0, sp_SendKQTeamType 00561560; `cEndOfKingdomQuest` 005df1f0, `cGetKQLimitSecond` 005e5390, `cGetKQTeamType` 005e81c0, `cIsKQJoiner` 005e82d0, `cKQRewardIndex` 005e4000, `cShowKQTimerWithLife` 005e54f0, `cShowKQTimerWithLife_Obj` 005e5690 | Z16 (plan line 12: "`KingdomQuest::KQElement` (… `kqe_ReviveNumber` …), `KQPlayerInfoList` (… knock-down counters …), `KQContribute::KQContributeList`") | KQ state; the Pine KQ nodes (§24.7, §25.6, §26.1) call it |
| Guild tournament: `DiceGame` Start 00478ef0; `GuildTouramentLoginDataInfo` GetLinkData 00478610; `GuildTournamentOccupyTable` GetOccupyTime 005c70f0; `GuildTournamentSystem::AdvanMobItemRegenInfo` ~AdvanMobItemRegenInfo 0047aa60; `GuildTournamentSystem` Clear 004808f0, CreateItemEffect 0047c1e0, GuildTournamentSystem 00480d30, Initialize 00480f10, IsBattleGuild 00478db0, IsFlagCapture 00479510, PlayerUnRegister 0047fd50, ScanEnemyUser 0047a3d0; `GuildTournamentSystem::FlagInfo` FlagInfo 0047ac30, ~FlagInfo 0047ace0; `GuildTournamentSystem::GuildGroup` AddTeamNPC 0047c120, CheckManagerUser 004798f0, GuildMasterBuffRun 0047b040, SendPlayerAllScoreInfo 0047f260; `GuildTournamentSystem::GuildMemberInfo` GradeSort 00478d80; `ShinePlayer` sp_FlagCaptureFree 00476cf0 | Z16 (plan line 13: "the GT system class (… `00479510` flag check, … dice game …)") | GT state; §12.3 (axial flags), §22 (GT nodes) and §24.8 call it |
| Item actions and costume charges: `ItemActionArgument` ItemActionArgument 0042aad0; `ItemActionObserveManager::ActionResults` GetRateAppliValue 005d0c20; `ItemActionObserveManager` EventRunBySkillGroupIndex 005d1f50, ItemActionObserveManager 005d1910, SetObject 005d0890, _EventRun 005d1df0; `ShinePlayer` sp_CostumShieldChargeDecrease_ToDB 0051ac20, sp_CostumWeaponChargeDecrease_ToDB 0051a610 | Z17 (plan line 12: "the player's item-action cooldown container"; line 13: "`sp_CostumWeaponChargeDecrease_*`") | `EventRunBySkillGroupIndex` is raised from skill use and from the magic field (`so_mgcfld_MagicField…`, `almfh_ApplyHeal`, §12); the container is Z17's |
| Game-log sends: `cSendGameLogDataType_4` 005f1a10, `cSendGameLogDataType_5` 005f1d40, `Send_NC_LOG_GAME_DATA_TYPE_5` 006145c0 (also from `cSaveTutorialInfo`, §28.13) | D05 (its scope table, plan lines 201 / 202: `NC_LOG_GAME_DATA_TYPE_4` / `_5`; D05-gamelog documents the zone senders by address) | the Lua side is one line each (§14.9 "already documented" row); the zone function is cited by no zone doc |

### 31.3 Packets and data files

| Found | Covered by | Argument |
|---|---|---|
| 0x8C4F NC_MINIHOUSE_PORTAL_DEL_CMD (`ShineMiniHouse::so_Routine`) (the `layouts.json` "0x0E0D" of `smh_SendFurnitureInfo` 00546930 is a false positive, §28.9) | Z13 (plan line 12: "`smh_SendFurnitureInfo` …, portals … and `so_Routine` (portal timeout)") | sent by mini-house code §28.1 only names; no doc describes them yet |
| 0x2442 NC_BAT_SOMEONESKILLBASH_OBJ_CAST_CMD, 0x2443 NC_BAT_SOMEONESKILLBASH_FLD_CAST_CMD (`ShineMobileObject::smo_SkillBash_Blast_Trap`) | Z03 (plan line 9: "skill cast/bash") | trap / field skill casts; §8.1 reaches the skill code only through `cNPCSkillUse` / `cSkillBlast` |
| 0x74F2 NC_GUILD_TOURNAMENT_ITEM_FLAG_CMD (`GuildTournamentSystem::PlayerRegister`) | Z16 (plan line 13: "the client packets 0x74xx sent during a match") | GT item flag |
| `World/Param<Class>Server.txt` (27 files, `CharClassManager::ccm_Load` 0044a5c0) | Z12 (plan line 12: "class base stats per level from class data `p.vt[0x49c]() + 0x10858`") | per-class player parameters (§28.9) |
| `AbState/*.dat` (11 files) | Z03 (plan line 9: abstates) | no string in the zone names the folder or a file (`strings.tsv`), so the 2016 zone does not load them; left-over client-style data |

### 31.4 Library code

| Found | Covered by | Argument |
|---|---|---|
| Lua: `luaG_runerror` 005ffac0, `luaL_loadfilex` 005fa1b0, `luaL_loadstring` 005fa4b0, `luaL_newstate` 005faba0, `luaL_openlibs` 00603ab0, `luaV_tonumber` 00610f30, `lua_checkstack` 005f71b0, `lua_close` 0060c690, `lua_getglobal` 005f83d0, `lua_gettable` 005f8430, `lua_isstring` 005f7830, `lua_next` 005f90c0, `lua_pcallk` 005f8d60, `lua_pushinteger` 005f8150, `lua_toboolean` 005f7d00, `lua_tointegerx` 005f7b80 | none needed: the embedded **Lua 5.2.1** (zone string "Lua 5.2.1  Copyright (C) 1994-2012 Lua.org, PUC-Rio"; 5.2 API names `lua_pcallk`, `lua_tointegerx`, `luaL_loadfilex`) | third-party source; a rebuild links the stock 5.2 library. §14 documents how the zone uses it |
| MSVC runtime: `_CIatan` 006592b0, `_CIcos` 00659730, `_CIsin` 00659600, `_CIsqrt` 00658330, `_findclose` 00659819, `_findfirst32` 006598b9, `_findnext32` 006599d7, `_ftol2` 00657236, `atoi` 00658292, `srand` 006594a0 | none needed | C runtime (`_CI*` math, `_ftol2`, `_findfirst32` directory scans of the script loaders, `atoi`, `srand`) |
| MSVC STL instances (`std::vector`, `std::_Tree` (map / set), `std::deque`, `std::basic_string`, iostreams, algorithms): `_Deque_iterator<ShineObject>::operator+` 0057e060, `_Destroy_range<FlagInfo>` 0047d760, `_Destroy_range<SlotMachineInfo>` 004b5800, `_List_val<BlockingDistribute>` 00438b70, `_Move<FlagInfo>` 0047d5c0, `_Remove<FamilyMob>` 004b5660, `_Remove<PlayerList>` 0049a160, `_Remove_if<Observer>` 00576840, `_Rotate<UnitPointWithDistance>` 005c8d40, `_Sort<ObjectWithDistanceSquare>` 005f4320, `map<ORToken>::_Erase` 0048f190, `map<ORToken>::_Lbound` 0048e570, `map<ORToken>::_Linsert` 0048f4e0, `map<enum_PET_AI_TYPE>::_Linsert` 00441080, `map<enum_PET_AI_TYPE>::_Linsert` 00626d20, `map<int>::_Erase` 005c7800, `map<int>::erase` 005c7ab0, `map<basic_string>::find` 0047bba0, `map<unsigned_long>::find` 005cf320, `map<unsigned_short>::_Insert` 005b1c40, `map<unsigned_short>::_Linsert` 004244b0, `map<unsigned_short>::erase` 005cf500, `map<unsigned_short>::find` 00464350, `map<unsigned_short>::_Linsert` 004b01c0, `map<unsigned_short>::_Linsert` 005c3da0, `set<IActCondition_*>::_Erase` 005b1b20, `set<IActCondition_*>::_Linsert` 005b1b60, `set<IActCondition_*>::erase` 005b2460, `set<MobRoamingPath>::_Linsert` 004b8160, `set<MobRoamingPath>::find` 004b7820, `set<enum_ABSTATEINDEX>::_Copy` 004643c0, `set<unsigned_long>::find` 005561b0, `map<unsigned_short>::operator++` 0043ca50, `map<ORToken>` 0048eae0, `map<enum_PET_AI_TYPE>` 00626ee0, `map<unsigned_long>` 00441230, `map<unsigned_short>` 005c84b0, `map<unsigned_short>` 00466fe0, `set<IActCondition_*>` 00463f20, `set<MobRoamingPath>` 004b7b60, `_Upper_bound<GuildMemberInfo>` 0047a0a0, `allocator<SlotMachineInfo>::allocate` 004934f0, `basic_ios<char>::widen` 004dd090, `basic_ostream<char>` 004e09c0, `basic_streambuf<char>` 004d9580, `basic_string<char>::_Myptr` 00402550, `basic_string<char>` 00424850, `basic_string<char>::compare` 0040cee0, `basic_stringstream<char>::str` 004e24e0, `basic_stringstream<char>` 004da420, `deque<ShineObject>::begin` 00576df0, `deque<ShineObject>::operator[]` 0057e0a0, `generate<int>` 004e6b20, `generate_n<Trigger>` 005c3fc0, `ios_base::_Init` 004d71b0, `ios_base::_Ios_base_dtor` 006555f1, `ios_base::clear` 004d7080, `list<BlockingDistribute>` 00438ef0, `make_pair<unsigned_short>` 005c4250, `make_pair<unsigned_short_&>` 004b0190, `map<enum_PET_AI_TYPE>::operator[]` 00442da0, `map<unsigned_short>::operator[]` 00442070, `operator<char>` 0040e090, `operator<char>` 004ddd70, `operator<char>` 004de010, `random_shuffle<int>` 004e71f0, `remove<Observer>` 00576ff0, `vector<AbstateElementInObject>::push_back` 00433b70, `vector<AbstateElementInObject>::resize` 00433ac0, `vector<CGambleObject>::push_back` 0047bc10, `vector<CGambleObject>::reserve` 005c7450, `vector<FamilyMob>::_Reserve` 004b59c0, `vector<FamilyMob>::erase` 004b5950, `vector<MobSpeciesSlot>::push_back` 004b5230, `vector<MobSpeciesSlot>` 004b4da0, `vector<AdvanMobItemRegenInfo>::push_back` 00480750, `vector<FlagInfo>::push_back` 00480830, `vector<Gate>::push_back` 004806b0, `vector<GuildMemberInfo>` 0047d440, `vector<EnemyPlayer>::push_back` 00482c30, `vector<EnemyPlayer>::resize` 00482bb0, `vector<PlayerList>::erase` 0049a410, `vector<TriggerChat>::erase` 00490a50, `vector<TriggerChat>::push_back` 005f4a10, `vector<TriggerJump>::push_back` 005f4ad0, `vector<TriggerUseItem>::push_back` 005f4b90, `vector<PathElement>::push_back` 004b7af0, `vector<Trigger>::_Reserve` 005c3e90, `vector<Trigger>::resize` 005c3f10, `vector<Trigger>` 005c3cc0, `vector<NaviPoint>::operator=` 005c92b0, `vector<NaviPoint>::push_back` 005c9410, `vector<NaviPoint>::reserve` 004bc690, `vector<NaviPoint>::resize` 004bc8a0, `vector<UnitPoint>::resize` 0055fd60, `vector<UnitPointWithDistance>::push_back` 005c9040, `vector<UnitPointWithDistance>::resize` 005c91e0, `vector<ObjectWithDistanceSquare>::push_back` 004480c0, `vector<ObjectWithDistanceSquare>::reserve` 00447600, `vector<Observer>::erase` 00442100, `vector<Observer>::push_back` 00577ed0, `vector<Observer>::reserve` 00442170, `vector<Observer>::resize` 004432e0, `vector<SkillDamage>::push_back` 0057f350, `vector<CardBookmarkInfo>::push_back` 00448050, `vector<MobOfQuest>::resize` 005c0840, `vector<ShineObject>::operator=` 00424890, `vector<SkillBlastEffect>` 00437f30, `vector<SkillBlastEffect>::push_back` 00437ec0, `vector<SkillBlastEffect>::resize` 00437df0, `vector<enum_ABSTATEINDEX>::operator=` 005d4450, `vector<enum_ABSTATEINDEX>` 005d5020, `vector<int>::_Construct_n` 004e7240, `vector<int>::_Insert_n` 005b20c0, `vector<int>::erase` 005d3b90, `vector<unsigned_long>::resize` 004b40f0, `vector<unsigned_short>::_Buy` 004a1e10, `vector<unsigned_short>::_Reserve` 0047b650, `vector<unsigned_short>::push_back` 0047bb30, `vector<unsigned_short>::reserve` 0047a7b0 | none needed | template instances over the classes of their owners; behaviour is the standard library's |

### 31.5 Things named in earlier sections

| Found | Covered by | Argument |
|---|---|---|
| §14.9 Lua rows "Z13 (pets)", "Z15 (quests, rewards, tutorial)", "Z16 (kingdom quests)" | Z13 / Z15 / Z16 / Z07 (§31.2 rows; tutorial → Z07 corrected there; the former "Z14 (instance dungeons, scores)" row is documented in §28.12) | the Lua functions call other items' engines; §14.9 records their names and addresses |
| The 25 NA-only Lua functions of FiestaHeroes' `fiesta.lua` (§14.9 after the table: `cAddFame` … `cStartKey`) *(fh-doc)* | none: not in the 2016 build | the private-server hooks; the 2016 zone does not register them (no code to document) |
| §27.5 film starters outside Z09: `CQuestZone::PsStart` 005bbd00, `kqe_QuestStart` 004953e0, `wms_NC_KQ_W2Z_DESTROY_CMD` 004972c0, `wms_GuildTournamantStart` 00476de0, `wh_Start` 005a25a0, `ZoneRingPacketFindInstanceDungeon::zrpb_Success` 005a8c20, `ZoneRingPacketFindJobDungeon::zrpb_Success` 005a8f40, `so_ply_2JobDungeon` 0049f880, `mc_PlayAllFilm` 00485fb0, `mc_AllDropFilm` 00485290, `mc_DeleteInstanceDungeon` 00486710, `mc_MissoionFailInstance` 0049ee70, `cm_AllDropFilm` 00486ec0, `wms_NC_INSTANCE_DUNGEON_LEVEL_SELECT_JOIN_ECHO_REQ` 004871a0, GM `ac_PlayInstanceDungeon` 00421190, `ac_KingdomQuest` 00423dd0, `ac_BigBang` 004240d0, `ac_IndunReload` 00419810, `ac_ReroadKingdomQuest` 0041dc80 | Z15 (plan line 13: `CALLPS` (`PsStart` / `PsEnd`)), Z16 (line 12 / 13), Z13 (line 13), Z14 (line 15), Z08 (part 3: 41 INSTANCE), Z11 (line 7) | §27.5's table: the film API is Z09's, deciding when to start a film is the caller's |
| Skill-side helpers: `smo_SkillBlastOption` actor vt 0x1c values, random-target helpers 0057e660 / 00579910, skill movers 00401db0 / 005c1390 / `smo_ShadowStep`, `so_AbnormalState_Set_SS_SETABSTATEME` (vt 0x648), `ShineMobileObject::so_Dispel` 0042bf70, the damage-absorb flag consumer (vt 0xbec in `smo_SwingDamage` 00432f30 / `sds_TemplateStore` 005803c0), which SubAbState kinds use the magic-field actor, B31's player-rule twin | Z03 (plan line 9) | combat and abstate rules; Z09 documents the mob / object side (§7.4, §8.4, §9.3, §12, §16.6) |
| GM commands: `ac_MobBreed` 0041b510 / 0041b790, `ac_MobHatchery` 0041f6c0, `ac_MobItemDrop`, `ac_DoorBuild` 0041aa50, `&releasenpc`, `ac_PetSystemTest_LuaReload` 00424740 | Z11 (plan line 7) | command parsing and levels; the objects they create are §10.6, §11, §13.1, §14 |
| KQ / GT objects: `sp_KQReward` 0052da70, `tcm_ItemMake(ShineReward)` 00595d00, `sp_KQItemDrop` 00496f00, `GTMobRegenKey` (004f8990, step 004fb0b0), `GuildTournamentSystem::CreateItemEffect` / `GetGuildRegIndex`, `so_IsTeamPVPKQ` 0055d6c0 | Z16 (plan lines 12 / 13) | §10.6, §10.10, §11, §22 document the Z09 side of each |
| Quest items `sp_QuestItemGet` 00528240 | Z15 (plan line 16: "quest items (`sp_QuestItemGet`, `IsQuestDropItem`)") | quest drop path |
| Items: `ItemAttr` class vt 0x2c (group row → lot / upgrade), `so_ply_EquipmentChange` 0052ce60 and the view slots, `sp_DestroyItem` 00527b60 / 00527a70 | Z04 (plan line 9) / Z05 (persistence) | item model |
| Pets, mounts, mini-house: `ShinePet::so_Routine` / `spt_RegenComplete`, `ShineMover::*`, `ShineMiniHouse::so_mh_*` 00543a40 / 00544f00 / 00546150 / 00546930 | Z13 (plan lines 12 / 15 / 16) | §8.4 / §14 / §15.7 / §28.1 document only the parts world simulation uses |
| `CCharacterTitleZone::CheckNewTitle` 005cb5f0 | Z07 (plan line 9: titles) | title unlock after `cCharTitleAddValue` (§17.8) |
| `GuildTournamentSystem` as a `RoutionInterface` ticked by axial flag 2 | Z16 (plan line 13) | §12.3 documents the flag; the system is Z16's |
| `g_LuaArgument` DAT_14d6fcd8 (Count / Interval / MaxSkip / Summary / SkipNumber / CertifyArg) | Z10 (plan line 14: "The Lua surface: list every C function the script can call") | set by the downloaded start script, not by map scripts |
| `sdc_Setsixpoint` 004607f0, `CFindWay`, `MobBehaviorDescript/` | Z09 (§30.7) | not out of bounds: summarised on purpose and listed there |
