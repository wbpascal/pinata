# Login server: process layer and session pools (L01)

Source: `Files/Server/2016/Login/3LoginServer2.exe`, read in the PDB re-analysis `re-data/exports/login-pdb`
(`python3 -I tools/protocol-re/clean.py re-data/exports/login-pdb - <addr> …`). Class, member and enum names are the
official ones from the NA2016 `Login.pdb` of the same build *(pdb2016)*; offsets are the PDB's first `LoginServer`
definition (size 0xfe40), which is the one the code uses. Everything else is read in the code unless marked
*(inferred)*.

This item covers the process layer around the handlers of `login-server.md` (L00): the main thread and its work
steps, the packet pump, the session pools and the session managers, the world-status table and its load thresholds
(`m_LoginUserRatable`), the shared server-link parser and the per-parser copies of the 0x0801 / 0x0804 handlers,
the entry point and Windows-service shell (§1.8), the one-time-token list (§4.3), the connection check and the small
handler bodies L00 only names (§4.4), and a pointer table of the library copies linked into Login (§4.6).
Already documented elsewhere and only cited here: process start-up and the version keys (`login-server.md` §2),
the client dispatcher (L00 §3.2), the network library and the session glue (S02 §1, §1.6), the constructor,
`OnStart_Service`, `Start_Acceptor`, `ProcessStop`, `DissconnectAllSessions`, `ProcHeartBeat` and the base-session
constructor (S02 §4.3). The WM twin of everything here is W05 §1 / §4.

Corrections to the done item L00 found on the way are collected in [`../../knowledge/L01.md`](../../knowledge/L01.md).

---

## 1. Process object and main thread

### 1.1 `LoginServer` (`gServer`, one global object)

| Offset | Member *(pdb2016)* | Notes |
|---|---|---|
| +0x0000 | `m_ServerInfo` (`CServerInfo`) | `LoginServerInfo.txt` + `ServerInfo.txt` rows (S02 §2.5, §4.3) |
| +0x04f8 | `m_MyServer` | `MY_SERVER` row: name, `nServerID` (4), `nWorldNo`, `nZoneNo` |
| +0x050c … +0x059c | `m_AccountDBInfo`, `m_AccountLogDBInfo`, `m_WorldManagerInfo`, `m_ClientInfo`, `m_OPToolInfo` | `SERVER_INFO` rows (0x24 bytes each): `pIP`, `nPort`, `nServerIDFrom`, `nBackLog`, `nMaxAccept` |
| +0x05c0 | `m_ConnectSocket_BindIP[16]` | local bind address of the two outgoing DB links |
| +0x05d0 | `m_strHashValue[128]` | written by `ReadGlobalGameData` (L00 §2 `LoadVersionKeys`) |
| +0x0650 | `m_LoginUserRatable[256]` | `LOGIN_USER_RATABLE`, 12 bytes each (§3) |
| +0x1250 | `m_Acceptor` | `CSocket_Acceptor` (S02 §1.4) |
| +0xa4dc | `m_IOCP` | `CIOCP` (S02 §1.3) |
| +0xa50c / +0xa614 | `m_AccountDB` / `m_AccountDBParser` | outgoing link (`CLoginAccountDBSession`, 0x108) + `CParserAccountDB` |
| +0xb71c / +0xb824 | `m_AccountLogDB` / `m_AccountLogDBParser` | outgoing link + `CParserAccountLogDB` |
| +0xc92c / +0xc94c | `m_Client` / `m_ClientParser` | `CLoginClientSessionManager` (§2.3) + `CParserClient` |
| +0xda54 / +0xda7c | `m_WorldManager` / `m_WorldManagerParser` | `CLoginWorldManagerSessionManager` (§2.5) + `CParserWorldManager` |
| +0xeb84 / +0xeba0 | `m_OPTool` / `m_OPToolParser` | `CLoginOPToolSessionManager` (§2.4) + `CParserOPTool` |
| +0xfca8 | `m_isPermitServer` | 1 after `OnStart_Service` (S02 §4.3); read by the login handlers (L00 §4 / §5.1) |
| +0xfcac | `m_bOnStopService` | only ever 0 (§1.2, L01-B3) |
| +0xfcb0 / +0xfcc0 | `m_ServerStartTime` / `m_ServerStopTime` | `SYSTEMTIME`, set by `ViewStartInfo` / `ViewStopInfo` |
| +0xfcd0 / +0xfcd4 | `m_bStopMainThread` / `m_bActiveMainThread` | main-thread hand-shake |
| +0xfcd8 / +0xfcdc | `m_hMainThread` / `m_MainThreadID` | `CreateThread` result |
| +0xfce0 | `m_MainWorkStep` | `MAIN_WORK_STEP`: 0 NONE, 1 LINK, 2 RUN, 3 CLOSE_ACCOUNT_DB, 4 CLOSE_ACCOUNTLOG_DB |
| +0xfce4 | `m_bProcessLinked` | 1 once both DB links were up and the WM / client listeners opened |
| +0xfce8 | `m_OTPLogin` | `COTPLogin`, the one-time-token list (§4.3, L00 §5.3) |
| +0xfcfc / +0xfe3c | `m_sVersionKey[5][64]` / `m_nVersionListNum` | L00 §2 |

### 1.2 Main thread and work steps

```pseudo
LoginServer::Start_MainThread(this):                                    @ FUN_00403200  (S02 §4.3)
    m_bStopMainThread = 0; m_bActiveMainThread = 0
    m_hMainThread = CreateThread(MainThread, this, &m_MainThreadID)
    fail → log GetLastErrorStr; return 0
    while m_bActiveMainThread != 1: Sleep(5)                            # wait until the thread runs
    return 1

LoginServer::MainThread(this):                                          @ FUN_004030e0
    log "<START MAIN THREAD, LINKING SERVER>"
    m_bActiveMainThread = 1
    srand(time(0))
    while m_bStopMainThread == 0:
        Sleep(5)                                                        # every pass, in every step
        switch m_MainWorkStep:
            LINK (1): ProcessLink(this)                                 # §1.3, then falls through to RUN
            RUN  (2): ProcessDisconnect(this)                           # §1.6
                      ProcessConnect(this)                              # §1.4
                      ProcessPacket(this)                               # §1.5
            CLOSE_ACCOUNT_DB (3), CLOSE_ACCOUNTLOG_DB (4):
                      gServer.m_bStopMainThread = 1
            NONE (0): nothing (the thread starts before OnStart_Service sets LINK, S02 §4.3)
    log "<EXIT MAIN LOOP>"
    ProcessStop(this)                                                   # S02 §4.3
    m_bActiveMainThread = 0
    log "<STOP MAIN THREAD>"
    if m_bOnStopService == 0:
        log "<SERVER SELF STOPPED>"; exit(0)
    return 0
```

The loop has a fixed 5 ms sleep per pass, so at most ~200 passes per second; one pass handles all buffered frames
of every session (§1.5), unlike the WM's one frame per session per pass (W05 §1.4).

Who ends the loop (`m_bStopMainThread = 1`):

| Writer | When |
|---|---|
| `ProcessLink` FUN_00401bb0 | `Listen_OPTool` failed, or `Listen_WorldManager` / `Listen_Client` failed once both DB links were up (§1.3) |
| `MainThread` itself | `m_MainWorkStep` 3, set by `ProcessDisconnect` when the AccountDB link closes after the server was linked (§1.6) |
| `CParserOPTool::fc_NC_OPTOOL_CLOSE_SERVER_REQ` FUN_00407980 | OPTool 0x2803 remote stop (L00 §5.4) |
| `LoginServer::OnStop_Service` FUN_00402b70 | service manager STOP, below |

`MAIN_WORK_CLOSE_ACCOUNTLOG_DB` (4) is never stored: a lost AccountLogDB link is reconnected instead (§1.6).

```pseudo
::OnStop_Service():   (service-shell callback, registered by LoginServer::Start FUN_00402f30)   @ FUN_004033c0
    LoginServer::OnStop_Service(&gServer)

LoginServer::OnStop_Service(this):                                      @ FUN_00402b70
    m_bStopMainThread = 1
    while m_bActiveMainThread != 0: Sleep(5)
```

Nothing in Login ever sets `m_bOnStopService` (only the constructor writes 0). The WM's `::OnStop_Service` sets it
before it calls the member function (W05 §1.6); Login's does not. So every stop, including a service-manager STOP,
ends with `exit(0)` on the main thread right after `m_bActiveMainThread = 0`, racing the service STOP callback that is
still returning from its wait **(original bug) L01-B3**. The race, with the service shell of §1.8: the SCM thread is in
`WinService::onServiceStop` FUN_00411560, which has reported `STOP_PENDING` and waits in `::OnStop_Service` for
`m_bActiveMainThread == 0`; the main thread clears that flag and at once calls `exit(0)`, which runs the static
destructor `~LoginServer` (§1.7, through `_dynamic_atexit_destructor_for_'gServer'` FUN_00427710) and ends the process.
If `exit` wins, `SetServiceStatus(STOPPED)` is never sent and the service manager sees a service that ended while
`STOP_PENDING` *(inferred: Windows then logs an unexpected termination and applies the service's recovery actions)*.

```pseudo
LoginServer::ViewStartInfo(this):   (LoginServer::Start, before ReadDefineScriptor, §1.8)   @ FUN_00401120
    m_ServerStartTime = GetLocalTime()
    log "Local  Time      " + "<date> <time>"          # GetDateFormatA / GetTimeFormatA, user locale
    log "System Time(UTC) " + "<date> <time>"          # GetSystemTime
LoginServer::ViewStopInfo(this):    (last step of ProcessStop)                    @ FUN_00401250
    the same with m_ServerStopTime
```

Both are instruction-identical to the WM's `ViewStopInfo` FUN_00403d40 (W05 §1.6) apart from the member offset.

### 1.3 ProcessLink (step LINK)

L00 §2 describes this as the "bootstrap tick"; its listen order is wrong there (knowledge file). The code:

```pseudo
LoginServer::ProcessLink(this):                                         @ FUN_00401bb0
    if !Listen_OPTool(this): gServer.m_bStopMainThread = 1; return       # first of all, every pass
    if m_AccountDB.m_Status == EMPTY:
        if CLoginBaseSession::Connect(&m_AccountDB, m_ConnectSocket_BindIP, 0, AccountDB ip, port, &m_IOCP) == 1:
            m_AccountDB.m_Status = CONNECTING (2); log "<CONNECTING ACCOUNT DB\t\tTO %s:%d>"
        else: log "<RECONNECT  ACCOUNT DB\t\tTO %s:%d>" once (bMsgOnce, re-armed by the next success)
    ConnectAccountLogServer(this)                                       # FUN_00401ac0, L00 §2 (same shape)
    if m_AccountDB.m_Status != CONNECTED or m_AccountLogDB.m_Status != CONNECTED: return
        # CONNECTED (1) is set by each link's 0x0803 S2SCONNECTION_ACK handler (L00 §5.1 / §5.2, §4.2)
    if Listen_WorldManager(this) and Listen_Client(this):
        m_bProcessLinked = 1; m_MainWorkStep = RUN
        log "<SUCCESSED RUNNING SERVER---…>"
    else:
        gServer.m_bStopMainThread = 1

LoginServer::Listen_OPTool(this):                                       @ FUN_00401790
    if done (static flag): return 1                                     # the flag holds Listen_Add's result
    CLoginOPToolSessionManager::InitSessions(&m_OPTool, m_OPToolInfo.nMaxAccept)        # §2.4
    done = CSocket_Acceptor::Listen_Add(&m_Acceptor, ip, port, nServerIDFrom (8), nBackLog)
    log "<SUCCESSED LISTEN ADD, IP=%s:%d, From=%s>" / "*FAILED LISTEN ADD, IP=%s:%d, From=%s*"
    return done
LoginServer::Listen_WorldManager(this):                                 @ FUN_004018b0
    CLoginWorldManagerSessionManager::InitSessions(&m_WorldManager, m_WorldManagerInfo.nMaxAccept)   # §2.5
    InitWorldManagerInfo(&m_WorldManager) == 0 → return 0               # no WORLD_NAME row (§2.5)
    Listen_Add(…, From = 5) with the same two logs; return its result
LoginServer::Listen_Client(this):                                       @ FUN_004019c0
    CLoginClientSessionManager::InitSessions(&m_Client, m_ClientInfo.nMaxAccept)           # §2.3
    Listen_Add(…, From = 20) with the same two logs; return its result
```

So the OPTool port opens at the first pass, before any DB link; the WM and client ports (and their pools) open
only once both DB links are validated. In the shipped `ServerInfo.txt` the pools are client 200 (port 9010), WM 50
(9011), OPTool 30 (9015, bound to 127.0.0.1). Until RUN the WM and client pools are empty, so the loops of
§1.4 – §1.6 over them do nothing.

### 1.4 ProcessConnect (accept)

```pseudo
LoginServer::ProcessConnect(this):     (LINK and RUN)                  @ FUN_004022a0
    ConnectAccountLogServer(this)                                       # reconnect a lost AccountLogDB link (§1.6)
    accepted = 0
    while CSocket_Acceptor::GetAccepted(&m_Acceptor, &info, 1):        # S02 §1.4 (one accepted socket)
        switch info.UserData (listen type):
          5 (WM):     node = m_WorldManager.vftable[0](socket, addr)    # CLoginWorldManagerSessionManager::ActiveSession
                      null → shutdown(socket, SD_BOTH); closesocket
                      else s = node.pSession; Socket_Register_To_IOCP(s, &m_IOCP) (S02 §1.6) and
                           Send_NC_MISC_S2SCONNECTION_RDY(s) (0x0801, §2.2), either failing → s.m_Status = 3
          8 (OPTool): the same with m_OPTool (vftable[0] = base ActiveSession) and the OPTool 0x0801
          20 (client): accepted++
                      node = m_Client.vftable[0](socket, addr)          # CLoginClientSessionManager::ActiveSession §2.3
                      null → shutdown + closesocket
                      s.m_Connected_Server_ID = 20; s.m_Status = CONNECTED (1)
                      Socket_Register_To_IOCP and Send_NC_MISC_SEED_ACK (0x0807, §2.2); either failing → s.m_Status = 3
                      else log "Connected from (%-25s world=%3d …)"
        if accepted > 1: return                                          # at most 2 client accepts per pass
```

WM and OPTool sessions stay in `CONNECTING` (2), set by the base `ActiveSession`, until their 0x0802 handler sets
`CONNECTED` (L00 §5.3 / §5.4). A client is `CONNECTED` at once: it has no S2S hand-shake; its login progress is the
`m_SessionMode` of §2.3 (L00 §3.2 `loginStep`). The client accept limit counts failed allocations too; WM and OPTool
accepts are not limited.

### 1.5 ProcessPacket (packet pump)

```pseudo
LoginServer::ProcessPacket(this):      (LINK and RUN)                  @ FUN_004024e0
    if m_AccountDB.m_Status in {1, 2}:    Pump(m_AccountDB, m_AccountDBParser)
    if m_AccountLogDB.m_Status in {1, 2}: Pump(m_AccountLogDB, m_AccountLogDBParser)
    for node in m_OPTool active list:       if s.m_Status in {1, 2}: Pump(s, m_OPToolParser)
    for node in m_WorldManager active list: if s.m_Status in {1, 2}: Pump(s, m_WorldManagerParser)
    for node in m_Client active list:       if s.m_Status in {1, 2}: Pump(s, m_ClientParser)

Pump(s, parser):   (inlined five times)
    loop:
        r = s.m_Packet.IsValidPacket()                       # vtbl 0x0c, S02 §1.7
        r == 0: if s.m_Packet.RemoveAllUsedPacket(): CLoginBaseSession::Receive(s)   # compact + re-arm; stop
        r == 1: ok = parser.Parser(s)                         # §4.1; client: CParserClient::Parser FUN_00406680 (L00 §3.2)
                if ok == 0: stop                              # the parser has set m_Status = 3
                s.m_Packet.TakeNextPacket()                   # vtbl 0x24
                continue                                       # next buffered frame of the same session
        r == 2: s.m_Status = 3; stop                          # bad frame (S02 §1.7): no log in Login
```

Differences from the WM pump (W05 §1.4): every buffered frame of a session is handled in one pass (there is no
`bWorkAllAndNextSession` switch), the bad-frame close writes no "FATAL ERROR" log, and client sessions are pumped in
state 1 or 2 (the WM pumps clients only in state 1). The four server-link pumps call one shared parser body
(`CParserWorldManager::Parser` FUN_004087d0, §4.1): the linker folded the four identical template instances.

Order inside a pass: AccountDB, AccountLogDB, OPTool, WM, clients. A frame from AccountDB that addresses a client
(the password-check answers, L00 §5.1) is therefore handled before the client's own frames of the same pass.

### 1.6 ProcessDisconnect (heartbeats and closing)

```pseudo
LoginServer::ProcessDisconnect(this):  (LINK and RUN)                  @ FUN_00401d30
    # 1. heartbeats (CheckHeartBeat FUN_00408f30, L00 §2: 0x0804 after 30 s silence, give up after 180 s more)
    for link in m_AccountDB, m_AccountLogDB:
        if CLoginBaseSession::CheckHeartBeat(link) == 0: CSocket_IOCP::CloseUseIOCP(&link.m_SocketIOCP, &m_IOCP)
    ProcHeartBeat(m_OPTool); ProcHeartBeat(m_WorldManager); ProcHeartBeat(m_Client)          # S02 §4.3
        # CloseUseIOCP only posts a close completion; the IOCP thread sets m_Status = 3 (S02 §1.6) and a later
        # pass closes the session below
    # 2. closing (m_Status == CLOSEING)
    if m_AccountDB.m_Status == 3:
        CLoginBaseSession::Close(&m_AccountDB)                           # shutdown + closesocket (S02 §1.6)
        if m_bProcessLinked == 0: m_AccountDB.m_Status = EMPTY            # still LINK: ProcessLink reconnects
        else:
            log "Closed AC from (%-25s world=%3d zone=%3d, …) (DEP=%d,CMD=%d,LEN=%d,WORK=%d)"   # last packet
            m_MainWorkStep = CLOSE_ACCOUNT_DB; m_AccountDB.m_Status = CLOSED (4)
            log "***FATAL ERROR - ACCOUNT DB SERVER DISCONNECTED, SERVER DOWN PROCESS ACTIVATED***"
            # the next MainThread pass stops the loop (§1.2): ProcessStop, exit(0)
    if m_AccountLogDB.m_Status == 3:
        CLoginBaseSession::Close(&m_AccountLogDB)
        if m_bProcessLinked: log "Closed AL from (…)"; log "ACCOUNTLOG SERVER DISCONNECTED, ATTEMPT TO RECONNECT."
        m_AccountLogDB.m_Status = EMPTY                                   # ConnectAccountLogServer reconnects
    for node in m_OPTool active list (next taken first):        if s.m_Status == 3: Close(s); m_OPTool.vftable[1](node);
                                                                  log "Closed OP from (…)"
    for node in m_WorldManager active list:                     if s.m_Status == 3: Close(s); m_WorldManager.vftable[1](node);
                                                                  log "Closed WM from (…)"
    for node in m_Client active list:                           if s.m_Status == 3: Close(s); m_Client.vftable[1](node);
                                                                  log "Closed CL from (…)"
```

`vftable[1]` is the manager's `InactiveSession`: base FUN_004094d0 for OPTool, FUN_0040a2b0 for WM (§2.5),
FUN_00409b10 for clients (§2.3). Unlike the WM (W05 §4.5) Login has no per-session close callback: closing a client
sends nothing to AccountDB, AccountLogDB or a WM.

### 1.7 Destruction

`LoginServer::~LoginServer` FUN_00401010 (static destructor of `gServer`, runs from `exit`) destroys the members in
reverse order: `m_OTPLogin` (with the shared empty destructor FUN_0040a550, so the token list nodes are not freed,
§4.3), each parser's `PROTOCOLFUNCTIONTEMPLETE` (§4.1) and session manager (`~CLoginOPToolSessionManager`
FUN_00409c90, `~CLoginWorldManagerSessionManager` FUN_0040a3c0, `~CLoginClientSessionManager` FUN_00409970), the two DB
sessions (the folded body FUN_00408cf0, PDB name `~CLoginWorldManagerSession`: `~CPacket`, `~CSocket_IOCP`, §2.2),
then `CIOCP::Close`, `~CSocket_Acceptor` and `~CCsl` (the server info). `ProcessStop` FUN_00402820 (S02 §4.3) has
already closed every socket and freed the client, WM **and OPTool** pools (`DissconnectAllSessions` + `FreeSessions`
each), so the pool destructors only find null arrays there. `CIOCP::Close` (S02 §1.3 FUN_004646b0) thus runs twice,
once in `ProcessStop` and again here; the second call is harmless: `Stop` returns at once because `m_pWorkThreads` is
already null, and `m_HandleIOCP` is 0, so nothing is closed again.

### 1.8 Entry point and Windows-service shell

Login links the WM's service shell (W05 §1.1 `Start` / `ParseCmd`, §6.3 `WinService`, `MiniDumper`) once more. Every
function below was read in the Login binary and does what W05 describes for its WM twin; only addresses, the
`LoginServer` offsets and `Start`'s error codes differ.

```pseudo
_dynamic_initializer_for_'gServer'():   (CRT start-up, before WinMain)                 @ FUN_00427560
    LoginServer::LoginServer(&gServer)                          # S02 §4.3
    atexit(_dynamic_atexit_destructor_for_'gServer')            # FUN_00427710: ~LoginServer(&gServer), §1.7

WinMain(hInst, hPrev, cmdLine, show):                                                   @ FUN_00403340
    MiniDumper()                                    # SetUnhandledExceptionFilter(TopLevelFilter), below
    r = LoginServer::Start(&gServer, cmdLine)
    log "< END OF MAIN = %d >" r; return r

LoginServer::Start(this, cmdLine):                  (L00 §2 "main")                     @ FUN_00402f30
    chdir(directory of GetModuleFileName)           # 9Data / LoginServerInfo.txt paths are relative to the exe
    log "Launching the server....."; _ExecUpdateInfoMsg("-") (FUN_004103f0); two banner lines
    ViewStartInfo(this)                             # §1.2
    if !ReadDefineScriptor(this): return −1         # L00 §2 LoadServerInfo FUN_00401380
    if !ParseCmd(this, cmdLine):  return −2         # below
    if !ReadGlobalGameData(this): return −4         # L00 §2 LoadVersionKeys FUN_00401680
    Singleton<WinService>::getInstance()            # inlined copy of FUN_00402960
    WinService::startDispatcher(m_MyServer.pServiceName, ::OnStart_Service, ::OnStop_Service)
    return 0                                        # also when the dispatcher failed (not started by the SCM)

LoginServer::ParseCmd(this, cmdLine) → bool:                                            @ FUN_00402ba0
    up to 5 tokens of cmdLine (_mbstok); first token upper-cased
    no token: queryServiceStatus(pServiceName) succeeds → code 0 (run as the service)
              else token = "UPLOAD"                 # first run without arguments installs the service
    "UPLOAD" → code = uploadService(pServiceName, pDisplayName, exe path) ? 1 : 2
    "REMOVE" → code = removeService(pServiceName) ? 3 : 4
    other    → code = 5
    delete the WinService singleton (vtbl[1], scalar deleting dtor FUN_004116c0); selfInstance = null
    texts 0 "<SERVICE START>", 1 "<SERVICE UPLOAD ONLY OK>", 2 "<SERVICE UPLOAD FAILED>", 3 "<SERVICE REMOVE OK>",
          4 "<SERVICE REMOVE FAILED>", 5 "<SERVICE UNKNOWN COMMAND>"
    code 0 → log, return true; 1 … 5 → log + MessageBoxA(text, caption pDisplayName), return false (Start → −2)

::OnStart_Service():   (service-shell start callback)                                   @ FUN_004033b0
    return LoginServer::OnStart_Service(&gServer)   # S02 §4.3: acceptor, IOCP, main thread, step LINK
# ::OnStop_Service FUN_004033c0: §1.2
```

`queryServiceStatus` succeeds whenever the service is installed, running or not, so a second start of the exe from a
console takes code 0 and then fails in `StartServiceCtrlDispatcherA` (not started by the service manager): `Start`
returns 0 and the process ends without a message. Login runs only as a manual-start service.

| Function (Login) | Body | WM twin (W05 §6.3) |
|---|---|---|
| `Singleton<WinService>::getInstance` FUN_00402960 | first call: `new WinService` (0x44) + vtbl[0] | FUN_004069a0 |
| `WinService::WinService` FUN_004116a0 / scalar deleting dtor FUN_004116c0 | `serviceName = ""`, `handleServiceEvent = INVALID_HANDLE_VALUE` / `~String`, delete if flag & 1 | FUN_00466d60 |
| `WinService::startDispatcher` FUN_00411910 | `param = param` self-assignment, so the member `serviceName` stays `""` **(original bug) L01-B6**; `StartServiceCtrlDispatcherA({ name, serviceLoop })` | FUN_00466fd0 (W05-B23) |
| `WinService::serviceLoop` FUN_004117e0 | `onServiceStart`; then wait on the event until `statusEvent` is 1 (STOP) or 5 (SHUTDOWN); `onServiceStop` | FUN_00466ea0 |
| `WinService::onServiceStart` FUN_00411720 | `CreateEvent`; `RegisterServiceCtrlHandlerA("", serviceHandler)`; `START_PENDING` (accepts STOP + SHUTDOWN, wait 1000 ms); `::OnStart_Service()` false → return false (the loop is skipped, `onServiceStop` still runs); `RUNNING` | FUN_00466de0 |
| `WinService::serviceHandler` FUN_004116f0 | `statusEvent = control; SetEvent` | FUN_00466db0 |
| `WinService::onServiceStop` FUN_00411560 | `STOP_PENDING` (wait 5000 ms); `::OnStop_Service()` (§1.2, L01-B3); `STOPPED`; `CloseHandle` only when the event handle **is** `INVALID_HANDLE_VALUE` **(original bug) L01-B7** | FUN_00466c20 (W05-B24) |
| `WinService::uploadService` FUN_004113b0 | `CreateServiceA(name, display, access 0, OWN_PROCESS, DEMAND_START, ERROR_IGNORE, exe path)` → true when created | FUN_00466a70 |
| `WinService::removeService` FUN_004114b0 | `OpenSCManager` fails → false; else `DeleteService(OpenServiceA(name, DELETE))` and **true** whatever the result **(original bug) L01-B8** | FUN_00466b70 (W05-B22) |
| `WinService::queryServiceStatus` FUN_004115f0 | `QueryServiceStatus` → `dwCurrentState`, 1; any failure → `GetLastError()`, 0 | FUN_00466cb0 |
| `String::operator==` FUN_00411b90 | the `ParseCmd` token compare (library `String`, W05 §6.3) | – |
| `MiniDumper::MiniDumper` FUN_004120c0 | `SetUnhandledExceptionFilter(TopLevelFilter)` | FUN_004608b0 |
| `MiniDumper::TopLevelFilter` FUN_00411dd0 | `DBGHELP.DLL` from the exe directory else the system; `MinidumpCallStack` FUN_00411bb0 (`<exe>_<time>CallStack.txt`); `FuncForStack` (never set in Login: no writer); `MiniDumpWriteDump(…, type 0x40)` to `<exe>_<time>.mdmp`; logs "EXCEPTION - Saved dump file to '%s'" / "Failed to create / save dump file …"; returns 1 only when the dump was written | FUN_004605c0 |
| `_ExecUpdateInfoMsg(text)` FUN_004103f0 | overwrite `.\DebugMessage\ExecUpdateInfo.txt` with `text` | FUN_004602c0 (W05 §6.4) |

---

## 2. Session pools

### 2.1 `CLoginBaseSessionManager`: two lists over one node array

| Offset | Member *(pdb2016)* | Notes |
|---|---|---|
| +0x00 | vftable | [0] `ActiveSession`, [1] `InactiveSession` (RTTI vftables, table below) |
| +0x04 | `m_pSessionListArray` | `LOGIN_SESSION_LIST[m_MaxSessions]`: `pLinkUp`, `pLinkDown`, `pSession` (12 bytes) |
| +0x08 / +0x0c | `m_MaxSessions` / `m_NumSessions` | capacity / sessions in the active list |
| +0x10 / +0x14 | `m_pActiveSessions` / `m_pEmptySessions` | list heads (doubly linked through `pLinkUp` / `pLinkDown`) |

| Manager | vftable [0] / [1] | Session class, size | Extra members |
|---|---|---|---|
| `CLoginClientSessionManager` (`m_Client`) | FUN_00409700 / FUN_00409b10 | `CLoginClientSession`, 0x2d0 | +0x18 `m_pSessionArray`, +0x1c `m_ClientSeed` (u16) |
| `CLoginWorldManagerSessionManager` (`m_WorldManager`) | FUN_00409e60 / FUN_0040a2b0 | `CLoginWorldManagerSession`, 0x10c | +0x18 `m_pSessionArray`, +0x1c `m_ppWSMappingTable`, +0x20 `m_pWorldManagerInfo`, +0x24 `m_pWMClientValidationTable` |
| `CLoginOPToolSessionManager` (`m_OPTool`) | FUN_00409410 / FUN_004094d0 (the base ones) | `CLoginOPToolSession`, 0x10c | +0x18 `m_pSessionArray` |

The bodies are the WM's (W05 §4.1) with these differences: the base `ActiveSession` does not set
`m_Connected_Time` (the S2S handshake handlers do, for links), and the base and derived managers keep no
pending-login groups.

```pseudo
CLoginBaseSessionManager::CLoginBaseSessionManager(m):                  @ FUN_00409200
    vftable; m_pSessionListArray = null; m_MaxSessions = m_NumSessions = 0; both list heads = null
CLoginBaseSessionManager::FreeSessions(m):                              @ FUN_00409220
    if m_pSessionListArray: delete[] it; array = active = empty = null   # m_MaxSessions / m_NumSessions kept
CLoginBaseSessionManager::~CLoginBaseSessionManager(m):                 @ FUN_004092c0   = FreeSessions inlined

CLoginBaseSessionManager::InitSessions(m, n):                           @ FUN_004092f0
    FreeSessions (inlined)
    if n > 0:
        nodes = new LOGIN_SESSION_LIST[n]; node[i].pSession = null; chained 0 ↔ … ↔ n−1
        m_MaxSessions = n; m_NumSessions = 0; m_pEmptySessions = node[0]; m_pActiveSessions = null
    return 1

CLoginBaseSessionManager::EmptyToActive(m, node):                       @ FUN_004093a0
    node == null: log "* NULL Session List used - CSocket_Session_Manager::CutFromEmpty *"; m_NumSessions++; return
    unlink node from the empty list (head when pLinkUp == null)
    push node at the head of the active list; m_NumSessions++

CLoginBaseSessionManager::ActiveSession(m, socket, addr) → node:        @ FUN_00409410
    if m_NumSessions < m_MaxSessions and (node = m_pEmptySessions) != null:
        s = node.pSession
        s.m_Packet.Clear()                                      # vtbl 0x2c: buffer start, positions 0 (S02 §1.7)
        s.m_SocketIOCP.m_Socket = socket; s.m_SocketIOCP.m_SocketAddr = *addr (16 bytes)
        s.m_Status = CONNECTING (2)
        s.m_LastReceiveTime = CGTimer::GetTime(); s.m_LastHeartBeatSendTime = 0
        EmptyToActive(m, node)
        bViewNoAcceptSession = 1                                # re-arm the log below
        return node
    if bViewNoAcceptSession: log "* ACCEPT NO SESSION BUFFER - ERROR *"; bViewNoAcceptSession = 0
    return null                                                 # ProcessConnect closes the socket (§1.4)

CLoginBaseSessionManager::InactiveSession(m, node):                     @ FUN_004094d0
    node.pSession.m_Status = EMPTY (0)
    unlink node from the active list; push it at the head of the empty list; m_NumSessions−−
```

`bViewNoAcceptSession` is one static flag shared by the three pools: after a "no session" log in one pool, a
successful accept in another one re-arms it.

### 2.2 Session objects

`CLoginBaseSession` (0x108 bytes, all five session kinds): +0x00 `m_Status` (`SESSION_STATUS`: 0 EMPTY, 1 CONNECTED,
2 CONNECTING, 3 CLOSEING, 4 CLOSED), +0x04 `m_Connected_Server_ID` (peer type), +0x08 / +0x0c `m_Connected_World` /
`m_Connected_Zone`, +0x10 `m_Connected_Time` (`SYSTEMTIME`), +0x20 / +0x24 `m_LastReceiveTime` / `m_LastSendTime`,
+0x28 `m_SocketIOCP` (socket +0x28, `sockaddr` +0x2c: port +0x2e, IPv4 +0x30), +0xdc `m_Packet` (`CPacket`), +0xf4
`m_Last_PacketCommand`, +0xf8 `m_Last_PacketLength`, +0xfc `m_Last_PacketWorkType` (1 in the handler, 2 done, 3
failed; logged by "Closed AC/AL from"), +0x100 `m_IOCP_Process` (`CIOCP_Process_LSession`), +0x104
`m_LastHeartBeatSendTime`. L00 §1.1 lists the client fields with its own names; the official ones:

| Offset | `CLoginClientSession` member *(pdb2016)* | L00 §1.1 name |
|---|---|---|
| +0x108 | `m_SessionHandle` (u16) | `handle` |
| +0x10a | `m_ClientSeed` (u16) | `seed` |
| +0x10c | `m_PacketEncryptor` (`PacketEncrypt`: +0 `pe_point`, +2 `pe_mark`) | `xorIndex` / its copy |
| +0x110 | `m_UserNo` | `userNo` |
| +0x114 | `m_UserID` (`Name256Byte`) | `userId` |
| +0x214 | `m_UserSwpawnApps` (`Name5`, sic) | `spawnapps` |
| +0x228 | `m_UserVaidation` (u16, sic) | `validated` |
| +0x22a / +0x2aa | `m_strSerialKey[128]` / `m_strRandomValue[32]` | (not in L00 §1.1) |
| +0x2cc | `m_SessionMode` (`SessionMode`: 0 `L_CLIENT_SESSION_MODE_BEFORE_NC_USER_VERSION_REQ`, 1 `…_BEFORE_NC_USER_LOGIN_REQ_FOR_EACH_VER`, 2 `…_AFTER_NC_USER_LOGIN_REQ_FOR_EACH_VER`) | `loginStep` |

`CLoginWorldManagerSession` adds +0x108 `m_bFirstConnectForBroadCastWorldStatus`; `CLoginOPToolSession` adds
+0x108 `m_SessionHandle`, which nothing in Login writes or reads.

```pseudo
CLoginAccountDBSession::CLoginAccountDBSession(s):      @ FUN_00408cd0   base ctor (S02 §4.3); m_Connected_Server_ID = 0; world = zone = 0
CLoginAccountLogDBSession::CLoginAccountLogDBSession(s): @ FUN_00408d00  base ctor; m_Connected_Server_ID = 1; world = zone = 0
    # the base ctor's SERVER_ID_UNKNOWN (10) is overwritten: the DB links' peer type is known in advance
CLoginWorldManagerSession::CLoginWorldManagerSession(s): @ FUN_00409e10  base ctor; m_bFirstConnectForBroadCastWorldStatus = 0
CLoginOPToolSession::CLoginOPToolSession(s):            @ FUN_00409c10   base ctor only
CLoginClientSession::CLoginClientSession(s):            @ FUN_00409520
    base ctor; PacketEncrypt ctor; m_UserID = Name256Byte() ; m_UserSwpawnApps = 0 (5 × u32); m_ClientSeed = 0
CLoginClientSession::~CLoginClientSession(s):           @ FUN_004095b0   ~PacketEncrypt (= the empty FUN_0040a550); ~CLoginBaseSession FUN_00408d60
CLoginBaseSession::~CLoginBaseSession(s):               @ FUN_00408d60   (client base part only; no EH frame)
CLoginWorldManagerSession::~CLoginWorldManagerSession(s):   @ FUN_00408cf0   (with an EH frame)
    both: m_IOCP_Process.vftable = CIOCP_Process_Interfece; ~CPacket(m_Packet); ~CSocket_IOCP(m_SocketIOCP)
    # FUN_00408cf0 is one folded body for the DB-link members (from ~LoginServer), the WM pool and the OPTool pool
    # array destructors; the client sessions reach the separate FUN_00408d60 through ~CLoginClientSession

CLoginClientSession::SetSessionMode(s, mode) / GetSessionMode(s):   @ FUN_00409660 / FUN_00409670   m_SessionMode
    # callers: CParserClient::Parser FUN_00406680 (L00 §3.2) and CLoginClientSessionManager::ActiveSession

CLoginClientSession::Send_NC_MISC_SEED_ACK(s):          @ FUN_00409610   (L00 §2 SendSeed)
    s.m_PacketEncryptor.pe_point = pe_mark = s.m_ClientSeed % pe_encryptlen (499)
    Send(s, { 04, 07 08, u16 m_ClientSeed }, 5)          # 0x0807 NC_MISC_SEED_ACK
CLoginWorldManagerSession::Send_NC_MISC_S2SCONNECTION_RDY(s):  @ FUN_00409e30
CLoginOPToolSession::Send_NC_MISC_S2SCONNECTION_RDY(s):        @ FUN_00409c20
    Send(s, Rdy = { 02, 01 08 }, 3)                      # 0x0801 NC_MISC_S2SCONNECTION_RDY (bytes at 0x4302fc)
```

### 2.3 Client pool (`CLoginClientSessionManager`)

```pseudo
CLoginClientSessionManager::CLoginClientSessionManager(m):   @ FUN_00409680
    base ctor; vftable; srand(time(0)); m_ClientSeed = (u16) rand(); m_pSessionArray = null

CLoginClientSessionManager::InitSessions(m, n):   (Listen_Client, n = nMaxAccept)   @ FUN_00409a00
    base FreeSessions; if m_pSessionArray: destroy each (~CLoginClientSession) and delete[] it
    if n > 0:
        base InitSessions(n)
        m_pSessionArray = new CLoginClientSession[n]          # ctor FUN_00409520 each
        for i: node[i].pSession = &session[i]; session[i].m_SessionHandle = i
    return 1
CLoginClientSessionManager::FreeSessions(m):                 @ FUN_004096c0   base FreeSessions; destroy + delete[] the session array
CLoginClientSessionManager::~CLoginClientSessionManager(m):  @ FUN_00409970   the same, then the base destructor

CLoginClientSessionManager::ActiveSession(m, socket, addr):  (vftable[0], ProcessConnect §1.4)   @ FUN_00409700
    node = base ActiveSession(socket, addr); null → null
    s = node.pSession
    m_ClientSeed = (m_ClientSeed + 1) % pe_encryptlen; s.m_ClientSeed = m_ClientSeed     # sent in 0x0807
    s.m_UserVaidation = 0
    s.SetSessionMode(BEFORE_NC_USER_VERSION_REQ (0))
    return node
    # m_UserNo / m_UserID were reset when the slot was released (InactiveSession below); m_strSerialKey,
    # m_strRandomValue and m_UserSwpawnApps keep the previous user's bytes until a login handler overwrites them

CLoginClientSessionManager::InactiveSession(m, node):        (vftable[1], ProcessDisconnect §1.6)   @ FUN_00409b10
    h = s.m_SessionHandle; slot = h % m_MaxSessions
    session[slot].m_UserNo = 0xFFFFFFFF; session[slot].m_UserID = ""; session[slot].m_UserVaidation = 0
    h' = (u16)(h + m_MaxSessions); if h' % m_MaxSessions != slot: h' = slot      # u16 wrap: restart at the slot
    session[slot].m_SessionHandle = h'
    base InactiveSession(node)                                # m_Status = EMPTY, back to the empty list
```

**Handles.** A client's handle is its slot index plus a multiple of the pool size; every release advances it by
`m_MaxSessions`. The handle travels to AccountDB / AccountLogDB in the login requests and to the WM in 0x0C0D
(L00 §4), and comes back in their answers; a reply for a session that has closed in between finds a different
handle and is dropped:

```pseudo
CLoginClientSessionManager::HandleIsValid(m, h) = session[h % max].m_SessionHandle == h         @ FUN_00409760
CLoginClientSessionManager::GetSession(m, h)    = that session if the handles match, else null  @ FUN_004097d0
CLoginClientSessionManager::Close(m, h):  if the handles match: session.m_Status = 3            @ FUN_00409790
CLoginClientSessionManager::Send(m, h, data, n): if the handles match: CLoginBaseSession::Send(session, data, n)
                                                 else return 0                                   @ FUN_00409bc0
```

None of them checks `m_Status`: a reply can still reach a session that is closing (state 3) but not yet released.
The client manager has no 0xFFFF guard (the WM's has none either, W05-B8); Login uses no 0xFFFF handle value, so a
handle reaching 0xFFFF has no effect here.

```pseudo
CLoginClientSessionManager::Kickoff(m, s) → kicked:          @ FUN_00409810
    kicked = 0
    for every session o in the active list:
        if o != s and o.m_UserVaidation == 1 and o.m_UserNo == s.m_UserNo:
            Send(o, { 04, 17 0C, u16 0x0683 }, 5)                 # 0x0C17 NC_USER_CONNECTCUT_CMD, code 0x683
            o.m_UserVaidation = 0; o.m_Status = 3; kicked = 1
    return kicked
    # callers (L00 §4 / §5.1 / §5.2): the CH password-check answer FUN_00404320, the teenager answer FUN_00404050,
    # the four regional IP-block answers (FUN_00405180 / FUN_004054c0 / FUN_004056c0 / FUN_004058c0) and the 0x0C37
    # token login FUN_00406bb0; each of them also broadcasts 0x0C16 to the WMs (§2.5 BroadCast). The client sets its "logged in elsewhere" flag
    # on code 0x683 (L00 §8, client FUN_0046eac0)

CLoginClientSessionManager::BroadCastWorldStatus(m):         @ FUN_00409890
    info = m_WorldManager.GetWorldManagerInfo()                # §2.5
    p = CSendPacket(0x0C1C NC_USER_WORLD_STATUS_ACK, 1 + numofworld × 0x12, info)
    for every session in the client active list (any state, any mode): CLoginBaseSession::Send(session, p)
```

`BroadCastWorldStatus` runs when a WM sends its first 0x0808 after connecting (L00 §5.3) and when a WM link is
released (§2.5). It also reaches clients that have not logged in yet; the client only stores the list and redraws
it when the world-select window is open (client `AccountFrameWork::On_NC_USER_WORLD_STATUS_ACK` FUN_0046eae0:
`Server::SetWorldMgrAddr`, then `WorldSelectWin::UpdateServerList` if the window's vtable +0x104 check passes,
*inferred: "is shown"*), so the extra copies are harmless.

### 2.4 OPTool pool (`CLoginOPToolSessionManager`)

```pseudo
CLoginOPToolSessionManager::CLoginOPToolSessionManager(m):   @ FUN_00409c30   base ctor; vftable; m_pSessionArray = null
CLoginOPToolSessionManager::InitSessions(m, n):  (Listen_OPTool)            @ FUN_00409d20
    base FreeSessions; destroy + delete[] the old array (with the folded session destructor FUN_00408cf0, §2.2)
    if n > 0: base InitSessions(n); new CLoginOPToolSession[n] (FUN_00409c10); node[i].pSession = &session[i]
    return 1                                       # no handles: m_SessionHandle stays uninitialised
CLoginOPToolSessionManager::FreeSessions(m):                 @ FUN_00409c50   base FreeSessions; destroy + delete[] the array
CLoginOPToolSessionManager::~CLoginOPToolSessionManager(m):  @ FUN_00409c90   the same, then the base destructor
```

`ActiveSession` / `InactiveSession` are the base ones (§2.1).

### 2.5 WM pool and world table (`CLoginWorldManagerSessionManager`)

The WM manager also owns the world list that Login sends to clients (0x0C0A / 0x0C1C) and answers world selects
from (0x0C0B):

| Member | Built by | Contents |
|---|---|---|
| `m_pWorldManagerInfo` | `InitWorldManagerInfo` | `PROTO_NC_USER_LOGIN_ACK` *(pdb2016)*: u8 `numofworld`, then `WorldInfo[numofworld]` = { u8 `worldno`, `Name4 worldname` (char[16]), u8 `worldstatus` } (0x12 bytes) |
| `m_ppWSMappingTable` | `InitSessions` | `CLoginWorldManagerSession*[nMaxAccept]`, **indexed by world number**: the WM link of each world |
| `m_pWMClientValidationTable` | `InitWorldManagerInfo` | u16[numofworld], **indexed by world number**: per-world counter for the 0x0C0D validate key |

```pseudo
CLoginWorldManagerSessionManager::CLoginWorldManagerSessionManager(m):   @ FUN_00409e40
    base ctor; the four extra pointers = null; vftable

CLoginWorldManagerSessionManager::InitSessions(m, n):  (Listen_WorldManager)   @ FUN_0040a420
    FreeSessions(m)                                      # also frees the world table (below)
    if n > 0:
        base InitSessions(n); m_pSessionArray = new CLoginWorldManagerSession[n] (FUN_00409e10)
        m_ppWSMappingTable = new ptr[n]; all null; node[i].pSession = &session[i]
    return 1

CLoginWorldManagerSessionManager::InitWorldManagerInfo(m):  (Listen_WorldManager, after InitSessions)   @ FUN_00409eb0
    n = CServerInfo::GetNumOfWorld()                     # WORLD_NAME rows (S02 §4.3, FUN_00410750)
    if n <= 0: return 0                                  # Listen_WorldManager fails → the server stops
    m_pWMClientValidationTable = new u16[n] (zeroed)
    m_pWorldManagerInfo = new byte[1 + n × 0x12]; numofworld = n
    i = 0
    for each config row with dwID == 2 (WORLD_NAME, in file order):
        w = column 0
        entry[i] = { worldno = w, worldname = strncpy(column 1, 16), worldstatus = 2 }
        if GetServerInfo(&r, id 5 (WM), world w, zone 0, from 20 (client)) and GetWorldName(w, &name):
            entry[i] = { worldno = w, worldname = strncpy(name, 16), worldstatus = 0 }
        i++
    return 1
    # status 2 ("You cannot connect to an empty server.") marks a world that has no WM client-port row, so its
    # players could not be sent anywhere; 0 ("Server is closed.") a configured world whose WM is not connected

CLoginWorldManagerSessionManager::GetWorldManagerInfo(m, &out): out = m_pWorldManagerInfo   @ FUN_0040a010

CLoginWorldManagerSessionManager::ActiveSession(m, socket, addr) = base ActiveSession       @ FUN_00409e60

CLoginWorldManagerSessionManager::SetWMSession(m, world, s):   (0x0802 handler only, s ≠ null)   @ FUN_0040a240
    m_ppWSMappingTable[world] = s                        # no bound check (original bug) L01-B1
    e = entry with worldno == world; none → return
    if s: e.worldstatus = 6                              # open, lowest load band (§3)
    elif e.worldstatus != 2: e.worldstatus = 0           # (dead: the only caller passes a session)
```

What the WM's 0x0802 handler (`CParserWorldManager::fc_NC_MISC_S2SCONNECTION_REQ` FUN_00408170, L00 §5.3) does
with the pool, in detail *(PDB struct `PROTO_NC_MISC_S2SCONNECTION_REQ` = { u8 `echo_data`, u8 `server_to_id`, u8
`server_from_id`, u8 `server_from_world_num`, u8 `server_from_zone_num`, u16 `key` })*:

```pseudo
    server_to_id != 4 (Login): log "NC_MISC_S2SCONNECTION_REQ <server_from id=%d w=%d z=%d, server_id_to=%d, key=%d, my_type=%d>"
                               return 0 (the parser closes the link)
    key != server_to_id + server_from_id: log "… <server_id_from=%d, server_id_to=%d, key=%d, my_type=%d>"; return 0
    Send 0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo_data, u16 error = 0 }; send failure → log "ValidationFail …"; return 0
    s.m_Connected_Server_ID = server_from_id; s.m_Connected_World = server_from_world_num; s.m_Connected_Zone = zone
    s.m_Connected_Time = GetLocalTime()
    old = m_ppWSMappingTable[world]; if old: old.m_Status = CONNECTING (2)    # demote the previous link of the world
    SetWMSession(world, s); s.m_bFirstConnectForBroadCastWorldStatus = 1; s.m_Status = CONNECTED (1)
    log "Connected from (%-25s world=%3d …)"; return 1
```

The key is not a secret (it is the sum of two type bytes), and nothing compares `server_from_world_num` with the
configured worlds: any peer that reaches the WM port can register as the WM of any world number 0 … 255. The
world number indexes `m_ppWSMappingTable`, which has only `nMaxAccept` (shipped: 50) entries: a world number ≥ that
writes a session pointer past the array (heap corruption) **(original bug) L01-B1**; `InactiveSession` below reads
the same slot. A demoted old link stays open in state 2: it is still pumped, its next packet with a
`CheckConnectionValidation` (every handler but 0x0802 / 0x0804 / 0x0805) fails and closes it (§4.2), and its release
does not touch the mapping (the slot now holds the new session).

```pseudo
CLoginWorldManagerSessionManager::SetWorldManagerConnectInfo(m, world, cnt):   (0x0808 handler)   @ FUN_0040a0c0
    # cnt = PROTO_NC_MISC_USER_COUNT_CMD { u16 NumOfUser, u16 MaxOfUser }, world = session.m_Connected_World
    e = entry with worldno == world; none → return
    e.worldstatus = load band of (NumOfUser, MaxOfUser, gServer.m_LoginUserRatable[world])     # §3

CLoginWorldManagerSessionManager::GetWorldManagerConnectInfo(m, world, &ack):   (0x0C0B, 0x0C0E)   @ FUN_0040a020
    # ack = PROTO_NC_USER_WORLDSELECT_ACK { u8 worldstatus, Name4 ip, u16 port, u16 validate_new[32] }
    if GetServerInfo(&r, 5, world, 0, 20): ack.ip = strncpy(r.pIP, 16); ack.port = r.nPort     # the WM client port
    ack.worldstatus = 4                                  # "Login failed due to an unknown error." if not listed
    e = entry with worldno == world; none → return 0
    ack.worldstatus = e.worldstatus
    return e.worldstatus >= 5                            # 5 (full) passes (original bug) L00-B3

CLoginWorldManagerSessionManager::GetClientValidation(m, world):   (0x0C0B only)   @ FUN_0040a200
    m_pWMClientValidationTable[world] = (m_pWMClientValidationTable[world] + 1) & 0x7FF
    return it                                            # seeds the XOR check word of 0x0C0D's validate[] (L00 §4)
```

`m_pWMClientValidationTable` has one entry per configured world but is indexed by the world number. With world
numbers that are not exactly 0 … n−1 (e.g. one world numbered 1), a world select for the highest-numbered worlds
increments a u16 past the end of the array **(original bug) L01-B2**. The shipped config has one world, number 0,
and is not affected. (0x0C0B reaches `GetClientValidation` only for a listed world with status ≥ 5, i.e. one whose
WM is connected.)

```pseudo
CLoginWorldManagerSessionManager::BroadCast(m, data, n) → ok:   @ FUN_00409e70
    ok = 1; for every WM session with m_Status == CONNECTED: ok &= CLoginBaseSession::Send(s, data, n)
    # callers: the 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD broadcasts of the login answers (L00 §4 / §5.1 / §5.2)

CLoginWorldManagerSessionManager::InactiveSession(m, node):   (vftable[1], ProcessDisconnect §1.6)   @ FUN_0040a2b0
    s = node.pSession; w = s.m_Connected_World
    if m_ppWSMappingTable[w] == s:                       # the world's current link (not a demoted one)
        m_ppWSMappingTable[w] = null
        e = entry with worldno == w: if e.worldstatus != 2: e.worldstatus = 0      # "Server is closed."
        gServer.m_Client.BroadCastWorldStatus()          # every client gets the new list (§2.3)
    base InactiveSession(node)
    # a WM that never completed 0x0802 has m_Connected_World 0 (or the previous user's world): if world 0's
    # link is a different session nothing happens

CLoginWorldManagerSessionManager::FreeSessions(m):           @ FUN_0040a330
    base FreeSessions; delete[] m_ppWSMappingTable; destroy + delete[] m_pSessionArray (FUN_00408cf0 each)
    delete[] m_pWMClientValidationTable; delete m_pWorldManagerInfo; all null
CLoginWorldManagerSessionManager::~CLoginWorldManagerSessionManager(m):   @ FUN_0040a3c0   FreeSessions; base destructor
```

`m_Connected_World` of a pool slot is not reset on release; a slot reused by a WM that closes before its 0x0802
compares the old world's mapping with itself, which no longer matches (the old link was released, so the
mapping is null or another session): harmless.

### 2.6 Session lifecycle: accept → pool → free

```
accept ─ ProcessConnect (§1.4) ─ vftable[0] ActiveSession: empty list head → active list, m_Status 2,
         │                        packet buffer cleared, socket / addr / receive time set
         │  client: seed, m_UserVaidation 0, m_SessionMode 0, then m_Status 1, register IOCP, 0x0807
         │  WM / OPTool: register IOCP, 0x0801; 0x0802 → m_Status 1 (L00 §5.3 / §5.4)
         ▼
pumped every pass while m_Status ∈ {1, 2} (§1.5); heartbeat checked every pass (§1.6)
         │  some event sets m_Status = 3 (table below)
         ▼
ProcessDisconnect (§1.6): CLoginBaseSession::Close (shutdown + closesocket) → vftable[1] InactiveSession:
         client: m_UserNo −1, m_UserID "", m_UserVaidation 0, handle += pool size
         WM: unmap the world, status 0, 0x0C1C to every client
         base: m_Status 0, back to the empty list
```

| Event | Who sets `m_Status = 3` | Sessions |
|---|---|---|
| peer closed the connection (zero-byte read), failed read / write completion | `CIOCP_Process_LSession::IOCP_Process` / `IOCP_CloseProcess` FUN_00409020 / FUN_004090b0 (S02 §1.6) | all |
| bad frame | the pump, r == 2 (§1.5) | all |
| handler returns 0 (incl. a failed `CheckConnectionValidation`, an unregistered opcode on the client link, a login-state violation) | `CParserClient::Parser` FUN_00406680 (L00 §3.2) / the shared parser FUN_004087d0 (§4.1) | all |
| client answers Login's 0x0804 (or sends any opcode but 0x0C65 / the login request) before logging in (`m_SessionMode` 0 / 1) | `CParserClient::Parser` FUN_00406680 "Invalid sequence protocol" | client |
| no frame for 30 s + 180 s | `ProcHeartBeat` / `CheckHeartBeat` → `CSocket_IOCP::CloseUseIOCP` → IOCP close completion → as above | all |
| register to IOCP or the first send fails | `ProcessConnect` (§1.4) | all |
| a DB server or the WM rejects / answers a login with a close | `CLoginClientSessionManager::Close(handle)` FUN_00409790, called by the password-check answers, 0x0C0E, the OTP / Netmarble / Outspark logins (L00 §4, §5) | client |
| same account logs in again | `Kickoff` FUN_00409810: 0x0C17 {0x683} to the old session | client |
| process stop | not via state 3: `ProcessStop` closes every socket with `DissconnectAllSessions`, then frees the pools without `InactiveSession` (S02 §4.3) | all |

The heartbeat outcome for a client depends on its `m_SessionMode` (`CParserClient::Parser` FUN_00406680, L00 §3.2):
in mode 0 only 0x0C65 (version check) and in mode 1 only dept 3 with cmd 0x37 or the login request of the build are
accepted; every other opcode, **including 0x0804 / 0x0805**, is logged "Invalid sequence protocol" and closes the
client (m_Status 3). So a client that stays 30 s before logging in gets Login's 0x0804; if it answers 0x0805 it is
closed at once, if not it is closed 180 s later: the heartbeat Login sends to a pre-login client has no answer that
keeps it open **(original bug) L01-B11**. Only in mode 2 (after the login request) are 0x0804 / 0x0805
accepted. Whether the client answers in the login scene depends on its heartbeat flag (net+0x10048, set by client
FUN_006d2da0, whose caller is not resolved; §5).

Nothing in Login closes a mode-2 client that stays idle but answers heartbeats (the WM's 2-hour login timeout,
W05 §4.5, has no Login twin): a client may stay on the world-select screen indefinitely *(inferred: no other
timer touches client sessions)*.

---

## 3. World status and the load table (`m_LoginUserRatable`)

`LOGIN_USER_RATABLE` *(pdb2016)* = { u16 `nWMSUS_1`, `nWMSUS_2`, `nWMSUS_3`, `nWMSUS_4`, `nWMSUS_5`, `nWMSUS_FULL` },
percentages of a world's `MaxOfUser`. `m_LoginUserRatable[256]` is indexed by world number; the constructor
(FUN_004029e0, S02 §4.3) sets every entry to { 3, 5, 8, 10, 30, 95 } (u16 writes; S02 §4.3 says "6 ints", the PDB
and the code agree on u16). Readers: `SetWorldManagerConnectInfo` and the two OPTool handlers below; nothing loads
it from a file, so the values hold until an OPTool changes them and are lost at restart.

```pseudo
load band in SetWorldManagerConnectInfo(world, NumOfUser, MaxOfUser):   @ FUN_0040a0c0
    t = gServer.m_LoginUserRatable[world]; pct(x) = (x × MaxOfUser) / 100      (signed int division)
    if   NumOfUser >= pct(t.nWMSUS_FULL): status = WMSUS_FULL (5)
    elif NumOfUser >= pct(t.nWMSUS_5):    status = WMSUS_5 (10)
    elif NumOfUser >= pct(t.nWMSUS_4):    status = WMSUS_4 (9)
    elif NumOfUser >= pct(t.nWMSUS_3):    status = WMSUS_3 (8)
    elif NumOfUser >= pct(t.nWMSUS_2):    status = WMSUS_2 (7)
    else:                                 status = WMSUS_1 (6)
```

The status values are the 2016 PDB enum `WORLD_MANAGER_SERVER_USER_STATUS` *(pdb2016)*: `WMSUS_CLOSED` 0,
`WMSUS_WORKING` 1, `WMSUS_EMPTY` 2, `WMSUS_RES1` 3, `WMSUS_UNKNOWN` 4, `WMSUS_FULL` 5, `WMSUS_1` … `WMSUS_5` 6 … 10.
Each `LOGIN_USER_RATABLE` field `nWMSUS_k` is the lower threshold of status `WMSUS_k`.

`nWMSUS_1` is never read by the computation: the OPTool can set and read it, without effect **(original bug)
L01-B4**. `WMSUS_1` is the "else" band, so its threshold would only matter as a lower bound for a band below it,
which the enum does not have. `MaxOfUser = 0` makes every threshold 0, so the world shows as full.

All world status values (`WorldInfo.worldstatus` in 0x0C0A / 0x0C1C, `worldstatus` in 0x0C0C); client texts from
L00 §8 (client `FUN_0046ef20`), icons from the world list (below):

| Value (`WMSUS_…`) | Set by | Client on world select (0x0C0C) | World-list icon |
|---|---|---|---|
| 0 `CLOSED` | `InitWorldManagerInfo` (configured world), WM link released (§2.5) | "Server is closed. Please try login later." | 4 |
| 1 `WORKING` | – (never set) | "Server is under maintenance. Please try login later." | 3 |
| 2 `EMPTY` | `InitWorldManagerInfo`: world without a WM client-port row; kept on WM release, overwritten by a WM connect (6) | "You cannot connect to an empty server." | 4 |
| 3 `RES1` | – (never set) | "The server has been reserved for a special use." | 4 |
| 4 `UNKNOWN` | `GetWorldManagerConnectInfo`: world number not in the list | "Login failed due to an unknown error." | 4 |
| 5 `FULL` | load ≥ `nWMSUS_FULL` % | "Server is full. Please try again later." (Login passes it, L00-B3) | 1 |
| 6 / 7 / 8 `WMSUS_1` … `_3` | WM connected (6), then each 0x0808 by load band (< `nWMSUS_4` %) | connect to the WM | 0 |
| 9 `WMSUS_4` | 0x0808, load ≥ `nWMSUS_4` % | connect to the WM | 2 |
| 10 `WMSUS_5` | 0x0808, load ≥ `nWMSUS_5` % | connect to the WM | 1 (same as full) |

```pseudo
client WorldSelectWin::UpdateServerList(win):   (after 0x0C0A / 0x0C1C)        client @ FUN_00473b80
    for row r in 0 … 7 of the current page (world index i = page × 8 + r):
        hide the row's five status icons
        if i >= world count: continue                       # no row
        if i is past the window's world list: show icon 4
        else switch WorldInfo[i].worldstatus:               # (byte +0x11 of the 0x12-byte entry)
            0, 2, 3, 4: icon 4      1: icon 3      5, 10: icon 1      6, 7, 8: icon 0      9: icon 2
            other: no icon
```

The client therefore shows three load levels for an open world (icon 0 below `nWMSUS_4`, icon 2, icon 1 from
`nWMSUS_5` on), and the top load band (default ≥ 30 %) shows the same icon as a full world while still connecting
on select (FUN_0046ef20 connects for 6 … 10) *(inferred: icons 0 / 2 / 1 read as low / medium / high-full; their
images are not resolved)*. The icon slots are the window's 5 controls per row at `win+0x1a4 + row × 20`; their
meaning comes only from this switch.

The status changes with every 0x0808 the WM sends, but only the first 0x0808 after a WM connects pushes the list
to the clients (0x0C1C, L00 §5.3); later changes reach a client only with its next 0x0C1B request or a new login.

```pseudo
0x2812 NC_OPTOOL_LOGIN_USER_RATABLE_GET_REQ { u8 nWorldNo }:          @ FUN_00407c90
    if !CParserOPTool::CheckConnectionValidation(s): return 0          # m_Status must be 1 (§4.2)
    Send 0x2813 NC_OPTOOL_LOGIN_USER_RATABLE_GET_ACK {                 # raw frame { 0x0F, 13 28, … }, 16 bytes
        u8 nWorldNo; LOGIN_USER_RATABLE RateTable = m_LoginUserRatable[nWorldNo]   # 6 × u16
    }
    return the send result

0x2814 NC_OPTOOL_LOGIN_USER_RATABLE_SET_CMD { u8 nWorldNo; LOGIN_USER_RATABLE RateTable }:   @ FUN_00407d50
    if !CheckConnectionValidation(s): return 0
    if nWorldNo == 0xFF: every one of the 256 entries = RateTable      # 0xFF = all worlds
    else:                m_LoginUserRatable[nWorldNo] = RateTable
    return 1                                                           # no answer
```

The PDB structs `PROTO_NC_OPTOOL_LOGIN_USER_RATABLE_GET_REQ` / `_GET_ACK` / `_SET_CMD` *(pdb2016)* match the code
(sizes 1 / 0xd / 0xd). Neither handler checks the frame length: a short SET frame stores whatever follows in the
receive buffer **(original bug) L01-B5**. Entry 255 can only be set through "all". The values are not checked
either (e.g. `nWMSUS_FULL` below `nWMSUS_5`). L00 §5.4 lists these two opcodes only as "further status queries".

---

## 4. Parsers and the per-parser handler copies

### 4.1 Handler tables and the shared server-link parser

Each parser object holds a `PROTOCOLFUNCTIONTEMPLETE<…>` `m_PFT`: +0 vftable, then `pft_funcpnt[1024]` (one row
pointer per command), `pft_defaultdepartment` (the shared row every command starts with) and `pft_deffunc` (the
parser's `fc_dummyfunction`). The layout and `pft_Store` are the WM's (W05 §6.1). In Login all five template
instances' `pft_Store` bodies were folded into one function, FUN_004086b0 (`handlers.json` `store`), called by
every registration function L00 cites (FUN_00404cd0, FUN_00405e50, FUN_00406e30, FUN_00407ef0, FUN_00408bc0):

```pseudo
PROTOCOLFUNCTIONTEMPLETE<T>::pft_Store(t, dept, cmd, fn):      @ FUN_004086b0
    if pft_funcpnt[cmd] == pft_defaultdepartment:               # first handler of this command
        pft_funcpnt[cmd] = new fn[64]; every slot = pft_deffunc
    if pft_funcpnt[cmd][dept] != pft_deffunc:
        ac_AssertFail("PROTOCOLFUNCTIONTEMPLETE<T>::pft_Store : Duplicate protocol set"); ShineExit("…pft_Store")
    pft_funcpnt[cmd][dept] = fn

~PROTOCOLFUNCTIONTEMPLETE<CParserWorldManager>(t):             @ FUN_00408680
    vftable; for each of the 1024 rows: if row != pft_defaultdepartment: delete[] row
scalar deleting destructor (vftable slot 0):                   @ FUN_00408780   the same, then delete t if flag & 1
```

```pseudo
CParserWorldManager::Parser(parser, s) → result:   (shared by AccountDB, AccountLogDB, OPTool, WM pumps, §1.5)   @ FUN_004087d0
    pkt = s.m_Packet.GetIDPtr()                                   # vtbl 0x18: opcode, then the payload
    s.m_Last_PacketCommand = u16 pkt[0]; s.m_Last_PacketLength = (u16) s.m_Packet.GetDataSize()   # vtbl 0x14
    s.m_Last_PacketWorkType = 1
    result = pft_funcpnt[op & 0x3FF][op >> 10](s, pkt, len)       # dept 0 … 63, cmd 0 … 1023: always in range
    if result == 0: s.m_Last_PacketWorkType = 3; s.m_Status = 3; return 0
    s.m_Last_PacketWorkType = 2; return result
```

No login-state checks and no decryption (only client frames are XOR-encrypted, L00 §3.2).

Unregistered opcodes reach the parser's `pft_deffunc`, its `fc_dummyfunction`, which logs
`"fc_dummyfunction, <PEER>, dep=%d, cmd=%d, length=%d, … %- 5d=%15s:%- 5d)"` and returns:

| Parser | `fc_dummyfunction` | Returns | Effect |
|---|---|---|---|
| `CParserAccountDB` | FUN_004039a0 | 1 | ignored |
| `CParserAccountLogDB` | FUN_00404eb0 | 1 | ignored |
| `CParserOPTool` | FUN_00407020 | 1 | ignored |
| `CParserWorldManager` | FUN_004080d0 | 0 | the WM link is closed (state 3) |
| `CParserClient` | FUN_00406010 | 0 | the client is closed; normally not reached, the dispatcher rejects unregistered opcodes first (L00 §3.2) |

L00 §3.2 says unregistered opcodes on the server links are ignored; for the WM link they close it (knowledge file).
An unknown opcode from a newer WM therefore drops the world from the list (§2.5) until the WM reconnects.

### 4.2 0x0801 / 0x0803 / 0x0804 / 0x0805 per parser

| Opcode | AccountDB (L00 §5.1) | AccountLogDB | OPTool | WM | Client |
|---|---|---|---|---|---|
| 0x0801 RDY | FUN_00403a40 | FUN_00404f50 | – | – | – |
| 0x0803 ACK | FUN_00404fb0 (one folded body, L00 §5.2) | FUN_00404fb0 | – | – | – |
| 0x0804 HEARTBEAT_REQ | FUN_00403aa0 | FUN_004050e0 | FUN_00407480 | FUN_00408560 | FUN_004060b0 (L00 §4) |
| 0x0805 HEARTBEAT_ACK | FUN_004074a0 | FUN_004074a0 | FUN_004074a0 | FUN_004074a0 | FUN_004074a0 |

```pseudo
0x0801 NC_MISC_S2SCONNECTION_RDY (AccountLogDB):                         @ FUN_00404f50
    Send raw { 09, 02 08, PROTO_NC_MISC_S2SCONNECTION_REQ {
        echo_data = 0, server_to_id = 1 (AccountLog), server_from_id = m_MyServer.nServerID (4),
        server_from_world_num = m_MyServer.nWorldNo, server_from_zone_num = m_MyServer.nZoneNo,
        key = (u8 nServerID) + 1 } }                                       # 10 bytes
    return the send result
    # the AccountDB copy FUN_00403a40 is the same with server_to_id = 0 and key = nServerID: both keys are
    # server_to_id + server_from_id, the rule the Login checks on its own 0x0802 (§2.5). L00 §5.1 shows the payload
    # as { myServerId, myWorld, myZone }: the leading echo_data / server_to_id bytes and the key are missing there

0x0804 NC_MISC_HEARTBEAT_REQ (AccountDB, AccountLogDB, OPTool, WM, client):   @ FUN_00403aa0 / FUN_004050e0 / FUN_00407480 / FUN_00408560 / FUN_004060b0
    return Send(s, Ack = { 02, 05 08 }, 3)                                 # 0x0805 HEARTBEAT_ACK, bytes at 0x430080
    # five identical bodies; no CheckConnectionValidation, so a server link's heartbeat is answered in any state
    # (also a demoted WM link in state 2, §2.5); on the client link the parser lets 0x0804 / 0x0805 through only in
    # m_SessionMode 2 and closes the client for them in modes 0 / 1 (§2.6)

0x0805 NC_MISC_HEARTBEAT_ACK (all five parsers):   CParserWorldManager::fc_NC_MISC_HEARTBEAT_ACK   @ FUN_004074a0
    return 1          # one folded body; receiving any frame already refreshed m_LastReceiveTime (S02 §1.6)
```

### 4.3 One-time-token list object (`COTPLogin`, `COTPData`)

`COTPLogin` *(pdb2016)*: +0 `m_bInit`, +4 `m_NumOfOTP`, +8 `m_pOTPTop`, +0xc `m_pOTPBottom` (doubly linked
`OTP_LIST` nodes: `COTPData OTPData` + `pLinkDn` +0x12c, `pLinkUp` +0x130), +0x10 `m_IncreaseSeed`. `COTPData`
(0x12c): `Name8 sOTP` (char[32]), `in_addr nClientIP`, `long tDueTime`, `ulong nUserNo`, `Name256Byte sUserID`. This
is L00's `g_TokenTable` (§5.3 0x0C35 / §4 0x0C37).

```pseudo
COTPLogin::COTPLogin(o):           @ FUN_0040a560   m_bInit = m_NumOfOTP = 0; m_pOTPTop = m_pOTPBottom = null; m_IncreaseSeed = 0
COTPData::COTPData(d):             @ FUN_0040a520   sOTP = 0 (8 × u32); sUserID = Name256Byte()
COTPData::operator=(d, src):       @ FUN_0040a580   copy sOTP, nClientIP, tDueTime, nUserNo, sUserID
COTPLogin::IsAddable(o, userNo):   @ FUN_0040a5e0   0 if a node with nUserNo == userNo exists, else 1   (L00 "ContainsUser")
COTPData::~COTPData():             @ FUN_0040a550   empty (`ret`)
```

The list operations (callers: 0x0C35 `fc_NC_USER_CREATE_OTP_REQ` FUN_00408a20 and 0x0C37
`fc_NC_USER_LOGIN_WITH_OTP_REQ` FUN_00406bb0, L00 §5.3 / §4):

```pseudo
COTPLogin::Find(o, sOTP) → node:            @ FUN_0040a610   (L00 "g_TokenTable.Find")
    null sOTP → null; first node from m_pOTPTop whose 32-byte sOTP equals sOTP (8 × u32 compare), else null
COTPLogin::Add(o, data) → bool:             @ FUN_0040a680   (L00 "Insert")
    node = new OTP_LIST (0x134); null → 0
    node.OTPData = data (COTPData::operator= FUN_0040a580); append at m_pOTPBottom; m_NumOfOTP += 1; return 1
    # no upper bound on m_NumOfOTP: one node per 0x0C35 that passed IsAddable (one token per user number)
COTPLogin::DelByDueTime(o, now):            @ FUN_0040a710   (L00 "ExpireOlderThan")
    unlink and delete every node with tDueTime <= now; return 1          # but see L01-B9
COTPLogin::DelByIP(o, ip):                  @ FUN_0040a7a0   (L00 "NoteFailure")
    unlink and delete every node with nClientIP == ip; return 1          # but see L01-B9
    # 0x0C37 with an unknown token deletes every pending token of the sender's IP: a wrong guess from one address
    # also invalidates the tokens of other players behind the same NAT address
COTPLogin::DelByOTP(o, sOTP) → bool:        @ FUN_0040a830   (L00 "Remove")
    node = Find(sOTP); null → 0; unlink, delete, m_NumOfOTP −= 1; return 1
```

Both sweeping deletes walk the list with one cursor and continue from `cursor->pLinkDn` after each step. When the node
they delete is the head, the cursor becomes the old second node and the loop then steps past it, so that node is never
tested **(original bug) L01-B9**. Tokens are appended in issue order, so expired tokens sit at the head: when two or
more have expired, every second one survives a `DelByDueTime` call, and the next `Find` in the same 0x0C37 can still
accept it after its due time (until a later call removes it as the new head).

```pseudo
COTPLogin::MakeOTP(o, d) → bool:   (cited by L00 §5.3 as the token generator)                   @ FUN_0040a8a0
    d == null → 0
    text = sprintf("%d%d%d%d%d%c", d.nClientIP, m_IncreaseSeed, d.nUserNo, d.tDueTime, rand(), '\0')
    m_IncreaseSeed += 1
    d.sOTP = first 32 chars of CMD5Checksum::GetMD5(text)          # 32 lower-case hex digits, no terminator
    return 1                                                        # never fails for a non-null d
```

L00 §5.3 writes the token as the `sprintf` result itself; it is the MD5 hex digest of that string (argument order
read from the pushes at 0x40a8f1 … 0x40a914; `%c` takes the 0 pushed before `rand()`). L00's failure code 0x1E59
"token generation failed" is therefore unreachable. Login's MD5 is the library copy of W05 §6.3: `GetMD5`
FUN_0040c170 (state 0x67452301 … 0x10325476) → `Update` FUN_0040b920 → `Transform` FUN_0040b240 → `Final` FUN_0040bf60
(hex via `"%x"` / `"0%x"` / `"00"` padding into a `std::string`); `~CMD5Checksum` FUN_0040b200 and its scalar deleting
destructor FUN_0040b210; FUN_0040bbac and the two `Catch_All` funclets at 0x40bb83 / 0x40bc0b are compiler-split
pieces of `std::basic_string::_Copy` FUN_0040bad0, the `std::string` growth inside `Final` (copy old text, free the old buffer; *(inferred)* from the body).

FUN_0040a550 is the one empty destructor the linker kept for every trivially destructible class: `~CSendPacket`
(after every CSendPacket send in the handlers; the frame buffer is inside the object on the stack), `~PacketEncrypt`,
`~COTPLogin` in `~LoginServer`, and the `WorldInfo` array in the WM `FreeSessions`. L00's names file calls it
`Pkt_Free`; it frees nothing.

### 4.4 Connection check, small handler bodies, template destructors

Every handler except 0x0802 (WM / OPTool login), 0x0804 and 0x0805 starts with its parser's
`CheckConnectionValidation`. The five bodies differ only in the peer name of the log line:

```pseudo
CParser<Peer>::CheckConnectionValidation(parser, s, pkt, len) → bool:
        @ FUN_004038f0 (AccountDB) / FUN_00404e00 (AccountLogDB) / FUN_00405f60 (client) / FUN_00406f70 (OPTool) / FUN_00408020 (WM)
    if s.m_Status == 1 (CONNECTED): return 1
    log "ERROR - 접속 <ACCOUNT_DB | ACCOUNTLOG_DB | CLIENT | OPTool | WORLDMANAGER> 미인증 상태에서 패킷 도착, 바로 접속을
         끊음, dep=%d, cmd=%d, length=%d, %15s:%- 5d)"      # "packet arrived before authentication, closing at once";
                                                             # IP = inet_ntoa(s +0x30), port = ntohs(s +0x2e)
    return 0                                                 # the handler returns 0 → the parser closes the link (§4.1)
```

`m_Status == 1` means: client accepted (§1.4), DB link answered 0x0803 (L00 §5.2), WM / OPTool sent a valid 0x0802
(§2.5). A WM demoted to state 2 by a second login for its world (§2.5) therefore fails every later check and is
closed by its next frame other than a heartbeat.

```pseudo
0x0C06 NC_USER_LOGIN_REQ:         CParserClient::fc_NC_USER_LOGIN_REQ          @ FUN_00406950   return 0
0x0C18 NC_USER_NORMALLOGOUT_CMD:  CParserClient::fc_NC_USER_NORMALLOGOUT_CMD   @ FUN_004062e0   return 0
    # both close the client (m_Status 3 via the client parser, L00 §3.2); L00 §4 calls them "no-op". 0x0C06 is the
    # old login request, refused anyway before m_SessionMode 2; 0x0C18 is how a client at world select logs out

0x2818 NC_OPTOOL_LOGON_PROCESS_TIME_VIEW_REQ {} (OPTool):                    @ FUN_00407df0
    if !CheckConnectionValidation(s): return 0
    Send raw { 1A, 19 28, PROTO_NC_OPTOOL_LOGON_PROCESS_TIME_VIEW_ACK {           # 27 bytes, opcode 0x2819
        u32 Connect_Count = 0, Connect_Time = 0, Login_Count = 0, Login_Time = 0,
        u32 IPBlock_Count = 0, IPBlock_Time = 0 } }                               # field names (pdb2016)
    # every field is the constant 0: Login keeps no logon-time statistics   (original bug) L01-B10
```

The handler-table destructors are not folded like `pft_Store` (§4.1): each template instance keeps its own pair, all
with the same body (restore the vftable, `delete[]` every row that is not `pft_defaultdepartment`; the scalar deleting
one also frees the object when `flag & 1`). They run from `~LoginServer` (§1.7).

| Instance | `~PROTOCOLFUNCTIONTEMPLETE` | scalar deleting destructor (vftable slot 0) |
|---|---|---|
| `CParserAccountDB` | FUN_00403fa0 | FUN_00403fd0 |
| `CParserAccountLogDB` | FUN_00405100 | FUN_00405130 |
| `CParserClient` | FUN_00406600 | FUN_00406630 |
| `CParserOPTool` | FUN_00407e70 | FUN_00407ea0 |
| `CParserWorldManager` | FUN_00408680 | FUN_00408780 (§4.1) |

The session IOCP glue (S02 §1.6) has three more trivial bodies in Login: the base class
`CIOCP_Process_Interfece::IOCP_CloseProcess` FUN_00408d20 (empty; `CIOCP_Process_LSession` overrides it with
FUN_004090b0), the base scalar deleting destructor FUN_00408d30 (vftable slot 2 of the `CIOCP_Process_LSession`
vftable, which therefore never runs the derived destructor) and `~CIOCP_Process_LSession` FUN_00410850 (resets the
vftable to the base one). `PacketEncrypt::PacketEncrypt` FUN_0040b160 is empty (the cipher position is set by
`InitSessions` / `ActiveSession`, §2.3).

### 4.5 Value types and message helpers used by the L00 handlers

| Function | Body | Used by |
|---|---|---|
| `Name256Byte::Name256Byte` FUN_00403430 | 256 bytes = 0 | client session ctor (§2.2), `COTPData` (§4.3), the message helpers below |
| `Name256Byte::operator=(const char*)` FUN_00403560 | 256 bytes = 0, then `strncpy(…, 256)`: a 256-char source leaves no terminator | user names from DB answers (L00 §5.1) |
| `Name256Byte::operator=(const Name256Byte&)` FUN_004036a0 | copy 256 bytes | `m_UserID` from a token or DB answer (L00 §4, §5) |
| `Name4::operator=(const char*)` FUN_004033d0 | 16 bytes = 0, `strncpy(…, 16)` | password fields (L00 §5.1) |
| `Name5::operator=(const Name5&)` FUN_00403400 | copy 20 bytes | `m_UserSwpawnApps` (§2.2) |
| `PROTO_NC_USER_GER_PASSWORD_CHECK_ACK::operator=` FUN_00403ac0 | copy `clienthandle`, `id` (256), `password` (16), `usrregnum`, `authid`, `block`, `loginable` | AccountDB 0x0C3A `NC_USER_GER_PASSWORD_CHECK_ACK` FUN_00404990 (L00 §5.1) |
| `PROTO_NC_USER_US_PASSWORD_CHECK_ACK::operator=` FUN_00403ed0 | copy `clienthandle`, `nError`, `nUserNo`, `sUserName[260]`, `sPassword[36]`, `sUserIP[20]`, `nAuthID`, `nBlock`, `bLoginAble`, `spawnapps` (20) | AccountDB 0x0C5C FUN_00404590 (L00 §5.1) |
| `PROTO_NC_LOG_USER_LOGINFAIL_SEND::PROTO_NC_LOG_USER_LOGINFAIL_SEND` FUN_00404020 | user id (`Name256Byte`) and the 16-byte password = 0 | the 0x0720 login-failure log of AccountDB 0x0C27 `fc_NC_USER_TEENAGER_ACK` FUN_00404050 (L00 §5.1) |
| `PROTO_NC_DATA_SEND1<PROTO_NC_USER_GER_IS_IP_BLOCK_REQ>` ctor FUN_00404960 | the `Name256Byte` at +5 and the 16 bytes at +0x105 = 0 | 0x0C3B `NC_USER_GER_IS_IP_BLOCK_REQ` to AccountLogDB, sent by FUN_00404990 (L00 §5.1) |
| `std::basic_string<char>::~basic_string` FUN_00403280 | free a heap buffer (capacity > 15), reset to the empty small string | `MakeOTP` (§4.3), log helpers |
| `std::bad_alloc::~bad_alloc` FUN_0040b1c0 / scalar deleting dtor FUN_0040b1d0 | CRT exception class | `operator new` failures |

### 4.6 Library copies in Login (pointer table)

These Login addresses are the same library functions that W05 / S02 document for the WM; they carry no
Login-specific behaviour.

| Login | Function | Documented at |
|---|---|---|
| FUN_004100c0 / FUN_00410180 | `GetCurrentTimeString` / `GetCurrentTimeString2` (time text for logs and dump file names) | W05 §6.3 (`GetCurrentTimeString2`), Z09 §30.1 |
| FUN_00410260, FUN_00410470, FUN_00410490, FUN_004104b0 | `_DebugMessageNew2`, `_DEBUGMSG`, `_DEBUGMSGVC`, `_DebugMessageNew` (the `Msg_<date>.txt` log) | W05 §3.1 / §6.4 (FUN_00460130, FUN_00460340, FUN_00460360), S02 §2.5 (FUN_00460ac0) |
| FUN_00410510 / FUN_00410530 | `CServerInfo::ViewErrorMsg` / `GetMyServerInfo` (`MY_SERVER` row → `m_MyServer`) | S02 §2.5, W05 §6.4 (FUN_00465cd0) |
| FUN_004120e0 / FUN_00412160 | `AssertClass::ac_DateTime` / `ac_AssertFail(msg, x)` (called by `pft_Store`, §4.1) | W05 §6.4 (FUN_00467270 / FUN_004672f0) |
| FUN_00412b50 | `cShineLogSystem::SLS_SetLogName`, called by the static initialisers of `gSocket_IOCP_Write` FUN_004275e0 and `gZoneLinktoErrorLog` FUN_00427640 | W05 §5.7 |
| FUN_00412e20, FUN_00412ea0, FUN_00412ed0, FUN_00413120, FUN_00413150, FUN_00413580, FUN_004139d0, FUN_00413a30, FUN_00413180 | `FillInStackFrame`, `CH_ReadProcessMemory`, `EHConvertSimpleException`, `EHInitSymbolEngine`, `EHCleanupSymbolEngine`, `GetFaultReason`, `GetFirstStackTraceString`, `GetNextStackTraceString`, `EHInternalGetStackTraceString` (fault text and stack walk of `MinidumpCallStack`, §1.8) | W05 §6.3 (FUN_00468010, FUN_00468090, FUN_004680c0; the others by name) |

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| L01-B1 | WM 0x0802 FUN_00408170 / `SetWMSession` FUN_0040a240 / WM `InactiveSession` FUN_0040a2b0 | `m_ppWSMappingTable[server_from_world_num]` written and read without a bound; the table has `nMaxAccept` (50) entries, the world byte goes to 255; the key is `to + from`, not a secret | any peer reaching the WM port can write a session pointer past the array (heap corruption) or take over a world's WM slot | size the table by world number (256) or reject worlds not in the world list |
| L01-B2 | 0x0C0B FUN_00406970 / `GetClientValidation` FUN_0040a200 | `m_pWMClientValidationTable` has `GetNumOfWorld()` entries but is indexed by world number | with non-contiguous world numbers (e.g. one world numbered 1) a world select writes 2 bytes past the array; the shipped config (world 0) is safe | index by the world's position in the list |
| L01-B3 | `::OnStop_Service` FUN_004033c0 / `MainThread` FUN_004030e0 | `m_bOnStopService` is never set to 1 (the WM's `::OnStop_Service` sets it) | a service STOP ends in `exit(0)` on the main thread ("<SERVER SELF STOPPED>"), racing the service STOP callback | set `m_bOnStopService = 1` before stopping, as the WM does |
| L01-B4 | `SetWorldManagerConnectInfo` FUN_0040a0c0 | `nWMSUS_1` (default 3 %) is never compared | the OPTool value has no effect; the six thresholds give only five bands below "full" | unclear: a sixth band for an almost empty world, or a spare field |
| L01-B5 | OPTool 0x2814 FUN_00407d50 (and 0x2812 FUN_00407c90) | no frame-length check; values not checked | a short frame stores stale receive-buffer bytes as thresholds | check `len` = 2 + 13 |
| L01-B6 | `WinService::startDispatcher` FUN_00411910 | assigns its `String` parameter to itself instead of to `serviceName` | `RegisterServiceCtrlHandlerA("")`; works only because an own-process service ignores the name (same as W05-B23) | `this->serviceName = name` |
| L01-B7 | `WinService::onServiceStop` FUN_00411560 | closes the event handle only when it equals `INVALID_HANDLE_VALUE` | the event handle leaks (once per process; same as W05-B24) | `!=` |
| L01-B8 | `WinService::removeService` FUN_004114b0 | returns true whatever `OpenServiceA` / `DeleteService` return | "REMOVE" reports "<SERVICE REMOVE OK>" for a missing service or a failed delete (same as W05-B22) | return the `DeleteService` result |
| L01-B9 | `COTPLogin::DelByDueTime` FUN_0040a710 / `DelByIP` FUN_0040a7a0 | after deleting the head node the walk continues from the new head's successor | the node after a deleted head is never tested: an expired one-time token can still be found by the 0x0C37 that just swept, and a failed 0x0C37 leaves one token of that IP | step to the new head without advancing |
| L01-B10 | OPTool 0x2818 FUN_00407df0 | `NC_OPTOOL_LOGON_PROCESS_TIME_VIEW_ACK` is sent with all six counters 0 | the OPTool shows no logon statistics | count connects / logins / IP-block checks and their times |
| L01-B11 | client `ProcHeartBeat` (S02 §4.3) / `CParserClient::Parser` FUN_00406680 | Login sends 0x0804 to every client silent for 30 s, also before its login request (`m_SessionMode` 0 / 1), where the parser rejects 0x0805 / 0x0804 as "Invalid sequence protocol" | a client idle 30 s on the login screen is closed at once if it answers the heartbeat, else 180 s later | accept 0x0804 / 0x0805 in every session mode (or skip heartbeats before login) |

## 5. Not reconstructed / uncertain

- L01-B3: the service shell is now traced (§1.8); what the service manager does when the process ends while
  `STOP_PENDING` (event log entry, recovery actions) is Windows behaviour, not in the binary *(inferred)*.
- The two banner lines `LoginServer::Start` FUN_00402f30 logs after "Launching the server....." are `_DebugMessageNew`
  calls whose string arguments the export drops; not recovered (cosmetic).
- FUN_0040bbac and the `Catch_All` funclets 0x40bb83 / 0x40bc0b (§4.3) are assigned to `basic_string::_Copy`
  FUN_0040bad0 by the sweep's call edge and their bodies only.
- `CParserOPTool::CheckConnectionValidation` FUN_00406f70 / `CParserWorldManager::…` FUN_00408020: the export types
  the session as a one-field struct, so the IP / port arguments of the log line show as `_padding_`; read as the same
  `+0x30` / `+0x2e` reads as the other three copies *(inferred)*.
- The client window check behind `WorldSelectWin::UpdateServerList` (vtable +0x104) is read as "is shown" from its
  use only.
- Whether the client answers Login's 0x0804 on the login screen (L01-B11, §2.6): client `Net` heartbeat flag
  net+0x10048 is set by FUN_006d2da0, which has no direct caller in the client export (called through a pointer
  *(inferred)*); C01's table says the client replies "if heartbeats are enabled". Either way the pre-login client is
  closed (at once or after 180 s); only the timing is open.
- The images of the five world-list status icons (§3) are not resolved; the low / medium / high reading is inferred.

## 6. Coverage boundary

Sweep (part 2): every function of `re-data/exports/login-pdb/decomp.c` between 0x401000 and 0x413000 (Login's own
code and the library linked into it; above are the CRT and unwind funclets) was checked against the `FUN_…` citations
of `login-server.md`, this file, `S02-library.md` and `knowledge/S02.md`; all callers and callees of the functions
documented here and of `LoginServer::LoginServer` / `~LoginServer` / `MainThread` were listed too. Everything found
is cited above, except:

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| The L00 handlers themselves (0x0C0B, 0x0C37, 0x0C35, the password-check and IP-block answers, OPTool 0x2801 … 0x2817), `ReadDefineScriptor` FUN_00401380, `ReadGlobalGameData` FUN_00401680, `ConnectAccountLogServer` FUN_00401ac0 | L00 (done) `login-server.md` §2, §4, §5 | documented there; this file only adds the corrections in `knowledge/L01.md` and the bodies L00 left out (0x0C06 / 0x0C18 / 0x2812 / 0x2814 / 0x2818, the token list) |
| The network library under the sessions (`CSocket_IOCP`, `CIOCP`, `CPacket`, `CSocket_Acceptor`, `CIOBuffer`, `CCsl`, `CGdp`), `LoginServer::LoginServer` FUN_004029e0, `OnStart_Service` FUN_004032b0, `Start_Acceptor`, `ProcessStop`, `DissconnectAllSessions`, `ProcHeartBeat`, the base-session constructor, `CIOCP_Process_LSession::IOCP_Process` / `IOCP_CloseProcess` | S02 (done) §1–§3, §1.6, §4.3 | library and glue documented there with the Login addresses |
| `std::string` / `String` helpers (`String::String` FUN_00411ab0 / FUN_00411b40, `~String` FUN_004119d0, `getBuffer` FUN_004119f0, `makeUpper` FUN_00411a00, `operator=` FUN_00411a10 / FUN_00411b70), `__tmainCRTStartup` FUN_004155c0 (calls `WinMain`), `rand` FUN_00415181 (world-select key, L00), `operator new` FUN_00414bb5 and `std::exception::exception` FUN_00415aef (its bad_alloc path, under `COTPLogin::Add`), `_eh_vector_*` iterators, unwind funclets (`__unwindfunclet$…LoginServer…`, `…CParser…`, `…SessionManager…`), the CRT (`sprintf`, `memset`, `rand` / `srand`, `_time32`, `exit`, `_chdir`, `operator new` / `delete`, `_mbsnbcpy`, `_mbstok`, `strncpy`) | none needed | compiler / CRT boilerplate with standard semantics; nothing server-specific (S02 §7 bounds the same set) |

The client world list (`WorldSelectWin::UpdateServerList` FUN_00473b80), which the done items C01 / L00 do not
document, is covered in §3. No follow-up item was needed.
