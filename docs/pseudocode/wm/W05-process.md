# World Manager: process services (W05)

Source binary: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe`. Read with
`python3 -I tools/protocol-re/clean.py re-data/exports/wm-pdb - <addr>` (PDB names) or
`… re-data/exports/wm tools/protocol-re/names/wm <addr>`. Class, member and function names are from the NA2016
`WorldManager.pdb` *(pdb2016)* unless marked *ours*; the 2016 offsets were checked in the non-PDB export. Packet
layouts: `docs/protocol/annotations/W05.json`. This item fills the WM process gaps W01-core leaves: the main loop,
the timed broadcasts, the data loader and the session teardown chain. It cites the subsystem docs (W01–W04) instead
of repeating them.

Server object: `gServer` = `WorldManagerServer` (DAT_0049a028, W01 `g_WM`; PDB "definition 1" layout, size
0x23abe8). Members used below (offset from `gServer`):

| Offset | Member *(pdb2016)* | Notes |
|---|---|---|
| +0x0000 | `m_ServerInfo` (`CServerInfo`) | ServerInfo.txt tables (W01 §2 `ReadDefineScriptor`) |
| +0x04f8 | `m_MyServer` | +0x504 nWorldNo, +0x508 nZoneNo (W01) |
| +0x050c … +0x0608 | `m_AccountDBInfo`, `m_AccountLogDBInfo`, `m_CharDBInfo`, `m_GameLogDBInfo`, `m_LoginInfo`, `m_ZoneInfo`, `m_ClientInfo`, `m_OPToolInfo` | 0x24 bytes each: pIP, nPort, nServerIDFrom, nMaxAccept, nBackLog |
| +0x063c / +0x98c8 | `m_Acceptor` / `m_IOCP` | one acceptor for all three listen ports |
| +0x98f8 … +0xe168 | `m_AccountDB`, `m_AccountLogDB`, `m_CharDB`, `m_GameLogDB`, `m_Login` + their parsers | W01 §1 |
| +0xbcb84 | `m_ClientNumOfUserLimit` | −1 at start (OPTool 0x280E, W01 §9) |
| +0xbcb88 / +0xbdcc4 / +0xc2f9c | `m_Client` / `m_Zone` / `m_OPTool` session managers | W01 §1 |
| +0xc40c0 | `m_MsgWM` (`CDataReader`) | `MsgWorldManager` table (W04 §2.5) |
| +0xc4100 / +0xc410c / +0xc4134 / +0x223f38 | `m_Party`, `m_PartyFinder`, `m_KQServer`, `m_Raidsystem` | W02, W04 §6 |
| +0x22ac98 | `m_GuildManager` | W03 |
| +0x22b06c / +0x22b0ac / +0x22b1f8 | `m_GuildGradeData`, `m_GuildDataServer`, `m_DataFileServer` | tables (§3) |
| +0x22b344 / +0x22b38c / +0x22b440 / +0x22b460 | `m_NpcScheduleServer`, `m_EventAttendance`, `m_DailyQuestTimer` (DAT_006c5468), `m_GMEventManager` | W04 §17.6, §17.5, this §2.3, W04 §16 |
| +0x22b474 / +0x22b484 | `m_SingleData`, `m_CharClassDataBox` | §3 |
| +0x22b4fc | `m_bOnStopService` | 1 = stop requested by the service manager |
| +0x22b500 / +0x22b510 | `m_ServerStartTime` / `m_ServerStopTime` (SYSTEMTIME) | `ViewStartInfo` / `ViewStopInfo` |
| +0x22b520 / +0x22b524 | `m_bStopMainThread` / `m_bActiveMainThread` | |
| +0x22b530 | `m_MainWorkStep` (`MAIN_WORK_STEP`) | W01 calls it "phase" (§1.3) |
| +0x22b534 | `m_bProcessLinked` | W01's "running flag"; 1 once the four DB links were up |
| +0x22b538 / +0x22b540 | `m_GambleSystemServer`, `m_RankingServer` | W04 §15.1, §13.3 |

All members are built by the constructor `WorldManagerServer::WorldManagerServer` @ FUN_00406a20 (global object,
runs before `WinMain`): it constructs every member in the order above, sets `m_ConnectSocket_BindIP = ""`,
`m_bOnStopService = 0`, `m_bProcessLinked = 0`, `m_MainWorkStep = MAIN_WORK_NONE`, `m_ClientNumOfUserLimit = −1`
and calls `RaidSystem::SetPartyData(&m_Party)`. `CDailyQuestTimer`'s constructor computes the first quest reset
times here, i.e. at process start (§2.3).

---

## 1. Process lifecycle

### 1.1 Start-up (WinMain → Windows service)

```pseudo
WinMain(hInst, hPrev, cmdLine, nShow):                                   @ FUN_004036f0
    MiniDumper()                                    # crash dump handler
    r = WorldManagerServer::Start(&gServer, cmdLine)
    log "< END OF MAIN = %d >" r; return r

WorldManagerServer::Start(this, cmdLine):                                 @ FUN_00407190
    chdir(directory of the exe)                     # all relative paths (9Data, WMServerInfo.txt) start there
    ViewStartInfo(this)                                                   @ FUN_00403c10
        m_ServerStartTime = GetLocalTime(); log "Local  Time      %s", "System Time(UTC) %s"
    if !ReadDefineScriptor(this): return −1        # WMServerInfo.txt + ServerInfo.txt, W01 §2 (FUN_00403e70)
    if !ParseCmd(this, cmdLine):  return −2        # service install / remove, below
    if !ReadGlobalGameData(this): return −4        # all data tables (§3, FUN_00404100)
    WinService::startDispatcher(serviceName, ::OnStart_Service, ::OnStop_Service)
    return 0                                        # the service manager now calls OnStart_Service

ParseCmd(this, cmdLine):                                                   @ FUN_00406d80
    split cmdLine into at most 5 tokens; first token upper-cased
    if no token:
        if WinService::queryServiceStatus(serviceName) succeeds: code = 0      # started by the SCM
        else: token = "UPLOAD"                                                 # first run installs itself
    "UPLOAD": code = uploadService(exePath, displayName, serviceName) ? 1 : 2
    "REMOVE": code = removeService(serviceName) ? 3 : 4
    other:    code = 5
    texts: 0 "<SERVICE START>", 1 "<SERVICE UPLOAD ONLY OK>", 2 "<SERVICE UPLOAD FAILED>",
           3 "<SERVICE REMOVE OK>", 4 "<SERVICE REMOVE FAILED>", 5 "<SERVICE UNKNOWN COMMAND>"
    code 0 → log, return true; code 1…5 → log + MessageBox(text, displayName), return false (process ends, −2)

::OnStart_Service() → WorldManagerServer::OnStart_Service(&gServer)       @ FUN_00403760 → FUN_00407a50
    n = 2 × number of CPUs; CIOCP::Start(n worker threads)
    log "<NUMBER OF %d IOCP WORKTHREAD STARTED, %d CPU DETECTED>"
    if started threads != n: return false
    if !Start_MainThread(this): return false                               @ FUN_004079d0
        m_bStopMainThread = 0; m_bActiveMainThread = 0
        CreateThread(MainThread, this); failure → log GetLastError text, return 0
        wait (Sleep 5 ms) until MainThread set m_bActiveMainThread = 1
    if !Start_Acceptor(this): return false                                  @ FUN_004045b0  (CSocket_Acceptor::Listen_Start)
    m_MainWorkStep = MAIN_WORK_LINK; return true
```

`MAIN_WORK_STEP` *(pdb2016)*: 0 NONE, 1 LINK, 2 RUN, 3 CLOSE_NORMAL, 4 CLOSE_ACCOUNT_DB, 5 CLOSE_ACCOUNTLOG_DB,
6 CLOSE_CHAR_DB, 7 CLOSE_GAMELOG_DB. Steps 5 and 7 are never stored by any function (an AccountLogDB or GameLogDB
loss only reconnects, §1.5); their `MainWork` cases are dead code.

### 1.2 Main thread and the work steps

```pseudo
MainThread(this):                                                          @ FUN_00407340
    m_bActiveMainThread = 1
    while m_bStopMainThread == 0:
        if m_CharDB.state == 1: Sleep(5)        # (original bug) W05-B1: no sleep while the CharDB link is not
                                                # validated (start-up, guild data load, CharDB lost): busy loop
        MainWork(this)
    ProcessStop(this)                            # §1.6
    m_bActiveMainThread = 0
    if m_bOnStopService: return 0                # stopped by the service manager
    exit(0)                                      # stopped by MainWork (DB loss)

MainWork(this):                                                            @ FUN_004070f0
    switch m_MainWorkStep:
        LINK:  ProcessLink; ProcessDisconnect; ProcessConnect; ProcessPacket          # until the DB links are up
        RUN:   ProcessDisconnect; ProcessConnect; ProcessPacket; ProcessContents      # normal operation
        CLOSE_NORMAL        → reason 0x782
        CLOSE_ACCOUNT_DB    → reason 0x789
        CLOSE_ACCOUNTLOG_DB → reason 0x78a   (never reached)
        CLOSE_CHAR_DB       → reason 0x78b
        CLOSE_GAMELOG_DB    → reason 0x78c   (never reached)
        CLOSE_*: CWMClientSessionManager::SetLogoutType(&m_Client, reason)         @ FUN_00437d20
                     # every client session in the active list: m_LogoutType (+0x11a, W01 closeReason) = reason
                 m_bStopMainThread = 1       # MainThread leaves the loop and runs ProcessStop
```

The loop has no fixed period: one pass is the four `Process*` calls, with a 5 ms sleep per pass in normal operation.
Every timed service in `ProcessContents` keeps its own next-run time (§2.1).

### 1.3 ProcessLink (start-up links)

Correction for W01-core §2 (`BootstrapTick`): the listener opened first is the **OPTool** listener, not the zone
listener; zone and client listeners open together once the four DB links are validated. (W01's names
`OpenListener_Zone` FUN_00404600 / "client" FUN_00404720 / "OPTool" FUN_00404820 are shifted: the PDB and the
`*Info` offsets read give OPTool / zone / client.)

```pseudo
ProcessLink(this):          (step LINK only)                               @ FUN_00404bf0
    if !Listen_OPTool(this): m_bStopMainThread = 1; return                  @ FUN_00404600
        # once (static bListen DAT_006d4c10): CWMOPToolSessionManager::InitSessions(m_OPToolInfo.nMaxAccept),
        # Listen_Add(IP, port, nServerIDFrom = listen type 8, backlog); log "<SUCCESSED LISTEN ADD, IP=%s:%d, From=%s>"
        # or "*FAILED LISTEN ADD, IP=%s:%d, From=%s*"
    ConnectAccountLogServer(this)                                           @ FUN_00404b00
    if m_AccountDB.state == 0: Connect(AccountDBInfo) → state 2, "<CONNECTING ACCOUNT DB TO %s:%d>"
                               (failure: "<RECONNECT  ACCOUNT DB TO %s:%d>" once)
    if m_CharDB.state == 0:    same for the CharDB ("<CONNECTING CHAR DB …>" / "<RECONNECT  CHAR DB …>")
    ConnectGameLogServer(this); ConnectLoginServer(this)                    @ FUN_00404a10 / FUN_00404920
    if AccountDB, AccountLogDB, CharDB and GameLogDB are all state 1:
        if Listen_Zone(this) and Listen_Client(this):                        @ FUN_00404720 / FUN_00404820
            # InitSessions(m_ZoneInfo.nMaxAccept) / InitSessions(m_ClientInfo.nMaxAccept) (§4), Listen_Add types 6 / 20
            m_bProcessLinked = 1; m_MainWorkStep = RUN
        else: m_bStopMainThread = 1          # listener failure ends the process
```

The CharDB link reaches state 1 only after the guild / academy data load: on 0x0803 the CharDB parser sets the link to
state 5 (`fc_NC_MISC_S2SCONNECTION_ACK` @ FUN_00409c50, not 1 as for the other links), `ProcessPacket` (§1.4) walks
the load states 5 … 0x18 (W03 §9.1), and the last answer 0x9806 sets state 1 when the academy ranking is loaded
(`fc_NC_GUILD_ACADEMY_START_DB_RANK_BALANCE_ACK` @ FUN_0040ccf0: `m_GuildManager.m_bAcademyRankInit != 0` → state 1).
So the client listener opens only after all guild data is in memory.

### 1.4 ProcessConnect and ProcessPacket (accept and packet pump)

```pseudo
ProcessConnect(this):     (LINK and RUN)                                    @ FUN_00405860
    ConnectLoginServer; ConnectGameLogServer; ConnectAccountLogServer        # reconnect these three if state 0
    for each accepted socket (CSocket_Acceptor::GetAccepted):
        listen type 6 (zone):   s = m_Zone.vtbl[0](socket, addr)            # take a free session (§4)
                                no session → shutdown + closesocket, log
                                register to IOCP and Send 0x0801 NC_MISC_S2SCONNECTION_RDY, else s.state = 3
        listen type 8 (OPTool): same with m_OPTool
        listen type 20 (client): s = m_Client.vtbl[0] = CWMClientSessionManager::ActiveSession (FUN_00438a60, §4)
                                no session → close the socket
                                s.m_Connected_Server_ID = 20; s.state = 1      # clients have no S2S handshake
                                register to IOCP and Send 0x0807 NC_MISC_SEED_ACK (W01 §3.2), else s.state = 3
                                log "Connected from (%-25s world=%3d …)"
```

```pseudo
ProcessPacket(this):      (LINK and RUN)                                    @ FUN_00405aa0
    for link in AccountDB, AccountLogDB, (CharDB, below), GameLogDB, Login: if link.state in {1, 2}: Pump(link)
    CharDB link by state:
        1, 2, 6, 8, 0xA, 0xE, 0x10, 0x12, 0x16, 0x18: Pump(CharDB)
        5, 7, 9, 0xB, 0xD, 0xF, 0x11, 0x13, 0x15, 0x17: send the next start-up request (W03 §9.1), state + 1
        0xC / 0x14: every guild's member / academy table loaded → log, state 0xD / 0x15; else Pump(CharDB)
    for each OPTool session and each zone session with state 1 or 2: Pump(session)
    for each client session with state 1:                                        Pump(session)

Pump(session):   (inlined per link)
    loop:
        r = session.vtbl[0x0c]()                      # packet-queue status
        r == 0: if session.vtbl[0x28](): CWMBaseSession::Receive(session)   # re-arm the read; stop
        r == 1: if !parser.Parser(session): stop      # dispatch one packet (pft_Store tables)
                session.vtbl[0x24]()                  # drop the handled packet
                continue only if bWorkAllAndNextSession (DAT_006d4c18) != 0
        r == 2: session.state = 3; session.vtbl[0x18](); log "FATAL ERROR - m_<Link> …" (CharDB: also the last
                two packets "Pre-last packet dep=%d, command=%d, size=%d, WT=%d" / "Last packet …"); stop
```

`bWorkAllAndNextSession` is in `.bss` and never written, so it is 0: **each session gets at most one packet per main
loop pass** (round-robin over all links and sessions).

### 1.5 ProcessDisconnect (heartbeats and closing links)

W01-core §2 (`SessionCleanupTick`) documents the client-session part (2-hour login timeout, too many sessions per
IP, close and free). The rest:

```pseudo
ProcessDisconnect(this):     (LINK and RUN)                                 @ FUN_00404e70
    for link in AccountLogDB, AccountDB, CharDB, GameLogDB, Login:
        if !CheckHeartBeat(link): CSocket_IOCP::CloseUseIOCP(link.socket)
    CWMBaseSessionManager::ProcHeartBeat(m_OPTool / m_Zone / m_Client)      @ FUN_00430160
        # CheckHeartBeat for every active session, CloseUseIOCP on failure

    AccountDB state 3:  Session_Close (CWMBaseSession::Close FUN_0042fc30)
        not yet linked (m_bProcessLinked == 0): state 0 (ProcessLink reconnects)
        linked: log "Closed AC from …"; m_MainWorkStep = CLOSE_ACCOUNT_DB; state 4    # → WM shuts down (§1.2)
    AccountLogDB / GameLogDB state 3: Close; state 0; log "Closed AL|GL from …" when linked
                                       # reconnected by ProcessConnect on the next pass
    CharDB state 3: Close
        not yet linked: state 0
        linked: log "Closed CH from …"; m_MainWorkStep = CLOSE_CHAR_DB; state 4; ReconnectCount++
                if Connect(CharDBInfo) == 1: m_MainWorkStep = RUN; state 2; log "<AUTO-RECONNECT  CHAR DB Count=%d TO %s:%d>"
                else: log "<AUTO-RECONNECT2 CHAR DB Count=%d TO %s:%d>" (once)       # step stays CLOSE_CHAR_DB → shutdown
    Login state 3: log "Closed LO from …"; Close; state 0
    zone / OPTool / client sessions: W01-core §2

CWMBaseSession::CheckHeartBeat(s):                                          @ FUN_0042fda0
    skip sessions with state 0, 3 or 4
    now = CGTimer::GetTime() (ms)
    if now − s.m_LastReceiveTime < 30000: s.m_LastHeartBeatSendTime = 0; return ok
    if s.m_LastHeartBeatSendTime == 0:
        s.m_LastHeartBeatSendTime = now; SendRaw(s, 0x0804 NC_MISC_HEARTBEAT_REQ {})   # 3 raw bytes 02 04 08
    elif now − s.m_LastHeartBeatSendTime ≥ 180000:
        log "ERROR - HEARTBEAT OVERTIME, NOW DISSCONNECT WITH %s"; return fail
    return ok
```

So a peer (DB server, Login, zone, OPTool or client) that sends nothing for 30 s gets one `0x0804`; if nothing at all
arrives in the next 180 s, the WM closes it. Any received packet resets the timer (`m_LastReceiveTime`, network
library). After a CharDB reconnect the link goes through the whole guild load again (state 5 on 0x0803), while
clients stay connected *(inferred: nothing blocks clients during it; their CharDB requests are sent on a link in
state 5 … 0x18)*.

### 1.6 Shutdown

```pseudo
::OnStop_Service() (service manager STOP):                                   @ FUN_00403770
    gServer.m_bOnStopService = 1
    WorldManagerServer::OnStop_Service(&gServer)                               @ FUN_00406d40
        m_MainWorkStep = CLOSE_NORMAL; m_bStopMainThread = 1
        wait (Sleep 50 ms) until m_bActiveMainThread == 0
    # (original bug) W05-B2: m_bStopMainThread is set together with the step, so MainThread leaves its loop
    # without running MainWork's CLOSE_NORMAL case: SetLogoutType(0x782) is not applied and the logout reports
    # (AccountDB 0x0C11 / AccountLog 0x0722) carry each session's current m_LogoutType instead of 0x782

ProcessStop(this):                                                            @ FUN_004067f0
    CSocket_Acceptor::Listen_Stop; CIOCP::Close
    CWMClientSessionManager::DissconnectAllSessions(&m_Client)               @ FUN_004376a0
        every active client: CWMClientSession::Close (W01 Client_OnClosed FUN_00437030: CharacterLogout,
        0x0C11 / 0x0722 / 0xC803 with m_LogoutType, 0x0C19 to the zones)
    CWMClientSessionManager::FreeSessions(&m_Client)                          @ FUN_00437660 (§4)
    CWMBaseSessionManager::DissconnectAllSessions(&m_Zone)                    @ FUN_00430130 (Close every session)
    CWMZoneSessionManager::FreeSessions(&m_Zone)
    Close Login, AccountDB, AccountLogDB, CharDB, GameLogDB links
    DissconnectAllSessions(&m_OPTool); CWMOPToolSessionManager::FreeSessions(&m_OPTool)
    ViewStopInfo(this)                                                        @ FUN_00403d40  (m_ServerStopTime, log local + UTC time)
```

WM `closeReason` (`m_LogoutType`) values added by this section (W01 knowledge lists 0x780/0x785/0x787/0x788/0x790):
0x782 server stopped normally, 0x789 AccountDB lost, 0x78a AccountLogDB lost (unused), 0x78b CharDB lost and not
reconnected, 0x78c GameLogDB lost (unused). The reason travels to AccountDB 0x0C11 / AccountLogDB 0x0722 (W01 §2)
and as `closeReason − 0x80` in CharDB 0x1037 (W01 §5.4).

---

## 2. Timed services (`ProcessContents`)

### 2.1 Order and period

`WorldManagerServer::ProcessContents` @ FUN_00406760 runs once per main-loop pass in step RUN, in this order. Each
service checks its own clock; the period column is the one documented by the owning item.

| # | Call | Period | Documented in |
|---|---|---|---|
| 1 | `CKQServer::DoKingdomQuest` FUN_00456190 (`KQ_Tick`) | 1 s (schedule part once a minute) | W04 §6.2 |
| 2 | `CWMLoginSession::SendUserCount(&m_Login, 0)` FUN_00438d10 (`Login_WorldStatus_0808`) | 30 s | W01 §2 |
| 3 | `CGuildManager::Process` FUN_0044fd60 (`GuildManager_Tick`) | dismiss 1 h, war 1 s, tournament 1 min | W03 §7 |
| 4 | `CPrisonServer::GetInstance` FUN_004589b0 → `CPrisonServer::OnPrisonTimer` FUN_00458360 | 2 s | W04 §9.1 |
| 5 | `CWMZoneSessionManager::SendWMTimeToZone(&m_Zone, 0)` FUN_00439590 (`Zones_TimeSync_0821`) | 60 s | W01 §2 |
| 6 | `CWMClientSessionManager::SendWMTimeToClient` FUN_00437e30 (0x0849) | 60 s, aligned to the minute | §2.2 |
| 7 | `CPartyFinderServer::Process` FUN_004575c0 (`PartyFinder_ExpireTick`) | 11 s | W02 §1.5 |
| 8 | `CGambleSystemServer::SendExchangeCoinInit` FUN_0043c2d0 | once a day at `GB_ResetTime` | W04 §15.1 |
| 9 | `CNpcScheduleServer::enss_Process` FUN_004574d0 (`NpcSched_Tick`) | every pass | W04 §17.6 |
| 10 | `cEvent_Attendance::EA_Schedule_Process` FUN_0043bde0 | 1 s | W04 §17.5 |
| 11 | `CDailyQuestTimer::DQ_Schedule_Process` FUN_0043a120 | once a day after local midnight | §2.3 |
| 12 | `RankingServer::Process` FUN_004021c0 (`IndunRank_DailyReset`) | once a day at local midnight | W04 §13.3 |

None of them runs before step RUN, i.e. before all four DB links and the guild load are done (§1.3).

### 2.2 Server time for the clients (0x0849)

```pseudo
0x0849 NC_MISC_SERVER_TIME_NOTIFY_CMD { tm dCurrentTM (9 × i32); i8 nTimeZone }   (37 bytes, WM → client)

CWMClientSessionManager::SendWMTimeToClient(this):     (every main-loop pass)   @ FUN_00437e30
    now = _time32()
    if now < this.m_NextSendWMTime: return
    if this.m_NextSendWMTime == 0:                    # first pass after start
        t = localtime(now); t.min += 1; t.sec = 0; m_NextSendWMTime = mktime(t)   # next full minute; nothing sent
        return
    m_NextSendWMTime = mktime(localtime(now) with sec + 60)                       # = now + 60 s
    local = localtime(now2); utc = gmtime(now2)       # now2 = _time32() again
    nTimeZone = (i8)((mktime(local) − mktime(utc)) / 3600)     # signed hours, truncated toward 0
    Send to every client session with inGame (+0x704) == 1:            # BroadCastToPlayer(&m_Client, pkt, 0)
        0x0849 { dCurrentTM = local, nTimeZone }                       #   @ FUN_00437b40 (W01 Clients_BroadcastInGame)

CWMClientSession::SendWMTimeToClientFirst(s):   (from 0x180C map-login-done, W01 §7.3)   @ FUN_00432e10
    if s.m_bFirstJoinSend_WMTime_ToClient (+0x1ed00) == 0: return
    s.m_bFirstJoinSend_WMTime_ToClient = 0
    Send s 0x0849 { dCurrentTM = localtime(now), nTimeZone as above }
    # the flag is set to 1 by CharDB 0x1007 NC_CHAR_CHARDATA_ACK (fc_NC_CHAR_CHARDATA_ACK FUN_00410040), so each
    # character login gets one 0x0849 on its first map login; map changes do not repeat it
```

Field names *(pdb2016)* `PROTO_NC_MISC_SERVER_TIME_NOTIFY_CMD { tm dCurrentTM; char nTimeZone; }` (0x25), the 2017
client PDB agrees. Only the minute grid is aligned: each later send is scheduled 60 s after the pass that sent it,
so the send second drifts by the loop latency *(inferred)*. `mktime(utc)` reads the UTC fields with `tm_isdst = 0`
as local standard time, so `nTimeZone` is the standard-time offset and leaves out daylight saving *(inferred from
the C runtime semantics)*; half-hour zones are truncated.

Client: `GameFrameWork::On_NC_MISC_SERVER_TIME_NOTIFY_CMD` (2016 FUN_004a4420, name from the 2017 PDB) copies
`dCurrentTM` to a global (DAT_00a80918), `nTimeZone` to DAT_00a8094c and stores `QueryPerformanceCounter` as the
reference point. FUN_0057d8f0 shows the clock: `dCurrentTM` + elapsed seconds, `strftime("%H:%M")` followed by
`" {color,yellow,GMT(+%d)}"` (or `"GMT(-%d)"` with the already negative value, so a negative zone shows as
`GMT(--5)`; client-side). No error codes.

### 2.3 Quest reset times (`CDailyQuestTimer`, 0x441C / 0x441D)

`gServer.m_DailyQuestTimer` (+0x22b440, DAT_006c5468): `m_ResetTime { tResetYearQuest, tResetMonthQuest,
tResetWeekQuest, tResetDayQuest }` (start of the current period, time_t) and `m_InitTime { tInitYearQuest,
tInitMonthQuest, tInitWeekQuest, tInitDayQuest }` (when the period ends). Weeks start on **Monday 00:00** local time.

```pseudo
helpers (all local time, via localtime + mktime):                     @ FUN_00439a00 … FUN_00439c80
    GetToday      today 00:00                 GetTodayEnd     today 00:00 + 86400
    GetThisWeek   Monday 00:00 of this week   GetThisWeekEnd  next Monday 00:00
    GetThisMonth  1st of this month 00:00     GetThisYear     1 January 00:00

CDailyQuestTimer::CDailyQuestTimer(this):    (process start, global constructor)       @ FUN_00439f10
    m_ResetTime = { GetThisYear, GetThisMonth, GetThisWeek, GetToday }  (inlined)
    tInitYearQuest  = 1 January of next year
    tInitMonthQuest = 1st of next month; in December: year + 1, month = 1 (February)   # (original bug) W05-B3
    tInitWeekQuest  = GetThisWeekEnd; tInitDayQuest = today 00:00 + 86400

CDailyQuestTimer::DQ_Schedule_Process(this):   (every main-loop pass)  @ FUN_0043a120
    now = _time32()
    if now <= m_InitTime.tInitDayQuest: return 0
    if now > tInitYearQuest:    tResetYearQuest = GetThisYear; tResetMonthQuest = 1st of this month (inline)
    elif now > tInitMonthQuest: tResetMonthQuest = GetThisMonth
    elif now <= tInitWeekQuest: goto day
    tResetWeekQuest = GetThisWeek
  day:
    tResetDayQuest = GetToday; tInitDayQuest = GetTodayEnd
    Send_NC_QUEST_RESET_TIME_CMD(this, m_ResetTime); return 1
    # (original bug) W05-B4: tInitYear/Month/WeekQuest are never advanced after the constructor, so after the first
    # year / month / week boundary every daily run takes that branch again; harmless, the values are recomputed as
    # "start of the current period"

Send_NC_QUEST_RESET_TIME_CMD(this, t):                                   @ FUN_00439d20
    Broadcast to all zones (CWMZoneSessionManager::BroadCast)
        0x441C NC_QUEST_RESET_TIME_CMD { i32 tResetYearQuest, i32 tResetMonthQuest, i32 tResetWeekQuest,
                                         i32 tResetDayQuest }            (16 bytes)
    broadcast failure → log "DEBUG - CDailyQuestTimer::Send_NC_QUEST_RESET_TIME_CMD : Zone broadcast fail"

Send_NC_QUEST_RESET_TIME_ZONE_CMD(this, zone, hdr):  (per character at map login, W01 §7.2 0x101C)   @ FUN_00439e30
    zone == null → return 0
    Send zone 0x441D NC_QUEST_RESET_TIME_ZONE_CMD { u32 nCharNo = hdr.charregistnumber, i32 Year, Month, Week, Day }  (20 bytes)
```

So the daily reset runs at the first main-loop pass after local midnight and tells every zone at once; a character
entering a zone gets the current times by 0x441D (the `charregistnumber` of the zone's 0x101C header is the
character number, Z01-core §5.3 `{ p.handle, charNo }`). The zone side (Z08 §3.4) stores them per player and forwards them
to the client as 0x441E. The WM itself does not reset any quest; it only defines the reset instants. Field names
*(pdb2016)* = the 2017 PDB.

---

## 3. Data loader (`ReadGlobalGameData`) and the SHN reader

The WM loads all its game data once, in `Start` before the service dispatcher starts (§1.1); nothing reloads it
later (no reload command reaches these loaders). Config files (`WMServerInfo.txt`, `ServerInfo.txt`) are read
before this by `ReadDefineScriptor` (W01 §2); the WM reads no other input file. Files it writes: debug log
`.\DebugMessage\Msg_<yyyy-mm-dd>.txt` (`_DEBUGMSG` FUN_00460340 → `_DebugMessageNew2` FUN_00460130), the
`SLS_AddLog` logs, `CallStack.txt` (crash dump), `Assert<date><hh>.txt` and `ExitLog<date><hh>.txt` (`ShineExit`).

### 3.1 `CDataReader`: the SHN reader all tables use

`CDataReader` *(pdb2016)*, 0x40 bytes: +0 vftable, +4 `m_nFileSize`, +8 `m_nBFSize` (buffer capacity), +0xC
`m_nDataArraySize`, +0x10 `m_nFileCheckSum`, +0x14 `m_sFileMD5` (Name8 = char[32], hex text), +0x34 `m_pHead`
(`HEAD*`, the whole file), +0x38 `m_pData` (first row), +0x3C `m_pDataArray` (row pointers). SHN header and field
types: `docs/knowledge/S01.md` §6.1; the cipher is the one `tools/protocol-re/shn.py` implements.

```pseudo
CDataReader::CDataReader(this)                                                         @ FUN_00458a70
    MD5 text = 0; m_pHead = 0; m_nBFSize = m_nDataArraySize = m_nFileCheckSum = 0

CDataReader::Read(this, path) → bool                                                   @ FUN_00458ca0
    f = fopen(path, "rb"); none → return 0
    m_nFileSize = filelength(f)
    if m_nBFSize < m_nFileSize:                       # grow only; a smaller file reuses the old buffer
        free the old buffer; m_pHead = new[m_nFileSize]; m_nBFSize = m_nFileSize; m_nFileCheckSum = 0
    if fread(m_pHead, m_nFileSize) fails: fclose; free the buffer; m_nBFSize = m_nFileCheckSum = 0; return 0
    fclose(f)
    if HEAD.nDataMode != 0: CDataReader::Encription(&HEAD.nDataSize (+0x24), m_nFileSize − 0x24)   @ FUN_00458aa0
        # in place, from the last byte down: b[i] ^= key; key = (i·11) ^ ((i & 0xF) + 0x55) ^ key ^ 0xAA,
        # first key = low byte of the length (= shn.py decrypt)
    m_pData = m_pHead + 0x34 + nNumOfField · 0x38
    grow m_pDataArray to nNumOfRecord; walk the rows: m_pDataArray[i] = row + 2 (each row starts with a u16 length)
    m_nFileCheckSum = Σ byte[i] · i over i < m_nBFSize            # never read by the WM
    m_sFileMD5 = MD5 hex text of the first m_nBFSize bytes        (CMD5Checksum::GetMD5)
        # both use the buffer capacity, not the file size: a re-read of a smaller file hashes stale bytes,
        # (original bug) W05-B6
    return CShnDataFileCheckSum::InitDataFileCheckSum(&ShnDataFile, path, m_sFileMD5)    # §3.4

CDataReader::Read(this, path, key, rowSize) → bool       (`Shn_LoadChecked`)                @ FUN_00458f00
    return Read(path) and HEAD.nVersionKey == key and HEAD.nFieldSize − 2 == rowSize

CDataReader::GetRecord(this, i) → row* or 0              (`Shn_GetRow`)                     @ FUN_00458ae0
    m_pHead != 0 and i < nNumOfRecord ? m_pDataArray[i] : 0
CDataReader::~CDataReader(this): free the buffer and the row array                        @ FUN_00458b10
```

Every WM table goes through the checked read: a wrong `nVersionKey` (= the row struct's `DataVersionKey`, S01 §6.1)
or row size refuses the file. All 2016 files pass (checked with `shn.py`: key, row size and row count below).

### 3.2 `ReadGlobalGameData`: order, destination, checks

```pseudo
WorldManagerServer::ReadGlobalGameData(this) → bool                                    @ FUN_00404100
    for each row of the table below, in order:
        ok = <loader>(<object>, "../9Data/Shine/<file>")
        if !ok: _DEBUGMSG("*FATAL ERROR* - <text> READ FAILED %s"); return 0
            # _DEBUGMSG passes its varargs to _vsnprintf but the call has no argument for "%s": the text
            # prints whatever pointer is on the stack (or faults while logging) (original bug) W05-B7
    # between rows 9 and 10: m_BoomStartKey1 … m_BoomStartKey6 (+0x22b4e4 … +0x22b4f8, u32) = 0;
    #   no WM function reads or writes them otherwise (dead members)
    CharClassDataBox::ccdb_Load(&m_CharClassDataBox, "../9Data/Shine/UseClassTypeInfo.shn")   # row 25
    return 1
# Start returns −4 when this returns 0: the process ends before the service runs (§1.1).
```

"Fatal" = `ReadGlobalGameData` returns 0 → WM does not start. All rows are fatal; no table is optional. Offsets are
from `gServer`. Key / row = the arguments of the checked read (`Shn_LoadChecked`); rows = 2016 file.

| # | File | Loader | Lands at | Key / row | 2016 rows | Extra check (fatal) | Used by |
|---|---|---|---|---|---|---|---|
| 1 | `MsgWorldManager.shn` | `CDataReader::Read` FUN_00458f00 | +0xc40c0 `m_MsgWM` | 0x1E / 1 (Desc VARSTR) | 3 | — | `GetMsg` (§3.3): KQ notices, W04 §6.2 |
| 2 | `KingdomQuest.shn` | `CKQServer::Read` FUN_00451b40 | +0xc4134 `m_KQServer` (+0x1B9D4) | 0x2535 / 0xB4 | 57 | W04 §6.1 | W04 §6 |
| 3 | `KingdomQuestMap.shn` | `CKQServer::ReadMap` FUN_00453e70 | `m_KQServer` +0x1BA14 | 0x2085 / 0x16B | 38 | W04 §6.1 | W04 §6 |
| 4 | `KQVoteMajorityRate.shn` | `CKQServer::ReadVoteRate` FUN_00451b60 | `m_KQServer` +0x1BA54 | 1 / 1 | 2 | — | W04 §6.5 |
| 5 | `KQIsVote.shn` | `CKQServer::ReadIsVote` FUN_00451b80 | `m_KQServer` +0x1BA94 | 5 / 3 | 30 | duplicate / missing IDs only logged (W04 §6.1) | W04 §6.1, §6.5 |
| 6 | `KQTeam.shn` | `CKQServer::ReadTeam` FUN_00451d80 | `m_KQServer` +0x1BAD4 | 0xF1 / 0x16 | 8 | W04 §6.1 | W04 §6 |
| 7 | `GuildGradeData.shn` | `CGuildDataServer::ReadGradeScoreData` FUN_0045a7e0 (on `m_GuildGradeData`) | +0x22b06c `m_GuildGradeData.m_GuildGradeData` | 0x4DA / 0x15 | 5 | — | **nobody in the WM** (below) |
| 8 | `GuildGradeScoreData.shn` | same FUN_0045a7e0 | +0x22b0ac `m_GuildDataServer` +0 `m_GuildGradeScoreData` | 0x2BD / 0xE | 7 | — | `GetGradeScore` FUN_0043c410, war points W03 §3.4 |
| 9 | `GuildLevelScoreData.shn` | `ReadLevelScoreData` FUN_0043c400 | `m_GuildDataServer` +0x40 | 0x12 / 4 | 3 | — | FUN_0043c450, W03 §3.4 |
| 10 | `GuildTournament.shn` | `CGuildTournamentServer::ReadScheduleData` FUN_0043d270 | +0x22acc4 `m_GuildManager.m_Tournament` (T) +0x2D4, active row T+0x314 | 0x3DE / 0x1D | 7 | ≥ 1 row; active row (below) | W03 §8.4, W04 §4.4 |
| 11 | `GuildTournamentReward.shn` | `ReadRewardData` FUN_0043d200 | T+0x318, row 0 at T+0x358 | 0x225 / 0x26 | 37 | ≥ 1 row | W03 §8.5 |
| 12 | `GuildTournamentRequire.shn` | `ReadRequireData` FUN_0043d510 | T+0x35C, row 0 at T+0x39C | 0x18 / 7 | 1 | ≥ 1 row | W03 §8.1 (entry conditions) |
| 13 | `GuildAcademy.shn` | `ReadGuildAcademyData` FUN_0043c520 | `m_GuildDataServer` +0x80, row 0 at +0xC0 | 0xDA / 0x26 | 1 | ≥ 1 row | W03 §6.4 (BuffName) |
| 14 | `GuildAcademyLevelUp.shn` | `ReadGuildAcademyLevelUpData` FUN_0043c590 | `m_GuildDataServer` +0xC4, row 0 at +0x104 | 0x2F / 9 | 51 | ≥ 1 row | W03 §4.7, §6.4 (FUN_0043c670) |
| 15 | `GuildAcademyRank.shn` | `ReadGuildAcademyRankData` FUN_0043c600 | `m_GuildDataServer` +0x108, row 0 at +0x148 | 0x108 / 0x26 | 4 | ≥ 1 row | W03 §6.4 |
| 16 | `SpamerReport.shn` | `CDataFileServer::ReadSpamerReportData` FUN_0043a220 | +0x22b1f8 `m_DataFileServer` +0, row 0 at +0x40 | 0x11C / 0x86 | 1 | ≥ 1 row | W04 §2.5 |
| 17 | `GBHouse.shn` | `ReadGBHouseData` FUN_0043a2e0 | `m_DataFileServer` +0x44, row 0 at +0x84 | 0x28 / 0xB | 1 | ≥ 1 row | W04 §15.1 |
| 18 | `NpcSchedule.shn` | `CNpcScheduleServer::enss_DataLoad` FUN_00457510 | +0x22b344 `m_NpcScheduleServer` | 0x83 / 0x2A | **0** | W04 §17.6 | W04 §17.6 |
| 19 | `BadNameFilter.shn` | `ReadBadNameFilterData` FUN_0043a370 | `m_DataFileServer` +0x88, row 0 at +0xC8 | 0x12 / 0x24 | 1175 | ≥ 1 row; every BadName upper-cased in place (`_mbsupr`) | `GetIsBadName` (§3.3): W01 §4.1, W03 §2.2 |
| 20 | `AttendSchedule.shn` | `ReadAttendScheduleData` FUN_0043a4c0 | `m_DataFileServer` +0xCC | 0x5C / 0xA | 1 | rows ordered and not overlapping (below) | W04 §17.5 |
| 21 | `AttendReward.shn` | `ReadAttendRewardData` FUN_0043a620 | `m_DataFileServer` +0x10C | 0x98 / 0x26 | 7 | — | W04 §17.5 |
| 22 | — | `cEvent_Attendance::EA_Schedule_Init(…, 0)` FUN_0043b090 | +0x22b38c `m_EventAttendance` | — | — | AttendSchedule row 0 usable (W04 §17.5); text "*FATAL ERROR* - Attend Schedule" | W04 §17.5 |
| 23 | — | `EA_Event_Set_RewardData` FUN_0043b9c0 | `m_EventAttendance` | — | — | AR_Type 0 or 1 only (W04 §17.5); "*FATAL ERROR* - Attend Set RewardData" | W04 §17.5 |
| 24 | `SingleData.shn` | `CSingleDataMap::InitSingleDataArray` FUN_00459de0 | +0x22b474 `m_SingleData` (std::map) | 7 / 0x22 | 41 | every row non-null | `GetValue` (§3.3) |
| 25 | `UseClassTypeInfo.shn` | `CharClassDataBox::ccdb_Load` FUN_00465a80 → `BinaryDataBox<UseClassTypeInfo>::bdb_ReadData` FUN_00465960 | +0x22b484 `m_CharClassDataBox` | 0x48A / 0x1F | 39 | failure → `ShineExit` (below) | `ccdb_UseClassTypeToBit` FUN_00465a90: KQ class mask, W04 §6.2 |

Error texts (row → `*FATAL ERROR* - … READ FAILED %s`): 1 `MsgWorldManager.shn`, 2–6 `KINGDOM QUEST [MAP / VOTE RATE /
ISVOTE / TEAM] DATA`, 7 `GUILD GRADE DATA`, 8 `GUILD GRADE SCORE DATA`, 9 `GUILD LEVEL SCORE DATA`, 10–12 `GUILD
TOURNAMENT [REWARD / REQUIRE] DATA`, 13–15 `GUILD ACADEMY [LEVEL UP / RANK] DATA`, 16–21 `DATA FILE - SPAMER REPORT /
GAMBLE HOUSE / NPC SCHEDULE / BAD NAME FILTER / Attend Schedule / Attend Reward DATA`, 24 `DATA FILE - SINGLE DATA`.

Loader details:

```pseudo
# rows 11–17 (the "row 0" loaders): one pattern
Read<X>Data(this, path):                    @ FUN_0043d200 FUN_0043d510 FUN_0043c520 FUN_0043c590 FUN_0043c600 FUN_0043a220 FUN_0043a2e0
    m_p<X> = 0
    if !Read(&m_<X>, path, key, row) or nNumOfRecord == 0: return 0
    m_p<X> = GetRecord(0); return m_p<X> != 0
    # the WM keeps only row 0 for SpamerReport, GBHouse, GuildTournamentRequire, GuildAcademy;
    # the others are walked by their users (W03 / W04)

CGuildTournamentServer::ReadScheduleData(T, path)                                     @ FUN_0043d270
    m_pScheduleData = 0
    if !Read(T+0x2D4, path, 0x3DE, 0x1D) or no rows: return 0
    for i in rows: m_pScheduleData = row i; if row.isActive == 1: break
    return m_pScheduleData != 0
    # with no active row the loop leaves the LAST row as the schedule and the load succeeds
    # (original bug) W05-B5; 2016: row 0 is active (isActive 1, Week 2, 13:00, MatchCycleMin 10080)

CDataFileServer::ReadBadNameFilterData(this, path)                                     @ FUN_0043a370
    checked read (0x12, 0x24), ≥ 1 row; _mbsupr(row.BadName) for every row; return 1
    # row: BadName char[32] @0, Type FilterType u32 @0x20 (FT_COMPLETE 0, FT_PART 1) (pdb2016)

CDataFileServer::ReadAttendScheduleData(this, path)                                     @ FUN_0043a4c0
    checked read (0x5C, 0xA)        # row: AS_StartYear u16, Month, Day, Hour, Minute u8, AS_JoinKeepTime u16 @6,
                                    #      AS_CheckTerm u16 @8 (W04 §17.5)
    prevEnd = 0
    for each row (0 rows pass):
        row missing → return 0
        if AS_CheckTerm ≤ AS_JoinKeepTime: return 0          # a "day" must be longer than the required online time
        start = mktime(local AS_StartYear-AS_StartMonth-AS_StartDay AS_StartHour:AS_StartMinute:00)
        if start < prevEnd: return 0                          # also an invalid date (mktime −1) on row 0
        prevEnd = start + AS_CheckTerm · 1680                  # 1680 = 28 days × 60: the event's 28 "days"
    return 1
    # a _time32(now) is taken and never used. 2016: 1 row, 2015-11-09 00:00, JoinKeepTime 60, CheckTerm 1440

CSingleDataMap::InitSingleDataArray(this, path, 7, 0x22)                                @ FUN_00459de0
    read into a temporary CDataReader (checked); failure → return 0
    for each row: missing → return 0; m_SingleData[string(row.SingleDataIDX char[32])] = row.SingleDataValue u16 @0x20
    the temporary reader is freed; only the map stays

BinaryDataBox<UseClassTypeInfo>::bdb_ReadData(this, path)                               @ FUN_00465960
    if checked read (0x48A, 0x1F) succeeds: return
    ac_AssertFail("BinaryDataBox<T>::bdb_ReadData : readfail", path); ac_AssertFail("Code:%X:%d\tSHN:%X:%d")
    ShineExit("BinaryDataBox<T>::bdb_ReadData")                                         @ FUN_004673f0
        append "<time> : AssertClass::ac_AssertFail : <text>" to ExitLog<yyyymmdd><hh>.txt; exit(0)
    # so this last table does not fail through ReadGlobalGameData: the process exits with code 0
    # row: UseClass (UseClassType enum, 39 values UCT_NONE … UCT_SHIELD_NOT_GLA) u32 @0, then one u8 per class
    # Fig @4 … Sav @0x1E (27 classes); ccdb_UseClassTypeToBit FUN_00465a90 turns the row of a UseClass into a u64
    # mask, bit 0 = Fig … bit 26 = Sav; unknown UseClass → 0 (W04 §6.2 uses it for the KQ class check)
```

`GuildGradeData.shn` (row 7): `CGuildGradeData` *(pdb2016)* is one `CDataReader`; the loader called for it is the
PDB's `CGuildDataServer::ReadGradeScoreData` with `this = &m_GuildGradeData` (both readers sit at +0 of their
object, so the linker folded the two identical functions *(inferred)*). No WM function reads `m_GuildGradeData`
(gServer+0x22b06c has no other reference): the WM loads it only for the start-up check. Its columns (Type, NeedFame,
MaxOfMember, MaxOfGradeMember[7]) are the zone's guild-grade rules (W03 §9.5: the zone combines the grade with the
GuildGradeData rights).

### 3.3 Table accessors

```pseudo
WorldManagerServer::GetMsg(this, n) → char*        (`WM_GetMsg`)                         @ FUN_00404570
    n < nNumOfRecord(m_MsgWM) ? GetRecord(m_MsgWM, n) (= Desc text) : pNULLMSG ("")
    # 2016 has rows 0…2; W04-B58 reads #3 / #4

CDataFileServer::GetIsBadName(this, name) → 1 = forbidden                                @ FUN_0043a400
    up = strcpy(local[128], name); _mbsupr(up)           # unbounded copy; callers pass length-checked names
    for each BadNameFilter row:
        Type 0 FT_COMPLETE: _mbsicmp(name, row.BadName) == 0 → return 1     # whole name, case-insensitive
        Type 1 FT_PART:     _mbsstr(up, row.BadName) != 0   → return 1     # BadName anywhere in the name
        other types: ignored
    return 0
    # callers: character create / rename (W01 §4.1, FUN_0043a400 there marked inferred: confirmed) and guild
    # create (W03 §2.2)

CSingleDataMap::GetValue(this, key) → u16           (`ServerParam_GetInt`)              @ FUN_00459f10
    return m_SingleData[key]           # std::map operator[]: an unknown key is inserted with 0 and returns 0
```

`SingleData.shn` keys the WM reads (all 16 exist in the 2016 file; value in brackets):

| Key | 2016 | Read by (documented in) |
|---|---|---|
| `KQVote_VoteLimitTime` | 60 | `CKQServer::GetVoingEndTime`, 0x5810 vote start (W04 §6.5) |
| `KQVote_SuggestCoolTime` | 300 | 0x5810 vote start (W04 §6.5) |
| `KQVote_LoginCoolTime` | 300 | `fc_NC_CHAR_LOGIN_REQ`, `TutorialLoginProcess` (W01 §4.2) |
| `KQPlayerList_ResetListCoolTime` | 5 | `Recv_NC_KQ_JOIN_LIST_REQ` (W04 §6.5) |
| `Guild_CannotLeaveTime` | 1 | `MemberJoin`, member leave / vanish (W03 §2.6, §2.7) |
| `Academy_CannotJoinNotTime` | 30 | `CGuildAcademyServer::AddBanishInfo` (W03 §5) |
| `GE_Member_60Lv`, `GE_Member_100Lv`, `GE_Change_Month`, `GE_Delete_Term_Date` | 20, 5, 1, 30 | guild emblem conditions and expiry (W03 §3.11) |
| `ChrLevel_CanCreateSen` | 60 | `fc_NC_AVATAR_CREATE_REQ` (W01 §4.1) |
| `UserNewbie_DaysAfterSignUp`, `UserComeback_DaysAfterSignUp` / `…DaysAfterLogOff` / `…DaysAfterComeback` | 21, 90, 30, 15 | AccountDB return check, AccountLogDB last-logout day (W01 §3.3) |
| `FriendLvDiff` | 10 | `fc_NC_FRIEND_FIND_FRIENDS_REQ` (W04 §5.6) |

The other 25 keys (Gather_*, Sen*, Pup*, item / mix keys …) are zone settings; the WM loads them unused.

### 3.4 Client-SHN checksum list (`CShnDataFileCheckSum`)

`ShnDataFile` (DAT_006d52e0) is a global `CShnDataFileCheckSum` *(pdb2016)*: `InitCheckSumCnt` u32 @0, then 49
entries of 0x41 bytes { bool `Marking` @0, Name8 `CheckSum` @1 (MD5 hex text), char `DataFileName`[32] @0x21 }
(size 0xC78). It is the zone's client-data check (the client sends the MD5s of these 49 files in 0x1801
NC_MAP_LOGIN_REQ and the zone compares them, Z01 §5.2), linked into the WM as part of the shared `CDataReader`
code.

```pseudo
`dynamic_initializer_for_'ShnDataFile'` (CRT static constructor, before WinMain)                @ FUN_00482610
    CShnDataFileCheckSum::CShnDataFileCheckSum(&ShnDataFile); atexit(destructor FUN_00482a10)

CShnDataFileCheckSum::CShnDataFileCheckSum(this)                                       @ FUN_0045d8c0
    InitCheckSumCnt = 0; every Marking = false
    DataFileName[0…48] = Abstate, ActiveSkill, CharacterTitleData, ChargedEffect, ClassName, Gather,
        GradeItemOption, ItemDismantle, ItemInfo, MapInfo, MiniHouse, MiniHouseFurniture, MiniHouseObjAni, MobInfo,
        PassiveSkill, Riding, SubAbstate, UpgradeInfo, WeaponAttrib, WeaponTitleData, MiniHouseFurnitureObjEffect,
        MiniHouseEndure, DiceDividind, ActionViewInfo, MapLinkPoint, MapWayPoint, AbStateView, ActiveSkillView,
        CharacterTitleStateView, EffectViewInfo, ItemShopView, ItemViewInfo, MapViewInfo, MobViewInfo, NPCViewInfo,
        PassiveSkillView, ProduceView, CollectCardView, GTIView, ItemViewEquipTypeInfo, SingleData,
        MarketSearchInfo, ItemMoney, PupMain, ChatColor, TermExtendMatch, MinimonInfo, MinimonAutoUseItem,
        ChargedDeletableBuff  (each + ".shn"), then every name lower-cased
    # index = position in the client's 0x1801 checksum array (same list in the zone, FUN_00631450)

CShnDataFileCheckSum::InitDataFileCheckSum(this, path, md5) → bool                     @ FUN_0045d710
    copy path to a 128-byte local (unbounded), lower-case it, split at '/' and '\'
    for each token: if it equals DataFileName[i] (exact, after both were lower-cased):
        if InitCheckSumCnt > 49: return 0             # makes the CDataReader::Read fail
        CheckSum[i] = md5; Marking[i] = true; InitCheckSumCnt++; return 1
    return 1                                           # files not in the list pass
```

**What uses it in the WM: nothing.** Only the constructor, `InitDataFileCheckSum` (called by every
`CDataReader::Read`) and the destructor touch `ShnDataFile`; the WM has no `DataFileCheck` / `GetDataFileCheckSum`
(the zone has them, FUN_00631350 …). Of the WM's 25 files only `SingleData.shn` is in the list, so at run time entry
40 holds the MD5 of the WM's `SingleData.shn` and nothing reads it. A rebuild of the WM can drop the class; the check
belongs to the zone (Z01 §5.2).

---

## 4. Session pools and the client session lifecycle

W01-core §2 / §3.2 / §5.4 document what happens *inside* a client session (world login, `CharacterLogout`,
`Client_OnClosed`). This section documents the pool around it: how a slot is taken, reset, released and destroyed,
which event leads there, and the same machinery for zone and OPTool sessions. Offsets are 2016 offsets (non-PDB
export); member names are `CWMClientSession` **definition 2** of the PDB. The `wm-pdb` export types this class with
definition 1, whose members are shifted by 4 or 8 bytes from `+0x6b8` on, so its member names for e.g.
`CharDataFree` / `ActiveSession` are wrong there (it shows `m_bAttendanceRewardLock`, `m_dwReportTickCount`, … being
reset; the 2016 code does not touch them).

### 4.1 Pool structure (`CWMBaseSessionManager`)

| Offset | Member *(pdb2016)* | Notes |
|---|---|---|
| +0x00 | vftable | slot 0 `ActiveSession`, slot 1 `InactiveSession` (RTTI vftables, below) |
| +0x04 | `m_pSessionListArray` | `WM_SESSION_LIST[m_MaxSessions]`, 12 bytes each: prev, next, `pSession` |
| +0x08 / +0x0c | `m_MaxSessions` / `m_NumSessions` | capacity / sessions in use |
| +0x10 / +0x14 | `m_pActiveSessions` / `m_pEmptySessions` | heads of two doubly linked lists over the same nodes |
| +0x18 | `m_pSessionArray` | the session objects (derived managers) |

| Manager | vftable [0] / [1] | Session class, size | Extra members |
|---|---|---|---|
| `CWMClientSessionManager` (`m_Client`) | FUN_00438a60 / FUN_004380f0 | `CWMClientSession`, 0x1f7b8 | +0x1c `m_NextSendWMTime` (§2.2), +0x20 `m_ClientSeed` (u16, `rand()` at construction), +0x24 `m_SessionGroupByIPArray` (`std::vector<CWMClientSession**>`) |
| `CWMZoneSessionManager` (`m_Zone`) | FUN_00439180 / FUN_00439920 | `CWMZoneSession`, 0x118 | +0x1c `m_MaxZoneSession`, +0x20 `m_ppZoneMappingTable[zoneNo]`, +0x24 / +0x28 indun map list (32 × 0xd), +0x1c8 / +0x1cc service map list (1024 × 0x10), +0x41cc `m_SendWMTime` |
| `CWMOPToolSessionManager` (`m_OPTool`) | FUN_00439180 / FUN_00439080 | `CWMOPToolSession`, 0x118 | – |

`CWMBaseSession` (0x114 bytes, all three session classes): +0x00 `m_Status` (`SESSION_STATUS`: 0 EMPTY, 1 CONNECTED,
2 CONNECTING, 3 CLOSEING, 4 CLOSED; 5 … 0x18 are the CharDB guild-load steps, W03 §9.1), +0x04 `m_Connected_Server_ID`
(peer type: 6 zone, 20 client, …), +0x08 / +0x0c `m_Connected_World` / `m_Connected_Zone`, +0x10 `m_Connected_Time`,
+0x20 `m_LastReceiveTime`, +0x28 `m_SocketIOCP` (socket at +0x28, peer `sockaddr` at +0x2c, i.e. IPv4 at +0x30 =
`GetIPAddress` FUN_00433500), +0xdc `m_Packet`, +0xf4 … +0x108 last two packets (logs), +0x110
`m_LastHeartBeatSendTime`. Zone and OPTool sessions add only +0x114 `m_SessionHandle` (u16); the OPTool manager
constructs its sessions with the zone session's constructor / destructor (identical code).

```pseudo
CWMBaseSessionManager::InitSessions(m, n):                                  @ FUN_004301d0
    FreeSessions(m)                                                          @ FUN_00430100 (delete the node array)
    nodes = new WM_SESSION_LIST[n], chained 0 → n−1 (prev / next); pSession = null (set by the derived manager)
    m_MaxSessions = n; m_NumSessions = 0; m_pEmptySessions = nodes[0]; m_pActiveSessions = null

CWMClientSessionManager::InitSessions(m, n):    (Listen_Client, §1.3)       @ FUN_00437fd0
    base FreeSessions; delete[] the old session array (each ~CWMClientSession)
    if n > 0: base InitSessions(n); new CWMClientSession[n]  (ctor FUN_00434300 each)
        for i: node[i].pSession = &session[i]; session[i].m_SessionHandle = i
               m_ZoneLinking = 1; m_ZoneHandle = 0xFFFF
    return 1
CWMZoneSessionManager::InitSessions(m, n):      (Listen_Zone)                @ FUN_004397d0
    same with CWMZoneSession[n]; also m_ppZoneMappingTable = new ptr[n] (all null); m_MaxZoneSession = n
CWMOPToolSessionManager::InitSessions(m, n):    (Listen_OPTool)              @ FUN_00438f70
    same with 0x118-byte sessions, no mapping table

CWMBaseSessionManager::ActiveSession(m, socket, addr) → node:               @ FUN_004302f0
    if m_NumSessions < m_MaxSessions and m_pEmptySessions:
        node = m_pEmptySessions; s = node.pSession
        s.m_Packet.vtbl[0x2c]()                                              # reset the receive buffer (inferred)
        s.socket = socket; s.addr = addr (16 bytes); s.m_LastReceiveTime = timeGetTime()
        s.m_LastHeartBeatSendTime = 0; s.m_Status = 2 (CONNECTING); s.m_Connected_Time = GetLocalTime()
        EmptyToActive(m, node)                                               @ FUN_00430280
            # unlink from the empty list, push at the head of the active list, m_NumSessions++
            # (node == null: log "* NULL Session List used - CSocket_Session_Manager::CutFromEmpty *", count++ anyway)
        return node
    log "* ACCEPT NO SESSION BUFFER - ERROR *" once (flag DAT_004975f4, re-armed by the next success); return null
    # ProcessConnect (§1.4) then closes the socket

CWMBaseSessionManager::InactiveSession(m, node):                             @ FUN_004303d0
    unlink node from the active list; push it at the head of the empty list; m_NumSessions−−; s.m_Status = 0 (EMPTY)
```

`CWMZoneSessionManager::ActiveSession` FUN_00439180 is only the base call (zone and OPTool share it).

### 4.2 Handles

A session's handle (`m_SessionHandle`, +0x114) is what other links carry to address it (client handle in the DB
requests and in 0x0C14, W01 §1.1; zone handle in `NETPACKETZONEHEADER`). Slot = `handle % m_MaxSessions`, so a handle
is valid only while the slot still holds the same generation:

```pseudo
CWMClientSessionManager::HandleIsValid(m, h) = session[h % max].m_SessionHandle == h          @ FUN_00437830
Clients_GetByHandle(m, h) = that session if the handles match and m_Status == 1, else null   @ FUN_00437860 (W01)

release (InactiveSession of the derived manager):
    slot = h % max; h' = h + max (u16)
    zone / OPTool only: if h' == 0xFFFF: h' = max − 1
    if h' % max != slot: h' = slot                       # u16 wrap: start again at the slot index
    session[slot].m_SessionHandle = h'
```

So every reuse of a slot advances its handle by `max`; answers from the DB servers or zones that arrive for a
closed session find a different handle and are dropped. The client manager lacks the 0xFFFF check the zone and
OPTool managers have: the slot `0xFFFF % max` reaches handle 0xFFFF after enough reuses (e.g. `max` = 1000:
slot 535 after 65 reuses) **(original bug) W05-B8**. 0xFFFF is the "offline" value of the friend and
holy-promise handle arrays (W04 §5, §12), so that player shows as offline to them *(inferred)*.

### 4.3 Client session: construct, take, reset

```pseudo
CWMClientSession::CWMClientSession(s):      (InitSessions, once per slot)    @ FUN_00434300
    CWMBaseSession ctor; PacketEncrypt; m_UserID; avatar array (6 × 0x82, all charNo = −1)
    CFriendServer, CKQ (KQList_Init FUN_0045cfd0), CHolyPromiseServer, CChatRestrictServer (ChatRestrict_Construct)
    m_LogoutType = 0x786 (u32 write: also m_ClientSeed = 0)
    CharDataClear(s)                                                         @ FUN_00430600
        # every blob pointer of W01 §6.3 = null (+0x560 … +0x6e0, +0x1ecf8), m_bCharDataValid = 0,
        # m_CharOptionDataType = 0, spammer ring pointers +0x1ecec / +0x1ecf0 = null, ring index = 0
    the remaining members 0 / −1 (guild, KQ, raid, tutorial, ranking delays; m_myRankingInfo memset)

CWMClientSessionManager::ActiveSession(m, socket, addr):   (vftable[0], ProcessConnect §1.4)   @ FUN_00438a60
    node = base ActiveSession(socket, addr); if null: return null
    m.m_ClientSeed = (m.m_ClientSeed + 1) % pe_encryptlen; s.m_ClientSeed = m.m_ClientSeed   # sent in 0x0807 (W01 §3.2)
    s.m_UserNo = −1
    CharDataFree(s)                                     # the previous user's blobs are freed only here (below)
    s.m_bKQServerTimeSend = 0; s.m_KQ_AutoRefreshActive = 0; s.m_KQ_AutoRefreshTime = 0
    CKQ::Clear(s.m_KQ)                                                       @ FUN_0045cd60  (count 0, list time = now)
    s.m_bGTFighter = 0; s.m_LastGuildTournamentJoinListAckTime = 0; s.m_LastGuildListAckTime = 0
    s.m_nPlayingCharNo = −1; s.m_bFirstJoinSendRestExpLastExecteTimeToClient = 0
    s.m_SessionMode = 0 (BEFORE_NC_USER_LOGINWORLD_REQ)   # W01 "loginStep"
    s.m_dActiveTime = time()                              # W01 "acceptTime"; 2-hour login timeout
    s.m_bClosingSession = 0
    AddClientSessionToIPGroup(m, s)
    s.m_tLastGuildWarAbleListAckTime = 0
    return node
```

Not reset per connection: `m_LogoutType` keeps the previous connection's value (0x786 only on a slot's first use),
so a session that ends without an explicit reason (socket drop, heartbeat timeout, login timeout, service stop:
W05-B2) reports the reason of the slot's previous user to AccountDB 0x0C11, AccountLogDB 0x0722 and CharDB 0x1037
**(original bug) W05-B9**. `m_UserID`, avatars, user type, guild and friend state are overwritten later, at world
login (0x0C0F, W01 §3.2) or character login (0x1001, W01 §4.2). `m_bFirstJoinSend_WMTime_ToClient` is set by the
CharDB character data and cleared by the first 0x0849 (§2.2); if the client drops in between, the next user of the
slot just gets that first 0x0849 too (harmless).

```pseudo
CWMClientSession::CharDataFree(s):                                           @ FUN_00434530
    s.m_bCharDataValid = 0
    free + null every character blob with its size (W01 §6.3 table): +0x560 base … +0x590 abstate, skills[6] +0x598,
        +0x5c8 … +0x5f8, inventories[3] +0x600, +0x618 … +0x630, +0x640 … +0x6b8 (CT, KQ map, charged buff, single
        option, link-from, item cool-time, the 7 binary + 3 improved option blobs)
    SpammerReportingTimeInfoInit(s)                                          @ FUN_00432a70
        n = SR_Number (SpamerReport row 0, W04 §2.5); malloc u32[n] for +0x1ecec / +0x1ecf0 when still null (once per
        slot, never freed); reportTime[i] = 0, reporterCharNo[i] = −1, ring index +0x1ecf4 = 0; malloc failure → 0
    free +0x1ecf8 newbie-guide view list (0x10D8 blob); m_CharGamblePrevMap (+0x1ed04, Name3) = ""
    free +0x6c0 coin, +0x6c8 / +0x6d0 / +0x6d8 card collection, +0x6e0 sell-item info
    s.m_bZoneLink_DataValid (+0x1dfa0) = 0
```

Callers: `ActiveSession` (new connection), `fc_NC_CHAR_LOGIN_REQ` 0x1001 (W01 §4.2, before 0x1004 asks the CharDB
for the new character) and the destructor. Neither logout nor disconnect frees the blobs: after a disconnect they
stay allocated in the empty slot until it is reused or the process stops.

### 4.4 Pending-login groups per IP

`m_SessionGroupByIPArray` holds one `CWMClientSession*[10]` per IP that has sessions which have not yet sent the world
login (log text: "array of session which is not certified yet").

```pseudo
CWMClientSessionManager::AddClientSessionToIPGroup(m, s):  (ActiveSession)   @ FUN_00438810
    group = the entry whose first session has s's IP
    if none: group = new ptr[10] = { s, 0 … } and append it    (alloc failure: log "Cannot memory allocation for
             array of session which is not certified yet."; s stays ungrouped); return
    put s into the first free slot of group
    if that was slot 9 (10 sessions):            # a group never stays full, so the 'no free slot' case cannot occur
        every session in group: m_bClosingSession = 1 (also s); remove the group from the vector (the 40-byte
        pointer array itself is not freed: a small leak per flood)
    # ProcessDisconnect then closes them all with "Invalid Client Session - NumberOfSessionOver(%d) …" (W01 §2)

Clients_RemoveFromIpTable = RemoveClientSessionFromIPGroup(m, s) → bool:     @ FUN_004386e0
    group = the entry whose first session has s's IP; find s in its 10 slots (else return 0)
    shift the later slots left; slot 9 = 0
    if the group is now empty: delete it, remove it from the vector
    return 1
```

Callers of the removal: `CParserClient::Parser` FUN_00419690 when 0x0C0F moves the session to mode 1 (W01 §3.2), and
`ProcessDisconnect` for every closed session (a no-op for sessions already removed). So at most 9 connections from
one IP can wait for their world login at the same time; the 10th closes all of them (anti-flood; a NAT gateway
with many simultaneous connects is affected too). The group lookup compares only the IP of the group's first session.

### 4.5 Release: which event closes a client session

Every client close path ends in the same two steps: something sets `m_Status = 3` (CLOSEING), and the next
`ProcessDisconnect` pass (§1.5, W01 §2) does the teardown.

| Event | Who sets state 3 | `m_LogoutType` set |
|---|---|---|
| socket closed / reset by the client, receive error | `Pump` r == 2 (§1.4) | – (stale, W05-B9) |
| no packet for 30 s + 180 s | `ProcHeartBeat` → `CSocket_IOCP::CloseUseIOCP` FUN_00466120 (posts a zero-byte completion for the socket, the IOCP side then closes it, *inferred*) → as above | – |
| first packet is not 0x0C0F, or a packet in mode −1 | `CParserClient::Parser` FUN_00419690 (W01 §3.2) | – |
| a handler returns 0, incl. every unregistered opcode | `CParserClient::Parser`; `fc_dummyfunction` FUN_00412be0 logs "fc_dummyfunction, CLIENT, dep=%d, cmd=%d, length=%d …" + the previous packet and returns 0 | 0x781 (dummy only) |
| login not completed within 7200 s | `ProcessDisconnect` (W01 §2) | – |
| 10 pending sessions from one IP | `ProcessDisconnect` via `m_bClosingSession` (§4.4) | – |
| quit (0x0C18 mode 0) | W01 §5.1 | 0x780 |
| same account logs in again (0x0C0F) | `Kickoff(s, userNo)` FUN_00437dc0 (W01 §3.2): 0x0C17 {0x683} to the old session, log "CLIENT DOUBLE CONNECT CLOSE2" | 0x785 |
| Login kicks the user (Login 0x0C16) | `Kickoff(userNo)` FUN_00437d50: every session with that `m_UserNo` gets 0x0C17 {0x683}; log "CLIENT DOUBLE CONNECT CLOSE1, nUserNo=%d"; returns 1 if any | 0x785 |
| OPTool kick | W04 §4 / W01 §9 | 0x790 |
| world-login refused, DB error | W01 §3.2 / §3.3 | 0x788 |
| service stop / lost AccountDB / CharDB | `SetLogoutType` FUN_00437d20 then `DissconnectAllSessions` (§1.2, §1.6) | 0x782 / 0x789 / 0x78b |

W01 §5.2 marks the Login-kick path *inferred*; the code above confirms it. W01-core §1 says unregistered opcodes
"are ignored"; on the client link they close the session (above). The server links' `fc_dummyfunction`s return 1
(AccountDB, GameLogDB, Login, OPTool, zone), 0 (AccountLogDB) or 0 from the 11th call on (CharDB, `DummyCount`);
what a 0 does on those links is part 4 (W01 core gaps).

```pseudo
ProcessDisconnect, client part (after the links, W01 §2):                    @ FUN_00404e70
    for each node of m_Client's active list:
        s = node.pSession
        if s.m_SessionMode == 0 and time() − s.m_dActiveTime > 7200: log "… TimeOver …"; s.m_Status = 3
        if s.m_bClosingSession == 1: log "… NumberOfSessionOver …"; → close
        elif s.m_Status == 3: → close
      close:
        s.m_SessionMode = −1 (INACTIVE_MODE)            # further packets are rejected by the parser
        RemoveClientSessionFromIPGroup(m_Client, s)
        CWMClientSession::Close(s) = Client_OnClosed (W01 §2) @ FUN_00437030
            # CharacterLogout, AccountDB 0x0C11, AccountLogDB 0x0722 / 0xC803, zones 0x0C19, then Session_Close
        m_Client.vftable[1](node) = CWMClientSessionManager::InactiveSession       @ FUN_004380f0
            new handle (§4.2); s.m_ZoneLinking = 1; s.m_ZoneHandle = 0xFFFF; s.m_bCharDataValid = 0
            base InactiveSession (to the empty list, m_Status = 0)
        log "Closed CL from (%-25s world=%3d …)"

Session_Close = CWMBaseSession::Close(s):                                    @ FUN_0042fc30
    CSocket_IOCP::Shutdown(s.socket)                                         @ FUN_00466060
        shutdown(sock, SD_SEND); on error other than WSAECONNRESET (10054, both codes): log
        "ERROR - CSocket_IOCP::Shutdown : ret(%d), GetLastError(%d), WsaError(%d)"
    CSocket_IOCP::Close(s.socket)                                            @ FUN_00466180
        if sock != −1: closesocket; success → sock = −1, else log "ERROR - CSocket_IOCP::Close : …" (sock kept)
        under the socket's lock: FreeBuffer; two counters at socket +0xa8 / +0xac = 0
```

`CParserCharDB::fc_NC_USER_AVATARINFO_ACK` FUN_0040ede0 on a DB error (W01 §3.3: 0x0C15 {0x46}, 0x788) calls
`CWMClientSession::Close` directly without setting state 3. The session stays in the active list with a closed
socket; when the network layer reports the dead socket (`Pump` r == 2 *inferred*) `ProcessDisconnect` runs
`Client_OnClosed` a second time, so AccountDB 0x0C11, AccountLogDB 0x0722 / 0xC803 and the zone 0x0C19 go out twice
for this user **(original bug) W05-B10** *(inferred: the second pass depends on how the IOCP layer reports a socket
the WM closed itself)*.

Zone and OPTool sessions are closed the same way in `ProcessDisconnect` (state 3 → `CWMBaseSession::Close` →
vftable[1]), without logout reports:

```pseudo
CWMZoneSessionManager::InactiveSession(m, node):                             @ FUN_00439920
    z = node.pSession
    if m_ppZoneMappingTable[z.m_Connected_Zone] == z and z.m_Connected_Server_ID == 6:
        if another active zone session has the same zone number: mapping[zoneNo] = it   # a second link of that zone
        else mapping[zoneNo] = null
    new handle (§4.2, with the 0xFFFF guard); base InactiveSession
CWMOPToolSessionManager::InactiveSession(m, node):                           @ FUN_00439080
    new handle; base InactiveSession
```

The zone's service-map entries (`SetServiceMapZoneNo`, W01 §7.1) are not touched on release; only the zone-number →
session mapping is. A character login for a map of a lost zone then finds no session for that zone number and is
refused with 0x145 "map under maintenance" (W01 §4.2) *(inferred from the two tables; the lookup itself is part 4)*.

### 4.6 Destroy (process stop and exit)

```pseudo
ProcessStop (§1.6) → CWMClientSessionManager::DissconnectAllSessions (Client_OnClosed for every active session,
                     W01 §2) → CWMClientSessionManager::FreeSessions(m)       @ FUN_00437660
    base FreeSessions (node array); delete[] the session array → ~CWMClientSession for every slot
    # zone / OPTool: DissconnectAllSessions (Close) + FreeSessions FUN_00439120 (also the mapping table) / FUN_00438e90

CWMClientSession::~CWMClientSession(s):                                      @ FUN_004352e0
    CharDataFree(s)                     # re-runs SpammerReportingTimeInfoInit: the two ring arrays are never freed
    ChatRestrict_Destroy(+0x1e290)      (W04 §14.1)        HPInfo_Destruct(+0x1dfb0) FUN_0045d470 (W04 §12)
    KQList_Destroy(+0x2594) FUN_0045cf90 (W04 §6)          ~CFriendServer(+0x708) FUN_0045c920 (count 0, 100 entries)
    avatar array (6 × 0x82); ~CWMBaseSession FUN_0042fbc0 (~CPacket, ~CSocket_IOCP)
```

At process exit the global `gServer` is destroyed by `~WorldManagerServer` FUN_00403920: members in reverse
construction order (ranking, gamble, class data, single data, GM events, quest timer, attendance, NPC schedule, the
`CDataReader` tables, guild manager, 500 `Raid`s, KQ server, party finder, party, `m_MsgWM`, then each parser's
`PROTOCOLFUNCTIONTEMPLETE` and session manager: OPTool, zone `~CWMZoneSessionManager` FUN_004396f0, client
`~CWMClientSessionManager` FUN_00438630 (= `FreeSessions` + delete the IP-group vector storage), login, the DB
links). The session arrays are normally already gone (`ProcessStop`), so these destructors find null pointers.

### 4.7 Newbie-guide list on the first map login (0x10D9)

```pseudo
CWMClientSession::NewbieGuideViewListRefresh(s):  (zone 0x180C map login done, W01 §7.3)   @ FUN_00432ce0
    if s.m_pCharDataNewbieGuideViewList (+0x1ecf8, CharDB 0x10D8 blob, W01 §6.3) == null: return
    n = blob[0]
    Send client 0x10D9 NC_CHAR_CLIENT_NEWBIE_GUIDE_VIEW_LIST_CMD { u8 nGuideViewNum = n, u8 nGuideViewList[n] }
         (n + 1 bytes copied from the blob)
    sent: free the blob (so only the first map login of a character sends it; 0x10DA updates go to the CharDB only,
          W01 §5.3)
    send failed: log "ERROR - CWMClientSession::ChatBlockSpamFilterRefresh, nCharNo=%d" (wrong function name in the
          text (original bug) W05-B11); the blob is kept and resent on the next map login
```

Client GameFrameWork FUN_004ba310: clears its 197-entry "guide already seen" table (all −1), sets entry `id` for every
listed `id < 0xC5` (larger ids are ignored), marks the list as received and, when the guide option is on, refreshes
the guide window (FUN_00493040). Struct `PROTO_NC_CHAR_NEWBIE_GUIDE_VIEW_LIST_CMD { uchar nGuideViewNum; uchar
nGuideViewList[] }` *(pdb2017)* matches the 2016 send. Layout: `annotations/W05.json`.

---

<!-- Part 4 adds §5 W01 core gaps; the sweep part adds the bug table,
     "Not reconstructed / uncertain" and "Coverage boundary". -->

## Original-server bugs (so far; completed in the sweep part)

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W05-B1 | `MainThread` FUN_00407340 | sleeps 5 ms per pass only while the CharDB link is in state 1 | one CPU core at 100 % during start-up, the guild data load and while the CharDB is lost | sleep on every pass (or wait on events) |
| W05-B2 | `OnStop_Service` FUN_00406d40 | sets `m_MainWorkStep = CLOSE_NORMAL` and `m_bStopMainThread = 1` together | the main thread exits before `MainWork` applies `SetLogoutType(0x782)`; logout reports of a service stop carry stale close reasons (the session's last explicit reason, or the previous slot user's, W05-B9) | set only the step and let `MainWork` stop the thread |
| W05-B3 | `CDailyQuestTimer` ctor FUN_00439f10 | December start: next month = February (month index 1) of next year | none (the year branch fires on 1 January and sets the month too) | month index 0 |
| W05-B4 | `DQ_Schedule_Process` FUN_0043a120 | `tInitYear/Month/WeekQuest` are computed once at start and never advanced | after the first boundary each daily run recomputes year / month / week again; same values | advance the end times when a period rolls over |
| W05-B5 | `CGuildTournamentServer::ReadScheduleData` FUN_0043d270 | with no `isActive == 1` row the loop leaves the last row selected and returns success | a table with every schedule disabled still runs the tournament on the last row's schedule | fail the load (or run no tournament) when no row is active |
| W05-B6 | `CDataReader::Read` FUN_00458ca0 | byte checksum and MD5 run over `m_nBFSize` (buffer capacity), not `m_nFileSize` | none in the WM (each reader is filled once); a re-read of a smaller file into the same reader would hash stale bytes | hash `m_nFileSize` bytes |
| W05-B7 | `ReadGlobalGameData` FUN_00404100 | every `*FATAL ERROR* … %s` text is passed to `_DEBUGMSG` without an argument for `%s` | on a failed load the log line prints a random stack pointer as a string or faults while logging | pass the file name |
| W05-B8 | `CWMClientSessionManager::InactiveSession` FUN_004380f0 | new handle = old + max without the `== 0xFFFF` guard the zone / OPTool managers have | slot `0xFFFF % max` eventually gets handle 0xFFFF, the "offline" marker of friend / holy-promise handle arrays; that player shows offline *(inferred)* | skip 0xFFFF as the other managers do |
| W05-B9 | `CWMClientSessionManager::ActiveSession` FUN_00438a60 | `m_LogoutType` is set to 0x786 only by the constructor, never per connection | a session closed without an explicit reason (socket drop, heartbeat, login timeout, service stop) reports the previous slot user's reason to AccountDB 0x0C11, AccountLogDB 0x0722 and CharDB 0x1037 | reset `m_LogoutType` to 0x786 in `ActiveSession` |
| W05-B10 | CharDB 0x0C13 `fc_NC_USER_AVATARINFO_ACK` FUN_0040ede0 | DB-error path calls `CWMClientSession::Close` directly instead of setting state 3 | `Client_OnClosed` runs again when `ProcessDisconnect` sees the dead socket: duplicate 0x0C11 / 0x0722 / 0xC803 / 0x0C19 *(inferred)* | set `m_Status = 3` and let `ProcessDisconnect` close |
| W05-B11 | `NewbieGuideViewListRefresh` FUN_00432ce0 | failure log names `CWMClientSession::ChatBlockSpamFilterRefresh` | misleading log line | log its own name |
