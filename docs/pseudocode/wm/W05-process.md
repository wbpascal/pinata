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
        s.m_LastHeartBeatSendTime = now
        return CSocket_IOCP::Send(s, 0x0804 NC_MISC_HEARTBEAT_REQ {})   # 3 raw bytes 02 04 08; a failed send
                                                                        # = fail: the peer is closed at once
    elif now − s.m_LastHeartBeatSendTime ≥ 180000:
        log "ERROR - HEARTBEAT OVERTIME, NOW DISSCONNECT WITH %s"; return fail
    return ok
```

So a peer (DB server, Login, zone, OPTool or client) that sends nothing for 30 s gets one `0x0804`; if nothing at all
arrives in the next 180 s, the WM closes it. A fail result makes `ProcHeartBeat` FUN_00430160 call
`CSocket_IOCP::CloseUseIOCP` on that peer, so a peer whose 0x0804 cannot be sent is closed right away. Any received packet resets the timer (`m_LastReceiveTime`, network
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
    # (original bug) W05-B2: m_bStopMainThread is set right after the step, with no hand-shake. MainThread
    # (FUN_00407340) checks the flag only after MainWork: a stop that lands before MainWork runs (e.g. during
    # the Sleep(5) of CharDB state 1, most of a normal pass) still runs the CLOSE_NORMAL case once and applies
    # SetLogoutType(0x782); a stop that lands while MainWork is running ends the loop without it, and the
    # logout reports (AccountDB 0x0C11 / AccountLog 0x0722) then carry each session's current m_LogoutType

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
    Send to every client session with m_bCharDataValid (+0x704) == 1:  # BroadCastToPlayer(&m_Client, pkt, 0)
        # +0x704 = W01's "inGame": set when the character data is complete (0x1005), cleared by
        # CWMClientSession::Logout FUN_00436d50 and on release; the receiver may still be loading a map
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
reference point. FUN_0057d8f0 shows the clock: copies `dCurrentTM`, adds the elapsed seconds to `tm_sec` only (no `mktime`
normalisation), then `strftime("%H:%M")`, which ignores `tm_sec`: the clock shows the HH:MM of the last 0x0849
and moves only when the next one arrives (hence the server's full-minute alignment, *inferred*). Then
`" {color,yellow,GMT(+%d)}"` (or `"GMT(-%d)"` with the already negative value, so a negative zone shows as
`GMT(--5)`; client-side). When the cursor is over the clock (vfunc +0x14c hit test) a tooltip shows
`strftime("%Y-%m-%d (%a)")` of the same `dCurrentTM`. No error codes.

### 2.3 Quest reset times (`CDailyQuestTimer`, 0x441C / 0x441D)

`gServer.m_DailyQuestTimer` (+0x22b440, DAT_006c5468): `m_ResetTime { tResetYearQuest, tResetMonthQuest,
tResetWeekQuest, tResetDayQuest }` (start of the current period, time_t) and `m_InitTime { tInitYearQuest,
tInitMonthQuest, tInitWeekQuest, tInitDayQuest }` (when the period ends). Weeks start on **Monday 00:00** local time.

```pseudo
helpers (all local time, via localtime + mktime):                     @ FUN_00439a00 … FUN_00439c80
    GetToday      FUN_00439a00  today 00:00                 GetTodayEnd     FUN_00439c00  today 00:00 + 86400
    GetThisWeek   FUN_00439a80  Monday 00:00 of this week   GetThisWeekEnd  FUN_00439c80  next Monday 00:00
    GetThisMonth  FUN_00439b20  1st of this month 00:00     GetThisYear     FUN_00439b90  1 January 00:00

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
        if !ok: _DEBUGMSG("*FATAL ERROR* - <text> READ FAILED %s", path); return 0
            # the path is pushed as the %s argument (disassembly at 0x40411b: push path, push format,
            # call _DEBUGMSG, add esp,8); the export drops _DEBUGMSG's varargs. The two Attend texts have no %s
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
so a session that ends without an explicit reason (socket drop, heartbeat timeout, login timeout, service stop
when W05-B2 hits, 0x0C18 from character select) reports the reason of the slot's previous user to AccountDB 0x0C11, AccountLogDB 0x0722 and CharDB 0x1037
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
| any client packet on a session whose `m_Status` ≠ 1 (e.g. after a quit set state 3) | `CParserClient::CheckConnectionValidation` FUN_00412b20 (called first by every client handler): logs "ERROR … CLIENT …", returns 0 → parser closes | 0x787 |
| quit (0x0C18 mode 0) | `fc_NC_USER_NORMALLOGOUT_CMD` FUN_00412df0 (W01 §5.1): broadcasts 0x0C19 {userNo, 0xFFFFFFFF} to the zones, `Logout` FUN_00436d50, `m_Status = 3`; `Client_OnClosed` then broadcasts 0x0C19 **again** and calls `Logout` again (no-op: its +0x704 guard is cleared; only the unconditional tail, KQ / guild fields and `CPrisonServer::LogOutPrison`, repeats) **(original bug) W05-B25** | 0x780 |
| 0x0C18 sent while `m_pCharDataBase == null` (quit from the character-select screen) | handler returns 0 → parser closes | – (stale, W05-B9) |
| return to character select (0x0C18 mode 1) | nobody: the session stays open. `Logout` only (party / friend / KQ / guild / prison logoff, CharDB 0x1037); `m_ZoneLinking = 1`, `m_ZoneHandle = 0xFFFF`; blobs stay until `CharDataFree` at the next 0x1001 (§4.3) | 0x780 (kept: a later socket drop reports a normal logout) |
| same account logs in again (0x0C0F) | `Kickoff(s, userNo)` FUN_00437dc0 (W01 §3.2): 0x0C17 {0x683} to the old session, log "CLIENT DOUBLE CONNECT CLOSE2" | 0x785 |
| Login kicks the user (Login 0x0C16) | `Kickoff(userNo)` FUN_00437d50: every session with that `m_UserNo` gets 0x0C17 {0x683}; log "CLIENT DOUBLE CONNECT CLOSE1, nUserNo=%d"; returns 1 if any | 0x785 |
| OPTool kick | W04 §4 / W01 §9 | 0x790 |
| world-login refused, DB error | W01 §3.2 / §3.3 | 0x788 |
| service stop / lost AccountDB / CharDB | `SetLogoutType` FUN_00437d20 then `DissconnectAllSessions` (§1.2, §1.6) | 0x782 / 0x789 / 0x78b |

W01 §5.2 marks the Login-kick path *inferred*; the code above confirms it. W01-core §1 says unregistered opcodes
"are ignored"; on the client link they close the session (above). The server links' `fc_dummyfunction`s return 1
(AccountDB, GameLogDB, Login, OPTool, zone), 0 (AccountLogDB) or 0 from the 11th call on (CharDB, `DummyCount`);
a 0 closes the link (§5.1).

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
refused with 0x145 "map under maintenance" (W01 §4.2) (lookup confirmed in §5.8).

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

## 5. W01 core gaps

What `coverage.py W01 --all` lists as unreached core code: the packet pump's handler-return rule, the zone
registration chain, the world-login entry copy, the per-opcode blob handlers W01 §6.3 / §7.4 describe only as a
table, the ping-test relay, and the small accessors the W01 handlers call. Feature code reached from the same
handlers (raid, KQ, friends, attendance, holy promise, chat restriction) is in W02–W04; §5.8 lists where.

### 5.1 Handler return value and `fc_dummyfunction` (corrects W01 §1)

Every parser runs one handler per packet (§1.4 `Pump`). The handler gets `(session, packet, len)`: `packet` points
at the opcode, the payload starts at `packet + 2`, and `len` is `CPacket::GetDataSize` FUN_004678c0 (vtable slot 5
of the session's `m_Packet` at +0xdc), the frame length byte = **2 + payload length** (README §1.1). A handler
returning 0 closes the link or session.

```pseudo
CParserZone::Parser(this, s):                                                    @ FUN_0042d4c0
    s.prevOpcode/prevLen/prevState (+0x100/+0x104/+0x108) = s.lastOpcode/lastLen/handlerState (+0xf4/+0xf8/+0xfc)
    s.lastOpcode = *m_Packet.GetIDPtr(); s.lastLen = m_Packet.GetDataSize(); s.handlerState = 1
    r = pft_funcpnt[cmd][dept](s, packet, len)
    r == 0: s.handlerState = 3; log "FAILED - ZONE Parser's unknowned packer"; s.state = 3     # zone link closed
    else:   s.handlerState = 2
CParserOPTool::Parser                                                            @ FUN_00424400
    the same without the log. The linker folded the identical CParserAccountDB / AccountLogDB / CharDB / GameLogDB
    / Login parsers into this one function: ProcessPacket (§1.4) calls FUN_00424400 for all five outgoing links.
CParserClient::Parser: W01 §3.2 (FUN_00419690).
```

`fc_dummyfunction` (unregistered opcode) logs `fc_dummyfunction, <PEER>, dep=%d, cmd=%d, length=%d, …` and the
previous packet (`pre packet, <PEER>, …, WT=%d`), then returns:

| Parser | `fc_dummyfunction` | Returns | Effect of an unknown opcode |
|---|---|---|---|
| AccountDB | FUN_00407bf0 | 1 | ignored |
| AccountLogDB | FUN_00408ca0 | **0** | link state 3: closed, reconnected by `ProcessConnect` (§1.4) |
| CharDB | FUN_00409ae0 | 1 while `++DummyCount < 11`, then 0 | from the 11th unknown CharDB packet of the process lifetime on, each one closes the CharDB link → `CLOSE_CHAR_DB` (§1.5). `DummyCount` is never reset (original bug) W05-B14 |
| GameLogDB | FUN_00424000 | 1 | ignored |
| Login | FUN_004245c0 | 1 | ignored |
| OPTool | FUN_00424d20 | 1 | ignored |
| Zone | FUN_004282e0 | 1 | ignored |
| Client | FUN_00412be0 | 0 (+ `m_LogoutType` 0x781) | session closed (§4.5) |

W01 §1 ("unregistered opcodes … are ignored") holds only for AccountDB, GameLogDB, Login, OPTool and zone links.

### 5.2 Zone registration 0x0802 (completes W01 §7.1)

```pseudo
0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo_data, u8 server_to_id, u8 server_from_id, u8 server_from_world_num,
                                   u8 server_from_zone_num, u16 key }   (PROTO size 7, pdb2016)   @ FUN_004283e0
    if server_to_id != gServer.m_MyServer.nServerID (+0x500, = 5 from WMServerInfo.txt MY_SERVER):
        log "접속요청한 서버의 타입과 나의 타입이 맞지 않음, 바로 접속을 끊음 - IP=%s:%d, SOCKET=%d (아래정보참고)"
            ("type of the requesting server does not match mine, disconnecting")
            + "NC_MISC_S2SCONNECTION_REQ <server_from id=%d w=%d z=%d, server_id_to=%d, key=%d, my_type=%d>"
        return 0                                                   # → zone Parser: state 3 (§5.1)
    if server_to_id + server_from_id != key:
        log "접속요청한 곧에서 잘못된 키값이 왔음, …" ("wrong key value") + "NC_MISC_S2SCONNECTION_REQ <server_id_from=%d,
            server_id_to=%d, key=%d, my_type=%d>"; return 0
    s.m_Connected_Server_ID (+4) = server_from_id
    ip = inet_ntoa(s.addr); port = ntohs(s.port)
    row = CServerInfo::GetServerInfo(&gServer.m_ServerInfo, out, nServerID 6, gServer.nWorldNo, server_from_zone_num,
                                     nServerIDFrom 6)                                       @ FUN_00465ef0
        # the payload's world byte is NOT used for the lookup and not compared (original bug) W05-B13
    no row: log "ERROR - 접속해온 WolrdNo=%d, ZoneNo=%d, IP=%s 정보 없음" ("no info for the connecting world/zone")
            with world (+5), zone (+6), ip (sprintf at 0x4285f3; the export drops the varargs); return 0
    if _mbsicmp(row.pIP, ip) != 0:                                 # case-insensitive string compare, no DNS
        log "ERROR - 대기중인 WorldNo=%d, ZoneNo=%d IP=%s, 접속해온 WorldNo=%d, ZoneNo=%d IP=%s 다름" ("expected … differs"); return 0
    newZone = (CWMZoneSessionManager::GetZoneSession(zone) == null)
    s.world (+8) = server_from_world_num; s.zone (+0xc) = server_from_zone_num; GetLocalTime(&s.connectTime +0x10)
    CWMZoneSessionManager::SetZoneSession(&gServer.m_Zone, zone, s)                        @ FUN_00439190
        if zone < m_MaxZoneSession: m_ppZoneMappingTable[zone] = s      # a reconnect replaces the old mapping
    s.state = 1
    log "Connected from (%-25s world=%3d zone=%3d, %- 5d=%15s:%- 5d) %4d/%4d개" with GetShineServerIDName(from)  @ FUN_0045a040
        (gpShineServerIDNames[id], id outside 0..20 → entry 10)
    Send 0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo_data, u16 error = 0 }   (size 3)
    CWMZoneSessionManager::SendWMTimeToZone(force 1)               # 0x0821, W01 §2
    if newZone: CNpcScheduleServer::enss_NPCStandState(zone)       # 0x086A per standing NPC, W04 §17.6 (W01's FUN_00457110)
    GMEventManager::GMEM_SendAllEventInfo(zone)                    # W04
    return Send result
```

The row the IP is checked against is the **zone's own row for zone-type peers** (`SERVER_INFO "PG_W00_Z<nn>", 6,
<world>, <zone>, 6, ip, port, …`). In the shipped `9Data/ServerInfo/ServerInfo.txt` those rows carry `"0.0.0.0"`, which
never equals a peer address: with that file every zone registration would fail (see §5.9 uncertain).

`CServerInfo` (`m_ServerInfo`, gServer +0) wraps a `CCsl` script (the parsed `WMServerInfo.txt` + included
`ServerInfo.txt`; `m_Csl`). Rows are `CSL_DATA_LIST { dwID = format index, pData, pNext }`; the format index is the
`#DEFINE` order across both files: 0 `MY_SERVER`, 1 `NATION_NAME`, 2 `WORLD_NAME`, **3 `SERVER_INFO`**, 4 `ODBC_INFO`.

```pseudo
CServerInfo::GetServerIndex(type, world, zone, from):             @ FUN_00465e10
    for i in 0 .. CCsl::GetNumDatas() - 1:                         @ FUN_00460b40 (m_NumDatas)
        if CCsl::GetDataInfo(i).dwID == 3 and columns 1..4 == (type, world, zone, from): return i     # first match
    return -1
CServerInfo::GetServerInfo(out, i):                                @ FUN_00465d60
    if GetDataInfo(i).dwID != 3: return 0                         # no null check: only called with a valid i
    out = { pName = col 0, nServerID 1, nWorldNo 2, nZoneNo 3, nServerIDFrom 4, pIP 5, nPort 6, nBackLog 7, nMaxAccept 8 }
    return 1                                                       # SERVER_INFO definition 1 (0x24 bytes), pdb2016
CServerInfo::GetServerInfo(out, type, world, zone, from) = GetServerIndex → GetServerInfo(out, i), 0 if -1   @ FUN_00465ef0
CCsl::GetDataInfo(i):  i ≥ m_NumDatas → null; m_ppDataTable[i] if the index table exists, else walk m_pDatas   @ FUN_00460b50
CCsl::GetData(i, col): row as above; null if i or col out of range (col < format.NumParameter); returns
    pData + Σ m_pCslParameterSize[type of columns 0..col-1]  (strings are stored as pointers)                  @ FUN_00460ba0
CCsl::GetFormat(id): same pattern over the format list                                                        @ FUN_00460af0
CCsl::AddFormat: append to the list, m_NumFormats++ (so a format's id = its #DEFINE order)                   @ FUN_00461150
```

The script parser itself (`CCsl::Read` / `ReadScript` / `ProcCmd` / `IncludeFile`, FUN_00461730 … FUN_004626f0) is
called only from `ReadDefineScriptor` (W01 §2) and is not documented here (§5.9).

### 5.3 World-login entry (0x0C0D / 0x0C0F helpers; corrects W01 §3.1)

```pseudo
PROTO_NC_USER_WILLLOGIN_REQ::operator=(dst, src):   (copy into the pending table, W01 §3.1)            @ FUN_00412d50
    dst.netpacketheader.clienthandle (u16 @0) = src…; willlogin_worldno (u8 @2); usrregnum (u32 @3)
    Name256Byte::operator=(dst.userid @7, src.userid)
    validate_new[32] (u16 @0x107) copied word by word
    spawnapps (Name5, 20 bytes @0x147)       # W01's "u32 extra[5]": forwarded to CharDB in 0x1036 (m_UserSwpawnApps)
Name256Byte::Name256Byte(): zero all 256 bytes (64 dwords)          @ FUN_004129f0   (0x0C0F local copy of the user id)
```

`PROTO_NC_USER_WILLLOGIN_REQ` is 0x15B bytes and `PROTO_NC_USER_WILLLOGIN_ACK` = that + `u8 ok` *(pdb2016)*; W05
annotations re-label the 0x0C0D fields with these names. Other struct copies the W01 handlers use:
`PROTO_AVATARINFORMATION::operator=` FUN_00409db0 (CharDB 0x1405 new avatar: chrregnum, name, level, slot, loginmap,
delinfo, shape, equip, nKQHandle, sKQMapName, nKQCoord, dKQDate, CharIDChangeData, TutorialInfo, i.e. the 0x82-byte
AVATAR of W01 §6.1), `PROTO_NC_AVATAR_CREATE_REQ::operator=` FUN_00412f60 (client 0x1401: slotnum, name, char_shape),
`Name3::Name3(char*)` FUN_00402090 / `Name3::operator=(char*)` FUN_00409770 (zero 12 bytes, `strncpy` ≤ 12: map
names; 0x1001 / 0x101C, and `"RouT00"` for a tutorial character at CharDB 0x1005, W01 §4.2).

### 5.4 Character blob cache: CharDB pushes (W01 §6.3 per handler)

All pass `CharDB_CheckAlive` (returns 0 → link closed, §5.1), find the session with `Clients_GetByHandle(u16 @
payload+0)` and do nothing when it is gone (return 1). Generic store `Session_StoreBlob(src, n, &ptr, &size)`
FUN_00430780: keep the buffer if `size == n`, else free it and `new[n]`; then `memcpy`. The CharDB handlers call it
with `src = payload + 2`, `n = len − 2` = payload length, so every blob holds the payload after the handle **plus
the 2 bytes that follow the packet in the receive buffer** (original bug) W05-B15 *(inferred from `len` = 2 +
payload, §5.1)*. Session offsets are the W01 §6.3 slots; names are the PDB `m_pCharData…` members.

| Op | Handler *(pdb2016 name `fc_…`)* | FUN | Stores |
|---|---|---|---|
| 0x1007 | NC_CHAR_BASE_CMD | FUN_0040a1d0 | +0x560 `m_pCharDataBase` (PROTO_NC_CHAR_BASE_CMD 0x69: chrregnum, charid, slotno, Level, Experience, stones, HP/SP/LP, fame, Cen, logininfo, statdistribute, pk, prisonmin, adminlevel, flags) |
| 0x1008 | NC_CHAR_SHAPE_CMD | FUN_0040a230 | +0x568 |
| 0x100A | NC_CHAR_QUEST_DOING_CMD | FUN_0040a290 | +0x570 (chrregnum, bNeedClear, nNumOfDoingQuest, PLAYER_QUEST_INFO[]) |
| 0x100B | NC_CHAR_QUEST_DONE_CMD | FUN_0040a2f0 | `CharDataStore` (quest done) FUN_00433210, below |
| 0x10CC | NC_CHAR_QUEST_READ_CMD | FUN_0040a340 | +0x580 |
| 0x10D5 | NC_CHAR_QUEST_REPEAT_CMD | FUN_0040a3a0 | +0x588 |
| 0x100C | NC_CHAR_ABSTATE_CMD | FUN_0040a400 | +0x590 (chrregnum, u16 number, ABSTATEREADBLOCK[]) |
| 0x100D | NC_CHAR_SKILL_CMD | FUN_0040a460 | `CharDataStore` (skill) FUN_004307d0, below |
| 0x100E | NC_CHAR_SKILL_PASSIVE_CMD | FUN_0040a4b0 | +0x5c8 |
| 0x100F | NC_CHAR_HOUSE_CMD | FUN_0040a510 | +0x5d0 |
| 0x1011 | NC_CHAR_MASPUP_CMD | FUN_0040a6a0 | +0x5d8 |
| 0x1013 | NC_CHAR_EMBLEM_CMD | FUN_0040a780 | +0x5e0 |
| 0x1014 | NC_CHAR_PET_CMD | FUN_0040a7e0 | +0x5e8 |
| 0x1015 | NC_CHAR_ARENA_CMD | FUN_0040a840 | +0x5f0 |
| 0x1016 | NC_CHAR_SEAWAR_CMD | FUN_0040a8a0 | +0x5f8 |
| 0x1017 | NC_CHAR_ITEM_CMD | FUN_0040a900 | `CharDataStore` (items) FUN_00430870, below |
| 0x1018 | NC_CHAR_CHESTINFO_CMD | FUN_0040a950 | +0x630 |
| 0x1019 | NC_CHAR_CHARTITLE_CMD | FUN_0040a9b0 | +0x640 |
| 0x101A | NC_CHAR_KQMAP_CMD | FUN_0040aa10 | +0x648 (saved KQ return position, used by 0x1005, W01 §4.2) |
| 0x101B | NC_CHAR_CHARGEDBUFF_CMD | FUN_0040aa70 | +0x650 |
| 0x10D2 | NC_CHAR_SINGLE_OPTION_CMD (W01: "FREESTAT_SET_DB_ACK") | FUN_0040aad0 | +0x658 (PROTO_NC_CHAR_SINGLE_OPTION_CMD 0xf: chrregnum, resttime, autopick, mystery_vault, nChatBan, bFirstJoin); then **sets blob byte +0xe `bFirstJoin` = 1** (zones send their own value back in 0x402A, §5.5) |
| 0x10CF | NC_CHAR_ITEMACTIONCOOLTIME_CMD | FUN_0040ab50 | +0x668 (W01 §6.3 lists no CharDB source for this slot) |
| 0x10D8 | NC_CHAR_NEWBIE_GUIDE_VIEW_LIST_CMD | FUN_0040abb0 | +0x1ecf8 `m_pCharDataNewbieGuideViewList` (size at +0x1ecfc; W01 §6.3 names the size slot); sent once by §4.7 |
| 0x10DC | NC_CHAR_COININFO_CMD | FUN_0040de50 | +0x6c0 |
| 0x10E2 / 0x10E5 / 0x10E8 | NC_CHAR_CARDCOLLECT_CMD / _BOOKMARK_CMD / _REWARD_CMD | FUN_0040deb0 / FUN_0040df10 / FUN_0040df70 | +0x6c8 / +0x6d0 / +0x6d8 |
| 0x10CA | NC_CHAR_GET_CHAT_BLOCK_SPAMER_DB_CMD | FUN_0040d6e0 | only if CHARDATA.chrregnum == u32 @payload+2: +0x1ece4 / +0x1ece8 = u32 @+6 / u32 @+0xa (BlockTime, DelayTime) |
| 0x1114 | NC_CHAR_TUTORIAL_INFO_WORLD_CMD { u32 nCharNo, PROTO_TUTORIAL_INFO (u32 nTutorialState, u8 nTutorialStep) } | FUN_0040e4b0 | session by `Clients_FindByCharNo(nCharNo)`; `SetTutorialInfo` FUN_00433630: +0x1ed2e nCharNo, +0x1ed32 state, +0x1ed36 step |
| 0x111E | NC_CHAR_CHAT_COLOR_CMD { u32 nCharNo, u8 nChatFontColorID, u8 nChatBalloonColorID } | FUN_0040e500 | by charNo; `ChatColor_SetFontColorID` FUN_00433800 → +0x1ed37, `ChatColor_SetBalloonColorID` FUN_00433810 → +0x1ed38 |
| 0x1121 | NC_CHAR_USEITEM_MINIMON_INFO_CMD { u16 handle, u32 charNo, USEITEM_MINIMON_INFO } | FUN_0040e560 | by handle (charNo not checked); `SetUseItemMinimonInfo` FUN_00433bb0 copies 0x32 bytes (bNormalItem, bChargedItem, NormalItemList[12], ChargedItemList[12]) to +0x1ed5c |

The 0x1114 / 0x111E / 0x1121 handlers also return 1 when the link or packet pointer is null (defensive checks that
never fire). CharDB 0x1010 (friends), 0x1012 / 0x1097 / 0x1414 / 0x1416 (guild), 0x0844 / 0x0864 / 0x0869 (chat
spam) and 0x10EC / 0x10EF / 0x10F4 (attendance) are feature handlers: §5.8.

```pseudo
CWMClientSession::CharDataStore(quest done) (blob +0x578 / size +0x57c):          @ FUN_00433210
    in = { u32 chrregnum @0, u16 @4, u16 total @6, u16 count @8, u16 start @10, record[count] (10 bytes) @12 }
    if blob exists and size != total: free it
    if no blob: size = total; blob = new[total]; header = { chrregnum, u16 @4, total, 0, 0 }
    copy the count records to blob + 12 + start × 10
    # start × 10 + 12 + count × 10 is never compared with total: heap overflow on inconsistent chunks (original bug) W05-B17
    # the header's count / start words stay 0; the zone side reads the records by total (W01 §7.2 0x1022 chunking)
CWMClientSession::CharDataStore(skill chunk):                                     @ FUN_004307d0
    in == null: log, return
    k = in[4] >> 2 (in[4] & 0xfc must be ≤ 0x17, else ignored): chunk 0..5
    store the whole chunk in +0x598 + 4k (size +0x5b0 + 4k), reuse when the size is equal
CWMClientSession::CharDataStore(items, n):                                        @ FUN_00430870
    order = in[0] & 0x7f (PacketOrder), part = in[1] (nPartMark)
    part & 4 and order < 3: order 0 frees all three inventory chunks first; store in +0x600 + 4·order (size +0x60c + 4·order)
    part & 8:  store in +0x618 (equipment)        part & 0x10: +0x620 (mini-house skin)        part & 0x20: +0x628 (action)
    # several bits in one packet store the same bytes in several slots
```

### 5.5 Zone state saves (W01 §7.4 per handler)

All pass `Zone_CheckAlive`; most find the session by `u16 wldmanhandle @payload+0` and require a CHARDATA blob whose
chrregnum equals the payload's charNo (W01 §7.4). Sizes come from counts inside the payload and are never compared
with `len` (original bug) W05-B16: a short or inconsistent packet makes the WM copy whatever follows it.

| Op | Handler (`fc_NC_CHARSAVE_2WLDMAN_…`) | FUN | Check / blob written |
|---|---|---|---|
| 0x400F | QUEST_DOING_CMD | FUN_00429e50 | charNo @+2; +0x570 = payload+2, size 6 + 0x20 × u8 @+7 |
| 0x4010 | QUEST_DONE_CMD | FUN_00429ec0 | charNo @+2; `CharDataStore` FUN_00433210 (§5.4) from payload+2 |
| 0x4029 | QUEST_READ_CMD | FUN_00429f20 | charNo @+2; +0x580, size 6 + 2 × u16 @+6 |
| 0x402B | QUEST_REPEAT_CMD | FUN_00429f90 | charNo @+2; +0x588, size 6 + 0x20 × u16 @+6 |
| 0x4011 | ABSTATE_CMD { wldmanhandle, PROTO_NC_CHARSAVE_ABSTATE_REQ { handle (6), u16 abstatenum @+8, ABSTATEREADBLOCK[] } } | FUN_0042a000 | charNo @+4; rebuilds the CharDB layout { u32 chrregnum, u16 n, n × 0x24 } in a temp buffer → +0x590 |
| 0x4012 | SKILL_CMD | FUN_0042a0b0 | charNo @+7; temp { u32 chrregnum, u8 @+2, u16 @+3, u16 n @+0xb, n × 0x10 } (9 + 0x10n bytes) → skill `CharDataStore` FUN_004307d0 |
| 0x4013 | ITEM_CMD { wldmanhandle, u32 nCharNo, PacketOrder @+6, nPartMark @+7, itemstr } | FUN_0042a160 | charNo @+2; items `CharDataStore` FUN_00430870 from payload+6 with `len − 4` = payload − 2 bytes: 4 bytes past the packet (W05-B15) |
| 0x4014 | CHESTINFO_CMD | FUN_0042a1c0 | charNo @+4; +0x630 = { u16 n @+8, u16[n] } |
| 0x4016 | TITLE_CMD | FUN_0042a370 | charNo @+2; +0x640 = payload+6, size 0x407 + 2 × u16 @+0x40b |
| 0x4019 | LINK_FROM_CMD { wldmanhandle, PROTO_NC_CHAR_LINKFROM_CMD (0x18) } | FUN_0042a460 | **no charNo check**; +0x660 = 0x18 bytes from payload+2; logs `DEBUG 1`, `DEBUG 2`, `DEBUG 3`, `DEBUG : %d : %d,%d` on every call (left-over debug output (original bug) W05-B18); sent once as 0x10B8 and freed (W01 §7.2) |
| 0x4021 | NC_CHARSAVE_SET_CHAT_BLOCK_SPAMER_WM_CMD { WmHandle, CharNo, BlockTime, DelayTime } | FUN_0042c2a0 | charNo; +0x1ece4 BlockTime, +0x1ece8 DelayTime |
| 0x402A | SINGLE_OPTION_CMD { WmHandle, chrregnum, resttime, autopick, mystery_vault, nChatBan, bFirstJoin } (0x11) | FUN_0042c300 | charNo; +0x658 = the 0xf-byte CharDB layout (bFirstJoin as sent by the zone) |
| 0x402C | COININFO_CMD { wldmanhandle, u64 nCoin, u64 nExchangedCoin, u32 nCharNo @+0x12 } | FUN_0042c4c0 | charNo @+0x12; +0x6c0 = { nCoin, nExchangedCoin } (0x10) |
| 0x4032 | CHAT_COLOR_CMD { nCharNo, nChatFontColorID, nChatBalloonColorID } | FUN_0042ccc0 | by charNo; +0x1ed37 / +0x1ed38 (FUN_00433800 / FUN_00433810) |
| 0x4033 | PET_LINK_RESUMMON_CMD { nCharNo, bDoResummon @4, u64 xResummonCode @5, u16 nSummonSlot @0xd, nId @0xf, nRegNum @0x13 } | FUN_0042cd20 | by charNo; `PetSystem_SetDoResummon` FUN_00433910 +0x1ed39, `SetResummonCode` FUN_00433920 +0x1ed40 (u64), `SetSummonSlot` FUN_00433940 +0x1ed48, `SetId` FUN_00433960 +0x1ed4c, `SetRegNum` FUN_00433970 +0x1ed50 |
| 0x4034 | ITEMACTIONCOOLTIME_CMD { nCharNo, u16 num, group[num] (10 bytes) } | FUN_0042cfc0 | by charNo; +0x668 = payload+4, size 6 + 10·num, i.e. 4 bytes past the records even for a consistent packet (W05-B16) |
| 0x4036 | NC_CHARSAVE_USEITEM_MINIMON_INFO_WORLD_CMD { nWorldHandle, nCharNo, USEITEM_MINIMON_INFO } | FUN_0042d020 | charNo @+2; FUN_00433bb0 (0x32 bytes → +0x1ed5c) |
| 0x111C | NC_CHAR_TUTORIAL_STEP_SAVE_CMD { nCharNo, PROTO_TUTORIAL_INFO } | FUN_0042cc40 | by charNo; `SetTutorialInfo` FUN_00433630 |
| 0xCC0B | NC_MOVER_LINKDATA_WORLD_CMD { u32 charNo, … } (0x3d bytes) | FUN_0042c5e0 | by charNo, CHARDATA must exist; `MoverSystem_SetLinkData` FUN_00432fa0: lazily `new(0x3d)` at +0x1ed18 (allocation failure → return), copy 0x3d bytes |

`MoverSystem_ClearLinkData` FUN_00432f70 frees +0x1ed18 (0x1001 character login, W01 §4.2); the 0x3d-byte copy
goes to the next zone as NC_MOVER_ZONE_LINKDATA_ZONE_CMD (FUN_004330a0, W01 §6.3).

### 5.6 Ping-test relay (OPTool ↔ WM ↔ client / CharDB / zone)

An operator tool measures the round trip through every hop. Each hop writes its `timeGetTime()` stamps into the
packet and forwards it unchanged; the WM writes the tool's session handle into `hTool` and sends the result back to
that tool. Structs *(pdb2016)*, offsets from the payload start:

```pseudo
OPTool 0x0813 NC_MISC_PINGTEST_TOOL_WM_CLIENT_ZONE_DB (0x82: ID, hTool @4, ToolSendToWM, ToolRecvFromWM, Name5
        TargetCharName @0xe, hWMClient @0x22, WMSendClient @0x24, WMRecvFromClient @0x28, ClientSendZone @0x2c,
        ClientRecvZone @0x30, hZoneClient @0x34, zone/DB stamps @0x36..0x52, NETPACKETZONEHEADER @0x56, buylot @0x5c):   @ FUN_00425f10
    hTool = tool session handle; WMSendClient = now
    c = Clients_FindByCharName(TargetCharName)
    none: hWMClient = 0; WMRecvFromClient = now; Send the tool 0x0813 (0x82 bytes)
    else: hWMClient = c.handle; Send c 0x0813
client GameFrameWork FUN_0049fba0: ClientSendZone == 0 → ClientSendZone = now, send 0x0813 to its zone connection;
    else ClientRecvZone = now, send it back to the WM connection *(which of the two PgNet links is which: inferred)*
client → WM 0x0813: WMRecvFromClient = now; Send the tool (by hTool) 0x0813         @ FUN_00415670 (W01 §5.3)
OPTool 0x0814 NC_MISC_PINGTEST_TOOL_WM_DB (0x26: ID, hTool, ToolSendToWM, ToolRecvFromWM, WMSendDB @0xe,
        WMRecvFromDB @0x12, DB stamps @0x16..0x22):                                   @ FUN_00426060
    hTool = handle; WMSendDB = now; Send CharDB 0x0814
CharDB 0x0814: WMRecvFromDB = now; Send the tool (by hTool, if still connected)        @ FUN_0040c460
OPTool 0x0815 NC_MISC_PINGTEST_TOOL_WM_ZONE_DB (0x3a: …, WMTargetZoneNo @0xe, WMSendZone @0x12, WMRecvFromZone @0x16,
        zone / DB stamps @0x1a..0x36):                                                @ FUN_00426130
    hTool = handle; WMSendZone = now; z = Zones_Get(WMTargetZoneNo)
    none: WMRecvFromZone = now; WMTargetZoneNo = 0xFFFFFFFF; back to the tool   else: Send z 0x0815
zone 0x0815: WMRecvFromZone = now; to the tool                                        @ FUN_0042b180
OPTool 0x0816 NC_MISC_PINGTEST_TOOL_WM_ZONE (0x22: …, WMTargetZoneNo @0xe, WMSendZone @0x12, WMRecvFromZone @0x16,
        ZoneRecvFromWMS @0x1a, ZoneSendToWMS @0x1e): same as 0x0815 with size 0x22   @ FUN_00426260
zone 0x0816: WMRecvFromZone = now; to the tool                                        @ FUN_0042b250
```

The other three client "accepted, no action" handlers of W01 §5.3: 0x0836 NC_MISC_APEX_CLIENT_CHCSTART_CMD
FUN_00415790 logs "ERROR - SERVER IS NO-APEX VERSION, BUT CLIENT APEX VERSION COME. NC_MISC_APEX_CLIENT_CHCSTART_CMD"
and returns 1; 0x0827 and 0x0832 (both registered to NC_MISC_XTRAP2_CLIENT_DATA_CMD FUN_00415a10) and 0x0834
NC_MISC_HACK_SCAN_STORE_CMD FUN_00415bc0 only run `Client_CheckAlive`.

### 5.7 Small helpers and the log systems

| Function | What it does | Used by |
|---|---|---|
| `CWMClientSessionManager::Send(handle, pkt)` FUN_00438220 | slot = handle % max; sends only if slot.handle == handle and state == 1, else 0; checks the slot pointer for null after using it (dead check (original bug) W05-B21) | CharDB replies by client handle (0x0C13 …) |
| `CWMClientSession::GetCharID` FUN_004351a0 | CHARDATA + 4 (charid), or a static zeroed Name5 when there is no CHARDATA | logs, 0x180C |
| `CWMClientSession::ClearRaidReserve` FUN_00431660 | +0x1ecd0 = 0xFFFF (pending raid invitation) | 0x1001 (W02) |
| `SetUserType` FUN_00433a90 / `SetUserTypeRewardEndTime` FUN_00433aa0 | +0x1ed54 / +0x1ed58 (W01 userKind / userKindUntil) | AccountDB 0x0C61 (W01 §3.3) |
| `CWMClientSession::GetTutorialSelectedSlot` FUN_00433600 | byte +0x1ed2d | CharDB 0x1113 (W01) |
| `GetShineServerIDName` FUN_0045a040 | `gpShineServerIDNames[id]`, id ∉ 0..20 → [10] | connect logs |
| `CChatRestrictServer::Get(charNo)` FUN_0045cb90 | linear search over `n` (+0) entries of the charNo array at +0x8a0; returns entry +4 + 0x16·i or null | CharDB id change (W04 §14) |
| `CHolyPromiseServer::Clear` FUN_00451000 | `CHolyPromise::Clear`, then the 3 handle words at +0x22c..+0x231 = 0xFFFF | logout (W04 holy promise) |
| `CFriend::PartyChange` FUN_0045c430 | find the friend whose Name5 (5 dwords @+8) matches; set its party byte (+0x1e in the 0x48-byte entry); 1 if found | W04 §5 friend party state |
| `CKQServer::Send_NC_KQ_VOTE_BAN_MSG_LOGOFF_CMD` FUN_004530e0 | if CHARDATA and `m_bCharDataValid` (+0x704, W01 inGame): Send 0x5830 with payload size 1 and no data: the byte is whatever the stack buffer held (`CSendPacket` ctor FUN_0045fd30 clears only size / id; `CSendPacket::ID` FUN_0045fe70 copies nothing for a null source) (original bug) W05-B19. The 2017 struct is empty (`sizeof` 1) | KQ map login (W04 §6) |
| `Raid::iterator::GetPartyRegNo` FUN_00462ae0, `Raid::GetSubLeader` FUN_004629c0, `Raid::GetLooter` FUN_00462a50, `Raid::GetLooting` FUN_00462a80 (raid + 0x24), `CLooting::reset` FUN_00464740 (4 types 0, looter −1), `GetItemLootingType` FUN_004646d0, `GetLooter` FUN_00464760 / `SetLooter` FUN_00464770 (+0x10), `CParty::operator[]` FUN_00464f50 (party no ≥ 4000 → `CParty::p_def`; else 0xd0-byte entries) | accessors | W02 (raid / party loot) |
| `PROTO_NC_DATA_SEND2<PROTO_NC_RAID_MEMBER_LIST_CMD>` ctor FUN_004359c0 | zero-inits the 4 × 0x14 and 0x15 × 0x14 MEMBER_INFO arrays | W02 raid member list |
| `std::list<AttendanceInfo>::push_back` FUN_0043b770 / `insert` FUN_0043b830 / `erase` FUN_0043b340 | STL | W04 §17.5 |

Log systems besides `_DEBUGMSG` (§3): `cShineLogSystem` objects `gZoneLinktoErrorLog` ("ZoneLinktoError", one file per
hour) and `gSocket_IOCP_Write` ("Socket_IOCP_Write", one file per day), set up by static initialisers (`SLS_SetLogName`
FUN_004674c0; empty or ≥ 256-char names fall back to "ShineLog").

```pseudo
cShineLogSystem::SLS_AddLog(this, fmt, …):                                    @ FUN_00467530
    if !SLS_bIsUse (+0): return true
    name = "%s\%s_%04d-%02d-%02d %02d.txt" (SLSFI_HOUR) or "%s\%s_%04d-%02d-%02d.txt" (SLSFI_DAY)
    if name != SLS_sOpenFileName: close the old file; fopen(name, "a+"); failure → _mkdir(".\Log") (CRT FUN_0046bcfc, also used by client 0x080F for `.\DebugClient`, W01 §5.3) and retry; fail → false
    fprintf("%06d %s %s\t%s\n", SLS_nLogCount++, date, time.ms, vsprintf(fmt, …)); fflush
```

Callers: zone 0x101C (`NC_CHAR_ZONE_CHARDATA_REQ : CheckConnectionValidation Fail`, `… Invalid ClientHandle
[CharID=%s]`, `… CharID Not Match [%s/%s]`), zone 0x104B (`NC_CHAR_REGISTNUMBER_REQ : CheckConnectionValidation
Fail`), `CSocket_IOCP::Send` / `WriteCallback` (write errors). Nothing in the WM writes `SLS_bIsUse`, so both logs
stay off (original bug) W05-B20 *(no write found in the export)*. `AssertClass::ac_AssertFail` FUN_00467340 appends
"%s : AssertClass::ac_AssertFail : %s[%d]" to `ac_FileName` when `ac_Write2File` (the raid member list asserts).

### 5.8 Triage of the W01 handlers `coverage.py` lists as undocumented

coverage.py counts a handler only when a doc cites its `FUN_`; W01 described most of these by opcode. Where each is
documented now:

| Handlers | Where |
|---|---|
| CharDB blob pushes 0x1007 … 0x101B, 0x10CC, 0x10CF, 0x10D2, 0x10D5, 0x10D8, 0x10DC, 0x10E2 / 0x10E5 / 0x10E8, 0x10CA, 0x1114, 0x111E, 0x1121 | §5.4 |
| Zone saves 0x400F … 0x4036, 0x111C, 0xCC0B | §5.5 |
| Client 0x0827 / 0x0832 / 0x0834 / 0x0836; OPTool 0x0813 … 0x0816 | §5.6 |
| AccountLogDB 0x800A FUN_004090c0 / 0x800C FUN_00409130 (data report) | W04 (cites both) |
| CharDB 0x1414 FUN_0040c6e0, 0x1416 FUN_0040c880, 0x1012 FUN_0040a700, 0x1097 FUN_0040cdb0 (guild) | W03 |
| CharDB 0x1010 FUN_0040a570 (friend list), 0x0844 FUN_0040d660, 0x0864 FUN_0040d980, 0x0869 FUN_0040dbf0 (chat spam), 0x10EC FUN_0040dfd0 / 0x10EF FUN_0040e010 / 0x10F4 FUN_0040e050 (attendance) | W04 |
| Client 0x0840 FUN_00417140, 0x0846 FUN_00417b90, 0x085F FUN_00417ef0, 0x0861 FUN_004180f0, 0x10F1 FUN_00418410 | W04 §17 |
| OPTool 0x2805 / 0x0828 FUN_00425930, 0x2809 FUN_00427790, 0x280C FUN_00425e20, 0x2811 FUN_00425d70, 0x280F FUN_004263f0, 0x2815 FUN_004264d0, 0x281B FUN_004265a0, 0x281D FUN_00426660, 0x2820 FUN_00427630, 0x2822 FUN_00426990, 0x2824 FUN_00427980, 0x2826 FUN_00426c10, 0x282B FUN_00427030, 0x9425 FUN_00427cb0, 0xD001 … 0xD009 FUN_004270f0 / FUN_00427130 / FUN_00427170 / FUN_004271b0 / FUN_004271f0 | W04 (OPTool section; 0x2815 / 0x2820 / 0x2822 / 0x2824 / 0x282B with W03) |
| OPTool 0x384E FUN_004274e0 (party member info) | W02 |

Lost zone and character login (promised in §4.5): `CWMZoneSessionManager::GetServiceMapZoneNo(map)` FUN_004392c0
returns the zone number of the first service-map entry with `active == 1` and the same 12-byte name (else −1); CharDB
0x1005 `fc_NC_CHAR_CHARDATA_ACK` FUN_00410040 then needs `GetZoneSession(zoneNo)` ≠ null and the zone's IP/port. The
zone release (§4.5) clears only the mapping, so the lookup succeeds and `GetZoneSession` fails: the client gets
0x1002 { 0x145 } (W01 §4.2), confirmed.

### 5.9 Uncertain (part 4)

- §5.2: with the shipped `ServerInfo.txt` the zone rows for zone-type peers hold `"0.0.0.0"`, and the WM compares that
  string with the zone's socket address. Either that install's zones connected through a patched exe or the file
  differs from the one used in production; the 2016 code itself only accepts an exact (case-insensitive) string match.
- §5.4 B15 rests on `len` = 2 + payload (`CPacket::GetDataSize` returns the frame's length byte). If the receive path
  passes a different `len`, the CharDB copies would be exact and the zone item copy 2 bytes long instead of 4.
- The `CCsl` script parser (format / data / include / remark handling) is shared by all servers and is read here only
  through its accessors.

---

## 6. Construction, service shell and small helpers (sweep)

What the sweep found below the functions of §1–§5 that no doc cited: the constructors `gServer` runs before
`WinMain`, the parsers' handler tables, the Windows-service shell and crash dump, and small helpers. The socket / IOCP
layer and the config-script reader are a shared library of Login, WM and Zone and go to the follow-up item S02 (§9).

### 6.1 Parser handler tables (`PROTOCOLFUNCTIONTEMPLETE<T>`)

Every link parser (`CParserAccountDB` … `CParserZone`) holds one `m_PFT` dispatch table:

```pseudo
PROTOCOLFUNCTIONTEMPLETE<T> layout:                                 (identical for the 8 parsers)
    +0x000          vftable
    +0x004          pft_funcpnt[1024]          # one row pointer per **command** (opcode & 0x3FF)
    +0x1004         pft_defaultdepartment[64]  # shared row: every department → pft_deffunc
    +0x1104         pft_deffunc = the parser's fc_dummyfunction (§5.1)        (size 0x1108, pdb2016)

<Parser>::<Parser>(this):        (constructed as a member of gServer, before WinMain)
    pft_deffunc = &fc_dummyfunction; pft_defaultdepartment[0..63] = pft_deffunc
    pft_funcpnt[0..1023] = &pft_defaultdepartment
    pft_Store(dept, cmd, handler) for each handler   # the registrations of handlers.json

pft_Store(this, dept, cmd, fn):                                     @ FUN_00427260  (one copy, folded for all 8)
    if pft_funcpnt[cmd] == &pft_defaultdepartment:
        pft_funcpnt[cmd] = new fn[64], all = pft_deffunc          # rows are allocated per command on first use
    if pft_funcpnt[cmd][dept] != pft_deffunc:
        ac_AssertFail("PROTOCOLFUNCTIONTEMPLETE<T>::pft_Store : Duplicate protocol set")
        ShineExit("PROTOCOLFUNCTIONTEMPLETE<T>::pft_Store")       # process ends (§3.2)
    pft_funcpnt[cmd][dept] = fn

~PROTOCOLFUNCTIONTEMPLETE<T>(this):     (at exit, §4.6)
    delete[] every pft_funcpnt[i] that is not &pft_defaultdepartment
```

Dispatch is `pft_funcpnt[opcode & 0x3FF][opcode >> 10]` (the folded parser of §5.1). Constructors / destructors and
their registration counts (handlers.json, 486 `pft_Store` calls in total, all to FUN_00427260):

| Parser | Ctor | `~PROTOCOLFUNCTIONTEMPLETE` | Registrations |
|---|---|---|---|
| `CParserAccountDB` | FUN_00408ae0 | FUN_00408260 | 9 |
| `CParserAccountLogDB` | FUN_00409650 | FUN_004092b0 | 10 |
| `CParserCharDB` | FUN_00411ec0 | FUN_0040ed60 | 163 |
| `CParserClient` | FUN_004234f0 | FUN_00419660 | 167 |
| `CParserGameLogDB` | FUN_00424340 | FUN_004242c0 | 4 |
| `CParserLogin` | FUN_00424b40 | FUN_00424920 | 7 |
| `CParserOPTool` | FUN_00427e60 | FUN_00427230 | 38 |
| `CParserZone` | FUN_0042f540 | FUN_0042d490 | 88 |

What each registered handler does is in W01–W04 and §5 (triage §5.8); the constructors hold nothing else.

### 6.2 Member and session constructors

`WorldManagerServer::WorldManagerServer` FUN_00406a20 (header) constructs, among others:

| Constructor | What it sets |
|---|---|
| `CWMBaseSession` FUN_00430020 (all session classes) | `m_SocketIOCP` + `m_Packet` built; `m_Connected_Server_ID = 10`, world / zone 0, `m_Status = EMPTY`, `m_Connected_Time = GetLocalTime()`, `m_LastReceiveTime = m_LastSendTime = CGTimer::GetTime()`, `m_LastHeartBeatSendTime = 0`; the three overlapped records (read / write / close) point back to the session and its `CIOCP_Process_LSession` |
| `CWMAccountDBSession` FUN_0042fb70 / `CWMAccountLogDBSession` FUN_0042fb90 | peer type 0 (AccountDB) / 1 (AccountLogDB), world 0, zone 0 |
| `CWMLoginSession` FUN_00438dd0 / dtor FUN_00438b30 | peer type 4; `m_ValidationBF` = 0x800 × `PROTO_NC_USER_WILLLOGIN_REQ` (0x15b bytes each, ctor FUN_00412d20 clears `userid` and `spawnapps`): the pending world-login table of W01 §3.1 |
| `CWMZoneSession` FUN_00430430 / dtor FUN_00438e50 | base only (also used for OPTool sessions, §4.1) |
| `CWMBaseSessionManager` FUN_004300e0 / dtor FUN_004301a0 | all list pointers null, counts 0 / delete the node array, clear the list heads |
| `CWMClientSessionManager` FUN_004385f0 | IP-group vector empty; `srand(time())`, `m_ClientSeed = rand()` (u16); `m_NextSendWMTime = 0` |
| `CWMZoneSessionManager` FUN_00439640 | 32 `INDUN_MAP_LIST` + 1024 `ZONE_SERVICE_MAP_LIST` built, the service-map list zeroed (0x4000 bytes), mapping table null, `m_SendWMTime = 0` |
| `CWMOPToolSessionManager` FUN_00438e70 / dtor FUN_00438ed0 | session array null / base `FreeSessions` + delete the 0x118-byte sessions with the zone-session dtor |
| `CGuildManager` FUN_0043da90 / dtor FUN_00450f60 | `m_Tournament` (`CGuildTournamentServer` FUN_0043d0d0: `CGuildTournament` FUN_0045b8c0 = 31 × `GUILD_TOURNAMENT_LIST`, match type NONE, `Clear`; three `CDataReader`s for the tournament tables, §3.2; `m_bDBRead = 0`); init flags 0, guild list empty. Dtor: `Clear` (W03), the three readers, the tournament |
| `CNpcScheduleServer` FUN_00456c10 | one `CDataReader` (`NpcSchedule`, W04 §17.6) |
| `CSingleDataMap` FUN_00459fd0 / dtor FUN_00459f70 | empty `std::map<std::string, u16>` (the `ServerParam` table, §3.3; `bad_alloc` thrown if the head node cannot be allocated) / erase all, free the head |
| `CharClassDataBox` FUN_00465a40 / dtor FUN_00465a70 | `BinaryDataBox<UseClassTypeInfo>` (base `BinaryData` FUN_00468cb0 / FUN_00468cd0 = a `CDataReader` with its own vftable) with an all-zero default row (§3.2) |
| `CParty` FUN_00465950 | `CParty::Init` (W02 §1.2) |
| `CPartyFinderServer` FUN_00457710 / dtor FUN_00457730 | `CPartyFinder` FUN_0045d500 (empty list) + a critical section / delete the CS, `~CPartyFinder` FUN_0045d6e0 (free every node) |
| `CServerInfo` FUN_00465c80 | its `CCsl` (S02) |
| `IOBufferContainer` FUN_00468d80 | pre-allocates 512 `CIOBuffer`s of 0x2010 bytes; any allocation failure → `ShineExit("IOBufferContainer::IOBufferContainer")` |

`CWMClientSession::CWMClientSession` FUN_00434300 (§4.3) adds `CHolyPromiseServer` FUN_004512f0 (`CHolyPromise`
cleared, `m_HolyPromisesUpHandle = 0xFFFF`, `m_HolyPromisesUpCharNo = 0xFFFFFFFF`, both "need send first info" flags
and `m_nRemainMoney` 0; W04 §12), `CFriendServer` FUN_0045c8f0 (100 × `PROTO_FRIEND_INFO` 0x48 bytes, count 0,
`m_bNeedTakeInfo = 0`; W04 §5) and `PacketEncrypt` FUN_0045d4a0 (empty constructor; the client cipher state lives
elsewhere, `docs/protocol/README.md`).

### 6.3 Windows-service shell, crash dump, checksums

```pseudo
Singleton<WinService>::getInstance():                                         @ FUN_004069a0
    first call: new WinService (FUN_00466d60: serviceName = "", handleServiceEvent = INVALID_HANDLE_VALUE) + vtbl[0]
WinService::startDispatcher(name, startFn, stopFn):                            @ FUN_00466fd0
    name = name                       # self-assignment: this->serviceName stays ""   (original bug) W05-B23
    serviceStartFunc = startFn (::OnStart_Service); serviceStopFunc = stopFn (::OnStop_Service)
    StartServiceCtrlDispatcherA({ name, serviceLoop }) → false on failure (Start still returns 0, §1.1)
WinService::serviceLoop(argc, argv):     (SCM thread)                          @ FUN_00466ea0
    if onServiceStart():
        loop: WaitForSingleObject(handleServiceEvent, INFINITE)
              if statusEvent in (1 STOP, 5 SHUTDOWN): break    # other controls (4 INTERROGATE) just loop
    onServiceStop()
WinService::onServiceStart():                                                  @ FUN_00466de0
    handleServiceEvent = CreateEvent(auto-reset); RegisterServiceCtrlHandlerA(serviceName = "", serviceHandler)
    SetServiceStatus(OWN_PROCESS, START_PENDING, accepts STOP | SHUTDOWN, checkpoint 1, wait 1000 ms)
    if serviceStartFunc and !serviceStartFunc(): return false        # OnStart_Service failed (§1.1)
    SetServiceStatus(RUNNING); return true
WinService::serviceHandler(control):                                           @ FUN_00466db0
    statusEvent = control; SetEvent(handleServiceEvent)
WinService::onServiceStop():                                                   @ FUN_00466c20
    SetServiceStatus(STOP_PENDING, wait 5000 ms); serviceStopFunc()   # ::OnStop_Service (§1.6) returns only when stopped
    SetServiceStatus(STOPPED)
    if handleServiceEvent == INVALID_HANDLE_VALUE: CloseHandle(INVALID)   # inverted test   (original bug) W05-B24
WinService::uploadService(name, display, exePath):                            @ FUN_00466a70
    CreateServiceA(SCM, name, display, access 0, SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START,
                   SERVICE_ERROR_IGNORE, exePath, no account) → true when created
WinService::removeService(name):                                               @ FUN_00466b70
    OpenSCManager fails → false; else DeleteService(OpenServiceA(name, DELETE)) → **true** even when the service
    does not exist or the delete fails                                                  (original bug) W05-B22
WinService::queryServiceStatus(&state, machine, name):                         @ FUN_00466cb0
    QueryServiceStatus → state = dwCurrentState, return 1; any failure → state = GetLastError(), return 0
```

So the WM is installed as a manual-start service: the first run without arguments installs it (`ParseCmd`, §1.1), and the
service manager then starts it; stop and system shutdown both run `OnStop_Service`.

```pseudo
MiniDumper::MiniDumper():        (WinMain, §1.1)                                @ FUN_004608b0
    SetUnhandledExceptionFilter(TopLevelFilter)
MiniDumper::TopLevelFilter(exc):                                               @ FUN_004605c0
    load DBGHELP.DLL from the exe directory, else from the system path
    MinidumpCallStack(exc)                                                      @ FUN_004603a0
        "<exe path>_<time>CallStack.txt": fault reason, a dashed line, then the stack trace (EHInitSymbolEngine,
        GetFirst/NextStackTraceString(0xe, exc))
    FuncForStack() if set (null in the WM)
    no DBGHELP.DLL → log "EXCEPTION - DBGHELP.DLL NOT FOUND"; no MiniDumpWriteDump → "… DBGHELP.DLL TOO OLD"; return 0
    "<exe path>_<time>.mdmp" = MiniDumpWriteDump(process, pid, file, type 0x40, { thread, exc })
    log "EXCEPTION - Saved dump file to '%s'" (or the create / save failure texts); return 1 on success
```

`<time>` = `GetCurrentTimeString2(0)` (Z09 §30.1 documents the zone's copy of this dumper; same code). The call-stack text
comes from a linked-in crash-handler library (function names as in John Robbins' *CrashHandler* *(inferred from
the names)*): `GetFaultReason` FUN_00468770 ("<exe> caused an: <exception name> in module: <module> at: < seg:offset >",
registers; "Bad parameter to GetFaultReason" for a null record, `EHConvertSimpleException` FUN_004680c0 maps the
exception code to its name), `GetFirstStackTraceString` / `GetNextStackTraceString` FUN_00468bc0 / FUN_00468c20 →
`EHInternalGetStackTraceString` FUN_00468370 (`StackWalk` frames with `FillInStackFrame` FUN_00468010 and
`CH_ReadProcessMemory` FUN_00468090), `EHInitSymbolEngine` / `EHCleanupSymbolEngine` FUN_00468310 / FUN_00468340
(dbghelp symbol engine). Process exit
after a crash is then the CRT's default.

`CDataReader::Read`'s MD5 (§3.1) is the standard RFC 1321 algorithm: `CMD5Checksum::GetMD5` FUN_0045eca0 →
`Update` FUN_0045e9e0 → `Transform` FUN_0045e300 (round constants 0xd76aa478 …) → `Final` FUN_0045ea90 (hex string,
via `std::string::append` FUN_00458bb0).

### 6.4 Small helpers

| Function | What it does |
|---|---|
| `CWMClientSession::SetSessionMode` / `GetSessionMode` FUN_004334b0 / FUN_004334c0 | write / read `m_SessionMode` (+0x1ed20, W01's `loginStep`; W01 names them `Client_SetLoginStep` / `Client_GetLoginStep`) |
| `CWMClientSession::SetActiveTimeToCurrent` / `GetActiveTime` FUN_004334d0 / FUN_004334f0 | `m_dActiveTime` (+0x1ed24) = `_time32()` / read it (W01's `Client_GetConnectTime`; the login timeout of §4.5) |
| `CWMClientSession::GetBoolClosingSession` / `SetBoolClosingSession` FUN_00433520 / FUN_00433530 | read / write `m_bClosingSession` (W01 names the getter `Client_IsOverLimit`; it is the "already closing" flag of §4.5) |
| `CWMClientSession::cs_GetRawIPAddress` FUN_00433510 | pointer to the peer IPv4 in the socket address (+0x30, §4.1; IP groups §4.4) |
| `CServerInfo::ReadServerInfo` FUN_00465c90 | `CCsl::Clear` + `CCsl::ReadScript(file, 0, 0x401, 0)` (S02) |
| `CServerInfo::GetMyServerInfo` FUN_00465cd0 | first data row of format id 0 (`MY_SERVER`, the first `#DEFINE` of WMServerInfo.txt): `pServiceName`, `pDisplayName`, `nServerID`, `nWorldNo`, `nZoneNo` (fields 0–4) → `m_MyServer` (W01 §2); 0 if missing |
| `GetShineServerIDShortName(id)` FUN_0045a060 | short peer-type name for logs, `gpShineServerIDShortNames[id]`; out of 0…20 → entry 10 |
| `GetLastErrorStr(code, crlf)` FUN_0045ff10 | `FormatMessageA` of `code` (0 → `GetLastError()`), one line unless `crlf`; unknown → `"ErrorCode=%d"`; static buffer |
| `_ExecUpdateInfoMsg(text)` FUN_004602c0 | overwrite `.\DebugMessage\ExecUpdateInfo.txt` with `text` (`Start` writes `"-"`) |
| `_DEBUGMSGVC` FUN_00460360 / `Log` FUN_00460380 | `_DebugMessageNew2(level, "Msg", fmt, …)` like `_DEBUGMSG` (§3.2) |
| `AssertClass::ac_DateTime` / `ac_AssertFail(msg, x)` FUN_00467270 / FUN_004672f0 | build `Assert<yyyymmdd><hh>.txt` and append `"<time> : AssertClass::ac_AssertFail : msg[x]"` when `ac_Write2File`; the 3-argument variant FUN_00467340 is §5.7 |
| `CPartyFinder::DelNode` FUN_0045d560 | unlink one party-finder entry, free it, count − 1 (`PartyFinder_ExpireTick`, W02 §1.5) |
| `Raid::GetMemberRegNoByIndex(party, slot)` FUN_00462d80, `Raid::iterator::GetCharRegistNo` FUN_00462de0, `Raid::iterator::GetSlotInfo` FUN_00462ea0 | raid member lookups for W02 §1.4: party index < 4, slot < 5 and < `NumOfMember`, party number ≠ 0xFFFF; return `chrregnum` (else 0xFFFFFFFF) or the slot pointer (else null); the iterator returns charNo 0xFFFFFFFF with success for an empty slot |
| `CLooting::CLooting` FUN_00464f80 | the raid's four looting types = FREE, looter 0xFFFFFFFF (`Raid` ctor, W02 §1.4) |
| `CGuildMemberServer::Send_NC_GUILD_WAR_START_CMD` / `…_END_CMD` FUN_00444180 / FUN_00444230 | `BroadCastToMember` of 0x7433 (0x3c bytes) / 0x7434 (0x22 bytes); the payloads are W03 §3.3 `Guild_WarStart` / `Guild_WarEnd` |
| `CGuildAcademyMember::~CGuildAcademyMember` FUN_0045b250 | destroys the 100 × 0x6d member array (`CGuildManager::Clear`, W03) |
| `RandomBox::rb_1000` FUN_00467bc0 | `well512_GetRandom(1000)` (KQ team draw, W04 §6): `cWell512Random::well512_GetRandom()` FUN_00468fd0 is the WELL512 generator (16-word state) returning `state / 2^32` in [0, 1); `well512_GetRandom(n)` FUN_00469080 = `round(r × 10^11) % n` |
| `CPartyFinder::Find(name)` FUN_0045d510 *(pdb2016)* | linear search of the party-finder list for the entry whose `sCharID` (Name5, 5 dwords) equals `name`; null if none. Used by `CPartyFinder::Del` FUN_0045d670 (W02 §1.5 `PartyFinder_Delete`), reached from `Logout` → `CPartyFinderServer::LogOffChar` (§4.5) |
| `Name8::operator=` FUN_004244d0 | 32-byte name copy (NPC schedule, W04 §17.6) |
| `std::list<AttendanceInfo>::splice` FUN_0043bda0 | STL splice used by `EA_Schedule_Process` (W04 §17.5) |
| `String` FUN_00467170 / FUN_00467200 (ctors), FUN_00467090 (dtor), FUN_004670d0 / FUN_00467230 (`operator=`), FUN_00467250 (`operator==`), FUN_004670c0 (`makeUpper`), FUN_004670b0 (`getBuffer`) | the small heap-string class of `ParseCmd` and `WinService` (§1.1, §6.3); FUN_00467230 = `operator=(other.chData)` |

## 7. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W05-B1 | `MainThread` FUN_00407340 | sleeps 5 ms per pass only while the CharDB link is in state 1 | one CPU core at 100 % during start-up, the guild data load and while the CharDB is lost | sleep on every pass (or wait on events) |
| W05-B2 | `OnStop_Service` FUN_00406d40 | sets `m_MainWorkStep = CLOSE_NORMAL` and `m_bStopMainThread = 1` together; `MainThread` tests the flag after each `MainWork` | timing-dependent: when the stop lands while `MainWork` runs (not during the 5 ms sleep), the thread exits before `MainWork` applies `SetLogoutType(0x782)`; logout reports of that service stop carry stale close reasons (the session's last explicit reason, or the previous slot user's, W05-B9) | set only the step and let `MainWork` stop the thread |
| W05-B3 | `CDailyQuestTimer` ctor FUN_00439f10 | December start: next month = February (month index 1) of next year | none (the year branch fires on 1 January and sets the month too) | month index 0 |
| W05-B4 | `DQ_Schedule_Process` FUN_0043a120 | `tInitYear/Month/WeekQuest` are computed once at start and never advanced | after the first boundary each daily run recomputes year / month / week again; same values | advance the end times when a period rolls over |
| W05-B5 | `CGuildTournamentServer::ReadScheduleData` FUN_0043d270 | with no `isActive == 1` row the loop leaves the last row selected and returns success | a table with every schedule disabled still runs the tournament on the last row's schedule | fail the load (or run no tournament) when no row is active |
| W05-B6 | `CDataReader::Read` FUN_00458ca0 | byte checksum and MD5 run over `m_nBFSize` (buffer capacity), not `m_nFileSize` | none in the WM (each reader is filled once); a re-read of a smaller file into the same reader would hash stale bytes | hash `m_nFileSize` bytes |
| W05-B7 | – | withdrawn in review: `ReadGlobalGameData` does pass the path for `%s` (the export drops varargs, §3.2) | – | – |
| W05-B8 | `CWMClientSessionManager::InactiveSession` FUN_004380f0 | new handle = old + max without the `== 0xFFFF` guard the zone / OPTool managers have | slot `0xFFFF % max` eventually gets handle 0xFFFF, the "offline" marker of friend / holy-promise handle arrays; that player shows offline *(inferred)* | skip 0xFFFF as the other managers do |
| W05-B9 | `CWMClientSessionManager::ActiveSession` FUN_00438a60 | `m_LogoutType` is set to 0x786 only by the constructor, never per connection | a session closed without an explicit reason (socket drop, heartbeat, login timeout, service stop) reports the previous slot user's reason to AccountDB 0x0C11, AccountLogDB 0x0722 and CharDB 0x1037 | reset `m_LogoutType` to 0x786 in `ActiveSession` |
| W05-B10 | CharDB 0x0C13 `fc_NC_USER_AVATARINFO_ACK` FUN_0040ede0 | DB-error path calls `CWMClientSession::Close` directly instead of setting state 3 | `Client_OnClosed` runs again when `ProcessDisconnect` sees the dead socket: duplicate 0x0C11 / 0x0722 / 0xC803 / 0x0C19 *(inferred)* | set `m_Status = 3` and let `ProcessDisconnect` close |
| W05-B11 | `NewbieGuideViewListRefresh` FUN_00432ce0 | failure log names `CWMClientSession::ChatBlockSpamFilterRefresh` | misleading log line | log its own name |
| W05-B12 | – | withdrawn in review: the 0x0802 "no info" log gets world, zone and IP (§5.2) | – | – |
| W05-B13 | zone 0x0802 FUN_004283e0 | `server_from_world_num` is stored but neither used for the ServerInfo lookup nor compared with the WM's world | a zone configured for another world (same zone number and IP) registers and is stored with the wrong world | refuse a world mismatch |
| W05-B14 | CharDB `fc_dummyfunction` FUN_00409ae0 | `DummyCount` is global and never reset; from the 11th unknown CharDB packet of the process lifetime each one returns 0 | rare unknown packets accumulate over days until one closes the CharDB link (`CLOSE_CHAR_DB`) | count per connection or per time window |
| W05-B15 | CharDB blob pushes (§5.4), zone 0x4013 FUN_0042a160 | copies `len − 2` (zone items `len − 4`) bytes from payload+2 (+6); `len` = 2 + payload | each blob holds 2 (items 4) bytes read past the packet; they go to the zones in 0x101C *(inferred from `len`)* | copy `len − 4` (`len − 8`) |
| W05-B16 | zone dept-16 saves (§5.5) | blob sizes from counts inside the payload, never compared with `len`; 0x4034 even adds 4 bytes to a consistent count | a short or inconsistent zone packet copies receive-buffer bytes into the character state, saved back to the DB | bound the size by `len` |
| W05-B17 | `CharDataStore` (quest done) FUN_00433210 | writes `count` 10-byte records at `12 + start × 10` without checking the allocated `total` | heap overflow if a CharDB / zone chunk is inconsistent | check `12 + (start + count) × 10 ≤ total` |
| W05-B18 | zone 0x4019 FUN_0042a460 | four `DEBUG …` log lines per call; no charNo check (all other saves check it) | log noise on every map change; a stale handle writes another character's link-from data | drop the debug lines; check charNo |
| W05-B19 | `CKQServer::Send_NC_KQ_VOTE_BAN_MSG_LOGOFF_CMD` FUN_004530e0 | 0x5830 sent with a 1-byte payload and a null source | one uninitialised stack byte on the wire | send 0 bytes or a zeroed byte |
| W05-B20 | `cShineLogSystem` `gZoneLinktoErrorLog` / `gSocket_IOCP_Write` | `SLS_bIsUse` is never set | the ZoneLinktoError and Socket_IOCP_Write logs are never written; those errors leave no trace | enable them (config or init) |
| W05-B21 | `CWMClientSessionManager::Send` FUN_00438220 | null check of the slot pointer after reading through it | none (the array pointer is never null) | check before use |
| W05-B22 | `WinService::removeService` FUN_00466b70 | the result of `OpenServiceA` is not checked; `DeleteService` failure is ignored; returns true | `REMOVE` prints "<SERVICE REMOVE OK>" for a service that does not exist or could not be deleted | return false when the open or the delete fails |
| W05-B23 | `WinService::startDispatcher` FUN_00466fd0 | assigns the name argument to itself instead of to `serviceName` | `RegisterServiceCtrlHandlerA` gets an empty name; no effect for a `SERVICE_WIN32_OWN_PROCESS` service (Windows ignores the name) | `this->serviceName = name` |
| W05-B24 | `WinService::onServiceStop` FUN_00466c20 | closes `handleServiceEvent` only when it equals `INVALID_HANDLE_VALUE` (and then closes −1) | the event handle is never closed; none in practice (the process ends right after) | close it when it is valid |
| W05-B25 | quit 0x0C18 mode 0 FUN_00412df0 + `Client_OnClosed` FUN_00437030 | the handler broadcasts 0x0C19 to the zones, then the close path broadcasts it again | every normal quit sends two 0x0C19 for the user to every zone (zones handle an absent user, W01 §5.1 / Z01) | broadcast only in `Client_OnClosed` |

## 8. Not reconstructed / uncertain

- §5.9 (part 4): the `"0.0.0.0"` zone rows of the shipped `ServerInfo.txt` against the exact IP check of 0x0802, and
  W05-B15's dependence on `len` = 2 + payload. Both need a live zone registration or capture (X02).
- W05-B8 and W05-B10 give their effect *(inferred)*: no capture shows a friend shown offline by handle 0xFFFF or a
  duplicated logout report.
- §6.3 dump file names: the separator between the exe path and the time string is a 2-byte constant (`s__`) read as
  `"_"` *(inferred from the Ghidra label)*; the `MiniDumpWriteDump` type 0x40
  (`MiniDumpWithIndirectlyReferencedMemory`) is taken from the decompiled argument order.
- `gpShineServerIDShortNames` (§6.4) is a table of 21 string pointers; its texts are not listed here (logs only).
- §3.4 `CShnDataFileCheckSum`: built but never read in the WM. The zone's copy of the class is the one used: its
  0x1801 check against the client's SHN checksums (FUN_00631350, 49 × 0x41 entries, code 0x147) is documented in
  `docs/pseudocode/zone/Z01-core.md` (map login); the WM keeps a dead copy of the shared class.
- The socket / IOCP layer and the `CCsl` script reader are described here only by what the WM calls (§1.3–§1.5, §4.5,
  §5.2): the send queue, partial writes, buffer limits and the script grammar are S02's.

## 9. Coverage boundary

`coverage.py` does not apply to W05 (no scope table). The sweep instead took every function this file cites, followed
callees three calls deep (`coverage.py`'s rules: hubs over 25 callers and registered handlers not expanded, functions
under 6 lines not counted) and listed what no doc cites: 212 functions before the sweep, 90 after it (54 script / file reader, 20 STL
including the split tail FUN_0040844c of `std::string`'s grow, 16 network library and CRT `atoi`). §6 covers the
WM-specific ones; the rest is below. `coverage.py W01 --all`: gaps 0 (part 4).

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| Network library: `CIOCP` FUN_00464350 / FUN_004645c0 / FUN_004644f0 / FUN_00464380 / FUN_004643c0 / FUN_004646b0, `CSocket_Acceptor` FUN_00463960 … FUN_00463ee0, `CSocket_IOCP` FUN_00466420 / FUN_004665b0 / FUN_004666f0 / FUN_00466240 / FUN_00465f40 / FUN_00466140 / FUN_00466520, `CIOBuffer::Alloc` / `Free` FUN_00468e10 / FUN_00468f00, `CIOSpinLock::Wait` FUN_00468d10, `InetAddress::WinSockStart` FUN_00468c40, `CSendPacket` FUN_0045fd30 … FUN_0045fe70, `CWMBaseSession::Connect` / `Receive` / `Socket_Register_To_IOCP` FUN_0042ffb0 / FUN_0042fcd0 / FUN_0042fd10 | new item S02 (added by W05) | the same library is linked into Login, WM and Zone; no item documents it (L00, W01, Z01 and this file only call it). One item documents it once for all three servers; W05 §1 / §4.5 / §5.2 already give what the WM sees of it |
| Config-script and packed-file readers: `CCsl` FUN_00460a40 … FUN_004626f0, `CToken` FUN_0045a080 … FUN_0045a6f0, `CGdp` FUN_0045ed50 … FUN_0045fac0 | new item S02 | shared with Login and Zone (their `ServerInfo.txt` readers); W05 uses only the accessors (§5.2) |
| STL instantiations (`std::_Tree<…string, u16…>` insert / erase / `_Linsert`, `std::map::operator[]`, `std::vector<…>::reserve`, `std::basic_string::append`; about 18 functions) | none needed | standard-library behaviour (MSVC STL); a rebuild uses its own containers. Their WM users are documented (`ServerParam` §3.3, IP groups §4.4) |
| `__unwindfunclet$…` FUN_0047f3e0 … FUN_00481d50 (exception unwind) | none needed | compiler-generated destructor calls for a constructor that throws; no behaviour |
| FUN_0044e5f9 (calls `ServerParam_GetInt("Guild_CannotLeaveTime")`) | W03 §2.7 (done; documents it under FUN_0044e580) | Ghidra split of `CGuildMemberServer::Recv_NC_GUILD_MEMBER_LEAVE_REQ` FUN_0044e580 after its `try` block; W03 §2.7 has the leave-time check and the 0x0CE2 / 0x0C41 / 0x3190 results |
| Bodies of the 486 handlers registered by the parser constructors (§6.1) | W01–W04, §5 (triage §5.8) | each handler is documented by its subsystem item; §6.1 covers only the table |
| Zone side of 0x441C / 0x441D and client side of 0x0849 / 0x10D9 | Z08 §3.4 (0x441C / 0x441D → 0x441E); §2.2 and §4.7 here (client handlers) | already documented |
| `"0.0.0.0"` zone rows vs the 0x0802 IP check; W05-B15 `len` | X02 (plan: "turn whatever static reading cannot settle into concrete capture scenarios") | needs a live zone registration or capture, not more reading |
| W01 statements this item corrects (listener order, CharDB loss, `fc_dummyfunction` return, blob sizes, names) | `docs/knowledge/W05.md` §1 "Corrections" (for X01) | W01 is done; corrections go to the knowledge file, which X01 collects |
