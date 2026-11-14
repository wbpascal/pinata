# Shared server library: network, config scripts, packed files (S02)

Login (`3LoginServer2.exe`), WorldManager (`4WorldManagerServer2.exe`) and Zone (`5ZoneServer2.exe`) link one network and
config library. This document reconstructs it from the **WM build** (`re-data/exports/wm-pdb`, names and layouts from the
NA2016 `WorldManager.pdb` *(pdb2016)*; addresses are the 2016 exe's) and maps the Login and Zone copies onto it (§1.9).
Read the code with `python3 -I tools/protocol-re/clean.py re-data/exports/wm-pdb - <addr> …` (Login: `login-pdb`, Zone:
`zone-pdb`). GameLog (no PDB) links an older variant of the same session framework; D05 §7.2 documents it.

Evidence markers as in `AGENTS.md`. Winsock imports are by ordinal: 1 `accept`, 2 `bind`, 3 `closesocket`, 4 `connect`,
5 `getpeername`, 6 `getsockname`, 7 `getsockopt`, 9 `htons`, 10 `ioctlsocket`, 11 `inet_addr`, 12 `inet_ntoa`,
13 `listen`, 15 `ntohs`, 18 `select`, 21 `setsockopt`, 22 `shutdown`, 23 `socket`, 111 `WSAGetLastError`,
116 `WSACleanup`.

What the servers do on top of the library (start order, which ports, the accept and packet pumps, heartbeats, close
triggers) is documented per server: WM in W05 §1.1–§1.6 / §4.5, Login in `login-server.md` §2–§3, Zone in Z10 §6.5 and
Z01 §1. This document is the layer below.

## 1. Network library

### 1.1 Object model

```
CIOCP                  one completion port + N worker threads                         §1.3
CSocket_Acceptor       one accept thread polling up to 10 listen sockets, ring of accepted sockets   §1.4
CSocket_IOCP           one connected socket: overlapped read / write / close, send queue of CIOBuffers  §1.5
CIOBuffer              0x2010-byte send buffer (0x2000 data), pooled                                §1.2
CPacket                0x2000-byte receive buffer of a session + frame parser                       §1.7
CSendPacket            0x2004-byte frame builder for one outgoing packet (Login, WM)                §1.8
CIOCP_Process(_Interfece)  callback indirection: an OVERLAPPED names a CIOCP_Process whose m_pProcess
                       points at an interface object; vtable slot 0 = IOCP_Process(ov, bytes),
                       slot 1 = IOCP_CloseProcess(ov) (error completion); the defaults return 1 / do nothing
                       (CIOCP_Process_Interfece::IOCP_Process FUN_00467790 returns 1)
<server>BaseSession    the server's session class: owns a CSocket_IOCP and a CPacket and installs its own
                       interface object in the three CIOCP_Process slots of the socket                §1.6
```

Layouts *(pdb2016, `WorldManager.pdb`; identical in `Login.pdb` / `Zone.pdb`)*:

| Class (size) | + | Member |
|---|---|---|
| `CIOCP` (0x30) | 0x00 / 0x04 / 0x08 / 0x0c | `m_HandleIOCP`, `m_NumOfWorkThread`, `m_ActiveWorker` (flag), `m_pWorkThreads` (`WORKER[n]`) |
| | 0x10 | `m_Overlapped_Stop` (`IOCP_OVERLAPPED`, Type = STOP) |
| `CIOCP::WORKER` (0x14) | 0x00 … 0x10 | `WorkerID`, `WorkerStatus` (`STATUS`: 0 NONE, 1 STARTING, 2 ACTIVE, 3 STOPPING, 4 STOPPED), `hThread`, `ThreadID`, `pIOCP` |
| `CIOCP::IOCP_OVERLAPPED` (0x20) | 0x00 | Win32 `OVERLAPPED` (0x14) |
| | 0x14 / 0x18 / 0x1c | `Type` (`IOCP_WORK_TYPE`: 0 READ, 1 WRITE, 2 CLOSE, 3 STOP), `pIOCP_Process`, `pData` (the owning session) |
| `CSocket_IOCP` (0xb4) | 0x00 / 0x04 | `m_Socket` (−1 = none), `m_SocketAddr` (peer, `sockaddr_in`) |
| | 0x14 | `m_IOCP_Process_Socket` (unused interface object) |
| | 0x18 / 0x20 / 0x28 | `m_Write_IOCP_Process`, `m_Read_IOCP_Process`, `m_Close_IOCP_Process` (`CIOCP_Process`, 8 bytes each) |
| | 0x30 / 0x50 / 0x70 | `m_Overlapped_Write` (Type 1), `m_Overlapped_Read` (Type 0), `m_Overlapped_Close` (Type 2) |
| | 0x90 | `m_Write_CS` (CRITICAL_SECTION, guards the send queue) |
| | 0xa8 / 0xac / 0xb0 | `m_nPendingWrite` (bytes queued), `m_pFirstBuf` (buffer being written), `m_pLastBuf` |
| `CIOBuffer` (0x2010) | 0x00 / 0x04 / 0x2004 / 0x2008 / 0x200c | vftable, `m_buffer[0x2000]`, `m_dwSize`, `m_nRef` (set 1, never read), `m_pNext` |
| `IOBufferContainer` (0x808) | 0x000 / 0x800 / 0x804 | `iobc_PointerList[512]`, `iobc_Pointer` (next unused), `iobc_Lock` (`CIOSpinLock`) |
| `CPacket` (0x18) | 0x00 / 0x04 / 0x08 | vftable, `m_pPacketBuffer`, `m_MaxPacketSize` (0x2000 = `PACKETBUFFERSIZE`) |
| | 0x0c / 0x10 / 0x14 | `m_pPacketHeader` (next unread frame), `m_ReadPosition` (only set by the builder `ID`), `m_WritePosition` (bytes received) |
| `CSendPacket` (0x2004) | 0x00 / 0x03 / 0x05 / 0x2000 | `Size` (3-byte union), `ID` (opcode), `Data[0x1ffb]` (`PACKETBUFFERSIZE` 8187), `m_DataSize` |
| `CSocket_Acceptor` (0x928c) | 0x0000 / 0x0004 | `m_ListenSocket` (never used: always −1), `m_ListenSocketAddr` |
| | 0x0014 | `m_ListenArray[10]` (`LISTEN_SOCKET`, 0x64 each) |
| | 0x03fc / 0x0400 | `m_NumOfListen`, `m_ListenBF_CS` |
| | 0x0418 | `m_AcceptedRing[1300]` (`ACCEPTED_SOCKET_INFO`, 0x1c each) |
| | 0x9248 / 0x924c / 0x9250 / 0x9254 | `m_NumOfAccepted`, `m_Accepted_Input`, `m_Accepted_Output`, `m_AcceptBF_CS` |
| | 0x926c / 0x9274 / 0x9278 | `m_Acceptor_Process` (unused), `m_bActiveAcceptThread`, `m_bAcceptThreadStop` |
| | 0x927c / 0x9284 / 0x9288 | `m_Listen_TimeOut` (`timeval`, 0 / 0 = poll), `m_hAcceptThread`, `m_AcceptThreadID` |
| `LISTEN_SOCKET` (0x64) | 0x00 / 0x04 / 0x08 | `Work` (`LISTEN_WORK`: 0 EMPTY, 1 ADD, 2 ADD_ERROR, 3 ACTIVE, 4 DEL), `Socket`, `SocketAddr` |
| | 0x18 / 0x58 / 0x5c / 0x60 | `IP[64]`, `PortNo`, `BacklogCount`, `UserData` (the server type of the peers: 5, 6, 8, 20 …) |
| `ACCEPTED_SOCKET_INFO` (0x1c) | 0x00 / 0x04 / 0x14 / 0x18 | `Socket`, `SocketAddr` (`sockaddr_in`), `UserData` (copied from the listen slot), `AcceptTime` (ms, never read) |

The session classes that embed them (offsets differ per server, §1.6):

| Session | `m_Status` | `m_LastReceiveTime` / `m_LastSendTime` | `m_SocketIOCP` | `m_Packet` | `m_IOCP_Process` | `m_LastHeartBeatSendTime` |
|---|---|---|---|---|---|---|
| WM `CWMBaseSession` (0x114) | +0x00 | +0x20 / +0x24 | +0x28 | +0xdc | +0x10c | +0x110 |
| Login `CLoginBaseSession` (0x108) | +0x00 | +0x20 / +0x24 | +0x28 | +0xdc | +0x100 | +0x104 |
| Zone `ZoneBaseSession` (0x100, has a vftable at +0) | +0x04 | +0x24 / +0x28 | +0x2c | +0xe0 | +0xf8 | +0xfc |

### 1.2 Send-buffer pool (`CIOBuffer`, `IOBufferContainer`, `CIOSpinLock`)

```pseudo
globals:
    IOBufferList[16]  : IOBufferContainer          # 16 × 512 pre-allocated buffers, built at static init
    g_slotBuffer[16]  : { CIOBuffer* m_pBuffer; CIOSpinLock m_lock }   # 16 free lists (LIFO)
    g_nAllocBuffer, g_nFreeBuffer : LONG           # round-robin counters
    CIOBuffer::s_nCount (buffers ever created), CIOBuffer::s_nAlloc (buffers in use): statistics, never read

static init of IOBufferList:                       @ FUN_004828a0 (`dynamic_initializer_for_'IOBufferList'`)
    for c in IOBufferList: IOBufferContainer::IOBufferContainer(c)       # vector ctor, 16 × 0x808

IOBufferContainer::IOBufferContainer(c):           @ FUN_00468d80
    c.iobc_Lock = 0; c.iobc_Pointer = 0
    for i in 0..511:
        c.iobc_PointerList[i] = new CIOBuffer (0x2010 bytes; s_nCount++)
        allocation failed → ShineExit("IOBufferContainer::IOBufferContainer")    # process ends (W05 §5.7)
    # 16 × 512 × 0x2010 = 67.2 MB committed at start, in every Login / WM / Zone process

CIOBuffer::Alloc():                                @ FUN_00468e10
    k = InterlockedIncrement(g_nAllocBuffer) & 0xF
    lock g_slotBuffer[k].m_lock (CAS 0→1, else CIOSpinLock::Wait)
    b = g_slotBuffer[k].m_pBuffer
    if b: g_slotBuffer[k].m_pBuffer = b.m_pNext                  # reuse a freed buffer
    else:
        unlock slot k; lock IOBufferList[k].iobc_Lock
        if IOBufferList[k].iobc_Pointer < 512: b = PointerList[iobc_Pointer++]    # next never-used buffer
        else: b = new CIOBuffer (s_nCount++)                     # heap; a null result is not checked: the
                                                                 # writes below fault (original bug) S02-B31
    unlock (the slot lock or the container lock)
    b.m_dwSize = 0; b.m_nRef = 1; b.m_pNext = null; s_nAlloc++
    return b

CIOBuffer::Free(b):                                @ FUN_00468f00
    s_nAlloc--
    k = InterlockedDecrement(g_nFreeBuffer) & 0xF                # a different counter: buffers migrate between lists
    lock g_slotBuffer[k].m_lock; b.m_pNext = slot.m_pBuffer; slot.m_pBuffer = b; unlock
    # buffers are never given back to the heap: the pool only grows

CIOSpinLock::Wait(lock):                           @ FUN_00468d10
    4000 × { CAS(lock, 1, 0) succeeded → return; pause }
    4000 × { SwitchToThread(); CAS succeeded → return }
    loop { Sleep(1000); CAS succeeded → return }               # a long-held lock costs whole seconds
```

`CIOBuffer`'s scalar deleting destructor FUN_00468de0 only resets the vftable (and frees when asked); nothing in the
library calls it.

### 1.3 `CIOCP`: completion port and worker threads

```pseudo
CIOCP::CIOCP(io):                                  @ FUN_00464350
    m_HandleIOCP = 0; m_NumOfWorkThread = 0; m_ActiveWorker = 0; m_pWorkThreads = null
    m_Overlapped_Stop = { OVERLAPPED 0, Type = STOP, pIOCP_Process = null, pData = null }

CIOCP::Start(io, n, bWait):                        @ FUN_004645c0
    if m_HandleIOCP == 0:
        m_HandleIOCP = CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0)   # concurrency 0 = number of CPUs
        failed → return 0
    Stop(io, −1)                                   # a second Start replaces the old workers
    m_pWorkThreads = new WORKER[n]; m_ActiveWorker = 1
    for i in 0..n−1:
        w = m_pWorkThreads[i]; w.pIOCP = io; w.WorkerID = i; w.WorkerStatus = STARTING
        w.hThread = CreateThread(WorkThread, &w, &w.ThreadID)      # failure not checked: the worker stays STARTING
                                                                   # and the wait below never ends (original bug) S02-B32
        Sleep(50)
    if bWait: for each worker: Sleep(50) while its status is STARTING
    m_NumOfWorkThread = n
    return n                                       # always n once the port exists
    # WM: n = 2 × CPUs (W05 §1.1); Zone: 2 × CPUs + 1, wait = 1 (Z10 §6.5); Login: login-server.md §2

CIOCP::WorkThread(w):                              @ FUN_004644f0
    port = w.pIOCP.m_HandleIOCP
    debug log "<IOCP WORKTHREAD #%d RUNNING>"; w.WorkerStatus = ACTIVE
    loop while w.WorkerStatus == ACTIVE:
        ok = GetQueuedCompletionStatus(port, &bytes, &key, &ov, 1000 ms)
        if !ok:
            err = GetLastError()
            if err ∉ {WAIT_TIMEOUT 0x102, ERROR_OPERATION_ABORTED 0x3e3} and ov and ov.pIOCP_Process:
                ov.pIOCP_Process.m_pProcess.IOCP_CloseProcess(ov)       # vtable slot 1: failed I/O (reset, …)
            continue                               # an aborted operation (socket closed by us) is dropped silently
        if ov.Type == STOP: break
        ov.pIOCP_Process.m_pProcess.IOCP_Process(ov, bytes)            # vtable slot 0; result ignored
    w.WorkerStatus = STOPPED; debug log "<IOCP WORKTHREAD #%d FREE>"
    # the completion key (= the socket, §1.6) is never used: everything comes from the OVERLAPPED

CIOCP::Register(io, handle, key):                  @ FUN_00464380
    if m_HandleIOCP == INVALID_HANDLE_VALUE: create the port; failed → return −1
        # dead: the handle is 0 or a real port, never −1. Before Start, the call below would create a
        # separate port per socket that no worker waits on (original bug) S02-B3
    return CreateIoCompletionPort(handle, m_HandleIOCP, key, 0)       # 0 = failure

CIOCP::Stop(io, which):                            @ FUN_004643c0
    if !m_pWorkThreads or !m_ActiveWorker: return
    range = which == −1 ? all workers : just worker `which`
    repeat:
        busy = false
        for w in range:
            STARTING / STOPPING: busy = true
            ACTIVE:  w.status = STOPPING; busy = true
                     PostQueuedCompletionStatus(port, 0, io, &m_Overlapped_Stop)   # one STOP per active worker
            STOPPED: CloseHandle(w.hThread); w.status = NONE
        if busy: continue                          # spins without sleeping until every worker in range stopped
        if any worker's status != NONE:
            which != −1: return                    # a single worker was stopped; the array stays
            Sleep(2); continue
        delete m_pWorkThreads; m_pWorkThreads = null; m_ActiveWorker = 0; return

CIOCP::Close(io):                                  @ FUN_004646b0   (Zone: CIOCP::~CIOCP FUN_006506e0, same body)
    Stop(io, −1); if m_HandleIOCP: CloseHandle(m_HandleIOCP); m_HandleIOCP = 0
```

The STOP overlapped is shared: a worker that dequeues it leaves; one post per ACTIVE worker. A worker blocked in a
callback (e.g. a long `CIOSpinLock::Wait`) delays `Stop` until it returns.

### 1.4 `CSocket_Acceptor`: listener thread and accepted ring

The acceptor owns one thread that polls up to 10 listen sockets with `select` and puts accepted sockets in a ring.
The main thread takes them out (`GetAccepted`) in its connect step (WM `ProcessConnect` W05 §1.4, Login
`ProcessConnect` login-server.md §2, Zone `zs_connect` Z09 §1.5). The ring is shared by all listen ports; each entry
carries the listen slot's `UserData` (the peer server type), which is how the main thread picks the session pool.

```pseudo
CSocket_Acceptor::CSocket_Acceptor(a):             @ FUN_00463960
    m_ListenSocket = −1; m_ListenSocketAddr = 0; thread flags 0; m_Listen_TimeOut = {0 s, 0 µs}
    m_NumOfListen = m_NumOfAccepted = m_Accepted_Input = m_Accepted_Output = 0
    InitializeCriticalSection(m_ListenBF_CS); InitializeCriticalSection(m_AcceptBF_CS)
    CSocket_Acceptor_Process::CSocket_Acceptor_Process(m_Acceptor_Process)           @ FUN_00468c30
        # default interface (vtable slot 0 = FUN_00467790, returns 1); the acceptor never calls it

CSocket_Acceptor::Listen_Start(a):                 @ FUN_004642a0
    if m_bActiveAcceptThread: return 1
    if !InetAddress::WinSockStart(2, 2): return 0
    every m_ListenArray[i].Work = EMPTY; m_bAcceptThreadStop = 0
    m_hAcceptThread = CreateThread(AcceptThreadRing, a); failed → return 0
    Sleep(5) until the thread set m_bActiveAcceptThread = 1; return 1

InetAddress::WinSockStart(major, minor):           @ FUN_00468c40
    WSAStartup(MAKEWORD(major, minor)) == 0 and the returned wVersion == requested → 1
    version differs → WSACleanup; 0.   failed → 0
    # called by every Listen_Start and every CSocket_IOCP::Connect; never balanced by WSACleanup (harmless)

CSocket_Acceptor::Listen_Add(a, ip, port, userData, backlog):     @ FUN_00463a50
    lock m_ListenBF_CS
    if m_NumOfListen < 10 and there is a slot with Work == EMPTY:
        m_NumOfListen++
        slot.IP = strcpy(ip)                       # no length check against IP[64]; ip comes from the config file
        slot.PortNo = port; slot.BacklogCount = backlog; slot.UserData = userData; slot.Work = ADD
        unlock
        Sleep(10) while slot.Work == ADD          # the accept thread opens the socket (below)
        if slot.Work == ADD_ERROR:
            log "*FAILED Listen_Add - IP = %s:%d"
            lock; slot.Work = EMPTY; m_NumOfListen--; unlock; return 0
        return 1
    unlock; log (an empty message); return 0
    # requires a running accept thread: called after Listen_Start, else it waits forever (inferred from the order:
    # WM W05 §1.1, Zone Z10 §6.5 call Listen_Start first)

CSocket_Acceptor::AcceptThreadRing(a):             @ FUN_00463ee0   (thread procedure)
    m_bActiveAcceptThread = 1
    if m_bAcceptThreadStop: m_bActiveAcceptThread = 0; return
    loop:
        accepted = false
        for each of the 10 slots, under m_ListenBF_CS (taken and released per slot):
            if accepted: skip                     # at most one accept per pass over the slots
            ADD:
                addr = { AF_INET, htons(PortNo), inet_addr(IP) }
                s = socket(AF_INET, SOCK_STREAM, 0)
                s valid:
                    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, 1)
                    ioctlsocket(s, FIONBIO, 1)                       # non-blocking listen socket
                    setsockopt(s, SOL_SOCKET, SO_SNDBUF, 0x8000)     # 32 KB, inherited by accepted sockets
                    bind(s, addr) ok and listen(s, BacklogCount) ok:
                        getsockname(s, &slot.SocketAddr, namelen = 4)   # length 4 < 16: always fails, the
                                                                          # address stays 0; never read (original bug) S02-B2
                        slot.Socket = s; slot.Work = ACTIVE; continue
                slot.Work = ADD_ERROR
                WSACleanup()                       # ordinal 116, where WSAGetLastError (111) fits; the socket s is
                                                   # not closed (original bug) S02-B1
            DEL:  closesocket(slot.Socket); slot.Work = EMPTY
            ACTIVE:
                if 1299 − m_NumOfAccepted < 1: continue              # ring full: leave connections in the backlog
                r = select({slot.Socket}, timeout m_Listen_TimeOut = 0)   # poll, no wait
                r == SOCKET_ERROR: log "ERROR - LISTEN SOCKET ACTIVE (%s) %s:%d ServerFromID=%d"
                                   (error text, IP, port, UserData); continue
                readable:
                    c = accept(slot.Socket, &peer)
                    c valid:
                        ioctlsocket(c, FIONBIO, 1)
                        getsockopt(c, SO_SNDBUF) (value unused); setsockopt(c, SO_SNDBUF, 0x8000); getsockopt again
                        if SetAccepted(a, c, peer, slot.UserData): accepted = true
                        else: shutdown(c, SD_BOTH); closesocket(c)   # refused: the peer sees a reset/close, no message
            EMPTY / ADD_ERROR: nothing
        if !accepted: Sleep(1)
        if m_bAcceptThreadStop: m_bActiveAcceptThread = 0; return

CSocket_Acceptor::SetAccepted(a, sock, peer, userData):           @ FUN_00463c40
    lock m_AcceptBF_CS
    if (m_Accepted_Input + 1) % 1300 == m_Accepted_Output: unlock; return 0        # ring full (1299 entries)
    for each queued entry (m_NumOfAccepted entries from m_Accepted_Output):
        if entry.SocketAddr.sin_addr == peer.sin_addr: unlock; return 0             # same IPv4 already waiting
    ring[m_Accepted_Input] = { sock, peer, userData, AcceptTime = CGTimer::GetTime() }
    m_NumOfAccepted++; m_Accepted_Input = (m_Accepted_Input + 1) % 1300
    unlock; return 1

CSocket_Acceptor::GetAccepted(a, &info, bRemove):                 @ FUN_00463bb0
    lock m_AcceptBF_CS
    ring empty (Input == Output) → unlock; return 0
    info = ring[m_Accepted_Output] (0x1c bytes)
    if bRemove: m_NumOfAccepted--; m_Accepted_Output = (m_Accepted_Output + 1) % 1300
    unlock; return 1
    # all three servers call it with bRemove = 1 in a loop until it returns 0

CSocket_Acceptor::Listen_Stop(a):                  @ FUN_00463e10   (WM, Login; not in the Zone)
    if !m_bActiveAcceptThread: return 1
    for each of the 10 slots:
        lock; EMPTY / ADD / ADD_ERROR → EMPTY; ACTIVE → DEL; unlock
        Sleep(10) until slot.Work == EMPTY         # the accept thread closes the listen socket
        m_NumOfListen--                            # for all 10 slots, used or not: ends at (listens − 10)
                                                   # (original bug) S02-B4, no effect (the process is stopping)
    m_bAcceptThreadStop = 1; Sleep(5) until m_bActiveAcceptThread == 0; return 1

CSocket_Acceptor::Stop(a):                         @ FUN_004639e0
    if m_ListenSocket != −1: shutdown(SD_SEND); closesocket → m_ListenSocket = −1      # never set: no-op
    if m_bActiveAcceptThread: m_bAcceptThreadStop = 1; Sleep(5) until the thread ended
    return 1
    # the listen sockets of the slots stay open (only Listen_Stop closes them)

CSocket_Acceptor::~CSocket_Acceptor(a):            @ FUN_00463de0
    Stop(a); DeleteCriticalSection × 2
```

**Per-IP admission rule.** `SetAccepted` refuses a connection while another connection from the same IPv4 address
sits in the ring, on any port. The ring is drained once per main-loop pass, so two connections from one address
that arrive within the same pass (players behind one NAT, or several zones started together on one host) lose all but
the first: the extra socket is closed at once without a packet; the peer has to reconnect *(inferred: the client
then shows a connection error; server links reconnect by their own retry, Z01 §3.3 / W05 §1.3)*. The code compares the whole address on
purpose (a flood guard, *inferred*); the port and the listen type are not compared.

Accepted sockets are non-blocking with a 32 KB send buffer; no receive buffer, keep-alive or `TCP_NODELAY` option is
set.

### 1.5 `CSocket_IOCP`: connect, receive, send queue, close

```pseudo
CSocket_IOCP::CSocket_IOCP(s):                     @ FUN_00466420
    m_Socket = −1; m_SocketAddr = 0
    three CIOCP_Process objects (FUN_004677a0: m_pProcess → the default interface)
    m_Overlapped_Write = { 0, WRITE, &m_Write_IOCP_Process, pData = s }
    m_Overlapped_Read  = { 0, READ,  &m_Read_IOCP_Process,  pData = s }
    m_Overlapped_Close = { 0, CLOSE, &m_Close_IOCP_Process, pData = s }
    m_nPendingWrite = 0; m_pFirstBuf = null; InitializeCriticalSection(m_Write_CS)
    # the session constructor then points all three m_pProcess at its own interface and pData at itself (§1.6)

CSocket_IOCP::~CSocket_IOCP(s):                    @ FUN_00466520
    Shutdown(s); Close(s); under m_Write_CS: FreeBuffer(s), m_nPendingWrite = 0, m_pFirstBuf = null
    DeleteCriticalSection; ~CIOCP_Process × 3 (FUN_00465f30: reset to the default vtable)

CSocket_IOCP::Connect(s, localIP, localPort, remoteIP, remotePort):   @ FUN_004665b0
    Shutdown(s); Close(s)
    if !InetAddress::WinSockStart(2, 2): return 0
    m_Socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); invalid → return 0
    bind(m_Socket, { inet_addr(localIP), htons(localPort) }) fails → Close(s); return 0
    connect(m_Socket, { inet_addr(remoteIP), htons(remotePort) })    # blocking connect, no timeout
        fails → WSAGetLastError (value dropped); Close(s); return 0
    getpeername(m_Socket, &m_SocketAddr); return 1
    # the socket stays in blocking mode (fine for overlapped I/O). The caller's thread waits for the TCP
    # handshake: against a host that does not answer, about 21 s (Windows default SYN retries, inferred). WM
    # ProcessConnect retries Login / GameLog / AccountLog links in state 0 on every main-loop pass (W05 §1.4), so a
    # silent host stalls the WM main loop (original bug) S02-B5

CSocket_IOCP::Receive(s, buf, n, &got):            @ FUN_00465f40
    if n == 0: log "ERROR - CSocket_IOCP::Receive, m_Socket(%d), dwNumBytes(%d), IP(%d.%d.%d.%d)"   # and goes on
    ok = ReadFile(m_Socket, buf, n, &read, &m_Overlapped_Read)
    !ok and GetLastError() ∉ {0, ERROR_IO_PENDING 0x3e5}:
        log "CSocket_IOCP::Read, ERROR=%d, m_Socket=%d, pBuffer=%p, dwNumBytes:%d, ReadBytes:%d"; return 0
    if got: got = read
    return 1
    # one read outstanding per socket; its completion arrives as READ (§1.6), also when ReadFile finished at once

CSocket_IOCP::Send(s, data, n):                    @ FUN_004666f0
    if n > 0x2000: log "WARNING - CSocket_IOCP::Send, OVERMAX SIZE,TYPE_1|TYPE_0, PacketSize=%d, Netcmd=%d,%d"
                   (TYPE_1 when data[0] == 0, a long frame); the data is still sent, in 0x2000-byte pieces
    while n > 0:
        chunk = min(n, 0x2000)
        b = CIOBuffer::Alloc(); copy chunk into b.m_buffer; b.m_dwSize = chunk
        lock m_Write_CS
        (dead checks: b.m_dwSize == 0 → "CSocket_IOCP::Write dwSize=%d"; > 0x2000 → "Send IOBuffer Full::dwSize=%d,
         BUFFER_SIZE=%d"; both free b, unlock, return 0)
        if m_Socket == −1: log "CSocket_IOCP::Write, INVALID m_Socket=%d"; Free(b); unlock; return 0
        m_nPendingWrite += chunk
        if m_pFirstBuf == null:                    # nothing in flight: write now
            m_pFirstBuf = m_pLastBuf = b
            ok = WriteFile(m_Socket, b.m_buffer, chunk, &w, &m_Overlapped_Write)
            !ok and GetLastError() != ERROR_IO_PENDING:
                err ∉ {WSAENOTSOCK 10038, WSAECONNRESET 10054, WSAECONNABORTED 10053, WSAESHUTDOWN 10058,
                       WSAEINVAL 10022, ERROR_NETNAME_DELETED 64}: log "CSocket_IOCP::Write %#x(%#x) err=%d"
                cShineLogSystem::SLS_AddLog(gSocket_IOCP_Write, …)   # daily "Socket_IOCP_Write" log, W05 §5.7; never written (W05-B20)
                FreeBuffer(s); unlock; return 0    # the queue is dropped; the socket is not closed here
        elif m_pFirstBuf == m_pLastBuf or m_pLastBuf.m_dwSize + chunk > 0x2000:
            m_pLastBuf.m_pNext = b; m_pLastBuf = b # new queue entry (the buffer in flight is never appended to)
        else:
            append chunk to m_pLastBuf (coalesce); Free(b)
        unlock
        data += chunk; n −= chunk
    return 1
    # no limit on the queue: a peer that stops reading makes the process allocate buffers without bound; they are
    # never returned to the heap (§1.2) (original bug) S02-B6. Several sends before the next completion go out as
    # one write of up to 0x2000 bytes.

CSocket_IOCP::WriteCallback(s, transferred):      @ FUN_00466240   (IOCP thread, WRITE completion, §1.6)
    lock m_Write_CS
    b = m_pFirstBuf
    b == null:
        log "m_pFirstBuf = NULL - WriteCallback, IP=%s:%d, SOCKET=%d, dwTransferred=%d, m_nPendingWrite=%d"
        FreeBuffer(s)
    transferred == b.m_dwSize:
        m_nPendingWrite −= transferred; m_pFirstBuf = b.m_pNext
        if m_pFirstBuf: WriteFile(next buffer, &m_Overlapped_Write)
            fails (not ERROR_IO_PENDING) → same error filter and log ("CSocket_IOCP::WriteCallback %#x(%#x) err=%d"),
            SLS_AddLog(gSocket_IOCP_Write), FreeBuffer(s)
        CIOBuffer::Free(b)
    else:                                          # partial write
        log "MISSMATCH - WriteCallback, dwTransferred=%d, FirstBFSize=%d, IP=%s:%d, SOCKET=%d, m_nPendingWrite=%d"
        FreeBuffer(s)                              # the unsent rest of b and every queued buffer are dropped, the
                                                   # socket stays open; later sends start a new write, so the
                                                   # peer's byte stream loses data mid-frame (original bug) S02-B7
    unlock

CSocket_IOCP::FreeBuffer(s):                       @ FUN_00466140   (caller holds m_Write_CS)
    while m_pFirstBuf: b = m_pFirstBuf; m_pFirstBuf = b.m_pNext; m_nPendingWrite −= b.m_dwSize; CIOBuffer::Free(b)

CSocket_IOCP::Shutdown(s):                         @ FUN_00466060
    if m_Socket != −1 and shutdown(m_Socket, SD_SEND) != 0:
        WSAGetLastError() == GetLastError() == WSAECONNRESET 10054 → return 1
        log "ERROR - CSocket_IOCP::Shutdown : ret(%d), GetLastError(%d), WsaError(%d)"; return 0
    return 1

CSocket_IOCP::Close(s):                            @ FUN_00466180
    r = 1
    if m_Socket != −1:
        closesocket(m_Socket) == 0 → m_Socket = −1
        else log "ERROR - CSocket_IOCP::Close : ret(%d), GetLastError(%d), WsaError(%d)"; r = 0 (m_Socket kept)
    under m_Write_CS: FreeBuffer(s); m_nPendingWrite = 0; m_pFirstBuf = null
    return r
    # closesocket cancels the outstanding read / write; their completions arrive as ERROR_OPERATION_ABORTED and
    # are dropped by WorkThread (§1.3). The queued data is discarded, not flushed: a reply sent just before Close
    # can be lost (SD_SEND was sent first by the session's Close, §1.6, but buffers still in the queue are freed).

CSocket_IOCP::CloseUseIOCP(s, iocp):               @ FUN_00466120
    PostQueuedCompletionStatus(iocp.m_HandleIOCP, 0, m_Socket, &m_Overlapped_Close)
    # a CLOSE completion: an IOCP thread marks the session closing (§1.6); the main thread then closes it
```

### 1.6 Session glue: callbacks, register, connect, receive

Each server's base session puts one interface object (`CIOCP_Process_LSession` in Login and WM,
`IOCPProcessSession` in the Zone) into the socket's three `CIOCP_Process` slots and sets every OVERLAPPED's `pData`
to the session (WM `CWMBaseSession::CWMBaseSession` FUN_00430020: also `m_Connected_Server_ID = 10`, state EMPTY,
`m_Connected_Time` = local time, both times = now, `m_LastHeartBeatSendTime = 0`). The IOCP threads only touch the
session through these callbacks; everything else (parsing, handlers, close) runs on the main thread.

```pseudo
CIOCP_Process_LSession::IOCP_Process(ov, bytes):  @ FUN_0042fe90   (WM; Login FUN_00409020)
    s = ov.pData
    READ:
        s.m_LastReceiveTime = CGTimer::GetTime()   # set by every read completion, also a zero-byte one
        bytes == 0: s.m_Status = 3; return 0       # peer closed the connection
        s.m_Packet.m_WritePosition += bytes
        free = m_MaxPacketSize − m_WritePosition   # re-read from memory after the add
        free ≥ 1: CSocket_IOCP::Receive(s.socket, m_pPacketBuffer + m_WritePosition, free)   # re-arm; failure ignored
        return 1                                   # buffer full: no read is armed; the main thread re-arms (§1.7)
    WRITE: s.m_LastSendTime = now; CSocket_IOCP::WriteCallback(s.socket, bytes); return 1
    CLOSE: s.m_Status = 3; return 0                # CloseUseIOCP
    other: WM logs "▶▶▶IOCP_Process::IOCP_WORK_TYPE UNKNOW[Type:%d]", s.m_Status = 3, return 0;
           Login returns 1 without a log

CIOCP_Process_LSession::IOCP_CloseProcess(ov):    @ FUN_0042ff60   (WM; Login FUN_004090b0)
    ov.pData.m_Status = 3                          # a failed read or write completion closes the session

IOCPProcessSession::IOCP_Process(ov, bytes):      @ FUN_005a6820   (Zone)
    if s.m_Status == 3: return 0                   # already closing: completions are ignored
    same as above with the Zone offsets (§1.1); an unknown type returns 1
IOCPProcessSession::IOCP_CloseProcess:            the default no-op (vtable slot 1 = a shared `ret 4`, 0x549070)
    # in the Zone a failed completion (connection reset while a read is pending, ERROR_NETNAME_DELETED …) does not
    # mark the session: no read is armed any more, and the session stays until the heartbeat check closes it:
    # ZoneBaseSession::CheckHeartBeat FUN_005a67c0 sends 0x0804 after 30 s without a read completion (fails at once on
    # a reset socket → closed, inferred) and gives up after another 180 s (original bug) S02-B8
```

**Read re-arm race.** The IOCP thread adds `bytes` to `m_WritePosition` and then re-reads it to compute the free
space. If the add filled the buffer, the main thread can compact it and arm a read (§1.7) between the two
instructions; the IOCP thread then sees free space again and arms a second `ReadFile` on the same OVERLAPPED
*(read in the disassembly at 0x42ff1c / 0x42ff22; the window is one instruction wide)* (original bug) S02-B9.

```pseudo
CWMBaseSession::Socket_Register_To_IOCP(s, iocp):  @ FUN_0042fd10   (Login FUN_00408e70, Zone FUN_005a6700)
    CIOCP::Register(iocp, s.socket, key = s.socket) == 0:
        log "ERROR - Socket_Register_To_IOCP Step #1, Socket=%d, %s" (Zone without the socket); return 0
    CSocket_IOCP::Receive(s.socket, m_Packet.m_pPacketBuffer, GetWriteableBufferSize()) fails:
        log "ERROR - Socket_Register_To_IOCP Step #2, Socket=%d, %s"; return 0
    return 1
    # the first read always targets the buffer start: the caller has reset m_Packet first (CPacket::Clear on the
    # pool take, W05 §4.3; CWMBaseSession::Connect below)

CWMBaseSession::Connect(s, localIP, localPort, remoteIP, remotePort, iocp):   @ FUN_0042ffb0  (Login FUN_004090d0, Zone FUN_005a68b0)
    CSocket_IOCP::Shutdown; CSocket_IOCP::Close; m_Packet.Clear() (vtable slot 0x2c)
    CSocket_IOCP::Connect(...) fails → 0
    iocp != null and !Socket_Register_To_IOCP(s, iocp) → 0
    return 1

CWMBaseSession::Receive(s):                        @ FUN_0042fcd0   (Login FUN_00408e30, Zone FUN_005a66c0)
    CSocket_IOCP::Receive(s.socket, m_Packet.GetWriteDataPtr(), m_Packet.GetWriteableBufferSize(), &dummy)
    # used by the pump to re-arm after a compaction (§1.7)

CWMBaseSession::Send(s, CSendPacket p):            @ FUN_0042fc50   = CSocket_IOCP::Send(GetSendPtr(p), GetSendSize(p))
CWMBaseSession::Send(s, data, n):                  @ FUN_0042fca0   = CSocket_IOCP::Send(data, n)    (raw frames)
CWMBaseSession::Close(s):                          @ FUN_0042fc30   = CSocket_IOCP::Shutdown; CSocket_IOCP::Close   (W05 §4.5)
```

### 1.7 `CPacket`: receive buffer and framing

A session's `CPacket` is one 0x2000-byte buffer: the IOCP thread appends at `m_WritePosition` (§1.6); the main thread
reads frames from `m_pPacketHeader`. The frame format is the client protocol's (`docs/protocol/README.md` §1.1):

```
short frame:  [size u8 ≠ 0]  [ID u16] [data]            frame length = size + 1          (CPacket::PACKET1)
long frame:   [0x00] [size2 u16] [ID u16] [data]        frame length = size2 + 3         (CPacket::PACKET2)
size / size2 = 2 + data length ("data size", what the handlers get as len)
```

Vtable *(read from the exe's RTTI vftable, the same order in all three servers)*: 0/1 destructor, **2** `IsValidHeader`,
**3 (0x0c)** `IsValidPacket`, **4 (0x10)** `GetPacketSize`, **5 (0x14)** `GetDataSize`, **6 (0x18)** `GetIDPtr`,
**7 (0x1c)** `GetDataPtr`, 8 (0x20) `GetPacket`, **9 (0x24)** `TakeNextPacket`, **10 (0x28)** `RemoveAllUsedPacket`,
**11 (0x2c)** `Clear`, 12 (0x30) `ID(op, len, data)` (builder), 13 (0x34) `ID()`. The `session.vtbl[…]` calls of the
WM pump (W05 §1.4) are these slots of the session's `m_Packet`: 0x0c status, 0x24 drop the handled frame, 0x28 compact,
0x18 / 0x10 opcode and size for the FATAL log.

```pseudo
CPacket::CPacket(p):                 @ FUN_00467ac0   m_pPacketBuffer = m_pPacketHeader = new char[0x2000]; m_MaxPacketSize = 0x2000;
                                                      read / write positions 0
CPacket::~CPacket(p):                @ FUN_004677b0   delete the buffer; buffer / size / header = 0
CPacket::Clear(p):                   @ FUN_004679d0   (re)allocate 0x2000 if none; header = buffer start; positions 0

CPacket::IsValidHeader(p):           @ FUN_004677e0
    avail = buffer + m_WritePosition − header
    avail ≤ 0: return 0
    header.size ≠ 0: return avail > 2 ? 1 : 0       # short header complete
    else:            return avail > 4 ? 2 : 0       # long header complete

CPacket::GetPacketSize(p, &err):     @ FUN_00467880   header ? (size ≠ 0 ? size + 1 : size2 + 3), err = 0 : err = −1, 0
CPacket::GetDataSize(p):             @ FUN_004678c0   size ≠ 0 ? size : size2
CPacket::GetIDPtr(p):                @ FUN_004678e0   &ID (header + 1 or header + 3)
CPacket::GetDataPtr(p):              @ FUN_004678f0   the same address as GetIDPtr: the handler's "packet" starts at the opcode
CPacket::ID(p) (read):               @ FUN_00467a10   *GetIDPtr

CPacket::IsValidPacket(p):           @ FUN_00467820   (slot 0x0c: the pump's status)
    if IsValidHeader() == 0: return 0                # need more bytes
    n = GetPacketSize(&err)
    if err ≥ 0 and 2 < n ≤ m_MaxPacketSize: return n ≤ avail ? 1 : 0       # 1 = a whole frame is buffered
    return 2                                         # bad frame → the session is closed (W05 §1.4)
    # short: size 1 → n = 2 → bad; size 2 → opcode only. Long: size2 0 or 1 gives n = 3 / 4, which passes although
    # the 5-byte long header does not fit: the frame is dispatched with len 0 / 1 and an opcode taken from the next
    # frame's first bytes; TakeNextPacket then steps 3 / 4 bytes, so the next frame is also handled normally
    # (original bug) S02-B10. A long frame with size2 ≤ 0xFF (where the sender would use the short form) is
    # accepted. The longest accepted frame is 0x2000 bytes (size2 ≤ 0x1FFD).

CPacket::GetPacket(p, &id, &data, &len):           @ FUN_00467900
    r = IsValidPacket(); r == 0 → 0; r ≠ 1 → 2
    id = ID(); data = GetDataPtr(); len = GetDataSize(); return 1          # no direct call; the pumps use slots 3/5/7

CPacket::TakeNextPacket(p):          @ FUN_00467960   n = GetPacketSize(&err); err ≥ 0 → header += n
CPacket::RemoveAllUsedPacket(p):     @ FUN_00467990   (slot 0x28: compact)
    if m_WritePosition < m_MaxPacketSize: return 0   # only a full buffer is compacted
    used = header − buffer; used == 0: return 0
    memmove(buffer, header, m_WritePosition − used); m_WritePosition −= used; header = buffer; return 1
```

**Pump contract** (WM `ProcessPacket` W05 §1.4, Login, Zone the same): `IsValidPacket` 1 → dispatch, `TakeNextPacket`;
0 → `RemoveAllUsedPacket`, and if it compacted, `Session::Receive` (re-arm); 2 → state 3. Because the IOCP thread
stops arming reads when the buffer is full and compaction only happens then, **the receive buffer is used as a
linear 8 KB window**: the session reads into it until it is full, then waits until the main thread has consumed the
complete frames and moved the incomplete tail to the front. While the main thread is behind (WM: one frame per
session per pass), TCP flow control throttles the peer. A frame longer than 0x2000 bytes can never be received
(IsValidPacket returns 2 for n > 0x2000).

Builder side (the receive class can also build one frame; no direct call in the three servers; whether a vtable call
through slot 0x30 reaches it was not traced):

```pseudo
CPacket::ID(p, op, len, data):       @ FUN_00467b00
    hdr = len + 2 < 0x100 ? 3 : 5; total = hdr + len
    buffer smaller than total → delete it; allocate total bytes if none (m_MaxPacketSize = total)
    m_WritePosition = hdr; if data: WriteData(data, len)
    short: ID = op; size = total − 1; m_ReadPosition = 3
    long:  ID(+3) = op; size = 0; size2 = total − 3; m_ReadPosition = 5
CPacket::WriteData(p, data, n):      @ FUN_00467a30
    m_WritePosition + n > m_MaxPacketSize → throw CPacket::InvalidPacketException
    copy at m_WritePosition; m_WritePosition += n; header.size += (u8)n      # the size is rewritten by ID afterwards
CPacket::GetWriteableBufferSize(p):  @ FUN_00467aa0   m_MaxPacketSize − m_WritePosition
CPacket::GetWriteDataPtr(p):         @ FUN_00467ab0   buffer + m_WritePosition
```

### 1.8 `CSendPacket`: frame builder (Login, WM)

```pseudo
CSendPacket layout: Size[3] | ID u16 @3 | Data[0x1FFB] @5 | m_DataSize u32 @0x2000
    short frame lives at +2: { size u8 @2, ID @3, Data @5 }      (PACKET_SIZE1 { u16 dummy; u8 size })
    long frame lives at +0:  { 0x00 @0, size2 u16 @1, ID @3, Data @5 }  (PACKET_SIZE2)

CSendPacket::CSendPacket(p):         @ FUN_0045fd30   size byte (+2) = 2; ID = 0; m_DataSize = 0     # an empty frame
CSendPacket::SetSize(p, n):          @ FUN_0045fd50
    n + 2 < 0x100: byte +2 = n + 2; u16 +0 = 0; m_DataSize = n; return 1
    n < 0x1FFC:    byte +0 = 0; u16 +1 = n + 2; m_DataSize = n; return 1
    else: log "ERROR - CSendPacket::SetSize=%d, Current/Old Dep=%d, Cmd=%d"; reset to the empty frame (size 2,
          m_DataSize 0, ID 0); return 0
CSendPacket::GetSendSize(p):         @ FUN_0045fe30   m_DataSize + 2 < 0x100 ? m_DataSize + 3 : m_DataSize + 5
CSendPacket::GetSendPtr(p):          @ FUN_0045fe50   short ? p + 2 : p
CSendPacket::ID(p, op, n, data):     @ FUN_0045fe70
    ID = op
    !SetSize(n): log "FATAL - ERROR, CSendPacket::ID, Dep=%d, Cmd=%d, nDataSize=%d, pData=%p"
                 # the frame is now {02, 00 00}: sending it puts opcode 0x0000 on the wire
    elif data and n: copy n bytes to Data
```

The longest payload is 0x1FFB bytes (frame 0x2000 = one `CIOBuffer`). The short form is used up to 0xFD payload bytes
(size byte ≤ 0xFF). Callers mostly fill `Data` directly and call `SetSize` / `ID(op, n, null)`; they must not write
past 0x1FFB bytes (S01-B2 is such an overflow). The Zone has no `CSendPacket`: it builds frames in
`ProtocolPacket::pp_SendPacket` FUN_004c89c0 (README §1.1, limit `< 0x1FFD`) and sends them through the same
`CSocket_IOCP::Send` FUN_0064fc00 (Z01 §3.1).

### 1.9 Login and Zone copies

The three servers carry the same library source. Each function below was compared with the WM body (normalised
decompilation, plus disassembly where the decompiler differed); every pair not listed under "Differences" is
identical.

| Function | WM | Login | Zone |
|---|---|---|---|
| `CIOBuffer::Alloc` / `Free` / dtor | FUN_00468e10 / FUN_00468f00 / FUN_00468de0 | FUN_00412a00 / FUN_00412af0 / FUN_004129d0 | FUN_00654cd0 / FUN_00654dc0 / FUN_00654ca0 |
| `IOBufferContainer` ctor, `CIOSpinLock::Wait` | FUN_00468d80, FUN_00468d10 | FUN_00412970, FUN_00412900 | FUN_00654c40, FUN_00654bd0 |
| `CIOCP` ctor / Register / Stop / WorkThread / Start | FUN_00464350 / FUN_00464380 / FUN_004643c0 / FUN_004644f0 / FUN_004645c0 | FUN_0040fc40 / FUN_0040fc70 / FUN_0040fcb0 / FUN_0040fde0 / FUN_0040feb0 | FUN_00650380 / FUN_006503b0 / FUN_006503f0 / FUN_00650520 / FUN_006505f0 |
| `CIOCP::Close` (Zone: `~CIOCP`) | FUN_004646b0 | FUN_0040ffa0 | FUN_006506e0 |
| `CIOCP_Process` ctor / dtor, default `IOCP_Process` | FUN_004677a0 / FUN_00465f30, FUN_00467790 | FUN_00412460 / FUN_00410860, FUN_00410a70 | FUN_0064f3e0 / FUN_0064f400, folded |
| `CSocket_Acceptor` ctor / Stop / Listen_Add / GetAccepted / SetAccepted / dtor | FUN_00463960 / FUN_004639e0 / FUN_00463a50 / FUN_00463bb0 / FUN_00463c40 / FUN_00463de0 | FUN_0040f250 / FUN_0040f2d0 / FUN_0040f340 / FUN_0040f4a0 / FUN_0040f530 / FUN_0040f6d0 | FUN_00652730 / FUN_006527b0 / FUN_00652820 / FUN_00652980 / FUN_00652a10 / FUN_00652bb0 |
| `CSocket_Acceptor` Listen_Stop / AcceptThreadRing / Listen_Start | FUN_00463e10 / FUN_00463ee0 / FUN_004642a0 | FUN_0040f700 / FUN_0040f7d0 / FUN_0040fb90 | – / FUN_00652be0 / FUN_00652fa0 |
| `CSocket_Acceptor_Process` ctor, `InetAddress::WinSockStart` | FUN_00468c30, FUN_00468c40 | FUN_00412880, FUN_00412890 | FUN_00654e20, FUN_00653840 |
| `CSocket_IOCP` ctor / dtor / Connect / Send / WriteCallback | FUN_00466420 / FUN_00466520 / FUN_004665b0 / FUN_004666f0 / FUN_00466240 | FUN_00410d60 / FUN_00410e60 / FUN_00410ef0 / FUN_00411030 / FUN_00410b80 | FUN_0064f930 / FUN_0064fa30 / FUN_0064fac0 / FUN_0064fc00 / FUN_0064f750 |
| `CSocket_IOCP` Receive / Shutdown / CloseUseIOCP / FreeBuffer / Close | FUN_00465f40 / FUN_00466060 / FUN_00466120 / FUN_00466140 / FUN_00466180 | FUN_00410870 / FUN_00410990 / FUN_00410a50 / FUN_00410a80 / FUN_00410ac0 | FUN_0064f410 / FUN_0064f530 / FUN_0064f5f0 / FUN_0064f620 / FUN_0064f690 |
| `CPacket` ctor / dtor / Clear / IsValidHeader / IsValidPacket / GetPacketSize | FUN_00467ac0 / FUN_004677b0 / FUN_004679d0 / FUN_004677e0 / FUN_00467820 / FUN_00467880 | FUN_00412780 / FUN_00412470 / FUN_00412690 / FUN_004124a0 / FUN_004124e0 / FUN_00412540 | FUN_00650290 / FUN_0064ff80 / FUN_006501a0 / FUN_0064ffb0 / FUN_0064fff0 / FUN_00650050 |
| `CPacket` GetDataSize / GetIDPtr / GetDataPtr / GetPacket / TakeNextPacket / RemoveAllUsedPacket | FUN_004678c0 / FUN_004678e0 / FUN_004678f0 / FUN_00467900 / FUN_00467960 / FUN_00467990 | FUN_00412580 / FUN_004125a0 / FUN_004125b0 / FUN_004125c0 / FUN_00412620 / FUN_00412650 | FUN_00650090 / FUN_006500b0 / FUN_006500c0 / FUN_006500d0 / FUN_00650130 / FUN_00650160 |
| `CPacket` ID() / ID(op,…) / WriteData / GetWriteableBufferSize / GetWriteDataPtr | FUN_00467a10 / FUN_00467b00 / FUN_00467a30 / FUN_00467aa0 / FUN_00467ab0 | FUN_004126d0 / FUN_004127c0 / FUN_004126f0 / FUN_00412760 / FUN_00412770 | FUN_006501e0 / FUN_006502d0 / FUN_00650200 / FUN_00650270 / FUN_00650280 |
| `CSendPacket` ctor / SetSize / GetSendSize / GetSendPtr / ID | FUN_0045fd30 / FUN_0045fd50 / FUN_0045fe30 / FUN_0045fe50 / FUN_0045fe70 | FUN_00412280 / FUN_004122a0 / FUN_00412380 / FUN_004123a0 / FUN_004123c0 | – |
| session `IOCP_Process` / `IOCP_CloseProcess` | FUN_0042fe90 / FUN_0042ff60 | FUN_00409020 / FUN_004090b0 | FUN_005a6820 / no-op |
| session Register / Connect / Receive / Close / Send | FUN_0042fd10 / FUN_0042ffb0 / FUN_0042fcd0 / FUN_0042fc30 / FUN_0042fc50, FUN_0042fca0 | FUN_00408e70 / FUN_004090d0 / FUN_00408e30 / FUN_00408dd0 / FUN_00408df0, FUN_00408e20 | FUN_005a6700 / FUN_005a68b0 / FUN_005a66c0 / FUN_005a6690 / FUN_005a66b0 |
| session ctor / dtor (`CWMBaseSession`, `CLoginBaseSession`, `ZoneBaseSession`) | FUN_00430020 / FUN_0042fbc0 | FUN_00409140 / FUN_00408d60 | FUN_005a6920 / FUN_005a6620 |

(Session ctor / dtor bodies: WM §1.6, Login §4.3 / §4.2, Zone §4.4.)

Differences:

- **Zone has no `CSendPacket` and no `Listen_Stop`**; its `CIOCP` is closed by the destructor `~CIOCP` FUN_006506e0
  (the WM / Login `Close` body).
- **Zone session callbacks** (§1.6): `IOCPProcessSession::IOCP_Process` FUN_005a6820 ignores completions of a session
  already in state 3 and does not override `IOCP_CloseProcess` (S02-B8). Its `Socket_Register_To_IOCP` FUN_005a6700
  logs without the socket number.
- Login `IOCP_Process` returns 1 for an unknown type without a log; WM logs it and closes.
- The decompiler shows the Zone `CIOCP::Stop`, `CPacket::ID(op,…)` and `~CPacket` without the final member resets;
  the disassembly has them (0x6504f0, 0x650304, 0x64ff99): same behaviour as the WM.
- `CToken` / `CCsl`: no code difference (the decompiler differences are artefacts), §2.7. `CGdp::CreateFileA`
  (Login / Zone decompile differently): §3.

Corrections to existing docs: `login-server.md` §3.1 sets `lastRecvTime` per dispatched packet; the code sets it on
every read completion (§1.6), so a peer trickling a partial frame keeps its heartbeat alive. W05 §1.4's
`session.vtbl[…]` slots are those of the session's `m_Packet` (§1.7).

### 1.10 Uncertain (part 1)

- S02-B9 (double read arm) is read from the instruction order; whether it ever fired is unknown.
- How long a blocking `connect` to a silent host takes (S02-B5) depends on the Windows TCP settings of the host
  (*inferred* ~21 s with defaults).
- After S02-B8 the zone session ends by its heartbeat (`ZoneBaseSession::CheckHeartBeat` FUN_005a67c0, read: 30 s →
  0x0804, 180 s more → fail; manager `ProcHeartBeat` FUN_005a6a40 then `CloseUseIOCP`). Whether the 0x0804 send already
  fails on the reset socket (closing it after 30 s) is *inferred*. Z01 owns the zone session lifecycle.

## 2. Config scripts: `CToken` and `CCsl`

Every server reads its `*ServerInfo.txt` (and the shared `9Data/ServerInfo/ServerInfo.txt` it includes) with the
`CCsl` script reader ("CSL", the class's own prefix), built on the `CToken` tokenizer. Names, layouts and enums are
*(pdb2016)* (`WorldManager.pdb`; the Login and Zone PDBs agree). Login and Zone link the same code (§2.7). The
Account, AccountLog, Character and GameLog binaries carry the same result-message strings ("FORMAT DEFINNING, EOF
Come." …), so they link the same reader *(inferred; not compared)*; D05 §1.1 documents GameLog's use of it.

### 2.1 Data structures and constant tables

```
CToken (0x294)                                   CCsl : CToken (0x4f8)
  +0x000 CGdp m_Gdp            (file layer, §3)    +0x294 CCsl* m_pParentCsl      (include: the including script)
  +0x15c int  m_bIsOpen                            +0x298 int   m_bInclude         (1 in an include reader)
  +0x160 HANDLE m_hFile                            +0x29c char  m_ScriptFN[260]    (name as passed to ReadScript)
  +0x164 u32  m_dwFileSize                         +0x3a0 HWND  m_hWnd, +0x3a4 m_UseMsgID (stored only, §2.3.1)
  +0x168 char* m_pFileBF       (whole file + NUL)  +0x3a8 int   m_bEnd             (#END seen)
  +0x16c char* m_pSaveTokenPos                     +0x3ac int   m_NumFormatErrors, +0x3b0 m_NumDataErrors
  +0x170 int  m_bOpenByMemory, +0x174 m_pOpenMemory +0x3b4 char* m_pDummyNull      ("" returned at EOF in a row)
  +0x178 char m_szSeprator[256] (strtok delimiters) +0x3b8 int   m_bRemarkBlock     (inside /* … */)
  +0x278 char* m_pResetStart, +0x27c m_bResetStart  +0x3bc char  m_CslSeprator[64] (delimiters, copied to CToken)
  +0x280 int  m_bIsStart       (next read = 1st)   +0x3fc char** m_CslRemarks      (7 keyword pointers)
  +0x284 char* m_pToken        (current token)     +0x400 / 0x440 / 0x480 char[64] m_CslRemarkLine / Start / End
  +0x288 char* m_pMyTokenStart (strtok position)   +0x4c0 m_pCslCmd, +0x4c4 m_pCslParameter, +0x4c8 m_pCslParameterSize
  +0x28c / 0x290 m_lplpTokenList, m_dwNumTokens    +0x4cc m_NumFormats, +0x4d0 m_pFormats, +0x4d4 m_pFormatLast,
                 (never used by the code read)            +0x4d8 m_ppFormatTable (index, built at the end)
                                                   +0x4dc m_NumDatas, +0x4e0 m_pDatas, +0x4e4 m_pDataLast, +0x4e8 m_ppDataTable
                                                   +0x4ec m_dwNumResultMsg, +0x4f0 m_pResultMsgs, +0x4f4 m_pResultMsgLast
CSL_FORMAT_LIST (0x4c) { char Format[64]; int NumParameter; CSL_PARAMETER* pParameter; next }
CSL_DATA_LIST   (0x10) { u32 dwID = format index; u32 dwSize; void* pData; next }
CSL_RESULT_MSG_LIST    { next; char Msg[] }       (one heap block, 4 + strlen + 1 bytes… allocated strlen + 9)
CSL_CHUNK_INFO  (8)    { CLS_CHUNK_ID dwID (0x11111111 FORMAT, 0x22222222 DATA); u32 dwSize }
CSL_FORMAT_WRITE       { chunk; char Format[64]; int NumParameter; CSL_PARAMETER pParameter[] }   (chunk.dwSize = 0x44 + 4n)
CSL_DATA_WRITE         { chunk; u32 dwID; u32 dwSize; u8 Data[dwSize] }                          (chunk.dwSize = 8 + dwSize)
```

Constant tables (identical bytes in WM `0x497b34 / 0x497ae8 / 0x497a98 / 0x497b5c`, Login `0x43075c / 0x430710 /
0x4306c0 / 0x430784`, Zone `0x873864 / 0x873818 / 0x8737c8 / 0x87388c`; the pointers are installed by `CCsl::Clear`):

| Table | Index = enum value | Entries |
|---|---|---|
| `pCslCmd` (`CSL_CMD`) | 0 … 9 | `#END`, `#DEFINE`, `#INCLUDE`, `#CLEAR`, `#CLEARFORMAT`, `#CLEARDATA`, `#READ`, `#WRITE`, `#WRITEFORMAT`, `#WRITEDATA` |
| `pCslParameter` (`CSL_PARAMETER`) | 0 … 18 | `<ID>` `[ID]` `<INTEGER>` `[INTEGER]` `<HEX>` `[HEX]` `<FLOAT>` `[FLOAT]` `<STRING>` `[STRING]` `<FILENAME>` `[FILENAME]` `<SHORTKEY>` `[SHORTKEY]` `<ARRAYSRT>` `[ARRAYSRT]` `<ARRAYEND>` `[ARRAYEND]` `#ENDDEFINE` (the enum calls 14/15 `ARRAYSTART`; the keyword is spelled `ARRAYSRT`) |
| `pCslParameterSize` | same | 4 ×8 (ID, INTEGER, HEX, FLOAT), **512** ×2 (STRING), **260** ×2 (FILENAME), 4 ×2 (SHORTKEY), 4 ×2 (ARRAYSRT), 0 ×2 (ARRAYEND), 0 (#ENDDEFINE) |
| `pCslRemarks` (`CSL_REMARK`, copied to the heap per reader) | 0 … 6 | → `m_CslRemarkLine`, → `m_CslRemarkStart`, → `m_CslRemarkEnd`, `#SEPRATOR`, `#REMARKLINE`, `#REMARKSTART`, `#REMARKEND` |

Defaults (`CCsl::Clear`): delimiters `", \t\r\n"` (comma, space, tab, CR, LF), line remark `;`, block remark `/*` … `*/`.
The bare `CToken` constructor sets `" \t\r\n"` (no comma); `ReadScript` replaces it with the CSL set.

A data row is one heap block: the columns packed in format order, each `pCslParameterSize[type]` bytes, **strings stored
inline** (a `<STRING>` column is a 512-byte char array, a `<FILENAME>` 260). A `SERVER_INFO` row is 512 + 4·4 + 512 +
3·4 = 1052 bytes; `CServerInfo` hands out pointers into it (W05 §5.2 "strings are stored as pointers" means the
`SERVER_INFO` struct members, not the row).

### 2.2 `CToken`: the tokenizer

```pseudo
CToken::CToken():                                                                  @ FUN_0045a080
    CGdp::CGdp(&m_Gdp)                                                             # §3
    m_bIsOpen = m_hFile = m_pFileBF = m_pSaveTokenPos = m_bOpenByMemory = m_bResetStart = 0
    m_bIsStart = 1; m_szSeprator = " \t\r\n"; m_pToken = m_lplpTokenList = m_dwNumTokens = 0
CToken::Close():  free(m_pFileBF); if m_bIsOpen: CGdp::CloseHandle(m_hFile); CGdp::GdpClose(); m_bOpenByMemory = 0   @ FUN_0045a0f0
CToken::~CToken(): the same body, then CGdp::~CGdp                                   @ FUN_0045a490
CToken::SetSeprator(s): strcpy(m_szSeprator, s)                                     @ FUN_0045a150

CToken::Open(name):                                                                @ FUN_0045a520
    Close()  (inlined)
    m_hFile = CGdp::CreateFileA(name, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)
    if m_hFile == INVALID_HANDLE_VALUE: return 0
    m_bIsOpen = 1                                    # the file stays open until Close (GoBegin re-reads it)
    m_dwFileSize = CGdp::GetFileSize(m_hFile)
    m_pFileBF = malloc(size + 1); m_pFileBF[size] = 0
    CGdp::ReadFile(m_hFile, m_pFileBF, size) ok → m_bOpenByMemory = 0; m_bIsStart = 1; return 1
    any failure → Close(); return 0
CToken::OpenFromMemory(text):                                                      @ FUN_0045a630
    Close(); m_dwFileSize = strlen(text); if 0: return 0
    m_pFileBF = malloc(len + 1) copy of text (NUL-terminated); m_pOpenMemory = text  # kept for GoBegin
    m_bIsStart = 1; m_bOpenByMemory = 1; return 1
CToken::GoBegin():                         # restore the pristine buffer (tokenising writes NULs into it)   @ FUN_0045a270
    by memory: m_pFileBF[size] = 0; memcpy(m_pFileBF, m_pOpenMemory, size); m_bIsStart = 1; return 1
    by file:   CGdp::SetFilePointer(m_hFile, 0, 0, FILE_BEGIN) and CGdp::ReadFile(whole file) → m_bIsStart = 1; return 1
               failure → Close(); return 0
    neither:   return 0

CToken::my_tcstok(start, delims):          # strtok over m_pMyTokenStart, MBCS-aware (_mbspbrk)   @ FUN_0045a170
    if start: m_pMyTokenStart = start
    p = m_pMyTokenStart; if p == null: return null
    q = _mbspbrk(p, delims); m_pMyTokenStart = q
    while q == p:                          # skip leading delimiters
        p = ++m_pMyTokenStart; q = _mbspbrk(p, delims); m_pMyTokenStart = q
    if m_pMyTokenStart: *m_pMyTokenStart++ = 0
    return p
    # unlike strtok, when only delimiters remain before the end it returns p = "" (empty token), not null;
    # the next call returns null; a script that ends in delimiters without #END therefore ends with one "" token,
    # which the main loop reports as "UNKNOWNED" and which fails the read (original bug) S02-B14
CToken::GetToken():                                                                @ FUN_0045a1f0
    if m_pFileBF == null: return null
    if m_bIsStart: m_bIsStart = m_bResetStart = 0; m_pToken = my_tcstok(m_pFileBF, m_szSeprator)
    elif m_bResetStart: m_bResetStart = 0; m_pToken = my_tcstok(m_pResetStart, m_szSeprator)   # after an empty ""
    else: m_pToken = my_tcstok(null, m_szSeprator)
    return m_pToken
CToken::GoStartString():                   # find the next '"' after the current token             @ FUN_0045a380
    p = m_pToken + strlen(m_pToken) + 1    # first byte after the token's terminating NUL
    while *p != '"': p++                   # unbounded: crosses lines, NULs and the buffer end (original bug) S02-B13
    return p
CToken::GetTokenString(&len):              # read the next "quoted" string                        @ FUN_0045a6f0
    if m_pFileBF == null: return null
    if m_bIsStart: m_bIsStart = m_bResetStart = 0; m_pToken = my_tcstok(m_pFileBF, "\"")
    if m_bResetStart: m_pToken = m_pResetStart - 1; m_bResetStart = 0
    p = GoStartString(); m_pToken = p
    if p[0] == '"' and p[1] == '"':        # empty string: nothing to NUL-terminate
        m_pResetStart = p + 2; m_bResetStart = 1; m_pToken = &CToken::m_NULLstr (static ""); len = 0
        # the next GetToken resumes at p+2. The next GetTokenString instead sets m_pToken = p+1 (the closing
        # quote, not NUL-terminated), so GoStartString's strlen runs to the end of the buffer and the scan
        # continues past it: an empty string followed directly by another string column reads heap memory
        # (original bug) S02-B13
    else:
        m_pToken = my_tcstok(p, "\"")      # string = bytes between the quotes; closing quote → NUL
        len = strlen(m_pToken)
    return m_pToken                        # no escape sequences; a string cannot contain '"'
CToken::GoNextLine():                      # skip the rest of the line (line remark)              @ FUN_0045a330
    if m_pFileBF == null or m_pToken == null: return 0
    p = m_pToken + strlen(m_pToken) + 1
    if *p != '\n': m_pToken = my_tcstok(null, "\n")
    return 1
    # with CRLF files the token ends at the CR, *p is the LF, nothing is skipped and the next GetToken starts on the
    # next line. With LF-only files a remark token that ends at the line end (";" or ";----" alone on its line) was
    # terminated by the LF itself: *p is the first byte of the next line and that whole line is skipped as well
    # (original bug) S02-B16
CToken::SaveTokenPositon(): m_pSaveTokenPos = m_pToken                              @ FUN_0045a3d0
CToken::RestoreTokenPositon(pos):                                                  @ FUN_0045a3e0
    pos == null: pos = m_pSaveTokenPos; if null: return 0
    if !GoBegin(): return 0                # buffer reloaded: every NUL written so far is gone
    m_bIsStart = 0; m_pToken = my_tcstok(pos, m_szSeprator); return 1
CToken::IsTokenID(tok, list, n): first i < n with _mbsicmp(tok, list[i]) == 0, else 0xFFFFFFFF   @ FUN_0045a450
    # every keyword comparison of the reader is therefore case-insensitive and whole-token
```

### 2.3 `CCsl`: the script reader

#### 2.3.1 ReadScript: the main loop

```pseudo
CCsl::ReadScript(name, hWnd, msgId, memText):                                      @ FUN_004626f0
    m_hWnd = hWnd; m_UseMsgID = msgId                       # never read again by the library (servers pass 0, 0x401)
    ok = memText ? CToken::OpenFromMemory(memText) : CToken::Open(name)             # servers: always the file
    if !ok:
        GetLastError()
        AddResultMsg("-----…"); AddResultMsg((m_bInclude ? "INCLUDE OPEN ERROR(Code = %d) - %s "
                                                         : "FILE OPEN ERROR(Code = %d) - %s ") % (err, name))
        AddResultMsg("-----…"); m_NumFormatErrors++
        ReadScriptDone(); return 0
    top level: AddResultMsg("=====…" ×80); "FILE PROCESSING - %s " % name; "=====…"; " "
    include:   AddResultMsg("-----…" ×63); "Include - %s " % name; "-----…"
    if name: strcpy(m_ScriptFN, name)                       # unbounded into char[260]
    CToken::SetSeprator(m_CslSeprator)
    while !m_bEnd and (tok = GetToken()) != null:
        if ProcRemark(tok): continue                        # §2.3.2
        if ProcCmd(tok): continue                           # §2.3.3
        if ProcData(tok): continue                          # §2.3.5: tok names a #DEFINEd format
        AddResultMsg("%s - UNKNOWNED." % tok); m_NumDataErrors++
    ReadScriptDone(); CToken::Close()
    return (m_NumDataErrors + m_NumFormatErrors) < 1        # 1 only with no error at all, includes counted (§2.3.4)

CCsl::AddResultMsg(text): node = new[strlen + 9] { next = 0; Msg = text }; append; m_dwNumResultMsg++; return node != 0   @ FUN_00460a40
CCsl::ViewResultMsg(): for each message: _DebugMessageNew(1, "Msg", "%s", msg)       @ FUN_00460ac0
    # WM / Login only (the Zone linker dropped it); no caller. The servers print the list through
    # CServerInfo::ViewErrorMsg (§2.5) after a failed read.
```

#### 2.3.2 Remarks and the remark-control commands

```pseudo
CCsl::ProcRemark(tok) → 1 if consumed:                                             @ FUN_00460c90
    i = IsTokenID(tok, m_CslRemarks, 7)     # [0] line remark, [1] block start, [2] block end, [3..6] commands
    if m_bRemarkBlock and i != 2: return 1  # inside /* … */ every token is ignored, commands included
    switch i:
    0 (tok == line remark, whole token): GoNextLine(); return 1
    1 (/*): m_bRemarkBlock = 1;  2 (*/): m_bRemarkBlock = 0;  return 1
    3 #SEPRATOR:   t = GetToken(); m_CslSeprator = t ?? ", \t\r\n"; SetSeprator(m_CslSeprator); return 1
    4 #REMARKLINE:  t = GetToken(); m_CslRemarkLine  = t ?? ";"
    5 #REMARKSTART: t = GetToken(); m_CslRemarkStart = t ?? "/*"
    6 #REMARKEND:   t = GetToken(); m_CslRemarkEnd   = t ?? "*/";   return 1
                    # the new value is the next token under the *current* delimiters, so it cannot contain them;
                    # strcpy into the 64-byte members, unbounded (original bug) S02-B19
    default: if _mbsnbcmp(tok, m_CslRemarkLine, strlen(m_CslRemarkLine)) == 0: GoNextLine(); return 1
             return 0
```

So a line remark is any token that **starts with** `;` (`;comment`, `;-----`); block markers must be whole tokens
(`/*text` is not a block start). ProcRemark runs before every token the reader takes with `GetToken` (main loop, format
definitions, numeric columns), but not before string columns: `GetTokenString` scans straight to the next `"`, even
through a remark.

#### 2.3.3 Commands

```pseudo
CCsl::ProcCmd(tok) → 1 if tok is a command:                                        @ FUN_004621f0
    switch IsTokenID(tok, m_pCslCmd, 10):
    0 #END:          m_bEnd = 1                               # stops this file only (an include returns to its parent)
    1 #DEFINE:       f = MakeFormat(); if f: AddFormat(f)      # §2.3.4
    2 #INCLUDE:      IncludeFile()                            # §2.3.6
    3 #CLEAR:        ClearFormats(); ClearDatas()
    4 #CLEARFORMAT:  ClearFormats()                            # rows keep their format index into the new list
    5 #CLEARDATA:    ClearDatas()
    6 #READ "f":     Parameter_filename(f)                    # GetTokenString + strcpy into char[260]   @ FUN_00461210
                     Read(f) ? "%s - READ OK" : (m_NumDataErrors++, "%s - READ ERROR")      # §2.3.7
    7 #WRITE "f":    h = CGdp::CreateFileA(f, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, NORMAL)
                     ok = h valid and WriteFormat(0, h) and WriteData(0, h); CloseHandle(h) if valid
                     ok ? "%s - WRITE OK" : (m_NumDataErrors++, "%s - WRITE ERROR")
    8 #WRITEFORMAT "f": as WriteFormat, inlined ("%s - WRITE FORMAT OK" / "%s - WRITE FORMAT ERROR" + error)
    9 #WRITEDATA "f":   as WriteData, inlined ("%s - WRITE DATA OK" / "%s - WRITE DATA ERROR" + error)
    else: return 0
    return 1                                                  # also when MakeFormat failed (its error is counted)
```

`#READ` / `#WRITE*` turn a text script into the binary chunk file of §2.3.7 and back (a tool feature: no shipped
script uses them).

#### 2.3.4 `#DEFINE`: formats

```pseudo
CCsl::MakeFormat():                         # after "#DEFINE"                                       @ FUN_00460ea0
    name = none; params = []
    loop:
        tok = GetToken()
        if tok == null: m_NumFormatErrors++; AddResultMsg("FORMAT DEFINNING, EOF Come."); return null   # params leak
        if ProcRemark(tok): continue
        if name == none: name = strncpy(tok, 64); continue   # first token = format name, into a zeroed 65-byte local;
                                                             # strcpy'd later into Format[64]: a 64-char name puts its
                                                             # NUL in the next member NumParameter, written right after
                                                             # (harmless; part of S02-B19)
        k = IsTokenID(tok, m_pCslParameter, 19)
        if k <= 17: params.append(k); continue               # <ID> … [ARRAYEND]
        if k == 18 (#ENDDEFINE): return new CSL_FORMAT_LIST { Format = name, NumParameter = len(params), pParameter = params }
        # not a type keyword: the name of an earlier format inserts that format's columns ("inheritance")
        for i in 0 .. m_NumFormats-1:
            if _mbsicmp(tok, (m_pFormats + i * 0x4c)->Format) == 0:      # array stride over a linked list:
                params += (m_pFormats + i * 0x4c)->pParameter[0 .. NumParameter-1]; break
        # only i = 0 (the first format) is a real node; i ≥ 1 reads whatever heap follows it (original bug) S02-B12
        else: m_NumFormatErrors++; AddResultMsg("%s - FORMAT DEFINING, UNKNOWNED PARAMATER." % tok)   # token skipped
CCsl::AddFormat(f): append to m_pFormats / m_pFormatLast; m_NumFormats++                       @ FUN_00461150
```

A format's index (`CSL_DATA_LIST.dwID`) is its position in the list, counted across includes in reading order; the
same name may be defined twice (rows then match the first one, §2.3.5).

#### 2.3.5 Data rows

```pseudo
CCsl::ProcData(tok):                                                               @ FUN_00461490
    i = index of the first format whose Format equals tok (_mbsicmp); none → return 0
    row = MakeData(i, format); append to m_pDatas / m_pDataLast; m_NumDatas++; return 1
CCsl::MakeData(id, f):                                                             @ FUN_00461240
    size = Σ pCslParameterSize[f.pParameter[k]]  (loop unrolled ×2)
    row = new CSL_DATA_LIST { dwID = id, dwSize = size, pData = new[size] zeroed }
    w = pData
    for each column type t:
        ID / INTEGER (0..3):  *(i32*)w = atoi(GetDataToken()); w += 4
        HEX (4, 5):           sscanf(GetDataToken(), "%x", (u32*)w); w += 4      # "0x" prefix accepted by %x
        FLOAT (6, 7):         *(f32*)w = (float)atof(GetDataToken()); w += 4
        STRING (8, 9):        strcpy(w, GetTokenString()); w += 512              # no length check (original bug) S02-B19
        FILENAME (10, 11):    strcpy(w, GetTokenString()); w += 260
        SHORTKEY (12, 13):    *(i32*)w = (signed char) GetTokenString()[0]; w += 4   # first char of a "quoted" key
        ARRAYSRT / ARRAYEND (14..17): nothing read, w not advanced (jump-table entries 14–17 → loop end, 0x46141e)
            # the size sum and CCsl::GetData count 4 bytes for ARRAYSRT, so every column after it is written 4 bytes
            # lower than GetData reads it (original bug) S02-B11
    return row
    # the "[…]" optional variants behave exactly like "<…>": a value is always consumed, so a short row silently
    # takes its missing values from the next row (original bug) S02-B21. Values may span lines: rows end only by
    # column count.
CCsl::GetDataToken():                                                              @ FUN_00461190
    loop: tok = GetToken()
          null → m_NumFormatErrors++ (a data error counted as a format error (original bug) S02-B20);
                 AddResultMsg("DATA DEFINNING, EOF Come"); return m_pDummyNull ("")
          !ProcRemark(tok) → return tok
```

Accessors (W05 §5.2 has their pseudocode): `GetNumDatas` FUN_00460b40, `GetDataInfo` FUN_00460b50, `GetData(row, col)`
FUN_00460ba0 (null if row ≥ m_NumDatas, the row's format is missing or col ≥ NumParameter; else `pData + Σ size of
columns 0..col-1`; it uses the index tables when they exist, else walks the lists), `GetFormat(i)` FUN_00460af0.

#### 2.3.6 `#INCLUDE`

```pseudo
CCsl::IncludeFile():                       # after "#INCLUDE"                                       @ FUN_00462090
    file = GetTokenString()                # quoted; copied into a 260-byte local, unbounded
    saveDir = GetCurrentDirectoryA()
    _fullpath(full, m_ScriptFN); _splitpath(full, drive, dir, …); SetCurrentDirectoryA(drive + dir)
        # the include name is relative to the including file's directory (nested includes chain correctly)
    SaveTokenPositon()                     # m_pToken = the file name inside the buffer
    child = CCsl(this)                     # §2.3.8: shares this reader's lists, remark settings and delimiters
    child.ReadScript(file, m_hWnd, m_UseMsgID, 0)          # result ignored: errors reach this reader via ReadScriptDone
    RestoreTokenPositon(null)              # GoBegin re-reads this file from disk, then strtok from the saved
                                           # position: the next token is the rest of the file name up to a delimiter
        # a file name containing a delimiter (space, comma) leaves its tail as a token → "%s - UNKNOWNED." data error,
        # which fails the whole read (original bug) S02-B18
    SetCurrentDirectoryA(saveDir); child.Close(); child.~CToken()
CCsl::ReadScriptDone():                                                            @ FUN_00461520
    include (m_bInclude):
        AddResultMsg("Include Format %d Defined, %d Errors" % (m_NumFormats − parent.m_NumFormats, m_NumFormatErrors))
        AddResultMsg("Include Data %d Defined, %d Errors"   % (m_NumDatas − parent.m_NumDatas, m_NumDataErrors)); " "
        parent.m_NumFormatErrors += m_NumFormatErrors; parent.m_NumDataErrors += m_NumDataErrors
        parent.{m_NumFormats, m_pFormats, m_pFormatLast, m_NumDatas, m_pDatas, m_pDataLast,
                m_pResultMsgLast, m_dwNumResultMsg, m_pResultMsgs} = this's            # hand the grown lists back
    top level:
        AddResultMsg(" "); "TOTAL Format %d Defined, %d Errors"; "TOTAL Data %d Defined, %d Errors"; " "
        MakeFormatTable(); MakeDataTable()  # pointer arrays for O(1) GetFormat / GetDataInfo   @ FUN_00460940 / FUN_004609c0
```

The child's settings are copied once: a `#SEPRATOR` / `#REMARK*` inside an include changes only the include (and the
child shares the parent's `m_CslRemarks` pointer array, whose entries 0–2 point at the **parent's** marker strings, so
an include's `#REMARKLINE x` changes the prefix test of the default case but not the whole-token test of case 0).
`m_bRemarkBlock` is copied in but not back.

#### 2.3.7 Binary chunk files (`#READ` / `#WRITE`)

```pseudo
CCsl::Read(file):                                                                  @ FUN_00461730
    h = CGdp::CreateFileA(file, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, NORMAL); invalid → return 0
    total = GetFileSize(h); 0xFFFFFFFF → CloseHandle; return 0;  0 → return 1
    pos = 0
    repeat:
        ReadFile(h, &chunk, 8) else fail
        buf = new[chunk.dwSize + 8]; ReadFile(h, buf + 8, chunk.dwSize) else fail
        chunk.dwID 0x11111111: append CSL_FORMAT_LIST { Format = buf+8 (strcpy), NumParameter = *(buf+0x48),
                                                         pParameter = copy of NumParameter × 4 bytes at buf+0x4c }
        chunk.dwID 0x22222222: append CSL_DATA_LIST { dwID = *(buf+8), dwSize = *(buf+0xc), pData = copy of dwSize bytes at buf+0x10 }
        other id → fail
        delete buf; pos += 8 + chunk.dwSize
    until pos ≥ total
    return 1
    fail: CloseHandle(h); return 0          # buf leaks on the failure paths
    # the success paths (also total == 0) never close h (original bug) S02-B17. No size field is checked
    # against the chunk length.
CCsl::WriteFormat(file, h):  h == INVALID → open file (GENERIC_WRITE, CREATE_ALWAYS) and close it at the end;      @ FUN_00461970
    per format: { 0x11111111, 0x44 + 4n } + Format[64] + NumParameter + pParameter[n]; any WriteFile failure → 0
CCsl::WriteData(file, h):    same; per row: { 0x22222222, dwSize + 8 } + dwID + dwSize + pData[dwSize]               @ FUN_00461a90
```

Rows are written with their inline strings, so a chunk file is position-independent and `Read` restores it exactly.
`Read` appends: it does not clear the lists first.

#### 2.3.8 Construction, clearing, teardown

```pseudo
CCsl::CCsl():  CToken(); m_CslRemarks = 0; VarClear(); Clear()                    @ FUN_00461e40
CCsl::CCsl(parent):                                                                @ FUN_00461ea0
    CToken()
    parent != 0: m_bEnd, m_bRemarkBlock, m_CslSeprator, m_CslRemarkLine/Start/End, m_CslRemarks (pointer!),
                 m_pCslCmd / Parameter / ParameterSize, the format, data and result-message lists = parent's;
                 m_NumFormatErrors = m_NumDataErrors = 0; m_pParentCsl = parent; m_bInclude = 1
                 # m_pDummyNull is not set (Clear is not called): EOF inside a data row of an included file makes
                 # GetDataToken return an uninitialised stack pointer to atoi / atof (original bug) S02-B15
    parent == 0: builds a temporary CCsl on the stack (CToken, VarClear, Clear, Close, ~CToken) and leaves `this`
                 with only the CToken fields set (the C++ "constructor calls a constructor" mistake). Dead: the only
                 caller is IncludeFile with `this` (original bug) S02-B22
CCsl::VarClear(): m_bEnd = m_bRemarkBlock = error counts = 0; all list heads, counts, index tables = 0;   @ FUN_004608d0
                  m_pParentCsl = 0; m_bInclude = 0          # does not free anything
CCsl::Clear():  Close(); VarClear(); m_pDummyNull = ""; m_CslRemarks = new char*[7] copy of pCslRemarks;   @ FUN_00461d00
                defaults of §2.1; m_CslRemarks[0..2] = &m_CslRemarkLine / Start / End; table pointers
CCsl::Close():  CToken::Close(); if !m_bInclude: free result messages, ClearFormats(), ClearDatas(),        @ FUN_00461c80
                delete m_CslRemarks; m_CslRemarks = 0       # an include reader frees nothing (the parent owns it)
CCsl::ClearFormats(): free every format and its pParameter; m_NumFormats = 0; delete m_ppFormatTable   @ FUN_00461ba0
CCsl::ClearDatas():   free every row and its pData; m_NumDatas = 0; delete[] m_ppDataTable           @ FUN_00461c10
    # m_pFormatLast / m_pDataLast keep pointing at freed nodes; harmless because the append paths test the head first
CCsl::~CCsl(): Close(); ~CToken()                                                  @ FUN_00461de0
```

### 2.4 Grammar, checked against the shipped files

```
script     := { item } [ "#END" ] ; reading stops at #END or at the end of the buffer
item       := remark | command | row
remark     := token starting with ";"  → rest of the line ignored
            | "/*" { token } "*/"     → whole tokens, may span lines
            | "#SEPRATOR" tok | "#REMARKLINE" tok | "#REMARKSTART" tok | "#REMARKEND" tok
command    := "#DEFINE" NAME { type | NAME_OF_EARLIER_FORMAT } "#ENDDEFINE"
            | "#INCLUDE" STRING | "#READ" STRING | "#WRITE" STRING | "#WRITEFORMAT" STRING | "#WRITEDATA" STRING
            | "#CLEAR" | "#CLEARFORMAT" | "#CLEARDATA"
type       := "<ID>" | "<INTEGER>" | "<HEX>" | "<FLOAT>" | "<STRING>" | "<FILENAME>" | "<SHORTKEY>"
            | "<ARRAYSRT>" | "<ARRAYEND>"  and each in "[…]" form (identical behaviour)
row        := FORMAT_NAME value × (number of columns)          ; no terminator, may span lines
value      := token (numeric types: atoi / %x / atof)  |  STRING (string, filename, shortkey types)
STRING     := '"' { any byte except '"' } '"'                   ; no escapes; "" = empty
token      := maximal run of non-delimiters; delimiters ", \t\r\n" (comma = whitespace)
```

Keywords and format names are case-insensitive. Numeric columns accept anything `atoi`/`atof` accept (garbage → 0,
never an error). Only these produce errors (and fail `ReadScript`): an unknown token at item level, an unknown word in
a `#DEFINE`, EOF inside a `#DEFINE` or a row, a file or include that cannot be opened, `#READ` / `#WRITE*` I/O failures.

Checked with a byte-faithful Python emulation of §2.2–§2.3 (`tools/protocol-re/csl.py <file> [-v] [--lf] [--noend]`;
it follows includes like `IncludeFile` and flags the bug paths S02-B11…B21) on every shipped script of the 2016 set:

| File | Formats (index: name, columns) | Rows | Errors |
|---|---|---|---|
| `Login/LoginServerInfo.txt`, `w00_WorldManager/WMServerInfo.txt`, `w00_Zone00…03/ZoneServerInfo/ZoneServerInfo.txt`, `Account/DataServerInfo_Account.txt`, `AccountLog/DataServerInfo_AccountLog.txt`, `w00_Character/DataServerInfo_Character.txt`, `w00_GameLog/DataServerInfo_GameLog.txt` | 0 MY_SERVER (5: STRING name, STRING, INTEGER server id, INTEGER world, INTEGER zone), then the include's 1 NATION_NAME (1), 2 WORLD_NAME (3), 3 SERVER_INFO (9), 4 ODBC_INFO (5) | 1 + 29 | 0 |
| `9Data/ServerInfo/ServerInfo.txt` (alone) | NATION_NAME, WORLD_NAME, SERVER_INFO, ODBC_INFO | 1 + 1 + 22 + 5 | 0 |
| `9Data/Shine/DefaultCharacterData.txt` (Character server *(inferred)*) | CHARACTER (11), ITEM (3), SKILL (2), QUEST (2), MAXSHAPE (4), SHORTCUT (4) | 530 (6 / 17 / 476 / 0 / 6 / 25) | 0 |
| `9Data/Shine/TutorialCharacterData.txt` | TUTORIAL_CHARACTER (9), DEFAULT_ITEM (3), TUTORIAL_ITEM (3) | 10 | 0 |

So the format indices `CServerInfo` relies on (3 = SERVER_INFO, W05 §5.2; Z10's 0–4) come from the order
MY_SERVER-then-include in each per-process file. The shipped files use only `#DEFINE`, `#ENDDEFINE`, `#INCLUDE`,
`#END`, `<INTEGER>`, `<STRING>` and `;` remarks (inline after values too, e.g. `ITEM 26, 62930, 50 ; …`), all with CRLF
line ends; none uses block remarks, `#SEPRATOR`, optional or array types, inheritance, `#READ` or `#WRITE*`. The
`ODBC_INFO` connection strings contain `;` and `{…}` safely because strings are not tokenised.

Variants run through the emulation: removing the final `#END` makes every file fail (the trailing CRLF becomes one
empty token → `'' - UNKNOWNED.`, S02-B14); converting `DefaultCharacterData.txt` to LF line ends still "succeeds" but
loads 505 rows instead of 530 (S02-B16: the data line after each `;` / `;-----` line is lost).

### 2.5 Users of the reader

```pseudo
CServerInfo::CServerInfo(): CCsl::CCsl(&m_Csl)                                     @ FUN_00465c80
CServerInfo::ReadServerInfo(file): CCsl::Clear(&m_Csl); return CCsl::ReadScript(&m_Csl, file, 0, 0x401, 0)   @ FUN_00465c90
CServerInfo::ViewErrorMsg(): for each m_Csl result message: _DebugMessageNew(1, "Msg", "%s", msg)    @ FUN_00465cc0
    # = ViewResultMsg inlined; WorldManagerServer::ReadDefineScriptor (FUN_00403e70, W01 §2) calls it after a failed
    # read ("*FAILED SCRIPTOR READ* %s"), then CToken::Close on the reader (already closed by ReadScript; harmless)
GetShineServerIDName(id) / GetShineServerIDShortName(id): id outside 0..20 → 10; table lookup   @ FUN_0045a040 / FUN_0045a060
    names: 0 SERVER_ID_DB_ACCOUNT, 1 …_DB_ACCOUNTLOG, 2 …_DB_CHARACTER, 3 …_DB_GAMELOG, 4 …_LOGIN, 5 …_WORLDMANAGER,
           6 …_ZONE, 7 …_PATCH, 8 …_OPTOOL, 9 …_WEB, 10 …_UNKNOWN, 11–18 SERVER_ID_11 … SERVER_ID_18, 19 …_LAUNCHER,
           20 …_CLIENT (short names drop "SERVER_ID_" for the named ones); used only in log lines
```

The accessors over the rows (`GetMyServerInfo`, `GetServerInfo`, `GetServerIndex`, Zone `GetNationName` /
`GetWorldName`) are W05 §5.2 / §6.2 and Z10 §1.1. The two Login-only ones (used by
`CLoginWorldManagerSessionManager::InitWorldManagerInfo` FUN_00409eb0, X03 §2):

```pseudo
CServerInfo::GetNumOfWorld(): count of rows with dwID == 2 (WORLD_NAME, Login's format order)        @ FUN_00410750
CServerInfo::GetWorldName(world, out): first WORLD_NAME row whose column 0 == world →                @ FUN_00410790
    out = { nWorldNo = col 0, pWorldName = &col 1, pWorldDataPath = &col 2 }; return 1;  none → 0
```

Zone also uses the bare `CToken` for quest scripts (`CQuestParserScript` FUN_00636f60 …: `OpenFromMemory`, `GoBegin`,
`GetToken`, `GoNextLine`, `Save/RestoreTokenPositon`, and the zone-only):

```pseudo
CToken::GetTokenID(&id, list, n):          (Zone only)                            @ FUN_0063b2b0
    GetToken(); id = 0xFFFFFFFF
    if list and n and m_pToken: if *m_pToken == 0: return null       # the empty end-of-buffer token → "no token"
                                id = IsTokenID(m_pToken, list, n)
    return m_pToken
```

### 2.6 Result messages (complete list)

`FILE PROCESSING - %s `, `Include - %s `, `FILE OPEN ERROR(Code = %d) - %s `, `INCLUDE OPEN ERROR(Code = %d) - %s `,
`FORMAT DEFINNING, EOF Come.`, `%s - FORMAT DEFINING, UNKNOWNED PARAMATER.`, `DATA DEFINNING, EOF Come`,
`%s - UNKNOWNED.`, `%s - READ OK` / `READ ERROR`, `%s - WRITE OK` / `WRITE ERROR`, `%s - WRITE FORMAT OK` /
`WRITE FORMAT ERROR`, `%s - WRITE DATA OK` / `WRITE DATA ERROR`, `Include Format %d Defined, %d Errors`,
`Include Data %d Defined, %d Errors`, `TOTAL Format %d Defined, %d Errors`, `TOTAL Data %d Defined, %d Errors`, plus
separator lines of `=` (80) and `-` (63) and `" "`. They are only shown on a failed `ReadServerInfo` (§2.5); the
`*(inferred)*` argument lists above follow the format strings (the export drops varargs; ReadScriptDone's were read
in the disassembly at 0x461543 … 0x46159f).

### 2.7 Login and Zone copies

An instruction-level comparison (`tools/protocol-re/asmcmp.py CCsl,CToken`: objdump of each same-name function,
addresses normalised) of all 16 `CToken` and 30
`CCsl` functions finds **no code difference**: the only mismatches are the inline jump tables of `MakeData`,
`ProcRemark`, `ProcCmd` (address bytes). The constant tables (§2.1) are byte-identical. The decompiler differences part 1
noted (Zone `Read`, `MakeFormat`, `Clear*`, `Close`, `MakeFormatTable`; Login / Zone `ProcRemark`) are export artefacts
(e.g. Zone `ClearFormats` 0x6519b0 has its loop at 0x6519c0–0x6519ee; the export shows one iteration). The Zone build
lacks `ViewResultMsg` (no caller) and adds `CToken::GetTokenID` (§2.5).

| Function | WM | Login | Zone |
|---|---|---|---|
| `CToken::CToken` / `Close` / `SetSeprator` / `my_tcstok` / `GetToken` | FUN_0045a080 / FUN_0045a0f0 / FUN_0045a150 / FUN_0045a170 / FUN_0045a1f0 | FUN_0040aa00 / FUN_0040aa70 / FUN_0040aad0 / FUN_0040aaf0 / FUN_0040ab70 | FUN_0063aea0 / FUN_0063af10 / FUN_0063af70 / FUN_0063af90 / FUN_0063b010 |
| `GoBegin` / `GoNextLine` / `GoStartString` / `SaveTokenPositon` / `RestoreTokenPositon` | FUN_0045a270 / FUN_0045a330 / FUN_0045a380 / FUN_0045a3d0 / FUN_0045a3e0 | FUN_0040abf0 / FUN_0040acb0 / FUN_0040ad00 / FUN_0040ad50 / FUN_0040ad60 | FUN_0063b090 / FUN_0063b150 / FUN_0063b1a0 / FUN_0063b1f0 / FUN_0063b200 |
| `IsTokenID` / `GetTokenID` / `~CToken` / `Open` / `OpenFromMemory` / `GetTokenString` | FUN_0045a450 / – / FUN_0045a490 / FUN_0045a520 / FUN_0045a630 / FUN_0045a6f0 | FUN_0040add0 / – / FUN_0040ae10 / FUN_0040aea0 / FUN_0040afb0 / FUN_0040b070 | FUN_0063b270 / FUN_0063b2b0 / FUN_0063b310 / FUN_0063b3a0 / FUN_0063b4b0 / FUN_0063b570 |
| `CCsl::VarClear` / `MakeFormatTable` / `MakeDataTable` / `AddResultMsg` / `ViewResultMsg` | FUN_004608d0 / FUN_00460940 / FUN_004609c0 / FUN_00460a40 / FUN_00460ac0 | FUN_0040d200 / FUN_0040d270 / FUN_0040d2f0 / FUN_0040d370 / FUN_0040d3f0 | FUN_00650710 / FUN_00650780 / FUN_00650800 / FUN_00650880 / – |
| `GetFormat` / `GetNumDatas` / `GetDataInfo` / `GetData` / `ProcRemark` / `MakeFormat` | FUN_00460af0 / FUN_00460b40 / FUN_00460b50 / FUN_00460ba0 / FUN_00460c90 / FUN_00460ea0 | FUN_0040d420 / FUN_0040d470 / FUN_0040d480 / FUN_0040d4d0 / FUN_0040d5c0 / FUN_0040d7d0 | FUN_00650900 / FUN_00650950 / FUN_00650960 / FUN_006509b0 / FUN_00650aa0 / FUN_00650cb0 |
| `AddFormat` / `GetDataToken` / `Parameter_filename` / `MakeData` / `ProcData` / `ReadScriptDone` | FUN_00461150 / FUN_00461190 / FUN_00461210 / FUN_00461240 / FUN_00461490 / FUN_00461520 | FUN_0040da80 / FUN_0040dac0 / FUN_0040db40 / FUN_0040db70 / FUN_0040ddc0 / FUN_0040de50 | FUN_00650f60 / FUN_00650fa0 / FUN_00651020 / FUN_00651050 / FUN_006512a0 / FUN_00651330 |
| `Read` / `WriteFormat` / `WriteData` / `ClearFormats` / `ClearDatas` / `Close` / `Clear` | FUN_00461730 / FUN_00461970 / FUN_00461a90 / FUN_00461ba0 / FUN_00461c10 / FUN_00461c80 / FUN_00461d00 | FUN_0040e060 / FUN_0040e2a0 / FUN_0040e3c0 / FUN_0040e4d0 / FUN_0040e540 / FUN_0040e5b0 / FUN_0040e630 | FUN_00651540 / FUN_00651780 / FUN_006518a0 / FUN_006519b0 / FUN_00651a20 / FUN_00651a90 / FUN_00651b10 |
| `~CCsl` / `CCsl()` / `CCsl(parent)` / `IncludeFile` / `ProcCmd` / `ReadScript` | FUN_00461de0 / FUN_00461e40 / FUN_00461ea0 / FUN_00462090 / FUN_004621f0 / FUN_004626f0 | FUN_0040e710 / FUN_0040e770 / FUN_0040e7d0 / FUN_0040e9c0 / FUN_0040eb20 / FUN_0040f020 | FUN_00651bf0 / FUN_00651c50 / FUN_00651cb0 / FUN_00651ea0 / FUN_00652000 / FUN_00652500 |
| `CServerInfo::CServerInfo` (= `CCsl()` on `m_Csl`) | FUN_00465c80 | FUN_004104d0 | FUN_0064d0e0 |
| `CServerInfo::ReadServerInfo` / `GetShineServerIDName` / `…ShortName` | FUN_00465c90 / FUN_0045a040 / FUN_0045a060 | FUN_004104e0 / FUN_0040a9c0 / FUN_0040a9e0 | FUN_0064d0f0 / – / – |

### 2.8 Uncertain (part 2)

- The varargs of the result messages are *(inferred)* from their format strings except ReadScriptDone's include
  counts (read). They are diagnostics only.
- `m_hWnd` / `m_UseMsgID` (0x401 = `WM_USER + 1`) and the unused `m_lplpTokenList` / `m_dwNumTokens` suggest the
  reader came from a Windows editor tool *(inferred)*; the servers never post window messages through them.
- What S02-B13 reads past the buffer depends on the heap; with the shipped files the path is not reached.

## 3. Packed files: `CGdp`

`CGdp` (0x15c bytes) is the file layer under `CToken` and `CCsl`: every file the script reader opens, reads, seeks,
writes or closes goes through it (`CToken::m_Gdp` at +0, §2.1; callers: `CToken::Open` / `GoBegin` / `Close` /
`OpenFromMemory` / `~CToken`, `CCsl::Read` / `WriteFormat` / `WriteData` / `ProcCmd` `#WRITE*`, §2.2–§2.3). It wraps a
"GDP" container format (a directory of named entries inside one file) behind Win32-shaped methods. Names, layout and
enums are *(pdb2016)*.

**In the 2016 servers the container mode is unreachable**: `m_bIsGDPOpen` is written only by `Clear`, `GdpClose` and
the destructor, always 0, and no function that opens a container is linked (the PDB lists all 24 `CGdp` publics; none
reads a container header). The magic `GDPID` / `GDP_TYPE_MAIN` = 0x1A504447 ("GDP\x1a") appears neither as an
immediate in the code nor as bytes in any 2016 server or client binary, and none of the 7,028 files under `Files/`
starts with it (no `*.gdp` either). So every `CGdp` method is a straight pass-through to the Win32 call of the same
name (§3.2). **No 2016 install ships a GDP container**, and the config scripts are always plain text files.
§3.3–§3.5 document the dead container code for completeness; its bugs (S02-B23 … B30) cannot happen in 2016.

### 3.1 Data structures

```
CGdp (0x15c)
  +0x000 int  m_bIsGDPOpen            container open (never set ≠ 0 in 2016)
  +0x004 GDP_IO_TYPE m_GdpIO          0 GDP_IO_WIN32 (HANDLE), 1 GDP_IO_ANSI (FILE*); always 0
  +0x008 HANDLE m_hGDPFile, +0x00c FILE* m_fpGDPFile      the container
  +0x010 int  m_bIsGDPOpenByHandle, +0x014 m_bIsGDPOpenByFilePointer   container given by the caller: GdpClose keeps it open
  +0x018 char m_GDPFileName[260]
  +0x11c u32  m_dwGDPFPos, +0x120 m_dwGDPFPosHigh         (only cleared)
  +0x124 u32  m_dwNumChunk, +0x128 GDP_CHUNK_LIST* m_pChunkList   in-memory copy of all chunk records
  +0x12c u32  m_dwDefaultNumEmptyMakes                    10 (GDP_DEFAULT_NUM_EMPTY_MAKES)
  +0x130 int  m_bWriteEncryptedHeader, +0x134 m_bWriteEncryptedData, +0x138 u32 m_EncryptKey   (ctor: 0, 0, 0; never set)
  +0x13c int  m_bIsOpen                                    an entry is open
  +0x140 GDP_STORE_TYPE m_StoreType, +0x144 int m_bNew, +0x148 int m_bWritten
  +0x14c HANDLE m_hFile, +0x150 FILE* m_fpFile             = the container handle while an entry is open
  +0x154 u32  m_dwFileNo, +0x158 GDP_CHUNK_LIST* m_pFileChunk   index / record of the open entry

GDP_CHUNK_LIST (0x144) { u32 ChunkFPos; i32 ChunkFPosHigh;  GDP_CHUNK Chunk }   (where the record sits in the container)
GDP_CHUNK (0x13c, the on-disk record) {
  +0x00 GDP_TYPE Type        0x1A504447 MAIN, 1 LINK, 2 FILE, 3 DELETED, 4 EMPTY, 5 END
  +0x04 u32 Encrypt          bit 0 ENCRYPTED_HEADER (+0x08…+0x13b XORed), bit 1 ENCRYPTED_DATA (entry bytes XORed)
  +0x08 union (0x134):
    TYPE_MAIN { char Comment[260]; u32 NumChunk; u32 NumNextChunkComes }                     (record 0)
    TYPE_LINK { char Comment[260]; u32 FDirPos; u32 FDirPosHigh; u32 NumNextChunkComes }     (continuation pointer)
    TYPE_DIR  { char Name[260]; GDP_STORE_TYPE StoreType (0 COPY, 1 DIB, 2 ZIP); u32 FPos, FPosHigh;
                u32 SrcSize, SrcSizeHigh; u32 DatSize, DatSizeHigh; FILETIME ftLastWriteTime; u32 CHK32, res0, res1 }  (FILE entry)
}
Other PDB constants: GDP_MAX_NAME 260, GDP_COPY_BUFFER_SIZE 131072; structs FILE_LIST { char FileName[512] },
FILE_LIST2 { FileName[512]; WIN32_FIND_DATAA } — used by no linked function.
```

The decompiler shows `TYPE_DIR` fields under the `TYPE_MAIN` / `TYPE_LINK` names that share their offset (union):
`TYPE_MAIN.NumChunk` = `StoreType` / `LINK.FDirPos` (+0x104), `TYPE_MAIN.NumNextChunkComes` = `FPos` /
`LINK.FDirPosHigh` (+0x108), `TYPE_LINK.NumNextChunkComes` = `FPosHigh` (+0x10c). The pseudocode below uses the
member that the logic means.

Container layout *(inferred from the writers; no reader is linked)*: record 0 is `MAIN` (`NumChunk` = total records);
records follow back to back, a run ends with `END`. Growing the directory appends a new run at the end of the file and
turns the old `END` into `LINK` { `FDirPos` = where the new run starts, `NumNextChunkComes` = its length }. Entry data
(`FILE.FPos`, `SrcSize` bytes) is appended at the end of the file too, so runs and data interleave. `CHK32`, `DatSize`
≠ `SrcSize` (compression, `DIB` / `ZIP`) and `res0/1` are never computed (`DatSize` = `SrcSize` always).

### 3.2 What the servers execute: the pass-through

```pseudo
CGdp::CGdp(): m_bWriteEncryptedHeader = m_bWriteEncryptedData = m_EncryptKey = 0; Clear()      @ FUN_0045f480
CGdp::Clear(): m_bIsGDPOpen = 0; m_GdpIO = WIN32; both container handles = 0; ByHandle = ByFilePointer = 0;   @ FUN_0045ed50
    m_GDPFileName = 0…; m_dwGDPFPos/High = 0; m_dwNumChunk = 0; m_pChunkList = 0; m_bIsOpen = 0; m_StoreType = COPY;
    m_bNew = 0; m_hFile = 0; m_dwFileNo = 0; m_pFileChunk = 0; m_dwDefaultNumEmptyMakes = 10
    # m_bWritten, m_fpFile and the encryption fields are not touched

with m_bIsGDPOpen == 0 (always, in 2016):
CGdp::CreateFileA(name, access, share, sa, disposition, flags, template) = ::CreateFileA(same)      @ FUN_0045fac0
CGdp::ReadFile(h, buf, n, &read, ov)     = ::ReadFile(same)                                       @ FUN_0045f1a0
CGdp::WriteFile(h, buf, n, &written, ov) = ::WriteFile(same)                                      @ FUN_0045f230
CGdp::GetFileSize(h, &high)              = ::GetFileSize(same)       (tail jump)                  @ FUN_0045f320
CGdp::SetFilePointer(h, lo, &hi, method) = ::SetFilePointer(same)    (tail jump)                  @ FUN_0045f360
CGdp::CloseHandle(h)                     = ::CloseHandle(h)                                       @ FUN_0045f160
CGdp::fclose(fp)                         = ::fclose(fp)              (no caller)                  @ FUN_0045f430
CGdp::GdpClose(): m_bIsOpen = 0 → skip; m_bIsGDPOpen = 0 → skip; m_pChunkList = 0 → skip; Clear(); return 1   @ FUN_0045f8d0
CGdp::~CGdp() = jmp GdpClose                                                                       @ FUN_0045fa70
```

So `CToken::Close` (`CloseHandle(m_hFile)` then `GdpClose`) closes the OS handle and re-clears the object; nothing else
is held. Win32 semantics apply unchanged, including the error codes the callers see.

### 3.3 Container mode: opening entries

```pseudo
CGdp::GdpSearchFile(name):  first i < m_dwNumChunk with chunk[i].Type == FILE and _mbsicmp(chunk[i].Name, name) == 0   @ FUN_0045f050
    → i, else 0xFFFFFFFF                     # case-insensitive (multibyte), linear
CGdp::Open(name): !m_bIsGDPOpen → 0; i = GdpSearchFile(name); −1 → 0; return Open(i)               @ FUN_0045fa40
CGdp::Open(i):                                                                                      @ FUN_0045f980
    !m_bIsGDPOpen → 0
    i > m_dwNumChunk → 0             # i == m_dwNumChunk passes: reads one record past the list (original bug) S02-B29
    chunk[i].Type != FILE → 0
    GdpCloseFile() fails → 0
    m_dwFileNo = i; m_pFileChunk = &list[i]
    GdpSetFilePointer(FPos, &FPosHigh, FILE_BEGIN) != FPos → 0   # also writes the container's new high dword into FPosHigh
    m_bWritten = 0; m_bNew = 0; m_fpFile = m_fpGDPFile; m_hFile = m_hGDPFile; m_bIsOpen = 1; return 1
CGdp::GdpCloseFile(): m_bIsOpen: WIN32 → return CloseHandle(m_hFile); ANSI → return fclose(m_fpFile); else 1   @ FUN_0045f4a0
CGdp::CloseHandle(h) / fclose(fp) with the container open:                                          @ FUN_0045f160 / FUN_0045f430
    m_bIsOpen → GdpUpdateChunk(m_dwFileNo) (rewrite the entry record: sizes, time); m_bIsOpen = 0
    return 1 (CloseHandle) / 0 (fclose)            # h / fp is ignored; the container stays open
CGdp::GdpClose() / ~CGdp():                                                                         @ FUN_0045f8d0 / FUN_0045fa70
    m_bIsOpen: close the entry as above (failure → return 0, the object stays as is); m_bIsOpen = 0
    m_bIsGDPOpen: m_bIsGDPOpen = 0; close the container handle / FILE* unless it was given by the caller (ByHandle / ByFilePointer)
    free(m_pChunkList); Clear(); return 1
CGdp::GdpSetFilePointer(lo, &hi, method):                                                           @ FUN_0045edd0
    WIN32: ::SetFilePointer(m_hGDPFile, lo, &hi, method)
    ANSI:  fseek(m_fpGDPFile, lo, method) ok → hi = 0; return ftell();  fails → SetLastError(0x84); return −1
    other: return −1
```

`CGdp::CreateFileA` with the container open (the disposition decides; `access`, `share`, `flags` are ignored):  @ FUN_0045fac0

```pseudo
    m_bIsOpen → close the current entry (CloseHandle / fclose as above)
    switch disposition:
      1 CREATE_NEW:        name exists → SetLastError(0xB7 ERROR_ALREADY_EXISTS); return INVALID_HANDLE_VALUE
      2 CREATE_ALWAYS:     GdpDeleteFile(name) (mark the old entry DELETED, if any)
      3 OPEN_EXISTING:     Open(name) → return m_hFile;  else SetLastError(0x490 ERROR_NOT_FOUND); return INVALID
      4 OPEN_ALWAYS:       Open(name) → return m_hFile
      5 TRUNCATE_EXISTING: name exists → SetLastError(0x490); return INVALID
                           else GdpDeleteFile(0xFFFFFFFF) (index −1: reads the record before the list) → 0 → return INVALID
                           # inverted test: an existing entry is refused and a missing one indexes list[−1] (original bug) S02-B24
      other:               return INVALID (no SetLastError)
    # create a new entry:
    i = GdpGetEmptyChunk(); m_dwFileNo = i; −1 → return INVALID
    m_pFileChunk = &list[i]; Type = FILE; strncpy(Name, name, 259)
    SrcSize/High = DatSize/High = 0; ftLastWriteTime = now (UTC); CHK32 = 0; FPosHigh = 0
    FPos = ::SetFilePointer(m_hGDPFile, 0, &FPosHigh, FILE_END)        # Win32 call even in ANSI mode
    FPos == −1 and GetLastError() != 0 → return INVALID
    m_bIsOpen = 1; m_bNew = 1; m_bWritten = 0; m_fpFile = 0; m_hFile = m_hGDPFile; return m_hGDPFile
    # StoreType, Encrypt, res0/1 of the slot are not set: uninitialised heap if the slot came from GdpMakeEmptyChunk
    # (original bug) S02-B27; the record is written to disk only when the entry is closed (GdpUpdateChunk)
```

The returned "handle" is the container handle itself; `ReadFile` / `WriteFile` / `SetFilePointer` / `GetFileSize`
recognise it by comparing with `m_hFile`.

### 3.4 Container mode: reading, writing, seeking

```pseudo
CGdp::ReadFile(h, buf, n, &read, ov):                                                               @ FUN_0045f1a0
    h != m_hFile → return 0
    switch m_pFileChunk.StoreType:
      COPY (0): ::ReadFile(h, buf, n, &read, ov) else return 0
                # n is not limited to the entry: reading past SrcSize returns the next records / entries (original bug) S02-B25
      DIB (1), ZIP (2): return 0              # not implemented
      other:    nothing read, `read` untouched, falls through and returns 1 (part of S02-B25)
    Encrypt & ENCRYPTED_DATA → GdpDecryptData(buf, read)
    return 1
CGdp::GdpDecryptData(buf, n):  k = byte0 ^ byte1 ^ byte2 ^ byte3 of m_EncryptKey; buf[j] ^= k for j < n    @ FUN_0045ee50
    # one constant byte: the "encryption" is symmetric and the key is 0 in every 2016 object (identity)
CGdp::WriteFile(h, buf, n, &written, ov):                                                           @ FUN_0045f230
    h != m_hFile → return 0
    Encrypt & ENCRYPTED_DATA → XOR buf in place with k (same byte as above)
    StoreType COPY → r = ::WriteFile(h, buf, n, &written, ov);  DIB / ZIP → r = 0;  other → r = h (non-zero, nothing written)
    Encrypt & ENCRYPTED_DATA → XOR buf again (restores the caller's const buffer)
    r != 0 → m_bWritten = 1; UpdateWriteDataInfo(buf, n)
    return r
CGdp::UpdateWriteDataInfo(buf, n):  SrcSize:High += n (64-bit); DatSize:High = SrcSize:High; ftLastWriteTime = now   @ FUN_0045efb0
    # adds n, not the bytes written, and whatever the position: rewriting an existing entry (Open / OPEN_ALWAYS)
    # grows its size and can overwrite the data or records that follow it (original bug) S02-B28
CGdp::GetFileSize(h, &high): high = SrcSizeHigh; return SrcSize        # h not checked                         @ FUN_0045f320
CGdp::SetFilePointer(h, lo, &hi, method):        # h not checked; always the Win32 call on m_hFile                  @ FUN_0045f360
    FILE_BEGIN (0):   hi += FPosHigh (if &hi); r = ::SetFilePointer(m_hFile, lo + FPos, &hi, FILE_BEGIN)
    FILE_CURRENT (1): r = ::SetFilePointer(m_hFile, lo, &hi, FILE_CURRENT)
    FILE_END (2):     r = ::SetFilePointer(m_hFile, lo + FPos + SrcSize, &hi + FPosHigh (pointer arithmetic), FILE_END)
                      # method FILE_END with an absolute target (lands past the container end), the high dword is
                      # passed as `&hi + FPosHigh` elements instead of `hi + FPosHigh`, then FPosHigh is subtracted
                      # from a value it was never added to (original bug) S02-B23
    other:            hi = −1 (if &hi); SetLastError(0x57 ERROR_INVALID_PARAMETER); return −1
    hi −= FPosHigh (if &hi); return r − FPos        # also when r is −1 (failure): returns −1 − FPos
```

### 3.5 Container mode: directory maintenance

```pseudo
CGdp::GdpWriteChunk(chunk):                                                                         @ FUN_0045ee90
    m_bWriteEncryptedHeader == 0: chunk.Encrypt &= ~1; write chunk as is
    else: chunk.Encrypt |= 1; copy = chunk; key = m_EncryptKey
          for j in 0 … 0x4c: copy.dword[2 + j] ^= key ^ 0x36175A5A; key = rotl(key, 1)   # the 0x134-byte union; Type / Encrypt stay plain
          write copy
    WIN32: return ::WriteFile(m_hGDPFile, rec, 0x13C, …)  (the byte count is not checked);  ANSI: fwrite(rec, 0x13C, 1) == 1;  other: 1
CGdp::GdpUpdateChunk(i): GdpSetFilePointer(list[i].ChunkFPos, &list[i].ChunkFPosHigh, FILE_BEGIN)          @ FUN_0045ef50
    (−1 and GetLastError() != 0 → 0); return GdpWriteChunk(&list[i].Chunk) != 0
CGdp::GdpDeleteFile(i): list[i].Type != FILE → 0; Type = DELETED; seek to list[i].ChunkFPos; return GdpWriteChunk != 0   @ FUN_0045f0b0
    # i is not range-checked (S02-B24 passes −1)
CGdp::GdpDeleteFile(name): i = GdpSearchFile(name); −1 → 0; return GdpDeleteFile(i)                 @ FUN_0045f130
CGdp::GdpGetEmptyChunk(): first i with Type == EMPTY → i; none → GdpMakeEmptyChunk(m_dwDefaultNumEmptyMakes = 10)   @ FUN_0045fa80
    # DELETED records are never reused
CGdp::GdpMakeEmptyChunk(n):                                                                         @ FUN_0045f4e0
    new = malloc((m_dwNumChunk + 1 + n) × 0x144) else return 0       # 0 is a valid index (record 0, MAIN): CreateFileA
                                                                       # turns MAIN into a FILE entry (original bug) S02-B30
    copy the old list, free it, m_pChunkList = new        # the n + 1 new slots stay uninitialised except as set below
    e = first index with Type == END; none → return −1
    endPos:endHigh = seek(container, 0, FILE_END)          # ANSI: fseek + ftell, high = 0
    for k in 1 … n:
        list[e+k].ChunkFPos:High = current position (Win32: SetFilePointer(0, FILE_CURRENT);
                                   ANSI: ftell, but any non-zero result counts as an error → −1 (original bug) S02-B26)
        −1 and GetLastError() != 0 → return −1
        GdpWriteChunk({ Type = EMPTY, rest 0 }) else −1; list[e+k].Type = EMPTY
    list[e+n+1].ChunkFPos:High = current position; GdpWriteChunk({ Type = END }) else −1; list[e+n+1].Type = END
    list[e].Type = LINK; list[e].FDirPos = endPos; FDirPosHigh = endHigh; NumNextChunkComes = n + 1
    seek to list[e].ChunkFPos; GdpWriteChunk(&list[e].Chunk) else −1      # the old END becomes the link record
    m_dwNumChunk += n + 1; list[0].NumChunk = m_dwNumChunk; GdpUpdateChunk-like rewrite of record 0 else −1
    return e + 1                                           # the first new EMPTY slot
```

### 3.6 Login and Zone copies

`tools/protocol-re/asmcmp.py CGdp` over all 24 functions: **no code difference** in Login or Zone. The only mismatch is
`CGdp::CreateFileA`'s inline switch jump table after the final `ret` (address bytes), which is also why the Login /
Zone exports decompile it differently (part 1 note). The pass-through behaviour (§3.2) therefore holds in all three
servers.

| Function | WM | Login | Zone |
|---|---|---|---|
| `Clear` / `GdpSetFilePointer` / `GdpDecryptData` / `GdpWriteChunk` / `GdpUpdateChunk` / `UpdateWriteDataInfo` | FUN_0045ed50 / FUN_0045edd0 / FUN_0045ee50 / FUN_0045ee90 / FUN_0045ef50 / FUN_0045efb0 | FUN_0040c220 / FUN_0040c2a0 / FUN_0040c320 / FUN_0040c360 / FUN_0040c420 / FUN_0040c480 | FUN_0063b660 / FUN_0063b6e0 / FUN_0063b760 / FUN_0063b7a0 / FUN_0063b860 / FUN_0063b8c0 |
| `GdpSearchFile` / `GdpDeleteFile(i)` / `GdpDeleteFile(name)` / `CloseHandle` / `ReadFile` / `WriteFile` | FUN_0045f050 / FUN_0045f0b0 / FUN_0045f130 / FUN_0045f160 / FUN_0045f1a0 / FUN_0045f230 | FUN_0040c520 / FUN_0040c580 / FUN_0040c600 / FUN_0040c630 / FUN_0040c670 / FUN_0040c700 | FUN_0063b960 / FUN_0063b9c0 / FUN_0063ba40 / FUN_0063ba70 / FUN_0063bab0 / FUN_0063bb40 |
| `GetFileSize` / `SetFilePointer` / `fclose` / `CGdp()` / `GdpCloseFile` / `GdpMakeEmptyChunk` | FUN_0045f320 / FUN_0045f360 / FUN_0045f430 / FUN_0045f480 / FUN_0045f4a0 / FUN_0045f4e0 | FUN_0040c7f0 / FUN_0040c830 / FUN_0040c900 / FUN_0040c950 / FUN_0040c970 / FUN_0040c9b0 | FUN_0063bc30 / FUN_0063bc70 / FUN_0063bd40 / FUN_0063bd90 / FUN_0063bdb0 / FUN_0063bdf0 |
| `GdpClose` / `Open(i)` / `Open(name)` / `~CGdp` / `GdpGetEmptyChunk` / `CreateFileA` | FUN_0045f8d0 / FUN_0045f980 / FUN_0045fa40 / FUN_0045fa70 / FUN_0045fa80 / FUN_0045fac0 | FUN_0040cda0 / FUN_0040ce50 / FUN_0040cf10 / FUN_0040cf40 / FUN_0040cf50 / FUN_0040cf90 | FUN_0063c1e0 / FUN_0063c290 / FUN_0063c350 / FUN_0063c380 / FUN_0063c390 / FUN_0063c3d0 |

The only `CGdp` instances in the three servers are the `m_Gdp` members of `CToken` objects (the `CCsl` readers and, in
Zone, the quest-script parser `CQuestParserScript`, §2.5): no other caller of any `CGdp` method exists.

### 3.7 Uncertain (part 3)

- The container's read side (open by name / handle / `FILE*`, header decryption, walking `LINK` runs) is not linked,
  so the on-disk layout in §3.1 is *(inferred)* from the writers and the PDB types. Whether the record-0 `MAIN` comment
  or a `LINK`'s `Comment` is ever filled is unknown.
- Whether Account / AccountLog / Character / GameLog link the same `CGdp` is not compared (no PDB); none of them
  contains the `GDPID` constant, so the container mode is dead there too.

## 4. Library users and small helpers (sweep)

What sits directly on top of the library and no other item cites. The rest of each server's process layer is
documented per server (WM: W05 §1, §4; Zone: Z10 §6.5, Z09 §1.5, Z01 §1; Login: `login-server.md` §2 and the
follow-up item L01, §7).

### 4.1 Helpers

```pseudo
CGTimer::GetTime(): return timeGetTime()          # ms since boot   @ FUN_00467bb0 (Login FUN_00412870, Zone FUN_00650700)
    # every library timestamp (accept time §1.4, session m_LastReceiveTime / m_LastSendTime §1.6) is this value
```

`GetLastErrorStr` (FUN_0045ff10), `ShineExit` (FUN_004673f0) and `cShineLogSystem::SLS_AddLog` (FUN_00467530) are
W05 §6.4 / §5.7; Login / Zone copies: `GetLastErrorStr` FUN_00410050 / FUN_0064efe0, `ShineExit` FUN_004121b0 /
FUN_0063c7c0, `SLS_AddLog` FUN_00412bc0 / FUN_00648570.

### 4.2 Destructors that tear the library down

```pseudo
CServerInfo::~CServerInfo(si):                    @ FUN_004037d0   (WM; Login FUN_00401000; Zone has none, below)
    CCsl::Close(&si.m_Csl); CToken::~CToken(&si.m_Csl)      # rows and formats freed by Close (§2.3.8)

ZoneServer::~ZoneServer(z):                       @ FUN_005aa6f0
    ~ClientSessionManager(z.zs_clientsessionmanager)        # §4.4 (FUN_0045c5e0)
    CSocket_Acceptor::~CSocket_Acceptor(z.zs_Acceptor)      # §1.4 (FUN_00652bb0)
    CIOCP::~CIOCP(z.zs_IOCP)                                # = WM / Login CIOCP::Close (§1.3, §1.9)
    CCsl::~CCsl(z.zs_serverinfo)                            # CServerInfo is torn down as its CCsl member

LoginServer::~LoginServer(l):                     @ FUN_00401010
    reverse member order: COTPLogin, OPTool parser table + pool, WM parser table + pool, client parser table + pool,
    AccountLog parser table + session, AccountDB parser table + session, CIOCP::Close(m_IOCP),
    ~CSocket_Acceptor(m_Acceptor), ~CCsl(m_ServerInfo)
    # the two DB sessions are destroyed through ~CLoginWorldManagerSession FUN_00408cf0: identical bodies folded by
    # the linker (inferred), same code as ~CLoginBaseSession below

CLoginBaseSession::~CLoginBaseSession(s):         @ FUN_00408d60   (WM ~CWMBaseSession FUN_0042fbc0, W05 §6.2)
    s.m_IOCP_Process.vftable = CIOCP_Process_Interfece; ~CPacket(s.m_Packet); ~CSocket_IOCP(s.m_SocketIOCP)
```

### 4.3 Login process glue the library reaches

The Login counterparts of WM W05 §1.1 / §1.6 / §6.2 that `login-server.md` does not cite. Same shape as the WM.

```pseudo
LoginServer::LoginServer(l):                      @ FUN_004029e0
    construct m_ServerInfo (CServerInfo, §2.5), m_Acceptor (§1.4), m_IOCP (§1.3), AccountDB / AccountLog sessions and
    parsers, client / WM / OPTool pools and parsers, m_OTPLogin
    m_ConnectSocket_BindIP[16] = 0; m_bOnStopService = m_bProcessLinked = 0; m_MainWorkStep = MAIN_WORK_NONE
    m_strHashValue[0x80] = 0
    m_LoginUserRatable[256] = { 3, 5, 8, 10, 30, 95 } each    # 6 ints per entry (nWMSUS_1 …); meaning: L01

LoginServer::OnStart_Service(l):                  @ FUN_004032b0   (WM: W05 §1.1)
    n = 2 × GetSystemInfo().dwNumberOfProcessors
    CIOCP::Start(m_IOCP, n, 1) != n → return false           # §1.3: returns the number of workers started
    Start_Acceptor(l) == 0 → return false
    m_isPermitServer = 1
    Start_MainThread(l) == 0 → return false                   # FUN_00403200: CreateThread(MainThread), Sleep(5)
                                                              # until it sets m_bActiveMainThread; fail → log
    m_MainWorkStep = MAIN_WORK_LINK; return true              # the main loop: login-server.md §2

LoginServer::Start_Acceptor(l):                   @ FUN_00401740
    CSocket_Acceptor::Listen_Start(m_Acceptor) → log "<SUCCESSED START ACCEPTOR>", 1; else "*FAILED START ACCEPTOR*", 0
    # the listen ports are added before (Listen_OPTool / Listen_WorldManager / Listen_Client, login-server.md §2)

LoginServer::ProcessStop(l):                      @ FUN_00402820   (WM: W05 §1.6)
    Listen_Stop(m_Acceptor); log "<STOPPED ACCEPTOR>" (or "*FAILED STOP ACCEPTOR*")
    CIOCP::Close(m_IOCP); log "<IOCP CLOSED>"                 # workers gone before any session is closed
    DissconnectAllSessions(client pool); client FreeSessions
    DissconnectAllSessions(WM pool); WM FreeSessions
    CLoginBaseSession::Close(m_AccountDB); CLoginBaseSession::Close(m_AccountLogDB)
    DissconnectAllSessions(OPTool pool); OPTool FreeSessions
    ViewStopInfo(l)                                           # one log line per step in between

CLoginBaseSessionManager::DissconnectAllSessions(m):   @ FUN_00409250
    if m_NumSessions: for node in m_pActiveSessions list: node.pSession → CLoginBaseSession::Close   (§1.6)

CLoginBaseSessionManager::ProcHeartBeat(m, iocp):      @ FUN_00409280   (WM: W05 §1.5)
    for node in m_pActiveSessions (next taken before the call):
        CLoginBaseSession::CheckHeartBeat(node.pSession) == 0 → CSocket_IOCP::CloseUseIOCP(&node.pSession.m_SocketIOCP, iocp)
        # CheckHeartBeat FUN_00408f30: login-server.md §3.1

CLoginBaseSession::CLoginBaseSession(s):          @ FUN_00409140   (WM: W05 §6.2)
    CSocket_IOCP(s.m_SocketIOCP) (§1.5); CPacket(s.m_Packet) (§1.7); s.m_IOCP_Process.vftable = CIOCP_Process_LSession
    m_Connected_Server_ID = 10 (SERVER_ID_UNKNOWN); m_Connected_World = m_Connected_Zone = 0
    m_Status = SESSION_STATUS_EMPTY; m_Connected_Time = GetLocalTime(); m_LastReceiveTime = m_LastSendTime = GetTime()
    m_LastHeartBeatSendTime = 0
    for ov in (Write, Read, Close): ov.pIOCP_Process.m_pProcess = &s.m_IOCP_Process; ov.pData = s
        # the wiring §1.6 relies on: a completion reaches CIOCP_Process_LSession::IOCP_Process with pData = session
```

Login's `CServerInfo` (FUN_004104d0 … FUN_00410810) is instruction-identical to the WM's (`asmcmp.py CServerInfo`),
plus `GetNumOfData()` FUN_00410520 (`return m_Csl.m_NumDatas`) and the two world accessors of §2.5. Its row lookups:
`GetServerInfo(out, index)` FUN_004105c0 (row must have `dwID == 3`, the `SERVER_INFO` format in Login's order; fills
`pName`, `nServerID`, `nWorldNo`, `nZoneNo`, `nServerIDFrom`, `pIP`, `nPort`, `nBackLog`, `nMaxAccept` from columns
0–8, strings as pointers into the row), `GetServerIndex(id, world, zone, from)` FUN_00410670 (first `dwID == 3` row
whose columns 1–4 match, else −1) and `GetServerInfo(out, id, world, zone, from)` FUN_00410810 (= index lookup, then
the first). The WM bodies are W05 §5.2.

### 4.4 Zone process glue the library reaches

The Zone counterparts of §4.2 / §4.3. Session pools, parsers and the zone ring belong to Z01 (§1, §10). Only the parts
that build or use the library are shown here.

```pseudo
ZoneServer::ZoneServer(z):                        @ FUN_005ab470   (global `zoneserver`, dynamic initialiser)
    CServerInfo::CServerInfo(z.zs_serverinfo.serverinfo)    # FUN_0064d0e0: only CCsl() on m_Csl (§2.3.8)
    z.zs_serverinfo.worldname.n4_code[0..3] = 0
    CIOCP::CIOCP(z.zs_IOCP)                                 # §1.3 (FUN_00650380)
    CSocket_Acceptor::CSocket_Acceptor(z.zs_Acceptor)       # §1.4 (FUN_00652730)
    ClientSessionManager::ClientSessionManager(z.zs_clientsessionmanager)   # below
    z.zs_serverinfo.ConnectSocket_BindIP[16] = 0            # filled from ZoneServerInfo (Z10 §1.1)

ZoneBaseSession::ZoneBaseSession(s):              @ FUN_005a6920   (WM FUN_00430020 §1.6, Login FUN_00409140 §4.3)
    CSocket_IOCP(s.m_SocketIOCP) (§1.5); CPacket(s.m_Packet) (§1.7); s.m_IOCP_Process.vftable = IOCPProcessSession
    m_Connected_Server_ID = 10; m_Connected_World = m_Connected_Zone = 0; m_Status = SESSION_STATUS_EMPTY
    m_Connected_Time = GetLocalTime(); m_LastReceiveTime = m_LastSendTime = CGTimer::GetTime(); m_LastHeartBeatSendTime = 0
    for ov in (Write, Read, Close): ov.pIOCP_Process.m_pProcess = &s.m_IOCP_Process; ov.pData = s
    # base of ClientSession, ClientSessionNull, GameDBSession, GameLogSession, WorldManagerSession, ZoneConnectSession
    # (and the zone listen sessions): every Zone connection gets the IOCPProcessSession callbacks of §1.6

ZoneBaseSession::~ZoneBaseSession(s):             @ FUN_005a6620
    s.m_IOCP_Process.vftable = CIOCP_Process_Interfece; ~CPacket(s.m_Packet); ~CSocket_IOCP(s.m_SocketIOCP)
    # the socket is not closed here: ~CSocket_IOCP (§1.5) does that

ClientSession::CheckHeartBeat(s, unused):         @ FUN_0045b110
    return ZoneBaseSession::CheckHeartBeat(s, 300)          # FUN_005a67c0 (§1.6): the argument is ignored there too;
                                                            # the 30 s / 180 s limits are constants

ZoneBaseSessionManager::ProcHeartBeat(m, iocp):   @ FUN_005a6a40   (WM: W05 §1.5; Login FUN_00409280 §4.3)
    for node in m_pActiveSessions (next taken before the call):
        node.pSession.vtbl[0](30) == 0 → CSocket_IOCP::CloseUseIOCP(&node.pSession.m_SocketIOCP, iocp)   # §1.5
        # slot 0 = CheckHeartBeat: ZoneBaseSession FUN_005a67c0 or the ClientSession override above; the 30 / 300
        # arguments are ignored by both

ClientSessionManager::ClientSessionManager(m):    @ FUN_0045c5c0
    ZoneBaseSessionManager(m)                               # FUN_005a69f0: list array, active / empty lists = null,
                                                            # m_MaxSessions = m_NumSessions = 0
    m.csm_SessionGroupByIPArray = {0, 0, 0}                 # (begin, end, capacity) of a vector (inferred); Z01

ClientSessionManager::~ClientSessionManager(m):   @ FUN_0045c5e0   (called from ~ZoneServer, §4.2)
    delete csm_SessionGroupByIPArray storage; zero its 3 words
    ZoneBaseSessionManager::~ZoneBaseSessionManager(m)      # FUN_005a6a80: delete m_pSessionListArray
    # sessions are not closed here; the stop path closes them before (inferred; Z01)

ZoneServer::zs_ServerConnect2Zone(z, s):          @ FUN_005a9a00   (only caller: ZoneConnectSession::zcs_Send FUN_005a6ed0, Z01 §10)
    s.m_Status != SESSION_STATUS_EMPTY → return 1           # already connecting or connected
    next = ZoneIPContainer::zipc_GetNextZoneNo(zipc, my nZoneNo)   # FUN_005a96b0, below
    next == −1 → return 0                                   # never: GetNextZoneNo returns 0 … 11 (dead check)
                                                            # (original bug) S02-B33
    ZoneIPContainer::zipc_Mechine2IP(zipc, next, &ip, &port)        # FUN_005a9760, below
        fails → AssertFail "zs_ServerConnect2Zone : not find nextzoneinfo"; return 0   # unreachable for 0 … 11
    log "Try to connect[%s:%d] bind[%s]"
    ZoneBaseSession::Connect(s, ConnectSocket_BindIP, 0, ip-string, port, &z.zs_IOCP) != 1 → return 1   # §1.6;
                                                            # state stays EMPTY, so the next zcs_Send retries
    log "Connect Success[%s:%d] bind[%s]"; s.m_Status = SESSION_STATUS_CONNECTING; return 1

ZoneIPContainer::zipc_GetNextZoneNo(c, zone):     @ FUN_005a96b0
    zone + 1 > 11 → return 0                                # wrap after the 12th slot
    c.zipc_IPAddress[zone + 1].addr == "" (16 zero bytes) → return 0   # no next zone: back to zone 0
    return zone + 1
    # with zone 0 alone in the world, zone 0 is its own "next" zone and connects to its own zone-listen port
    # (inferred: ring of one)

ZoneIPContainer::zipc_Mechine2IP(c, n, &ip, &port):   @ FUN_005a9760
    n == 99 ('c') → n = zs_worlddata().nZoneNo              # "this machine"
    n > 11 → AssertFail "ZoneIPContainer::zipc_Mechine2IP : Invalid machine number"; return 0
    ip = c.zipc_IPAddress[n].addr (Name4, 16 bytes); port = c.zipc_IPAddress[n].port; return 1

ZoneIPContainer (global `zipc`): zipc_IPAddress[12] of { Name4 addr (16 bytes, dotted IP string); u16 port } (0x12 each),
    then Name4 zipc_NextIP. One slot per zone number ("machine") of this world.
ZoneIPContainer::ZoneIPContainer(c):             @ FUN_005a97d0   (element ctor FUN_005a9630: addr = 0)
    zipc_NextIP = ""; every slot: addr = "" (port left as constructed)
ZoneIPContainer::zipc_Store(c, n, ip, port):     @ FUN_005a9640   (caller: FieldContainer::fc_MakeField FUN_004650a0)
    n > 11 → AssertFail "ZoneIPContainer::zipc_Store : Invalid mechine"; ShineExit("ZoneIPContainer::zipc_Store")
    slot[n].addr = strncpy(ip, 16) after zeroing; slot[n].port = port     # 16 chars leave no NUL (inferred harmless:
                                                                          # read back as a Name4)
ZoneIPContainer::zipc_SetNextIP(c, own):         @ FUN_005a9850   (caller: zs_start_moon LAB_005ae250, Z10 §7.1)
    next = zipc_GetNextZoneNo(own)
    zipc_NextIP = (next == own) ? "" : slot[next].addr               # a lone zone 0 has no next IP
ZoneIPContainer::zipc_GetNextIP(c):              @ FUN_005a96a0   return &zipc_NextIP
    # caller: ZoneListenSession::zls_NC_MISC_ZONERINGLINKTEST_RNG FUN_0045b4d0 (Z01 §10)
    # note: zs_ServerConnect2Zone does not use zipc_NextIP; it recomputes the neighbour, so a lone zone 0 still
    # connects to slot 0 = itself (inferred)
```

## 5. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| S02-B1 | `CSocket_Acceptor::AcceptThreadRing` FUN_00463ee0 (ADD) | a failed `bind` / `listen` calls `WSACleanup` (ordinal 116) and does not close the new socket | one leaked socket per failed listen; the WinSock reference count drops | `WSAGetLastError` (111) for the log, then `closesocket` |
| S02-B2 | same | `getsockname(s, &addr, namelen = 4)` | always fails; the slot's address stays 0 (never read) | `namelen = sizeof(sockaddr_in)` |
| S02-B3 | `CIOCP::Register` FUN_00464380 | creates the port when the handle is −1, but it is 0 before `Start`; `CreateIoCompletionPort(h, 0, …)` then makes a new port per socket | dead in practice (Start runs first); a Register before Start would bind the socket to a port no worker waits on | test `== 0` / create in the ctor |
| S02-B4 | `CSocket_Acceptor::Listen_Stop` FUN_00463e10 | decrements `m_NumOfListen` for all 10 slots | the count ends negative; no effect (process stopping) | decrement only for used slots |
| S02-B5 | `CSocket_IOCP::Connect` FUN_004665b0 | blocking `connect` without timeout on the main thread | a silent peer host stalls the WM main loop ~21 s per retry (inferred) | non-blocking connect / `ConnectEx` |
| S02-B6 | `CSocket_IOCP::Send` FUN_004666f0 | no limit on the queued buffers; buffers are never returned to the heap | a peer that stops reading grows the process without bound | cap the queue and close the session |
| S02-B7 | `CSocket_IOCP::WriteCallback` FUN_00466240 | a partial write drops the rest of the buffer and the whole queue, socket stays open | the peer's byte stream loses data mid-frame, so its framing desyncs | re-issue the write for the unsent rest |
| S02-B8 | Zone `IOCPProcessSession::IOCP_Process` FUN_005a6820 | no `IOCP_CloseProcess` override; a failed completion does not mark the session | a reset connection stays until the heartbeat check (30 s, then 180 s) | mark state 3 like WM / Login |
| S02-B9 | `CIOCP_Process_LSession::IOCP_Process` read path FUN_0042fe90 (WM; Login / Zone copies §1.9) | adds the bytes, then re-reads `m_WritePosition` for the free space | a one-instruction window lets the main thread compact and re-arm; then two `ReadFile`s share one OVERLAPPED | compute the free space from the local value |
| S02-B10 | `CPacket::IsValidPacket` FUN_00467820 | long frames with size2 0 / 1 pass (`n = 3 / 4` > 2) | dispatched with len 0 / 1 and an opcode taken from the next frame's bytes | require size2 ≥ 2 |
| S02-B11 | `CCsl::MakeData` FUN_00461240 | `<ARRAYSRT>` writes nothing but the row size and `GetData` count 4 bytes | every column after it is read 4 bytes off | write (or skip) the 4 bytes consistently |
| S02-B12 | `CCsl::MakeFormat` FUN_00460ea0 | format inheritance indexes the format list as an array (`m_pFormats + i·0x4c`) | only the first format can be inherited; others read heap | walk the linked list |
| S02-B13 | `CToken::GoStartString` FUN_0045a380 / `GetTokenString` FUN_0045a6f0 | scans for `"` without bound; `""` leaves `m_pToken` on the unterminated quote | a missing quote or `""` before another string column reads past the buffer | bound the scan; NUL-terminate the empty string |
| S02-B14 | `CToken::my_tcstok` FUN_0045a170 | returns `""` (not null) when only delimiters remain | a script without `#END` ending in whitespace fails with `'' - UNKNOWNED.` | return null at the end |
| S02-B15 | `CCsl::CCsl(parent)` FUN_00461ea0 | include reader's `m_pDummyNull` not set | EOF inside a row of an included file passes an uninitialised pointer to `atoi` / `atof` | copy it from the parent / call Clear |
| S02-B16 | `CToken::GoNextLine` FUN_0045a330 | with LF-only files a remark token ending at the line end skips the next line too | LF files silently lose rows (505 of 530 in `DefaultCharacterData.txt`) | skip to the next LF from the token start |
| S02-B17 | `CCsl::Read` FUN_00461730 | success paths never close the file handle; failure paths leak the chunk buffer | one handle per `#READ` | close / free on every path |
| S02-B18 | `CCsl::IncludeFile` FUN_00462090 | re-tokenises from the saved position after the include | an include name with a space or comma leaves its tail as a token and fails the read | skip the whole quoted name |
| S02-B19 | `ProcRemark` FUN_00460c90, `MakeFormat` FUN_00460ea0, `MakeData` FUN_00461240 | unbounded `strcpy` into STRING [512], FILENAME [260], remark markers [64]; the format name is cut to 64 chars first (`strncpy` 0x40 into a zeroed 0x41 local), so only its NUL can land in the next member `NumParameter`, which is then overwritten | a long value overflows the row / reader (format name: harmless) | bounded copy |
| S02-B20 | `CCsl::GetDataToken` FUN_00461190 | EOF inside a data row increments `m_NumFormatErrors` | the message counts it as a format error | `m_NumDataErrors` |
| S02-B21 | `CCsl::MakeData` FUN_00461240 | `[…]` optional column types consume a value like `<…>` | a short row silently takes its missing values from the next row | stop at the line end for optional columns |
| S02-B22 | `CCsl::CCsl(CCsl* null)` FUN_00461ea0 | builds a temporary `CCsl` on the stack instead of initialising `this` | dead (only caller passes `this`) | call `VarClear` / `Clear` on `this` |
| S02-B23 | `CGdp::SetFilePointer` FUN_0045f360 (FILE_END) | method / high-pointer arithmetic mixed | dead in 2016 (container mode, §3.2) | – |
| S02-B24 | `CGdp::CreateFileA` FUN_0045fac0 (TRUNCATE_EXISTING) | inverted existence test; a missing entry indexes `list[−1]` | dead in 2016 | test the found index |
| S02-B25 | `CGdp::ReadFile` FUN_0045f1a0 | read not bounded to the entry; StoreType > 2 returns 1 with nothing read | dead in 2016 | clamp to SrcSize; fail unknown types |
| S02-B26 | `CGdp::GdpMakeEmptyChunk` FUN_0045f4e0 (ANSI) | any non-zero `ftell` counts as an error | dead in 2016 | test −1 |
| S02-B27 | `CGdp::CreateFileA` FUN_0045fac0 | new slot's StoreType / Encrypt uninitialised | dead in 2016 | zero them |
| S02-B28 | `CGdp::UpdateWriteDataInfo` FUN_0045efb0 (WriteFile) | adds n to SrcSize regardless of the position | dead in 2016 | size = max(size, pos + n) |
| S02-B29 | `CGdp::Open(i)` FUN_0045f980 | accepts `i == m_dwNumChunk` | dead in 2016 (one record past the list) | `i ≥ n` → fail |
| S02-B30 | `CGdp::GdpMakeEmptyChunk` FUN_0045f4e0 | malloc failure returns 0 (= the MAIN index) | dead in 2016 (turns MAIN into a FILE entry) | return −1 |
| S02-B31 | `CIOBuffer::Alloc` FUN_00468e10 | after the 512 pooled buffers of a slot, `new CIOBuffer` (0x2010) is not checked for null; `m_dwSize` / `m_nRef` / `m_pNext` are written at once | out of memory → access violation in a send instead of a failed send | return null and let `CSocket_IOCP::Send` fail |
| S02-B32 | `CIOCP::Start` FUN_004645c0 | `CreateThread` result not checked; with the wait flag set (all callers) the loop sleeps 50 ms until the worker leaves STARTING, which a thread that was never created never does; `Start` returns `n` either way, so the Login / WM `!= n` checks only catch a failed port creation (0); Zone (2 × CPUs + 1 workers) ignores the result | start-up hangs forever instead of failing | check the handle, count started workers, return the count |
| S02-B33 | `ZoneServer::zs_ServerConnect2Zone` FUN_005a9a00 | tests `zipc_GetNextZoneNo() == −1` and asserts "not find nextzoneinfo" when `zipc_Mechine2IP` fails, but GetNextZoneNo returns 0 … 11 (0 when there is no next zone), so both are dead | a missing ring neighbour is never reported; the zone connects to zone 0 (its own listen port when it is zone 0) | return −1 for "no next zone" |

## 6. Not reconstructed / uncertain

The per-part lists are §1.10, §2.8 and §3.7. In addition:

- The `m_LoginUserRatable` values in the Login constructor (§4.3) are stored here only; their meaning (a per-world
  user-count → status table, *inferred* from the `nWMSUS` names = "WM server user status") is for L01.
- Account / AccountLog / Character / GameLog link the same `CCsl` / `CToken` (same message strings) and an older
  session framework (GameLog: D05 §7.2); their copies of the network classes and `CCsl` were not compared
  instruction by instruction (no PDB). Z19 covers the `CCsl` comparison for all servers.

## 7. Coverage boundary

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| WM process layer on top of the library: `WorldManagerServer` ctor / dtor, `Listen_OPTool` / `Listen_Zone` / `Listen_Client`, `Start_Acceptor`, `OnStart_Service`, `ProcessLink` / `ProcessConnect` / `ProcessPacket` / `ProcessDisconnect` / `ProcessStop`, `CWMBaseSession` ctor / dtor / `CheckHeartBeat`, `CWMBaseSessionManager` pools | W05 (done) §1.1–§1.6, §4.1, §6.2 | already documented there; this document is the layer below |
| Handlers that build frames with `CSendPacket` and send through the session `Send` (WM, Login) or `ProtocolPacket::pp_SendPacket` (Zone) | the server items (W01–W04, L00, Z01–Z18) | the library only frames and queues; the payloads are the handlers' |
| `cShineLogSystem` (`SLS_AddLog`, `gSocket_IOCP_Write` initialiser FUN_00482690), `ShineExit`, `GetLastErrorStr`, `_DebugMessageNew` | W05 (done) §5.7, §6.4 | process log systems, documented there (W05-B20: `Socket_IOCP_Write` is never written) |
| `CServerInfo` row accessors (`GetMyServerInfo`, `GetServerInfo`, `GetServerIndex`; Zone `GetNationName` / `GetWorldName`) | W05 (done) §5.2 / §6.2, Z10 (done) §1.1 | what the rows mean per server; Login copies identical, §4.3 |
| `PROTOCOLFUNCTIONTEMPLETE<T>::pft_Store` handler tables | W05 (done) §6.1 | the dispatch above `CPacket` |
| Login process layer not cited anywhere: `ViewStartInfo` FUN_00401120, `MainThread` FUN_004030e0, `ProcessPacket` FUN_004024e0, `OnStop_Service` FUN_00402b70, the session pools (`CLoginBaseSessionManager` InitSessions / EmptyToActive / ActiveSession / InactiveSession / FreeSessions, `CLoginClientSessionManager` ActiveSession / HandleIsValid / GetSession / Kickoff / Send / InitSessions, `CLoginWorldManagerSessionManager` Get/SetWorldManagerConnectInfo / GetClientValidation / SetWMSession / InactiveSession / FreeSessions / InitSessions, `CLoginClientSession` Get/SetSessionMode), `m_LoginUserRatable`, `CParserWorldManager::Parser` FUN_004087d0 / its `pft_Store` FUN_004086b0, the AccountDB / AccountLogDB session ctors FUN_00408cd0 / FUN_00408d00, `COTPLogin` ctor FUN_0040a560, `~COTPData` FUN_0040a550, the per-parser 0x0801 / 0x0804 handler copies FUN_00404f50 / FUN_004050e0 / FUN_00407480 / FUN_00408560 | new item L01 (added by S02) | L00 is done and `login-server.md` cites none of them (~45 functions, the Login twin of W05 §1 / §4); too large for a gap fix here |
| Zone process layer: `zs_Start_Acceptor` FUN_005a9c60, `zs_service_acceptor` LAB_005aa7c0, `zs_connect` FUN_005aa840, the ring (`ZoneConnectSession::zcs_Send` FUN_005a6ed0, `ZoneListenSession`, `FieldContainer::fc_MakeField`), the session pools above the base manager (`ClientSessionManager` InitSessions …) | Z10 (done) §1.1 / §6.5 (acceptor start and service), Z09 (done) §1.5 (`zs_connect`), Z01 (done) §1 / §10 (pools, ring) | documented there. The library-facing glue those docs did not cite (`ZoneServer` ctor, `ZoneBaseSession` ctor / dtor, `ProcHeartBeat`, `ClientSession::CheckHeartBeat`, `ClientSessionManager` ctor / dtor, `zs_ServerConnect2Zone`, all of `ZoneIPContainer`, Zone `CServerInfo` ctor) is §4.4; `~ZoneServer` §4.2 |
| GameLog's session framework (older variant) | D05 (done) §7.2 | documented there |
| `CCsl` / `CToken` copies in Account, AccountLog, Character, GameLog; tested reader for all servers | Z19 (open; plan: "Other servers: confirm Login, WM, Account, AccountLog use the same functions … Character and GameLog … find the copy by its strings") | Z19 can cite §2 for the grammar and parser and add only the per-server diff |
| `CToken` as the quest-script tokenizer (`CQuestParserScript` FUN_00636f60 …, `ParserNext` FUN_006387f0) | Z15 (open; plan cites `QuestScript_Next` FUN_006387f0) | the tokenizer is §2.2; the quest grammar on top is Z15's |
| What each config file read through `CCsl` contains (`*ServerInfo.txt` rows, `DefaultCharacterData.txt`, `TutorialCharacterData.txt`, zone configs) | X03 knowledge §4–§5, Z10 §1.1, D03, Z19 | §2.4 gives the grammar and checks every shipped file; the meaning of the rows is per server |
| C runtime called by the library (`memmove`, `sscanf`, `atof`, `atoi`, `fopen` / `fclose` / `fread` / `fwrite` / `ftell` / `fseek`, `_mbspbrk`, `_mbsicmp`, `atexit`) | none needed | standard MSVC CRT semantics; nothing server-specific |
