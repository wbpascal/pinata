# Zone server: world simulation — main loop, timers, mobs, NPCs, spawns, drops, scripts (Z09)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (export `re-data/exports/zone`). Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`. Names: the zone's
own profiler strings (`docs/knowledge/Z01.md` §1) plus `tools/protocol-re/names/zone/Z09.json` (names marked *(ours)*
there and here are ours). Evidence markers as in `AGENTS.md`: plain = read in the 2016 code, *(pdb2017)*, *(inferred)*.

Time unit: `g_Now` (DAT_14d41a70) counts **tenths of a second** (Z02 §1); "`g_Now + 50`" = 5 s.

This file is written in parts (status: `docs/plan/status/Z09.md`). Sections so far: §1 main loop and global timers,
§2 the player tick, §3 GM events, §4 prison (no zone timer), §5 mob object core (data, spawn, routines, NPC, bandit),
§6 mob AI 1 (brain, target selectors, aggro, battle / recover, calls for help), §7 mob AI 2a (tactic state machine,
weapons, attack sequences, captivated players, the dead `so_attack` / `so_Bash` path), §8 mob AI 2b (script-ordered
skills and weapon rates, cross-counter, hit / heal rules of the non-player classes, skill blast delay, mob chat, mob
shout, servant explosions, boss-field hooks, the charmed player's target selector). §9 movement (MoveManager, block
bitmaps and doors, server-driven moves, random spots, Navigator, MobRoam, scenario moves) and sight (coordinate lists,
range queries, 0x1C0E on moves).

---

## 1. Main loop and global timers

### 1.1 `ZoneServer::zs_mainthreadfunction`

One thread runs the whole world: network polling of the server links, **all client packet handling** (inside each
player's tick, §2.5), every object's routine, and the global containers. IOCP workers only move bytes.

```pseudo
zs_mainthreadfunction(ctl)                                          @ FUN_005aca30
    # ctl = thread control block: +0 u8 running, +1 u8 stopRequest, +0xc u32 tickCounter
    ctl.running = 1; ctl.tickCounter = 1
    srand(time()); r[16] = 16 × rand(); FUN_0063c890(r)              # seeds the zone's own RNG (inferred)
    DAT_14d44a34 = 0
    while !ctl.stopRequest:
        lock DAT_0d026c10 (FUN_004678e0) … unlock (FUN_004681f0) at the end of the tick   # main-thread lock (inferred)
        # clock
        acc64 += timeGetTime() − last;  g_Now = acc64 · 10 / 1000      # tenths of a second since the first WM 0x0821
        DAT_14d41a74 = tenths elapsed since the last whole tenth (step of this tick, inferred)
        DAT_1327281a = DAT_13272bca = −1                               # two per-tick caches reset (meaning not traced)
        ClientSessions_Reap(server)                                    @ FUN_005abb60   §1.5
        Listen_AcceptPending(server)                                   @ FUN_005aa840   §1.5
        SessionPool_PollAll(g_GameDBSessions); (g_GameLogSessions); (g_WMSessions)   @ FUN_005ab030
        Session_Poll("ZoneCon", g_ZoneRingNext); Session_Poll("ZoneLis", ring previous DAT_0af0cff0)   @ FUN_005a9f70
        if g_WorldTm.tm_min ≠ (g_WorldDate >> 25):  PerMinuteBlock()   # §1.2
        GMEvents_Routine(&g_GMEvents)                                  @ FUN_0046d7e0   §3 (every 1 s)
        SessionPool_Reconnect(g_GameDBSessions, type 2); (g_GameLogSessions, 3); (g_WMSessions, 5)   @ FUN_005aa340
        ForEachList(&g_Objects, ShineObjectEachList.soel_Routine)      @ FUN_004026e0 → FUN_0054f710   §1.3
        SkillBlastEffectContainer.sbec_Routine(&g_BlastEffects)        @ FUN_00437fc0   (Z03 §5.4)
        ForEach(&g_EventReserveList DAT_13388e70, erle_Routine)        @ FUN_005af1e0   §1.4
        ForEach(&g_OPToolObjects DAT_0da3d2b8, OPToolObject.opto_Routine)   @ FUN_004c7e60   §1.5
        ForEach(&g_GuildStorage, FUN_00474950)                         # drops records whose +0x106c "in use" byte is 0 (Z14)
        g_MinuteFlags (DAT_00aa43e0, u16) = 0                          # the per-minute flags live for exactly one tick
        if g_Pulse5s (DAT_14d6fcb4) < g_Now: g_Pulse5s = g_Now + 50   # 5-second pulse, §1.4
        SleepManager.sm_Routine(&g_Sleep DAT_0086ed54)                 @ FUN_005aa610   §1.4
        if DAT_0d76abc0 < g_Now:                                       # instance-cluster interval
            DAT_0d76abc0 += DAT_0d76abc4
            ForEach(&g_MapClusterMgr, MapCluster.mc_Routine)           @ FUN_004868d0   (Z14)
        g_TickTimes[DAT_0084fb20++ & mask] = g_Now                     # ring of tick start times (diagnostic, inferred)
        GambleMgr_Routine(&g_GambleMgr)                                @ FUN_006158d0: every game object vt 0x20 (Z06 §5 routines)
        ctl.tickCounter++
    ctl.running = 0
```

There is no fixed tick length: the loop runs as fast as it can, throttled only by the sleep manager (§1.4).

### 1.2 Per-minute block (world time)

The WM sends `0x0821 NC_MISC_TIMEFROMWORLD_CMD { struct tm }` every 60 s and when the zone connects (W01 §2,
`Zones_TimeSync`). The zone handler (`wms_NC_MISC_TIMEFROMWORLD_CMD` @ FUN_004511a0, Z01 §9) copies it into
`g_WorldTm` (DAT_00aa43e4, 9 ints: sec, min, hour, mday, mon, year, wday, yday, isdst), sets the machine clock and
`g_TimeOffset` (DAT_00aa4408 = mktime(tm) − time()). `WorldTime_Now(&t)` @ FUN_00450360 *(ours)* = `time() + g_TimeOffset`.
So the block below runs once per WM time message whose minute differs from the last one (≈ once a minute); while the
WM link is down no minute passes *(inferred)*.

```pseudo
PerMinuteBlock():                                                   (inline in FUN_005aca30)
    # certification counters (Z10): DAT_14d6fce0 < DAT_14d6fce8 → ctl.stopRequest = 1 (the zone stops);
    #   else DAT_14d6fce4++, and when ≥ DAT_14d6fcdc: DAT_14d6fcec = next non-zero (table DAT_150923f0[i] − 50), DAT_14d6fce4 = 0
    clear the map DAT_13295a6c (entries added by som_FreeObject FUN_00557d70; freed-handle bookkeeping, inferred)
    g_WorldDate (DAT_00aa43b8) = min<<25 | hour<<19 | mday<<13 | (mon+1)<<8 | (u8)(year − 100)
        # packed "now" that charged / time-limited items compare with field by field (e.g. §2.4 SmallChargedItemLimitCheck)
    g_WorldTmSnapshot (DAT_00aa43bc) = g_WorldTm
    g_MinuteFlags: byte 0 (DAT_00aa43e0) = 1 "a minute passed";
                   byte 1 (DAT_00aa43e1) = 1 when min == 0 and hour == 0 "a new day"
    DAT_0086ed5c −= DAT_0086ed5c / 100                             # 1 % decay; nothing else reads it (inferred: dead statistic)
    wms_GuildTournamentCheck()                                      @ FUN_004776a0   (Z16)
    wms_GuildWarStatusRequest(g_WMSessions)                         @ FUN_005a45f0   (Z08 / W03)
    WeddingHall.wh_Routine(&g_WeddingHall)                          @ FUN_005a2a10   (Z13)
    object-pool consistency check: for each of the 13 pools (DAT_132828a4[0..12]) and each used slot:
        ObjectHandle_Decode(obj.handle) must give (pool, slot); otherwise log
        "ZoneServer::zs_mainthreadfunction - so_GetZoneHandle[h] ObjType[t] Index[i] inlist[…]" (log only)
    if DAT_00870de0 == 0: DAT_00870dd8 *= const DAT_006f91c8        # argument of the next call (not traced)
    Lua_CallGlobal(start-script state DAT_14d6fdf0, "xlrfunction", …)   @ FUN_005d7bc0
        # a function defined by the downloaded start script (Z10); failure → log "…zs_mainthreadfunction : function call error"
```

Everything that "runs once a minute" in the zone keys off `g_MinuteFlags` during that one tick (player checks §2.4).

### 1.3 Object routines

`g_Objects` holds one `ShineObjectEachList` per object pool (13 lists, Z01 §4.2). The main loop visits each list
(`ForEachList` @ FUN_004026e0 *(ours)*); each list visits its objects:

```pseudo
ShineObjectEachList.soel_Routine(list)                              @ FUN_0054f710
    ok = ObjectList_ForEach(list, obj → obj.vt[0x4ac]())            @ FUN_0054b160, thunk LAB_0054b320 (jmp [vt+0x4ac])
    if !ok: list.failCount (+0x1c)++                                # a visit stopped at a free slot
    if list.nextReport (+0x18) < g_Now:
        if failCount: log "ShineObjectEachList::soel_Routine - ObjectType[…] LISTNO Count[n]"; failCount = 0
        nextReport = g_Now + 600                                    # once a minute
```

`vt 0x4ac` = `so_Routine` per class (from the RTTI vftables):

| Class | so_Routine | Section |
|---|---|---|
| ShineObject (base) | FUN_0064c820 `return 1` | — |
| ShineAxialFlag | `ShineAxialFlag_so_Routine` | later part (objects) |
| ShineDropItem | `ShineDropItem_so_Routine` | later part (drops) |
| ShineMiniHouse | FUN_00567400 | Z06 §3.4 / Z13 |
| ShineMagicField, ShineEffectObject, ShineDoor, ShineServant | `…_so_Routine` | later part (objects) |
| ShineBandit | `ShineBandit_so_Routine` FUN_0056c630 | §5.10 |
| ShineMobileObject (base of all movers) | FUN_0056a080 (cast completion: Z03 §5) | §5.5 |
| ShinePlayer | FUN_0056c790 | §2 |
| ShineMob, ShineNPC | `ShineMob_so_Routine` FUN_0056baa0, `ShineNPC_so_Routine` FUN_0056a9e0 | §5.4, §5.9 |
| ShineMover, ShinePet | `…_so_Routine` | Z13 |

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
    # s = { work (DAT_0086ed54), step, peak }; work is incremented once per processed packet
    #     (player tick §2.5, Session_Poll, opto_Routine)
    peak = max(peak, work)
    if work · 2500 / peak < step²:  SleepManager.sm_Sleep(s)        @ FUN_005aa5b0: Sleep(1 ms); step = 0
    else step++
    work = 0
    # an idle zone sleeps 1 ms every other tick; a busy one sleeps after ~√(2500·work/peak) ticks
```

`g_Pulse5s` (DAT_14d6fcb4) is "true" (`< g_Now`) for exactly one tick every 5 s, because the main loop re-arms it after
the object routines. `ShineMob.sm_IBuffToBuffee` (FUN_005d48c0) and FUN_0069b690 test it (mob part).

### 1.5 Session polling and reaping (network side of the tick)

```pseudo
Session_Poll(name, s)                                               @ FUN_005a9f70
    if s.state ∉ {1, 2}: return 2
    r = s.io.vt[0xc]()                     # 0 nothing, 1 packet ready, 2 error
    1 → s.vt[4](0, 0xFFFF) (dispatch with handle −1); s.io.vt[0x24]() (release); g_Sleep.work++; return 0
    2 → s.io.vt[0x10](&n); if n < 0 return 1; s.io.vt[0x18](); s.state = 3; return 1
    0 → if s.io.vt[0x28]() (flush) fails: FUN_005a66c0(s) (close)
SessionPool_PollAll(pool)                                           @ FUN_005ab030
    for the 4 entries in state 1/2: if Session_Poll ≠ 0: close (FUN_005a6690), state 0,
        reconnectAt (+0xfc) = g_Now + pool.reconnectSeconds (+0) · 10, ready = 0, log
SessionPool_Reconnect(pool, info, type)                             @ FUN_005aa340
    for entries not in state 1/2 whose reconnectAt ≤ g_Now: FUN_005a9b50(info, entry, type, 1) (connect + handshake, Z01 §3.3)
Listen_AcceptPending(server)                                        @ FUN_005aa840
    per accepted socket by listen type: 6 zone ring (ZoneListenSession), 8 OPTool (OPToolSession; refused when
    no OPTool object is free), 0x14 client (ClientSession from the free pool; full → socket closed)
ClientSessions_Reap(server)                                         @ FUN_005abb60
    also polls the ring-next link (reconnect when down) and the pools' keep-alives (FUN_005aae80, FUN_005ab2c0, not opened)
    for each client session:
        phase (FUN_0045b190) ∈ {0, 1} and g_Now − connectTime (FUN_0045b1b0) > 72000 (2 h): log, state = 3
        FUN_0045b1d0 == 1: log, state = 3
        state 3 ("Socket cut"): obj = som_GetObject(session.objHandle +0x102)
            if obj is a player in a game mode: obj.vt[0x910]("Socket"); sp_RefreshWMSSocket   (Z01 §8.2)
            so_PacketBufferFlush; so_Unmark(…, 1, 7); som_FreeObject(handle) (log "…zs_disconnect : Fail to object free")
            release the session to the pool
OPToolObject.opto_Routine(o, list, idx)                             @ FUN_004c7e60
    same receive/dispatch as Session_Poll for an OPTool session; dead session → removed from the list
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
    ScriptTrigger_Fire(p, 0, 0, 0)  (vt 0xa38)                      @ FUN_00577c10   §2.6
    ScriptTrigger range check                                       §2.6
    ToggleSkill_DropUnusable(p.skillList +0x17d0c, p)               @ FUN_00448e20
        for each toggled skill (entry +2 ≠ 0) that csl_Toggle_CanUseSkill refuses now: remove its up to 4 abstates
        (vt 0x650, BriefAbstateBit_Clear, so_AbnormalState_BroadcastReset) and p.vt[0xbcc](skill) (toggle off)
    ScriptTrigger_Fire(p, 6, 0, 0)
    ReceivePackets(p, handle)                                       # §2.5
    SlantedNodes_CheckRelink: if the player's x/y nodes (+0x16, +0x22) fail
        SlantedCoordList::CoordedNode::cn_IsValid (FUN_0054b4c0: "Not inlist", "Link error", "Order error"):
        FieldMap.fm_Relink(field)                                   @ FUN_00462bd0   (the same check runs again on exit, FUN_005670c0)
```

Disconnect reasons used here: `0x680` player outside the map rectangle, `0x685` in a game mode without a map.
Bit 0 of `obj+0x1e78` is therefore the "invalid position" flag for players: it is set only by the routines' bounds
checks (players here; FUN_00567280, FUN_0056baa0, FUN_0056c1e0 for other classes) and cleared by FUN_004424f0,
FUN_00442eb0, FUN_0055fdf0 (re-placement). This corrects Z03 §2 ("routine ran once") *(inferred from the writers)*.

### 2.2 Region check on Elderine

```pseudo
sp_ElderineRegionCheck(p)                                           @ FUN_005529d0
    if p.field.mapName == "Eld" and (x ∉ [6000, 20000] or y ∉ [6000, 20000]):
        log x, y, charNo and dump the 16-entry position history ring p+0x2a804 (FUN_0054a120)   # log only, no correction
```

### 2.3 Work done for a player in a game mode

```pseudo
GameModeWork(p):                                                    (inline in FUN_0056c790, when p.mode ≠ 0)
    NormalAttackDamageTick.nadt_Routine(p+0x173d0, p)               @ FUN_00577520   (Z03 §3)
    if p.itemActions (vt 0x5d0): FUN_005d1930(it)                    # item-action cooldown routine (Z17)
    character-title minute counters: FUN_005cc4e0(p+0x29638)
        when WorldTime_Now()/60 changes: +0x4c8++ (cond 3), +0x4d8++ (cond 4), +0x728++ (cond 0x29), and
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
        +0x29634 (ShinePlayer_MoverRecoveryTick FUN_0056b5f0 while on a mover)
    class object (vt 0x49c) .vt[0x34](p)                            # per-class routine (CharClass*, Z12)
    if g_MinuteFlags.minute: PerMinutePlayerChecks(p)               # §2.4
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
    BashStopNotify_Send(p+0x7f36, p)                                @ FUN_00566820   (Z03: 0x243D)
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
        then so_AllOfRange_Class0(…, so_ply_Send2WhoTargetMe): the same to everyone who targets p
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
PerMinutePlayerChecks(p):                                           (inline; g_MinuteFlags byte 0)
    p.minuteCounter (+0x2a7c8)++; reset to 0 on a new day (byte 1)    # reader not found (inferred: minutes played today)
    sp_MiniHouseActivCheck(p)                                       @ FUN_00534fe0   (Z13)
    sp_DecorationActivCheck(p)                                      @ FUN_00534c60   (Z07)
    sp_ActionItemActivCheck(p, p+0xf758, 15)                        @ FUN_005697e0   (premium emote items, Z04 / Z02 §9.3)
    charged buffs: rebuild p+0x2a5a0 from the template DAT_132728f8 and the buff list p+0x2a330 (FUN_00450e10, FUN_00487c50);
        p+0xe94 = 1; if a buff expired (+0x2a5ce): so_RecalcEquipParam (vt 0x35c), so_RecalcLastParam (vt 0x368)
    smo_NotifyParameterChange(1) (vt 0x34); so_ply_SendBoothSize (vt 0x3e0)
    sp_ChargedItemLimitCheck (vt 0x38) on the inventory (p+0x8e2c, kind 9), the equipment (p+0x7fd8, kind 8) and, unless
        mode 4/5, the mini-house bag (p+0xe778, kind 0xc)           (expiry of time-limited items, Z04)
    sp_SmallChargedItemLimitCheck(p, p+0xf758, 15)                  @ FUN_0056b900
        for each item of that bag with an expiry date (FUN_00643400): if expiry ≤ g_WorldDate
        (compared year, month, day, hour, minute in that order): sp_SmallItemDelete
    wedding status (+0x5cd0 low nibble): 1 Wedding_CheckProposeExpired (FUN_0059f1b0), 2 Wedding_CheckDivorceTimers
        (FUN_005a1c90), 3 Wedding_CheckEscapeDivorce (FUN_0059f2d0)                                            (Z13)
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
        1 (one packet):   p.lastPacketAt (+0x17d48) = g_Now; s.vt[4](p, handle) → ClientSession.zbs_Parsing (Z02 §1);
                          if s.vt[0xc]() == 1: s.io.vt[0x24]() (release); g_Sleep.work++
        2 (malformed):    s.state = 3; log "Char as abnormal packet "; end of tick
```

So a player's requests are executed in that player's slot of the object walk, after its own timers; replies queued
in its send buffer go out at the next `so_PacketBufferFlush`. At most 1000 packets per player per tick.

### 2.6 Script triggers held by the player

`p+0x2a948 … +0x2a94c` is a vector of 0x18-byte trigger entries `{ vtable, → owner object, … }` added by
FUN_00576d50 / FUN_00577b50 (Lua `cTriggerRegist` and the chat/jump triggers; script part).

```pseudo
ScriptTrigger_Fire(p, kind, a, b)       vt 0xa38                    @ FUN_00577c10
    for each entry e: r = e.vt[4](0, p, kind, a, b, 0, 0); if r & 2: destroy e and remove it
    # kinds seen: 0 every tick, 6 every tick after the skill check, 7 moved (Z02 §2), 4 emotion (Z02 §4)
ScriptTrigger_RemoveFor(p, owner)       vt 0xa34                    @ FUN_00577ba0
    remove the entries whose owner == owner
range check (so_Routine): for each entry whose owner is not closing:
    d² = distance² between p and owner (999999999 if either has no map, the maps differ or the layers differ)
    if d² > owner.vt[0xa54]()² (FUN_005551a0 returns 1000 → 1000 units): ScriptTrigger_RemoveFor(p, owner)
```

---

## 3. GM events (`g_GMEvents`, DAT_14d42940)

The WM pushes `GM_EVENT_DATA` records (0xD00B add/update, 0xD00C delete; Z08 §13, W04 §16). The zone keeps them in
a vector of 0x958-byte entries: the 0x553-byte `GM_EVENT_DATA` followed by a derived map table and four state bytes.
A GM event in the 2016 zone only **grants up to three abnormal states** to the players it matches; it changes no
rate (exp/drop) directly; any rate change comes from the abstates' own effects *(inferred from the only effect code)*.

| Offset | Field (2017 PDB `GM_EVENT_DATA`, size 0x553) | Use |
|---|---|---|
| +0x000 | u16 nEventNo | key |
| +0x002 / +0x006 | i32 dStartTime / dEndTime | `time_t` (machine clock, which the WM sets via 0x0821) |
| +0x00a | u16 nRewardAbstateIndex[3] | abstate IDs (0xFFFF = none), looked up in `g_AbStateByName` (FUN_004013e0) |
| +0x010 | u8 bIsPlayerLevel[255] | by level (vt 0x4d8) |
| +0x10f | u8 bIsPlayerClass[64] | by class (vt 0x4dc) |
| +0x14f | u8 bIsMapID[1024] | by map id |
| +0x54f…+0x552 | u8 bIsField_KQ / _Battle / _ID / _Normal | add every map of that kind |
| +0x553 | u8 map[1024] (zone-side) | effective map set = bIsMapID ∪ kind tables |
| +0x953 | u8 active | start ≤ now < end |
| +0x954 / +0x955 / +0x956 / +0x957 | u8 has abstate / level filter / class filter / map filter | derived |

The four map-kind tables are 1024-byte arrays inside the manager (`g_GMEvents + 0x10 / 0x410 / 0x810 / 0xc10`,
KQ / battle / instance / normal); their filler was not traced.

```pseudo
GMEvent_Activate(mgr, e)                (after 0xD00B)              @ FUN_0046d5c0
    e.hasAbstate = any nRewardAbstateIndex ≠ 0xFFFF
    e.levelFilter = any bIsPlayerLevel[i] == 1;  e.classFilter = any bIsPlayerClass[i] == 1
    e.map[] = 0; for each bIsField_X == 1: e.map |= mgr.kindTable[X];  e.map |= bIsMapID; e.mapFilter = any set
    if time() ∉ [start, end): e.active = 0
    else e.active = 1; for every player: GMEvent_ApplyToPlayer(p, e)
GMEvents_Routine(mgr)                   (main loop)                 @ FUN_0046d7e0
    every 1 s (mgr+0x1010 = g_Now + 10):
        for each e: if time() ∉ [start, end): e.active = 0
                    else if !e.active: e.active = 1; for every player: GMEvent_ApplyToPlayer(p, e)
    # an event that ends is only marked inactive; already granted abstates run out on their own timer
GMEvents_ApplyAll(mgr, p)                                           @ FUN_0046d8e0
    for each e: GMEvent_ApplyToPlayer(p, e)
    # called from sp_NC_MAP_LOGINCOMPLETE_CMD (FUN_00443390), sp_GainExp (FUN_0042d830, i.e. level change)
    # and so_ply_ClassChange (FUN_004521b0): a player who enters, levels or changes class gets the running events
GMEvent_ApplyToPlayer(p, e)                                         @ FUN_0046d4d0
    if !(e.active and e.hasAbstate): return
    if e.levelFilter and !bIsPlayerLevel[p.level]: return          @ FUN_0046d260
    if e.classFilter and !(p.class < 64 and bIsPlayerClass[p.class]): return   @ FUN_0046d2a0
    if e.mapFilter and !(mapId(p) < 1024 and e.map[mapId]): return @ FUN_0046d300 (map id via FUN_004013d0 → FUN_0042ab10)
    GMEvent_GiveAbstates(p, e)                                      @ FUN_0046d380
        for each of the 3 abstate IDs that exists with a strength-1 block:
            keep = (end − time()) · 1000 ms when end is in the future, else the row's default keep time (block +0x2b)
            if p.vt[0x638](p, idx, 1, row, g_Now, 0, −1, keep, 0, 0) (set abstate, Z03 §2):
                BriefAbstateBit_Set; strength = DAT_00875220 clamped to 1..40 (1 if outside);
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

### 5.1 Mob data: `MobDataBox` (`g_MobData` DAT_14d44a38)

`MobDataBox::mdb_Load` @ FUN_00641e60 (start stage `home`, Z01-core §2.3) loads eleven SHN tables into `BinaryDataBox`es
inside the box, checks that MobInfo, MobInfoServer, MobSpecies and QuestSpecies have the same row count and the same ID in
every row ("MobDataBox::mdb_Load : Mob number mismatch" / "DataOrder mismatch", fatal), then builds one **entry per mob ID**
(`box+0x65c`, `(maxID + 1) × 0x34` bytes; max ID at `box+0x664`; name → ID index at `box+0x668`, `FUN_0063cc30(&DAT_14d450a0, name)`):

| Entry offset | Content | Filled by |
|---|---|---|
| +0x00 | → MobInfo row (client table, 2017 PDB `struct MobInfo`, layout holds for 2016: `ID +0, InxName[32] +2, Name[32] +0x22, Level +0x42, MaxHP +0x46, WalkSpeed +0x4a, RunSpeed +0x4e, IsNPC +0x52, Size +0x53, WeaponType +0x57, ArmorType +0x5b, GradeType +0x5f, Type +0x63, IsPlayerSide +0x67, AbsoluteSize +0x68`) | mdb_Load |
| +0x04 | → MobInfoServer row (0xa7 bytes, see below) | mdb_Load |
| +0x08 / +0x0c | MobWeapon list: array of `{ → MobWeapon row, u16 skill index, u32 abstate index (0x318 = none) }` (0xc each) / count | `mdb_SkillStore` @ FUN_00642630 |
| +0x10 | → MobSpecies row (`ID u16, MobName[33], 3 more names`) | mdb_Load |
| +0x14 | u16 MobResist row index (from MobInfoServer.ResIndex; 0xFFFF = "-") | mdb_Load, `MobResist` table DAT_150ba618 (FUN_00644e80) |
| +0x18 | → QuestSpecies row (`ID u16, MobGroupName[33] × 5`) | mdb_Load |
| +0x1c | → MobKillAnnounce row (`MobID u32, TextIndex u32`), or 0 | mdb_Load |
| +0x20 | → MobKillLog row (`MobID u32`), or 0 | mdb_Load |
| +0x24 | u32 MobLifeTime.LifeTime (seconds), 0 = none | mdb_Load |
| +0x28 | two flag bits, cleared at load (not traced) | — |
| +0x2c | → MobRegenAni row (`MobIDX[32], RegenTime u16 +0x20 (ms), GroupAbStateIDX[32] +0x22, IsAggro u8 +0x42`), or 0 | mdb_SkillStore |
| +0x30 | GroupAbState group number of the RegenAni row (−1 = none) | mdb_SkillStore |

`mdb_SkillStore(skillNames, abstateNames)` @ FUN_00642630 (start stage `sleep`, "MobDataBox link") runs over MobWeapon twice
(count, then fill), resolving `Skill` (+0x25, "-" = none) and `StaName` (+0x71) by name; unknown names are logged and the
weapon keeps 0xFFFF / 0x318. GroupAbState rows are grouped by `GroupAbStateIDX` into a multimap `box+0xa6c` (group number →
row; `AbstateIDX` +0x20, `Strength` u8 +0x40). Each MobRegenAni row is attached to its mob (duplicates and unknown names are
fatal) and its group is looked up by name.

MobInfoServer.shn (2016, 0xa7 bytes; column names from the SHN header): `ID u32 +0, InxName[32] +4, Visible u8 +0x24,
AC u16 +0x25, TB +0x27, MR +0x29, MB +0x2b, EnemyDetectType u32 +0x2d, MobKillInx u32 +0x31, MonEXP u32 +0x35, EXPRange u16
+0x39, DetectCha u16 +0x3b, ResetInterval u8 +0x3d, CutInterval u16 +0x3e, CutNonAT u32 +0x40, FollowCha u32 +0x44,
PceHPRcvDly u16 +0x48, PceHPRcv +0x4a, AtkHPRcvDly +0x4c, AtkHPRcv +0x4e, Str +0x50, Dex +0x52, Con +0x54, Int +0x56, Men +0x58,
MobRaceType u32 +0x5a, Rank u8 +0x5e, FamilyArea u32 +0x5f, FamilyRescArea u32 +0x63, FamilyRescCount u8 +0x67, BloodingResi
u16 +0x68, StunResi +0x6a, MoveSpeedResi +0x6c, FearResi +0x6e, ResIndex[32] +0x70, KQKillPoint u16 +0x90, Return2Regen u8 +0x92,
IsRoaming u8 +0x93, RoamingNumber u8 +0x94, RoamingDistance u16 +0x95, RoamingRestTime u16 +0x97, MaxSP u16 +0x99, BroadAtDead
u8 +0x9b, TurnSpeed u16 +0x9c, WalkChase u16 +0x9e, AllCanLoot u8 +0xa0, DmgByHealMin u16 +0xa1, DmgByHealMax u16 +0xa3,
RegenInterval u16 +0xa5`. `EnemyDetectType` values = enum `EnemyDetect` *(pdb2017)*: 0 ED_BOUT, 1 ED_AGGRESSIVE, 2 ED_NOBRAIN,
3 ED_AGGRESSIVE2, 4 ED_AGGREESIVEALL, 5 ED_ENEMYALLDETECT (2016 data: 220 / 1872 / 728 / 12 / 1 / 9 rows; the NOBRAIN rows
are shop NPCs and gates). The columns used by this section are named below; the AI columns are read in part 3.

`MobDataBox::mdb_CanIKill(mobId, identity)` @ FUN_006424c0 — may this kind of attacker kill the mob:

```pseudo
    if mobId == 0xFFFF: return true
    k = MobInfoServer.MobKillInx                               # enum MobKillType (pdb2017): 0 MKT_DEFAULT, 1 MKT_ONLYSCRIPT, 2 MKT_MOB
    if k >= 3: log "…Invalid MobKillType"; return false
    row = MobKillAble[k]                                       # MobKillAble.shn { MobKillInx, Cheat u8, Mob u8, User u8 }
    identity 0 → row.Cheat, 1 → row.Mob, 2 → row.User, 3 → true, other → log "Unknown identity", true
```

2016 rows: DEFAULT {1,1,1}, ONLYSCRIPT {0,0,0}, MOB {0,1,0}. Callers: player attacks and skills, `so_mobile_ICanDamageTo`,
the mob target selectors and the magic-field damage (Z03, part 3).

Other mob tables loaded elsewhere and read in this part:

- `MobConditionServer.shn` → `MobConditionChecker::MCC_DataRead` @ FUN_004b0460 into the map DAT_1328bcd0 (mob ID →
  vector of conditions, `FUN_004b0140(&DAT_1328bcd0, mobId)`; §5.6). Only `MC_Type` 0 is accepted (enum
  `MobCondition_Type` *(pdb2017)*: `MCT_HP = 0` is the only member); any other type fails with "Memory Alloc Fail" and the
  whole table is dropped. Consecutive rows of the same mob form one vector, in file order.
- `MobDeadCount` (`mdc_Clear` @ FUN_004b07b0, `mdc_Count` @ FUN_004b0820, `mdc_DeadCountGet` @ FUN_004b08f0, created by
  FUN_004b09f0): one u16 counter per mob ID, incremented by `ShineMob::so_KilledBy` (Z03 §8.1); readers are the map
  scripts (part 14–16).
- `MobAutoAction.shn` belongs to `BossFieldContent::MobAutomaticActionList::maal_Load` @ FUN_005d49f0 (part 16).

### 5.2 Mob members (offsets from the object start; *(ours)* names)

| Offset | Meaning |
|---|---|
| +0x4e / +0x52 / +0x56 | layer ids / "visible in all layers" flag (Z03 `SameLayer`); NPC.txt NPCs set +0x56 = 1 (FUN_0054aae0) |
| +0x66 → | position `{x, y}`; +0x6a → u8 direction (degrees / 2) |
| +0x76 → +4 | sub-layer (`so_SubLayer_CanSee`, Z02 §5): 0 normal, 3 hidden (StaGMHideMode) |
| +0x7a | → FieldMap |
| +0x7e / +0x82 | AI Lua script of the mob type (map DAT_14d712d0, keyed by MobInfoServer.ID) / std::string function name = MobInfo.InxName; 7 more strings follow (+0x9e … +0x146), cleared by vt 0xc14 FUN_00558c80 |
| +0x18c…+0x1b8 | MoveManager (part 5): +0x18c state, +0x1ac active |
| +0x184 | killer handle (`ShineMobileObject::so_KilledBy`) |
| +0xe9c → | mode byte (`GetMode` vt 0x484): 0 while spawning, 2 alive, 3 dead |
| +0xea0 / +0xea4 | timestamps set to g_Now at spawn (recovery timers, part 3) |
| +0xea8 / +0xeac | MaxHP (vt 0x4f0) / MaxSP (vt 0x4f4) |
| +0xfc0 | stat matrix (Z03 knowledge §2); base layer from MobInfoServer (§5.3) |
| +0x1d84 | cast block (Z03 §5) |
| +0x1e74 | rule set: `RulesOfEngagementNormalPY` (no weapon or first weapon `HitType` 0) or `…NormalMA` |
| +0x1e78 | flag byte: bit 0 invalid position, bit 2 Fear, bit 3 killed, bit 4 blast armed, bit 7 (vt 0xbf0) |
| +0x1e8c…+0x1e9c | movement detector (FUN_0055d610): +0x1e8c 1 = moving, +0x1e90/94 last position, +0x1e98 time of the last change, +0x1e9c next check |
| +0x1ea8 / +0x1eac | wander-chat timer `g_Now + t` / `t`, t = `MobChat` PIECE element of the mob ID (DAT_0084cc8c[mobId].vt[0](), ms → tenths; 10⁹ ms without a PIECE row) (§8.6) |
| +0x1ec0 | spawning breeder (MobBreeder, part 6; −1 for NPC.txt NPCs) |
| +0x1ec4 / +0x1ec8 | HP / SP |
| +0x1ecc | the mob's own brief-info packet 0x1C08 `NC_BRIEFINFO_REGENMOB_CMD`; its payload pointer is +0x1f74 (§5.3) |
| +0x1f78 | char map[12] (vt 0x4bc), the map the mob is spawned on |
| +0x1f84…+0x1f8c | spawn x, y, dir copied from the brief (vt 0xf6c) |
| +0x1f90 | → MobDataBox entry (vt 0x70c) |
| +0x1f94 | u8 level (MobInfo.Level unless the spawn gives one) |
| +0x1f98 | per-weapon cooldown: "usable again at" g_Now (one u32 per MobWeapon, zeroed at spawn; §7.4) |
| +0x1fa8 | current weapon index (−1 at spawn / none; §7.4) |
| +0x1fac / +0x1fb0 | `MobAttackSequence` record of the mob ID (`g_MobAttackSequence` DAT_0d76e9e8, FUN_0043f6e0) / sequence position (§7.6) |
| +0x1fb4 / +0x1fb6 | chained NextSkill skill ID (0xFFFF none) / "do not advance the sequence after this use" (§7.6) |
| +0x1fb8 / +0x1fba | death broadcast sent / killer handle (Z03 §8.1) |
| +0x1fbc / +0x1fc0 | death time / extra corpse time (vt 0xc3c, `cSetDeadDelayTime`) |
| +0x1fc4 / +0x1fc8 | brain context: tick argument / self |
| +0x1fcc | `MobAggroManager` (aggro list, 10 entries) followed by one selector object per `EnemyDetectType` (+0x2124 … +0x21fc, §6.1) |
| +0x2234 | → active target selector (§6.1; vt +8 per tick, +0x14 reset) |
| +0x2238 | tactic set (InMove … Turning, §7.1), bound to the target cell +0x24e0 by FUN_004b8c80 at spawn |
| +0x2260 / +0x227c | MobActionWander / MobActionAttack tactic elements (§7.1) |
| +0x22e4 | current tactic state (`MobActionWander`, `MobActionRoaming` 0x84cfc4, `MobActionNoBrain` 0x84cfc8) |
| +0x22e8 | regen slot of the breeder (+0x4c = time of the last spawn) |
| +0x22ec | guild number shown with the mob (`so_mob_SetGuildRegNum`, §5.8) |
| +0x22f0 | HitMeList (Z03 §8.2) |
| +0x249c/+0x24a0, +0x24a4/+0x24a8 | spawn point and return point (both = spawn position) |
| +0x24ac | flags (bit 0, 1 set at spawn; 2, 3 cleared) |
| +0x24ae | current fight target handle (`so_mob_CurrentTarget` vt 0xb78, §6.5); 0xFFFF at spawn |
| +0x24b0 | battle state: 0 idle, 1 battle (`sm_DuringBattle`), 2 recover (`sm_DuringRecover`) (§6.5) |
| +0x24b1 / +0x24b5 | family ring (prev / next mob of the same family; self when alone); vt 0x744 returns +0x24b1 |
| +0x24bc, +0x24c0, +0x24c4 | rescue flags (bit 0 healed / not asking, bit 1 called by a dying friend, bit 2 help chat said), → friend to help (0), friend's last seen HP (60000) (§6.6) |
| +0x24c8 / +0x24cc | script weapon rates `vector<u16>` (§8.2) |
| +0x24d8 / +0x24da | u16 roaming flags `IsRoaming & 1 | (RoamingNumber & 0x7f) << 1` / RoamingDistance |
| +0x24dc / +0x24e0 / +0x24e4 / +0x24e5 | last broadcast target / current target (vt 0xa04) / target-dirty flag / target order (vt 0xa08) |
| +0x24e8 | NPCAction trigger entry for this mob ID (map DAT_14d50784, FUN_005c4420), or 0 |
| +0x24ec | lifetime timer `{acc, period, active u8, start}` (vt 0xabc FUN_0055e5b0) |
| +0x24fc | abstate level at death (`smo_BossAbstateSet` / `sm_BossAbstateGet`, §8.9) |
| +0x2500 | resting until (vt 0xb34 / 0xb38, §7.1) |
| +0x2504 / +0x2508 | script overrides MaxHP / MonEXP (0 = table) |
| +0x250c | u8 drops enabled (1; `cSetNPCIsItemDrop` → vt 0xbb0 `so_mob_IsItemDropSetAtScript` FUN_004aa810) |
| +0x250d | copy of the mob's MobResist row (0x34 bytes) |
| +0x2544 | 6 at spawn; +0x2548 −1; +0x254c / +0x2550 / +0x2554 script WalkSpeed / RunSpeed / HPRegen (−1 = table); +0x2558 u16 0xFFFF |
| +0x255c | → MobConditionServer vector of the mob ID (or 0) |
| +0x2560 / +0x2564 | spawn time / "regen animation over" flag (AI waits for it) |
| NPC +0x2568 | u8 "from NPC.txt" (`so_npc_FromTable` vt 0xa80 FUN_004b19b0) |
| servant +0x2568…+0x2580 | servant row, master, follow target, explosion state / next time / count left (§8.8) |
| bandit +0x2666 | → bandit brief (`+0xc2` u8 object type, §5.10) |

### 5.3 Spawn: `so_mob_Regenerate` and `so_mob_RegenComplete`

Every spawner (breeders, scripts, NPCManager, GM commands) allocates a pool slot and calls vt 0x6e0:

```pseudo
ShineMob::so_mob_Regenerate(m, map[12], x, y, dirDeg, handle, mobId, briefArg, breeder, familyLeader,
                            regenSlot, level, _, layerA, layerB) → 0 | marking error      @ FUN_004b41b0
    m.breeder (+0x1ec0) = breeder;  m.map (+0x1f78) = map;  mode = 0;  m+0x2544 = 6
    m.vt[0xf70](handle, mobId, briefArg)        # brief: FUN_004b1120 → FUN_004b0d20: handle, mobid, flagstate 0,
                                                #   sAnimation "", nAnimationLevel 0, bRegenAni 0; entry = g_MobData[mobId]
    m.pos = (x, y);  m.dir = (dirDeg / 2, +180 if negative)
    entry = g_MobData[mobId]   (null when the ID is out of range or the row ID differs: "MobDataBox::operator [] :Invalid mob index")
    m.level = level >= 1 ? level : MobInfo.Level
    m.roaming (+0x24d8/+0x24da) from MobInfoServer.IsRoaming / RoamingNumber / RoamingDistance
    m+0x1eb8 = 0;  aggro list reset unless the current target is a pet (type 12)
    sm_SetBrain(m)                                                                  # part 3
    m.vt[0xf6c]()                                # spawn x/y/dir copied from the brief
    m.regenSlot (+0x22e8) = regenSlot
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
        so_AllOfRange_Class0(m, so_ExchageBriefInfo)           # brief info both ways with everything in sight (Z02 §5)
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
    regenSlot.lastSpawn = g_Now
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
ShineMob::so_Routine(m, _, tickArg)                                              @ FUN_0056baa0
    if mode == 0: return 1                                     # not spawned yet
    if the position is outside the field: log "fm_IsInFieldSize : Mob"; flags1e78 |= 1
    MobConditionServer step (FUN_00554420, §5.6)
    ShineMobileObject::so_Routine(m)                           # §5.5 (abstates, movement, casts)
    if flags1e78 & 1:  so_Unmark(0, 1, 3); som_FreeObject(m, reason 7); return
    if mode != 3 and m.npcAction (+0x24e8):                    # NPCAction proximity triggers (part 9)
        so_AllOfRange_Class1(m, range = MobInfoServer.DetectCha, NeighborhoodChecker(m.npcAction))   @ FUN_005c2ee0 / FUN_005c2fe0
    regen animation over? (FUN_0055e760): if no RegenAni row or g_Now > spawnTime + RegenTime/1000·10: regenAniOver = 1
    if m has StaImmortal (291) or StaAdlFLoussierIMT (499):
        run the AI Lua function only (below); return           # no AI while protected
    if battle state == 1: sm_DuringBattle(m)  elif == 2: sm_DuringRecover(m)        # part 3
    if flags1e78 & 4 (Fear): run the AI Lua function only; return
    if m.rescue (+0x24c0): so_RescueRoutine(m)                                       # part 3
    if mode == 3 (dead):
        if not deathSent:
            to sight (incl. players only, AllOfRange_Class1 … 1):
                0x244A NC_BAT_REALLYKILL_CMD { u16 dead = m.handle, u16 attacker = m.killer (+0x1fba) }   # size 6
            deathSent = 1
        if m.deadAt and g_Now − m.deadAt >= (m.corpseExtra · 5 + 50) · 2:          # = 10 s + corpseExtra seconds
            so_Unmark(0, 1, 3); som_FreeObject(m, reason 8)                         # respawn is the breeder's job (part 6)
        run the AI Lua function; return
    if m.entry == null: return
    if MobInfo row flag bit 0 of entry+0x28: sm_IBuffToBuffee(m)                     # part 4
    r = 2
    if m.script and g_AIScriptOn (DAT_14d41a7c, set by FUN_004511a0):
        r = LuaScriptScenario.lss_Routine(m.script, m.funcName, ctx{handle, field})  @ FUN_00507200 (ctx FUN_005d6ef0, result ctx+8)
            # calls the global Lua function named like the mob (MobInfo.InxName);
            # error → "LuaScriptScenario::lss_Routine : function call error"
    if regenAniOver and alive and HP != 0 and (not MoveManager.active or move state != 3):
        brain context = { self, tickArg }
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
    SetItemData_SkillEffect.se_Clear(&g_SetEffect)
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
Layout matches `PROTO_NC_ACT_ANIMATION_LEVEL_CHANGE_CMD` *(pdb2017)*.

### 5.7 Placing the mob: `so_MapMarking` → `FieldMap::fm_Marking`

```pseudo
ShineMob::so_MapMarking(m, force) → 0 | 3                                       @ FUN_004665f0
    field = the FieldMap whose map name equals m.map (ListSearchSame over g_FieldList)
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
           no object within `spacing` collides (so_AllOfRange_Class0(o, spacing, so_collesioncheck)):
            o.marked = 1; return 0
        next spiral point (FUN_00460910; at most 32 levels, "DropLocationManager::dlm_Getloc");
        none left: log "FieldMap::fm_Marking : Fail mark"; return 3
        outside the field: return 3
        ShineObject_SetPosition(o, point);  dlm_next
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
| `so_mob_SetGuildRegNum(g)` vt 0x900 @ FUN_00476110 | +0x22ec = g; to sight: 0x748D NC_GUILD_MOBGUILD_CMD { u16 handle, u32 guildNo } (size 8); `mb_SendMyGuildInfo` @ FUN_00475a80 sends the same to one newcomer when g ≠ 0 (Z02 §5). Client `ON_NC_GUILD_MOBGUILD_CMD` (client FUN_004ba6b0) keeps a map handle → guildNo in `CGuildMonster` (replacing an older entry). Used for guild-tournament / guild objects (Z08/Z16) |
| `so_mob_IsItemDropSetAtScript(b)` vt 0xbb0 @ FUN_004aa810 | dropsEnabled = b |
| `so_SendInform2Admin(gm)` vt 0x8d8 @ FUN_0058e5d0 | only calls `ShineMobileObject::so_SendInform2Admin` (the GM object-info dump; GM commands item) |

### 5.9 `ShineNPC` and `NPCManager`

`NPCManager` = `g_NPCRoleTable` DAT_0da29a60: 1024 entries of 12 bytes `{ → NPC.txt row, → NPCRole, u16 handle }`, +0x3000
= number of NPC.txt rows (the static part). Row and role classes: Z02 §6.1.

```pseudo
NPCManager::nm_SetNPC(nm)   (start stage `open`)                               @ FUN_004c6560
    for each static entry:
        mobId = g_MobData.index(row.MobName);  unknown → log "nm_SetNPC : Invalid mob id"; next
        npc = som_AllocObject(type 4)  (none → "Too many npc")
        r = npc.so_mob_Regenerate(row.Map, row.x, row.y, row.Direct, handle, mobId, 0, breeder −1, 0, 0, level −1, 1, 0, 0)
        npc.so_npc_FromTable()                                 # +0x2568 = 1
        if r != 0: som_FreeObject(reason 0x22); next
        npc.allLayers (+0x56) = 1;  entry.handle = handle;  entry.role.vt[0x2c](npc, row + 0x54)   # role init with RoleArg
        if NpcSchedule.shn has a row whose index (32 chars) equals row.MobName: so_Unmark(npc, 0, 1, 3)
                                                              # scheduled event NPCs stay off the map until WM 0x086A (Z01-core §10)
    qsort the static part by handle (FUN_004c52f0)            # NPCRoleTable_Find bsearches it, then scans the dynamic part

NPCManager::nm_DynamicRegenerateNPC(nm, from, name[32], map, x, y, dir)        @ FUN_004c6cd0
        # callers: GM command `&RegenNPC` (FUN_00421e50) and Lua `cNPCRegen` (FUN_005de700)
    from == null → "PFrom is not set: "; from's field option missing → "Unable to get Field Optionj: "
    mobId = index(name)  (unknown → "…Invalid mob id")
    find the static entry with MobName == name and Map == from's map ("i == nm_BufferPoint: " when none)
    npc = som_AllocObject(type 4) ("…Too many npc")
    x, y, dir = −1 → the row's values
    npc.allLayers = 1;  r = npc.so_mob_Regenerate(map, x, y, dir, handle, mobId, 0, −1, 0, 0, −1, 1, 0, 0);  npc.so_npc_FromTable()
    r != 0 → log "NPCRegenResult != FM_MARKSUCCESS: ", free (reason 0x2c)
    else: put { row, role, handle } into the first slot at index ≥ count whose handle is 0xFFFF
          (original bug) Z09-B2: when no slot is free the loop ends at index 0x400 and the entry is written there anyway,
          over `count` and the words after the table; the "nm_BufferArray Full" branch (free, reason 0x2d) is unreachable

NPC role entry release (FUN_004c5310): clear the dynamic entry with that handle (row, role = 0, handle = 0xFFFF);
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
    tell the GM "Changed from <mode> to 2";  mode = 2;  so_AllOfRange_Class0(n, so_BroadcastBriefInfo)

ShineNPC::so_mob_Regenerate @ FUN_004b4bc0: fromTable = 0, then ShineMob::so_mob_Regenerate (§5.3).
```

### 5.10 `ShineBandit` (scenario objects that switch between NPC and mob)

```pseudo
brief for bandits (vt 0xf70 FUN_004b11a0(handle, _, src)):  copy the brief from src (FUN_004b0bf0) into +0x2666,
    handle, type (+0xc2) = 4, +0xbe = 0, +0xc3 = 0;  spawn x/y/dir from +0x16/+0x1a/+0x1e of it (vt 0xf6c FUN_004b10c0)

ShineBandit::so_Routine(b, _, tickArg)                                         @ FUN_0056c630
    if b.type (+0x2666 → +0xc2) == 5 or invalid position: return ShineMob::so_Routine(b, _, tickArg)   # acts as a mob
    if outside the field: log "fm_IsInFieldSize : Bandit"; so_Unmark(0, 1, 3); som_FreeObject(reason 6); return
    smo_MoveByScenario(b);  ShineMobileObject::so_Routine(b)  # no AI while it is an NPC

ShineBandit::so_bandit_ChangeType(b, t)   (vt 0x898; map-script nodes ShineChange2Mob / ShineChange2NPC, part 15)   @ FUN_005508b0
    b.type = t
    to the whole map (so_AllInMap1): 0x6C0B NC_SCENARIO_OBJTYPECHANGE_CMD { u16 handle, u8 type }   # size 5
```

The client (`GameFrameWork::On_NC_SCENARIO_OBJTYPECHANGE_CMD`, client FUN_004a3580) stores `type` in the character
(+0x78c). Layout matches `PROTO_NC_SCENARIO_OBJTYPECHANGE_CMD` *(pdb2017)*. Which value each script node passes
(5 = mob, 4 = NPC *(inferred from the routine test and the spawn value)*) is read in part 15. The bandit name for
`vt 0x4a0` is `+0x2666 + 0x5b` (FUN_00556f20).

---

## 6. Mob AI 1: brain, target selectors, aggro, rescue

The mob's AI has two layers. The **target selector** (`MobTarget*`, one object per mob, chosen by `EnemyDetectType`)
keeps the aggro list and answers "whom do I fight". The **tactic state machine** (`MobTacticElement::*`, `+0x22e4`,
part 4) decides what to do each tick and asks the selector. This section covers the selector, the aggro list, the
battle / recover states and the call for help. Tactics, weapons and skills are part 4; movement is part 5.

### 6.1 Brain objects in the mob (`MobAggroManager` at +0x1fcc)

The mob constructor part FUN_0054ee00 builds, at `mob+0x1fcc`, a `MobAggroManager` (FUN_004bda50: a
`List<MobTargetStruct>` with **10 preallocated nodes** of 0x20 bytes) and right after it one selector object of every
class. `sm_SetBrain` points `+0x2234` at one of them:

| Mob offset | Class (constructor) | `EnemyDetectType` *(enum names pdb2017)* | 2016 rows |
|---|---|---|---|
| +0x2124 | `MobTargetBout` (FUN_004bd2c0) | 0 ED_BOUT, and every unknown value | 220 |
| +0x213c | `MobTargetAggresive` (FUN_004bd2e0) | 1 ED_AGGRESSIVE | 1872 |
| +0x2174 | `MobTargetNoBrain` (FUN_004bd410) | 2 ED_NOBRAIN | 728 |
| +0x218c | `MobTargetAggresive2` (FUN_004bd340) | 3 ED_AGGRESSIVE2 | 12 |
| +0x21c4 | `MobTargetAggresiveALL` (FUN_004bd2e0, vftable replaced) | 4 ED_AGGREESIVEALL | 1 |
| +0x21fc | `MobTargetAggresiveNoLevel` (same) | 5 ED_ENEMYALLDETECT | 9 |

`MobTargetPlayerCaptivate` is not in the mob; its only vftable write is in FUN_0055bc80 at `player+0x2a9d0`
(`param_1[0xaa74]`), i.e. a player-owned selector; its use with the charm state StaKarenCaptivate is *(inferred)* (§6.9).

```pseudo
ShineMob::sm_SetBrain(m)                                                        @ FUN_004b2480
    t = m.enemyDetect (+0x2544)                    # 6 = "use the table" (set at spawn, §5.3)
    if t == 6: t = MobInfoServer.EnemyDetectType
    sel = selector object for t (table above); unknown t → MobTargetBout and
          log "ShineObjectClass::ShineMob::sm_SetBrain Not Case EnemyDetectType"
    m.targetSelector (+0x2234) = sel.vt[0x10](m, &m.aggroManager)     # mts_Initialize, returns sel
```

Callers: `so_mob_Regenerate` (§5.3), the teleport FUN_005793e0 (`ShineMob::smo_Teleport` log string; part 5) and the
two setters below. `ShineObject::so_mob_SetEnemyDetect` exists as vt 0xba4 FUN_004aa630 (value 0…5, other → 6) and vt
0xba8 FUN_004aa3a0 (name `"ED_BOUT"` … `"ED_ENEMYALLDETECT"`, other → 6, null → 6 without re-brain); both call
`sm_SetBrain`. No caller of either slot was found in the 2016 zone (players / base objects: empty FUN_004aa5e0).

**Selector object layout** (all classes, base `MobTargetSelector` FUN_004a9b40, which is also an `AxialListIterator`):

| Offset | Meaning |
|---|---|
| +0x04 | → current target entry (`MobTargetStruct`); `&DAT_0da28aac` = the empty entry (no target) |
| +0x08 | squared search radius during a scan; best distance² found so far |
| +0x0c | → mob |
| +0x10 | `MobInfoServer.DetectCha` (detection radius) |
| +0x14 | → `MobAggroManager` (the aggro list, mob+0x1fcc) |
| +0x18 … +0x20 | built-in entry `{u16 handle, identity, → object}` filled by a scan (`ali_Work`) |
| +0x2c | Aggresive classes: a second container (FUN_0058a630; not used by the code read here) |

**`MobTargetStruct`** (0x20, list entry): `+0 u16 handle, +4 identity (vt 0x344: player = character number, mob =
spawning breeder; protects against reused handles), +8 → object, +0xc s32 aggro points, +0x10 time of the last
aggro (g_Now), +0x14 SpyNet intelligence report (`SpyNet::IntelligenceOffice::io_ReadReport`, part 4), +0x18 report
mask`. An entry with 0 aggro counts as free.

**Selector vtable** (byte offsets; names from profiler strings unless marked):

| Slot | Bout / NoBrain / Aggresive* | Meaning |
|---|---|---|
| 0x00 | `ali_Work` FUN_004a9e20 (Aggresive, ALL, NoLevel), FUN_004aa020 (Aggresive2), FUN_004add20 (Captivate) | one candidate of a range scan (§6.3) |
| 0x08 | `mts_Routine` FUN_004ac940 | per tick: expire entries (§6.2); called from `ShineMob::so_Routine` (§5.4) |
| 0x0c | `mt_InitRegen` FUN_004aced0 | `mob = arg`; erase all entries |
| 0x10 | FUN_004abf00 → `mts_Initialize` FUN_004abe40 | `(mob, aggroManager)`: store both, radius = DetectCha, target = none; returns the selector |
| 0x14 | `mts_AggroClear` FUN_004ad6f0 | erase all entries (battle over, §6.6) |
| 0x18 | FUN_004ad7b0 *(ViewAggroList; it carries the profiler string "MobTargetBout::mts_AppendAggroPoint")* | GM list (§6.8) |
| 0x1c | `mts_AppendAggroPoint` FUN_004ad9a0 | §6.2 |
| 0x20 | `mts_DecreaseAggroPoint` FUN_004ac3d0 | §6.2 |
| 0x24 | `mts_InitThink` FUN_004abf20 | target = none; radius = DetectCha; +8 = DetectCha² |
| 0x28 | `mt_SelectTarget`: Bout FUN_004acfc0, Aggresive/2/NoLevel FUN_004ad290, ALL FUN_004ab1b0, NoBrain FUN_004ac0d0, base FUN_004ac000 | §6.3; called by the tactics (part 4) |
| 0x2c | `mts_StoreAggroList` FUN_005d5250 (base FUN_005d30d0 returns −1) | append the handle of every entry with an object to a `vector<u16>`; returns the count |
| 0x30 | FUN_004bd630 | run a `SlayerCollect` iterator over the list (the kill-credit list of 0x244C NC_BAT_MOBSLAYER_CMD, Z03 §8.1 *(inferred)*) |
| 0x34 | `mts_AggroAdjust` FUN_004a7c50 | §6.2 |
| 0x38 | `mts_GetTopAggroTarget`: Bout/NoBrain FUN_004aa8d0, Aggresive* FUN_004aab80, ALL FUN_004aaf30 | §6.4 |
| 0x3c | "target is protected": Aggresive* FUN_004a9b90 (StaAdlFLoussierIMT 499, StaImmortal 291, StaHide 75), ALL FUN_004a9cb0 (291, 499) | no caller found in the code read here (part 4) |
| 0x40 | "level gap too big": FUN_004a9b70 `mobLevel − candLevel > 10`; NoLevel FUN_004021b0 always false | used by `ali_Work` |

Abstate numbers are `AbStataIndex` values (Z03 §1): 75 StaHide, 77 StaEntrapHide, 291 StaImmortal, 335 StaKarenCaptivate,
499 StaAdlFLoussierIMT, 562 StaWarLBrainWash.

### 6.2 The aggro list

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
            SpyNet::IntelligenceOffice::io_ReadReport(&e.report, mob, o.intelligence)   # part 4
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
    so_AllOfRange_Class1(p, range (0 = sight), AxialListAggroAdjust{permille})
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
    so_AllOfRange_Class1(m, centre, DetectCha, sel)       # sel.ali_Work for each object
    if found: m.so_mob_AppendAggro(found, m.level × 5)    # the new enemy enters the list with level × 5 points

MobTargetAggresiveALL select                                                    @ FUN_004ab1b0
    sel.target = the FIRST entry that passes the skip rules (not the highest aggro)
    if none and within 3000 of the spawn point: sel.+8 = DetectCha²; scan with sel over the field's sight range
        (FUN_00553c20: so_AllOfRange_Class1 with range 0 = the map's sight radius); the found object becomes the
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
        Layer_Match(o, m) and so_SubLayer_CanSee(o, m)  (Z02 §5)
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
        if on a field: cc_ScriptInterrupt(field.cinema (+0x44), sim_ObjectDead (FUN_0050c840), { u16 m.handle })
            # (original bug) Z09-B5: a mob that has finished healing is reported to the map scripts as "object dead"
        rescueFlags bit 0 = 1
    so_AllOfRange_Class0(m, sight, so_ply_Send2WhoTargetMe)  # every player whose target is m gets 0x2402 NC_BAT_TARGETINFO_CMD (Z03 §2.4)
```

So a mob regains 10 % HP and SP every 3 s after a fight (or the script value per step), and the players who target it
see the bar fill. During battle the mob does not regenerate (the `PceHPRcv*` / `AtkHPRcv*` columns are not read by the
code of this section; part 4 checks the tactics).

### 6.6 Calling for help (`sm_Scream4Rescue`, `so_RescueRoutine`)

```pseudo
ShineMob::sm_Scream4Rescue(m, target, range, count, flag)                       @ FUN_00568bf0
    race = MobInfoServer.MobRaceType;  if race == 0 or range <= 0: return
    if target == null: log "ShineObjectClass::ShineMob::sm_Scream4Rescue : Target not found"; return
    so_AllOfRange_Class1(m, m.pos, range, AxialListRescueRequest{ target, target.handle, race, count, flag })

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
`ATKTYPE` *(pdb2017)*: 0 SKLTP_DAMAGE, 1 SKLTP_HEAL, 2 SKLTP_ABSTATE, 3 SKLTP_SPECIAL, 4 SKLTP_DISPEL). `list` is the
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
    so_AllOfRange_Class1(m, 500, AxialListNearFriend{list, i}) → first hit, or 0
    AxialListNearFriend::ali_Work @ FUN_004aca50: skip dead; o.race (vt 0x714) != 0 and == m.race:
        result = o.so_mob_CanMyTarget(list, i); stop at the first result
    (base ShineObject FUN_004acb80: 0)
ShineObject::so_mob_CanNPCTarget(m)              (vt 0x750, mob version)                        @ FUN_004acd70
    so_AllOfRange_Class1(m, 500, AxialListNPCTargetFind{ mobId 0xbc (188), n = 1 }) → result
    AxialListNPCTargetFind::ali_Work @ FUN_004abd80: for objects with mob ID 188: the first one is taken; for later ones
        (n in 1…100) a value from the per-n random ring DAT_14d720d0 (0x8008-byte blocks) decides whether it replaces
        the choice (reservoir-style pick *(inferred)*); n += 1
    (base FUN_004acd20: 0)
```

`MOBATTACKTARGET` *(pdb2017)*: `MAT_ENEMY 0, MAT_ME 1, MAT_MYRACE 2, MAT_NONE 3, MAT_NPC 4` = `MobWeapon.MopAttackTarget`
(+0x69); the mapping to the four functions above (ME → vt 0x74c, MYRACE → vt 0x748, NPC → vt 0x750) is part 4's tactic code.
Mob ID 188 is the only NPC type a mob can pick as a target (MobInfo row 188; the escort / defence NPC *(inferred)*).

### 6.8 Script and GM access to aggro and AI

| Function | Behaviour |
|---|---|
| `cAggroSet(mob, obj, n)` FUN_005d9370 | `mob.vt[0x700](obj, n or 1)` |
| `cAggroReset(mob, obj)` FUN_005e1280 | `mob.vt[0x704](obj, 1000)`: obj's aggro drops to 1 |
| `cAggroListSize(mob)` FUN_005f2f70 | count from `vt 0xb88` |
| `cAggroList(mob)` FUN_005f3250 | pushes every handle of `vt 0xb88`; returns their number |
| `cIsInBattle(mob)` FUN_005ef430 | if `so_mob_CurrentTarget` (vt 0xb78) is an object within 999999999 distance² and the mob is not dead: returns that handle |
| `so_mob_GetAggroList(m, vec)` vt 0xb88 FUN_005d4dd0 | clears vec, `selector.vt[0x2c](vec)` (base FUN_005d4d50: −1) |
| GM `&viewaggrolist` (level 50, FUN_004196f0) | target = `gm.vt[0x75c]()` or the GM; if on a field: `target.so_mob_ViewAggroList(gm)` |
| `so_mob_ViewAggroList(m, gm)` vt 0x6fc FUN_0042d2a0 | `selector.vt[0x18](gm)`: GM notice per entry `"%d) %s : %d"` (index, name, aggro); without a selector a fixed notice (DAT_006aa168) |
| `so_AILearn(o, script)` vt 0xb60 FUN_005d5430 / mob FUN_005d5500 | null → vt 0xc14 (clear); else `o.script (+0x7e) = script`, function name (+0x82) = `"Entrance"`, for mobs `MobInfo.InxName` |
| `so_AITraining(o, other)` vt 0xb5c FUN_005d2680 | `other.so_AILearn(o.script)` (copy the AI script) |
| `so_EscapeFromTarget(o)` vt 0x64c FUN_00435ba0 | `AxialListTargetChange{o.handle, null}` over sight: every player (kind 2, vt 0x4d0) whose target (vt 0xa04) is o gets `so_ply_TargetChange(null)` (vt 0x998, Z03 §2.3 → 0x244D) (ali_Work FUN_00435ac0). Callers: magic-field damage, `smo_MagicFieldSpread`, `smo_SkillBash_Blast_Obj` |

The Lua bindings themselves (argument reading FUN_005f7680 / FUN_005f7ad0, result push FUN_005f8110) are part 9;
`cSetAIScript` / `cAIScriptSet` (callers of vt 0xb60 / 0xb5c) are listed for part 10.

### 6.9 Not in this section

- `MobTargetPlayerCaptivate` (`ali_Work` FUN_004add20, `mts_Initialize` FUN_004abde0, `mt_SelectTarget` FUN_004abe10): §8.10.
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
  `whokillme`); no zone string names the folder or a `.ps` path of it. Whether the PineScript loader (part 14) reads it
  stays open.
- Other aggro sources, documented with their owners: the map-script node `PineEventScriptNode::ShineAggro::sa_Step`
  FUN_004f2d10 (part 15), `AxialListMagicFieldAggro` (`alns_ValidObject` FUN_0057a980, `almfa_AppendAggro` FUN_0057aad0;
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
at **mob+0x1fc4** (`ctx+0 tickArg, ctx+4 → self`); everything below gives context offsets and, in brackets, mob offsets.
The same block is allocated for a **captivated player** (§7.7), so the code never uses mob offsets directly.

| ctx offset [mob] | Object | Kind |
|---|---|---|
| +0x008 [+0x1fcc] | `MobAggroManager` + selectors (§6.1) | |
| +0x270 [+0x2234] | → active target selector (§6.1) | |
| +0x274 [+0x2238] | `MobActionInMove` `{vt, next}` | tactic set, built by FUN_00549bc0 (so `+0x2238` is not an "aggro container" as §5.2 said: `FUN_004b8c80(set, cell)` at spawn stores the shared **target cell** `&mob+0x24e0` into every element through vt 0x14) |
| +0x27c [+0x2240] | `MobActionInMove_Cancelable` `{vt, next}` | |
| +0x284 [+0x2248] | `MobActionInChase` `{vt, → target, next-on-arrival, next-if-target-moved, target destination x, y}` | |
| +0x29c [+0x2260] | `MobActionWander` `{vt, timer A {next, period}, timer B, timer C}` (ctor FUN_004b8ad0) | |
| +0x2b8 [+0x227c] | `MobActionAttack` `{vt, → cell, u32 next attack time, u16 script skill (0xFFFF none), u32 script weapon, → script target}` (ctor FUN_004b9540) | |
| +0x2d0 [+0x2294] | `MobActionChase` `{vt, → cell}` | |
| +0x2d8 [+0x229c] | `MobActionBackStep` `{vt, → cell, u8 extra distance}` | |
| +0x2e4 [+0x22a8] | `MobActionAvoidOverlap` `{vt, → cell}` | |
| +0x2ec [+0x22b0] | `MobActionWaitSkillEnd` `{vt, until, next, target}` | |
| +0x2fc [+0x22c0] | `MobActionSwingDamage` `{vt, delay, target, next}` | |
| +0x30c [+0x22d0] | `MobActionTurning` `{vt, next, target, u16 TurnSpeed, start time}` | |
| +0x320 [+0x22e4] | → current state | |

Singletons (one object for all mobs; `PTR_vftable_…` globals, classes from RTTI): `MobActionBase` 0x84cfb8,
**`MobActionTargetting` 0x84cfbc** (the hub every state falls back to), `MobAction2Region` 0x84cfc0, `MobActionRoaming`
0x84cfc4, `MobActionNoBrain` 0x84cfc8, `DuringReturn2Regen` 0x84cfcc. The "cell" is a pointer to the shared target slot
(mob+0x24e0, read by vt 0xa04); writing `*cell = obj` before switching state hands the target over.

**Element vtable** (byte slots; all classes):

| Slot | Meaning | Implementations |
|---|---|---|
| 0x00 | `mab_Think(ctx)` → next state | per class (below); `MobActionBase` FUN_004b8ec0 → Targetting; `MobActionNoBrain` FUN_004b8c50 → itself (never moves, never fights) |
| 0x04 | damaged notify (`so_DamagedBy`, §6) | `MobActionWander` and `InMove_Cancelable` FUN_004b8c10: `so_mobile_StopHere` (vt 0xa48), state = Targetting; others no-op |
| 0x08 / 0x0c | target handle / object (mob vt 0x754 / 0x75c, §6.5) | Attack, Chase, BackStep, AvoidOverlap: FUN_004b8a60 / FUN_004b8a80 (`*cell`); others 0xFFFF / 0; `WaitSkillEnd` +0xc: FUN_00461b70 |
| 0x10 | re-plan (mob vt 0x8f8, §6) | FUN_004b8c40 → Targetting (all) |
| 0x14 | bind the target cell | FUN_00653a60 (`this+4 = cell`) for Attack, Chase, BackStep, AvoidOverlap; others no-op |
| 0x18 | `mab_SkillRegistAtScript` | Attack FUN_004b9400 (§8); base FUN_004b93b0 returns false |
| 0x1c | "waiting for a skill to end" | `WaitSkillEnd` FUN_005af8d0 → 1; others 0 |

`MobActionElement` (vftable 0x6c15b4, ctor FUN_004a9b00, dtor FUN_004a9dc0) is an unrelated base whose `mae_Action`
FUN_004aa880 returns a static empty object; no caller of it was found.

Helpers used throughout (mob slots unless noted):

| Helper | Meaning |
|---|---|
| `FUN_004b8830(selector)` | the selector's current target object, or **0 when it has StaImmortal (291) or StaAdlFLoussierIMT (499)** (the name is copied to a debug ring) |
| `ShineMob_SetCurrentTarget` FUN_004b8930 | +0x24ae, raises `sim_TargetChange` (§6.5) |
| vt 0x510(t) FUN_005566c0 | attack reach to `t` = `t.vt[0x6cc]()` (body size) + current weapon `Range` (+0x67); 99999 without a weapon |
| vt 0x514 / 0x518 | walk / run speed: script override (vt 0xe84/0xe8c, 0xe88/0xe90) else (script +0x254c / +0x2550 ≥ 0 ? it : MobInfo.WalkSpeed / RunSpeed) × speed rate (+0x1c00) / 1000, clamped ≥ 0 (FUN_00556740 / FUN_005567b0) |
| vt 0x610 | moving (`MoveManager` +0x1ac, part 5); vt 0x7b4 move mode (+0x18c: 1 walk, 2 run), vt 0x7b0 current speed (+0x194) |
| vt 0x60c | the object's move destination (+0x1a0) |
| vt 0x614 / 0x618 | spawn point +0x249c / return point +0x24a4 |
| vt 0x61c | leash² = `MobInfoServer.FollowCha` (+0x44)² |
| vt 0xb34(t) / vt 0xb38 | rest until `t` (+0x2500) / resting (`g_Now < +0x2500`, else clears it) |
| vt 0xa08(v) | target-order byte +0x24e5; sets the dirty flag +0x24e4 when target or order changed (§5.2) |
| vt 0xf54 / 0xf4c / 0xf50 | set / read "was chasing" (+0x24ac bit 3) / spawn point := the current scenario path point (FUN_004b7690, path vector +0x1eb8, 0x2a-byte points, index +0x1ebc) |
| vt 0xa18 | scenario path vector +0x1eb8 (part 5); non-zero = walk the path instead of wandering |
| `FUN_004011c0(timer)` | periodic timer `{next, period}`: fires when `next < g_Now`, then `next += period` |
| `ShineObject_so_FindBlockLocate(o, pos, r, out, bitmap)` | nearest unblocked point to `pos` within `r` (part 5) |
| `DAT_0084cfb4` | "use `Navigator`" byte, initial value **1** and never written: the old block path finder branches (FUN_004a9ae0 + FUN_00632ba0 / FUN_00632450, "Path not found", "MobThink_Chase::mtc_pathfind : Zero path") are dead in 2016 |

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
    w = weapon i of the MobDataBox entry; if no row: log "MobTacticElement::MobActionTargetting::mab_Think : Null Weapon"; return Targetting
    o = weapon target (§7.5) by w.MopAttackTarget
    if o:
        (t or o having 291 / 499 is only logged)
        s.vt[0xa08](1); *cell = t; return Attack    # note: the cell gets the selector's target, not o
    # the weapon cannot be used on anybody now: skip it
    FUN_004b8c60(s)                                 # advance the attack sequence (§7.6)
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
    if timer A fired: return 2Region                 # every (r + 55) s: go home
    if timer B fired: return Targetting              # every 1 s: look for targets
    if s is a ShineMob and its chat timer (+0x1ea8, §5.2) fired: MobChatManager::mcm_WanderChat(s)    # §8
    if timer C fired (1 s) and rand(100) < 5:        # random ring DAT_14d720d0
        InMove_Cancelable.next = this
        return mab_RandomDirectWalk(s, 30 + rand(20), InMove_Cancelable, this)
    return this

MobActionWander::maw_MetronomeReset(w)                                          @ FUN_004b9210
    r = next value of the u16 random ring DAT_14dc2120 (range not traced)
    timer A = { g_Now + (r + 55) × 10, (r + 55) × 10 };  timer B = timer C = { g_Now + 10, 10 }
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
        dx, dy = cos/sin table DAT_13283770 (FUN_005790e0 / FUN_00579110) × dist / 1024
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
    if not t: log "MobTacticElement::MobActionAttack::mab_Think : Target Null"; return Targetting
    if t closing (vt 0x300) or t.mode in {3 dead, 0 spawning} or t.IsDead(): return Targetting
    if s.IsCasting(): return this
    if not SameLayer(s, t) or t is a captivated player: return Targetting
    if t has StaImmortal (291) or StaAdlFLoussierIMT (499): return Targetting
    if MobInfoServer.TurnSpeed (+0x9c) != 0 and the angle from s's direction to t > 15 (2° units, ddt_ShineRadianDiff):
        return Turning.set(next = this, s, t)                              # FUN_004b8a00, §7.3 Turning
    if FindBlockLocate(s, t.pos, 10000, bitmap A) != t.pos:                # target stands on a blocked cell
        return rand(1000) < 800 ? (Chase.cell = t; Chase) : Targetting
    if s moving: StopHere
    if this.scriptSkill (+0xc) == 0xFFFF: s.so_mob_SelectWeapon(t, advance = 1)   # §7.4
    else: s.so_mob_SetWeaponAsScript(low byte of this.scriptWeapon (+0x10))        # vt 0xb74, §8
    if s is not a ShineMob:                                                 # captivated player
        return FUN_004ba0d0(this, ctx)                                      # §7.7
    sm_SkillExchange_HPLow(s); FUN_004bb600(s) (HPLow_ChangeOrder)          # §7.6
    i = current weapon (+0x1fa8, vt 0x740); if i < 0: return this
    o = weapon target of weapon i (§7.5)                                    # MAT_NONE / unknown → log, o = 0
    if this.scriptTarget (+0x14): o = scriptTarget; maa_SkillFromScriptClear(this)    # FUN_004b9470
    if not o: return Targetting
    d² = dist²(o, s)
    if d² > reach(o)²: sm_SkillExchange_TargetState(s, o)                   # §7.6 (yes: only when out of reach)
    if d² > reach(o)² (reach of the possibly exchanged weapon) and not sm_SkillExchange_OutOfRange(s):
        return rand(1000) < 800 ? (Chase.cell = o; Chase) : Targetting
    # attack now
    sm_UseWeapon(s, o)                                                      # §7.4
    s.vt[0x718]()                                                           # weapon cooldown
    r = min(reach(t) / 4, 150)
    swing = SwingTime (+0x4b) tenths (vt 0x71c);  cast = skill CastTime (FUN_004b88e0, 0 for weapon 0)
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
        ShineMob: s.vt[0xf74]() (ShineServant FUN_004a3480: vt 0xf7c(0); mob no-op)
        return 2Region
    if dot(s − t.pos, s − t.destination) < 1:        # the target is coming at us / passing us
        mab_RunTo(s, t.pos); Attack.cell = t
        return InChase.set(t, Attack, this)          # FUN_004b89c0 (stores t's destination)
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

MobActionTurning (set FUN_004b8a00, think FUN_004b9ea0):
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
sight (so_AllOfRange_Class1, radius DAT_132826b4) ← 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD / 0x201A NC_ACT_SOMEONEMOVERUN_CMD {
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
weapon rate(m, i)                                                               @ FUN_004aa060
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
        sk = SkillDataBox_Find(weapon skill)
        if not sk: log "ShineObjectClass::ShineMob::sm_UseWeapon : Null skill"; return
        if m.SP < sk.SP (+0xa0): log "…sm_UseWeapon : Minus sp"; return
        if sk.+0x130: m.flags1e78 |= 2               # "alternate damage path" (Z03 knowledge bit 1)
        tgt = sk.First (+0xb8) == 1 (ME) ? m : t;  pos = tgt.pos
        if sk.+0x220 == 1 and sk.+0x224 in {0, 2}:   # a SkillSpecial "random target" kind (offset mapping inferred, Z03 §5.1)
            if sk.First == 4 (SPOT): if not m.vt[0xc20](sk, &pos) (FUN_00579910: random point within Range): pos = tgt.pos
            else: o = m.vt[0xc1c](sk, Range, m) (FUN_0057e660: random object of the Last target class in sight); if o: tgt = o
        if sk.+0x260 == 1 and sk.First == 4 and (o = m.vt[0xc1c](sk, Range, m)): pos = o.pos
        smo_SkillBash_Casting(m, sk, First == 4 ? null : tgt, First == 4 ? &pos : null, CastTime (+0xcb))   (Z03 §5)
        if sk.+0x238 == 1: FUN_00553510(m, 0)        # sight ← 0xBC1C {u16 handle, u8 direction} (the "face direction"
                                                     #   broadcast that Z06 also uses under the 2017 name NC_GAMBLE_ENTER_PLAYER_DIRECT_CMD)
    if m.+0x1fb6 == 1: m.+0x1fb6 = 0                 # a chained NextSkill was used: the sequence does not advance
    else: FUN_004b8c60(m)                            # advance the sequence position (§7.6)
    for each abstate on m: aeo_Attack                # abstates that react to attacking (Z03 §6)

cooldown (vt 0x718)                                                             @ FUN_00556d00
    if weapon >= 0: cooldown[weapon] = g_Now + ceil(AttackSpeed / 100)       # tenths
AttackSpeed (vt 0x508)                                                          @ FUN_00556640
    AtkSpd (+0x45) × param[0xa18] / 1000 (≥ 0); 99999 when weapon < 0 or the row is missing
    (the row is read before the index is checked; the only mob caller, vt 0x718, checks the index first, so this
     does not fault; the other vt 0x508 callers are the player schedule functions FUN_0042f550 / FUN_00430bc0, Z03)
swing time (vt 0x71c)  FUN_005564f0: SwingTime × 10 / 1000 tenths (0 without a weapon)
```

### 7.5 Weapon target by `MopAttackTarget`

Both Targetting and Attack resolve "on whom is weapon `i` used" the same way (`MOBATTACKTARGET` *(pdb2017)*; 2016 data:
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
step label `mobattseq`, before `chargedbuffdatabox`) into `g_MobAttackSequence` **DAT_0d76e9e8** `{u32 count; record[400]}`
(records built by `_eh_vector_constructor_iterator_` with FUN_0043be70, sorted by mob ID with `qsort` after each append,
looked up with `bsearch` FUN_0043f6e0 at spawn → mob+0x1fac; sequence position mob+0x1fb0 = 0):

```pseudo
for every MobInfo row (in table order):
    file = "../9Data/Shine/MobAttackSequence/<MobInfo.InxName>.txt"; skip if it does not open
    parse (ShineDataFile); on error log "MobAttackSequence::mas_Load : Option read error" and stop the server
    if count > 399: "…mas_Append : Too many element" (fatal); record = { mobId, length 0 }; count += 1; qsort
    table AttSeq (columns Order WORD, Attack STRING[33]): for i = 0, 1, 2 …: the Attack value of the row whose Order == i
      (FUN_006483d0(file, "Attack", …, "Order", i), key lookup *(inferred)* from the arguments), until none is found:
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
            #   no zone-wide exception trap were found. Uncertain how 2016 servers survived this (sweep / review: check SEH)
        if found and to != 0xFFFF and some weapon ≥ 1 has skill to: m.chainedSkill = to
    return result

advance (FUN_004b8c60 → FUN_004a8500):  *pos += 1; if *pos >= length: *pos = repeatStart
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
| HPLow_ChangeOrder FUN_004bb600 *(ours: `sm_SkillExchange_HPLowChangeOrder`)* | +0x1be4 | entry position == sequence position (+0x1fb0) and `HP < MaxHP × Value / 1000` | Attack, after HPLow |

`HPLow_ChangeOrder` (367 of 400 rows) lets a boss play a different skill at given sequence positions once its HP drops
below a threshold (e.g. `EglackMad`: below 40 % / 70 %). Unlike the others it ignores `from`.

### 7.7 Captivated players

When a player becomes captivated (StaKarenCaptivate 335 / StaWarLBrainWash 562, Z03 §6.6), `ShinePlayer` vt 0xf1c
FUN_00564e50 (wraps `smo_SetCaptivate`) builds a 0x324-byte brain: `+4 → player`, `+8` brain objects
(`ShineMob_BrainObjects_ctor` FUN_0054ee00), `+0x270` = the player's `MobTargetPlayerCaptivate` selector (+0x2a9d0,
§6.9) initialised with them, `+0x274` the tactic set bound to the cell `player+0x2aa28`, state = Targetting; the pointer is
kept at `player+0x2a9cc`. Captivate off destroys it and clears the pointer (Ghidra cuts the decompile at the
`operator delete`, FUN_0065677f is wrongly marked no-return; the disassembly at 0x564f74 clears +0x2a9cc).
`ShineMobileObject::so_Routine` (§5.5) calls vt 0xf24 FUN_005601e0 for a captivated object: one tactic step.

The tactic code branches on "not a ShineMob": Targetting attacks the selector's choice (a player only, §6.9), Chase runs
(after `smo_BashStop`), and Attack ends in

```pseudo
captivated attack(this, ctx)                                                    @ FUN_004ba0d0
    p = ctx.self (ShinePlayer);  t = *cell
    if dist²(p, t) > reach²: Chase.cell = t; return Chase
    if t != p:
        p.so_ply_TargetChange(t)                    # vt 0x998
        FUN_005497e0(p, 2)
        if player state (+0x2a790) not in {2, 3}: run the client handler 0x242B NC_BAT_BASHSTART_CMD for p (Z03 §2)
    return Targetting
```

so the victim auto-attacks other players with normal attacks through the ordinary player attack path.

### 7.8 `so_attack` and `so_Bash` are dead code in 2016

`ShineMob::so_attack` FUN_0042ce00 (vt 0x580 of ShineMob / NPC / Bandit / Pet / Servant) → `ShineMobileObject::so_attack`
FUN_0042cab0 (damage from the rule set at 0x858ecc through FUN_004fc4a0) → vt 0x584 FUN_0042cb80, which logs
"ShineObjectClass::ShineMobileObject::so_attack called", applies the damage and broadcasts **0x2404 / 0x2405
NC_BAT_SOMEONEDAMAGED_SMALL / LARGE_CMD** `{u16 attacker, u16 target, u8|u16 damage, u8 action}` (or 0x2406 / 0x2407
`NC_BAT_SOMEONEDEAD_SMALL / LARGE_CMD`, same layout, when the hit kills; small when damage < 256) *(names pdb2017)*. No
code calls vt 0x580 or 0x584 (no `+ 0x580` / `+ 0x584` call in the export except FUN_0042cab0 itself, and no direct
call of FUN_0042ce00). Likewise `so_Bash` (vt 0x598: `ShineMobileObject::so_Bash` FUN_0042e950, `ShinePlayer::so_Bash`
FUN_0042efb0, packets 0x242C–0x2431, Z03 §3.5) has no caller at all. The live mob attack is §7.3 (`SWING_START` +
`smo_SwingDamage`) and `smo_SkillBash_Casting`. This corrects Z03 §3.5 ("reached from `so_attack` … and the `&`
commands") and narrows Z03 §7.1 (0x2406 / 0x2407 exist only in this dead path).

### 7.9 Continued in §8

The script-driven skills and weapon rates, mob chat, servant explosions, boss-field hooks, the cross-counter and the
hit / heal rules of the non-player classes are §8.

---

## 8. Mob AI 2b: script control, chat, servant explosions, boss hooks, hit rules

Part 4b. Helpers as in §7.1. `RandomRing(n)` *(ours)*: the next value of a pre-filled ring of random numbers below `n`
(`DAT_14d720d0 + n × 0x8008`: 0x4000 u16 values, index at +0x8000, mask at +0x8004); only for `1 ≤ n ≤ 100`, else 0.
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
    sp_castabort(m)                                              # vt 0xed4 FUN_00579d50: no-op here (it acts only while casting)
    Attack = m+0x227c;  maa_SkillFromScriptClear(Attack)         # FUN_004b9470: skill 0xFFFF, weapon −1, target 0
    *Attack.cell = target                                        # FUN_004b89a0 (returns Attack)
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
    sk = SkillDataBox_Find(skill ID of weapon slot i)
    if sk and m.SP (vt 0x4ec) >= sk.SP (+0xa0): weapon (+0x1fa8) = i; return i
    weapon = −1; return −1
ShinePlayer / other classes: FUN_004d8e20 returns −1
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
    FUN_004a9d50(m, …): stat matrix +0x10a0 MinWC = p[0], +0x10a4 MaxWC = p[1], +0x10ac TH = (u16) p[2],
                        +0x10b4 MinMA = p[3], +0x10b8 MaxMA = p[4], +0x10c0 MH = (u16) p[5];  return true
ShineMob::so_mob_SkillParameterSet(m, skillId)               (vt 0xb90)        @ FUN_005d2e90
    the same six values from the MobWeapon row of skillId (MinWC +0x53, MaxWC +0x57, TH +0x5b, MinMA +0x5d, MaxMA +0x61,
    MH +0x65); false when the mob has no such weapon
```

Callers (all Lua C functions, documented in part 10): `cNPCSkillUse(caster, target, skillName)` FUN_005ef5c0 → vt 0xb7c;
`cSkillBlast(caster, target, skillName, range)` FUN_005f0960 → vt 0xb84 after `dist² ≤ range²` (range 0 → 1000);
`cSkillDamageCalculate(caster, skillName, target, params)` FUN_005f1370 → vt 0xb94 when `params` is a table, else vt 0xb90,
then returns the skill's computed damage. Skill names resolve through `FUN_0063cc80(&DAT_13286d08, name)`.

### 8.2 Weapon rates set by scripts

`weapon rate(m, i)` (§7.4, FUN_004aa060) prefers the vector **+0x24c8 / +0x24cc** (`vector<u16>`, per mille) over
`MobWeapon.BlastRate`; it is only read by `so_mob_SelectWeapon` for mobs without a `MobAttackSequence`. The vector is
replaced as a whole and lives until the mob object is reused (the respawn in §5.3 does not reset it *(inferred: no write
to +0x24c8 found outside FUN_0050dfa0)*).

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
        ctx = damage context (t, a, skill, empower +0x1dac, t.position)          # FUN_0042abf0
        if effect.vt[0x20](ctx):                       # the effect applies to a
            dmg = effect.vt[0x1c](ctx)                 # damage t's skill would have dealt to a
            t.flags1e78 &= ~0x10;  t.cast (+0x1d84) = 0     # t's skill is cancelled
            return dmg
    return −1

ShinePlayer::so_smo_CrossCounterDamage(p, a)                                   @ FUN_004a54b0
    if (d = base(p, a)) >= 0: return d
    if p's attack schedule (+0x173d0) is running and its current target handle == a.handle (vt 0x344):  # FUN_00576000 / FUN_005776d0
        p.vt[0x588](); a.vt[0x588]()                   # both "in battle" (§6.5)
        dmg = p.rules (+0x1e74).vt[0x1c](ctx);  hit = rules.vt[0x18](ctx)     # normal-attack damage and hit rate
        if rand(1000) <= hit: advance the schedule past this swing (FUN_00577780); return max(dmg, 1)
    return −1

ShineMob::so_smo_CrossCounterDamage(m, a)          (pet, NPC, bandit, servant too)  @ FUN_004a56a0
    if (d = base(m, a)) >= 0: return d
    if m.flags24ac & 4 (between swing start and hit of a normal attack, §7.3):
        m.vt[0x588](); a.vt[0x588]()
        dmg = m.rules.vt[0x1c](ctx);  m.flags24ac &= ~4
        m.tactic = Targetting
        m.vt[0xed8]()                                  # FUN_0042adf0: 0x243D NC_BAT_CEASE_FIRE_CMD { u16 handle } to sight
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
    if s.+0x2594 bit 0 (vt 0xdec FUN_0054af90: "independent" servant): return ShineMob rule (above)
    return s.master (+0x256c) ? master.vt[0x980](d, why) : false              # otherwise the master's (player) rules
ShineServant::smo_ICanHealTo(s, d)                                             @ FUN_004356b0
    return s.master ? master.vt[0xe94](d) : false
ShineServant same side (vt 0xe60)  FUN_0054b100: master ? master.vt[0xe60](d) : ShineMob_IsSameSide(s, d)

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
    d mob / bandit / NPC: not same side (vt 0xe60, FUN_0054b130 = the rider's answer through vt 0xcb0),
        not the mover's guild, and d has a mob row (vt 0x70c) → true
```

The mover differs from the player version in one place: outside kingdom-quest maps it never may damage a player or
mover (the player version falls through to the free-PK / party / guild rules). Whether this is meant (movers as KQ
vehicles) is open (§8.11).

### 8.5 `smo_SkillBlastTick` (vt 0xf14): delay between a skill's blast and its damage

Used by `SkillBlastEffectContainer::sbec_Store` FUN_00438380 (Z03 §5: the effect is queued at `g_Now + tick`).

| Class | Function | Value (tenths) |
|---|---|---|
| base (door, mover) | FUN_004358e0 | 0 |
| player | FUN_00435930 | `skill.server.HitTime (+0x4b) × 10 / 1000`; 100000 without a skill |
| mob, NPC, bandit, pet, servant | FUN_004359b0 | the **current weapon's `MobWeapon.HitTime` (+0x4d)** × 10 / 1000 when the weapon index is valid, else as the player (99999 without a skill) |

This corrects Z03 §5 ("mobs 0"): only doors and movers use 0.

### 8.6 Mob chat (`MobChat::MobChatManager`, `DAT_0084cc84`)

Data: `World/<world>/MobChat.txt`, falling back to `World/MobChat.txt` (2016: only the fallback exists), loaded by
**`MobChatManager::mcm_Load`** FUN_004af640, called once at start-up right after `mdb_Load` (call at 0x5add9b, argument =
the world folder name DAT_14d460bc). If neither file reads: log "MobChat::MobChatManager::mcm_Load : Error in Script read"
(the server continues with empty tables).

Seven tables, identical columns `MobIndex (mob InxName), Rate0 u32, Rate1 u32, Script0…Script3 char[65]`:

| Table (code name) | Array (manager +) | Element class, slot | Fired by | 2016 rows |
|---|---|---|---|---|
| `PIECE` | +0x08 (DAT_0084cc8c) | `MobChatElementWander` (0x130 bytes): vt 0 interval, vt 4 `mceb_WanderChat` | idle timer +0x1ea8 in `MobActionWander::mab_Think` FUN_004bb790 (§7.2) | 330 |
| `ATTACK` | +0x0c | `MobChatElement` (0x128), vt 8 `mceb_AttackChat` | normal attack (weapon 0) in `sm_UseWeapon` (§7.4) | 330 |
| `DAMAGED` | +0x10 | vt 0xc `mceb_DamageChat` | every hit, `ShineMob::so_DamagedBy` FUN_00431750 (Z03) | 330 |
| `DEAD` | +0x14 | vt 0x10 `mceb_KilledChat` | `ShineMob::so_KilledBy` FUN_00432760, after the kill bookkeeping | 330 |
| `HELPMAIN` | +0x18 | vt 0x14 `mceb_HelpReqChat` | the mob calling for help, `sm_DuringBattle` FUN_00568d30 (§6.6, once per fight: rescue flag bit 2) | 32 |
| `HELPSUB` | +0x1c | vt 0x18 `mceb_HelpAckChat` | a helper answering, `so_RescueRoutine` FUN_00569050 (§6.6, flag bit 1) | 32 |
| `RACERESCU` | +0x20 | vt 0x1c `mceb_DetectBattleChat` | a helper noticing a fight, `so_RescueRoutine` (§6.6) | **0 loaded** (file: 32 `RACERESCUE` rows) |

```pseudo
MobChatManager::mcm_Load(mgr, world)                                           @ FUN_004af640
    mgr.count (+0) = maxMobId (DAT_14d4509c) + 1
    7 arrays of count pointers, every slot = &mgr+4    # a static MobChatElementBase (vftable 0x6c1f94): every chat is a
                                                       #   no-op, interval FUN_004ae540 = 1 000 000 000
    for every MobInfo row r (r < DAT_14d45098):
        e = g_MobData entry of r.ID; if none: log "…mcm_Load : Null inf" (fatal log)
        for each of the 7 table names (char[20], compared as 5 dwords: TableNameCompareArgument FUN_006470f0):
            rec = record of that table with MobIndex == MobInfo.InxName (FUN_00647c00); if none: continue
            if slot already set: log "…mcm_Load : Duplicate entry"          # cannot happen: each mob is visited once
            slot[r.ID] = new element(rec)                                    # FUN_004aeb20 copies the record
            PIECE only: range = Rate1 − Rate0; mult = 1; while range > 99: range /= 2, mult *= 2
                        element +0x128 = range, +0x12c = mult
            (a record of an unknown table logs "Invalid Flag": unreachable, the names are fixed)
    element.lines (+0x124) = number of Script columns before the first one that starts with '-' (0…4)

MobChatManager::mcm_<X>Chat(mgr, m)                (Wander FUN_004ae570, Attack FUN_004ae640, Damage FUN_004ae710,
                                                    Killed FUN_004ae7e0, HelpReq FUN_004ae8b0, HelpAck FUN_004ae980,
                                                    DetectBattle FUN_004aea50)
    id = m.mobId (vt 0x70c row → u16 ID); if id < mgr.count: array_X[id].vt[slot_X](m)

MobChatElement::mceb_<event>Chat(e, m)             (ATTACK … RACERESCU; FUN_004aedd0, FUN_004aef00, FUN_004af030,
                                                    FUN_004af160, FUN_004af290, FUN_004af3c0: identical bodies)
    if e.lines == 0: return
    if rand(1000) <= e.Rate0 (+0x18):                  # Rate0 = chance in per mille (data: 10…100); Rate1 unused
        text = e.Script[RandomRing(e.lines)]
        m.so_Chat(0xFFFF, text, strlen(text), chatwin 0, links 0)          # vt 0x530 → 0x2002 below

MobChatElementWander::mceb_WanderChat(e, m)                                    @ FUN_004aecb0
    the same without the Rate0 roll (the timer already decided)
MobChatElementWander::mceb_MobChatInterval(e)      (vt 0)                      @ FUN_004aebb0
    e.lines == 0 ? 10⁹ : Rate0 + RandomRing(range) × mult       # milliseconds; e.g. 1 800 000 … 3 400 000 = 30–57 min
```

The interval is drawn **once per spawn**: `so_mob_RegenComplete` (§5.3) arms the periodic timer +0x1ea8/+0x1eac with
`interval / 100` tenths; it then repeats with the same period while the mob wanders. (This resolves the "behaviour object
`DAT_0084cc8c`" of §5.2 / §6.9: it is the PIECE array.) The destructor FUN_004af4f0 frees every non-default element.

The line goes out as **0x2002 NC_ACT_SOMEONECHAT_CMD** (`ShineMobileObject::so_Chat` FUN_00458c90, layout in Z02 §3.1)
to everyone in sight of the mob: `handle` = the mob, `flag` GMColor = vt 0xef4 (0 for mobs), font / balloon colour from
vt 0xe2c / 0xe34. The client shows it like a player's chat line over the mob *(inferred: same handler as player chat)*.

(original bug) **Z09-B9**: the loader looks up the table name `"RACERESCU"` (9 letters), but `MobChat.txt` declares
`#Table RACERESCUE`; the file parser stores table names with `strncpy(…, 20)` (FUN_00646100) and the lookup compares all
20 bytes, so the table is never found and the 32 `RACERESCUE` rows are ignored: `mcm_DetectBattleChat` always hits the
default no-op element.

### 8.7 Mob shout and scripted mob chat

```pseudo
ShineMob::smo_Shout(m, target, speaker, content, len)   (vt 0x534; mob, NPC, bandit, pet, servant)   @ FUN_00459250
    0x201F NC_ACT_SOMEONESHOUT_CMD {
        u8 itemLinkDataCount = 0,
        speaker (20 bytes): speaker != "" ? speaker[20] : u16 mobID (vt 0x708) in the first two bytes,
        u8 flag: isMob (bit 1) = (speaker == ""), GMColor (bit 0) = vt 0xef4 (0); other bits = stale buffer bits,
        u8 len, u8 content[len] }
    size sent = len + 0x1A                       # (original bug) Z09-B10: one byte more than the packet (the player
                                                 #   version FUN_00459080 sends len + 0x19); the extra byte is stale buffer
    target == 0xFFFF ? so_AllInMap1(m, …)        # the whole map instance
                     : send only to GetObject(target)   ("…ShineMob::so_Shout : Packet Too Long" when the length is refused)
ShineObject::smo_Shout                                                          @ FUN_00459030   (non-mobile objects: no-op)
```

The client reads `speaker` as a u16 mob ID when `isMob` is set (client handler reads offset 1 as u16, C01 table
`re-data/client-handlers.json` 0x201f) and shows the mob's name. Callers: the Lua `cMobShout` FUN_005dbcd0 (part 12) and the
map-script node `ShineNPCShout` FUN_004eecd0 (part 15).

```pseudo
cMobChat(handle, scriptName, key, chatwin)           (Lua)                       @ FUN_005e2560
    o = GetObject(handle); set = script-string set scriptName (FUN_0064ce70(&DAT_150e04e8, name): "Invalid script name")
    text = set.ScrString(key) (FUN_0048ce60; "" when missing)
    o.so_Chat(0xFFFF, text, strlen(text), chatwin & 0xFF, 0)        # vt 0x530 → 0x2002 to sight
    return 0 values
```

### 8.8 Servant explosions (`MobExplosionElement`)

Only `ShineServant` (object kind 10, summoned by a player's skill) uses these; the servant object itself is part 8.
State at servant **+0x2574** = one of five singletons (`PTR_vftable_0084c9c0` Base, `…c4` Enemy, `…c8` Target, `…cc` Always,
`…d0` TargetAll; one slot each, `meb_Routine(servant, row) → next state`). Servant members used: +0x2568 → servant row,
+0x256c master, +0x2570 follow target (vt 0xf78 FUN_00557110), +0x257c next explosion time, +0x2580 i16 explosions left,
+0x1fbc death time. Row fields *(ours; the table is identified in part 8)*: +0x54 lifetime ms (0 = unlimited), +0x5c
explosion kind, +0x60 trigger radius, +0x64 u16 skill ID (0xFFFF none), +0x68 blast mode, +0x6c u16 explosion count,
+0x70 delay / interval ms.

```pseudo
ShineServant::so_mob_RegenComplete(s, arg)                                      @ FUN_00442c50
    ShineMob::so_mob_RegenComplete(s, arg)   (§5.3);  master = follow = 0
    s.deathTime (+0x1fbc) = row.lifetime ? g_Now + lifetime/100 : 0
    state by row.kind: 1, 4 → Enemy;  2 → Target;  3 → ss_ExplosionReady(s);  5 → TargetAll;  else → Base

ShineServant::ss_ExplosionReady(s)                                              @ FUN_0057b5d0
    s.nextBlast = g_Now + row.interval/100;  s.left = row.count;  return Always

ShineServant::so_Routine(s, …)                                                  @ FUN_0056c070
    if s not dead:
        if no master (vt 0x9b0 FUN_00557090: +0x256c not removed, mode 1/2/4, same field): s.vt[0x33c](0,1,3); FreeObject(s, 9); return
        if deathTime and deathTime < g_Now: mode = 3; s.vt[0x33c](0,1,3); FreeObject(s, 10); return
    ShineMob::so_Routine(s, …)                       (§5.4: tactics, AI)
    if alive (mode ∉ {0, 3}): s.state = s.state.meb_Routine(s, row)

Base::meb_Routine                                    FUN_0057b660   → Base (never explodes)
Enemy::meb_Routine(s, row)                           FUN_0057b6b0
    if no master: meb_Vanish(s, 0); → Base
    scan row.radius around s with AxialListNearScanSkillEnemy (DAT_13286090; s as caster)
    any enemy found → ss_ExplosionReady(s) (Always) else stay
Target::meb_Routine                                  FUN_0057b830
    if no master: Vanish(0); → Base
    f = follow target; if f present, not removed (vt 0x300), mode ∉ {0, 3} and not dead (vt 0x28 `IsDead` FUN_005557a0: flag +0x1d7c or HP 0):
        if dist²(s, f) <= radius²: → ss_ExplosionReady(s)    else stay
    else Vanish(0) (stays Target until removed)
TargetAll::meb_Routine                               FUN_0057bb20
    if no master: Vanish(0); → Base
    scan radius with AxialListScanSkillTarget (DAT_13284318); ready if it found ≥ 2 objects, or one that is not the master
Always::meb_Routine                                  FUN_0057b9d0
    if no master: Vanish(0); → Base
    if s.left <= 0: Vanish(3); → Base
    if s.nextBlast <= g_Now:
        if meb_Explosion(s, row, master): s.left −= 1
        if s.left < 1: Vanish(1); → Base
        s.nextBlast = g_Now + row.interval/100
    stay

MobExplosionBase::meb_Vanish(s, sec)                                            @ FUN_004a4110
    s.vt[0xf7c](sec)       # ShineServant SetSuicide FUN_004a3490: state = Base, deathTime = g_Now + sec × 10,
                           #   vt 0x24, AxialListMobSuicide::alms_SelfKill(s) (part 8)

MobExplosionBase::meb_Explosion(s, row, master) → bool                          @ FUN_004a7960
    sds_Initialize(damage sender DAT_0087efc4)                        (Z03 §5)
    if not s or not master or row.skill == 0xFFFF or not (sk = SkillDataBox_Find(row.skill)): return false
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
    c = ListOfMobStateCheckAtDead[m.mobId]   (DAT_14d6fcb8, FUN_005d2580; 0x14-byte entries {DropType, vector<abstate index>, …};
                                              loaded from MobAbStateDropSetting.shn by lomscad_Load FUN_005d5970, part 16)
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
    if g_Pulse5s >= g_Now: return                      # once per 5 s (§1.4)
    b = ServentBuffBossTable.sbbt_FindBuffer(m.mobId)  # DAT_14d6fca4, FUN_005d47f0: the StateMob.shn row whose
                                                       #   ConditionMobInx is m: {target mob ID, abstate index, abstate, strength}
    if b: so_AllInMap1(m, AxialListMobStateSet{targetMob, abstate, strength, keep 6000 ms})    # FUN_004eb880
AxialListMobStateSet::work(o)                                                   @ FUN_004f0fc0 → FUN_004eb8d0
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
    sel+0xc = owner;  sel+0x14 = arg;  scan radius (+0x10) = 600;  result block → sel+0x38
mt_SelectTarget(sel, p)                (vt 0x28)                                @ FUN_004abe10
    sel.found (+0x40) = 0;  if p: ShineObject_ScanSight(p, sel)        # calls ali_Work per object in sight
ali_Work(sel, p, o)                    (vt 0)                                   @ FUN_004add20
    skip unless mdb_CanIKill(o.mobId (vt 0x708), 1 = by a mob) and o.side (vt 0x8cc) ≠ 0
    if o has StaImmortal (291) or StaAdlFLoussierIMT (499): copy o's name to the debug ring DAT_0085dfb0; skip
    skip if o is dead (mode 3) or not placed (mode 0), has StaHide (75), is not a player, or is captivated itself (vt 0xf20)
    if same layer and o can be seen from p's sub-layer:
        sel.found = o; sel+0x38 = o.handle; sel+0x3c = o.identity (vt 0x344); stop the scan
```

The charmed player therefore attacks the first visible, uncharmed, unprotected **player** in scan order (radius 600 is set
but `ShineObject_ScanSight` FUN_00553c20 calls `so_AllOfRange_Class1` with range 0, i.e. the whole sight list, and
`ali_Work` has no distance test, so the radius is not applied *(inferred: range 0 = sight)*).

### 8.11 Open points of this section

- The servant row table behind +0x2568 (fields +0x54…+0x70) and `vt 0x33c` / `FreeObject` reasons 9 / 10: part 8.
- `ShineMover::so_mobile_ICanDamageTo` refuses all player targets outside kingdom-quest maps; whether movers ever attack
  (and whether that is intended) is not checked here (movers: part 8).
- The scanner classes `AxialListNearScanSkillEnemy` / `AxialListScanSkillTarget` belong to Z03's skill targeting.

---

## 9. Movement, map blocks, path finding and sight

Every mobile object (player, mob, NPC, servant, pet, mover, bandit) moves the same way: a `MoveManager` at obj+0x18c
interpolates the position from a start point to a destination at a fixed speed, one step per tick, and every step goes
through the block bitmaps and the sight update. Client-driven moves (Z02 §2) and all server-driven moves (tactics §7,
fear, scripts, skills) start it with `MoveStart` (vt 0x660).

### 9.1 `MoveManager` (obj+0x18c)

| Off (in MoveManager) | obj | Meaning |
|---|---|---|
| +0x00 | +0x18c | move kind: 0 idle, 1 walk, 2 run, 3 server push (`so_ReinforceMove`; kept through resets, see `Reset`) |
| +0x04 | +0x190 | owner object |
| +0x08 | +0x194 | speed (units per second; vt 0x7b0 reads it) |
| +0x0c / +0x10 | +0x198 | start point |
| +0x14 / +0x18 | +0x1a0 | destination (vt 0x60c returns its address; a player on a mover returns the mover's) |
| +0x1c | +0x1a8 | start time (`timeGetTime`, ms) |
| +0x20 | +0x1ac | duration in ms = distance × 1000 / speed (min 1); **non-zero = moving** (vt 0x610 `IsMoving` FUN_005555c0) |
| +0x24 / +0x28 | | last / previous step time (ms) |
| +0x2c | | ms of the move already applied |
| +0x30 / +0x34 | | \|dx\| / dx > 0; +0x38 / +0x3c \|dy\| / dy > 0 |

```pseudo
MoveStart(o, dest, speed, kind, backwards)  (vt 0x660, all classes)        @ FUN_00555970
    o.direction (*o+0x6a, 0..179 in 2° steps) = Direction(backwards ? pos − dest : dest − pos)   @ FUN_00401330
    mm_MoveStart(o+0x18c, dest, speed, kind)                                 @ FUN_004bdcc0
        if speed ≤ 0: return;  if !dest: log "Where am I to go?"; return
        if dest == o.pos: return                                             # nothing is (re)started
        kind, start = o.pos, start/last/prev step time = now, applied = 0, destination = dest
        mm_RecalcSpeed(speed)                                                @ FUN_004bdbe0
            |dx|, |dy|, signs; duration = Distance(dx, dy) × 1000 / speed (≥ 1); speed stored
            speed ≤ 0: log "mm_RecalcSpeed : speed zero"
Reset(mm)  (inlined in many places)                                          @ FUN_0043f780
    if kind ≠ 3: kind = 0; times, duration, applied, speed = 0; destination = o.pos
Arrive(mm)                                                                   @ FUN_0043cc60
    times, duration, applied, speed = 0; destination = o.pos                 # kind is left as it was

mm_Step(mm, force)            # called by so_Routine every tick while moving (§5.5), by STOP_REQ (Z02 §2.3) with force=1
                                                                             @ FUN_004be7e0
    if duration == 0: kind = 0; return
    p = o.GetParam (vt 0x430)
    if kind == 3:  stop if p.flags (+0xcce) & 2
    else:          if p.flags & 1 or p.flags & 2: Reset(unless kind 3); StopHere (vt 0xa48); vt 0xa50; return
                   stop if o.IsInGambleGame (vt 0xb24; players at a gamble seat, Z06)
    stop = Reset; so_mobile_StopHere (vt 0xa48); vt 0xa50 (player: 0x204A REINFORCE_STOP to itself); return
    now = timeGetTime(); elapsed = min(now − start, duration)
    if !force and duration ≥ 100 and (lastStep − now) < 100 (unsigned) and now − start < 100: return
        # (original bug) Z09-B15: the throttle subtracts the wrong way round; as unsigned it is true only when
        # lastStep == now, so steps are practically never skipped (intent: skip when < 100 ms since the last step)
    prevStep = lastStep; lastStep = now
    applied = (elapsed − applied < 100) ? elapsed : applied + 100
    loop while applied ≤ elapsed:                       # walks the time in slices of at most 100 ms
        point = (applied == duration) ? destination : start ± |d| × applied / duration (per axis)
        if o.IsInFear (vt 0x9e8, +0x1e78 bit 2) and (no map or BlockA(point) or BlockB(point)): stop (see above); return
        if !o.smo_BlockCheck(point) (vt 0xf40, §9.2): return
        old = o.pos
        smo_NewObjBriefInfoChange(o, point)             # §9.6: objects that come into sight
        SetPosition(o, point)                           # Z02 §2 (re-sorts the coordinate lists, §9.5; script hook 7)
        smo_OldObjectDelete(o, old)                     # §9.6: objects that leave sight → 0x1C0E
        if applied == elapsed: if elapsed == duration: Arrive(mm); return
        applied += min(100, elapsed − applied)
```

Stat flags in `GetParam()+0xcce` (bit 0 and bit 1 stop every move except kind 3, bit 1 stops kind 3 too) are set by
abstates (Z03 §6; §5.5 calls them "cannot move / attack / cast"). Pushes (kind 3) therefore survive a root but not a stun
*(inferred from the bits)*.

**Stops.**

```pseudo
so_mobile_StopHere(o)  (vt 0xa48)                                            @ FUN_0045a0c0
    Reset(o.mm) (unless kind 3); o.lastMoveCmd (+0x168) = 0                  # newcomers no longer see a move (Z02 §5)
    broadcast to sight 0x2013 NC_ACT_SOMEONESTOP_CMD { u16 handle, u32 pos.x, pos.y }
    # a ShineMover (kind 11) broadcasts around the object vt 0xcb0 returns instead (nothing if none)
ShinePlayer.smo_ply_ReinforceStopHere(p)  (vt 0xa50; other classes no-op FUN_00417480)   @ FUN_00456ef0
    p ← 0x204A NC_ACT_REINFORCE_STOP_CMD { u32 loc.x, loc.y = p.pos }        # client: put the main character there
```

### 9.2 Block bitmaps and the per-class block checks

Each map has a `MapBlockInformation` (field+0x14), loaded once per map name by `MapBlockInformationBox::mbib_Load`
(FUN_0049e940; table of ≤ 256 maps × 0xb50 bytes, "Too many block info") → `mbi_Load` FUN_0049e3b0:

| File (`9Data/Shine/BlockInfo/`) | Read into | Content |
|---|---|---|
| `<map>.shab` (optional, 8 maps in 2016) | +0x18 | `u32 bytesPerRow, u32 rows`, then rows × bytesPerRow bytes; bit set = blocked. Read first; missing file is not an error |
| `<map>.shbd` (required: "Map block information not found" stops the server) | +0x14 | same format; **after loading, every byte of .shab is OR-ed into .shbd** |
| `<map>.aid` (optional) | +0x24 | `AreaInfoData` (FUN_0062d990): `u32 n` (≤ 256), then per area `char name[32], u32 type`; type 0 `AE_Circle` + 3 × 4 bytes, type 1 `AE_Square` + 5 × 4 bytes (the last one is an angle in degrees converted to radians). Script areas (part 9) |
| `<map>.sbi` (optional) | +0x430 | door blocks (`MapDoorArray::mda_Load` FUN_0049dd30): `u32 n` (≤ 31, "Too many doors"), n × `MapDoorBlockElement` (FUN_0049dc20: `char name[32], u32 x0, y0, x1, y1` in cells, `u32 len, u32 offset`; x1−x0+1 must be a multiple of 8, len = (x1−x0+1)/8 × (y1−y0+1)), then all door images (2 × len per door: closed image, open image) |

Cell size: 50/8 = **6.25 units**; map size in units = bytesPerRow × 50 (x) and rows × 6.25 (y) (`mbi_Load` returns
both; all 158 `.shbd` of 2016 are square). Also built at load: the `BlockDistribute` quadtree (+0x42c, §9.4).

```pseudo
BlockA(map, x, y)  = .shab bit at cell (x·8/50, y·8/50); outside the map → blocked; no .shab → free     @ FUN_0049df00
BlockB(map, x, y)  = .shbd|.shab bit; outside → blocked                                               @ FUN_0049df70
mbi_OccupCellCheck(map, x, y, r)                                                                      @ FUN_0049e230
    true when any cell in the (2r+1)² square around (x, y) is inside the map and free in .shbd   # Z02 CellFree uses r = 1
mbi_DoorAction(map, name[32], action)                                                                 @ FUN_0049ec60
    find the door element whose 32-byte name matches (mda_DoorAction FUN_0049eb60 / mdbe_DoorAction FUN_0049ea40)
    mdbe_DoorAction2(door, map, action)                                                               @ FUN_0049e080
        action 1 (open):  copy the open image over the door's rectangle of .shbd
        else (close):     OR the closed image into it ("Null block" when the rectangle is outside the map)
mda_CloseAllDoor(doors, map): mdbe_DoorAction2(each, 0) ("Close error")                               @ FUN_0049e1e0
    callers: bdm_Find (map load), &bigbang (Z11), guild-tournament start, KQ start / destroy (Z16), instance dungeon
    reuse (FUN_005a8c20, FUN_0049ee70 dungeon timeout: also clears the map), FUN_00419340, FUN_005d6b00
```

Doors are opened by `ShineDoor::so_door_DoorAction` FUN_00550770 (part 8). Only `.shbd` changes, so `.shab` areas can
never be opened.

**Block checks during a move** (vt 0xf40 `smo_BlockCheck(point)` in `mm_Step`; vt 0xf44 after a client stop):

```pseudo
ShineMobileObject.smo_BlockCheck / smo_StopBlockCheck: return true            @ FUN_004be3a0 / FUN_004be5c0
    # mobs, NPCs, servants, pets never test blocks while moving: their paths are checked when planned (§7, §9.3)
ShinePlayer.smo_BlockCheck(p, point)                                          @ FUN_004bec00
    if no map: Reset; StopHere; ReinforceStopHere (0x204A); return false
    if !BlockA(point) and !BlockB(point) (g_MoveBlockCheck FUN_004be3f0): lastGood (+0x2a918/+0x2a91c) = p.pos; return true
    if dist²(p.pos, lastGood) > 899:                  # more than ~30 units into blocked cells
        if (point ± 10 on x or y) all four blocked (g_FindEmpty FUN_004be4c0; a free one becomes lastGood):
            SetPosition(p, lastGood); Reset; StopHere; ReinforceStopHere; return false
    return true                                      # the step onto the blocked cell is accepted
ShinePlayer.smo_StopBlockCheck(p)  (Z02 "StopBlockCheck")                      @ FUN_004bee40
    if p.pos ≠ lastGood:
        no map: Reset; StopHere; ReinforceStopHere; return false
        if p.pos blocked: SetPosition(p, lastGood); Reset; StopHere; ReinforceStopHere
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
    if Distance(from, to) > maxDist + 10: return false
    out = from; n = Distance/8 + 1
    for k = 1..n: q = from + (to − from)·k/n; if blockedFn(q): break; out = q
    return true                                      # out = last free point on the line (from if the first step is blocked)
so_FindBlockLocate(o, to, maxDist, out, fn) = so_FindBlockLocateFrom(o.pos, …) @ FUN_004beb40
FieldMap.fm_FindBlockLocation(from, maxDist, to, out, fn)                     @ FUN_004630f0
    same walk with n = Distance/16 + 1; returns 2 = too far, 1 = stopped at a block, 0 = reached `to`
FieldMap.fm_IsStraightPath(a, b, fn) / Navigator::VirtualMap::vm_IsStreight(a, b)   @ FUN_004636e0 / FUN_005ca2f0
    true if dist² < 25; else false if the midpoint is blocked (fn / BlockA), else both halves recursively
```

`vm_IsStreight` and the Navigator test **only .shab** (BlockA): mob paths ignore `.shbd` walls (and closed doors) unless
the map also has a `.shab`; the per-step check does not run for mobs either. All 8 maps with a `.shab` and the 150
without are treated so *(inferred consequence; whether the 150 maps then let mobs walk through walls was not checked in a
capture)*.

### 9.3 Server-driven moves

```pseudo
so_MoveByServer(o, dest, cmd, lastCmd, kind, logArg)  (vt 0x5b0)              @ FUN_00569510
    o.SendMoveSpeed(1) (vt 0xd4c; player FUN_00459540: 0x203E MOVESPEED to itself, Z02 §2.2)
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
`ShinePlayerWalk` FUN_004f6d40 (part 15). All pass lastCmd 0x49 for a run *(as read at the fear / speed-change sites)*.
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
    if so_FindBlockLocate(o, target, 450, &q, BlockB): so_MoveByServer(o, q, 0x1A, 0x49, run, 2)
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
    base version; if clearFlag: p+0x7f36 = 0 (FUN_00566800); sp_SkillShiftCancel(p)
    p.lastMoveCmd = 0x69 with the payload (newcomers see the push); ClearEmoticon
```

Callers of vt 0xa28: `smo_ShootMeTo` (below), the skill knock-back / pull handler FUN_00401db0 and FUN_005c1390 (Z03
skill effects). Client 0x2069 (FUN_004a4180): `ClearTraceMove`, sets walk/run speed to `speed`, moves the character to
`to`; with bit 0 it keeps facing `from` (pushed backwards).

```pseudo
smo_ShootMeTo(o, dest)  (skill bash "shoot me" to a location)                 @ FUN_00459940
    t = AbState 391 StaBodyForce row's keep time (+0x30 → +0x2b), default 1000
    set abstate 391 (vt 0x638), brief bit, broadcast, inform (vt 0x3f0); same for 350 StaCannotControl
    speed = Distance(o.pos, dest) × 1000 / t (100 if t == 0); o.so_ReinforceMove(dest, speed, 0, 0, 1)
smo_WarpTo(o, dest, skillRow)  (dash / blink skills)                          @ FUN_004a7de0
    dest.x += 5
    if !so_FindBlockLocate(o, dest, skillRow+0xdc, &q, BlockB): return
    kind = 0; StopHere; NewObjBriefInfoChange(q); SetPosition(q); OldObjectDelete(old)
    o ← 0x2450 NC_BAT_SKILLBASH_HIT_FLD_START_CMD { u16 skillId, u32 dest.x, dest.y, u16 counter++ (DAT_0087efe4 & 0x7fff) }
        # to the warping object only; the log text on failure says "smo_SkillBash_BlastA" (copied)
    broadcast to sight (players) 0x4828 NC_SKILL_WARP_CMD { u16 object, from (old), to (q), u16 skill }
    Reset(o.mm)
smo_WarpForward(o, skillRow): dest = o.pos + skillRow+0xdc units in o's direction; smo_WarpTo   @ FUN_004a83e0 / FUN_004a2db0
smo_JumpTo(o, target, skillRow, _)  (skill blast "jump")                      @ FUN_0057db20
    v = target − o.pos scaled to (row+0x248 == 1 ? |v| − row+0x24c : |v| + row+0x204)   # land short of / beyond the target
    land = o.pos + v
    if so_FindBlockLocateFrom(target, land, that length, &q, BlockB) and the straight walk o.pos → q has no BlockA cell:
        StopHere; NewObj/SetPosition/OldObj; broadcast 0x482D NC_SKILL_JUMP_CMD { u16 nObject, From, To, u8 nDirect, u16 SkillID }
        Reset(o.mm); return true
    return false
```

`smo_ShadowStep` FUN_0045ad10 (0x206A REINFORCEMOVEBYPATH, Z03 §5) builds its curved path with `RadianMoveTrack`:
`rmt_Calculate` FUN_00460450 turns the angle between the facing and the target into an arc and `rmt_MakePath`
FUN_00460250 splits it recursively (≤ 30 levels, ≤ 19 direction steps per piece) into points whose chords pass
`FieldMap_fm_IsStreight` (both arc directions are tried).

**Teleports.**

```pseudo
ShineMob.smo_Teleport(m, xy)  (vt 0x6d4 for non-players)                      @ FUN_005793e0
    StopHere; so_Unmark (vt 0x33c, 0, 1, 3); m.pos = xy; spawn point (+0x249c/+0x24a0) = xy; sm_SetBrain (§6.1)
    if fm_Marking(map, m) fails: log "smo_Teleport : Fail"; mode = 3 (dead); +0x1ec4 = 0
    if m has a brief packet (+0x1f90 → +4 → +0x24): full brief exchange around m (FUN_00441f60, so_ExchageBriefInfo)
ShinePlayer.smo_Teleport(p, xy)  (vt 0x6d4 player)                            @ FUN_0057d1d0
    kind = 0; StopHere; SetPosition; ShinePlayer_ReExchangeBriefInfo; OldObjectDelete(old); Reset; SendMoveFail (vt 0xa4c)
smo_Teleport()  (vt 0x6d8, random spot)                                       @ FUN_0057a8b0
    q = BlockDistribute random free spot of the map (FUN_00438960, §9.4); vt 0x6d4(q)
    callers: so_Routine (§5.5 table), ShineTeleport script node FUN_004f4cc0, cCastTeleport FUN_005e5b10, ac_CastTeleport FUN_004229b0, FUN_00428730
SetPositionWithSight(o, x, y, dir)  (vt 0xc98, only if o+0x162)               @ FUN_0045a000
    NewObjBriefInfoChange; direction = dir; SetPosition; OldObjectDelete
```

### 9.4 `BlockDistribute`: random free spots

`BlockDistributeManager::bdm_Find` FUN_00438f70 (global DAT_008b7018, ≤ 64 maps, "Too many BlockDistribute") closes all
doors of the map, then builds a quadtree (`BlockingDistribute` ctor FUN_00438c80, nodes from the pool DAT_008b7008,
"Too small size" above 59999 units): a node splits into four until both spans are under 100 units; a leaf counts 1 if
its centre is free in `.shbd`; every node keeps its child count (+0x18) and free-leaf count (+0x1a); empty children are
dropped. The tree is built over x ∈ [0, map height] and y ∈ [0, map width] (the arguments are passed swapped; harmless
because every 2016 map is square).

```pseudo
RandomFreeSpot(tree)                                                         @ FUN_00438960
    node = root
    while node has children:
        pick a child weighted by its free-leaf count (Random 0..999 against the per-mille shares; 10 tries, else the first child)
    return the leaf's centre
```

Used by `smo_Teleport` vt 0x6d8, `&linkto` (Z11) and the script statement `os_ObjectRegen` FUN_004f8c40 (part 14).

### 9.5 Mob paths: Navigator and MobRoam

**Navigator** (`Navigator::MapNavigator` at field+0xa4, grid step at +0xc, `PathFindBuffer` at +4; used only when
`g_UseNavigator` DAT_0084cfb4 is set, §7.3):

```pseudo
mn_PathFind(nav, from, to, outPath)                                           @ FUN_005c9ee0
    if to is blocked (vm_IsBlocked = BlockA FUN_005ca230): mn_ExitFromBlock FUN_005c8ab0 moves `to` to the first free
        point on growing squares (1..49 units); none → return −1
    PathAnalyzer.pa_Analyze FUN_005c9870: points [from, first block on from→to (vm_FindBlock FUN_005ca470 via
        fm_FindBlockLocation), first block on to→from, to]  (2 points when the line is free)
    2 points: outPath = straight line; return 2
    4 points: outPath = [from, …] + mn_Search(block A → block B) + [to]
        mn_Search FUN_005c9c90: best-first search on the grid around block A (PathFindBuffer FUN_005c8800: a
            (2r+1)² array of 0x14-byte cells {stamp, parent x, parent y, h, g}, FUN_005c88f0 index), 8 neighbours
            (wl_StoreNeighbor FUN_005c9a90, free cells only, g+1, h = Distance to the goal FUN_005ca210), open list
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
    if Distance(m, p) ≤ 100: AdvanceIndex(m+0x1ebc, path); p = new point; clear "was chasing" (+0x24ac bit 3); advanced = 1
    dx, dy, dist = p − m.pos; spawn point (+0x249c/+0x24a0) = p              # leash and "go home" follow the path
    return true
AdvanceIndex(idx, path)                                                     @ FUN_004b71f0
    bit 15 set (walking back): index−1; at 0 → index = 1 forward
    else index+1; at the end: walk back (bit 15, index = count − 2)
        EventIndex of the reached point (first 20 bytes): "-" nothing; "return" → walk back from here;
        "rotate" → index 0 (loop)
ShineMob_SpawnPointFromPath (vt 0xf50): spawn point = current path point          @ FUN_004b7690
```

**Scenario moves** (NPCs and bandits moved by map scripts):

```pseudo
so_scene_MovePathSet(o, x, y, kind)  (vt 0x8ac; ShineAct / ShineWalk script nodes, part 15)   @ FUN_0050d450
    append {x, y, kind} to the queue o+0x1db0 (16 × 12 bytes, count +0x1e70); full → ignored
smo_MoveByScenario(o)  (from ShineNPC / ShineBandit so_Routine, §5.9 / §5.10)               @ FUN_0050d520
    if queue empty or moving: return
    pop the first entry; kind 1: MoveStart(walk speed, 1), RememberMove + broadcast 0x2018; else run speed, 2, 0x201A
```

### 9.6 Sight: how objects appear and disappear (answers Z02 §5)

The coordinate lists: each object has two `CoordedNode`s, obj+0x16 (`ObjectXCoordNode`, key = x, FUN_00587d00) and
obj+0x22 (`ObjectYCoordNode`, key = y, FUN_00587d30), each `{vptr, next +4, prev +8}`. Every map keeps two sentinel
objects (field+0x20 at (0, 0) and field+0x24 at (0xFFFFFF, 0xFFFFFF)) and five anchors (field+0x28…+0x38) on the
diagonal at (w/10 + i·w/5, h/10 + i·w/5) — the "slanted" entry points.

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

`so_AllOfRange_Class0/1(o, stamp, centre, range, …, work, includeSelf, skipHandle)` FUN_0054baf0 / FUN_0054bc80: range
0 means the sight radius = MapInfo.Sight (field+0x10 → +0x48), 99,999,999 when o+0x163 == 1 or field+0x124 == 1. It
calls the map's query function field+0x88; for normal maps `so_AllOfRangeNomal_Class2` FUN_0054c900:

```pseudo
    walk o's X list both ways while |Δx| < range, stamping each object (obj+0x2e + depth·4 = stamp; nesting depth DAT_0074d71c)
    walk o's Y list both ways while |Δy| < range; for each stamped object with handle ≠ skipHandle and dist² < range²
        (and inside the cone when a direction is given: dot product ≥ cos(angle/2)):
        if same layer (obj+0x4e/+0x52) or either object's +0x56 flag ("all layers"): if !work(o, other, dist²): stop
    includeSelf: work(o, o, 0)
    > 10000 steps on one list: log "Too many loop" and stop; a node pointing at itself: o.vt[0x8a0](1..4) and fm_Relink
```

(Mini-house maps use `so_AllOfRangeMiniHouse_Class4` FUN_00553f60 *(inferred from the name; not read)*.)

**Appear and disappear on every step.** `mm_Step`, `smo_WarpTo`, `smo_JumpTo`, `ShinePlayer.smo_Teleport` and vt 0xc98
wrap `SetPosition` like this:

```pseudo
smo_NewObjBriefInfoChange(o, newPos)                                          @ FUN_004bdef0
    so_AllOfRange_Class1(o, around newPos, sight, AxialListBriefExchangerAtMove)
    ali_Work(o, other)                                                        @ FUN_004bdde0
        s = MapInfo.Sight² (0xFFFFFFFF on unlimited maps); if dist²(o's *old* position, other) < s: skip   # already in sight
        if SubLayer_CanSee(o, other): o.so_SendMyBriefInfo(other) (vt 0x4c8, Z02 §5) + o's abstate list 0x1C19 to other
        if SubLayer_CanSee(other, o): other.so_SendMyBriefInfo(o) + other's abstates to o
smo_OldObjectDelete(o, oldPos)                                                @ FUN_004be0d0
    so_AllOfRange_Class1(o, around oldPos, sight, AxialListBriefDeleteAtMove)
    ali_Work(o, other)                                                        @ FUN_004bdfe0
        if other is an NPC (kind 4): skip                                     # NPCs are never removed by moving
        if dist²(o's *new* position, other) < s: skip                          # still in sight
        if SubLayer_CanSee(o, other): other ← 0x1C0E NC_BRIEFINFO_BRIEFINFODELETE_CMD { u16 hnd = o.handle }
        if SubLayer_CanSee(other, o): o ← 0x1C0E { hnd = other.handle }
```

So **the zone does send 0x1C0E** (correction of Z02 §5 / knowledge "no 0x1C0E sender"). The packet is a static buffer
built at start-up (FUN_006951d0: buffer 0x74df98, opcode 0x1C0E, payload pointer DAT_0074e028). The same packet goes
out from `AxialListBriefDeleteAllOfRange::ali_Work` FUN_005535c0 (both directions, skipped for objects with the +0x56
"all layers" flag) through the player's vt 0xdc4 (FUN_00553650, objects in sight) and vt 0xdd0 (FUN_005536f0, whole
map), which the four layer-move entries vt 0xdbc…0xdcc call before changing the layer (Z06 §2 lists them); after the
change vt 0xdd8 FUN_00441ed0 recomputes `g_SightDistSq`, runs `so_ExchageBriefInfo` over the sight range, flushes the
batches (FUN_0043fc80) and sends the abstates (`asl_SendAfterLogin`). Other ways out of the client: 0x1805 logout
broadcast (Z01 §3.2) and the death/corpse removal of mobs (§5.4).

Note the distance used here is the plain MapInfo.Sight², not the crowd-reduced `g_SightDistSq` used by the full
exchanges (Z02 §5.2): in crowded places an object can be announced by the full exchange at a smaller radius and then be
deleted/announced at the map radius by moves *(inferred from the two formulas; not observed)*.

(original bug) Z09-B13: in both delete workers the second send ("tell o that other left") calls
`o.sendObject.pcb_Append(other, packet)` with **other** as the first argument (the exchanger passes `o`). The packet still
lands in o's buffer, but when that buffer is full (> 0x17ff bytes) `PacketContainer_pcb_Append` FUN_004c8b20 flushes it
to `other.GetClientSession()` (vt 0xa70): to the other player's client, or to no session (0) when other is a mob.

Client (C01): `On_NC_BRIEFINFO_BRIEFINFODELETE_CMD` FUN_004b99f0 removes NPC/resource/gate effects, puts the handle into
`CharMgr.m_kmapDeletedChar` (CharMgr+0x18 *(pdb2017)*) unless char+0x9be is set, removes a mover's effect, the minimap
mark, decals and the KQ team mark. No client-side distance culling was looked for: the server drives it.

### 9.7 Collision for placement

`so_collesioncheck(o, other)` FUN_00452b00 (the `fm_Marking` spacing test, §5.7) answers "keep looking" (true) unless
`other` takes part in collisions (vt 0x4b8) and is of the same class (vt 0x4b8 values equal and ≠ 3) *(the vt 0x4b8
value is a bool here: players FUN_00557240 = mode ≠ 3 (alive); mobs FUN_00556540 = always for MobInfoServer +0x5f ∈
{1, 2}, else mode ≠ 3)*.

### 9.8 Open points of this section

- `MainChar+0x20 / +0x2c` (client 0x2049 guard) and player byte +0x7f36 (cleared by pushes) are not identified.
- The meaning of `GetParam()+0xcce` bits 0/1 (which abstates set them): Z03 §6.
- `so_AllOfRangeMiniHouse_Class4` (mini-house interiors) and field+0x88 selection (FUN_00464bc0 map init): Z06/Z01.
- Callers of vt 0xc98 (`SetPositionWithSight`) were not listed (sweep).
