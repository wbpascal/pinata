# Zone server: world simulation — main loop, timers, mobs, NPCs, spawns, drops, scripts (Z09)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (export `re-data/exports/zone`). Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`. Names: the zone's
own profiler strings (`docs/knowledge/Z01.md` §1) plus `tools/protocol-re/names/zone/Z09.json` (names marked *(ours)*
there and here are ours). Evidence markers as in `AGENTS.md`: plain = read in the 2016 code, *(pdb2017)*, *(inferred)*.

Time unit: `g_Now` (DAT_14d41a70) counts **tenths of a second** (Z02 §1); "`g_Now + 50`" = 5 s.

This file is written in parts (status: `docs/plan/status/Z09.md`). Sections so far: §1 main loop and global timers,
§2 the player tick, §3 GM events, §4 prison (no zone timer).

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
| ShineMagicField, ShineEffectObject, ShineDoor, ShineServant, ShineBandit | `…_so_Routine` | later part (objects) |
| ShineMobileObject (base of all movers) | FUN_0056a080 (cast completion: Z03 §5) | later part (mobs) |
| ShinePlayer | FUN_0056c790 | §2 |
| ShineMob, ShineNPC | `ShineMob_so_Routine`, `ShineNPC_so_Routine` | later part (mobs) |
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
