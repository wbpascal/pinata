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
- The CCsl and CGdp copies differ in a few functions (Zone `CCsl::Read`, `MakeFormat`, `Clear*`; Login / Zone
  `CCsl::ProcRemark`, `CGdp::CreateFileA`): §2 / §3 (later parts).

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
