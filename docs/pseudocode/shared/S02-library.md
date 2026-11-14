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
        else: b = new CIOBuffer (s_nCount++)                     # heap; a null result is not checked
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
        w.hThread = CreateThread(WorkThread, &w, &w.ThreadID)      # failure not checked
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
                cShineLogSystem::SLS_AddLog(gSocket_IOCP_Write, …)   # daily "Socket_IOCP_Write" log, W05 §5.7
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
| `CIOBuffer::Alloc` / `Free` / dtor | 468e10 / 468f00 / 468de0 | 412a00 / 412af0 / 4129d0 | 654cd0 / 654dc0 / 654ca0 |
| `IOBufferContainer` ctor, `CIOSpinLock::Wait` | 468d80, 468d10 | 412970, 412900 | 654c40, 654bd0 |
| `CIOCP` ctor / Register / Stop / WorkThread / Start | 464350 / 464380 / 4643c0 / 4644f0 / 4645c0 | 40fc40 / 40fc70 / 40fcb0 / 40fde0 / 40feb0 | 650380 / 6503b0 / 6503f0 / 650520 / 6505f0 |
| `CIOCP::Close` (Zone: `~CIOCP`) | 4646b0 | 40ffa0 | 6506e0 |
| `CIOCP_Process` ctor / dtor, default `IOCP_Process` | 4677a0 / 465f30, 467790 | 412460 / 410860, 410a70 | 64f3e0 / 64f400, folded |
| `CSocket_Acceptor` ctor / Stop / Listen_Add / GetAccepted / SetAccepted / dtor | 463960 / 4639e0 / 463a50 / 463bb0 / 463c40 / 463de0 | 40f250 / 40f2d0 / 40f340 / 40f4a0 / 40f530 / 40f6d0 | 652730 / 6527b0 / 652820 / 652980 / 652a10 / 652bb0 |
| `CSocket_Acceptor` Listen_Stop / AcceptThreadRing / Listen_Start | 463e10 / 463ee0 / 4642a0 | 40f700 / 40f7d0 / 40fb90 | – / 652be0 / 652fa0 |
| `CSocket_Acceptor_Process` ctor, `InetAddress::WinSockStart` | 468c30, 468c40 | 412880, 412890 | 654e20, 653840 |
| `CSocket_IOCP` ctor / dtor / Connect / Send / WriteCallback | 466420 / 466520 / 4665b0 / 4666f0 / 466240 | 410d60 / 410e60 / 410ef0 / 411030 / 410b80 | 64f930 / 64fa30 / 64fac0 / 64fc00 / 64f750 |
| `CSocket_IOCP` Receive / Shutdown / CloseUseIOCP / FreeBuffer / Close | 465f40 / 466060 / 466120 / 466140 / 466180 | 410870 / 410990 / 410a50 / 410a80 / 410ac0 | 64f410 / 64f530 / 64f5f0 / 64f620 / 64f690 |
| `CPacket` ctor / dtor / Clear / IsValidHeader / IsValidPacket / GetPacketSize | 467ac0 / 4677b0 / 4679d0 / 4677e0 / 467820 / 467880 | 412780 / 412470 / 412690 / 4124a0 / 4124e0 / 412540 | 650290 / 64ff80 / 6501a0 / 64ffb0 / 64fff0 / 650050 |
| `CPacket` GetDataSize / GetIDPtr / GetDataPtr / GetPacket / TakeNextPacket / RemoveAllUsedPacket | 4678c0 / 4678e0 / 4678f0 / 467900 / 467960 / 467990 | 412580 / 4125a0 / 4125b0 / 4125c0 / 412620 / 412650 | 650090 / 6500b0 / 6500c0 / 6500d0 / 650130 / 650160 |
| `CPacket` ID() / ID(op,…) / WriteData / GetWriteableBufferSize / GetWriteDataPtr | 467a10 / 467b00 / 467a30 / 467aa0 / 467ab0 | 4126d0 / 4127c0 / 4126f0 / 412760 / 412770 | 6501e0 / 6502d0 / 650200 / 650270 / 650280 |
| `CSendPacket` ctor / SetSize / GetSendSize / GetSendPtr / ID | 45fd30 / 45fd50 / 45fe30 / 45fe50 / 45fe70 | 412280 / 4122a0 / 412380 / 4123a0 / 4123c0 | – |
| session `IOCP_Process` / `IOCP_CloseProcess` | 42fe90 / 42ff60 | 409020 / 4090b0 | 5a6820 / no-op |
| session Register / Connect / Receive / Close / Send | 42fd10 / 42ffb0 / 42fcd0 / 42fc30 / 42fc50, 42fca0 | 408e70 / 4090d0 / 408e30 / 408dd0 / 408df0, 408e20 | 5a6700 / 5a68b0 / 5a66c0 / 5a6690 / 5a66b0 |

(All addresses are `FUN_00…`: e.g. Zone `CSocket_IOCP::Send` = FUN_0064fc00.)

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
        if name == none: name = strncpy(tok, 64); continue   # first token = format name; 64 chars leave no NUL in
                                                             # Format[64] (part of S02-B19)
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
| `CToken::CToken` / `Close` / `SetSeprator` / `my_tcstok` / `GetToken` | 0045a080 / a0f0 / a150 / a170 / a1f0 | 0040aa00 / aa70 / aad0 / aaf0 / ab70 | 0063aea0 / af10 / af70 / af90 / b010 |
| `GoBegin` / `GoNextLine` / `GoStartString` / `SaveTokenPositon` / `RestoreTokenPositon` | 0045a270 / a330 / a380 / a3d0 / a3e0 | 0040abf0 / acb0 / ad00 / ad50 / ad60 | 0063b090 / b150 / b1a0 / b1f0 / b200 |
| `IsTokenID` / `GetTokenID` / `~CToken` / `Open` / `OpenFromMemory` / `GetTokenString` | 0045a450 / – / a490 / a520 / a630 / a6f0 | 0040add0 / – / ae10 / aea0 / afb0 / b070 | 0063b270 / b2b0 / b310 / b3a0 / b4b0 / b570 |
| `CCsl::VarClear` / `MakeFormatTable` / `MakeDataTable` / `AddResultMsg` / `ViewResultMsg` | 004608d0 / 0940 / 09c0 / 0a40 / 0ac0 | 0040d200 / d270 / d2f0 / d370 / d3f0 | 00650710 / 0780 / 0800 / 0880 / – |
| `GetFormat` / `GetNumDatas` / `GetDataInfo` / `GetData` / `ProcRemark` / `MakeFormat` | 00460af0 / 0b40 / 0b50 / 0ba0 / 0c90 / 0ea0 | 0040d420 / d470 / d480 / d4d0 / d5c0 / d7d0 | 00650900 / 0950 / 0960 / 09b0 / 0aa0 / 0cb0 |
| `AddFormat` / `GetDataToken` / `Parameter_filename` / `MakeData` / `ProcData` / `ReadScriptDone` | 00461150 / 1190 / 1210 / 1240 / 1490 / 1520 | 0040da80 / dac0 / db40 / db70 / ddc0 / de50 | 00650f60 / 0fa0 / 1020 / 1050 / 12a0 / 1330 |
| `Read` / `WriteFormat` / `WriteData` / `ClearFormats` / `ClearDatas` / `Close` / `Clear` | 00461730 / 1970 / 1a90 / 1ba0 / 1c10 / 1c80 / 1d00 | 0040e060 / e2a0 / e3c0 / e4d0 / e540 / e5b0 / e630 | 00651540 / 1780 / 18a0 / 19b0 / 1a20 / 1a90 / 1b10 |
| `~CCsl` / `CCsl()` / `CCsl(parent)` / `IncludeFile` / `ProcCmd` / `ReadScript` | 00461de0 / 1e40 / 1ea0 / 2090 / 21f0 / 26f0 | 0040e710 / e770 / e7d0 / e9c0 / eb20 / f020 | 00651bf0 / 1c50 / 1cb0 / 1ea0 / 2000 / 2500 |
| `CServerInfo::ReadServerInfo` / `GetShineServerIDName` / `…ShortName` | 00465c90 / 0045a040 / 0045a060 | 004104e0 / 0040a9c0 / 0040a9e0 | 0064d0f0 / – / – |

### 2.8 Uncertain (part 2)

- The varargs of the result messages are *(inferred)* from their format strings except ReadScriptDone's include
  counts (read). They are diagnostics only.
- `m_hWnd` / `m_UseMsgID` (0x401 = `WM_USER + 1`) and the unused `m_lplpTokenList` / `m_dwNumTokens` suggest the
  reader came from a Windows editor tool *(inferred)*; the servers never post window messages through them.
- What S02-B13 reads past the buffer depends on the heap; with the shipped files the path is not reached.
