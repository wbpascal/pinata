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
  +0x050c   char[16]    m_ConnectSocket_BindIP   zeroed by the ctor, never read in Account (inferred: used by servers that connect out)
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
AccountLog / Character / GameLog variant; parts 3, 4 and 7 of D08 read those). Several addresses = identical-code
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

## Original-server bugs

| ID | Handler / function | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| D08-B1 | `CSessionWorkerManager::AddQue` FUN_004066a0 / `CSession::PacketStroe` FUN_00405630 (all four builds) | returns the space left (0 when the record fills the 2 MB queue exactly), which the caller reads as "full" and appends the frame again | that packet is handled twice (double DB call, double reply) when the backlog reaches exactly 2 MB | return a success flag separate from the space left |
| D08-B2 | 0x2803 `CPFs::fc_NC_OPTOOL_CLOSE_SERVER_REQ` + `DataServer::MainThread` (all four builds) | sets `m_bStopMainThread`; the main thread stops listener, workers, links and IOCP, then returns without reporting to the service manager | the DB server is dead but the service is RUNNING until stopped by hand; Login / WM cannot reconnect | end the service (report STOPPED / exit) after a remote stop |
| D08-B3 | job queue (`GetJobA` FUN_00406780) (all four builds) | a queued record keeps a raw pooled `CSession*` | after a close and an immediate reconnect the old link's request runs on the new link (reply to the wrong peer; a 0x0802 sets the new link's identity) *(inferred)* | tag records with a session generation / drop records of closed sessions |

Next free ID: D08-B4.

## Not reconstructed / uncertain

- §1.5: per-link ordering of requests is not guaranteed by the code; whether the peers ever send two dependent
  requests back to back on one link is not checked here (the handlers are D01–D05's).

## Coverage boundary

(Completed in the sweep part.)
