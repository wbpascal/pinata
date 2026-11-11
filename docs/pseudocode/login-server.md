# Login Server: reconstructed pseudocode

Source: `Files/Server/2016/Login/3LoginServer2.exe` (SHA-256 `3513309c…`), decompiled with Ghidra. Each block cites
the function it was reconstructed from (`@ FUN_xxxxxxxx`). Use `tools/protocol-re/clean.py` to view the
original decompilation:

```
python3 tools/protocol-re/clean.py <export>/login tools/protocol-re/names-login.json 406680
```

This is a behavioural reconstruction, not original source. Names are mine unless they appear in a
string in the binary. *(inferred)* marks behaviour deduced from context, not read directly. Packet
layouts are in [`../protocol/packets-login.md`](../protocol/packets-login.md) and
[`../protocol/annotations.json`](../protocol/annotations.json) (+ [`annotations/L00.json`](../protocol/annotations/L00.json)).
Opcode names are the official ones from [`../protocol/opcodes.json`](../protocol/opcodes.json); most
come from the 2017 client PDB (`name_source: pdb2017`, work item C02) and fit the 2016 handlers they label.

---

## 1. Process structure

```
LoginServer (single global object, "this" in most functions)
├── config            : LoginServerInfo.txt + ../9Data/ServerInfo/ServerInfo.txt   (SERVER_INFO / ODBC rows)
├── versionKeys[5][64]: ClientVersionKeyInfo.txt
├── iocp              : CSocket_IOCP worker threads + acceptor (4 listen ports)
├── sessions
│   ├── ClientSession[]      (type 20)  parser = CParserClient
│   ├── WorldManagerSession[](type 5)   parser = CParserWorldManager   one per world
│   ├── OPToolSession[]      (type 8)   parser = CParserOPTool
│   ├── AccountDBSession     (outgoing, type 0)  parser = CParserAccountDB
│   └── AccountLogDBSession  (outgoing, type 1)  parser = CParserAccountLogDB
├── g_Clients     : handle -> ClientSession   (registry of logged-in clients)
├── g_WorldList   : world list packet + per-world WM session + per-world validate key
├── g_TokenTable  : one-time login tokens issued for WM "return to world select"
└── g_LoginOpen   : 0 = refuse logins (error 0x45)
```

### 1.1 Session object (`ClientSession`, fields seen)

| Offset | Field | Notes |
|---|---|---|
| +0x00 | `state` | 0 free, 1 connected, 2 validated, 3 = close requested, 4 closing |
| +0x04 | `type` | 20 = client |
| +0x20 | `lastRecvTime` | `timeGetTime()` of last received packet |
| +0x28 | `socket` (CSocket_IOCP) | send queue lives here |
| +0x30 | `ip` (u32) | +0x2e = port |
| +0x104 | `heartbeatSentAt` | 0 if no heartbeat pending |
| +0x108 | `handle` (u16) | index in g_Clients, sent to DB servers to route replies |
| +0x10a | `seed` (u16) | |
| +0x10c | `xorIndex` (u16) | +0x10e copy of the starting index |
| +0x110 | `userNo` (i32) | from AccountDB |
| +0x114 | `userId` (char[256]) | |
| +0x214 | `spawnapps` (20 bytes, `Name5`) | from 0x0C5A, forwarded to WM. Official name from the 2017 PDB *(pdb2017)*; read as 5 × u32 |
| +0x228 | `validated` (u16) | set to 1 after a successful account check |
| +0x2cc | `loginStep` | dispatcher state, see §3.2 |

---

## 2. Startup and main loop

```pseudo
main(args):                                              @ FUN_00402f30
    chdir(directory of the executable)
    log "Launching the server....."
    if !LoadServerInfo(): return                           @ FUN_00401380
    if !HandleServiceCommand(args): return                 @ FUN_00402ba0  (install/remove as NT service)
    if !LoadVersionKeys(): return                          @ FUN_00401680
    start main thread -> MainLoop

LoadServerInfo():                                        @ FUN_00401380
    parse "LoginServerInfo.txt" (MY_SERVER "PG_Login", "_2015_Login", type 4, world 0, zone 0)
        with #INCLUDE ../9Data/ServerInfo/ServerInfo.txt
    log "<I AM THE %s, %s, WorldNo=%d, ZoneNo=%d>"
    accountDb     = find SERVER_INFO(type 0)                 else log FATAL "CAN'T FOUND ACCOUNT DB SERVER INFO"
    accountLogDb  = find SERVER_INFO(type 1)
    wmListen      = find SERVER_INFO(myName, world, zone, listenType 5)   "WORLDMANAGER SERVER INFO"
    clientListen  = find SERVER_INFO(myName, world, zone, listenType 20)  "CLIENT SERVER INFO"
    opToolListen  = find SERVER_INFO(myName, world, listenType 8)         "OPTOOL INFO"

LoadVersionKeys():                                       @ FUN_00401680
    this.builtinKey = "037C4103B543CA6E6513075FED1D…" (33-byte constant at 0x428508; no reader found.
                       Probably the counterpart of the client's 0x0C04 key "33B543B0CA6E7C41E5D1D0651307",
                       which uses the same hex pairs in a different order; the check is not active in this build)
    f = fopen("ClientVersionKeyInfo.txt") or FATAL "VERSION KEY DATA READ FAILED"
    versionKeyCount = 0
    repeat up to 5 times:
        line = fgets(64); if none: break
        strip "\n"; versionKeys[versionKeyCount++] = line

Bootstrap tick (runs until "running"):                   @ FUN_00401bb0
    if !OpenListener(wmListen): fatal stop                 @ FUN_00401790  "<SUCCESSED LISTEN ADD ...>"
    if AccountDB not connected:  connect(accountDb)        "<CONNECTING ACCOUNT DB TO %s:%d>" / "<RECONNECT …>"
    if AccountLogDB not connected: connect(accountLogDb)   @ FUN_00401ac0
    when both DB links are up (state 1 = validated by NC_MISC_S2SCONNECTION_ACK):
        OpenListener(clientListen); OpenListener(opToolListen)   @ FUN_004018b0 / FUN_004019c0
        running = true; log "<SUCCESSED RUNNING SERVER---->"
    (clients cannot connect before both DB servers are up)

AcceptTick():                                            @ FUN_004022a0
    accepted = 0
    while acceptor.poll(&sock, &listenType):
        switch listenType:
          5  (WM):     s = WMSessions.alloc(sock);  register IOCP; SendRaw(s, 02 03 08)   @ FUN_00409e30  (0x0803)
          8  (OPTool): s = OPToolSessions.alloc(sock); register IOCP; FUN_00409c20(s)
          20 (client): accepted++
                       s = ClientSessions.alloc(sock) or close(sock)
                       s.type = 20; s.state = 1
                       register IOCP; SendSeed(s)
                       log "Accept client …"
        if allocation/registration fails: s.state = 3 (close)
        if accepted > 1: break          # at most 2 new clients per tick

SendSeed(s):                                             @ FUN_00409610
    s.xorIndex = s.xorStart = s.seed % 499
    SendRaw(s, [04, 07 08, seed])                          # 0x0807 NC_MISC_SEED_ACK

HeartbeatTick(s) for every session:                      @ FUN_00408f30
    if s.state in {1,2} or s.state > 4:
        now = timeGetTime()
        if now - s.lastRecvTime < 30_000:  s.heartbeatSentAt = 0
        elif s.heartbeatSentAt == 0:       s.heartbeatSentAt = now; SendRaw(s, [02, 04 08])   # 0x0804 HEARTBEAT_REQ
        elif now - s.heartbeatSentAt >= 180_000:
            log "ERROR - HEARTBEAT OVERTIME, NOW DISSCONNECT WITH %s"   (session closed)

On AccountLogDB disconnect: log "ACCOUNTLOG SERVER DISCONNECTED, ATTEMPT TO RECONNECT."; reconnect   @ FUN_00401d30
On AccountDB disconnect:    log "***FATAL ERROR - ACCOUNT DB SERVER DISCONNECTED, SERVER DOWN PROCESS…"; shut down
```

---

## 3. Receiving packets

### 3.1 Framing and decryption (shared network library)

```pseudo
OnReceive(session, bytes):                               @ FUN_00410870 + session read loop
    append to session.rxBuffer
    while a full packet is buffered:
        if rx[0] != 0: len = rx[0];          body = rx[1 : 1+len]
        else:          len = u16(rx[1:3]);   body = rx[3 : 3+len]
        session.lastRecvTime = now
        parser.Dispatch(session, body, len)

XorDecrypt(session, body, len):                          @ FUN_0040b170   (client sessions only)
    for i in 0..len-1:
        body[i] ^= XOR499[session.xorIndex]
        session.xorIndex = (session.xorIndex + 1) if < 498 else 0
```

### 3.2 Client dispatcher and login state machine

```pseudo
CParserClient.Dispatch(session, body, len):              @ FUN_00406680
    session.lastLen = len
    XorDecrypt(session, body, len)
    dept = u16(body) >> 10;  cmd = u16(body) & 0x3FF
    switch session.loginStep:
      0:  if (dept,cmd) != (3,0x65): reject                 # only the version check
          session.loginStep = 1
      1:  if dept != 3: reject
          if cmd == 0x37 (token login):   session.loginStep = 2
          elif cmd == 0x5A (user login):  session.loginStep = 2
          else: reject
      ≥2: (anything registered)
    handler = table[cmd][dept]
    session.lastOpcode = u16(body); session.inHandler = 1
    ok = handler(session, body, len)
    session.inHandler = ok ? 2 : 3
    if !ok: session.state = 3            # handler returning 0 closes the session

reject:
    if handler slot is the default: log "Invalid Client Session - Not registered protocol(Dept/Cmd=%d/%d) - IP_Addr(..), nUserRegNo(%d), bUserValidation(%s)"
    else:                           log "Invalid Client Session - Invalid sequence protocol(...)"
    session.state = 3                                     # disconnect

Unregistered opcodes on server links go to fc_dummyfunction: logs
"fc_dummyfunction, <PEER>, dep=%d, cmd=%d, length=%d" and ignores the packet.
```

Every handler first calls `<Peer>_CheckAlive(session)`, which only passes when `session.state == 1`
(otherwise it logs and the packet is ignored).

---

## 4. Client handlers (CParserClient, registered @ FUN_00406e30)

```pseudo
0x0804 NC_MISC_HEARTBEAT_REQ:                            @ FUN_004060b0
    SendRaw(s, [02, 05 08])                               # 0x0805 HEARTBEAT_ACK

0x0805 NC_MISC_HEARTBEAT_ACK:  no-op (receiving it already refreshed lastRecvTime)   @ LAB_004074a0

0x0C65 NC_USER_CLIENT_VERSION_CHECK_REQ { char sVersionKey[64] }:   @ FUN_004060d0
    for k in versionKeys[0 .. versionKeyCount-1]:
        if strncmp(payload.key, k, 64) == 0:
            s.someString = ""                              # field at +0x2aa cleared before use
            Send 0x0C67 NC_USER_CLIENT_RIGHTVERSION_CHECK_ACK { u8 XTrapServerKeyLength = strlen("")+1 = 1, char XTrapServerKey[1] = "" }
            return
    Send 0x0C66 NC_USER_CLIENT_WRONGVERSION_CHECK_ACK {}  # rejected; client is expected to quit
    # payload size 1, byte never written: the PDB struct is empty, the 1 is C++ sizeof of an empty struct
    # (original bug) L00-B1: one uninitialised byte on the wire

0x0C5A NC_USER_US_LOGIN_REQ { char sUserName[260]; char sPassword[36]; Name5 spawnapps }   (exact length 0x13E)   @ FUN_00406450
    if len != 0x13E: return
    Send to AccountDB 0x0C5B NC_USER_US_PASSWORD_CHECK_REQ {   # size 0x152
        u16  clientHandle  = s.handle               # NETPACKETHEADER
        char sUserName[260] = payload.sUserName (copies max 256; bytes 256..259 never read)
        char sPassword[36]  = payload.sPassword
        char sUserIP[20]    = sprintf("%03d.%03d.%03d.%03d", s.ip)
        Name5 spawnapps     = payload.spawnapps     # 20 bytes, copied as 5 × u32
    }
    # answer arrives as AccountDB 0x0C5C (§5.1)

0x0C37 NC_USER_LOGIN_WITH_OTP_REQ { sOTP[32] }  (exact length 0x22):   @ FUN_00406bb0
    if len != 0x22: return
    g_TokenTable.ExpireOlderThan(now)
    entry = g_TokenTable.Find(payload.token[32])
    if entry == null:
        g_TokenTable.NoteFailure(s.ip); err = 0x52             # no client text (original bug) L00-B4
    elif !g_LoginOpen:
        err = 0x45                                          # "Please check ID or Password." (original bug) L00-B2
    else:
        s.userNo = entry.userNo; s.userId = entry.userId; s.validated = 1
        g_Clients.Register(s)
        WorldList.BroadcastToAllWM 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD { u32 userNo }   # drop any old session
        Send 0x0C0A worldList
        g_TokenTable.Remove(payload.token); return
    # failure path
    g_Clients.SendRaw(s.handle, 0x0C09 { u16 err }); g_Clients.Disconnect(s.handle)
    Send to AccountLogDB 0x0720 (login-failure log) { userId = "USE OTP", ip, err }
    g_TokenTable.Remove(payload.token)

0x0C1B NC_USER_WORLD_STATUS_REQ (world list refresh):    @ FUN_004062f0
    Send 0x0C1C NC_USER_WORLD_STATUS_ACK (same body as 0x0C0A NC_USER_LOGIN_ACK: u8 count + WORLD[count])

0x0C0B NC_USER_WORLDSELECT_REQ { u8 worldno }:           @ FUN_00406970
    if !WorldList.GetWMAddress(worldNo, &reply)          # reply.status = world status byte
       or world status < 5:                               # status meanings: see §8
                                                          # status 5 (full) passes, the client refuses it (original bug) L00-B3
        Send 0x0C0C { status, zeros… }                    # 0x56-byte raw packet, only status filled
        return
    Send to AccountDB    0x0C10 { u32 userNo, u8 worldNo, u32 ip }       # "user entering world" (inferred)
    Send to AccountLogDB 0x0721 { u32 userNo, u8 worldNo, u32 ip }       # world-select log
    key = WorldList.GetKey(worldNo)
    rnd[31] = random() % 0xFFFF; check = key XOR rnd[0] XOR … XOR rnd[30]
    Send to WM[worldNo] 0x0C0D {                          # size 0x15B
        u16  loginHandle = s.handle
        u8   worldNo
        u32  userNo
        char userId[256]
        u16  validate[32] = rnd[0..30], check
        Name5 spawnapps = s.spawnapps
    }
    # WM answers 0x0C0E (§5.3) -> client gets 0x0C0C with WM address and validate[]

0x0C1D NC_USER_LOGIN_NETMARBLE_REQ:                      @ FUN_00406280
    Send 0x0C09 { 0x4A }; g_Clients.Disconnect(s)        # client-side cancel/exit (inferred)

0x0C20 NC_USER_LOGIN_OUTSPARK_REQ:                       @ FUN_004063d0
    log "ERROR - ERR_USERLOGIN_OUTSPARK_NOTSUPPORT"
    Send 0x0C09 { 0x4C }; g_Clients.Disconnect(s)        # unsupported external login method; no client text (original bug) L00-B4

0x0C04 NC_USER_XTRAP_REQ { u8 XTrapClientKeyLength = 29, char XTrapClientKey[29] }:   @ FUN_00406230
    # the client sends "33B543B0CA6E7C41E5D1D0651307" right after 0x0C67 (client FUN_0046f470)
    # this build does NOT check it (original bug) L00-B5
    SendRaw(s, [03, 05 0C, 01])                           # 0x0C05 NC_USER_XTRAP_ACK { u8 bSuccess = 1 }; the client ignores it

0x0C06 NC_USER_LOGIN_REQ, 0x0C18 NC_USER_NORMALLOGOUT_CMD: no-op           @ FUN_00406950 / LAB_004062e0
```

---

## 5. Server-link handlers

### 5.1 AccountDB replies (CParserAccountDB, registered @ FUN_00404cd0)

All replies carry the client's `handle` so the Login server can find the session again
(`g_Clients.IsValid(handle)` and `g_Clients.Get(handle)`). If the client has gone, the reply is dropped.

```pseudo
common AccountCheckResult(r):   (r = reply payload; fields: userNo i32, blocked i32, authOk i32, userId…)
    if r.userNo == -1:           err = 0x45     # client: "Please check ID or Password."
    elif r.userNo == -2:         err = 0x4B     # client: "Please accept the agreement to continue."
    elif !g_LoginOpen:           err = 0x45     # (original bug) L00-B2
    elif r.blocked != 0:         err = 0x47     # client: "The ID has been blocked."
    elif r.authOk != 1:          err = 0x48     # client: "The World Servers are down for maintenance."
    else:                        err = OK
    # error texts confirmed in the client (Fiesta.bin FUN_00416430, see §8)

0x0C5C NC_USER_US_PASSWORD_CHECK_ACK  reply to 0x0C5B:   @ FUN_00404590
    err = AccountCheckResult(r)
    if err == OK:
        s.userNo = r.userNo; s.userId = r.userId; s.spawnapps = r.spawnapps; s.validated = 1
        Send to AccountLogDB 0x0C5D NC_USER_US_IS_IP_BLOCK_REQ { handle, userNo, s.handle, ip-string, … }   # 0x17B bytes; ban/log check
        return                                             # continues in AccountLog 0x0C5E (§5.2)
    Send to AccountLogDB 0x0720 { userId, char[16] from reply +0x10C (unidentified), ip, err }   # failed-login log
    g_Clients.SendRaw(s, 0x0C09 { err }); g_Clients.Disconnect(s)
    Send to AccountLogDB 0xC802 NC_SYSLOG_ACCOUNT_LOGIN_FAILURE { UserName[256], UserIP[16], spawnapps }   # failed-login detail

0x0C08 / 0x0C54  (replies to older login request variants):   @ FUN_00404320
    err = AccountCheckResult(r)
    if OK: s.userNo = r.userNo; s.userId = r.userId; s.validated = 1
           g_Clients.Register(s); Broadcast WM 0x0C16 { userNo }; Send 0x0C0A worldList
    else:  Send 0x0C09 { err }; disconnect; Send to AccountLogDB 0x0720 log

0x0C3A  (variant):                                       @ FUN_00404990
    as above, but on success forwards to AccountLogDB 0x0C3B and waits for 0x0C3C

0x0C3F / 0x0C4C  (results with an explicit result code; 0x41 = OK):  @ FUN_00403b50 / FUN_00403cd0
    if r.code == 0x41 and r.userNo != -1: s.userNo = r.userNo; s.validated = 1
         forward to AccountLogDB (0x0C24 / 0x0C4D)
    else: Send 0x0C09 { r.code (or 0x44 / 0x41) }; disconnect

0x0C27  (teen-protection variant):                       @ FUN_00404050
    if r.mode == 3: log "WARNING - KEEP_TEENAGER, LOGINABLE VERSION, DB-ERROR User pass…"; r.mode = 2
    Send to client 0x0C25 { string, u8 mode, u32 value }   # 0x3A raw bytes
    if r.mode == 1: Send AccountLogDB 0x0720 log (err 0x4E; no client text, (original bug) L00-B4)
    else:           g_Clients.Register(s); Broadcast WM 0x0C16; Send 0x0C0A worldList

0x0801 S2SCONNECTION_RDY → reply 0x0802 S2SCONNECTION_REQ { myServerId, myWorld, myZone }   @ FUN_00403a40
0x0803 S2SCONNECTION_ACK: if code == 0: link.state = 1, log "Connected to …" else log "ValidationFail …"   @ FUN_00404fb0
0x0804 HEARTBEAT_REQ → reply 0x0805                       @ FUN_00403aa0
```

Only the `0x0C5A → 0x0C5B → 0x0C5C → 0x0C5D → 0x0C5E` path is reachable from the current client,
because the client parser only accepts `0x0C5A` and `0x0C37`. The other variants are kept for older clients.

### 5.2 AccountLogDB replies (CParserAccountLogDB, registered @ FUN_00405e50)

```pseudo
0x0C5E NC_USER_US_IS_IP_BLOCK_ACK  reply to 0x0C5D:      @ FUN_004058c0
    s = g_Clients.Get(r.handle)  (at payload +0x161)
    if r.blocked (payload +0x163) == 1:
        Send 0x0C09 { 0x51 }                               # client: "You are not in our service area." (region block)
        Send AccountLogDB 0x0720 log; Send AccountLogDB 0xC802 detail
    else:
        g_Clients.Register(s)
        Broadcast to all WM 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD { u32 userNo }
        Send 0x0C0A worldList
        Send AccountLogDB 0xC801 NC_SYSLOG_ACCOUNT_LOGIN_SUCCESS {   # successful-login log, 40 bytes
            u32 UserNo; char UserIP[16] (zeroed here; (original bug) L00-B6); Name5 spawnapps }   # 2017 struct is 70 B: adds UserID[30] before spawnapps

0x0C2B / 0x0C3C / 0x0C41 / 0x0C4E:  same shape for the legacy login variants   @ FUN_00405c80 / 405180 / 4054c0 / 4056c0
```

### 5.3 World manager links (CParserWorldManager, registered @ FUN_00408bc0)

```pseudo
0x0802 NC_MISC_S2SCONNECTION_REQ (WM announces itself):  @ FUN_00408170
    validate server id / key from ServerInfo; bind session to its world number
    reply 0x0803 { u16 result }

0x0808 NC_MISC_USER_COUNT_CMD (world status update):                              @ FUN_00408580
    WorldList.Update(session.worldNo, payload)            # status byte in WORLD entry (≥5 = open)
    if session.firstUpdatePending: clear it; push 0x0C1C world list to every client   @ FUN_00409890

0x080B: forward payload verbatim to AccountDB            @ FUN_004085e0   (WM uses Login as relay)
0x080C: forward payload verbatim to AccountLogDB         @ FUN_00408620
0x0823: no-op                                            @ FUN_00408660

0x0C0E NC_USER_WILLLOGIN_ACK  WM accepted a world login: @ FUN_00408870
    if !g_Clients.IsValid(r.loginHandle): log "ERROR - CLIENT_HANDLE_ISVALID = %d"; return
    if r.ok == 0: log; g_Clients.Disconnect(r.loginHandle); return
    WorldList.GetWMAddress(r.worldNo, &reply)             # status + WM client IP
    reply.validate[32] = r.validate[32]                   # payload +0x107 (64 bytes)
    g_Clients.SendRaw(r.loginHandle, 0x0C0C reply)        # 0x56 bytes

0x0C35 NC_USER_CREATE_OTP_REQ  WM asks for a one-time token (player returns to world select):   @ FUN_00408a20
    g_TokenTable.ExpireOlderThan(now)
    if g_TokenTable.ContainsUser(r.userNo):        result = 0x1E5B  # already pending
    else:
        token = sprintf("%d%d%d%d%d%c", random…)        @ FUN_0040a8a0  (32 chars)
        entry = { token, userNo = r.userNo, userId = r.userId, expires = now + 10 s, worldHandle = r.handle }
        if token generation failed:  result = 0x1E59
        elif !g_TokenTable.Insert(entry): result = 0x1E5A
        else: result = 0x1E58                            # OK
    reply 0x0C36 NC_USER_CREATE_OTP_ACK { u16 wmHandle = r.handle, u16 result, char token[32] }   # 0x27 raw bytes
    # WM passes the token to the client, which reconnects to Login and sends 0x0C37 within 10 s
```

### 5.4 OPTool (operator tool, CParserOPTool, registered @ FUN_00407ef0)

```pseudo
0x0802 S2SCONNECTION_REQ: authenticate the tool, reply 0x0803   @ FUN_004070c0
0x2801 → 0x2802 connection list: for AccountDB, AccountLogDB and every WM/OPTool link that is up:
        { u8 serverType, u8 world, u8 zone, u32 connectedAt (packed y/m/d/h/m/s bits) }   @ FUN_004074b0
0x2803 → 0x2804 { u16 0x0600 }; g_Shutdown = 1           # remote stop   @ FUN_00407980
0x2807 NC_OPTOOL_CONNECT_BRIF_REQ → 0x2808: per (type, world, zone) count of connected links (170 bytes)   @ FUN_00407a30
0x2812 → 0x2813, 0x2814, 0x2818 → 0x2819: further status queries   @ FUN_00407c90 / 407d50 / 407df0
0x2805, 0x2817: accepted, no action                      @ FUN_00407dd0
```

---

## 6. End-to-end: what happens when a player logs in

```
connect                     → server: SendSeed (0x0807)
0x0C65 version key          → 0x0C67 ok | 0x0C66 reject
0x0C5A id/password          → AccountDB 0x0C5B
       AccountDB 0x0C5C     → (fail) 0x0C09 err + AccountLog logs, disconnect
                            → (ok)   AccountLog 0x0C5D
       AccountLog 0x0C5E    → (blocked) 0x0C09 0x51, disconnect
                            → (ok) register, kick old WM sessions (0x0C16 to every WM),
                                   0x0C0A world list, AccountLog 0xC801 login record
0x0C0B world n              → AccountDB 0x0C10, AccountLog 0x0721, WM[n] 0x0C0D (32-word key)
       WM 0x0C0E            → 0x0C0C { status, WM ip, validate[32] }
client disconnects and connects to WM with 0x0C0F (see WM docs)

returning from the game to world select:
WM → Login 0x0C35 → Login 0x0C36 { token } → WM → client → client reconnects to Login → 0x0C37 token
```

## Original-server bugs

Behaviour of the 2016 Login server that looks unintended. A faithful rebuild reproduces it; a fixed rebuild should
change it deliberately. All items are read in the code; none was observed in a capture.

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| L00-B1 | 0x0C65 (reject path) | 0x0C66 is sent with a 1-byte payload that is never written | one uninitialised byte on the wire (client ignores it) | empty payload, or zero the byte |
| L00-B2 | 0x0C37, AccountCheckResult | logins closed (`g_LoginOpen == 0`) report 0x45 | client says "Please check ID or Password." during a closed login | a maintenance code (0x48) |
| L00-B3 | 0x0C0B | accepts world status 5 (full); only < 5 is refused | AccountDB 0x0C10, AccountLog 0x0721 and WM 0x0C0D are sent for a world the client then refuses to enter ("Server is full") | refuse status 5 too (`< 6`) |
| L00-B4 | 0x0C37, 0x0C20, 0x0C27 | sends error codes 0x52, 0x4C, 0x4E | no entry in the client table: "An unidentified error code has occurred." | codes the client knows |
| L00-B5 | 0x0C04 | the client's XTrap key is never compared; `builtinKey` is loaded and unused | any key is accepted (dead check) | compare with `builtinKey`, or drop the exchange |
| L00-B6 | 0x0C5E success | 0xC801 login-success log has `UserIP` zeroed | the success log has no IP | fill the IP like 0x0720 / 0xC802 |

## 7. Not reconstructed / uncertain

- Which database conditions set the AccountDB result flags (the client texts are known, see §8).
  That logic lives in the Account server and its SQL procedures.
- `builtinKey` at 0x428508 is copied into the server object, but no reader was found.
- Error codes 0x4C, 0x4E and 0x52 have no entry in the client's table. The client shows
  "An unidentified error code has occurred.: <code>".
- The OPTool status queries 0x2812/0x2814/0x2818 are only summarised.
- Service install/remove (`FUN_00402ba0`), crash-dump and log-file plumbing (`FUN_00411bb0`,
  `FUN_00412bc0`) are infrastructure and are not detailed.

## 8. Client side (cross-referenced with `Files/Client/2016/Fiesta.bin`)

The client's login screen accepts only these packets (dispatcher `FUN_0046f4d0`, switch on dept/cmd):

```pseudo
LoginScene.OnPacket(dept, cmd, payload):                 client @ FUN_0046f4d0
  0x0807 seed:          store seed; Send 0x0C65 { char[64] "20151116141627" }            @ FUN_0046eb30
  0x0C67 version ok:    open login UI; Send 0x0C04 { u8 29, "33B543B0CA6E7C41E5D1D0651307" }   @ FUN_0046f470
  0x0C66 version bad:   message "You client version is different from the Server version.
                        Please restart the client after patching."               @ FUN_0046eec0
  0x0C05:               ignored
  0x0C09 {u16 code}:    message ErrMsgTable::GetErrMsg(code); close login connection           @ FUN_0046ee40
  0x0C0A / 0x0C1C:      store world list, show world selection                   @ FUN_0046edd0 / FUN_0046eae0
  0x0C0C {status, ip[16], port, validate[32]}:                                   @ FUN_0046ef20
        status 0  "Server is closed. Please try login later."
        status 1  "Server is under maintenance. Please try login later."
        status 2  "You cannot connect to an empty server."
        status 3  "The server has been reserved for a special use."
        status 4  "Login failed due to an unknown error."
        status 5  "Server is full. Please try again later."
        status 6..10: remember validate[32]; connect to ip:port (World manager)
  0x0C17 {u16 reason}:  if reason == 0x683 (same account logged in elsewhere): set flag   @ FUN_0046eac0
  0x2011:               ignored
```

Login-related error codes (`ErrMsgTable::GetErrMsg` = client `FUN_00416430`; the full table of 479 codes is in
[`../protocol/client-error-codes.json`](../protocol/client-error-codes.json)):

| Code | Sent by Login when | Client text |
|---|---|---|
| 0x42 | – | An unknown error has occurred. |
| 0x43, 0x46 | – | DB error |
| 0x44 | WM: bad validate key (0x0C15) | Authentication failed. |
| 0x45 | account check returned -1, or logins closed | Please check ID or Password. |
| 0x47 | account blocked flag | The ID has been blocked. |
| 0x48 | account flag ≠ 1 | The World Servers are down for maintenance. |
| 0x49 | – | Authentication timed out. Please try to log in again. |
| 0x4A | client sent 0x0C1D | Login failed. |
| 0x4B | account check returned -2 | Please accept the agreement to continue. |
| 0x4C | client sent 0x0C20 (unsupported login method) | (no entry) "An unidentified error code has occurred." |
| 0x4E | teen-protection variant | (no entry) |
| 0x51 | AccountLog flag | You are not in our service area. |
| 0x52 | unknown one-time token | (no entry) |

World status byte (`WORLD.status`, `0x0C0C.status`): the Login server rejects a world select when the status
is below 5. The client also refuses status 5 (full) and connects only for 6–10.
