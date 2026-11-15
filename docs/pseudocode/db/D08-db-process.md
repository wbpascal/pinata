# DB servers: process layer and shared-class copies (D08)

Account, AccountLog, Character and GameLog are four builds of one "DataServer" program. D01–D05 describe their packet
handlers; this document describes what is under them: start-up, Windows service, main thread, sessions, session
workers, the linked library and data classes, the Character server's SOAP item-shop client, and the open points of
D01 / D02.

Sources: `Files/Server/2016/{Account,AccountLog,w00_Character,w00_GameLog}/* Release.exe`. Account and AccountLog are
read in the PDB exports (`re-data/exports/account-pdb`, `accountlog-pdb`; names and member names *(pdb2016)*, from
`Files/Server/NA2016/{Account,AccountLog}/*.pdb`). Character and GameLog have no PDB: their functions are matched to
the Account ones by identical decompiled body (`python3 -I docs/plan/status/D08-match.py account <bin> [lo hi]`:
variable names, addresses and string labels normalised, everything else must be equal), and the official names are in
`tools/protocol-re/names/{character,gamelog}/D08.json`. View code with
`python3 -I tools/protocol-re/clean.py re-data/exports/account-pdb - <addr>`.

Evidence markers as in `AGENTS.md`. "Same as" means the decompiled body is identical to the cited build's function
(checked with the same script against `wm-pdb`, `login-pdb`, `zone-pdb`); only the addresses are new.

Corrections to D01 / D05 (done items, not edited): `docs/knowledge/D08.md` §0.

## 1. The DataServer process (Account build as reference)

D05 §7 reconstructs the same framework from the GameLog binary under our own names. This section gives the official
names, the object layout, and what D05 does not say or says differently. The address table of §1.6 maps every function
to all four builds.

### 1.1 Objects

```
DataServer gServer   (Account DAT_0044b308, AccountLog DAT_004461a8, GameLog DAT_0044d188; size 0x209a68)   (pdb2016)
  +0x0000   CServerInfo m_ServerInfo          config rows (Z19 §5.3)
  +0x04f8   MY_SERVER   m_MyServer            pServiceName, pDisplayName, nServerID (+0x500), nWorldNo, nZoneNo
  +0x050c   char[16]    m_ConnectSocket_BindIP   zeroed by the ctor, filled by `ReadDefineScriptor`, never read in Account; the Character server binds its GameLog connect to it (§4.3)
  +0x051c   CIOCP       m_IOCP_For_Socket     S02 §1.3
  +0x054c   CSession_Manager m_SocketSessionManager      §1.4 (contains the acceptor at +0x558)
  +0x9838   CSessionWorkerManager m_SessionWorkerManager §1.5 (2 MB job queue)
  +0x209890 int m_bOnStopService              set to 1 by OnStart_Service, never cleared
  +0x209894 / +0x2098a4  SYSTEMTIME m_ServerStartTime / m_ServerStopTime
  +0x2098b4 int m_bStopMainThread             the stop request; the main thread polls it every second
  +0x2098b8 int m_bActiveMainThread
  +0x2098bc / +0x2098c0  m_hMainThread, m_MainThreadID
  +0x2098c4 int m_NumOfIndunMap; +0x2098c8 SHINE_INDUN_INFO[32] m_IndunMapList   zeroed by the ctor, no other access in Account
```

`gServer` is built by the CRT before `WinMain` (`_dynamic_initializer_for_'gServer'` FUN_004317e0 →
`DataServer::DataServer` FUN_00401850 + `atexit`) and destroyed at process exit (`_dynamic_atexit_destructor_for_'gServer'`
FUN_00431c40 → `DataServer::~DataServer` FUN_00401020: the indun list, the worker manager (stops the workers), the
session manager, `CIOCP::Close`, the `CCsl` base of `CServerInfo`).

### 1.2 Start-up and the Windows-service shell

```pseudo
WinMain(hInst, hPrev, cmdLine, show):                                         @ FUN_00401fc0
    MiniDumper()                                   # SetUnhandledExceptionFilter(TopLevelFilter), W05 §6.3
    r = DataServer::Start(&gServer, cmdLine); log "< END OF MAIN = %d >" r; return r

DataServer::Start(this, cmdLine):                                             @ FUN_00401d20
    chdir(directory of GetModuleFileName)          # all config / 9Data paths are relative to the exe (Z19 §5.4)
    log "-----…", _ExecUpdateInfoMsg("-"), "Launching the server.....", "-----…"
    ViewStartInfo(this)                            # FUN_004010e0: local and UTC start time, same as L01 §1.2
    if !ReadDefineScriptor(this): return −1        # FUN_00401360, D01 §1 (DataServerInfo_Account.txt)
    if m_MyServer.nServerID == 2:                  # 2 = Character DB; never true in Account / AccountLog (ids 0 / 1)
        if !MapDataBox::CheckReadData(&mapdatabox, "../../9Data/Shine/MapInfo.shn")
           and !CheckReadData(&mapdatabox, "../9Data/Shine/MapInfo.shn"):
            log "*FAILED GLOBAL GAME DATA READ - MapInfo.shn"; return −4
    if !ParseCmd(this, cmdLine): return −2         # below
    Singleton<WinService>::getInstance()           # inlined FUN_004017d0
    WinService::startDispatcher(m_MyServer.pServiceName, ::OnStart_Service FUN_00402030, ::OnStop_Service FUN_00402040)
    return 0                                       # also when the dispatcher failed (not started by the SCM)
```

Unlike GameLog (D05 §7.1, which loads ItemInfo here) the Account build loads no game table in `Start`; its ItemInfo copy
is loaded by a static constructor (§2, part 2).

`DataServer::ParseCmd` FUN_00401920 is the WM / Login `ParseCmd` (W05 §1.1, L01 §1.8) with other texts: up to 5 tokens of
the command line; none and `queryServiceStatus` succeeds → code 0; none and the service is not installed → "UPLOAD";
"UPLOAD" → `uploadService` (1 ok / 2 failed), "REMOVE" → `removeService` (3 / 4), other → 5; the singleton is deleted;
texts "Service start(no parameter)", "Service upload only ok.", "Service upload failed.", "Service remove ok.",
"Service remove failed.", "Service unknown command."; codes 1–5 log the text, show `MessageBoxA(text, pDisplayName)` and
return false. The service shell (`WinService::*`, `Singleton<WinService>::getInstance`) and `MiniDumper` are identical to
the WM's, so W05-B22 (`removeService` always true), W05-B23 (`startDispatcher` self-assignment, empty service name) and
W05-B24 (`onServiceStop` closes the event handle only when it is invalid) hold for all four DB servers.

```pseudo
DataServer::OnStart_Service(this):   (WinService::onServiceStart → ::OnStart_Service)   @ FUN_00401f10
    m_bOnStopService = 1
    n = CIOCP::Start(&m_IOCP_For_Socket, 5 × CPU count, wait = 1)   # S02 §1.3; Login / WM start 2 × CPU
    log "<NUMBER OF %d IOCP WORKTHREAD STARTED, %d CPU DETECTED>"
    if n != 5 × CPU: return false
    m_SessionWorkerManager.m_PacketQueSize = 0
    if !CSessionWorkerManager::Start(-1, wait = 1): return false      # §1.5: min(10 × CPU + 1, 81) workers, one DB link each
    if !Start_Acceptor(this): return false                           # below
    if !Start_MainThread(this): return false                         # FUN_00401ca0, same as L01 §1.2 ("*FAILED CREATE MAIN THREAD*")
    log "SERVER WORK START ---…"; return true
    # false: onServiceStart returns before RUNNING; already started IOCP threads and workers keep running and the
    # service stays START_PENDING (D05-B10, all four servers)

DataServer::Start_Acceptor(this):                                             @ FUN_00401500
    row = CServerInfo::GetServerInfo(nServerID, nWorldNo, nZoneNo)            # SERVER_INFO row of this server (Z19 §5.3)
        none → "FATAL ERROR - Can't found ServerInfo on funcition 'DataServer::Start_Acceptor()', need check scriptor data."; 0
    CSocket_Session_Manager::InitSessions(&m_SocketSessionManager, &m_IOCP_For_Socket, row.nMaxAccept, 0, 0)   # §1.4
        fails → "*FAILED SESSION MANAGER INIT*"; 0          (only with a null IOCP: cannot happen)
    log "<SUCCESSED SESSION MANAGER INIT>"
    ok = row.pIP == "" ? CSocket_Acceptor::Listen(port, backlog)          # FUN_004102a0: first address of the host
                       : CSocket_Acceptor::Listen(ip, port, backlog)       # FUN_00410200
    !ok → "*FAILED START LISTEN SOCKET*"; 0
    return 1
```

2016 `9Data/ServerInfo/ServerInfo.txt` rows (name, type, world, zone, –, ip, port, backlog, `nMaxAccept`): `PG_AccDB` 0 /
port 9000, `PG_ALDB` 1 / 9311, `PG_W00_CDB` 2 / 9411, `PG_W00_GLDB` 3 / 9511, all `"0.0.0.0"`, backlog 100, 100 sessions
(X03 knowledge §4.1 for the whole file).

### 1.3 Main thread and the three ways to stop

```pseudo
DataServer::MainThread(this):                                                 @ FUN_00401620
    log "<MAIN THREAD START>"; m_bActiveMainThread = 1
    while m_bStopMainThread == 0:
        Sleep(1000)
        CSession_Manager::ProcHeartBeat(&m_SocketSessionManager)              # §1.4: the only periodic work of the process
    CSocket_Acceptor::Stop(listener)               # "<SUCCESSED STOP LISTEN SOCKET>" / "*FAILED STOP LISTEN SOCKET*"
    CSessionWorkerManager::Stop(-1)                # waits for every worker; "<SESSION WORKER ALL STOPPED>"
    CSocket_Session_Manager::DissconnectSessions   # shutdown + closesocket on every active session; "<SESSION DISCONNECTED>"
    CIOCP::Close                                   # "<IOCP CLOSED>"
    CSocket_Session_Manager::CloseSessions         # all sessions freed; "<SESSION CLOSED>"
    ViewStopInfo(this)                             # FUN_00401220; "<MAIN THREAD STOP>"
    m_bActiveMainThread = 0
    if m_bOnStopService != 0: log "<SERVER MANUAL STOPPED>"; return 0
    log "<SERVER SELF STOPPED>"; exit(0)           # dead: OnStart_Service sets m_bOnStopService before the thread exists

DataServer::OnStop_Service(this):   (WinService::onServiceStop → ::OnStop_Service)       @ FUN_004010b0
    m_bStopMainThread = 1; while m_bActiveMainThread != 0: Sleep(5)
```

There is no timer and no periodic job other than the heartbeat check: all work is packet-driven (the workers, §1.5).

Writers of `m_bStopMainThread`:

| Writer | Effect |
|---|---|
| `DataServer::OnStop_Service` (service STOP / SHUTDOWN) | main thread tears down, then `onServiceStop` reports STOPPED; clean stop |
| `CPFs::fc_NC_OPTOOL_CLOSE_SERVER_REQ` FUN_00404fc0 (0x2803, D01 §2; AccountLog FUN_00404880; GameLog FUN_00409360, D05 §5) | replies 0x2804 `{u16 0x0600}`, then `gServer.m_bStopMainThread = 1` |

D01 calls the flag of 0x2803 `g_Shutdown (DAT_00654bbc)` and D05 says its copy (`DAT_00656a3c`) is never read
(D05-B7). Both addresses are `gServer + 0x2098b4` (0x0044b308 + 0x2098b4 = 0x00654bbc; GameLog 0x0044d188 + 0x2098b4 =
0x00656a3c, `mov ecx, 0x44d188` before `DataServer::Start` in GameLog's `WinMain` FUN_004020b0), i.e.
`m_bStopMainThread`. An OPTool close **does** stop the server: within a second the listener, the workers, every link
and the IOCP are gone. The main thread then takes the `<SERVER MANUAL STOPPED>` branch and returns, but nothing reports
it to the service manager: the process keeps running as a RUNNING service with no listener and no worker until an
operator stops the service **(original bug) D08-B2**. The handler has no `CheckAlive` (D01 §2), so any peer that can
connect, even before the 0x0802 handshake, can do this (D05-B7's "no authentication" part stands).

### 1.4 Sessions, accept and receive (the older session framework)

The DB servers do not use the WM / Login session pools (S02 §1.4 `CSocket_Acceptor` ring, W05 §4). They link an older
pair `CSocket_Session_Manager` / `CSocket_Session` that S02 does not cover; D05 §7.2 describes its GameLog copy. The
accept ring members of `CSocket_Acceptor` (`m_ListenArray[10]`, `m_AcceptedRing[1300]`) exist in the class (the ctor
FUN_0040fee0 is the WM's) but the old accept thread uses only `m_ListenSocket`.

```
CSocket_Session_Manager (0x92dc)                     CSession_Manager : CSocket_Session_Manager (0x92ec)
  vtbl slots: 0 MakeAEmptySession, 1 DeleteEmptySession, 2 ActiveSession(sock, addr), 3 InactiveSession(node)
  +0x0004 m_bInit, +0x0008 m_pIOCP
  +0x000c CSocket_Acceptor m_Acceptor (0x928c)       +0x92dc CIOCP_Process_Manager_App m_IOCP_Process
  +0x9298 m_MaxSessions, +0x929c m_NumSessions       +0x92e4 CSocket_Acceptor_Process_Manager_App m_Acceptor_Process
  +0x92a0 m_pActiveSessions, +0x92a4 m_pEmptySessions (doubly linked CSM_SESSION_LIST {bActived, pLinkUp, pLinkDown, pSocketSession})
  +0x92c0 m_CSM_Critical_Section (recursive Windows CS), +0x92d8 m_bCMS_OK
CSession : CSocket_Session (0x154): fields as D05 §7.2, names (pdb2016): +0xdc m_Connection, +0xe0 m_Connected_Server_ID
  (−1 until 0x0802), +0xe4 m_Connected_World, +0xe8 m_Connected_Zone, +0xec m_Connected_Time, +0xfc m_LastReceiveTime,
  +0x100 m_LastSendTime, +0x104 m_Last_PacketCommand, +0x108 m_Last_PacketLength, +0x10c m_Last_PacketWorkType,
  +0x110 m_LastHeartBeatSendTime, +0x114 m_Send_CS, +0x12c m_Close_IOCP_Process, +0x134 m_Overlapped_Close
CSocket_Session (0xdc): +0x04 m_IOCP_Process_Socket_Session, +0x08 CSocket_IOCP m_SocketIOCP (S02 §1.5), +0xbc CPacket m_Packet
  (S02 §1.7), +0xd4 m_Packet_Parser, +0xd8 m_Socket_Session_Parser
```

```pseudo
CSocket_Session_Manager::InitSessions(iocp, max, iocpProcess, acceptProcess):         @ FUN_00410930
    iocp null → return 0
    first call: InitializeCriticalSection; m_bCMS_OK = m_bInit = 1
    max != m_MaxSessions → AllActiveToEmpty (slot 3 on every active node, FUN_004104f0) and AllEmptyToFree
                           (slot 1 on every empty node, FUN_004107a0)
    max > 0: replace the process hooks if given; create max sessions with vtbl slot 0 and push them on the empty list
             (CSession_Manager::MakeAEmptySession FUN_00405ba0: new CSession 0x154 + node 0x10; the read / write / close
             OVERLAPPEDs point to m_IOCP_Process = CIOCP_Process_Manager_App, so completions reach CSession::IOCP_Process)
    return 1                                       # sessions are created once; the pool never grows

Accept thread  CSocket_Acceptor::AcceptThread(acceptor):                               @ FUN_0040fda0
    m_bActiveAcceptThread = 1
    until m_bAcceptThreadStop:
        select({m_ListenSocket}, timeout m_Listen_TimeOut = {0, 0})   # a poll: the ctor sets 0 s, nothing changes it
        error  → log "*Listen Socket Error!*"; Sleep(10)
        not readable, or accept fails → Sleep(10)
        accepted → m_Acceptor_Process.Accept_Process(sock, addr)
                     → CSocket_Acceptor_Process_Manager_App::Accept_Process FUN_00405ea0 (forwards to +0x92a8)
                     → CSocket_Acceptor_Process_Manager::Accept_Process FUN_00410450:
                         session manager slot 2 (CSession_Manager::ActiveSession) == null → shutdown + closesocket; return 1
                   result 0 → log "*Accept_Process Error!*", closesocket      # unreachable: the chain always returns 1
                   Sleep(1)
    m_bActiveAcceptThread = 0
    # accept latency up to 10 ms; one thread, one listen socket

CSocket_Acceptor::Listen(ip, port, backlog):                                          @ FUN_00410200
    Initialize(ip, port, backlog):                                                     @ FUN_0040ffd0
        close an old listen socket, stop an old accept thread; WSAStartup 2.2 (InetAddress::WinSockStart FUN_00414090)
        socket(AF_INET, SOCK_STREAM); SO_REUSEADDR; FIONBIO (non-blocking); bind(inet_addr(ip), port); listen(backlog);
        getsockname → m_ListenSocketAddr; any failure → WSACleanup, return 0
    Start_AcceptThread(): CreateThread(AcceptThread), wait (5 ms steps) until it runs    @ FUN_00410150
    log "<SUCCSSED LISTEN AT IP=%s, Port=%d, BacklogCount=%d >"
Listen(port, backlog) @ FUN_004102a0: ip = InetAddress::GetHostAddress() FUN_00414100 (gethostname → gethostbyname →
    first address); none → "ERROR - FAILED TO GET LISTEN SOCKET IP ADDRESS"
CSocket_Acceptor::Stop FUN_0040ff60: same as the WM's (S02 §1.4)

CSession_Manager::ActiveSession(sock, addr):   (slot 2)                                @ FUN_00405c80
    under the list lock:
    node = CSocket_Session_Manager::ActiveSession(sock, addr)                           @ FUN_004108f0
        GetNewActiveSession FUN_00410850: m_NumSessions < m_MaxSessions and an empty node → CPacket::Clear, EmptyToActive
            (FUN_004105f0: unlink from the empty list, push on the active list, m_NumSessions++); else log
            "* ACCEPT NO SESSION BUFFER - ERROR *" once (static flag bViewNoAcceptSession, re-armed by the next success)
        store socket and peer address
    none → return null
    s.m_Connection = 0; s.m_LastReceiveTime = now; s.m_LastHeartBeatSendTime = 0
    CSocket_Session::Socket_Register_To_IOCP(s, iocp) FUN_00412d00: CIOCP::Register(socket) and the first
        CSocket_IOCP::Receive into m_Packet ("ERROR - Socket_Register_To_IOCP Step #1|#2, Socket=%d, %s")
        fails → ActiveToEmpty (FUN_00410550); log "* ACCEPT SOCKET IOCP REGISTER - ERROR *"; return null
    CSession::Send_NC_MISC_S2SCONNECTION_RDY(s) FUN_00405aa0: raw frame {02 01 08} = 0x0801 under m_Send_CS
        fails → ActiveToEmpty; "* NC_MISC_S2SCONNECTION_RDY - SEND ERROR *"; return null
    return node
    # the socket of a refused session is closed by the caller; the session object is never reset beyond these fields
    # and CPacket::Clear: m_Connected_Server_ID / World / Zone keep the previous peer's values until 0x0802 (§1.5 note)

Completion  CIOCP_Process_Manager_App::IOCP_Process(ov, bytes):                         @ FUN_00405e60
    CSession::IOCP_Process(node.session, ov, bytes) == 0 → session manager slot 3 (InactiveSession); return 1
    IOCP_CloseProcess FUN_00405ec0 (failed completion): slot 3 directly
CSession::IOCP_Process(ov, bytes):                                                     @ FUN_00405790
    READ:  m_LastReceiveTime = now; bytes 0 → Close; return 0
           used += bytes; PacketStroe (below) fails → Close; return 0
           free = CPacket::GetWriteableBufferSize; free ≤ 0 → log "ERROR - Socket buffer full, some protocol too large
           then socket buffer size."; Close; return 0
           CSocket_IOCP::Receive(the free tail); return 1
    WRITE: m_LastSendTime = now; CSocket_IOCP::WriteCallback (S02 §1.5); return 1
    CLOSE (posted by SocketCloseUseIOCP FUN_00405610): Close; return 0
    # Close = CSocket_Session::Close FUN_00412c60 = CSocket_IOCP::Shutdown + Close (S02 §1.5)
CSession::PacketStroe(rx):                                                             @ FUN_00405630
    while CPacket::IsValidPacket(rx) == 1:          # framing S02 §1.7
        while CSessionWorkerManager::AddQue(&gServer.m_SessionWorkerManager, s, frame, frameSize) == 0: Sleep(2)
        CPacket::TakeNextPacket(rx)
    == 2 (bad frame) → log "패킷 오류 확인 From (…)" ("packet error"); return 0 (the link is closed)
    CPacket::RemoveAllUsedPacket(rx); return 1
    # the IOCP thread blocks while the queue is full: back-pressure on every link of the process

CSession_Manager::InactiveSession(node):   (slot 3)                                    @ FUN_00405d60
    under the list lock: m_Connection != 0 → log "Closed    from %p (…) (% 3d/% 3d개) (DEP=%d,CMD=%d,LEN=%d,WORK=%d)"
    CSocket_Session_Manager::InactiveSession FUN_00410690 → ActiveToEmpty (back on the empty list, LIFO)

CSession_Manager::ProcHeartBeat():   (main thread, every second)                       @ FUN_00405b40
    under the list lock, every active session with m_Connection == 1:
        CSession::CheckHeartBeat(s) == 0 → CSession::SocketCloseUseIOCP(s)            # posts the CLOSE completion
CSession::CheckHeartBeat(s):                                                           @ FUN_00405970
    now − m_LastReceiveTime < 30 000 ms → m_LastHeartBeatSendTime = 0; return 1
    m_LastHeartBeatSendTime == 0 → = now; Send 0x0804 NC_MISC_HEARTBEAT_REQ {} (CSendPacket, under m_Send_CS); return the send result
    now − m_LastHeartBeatSendTime ≥ 180 000 ms → log "ERROR - HEARTBEAT OVERTIME, NOW DISSCONNECT WITH %s"; return 0
    return 1
```

All of this is the D05 §7.2 behaviour (D05-B9: unauthenticated links are never timed out, all four builds). New here: the
pool is fixed at `nMaxAccept` sessions created at start; freed sessions go to the head of the empty list and are reused
first; the default handlers of the base classes, `CIOCP_Process_Socket_Session::IOCP_Process` FUN_00412e00 (read → parse
with the default parser and discard; write → WriteCallback), `CPacket_Parser_Socket_Session::Parser` FUN_00412ec0 (walk
and drop every frame), `CIOCP_Process_Manager::IOCP_Process` FUN_004103f0 and `CSocket_Session_Manager::MakeAEmptySession`
FUN_00410340 (plain 0xdc-byte `CSocket_Session`), are overridden by the `CSession_Manager` / `CSession` slots and never run.

### 1.5 Session workers and the job queue

```
CSessionWorkerManager (0x200058, gServer+0x9838):  +0x0 m_bManualRead, +0x4 m_PacketQueSize, +0x8 u8 m_PacketQue[0x200000],
    +0x200008 CPacket m_Packet (a frame reader pointed into the queue), +0x200020 m_pPacketBufferSave, +0x200024 m_BF_CS,
    +0x20003c m_NumOfWorkThread, +0x200040 m_pWorkThreads (SESSION_WORKER[n] = {CSessionWorker*}), +0x200044 m_ActiveWorker,
    +0x200048 u64 m_JobIndexSrt, +0x200050 u64 m_JobIndexEnd
CSessionWorker : CSocket_Session (0x1268): +0xdc…+0x10c the CSession fields (copied per job), +0x110 m_WorkerID,
    +0x114 m_WorkerStatus (NONE 0, STARTING 1, ACTIVE 2, STOPPING 3, STOPPED 4), +0x118 m_bJob, +0x120 u64 m_JobIndex,
    +0x128 m_pWorkerManager, +0x12c m_ActiveWorker, +0x130 m_hThread, +0x134 m_ThreadID,
    +0x138 CParserAccount m_Parser (the handler table; its +0x8 = session of the current job), +0x124c CGameDB_Account m_DBF
Queue record: {CSession* session; frame bytes (size byte or 0 + u16, opcode, payload)}
```

```pseudo
CSessionWorkerManager::Start(count, wait):                                             @ FUN_004068b0
    Stop(-1); job counters = 0
    count == −1 → count = min(10 × CPU + 1, 81)
    m_pWorkThreads = new SESSION_WORKER[count]; m_ActiveWorker = 1
    for i in 0 … count−1:
        w = new CSessionWorker (0x1268; ctor FUN_004063a0: CSocket_Session base, CParserAccount table (D01 §3), DB object)
        w.m_JobIndex = i; slot i = w; w.m_Parser.+4 = w
        CSessionWorker::Start(w, this, i, wait) FUN_00406210:
            m_WorkerID = i; m_WorkerStatus = STARTING; CreateThread(SessionWorkThread)
            wait: spin (5 ms) while STARTING; ok only if ACTIVE (the DB connected)
        fails → Stop(-1); return 0
    log "<NUMBER OF %d SESSION WORKER STARTED>"; return count

CSessionWorker::SessionWorkThread(w):                                                  @ FUN_00406010
    m_ActiveWorker = 1
    DB_Init(w) fails (FUN_00405f20, D01 §1) → m_WorkerStatus = STOPPED; "<SESSION WORKER #%d INIT DB FAILED - STOP ******>"; return
    m_WorkerStatus = ACTIVE
    while m_WorkerStatus == ACTIVE:
        GetJobA(manager, w) == 0 → Sleep(2); continue
        ok = m_Parser.vtbl[0](&w.m_Packet)          # the parser dispatch (D05 §7.2 CParser_Dispatch, W05 §6.1 table)
        !ok and job session.m_Connection != 0 → log "*Work failed   (%-25s world=%3d zone=%3d, …) (DEP=%d,CMD=%d,LEN=%d,WORK=%d, WorkerID=%d)"
        m_bJob = 0
    CGameDB_Connect::DBClose(&m_DBF); "<SESSION WORKER #%d FREE>"; m_WorkerStatus = STOPPED; m_ActiveWorker = 0

CSessionWorkerManager::GetJobA(w):   (under m_BF_CS)                                   @ FUN_00406780
    m_PacketQueSize < 6 → return 0
    point m_Packet at the first record's frame; r = m_Packet.IsValidPacket()
    r == 1: copy the frame into w's receive CPacket, w.m_Parser.+8 = record.session, w.m_bJob = 1,
            DelQue(frameSize + 4) FUN_00406710 (memmove the rest down), m_JobIndexSrt++, w.m_JobIndex += m_NumOfWorkThread;
            return 1
    r == 2: CSocket_IOCP::CloseUseIOCP(record.session); return 0     # unreachable: PacketStroe queues only valid frames
    return 0
    # the job indices are counted but never compared: any idle worker takes the head record

CSessionWorkerManager::AddQue(session, frame, n):   (IOCP thread, under m_BF_CS)       @ FUN_004066a0
    if m_PacketQueSize + 4 + n ≤ 0x200000:
        append {session, frame}; m_PacketQueSize += n + 4
        return 0x200000 − m_PacketQueSize           # the space left
    return 0                                       # full
```

`AddQue` returns the space left after a successful append, which is 0 when the record exactly fills the 2 MB queue;
`PacketStroe` takes 0 for "full" and appends the same frame again once a worker has made room, so that packet is handled
twice **(original bug) D08-B1** (needs a backlog of exactly 2 MB, i.e. the workers or the database stalled; any request,
e.g. a login check answered twice, a log row written twice).

The queue is one FIFO for all links, drained by up to 81 threads at once: two frames of the same link can run
concurrently on two workers and finish in any order *(inferred from the code: no per-session lock or ordering)*. Each
record holds a raw `CSession*`; when that link closes and the pooled session is reused by a new connection (LIFO, §1.4)
before a worker reaches the record, the handler runs against the new link: its reply goes to the new peer, and a 0x0802
handshake handled that way authenticates the new link with the old peer's identity **(original bug) D08-B3** *(inferred:
needs a close and a reconnect inside the queue latency)*.

```pseudo
CSessionWorkerManager::Stop(id):   (id −1 = all)                                       @ FUN_004064d0
    nothing active → return
    repeat: ACTIVE → STOPPING; STARTING / STOPPING → wait; STOPPED → NONE
            until every worker is NONE (Sleep 2 ms between passes; with one id, one pass only)
    FreeWorker FUN_00406450 (delete the workers, CSessionWorker dtor FUN_00406300: Stop, DB object, handler rows, base);
    m_ActiveWorker = 0
CSessionWorker::Stop FUN_00405fb0: the same loop for one worker (used by its destructor)
~CSessionWorkerManager FUN_00406620: Stop(-1), FreeWorker, restore m_Packet's buffer pointer, DeleteCriticalSection
CParserAccount::~CParserAccount FUN_004062c0: frees the allocated handler rows (pft table, W05 §6.1)
```

A stopping worker finishes the job in hand; records still queued at stop are dropped (the queue is not drained).

### 1.6 Address table of the process layer

Same function in all four builds, matched by identical body (§ intro). "–" = the body differs in that build (an
AccountLog / Character / GameLog variant; §3.6, §4.7 and part 7 of D08 give those). Several addresses = identical-code
folds in that build.

| Function *(pdb2016)* | Account | AccountLog | Character | GameLog | Documented at |
|---|---|---|---|---|---|
| `CServerInfo::~CServerInfo` | FUN_00401000 | FUN_00401000 | FUN_0043ed60 | FUN_00401000 | Z19 §5.3 |
| `DataServer::~DataServer` | FUN_00401020 | – | – | – | §1.2–§1.3 |
| `DataServer::OnStop_Service` | FUN_004010b0 | – | – | FUN_004010c0 | §1.2–§1.3 |
| `DataServer::ViewStartInfo` | FUN_004010e0 | – | – | FUN_004010f0 | §1.2–§1.3 |
| `DataServer::ViewStopInfo` | FUN_00401220 | – | – | FUN_00401230 | §1.2–§1.3 |
| `DataServer::ReadDefineScriptor` | FUN_00401360 | – | – | – | §1.2–§1.3 |
| `DataServer::Start_Acceptor` | FUN_00401500 | FUN_00401520 | FUN_00401bb0 | FUN_004015b0 | §1.2–§1.3 |
| `DataServer::MainThread` | FUN_00401620 | – | – | FUN_004016d0 | §1.2–§1.3 |
| `Singleton<WinService>::getInstance` | FUN_004017d0 | FUN_004017f0 | FUN_00401ea0 | FUN_00401880 | §1.2; W05 §6.3 |
| `DataServer::DataServer` | FUN_00401850 | – | – | – | §1.2–§1.3 |
| `DataServer::ParseCmd` | FUN_00401920 | FUN_00401960 | FUN_00402040 | FUN_004019e0 | §1.2–§1.3 |
| `DataServer::Start_MainThread` | FUN_00401ca0 | – | – | FUN_00401d60 | §1.2–§1.3 |
| `DataServer::Start` | FUN_00401d20 | FUN_00401d60 | – | – | §1.2–§1.3 |
| `DataServer::OnStart_Service` | FUN_00401f10 | – | – | – | §1.2–§1.3 |
| `WinMain` | FUN_00401fc0 | FUN_00402060 | FUN_00402930 | FUN_004020b0 | §1.2–§1.3 |
| `PROTOCOLFUNCTIONTEMPLETE<CPFs>::~PROTOCOLFUNCTIONTEMPLETE` | FUN_00403530 | FUN_00403780 | FUN_00431130 | FUN_00407aa0 | W05 §6.1; D05 §7.2 |
| `PROTOCOLFUNCTIONTEMPLETE<CPFs>::pft_Store` | FUN_00403560 | FUN_004037b0 | FUN_00431160 | FUN_00407ad0 | W05 §6.1; D05 §7.2 |
| `PROTOCOLFUNCTIONTEMPLETE<CPFs>::`scalar_deleting_destructor'` | FUN_00403630 | FUN_00403880 | FUN_00431500 | FUN_00407ba0 | W05 §6.1; D05 §7.2 |
| `CIOCP_Process_Interfece::IOCP_CloseProcess` | FUN_00405580 | FUN_00404e60, FUN_0040e270, FUN_00411b60, FUN_00411d50 | FUN_0044ee40, FUN_0044f130, FUN_0046f1f0, FUN_0046f750 | FUN_00412c90, FUN_004157a0, FUN_00415f50, FUN_004183c0 | S02 §1.1 |
| `CIOCP_Process::~CIOCP_Process` | FUN_00405590 | FUN_00404e70 | FUN_0043d5e0 | FUN_00409930 | S02 §1.1 |
| `CSession::Send` | FUN_004055a0 | FUN_00404e80 | FUN_0043d5f0 | FUN_00409940 | §1.4; D05 §7.2 |
| `CSession::Send` | FUN_004055d0 | FUN_00404eb0 | FUN_0043d620 | FUN_00409970 | §1.4; D05 §7.2 |
| `CSession::SocketCloseUseIOCP` | FUN_00405610 | FUN_00404ef0 | FUN_0043d660 | FUN_004099b0 | §1.4; D05 §7.2 |
| `CSession::PacketStroe` | FUN_00405630 | FUN_00404f10 | FUN_0043d680 | FUN_004099d0 | §1.4; D05 §7.2 |
| `CSession::IOCP_Process` | FUN_00405790 | FUN_00405070 | FUN_0043d7e0 | FUN_00409b30 | §1.4; D05 §7.2 |
| `CSession::CSession` | FUN_00405860 | FUN_00405140 | FUN_0043d8b0 | FUN_00409c00 | §1.4; D05 §7.2 |
| `CSession::CheckHeartBeat` | FUN_00405970 | FUN_00405250 | FUN_0043d9f0 | FUN_00409d10 | §1.4; D05 §7.2 |
| `CSession::Send_NC_MISC_S2SCONNECTION_RDY` | FUN_00405aa0 | FUN_00405380 | FUN_0043db20 | FUN_00409e40 | §1.4; D05 §7.2 |
| `CSession::`scalar_deleting_destructor'` | FUN_00405ae0 | FUN_004053c0 | FUN_0043db60 | FUN_00409e80 | §1.4; D05 §7.2 |
| `CSession_Manager::~CSession_Manager` | FUN_00405b20 | FUN_00405400 | FUN_0043dba0 | FUN_00409ec0 | §1.4; D05 §7.2 |
| `CSession_Manager::ProcHeartBeat` | FUN_00405b40 | FUN_00405420 | FUN_0043dbc0 | FUN_00409ee0 | §1.4; D05 §7.2 |
| `CSession_Manager::MakeAEmptySession` | FUN_00405ba0 | FUN_004054e0 | FUN_0043dc80 | FUN_00409f40 | §1.4; D05 §7.2 |
| `CSession_Manager::DeleteEmptySession` | FUN_00405c50 | FUN_00405590 | FUN_0043dd30 | FUN_00411440 | §1.4; D05 §7.2 |
| `CSession_Manager::ActiveSession` | FUN_00405c80 | FUN_004055c0 | FUN_0043dd60 | FUN_00409ff0 | §1.4; D05 §7.2 |
| `CSession_Manager::InactiveSession` | FUN_00405d60 | FUN_004056a0 | – | FUN_0040a0d0 | §1.4; D05 §7.2 |
| `CIOCP_Process_Manager_App::IOCP_Process` | FUN_00405e60 | FUN_004057a0 | FUN_0043df70 | FUN_0040a1d0 | §1.4; D05 §7.2 |
| `CSocket_Acceptor_Process_Manager_App::Accept_Process` | FUN_00405ea0 | – | – | – | §1.4; D05 §7.2 |
| `CIOCP_Process_Manager_App::IOCP_CloseProcess` | FUN_00405ec0 | FUN_00405800 | FUN_0043dfd0 | FUN_0040a230 | §1.4; D05 §7.2 |
| `CSession_Manager::CSession_Manager` | FUN_00405ee0 | FUN_00405820 | FUN_0043dff0 | FUN_0040a250 | §1.4; D05 §7.2 |
| `CSessionWorker::DB_Init` | FUN_00405f20 | – | – | – | §1.5 |
| `CSessionWorker::Stop` | FUN_00405fb0 | FUN_00405960 | FUN_0043e0d0 | FUN_0040a320 | §1.5 |
| `CSessionWorker::SessionWorkThread` | FUN_00406010 | – | FUN_0043e130 | FUN_0040a380 | §1.5 |
| `CSessionWorker::Start` | FUN_00406210 | FUN_00405c30 | FUN_0043e330 | FUN_0040a580 | §1.5 |
| `CParserAccount::~CParserAccount` | FUN_004062c0 | FUN_00405ce0 | FUN_0043e3e0 | FUN_00407bf0 | §1.5 |
| `CSessionWorker::~CSessionWorker` | FUN_00406300 | – | – | FUN_0040a630 | §1.5 |
| `CSessionWorker::CSessionWorker` | FUN_004063a0 | – | FUN_0043e4d0 | FUN_0040a6d0 | §1.5 |
| `CSessionWorker::`scalar_deleting_destructor'` | FUN_00406420 | FUN_00405e80, FUN_00413240 | FUN_0043e550, FUN_00440a30, FUN_00452180, FUN_0048ce60 | FUN_0040a750, FUN_00417d70 | §1.5 |
| `CSessionWorkerManager::FreeWorker` | FUN_00406450 | FUN_00405eb0 | FUN_0043e580 | FUN_0040a780 | §1.5 |
| `CSessionWorkerManager::Stop` | FUN_004064d0 | FUN_00405f30 | FUN_0043e600 | FUN_0040a800 | §1.5 |
| `CSessionWorkerManager::CSessionWorkerManager` | FUN_004065e0 | FUN_00406040 | FUN_0043e710 | FUN_0040a910 | §1.5 |
| `CSessionWorkerManager::~CSessionWorkerManager` | FUN_00406620 | FUN_00406080 | FUN_0043e750 | FUN_0040a950 | §1.5 |
| `CSessionWorkerManager::AddQue` | FUN_004066a0 | FUN_00406100 | FUN_0043e7d0 | FUN_0040a9d0 | §1.5 |
| `CSessionWorkerManager::DelQue` | FUN_00406710 | FUN_00406170 | FUN_0043e840 | FUN_0040aa40 | §1.5 |
| `CSessionWorkerManager::GetJobA` | FUN_00406780 | FUN_004061e0 | FUN_0043e8b0 | FUN_0040aab0 | §1.5 |
| `CSessionWorkerManager::Start` | FUN_004068b0 | – | – | FUN_0040abe0 | §1.5 |
| `GetShineServerIDName` | FUN_00406eb0 | FUN_00406a80, FUN_00406aa0 | FUN_00442310, FUN_00442330 | FUN_0040b240, FUN_0040b260 | S02 §2.5 |
| `GetShineServerIDShortName` | FUN_00406ed0 | FUN_00406a80, FUN_00406aa0 | FUN_00442310, FUN_00442330 | FUN_0040b240, FUN_0040b260 | S02 §2.5 |
| `CIOCP::CIOCP` | FUN_0040ebc0 | FUN_0040a220 | FUN_00447180 | FUN_0040e9f0 | S02 §1.3 |
| `CIOCP::Register` | FUN_0040ebf0 | FUN_0040a250 | FUN_004471b0 | FUN_0040ea20 | S02 §1.3 |
| `CIOCP::Stop` | FUN_0040ec30 | – | – | – | S02 §1.3 |
| `CIOCP::WorkThread` | FUN_0040ed60 | FUN_0040a3c0 | FUN_00447320 | FUN_0040eb90 | S02 §1.3 |
| `CIOCP::Close` | FUN_0040ee30 | FUN_0040a490 | FUN_004474e0 | FUN_0040ec60 | S02 §1.3 |
| `CIOCP::Start` | FUN_0040ee50 | FUN_0040a4b0 | FUN_004473f0 | FUN_0040ec80 | S02 §1.3 |
| `GetLastErrorStr` | FUN_0040efe0 | FUN_0040b0a0 | FUN_00447500 | FUN_0040f870 | W05 §6.4 |
| `_DebugMessageNew2` | FUN_0040f1f0 | FUN_0040b2b0 | FUN_00447710 | FUN_0040fa80 | W05 §6.4 |
| `_ExecUpdateInfoMsg` | FUN_0040f380 | FUN_0040b440 | FUN_004478a0 | FUN_0040fc10 | W05 §6.4 |
| `_DebugMessageNew` | FUN_0040f440 | FUN_0040b500 | FUN_00447960 | FUN_0040fcd0 | W05 §6.4 |
| `CServerInfo::CServerInfo` | FUN_0040f580 | FUN_0040b610, FUN_004138f0 | FUN_0043eb40, FUN_004516e0 | FUN_0040fde0, FUN_00417f00 | Z19 §5.3 |
| `CServerInfo::ReadServerInfo` | FUN_0040f590 | FUN_0040b620 | FUN_00449410 | FUN_0040fdf0 | Z19 §5.3 |
| `CServerInfo::GetMyServerInfo` | FUN_0040f5c0 | FUN_0040b650 | FUN_00449440 | FUN_0040fe20 | Z19 §5.3 |
| `CServerInfo::GetServerInfo` | FUN_0040f650 | FUN_0040b6e0 | FUN_004494d0 | FUN_0040feb0 | Z19 §5.3 |
| `CServerInfo::GetServerIndex` | FUN_0040f700 | FUN_0040b790 | FUN_00449580 | FUN_0040ff60 | Z19 §5.3 |
| `CServerInfo::GetODBCInfo` | FUN_0040f7d0 | FUN_0040b860 | FUN_00449650 | FUN_00410030 | Z19 §5.3 |
| `CServerInfo::GetServerInfo` | FUN_0040f880 | FUN_0040b910 | FUN_00449700 | FUN_004100e0 | Z19 §5.3 |
| `CSocket_Acceptor::AcceptThread` | FUN_0040fda0 | FUN_0040be30 | FUN_0044a410 | FUN_00410df0 | §1.4 |
| `CSocket_Acceptor::CSocket_Acceptor` | FUN_0040fee0 | FUN_0040bf70 | FUN_0044a550 | FUN_00410f30 | §1.4 |
| `CSocket_Acceptor::Stop` | FUN_0040ff60 | FUN_0040bff0 | FUN_0044a5d0 | FUN_00410fb0 | §1.4 |
| `CSocket_Acceptor::Initialize` | FUN_0040ffd0 | FUN_0040c060 | FUN_0044a640 | FUN_00411020 | §1.4 |
| `CSocket_Acceptor::Start_AcceptThread` | FUN_00410150 | FUN_0040c1e0 | FUN_0044a7c0 | FUN_004111a0 | §1.4 |
| `CSocket_Acceptor::~CSocket_Acceptor` | FUN_004101d0 | FUN_0040c260 | FUN_0044a840 | FUN_00411220 | §1.4 |
| `CSocket_Acceptor::Listen` | FUN_00410200 | FUN_0040c290 | FUN_0044a870 | FUN_00411250 | §1.4 |
| `CSocket_Acceptor::Listen` | FUN_004102a0 | FUN_0040c330 | FUN_0044a910 | FUN_004112f0 | §1.4 |
| `CSocket_Session_Manager::CSM_Enter_CS` | FUN_00410300 | FUN_0040c390 | FUN_0044a970 | FUN_00411350 | §1.4 |
| `CSocket_Session_Manager::CSM_Leave_CS` | FUN_00410320 | FUN_0040c3b0 | FUN_0044a990 | FUN_00411370 | §1.4 |
| `CSocket_Session_Manager::MakeAEmptySession` | FUN_00410340 | FUN_0040c3d0 | FUN_0044a9b0 | FUN_00411390 | §1.4 |
| `CIOCP_Process_Manager::IOCP_Process` | FUN_004103f0 | FUN_0040c480 | FUN_0044aa60 | FUN_00411470 | §1.4 |
| `CSocket_Acceptor_Process_Manager::Accept_Process` | FUN_00410450 | FUN_0040c4e0 | FUN_0044aac0 | FUN_004114d0 | §1.4 |
| `CSocket_Session_Manager::DissconnectSessions` | FUN_00410490 | FUN_0040c520 | FUN_0044ab00 | FUN_00411510 | §1.4 |
| `CSocket_Session_Manager::AllActiveToEmpty` | FUN_004104f0 | FUN_0040c580 | FUN_0044ab60 | FUN_00411570 | §1.4 |
| `CSocket_Session_Manager::ActiveToEmpty` | FUN_00410550 | FUN_0040c5e0 | FUN_0044abc0 | FUN_004115d0 | §1.4 |
| `CSocket_Session_Manager::EmptyToActive` | FUN_004105f0 | FUN_0040c680 | FUN_0044ac60 | FUN_00411670 | §1.4 |
| `CSocket_Session_Manager::InactiveSession` | FUN_00410690 | FUN_0040c720 | FUN_0044ad00 | FUN_00411710 | §1.4 |
| `CSocket_Session_Manager::CSocket_Session_Manager` | FUN_004106e0 | FUN_0040c770 | FUN_0044ad50 | FUN_00411760 | §1.4 |
| `CSocket_Session_Manager::AllEmptyToFree` | FUN_004107a0 | FUN_0040c830 | FUN_0044ae10 | FUN_00411820 | §1.4 |
| `CSocket_Session_Manager::GetNewActiveSession` | FUN_00410850 | FUN_0040c8e0 | FUN_0044aec0 | FUN_004118d0 | §1.4 |
| `CSocket_Session_Manager::ActiveSession` | FUN_004108f0 | FUN_0040c980 | FUN_0044af60 | FUN_00411970 | §1.4 |
| `CSocket_Session_Manager::InitSessions` | FUN_00410930 | FUN_0040c9c0 | FUN_0044afa0 | FUN_004119b0 | §1.4 |
| `CSocket_Session_Manager::CloseSessions` | FUN_00410a10 | FUN_0040caa0 | FUN_0044b080 | FUN_00411a90 | §1.4 |
| `CSocket_Session_Manager::~CSocket_Session_Manager` | FUN_00410a50 | FUN_0040cae0 | FUN_0044b0c0 | FUN_00411ad0 | §1.4 |
| `WinService::uploadService` | FUN_00410af0 | FUN_0040cb80 | FUN_0044bda0 | FUN_00411b70 | §1.2; W05 §6.3 |
| `WinService::removeService` | FUN_00410bf0 | FUN_0040cc80 | FUN_0044bea0 | FUN_00411c70 | §1.2; W05 §6.3 |
| `WinService::onServiceStop` | FUN_00410ca0 | FUN_0040cd30 | FUN_0044bf50 | FUN_00411d20 | §1.2; W05 §6.3 |
| `WinService::queryServiceStatus` | FUN_00410d30 | FUN_0040cdc0 | FUN_0044bfe0 | FUN_00411db0 | §1.2; W05 §6.3 |
| `WinService::WinService` | FUN_00410de0 | FUN_0040ce70 | FUN_0044c090 | FUN_00411e60 | §1.2; W05 §6.3 |
| `WinService::`scalar_deleting_destructor'` | FUN_00410e00 | FUN_0040ce90 | FUN_0044c0b0 | FUN_00411e80 | §1.2; W05 §6.3 |
| `WinService::serviceHandler` | FUN_00410e30 | FUN_0040cec0 | FUN_0044c0e0 | FUN_00411eb0 | §1.2; W05 §6.3 |
| `WinService::onServiceStart` | FUN_00410e60 | FUN_0040cef0 | FUN_0044c110 | FUN_00411ee0 | §1.2; W05 §6.3 |
| `WinService::serviceLoop` | FUN_00410f30 | FUN_0040cfb0 | FUN_0044c1d0 | FUN_00411fa0 | §1.2; W05 §6.3 |
| `WinService::startDispatcher` | FUN_00411060 | FUN_0040d0e0 | FUN_0044c300 | FUN_004120d0 | §1.2; W05 §6.3 |
| `String::~String` | FUN_00411120 | FUN_0040d1a0 | FUN_0044c3c0 | FUN_00412190 | W05 §6.3 |
| `String::getBuffer` | FUN_00411140 | FUN_0040d1c0, FUN_0041593e | FUN_0044c3e0, FUN_0048d564 | FUN_004121b0, FUN_0041b9ca | W05 §6.3 |
| `String::makeUpper` | FUN_00411150 | FUN_0040d1d0 | FUN_0044c3f0 | FUN_004121c0 | W05 §6.3 |
| `String::operator=` | FUN_00411160 | FUN_0040d1e0 | FUN_0044c400 | FUN_004121d0 | W05 §6.3 |
| `String::String` | FUN_00411200 | FUN_0040d280 | FUN_0044c4a0 | FUN_00412270 | W05 §6.3 |
| `String::`scalar_deleting_destructor'` | FUN_00411250 | FUN_0040d2d0 | FUN_0044c4f0 | FUN_004122c0 | W05 §6.3 |
| `String::String` | FUN_00411290 | FUN_0040d310 | FUN_0044c530 | FUN_00412300 | W05 §6.3 |
| `String::operator=` | FUN_004112c0 | FUN_0040d340 | FUN_0044c560 | FUN_00412330 | W05 §6.3 |
| `MiniDumper::MinidumpCallStack` | FUN_00411300 | FUN_0040d380 | FUN_0044c5a0 | FUN_00412370 | W05 §6.3 |
| `MiniDumper::TopLevelFilter` | FUN_00411520 | FUN_0040d5a0 | FUN_0044c7c0 | FUN_00412590 | W05 §6.3 |
| `MiniDumper::MiniDumper` | FUN_00411810 | FUN_0040d890 | FUN_0044cab0 | FUN_00412880 | W05 §6.3 |
| `AssertClass::ac_DateTime` | FUN_00411fe0 | FUN_0040e060 | FUN_0044cad0 | FUN_004128a0 | W05 §6.4; D05 §7.4 |
| `AssertClass::ac_AssertFail` | FUN_00412060 | FUN_0040e0e0 | FUN_0044cb50 | FUN_00412920 | W05 §6.4; D05 §7.4 |
| `AssertClass::ac_AssertFail` | FUN_004120b0 | FUN_0040e130 | FUN_0044cba0 | FUN_00412970 | W05 §6.4; D05 §7.4 |
| `ShineExit` | FUN_00412100 | FUN_0040e180 | FUN_0044cbf0 | FUN_004129c0 | W05 §6.4; D05 §7.4 |
| `CSocket_Session::Close` | FUN_00412c60 | FUN_0040e7c0 | FUN_0044cdf0 | FUN_00412c70 | §1.4 |
| `CSocket_Session::Send` | FUN_00412c80 | FUN_0040e7e0 | FUN_0044ce10 | FUN_00412ca0 | §1.4 |
| `CSocket_Session::Send` | FUN_00412cd0 | FUN_0040e830 | FUN_0044ce60 | FUN_00412cf0 | §1.4 |
| `CSocket_Session::Socket_Register_To_IOCP` | FUN_00412d00 | FUN_0040e860 | FUN_0044ce90 | FUN_00412d20 | §1.4 |
| `CIOCP_Process_Socket_Session::IOCP_Process` | FUN_00412e00 | FUN_0040e960 | FUN_0044cf90 | FUN_00412e20 | §1.4 |
| `CPacket_Parser_Socket_Session::Parser` | FUN_00412ec0 | FUN_0040ea20 | FUN_0044d050 | FUN_00412ee0 | §1.4 |
| `CSocket_Session::~CSocket_Session` | FUN_00412f10 | FUN_0040ea70 | FUN_0044d0a0 | FUN_00412f60 | §1.4 |
| `CSocket_Session::CSocket_Session` | FUN_00412f90 | FUN_0040eaf0 | FUN_0044d120 | FUN_00412fe0 | §1.4 |
| `CSocket_Session::`scalar_deleting_destructor'` | FUN_00413020 | FUN_0040eb80 | FUN_0044d1b0 | FUN_00413070 | §1.4 |
| `CIOCP_Process::CIOCP_Process` | FUN_004130b0 | FUN_0040ec10 | FUN_0044ffb0 | FUN_00413100 | S02 §1.1 |
| `CIOCP_Process_Socket::~CIOCP_Process_Socket` | FUN_004130c0 | FUN_0040ec20 | FUN_0044cde0 | FUN_00413110 | S02 §1.1 |
| `CSocket_IOCP::Receive` | FUN_004130d0 | FUN_0040ec30 | FUN_0044b160 | FUN_00413120 | S02 §1.5 |
| `CSocket_IOCP::Shutdown` | FUN_004131f0 | FUN_0040ed50 | FUN_0044b280 | FUN_00413240 | S02 §1.5 |
| `CSocket_IOCP::CloseUseIOCP` | FUN_004132b0 | FUN_0040ee10 | FUN_0044b340 | FUN_00413300 | S02 §1.5 |
| `CSocket_IOCP::FreeBuffer` | FUN_004132d0 | FUN_0040ee30 | FUN_0044b360 | FUN_00413320 | S02 §1.5 |
| `CIOCP_Process_Manager_App::`scalar_deleting_destructor'` | FUN_00413310 | FUN_0040ee70 | FUN_0044b3a0 | FUN_00412f30 | §1.4; D05 §7.2 |
| `CSocket_IOCP::Close` | FUN_00413340 | FUN_0040eea0 | FUN_0044b3d0 | FUN_00413360 | S02 §1.5 |
| `CSocket_IOCP::WriteCallback` | FUN_00413400 | FUN_0040ef60 | FUN_0044b490 | FUN_00413420 | S02 §1.5 |
| `CSocket_IOCP::CSocket_IOCP` | FUN_004135e0 | FUN_0040f140 | FUN_0044b670 | FUN_00413600 | S02 §1.5 |
| `CSocket_IOCP::~CSocket_IOCP` | FUN_004136e0 | FUN_0040f240 | FUN_0044b770 | FUN_00413700 | S02 §1.5 |
| `CSocket_IOCP::Send` | FUN_00413770 | FUN_0040f2d0 | FUN_0044b940 | FUN_00413790 | S02 §1.5 |
| `CPacket::~CPacket` | FUN_00413af0 | FUN_0040f650 | FUN_0044ffc0 | FUN_00413b10 | S02 §1.7 |
| `CPacket::IsValidHeader` | FUN_00413b30 | FUN_0040f680 | FUN_0044fff0 | FUN_00413b40 | S02 §1.7 |
| `CPacket::IsValidPacket` | FUN_00413b70 | FUN_0040f6c0 | FUN_00450030 | FUN_00413b80 | S02 §1.7 |
| `CPacket::GetPacketSize` | FUN_00413bd0 | FUN_0040f720 | FUN_00450090 | FUN_00413be0 | S02 §1.7 |
| `CPacket::GetDataSize` | FUN_00413c10 | FUN_0040f760 | FUN_004500d0 | FUN_00413c20 | S02 §1.7 |
| `CPacket::GetIDPtr` | FUN_00413c30 | FUN_0040f780 | FUN_004500f0 | FUN_00413c40 | S02 §1.7 |
| `CPacket::GetDataPtr` | FUN_00413c40 | FUN_0040f790 | FUN_00450100 | FUN_00413c50 | S02 §1.7 |
| `CPacket::GetPacket` | FUN_00413c50 | FUN_0040f7a0 | FUN_00450110 | FUN_00413c60 | S02 §1.7 |
| `CPacket::TakeNextPacket` | FUN_00413cb0 | FUN_0040f800 | FUN_00450170 | FUN_00413cc0 | S02 §1.7 |
| `CPacket::RemoveAllUsedPacket` | FUN_00413ce0 | FUN_0040f830 | FUN_004501a0 | FUN_00413cf0 | S02 §1.7 |
| `CPacket::Clear` | FUN_00413d20 | FUN_0040f870 | FUN_004501e0 | FUN_00413d30 | S02 §1.7 |
| `CPacket::ID` | FUN_00413d60 | FUN_0040f8b0 | FUN_00450220 | FUN_00413d70 | S02 §1.7 |
| `CPacket::WriteData` | FUN_00413d80 | FUN_0040f8d0 | FUN_00450240 | FUN_00413d90 | S02 §1.7 |
| `CPacket::GetWriteableBufferSize` | FUN_00413df0 | FUN_0040f940 | FUN_004502b0 | FUN_00413e00 | S02 §1.7 |
| `CPacket::CPacket` | FUN_00413e00 | FUN_0040f950 | FUN_004502c0 | FUN_00413e10 | S02 §1.7 |
| `CPacket::ID` | FUN_00413e40 | FUN_0040f990 | FUN_00450300 | FUN_00413e50 | S02 §1.7 |
| `CGTimer::GetTime` | FUN_00413ef0 | – | – | – | S02 §1 (`timeGetTime`) |
| `CSocket_Acceptor_Process::CSocket_Acceptor_Process` | FUN_00413f00 | FUN_0040fa50 | FUN_004503d0 | FUN_00413f10 | §1.4 |
| `InetAddress::WinSockStart` | FUN_00414090 | FUN_0040fbe0 | FUN_0044bcc0 | FUN_00416890 | §1.4 |
| `InetAddress::GetHostAddress` | FUN_00414100 | FUN_0040fc50 | FUN_0044bd30 | FUN_00416900 | §1.4 |
| `CIOSpinLock::Wait` | FUN_00417710 | FUN_00413270 | FUN_00450440 | FUN_00417590 | S02 §1.2 |
| `IOBufferContainer::IOBufferContainer` | FUN_00417780 | FUN_004132e0 | FUN_004504b0 | FUN_00417600 | S02 §1.2 |
| `CIOBuffer::`scalar_deleting_destructor'` | FUN_004177e0 | FUN_00413340 | FUN_00450510 | FUN_00417660 | S02 §1.2 |
| `CIOBuffer::Alloc` | FUN_00417810 | FUN_00413370 | FUN_00450540 | FUN_00417690 | S02 §1.2 |
| `CIOBuffer::Free` | FUN_00417900 | FUN_00413460 | FUN_00450630 | FUN_00417780 | S02 §1.2 |
| `cShineLogSystem::SLS_SetLogName` | FUN_00417960 | FUN_004134c0 | FUN_00450690 | FUN_004177e0 | W05 §5.7; D05 §7.4 |
| `cShineLogSystem::SLS_AddLog` | FUN_004179d0 | FUN_00413530 | FUN_00450700 | FUN_00417850 | W05 §5.7; D05 §7.4 |

Not in the table: `DataServer::DataServer` / `~DataServer` / `ReadDefineScriptor` / `Start` / `OnStart_Service` and
`CSessionWorker::DB_Init` differ per build (server type, config file name, ODBC rows, start-up loaders); their Account
bodies are above and in D01 §1. `DataServer::Start` differs from the WM and Login `Start` only in the texts and the
missing `ReadGlobalGameData`; `CIOCP::Stop` FUN_0040ec30 and `CGTimer::GetTime` FUN_00413ef0 differ from the WM copies
only in decompiler output (same calls and constants, read).

## 2. Linked game-data and database classes (Account build)

The DB servers link the shared game-data library of the zone (item table, item attribute classes, map table, random
boxes, SHN reader) and an ODBC wrapper of their own. Compared by PDB name and normalised body with `zone-pdb` and
`wm-pdb` (same normaliser as §1.6; scratch compare, not kept): of 426 functions in 0x40f800–0x419000, 175 are identical
to the zone's, 113 to the WM's, 115 exist in neither (session layer §1.4, ODBC wrapper §2.5, the `iac_ItemClass`
one-liners the zone folds), and the 23 that differ differ only in a folded callee name or a decompiler type
(§2.6 lists the three real differences). What matters for a rebuild is **which of these objects the DB servers
actually use**: almost none.

### 2.1 Static objects and who uses them

The CRT builds these globals before `WinMain` (`dynamic_initializer_for_…`, in this order *(inferred: the `__xc` table
is in address order)*) and destroys them at exit (`dynamic_atexit_destructor_for_…`):

| Global (pdb2016) | Initializer → constructor | What it does at start-up | Used in Account at run time |
|---|---|---|---|
| `gServer` | FUN_004317e0 | §1.1 | yes |
| `itemdatabox` (`ItemDataBox`, 0x94c) | FUN_00431800 → `ItemDataBox::ItemDataBox(&itemdatabox, (char*)-1, false)` FUN_00411f30 | builds the empty trie and the seven `BinaryDataBox` members (`<unnamed-type-idb_BinData>` ctor FUN_00411a00); path −1 = **no file is read** (a null path would read `../9Data/Shine/ItemInfo.shn` through `ItemDataBox::ReadData` FUN_00411c70, Z24 §7.3) | no: only `ItemAttrCls_Amount::iac_itemcreate` FUN_00415f10 reads it, and that is never called (below) |
| `namestring` (`NameString`, 256 × 128-byte ring) | FUN_00431820 (atexit only) | – | only by `MapDataBox::mdb_Load` (§2.2) |
| `mapdatabox` (`MapDataBox`, 0x51c) | FUN_00431830 → `MapDataBox::MapDataBox` FUN_0040fc50 | empty | loaded by `DataServer::Start` only when `nServerID == 2` (Character, §1.2, §2.2); never in Account / AccountLog |
| `g_ItmBelongAttr` (`ItemBelongAttribute` : `CItemAuthorityBase`, 0x3d8) | FUN_00431850 → `CItemAuthorityBase::CItemAuthorityBase` FUN_0042efb0, then the `ItemBelongAttribute` vftable | fills the three box-to-box matrices (§2.3); `BelongTypeInfo.shn` is not loaded (`iba_Load` is not linked) | no |
| `shineassert` | FUN_00431870 | `AssertClass` (W05 §6.4) | yes (assert log) |
| `charinvenman` (`CharacterInventoryManager`, 17 member-function pointers) | FUN_00431880 | `cim_Array[7]` = `cim_quest` FUN_00414dc0 (inventory + 0x6558), `[8]` = `cim_equip` FUN_00414da0 (+0), `[9]` = `cim_inven` FUN_00414db0 (+0xe54), `[12]` = `cim_minihouse` FUN_00414dd0 (+0x67a0), every other slot `cim_null` FUN_00414d90 (returns its argument); same offsets as the zone's FUN_00642e00 … | no |
| `ItemBag::ib_staticcell`, `ItemActionItemBox::iaib_Default` | FUN_00431910, FUN_00431920 (atexit only) | – | no |
| `itmattcontainer` (`ItemAttributeClassContainer`) | FUN_00431930 → FUN_00416dc0 | one object per attribute class, `iacc_Array[0…0x26]` by `ItemClassEnum`, same table as the zone (Z04 §1) and the Character copy (D07 §1.3) | **no**: no function of Account reads `itmattcontainer`, so none of the 202 `ItemAttributeClass` / `ItemAttrCls_*` functions (vtables only) can run |
| `IOBufferList`, `g_slotBuffer`, `gSocket_IOCP_Write`, `gZoneLinktoErrorLog` | FUN_00431950 … FUN_00431a00 | library (S02 §1.2, §1.4 here) | yes |
| `rewarddata` (`RewardData` : `BinaryDataBox<ShineReward>`), `fprewarddata` (`FPRewardData` : `BinaryDataBox<FriendPointReward>`) | FUN_00431a60, FUN_00431b30 | zeroed `BinaryData` (`BinaryData::BinaryData` FUN_00414030 = a `CDataReader`) | no (never loaded) |
| `itemoptiondata` (`ItemOptionsData` : `BinaryDataBox<ItemOptions>`, 0x46ac) | FUN_00431a90 | 500 empty `OptionCardStack` (§2.4) | no (never loaded; read only by `ocs_make`) |
| `rndbox` (`RandomBox`, 0x348398 = 3.3 MB) | FUN_00431b90 → `RandomBox::RandomBox` FUN_004182e0 | **runs**: `srand(time)`, 101 + 4 shuffled 16 384-entry rings and a WELL512 state (§2.4) | no (read only by the item-create code) |
| `ShnDataFile` (`CShnDataFileCheckSum`) | FUN_00431c20 → FUN_0042f3c0 | the 49-name client-file list, same as W05 §3.4 | only through `CDataReader::Read` (Character: MapInfo) |

So the Account and AccountLog servers read **no SHN file** at all; this replaces the D01 §1 statement "also loads
MapInfo.shn, ItemInfo.shn (framework)" (knowledge §0). The whole item library is dead weight in Account: a rebuild of
Account / AccountLog needs none of it. The Character server loads ItemInfo, MapInfo and seven more tables in its own
`GameData_Load` and uses `itemdatabox`, `mapdatabox` and `itmattcontainer` (§4.5).

### 2.2 `MapDataBox` (MapInfo.shn, loaded by the Character server only)

```pseudo
MapDataBox::CheckReadData(this, path) → bool                                     @ FUN_0040fd60
    f = fopen(path, "rb"); none → return false; fclose(f)
    mdb_Load(this, path); return true          # DataServer::Start tries "../../9Data/Shine/MapInfo.shn", then "../9Data/…" (§1.2)

MapDataBox::mdb_Load(this, path)                                                 @ FUN_0040f970
    BinaryDataBox<MapInfo>::bdb_ReadData(&mdb_BinData, path)                     @ FUN_0040f8c0
        CDataReader::Read(path, key 0x1f8, row size 0x4c) (W05 §3.1) fails →
        assert "BinaryDataBox<T>::bdb_ReadData : readfail", "Code:%X:%d\tSHN:%X:%d"; ShineExit   (process ends)
    mdb_maxmapid = max(row.ID) + 1; mdb_index = new MapInfo*[mdb_maxmapid], all null
    for each row r:
        mdb_index[r.ID] = r
        key = r.MapName (Name3, 12 bytes) copied into the next `namestring` slot with a NUL at 12
        BTree::bt_Insert(&mdb_btree, key, r.ID) == 0 → assert "MobDataBox::ReadData : memory leak for BTree"  (sic);
            ShineExit("MapDataBox::mdb_Load")          # only on out-of-memory: bt_Insert fails only when new fails
    mdb_wmlink[0…32] = null; for each row: mdb_wmlink[r.IsWMLink] = r (last row wins); mdb_wmlink[0] = null
        # IsWMLink is not range-checked (33 slots); 2016 MapInfo.shn: 138 rows, IDs 0…1001, IsWMLink 0…32, no
        # duplicate link or name, so the data is safe
```

`MapInfo` row *(pdb2016)*, 0x4c: `u16 ID`, `Name3 MapName` @2, `char Name[32]` @0xe, `WM_Link IsWMLink` (u32) @0x2e,
`u32 RegenX` @0x32, `RegenY` @0x36, `u8 KingdomMap` @0x3a, `Name3 MapFolderName` @0x3b, `u8 InSide` @0x47,
`u32 Sight` @0x48. The zone's `mdb_Load` FUN_0064ebf0 is the same code with the path built in (Z01 §2.3 table); in
Account the path is a parameter. `BTree` (256-way trie, node 0x404 = `bt_id` + 256 children; `bt_Insert` FUN_00413f60
overwrites an existing key, `operator[]` FUN_00413ff0 returns 0xffffffff when absent, case-sensitive; ctor / dtor
FUN_00413f10 / FUN_00413f30) is the zone's (Z09 §28.11). In the Character server only `GetCharBaseData` reads it (§4.5).

### 2.3 `CItemAuthorityBase`: the box-to-box move matrices

Not documented for the zone either (its copy FUN_00631e50 is identical); the only reader is the zone's
`CItemAuthorityBase::IA_CanInvenReloc` FUN_00632280 (Z04 §1.3 `BelongType_CanMove`, Z30 §9 `IA_IsWork*Belonged`):
`from`, `to` = inventory types of Z04 §1.1 (both < 17, else refused); the item's belong state picks the matrix —
character-bound (`IA_IsWorkChrBelonged`) → `IA_ChrBelong`, else account-bound → `IA_AccBelong`, else
`IA_CanStorage` must pass and `IA_Common` decides.

```pseudo
CItemAuthorityBase::CItemAuthorityBase(this)                                     @ FUN_0042efb0
    all three bool[17][17] matrices = false, then true for (from → to):
    IA_Common:   9→{0, 3, 6, 8, 9, 12, 13, 14, 15, 16}, 8→9, {0, 2, 4, 5, 6}→9, and t→t for t ∈ {0, 3, 6, 12, 13, 14, 15, 16}
    IA_ChrBelong: as IA_Common without 9→0 and 9→6           (no account storage, no academy storage)
    IA_AccBelong: as IA_Common without 9→0                   (account storage allowed)
    # IA_ChrBelong[0][0] and IA_AccBelong[0][0] are set only by 2-byte stores (`= 0x101`) at the previous matrix's
    # [16][16]: the compiler merged "[16][16] = true" with the next matrix's "[0][0] = true" (inferred: written per
    # matrix in the source like IA_Common[0][0]); so 0→0 is allowed in all three
```

Type 9 = main inventory, 8 = equipment, 6 = account storage, 4 = guild storage, 0 = guild-academy storage,
3 / 12–16 = mini-house and small-item boxes (Z04 §1.1). No matrix allows 9→4 or any move into type 2 (reward box) or
type 4 (guild storage); whether the zone's guild-storage deposit takes another path belongs to Z04's RELOC handler.

### 2.4 Random boxes and the reward-item option roll (zone code, dead in the DB servers)

```pseudo
RandomBox::RandomBox(this)                                                       @ FUN_004182e0
    srand(_time32()); rb_box[n] for n = 0…100: RandomSlot of 16 384 u16 = i·n >> 14 (uniform 0…n−1), shuffled with rand(),
        values ≥ n → 0; rb_thausend[0…3] = RandomSlot::rs_Init(1000) FUN_00418250 (same for n = 1000)
    WELL512 state = 16 × rand() (cWell512Random::well512_InitState FUN_00417c70; ctor FUN_00417c30)
    # same as the zone (Z23 knowledge: box n = 1…100 is a shuffled ring of 16 384 values uniform over 0…n−1) and the WM
cWell512Random::well512_GetRandom() FUN_00417ca0 → [0, 1);  (n) FUN_00417d50 → 0…n−1   (zone Z09 §28.10, W05 §6.4)
```

The item-create overloads that take a `ShineReward` row (vt 0x10; vt 0x14 is the `"-o"` text parser of Z11 §4.3)
are reachable only in the zone (reward items); their Account copies are identical to the zone's (`ItemAttrCls_Weapon`
FUN_004162b0 = zone FUN_0063f650, Armor FUN_00416360 = FUN_0063f700, Amulet FUN_00416270 = FUN_0063f610, Bracelet
FUN_00416420 = FUN_0063f7a0) and no zone document describes them, so here once:

```pseudo
ItemAttrCls_Weapon::iac_itemcreate(itemID, ShineReward rw, item)                 @ FUN_004162b0
    vt 0x14(itemID, item, "-o")                        # class defaults (Z11 table)
    r = well512(1000); upgrade = first i < 10 with r < rw.Upgrade[i] (subtracting each weight); none → 0
    ocs_make(&itemoptiondata.iod_optionlist[rw.OptionDegree], &item.weapon.option)
    s = EnchantSocketRateData::GetSocketRateData() FUN_00417e80 (static sm_pSocketRateData; never set in Account → null)
    s: maxSocketCount = min(s.vt0(itemID), 2)
Armor FUN_00416360: the same without the socket part (options into the armor option block)
Amulet FUN_00416270, Bracelet FUN_00416420: "-o" defaults, then ocs_make only (no upgrade roll)

ItemOptionsData::OptionCardStack::ocs_make(stack, ItemOptionStorage* o) → bool   @ FUN_00417f80
    keep o.identified bit (bit 0 of optionnumber); stack.ocs_Number (ItemOptions row) null → false
    n = ocs_selectnumber(stack.ocs_Number)            # how many options
    while option count < n:
        take the top card (CardDeck::CardStack, the List<Card> of W05 / Z05 §8.5) else assert "…ocs_make : Error in selecting"; false
        put it back at the bottom (cs_InsertBottom FUN_00418af0; failure → assert "…Error in card recycle")
        row = itemoptiondata[card] (ItemOptions); row id 0xffff → assert "…Option not found"; false
        row.Type ∉ 1…11 → assert "…Invalid Option"; false
        o.optionlist[count] = { type = row.Type, value = ocs_selectnumber(stack.ocs_Number) }; count++
    true
ItemOptionsData::OptionCardStack::ocs_selectnumber(ItemOptions r) → int         @ FUN_00417db0
    x = well512(1000); i = first of 9 with x < r.Rate[i] (subtracting); none → assert "…Error in random select", i = 0
    r.Interval == 1 → i + 1
    v = r.Interval · i + rndbox[r.Interval] (0…Interval−1; 0 when Interval ∉ 1…100); v > 255 → assert "…Too large value", 255
```

`ItemOptions` row *(pdb2016)*: `u16 OptionDegree`, `ITEM_OPTION_TYPE Type` @2 (u32), `u8 Interval` @6, `u16 Rate[9]` @7.
`ShineReward`: `u16 RewardHandle`, `u8 RewardType`, `char Argument[33]`, `u32 Quantity` @0x24, `u16 Upgrade[10]` @0x28,
`u16 OptionDegree` @0x3c, `u32 TitleDegree` @0x3e. The card decks are filled by the zone's `ItemOptions.shn` loader
(Z01 §2.3 table, FUN_0064cbc0), which the DB servers do not link.

### 2.5 The ODBC wrapper (`Database`, `DBRecord`, `CGameDB_Connect`)

DB-server only (neither the zone nor the WM has it). Layout *(pdb2016)*: `Database` 0xc { vftable, `bool m_bTran` @4,
`void* handleDBC` @8 }; `DBRecord : Database` 0x14 { `handleStatement` @0xc, `int columnNo` @0x10 };
`CGameDB_Connect` { `DBRecord m_DB` @0 }; `CGameDB_Account : CGameDB_Connect` 0x18 (+ the empty procedure classes
`CSQLPAccount` / `CSQLPIPChecker`, D01). One per session worker (`CSessionWorker.m_DBF`, §1.5). Statics shared by all
objects: `handleEnv`, `handleEnvRef` (open connections), `bInit`.

```pseudo
Database::Database: vftable, handleDBC = 0, m_bTran = false                      @ FUN_00417310
Database::InitEnv() → bool                                                       @ FUN_00417330
    bInit → true
    handleEnvRef = 0; SQLAllocHandle(ENV) fails → handleEnv = 0; false
    SQLSetEnvAttr(SQL_ATTR_ODBC_VERSION 200, 2 = SQL_OV_ODBC2) fails → free; handleEnv = 0; false
    SQLSetEnvAttr(201 = SQL_ATTR_CONNECTION_POOLING, 1 = SQL_CP_ONE_PER_DRIVER) ≠ SQL_SUCCESS → false
        # (original bug) D08-B4: here SQL_SUCCESS_WITH_INFO also counts as failure and the environment handle is
        # neither freed nor cleared, so the next openDB allocates another one
    bInit = true; true
Database::openDB(connStr) → bool                                                 @ FUN_004175e0
    InitEnv() fails → false
    an open connection: (m_bTran → CommitTran) SQLDisconnect, free, handleEnvRef−−
    SQLAllocHandle(DBC); SQLDriverConnect(hdbc, 0, connStr, SQL_NTS, out[0x400], …, SQL_DRIVER_NOPROMPT)
    ok → handleEnvRef++, true; else free, handleDBC = 0, false
Database::CommitTran() → bool                                                    @ FUN_004173d0
    !m_bTran → false; SQLEndTran(DBC, hdbc, SQL_COMMIT); SQLSetConnectAttr(SQL_ATTR_AUTOCOMMIT, ON); m_bTran = false
    # nothing in Account / AccountLog sets m_bTran = true (no BeginTran is linked; Character / GameLog: §4 / §7): autocommit
Database::close FUN_00417530: open → (CommitTran) SQLDisconnect, free DBC, handleEnvRef−−
Database::~Database FUN_00417570: close; handleEnvRef < 1 → free the environment, bInit = false
DBRecord::DBRecord FUN_004123b0 (handleStatement = 0); ~DBRecord FUN_00412550 / close FUN_004123e0: free the statement, Database::close
DBRecord::openDB(connStr) (vt 1) → bool                                          @ FUN_004125d0
    free the statement; Database::close; Database::openDB(connStr) and SQLAllocHandle(STMT) → true
DBRecord::query(fmt, …) FUN_00412410: vsprintf into 8 KB, SQLCloseCursor, SQLFreeStmt(SQL_CLOSE), SQLExecDirect (D06 §7.3)
DBRecord::fetch FUN_004124a0: columnNo = 0; SQLFetch ∈ {0, 1};  endFetch FUN_004124d0: SQLCloseCursor
DBRecord::operator>>(int&) FUN_004124e0 / (ulong&) FUN_00412510: SQLGetData(++columnNo, SQL_C_SLONG / SQL_C_ULONG, 4 bytes)
DBRecord::getStatement FUN_00412540 → handleStatement (the CSQLP* procedures bind and execute on it, D01–D06)
CGameDB_Connect::DBConnect(connStr, startupCmd) → 0 ok / 1 connect failed / 2 start-up command failed   @ FUN_00419bb0
    m_DB.vt 1 (DBRecord::openDB)(connStr); startupCmd non-empty → DBRecord::query(startupCmd)   (D06 §7.3)
CGameDB_Connect::DBClose FUN_00419c10: free the statement, Database::close   (worker exit, §1.5)
ViewDBError(where, hstmt)                                                        @ FUN_00417420
    SQLError(0, 0, hstmt, state, &native, text[0x400]); a message → log "ERROR - %s, state = %s error_num = %d error_str = %s"
    rc −1 → "ERROR - %s, SQLError = %d = SQL_ERROR"; rc not 0 → "… = unknown return value"   (log only; callers D01–D06)
```

The statics are not locked. The workers connect one after another (`CSessionWorkerManager::Start(-1, wait = 1)` from
`DataServer::Start`, §1.5), so `InitEnv` does not race at start-up; at stop the workers decrement `handleEnvRef` in
parallel, which is harmless because the environment is freed only by the destructors after all threads have ended.

### 2.6 Address table of the data classes (Account; same as the cited zone / WM documentation)

| Class (Account functions) | Same as | Note |
|---|---|---|
| `ItemAttributeClass` + 38 `ItemAttrCls_*` (202 functions 00414de0–004172e0: 00414de0 00414df0 00414e00 00414e10 00414e20 00414e30 00414e40 00414e60 00414e70 00414e80 00414e90 00414ea0 00414eb0 00414ec0 00414ed0 00414ee0 00414ef0 00414f00 00414f10 00414f20 00414f30 00414f40 00414f50 00414f60 00414f70 00414f80 00414f90 00414fa0 00414fb0 00414fc0 00414fd0 00414fe0 00414ff0 00415000 00415010 00415020 00415030 00415040 00415050 00415060 00415070 00415080 00415090 004150a0 004150b0 004150c0 004150d0 004150e0 004150f0 00415100 00415110 00415120 00415130 00415140 004151e0 004151f0 00415200 00415210 00415220 00415230 00415240 00415250 00415260 00415270 00415280 00415290 004152a0 004152f0 00415320 00415410 00415460 00415480 004154a0 004154c0 004154e0 00415510 00415540 00415580 004155a0 004155d0 00415600 00415620 00415650 00415660 00415680 004156a0 004156d0 00415700 00415740 00415760 00415780 00415790 004157c0 004157f0 00415810 00415830 00415860 00415870 00415880 00415890 004158b0 004158c0 004158d0 004158e0 004158f0 00415900 00415910 00415920 00415930 004159b0 004159f0 00415a30 00415ad0 00415c00 00415ca0 00415d40 00415d90 00415db0 00415e30 00415e50 00415e70 00415ec0 00415f10 00415f90 00415fc0 00416000 00416010 00416030 00416050 004160d0 004160e0 00416110 004161b0 004161c0 004161d0 004161e0 00416200 00416230 00416250 00416270 004162b0 00416360 004163e0 00416400 00416420 00416460 00416490 004164a0 00416550 00416590 004165c0 004165d0 00416610 00416650 00416690 00416720 00416770 00416790 004167a0 00416850 00416860 004168b0 004168c0 004168d0 004168e0 00416900 00416930 00416940 00416950 004169d0 004169f0 00416a00 00416a40 00416a50 00416bf0 00416c00 00416c10 00416c20 00416c30 00416c50 00416c70 00416c90 00416cb0 00416cd0 00416ce0 00416d00 00416d20 00416d40 00416d60 00416d90 00417100 00417130 00417160 00417190 004171c0 004171f0 00417220 00417250 00417280 004172a0 004172c0 004172e0) | zone: Z04 §1 (classes), Z11 (`iac_itemcreate` "-…" options), Z18 knowledge (slots), Z13 / Z17 / Z28 (per class); Character copy D07 §1.3 | dead in Account (§2.1). 154 bodies identical to the zone's, 47 are one-liners the zone folds under other names; 3 differ: `ItemAttrCls_Riding::iac_itemcreate` FUN_00415ec0 and `ItemAttrCls_CostumWeapon::iac_itemcreate` FUN_00415f90 call a folded "return 0" (FUN_004036d0, named `TiXmlNode::ToElement`) where the zone calls `RidingInitHP` / `WeaponCostumInitCharge`, and `RidingInitHungry` FUN_004017c0 returns the constant 100 (zone: from `MoverHG` / `Riding.shn`, Z24 §5): the DB builds stub the helpers that need zone tables |
| `ItemAttributeClassContainer` 00416dc0 00417070 | Z04 §1; D07 §1.3 | never read in Account |
| `ItemDataBox`, `<unnamed-type-idb_BinData>`, `BinaryDataBox<ItemInfo / ItemInfoServer / GradeItemOption / ItemDropLog / ItemSort / ItemInvenDel / ItemMoney>` 00411850 00411860 00411870 00411880 00411890 004118a0 004118b0 004118e0 00411910 00411940 00411970 004119a0 004119d0 00411a00 00411ba0 00411c70 00411e80 00411f30 | Z27 §1.1, Z24 §7.3 (`ReadData`, ctor) | built empty, nothing read (§2.1) |
| `MapDataBox`, `BinaryDataBox<MapInfo>` 0040f8c0 0040f970 0040fc10 0040fc20 0040fc50 0040fce0 0040fd60 | §2.2 | Character only |
| `BinaryData` 00414030 00414050 00414060; `BTree` 00413f10 00413f30 00413f60 00413ff0 | W05 §6.2, Z27 §1.1; Z09 §28.11 | |
| `CItemAuthorityBase`, `ItemBelongAttribute` 00411830 00411f00 0042efb0 0042f160 0042f170 | §2.3; zone Z30 §9 (`IA_IsWork*Belonged`), Z04 §1.3 | `IA_GetBelongTypeInfo` FUN_00411830: index > 10 → null, else `iba_Array[i]` (never filled in Account) |
| `CharacterInventoryManager` 00414d90 00414da0 00414db0 00414dc0 00414dd0 | §2.1 | unused |
| `ItemOptionsData`, `OptionCardStack`, `BinaryDataBox<ItemOptions>`, `EnchantSocketRateData` 00417d90 00417da0 00417db0 00417e80 00417e90 00417ed0 00417f80 00418170 | §2.4 | identical to WM / zone |
| `BinaryDataBox<ShineReward / FriendPointReward>` 00417ea0 00418200 | §2.1 | never loaded |
| `CardDeck::CardStack`, `ListEraser / ListIteratorDefault<CardDeck::Card>` 00417f70 00418140 00418160 00418a80 00418af0 00418d40 (and the `List<CardDeck::Card>` methods of §1.6) | Z09 §28.10, Z05 §8.5, W05 | |
| `RandomBox`, `RandomSlot`, `cWell512Random` 00417c30 00417c70 00417ca0 00417d50 00418230 00418250 004182e0 | §2.4; Z23 / Z09 knowledge, W05 §6.4 | the ctor runs at start-up |
| `CDataReader` 0042ebd0 0042ec00 0042ec40 0042ec70 0042ecb0 0042ed10 0042ef70 | W05 §3.1 (identical bodies) | reached only via §2.2 |
| `CShnDataFileCheckSum` 0042f1f0 0042f210 0042f3c0 | W05 §3.4 (identical) | 49 names; in Character only `MapInfo.shn` (entry 9) gets an MD5, nothing reads it |
| `CWeaponTitle::GetLevel` 0042f1a0 | Z18 §6.6 | dead (caller is an `iac_wptitle_*`) |
| `CMD5Checksum` 0040afe0 0040aff0 0040b020 0040b700 0040b8e0 0040baf0 | W05 §6.3 (RFC 1321), L01 | used by `CDataReader::Read` and D01 (MD5 hex) |
| `Database`, `DBRecord`, `CGameDB_Connect`, `ViewDBError` 004123b0 004123e0 00412410 004124a0 004124d0 004124e0 00412510 00412540 00412550 004125d0 00412640 00417310 00417330 004173d0 00417420 00417530 00417570 004175e0 004176e0 00419bb0 00419c10 | §2.5 | DB servers only |
| `SHINE_INDUN_INFO` ctor / dtor 00401010 00413b20; `type_info` 0041b8fc 0041b90c 0041b92d 004264a3; `g_CardCollectMake` 004123d0 | – | empty folded ctor / dtor (31 callers: every empty destructor); CRT RTTI; `g_CardCollectMake` is a one-line stub here (zone Z28 §4.2) |
| static initializers / atexit destructors 00431800 00431820 00431830 00431850 00431880 00431910 00431920 00431930 00431a60 00431a90 00431b30 00431b90 00431c20 00431c50 00431c70 00431c80 00431ce0 00431d50 00431d70 00431df0 00431e10 00431ef0 | §2.1 | |

## 3. AccountLog: differences against the Account build

`python3 -I docs/plan/status/D08-match.py accountlog account` over the whole AccountLog export: 1 056 of 1 327 functions
have an identical body in Account. Of the 230 class-named AccountLog functions that no document cited before this part
(`X02-cov.py game accountlog`), 203 are such copies (address table §3.6) and 27 differ. Read side by side
(`clean.py` on both PDB exports, labels and addresses masked), the 27 and the AccountLog "–" cells of §1.6 fall in three
groups:

- **only labels, member offsets or a folded empty destructor differ** (same code): `DataServer::OnStop_Service`
  FUN_004010d0, `ViewStartInfo` FUN_00401100, `ViewStopInfo` FUN_00401240, `Start_MainThread` FUN_00401ce0,
  `CSocket_Acceptor_Process_Manager_App::Accept_Process` FUN_004057e0, `CIOCP::Stop` FUN_0040a290, `CGTimer::GetTime`
  FUN_0040fa40, `BinaryDataBox<MapInfo>::bdb_ReadData` FUN_0040b950, `MapDataBox::mdb_Load` FUN_0040ba00, both
  `cWell512Random::well512_GetRandom` FUN_00413800 / FUN_004138b0, the `CGdp` file functions FUN_00407630 / FUN_00407670 /
  FUN_00407700 / FUN_004077f0 / FUN_00407830, `CPFs::fc_NC_MISC_S2SCONNECTION_REQ` FUN_004040f0 and
  `CPFs::fc_NC_OPTOOL_CLOSE_SERVER_REQ` FUN_00404880 (they end in the folded empty destructor, which the PDB names
  `CStatistics::~CStatistics` here and `SHINE_INDUN_INFO::~SHINE_INDUN_INFO` in Account). Their Account description holds:
  §1.2–§1.5, §2.2, §2.4, S02 §1.3, D01 §2.
- **AccountLog variants** of the process layer: the `DataServer` object, start-up, main thread, DB_Init and the
  session worker (§3.1–§3.4).
- **AccountLog-only classes**: `CStatistics` (§3.3), `cLogSystem` / `cLS_Queue` (§3.5), `CSession_Manager::FindSession`
  (§3.3), `CGameDB_AccountLog` / `CSQLPReport` (§3.4), `CParserAccountLog` (§3.4).

### 3.1 Objects

```
DataServer gServer (0x209e20, DAT_004461a8) *(pdb2016)*: as Account (§1.1) up to +0x9838 m_SessionWorkerManager, then
    +0x209890 CStatistics m_Statistics (0x24: tm m_Timer)        # new
    +0x2098b4 m_bOnStopService  +0x2098b8 m_ServerStartTime  +0x2098c8 m_ServerStopTime
    +0x2098d8 m_bStopMainThread  +0x2098dc m_bActiveMainThread  +0x2098e0 m_hMainThread  +0x2098e4 m_MainThreadID
    +0x2098e8 cLogSystem m_UK_SysLog (0x390)                     # new: the syslog text file (§3.5); DAT_0064fa90 in D01 §4.5
    +0x209c78 m_NumOfIndunMap  +0x209c7c SHINE_INDUN_INFO m_IndunMapList[32]
CSessionWorker (0x1288): as Account up to +0x138, then +0x138 CParserAccountLog m_Parser, +0x124c CGameDB_AccountLog m_DBF
    (0x20: CGameDB_Connect + CSQLPReport m_SQLPReport @0x14 + empty CSQLP* method holders), +0x126c CGameDB_StatisticsData
    m_DBFStatistics (the second ODBC link)
```

So the stop flag of 0x2803 is `gServer + 0x2098d8` in AccountLog (Account / GameLog: +0x2098b4, knowledge §1).

### 3.2 Start-up, main thread, stop

```pseudo
DataServer::DataServer:                                   @ FUN_00401870
    as Account (§1.2), plus CStatistics::CStatistics(&m_Statistics) and cLogSystem::cLogSystem(&m_UK_SysLog)
        CStatistics ctor FUN_00406470: m_Timer = localtime(_time64())            # the minute of start-up
        cLogSystem ctor FUN_0040a800: two empty std::string (directory, file name)
DataServer::~DataServer:                                  @ FUN_00401020
    as Account, plus ~cLogSystem FUN_0040a820 (frees the two strings; the writer thread is not stopped) and ~CStatistics (empty)
DataServer::ReadDefineScriptor:                           @ FUN_00401380
    as Account, file "DataServerInfo_AccountLog.txt"

DataServer::OnStart_Service:                              @ FUN_00401f50
    name = "_fiesta_Accountlog.log"
    if !cLogSystem::ls_LogSystemInit(&m_UK_SysLog, "C:/data/gamigo-dwh/current/", LCT_HOUR, name):   (§3.5)
        return false                                       # no message: the service start fails silently
    then exactly the Account sequence (§1.2): m_bOnStopService = 1, IOCP 5 × CPU, CSessionWorkerManager::Start(-1, wait),
    Start_Acceptor, Start_MainThread

DataServer::MainThread:                                   @ FUN_00401640
    m_bActiveMainThread = 1
    while !m_bStopMainThread:
        Sleep(1000)
        CSession_Manager::ProcHeartBeat(&m_SocketSessionManager)        # §1.4
        CStatistics::Process(&m_Statistics, &m_SocketSessionManager)    # new: §3.3
    then the Account stop sequence (§1.3), testing m_bOnStopService at its AccountLog offset
```

The writer thread of `m_UK_SysLog` has no stop path: `ls_bLogThreadStopOrder` is only ever written by
`ls_LogSystemInit` (false), so the thread runs until the process ends, and lines still queued at `exit(0)` or service
stop are lost *(read: no other writer of the flag in the export)*.

### 3.3 The once-a-minute user-count poll (`CStatistics`)

```pseudo
CStatistics::Process(stat, sessions):   (main thread, every second)            @ FUN_004064b0
    now = localtime(_time64())
    minuteChanged = stat.m_Timer.tm_min != now.tm_min
    copy now.tm_min / tm_hour / tm_mday / tm_mon into m_Timer where they changed        # only tm_min is ever tested
    lock the session list (CSM_Enter_CS)
    for s = FindSession(5, null); s; s = FindSession(5, s.pLinkDown):   # every authenticated WorldManager link
        if minuteChanged:
            CSession::Send(s, raw {0x03, 0x0809, b}, 4)     # NC_MISC_CONNECTER_REQ; b = high byte of the `sessions`
                                                            # pointer reused as the buffer = 0x00 (P02-B6; layout P02)
        if !s.pLinkDown: break
    unlock; return 0

CSession_Manager::FindSession(serverId, from):            @ FUN_00405480   (AccountLog; Character copy FUN_0043dc20, §4.3)
    under the session-list lock: first node at or after `from` (null = list head) whose session has
    m_Connection == 1 and m_Connected_Server_ID == serverId; null if none
```

The WM answers each 0x0809 with 0xC811 `NC_SYSLOG_SERVER_CCU` and 0x080A `NC_MISC_CONNECTER_ACK` (W01 §8), which AccountLog
stores as one `p_SameTimeChar_Add` row per world (D01 §4.2) and one syslog line (D01 §4.5). So the concurrent-user
statistics are sampled once per wall-clock minute (at the first second tick of the minute), not at a WM interval
*(captured: P02, 0x0809 once per minute)*. The first poll comes at the first minute change after start-up.

### 3.4 Session workers, the two DB links, the dispatcher

```pseudo
CSessionWorker::CSessionWorker:                           @ FUN_00405de0
    as Account (§1.5), with CParserAccountLog m_Parser (registrations below), CSQLPReport, a second DBRecord (statistics)
CSessionWorker::~CSessionWorker:                          @ FUN_00405d20
    as Account, plus ~DBRecord(m_DBFStatistics), ~CSQLPReport
CGameDB_AccountLog::~CGameDB_AccountLog:                  @ FUN_00405bd0   ~CSQLPReport, ~DBRecord
CSQLPReport::`scalar_deleting_destructor':                @ FUN_00415330   (empty class with a vtable; the report procedures, D01 §4.4)
CSessionWorkerManager::Start:                             @ FUN_00406310
    as Account (§1.5) with workers of 0x1288 bytes

CSessionWorker::DB_Init(w):                               @ FUN_00405870
    base = CServerInfo::GetODBCInfo(id 1 "AccountLog", my world)        # Account: id 0
    stat = CServerInfo::GetODBCInfo(id 2 "Statistics", my world)        # both rows must exist, else log and fail
    if DBConnect(w.m_DBF, base) ok:
        if DBConnect(w.m_DBFStatistics, stat) ok: return 1
        DBClose(w.m_DBF)
    log "DB_Init FAILED …"; return 0
CSessionWorker::SessionWorkThread(w):                     @ FUN_004059c0
    as Account (§1.5); at the end it also closes m_DBFStatistics (offset +0x126c)
```

So every AccountLog worker holds two ODBC connections: up to 2 × 81 connections at once, half of them to
StatisticsData (D01 §1).

```pseudo
CParser::Parser(parser, packet):   (the worker's m_Parser.vtbl[0]; identical in Account FUN_004053c0)   @ FUN_00404ca0
    while (r = packet.IsValidPacket()) == 1:                # one frame of the job (normally exactly one)
        op = frame opcode; session.m_Last_PacketCommand = op; session.m_Last_PacketLength = payload length
        session.m_Last_PacketWorkType = PACKET_PARSING_WORKING
        ok = pft_funcpnt[op & 0x3ff][op >> 10](payload, length)      # handler table (W05 §6.1); empty slot = fc_dummyfunction
        if !ok: m_Last_PacketWorkType = PACKET_PARSING_FAILED; return 0     # the worker logs "*Work failed …" (§1.5)
        m_Last_PacketWorkType = PACKET_PARSING_DONE; packet.next()
    if r == 2: log "… From (%25s world=… )" with the peer IP / port and server name; return 0     # malformed frame
    packet.reset(); return 1
```

`CParserAccountLog::CParserAccountLog` FUN_00403dc0 registers 21 handlers on the `CParser` base table (D01 §2's
server-link handlers come from the base constructor FUN_00404b70):

| Opcode (dept, cmd) | Handler | D01 § |
|---|---|---|
| 0x0720 / 0x0721 / 0x0722 (1, 800–802) | FUN_00402470 / FUN_00402580 / FUN_00402640 | §4.1 |
| 0x080A (2, 10) | FUN_004026f0 | §4.2 |
| 0x081F (2, 31), 0x082C (2, 44), 0x0835 (2, 53), 0x0843 (2, 67) | FUN_00402990, FUN_00402aa0, FUN_00402d40, FUN_004030d0 | §4.2 |
| 0x0C2A, 0x0C3B, 0x0C40, 0x0C4D, 0x0C5D (3, 42 / 59 / 64 / 77 / 93) | FUN_00403bb0, FUN_00403cc0, FUN_00402e00, FUN_00402ec0, FUN_004038d0 | §4.3 |
| 0x0C62 (3, 98) | FUN_004035e0 | §4.4 |
| 0x8007 / 0x8009 / 0x800B (32, 7 / 9 / 11) | FUN_00403a00 / FUN_004027b0 / FUN_004028a0 | §4.4 |
| 0xC801 / 0xC802 / 0xC803 / 0xC811 (50, 1 / 2 / 3 / 17) | FUN_00403310 / FUN_004033d0 / FUN_004034e0 / FUN_00403560 | §4.5 |

### 3.5 The syslog text file (`cLogSystem`, `cLS_Queue<std::string>`)

The same class as the GameLog's hourly log file (D05 §6.1, our names there); AccountLog's PDB gives the official names,
and the GameLog copies match by body (names added to `names/gamelog/D08.json`). Account and Character do not have it.

| D05 §6.1 (GameLog, ours) | Official *(pdb2016)* | AccountLog | GameLog |
|---|---|---|---|
| `RotatingLog_Open` | `cLogSystem::ls_LogSystemInit` | FUN_0040aee0 | FUN_0040f6b0 |
| `CreateDirectoryPath` | `cLogSystem::ls_CreateDirectory` | FUN_0040a5a0 | FUN_0040ed70 |
| `RotatingLog_IsBeforeRollover` | `cLogSystem::ls_ValidTimeCheck` | FUN_0040a620 | FUN_0040edf0 |
| `RotatingLog_Write` | `cLogSystem::ls_LogReservation` | FUN_0040aa20 | FUN_0040f1f0 |
| `RotatingLog_WriterThread` | `cLogSystem::ls_LogSystemProcess` | FUN_0040aa80 | FUN_0040f250 |
| `LineQueue_Push` | `cLS_Queue::lsq_Push` | FUN_0040a870 | FUN_0040f040 |
| – | `cLS_Queue::lsq_Front` / `lsq_QueueAllocate` | FUN_0040a990 / FUN_0040a730 | FUN_0040f160 / FUN_0040ef00 |
| – | `cLogSystem` ctor / dtor | FUN_0040a800 / FUN_0040a820 | FUN_0040efd0 / FUN_0040eff0 |

```
cLogSystem (0x390) *(pdb2016)*: +0x0 std::string ls_LogFileDirectory, +0x1c LOG_CYCLE_TYPE ls_LogCycleType
    (LCT_NULL 0, YEAR 1, MONTH 2, DAY 3, HOUR 4, MINUTE 5, SECOND 6), +0x20 std::string ls_LogFileName,
    +0x3c char ls_FileNameBuf[256], +0x13c char ls_FileLineBuf[512], +0x33c cLS_Queue ls_LogQueue,
    +0x364 bool ls_LogFlush (set, never read), +0x368 ulong ls_LogInsertCount, +0x36c CRITICAL_SECTION ls_SendCS,
    +0x384 ls_hLogThread, +0x388 ls_dwLogThread, +0x38c bool ls_bActiveLogThread, +0x38d bool ls_bLogThreadStopOrder
cLS_Queue (+0x33c): lsq_dwFront_X / _Y, lsq_dwBack_X / _Y (slot in block, block number), lsq_dwAllocatePoint = 0x400
    (slots per block), list head / tail of CLS_QNODE {std::string* pDataArray; …; pNext}, current front / back block,
    lsq_pMemoryHead (free list of emptied blocks)
```

```pseudo
ls_LogSystemInit(dir, cycle, name):                       @ FUN_0040aee0
    store dir, cycle, name; active = stop = false; flush = true; count = 0
    ls_CreateDirectory(dir)                               @ FUN_0040a5a0  (CreateDirectoryA per '/' or '\' prefix, then all; results ignored)
    queue = one block of 1024 std::string (lsq_QueueAllocate @ FUN_0040a730: from the free list, else new)
    CreateThread(ls_LogSystemProcess); fails → false
    InitializeCriticalSection(ls_SendCS); return true

ls_LogReservation(line):                                  @ FUN_0040aa20
    if line and ls_bActiveLogThread and !ls_bLogThreadStopOrder:
        under ls_SendCS: lsq_Push(std::string(line)); ls_LogInsertCount++
lsq_Push(s):                                              @ FUN_0040a870
    back slot = s; Back_X++
    block full → next block (lsq_QueueAllocate; chained at the tail), Back_Y++
        # the "overwrite the last slot" branch needs Back_Y to wrap onto Front_Y (2³² blocks) or a failed `new`:
        # in practice the queue is unbounded and grows by 1024-line blocks; emptied blocks are recycled

ls_LogSystemProcess:   (the writer thread)                @ FUN_0040aa80
    ls_bActiveLogThread = 1
    while !stop or queue not empty:
        Sleep(1)
        queue empty and a file is open and !ls_ValidTimeCheck(now, rollover): fclose     # close at the hour even when idle
        while queue not empty:
            now = GetLocalTime()
            no file, or !ls_ValidTimeCheck(now, rollover) (after fclose):
                stamp by cycle: YEAR "%04d", MONTH "%04d%02d", DAY "%04d%02d%02d", HOUR "%04d%02d%02d%02d",
                    MINUTE "…%02d", SECOND "…%02d", other ""
                rollover = now + 1 unit, lower fields zeroed (hour: yyyy-mm-dd (hh+1):00:00)
                ls_FileNameBuf = dir + stamp + name; fopen("a+"); fails → thread ends with −1   (D05-B11)
            else:
                under ls_SendCS: lsq_Front → sprintf(ls_FileLineBuf, "%s", line); pop (an emptied block goes to the free list)
                fprintf(file, "%s\n", ls_FileLineBuf); fflush
    fclose; ls_bActiveLogThread = 0
ls_ValidTimeCheck(now, rollover, cycle):                  @ FUN_0040a620
    cycle == LCT_NULL → true
    true when Y·10¹⁰ + M·10⁸ + D·10⁶ + h·10⁴ + m·10² + s of now < the same number of rollover   (64-bit)
        # hour 24 / day 32 / month 13 compare correctly as numbers, so month and year ends roll over too
```

AccountLog file: `C:/data/gamigo-dwh/current/<yyyymmddhh>_fiesta_Accountlog.log`, one per hour. Lines come only from
`CPFsAccountLog::SaveSysLog` FUN_00403150 (the four 0xC8xx handlers, D01 §4.5); their buffer is 0x500 bytes, the writer
copies into 512 with an unbounded `sprintf`, and the longest line (0xC802 with a 256-byte user name) is 434 bytes plus the
host name, so it overflows only with a host name of 78 characters or more *(computed from the formats)*.

### 3.6 Address table (AccountLog functions identical to the Account copy)

All AccountLog class-named functions not cited elsewhere whose body equals the Account function documented in the cited
section (addresses are AccountLog's; the Account addresses: `D08-match.py accountlog account`).

| Class (AccountLog functions, identical body to the Account copy) | Same as | n |
|---|---|---|
| `ItemAttributeClass` + `ItemAttrCls_*`: 00410920 00410940 00410950 00410960 00410980 004109a0 004109b0 004109c0 004109d0 004109e0 004109f0 00410a00 00410a20 00410a30 00410a40 00410a60 00410a90 00410aa0 00410ab0 00410ad0 00410ae0 00410b00 00410b10 00410b20 00410b30 00410b40 00410b50 00410b60 00410b70 00410ba0 00410bb0 00410bc0 00410bd0 00410be0 00410c00 00410c10 00410c20 00410c30 00410c40 00410c50 00410c60 00410c70 00410c80 00410c90 00410d40 00410d50 00410d70 00410d80 00410d90 00410da0 00410db0 00410dc0 00410dd0 00410e50 00410e80 00410f70 00410fc0 00410fd0 00410ff0 00411010 00411090 004110d0 004110f0 00411110 00411170 00411190 004111c0 004111e0 00411240 00411280 004112b0 00411310 00411340 004113d0 004113e0 00411400 00411410 00411420 00411430 00411450 00411480 00411490 00411550 00411590 004117a0 00411840 00411930 00411950 00411a40 00411b10 00411c30 00411c40 00411d10 00411d30 00411d60 00411d90 00411e10 00411f40 00411f60 00411f80 00411fc0 00411ff0 004120a0 00412110 00412120 00412130 00412170 00412240 00412290 00412420 00412430 00412440 004124b0 004124c0 00412560 00412740 004127e0 00412820 00412830 00412850 00412860 004128c0 004128f0 00412cc0 00412d80 00412db0 00412de0 00412e40 | §2.6 row 1 (Z04 §1, D07 §1.3) | 128 |
| `ItemDataBox`, `BinaryDataBox<Item… / GradeItemOption>`, `ItemBelongAttribute`: 0040d8f0 0040d990 0040d8b0 0040d8d0 0040d8e0 0040d900 0040d910 0040d920 0040d930 0040d960 0040d9f0 0040da20 0040da50 0040dc20 0040dcf0 0040df00 0040df80 0040dfb0 | §2.6 rows 3, 6 | 18 |
| `MapDataBox`, `BinaryDataBox<MapInfo>`, `BinaryData`, `BTree`: 0040bcb0 0040bd70 0040fa60 0040fab0 0040fb40 0040fb80 0040fba0 0040fbb0 | §2.2; §2.6 rows 4–5 | 8 |
| `CItemAuthorityBase`: 00429ff0 0042a1a0 0042a1b0 | §2.3 | 3 |
| `CharacterInventoryManager`: 004108e0 00410900 00410910 00412490 | §2.1 | 4 |
| `ItemOptionsData`, `OptionCardStack`, `BinaryDataBox<ItemOptions / ShineReward / FriendPointReward>`, `EnchantSocketRateData`, `RandomSlot`, `cWell512Random`: 004137d0 00413910 004139e0 004139f0 00413a00 00413a60 00413d00 00413db0 | §2.4; §2.6 rows 8–9, 11 | 8 |
| `CardDeck::CardStack`, `List*<CardDeck::Card>`: 00413b00 00413cd0 00414590 00414650 004148a0 | §2.6 row 10 (Z09 §28.10) | 5 |
| `CDataReader`: 00429c10 00429c40 00429cb0 00429cf0 00429d50 | §2.6 (W05 §3.1) | 5 |
| `CShnDataFileCheckSum`: 0042a250 0042a400 | §2.6 (W05 §3.4) | 2 |
| `CMD5Checksum`: 0042ae00 0042ae10 0042ae40 0042b520 0042b5d0 0042b7e0 | §2.6 (W05 §6.3) | 6 |
| `Database`, `DBRecord`, `CGameDB_Connect`: 0040e440 0040e470 0040e6c0 0040e730 00412e70 00412e90 00413090 00413140 004156e0 | §2.5 | 9 |
| `type_info`: 00416986 00416996 004169b7 0041f94d | §2.6 (CRT RTTI) | 4 |
| `CParser::CParser`, `CPFs::fc_dummyfunction`: 00404010 00404b70 | D01 §2 (Account FUN_00405290 / FUN_00404750) | 2 |
| `CParser::Parser`: 00404ca0 | §3.4 | 1 |

### 3.7 D01 open point: TEENAGER `nType` 1 (confidence.md §4.6 row 4)

`CPFsAccount::fc_NC_USER_TEENAGER_REQ` FUN_00402610, x87 code at 0x402972–0x4029e9 (objdump):

```pseudo
elapsed = _difftime32(now, mktime(lastLogoff))            # double, seconds since the stored logoff time
fld 17940.0 (DAT_00432960); fcom elapsed                  # elapsed ≥ 17940 → nType 0, nMinute 180 (as D01 says)
elapsed < 17940:
    remain = r.nUserPlayRemainTime (signed compare with 0)
    remain ≥ 1:  nType 0, nMinute = remain
    remain ≤ 0:  fsubrp (DE E1) → 17940.0 − elapsed; _ftol2_sse → int seconds
                 nMinute = seconds / 60 (signed, truncated: magic 0x88888889, sar 5)
                 nType 1
```

So `nType 1` carries **the whole minutes left until 4 h 59 min have passed since the last logoff**, i.e. when the
teen's play time will be reset to 180 minutes; D01's guess is right. The 17940 s window is measured from the stored
logoff time (`dUserLogoff`, written by 0x0C28 with the current time and the remaining minutes). Login refuses nType 1
with 0x4E and does not use `nMinute` (login-server.md §5.1). A logoff time in the future (clock change) gives a negative
`elapsed` and a `nMinute` above 299.

## 4. Character: differences against the Account build

Source `Files/Server/2016/w00_Character/Character Release.exe` (no PDB). A Character function carries the Account
(or AccountLog / WM / zone) PDB name when its decompiled body is identical (`D08-match.py`), or identical after masking
labels, addresses and types (a masked line diff; "near-identical" below, every one checked by reading the diff). Those
names are in `tools/protocol-re/names/character/D08.json` (214 added in this part, 372 in all). D02 §1 already describes
what the server loads and its handler tables; this section adds the process layer under them.

### 4.1 Objects

```
DataServer g_Server   (DAT_004e2a68, 0x20a47c bytes; ctor FUN_00401f20, dtor FUN_00401000)
  +0x000000 CServerInfo m_ServerInfo          DataServerInfo_Character.txt (ReadDefineScriptor FUN_004013b0, Z19 §5.3)
  +0x0004f8 MY_SERVER   m_MyServer            nServerID +0x500 (= 2), nWorldNo +0x504, nZoneNo +0x508
  +0x00050c char[16]    m_ConnectSocket_BindIP   this server's own ServerInfo row IP (copied by ReadDefineScriptor, as in
                                              Account); used here as the local address of the GameLog connect (§4.3)
  +0x00051c CIOCP / +0x00054c CSession_Manager (acceptor +0x558) / +0x009838 CSessionWorkerManager   same as Account (§1.1)
  --- from here the Character members (names ours, inferred from use) ---
  +0x209890 CServerInfo DefaultCharacterData.txt (a CCsl script, D02 §1)   [Account: m_bOnStopService …, indun list]
  +0x209d88 / +0x209dc8 / +0x209e08 CDataReader FaceInfo / HairColorInfo / HairInfo.shn (0x40 each, W05 §3.1)
  +0x209e48 u16[6] hair-shop coupon ids HairShop01 … 05, the sixth read as HairShop05 again (D02 §10); +0x209e54 u16 UniChange01
  +0x209e58 CDataReader HolyPromiseReward.shn (D04 §8)
  +0x209e98 CDataReader promotion reward table: built and destroyed, never loaded (D02 §13)
  +0x209ed8 CDataReader AttendReward.shn (D02 §12)
  +0x209f18 cUKItemShop (0x34; ctor FUN_0043f5b0, dtor FUN_0043f5c0; §5)
  +0x209f4c CServerInfo TutorialCharacterData.txt (D02 §8; its dtor is reached through the thunk to CCsl::~CCsl FUN_00446640)
  +0x20a444 m_bOnStopService   +0x20a448 / +0x20a458 SYSTEMTIME start / stop   +0x20a468 m_bStopMainThread (0x2803 writes
  DAT_006eced0 = this) +0x20a46c m_bActiveMainThread   +0x20a470 / +0x20a474 m_hMainThread / m_MainThreadID
  +0x20a478 CSession* g_GameLogLink (DAT_006ecee0, D02 §1)
```

There are three `CServerInfo` objects (the server's config and two game-data scripts read with the same `CCsl` parser)
and no `SHINE_INDUN_INFO` list. The destructor runs in reverse order (Tutorial script, item-shop vector, the six
`CDataReader`s via FUN_004402a0, the DefaultCharacterData script, workers, sessions, `CIOCP::Close`, the config).

The session pool, `CSession` (0x154), `CSession_Manager` and the acceptor have the Account layout (§1.4). The session
worker is larger:

```
CSessionWorker (0x12a8; ctor FUN_0043e4d0, dtor FUN_0043e420, deleting dtor FUN_0043e550)
  +0x000 … +0x134  as Account (§1.5)
  +0x138  CParserCharacter m_Parser (ctor FUN_0043b040 = CParser::CParser FUN_0043d2f0 + the D02 / D03 / D04 registrations)
  +0x124c DB object (0x5c, ctor FUN_0046e0d0): DBRecord (0x14, §2.5) + procedure-class bases (one RTTI name visible:
          `CSQLPPrison`, vftable at +0x1268) and pointer tables into itself; the handlers' "*this + 0x124c" (D02 §1.1)
```

### 4.2 Start-up, main thread, stop

```pseudo
DataServer::Start(this, cmdLine):                                             @ FUN_00402570   (Account FUN_00401d20, §1.2)
    chdir(exe directory); banner "Launching the server....."; ViewStartInfo FUN_00401130
    !ReadDefineScriptor(this) → return −1          # FUN_004013b0: "DataServerInfo_Character.txt", "<I AM THE %s, …>"
    !GameData_Load(this)      → return −4          # FUN_00401550, below; replaces Account's MapInfo-only step
    !ParseCmd(this, cmdLine)  → return −2          # FUN_00402040, same as Account
    WinService singleton; startDispatcher(m_MyServer.pServiceName, ::OnStart_Service, ::OnStop_Service); return 0

GameData_Load(this) → 1 ok / 0 failed:                                        @ FUN_00401550   (D02 §1; return value read in the asm)
    every file: "../../9Data/Shine/<f>", then "../9Data/Shine/<f>"; neither → "*FAILED GLOBAL GAME DATA READ - <f>", return 0
    ItemInfo.shn            → g_ItemInfo (itemdatabox): FUN_0044a320 (fopen probe, then ItemDataBox::ReadData FUN_0044a060,
                              Z24 §7.3: ItemInfo only, name trie for idb_2itemid FUN_00402cf0)
    DefaultCharacterData.txt → +0x209890 (CServerInfo::ReadServerInfo, CCsl)
    FaceInfo.shn, HairColorInfo.shn, HairInfo.shn → CDataReader::Read(path, key, rowSize) FUN_00441c80 with
                              (0x45f, 0x3a), (0xc5, 0x3e), (0x3a4d, 0x1e8)   # the file's first u32 must equal key and its
                              u32 at +0x2c (record length) − 2 must equal rowSize (W05 §3.1 Shn_LoadChecked)
    HairShop01 … HairShop05 by idb_2itemid; any missing → "*Not found HAIRSHOP_ITEMGRADE_<n>, ItemIndex = HairShop0<n>"
                              for each, return 0;  UniChange01 missing → "*Not found HAIRSHOP_ITEM_GENDER …", return 0
    HolyPromiseReward.shn (0x2a1, 0x46); every row's item index must exist, else log
                              "ERROR - HOLY_PROMISE_REWARD Unknowned Level=%3d, Class=%2d, item = '%s'" per row, return 0
    AttendReward.shn (0x98, 0x26); the first row with an unknown item → "ERROR - AttendReward Invalid Item : RewardID(%d),
                              Index(%s)", return 0
    TutorialCharacterData.txt → +0x209f4c
    nServerID == 2: MapInfo.shn → g_MapInfo (mapdatabox, MapDataBox::CheckReadData FUN_00449be0 → mdb_Load FUN_004497f0, §2.2)
    return 1
```

Every table is checked at start and any gap stops the start (−4): the server never runs with a partial table set. The
SHN reads go through `CDataReader::Read(path)` FUN_00441a20 (near-identical to the Account / WM copy, W05 §3.1), which
also registers the file's MD5 in `ShnDataFile` (`CShnDataFileCheckSum::InitDataFileCheckSum` FUN_00442b20,
`CMD5Checksum::GetMD5` FUN_004440d0 / `Final` FUN_00443f20 *(inferred from the structure; the body differs from Account's
in the decompiler only)*). `CShnDataFileCheckSum::CShnDataFileCheckSum` FUN_00442cd0 has the Account / WM list of 49
client file names (identical after masking): of the files read here only ItemInfo.shn and MapInfo.shn are on it, and
nothing in the Character server reads the stored digests.

```pseudo
DataServer::OnStart_Service(this):                                            @ FUN_004027a0   (Account FUN_00401f10)
    !cUKItemShop::Init(&m_ItemShop (+0x209f18), 0) (FUN_0043f690, §5) → log "FAILED - UK ItemShop Init"; return false
    m_bOnStopService = 1
    CIOCP::Start(5 × CPU, wait 1), "<NUMBER OF %d IOCP WORKTHREAD STARTED, %d CPU DETECTED>"; n ≠ 5 × CPU → false
    m_PacketQueSize = 0; CSessionWorkerManager::Start(-1, 1) FUN_0043e9e0 (same as Account: min(10 × CPU + 1, 81)
        workers, 0x12a8 bytes each, one ODBC link each); Start_Acceptor FUN_00401bb0; Start_MainThread FUN_00402720
    log "SERVER WORK START ---…"
    # Character only: one job queued to itself
    s_SelfSession = static CSession (DAT_004e2908, built on first use, guard bit DAT_004e2a5c & 1, atexit dtor)
    frame = { u8 2, u16 0xC414 }                    # NC_COLLECT_CHARACTERDB_UP_GET_CARDCOUNT_CMD, no body
    while CSessionWorkerManager::AddQue(&m_SessionWorkerManager, &s_SelfSession, frame, 3) == 0: Sleep(2)
    return true
```

The 0xC414 handler (`LAB_00427cf0`, D03 §12) has no `CheckAlive`, so the first free worker runs it although the session
was never connected (`m_Connection` 0): the collection-card serial counters are loaded right after start. No zone or WM
build sends 0xC414 (the open point of Z28 §7), so this self-job is the only load: if it fails ("ERROR -
fc_NC_COLLECT_CHARACTERDB_UP_GET_CARDCOUNT_CMD, DB Data Get Fail") nothing retries it and every new sealed card is saved
without serial until the next restart (D03 §12's effect). This corrects D03 §12 / knowledge D03 "loaded only when a zone
sends 0xC414" (knowledge D08 §0). An item-shop failure stops the start before the IOCP threads, workers and listener exist;
the other failure paths leave threads running as in Account (D05-B10).

```pseudo
DataServer::MainThread(this):                                                 @ FUN_004023c0   (Account FUN_00401620, §1.3)
    log "<MAIN THREAD START>"; m_bActiveMainThread = 1
    while m_bStopMainThread == 0:
        Sleep(1000); CSession_Manager::ProcHeartBeat(&m_SocketSessionManager)
        if g_GameLogLink == null: CSession::ConnectToGameLog(this)            # FUN_00401cd0, §4.3: once a second until connected
    the Account tear-down (listener, workers, DissconnectSessions, CIOCP::Close, CloseSessions, ViewStopInfo FUN_00401270)
    m_bActiveMainThread = 0; m_bOnStopService ≠ 0 → "<SERVER MANUAL STOPPED>", return 0; else "<SERVER SELF STOPPED>", exit(0)
```

`DataServer::OnStop_Service` FUN_00401100, `Start_MainThread` FUN_00402720 ("*FAILED CREATE MAIN THREAD*"),
`ViewStartInfo` / `ViewStopInfo` FUN_00401130 / FUN_00401270 are the Account code with the members moved (§4.1). The
0x2803 handler FUN_0043d000 writes `m_bStopMainThread`, so D08-B2 holds here too. A blocking connect to a silent
GameLog host holds the main thread (no heartbeat checks, a stop request waits) for the TCP connect timeout of every
attempt (S02-B5, *inferred*: the Windows default is about 21 s).

### 4.3 The GameLog link

The Character server is the only DB server that connects out. D02 §1 / §2 describe what is sent on the link and the
0x0802 rule ("links are refused until GameLog is connected"); the link itself:

```pseudo
CSession::ConnectToGameLog(this)   (name from its log text)                   @ FUN_00401cd0
    row = CServerInfo::GetServerInfo(&g_Server, type 3 = GameLog, nWorldNo, nZoneNo)   # PG_W00_GLDB, port 9511 (§1.2)
        none → log "CSession::ConnectToGameLog()에서 서버 연결정보를 찾을수 없음, 스크립터 확인필요"
               ("… cannot find the server connection info, check the script"); return
    ip = row.pIP; "" → InetAddress::GetHostAddress() (this host)
    s = CSocket_IOCP (stack object)
    if !CSocket_IOCP::Connect(&s, m_ConnectSocket_BindIP, 0, ip, row.port):   # FUN_0044b800 = S02 §1.5 (blocking)
        if s_bLinkUp (DAT_004d7000, initially 1): s_bLinkUp = 0; log "CONNECT TO GAMELOG SERVER TO %s:%d"
        # the line is written once per outage, at the first failed attempt (the text reads like an attempt notice)
    else:
        e = CSession_Manager::ActiveSession(&m_SocketSessionManager, socket, …)   # a pooled session, registered with the IOCP
        none (pool full) → close the socket (next try in 1 s)
        else: g_GameLogLink = e.pSocketSession; .m_Connection = 2; .m_Connected_Server_ID = 3; socket handed over; s_bLinkUp = 1
    ~CSocket_IOCP(&s)

handshake on that session (handlers of D02 §2, X02 knowledge §0, row D02 §2):
    GameLog accepts and sends 0x0801  → fc_NC_MISC_S2SCONNECTION_RDY FUN_0043c7a0: send 0x0802 { echo (never written,
        X02-B12), to 3, from nServerID, world nWorldNo, zone 0, key from + 3 }
    GameLog answers 0x0803 { u16 err } → fc_NC_MISC_S2SCONNECTION_ACK FUN_0043cd20: err == 0 → m_Connection = 1,
        log "Connected to   %p (%-25s world=%3d zone=%3d, …)"; err ≠ 0 → nothing (the link stays at 2)

close of any session:   CSession_Manager::InactiveSession(list entry)          @ FUN_0043de40   (Account FUN_00405d60, §1.4)
    under the manager lock: m_Connection ≠ 0 → log "Closed    from %p (…)";
        m_Connected_Server_ID == 3 → g_GameLogLink = null; log "GAMELOG SERVER DISSCONNECT, WILL RECONNECT TO GAMELOG"
    CSocket_Session_Manager::InactiveSession (back to the pool)
```

`g_GameLogLink` is set as soon as the TCP connect succeeds, before the handshake: 0x0802 requests of WM / zone links are
accepted from then on, and the log packets that handlers send in that first round trip arrive at GameLog before its
0x0803 has authenticated the link (GameLog's `CheckAlive` drops them, D05 §7.2) *(inferred: a few milliseconds)*. The
pointer is cleared on the IOCP thread and read by the workers without a lock; a worker that read it just before the close
sends into a pooled session, possibly reused by another peer (the D08-B3 pattern) *(inferred)*. The close test looks only at
`m_Connected_Server_ID == 3`, not at `g_GameLogLink`: an incoming link that announced itself as server type 3 in its
0x0802 (the 0x0802 handler accepts any `server_id_from`) clears the pointer when it closes, while the real GameLog link
stays open and unused, and the main thread opens a second one **(original bug) D08-B5**.

`CSession_Manager::FindSession(type, from)` FUN_0043dc20 is the AccountLog function of §3.3 (identical after masking):
the first list node at or after `from` (null = head) whose session has `m_Connection == 1` and
`m_Connected_Server_ID == type`. Its only caller is `SendToWorldManager` FUN_00402d80 (D03), with type 5 = the WM and
`from` = null: the first authenticated WM link (one per world).

### 4.4 Workers, the DB link, the parser

- `CSessionWorker::DB_Init` FUN_0043e040: `CServerInfo::GetODBCInfo(id 10 = w00_Character, nWorldNo)` (Account: id 0);
  none → "DB_Init FAILED, Scriptor BASE ODBC info. not found."; `CGameDB_Connect::DBConnect` failure → "DB_Init FAILED = "
  + the reason. One link per worker, as in Account (AccountLog has two, §3.4).
- `CSessionWorkerManager::Start` FUN_0043e9e0: the Account code (§1.5) with `new CSessionWorker` of 0x12a8 bytes.
- `~CSessionWorker` FUN_0043e420: Account's plus the reset of the `CSQLPPrison` base (FUN_004659d0) before `~DBRecord`.
- `CParser::CParser` FUN_0043d2f0: the D01 §2 base table (2/1 RDY, 2/2 REQ, 2/3 ACK, 2/4 heartbeat `LAB_0043cdf0`, 2/5
  `fc_ReturnTrue`, 10/1, 10/3, 10/5, 10/7 OPTool, 2/0x23 `fc_CheckAliveOnly`; default `CPFs::fc_dummyfunction`
  FUN_0043c6d0); `CParser::Parser` FUN_0043d420 is the AccountLog dispatcher of §3.4 (identical body).
- Transactions: `Database::CommitTran` FUN_00451e70 is reached only from `close` / `openDB` / `~Database` and no code
  sets `m_bTran`: the Character server runs in autocommit like Account (§2.5). `Database::InitEnv` FUN_00451dd0 is the
  Account copy, so D08-B4 holds.
- The session layer below (`CSession`, `CSession_Manager`, `CSocket_*`, `CIOCP*`, `CPacket`, `CSendPacket`) is the Account
  code (§1.6 Character column); `CSession::~CSession` FUN_0043d9c0 / deleting dtor FUN_0043db60, `Accept_Process`
  FUN_0043dfb0 and `CIOCP::Stop` FUN_004471f0 differ only in labels.

### 4.5 Game data in the Character server (replaces the part-2 guess in §2.1)

| Table / object | Loaded | Read by |
|---|---|---|
| ItemInfo.shn → `itemdatabox` (`g_ItemInfo` DAT_006ed408) | `GameData_Load` | `idb_2itemid` and the row getters of the item handlers (D02 §3 create, D03, D04, D07; 20 functions) |
| DefaultCharacterData.txt, FaceInfo / HairColorInfo / HairInfo.shn, hair-shop ids, HolyPromiseReward.shn, AttendReward.shn, TutorialCharacterData.txt | `GameData_Load` | D02 §3 (create), §10 (beauty shop), §12 (attendance), §8 (tutorial); D04 §8 |
| MapInfo.shn → `mapdatabox` (`g_MapInfo` DAT_006ecee8) | `GameData_Load` (nServerID 2) | only `GetCharBaseData` FUN_0046e2e0 (D02 §4: the 37th column's map name → `mdb_btree`, then `mdb_index` for RegenX / RegenY) |
| `itmattcontainer` (`g_ItemAttrClassContainer` DAT_006ef2e8) | static constructor | `ItemAttributeClassContainer_Get` FUN_0044d380 from the item-record builders and readers (D03 / D07 §1.3): vtable slots 1 `iac_fill2buffer`, 2 `iac_fill2struct`, 32 / 33 `iac_SetItemOptionUpgrade` / `iac_ClearItemOptionUpgrade` (slot names from the Account vtables) |
| `itemoptiondata`, `rewarddata`, `fprewarddata`, `rndbox`, `charinvenman`, `g_ItmBelongAttr`, `ShnDataFile` | static constructors (§2.1) | nothing (`rndbox` is filled at start-up and never read) |

No Character code calls vtable slot 5 (`iac_itemcreate`): the reward-item path writes records itself (D07 §1.3), so the
`ItemAttrCls_*::iac_itemcreate` bodies and their stubs `RidingInitHungry` FUN_00401e80 (returns 100) and the folded
"return 0" FUN_00401e90 (`RidingInitHP`, `WeaponCostumInitCharge`; read by `ItemAttrCls_Riding::iac_itemcreate`
FUN_0044e3b0 and `ItemAttrCls_CostumWeapon::iac_itemcreate` FUN_0044e480) are dead here as in Account.

### 4.6 Library code the Character build links in addition

- MSVC `<sstream>` / locale / `num_put` instantiations (0x43eed0–0x4493b0 below): used by `SQL_BuildCallString`
  FUN_00460bf0 (D06 §7.2: `std::stringstream` builds `"{CALL name(?,…)}"`) and the item-shop client's `std::string`s (§5).
  Standard library; nothing project-specific.
- The crash-dump helpers of `MiniDumper` (`FillInStackFrame`, `EHInternalGetStackTraceString`, `GetFaultReason`, …): the
  WM bodies (W05 §6.3).
- `cWell512Random::well512_GetRandom` FUN_004515f0 / FUN_004516a0: W05 §6.4 (only `RandomBox` uses them; dead here).

### 4.7 Address table (Character)

Character addresses for the "–" cells of §1.6:

| Function | Character | Difference |
|---|---|---|
| `DataServer::~DataServer` / `DataServer::DataServer` | FUN_00401000 / FUN_00401f20 | §4.1 members |
| `DataServer::OnStop_Service`, `ViewStartInfo`, `ViewStopInfo`, `Start_MainThread` | FUN_00401100, FUN_00401130, FUN_00401270, FUN_00402720 | member offsets only |
| `DataServer::ReadDefineScriptor` | FUN_004013b0 | file name only |
| `DataServer::MainThread`, `Start`, `OnStart_Service` | FUN_004023c0, FUN_00402570, FUN_004027a0 | §4.2 |
| `CSession_Manager::InactiveSession` | FUN_0043de40 | clears `g_GameLogLink` (§4.3) |
| `CSocket_Acceptor_Process_Manager_App::Accept_Process` | FUN_0043dfb0 | labels only |
| `CSessionWorker::DB_Init`, `~CSessionWorker`, `CSessionWorkerManager::Start` | FUN_0043e040, FUN_0043e420, FUN_0043e9e0 | §4.4 |
| `CIOCP::Stop`, `CGTimer::GetTime` | FUN_004471f0, FUN_004503b0 | labels only |

Character functions identical (or near-identical, marked ~) to the cited Account / WM / zone function and cited by no
other document (the SOAP classes of 0x43f310–0x43f660 are §5's):

| Class (Character functions) | Same as | n |
|---|---|---|
| `ItemAttributeClass` + `ItemAttrCls_*`: 0044d440 0044d460 0044d4b0 0044d4d0 0044d500 0044d520 0044d540 0044d590 0044d5b0 0044d5c0 0044d5e0 0044d600 0044d620 0044d630 0044d640 0044d680 0044d690 0044d6a0 0044d740 0044d750 0044d760 0044d770 0044d790 0044d7a0 0044d7b0 0044d7c0 0044d7d0 0044d7e0 0044d7f0 0044d840 0044d870 0044d960 0044ddd0 0044de80 0044df00 0044df40 0044dfe0 0044e110 0044e1b0 0044e250~ 0044e2a0 0044e2c0 0044e340 0044e360 0044e3b0 0044e400 0044e480 0044e4b0 0044e4d0 0044e510 0044e530 0044e550~ 0044e5e0 0044e620 0044e650 0044e700 0044e720 0044e740 0044e770 0044e790 0044e7b0 0044e7d0 0044e810 0044e8c0 0044e940 0044e960 0044e9a0 0044e9e0 0044ea90 0044ead0 0044eb10 0044eb50 0044eb90 0044ebd0 0044ec60 0044ece0 0044eda0 0044ee00 0044ee20 0044ee50 0044ee80 0044eea0 0044ef20 0044ef40 0044ef90 0044f140 0044f160 0044f170 0044f190 0044f1b0 0044f1d0 0044f1f0 0044f210 0044f230 0044f240 0044f270 0044f290 0044f2b0 0044f2d0 0044f300 0044f670 0044f6a0 0044f7f0 0044f810 0044f830 0044f850 | §2.6 row 1 (Z04 §1); used slots §4.5 | 106 |
| trivial folded bodies (8 lines: return a constant, the argument or a member address, or empty; shared by many vtable slots of the item, gamble, class and STL classes, so no single name applies), incl. the `RidingInitHP` / `WeaponCostumInitCharge` fold FUN_00401e90: 00401e90 0043ed70 0043f370 0043f410 0043ffa0 0043ffe0 00440380 00440390 004403a0 004403b0 004403c0 004403d0 0044d420 0044d430 0044d450 0044d470 0044d480 0044d490 0044d4a0 0044d4c0 0044d4e0 0044d4f0 0044d510 0044d530 0044d550 0044d560 0044d570 0044d580 0044d5a0 0044d5f0 0044d610 0044d660 0044d670 0044d780 0044ddb0 0044ddc0 0044de00 0044de10 0044de20 0044de30 0044de40 0044de50 0044de60 0044de70 0044e5d0 0044e6f0 0044e9d0 0044eb00 0044ecb0 0044ecd0 0044ed90 0044edf0 0044ee10 0044ee90 0044ef80 0044f180 0044f260 0044ff70 004517d0 004518c0 00451a90 00452780 | – | 62 |
| `ItemDataBox`, `BinaryDataBox<ItemInfo / ItemInfoServer / GradeItemOption / ItemDropLog / ItemSort / ItemInvenDel / ItemMoney>`, `ItemBelongAttribute`; FUN_0044a320 = the fopen probe before `ItemDataBox::ReadData` (shape of `MapDataBox::CheckReadData`, no official name): 00402cf0 00449c20 00449c40 00449c50 00449c60 00449c70 00449c80 00449c90 00449ca0 00449cd0 00449d00 00449d30 00449d60 00449d90 00449dc0 00449df0 00449f90 0044a060 0044a270 0044a2f0 0044a320~ 0044a360 004517e0 00451820 | §2.6 rows 3, 6 (Z27 §1.1, Z24 §7.3); §4.2, §4.5 | 24 |
| `MapDataBox`, `BinaryDataBox<MapInfo>` (`bdb_ReadData` differs only in inlined code addresses), `BinaryData`, `BTree`: 00449740~ 004497f0~ 00449a90 00449ad0 00449b60 00449be0 0044ccc0 0044cce0 0044cd10 004503e0 00450400 00450410 | §2.2; §2.6 row 5 | 12 |
| `CDataReader` (incl. `Read(path)` FUN_00441a20), `CShnDataFileCheckSum` (incl. the ctor FUN_00442cd0), `CMD5Checksum` (`Final` FUN_00443f20, inferred): 0043fd50 0043fd80 004402a0 00440fd0 00441a20~ 00441c80 00442b20 004436d0 004436e0 00443710 00443df0 00443f20~ 004440d0~ | §2.6 (W05 §3.1, §3.4, §6.3); §4.2 | 13 |
| `ItemOptionsData`, `OptionCardStack`, `BinaryDataBox<ItemOptions / ShineReward / FriendPointReward>`, `EnchantSocketRateData`, `RandomBox`, `RandomSlot`, `cWell512Random`, `CardDeck::CardStack`, `List* / ListEraser<CardDeck::Card>`, `List<AbnormalStateContainer::AbnormalStateNode>`: 00451580 004515c0 004515f0~ 004516a0~ 00451700 004517f0 00451850 004518d0 00451ab0 00451ac0 00451b50 00451ba0 00451c30 004521d0 00452390 00452490 00452680 004526b0 004526e0 00452730 00452790 004527d0 00452840 00452890 00452a10 00452a90 | §2.4; §2.6 rows 8–11 (Z09 §28.10, W05 §6.4) | 26 |
| `Database`, `DBRecord`, `CGameDB_Connect`: 0043e030 0044fab0 0044fad0 0044fde0 0044fe60 0044fed0 00451db0 00451dd0 00451e70 00451fd0 00452010 00452080 | §2.5; §4.4 | 12 |
| `CharacterInventoryManager` (`cim_inven` +0xe54; the two accessors FUN_0044ff90 / FUN_0044ffa0 return +0x4f98 / +0x51e0 where Account's `cim_quest` / `cim_minihouse` return +0x6558 / +0x67a0: another `CharacterInventory` layout, inferred; no code calls them): 0044ff80 0044ff90~ 0044ffa0~ | §2.1 | 3 |
| process layer: `CPFs::fc_dummyfunction`, `CParser::Parser`, `CSession::~CSession`, `inet_ntoa` thunk, `GetCurrentTimeString2`, `_DEBUGMSGVC`, `CSocket_IOCP::Connect`, `CSendPacket::GetSendSize / GetSendPtr`: 0043c6d0 0043d420 0043d9c0~ 0043fbcc~ 00447630 00447940 0044b800 0044f9d0 0044f9f0 | §1.6, §3.4, §4.3, §4.4; S02 §1.5 | 9 |
| `MiniDumper` crash-dump helpers (`FillInStackFrame`, `CH_ReadProcessMemory`, `EHConvertSimpleException`, `EHInitSymbolEngine`, `EHCleanupSymbolEngine`, `EHInternalGetStackTraceString`, `GetFaultReason`, `GetFirstStackTraceString`, `GetNextStackTraceString`): 00450960~ 004509e0 00450a10 00450c60 00450c90 00450cc0~ 004510c0~ 00451510 00451570 | W05 §6.3 | 9 |
| MSVC STL / CRT: `std::basic_string`, `basic_stringstream` / `stringbuf` / `streambuf` / `ios_base` / `istream` / `ostream`, `locale` facets (`ctype`, `numpunct`, `num_put`, `codecvt`), `bad_alloc` / `logic_error` / `runtime_error` / `system_error` / `ios_base::failure`, `allocator`, catch funclets: 0043eed0 0043ef00 0043ef20 0043ef80 0043efd0 0043f113~ 0043f13c 0043f19b~ 0043fbe0 0043fc10 0043fc50 0043fc60 0043fcb0~ 0043fce0 0043fd20~ 0043fdf0~ 0043fe00 0043fe10~ 0043fe30 0043fe60 0043fe80 0043fea0~ 0043ff00 0043ff20 0043ff50 0043ff70 0043ffb0 0043fff0 00440020~ 00440080 00440160 00440180 004401b0 00440240 00440270 004402e0 00440300~ 00440410~ 004404e0~ 004405b0 004405e0 00440610 00440660 004406d0 00440890 004409b0~ 004409f0~ 00440a60~ 00440ac0~ 00440af0 00440be0 00440c20 00440c50 00440d78~ 00440d90 00440e40 00440ef0 00441030~ 004410b0 00441140~ 004412f0 00441430 00441440 00441450~ 004414a0~ 004414c0 00441510~ 00441550 0044167c~ 004416f0 00441743~ 00441750 00441770 00441790 004417b0~ 004418a0 00441950 00441cc0 00441d30 00441de0 00442056~ 004420a0 004421e0 00442220 00442270 004422c0 00443ea0~ 00447980 00447a10 00447a80 00447af0 00447b90 00447c50~ 00447d50 00447e90 00448153~ 004481a0~ 00448270~ 004482a7~ 00448320~ 00448890~ 00448b20~ 00448b80~ 00448da0 00448ea0 00448f20 004491b0~ 004493b0 0044c580 | – (§4.6) | 109 |

385 functions; `~` = near-identical (labels, inlined code addresses or decompiler types differ; the diff was read).

---

## 5. Character: the SOAP item-shop client (`cUKItemShop`, gSOAP 2.8)

The Character server answers the WM's 0x0870 (the in-game item-shop button, W01 §5.3) by asking a gamigo web service
for a per-account shop URL. The client is a gSOAP 2.8 proxy (`gSOAP/2.8` in the User-Agent string FUN_004825e0;
generated code 0x46ed40–0x47d55f, runtime `stdsoap2` 0x47d560–0x48ce80). Account and AccountLog include the same header
(their PDBs have the types `cUKItemShop`, `SingleSignOnServiceSoapBindingProxy`, `soap`, `ns1__*` *(pdb2016)*) but
link none of its code. The gSOAP function names used below are library names, matched by structure, call order
and strings to the gSOAP 2.8 sources *(inferred)*; the class, member and vtable names come from RTTI and the Account
PDB types.

### 5.1 Objects

```
cUKItemShop (0x34, g_Server+0x209f18 = DAT_006ec980; member names (pdb2016) from Account.pdb):
    +0x00 _RTL_CRITICAL_SECTION m_CS          guards the list
    +0x18 HANDLE m_hSemaphore                  count = free proxies
    +0x1c ulong m_dwMaxProcessNum              pool size
    +0x20 SingleSignOnServiceSoapBindingProxy** m_pSoap      array of the pool (only tested for null after Init)
    +0x24 std::vector<SingleSignOnServiceSoapBindingProxy*> m_pSoapList   the free list (LIFO)
    ctor FUN_0043f5b0 zeroes the vector; dtor FUN_0043f5c0 frees the vector's buffer only (the proxies, the array, the
    semaphore and the critical section are never released; the process is ending anyway)
SingleSignOnServiceSoapBindingProxy : soap (0x1d6c0): +0x1d6bc char* soap_endpoint; 20 virtual slots (§5.6)
soap (gSOAP context, layout (pdb2016) from Account.pdb): +0x8 mode, +0xc imode, +0x10 omode, +0x34 recv_timeout,
    +0x38 send_timeout, +0x3c connect_timeout, +0x40 accept_timeout, +0x6c alist (allocations of soap_malloc),
    +0x5fec… callback table (fpost … fplugin), +0x60c4 socket, +0x19178 keep_alive, +0x191a8 error
ns1__getItemShopUrlRequest  (0x24): +0x4 std::string accountId, +0x20 soap* soap   (ctor FUN_0043f310, dtor FUN_0043f380)
ns1__getShopUrlResponse     (0x24): +0x4 std::string url,       +0x20 soap* soap   (ctor FUN_0043f3b0, dtor FUN_0043f420)
namespaces table PTR_s_SOAP_ENV_004c97c0: SOAP-ENV http://schemas.xmlsoap.org/soap/envelope/, SOAP-ENC …/soap/encoding/,
    xsi http://www.w3.org/2001/XMLSchema-instance, xsd http://www.w3.org/2001/XMLSchema,
    ns1 http://infrastructure.games.gamigo.com/v_1_3          # SOAP 1.1, document/literal
endpoint (string 004bb5a0, compiled in, no config key): http://bip.srv.gsc.gas.gamigo.com:8080/gameserverconnector-webapp-fiesta-us/sso
```

### 5.2 Start-up: building the pool

```pseudo
cUKItemShop::Init(this, nCount) → 1 ok / 0 failed:   (our name; log "FAILED - UK ItemShop Init")   @ FUN_0043f690
    # called once, first step of DataServer::OnStart_Service FUN_004027a0 with nCount 0 (§4.2); 0 → the start fails
    m_dwMaxProcessNum = nCount ≠ 0 ? nCount : max(1, (CPU × 10) >> 1)        # 5 per CPU (GetSystemInfo)
    InitializeCriticalSection(&m_CS)
    m_hSemaphore = CreateSemaphoreA(null, n, n, null);      null → return 0
    m_pSoap = new Proxy*[n] (FUN_0048ce81);                 null → return 0
    for i in 0 … n−1:
        p = new SingleSignOnServiceSoapBindingProxy(endpoint)  (0x1d6c0 bytes; ctor FUN_0047d520, §5.6)
        p == null: delete the proxies 0 … i−1 (virtual dtor), delete[] m_pSoap; return 0
            # m_pSoap keeps the freed pointer and m_pSoapList the freed proxies; harmless, the start stops here
        m_pSoap[i] = p; m_pSoapList.push_back(p) (FUN_0043f5f0, grow FUN_0043f450)
    return 1
```

The proxy constructor runs `soap_init2(this, 0, 0)` FUN_0048c5d0 (via `soap::soap` FUN_0048cdd0): input and output mode
`SOAP_IO_DEFAULT`, no keep-alive, and **all four timeouts 0** (`+0x34 … +0x40`, FUN_0048c5d0 is the only code in the
binary that writes them; nothing in the Character code changes them afterwards). It then sets the namespaces table
(`soap_set_namespaces` FUN_00483230) and `soap_endpoint` = the URL above. Nothing connects at start: the shop host is
first contacted by the first 0x0870.

### 5.3 0x0870 NC_MISC_ITEMSHOP_URL_DB_REQ

```pseudo
0x0870 NC_MISC_ITEMSHOP_URL_DB_REQ { u32 nCharNo, u32 nUserNo }   (from the WM; no length check)
                                                       @ fc_NC_MISC_ITEMSHOP_URL_DB_REQ FUN_00428bb0 (D02 §9)
    CheckAlive(session) fails → return 0
    cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ(&g_Server.m_ItemShop, payload, session); return 1

cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ(this, req, session):   (name from its log strings)   @ FUN_0043f7f0
    # runs on the session worker that took the job (§1.5); everything below blocks that worker
    m_pSoap == null: log "cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ : Not Init Soap"; return      # no reply
        # unreachable: Init failing stops the start (§5.2)
    r = WaitForSingleObject(m_hSemaphore, 0)                                   # no waiting
    r == WAIT_TIMEOUT (0x102):                                                 # every proxy is in use
        Send session 0x0871 NC_MISC_ITEMSHOP_URL_DB_ACK { u32 nCharNo = req.nCharNo, u16 nError = 0x3042, u16 nLen = 0 }
        return
    r ≠ 0: return                                     # WAIT_FAILED: no reply, no log (unreachable with a valid handle)
    under m_CS: p = m_pSoapList.back(); pop_back()    # LIFO; the semaphore guarantees the list is not empty
    request = ns1__getItemShopUrlRequest { accountId = sprintf("%d", req.nUserNo) }   # signed decimal
    response = ns1__getShopUrlResponse { url = "" }
    err = p->getItemShopUrl(&request, &response)      # vtable +0x44 FUN_0047cd00 → +0x40 FUN_0047d0b0, §5.4
    err == SOAP_OK (0):
        nLen = (u16) response.url.size()
        strncpy(packet.Data + 8, response.url, nLen)  # no check against the 8187-byte packet buffer (original bug) D08-B7
        Send session 0x0871 { u32 nCharNo = req.nCharNo, u16 nError = 0x3040, u16 nLen, char sURL[nLen] }   (size nLen + 8)
    else:
        Send session 0x0871 { u32 nCharNo, u16 nError = 0x3043, u16 nLen = 0 }
        p->soap_sprint_fault(buf, 0x800) (vtable +0x34 FUN_0047ce70 → soap_sprint_fault FUN_00484500:
            "Error <err> fault: <faultcode> [<subcode>]\n\"<faultstring>\"\nDetail: <detail>")
        log "ERROR - cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ : soap fail ErrCode : %d\n%s" (err, buf)
    under m_CS: m_pSoapList.push_back(p)
    !ReleaseSemaphore(m_hSemaphore, 1) → log "ERROR - cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ Semaphore Release Error"
    # no soap_destroy / soap_end on p (original bug) D08-B8
```

Codes (2017 PDB struct `PROTO_NC_MISC_ITEMSHOP_URL_DB_ACK { ulong nCharNo; ushort nError; ushort nLen; char sURL[0] }`
*(pdb2017)*, matches the 2016 send): 0x3040 ok, 0x3042 busy, 0x3043 SOAP failure; 0x3041 is the WM's own rate-limit
code (W01 §5.3, one request per session per 5 s). The WM copies `nError`, `nLen`, `sURL` into the client's 0x086F
(W01 §5.3, FUN_0040e090). The client (`GameFrameWork::On_NC_MISC_ITEMSHOP_URL_ACK` FUN_004b40f0): 0x3041 / 0x3042 /
0x3043 → system message "Please try later." (text 0x265a978f); 0x3040 → `ShopWin::SetItemShopUrl(sURL, nLen)` and the
shop window opens; any other code is ignored. An answer without `<ns1:url>` is accepted (the element is optional
outside `SOAP_XML_STRICT`, FUN_00479db0): 0x3040 with `nLen` 0, an empty shop window.

### 5.4 The `getItemShopUrl` call on the wire

```pseudo
SingleSignOnServiceSoapBindingProxy::getItemShopUrl(endpoint, action, req, resp):   @ FUN_0047d0b0
    soap_endpoint = endpoint ?: soap_endpoint ?: "http://localhost:8080/sso"   # the pool always has the gamigo URL
    action = action ?: "getItemShopUrl"
    encodingStyle = null                                           # document/literal
    soap_begin FUN_00483100; soap_serialize___ns1__getItemShopUrl FUN_0046fc80
    soap_begin_count FUN_00485400; if mode & SOAP_IO_LENGTH: serialise once to count the length
        (soap_envelope_begin_out FUN_0048b6a0, soap_putheader FUN_0046f760, soap_body_begin_out FUN_0048b7f0,
         soap_put___ns1__getItemShopUrl FUN_0046fcb0, soap_body_end_out FUN_0048a4c0, soap_envelope_end_out FUN_0048a1f0);
    soap_end_count FUN_0047eac0
    soap_connect FUN_0048cc30 → soap_connect_command(SOAP_POST 2000) FUN_0048b870: tcp_gethost FUN_0047e420 (name lookup
        every call), tcp_connect FUN_00481d90 (new socket every call), http_post FUN_004825e0 + soap_puthttphdr FUN_00480b90
    the same serialisation again to the socket; soap_end_send FUN_0048a550
    any error so far → return soap_closesock FUN_0047e6c0 (= the error)
    soap_begin_recv FUN_00487d50 (reads and parses the HTTP answer, http_parse FUN_00484d00), soap_envelope_begin_in
        FUN_0048a340, soap_recv_header FUN_00480710, soap_body_begin_in FUN_0048a500
    resp->soap_get(soap, "ns1:getItemShopUrlResponse", "ns1:getShopUrlResponse")   # FUN_0047ca60 → FUN_00479db0, child <ns1:url>
    soap.error ≠ 0 → return soap_recv_fault FUN_004884d0 (parses a SOAP-ENV:Fault, soap_get_SOAP_ENV__Fault FUN_0047c700)
    soap_body_end_in FUN_00488490, soap_envelope_end_in FUN_00488460, soap_end_recv FUN_00485700
    return soap_closesock FUN_0047e6c0       # keep_alive 0: the socket is closed after every call
```

The request (read in `http_post` / `soap_puthttphdr` / the serialisers; not captured, the shop traffic is not in any
capture):

```
POST /gameserverconnector-webapp-fiesta-us/sso HTTP/1.1
Host: bip.srv.gsc.gas.gamigo.com:8080
User-Agent: gSOAP/2.8
Content-Type: text/xml; charset=utf-8
Content-Length: <n>
Connection: close
SOAPAction: "getItemShopUrl"

<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:SOAP-ENC="…/soap/encoding/"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"
  xmlns:ns1="http://infrastructure.games.gamigo.com/v_1_3"><SOAP-ENV:Body>
  <ns1:getItemShopUrl><ns1:accountId>{nUserNo}</ns1:accountId></ns1:getItemShopUrl>
</SOAP-ENV:Body></SOAP-ENV:Envelope>
```

The expected answer is `<ns1:getItemShopUrlResponse><ns1:url>…</ns1:url></ns1:getItemShopUrlResponse>` (type
`ns1:getShopUrlResponse`, also the answer type of `getCashShopUrl`). Error values reaching the 0x3043 log are gSOAP's:
28 `SOAP_TCP_ERROR` (name lookup ("get host by name failed in tcp_connect()") or connect failed, read in `tcp_connect` FUN_00481d90:
`0x1c`), an HTTP status
≥ 300 without a SOAP body, 12 `SOAP_FAULT` / 1 / 2 for a SOAP fault (the service's declared fault details are
`AccountNotFound`, `InfrastructureServiceError`, `TokenInvalid`, …, parsed by `soap_in_SOAP_ENV__Detail` FUN_0047c000),
3 / 5 / −1 for a malformed or truncated answer *(gSOAP 2.8 error numbering, inferred except 28)*.

### 5.5 When the shop host does not answer

There are no timeouts (§5.2): `tcp_connect` uses a blocking `connect`, and `frecv` FUN_0048c1e0 / `fsend`
FUN_0048bf40 wait in `select` only when `recv_timeout` / `send_timeout` ≠ 0, which is never the case. So, per request:

| Shop host state | What the worker does | Reply to the WM / client |
|---|---|---|
| name does not resolve | blocks for the DNS lookup, then error 28 | 0x3043 "Please try later." |
| refuses (RST) | fails at once, error 28 | 0x3043 |
| drops packets (no route / firewall) | blocks in `connect` for the OS connect timeout *(inferred: about 21 s on Windows)*, then error 28 | 0x3043 after the wait |
| accepts but never answers (hung web app) | blocks in `recv` **forever**; the proxy and the worker never come back | none; the client never gets a window or a message |
| answers slowly | blocks until the answer | normal reply, late |

Each blocked request holds one proxy and one session worker. The pool has 5 × CPU proxies, the worker pool
min(10 × CPU + 1, 81) workers (§4.4), so a hung host takes up to half the workers on up to 8 CPUs (4 CPUs: 20 of 41),
45 of 81 on 9 CPUs, 80 of 81 on 16; after that every 0x0870 is answered 0x3042 at once, and the remaining workers carry
every other Character job (logins, saves, items) of the world. From 17 CPUs on the pool (85 …) is larger than the
worker count: all 81 workers can block, the Character server stops serving every job, and 0x3042 is never sent. The lost workers stay lost until a restart, and a stop
(`CSessionWorkerManager::Stop` waits for each worker to reach STOPPED, §1.5) never completes while one of them is
blocked in `recv` (original bug) D08-B6. The WM's 5-s per-session limit (0x3041) keeps one player from filling the
pool alone, not several players.

### 5.6 The proxy class and the unused operations

`SingleSignOnServiceSoapBindingProxy` vtable (RTTI; slot order of soapcpp2's proxy class, MSVC puts each overload pair
in reverse order):

| Slot | Function | |
|---|---|---|
| 0 | FUN_0047d4f0 `scalar deleting destructor` (→ `soap::~soap` FUN_0048cdf0: frees the class list, `soap_end`, `soap_done` FUN_0048c3d0) | |
| 1–3 | FUN_0047cd40 `SingleSignOnServiceSoapBindingProxy_init` (modes, namespaces), FUN_0047cd70 `destroy` (`soap_delete` FUN_0047ef30 + `soap_end` FUN_004831d0), FUN_0047cd90 `reset` | never called by the Character code |
| 4–13 | FUN_0047cdc0 `soap_noheader`, FUN_0047cdd0 `soap_header`, FUN_0047cde0 `soap_fault`, FUN_0047cdf0 `soap_fault_string`, FUN_0047ce00 `soap_fault_detail`, FUN_0047ce10 `soap_close_socket`, FUN_0047ce20 `soap_force_close_socket`, FUN_0047ce30 `soap_print_fault`, FUN_0047ce50 `soap_stream_fault`, FUN_0047ce70 `soap_sprint_fault` | only slot 13 is used (§5.3) |
| 14 / 15 | FUN_0047ce90 / FUN_0047cce0 `getAccountForToken` (action "getAccountForToken", request `ns1:getAccountForToken` with `ssoToken`, `clientIp`; answer `ns1:getAccountForTokenResponse`) | dead: no caller |
| 16 / 17 | FUN_0047d0b0 / FUN_0047cd00 `getItemShopUrl` | §5.4 |
| 18 / 19 | FUN_0047d2d0 / FUN_0047cd20 `getCashShopUrl` (action "getCashShopUrl", request `ns1:getCashShopUrlRequest` with `accountId`; answer type `ns1:getShopUrlResponse`) | dead: no caller |

The generated schema also carries a shopping-cart / item model (`ns1__shoppingCartItem` with `itemId`, `name`, `quantity`,
`total`; `ns1__itemInformationType` with `itemId`, `description`, `visible`, `purchasable`; `ns1__property` /
`ns1__propertyList` key–value pairs; `_ns1__IllegalAmount`, `_ns1__InsufficentCash { accountId, requestedAmount,
currentBalance }`, `_ns1__VoucherCodeInvalid`, …): types of the same WSDL that no operation of this proxy sends or
expects except as fault details. The server never buys, books cash or checks tokens through this service; it only fetches
the shop URL. The account identifier sent is the game's `nUserNo`, so the web service maps user numbers to its own
accounts *(inferred)*.

### 5.7 Address table (Character, gSOAP)

None of these functions has project logic except §5.2–§5.4; the rest is generated (soapcpp2) or library (stdsoap2) code.

| Group | Functions | Where described |
|---|---|---|
| `cUKItemShop`, its `std::vector<Proxy*>` / `std::string` helpers, the two `ns1` objects on the stack | 0043f310 0043f380 0043f3b0 0043f420 0043f450 0043f4b0 0043f5b0 0043f5c0 0043f5f0 0043f660 0043f690 0043f7f0 | §5.1–§5.3 |
| proxy class (vtable, ctor FUN_0047d520) | 0047cce0 0047cd00 0047cd20 0047cd40 0047cd70 0047cd90 0047cdc0 0047cdd0 0047cde0 0047cdf0 0047ce00 0047ce10 0047ce20 0047ce30 0047ce50 0047ce70 0047ce90 0047d0b0 0047d2d0 0047d4f0 0047d520 | §5.6 |
| `ns1` class virtuals (RTTI vtables of the 22 classes: `soap_type`, `soap_default`, `soap_serialize`, `soap_put`, `soap_out`, `soap_get`, `soap_in`, `scalar deleting destructor`); shared bodies (identical code folded): FUN_0046f1f0 `soap_serialize` of 21 classes (empty), FUN_00471840 `soap_default` of the 12 one-string classes, FUN_00472370 of the 4 two-string classes; the `soap_type` of 10 classes are folded into constant-return functions elsewhere (FUN_0043f370 is also the `fget` callback: returns 15) | 0046ed70 0046f170 0046f190 0046f200 0046f210 0046f850 0046f8e0 00470c80 00470ce0 00470d20 00470d60 00470da0 00470de0 00470e70 00470f60 00470fa0 00471010 00471660 004716d0 00471750 004717c0 00471860 004718d0 00471950 004719c0 00471a40 00471ab0 00471b30 00471b60 00471b80 00471c00 00471c20 00471cc0 00471ce0 00471d80 00471df0 00471e70 00471ee0 00471f60 00471fd0 00472050 00472070 004720f0 00472160 004721e0 00472250 004722d0 004722f0 004723a0 004723c0 00472460 00472480 00472520 00472560 00472580 00472620 00472660 00472680 004729d0 004730a0 00473100 00473160 004731c0 00473220 00473280 004732e0 00473340 004733a0 00473400 00473460 004734c0 00473520 00473580 004735e0 00473640 004736a0 00473700 00473760 00473780 004737e0 00473860 004738c0 00473920 004755d0 00476a00 00479300 0047a7f0 0047ad30 0047bda0 0047bdc0 0047bde0 0047be00 0047be20 0047be40 0047be60 0047be80 0047bea0 0047bec0 0047bee0 0047bf00 0047bf20 0047bf40 0047bf60 0047bf80 0047bfa0 0047bfc0 0047bfe0 0047c760 0047c7a0 0047c7e0 0047c820 0047c860 0047c8a0 0047c8e0 0047c920 0047c960 0047c9a0 0047c9e0 0047ca20 0047ca60 0047caa0 0047cae0 0047cb20 0047cb60 0047cba0 0047cbe0 0047cc20 0047cc60 0047cca0 | names in `names/character/D08.json` |
| generated free functions with a role in the call (§5.3–§5.4) | `soap_ignore_element` 0046ed80, `soap_putheader` 0046f760, `soap_serialize___ns1__getCashShopUrl` 0046fbf0, `soap_put___ns1__getCashShopUrl` 0046fc20, `soap_serialize___ns1__getItemShopUrl` 0046fc80, `soap_put___ns1__getItemShopUrl` 0046fcb0, `soap_serialize___ns1__getAccountForToken` 0046fd10, `soap_put___ns1__getAccountForToken` 0046fd40, `soap_out_ns1__getShopUrlResponse` 00470720, `soap_putelement` 00471020, `soap_fdelete` 00473980, `soap_in_std__string` 00478400, `soap_in_ns1__getShopUrlResponse` 00479db0, `soap_getelement` 0047ad50, `soap_in_SOAP_ENV__Detail` 0047c000, `soap_getindependent` 0047c380, `soap_in_SOAP_ENV__Fault` 0047c3e0, `soap_get_SOAP_ENV__Fault` 0047c700 | §5.4 |
| remaining generated serialisers (`soap_default_*` / `soap_serialize_*` / `soap_out_*` / `soap_in_*` / `soap_instantiate_*` / pointer and `std::string` typedef helpers of the types above, SOAP-ENV header / fault / code / detail, xsd built-ins) | 0046ed40 0046eea0 0046eed0 0046ef00 0046ef50 0046ef80 0046eff0 0046f070 0046f270 0046f350 0046f3a0 0046f3f0 0046f440 0046f490 0046f4e0 0046f530 0046f580 0046f5d0 0046f620 0046f670 0046f6c0 0046f6f0 0046f750 0046f7e0 0046f830 0046f8c0 0046f930 0046f950 0046fa70 0046fda0 0046fe60 0046ff20 0046ffb0 00470040 004700d0 00470160 004701f0 00470280 00470310 004703a0 00470430 004704c0 00470550 00470600 00470690 004707a0 00470820 004708b0 00470940 00470a30 00470b10 00470b60 00470b90 00470be0 00470c30 00470c90 00470cf0 00470d30 00470d70 00470db0 00470df0 00470e20 00470e80 00470ed0 00470f00 00470f30 00470f70 00470fb0 00470fe0 00472720 00472760 004727d0 00472800 00472880 00472910 004729a0 004729e0 00472a60 00472ae0 00472b40 00472ba0 00472c00 00472c60 00472cc0 00472d40 00472dc0 00472e30 00472e90 00472ef0 00472f50 00472fb0 00473010 00473b90 00473cc0 00473e30 00473fa0 00474110 00474280 004743f0 00474530 00474680 004747d0 00474920 00474a90 00474c00 00474d70 00474ee0 00475050 004751c0 00475330 00475480 00475640 00475790 004758e0 00475a20 00475ac0 00475b60 00475c00 00475c80 00475d20 00475dc0 00475e60 00475f00 00475fe0 004760c0 004761a0 00476280 00476360 00476440 00476560 00476690 004767b0 004767e0 00476870 004768b0 004768e0 004769c0 00476a40 00476dc0 00476e10 00476e30 00476f70 00476fa0 00477450 004775e0 00477770 00477910 00477aa0 00477c30 00477dc0 00477f50 004780e0 00478270 00478590 00478750 00478790 004787c0 00478800 00478960 004789b0 00478a00 00478b30 00478cc0 00478e50 00478fe0 00479170 00479320 00479540 00479720 00479900 00479a90 00479c20 00479f60 0047a0f0 0047a280 0047a430 0047a610 0047a810 0047aac0 0047c2c0 | not individually named: generated from the WSDL, no project logic |
| stdsoap2 runtime, identified (call path, callback table of `soap_init2`, strings) | `tcp_gethost` 0047e420, `tcp_accept` 0047e620, `tcp_disconnect` 0047e640, `tcp_closesocket` 0047e690, `tcp_shutdownsocket` 0047e6a0, `soap_closesock` 0047e6c0, `soap_force_closesock` 0047e750, `soap_end_count` 0047eac0, `soap_malloc` 0047ee90, `soap_delete` 0047ef30, `soap_link` 0047efd0, `soap_recv_header` 00480710, `soap_puthttphdr` 00480b90, `fplugin` 00481170, `tcp_connect` 00481d90, `soap_poll` 00482510, `http_post` 004825e0, `http_response` 004829b0, `soap_dealloc` 00482d20, `soap_free_temp` 00482f60, `soap_begin` 00483100, `soap_end` 004831d0, `soap_set_namespaces` 00483230, `soap_print_fault` 00484410, `soap_sprint_fault` 00484500, `http_parse` 00484d00, `soap_begin_count` 00485400, `soap_end_recv` 00485700, `soap_element_end_in` 004858b0, `soap_string_in` 00486ab0, `soap_begin_recv` 00487d50, `soap_envelope_end_in` 00488460, `soap_body_end_in` 00488490, `soap_recv_fault` 004884d0, `http_parse_header` 00488980, `http_post_header` 00489000, `soap_element_end_out` 00489120, `soap_element_begin_in` 00489210, `soap_envelope_end_out` 0048a1f0, `soap_envelope_begin_in` 0048a340, `soap_body_end_out` 0048a4c0, `soap_body_begin_in` 0048a500, `soap_end_send` 0048a550, `http_405` 0048aea0, `soap_element_begin_out` 0048b3f0, `soap_envelope_begin_out` 0048b6a0, `soap_body_begin_out` 0048b7f0, `soap_connect_command` 0048b870, `fsend` 0048bf40, `frecv` 0048c1e0, `soap_done` 0048c3d0, `soap_init2` 0048c5d0, `soap_connect` 0048cc30, `soap_stream_fault` 0048cc50, `soap::soap` 0048cdd0, `soap::~soap` 0048cdf0, `soap::`scalar_deleting_destructor'` 0048ce60 | §5.2–§5.5 |
| stdsoap2 runtime, rest (XML scanner / writer, entity and base64 coding, MIME / DIME attachments, hash tables, UDP, HTTP server side, `soap_poll`, plugin, …) | 0047d560 0047d5c0 0047d940 0047dbe0 0047dc40 0047dca0 0047dcd0 0047dd50 0047dd90 0047deb0 0047df30 0047df70 0047df90 0047e010 0047e090 0047e0d0 0047e1d0 0047e2b0 0047e480 0047e780 0047e890 0047e8d0 0047e910 0047e960 0047ea20 0047eaf0 0047eb80 0047ec70 0047ece0 0047ed20 0047ed40 0047eda0 0047ee30 0047f010 0047f040 0047f1f0 0047f340 0047f360 0047f420 0047f4a0 0047f4f0 0047f660 0047f710 0047fba0 0047fc10 0047fce0 0047fd10 0047fd80 0047fdf0 0047fe50 0047ffa0 00480130 00480200 00480400 004804f0 00480660 00480760 004808a0 004809e0 00480f60 00480fc0 004810b0 00481110 004811d0 00481300 00481410 00481650 004817b0 00481800 00481a60 00481b60 00481d20 00482c60 00482e20 00483340 00483630 00483aa0 00483b50 00483c20 00483d80 00484600 00484670 00484ad0 00485380 00485540 00485a10 00485b20 004875a0 00487660 004878e0 00488670 004887a0 004887d0 00488860 00488e30 00489060 00489320 00489630 00489760 00489860 004899c0 00489ab0 00489c80 00489f30 0048a040 0048a760 0048a9e0 0048aad0 0048abd0 0048af10 0048b430 0048b4e0 0048b570 0048b600 0048bc80 0048bd3d 0048bd71 0048bdf0 0048beef 0048ca10 0048caa0 0048cb70 | library, not individually named |

`thunk_FUN_0044fad0` FUN_0046ed30 (the last function before the generated block) belongs to the ODBC wrapper (§2.5);
the CRT starts at FUN_0048ce81 (`operator new[]`).

## Original-server bugs

| ID | Handler / function | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D08-B1 | `CSessionWorkerManager::AddQue` FUN_004066a0 / `CSession::PacketStroe` FUN_00405630 (all four builds) | returns the space left (0 when the record fills the 2 MB queue exactly), which the caller reads as "full" and appends the frame again | that packet is handled twice (double DB call, double reply) when the backlog reaches exactly 2 MB | return a success flag separate from the space left |
| D08-B2 | 0x2803 `CPFs::fc_NC_OPTOOL_CLOSE_SERVER_REQ` + `DataServer::MainThread` (all four builds) | sets `m_bStopMainThread`; the main thread stops listener, workers, links and IOCP, then returns without reporting to the service manager | the DB server is dead but the service is RUNNING until stopped by hand; Login / WM cannot reconnect | end the service (report STOPPED / exit) after a remote stop |
| D08-B3 | job queue (`GetJobA` FUN_00406780) (all four builds) | a queued record keeps a raw pooled `CSession*` | after a close and an immediate reconnect the old link's request runs on the new link (reply to the wrong peer; a 0x0802 sets the new link's identity) *(inferred)* | tag records with a session generation / drop records of closed sessions |
| D08-B4 | `Database::InitEnv` FUN_00417330 (all four builds) | the connection-pooling `SQLSetEnvAttr` is accepted only as `SQL_SUCCESS`; on any other result the function fails without freeing or clearing the environment handle | a driver manager answering `SQL_SUCCESS_WITH_INFO` makes every worker's connect fail (server does not start) and leaks one environment handle per attempt *(inferred: the 2016 hosts answer `SQL_SUCCESS`, the servers start)* | accept 0 / 1 like the other calls; free the handle on failure |
| D08-B5 | Character `CSession_Manager::InactiveSession` FUN_0043de40 (§4.3) | clears `g_GameLogLink` when any session with `m_Connected_Server_ID == 3` closes, without comparing it with `g_GameLogLink` | an incoming link that announced server type 3 in its 0x0802 (accepted for any `server_id_from`) clears the pointer when it closes; the main thread opens a second GameLog link while the first stays open and unused (needs a misconfigured or hostile peer) | clear only when the closing session is `g_GameLogLink` |

| D08-B6 | Character `cUKItemShop::Recv_NC_MISC_ITEMSHOP_URL_DB_REQ` FUN_0043f7f0 / proxy pool `cUKItemShop::Init` FUN_0043f690 (§5.5) | the gSOAP contexts keep `soap_init2`'s timeouts 0: blocking connect, `recv` / `send` without limit, on a session worker | a shop host that accepts and never answers blocks one worker and one proxy per request for good (up to 5 × CPU workers; all 81 from 17 CPUs on, which stops the whole Character server); a stop never completes while a worker is blocked | set `connect_timeout` / `recv_timeout` / `send_timeout` (a few seconds) and run the call off the DB workers |
| D08-B7 | Character FUN_0043f7f0 (§5.3) | copies `nLen = (u16) url.size()` bytes of the shop's URL into the 8187-byte `CSendPacket` at payload +8 without a bound | a URL over 8179 bytes (0x1ff3) fails `CSendPacket::SetSize` (log, a 3-byte frame with opcode 0 is sent); over 8183 bytes the copy runs past the packet into the stack objects (request / response `std::string`, fault buffer, cookie): crash on return; ≥ 64 KiB is cut to `len mod 0x10000` | clamp `nLen` to the packet's payload room (and to what the client's shop window accepts) |
| D08-B8 | Character FUN_0043f7f0 (§5.3) | never calls `soap_destroy` / `soap_end` after a call; `soap_begin` FUN_00483100 frees only the temporary lists (`soap_free_temp` FUN_00482f60), not `alist` | every answer's `soap_malloc` blocks (the URL text from `soap_string_in`, fault strings) stay on the proxy until the process ends: the Character server's memory grows with every item-shop request *(effect inferred from the gSOAP 2.8 allocation path, size per call = the answer's strings)* | `soap_destroy(p); soap_end(p)` after each call |
Next free ID: D08-B9.

## Not reconstructed / uncertain

- §1.5: per-link ordering of requests is not guaranteed by the code; whether the peers ever send two dependent
  requests back to back on one link is not checked here (the handlers are D01–D05's).
- §4.1 / §4.4 (Character): the members after `+0x9838` and the worker's DB object (+0x124c, 0x5c bytes) have no PDB; the
  member names are ours and the DB object's bases are known only by the one RTTI name `CSQLPPrison`. FUN_00443f20 is
  named `CMD5Checksum::Final` from its structure (padding, length, 16 hex bytes), not from an identical body;
  FUN_0044a320 (the ItemInfo fopen probe) has no official name in any PDB.
- §4.3: the timing claims (log packets dropped before GameLog's 0x0803, the `g_GameLogLink` race) are deduced from the
  code paths, not observed; no capture covers the Character ↔ GameLog link.
- §5: the shop traffic is in no capture: the HTTP request text is read from `http_post` / `soap_puthttphdr` and the
  serialisers, the answer format from the response parser; what the gamigo service returned (URL length, faults) and
  whether the host still existed in 2016 is unknown. The gSOAP function names (§5.7) are matched to the public 2.8
  sources by structure, call order and strings, not by a symbol file; the ~300 generated / runtime functions listed
  without a name are library code that was not read one by one.

## Coverage boundary

(Completed in the sweep part.)
